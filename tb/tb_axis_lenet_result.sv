`timescale 1ns/1ps

module tb_axis_lenet_result;
  localparam int NC = 8;
  localparam int AXIS_W = 128;
  localparam int AXIS_BYTES = 16;
  localparam int COUNT_W = 16;
  localparam int BASE_W = 16;
  localparam int BANK_ADDR_W = 9;
  localparam int BANK_W = $clog2(NC);

  logic clk;
  logic rst_n;
  logic start;
  logic clear_error;
  logic [COUNT_W-1:0] cfg_word_count;
  logic [BASE_W-1:0] cfg_base;
  logic [BANK_W-1:0] cfg_bank_base;
  logic cfg_activation_set;
  logic activation_host_ready;
  logic activation_host_set;
  logic activation_host_en [0:NC-1];
  logic [1:0] activation_host_we [0:NC-1];
  logic [BANK_ADDR_W-1:0] activation_host_addr [0:NC-1];
  logic [15:0] activation_host_wdata [0:NC-1];
  logic [15:0] activation_host_rdata [0:NC-1];
  logic activation_host_rvalid;
  logic [AXIS_W-1:0] m_axis_tdata;
  logic [AXIS_BYTES-1:0] m_axis_tkeep;
  logic m_axis_tvalid;
  logic m_axis_tready;
  logic m_axis_tlast;
  logic busy;
  logic done;
  logic error;

  int seed;
  int random_count;
  int plusarg_status;
  int random_seed_value;
  int random_stalls;
  int current_tx;
  int current_count;
  int effective_count;
  int current_base;
  int current_bank;
  int current_set;
  int request_seen;
  int packet_seen;
  int cycle_count;
  int monitor_enable;

  import "DPI-C" function int result_expected_bank(
      input int bank_base, input int index, input int banks);
  import "DPI-C" function int result_expected_addr(
      input int base, input int bank_base, input int index, input int banks);
  import "DPI-C" function int result_expected_word(
      input int seed, input int transaction, input int index);
  import "DPI-C" function int result_expected_keep(
      input int word_count);

  axis_lenet_result dut (.*);

  always #5 clk = ~clk;

  always @(negedge clk) begin
    if (!rst_n) begin
      activation_host_ready <= 1'b0;
      m_axis_tready <= 1'b0;
    end else if (random_stalls) begin
      activation_host_ready <= ($urandom_range(0, 3) != 0);
      m_axis_tready <= ($urandom_range(0, 3) != 0);
    end else begin
      activation_host_ready <= 1'b1;
      m_axis_tready <= 1'b1;
    end
  end

  always @(posedge clk) begin
    int enabled_bank;
    enabled_bank = -1;
    if (!rst_n) begin
      activation_host_rvalid <= 1'b0;
      for (int c = 0; c < NC; c++)
        activation_host_rdata[c] <= '0;
      cycle_count <= 0;
    end else begin
      cycle_count <= cycle_count + 1;
      activation_host_rvalid <= 1'b0;
      for (int c = 0; c < NC; c++) begin
        if (activation_host_en[c]) begin
          if (enabled_bank != -1)
            $fatal(1, "RESULT multiple bank reads cycle=%0d",
                   cycle_count);
          enabled_bank = c;
        end
      end

      if (enabled_bank != -1) begin
        int exp_bank;
        int exp_addr;
        int exp_word;
        exp_bank = result_expected_bank(
            current_bank, request_seen, NC);
        exp_addr = result_expected_addr(
            current_base, current_bank, request_seen, NC);
        exp_word = result_expected_word(
            seed, current_tx, request_seen);
        if ((enabled_bank != exp_bank) ||
            (activation_host_addr[enabled_bank] !==
             BANK_ADDR_W'(exp_addr)) ||
            (activation_host_we[enabled_bank] !== 2'b00) ||
            (activation_host_set !== current_set))
          $fatal(1,
              "RESULT request cycle=%0d tx=%0d idx=%0d bank=%0d/%0d addr=%0d/%0d set=%0d/%0d",
              cycle_count, current_tx, request_seen,
              enabled_bank, exp_bank,
              activation_host_addr[enabled_bank], exp_addr,
              activation_host_set, current_set);
        activation_host_rdata[enabled_bank] <= 16'(exp_word);
        activation_host_rvalid <= 1'b1;
        request_seen <= request_seen + 1;
      end

      if (monitor_enable && m_axis_tvalid) begin
        int exp_keep;
        exp_keep = result_expected_keep(effective_count);
        if (!m_axis_tlast)
          $fatal(1, "RESULT TLAST missing cycle=%0d", cycle_count);
        if (m_axis_tkeep !== 16'(exp_keep))
          $fatal(1,
              "RESULT TKEEP cycle=%0d got=%0h exp=%0h",
              cycle_count, m_axis_tkeep, exp_keep);
        for (int w = 0; w < effective_count; w++) begin
          int exp_word;
          exp_word = result_expected_word(seed, current_tx, w);
          if (m_axis_tdata[w*16 +: 16] !== 16'(exp_word))
            $fatal(1,
                "RESULT data cycle=%0d tx=%0d word=%0d got=%0h exp=%0h",
                cycle_count, current_tx, w,
                m_axis_tdata[w*16 +: 16], exp_word);
        end
        if (m_axis_tready)
          packet_seen <= packet_seen + 1;
      end
    end
  end

  task automatic reset_dut;
    begin
      rst_n = 1'b0;
      start = 1'bx;
      clear_error = 1'bx;
      cfg_word_count = 'x;
      cfg_base = 'x;
      cfg_bank_base = 'x;
      cfg_activation_set = 1'bx;
      random_stalls = 0;
      monitor_enable = 0;
      repeat (4) @(negedge clk);
      start = 1'b0;
      clear_error = 1'b0;
      cfg_word_count = '0;
      cfg_base = '0;
      cfg_bank_base = '0;
      cfg_activation_set = 1'b0;
      rst_n = 1'b1;
      repeat (2) @(negedge clk);
      if ($isunknown({activation_host_set, m_axis_tdata,
                      m_axis_tkeep, m_axis_tvalid, m_axis_tlast,
                      busy, done, error}))
        $fatal(1, "RESULT reset left unknown outputs");
    end
  endtask

  task automatic run_case(
      input int tx,
      input int word_count,
      input int base,
      input int bank,
      input int set_id,
      input int stalls,
      input int expect_error
  );
    int guard;
    begin
      current_tx = tx;
      current_count = word_count;
      effective_count =
          (word_count == 0) ? 1 : ((word_count > 8) ? 8 : word_count);
      current_base = base;
      current_bank = bank;
      current_set = set_id;
      request_seen = 0;
      packet_seen = 0;
      random_stalls = stalls;
      monitor_enable = 1;
      @(negedge clk);
      cfg_word_count = COUNT_W'(word_count);
      cfg_base = BASE_W'(base);
      cfg_bank_base = BANK_W'(bank);
      cfg_activation_set = set_id;
      start = 1'b1;
      @(negedge clk);
      start = 1'b0;
      if (!busy)
        $fatal(1, "RESULT tx=%0d did not start", tx);

      guard = 0;
      while (!done && guard < 5000) begin
        @(posedge clk);
        #1;
        guard++;
      end
      if (!done)
        $fatal(1, "RESULT tx=%0d timeout", tx);
      if ((request_seen != effective_count) || (packet_seen != 1))
        $fatal(1,
            "RESULT tx=%0d requests=%0d/%0d packets=%0d",
            tx, request_seen, effective_count, packet_seen);
      if (error != expect_error)
        $fatal(1,
            "RESULT tx=%0d error=%0d expected=%0d",
            tx, error, expect_error);
      monitor_enable = 0;
      random_stalls = 0;
      $display(
          "RESULT TX PASSED tx=%0d words=%0d effective=%0d stalls=%0d",
          tx, word_count, effective_count, stalls);
      @(negedge clk);
      clear_error = 1'b1;
      @(negedge clk);
      clear_error = 1'b0;
      repeat (2) @(negedge clk);
    end
  endtask

  task automatic reset_mid_transfer;
    begin
      current_tx = 90;
      current_count = 5;
      effective_count = 5;
      current_base = 0;
      current_bank = 0;
      current_set = 1;
      request_seen = 0;
      packet_seen = 0;
      random_stalls = 0;
      monitor_enable = 1;
      @(negedge clk);
      cfg_word_count = COUNT_W'(5);
      cfg_base = '0;
      cfg_bank_base = '0;
      cfg_activation_set = 1'b1;
      start = 1'b1;
      @(negedge clk);
      start = 1'b0;
      repeat (2) @(negedge clk);
      rst_n = 1'b0;
      monitor_enable = 0;
      repeat (3) @(negedge clk);
      rst_n = 1'b1;
      repeat (2) @(negedge clk);
      if (busy || done || error || m_axis_tvalid)
        $fatal(1, "RESULT reset-mid-transfer did not clear state");
      $display("RESULT RESET_MID_TRANSFER PASSED");
    end
  endtask

  initial begin
    clk = 1'b0;
    seed = 20260725;
    random_count = 0;
    plusarg_status = $value$plusargs("SEED=%d", seed);
    plusarg_status = $value$plusargs("RANDOM_COUNT=%d", random_count);
    random_seed_value = $urandom(seed);
    $display("RESULT seed=%0d random_count=%0d", seed, random_count);

    reset_dut();
    run_case(1, 5, 0, 0, 1, 0, 0);
    run_case(2, 1, 7, 3, 0, 1, 0);
    run_case(3, 8, 11, 6, 1, 1, 0);
    run_case(4, 0, 0, 0, 0, 0, 1);
    run_case(5, 9, 0, 0, 0, 0, 1);
    reset_mid_transfer();

    for (int n = 0; n < random_count; n++) begin
      int words;
      int base;
      int bank;
      words = $urandom_range(1, 8);
      base = $urandom_range(0, 40);
      bank = $urandom_range(0, NC - 1);
      run_case(100 + n, words, base, bank, n & 1, 1, 0);
    end

    $display(
        "AXIS_LENET_RESULT TEST PASSED seed=%0d random_count=%0d",
        seed, random_count);
    $finish;
  end

endmodule
