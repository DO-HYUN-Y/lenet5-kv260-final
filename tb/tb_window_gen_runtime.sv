`timescale 1ns/1ps

module tb_window_gen_runtime;
  localparam int ACT_W = 8;
  localparam int NG = 4;
  localparam int NC = 8;
  localparam int K = 5;
  localparam int MAX_C_IN = 6;
  localparam int MAX_FMAP_W = 32;
  localparam int MAX_FMAP_H = 32;
  localparam int C_W = $clog2(MAX_C_IN + 1);
  localparam int DIM_W = $clog2(MAX_FMAP_W + 1);
  localparam int KOUT_W = $clog2(K*K*MAX_C_IN);

  import "DPI-C" function int runtime_pixel(
      input int case_id, input int index);
  import "DPI-C" function int runtime_row_zero(
      input int case_id, input int y);
  import "DPI-C" function int runtime_first_k(
      input int case_id, input int out_y);
  import "DPI-C" function int runtime_next_k(
      input int case_id, input int out_y, input int current_k);
  import "DPI-C" function int runtime_win(
      input int case_id, input int out_y, input int tile_x,
      input int k, input int lane);

  logic clk;
  logic rst_n;
  logic en;
  logic start;
  logic [DIM_W-1:0] cfg_fmap_w;
  logic [DIM_W-1:0] cfg_fmap_h;
  logic [C_W-1:0] cfg_c_in;
  logic [DIM_W-1:0] cfg_out_w;
  logic [DIM_W-1:0] cfg_out_h;
  logic signed [ACT_W-1:0] pix_in;
  logic pix_valid;
  logic pix_rd_en;
  logic signed [ACT_W-1:0] win_q [0:2*NG-1];
  logic pair_valid [0:NG-1];
  logic [1:0] lane_mask [0:NG-1];
  logic depth_last [0:NG-1];
  logic [KOUT_W-1:0] k_out;
  logic done;

  int active_case;
  int active_fmap_w;
  int active_fmap_h;
  int active_c_in;
  int active_out_w;
  int active_out_h;
  int pix_index;
  int source_y;
  int source_tile;
  int expected_k;
  int token_count;
  int rate_hold_count;
  int random_stalls;
  int seed;

  window_gen_runtime #(
    .ACT_W(ACT_W), .NG(NG), .NC(NC), .K(K),
    .MAX_C_IN(MAX_C_IN), .MAX_FMAP_W(MAX_FMAP_W),
    .MAX_FMAP_H(MAX_FMAP_H)
  ) dut (.*);

  always #5 clk = ~clk;
  always_comb begin
    pix_in = ACT_W'(runtime_pixel(active_case, pix_index));
    pix_valid = rst_n;
  end

  always_ff @(posedge clk) begin
    if (!rst_n || start)
      pix_index <= 0;
    else if (pix_rd_en)
      pix_index <= pix_index + 1;
  end

  always @(posedge clk) begin
    if (rst_n && en && pair_valid[0]) begin
      int next_k;
      int expected_mask;
      if (k_out !== KOUT_W'(expected_k))
        $fatal(1, "RUNTIME_WGEN k case=%0d y=%0d tile=%0d got=%0d exp=%0d",
               active_case, source_y, source_tile, k_out, expected_k);
      expected_mask = 0;
      for (int lane = 0; lane < 2 * NG; lane++) begin
        int x;
        int expected;
        x = source_tile * (2 * NG) + lane;
        if (x < active_out_w) expected_mask |= (1 << lane);
        expected = runtime_win(
            active_case, source_y, source_tile, expected_k, lane);
        if ($signed(win_q[lane]) !== expected)
          $fatal(1,
              "RUNTIME_WGEN win case=%0d y=%0d tile=%0d k=%0d lane=%0d got=%0d exp=%0d",
              active_case, source_y, source_tile, expected_k, lane,
              $signed(win_q[lane]), expected);
      end
      for (int g = 0; g < NG; g++) begin
        if (!pair_valid[g])
          $fatal(1, "RUNTIME_WGEN group valid g=%0d", g);
        if (lane_mask[g] !==
            {expected_mask[2*g+1], expected_mask[2*g]})
          $fatal(1, "RUNTIME_WGEN mask g=%0d got=%b", g, lane_mask[g]);
        if (depth_last[g] !== depth_last[0])
          $fatal(1, "RUNTIME_WGEN last mismatch g=%0d", g);
      end

      next_k = runtime_next_k(active_case, source_y, expected_k);
      if (depth_last[0] !== (next_k < 0))
        $fatal(1,
            "RUNTIME_WGEN last case=%0d y=%0d tile=%0d k=%0d got=%0b next=%0d",
            active_case, source_y, source_tile, expected_k,
            depth_last[0], next_k);
      token_count++;
      if (next_k < 0) begin
        if (source_tile ==
            (active_out_w + 2 * NG - 1) / (2 * NG) - 1) begin
          source_tile = 0;
          source_y++;
        end else begin
          source_tile++;
        end
        if (source_y < active_out_h)
          expected_k = runtime_first_k(active_case, source_y);
      end else begin
        expected_k = next_k;
      end
    end
    if (rst_n && en && dut.rate_hold_c) rate_hold_count++;
  end

  task automatic apply_reset;
    begin
      @(negedge clk);
      rst_n = 1'b0;
      en = 1'b0;
      start = 1'b0;
      repeat (3) @(negedge clk);
      rst_n = 1'b1;
      @(negedge clk);
    end
  endtask

  task automatic run_case(
      input int case_id,
      input int fmap_w,
      input int fmap_h,
      input int c_in,
      input int out_w,
      input int out_h
  );
    int expected_pixels;
    begin
      apply_reset();
      active_case = case_id;
      active_fmap_w = fmap_w;
      active_fmap_h = fmap_h;
      active_c_in = c_in;
      active_out_w = out_w;
      active_out_h = out_h;
      source_y = 0;
      source_tile = 0;
      expected_k = runtime_first_k(case_id, 0);
      token_count = 0;
      rate_hold_count = 0;
      cfg_fmap_w = DIM_W'(fmap_w);
      cfg_fmap_h = DIM_W'(fmap_h);
      cfg_c_in = C_W'(c_in);
      cfg_out_w = DIM_W'(out_w);
      cfg_out_h = DIM_W'(out_h);
      en = 1'b1;
      start = 1'b1;
      @(negedge clk);
      start = 1'b0;

      for (int guard = 0; guard < 40000 && !done; guard++) begin
        if (random_stalls)
          en = ($urandom_range(0, 9) != 0);
        else
          en = 1'b1;
        @(negedge clk);
      end
      en = 1'b1;
      if (!done)
        $fatal(1, "RUNTIME_WGEN timeout case=%0d state=%0d y=%0d tile=%0d",
               case_id, dut.state_r, source_y, source_tile);
      expected_pixels = fmap_w * fmap_h * c_in;
      if (pix_index != expected_pixels)
        $fatal(1, "RUNTIME_WGEN pixels case=%0d got=%0d exp=%0d",
               case_id, pix_index, expected_pixels);
      if ((source_y != out_h) || (source_tile != 0))
        $fatal(1, "RUNTIME_WGEN source count case=%0d y=%0d tile=%0d",
               case_id, source_y, source_tile);
      if ((case_id == 1) && (rate_hold_count == 0))
        $fatal(1, "RUNTIME_WGEN gap limiter untested case=%0d", case_id);
      $display(
          "RUNTIME_WGEN CASE PASSED id=%0d shape=%0dx%0dx%0d out=%0dx%0d tokens=%0d holds=%0d",
          case_id, fmap_w, fmap_h, c_in, out_w, out_h,
          token_count, rate_hold_count);
    end
  endtask

  initial begin
    int ignored;
    clk = 1'bx;
    rst_n = 1'bx;
    en = 1'bx;
    start = 1'bx;
    cfg_fmap_w = 'x;
    cfg_fmap_h = 'x;
    cfg_c_in = 'x;
    cfg_out_w = 'x;
    cfg_out_h = 'x;
    active_case = 1;
    active_fmap_w = 0;
    active_fmap_h = 0;
    active_c_in = 0;
    active_out_w = 0;
    active_out_h = 0;
    source_y = 0;
    source_tile = 0;
    expected_k = 0;
    token_count = 0;
    rate_hold_count = 0;
    random_stalls = 0;
    seed = 20260724;
    ignored = $value$plusargs("SEED=%d", seed);
    ignored = $value$plusargs("RANDOM_STALLS=%d", random_stalls);
    ignored = $urandom(seed);
    $display("RUNTIME_WGEN seed=%0d random_stalls=%0d",
             seed, random_stalls);

    #2;
    clk = 1'b0;
    rst_n = 1'b0;
    en = 1'b0;
    start = 1'b0;
    cfg_fmap_w = '0;
    cfg_fmap_h = '0;
    cfg_c_in = '0;
    cfg_out_w = '0;
    cfg_out_h = '0;
    repeat (3) @(negedge clk);
    rst_n = 1'b1;
    @(posedge clk);
    #1;
    if ($isunknown({done, pix_rd_en}))
      $fatal(1, "RUNTIME_WGEN XPROP after reset");

    run_case(1, 32, 32, 1, 28, 28);
    run_case(2, 14, 14, 6, 10, 10);
    $display("WINDOW_GEN_RUNTIME TEST PASSED");
    $finish;
  end

endmodule
