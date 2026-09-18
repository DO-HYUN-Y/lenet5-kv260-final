`timescale 1ns/1ps

// Stride-aware banked M16 row-stationary feeder.
//
// The legacy M16 feeder obtains sixteen reads by replicating the complete
// ring store sixteen times.  This implementation stores every pixel once in
// one of sixteen word banks and four x-mod-4 byte-word planes:
//
//   stride 1: bank = x mod 16, plane = 0
//   stride 4: bank = floor(x/4) mod 16, plane = x mod 4
//
// Sixteen consecutive output positions request one word from each bank within
// an output row.  A flattened M16 group may cross one row boundary, so those
// uncommon groups use two consecutive read passes.  Every 512x64 bank/plane
// is simple dual port: the write port keeps accepting the raster while the
// read port fetches a patch.  This shape fits one RAMB36E2, for a target of
// 16*4 = 64 RAMB36E2 instead of the legacy 112 RAMB36E2 copies.
module alexnet_n8_rs_m16_xmod4_feeder #(
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

  localparam int M_GROUP = 16;
  localparam int WORD_BANKS = 16;
  localparam int XMOD4_PLANES = 4;
  localparam int MAX_PADDED_WIDTH = MAX_INPUT_WIDTH + 2 * MAX_PADDING;
  localparam int MAX_RING_ROWS = MAX_KERNEL + 4;
  localparam int S1_WORDS_PER_ROW =
      (MAX_PADDED_WIDTH + WORD_BANKS - 1) / WORD_BANKS;
  localparam int S4_WORDS_PER_ROW =
      (MAX_PADDED_WIDTH + 4*WORD_BANKS - 1) / (4*WORD_BANKS);
  localparam int BANK_DEPTH = 512;
  localparam int BANK_ADDR_W = $clog2(BANK_DEPTH);
  localparam int RING_ROW_W = $clog2(MAX_RING_ROWS);

  typedef enum logic [3:0] {
    ST_IDLE,
    ST_PLAN,
    ST_PLAN_ENDPOINT,
    ST_WAIT_DATA,
    ST_READ_ISSUE,
    ST_READ_WAIT,
    ST_READ_SECOND,
    ST_READ_SECOND_WAIT,
    ST_READ_CAPTURE,
    ST_EMIT,
    ST_DRAIN_SCAN
  } state_t;

  state_t state_q;
  logic [DIM_W-1:0] input_h_q, input_w_q;
  logic [DIM_W-1:0] padded_h_q, padded_w_q;
  logic [DIM_W-1:0] output_h_q, output_w_q;
  logic [3:0] channel_count_q;
  logic [7:0] lane_mask_q;
  logic [DIM_W-1:0] kernel_q, stride_q, padding_q;
  logic [FRAME_TAG_W-1:0] frame_tag_q;

  logic [DIM_W-1:0] scan_y_q, scan_x_q;
  logic [RING_ROW_W-1:0] write_ring_row_q;
  logic scan_complete_q;

  logic [DIM_W-1:0] group_y_q, group_x_q;
  logic [4:0] group_count_q;
  logic [DIM_W-1:0] planned_endpoint_y_q, planned_endpoint_x_q;
  logic [DIM_W-1:0] endpoint_group_y_q, endpoint_group_x_q;
  logic [DIM_W-1:0] next_group_y_q, next_group_x_q;
  logic next_group_is_last_q;
  logic [RING_ROW_W-1:0] first_row_ring_base_q;
  logic [RING_ROW_W-1:0] second_row_ring_base_q;
  logic [DIM_W-1:0] lane_x_base_q [0:M_GROUP-1];
  logic lane_second_row_q [0:M_GROUP-1];
  logic group_crosses_row_q;

  logic [DIM_W-1:0] emit_ky_q, emit_kx_q;
  logic [3:0] emit_ic_q;
  logic [K_INDEX_W-1:0] emit_k_q;
  logic [63:0] pixel_q [0:M_GROUP-1];
  logic [63:0] prefetch_pixel_q [0:M_GROUP-1];
  logic [2:0] prefetch_phase_q;
  logic prefetch_valid_q;

  logic [63:0] bank_read_q [0:WORD_BANKS-1][0:XMOD4_PLANES-1];
  logic [63:0] bank_plane_data [0:WORD_BANKS-1];
  logic [63:0] lane_read_data [0:M_GROUP-1];
  logic [3:0] capture_bank_q [0:M_GROUP-1];
  logic [1:0] capture_plane_q;
  logic read_cmd_valid_q;
  logic [1:0] read_cmd_plane_q;
  logic [BANK_ADDR_W-1:0] read_cmd_addr_q [0:WORD_BANKS-1];
  logic [3:0] read_cmd_bank_q [0:M_GROUP-1];

  logic frame_fire, s_fire, scan_inside, scan_step;
  logic last_scan_position, scan_finishing, scan_has_row_credit;
  logic memory_read_issue, read_second_pass;
  logic prefetch_first_issue, prefetch_second_issue;
  logic prefetch_complete_now;
  logic emit_wait_for_prefetch;
  logic [DIM_W-1:0] read_ky, read_kx;
  logic [DIM_W-1:0] next_read_ky, next_read_kx;
  logic last_spatial_position;
  logic group_data_available;

  logic [DIM_W:0] group_span_capacity, group_end_x_sum;
  logic [4:0] planned_group_count;
  logic [DIM_W-1:0] endpoint_group_y, endpoint_group_x;
  logic [DIM_W:0] group_advance_x_sum;
  logic [DIM_W:0] planned_next_group_y;
  logic [DIM_W-1:0] planned_next_group_x;
  logic planned_group_is_last;
  logic [DIM_W-1:0] planned_endpoint_y, planned_endpoint_x;

  logic [DIM_W:0] endpoint_row_lag;
  logic [DIM_W:0] endpoint_ring_sum;
  logic [RING_ROW_W-1:0] endpoint_ring_row;
  logic [DIM_W:0] protected_row_limit;
  logic [DIM_W:0] lane_flat_x_sum [0:M_GROUP-1];
  logic [DIM_W-1:0] plan_output_y [0:M_GROUP-1];
  logic [DIM_W-1:0] plan_output_x [0:M_GROUP-1];
  logic [DIM_W:0] plan_input_y [0:M_GROUP-1];
  logic [DIM_W:0] plan_row_lag [0:M_GROUP-1];
  logic [DIM_W+1:0] plan_ring_sum [0:M_GROUP-1];
  logic [RING_ROW_W-1:0] plan_ring_row [0:M_GROUP-1];

  logic [DIM_W:0] read_x_for_lane [0:M_GROUP-1];
  logic [DIM_W:0] read_word_index [0:M_GROUP-1];
  logic [3:0] read_bank_for_lane [0:M_GROUP-1];
  logic [BANK_ADDR_W-1:0] bank_read_addr [0:WORD_BANKS-1];
  logic [DIM_W:0] read_output_x_start;
  logic [DIM_W:0] read_base_word;
  logic [3:0] read_base_bank;
  logic [DIM_W:0] read_base_column;
  logic [1:0] read_plane;
  logic [RING_ROW_W-1:0] read_common_ring_base;
  logic [RING_ROW_W:0] read_common_ring_sum;
  logic [RING_ROW_W-1:0] read_common_ring_row;
  logic [DIM_W:0] read_row_address_base;

  logic [DIM_W:0] write_word_index;
  logic [3:0] write_bank;
  logic [1:0] write_plane;
  logic [BANK_ADDR_W-1:0] write_bank_addr;
  logic [63:0] scan_values_masked;
  logic write_valid_q;
  logic [3:0] write_bank_q;
  logic [1:0] write_plane_q;
  logic [BANK_ADDR_W-1:0] write_bank_addr_q;
  logic [63:0] write_data_q;
  logic [3:0] expected_lane_count;
  logic [7:0] expected_lane_mask;

  assign idle = state_q == ST_IDLE;
  assign frame_ready = idle;
  assign frame_fire = frame_valid && frame_ready;
  assign frame_active = !idle;

  assign scan_inside = scan_y_q >= padding_q &&
                       scan_y_q < padding_q + input_h_q &&
                       scan_x_q >= padding_q &&
                       scan_x_q < padding_q + input_w_q;
  assign protected_row_limit = group_y_q * stride_q + MAX_RING_ROWS;
  assign scan_has_row_credit = state_q == ST_DRAIN_SCAN ||
                               scan_y_q < protected_row_limit;
  assign s_ready = frame_active && !scan_complete_q && scan_inside &&
                   scan_has_row_credit;
  assign s_fire = s_valid && s_ready;
  assign scan_step = frame_active && !scan_complete_q &&
                     scan_has_row_credit && (!scan_inside || s_fire);
  assign last_scan_position = scan_y_q == padded_h_q - 1'b1 &&
                              scan_x_q == padded_w_q - 1'b1;
  assign scan_finishing = scan_step && last_scan_position;

  always_comb begin
    group_span_capacity = output_w_q - group_x_q;
    if (group_y_q + 1'b1 < output_h_q)
      group_span_capacity = group_span_capacity + output_w_q;
    if (group_span_capacity >= M_GROUP)
      planned_group_count = 5'd16;
    else
      planned_group_count = group_span_capacity[4:0];

    group_end_x_sum = group_x_q + planned_group_count - 1'b1;
    if (group_end_x_sum >= output_w_q) begin
      endpoint_group_y = group_y_q + 1'b1;
      endpoint_group_x = group_end_x_sum - output_w_q;
    end else begin
      endpoint_group_y = group_y_q;
      endpoint_group_x = group_end_x_sum[DIM_W-1:0];
    end
    planned_endpoint_y = endpoint_group_y_q * stride_q + kernel_q - 1'b1;
    planned_endpoint_x = endpoint_group_x_q * stride_q + kernel_q - 1'b1;

    group_advance_x_sum = group_x_q + planned_group_count;
    if (group_advance_x_sum >= ({1'b0, output_w_q} << 1)) begin
      planned_next_group_y = group_y_q + 2;
      planned_next_group_x = group_advance_x_sum -
                             ({1'b0, output_w_q} << 1);
    end else if (group_advance_x_sum >= output_w_q) begin
      planned_next_group_y = group_y_q + 1'b1;
      planned_next_group_x = group_advance_x_sum - output_w_q;
    end else begin
      planned_next_group_y = group_y_q;
      planned_next_group_x = group_advance_x_sum[DIM_W-1:0];
    end
    planned_group_is_last = planned_next_group_y >= output_h_q;
  end

  assign group_data_available = scan_complete_q ||
      scan_y_q > planned_endpoint_y_q ||
      (scan_y_q == planned_endpoint_y_q &&
       scan_x_q > planned_endpoint_x_q);

  assign endpoint_row_lag = scan_y_q - planned_endpoint_y_q;
  assign endpoint_ring_sum = write_ring_row_q + MAX_RING_ROWS -
                             endpoint_row_lag;
  assign endpoint_ring_row = endpoint_ring_sum >= MAX_RING_ROWS ?
      endpoint_ring_sum - MAX_RING_ROWS : endpoint_ring_sum[RING_ROW_W-1:0];

  always_comb begin
    for (int lane = 0; lane < M_GROUP; lane++) begin
      lane_flat_x_sum[lane] = group_x_q + lane;
      if (lane_flat_x_sum[lane] >= output_w_q) begin
        plan_output_y[lane] = group_y_q + 1'b1;
        plan_output_x[lane] = lane_flat_x_sum[lane] - output_w_q;
      end else begin
        plan_output_y[lane] = group_y_q;
        plan_output_x[lane] = lane_flat_x_sum[lane][DIM_W-1:0];
      end
      plan_input_y[lane] = plan_output_y[lane] * stride_q;
      plan_row_lag[lane] = planned_endpoint_y_q - plan_input_y[lane];
      plan_ring_sum[lane] = endpoint_ring_row + MAX_RING_ROWS -
                            plan_row_lag[lane];
      if (plan_ring_sum[lane] >= MAX_RING_ROWS)
        plan_ring_row[lane] = plan_ring_sum[lane] - MAX_RING_ROWS;
      else
        plan_ring_row[lane] = plan_ring_sum[lane][RING_ROW_W-1:0];
    end
  end

  assign last_spatial_position = emit_ky_q == kernel_q - 1'b1 &&
                                 emit_kx_q == kernel_q - 1'b1;
  always_comb begin
    next_read_ky = emit_ky_q;
    next_read_kx = emit_kx_q + 1'b1;
    if (emit_kx_q == kernel_q - 1'b1) begin
      next_read_ky = emit_ky_q + 1'b1;
      next_read_kx = '0;
    end
    prefetch_first_issue = state_q == ST_EMIT && channel_count_q >= 3 &&
                           !last_spatial_position && prefetch_phase_q == 0 &&
                           !prefetch_valid_q;
    prefetch_second_issue = state_q == ST_EMIT &&
                            prefetch_phase_q == 1 && group_crosses_row_q;
    prefetch_complete_now = state_q == ST_EMIT &&
                            ((!group_crosses_row_q &&
                              prefetch_phase_q == 2) ||
                             (group_crosses_row_q &&
                              prefetch_phase_q == 3));
    memory_read_issue = state_q == ST_READ_ISSUE ||
                        state_q == ST_READ_SECOND ||
                        prefetch_first_issue || prefetch_second_issue;
    read_second_pass = state_q == ST_READ_SECOND || prefetch_second_issue;
    if (prefetch_first_issue || prefetch_second_issue) begin
      read_ky = next_read_ky;
      read_kx = next_read_kx;
    end else begin
      read_ky = emit_ky_q;
      read_kx = emit_kx_q;
    end
  end

  always_comb begin
    if (read_second_pass) begin
      read_output_x_start = '0;
      read_common_ring_base = second_row_ring_base_q;
    end else begin
      read_output_x_start = group_x_q;
      read_common_ring_base = first_row_ring_base_q;
    end

    if (stride_q == 4) begin
      read_base_word = read_output_x_start + (read_kx >> 2);
      read_plane = read_kx[1:0];
    end else begin
      read_base_word = read_output_x_start + read_kx;
      read_plane = '0;
    end
    read_base_bank = read_base_word[3:0];
    read_base_column = read_base_word >> 4;
    read_common_ring_sum = read_common_ring_base + read_ky;
    if (read_common_ring_sum >= MAX_RING_ROWS)
      read_common_ring_row = read_common_ring_sum - MAX_RING_ROWS;
    else
      read_common_ring_row = read_common_ring_sum[RING_ROW_W-1:0];
    if (stride_q == 4)
      read_row_address_base = read_common_ring_row * S4_WORDS_PER_ROW +
                              read_base_column;
    else
      read_row_address_base = read_common_ring_row * S1_WORDS_PER_ROW +
                              read_base_column;

    for (int bank = 0; bank < WORD_BANKS; bank++) begin
      bank_read_addr[bank] = read_row_address_base;
      if (bank < read_base_bank)
        bank_read_addr[bank] = read_row_address_base + 1'b1;
    end
    for (int lane = 0; lane < M_GROUP; lane++) begin
      read_x_for_lane[lane] = lane_x_base_q[lane] + read_kx;
      if (stride_q == 4) begin
        read_word_index[lane] = read_x_for_lane[lane] >> 2;
        read_bank_for_lane[lane] = read_word_index[lane][3:0];
      end else begin
        read_word_index[lane] = read_x_for_lane[lane];
        read_bank_for_lane[lane] = read_x_for_lane[lane][3:0];
      end
    end
  end

  always_comb begin
    scan_values_masked = '0;
    if (scan_inside) begin
      for (int lane = 0; lane < 8; lane++)
        if (lane_mask_q[lane] && s_lane_mask[lane])
          scan_values_masked[lane*8 +: 8] = s_values[lane*8 +: 8];
    end
    if (stride_q == 4) begin
      write_word_index = scan_x_q >> 2;
      write_bank = write_word_index[3:0];
      write_plane = scan_x_q[1:0];
      write_bank_addr = write_ring_row_q * S4_WORDS_PER_ROW +
                        (write_word_index >> 4);
    end else begin
      write_word_index = scan_x_q;
      write_bank = scan_x_q[3:0];
      write_plane = 0;
      write_bank_addr = write_ring_row_q * S1_WORDS_PER_ROW +
                        (scan_x_q >> 4);
    end
  end

  generate
    for (genvar bank = 0; bank < WORD_BANKS; bank++) begin : g_bank
      for (genvar plane = 0; plane < XMOD4_PLANES; plane++) begin : g_plane
        (* ram_style = "block" *) logic [63:0] mem [0:BANK_DEPTH-1];

        // Independent write and synchronous read ports infer one 512x64
        // simple-dual-port RAMB36E2 for each bank/plane.
        always_ff @(posedge clk) begin
          if (write_valid_q && write_bank_q == bank &&
              write_plane_q == plane)
            mem[write_bank_addr_q] <= write_data_q;
        end
        always_ff @(posedge clk) begin
          if (read_cmd_valid_q && read_cmd_plane_q == plane)
            bank_read_q[bank][plane] <= mem[read_cmd_addr_q[bank]];
        end
      end
    end
  endgenerate

  // Share one plane-select and one bank-select fabric across all FSM capture
  // paths.  Keeping the dynamic indexing at this single boundary prevents
  // synthesis from cloning a 64:1 data mux for each destination register.
  always_comb begin
    for (int bank = 0; bank < WORD_BANKS; bank++)
      bank_plane_data[bank] = bank_read_q[bank][capture_plane_q];
    for (int lane = 0; lane < M_GROUP; lane++)
      lane_read_data[lane] = bank_plane_data[capture_bank_q[lane]];
  end

  always_comb begin
    // A row-crossing prefetch needs one more cycle than Conv1's three input
    // channel beats after the registered-command cut.  Hold only the final
    // beat for that one cycle so the completed second-row data can be swapped
    // in directly; this avoids abandoning the prefetch and re-reading it.
    emit_wait_for_prefetch = channel_count_q >= 3 &&
                             !last_spatial_position &&
                             emit_ic_q == channel_count_q - 1'b1 &&
                             !prefetch_valid_q &&
                             !prefetch_complete_now;
    m_valid = state_q == ST_EMIT && !emit_wait_for_prefetch;
    for (int row = 0; row < 8; row++) begin
      m_act_lo[row] = $signed(pixel_q[2*row][emit_ic_q*8 +: 8]);
      m_act_hi[row] = $signed(pixel_q[2*row+1][emit_ic_q*8 +: 8]);
      m_lane_mask[row] = {group_count_q > 2*row + 1,
                          group_count_q > 2*row};
    end
    m_tile_clear = emit_k_q == 0;
    m_reduce_last = last_spatial_position &&
                    emit_ic_q == channel_count_q - 1'b1;
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
      write_valid_q <= 1'b0;
      write_bank_q <= '0;
      write_plane_q <= '0;
      write_bank_addr_q <= '0;
      write_data_q <= '0;
      group_y_q <= '0;
      group_x_q <= '0;
      group_count_q <= '0;
      planned_endpoint_y_q <= '0;
      planned_endpoint_x_q <= '0;
      endpoint_group_y_q <= '0;
      endpoint_group_x_q <= '0;
      next_group_y_q <= '0;
      next_group_x_q <= '0;
      next_group_is_last_q <= 1'b0;
      emit_ky_q <= '0;
      emit_kx_q <= '0;
      emit_ic_q <= '0;
      emit_k_q <= '0;
      prefetch_phase_q <= '0;
      prefetch_valid_q <= 1'b0;
      read_cmd_valid_q <= 1'b0;
      read_cmd_plane_q <= '0;
      frame_done <= 1'b0;
      first_row_ring_base_q <= '0;
      second_row_ring_base_q <= '0;
      for (int lane = 0; lane < M_GROUP; lane++) begin
        lane_x_base_q[lane] <= '0;
        lane_second_row_q[lane] <= 1'b0;
        capture_bank_q[lane] <= '0;
        read_cmd_bank_q[lane] <= '0;
      end
      for (int bank = 0; bank < WORD_BANKS; bank++)
        read_cmd_addr_q[bank] <= '0;
      capture_plane_q <= '0;
      group_crosses_row_q <= 1'b0;
    end else begin
      frame_done <= 1'b0;
      // Register the raster write transaction before the 64 BRAM enables and
      // data inputs.  This keeps scan/credit control off the high-fanout RAM
      // write path while preserving one accepted raster word per cycle.
      write_valid_q <= scan_step;
      // Register one read command before the BRAM address pins.  The address
      // calculation is shared by the four planes, so this boundary has only
      // sixteen address registers; each registered address then fans out to
      // the four RAMB36E2 planes in its bank.
      read_cmd_valid_q <= memory_read_issue;
      if (memory_read_issue) begin
        read_cmd_plane_q <= read_plane;
        for (int bank = 0; bank < WORD_BANKS; bank++)
          read_cmd_addr_q[bank] <= bank_read_addr[bank];
        for (int lane = 0; lane < M_GROUP; lane++)
          read_cmd_bank_q[lane] <= read_bank_for_lane[lane];
      end
      if (scan_step) begin
        write_bank_q <= write_bank;
        write_plane_q <= write_plane;
        write_bank_addr_q <= write_bank_addr;
        write_data_q <= scan_values_masked;
      end

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
        frame_tag_q <= frame_tag;
        scan_y_q <= '0;
        scan_x_q <= '0;
        write_ring_row_q <= '0;
        scan_complete_q <= 1'b0;
        group_y_q <= '0;
        group_x_q <= '0;
        group_count_q <= '0;
        emit_ky_q <= '0;
        emit_kx_q <= '0;
        emit_ic_q <= '0;
        emit_k_q <= '0;
        prefetch_phase_q <= '0;
        prefetch_valid_q <= 1'b0;
      end

      if (scan_step) begin
        if (last_scan_position)
          scan_complete_q <= 1'b1;
        else if (scan_x_q == padded_w_q - 1'b1) begin
          scan_x_q <= '0;
          scan_y_q <= scan_y_q + 1'b1;
          if (write_ring_row_q == MAX_RING_ROWS - 1)
            write_ring_row_q <= '0;
          else
            write_ring_row_q <= write_ring_row_q + 1'b1;
        end else begin
          scan_x_q <= scan_x_q + 1'b1;
        end
      end

      // These selectors advance when the registered command reaches the
      // synchronous BRAM read port, keeping them aligned with bank_read_q.
      if (read_cmd_valid_q) begin
        for (int lane = 0; lane < M_GROUP; lane++) begin
          capture_bank_q[lane] <= read_cmd_bank_q[lane];
        end
        capture_plane_q <= read_cmd_plane_q;
      end

      if (prefetch_first_issue)
        prefetch_phase_q <= 1;
      else if (prefetch_phase_q == 1) begin
        // The first registered command is reaching the BRAM this cycle.  A
        // row-crossing group also queues its second command back-to-back.
        prefetch_phase_q <= 2;
      end else if (prefetch_phase_q == 2) begin
        for (int lane = 0; lane < M_GROUP; lane++) begin
          if (lane < group_count_q && !lane_second_row_q[lane])
            prefetch_pixel_q[lane] <= lane_read_data[lane];
          else if (lane >= group_count_q)
            prefetch_pixel_q[lane] <= '0;
        end
        if (group_crosses_row_q)
          prefetch_phase_q <= 3;
        else begin
          prefetch_phase_q <= 0;
          prefetch_valid_q <= 1'b1;
        end
      end else if (prefetch_phase_q == 3) begin
        for (int lane = 0; lane < M_GROUP; lane++) begin
          if (lane < group_count_q && lane_second_row_q[lane])
            prefetch_pixel_q[lane] <= lane_read_data[lane];
        end
        prefetch_phase_q <= 0;
        prefetch_valid_q <= 1'b1;
      end

      case (state_q)
        ST_PLAN: begin
          group_count_q <= planned_group_count;
          endpoint_group_y_q <= endpoint_group_y;
          endpoint_group_x_q <= endpoint_group_x;
          next_group_y_q <= planned_next_group_y[DIM_W-1:0];
          next_group_x_q <= planned_next_group_x;
          next_group_is_last_q <= planned_group_is_last;
          state_q <= ST_PLAN_ENDPOINT;
        end

        ST_PLAN_ENDPOINT: begin
          planned_endpoint_y_q <= planned_endpoint_y;
          planned_endpoint_x_q <= planned_endpoint_x;
          state_q <= ST_WAIT_DATA;
        end

        ST_WAIT_DATA: if (group_data_available) begin
          // Register both possible row bases at the planning boundary.  The
          // BRAM address path then selects between two short registered
          // values instead of indexing a 16-entry array with output_w.
          first_row_ring_base_q <= plan_ring_row[0];
          second_row_ring_base_q <= plan_ring_row[M_GROUP-1];
          for (int lane = 0; lane < M_GROUP; lane++) begin
            lane_second_row_q[lane] <= plan_output_y[lane] != group_y_q;
            if (lane < group_count_q)
              lane_x_base_q[lane] <= plan_output_x[lane] * stride_q;
            else
              lane_x_base_q[lane] <= '0;
          end
          group_crosses_row_q <= endpoint_group_y_q != group_y_q;
          emit_ky_q <= '0;
          emit_kx_q <= '0;
          emit_ic_q <= '0;
          emit_k_q <= '0;
          prefetch_phase_q <= '0;
          prefetch_valid_q <= 1'b0;
          state_q <= ST_READ_ISSUE;
        end

        ST_READ_ISSUE:
          state_q <= group_crosses_row_q ? ST_READ_SECOND : ST_READ_WAIT;

        ST_READ_WAIT:
          state_q <= ST_READ_CAPTURE;

        ST_READ_SECOND:
          state_q <= ST_READ_SECOND_WAIT;

        ST_READ_SECOND_WAIT: begin
          for (int lane = 0; lane < M_GROUP; lane++) begin
            if (lane < group_count_q && !lane_second_row_q[lane])
              pixel_q[lane] <= lane_read_data[lane];
          end
          state_q <= ST_READ_CAPTURE;
        end

        ST_READ_CAPTURE: begin
          for (int lane = 0; lane < M_GROUP; lane++) begin
            if (lane < group_count_q) begin
              if (!group_crosses_row_q || lane_second_row_q[lane])
                pixel_q[lane] <= lane_read_data[lane];
            end else begin
              pixel_q[lane] <= '0;
            end
          end
          state_q <= ST_EMIT;
        end

        ST_EMIT: if (m_ready && m_valid) begin
          if (m_reduce_last) begin
            emit_ky_q <= '0;
            emit_kx_q <= '0;
            emit_ic_q <= '0;
            emit_k_q <= '0;
            prefetch_phase_q <= '0;
            prefetch_valid_q <= 1'b0;
            if (next_group_is_last_q) begin
              if (scan_complete_q || scan_finishing) begin
                state_q <= ST_IDLE;
                frame_done <= 1'b1;
              end else begin
                state_q <= ST_DRAIN_SCAN;
              end
            end else begin
              group_y_q <= next_group_y_q;
              group_x_q <= next_group_x_q;
              state_q <= ST_PLAN;
            end
          end else if (emit_ic_q == channel_count_q - 1'b1) begin
            emit_ic_q <= '0;
            emit_k_q <= emit_k_q + 1'b1;
            emit_ky_q <= next_read_ky;
            emit_kx_q <= next_read_kx;
            if (prefetch_valid_q) begin
              for (int lane = 0; lane < M_GROUP; lane++)
                pixel_q[lane] <= prefetch_pixel_q[lane];
              prefetch_valid_q <= 1'b0;
            end else if (prefetch_complete_now) begin
              for (int lane = 0; lane < M_GROUP; lane++) begin
                if (group_crosses_row_q && !lane_second_row_q[lane])
                  pixel_q[lane] <= prefetch_pixel_q[lane];
                else
                  pixel_q[lane] <= lane_read_data[lane];
              end
              prefetch_phase_q <= '0;
              prefetch_valid_q <= 1'b0;
            end else begin
              state_q <= ST_READ_ISSUE;
            end
          end else begin
            emit_ic_q <= emit_ic_q + 1'b1;
            emit_k_q <= emit_k_q + 1'b1;
          end
        end

        ST_DRAIN_SCAN: if (scan_complete_q || scan_finishing) begin
          state_q <= ST_IDLE;
          frame_done <= 1'b1;
        end

        default: ;
      endcase
    end
  end

`ifndef SYNTHESIS
  initial begin
    if (MAX_RING_ROWS != 15 || S1_WORDS_PER_ROW * MAX_RING_ROWS > BANK_DEPTH ||
        S4_WORDS_PER_ROW * MAX_RING_ROWS > BANK_DEPTH)
      $fatal(1, "M16 x-mod-4 feeder memory geometry is invalid");
  end

  always_ff @(posedge clk) begin
    if (!rst) begin
      if (frame_fire &&
          (frame_input_h == 0 || frame_input_w == 0 ||
           frame_channel_count < 1 || frame_channel_count > 8 ||
           frame_kernel < 1 || frame_kernel > MAX_KERNEL ||
           (frame_stride != 1 && frame_stride != 4) ||
           frame_padding > MAX_PADDING ||
           frame_lane_mask != expected_lane_mask))
        $fatal(1, "M16 x-mod-4 feeder frame descriptor is invalid");
      if (m_valid && m_k !=
          ((emit_ky_q * kernel_q + emit_kx_q) * channel_count_q + emit_ic_q))
        $fatal(1, "M16 x-mod-4 feeder K order mismatch");
    end
  end
`endif

endmodule
