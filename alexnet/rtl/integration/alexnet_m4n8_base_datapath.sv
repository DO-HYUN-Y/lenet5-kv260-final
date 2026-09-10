`timescale 1ns/1ps

// Complete local M4xN8 base datapath. The existing SA and PE RTL are used
// unchanged; this wrapper only coordinates tile clear/descriptor start, derives
// packed M masks, and connects PE holdings to the integrated N8 output slice.
module alexnet_m4n8_base_datapath #(
    parameter int PHYS_ROWS = 2,
    parameter int M_GROUP = 2 * PHYS_ROWS,
    parameter int M_COUNT_W = $clog2(M_GROUP + 1),
    parameter int SLICE_INDEX = 0,
    parameter int FIFO_DEPTH = 64,
    parameter int TILE_TAG_W = 16,
    parameter int N_BASE_W = 16
) (
    input logic clk,
    input logic rst,
    input logic ce,

    input  logic cfg_valid,
    output logic cfg_ready,
    input  logic [1:0] cfg_destination,
    input  logic [N_BASE_W-1:0] cfg_n64_tile_base,
    input  logic [7:0] cfg_lane_mask,
    input  logic signed [31:0] cfg_bias [0:7],
    input  logic signed [17:0] cfg_multiplier [0:7],
    input  logic [5:0] cfg_right_shift [0:7],
    input  logic [7:0] cfg_relu,

    input  logic tile_start_valid,
    output logic tile_start_ready,
    input  logic [M_COUNT_W-1:0] tile_m_count,
    input  logic [7:0] tile_n_lane_mask,
    input  logic [TILE_TAG_W-1:0] tile_tag,

    input  logic issue_valid,
    output logic issue_ready,
    input  logic issue_last,
    input  logic signed [7:0] issue_act_lo [0:PHYS_ROWS-1],
    input  logic signed [7:0] issue_act_hi [0:PHYS_ROWS-1],
    input  logic signed [7:0] issue_weight [0:7],

    output logic egress_valid,
    input  logic egress_ready,
    output logic [63:0] egress_values,
    output logic [7:0] egress_lane_mask,
    output logic [1:0] egress_destination,
    output logic [2:0] egress_slice,
    output logic [4:0] egress_m,
    output logic [N_BASE_W-1:0] egress_n_base,
    output logic [TILE_TAG_W-1:0] egress_tile_tag,

    output logic configured,
    output logic compute_busy,
    output logic tile_done,
    output logic datapath_idle,
    output logic [$clog2(FIFO_DEPTH+1)-1:0] queued_count
);

  logic tile_active_q;
  logic issue_open_q;
  logic [1:0] m_lane_mask_q [0:PHYS_ROWS-1];
  logic tile_start_fire;
  logic issue_fire;
  logic cfg_fire;

  logic sa_result_valid [0:PHYS_ROWS-1][0:7];
  logic sa_result_ready [0:PHYS_ROWS-1][0:7];
  logic signed [31:0] sa_result_lo [0:PHYS_ROWS-1][0:7];
  logic signed [31:0] sa_result_hi [0:PHYS_ROWS-1][0:7];
  logic [1:0] sa_result_lane_mask [0:PHYS_ROWS-1][0:7];

  logic output_cfg_ready;
  logic output_tile_valid;
  logic output_tile_ready;
  logic output_configured;
  logic output_slice_idle;
  logic output_tile_scan_done;

  assign configured = output_configured;
  assign compute_busy = tile_active_q;
  assign datapath_idle = !tile_active_q && output_slice_idle;

  // Configuration is forwarded only on the full-datapath idle boundary. A
  // pending request blocks the next tile but never blocks K tokens belonging
  // to an already accepted tile.
  assign cfg_ready = !tile_active_q && output_cfg_ready;
  assign cfg_fire = cfg_valid && cfg_ready;

  // tile_start is one standalone SA clear cycle and one scanner descriptor
  // handshake. ce must be high so both sides observe the same start edge.
  assign tile_start_ready = output_configured && !cfg_valid && !tile_active_q &&
                            output_tile_ready && ce;
  assign tile_start_fire = tile_start_valid && tile_start_ready;
  assign output_tile_valid = tile_start_fire;

  assign issue_ready = tile_active_q && issue_open_q && ce;
  assign issue_fire = issue_valid && issue_ready;

  always_ff @(posedge clk) begin
    if (rst) begin
      tile_active_q <= 1'b0;
      issue_open_q <= 1'b0;
      for (int g = 0; g < PHYS_ROWS; g++)
        m_lane_mask_q[g] <= '0;
      tile_done <= 1'b0;
    end else begin
      tile_done <= 1'b0;

      if (tile_start_fire) begin
        tile_active_q <= 1'b1;
        issue_open_q <= 1'b1;
        for (int g = 0; g < PHYS_ROWS; g++) begin
          if (tile_m_count <= 2*g)
            m_lane_mask_q[g] <= 2'b00;
          else if (tile_m_count == 2*g + 1)
            m_lane_mask_q[g] <= 2'b01;
          else
            m_lane_mask_q[g] <= 2'b11;
        end
      end

      if (issue_fire && issue_last)
        issue_open_q <= 1'b0;

      if (output_tile_scan_done) begin
        tile_active_q <= 1'b0;
        issue_open_q <= 1'b0;
        tile_done <= 1'b1;
      end
    end
  end

  alexnet_sa_m4n8 #(
      .PHYS_ROWS(PHYS_ROWS)
  ) u_sa (
      .clk(clk),
      .rst(rst),
      .ce(ce),
      .act_lo(issue_act_lo),
      .act_hi(issue_act_hi),
      .weight(issue_weight),
      .issue_valid(issue_fire),
      .tile_clear(tile_start_fire),
      .reduce_last(issue_fire && issue_last),
      .m_lane_mask(m_lane_mask_q),
      .result_valid(sa_result_valid),
      .result_ready(sa_result_ready),
      .result_lo(sa_result_lo),
      .result_hi(sa_result_hi),
      .result_lane_mask(sa_result_lane_mask)
  );

  alexnet_m4n8_n8_output_slice #(
      .PHYS_ROWS(PHYS_ROWS),
      .SLICE_INDEX(SLICE_INDEX),
      .FIFO_DEPTH(FIFO_DEPTH),
      .TILE_TAG_W(TILE_TAG_W),
      .N_BASE_W(N_BASE_W)
  ) u_output_slice (
      .clk(clk),
      .rst(rst),
      .cfg_valid(cfg_fire),
      .cfg_ready(output_cfg_ready),
      .cfg_destination(cfg_destination),
      .cfg_n64_tile_base(cfg_n64_tile_base),
      .cfg_lane_mask(cfg_lane_mask),
      .cfg_bias(cfg_bias),
      .cfg_multiplier(cfg_multiplier),
      .cfg_right_shift(cfg_right_shift),
      .cfg_relu(cfg_relu),
      .tile_valid(output_tile_valid),
      .tile_ready(output_tile_ready),
      .tile_m_count(tile_m_count),
      .tile_n_lane_mask(tile_n_lane_mask),
      .tile_tag(tile_tag),
      .hold_valid(sa_result_valid),
      .hold_ready(sa_result_ready),
      .hold_lo(sa_result_lo),
      .hold_hi(sa_result_hi),
      .hold_m_lane_mask(sa_result_lane_mask),
      .egress_valid(egress_valid),
      .egress_ready(egress_ready),
      .egress_values(egress_values),
      .egress_lane_mask(egress_lane_mask),
      .egress_destination(egress_destination),
      .egress_slice(egress_slice),
      .egress_m(egress_m),
      .egress_n_base(egress_n_base),
      .egress_tile_tag(egress_tile_tag),
      .configured(output_configured),
      .slice_idle(output_slice_idle),
      .tile_scan_done(output_tile_scan_done),
      .queued_count(queued_count)
  );

`ifndef SYNTHESIS
  always_ff @(posedge clk) begin
    if (!rst) begin
      if (tile_start_fire && issue_valid)
        $fatal(1, "base datapath tile clear requires a standalone source cycle");
      if (issue_valid && !tile_active_q)
        $fatal(1, "base datapath received a K token without an active tile");
      if (issue_valid && tile_active_q && !issue_open_q)
        $fatal(1, "base datapath received a K token after issue_last");
      if (output_tile_scan_done && issue_open_q)
        $fatal(1, "base datapath released a tile before its final K token");
    end
  end
`endif

endmodule
