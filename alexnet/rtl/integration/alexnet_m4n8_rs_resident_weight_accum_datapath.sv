`timescale 1ns/1ps

// Multi-channel-chunk row-stationary convolution with one resident N8 weight
// tile and one accumulator transaction. Each chunk atomically starts the
// raster feeder and accumulator descriptor, replays its resident weight tile
// for every spatial M group, then releases only the weight ownership. Partial
// sums remain resident between chunks and are requantized only after the final
// chunk.
module alexnet_m4n8_rs_resident_weight_accum_datapath #(
    parameter int SLICE_INDEX = 0,
    parameter int FIFO_DEPTH = 64,
    parameter int MAX_INPUT_WIDTH = 224,
    parameter int WEIGHT_DEPTH = 968,
    parameter int BANK_DEPTH = 512,
    parameter int DIM_W = 8,
    parameter int K_INDEX_W = 10,
    parameter int TILE_TAG_W = 16,
    parameter int WEIGHT_CONTEXT_TAG_W = 16,
    parameter int ACCUM_CONTEXT_TAG_W = 16,
    parameter int CHUNK_INDEX_W = 8,
    parameter int N_BASE_W = 16,
    parameter int WEIGHT_COUNT_W = $clog2(WEIGHT_DEPTH + 1),
    parameter int BANK_COUNT_W = $clog2(BANK_DEPTH + 1)
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

    input  logic weight_fill_valid,
    output logic weight_fill_ready,
    input  logic [WEIGHT_COUNT_W-1:0] weight_fill_k_count,
    input  logic [7:0] weight_fill_n_lane_mask,
    input  logic [WEIGHT_CONTEXT_TAG_W-1:0] weight_fill_context_tag,
    input  logic weight_write_valid,
    output logic weight_write_ready,
    input  logic [63:0] weight_write_values,
    input  logic [7:0] weight_write_n_lane_mask,
    input  logic weight_write_last,
    input  logic weight_release_valid,
    output logic weight_release_ready,

    input  logic chunk_valid,
    output logic chunk_ready,
    input  logic [DIM_W-1:0] chunk_input_h,
    input  logic [DIM_W-1:0] chunk_input_w,
    input  logic [3:0] chunk_channel_count,
    input  logic [7:0] chunk_input_lane_mask,
    input  logic [3:0] chunk_kernel,
    input  logic [2:0] chunk_stride,
    input  logic [2:0] chunk_padding,
    input  logic [WEIGHT_COUNT_W-1:0] chunk_k_count,
    input  logic [WEIGHT_CONTEXT_TAG_W-1:0]
        chunk_weight_context_tag,
    input  logic [BANK_COUNT_W-1:0] chunk_word_count,
    input  logic [DIM_W-1:0] chunk_output_width,
    input  logic [ACCUM_CONTEXT_TAG_W-1:0] chunk_accum_context_tag,
    input  logic [TILE_TAG_W-1:0] chunk_tile_tag_base,
    input  logic [CHUNK_INDEX_W-1:0] chunk_index,
    input  logic chunk_first,
    input  logic chunk_final,

    input  logic s_valid,
    output logic s_ready,
    input  logic [63:0] s_values,
    input  logic [7:0] s_lane_mask,

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
    output logic chunk_frame_active,
    output logic chunk_done,
    output logic compute_busy,
    output logic transaction_active,
    output logic accum_chunk_active,
    output logic transaction_done,
    output logic pipeline_idle,
    output logic protocol_error,
    output logic accum_context_error,
    output logic weight_context_error,
    output logic [15:0] completed_tile_count,
    output logic [15:0] completed_weight_replays,
    output logic [1:0] weight_bank_state,
    output logic weight_resident_valid,
    output logic [WEIGHT_COUNT_W-1:0] resident_weight_k_count,
    output logic [WEIGHT_COUNT_W-1:0] resident_weight_words_written,
    output logic [7:0] resident_weight_n_lane_mask,
    output logic [WEIGHT_CONTEXT_TAG_W-1:0]
        resident_weight_context_tag,
    output logic weight_replay_done,
    output logic [2:0] accum_bank_state,
    output logic [$clog2(FIFO_DEPTH+1)-1:0] queued_count
);

  localparam logic [1:0] WEIGHT_STATE_WRITING = 2'd1;
  localparam logic [1:0] WEIGHT_STATE_READY = 2'd2;
  localparam logic [1:0] WEIGHT_STATE_REPLAYING = 2'd3;

  logic cfg_fire;
  logic base_cfg_valid;
  logic base_cfg_ready;
  logic [7:0] configured_n_lane_mask_q;

  logic bank_fill_valid;
  logic bank_fill_ready;
  logic bank_release_valid;
  logic bank_release_ready;
  logic bank_context_error;
  logic bank_replay_valid;
  logic bank_replay_ready;
  logic safe_bank_owner_change;

  logic chunk_context_match;
  logic chunk_boundary_ready;
  logic chunk_fire;
  logic feeder_frame_valid;
  logic feeder_frame_ready;
  logic feeder_frame_active;
  logic feeder_frame_done;
  logic feeder_idle;
  logic feeder_done_seen_q;
  logic base_chunk_valid;
  logic base_chunk_ready;
  logic base_chunk_done;
  logic base_chunk_done_seen_q;

  logic feeder_m_valid;
  logic feeder_m_ready;
  logic signed [7:0] feeder_act_lo [0:1];
  logic signed [7:0] feeder_act_hi [0:1];
  logic [1:0] feeder_m_lane_mask [0:1];
  logic feeder_tile_clear;
  logic feeder_reduce_last;
  logic [K_INDEX_W-1:0] feeder_k;
  logic [3:0] feeder_input_channel;
  logic [2:0] feeder_m_count;
  logic [DIM_W-1:0] feeder_output_y;
  logic [DIM_W-1:0] feeder_output_x;
  logic [TILE_TAG_W-1:0] feeder_frame_tag;

  logic controller_idle;
  logic controller_tile_inflight;
  logic controller_protocol_error;
  logic controller_weight_tile_valid;
  logic controller_weight_tile_ready;
  logic [15:0] controller_weight_tile_index;
  logic [2:0] controller_weight_tile_m_count;
  logic [DIM_W-1:0] controller_weight_tile_output_y;
  logic [DIM_W-1:0] controller_weight_tile_output_x;
  logic [TILE_TAG_W-1:0] controller_weight_tile_tag;

  logic bank_weight_valid;
  logic bank_weight_ready;
  logic signed [7:0] bank_weight_values [0:7];
  logic [K_INDEX_W-1:0] bank_weight_k;
  logic bank_weight_last;
  logic [7:0] bank_weight_n_lane_mask;
  logic [WEIGHT_CONTEXT_TAG_W-1:0] bank_weight_context_tag;

  logic base_tile_start_valid;
  logic base_tile_start_ready;
  logic [2:0] base_tile_m_count;
  logic [7:0] base_tile_n_lane_mask;
  logic [TILE_TAG_W-1:0] base_tile_tag;
  logic base_issue_valid;
  logic base_issue_ready;
  logic base_issue_last;
  logic signed [7:0] base_issue_act_lo [0:1];
  logic signed [7:0] base_issue_act_hi [0:1];
  logic signed [7:0] base_issue_weight [0:7];
  logic base_tile_done;
  logic base_datapath_idle;
  logic base_protocol_error;

  logic [WEIGHT_COUNT_W-1:0] active_k_count_q;
  logic [WEIGHT_CONTEXT_TAG_W-1:0] active_weight_context_tag_q;
  logic [11:0] derived_chunk_k_count;

  assign cfg_ready = !chunk_frame_active && feeder_idle && controller_idle &&
                     base_cfg_ready;
  assign cfg_fire = cfg_valid && cfg_ready;
  assign base_cfg_valid = cfg_fire;

  // Weight storage is independent of the partial-sum transaction. Once both
  // sides of the current chunk have retired, software may replace the tile
  // for the next input-channel chunk without clearing the accumulator bank.
  assign safe_bank_owner_change = !chunk_frame_active && feeder_idle &&
                                  controller_idle && !compute_busy &&
                                  !accum_chunk_active && !chunk_valid;
  assign bank_fill_valid = weight_fill_valid && safe_bank_owner_change;
  assign weight_fill_ready = bank_fill_ready && safe_bank_owner_change;
  assign bank_release_valid = weight_release_valid && safe_bank_owner_change;
  assign weight_release_ready = bank_release_ready && safe_bank_owner_change;

  assign chunk_context_match =
      (weight_bank_state == WEIGHT_STATE_READY) && weight_resident_valid &&
      (resident_weight_k_count == chunk_k_count) &&
      (resident_weight_n_lane_mask == configured_n_lane_mask_q) &&
      (resident_weight_context_tag == chunk_weight_context_tag);
  assign chunk_boundary_ready = configured && !chunk_frame_active &&
                                feeder_frame_ready && controller_idle &&
                                base_chunk_ready;
  assign chunk_ready = chunk_boundary_ready && chunk_context_match;
  assign chunk_fire = chunk_valid && chunk_ready;
  assign feeder_frame_valid = chunk_fire;
  assign base_chunk_valid = chunk_fire;

  assign controller_weight_tile_ready = bank_replay_ready;
  assign bank_replay_valid = controller_weight_tile_valid;

  assign protocol_error = controller_protocol_error || base_protocol_error;
  assign pipeline_idle = !chunk_frame_active && feeder_idle &&
                         controller_idle && base_datapath_idle &&
                         (weight_bank_state != WEIGHT_STATE_WRITING) &&
                         (weight_bank_state != WEIGHT_STATE_REPLAYING);

  always_comb begin
    case (chunk_kernel)
      11: derived_chunk_k_count = chunk_channel_count * 12'd121;
      5: derived_chunk_k_count = chunk_channel_count * 12'd25;
      3: derived_chunk_k_count = chunk_channel_count * 12'd9;
      default: derived_chunk_k_count = '0;
    endcase
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      configured_n_lane_mask_q <= '0;
      active_k_count_q <= '0;
      active_weight_context_tag_q <= '0;
      chunk_frame_active <= 1'b0;
      chunk_done <= 1'b0;
      feeder_done_seen_q <= 1'b0;
      base_chunk_done_seen_q <= 1'b0;
      weight_context_error <= 1'b0;
    end else begin
      chunk_done <= 1'b0;

      if (cfg_fire)
        configured_n_lane_mask_q <= cfg_lane_mask;

      if ((bank_fill_valid && bank_fill_ready) ||
          (bank_release_valid && bank_release_ready))
        weight_context_error <= 1'b0;
      else if (chunk_valid && chunk_boundary_ready && !chunk_context_match)
        weight_context_error <= 1'b1;
      else if (bank_context_error)
        weight_context_error <= 1'b1;

      if (chunk_fire) begin
        active_k_count_q <= chunk_k_count;
        active_weight_context_tag_q <= chunk_weight_context_tag;
        chunk_frame_active <= 1'b1;
        feeder_done_seen_q <= 1'b0;
        base_chunk_done_seen_q <= 1'b0;
      end

      if (feeder_frame_done)
        feeder_done_seen_q <= 1'b1;
      if (base_chunk_done)
        base_chunk_done_seen_q <= 1'b1;

      if (chunk_frame_active &&
          (feeder_done_seen_q || feeder_frame_done) &&
          (base_chunk_done_seen_q || base_chunk_done) && controller_idle &&
          !compute_busy && (weight_bank_state == WEIGHT_STATE_READY)) begin
        chunk_frame_active <= 1'b0;
        chunk_done <= 1'b1;
        feeder_done_seen_q <= 1'b0;
        base_chunk_done_seen_q <= 1'b0;
      end
    end
  end

  alexnet_n8_rs_m4_feeder #(
      .MAX_INPUT_WIDTH(MAX_INPUT_WIDTH),
      .DIM_W(DIM_W),
      .K_INDEX_W(K_INDEX_W),
      .FRAME_TAG_W(TILE_TAG_W)
  ) u_feeder (
      .clk(clk),
      .rst(rst),
      .frame_valid(feeder_frame_valid),
      .frame_ready(feeder_frame_ready),
      .frame_input_h(chunk_input_h),
      .frame_input_w(chunk_input_w),
      .frame_channel_count(chunk_channel_count),
      .frame_lane_mask(chunk_input_lane_mask),
      .frame_kernel(chunk_kernel),
      .frame_stride(chunk_stride),
      .frame_padding(chunk_padding),
      .frame_tag(chunk_tile_tag_base),
      .s_valid(s_valid),
      .s_ready(s_ready),
      .s_values(s_values),
      .s_lane_mask(s_lane_mask),
      .m_valid(feeder_m_valid),
      .m_ready(feeder_m_ready),
      .m_act_lo(feeder_act_lo),
      .m_act_hi(feeder_act_hi),
      .m_lane_mask(feeder_m_lane_mask),
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

  alexnet_m4n8_rs_issue_controller #(
      .DIM_W(DIM_W),
      .K_INDEX_W(K_INDEX_W),
      .TILE_TAG_W(TILE_TAG_W)
  ) u_issue_controller (
      .clk(clk),
      .rst(rst),
      .frame_start(chunk_fire),
      .tile_n_lane_mask(configured_n_lane_mask_q),
      .feeder_valid(feeder_m_valid),
      .feeder_ready(feeder_m_ready),
      .feeder_act_lo(feeder_act_lo),
      .feeder_act_hi(feeder_act_hi),
      .feeder_m_lane_mask(feeder_m_lane_mask),
      .feeder_tile_clear(feeder_tile_clear),
      .feeder_reduce_last(feeder_reduce_last),
      .feeder_k(feeder_k),
      .feeder_m_count(feeder_m_count),
      .feeder_output_y(feeder_output_y),
      .feeder_output_x(feeder_output_x),
      .feeder_frame_tag(feeder_frame_tag),
      .weight_tile_valid(controller_weight_tile_valid),
      .weight_tile_ready(controller_weight_tile_ready),
      .weight_tile_index(controller_weight_tile_index),
      .weight_tile_m_count(controller_weight_tile_m_count),
      .weight_tile_output_y(controller_weight_tile_output_y),
      .weight_tile_output_x(controller_weight_tile_output_x),
      .weight_tile_tag(controller_weight_tile_tag),
      .weight_valid(bank_weight_valid),
      .weight_ready(bank_weight_ready),
      .weight_values(bank_weight_values),
      .weight_k(bank_weight_k),
      .weight_last(bank_weight_last),
      .tile_start_valid(base_tile_start_valid),
      .tile_start_ready(base_tile_start_ready),
      .tile_m_count(base_tile_m_count),
      .tile_n_lane_mask_out(base_tile_n_lane_mask),
      .tile_tag(base_tile_tag),
      .issue_valid(base_issue_valid),
      .issue_ready(base_issue_ready),
      .issue_last(base_issue_last),
      .issue_act_lo(base_issue_act_lo),
      .issue_act_hi(base_issue_act_hi),
      .issue_weight(base_issue_weight),
      .tile_done(base_tile_done),
      .controller_idle(controller_idle),
      .tile_inflight(controller_tile_inflight),
      .completed_tile_count(completed_tile_count),
      .protocol_error(controller_protocol_error)
  );

  alexnet_n8_weight_tile_bank #(
      .DEPTH(WEIGHT_DEPTH),
      .CONTEXT_TAG_W(WEIGHT_CONTEXT_TAG_W),
      .ADDR_W(K_INDEX_W),
      .COUNT_W(WEIGHT_COUNT_W)
  ) u_weight_bank (
      .clk(clk),
      .rst(rst),
      .fill_valid(bank_fill_valid),
      .fill_ready(bank_fill_ready),
      .fill_k_count(weight_fill_k_count),
      .fill_n_lane_mask(weight_fill_n_lane_mask),
      .fill_context_tag(weight_fill_context_tag),
      .write_valid(weight_write_valid),
      .write_ready(weight_write_ready),
      .write_values(weight_write_values),
      .write_n_lane_mask(weight_write_n_lane_mask),
      .write_last(weight_write_last),
      .replay_valid(bank_replay_valid),
      .replay_ready(bank_replay_ready),
      .replay_k_count(active_k_count_q),
      .replay_n_lane_mask(configured_n_lane_mask_q),
      .replay_context_tag(active_weight_context_tag_q),
      .weight_valid(bank_weight_valid),
      .weight_ready(bank_weight_ready),
      .weight_values(bank_weight_values),
      .weight_k(bank_weight_k),
      .weight_last(bank_weight_last),
      .weight_n_lane_mask(bank_weight_n_lane_mask),
      .weight_context_tag(bank_weight_context_tag),
      .release_valid(bank_release_valid),
      .release_ready(bank_release_ready),
      .bank_state(weight_bank_state),
      .resident_valid(weight_resident_valid),
      .resident_k_count(resident_weight_k_count),
      .resident_n_lane_mask(resident_weight_n_lane_mask),
      .resident_context_tag(resident_weight_context_tag),
      .words_written(resident_weight_words_written),
      .completed_replays(completed_weight_replays),
      .replay_done(weight_replay_done),
      .context_error(bank_context_error),
      .idle()
  );

  alexnet_m4n8_accum_base_datapath #(
      .SLICE_INDEX(SLICE_INDEX),
      .FIFO_DEPTH(FIFO_DEPTH),
      .BANK_DEPTH(BANK_DEPTH),
      .DIM_W(DIM_W),
      .TILE_TAG_W(TILE_TAG_W),
      .CONTEXT_TAG_W(ACCUM_CONTEXT_TAG_W),
      .CHUNK_INDEX_W(CHUNK_INDEX_W),
      .N_BASE_W(N_BASE_W)
  ) u_accum_base_datapath (
      .clk(clk),
      .rst(rst),
      .ce(ce),
      .cfg_valid(base_cfg_valid),
      .cfg_ready(base_cfg_ready),
      .cfg_destination(cfg_destination),
      .cfg_n64_tile_base(cfg_n64_tile_base),
      .cfg_slice_index(3'(SLICE_INDEX)),
      .cfg_lane_mask(cfg_lane_mask),
      .cfg_bias(cfg_bias),
      .cfg_multiplier(cfg_multiplier),
      .cfg_right_shift(cfg_right_shift),
      .cfg_relu(cfg_relu),
      .chunk_valid(base_chunk_valid),
      .chunk_ready(base_chunk_ready),
      .chunk_word_count(chunk_word_count),
      .chunk_output_width(chunk_output_width),
      .chunk_n_lane_mask(configured_n_lane_mask_q),
      .chunk_context_tag(chunk_accum_context_tag),
      .chunk_tile_tag_base(chunk_tile_tag_base),
      .chunk_index(chunk_index),
      .chunk_first(chunk_first),
      .chunk_final(chunk_final),
      .tile_start_valid(base_tile_start_valid),
      .tile_start_ready(base_tile_start_ready),
      .tile_m_count(base_tile_m_count),
      .tile_n_lane_mask(base_tile_n_lane_mask),
      .tile_tag(base_tile_tag),
      .issue_valid(base_issue_valid),
      .issue_ready(base_issue_ready),
      .issue_last(base_issue_last),
      .issue_act_lo(base_issue_act_lo),
      .issue_act_hi(base_issue_act_hi),
      .issue_weight(base_issue_weight),
      .egress_valid(egress_valid),
      .egress_ready(egress_ready),
      .egress_values(egress_values),
      .egress_lane_mask(egress_lane_mask),
      .egress_destination(egress_destination),
      .egress_slice(egress_slice),
      .egress_m(egress_m),
      .egress_n_base(egress_n_base),
      .egress_tile_tag(egress_tile_tag),
      .configured(configured),
      .compute_busy(compute_busy),
      .transaction_active(transaction_active),
      .chunk_active(accum_chunk_active),
      .tile_done(base_tile_done),
      .chunk_done(base_chunk_done),
      .transaction_done(transaction_done),
      .datapath_idle(base_datapath_idle),
      .accum_bank_state(accum_bank_state),
      .accum_context_error(accum_context_error),
      .protocol_error(base_protocol_error),
      .queued_count(queued_count)
  );

`ifndef SYNTHESIS
  always_ff @(posedge clk) begin
    if (!rst) begin
      if (chunk_fire && chunk_k_count != derived_chunk_k_count)
        $fatal(1, "resident accum chunk K count does not match geometry");
      if (chunk_fire && chunk_input_lane_mask !=
          ((9'b1 << chunk_channel_count) - 1'b1))
        $fatal(1, "resident accum input lane mask/count mismatch");
      if (chunk_fire && chunk_word_count == 0)
        $fatal(1, "resident accum chunk has no output words");
      if (controller_weight_tile_valid && bank_weight_valid &&
          bank_weight_n_lane_mask != configured_n_lane_mask_q)
        $fatal(1, "resident accum replay N mask changed during chunk");
      if (controller_weight_tile_valid && bank_weight_valid &&
          bank_weight_context_tag != active_weight_context_tag_q)
        $fatal(1, "resident accum replay context changed during chunk");
      if (weight_release_ready && chunk_frame_active)
        $fatal(1, "resident accum weight became releasable mid-chunk");
      if (chunk_done && weight_bank_state != WEIGHT_STATE_READY)
        $fatal(1, "resident accum chunk retired before weight bank READY");
      if (chunk_fire && s_valid)
        $fatal(1, "resident accum descriptor requires standalone source cycle");
    end
  end
`endif

endmodule
