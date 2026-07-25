// Self-checking testbench for sa_packed_4x8.sv
// Drives the array's 4 row (activation-pair) ports + 8 col (weight) ports as
// if a skew_buf.sv sat upstream and re-verifies that the array's internal
// horizontal (activation, per-column) and vertical (weight, per-row) hop
// chains, plus the parallel control-tag shift chain, deliver every one of
// the 32 PPE's WP487 accumulations correctly -- independent of completion
// timing, since PPE[g][c] finishes g+c cycles later than PPE[0][0].
//
// Per-(g,c) FIFO scoreboard (32 queues) makes each position's check order-
// matched against its own issue stream, so real hop/skew timing doesn't need
// to be predicted here -- only value correctness per (tile,g,c). Both this
// testbench's rtl_out.txt and the independent C golden model's golden_out.txt
// are sorted by (tile,g,c) before diffing.
`timescale 1ns/1ps

module tb_sa_packed_4x8;

  localparam int NG = 4;
  localparam int NC = 8;

  logic clk = 0;
  logic rst_n;
  logic en;

  logic signed [7:0] act_lo_in [0:NG-1];
  logic signed [7:0] act_hi_in [0:NG-1];
  logic               pair_valid [0:NG-1];
  logic [1:0]         lane_mask  [0:NG-1];
  logic               depth_last [0:NG-1];

  logic signed [7:0] weight_in [0:NC-1];

  logic signed [31:0] acc_lo_out [0:NG-1][0:NC-1];
  logic signed [31:0] acc_hi_out [0:NG-1][0:NC-1];
  logic [1:0]          acc_valid  [0:NG-1][0:NC-1];

  // raw (unskewed) stimulus: tasks drive these directly, all rows/cols in
  // lockstep on the same testbench cycle k. The model reads these raw_*
  // streams too, so its lo[g][k]*w[c][k] pairing is correct by construction.
  logic signed [7:0] raw_act_lo_in  [0:NG-1];
  logic signed [7:0] raw_act_hi_in  [0:NG-1];
  logic               raw_pair_valid [0:NG-1];
  logic [1:0]         raw_lane_mask  [0:NG-1];
  logic               raw_depth_last [0:NG-1];
  logic signed [7:0] raw_weight_in  [0:NC-1];

  sa_packed_4x8 dut (.*);

  always #5 clk = ~clk;

  // ---------------- skew layer (stand-in for not-yet-built skew_buf.sv) ----------------
  // dut's ports require ALREADY-SKEWED inputs: row g delayed g cycles, col c
  // delayed c cycles (my_self.md sec.4). Without this, the array's own internal
  // hops (activation c cycles horiz, weight g cycles vert) would pair mismatched
  // depths at PE[g][c] whenever g!=c.
  generate
    for (genvar g = 0; g < NG; g++) begin : skew_row
      if (g == 0) begin : g0
        assign act_lo_in[g]  = raw_act_lo_in[g];
        assign act_hi_in[g]  = raw_act_hi_in[g];
        assign pair_valid[g] = raw_pair_valid[g];
        assign lane_mask[g]  = raw_lane_mask[g];
        assign depth_last[g] = raw_depth_last[g];
      end else begin : gn
        logic signed [7:0] d_lo [0:g-1];
        logic signed [7:0] d_hi [0:g-1];
        logic               d_pv [0:g-1];
        logic [1:0]         d_lm [0:g-1];
        logic               d_dl [0:g-1];
        always_ff @(posedge clk or negedge rst_n) begin
          if (!rst_n) begin
            for (int i = 0; i < g; i++) begin
              d_lo[i] <= 0; d_hi[i] <= 0; d_pv[i] <= 0; d_lm[i] <= 0; d_dl[i] <= 0;
            end
          end else if (en) begin
            d_lo[0] <= raw_act_lo_in[g];
            d_hi[0] <= raw_act_hi_in[g];
            d_pv[0] <= raw_pair_valid[g];
            d_lm[0] <= raw_lane_mask[g];
            d_dl[0] <= raw_depth_last[g];
            for (int i = 1; i < g; i++) begin
              d_lo[i] <= d_lo[i-1]; d_hi[i] <= d_hi[i-1]; d_pv[i] <= d_pv[i-1];
              d_lm[i] <= d_lm[i-1]; d_dl[i] <= d_dl[i-1];
            end
          end
        end
        assign act_lo_in[g]  = d_lo[g-1];
        assign act_hi_in[g]  = d_hi[g-1];
        assign pair_valid[g] = d_pv[g-1];
        assign lane_mask[g]  = d_lm[g-1];
        assign depth_last[g] = d_dl[g-1];
      end
    end
  endgenerate

  generate
    for (genvar c = 0; c < NC; c++) begin : skew_col
      if (c == 0) begin : c0
        assign weight_in[c] = raw_weight_in[c];
      end else begin : cn
        logic signed [7:0] d_w [0:c-1];
        always_ff @(posedge clk or negedge rst_n) begin
          if (!rst_n) begin
            for (int i = 0; i < c; i++) d_w[i] <= 0;
          end else if (en) begin
            d_w[0] <= raw_weight_in[c];
            for (int i = 1; i < c; i++) d_w[i] <= d_w[i-1];
          end
        end
        assign weight_in[c] = d_w[c-1];
      end
    end
  endgenerate

  // ---------------- reference scoreboard (32 FIFOs, order-matched per PE) ----------------
  typedef struct {
    int                  tile;
    logic signed [31:0] lo;
    logic signed [31:0] hi;
    logic [1:0]          mask;
  } exp_t;

  exp_t exp_q [0:NG-1][0:NC-1][$];

  int errors = 0;
  int checked = 0;
  int tile_idx = 0;

  logic signed [31:0] model_lo [0:NG-1][0:NC-1];
  logic signed [31:0] model_hi [0:NG-1][0:NC-1];

  int stim_fd, rtl_fd;
  initial begin
    stim_fd = $fopen("sa_stim_log.txt", "w");
    rtl_fd  = $fopen("sa_rtl_out.txt", "w");
    for (int g = 0; g < NG; g++)
      for (int c = 0; c < NC; c++) begin
        model_lo[g][c] = 0;
        model_hi[g][c] = 0;
      end
  end

  // model + stim-log: runs on the same edge the driver applies pair_valid/
  // depth_last on (posedge), mirrors packed_pe_golden.c's WP487 split, but
  // combines row g's activation values with col c's weight values for all
  // 32 (g,c) independently -- skew/hop timing doesn't change the VALUE, only
  // WHEN acc_valid fires, so no timing model is needed here.
  always_ff @(posedge clk) begin
    if (rst_n && en && raw_pair_valid[0]) begin
      $fwrite(stim_fd, "%0d", tile_idx);
      for (int g = 0; g < NG; g++)
        $fwrite(stim_fd, " %0d %0d", raw_act_lo_in[g], raw_act_hi_in[g]);
      for (int c = 0; c < NC; c++)
        $fwrite(stim_fd, " %0d", raw_weight_in[c]);
      $fwrite(stim_fd, " %0d", raw_depth_last[0]);
      for (int g = 0; g < NG; g++)
        $fwrite(stim_fd, " %0d", raw_lane_mask[g]);
      $fwrite(stim_fd, "\n");

      for (int g = 0; g < NG; g++) begin
        for (int c = 0; c < NC; c++) begin
          automatic logic signed [31:0] plo, phi;
          plo = raw_act_lo_in[g] * raw_weight_in[c];
          phi = raw_act_hi_in[g] * raw_weight_in[c];
          model_lo[g][c] += plo;
          model_hi[g][c] += phi;
          if (raw_depth_last[0]) begin
            exp_q[g][c].push_back('{tile: tile_idx, lo: model_lo[g][c] + 0,
                                     hi: model_hi[g][c] + 0, mask: raw_lane_mask[g]});
            model_lo[g][c] = 0;
            model_hi[g][c] = 0;
          end
        end
      end

      if (raw_depth_last[0]) tile_idx++;
    end
  end

  // checker: pop per-(g,c) FIFO on that PE's own acc_valid pulse
  // acc_valid/acc_lo_out/acc_hi_out only take on a new value when en=1
  // (packed_pe gates that whole register stage with "else if (en)"); while
  // en=0 they simply hold last cycle's value, so only check on en=1 cycles.
  generate
    for (genvar g = 0; g < NG; g++) begin : chk_g
      for (genvar c = 0; c < NC; c++) begin : chk_c
        always @(posedge clk) begin
          if (rst_n && en && acc_valid[g][c] != 2'b00) begin
            exp_t e;
            checked++;
            if (exp_q[g][c].size() == 0) begin
              $display("[%0t] ERROR: acc_valid[%0d][%0d] fired with empty scoreboard", $time, g, c);
              errors++;
            end else begin
              e = exp_q[g][c].pop_front();
              $fwrite(rtl_fd, "%0d %0d %0d %0d %0d %0d\n",
                      e.tile, g, c, acc_lo_out[g][c], acc_hi_out[g][c], acc_valid[g][c]);
              if (e.lo !== acc_lo_out[g][c] || e.hi !== acc_hi_out[g][c] || e.mask !== acc_valid[g][c]) begin
                $display("[%0t] MISMATCH g=%0d c=%0d tile=%0d exp lo=%0d hi=%0d mask=%b  got lo=%0d hi=%0d mask=%b",
                          $time, g, c, e.tile, e.lo, e.hi, e.mask, acc_lo_out[g][c], acc_hi_out[g][c], acc_valid[g][c]);
                errors++;
              end
            end
          end
        end
      end
    end
  endgenerate

  // ---------------- helpers ----------------
  function automatic logic signed [7:0] rand8();
    rand8 = $urandom_range(0, 255) - 128;
  endfunction

  task automatic idle_cycle();
    for (int g = 0; g < NG; g++) begin
      raw_pair_valid[g] = 0; raw_depth_last[g] = 0; raw_act_lo_in[g] = 0; raw_act_hi_in[g] = 0;
    end
    for (int c = 0; c < NC; c++) raw_weight_in[c] = 0;
    @(negedge clk);
  endtask

  // feed one tile of depth K; lo/hi per row, w per col, mask per row
  task automatic run_tile(int K, logic signed [7:0] lo[NG][], logic signed [7:0] hi[NG][],
                           logic signed [7:0] w[NC][], logic [1:0] mask[NG], bit bubbles);
    for (int k = 0; k < K; k++) begin
      if (bubbles && ($urandom_range(0,2) == 0)) idle_cycle();
      for (int g = 0; g < NG; g++) begin
        raw_act_lo_in[g]  = lo[g][k];
        raw_act_hi_in[g]  = hi[g][k];
        raw_pair_valid[g] = 1;
        raw_lane_mask[g]  = mask[g];
        raw_depth_last[g] = (k == K-1);
      end
      for (int c = 0; c < NC; c++) raw_weight_in[c] = w[c][k];
      @(negedge clk);
    end
    for (int g = 0; g < NG; g++) begin raw_pair_valid[g] = 0; raw_depth_last[g] = 0; end
  endtask

  task automatic rand_tile(int K, bit bubbles);
    logic signed [7:0] lo[NG][], hi[NG][], w[NC][];
    logic [1:0] mask[NG];
    for (int g = 0; g < NG; g++) begin
      lo[g] = new[K]; hi[g] = new[K];
      for (int k = 0; k < K; k++) begin lo[g][k] = rand8(); hi[g][k] = rand8(); end
      mask[g] = $urandom_range(1, 3);
    end
    for (int c = 0; c < NC; c++) begin
      w[c] = new[K];
      for (int k = 0; k < K; k++) w[c][k] = rand8();
    end
    run_tile(K, lo, hi, w, mask, bubbles);
  endtask

  initial begin
    rst_n = 0; en = 1;
    for (int g = 0; g < NG; g++) begin
      raw_pair_valid[g] = 0; raw_depth_last[g] = 0; raw_lane_mask[g] = 2'b11;
      raw_act_lo_in[g] = 0; raw_act_hi_in[g] = 0;
    end
    for (int c = 0; c < NC; c++) raw_weight_in[c] = 0;
    repeat (4) @(negedge clk);
    rst_n = 1;
    @(negedge clk);

    // ---- directed Conv1-sized tile: K=25 (5x5x1 kernel depth) ----
    rand_tile(25, 0);

    // ---- randomized tiles, varying depth, with idle bubbles ----
    for (int t = 0; t < 60; t++) begin
      int K = $urandom_range(1, 10);
      rand_tile(K, 1);
    end

    // ---- en=0 stall mid-tile (holds hop + control chains together) ----
    begin
      logic signed [7:0] lo[NG][4], hi[NG][4], w[NC][4];
      logic [1:0] mask[NG];
      for (int g = 0; g < NG; g++) begin
        for (int k = 0; k < 4; k++) begin lo[g][k] = rand8(); hi[g][k] = rand8(); end
        mask[g] = 2'b11;
      end
      for (int c = 0; c < NC; c++)
        for (int k = 0; k < 4; k++) w[c][k] = rand8();

      for (int g = 0; g < NG; g++) begin
        raw_act_lo_in[g] = lo[g][0]; raw_act_hi_in[g] = hi[g][0];
        raw_pair_valid[g] = 1; raw_depth_last[g] = 0; raw_lane_mask[g] = mask[g];
      end
      for (int c = 0; c < NC; c++) raw_weight_in[c] = w[c][0];
      @(negedge clk);
      en = 0;
      repeat (7) @(negedge clk);   // hold everything
      en = 1;
      for (int g = 0; g < NG; g++) begin raw_act_lo_in[g] = lo[g][1]; raw_act_hi_in[g] = hi[g][1]; end
      for (int c = 0; c < NC; c++) raw_weight_in[c] = w[c][1];
      @(negedge clk);
      for (int g = 0; g < NG; g++) begin raw_act_lo_in[g] = lo[g][2]; raw_act_hi_in[g] = hi[g][2]; end
      for (int c = 0; c < NC; c++) raw_weight_in[c] = w[c][2];
      @(negedge clk);
      for (int g = 0; g < NG; g++) begin raw_act_lo_in[g] = lo[g][3]; raw_act_hi_in[g] = hi[g][3]; end
      for (int c = 0; c < NC; c++) raw_weight_in[c] = w[c][3];
      for (int g = 0; g < NG; g++) raw_depth_last[g] = 1;
      @(negedge clk);
      for (int g = 0; g < NG; g++) begin raw_pair_valid[g] = 0; raw_depth_last[g] = 0; end
    end

    // drain: worst case hop delay g+c=10 (group3+col7) + packed_pe's own
    // 4-stage internal pipeline; generous margin
    repeat (60) @(posedge clk);

    for (int g = 0; g < NG; g++)
      for (int c = 0; c < NC; c++)
        if (exp_q[g][c].size() != 0) begin
          $display("ERROR: g=%0d c=%0d has %0d expected results never observed", g, c, exp_q[g][c].size());
          errors += exp_q[g][c].size();
        end

    if (errors == 0)
      $display("PASS: %0d results checked, 0 errors", checked);
    else
      $display("FAIL: %0d results checked, %0d errors", checked, errors);

    $fclose(stim_fd);
    $fclose(rtl_fd);
    $finish;
  end

endmodule
