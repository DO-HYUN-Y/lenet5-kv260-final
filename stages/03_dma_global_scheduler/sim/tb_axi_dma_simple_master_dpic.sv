`timescale 1ns/1ps

module tb_axi_dma_simple_master_dpic;
  localparam int DMA_LEN_W = 26;

  logic clk;
  logic rst_n;
  logic clear_error;
  logic cmd_valid;
  logic cmd_ready;
  logic cmd_s2mm;
  logic [31:0] cmd_buffer_addr;
  logic [DMA_LEN_W-1:0] cmd_length_bytes;
  logic [31:0] cmd_timeout_cycles;
  logic armed;
  logic busy;
  logic done;
  logic error;
  logic [3:0] error_code;
  logic [31:0] last_status;
  logic [31:0] active_cycles;
  logic [3:0] state_debug;
  logic [31:0] m_axi_awaddr;
  logic [2:0] m_axi_awprot;
  logic m_axi_awvalid;
  logic m_axi_awready;
  logic [31:0] m_axi_wdata;
  logic [3:0] m_axi_wstrb;
  logic m_axi_wvalid;
  logic m_axi_wready;
  logic [1:0] m_axi_bresp;
  logic m_axi_bvalid;
  logic m_axi_bready;
  logic [31:0] m_axi_araddr;
  logic [2:0] m_axi_arprot;
  logic m_axi_arvalid;
  logic m_axi_arready;
  logic [31:0] m_axi_rdata;
  logic [1:0] m_axi_rresp;
  logic m_axi_rvalid;
  logic m_axi_rready;

  int seed;
  int random_count;
  int plusarg_status;
  int random_seed_value;
  int cycle_count;
  bit random_backpressure;

  bit aw_seen;
  bit w_seen;
  logic [31:0] aw_hold;
  logic [31:0] w_hold;
  int b_delay;
  int r_delay;
  int expected_step;
  int poll_index;
  int complete_after;
  int b_error_step;
  bit inject_rresp_error;
  bit inject_status_error;
  bit never_complete;
  logic expected_s2mm;
  logic [31:0] expected_addr;
  logic [31:0] expected_length;

  import "DPI-C" function int unsigned dma_golden_write_addr(
      input int s2mm, input int step);
  import "DPI-C" function int unsigned dma_golden_write_data(
      input int step, input int unsigned buffer_addr,
      input int unsigned length_bytes);
  import "DPI-C" function int unsigned dma_golden_status_addr(
      input int s2mm);
  import "DPI-C" function int unsigned dma_golden_status(
      input int poll_index, input int complete_after,
      input int inject_error);

  axi_dma_simple_master #(
    .POLL_INTERVAL(2),
    .DEFAULT_TIMEOUT(32'd200)
  ) dut (.*);

  always #5 clk = ~clk;

  always @(posedge clk) begin
    if (!rst_n)
      cycle_count <= 0;
    else
      cycle_count <= cycle_count + 1;
  end

  // AXI-Lite slave driver. Ready and response latency are independent to
  // exercise split AW/W handshakes and delayed B/R responses.
  always @(negedge clk) begin
    if (!rst_n) begin
      m_axi_awready = 1'b0;
      m_axi_wready = 1'b0;
      m_axi_arready = 1'b0;
    end else begin
      m_axi_awready =
          !aw_seen && !m_axi_bvalid &&
          (!random_backpressure || $urandom_range(0, 3) != 0);
      m_axi_wready =
          !w_seen && !m_axi_bvalid &&
          (!random_backpressure || $urandom_range(0, 3) != 0);
      m_axi_arready =
          !m_axi_rvalid &&
          (!random_backpressure || $urandom_range(0, 3) != 0);
    end
  end

  always @(posedge clk) begin : axi_slave_model
    bit aw_fire;
    bit w_fire;
    logic [31:0] committed_addr;
    logic [31:0] committed_data;
    if (!rst_n) begin
      aw_seen = 1'b0;
      w_seen = 1'b0;
      aw_hold = 32'd0;
      w_hold = 32'd0;
      b_delay = 0;
      r_delay = 0;
      m_axi_bvalid <= 1'b0;
      m_axi_bresp <= 2'b00;
      m_axi_rvalid <= 1'b0;
      m_axi_rresp <= 2'b00;
      m_axi_rdata <= 32'd0;
    end else begin
      aw_fire = m_axi_awvalid && m_axi_awready;
      w_fire = m_axi_wvalid && m_axi_wready;

      if (aw_fire) begin
        aw_hold = m_axi_awaddr;
        aw_seen = 1'b1;
      end
      if (w_fire) begin
        w_hold = m_axi_wdata;
        w_seen = 1'b1;
        if (m_axi_wstrb !== 4'hf)
          $fatal(1,
              "DMA_MASTER WSTRB cycle=%0d got=%h expected=f",
              cycle_count, m_axi_wstrb);
      end

      if (aw_seen && w_seen && !m_axi_bvalid && (b_delay == 0)) begin
        committed_addr = aw_hold;
        committed_data = w_hold;
        if (committed_addr !==
            dma_golden_write_addr(expected_s2mm, expected_step))
          $fatal(1,
              "DMA_MASTER AW cycle=%0d step=%0d got=%08h expected=%08h",
              cycle_count, expected_step, committed_addr,
              dma_golden_write_addr(expected_s2mm, expected_step));
        if (committed_data !==
            dma_golden_write_data(
                expected_step, expected_addr, expected_length))
          $fatal(1,
              "DMA_MASTER W cycle=%0d step=%0d got=%08h expected=%08h",
              cycle_count, expected_step, committed_data,
              dma_golden_write_data(
                  expected_step, expected_addr, expected_length));
        m_axi_bresp <=
            (expected_step == b_error_step) ? 2'b10 : 2'b00;
        b_delay = random_backpressure ? $urandom_range(1, 4) : 1;
        aw_seen = 1'b0;
        w_seen = 1'b0;
        expected_step++;
      end

      if (b_delay > 0) begin
        b_delay--;
        if (b_delay == 0)
          m_axi_bvalid <= 1'b1;
      end
      if (m_axi_bvalid && m_axi_bready)
        m_axi_bvalid <= 1'b0;

      if (m_axi_arvalid && m_axi_arready) begin
        if (m_axi_araddr !== dma_golden_status_addr(expected_s2mm))
          $fatal(1,
              "DMA_MASTER AR cycle=%0d got=%08h expected=%08h",
              cycle_count, m_axi_araddr,
              dma_golden_status_addr(expected_s2mm));
        m_axi_rresp <= inject_rresp_error ? 2'b10 : 2'b00;
        m_axi_rdata <= never_complete
            ? 32'd0
            : dma_golden_status(
                poll_index, complete_after, inject_status_error);
        poll_index++;
        r_delay = random_backpressure ? $urandom_range(1, 4) : 1;
      end
      if (r_delay > 0) begin
        r_delay--;
        if (r_delay == 0)
          m_axi_rvalid <= 1'b1;
      end
      if (m_axi_rvalid && m_axi_rready)
        m_axi_rvalid <= 1'b0;
    end
  end

  task automatic pulse_clear;
    begin
      @(negedge clk);
      clear_error = 1'b1;
      @(negedge clk);
      clear_error = 1'b0;
      repeat (2) @(negedge clk);
      if (error || busy || !cmd_ready)
        $fatal(1,
            "DMA_MASTER recovery cycle=%0d busy=%0d error=%0d ready=%0d",
            cycle_count, busy, error, cmd_ready);
    end
  endtask

  task automatic configure_model(
      input logic s2mm,
      input logic [31:0] address,
      input logic [DMA_LEN_W-1:0] length,
      input int finish_poll,
      input int write_error_step,
      input bit read_error,
      input bit status_error,
      input bit no_completion);
    begin
      expected_s2mm = s2mm;
      expected_addr = address;
      expected_length = 32'(length);
      expected_step = 0;
      poll_index = 0;
      complete_after = finish_poll;
      b_error_step = write_error_step;
      inject_rresp_error = read_error;
      inject_status_error = status_error;
      never_complete = no_completion;
      aw_seen = 1'b0;
      w_seen = 1'b0;
      b_delay = 0;
      r_delay = 0;
    end
  endtask

  task automatic run_command(
      input logic s2mm,
      input logic [31:0] address,
      input logic [DMA_LEN_W-1:0] length,
      input logic [31:0] timeout,
      input logic [3:0] expected_error,
      input bit expect_armed);
    int guard;
    bit saw_armed;
    begin
      cmd_s2mm = s2mm;
      cmd_buffer_addr = address;
      cmd_length_bytes = length;
      cmd_timeout_cycles = timeout;
      @(negedge clk);
      cmd_valid = 1'b1;
      do @(posedge clk); while (!cmd_ready);
      @(negedge clk);
      cmd_valid = 1'b0;

      saw_armed = 1'b0;
      guard = 0;
      while (!done && !error && guard < 2000) begin
        @(negedge clk);
        if (armed)
          saw_armed = 1'b1;
        guard++;
      end
      if (guard >= 2000)
        $fatal(1, "DMA_MASTER timeout waiting for DUT completion");
      if (armed)
        saw_armed = 1'b1;
      if (saw_armed != expect_armed)
        $fatal(1,
            "DMA_MASTER armed mismatch got=%0d expected=%0d",
            saw_armed, expect_armed);
      if (expected_error == 0) begin
        if (error || !done || (expected_step != 4))
          $fatal(1,
              "DMA_MASTER normal result done=%0d error=%0d writes=%0d",
              done, error, expected_step);
      end else begin
        if (!error || (error_code != expected_error))
          $fatal(1,
              "DMA_MASTER error got=%0d/%0d expected=%0d",
              error, error_code, expected_error);
      end
      @(negedge clk);
    end
  endtask

  task automatic reset_dut;
    begin
      rst_n = 1'b0;
      clear_error = 1'bx;
      cmd_valid = 1'bx;
      cmd_s2mm = 1'bx;
      cmd_buffer_addr = 'x;
      cmd_length_bytes = 'x;
      cmd_timeout_cycles = 'x;
      repeat (5) @(negedge clk);
      clear_error = 1'b0;
      cmd_valid = 1'b0;
      cmd_s2mm = 1'b0;
      cmd_buffer_addr = 32'd0;
      cmd_length_bytes = '0;
      cmd_timeout_cycles = 32'd0;
      rst_n = 1'b1;
      repeat (3) @(negedge clk);
      if ($isunknown({
          cmd_ready, armed, busy, done, error, error_code,
          last_status, active_cycles, state_debug,
          m_axi_awaddr, m_axi_awprot, m_axi_awvalid,
          m_axi_wdata, m_axi_wstrb, m_axi_wvalid, m_axi_bready,
          m_axi_araddr, m_axi_arprot, m_axi_arvalid, m_axi_rready
      }))
        $fatal(1, "DMA_MASTER reset left unknown outputs");
    end
  endtask

  initial begin
    clk = 1'b0;
    seed = 20260725;
    random_count = 0;
    plusarg_status = $value$plusargs("SEED=%d", seed);
    plusarg_status = $value$plusargs("RANDOM_COUNT=%d", random_count);
    random_seed_value = $urandom(seed);
    random_backpressure = 1'b0;

    reset_dut();
    $display("DMA_MASTER seed=%0d random_count=%0d",
             seed, random_count);

    configure_model(1'b0, 32'h1000_0000, 26'd1024,
                    2, -1, 0, 0, 0);
    run_command(1'b0, 32'h1000_0000, 26'd1024,
                32'd200, 4'd0, 1);

    configure_model(1'b1, 32'h2000_0000, 26'd10,
                    1, -1, 0, 0, 0);
    run_command(1'b1, 32'h2000_0000, 26'd10,
                32'd200, 4'd0, 1);

    configure_model(1'b0, 32'h1000_0004, 26'd64,
                    1, -1, 0, 0, 0);
    run_command(1'b0, 32'h1000_0004, 26'd64,
                32'd200, 4'd1, 0);
    pulse_clear();

    configure_model(1'b0, 32'h1000_0000, 26'd0,
                    1, -1, 0, 0, 0);
    run_command(1'b0, 32'h1000_0000, 26'd0,
                32'd200, 4'd1, 0);
    pulse_clear();

    configure_model(1'b0, 32'h1000_0000, 26'd64,
                    1, 2, 0, 0, 0);
    run_command(1'b0, 32'h1000_0000, 26'd64,
                32'd200, 4'd2, 0);
    pulse_clear();

    configure_model(1'b0, 32'h1000_0000, 26'd64,
                    1, -1, 1, 0, 0);
    run_command(1'b0, 32'h1000_0000, 26'd64,
                32'd200, 4'd3, 1);
    pulse_clear();

    configure_model(1'b1, 32'h2000_0000, 26'd64,
                    1, -1, 0, 1, 0);
    run_command(1'b1, 32'h2000_0000, 26'd64,
                32'd200, 4'd4, 1);
    pulse_clear();

    configure_model(1'b0, 32'h1000_0000, 26'd64,
                    999, -1, 0, 0, 1);
    run_command(1'b0, 32'h1000_0000, 26'd64,
                32'd20, 4'd5, 1);
    pulse_clear();

    // Reset while the DMA is polling must cancel every visible transaction.
    configure_model(1'b0, 32'h1000_0000, 26'd128,
                    999, -1, 0, 0, 1);
    cmd_s2mm = 1'b0;
    cmd_buffer_addr = 32'h1000_0000;
    cmd_length_bytes = 26'd128;
    cmd_timeout_cycles = 32'd200;
    @(negedge clk);
    cmd_valid = 1'b1;
    do @(posedge clk); while (!cmd_ready);
    @(negedge clk);
    cmd_valid = 1'b0;
    while (!armed) @(negedge clk);
    rst_n = 1'b0;
    repeat (3) @(negedge clk);
    rst_n = 1'b1;
    repeat (3) @(negedge clk);
    if (busy || error || !cmd_ready)
      $fatal(1, "DMA_MASTER mid-operation reset failed");

    $display("DMA_MASTER DIRECTED PASSED");

    random_backpressure = 1'b1;
    for (int tx = 0; tx < random_count; tx++) begin
      logic direction;
      logic [31:0] address;
      logic [DMA_LEN_W-1:0] length;
      direction = $urandom_range(0, 1);
      address = 32'h3000_0000 + 32'($urandom_range(0, 4095)) * 16;
      length = DMA_LEN_W'($urandom_range(1, 4096));
      configure_model(direction, address, length,
                      $urandom_range(0, 5), -1, 0, 0, 0);
      run_command(direction, address, length,
                  32'd1000, 4'd0, 1);
    end
    if (random_count > 0)
      $display("DMA_MASTER RANDOM PASSED commands=%0d seed=%0d",
               random_count, seed);

    $display("AXI_DMA_SIMPLE_MASTER TEST PASSED");
    $finish;
  end

endmodule
