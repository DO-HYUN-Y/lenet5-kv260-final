`timescale 1ns/1ps

// Cycle-accurate integration test. The C functions are the only arithmetic
// reference; SV drives/monitors transactions and compares each source token
// and each PE result event at its observed cycle.
module tb_conv_stream_datapath;
  localparam int ACT_W = 8;
  localparam int WGT_W = 8;
  localparam int ACC_W = 32;
  localparam int NG = 4;
  localparam int NC = 8;
  localparam int C_IN = 2;
  localparam int FMAP_W = 13;
  localparam int FMAP_H = 13;
  localparam int K = 5;
  localparam int OUT_W = 9;
  localparam int OUT_H = 9;
  localparam int TILE = 2 * NG;
  localparam int NUM_TILES = (OUT_W + TILE - 1) / TILE;
  localparam int DEPTH = K * K * C_IN;
  localparam int MEM_DEPTH = 64;
  localparam int ADDR_W = $clog2(MEM_DEPTH);
  localparam int KOUT_W = $clog2(DEPTH);
  localparam int OUT_ADDR_W = 16;
  localparam int OUT_CH_W = 8;
  localparam int LAYER_ID_W = 3;
  localparam int OUT_BASE = 123;
  localparam int OUT_CH_BASE = 5;
  localparam int OUT_CHANNELS = NC;
  localparam int TEST_LAYER_ID = 2;
  localparam int BANK_ADDR_W = 9;
  localparam int BANK_BASE_WORD = 17;
  localparam int EXPECTED_PACKETS =
      OUT_H * ((NUM_TILES - 1) * NG * NC + NC);
  localparam int EXPECTED_BANK_WRITES = EXPECTED_PACKETS / NC;
  localparam int MAX_RESULTS_PER_PE = OUT_H * NUM_TILES * 2;

  import "DPI-C" function int golden_pixel(input int index);
  import "DPI-C" function int golden_weight(input int k, input int col);
  import "DPI-C" function int golden_win(input int out_y, input int tile_x,
                                            input int k, input int lane);
  import "DPI-C" function int golden_sum(input int out_y, input int out_x,
                                            input int col);
  import "DPI-C" function int golden_output_addr(
      input int base, input int channel, input int out_y, input int out_x);
  import "DPI-C" function int golden_bias(
      input int group_idx, input int col, input int lane);
  import "DPI-C" function int golden_scale(
      input int group_idx, input int col, input int lane);
  import "DPI-C" function int golden_postprocessed(
      input int out_y, input int out_x, input int col,
      input int group_idx, input int lane);

  logic clk, rst_n, en, start;
  logic signed [ACT_W-1:0] pix_in;
  logic pix_rd_en;
  logic wr_en;
  logic [ADDR_W-1:0] wr_addr;
  logic signed [WGT_W-1:0] wr_data [0:NC-1];
  logic [ADDR_W-1:0] base_layer, pass_idx;
  logic [OUT_ADDR_W-1:0] out_base_addr;
  logic [OUT_CH_W-1:0] out_ch_base, out_channels;
  logic fc_mode;
  logic [LAYER_ID_W-1:0] layer_id;
  logic param_wr_en;
  logic [$clog2(2*NG*NC)-1:0] param_wr_lane;
  logic signed [ACC_W-1:0] param_wr_bias;
  logic signed [17:0] param_wr_scale;
  logic relu_en;
  logic signed [ACC_W-1:0] acc_lo_out [0:NG-1][0:NC-1];
  logic signed [ACC_W-1:0] acc_hi_out [0:NG-1][0:NC-1];
  logic [1:0] acc_valid [0:NG-1][0:NC-1];
  logic result_valid [0:NC-1];
  logic result_ready [0:NC-1];
  logic [15:0] result_data [0:NC-1];
  logic [1:0] result_lane_mask [0:NC-1];
  logic [OUT_ADDR_W-1:0] result_addr_lo [0:NC-1];
  logic [OUT_ADDR_W-1:0] result_addr_hi [0:NC-1];
  logic [OUT_CH_W-1:0] result_channel_lo [0:NC-1];
  logic [OUT_CH_W-1:0] result_channel_hi [0:NC-1];
  logic [$clog2(NG)-1:0] result_group [0:NC-1];
  logic result_fc_mode [0:NC-1];
  logic [LAYER_ID_W-1:0] result_layer_id [0:NC-1];
  logic bank_ready [0:NC-1];
  logic bank_we [0:NC-1];
  logic [BANK_ADDR_W-1:0] bank_word_addr [0:NC-1];
  logic [15:0] bank_wdata [0:NC-1];
  logic [1:0] bank_wstrb [0:NC-1];
  logic done;

  conv_stream_datapath #(
    .ACT_W(ACT_W), .WGT_W(WGT_W), .ACC_W(ACC_W), .NG(NG), .NC(NC),
    .C_IN(C_IN), .FMAP_W(FMAP_W), .FMAP_H(FMAP_H), .K(K),
    .OUT_W(OUT_W), .OUT_H(OUT_H), .MEM_DEPTH(MEM_DEPTH),
    .OUT_ADDR_W(OUT_ADDR_W), .OUT_CH_W(OUT_CH_W),
    .LAYER_ID_W(LAYER_ID_W)
  ) dut (.*);

  banked_activation_writer #(
    .NC(NC), .BYTE_ADDR_W(OUT_ADDR_W), .WORD_ADDR_W(BANK_ADDR_W)
  ) u_banked_writer (
    .clk(clk), .rst_n(rst_n), .start(start),
    .cfg_bank_base_word(BANK_ADDR_W'(BANK_BASE_WORD)),
    .in_valid(result_valid), .in_ready(result_ready),
    .in_data(result_data), .in_lane_mask(result_lane_mask),
    .in_addr_lo(result_addr_lo), .in_addr_hi(result_addr_hi),
    .bank_we(bank_we), .bank_ready(bank_ready),
    .bank_word_addr(bank_word_addr), .bank_wdata(bank_wdata),
    .bank_wstrb(bank_wstrb)
  );

  always #5 clk = ~clk;

  int pix_index;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) pix_index <= 0;
    else if (pix_rd_en) pix_index <= pix_index + 1;
  end
  always_comb pix_in = ACT_W'(golden_pixel(pix_index));

  int exp_lo [0:NG-1][0:NC-1][0:MAX_RESULTS_PER_PE-1];
  int exp_hi [0:NG-1][0:NC-1][0:MAX_RESULTS_PER_PE-1];
  int q_head [0:NG-1][0:NC-1][0:1];
  int q_tail [0:NG-1][0:NC-1][0:1];
  bit result_seen [0:NC-1][0:OUT_H-1][0:OUT_W-1];
  int source_band, source_tile;
  int acc_result_lanes, router_result_lanes, router_packets;
  int compute_cycles, prefetch_wait_cycles, router_stall_cycles;
  int rate_hold_cycles;
  int run_cycle, random_cycles, seed, dummy_seed;
  int bank_write_count [0:NC-1];
  int bank_expected_addr [0:NC-1];

  task automatic enqueue_expected(input int g, input int c, input int lane,
                                  input int value);
    int tail;
    begin
      tail = q_tail[g][c][lane];
      if (tail >= MAX_RESULTS_PER_PE)
        $fatal(1, "QUEUE OVERFLOW g=%0d c=%0d lane=%0d", g, c, lane);
      if (lane == 0) exp_lo[g][c][tail] = value;
      else exp_hi[g][c][tail] = value;
      q_tail[g][c][lane] = tail + 1;
    end
  endtask

  task automatic check_result(input int g, input int c, input int lane,
                              input logic signed [ACC_W-1:0] observed);
    int head;
    int expected;
    begin
      head = q_head[g][c][lane];
      if (head >= q_tail[g][c][lane])
        $fatal(1, "RESULT WITHOUT TOKEN g=%0d c=%0d lane=%0d", g, c, lane);
      expected = (lane == 0) ? exp_lo[g][c][head] : exp_hi[g][c][head];
      if ($signed(observed) !== expected)
        $fatal(1, "RESULT MISMATCH g=%0d c=%0d lane=%0d got=%0d exp=%0d",
               g, c, lane, $signed(observed), expected);
      q_head[g][c][lane] = head + 1;
      acc_result_lanes++;
    end
  endtask

  task automatic check_router_lane(
      input int stream_col,
      input int group_idx,
      input int lane,
      input logic signed [7:0] observed,
      input logic [OUT_ADDR_W-1:0] observed_addr,
      input logic [OUT_CH_W-1:0] observed_channel);
    int local_col;
    int position;
    int out_y;
    int out_x;
    int expected;
    int expected_addr;
    int expected_group;
    int expected_lane;
    begin
      if ((observed_channel < OUT_CH_BASE) ||
          (observed_channel >= OUT_CH_BASE + OUT_CHANNELS))
        $fatal(1, "ROUTER CHANNEL RANGE lane=%0d channel=%0d",
               lane, observed_channel);
      local_col = observed_channel - OUT_CH_BASE;
      if (local_col != stream_col)
        $fatal(1, "ROUTER COLUMN stream=%0d channel_col=%0d",
               stream_col, local_col);
      position = observed_addr - OUT_BASE -
                 observed_channel * (OUT_W * OUT_H);
      out_y = position / OUT_W;
      out_x = position % OUT_W;
      if ((position < 0) || (out_y >= OUT_H) || (out_x >= OUT_W))
        $fatal(1, "ROUTER ADDRESS RANGE lane=%0d addr=%0d channel=%0d",
               lane, observed_addr, observed_channel);
      if (result_seen[local_col][out_y][out_x])
        $fatal(1, "ROUTER DUPLICATE c=%0d y=%0d x=%0d",
               local_col, out_y, out_x);
      expected_group = (out_x % TILE) / 2;
      expected_lane = out_x % 2;
      if ((group_idx != expected_group) || (lane != expected_lane))
        $fatal(1, "ROUTER PHYSICAL MAP c=%0d y=%0d x=%0d g=%0d/%0d lane=%0d/%0d",
               local_col, out_y, out_x, group_idx, expected_group,
               lane, expected_lane);
      expected = golden_postprocessed(
          out_y, out_x, local_col, group_idx, lane);
      expected_addr = golden_output_addr(
          OUT_BASE, observed_channel, out_y, out_x);
      if ($signed(observed) !== expected)
        $fatal(1, "ROUTER DATA c=%0d y=%0d x=%0d got=%0d exp=%0d",
               local_col, out_y, out_x, $signed(observed), expected);
      if (observed_addr !== OUT_ADDR_W'(expected_addr))
        $fatal(1, "ROUTER ADDRESS c=%0d y=%0d x=%0d got=%0d exp=%0d",
               local_col, out_y, out_x, observed_addr, expected_addr);
      result_seen[local_col][out_y][out_x] = 1'b1;
      router_result_lanes++;
    end
  endtask

  task automatic check_router_packet(input int c);
    begin
      if (result_lane_mask[c] == 2'b00)
        $fatal(1, "ROUTER EMPTY PACKET");
      if (result_fc_mode[c] !== 1'b0)
        $fatal(1, "ROUTER MODE c=%0d got=%0d exp=0",
               c, result_fc_mode[c]);
      if (result_layer_id[c] !== LAYER_ID_W'(TEST_LAYER_ID))
        $fatal(1, "ROUTER LAYER got=%0d exp=%0d",
               result_layer_id[c], TEST_LAYER_ID);
      if (result_lane_mask[c][0])
        check_router_lane(c, result_group[c], 0, $signed(result_data[c][7:0]),
                          result_addr_lo[c], result_channel_lo[c]);
      if (result_lane_mask[c][1])
        check_router_lane(c, result_group[c], 1, $signed(result_data[c][15:8]),
                          result_addr_hi[c], result_channel_hi[c]);
      router_packets++;
    end
  endtask

  // Output handshakes are checked before NBA updates. Source/PE results are
  // checked after NBA only when the exact shared compute enable advanced.
  always @(posedge clk) begin
    bit advance_before;
    for (int c = 0; c < NC; c++)
      if (rst_n && result_valid[c] && result_ready[c])
        check_router_packet(c);
    for (int c = 0; c < NC; c++) begin
      if (rst_n && bank_we[c]) begin
        if (bank_word_addr[c] !== BANK_ADDR_W'(bank_expected_addr[c]))
          $fatal(1, "BANK WRITE ADDR c=%0d got=%0d exp=%0d",
                 c, bank_word_addr[c], bank_expected_addr[c]);
        if ({bank_wdata[c], bank_wstrb[c]} !==
            {result_data[c], result_lane_mask[c]})
          $fatal(1, "BANK WRITE PAYLOAD c=%0d", c);
        bank_expected_addr[c]++;
        bank_write_count[c]++;
      end
    end
    advance_before = dut.pipe_en;
    if (rst_n && en && !dut.router_ingress_ready)
      router_stall_cycles++;
    if (rst_n) begin
      #1;
      if (advance_before) begin
        run_cycle++;
        if (dut.u_window_gen.state_r == 3'd3) compute_cycles++;
        if (dut.u_window_gen.state_r == 3'd4) prefetch_wait_cycles++;
        if (dut.u_window_gen.rate_hold_c) rate_hold_cycles++;
      end

      if (advance_before && dut.src_pair_valid[0]) begin
        for (int r = 0; r < 2 * NG; r++) begin
          int expected_win;
          expected_win = golden_win(source_band, source_tile, dut.src_k_out, r);
          if ($signed(dut.src_win_q[r]) !== expected_win)
            $fatal(1, "WIN MISMATCH y=%0d tile=%0d k=%0d lane=%0d got=%0d exp=%0d",
                   source_band, source_tile, dut.src_k_out, r,
                   $signed(dut.src_win_q[r]), expected_win);
        end
        if (!dut.wgt_valid || dut.wgt_k_out !== dut.src_k_out)
          $fatal(1, "SOURCE/WEIGHT TAG MISMATCH k=%0d wvalid=%0d wk=%0d",
                 dut.src_k_out, dut.wgt_valid, dut.wgt_k_out);
        for (int c = 0; c < NC; c++) begin
          if ($signed(dut.wgt_q[c]) !== golden_weight(dut.src_k_out, c))
            $fatal(1, "WEIGHT MISMATCH k=%0d c=%0d got=%0d exp=%0d",
                   dut.src_k_out, c, $signed(dut.wgt_q[c]),
                   golden_weight(dut.src_k_out, c));
        end

        if (dut.src_depth_last[0]) begin
          for (int g = 0; g < NG; g++) begin
            int x_lo;
            x_lo = source_tile * TILE + 2 * g;
            for (int c = 0; c < NC; c++) begin
              if (dut.src_lane_mask[g][0])
                enqueue_expected(g, c, 0, golden_sum(source_band, x_lo, c));
              if (dut.src_lane_mask[g][1])
                enqueue_expected(g, c, 1, golden_sum(source_band, x_lo + 1, c));
            end
          end
          if (source_tile == NUM_TILES - 1) begin
            source_tile = 0;
            source_band++;
          end else begin
            source_tile++;
          end
        end
      end else if (advance_before && dut.wgt_valid) begin
        $fatal(1, "WEIGHT VALID WITHOUT SOURCE VALID");
      end

      if (advance_before)
        for (int g = 0; g < NG; g++)
          for (int c = 0; c < NC; c++) begin
            if (acc_valid[g][c][0]) check_result(g, c, 0, acc_lo_out[g][c]);
            if (acc_valid[g][c][1]) check_result(g, c, 1, acc_hi_out[g][c]);
          end
    end
  end

  initial begin
    clk = 1'bx;
    rst_n = 1'bx;
    en = 1'bx;
    start = 1'bx;
    wr_en = 1'bx;
    wr_addr = 'x;
    base_layer = 'x;
    pass_idx = 'x;
    out_base_addr = 'x;
    out_ch_base = 'x;
    out_channels = 'x;
    fc_mode = 1'bx;
    layer_id = 'x;
    param_wr_en = 1'bx;
    param_wr_lane = 'x;
    param_wr_bias = 'x;
    param_wr_scale = 'x;
    relu_en = 1'bx;
    for (int c = 0; c < NC; c++) bank_ready[c] = 1'bx;
    for (int c = 0; c < NC; c++) wr_data[c] = 'x;
    #2;
    clk = 0;
    rst_n = 0;
    en = 0;
    start = 0;
    wr_en = 0;
    wr_addr = '0;
    base_layer = '0;
    pass_idx = '0;
    out_base_addr = OUT_ADDR_W'(OUT_BASE);
    out_ch_base = OUT_CH_W'(OUT_CH_BASE);
    out_channels = OUT_CH_W'(OUT_CHANNELS);
    fc_mode = 1'b0;
    layer_id = LAYER_ID_W'(TEST_LAYER_ID);
    param_wr_en = 1'b0;
    param_wr_lane = '0;
    param_wr_bias = '0;
    param_wr_scale = '0;
    relu_en = 1'b1;
    for (int c = 0; c < NC; c++) bank_ready[c] = 1'b0;
    for (int c = 0; c < NC; c++) wr_data[c] = '0;
    for (int g = 0; g < NG; g++)
      for (int c = 0; c < NC; c++)
        for (int l = 0; l < 2; l++) begin
          q_head[g][c][l] = 0;
          q_tail[g][c][l] = 0;
        end
    for (int c = 0; c < NC; c++)
      for (int y = 0; y < OUT_H; y++)
        for (int x = 0; x < OUT_W; x++)
          result_seen[c][y][x] = 1'b0;
    for (int c = 0; c < NC; c++) begin
      bank_write_count[c] = 0;
      bank_expected_addr[c] = BANK_BASE_WORD;
    end
    source_band = 0;
    source_tile = 0;
    acc_result_lanes = 0;
    router_result_lanes = 0;
    router_packets = 0;
    compute_cycles = 0;
    prefetch_wait_cycles = 0;
    router_stall_cycles = 0;
    rate_hold_cycles = 0;
    run_cycle = 0;
    random_cycles = 0;
    seed = 314159;
    dummy_seed = $value$plusargs("RANDOM_CYCLES=%d", random_cycles);
    dummy_seed = $value$plusargs("SEED=%d", seed);
    dummy_seed = $urandom(seed);
    $display("CONV_STREAM seed=%0d random_cycles=%0d", seed, random_cycles);

    repeat (4) @(negedge clk);
    rst_n = 1;
    @(posedge clk);
    #1;
    if ($isunknown(done) || $isunknown(pix_rd_en))
      $fatal(1, "XPROP: visible control output unknown after reset");

    // Preload all depth positions into the eight physical column banks.
    for (int a = 0; a < DEPTH; a++) begin
      @(negedge clk);
      wr_en = 1;
      wr_addr = ADDR_W'(a);
      for (int c = 0; c < NC; c++) wr_data[c] = WGT_W'(golden_weight(a, c));
    end
    @(negedge clk);
    wr_en = 0;
    for (int c = 0; c < NC; c++) wr_data[c] = '0;

    // Preload one fixed-point bias/scale entry for every physical logical lane.
    for (int g = 0; g < NG; g++) begin
      for (int c = 0; c < NC; c++) begin
        for (int lane = 0; lane < 2; lane++) begin
          @(negedge clk);
          param_wr_en = 1'b1;
          param_wr_lane = (g * 2 * NC) + (c * 2) + lane;
          param_wr_bias = golden_bias(g, c, lane);
          param_wr_scale = golden_scale(g, c, lane);
        end
      end
    end
    @(negedge clk);
    param_wr_en = 1'b0;

    // One further edge drains the final preload transaction.
    @(negedge clk);
    en = 1;
    for (int c = 0; c < NC; c++) bank_ready[c] = 1;
    start = 1;
    @(negedge clk);
    start = 0;

    // Directed run has random_cycles=0. The optional seeded phase independently
    // stalls source movement and output consumption.
    for (int guard = 0; guard < 8000 && !done; guard++) begin
      if (random_cycles != 0 && guard < random_cycles) begin
        en = ($urandom_range(0, 9) != 0);
        // Deliberately harsh 50% sink availability exercises skid-register
        // backpressure, held-valid stability, and lossless recovery.
        for (int c = 0; c < NC; c++)
          bank_ready[c] = ($urandom_range(0, 1) != 0);
      end else begin
        en = 1'b1;
        for (int c = 0; c < NC; c++) bank_ready[c] = 1'b1;
      end
      @(negedge clk);
    end
    en = 1'b1;
    for (int c = 0; c < NC; c++) bank_ready[c] = 1'b1;
    if (!done) begin
      $display("TIMEOUT state=%0d router_idle=%0d ingress_ready=%0d pending=%0d window_done=%0d result_valid=%0d pix=%0d band=%0d tile=%0d acc=%0d routed=%0d",
               dut.u_window_gen.state_r, dut.router_idle,
               dut.router_ingress_ready, dut.job_drain_pending_r,
               dut.window_done, result_valid[0], pix_index, source_band,
               source_tile, acc_result_lanes, router_result_lanes);
      $fatal(1, "TIMEOUT waiting for done");
    end
    repeat (3) @(negedge clk);

    if (pix_index != C_IN * FMAP_W * FMAP_H)
      $fatal(1, "PIXEL COUNT got=%0d exp=%0d", pix_index, C_IN * FMAP_W * FMAP_H);
    if (source_band != OUT_H || source_tile != 0)
      $fatal(1, "SOURCE TILE COUNT y=%0d tile=%0d", source_band, source_tile);
    if (rate_hold_cycles == 0)
      $fatal(1, "RATE LIMIT was not exercised by sparse directed image");
    if (prefetch_wait_cycles != 0)
      $display("PREFETCH WAIT observed=%0d router_stalls=%0d",
               prefetch_wait_cycles, router_stall_cycles);
    if (acc_result_lanes != OUT_H * OUT_W * NC)
      $fatal(1, "ACC LANE COUNT got=%0d exp=%0d",
             acc_result_lanes, OUT_H * OUT_W * NC);
    if (router_result_lanes != OUT_H * OUT_W * NC)
      $fatal(1, "ROUTER LANE COUNT got=%0d exp=%0d",
             router_result_lanes, OUT_H * OUT_W * NC);
    if (router_packets != EXPECTED_PACKETS)
      $fatal(1, "ROUTER PACKET COUNT got=%0d exp=%0d",
             router_packets, EXPECTED_PACKETS);
    for (int c = 0; c < NC; c++) begin
      if (bank_write_count[c] != EXPECTED_BANK_WRITES)
        $fatal(1, "BANK WRITE COUNT c=%0d got=%0d exp=%0d",
               c, bank_write_count[c], EXPECTED_BANK_WRITES);
      if (bank_expected_addr[c] !=
          BANK_BASE_WORD + EXPECTED_BANK_WRITES)
        $fatal(1, "BANK FINAL ADDR c=%0d got=%0d exp=%0d",
               c, bank_expected_addr[c],
               BANK_BASE_WORD + EXPECTED_BANK_WRITES);
    end
    for (int c = 0; c < NC; c++)
      for (int y = 0; y < OUT_H; y++)
        for (int x = 0; x < OUT_W; x++)
          if (!result_seen[c][y][x])
            $fatal(1, "ROUTER MISSING c=%0d y=%0d x=%0d", c, y, x);
    for (int g = 0; g < NG; g++)
      for (int c = 0; c < NC; c++)
        for (int l = 0; l < 2; l++)
          if (q_head[g][c][l] != q_tail[g][c][l])
            $fatal(1, "UNCONSUMED RESULT g=%0d c=%0d lane=%0d head=%0d tail=%0d",
                   g, c, l, q_head[g][c][l], q_tail[g][c][l]);

    if (!dut.router_idle || !dut.postprocess_idle)
      $fatal(1, "EGRESS NOT IDLE AT DONE router=%0d post=%0d",
             dut.router_idle, dut.postprocess_idle);
    $display("CONV_STREAM_DATAPATH TEST PASSED compute=%0d prefetch_wait=%0d rate_holds=%0d acc_lanes=%0d router_packets=%0d router_stalls=%0d",
             compute_cycles, prefetch_wait_cycles, rate_hold_cycles,
             acc_result_lanes, router_packets, router_stall_cycles);
    $finish;
  end
endmodule
