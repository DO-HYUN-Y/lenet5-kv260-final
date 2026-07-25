`timescale 1ns/1ps
// window_gen_runtime.sv -- runtime-configured C1/C3 window scheduler.
//
// Storage is sized for the largest convolution layer, while width, height,
// channel count, output shape, and tile count are latched per layer.

module window_gen_runtime #(
  parameter int ACT_W          = 8,
  parameter int NG             = 4,
  parameter int NC             = 8,
  parameter int K              = 5,
  parameter int MAX_C_IN       = 6,
  parameter int MAX_FMAP_W     = 32,
  parameter int MAX_FMAP_H     = 32,
  parameter int PREFETCH_ROWS  = 2,
  parameter int MIN_RESULT_GAP = 4,
  parameter int DRAIN_LATENCY  = 1 + (NG - 1) + (NC - 1) + 4,
  parameter int C_W            =
      (MAX_C_IN < 2) ? 1 : $clog2(MAX_C_IN + 1),
  parameter int DIM_W          =
      (MAX_FMAP_W < 2) ? 1 : $clog2(MAX_FMAP_W + 1),
  parameter int KOUT_W         =
      $clog2(K*K*MAX_C_IN > 1 ? K*K*MAX_C_IN : 2)
) (
  input  logic clk,
  input  logic rst_n,
  input  logic en,
  input  logic start,

  input  logic [DIM_W-1:0] cfg_fmap_w,
  input  logic [DIM_W-1:0] cfg_fmap_h,
  input  logic [C_W-1:0]   cfg_c_in,
  input  logic [DIM_W-1:0] cfg_out_w,
  input  logic [DIM_W-1:0] cfg_out_h,

  input  logic signed [ACT_W-1:0] pix_in,
  input  logic                    pix_valid,
  output logic                    pix_rd_en,

  output logic signed [ACT_W-1:0] win_q [0:2*NG-1],
  output logic                    pair_valid [0:NG-1],
  output logic [1:0]              lane_mask [0:NG-1],
  output logic                    depth_last [0:NG-1],
  output logic [KOUT_W-1:0]       k_out,
  output logic                    done
);

  localparam int TILE = 2 * NG;
  localparam int MAX_TILES = (MAX_FMAP_W + TILE - 1) / TILE;
  localparam int LBANKS = K + PREFETCH_ROWS;
  localparam int KW = (K < 2) ? 1 : $clog2(K + 1);
  localparam int TX_W = (MAX_TILES < 2) ? 1 : $clog2(MAX_TILES + 1);
  localparam int LB_W = (LBANKS < 2) ? 1 : $clog2(LBANKS);
  localparam int PF_W =
      (PREFETCH_ROWS < 2) ? 1 : $clog2(PREFETCH_ROWS + 1);
  localparam int DRAIN_W =
      ($clog2(DRAIN_LATENCY + 1) < 1) ?
      1 : $clog2(DRAIN_LATENCY + 1);
  localparam int GAP_W =
      (MIN_RESULT_GAP < 2) ? 1 : $clog2(MIN_RESULT_GAP);

  logic [DIM_W-1:0] fmap_w_r;
  logic [DIM_W-1:0] fmap_h_r;
  logic [C_W-1:0] c_in_r;
  logic [DIM_W-1:0] out_w_r;
  logic [DIM_W-1:0] out_h_r;
  logic [TX_W-1:0] num_tiles_r;

  (* ram_style = "registers" *)
  logic signed [ACT_W-1:0]
      line_buf_ff [0:LBANKS-1][0:MAX_C_IN-1][0:MAX_FMAP_W-1];
  logic row_zero_ff [0:LBANKS-1];

  typedef enum logic [2:0] {
    S_IDLE, S_LOAD, S_LOAD_DRAIN, S_COMPUTE,
    S_WAIT_PREFETCH, S_DRAIN, S_DONE
  } state_e;
  state_e state_r;

  logic [LB_W-1:0] lb_base_r;
  logic [LB_W-1:0] prefetch_slot_r;
  logic [LB_W-1:0] row_load_idx_r;
  logic [C_W-1:0] load_ch_r;
  logic [C_W-1:0] prefetch_ch_r;
  logic [DIM_W-1:0] load_col_r;
  logic [DIM_W-1:0] prefetch_col_r;
  logic load_any_nonzero_r;
  logic prefetch_any_nonzero_r;
  logic prefetch_active_r;
  logic [PF_W-1:0] prefetch_rows_r;
  logic [DIM_W-1:0] rows_fetched_r;

  logic [DIM_W-1:0] out_y_r;
  logic [TX_W-1:0] tile_x_r;
  logic [KW-1:0] kernel_col_r;
  logic [C_W-1:0] tap_ch_r;
  logic [DRAIN_W-1:0] drain_count_r;
  logic [GAP_W-1:0] issue_gap_r;

  logic [KW-1:0] active_kr_list_r [0:K-1];
  logic [KW-1:0] band_n_active_r;
  logic [KW-1:0] active_idx_r;
  logic [KW-1:0] kr_value_c;
  logic compute_tile_done_c;
  logic rate_hold_c;

  function automatic logic [LB_W-1:0] bank_add(
      input logic [LB_W-1:0] base,
      input logic [LB_W-1:0] offset
  );
    logic [LB_W:0] sum;
    begin
      sum = {1'b0, base} + {1'b0, offset};
      if (sum >= LBANKS) sum = sum - LBANKS;
      bank_add = sum[LB_W-1:0];
    end
  endfunction

  function automatic logic [LB_W-1:0] bank_next(
      input logic [LB_W-1:0] base
  );
    bank_next = (base == LBANKS - 1) ? '0 : base + 1'b1;
  endfunction

  function automatic logic [1:0] make_lane_mask(
      input int tile_index,
      input int group_index,
      input int output_width
  );
    int base_x;
    begin
      base_x = tile_index * TILE + 2 * group_index;
      make_lane_mask = {
        (base_x + 1 < output_width),
        (base_x < output_width)
      };
    end
  endfunction

  assign kr_value_c = active_kr_list_r[active_idx_r];

  always_comb begin
    logic last_active;
    last_active = (band_n_active_r != 0) &&
                  (active_idx_r == band_n_active_r - 1'b1);
    compute_tile_done_c = 1'b0;
    if (state_r == S_COMPUTE) begin
      if (band_n_active_r == 0)
        compute_tile_done_c = 1'b1;
      else if (last_active && (kernel_col_r == K - 1) &&
               (tap_ch_r == c_in_r - 1'b1))
        compute_tile_done_c = 1'b1;
    end
  end

  assign rate_hold_c =
      compute_tile_done_c && (issue_gap_r != 0);

  logic prefetch_fire_c;
  logic prefetch_completes_c;
  assign prefetch_fire_c =
      en && pix_valid &&
      ((state_r == S_COMPUTE) || (state_r == S_WAIT_PREFETCH)) &&
      (out_y_r != out_h_r - 1'b1) && prefetch_active_r;
  assign prefetch_completes_c =
      prefetch_fire_c &&
      (prefetch_col_r == fmap_w_r - 1'b1) &&
      (prefetch_ch_r == c_in_r - 1'b1);
  assign pix_rd_en =
      (en && pix_valid && (state_r == S_LOAD)) || prefetch_fire_c;

  logic lb_write_en_c;
  logic [LB_W-1:0] lb_write_slot_c;
  logic [C_W-1:0] lb_write_ch_c;
  logic [DIM_W-1:0] lb_write_col_c;
  always_comb begin
    lb_write_en_c = 1'b0;
    lb_write_slot_c = '0;
    lb_write_ch_c = '0;
    lb_write_col_c = '0;
    if (en && pix_valid && (state_r == S_LOAD)) begin
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

  // Register the activation broadcast and write address before the large
  // FF line buffer. Each row/channel pair owns a local replica, reducing the
  // BRAM-reader data fanout from every line-buffer bit to one replica bank.
  // The delayed write still accepts one pixel every cycle.
  logic lb_write_en_q;
  logic [LB_W-1:0] lb_write_slot_q;
  logic [C_W-1:0] lb_write_ch_q;
  logic [DIM_W-1:0] lb_write_col_q;
  logic signed [ACT_W-1:0]
      pix_write_replica_r [0:LBANKS-1][0:MAX_C_IN-1];

  always_ff @(posedge clk) begin
    if (!rst_n || start) begin
      lb_write_en_q <= 1'b0;
      lb_write_slot_q <= '0;
      lb_write_ch_q <= '0;
      lb_write_col_q <= '0;
    end else begin
      lb_write_en_q <= lb_write_en_c;
      if (lb_write_en_c) begin
        lb_write_slot_q <= lb_write_slot_c;
        lb_write_ch_q <= lb_write_ch_c;
        lb_write_col_q <= lb_write_col_c;
        pix_write_replica_r[lb_write_slot_c][lb_write_ch_c] <=
            pix_in;
      end
      if (lb_write_en_q)
        line_buf_ff[lb_write_slot_q][lb_write_ch_q][lb_write_col_q] <=
            pix_write_replica_r[lb_write_slot_q][lb_write_ch_q];
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      fmap_w_r <= '0;
      fmap_h_r <= '0;
      c_in_r <= '0;
      out_w_r <= '0;
      out_h_r <= '0;
      num_tiles_r <= '0;
      state_r <= S_IDLE;
      lb_base_r <= '0;
      prefetch_slot_r <= '0;
      row_load_idx_r <= '0;
      load_ch_r <= '0;
      prefetch_ch_r <= '0;
      load_col_r <= '0;
      prefetch_col_r <= '0;
      load_any_nonzero_r <= 1'b0;
      prefetch_any_nonzero_r <= 1'b0;
      prefetch_active_r <= 1'b0;
      prefetch_rows_r <= '0;
      rows_fetched_r <= '0;
      out_y_r <= '0;
      tile_x_r <= '0;
      kernel_col_r <= '0;
      tap_ch_r <= '0;
      drain_count_r <= '0;
      issue_gap_r <= '0;
      band_n_active_r <= '0;
      active_idx_r <= '0;
      done <= 1'b0;
      for (int s = 0; s < LBANKS; s++) row_zero_ff[s] <= 1'b0;
      for (int i = 0; i < K; i++) active_kr_list_r[i] <= '0;
    end else begin
      done <= 1'b0;

      if (en) begin
        if (compute_tile_done_c && !rate_hold_c)
          issue_gap_r <= GAP_W'(MIN_RESULT_GAP - 1);
        else if (issue_gap_r != 0)
          issue_gap_r <= issue_gap_r - 1'b1;

        if (prefetch_fire_c) begin
          logic nonzero_now;
          nonzero_now = (pix_in != '0);
          if (prefetch_col_r == fmap_w_r - 1'b1) begin
            prefetch_col_r <= '0;
            if (prefetch_ch_r == c_in_r - 1'b1) begin
              prefetch_ch_r <= '0;
              row_zero_ff[prefetch_slot_r] <=
                  ~(prefetch_any_nonzero_r | nonzero_now);
              prefetch_any_nonzero_r <= 1'b0;
              prefetch_rows_r <= prefetch_rows_r + 1'b1;
              rows_fetched_r <= rows_fetched_r + 1'b1;
              if ((rows_fetched_r + 1'b1 < fmap_h_r) &&
                  (prefetch_rows_r + 1'b1 < PREFETCH_ROWS)) begin
                prefetch_slot_r <= bank_add(
                    lb_base_r,
                    LB_W'(K) + LB_W'(prefetch_rows_r + 1'b1));
                prefetch_active_r <= 1'b1;
              end else begin
                prefetch_active_r <= 1'b0;
              end
            end else begin
              prefetch_ch_r <= prefetch_ch_r + 1'b1;
              prefetch_any_nonzero_r <=
                  prefetch_any_nonzero_r | nonzero_now;
            end
          end else begin
            prefetch_col_r <= prefetch_col_r + 1'b1;
            prefetch_any_nonzero_r <=
                prefetch_any_nonzero_r | nonzero_now;
          end
        end

        case (state_r)
          S_IDLE: begin
            if (start) begin
              fmap_w_r <= cfg_fmap_w;
              fmap_h_r <= cfg_fmap_h;
              c_in_r <= cfg_c_in;
              out_w_r <= cfg_out_w;
              out_h_r <= cfg_out_h;
              num_tiles_r <=
                  TX_W'((int'(cfg_out_w) + TILE - 1) / TILE);
              lb_base_r <= '0;
              row_load_idx_r <= '0;
              load_ch_r <= '0;
              load_col_r <= '0;
              load_any_nonzero_r <= 1'b0;
              prefetch_active_r <= 1'b0;
              prefetch_rows_r <= '0;
              rows_fetched_r <= '0;
              out_y_r <= '0;
              issue_gap_r <= '0;
              state_r <= S_LOAD;
            end
          end

          S_LOAD: begin
            if (pix_valid) begin
              logic nonzero_now;
              nonzero_now = (pix_in != '0);
              if (load_col_r == fmap_w_r - 1'b1) begin
                load_col_r <= '0;
                if (load_ch_r == c_in_r - 1'b1) begin
                  load_ch_r <= '0;
                  row_zero_ff[row_load_idx_r] <=
                      ~(load_any_nonzero_r | nonzero_now);
                  load_any_nonzero_r <= 1'b0;
                  if (row_load_idx_r == K - 1) begin
                    rows_fetched_r <= DIM_W'(K);
                    state_r <= S_LOAD_DRAIN;
                  end else begin
                    row_load_idx_r <= row_load_idx_r + 1'b1;
                  end
                end else begin
                  load_ch_r <= load_ch_r + 1'b1;
                  load_any_nonzero_r <=
                      load_any_nonzero_r | nonzero_now;
                end
              end else begin
                load_col_r <= load_col_r + 1'b1;
                load_any_nonzero_r <=
                    load_any_nonzero_r | nonzero_now;
              end
            end
          end

          S_LOAD_DRAIN: begin
            logic [KW-1:0] active_count;
            active_count = '0;
            for (int i = 0; i < K; i++) begin
              logic [LB_W-1:0] slot;
              slot = bank_add(lb_base_r, LB_W'(i));
              if (!row_zero_ff[slot]) begin
                active_kr_list_r[active_count] <= KW'(i);
                active_count = active_count + 1'b1;
              end
            end
            band_n_active_r <= active_count;
            active_idx_r <= '0;
            tile_x_r <= '0;
            kernel_col_r <= '0;
            tap_ch_r <= '0;
            if (!prefetch_active_r &&
                (rows_fetched_r < fmap_h_r) &&
                (prefetch_rows_r < PREFETCH_ROWS)) begin
              prefetch_slot_r <= bank_add(
                  lb_base_r, LB_W'(K) + LB_W'(prefetch_rows_r));
              prefetch_ch_r <= '0;
              prefetch_col_r <= '0;
              prefetch_any_nonzero_r <= 1'b0;
              prefetch_active_r <= 1'b1;
            end
            state_r <= S_COMPUTE;
          end

          S_COMPUTE: begin
            logic tile_done;
            logic last_active;
            logic prefetch_ready;
            tile_done = 1'b0;
            last_active = (band_n_active_r != 0) &&
                          (active_idx_r == band_n_active_r - 1'b1);
            prefetch_ready =
                (prefetch_rows_r != 0) || prefetch_completes_c;
            if (band_n_active_r == 0)
              tile_done = 1'b1;
            else if (last_active &&
                     (kernel_col_r == K - 1) &&
                     (tap_ch_r == c_in_r - 1'b1))
              tile_done = 1'b1;

            if (tile_done && !rate_hold_c) begin
              if (tile_x_r == num_tiles_r - 1'b1) begin
                if (out_y_r == out_h_r - 1'b1) begin
                  drain_count_r <= DRAIN_W'(DRAIN_LATENCY);
                  state_r <= S_DRAIN;
                end else if (prefetch_ready) begin
                  prefetch_rows_r <=
                      prefetch_completes_c ?
                      prefetch_rows_r : prefetch_rows_r - 1'b1;
                  lb_base_r <= bank_next(lb_base_r);
                  out_y_r <= out_y_r + 1'b1;
                  state_r <= S_LOAD_DRAIN;
                end else begin
                  state_r <= S_WAIT_PREFETCH;
                end
              end else begin
                tile_x_r <= tile_x_r + 1'b1;
                active_idx_r <= '0;
                kernel_col_r <= '0;
                tap_ch_r <= '0;
              end
            end else if (!rate_hold_c) begin
              if ((kernel_col_r == K - 1) &&
                  (tap_ch_r == c_in_r - 1'b1)) begin
                active_idx_r <= active_idx_r + 1'b1;
                kernel_col_r <= '0;
                tap_ch_r <= '0;
              end else if (tap_ch_r == c_in_r - 1'b1) begin
                tap_ch_r <= '0;
                kernel_col_r <= kernel_col_r + 1'b1;
              end else begin
                tap_ch_r <= tap_ch_r + 1'b1;
              end
            end
          end

          S_WAIT_PREFETCH: begin
            if ((prefetch_rows_r != 0) || prefetch_completes_c) begin
              prefetch_rows_r <=
                  prefetch_completes_c ?
                  prefetch_rows_r : prefetch_rows_r - 1'b1;
              lb_base_r <= bank_next(lb_base_r);
              out_y_r <= out_y_r + 1'b1;
              state_r <= S_LOAD_DRAIN;
            end
          end

          S_DRAIN: begin
            if (drain_count_r == 0)
              state_r <= S_DONE;
            else
              drain_count_r <= drain_count_r - 1'b1;
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

  // Split the runtime FF-line-buffer lookup into:
  //   selector register -> selected 32-byte row -> lane column mux.
  // The old single-cycle lookup combined slot, channel, column, active-row,
  // and k-index arithmetic in one large mux cone. These two stages keep II=1
  // and preserve the token stream while providing a 200 MHz timing boundary.
  logic issue_valid_c;
  logic issue_zero_c;
  logic issue_last_c;
  (* use_dsp = "no" *) logic [KOUT_W-1:0] issue_k_c;
  logic [LB_W-1:0] issue_slot_c;
  logic [C_W-1:0] issue_ch_c;
  logic [1:0] issue_mask_c [0:NG-1];
  logic [DIM_W-1:0] issue_x_c [0:2*NG-1];
  logic issue_x_valid_c [0:2*NG-1];

  always_comb begin
    int tile_base_x;
    logic last_tap;

    tile_base_x = int'(tile_x_r) * TILE;
    last_tap = (band_n_active_r != 0) &&
               (active_idx_r == band_n_active_r - 1'b1) &&
               (kernel_col_r == K - 1) &&
               (tap_ch_r == c_in_r - 1'b1);
    issue_valid_c = (state_r == S_COMPUTE) && !rate_hold_c;
    issue_zero_c = (band_n_active_r == 0);
    issue_last_c = issue_zero_c || last_tap;
    issue_k_c = '0;
    issue_slot_c = bank_add(lb_base_r, LB_W'(kr_value_c));
    issue_ch_c = tap_ch_r;

    for (int g = 0; g < NG; g++)
      issue_mask_c[g] =
          issue_valid_c ? make_lane_mask(tile_x_r, g, out_w_r) : 2'b00;
    for (int lane = 0; lane < 2 * NG; lane++) begin
      int input_x;
      input_x = tile_base_x + int'(kernel_col_r) + lane;
      issue_x_c[lane] = DIM_W'(input_x);
      issue_x_valid_c[lane] =
          issue_valid_c && !issue_zero_c &&
          (input_x < int'(fmap_w_r));
    end

    if (issue_valid_c && !issue_zero_c)
      issue_k_c =
          KOUT_W'((int'(kr_value_c) * K + int'(kernel_col_r)) *
                  int'(c_in_r) + int'(tap_ch_r));
  end

  logic req_valid_r;
  logic req_zero_r;
  logic req_last_r;
  logic [KOUT_W-1:0] req_k_r;
  logic [LB_W-1:0] req_slot_r;
  logic [C_W-1:0] req_ch_r;
  logic [1:0] req_mask_r [0:NG-1];
  logic [DIM_W-1:0] req_x_r [0:2*NG-1];
  logic req_x_valid_r [0:2*NG-1];

  logic signed [ACT_W-1:0] selected_row_r [0:MAX_FMAP_W-1];
  logic row_valid_r;
  logic row_last_r;
  logic [KOUT_W-1:0] row_k_r;
  logic [1:0] row_mask_r [0:NG-1];
  logic [DIM_W-1:0] row_x_r [0:2*NG-1];
  logic row_x_valid_r [0:2*NG-1];

  always_ff @(posedge clk) begin
    if (!rst_n || start) begin
      req_valid_r <= 1'b0;
      req_zero_r <= 1'b0;
      req_last_r <= 1'b0;
      req_k_r <= '0;
      req_slot_r <= '0;
      req_ch_r <= '0;
      row_valid_r <= 1'b0;
      row_last_r <= 1'b0;
      row_k_r <= '0;
      k_out <= '0;
      for (int col = 0; col < MAX_FMAP_W; col++)
        selected_row_r[col] <= '0;
      for (int lane = 0; lane < 2 * NG; lane++) begin
        req_x_r[lane] <= '0;
        req_x_valid_r[lane] <= 1'b0;
        row_x_r[lane] <= '0;
        row_x_valid_r[lane] <= 1'b0;
        win_q[lane] <= '0;
      end
      for (int g = 0; g < NG; g++) begin
        req_mask_r[g] <= 2'b00;
        row_mask_r[g] <= 2'b00;
        pair_valid[g] <= 1'b0;
        lane_mask[g] <= 2'b00;
        depth_last[g] <= 1'b0;
      end
    end else if (en) begin
      req_valid_r <= issue_valid_c;
      req_zero_r <= issue_zero_c;
      req_last_r <= issue_last_c;
      req_k_r <= issue_k_c;
      req_slot_r <= issue_slot_c;
      req_ch_r <= issue_ch_c;
      for (int g = 0; g < NG; g++)
        req_mask_r[g] <= issue_mask_c[g];
      for (int lane = 0; lane < 2 * NG; lane++) begin
        req_x_r[lane] <= issue_x_c[lane];
        req_x_valid_r[lane] <= issue_x_valid_c[lane];
      end

      row_valid_r <= req_valid_r;
      row_last_r <= req_last_r;
      row_k_r <= req_k_r;
      for (int g = 0; g < NG; g++)
        row_mask_r[g] <= req_mask_r[g];
      for (int lane = 0; lane < 2 * NG; lane++) begin
        row_x_r[lane] <= req_x_r[lane];
        row_x_valid_r[lane] <= req_x_valid_r[lane];
      end
      for (int col = 0; col < MAX_FMAP_W; col++) begin
        if (req_valid_r && !req_zero_r)
          selected_row_r[col] <=
              line_buf_ff[req_slot_r][req_ch_r][col];
        else
          selected_row_r[col] <= '0;
      end

      k_out <= row_valid_r ? row_k_r : '0;
      for (int g = 0; g < NG; g++) begin
        pair_valid[g] <= row_valid_r;
        lane_mask[g] <= row_valid_r ? row_mask_r[g] : 2'b00;
        depth_last[g] <= row_valid_r && row_last_r;
      end
      for (int lane = 0; lane < 2 * NG; lane++) begin
        if (row_valid_r && row_x_valid_r[lane])
          win_q[lane] <= selected_row_r[row_x_r[lane]];
        else
          win_q[lane] <= '0;
      end
    end
  end

`ifdef SIMULATION
  assert property (@(posedge clk) disable iff (!rst_n)
      start |-> ((cfg_fmap_w >= K) && (cfg_fmap_w <= MAX_FMAP_W) &&
                 (cfg_fmap_h >= K) && (cfg_fmap_h <= MAX_FMAP_H) &&
                 (cfg_c_in != 0) && (cfg_c_in <= MAX_C_IN) &&
                 (cfg_out_w != 0) && (cfg_out_h != 0)));
  assert property (@(posedge clk) disable iff (!rst_n)
      (state_r == S_WAIT_PREFETCH) |->
        (out_y_r != out_h_r - 1'b1));
  assert property (@(posedge clk) disable iff (!rst_n)
      ((state_r == S_LOAD) && en) |-> pix_valid);
  for (genvar g = 0; g < NG; g++) begin : g_assert_rate
    assert property (@(posedge clk) disable iff (!rst_n)
        rate_hold_c |-> !issue_valid_c);
  end
`endif

endmodule
