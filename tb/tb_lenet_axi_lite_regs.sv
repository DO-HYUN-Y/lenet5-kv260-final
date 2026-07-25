`timescale 1ns/1ps

module tb_lenet_axi_lite_regs;
  localparam int ADDR_W = 8;

  logic clk;
  logic rst_n;
  logic [ADDR_W-1:0] s_axi_awaddr;
  logic s_axi_awvalid;
  logic s_axi_awready;
  logic [31:0] s_axi_wdata;
  logic [3:0] s_axi_wstrb;
  logic s_axi_wvalid;
  logic s_axi_wready;
  logic [1:0] s_axi_bresp;
  logic s_axi_bvalid;
  logic s_axi_bready;
  logic [ADDR_W-1:0] s_axi_araddr;
  logic s_axi_arvalid;
  logic s_axi_arready;
  logic [31:0] s_axi_rdata;
  logic [1:0] s_axi_rresp;
  logic s_axi_rvalid;
  logic s_axi_rready;
  logic core_start_pulse;
  logic load_start_pulse;
  logic result_start_pulse;
  logic clear_status_pulse;
  logic auto_submit_pulse;
  logic [1:0] load_mode;
  logic load_activation_set;
  logic [2:0] load_bank_base;
  logic [15:0] load_count;
  logic [15:0] load_base;
  logic [2:0] result_bank_base;
  logic [15:0] result_word_count;
  logic [15:0] result_base;
  logic auto_reload_model;
  logic [31:0] auto_weight_addr;
  logic [31:0] auto_param_addr;
  logic [31:0] auto_input_addr;
  logic [31:0] auto_result_addr;
  logic [31:0] auto_timeout_cycles;
  logic [31:0] auto_job_id;
  logic core_busy;
  logic core_done_status;
  logic ingress_busy;
  logic ingress_done_status;
  logic result_busy;
  logic result_done_status;
  logic error_status;
  logic model_valid;
  logic input_valid;
  logic result_set;
  logic model_host_ready;
  logic activation_host_ready;
  logic [3:0] op_index;
  logic [31:0] busy_cycles;
  logic [31:0] compute_cycles;
  logic [31:0] pool_cycles;
  logic [31:0] param_cycles;
  logic auto_busy;
  logic auto_done_status;
  logic auto_error;
  logic auto_queue_full;
  logic auto_submit_ready;
  logic [4:0] auto_state;
  logic [7:0] auto_error_code;
  logic [31:0] auto_completed_job_id;
  logic [31:0] auto_job_cycles;
  logic [31:0] auto_dma_cycles;
  logic [31:0] auto_completed_jobs;

  int seed;
  int random_count;
  int plusarg_status;
  int random_seed_value;
  int core_pulses;
  int load_pulses;
  int result_pulses;
  int clear_pulses;
  int auto_submit_pulses;
  logic [31:0] expected_load_cfg;
  logic [31:0] expected_load_base;
  logic [31:0] expected_result_cfg;
  logic [31:0] expected_result_base;

  import "DPI-C" function int unsigned csr_apply_wstrb(
      input int unsigned old_value,
      input int unsigned new_value,
      input int strobe);
  import "DPI-C" function int unsigned csr_expected_id();
  import "DPI-C" function int unsigned csr_expected_status(
      input int core_busy,
      input int core_done,
      input int ingress_busy,
      input int ingress_done,
      input int result_busy,
      input int result_done,
      input int error,
      input int model_valid,
      input int input_valid,
      input int result_set,
      input int model_ready,
      input int activation_ready,
      input int op_index);

  lenet_axi_lite_regs dut (.*);

  always #5 clk = ~clk;

  always @(posedge clk) begin
    if (!rst_n) begin
      core_pulses <= 0;
      load_pulses <= 0;
      result_pulses <= 0;
      clear_pulses <= 0;
      auto_submit_pulses <= 0;
    end else begin
      if (core_start_pulse) core_pulses <= core_pulses + 1;
      if (load_start_pulse) load_pulses <= load_pulses + 1;
      if (result_start_pulse) result_pulses <= result_pulses + 1;
      if (clear_status_pulse) clear_pulses <= clear_pulses + 1;
      if (auto_submit_pulse)
        auto_submit_pulses <= auto_submit_pulses + 1;
    end
  end

  task automatic send_aw(
      input logic [ADDR_W-1:0] address,
      input int delay_cycles);
    begin
      repeat (delay_cycles) @(negedge clk);
      s_axi_awaddr = address;
      s_axi_awvalid = 1'b1;
      do @(posedge clk); while (!s_axi_awready);
      @(negedge clk);
      s_axi_awvalid = 1'b0;
    end
  endtask

  task automatic send_w(
      input logic [31:0] data,
      input logic [3:0] strobe,
      input int delay_cycles);
    begin
      repeat (delay_cycles) @(negedge clk);
      s_axi_wdata = data;
      s_axi_wstrb = strobe;
      s_axi_wvalid = 1'b1;
      do @(posedge clk); while (!s_axi_wready);
      @(negedge clk);
      s_axi_wvalid = 1'b0;
    end
  endtask

  task automatic axi_write(
      input logic [ADDR_W-1:0] address,
      input logic [31:0] data,
      input logic [3:0] strobe,
      input int ordering,
      input int response_stalls,
      input logic [1:0] expected_resp);
    logic [1:0] held_resp;
    begin
      s_axi_bready = 1'b0;
      fork
        send_aw(address, (ordering == 1) ? 3 : 0);
        send_w(data, strobe, (ordering == 2) ? 3 : 0);
      join
      while (!s_axi_bvalid) @(negedge clk);
      held_resp = s_axi_bresp;
      repeat (response_stalls) begin
        @(negedge clk);
        if (!s_axi_bvalid || (s_axi_bresp !== held_resp))
          $fatal(1, "CSR B response changed while stalled");
      end
      if (s_axi_bresp !== expected_resp)
        $fatal(1, "CSR write addr=%02h resp=%0h expected=%0h",
               address, s_axi_bresp, expected_resp);
      s_axi_bready = 1'b1;
      @(posedge clk);
      @(negedge clk);
      s_axi_bready = 1'b0;
      if (s_axi_bvalid)
        $fatal(1, "CSR BVALID did not clear");
    end
  endtask

  task automatic axi_read(
      input logic [ADDR_W-1:0] address,
      input int response_stalls,
      input logic [31:0] expected_data,
      input logic [1:0] expected_resp);
    logic [31:0] held_data;
    logic [1:0] held_resp;
    begin
      s_axi_rready = 1'b0;
      @(negedge clk);
      s_axi_araddr = address;
      s_axi_arvalid = 1'b1;
      do @(posedge clk); while (!s_axi_arready);
      @(negedge clk);
      s_axi_arvalid = 1'b0;
      while (!s_axi_rvalid) @(negedge clk);
      held_data = s_axi_rdata;
      held_resp = s_axi_rresp;
      repeat (response_stalls) begin
        @(negedge clk);
        if (!s_axi_rvalid ||
            (s_axi_rdata !== held_data) ||
            (s_axi_rresp !== held_resp))
          $fatal(1, "CSR R payload changed while stalled");
      end
      if ((s_axi_rdata !== expected_data) ||
          (s_axi_rresp !== expected_resp))
        $fatal(1,
            "CSR read addr=%02h data=%08h/%08h resp=%0h/%0h",
            address, s_axi_rdata, expected_data,
            s_axi_rresp, expected_resp);
      s_axi_rready = 1'b1;
      @(posedge clk);
      @(negedge clk);
      s_axi_rready = 1'b0;
      if (s_axi_rvalid)
        $fatal(1, "CSR RVALID did not clear");
    end
  endtask

  task automatic reset_dut;
    begin
      rst_n = 1'b0;
      s_axi_awaddr = 'x;
      s_axi_awvalid = 1'b0;
      s_axi_wdata = 'x;
      s_axi_wstrb = 'x;
      s_axi_wvalid = 1'b0;
      s_axi_bready = 1'b0;
      s_axi_araddr = 'x;
      s_axi_arvalid = 1'b0;
      s_axi_rready = 1'b0;
      core_busy = 1'b0;
      core_done_status = 1'b0;
      ingress_busy = 1'b0;
      ingress_done_status = 1'b0;
      result_busy = 1'b0;
      result_done_status = 1'b0;
      error_status = 1'b0;
      model_valid = 1'b0;
      input_valid = 1'b0;
      result_set = 1'b0;
      model_host_ready = 1'b0;
      activation_host_ready = 1'b0;
      op_index = '0;
      busy_cycles = '0;
      compute_cycles = '0;
      pool_cycles = '0;
      param_cycles = '0;
      auto_busy = 1'b0;
      auto_done_status = 1'b0;
      auto_error = 1'b0;
      auto_queue_full = 1'b0;
      auto_submit_ready = 1'b0;
      auto_state = '0;
      auto_error_code = '0;
      auto_completed_job_id = '0;
      auto_job_cycles = '0;
      auto_dma_cycles = '0;
      auto_completed_jobs = '0;
      repeat (4) @(negedge clk);
      rst_n = 1'b1;
      repeat (2) @(negedge clk);
      if ($isunknown({s_axi_awready, s_axi_wready, s_axi_bresp,
                      s_axi_bvalid, s_axi_arready, s_axi_rdata,
                      s_axi_rresp, s_axi_rvalid, core_start_pulse,
                      load_start_pulse, result_start_pulse,
                      clear_status_pulse, auto_submit_pulse, load_mode,
                      load_activation_set, load_bank_base, load_count,
                      load_base, result_bank_base, result_word_count,
                      result_base, auto_reload_model,
                      auto_weight_addr, auto_param_addr,
                      auto_input_addr, auto_result_addr,
                      auto_timeout_cycles, auto_job_id}))
        $fatal(1, "CSR reset left unknown outputs");
    end
  endtask

  initial begin
    logic [31:0] status_value;
    clk = 1'b0;
    seed = 20260725;
    random_count = 0;
    plusarg_status = $value$plusargs("SEED=%d", seed);
    plusarg_status = $value$plusargs("RANDOM_COUNT=%d", random_count);
    random_seed_value = $urandom(seed);
    $display("CSR seed=%0d random_count=%0d", seed, random_count);

    reset_dut();
    expected_load_cfg = 32'h0001_0000;
    expected_load_base = 32'h0000_0000;
    expected_result_cfg = 32'h0005_0000;
    expected_result_base = 32'h0000_0000;

    axi_read(8'h00, 2, csr_expected_id(), 2'b00);
    axi_read(8'h0c, 0, expected_load_cfg, 2'b00);
    axi_read(8'h14, 1, expected_result_cfg, 2'b00);
    axi_read(8'h30, 0, 32'd0, 2'b00);
    axi_read(8'h44, 0, 32'd10_000_000, 2'b00);

    core_busy = 1'b1;
    core_done_status = 1'b1;
    ingress_busy = 1'b1;
    ingress_done_status = 1'b0;
    result_busy = 1'b0;
    result_done_status = 1'b1;
    error_status = 1'b1;
    model_valid = 1'b1;
    input_valid = 1'b1;
    result_set = 1'b1;
    model_host_ready = 1'b0;
    activation_host_ready = 1'b1;
    op_index = 4'ha;
    status_value = csr_expected_status(
        1, 1, 1, 0, 0, 1, 1, 1, 1, 1, 0, 1, 10);
    axi_read(8'h08, 3, status_value, 2'b00);

    expected_load_cfg =
        csr_apply_wstrb(expected_load_cfg, 32'h05a5_003e, 4'hf);
    axi_write(8'h0c, 32'h05a5_003e, 4'hf, 0, 2, 2'b00);
    axi_read(8'h0c, 0, expected_load_cfg, 2'b00);
    if ({load_count, 10'd0, load_bank_base,
         load_activation_set, load_mode} !==
        {expected_load_cfg[31:16], 10'd0,
         expected_load_cfg[5:3], expected_load_cfg[2],
         expected_load_cfg[1:0]})
      $fatal(1, "CSR LOAD_CFG field decode mismatch");

    expected_load_base =
        csr_apply_wstrb(expected_load_base, 32'h1234_5678, 4'b0011);
    axi_write(8'h10, 32'h1234_5678, 4'b0011, 1, 0, 2'b00);
    axi_read(8'h10, 2, expected_load_base, 2'b00);

    expected_result_cfg =
        csr_apply_wstrb(expected_result_cfg, 32'h0007_0005, 4'hf);
    axi_write(8'h14, 32'h0007_0005, 4'hf, 2, 1, 2'b00);
    expected_result_base =
        csr_apply_wstrb(expected_result_base, 32'hdead_0099, 4'b0011);
    axi_write(8'h18, 32'hdead_0099, 4'b0011, 0, 0, 2'b00);
    axi_read(8'h14, 0, expected_result_cfg, 2'b00);
    axi_read(8'h18, 0, expected_result_base, 2'b00);

    busy_cycles = 32'd10001;
    compute_cycles = 32'd9184;
    pool_cycles = 32'd250;
    param_cycles = 32'd520;
    axi_read(8'h20, 0, busy_cycles, 2'b00);
    axi_read(8'h24, 1, compute_cycles, 2'b00);
    axi_read(8'h28, 0, pool_cycles, 2'b00);
    axi_read(8'h2c, 2, param_cycles, 2'b00);

    axi_write(8'h30, 32'h0000_0001, 4'b0001, 0, 0, 2'b00);
    axi_write(8'h34, 32'h1000_0000, 4'hf, 1, 1, 2'b00);
    axi_write(8'h38, 32'h1002_0000, 4'hf, 2, 0, 2'b00);
    axi_write(8'h3c, 32'h1003_0000, 4'hf, 0, 2, 2'b00);
    axi_write(8'h40, 32'h1004_0000, 4'hf, 1, 0, 2'b00);
    axi_write(8'h44, 32'd123456, 4'hf, 2, 1, 2'b00);
    axi_write(8'h48, 32'h55aa_1234, 4'hf, 0, 0, 2'b00);
    axi_read(8'h30, 0, 32'h0000_0001, 2'b00);
    axi_read(8'h34, 0, 32'h1000_0000, 2'b00);
    axi_read(8'h38, 0, 32'h1002_0000, 2'b00);
    axi_read(8'h3c, 0, 32'h1003_0000, 2'b00);
    axi_read(8'h40, 0, 32'h1004_0000, 2'b00);
    axi_read(8'h44, 0, 32'd123456, 2'b00);
    axi_read(8'h48, 0, 32'h55aa_1234, 2'b00);
    if (!auto_reload_model ||
        (auto_weight_addr != 32'h1000_0000) ||
        (auto_param_addr != 32'h1002_0000) ||
        (auto_input_addr != 32'h1003_0000) ||
        (auto_result_addr != 32'h1004_0000) ||
        (auto_timeout_cycles != 32'd123456) ||
        (auto_job_id != 32'h55aa_1234))
      $fatal(1, "CSR autonomous descriptor decode mismatch");

    auto_busy = 1'b1;
    auto_done_status = 1'b1;
    auto_error = 1'b1;
    auto_queue_full = 1'b1;
    auto_submit_ready = 1'b1;
    auto_state = 5'h15;
    auto_error_code = 8'ha7;
    auto_completed_job_id = 32'h1234_5678;
    auto_job_cycles = 32'd10025;
    auto_dma_cycles = 32'd42;
    auto_completed_jobs = 32'd7;
    status_value[25:16] = {auto_state, auto_submit_ready,
                           auto_queue_full, auto_error,
                           auto_done_status, auto_busy};
    axi_read(8'h08, 0, status_value, 2'b00);
    axi_read(8'h4c, 0, 32'h0000_151f, 2'b00);
    axi_read(8'h50, 0, 32'h0000_00a7, 2'b00);
    axi_read(8'h54, 0, 32'h1234_5678, 2'b00);
    axi_read(8'h58, 0, 32'd10025, 2'b00);
    axi_read(8'h5c, 0, 32'd42, 2'b00);
    axi_read(8'h60, 0, 32'd7, 2'b00);

    axi_write(8'h04, 32'h0000_001f, 4'b0001, 2, 3, 2'b00);
    repeat (2) @(negedge clk);
    if ((core_pulses != 1) || (load_pulses != 1) ||
        (result_pulses != 1) || (clear_pulses != 1) ||
        (auto_submit_pulses != 1))
      $fatal(1,
          "CSR control pulse count mismatch %0d %0d %0d %0d %0d",
          core_pulses, load_pulses, result_pulses, clear_pulses,
          auto_submit_pulses);

    axi_write(8'h00, 32'hffff_ffff, 4'hf, 0, 0, 2'b10);
    axi_write(8'h7c, 32'h1234_5678, 4'hf, 1, 1, 2'b10);
    axi_read(8'h7c, 1, 32'hdead_beef, 2'b10);
    $display("CSR DIRECTED PASSED");

    for (int tx = 0; tx < random_count; tx++) begin
      logic [7:0] address;
      logic [31:0] data;
      logic [3:0] strobe;
      logic [31:0] expected;
      int select;
      select = $urandom_range(0, 3);
      data = $urandom();
      strobe = 4'($urandom_range(0, 15));
      case (select)
        0: begin
          address = 8'h0c;
          expected_load_cfg =
              csr_apply_wstrb(expected_load_cfg, data, strobe);
          expected = expected_load_cfg;
        end
        1: begin
          address = 8'h10;
          expected_load_base =
              csr_apply_wstrb(expected_load_base, data, strobe);
          expected = expected_load_base;
        end
        2: begin
          address = 8'h14;
          expected_result_cfg =
              csr_apply_wstrb(expected_result_cfg, data, strobe);
          expected = expected_result_cfg;
        end
        default: begin
          address = 8'h18;
          expected_result_base =
              csr_apply_wstrb(expected_result_base, data, strobe);
          expected = expected_result_base;
        end
      endcase
      axi_write(address, data, strobe,
                $urandom_range(0, 2), $urandom_range(0, 4), 2'b00);
      axi_read(address, $urandom_range(0, 4), expected, 2'b00);
    end

    if (random_count > 0)
      $display("CSR RANDOM PASSED transactions=%0d seed=%0d",
               random_count, seed);
    $display("LENET_AXI_LITE_REGS TEST PASSED");
    $finish;
  end

endmodule
