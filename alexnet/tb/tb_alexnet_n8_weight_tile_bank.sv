`timescale 1ns/1ps

module tb_alexnet_n8_weight_tile_bank;

  localparam int DEPTH = 968;
  localparam int ADDR_W = $clog2(DEPTH);
  localparam int COUNT_W = $clog2(DEPTH + 1);

  import "DPI-C" function int alexnet_golden_weight_tile_bank_reset(
      input int depth);
  import "DPI-C" function int alexnet_golden_weight_tile_bank_begin_fill(
      input int k_count, input byte n_lane_mask, input int context_tag);
  import "DPI-C" function int alexnet_golden_weight_tile_bank_write(
      input longint unsigned values, input byte n_lane_mask, input byte last);
  import "DPI-C" function int alexnet_golden_weight_tile_bank_begin_replay(
      input int k_count, input byte n_lane_mask, input int context_tag);
  import "DPI-C" function int alexnet_golden_weight_tile_bank_word(
      input int k, output longint unsigned values,
      output byte n_lane_mask, output byte last, output int context_tag);
  import "DPI-C" function int
      alexnet_golden_weight_tile_bank_complete_replay();
  import "DPI-C" function int alexnet_golden_weight_tile_bank_release();
  import "DPI-C" function int alexnet_golden_weight_tile_bank_state(
      output byte state, output int words_written,
      output int completed_replays);

  logic clk = 1'b0;
  logic rst;
  logic fill_valid;
  logic fill_ready;
  logic [COUNT_W-1:0] fill_k_count;
  logic [7:0] fill_n_lane_mask;
  logic [15:0] fill_context_tag;
  logic write_valid;
  logic write_ready;
  logic [63:0] write_values;
  logic [7:0] write_n_lane_mask;
  logic write_last;
  logic replay_valid;
  logic replay_ready;
  logic [COUNT_W-1:0] replay_k_count;
  logic [7:0] replay_n_lane_mask;
  logic [15:0] replay_context_tag;
  logic weight_valid;
  logic weight_ready;
  logic signed [7:0] weight_values [0:7];
  logic [ADDR_W-1:0] weight_k;
  logic weight_last;
  logic [7:0] weight_n_lane_mask;
  logic [15:0] weight_context_tag;
  logic release_valid;
  logic release_ready;
  logic [1:0] bank_state;
  logic resident_valid;
  logic [COUNT_W-1:0] resident_k_count;
  logic [7:0] resident_n_lane_mask;
  logic [15:0] resident_context_tag;
  logic [COUNT_W-1:0] words_written;
  logic [15:0] completed_replays;
  logic replay_done;
  logic context_error;
  logic idle;

  int transactions;
  int total_replays;
  int total_replay_words;
  int mismatch_attempts;
  int max_stall;
  int stall_run;
  logic hold_active;
  logic [63:0] hold_values;
  logic [ADDR_W-1:0] hold_k;
  logic hold_last;
  logic [7:0] hold_mask;
  logic [15:0] hold_tag;

  alexnet_n8_weight_tile_bank #(
      .DEPTH(DEPTH)
  ) dut (.*);

  always #2.5 clk = ~clk;

  function automatic logic [63:0] make_word(
      input int transaction_index,
      input int k_index);
    logic [63:0] result;
    int value;
    begin
      result = '0;
      for (int lane = 0; lane < 8; lane++) begin
        value = (transaction_index * 83 + k_index * 37 + lane * 59) & 8'hff;
        if (k_index == 0 && lane == 0)
          value = 8'h80;
        else if (k_index == 0 && lane == 1)
          value = 8'h7f;
        result[lane*8 +: 8] = value[7:0];
      end
      make_word = result;
    end
  endfunction

  function automatic logic [63:0] pack_weight_output;
    logic [63:0] packed_result;
    begin
      packed_result = '0;
      for (int lane = 0; lane < 8; lane++)
        packed_result[lane*8 +: 8] = weight_values[lane];
      pack_weight_output = packed_result;
    end
  endfunction

  task automatic check_state;
    byte golden_state;
    int golden_written;
    int golden_replays;
    int status;
    begin
      status = alexnet_golden_weight_tile_bank_state(
          golden_state, golden_written, golden_replays);
      if (status != 0 || bank_state != golden_state[1:0] ||
          words_written != golden_written ||
          completed_replays != golden_replays)
        $fatal(1,
               "weight state mismatch rtl=%0d/%0d/%0d golden=%0d/%0d/%0d status=%0d",
               bank_state, words_written, completed_replays, golden_state,
               golden_written, golden_replays, status);
    end
  endtask

  task automatic check_weight_output;
    longint unsigned golden_values;
    byte golden_mask;
    byte golden_last;
    int golden_tag;
    int status;
    logic [63:0] packed_values;
    begin
      packed_values = pack_weight_output();
      if (hold_active) begin
        if (!weight_valid || packed_values != hold_values ||
            weight_k != hold_k || weight_last != hold_last ||
            weight_n_lane_mask != hold_mask ||
            weight_context_tag != hold_tag)
          $fatal(1, "weight replay output changed while backpressured");
      end

      if (weight_valid) begin
        status = alexnet_golden_weight_tile_bank_word(
            weight_k, golden_values, golden_mask, golden_last, golden_tag);
        if (status != 0 || packed_values != golden_values ||
            weight_n_lane_mask != golden_mask ||
            weight_last != golden_last[0] ||
            weight_context_tag != golden_tag)
          $fatal(1,
                 "weight replay mismatch k=%0d values=%016x/%016x mask=%02x/%02x last=%0b/%0b tag=%0d/%0d status=%0d",
                 weight_k, packed_values, golden_values, weight_n_lane_mask,
                 golden_mask, weight_last, golden_last[0],
                 weight_context_tag, golden_tag, status);
      end

      if (weight_valid && !weight_ready) begin
        hold_active = 1'b1;
        hold_values = packed_values;
        hold_k = weight_k;
        hold_last = weight_last;
        hold_mask = weight_n_lane_mask;
        hold_tag = weight_context_tag;
        stall_run = stall_run + 1;
        if (stall_run > max_stall)
          max_stall = stall_run;
      end else begin
        hold_active = 1'b0;
        stall_run = 0;
      end
    end
  endtask

  task automatic try_bad_context(
      input int k_count,
      input logic [7:0] lane_mask,
      input int context_tag,
      input int mismatch_kind);
    begin
      replay_valid = 1'b1;
      replay_k_count = k_count;
      replay_n_lane_mask = lane_mask;
      replay_context_tag = context_tag;
      case (mismatch_kind)
        0: replay_k_count = k_count == 1 ? 2 : k_count - 1;
        1: replay_n_lane_mask = {lane_mask[6:0], lane_mask[7]};
        2: replay_context_tag = context_tag + 1;
        default: $fatal(1, "invalid mismatch kind");
      endcase
      if (mismatch_kind == 1 && replay_n_lane_mask == lane_mask)
        replay_n_lane_mask = lane_mask ^ 8'h80;
      release_valid = 1'b1;
      #1;
      if (replay_ready || release_ready)
        $fatal(1, "weight bank accepted a mismatched replay context");
      @(posedge clk);
      @(negedge clk);
      if (!context_error || bank_state != 2)
        $fatal(1, "weight bank did not latch context mismatch");
      replay_valid = 1'b0;
      release_valid = 1'b0;
      mismatch_attempts = mismatch_attempts + 1;
    end
  endtask

  task automatic run_replay(
      input int k_count,
      input logic [7:0] lane_mask,
      input int context_tag,
      input int replay_index);
    int read_count_local;
    int cycles;
    int status;
    logic weight_fire_local;
    logic weight_last_local;
    logic done_seen;
    begin
      replay_valid = 1'b1;
      replay_k_count = k_count;
      replay_n_lane_mask = lane_mask;
      replay_context_tag = context_tag;
      release_valid = 1'b1;
      #1;
      if (!replay_ready || release_ready)
        $fatal(1, "weight bank correct replay handshake mismatch");
      @(posedge clk);
      status = alexnet_golden_weight_tile_bank_begin_replay(
          k_count, lane_mask, context_tag);
      if (status != 0)
        $fatal(1, "C++ weight begin_replay failed status=%0d", status);
      @(negedge clk);
      replay_valid = 1'b0;
      release_valid = 1'b0;

      read_count_local = 0;
      cycles = 0;
      done_seen = 1'b0;
      hold_active = 1'b0;
      stall_run = 0;

      while (!done_seen) begin
        fill_valid = 1'b1;
        write_valid = 1'b1;
        release_valid = 1'b1;
        if ((cycles % 61) < 15)
          weight_ready = 1'b0;
        else
          weight_ready = $urandom_range(0, 5) != 0;
        #1;
        check_state();
        check_weight_output();
        if (fill_ready || write_ready || replay_ready || release_ready)
          $fatal(1, "weight bank allowed another owner while replaying");
        weight_fire_local = weight_valid && weight_ready;
        weight_last_local = weight_last;
        if (weight_fire_local && weight_k != read_count_local)
          $fatal(1, "weight K order mismatch got=%0d expected=%0d",
                 weight_k, read_count_local);
        @(posedge clk);
        if (weight_fire_local) begin
          read_count_local = read_count_local + 1;
          total_replay_words = total_replay_words + 1;
          if (weight_last_local) begin
            status = alexnet_golden_weight_tile_bank_complete_replay();
            if (status != 0)
              $fatal(1, "C++ weight complete_replay failed status=%0d",
                     status);
          end
        end
        @(negedge clk);
        if (replay_done)
          done_seen = 1'b1;
        cycles = cycles + 1;
        if (cycles > 100000)
          $fatal(1, "weight replay timeout replay=%0d K=%0d",
                 replay_index, k_count);
      end

      fill_valid = 1'b0;
      write_valid = 1'b0;
      release_valid = 1'b0;
      weight_ready = 1'b0;
      #1;
      check_state();
      if (bank_state != 2 || !resident_valid ||
          resident_k_count != k_count ||
          resident_n_lane_mask != lane_mask ||
          resident_context_tag != context_tag ||
          read_count_local != k_count)
        $fatal(1, "weight bank did not retain resident tile after replay");
      total_replays = total_replays + 1;
    end
  endtask

  task automatic run_transaction(
      input int transaction_index,
      input int k_count,
      input logic [7:0] lane_mask,
      input int context_tag,
      input int replay_count);
    int write_index_local;
    int status;
    logic pending_write;
    logic write_fire_local;
    begin
      check_state();
      if (!idle || !fill_ready || resident_valid || write_ready ||
          replay_ready || release_ready)
        $fatal(1, "weight bank did not expose EMPTY ownership");

      fill_valid = 1'b1;
      fill_k_count = k_count;
      fill_n_lane_mask = lane_mask;
      fill_context_tag = context_tag;
      replay_valid = 1'b1;
      release_valid = 1'b1;
      #1;
      if (!fill_ready || replay_ready || release_ready)
        $fatal(1, "weight bank fill descriptor readiness mismatch");
      @(posedge clk);
      status = alexnet_golden_weight_tile_bank_begin_fill(
          k_count, lane_mask, context_tag);
      if (status != 0)
        $fatal(1, "C++ weight begin_fill failed status=%0d", status);
      @(negedge clk);
      fill_valid = 1'b0;
      replay_valid = 1'b0;
      release_valid = 1'b0;

      write_index_local = 0;
      pending_write = 1'b0;
      while (write_index_local < k_count) begin
        if (!pending_write && $urandom_range(0, 4) != 0)
          pending_write = 1'b1;
        write_valid = pending_write;
        write_values = make_word(transaction_index, write_index_local);
        write_n_lane_mask = lane_mask;
        write_last = write_index_local == k_count - 1;
        replay_valid = 1'b1;
        release_valid = 1'b1;
        #1;
        check_state();
        if (fill_ready || replay_ready || release_ready)
          $fatal(1, "weight bank allowed another owner while writing");
        write_fire_local = write_valid && write_ready;
        @(posedge clk);
        if (write_fire_local) begin
          status = alexnet_golden_weight_tile_bank_write(
              write_values, lane_mask, write_last);
          if (status != 0)
            $fatal(1, "C++ weight write failed K=%0d status=%0d",
                   write_index_local, status);
          write_index_local = write_index_local + 1;
          pending_write = 1'b0;
        end
        @(negedge clk);
      end
      write_valid = 1'b0;
      replay_valid = 1'b0;
      release_valid = 1'b0;
      #1;
      check_state();
      if (bank_state != 2 || !resident_valid ||
          words_written != k_count || !release_ready)
        $fatal(1, "weight bank did not enter READY after final write");

      try_bad_context(k_count, lane_mask, context_tag, 0);
      try_bad_context(k_count, lane_mask, context_tag, 1);
      try_bad_context(k_count, lane_mask, context_tag, 2);

      for (int replay = 0; replay < replay_count; replay++)
        run_replay(k_count, lane_mask, context_tag, replay);

      release_valid = 1'b1;
      fill_valid = 1'b1;
      #1;
      if (!release_ready || fill_ready)
        $fatal(1, "weight bank release handshake mismatch");
      @(posedge clk);
      status = alexnet_golden_weight_tile_bank_release();
      if (status != 0)
        $fatal(1, "C++ weight release failed status=%0d", status);
      @(negedge clk);
      release_valid = 1'b0;
      fill_valid = 1'b0;
      #1;
      check_state();
      if (!idle || resident_valid || context_error ||
          resident_k_count != 0 || resident_n_lane_mask != 0 ||
          resident_context_tag != 0)
        $fatal(1, "weight bank did not clear resident ownership on release");
      transactions = transactions + 1;
    end
  endtask

  initial begin
    int seed;
    int seed_sink;
    int status;
    seed = 32'h6b3a_6e29;
    seed_sink = $urandom(seed);

    rst = 1'b1;
    fill_valid = 1'b0;
    fill_k_count = '0;
    fill_n_lane_mask = '0;
    fill_context_tag = '0;
    write_valid = 1'b0;
    write_values = '0;
    write_n_lane_mask = '0;
    write_last = 1'b0;
    replay_valid = 1'b0;
    replay_k_count = '0;
    replay_n_lane_mask = '0;
    replay_context_tag = '0;
    weight_ready = 1'b0;
    release_valid = 1'b0;
    transactions = 0;
    total_replays = 0;
    total_replay_words = 0;
    mismatch_attempts = 0;
    max_stall = 0;
    stall_run = 0;
    hold_active = 1'b0;

    status = alexnet_golden_weight_tile_bank_reset(DEPTH);
    if (status != 0)
      $fatal(1, "C++ weight tile bank reset failed status=%0d", status);

    repeat (5) @(negedge clk);
    rst = 1'b0;
    @(negedge clk);

    run_transaction(0, 1, 8'hff, 201, 3);
    run_transaction(1, 17, 8'h0f, 202, 2);
    run_transaction(2, 967, 8'h81, 203, 1);
    run_transaction(3, 968, 8'h01, 204, 2);

    if (completed_replays != total_replays)
      $fatal(1, "weight replay total mismatch rtl=%0d expected=%0d",
             completed_replays, total_replays);

    $display(
        "ALEXNET_N8_WEIGHT_TILE_BANK_TEST_PASSED transactions=%0d replays=%0d words=%0d mismatches=%0d maxstall=%0d seed=%0d",
        transactions, total_replays, total_replay_words, mismatch_attempts,
        max_stall, seed);
    $finish;
  end

endmodule
