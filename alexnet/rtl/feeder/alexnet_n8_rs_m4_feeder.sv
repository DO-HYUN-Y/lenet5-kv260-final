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
    parameter int PHYS_ROWS = 2,
    parameter int M_GROUP = 2 * PHYS_ROWS,
    parameter int M_COUNT_W = $clog2(M_GROUP + 1),
    parameter int READ_COPIES = PHYS_ROWS == 4 ? M_GROUP : 1,
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
    output logic signed [7:0] m_act_lo [0:PHYS_ROWS-1],
    output logic signed [7:0] m_act_hi [0:PHYS_ROWS-1],
    output logic [1:0] m_lane_mask [0:PHYS_ROWS-1],
    output logic m_tile_clear,
    output logic m_reduce_last,
    output logic [K_INDEX_W-1:0] m_k,
    output logic [3:0] m_input_channel,
    output logic [M_COUNT_W-1:0] m_count,
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
  localparam bit PARALLEL_READ = READ_COPIES == M_GROUP;

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
  logic [M_COUNT_W-1:0] group_count_q;
  logic group_pending_q;
  logic [RING_ROW_W-1:0] endpoint_ring_row_q;

  logic [DIM_W-1:0] emit_ky_q;
  logic [DIM_W-1:0] emit_kx_q;
  logic [3:0] emit_ic_q;
  logic [K_INDEX_W-1:0] emit_k_q;
  logic [M_COUNT_W-1:0] read_m_q;
  logic [63:0] pixel_q [0:M_GROUP-1];
  logic [63:0] prefetch_pixel_q [0:M_GROUP-1];
  logic prefetch_inflight_q;
  logic prefetch_valid_q;
  logic [63:0] ring_bank_read_q [0:READ_COPIES-1][0:RING_BANKS-1];
  logic [RING_BANK_W-1:0] read_bank_select_q [0:READ_COPIES-1];

  logic scan_inside;
  logic scan_step;
  logic s_fire;
  logic frame_fire;
  logic last_scan_position;
  logic at_group_endpoint;
  logic [M_COUNT_W-1:0] next_group_count;
  logic [DIM_W-1:0] endpoint_y;
  logic [DIM_W-1:0] endpoint_x;
  logic [RING_ADDR_W-1:0] write_addr;
  logic [RING_ADDR_W-1:0] read_addr [0:READ_COPIES-1];
  logic [RING_BANK_W-1:0] write_bank;
  logic [RING_BANK_W-1:0] read_bank [0:READ_COPIES-1];
  logic [8:0] write_bank_addr;
  logic [8:0] read_bank_addr [0:READ_COPIES-1];
  logic [RING_ROW_W:0] read_ring_row_sum;
  logic [RING_ROW_W-1:0] read_ring_row;
  logic [DIM_W-1:0] read_ky;
  logic [DIM_W-1:0] read_kx;
  logic [DIM_W-1:0] next_emit_ky;
  logic [DIM_W-1:0] next_emit_kx;
  logic prefetch_issue;
  logic [DIM_W-1:0] read_x [0:READ_COPIES-1];
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
    if (output_w_q - group_x_q >= M_GROUP)
      next_group_count = M_COUNT_W'(M_GROUP);
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
    if (emit_kx_q == kernel_q - 1'b1) begin
      next_emit_ky = emit_ky_q + 1'b1;
      next_emit_kx = '0;
    end else begin
      next_emit_ky = emit_ky_q;
      next_emit_kx = emit_kx_q + 1'b1;
    end
  end

  // With one replicated read port per M lane, fetch the next kernel position
  // while the current pixel word supplies its input-channel beats. AlexNet's
  // smallest channel count is three, which leaves enough time for the
  // synchronous BRAM issue/capture pair before the current word retires.
  assign prefetch_issue = PARALLEL_READ &&
                          (state_q == ST_EMIT) &&
                          (channel_count_q >= 3) &&
                          !prefetch_inflight_q && !prefetch_valid_q &&
                          !((emit_ky_q == kernel_q - 1'b1) &&
                            (emit_kx_q == kernel_q - 1'b1));

  always_comb begin
    if (prefetch_issue) begin
      read_ky = next_emit_ky;
      read_kx = next_emit_kx;
    end else begin
      read_ky = emit_ky_q;
      read_kx = emit_kx_q;
    end

    read_ring_row_sum = endpoint_ring_row_q + 1'b1 + read_ky;
    if (read_ring_row_sum >= kernel_q)
      read_ring_row = read_ring_row_sum - kernel_q;
    else
      read_ring_row = read_ring_row_sum[RING_ROW_W-1:0];

    for (int copy = 0; copy < READ_COPIES; copy++) begin
      if (stride_q == 4) begin
        if (READ_COPIES == 1)
          read_x[copy] = (group_x_q << 2) + (read_m_q << 2) + read_kx;
        else
          read_x[copy] = (group_x_q << 2) + (copy << 2) + read_kx;
      end else begin
        if (READ_COPIES == 1)
          read_x[copy] = group_x_q + read_m_q + read_kx;
        else
          read_x[copy] = group_x_q + copy + read_kx;
      end
    end
  end

  assign write_bank = write_addr[RING_ADDR_W-1:9];
  assign write_bank_addr = write_addr[8:0];

  generate
    for (genvar copy = 0; copy < READ_COPIES; copy++) begin : g_read_address
      assign read_addr[copy] =
          read_ring_row * MAX_PADDED_WIDTH + read_x[copy];
      assign read_bank[copy] = read_addr[copy][RING_ADDR_W-1:9];
      assign read_bank_addr[copy] = read_addr[copy][8:0];
    end
  endgenerate

  // Explicit 512x64 banking prevents the 2508-word logical depth from being
  // expanded into Vivado's larger irregular cascade. Each generated bank maps
  // independently to one RAMB36E2.
  generate
    for (genvar copy = 0; copy < READ_COPIES; copy++) begin : g_read_copy
      for (genvar bank = 0; bank < RING_BANKS; bank++) begin : g_ring_bank
        (* ram_style = "block" *) logic [63:0] mem [0:RING_BANK_WORDS-1];

        always_ff @(posedge clk) begin
          if (scan_step && write_bank == bank)
            mem[write_bank_addr] <= scan_values_masked;
          if (state_q == ST_READ_ISSUE || prefetch_issue)
            ring_bank_read_q[copy][bank] <= mem[read_bank_addr[copy]];
        end
      end
    end
  endgenerate

  always_comb begin
    m_valid = state_q == ST_EMIT;
    for (int g = 0; g < PHYS_ROWS; g++) begin
      m_act_lo[g] = $signed(pixel_q[2*g][emit_ic_q*8 +: 8]);
      m_act_hi[g] = $signed(pixel_q[2*g+1][emit_ic_q*8 +: 8]);
      m_lane_mask[g] = {group_count_q > 2*g + 1,
                        group_count_q > 2*g};
    end
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
      prefetch_inflight_q <= 1'b0;
      prefetch_valid_q <= 1'b0;
      for (int copy = 0; copy < READ_COPIES; copy++)
        read_bank_select_q[copy] <= '0;
      // Pixel payload registers intentionally have no reset. State and
      // prefetch-valid control qualify every use, and each live M lane is
      // overwritten by a BRAM capture before it can be emitted. Avoiding a
      // reset/clear mux here keeps frame-control fanout off the 1024 payload
      // bits and materially shortens the 200 MHz feeder path.
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
        prefetch_inflight_q <= 1'b0;
        prefetch_valid_q <= 1'b0;
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
          prefetch_inflight_q <= 1'b0;
          prefetch_valid_q <= 1'b0;
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

      if (state_q == ST_READ_ISSUE || prefetch_issue) begin
        for (int copy = 0; copy < READ_COPIES; copy++)
          read_bank_select_q[copy] <= read_bank[copy];
      end

      if (prefetch_issue)
        prefetch_inflight_q <= 1'b1;

      if (prefetch_inflight_q) begin
        for (int m = 0; m < M_GROUP; m++) begin
          if (m < group_count_q)
            prefetch_pixel_q[m] <=
                ring_bank_read_q[m % READ_COPIES]
                                [read_bank_select_q[m % READ_COPIES]];
          else
            prefetch_pixel_q[m] <= '0;
        end
        prefetch_inflight_q <= 1'b0;
        prefetch_valid_q <= 1'b1;
      end

      if (state_q == ST_READ_ISSUE) begin
        state_q <= ST_READ_CAPTURE;
      end

      if (state_q == ST_READ_CAPTURE) begin
        if (READ_COPIES == 1) begin
          pixel_q[read_m_q] <=
              ring_bank_read_q[0][read_bank_select_q[0]];
          if (read_m_q == group_count_q - 1'b1) begin
            for (int m = 0; m < M_GROUP; m++) begin
              if (m >= group_count_q)
                pixel_q[m] <= '0;
            end
            read_m_q <= '0;
            state_q <= ST_EMIT;
          end else begin
            read_m_q <= read_m_q + 1'b1;
            state_q <= ST_READ_ISSUE;
          end
        end else begin
          for (int m = 0; m < M_GROUP; m++) begin
            if (m < group_count_q)
              pixel_q[m] <= ring_bank_read_q[m][read_bank_select_q[m]];
            else
              pixel_q[m] <= '0;
          end
          state_q <= ST_EMIT;
        end
      end

      if (state_q == ST_EMIT && m_ready) begin
        if (m_reduce_last) begin
          if (group_x_q + M_GROUP >= output_w_q) begin
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
            group_x_q <= group_x_q + M_GROUP;
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
          if (PARALLEL_READ && prefetch_valid_q) begin
            for (int m = 0; m < M_GROUP; m++)
              pixel_q[m] <= prefetch_pixel_q[m];
            prefetch_valid_q <= 1'b0;
          end else begin
            state_q <= ST_READ_ISSUE;
          end
        end else begin
          emit_ic_q <= emit_ic_q + 1'b1;
          emit_k_q <= emit_k_q + 1'b1;
        end
      end
    end
  end

`ifndef SYNTHESIS
  initial begin
    if (!((PHYS_ROWS == 2 && M_GROUP == 4 && READ_COPIES == 1) ||
          (PHYS_ROWS == 4 && M_GROUP == 8 && READ_COPIES == 8)))
      $fatal(1, "RS feeder supports M4 serial-read or M8 parallel-read mode");
  end

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
