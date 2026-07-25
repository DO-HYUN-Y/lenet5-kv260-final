// tb_weight_loader.sv -- self-checking-by-external-diff testbench for
// weight_loader.sv
//
// weight_loader is tested standalone (window_gen NOT instantiated): it
// replays window_gen's own already-verified golden trace
// (../golden/wgen_golden_out.txt, 769 lines) as direct stimulus into
// weight_loader's k_out/pair_valid[0]/depth_last[0] ports, exactly like
// golden/weight_loader_golden.c does. The 8 banks are preloaded through the
// DUT's own wr_en/wr_addr/wr_data write port from
// ../golden/wload_stim_weights.txt (8 rows x MEM_DEPTH cols).
//
// Output correspondence (matches weight_loader_golden.c's registered-latency
// bookkeeping exactly): log line 0 = reset state (no input presented yet,
// all-zero/invalid). Log line i+1 (i=0..768) = DUT output sampled right
// after the edge that captured input line i. Total = 1 + 769 = 770 lines,
// diffed against ../golden/wload_golden_out.txt.

`timescale 1ns/1ps

module tb_weight_loader;

  localparam int ACT_W     = 8;
  localparam int NC        = 8;
  localparam int K         = 5;
  localparam int C_IN      = 2;
  localparam int DEPTH     = K * K * C_IN;
  localparam int MEM_DEPTH = 200;
  localparam int ADDR_W    = $clog2(MEM_DEPTH);
  localparam int KOUT_W    = $clog2(K*K*C_IN);
  localparam int NG        = 4;
  localparam int N_LINES   = 769;
  localparam int BASE_LAYER = 37;
  localparam int PASS_IDX   = 1;

  logic clk, rst_n, en;
  logic                    wr_en;
  logic [ADDR_W-1:0]       wr_addr;
  logic signed [ACT_W-1:0] wr_data [0:NC-1];
  logic                    k_valid;
  logic [KOUT_W-1:0]       k_out;
  logic                    depth_last_in;
  logic [ADDR_W-1:0]       base_layer;
  logic [ADDR_W-1:0]       pass_idx;
  logic signed [ACT_W-1:0] wgt_q [0:NC-1];
  logic                    wgt_valid;
  logic                    wgt_depth_last;
  logic [KOUT_W-1:0]       wgt_k_out;

  weight_loader #(
    .ACT_W(ACT_W), .NC(NC), .K(K), .C_IN(C_IN),
    .DEPTH(DEPTH), .MEM_DEPTH(MEM_DEPTH)
  ) dut (.*);

  always #5 clk = ~clk;

  int wmem [0:NC-1][0:MEM_DEPTH-1];
  int rtl_fd;
  int cycles_logged;

  task automatic log_output();
    int c;
    for (c = 0; c < NC; c++) $fwrite(rtl_fd, "%0d ", wgt_q[c]);
    $fwrite(rtl_fd, "%0d %0d\n", wgt_valid, wgt_depth_last);
  endtask

  initial begin
    int fd;
    int nc_f, depth_f;
    int c, a;
    int win_d, pv_d, lm_d, dl_d, kout_v, pv0_v, dl0_v;
    int i;

    clk           = 0;
    rst_n         = 0;
    en            = 1'b1;
    wr_en         = 0;
    wr_addr       = '0;
    k_valid       = 0;
    k_out         = '0;
    depth_last_in = 0;
    base_layer    = BASE_LAYER[ADDR_W-1:0];
    pass_idx      = PASS_IDX[ADDR_W-1:0];
    cycles_logged = 0;
    for (c = 0; c < NC; c++) wr_data[c] = '0;

    // -- load weight preload image --
    fd = $fopen("../golden/wload_stim_weights.txt", "r");
    if (fd == 0) begin
      $display("FAIL: could not open ../golden/wload_stim_weights.txt");
      $finish;
    end
    void'($fscanf(fd, "%d %d", nc_f, depth_f));
    if (nc_f !== NC || depth_f !== MEM_DEPTH) begin
      $display("FAIL: wload_stim_weights.txt header mismatch (%0d %0d)", nc_f, depth_f);
      $finish;
    end
    for (c = 0; c < NC; c++)
      for (a = 0; a < MEM_DEPTH; a++)
        void'($fscanf(fd, "%d", wmem[c][a]));
    $fclose(fd);

    rtl_fd = $fopen("wload_rtl_out.txt", "w");
    if (rtl_fd == 0) begin
      $display("FAIL: could not open wload_rtl_out.txt");
      $finish;
    end

    repeat (4) @(negedge clk);
    rst_n = 1;
    @(negedge clk);

    // -- preload 8 banks via DUT's own write port --
    for (a = 0; a < MEM_DEPTH; a++) begin
      wr_en   = 1;
      wr_addr = a[ADDR_W-1:0];
      for (c = 0; c < NC; c++) wr_data[c] = wmem[c][a];
      @(negedge clk);
    end
    wr_en = 0;

    // -- log line 0: reset state, no compute input presented yet --
    @(posedge clk);
    #1;
    log_output();
    cycles_logged++;

    // -- replay window_gen's golden trace as k_out/pair_valid/depth_last stream --
    fd = $fopen("../golden/wgen_golden_out.txt", "r");
    if (fd == 0) begin
      $display("FAIL: could not open ../golden/wgen_golden_out.txt");
      $finish;
    end
    for (i = 0; i < N_LINES; i++) begin
      for (int j = 0; j < 2*NG; j++) void'($fscanf(fd, "%d", win_d));
      void'($fscanf(fd, "%d", pv0_v));
      for (int j = 1; j < NG; j++)   void'($fscanf(fd, "%d", pv_d));
      for (int j = 0; j < NG; j++)   void'($fscanf(fd, "%d", lm_d));
      void'($fscanf(fd, "%d", dl0_v));
      for (int j = 1; j < NG; j++)   void'($fscanf(fd, "%d", dl_d));
      void'($fscanf(fd, "%d", kout_v));

      k_valid       = pv0_v[0];
      k_out         = kout_v[KOUT_W-1:0];
      depth_last_in = dl0_v[0];

      @(posedge clk);
      #1;
      log_output();
      cycles_logged++;
    end
    $fclose(fd);

    $display("WEIGHT_LOADER_SIM_DONE: %0d cycles logged to wload_rtl_out.txt", cycles_logged);
    $fclose(rtl_fd);
    $finish;
  end

endmodule
