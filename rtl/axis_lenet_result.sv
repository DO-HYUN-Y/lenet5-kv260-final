`timescale 1ns/1ps
// axis_lenet_result.sv -- activation-bank result reader to 128-bit AXIS.
//
// The fixed LeNet-5 output is five packed 16-bit words (ten INT8 logits).
// Reads are issued one at a time through the existing host port, collected in
// memory order, and exposed as one backpressure-safe AXIS packet.

module axis_lenet_result #(
  parameter int NC          = 8,
  parameter int AXIS_W      = 128,
  parameter int AXIS_BYTES  = AXIS_W / 8,
  parameter int COUNT_W     = 16,
  parameter int BASE_W      = 16,
  parameter int WGT_ADDR_W  = 11,
  parameter int PARAM_ADDR_W = 8,
  parameter int BANK_ADDR_W = 9,
  parameter int BANK_W      = (NC < 2) ? 1 : $clog2(NC)
) (
  input  logic clk,
  input  logic rst_n,
  input  logic start,
  input  logic clear_error,
  input  logic [COUNT_W-1:0] cfg_word_count,
  input  logic [BASE_W-1:0]  cfg_base,
  input  logic [BANK_W-1:0]  cfg_bank_base,
  input  logic               cfg_activation_set,

  input  logic               activation_host_ready,
  output logic               activation_host_set,
  output logic               activation_host_en [0:NC-1],
  output logic [1:0]         activation_host_we [0:NC-1],
  output logic [BANK_ADDR_W-1:0] activation_host_addr [0:NC-1],
  output logic [15:0]        activation_host_wdata [0:NC-1],
  input  logic [15:0]        activation_host_rdata [0:NC-1],
  input  logic               activation_host_rvalid,

  output logic [AXIS_W-1:0]     m_axis_tdata,
  output logic [AXIS_BYTES-1:0] m_axis_tkeep,
  output logic                  m_axis_tvalid,
  input  logic                  m_axis_tready,
  output logic                  m_axis_tlast,

  output logic busy,
  output logic done,
  output logic error
);

  localparam logic [1:0] MODE_RESULT = 2'd3;
  typedef enum logic [1:0] {
    ST_IDLE,
    ST_ISSUE,
    ST_WAIT_RSP,
    ST_SEND
  } state_t;

  state_t state_r;
  logic busy_r;
  logic error_r;
  logic activation_set_r;
  logic [COUNT_W-1:0] word_count_r;
  logic [AXIS_W-1:0] output_buffer_r;
  logic [AXIS_BYTES-1:0] output_keep_r;
  logic [BANK_W-1:0] pending_bank_r;
  logic [2:0] pending_slot_r;
  logic pending_last_r;

  logic addr_start;
  logic addr_advance;
  logic addr_busy;
  logic addr_valid;
  logic addr_last;
  logic addr_done;
  logic addr_error;
  logic [1:0] addr_mode;
  logic [COUNT_W-1:0] addr_index;
  logic [WGT_ADDR_W-1:0] unused_weight_addr;
  logic [PARAM_ADDR_W-1:0] unused_param_addr;
  logic [BANK_W-1:0] addr_bank;
  logic [BANK_ADDR_W-1:0] addr_bank_word;
  logic [COUNT_W-1:0] addr_cfg_count_c;
  logic read_issue_c;

  always_comb begin
    if (cfg_word_count == '0)
      addr_cfg_count_c = COUNT_W'(1);
    else if (cfg_word_count > COUNT_W'(AXIS_BYTES / 2))
      addr_cfg_count_c = COUNT_W'(AXIS_BYTES / 2);
    else
      addr_cfg_count_c = cfg_word_count;
  end

  assign addr_start = start && !busy_r;

  lenet_dma_addr_gen #(
    .NC(NC), .COUNT_W(COUNT_W), .BASE_W(BASE_W),
    .WGT_ADDR_W(WGT_ADDR_W), .PARAM_ADDR_W(PARAM_ADDR_W),
    .BANK_ADDR_W(BANK_ADDR_W), .BANK_W(BANK_W)
  ) u_addr_gen (
    .clk(clk), .rst_n(rst_n), .start(addr_start),
    .clear_error(clear_error), .advance(addr_advance),
    .cfg_mode(MODE_RESULT), .cfg_count(addr_cfg_count_c),
    .cfg_base(cfg_base), .cfg_bank_base(cfg_bank_base),
    .busy(addr_busy), .valid(addr_valid), .last(addr_last),
    .done(addr_done), .error(addr_error), .mode(addr_mode),
    .unit_index(addr_index), .weight_addr(unused_weight_addr),
    .param_addr(unused_param_addr), .bank_index(addr_bank),
    .bank_word_addr(addr_bank_word)
  );

  always_comb begin
    read_issue_c =
        (state_r == ST_ISSUE) && addr_valid && activation_host_ready;
    addr_advance = read_issue_c;
    activation_host_set = activation_set_r;

    for (int c = 0; c < NC; c++) begin
      activation_host_en[c] =
          read_issue_c && (addr_bank == BANK_W'(c));
      activation_host_we[c] = 2'b00;
      activation_host_addr[c] = addr_bank_word;
      activation_host_wdata[c] = '0;
    end

    m_axis_tdata = output_buffer_r;
    m_axis_tkeep = output_keep_r;
    m_axis_tvalid = (state_r == ST_SEND);
    m_axis_tlast = (state_r == ST_SEND);
    busy = busy_r;
    error = error_r || addr_error;
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state_r <= ST_IDLE;
      busy_r <= 1'b0;
      done <= 1'b0;
      error_r <= 1'b0;
      activation_set_r <= 1'b0;
      word_count_r <= COUNT_W'(1);
      output_buffer_r <= '0;
      output_keep_r <= '0;
      pending_bank_r <= '0;
      pending_slot_r <= '0;
      pending_last_r <= 1'b0;
    end else begin
      done <= 1'b0;
      if (clear_error)
        error_r <= 1'b0;

      if (start) begin
        if (busy_r) begin
          error_r <= 1'b1;
        end else begin
          busy_r <= 1'b1;
          state_r <= ST_ISSUE;
          activation_set_r <= cfg_activation_set;
          word_count_r <= addr_cfg_count_c;
          output_buffer_r <= '0;
          output_keep_r <= '0;
          for (int b = 0; b < AXIS_BYTES; b++) begin
            if (b < 2 * addr_cfg_count_c)
              output_keep_r[b] <= 1'b1;
          end
          if ((cfg_word_count == '0) ||
              (cfg_word_count > COUNT_W'(AXIS_BYTES / 2)))
            error_r <= 1'b1;
        end
      end

      case (state_r)
        ST_IDLE: begin
        end
        ST_ISSUE: begin
          if (read_issue_c) begin
            pending_bank_r <= addr_bank;
            pending_slot_r <= 3'(addr_index);
            pending_last_r <= addr_last;
            state_r <= ST_WAIT_RSP;
          end
        end
        ST_WAIT_RSP: begin
          if (activation_host_rvalid) begin
            output_buffer_r[
                pending_slot_r*16 +: 16
            ] <= activation_host_rdata[pending_bank_r];
            if (pending_last_r)
              state_r <= ST_SEND;
            else
              state_r <= ST_ISSUE;
          end
        end
        ST_SEND: begin
          if (m_axis_tvalid && m_axis_tready) begin
            busy_r <= 1'b0;
            done <= 1'b1;
            state_r <= ST_IDLE;
          end
        end
        default: begin
          state_r <= ST_IDLE;
          busy_r <= 1'b0;
          error_r <= 1'b1;
        end
      endcase

      if (activation_host_rvalid && (state_r != ST_WAIT_RSP))
        error_r <= 1'b1;
    end
  end

`ifdef SIMULATION
  assert property (@(posedge clk) disable iff (!rst_n)
      (m_axis_tvalid && !m_axis_tready) |=> $stable({
        m_axis_tdata, m_axis_tkeep, m_axis_tlast
      }));
  assert property (@(posedge clk) disable iff (!rst_n)
      m_axis_tvalid |-> m_axis_tlast);
  assert property (@(posedge clk) disable iff (!rst_n)
      read_issue_c |-> activation_host_ready);
  assert property (@(posedge clk) disable iff (!rst_n)
      $onehot0({
        activation_host_en[0], activation_host_en[1],
        activation_host_en[2], activation_host_en[3],
        activation_host_en[4], activation_host_en[5],
        activation_host_en[6], activation_host_en[7]
      }));
`endif

endmodule
