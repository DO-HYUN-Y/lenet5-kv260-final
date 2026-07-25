`timescale 1ns/1ps

module tb_lenet_dma_addr_gen;
  localparam int NC = 8;
  localparam int COUNT_W = 16;
  localparam int BASE_W = 16;
  localparam int WGT_ADDR_W = 11;
  localparam int PARAM_ADDR_W = 8;
  localparam int BANK_ADDR_W = 9;
  localparam int BANK_W = $clog2(NC);

  logic clk;
  logic rst_n;
  logic start;
  logic clear_error;
  logic advance;
  logic [1:0] cfg_mode;
  logic [COUNT_W-1:0] cfg_count;
  logic [BASE_W-1:0] cfg_base;
  logic [BANK_W-1:0] cfg_bank_base;
  logic busy;
  logic valid;
  logic last;
  logic done;
  logic error;
  logic [1:0] mode;
  logic [COUNT_W-1:0] unit_index;
  logic [WGT_ADDR_W-1:0] weight_addr;
  logic [PARAM_ADDR_W-1:0] param_addr;
  logic [BANK_W-1:0] bank_index;
  logic [BANK_ADDR_W-1:0] bank_word_addr;

  int cycle_count;
  int accepted_count;
  int current_expected_count;
  int monitor_enable;
  int seed;
  int random_count;
  int plusarg_status;
  int random_seed_value;

  import "DPI-C" function int agen_expected_weight_addr(
      input int mode, input int base, input int index);
  import "DPI-C" function int agen_expected_param_addr(
      input int mode, input int base, input int index);
  import "DPI-C" function int agen_expected_bank(
      input int mode, input int bank_base, input int index, input int banks);
  import "DPI-C" function int agen_expected_bank_addr(
      input int mode, input int base, input int bank_base,
      input int index, input int banks);

  lenet_dma_addr_gen dut (.*);

  always #5 clk = ~clk;

  always @(posedge clk) begin
    if (!rst_n) begin
      cycle_count <= 0;
      accepted_count <= 0;
    end else begin
      cycle_count <= cycle_count + 1;
      if (monitor_enable && valid) begin
        int exp_wgt;
        int exp_param;
        int exp_bank;
        int exp_bank_addr;
        exp_wgt = agen_expected_weight_addr(
            int'(mode), int'(cfg_base), int'(unit_index));
        exp_param = agen_expected_param_addr(
            int'(mode), int'(cfg_base), int'(unit_index));
        exp_bank = agen_expected_bank(
            int'(mode), int'(cfg_bank_base), int'(unit_index), NC);
        exp_bank_addr = agen_expected_bank_addr(
            int'(mode), int'(cfg_base), int'(cfg_bank_base),
            int'(unit_index), NC);
        if (weight_addr !== WGT_ADDR_W'(exp_wgt))
          $fatal(1,
              "AGEN weight cycle=%0d tx=%0d got=%0d exp=%0d",
              cycle_count, unit_index, weight_addr, exp_wgt);
        if (param_addr !== PARAM_ADDR_W'(exp_param))
          $fatal(1,
              "AGEN param cycle=%0d tx=%0d got=%0d exp=%0d",
              cycle_count, unit_index, param_addr, exp_param);
        if (bank_index !== BANK_W'(exp_bank))
          $fatal(1,
              "AGEN bank cycle=%0d tx=%0d got=%0d exp=%0d",
              cycle_count, unit_index, bank_index, exp_bank);
        if (bank_word_addr !== BANK_ADDR_W'(exp_bank_addr))
          $fatal(1,
              "AGEN bank_addr cycle=%0d tx=%0d got=%0d exp=%0d",
              cycle_count, unit_index, bank_word_addr, exp_bank_addr);
        if (last !== (unit_index == COUNT_W'(current_expected_count - 1)))
          $fatal(1,
              "AGEN last cycle=%0d tx=%0d got=%0d count=%0d",
              cycle_count, unit_index, last, current_expected_count);
        if (advance) begin
          if (unit_index !== COUNT_W'(accepted_count))
            $fatal(1,
                "AGEN order cycle=%0d got_index=%0d accepted=%0d",
                cycle_count, unit_index, accepted_count);
          accepted_count <= accepted_count + 1;
        end
      end
    end
  end

  task automatic reset_dut;
    begin
      rst_n = 1'b0;
      start = 1'bx;
      clear_error = 1'bx;
      advance = 1'bx;
      cfg_mode = 'x;
      cfg_count = 'x;
      cfg_base = 'x;
      cfg_bank_base = 'x;
      monitor_enable = 0;
      repeat (4) @(negedge clk);
      start = 1'b0;
      clear_error = 1'b0;
      advance = 1'b0;
      cfg_mode = '0;
      cfg_count = '0;
      cfg_base = '0;
      cfg_bank_base = '0;
      rst_n = 1'b1;
      repeat (2) @(negedge clk);
      if ($isunknown({busy, valid, last, done, error, mode, unit_index,
                      weight_addr, param_addr, bank_index, bank_word_addr}))
        $fatal(1, "AGEN reset left unknown outputs");
    end
  endtask

  task automatic run_case(
      input int test_id,
      input int test_mode,
      input int test_count,
      input int test_base,
      input int test_bank_base,
      input bit random_stall
  );
    int guard;
    int effective_count;
    begin
      effective_count = (test_count == 0) ? 1 : test_count;
      current_expected_count = effective_count;
      accepted_count = 0;
      @(negedge clk);
      cfg_mode = 2'(test_mode);
      cfg_count = COUNT_W'(test_count);
      cfg_base = BASE_W'(test_base);
      cfg_bank_base = BANK_W'(test_bank_base);
      start = 1'b1;
      @(negedge clk);
      start = 1'b0;
      monitor_enable = 1;

      guard = 0;
      while (!done && guard < 2000) begin
        if (busy) begin
          if (random_stall)
            advance = ($urandom_range(0, 3) != 0);
          else
            advance = 1'b1;
        end else begin
          advance = 1'b0;
        end
        @(negedge clk);
        guard++;
      end
      advance = 1'b0;
      monitor_enable = 0;
      if (!done)
        $fatal(1, "AGEN test=%0d timeout", test_id);
      if (accepted_count != effective_count)
        $fatal(1,
            "AGEN test=%0d accepted=%0d expected=%0d",
            test_id, accepted_count, effective_count);
      if ((test_count == 0) && !error)
        $fatal(1, "AGEN test=%0d zero count did not flag error", test_id);
      $display("TEST%0d PASSED mode=%0d count=%0d base=%0d stalls=%0d",
               test_id, test_mode, test_count, test_base, random_stall);
      @(negedge clk);
      clear_error = 1'b1;
      @(negedge clk);
      clear_error = 1'b0;
    end
  endtask

  task automatic reset_mid_operation;
    begin
      current_expected_count = 8;
      accepted_count = 0;
      @(negedge clk);
      cfg_mode = 2'd2;
      cfg_count = COUNT_W'(8);
      cfg_base = BASE_W'(20);
      cfg_bank_base = BANK_W'(1);
      start = 1'b1;
      @(negedge clk);
      start = 1'b0;
      monitor_enable = 1;
      advance = 1'b1;
      repeat (3) @(negedge clk);
      rst_n = 1'b0;
      advance = 1'b0;
      monitor_enable = 0;
      repeat (2) @(negedge clk);
      rst_n = 1'b1;
      repeat (2) @(negedge clk);
      if (busy || valid || done || error)
        $fatal(1, "AGEN reset-mid-operation status not clear");
      $display("RESET_MID_OPERATION PASSED");
    end
  endtask

  initial begin
    clk = 1'b0;
    seed = 20260725;
    random_count = 0;
    plusarg_status = $value$plusargs("SEED=%d", seed);
    plusarg_status = $value$plusargs("RANDOM_COUNT=%d", random_count);
    random_seed_value = $urandom(seed);
    $display("AGEN seed=%0d random_count=%0d", seed, random_count);

    reset_dut();
    run_case(1, 0, 4, 12, 0, 1'b0);
    run_case(2, 1, 3, 7, 0, 1'b0);
    run_case(3, 2, 5, 21, 3, 1'b1);
    run_case(4, 3, 10, 9, 6, 1'b1);
    run_case(5, 2, 0, 0, 0, 1'b0);
    run_case(6, 0, 1, 100, 0, 1'b0);
    reset_mid_operation();

    for (int n = 0; n < random_count; n++) begin
      int m;
      int count;
      int base;
      int bank;
      m = $urandom_range(0, 3);
      count = $urandom_range(1, 24);
      base = $urandom_range(0, 100);
      bank = $urandom_range(0, NC - 1);
      run_case(100 + n, m, count, base, bank, 1'b1);
    end

    $display(
        "LENET_DMA_ADDR_GEN TEST PASSED seed=%0d random_count=%0d",
        seed, random_count);
    $finish;
  end

endmodule
