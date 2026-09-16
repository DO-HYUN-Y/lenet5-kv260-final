`timescale 1ns/1ps

// Functional bridge from the verified N8 raster feeder to the transposed M16
// activation-patch ping-pong.  It is the first payload boundary used when the
// M8xN126 graph scheduler replaces the resource-probe generator.
//
// USE_XMOD4_BANKING selects the stride-aware 64-BRAM store. The legacy
// replicated 112-BRAM feeder remains available as a bit-exact comparison.
module alexnet_m16_patch_feeder_bridge #(
    parameter int MAX_INPUT_WIDTH = 224,
    parameter int PATCH_DEPTH = 4096,
    parameter int DIM_W = 8,
    parameter int FRAME_TAG_W = 16,
    parameter bit USE_XMOD4_BANKING = 1'b1,
    parameter int COUNT_W = $clog2(PATCH_DEPTH + 1),
    parameter int ADDR_W = $clog2(PATCH_DEPTH)
) (
    input logic clk,
    input logic rst,

    input  logic frame_valid,
    output logic frame_ready,
    input  logic [DIM_W-1:0] frame_input_h,
    input  logic [DIM_W-1:0] frame_input_w,
    input  logic [3:0] frame_channel_count,
    input  logic [7:0] frame_lane_mask,
    input  logic [3:0] frame_kernel,
    input  logic [2:0] frame_stride,
    input  logic [2:0] frame_padding,
    input  logic [COUNT_W-1:0] frame_k_count,
    input  logic [FRAME_TAG_W-1:0] frame_tag,

    input  logic s_valid,
    output logic s_ready,
    input  logic [63:0] s_values,
    input  logic [7:0] s_lane_mask,

    input  logic replay_valid,
    output logic replay_ready,
    input  logic [COUNT_W-1:0] replay_k_count,
    input  logic [15:0] replay_m_lane_mask,
    input  logic [FRAME_TAG_W-1:0] replay_context_tag,

    output logic patch_valid,
    input  logic patch_ready,
    output logic signed [7:0] patch_values [0:15],
    output logic [ADDR_W-1:0] patch_k,
    output logic patch_last,
    output logic [15:0] patch_m_lane_mask,
    output logic [FRAME_TAG_W-1:0] patch_context_tag,

    output logic frame_active,
    output logic frame_done,
    output logic [15:0] completed_patch_fills,
    output logic [15:0] completed_patch_replays,
    output logic [1:0] ready_set_mask,
    output logic fill_active,
    output logic replay_active,
    output logic overlap_active,
    output logic fault,
    output logic idle
);

  logic feeder_m_valid, feeder_m_ready;
  logic signed [7:0] feeder_act_lo [0:7];
  logic signed [7:0] feeder_act_hi [0:7];
  logic [1:0] feeder_lane_mask [0:7];
  logic feeder_tile_clear, feeder_reduce_last;
  logic [9:0] feeder_k;
  logic [3:0] feeder_input_channel;
  logic [4:0] feeder_m_count;
  logic [DIM_W-1:0] feeder_output_y, feeder_output_x;
  logic [FRAME_TAG_W-1:0] feeder_frame_tag;
  logic feeder_idle;

  logic patch_fill_valid, patch_fill_ready;
  logic patch_write_valid, patch_write_ready;
  logic [127:0] patch_write_values;
  logic patch_write_last;
  logic [ADDR_W-1:0] patch_write_k;
  logic [1:0] patch_set_state [0:1];
  logic patch_fill_set, patch_replay_set;
  logic [COUNT_W-1:0] patch_words_written;
  logic patch_fill_done, patch_replay_done;
  logic patch_context_error, patch_protocol_error, patch_idle;

  logic [COUNT_W-1:0] frame_k_count_q;
  logic [FRAME_TAG_W-1:0] frame_tag_q;
  logic [15:0] group_index_q;
  logic fill_descriptor_accepted_q;
  logic [15:0] current_m_lane_mask;
  logic frame_fire, fill_fire, write_fire;

  assign frame_fire = frame_valid && frame_ready;
  assign fill_fire = patch_fill_valid && patch_fill_ready;
  assign write_fire = patch_write_valid && patch_write_ready;
  assign patch_fill_valid = feeder_m_valid && feeder_k == 0 &&
                            !fill_descriptor_accepted_q;
  assign patch_write_valid = feeder_m_valid &&
                             fill_descriptor_accepted_q;
  assign patch_write_last = feeder_reduce_last;
  assign feeder_m_ready = fill_descriptor_accepted_q && patch_write_ready;
  assign overlap_active = fill_active && replay_active;
  assign fault = patch_context_error || patch_protocol_error;
  assign idle = feeder_idle && patch_idle && !fill_descriptor_accepted_q;

  always_comb begin
    patch_write_values = 0;
    current_m_lane_mask = 0;
    for (int row = 0; row < 8; row++) begin
      patch_write_values[(2*row)*8 +: 8] = feeder_act_lo[row];
      patch_write_values[(2*row+1)*8 +: 8] = feeder_act_hi[row];
      current_m_lane_mask[2*row +: 2] = feeder_lane_mask[row];
    end
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      frame_k_count_q <= 0;
      frame_tag_q <= 0;
      group_index_q <= 0;
      fill_descriptor_accepted_q <= 1'b0;
    end else begin
      if (frame_fire) begin
        frame_k_count_q <= frame_k_count;
        frame_tag_q <= frame_tag;
        group_index_q <= 0;
        fill_descriptor_accepted_q <= 1'b0;
      end
      if (fill_fire)
        fill_descriptor_accepted_q <= 1'b1;
      if (write_fire && feeder_reduce_last) begin
        fill_descriptor_accepted_q <= 1'b0;
        group_index_q <= group_index_q + 1'b1;
      end
    end
  end

  generate
    if (USE_XMOD4_BANKING) begin : g_xmod4_feeder
      alexnet_n8_rs_m16_xmod4_feeder #(
          .MAX_INPUT_WIDTH(MAX_INPUT_WIDTH),
          .FRAME_TAG_W(FRAME_TAG_W)
      ) u_feeder (
          .clk, .rst, .frame_valid, .frame_ready, .frame_input_h,
          .frame_input_w, .frame_channel_count, .frame_lane_mask,
          .frame_kernel, .frame_stride, .frame_padding, .frame_tag,
          .s_valid, .s_ready, .s_values, .s_lane_mask,
          .m_valid(feeder_m_valid), .m_ready(feeder_m_ready),
          .m_act_lo(feeder_act_lo), .m_act_hi(feeder_act_hi),
          .m_lane_mask(feeder_lane_mask),
          .m_tile_clear(feeder_tile_clear),
          .m_reduce_last(feeder_reduce_last), .m_k(feeder_k),
          .m_input_channel(feeder_input_channel), .m_count(feeder_m_count),
          .m_output_y(feeder_output_y), .m_output_x(feeder_output_x),
          .m_frame_tag(feeder_frame_tag), .frame_active, .frame_done,
          .idle(feeder_idle)
      );
    end else begin : g_legacy_feeder
      alexnet_n8_rs_m16_feeder #(
          .MAX_INPUT_WIDTH(MAX_INPUT_WIDTH),
          .FRAME_TAG_W(FRAME_TAG_W)
      ) u_feeder (
          .clk, .rst, .frame_valid, .frame_ready, .frame_input_h,
          .frame_input_w, .frame_channel_count, .frame_lane_mask,
          .frame_kernel, .frame_stride, .frame_padding, .frame_tag,
          .s_valid, .s_ready, .s_values, .s_lane_mask,
          .m_valid(feeder_m_valid), .m_ready(feeder_m_ready),
          .m_act_lo(feeder_act_lo), .m_act_hi(feeder_act_hi),
          .m_lane_mask(feeder_lane_mask),
          .m_tile_clear(feeder_tile_clear),
          .m_reduce_last(feeder_reduce_last), .m_k(feeder_k),
          .m_input_channel(feeder_input_channel), .m_count(feeder_m_count),
          .m_output_y(feeder_output_y), .m_output_x(feeder_output_x),
          .m_frame_tag(feeder_frame_tag), .frame_active, .frame_done,
          .idle(feeder_idle)
      );
    end
  endgenerate

  alexnet_m16_patch_pingpong #(
      .DEPTH(PATCH_DEPTH),
      .CONTEXT_TAG_W(FRAME_TAG_W),
      .ADDR_W(ADDR_W),
      .COUNT_W(COUNT_W)
  ) u_patch_pingpong (
      .clk,
      .rst,
      .fill_valid(patch_fill_valid),
      .fill_ready(patch_fill_ready),
      .fill_k_count(frame_k_count_q),
      .fill_m_lane_mask(current_m_lane_mask),
      .fill_context_tag(frame_tag_q + group_index_q),
      .write_valid(patch_write_valid),
      .write_ready(patch_write_ready),
      .write_values(patch_write_values),
      .write_last(patch_write_last),
      .write_k(patch_write_k),
      .replay_valid,
      .replay_ready,
      .replay_k_count,
      .replay_m_lane_mask,
      .replay_context_tag,
      .patch_valid,
      .patch_ready,
      .patch_values,
      .patch_k,
      .patch_last,
      .patch_m_lane_mask,
      .patch_context_tag,
      .set_state(patch_set_state),
      .ready_set_mask,
      .fill_active,
      .active_fill_set(patch_fill_set),
      .replay_active,
      .active_replay_set(patch_replay_set),
      .words_written(patch_words_written),
      .completed_fills(completed_patch_fills),
      .completed_replays(completed_patch_replays),
      .fill_done(patch_fill_done),
      .replay_done(patch_replay_done),
      .context_error(patch_context_error),
      .protocol_error(patch_protocol_error),
      .idle(patch_idle)
  );

`ifndef SYNTHESIS
  always_ff @(posedge clk) begin
    if (!rst) begin
      if (frame_fire && frame_k_count !=
          frame_kernel * frame_kernel * frame_channel_count)
        $fatal(1, "patch bridge K count does not match frame geometry");
      if (fill_fire && (!feeder_tile_clear || feeder_m_count == 0))
        $fatal(1, "patch bridge fill did not start on a feeder boundary");
      if (write_fire && patch_write_k != feeder_k)
        $fatal(1, "patch bridge feeder/store K mismatch");
      if (write_fire && patch_write_last !=
          (patch_write_k + 1'b1 == frame_k_count_q))
        $fatal(1, "patch bridge final K mismatch");
    end
  end
`endif

endmodule
