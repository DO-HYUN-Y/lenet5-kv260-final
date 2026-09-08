`timescale 1ns/1ps

module tb_alexnet_n8_dma_ingress;

  localparam int COUNT_W = 11;
  localparam int ACTIVATION_COUNT_W = 11;
  localparam int WEIGHT_COUNT_W = 10;
  localparam int BYTE_COUNT_W = 16;
  localparam int TAG_W = 16;
  localparam logic [1:0] DEST_ACTIVATION_DIRECT = 2'd0;
  localparam logic [1:0] DEST_ACTIVATION_POOLED = 2'd1;
  localparam logic [1:0] DEST_WEIGHT = 2'd2;

  logic clk = 1'b0;
  logic rst;
  logic clear_error;
  logic descriptor_valid;
  logic descriptor_ready;
  logic [1:0] descriptor_destination;
  logic [COUNT_W-1:0] descriptor_word_count;
  logic [BYTE_COUNT_W-1:0] descriptor_byte_count;
  logic [7:0] descriptor_lane_mask;
  logic [TAG_W-1:0] descriptor_tag;
  logic [127:0] s_axis_tdata;
  logic [15:0] s_axis_tkeep;
  logic s_axis_tvalid;
  logic s_axis_tready;
  logic s_axis_tlast;
  logic activation_fill_valid;
  logic activation_fill_ready;
  logic activation_fill_is_pooled;
  logic [ACTIVATION_COUNT_W-1:0] activation_fill_word_count;
  logic [7:0] activation_fill_lane_mask;
  logic [TAG_W-1:0] activation_fill_tensor_tag;
  logic activation_direct_valid;
  logic activation_direct_ready;
  logic [63:0] activation_direct_values;
  logic [7:0] activation_direct_lane_mask;
  logic activation_direct_last;
  logic activation_pooled_valid;
  logic activation_pooled_ready;
  logic [63:0] activation_pooled_values;
  logic [7:0] activation_pooled_lane_mask;
  logic activation_pooled_last;
  logic weight_fill_valid;
  logic weight_fill_ready;
  logic [WEIGHT_COUNT_W-1:0] weight_fill_k_count;
  logic [7:0] weight_fill_n_lane_mask;
  logic [TAG_W-1:0] weight_fill_context_tag;
  logic weight_write_valid;
  logic weight_write_ready;
  logic [63:0] weight_write_values;
  logic [7:0] weight_write_n_lane_mask;
  logic weight_write_last;
  logic busy;
  logic transfer_active;
  logic transfer_done;
  logic descriptor_rejected;
  logic descriptor_error;
  logic stream_error;
  logic protocol_error;
  logic [1:0] active_destination;
  logic [COUNT_W-1:0] words_transferred;
  logic [15:0] completed_transfers;

  int seed;
  int seed_sink;
  int cycles;
  int axis_beats;
  int total_output_words;
  int rejected_descriptors;
  int activation_descriptor_commits;
  int weight_descriptor_commits;
  int owner_wait_cycles;
  int payload_stall_run;
  int max_payload_stall;
  int current_transaction;
  int current_word_count;
  int current_payload_seen;
  logic [1:0] current_destination;
  logic [7:0] current_lane_mask;
  logic [TAG_W-1:0] current_tag;
  logic monitor_transfer;
  logic random_payload_stalls;
  logic held_payload_valid;
  logic [63:0] held_payload_values;
  logic [7:0] held_payload_mask;
  logic held_payload_last;
  logic [1:0] held_payload_destination;

  alexnet_n8_dma_ingress dut (.*);

  always #2.5 clk = ~clk;

  function automatic logic [63:0] make_word(
      input int transaction,
      input int word_index);
    logic [63:0] result;
    int value;
    begin
      result = '0;
      for (int lane = 0; lane < 8; lane++) begin
        value = (transaction * 67 + word_index * 43 + lane * 29 + 11) &
                8'hff;
        result[lane*8 +: 8] = value[7:0];
      end
      make_word = result;
    end
  endfunction

  always @(negedge clk) begin
    if (rst) begin
      activation_direct_ready <= 1'b0;
      activation_pooled_ready <= 1'b0;
      weight_write_ready <= 1'b0;
    end else if (random_payload_stalls) begin
      activation_direct_ready <= $urandom_range(0, 4) != 0;
      activation_pooled_ready <= $urandom_range(0, 3) != 0;
      weight_write_ready <= $urandom_range(0, 5) != 0;
    end else begin
      activation_direct_ready <= 1'b1;
      activation_pooled_ready <= 1'b1;
      weight_write_ready <= 1'b1;
    end
  end

  always @(posedge clk) begin
    int valid_count;
    logic observed_valid;
    logic observed_ready;
    logic [63:0] observed_values;
    logic [7:0] observed_mask;
    logic observed_last;
    logic [1:0] observed_destination;

    if (rst) begin
      cycles = 0;
      rejected_descriptors = 0;
      activation_descriptor_commits = 0;
      weight_descriptor_commits = 0;
      owner_wait_cycles = 0;
      payload_stall_run = 0;
      max_payload_stall = 0;
      held_payload_valid = 1'b0;
    end else begin
      cycles = cycles + 1;
      if (cycles > 30000)
        $fatal(1, "DMA ingress watchdog expired");

      if (descriptor_rejected)
        rejected_descriptors = rejected_descriptors + 1;

      if (activation_fill_valid && !activation_fill_ready)
        owner_wait_cycles = owner_wait_cycles + 1;
      if (weight_fill_valid && !weight_fill_ready)
        owner_wait_cycles = owner_wait_cycles + 1;

      if (activation_fill_valid) begin
        if (!monitor_transfer ||
            !(current_destination inside {DEST_ACTIVATION_DIRECT,
                                          DEST_ACTIVATION_POOLED}) ||
            activation_fill_is_pooled !=
                (current_destination == DEST_ACTIVATION_POOLED) ||
            activation_fill_word_count != current_word_count ||
            activation_fill_lane_mask != current_lane_mask ||
            activation_fill_tensor_tag != current_tag)
          $fatal(1, "DMA activation descriptor mismatch");
        if (activation_fill_ready)
          activation_descriptor_commits =
              activation_descriptor_commits + 1;
      end

      if (weight_fill_valid) begin
        if (!monitor_transfer || current_destination != DEST_WEIGHT ||
            weight_fill_k_count != current_word_count ||
            weight_fill_n_lane_mask != current_lane_mask ||
            weight_fill_context_tag != current_tag)
          $fatal(1, "DMA weight descriptor mismatch");
        if (weight_fill_ready)
          weight_descriptor_commits = weight_descriptor_commits + 1;
      end

      valid_count = activation_direct_valid + activation_pooled_valid +
                    weight_write_valid;
      if (valid_count > 1)
        $fatal(1, "DMA ingress drove multiple payload destinations");

      observed_valid = valid_count != 0;
      observed_ready = 1'b0;
      observed_values = '0;
      observed_mask = '0;
      observed_last = 1'b0;
      observed_destination = '0;
      if (activation_direct_valid) begin
        observed_ready = activation_direct_ready;
        observed_values = activation_direct_values;
        observed_mask = activation_direct_lane_mask;
        observed_last = activation_direct_last;
        observed_destination = DEST_ACTIVATION_DIRECT;
      end else if (activation_pooled_valid) begin
        observed_ready = activation_pooled_ready;
        observed_values = activation_pooled_values;
        observed_mask = activation_pooled_lane_mask;
        observed_last = activation_pooled_last;
        observed_destination = DEST_ACTIVATION_POOLED;
      end else if (weight_write_valid) begin
        observed_ready = weight_write_ready;
        observed_values = weight_write_values;
        observed_mask = weight_write_n_lane_mask;
        observed_last = weight_write_last;
        observed_destination = DEST_WEIGHT;
      end

      if (held_payload_valid &&
          (!observed_valid || observed_values != held_payload_values ||
           observed_mask != held_payload_mask ||
           observed_last != held_payload_last ||
           observed_destination != held_payload_destination))
        $fatal(1, "DMA ingress payload changed under backpressure");

      if (observed_valid) begin
        if (!monitor_transfer ||
            observed_destination != current_destination ||
            observed_values !=
                make_word(current_transaction, current_payload_seen) ||
            observed_mask != current_lane_mask ||
            observed_last !=
                (current_payload_seen + 1 == current_word_count))
          $fatal(1,
                 "DMA payload mismatch tx=%0d word=%0d destination=%0d",
                 current_transaction, current_payload_seen,
                 observed_destination);
        if (observed_ready) begin
          current_payload_seen = current_payload_seen + 1;
          total_output_words = total_output_words + 1;
          payload_stall_run = 0;
        end else begin
          payload_stall_run = payload_stall_run + 1;
          if (payload_stall_run > max_payload_stall)
            max_payload_stall = payload_stall_run;
        end
      end else begin
        payload_stall_run = 0;
      end

      held_payload_valid = observed_valid && !observed_ready;
      if (held_payload_valid) begin
        held_payload_values = observed_values;
        held_payload_mask = observed_mask;
        held_payload_last = observed_last;
        held_payload_destination = observed_destination;
      end
    end
  end

  task automatic submit_descriptor(
      input logic [1:0] destination,
      input int word_count,
      input int byte_count,
      input logic [7:0] lane_mask,
      input logic [TAG_W-1:0] tag);
    begin
      @(negedge clk);
      while (!descriptor_ready)
        @(negedge clk);
      descriptor_destination = destination;
      descriptor_word_count = COUNT_W'(word_count);
      descriptor_byte_count = BYTE_COUNT_W'(byte_count);
      descriptor_lane_mask = lane_mask;
      descriptor_tag = tag;
      descriptor_valid = 1'b1;
      @(posedge clk);
      @(negedge clk);
      descriptor_valid = 1'b0;
    end
  endtask

  task automatic reject_descriptor(
      input logic [1:0] destination,
      input int word_count,
      input int byte_count,
      input logic [7:0] lane_mask);
    int activation_commits_before;
    int weight_commits_before;
    begin
      activation_commits_before = activation_descriptor_commits;
      weight_commits_before = weight_descriptor_commits;
      monitor_transfer = 1'b0;
      submit_descriptor(destination, word_count, byte_count, lane_mask,
                        16'hde00 + rejected_descriptors);
      while (!descriptor_rejected)
        @(negedge clk);
      if (busy || transfer_active || s_axis_tready ||
          activation_descriptor_commits != activation_commits_before ||
          weight_descriptor_commits != weight_commits_before)
        $fatal(1, "rejected DMA descriptor consumed an owner");
      @(negedge clk);
    end
  endtask

  task automatic drive_axis_payload(
      input int transaction,
      input int word_count,
      input logic inject_stream_error);
    int word_index;
    int words_this_beat;
    logic [127:0] beat_data;
    logic [15:0] beat_keep;
    logic beat_last;
    begin
      word_index = 0;
      while (word_index < word_count) begin
        repeat ($urandom_range(0, 2)) @(negedge clk);
        @(negedge clk);
        while (!s_axis_tready)
          @(negedge clk);
        words_this_beat = ((word_count - word_index) >= 2) ? 2 : 1;
        beat_data = '0;
        beat_data[63:0] = make_word(transaction, word_index);
        if (words_this_beat == 2)
          beat_data[127:64] = make_word(transaction, word_index + 1);
        beat_keep = (words_this_beat == 2) ? 16'hffff : 16'h00ff;
        beat_last = word_index + words_this_beat == word_count;
        if (inject_stream_error && beat_last) begin
          beat_keep = 16'hffff;
          beat_last = 1'b0;
        end
        s_axis_tdata = beat_data;
        s_axis_tkeep = beat_keep;
        s_axis_tlast = beat_last;
        s_axis_tvalid = 1'b1;
        @(posedge clk);
        axis_beats = axis_beats + 1;
        @(negedge clk);
        s_axis_tvalid = 1'b0;
        word_index = word_index + words_this_beat;
      end
    end
  endtask

  task automatic run_transfer(
      input int transaction,
      input logic [1:0] destination,
      input int word_count,
      input logic [7:0] lane_mask,
      input logic [TAG_W-1:0] tag,
      input int owner_delay,
      input logic inject_stream_error);
    int completed_before;
    begin
      current_transaction = transaction;
      current_destination = destination;
      current_word_count = word_count;
      current_lane_mask = lane_mask;
      current_tag = tag;
      current_payload_seen = 0;
      monitor_transfer = 1'b1;
      completed_before = completed_transfers;

      if (destination == DEST_WEIGHT)
        weight_fill_ready = 1'b0;
      else
        activation_fill_ready = 1'b0;

      submit_descriptor(destination, word_count, word_count * 8, lane_mask,
                        tag);
      repeat (owner_delay) begin
        @(negedge clk);
        if (transfer_active || s_axis_tready)
          $fatal(1, "DMA transfer started before destination owner ready");
      end

      if (destination == DEST_WEIGHT)
        weight_fill_ready = 1'b1;
      else
        activation_fill_ready = 1'b1;
      while (!transfer_active)
        @(negedge clk);

      drive_axis_payload(transaction, word_count, inject_stream_error);
      while (!transfer_done)
        @(negedge clk);
      if (current_payload_seen != word_count ||
          words_transferred != word_count ||
          completed_transfers != completed_before + 1)
        $fatal(1,
               "DMA transfer completion mismatch tx=%0d payload=%0d/%0d words=%0d completed=%0d/%0d",
               transaction, current_payload_seen, word_count,
               words_transferred, completed_transfers,
               completed_before + 1);
      monitor_transfer = 1'b0;
      @(negedge clk);
    end
  endtask

  task automatic clear_errors;
    begin
      @(negedge clk);
      clear_error = 1'b1;
      @(posedge clk);
      @(negedge clk);
      clear_error = 1'b0;
      if (protocol_error || descriptor_error || stream_error)
        $fatal(1, "DMA ingress sticky errors did not clear");
    end
  endtask

  initial begin
    seed = 32'h752c_91a7;
    seed_sink = $urandom(seed);
    rst = 1'b1;
    clear_error = 1'b0;
    descriptor_valid = 1'b0;
    descriptor_destination = '0;
    descriptor_word_count = '0;
    descriptor_byte_count = '0;
    descriptor_lane_mask = '0;
    descriptor_tag = '0;
    s_axis_tdata = '0;
    s_axis_tkeep = '0;
    s_axis_tvalid = 1'b0;
    s_axis_tlast = 1'b0;
    activation_fill_ready = 1'b1;
    weight_fill_ready = 1'b1;
    random_payload_stalls = 1'b0;
    monitor_transfer = 1'b0;
    axis_beats = 0;
    total_output_words = 0;
    current_transaction = 0;
    current_word_count = 0;
    current_payload_seen = 0;
    current_destination = '0;
    current_lane_mask = '0;
    current_tag = '0;

    repeat (5) @(negedge clk);
    rst = 1'b0;
    repeat (2) @(negedge clk);
    if ($isunknown({descriptor_ready, s_axis_tready, busy, transfer_active,
                    transfer_done, descriptor_rejected, protocol_error,
                    completed_transfers}))
      $fatal(1, "DMA ingress reset left unknown outputs");

    reject_descriptor(2'd3, 10, 80, 8'hff);
    reject_descriptor(DEST_ACTIVATION_DIRECT, 0, 0, 8'hff);
    reject_descriptor(DEST_ACTIVATION_DIRECT, 1025, 8200, 8'hff);
    reject_descriptor(DEST_WEIGHT, 969, 7752, 8'hff);
    reject_descriptor(DEST_ACTIVATION_POOLED, 10, 79, 8'hff);
    reject_descriptor(DEST_WEIGHT, 10, 80, 8'h81);
    if (rejected_descriptors != 6 || !descriptor_error || !protocol_error)
      $fatal(1, "DMA descriptor rejection coverage mismatch");
    clear_errors();

    random_payload_stalls = 1'b1;
    run_transfer(0, DEST_ACTIVATION_DIRECT, 729, 8'hff, 16'h3100,
                 12, 1'b0);
    run_transfer(1, DEST_ACTIVATION_POOLED, 17, 8'h3f, 16'h3101,
                 5, 1'b0);
    run_transfer(2, DEST_WEIGHT, 200, 8'hff, 16'h4200,
                 9, 1'b0);
    if (protocol_error)
      $fatal(1, "valid DMA transfers raised a protocol error");

    run_transfer(3, DEST_ACTIVATION_DIRECT, 3, 8'h0f, 16'h3102,
                 0, 1'b1);
    if (!stream_error || !protocol_error || descriptor_error)
      $fatal(1, "malformed AXIS final beat was not isolated as stream error");
    clear_errors();

    random_payload_stalls = 1'b0;
    repeat (4) @(negedge clk);
    if (busy || transfer_active || !descriptor_ready || s_axis_tready ||
        completed_transfers != 4 || total_output_words != 949 ||
        axis_beats != 476 || rejected_descriptors != 6 ||
        activation_descriptor_commits != 3 ||
        weight_descriptor_commits != 1 || protocol_error)
      $fatal(1,
             "DMA ingress final state mismatch transfers=%0d words=%0d beats=%0d rejects=%0d activation=%0d weight=%0d",
             completed_transfers, total_output_words, axis_beats,
             rejected_descriptors, activation_descriptor_commits,
             weight_descriptor_commits);

    $display(
        "ALEXNET_N8_DMA_INGRESS_TEST_PASSED transfers=%0d words=%0d axis_beats=%0d rejects=%0d activation_commits=%0d weight_commits=%0d owner_wait_cycles=%0d maxstall=%0d stream_errors=1 seed=%0d",
        completed_transfers, total_output_words, axis_beats,
        rejected_descriptors, activation_descriptor_commits,
        weight_descriptor_commits, owner_wait_cycles, max_payload_stall,
        seed);
    $finish;
  end

endmodule
