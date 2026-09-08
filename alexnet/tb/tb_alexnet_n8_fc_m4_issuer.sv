`timescale 1ns/1ps

module tb_alexnet_n8_fc_m4_issuer;

  localparam int K_COUNT_W = 10;
  localparam int MAX_K = 968;

  logic clk = 1'b0;
  logic rst;

  logic descriptor_valid;
  logic descriptor_ready;
  logic [K_COUNT_W-1:0] descriptor_k_count;
  logic [2:0] descriptor_m_count;
  logic [7:0] descriptor_n_lane_mask;
  logic [15:0] descriptor_activation_tensor_tag;
  logic [15:0] descriptor_weight_context_tag;
  logic [15:0] descriptor_tile_tag;

  logic activation_valid;
  logic activation_ready;
  logic [63:0] activation_values;
  logic [7:0] activation_lane_mask;
  logic activation_last;
  logic [15:0] activation_tensor_tag;

  logic weight_replay_valid;
  logic weight_replay_ready;
  logic [K_COUNT_W-1:0] weight_replay_k_count;
  logic [7:0] weight_replay_n_lane_mask;
  logic [15:0] weight_replay_context_tag;

  logic weight_valid;
  logic weight_ready;
  logic signed [7:0] weight_values [0:7];
  logic [K_COUNT_W-1:0] weight_k;
  logic weight_last;
  logic [7:0] weight_n_lane_mask;
  logic [15:0] weight_context_tag;

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
  logic tile_done;

  logic issuer_idle;
  logic descriptor_active;
  logic descriptor_done;
  logic descriptor_rejected;
  logic protocol_error;
  logic [2:0] phase;
  logic [K_COUNT_W-1:0] active_k;
  logic [K_COUNT_W:0] activation_words_consumed;
  logic [15:0] accepted_descriptors;
  logic [15:0] completed_descriptors;
  logic [15:0] rejected_descriptors;
  logic [31:0] completed_k_tokens;

  logic signed [7:0] expected_activation [0:MAX_K-1][0:3];
  logic signed [7:0] expected_weight [0:MAX_K-1][0:7];
  int current_k_count;
  int current_m_count;
  logic [7:0] current_n_lane_mask;
  logic [15:0] current_activation_tag;
  logic [15:0] current_weight_tag;
  logic [15:0] current_tile_tag;
  int expected_issue_k;
  int tile_done_countdown;

  int descriptors_seen;
  int descriptors_completed;
  int descriptors_rejected_seen;
  int activation_words_seen;
  int replays_seen;
  int tiles_seen;
  int issues_seen;
  int replay_stall_cycles;
  int activation_stall_cycles;
  int tile_stall_cycles;
  int issue_stall_cycles;

  logic replay_held;
  logic [K_COUNT_W-1:0] held_replay_k_count;
  logic [7:0] held_replay_n_lane_mask;
  logic [15:0] held_replay_context_tag;
  logic tile_held;
  logic [2:0] held_tile_m_count;
  logic [7:0] held_tile_n_lane_mask;
  logic [15:0] held_tile_tag;
  logic issue_held;
  logic held_issue_last;
  logic [31:0] held_issue_activation;
  logic [63:0] held_issue_weight;

  alexnet_n8_fc_m4_issuer dut (.*);

  always #2.5 clk = ~clk;

  function automatic logic [7:0] low_mask(input int count);
    if (count >= 8)
      low_mask = 8'hff;
    else
      low_mask = (9'b1 << count) - 1'b1;
  endfunction

  function automatic logic [31:0] pack_issue_activation;
    pack_issue_activation = {
        issue_act_hi[1], issue_act_lo[1],
        issue_act_hi[0], issue_act_lo[0]};
  endfunction

  function automatic logic [63:0] pack_issue_weight;
    for (int lane = 0; lane < 8; lane++)
      pack_issue_weight[lane*8 +: 8] = issue_weight[lane];
  endfunction

  always @(negedge clk) begin
    if (rst) begin
      weight_replay_ready = 1'b0;
      tile_start_ready = 1'b0;
      issue_ready = 1'b0;
      tile_done = 1'b0;
      tile_done_countdown = 0;
    end else begin
      weight_replay_ready = $urandom_range(0, 3) != 0;
      tile_start_ready = $urandom_range(0, 4) != 0;
      issue_ready = $urandom_range(0, 3) != 0;
      tile_done = 1'b0;
      if (tile_done_countdown > 0) begin
        tile_done_countdown = tile_done_countdown - 1;
        if (tile_done_countdown == 0)
          tile_done = 1'b1;
      end
    end
  end

  always @(posedge clk) begin : scoreboard
    logic [31:0] expected_packed_activation;
    logic [63:0] expected_packed_weight;

    if (rst) begin
      descriptors_seen = 0;
      descriptors_completed = 0;
      descriptors_rejected_seen = 0;
      activation_words_seen = 0;
      replays_seen = 0;
      tiles_seen = 0;
      issues_seen = 0;
      replay_stall_cycles = 0;
      activation_stall_cycles = 0;
      tile_stall_cycles = 0;
      issue_stall_cycles = 0;
      expected_issue_k = 0;
      replay_held <= 1'b0;
      tile_held <= 1'b0;
      issue_held <= 1'b0;
    end else begin
      if (descriptor_valid && descriptor_ready)
        descriptors_seen = descriptors_seen + 1;
      if (descriptor_done)
        descriptors_completed = descriptors_completed + 1;
      if (descriptor_rejected)
        descriptors_rejected_seen = descriptors_rejected_seen + 1;
      if (activation_valid && activation_ready)
        activation_words_seen = activation_words_seen + 1;

      if (weight_replay_valid && !weight_replay_ready)
        replay_stall_cycles = replay_stall_cycles + 1;
      if (activation_valid && !activation_ready)
        activation_stall_cycles = activation_stall_cycles + 1;
      if (tile_start_valid && !tile_start_ready)
        tile_stall_cycles = tile_stall_cycles + 1;
      if (issue_valid && !issue_ready)
        issue_stall_cycles = issue_stall_cycles + 1;

      if (replay_held) begin
        if (!weight_replay_valid ||
            weight_replay_k_count != held_replay_k_count ||
            weight_replay_n_lane_mask != held_replay_n_lane_mask ||
            weight_replay_context_tag != held_replay_context_tag)
          $fatal(1, "FC replay request changed while stalled");
      end
      replay_held <= weight_replay_valid && !weight_replay_ready;
      if (weight_replay_valid && !weight_replay_ready) begin
        held_replay_k_count <= weight_replay_k_count;
        held_replay_n_lane_mask <= weight_replay_n_lane_mask;
        held_replay_context_tag <= weight_replay_context_tag;
      end

      if (tile_held) begin
        if (!tile_start_valid || tile_m_count != held_tile_m_count ||
            tile_n_lane_mask != held_tile_n_lane_mask ||
            tile_tag != held_tile_tag)
          $fatal(1, "FC tile descriptor changed while stalled");
      end
      tile_held <= tile_start_valid && !tile_start_ready;
      if (tile_start_valid && !tile_start_ready) begin
        held_tile_m_count <= tile_m_count;
        held_tile_n_lane_mask <= tile_n_lane_mask;
        held_tile_tag <= tile_tag;
      end

      if (issue_held) begin
        if (!issue_valid || issue_last != held_issue_last ||
            pack_issue_activation() != held_issue_activation ||
            pack_issue_weight() != held_issue_weight)
          $fatal(1, "FC issue payload changed while stalled");
      end
      issue_held <= issue_valid && !issue_ready;
      if (issue_valid && !issue_ready) begin
        held_issue_last <= issue_last;
        held_issue_activation <= pack_issue_activation();
        held_issue_weight <= pack_issue_weight();
      end

      if (weight_replay_valid && weight_replay_ready) begin
        replays_seen = replays_seen + 1;
        if (weight_replay_k_count != current_k_count ||
            weight_replay_n_lane_mask != current_n_lane_mask ||
            weight_replay_context_tag != current_weight_tag)
          $fatal(1, "FC replay descriptor mismatch");
      end

      if (tile_start_valid && tile_start_ready) begin
        tiles_seen = tiles_seen + 1;
        expected_issue_k = 0;
        if (tile_m_count != current_m_count ||
            tile_n_lane_mask != current_n_lane_mask ||
            tile_tag != current_tile_tag)
          $fatal(1, "FC tile-start descriptor mismatch");
      end

      if (issue_valid && issue_ready) begin
        expected_packed_activation = '0;
        expected_packed_weight = '0;
        for (int m = 0; m < 4; m++) begin
          if (m < current_m_count)
            expected_packed_activation[m*8 +: 8] =
                expected_activation[expected_issue_k][m];
        end
        for (int lane = 0; lane < 8; lane++) begin
          if (current_n_lane_mask[lane])
            expected_packed_weight[lane*8 +: 8] =
                expected_weight[expected_issue_k][lane];
        end
        if (active_k != expected_issue_k ||
            pack_issue_activation() != expected_packed_activation ||
            pack_issue_weight() != expected_packed_weight ||
            issue_last != (expected_issue_k + 1 == current_k_count))
          $fatal(1, "FC K issue mismatch at k=%0d", expected_issue_k);
        expected_issue_k = expected_issue_k + 1;
        issues_seen = issues_seen + 1;
        if (issue_last)
          tile_done_countdown = 2 + $urandom_range(0, 3);
      end
    end
  end

  task automatic submit_descriptor(
      input int k_count,
      input int m_count,
      input logic [7:0] n_lane_mask,
      input logic [15:0] activation_tag,
      input logic [15:0] weight_tag,
      input logic [15:0] requested_tile_tag);
    begin
      @(negedge clk);
      descriptor_k_count = k_count;
      descriptor_m_count = m_count;
      descriptor_n_lane_mask = n_lane_mask;
      descriptor_activation_tensor_tag = activation_tag;
      descriptor_weight_context_tag = weight_tag;
      descriptor_tile_tag = requested_tile_tag;
      descriptor_valid = 1'b1;
      do @(posedge clk); while (!descriptor_ready);
      @(negedge clk);
      descriptor_valid = 1'b0;
    end
  endtask

  task automatic send_activation_stream(
      input int k_count,
      input int m_count,
      input logic [15:0] activation_tag,
      input bit inject_bad_tag);
    logic [63:0] packed_word;
    logic [7:0] block_mask;
    int block_count;
    begin
      block_count = (k_count + 7) / 8;
      for (int block = 0; block < block_count; block++) begin
        block_mask = low_mask(k_count - block * 8);
        for (int m = 0; m < m_count; m++) begin
          packed_word = '0;
          for (int lane = 0; lane < 8; lane++) begin
            if (block * 8 + lane < k_count)
              packed_word[lane*8 +: 8] =
                  expected_activation[block * 8 + lane][m];
          end
          repeat ($urandom_range(0, 2)) @(negedge clk);
          activation_values = packed_word;
          activation_lane_mask = block_mask;
          activation_last =
              (block + 1 == block_count) && (m + 1 == m_count);
          activation_tensor_tag =
              (inject_bad_tag && block == 0 && m == 0) ?
                  activation_tag + 1'b1 : activation_tag;
          activation_valid = 1'b1;
          do @(posedge clk); while (!activation_ready);
          @(negedge clk);
          activation_valid = 1'b0;
        end
      end
    end
  endtask

  task automatic send_weight_stream(
      input int k_count,
      input logic [7:0] n_lane_mask,
      input logic [15:0] weight_tag,
      input bit inject_bad_k);
    begin
      do @(posedge clk); while (!(weight_replay_valid &&
                                  weight_replay_ready));
      for (int k = 0; k < k_count; k++) begin
        repeat ($urandom_range(0, 2)) @(negedge clk);
        for (int lane = 0; lane < 8; lane++) begin
          if (n_lane_mask[lane])
            weight_values[lane] = expected_weight[k][lane];
          else
            weight_values[lane] = '0;
        end
        weight_k = (inject_bad_k && k == 3) ? k + 1 : k;
        weight_last = k + 1 == k_count;
        weight_n_lane_mask = n_lane_mask;
        weight_context_tag = weight_tag;
        weight_valid = 1'b1;
        do @(posedge clk); while (!weight_ready);
        @(negedge clk);
        weight_valid = 1'b0;
      end
    end
  endtask

  task automatic run_case(
      input int case_id,
      input int k_count,
      input int m_count,
      input logic [7:0] n_lane_mask,
      input bit inject_source_error);
    int completed_before;
    int words_before;
    begin
      current_k_count = k_count;
      current_m_count = m_count;
      current_n_lane_mask = n_lane_mask;
      current_activation_tag = 16'h1000 + case_id;
      current_weight_tag = 16'h2000 + case_id;
      current_tile_tag = 16'h3000 + case_id;
      for (int k = 0; k < k_count; k++) begin
        for (int m = 0; m < 4; m++)
          expected_activation[k][m] =
              $signed(((case_id * 19 + k * 7 + m * 3) % 31) - 15);
        for (int lane = 0; lane < 8; lane++)
          expected_weight[k][lane] =
              $signed(((case_id * 13 + k * 5 + lane * 11) % 29) - 14);
      end

      completed_before = descriptors_completed;
      words_before = activation_words_seen;
      fork
        submit_descriptor(k_count, m_count, n_lane_mask,
                          current_activation_tag, current_weight_tag,
                          current_tile_tag);
        send_activation_stream(k_count, m_count, current_activation_tag,
                               inject_source_error);
        send_weight_stream(k_count, n_lane_mask, current_weight_tag,
                           inject_source_error);
      join

      while (descriptors_completed == completed_before)
        @(negedge clk);
      if (expected_issue_k != k_count)
        $fatal(1, "FC case %0d issued %0d/%0d K tokens",
               case_id, expected_issue_k, k_count);
      if (activation_words_seen - words_before !=
          ((k_count + 7) / 8) * m_count)
        $fatal(1, "FC case %0d activation word-count mismatch", case_id);
      if (!inject_source_error && protocol_error)
        $fatal(1, "FC case %0d unexpectedly raised protocol_error", case_id);
      if (inject_source_error && !protocol_error)
        $fatal(1, "FC malformed source metadata was not reported");
      while (!issuer_idle)
        @(negedge clk);
      @(negedge clk);
    end
  endtask

  initial begin
    int seed;
    int seed_sink;
    int timeout;
    int replay_before;

    rst = 1'b1;
    descriptor_valid = 1'b0;
    descriptor_k_count = '0;
    descriptor_m_count = '0;
    descriptor_n_lane_mask = '0;
    descriptor_activation_tensor_tag = '0;
    descriptor_weight_context_tag = '0;
    descriptor_tile_tag = '0;
    activation_valid = 1'b0;
    activation_values = '0;
    activation_lane_mask = '0;
    activation_last = 1'b0;
    activation_tensor_tag = '0;
    weight_replay_ready = 1'b0;
    weight_valid = 1'b0;
    weight_k = '0;
    weight_last = 1'b0;
    weight_n_lane_mask = '0;
    weight_context_tag = '0;
    tile_start_ready = 1'b0;
    issue_ready = 1'b0;
    tile_done = 1'b0;
    current_k_count = 0;
    current_m_count = 0;
    current_n_lane_mask = '0;
    current_activation_tag = '0;
    current_weight_tag = '0;
    current_tile_tag = '0;
    tile_done_countdown = 0;
    for (int lane = 0; lane < 8; lane++)
      weight_values[lane] = '0;

    seed = 32'h7f31_5ac9;
    seed_sink = $urandom(seed);
    repeat (5) @(negedge clk);
    rst = 1'b0;
    @(negedge clk);

    replay_before = replays_seen;
    submit_descriptor(0, 0, 8'h00, 16'hdead, 16'hbeef, 16'hffff);
    while (!descriptor_rejected)
      @(negedge clk);
    if (replays_seen != replay_before || weight_replay_valid ||
        activation_ready || tile_start_valid || issue_valid)
      $fatal(1, "invalid FC descriptor reached a child owner");

    run_case(1, 968, 4, 8'hff, 1'b0);
    run_case(2, 10, 3, 8'h1f, 1'b0);
    run_case(3, 9, 1, 8'h01, 1'b0);
    run_case(4, 7, 2, 8'h03, 1'b1);

    timeout = 0;
    while ((!issuer_idle || descriptor_active || weight_valid ||
            tile_done_countdown != 0) && timeout < 1000) begin
      @(negedge clk);
      timeout = timeout + 1;
    end
    if (timeout == 1000)
      $fatal(1, "FC issuer did not return idle");
    if (descriptors_seen != 5 || descriptors_completed != 4 ||
        descriptors_rejected_seen != 1 || replays_seen != 4 ||
        tiles_seen != 4 || issues_seen != 994 ||
        activation_words_seen != 494)
      $fatal(1, "FC issuer final scoreboard mismatch");
    if (accepted_descriptors != 5 || completed_descriptors != 4 ||
        rejected_descriptors != 1 || completed_k_tokens != 994)
      $fatal(1, "FC issuer hardware counters mismatch");

    $display(
        "ALEXNET_N8_FC_M4_ISSUER_TEST_PASSED descriptors=%0d completed=%0d rejected=%0d replays=%0d activation_words=%0d tiles=%0d k_tokens=%0d replay_stall_cycles=%0d activation_stall_cycles=%0d tile_stall_cycles=%0d issue_stall_cycles=%0d source_metadata_errors=2 seed=%0d",
        descriptors_seen, descriptors_completed, descriptors_rejected_seen,
        replays_seen, activation_words_seen, tiles_seen, issues_seen,
        replay_stall_cycles, activation_stall_cycles, tile_stall_cycles,
        issue_stall_cycles, seed);
    $finish;
  end

endmodule
