`timescale 1ns/1ps

module tb_alexnet_m4n8_result_scanner;

  localparam int PHYS_ROWS = 2;
  localparam int COLS = 8;
  localparam int TILE_TAG_W = 16;

  import "DPI-C" function int alexnet_golden_scanner_reset(
      input int m_count, input int n_count, input int n_base);
  import "DPI-C" function int alexnet_golden_scanner_tick(
      input byte ready, output byte valid, output int m,
      output byte n_lane_mask);

  logic clk = 1'b0;
  logic rst;
  logic tile_valid;
  logic tile_ready;
  logic [2:0] tile_m_count;
  logic [COLS-1:0] tile_n_lane_mask;
  logic [TILE_TAG_W-1:0] tile_tag;
  logic hold_valid [0:PHYS_ROWS-1][0:COLS-1];
  logic hold_ready [0:PHYS_ROWS-1][0:COLS-1];
  logic signed [31:0] hold_lo [0:PHYS_ROWS-1][0:COLS-1];
  logic signed [31:0] hold_hi [0:PHYS_ROWS-1][0:COLS-1];
  logic [1:0] hold_m_lane_mask [0:PHYS_ROWS-1][0:COLS-1];
  logic out_valid;
  logic out_ready;
  logic signed [31:0] out_accumulator [0:COLS-1];
  logic [1:0] out_m;
  logic [COLS-1:0] out_n_lane_mask;
  logic [TILE_TAG_W-1:0] out_tile_tag;
  logic busy;
  logic tile_done;

  alexnet_m4n8_result_scanner dut (.*);

  always #2.5 clk = ~clk;

  int checked_beats;
  logic stalled_previous;
  logic [1:0] stalled_m;
  logic [7:0] stalled_n_mask;
  logic [15:0] stalled_tag;
  logic signed [31:0] stalled_accumulator [0:COLS-1];

  function automatic int expected_accumulator(
      input int tag_value, input int m_value, input int column);
    expected_accumulator = tag_value * 10000 + m_value * 100 + column;
  endfunction

  always_ff @(posedge clk) begin
    if (rst) begin
      for (int g = 0; g < PHYS_ROWS; g++)
        for (int c = 0; c < COLS; c++)
          hold_valid[g][c] <= 1'b0;
    end else begin
      for (int g = 0; g < PHYS_ROWS; g++)
        for (int c = 0; c < COLS; c++)
          if (hold_valid[g][c] && hold_ready[g][c])
            hold_valid[g][c] <= 1'b0;
    end
  end

  // Sample the transfer immediately before the DUT's nonblocking state
  // update. All ready/data stimulus changes on the preceding negedge.
  always @(posedge clk) begin
    byte golden_valid;
    byte golden_mask;
    int golden_m;
    int status;

    if (rst) begin
      checked_beats = 0;
      stalled_previous = 1'b0;
    end else begin
      if (stalled_previous) begin
        if (!out_valid || out_m !== stalled_m ||
            out_n_lane_mask !== stalled_n_mask || out_tile_tag !== stalled_tag)
          $fatal(1, "scanner tags changed while valid && !ready");
        for (int c = 0; c < COLS; c++)
          if (out_accumulator[c] !== stalled_accumulator[c])
            $fatal(1, "scanner data changed while stalled at column %0d", c);
      end

      if (out_valid) begin
        status = alexnet_golden_scanner_tick(
            out_ready, golden_valid, golden_m, golden_mask);
        if (status != 0 || golden_valid == 0)
          $fatal(1, "C++ scanner oracle failed status=%0d valid=%0d",
                 status, golden_valid);
        if (out_m != golden_m || out_n_lane_mask != golden_mask)
          $fatal(1, "scanner coordinate mismatch got m=%0d mask=%02x expected=%0d/%02x",
                 out_m, out_n_lane_mask, golden_m, golden_mask);
        for (int c = 0; c < COLS; c++) begin
          int expected_value;
          expected_value = out_n_lane_mask[c] ?
              expected_accumulator(out_tile_tag, out_m, c) : 0;
          if ($signed(out_accumulator[c]) != expected_value)
            $fatal(1, "scanner value mismatch m=%0d c=%0d got=%0d expected=%0d",
                   out_m, c, $signed(out_accumulator[c]), expected_value);
        end
        if (out_ready)
          checked_beats = checked_beats + 1;
      end

      stalled_previous = out_valid && !out_ready;
      stalled_m = out_m;
      stalled_n_mask = out_n_lane_mask;
      stalled_tag = out_tile_tag;
      for (int c = 0; c < COLS; c++)
        stalled_accumulator[c] = out_accumulator[c];
    end
  end

  task automatic run_tile(
      input int m_count,
      input int n_count,
      input int tag_value,
      input bit stagger_holdings);
    int status;
    logic [1:0] row_mask [0:PHYS_ROWS-1];
    begin
      while (!tile_ready)
        @(negedge clk);

      row_mask[0] = (m_count == 1) ? 2'b01 : 2'b11;
      if (m_count <= 2)
        row_mask[1] = 2'b00;
      else
        row_mask[1] = (m_count == 3) ? 2'b01 : 2'b11;

      for (int g = 0; g < PHYS_ROWS; g++) begin
        for (int c = 0; c < COLS; c++) begin
          hold_valid[g][c] = 1'b0;
          hold_m_lane_mask[g][c] = row_mask[g];
          hold_lo[g][c] = expected_accumulator(tag_value, 2*g, c);
          hold_hi[g][c] = expected_accumulator(tag_value, 2*g+1, c);
        end
      end

      tile_m_count = m_count;
      tile_n_lane_mask = (9'b1 << n_count) - 1'b1;
      tile_tag = tag_value;
      status = alexnet_golden_scanner_reset(m_count, n_count, 0);
      if (status != 0)
        $fatal(1, "C++ scanner reset failed status=%0d", status);

      tile_valid = 1'b1;
      out_ready = 1'b0;
      @(negedge clk);
      tile_valid = 1'b0;

      for (int g = 0; g < PHYS_ROWS; g++) begin
        if (row_mask[g] != 0) begin
          for (int c = 0; c < COLS; c++) begin
            hold_valid[g][c] = 1'b1;
            if (stagger_holdings)
              @(negedge clk);
          end
        end
      end

      while (busy) begin
        out_ready = ($urandom_range(0, 3) != 0);
        @(negedge clk);
      end
      out_ready = 1'b1;
      @(negedge clk);

      for (int g = 0; g < PHYS_ROWS; g++)
        for (int c = 0; c < COLS; c++)
          if (hold_valid[g][c])
            $fatal(1, "scanner failed to release active holding [%0d][%0d]", g, c);
    end
  endtask

  initial begin
    int seed_sink;
    seed_sink = $urandom(32'h4e38_5343);

    rst = 1'b1;
    tile_valid = 1'b0;
    tile_m_count = 1;
    tile_n_lane_mask = 8'h01;
    tile_tag = '0;
    out_ready = 1'b0;
    for (int g = 0; g < PHYS_ROWS; g++)
      for (int c = 0; c < COLS; c++) begin
        hold_valid[g][c] = 1'b0;
        hold_lo[g][c] = '0;
        hold_hi[g][c] = '0;
        hold_m_lane_mask[g][c] = '0;
      end

    repeat (5) @(negedge clk);
    rst = 1'b0;
    @(negedge clk);

    run_tile(1, 1, 1, 1'b1);
    run_tile(2, 4, 2, 1'b0);
    run_tile(3, 7, 3, 1'b1);
    run_tile(4, 8, 4, 1'b0);

    for (int tile = 0; tile < 100; tile++)
      run_tile($urandom_range(1, 4), $urandom_range(1, 8), tile + 10,
               $urandom_range(0, 1));

    $display("ALEXNET_M4N8_SCANNER_TEST_PASSED beats=%0d", checked_beats);
    $finish;
  end

endmodule
