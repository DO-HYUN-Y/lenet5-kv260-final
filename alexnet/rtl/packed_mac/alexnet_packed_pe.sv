`timescale 1ns/1ps

// AlexNet fixed-GEMM split-every-cycle packed processing element.
//
// One DSP48E2 computes two signed INT8 products with AMD WP487 method A:
//
//   packed = (act_hi << 18) + act_lo
//   product = packed * weight
//   lo = signed(product[17:0])
//   hi = signed(product[35:18]) + product[17]
//
// Unlike the legacy LeNet PE, this block has no operand-role mux, hop path, or
// per-PE tag pipeline. mac_valid/acc_clear/reduce_last/lane_mask are already
// aligned with product_reg by the local M8xN8 row-control tap. The DSP operand
// latency from an input issue edge to the matching aligned-control edge is
// four enabled cycles.
module alexnet_packed_pe #(
    parameter int ACC_W = 27
) (
    input  logic clk,
    input  logic rst,
    input  logic ce,

    input  logic signed [7:0] act_lo,
    input  logic signed [7:0] act_hi,
    input  logic signed [7:0] weight,

    input  logic       mac_valid,
    input  logic       acc_clear,
    input  logic       reduce_last,
    input  logic [1:0] lane_mask,

    output logic               result_valid,
    input  logic               result_ready,
    output logic signed [31:0] result_lo,
    output logic signed [31:0] result_hi,
    output logic        [1:0]  result_lane_mask
);

  localparam int PACK_SHIFT = 18;
  localparam int DSP_A_W = 27;
  localparam int PRODUCT_W = 36;

  logic signed [DSP_A_W-1:0] act_lo_ext;
  logic signed [DSP_A_W-1:0] act_hi_ext;

  assign act_lo_ext = {{(DSP_A_W-8){act_lo[7]}}, act_lo};
  assign act_hi_ext = {{(DSP_A_W-8){act_hi[7]}}, act_hi};

  // DSP48E2 pipeline: AREG/DREG/BREG1 -> ADREG/BREG2 -> MREG -> PREG.
  // Synchronous reset and a single tile-local CE preserve native DSP mapping.
  logic signed [DSP_A_W-1:0] a_reg;
  logic signed [DSP_A_W-1:0] d_reg;
  logic signed [DSP_A_W-1:0] ad_reg;
  logic signed [7:0] b_reg1;
  logic signed [7:0] b_reg2;
  (* use_dsp = "yes" *) logic signed [PRODUCT_W-1:0] mult_reg;
  logic signed [PRODUCT_W-1:0] product_reg;

  always_ff @(posedge clk) begin
    if (rst) begin
      a_reg       <= '0;
      d_reg       <= '0;
      ad_reg      <= '0;
      b_reg1      <= '0;
      b_reg2      <= '0;
      mult_reg    <= '0;
      product_reg <= '0;
    end else if (ce) begin
      a_reg       <= act_hi_ext <<< PACK_SHIFT;
      d_reg       <= act_lo_ext;
      b_reg1      <= weight;
      ad_reg      <= a_reg + d_reg;
      b_reg2      <= b_reg1;
      mult_reg    <= ad_reg * b_reg2;
      product_reg <= mult_reg;
    end
  end

  logic signed [ACC_W-1:0] product_lo;
  logic signed [ACC_W-1:0] product_hi_uncorrected;

  assign product_lo = {{(ACC_W-PACK_SHIFT){product_reg[PACK_SHIFT-1]}},
                       product_reg[PACK_SHIFT-1:0]};
  assign product_hi_uncorrected =
      {{(ACC_W-PACK_SHIFT){product_reg[PRODUCT_W-1]}},
       product_reg[PRODUCT_W-1:PACK_SHIFT]};

  // The frozen AlexNet weights prove every post-bias result fits signed 27
  // bits. The holding registers stay 27 bits; outputs are sign-extended to
  // the frozen INT32 tensor/parameter ABI without spending another 10 FFs.
  logic signed [ACC_W-1:0] acc_lo_q;
  logic signed [ACC_W-1:0] acc_hi_q;
  logic signed [ACC_W-1:0] acc_lo_sum;
  logic signed [ACC_W-1:0] acc_hi_sum;
  logic signed [ACC_W-1:0] hold_lo_q;
  logic signed [ACC_W-1:0] hold_hi_q;

  assign acc_lo_sum = acc_lo_q + product_lo;
  // Express the WP487 carry correction as the accumulator carry-in. This
  // keeps the high lane to one ACC_W-bit carry chain instead of materializing
  // a separate ACC_W-bit correction adder in front of the accumulator.
  assign acc_hi_sum = acc_hi_q + product_hi_uncorrected +
                      {{(ACC_W-1){1'b0}}, product_reg[PACK_SHIFT-1]};

  assign result_lo = {{(32-ACC_W){hold_lo_q[ACC_W-1]}}, hold_lo_q};
  assign result_hi = {{(32-ACC_W){hold_hi_q[ACC_W-1]}}, hold_hi_q};

  always_ff @(posedge clk) begin
    if (rst) begin
      acc_lo_q         <= '0;
      acc_hi_q         <= '0;
      hold_lo_q        <= '0;
      hold_hi_q        <= '0;
      result_lane_mask <= '0;
      result_valid     <= 1'b0;
    end else begin
      // Holding can drain independently of a compute-pipeline CE stall.
      if (result_valid && result_ready)
        result_valid <= 1'b0;

      if (ce) begin
        // acc_clear is a standalone aligned control cycle. Keeping it out of
        // the MAC cycle removes two 27-bit clear muxes from every physical PE.
        if (acc_clear) begin
          acc_lo_q <= '0;
          acc_hi_q <= '0;
        end else if (mac_valid) begin
          if (reduce_last) begin
            hold_lo_q        <= acc_lo_sum;
            hold_hi_q        <= acc_hi_sum;
            result_lane_mask <= lane_mask;
            result_valid     <= 1'b1;
            acc_lo_q         <= '0;
            acc_hi_q         <= '0;
          end else begin
            acc_lo_q <= acc_lo_sum;
            acc_hi_q <= acc_hi_sum;
          end
        end
      end
    end
  end

`ifndef SYNTHESIS
  logic signed [ACC_W-1:0] product_hi_checked;

  assign product_hi_checked = product_hi_uncorrected +
                               {{(ACC_W-1){1'b0}},
                                product_reg[PACK_SHIFT-1]};

  initial begin
    if (ACC_W != 27)
      $fatal(1, "AlexNet frozen accumulator width must be 27, got %0d", ACC_W);
  end

  always_ff @(posedge clk) begin
    if (!rst && ce) begin
      if (reduce_last && !mac_valid)
        $fatal(1, "reduce_last requires an aligned valid product");
      if (acc_clear && mac_valid)
        $fatal(1, "acc_clear must use a standalone aligned control cycle");
      if (mac_valid && (lane_mask == 2'b00))
        $fatal(1, "mac_valid requires at least one active packed lane");
      if (mac_valid && reduce_last && result_valid && !result_ready)
        $fatal(1, "packed PE holding overflow");
      if (mac_valid && (acc_lo_q[ACC_W-1] == product_lo[ACC_W-1]) &&
          (acc_lo_sum[ACC_W-1] != acc_lo_q[ACC_W-1]))
        $fatal(1, "packed PE low-lane signed-27 accumulator overflow");
      if (mac_valid &&
          (acc_hi_q[ACC_W-1] == product_hi_checked[ACC_W-1]) &&
          (acc_hi_sum[ACC_W-1] != acc_hi_q[ACC_W-1]))
        $fatal(1, "packed PE high-lane signed-27 accumulator overflow");
    end
  end
`endif

endmodule
