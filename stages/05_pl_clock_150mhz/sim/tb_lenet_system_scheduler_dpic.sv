`timescale 1ns/1ps

module tb_lenet_system_scheduler_dpic;
  localparam int DMA_LEN_W = 26;
  localparam int MAX_SCORE_JOBS = 512;

  logic clk;
  logic rst_n;
  logic submit;
  logic submit_ready;
  logic submit_rejected;
  logic clear_status;
  logic cfg_reload_model;
  logic [31:0] cfg_weight_addr;
  logic [31:0] cfg_param_addr;
  logic [31:0] cfg_input_addr;
  logic [31:0] cfg_result_addr;
  logic [31:0] cfg_timeout_cycles;
  logic [31:0] cfg_job_id;
  logic resources_idle;
  logic model_valid;
  logic ingress_busy;
  logic ingress_done;
  logic ingress_error;
  logic core_busy;
  logic core_done;
  logic result_busy;
  logic result_done;
  logic result_error;
  logic ingress_start;
  logic [1:0] ingress_mode;
  logic [15:0] ingress_count;
  logic [15:0] ingress_base;
  logic [2:0] ingress_bank_base;
  logic ingress_activation_set;
  logic core_start;
  logic result_start;
  logic [15:0] result_word_count;
  logic [15:0] result_base;
  logic [2:0] result_bank_base;
  logic dma_cmd_valid;
  logic dma_cmd_ready;
  logic dma_cmd_s2mm;
  logic [31:0] dma_cmd_addr;
  logic [DMA_LEN_W-1:0] dma_cmd_length;
  logic [31:0] dma_cmd_timeout;
  logic dma_armed;
  logic dma_busy;
  logic dma_done;
  logic dma_error;
  logic [3:0] dma_error_code;
  logic busy;
  logic done;
  logic error;
  logic queue_full;
  logic [7:0] error_code;
  logic [4:0] state_debug;
  logic [31:0] completed_job_id;
  logic [31:0] last_job_cycles;
  logic [31:0] last_dma_cycles;
  logic [31:0] completed_jobs;

  int seed;
  int random_count;
  int plusarg_status;
  int random_seed_value;
  int cycle_count;
  bit random_delays;
  bit hold_completions;
  bit inject_dma_error;
  bit inject_ingress_error;
  bit inject_result_error;

  int dma_arm_countdown;
  int dma_done_countdown;
  int ingress_countdown;
  int core_countdown;
  int result_countdown;
  int dma_transfer_number;
  logic [1:0] ingress_mode_active;
  logic dma_direction_active;

  bit scoreboard_enable;
  int expected_job_count;
  int score_job_index;
  int score_dma_index;
  int score_ingress_index;
  int score_core_count;
  int score_result_count;
  bit output_armed_seen;
  bit expected_need_model [0:MAX_SCORE_JOBS-1];
  logic [31:0] expected_weight_addr [0:MAX_SCORE_JOBS-1];
  logic [31:0] expected_param_addr [0:MAX_SCORE_JOBS-1];
  logic [31:0] expected_input_addr [0:MAX_SCORE_JOBS-1];
  logic [31:0] expected_result_addr [0:MAX_SCORE_JOBS-1];
  logic [31:0] expected_job_id [0:MAX_SCORE_JOBS-1];

  import "DPI-C" function int scheduler_golden_dma_count(
      input int need_model);
  import "DPI-C" function int scheduler_golden_ingress_count(
      input int need_model);
  import "DPI-C" function int scheduler_golden_dma_kind(
      input int need_model, input int index);
  import "DPI-C" function int unsigned scheduler_golden_length(
      input int kind);
  import "DPI-C" function int scheduler_golden_ingress_mode(
      input int need_model, input int index);
  import "DPI-C" function int unsigned
      scheduler_golden_ingress_count_value(input int mode);

  lenet_system_scheduler #(
    .DEFAULT_TIMEOUT(32'd1000)
  ) dut (.*);

  always #5 clk = ~clk;
  assign resources_idle = !ingress_busy && !core_busy && !result_busy;

  function automatic int delay_value(input int minimum, input int maximum);
    if (random_delays)
      return $urandom_range(minimum, maximum);
    return minimum;
  endfunction

  // Independent done-in-N-cycles models for DMA and the three scheduled units.
  always @(posedge clk) begin
    if (!rst_n || clear_status) begin
      ingress_busy <= 1'b0;
      ingress_done <= 1'b0;
      ingress_error <= 1'b0;
      core_busy <= 1'b0;
      core_done <= 1'b0;
      result_busy <= 1'b0;
      result_done <= 1'b0;
      result_error <= 1'b0;
      dma_cmd_ready <= 1'b1;
      dma_armed <= 1'b0;
      dma_busy <= 1'b0;
      dma_done <= 1'b0;
      dma_error <= 1'b0;
      dma_error_code <= 4'd0;
      dma_arm_countdown = 0;
      dma_done_countdown = 0;
      ingress_countdown = 0;
      core_countdown = 0;
      result_countdown = 0;
      dma_transfer_number = 0;
      ingress_mode_active <= 2'd0;
      dma_direction_active <= 1'b0;
    end else begin
      ingress_done <= 1'b0;
      core_done <= 1'b0;
      result_done <= 1'b0;
      dma_armed <= 1'b0;
      dma_done <= 1'b0;
      dma_cmd_ready <=
          !dma_busy && (!random_delays || $urandom_range(0, 3) != 0);

      if (dma_cmd_valid && dma_cmd_ready) begin
        dma_busy <= 1'b1;
        dma_direction_active <= dma_cmd_s2mm;
        dma_arm_countdown = delay_value(2, 5);
        dma_done_countdown = delay_value(7, 15);
        dma_transfer_number++;
        if (inject_dma_error) begin
          dma_error <= 1'b1;
          dma_error_code <= 4'd4;
        end
      end
      if (dma_busy && !hold_completions && !dma_error) begin
        if (dma_arm_countdown > 0) begin
          dma_arm_countdown--;
          if (dma_arm_countdown == 0)
            dma_armed <= 1'b1;
        end
        if (dma_done_countdown > 0) begin
          dma_done_countdown--;
          if (dma_done_countdown == 0) begin
            dma_busy <= 1'b0;
            dma_done <= 1'b1;
          end
        end
      end

      if (ingress_start) begin
        ingress_busy <= 1'b1;
        ingress_mode_active <= ingress_mode;
        ingress_countdown = delay_value(3, 12);
        if (inject_ingress_error)
          ingress_error <= 1'b1;
      end
      if (ingress_busy && !hold_completions && !ingress_error) begin
        if (ingress_countdown > 0) begin
          ingress_countdown--;
          if (ingress_countdown == 0) begin
            ingress_busy <= 1'b0;
            ingress_done <= 1'b1;
            if (ingress_mode_active == 2'd1)
              model_valid <= 1'b1;
          end
        end
      end

      if (core_start) begin
        core_busy <= 1'b1;
        core_countdown = delay_value(6, 20);
      end
      if (core_busy && !hold_completions) begin
        if (core_countdown > 0) begin
          core_countdown--;
          if (core_countdown == 0) begin
            core_busy <= 1'b0;
            core_done <= 1'b1;
          end
        end
      end

      if (result_start) begin
        result_busy <= 1'b1;
        result_countdown = delay_value(3, 8);
        if (inject_result_error)
          result_error <= 1'b1;
      end
      if (result_busy && !hold_completions && !result_error) begin
        if (result_countdown > 0) begin
          result_countdown--;
          if (result_countdown == 0) begin
            result_busy <= 1'b0;
            result_done <= 1'b1;
          end
        end
      end
    end
  end

  always @(posedge clk) begin : cycle_scoreboard
    int kind;
    int mode;
    logic [31:0] address_expected;
    if (!rst_n) begin
      cycle_count <= 0;
      score_job_index = 0;
      score_dma_index = 0;
      score_ingress_index = 0;
      score_core_count = 0;
      score_result_count = 0;
      output_armed_seen = 1'b0;
    end else begin
      cycle_count <= cycle_count + 1;
      if (scoreboard_enable && (score_job_index < expected_job_count)) begin
        if (dma_cmd_valid && dma_cmd_ready) begin
          kind = scheduler_golden_dma_kind(
              expected_need_model[score_job_index], score_dma_index);
          case (kind)
            0: address_expected =
                expected_weight_addr[score_job_index];
            1: address_expected =
                expected_param_addr[score_job_index];
            2: address_expected =
                expected_input_addr[score_job_index];
            3: address_expected =
                expected_result_addr[score_job_index];
            default: address_expected = 32'hffff_ffff;
          endcase
          if (dma_cmd_addr !== address_expected ||
              dma_cmd_length !==
                  DMA_LEN_W'(scheduler_golden_length(kind)) ||
              dma_cmd_s2mm !== (kind == 3))
            $fatal(1,
                "SCHED DMA cycle=%0d job=%0d index=%0d kind=%0d addr=%08h/%08h len=%0d/%0d dir=%0d",
                cycle_count, score_job_index, score_dma_index, kind,
                dma_cmd_addr, address_expected, dma_cmd_length,
                scheduler_golden_length(kind), dma_cmd_s2mm);
          if ((kind != 3) && !ingress_start)
            $fatal(1,
                "SCHED ingress not aligned to MM2S accept cycle=%0d",
                cycle_count);
          score_dma_index++;
        end

        if (ingress_start) begin
          mode = scheduler_golden_ingress_mode(
              expected_need_model[score_job_index],
              score_ingress_index);
          if ((ingress_mode !== mode[1:0]) ||
              (ingress_count !==
                  scheduler_golden_ingress_count_value(mode)) ||
              (ingress_base != 0) || (ingress_bank_base != 0) ||
              ingress_activation_set)
            $fatal(1,
                "SCHED ingress cycle=%0d job=%0d index=%0d mode=%0d/%0d count=%0d/%0d",
                cycle_count, score_job_index, score_ingress_index,
                ingress_mode, mode, ingress_count,
                scheduler_golden_ingress_count_value(mode));
          score_ingress_index++;
        end

        if (dma_armed && dma_busy && dma_direction_active)
          output_armed_seen = 1'b1;

        if (core_start)
          score_core_count++;

        if (result_start) begin
          if (!output_armed_seen)
            $fatal(1,
                "SCHED result before S2MM armed cycle=%0d",
                cycle_count);
          if ((result_word_count != 16'd5) ||
              (result_base != 16'd0) ||
              (result_bank_base != 3'd0))
            $fatal(1, "SCHED result config mismatch");
          score_result_count++;
        end

        if (done) begin
          if (completed_job_id !== expected_job_id[score_job_index])
            $fatal(1,
                "SCHED done cycle=%0d job id got=%08h expected=%08h",
                cycle_count, completed_job_id,
                expected_job_id[score_job_index]);
          if (score_dma_index != scheduler_golden_dma_count(
                  expected_need_model[score_job_index]) ||
              score_ingress_index != scheduler_golden_ingress_count(
                  expected_need_model[score_job_index]) ||
              score_core_count != 1 || score_result_count != 1)
            $fatal(1,
                "SCHED event counts job=%0d dma=%0d ingress=%0d core=%0d result=%0d",
                score_job_index, score_dma_index, score_ingress_index,
                score_core_count, score_result_count);
          if (last_job_cycles == 0 || last_dma_cycles == 0)
            $fatal(1, "SCHED counters not updated");
          score_job_index++;
          score_dma_index = 0;
          score_ingress_index = 0;
          score_core_count = 0;
          score_result_count = 0;
          output_armed_seen = 1'b0;
        end
      end
    end
  end

  task automatic add_expected_job(
      input bit need_model,
      input logic [31:0] weight_addr,
      input logic [31:0] param_addr,
      input logic [31:0] input_addr,
      input logic [31:0] output_addr,
      input logic [31:0] job_id);
    begin
      expected_need_model[expected_job_count] = need_model;
      expected_weight_addr[expected_job_count] = weight_addr;
      expected_param_addr[expected_job_count] = param_addr;
      expected_input_addr[expected_job_count] = input_addr;
      expected_result_addr[expected_job_count] = output_addr;
      expected_job_id[expected_job_count] = job_id;
      expected_job_count++;
    end
  endtask

  task automatic pulse_submit(
      input bit reload_model,
      input logic [31:0] weight_addr,
      input logic [31:0] param_addr,
      input logic [31:0] input_addr,
      input logic [31:0] output_addr,
      input logic [31:0] timeout_cycles,
      input logic [31:0] job_id,
      input bit expect_accept);
    bit ready_before;
    begin
      cfg_reload_model = reload_model;
      cfg_weight_addr = weight_addr;
      cfg_param_addr = param_addr;
      cfg_input_addr = input_addr;
      cfg_result_addr = output_addr;
      cfg_timeout_cycles = timeout_cycles;
      cfg_job_id = job_id;
      @(negedge clk);
      ready_before = submit_ready;
      submit = 1'b1;
      @(posedge clk);
      @(negedge clk);
      submit = 1'b0;
      if (ready_before != expect_accept)
        $fatal(1,
            "SCHED submit ready got=%0d expected=%0d state=%0d",
            ready_before, expect_accept, state_debug);
      if (!expect_accept && !submit_rejected)
        $fatal(1, "SCHED rejected submit did not pulse");
    end
  endtask

  task automatic wait_completed(input int target, input int timeout);
    int guard;
    begin
      guard = 0;
      while ((score_job_index < target) && guard < timeout) begin
        @(negedge clk);
        guard++;
      end
      if (score_job_index < target)
        $fatal(1,
            "SCHED wait timeout target=%0d got=%0d state=%0d error=%0d/%02h",
            target, score_job_index, state_debug, error, error_code);
    end
  endtask

  task automatic pulse_clear;
    begin
      @(negedge clk);
      clear_status = 1'b1;
      @(negedge clk);
      clear_status = 1'b0;
      inject_dma_error = 1'b0;
      inject_ingress_error = 1'b0;
      inject_result_error = 1'b0;
      hold_completions = 1'b0;
      repeat (2) @(negedge clk);
      if (error || busy)
        $fatal(1, "SCHED clear failed error=%0d busy=%0d", error, busy);
    end
  endtask

  task automatic reset_dut;
    begin
      rst_n = 1'b0;
      submit = 1'bx;
      clear_status = 1'bx;
      cfg_reload_model = 1'bx;
      cfg_weight_addr = 'x;
      cfg_param_addr = 'x;
      cfg_input_addr = 'x;
      cfg_result_addr = 'x;
      cfg_timeout_cycles = 'x;
      cfg_job_id = 'x;
      model_valid = 1'b0;
      random_delays = 1'b0;
      hold_completions = 1'b0;
      inject_dma_error = 1'b0;
      inject_ingress_error = 1'b0;
      inject_result_error = 1'b0;
      scoreboard_enable = 1'b0;
      repeat (5) @(negedge clk);
      submit = 1'b0;
      clear_status = 1'b0;
      cfg_reload_model = 1'b0;
      cfg_weight_addr = 32'd0;
      cfg_param_addr = 32'd0;
      cfg_input_addr = 32'd0;
      cfg_result_addr = 32'd0;
      cfg_timeout_cycles = 32'd0;
      cfg_job_id = 32'd0;
      rst_n = 1'b1;
      repeat (3) @(negedge clk);
      if ($isunknown({
          submit_ready, submit_rejected, ingress_start, ingress_mode,
          ingress_count, ingress_base, ingress_bank_base,
          ingress_activation_set, core_start, result_start,
          result_word_count, result_base, result_bank_base,
          dma_cmd_valid, dma_cmd_s2mm, dma_cmd_addr, dma_cmd_length,
          dma_cmd_timeout, busy, done, error, queue_full, error_code,
          state_debug, completed_job_id, last_job_cycles,
          last_dma_cycles, completed_jobs
      }))
        $fatal(1, "SCHED reset left unknown outputs");
    end
  endtask

  initial begin
    int base_expected;
    clk = 1'b0;
    seed = 20260725;
    random_count = 0;
    plusarg_status = $value$plusargs("SEED=%d", seed);
    plusarg_status = $value$plusargs("RANDOM_COUNT=%d", random_count);
    random_seed_value = $urandom(seed);
    expected_job_count = 0;

    reset_dut();
    scoreboard_enable = 1'b1;
    $display("SCHED seed=%0d random_count=%0d", seed, random_count);

    add_expected_job(1, 32'h1000_0000, 32'h1002_0000,
                     32'h1003_0000, 32'h1004_0000, 32'h0000_0001);
    pulse_submit(0, 32'h1000_0000, 32'h1002_0000,
                 32'h1003_0000, 32'h1004_0000,
                 32'd1000, 32'h0000_0001, 1);
    wait_completed(1, 2000);

    // Resident model skips weight and parameter DMA.
    add_expected_job(0, 32'h1100_0000, 32'h1102_0000,
                     32'h1103_0000, 32'h1104_0000, 32'h0000_0002);
    pulse_submit(0, 32'h1100_0000, 32'h1102_0000,
                 32'h1103_0000, 32'h1104_0000,
                 32'd1000, 32'h0000_0002, 1);
    wait_completed(2, 1000);

    // One active plus one pending job. The second starts without host wait.
    add_expected_job(1, 32'h1200_0000, 32'h1202_0000,
                     32'h1203_0000, 32'h1204_0000, 32'h0000_0003);
    pulse_submit(1, 32'h1200_0000, 32'h1202_0000,
                 32'h1203_0000, 32'h1204_0000,
                 32'd1000, 32'h0000_0003, 1);
    repeat (4) @(negedge clk);
    add_expected_job(0, 32'h1300_0000, 32'h1302_0000,
                     32'h1303_0000, 32'h1304_0000, 32'h0000_0004);
    pulse_submit(0, 32'h1300_0000, 32'h1302_0000,
                 32'h1303_0000, 32'h1304_0000,
                 32'd1000, 32'h0000_0004, 1);
    if (!queue_full)
      $fatal(1, "SCHED pending queue did not fill");
    pulse_submit(0, 32'h1400_0000, 32'h1402_0000,
                 32'h1403_0000, 32'h1404_0000,
                 32'd1000, 32'h0000_0005, 0);
    wait_completed(4, 3000);
    $display("SCHED DIRECTED HAPPY/QUEUE PASSED");

    // Invalid address.
    scoreboard_enable = 1'b0;
    pulse_submit(0, 32'h1000_0000, 32'h1002_0000,
                 32'h1003_0004, 32'h1004_0000,
                 32'd1000, 32'hbad0_0001, 1);
    while (!error) @(negedge clk);
    if (error_code != 8'h01)
      $fatal(1, "SCHED invalid descriptor code=%02h", error_code);
    pulse_clear();

    // DMA, ingress, result, and timeout error paths with recovery.
    inject_dma_error = 1'b1;
    pulse_submit(0, 32'h1000_0000, 32'h1002_0000,
                 32'h1003_0000, 32'h1004_0000,
                 32'd1000, 32'hbad0_0002, 1);
    while (!error) @(negedge clk);
    if (error_code != 8'h24)
      $fatal(1, "SCHED DMA error code=%02h", error_code);
    pulse_clear();

    inject_ingress_error = 1'b1;
    pulse_submit(0, 32'h1000_0000, 32'h1002_0000,
                 32'h1003_0000, 32'h1004_0000,
                 32'd1000, 32'hbad0_0003, 1);
    while (!error) @(negedge clk);
    if (error_code != 8'h04)
      $fatal(1, "SCHED ingress error code=%02h", error_code);
    pulse_clear();

    inject_result_error = 1'b1;
    pulse_submit(0, 32'h1000_0000, 32'h1002_0000,
                 32'h1003_0000, 32'h1004_0000,
                 32'd1000, 32'hbad0_0004, 1);
    while (!error) @(negedge clk);
    if (error_code != 8'h05)
      $fatal(1, "SCHED result error code=%02h", error_code);
    pulse_clear();

    hold_completions = 1'b1;
    pulse_submit(0, 32'h1000_0000, 32'h1002_0000,
                 32'h1003_0000, 32'h1004_0000,
                 32'd8, 32'hbad0_0005, 1);
    while (!error) @(negedge clk);
    if (error_code != 8'h03)
      $fatal(1, "SCHED timeout error code=%02h", error_code);
    pulse_clear();

    // Mid-operation reset.
    pulse_submit(0, 32'h1000_0000, 32'h1002_0000,
                 32'h1003_0000, 32'h1004_0000,
                 32'd1000, 32'hbad0_0006, 1);
    repeat (5) @(negedge clk);
    rst_n = 1'b0;
    repeat (3) @(negedge clk);
    rst_n = 1'b1;
    repeat (3) @(negedge clk);
    if (busy || error || queue_full)
      $fatal(1, "SCHED mid-operation reset failed");
    $display("SCHED DIRECTED ERRORS/RESET PASSED");

    // Seeded random jobs execute sequentially with a resident model.
    scoreboard_enable = 1'b1;
    random_delays = 1'b1;
    model_valid = 1'b1;
    base_expected = expected_job_count;
    score_job_index = base_expected;
    score_dma_index = 0;
    score_ingress_index = 0;
    score_core_count = 0;
    score_result_count = 0;
    output_armed_seen = 1'b0;
    for (int tx = 0; tx < random_count; tx++) begin
      logic reload;
      logic [31:0] address_base;
      reload = ($urandom_range(0, 7) == 0);
      address_base = 32'h2000_0000 + 32'(tx) * 32'h0001_0000;
      add_expected_job(reload, address_base,
                       address_base + 32'h0000_2000,
                       address_base + 32'h0000_4000,
                       address_base + 32'h0000_6000,
                       32'h8000_0000 + 32'(tx));
      while (!submit_ready) @(negedge clk);
      pulse_submit(reload, address_base,
                   address_base + 32'h0000_2000,
                   address_base + 32'h0000_4000,
                   address_base + 32'h0000_6000,
                   32'd1000, 32'h8000_0000 + 32'(tx), 1);
      wait_completed(base_expected + tx + 1, 3000);
    end
    if (random_count > 0)
      $display("SCHED RANDOM PASSED jobs=%0d seed=%0d",
               random_count, seed);

    $display("LENET_SYSTEM_SCHEDULER TEST PASSED");
    $finish;
  end

endmodule
