`timescale 1ns/1ps

module tb_alexnet_axi_dma_simple_master_alignment;
  logic clk = 1'b0;
  logic rst_n, clear_error;
  logic cmd_valid, cmd_ready, cmd_s2mm;
  logic [31:0] cmd_buffer_addr;
  logic [25:0] cmd_length_bytes;
  logic [31:0] cmd_timeout_cycles;
  logic armed, busy, done, error;
  logic [3:0] error_code, state_debug;
  logic [31:0] last_status, active_cycles;
  logic [31:0] m_axi_awaddr, m_axi_wdata, m_axi_araddr, m_axi_rdata;
  logic [2:0] m_axi_awprot, m_axi_arprot;
  logic [3:0] m_axi_wstrb;
  logic m_axi_awvalid, m_axi_awready, m_axi_wvalid, m_axi_wready;
  logic [1:0] m_axi_bresp, m_axi_rresp;
  logic m_axi_bvalid, m_axi_bready, m_axi_arvalid, m_axi_arready;
  logic m_axi_rvalid, m_axi_rready;
  int write_step;
  logic expected_s2mm;
  logic [31:0] expected_buffer;
  logic default_cmd_valid, default_cmd_ready, default_error;
  logic [3:0] default_error_code;

  axi_dma_simple_master #(
      .POLL_INTERVAL(1), .DMA_ALIGNMENT_BYTES(8),
      .DEFAULT_TIMEOUT(32'd200)
  ) dut (.*);

  // The shared LeNet-facing default remains 16 bytes; it must continue to
  // reject the 8-byte-only address accepted by the AlexNet instance.
  axi_dma_simple_master u_default_alignment (
      .clk(clk), .rst_n(rst_n), .clear_error(1'b0),
      .cmd_valid(default_cmd_valid), .cmd_ready(default_cmd_ready),
      .cmd_s2mm(1'b0), .cmd_buffer_addr(32'h1000_0008),
      .cmd_length_bytes(26'd8), .cmd_timeout_cycles(32'd200),
      .armed(), .busy(), .done(), .error(default_error),
      .error_code(default_error_code), .last_status(), .active_cycles(),
      .state_debug(), .m_axi_awaddr(), .m_axi_awprot(),
      .m_axi_awvalid(), .m_axi_awready(1'b0), .m_axi_wdata(),
      .m_axi_wstrb(), .m_axi_wvalid(), .m_axi_wready(1'b0),
      .m_axi_bresp(2'b00), .m_axi_bvalid(1'b0), .m_axi_bready(),
      .m_axi_araddr(), .m_axi_arprot(), .m_axi_arvalid(),
      .m_axi_arready(1'b0), .m_axi_rdata(32'd0), .m_axi_rresp(2'b00),
      .m_axi_rvalid(1'b0), .m_axi_rready()
  );

  // This is a protocol simulation at the project's sole 200 MHz clock.
  always #2.5 clk = ~clk;

  function automatic logic [31:0] expected_write_address(input int step);
    case (step % 4)
      0: expected_write_address = 32'ha001_0000 +
          (expected_s2mm ? 32'h30 : 32'h00);
      1: expected_write_address = 32'ha001_0000 +
          (expected_s2mm ? 32'h34 : 32'h04);
      2: expected_write_address = 32'ha001_0000 +
          (expected_s2mm ? 32'h48 : 32'h18);
      default: expected_write_address = 32'ha001_0000 +
          (expected_s2mm ? 32'h58 : 32'h28);
    endcase
  endfunction

  function automatic logic [31:0] expected_write_data(input int step);
    case (step % 4)
      0: expected_write_data = 32'h0000_5001;
      1: expected_write_data = 32'h0000_7000;
      2: expected_write_data = expected_buffer;
      default: expected_write_data = 32'd8;
    endcase
  endfunction

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      m_axi_bvalid <= 1'b0;
      m_axi_bresp <= 2'b00;
      m_axi_rvalid <= 1'b0;
      m_axi_rresp <= 2'b00;
      m_axi_rdata <= 32'd0;
      write_step <= 0;
    end else begin
      if (m_axi_awvalid && m_axi_awready &&
          m_axi_wvalid && m_axi_wready) begin
        if (m_axi_awaddr != expected_write_address(write_step) ||
            m_axi_wdata != expected_write_data(write_step) ||
            m_axi_wstrb != 4'hf)
          $fatal(1, "AXI DMA programming mismatch step=%0d addr=%h data=%h",
                 write_step, m_axi_awaddr, m_axi_wdata);
        m_axi_bvalid <= 1'b1;
        m_axi_bresp <= 2'b00;
        write_step <= write_step + 1;
      end else if (m_axi_bvalid && m_axi_bready) begin
        m_axi_bvalid <= 1'b0;
      end

      if (m_axi_arvalid && m_axi_arready) begin
        if (m_axi_araddr != 32'ha001_0000 +
            (expected_s2mm ? 32'h34 : 32'h04))
          $fatal(1, "AXI DMA status address mismatch");
        m_axi_rvalid <= 1'b1;
        m_axi_rresp <= 2'b00;
        m_axi_rdata <= 32'h0000_1000;
      end else if (m_axi_rvalid && m_axi_rready) begin
        m_axi_rvalid <= 1'b0;
      end
    end
  end

  task automatic run_valid_transfer(
      input logic direction,
      input logic [31:0] address);
    bit saw_armed;
    int first_step;
    begin
      expected_s2mm = direction;
      expected_buffer = address;
      first_step = write_step;
      cmd_s2mm = direction;
      cmd_buffer_addr = address;
      cmd_length_bytes = 26'd8;
      cmd_timeout_cycles = 32'd200;
      @(negedge clk);
      cmd_valid = 1'b1;
      do @(posedge clk); while (!cmd_ready);
      @(negedge clk);
      cmd_valid = 1'b0;
      saw_armed = 1'b0;
      while (!done && !error) begin
        @(negedge clk);
        if (armed) saw_armed = 1'b1;
      end
      if (error || !done || !saw_armed || write_step != first_step + 4)
        $fatal(1, "8-byte-aligned DMA transfer failed dir=%0b", direction);
      @(negedge clk);
    end
  endtask

  initial begin
    rst_n = 1'b0;
    clear_error = 1'b0;
    cmd_valid = 1'b0;
    cmd_s2mm = 1'b0;
    cmd_buffer_addr = 0;
    cmd_length_bytes = 0;
    cmd_timeout_cycles = 0;
    m_axi_awready = 1'b1;
    m_axi_wready = 1'b1;
    m_axi_arready = 1'b1;
    expected_s2mm = 1'b0;
    expected_buffer = 0;
    default_cmd_valid = 1'b0;
    repeat (5) @(negedge clk);
    rst_n = 1'b1;
    repeat (2) @(negedge clk);

    // Both addresses are legal with DRE but intentionally not 16-byte aligned.
    run_valid_transfer(1'b0, 32'h1000_0008);
    run_valid_transfer(1'b1, 32'h2000_0008);

    cmd_s2mm = 1'b0;
    cmd_buffer_addr = 32'h1000_0004;
    cmd_length_bytes = 26'd8;
    cmd_timeout_cycles = 32'd200;
    @(negedge clk);
    cmd_valid = 1'b1;
    do @(posedge clk); while (!cmd_ready);
    @(negedge clk);
    cmd_valid = 1'b0;
    @(negedge clk);
    if (!error || error_code != 4'd1 || armed)
      $fatal(1, "4-byte-aligned address was not rejected");
    clear_error = 1'b1;
    @(posedge clk);
    @(negedge clk);
    clear_error = 1'b0;

    @(negedge clk);
    default_cmd_valid = 1'b1;
    do @(posedge clk); while (!default_cmd_ready);
    @(negedge clk);
    default_cmd_valid = 1'b0;
    @(negedge clk);
    if (!default_error || default_error_code != 4'd1)
      $fatal(1, "LeNet-compatible 16-byte default alignment changed");

    $display("ALEXNET_AXI_DMA_ALIGNMENT_TEST_PASSED transfers=2 alexnet_alignment=8 default_alignment=16 clock_mhz=200");
    $finish;
  end
endmodule
