`timescale 1ns/1ps
// window_gen.sv -- activation source scheduler with row-zero compaction.
//
// Five resident input rows feed the tap MUX while two FF row banks prefetch
// sequential future scanlines. pix_rd_en remains one INT8 pixel per cycle,
// but that traffic overlaps S_COMPUTE whenever another output band exists.

module window_gen #(
  parameter int ACT_W         = 8,
  parameter int NG            = 4,
  parameter int NC            = 8,
  parameter int C_IN          = 2,
  parameter int FMAP_W        = 13,
  parameter int FMAP_H        = 13,
  parameter int K             = 5,
  parameter int OUT_W         = FMAP_W - K + 1,
  parameter int OUT_H         = FMAP_H - K + 1,
  parameter int PREFETCH_ROWS = 2,
  // Minimum accepted depth_last spacing required by the eight column
  // postprocessors. Dense tiles naturally exceed this interval; only compact
  // sparse tiles receive invalid bubble advances.
  parameter int MIN_RESULT_GAP = 4,
  // Includes source register, g+c systolic skew, and PPE tag/product delay.
  parameter int DRAIN_LATENCY = 1 + (NG - 1) + (NC - 1) + 4
) (
  input  logic clk,
  input  logic rst_n,          // Async active-low reset for this RTL stage.
  input  logic en,             // Shared global clock-enable; 0 freezes progress.

  input  logic start,          // One-cycle pulse while idle.
  input  logic signed [ACT_W-1:0] pix_in,
  output logic pix_rd_en,      // Upstream sequential activation read request.

  output logic signed [ACT_W-1:0] win_q       [0:2*NG-1],
  output logic                    pair_valid  [0:NG-1],
  output logic [1:0]              lane_mask   [0:NG-1],
  output logic                    depth_last  [0:NG-1],
  output logic [$clog2(K*K*C_IN > 1 ? K*K*C_IN : 2)-1:0] k_out,

  output logic done
);

  localparam int TILE       = 2 * NG;
  localparam int NUM_TILES  = (OUT_W + TILE - 1) / TILE;
  localparam int LBANKS     = K + PREFETCH_ROWS;

  localparam int KW    = (K          < 2) ? 1 : $clog2(K + 1);
  localparam int CW    = (C_IN       < 2) ? 1 : $clog2(C_IN);
  localparam int COLW  = (FMAP_W     < 2) ? 1 : $clog2(FMAP_W);
  localparam int BW    = (OUT_H      < 2) ? 1 : $clog2(OUT_H);
  localparam int TXW   = (NUM_TILES  < 2) ? 1 : $clog2(NUM_TILES);
  localparam int LBW   = (LBANKS     < 2) ? 1 : $clog2(LBANKS);
  localparam int PW    = (PREFETCH_ROWS < 2) ? 1 : $clog2(PREFETCH_ROWS + 1);
  localparam int RW    = (FMAP_H     < 2) ? 1 : $clog2(FMAP_H + 1);
  localparam int DRW   = ($clog2(DRAIN_LATENCY + 1) < 1) ? 1 : $clog2(DRAIN_LATENCY + 1);
  localparam int GAPW  = (MIN_RESULT_GAP < 2) ? 1 : $clog2(MIN_RESULT_GAP);

  // FF banks provide parallel tap reads. Future banks are never selected by
  // S_COMPUTE until their rows rotate into the active K-row window.
  (* ram_style = "registers" *)
  logic signed [ACT_W-1:0] line_buf_ff [0:LBANKS-1][0:C_IN-1][0:FMAP_W-1];
  logic                    row_zero_ff [0:LBANKS-1];

  typedef enum logic [2:0] {
    S_IDLE, S_LOAD, S_LOAD_DRAIN, S_COMPUTE, S_WAIT_PREFETCH, S_DRAIN, S_DONE
  } state_e;
  state_e state_r;

  // Active K-row window is contiguous in a K+1-bank ring.
  logic [LBW-1:0] lb_base_r;
  logic [LBW-1:0] prefetch_slot_r;
  logic [LBW-1:0] row_load_idx_r;
  logic [CW-1:0]  load_ch_r, prefetch_ch_r;
  logic [COLW-1:0] load_col_r, prefetch_col_r;
  logic            load_any_nonzero_r, prefetch_any_nonzero_r;
  logic            prefetch_active_r;
  logic [PW-1:0]   prefetch_rows_r;  // Completed future rows in the ring.
  logic [RW-1:0]   rows_fetched_r;   // Sequential input rows fully consumed.

  logic [BW-1:0]  b_r;
  logic [TXW-1:0] tx_r;
  logic [KW-1:0]  kc_r;
  logic [CW-1:0]  tap_ch_r;
  logic [DRW-1:0] drain_cnt_r;
  logic [GAPW-1:0] issue_gap_r;

  // Built once per output band; S_COMPUTE only walks this compact list.
  logic [KW-1:0] active_kr_list_r [0:K-1];
  logic [KW-1:0] band_n_active_r;
  logic [KW-1:0] active_idx_r;
  logic [KW-1:0] kr_val_c;
  logic compute_tile_done_c;
  logic rate_hold_c;

  function automatic logic [LBW-1:0] bank_add(
      input logic [LBW-1:0] base,
      input logic [LBW-1:0] offset
  );
    logic [LBW:0] sum;
    begin
      sum = {1'b0, base} + {1'b0, offset};
      if (sum >= LBANKS) sum = sum - LBANKS;
      bank_add = sum[LBW-1:0];
    end
  endfunction

  function automatic logic [LBW-1:0] bank_next(input logic [LBW-1:0] base);
    begin
      bank_next = (base == LBANKS - 1) ? '0 : base + 1'b1;
    end
  endfunction

  function automatic logic [1:0] calc_lane_mask(input int tx, input int g);
    int base_col;
    logic lo_valid, hi_valid;
    begin
      base_col = tx * TILE + 2 * g;
      lo_valid = (base_col     < OUT_W);
      hi_valid = (base_col + 1 < OUT_W);
      calc_lane_mask = {hi_valid, lo_valid};
    end
  endfunction

  assign kr_val_c = active_kr_list_r[active_idx_r];

  // The result wave for one tile occupies four cycles at each physical
  // column. Keep accepted tile-final tokens at least MIN_RESULT_GAP advances
  // apart. Non-final tokens continue normally, so dense convolution receives
  // no extra bubbles.
  always_comb begin
    logic last_active;

    last_active = (band_n_active_r != 0) &&
                  (active_idx_r == band_n_active_r - 1'b1);
    compute_tile_done_c = 1'b0;
    if (state_r == S_COMPUTE) begin
      if (band_n_active_r == 0)
        compute_tile_done_c = 1'b1;
      else if (last_active && (kc_r == K - 1) &&
               (tap_ch_r == C_IN - 1))
        compute_tile_done_c = 1'b1;
    end
  end

  assign rate_hold_c = compute_tile_done_c && (issue_gap_r != 0);

  // Future scanlines are fetched during useful compute. S_WAIT_PREFETCH is
  // entered only if no complete future row is ready at a band transition.
  logic prefetch_fire_c;
  logic prefetch_completes_c;
  assign prefetch_fire_c = ((state_r == S_COMPUTE) || (state_r == S_WAIT_PREFETCH)) &&
                           (b_r != OUT_H - 1) && prefetch_active_r;
  assign prefetch_completes_c = prefetch_fire_c &&
                               (prefetch_col_r == FMAP_W - 1) &&
                               (prefetch_ch_r == C_IN - 1);
  assign pix_rd_en = en && ((state_r == S_LOAD) || prefetch_fire_c);

  // One explicit FF-bank write port makes the mutually exclusive PREFILL and
  // PREFETCH writers visible to synthesis. This avoids a multi-write memory
  // inference and preserves the intended register-bank implementation.
  logic lb_write_en_c;
  logic [LBW-1:0] lb_write_slot_c;
  logic [CW-1:0] lb_write_ch_c;
  logic [COLW-1:0] lb_write_col_c;
  always_comb begin
    lb_write_en_c = 1'b0;
    lb_write_slot_c = '0;
    lb_write_ch_c = '0;
    lb_write_col_c = '0;
    if (state_r == S_LOAD) begin
      lb_write_en_c = 1'b1;
      lb_write_slot_c = row_load_idx_r;
      lb_write_ch_c = load_ch_r;
      lb_write_col_c = load_col_r;
    end else if (prefetch_fire_c) begin
      lb_write_en_c = 1'b1;
      lb_write_slot_c = prefetch_slot_r;
      lb_write_ch_c = prefetch_ch_r;
      lb_write_col_c = prefetch_col_r;
    end
  end

  // Keep the FF line-buffer storage out of the asynchronous control-reset
  // process. It is written only after a fresh layer start and does not need a
  // reset value; separating it also preserves a clean single write port.
  always_ff @(posedge clk) begin
    if (en && lb_write_en_c)
      line_buf_ff[lb_write_slot_c][lb_write_ch_c][lb_write_col_c] <= pix_in;
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_r                 <= S_IDLE;
      lb_base_r               <= '0;
      prefetch_slot_r         <= '0;
      row_load_idx_r          <= '0;
      load_ch_r               <= '0;
      load_col_r              <= '0;
      prefetch_ch_r           <= '0;
      prefetch_col_r          <= '0;
      load_any_nonzero_r      <= 1'b0;
      prefetch_any_nonzero_r  <= 1'b0;
      prefetch_active_r       <= 1'b0;
      prefetch_rows_r         <= '0;
      rows_fetched_r          <= '0;
      b_r                     <= '0;
      tx_r                    <= '0;
      kc_r                    <= '0;
      tap_ch_r                <= '0;
      band_n_active_r         <= '0;
      active_idx_r            <= '0;
      drain_cnt_r             <= '0;
      issue_gap_r              <= '0;
      done                    <= 1'b0;
      for (int s = 0; s < LBANKS; s++) row_zero_ff[s] <= 1'b0;
      for (int s = 0; s < K; s++) active_kr_list_r[s] <= '0;
    end else begin
      done <= 1'b0;

      if (en) begin
        if (compute_tile_done_c && !rate_hold_c) begin
          issue_gap_r <= GAPW'(MIN_RESULT_GAP - 1);
        end else if (issue_gap_r != 0) begin
          issue_gap_r <= issue_gap_r - 1'b1;
        end

        // Independent future-row writer. It writes only a non-active bank.
        if (prefetch_fire_c) begin
          logic nz_now;
          nz_now = (pix_in != '0);
          if (prefetch_col_r == FMAP_W - 1) begin
            prefetch_col_r <= '0;
            if (prefetch_ch_r == C_IN - 1) begin
              prefetch_ch_r <= '0;
              row_zero_ff[prefetch_slot_r] <= ~(prefetch_any_nonzero_r | nz_now);
              prefetch_any_nonzero_r <= 1'b0;
              prefetch_rows_r <= prefetch_rows_r + 1'b1;
              rows_fetched_r <= rows_fetched_r + 1'b1;
              if ((rows_fetched_r + 1'b1 < FMAP_H) &&
                  (prefetch_rows_r + 1'b1 < PREFETCH_ROWS)) begin
                prefetch_slot_r <= bank_add(lb_base_r,
                    LBW'(K) + LBW'(prefetch_rows_r + 1'b1));
                prefetch_ch_r <= '0;
                prefetch_col_r <= '0;
                prefetch_any_nonzero_r <= 1'b0;
                prefetch_active_r <= 1'b1;
              end else begin
                prefetch_active_r <= 1'b0;
              end
            end else begin
              prefetch_ch_r <= prefetch_ch_r + 1'b1;
              prefetch_any_nonzero_r <= prefetch_any_nonzero_r | nz_now;
            end
          end else begin
            prefetch_col_r <= prefetch_col_r + 1'b1;
            prefetch_any_nonzero_r <= prefetch_any_nonzero_r | nz_now;
          end
        end

        case (state_r)
          S_IDLE: begin
            if (start) begin
              lb_base_r          <= '0;
              row_load_idx_r     <= '0;
              load_ch_r          <= '0;
              load_col_r         <= '0;
              load_any_nonzero_r <= 1'b0;
              prefetch_active_r  <= 1'b0;
              prefetch_rows_r    <= '0;
              rows_fetched_r     <= '0;
              b_r                <= '0;
              issue_gap_r        <= '0;
              state_r            <= S_LOAD;
            end
          end

          // Initial K-row fill. All later rows use the prefetch path.
          S_LOAD: begin
            logic nz_now;
            nz_now = (pix_in != '0);
            if (load_col_r == FMAP_W - 1) begin
              load_col_r <= '0;
              if (load_ch_r == C_IN - 1) begin
                load_ch_r <= '0;
                row_zero_ff[row_load_idx_r] <= ~(load_any_nonzero_r | nz_now);
                load_any_nonzero_r <= 1'b0;
                if (row_load_idx_r == K - 1) begin
                  rows_fetched_r <= RW'(K);
                  state_r <= S_LOAD_DRAIN;
                end
                else row_load_idx_r <= row_load_idx_r + 1'b1;
              end else begin
                load_ch_r <= load_ch_r + 1'b1;
                load_any_nonzero_r <= load_any_nonzero_r | nz_now;
              end
            end else begin
              load_col_r <= load_col_r + 1'b1;
              load_any_nonzero_r <= load_any_nonzero_r | nz_now;
            end
          end

          // Compact active kr values and start prefetch only when the ring has
          // available future-row capacity. A partial future row survives this
          // setup state across a bank rotation without being reset.
          S_LOAD_DRAIN: begin
            logic [KW-1:0] n;
            n = '0;
            for (int i = 0; i < K; i++) begin
              logic [LBW-1:0] slot;
              slot = bank_add(lb_base_r, LBW'(i));
              if (!row_zero_ff[slot]) begin
                active_kr_list_r[n] <= KW'(i);
                n = n + 1'b1;
              end
            end
            band_n_active_r        <= n;
            active_idx_r           <= '0;
            tx_r                   <= '0;
            kc_r                   <= '0;
            tap_ch_r               <= '0;
            if (!prefetch_active_r && (rows_fetched_r < FMAP_H) &&
                (prefetch_rows_r < PREFETCH_ROWS)) begin
              prefetch_slot_r <= bank_add(lb_base_r,
                  LBW'(K) + LBW'(prefetch_rows_r));
              prefetch_ch_r <= '0;
              prefetch_col_r <= '0;
              prefetch_any_nonzero_r <= 1'b0;
              prefetch_active_r <= 1'b1;
            end
            state_r                <= S_COMPUTE;
          end

          S_COMPUTE: begin
            logic tile_done;
            logic last_active;
            logic prefetch_ready;
            tile_done = 1'b0;
            last_active = (band_n_active_r != 0) &&
                          (active_idx_r == band_n_active_r - 1'b1);
            prefetch_ready = (prefetch_rows_r != 0) || prefetch_completes_c;

            if (band_n_active_r == 0) tile_done = 1'b1;
            else if (last_active && kc_r == K - 1 && tap_ch_r == C_IN - 1) tile_done = 1'b1;

            if (tile_done && !rate_hold_c) begin
              if (tx_r == NUM_TILES - 1) begin
                if (b_r == OUT_H - 1) begin
                  drain_cnt_r <= DRW'(DRAIN_LATENCY);
                  state_r <= S_DRAIN;
                end else if (prefetch_ready) begin
                  // Consume one complete future row. A row completing on this
                  // same edge supplies the new active row and leaves the count
                  // unchanged; otherwise the completed-lookahead count drops.
                  prefetch_rows_r <= prefetch_completes_c ? prefetch_rows_r :
                                                        prefetch_rows_r - 1'b1;
                  lb_base_r <= bank_next(lb_base_r);
                  b_r <= b_r + 1'b1;
                  state_r <= S_LOAD_DRAIN;
                end else begin
                  state_r <= S_WAIT_PREFETCH;
                end
              end else begin
                tx_r         <= tx_r + 1'b1;
                active_idx_r <= '0;
                kc_r         <= '0;
                tap_ch_r     <= '0;
              end
            end else begin
              if (kc_r == K - 1 && tap_ch_r == C_IN - 1) begin
                active_idx_r <= active_idx_r + 1'b1;
                kc_r         <= '0;
                tap_ch_r     <= '0;
              end else if (tap_ch_r == C_IN - 1) begin
                tap_ch_r <= '0;
                kc_r     <= kc_r + 1'b1;
              end else begin
                tap_ch_r <= tap_ch_r + 1'b1;
              end
            end
          end

          S_WAIT_PREFETCH: begin
            if ((prefetch_rows_r != 0) || prefetch_completes_c) begin
              prefetch_rows_r <= prefetch_completes_c ? prefetch_rows_r :
                                                        prefetch_rows_r - 1'b1;
              lb_base_r <= bank_next(lb_base_r);
              b_r <= b_r + 1'b1;
              state_r <= S_LOAD_DRAIN;
            end
          end

          S_DRAIN: begin
            if (drain_cnt_r == 0) state_r <= S_DONE;
            else drain_cnt_r <= drain_cnt_r - 1'b1;
          end

          S_DONE: begin
            done <= 1'b1;
            state_r <= S_IDLE;
          end

          default: state_r <= S_IDLE;
        endcase
      end
    end
  end

  // This payload is captured by conv_stream_datapath's source register so it
  // aligns with weight_loader's registered BRAM output before skew_buf.
  always_comb begin
    int tile_base_col;
    logic is_last_tap;
    logic [LBW-1:0] slot;

    tile_base_col = tx_r * TILE;
    is_last_tap = (band_n_active_r != 0) &&
                  (active_idx_r == band_n_active_r - 1'b1) &&
                  (kc_r == K - 1) && (tap_ch_r == C_IN - 1);
    slot = bank_add(lb_base_r, kr_val_c[LBW-1:0]);

    for (int i = 0; i < 2 * NG; i++) win_q[i] = '0;
    for (int g = 0; g < NG; g++) begin
      pair_valid[g] = 1'b0;
      lane_mask[g]  = 2'b00;
      depth_last[g] = 1'b0;
    end
    k_out = '0;

    if ((state_r == S_COMPUTE) && !rate_hold_c) begin
      for (int g = 0; g < NG; g++) lane_mask[g] = calc_lane_mask(tx_r, g);
      if (band_n_active_r == 0) begin
        for (int g = 0; g < NG; g++) begin
          pair_valid[g] = 1'b1;
          depth_last[g] = 1'b1;
        end
      end else begin
        for (int r = 0; r < 2 * NG; r++) begin
          int col;
          col = tile_base_col + kc_r + r;
          win_q[r] = (col >= FMAP_W) ? '0 : line_buf_ff[slot][tap_ch_r][col];
        end
        for (int g = 0; g < NG; g++) begin
          pair_valid[g] = 1'b1;
          depth_last[g] = is_last_tap;
        end
        k_out = (kr_val_c * K + kc_r) * C_IN + tap_ch_r;
      end
    end
  end

`ifdef SIMULATION
  assert property (@(posedge clk) disable iff (!rst_n)
      (state_r == S_WAIT_PREFETCH) |-> (b_r != OUT_H - 1));
  for (genvar ag = 0; ag < NG; ag++) begin : g_assert_rate_hold
    assert property (@(posedge clk) disable iff (!rst_n)
        rate_hold_c |-> !pair_valid[ag]);
  end
`endif

endmodule
