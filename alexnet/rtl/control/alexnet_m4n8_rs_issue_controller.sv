`timescale 1ns/1ps

// Serializes one RS-feeder M group into one M4xN8 base-datapath tile.
// The resident-weight replay and base tile descriptor are accepted atomically
// on the standalone tile-clear cycle, then activation/weight K beats are
// accepted together. The base reports tile_done one cycle after reduce_last;
// the controller can already prepare the next context because reduce_last is
// itself the unique retirement event for the current issue stream.
module alexnet_m4n8_rs_issue_controller #(
    parameter int PHYS_ROWS = 2,
    parameter int M_GROUP = 2 * PHYS_ROWS,
    parameter int M_COUNT_W = $clog2(M_GROUP + 1),
    parameter int DIM_W = 8,
    parameter int K_INDEX_W = 10,
    parameter int TILE_TAG_W = 16
) (
    input logic clk,
    input logic rst,
    input logic frame_start,
    input logic [7:0] tile_n_lane_mask,

    input  logic feeder_valid,
    output logic feeder_ready,
    input  logic signed [7:0] feeder_act_lo [0:PHYS_ROWS-1],
    input  logic signed [7:0] feeder_act_hi [0:PHYS_ROWS-1],
    input  logic [1:0] feeder_m_lane_mask [0:PHYS_ROWS-1],
    input  logic feeder_tile_clear,
    input  logic feeder_reduce_last,
    input  logic [K_INDEX_W-1:0] feeder_k,
    input  logic [M_COUNT_W-1:0] feeder_m_count,
    input  logic [DIM_W-1:0] feeder_output_y,
    input  logic [DIM_W-1:0] feeder_output_x,
    input  logic [TILE_TAG_W-1:0] feeder_frame_tag,

    output logic weight_tile_valid,
    input  logic weight_tile_ready,
    output logic [15:0] weight_tile_index,
    output logic [M_COUNT_W-1:0] weight_tile_m_count,
    output logic [DIM_W-1:0] weight_tile_output_y,
    output logic [DIM_W-1:0] weight_tile_output_x,
    output logic [TILE_TAG_W-1:0] weight_tile_tag,

    input  logic weight_valid,
    output logic weight_ready,
    input  logic signed [7:0] weight_values [0:7],
    input  logic [K_INDEX_W-1:0] weight_k,
    input  logic weight_last,

    output logic tile_start_valid,
    input  logic tile_start_ready,
    output logic [M_COUNT_W-1:0] tile_m_count,
    output logic [7:0] tile_n_lane_mask_out,
    output logic [TILE_TAG_W-1:0] tile_tag,

    output logic issue_valid,
    input  logic issue_ready,
    output logic issue_last,
    output logic signed [7:0] issue_act_lo [0:PHYS_ROWS-1],
    output logic signed [7:0] issue_act_hi [0:PHYS_ROWS-1],
    output logic signed [7:0] issue_weight [0:7],
    input  logic tile_done,

    output logic controller_idle,
    output logic tile_inflight,
    output logic [15:0] completed_tile_count,
    output logic protocol_error
);

  typedef enum logic [1:0] {
    ST_WAIT_CONTEXT,
    ST_START_TILE,
    ST_ISSUE,
    ST_WAIT_DONE
  } state_t;

  state_t state_q;
  logic [15:0] tile_index_q;
  logic metadata_match;
  logic context_start_valid;
  logic context_fire;
  logic tile_start_fire;
  logic issue_fire;

  assign metadata_match = (weight_k == feeder_k) &&
                          (weight_last == feeder_reduce_last);
  assign context_start_valid = (state_q == ST_WAIT_CONTEXT) && feeder_valid &&
                               feeder_tile_clear && (feeder_k == 0);
  assign context_fire = weight_tile_valid && weight_tile_ready;
  assign tile_start_fire = tile_start_valid && tile_start_ready;
  assign issue_fire = issue_valid && issue_ready;

  assign controller_idle = state_q == ST_WAIT_CONTEXT;
  assign tile_inflight = state_q != ST_WAIT_CONTEXT;
  assign completed_tile_count = tile_index_q;

  // Cross-gating makes the replay and tile descriptor handshakes indivisible.
  // This removes two control-only cycles per spatial group while retaining the
  // base datapath's required no-issue tile-clear cycle.
  assign weight_tile_valid = context_start_valid && tile_start_ready;
  assign weight_tile_index = tile_index_q;
  assign weight_tile_m_count = feeder_m_count;
  assign weight_tile_output_y = feeder_output_y;
  assign weight_tile_output_x = feeder_output_x;
  assign weight_tile_tag = feeder_frame_tag + tile_index_q;

  assign tile_start_valid = context_start_valid && weight_tile_ready;
  assign tile_m_count = feeder_m_count;
  assign tile_n_lane_mask_out = tile_n_lane_mask;
  assign tile_tag = feeder_frame_tag + tile_index_q;

  assign issue_valid = (state_q == ST_ISSUE) && feeder_valid && weight_valid &&
                       metadata_match;
  assign feeder_ready = (state_q == ST_ISSUE) && weight_valid &&
                        metadata_match && issue_ready;
  assign weight_ready = (state_q == ST_ISSUE) && feeder_valid &&
                        metadata_match && issue_ready;
  assign issue_last = feeder_reduce_last;

  always_comb begin
    for (int row = 0; row < PHYS_ROWS; row++) begin
      issue_act_lo[row] = feeder_act_lo[row];
      issue_act_hi[row] = feeder_act_hi[row];
    end
    for (int lane = 0; lane < 8; lane++)
      issue_weight[lane] = weight_values[lane];
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      state_q <= ST_WAIT_CONTEXT;
      tile_index_q <= '0;
      protocol_error <= 1'b0;
    end else begin
      if (frame_start) begin
        state_q <= ST_WAIT_CONTEXT;
        tile_index_q <= '0;
      end

      case (state_q)
        ST_WAIT_CONTEXT: begin
          if (context_fire && tile_start_fire)
            state_q <= ST_ISSUE;
        end
        ST_START_TILE: begin
          if (tile_start_fire)
            state_q <= ST_ISSUE;
        end
        ST_ISSUE: begin
          if (feeder_valid && weight_valid && !metadata_match)
            protocol_error <= 1'b1;
          if (issue_fire && feeder_reduce_last) begin
            tile_index_q <= tile_index_q + 1'b1;
            state_q <= ST_WAIT_CONTEXT;
          end
        end
        ST_WAIT_DONE: begin
          if (tile_done) begin
            tile_index_q <= tile_index_q + 1'b1;
            state_q <= ST_WAIT_CONTEXT;
          end
        end
        default: state_q <= ST_WAIT_CONTEXT;
      endcase
    end
  end

`ifndef SYNTHESIS
  always_ff @(posedge clk) begin
    if (!rst) begin
      if (frame_start && state_q != ST_WAIT_CONTEXT)
        $fatal(1, "issue controller started a frame with a tile in flight");
      if (state_q == ST_WAIT_CONTEXT && feeder_valid &&
          (!feeder_tile_clear || feeder_k != 0))
        $fatal(1, "issue controller did not observe K=0 at a tile boundary");
      if (feeder_valid && weight_valid && state_q == ST_ISSUE &&
          !metadata_match)
        $fatal(1, "issue controller activation/weight K metadata mismatch");
      if (issue_fire && feeder_m_count == 0)
        $fatal(1, "issue controller accepted an empty M group");
      if (issue_fire) begin
        for (int g = 0; g < PHYS_ROWS; g++) begin
          if (feeder_m_lane_mask[g] !=
              {feeder_m_count > 2*g + 1, feeder_m_count > 2*g})
            $fatal(1, "issue controller feeder M mask/count mismatch");
        end
      end
      if (tile_done && state_q != ST_WAIT_CONTEXT)
        $fatal(1, "issue controller observed an unexpected tile_done");
    end
  end
`endif

endmodule
