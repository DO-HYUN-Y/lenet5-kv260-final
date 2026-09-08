`timescale 1ns/1ps

module tb_alexnet_n8_activation_bank;

  localparam int DEPTH = 512;
  localparam int ADDR_W = $clog2(DEPTH);
  localparam int COUNT_W = $clog2(DEPTH + 1);

  import "DPI-C" function int alexnet_golden_activation_bank_reset(
      input int depth);
  import "DPI-C" function int alexnet_golden_activation_bank_begin_fill(
      input int word_count, input byte lane_mask, input int tensor_tag);
  import "DPI-C" function int alexnet_golden_activation_bank_write(
      input longint unsigned values, input byte lane_mask, input byte last);
  import "DPI-C" function int alexnet_golden_activation_bank_begin_read();
  import "DPI-C" function int alexnet_golden_activation_bank_word(
      input int index, output longint unsigned values,
      output byte lane_mask, output byte last, output int tensor_tag);
  import "DPI-C" function int alexnet_golden_activation_bank_complete_read();
  import "DPI-C" function int alexnet_golden_activation_bank_state(
      output byte state, output int words_written);

  logic clk = 1'b0;
  logic rst;
  logic fill_valid;
  logic fill_ready;
  logic [COUNT_W-1:0] fill_word_count;
  logic [7:0] fill_lane_mask;
  logic [15:0] fill_tensor_tag;
  logic write_valid;
  logic write_ready;
  logic [63:0] write_values;
  logic [7:0] write_lane_mask;
  logic write_last;
  logic read_start_valid;
  logic read_start_ready;
  logic read_valid;
  logic read_ready;
  logic [63:0] read_values;
  logic [7:0] read_lane_mask;
  logic [ADDR_W-1:0] read_index;
  logic read_last;
  logic [15:0] read_tensor_tag;
  logic [1:0] bank_state;
  logic [COUNT_W-1:0] words_written;
  logic read_done;
  logic idle;

  int transactions;
  int total_words;
  int max_stall;
  int stall_run;
  logic hold_active;
  logic [63:0] hold_values;
  logic [7:0] hold_mask;
  logic [ADDR_W-1:0] hold_index;
  logic hold_last;
  logic [15:0] hold_tag;

  alexnet_n8_activation_bank #(
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
        value = (transaction_index * 67 + word_index * 29 + lane * 43) & 8'hff;
        result[lane*8 +: 8] = value[7:0];
      end
      make_word = result;
    end
  endfunction

  task automatic check_state;
    byte golden_state;
    int golden_written;
    int status;
    begin
      status = alexnet_golden_activation_bank_state(golden_state,
                                                     golden_written);
      if (status != 0 || bank_state != golden_state[1:0] ||
          words_written != golden_written)
        $fatal(1,
               "activation state mismatch rtl=%0d/%0d golden=%0d/%0d status=%0d",
               bank_state, words_written, golden_state, golden_written,
               status);
    end
  endtask

  task automatic check_read_output;
    longint unsigned golden_values;
    byte golden_mask;
    byte golden_last;
    int golden_tag;
    int status;
    begin
      if (hold_active) begin
        if (!read_valid || read_values != hold_values ||
            read_lane_mask != hold_mask || read_index != hold_index ||
            read_last != hold_last || read_tensor_tag != hold_tag)
          $fatal(1, "activation read output changed while backpressured");
      end

      if (read_valid) begin
        status = alexnet_golden_activation_bank_word(
            read_index, golden_values, golden_mask, golden_last, golden_tag);
        if (status != 0 || read_values != golden_values ||
            read_lane_mask != golden_mask || read_last != golden_last[0] ||
            read_tensor_tag != golden_tag)
          $fatal(1,
                 "activation read mismatch index=%0d values=%016x/%016x mask=%02x/%02x last=%0b/%0b tag=%0d/%0d status=%0d",
                 read_index, read_values, golden_values, read_lane_mask,
                 golden_mask, read_last, golden_last[0], read_tensor_tag,
                 golden_tag, status);
      end

      if (read_valid && !read_ready) begin
        hold_active = 1'b1;
        hold_values = read_values;
        hold_mask = read_lane_mask;
        hold_index = read_index;
        hold_last = read_last;
        hold_tag = read_tensor_tag;
        stall_run = stall_run + 1;
        if (stall_run > max_stall)
          max_stall = stall_run;
      end else begin
        hold_active = 1'b0;
        stall_run = 0;
      end
    end
  endtask

  task automatic run_transaction(
      input int transaction_index,
      input int word_count,
      input logic [7:0] lane_mask,
      input int tensor_tag);
    int write_index_local;
    int read_count_local;
    int cycles;
    int status;
    logic pending_write;
    logic write_fire;
    logic read_fire;
    logic done_seen;
    begin
      write_index_local = 0;
      read_count_local = 0;
      cycles = 0;
      pending_write = 1'b0;
      done_seen = 1'b0;
      hold_active = 1'b0;
      stall_run = 0;

      check_state();
      if (!idle || !fill_ready || write_ready || read_start_ready)
        $fatal(1, "activation bank did not expose EMPTY ownership");

      fill_valid = 1'b1;
      fill_word_count = word_count;
      fill_lane_mask = lane_mask;
      fill_tensor_tag = tensor_tag;
      read_start_valid = 1'b1;
      #1;
      if (!fill_ready || read_start_ready)
        $fatal(1, "activation bank descriptor readiness mismatch");
      @(posedge clk);
      status = alexnet_golden_activation_bank_begin_fill(
          word_count, lane_mask, tensor_tag);
      if (status != 0)
        $fatal(1, "C++ activation begin_fill failed status=%0d", status);
      @(negedge clk);
      fill_valid = 1'b0;

      while (write_index_local < word_count) begin
        if (!pending_write && $urandom_range(0, 4) != 0)
          pending_write = 1'b1;
        write_valid = pending_write;
        write_values = make_word(transaction_index, write_index_local);
        write_lane_mask = lane_mask;
        write_last = write_index_local == word_count - 1;
        read_start_valid = 1'b1;
        #1;
        check_state();
        if (read_start_ready || fill_ready)
          $fatal(1, "activation bank allowed another owner while writing");
        write_fire = write_valid && write_ready;
        @(posedge clk);
        if (write_fire) begin
          status = alexnet_golden_activation_bank_write(
              write_values, lane_mask, write_last);
          if (status != 0)
            $fatal(1, "C++ activation write failed index=%0d status=%0d",
                   write_index_local, status);
          write_index_local = write_index_local + 1;
          pending_write = 1'b0;
        end
        @(negedge clk);
      end
      write_valid = 1'b0;
      read_start_valid = 1'b0;
      #1;
      check_state();
      if (bank_state != 2 || !read_start_ready || write_ready || fill_ready)
        $fatal(1, "activation bank did not enter READY after final write");

      write_valid = 1'b1;
      read_start_valid = 1'b1;
      #1;
      if (write_ready || !read_start_ready)
        $fatal(1, "activation bank read ownership handshake mismatch");
      @(posedge clk);
      status = alexnet_golden_activation_bank_begin_read();
      if (status != 0)
        $fatal(1, "C++ activation begin_read failed status=%0d", status);
      @(negedge clk);
      read_start_valid = 1'b0;

      while (!done_seen) begin
        write_valid = 1'b1;
        write_values = ~64'b0;
        write_lane_mask = lane_mask;
        write_last = 1'b0;
        fill_valid = 1'b1;
        if ((cycles % 53) < 8)
          read_ready = 1'b0;
        else
          read_ready = $urandom_range(0, 4) != 0;
        #1;
        check_state();
        check_read_output();
        if (write_ready || fill_ready || read_start_ready)
          $fatal(1, "activation bank allowed a second owner while reading");
        read_fire = read_valid && read_ready;
        @(posedge clk);
        if (read_fire) begin
          if (read_index != read_count_local)
            $fatal(1, "activation read order mismatch index=%0d expected=%0d",
                   read_index, read_count_local);
          read_count_local = read_count_local + 1;
          total_words = total_words + 1;
          if (read_last) begin
            status = alexnet_golden_activation_bank_complete_read();
            if (status != 0)
              $fatal(1, "C++ activation complete_read failed status=%0d",
                     status);
          end
        end
        @(negedge clk);
        if (read_done)
          done_seen = 1'b1;
        cycles = cycles + 1;
        if (cycles > 100000)
          $fatal(1, "activation bank timeout words=%0d", word_count);
      end

      fill_valid = 1'b0;
      write_valid = 1'b0;
      read_start_valid = 1'b0;
      read_ready = 1'b0;
      #1;
      check_state();
      if (!idle || read_count_local != word_count)
        $fatal(1, "activation bank release mismatch reads=%0d/%0d idle=%0b",
               read_count_local, word_count, idle);
      transactions = transactions + 1;
    end
  endtask

  initial begin
    int seed;
    int seed_sink;
    int status;
    seed = 32'h6b29_4d17;
    seed_sink = $urandom(seed);

    rst = 1'b1;
    fill_valid = 1'b0;
    fill_word_count = '0;
    fill_lane_mask = '0;
    fill_tensor_tag = '0;
    write_valid = 1'b0;
    write_values = '0;
    write_lane_mask = '0;
    write_last = 1'b0;
    read_start_valid = 1'b0;
    read_ready = 1'b0;
    transactions = 0;
    total_words = 0;
    max_stall = 0;
    stall_run = 0;
    hold_active = 1'b0;

    status = alexnet_golden_activation_bank_reset(DEPTH);
    if (status != 0)
      $fatal(1, "C++ activation bank reset failed status=%0d", status);

    repeat (5) @(negedge clk);
    rst = 1'b0;
    @(negedge clk);

    run_transaction(0, 1, 8'hff, 101);
    run_transaction(1, 17, 8'h0f, 102);
    run_transaction(2, 511, 8'h81, 103);
    run_transaction(3, 512, 8'h01, 104);

    $display(
        "ALEXNET_N8_ACTIVATION_BANK_TEST_PASSED transactions=%0d words=%0d maxstall=%0d seed=%0d",
        transactions, total_words, max_stall, seed);
    $finish;
  end

endmodule
