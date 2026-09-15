`timescale 1ns/1ps

// Self-testable M8xN128 compute island used to measure realistic K26 headroom
// before changing the complete AlexNet graph scheduler.  The datapath is a
// real connection of the M16 row-stationary feeder, N128 URAM weight
// ping-pong, dynamic 2xM8xN64 array, and one 64-DSP M8xN8 requant engine.
//
// The built-in transaction uses a 16x16/C3/K3/S1/P1 frame.  Sixteen spatial
// M16 tiles exercise all eight N16 banks.  It is a resource/timing and board
// smoke-test workload, not an AlexNet classification claim.
module alexnet_m8n128_compute_island (
    input  logic clk,
    input  logic rst,
    input  logic start_valid,
    output logic start_ready,
    input  logic [31:0] seed,

    output logic busy,
    output logic done,
    output logic fault,
    output logic [31:0] result_signature,
    output logic [15:0] completed_tiles,
    output logic [31:0] active_cycles,
    output logic [31:0] issue_cycles,
    output logic [31:0] weight_stall_cycles,
    output logic [31:0] activation_stall_cycles,
    output logic [31:0] result_stall_cycles,
    output logic [63:0] useful_mac_count,
    output logic [63:0] peak_mac_slot_count
);

  localparam int INPUT_H = 16;
  localparam int INPUT_W = 16;
  localparam int PIXELS = INPUT_H * INPUT_W;
  localparam int K_COUNT = 3 * 3 * 3;
  localparam int WEIGHT_BEATS = K_COUNT * 8;
  localparam int RESULT_SLICES = 16;
  localparam int LOGICAL_N = 126;
  localparam logic [15:0] CONTEXT_TAG = 16'h8128;

  typedef enum logic [3:0] {
    ST_IDLE,
    ST_ARM,
    ST_LOAD,
    ST_WAIT_TILE,
    ST_WAIT_WEIGHT,
    ST_CLEAR,
    ST_ISSUE,
    ST_DRAIN,
    ST_WAIT_RESULT,
    ST_FINISH
  } state_t;

  state_t state_q;
  logic [31:0] lfsr_q;
  logic frame_cfg_sent_q;
  logic weight_cfg_sent_q;
  logic requant_cfg_sent_q;
  logic weights_ready_q;
  logic frame_done_seen_q;
  logic [8:0] pixel_count_q;
  logic [8:0] weight_beat_count_q;
  logic [4:0] result_slice_issue_q;
  logic [4:0] result_slice_egress_q;
  logic [15:0] compute_tile_index_q;

  logic feeder_frame_valid;
  logic feeder_frame_ready;
  logic feeder_s_valid;
  logic feeder_s_ready;
  logic [63:0] feeder_s_values;
  logic feeder_m_valid;
  logic feeder_m_ready;
  logic signed [7:0] feeder_act_lo [0:7];
  logic signed [7:0] feeder_act_hi [0:7];
  logic [1:0] feeder_lane_mask [0:7];
  logic feeder_tile_clear;
  logic feeder_reduce_last;
  logic [9:0] feeder_k;
  logic [3:0] feeder_input_channel;
  logic [4:0] feeder_m_count;
  logic [7:0] feeder_output_y;
  logic [7:0] feeder_output_x;
  logic [15:0] feeder_frame_tag;
  logic feeder_frame_active;
  logic feeder_frame_done;
  logic feeder_idle;

  logic weight_fill_valid;
  logic weight_fill_ready;
  logic weight_write_valid;
  logic weight_write_ready;
  logic [127:0] weight_write_values;
  logic weight_write_last;
  logic [11:0] weight_write_k;
  logic [2:0] weight_write_bank_slot;
  logic weight_replay_valid;
  logic weight_replay_ready;
  logic weight_valid;
  logic weight_ready;
  logic signed [7:0] weight_values [0:7][0:15];
  logic [11:0] weight_k;
  logic weight_last;
  logic [7:0] weight_bank_enable;
  logic [15:0] weight_n_lane_mask [0:7];
  logic [15:0] weight_context_tag;
  logic [1:0] weight_set_state [0:1];
  logic [1:0] weight_ready_set_mask;
  logic weight_fill_active;
  logic weight_active_fill_set;
  logic weight_replay_active;
  logic weight_active_replay_set;
  logic [15:0] weight_words_written;
  logic [15:0] weight_completed_fills;
  logic [15:0] weight_completed_replays;
  logic weight_fill_done;
  logic weight_replay_done;
  logic weight_context_error;
  logic weight_protocol_error;
  logic weight_idle;

  logic group_ce [0:1];
  logic signed [7:0] group_act_lo [0:1][0:3];
  logic signed [7:0] group_act_hi [0:1][0:3];
  logic group_issue_valid [0:1];
  logic group_tile_clear [0:1];
  logic group_reduce_last [0:1];
  logic [1:0] group_m_lane_mask [0:1][0:3];
  logic [15:0] group_tile_tag [0:1];
  logic sa_result_valid [0:7][0:3][0:15];
  logic sa_result_ready [0:7][0:3][0:15];
  logic signed [31:0] sa_result_lo [0:7][0:3][0:15];
  logic signed [31:0] sa_result_hi [0:7][0:3][0:15];
  logic [1:0] sa_result_lane_mask [0:7][0:3][0:15];
  logic sa_bank_source_group [0:7];
  logic [2:0] sa_bank_n16_slot [0:7];
  logic [15:0] sa_bank_result_tag [0:7];

  logic requant_cfg_valid;
  logic requant_cfg_ready;
  logic signed [31:0] requant_cfg_bias [0:7];
  logic signed [17:0] requant_cfg_multiplier [0:7];
  logic [5:0] requant_cfg_right_shift [0:7];
  logic [7:0] requant_cfg_relu;
  logic requant_ingress_valid;
  logic requant_ingress_ready;
  logic signed [31:0] requant_accumulator [0:7][0:7];
  logic requant_egress_valid;
  logic [63:0] requant_egress_values [0:7];
  logic [7:0] requant_egress_lane_mask [0:7];
  logic [3:0] requant_egress_m_count;
  logic [15:0] requant_egress_tile_tag;
  logic requant_idle;

  logic frame_cfg_fire;
  logic weight_cfg_fire;
  logic requant_cfg_fire;
  logic pixel_fire;
  logic weight_write_fire;
  logic weight_replay_fire;
  logic issue_fire;
  logic requant_ingress_fire;
  logic selected_slice_valid;
  logic [31:0] selected_slice_valid_vector;
  logic [2:0] selected_bank;
  logic selected_half;
  logic [31:0] egress_fold;

  assign start_ready = state_q == ST_IDLE;
  assign frame_cfg_fire = feeder_frame_valid && feeder_frame_ready;
  assign weight_cfg_fire = weight_fill_valid && weight_fill_ready;
  assign requant_cfg_fire = requant_cfg_valid && requant_cfg_ready;
  assign pixel_fire = feeder_s_valid && feeder_s_ready;
  assign weight_write_fire = weight_write_valid && weight_write_ready;
  assign weight_replay_fire = weight_replay_valid && weight_replay_ready;
  assign issue_fire = state_q == ST_ISSUE && feeder_m_valid && weight_valid;
  assign requant_ingress_fire = requant_ingress_valid &&
                                requant_ingress_ready;

  assign feeder_frame_valid = state_q == ST_ARM && !frame_cfg_sent_q;
  assign weight_fill_valid = state_q == ST_ARM && !weight_cfg_sent_q;
  assign requant_cfg_valid = state_q == ST_ARM && !requant_cfg_sent_q;

  assign feeder_s_valid = state_q != ST_IDLE && state_q != ST_ARM &&
                          state_q != ST_FINISH && pixel_count_q < PIXELS;
  assign weight_write_valid = state_q != ST_IDLE && state_q != ST_ARM &&
                              state_q != ST_FINISH &&
                              weight_beat_count_q < WEIGHT_BEATS;
  assign weight_write_last = weight_beat_count_q == WEIGHT_BEATS-1;

  assign weight_replay_valid = state_q == ST_WAIT_TILE && feeder_m_valid &&
                               feeder_k == 0;
  assign feeder_m_ready = state_q == ST_ISSUE && weight_valid;
  assign weight_ready = state_q == ST_ISSUE && feeder_m_valid;

  // Clamp the array indices after the last slice.  The valid term below still
  // blocks ingress, while the clamp prevents an out-of-range combinational
  // read from becoming implementation-dependent during the egress tail.
  assign selected_bank = result_slice_issue_q < RESULT_SLICES ?
                         result_slice_issue_q[3:1] : 3'd0;
  assign selected_half = result_slice_issue_q < RESULT_SLICES ?
                         result_slice_issue_q[0] : 1'b0;
  assign requant_ingress_valid = state_q == ST_DRAIN &&
                                 result_slice_issue_q < RESULT_SLICES &&
                                 selected_slice_valid;

  always_comb begin
    feeder_s_values = '0;
    for (int lane = 0; lane < 8; lane++)
      feeder_s_values[lane*8 +: 8] =
          lfsr_q[7:0] ^ 8'(pixel_count_q + lane*13);

    weight_write_values = '0;
    for (int lane = 0; lane < 16; lane++)
      weight_write_values[lane*8 +: 8] =
          lfsr_q[23:16] ^ 8'(weight_beat_count_q + lane*11);

    for (int lane = 0; lane < 8; lane++) begin
      requant_cfg_bias[lane] = '0;
      requant_cfg_multiplier[lane] = 18'sd65540;
      requant_cfg_right_shift[lane] = 6'd23;
    end
    requant_cfg_relu = '0;

    for (int group = 0; group < 2; group++) begin
      // After the final source token, keep the local systolic registers
      // advancing until reduce_last reaches every row/column holding slot.
      group_ce[group] = state_q == ST_CLEAR || issue_fire ||
                        state_q == ST_DRAIN;
      group_issue_valid[group] = issue_fire;
      group_tile_clear[group] = state_q == ST_CLEAR;
      group_reduce_last[group] = issue_fire && feeder_reduce_last &&
                                 weight_last;
      group_tile_tag[group] = {compute_tile_index_q[13:0], group[0], 1'b0};
      for (int row = 0; row < 4; row++) begin
        group_act_lo[group][row] = feeder_act_lo[group*4+row];
        group_act_hi[group][row] = feeder_act_hi[group*4+row];
        group_m_lane_mask[group][row] =
            feeder_lane_mask[group*4+row];
      end
    end

    for (int row = 0; row < 4; row++) begin
      for (int col = 0; col < 8; col++) begin
        selected_slice_valid_vector[row*8+col] =
            sa_result_valid[selected_bank][row][selected_half*8+col];
      end
    end
    // A packed reduction lets synthesis build a balanced tree.  Updating a
    // scalar with &= inside the bank/row/column loop formed a 201-LUT serial
    // chain after elaboration and dominated the entire top-level STA result.
    selected_slice_valid = result_slice_issue_q < RESULT_SLICES &&
                           (&selected_slice_valid_vector);
    for (int bank = 0; bank < 8; bank++) begin
      for (int row = 0; row < 4; row++) begin
        for (int col = 0; col < 16; col++) begin
          sa_result_ready[bank][row][col] = 1'b0;
        end
      end
    end
    if (result_slice_issue_q < RESULT_SLICES) begin
      for (int row = 0; row < 4; row++) begin
        for (int col = 0; col < 8; col++) begin
          sa_result_ready[selected_bank][row][selected_half*8+col] =
              requant_ingress_valid && requant_ingress_ready;
        end
      end
    end

    for (int row = 0; row < 4; row++) begin
      for (int col = 0; col < 8; col++) begin
        requant_accumulator[2*row][col] =
            sa_result_lo[selected_bank][row][selected_half*8+col];
        requant_accumulator[2*row+1][col] =
            sa_result_hi[selected_bank][row][selected_half*8+col];
      end
    end

    egress_fold = '0;
    for (int row = 0; row < 8; row++)
      egress_fold ^= requant_egress_values[row][31:0] ^
                     requant_egress_values[row][63:32] ^
                     {24'b0, requant_egress_lane_mask[row]};
    egress_fold ^= {16'b0, requant_egress_tile_tag};
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      state_q <= ST_IDLE;
      lfsr_q <= 32'h1;
      frame_cfg_sent_q <= 1'b0;
      weight_cfg_sent_q <= 1'b0;
      requant_cfg_sent_q <= 1'b0;
      weights_ready_q <= 1'b0;
      frame_done_seen_q <= 1'b0;
      pixel_count_q <= '0;
      weight_beat_count_q <= '0;
      result_slice_issue_q <= '0;
      result_slice_egress_q <= '0;
      compute_tile_index_q <= '0;
      busy <= 1'b0;
      done <= 1'b0;
      fault <= 1'b0;
      result_signature <= '0;
      completed_tiles <= '0;
      active_cycles <= '0;
      issue_cycles <= '0;
      weight_stall_cycles <= '0;
      activation_stall_cycles <= '0;
      result_stall_cycles <= '0;
      useful_mac_count <= '0;
      peak_mac_slot_count <= '0;
    end else begin
      done <= 1'b0;

      if (busy)
        active_cycles <= active_cycles + 1'b1;

      if (pixel_fire) begin
        pixel_count_q <= pixel_count_q + 1'b1;
        lfsr_q <= {lfsr_q[30:0],
                   lfsr_q[31] ^ lfsr_q[21] ^ lfsr_q[1] ^ lfsr_q[0]};
      end
      if (weight_write_fire)
        weight_beat_count_q <= weight_beat_count_q + 1'b1;
      if (weight_fill_done)
        weights_ready_q <= 1'b1;
      if (feeder_frame_done)
        frame_done_seen_q <= 1'b1;

      if (issue_fire) begin
        issue_cycles <= issue_cycles + 1'b1;
        peak_mac_slot_count <= peak_mac_slot_count + 64'd1024;
        // The physical M8xN128 array still issues 1024 packed-MAC slots.
        // The logical N126 workload keeps 1008 useful slots on a full issue.
        useful_mac_count <= useful_mac_count +
                            feeder_m_count * (LOGICAL_N / 2);
      end
      if (state_q == ST_ISSUE && feeder_m_valid && !weight_valid)
        weight_stall_cycles <= weight_stall_cycles + 1'b1;
      if (state_q == ST_ISSUE && !feeder_m_valid && weight_valid)
        activation_stall_cycles <= activation_stall_cycles + 1'b1;
      if (state_q == ST_DRAIN && result_slice_issue_q < RESULT_SLICES &&
          (!selected_slice_valid || !requant_ingress_ready))
        result_stall_cycles <= result_stall_cycles + 1'b1;

      if (requant_ingress_fire)
        result_slice_issue_q <= result_slice_issue_q + 1'b1;
      if (requant_egress_valid) begin
        result_signature <= {result_signature[30:0],
                             result_signature[31]} ^ egress_fold;
        if (result_slice_egress_q == RESULT_SLICES-1) begin
          result_slice_egress_q <= '0;
          completed_tiles <= completed_tiles + 1'b1;
        end else begin
          result_slice_egress_q <= result_slice_egress_q + 1'b1;
        end
      end

      fault <= fault || weight_context_error || weight_protocol_error;

      case (state_q)
        ST_IDLE: begin
          busy <= 1'b0;
          if (start_valid) begin
            state_q <= ST_ARM;
            lfsr_q <= seed == 0 ? 32'h1 : seed;
            frame_cfg_sent_q <= 1'b0;
            weight_cfg_sent_q <= 1'b0;
            requant_cfg_sent_q <= 1'b0;
            weights_ready_q <= 1'b0;
            frame_done_seen_q <= 1'b0;
            pixel_count_q <= '0;
            weight_beat_count_q <= '0;
            result_slice_issue_q <= '0;
            result_slice_egress_q <= '0;
            compute_tile_index_q <= '0;
            completed_tiles <= '0;
            active_cycles <= '0;
            issue_cycles <= '0;
            weight_stall_cycles <= '0;
            activation_stall_cycles <= '0;
            result_stall_cycles <= '0;
            useful_mac_count <= '0;
            peak_mac_slot_count <= '0;
            result_signature <= '0;
            fault <= 1'b0;
            busy <= 1'b1;
          end
        end

        ST_ARM: begin
          if (frame_cfg_fire)
            frame_cfg_sent_q <= 1'b1;
          if (weight_cfg_fire)
            weight_cfg_sent_q <= 1'b1;
          if (requant_cfg_fire)
            requant_cfg_sent_q <= 1'b1;
          if ((frame_cfg_sent_q || frame_cfg_fire) &&
              (weight_cfg_sent_q || weight_cfg_fire) &&
              (requant_cfg_sent_q || requant_cfg_fire))
            state_q <= ST_LOAD;
        end

        ST_LOAD: begin
          if (weights_ready_q || weight_fill_done)
            state_q <= ST_WAIT_TILE;
        end

        ST_WAIT_TILE: begin
          if (weight_replay_fire)
            state_q <= ST_WAIT_WEIGHT;
        end

        ST_WAIT_WEIGHT: begin
          if (feeder_m_valid && weight_valid)
            state_q <= ST_CLEAR;
        end

        ST_CLEAR: begin
          result_slice_issue_q <= '0;
          state_q <= ST_ISSUE;
        end

        ST_ISSUE: begin
          if (issue_fire && feeder_reduce_last && weight_last)
            state_q <= ST_DRAIN;
        end

        ST_DRAIN: begin
          // Once all sixteen hold slices have entered the pipelined requantizer,
          // every PE holding register is free.  Start preparing the next tile
          // while the five-stage requant tail completes in the background.
          if (requant_ingress_fire &&
              result_slice_issue_q == RESULT_SLICES-1) begin
            compute_tile_index_q <= compute_tile_index_q + 1'b1;
            if (frame_done_seen_q || feeder_frame_done)
              state_q <= ST_WAIT_RESULT;
            else
              state_q <= ST_WAIT_TILE;
          end
        end

        ST_WAIT_RESULT: begin
          if (requant_egress_valid &&
              result_slice_egress_q == RESULT_SLICES-1)
            state_q <= ST_FINISH;
        end

        ST_FINISH: begin
          busy <= 1'b0;
          done <= 1'b1;
          state_q <= ST_IDLE;
        end

        default: begin
          fault <= 1'b1;
          state_q <= ST_FINISH;
        end
      endcase
    end
  end

  alexnet_n8_rs_m16_feeder u_feeder (
      .clk,
      .rst,
      .frame_valid(feeder_frame_valid),
      .frame_ready(feeder_frame_ready),
      .frame_input_h(8'(INPUT_H)),
      .frame_input_w(8'(INPUT_W)),
      .frame_channel_count(4'd3),
      .frame_lane_mask(8'h07),
      .frame_kernel(4'd3),
      .frame_stride(3'd1),
      .frame_padding(3'd1),
      .frame_tag(CONTEXT_TAG),
      .s_valid(feeder_s_valid),
      .s_ready(feeder_s_ready),
      .s_values(feeder_s_values),
      .s_lane_mask(8'h07),
      .m_valid(feeder_m_valid),
      .m_ready(feeder_m_ready),
      .m_act_lo(feeder_act_lo),
      .m_act_hi(feeder_act_hi),
      .m_lane_mask(feeder_lane_mask),
      .m_tile_clear(feeder_tile_clear),
      .m_reduce_last(feeder_reduce_last),
      .m_k(feeder_k),
      .m_input_channel(feeder_input_channel),
      .m_count(feeder_m_count),
      .m_output_y(feeder_output_y),
      .m_output_x(feeder_output_x),
      .m_frame_tag(feeder_frame_tag),
      .frame_active(feeder_frame_active),
      .frame_done(feeder_frame_done),
      .idle(feeder_idle)
  );

  alexnet_n128_weight_pingpong #(
      .DEPTH(4096)
  ) u_weight_pingpong (
      .clk,
      .rst,
      .fill_valid(weight_fill_valid),
      .fill_ready(weight_fill_ready),
      .fill_k_count(13'(K_COUNT)),
      .fill_bank_enable(8'hff),
      .fill_n_lane_mask('{16'hffff, 16'hffff, 16'hffff, 16'hffff,
                          16'hffff, 16'hffff, 16'hffff, 16'h3fff}),
      .fill_context_tag(CONTEXT_TAG),
      .write_valid(weight_write_valid),
      .write_ready(weight_write_ready),
      .write_values(weight_write_values),
      .write_last(weight_write_last),
      .write_k(weight_write_k),
      .write_bank_slot(weight_write_bank_slot),
      .replay_valid(weight_replay_valid),
      .replay_ready(weight_replay_ready),
      .replay_k_count(13'(K_COUNT)),
      .replay_bank_enable(8'hff),
      .replay_n_lane_mask('{16'hffff, 16'hffff, 16'hffff, 16'hffff,
                            16'hffff, 16'hffff, 16'hffff, 16'h3fff}),
      .replay_context_tag(CONTEXT_TAG),
      .weight_valid(weight_valid),
      .weight_ready(weight_ready),
      .weight_values(weight_values),
      .weight_k(weight_k),
      .weight_last(weight_last),
      .weight_bank_enable(weight_bank_enable),
      .weight_n_lane_mask(weight_n_lane_mask),
      .weight_context_tag(weight_context_tag),
      .release_valid(1'b0),
      .release_ready(),
      .release_context_tag('0),
      .set_state(weight_set_state),
      .ready_set_mask(weight_ready_set_mask),
      .fill_active(weight_fill_active),
      .active_fill_set(weight_active_fill_set),
      .replay_active(weight_replay_active),
      .active_replay_set(weight_active_replay_set),
      .words_written(weight_words_written),
      .completed_fills(weight_completed_fills),
      .completed_replays(weight_completed_replays),
      .fill_done(weight_fill_done),
      .replay_done(weight_replay_done),
      .context_error(weight_context_error),
      .protocol_error(weight_protocol_error),
      .idle(weight_idle)
  );

  alexnet_sa_m8n128_dynamic u_dynamic_sa (
      .clk,
      .rst,
      .mode_split_n64(1'b1),
      .bank_enable(weight_bank_enable),
      .group_ce,
      .group_act_lo,
      .group_act_hi,
      .group_issue_valid,
      .group_tile_clear,
      .group_reduce_last,
      .group_m_lane_mask,
      .group_tile_tag,
      .bank_weight(weight_values),
      .result_valid(sa_result_valid),
      .result_ready(sa_result_ready),
      .result_lo(sa_result_lo),
      .result_hi(sa_result_hi),
      .result_lane_mask(sa_result_lane_mask),
      .bank_source_group(sa_bank_source_group),
      .bank_n16_slot(sa_bank_n16_slot),
      .bank_result_tag(sa_bank_result_tag)
  );

  alexnet_m8n8_parallel_requant u_requant (
      .clk,
      .rst,
      .cfg_valid(requant_cfg_valid),
      .cfg_ready(requant_cfg_ready),
      .cfg_bias(requant_cfg_bias),
      .cfg_multiplier(requant_cfg_multiplier),
      .cfg_right_shift(requant_cfg_right_shift),
      .cfg_relu(requant_cfg_relu),
      .ingress_valid(requant_ingress_valid),
      .ingress_ready(requant_ingress_ready),
      .ingress_m_count(4'd8),
      .ingress_accumulator(requant_accumulator),
      .ingress_lane_mask(result_slice_issue_q == RESULT_SLICES-1 ?
                         8'h3f : 8'hff),
      .ingress_tile_tag(sa_bank_result_tag[selected_bank]),
      .egress_valid(requant_egress_valid),
      .egress_ready(1'b1),
      .egress_m_count(requant_egress_m_count),
      .egress_values(requant_egress_values),
      .egress_lane_mask(requant_egress_lane_mask),
      .egress_tile_tag(requant_egress_tile_tag),
      .idle(requant_idle)
  );

`ifndef SYNTHESIS
  always_ff @(posedge clk) begin
    if (!rst) begin
      if (state_q == ST_WAIT_TILE && feeder_m_valid && feeder_k != 0)
        $fatal(1, "compute island lost the feeder tile boundary");
      if (issue_fire && feeder_k != weight_k)
        $fatal(1, "compute island activation/weight K mismatch");
      if (issue_fire && feeder_tile_clear != (feeder_k == 0))
        $fatal(1, "compute island feeder clear metadata mismatch");
      if (issue_fire && feeder_reduce_last != weight_last)
        $fatal(1, "compute island reduction-last mismatch");
      if (compute_tile_index_q < completed_tiles)
        $fatal(1, "compute island retired a result before its compute tile");
    end
  end
`endif

endmodule
