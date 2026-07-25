`timescale 1ns/1ps
// dual_lane_postprocess.sv -- two independent scalar requantization lanes.
//
// Each accepted packet carries the finalized INT32 acc_lo/acc_hi values from
// one packed PE. The two lanes use independent bias and scale parameters so
// the same block supports shared-channel convolution pairs and distinct FC
// output-channel pairs. The rigid pipeline accepts one packet per cycle.

module dual_lane_postprocess #(
  parameter int ACC_W       = 32,
  parameter int MUL_IN_W    = 27,
  parameter int SCALE_W     = 18,
  parameter int SCALE_SHIFT = 17,
  parameter int OUT_ADDR_W  = 16,
  parameter int OUT_CH_W    = 8,
  parameter int GROUP_W     = 2,
  parameter int LAYER_ID_W  = 3
) (
  input  logic clk,
  input  logic rst_n,
  input  logic flush,

  input  logic                    in_valid,
  output logic                    in_ready,
  input  logic signed [ACC_W-1:0] in_acc_lo,
  input  logic signed [ACC_W-1:0] in_acc_hi,
  input  logic [1:0]              in_lane_mask,
  input  logic signed [ACC_W-1:0] in_bias_lo,
  input  logic signed [ACC_W-1:0] in_bias_hi,
  input  logic signed [SCALE_W-1:0] in_scale_lo,
  input  logic signed [SCALE_W-1:0] in_scale_hi,
  input  logic                    in_relu_en,
  input  logic [OUT_ADDR_W-1:0]   in_addr_lo,
  input  logic [OUT_ADDR_W-1:0]   in_addr_hi,
  input  logic [OUT_CH_W-1:0]     in_channel_lo,
  input  logic [OUT_CH_W-1:0]     in_channel_hi,
  input  logic [GROUP_W-1:0]      in_group,
  input  logic                    in_fc_mode,
  input  logic [LAYER_ID_W-1:0]   in_layer_id,

  output logic                    out_valid,
  input  logic                    out_ready,
  output logic [15:0]             out_data,
  output logic [1:0]              out_lane_mask,
  output logic [OUT_ADDR_W-1:0]   out_addr_lo,
  output logic [OUT_ADDR_W-1:0]   out_addr_hi,
  output logic [OUT_CH_W-1:0]     out_channel_lo,
  output logic [OUT_CH_W-1:0]     out_channel_hi,
  output logic [GROUP_W-1:0]      out_group,
  output logic                    out_fc_mode,
  output logic [LAYER_ID_W-1:0]   out_layer_id,
  output logic                    idle
);

  localparam int MUL_W = MUL_IN_W + SCALE_W;
  localparam logic signed [MUL_IN_W-1:0] MUL_MAX_N =
      {1'b0, {(MUL_IN_W-1){1'b1}}};
  localparam logic signed [MUL_IN_W-1:0] MUL_MIN_N =
      {1'b1, {(MUL_IN_W-1){1'b0}}};

  function automatic logic signed [MUL_IN_W-1:0] prepare_acc(
      input logic signed [ACC_W-1:0] acc_value,
      input logic signed [ACC_W-1:0] bias_value,
      input logic relu_enable
  );
    logic signed [ACC_W:0] sum_wide;
    logic signed [ACC_W:0] active_wide;
    logic signed [ACC_W:0] max_wide;
    logic signed [ACC_W:0] min_wide;
    begin
      sum_wide = $signed({acc_value[ACC_W-1], acc_value}) +
                 $signed({bias_value[ACC_W-1], bias_value});
      if (relu_enable && sum_wide[ACC_W])
        active_wide = '0;
      else
        active_wide = sum_wide;

      max_wide = {{(ACC_W+1-MUL_IN_W){MUL_MAX_N[MUL_IN_W-1]}},
                  MUL_MAX_N};
      min_wide = {{(ACC_W+1-MUL_IN_W){MUL_MIN_N[MUL_IN_W-1]}},
                  MUL_MIN_N};
      if (active_wide > max_wide)
        prepare_acc = MUL_MAX_N;
      else if (active_wide < min_wide)
        prepare_acc = MUL_MIN_N;
      else
        prepare_acc = active_wide[MUL_IN_W-1:0];
    end
  endfunction

  function automatic logic signed [7:0] requantize(
      input logic signed [MUL_W-1:0] product
  );
    logic negative;
    logic signed [MUL_W:0] product_wide;
    logic [MUL_W:0] magnitude;
    logic [MUL_W:0] rounding;
    logic [MUL_W:0] rounded_magnitude;
    logic [MUL_W:0] shifted_magnitude;
    logic signed [MUL_W:0] shifted_signed;
    begin
      negative = product[MUL_W-1];
      product_wide = {product[MUL_W-1], product};
      magnitude = negative ? $unsigned(-product_wide) :
                             $unsigned(product_wide);
      rounding = '0;
      rounding[SCALE_SHIFT-1] = 1'b1;
      rounded_magnitude = magnitude + rounding;
      shifted_magnitude = rounded_magnitude >> SCALE_SHIFT;
      shifted_signed = negative ? -$signed(shifted_magnitude) :
                                  $signed(shifted_magnitude);

      if (shifted_signed > 127)
        requantize = 8'sd127;
      else if (shifted_signed < -128)
        requantize = -8'sd128;
      else
        requantize = shifted_signed[7:0];
    end
  endfunction

  logic pipe_ce;
  logic pre_valid_r;
  logic signed [ACC_W-1:0] pre_acc_lo_r;
  logic signed [ACC_W-1:0] pre_acc_hi_r;
  logic signed [ACC_W-1:0] pre_bias_lo_r;
  logic signed [ACC_W-1:0] pre_bias_hi_r;
  logic signed [SCALE_W-1:0] pre_scale_lo_r;
  logic signed [SCALE_W-1:0] pre_scale_hi_r;
  logic pre_relu_en_r;
  logic [1:0] pre_mask_r;
  logic [OUT_ADDR_W-1:0] pre_addr_lo_r, pre_addr_hi_r;
  logic [OUT_CH_W-1:0] pre_channel_lo_r, pre_channel_hi_r;
  logic [GROUP_W-1:0] pre_group_r;
  logic pre_fc_mode_r;
  logic [LAYER_ID_W-1:0] pre_layer_id_r;

  logic s0_valid_r;
  logic signed [MUL_IN_W-1:0] s0_value_lo_r;
  logic signed [MUL_IN_W-1:0] s0_value_hi_r;
  logic signed [SCALE_W-1:0] s0_scale_lo_r;
  logic signed [SCALE_W-1:0] s0_scale_hi_r;
  logic [1:0] s0_mask_r;
  logic [OUT_ADDR_W-1:0] s0_addr_lo_r, s0_addr_hi_r;
  logic [OUT_CH_W-1:0] s0_channel_lo_r, s0_channel_hi_r;
  logic [GROUP_W-1:0] s0_group_r;
  logic s0_fc_mode_r;
  logic [LAYER_ID_W-1:0] s0_layer_id_r;

  logic s1_valid_r;
  (* use_dsp = "yes" *) logic signed [MUL_W-1:0] s1_product_lo_r;
  (* use_dsp = "yes" *) logic signed [MUL_W-1:0] s1_product_hi_r;
  logic [1:0] s1_mask_r;
  logic [OUT_ADDR_W-1:0] s1_addr_lo_r, s1_addr_hi_r;
  logic [OUT_CH_W-1:0] s1_channel_lo_r, s1_channel_hi_r;
  logic [GROUP_W-1:0] s1_group_r;
  logic s1_fc_mode_r;
  logic [LAYER_ID_W-1:0] s1_layer_id_r;

  logic out_valid_r;
  logic [15:0] out_data_r;
  logic [1:0] out_mask_r;
  logic [OUT_ADDR_W-1:0] out_addr_lo_r, out_addr_hi_r;
  logic [OUT_CH_W-1:0] out_channel_lo_r, out_channel_hi_r;
  logic [GROUP_W-1:0] out_group_r;
  logic out_fc_mode_r;
  logic [LAYER_ID_W-1:0] out_layer_id_r;

  assign pipe_ce = !out_valid_r || out_ready;
  assign in_ready = pipe_ce;
  assign out_valid = out_valid_r;
  assign out_data = out_data_r;
  assign out_lane_mask = out_mask_r;
  assign out_addr_lo = out_addr_lo_r;
  assign out_addr_hi = out_addr_hi_r;
  assign out_channel_lo = out_channel_lo_r;
  assign out_channel_hi = out_channel_hi_r;
  assign out_group = out_group_r;
  assign out_fc_mode = out_fc_mode_r;
  assign out_layer_id = out_layer_id_r;
  assign idle =
      !(pre_valid_r || s0_valid_r || s1_valid_r || out_valid_r);

  always_ff @(posedge clk) begin
    if (!rst_n || flush) begin
      pre_valid_r <= 1'b0;
      pre_acc_lo_r <= '0;
      pre_acc_hi_r <= '0;
      pre_bias_lo_r <= '0;
      pre_bias_hi_r <= '0;
      pre_scale_lo_r <= '0;
      pre_scale_hi_r <= '0;
      pre_relu_en_r <= 1'b0;
      pre_mask_r <= '0;
      pre_addr_lo_r <= '0;
      pre_addr_hi_r <= '0;
      pre_channel_lo_r <= '0;
      pre_channel_hi_r <= '0;
      pre_group_r <= '0;
      pre_fc_mode_r <= 1'b0;
      pre_layer_id_r <= '0;

      s0_valid_r <= 1'b0;
      s0_value_lo_r <= '0;
      s0_value_hi_r <= '0;
      s0_scale_lo_r <= '0;
      s0_scale_hi_r <= '0;
      s0_mask_r <= '0;
      s0_addr_lo_r <= '0;
      s0_addr_hi_r <= '0;
      s0_channel_lo_r <= '0;
      s0_channel_hi_r <= '0;
      s0_group_r <= '0;
      s0_fc_mode_r <= 1'b0;
      s0_layer_id_r <= '0;

      s1_valid_r <= 1'b0;
      s1_product_lo_r <= '0;
      s1_product_hi_r <= '0;
      s1_mask_r <= '0;
      s1_addr_lo_r <= '0;
      s1_addr_hi_r <= '0;
      s1_channel_lo_r <= '0;
      s1_channel_hi_r <= '0;
      s1_group_r <= '0;
      s1_fc_mode_r <= 1'b0;
      s1_layer_id_r <= '0;

      out_valid_r <= 1'b0;
      out_data_r <= '0;
      out_mask_r <= '0;
      out_addr_lo_r <= '0;
      out_addr_hi_r <= '0;
      out_channel_lo_r <= '0;
      out_channel_hi_r <= '0;
      out_group_r <= '0;
      out_fc_mode_r <= 1'b0;
      out_layer_id_r <= '0;
    end else if (pipe_ce) begin
      // Register the router packet and selected lane parameters before the
      // bias/ReLU/saturation cone. This preserves II=1 while removing that
      // cone from the router-to-DSP setup path.
      pre_valid_r <= in_valid;
      pre_acc_lo_r <= in_acc_lo;
      pre_acc_hi_r <= in_acc_hi;
      pre_bias_lo_r <= in_bias_lo;
      pre_bias_hi_r <= in_bias_hi;
      pre_scale_lo_r <= in_scale_lo;
      pre_scale_hi_r <= in_scale_hi;
      pre_relu_en_r <= in_relu_en;
      pre_mask_r <= in_lane_mask;
      pre_addr_lo_r <= in_addr_lo;
      pre_addr_hi_r <= in_addr_hi;
      pre_channel_lo_r <= in_channel_lo;
      pre_channel_hi_r <= in_channel_hi;
      pre_group_r <= in_group;
      pre_fc_mode_r <= in_fc_mode;
      pre_layer_id_r <= in_layer_id;

      s0_valid_r <= pre_valid_r;
      s0_value_lo_r <=
          prepare_acc(pre_acc_lo_r, pre_bias_lo_r, pre_relu_en_r);
      s0_value_hi_r <=
          prepare_acc(pre_acc_hi_r, pre_bias_hi_r, pre_relu_en_r);
      s0_scale_lo_r <= pre_scale_lo_r;
      s0_scale_hi_r <= pre_scale_hi_r;
      s0_mask_r <= pre_mask_r;
      s0_addr_lo_r <= pre_addr_lo_r;
      s0_addr_hi_r <= pre_addr_hi_r;
      s0_channel_lo_r <= pre_channel_lo_r;
      s0_channel_hi_r <= pre_channel_hi_r;
      s0_group_r <= pre_group_r;
      s0_fc_mode_r <= pre_fc_mode_r;
      s0_layer_id_r <= pre_layer_id_r;

      s1_valid_r <= s0_valid_r;
      s1_product_lo_r <= s0_value_lo_r * s0_scale_lo_r;
      s1_product_hi_r <= s0_value_hi_r * s0_scale_hi_r;
      s1_mask_r <= s0_mask_r;
      s1_addr_lo_r <= s0_addr_lo_r;
      s1_addr_hi_r <= s0_addr_hi_r;
      s1_channel_lo_r <= s0_channel_lo_r;
      s1_channel_hi_r <= s0_channel_hi_r;
      s1_group_r <= s0_group_r;
      s1_fc_mode_r <= s0_fc_mode_r;
      s1_layer_id_r <= s0_layer_id_r;

      out_valid_r <= s1_valid_r;
      out_data_r[7:0] <= s1_mask_r[0] ?
                         requantize(s1_product_lo_r) : 8'd0;
      out_data_r[15:8] <= s1_mask_r[1] ?
                          requantize(s1_product_hi_r) : 8'd0;
      out_mask_r <= s1_mask_r;
      out_addr_lo_r <= s1_addr_lo_r;
      out_addr_hi_r <= s1_addr_hi_r;
      out_channel_lo_r <= s1_channel_lo_r;
      out_channel_hi_r <= s1_channel_hi_r;
      out_group_r <= s1_group_r;
      out_fc_mode_r <= s1_fc_mode_r;
      out_layer_id_r <= s1_layer_id_r;
    end
  end

`ifdef SIMULATION
  assert property (@(posedge clk) disable iff (!rst_n)
      (out_valid && !out_ready) |=> $stable({
        out_data, out_lane_mask, out_addr_lo, out_addr_hi,
        out_channel_lo, out_channel_hi, out_group, out_fc_mode, out_layer_id
      }));
`endif

endmodule
