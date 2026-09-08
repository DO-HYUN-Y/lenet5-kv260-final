`timescale 1ns/1ps

// Converts the stored N8 activation layout into one M4xN8 fully-connected
// tile issue stream without changing the packed PE or SA boundary.
//
// Activation words arrive block-major, then M-major:
//
//   [k_block][m][k_lane]
//
// One word therefore holds eight adjacent flattened features for one batch
// position. Up to four words are buffered and transposed into eight K cycles.
// Resident weights already arrive in the required [k][n_lane] order. A K tail
// uses a low-contiguous activation lane mask. The issuer owns exactly one
// weight replay and one SA tile at a time; K chunks are separate descriptors
// and are accumulated by the unchanged downstream partial-sum path.
module alexnet_n8_fc_m4_issuer #(
    parameter int K_COUNT_W = 10,
    parameter int TILE_TAG_W = 16,
    parameter int TENSOR_TAG_W = 16,
    parameter int WEIGHT_CONTEXT_TAG_W = 16
) (
    input logic clk,
    input logic rst,

    input  logic descriptor_valid,
    output logic descriptor_ready,
    input  logic [K_COUNT_W-1:0] descriptor_k_count,
    input  logic [2:0] descriptor_m_count,
    input  logic [7:0] descriptor_n_lane_mask,
    input  logic [TENSOR_TAG_W-1:0] descriptor_activation_tensor_tag,
    input  logic [WEIGHT_CONTEXT_TAG_W-1:0]
        descriptor_weight_context_tag,
    input  logic [TILE_TAG_W-1:0] descriptor_tile_tag,

    input  logic activation_valid,
    output logic activation_ready,
    input  logic [63:0] activation_values,
    input  logic [7:0] activation_lane_mask,
    input  logic activation_last,
    input  logic [TENSOR_TAG_W-1:0] activation_tensor_tag,

    output logic weight_replay_valid,
    input  logic weight_replay_ready,
    output logic [K_COUNT_W-1:0] weight_replay_k_count,
    output logic [7:0] weight_replay_n_lane_mask,
    output logic [WEIGHT_CONTEXT_TAG_W-1:0]
        weight_replay_context_tag,

    input  logic weight_valid,
    output logic weight_ready,
    input  logic signed [7:0] weight_values [0:7],
    input  logic [K_COUNT_W-1:0] weight_k,
    input  logic weight_last,
    input  logic [7:0] weight_n_lane_mask,
    input  logic [WEIGHT_CONTEXT_TAG_W-1:0] weight_context_tag,

    output logic tile_start_valid,
    input  logic tile_start_ready,
    output logic [2:0] tile_m_count,
    output logic [7:0] tile_n_lane_mask,
    output logic [TILE_TAG_W-1:0] tile_tag,

    output logic issue_valid,
    input  logic issue_ready,
    output logic issue_last,
    output logic signed [7:0] issue_act_lo [0:1],
    output logic signed [7:0] issue_act_hi [0:1],
    output logic signed [7:0] issue_weight [0:7],
    input  logic tile_done,

    output logic issuer_idle,
    output logic descriptor_active,
    output logic descriptor_done,
    output logic descriptor_rejected,
    output logic protocol_error,
    output logic [2:0] phase,
    output logic [K_COUNT_W-1:0] active_k,
    output logic [K_COUNT_W:0] activation_words_consumed,
    output logic [15:0] accepted_descriptors,
    output logic [15:0] completed_descriptors,
    output logic [15:0] rejected_descriptors,
    output logic [31:0] completed_k_tokens
);

  typedef enum logic [2:0] {
    ST_IDLE = 3'd0,
    ST_VALIDATE = 3'd1,
    ST_WEIGHT_REPLAY = 3'd2,
    ST_FILL_ACTIVATION = 3'd3,
    ST_START_TILE = 3'd4,
    ST_ISSUE = 3'd5,
    ST_WAIT_TILE = 3'd6
  } state_t;

  state_t state_q;
  logic [K_COUNT_W-1:0] k_count_q;
  logic [2:0] m_count_q;
  logic [7:0] n_lane_mask_q;
  logic [TENSOR_TAG_W-1:0] activation_tensor_tag_q;
  logic [WEIGHT_CONTEXT_TAG_W-1:0] weight_context_tag_q;
  logic [TILE_TAG_W-1:0] tile_tag_q;
  logic [63:0] activation_block_q [0:3];
  logic [2:0] fill_m_q;
  logic tile_started_q;

  logic descriptor_fire;
  logic activation_fire;
  logic weight_replay_fire;
  logic tile_start_fire;
  logic issue_fire;
  logic descriptor_shape_valid;
  logic weight_metadata_match;
  logic activation_metadata_match;
  logic [K_COUNT_W:0] remaining_k;
  logic [3:0] block_lane_count;
  logic [7:0] expected_activation_lane_mask;
  logic expected_activation_last;
  logic [63:0] masked_activation_values;

  assign phase = state_q;
  assign issuer_idle = state_q == ST_IDLE;
  assign descriptor_active = state_q != ST_IDLE;
  assign descriptor_ready = state_q == ST_IDLE;
  assign descriptor_fire = descriptor_valid && descriptor_ready;

  assign descriptor_shape_valid =
      (k_count_q != 0) && (m_count_q != 0) && (m_count_q <= 4) &&
      (n_lane_mask_q != 0) &&
      ((n_lane_mask_q & (n_lane_mask_q + 1'b1)) == 0);

  assign weight_replay_valid = state_q == ST_WEIGHT_REPLAY;
  assign weight_replay_k_count = k_count_q;
  assign weight_replay_n_lane_mask = n_lane_mask_q;
  assign weight_replay_context_tag = weight_context_tag_q;
  assign weight_replay_fire = weight_replay_valid && weight_replay_ready;

  assign activation_ready = state_q == ST_FILL_ACTIVATION;
  assign activation_fire = activation_valid && activation_ready;

  always_comb begin
    remaining_k = {1'b0, k_count_q} - {1'b0, active_k};
    if (remaining_k >= 8) begin
      block_lane_count = 4'd8;
      expected_activation_lane_mask = 8'hff;
    end else begin
      block_lane_count = remaining_k[3:0];
      expected_activation_lane_mask =
          (9'b1 << remaining_k[3:0]) - 1'b1;
    end
  end

  assign expected_activation_last =
      (remaining_k <= 8) && (fill_m_q + 1'b1 == m_count_q);
  assign activation_metadata_match =
      (activation_lane_mask == expected_activation_lane_mask) &&
      (activation_last == expected_activation_last) &&
      (activation_tensor_tag == activation_tensor_tag_q);

  always_comb begin
    masked_activation_values = '0;
    for (int lane = 0; lane < 8; lane++) begin
      if (expected_activation_lane_mask[lane] &&
          activation_lane_mask[lane])
        masked_activation_values[lane*8 +: 8] =
            activation_values[lane*8 +: 8];
    end
  end

  assign tile_start_valid = state_q == ST_START_TILE;
  assign tile_m_count = m_count_q;
  assign tile_n_lane_mask = n_lane_mask_q;
  assign tile_tag = tile_tag_q;
  assign tile_start_fire = tile_start_valid && tile_start_ready;

  assign weight_metadata_match =
      (weight_k == active_k) &&
      (weight_last == (active_k + 1'b1 == k_count_q)) &&
      (weight_n_lane_mask == n_lane_mask_q) &&
      (weight_context_tag == weight_context_tag_q);
  assign issue_valid = (state_q == ST_ISSUE) && weight_valid;
  assign weight_ready = (state_q == ST_ISSUE) && issue_ready;
  assign issue_last = active_k + 1'b1 == k_count_q;
  assign issue_fire = issue_valid && issue_ready;

  always_comb begin
    issue_act_lo[0] =
        $signed(activation_block_q[0][active_k[2:0]*8 +: 8]);
    issue_act_hi[0] =
        $signed(activation_block_q[1][active_k[2:0]*8 +: 8]);
    issue_act_lo[1] =
        $signed(activation_block_q[2][active_k[2:0]*8 +: 8]);
    issue_act_hi[1] =
        $signed(activation_block_q[3][active_k[2:0]*8 +: 8]);
    for (int lane = 0; lane < 8; lane++)
      issue_weight[lane] = weight_values[lane];
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      state_q <= ST_IDLE;
      k_count_q <= '0;
      m_count_q <= '0;
      n_lane_mask_q <= '0;
      activation_tensor_tag_q <= '0;
      weight_context_tag_q <= '0;
      tile_tag_q <= '0;
      fill_m_q <= '0;
      tile_started_q <= 1'b0;
      active_k <= '0;
      activation_words_consumed <= '0;
      descriptor_done <= 1'b0;
      descriptor_rejected <= 1'b0;
      protocol_error <= 1'b0;
      accepted_descriptors <= '0;
      completed_descriptors <= '0;
      rejected_descriptors <= '0;
      completed_k_tokens <= '0;
      for (int m = 0; m < 4; m++)
        activation_block_q[m] <= '0;
    end else begin
      descriptor_done <= 1'b0;
      descriptor_rejected <= 1'b0;

      if (descriptor_fire) begin
        k_count_q <= descriptor_k_count;
        m_count_q <= descriptor_m_count;
        n_lane_mask_q <= descriptor_n_lane_mask;
        activation_tensor_tag_q <= descriptor_activation_tensor_tag;
        weight_context_tag_q <= descriptor_weight_context_tag;
        tile_tag_q <= descriptor_tile_tag;
        fill_m_q <= '0;
        tile_started_q <= 1'b0;
        active_k <= '0;
        activation_words_consumed <= '0;
        protocol_error <= 1'b0;
        accepted_descriptors <= accepted_descriptors + 1'b1;
        for (int m = 0; m < 4; m++)
          activation_block_q[m] <= '0;
        state_q <= ST_VALIDATE;
      end

      case (state_q)
        ST_IDLE: begin
        end
        ST_VALIDATE: begin
          if (descriptor_shape_valid) begin
            state_q <= ST_WEIGHT_REPLAY;
          end else begin
            descriptor_rejected <= 1'b1;
            rejected_descriptors <= rejected_descriptors + 1'b1;
            state_q <= ST_IDLE;
          end
        end
        ST_WEIGHT_REPLAY: begin
          if (weight_replay_fire)
            state_q <= ST_FILL_ACTIVATION;
        end
        ST_FILL_ACTIVATION: begin
          if (activation_fire) begin
            activation_block_q[fill_m_q] <= masked_activation_values;
            activation_words_consumed <= activation_words_consumed + 1'b1;
            if (!activation_metadata_match)
              protocol_error <= 1'b1;
            if (fill_m_q + 1'b1 == m_count_q) begin
              fill_m_q <= '0;
              if (tile_started_q)
                state_q <= ST_ISSUE;
              else
                state_q <= ST_START_TILE;
            end else begin
              fill_m_q <= fill_m_q + 1'b1;
            end
          end
        end
        ST_START_TILE: begin
          if (tile_start_fire) begin
            tile_started_q <= 1'b1;
            state_q <= ST_ISSUE;
          end
        end
        ST_ISSUE: begin
          if (issue_fire) begin
            completed_k_tokens <= completed_k_tokens + 1'b1;
            if (!weight_metadata_match)
              protocol_error <= 1'b1;
            if (issue_last) begin
              state_q <= ST_WAIT_TILE;
            end else begin
              active_k <= active_k + 1'b1;
              if (active_k[2:0] == 3'd7) begin
                for (int m = 0; m < 4; m++)
                  activation_block_q[m] <= '0;
                state_q <= ST_FILL_ACTIVATION;
              end
            end
          end
        end
        ST_WAIT_TILE: begin
          if (tile_done) begin
            descriptor_done <= 1'b1;
            completed_descriptors <= completed_descriptors + 1'b1;
            state_q <= ST_IDLE;
          end
        end
        default: state_q <= ST_IDLE;
      endcase

      if (tile_done && state_q != ST_WAIT_TILE)
        protocol_error <= 1'b1;
    end
  end

`ifndef SYNTHESIS
  initial begin
    if (K_COUNT_W < 4)
      $fatal(1, "FC issuer K_COUNT_W must represent at least eight K lanes");
  end

  always_ff @(posedge clk) begin
    if (!rst) begin
      if (descriptor_ready &&
          (weight_replay_valid || activation_ready || tile_start_valid ||
           issue_valid))
        $fatal(1, "idle FC issuer exposed a downstream request");
      if (tile_start_fire && issue_valid)
        $fatal(1, "FC tile clear and K issue shared one cycle");
      if (issue_fire && active_k >= k_count_q)
        $fatal(1, "FC issuer exceeded descriptor K count");
      if (issue_fire && m_count_q == 0)
        $fatal(1, "FC issuer emitted an empty M tile");
      if (activation_fire && fill_m_q >= m_count_q)
        $fatal(1, "FC issuer activation M index exceeded descriptor");
    end
  end
`endif

endmodule
