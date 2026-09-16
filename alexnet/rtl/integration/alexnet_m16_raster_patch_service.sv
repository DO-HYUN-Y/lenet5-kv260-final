`timescale 1ns/1ps

// AXI4-Stream raster-to-M16 patch service.
//
// A frame is supplied as two ordered N8 pixels per 128-bit AXIS beat.  The
// existing x-mod-4 raster feeder assembles convolution windows and its local
// ping-pong buffer exposes the same K-major M16 stream consumed by the graph
// payload engine.  Raster ingestion and patch replay may overlap.
module alexnet_m16_raster_patch_service #(
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

    input  logic [127:0] s_axis_tdata,
    input  logic [15:0] s_axis_tkeep,
    input  logic s_axis_tvalid,
    output logic s_axis_tready,
    input  logic s_axis_tlast,

    input  logic request_valid,
    output logic request_ready,
    input  logic [COUNT_W-1:0] request_k_count,
    input  logic [15:0] request_m_lane_mask,
    input  logic [FRAME_TAG_W-1:0] request_context_tag,

    output logic patch_axis_valid,
    input  logic patch_axis_ready,
    output logic [127:0] patch_axis_data,
    output logic patch_axis_last,

    output logic raster_active,
    output logic frame_active,
    output logic frame_done,
    output logic [15:0] completed_patch_fills,
    output logic [15:0] completed_patch_replays,
    output logic overlap_active,
    output logic fault,
    output logic idle
);

  logic bridge_frame_ready;
  logic bridge_s_ready;
  logic bridge_patch_valid;
  logic signed [7:0] bridge_patch_values [0:15];
  logic [ADDR_W-1:0] bridge_patch_k;
  logic bridge_patch_last;
  logic [15:0] bridge_patch_m_lane_mask;
  logic [FRAME_TAG_W-1:0] bridge_patch_context_tag;
  logic [1:0] bridge_ready_set_mask;
  logic bridge_fill_active, bridge_replay_active;
  logic bridge_fault, bridge_idle;

  logic unpacker_axis_ready;
  logic unpacker_valid, unpacker_ready;
  logic [63:0] unpacker_values;
  logic [7:0] unpacker_byte_keep;
  logic unpacker_last, unpacker_busy, unpacker_error;

  logic raster_active_q;
  logic [7:0] frame_lane_mask_q;
  logic [16:0] expected_pixels_q;
  logic [16:0] accepted_pixels_q;
  logic raster_protocol_error_q;
  logic frame_fire, pixel_fire;

  assign frame_ready = bridge_frame_ready && !raster_active_q;
  assign frame_fire = frame_valid && frame_ready;
  assign raster_active = raster_active_q;

  assign s_axis_tready = raster_active_q && unpacker_axis_ready;
  assign unpacker_ready = raster_active_q && bridge_s_ready;
  assign pixel_fire = unpacker_valid && unpacker_ready;

  // The bridge performs the exact descriptor match.  Its replay_ready is the
  // authoritative handshake.
  logic bridge_replay_ready;
  assign request_ready = bridge_replay_ready && !fault;

  assign patch_axis_valid = bridge_patch_valid;
  assign patch_axis_last = bridge_patch_last;
  always_comb begin
    patch_axis_data = 0;
    for (int lane = 0; lane < 16; lane++)
      patch_axis_data[lane*8 +: 8] = bridge_patch_values[lane];
  end

  assign fault = bridge_fault || unpacker_error || raster_protocol_error_q;
  assign idle = bridge_idle && !raster_active_q && !unpacker_busy;

  always_ff @(posedge clk) begin
    if (rst) begin
      raster_active_q <= 1'b0;
      frame_lane_mask_q <= 0;
      expected_pixels_q <= 0;
      accepted_pixels_q <= 0;
      raster_protocol_error_q <= 1'b0;
    end else begin
      if (frame_fire) begin
        raster_active_q <= 1'b1;
        frame_lane_mask_q <= frame_lane_mask;
        expected_pixels_q <= frame_input_h * frame_input_w;
        accepted_pixels_q <= 0;
        raster_protocol_error_q <= 1'b0;
      end

      if (pixel_fire) begin
        accepted_pixels_q <= accepted_pixels_q + 1'b1;
        if ((unpacker_byte_keep & frame_lane_mask_q) != frame_lane_mask_q)
          raster_protocol_error_q <= 1'b1;
        if (unpacker_last !=
            (accepted_pixels_q + 1'b1 == expected_pixels_q))
          raster_protocol_error_q <= 1'b1;
        if (unpacker_last)
          raster_active_q <= 1'b0;
      end
    end
  end

  alexnet_axis128_to_n8_unpacker u_unpacker (
      .clk, .rst, .clear_error(frame_fire),
      .s_axis_tdata,
      .s_axis_tkeep,
      .s_axis_tvalid(s_axis_tvalid && raster_active_q),
      .s_axis_tready(unpacker_axis_ready),
      .s_axis_tlast,
      .m_valid(unpacker_valid),
      .m_ready(unpacker_ready),
      .m_values(unpacker_values),
      .m_byte_keep(unpacker_byte_keep),
      .m_last(unpacker_last),
      .busy(unpacker_busy),
      .protocol_error(unpacker_error)
  );

  alexnet_m16_patch_feeder_bridge #(
      .MAX_INPUT_WIDTH(MAX_INPUT_WIDTH),
      .PATCH_DEPTH(PATCH_DEPTH),
      .DIM_W(DIM_W),
      .FRAME_TAG_W(FRAME_TAG_W),
      .USE_XMOD4_BANKING(USE_XMOD4_BANKING),
      .COUNT_W(COUNT_W),
      .ADDR_W(ADDR_W)
  ) u_bridge (
      .clk, .rst,
      .frame_valid(frame_valid && !raster_active_q),
      .frame_ready(bridge_frame_ready),
      .frame_input_h, .frame_input_w, .frame_channel_count,
      .frame_lane_mask, .frame_kernel, .frame_stride, .frame_padding,
      .frame_k_count, .frame_tag,
      .s_valid(unpacker_valid && raster_active_q),
      .s_ready(bridge_s_ready),
      .s_values(unpacker_values),
      .s_lane_mask(frame_lane_mask_q & unpacker_byte_keep),
      .replay_valid(request_valid && !fault),
      .replay_ready(bridge_replay_ready),
      .replay_k_count(request_k_count),
      .replay_m_lane_mask(request_m_lane_mask),
      .replay_context_tag(request_context_tag),
      .patch_valid(bridge_patch_valid),
      .patch_ready(patch_axis_ready),
      .patch_values(bridge_patch_values),
      .patch_k(bridge_patch_k),
      .patch_last(bridge_patch_last),
      .patch_m_lane_mask(bridge_patch_m_lane_mask),
      .patch_context_tag(bridge_patch_context_tag),
      .frame_active, .frame_done,
      .completed_patch_fills, .completed_patch_replays,
      .ready_set_mask(bridge_ready_set_mask),
      .fill_active(bridge_fill_active),
      .replay_active(bridge_replay_active),
      .overlap_active,
      .fault(bridge_fault),
      .idle(bridge_idle)
  );

`ifndef SYNTHESIS
  always_ff @(posedge clk) begin
    if (!rst) begin
      if (frame_fire && (frame_input_h == 0 || frame_input_w == 0 ||
                         frame_lane_mask == 0))
        $fatal(1, "raster patch service accepted an empty frame");
      if (pixel_fire && accepted_pixels_q >= expected_pixels_q)
        $fatal(1, "raster patch service accepted excess pixels");
    end
  end
`endif

endmodule
