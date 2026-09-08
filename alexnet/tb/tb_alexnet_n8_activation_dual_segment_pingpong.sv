`timescale 1ns/1ps

module tb_alexnet_n8_activation_dual_segment_pingpong;

  localparam int SEGMENT_DEPTH = 512;
  localparam int LOCAL_ADDR_W = $clog2(SEGMENT_DEPTH);
  localparam int LOCAL_COUNT_W = $clog2(SEGMENT_DEPTH + 1);
  localparam int GLOBAL_ADDR_W = $clog2(2 * SEGMENT_DEPTH);
  localparam int TOTAL_COUNT_W = $clog2(2 * SEGMENT_DEPTH + 1);
  localparam int TRANSACTION_COUNT = 8;
  localparam int EXPECTED_WORDS = 4526;

  import "DPI-C" function int
      alexnet_golden_activation_dual_segment_pingpong_reset(
          input int segment_depth);
  import "DPI-C" function int
      alexnet_golden_activation_dual_segment_pingpong_begin_fill(
          input byte is_pooled, input int word_count, input byte lane_mask,
          input int tensor_tag, output byte bank);
  import "DPI-C" function int
      alexnet_golden_activation_dual_segment_pingpong_write(
          input byte is_pooled, input longint unsigned values,
          input byte lane_mask, input byte last);
  import "DPI-C" function int
      alexnet_golden_activation_dual_segment_pingpong_begin_read(
          input int tensor_tag, output byte bank);
  import "DPI-C" function int
      alexnet_golden_activation_dual_segment_pingpong_word(
          input int global_index, output longint unsigned values,
          output byte lane_mask, output byte last, output int tensor_tag);
  import "DPI-C" function int
      alexnet_golden_activation_dual_segment_pingpong_complete_segment0();
  import "DPI-C" function int
      alexnet_golden_activation_dual_segment_pingpong_complete_read();
  import "DPI-C" function int
      alexnet_golden_activation_dual_segment_pingpong_state(
          output int golden_ready_count, output byte golden_ready_valid,
          output byte golden_ready_bank, output int golden_ready_tag,
          output byte golden_fill_active, output byte golden_fill_bank,
          output byte golden_fill_is_pooled, output byte golden_read_active,
          output byte golden_read_bank, output byte golden_read_segment);

  logic clk = 1'b0;
  logic rst;
  logic fill_valid;
  logic fill_ready;
  logic fill_is_pooled;
  logic [TOTAL_COUNT_W-1:0] fill_word_count;
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
  logic [GLOBAL_ADDR_W-1:0] read_index;
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
  logic read_segment;
  logic [1:0] segment0_bank0_state;
  logic [1:0] segment0_bank1_state;
  logic [1:0] segment1_bank0_state;
  logic [1:0] segment1_bank1_state;
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
  int segment_transitions;
  int boundary511_stalls;
  int boundary512_stalls;
  int max_read_stall;
  int read_stall_run;
  int cycles;
  logic malformed_word_attempted;
  logic saw_ready_full;
  logic held_read_valid;
  logic [63:0] held_read_values;
  logic [7:0] held_read_lane_mask;
  logic [GLOBAL_ADDR_W-1:0] held_read_index;
  logic held_read_last;
  logic [15:0] held_read_tag;

  alexnet_n8_activation_dual_segment_pingpong #(
      .SEGMENT_DEPTH(SEGMENT_DEPTH)
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
        value = (transaction_index * 83 + word_index * 41 + lane * 47) &
                8'hff;
        result[lane*8 +: 8] = value[7:0];
      end
      make_word = result;
    end
  endfunction

  task automatic check_model_state;
    int golden_ready_count;
    int golden_ready_tag;
    byte golden_ready_valid;
    byte golden_ready_bank;
    byte golden_fill_active;
    byte golden_fill_bank;
    byte golden_fill_is_pooled;
    byte golden_read_active;
    byte golden_read_bank;
    byte golden_read_segment;
    int status;
    begin
      status = alexnet_golden_activation_dual_segment_pingpong_state(
          golden_ready_count, golden_ready_valid, golden_ready_bank,
          golden_ready_tag, golden_fill_active, golden_fill_bank,
          golden_fill_is_pooled, golden_read_active, golden_read_bank,
          golden_read_segment);
      if (status != 0)
        $fatal(1, "dual-segment activation state oracle failed status=%0d",
               status);
      if (ready_count != golden_ready_count ||
          ready_tensor_valid != golden_ready_valid[0] ||
          fill_active != golden_fill_active[0] ||
          read_active != golden_read_active[0])
        $fatal(1,
               "dual-segment activation owner mismatch ready=%0d/%0d fill=%0b/%0b read=%0b/%0b",
               ready_count, golden_ready_count, fill_active,
               golden_fill_active[0], read_active, golden_read_active[0]);
      if (ready_tensor_valid &&
          (ready_tensor_bank != golden_ready_bank[0] ||
           ready_tensor_tag != golden_ready_tag))
        $fatal(1,
               "dual-segment activation READY mismatch bank=%0d/%0d tag=%0d/%0d",
               ready_tensor_bank, golden_ready_bank, ready_tensor_tag,
               golden_ready_tag);
      if (fill_active &&
          (fill_bank != golden_fill_bank[0] ||
           active_fill_is_pooled != golden_fill_is_pooled[0]))
        $fatal(1,
               "dual-segment activation fill mismatch bank=%0d/%0d source=%0d/%0d",
               fill_bank, golden_fill_bank, active_fill_is_pooled,
               golden_fill_is_pooled);
      if (read_active &&
          (read_bank != golden_read_bank[0] ||
           read_segment != golden_read_segment[0]))
        $fatal(1,
               "dual-segment activation read mismatch bank=%0d/%0d segment=%0d/%0d",
               read_bank, golden_read_bank, read_segment,
               golden_read_segment);
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
        $fatal(1,
               "dual-segment activation output changed under backpressure");

      if (read_valid) begin
        status = alexnet_golden_activation_dual_segment_pingpong_word(
            read_index, golden_values, golden_lane_mask, golden_last,
            golden_tensor_tag);
        if (status != 0 || read_values != golden_values ||
            read_lane_mask != golden_lane_mask ||
            read_last != golden_last[0] ||
            read_tensor_tag != golden_tensor_tag)
          $fatal(1,
                 "dual-segment activation data mismatch index=%0d values=%016x/%016x mask=%02x/%02x last=%0b/%0b tag=%0d/%0d status=%0d",
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
    logic captured_source_valid;
    logic captured_source_ready;
    logic captured_source_last;
    logic [63:0] captured_source_values;
    logic [7:0] captured_source_mask;
    logic captured_ready_bank;

    seed = 32'h6b4b_9e31;
    seed_sink = $urandom(seed);

    word_counts[0] = 513;
    word_counts[1] = 729;
    word_counts[2] = 1024;
    word_counts[3] = 514;
    word_counts[4] = 777;
    word_counts[5] = 600;
    word_counts[6] = 169;
    word_counts[7] = 200;
    lane_masks[0] = 8'hff;
    lane_masks[1] = 8'h0f;
    lane_masks[2] = 8'h81;
    lane_masks[3] = 8'h01;
    lane_masks[4] = 8'h7f;
    lane_masks[5] = 8'h55;
    lane_masks[6] = 8'hff;
    lane_masks[7] = 8'h03;
    for (int transaction = 0; transaction < TRANSACTION_COUNT;
         transaction++) begin
      is_pooled[transaction] = transaction[0];
      tensor_tags[transaction] = 16'h4100 + transaction;
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
    segment_transitions = 0;
    boundary511_stalls = 0;
    boundary512_stalls = 0;
    max_read_stall = 0;
    read_stall_run = 0;
    cycles = 0;
    malformed_word_attempted = 1'b0;
    saw_ready_full = 1'b0;
    held_read_valid = 1'b0;

    status = alexnet_golden_activation_dual_segment_pingpong_reset(
        SEGMENT_DEPTH);
    if (status != 0)
      $fatal(1, "dual-segment activation reset oracle failed status=%0d",
             status);

    repeat (5) @(negedge clk);
    rst = 1'b0;
    @(negedge clk);

    // A zero-length descriptor remains illegal at this storage boundary.
    fill_valid = 1'b1;
    fill_word_count = 0;
    fill_lane_mask = 8'hff;
    fill_tensor_tag = 16'hffff;
    #1;
    if (fill_ready)
      $fatal(1, "dual-segment activation accepted a zero descriptor");
    @(posedge clk);
    @(negedge clk);
    fill_valid = 1'b0;
    #1;
    if (!protocol_error)
      $fatal(1, "dual-segment activation did not latch descriptor error");

    while (reads_completed < TRANSACTION_COUNT) begin
      fill_valid = 1'b0;
      direct_valid = 1'b0;
      pooled_valid = 1'b0;
      read_start_valid = 1'b0;

      if (active_fill_transaction < 0 &&
          next_fill_transaction < TRANSACTION_COUNT) begin
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
        captured_source_values = make_word(active_fill_transaction,
                                           fill_word_index);
        captured_source_mask = lane_masks[active_fill_transaction];
        captured_source_last =
            fill_word_index == word_counts[active_fill_transaction] - 1;

        if (!malformed_word_attempted && active_fill_transaction == 2 &&
            fill_word_index == SEGMENT_DEPTH) begin
          captured_source_mask = lane_masks[active_fill_transaction] ^ 8'h80;
          captured_source_last = 1'b0;
          captured_source_valid = 1'b1;
        end else begin
          captured_source_valid = (cycles % 5) != 0;
        end

        if (is_pooled[active_fill_transaction]) begin
          pooled_valid = captured_source_valid;
          pooled_values = captured_source_values;
          pooled_lane_mask = captured_source_mask;
          pooled_last = captured_source_last;
        end else begin
          direct_valid = captured_source_valid;
          direct_values = captured_source_values;
          direct_lane_mask = captured_source_mask;
          direct_last = captured_source_last;
        end

        if ((cycles % 13) == 4) begin
          if (is_pooled[active_fill_transaction]) begin
            direct_valid = 1'b1;
            direct_values = ~captured_source_values;
            direct_lane_mask = lane_masks[active_fill_transaction];
            direct_last = 1'b0;
          end else begin
            pooled_valid = 1'b1;
            pooled_values = ~captured_source_values;
            pooled_lane_mask = lane_masks[active_fill_transaction];
            pooled_last = 1'b0;
          end
        end
      end

      if (fills_completed >= 2 && active_read_transaction < 0 &&
          next_read_transaction < TRANSACTION_COUNT && ready_tensor_valid) begin
        read_start_valid = 1'b1;
        if (!mismatch_attempted[next_read_transaction])
          read_start_tensor_tag = tensor_tags[next_read_transaction] + 1;
        else
          read_start_tensor_tag = tensor_tags[next_read_transaction];
      end

      if (read_valid && read_index == SEGMENT_DEPTH - 1 &&
          boundary511_stalls < 5)
        read_ready = 1'b0;
      else if (read_valid && read_index == SEGMENT_DEPTH &&
               boundary512_stalls < 5)
        read_ready = 1'b0;
      else if ((cycles % 53) < 17)
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
        $fatal(1, "dual-segment activation enabled both sources");
      if (fill_active && active_fill_is_pooled && direct_valid) begin
        if (direct_ready)
          $fatal(1, "dual-segment activation accepted non-owner direct data");
        wrong_source_blocks = wrong_source_blocks + 1;
      end
      if (fill_active && !active_fill_is_pooled && pooled_valid) begin
        if (pooled_ready)
          $fatal(1, "dual-segment activation accepted non-owner pooled data");
        wrong_source_blocks = wrong_source_blocks + 1;
      end
      if (read_start_valid) begin
        if (!mismatch_attempted[next_read_transaction]) begin
          if (read_start_ready)
            $fatal(1, "dual-segment activation accepted a bad tensor tag");
          if (ready_tensor_tag != tensor_tags[next_read_transaction])
            $fatal(1, "dual-segment activation READY order changed");
        end
      end

      if (read_valid && !read_ready && read_index == SEGMENT_DEPTH - 1)
        boundary511_stalls = boundary511_stalls + 1;
      if (read_valid && !read_ready && read_index == SEGMENT_DEPTH)
        boundary512_stalls = boundary512_stalls + 1;

      fill_fire = fill_valid && fill_ready;
      direct_fire = direct_valid && direct_ready;
      pooled_fire = pooled_valid && pooled_ready;
      read_start_fire = read_start_valid && read_start_ready;
      read_fire = read_valid && read_ready;
      captured_ready_bank = ready_tensor_bank;

      captured_source_valid = 1'b0;
      captured_source_ready = 1'b0;
      captured_source_values = '0;
      captured_source_mask = '0;
      captured_source_last = 1'b0;
      if (active_fill_transaction >= 0) begin
        captured_source_valid = is_pooled[active_fill_transaction] ?
                                pooled_valid : direct_valid;
        captured_source_ready = is_pooled[active_fill_transaction] ?
                                pooled_ready : direct_ready;
        captured_source_values = is_pooled[active_fill_transaction] ?
                                 pooled_values : direct_values;
        captured_source_mask = is_pooled[active_fill_transaction] ?
                               pooled_lane_mask : direct_lane_mask;
        captured_source_last = is_pooled[active_fill_transaction] ?
                               pooled_last : direct_last;
      end

      if (fill_fire && read_start_fire)
        simultaneous_role_swaps = simultaneous_role_swaps + 1;

      @(posedge clk);

      if (fill_fire) begin
        status = alexnet_golden_activation_dual_segment_pingpong_begin_fill(
            fill_is_pooled, fill_word_count, fill_lane_mask,
            fill_tensor_tag, golden_bank);
        if (status != 0)
          $fatal(1,
                 "dual-segment activation begin-fill oracle failed bank=%0d status=%0d",
                 golden_bank, status);
        active_fill_transaction = next_fill_transaction;
        next_fill_transaction = next_fill_transaction + 1;
        fill_word_index = 0;
      end

      if (active_fill_transaction == 2) begin
        if (fill_word_index == SEGMENT_DEPTH && captured_source_valid &&
            !captured_source_ready && !malformed_word_attempted) begin
          malformed_word_attempted = 1'b1;
          malformed_word_blocks = malformed_word_blocks + 1;
        end
      end

      if (direct_fire || pooled_fire) begin
        status = alexnet_golden_activation_dual_segment_pingpong_write(
            is_pooled[active_fill_transaction], captured_source_values,
            captured_source_mask, captured_source_last);
        if (status != 0)
          $fatal(1,
                 "dual-segment activation write oracle failed transaction=%0d index=%0d status=%0d",
                 active_fill_transaction, fill_word_index, status);
        fill_word_index = fill_word_index + 1;
        if (captured_source_last) begin
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
        status = alexnet_golden_activation_dual_segment_pingpong_begin_read(
            read_start_tensor_tag, golden_bank);
        if (status != 0 || golden_bank != captured_ready_bank)
          $fatal(1,
                 "dual-segment activation begin-read mismatch bank=%0d/%0d status=%0d",
                 captured_ready_bank, golden_bank, status);
        active_read_transaction = next_read_transaction;
        next_read_transaction = next_read_transaction + 1;
      end

      if (read_fire) begin
        total_words_read = total_words_read + 1;
        if (read_index == SEGMENT_DEPTH - 1) begin
          status =
              alexnet_golden_activation_dual_segment_pingpong_complete_segment0();
          if (status != 0)
            $fatal(1,
                   "dual-segment activation segment transition failed status=%0d",
                   status);
          segment_transitions = segment_transitions + 1;
        end
        if (read_last) begin
          status =
              alexnet_golden_activation_dual_segment_pingpong_complete_read();
          if (status != 0)
            $fatal(1,
                   "dual-segment activation read completion failed status=%0d",
                   status);
          if (read_index + 1 != word_counts[active_read_transaction])
            $fatal(1,
                   "dual-segment activation final index mismatch index=%0d words=%0d",
                   read_index, word_counts[active_read_transaction]);
          active_read_transaction = -1;
          reads_completed = reads_completed + 1;
        end
      end

      @(negedge clk);
      if (read_done)
        read_done_pulses = read_done_pulses + 1;
      cycles = cycles + 1;
      if (cycles > 100000)
        $fatal(1,
               "dual-segment activation timeout fills=%0d reads=%0d active=%0d/%0d",
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
        total_words_read != EXPECTED_WORDS ||
        overlap_cycles == 0 || simultaneous_role_swaps == 0 ||
        context_rejects != TRANSACTION_COUNT ||
        read_done_pulses != TRANSACTION_COUNT ||
        segment_transitions != 6 ||
        boundary511_stalls < 5 || boundary512_stalls < 5 ||
        malformed_word_blocks != 1 || wrong_source_blocks == 0)
      $fatal(1,
             "dual-segment activation final coverage mismatch idle=%0b ready=%0d active=%0b/%0b errors=%0b/%0b full=%0b words=%0d overlap=%0d swaps=%0d rejects=%0d done=%0d transitions=%0d boundary=%0d/%0d malformed=%0d wrongsrc=%0d",
             idle, ready_count, fill_active, read_active, context_error,
             protocol_error, saw_ready_full, total_words_read, overlap_cycles,
             simultaneous_role_swaps, context_rejects, read_done_pulses,
             segment_transitions, boundary511_stalls, boundary512_stalls,
             malformed_word_blocks, wrong_source_blocks);

    $display(
        "ALEXNET_N8_ACTIVATION_DUAL_SEGMENT_PINGPONG_TEST_PASSED transactions=%0d words=%0d rejects=%0d wrongsrc=%0d overlap_cycles=%0d role_swaps=%0d transitions=%0d boundary_stalls=%0d maxstall=%0d seed=%0d",
        TRANSACTION_COUNT, total_words_read, context_rejects,
        wrong_source_blocks, overlap_cycles, simultaneous_role_swaps,
        segment_transitions, boundary511_stalls + boundary512_stalls,
        max_read_stall, seed);
    $finish;
  end

endmodule
