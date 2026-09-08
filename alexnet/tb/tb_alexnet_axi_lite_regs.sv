`timescale 1ns/1ps

module tb_alexnet_axi_lite_regs;
  logic clk = 1'b0;
  logic rst;
  logic [7:0] s_axi_awaddr;
  logic s_axi_awvalid, s_axi_awready;
  logic [31:0] s_axi_wdata;
  logic [3:0] s_axi_wstrb;
  logic s_axi_wvalid, s_axi_wready;
  logic [1:0] s_axi_bresp;
  logic s_axi_bvalid, s_axi_bready;
  logic [7:0] s_axi_araddr;
  logic s_axi_arvalid, s_axi_arready;
  logic [31:0] s_axi_rdata;
  logic [1:0] s_axi_rresp;
  logic s_axi_rvalid, s_axi_rready;
  logic core_start_valid, core_start_ready;
  logic [15:0] core_start_tag;
  logic [63:0] active_input_base, active_activation_a_base;
  logic [63:0] active_activation_b_base, active_weights_base;
  logic [63:0] active_parameters_base, active_final_output_base;
  logic [31:0] active_dma_timeout_cycles;
  logic core_busy, inference_done, inference_failed, core_fault;
  logic [3:0] fault_code;
  logic [7:0] fault_detail;
  logic [4:0] graph_phase;
  logic [3:0] active_layer_id;
  logic [15:0] active_inference_tag;
  logic [2:0] completed_conv_layers;
  logic [1:0] completed_fc_layers;
  logic pool5_cache_valid, dma_busy, dma_error;
  logic [3:0] dma_error_code;
  logic [2:0] dma_active_source;
  logic [31:0] dma_accepted_requests, dma_issued_commands;
  logic [31:0] dma_completed_transfers, conv_storage_completed_tiles;
  logic irq, start_pending, done_sticky, failed_sticky, fault_sticky;
  logic start_rejected_sticky;
  logic [31:0] read_value;
  logic [1:0] read_response;

  alexnet_axi_lite_regs dut (.*);

  always #2.5 clk = ~clk;

  task automatic drive_aw(input logic [7:0] address);
    begin
      @(negedge clk);
      s_axi_awaddr = address;
      s_axi_awvalid = 1'b1;
      do @(posedge clk); while (!s_axi_awready);
      @(negedge clk);
      s_axi_awvalid = 1'b0;
    end
  endtask

  task automatic drive_w(
      input logic [31:0] data,
      input logic [3:0] strobe);
    begin
      @(negedge clk);
      s_axi_wdata = data;
      s_axi_wstrb = strobe;
      s_axi_wvalid = 1'b1;
      do @(posedge clk); while (!s_axi_wready);
      @(negedge clk);
      s_axi_wvalid = 1'b0;
    end
  endtask

  task automatic axi_write(
      input logic [7:0] address,
      input logic [31:0] data,
      input logic [3:0] strobe,
      input int order,
      input logic [1:0] expected_response);
    logic [1:0] held_response;
    begin
      case (order)
        0: fork
          drive_aw(address);
          drive_w(data, strobe);
        join
        1: begin
          drive_aw(address);
          repeat (2) @(negedge clk);
          drive_w(data, strobe);
        end
        default: begin
          drive_w(data, strobe);
          repeat (2) @(negedge clk);
          drive_aw(address);
        end
      endcase
      while (!s_axi_bvalid) @(negedge clk);
      held_response = s_axi_bresp;
      repeat (2) begin
        @(negedge clk);
        if (!s_axi_bvalid || s_axi_bresp != held_response)
          $fatal(1, "AXI B response changed under backpressure");
      end
      if (held_response != expected_response)
        $fatal(1, "AXI write response mismatch addr=%h got=%b expected=%b",
               address, held_response, expected_response);
      s_axi_bready = 1'b1;
      @(posedge clk);
      @(negedge clk);
      s_axi_bready = 1'b0;
    end
  endtask

  task automatic axi_read(
      input logic [7:0] address,
      output logic [31:0] data,
      output logic [1:0] response);
    logic [31:0] held_data;
    logic [1:0] held_response;
    begin
      @(negedge clk);
      s_axi_araddr = address;
      s_axi_arvalid = 1'b1;
      do @(posedge clk); while (!s_axi_arready);
      @(negedge clk);
      s_axi_arvalid = 1'b0;
      while (!s_axi_rvalid) @(negedge clk);
      held_data = s_axi_rdata;
      held_response = s_axi_rresp;
      repeat (2) begin
        @(negedge clk);
        if (!s_axi_rvalid ||
            {s_axi_rdata, s_axi_rresp} != {held_data, held_response})
          $fatal(1, "AXI R payload changed under backpressure");
      end
      data = held_data;
      response = held_response;
      s_axi_rready = 1'b1;
      @(posedge clk);
      @(negedge clk);
      s_axi_rready = 1'b0;
    end
  endtask

  task automatic expect_read(
      input logic [7:0] address,
      input logic [31:0] expected,
      input logic [31:0] mask = 32'hffff_ffff);
    begin
      axi_read(address, read_value, read_response);
      if (read_response != 2'b00 ||
          (read_value & mask) != (expected & mask))
        $fatal(1, "AXI read mismatch addr=%h got=%h resp=%b expected=%h mask=%h",
               address, read_value, read_response, expected, mask);
    end
  endtask

  initial begin
    rst = 1'b1;
    s_axi_awaddr = 0;
    s_axi_awvalid = 0;
    s_axi_wdata = 0;
    s_axi_wstrb = 0;
    s_axi_wvalid = 0;
    s_axi_bready = 0;
    s_axi_araddr = 0;
    s_axi_arvalid = 0;
    s_axi_rready = 0;
    core_start_ready = 0;
    core_busy = 0;
    inference_done = 0;
    inference_failed = 0;
    core_fault = 0;
    fault_code = 0;
    fault_detail = 0;
    graph_phase = 0;
    active_layer_id = 0;
    active_inference_tag = 0;
    completed_conv_layers = 0;
    completed_fc_layers = 0;
    pool5_cache_valid = 0;
    dma_busy = 0;
    dma_error = 0;
    dma_error_code = 0;
    dma_active_source = 0;
    dma_accepted_requests = 0;
    dma_issued_commands = 0;
    dma_completed_transfers = 0;
    conv_storage_completed_tiles = 0;
    repeat (5) @(posedge clk);
    @(negedge clk);
    rst = 1'b0;

    expect_read(8'h00, 32'h414c_0100);
    expect_read(8'h7c, 32'h0408_00c8);
    expect_read(8'h40, 32'd10_000_000);
    expect_read(8'h78, 32'h0000_0007, 32'h0000_0007);

    axi_write(8'h0c, 32'h0000_0012, 4'b0001, 0, 2'b00);
    axi_write(8'h0c, 32'h0000_3400, 4'b0010, 1, 2'b00);
    expect_read(8'h0c, 32'h0000_3412);
    axi_write(8'h10, 32'h1000_0000, 4'hf, 2, 2'b00);
    axi_write(8'h18, 32'h1100_0000, 4'hf, 0, 2'b00);
    axi_write(8'h20, 32'h1200_0000, 4'hf, 1, 2'b00);
    axi_write(8'h28, 32'h2000_0000, 4'hf, 2, 2'b00);
    axi_write(8'h30, 32'h3000_0000, 4'hf, 0, 2'b00);
    axi_write(8'h38, 32'h4000_0000, 4'hf, 1, 2'b00);
    axi_write(8'h40, 32'd123456, 4'hf, 2, 2'b00);
    axi_write(8'h60, 32'h0000_0003, 4'hf, 0, 2'b00);

    // Submit while the graph is not ready. The command and all bases must be
    // retained despite later writes to the software shadow registers.
    axi_write(8'h04, 32'h0000_0001, 4'h1, 0, 2'b00);
    if (!start_pending || !core_start_valid || core_start_tag != 16'h3412)
      $fatal(1, "first job did not enter pending mailbox");
    axi_write(8'h0c, 32'h0000_2222, 4'hf, 1, 2'b00);
    axi_write(8'h10, 32'h5000_0000, 4'hf, 2, 2'b00);
    if (core_start_tag != 16'h3412)
      $fatal(1, "shadow write corrupted pending job tag");
    axi_write(8'h04, 32'h0000_0001, 4'h1, 0, 2'b10);
    if (!start_rejected_sticky || !irq)
      $fatal(1, "queue-full submit was not reported");
    expect_read(8'h70, 32'd1);
    axi_write(8'h64, 32'h0000_0008, 4'h1, 1, 2'b00);
    if (start_rejected_sticky || irq)
      $fatal(1, "submit-rejected W1C failed");

    core_start_ready = 1'b1;
    @(posedge clk);
    @(negedge clk);
    core_start_ready = 1'b0;
    core_busy = 1'b1;
    active_inference_tag = 16'h3412;
    if (start_pending || active_input_base != 64'h0000_0000_1000_0000 ||
        active_activation_a_base != 64'h0000_0000_1100_0000 ||
        active_activation_b_base != 64'h0000_0000_1200_0000 ||
        active_weights_base != 64'h0000_0000_2000_0000 ||
        active_parameters_base != 64'h0000_0000_3000_0000 ||
        active_final_output_base != 64'h0000_0000_4000_0000 ||
        active_dma_timeout_cycles != 32'd123456)
      $fatal(1, "active configuration did not use pending snapshot");

    // A second configuration can be queued while the first job runs without
    // changing any active address.
    axi_write(8'h04, 32'h0000_0001, 4'h1, 2, 2'b00);
    if (!start_pending || core_start_tag != 16'h2222 ||
        active_input_base != 64'h0000_0000_1000_0000)
      $fatal(1, "queued second job changed active configuration");
    repeat (20) @(posedge clk);
    @(negedge clk);
    inference_done = 1'b1;
    @(posedge clk);
    @(negedge clk);
    inference_done = 1'b0;
    core_busy = 1'b0;
    if (!done_sticky || !irq)
      $fatal(1, "completion status/interrupt was not retained");
    expect_read(8'h6c, 32'd1);
    expect_read(8'h4c, 32'h3412_3412);
    axi_write(8'h64, 32'h0000_0001, 4'h1, 0, 2'b00);
    if (done_sticky || irq)
      $fatal(1, "done W1C failed");

    core_start_ready = 1'b1;
    @(posedge clk);
    @(negedge clk);
    core_start_ready = 1'b0;
    core_busy = 1'b1;
    active_inference_tag = 16'h2222;
    if (start_pending || active_input_base != 64'h0000_0000_5000_0000)
      $fatal(1, "second pending configuration was not activated");

    // The bridge is 32-bit addressed and all regions require 128-byte base
    // alignment. Invalid shadow configuration must fail before graph launch.
    axi_write(8'h10, 32'h5000_0004, 4'hf, 1, 2'b00);
    axi_write(8'h04, 32'h0000_0001, 4'h1, 2, 2'b10);
    if (!start_rejected_sticky || start_pending)
      $fatal(1, "unaligned configuration was not rejected");
    expect_read(8'h78, 32'h0000_0004, 32'h0000_0007);
    axi_write(8'h10, 32'h5000_0000, 4'hf, 0, 2'b00);
    axi_write(8'h64, 32'h0000_0008, 4'h1, 1, 2'b00);

    fault_code = 4'h5;
    dma_error_code = 4'ha;
    fault_detail = 8'ha5;
    @(negedge clk);
    core_fault = 1'b1;
    inference_failed = 1'b1;
    @(posedge clk);
    @(negedge clk);
    inference_failed = 1'b0;
    core_busy = 1'b0;
    if (!failed_sticky || !fault_sticky || !irq)
      $fatal(1, "failure status/interrupt was not retained");
    expect_read(8'h74, 32'd1);
    expect_read(8'h48, 32'ha500_00a5, 32'hff00_00ff);
    axi_write(8'h64, 32'h0000_0006, 4'h1, 2, 2'b00);
    if (!fault_sticky)
      $fatal(1, "live fault was incorrectly cleared");
    core_fault = 1'b0;
    @(posedge clk);
    axi_write(8'h64, 32'h0000_0006, 4'h1, 0, 2'b00);
    if (failed_sticky || fault_sticky || irq)
      $fatal(1, "failure/fault W1C failed after live fault cleared");

    axi_read(8'h80, read_value, read_response);
    if (read_response != 2'b10)
      $fatal(1, "unmapped AXI read did not return SLVERR");
    axi_write(8'h80, 32'h0, 4'hf, 1, 2'b10);

    $display("ALEXNET_AXI_LITE_REGS_TEST_PASSED completed=%0d rejected=%0d failed=%0d",
             dut.completed_jobs_q, dut.rejected_submits_q, dut.failed_jobs_q);
    $finish;
  end
endmodule
