`timescale 1ns/1ps

// M16 wrapper for the N8 row-stationary feeder.  Sixteen replicated
// ring-buffer read copies fetch two independent M8 spatial groups in one
// cycle for the split 2xM8xN64 dynamic-array mode.
module alexnet_n8_rs_m16_feeder #(
    parameter int MAX_INPUT_WIDTH = 224,
    parameter int MAX_KERNEL = 11,
    parameter int MAX_PADDING = 2,
    parameter int DIM_W = 8,
    parameter int K_INDEX_W = 10,
    parameter int FRAME_TAG_W = 16
) (
    input logic clk,
    input logic rst,
    input logic frame_valid,
    output logic frame_ready,
    input logic [DIM_W-1:0] frame_input_h,
    input logic [DIM_W-1:0] frame_input_w,
    input logic [3:0] frame_channel_count,
    input logic [7:0] frame_lane_mask,
    input logic [3:0] frame_kernel,
    input logic [2:0] frame_stride,
    input logic [2:0] frame_padding,
    input logic [FRAME_TAG_W-1:0] frame_tag,
    input logic s_valid,
    output logic s_ready,
    input logic [63:0] s_values,
    input logic [7:0] s_lane_mask,
    output logic m_valid,
    input logic m_ready,
    output logic signed [7:0] m_act_lo [0:7],
    output logic signed [7:0] m_act_hi [0:7],
    output logic [1:0] m_lane_mask [0:7],
    output logic m_tile_clear,
    output logic m_reduce_last,
    output logic [K_INDEX_W-1:0] m_k,
    output logic [3:0] m_input_channel,
    output logic [4:0] m_count,
    output logic [DIM_W-1:0] m_output_y,
    output logic [DIM_W-1:0] m_output_x,
    output logic [FRAME_TAG_W-1:0] m_frame_tag,
    output logic frame_active,
    output logic frame_done,
    output logic idle
);

  alexnet_n8_rs_m4_feeder #(
      .PHYS_ROWS(8),
      .M_GROUP(16),
      .M_COUNT_W(5),
      .READ_COPIES(16),
      .MAX_INPUT_WIDTH(MAX_INPUT_WIDTH),
      .MAX_KERNEL(MAX_KERNEL),
      .MAX_PADDING(MAX_PADDING),
      .DIM_W(DIM_W),
      .K_INDEX_W(K_INDEX_W),
      .FRAME_TAG_W(FRAME_TAG_W)
  ) u_feeder (.*);

endmodule
