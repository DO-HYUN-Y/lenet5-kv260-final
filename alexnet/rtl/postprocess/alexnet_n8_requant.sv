`timescale 1ns/1ps

// One N8 post-processing slice between the M4xN8 result scanner and an N8
// output router. Parameters are stationary by N lane and may only change once
// all five pipeline stages have drained.
module alexnet_n8_requant #(
    parameter int M_W = 5,
    parameter int TILE_TAG_W = 16
) (
    input logic clk,
    input logic rst,

    input  logic cfg_valid,
    output logic cfg_ready,
    input  logic signed [31:0] cfg_bias [0:7],
    input  logic signed [17:0] cfg_multiplier [0:7],
    input  logic [5:0] cfg_right_shift [0:7],
    input  logic [7:0] cfg_relu,

    input  logic ingress_valid,
    output logic ingress_ready,
    input  logic signed [31:0] ingress_accumulator [0:7],
    input  logic [7:0] ingress_lane_mask,
    input  logic [M_W-1:0] ingress_m,
    input  logic [TILE_TAG_W-1:0] ingress_tile_tag,

    output logic egress_valid,
    input  logic egress_ready,
    output logic [63:0] egress_values,
    output logic [7:0] egress_lane_mask,
    output logic [M_W-1:0] egress_m,
    output logic [TILE_TAG_W-1:0] egress_tile_tag,

    output logic idle
);

  localparam logic signed [32:0] SIGNED27_MIN = -33'sd67108864;
  localparam logic signed [32:0] SIGNED27_MAX =  33'sd67108863;

  logic configured_q;
  logic signed [31:0] bias_q [0:7];
  logic signed [17:0] multiplier_q [0:7];
  logic [5:0] right_shift_q [0:7];
  logic [7:0] relu_q;

  logic [4:0] valid_q;
  logic advance;

  logic signed [32:0] biased_input [0:7];
  logic signed [26:0] biased_q [0:7];
  // The registered 27x18 product is the intended DSP48E2 boundary.
  (* use_dsp = "yes" *) logic signed [44:0] product_q [0:7];
  logic signed [44:0] product_pipe_q [0:7];
  logic signed [45:0] rounded_q [0:7];
  logic [63:0] values_q;

  logic [7:0] lane_mask_q [0:4];
  logic [M_W-1:0] m_q [0:4];
  logic [TILE_TAG_W-1:0] tile_tag_q [0:4];

  // Symmetric half-away rounding can use one signed bias before an arithmetic
  // shift: add 2^(s-1) for non-negative values, or 2^(s-1)-1 for negatives.
  // After that add, dropping the fixed lower 23 bits shrinks the only variable
  // shifter to 22 bits for the frozen shift range 23..32.
  function automatic logic signed [45:0] rounded_shift(
      input logic signed [44:0] value,
      input logic [5:0] right_shift);
    logic signed [44:0] rounding_bias;
    logic signed [44:0] adjusted_value;
    logic signed [21:0] coarse_value;
    logic signed [21:0] shifted_value;
    logic [5:0] shift_offset;
    begin
      rounding_bias = 45'sd1 <<< (right_shift - 1'b1);
      if (value[44])
        rounding_bias = rounding_bias - 1'b1;
      adjusted_value = value + rounding_bias;
      coarse_value = adjusted_value[44:23];
      shift_offset = right_shift - 6'd23;
      shifted_value = coarse_value >>> shift_offset;
      rounded_shift = {{24{shifted_value[21]}}, shifted_value};
    end
  endfunction

  function automatic logic [7:0] saturate_i8(
      input logic signed [45:0] value,
      input logic relu);
    begin
      if (relu && value < 0)
        saturate_i8 = 8'h00;
      else if (value > 46'sd127)
        saturate_i8 = 8'h7f;
      else if (value < -46'sd128)
        saturate_i8 = 8'h80;
      else
        saturate_i8 = value[7:0];
    end
  endfunction

  for (genvar lane = 0; lane < 8; lane++) begin : g_bias_input
    always_comb begin
      biased_input[lane] =
          $signed({ingress_accumulator[lane][31], ingress_accumulator[lane]}) +
          $signed({bias_q[lane][31], bias_q[lane]});
    end
  end

  assign idle = ~(|valid_q);
  assign cfg_ready = idle;
  assign advance = !valid_q[4] || egress_ready;
  assign ingress_ready = configured_q && !cfg_valid && advance;

  assign egress_valid = valid_q[4];
  assign egress_values = values_q;
  assign egress_lane_mask = lane_mask_q[4];
  assign egress_m = m_q[4];
  assign egress_tile_tag = tile_tag_q[4];

  always_ff @(posedge clk) begin
    if (rst) begin
      configured_q <= 1'b0;
      valid_q <= '0;
      // Payload registers are deliberately not reset. valid_q/configured_q
      // completely qualify their use, while resetting the inferred DSP data
      // registers creates a long system-configuration-to-DSP reset path.
      // Their contents are overwritten before becoming architecturally live.
    end else begin
      if (cfg_valid && cfg_ready) begin
        configured_q <= 1'b1;
        relu_q <= cfg_relu;
        for (int lane = 0; lane < 8; lane++) begin
          bias_q[lane] <= cfg_bias[lane];
          multiplier_q[lane] <= cfg_multiplier[lane];
          right_shift_q[lane] <= cfg_right_shift[lane];
        end
      end

      if (advance) begin
        valid_q[0] <= ingress_valid && ingress_ready;
        valid_q[1] <= valid_q[0];
        valid_q[2] <= valid_q[1];
        valid_q[3] <= valid_q[2];
        valid_q[4] <= valid_q[3];

        if (ingress_valid && ingress_ready) begin
          lane_mask_q[0] <= ingress_lane_mask;
          m_q[0] <= ingress_m;
          tile_tag_q[0] <= ingress_tile_tag;
          for (int lane = 0; lane < 8; lane++) begin
            biased_q[lane] <= ingress_lane_mask[lane]
                                  ? biased_input[lane][26:0]
                                  : '0;
          end
        end

        if (valid_q[0]) begin
          lane_mask_q[1] <= lane_mask_q[0];
          m_q[1] <= m_q[0];
          tile_tag_q[1] <= tile_tag_q[0];
          for (int lane = 0; lane < 8; lane++)
            product_q[lane] <= biased_q[lane] * multiplier_q[lane];
        end

        if (valid_q[1]) begin
          lane_mask_q[2] <= lane_mask_q[1];
          m_q[2] <= m_q[1];
          tile_tag_q[2] <= tile_tag_q[1];
          for (int lane = 0; lane < 8; lane++)
            product_pipe_q[lane] <= product_q[lane];
        end

        if (valid_q[2]) begin
          lane_mask_q[3] <= lane_mask_q[2];
          m_q[3] <= m_q[2];
          tile_tag_q[3] <= tile_tag_q[2];
          for (int lane = 0; lane < 8; lane++)
            rounded_q[lane] <= rounded_shift(product_pipe_q[lane],
                                                right_shift_q[lane]);
        end

        if (valid_q[3]) begin
          lane_mask_q[4] <= lane_mask_q[3];
          m_q[4] <= m_q[3];
          tile_tag_q[4] <= tile_tag_q[3];
          for (int lane = 0; lane < 8; lane++) begin
            values_q[lane*8 +: 8] <= lane_mask_q[3][lane]
                ? saturate_i8(rounded_q[lane], relu_q[lane])
                : 8'h00;
          end
        end
      end
    end
  end

`ifndef SYNTHESIS
  always_ff @(posedge clk) begin
    if (!rst) begin
      if (cfg_valid && cfg_ready) begin
        for (int lane = 0; lane < 8; lane++) begin
          if (cfg_multiplier[lane] < 18'sd65540 ||
              cfg_multiplier[lane] > 18'sd131067)
            $fatal(1, "requant lane %0d multiplier is outside frozen range", lane);
          if (cfg_right_shift[lane] < 23 || cfg_right_shift[lane] > 32)
            $fatal(1, "requant lane %0d shift is outside frozen range", lane);
        end
      end
      if (ingress_valid && ingress_ready) begin
        if (ingress_lane_mask == 0 ||
            ((ingress_lane_mask & (ingress_lane_mask + 1'b1)) != 0))
          $fatal(1, "requant lane mask must be a nonzero low-lane tail mask");
        for (int lane = 0; lane < 8; lane++) begin
          if (ingress_lane_mask[lane] &&
              (biased_input[lane] < SIGNED27_MIN ||
               biased_input[lane] > SIGNED27_MAX))
            $fatal(1, "requant lane %0d post-bias value exceeds signed 27-bit", lane);
        end
      end
    end
  end
`endif

endmodule
