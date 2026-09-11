`timescale 1ns/1ps

module tb_alexnet_n128_weight_pingpong;

  localparam int DEPTH = 64;
  localparam int ADDR_W = $clog2(DEPTH);
  localparam int COUNT_W = $clog2(DEPTH + 1);
  localparam int WRITE_COUNT_W = $clog2(8 * DEPTH + 1);

  logic clk = 1'b0;
  logic rst;
  logic fill_valid;
  logic fill_ready;
  logic [COUNT_W-1:0] fill_k_count;
  logic [7:0] fill_bank_enable;
  logic [15:0] fill_n_lane_mask [0:7];
  logic [15:0] fill_context_tag;
  logic write_valid;
  logic write_ready;
  logic [127:0] write_values;
  logic write_last;
  logic [ADDR_W-1:0] write_k;
  logic [2:0] write_bank_slot;
  logic replay_valid;
  logic replay_ready;
  logic [COUNT_W-1:0] replay_k_count;
  logic [7:0] replay_bank_enable;
  logic [15:0] replay_n_lane_mask [0:7];
  logic [15:0] replay_context_tag;
  logic weight_valid;
  logic weight_ready;
  logic signed [7:0] weight_values [0:7][0:15];
  logic [ADDR_W-1:0] weight_k;
  logic weight_last;
  logic [7:0] weight_bank_enable;
  logic [15:0] weight_n_lane_mask [0:7];
  logic [15:0] weight_context_tag;
  logic release_valid;
  logic release_ready;
  logic [15:0] release_context_tag;
  logic [1:0] set_state [0:1];
  logic [1:0] ready_set_mask;
  logic fill_active;
  logic active_fill_set;
  logic replay_active;
  logic active_replay_set;
  logic [WRITE_COUNT_W-1:0] words_written;
  logic [15:0] completed_fills;
  logic [15:0] completed_replays;
  logic fill_done;
  logic replay_done;
  logic context_error;
  logic protocol_error;
  logic idle;

  logic [127:0] expected_memory [0:1][0:7][0:DEPTH-1];
  int overlap_cycles;
  int replay_words;
  int max_stall;

  alexnet_n128_weight_pingpong #(
      .DEPTH(DEPTH),
      .ADDR_W(ADDR_W),
      .COUNT_W(COUNT_W),
      .WRITE_COUNT_W(WRITE_COUNT_W)
  ) dut (.*);

  always #2.5 clk = ~clk;

  always_ff @(posedge clk)
    if (rst)
      overlap_cycles <= 0;
    else if (fill_active && replay_active)
      overlap_cycles <= overlap_cycles + 1;

  function automatic logic [15:0] lane_mask_for(
      input logic [7:0] bank_enable,
      input int bank,
      input int tail_bank,
      input logic [15:0] tail_mask);
    begin
      if (!bank_enable[bank])
        lane_mask_for = 16'h0000;
      else if (bank == tail_bank)
        lane_mask_for = tail_mask;
      else
        lane_mask_for = 16'hffff;
    end
  endfunction

  function automatic logic is_final_enabled_bank(
      input logic [7:0] bank_enable,
      input int bank);
    logic higher;
    begin
      higher = 1'b0;
      for (int candidate = bank + 1; candidate < 8; candidate++)
        if (bank_enable[candidate])
          higher = 1'b1;
      is_final_enabled_bank = !higher;
    end
  endfunction

  function automatic logic [127:0] make_word(
      input int tag,
      input int k,
      input int bank);
    logic [127:0] result;
    int value;
    begin
      result = '0;
      for (int lane = 0; lane < 16; lane++) begin
        value = (tag * 29 + k * 47 + bank * 71 + lane * 13) & 8'hff;
        if (k == 0 && bank == 0 && lane == 0)
          value = 8'h80;
        else if (k == 0 && bank == 0 && lane == 1)
          value = 8'h7f;
        result[lane*8 +: 8] = value[7:0];
      end
      make_word = result;
    end
  endfunction

  function automatic logic [1023:0] pack_weight_output;
    logic [1023:0] result;
    begin
      result = '0;
      for (int bank = 0; bank < 8; bank++)
        for (int lane = 0; lane < 16; lane++)
          result[(bank*16 + lane)*8 +: 8] =
              weight_values[bank][lane];
      pack_weight_output = result;
    end
  endfunction

  function automatic logic [1023:0] expected_replay_word(
      input int set_index,
      input int k,
      input logic [7:0] bank_enable);
    logic [1023:0] result;
    begin
      result = '0;
      for (int bank = 0; bank < 8; bank++)
        if (bank_enable[bank])
          result[bank*128 +: 128] = expected_memory[set_index][bank][k];
      expected_replay_word = result;
    end
  endfunction

  task automatic drive_fill_descriptor(
      input int tag,
      input int k_count,
      input logic [7:0] bank_enable,
      input int tail_bank,
      input logic [15:0] tail_mask);
    begin
      @(negedge clk);
      fill_valid = 1'b1;
      fill_k_count = k_count;
      fill_bank_enable = bank_enable;
      fill_context_tag = tag;
      for (int bank = 0; bank < 8; bank++)
        fill_n_lane_mask[bank] = lane_mask_for(
            bank_enable, bank, tail_bank, tail_mask);
      #1;
      if (!fill_ready)
        $fatal(1, "N128 fill descriptor was not accepted tag=%0d", tag);
      @(posedge clk);
      @(negedge clk);
      fill_valid = 1'b0;
    end
  endtask

  task automatic fill_transaction(
      input int set_index,
      input int tag,
      input int k_count,
      input logic [7:0] bank_enable,
      input int tail_bank,
      input logic [15:0] tail_mask,
      input bit random_gaps);
    logic [127:0] raw_word;
    logic [127:0] masked_word;
    logic [15:0] current_lane_mask;
    logic pending;
    int written;
    begin
      drive_fill_descriptor(
          tag, k_count, bank_enable, tail_bank, tail_mask);
      if (active_fill_set != set_index)
        $fatal(1, "N128 fill selected set %0d expected %0d",
               active_fill_set, set_index);

      written = 0;
      pending = 1'b0;
      for (int k = 0; k < k_count; k++) begin
        for (int bank = 0; bank < 8; bank++) begin
          if (bank_enable[bank]) begin
            while (!pending) begin
              @(negedge clk);
              pending = !random_gaps || $urandom_range(0, 3) != 0;
              write_valid = pending;
            end

            raw_word = make_word(tag, k, bank);
            masked_word = '0;
            current_lane_mask = lane_mask_for(
                bank_enable, bank, tail_bank, tail_mask);
            for (int lane = 0; lane < 16; lane++)
              if (current_lane_mask[lane])
                masked_word[lane*8 +: 8] = raw_word[lane*8 +: 8];
            write_values = raw_word;
            write_last = k == k_count - 1 &&
                         is_final_enabled_bank(bank_enable, bank);
            #1;
            if (!write_ready || write_k != k || write_bank_slot != bank)
              $fatal(1,
                     "N128 write cursor mismatch rtl=%0d/%0d expected=%0d/%0d",
                     write_k, write_bank_slot, k, bank);
            @(posedge clk);
            expected_memory[set_index][bank][k] = masked_word;
            written = written + 1;
            pending = 1'b0;
            @(negedge clk);
            write_valid = 1'b0;
          end
        end
      end

      if (fill_active || set_state[set_index] != 2 ||
          words_written != written || !fill_done)
        $fatal(1,
               "N128 fill completion mismatch set=%0d state=%0d words=%0d/%0d done=%0b",
               set_index, set_state[set_index], words_written, written,
               fill_done);
    end
  endtask

  task automatic drive_replay_descriptor(
      input int tag,
      input int k_count,
      input logic [7:0] bank_enable,
      input int tail_bank,
      input logic [15:0] tail_mask);
    begin
      @(negedge clk);
      replay_valid = 1'b1;
      replay_k_count = k_count;
      replay_bank_enable = bank_enable;
      replay_context_tag = tag;
      for (int bank = 0; bank < 8; bank++)
        replay_n_lane_mask[bank] = lane_mask_for(
            bank_enable, bank, tail_bank, tail_mask);
      #1;
      if (!replay_ready)
        $fatal(1, "N128 replay descriptor was not accepted tag=%0d", tag);
      @(posedge clk);
      @(negedge clk);
      replay_valid = 1'b0;
    end
  endtask

  task automatic replay_transaction(
      input int set_index,
      input int tag,
      input int k_count,
      input logic [7:0] bank_enable,
      input int tail_bank,
      input logic [15:0] tail_mask,
      input bit apply_stalls);
    logic [1023:0] held_values;
    logic [ADDR_W-1:0] held_k;
    logic held_last;
    logic holding;
    logic fire;
    int accepted;
    int cycles;
    int stall_run;
    bit first_seen;
    begin
      drive_replay_descriptor(
          tag, k_count, bank_enable, tail_bank, tail_mask);
      if (active_replay_set != set_index)
        $fatal(1, "N128 replay selected set %0d expected %0d",
               active_replay_set, set_index);

      accepted = 0;
      cycles = 0;
      stall_run = 0;
      holding = 1'b0;
      first_seen = 1'b0;
      while (accepted < k_count) begin
        @(negedge clk);
        weight_ready = !apply_stalls || ((cycles % 19) >= 5 &&
                       $urandom_range(0, 5) != 0);
        #1;
        if (!apply_stalls && first_seen && !weight_valid)
          $fatal(1, "N128 replay inserted a steady-state bubble k=%0d",
                 accepted);
        if (holding && (!weight_valid ||
                        pack_weight_output() != held_values ||
                        weight_k != held_k || weight_last != held_last))
          $fatal(1, "N128 replay output changed under backpressure");

        if (weight_valid) begin
          first_seen = 1'b1;
          if (weight_k != accepted ||
              pack_weight_output() !=
              expected_replay_word(set_index, accepted, bank_enable) ||
              weight_bank_enable != bank_enable ||
              weight_context_tag != tag ||
              weight_last != (accepted == k_count - 1))
            $fatal(1, "N128 replay mismatch set=%0d k=%0d", set_index,
                   accepted);
          for (int bank = 0; bank < 8; bank++)
            if (weight_n_lane_mask[bank] != lane_mask_for(
                bank_enable, bank, tail_bank, tail_mask))
              $fatal(1, "N128 replay lane-mask mismatch bank=%0d", bank);
        end

        fire = weight_valid && weight_ready;
        if (weight_valid && !weight_ready) begin
          holding = 1'b1;
          held_values = pack_weight_output();
          held_k = weight_k;
          held_last = weight_last;
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
          $fatal(1, "N128 replay timeout tag=%0d", tag);
      end

      @(negedge clk);
      weight_ready = 1'b0;
      if (!replay_done || replay_active || set_state[set_index] != 2)
        $fatal(1, "N128 replay did not return set %0d to READY", set_index);
    end
  endtask

  task automatic release_set(input int tag);
    begin
      @(negedge clk);
      release_valid = 1'b1;
      release_context_tag = tag;
      #1;
      if (!release_ready)
        $fatal(1, "N128 release was not accepted tag=%0d", tag);
      @(posedge clk);
      @(negedge clk);
      release_valid = 1'b0;
    end
  endtask

  initial begin
    rst = 1'b1;
    fill_valid = 1'b0;
    fill_k_count = '0;
    fill_bank_enable = '0;
    fill_context_tag = '0;
    write_valid = 1'b0;
    write_values = '0;
    write_last = 1'b0;
    replay_valid = 1'b0;
    replay_k_count = '0;
    replay_bank_enable = '0;
    replay_context_tag = '0;
    weight_ready = 1'b0;
    release_valid = 1'b0;
    release_context_tag = '0;
    replay_words = 0;
    max_stall = 0;
    for (int bank = 0; bank < 8; bank++) begin
      fill_n_lane_mask[bank] = '0;
      replay_n_lane_mask[bank] = '0;
    end

    repeat (8) @(posedge clk);
    @(negedge clk);
    rst = 1'b0;
    if (!idle || !fill_ready || ready_set_mask != 0)
      $fatal(1, "N128 ping-pong reset state mismatch");

    drive_fill_descriptor(50, 2, 8'h01, 0, 16'hffff);
    @(negedge clk);
    write_valid = 1'b1;
    write_values = make_word(50, 0, 0);
    write_last = 1'b1;
    #1;
    if (!write_ready)
      $fatal(1, "N128 malformed write was not sampled");
    @(posedge clk);
    @(negedge clk);
    write_valid = 1'b0;
    write_last = 1'b0;
    if (!protocol_error || fill_active || set_state[0] != 0)
      $fatal(1, "N128 malformed write did not abort the fill");

    fill_transaction(0, 100, 31, 8'hff, 7, 16'h00ff, 1'b1);

    @(negedge clk);
    replay_valid = 1'b1;
    replay_k_count = 31;
    replay_bank_enable = 8'hff;
    replay_context_tag = 101;
    for (int bank = 0; bank < 8; bank++)
      replay_n_lane_mask[bank] = lane_mask_for(
          8'hff, bank, 7, 16'h00ff);
    #1;
    if (replay_ready)
      $fatal(1, "N128 mismatched context was accepted");
    @(posedge clk);
    @(negedge clk);
    replay_valid = 1'b0;
    if (!context_error)
      $fatal(1, "N128 context mismatch was not latched");

    fork
      replay_transaction(0, 100, 31, 8'hff, 7, 16'h00ff, 1'b1);
      fill_transaction(1, 200, 11, 8'h0f, 3, 16'h0007, 1'b1);
    join

    release_set(100);

    fork
      replay_transaction(1, 200, 11, 8'h0f, 3, 16'h0007, 1'b0);
      fill_transaction(0, 300, 9, 8'h55, 6, 16'h0fff, 1'b0);
    join

    release_set(200);
    replay_transaction(0, 300, 9, 8'h55, 6, 16'h0fff, 1'b1);
    release_set(300);

    if (!idle || completed_fills != 3 || completed_replays != 3 ||
        replay_words != 51 || overlap_cycles == 0 || protocol_error)
      $fatal(1,
             "N128 final status mismatch fills=%0d replays=%0d words=%0d overlap=%0d idle=%0b",
             completed_fills, completed_replays, replay_words,
             overlap_cycles, idle);

    $display("ALEXNET_N128_WEIGHT_PINGPONG_TEST_PASSED fills=%0d replays=%0d words=%0d overlap_cycles=%0d maxstall=%0d",
             completed_fills, completed_replays, replay_words,
             overlap_cycles, max_stall);
    $finish;
  end

endmodule
