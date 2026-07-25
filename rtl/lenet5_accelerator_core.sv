`timescale 1ns/1ps
// lenet5_accelerator_core.sv -- autonomous fixed-shape LeNet-5 accelerator.
//
// The top contains one shared 32-packed-DSP Conv/FC array, 16 requant DSP
// lanes, on-chip model storage, two 8-bank activation sets, parallel MaxPool,
// and the fixed ten-operation controller. External logic only preloads the
// model/input, asserts model_valid, and pulses start.

module lenet5_accelerator_core #(
  parameter int DATA_W          = 8,
  parameter int ACC_W           = 32,
  parameter int NG              = 4,
  parameter int NC              = 8,
  parameter int K               = 5,
  parameter int DIM_W           = 6,
  parameter int C_W             = 3,
  parameter int KOUT_W          = 9,
  parameter int WGT_MEM_DEPTH   = 2048,
  parameter int WGT_ADDR_W      = $clog2(WGT_MEM_DEPTH),
  parameter int OUT_ADDR_W      = 16,
  parameter int OUT_CH_W        = 8,
  parameter int LAYER_ID_W      = 3,
  parameter int SCALE_W         = 18,
  parameter int BANK_ADDR_W     = 9,
  parameter int BANK_DEPTH      = 1 << BANK_ADDR_W,
  parameter int TOTAL_PARAMS    = 236,
  parameter int PARAM_ADDR_W    = $clog2(TOTAL_PARAMS),
  parameter int LANE_COUNT      = 2 * NG * NC,
  parameter int LANE_ID_W       = $clog2(LANE_COUNT)
) (
  input  logic clk,
  input  logic rst_n,
  input  logic start,
  input  logic model_valid,

  output logic busy,
  output logic done,
  output logic irq,
  output logic result_set,
  output logic [3:0] op_index,
  output logic [31:0] busy_cycles,
  output logic [31:0] compute_cycles,
  output logic [31:0] pool_cycles,
  output logic [31:0] param_cycles,

  // 512-bit/cycle model-weight preload port.
  input  logic                         weight_host_wr_en [0:NC-1],
  input  logic [WGT_ADDR_W-1:0]        weight_host_wr_addr,
  input  logic [2*NG*DATA_W-1:0]       weight_host_wr_data [0:NC-1],

  // Logical bias/scale preload port.
  input  logic                         param_host_wr_en,
  input  logic [PARAM_ADDR_W-1:0]      param_host_wr_addr,
  input  logic signed [ACC_W-1:0]      param_host_wr_bias,
  input  logic signed [SCALE_W-1:0]    param_host_wr_scale,
  output logic                         model_host_ready,

  // 128-bit/cycle activation/result host port.
  input  logic                         activation_host_set,
  input  logic                         activation_host_en [0:NC-1],
  input  logic [1:0]                   activation_host_we [0:NC-1],
  input  logic [BANK_ADDR_W-1:0]       activation_host_addr [0:NC-1],
  input  logic [15:0]                  activation_host_wdata [0:NC-1],
  output logic [15:0]                  activation_host_rdata [0:NC-1],
  output logic                         activation_host_rvalid,
  output logic                         activation_host_ready
);

  logic [1:0] owner;
  logic read_set;
  logic write_set;
  logic compute_start;
  logic pool_start;
  logic param_load_start;

  logic cfg_fc_mode;
  logic [DIM_W-1:0] cfg_fmap_w;
  logic [DIM_W-1:0] cfg_fmap_h;
  logic [C_W-1:0] cfg_c_in;
  logic [DIM_W-1:0] cfg_out_w;
  logic [DIM_W-1:0] cfg_out_h;
  logic [KOUT_W-1:0] cfg_depth;
  logic [WGT_ADDR_W-1:0] weight_read_base;
  logic [OUT_ADDR_W-1:0] out_base_addr;
  logic [OUT_ADDR_W-1:0] out_plane_size;
  logic [OUT_CH_W-1:0] out_ch_base;
  logic [OUT_CH_W-1:0] out_channels;
  logic [OUT_CH_W-1:0] pass_channels;
  logic [LAYER_ID_W-1:0] layer_id;
  logic relu_en;
  logic [BANK_ADDR_W-1:0] cfg_bank_base_word;

  logic [DIM_W-1:0] conv_width;
  logic [DIM_W-1:0] conv_height;
  logic [OUT_CH_W-1:0] conv_channels;
  logic [BANK_ADDR_W-1:0] conv_base_word;
  logic [BANK_ADDR_W:0] conv_plane_words;

  logic fc_packed_layout;
  logic [KOUT_W-1:0] fc_length;
  logic [OUT_CH_W-1:0] fc_channels;
  logic [KOUT_W-1:0] fc_plane_bytes;
  logic [BANK_ADDR_W-1:0] fc_plane_words;
  logic [BANK_ADDR_W-1:0] fc_base_word;

  logic [DIM_W-1:0] pool_in_w;
  logic [DIM_W-1:0] pool_in_h;
  logic [OUT_CH_W-1:0] pool_channels;
  logic [BANK_ADDR_W-1:0] pool_in_base_word;
  logic [BANK_ADDR_W-1:0] pool_out_base_word;
  logic [BANK_ADDR_W-1:0] pool_in_plane_words;
  logic [BANK_ADDR_W-1:0] pool_out_plane_words;
  logic [PARAM_ADDR_W-1:0] param_base;

  logic core_busy;
  logic core_done;
  logic pool_busy;
  logic pool_done;
  logic param_busy;
  logic param_done;

  lenet_global_controller #(
    .DIM_W(DIM_W), .C_W(C_W), .KOUT_W(KOUT_W),
    .WGT_ADDR_W(WGT_ADDR_W), .OUT_ADDR_W(OUT_ADDR_W),
    .OUT_CH_W(OUT_CH_W), .LAYER_ID_W(LAYER_ID_W),
    .BANK_ADDR_W(BANK_ADDR_W), .PARAM_ADDR_W(PARAM_ADDR_W)
  ) u_controller (
    .clk(clk), .rst_n(rst_n), .start(start), .model_valid(model_valid),
    .compute_busy(core_busy), .compute_done(core_done),
    .pool_busy(pool_busy), .pool_done(pool_done),
    .param_busy(param_busy), .param_done(param_done),
    .owner(owner), .read_set(read_set), .write_set(write_set),
    .compute_start(compute_start), .pool_start(pool_start),
    .param_load_start(param_load_start),
    .cfg_fc_mode(cfg_fc_mode), .cfg_fmap_w(cfg_fmap_w),
    .cfg_fmap_h(cfg_fmap_h), .cfg_c_in(cfg_c_in),
    .cfg_out_w(cfg_out_w), .cfg_out_h(cfg_out_h),
    .cfg_depth(cfg_depth), .weight_read_base(weight_read_base),
    .out_base_addr(out_base_addr), .out_plane_size(out_plane_size),
    .out_ch_base(out_ch_base), .out_channels(out_channels),
    .pass_channels(pass_channels), .layer_id(layer_id),
    .relu_en(relu_en), .cfg_bank_base_word(cfg_bank_base_word),
    .conv_width(conv_width), .conv_height(conv_height),
    .conv_channels(conv_channels), .conv_base_word(conv_base_word),
    .conv_plane_words(conv_plane_words),
    .fc_packed_layout(fc_packed_layout), .fc_length(fc_length),
    .fc_channels(fc_channels), .fc_plane_bytes(fc_plane_bytes),
    .fc_plane_words(fc_plane_words), .fc_base_word(fc_base_word),
    .pool_in_w(pool_in_w), .pool_in_h(pool_in_h),
    .pool_channels(pool_channels),
    .pool_in_base_word(pool_in_base_word),
    .pool_out_base_word(pool_out_base_word),
    .pool_in_plane_words(pool_in_plane_words),
    .pool_out_plane_words(pool_out_plane_words),
    .param_base(param_base), .busy(busy), .done(done), .irq(irq),
    .result_set(result_set), .op_index(op_index),
    .busy_cycles(busy_cycles), .compute_cycles(compute_cycles),
    .pool_cycles(pool_cycles), .param_cycles(param_cycles)
  );

  logic param_host_ready_i;
  logic core_param_wr_en;
  logic [LANE_ID_W-1:0] core_param_wr_lane;
  logic signed [ACC_W-1:0] core_param_wr_bias;
  logic signed [SCALE_W-1:0] core_param_wr_scale;

  assign model_host_ready =
      (owner == 2'd0) && !busy && param_host_ready_i;
  assign activation_host_ready = (owner == 2'd0);

  lenet_param_loader #(
    .ACC_W(ACC_W), .SCALE_W(SCALE_W), .NG(NG), .NC(NC),
    .OUT_CH_W(OUT_CH_W), .TOTAL_PARAMS(TOTAL_PARAMS),
    .PARAM_ADDR_W(PARAM_ADDR_W)
  ) u_param_loader (
    .clk(clk), .rst_n(rst_n),
    .host_wr_en(param_host_wr_en && model_host_ready),
    .host_wr_addr(param_host_wr_addr),
    .host_wr_bias(param_host_wr_bias),
    .host_wr_scale(param_host_wr_scale),
    .host_ready(param_host_ready_i),
    .load_start(param_load_start), .cfg_fc_mode(cfg_fc_mode),
    .cfg_param_base(param_base), .cfg_out_ch_base(out_ch_base),
    .cfg_out_channels(out_channels),
    .cfg_pass_channels(pass_channels),
    .param_wr_en(core_param_wr_en),
    .param_wr_lane(core_param_wr_lane),
    .param_wr_bias(core_param_wr_bias),
    .param_wr_scale(core_param_wr_scale),
    .busy(param_busy), .done(param_done)
  );

  logic signed [DATA_W-1:0] core_pix_data;
  logic core_pix_valid;
  logic core_pix_consume;
  logic core_bank_we [0:NC-1];
  logic [BANK_ADDR_W-1:0] core_bank_addr [0:NC-1];
  logic [15:0] core_bank_wdata [0:NC-1];
  logic [1:0] core_bank_wstrb [0:NC-1];
  logic core_bank_ready [0:NC-1];

  logic core_weight_wr_en [0:NC-1];
  always_comb begin
    for (int c = 0; c < NC; c++)
      core_weight_wr_en[c] =
          weight_host_wr_en[c] && model_host_ready;
  end

  logic signed [ACC_W-1:0] debug_acc_lo [0:NG-1][0:NC-1];
  logic signed [ACC_W-1:0] debug_acc_hi [0:NG-1][0:NC-1];
  logic [1:0] debug_acc_valid [0:NG-1][0:NC-1];

  lenet_compute_core #(
    .DATA_W(DATA_W), .ACC_W(ACC_W), .NG(NG), .NC(NC), .K(K),
    .MAX_C_IN(6), .MAX_FMAP_W(32), .MAX_FMAP_H(32),
    .DIM_W(DIM_W), .C_W(C_W), .KOUT_W(KOUT_W),
    .MEM_DEPTH(WGT_MEM_DEPTH), .WGT_ADDR_W(WGT_ADDR_W),
    .OUT_ADDR_W(OUT_ADDR_W), .OUT_CH_W(OUT_CH_W),
    .LAYER_ID_W(LAYER_ID_W), .SCALE_W(SCALE_W),
    .BANK_ADDR_W(BANK_ADDR_W)
  ) u_compute (
    .clk(clk), .rst_n(rst_n), .en(1'b1), .start(compute_start),
    .cfg_fc_mode(cfg_fc_mode), .cfg_fmap_w(cfg_fmap_w),
    .cfg_fmap_h(cfg_fmap_h), .cfg_c_in(cfg_c_in),
    .cfg_out_w(cfg_out_w), .cfg_out_h(cfg_out_h),
    .cfg_depth(cfg_depth), .pix_in(core_pix_data),
    .pix_valid(core_pix_valid), .pix_rd_en(core_pix_consume),
    .weight_wr_en(core_weight_wr_en),
    .weight_wr_addr(weight_host_wr_addr),
    .weight_wr_data(weight_host_wr_data),
    .weight_read_base(weight_read_base),
    .out_base_addr(out_base_addr), .out_plane_size(out_plane_size),
    .out_ch_base(out_ch_base), .out_channels(out_channels),
    .pass_channels(pass_channels), .layer_id(layer_id),
    .param_wr_en(core_param_wr_en),
    .param_wr_lane(core_param_wr_lane),
    .param_wr_bias(core_param_wr_bias),
    .param_wr_scale(core_param_wr_scale), .relu_en(relu_en),
    .cfg_bank_base_word(cfg_bank_base_word),
    .bank_ready(core_bank_ready), .bank_we(core_bank_we),
    .bank_word_addr(core_bank_addr), .bank_wdata(core_bank_wdata),
    .bank_wstrb(core_bank_wstrb),
    .debug_acc_lo(debug_acc_lo), .debug_acc_hi(debug_acc_hi),
    .debug_acc_valid(debug_acc_valid),
    .busy(core_busy), .done(core_done)
  );

  activation_pingpong_subsystem #(
    .DATA_W(DATA_W), .NG(NG), .NC(NC),
    .ADDR_W(BANK_ADDR_W), .BANK_DEPTH(BANK_DEPTH),
    .DIM_W(DIM_W), .CHANNEL_W(OUT_CH_W), .KOUT_W(KOUT_W)
  ) u_activation (
    .clk(clk), .rst_n(rst_n), .owner(owner),
    .read_set(read_set), .write_set(write_set),
    .compute_start(compute_start), .compute_fc_mode(cfg_fc_mode),
    .core_pix_consume(core_pix_consume),
    .core_pix_data(core_pix_data), .core_pix_valid(core_pix_valid),
    .core_bank_we(core_bank_we), .core_bank_addr(core_bank_addr),
    .core_bank_wdata(core_bank_wdata),
    .core_bank_wstrb(core_bank_wstrb),
    .core_bank_ready(core_bank_ready),
    .conv_width(conv_width), .conv_height(conv_height),
    .conv_channels(conv_channels), .conv_base_word(conv_base_word),
    .conv_plane_words(conv_plane_words),
    .fc_packed_layout(fc_packed_layout), .fc_length(fc_length),
    .fc_channels(fc_channels), .fc_plane_bytes(fc_plane_bytes),
    .fc_plane_words(fc_plane_words), .fc_base_word(fc_base_word),
    .pool_start(pool_start), .pool_in_w(pool_in_w),
    .pool_in_h(pool_in_h), .pool_channels(pool_channels),
    .pool_in_base_word(pool_in_base_word),
    .pool_out_base_word(pool_out_base_word),
    .pool_in_plane_words(pool_in_plane_words),
    .pool_out_plane_words(pool_out_plane_words),
    .pool_busy(pool_busy), .pool_done(pool_done),
    .host_set(activation_host_set), .host_en(activation_host_en),
    .host_we(activation_host_we), .host_addr(activation_host_addr),
    .host_wdata(activation_host_wdata),
    .host_rdata(activation_host_rdata),
    .host_rvalid(activation_host_rvalid)
  );

`ifdef SIMULATION
  assert property (@(posedge clk) disable iff (!rst_n)
      start |-> (model_valid && model_host_ready &&
                 activation_host_ready));
  assert property (@(posedge clk) disable iff (!rst_n)
      busy |-> !(param_host_wr_en ||
                 (|activation_host_we[0]) ||
                 (|activation_host_we[1]) ||
                 (|activation_host_we[2]) ||
                 (|activation_host_we[3]) ||
                 (|activation_host_we[4]) ||
                 (|activation_host_we[5]) ||
                 (|activation_host_we[6]) ||
                 (|activation_host_we[7])));
`endif

endmodule
