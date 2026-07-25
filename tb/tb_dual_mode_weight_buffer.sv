`timescale 1ns/1ps

module tb_dual_mode_weight_buffer;
  localparam int WGT_W = 8;
  localparam int NG = 4;
  localparam int NC = 8;
  localparam int WORD_W = 64;
  localparam int MEM_DEPTH = 256;
  localparam int ADDR_W = $clog2(MEM_DEPTH);
  localparam int KOUT_W = 8;
  localparam int READ_BASE = 37;
  localparam int READ_DEPTH = 100;

  import "DPI-C" function int dual_weight_golden(
      input int address, input int bank, input int byte_lane);

  logic clk;
  logic rst_n;
  logic en;
  logic wr_en [0:NC-1];
  logic [ADDR_W-1:0] wr_addr;
  logic [WORD_W-1:0] wr_data [0:NC-1];
  logic k_valid;
  logic [KOUT_W-1:0] k_out;
  logic depth_last_in;
  logic [ADDR_W-1:0] read_base_addr;
  logic signed [WGT_W-1:0] conv_weight [0:NC-1];
  logic signed [WGT_W-1:0] fc_weight_lo [0:NG-1][0:NC-1];
  logic signed [WGT_W-1:0] fc_weight_hi [0:NG-1][0:NC-1];
  logic weight_valid;
  logic weight_depth_last;
  logic [KOUT_W-1:0] weight_k_out;

  int expected_k_q [0:READ_DEPTH+8];
  int q_head;
  int q_tail;
  int accepted_count;
  int observed_count;

  dual_mode_weight_buffer #(
    .WGT_W(WGT_W), .NG(NG), .NC(NC), .WORD_W(WORD_W),
    .MEM_DEPTH(MEM_DEPTH), .ADDR_W(ADDR_W), .KOUT_W(KOUT_W)
  ) dut (.*);

  always #5 clk = ~clk;

  always @(posedge clk) begin
    if (rst_n && en && weight_valid) begin
      int expected_k;
      if (q_head >= q_tail)
        $fatal(1, "DUAL_WEIGHT output without expected token");
      expected_k = expected_k_q[q_head];
      if (weight_k_out !== KOUT_W'(expected_k))
        $fatal(1, "DUAL_WEIGHT tag got=%0d exp=%0d",
               weight_k_out, expected_k);
      if (weight_depth_last !== (expected_k == READ_DEPTH - 1))
        $fatal(1, "DUAL_WEIGHT last k=%0d got=%0b",
               expected_k, weight_depth_last);
      for (int c = 0; c < NC; c++) begin
        if ($signed(conv_weight[c]) !==
            dual_weight_golden(READ_BASE + expected_k, c, 0))
          $fatal(1, "DUAL_WEIGHT conv k=%0d c=%0d got=%0d exp=%0d",
                 expected_k, c, $signed(conv_weight[c]),
                 dual_weight_golden(READ_BASE + expected_k, c, 0));
        for (int g = 0; g < NG; g++) begin
          if ($signed(fc_weight_lo[g][c]) !==
              dual_weight_golden(READ_BASE + expected_k, c, 2*g))
            $fatal(1, "DUAL_WEIGHT fc_lo k=%0d g=%0d c=%0d",
                   expected_k, g, c);
          if ($signed(fc_weight_hi[g][c]) !==
              dual_weight_golden(READ_BASE + expected_k, c, 2*g+1))
            $fatal(1, "DUAL_WEIGHT fc_hi k=%0d g=%0d c=%0d",
                   expected_k, g, c);
        end
      end
      q_head = q_head + 1;
      observed_count = observed_count + 1;
    end

    if (rst_n && en && k_valid) begin
      expected_k_q[q_tail] = k_out;
      q_tail = q_tail + 1;
      accepted_count = accepted_count + 1;
    end
  end

  initial begin
    int seed;
    int ignored;

    clk = 1'bx;
    rst_n = 1'bx;
    en = 1'bx;
    wr_addr = 'x;
    k_valid = 1'bx;
    k_out = 'x;
    depth_last_in = 1'bx;
    read_base_addr = 'x;
    for (int c = 0; c < NC; c++) begin
      wr_en[c] = 1'bx;
      wr_data[c] = 'x;
    end
    q_head = 0;
    q_tail = 0;
    accepted_count = 0;
    observed_count = 0;
    seed = 20260724;
    ignored = $value$plusargs("SEED=%d", seed);
    ignored = $urandom(seed);
    $display("DUAL_WEIGHT seed=%0d", seed);

    #2;
    clk = 1'b0;
    rst_n = 1'b0;
    en = 1'b0;
    wr_addr = '0;
    k_valid = 1'b0;
    k_out = '0;
    depth_last_in = 1'b0;
    read_base_addr = ADDR_W'(READ_BASE);
    for (int c = 0; c < NC; c++) begin
      wr_en[c] = 1'b0;
      wr_data[c] = '0;
    end
    repeat (4) @(negedge clk);
    rst_n = 1'b1;
    @(posedge clk);
    #1;
    if ($isunknown({weight_valid, weight_depth_last, weight_k_out}))
      $fatal(1, "DUAL_WEIGHT XPROP output unknown after reset");

    for (int a = READ_BASE; a < READ_BASE + READ_DEPTH; a++) begin
      @(negedge clk);
      wr_addr = ADDR_W'(a);
      for (int c = 0; c < NC; c++) begin
        wr_en[c] = 1'b1;
        for (int byte_lane = 0; byte_lane < 2 * NG; byte_lane++)
          wr_data[c][byte_lane*WGT_W +: WGT_W] =
              WGT_W'(dual_weight_golden(a, c, byte_lane));
      end
    end
    @(negedge clk);
    for (int c = 0; c < NC; c++) wr_en[c] = 1'b0;
    repeat (2) @(negedge clk);

    for (int k = 0; k < READ_DEPTH; k++) begin
      @(negedge clk);
      k_valid = 1'b1;
      k_out = KOUT_W'(k);
      depth_last_in = (k == READ_DEPTH - 1);
      en = ($urandom_range(0, 3) != 0);
      @(posedge clk);
      while (!en) begin
        @(negedge clk);
        en = ($urandom_range(0, 3) != 0);
        @(posedge clk);
      end
    end
    @(negedge clk);
    k_valid = 1'b0;
    depth_last_in = 1'b0;
    en = 1'b1;
    for (int guard = 0; guard < 20 && q_head != q_tail; guard++)
      @(negedge clk);
    if (q_head != q_tail)
      $fatal(1, "DUAL_WEIGHT drain head=%0d tail=%0d", q_head, q_tail);
    if (accepted_count != READ_DEPTH || observed_count != READ_DEPTH)
      $fatal(1, "DUAL_WEIGHT counts accepted=%0d observed=%0d",
             accepted_count, observed_count);
    $display("DUAL_MODE_WEIGHT_BUFFER TEST PASSED tokens=%0d",
             observed_count);
    $finish;
  end

endmodule
