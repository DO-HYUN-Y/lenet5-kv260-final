`timescale 1ns/1ps

module tb_alexnet_m16_patch_pingpong;

  localparam int DEPTH = 64;
  localparam int ADDR_W = $clog2(DEPTH);
  localparam int COUNT_W = $clog2(DEPTH + 1);

  logic clk = 1'b0;
  logic rst;
  logic fill_valid;
  logic fill_ready;
  logic [COUNT_W-1:0] fill_k_count;
  logic [15:0] fill_m_lane_mask;
  logic [15:0] fill_context_tag;
  logic write_valid;
  logic write_ready;
  logic [127:0] write_values;
  logic write_last;
  logic [ADDR_W-1:0] write_k;
  logic replay_valid;
  logic replay_ready;
  logic [COUNT_W-1:0] replay_k_count;
  logic [15:0] replay_m_lane_mask;
  logic [15:0] replay_context_tag;
  logic patch_valid;
  logic patch_ready;
  logic signed [7:0] patch_values [0:15];
  logic [ADDR_W-1:0] patch_k;
  logic patch_last;
  logic [15:0] patch_m_lane_mask;
  logic [15:0] patch_context_tag;
  logic [1:0] set_state [0:1];
  logic [1:0] ready_set_mask;
  logic fill_active;
  logic active_fill_set;
  logic replay_active;
  logic active_replay_set;
  logic [COUNT_W-1:0] words_written;
  logic [15:0] completed_fills;
  logic [15:0] completed_replays;
  logic fill_done;
  logic replay_done;
  logic context_error;
  logic protocol_error;
  logic idle;

  logic [127:0] expected_memory [0:1][0:DEPTH-1];
  int overlap_cycles;
  int replay_words;
  int max_stall;

  alexnet_m16_patch_pingpong #(
      .DEPTH(DEPTH), .ADDR_W(ADDR_W), .COUNT_W(COUNT_W)
  ) dut (.*);

  always #2.5 clk = ~clk;

  always_ff @(posedge clk)
    if (rst)
      overlap_cycles <= 0;
    else if (fill_active && replay_active)
      overlap_cycles <= overlap_cycles + 1;

  function automatic logic [127:0] make_word(
      input int tag,
      input int k);
    logic [127:0] result;
    begin
      result = '0;
      for (int lane = 0; lane < 16; lane++)
        result[lane*8 +: 8] =
            (tag * 17 + k * 31 + lane * 13) & 8'hff;
      make_word = result;
    end
  endfunction

  function automatic logic [127:0] mask_word(
      input logic [127:0] value,
      input logic [15:0] lane_mask);
    logic [127:0] result;
    begin
      result = '0;
      for (int lane = 0; lane < 16; lane++)
        if (lane_mask[lane])
          result[lane*8 +: 8] = value[lane*8 +: 8];
      mask_word = result;
    end
  endfunction

  function automatic logic [127:0] pack_patch_output;
    logic [127:0] result;
    begin
      result = '0;
      for (int lane = 0; lane < 16; lane++)
        result[lane*8 +: 8] = patch_values[lane];
      pack_patch_output = result;
    end
  endfunction

  task automatic fill_transaction(
      input int set_index,
      input int tag,
      input int k_count,
      input logic [15:0] lane_mask,
      input bit random_gaps);
    logic [127:0] raw_word;
    bit pending;
    begin
      @(negedge clk);
      fill_valid = 1'b1;
      fill_k_count = k_count;
      fill_m_lane_mask = lane_mask;
      fill_context_tag = tag;
      #1;
      if (!fill_ready)
        $fatal(1, "patch fill descriptor was not accepted tag=%0d", tag);
      @(posedge clk);
      @(negedge clk);
      fill_valid = 1'b0;
      if (active_fill_set != set_index)
        $fatal(1, "patch fill selected set %0d expected %0d",
               active_fill_set, set_index);

      pending = 1'b0;
      for (int k = 0; k < k_count; k++) begin
        while (!pending) begin
          @(negedge clk);
          pending = !random_gaps || $urandom_range(0, 3) != 0;
          write_valid = pending;
        end
        raw_word = make_word(tag, k);
        write_values = raw_word;
        write_last = k == k_count - 1;
        #1;
        if (!write_ready || write_k != k)
          $fatal(1, "patch write cursor mismatch rtl=%0d expected=%0d",
                 write_k, k);
        @(posedge clk);
        expected_memory[set_index][k] = mask_word(raw_word, lane_mask);
        pending = 1'b0;
        @(negedge clk);
        write_valid = 1'b0;
      end

      if (fill_active || set_state[set_index] != 2 ||
          words_written != k_count || !fill_done)
        $fatal(1, "patch fill completion mismatch set=%0d", set_index);
    end
  endtask

  task automatic replay_transaction(
      input int set_index,
      input int tag,
      input int k_count,
      input logic [15:0] lane_mask,
      input bit apply_stalls);
    logic [127:0] held_values;
    logic [ADDR_W-1:0] held_k;
    logic held_last;
    bit holding;
    bit fire;
    bit first_seen;
    int accepted;
    int cycles;
    int stall_run;
    begin
      @(negedge clk);
      replay_valid = 1'b1;
      replay_k_count = k_count;
      replay_m_lane_mask = lane_mask;
      replay_context_tag = tag;
      #1;
      if (!replay_ready)
        $fatal(1, "patch replay descriptor was not accepted tag=%0d", tag);
      @(posedge clk);
      @(negedge clk);
      replay_valid = 1'b0;
      if (active_replay_set != set_index)
        $fatal(1, "patch replay selected set %0d expected %0d",
               active_replay_set, set_index);

      holding = 1'b0;
      first_seen = 1'b0;
      accepted = 0;
      cycles = 0;
      stall_run = 0;
      while (accepted < k_count) begin
        @(negedge clk);
        patch_ready = !apply_stalls || ((cycles % 13) >= 3 &&
                      $urandom_range(0, 4) != 0);
        #1;
        if (!apply_stalls && first_seen && !patch_valid)
          $fatal(1, "patch replay inserted a steady-state bubble k=%0d",
                 accepted);
        if (holding && (!patch_valid ||
                        pack_patch_output() != held_values ||
                        patch_k != held_k || patch_last != held_last))
          $fatal(1, "patch output changed under backpressure");

        if (patch_valid) begin
          first_seen = 1'b1;
          if (patch_k != accepted ||
              pack_patch_output() != expected_memory[set_index][accepted] ||
              patch_m_lane_mask != lane_mask ||
              patch_context_tag != tag ||
              patch_last != (accepted == k_count - 1))
            $fatal(1, "patch replay mismatch set=%0d k=%0d",
                   set_index, accepted);
        end

        fire = patch_valid && patch_ready;
        if (patch_valid && !patch_ready) begin
          holding = 1'b1;
          held_values = pack_patch_output();
          held_k = patch_k;
          held_last = patch_last;
          stall_run = stall_run + 1;
          if (stall_run > max_stall)
            max_stall = stall_run;
        end else begin
          holding = 1'b0;
          stall_run = 0;
        end

        @(posedge clk);
        if (fire) begin
          accepted = accepted + 1;
          replay_words = replay_words + 1;
        end
        cycles = cycles + 1;
        if (cycles > 10000)
          $fatal(1, "patch replay timeout tag=%0d", tag);
      end

      @(negedge clk);
      patch_ready = 1'b0;
      if (!replay_done || replay_active || set_state[set_index] != 0)
        $fatal(1, "patch replay did not release set %0d", set_index);
    end
  endtask

  initial begin
    rst = 1'b1;
    fill_valid = 1'b0;
    fill_k_count = '0;
    fill_m_lane_mask = '0;
    fill_context_tag = '0;
    write_valid = 1'b0;
    write_values = '0;
    write_last = 1'b0;
    replay_valid = 1'b0;
    replay_k_count = '0;
    replay_m_lane_mask = '0;
    replay_context_tag = '0;
    patch_ready = 1'b0;
    replay_words = 0;
    max_stall = 0;
    repeat (8) @(posedge clk);
    rst = 1'b0;

    fill_transaction(0, 16'h1101, 17, 16'hffff, 1'b1);
    fork
      replay_transaction(0, 16'h1101, 17, 16'hffff, 1'b1);
      fill_transaction(1, 16'h2202, 23, 16'h03ff, 1'b1);
    join
    replay_transaction(1, 16'h2202, 23, 16'h03ff, 1'b0);

    if (!idle || protocol_error || context_error)
      $fatal(1, "patch ping-pong did not finish cleanly");
    if (completed_fills != 2 || completed_replays != 2 ||
        replay_words != 40 || overlap_cycles == 0 || max_stall == 0)
      $fatal(1, "patch coverage counters did not close");

    $display("ALEXNET_M16_PATCH_PINGPONG_TEST_PASSED fills=%0d replays=%0d words=%0d overlap=%0d max_stall=%0d",
             completed_fills, completed_replays, replay_words,
             overlap_cycles, max_stall);
    $finish;
  end

endmodule
