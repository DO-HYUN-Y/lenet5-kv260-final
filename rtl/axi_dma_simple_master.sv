`timescale 1ns/1ps
// axi_dma_simple_master.sv -- AXI-Lite master for one AXI DMA simple transfer.
//
// cmd_valid/cmd_ready is driven by the system scheduler. The master writes the
// selected AXI DMA channel registers, pulses armed after LENGTH is accepted,
// and polls DMASR until IOC or an error is observed.

module axi_dma_simple_master #(
  parameter int AXI_ADDR_W = 32,
  parameter int DMA_LEN_W = 26,
  parameter logic [AXI_ADDR_W-1:0] DMA_BASE_ADDR = 32'ha001_0000,
  parameter int POLL_INTERVAL = 4,
  parameter logic [31:0] DEFAULT_TIMEOUT = 32'd10_000_000
) (
  input  logic                  clk,
  input  logic                  rst_n,
  input  logic                  clear_error,

  input  logic                  cmd_valid,
  output logic                  cmd_ready,
  input  logic                  cmd_s2mm,
  input  logic [31:0]           cmd_buffer_addr,
  input  logic [DMA_LEN_W-1:0]  cmd_length_bytes,
  input  logic [31:0]           cmd_timeout_cycles,

  output logic                  armed,
  output logic                  busy,
  output logic                  done,
  output logic                  error,
  output logic [3:0]            error_code,
  output logic [31:0]           last_status,
  output logic [31:0]           active_cycles,
  output logic [3:0]            state_debug,

  output logic [AXI_ADDR_W-1:0] m_axi_awaddr,
  output logic [2:0]            m_axi_awprot,
  output logic                  m_axi_awvalid,
  input  logic                  m_axi_awready,
  output logic [31:0]           m_axi_wdata,
  output logic [3:0]            m_axi_wstrb,
  output logic                  m_axi_wvalid,
  input  logic                  m_axi_wready,
  input  logic [1:0]            m_axi_bresp,
  input  logic                  m_axi_bvalid,
  output logic                  m_axi_bready,
  output logic [AXI_ADDR_W-1:0] m_axi_araddr,
  output logic [2:0]            m_axi_arprot,
  output logic                  m_axi_arvalid,
  input  logic                  m_axi_arready,
  input  logic [31:0]           m_axi_rdata,
  input  logic [1:0]            m_axi_rresp,
  input  logic                  m_axi_rvalid,
  output logic                  m_axi_rready
);

  localparam logic [31:0] DMA_CONTROL_VALUE = 32'h0000_5001;
  localparam logic [31:0] DMA_STATUS_CLEAR  = 32'h0000_7000;
  localparam logic [31:0] DMA_ERROR_MASK    = 32'h0000_4770;
  localparam int POLL_COUNT_W =
      (POLL_INTERVAL <= 1) ? 1 : $clog2(POLL_INTERVAL);

  typedef enum logic [3:0] {
    ST_IDLE,
    ST_WRITE_CONTROL,
    ST_CLEAR_STATUS,
    ST_WRITE_ADDRESS,
    ST_WRITE_LENGTH,
    ST_POLL_DELAY,
    ST_READ_STATUS_REQ,
    ST_READ_STATUS_WAIT,
    ST_ERROR
  } state_t;

  state_t state_r;
  logic direction_r;
  logic [31:0] buffer_addr_r;
  logic [DMA_LEN_W-1:0] length_r;
  logic [31:0] timeout_r;
  logic [POLL_COUNT_W-1:0] poll_count_r;
  logic aw_done_r;
  logic w_done_r;
  logic armed_seen_r;
  logic error_r;
  logic [3:0] error_code_r;
  logic [31:0] last_status_r;
  logic [31:0] active_cycles_r;

  logic write_state_c;
  logic [AXI_ADDR_W-1:0] write_addr_c;
  logic [31:0] write_data_c;
  logic [AXI_ADDR_W-1:0] status_addr_c;

  always_comb begin
    write_state_c = 1'b0;
    write_addr_c = DMA_BASE_ADDR;
    write_data_c = 32'd0;
    status_addr_c =
        DMA_BASE_ADDR + (direction_r ? AXI_ADDR_W'(32'h34)
                                    : AXI_ADDR_W'(32'h04));

    unique case (state_r)
      ST_WRITE_CONTROL: begin
        write_state_c = 1'b1;
        write_addr_c =
            DMA_BASE_ADDR + (direction_r ? AXI_ADDR_W'(32'h30)
                                        : AXI_ADDR_W'(32'h00));
        write_data_c = DMA_CONTROL_VALUE;
      end
      ST_CLEAR_STATUS: begin
        write_state_c = 1'b1;
        write_addr_c = status_addr_c;
        write_data_c = DMA_STATUS_CLEAR;
      end
      ST_WRITE_ADDRESS: begin
        write_state_c = 1'b1;
        write_addr_c =
            DMA_BASE_ADDR + (direction_r ? AXI_ADDR_W'(32'h48)
                                        : AXI_ADDR_W'(32'h18));
        write_data_c = buffer_addr_r;
      end
      ST_WRITE_LENGTH: begin
        write_state_c = 1'b1;
        write_addr_c =
            DMA_BASE_ADDR + (direction_r ? AXI_ADDR_W'(32'h58)
                                        : AXI_ADDR_W'(32'h28));
        write_data_c = 32'(length_r);
      end
      default: begin
      end
    endcase
  end

  always_comb begin
    cmd_ready = (state_r == ST_IDLE) && !error_r;
    busy = (state_r != ST_IDLE) && (state_r != ST_ERROR);
    error = error_r;
    error_code = error_code_r;
    last_status = last_status_r;
    active_cycles = active_cycles_r;
    state_debug = 4'(state_r);

    m_axi_awaddr = write_addr_c;
    m_axi_awprot = 3'b000;
    m_axi_awvalid = write_state_c && !aw_done_r;
    m_axi_wdata = write_data_c;
    m_axi_wstrb = 4'hf;
    m_axi_wvalid = write_state_c && !w_done_r;
    m_axi_bready = write_state_c && aw_done_r && w_done_r;

    m_axi_araddr = status_addr_c;
    m_axi_arprot = 3'b000;
    m_axi_arvalid = (state_r == ST_READ_STATUS_REQ);
    m_axi_rready = (state_r == ST_READ_STATUS_WAIT);
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state_r <= ST_IDLE;
      direction_r <= 1'b0;
      buffer_addr_r <= 32'd0;
      length_r <= '0;
      timeout_r <= DEFAULT_TIMEOUT;
      poll_count_r <= '0;
      aw_done_r <= 1'b0;
      w_done_r <= 1'b0;
      armed_seen_r <= 1'b0;
      armed <= 1'b0;
      done <= 1'b0;
      error_r <= 1'b0;
      error_code_r <= 4'd0;
      last_status_r <= 32'd0;
      active_cycles_r <= 32'd0;
    end else begin
      armed <= 1'b0;
      done <= 1'b0;

      if (clear_error) begin
        state_r <= ST_IDLE;
        aw_done_r <= 1'b0;
        w_done_r <= 1'b0;
        armed_seen_r <= 1'b0;
        error_r <= 1'b0;
        error_code_r <= 4'd0;
        last_status_r <= 32'd0;
        active_cycles_r <= 32'd0;
      end else if (armed_seen_r && busy &&
                   (active_cycles_r >= timeout_r - 1'b1)) begin
        state_r <= ST_ERROR;
        aw_done_r <= 1'b0;
        w_done_r <= 1'b0;
        error_r <= 1'b1;
        error_code_r <= 4'd5;
      end else begin
        if (busy)
          active_cycles_r <= active_cycles_r + 1'b1;

        if (write_state_c) begin
          if (m_axi_awvalid && m_axi_awready)
            aw_done_r <= 1'b1;
          if (m_axi_wvalid && m_axi_wready)
            w_done_r <= 1'b1;
        end

        unique case (state_r)
          ST_IDLE: begin
            aw_done_r <= 1'b0;
            w_done_r <= 1'b0;
            armed_seen_r <= 1'b0;
            if (cmd_valid && cmd_ready) begin
              direction_r <= cmd_s2mm;
              buffer_addr_r <= cmd_buffer_addr;
              length_r <= cmd_length_bytes;
              timeout_r <=
                  (cmd_timeout_cycles == 32'd0)
                      ? DEFAULT_TIMEOUT : cmd_timeout_cycles;
              active_cycles_r <= 32'd0;
              last_status_r <= 32'd0;
              if ((cmd_buffer_addr[3:0] != 4'd0) ||
                  (cmd_length_bytes == '0)) begin
                state_r <= ST_ERROR;
                error_r <= 1'b1;
                error_code_r <= 4'd1;
              end else begin
                state_r <= ST_WRITE_CONTROL;
              end
            end
          end

          ST_WRITE_CONTROL,
          ST_CLEAR_STATUS,
          ST_WRITE_ADDRESS,
          ST_WRITE_LENGTH: begin
            if (m_axi_bvalid && m_axi_bready) begin
              aw_done_r <= 1'b0;
              w_done_r <= 1'b0;
              if (m_axi_bresp != 2'b00) begin
                state_r <= ST_ERROR;
                error_r <= 1'b1;
                error_code_r <= 4'd2;
              end else begin
                unique case (state_r)
                  ST_WRITE_CONTROL: state_r <= ST_CLEAR_STATUS;
                  ST_CLEAR_STATUS: state_r <= ST_WRITE_ADDRESS;
                  ST_WRITE_ADDRESS: state_r <= ST_WRITE_LENGTH;
                  ST_WRITE_LENGTH: begin
                    armed <= 1'b1;
                    armed_seen_r <= 1'b1;
                    poll_count_r <= '0;
                    state_r <= ST_POLL_DELAY;
                  end
                  default: state_r <= ST_ERROR;
                endcase
              end
            end
          end

          ST_POLL_DELAY: begin
            if ((POLL_INTERVAL <= 1) ||
                (poll_count_r == POLL_COUNT_W'(POLL_INTERVAL - 1))) begin
              poll_count_r <= '0;
              state_r <= ST_READ_STATUS_REQ;
            end else begin
              poll_count_r <= poll_count_r + 1'b1;
            end
          end

          ST_READ_STATUS_REQ: begin
            if (m_axi_arvalid && m_axi_arready)
              state_r <= ST_READ_STATUS_WAIT;
          end

          ST_READ_STATUS_WAIT: begin
            if (m_axi_rvalid && m_axi_rready) begin
              last_status_r <= m_axi_rdata;
              if (m_axi_rresp != 2'b00) begin
                state_r <= ST_ERROR;
                error_r <= 1'b1;
                error_code_r <= 4'd3;
              end else if (|(m_axi_rdata & DMA_ERROR_MASK)) begin
                state_r <= ST_ERROR;
                error_r <= 1'b1;
                error_code_r <= 4'd4;
              end else if (m_axi_rdata[12]) begin
                done <= 1'b1;
                armed_seen_r <= 1'b0;
                state_r <= ST_IDLE;
              end else begin
                poll_count_r <= '0;
                state_r <= ST_POLL_DELAY;
              end
            end
          end

          ST_ERROR: begin
          end

          default: begin
            state_r <= ST_ERROR;
            error_r <= 1'b1;
            error_code_r <= 4'd4;
          end
        endcase
      end
    end
  end

`ifdef SIMULATION
  assert property (@(posedge clk) disable iff (!rst_n)
      (m_axi_awvalid && !m_axi_awready) |=>
          m_axi_awvalid && $stable({m_axi_awaddr, m_axi_awprot}));
  assert property (@(posedge clk) disable iff (!rst_n)
      (m_axi_wvalid && !m_axi_wready) |=>
          m_axi_wvalid && $stable({m_axi_wdata, m_axi_wstrb}));
  assert property (@(posedge clk) disable iff (!rst_n)
      (m_axi_arvalid && !m_axi_arready) |=>
          m_axi_arvalid && $stable({m_axi_araddr, m_axi_arprot}));
  assert property (@(posedge clk) disable iff (!rst_n)
      cmd_ready |-> !busy);
  assert property (@(posedge clk) disable iff (!rst_n)
      armed |-> busy);
  assert property (@(posedge clk) disable iff (!rst_n)
      done |-> !error);
`endif

endmodule
