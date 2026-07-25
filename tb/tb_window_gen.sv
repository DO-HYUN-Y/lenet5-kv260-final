// tb_window_gen.sv -- self-checking-by-external-diff testbench for window_gen.sv
//
// window_gen has no randomized stimulus of its own: golden/window_gen_golden.c
// generates a fixed synthetic image (hand-picked to exercise every row_zero
// skip count 0..5, lane_mask boundary, and input-overrun zero-forcing) and
// writes it to wgen_stim_img.txt. This TB preloads that exact image into a
// synchronous-read pix_mem, pulses start once, and logs the DUT's
// win_q/pair_valid/lane_mask/depth_last/k_out every cycle window_gen spends
// in {S_LOAD, S_LOAD_DRAIN, S_COMPUTE} -- matching golden's own logging
// window exactly (it stops before S_DRAIN/S_DONE, which golden doesn't
// model at all). wgen_rtl_out.txt is then diffed line-for-line against
// wgen_golden_out.txt; that diff is the pass/fail gate, not anything inside
// this file.

`timescale 1ns/1ps

module tb_window_gen;

  localparam int NG     = 4;
  localparam int C_IN   = 2;
  localparam int FMAP_W = 13;
  localparam int FMAP_H = 13;
  localparam int K      = 5;
  localparam int OUT_W  = 9;
  localparam int OUT_H  = 9;
  localparam int KOUT_W = $clog2(K*K*C_IN);
  localparam int NPIX   = C_IN * FMAP_W * FMAP_H;

  logic clk, rst_n, en, start;
  logic signed [7:0] pix_in;
  logic pix_rd_en;
  logic signed [7:0] win_q      [0:2*NG-1];
  logic              pair_valid [0:NG-1];
  logic [1:0]        lane_mask  [0:NG-1];
  logic              depth_last [0:NG-1];
  logic [KOUT_W-1:0] k_out;
  logic              done;

  window_gen dut (.*);

  always #5 clk = ~clk;

  // -- pix_mem: exact preload of wgen_stim_img.txt, synchronous read gated
  // by pix_rd_en (1 pixel/cycle, no bubble, matching golden's load
  // assumption). File order (row-major, ch-major/col-minor within a row)
  // is already the exact consumption order window_gen's S_LOAD walks. --
  logic signed [7:0] pix_mem [0:NPIX-1];
  logic [$clog2(NPIX)-1:0] pix_idx_r;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) pix_idx_r <= '0;
    else if (pix_rd_en) pix_idx_r <= pix_idx_r + 1'b1;
  end
  assign pix_in = pix_mem[pix_idx_r];

  int rtl_fd;
  int cycles_logged;

  task automatic log_output();
    int i;
    for (i = 0; i < 2*NG; i++) $fwrite(rtl_fd, "%0d ", win_q[i]);
    for (i = 0; i < NG; i++)   $fwrite(rtl_fd, "%0d ", pair_valid[i]);
    for (i = 0; i < NG; i++)   $fwrite(rtl_fd, "%0d ", lane_mask[i]);
    for (i = 0; i < NG; i++)   $fwrite(rtl_fd, "%0d ", depth_last[i]);
    $fwrite(rtl_fd, "%0d\n", k_out);
  endtask

  // Sample 1ns after the edge that produced this cycle's state_r, matching
  // tb_skew_buf.sv's convention (let NBA + always_comb settle first).
  always @(posedge clk) begin
    if (rst_n) begin
      #1;
      if (dut.state_r == dut.S_LOAD || dut.state_r == dut.S_LOAD_DRAIN ||
          dut.state_r == dut.S_COMPUTE) begin
        log_output();
        cycles_logged++;
      end
    end
  end

  initial begin
    int fd;
    int c_in_f, fmap_w_f, fmap_h_f, out_w_f, out_h_f;
    int pv;
    int r, ch, c, idx;
    int cyc, timeout_cycles;

    clk   = 0;
    rst_n = 0;
    en    = 1'b1;
    start = 0;
    cycles_logged = 0;

    fd = $fopen("../golden/wgen_stim_img.txt", "r");
    if (fd == 0) begin
      $display("FAIL: could not open ../golden/wgen_stim_img.txt");
      $finish;
    end
    void'($fscanf(fd, "%d %d %d %d %d", c_in_f, fmap_w_f, fmap_h_f, out_w_f, out_h_f));
    if (c_in_f !== C_IN || fmap_w_f !== FMAP_W || fmap_h_f !== FMAP_H ||
        out_w_f !== OUT_W || out_h_f !== OUT_H) begin
      $display("FAIL: wgen_stim_img.txt header mismatch (%0d %0d %0d %0d %0d)",
                c_in_f, fmap_w_f, fmap_h_f, out_w_f, out_h_f);
      $finish;
    end
    idx = 0;
    for (r = 0; r < FMAP_H; r++) begin
      for (ch = 0; ch < C_IN; ch++) begin
        for (c = 0; c < FMAP_W; c++) begin
          void'($fscanf(fd, "%d", pv));
          pix_mem[idx] = pv;
          idx++;
        end
      end
    end
    $fclose(fd);

    rtl_fd = $fopen("wgen_rtl_out.txt", "w");
    if (rtl_fd == 0) begin
      $display("FAIL: could not open wgen_rtl_out.txt");
      $finish;
    end

    repeat (4) @(negedge clk);
    rst_n = 1;
    @(negedge clk);

    start = 1'b1;
    @(negedge clk);
    start = 1'b0;

    timeout_cycles = 2000;
    cyc = 0;
    while (!done && cyc < timeout_cycles) begin
      @(negedge clk);
      cyc++;
    end
    if (cyc >= timeout_cycles) $display("FAIL: TIMEOUT waiting for done");

    repeat (5) @(negedge clk);

    $display("WINDOW_GEN_SIM_DONE: %0d cycles logged to wgen_rtl_out.txt", cycles_logged);
    $fclose(rtl_fd);
    $finish;
  end

endmodule
