`timescale 1ns/1ps

module tb_alexnet_graph_dma_read_router;
  logic clk = 1'b0;
  logic rst;
  logic launch_valid, launch_ready, launch_s2mm;
  logic [2:0] launch_source;
  logic [3:0] launch_layer_id;
  logic [15:0] launch_n_base, launch_tag;
  logic [25:0] launch_length_bytes;
  logic dma_done, dma_error;
  logic [127:0] s_axis_tdata;
  logic [15:0] s_axis_tkeep;
  logic s_axis_tvalid, s_axis_tready, s_axis_tlast;
  logic [127:0] graph_axis_tdata;
  logic [15:0] graph_axis_tkeep;
  logic graph_axis_tvalid, graph_axis_tready, graph_axis_tlast;
  logic parameter_valid, parameter_ready, parameter_is_fc;
  logic [3:0] parameter_layer_id;
  logic [15:0] parameter_job_tag, parameter_n_base;
  logic signed [31:0] parameter_bias [0:7];
  logic signed [17:0] parameter_multiplier [0:7];
  logic [5:0] parameter_right_shift [0:7];
  logic busy, fault;
  logic [2:0] active_source;
  logic [25:0] bytes_transferred;
  logic [31:0] launched_reads, completed_reads;
  integer lane;

  alexnet_graph_dma_read_router dut (.*);
  always #2.5 clk = ~clk;

  function automatic logic [127:0] parameter_record(
      input integer index, input logic relu);
    begin
      parameter_record = {48'b0, {7'b0, relu}, 8'(24 + index),
                          32'(80000 + index), 32'(-200 + index)};
    end
  endfunction

  task automatic launch(
      input logic s2mm,
      input logic [2:0] source,
      input logic [3:0] layer_id,
      input logic [15:0] n_base,
      input logic [15:0] tag,
      input integer length_bytes);
    begin
      launch_s2mm = s2mm;
      launch_source = source;
      launch_layer_id = layer_id;
      launch_n_base = n_base;
      launch_tag = tag;
      launch_length_bytes = length_bytes;
      launch_valid = 1'b1;
      #1;
      while (!launch_ready) @(negedge clk);
      @(posedge clk);
      @(negedge clk);
      launch_valid = 1'b0;
    end
  endtask

  task automatic send_beat(
      input logic [127:0] data,
      input logic [15:0] keep,
      input logic last);
    begin
      s_axis_tdata = data;
      s_axis_tkeep = keep;
      s_axis_tlast = last;
      s_axis_tvalid = 1'b1;
      #1;
      while (!s_axis_tready) @(negedge clk);
      @(posedge clk);
      @(negedge clk);
      s_axis_tvalid = 1'b0;
    end
  endtask

  task automatic finish_dma;
    begin
      dma_done = 1'b1;
      @(posedge clk);
      @(negedge clk);
      dma_done = 1'b0;
    end
  endtask

  initial begin
    rst = 1'b1;
    launch_valid = 1'b0;
    launch_s2mm = 1'b0;
    launch_source = 0;
    launch_layer_id = 0;
    launch_n_base = 0;
    launch_tag = 0;
    launch_length_bytes = 0;
    dma_done = 1'b0;
    dma_error = 1'b0;
    s_axis_tdata = 0;
    s_axis_tkeep = 0;
    s_axis_tvalid = 1'b0;
    s_axis_tlast = 1'b0;
    graph_axis_tready = 1'b0;
    parameter_ready = 1'b0;
    repeat (5) @(negedge clk);
    rst = 1'b0;
    @(negedge clk);

    // Ordinary RS/FC payload remains bit-for-bit AXIS data. Exercise a
    // one-word tail and downstream backpressure.
    launch(1'b0, 3'd0, 4'd2, 16'd16, 16'h2001, 24);
    graph_axis_tready = 1'b0;
    s_axis_tdata = 128'hfedc_ba98_7654_3210_0123_4567_89ab_cdef;
    s_axis_tkeep = 16'hffff;
    s_axis_tlast = 1'b0;
    s_axis_tvalid = 1'b1;
    repeat (3) begin
      @(negedge clk);
      if (s_axis_tready || !graph_axis_tvalid ||
          graph_axis_tdata != s_axis_tdata)
        $fatal(1, "payload router violated graph backpressure");
    end
    graph_axis_tready = 1'b1;
    @(posedge clk);
    @(negedge clk);
    s_axis_tvalid = 1'b0;
    // The physical DMA may report IOC while its final AXIS beat is still
    // buffered.  Ownership must remain live without raising a fault.
    finish_dma();
    if (!busy || fault || completed_reads != 0)
      $fatal(1, "early DMA completion did not wait for payload TLAST");
    send_beat(128'h55aa, 16'h00ff, 1'b1);
    if (bytes_transferred != 24 || fault)
      $fatal(1, "payload byte accounting mismatch");
    // Stream completion is deliberately registered to keep the TKEEP byte
    // counter out of the route-control timing path.
    @(posedge clk);
    @(negedge clk);
    if (busy || completed_reads != 1)
      $fatal(1, "payload route did not complete after delayed TLAST");

    // Conv parameter source is consumed locally and never reaches graph AXIS.
    launch(1'b0, 3'd2, 4'd3, 16'd24, 16'h3001, 128);
    for (lane = 0; lane < 8; lane = lane + 1) begin
      send_beat(parameter_record(lane, 1'b1), 16'hffff, lane == 7);
      if (graph_axis_tvalid)
        $fatal(1, "parameter record leaked into graph payload stream");
    end
    finish_dma();
    while (!parameter_valid) @(negedge clk);
    if (parameter_is_fc || parameter_layer_id != 3 ||
        parameter_job_tag != 16'h3001 || parameter_n_base != 24)
      $fatal(1, "Conv parameter metadata mismatch");
    for (lane = 0; lane < 8; lane = lane + 1)
      if (parameter_bias[lane] != -200 + lane ||
          parameter_multiplier[lane] != 80000 + lane ||
          parameter_right_shift[lane] != 24 + lane)
        $fatal(1, "Conv parameter lane mismatch");
    parameter_ready = 1'b1;
    @(posedge clk);
    @(negedge clk);
    parameter_ready = 1'b0;

    // S2MM commands must not reserve the MM2S route.
    launch(1'b1, 3'd7, 4'd8, 16'd0, 16'h8001, 8);
    if (busy)
      $fatal(1, "S2MM launch acquired the MM2S router");

    if (launched_reads != 2 || completed_reads != 2 || fault)
      $fatal(1, "DMA read router counters mismatch");
    $display("ALEXNET_GRAPH_DMA_READ_ROUTER_TEST_PASSED reads=2 payload_bytes=24 parameter_bytes=128 parameter_records=8 s2mm_ignored=1");
    $finish;
  end

  initial begin
    #100000;
    $fatal(1, "graph DMA read router watchdog");
  end
endmodule
