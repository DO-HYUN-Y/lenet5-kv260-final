`timescale 1ns/1ps

module tb_lenet5_accelerator_core;
  localparam int DATA_W = 8;
  localparam int ACC_W = 32;
  localparam int NG = 4;
  localparam int NC = 8;
  localparam int WGT_MEM_DEPTH = 2048;
  localparam int WGT_ADDR_W = $clog2(WGT_MEM_DEPTH);
  localparam int BANK_ADDR_W = 9;
  localparam int TOTAL_PARAMS = 236;
  localparam int PARAM_ADDR_W = $clog2(TOTAL_PARAMS);
  localparam int SCALE_W = 18;
  localparam int LAST_WEIGHT_ADDR = 1448;

  logic clk;
  logic rst_n;
  logic start;
  logic model_valid;
  logic busy;
  logic done;
  logic irq;
  logic result_set;
  logic [3:0] op_index;
  logic [31:0] busy_cycles;
  logic [31:0] compute_cycles;
  logic [31:0] pool_cycles;
  logic [31:0] param_cycles;

  logic weight_host_wr_en [0:NC-1];
  logic [WGT_ADDR_W-1:0] weight_host_wr_addr;
  logic [2*NG*DATA_W-1:0] weight_host_wr_data [0:NC-1];
  logic param_host_wr_en;
  logic [PARAM_ADDR_W-1:0] param_host_wr_addr;
  logic signed [ACC_W-1:0] param_host_wr_bias;
  logic signed [SCALE_W-1:0] param_host_wr_scale;
  logic model_host_ready;

  logic activation_host_set;
  logic activation_host_en [0:NC-1];
  logic [1:0] activation_host_we [0:NC-1];
  logic [BANK_ADDR_W-1:0] activation_host_addr [0:NC-1];
  logic [15:0] activation_host_wdata [0:NC-1];
  logic [15:0] activation_host_rdata [0:NC-1];
  logic activation_host_rvalid;
  logic activation_host_ready;

  int lane_count [0:9];
  int completed_ops;

  lenet5_accelerator_core dut (.*);

  always #5 clk = ~clk;

  always @(posedge clk) begin
    if (rst_n) begin
      for (int c = 0; c < NC; c++) begin
        if (dut.core_bank_we[c]) begin
          lane_count[op_index] += dut.core_bank_wstrb[c][0];
          lane_count[op_index] += dut.core_bank_wstrb[c][1];
        end
      end
    end
  end

  task automatic host_idle;
    begin
      for (int c = 0; c < NC; c++) begin
        weight_host_wr_en[c] = 1'b0;
        weight_host_wr_data[c] = '0;
        activation_host_en[c] = 1'b0;
        activation_host_we[c] = 2'b00;
        activation_host_addr[c] = '0;
        activation_host_wdata[c] = '0;
      end
      param_host_wr_en = 1'b0;
    end
  endtask

  task automatic preload_zero_weights;
    begin
      for (int addr = 0; addr <= LAST_WEIGHT_ADDR; addr++) begin
        @(negedge clk);
        weight_host_wr_addr = WGT_ADDR_W'(addr);
        for (int c = 0; c < NC; c++) begin
          weight_host_wr_en[c] = 1'b1;
          weight_host_wr_data[c] = '0;
        end
      end
      @(negedge clk);
      for (int c = 0; c < NC; c++)
        weight_host_wr_en[c] = 1'b0;
      repeat (2) @(negedge clk);
    end
  endtask

  function automatic int preload_bias(input int addr);
    int logit;
    begin
      if (addr >= 226) begin
        logit = addr - 226 - 5;
        preload_bias = 2 * logit;
      end else begin
        preload_bias = 2;
      end
    end
  endfunction

  task automatic preload_params;
    begin
      for (int addr = 0; addr < TOTAL_PARAMS; addr++) begin
        @(negedge clk);
        param_host_wr_en = 1'b1;
        param_host_wr_addr = PARAM_ADDR_W'(addr);
        param_host_wr_bias = preload_bias(addr);
        param_host_wr_scale = 18'sd65536;
      end
      @(negedge clk);
      param_host_wr_en = 1'b0;
    end
  endtask

  task automatic preload_zero_image;
    begin
      activation_host_set = 1'b0;
      for (int addr = 0; addr < 512; addr++) begin
        @(negedge clk);
        activation_host_en[0] = 1'b1;
        activation_host_we[0] = 2'b11;
        activation_host_addr[0] = BANK_ADDR_W'(addr);
        activation_host_wdata[0] = 16'h0000;
      end
      @(negedge clk);
      activation_host_en[0] = 1'b0;
      activation_host_we[0] = 2'b00;
    end
  endtask

  task automatic check_lane_counts;
    begin
      if (lane_count[0] != 28 * 28 * 6)
        $fatal(1, "TOP C1 lanes got=%0d", lane_count[0]);
      if (lane_count[2] != 10 * 10 * 8)
        $fatal(1, "TOP C3p0 lanes got=%0d", lane_count[2]);
      if (lane_count[3] != 10 * 10 * 8)
        $fatal(1, "TOP C3p1 lanes got=%0d", lane_count[3]);
      if (lane_count[5] != 64)
        $fatal(1, "TOP C5p0 lanes got=%0d", lane_count[5]);
      if (lane_count[6] != 56)
        $fatal(1, "TOP C5p1 lanes got=%0d", lane_count[6]);
      if (lane_count[7] != 64)
        $fatal(1, "TOP F6p0 lanes got=%0d", lane_count[7]);
      if (lane_count[8] != 20)
        $fatal(1, "TOP F6p1 lanes got=%0d", lane_count[8]);
      if (lane_count[9] != 10)
        $fatal(1, "TOP OUT lanes got=%0d", lane_count[9]);
      if ((lane_count[1] != 0) || (lane_count[4] != 0))
        $fatal(1, "TOP pool ops emitted core lanes");
    end
  endtask

  task automatic read_and_check_logits;
    begin
      @(negedge clk);
      activation_host_set = 1'b1;
      for (int c = 0; c < NC; c++) begin
        activation_host_en[c] = (c < 5);
        activation_host_we[c] = 2'b00;
        activation_host_addr[c] = '0;
      end
      @(posedge clk);
      #1;
      if (!activation_host_rvalid)
        $fatal(1, "TOP logits host_rvalid missing");
      for (int c = 0; c < 5; c++) begin
        int got_lo;
        int got_hi;
        int exp_lo;
        int exp_hi;
        got_lo = $signed(activation_host_rdata[c][7:0]);
        got_hi = $signed(activation_host_rdata[c][15:8]);
        exp_lo = 2 * c - 5;
        exp_hi = 2 * c + 1 - 5;
        if ((got_lo != exp_lo) || (got_hi != exp_hi))
          $fatal(1,
              "TOP logit bank=%0d got=(%0d,%0d) exp=(%0d,%0d)",
              c, got_lo, got_hi, exp_lo, exp_hi);
      end
      @(negedge clk);
      for (int c = 0; c < NC; c++)
        activation_host_en[c] = 1'b0;
    end
  endtask

  initial begin
    clk = 1'b0;
    rst_n = 1'b0;
    start = 1'b0;
    model_valid = 1'b0;
    weight_host_wr_addr = '0;
    param_host_wr_addr = '0;
    param_host_wr_bias = '0;
    param_host_wr_scale = '0;
    activation_host_set = 1'b0;
    completed_ops = 0;
    for (int op = 0; op < 10; op++)
      lane_count[op] = 0;
    host_idle();

    repeat (6) @(negedge clk);
    rst_n = 1'b1;
    if (!model_host_ready || !activation_host_ready)
      $fatal(1, "TOP preload ports not ready");

    preload_zero_weights();
    preload_params();
    preload_zero_image();
    host_idle();

    @(negedge clk);
    model_valid = 1'b1;
    start = 1'b1;
    @(negedge clk);
    start = 1'b0;

    for (int guard = 0; guard < 100000 && !done; guard++)
      @(negedge clk);
    if (!done)
      $fatal(1, "TOP timeout op=%0d busy=%0d cycles=%0d",
             op_index, busy, busy_cycles);
    if (!irq || !result_set || busy)
      $fatal(1, "TOP completion irq=%0d result=%0d busy=%0d",
             irq, result_set, busy);
    if ((compute_cycles == 0) || (pool_cycles == 0) ||
        (param_cycles != 8 * 65))
      $fatal(1,
          "TOP performance counters compute=%0d pool=%0d param=%0d",
          compute_cycles, pool_cycles, param_cycles);

    check_lane_counts();
    read_and_check_logits();

    $display(
        "LENET5_ACCELERATOR_CORE TEST PASSED busy=%0d compute=%0d pool=%0d param=%0d",
        busy_cycles, compute_cycles, pool_cycles, param_cycles);
    $finish;
  end

endmodule
