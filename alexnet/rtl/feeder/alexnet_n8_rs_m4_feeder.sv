`timescale 1ns/1ps

// One N8 row-stationary convolution window-feeder slice.
//
// Input pixels arrive in raster order with up to eight input channels packed
// into each 64-bit beat. The feeder walks a virtual padded raster, retains
// K+stride rows, and emits flattened spatial groups in the frozen K order:
//
//   k = ((kernel_y * kernel) + kernel_x) * channel_count + input_channel
//
// Kernel/stride/padding are descriptor controlled for the AlexNet modes
// K11/s4/p2, K5/s1/p2, and K3/s1/p1. A group may cross one output-row
// boundary, eliminating the per-row M tail. The independent scanner overlaps
// BRAM writes with window read/emit and row credits prevent it from
// overwriting the oldest live window.
module alexnet_n8_rs_m4_feeder #(
    parameter int PHYS_ROWS = 2,
    parameter int M_GROUP = 2 * PHYS_ROWS,
    parameter int M_COUNT_W = $clog2(M_GROUP + 1),
    parameter int READ_COPIES = PHYS_ROWS >= 4 ? M_GROUP : 1,
    parameter int MAX_INPUT_WIDTH = 224,
    parameter int MAX_KERNEL = 11,
    parameter int MAX_STRIDE = 4,
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
  // A cross-row group can simultaneously reference windows whose input-row
  // origins differ by one output stride. K+stride rows are therefore needed;
  // K+1 is sufficient only for the stride-1 layers.
  localparam int MAX_RING_ROWS = MAX_KERNEL + MAX_STRIDE;
  localparam int RING_LOGICAL_DEPTH = MAX_RING_ROWS * MAX_PADDED_WIDTH;
  localparam int RING_BANK_WORDS = 512;
  localparam int RING_BANKS =
      (RING_LOGICAL_DEPTH + RING_BANK_WORDS - 1) / RING_BANK_WORDS;
  localparam int RING_ADDR_W = $clog2(RING_LOGICAL_DEPTH);
  localparam int RING_BANK_W = $clog2(RING_BANKS);
  localparam int RING_ROW_W = $clog2(MAX_RING_ROWS);
  localparam bit PARALLEL_READ = READ_COPIES == M_GROUP;

  typedef enum logic [2:0] {
    ST_IDLE,
    ST_PLAN,
    ST_ENDPOINT,
    ST_WAIT_DATA,
    ST_PREP,
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
  logic [RING_ROW_W:0] runtime_ring_rows_q;
  logic [FRAME_TAG_W-1:0] frame_tag_q;

  logic [DIM_W-1:0] scan_y_q;
  logic [DIM_W-1:0] scan_x_q;
  logic [RING_ROW_W-1:0] write_ring_row_q;
  logic scan_complete_q;

  logic [DIM_W-1:0] group_y_q;
  logic [DIM_W-1:0] group_x_q;
  logic [M_COUNT_W-1:0] group_count_q;
  logic group_pending_q;
  logic [DIM_W-1:0] group_end_y_q;
  logic [DIM_W-1:0] group_end_x_q;
  logic [DIM_W-1:0] next_group_y_q;
  logic [DIM_W-1:0] next_group_x_q;
  logic next_group_is_last_q;
  logic [DIM_W-1:0] planned_endpoint_y_q;
  logic [DIM_W-1:0] planned_endpoint_x_q;
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
  logic [M_COUNT_W-1:0] next_group_count;
  logic [DIM_W:0] group_span_capacity;
  logic [DIM_W:0] group_end_x_sum;
  logic [DIM_W:0] group_advance_x_sum;
  logic [DIM_W:0] next_group_y;
  logic [DIM_W-1:0] next_group_x;
  logic group_is_last;
  logic [DIM_W-1:0] endpoint_group_y;
  logic [DIM_W-1:0] endpoint_group_x;
  logic [DIM_W-1:0] endpoint_y;
  logic [DIM_W-1:0] endpoint_x;
  logic group_data_available;
  logic scan_enable;
  logic scan_has_row_credit;
  logic scan_finishing;
  logic [DIM_W:0] protected_row_limit;
  logic [DIM_W-1:0] endpoint_row_lag;
  logic [DIM_W:0] endpoint_ring_sum;
  logic [RING_ROW_W-1:0] endpoint_ring_row;
  logic [RING_ADDR_W-1:0] write_addr;
  logic [RING_ADDR_W-1:0] read_addr [0:READ_COPIES-1];
  logic [RING_BANK_W-1:0] write_bank;
  logic [RING_BANK_W-1:0] read_bank [0:READ_COPIES-1];
  logic [8:0] write_bank_addr;
  logic [8:0] read_bank_addr [0:READ_COPIES-1];
  logic [DIM_W:0] plan_lane_x_sum [0:M_GROUP-1];
  logic [DIM_W-1:0] plan_output_y [0:M_GROUP-1];
  logic [DIM_W-1:0] plan_output_x [0:M_GROUP-1];
  logic [DIM_W-1:0] plan_row_lag [0:M_GROUP-1];
  logic [DIM_W:0] plan_ring_row_sum [0:M_GROUP-1];
  logic [RING_ROW_W-1:0] plan_ring_row [0:M_GROUP-1];
  logic [DIM_W-1:0] plan_x_base [0:M_GROUP-1];
  logic [RING_ROW_W-1:0] lane_ring_base_q [0:M_GROUP-1];
  logic [RING_ADDR_W-1:0] lane_row_addr_q [0:M_GROUP-1];
  logic [DIM_W-1:0] lane_x_base_q [0:M_GROUP-1];
  logic [RING_ROW_W-1:0] selected_lane_ring_base [0:READ_COPIES-1];
  logic [RING_ADDR_W-1:0] selected_lane_row_addr [0:READ_COPIES-1];
  logic [DIM_W-1:0] selected_lane_x_base [0:READ_COPIES-1];
  logic [RING_ADDR_W-1:0] selected_read_row_addr [0:READ_COPIES-1];
  logic [DIM_W-1:0] read_kx;
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
  assign scan_enable = frame_active;
  assign protected_row_limit = (stride_q == 4 ?
      ({1'b0, group_y_q} << 2) : {1'b0, group_y_q}) +
      runtime_ring_rows_q;
  assign scan_has_row_credit = !group_pending_q ||
                               ({1'b0, scan_y_q} < protected_row_limit);
  assign s_ready = scan_enable && !scan_complete_q && scan_has_row_credit &&
                   scan_inside;
  assign s_fire = s_valid && s_ready;
  assign scan_step = scan_enable && !scan_complete_q &&
                     scan_has_row_credit && (!scan_inside || s_fire);
  assign last_scan_position = (scan_y_q == padded_h_q - 1'b1) &&
                              (scan_x_q == padded_w_q - 1'b1);
  assign scan_finishing = scan_step && last_scan_position;

  always_comb begin
    // Flatten output positions so a full group can continue into the next
    // row. Limiting a group to at most two rows bounds the live-window span
    // to one stride and makes the K+stride ownership contract explicit.
    group_span_capacity = output_w_q - group_x_q;
    if (group_y_q + 1'b1 < output_h_q)
      group_span_capacity = group_span_capacity + output_w_q;
    if (group_span_capacity >= M_GROUP)
      next_group_count = M_COUNT_W'(M_GROUP);
    else
      next_group_count = M_COUNT_W'(group_span_capacity);

    group_end_x_sum = group_x_q + next_group_count - 1'b1;
    if (group_end_x_sum >= output_w_q) begin
      endpoint_group_y = group_y_q + 1'b1;
      endpoint_group_x = group_end_x_sum - output_w_q;
    end else begin
      endpoint_group_y = group_y_q;
      endpoint_group_x = group_end_x_sum[DIM_W-1:0];
    end

    // group_count_q was registered by ST_PLAN.  Use it here so the next-group
    // coordinate path does not include the span/count planning cone; ST_PREP
    // captures these coordinates before any payload is emitted.
    group_advance_x_sum = group_x_q + group_count_q;
    if (group_advance_x_sum >= ({1'b0, output_w_q} << 1)) begin
      next_group_y = group_y_q + 2;
      next_group_x = group_advance_x_sum -
                     ({1'b0, output_w_q} << 1);
    end else if (group_advance_x_sum >= output_w_q) begin
      next_group_y = group_y_q + 1'b1;
      next_group_x = group_advance_x_sum - output_w_q;
    end else begin
      next_group_y = group_y_q;
      next_group_x = group_advance_x_sum[DIM_W-1:0];
    end
    group_is_last = next_group_y >= output_h_q;

    // ST_PLAN registers the group's last output coordinate first.  Deriving
    // the input-data endpoint from those registers in ST_ENDPOINT keeps the
    // span/count planning cone out of this path.
    if (stride_q == 4) begin
      endpoint_y = (group_end_y_q << 2) + kernel_q - 1'b1;
      endpoint_x = (group_end_x_q << 2) + kernel_q - 1'b1;
    end else begin
      endpoint_y = group_end_y_q + kernel_q - 1'b1;
      endpoint_x = group_end_x_q + kernel_q - 1'b1;
    end
  end

  assign group_data_available = scan_complete_q ||
      (scan_y_q > planned_endpoint_y_q) ||
      ((scan_y_q == planned_endpoint_y_q) &&
       (scan_x_q > planned_endpoint_x_q)) ||
      ((scan_y_q == planned_endpoint_y_q) &&
       (scan_x_q == planned_endpoint_x_q) && scan_step);

  assign endpoint_row_lag = scan_y_q - planned_endpoint_y_q;
  assign endpoint_ring_sum = write_ring_row_q + runtime_ring_rows_q -
                             endpoint_row_lag;
  assign endpoint_ring_row = endpoint_ring_sum >= runtime_ring_rows_q ?
      endpoint_ring_sum - runtime_ring_rows_q : endpoint_ring_sum;

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
      next_emit_kx = '0;
    end else begin
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
      read_kx = next_emit_kx;
    end else begin
      read_kx = emit_kx_q;
    end

    for (int m = 0; m < M_GROUP; m++) begin
      if (m < group_count_q)
        plan_lane_x_sum[m] = group_x_q + m;
      else
        plan_lane_x_sum[m] = group_x_q;
      if (plan_lane_x_sum[m] >= output_w_q) begin
        plan_output_y[m] = group_y_q + 1'b1;
        plan_output_x[m] = plan_lane_x_sum[m] - output_w_q;
      end else begin
        plan_output_y[m] = group_y_q;
        plan_output_x[m] = plan_lane_x_sum[m][DIM_W-1:0];
      end
      plan_row_lag[m] = kernel_q - 1'b1;
      if (group_end_y_q != plan_output_y[m])
        plan_row_lag[m] = plan_row_lag[m] + stride_q;
      plan_ring_row_sum[m] = endpoint_ring_row_q + runtime_ring_rows_q -
                             plan_row_lag[m];
      if (plan_ring_row_sum[m] >= runtime_ring_rows_q)
        plan_ring_row[m] = plan_ring_row_sum[m] - runtime_ring_rows_q;
      else
        plan_ring_row[m] = plan_ring_row_sum[m][RING_ROW_W-1:0];
      if (stride_q == 4)
        plan_x_base[m] = plan_output_x[m] << 2;
      else
        plan_x_base[m] = plan_output_x[m];
    end

    for (int copy = 0; copy < READ_COPIES; copy++) begin
      if (READ_COPIES == 1) begin
        selected_lane_ring_base[copy] = lane_ring_base_q[read_m_q];
        selected_lane_row_addr[copy] = lane_row_addr_q[read_m_q];
        selected_lane_x_base[copy] = lane_x_base_q[read_m_q];
      end else begin
        selected_lane_ring_base[copy] = lane_ring_base_q[copy];
        selected_lane_row_addr[copy] = lane_row_addr_q[copy];
        selected_lane_x_base[copy] = lane_x_base_q[copy];
      end
      // The row-word address advances once per kernel row.  Keeping this
      // product in a register removes runtime modulo and constant multiply
      // logic from every replicated BRAM address port.  A row-boundary
      // prefetch uses the one-row look-ahead value; the registers themselves
      // advance when the current kernel position retires.
      selected_read_row_addr[copy] = selected_lane_row_addr[copy];
      if (prefetch_issue && next_emit_kx == 0) begin
        if (selected_lane_ring_base[copy] == runtime_ring_rows_q - 1'b1)
          selected_read_row_addr[copy] = '0;
        else
          selected_read_row_addr[copy] = selected_lane_row_addr[copy] +
                                         MAX_PADDED_WIDTH;
      end
      read_x[copy] = selected_lane_x_base[copy] + read_kx;
    end
  end

  assign write_bank = write_addr[RING_ADDR_W-1:9];
  assign write_bank_addr = write_addr[8:0];

  generate
    for (genvar copy = 0; copy < READ_COPIES; copy++) begin : g_read_address
      assign read_addr[copy] =
          selected_read_row_addr[copy] + read_x[copy];
      assign read_bank[copy] = read_addr[copy][RING_ADDR_W-1:9];
      assign read_bank_addr[copy] = read_addr[copy][8:0];
    end
  endgenerate

  // Explicit 512x64 banking prevents the logical depth from being
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
      runtime_ring_rows_q <= '0;
      frame_tag_q <= '0;
      scan_y_q <= '0;
      scan_x_q <= '0;
      write_ring_row_q <= '0;
      scan_complete_q <= 1'b0;
      group_y_q <= '0;
      group_x_q <= '0;
      group_count_q <= '0;
      group_pending_q <= 1'b0;
      group_end_y_q <= '0;
      group_end_x_q <= '0;
      next_group_y_q <= '0;
      next_group_x_q <= '0;
      next_group_is_last_q <= 1'b0;
      planned_endpoint_y_q <= '0;
      planned_endpoint_x_q <= '0;
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
      for (int m = 0; m < M_GROUP; m++) begin
        lane_ring_base_q[m] <= '0;
        lane_row_addr_q[m] <= '0;
        lane_x_base_q[m] <= '0;
      end
      // Pixel payload registers intentionally have no reset. State and
      // prefetch-valid control qualify every use, and each live M lane is
      // overwritten by a BRAM capture before it can be emitted. Avoiding a
      // reset/clear mux here keeps frame-control fanout off the 1024 payload
      // bits and materially shortens the 200 MHz feeder path.
      frame_done <= 1'b0;
    end else begin
      frame_done <= 1'b0;

      if (frame_fire) begin
        state_q <= ST_PLAN;
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
        runtime_ring_rows_q <= frame_kernel + frame_stride;
        frame_tag_q <= frame_tag;
        scan_y_q <= '0;
        scan_x_q <= '0;
        write_ring_row_q <= '0;
        scan_complete_q <= 1'b0;
        group_y_q <= '0;
        group_x_q <= '0;
        group_count_q <= '0;
        group_pending_q <= 1'b1;
        group_end_y_q <= '0;
        group_end_x_q <= '0;
        next_group_y_q <= '0;
        next_group_x_q <= '0;
        next_group_is_last_q <= 1'b0;
        planned_endpoint_y_q <= '0;
        planned_endpoint_x_q <= '0;
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
        if (last_scan_position)
          scan_complete_q <= 1'b1;
        else if (scan_x_q == padded_w_q - 1'b1) begin
          scan_x_q <= '0;
          scan_y_q <= scan_y_q + 1'b1;
          if (write_ring_row_q == runtime_ring_rows_q - 1'b1)
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

      case (state_q)
        ST_PLAN: begin
          if (!group_pending_q) begin
            if (scan_complete_q || scan_finishing) begin
              state_q <= ST_IDLE;
              frame_done <= 1'b1;
            end
          end else begin
            group_count_q <= next_group_count;
            group_end_y_q <= endpoint_group_y;
            group_end_x_q <= endpoint_group_x;
            state_q <= ST_ENDPOINT;
          end
        end

        ST_ENDPOINT: begin
          planned_endpoint_y_q <= endpoint_y;
          planned_endpoint_x_q <= endpoint_x;
          state_q <= ST_WAIT_DATA;
        end

        ST_WAIT_DATA: begin
          if (group_data_available) begin
            endpoint_ring_row_q <= endpoint_ring_row;
            emit_ky_q <= '0;
            emit_kx_q <= '0;
            emit_ic_q <= '0;
            emit_k_q <= '0;
            read_m_q <= '0;
            prefetch_inflight_q <= 1'b0;
            prefetch_valid_q <= 1'b0;
            state_q <= ST_PREP;
          end
        end

        ST_PREP: begin
          for (int m = 0; m < M_GROUP; m++) begin
            lane_ring_base_q[m] <= plan_ring_row[m];
            lane_row_addr_q[m] <= plan_ring_row[m] * MAX_PADDED_WIDTH;
            lane_x_base_q[m] <= plan_x_base[m];
          end
          next_group_y_q <= next_group_y[DIM_W-1:0];
          next_group_x_q <= next_group_x;
          next_group_is_last_q <= group_is_last;
          state_q <= ST_READ_ISSUE;
        end

        ST_EMIT: begin
          if (m_ready && m_reduce_last) begin
            if (next_group_is_last_q) begin
              group_pending_q <= 1'b0;
              if (scan_complete_q || scan_finishing) begin
                state_q <= ST_IDLE;
                frame_done <= 1'b1;
              end else begin
                state_q <= ST_PLAN;
              end
            end else begin
              group_y_q <= next_group_y_q;
              group_x_q <= next_group_x_q;
              state_q <= ST_PLAN;
            end
            emit_ky_q <= '0;
            emit_kx_q <= '0;
            emit_ic_q <= '0;
            emit_k_q <= '0;
          end else if (m_ready && emit_ic_q == channel_count_q - 1'b1) begin
            emit_ic_q <= '0;
            emit_k_q <= emit_k_q + 1'b1;
            if (emit_kx_q == kernel_q - 1'b1) begin
              emit_kx_q <= '0;
              emit_ky_q <= emit_ky_q + 1'b1;
              for (int m = 0; m < M_GROUP; m++) begin
                if (lane_ring_base_q[m] == runtime_ring_rows_q - 1'b1) begin
                  lane_ring_base_q[m] <= '0;
                  lane_row_addr_q[m] <= '0;
                end else begin
                  lane_ring_base_q[m] <= lane_ring_base_q[m] + 1'b1;
                  lane_row_addr_q[m] <= lane_row_addr_q[m] +
                                        MAX_PADDED_WIDTH;
                end
              end
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
          end else if (m_ready) begin
            emit_ic_q <= emit_ic_q + 1'b1;
            emit_k_q <= emit_k_q + 1'b1;
          end
        end

        default: ;
      endcase
    end
  end

`ifndef SYNTHESIS
  initial begin
    if (!((PHYS_ROWS == 2 && M_GROUP == 4 && READ_COPIES == 1) ||
          (PHYS_ROWS == 4 && M_GROUP == 8 && READ_COPIES == 8) ||
          (PHYS_ROWS == 8 && M_GROUP == 16 && READ_COPIES == 16)))
      $fatal(1,
             "RS feeder supports M4 serial-read, M8 or M16 parallel-read mode");
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
