`timescale 1ns/1ps

module tb_alexnet_pool5_n8_store;
  logic clk = 1'b0;
  logic rst;
  logic start_valid, start_ready;
  logic [15:0] start_tag;
  logic write_valid, write_ready;
  logic [127:0] write_data;
  logic [15:0] write_keep;
  logic write_last;
  logic read_request_valid, read_request_ready;
  logic [10:0] read_request_word_address;
  logic [2:0] read_request_lane;
  logic [15:0] read_request_tag;
  logic read_response_valid, read_response_ready;
  logic signed [7:0] read_response_value;
  logic read_response_error;
  logic write_active, write_done, cache_valid;
  logic [15:0] cache_tag;
  logic fault;
  logic [9:0] beats_written;
  logic [5:0] tiles_written;

  alexnet_pool5_n8_store dut (.*);

  always #2.5 clk = ~clk;

  function automatic logic [63:0] word_value(input int word_address);
    logic [63:0] result;
    begin
      result = 0;
      for (int lane = 0; lane < 8; lane++)
        result[lane*8 +: 8] =
            (word_address * 13 + lane * 31 + 8'h47) & 8'hff;
      word_value = result;
    end
  endfunction

  initial begin
    logic [7:0] expected;
    logic [63:0] expected_source_word;
    rst = 1'b1;
    start_valid = 0;
    start_tag = 0;
    write_valid = 0;
    write_data = 0;
    write_keep = 0;
    write_last = 0;
    read_request_valid = 0;
    read_request_word_address = 0;
    read_request_lane = 0;
    read_request_tag = 0;
    read_response_ready = 0;
    repeat (5) @(negedge clk);
    rst = 1'b0;
    @(negedge clk);

    start_tag = 16'h5ca5;
    start_valid = 1'b1;
    #1;
    if (!start_ready)
      $fatal(1, "Pool5 cache did not accept frame start");
    @(posedge clk);
    @(negedge clk);
    start_valid = 1'b0;

    for (int beat = 0; beat < 576; beat++) begin
      write_data = {word_value(beat * 2 + 1), word_value(beat * 2)};
      write_keep = 16'hffff;
      write_last = beat % 18 == 17;
      write_valid = 1'b1;
      while (!write_ready) @(negedge clk);
      @(posedge clk);
      @(negedge clk);
    end
    write_valid = 1'b0;
    while (!write_done) @(negedge clk);
    @(negedge clk);
    if (!cache_valid || cache_tag != 16'h5ca5 || fault || write_active ||
        beats_written != 576 || tiles_written != 32)
      $fatal(1, "Pool5 cache full-frame write mismatch");

    for (int address = 0; address < 1152; address++) begin
      for (int lane = 0; lane < 8; lane++) begin
        read_request_word_address = address;
        read_request_lane = lane;
        read_request_tag = 16'h5ca5;
        read_request_valid = 1'b1;
        #1;
        while (!read_request_ready) @(negedge clk);
        @(posedge clk);
        @(negedge clk);
        read_request_valid = 1'b0;
        while (!read_response_valid) @(negedge clk);
        expected_source_word = word_value(address);
        expected = expected_source_word[lane*8 +: 8];
        if (read_response_value != expected || read_response_error)
          $fatal(1, "Pool5 cache read mismatch address=%0d lane=%0d",
                 address, lane);
        repeat ((address + lane) % 3) @(negedge clk);
        read_response_ready = 1'b1;
        @(posedge clk);
        @(negedge clk);
        read_response_ready = 1'b0;
      end
    end

    if (fault || !cache_valid)
      $fatal(1, "Pool5 cache fault after exhaustive readback");
    $display(
        "ALEXNET_POOL5_N8_STORE_TEST_PASSED beats=576 words=1152 scalars=9216 bram_target=2");
    $finish;
  end
endmodule
