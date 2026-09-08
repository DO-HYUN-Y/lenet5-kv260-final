`timescale 1ns/1ps

// End-to-end M4xN8 result path: packed-PE holdings -> M-ordered scanner ->
// eight-lane requantization -> one 64-entry N8 output-router slice.
//
// Requant parameters and the router descriptor share one atomic configuration
// handshake. A pending change blocks new tiles but lets all accepted work drain.
module alexnet_m4n8_n8_output_slice #(
    parameter int SLICE_INDEX = 0,
    parameter int FIFO_DEPTH = 64,
    parameter int TILE_TAG_W = 16,
    parameter int N_BASE_W = 16
) (
    input logic clk,
    input logic rst,

    input  logic cfg_valid,
    output logic cfg_ready,
    input  logic [1:0] cfg_destination,
    input  logic [N_BASE_W-1:0] cfg_n64_tile_base,
    input  logic [7:0] cfg_lane_mask,
    input  logic signed [31:0] cfg_bias [0:7],
    input  logic signed [17:0] cfg_multiplier [0:7],
    input  logic [5:0] cfg_right_shift [0:7],
    input  logic [7:0] cfg_relu,

    input  logic tile_valid,
    output logic tile_ready,
    input  logic [2:0] tile_m_count,
    input  logic [7:0] tile_n_lane_mask,
    input  logic [TILE_TAG_W-1:0] tile_tag,

    input  logic hold_valid [0:1][0:7],
    output logic hold_ready [0:1][0:7],
    input  logic signed [31:0] hold_lo [0:1][0:7],
    input  logic signed [31:0] hold_hi [0:1][0:7],
    input  logic [1:0] hold_m_lane_mask [0:1][0:7],

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
    output logic slice_idle,
    output logic tile_scan_done,
    output logic [$clog2(FIFO_DEPTH+1)-1:0] queued_count
);

  logic configured_q;
  logic cfg_fire;

  logic scanner_tile_valid;
  logic scanner_tile_ready;
  logic scanner_valid;
  logic scanner_ready;
  logic signed [31:0] scanner_accumulator [0:7];
  logic [1:0] scanner_m;
  logic [7:0] scanner_lane_mask;
  logic [TILE_TAG_W-1:0] scanner_tile_tag;
  logic scanner_busy;

  logic requant_cfg_ready;
  logic requant_valid;
  logic requant_ready;
  logic [63:0] requant_values;
  logic [7:0] requant_lane_mask;
  logic [4:0] requant_m;
  logic [TILE_TAG_W-1:0] requant_tile_tag;
  logic requant_idle;

  logic router_cfg_ready;
  logic router_idle;

  assign configured = configured_q;
  assign slice_idle = scanner_tile_ready && requant_idle && router_idle;
  assign cfg_ready = slice_idle;
  assign cfg_fire = cfg_valid && cfg_ready;

  // As soon as a new descriptor is requested, stop admitting tiles. Existing
  // scanner/pipeline/FIFO state continues to advance until cfg_ready rises.
  assign tile_ready = configured_q && !cfg_valid && scanner_tile_ready;
  assign scanner_tile_valid = tile_valid && configured_q && !cfg_valid;

  always_ff @(posedge clk) begin
    if (rst)
      configured_q <= 1'b0;
    else if (cfg_fire)
      configured_q <= 1'b1;
  end

  alexnet_m4n8_result_scanner #(
      .PHYS_ROWS(2),
      .COLS(8),
      .TILE_TAG_W(TILE_TAG_W)
  ) u_scanner (
      .clk(clk),
      .rst(rst),
      .tile_valid(scanner_tile_valid),
      .tile_ready(scanner_tile_ready),
      .tile_m_count(tile_m_count),
      .tile_n_lane_mask(tile_n_lane_mask),
      .tile_tag(tile_tag),
      .hold_valid(hold_valid),
      .hold_ready(hold_ready),
      .hold_lo(hold_lo),
      .hold_hi(hold_hi),
      .hold_m_lane_mask(hold_m_lane_mask),
      .out_valid(scanner_valid),
      .out_ready(scanner_ready),
      .out_accumulator(scanner_accumulator),
      .out_m(scanner_m),
      .out_n_lane_mask(scanner_lane_mask),
      .out_tile_tag(scanner_tile_tag),
      .busy(scanner_busy),
      .tile_done(tile_scan_done)
  );

  alexnet_n8_requant #(
      .M_W(5),
      .TILE_TAG_W(TILE_TAG_W)
  ) u_requant (
      .clk(clk),
      .rst(rst),
      .cfg_valid(cfg_fire),
      .cfg_ready(requant_cfg_ready),
      .cfg_bias(cfg_bias),
      .cfg_multiplier(cfg_multiplier),
      .cfg_right_shift(cfg_right_shift),
      .cfg_relu(cfg_relu),
      .ingress_valid(scanner_valid),
      .ingress_ready(scanner_ready),
      .ingress_accumulator(scanner_accumulator),
      .ingress_lane_mask(scanner_lane_mask),
      .ingress_m({3'b000, scanner_m}),
      .ingress_tile_tag(scanner_tile_tag),
      .egress_valid(requant_valid),
      .egress_ready(requant_ready),
      .egress_values(requant_values),
      .egress_lane_mask(requant_lane_mask),
      .egress_m(requant_m),
      .egress_tile_tag(requant_tile_tag),
      .idle(requant_idle)
  );

  alexnet_n8_output_router #(
      .SLICE_INDEX(SLICE_INDEX),
      .FIFO_DEPTH(FIFO_DEPTH),
      .M_W(5),
      .N_BASE_W(N_BASE_W),
      .TILE_TAG_W(TILE_TAG_W)
  ) u_router (
      .clk(clk),
      .rst(rst),
      .cfg_valid(cfg_fire),
      .cfg_ready(router_cfg_ready),
      .cfg_destination(cfg_destination),
      .cfg_n64_tile_base(cfg_n64_tile_base),
      .cfg_slice_index(3'(SLICE_INDEX)),
      .cfg_lane_mask(cfg_lane_mask),
      .ingress_valid(requant_valid),
      .ingress_ready(requant_ready),
      .ingress_values(requant_values),
      .ingress_lane_mask(requant_lane_mask),
      .ingress_m(requant_m),
      .ingress_tile_tag(requant_tile_tag),
      .egress_valid(egress_valid),
      .egress_ready(egress_ready),
      .egress_values(egress_values),
      .egress_lane_mask(egress_lane_mask),
      .egress_destination(egress_destination),
      .egress_slice(egress_slice),
      .egress_m(egress_m),
      .egress_n_base(egress_n_base),
      .egress_tile_tag(egress_tile_tag),
      .idle(router_idle),
      .queued_count(queued_count)
  );

`ifndef SYNTHESIS
  always_ff @(posedge clk) begin
    if (!rst) begin
      if (cfg_fire && (!requant_cfg_ready || !router_cfg_ready))
        $fatal(1, "integrated output slice configuration was not atomic");
      if (tile_valid && tile_ready && tile_n_lane_mask != cfg_lane_mask)
        $fatal(1, "tile N mask must match the active output-slice descriptor");
      if (scanner_busy && cfg_fire)
        $fatal(1, "output-slice configuration changed while scanner was busy");
    end
  end
`endif

endmodule
