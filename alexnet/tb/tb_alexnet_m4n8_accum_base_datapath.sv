`timescale 1ns/1ps

module tb_alexnet_m4n8_accum_base_datapath;

  localparam int SLICE_INDEX = 1;
  localparam int FIFO_DEPTH = 64;
  localparam int BANK_DEPTH = 512;
  localparam int BANK_COUNT_W = $clog2(BANK_DEPTH + 1);
  localparam int MAX_K = 4;
  localparam int MAX_EXPECTED = 1024;

  import "DPI-C" function int alexnet_golden_packed_products(
      input byte act_lo, input byte act_hi, input byte weight,
      output int product_lo, output int product_hi);
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
  logic ce;

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

  logic tile_start_valid;
  logic tile_start_ready;
  logic [2:0] tile_m_count;
  logic [7:0] tile_n_lane_mask;
  logic [15:0] tile_tag;

  logic issue_valid;
  logic issue_ready;
  logic issue_last;
  logic signed [7:0] issue_act_lo [0:1];
  logic signed [7:0] issue_act_hi [0:1];
  logic signed [7:0] issue_weight [0:7];

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
  logic compute_busy;
  logic transaction_active;
  logic chunk_active;
  logic tile_done;
  logic chunk_done;
  logic transaction_done;
  logic datapath_idle;
  logic [2:0] accum_bank_state;
  logic accum_context_error;
  logic protocol_error;
  logic [$clog2(FIFO_DEPTH+1)-1:0] queued_count;

  logic signed [7:0] tile_act_lo [0:MAX_K-1][0:1];
  logic signed [7:0] tile_act_hi [0:MAX_K-1][0:1];
  logic signed [7:0] tile_weight [0:MAX_K-1][0:7];
  longint signed tile_accumulator [0:3][0:7];

  logic [1:0] active_destination;
  logic [15:0] active_n64_tile_base;
  logic [7:0] active_lane_mask;
  logic signed [31:0] active_bias [0:7];
  logic signed [17:0] active_multiplier [0:7];
  logic [5:0] active_right_shift [0:7];
  logic [7:0] active_relu;

  logic [63:0] expected_values [0:MAX_EXPECTED-1];
  logic [7:0] expected_mask [0:MAX_EXPECTED-1];
  logic [1:0] expected_destination [0:MAX_EXPECTED-1];
  logic [2:0] expected_slice [0:MAX_EXPECTED-1];
  logic [4:0] expected_m [0:MAX_EXPECTED-1];
  logic [15:0] expected_n_base [0:MAX_EXPECTED-1];
  logic [15:0] expected_tag [0:MAX_EXPECTED-1];

  int expected_write;
  int expected_read;
  int configuration_count;
  int submitted_transactions;
  int completed_transactions;
  int submitted_chunks;
  int completed_chunks;
  int submitted_tiles;
  int completed_tiles;
  int accepted_k_tokens;
  int expected_k_tokens;
  int accumulated_words;
  int max_queued;
  int blocked_output_cycles;
  int tiles_while_cfg_pending;
  logic force_ready;
  logic pending_configuration_done;

  logic stalled_q;
  logic [63:0] stalled_values_q;
  logic [7:0] stalled_mask_q;
  logic [1:0] stalled_destination_q;
  logic [2:0] stalled_slice_q;
  logic [4:0] stalled_m_q;
  logic [15:0] stalled_n_base_q;
  logic [15:0] stalled_tag_q;

  alexnet_m4n8_accum_base_datapath #(
      .SLICE_INDEX(SLICE_INDEX),
      .FIFO_DEPTH(FIFO_DEPTH),
      .BANK_DEPTH(BANK_DEPTH)
  ) dut (.cfg_slice_index(3'bxxx), .*);

  always #2.5 clk = ~clk;

  function automatic logic signed [7:0] random_i8(input bit full_range);
    if (full_range)
      random_i8 = $urandom_range(0, 255) - 128;
    else
      random_i8 = $urandom_range(0, 15) - 8;
  endfunction

  always @(negedge clk) begin
    if (rst)
      egress_ready <= 1'b0;
    else if (force_ready)
      egress_ready <= 1'b1;
    else if (blocked_output_cycles > 0) begin
      egress_ready <= 1'b0;
      blocked_output_cycles = blocked_output_cycles - 1;
    end else
      egress_ready <= ($urandom_range(0, 4) != 0);
  end

  always @(posedge clk) begin : scoreboard
    if (rst) begin
      expected_write = 0;
      expected_read = 0;
      configuration_count = 0;
      submitted_transactions = 0;
      completed_transactions = 0;
      submitted_chunks = 0;
      completed_chunks = 0;
      submitted_tiles = 0;
      completed_tiles = 0;
      accepted_k_tokens = 0;
      expected_k_tokens = 0;
      accumulated_words = 0;
      max_queued = 0;
      tiles_while_cfg_pending = 0;
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
        configuration_count = configuration_count + 1;
      if (chunk_valid && chunk_ready) begin
        submitted_chunks = submitted_chunks + 1;
        if (chunk_first)
          submitted_transactions = submitted_transactions + 1;
      end
      if (chunk_done)
        completed_chunks = completed_chunks + 1;
      if (transaction_done)
        completed_transactions = completed_transactions + 1;
      if (tile_start_valid && tile_start_ready) begin
        submitted_tiles = submitted_tiles + 1;
        if (cfg_valid)
          tiles_while_cfg_pending = tiles_while_cfg_pending + 1;
      end
      if (tile_done)
        completed_tiles = completed_tiles + 1;
      if (issue_valid && issue_ready)
        accepted_k_tokens = accepted_k_tokens + 1;
      if (queued_count > max_queued)
        max_queued = queued_count;

      if (stalled_q) begin
        if (!egress_valid || egress_values !== stalled_values_q ||
            egress_lane_mask !== stalled_mask_q ||
            egress_destination !== stalled_destination_q ||
            egress_slice !== stalled_slice_q || egress_m !== stalled_m_q ||
            egress_n_base !== stalled_n_base_q ||
            egress_tile_tag !== stalled_tag_q)
          $fatal(1, "accum base datapath output changed while stalled");
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
          $fatal(1, "accum base datapath produced an unexpected packet");
        if (egress_values !== expected_values[expected_read] ||
            egress_lane_mask !== expected_mask[expected_read] ||
            egress_destination !== expected_destination[expected_read] ||
            egress_slice !== expected_slice[expected_read] ||
            egress_m !== expected_m[expected_read] ||
            egress_n_base !== expected_n_base[expected_read] ||
            egress_tile_tag !== expected_tag[expected_read])
          $fatal(1,
                 "accum base packet mismatch index=%0d values=%016x/%016x mask=%02x/%02x dest=%0d/%0d slice=%0d/%0d m=%0d/%0d n=%0d/%0d tag=%0d/%0d",
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

  task automatic configure_datapath(input int phase);
    logic accepted;
    begin
      case (phase)
        0: begin
          cfg_destination = 1;
          cfg_n64_tile_base = 64;
          cfg_lane_mask = 8'hff;
        end
        1: begin
          cfg_destination = 2;
          cfg_n64_tile_base = 960;
          cfg_lane_mask = 8'h0f;
        end
        default: begin
          cfg_destination = 0;
          cfg_n64_tile_base = 0;
          cfg_lane_mask = 8'h01;
        end
      endcase

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

      active_destination = cfg_destination;
      active_n64_tile_base = cfg_n64_tile_base;
      active_lane_mask = cfg_lane_mask;
      active_relu = cfg_relu;
      for (int lane = 0; lane < 8; lane++) begin
        active_bias[lane] = cfg_bias[lane];
        active_multiplier[lane] = cfg_multiplier[lane];
        active_right_shift[lane] = cfg_right_shift[lane];
      end

      @(negedge clk);
      cfg_valid = 1'b0;
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
    int status;
    begin
      chunk_word_count = word_count;
      chunk_output_width = output_width;
      chunk_n_lane_mask = lane_mask;
      chunk_context_tag = context_tag;
      chunk_tile_tag_base = tile_tag_base;
      chunk_index = chunk_number;
      chunk_first = chunk_number == 0;
      chunk_final = chunk_number == chunk_count - 1;

      while (!chunk_ready)
        @(negedge clk);
      chunk_valid = 1'b1;
      @(posedge clk);
      if (!chunk_ready)
        $fatal(1, "accum base chunk lost ready on handshake");

      status = alexnet_golden_partial_sum_bank_begin_chunk(
          word_count, lane_mask, context_tag, chunk_number,
          chunk_number == 0, chunk_number == chunk_count - 1);
      if (status != 0)
        $fatal(1, "C++ accum base begin_chunk failed status=%0d", status);
      @(negedge clk);
      clear_chunk_descriptor();
      if (!chunk_active)
        $fatal(1, "accum base did not activate accepted chunk");
      $display("ALEXNET_M4N8_ACCUM_BASE_CHUNK_ACCEPTED chunk=%0d/%0d state=%0d time=%0t",
               chunk_number + 1, chunk_count, accum_bank_state, $time);
    end
  endtask

  task automatic prepare_tile(
      input int transaction_number,
      input int chunk_number,
      input int word_base,
      input int depth,
      input int m_count,
      input bit full_range);
    int product_lo;
    int product_hi;
    int status;
    begin
      for (int m = 0; m < 4; m++)
        for (int lane = 0; lane < 8; lane++)
          tile_accumulator[m][lane] = 0;

      for (int k = 0; k < depth; k++) begin
        for (int row = 0; row < 2; row++) begin
          tile_act_lo[k][row] = random_i8(full_range);
          tile_act_hi[k][row] = random_i8(full_range);
        end
        for (int lane = 0; lane < 8; lane++)
          tile_weight[k][lane] = random_i8(full_range);

        if (transaction_number == 0 && chunk_number == 0 &&
            word_base == 0 && k == 0) begin
          tile_act_lo[k][0] = -128;
          tile_act_hi[k][0] = 127;
          tile_act_lo[k][1] = -127;
          tile_act_hi[k][1] = 126;
          for (int lane = 0; lane < 8; lane++)
            tile_weight[k][lane] = lane[0] ? 127 : -128;
        end

        for (int row = 0; row < 2; row++) begin
          for (int lane = 0; lane < 8; lane++) begin
            status = alexnet_golden_packed_products(
                tile_act_lo[k][row], tile_act_hi[k][row],
                tile_weight[k][lane], product_lo, product_hi);
            if (status != 0)
              $fatal(1, "C++ accum base packed product failed status=%0d",
                     status);
            tile_accumulator[2*row][lane] += product_lo;
            tile_accumulator[2*row+1][lane] += product_hi;
          end
        end
      end

      for (int m = m_count; m < 4; m++)
        for (int lane = 0; lane < 8; lane++)
          tile_accumulator[m][lane] = 0;
    end
  endtask

  task automatic run_tile(
      input int transaction_number,
      input int chunk_number,
      input int word_count,
      input int word_base,
      input int depth,
      input int m_count,
      input logic [7:0] lane_mask,
      input int tag_value,
      input bit bubbles,
      input bit ce_stalls,
      input bit full_range);
    logic accepted;
    int status;
    begin
      prepare_tile(transaction_number, chunk_number, word_base, depth,
                   m_count, full_range);

      while (!tile_start_ready)
        @(negedge clk);
      tile_m_count = m_count;
      tile_n_lane_mask = lane_mask;
      tile_tag = tag_value;
      tile_start_valid = 1'b1;
      @(posedge clk);
      if (!tile_start_ready)
        $fatal(1, "accum base tile lost ready on handshake");
      @(negedge clk);
      tile_start_valid = 1'b0;

      for (int k = 0; k < depth; k++) begin
        if (bubbles && ($urandom_range(0, 4) == 0)) begin
          issue_valid = 1'b0;
          repeat ($urandom_range(1, 2))
            @(negedge clk);
        end

        for (int row = 0; row < 2; row++) begin
          issue_act_lo[row] = tile_act_lo[k][row];
          issue_act_hi[row] = tile_act_hi[k][row];
        end
        for (int lane = 0; lane < 8; lane++)
          issue_weight[lane] = tile_weight[k][lane];
        issue_last = k == depth - 1;
        issue_valid = 1'b1;

        if (ce_stalls && ($urandom_range(0, 15) == 0)) begin
          ce = 1'b0;
          repeat ($urandom_range(1, 3))
            @(negedge clk);
          ce = 1'b1;
        end

        accepted = 1'b0;
        while (!accepted) begin
          @(posedge clk);
          accepted = issue_ready;
        end
        @(negedge clk);
        issue_valid = 1'b0;
      end
      issue_last = 1'b0;
      expected_k_tokens = expected_k_tokens + depth;

      while (!tile_done)
        @(negedge clk);
      @(negedge clk);

      for (int m = 0; m < m_count; m++) begin
        status = alexnet_golden_partial_sum_bank_write(
            word_base + m,
            tile_accumulator[m][0], tile_accumulator[m][1],
            tile_accumulator[m][2], tile_accumulator[m][3],
            tile_accumulator[m][4], tile_accumulator[m][5],
            tile_accumulator[m][6], tile_accumulator[m][7],
            lane_mask, word_base + m == word_count - 1);
        if (status != 0)
          $fatal(1,
                 "C++ accum base write failed chunk=%0d word=%0d status=%0d",
                 chunk_number, word_base + m, status);
        accumulated_words = accumulated_words + 1;
      end
    end
  endtask

  task automatic build_expected_packets(
      input int word_count,
      input int output_width,
      input int context_tag,
      input int tile_tag_base);
    int accum [0:7];
    int returned_context;
    int status;
    byte returned_mask;
    byte returned_last;
    byte golden_result;
    longint unsigned packed_values;
    int tile_index;
    begin
      for (int word = 0; word < word_count; word++) begin
        status = alexnet_golden_partial_sum_bank_word(
            word, accum[0], accum[1], accum[2], accum[3],
            accum[4], accum[5], accum[6], accum[7],
            returned_mask, returned_last, returned_context);
        if (status != 0 || returned_mask !== active_lane_mask ||
            returned_context != context_tag ||
            returned_last != (word == word_count - 1))
          $fatal(1, "C++ accum base final word mismatch word=%0d status=%0d",
                 word, status);

        if (expected_write >= MAX_EXPECTED)
          $fatal(1, "accum base scoreboard overflow");
        packed_values = '0;
        for (int lane = 0; lane < 8; lane++) begin
          if (active_lane_mask[lane]) begin
            if (accum[lane] + $signed(active_bias[lane]) < -67108864 ||
                accum[lane] + $signed(active_bias[lane]) > 67108863)
              $fatal(1,
                     "accum base vector exceeded signed-27 post-bias bound");
            status = alexnet_golden_requantize(
                accum[lane], active_bias[lane], active_multiplier[lane],
                active_right_shift[lane], active_relu[lane], golden_result);
            if (status != 0)
              $fatal(1, "C++ accum base requant failed status=%0d", status);
            packed_values[lane*8 +: 8] = golden_result;
          end
        end

        tile_index = (word / output_width) *
                     ((output_width + 3) / 4) +
                     ((word % output_width) / 4);
        expected_values[expected_write] = packed_values;
        expected_mask[expected_write] = active_lane_mask;
        expected_destination[expected_write] = active_destination;
        expected_slice[expected_write] = SLICE_INDEX;
        expected_m[expected_write] = (word % output_width) % 4;
        expected_n_base[expected_write] =
            active_n64_tile_base + SLICE_INDEX * 8;
        expected_tag[expected_write] = tile_tag_base + tile_index;
        expected_write = expected_write + 1;
      end

      status = alexnet_golden_partial_sum_bank_complete_emit();
      if (status != 0)
        $fatal(1, "C++ accum base complete_emit failed status=%0d", status);
    end
  endtask

  task automatic run_transaction(
      input int transaction_number,
      input int word_count,
      input int output_width,
      input int chunk_count,
      input logic [7:0] lane_mask,
      input int context_tag,
      input int tile_tag_base,
      input int pending_config_phase,
      input bit block_final_output);
    int status;
    int tile_index;
    int word_base;
    int m_count;
    int depth;
    begin
      status = alexnet_golden_partial_sum_bank_reset(BANK_DEPTH);
      if (status != 0)
        $fatal(1, "C++ accum base reset failed status=%0d", status);

      pending_configuration_done = pending_config_phase < 0;
      for (int chunk = 0; chunk < chunk_count; chunk++) begin
        start_chunk(word_count, output_width, lane_mask, context_tag,
                    tile_tag_base, chunk, chunk_count);

        if (chunk == 0 && pending_config_phase >= 0) begin
          fork
            begin
              configure_datapath(pending_config_phase);
              pending_configuration_done = 1'b1;
            end
          join_none
        end

        tile_index = 0;
        for (int row = 0; row < word_count / output_width; row++) begin
          for (int x = 0; x < output_width; x += 4) begin
            word_base = row * output_width + x;
            m_count = output_width - x;
            if (m_count > 4)
              m_count = 4;
            // The 48-chunk case is an accumulation/ownership stress. K-depth
            // variation is already covered by the surrounding transactions
            // and the standalone base-datapath regression, so use K=1 here
            // to keep the full 13x13 raster regression practical.
            if (transaction_number == 1)
              depth = 1;
            else
              depth = 1 + ((transaction_number + chunk + tile_index) % 3);
            run_tile(transaction_number, chunk, word_count, word_base,
                     depth, m_count, lane_mask, tile_tag_base + tile_index,
                     1'b1, 1'b1,
                     transaction_number == 0 && chunk == 0 &&
                     tile_index == 0);
            tile_index = tile_index + 1;
          end
        end

        // The final tile scan and chunk completion may share one edge. Wait
        // on the scoreboard count so a one-cycle completion pulse cannot be
        // missed after run_tile returns.
        while (completed_chunks < submitted_chunks)
          @(negedge clk);
        $display("ALEXNET_M4N8_ACCUM_BASE_PROGRESS transaction=%0d chunk=%0d/%0d tiles=%0d k_tokens=%0d time=%0t",
                 transaction_number, chunk + 1, chunk_count,
                 completed_tiles, accepted_k_tokens, $time);
        if (chunk != chunk_count - 1 && egress_valid)
          $fatal(1, "non-final accum base chunk exposed an output packet");
        if (chunk == chunk_count - 1) begin
          if (block_final_output)
            blocked_output_cycles = 700;
          build_expected_packets(word_count, output_width, context_tag,
                                 tile_tag_base);
        end
        @(negedge clk);
      end

      while (completed_transactions < submitted_transactions)
        @(negedge clk);
      while (expected_read != expected_write)
        @(negedge clk);
      while (!datapath_idle)
        @(negedge clk);
      while (!pending_configuration_done)
        @(negedge clk);
      @(negedge clk);
    end
  endtask

  initial begin
    int seed;
    int seed_sink;
    int timeout;

    rst = 1'b1;
    ce = 1'b1;
    cfg_valid = 1'b0;
    cfg_destination = '0;
    cfg_n64_tile_base = '0;
    cfg_lane_mask = 8'hff;
    cfg_relu = '0;
    clear_chunk_descriptor();
    tile_start_valid = 1'b0;
    tile_m_count = 1;
    tile_n_lane_mask = 8'hff;
    tile_tag = '0;
    issue_valid = 1'b0;
    issue_last = 1'b0;
    egress_ready = 1'b0;
    force_ready = 1'b0;
    blocked_output_cycles = 0;
    pending_configuration_done = 1'b1;
    seed = 32'h75c3_4244;
    seed_sink = $urandom(seed);

    active_destination = '0;
    active_n64_tile_base = '0;
    active_lane_mask = '0;
    active_relu = '0;
    for (int lane = 0; lane < 8; lane++) begin
      cfg_bias[lane] = '0;
      cfg_multiplier[lane] = 18'sd65540;
      cfg_right_shift[lane] = 6'd23;
      active_bias[lane] = '0;
      active_multiplier[lane] = '0;
      active_right_shift[lane] = '0;
      issue_weight[lane] = '0;
    end
    for (int row = 0; row < 2; row++) begin
      issue_act_lo[row] = '0;
      issue_act_hi[row] = '0;
    end

    repeat (5) @(negedge clk);
    rst = 1'b0;
    @(negedge clk);

    if (configured || chunk_ready || tile_start_ready || issue_ready)
      $fatal(1, "unconfigured accum base datapath exposed a ready input");

    configure_datapath(0);
    run_transaction(0, 45, 5, 3, 8'hff, 16'h1100, 16'h0100, 1, 1'b0);
    run_transaction(1, 169, 13, 48, 8'h0f, 16'h2200, 16'h2000, -1, 1'b1);
    configure_datapath(2);
    run_transaction(2, 12, 6, 1, 8'h01, 16'h3300, 16'h3000, -1, 1'b0);

    force_ready = 1'b1;
    ce = 1'b1;
    timeout = 0;
    while ((!datapath_idle || expected_read != expected_write) &&
           timeout < 200000) begin
      @(negedge clk);
      timeout = timeout + 1;
    end
    if (timeout == 200000)
      $fatal(1, "accum base datapath drain timeout");
    if (configuration_count != 3 || submitted_transactions != 3 ||
        completed_transactions != 3 || submitted_chunks != 52 ||
        completed_chunks != submitted_chunks || submitted_tiles != 2554 ||
        completed_tiles != submitted_tiles || accepted_k_tokens != 2613 ||
        accepted_k_tokens != expected_k_tokens || accumulated_words != 8259 ||
        expected_read != 226 || expected_read != expected_write ||
        max_queued != FIFO_DEPTH || tiles_while_cfg_pending == 0 ||
        protocol_error || accum_context_error)
      $fatal(1,
             "accum base final counts cfg=%0d tx=%0d/%0d chunks=%0d/%0d tiles=%0d/%0d k=%0d/%0d words=%0d packets=%0d/%0d maxq=%0d pending_tiles=%0d errors=%0b/%0b",
             configuration_count, completed_transactions,
             submitted_transactions, completed_chunks, submitted_chunks,
             completed_tiles, submitted_tiles, accepted_k_tokens,
             expected_k_tokens, accumulated_words, expected_read,
             expected_write, max_queued, tiles_while_cfg_pending,
             protocol_error, accum_context_error);

    $display("ALEXNET_M4N8_ACCUM_BASE_DATAPATH_TEST_PASSED transactions=%0d chunks=%0d tiles=%0d k_tokens=%0d accum_words=%0d packets=%0d configs=%0d maxq=%0d pending_tiles=%0d seed=%0d",
             completed_transactions, completed_chunks, completed_tiles,
             accepted_k_tokens, accumulated_words, expected_read,
             configuration_count, max_queued, tiles_while_cfg_pending, seed);
    $finish;
  end

  // A ready/valid regression should never run forever. The expected run is
  // well below this bound even with randomized CE and source stalls.
  initial begin : watchdog
    repeat (400000) @(posedge clk);
    $fatal(1,
           "accum base datapath global watchdog expired configured=%0b cfg=%0b/%0b tx=%0b chunk=%0b state=%0d tile=%0b/%0b compute=%0b issue=%0b/%0b done=%0b/%0b/%0b packets=%0d/%0d",
           configured, cfg_valid, cfg_ready, transaction_active, chunk_active,
           accum_bank_state, tile_start_valid, tile_start_ready, compute_busy,
           issue_valid, issue_ready, tile_done, chunk_done, transaction_done,
           expected_read, expected_write);
  end

endmodule
