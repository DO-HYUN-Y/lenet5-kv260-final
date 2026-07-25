`timescale 1ns/1ps

module tb_fc_stream_datapath;
  localparam int DATA_W = 8;
  localparam int ACC_W = 32;
  localparam int NG = 4;
  localparam int NC = 8;
  localparam int MEM_DEPTH = 128;
  localparam int WGT_ADDR_W = $clog2(MEM_DEPTH);
  localparam int KOUT_W = 6;
  localparam int OUT_ADDR_W = 16;
  localparam int OUT_CH_W = 8;
  localparam int LAYER_ID_W = 3;
  localparam int BANK_ADDR_W = 9;
  localparam int FC_DEPTH = 23;
  localparam int TOTAL_OUTPUTS = 70;
  localparam int WEIGHT_BASE = 10;
  localparam int OUT_BASE = 1000;
  localparam int TEST_LAYER = 5;

  import "DPI-C" function int fc_golden_activation(input int k);
  import "DPI-C" function int fc_golden_weight(
      input int filter, input int k);
  import "DPI-C" function int fc_golden_sum(input int filter);
  import "DPI-C" function int fc_golden_bias(input int filter);
  import "DPI-C" function int fc_golden_scale(input int filter);
  import "DPI-C" function int fc_golden_postprocessed(
      input int filter, input int relu_en);

  logic clk;
  logic rst_n;
  logic en;
  logic start;
  logic signed [DATA_W-1:0] pix_in;
  logic pix_valid;
  logic pix_rd_en;
  logic weight_wr_en [0:NC-1];
  logic [WGT_ADDR_W-1:0] weight_wr_addr;
  logic [2*NG*DATA_W-1:0] weight_wr_data [0:NC-1];
  logic [WGT_ADDR_W-1:0] weight_read_base;
  logic [KOUT_W-1:0] cfg_depth;
  logic [OUT_ADDR_W-1:0] out_base_addr;
  logic [OUT_CH_W-1:0] out_ch_base;
  logic [OUT_CH_W-1:0] out_channels;
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
  logic busy;
  logic done;

  int pix_index;
  int active_pass_base;
  int active_bank_base;
  int observed_lanes;
  int observed_acc_lanes;
  bit result_seen [0:TOTAL_OUTPUTS-1];
  int seed;
  int random_stalls;

  fc_stream_datapath #(
    .DATA_W(DATA_W), .ACC_W(ACC_W), .NG(NG), .NC(NC),
    .MEM_DEPTH(MEM_DEPTH), .WGT_ADDR_W(WGT_ADDR_W),
    .KOUT_W(KOUT_W), .OUT_ADDR_W(OUT_ADDR_W),
    .OUT_CH_W(OUT_CH_W), .LAYER_ID_W(LAYER_ID_W),
    .BANK_ADDR_W(BANK_ADDR_W)
  ) dut (.*);

  always #5 clk = ~clk;

  always_comb begin
    pix_in = DATA_W'(fc_golden_activation(pix_index));
    pix_valid = busy || start;
  end

  always_ff @(posedge clk) begin
    if (!rst_n || start)
      pix_index <= 0;
    else if (pix_rd_en)
      pix_index <= pix_index + 1;
  end

  always @(posedge clk) begin
    bit advance_before;
    advance_before = dut.pipe_en;

    if (rst_n) begin
      for (int c = 0; c < NC; c++) begin
        if (bank_we[c]) begin
          int group_idx;
          int filter_lo;
          int got;
          group_idx = bank_word_addr[c] - active_bank_base;
          filter_lo = active_pass_base + group_idx * (2 * NC) + 2 * c;
          if ((group_idx < 0) || (group_idx >= NG))
            $fatal(1, "FC bank address c=%0d addr=%0d base=%0d",
                   c, bank_word_addr[c], active_bank_base);
          if (bank_wstrb[c][0]) begin
            got = $signed(bank_wdata[c][7:0]);
            if (filter_lo >= TOTAL_OUTPUTS)
              $fatal(1, "FC illegal low filter=%0d", filter_lo);
            if (result_seen[filter_lo])
              $fatal(1, "FC duplicate filter=%0d", filter_lo);
            if (got != fc_golden_postprocessed(filter_lo, 1))
              $fatal(1, "FC post filter=%0d got=%0d exp=%0d",
                     filter_lo, got,
                     fc_golden_postprocessed(filter_lo, 1));
            result_seen[filter_lo] = 1'b1;
            observed_lanes++;
          end
          if (bank_wstrb[c][1]) begin
            got = $signed(bank_wdata[c][15:8]);
            if (filter_lo + 1 >= TOTAL_OUTPUTS)
              $fatal(1, "FC illegal high filter=%0d", filter_lo + 1);
            if (result_seen[filter_lo + 1])
              $fatal(1, "FC duplicate filter=%0d", filter_lo + 1);
            if (got != fc_golden_postprocessed(filter_lo + 1, 1))
              $fatal(1, "FC post filter=%0d got=%0d exp=%0d",
                     filter_lo + 1, got,
                     fc_golden_postprocessed(filter_lo + 1, 1));
            result_seen[filter_lo + 1] = 1'b1;
            observed_lanes++;
          end
        end
      end
    end

    if (rst_n) begin
      #1;
      if (advance_before) begin
        for (int g = 0; g < NG; g++) begin
          for (int c = 0; c < NC; c++) begin
            int filter_lo;
            filter_lo = active_pass_base + g * (2 * NC) + 2 * c;
            if (dut.acc_valid[g][c][0]) begin
              if (filter_lo >= TOTAL_OUTPUTS)
                $fatal(1, "FC acc invalid low filter=%0d", filter_lo);
              if ($signed(dut.acc_lo[g][c]) !== fc_golden_sum(filter_lo))
                $fatal(1, "FC acc low filter=%0d got=%0d exp=%0d",
                       filter_lo, $signed(dut.acc_lo[g][c]),
                       fc_golden_sum(filter_lo));
              observed_acc_lanes++;
            end
            if (dut.acc_valid[g][c][1]) begin
              if (filter_lo + 1 >= TOTAL_OUTPUTS)
                $fatal(1, "FC acc invalid high filter=%0d", filter_lo + 1);
              if ($signed(dut.acc_hi[g][c]) !==
                  fc_golden_sum(filter_lo + 1))
                $fatal(1, "FC acc high filter=%0d got=%0d exp=%0d",
                       filter_lo + 1, $signed(dut.acc_hi[g][c]),
                       fc_golden_sum(filter_lo + 1));
              observed_acc_lanes++;
            end
          end
        end
      end
    end
  end

  task automatic preload_weights;
    begin
      for (int pass = 0; pass < 2; pass++) begin
        for (int k = 0; k < FC_DEPTH; k++) begin
          @(negedge clk);
          weight_wr_addr =
              WGT_ADDR_W'(WEIGHT_BASE + pass * FC_DEPTH + k);
          for (int c = 0; c < NC; c++) begin
            weight_wr_en[c] = 1'b1;
            for (int g = 0; g < NG; g++) begin
              int filter_lo;
              filter_lo = pass * 64 + g * (2 * NC) + 2 * c;
              weight_wr_data[c][(2*g)*DATA_W +: DATA_W] =
                  DATA_W'(fc_golden_weight(filter_lo, k));
              weight_wr_data[c][(2*g+1)*DATA_W +: DATA_W] =
                  DATA_W'(fc_golden_weight(filter_lo + 1, k));
            end
          end
        end
      end
      @(negedge clk);
      for (int c = 0; c < NC; c++) weight_wr_en[c] = 1'b0;
      repeat (2) @(negedge clk);
    end
  endtask

  task automatic load_params(input int pass_base);
    begin
      for (int g = 0; g < NG; g++) begin
        for (int c = 0; c < NC; c++) begin
          for (int lane = 0; lane < 2; lane++) begin
            int physical_lane;
            int filter;
            physical_lane = g * 2 * NC + 2 * c + lane;
            filter = pass_base + physical_lane;
            @(negedge clk);
            param_wr_en = 1'b1;
            param_wr_lane = physical_lane;
            param_wr_bias = fc_golden_bias(filter);
            param_wr_scale = fc_golden_scale(filter);
          end
        end
      end
      @(negedge clk);
      param_wr_en = 1'b0;
    end
  endtask

  task automatic run_pass(input int pass);
    int expected_lanes;
    begin
      active_pass_base = pass * 64;
      active_bank_base = pass * NG;
      expected_lanes =
          ((TOTAL_OUTPUTS - active_pass_base) > 64) ?
          64 : (TOTAL_OUTPUTS - active_pass_base);
      load_params(active_pass_base);
      @(negedge clk);
      weight_read_base =
          WGT_ADDR_W'(WEIGHT_BASE + pass * FC_DEPTH);
      out_ch_base = OUT_CH_W'(active_pass_base);
      cfg_bank_base_word = BANK_ADDR_W'(active_bank_base);
      for (int c = 0; c < NC; c++) bank_ready[c] = 1'b1;
      en = 1'b1;
      start = 1'b1;
      @(negedge clk);
      start = 1'b0;

      for (int guard = 0; guard < 2000 && !done; guard++) begin
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
        $fatal(1, "FC timeout pass=%0d pix=%0d lanes=%0d",
               pass, pix_index, observed_lanes);
      if (pix_index != FC_DEPTH)
        $fatal(1, "FC pixel count pass=%0d got=%0d exp=%0d",
               pass, pix_index, FC_DEPTH);
      @(negedge clk);
      if (done)
        $fatal(1, "FC done not pulse pass=%0d", pass);
      $display("FC PASS PASSED pass=%0d outputs=%0d", pass,
               expected_lanes);
    end
  endtask

  initial begin
    int ignored;
    clk = 1'bx;
    rst_n = 1'bx;
    en = 1'bx;
    start = 1'bx;
    weight_wr_addr = 'x;
    weight_read_base = 'x;
    cfg_depth = 'x;
    out_base_addr = 'x;
    out_ch_base = 'x;
    out_channels = 'x;
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
    for (int f = 0; f < TOTAL_OUTPUTS; f++) result_seen[f] = 1'b0;
    active_pass_base = 0;
    active_bank_base = 0;
    observed_lanes = 0;
    observed_acc_lanes = 0;
    seed = 20260724;
    random_stalls = 0;
    ignored = $value$plusargs("SEED=%d", seed);
    ignored = $value$plusargs("RANDOM_STALLS=%d", random_stalls);
    ignored = $urandom(seed);
    $display("FC_STREAM seed=%0d random_stalls=%0d",
             seed, random_stalls);

    #2;
    clk = 1'b0;
    rst_n = 1'b0;
    en = 1'b0;
    start = 1'b0;
    weight_wr_addr = '0;
    weight_read_base = '0;
    cfg_depth = KOUT_W'(FC_DEPTH);
    out_base_addr = OUT_ADDR_W'(OUT_BASE);
    out_ch_base = '0;
    out_channels = OUT_CH_W'(TOTAL_OUTPUTS);
    layer_id = LAYER_ID_W'(TEST_LAYER);
    param_wr_en = 1'b0;
    param_wr_lane = '0;
    param_wr_bias = '0;
    param_wr_scale = '0;
    relu_en = 1'b1;
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
      $fatal(1, "FC XPROP visible control unknown after reset");

    preload_weights();
    run_pass(0);
    run_pass(1);

    if (observed_lanes != TOTAL_OUTPUTS)
      $fatal(1, "FC output lanes got=%0d exp=%0d",
             observed_lanes, TOTAL_OUTPUTS);
    if (observed_acc_lanes != TOTAL_OUTPUTS)
      $fatal(1, "FC acc lanes got=%0d exp=%0d",
             observed_acc_lanes, TOTAL_OUTPUTS);
    for (int f = 0; f < TOTAL_OUTPUTS; f++)
      if (!result_seen[f]) $fatal(1, "FC missing filter=%0d", f);
    $display(
        "FC_STREAM_DATAPATH TEST PASSED outputs=%0d acc_lanes=%0d",
        observed_lanes, observed_acc_lanes);
    $finish;
  end

endmodule
