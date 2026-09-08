`timescale 1ns/1ps

module tb_alexnet_parameter_record_loader;
  logic clk = 1'b0;
  logic rst;
  logic start_valid, start_ready, start_is_fc;
  logic [3:0] start_layer_id;
  logic [15:0] start_job_tag, start_n_base;
  logic [127:0] s_axis_tdata;
  logic [15:0] s_axis_tkeep;
  logic s_axis_tvalid, s_axis_tready, s_axis_tlast;
  logic parameter_valid, parameter_ready, parameter_is_fc;
  logic [3:0] parameter_layer_id;
  logic [15:0] parameter_job_tag, parameter_n_base;
  logic signed [31:0] parameter_bias [0:7];
  logic signed [17:0] parameter_multiplier [0:7];
  logic [5:0] parameter_right_shift [0:7];
  logic busy, fault;
  logic [2:0] active_lane;
  logic [31:0] accepted_tiles, completed_tiles, rejected_tiles;
  integer lane;

  alexnet_parameter_record_loader dut (.*);
  always #2.5 clk = ~clk;

  function automatic logic [127:0] make_record(
      input integer index,
      input logic relu,
      input logic bad_padding);
    logic signed [31:0] bias;
    logic [31:0] multiplier;
    logic [7:0] shift;
    begin
      bias = -32'sd1000 + index * 32'sd17;
      multiplier = 32'd70000 + index * 32'd101;
      shift = 8'd23 + index;
      make_record = {48'b0, {7'b0, relu}, shift, multiplier, bias};
      if (bad_padding)
        make_record[127] = 1'b1;
    end
  endfunction

  task automatic launch_tile(
      input logic is_fc,
      input logic [3:0] layer_id,
      input logic [15:0] job_tag,
      input logic [15:0] n_base);
    begin
      start_is_fc = is_fc;
      start_layer_id = layer_id;
      start_job_tag = job_tag;
      start_n_base = n_base;
      start_valid = 1'b1;
      #1;
      while (!start_ready) @(negedge clk);
      @(posedge clk);
      @(negedge clk);
      start_valid = 1'b0;
    end
  endtask

  task automatic send_tile(
      input logic relu,
      input integer bad_lane,
      input integer early_last_lane);
    begin
      for (lane = 0; lane < 8; lane = lane + 1) begin
        repeat (lane[0]) @(negedge clk);
        s_axis_tdata = make_record(lane, relu, lane == bad_lane);
        s_axis_tkeep = 16'hffff;
        s_axis_tlast = lane == 7 || lane == early_last_lane;
        s_axis_tvalid = 1'b1;
        #1;
        while (!s_axis_tready) @(negedge clk);
        @(posedge clk);
        @(negedge clk);
        s_axis_tvalid = 1'b0;
        if (lane == early_last_lane)
          lane = 8;
      end
    end
  endtask

  task automatic check_response(
      input logic expected_is_fc,
      input logic [3:0] expected_layer,
      input logic [15:0] expected_tag,
      input logic [15:0] expected_n_base);
    logic [3:0] held_meta;
    begin
      while (!parameter_valid) @(negedge clk);
      held_meta = parameter_layer_id;
      repeat (3) begin
        @(negedge clk);
        if (!parameter_valid || parameter_layer_id != held_meta)
          $fatal(1, "parameter response changed under backpressure");
      end
      if (parameter_is_fc != expected_is_fc ||
          parameter_layer_id != expected_layer ||
          parameter_job_tag != expected_tag ||
          parameter_n_base != expected_n_base)
        $fatal(1, "parameter response metadata mismatch");
      for (lane = 0; lane < 8; lane = lane + 1) begin
        if (parameter_bias[lane] != -1000 + lane * 17 ||
            parameter_multiplier[lane] != 70000 + lane * 101 ||
            parameter_right_shift[lane] != 23 + lane)
          $fatal(1, "parameter lane %0d mismatch", lane);
      end
      parameter_ready = 1'b1;
      @(posedge clk);
      @(negedge clk);
      parameter_ready = 1'b0;
      if (parameter_valid || busy)
        $fatal(1, "parameter loader did not retire response");
    end
  endtask

  initial begin
    rst = 1'b1;
    start_valid = 1'b0;
    start_is_fc = 1'b0;
    start_layer_id = 0;
    start_job_tag = 0;
    start_n_base = 0;
    s_axis_tdata = 0;
    s_axis_tkeep = 0;
    s_axis_tvalid = 1'b0;
    s_axis_tlast = 1'b0;
    parameter_ready = 1'b0;
    repeat (5) @(negedge clk);
    rst = 1'b0;
    @(negedge clk);

    launch_tile(1'b0, 4'd3, 16'h1234, 16'd24);
    send_tile(1'b1, -1, -1);
    check_response(1'b0, 4'd3, 16'h1234, 16'd24);

    launch_tile(1'b1, 4'd8, 16'h5678, 16'd992);
    send_tile(1'b0, -1, -1);
    check_response(1'b1, 4'd8, 16'h5678, 16'd992);

    if (accepted_tiles != 2 || completed_tiles != 2 ||
        rejected_tiles != 0 || fault)
      $fatal(1, "parameter loader clean counters mismatch");

    // Padding corruption must consume and reject the complete tile without
    // ever exposing a parameter response.
    launch_tile(1'b1, 4'd7, 16'h9abc, 16'd8);
    send_tile(1'b1, 3, -1);
    repeat (3) @(negedge clk);
    if (parameter_valid || !fault || accepted_tiles != 3 ||
        completed_tiles != 2 || rejected_tiles != 1)
      $fatal(1, "malformed parameter tile was not rejected");

    $display("ALEXNET_PARAMETER_RECORD_LOADER_TEST_PASSED tiles=3 completed=2 rejected=1 records=24 backpressure=stable format=<iiBB6x>");
    $finish;
  end

  initial begin
    #100000;
    $fatal(1, "parameter record loader watchdog");
  end
endmodule
