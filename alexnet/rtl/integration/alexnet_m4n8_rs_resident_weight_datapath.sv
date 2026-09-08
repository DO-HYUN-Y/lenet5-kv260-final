`timescale 1ns/1ps

// One input-channel chunk from raster N8 activations through a resident N8
// weight tile and the complete M4xN8 datapath. The weight tile is filled once,
// then rewound automatically for every spatial M group in the frame.
module alexnet_m4n8_rs_resident_weight_datapath #(
    parameter int SLICE_INDEX = 0,
    parameter int FIFO_DEPTH = 64,
    parameter int MAX_INPUT_WIDTH = 224,
    parameter int WEIGHT_DEPTH = 968,
    parameter int DIM_W = 8,
    parameter int K_INDEX_W = 10,
    parameter int TILE_TAG_W = 16,
    parameter int WEIGHT_CONTEXT_TAG_W = 16,
    parameter int N_BASE_W = 16,
    parameter int WEIGHT_COUNT_W = $clog2(WEIGHT_DEPTH + 1)
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

    input  logic frame_valid,
    output logic frame_ready,
    input  logic [DIM_W-1:0] frame_input_h,
    input  logic [DIM_W-1:0] frame_input_w,
    input  logic [3:0] frame_channel_count,
    input  logic [7:0] frame_input_lane_mask,
    input  logic [3:0] frame_kernel,
    input  logic [2:0] frame_stride,
    input  logic [2:0] frame_padding,
    input  logic [WEIGHT_COUNT_W-1:0] frame_k_count,
    input  logic [WEIGHT_CONTEXT_TAG_W-1:0] frame_weight_context_tag,
    input  logic [TILE_TAG_W-1:0] frame_tag_base,

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
    output logic frame_active,
    output logic frame_done,
    output logic compute_busy,
    output logic pipeline_idle,
    output logic protocol_error,
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
    output logic [$clog2(FIFO_DEPTH+1)-1:0] queued_count
);

  localparam logic [1:0] WEIGHT_STATE_EMPTY = 2'd0;
  localparam logic [1:0] WEIGHT_STATE_WRITING = 2'd1;
  localparam logic [1:0] WEIGHT_STATE_READY = 2'd2;
  localparam logic [1:0] WEIGHT_STATE_REPLAYING = 2'd3;

  logic inner_cfg_ready;
  logic cfg_fire;
  logic [7:0] configured_n_lane_mask_q;

  logic bank_fill_valid;
  logic bank_fill_ready;
  logic bank_release_valid;
  logic bank_release_ready;
  logic bank_context_error;
  logic bank_replay_valid;
  logic bank_replay_ready;

  logic inner_frame_valid;
  logic inner_frame_ready;
  logic inner_frame_active;
  logic inner_frame_done;
  logic inner_pipeline_idle;
  logic frame_context_match;
  logic frame_fire;
  logic frame_retire_pending_q;
  logic [WEIGHT_COUNT_W-1:0] active_k_count_q;
  logic [WEIGHT_CONTEXT_TAG_W-1:0] active_weight_context_tag_q;

  logic inner_weight_tile_valid;
  logic inner_weight_tile_ready;
  logic [15:0] inner_weight_tile_index;
  logic [2:0] inner_weight_tile_m_count;
  logic [DIM_W-1:0] inner_weight_tile_output_y;
  logic [DIM_W-1:0] inner_weight_tile_output_x;
  logic [TILE_TAG_W-1:0] inner_weight_tile_tag;

  logic bank_weight_valid;
  logic bank_weight_ready;
  logic inner_weight_ready;
  logic signed [7:0] bank_weight_values [0:7];
  logic [K_INDEX_W-1:0] bank_weight_k;
  logic bank_weight_last;
  logic [7:0] bank_weight_n_lane_mask;
  logic [WEIGHT_CONTEXT_TAG_W-1:0] bank_weight_context_tag;

  logic safe_bank_owner_change;
  logic [11:0] derived_frame_k_count;

  assign cfg_ready = inner_cfg_ready;
  assign cfg_fire = cfg_valid && cfg_ready;

  assign safe_bank_owner_change = !frame_active && inner_pipeline_idle &&
                                  !frame_valid;
  assign bank_fill_valid = weight_fill_valid && safe_bank_owner_change;
  assign weight_fill_ready = bank_fill_ready && safe_bank_owner_change;
  assign bank_release_valid = weight_release_valid && safe_bank_owner_change;
  assign weight_release_ready = bank_release_ready && safe_bank_owner_change;

  assign frame_context_match =
      (weight_bank_state == WEIGHT_STATE_READY) && weight_resident_valid &&
      (resident_weight_k_count == frame_k_count) &&
      (resident_weight_n_lane_mask == configured_n_lane_mask_q) &&
      (resident_weight_context_tag == frame_weight_context_tag);
  assign inner_frame_valid = frame_valid && !frame_active &&
                             frame_context_match;
  assign frame_ready = inner_frame_ready && !frame_active &&
                       frame_context_match;
  assign frame_fire = frame_valid && frame_ready;

  assign inner_weight_tile_ready = bank_replay_ready;
  assign bank_replay_valid = inner_weight_tile_valid;
  assign bank_weight_ready = inner_weight_ready;

  assign pipeline_idle = !frame_active && inner_pipeline_idle &&
                         (weight_bank_state != WEIGHT_STATE_WRITING) &&
                         (weight_bank_state != WEIGHT_STATE_REPLAYING);

  always_comb begin
    case (frame_kernel)
      11: derived_frame_k_count = frame_channel_count * 12'd121;
      5: derived_frame_k_count = frame_channel_count * 12'd25;
      3: derived_frame_k_count = frame_channel_count * 12'd9;
      default: derived_frame_k_count = '0;
    endcase
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      configured_n_lane_mask_q <= '0;
      active_k_count_q <= '0;
      active_weight_context_tag_q <= '0;
      frame_active <= 1'b0;
      frame_done <= 1'b0;
      frame_retire_pending_q <= 1'b0;
      weight_context_error <= 1'b0;
    end else begin
      frame_done <= 1'b0;

      if (cfg_fire)
        configured_n_lane_mask_q <= cfg_lane_mask;

      if ((bank_fill_valid && bank_fill_ready) ||
          (bank_release_valid && bank_release_ready))
        weight_context_error <= 1'b0;
      else if (frame_valid && inner_frame_ready && !frame_active &&
               !frame_context_match)
        weight_context_error <= 1'b1;
      else if (bank_context_error)
        weight_context_error <= 1'b1;

      if (frame_fire) begin
        active_k_count_q <= frame_k_count;
        active_weight_context_tag_q <= frame_weight_context_tag;
        frame_active <= 1'b1;
        frame_retire_pending_q <= 1'b0;
      end

      if (inner_frame_done) begin
        if (weight_bank_state == WEIGHT_STATE_READY) begin
          frame_active <= 1'b0;
          frame_done <= 1'b1;
        end else begin
          frame_retire_pending_q <= 1'b1;
        end
      end else if (frame_retire_pending_q &&
                   weight_bank_state == WEIGHT_STATE_READY) begin
        frame_active <= 1'b0;
        frame_done <= 1'b1;
        frame_retire_pending_q <= 1'b0;
      end
    end
  end

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

  alexnet_m4n8_rs_datapath #(
      .SLICE_INDEX(SLICE_INDEX),
      .FIFO_DEPTH(FIFO_DEPTH),
      .MAX_INPUT_WIDTH(MAX_INPUT_WIDTH),
      .DIM_W(DIM_W),
      .K_INDEX_W(K_INDEX_W),
      .TILE_TAG_W(TILE_TAG_W),
      .N_BASE_W(N_BASE_W)
  ) u_rs_datapath (
      .clk(clk),
      .rst(rst),
      .ce(ce),
      .cfg_valid(cfg_valid),
      .cfg_ready(inner_cfg_ready),
      .cfg_destination(cfg_destination),
      .cfg_n64_tile_base(cfg_n64_tile_base),
      .cfg_lane_mask(cfg_lane_mask),
      .cfg_bias(cfg_bias),
      .cfg_multiplier(cfg_multiplier),
      .cfg_right_shift(cfg_right_shift),
      .cfg_relu(cfg_relu),
      .frame_valid(inner_frame_valid),
      .frame_ready(inner_frame_ready),
      .frame_input_h(frame_input_h),
      .frame_input_w(frame_input_w),
      .frame_channel_count(frame_channel_count),
      .frame_input_lane_mask(frame_input_lane_mask),
      .frame_kernel(frame_kernel),
      .frame_stride(frame_stride),
      .frame_padding(frame_padding),
      .frame_tag_base(frame_tag_base),
      .s_valid(s_valid),
      .s_ready(s_ready),
      .s_values(s_values),
      .s_lane_mask(s_lane_mask),
      .weight_tile_valid(inner_weight_tile_valid),
      .weight_tile_ready(inner_weight_tile_ready),
      .weight_tile_index(inner_weight_tile_index),
      .weight_tile_m_count(inner_weight_tile_m_count),
      .weight_tile_output_y(inner_weight_tile_output_y),
      .weight_tile_output_x(inner_weight_tile_output_x),
      .weight_tile_tag(inner_weight_tile_tag),
      .weight_valid(bank_weight_valid),
      .weight_ready(inner_weight_ready),
      .weight_values(bank_weight_values),
      .weight_k(bank_weight_k),
      .weight_last(bank_weight_last),
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
      .frame_active(inner_frame_active),
      .frame_done(inner_frame_done),
      .compute_busy(compute_busy),
      .pipeline_idle(inner_pipeline_idle),
      .protocol_error(protocol_error),
      .completed_tile_count(completed_tile_count),
      .queued_count(queued_count)
  );

`ifndef SYNTHESIS
  always_ff @(posedge clk) begin
    if (!rst) begin
      if (frame_fire && frame_k_count != derived_frame_k_count)
        $fatal(1, "resident-weight frame K count does not match feeder geometry");
      if (frame_fire && frame_input_lane_mask !=
          ((9'b1 << frame_channel_count) - 1'b1))
        $fatal(1, "resident-weight frame input lane mask/count mismatch");
      if (inner_weight_tile_valid &&
          (bank_weight_n_lane_mask != configured_n_lane_mask_q) &&
          bank_weight_valid)
        $fatal(1, "resident-weight replay N mask changed during a frame");
      if (inner_weight_tile_valid &&
          (bank_weight_context_tag != active_weight_context_tag_q) &&
          bank_weight_valid)
        $fatal(1, "resident-weight replay context changed during a frame");
      if (weight_release_ready && frame_active)
        $fatal(1, "resident weight became releasable during an active frame");
      if (frame_done && weight_bank_state != WEIGHT_STATE_READY)
        $fatal(1, "resident-weight frame completed before bank returned READY");
    end
  end
`endif

endmodule
