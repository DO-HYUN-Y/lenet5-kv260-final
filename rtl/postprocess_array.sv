`timescale 1ns/1ps
// postprocess_array.sv -- eight column-aligned dual-scalar postprocessors.
//
// A compact sequential parameter preload port fills 64 physical lane slots.
// Conv passes duplicate one output-channel parameter across the four groups
// and two packed lanes. FC passes load distinct parameters for every lane.

module postprocess_array #(
  parameter int ACC_W        = 32,
  parameter int NG           = 4,
  parameter int NC           = 8,
  parameter int SCALE_W      = 18,
  parameter int OUT_ADDR_W   = 16,
  parameter int OUT_CH_W     = 8,
  parameter int LAYER_ID_W   = 3,
  parameter int GROUP_W      = (NG < 2) ? 1 : $clog2(NG),
  parameter int LANE_COUNT   = 2 * NG * NC,
  parameter int LANE_ID_W    = (LANE_COUNT < 2) ? 1 : $clog2(LANE_COUNT)
) (
  input  logic clk,
  input  logic rst_n,
  input  logic flush,

  input  logic                    param_wr_en,
  input  logic [LANE_ID_W-1:0]    param_wr_lane,
  input  logic signed [ACC_W-1:0] param_wr_bias,
  input  logic signed [SCALE_W-1:0] param_wr_scale,
  input  logic                    cfg_relu_en,

  input  logic                    in_valid [0:NC-1],
  output logic                    in_ready [0:NC-1],
  input  logic signed [ACC_W-1:0] in_acc_lo [0:NC-1],
  input  logic signed [ACC_W-1:0] in_acc_hi [0:NC-1],
  input  logic [1:0]              in_lane_mask [0:NC-1],
  input  logic [OUT_ADDR_W-1:0]   in_addr_lo [0:NC-1],
  input  logic [OUT_ADDR_W-1:0]   in_addr_hi [0:NC-1],
  input  logic [OUT_CH_W-1:0]     in_channel_lo [0:NC-1],
  input  logic [OUT_CH_W-1:0]     in_channel_hi [0:NC-1],
  input  logic [GROUP_W-1:0]      in_group [0:NC-1],
  input  logic                    in_fc_mode [0:NC-1],
  input  logic [LAYER_ID_W-1:0]   in_layer_id [0:NC-1],

  output logic                    out_valid [0:NC-1],
  input  logic                    out_ready [0:NC-1],
  output logic [15:0]             out_data [0:NC-1],
  output logic [1:0]              out_lane_mask [0:NC-1],
  output logic [OUT_ADDR_W-1:0]   out_addr_lo [0:NC-1],
  output logic [OUT_ADDR_W-1:0]   out_addr_hi [0:NC-1],
  output logic [OUT_CH_W-1:0]     out_channel_lo [0:NC-1],
  output logic [OUT_CH_W-1:0]     out_channel_hi [0:NC-1],
  output logic [GROUP_W-1:0]      out_group [0:NC-1],
  output logic                    out_fc_mode [0:NC-1],
  output logic [LAYER_ID_W-1:0]   out_layer_id [0:NC-1],
  output logic                    idle
);

  logic signed [ACC_W-1:0] bias_r [0:LANE_COUNT-1];
  logic signed [SCALE_W-1:0] scale_r [0:LANE_COUNT-1];
  logic signed [ACC_W-1:0] bias_lo_c [0:NC-1];
  logic signed [ACC_W-1:0] bias_hi_c [0:NC-1];
  logic signed [SCALE_W-1:0] scale_lo_c [0:NC-1];
  logic signed [SCALE_W-1:0] scale_hi_c [0:NC-1];
  logic lane_idle [0:NC-1];

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      for (int i = 0; i < LANE_COUNT; i++) begin
        bias_r[i] <= '0;
        scale_r[i] <= '0;
      end
    end else if (param_wr_en) begin
      bias_r[param_wr_lane] <= param_wr_bias;
      scale_r[param_wr_lane] <= param_wr_scale;
    end
  end

  always_comb begin
    for (int c = 0; c < NC; c++) begin
      int lane_base;
      lane_base = int'(in_group[c]) * (2 * NC) + (2 * c);
      bias_lo_c[c] = bias_r[lane_base];
      bias_hi_c[c] = bias_r[lane_base + 1];
      scale_lo_c[c] = scale_r[lane_base];
      scale_hi_c[c] = scale_r[lane_base + 1];
    end
  end

  generate
    for (genvar c = 0; c < NC; c++) begin : g_post_col
      dual_lane_postprocess #(
        .ACC_W(ACC_W), .SCALE_W(SCALE_W),
        .OUT_ADDR_W(OUT_ADDR_W), .OUT_CH_W(OUT_CH_W),
        .GROUP_W(GROUP_W), .LAYER_ID_W(LAYER_ID_W)
      ) u_postprocess (
        .clk(clk), .rst_n(rst_n), .flush(flush),
        .in_valid(in_valid[c]), .in_ready(in_ready[c]),
        .in_acc_lo(in_acc_lo[c]), .in_acc_hi(in_acc_hi[c]),
        .in_lane_mask(in_lane_mask[c]),
        .in_bias_lo(bias_lo_c[c]), .in_bias_hi(bias_hi_c[c]),
        .in_scale_lo(scale_lo_c[c]), .in_scale_hi(scale_hi_c[c]),
        .in_relu_en(cfg_relu_en),
        .in_addr_lo(in_addr_lo[c]), .in_addr_hi(in_addr_hi[c]),
        .in_channel_lo(in_channel_lo[c]),
        .in_channel_hi(in_channel_hi[c]), .in_group(in_group[c]),
        .in_fc_mode(in_fc_mode[c]), .in_layer_id(in_layer_id[c]),
        .out_valid(out_valid[c]), .out_ready(out_ready[c]),
        .out_data(out_data[c]), .out_lane_mask(out_lane_mask[c]),
        .out_addr_lo(out_addr_lo[c]), .out_addr_hi(out_addr_hi[c]),
        .out_channel_lo(out_channel_lo[c]),
        .out_channel_hi(out_channel_hi[c]), .out_group(out_group[c]),
        .out_fc_mode(out_fc_mode[c]), .out_layer_id(out_layer_id[c]),
        .idle(lane_idle[c])
      );
    end
  endgenerate

  always_comb begin
    idle = 1'b1;
    for (int c = 0; c < NC; c++) idle = idle && lane_idle[c];
  end

`ifdef SIMULATION
  assert property (@(posedge clk) disable iff (!rst_n)
      param_wr_en |-> (param_wr_lane < LANE_COUNT));
`endif

endmodule
