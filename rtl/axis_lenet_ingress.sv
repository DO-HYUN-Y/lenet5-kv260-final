`timescale 1ns/1ps
// axis_lenet_ingress.sv -- 128-bit AXIS to LeNet host-port adapter.
//
// The AXIS source is the single shared MM2S channel. cfg_mode selects one
// destination per transfer. The module owns all unpacking and address advance;
// the accelerator core only sees its existing weight, parameter, and activation
// host ports.

module axis_lenet_ingress #(
  parameter int DATA_W          = 8,
  parameter int NG              = 4,
  parameter int NC              = 8,
  parameter int AXIS_W          = 128,
  parameter int AXIS_BYTES      = AXIS_W / 8,
  parameter int COUNT_W         = 16,
  parameter int BASE_W          = 16,
  parameter int WGT_ADDR_W      = 11,
  parameter int PARAM_ADDR_W    = 8,
  parameter int BANK_ADDR_W     = 9,
  parameter int ACC_W           = 32,
  parameter int SCALE_W         = 18,
  parameter int BANK_W          = (NC < 2) ? 1 : $clog2(NC),
  parameter int WEIGHT_WORD_W   = 2 * NG * DATA_W
) (
  input  logic clk,
  input  logic rst_n,
  input  logic start,
  input  logic clear_error,
  input  logic [1:0]             cfg_mode,
  input  logic [COUNT_W-1:0]     cfg_count,
  input  logic [BASE_W-1:0]      cfg_base,
  input  logic [BANK_W-1:0]      cfg_bank_base,
  input  logic                   cfg_activation_set,

  input  logic [AXIS_W-1:0]      s_axis_tdata,
  input  logic [AXIS_BYTES-1:0]  s_axis_tkeep,
  input  logic                   s_axis_tvalid,
  output logic                   s_axis_tready,
  input  logic                   s_axis_tlast,

  input  logic                   model_host_ready,
  output logic                   weight_host_wr_en [0:NC-1],
  output logic [WGT_ADDR_W-1:0]  weight_host_wr_addr,
  output logic [WEIGHT_WORD_W-1:0] weight_host_wr_data [0:NC-1],
  output logic                   param_host_wr_en,
  output logic [PARAM_ADDR_W-1:0] param_host_wr_addr,
  output logic signed [ACC_W-1:0] param_host_wr_bias,
  output logic signed [SCALE_W-1:0] param_host_wr_scale,

  input  logic                   activation_host_ready,
  output logic                   activation_host_set,
  output logic                   activation_host_en [0:NC-1],
  output logic [1:0]             activation_host_we [0:NC-1],
  output logic [BANK_ADDR_W-1:0] activation_host_addr [0:NC-1],
  output logic [15:0]            activation_host_wdata [0:NC-1],

  output logic                   busy,
  output logic                   done,
  output logic                   error
);

  localparam logic [1:0] MODE_WEIGHT = 2'd0;
  localparam logic [1:0] MODE_PARAM  = 2'd1;
  localparam logic [1:0] MODE_INPUT  = 2'd2;
  localparam logic [1:0] MODE_RESULT = 2'd3;

  logic addr_start;
  logic addr_advance;
  logic addr_busy;
  logic addr_valid;
  logic addr_last;
  logic addr_done;
  logic addr_error;
  logic [1:0] addr_mode;
  logic [COUNT_W-1:0] addr_index;
  logic [WGT_ADDR_W-1:0] addr_weight;
  logic [PARAM_ADDR_W-1:0] addr_param;
  logic [BANK_W-1:0] addr_bank;
  logic [BANK_ADDR_W-1:0] addr_bank_word;

  logic [COUNT_W-1:0] count_r;
  logic activation_set_r;
  logic protocol_error_r;

  logic [1:0] weight_beat_r;
  logic [4*AXIS_W-1:0] weight_assembly_r;
  logic [4*AXIS_W-1:0] weight_commit_data_c;
  logic weight_fire_c;
  logic weight_commit_c;

  logic [AXIS_W-1:0] param_buffer_r;
  logic param_buffer_valid_r;
  logic param_record_sel_r;
  logic [1:0] param_records_r;
  logic param_stream_fire_c;
  logic param_emit_c;
  logic [63:0] param_record_c;

  logic [AXIS_W-1:0] activation_buffer_r;
  logic activation_buffer_valid_r;
  logic [2:0] activation_word_sel_r;
  logic [3:0] activation_words_r;
  logic activation_stream_fire_c;
  logic activation_emit_c;

  assign addr_start = start && (cfg_mode != MODE_RESULT);

  lenet_dma_addr_gen #(
    .NC(NC), .COUNT_W(COUNT_W), .BASE_W(BASE_W),
    .WGT_ADDR_W(WGT_ADDR_W), .PARAM_ADDR_W(PARAM_ADDR_W),
    .BANK_ADDR_W(BANK_ADDR_W), .BANK_W(BANK_W)
  ) u_addr_gen (
    .clk(clk), .rst_n(rst_n), .start(addr_start),
    .clear_error(clear_error), .advance(addr_advance),
    .cfg_mode(cfg_mode), .cfg_count(cfg_count), .cfg_base(cfg_base),
    .cfg_bank_base(cfg_bank_base), .busy(addr_busy),
    .valid(addr_valid), .last(addr_last), .done(addr_done),
    .error(addr_error), .mode(addr_mode), .unit_index(addr_index),
    .weight_addr(addr_weight), .param_addr(addr_param),
    .bank_index(addr_bank), .bank_word_addr(addr_bank_word)
  );

  always_comb begin
    s_axis_tready = 1'b0;
    weight_fire_c = 1'b0;
    weight_commit_c = 1'b0;
    param_stream_fire_c = 1'b0;
    param_emit_c = 1'b0;
    activation_stream_fire_c = 1'b0;
    activation_emit_c = 1'b0;
    addr_advance = 1'b0;

    weight_commit_data_c = weight_assembly_r;
    if (addr_valid && (addr_mode == MODE_WEIGHT)) begin
      s_axis_tready =
          (weight_beat_r != 2'd3) || model_host_ready;
      weight_fire_c = s_axis_tvalid && s_axis_tready;
      weight_commit_c = weight_fire_c && (weight_beat_r == 2'd3);
      weight_commit_data_c =
          {s_axis_tdata, weight_assembly_r[3*AXIS_W-1:0]};
      addr_advance = weight_commit_c;
    end else if (addr_valid && (addr_mode == MODE_PARAM)) begin
      s_axis_tready = !param_buffer_valid_r;
      param_stream_fire_c = s_axis_tvalid && s_axis_tready;
      param_emit_c = param_buffer_valid_r && model_host_ready;
      addr_advance = param_emit_c;
    end else if (addr_valid && (addr_mode == MODE_INPUT)) begin
      s_axis_tready = !activation_buffer_valid_r;
      activation_stream_fire_c = s_axis_tvalid && s_axis_tready;
      activation_emit_c =
          activation_buffer_valid_r && activation_host_ready;
      addr_advance = activation_emit_c;
    end

    param_record_c =
        param_record_sel_r ? param_buffer_r[127:64]
                           : param_buffer_r[63:0];
  end

  always_comb begin
    weight_host_wr_addr = addr_weight;
    param_host_wr_en = param_emit_c;
    param_host_wr_addr = addr_param;
    param_host_wr_bias = $signed(param_record_c[31:0]);
    param_host_wr_scale = $signed(param_record_c[49:32]);
    activation_host_set = activation_set_r;

    for (int c = 0; c < NC; c++) begin
      weight_host_wr_en[c] = weight_commit_c;
      weight_host_wr_data[c] =
          weight_commit_data_c[c*WEIGHT_WORD_W +: WEIGHT_WORD_W];
      activation_host_en[c] =
          activation_emit_c && (addr_bank == BANK_W'(c));
      activation_host_we[c] =
          activation_host_en[c] ? 2'b11 : 2'b00;
      activation_host_addr[c] = addr_bank_word;
      activation_host_wdata[c] =
          activation_buffer_r[
              activation_word_sel_r*16 +: 16
          ];
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      count_r <= COUNT_W'(1);
      activation_set_r <= 1'b0;
      protocol_error_r <= 1'b0;
      weight_beat_r <= '0;
      weight_assembly_r <= '0;
      param_buffer_r <= '0;
      param_buffer_valid_r <= 1'b0;
      param_record_sel_r <= 1'b0;
      param_records_r <= '0;
      activation_buffer_r <= '0;
      activation_buffer_valid_r <= 1'b0;
      activation_word_sel_r <= '0;
      activation_words_r <= '0;
    end else begin
      if (clear_error)
        protocol_error_r <= 1'b0;

      if (start) begin
        if (cfg_mode == MODE_RESULT)
          protocol_error_r <= 1'b1;
        if (!addr_busy && (cfg_mode != MODE_RESULT)) begin
          count_r <=
              (cfg_count == '0) ? COUNT_W'(1) : cfg_count;
          activation_set_r <= cfg_activation_set;
          weight_beat_r <= '0;
          weight_assembly_r <= '0;
          param_buffer_valid_r <= 1'b0;
          param_record_sel_r <= 1'b0;
          param_records_r <= '0;
          activation_buffer_valid_r <= 1'b0;
          activation_word_sel_r <= '0;
          activation_words_r <= '0;
        end
      end

      if (weight_fire_c) begin
        weight_assembly_r[
            weight_beat_r*AXIS_W +: AXIS_W
        ] <= s_axis_tdata;
        if (s_axis_tkeep != {AXIS_BYTES{1'b1}})
          protocol_error_r <= 1'b1;
        if (s_axis_tlast != (addr_last && (weight_beat_r == 2'd3)))
          protocol_error_r <= 1'b1;
        if (weight_beat_r == 2'd3)
          weight_beat_r <= '0;
        else
          weight_beat_r <= weight_beat_r + 1'b1;
      end

      if (param_stream_fire_c) begin
        logic [COUNT_W-1:0] remaining;
        logic [1:0] records;
        logic [AXIS_BYTES-1:0] expected_keep;
        remaining = count_r - addr_index;
        records = (remaining >= COUNT_W'(2)) ? 2 : 1;
        expected_keep =
            (records == 2) ? {AXIS_BYTES{1'b1}} : 16'h00ff;
        param_buffer_r <= s_axis_tdata;
        param_buffer_valid_r <= 1'b1;
        param_record_sel_r <= 1'b0;
        param_records_r <= records;
        if (s_axis_tkeep != expected_keep)
          protocol_error_r <= 1'b1;
        if (s_axis_tlast != (remaining <= COUNT_W'(2)))
          protocol_error_r <= 1'b1;
      end else if (param_emit_c) begin
        if (param_record_sel_r == param_records_r - 1'b1) begin
          param_buffer_valid_r <= 1'b0;
          param_record_sel_r <= 1'b0;
        end else begin
          param_record_sel_r <= param_record_sel_r + 1'b1;
        end
      end

      if (activation_stream_fire_c) begin
        logic [COUNT_W-1:0] remaining;
        logic [3:0] words;
        logic [AXIS_BYTES-1:0] expected_keep;
        remaining = count_r - addr_index;
        words = (remaining >= COUNT_W'(8)) ? 4'd8
                                                   : 4'(remaining);
        expected_keep = '0;
        for (int b = 0; b < AXIS_BYTES; b++) begin
          if (b < 2 * words)
            expected_keep[b] = 1'b1;
        end
        activation_buffer_r <= s_axis_tdata;
        activation_buffer_valid_r <= 1'b1;
        activation_word_sel_r <= '0;
        activation_words_r <= words;
        if (s_axis_tkeep != expected_keep)
          protocol_error_r <= 1'b1;
        if (s_axis_tlast != (remaining <= COUNT_W'(8)))
          protocol_error_r <= 1'b1;
      end else if (activation_emit_c) begin
        if (activation_word_sel_r == activation_words_r - 1'b1) begin
          activation_buffer_valid_r <= 1'b0;
          activation_word_sel_r <= '0;
        end else begin
          activation_word_sel_r <= activation_word_sel_r + 1'b1;
        end
      end
    end
  end

  assign busy = addr_busy;
  assign done = addr_done;
  assign error = addr_error || protocol_error_r;

`ifdef SIMULATION
  assert property (@(posedge clk) disable iff (!rst_n)
      (s_axis_tvalid && !s_axis_tready) |=> $stable({
        s_axis_tdata, s_axis_tkeep, s_axis_tlast
      }));
  assert property (@(posedge clk) disable iff (!rst_n)
      weight_commit_c |-> model_host_ready);
  assert property (@(posedge clk) disable iff (!rst_n)
      param_emit_c |-> model_host_ready);
  assert property (@(posedge clk) disable iff (!rst_n)
      activation_emit_c |-> activation_host_ready);
  assert property (@(posedge clk) disable iff (!rst_n)
      !(weight_commit_c && (param_emit_c || activation_emit_c)));
  assert property (@(posedge clk) disable iff (!rst_n)
      !(param_emit_c && activation_emit_c));
`endif

endmodule
