// tb_skew_buf.sv -- self-checking-by-external-diff testbench for skew_buf.sv
//
// skew_buf's whole job is cycle-exact delay, so this TB does not replicate
// an inline scoreboard (a second hand-written copy of the same recurrence
// risks the same off-by-one bug in both places). Instead it drives random
// stimulus, logs one line per cycle of (a) the exact DUT inputs and (b) the
// exact DUT outputs, in the formats skew_buf_golden.c expects/produces.
// skew_buf_golden.c (independent C model) is then run on the stim log and
// diffed line-for-line against the rtl_out log -- that diff is the pass/fail
// gate, not anything inside this file.
//
// Sampling points (must match golden/skew_buf_golden.c header comment):
//   stim line T   = DUT inputs sampled at posedge T.
//   output line T = DUT outputs sampled at posedge T + 1ns.

`timescale 1ns/1ps

module tb_skew_buf;

  localparam int NG = 4;
  localparam int NC = 8;

  logic clk, rst_n, en;
  logic signed [7:0] win_q [0:2*NG-1];
  logic              pair_valid_in [0:NG-1];
  logic [1:0]        lane_mask_in  [0:NG-1];
  logic              depth_last_in [0:NG-1];
  logic signed [7:0] weight_q [0:NC-1];
  logic weight_valid_in, weight_depth_last_in;

  logic signed [7:0] act_lo_out    [0:NG-1];
  logic signed [7:0] act_hi_out    [0:NG-1];
  logic              pair_valid_out [0:NG-1];
  logic [1:0]        lane_mask_out  [0:NG-1];
  logic              depth_last_out [0:NG-1];
  logic signed [7:0] weight_out [0:NC-1];
  logic weight_valid_out [0:NC-1];
  logic weight_depth_last_out [0:NC-1];

  skew_buf dut (.*);

  always #5 clk = ~clk;

  function automatic logic signed [7:0] rand8();
    rand8 = $urandom_range(0, 255) - 128;
  endfunction

  int stim_fd, rtl_fd;
  int cycles_logged;

  task automatic drive_random();
    int i;
    en = ($urandom_range(0, 9) != 0); // ~10% en=0 stall cycles
    for (i = 0; i < 2*NG; i++) win_q[i] = rand8();
    for (i = 0; i < NG; i++) begin
      pair_valid_in[i] = $urandom_range(0, 1);
      lane_mask_in[i]  = $urandom_range(0, 3);
      depth_last_in[i] = $urandom_range(0, 1);
    end
    for (i = 0; i < NC; i++) weight_q[i] = rand8();
    weight_valid_in = $urandom_range(0, 1);
    weight_depth_last_in = $urandom_range(0, 1);
  endtask

  task automatic drive_ramp(int idx, int last);
    int i;
    en = 1'b1;
    for (i = 0; i < 2*NG; i++) win_q[i] = (idx + i) & 8'h7f;
    for (i = 0; i < NG; i++) begin
      pair_valid_in[i] = 1'b1;
      lane_mask_in[i]  = i[1:0];
      depth_last_in[i] = last;
    end
    for (i = 0; i < NC; i++) weight_q[i] = (idx - i) & 8'h7f;
    weight_valid_in = 1'b1;
    weight_depth_last_in = last;
  endtask

  task automatic hold_stall();
    en = 1'b0;
    // data ports don't matter while en=0 (registers hold), leave as-is
  endtask

  task automatic log_stim();
    int i;
    $fwrite(stim_fd, "%0d ", en);
    for (i = 0; i < 2*NG; i++) $fwrite(stim_fd, "%0d ", win_q[i]);
    for (i = 0; i < NG; i++)   $fwrite(stim_fd, "%0d ", pair_valid_in[i]);
    for (i = 0; i < NG; i++)   $fwrite(stim_fd, "%0d ", lane_mask_in[i]);
    for (i = 0; i < NG; i++)   $fwrite(stim_fd, "%0d ", depth_last_in[i]);
    for (i = 0; i < NC; i++)   $fwrite(stim_fd, "%0d%s", weight_q[i], (i == NC-1) ? "\n" : " ");
  endtask

  task automatic log_output();
    int g, c;
    for (g = 0; g < NG; g++) begin
      $fwrite(rtl_fd, "%0d %0d %0d %0d %0d ",
              act_lo_out[g], act_hi_out[g], pair_valid_out[g],
              lane_mask_out[g], depth_last_out[g]);
    end
    for (c = 0; c < NC; c++) $fwrite(rtl_fd, "%0d%s", weight_out[c], (c == NC-1) ? "\n" : " ");
  endtask

  // Logged every cycle post-reset: stim at posedge, DUT output 1ns later
  // (after this same edge's NBA updates land) -- see golden model header.
  always @(posedge clk) begin
    if (rst_n) begin
      log_stim();
      cycles_logged++;
      #1;
      log_output();
    end
  end

  initial begin
    clk   = 0;
    rst_n = 0;
    en    = 0;
    for (int i = 0; i < 2*NG; i++) win_q[i] = '0;
    for (int i = 0; i < NG; i++) begin
      pair_valid_in[i] = 0; lane_mask_in[i] = 0; depth_last_in[i] = 0;
    end
    for (int i = 0; i < NC; i++) weight_q[i] = '0;
    weight_valid_in = 1'b0;
    weight_depth_last_in = 1'b0;
    cycles_logged = 0;

    stim_fd = $fopen("skew_stim_log.txt", "w");
    rtl_fd  = $fopen("skew_rtl_out.txt", "w");
    if (stim_fd == 0 || rtl_fd == 0) begin
      $display("FAIL: could not open log files");
      $finish;
    end

    repeat (4) @(negedge clk);
    rst_n = 1;
    @(negedge clk);

    // directed ramp: easy to eyeball the skew by hand
    for (int idx = 0; idx < 32; idx++) begin
      drive_ramp(idx, (idx == 31));
      @(negedge clk);
    end

    // randomized run with occasional en=0 stalls mixed in
    for (int k = 0; k < 300; k++) begin
      drive_random();
      @(negedge clk);
    end

    // directed multi-cycle stall block, then resume randomized traffic
    for (int k = 0; k < 10; k++) begin
      hold_stall();
      @(negedge clk);
    end
    for (int k = 0; k < 100; k++) begin
      drive_random();
      @(negedge clk);
    end

    // generous drain tail: worst-case chain depth is 7 cycles (col 7 / group 3
    // both <=7), 20 cycles clears every stage with margin
    en = 1'b1;
    for (int i = 0; i < 2*NG; i++) win_q[i] = '0;
    for (int i = 0; i < NG; i++) begin
      pair_valid_in[i] = 0; lane_mask_in[i] = 0; depth_last_in[i] = 0;
    end
    for (int i = 0; i < NC; i++) weight_q[i] = '0;
    weight_valid_in = 1'b0;
    weight_depth_last_in = 1'b0;
    repeat (20) @(negedge clk);

    $display("SKEW_BUF_SIM_DONE: %0d cycles logged to skew_stim_log.txt / skew_rtl_out.txt", cycles_logged);
    $fclose(stim_fd);
    $fclose(rtl_fd);
    $finish;
  end

endmodule
