`timescale 1ns/1ps

// Raster N8 activations through K-major RS window generation, lockstep
// external N8 weights, unchanged M4xN8 SA/PEs, requantization, and routing.
// One frame descriptor is active at a time. New frame/configuration handshakes
// wait until the complete prior pipeline drains.
module alexnet_m4n8_rs_datapath #(
    parameter int SLICE_INDEX = 0,
    parameter int FIFO_DEPTH = 64,
    parameter int MAX_INPUT_WIDTH = 224,
    parameter int DIM_W = 8,
    parameter int K_INDEX_W = 10,
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

    input  logic frame_valid,
    output logic frame_ready,
    input  logic [DIM_W-1:0] frame_input_h,
    input  logic [DIM_W-1:0] frame_input_w,
    input  logic [3:0] frame_channel_count,
    input  logic [7:0] frame_input_lane_mask,
    input  logic [3:0] frame_kernel,
    input  logic [2:0] frame_stride,
    input  logic [2:0] frame_padding,
    input  logic [TILE_TAG_W-1:0] frame_tag_base,

    input  logic s_valid,
    output logic s_ready,
    input  logic [63:0] s_values,
    input  logic [7:0] s_lane_mask,

    output logic weight_tile_valid,
    input  logic weight_tile_ready,
    output logic [15:0] weight_tile_index,
    output logic [2:0] weight_tile_m_count,
    output logic [DIM_W-1:0] weight_tile_output_y,
    output logic [DIM_W-1:0] weight_tile_output_x,
    output logic [TILE_TAG_W-1:0] weight_tile_tag,

    input  logic weight_valid,
    output logic weight_ready,
    input  logic signed [7:0] weight_values [0:7],
    input  logic [K_INDEX_W-1:0] weight_k,
    input  logic weight_last,

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
    output logic [15:0] completed_tile_count,
    output logic [$clog2(FIFO_DEPTH+1)-1:0] queued_count
);

  logic cfg_fire;
  logic base_cfg_valid;
  logic base_cfg_ready;
  logic frame_fire;
  logic feeder_frame_valid;
  logic feeder_frame_ready;
  logic feeder_frame_active;
  logic feeder_frame_done;
  logic feeder_idle;
  logic feeder_done_seen_q;
  logic [7:0] n_lane_mask_q;

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

  assign pipeline_idle = !frame_active && feeder_idle && controller_idle &&
                         base_datapath_idle;
  assign cfg_ready = !frame_active && feeder_idle && controller_idle &&
                     base_cfg_ready;
  assign cfg_fire = cfg_valid && cfg_ready;
  assign base_cfg_valid = cfg_fire;

  assign frame_ready = configured && !cfg_valid && !frame_active &&
                       feeder_frame_ready && controller_idle &&
                       base_datapath_idle;
  assign frame_fire = frame_valid && frame_ready;
  assign feeder_frame_valid = frame_fire;

  always_ff @(posedge clk) begin
    if (rst) begin
      n_lane_mask_q <= '0;
      frame_active <= 1'b0;
      frame_done <= 1'b0;
      feeder_done_seen_q <= 1'b0;
    end else begin
      frame_done <= 1'b0;

      if (cfg_fire)
        n_lane_mask_q <= cfg_lane_mask;

      if (frame_fire) begin
        frame_active <= 1'b1;
        feeder_done_seen_q <= 1'b0;
      end

      if (feeder_frame_done)
        feeder_done_seen_q <= 1'b1;

      if (frame_active && (feeder_done_seen_q || feeder_frame_done) &&
          controller_idle && !compute_busy) begin
        frame_active <= 1'b0;
        frame_done <= 1'b1;
        feeder_done_seen_q <= 1'b0;
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
      .frame_input_h(frame_input_h),
      .frame_input_w(frame_input_w),
      .frame_channel_count(frame_channel_count),
      .frame_lane_mask(frame_input_lane_mask),
      .frame_kernel(frame_kernel),
      .frame_stride(frame_stride),
      .frame_padding(frame_padding),
      .frame_tag(frame_tag_base),
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
      .frame_start(frame_fire),
      .tile_n_lane_mask(n_lane_mask_q),
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
      .weight_tile_valid(weight_tile_valid),
      .weight_tile_ready(weight_tile_ready),
      .weight_tile_index(weight_tile_index),
      .weight_tile_m_count(weight_tile_m_count),
      .weight_tile_output_y(weight_tile_output_y),
      .weight_tile_output_x(weight_tile_output_x),
      .weight_tile_tag(weight_tile_tag),
      .weight_valid(weight_valid),
      .weight_ready(weight_ready),
      .weight_values(weight_values),
      .weight_k(weight_k),
      .weight_last(weight_last),
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
      .protocol_error(protocol_error)
  );

  alexnet_m4n8_base_datapath #(
      .SLICE_INDEX(SLICE_INDEX),
      .FIFO_DEPTH(FIFO_DEPTH),
      .TILE_TAG_W(TILE_TAG_W),
      .N_BASE_W(N_BASE_W)
  ) u_base_datapath (
      .clk(clk),
      .rst(rst),
      .ce(ce),
      .cfg_valid(base_cfg_valid),
      .cfg_ready(base_cfg_ready),
      .cfg_destination(cfg_destination),
      .cfg_n64_tile_base(cfg_n64_tile_base),
      .cfg_lane_mask(cfg_lane_mask),
      .cfg_bias(cfg_bias),
      .cfg_multiplier(cfg_multiplier),
      .cfg_right_shift(cfg_right_shift),
      .cfg_relu(cfg_relu),
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
      .tile_done(base_tile_done),
      .datapath_idle(base_datapath_idle),
      .queued_count(queued_count)
  );

`ifndef SYNTHESIS
  always_ff @(posedge clk) begin
    if (!rst) begin
      if (frame_fire && s_valid)
        $fatal(1, "RS datapath frame descriptor requires a standalone source cycle");
      if (cfg_valid && frame_active && cfg_ready)
        $fatal(1, "RS datapath reconfigured an active frame");
      if (frame_done && protocol_error)
        $fatal(1, "RS datapath completed with a weight protocol error");
    end
  end
`endif

endmodule
