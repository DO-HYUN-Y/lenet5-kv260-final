`timescale 1ns/1ps

// Eight fully pipelined N8 requantizers operating on one complete M8 result
// group. This is the post-processing target for the partitioned M-bank path:
// 64 DSP48E2 multipliers accept up to 64 INT32 accumulators atomically.
module alexnet_m8n8_parallel_requant #(
    parameter int M_ROWS = 8,
    parameter int M_COUNT_W = $clog2(M_ROWS + 1),
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
    input  logic [M_COUNT_W-1:0] ingress_m_count,
    input  logic signed [31:0] ingress_accumulator [0:M_ROWS-1][0:7],
    input  logic [7:0] ingress_lane_mask,
    input  logic [TILE_TAG_W-1:0] ingress_tile_tag,

    output logic egress_valid,
    input  logic egress_ready,
    output logic [M_COUNT_W-1:0] egress_m_count,
    output logic [63:0] egress_values [0:M_ROWS-1],
    output logic [7:0] egress_lane_mask [0:M_ROWS-1],
    output logic [TILE_TAG_W-1:0] egress_tile_tag,

    output logic idle
);

  logic child_cfg_ready [0:M_ROWS-1];
  logic child_ingress_ready [0:M_ROWS-1];
  logic child_egress_valid [0:M_ROWS-1];
  logic child_egress_ready;
  logic [63:0] child_egress_values [0:M_ROWS-1];
  logic [7:0] child_egress_lane_mask [0:M_ROWS-1];
  logic [4:0] child_egress_m [0:M_ROWS-1];
  logic [TILE_TAG_W-1:0] child_egress_tile_tag [0:M_ROWS-1];
  logic child_idle [0:M_ROWS-1];

  logic cfg_fire;
  logic ingress_fire;
  logic [4:0] group_valid_q;
  logic [M_COUNT_W-1:0] m_count_q [0:4];
  logic advance;

  // All eight rows receive exactly the same valid/ready events and therefore
  // remain lockstep. Use row zero as the control representative instead of
  // building timing-heavy eight-way AND trees on every handshake.
  assign cfg_ready = child_cfg_ready[0] && !ingress_valid;
  assign cfg_fire = cfg_valid && cfg_ready;
  assign advance = !group_valid_q[4] || egress_ready;
  assign ingress_ready = !cfg_valid && child_ingress_ready[0] && advance;
  assign ingress_fire = ingress_valid && ingress_ready;
  assign egress_valid = group_valid_q[4] && child_egress_valid[0];
  assign egress_m_count = m_count_q[4];
  assign egress_tile_tag = child_egress_tile_tag[0];
  assign child_egress_ready = group_valid_q[4] && egress_ready;
  assign idle = child_idle[0] && !(|group_valid_q);

  for (genvar m = 0; m < M_ROWS; m++) begin : g_requant_row
    alexnet_n8_requant #(
        .M_W(5),
        .TILE_TAG_W(TILE_TAG_W)
    ) u_requant (
        .clk(clk),
        .rst(rst),
        .cfg_valid(cfg_fire),
        .cfg_ready(child_cfg_ready[m]),
        .cfg_bias(cfg_bias),
        .cfg_multiplier(cfg_multiplier),
        .cfg_right_shift(cfg_right_shift),
        .cfg_relu(cfg_relu),
        .ingress_valid(ingress_fire),
        .ingress_ready(child_ingress_ready[m]),
        .ingress_accumulator(ingress_accumulator[m]),
        .ingress_lane_mask(ingress_lane_mask),
        .ingress_m(5'(m)),
        .ingress_tile_tag(ingress_tile_tag),
        .egress_valid(child_egress_valid[m]),
        .egress_ready(child_egress_ready),
        .egress_values(child_egress_values[m]),
        .egress_lane_mask(child_egress_lane_mask[m]),
        .egress_m(child_egress_m[m]),
        .egress_tile_tag(child_egress_tile_tag[m]),
        .idle(child_idle[m])
    );

    always_comb begin
      egress_values[m] = child_egress_values[m];
      egress_lane_mask[m] = child_egress_lane_mask[m];
    end
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      group_valid_q <= '0;
      for (int stage = 0; stage < 5; stage++)
        m_count_q[stage] <= '0;
    end else if (advance) begin
      group_valid_q[0] <= ingress_fire;
      group_valid_q[1] <= group_valid_q[0];
      group_valid_q[2] <= group_valid_q[1];
      group_valid_q[3] <= group_valid_q[2];
      group_valid_q[4] <= group_valid_q[3];
      if (ingress_fire)
        m_count_q[0] <= ingress_m_count;
      for (int stage = 1; stage < 5; stage++)
        if (group_valid_q[stage-1])
          m_count_q[stage] <= m_count_q[stage-1];
    end
  end

`ifndef SYNTHESIS
  initial begin
    if (M_ROWS != 8)
      $fatal(1, "parallel requant currently supports M_ROWS=8");
  end

  always_ff @(posedge clk) begin
    if (!rst) begin
      if (ingress_valid && ingress_ready &&
          (ingress_m_count == 0 || ingress_m_count > M_ROWS))
        $fatal(1, "parallel requant M count is outside 1..8");
      if (egress_valid) begin
        for (int m = 0; m < M_ROWS; m++) begin
          if (child_egress_valid[m] != child_egress_valid[0] ||
              child_cfg_ready[m] != child_cfg_ready[0] ||
              child_ingress_ready[m] != child_ingress_ready[0] ||
              child_idle[m] != child_idle[0])
            $fatal(1, "parallel requant rows lost lockstep control");
          if (M_COUNT_W'(m) < egress_m_count) begin
            if (!child_egress_valid[m] || child_egress_m[m] != m ||
                child_egress_tile_tag[m] != child_egress_tile_tag[0])
              $fatal(1, "parallel requant row metadata lost alignment");
          end
        end
      end
    end
  end
`endif

endmodule
