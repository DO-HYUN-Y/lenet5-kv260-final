`timescale 1ns/1ps

// One N8 row-stationary convolution window-feeder slice.
//
// Input pixels arrive in raster order with up to eight input channels packed
// into each 64-bit beat. The feeder walks a virtual padded raster, retains
// only K rows, and emits row-local M4 spatial groups in the frozen K order:
//
//   k = ((kernel_y * kernel) + kernel_x) * channel_count + input_channel
//
// Kernel/stride/padding are descriptor controlled for the AlexNet modes
// K11/s4/p2, K5/s1/p2, and K3/s1/p1. The last group of each output row may be
// an M tail; invalid M lanes are zero. Scanning pauses while a group is read
// from the ring memory, so source and output stalls cannot overwrite a live
// window.
module alexnet_n8_rs_m4_feeder #(
    parameter int MAX_INPUT_WIDTH = 224,
    parameter int MAX_KERNEL = 11,
    parameter int MAX_PADDING = 2,
    parameter int DIM_W = 8,
    parameter int K_INDEX_W = 10,
    parameter int FRAME_TAG_W = 16
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
    input  logic [FRAME_TAG_W-1:0] frame_tag,

    input  logic s_valid,
    output logic s_ready,
    input  logic [63:0] s_values,
    input  logic [7:0] s_lane_mask,

    output logic m_valid,
    input  logic m_ready,
    output logic signed [7:0] m_act_lo [0:1],
    output logic signed [7:0] m_act_hi [0:1],
    output logic [1:0] m_lane_mask [0:1],
    output logic m_tile_clear,
    output logic m_reduce_last,
    output logic [K_INDEX_W-1:0] m_k,
    output logic [3:0] m_input_channel,
    output logic [2:0] m_count,
    output logic [DIM_W-1:0] m_output_y,
    output logic [DIM_W-1:0] m_output_x,
    output logic [FRAME_TAG_W-1:0] m_frame_tag,

    output logic frame_active,
    output logic frame_done,
    output logic idle
);

  localparam int MAX_PADDED_WIDTH = MAX_INPUT_WIDTH + 2 * MAX_PADDING;
  localparam int RING_LOGICAL_DEPTH = MAX_KERNEL * MAX_PADDED_WIDTH;
  localparam int RING_BANK_WORDS = 512;
  localparam int RING_BANKS =
      (RING_LOGICAL_DEPTH + RING_BANK_WORDS - 1) / RING_BANK_WORDS;
  localparam int RING_ADDR_W = $clog2(RING_LOGICAL_DEPTH);
  localparam int RING_BANK_W = $clog2(RING_BANKS);
  localparam int RING_ROW_W = $clog2(MAX_KERNEL);

  typedef enum logic [2:0] {
    ST_IDLE,
    ST_SCAN,
    ST_READ_ISSUE,
    ST_READ_CAPTURE,
    ST_EMIT
  } state_t;

  state_t state_q;
  logic [DIM_W-1:0] input_h_q;
  logic [DIM_W-1:0] input_w_q;
  logic [DIM_W-1:0] padded_h_q;
  logic [DIM_W-1:0] padded_w_q;
  logic [DIM_W-1:0] output_h_q;
  logic [DIM_W-1:0] output_w_q;
  logic [3:0] channel_count_q;
  logic [7:0] lane_mask_q;
  logic [DIM_W-1:0] kernel_q;
  logic [DIM_W-1:0] stride_q;
  logic [DIM_W-1:0] padding_q;
  logic [FRAME_TAG_W-1:0] frame_tag_q;

  logic [DIM_W-1:0] scan_y_q;
  logic [DIM_W-1:0] scan_x_q;
  logic [RING_ROW_W-1:0] write_ring_row_q;
  logic scan_complete_q;

  logic [DIM_W-1:0] group_y_q;
  logic [DIM_W-1:0] group_x_q;
  logic [2:0] group_count_q;
  logic group_pending_q;
  logic [RING_ROW_W-1:0] endpoint_ring_row_q;

  logic [DIM_W-1:0] emit_ky_q;
  logic [DIM_W-1:0] emit_kx_q;
  logic [3:0] emit_ic_q;
  logic [K_INDEX_W-1:0] emit_k_q;
  logic [2:0] read_m_q;
  logic [63:0] pixel_q [0:3];
  logic [63:0] ring_bank_read_q [0:RING_BANKS-1];
  logic [RING_BANK_W-1:0] read_bank_select_q;

  logic scan_inside;
  logic scan_step;
  logic s_fire;
  logic frame_fire;
  logic last_scan_position;
  logic at_group_endpoint;
  logic [2:0] next_group_count;
  logic [DIM_W-1:0] endpoint_y;
  logic [DIM_W-1:0] endpoint_x;
  logic [RING_ADDR_W-1:0] write_addr;
  logic [RING_ADDR_W-1:0] read_addr;
  logic [RING_BANK_W-1:0] write_bank;
  logic [RING_BANK_W-1:0] read_bank;
  logic [8:0] write_bank_addr;
  logic [8:0] read_bank_addr;
  logic [RING_ROW_W:0] read_ring_row_sum;
  logic [RING_ROW_W-1:0] read_ring_row;
  logic [DIM_W-1:0] read_x;
  logic [63:0] scan_values_masked;
  logic [3:0] expected_lane_count;
  logic [7:0] expected_lane_mask;

  assign idle = state_q == ST_IDLE;
  assign frame_ready = idle;
  assign frame_fire = frame_valid && frame_ready;
  assign frame_active = state_q != ST_IDLE;

  assign scan_inside = (scan_y_q >= padding_q) &&
                       (scan_y_q < padding_q + input_h_q) &&
                       (scan_x_q >= padding_q) &&
                       (scan_x_q < padding_q + input_w_q);
  assign s_ready = (state_q == ST_SCAN) && !scan_complete_q && scan_inside;
  assign s_fire = s_valid && s_ready;
  assign scan_step = (state_q == ST_SCAN) && !scan_complete_q &&
                     (!scan_inside || s_fire);
  assign last_scan_position = (scan_y_q == padded_h_q - 1'b1) &&
                              (scan_x_q == padded_w_q - 1'b1);

  always_comb begin
    if (output_w_q - group_x_q >= 4)
      next_group_count = 3'd4;
    else
      next_group_count = output_w_q - group_x_q;

    if (stride_q == 4) begin
      endpoint_y = (group_y_q << 2) + kernel_q - 1'b1;
      endpoint_x = ((group_x_q + next_group_count - 1'b1) << 2) +
                   kernel_q - 1'b1;
    end else begin
      endpoint_y = group_y_q + kernel_q - 1'b1;
      endpoint_x = group_x_q + next_group_count + kernel_q - 2;
    end
  end

  assign at_group_endpoint = group_pending_q &&
                             (scan_y_q == endpoint_y) &&
                             (scan_x_q == endpoint_x);

  always_comb begin
    scan_values_masked = '0;
    if (scan_inside) begin
      for (int lane = 0; lane < 8; lane++) begin
        if (lane_mask_q[lane] && s_lane_mask[lane])
          scan_values_masked[lane*8 +: 8] = s_values[lane*8 +: 8];
      end
    end
  end

  assign write_addr = write_ring_row_q * MAX_PADDED_WIDTH + scan_x_q;

  always_comb begin
    read_ring_row_sum = endpoint_ring_row_q + 1'b1 + emit_ky_q;
    if (read_ring_row_sum >= kernel_q)
      read_ring_row = read_ring_row_sum - kernel_q;
    else
      read_ring_row = read_ring_row_sum[RING_ROW_W-1:0];

    if (stride_q == 4)
      read_x = (group_x_q << 2) + (read_m_q << 2) + emit_kx_q;
    else
      read_x = group_x_q + read_m_q + emit_kx_q;
  end

  assign read_addr = read_ring_row * MAX_PADDED_WIDTH + read_x;
  assign write_bank = write_addr[RING_ADDR_W-1:9];
  assign read_bank = read_addr[RING_ADDR_W-1:9];
  assign write_bank_addr = write_addr[8:0];
  assign read_bank_addr = read_addr[8:0];

  // Explicit 512x64 banking prevents the 2508-word logical depth from being
  // expanded into Vivado's larger irregular cascade. Each generated bank maps
  // independently to one RAMB36E2.
  generate
    for (genvar bank = 0; bank < RING_BANKS; bank++) begin : g_ring_bank
      (* ram_style = "block" *) logic [63:0] mem [0:RING_BANK_WORDS-1];

      always_ff @(posedge clk) begin
        if (scan_step && write_bank == bank)
          mem[write_bank_addr] <= scan_values_masked;
        if (state_q == ST_READ_ISSUE)
          ring_bank_read_q[bank] <= mem[read_bank_addr];
      end
    end
  endgenerate

  always_comb begin
    m_valid = state_q == ST_EMIT;
    m_act_lo[0] = $signed(pixel_q[0][emit_ic_q*8 +: 8]);
    m_act_hi[0] = $signed(pixel_q[1][emit_ic_q*8 +: 8]);
    m_act_lo[1] = $signed(pixel_q[2][emit_ic_q*8 +: 8]);
    m_act_hi[1] = $signed(pixel_q[3][emit_ic_q*8 +: 8]);
    m_lane_mask[0] = {group_count_q > 1, group_count_q > 0};
    m_lane_mask[1] = {group_count_q > 3, group_count_q > 2};
    m_tile_clear = emit_k_q == 0;
    m_reduce_last = (emit_ky_q == kernel_q - 1'b1) &&
                    (emit_kx_q == kernel_q - 1'b1) &&
                    (emit_ic_q == channel_count_q - 1'b1);
    m_k = emit_k_q;
    m_input_channel = emit_ic_q;
    m_count = group_count_q;
    m_output_y = group_y_q;
    m_output_x = group_x_q;
    m_frame_tag = frame_tag_q;
  end

  always_comb begin
    expected_lane_count = frame_channel_count;
    if (expected_lane_count == 8)
      expected_lane_mask = 8'hff;
    else
      expected_lane_mask = (9'b1 << expected_lane_count) - 1'b1;
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      state_q <= ST_IDLE;
      input_h_q <= '0;
      input_w_q <= '0;
      padded_h_q <= '0;
      padded_w_q <= '0;
      output_h_q <= '0;
      output_w_q <= '0;
      channel_count_q <= '0;
      lane_mask_q <= '0;
      kernel_q <= '0;
      stride_q <= '0;
      padding_q <= '0;
      frame_tag_q <= '0;
      scan_y_q <= '0;
      scan_x_q <= '0;
      write_ring_row_q <= '0;
      scan_complete_q <= 1'b0;
      group_y_q <= '0;
      group_x_q <= '0;
      group_count_q <= '0;
      group_pending_q <= 1'b0;
      endpoint_ring_row_q <= '0;
      emit_ky_q <= '0;
      emit_kx_q <= '0;
      emit_ic_q <= '0;
      emit_k_q <= '0;
      read_m_q <= '0;
      read_bank_select_q <= '0;
      for (int m = 0; m < 4; m++)
        pixel_q[m] <= '0;
      frame_done <= 1'b0;
    end else begin
      frame_done <= 1'b0;

      if (frame_fire) begin
        state_q <= ST_SCAN;
        input_h_q <= frame_input_h;
        input_w_q <= frame_input_w;
        padded_h_q <= frame_input_h + (frame_padding << 1);
        padded_w_q <= frame_input_w + (frame_padding << 1);
        if (frame_stride == 4) begin
          output_h_q <= ((frame_input_h + (frame_padding << 1) -
                          frame_kernel) >> 2) + 1'b1;
          output_w_q <= ((frame_input_w + (frame_padding << 1) -
                          frame_kernel) >> 2) + 1'b1;
        end else begin
          output_h_q <= frame_input_h + (frame_padding << 1) -
                        frame_kernel + 1'b1;
          output_w_q <= frame_input_w + (frame_padding << 1) -
                        frame_kernel + 1'b1;
        end
        channel_count_q <= frame_channel_count;
        lane_mask_q <= frame_lane_mask;
        kernel_q <= frame_kernel;
        stride_q <= frame_stride;
        padding_q <= frame_padding;
        frame_tag_q <= frame_tag;
        scan_y_q <= '0;
        scan_x_q <= '0;
        write_ring_row_q <= '0;
        scan_complete_q <= 1'b0;
        group_y_q <= '0;
        group_x_q <= '0;
        group_count_q <= '0;
        group_pending_q <= 1'b1;
        endpoint_ring_row_q <= '0;
        emit_ky_q <= '0;
        emit_kx_q <= '0;
        emit_ic_q <= '0;
        emit_k_q <= '0;
        read_m_q <= '0;
        for (int m = 0; m < 4; m++)
          pixel_q[m] <= '0;
      end

      if (scan_step) begin
        if (at_group_endpoint) begin
          endpoint_ring_row_q <= write_ring_row_q;
          group_count_q <= next_group_count;
          emit_ky_q <= '0;
          emit_kx_q <= '0;
          emit_ic_q <= '0;
          emit_k_q <= '0;
          read_m_q <= '0;
          for (int m = 0; m < 4; m++)
            pixel_q[m] <= '0;
          state_q <= ST_READ_ISSUE;
        end

        if (last_scan_position) begin
          scan_complete_q <= 1'b1;
          if (!group_pending_q) begin
            state_q <= ST_IDLE;
            frame_done <= 1'b1;
          end
        end else if (scan_x_q == padded_w_q - 1'b1) begin
          scan_x_q <= '0;
          scan_y_q <= scan_y_q + 1'b1;
          if (write_ring_row_q == kernel_q - 1'b1)
            write_ring_row_q <= '0;
          else
            write_ring_row_q <= write_ring_row_q + 1'b1;
        end else begin
          scan_x_q <= scan_x_q + 1'b1;
        end
      end

      if (state_q == ST_READ_ISSUE) begin
        read_bank_select_q <= read_bank;
        state_q <= ST_READ_CAPTURE;
      end

      if (state_q == ST_READ_CAPTURE) begin
        pixel_q[read_m_q] <= ring_bank_read_q[read_bank_select_q];
        if (read_m_q == group_count_q - 1'b1) begin
          read_m_q <= '0;
          state_q <= ST_EMIT;
        end else begin
          read_m_q <= read_m_q + 1'b1;
          state_q <= ST_READ_ISSUE;
        end
      end

      if (state_q == ST_EMIT && m_ready) begin
        if (m_reduce_last) begin
          if (group_x_q + 4 >= output_w_q) begin
            group_x_q <= '0;
            if (group_y_q == output_h_q - 1'b1) begin
              group_pending_q <= 1'b0;
              if (scan_complete_q) begin
                state_q <= ST_IDLE;
                frame_done <= 1'b1;
              end else begin
                state_q <= ST_SCAN;
              end
            end else begin
              group_y_q <= group_y_q + 1'b1;
              state_q <= ST_SCAN;
            end
          end else begin
            group_x_q <= group_x_q + 4;
            state_q <= ST_SCAN;
          end
          emit_ky_q <= '0;
          emit_kx_q <= '0;
          emit_ic_q <= '0;
          emit_k_q <= '0;
        end else if (emit_ic_q == channel_count_q - 1'b1) begin
          emit_ic_q <= '0;
          emit_k_q <= emit_k_q + 1'b1;
          if (emit_kx_q == kernel_q - 1'b1) begin
            emit_kx_q <= '0;
            emit_ky_q <= emit_ky_q + 1'b1;
          end else begin
            emit_kx_q <= emit_kx_q + 1'b1;
          end
          read_m_q <= '0;
          for (int m = 0; m < 4; m++)
            pixel_q[m] <= '0;
          state_q <= ST_READ_ISSUE;
        end else begin
          emit_ic_q <= emit_ic_q + 1'b1;
          emit_k_q <= emit_k_q + 1'b1;
        end
      end
    end
  end

`ifndef SYNTHESIS
  always_ff @(posedge clk) begin
    if (!rst) begin
      if (frame_fire &&
          (frame_input_h == 0 || frame_input_w == 0 ||
           frame_input_w > MAX_INPUT_WIDTH ||
           frame_channel_count == 0 || frame_channel_count > 8 ||
           frame_lane_mask != expected_lane_mask ||
           !((frame_kernel == 11 && frame_stride == 4 && frame_padding == 2) ||
             (frame_kernel == 5 && frame_stride == 1 && frame_padding == 2) ||
             (frame_kernel == 3 && frame_stride == 1 && frame_padding == 1))))
        $fatal(1, "RS feeder descriptor is outside the AlexNet modes");
      if (frame_fire && s_valid)
        $fatal(1, "RS feeder descriptor requires a standalone source cycle");
      if (s_valid && state_q == ST_IDLE)
        $fatal(1, "RS feeder input arrived without an active frame");
      if (s_fire && s_lane_mask != lane_mask_q)
        $fatal(1, "RS feeder input lane mask changed inside a frame");
      if (s_valid && scan_complete_q)
        $fatal(1, "RS feeder received data after the final frame pixel");
      if (m_valid && m_count == 0)
        $fatal(1, "RS feeder emitted an empty M group");
    end
  end
`endif

endmodule
