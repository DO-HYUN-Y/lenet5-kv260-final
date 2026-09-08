`timescale 1ns/1ps

module tb_alexnet_packed_pe;

  localparam int DSP_LATENCY = 4;
  localparam int MAX_RESULTS = 4096;

  import "DPI-C" function int alexnet_golden_packed_products(
      input byte act_lo, input byte act_hi, input byte weight,
      output int product_lo, output int product_hi);

  logic clk = 1'b0;
  logic rst;
  logic ce;

  logic signed [7:0] act_lo;
  logic signed [7:0] act_hi;
  logic signed [7:0] weight;
  logic raw_valid;
  logic raw_clear;
  logic raw_last;
  logic [1:0] raw_mask;

  logic mac_valid;
  logic acc_clear;
  logic reduce_last;
  logic [1:0] lane_mask;

  logic result_valid;
  logic result_ready;
  logic signed [31:0] result_lo;
  logic signed [31:0] result_hi;
  logic [1:0] result_lane_mask;

  alexnet_packed_pe dut (
      .clk,
      .rst,
      .ce,
      .act_lo,
      .act_hi,
      .weight,
      .mac_valid,
      .acc_clear,
      .reduce_last,
      .lane_mask,
      .result_valid,
      .result_ready,
      .result_lo,
      .result_hi,
      .result_lane_mask
  );

  always #2 clk = ~clk;

  typedef struct packed {
    logic valid;
    logic clear;
    logic last;
    logic [1:0] mask;
  } aligned_control_t;

  aligned_control_t control_pipe [0:DSP_LATENCY-1];

  assign mac_valid  = control_pipe[DSP_LATENCY-1].valid;
  assign acc_clear  = control_pipe[DSP_LATENCY-1].clear;
  assign reduce_last = control_pipe[DSP_LATENCY-1].last;
  assign lane_mask  = control_pipe[DSP_LATENCY-1].mask;

  always_ff @(posedge clk) begin
    if (rst) begin
      for (int index = 0; index < DSP_LATENCY; index++)
        control_pipe[index] <= '0;
    end else if (ce) begin
      control_pipe[0] <= '{valid: raw_valid, clear: raw_clear,
                           last: raw_last, mask: raw_mask};
      for (int index = 1; index < DSP_LATENCY; index++)
        control_pipe[index] <= control_pipe[index-1];
    end
  end

  typedef struct {
    int lo;
    int hi;
    logic [1:0] mask;
  } expected_result_t;

  expected_result_t expected [0:MAX_RESULTS-1];
  int expected_head;
  int expected_tail;
  longint signed model_lo;
  longint signed model_hi;
  int issued_products;
  int checked_results;

  // The transaction oracle calls the checked-in C++ packed product model.
  always @(posedge clk) begin
    int product_lo;
    int product_hi;
    int status;

    if (rst) begin
      expected_head = 0;
      expected_tail = 0;
      model_lo = 0;
      model_hi = 0;
      issued_products = 0;
    end else if (ce) begin
      if (raw_clear) begin
        model_lo = 0;
        model_hi = 0;
      end

      if (raw_valid) begin
        status = alexnet_golden_packed_products(
            act_lo, act_hi, weight, product_lo, product_hi);
        if (status != 0)
          $fatal(1, "C++ packed product oracle returned %0d", status);

        model_lo = model_lo + product_lo;
        model_hi = model_hi + product_hi;
        issued_products = issued_products + 1;

        if ((model_lo < -67108864) || (model_lo > 67108863) ||
            (model_hi < -67108864) || (model_hi > 67108863))
          $fatal(1, "test vector exceeded frozen signed-27 bound");

        if (raw_last) begin
          if (expected_tail >= MAX_RESULTS)
            $fatal(1, "expected result storage exhausted");
          expected[expected_tail].lo = model_lo;
          expected[expected_tail].hi = model_hi;
          expected[expected_tail].mask = raw_mask;
          expected_tail = expected_tail + 1;
          model_lo = 0;
          model_hi = 0;
        end
      end
    end
  end

  logic stalled_previous;
  logic signed [31:0] stalled_lo;
  logic signed [31:0] stalled_hi;
  logic [1:0] stalled_mask;

  always @(posedge clk) begin
    expected_result_t item;

    if (rst) begin
      checked_results = 0;
      stalled_previous = 1'b0;
      stalled_lo = '0;
      stalled_hi = '0;
      stalled_mask = '0;
    end else begin
      if (stalled_previous &&
          (!result_valid || result_lo !== stalled_lo ||
           result_hi !== stalled_hi || result_lane_mask !== stalled_mask))
        $fatal(1, "holding output changed while valid && !ready");

      if (result_valid && result_ready) begin
        if (expected_head >= expected_tail)
          $fatal(1, "RTL result arrived without an expected transaction");
        item = expected[expected_head];
        if (($signed(result_lo) != item.lo) ||
            ($signed(result_hi) != item.hi) ||
            (result_lane_mask !== item.mask))
          $fatal(1,
                 "result %0d mismatch got=(%0d,%0d,%b) expected=(%0d,%0d,%b)",
                 expected_head, $signed(result_lo), $signed(result_hi),
                 result_lane_mask, item.lo, item.hi, item.mask);
        expected_head = expected_head + 1;
        checked_results = checked_results + 1;
      end

      stalled_previous = result_valid && !result_ready;
      stalled_lo = result_lo;
      stalled_hi = result_hi;
      stalled_mask = result_lane_mask;
    end
  end

  task automatic drive_cycle(
      input logic valid,
      input logic clear,
      input logic last,
      input logic signed [7:0] lo_value,
      input logic signed [7:0] hi_value,
      input logic signed [7:0] weight_value,
      input logic [1:0] mask_value);
    begin
      raw_valid = valid;
      raw_clear = clear;
      raw_last = last;
      act_lo = lo_value;
      act_hi = hi_value;
      weight = weight_value;
      raw_mask = mask_value;
      @(negedge clk);
    end
  endtask

  task automatic idle_cycle();
    drive_cycle(1'b0, 1'b0, 1'b0, '0, '0, '0, 2'b11);
  endtask

  task automatic run_constant_tile(
      input int depth,
      input logic signed [7:0] lo_value,
      input logic signed [7:0] hi_value,
      input logic signed [7:0] weight_value,
      input logic [1:0] mask_value);
    begin
      drive_cycle(1'b0, 1'b1, 1'b0, '0, '0, '0, mask_value);
      for (int k = 0; k < depth; k++)
        drive_cycle(1'b1, 1'b0, k == depth-1, lo_value, hi_value,
                    weight_value, mask_value);
      idle_cycle();
    end
  endtask

  task automatic wait_for_all_results();
    int timeout;
    begin
      timeout = 0;
      while (((expected_head != expected_tail) || result_valid) &&
             (timeout < 200)) begin
        idle_cycle();
        timeout = timeout + 1;
      end
      if ((expected_head != expected_tail) || result_valid)
        $fatal(1, "timeout draining expected results head=%0d tail=%0d",
               expected_head, expected_tail);
    end
  endtask

  function automatic logic signed [7:0] random_int8();
    random_int8 = $urandom_range(0, 255) - 128;
  endfunction

  initial begin
    int seed;
    int random_tiles;
    int plusarg_status;
    int seed_sink;

    seed = 32'h41e8_2601;
    random_tiles = 400;
    plusarg_status = $value$plusargs("SEED=%d", seed);
    plusarg_status = $value$plusargs("RANDOM_TILES=%d", random_tiles);
    seed_sink = $urandom(seed);

    rst = 1'b1;
    ce = 1'b1;
    result_ready = 1'b1;
    raw_valid = 1'b0;
    raw_clear = 1'b0;
    raw_last = 1'b0;
    raw_mask = 2'b11;
    act_lo = '0;
    act_hi = '0;
    weight = '0;
    repeat (5) @(negedge clk);
    rst = 1'b0;
    @(negedge clk);

    // Signed packing/carry-correction corners and M-tail masks.
    run_constant_tile(1, -128,  127,  127, 2'b11);
    run_constant_tile(1, -128, -128, -128, 2'b11);
    run_constant_tile(1,   -1,    0,    1, 2'b01);
    run_constant_tile(1,    0,   -1,   -1, 2'b10);
    run_constant_tile(5,  127, -128,   63, 2'b11);

    // Clear without a valid MAC models a structurally skipped first token.
    drive_cycle(1'b0, 1'b1, 1'b0, 0, 0, 0, 2'b11);
    drive_cycle(1'b1, 1'b0, 1'b0, 12, -9, 7, 2'b11);
    drive_cycle(1'b0, 1'b1, 1'b0, 0, 0, 0, 2'b11);
    drive_cycle(1'b1, 1'b0, 1'b1, -3, 5, 11, 2'b11);
    idle_cycle();

    // reduce_last clears for the next tile, allowing one completed K=1 dot
    // product per cycle without another explicit clear control cycle.
    drive_cycle(1'b0, 1'b1, 1'b0, 0, 0, 0, 2'b11);
    drive_cycle(1'b1, 1'b0, 1'b1, 9, -7, 5, 2'b11);
    drive_cycle(1'b1, 1'b0, 1'b1, -4, 3, -11, 2'b11);
    idle_cycle();

    // Tile-local CE freezes operands and the external row-control tap.
    drive_cycle(1'b0, 1'b1, 1'b0, 0, 0, 0, 2'b11);
    drive_cycle(1'b1, 1'b0, 1'b0, 10, -10, 5, 2'b11);
    drive_cycle(1'b1, 1'b0, 1'b0, -20, 20, -5, 2'b11);
    ce = 1'b0;
    repeat (9) begin
      raw_valid = $urandom_range(0, 1);
      act_lo = random_int8();
      act_hi = random_int8();
      weight = random_int8();
      @(negedge clk);
    end
    ce = 1'b1;
    drive_cycle(1'b1, 1'b0, 1'b0, 30, -30, 5, 2'b11);
    drive_cycle(1'b1, 1'b0, 1'b1, -40, 40, -5, 2'b11);
    idle_cycle();

    // Backpressure must preserve a completed tile independently of compute CE.
    run_constant_tile(7, 21, -17, 13, 2'b11);
    result_ready = 1'b0;
    repeat (14) idle_cycle();
    if (!result_valid)
      $fatal(1, "directed holding test never produced result_valid");
    ce = 1'b0;
    repeat (7) @(negedge clk);
    ce = 1'b1;
    result_ready = 1'b1;
    repeat (2) idle_cycle();

    // Exercise values near both signed-27 limits at FC6-scale K depth.
    run_constant_tile(9200,  100, -100, 70, 2'b11);
    run_constant_tile(9200, -100,  100, 70, 2'b11);

    // Deterministic random tiles. result_ready=1 permits K=1 same-cycle
    // holding turnover, while random bubbles and CE stalls perturb latency.
    for (int tile = 0; tile < random_tiles; tile++) begin
      int depth;
      logic [1:0] mask_value;

      depth = $urandom_range(1, 64);
      mask_value = $urandom_range(1, 3);
      drive_cycle(1'b0, 1'b1, 1'b0, '0, '0, '0, mask_value);
      for (int k = 0; k < depth; k++) begin
        if ($urandom_range(0, 4) == 0)
          idle_cycle();
        if ($urandom_range(0, 31) == 0) begin
          ce = 1'b0;
          repeat ($urandom_range(1, 5)) @(negedge clk);
          ce = 1'b1;
        end
        drive_cycle(1'b1, 1'b0, k == depth-1,
                    random_int8(), random_int8(), random_int8(), mask_value);
      end
    end

    wait_for_all_results();
    repeat (4) idle_cycle();

    if (expected_head != expected_tail)
      $fatal(1, "undrained expected results");

    $display("ALEXNET_PACKED_PE_TEST_PASSED products=%0d results=%0d seed=%0d",
             issued_products, checked_results, seed);
    $finish;
  end

endmodule
