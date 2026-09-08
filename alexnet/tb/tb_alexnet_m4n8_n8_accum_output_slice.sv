`timescale 1ns/1ps

module tb_alexnet_m4n8_n8_accum_output_slice;

  localparam int SLICE_INDEX = 1;
  localparam int FIFO_DEPTH = 64;
  localparam int BANK_DEPTH = 512;
  localparam int BANK_COUNT_W = $clog2(BANK_DEPTH + 1);
  localparam int MAX_EXPECTED = 1024;

  import "DPI-C" function int alexnet_golden_requantize(
      input int accumulator, input int bias, input int multiplier,
      input byte right_shift, input byte relu, output byte result);
  import "DPI-C" function int alexnet_golden_partial_sum_bank_reset(
      input int depth);
  import "DPI-C" function int alexnet_golden_partial_sum_bank_begin_chunk(
      input int word_count, input byte n_lane_mask, input int context_tag,
      input int chunk_index, input byte first_chunk, input byte final_chunk);
  import "DPI-C" function int alexnet_golden_partial_sum_bank_write(
      input int index,
      input int accumulator0, input int accumulator1,
      input int accumulator2, input int accumulator3,
      input int accumulator4, input int accumulator5,
      input int accumulator6, input int accumulator7,
      input byte n_lane_mask, input byte last);
  import "DPI-C" function int alexnet_golden_partial_sum_bank_word(
      input int index,
      output int accumulator0, output int accumulator1,
      output int accumulator2, output int accumulator3,
      output int accumulator4, output int accumulator5,
      output int accumulator6, output int accumulator7,
      output byte n_lane_mask, output byte last, output int context_tag);
  import "DPI-C" function int alexnet_golden_partial_sum_bank_complete_emit();

  logic clk = 1'b0;
  logic rst;

  logic cfg_valid;
  logic cfg_ready;
  logic [1:0] cfg_destination;
  logic [15:0] cfg_n64_tile_base;
  logic [7:0] cfg_lane_mask;
  logic signed [31:0] cfg_bias [0:7];
  logic signed [17:0] cfg_multiplier [0:7];
  logic [5:0] cfg_right_shift [0:7];
  logic [7:0] cfg_relu;

  logic chunk_valid;
  logic chunk_ready;
  logic [BANK_COUNT_W-1:0] chunk_word_count;
  logic [7:0] chunk_output_width;
  logic [7:0] chunk_n_lane_mask;
  logic [15:0] chunk_context_tag;
  logic [15:0] chunk_tile_tag_base;
  logic [7:0] chunk_index;
  logic chunk_first;
  logic chunk_final;

  logic tile_valid;
  logic tile_ready;
  logic [2:0] tile_m_count;
  logic [7:0] tile_n_lane_mask;
  logic [15:0] tile_tag;

  logic hold_valid [0:1][0:7];
  logic hold_ready [0:1][0:7];
  logic signed [31:0] hold_lo [0:1][0:7];
  logic signed [31:0] hold_hi [0:1][0:7];
  logic [1:0] hold_m_lane_mask [0:1][0:7];

  logic egress_valid;
  logic egress_ready;
  logic [63:0] egress_values;
  logic [7:0] egress_lane_mask;
  logic [1:0] egress_destination;
  logic [2:0] egress_slice;
  logic [4:0] egress_m;
  logic [15:0] egress_n_base;
  logic [15:0] egress_tile_tag;

  logic configured;
  logic slice_idle;
  logic transaction_active;
  logic chunk_active;
  logic tile_scan_done;
  logic chunk_done;
  logic transaction_done;
  logic [2:0] accum_bank_state;
  logic accum_context_error;
  logic protocol_error;
  logic [$clog2(FIFO_DEPTH+1)-1:0] queued_count;

  logic [63:0] expected_values [0:MAX_EXPECTED-1];
  logic [7:0] expected_mask [0:MAX_EXPECTED-1];
  logic [1:0] expected_destination [0:MAX_EXPECTED-1];
  logic [2:0] expected_slice [0:MAX_EXPECTED-1];
  logic [4:0] expected_m [0:MAX_EXPECTED-1];
  logic [15:0] expected_n_base [0:MAX_EXPECTED-1];
  logic [15:0] expected_tag [0:MAX_EXPECTED-1];

  int expected_write;
  int expected_read;
  int configurations;
  int transactions;
  int submitted_chunks;
  int completed_chunks;
  int submitted_tiles;
  int scanned_tiles;
  int total_accumulator_words;
  int rejected_descriptors;
  int max_queued;
  int forced_output_block;
  logic force_output_ready;

  logic stalled_q;
  logic [63:0] stalled_values_q;
  logic [7:0] stalled_mask_q;
  logic [1:0] stalled_destination_q;
  logic [2:0] stalled_slice_q;
  logic [4:0] stalled_m_q;
  logic [15:0] stalled_n_base_q;
  logic [15:0] stalled_tag_q;

  alexnet_m4n8_n8_accum_output_slice #(
      .SLICE_INDEX(SLICE_INDEX),
      .FIFO_DEPTH(FIFO_DEPTH),
      .BANK_DEPTH(BANK_DEPTH)
  ) dut (.cfg_slice_index(3'bxxx), .*);

  always #2.5 clk = ~clk;

  function automatic int signed make_accumulator(
      input int transaction_index,
      input int chunk_number,
      input int word_index,
      input int lane);
    int signed mixed;
    begin
      mixed = transaction_index * 1777 + chunk_number * 919 +
              word_index * 131 + lane * 43;
      make_accumulator = (mixed % 200001) - 100000;
    end
  endfunction

  always_ff @(posedge clk) begin
    if (rst) begin
      for (int row = 0; row < 2; row++)
        for (int lane = 0; lane < 8; lane++)
          hold_valid[row][lane] <= 1'b0;
    end else begin
      for (int row = 0; row < 2; row++)
        for (int lane = 0; lane < 8; lane++)
          if (hold_valid[row][lane] && hold_ready[row][lane])
            hold_valid[row][lane] <= 1'b0;
    end
  end

  always @(negedge clk) begin
    if (rst)
      egress_ready <= 1'b0;
    else if (force_output_ready)
      egress_ready <= 1'b1;
    else if (forced_output_block > 0) begin
      egress_ready <= 1'b0;
      forced_output_block = forced_output_block - 1;
    end else
      egress_ready <= $urandom_range(0, 4) != 0;
  end

  always @(posedge clk) begin : scoreboard
    if (rst) begin
      expected_write = 0;
      expected_read = 0;
      configurations = 0;
      transactions = 0;
      submitted_chunks = 0;
      completed_chunks = 0;
      submitted_tiles = 0;
      scanned_tiles = 0;
      total_accumulator_words = 0;
      rejected_descriptors = 0;
      max_queued = 0;
      stalled_q <= 1'b0;
      stalled_values_q <= '0;
      stalled_mask_q <= '0;
      stalled_destination_q <= '0;
      stalled_slice_q <= '0;
      stalled_m_q <= '0;
      stalled_n_base_q <= '0;
      stalled_tag_q <= '0;
    end else begin
      if (cfg_valid && cfg_ready)
        configurations = configurations + 1;
      if (chunk_valid && chunk_ready)
        submitted_chunks = submitted_chunks + 1;
      if (chunk_done)
        completed_chunks = completed_chunks + 1;
      if (tile_valid && tile_ready)
        submitted_tiles = submitted_tiles + 1;
      if (tile_scan_done)
        scanned_tiles = scanned_tiles + 1;
      if (queued_count > max_queued)
        max_queued = queued_count;

      if (stalled_q) begin
        if (!egress_valid || egress_values !== stalled_values_q ||
            egress_lane_mask !== stalled_mask_q ||
            egress_destination !== stalled_destination_q ||
            egress_slice !== stalled_slice_q || egress_m !== stalled_m_q ||
            egress_n_base !== stalled_n_base_q ||
            egress_tile_tag !== stalled_tag_q)
          $fatal(1, "accum output packet changed while stalled");
      end

      stalled_q <= egress_valid && !egress_ready;
      if (egress_valid && !egress_ready) begin
        stalled_values_q <= egress_values;
        stalled_mask_q <= egress_lane_mask;
        stalled_destination_q <= egress_destination;
        stalled_slice_q <= egress_slice;
        stalled_m_q <= egress_m;
        stalled_n_base_q <= egress_n_base;
        stalled_tag_q <= egress_tile_tag;
      end

      if (egress_valid && egress_ready) begin
        if (expected_read >= expected_write)
          $fatal(1, "accum output slice produced an unexpected packet");
        if (egress_values !== expected_values[expected_read] ||
            egress_lane_mask !== expected_mask[expected_read] ||
            egress_destination !== expected_destination[expected_read] ||
            egress_slice !== expected_slice[expected_read] ||
            egress_m !== expected_m[expected_read] ||
            egress_n_base !== expected_n_base[expected_read] ||
            egress_tile_tag !== expected_tag[expected_read])
          $fatal(1,
                 "accum packet mismatch index=%0d values=%016x/%016x mask=%02x/%02x dest=%0d/%0d slice=%0d/%0d m=%0d/%0d n=%0d/%0d tag=%0d/%0d",
                 expected_read, egress_values, expected_values[expected_read],
                 egress_lane_mask, expected_mask[expected_read],
                 egress_destination, expected_destination[expected_read],
                 egress_slice, expected_slice[expected_read], egress_m,
                 expected_m[expected_read], egress_n_base,
                 expected_n_base[expected_read], egress_tile_tag,
                 expected_tag[expected_read]);
        expected_read = expected_read + 1;
      end
    end
  end

  task automatic clear_chunk_descriptor;
    begin
      chunk_valid = 1'b0;
      chunk_word_count = '0;
      chunk_output_width = '0;
      chunk_n_lane_mask = '0;
      chunk_context_tag = '0;
      chunk_tile_tag_base = '0;
      chunk_index = '0;
      chunk_first = 1'b0;
      chunk_final = 1'b0;
    end
  endtask

  task automatic configure_slice(
      input logic [7:0] lane_mask,
      input int phase);
    logic accepted;
    begin
      cfg_destination = phase % 3;
      cfg_n64_tile_base = phase * 64;
      cfg_lane_mask = lane_mask;
      for (int lane = 0; lane < 8; lane++) begin
        cfg_bias[lane] = (lane - 4) * (phase + 1) * 257;
        cfg_multiplier[lane] = 65540 + lane * 7000 + phase * 1000;
        cfg_right_shift[lane] = 23 + ((lane + phase) % 10);
        cfg_relu[lane] = ((lane + phase) % 3) == 0;
      end

      cfg_valid = 1'b1;
      accepted = 1'b0;
      while (!accepted) begin
        @(posedge clk);
        accepted = cfg_ready;
      end
      @(negedge clk);
      cfg_valid = 1'b0;
    end
  endtask

  task automatic reject_continuation_descriptor(
      input int word_count,
      input int output_width,
      input logic [7:0] lane_mask,
      input int context_tag,
      input int tile_tag_base,
      input int chunk_number,
      input logic final_chunk,
      input logic wrong_slice_context);
    begin
      chunk_valid = 1'b1;
      chunk_word_count = word_count;
      chunk_output_width = output_width;
      chunk_n_lane_mask = lane_mask;
      chunk_context_tag = wrong_slice_context ? context_tag : context_tag + 1;
      chunk_tile_tag_base = wrong_slice_context ? tile_tag_base + 1
                                                : tile_tag_base;
      chunk_index = chunk_number;
      chunk_first = 1'b0;
      chunk_final = final_chunk;
      #1;
      if (chunk_ready)
        $fatal(1, "accum output slice accepted mismatched continuation");
      @(posedge clk);
      @(negedge clk);
      clear_chunk_descriptor();
      rejected_descriptors = rejected_descriptors + 1;
    end
  endtask

  task automatic start_chunk(
      input int word_count,
      input int output_width,
      input logic [7:0] lane_mask,
      input int context_tag,
      input int tile_tag_base,
      input int chunk_number,
      input int chunk_count);
    logic accepted;
    int status;
    begin
      if (chunk_number != 0) begin
        reject_continuation_descriptor(
            word_count, output_width, lane_mask, context_tag, tile_tag_base,
            chunk_number, chunk_number == chunk_count - 1, 1'b1);
        reject_continuation_descriptor(
            word_count, output_width, lane_mask, context_tag, tile_tag_base,
            chunk_number, chunk_number == chunk_count - 1, 1'b0);
        if (!accum_context_error)
          $fatal(1, "accum output slice did not latch context error");
      end

      chunk_valid = 1'b1;
      chunk_word_count = word_count;
      chunk_output_width = output_width;
      chunk_n_lane_mask = lane_mask;
      chunk_context_tag = context_tag;
      chunk_tile_tag_base = tile_tag_base;
      chunk_index = chunk_number;
      chunk_first = chunk_number == 0;
      chunk_final = chunk_number == chunk_count - 1;
      accepted = 1'b0;
      while (!accepted) begin
        @(posedge clk);
        accepted = chunk_ready;
      end
      status = alexnet_golden_partial_sum_bank_begin_chunk(
          word_count, lane_mask, context_tag, chunk_number,
          chunk_number == 0, chunk_number == chunk_count - 1);
      if (status != 0)
        $fatal(1, "C++ accum begin_chunk failed status=%0d", status);
      @(negedge clk);
      clear_chunk_descriptor();
      if (!chunk_active)
        $fatal(1, "accum output slice did not activate accepted chunk");
    end
  endtask

  task automatic run_tile(
      input int transaction_index,
      input int chunk_number,
      input int word_count,
      input int word_base,
      input int m_count,
      input logic [7:0] lane_mask,
      input int tag_value);
    logic [1:0] row_mask [0:1];
    logic accepted;
    int status;
    begin
      row_mask[0] = (m_count == 1) ? 2'b01 : 2'b11;
      if (m_count <= 2)
        row_mask[1] = 2'b00;
      else
        row_mask[1] = (m_count == 3) ? 2'b01 : 2'b11;

      while (!tile_ready)
        @(negedge clk);

      for (int row = 0; row < 2; row++) begin
        for (int lane = 0; lane < 8; lane++) begin
          hold_valid[row][lane] = 1'b0;
          hold_m_lane_mask[row][lane] = row_mask[row];
          hold_lo[row][lane] = make_accumulator(
              transaction_index, chunk_number, word_base + 2*row, lane);
          hold_hi[row][lane] = make_accumulator(
              transaction_index, chunk_number, word_base + 2*row + 1, lane);
        end
      end

      tile_m_count = m_count;
      tile_n_lane_mask = lane_mask;
      tile_tag = tag_value;
      tile_valid = 1'b1;
      accepted = 1'b0;
      while (!accepted) begin
        @(posedge clk);
        accepted = tile_ready;
      end
      @(negedge clk);
      tile_valid = 1'b0;

      for (int row = 0; row < 2; row++) begin
        if (row_mask[row] != 0) begin
          for (int lane = 0; lane < 8; lane++)
            hold_valid[row][lane] = 1'b1;
        end
      end

      while (!tile_scan_done)
        @(negedge clk);
      @(negedge clk);

      for (int m = 0; m < m_count; m++) begin
        status = alexnet_golden_partial_sum_bank_write(
            word_base + m,
            make_accumulator(transaction_index, chunk_number,
                             word_base + m, 0),
            make_accumulator(transaction_index, chunk_number,
                             word_base + m, 1),
            make_accumulator(transaction_index, chunk_number,
                             word_base + m, 2),
            make_accumulator(transaction_index, chunk_number,
                             word_base + m, 3),
            make_accumulator(transaction_index, chunk_number,
                             word_base + m, 4),
            make_accumulator(transaction_index, chunk_number,
                             word_base + m, 5),
            make_accumulator(transaction_index, chunk_number,
                             word_base + m, 6),
            make_accumulator(transaction_index, chunk_number,
                             word_base + m, 7),
            lane_mask, word_base + m == word_count - 1);
        if (status != 0)
          $fatal(1,
                 "C++ accum write failed chunk=%0d word=%0d status=%0d",
                 chunk_number, word_base + m, status);
        total_accumulator_words = total_accumulator_words + 1;
      end

      for (int row = 0; row < 2; row++)
        for (int lane = 0; lane < 8; lane++)
          if (hold_valid[row][lane])
            $fatal(1, "accum scanner failed to release holding [%0d][%0d]",
                   row, lane);
    end
  endtask

  task automatic run_chunk_raster(
      input int transaction_index,
      input int chunk_number,
      input int output_h,
      input int output_w,
      input logic [7:0] lane_mask,
      input int tile_tag_base);
    int word_base;
    int m_count;
    int tile_index_local;
    int timeout;
    begin
      tile_index_local = 0;
      for (int y = 0; y < output_h; y++) begin
        for (int x = 0; x < output_w; x += 4) begin
          word_base = y * output_w + x;
          m_count = (output_w - x >= 4) ? 4 : output_w - x;
          run_tile(transaction_index, chunk_number, output_h * output_w,
                   word_base,
                   m_count, lane_mask, tile_tag_base + tile_index_local);
          tile_index_local = tile_index_local + 1;
        end
      end

      timeout = 0;
      while (chunk_active && timeout < 100) begin
        @(negedge clk);
        timeout = timeout + 1;
      end
      if (timeout == 100)
        $fatal(1, "accum output chunk did not retire");
    end
  endtask

  task automatic enqueue_expected_transaction(
      input int word_count,
      input int output_width,
      input logic [7:0] lane_mask,
      input int context_tag,
      input int tile_tag_base);
    int golden_accumulator [0:7];
    byte golden_mask;
    byte golden_last;
    int golden_context;
    byte golden_result;
    longint unsigned packed_values;
    int x;
    int tile_index_local;
    int status;
    begin
      x = 0;
      tile_index_local = 0;
      for (int word = 0; word < word_count; word++) begin
        status = alexnet_golden_partial_sum_bank_word(
            word,
            golden_accumulator[0], golden_accumulator[1],
            golden_accumulator[2], golden_accumulator[3],
            golden_accumulator[4], golden_accumulator[5],
            golden_accumulator[6], golden_accumulator[7],
            golden_mask, golden_last, golden_context);
        if (status != 0 || golden_mask != lane_mask ||
            golden_context != context_tag ||
            golden_last[0] != (word == word_count - 1))
          $fatal(1, "C++ accum final metadata mismatch word=%0d status=%0d",
                 word, status);

        if (expected_write >= MAX_EXPECTED)
          $fatal(1, "accum output scoreboard overflow");
        packed_values = '0;
        for (int lane = 0; lane < 8; lane++) begin
          if (lane_mask[lane]) begin
            status = alexnet_golden_requantize(
                golden_accumulator[lane], cfg_bias[lane],
                cfg_multiplier[lane], cfg_right_shift[lane],
                cfg_relu[lane], golden_result);
            if (status != 0)
              $fatal(1, "C++ accum requant failed word=%0d lane=%0d",
                     word, lane);
            packed_values[lane*8 +: 8] = golden_result;
          end
        end

        expected_values[expected_write] = packed_values;
        expected_mask[expected_write] = lane_mask;
        expected_destination[expected_write] = cfg_destination;
        expected_slice[expected_write] = SLICE_INDEX;
        expected_m[expected_write] = x[1:0];
        expected_n_base[expected_write] =
            cfg_n64_tile_base + SLICE_INDEX * 8;
        expected_tag[expected_write] = tile_tag_base + tile_index_local;
        expected_write = expected_write + 1;

        if ((x + 1 == output_width) || (x[1:0] == 2'b11))
          tile_index_local = tile_index_local + 1;
        if (x + 1 == output_width)
          x = 0;
        else
          x = x + 1;
      end
    end
  endtask

  task automatic run_transaction(
      input int transaction_index,
      input int output_h,
      input int output_w,
      input int chunk_count,
      input logic [7:0] lane_mask,
      input int context_tag,
      input int tile_tag_base,
      input int config_phase,
      input int output_block_cycles);
    int word_count;
    int status;
    int timeout;
    logic emit_done_seen;
    begin
      word_count = output_h * output_w;
      configure_slice(lane_mask, config_phase);

      for (int chunk_number = 0;
           chunk_number < chunk_count; chunk_number++) begin
        start_chunk(word_count, output_w, lane_mask, context_tag,
                    tile_tag_base, chunk_number, chunk_count);
        run_chunk_raster(transaction_index, chunk_number, output_h, output_w,
                         lane_mask, tile_tag_base);
        if (chunk_number != chunk_count - 1 && egress_valid)
          $fatal(1, "non-final accumulation chunk reached router output");
      end

      enqueue_expected_transaction(word_count, output_w, lane_mask,
                                   context_tag, tile_tag_base);
      forced_output_block = output_block_cycles;
      emit_done_seen = transaction_done;
      timeout = 0;
      while (!emit_done_seen && timeout < word_count * 20 + 500) begin
        @(negedge clk);
        if (transaction_done)
          emit_done_seen = 1'b1;
        timeout = timeout + 1;
      end
      if (!emit_done_seen)
        $fatal(1, "accum output transaction emit timeout");

      status = alexnet_golden_partial_sum_bank_complete_emit();
      if (status != 0)
        $fatal(1, "C++ accum complete_emit failed status=%0d", status);

      force_output_ready = 1'b1;
      timeout = 0;
      while ((!slice_idle || expected_read != expected_write) &&
             timeout < word_count * 30 + 1000) begin
        @(negedge clk);
        timeout = timeout + 1;
      end
      force_output_ready = 1'b0;
      if (timeout == word_count * 30 + 1000)
        $fatal(1, "accum output slice drain timeout");
      transactions = transactions + 1;
    end
  endtask

  initial begin
    int seed;
    int seed_sink;
    int status;
    seed = 32'h74b2_31e5;
    seed_sink = $urandom(seed);

    rst = 1'b1;
    cfg_valid = 1'b0;
    cfg_destination = '0;
    cfg_n64_tile_base = '0;
    cfg_lane_mask = 8'hff;
    cfg_relu = '0;
    clear_chunk_descriptor();
    tile_valid = 1'b0;
    tile_m_count = 1;
    tile_n_lane_mask = 8'hff;
    tile_tag = '0;
    egress_ready = 1'b0;
    force_output_ready = 1'b0;
    forced_output_block = 0;
    for (int lane = 0; lane < 8; lane++) begin
      cfg_bias[lane] = '0;
      cfg_multiplier[lane] = 18'sd65540;
      cfg_right_shift[lane] = 6'd23;
      for (int row = 0; row < 2; row++) begin
        hold_valid[row][lane] = 1'b0;
        hold_lo[row][lane] = '0;
        hold_hi[row][lane] = '0;
        hold_m_lane_mask[row][lane] = '0;
      end
    end

    status = alexnet_golden_partial_sum_bank_reset(BANK_DEPTH);
    if (status != 0)
      $fatal(1, "C++ accum bank reset failed status=%0d", status);

    repeat (5) @(negedge clk);
    rst = 1'b0;
    @(negedge clk);

    if (configured || tile_ready || chunk_active || transaction_active)
      $fatal(1, "unconfigured accum output slice exposed ownership");

    run_transaction(0, 3, 5, 3, 8'h0f, 16'h0701, 16'h1000, 0, 40);
    run_transaction(1, 13, 13, 48, 8'hff, 16'h0702, 16'h2000, 1, 150);
    run_transaction(2, 2, 6, 1, 8'h01, 16'h0703, 16'h3000, 2, 20);

    if (configurations != 3 || transactions != 3 ||
        submitted_chunks != 52 || completed_chunks != submitted_chunks ||
        submitted_tiles != 2518 || scanned_tiles != submitted_tiles ||
        total_accumulator_words != 8169 || expected_write != 196 ||
        expected_read != expected_write || max_queued != FIFO_DEPTH ||
        rejected_descriptors != 98 || protocol_error)
      $fatal(1,
             "accum output summary mismatch cfg=%0d tx=%0d chunks=%0d/%0d tiles=%0d/%0d words=%0d packets=%0d/%0d maxq=%0d rejects=%0d protocol=%0b",
             configurations, transactions, completed_chunks,
             submitted_chunks, scanned_tiles, submitted_tiles,
             total_accumulator_words, expected_read, expected_write,
             max_queued, rejected_descriptors, protocol_error);

    $display(
        "ALEXNET_M4N8_N8_ACCUM_OUTPUT_SLICE_TEST_PASSED transactions=%0d chunks=%0d tiles=%0d accum_words=%0d packets=%0d descriptor_rejects=%0d configs=%0d maxq=%0d seed=%0d",
        transactions, submitted_chunks, submitted_tiles,
        total_accumulator_words, expected_write, rejected_descriptors,
        configurations, max_queued, seed);
    $finish;
  end

endmodule
