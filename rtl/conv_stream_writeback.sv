`timescale 1ns/1ps
// conv_stream_writeback.sv -- conv/FC stream core plus eight-bank adapter.

module conv_stream_writeback #(
  parameter int ACT_W          = 8,
  parameter int WGT_W          = 8,
  parameter int ACC_W          = 32,
  parameter int NG             = 4,
  parameter int NC             = 8,
  parameter int C_IN           = 2,
  parameter int FMAP_W         = 13,
  parameter int FMAP_H         = 13,
  parameter int K              = 5,
  parameter int OUT_W          = FMAP_W - K + 1,
  parameter int OUT_H          = FMAP_H - K + 1,
  parameter int PREFETCH_ROWS  = 2,
  parameter int DEPTH          = K * K * C_IN,
  parameter int MEM_DEPTH      = 2048,
  parameter int ADDR_W         = $clog2(MEM_DEPTH),
  parameter int OUT_ADDR_W     = 16,
  parameter int OUT_CH_W       = 8,
  parameter int LAYER_ID_W     = 3,
  parameter int SCALE_W        = 18,
  parameter int BANK_ADDR_W    = 9,
  parameter int LANE_COUNT     = 2 * NG * NC,
  parameter int LANE_ID_W      =
      (LANE_COUNT < 2) ? 1 : $clog2(LANE_COUNT)
) (
  input  logic clk,
  input  logic rst_n,
  input  logic en,
  input  logic start,

  input  logic signed [ACT_W-1:0] pix_in,
  output logic                    pix_rd_en,

  input  logic                    wr_en,
  input  logic [ADDR_W-1:0]       wr_addr,
  input  logic signed [WGT_W-1:0] wr_data [0:NC-1],
  input  logic [ADDR_W-1:0]       base_layer,
  input  logic [ADDR_W-1:0]       pass_idx,

  input  logic [OUT_ADDR_W-1:0] out_base_addr,
  input  logic [OUT_CH_W-1:0]   out_ch_base,
  input  logic [OUT_CH_W-1:0]   out_channels,
  input  logic                  fc_mode,
  input  logic [LAYER_ID_W-1:0] layer_id,

  input  logic                      param_wr_en,
  input  logic [LANE_ID_W-1:0]      param_wr_lane,
  input  logic signed [ACC_W-1:0]   param_wr_bias,
  input  logic signed [SCALE_W-1:0] param_wr_scale,
  input  logic                      relu_en,

  input  logic [BANK_ADDR_W-1:0] cfg_bank_base_word,
  input  logic                   bank_ready [0:NC-1],
  output logic                   bank_we [0:NC-1],
  output logic [BANK_ADDR_W-1:0] bank_word_addr [0:NC-1],
  output logic [15:0]            bank_wdata [0:NC-1],
  output logic [1:0]             bank_wstrb [0:NC-1],

  output logic done
);

  logic signed [ACC_W-1:0] unused_acc_lo [0:NG-1][0:NC-1];
  logic signed [ACC_W-1:0] unused_acc_hi [0:NG-1][0:NC-1];
  logic [1:0] unused_acc_valid [0:NG-1][0:NC-1];
  logic result_valid [0:NC-1];
  logic result_ready [0:NC-1];
  logic [15:0] result_data [0:NC-1];
  logic [1:0] result_lane_mask [0:NC-1];
  logic [OUT_ADDR_W-1:0] result_addr_lo [0:NC-1];
  logic [OUT_ADDR_W-1:0] result_addr_hi [0:NC-1];
  logic [OUT_CH_W-1:0] unused_channel_lo [0:NC-1];
  logic [OUT_CH_W-1:0] unused_channel_hi [0:NC-1];
  logic [$clog2(NG)-1:0] unused_group [0:NC-1];
  logic unused_fc_mode [0:NC-1];
  logic [LAYER_ID_W-1:0] unused_layer_id [0:NC-1];

  conv_stream_datapath #(
    .ACT_W(ACT_W), .WGT_W(WGT_W), .ACC_W(ACC_W),
    .NG(NG), .NC(NC), .C_IN(C_IN),
    .FMAP_W(FMAP_W), .FMAP_H(FMAP_H), .K(K),
    .OUT_W(OUT_W), .OUT_H(OUT_H),
    .PREFETCH_ROWS(PREFETCH_ROWS), .DEPTH(DEPTH),
    .MEM_DEPTH(MEM_DEPTH), .ADDR_W(ADDR_W),
    .OUT_ADDR_W(OUT_ADDR_W), .OUT_CH_W(OUT_CH_W),
    .LAYER_ID_W(LAYER_ID_W), .SCALE_W(SCALE_W)
  ) u_conv_stream (
    .clk(clk), .rst_n(rst_n), .en(en), .start(start),
    .pix_in(pix_in), .pix_rd_en(pix_rd_en),
    .wr_en(wr_en), .wr_addr(wr_addr), .wr_data(wr_data),
    .base_layer(base_layer), .pass_idx(pass_idx),
    .out_base_addr(out_base_addr), .out_ch_base(out_ch_base),
    .out_channels(out_channels), .fc_mode(fc_mode), .layer_id(layer_id),
    .param_wr_en(param_wr_en), .param_wr_lane(param_wr_lane),
    .param_wr_bias(param_wr_bias), .param_wr_scale(param_wr_scale),
    .relu_en(relu_en),
    .acc_lo_out(unused_acc_lo), .acc_hi_out(unused_acc_hi),
    .acc_valid(unused_acc_valid),
    .result_valid(result_valid), .result_ready(result_ready),
    .result_data(result_data), .result_lane_mask(result_lane_mask),
    .result_addr_lo(result_addr_lo), .result_addr_hi(result_addr_hi),
    .result_channel_lo(unused_channel_lo),
    .result_channel_hi(unused_channel_hi),
    .result_group(unused_group), .result_fc_mode(unused_fc_mode),
    .result_layer_id(unused_layer_id), .done(done)
  );

  banked_activation_writer #(
    .NC(NC), .BYTE_ADDR_W(OUT_ADDR_W), .WORD_ADDR_W(BANK_ADDR_W)
  ) u_banked_writer (
    .clk(clk), .rst_n(rst_n), .start(start),
    .cfg_bank_base_word(cfg_bank_base_word),
    .in_valid(result_valid), .in_ready(result_ready),
    .in_data(result_data), .in_lane_mask(result_lane_mask),
    .in_addr_lo(result_addr_lo), .in_addr_hi(result_addr_hi),
    .bank_we(bank_we), .bank_ready(bank_ready),
    .bank_word_addr(bank_word_addr), .bank_wdata(bank_wdata),
    .bank_wstrb(bank_wstrb)
  );

endmodule
