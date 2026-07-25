`timescale 1ns/1ps

module tb_lenet_compute_core;
  localparam int DATA_W = 8;
  localparam int ACC_W = 32;
  localparam int NG = 4;
  localparam int NC = 8;
  localparam int K = 5;
  localparam int MAX_C_IN = 6;
  localparam int MAX_FMAP_W = 32;
  localparam int MAX_FMAP_H = 32;
  localparam int DIM_W = $clog2(MAX_FMAP_W + 1);
  localparam int C_W = $clog2(MAX_C_IN + 1);
  localparam int KOUT_W = 9;
  localparam int MEM_DEPTH = 256;
  localparam int WGT_ADDR_W = $clog2(MEM_DEPTH);
  localparam int OUT_ADDR_W = 16;
  localparam int OUT_CH_W = 8;
  localparam int LAYER_ID_W = 3;
  localparam int BANK_ADDR_W = 9;
  localparam int CONV_W = 13;
  localparam int CONV_H = 13;
  localparam int CONV_C = 2;
  localparam int CONV_OUT_W = 9;
  localparam int CONV_OUT_H = 9;
  localparam int CONV_DEPTH = 50;
  localparam int CONV_PACKETS_PER_ROW = 5;
  localparam int FC_DEPTH = 23;
  localparam int FC_OUTPUTS = 10;
  localparam int FC_WEIGHT_BASE = 64;
  localparam int FC_BANK_BASE = 100;

  import "DPI-C" function int golden_pixel(input int index);
  import "DPI-C" function int golden_weight(input int k, input int col);
  import "DPI-C" function int golden_postprocessed(
      input int out_y, input int out_x, input int col,
      input int group_idx, input int lane);
  import "DPI-C" function int golden_bias(
      input int group_idx, input int col, input int lane);
  import "DPI-C" function int golden_scale(
      input int group_idx, input int col, input int lane);
  import "DPI-C" function int fc_golden_activation(input int k);
  import "DPI-C" function int fc_golden_weight(
      input int filter, input int k);
  import "DPI-C" function int fc_golden_bias(input int filter);
  import "DPI-C" function int fc_golden_scale(input int filter);
  import "DPI-C" function int fc_golden_postprocessed(
      input int filter, input int relu_en);

  logic clk;
  logic rst_n;
  logic en;
  logic start;
  logic cfg_fc_mode;
  logic [DIM_W-1:0] cfg_fmap_w;
  logic [DIM_W-1:0] cfg_fmap_h;
  logic [C_W-1:0] cfg_c_in;
  logic [DIM_W-1:0] cfg_out_w;
  logic [DIM_W-1:0] cfg_out_h;
  logic [KOUT_W-1:0] cfg_depth;
  logic signed [DATA_W-1:0] pix_in;
  logic pix_valid;
  logic pix_rd_en;
  logic weight_wr_en [0:NC-1];
  logic [WGT_ADDR_W-1:0] weight_wr_addr;
  logic [2*NG*DATA_W-1:0] weight_wr_data [0:NC-1];
  logic [WGT_ADDR_W-1:0] weight_read_base;
  logic [OUT_ADDR_W-1:0] out_base_addr;
  logic [OUT_ADDR_W-1:0] out_plane_size;
  logic [OUT_CH_W-1:0] out_ch_base;
  logic [OUT_CH_W-1:0] out_channels;
  logic [OUT_CH_W-1:0] pass_channels;
  logic [LAYER_ID_W-1:0] layer_id;
  logic param_wr_en;
  logic [$clog2(2*NG*NC)-1:0] param_wr_lane;
  logic signed [ACC_W-1:0] param_wr_bias;
  logic signed [17:0] param_wr_scale;
  logic relu_en;
  logic [BANK_ADDR_W-1:0] cfg_bank_base_word;
  logic bank_ready [0:NC-1];
  logic bank_we [0:NC-1];
  logic [BANK_ADDR_W-1:0] bank_word_addr [0:NC-1];
  logic [15:0] bank_wdata [0:NC-1];
  logic [1:0] bank_wstrb [0:NC-1];
  logic signed [ACC_W-1:0] debug_acc_lo [0:NG-1][0:NC-1];
  logic signed [ACC_W-1:0] debug_acc_hi [0:NG-1][0:NC-1];
  logic [1:0] debug_acc_valid [0:NG-1][0:NC-1];
  logic busy;
  logic done;

  int pix_index;
  bit active_mode_fc;
  int operation_lane_count;
  int total_lane_count;
  bit conv_seen [0:NC-1][0:CONV_OUT_H-1][0:CONV_OUT_W-1];
  bit fc_seen [0:FC_OUTPUTS-1];
  int random_stalls;
  int seed;

  lenet_compute_core #(
    .DATA_W(DATA_W), .ACC_W(ACC_W), .NG(NG), .NC(NC), .K(K),
    .MAX_C_IN(MAX_C_IN), .MAX_FMAP_W(MAX_FMAP_W),
    .MAX_FMAP_H(MAX_FMAP_H), .KOUT_W(KOUT_W),
    .MEM_DEPTH(MEM_DEPTH), .WGT_ADDR_W(WGT_ADDR_W),
    .OUT_ADDR_W(OUT_ADDR_W), .OUT_CH_W(OUT_CH_W),
    .LAYER_ID_W(LAYER_ID_W), .BANK_ADDR_W(BANK_ADDR_W)
  ) dut (.*);

  always #5 clk = ~clk;
  always_comb begin
    if (active_mode_fc)
      pix_in = DATA_W'(fc_golden_activation(pix_index));
    else
      pix_in = DATA_W'(golden_pixel(pix_index));
    pix_valid = rst_n;
  end

  always_ff @(posedge clk) begin
    if (!rst_n || start)
      pix_index <= 0;
    else if (pix_rd_en)
      pix_index <= pix_index + 1;
  end

  always @(posedge clk) begin
    if (rst_n) begin
      for (int c = 0; c < NC; c++) begin
        if (bank_we[c]) begin
          if (active_mode_fc) begin
            int group_idx;
            int filter_lo;
            int got;
            group_idx = bank_word_addr[c] - FC_BANK_BASE;
            filter_lo = group_idx * (2 * NC) + 2 * c;
            if ((group_idx < 0) || (group_idx >= NG))
              $fatal(1, "CORE FC bank addr c=%0d addr=%0d",
                     c, bank_word_addr[c]);
            if (bank_wstrb[c][0]) begin
              got = $signed(bank_wdata[c][7:0]);
              if ((filter_lo >= FC_OUTPUTS) || fc_seen[filter_lo])
                $fatal(1, "CORE FC low filter=%0d", filter_lo);
              if (got != fc_golden_postprocessed(filter_lo, 1))
                $fatal(1, "CORE FC data filter=%0d got=%0d exp=%0d",
                       filter_lo, got,
                       fc_golden_postprocessed(filter_lo, 1));
              fc_seen[filter_lo] = 1'b1;
              operation_lane_count++;
              total_lane_count++;
            end
            if (bank_wstrb[c][1]) begin
              got = $signed(bank_wdata[c][15:8]);
              if ((filter_lo + 1 >= FC_OUTPUTS) ||
                  fc_seen[filter_lo + 1])
                $fatal(1, "CORE FC high filter=%0d", filter_lo + 1);
              if (got != fc_golden_postprocessed(filter_lo + 1, 1))
                $fatal(1, "CORE FC data filter=%0d got=%0d exp=%0d",
                       filter_lo + 1, got,
                       fc_golden_postprocessed(filter_lo + 1, 1));
              fc_seen[filter_lo + 1] = 1'b1;
              operation_lane_count++;
              total_lane_count++;
            end
          end else begin
            int packet;
            int out_y;
            int pair_x;
            int out_x;
            int group_idx;
            int got;
            packet = bank_word_addr[c];
            out_y = packet / CONV_PACKETS_PER_ROW;
            pair_x = packet % CONV_PACKETS_PER_ROW;
            out_x = 2 * pair_x;
            group_idx = (out_x % (2 * NG)) / 2;
            if ((out_y >= CONV_OUT_H) || (out_x >= CONV_OUT_W))
              $fatal(1, "CORE CONV bank map c=%0d addr=%0d",
                     c, bank_word_addr[c]);
            if (bank_wstrb[c][0]) begin
              got = $signed(bank_wdata[c][7:0]);
              if (conv_seen[c][out_y][out_x])
                $fatal(1, "CORE CONV duplicate c=%0d y=%0d x=%0d",
                       c, out_y, out_x);
              if (got != golden_postprocessed(
                  out_y, out_x, c, group_idx, 0))
                $fatal(1,
                    "CORE CONV data c=%0d y=%0d x=%0d got=%0d exp=%0d",
                    c, out_y, out_x, got,
                    golden_postprocessed(out_y, out_x, c, group_idx, 0));
              conv_seen[c][out_y][out_x] = 1'b1;
              operation_lane_count++;
              total_lane_count++;
            end
            if (bank_wstrb[c][1]) begin
              got = $signed(bank_wdata[c][15:8]);
              if ((out_x + 1 >= CONV_OUT_W) ||
                  conv_seen[c][out_y][out_x + 1])
                $fatal(1, "CORE CONV illegal high c=%0d y=%0d x=%0d",
                       c, out_y, out_x + 1);
              if (got != golden_postprocessed(
                  out_y, out_x + 1, c, group_idx, 1))
                $fatal(1,
                    "CORE CONV data c=%0d y=%0d x=%0d got=%0d exp=%0d",
                    c, out_y, out_x + 1, got,
                    golden_postprocessed(
                        out_y, out_x + 1, c, group_idx, 1));
              conv_seen[c][out_y][out_x + 1] = 1'b1;
              operation_lane_count++;
              total_lane_count++;
            end
          end
        end
      end
    end
  end

  task automatic preload_weights;
    begin
      for (int k = 0; k < CONV_DEPTH; k++) begin
        @(negedge clk);
        weight_wr_addr = WGT_ADDR_W'(k);
        for (int c = 0; c < NC; c++) begin
          weight_wr_en[c] = 1'b1;
          weight_wr_data[c] = '0;
          weight_wr_data[c][7:0] =
              DATA_W'(golden_weight(k, c));
        end
      end
      for (int k = 0; k < FC_DEPTH; k++) begin
        @(negedge clk);
        weight_wr_addr = WGT_ADDR_W'(FC_WEIGHT_BASE + k);
        for (int c = 0; c < NC; c++) begin
          weight_wr_en[c] = 1'b1;
          for (int g = 0; g < NG; g++) begin
            int filter_lo;
            filter_lo = g * (2 * NC) + 2 * c;
            weight_wr_data[c][(2*g)*DATA_W +: DATA_W] =
                DATA_W'(fc_golden_weight(filter_lo, k));
            weight_wr_data[c][(2*g+1)*DATA_W +: DATA_W] =
                DATA_W'(fc_golden_weight(filter_lo + 1, k));
          end
        end
      end
      @(negedge clk);
      for (int c = 0; c < NC; c++) weight_wr_en[c] = 1'b0;
      repeat (2) @(negedge clk);
    end
  endtask

  task automatic load_conv_params;
    begin
      for (int g = 0; g < NG; g++)
        for (int c = 0; c < NC; c++)
          for (int lane = 0; lane < 2; lane++) begin
            @(negedge clk);
            param_wr_en = 1'b1;
            param_wr_lane = g * 2 * NC + 2 * c + lane;
            param_wr_bias = golden_bias(g, c, lane);
            param_wr_scale = golden_scale(g, c, lane);
          end
      @(negedge clk);
      param_wr_en = 1'b0;
    end
  endtask

  task automatic load_fc_params;
    begin
      for (int g = 0; g < NG; g++)
        for (int c = 0; c < NC; c++)
          for (int lane = 0; lane < 2; lane++) begin
            int filter;
            filter = g * 2 * NC + 2 * c + lane;
            @(negedge clk);
            param_wr_en = 1'b1;
            param_wr_lane = filter;
            param_wr_bias = fc_golden_bias(filter);
            param_wr_scale = fc_golden_scale(filter);
          end
      @(negedge clk);
      param_wr_en = 1'b0;
    end
  endtask

  task automatic wait_job(input int expected_lanes);
    begin
      for (int guard = 0; guard < 20000 && !done; guard++) begin
        if (random_stalls) begin
          en = ($urandom_range(0, 9) != 0);
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
      if (!done)
        $fatal(1, "CORE timeout mode_fc=%0d lanes=%0d pix=%0d",
               active_mode_fc, operation_lane_count, pix_index);
      if (operation_lane_count != expected_lanes)
        $fatal(1, "CORE lane count mode_fc=%0d got=%0d exp=%0d",
               active_mode_fc, operation_lane_count, expected_lanes);
      @(negedge clk);
      if (done) $fatal(1, "CORE done not pulse");
    end
  endtask

  task automatic run_conv;
    begin
      load_conv_params();
      @(negedge clk);
      active_mode_fc = 1'b0;
      operation_lane_count = 0;
      cfg_fc_mode = 1'b0;
      cfg_fmap_w = DIM_W'(CONV_W);
      cfg_fmap_h = DIM_W'(CONV_H);
      cfg_c_in = C_W'(CONV_C);
      cfg_out_w = DIM_W'(CONV_OUT_W);
      cfg_out_h = DIM_W'(CONV_OUT_H);
      cfg_depth = KOUT_W'(CONV_DEPTH);
      weight_read_base = '0;
      out_plane_size = OUT_ADDR_W'(CONV_OUT_W * CONV_OUT_H);
      out_ch_base = '0;
      out_channels = OUT_CH_W'(NC);
      pass_channels = OUT_CH_W'(NC);
      layer_id = '0;
      cfg_bank_base_word = '0;
      relu_en = 1'b1;
      en = 1'b1;
      for (int c = 0; c < NC; c++) bank_ready[c] = 1'b1;
      start = 1'b1;
      @(negedge clk);
      start = 1'b0;
      wait_job(CONV_OUT_W * CONV_OUT_H * NC);
      if (pix_index != CONV_W * CONV_H * CONV_C)
        $fatal(1, "CORE CONV pixels got=%0d", pix_index);
      $display("CORE CONV PASSED lanes=%0d", operation_lane_count);
    end
  endtask

  task automatic run_fc;
    begin
      load_fc_params();
      @(negedge clk);
      active_mode_fc = 1'b1;
      operation_lane_count = 0;
      cfg_fc_mode = 1'b1;
      cfg_fmap_w = '0;
      cfg_fmap_h = '0;
      cfg_c_in = '0;
      cfg_out_w = DIM_W'(1);
      cfg_out_h = DIM_W'(1);
      cfg_depth = KOUT_W'(FC_DEPTH);
      weight_read_base = WGT_ADDR_W'(FC_WEIGHT_BASE);
      out_plane_size = 1;
      out_ch_base = '0;
      out_channels = OUT_CH_W'(FC_OUTPUTS);
      pass_channels = OUT_CH_W'(FC_OUTPUTS);
      layer_id = 5;
      cfg_bank_base_word = BANK_ADDR_W'(FC_BANK_BASE);
      relu_en = 1'b1;
      en = 1'b1;
      for (int c = 0; c < NC; c++) bank_ready[c] = 1'b1;
      start = 1'b1;
      @(negedge clk);
      start = 1'b0;
      wait_job(FC_OUTPUTS);
      if (pix_index != FC_DEPTH)
        $fatal(1, "CORE FC pixels got=%0d", pix_index);
      $display("CORE FC PASSED lanes=%0d", operation_lane_count);
    end
  endtask

  initial begin
    int ignored;
    clk = 1'bx;
    rst_n = 1'bx;
    en = 1'bx;
    start = 1'bx;
    cfg_fc_mode = 1'bx;
    cfg_fmap_w = 'x;
    cfg_fmap_h = 'x;
    cfg_c_in = 'x;
    cfg_out_w = 'x;
    cfg_out_h = 'x;
    cfg_depth = 'x;
    weight_wr_addr = 'x;
    weight_read_base = 'x;
    out_base_addr = 'x;
    out_plane_size = 'x;
    out_ch_base = 'x;
    out_channels = 'x;
    pass_channels = 'x;
    layer_id = 'x;
    param_wr_en = 1'bx;
    param_wr_lane = 'x;
    param_wr_bias = 'x;
    param_wr_scale = 'x;
    relu_en = 1'bx;
    cfg_bank_base_word = 'x;
    for (int c = 0; c < NC; c++) begin
      weight_wr_en[c] = 1'bx;
      weight_wr_data[c] = 'x;
      bank_ready[c] = 1'bx;
    end
    for (int c = 0; c < NC; c++)
      for (int y = 0; y < CONV_OUT_H; y++)
        for (int x = 0; x < CONV_OUT_W; x++)
          conv_seen[c][y][x] = 1'b0;
    for (int f = 0; f < FC_OUTPUTS; f++) fc_seen[f] = 1'b0;
    active_mode_fc = 1'b0;
    operation_lane_count = 0;
    total_lane_count = 0;
    random_stalls = 0;
    seed = 20260724;
    ignored = $value$plusargs("SEED=%d", seed);
    ignored = $value$plusargs("RANDOM_STALLS=%d", random_stalls);
    ignored = $urandom(seed);
    $display("LENET_CORE seed=%0d random_stalls=%0d",
             seed, random_stalls);

    #2;
    clk = 1'b0;
    rst_n = 1'b0;
    en = 1'b0;
    start = 1'b0;
    cfg_fc_mode = 1'b0;
    cfg_fmap_w = '0;
    cfg_fmap_h = '0;
    cfg_c_in = '0;
    cfg_out_w = '0;
    cfg_out_h = '0;
    cfg_depth = '0;
    weight_wr_addr = '0;
    weight_read_base = '0;
    out_base_addr = 0;
    out_plane_size = '0;
    out_ch_base = '0;
    out_channels = '0;
    pass_channels = '0;
    layer_id = '0;
    param_wr_en = 1'b0;
    param_wr_lane = '0;
    param_wr_bias = '0;
    param_wr_scale = '0;
    relu_en = 1'b0;
    cfg_bank_base_word = '0;
    for (int c = 0; c < NC; c++) begin
      weight_wr_en[c] = 1'b0;
      weight_wr_data[c] = '0;
      bank_ready[c] = 1'b0;
    end
    repeat (4) @(negedge clk);
    rst_n = 1'b1;
    @(posedge clk);
    #1;
    if ($isunknown({busy, done, pix_rd_en}))
      $fatal(1, "CORE XPROP after reset");

    preload_weights();
    run_conv();
    run_fc();

    for (int c = 0; c < NC; c++)
      for (int y = 0; y < CONV_OUT_H; y++)
        for (int x = 0; x < CONV_OUT_W; x++)
          if (!conv_seen[c][y][x])
            $fatal(1, "CORE missing conv c=%0d y=%0d x=%0d", c, y, x);
    for (int f = 0; f < FC_OUTPUTS; f++)
      if (!fc_seen[f]) $fatal(1, "CORE missing fc=%0d", f);
    if (total_lane_count != CONV_OUT_W * CONV_OUT_H * NC + FC_OUTPUTS)
      $fatal(1, "CORE total lanes got=%0d", total_lane_count);
    $display("LENET_COMPUTE_CORE TEST PASSED total_lanes=%0d",
             total_lane_count);
    $finish;
  end

endmodule
