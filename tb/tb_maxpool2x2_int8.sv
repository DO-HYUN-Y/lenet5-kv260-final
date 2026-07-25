`timescale 1ns/1ps

module tb_maxpool2x2_int8;
  localparam int MAX_RANDOM = 8192;

  import "DPI-C" function int maxpool2x2_golden(
      input int top_pair, input int bottom_pair);

  logic clk;
  logic rst_n;
  logic flush;
  logic in_valid;
  logic in_ready;
  logic [15:0] top_pair;
  logic [15:0] bottom_pair;
  logic out_valid;
  logic out_ready;
  logic signed [7:0] out_data;

  logic model_valid;
  logic signed [7:0] model_data;
  longint model_due_cycle;
  logic model_first_seen;
  longint cycle_count;
  int accepted_count;
  int observed_count;

  maxpool2x2_int8 dut (.*);

  always #5 clk = ~clk;

  always @(posedge clk) begin
    bit accept_before;
    bit consume_before;
    int expected;

    accept_before = rst_n && !flush && in_valid && in_ready;
    consume_before = rst_n && !flush && out_valid && out_ready;

    if (rst_n && !flush) begin
      if ($isunknown({in_ready, out_valid, out_data}))
        $fatal(1, "MAXPOOL XPROP visible output unknown");
      if (out_valid !== model_valid)
        $fatal(1, "MAXPOOL valid cycle=%0d got=%0b exp=%0b",
               cycle_count, out_valid, model_valid);
      if (model_valid && (out_data !== model_data))
        $fatal(1, "MAXPOOL data cycle=%0d got=%0d exp=%0d",
               cycle_count, out_data, model_data);
      if (model_valid && !model_first_seen) begin
        if (cycle_count != model_due_cycle)
          $fatal(1, "MAXPOOL latency got_cycle=%0d exp_cycle=%0d",
                 cycle_count, model_due_cycle);
        model_first_seen = 1'b1;
      end
    end

    if (consume_before) observed_count = observed_count + 1;

    if (!rst_n || flush) begin
      model_valid = 1'b0;
      model_data = '0;
      model_due_cycle = 0;
      model_first_seen = 1'b0;
    end else if (in_ready) begin
      model_valid = in_valid;
      if (in_valid) begin
        expected = maxpool2x2_golden(top_pair, bottom_pair);
        model_data = expected[7:0];
        model_due_cycle = cycle_count + 1;
        model_first_seen = 1'b0;
      end
    end

    if (accept_before) accepted_count = accepted_count + 1;
    if (rst_n) cycle_count = cycle_count + 1;
  end

  task automatic drive_one(
      input logic [15:0] top_value,
      input logic [15:0] bottom_value
  );
    begin
      @(negedge clk);
      in_valid = 1'b1;
      top_pair = top_value;
      bottom_pair = bottom_value;
      @(posedge clk);
      while (!in_ready) @(posedge clk);
    end
  endtask

  task automatic stop_driver;
    begin
      @(negedge clk);
      in_valid = 1'b0;
      top_pair = '0;
      bottom_pair = '0;
    end
  endtask

  task automatic wait_empty;
    begin
      out_ready = 1'b1;
      for (int guard = 0; guard < 1000 && (model_valid || out_valid);
           guard++)
        @(negedge clk);
      if (model_valid || out_valid)
        $fatal(1, "MAXPOOL drain timeout");
    end
  endtask

  initial begin
    int seed;
    int random_count;
    int ignored;

    clk = 1'bx;
    rst_n = 1'bx;
    flush = 1'bx;
    in_valid = 1'bx;
    top_pair = 'x;
    bottom_pair = 'x;
    out_ready = 1'bx;
    model_valid = 1'b0;
    model_data = '0;
    model_due_cycle = 0;
    model_first_seen = 1'b0;
    cycle_count = 0;
    accepted_count = 0;
    observed_count = 0;
    seed = 20260724;
    random_count = 0;
    ignored = $value$plusargs("SEED=%d", seed);
    ignored = $value$plusargs("RANDOM_COUNT=%d", random_count);
    if (random_count > MAX_RANDOM)
      $fatal(1, "MAXPOOL random_count exceeds %0d", MAX_RANDOM);
    ignored = $urandom(seed);
    $display("MAXPOOL seed=%0d random_count=%0d", seed, random_count);

    #2;
    clk = 1'b0;
    rst_n = 1'b0;
    flush = 1'b0;
    in_valid = 1'b0;
    top_pair = '0;
    bottom_pair = '0;
    out_ready = 1'b0;
    repeat (4) @(negedge clk);
    rst_n = 1'b1;
    @(posedge clk);
    #1;
    if ($isunknown({in_ready, out_valid, out_data}))
      $fatal(1, "MAXPOOL XPROP visible output unknown after reset");

    out_ready = 1'b1;
    drive_one({8'(-4),  8'(-8)}, {8'(-1),  8'(-7)});
    drive_one({8'(127), 8'(-128)}, {8'(0), 8'(126)});
    drive_one({8'(-128), 8'(-128)}, {8'(-128), 8'(-128)});
    drive_one({8'(12), 8'(12)}, {8'(12), 8'(12)});
    drive_one({8'(1), 8'(2)}, {8'(4), 8'(3)});
    stop_driver();
    wait_empty();
    $display("MAXPOOL DIRECTED PASSED vectors=5");

    if (random_count > 0) begin
      fork
        begin : consumer_stalls
          for (int cycle = 0; cycle < random_count * 5; cycle++) begin
            @(negedge clk);
            out_ready = ($urandom_range(0, 3) != 0);
          end
          out_ready = 1'b1;
        end
        begin : random_driver
          for (int n = 0; n < random_count; n++) begin
            logic [15:0] random_top;
            logic [15:0] random_bottom;
            random_top = $urandom;
            random_bottom = $urandom;
            drive_one(random_top, random_bottom);
          end
          stop_driver();
        end
      join
      wait_empty();
      $display("MAXPOOL RANDOM PASSED vectors=%0d seed=%0d",
               random_count, seed);
    end

    if (accepted_count != observed_count)
      $fatal(1, "MAXPOOL count accepted=%0d observed=%0d",
             accepted_count, observed_count);
    $display("MAXPOOL2X2_INT8 TEST PASSED accepted=%0d",
             accepted_count);
    $finish;
  end

endmodule
