`timescale 1ns/1ps

module tb_alexnet_n8_int32_partial_sum_bank;

  localparam int DEPTH = 512;
  localparam int ADDR_W = $clog2(DEPTH);
  localparam int COUNT_W = $clog2(DEPTH + 1);
  localparam int CHUNK_INDEX_W = 8;

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
  import "DPI-C" function int alexnet_golden_partial_sum_bank_state(
      output byte state, output int words_accepted,
      output int next_chunk_index, output int completed_chunks);

  logic clk = 1'b0;
  logic rst;

  logic descriptor_valid;
  logic descriptor_ready;
  logic [COUNT_W-1:0] descriptor_word_count;
  logic [7:0] descriptor_n_lane_mask;
  logic [15:0] descriptor_context_tag;
  logic [CHUNK_INDEX_W-1:0] descriptor_chunk_index;
  logic descriptor_first_chunk;
  logic descriptor_final_chunk;

  logic ingress_valid;
  logic ingress_ready;
  logic signed [31:0] ingress_accumulator [0:7];
  logic [7:0] ingress_n_lane_mask;
  logic [ADDR_W-1:0] ingress_word_index;
  logic ingress_last;

  logic egress_valid;
  logic egress_ready;
  logic signed [31:0] egress_accumulator [0:7];
  logic [7:0] egress_n_lane_mask;
  logic [ADDR_W-1:0] egress_word_index;
  logic egress_last;
  logic [15:0] egress_context_tag;

  logic [2:0] bank_state;
  logic resident_valid;
  logic [COUNT_W-1:0] resident_word_count;
  logic [7:0] resident_n_lane_mask;
  logic [15:0] resident_context_tag;
  logic [CHUNK_INDEX_W-1:0] next_chunk_index;
  logic [CHUNK_INDEX_W:0] completed_chunks;
  logic [COUNT_W-1:0] words_accepted;
  logic chunk_done;
  logic emit_done;
  logic context_error;
  logic protocol_error;
  logic idle;

  int transactions;
  int total_chunks;
  int total_ingress_words;
  int total_egress_words;
  int rejected_descriptors;
  int blocked_words;
  int max_output_stall;
  int stall_run;

  logic hold_active;
  logic signed [31:0] hold_accumulator [0:7];
  logic [7:0] hold_mask;
  logic [ADDR_W-1:0] hold_index;
  logic hold_last;
  logic [15:0] hold_tag;

  alexnet_n8_int32_partial_sum_bank #(
      .DEPTH(DEPTH)
  ) dut (.*);

  always #2.5 clk = ~clk;

  function automatic int signed make_accumulator(
      input int transaction_index,
      input int chunk_index,
      input int word_index,
      input int lane);
    longint signed mixed;
    begin
      mixed = transaction_index * 104729 + chunk_index * 8191 +
              word_index * 1543 + lane * 313;
      make_accumulator = (mixed % 2000001) - 1000000;
      if (transaction_index == 0 && word_index == 0 && lane == 0)
        make_accumulator = -2140000000 + chunk_index * 1000;
      if (transaction_index == 0 && word_index == 0 && lane == 1)
        make_accumulator = 2140000000 - chunk_index * 1000;
    end
  endfunction

  task automatic clear_descriptor;
    begin
      descriptor_valid = 1'b0;
      descriptor_word_count = '0;
      descriptor_n_lane_mask = '0;
      descriptor_context_tag = '0;
      descriptor_chunk_index = '0;
      descriptor_first_chunk = 1'b0;
      descriptor_final_chunk = 1'b0;
    end
  endtask

  task automatic clear_ingress;
    begin
      ingress_valid = 1'b0;
      ingress_n_lane_mask = '0;
      ingress_word_index = '0;
      ingress_last = 1'b0;
      for (int lane = 0; lane < 8; lane++)
        ingress_accumulator[lane] = '0;
    end
  endtask

  task automatic check_stable_state(input int expected_state);
    byte golden_state;
    int golden_words;
    int golden_next_chunk;
    int golden_completed;
    int status;
    begin
      status = alexnet_golden_partial_sum_bank_state(
          golden_state, golden_words, golden_next_chunk, golden_completed);
      if (status != 0 || bank_state != expected_state ||
          bank_state != golden_state[2:0] || words_accepted != golden_words ||
          next_chunk_index != golden_next_chunk ||
          completed_chunks != golden_completed)
        $fatal(1,
               "partial-sum state mismatch rtl=%0d/%0d/%0d/%0d golden=%0d/%0d/%0d/%0d expected=%0d status=%0d",
               bank_state, words_accepted, next_chunk_index,
               completed_chunks, golden_state, golden_words,
               golden_next_chunk, golden_completed, expected_state, status);
    end
  endtask

  task automatic drive_rejected_descriptor(
      input int word_count,
      input logic [7:0] lane_mask,
      input int context_tag,
      input int chunk_index,
      input logic first_chunk,
      input logic final_chunk);
    begin
      descriptor_valid = 1'b1;
      descriptor_word_count = word_count;
      descriptor_n_lane_mask = lane_mask;
      descriptor_context_tag = context_tag;
      descriptor_chunk_index = chunk_index;
      descriptor_first_chunk = first_chunk;
      descriptor_final_chunk = final_chunk;
      #1;
      if (descriptor_ready)
        $fatal(1, "partial-sum bank accepted a rejected descriptor");
      @(posedge clk);
      @(negedge clk);
      descriptor_valid = 1'b0;
      rejected_descriptors = rejected_descriptors + 1;
    end
  endtask

  task automatic start_chunk(
      input int word_count,
      input logic [7:0] lane_mask,
      input int context_tag,
      input int chunk_index,
      input logic first_chunk,
      input logic final_chunk);
    int status;
    begin
      descriptor_valid = 1'b1;
      descriptor_word_count = word_count;
      descriptor_n_lane_mask = lane_mask;
      descriptor_context_tag = context_tag;
      descriptor_chunk_index = chunk_index;
      descriptor_first_chunk = first_chunk;
      descriptor_final_chunk = final_chunk;
      #1;
      if (!descriptor_ready)
        $fatal(1, "partial-sum bank rejected correct chunk=%0d", chunk_index);
      @(posedge clk);
      status = alexnet_golden_partial_sum_bank_begin_chunk(
          word_count, lane_mask, context_tag, chunk_index,
          first_chunk, final_chunk);
      if (status != 0)
        $fatal(1, "C++ partial-sum begin_chunk failed status=%0d", status);
      @(negedge clk);
      clear_descriptor();
      if (bank_state != (first_chunk ? 1 : 3))
        $fatal(1, "partial-sum bank did not enter ingest state");
    end
  endtask

  task automatic inject_rejected_word(
      input int transaction_index,
      input int chunk_index,
      input int word_count,
      input logic [7:0] lane_mask);
    begin
      ingress_valid = 1'b1;
      ingress_n_lane_mask = lane_mask;
      ingress_word_index = (word_count == 1) ? 1 : word_count - 1;
      ingress_last = word_count == 1;
      for (int lane = 0; lane < 8; lane++)
        ingress_accumulator[lane] = make_accumulator(
            transaction_index, chunk_index, 0, lane);
      #1;
      if (ingress_ready)
        $fatal(1, "partial-sum bank accepted an out-of-order word");
      @(posedge clk);
      @(negedge clk);
      clear_ingress();
      blocked_words = blocked_words + 1;
    end
  endtask

  task automatic ingest_chunk(
      input int transaction_index,
      input int chunk_index,
      input int word_count,
      input logic [7:0] lane_mask);
    int word_index;
    int cycles;
    int status;
    logic pending_word;
    logic ingress_fire;
    logic done_seen;
    begin
      word_index = 0;
      cycles = 0;
      pending_word = 1'b0;
      done_seen = 1'b0;

      inject_rejected_word(transaction_index, chunk_index, word_count,
                           lane_mask);
      if (!protocol_error)
        $fatal(1, "partial-sum bank did not flag rejected word metadata");

      while (word_index < word_count) begin
        if (!pending_word && $urandom_range(0, 5) != 0)
          pending_word = 1'b1;
        ingress_valid = pending_word;
        ingress_n_lane_mask = lane_mask;
        ingress_word_index = word_index;
        ingress_last = word_index == word_count - 1;
        for (int lane = 0; lane < 8; lane++)
          ingress_accumulator[lane] = make_accumulator(
              transaction_index, chunk_index, word_index, lane);
        #1;
        ingress_fire = ingress_valid && ingress_ready;
        @(posedge clk);
        if (ingress_fire) begin
          status = alexnet_golden_partial_sum_bank_write(
              word_index,
              ingress_accumulator[0], ingress_accumulator[1],
              ingress_accumulator[2], ingress_accumulator[3],
              ingress_accumulator[4], ingress_accumulator[5],
              ingress_accumulator[6], ingress_accumulator[7],
              lane_mask, ingress_last);
          if (status != 0)
            $fatal(1,
                   "C++ partial-sum write failed chunk=%0d word=%0d status=%0d",
                   chunk_index, word_index, status);
          word_index = word_index + 1;
          total_ingress_words = total_ingress_words + 1;
          pending_word = 1'b0;
        end
        @(negedge clk);
        if (chunk_done)
          done_seen = 1'b1;
        cycles = cycles + 1;
        if (cycles > word_count * 20 + 100)
          $fatal(1, "partial-sum ingress timeout chunk=%0d", chunk_index);
      end
      clear_ingress();

      while (!done_seen) begin
        @(posedge clk);
        @(negedge clk);
        if (chunk_done)
          done_seen = 1'b1;
        cycles = cycles + 1;
        if (cycles > word_count * 20 + 120)
          $fatal(1, "partial-sum RMW drain timeout chunk=%0d", chunk_index);
      end
      total_chunks = total_chunks + 1;
    end
  endtask

  task automatic check_egress;
    int golden_accumulator [0:7];
    byte golden_mask;
    byte golden_last;
    int golden_tag;
    int status;
    begin
      if (hold_active) begin
        if (!egress_valid || egress_n_lane_mask != hold_mask ||
            egress_word_index != hold_index || egress_last != hold_last ||
            egress_context_tag != hold_tag)
          $fatal(1, "partial-sum metadata changed while backpressured");
        for (int lane = 0; lane < 8; lane++)
          if (egress_accumulator[lane] != hold_accumulator[lane])
            $fatal(1,
                   "partial-sum lane changed while backpressured lane=%0d",
                   lane);
      end

      if (egress_valid) begin
        status = alexnet_golden_partial_sum_bank_word(
            egress_word_index,
            golden_accumulator[0], golden_accumulator[1],
            golden_accumulator[2], golden_accumulator[3],
            golden_accumulator[4], golden_accumulator[5],
            golden_accumulator[6], golden_accumulator[7],
            golden_mask, golden_last, golden_tag);
        if (status != 0 || egress_n_lane_mask != golden_mask ||
            egress_last != golden_last[0] ||
            egress_context_tag != golden_tag)
          $fatal(1,
                 "partial-sum output metadata mismatch word=%0d status=%0d",
                 egress_word_index, status);
        for (int lane = 0; lane < 8; lane++)
          if (egress_accumulator[lane] != golden_accumulator[lane])
            $fatal(1,
                   "partial-sum output mismatch word=%0d lane=%0d rtl=%0d golden=%0d",
                   egress_word_index, lane, egress_accumulator[lane],
                   golden_accumulator[lane]);
      end

      if (egress_valid && !egress_ready) begin
        hold_active = 1'b1;
        hold_mask = egress_n_lane_mask;
        hold_index = egress_word_index;
        hold_last = egress_last;
        hold_tag = egress_context_tag;
        for (int lane = 0; lane < 8; lane++)
          hold_accumulator[lane] = egress_accumulator[lane];
        stall_run = stall_run + 1;
        if (stall_run > max_output_stall)
          max_output_stall = stall_run;
      end else begin
        hold_active = 1'b0;
        stall_run = 0;
      end
    end
  endtask

  task automatic drain_output(input int word_count, input int chunk_count);
    int output_count;
    int cycles;
    int status;
    logic output_fire;
    logic output_last;
    logic done_seen;
    begin
      output_count = 0;
      cycles = 0;
      done_seen = 1'b0;
      hold_active = 1'b0;
      stall_run = 0;
      check_stable_state(4);
      if (completed_chunks != chunk_count)
        $fatal(1, "partial-sum completed chunk count mismatch");

      while (!done_seen) begin
        if ((cycles % 61) < 15)
          egress_ready = 1'b0;
        else
          egress_ready = $urandom_range(0, 4) != 0;
        #1;
        check_egress();
        output_fire = egress_valid && egress_ready;
        output_last = egress_last;
        if (output_fire && egress_word_index != output_count)
          $fatal(1, "partial-sum output order mismatch rtl=%0d expected=%0d",
                 egress_word_index, output_count);
        @(posedge clk);
        if (output_fire) begin
          output_count = output_count + 1;
          total_egress_words = total_egress_words + 1;
          if (output_last) begin
            status = alexnet_golden_partial_sum_bank_complete_emit();
            if (status != 0)
              $fatal(1, "C++ partial-sum complete_emit failed status=%0d",
                     status);
          end
        end
        @(negedge clk);
        if (emit_done)
          done_seen = 1'b1;
        cycles = cycles + 1;
        if (cycles > word_count * 25 + 200)
          $fatal(1, "partial-sum output timeout words=%0d", word_count);
      end

      egress_ready = 1'b0;
      if (output_count != word_count || !idle || resident_valid)
        $fatal(1,
               "partial-sum emit release mismatch outputs=%0d/%0d idle=%0b resident=%0b",
               output_count, word_count, idle, resident_valid);
      check_stable_state(0);
    end
  endtask

  task automatic run_transaction(
      input int transaction_index,
      input int word_count,
      input int chunk_count,
      input logic [7:0] lane_mask,
      input int context_tag);
    begin
      if (!idle || resident_valid)
        $fatal(1, "partial-sum bank did not expose EMPTY ownership");

      drive_rejected_descriptor(word_count, lane_mask, context_tag, 1,
                                1'b0, 1'b0);
      if (!protocol_error)
        $fatal(1, "partial-sum bank did not flag invalid first descriptor");

      for (int chunk = 0; chunk < chunk_count; chunk++) begin
        if (chunk != 0) begin
          drive_rejected_descriptor(word_count, lane_mask, context_tag + 1,
                                    chunk, 1'b0,
                                    chunk == chunk_count - 1);
          drive_rejected_descriptor(word_count, lane_mask, context_tag,
                                    chunk + 1, 1'b0,
                                    chunk == chunk_count - 1);
          drive_rejected_descriptor(word_count,
                                    lane_mask == 8'hff ? 8'h7f : 8'hff,
                                    context_tag, chunk, 1'b0,
                                    chunk == chunk_count - 1);
          if (!context_error)
            $fatal(1,
                   "partial-sum bank did not flag continuation context error");
        end

        start_chunk(word_count, lane_mask, context_tag, chunk,
                    chunk == 0, chunk == chunk_count - 1);
        ingest_chunk(transaction_index, chunk, word_count, lane_mask);

        if (chunk == chunk_count - 1)
          check_stable_state(4);
        else
          check_stable_state(2);
      end

      drain_output(word_count, chunk_count);
      transactions = transactions + 1;
    end
  endtask

  initial begin
    int seed;
    int seed_sink;
    int status;
    seed = 32'h73a8_19cd;
    seed_sink = $urandom(seed);

    rst = 1'b1;
    clear_descriptor();
    clear_ingress();
    egress_ready = 1'b0;
    transactions = 0;
    total_chunks = 0;
    total_ingress_words = 0;
    total_egress_words = 0;
    rejected_descriptors = 0;
    blocked_words = 0;
    max_output_stall = 0;
    stall_run = 0;
    hold_active = 1'b0;

    status = alexnet_golden_partial_sum_bank_reset(DEPTH);
    if (status != 0)
      $fatal(1, "C++ partial-sum reset failed status=%0d", status);

    repeat (5) @(negedge clk);
    rst = 1'b0;
    @(negedge clk);

    run_transaction(0, 1, 1, 8'h01, 301);
    run_transaction(1, 17, 3, 8'h0f, 302);
    run_transaction(2, 511, 5, 8'h7f, 303);
    run_transaction(3, 512, 8, 8'hff, 304);
    // Conv4 is the largest AlexNet input-channel fan-in: 384 / N8 = 48
    // channel chunks over a 13x13 output raster.
    run_transaction(4, 169, 48, 8'hff, 305);

    $display(
        "ALEXNET_N8_INT32_PARTIAL_SUM_BANK_TEST_PASSED transactions=%0d chunks=%0d ingress_words=%0d egress_words=%0d descriptor_rejects=%0d blocked_words=%0d maxstall=%0d seed=%0d",
        transactions, total_chunks, total_ingress_words, total_egress_words,
        rejected_descriptors, blocked_words, max_output_stall, seed);
    $finish;
  end

endmodule
