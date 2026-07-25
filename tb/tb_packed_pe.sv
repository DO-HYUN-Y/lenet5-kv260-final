// Self-checking testbench for packed_pe.sv
// Verifies WP487 method-A DSP packing math (prod_lo/prod_hi split incl. P[17]
// carry correction) against a plain (unpacked) reference model, event-ordered
// via a FIFO scoreboard so it stays valid across en-stalls / idle bubbles.
`timescale 1ns/1ps

module tb_packed_pe;

  logic clk = 0;
  logic rst_n;
  logic en;

  logic signed [7:0] act_lo_in, act_hi_in, weight_in;
  logic               pair_valid;
  logic [1:0]         lane_mask;
  logic               depth_last;

  logic signed [7:0] act_lo_out, act_hi_out, weight_out;
  logic signed [31:0] acc_lo_out, acc_hi_out;
  logic [1:0]          acc_valid;

  packed_pe dut (.*);

  always #5 clk = ~clk;

  // ---------------- reference scoreboard (FIFO, order-matched) ----------------
  typedef struct {
    logic signed [31:0] lo;
    logic signed [31:0] hi;
    logic [1:0]          mask;
  } exp_t;

  exp_t exp_q[$];
  int   errors = 0;
  int   errors_acc = 0;
  int   errors_hop = 0;
  int   checked = 0;

  logic signed [31:0] model_lo = 0, model_hi = 0;

  // golden-model cross-check logs (C reimplementation reads stim_log.txt,
  // its output diffed against rtl_out.txt — independent of this SV model)
  int stim_fd, rtl_fd;
  initial begin
    stim_fd = $fopen("stim_log.txt", "w");
    rtl_fd  = $fopen("rtl_out.txt", "w");
  end

  // model runs on the same clock edge as the driver applies pair_valid/depth_last
  always_ff @(posedge clk) begin
    if (rst_n && en && pair_valid) begin
      $fwrite(stim_fd, "%0d %0d %0d %0d %0d\n", act_lo_in, act_hi_in, weight_in, depth_last, lane_mask);
      model_lo <= model_lo + (act_lo_in * weight_in);
      model_hi <= model_hi + (act_hi_in * weight_in);
      if (depth_last) begin
        exp_q.push_back('{lo: model_lo + (act_lo_in * weight_in),
                           hi: model_hi + (act_hi_in * weight_in),
                           mask: lane_mask});
        model_lo <= 0;
        model_hi <= 0;
      end
    end
  end

  // checker: pop on any acc_valid pulse
  always_ff @(posedge clk) begin
    if (rst_n && acc_valid != 2'b00) begin
      exp_t e;
      checked++;
      $fwrite(rtl_fd, "%0d %0d %0d\n", acc_lo_out, acc_hi_out, acc_valid);
      if (exp_q.size() == 0) begin
        $display("[%0t] ERROR: acc_valid fired with empty scoreboard", $time);
        errors_acc++;
      end else begin
        e = exp_q.pop_front();
        if (e.lo !== acc_lo_out || e.hi !== acc_hi_out || e.mask !== acc_valid) begin
          $display("[%0t] MISMATCH exp lo=%0d hi=%0d mask=%b  got lo=%0d hi=%0d mask=%b",
                    $time, e.lo, e.hi, e.mask, acc_lo_out, acc_hi_out, acc_valid);
          errors_acc++;
        end
      end
    end
  end

  // ---------------- hop-path passthrough check ----------------
  logic signed [7:0] prev_lo, prev_hi, prev_w;
  logic prev_en;
  always_ff @(posedge clk) begin
    if (rst_n && prev_en) begin
      if (act_lo_out !== prev_lo || act_hi_out !== prev_hi || weight_out !== prev_w) begin
        $display("[%0t] HOP MISMATCH exp lo=%0d hi=%0d w=%0d got lo=%0d hi=%0d w=%0d",
                  $time, prev_lo, prev_hi, prev_w, act_lo_out, act_hi_out, weight_out);
        errors_hop++;
      end
    end
    prev_lo <= act_lo_in; prev_hi <= act_hi_in; prev_w <= weight_in; prev_en <= en;
  end

  // ---------------- helpers ----------------
  function automatic logic signed [7:0] rand8();
    rand8 = $urandom_range(0, 255) - 128;
  endfunction

  // driver always syncs on NEGEDGE (half-period before DUT/model/checker's
  // posedge sample) so stimulus is stable a full half-cycle before any
  // posedge-triggered always_ff reads it — avoids a same-edge race between
  // this initial block's blocking assigns and posedge always_ff processes.
  task automatic idle_cycle();
    pair_valid = 0; depth_last = 0; act_lo_in = 0; act_hi_in = 0; weight_in = 0;
    @(negedge clk);
  endtask

  // feed one tile of depth K; lo[],hi[],w[] length K
  task automatic run_tile(int K, logic signed [7:0] lo[], logic signed [7:0] hi[],
                           logic signed [7:0] w[], logic [1:0] mask, bit bubbles);
    for (int k = 0; k < K; k++) begin
      if (bubbles && ($urandom_range(0,2) == 0)) idle_cycle();
      act_lo_in  = lo[k];
      act_hi_in  = hi[k];
      weight_in  = w[k];
      pair_valid = 1;
      lane_mask  = mask;
      depth_last = (k == K-1);
      @(negedge clk);
    end
    pair_valid = 0; depth_last = 0;
  endtask

  task automatic directed_case(int K, logic signed[7:0] lo[], logic signed[7:0] hi[],
                                logic signed[7:0] w[], logic [1:0] mask);
    run_tile(K, lo, hi, w, mask, 0);
  endtask

  initial begin
    rst_n = 0; en = 1; pair_valid = 0; depth_last = 0; lane_mask = 2'b11;
    act_lo_in = 0; act_hi_in = 0; weight_in = 0;
    repeat (4) @(negedge clk);
    rst_n = 1;
    @(negedge clk);

    // ---- directed corner cases: signed extremes, P[17] correction path ----
    begin
      logic signed [7:0] lo[1], hi[1], w[1];
      lo[0] = -128; hi[0] = 127;  w[0] = 127;  directed_case(1, lo, hi, w, 2'b11);
      lo[0] = -128; hi[0] = -128; w[0] = -128; directed_case(1, lo, hi, w, 2'b11);
      lo[0] = -1;   hi[0] = 0;    w[0] = 1;    directed_case(1, lo, hi, w, 2'b11);
      lo[0] = 0;    hi[0] = -1;   w[0] = -1;   directed_case(1, lo, hi, w, 2'b11);
      lo[0] = 127;  hi[0] = -128; w[0] = -128; directed_case(1, lo, hi, w, 2'b10);
      lo[0] = -128; hi[0] = 0;    w[0] = -1;   directed_case(1, lo, hi, w, 2'b01);
    end

    // multi-depth directed tile (K=5, mimics 5x5 conv depth slice)
    begin
      logic signed [7:0] lo[5], hi[5], w[5];
      lo = '{-128, 127, -1, 0, 64};
      hi = '{127, -128, 0, -1, -64};
      w  = '{127, -128, 1, -1, 32};
      directed_case(5, lo, hi, w, 2'b11);
    end

    // ---- randomized tiles, varying depth, with idle bubbles ----
    for (int t = 0; t < 200; t++) begin
      int K = $urandom_range(1, 8);
      logic signed [7:0] lo[], hi[], w[];
      logic [1:0] mask;
      lo = new[K]; hi = new[K]; w = new[K];
      for (int k = 0; k < K; k++) begin
        lo[k] = rand8(); hi[k] = rand8(); w[k] = rand8();
      end
      mask = $urandom_range(1, 3);
      run_tile(K, lo, hi, w, mask, 1);
    end

    // ---- en=0 stall mid-tile ----
    begin
      logic signed [7:0] lo[4], hi[4], w[4];
      lo = '{10, -20, 30, -40};
      hi = '{-10, 20, -30, 40};
      w  = '{5, -5, 5, -5};
      act_lo_in = lo[0]; act_hi_in = hi[0]; weight_in = w[0];
      pair_valid = 1; depth_last = 0; lane_mask = 2'b11;
      @(negedge clk);
      en = 0;
      repeat (7) @(negedge clk);   // hold everything
      en = 1;
      act_lo_in = lo[1]; act_hi_in = hi[1]; weight_in = w[1];
      @(negedge clk);
      act_lo_in = lo[2]; act_hi_in = hi[2]; weight_in = w[2];
      @(negedge clk);
      act_lo_in = lo[3]; act_hi_in = hi[3]; weight_in = w[3];
      depth_last = 1;
      @(negedge clk);
      pair_valid = 0; depth_last = 0;
    end

    // drain
    repeat (20) @(posedge clk);

    if (exp_q.size() != 0) begin
      $display("ERROR: %0d expected results never observed", exp_q.size());
    end

    errors = errors_acc + errors_hop + exp_q.size();
    if (errors == 0)
      $display("PASS: %0d results checked, 0 errors", checked);
    else
      $display("FAIL: %0d results checked, %0d errors", checked, errors);

    $fclose(stim_fd);
    $fclose(rtl_fd);
    $finish;
  end

endmodule
