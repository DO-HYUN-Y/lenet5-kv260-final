`timescale 1ns/1ps

module tb_alexnet_sa_m4n8;

  localparam int PHYS_ROWS = 2;
  localparam int COLS = 8;
  localparam int MAX_RESULTS = 512;

  import "DPI-C" function int alexnet_golden_packed_products(
      input byte act_lo, input byte act_hi, input byte weight,
      output int product_lo, output int product_hi);

  logic clk = 1'b0;
  logic rst;
  logic ce;
  logic signed [7:0] act_lo [0:PHYS_ROWS-1];
  logic signed [7:0] act_hi [0:PHYS_ROWS-1];
  logic signed [7:0] weight [0:COLS-1];
  logic issue_valid;
  logic tile_clear;
  logic reduce_last;
  logic [1:0] m_lane_mask [0:PHYS_ROWS-1];
  logic result_valid [0:PHYS_ROWS-1][0:COLS-1];
  logic result_ready [0:PHYS_ROWS-1][0:COLS-1];
  logic signed [31:0] result_lo [0:PHYS_ROWS-1][0:COLS-1];
  logic signed [31:0] result_hi [0:PHYS_ROWS-1][0:COLS-1];
  logic [1:0] result_lane_mask [0:PHYS_ROWS-1][0:COLS-1];

  alexnet_sa_m4n8 dut (.*);

  always #2.5 clk = ~clk;

  typedef struct packed {
    logic signed [31:0] lo;
    logic signed [31:0] hi;
    logic [1:0] mask;
  } expected_t;

  expected_t expected [0:PHYS_ROWS-1][0:COLS-1][0:MAX_RESULTS-1];
  int expected_head [0:PHYS_ROWS-1][0:COLS-1];
  int expected_tail [0:PHYS_ROWS-1][0:COLS-1];
  longint signed model_lo [0:PHYS_ROWS-1][0:COLS-1];
  longint signed model_hi [0:PHYS_ROWS-1][0:COLS-1];
  int issued_products;
  int checked_results;

  always @(posedge clk) begin
    int product_lo;
    int product_hi;
    int status;

    if (rst) begin
      issued_products = 0;
      for (int g = 0; g < PHYS_ROWS; g++) begin
        for (int c = 0; c < COLS; c++) begin
          expected_head[g][c] = 0;
          expected_tail[g][c] = 0;
          model_lo[g][c] = 0;
          model_hi[g][c] = 0;
        end
      end
    end else if (ce) begin
      if (tile_clear) begin
        for (int g = 0; g < PHYS_ROWS; g++) begin
          for (int c = 0; c < COLS; c++) begin
            model_lo[g][c] = 0;
            model_hi[g][c] = 0;
          end
        end
      end

      if (issue_valid) begin
        for (int g = 0; g < PHYS_ROWS; g++) begin
          if (m_lane_mask[g] != 2'b00) begin
            for (int c = 0; c < COLS; c++) begin
              status = alexnet_golden_packed_products(
                  act_lo[g], act_hi[g], weight[c], product_lo, product_hi);
              if (status != 0)
                $fatal(1, "C++ packed product oracle returned %0d", status);
              model_lo[g][c] = model_lo[g][c] + product_lo;
              model_hi[g][c] = model_hi[g][c] + product_hi;
              issued_products = issued_products + 1;

              if ((model_lo[g][c] < -67108864) ||
                  (model_lo[g][c] > 67108863) ||
                  (model_hi[g][c] < -67108864) ||
                  (model_hi[g][c] > 67108863))
                $fatal(1, "test vector exceeded frozen signed-27 bound");

              if (reduce_last) begin
                if (expected_tail[g][c] >= MAX_RESULTS)
                  $fatal(1, "expected result storage exhausted");
                expected[g][c][expected_tail[g][c]].lo = model_lo[g][c];
                expected[g][c][expected_tail[g][c]].hi = model_hi[g][c];
                expected[g][c][expected_tail[g][c]].mask = m_lane_mask[g];
                expected_tail[g][c] = expected_tail[g][c] + 1;
                model_lo[g][c] = 0;
                model_hi[g][c] = 0;
              end
            end
          end
        end
      end
    end
  end

  logic stalled_previous [0:PHYS_ROWS-1][0:COLS-1];
  logic signed [31:0] stalled_lo [0:PHYS_ROWS-1][0:COLS-1];
  logic signed [31:0] stalled_hi [0:PHYS_ROWS-1][0:COLS-1];
  logic [1:0] stalled_mask [0:PHYS_ROWS-1][0:COLS-1];

  generate
    for (genvar g = 0; g < PHYS_ROWS; g++) begin : g_check_row
      for (genvar c = 0; c < COLS; c++) begin : g_check_col
        always @(posedge clk) begin
          expected_t item;

          if (rst) begin
            stalled_previous[g][c] = 1'b0;
            stalled_lo[g][c] = '0;
            stalled_hi[g][c] = '0;
            stalled_mask[g][c] = '0;
          end else begin
            if (stalled_previous[g][c] &&
                (!result_valid[g][c] ||
                 result_lo[g][c] !== stalled_lo[g][c] ||
                 result_hi[g][c] !== stalled_hi[g][c] ||
                 result_lane_mask[g][c] !== stalled_mask[g][c]))
              $fatal(1, "holding output changed at PE[%0d][%0d]", g, c);

            if (result_valid[g][c] && result_ready[g][c]) begin
              if (expected_head[g][c] >= expected_tail[g][c])
                $fatal(1, "unexpected result at PE[%0d][%0d]", g, c);
              item = expected[g][c][expected_head[g][c]];
              if (($signed(result_lo[g][c]) != $signed(item.lo)) ||
                  ($signed(result_hi[g][c]) != $signed(item.hi)) ||
                  (result_lane_mask[g][c] !== item.mask))
                $fatal(1,
                       "PE[%0d][%0d] mismatch got=(%0d,%0d,%b) expected=(%0d,%0d,%b)",
                       g, c, $signed(result_lo[g][c]),
                       $signed(result_hi[g][c]), result_lane_mask[g][c],
                       $signed(item.lo), $signed(item.hi), item.mask);
              expected_head[g][c] = expected_head[g][c] + 1;
              checked_results = checked_results + 1;
            end

            stalled_previous[g][c] =
                result_valid[g][c] && !result_ready[g][c];
            stalled_lo[g][c] = result_lo[g][c];
            stalled_hi[g][c] = result_hi[g][c];
            stalled_mask[g][c] = result_lane_mask[g][c];
          end
        end
      end
    end
  endgenerate

  function automatic logic signed [7:0] random_int8();
    random_int8 = $urandom_range(0, 255) - 128;
  endfunction

  task automatic drive_cycle(
      input logic valid,
      input logic clear,
      input logic last);
    begin
      issue_valid = valid;
      tile_clear = clear;
      reduce_last = last;
      @(negedge clk);
    end
  endtask

  task automatic idle_cycle();
    begin
      for (int g = 0; g < PHYS_ROWS; g++) begin
        act_lo[g] = '0;
        act_hi[g] = '0;
      end
      for (int c = 0; c < COLS; c++)
        weight[c] = '0;
      drive_cycle(1'b0, 1'b0, 1'b0);
    end
  endtask

  task automatic random_tile(input int depth, input bit bubbles,
                             input logic [1:0] row0_mask,
                             input logic [1:0] row1_mask);
    begin
      m_lane_mask[0] = row0_mask;
      m_lane_mask[1] = row1_mask;
      drive_cycle(1'b0, 1'b1, 1'b0);

      for (int k = 0; k < depth; k++) begin
        if (bubbles && ($urandom_range(0, 4) == 0))
          idle_cycle();
        if (bubbles && ($urandom_range(0, 31) == 0)) begin
          ce = 1'b0;
          repeat ($urandom_range(1, 5)) begin
            issue_valid = $urandom_range(0, 1);
            tile_clear = 1'b0;
            reduce_last = 1'b0;
            for (int g = 0; g < PHYS_ROWS; g++) begin
              act_lo[g] = random_int8();
              act_hi[g] = random_int8();
            end
            for (int c = 0; c < COLS; c++)
              weight[c] = random_int8();
            @(negedge clk);
          end
          ce = 1'b1;
        end
        for (int g = 0; g < PHYS_ROWS; g++) begin
          act_lo[g] = random_int8();
          act_hi[g] = random_int8();
        end
        for (int c = 0; c < COLS; c++)
          weight[c] = random_int8();
        drive_cycle(1'b1, 1'b0, k == depth-1);
      end
      idle_cycle();
    end
  endtask

  task automatic wait_for_all_results();
    int timeout;
    bit pending;
    begin
      timeout = 0;
      pending = 1'b1;
      while (pending && timeout < 500) begin
        idle_cycle();
        pending = 1'b0;
        for (int g = 0; g < PHYS_ROWS; g++) begin
          for (int c = 0; c < COLS; c++) begin
            if ((expected_head[g][c] != expected_tail[g][c]) ||
                result_valid[g][c])
              pending = 1'b1;
          end
        end
        timeout = timeout + 1;
      end
      if (pending)
        $fatal(1, "timeout draining M4xN8 results");
    end
  endtask

  initial begin
    int seed;
    int random_tiles;
    int plusarg_status;
    int seed_sink;

    seed = 32'h4d34_4e38;
    random_tiles = 100;
    plusarg_status = $value$plusargs("SEED=%d", seed);
    plusarg_status = $value$plusargs("RANDOM_TILES=%d", random_tiles);
    seed_sink = $urandom(seed);

    rst = 1'b1;
    ce = 1'b1;
    issue_valid = 1'b0;
    tile_clear = 1'b0;
    reduce_last = 1'b0;
    checked_results = 0;
    for (int g = 0; g < PHYS_ROWS; g++) begin
      act_lo[g] = '0;
      act_hi[g] = '0;
      m_lane_mask[g] = 2'b11;
      for (int c = 0; c < COLS; c++)
        result_ready[g][c] = 1'b1;
    end
    for (int c = 0; c < COLS; c++)
      weight[c] = '0;

    repeat (5) @(negedge clk);
    rst = 1'b0;
    @(negedge clk);

    // Different values on every row/column make skew pairing errors visible.
    random_tile(25, 1'b0, 2'b11, 2'b01);
    wait_for_all_results();

    // All 16 PE holdings fill under backpressure and must remain stable.
    random_tile(7, 1'b0, 2'b11, 2'b11);
    for (int g = 0; g < PHYS_ROWS; g++)
      for (int c = 0; c < COLS; c++)
        result_ready[g][c] = 1'b0;
    repeat (24) idle_cycle();
    for (int g = 0; g < PHYS_ROWS; g++)
      for (int c = 0; c < COLS; c++) begin
        if (!result_valid[g][c])
          $fatal(1, "backpressure did not fill PE[%0d][%0d] holding", g, c);
        result_ready[g][c] = 1'b1;
      end
    repeat (2) idle_cycle();

    // Random K depths, bubbles, CE stalls, and M-tail masks.
    for (int tile = 0; tile < random_tiles; tile++) begin
      logic [1:0] row0_mask;
      logic [1:0] row1_mask;
      row0_mask = $urandom_range(1, 3);
      row1_mask = ($urandom_range(0, 7) == 0) ? 2'b00 :
                  $urandom_range(1, 3);
      random_tile($urandom_range(1, 64), 1'b1, row0_mask, row1_mask);
    end

    wait_for_all_results();
    repeat (4) idle_cycle();

    $display("ALEXNET_SA_M4N8_TEST_PASSED products=%0d results=%0d seed=%0d",
             issued_products, checked_results, seed);
    $finish;
  end

endmodule
