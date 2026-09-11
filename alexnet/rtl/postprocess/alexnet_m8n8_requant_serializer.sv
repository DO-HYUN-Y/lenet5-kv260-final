`timescale 1ns/1ps

// M8-wide requantization followed by a lossless scalar serializer. The wide
// DSP stage accepts complete groups; the serializer preserves the existing
// 64-bit N8 router/AXI boundary and emits only the active M-tail rows.
module alexnet_m8n8_requant_serializer #(
    parameter int TILE_TAG_W = 16,
    parameter int M_COUNT_W = 4
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
    input  logic [M_COUNT_W-1:0] ingress_m_count,
    input  logic signed [31:0] ingress_accumulator [0:7][0:7],
    input  logic [7:0] ingress_lane_mask,
    input  logic [TILE_TAG_W-1:0] ingress_tile_tag,

    output logic egress_valid,
    input  logic egress_ready,
    output logic [63:0] egress_values,
    output logic [7:0] egress_lane_mask,
    output logic [4:0] egress_m,
    output logic [TILE_TAG_W-1:0] egress_tile_tag,

    output logic idle
);

  logic parallel_cfg_ready;
  logic parallel_ingress_ready;
  logic parallel_egress_valid;
  logic parallel_egress_ready;
  logic [M_COUNT_W-1:0] parallel_egress_m_count;
  logic [63:0] parallel_egress_values [0:7];
  logic [7:0] parallel_egress_lane_mask [0:7];
  logic [TILE_TAG_W-1:0] parallel_egress_tile_tag;
  logic parallel_idle;

  logic group_valid_q;
  logic [M_COUNT_W-1:0] group_m_count_q;
  logic [63:0] group_values_q [0:7];
  logic [7:0] group_lane_mask_q [0:7];
  logic [TILE_TAG_W-1:0] group_tile_tag_q;
  logic [2:0] serialize_m_q;
  logic group_slot_ready;
  logic group_capture_fire;
  logic scalar_fire;
  logic scalar_last;

  assign scalar_last = M_COUNT_W'(serialize_m_q) ==
                       group_m_count_q - 1'b1;
  assign scalar_fire = egress_valid && egress_ready;
  assign group_slot_ready = !group_valid_q || (scalar_fire && scalar_last);
  assign parallel_egress_ready = group_slot_ready;
  assign group_capture_fire = parallel_egress_valid &&
                              parallel_egress_ready;

  assign cfg_ready = parallel_cfg_ready && !group_valid_q && !ingress_valid;
  assign ingress_ready = parallel_ingress_ready && !cfg_valid;
  assign egress_valid = group_valid_q;
  assign egress_values = group_values_q[serialize_m_q];
  assign egress_lane_mask = group_lane_mask_q[serialize_m_q];
  assign egress_m = 5'(serialize_m_q);
  assign egress_tile_tag = group_tile_tag_q;
  assign idle = parallel_idle && !group_valid_q;

  alexnet_m8n8_parallel_requant #(
      .M_ROWS(8), .M_COUNT_W(M_COUNT_W), .TILE_TAG_W(TILE_TAG_W)
  ) u_parallel_requant (
      .clk(clk),
      .rst(rst),
      .cfg_valid(cfg_valid && !group_valid_q),
      .cfg_ready(parallel_cfg_ready),
      .cfg_bias(cfg_bias),
      .cfg_multiplier(cfg_multiplier),
      .cfg_right_shift(cfg_right_shift),
      .cfg_relu(cfg_relu),
      .ingress_valid(ingress_valid && !cfg_valid),
      .ingress_ready(parallel_ingress_ready),
      .ingress_m_count(ingress_m_count),
      .ingress_accumulator(ingress_accumulator),
      .ingress_lane_mask(ingress_lane_mask),
      .ingress_tile_tag(ingress_tile_tag),
      .egress_valid(parallel_egress_valid),
      .egress_ready(parallel_egress_ready),
      .egress_m_count(parallel_egress_m_count),
      .egress_values(parallel_egress_values),
      .egress_lane_mask(parallel_egress_lane_mask),
      .egress_tile_tag(parallel_egress_tile_tag),
      .idle(parallel_idle)
  );

  always_ff @(posedge clk) begin
    if (rst) begin
      group_valid_q <= 1'b0;
      group_m_count_q <= '0;
      group_tile_tag_q <= '0;
      serialize_m_q <= '0;
      for (int m = 0; m < 8; m++) begin
        group_values_q[m] <= '0;
        group_lane_mask_q[m] <= '0;
      end
    end else begin
      if (scalar_fire) begin
        if (scalar_last) begin
          group_valid_q <= 1'b0;
          serialize_m_q <= '0;
        end else begin
          serialize_m_q <= serialize_m_q + 1'b1;
        end
      end

      // Same-cycle replacement on the final scalar beat prevents a bubble
      // between adjacent groups when the downstream router remains ready.
      if (group_capture_fire) begin
        group_valid_q <= 1'b1;
        group_m_count_q <= parallel_egress_m_count;
        group_tile_tag_q <= parallel_egress_tile_tag;
        serialize_m_q <= '0;
        for (int m = 0; m < 8; m++) begin
          group_values_q[m] <= parallel_egress_values[m];
          group_lane_mask_q[m] <= parallel_egress_lane_mask[m];
        end
      end
    end
  end

`ifndef SYNTHESIS
  always_ff @(posedge clk) begin
    if (!rst) begin
      if (group_capture_fire &&
          (parallel_egress_m_count == 0 || parallel_egress_m_count > 8))
        $fatal(1, "M8 requant serializer captured an invalid M count");
      if (cfg_valid && cfg_ready && !parallel_cfg_ready)
        $fatal(1, "M8 requant serializer configuration was not atomic");
    end
  end
`endif

endmodule
