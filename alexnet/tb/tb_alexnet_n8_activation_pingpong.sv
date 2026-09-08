`timescale 1ns/1ps

module tb_alexnet_n8_activation_pingpong;

  localparam int DEPTH = 512;
  localparam int ADDR_W = $clog2(DEPTH);
  localparam int COUNT_W = $clog2(DEPTH + 1);
  localparam int TRANSACTION_COUNT = 8;

  import "DPI-C" function int alexnet_golden_activation_pingpong_reset(
      input int depth);
  import "DPI-C" function int alexnet_golden_activation_pingpong_begin_fill(
      input byte is_pooled, input int word_count, input byte lane_mask,
      input int tensor_tag, output byte bank);
  import "DPI-C" function int alexnet_golden_activation_pingpong_write(
      input byte is_pooled, input longint unsigned values,
      input byte lane_mask, input byte last);
  import "DPI-C" function int alexnet_golden_activation_pingpong_begin_read(
      input int tensor_tag, output byte bank);
  import "DPI-C" function int alexnet_golden_activation_pingpong_word(
      input int index, output longint unsigned values,
      output byte lane_mask, output byte last, output int tensor_tag);
  import "DPI-C" function int alexnet_golden_activation_pingpong_complete_read();
  import "DPI-C" function int alexnet_golden_activation_pingpong_state(
      output byte golden_bank0_state, output int golden_bank0_words,
      output byte golden_bank1_state, output int golden_bank1_words,
      output int golden_ready_count, output byte golden_ready_valid,
      output byte golden_ready_bank, output int golden_ready_tag,
      output byte golden_fill_active, output byte golden_fill_bank,
      output byte golden_fill_is_pooled, output byte golden_read_active,
      output byte golden_read_bank);

  logic clk = 1'b0;
  logic rst;
  logic fill_valid;
  logic fill_ready;
  logic fill_is_pooled;
  logic [COUNT_W-1:0] fill_word_count;
  logic [7:0] fill_lane_mask;
  logic [15:0] fill_tensor_tag;
  logic direct_valid;
  logic direct_ready;
  logic [63:0] direct_values;
  logic [7:0] direct_lane_mask;
  logic direct_last;
  logic pooled_valid;
  logic pooled_ready;
  logic [63:0] pooled_values;
  logic [7:0] pooled_lane_mask;
  logic pooled_last;
  logic read_start_valid;
  logic read_start_ready;
  logic [15:0] read_start_tensor_tag;
  logic read_valid;
  logic read_ready;
  logic [63:0] read_values;
  logic [7:0] read_lane_mask;
  logic [ADDR_W-1:0] read_index;
  logic read_last;
  logic [15:0] read_tensor_tag;
  logic read_done;
  logic ready_tensor_valid;
  logic ready_tensor_bank;
  logic [15:0] ready_tensor_tag;
  logic [1:0] ready_count;
  logic fill_active;
  logic fill_bank;
  logic active_fill_is_pooled;
  logic read_active;
  logic read_bank;
  logic [1:0] bank0_state;
  logic [1:0] bank1_state;
  logic [COUNT_W-1:0] bank0_words_written;
  logic [COUNT_W-1:0] bank1_words_written;
  logic context_error;
  logic protocol_error;
  logic idle;

  int word_counts [0:TRANSACTION_COUNT-1];
  logic [7:0] lane_masks [0:TRANSACTION_COUNT-1];
  logic is_pooled [0:TRANSACTION_COUNT-1];
  int tensor_tags [0:TRANSACTION_COUNT-1];
  logic mismatch_attempted [0:TRANSACTION_COUNT-1];

  int next_fill_transaction;
  int active_fill_transaction;
  int fill_word_index;
  int fills_completed;
  int next_read_transaction;
  int active_read_transaction;
  int reads_completed;
  int total_words_read;
  int context_rejects;
  int wrong_source_blocks;
  int malformed_word_blocks;
  int overlap_cycles;
  int simultaneous_role_swaps;
  int read_done_pulses;
  int max_read_stall;
  int read_stall_run;
  int cycles;
  logic malformed_word_attempted;
  logic saw_ready_full;
  logic held_read_valid;
  logic [63:0] held_read_values;
  logic [7:0] held_read_lane_mask;
  logic [ADDR_W-1:0] held_read_index;
  logic held_read_last;
  logic [15:0] held_read_tag;

  alexnet_n8_activation_pingpong #(
      .DEPTH(DEPTH)
  ) dut (.*);

  always #2.5 clk = ~clk;

  function automatic logic [63:0] make_word(
      input int transaction_index,
      input int word_index);
    logic [63:0] result;
    int value;
    begin
      result = '0;
      for (int lane = 0; lane < 8; lane++) begin
        value = (transaction_index * 71 + word_index * 37 + lane * 53) &
                8'hff;
        result[lane*8 +: 8] = value[7:0];
      end
      make_word = result;
    end
  endfunction

  task automatic check_model_state;
    byte golden_bank0_state;
    byte golden_bank1_state;
    byte golden_ready_valid;
    byte golden_ready_bank;
    byte golden_fill_active;
    byte golden_fill_bank;
    byte golden_fill_is_pooled;
    byte golden_read_active;
    byte golden_read_bank;
    int golden_bank0_words;
    int golden_bank1_words;
    int golden_ready_count;
    int golden_ready_tag;
    int status;
    begin
      status = alexnet_golden_activation_pingpong_state(
          golden_bank0_state, golden_bank0_words,
          golden_bank1_state, golden_bank1_words,
          golden_ready_count, golden_ready_valid, golden_ready_bank,
          golden_ready_tag, golden_fill_active, golden_fill_bank,
          golden_fill_is_pooled, golden_read_active, golden_read_bank);
      if (status != 0)
        $fatal(1, "activation ping-pong state oracle failed status=%0d",
               status);
      if (bank0_state != golden_bank0_state[1:0] ||
          bank1_state != golden_bank1_state[1:0] ||
          bank0_words_written != golden_bank0_words ||
          bank1_words_written != golden_bank1_words ||
          ready_count != golden_ready_count ||
          ready_tensor_valid != golden_ready_valid[0])
        $fatal(1,
               "activation ping-pong ownership mismatch b0=%0d/%0d/%0d/%0d b1=%0d/%0d/%0d/%0d ready=%0d/%0d",
               bank0_state, golden_bank0_state, bank0_words_written,
               golden_bank0_words, bank1_state, golden_bank1_state,
               bank1_words_written, golden_bank1_words, ready_count,
               golden_ready_count);
      if (ready_tensor_valid &&
          (ready_tensor_bank != golden_ready_bank[0] ||
           ready_tensor_tag != golden_ready_tag))
        $fatal(1,
               "activation ping-pong READY head mismatch bank=%0d/%0d tag=%0d/%0d",
               ready_tensor_bank, golden_ready_bank, ready_tensor_tag,
               golden_ready_tag);
      if (fill_active != golden_fill_active[0] ||
          read_active != golden_read_active[0])
        $fatal(1,
               "activation ping-pong active-owner mismatch fill=%0b/%0b read=%0b/%0b",
               fill_active, golden_fill_active[0], read_active,
               golden_read_active[0]);
      if (fill_active &&
          (fill_bank != golden_fill_bank[0] ||
           active_fill_is_pooled != golden_fill_is_pooled[0]))
        $fatal(1,
               "activation ping-pong fill-owner mismatch bank=%0d/%0d source=%0d/%0d",
               fill_bank, golden_fill_bank, active_fill_is_pooled,
               golden_fill_is_pooled);
      if (read_active && read_bank != golden_read_bank[0])
        $fatal(1, "activation ping-pong read-owner mismatch bank=%0d/%0d",
               read_bank, golden_read_bank);
    end
  endtask

  task automatic check_read_output;
    longint unsigned golden_values;
    byte golden_lane_mask;
    byte golden_last;
    int golden_tensor_tag;
    int status;
    begin
      if (held_read_valid &&
          (!read_valid || read_values != held_read_values ||
           read_lane_mask != held_read_lane_mask ||
           read_index != held_read_index || read_last != held_read_last ||
           read_tensor_tag != held_read_tag))
        $fatal(1, "activation ping-pong output changed under backpressure");

      if (read_valid) begin
        status = alexnet_golden_activation_pingpong_word(
            read_index, golden_values, golden_lane_mask, golden_last,
            golden_tensor_tag);
        if (status != 0 || read_values != golden_values ||
            read_lane_mask != golden_lane_mask ||
            read_last != golden_last[0] ||
            read_tensor_tag != golden_tensor_tag)
          $fatal(1,
                 "activation ping-pong read mismatch index=%0d values=%016x/%016x mask=%02x/%02x last=%0b/%0b tag=%0d/%0d status=%0d",
                 read_index, read_values, golden_values, read_lane_mask,
                 golden_lane_mask, read_last, golden_last[0], read_tensor_tag,
                 golden_tensor_tag, status);
      end

      held_read_valid = read_valid && !read_ready;
      if (held_read_valid) begin
        held_read_values = read_values;
        held_read_lane_mask = read_lane_mask;
        held_read_index = read_index;
        held_read_last = read_last;
        held_read_tag = read_tensor_tag;
        read_stall_run = read_stall_run + 1;
        if (read_stall_run > max_read_stall)
          max_read_stall = read_stall_run;
      end else begin
        read_stall_run = 0;
      end
    end
  endtask

  initial begin
    int seed;
    int seed_sink;
    int status;
    byte golden_bank;
    logic fill_fire;
    logic direct_fire;
    logic pooled_fire;
    logic read_start_fire;
    logic read_fire;
    logic selected_source_valid;
    logic selected_source_ready;
    logic selected_source_last;
    logic [63:0] selected_source_values;
    logic [7:0] selected_source_mask;

    seed = 32'h6b3a_8d21;
    seed_sink = $urandom(seed);

    word_counts[0] = 17;
    word_counts[1] = 1;
    word_counts[2] = 511;
    word_counts[3] = 512;
    word_counts[4] = 169;
    word_counts[5] = 55;
    word_counts[6] = 256;
    word_counts[7] = 3;
    lane_masks[0] = 8'hff;
    lane_masks[1] = 8'h0f;
    lane_masks[2] = 8'h81;
    lane_masks[3] = 8'h01;
    lane_masks[4] = 8'h7f;
    lane_masks[5] = 8'h03;
    lane_masks[6] = 8'h1f;
    lane_masks[7] = 8'h55;
    for (int transaction = 0; transaction < TRANSACTION_COUNT;
         transaction++) begin
      is_pooled[transaction] = transaction[0];
      tensor_tags[transaction] = 16'h3100 + transaction;
      mismatch_attempted[transaction] = 1'b0;
    end

    rst = 1'b1;
    fill_valid = 1'b0;
    fill_is_pooled = 1'b0;
    fill_word_count = '0;
    fill_lane_mask = '0;
    fill_tensor_tag = '0;
    direct_valid = 1'b0;
    direct_values = '0;
    direct_lane_mask = '0;
    direct_last = 1'b0;
    pooled_valid = 1'b0;
    pooled_values = '0;
    pooled_lane_mask = '0;
    pooled_last = 1'b0;
    read_start_valid = 1'b0;
    read_start_tensor_tag = '0;
    read_ready = 1'b0;
    next_fill_transaction = 0;
    active_fill_transaction = -1;
    fill_word_index = 0;
    fills_completed = 0;
    next_read_transaction = 0;
    active_read_transaction = -1;
    reads_completed = 0;
    total_words_read = 0;
    context_rejects = 0;
    wrong_source_blocks = 0;
    malformed_word_blocks = 0;
    overlap_cycles = 0;
    simultaneous_role_swaps = 0;
    read_done_pulses = 0;
    max_read_stall = 0;
    read_stall_run = 0;
    cycles = 0;
    malformed_word_attempted = 1'b0;
    saw_ready_full = 1'b0;
    held_read_valid = 1'b0;

    status = alexnet_golden_activation_pingpong_reset(DEPTH);
    if (status != 0)
      $fatal(1, "activation ping-pong reset oracle failed status=%0d",
             status);

    repeat (5) @(negedge clk);
    rst = 1'b0;
    @(negedge clk);

    // Invalid descriptors are backpressured and cannot claim either bank.
    fill_valid = 1'b1;
    fill_word_count = '0;
    fill_lane_mask = 8'hff;
    fill_tensor_tag = 16'hffff;
    #1;
    if (fill_ready)
      $fatal(1, "activation ping-pong accepted an invalid descriptor");
    @(posedge clk);
    @(negedge clk);
    fill_valid = 1'b0;
    #1;
    if (!protocol_error)
      $fatal(1, "activation ping-pong did not latch descriptor error");

    while (reads_completed < TRANSACTION_COUNT) begin
      fill_valid = 1'b0;
      direct_valid = 1'b0;
      pooled_valid = 1'b0;
      read_start_valid = 1'b0;

      if (active_fill_transaction < 0 &&
          next_fill_transaction < TRANSACTION_COUNT) begin
        // Leave the newly empty bank unclaimed for one mismatch probe. The
        // following correct read and next fill can then exchange roles on the
        // same edge.
        if (!(fills_completed >= 2 && ready_tensor_valid &&
              active_read_transaction < 0 &&
              next_read_transaction < TRANSACTION_COUNT &&
              !mismatch_attempted[next_read_transaction])) begin
          fill_valid = 1'b1;
          fill_is_pooled = is_pooled[next_fill_transaction];
          fill_word_count = word_counts[next_fill_transaction];
          fill_lane_mask = lane_masks[next_fill_transaction];
          fill_tensor_tag = tensor_tags[next_fill_transaction];
        end
      end

      if (active_fill_transaction >= 0) begin
        if (!malformed_word_attempted && active_fill_transaction == 2 &&
            fill_word_index == 0) begin
          selected_source_values = make_word(active_fill_transaction,
                                             fill_word_index);
          selected_source_mask = lane_masks[active_fill_transaction] ^ 8'h80;
          selected_source_last = 1'b0;
          if (is_pooled[active_fill_transaction]) begin
            pooled_valid = 1'b1;
            pooled_values = selected_source_values;
            pooled_lane_mask = selected_source_mask;
            pooled_last = selected_source_last;
          end else begin
            direct_valid = 1'b1;
            direct_values = selected_source_values;
            direct_lane_mask = selected_source_mask;
            direct_last = selected_source_last;
          end
        end else if ((cycles % 5) != 0) begin
          selected_source_values = make_word(active_fill_transaction,
                                             fill_word_index);
          selected_source_mask = lane_masks[active_fill_transaction];
          selected_source_last =
              fill_word_index == word_counts[active_fill_transaction] - 1;
          if (is_pooled[active_fill_transaction]) begin
            pooled_valid = 1'b1;
            pooled_values = selected_source_values;
            pooled_lane_mask = selected_source_mask;
            pooled_last = selected_source_last;
          end else begin
            direct_valid = 1'b1;
            direct_values = selected_source_values;
            direct_lane_mask = selected_source_mask;
            direct_last = selected_source_last;
          end
        end

        // The non-owner source may be active but must never see ready.
        if ((cycles % 11) == 3) begin
          if (is_pooled[active_fill_transaction]) begin
            direct_valid = 1'b1;
            direct_values = ~make_word(active_fill_transaction,
                                       fill_word_index);
            direct_lane_mask = lane_masks[active_fill_transaction];
            direct_last = 1'b0;
          end else begin
            pooled_valid = 1'b1;
            pooled_values = ~make_word(active_fill_transaction,
                                       fill_word_index);
            pooled_lane_mask = lane_masks[active_fill_transaction];
            pooled_last = 1'b0;
          end
        end
      end

      // Hold the consumer until both initial fills are READY, proving that the
      // two-entry order queue becomes full before overlap begins.
      if (fills_completed >= 2 && active_read_transaction < 0 &&
          next_read_transaction < TRANSACTION_COUNT && ready_tensor_valid) begin
        read_start_valid = 1'b1;
        if (!mismatch_attempted[next_read_transaction])
          read_start_tensor_tag = tensor_tags[next_read_transaction] + 1;
        else
          read_start_tensor_tag = tensor_tags[next_read_transaction];
      end

      if ((cycles % 47) < 15)
        read_ready = 1'b0;
      else
        read_ready = $urandom_range(0, 5) != 0;

      #1;
      check_model_state();
      check_read_output();

      if (ready_count == 2)
        saw_ready_full = 1'b1;
      if (fill_active && read_active)
        overlap_cycles = overlap_cycles + 1;
      if (direct_ready && pooled_ready)
        $fatal(1, "activation ping-pong enabled both write sources");
      if (fill_active && active_fill_is_pooled && direct_valid) begin
        if (direct_ready)
          $fatal(1, "activation ping-pong accepted non-owner direct data");
        wrong_source_blocks = wrong_source_blocks + 1;
      end
      if (fill_active && !active_fill_is_pooled && pooled_valid) begin
        if (pooled_ready)
          $fatal(1, "activation ping-pong accepted non-owner pooled data");
        wrong_source_blocks = wrong_source_blocks + 1;
      end
      if (read_start_valid) begin
        if (!mismatch_attempted[next_read_transaction]) begin
          if (read_start_ready)
            $fatal(1, "activation ping-pong accepted a mismatched tensor tag");
          if (ready_tensor_tag != tensor_tags[next_read_transaction])
            $fatal(1, "activation ping-pong READY order changed");
        end
      end

      fill_fire = fill_valid && fill_ready;
      direct_fire = direct_valid && direct_ready;
      pooled_fire = pooled_valid && pooled_ready;
      read_start_fire = read_start_valid && read_start_ready;
      read_fire = read_valid && read_ready;
      selected_source_valid = 1'b0;
      selected_source_ready = 1'b0;
      selected_source_values = '0;
      selected_source_mask = '0;
      selected_source_last = 1'b0;
      if (active_fill_transaction >= 0) begin
        selected_source_valid = is_pooled[active_fill_transaction] ?
                                pooled_valid : direct_valid;
        selected_source_ready = is_pooled[active_fill_transaction] ?
                                pooled_ready : direct_ready;
        selected_source_values = is_pooled[active_fill_transaction] ?
                                 pooled_values : direct_values;
        selected_source_mask = is_pooled[active_fill_transaction] ?
                               pooled_lane_mask : direct_lane_mask;
        selected_source_last = is_pooled[active_fill_transaction] ?
                               pooled_last : direct_last;
      end

      if (fill_fire && read_start_fire)
        simultaneous_role_swaps = simultaneous_role_swaps + 1;

      @(posedge clk);

      if (fill_fire) begin
        status = alexnet_golden_activation_pingpong_begin_fill(
            fill_is_pooled, fill_word_count, fill_lane_mask,
            fill_tensor_tag, golden_bank);
        if (status != 0)
          $fatal(1,
                 "activation ping-pong begin-fill oracle failed bank=%0d status=%0d",
                 golden_bank, status);
        active_fill_transaction = next_fill_transaction;
        next_fill_transaction = next_fill_transaction + 1;
        fill_word_index = 0;
      end

      if (active_fill_transaction == 2) begin
        if (fill_word_index == 0 && selected_source_valid &&
            !selected_source_ready && !malformed_word_attempted) begin
          malformed_word_attempted = 1'b1;
          malformed_word_blocks = malformed_word_blocks + 1;
        end
      end

      if (direct_fire || pooled_fire) begin
        status = alexnet_golden_activation_pingpong_write(
            is_pooled[active_fill_transaction], selected_source_values,
            selected_source_mask, selected_source_last);
        if (status != 0)
          $fatal(1,
                 "activation ping-pong write oracle failed transaction=%0d index=%0d status=%0d",
                 active_fill_transaction, fill_word_index, status);
        fill_word_index = fill_word_index + 1;
        if (selected_source_last) begin
          active_fill_transaction = -1;
          fills_completed = fills_completed + 1;
        end
      end

      if (read_start_valid && !read_start_fire) begin
        if (!mismatch_attempted[next_read_transaction] &&
            read_start_tensor_tag != ready_tensor_tag) begin
          mismatch_attempted[next_read_transaction] = 1'b1;
          context_rejects = context_rejects + 1;
        end
      end

      if (read_start_fire) begin
        status = alexnet_golden_activation_pingpong_begin_read(
            read_start_tensor_tag, golden_bank);
        if (status != 0 || golden_bank != ready_tensor_bank)
          $fatal(1,
                 "activation ping-pong begin-read mismatch bank=%0d/%0d status=%0d",
                 ready_tensor_bank, golden_bank, status);
        active_read_transaction = next_read_transaction;
        next_read_transaction = next_read_transaction + 1;
      end

      if (read_fire) begin
        if (read_index >= word_counts[active_read_transaction])
          $fatal(1, "activation ping-pong read index exceeded transaction");
        total_words_read = total_words_read + 1;
        if (read_last) begin
          status = alexnet_golden_activation_pingpong_complete_read();
          if (status != 0)
            $fatal(1,
                   "activation ping-pong complete-read oracle failed status=%0d",
                   status);
          if (read_index + 1 != word_counts[active_read_transaction])
            $fatal(1,
                   "activation ping-pong early read-last index=%0d words=%0d",
                   read_index, word_counts[active_read_transaction]);
          active_read_transaction = -1;
          reads_completed = reads_completed + 1;
        end
      end

      @(negedge clk);
      if (read_done)
        read_done_pulses = read_done_pulses + 1;
      cycles = cycles + 1;
      if (cycles > 50000)
        $fatal(1,
               "activation ping-pong timeout fills=%0d reads=%0d active=%0d/%0d",
               fills_completed, reads_completed, active_fill_transaction,
               active_read_transaction);
    end

    fill_valid = 1'b0;
    direct_valid = 1'b0;
    pooled_valid = 1'b0;
    read_start_valid = 1'b0;
    read_ready = 1'b0;
    #1;
    check_model_state();
    if (!idle || ready_count != 0 || fill_active || read_active ||
        !context_error || !protocol_error || !saw_ready_full ||
        overlap_cycles == 0 || simultaneous_role_swaps == 0 ||
        context_rejects != TRANSACTION_COUNT ||
        read_done_pulses != TRANSACTION_COUNT ||
        malformed_word_blocks != 1 || wrong_source_blocks == 0)
      $fatal(1,
             "activation ping-pong final coverage mismatch idle=%0b ready=%0d active=%0b/%0b errors=%0b/%0b full=%0b overlap=%0d swaps=%0d rejects=%0d done=%0d malformed=%0d wrongsrc=%0d",
             idle, ready_count, fill_active, read_active, context_error,
             protocol_error, saw_ready_full, overlap_cycles,
             simultaneous_role_swaps, context_rejects, read_done_pulses,
             malformed_word_blocks, wrong_source_blocks);

    $display(
        "ALEXNET_N8_ACTIVATION_PINGPONG_TEST_PASSED transactions=%0d words=%0d rejects=%0d wrongsrc=%0d overlap_cycles=%0d role_swaps=%0d maxstall=%0d seed=%0d",
        TRANSACTION_COUNT, total_words_read, context_rejects,
        wrong_source_blocks, overlap_cycles, simultaneous_role_swaps,
        max_read_stall, seed);
    $finish;
  end

endmodule
