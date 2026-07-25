`timescale 1ns/1ps
// output_router.sv -- cycle-aligned, row-parallel systolic egress.
//
// A fixed systolic row can produce at most NC PE packets for one issue, and
// different rows are independent. Four row streams therefore preserve the
// array's natural maximum of four packets (eight packed lanes) per cycle
// without a timing-expensive 32-to-1 global selector.
//
// Contract:
// - issue_last/lane_mask describe the source tile ending on this advance.
// - advance_in is the exact source/skew/SA clock enable.
// - Tag latency to PE[g][c] is BASE_LATENCY+g+c advances.
// - A short FIFO per PE absorbs overlapping structural-skip waves.
// - ingress_ready freezes the complete compute pipeline before any FIFO can
//   overflow. Row outputs continue draining independently.
// - result_addr is authoritative; output order between rows is irrelevant.

module output_router #(
  parameter int ACC_W         = 32,
  parameter int NG            = 4,
  parameter int NC            = 8,
  parameter int OUT_W         = 9,
  parameter int OUT_H         = 9,
  parameter int OUT_ADDR_W    = 16,
  parameter int OUT_CH_W      = 8,
  parameter int LAYER_ID_W    = 3,
  parameter int BASE_LATENCY  = 5,
  parameter int QUEUE_DEPTH   = 4
) (
  input  logic clk,
  input  logic rst_n,
  input  logic start,
  input  logic advance_in,
  input  logic drain_en,

  input  logic       issue_last,
  input  logic [1:0] issue_lane_mask [0:NG-1],

  input  logic [OUT_ADDR_W-1:0] cfg_out_base_addr,
  input  logic [OUT_CH_W-1:0]   cfg_out_ch_base,
  input  logic [OUT_CH_W-1:0]   cfg_out_channels,
  input  logic                  cfg_fc_mode,
  input  logic [LAYER_ID_W-1:0] cfg_layer_id,

  input  logic signed [ACC_W-1:0] acc_lo_in [0:NG-1][0:NC-1],
  input  logic signed [ACC_W-1:0] acc_hi_in [0:NG-1][0:NC-1],
  input  logic [1:0]              acc_valid_in [0:NG-1][0:NC-1],

  output logic ingress_ready,
  output logic idle,

  output logic                    result_valid [0:NG-1],
  input  logic                    result_ready [0:NG-1],
  output logic signed [ACC_W-1:0] result_acc_lo [0:NG-1],
  output logic signed [ACC_W-1:0] result_acc_hi [0:NG-1],
  output logic [1:0]              result_lane_mask [0:NG-1],
  output logic [OUT_ADDR_W-1:0]   result_addr_lo [0:NG-1],
  output logic [OUT_ADDR_W-1:0]   result_addr_hi [0:NG-1],
  output logic [OUT_CH_W-1:0]     result_channel_lo [0:NG-1],
  output logic [OUT_CH_W-1:0]     result_channel_hi [0:NG-1],
  output logic                    result_fc_mode [0:NG-1],
  output logic [LAYER_ID_W-1:0]   result_layer_id [0:NG-1]
);

  localparam int TILE       = 2 * NG;
  localparam int NUM_TILES  = (OUT_W + TILE - 1) / TILE;
  localparam int OUT_SIZE   = OUT_W * OUT_H;
  localparam int CW         = (NC < 2) ? 1 : $clog2(NC);
  localparam int QPW        = (QUEUE_DEPTH < 2) ? 1 : $clog2(QUEUE_DEPTH);
  localparam int QCW        = $clog2(QUEUE_DEPTH + 1);
  localparam int YW         = (OUT_H < 2) ? 1 : $clog2(OUT_H);
  localparam int TXW        = (NUM_TILES < 2) ? 1 : $clog2(NUM_TILES);

  typedef struct packed {
    logic                      valid;
    logic [1:0]                lane_mask;
    logic [OUT_ADDR_W-1:0]     addr_base;
    logic [OUT_ADDR_W-1:0]     position_base;
    logic [OUT_CH_W-1:0]       channel_base;
    logic [OUT_CH_W-1:0]       channel_limit;
    logic                      fc_mode;
    logic [LAYER_ID_W-1:0]     layer_id;
  } route_tag_t;

  typedef struct packed {
    logic signed [ACC_W-1:0]   acc_lo;
    logic signed [ACC_W-1:0]   acc_hi;
    logic [1:0]                lane_mask;
    logic [OUT_ADDR_W-1:0]     addr_lo;
    logic [OUT_ADDR_W-1:0]     addr_hi;
    logic [OUT_CH_W-1:0]       channel_lo;
    logic [OUT_CH_W-1:0]       channel_hi;
    logic                      fc_mode;
    logic [LAYER_ID_W-1:0]     layer_id;
  } result_packet_t;

  logic [YW-1:0]  issue_y_r;
  logic [TXW-1:0] issue_tile_r;
  (* use_dsp = "no" *) logic [OUT_ADDR_W-1:0] issue_channel_offset_c;
  (* use_dsp = "no" *) logic [OUT_ADDR_W-1:0] issue_row_offset_c;
  logic [OUT_ADDR_W-1:0] issue_addr_base_c;
  logic [OUT_ADDR_W-1:0] issue_position_base_c;

  always_comb begin
    issue_channel_offset_c =
        OUT_ADDR_W'(cfg_out_ch_base) * OUT_ADDR_W'(OUT_SIZE);
    issue_row_offset_c = OUT_ADDR_W'(issue_y_r) * OUT_ADDR_W'(OUT_W);
    if (cfg_fc_mode)
      issue_addr_base_c = cfg_out_base_addr + OUT_ADDR_W'(cfg_out_ch_base);
    else
      issue_addr_base_c = cfg_out_base_addr + issue_channel_offset_c;
    issue_position_base_c = issue_row_offset_c +
                            OUT_ADDR_W'(issue_tile_r) * OUT_ADDR_W'(TILE);
  end

  always_ff @(posedge clk) begin
    if (!rst_n || start) begin
      issue_y_r    <= '0;
      issue_tile_r <= '0;
    end else if (advance_in && issue_last && !cfg_fc_mode) begin
      if (issue_tile_r == NUM_TILES - 1) begin
        issue_tile_r <= '0;
        if (issue_y_r == OUT_H - 1) issue_y_r <= '0;
        else issue_y_r <= issue_y_r + 1'b1;
      end else begin
        issue_tile_r <= issue_tile_r + 1'b1;
      end
    end
  end

  // One shared tag shift chain per physical row. Column c taps a different
  // stage, removing the large duplicated prefixes of one chain per PE.
  route_tag_t tag_out [0:NG-1][0:NC-1];
  logic tag_pending [0:NG-1];
  generate
    for (genvar g = 0; g < NG; g++) begin : g_tag_row
      localparam int ROW_LAT = BASE_LATENCY + g + NC;
      route_tag_t tag_pipe [0:ROW_LAT-1];

      always_ff @(posedge clk) begin
        if (!rst_n || start) begin
          for (int i = 0; i < ROW_LAT; i++) tag_pipe[i] <= '0;
        end else if (advance_in) begin
          tag_pipe[0] <= '{
            valid:         issue_last && (|issue_lane_mask[g]),
            lane_mask:     issue_lane_mask[g],
            addr_base:     issue_addr_base_c,
            position_base: issue_position_base_c,
            channel_base:  cfg_out_ch_base,
            channel_limit: cfg_out_channels,
            fc_mode:       cfg_fc_mode,
            layer_id:      cfg_layer_id
          };
          for (int i = 1; i < ROW_LAT; i++)
            tag_pipe[i] <= tag_pipe[i-1];
        end
      end

      always_comb begin
        tag_pending[g] = 1'b0;
        for (int i = 0; i < ROW_LAT; i++)
          tag_pending[g] = tag_pending[g] | tag_pipe[i].valid;
      end

      for (genvar c = 0; c < NC; c++) begin : g_tag_tap
        assign tag_out[g][c] = tag_pipe[BASE_LATENCY + g + c - 1];
      end
    end
  endgenerate

  result_packet_t enq_packet_c [0:NG-1][0:NC-1];
  logic enq_valid_c [0:NG-1][0:NC-1];

  always_comb begin
    for (int g = 0; g < NG; g++) begin
      for (int c = 0; c < NC; c++) begin
        logic [OUT_CH_W-1:0] conv_ch;
        logic [OUT_CH_W-1:0] fc_ch_lo;
        logic [OUT_CH_W-1:0] fc_ch_hi;
        logic [OUT_ADDR_W-1:0] conv_lane_base;
        logic [OUT_ADDR_W-1:0] fc_lane_offset;
        logic [1:0] legal_mask;

        conv_ch = tag_out[g][c].channel_base + OUT_CH_W'(c);
        fc_ch_lo = tag_out[g][c].channel_base +
                   OUT_CH_W'(g * (2 * NC) + c * 2);
        fc_ch_hi = fc_ch_lo + 1'b1;
        conv_lane_base = tag_out[g][c].addr_base +
                         OUT_ADDR_W'(c * OUT_SIZE) +
                         tag_out[g][c].position_base +
                         OUT_ADDR_W'(2 * g);
        fc_lane_offset = OUT_ADDR_W'(g * (2 * NC) + c * 2);

        legal_mask = acc_valid_in[g][c] & tag_out[g][c].lane_mask;
        if (tag_out[g][c].fc_mode) begin
          legal_mask[0] = legal_mask[0] &&
                          (fc_ch_lo < tag_out[g][c].channel_limit);
          legal_mask[1] = legal_mask[1] &&
                          (fc_ch_hi < tag_out[g][c].channel_limit);
        end else if (conv_ch >= tag_out[g][c].channel_limit) begin
          legal_mask = 2'b00;
        end

        enq_packet_c[g][c] = '0;
        enq_packet_c[g][c].acc_lo = acc_lo_in[g][c];
        enq_packet_c[g][c].acc_hi = acc_hi_in[g][c];
        enq_packet_c[g][c].lane_mask = legal_mask;
        enq_packet_c[g][c].fc_mode = tag_out[g][c].fc_mode;
        enq_packet_c[g][c].layer_id = tag_out[g][c].layer_id;

        if (tag_out[g][c].fc_mode) begin
          enq_packet_c[g][c].channel_lo = fc_ch_lo;
          enq_packet_c[g][c].channel_hi = fc_ch_hi;
          enq_packet_c[g][c].addr_lo =
              tag_out[g][c].addr_base + fc_lane_offset;
          enq_packet_c[g][c].addr_hi =
              tag_out[g][c].addr_base + fc_lane_offset + 1'b1;
        end else begin
          enq_packet_c[g][c].channel_lo = conv_ch;
          enq_packet_c[g][c].channel_hi = conv_ch;
          enq_packet_c[g][c].addr_lo = conv_lane_base;
          enq_packet_c[g][c].addr_hi = conv_lane_base + 1'b1;
        end

        enq_valid_c[g][c] =
            advance_in && tag_out[g][c].valid && (|legal_mask);
      end
    end
  end

  result_packet_t queue_mem_r [0:NG-1][0:NC-1][0:QUEUE_DEPTH-1];
  logic [QPW-1:0] queue_head_ptr_r [0:NG-1][0:NC-1];
  logic [QPW-1:0] queue_tail_ptr_r [0:NG-1][0:NC-1];
  logic [QCW-1:0] queue_count_r [0:NG-1][0:NC-1];

  logic [CW-1:0] rr_col_r [0:NG-1];
  logic select_valid_c [0:NG-1];
  logic [CW-1:0] select_col_c [0:NG-1];
  logic pop_queue_c [0:NG-1];
  logic dequeue_c [0:NG-1][0:NC-1];
  logic result_valid_r [0:NG-1];
  result_packet_t result_packet_r [0:NG-1];

  always_comb begin
    for (int g = 0; g < NG; g++) begin
      select_valid_c[g] = 1'b0;
      select_col_c[g] = rr_col_r[g];
      for (int offset = 0; offset < NC; offset++) begin
        int col;
        col = rr_col_r[g] + offset;
        if (col >= NC) col = col - NC;
        if (!select_valid_c[g] && (queue_count_r[g][col] != 0)) begin
          select_valid_c[g] = 1'b1;
          select_col_c[g] = CW'(col);
        end
      end
      pop_queue_c[g] = drain_en && !start &&
                       (!result_valid_r[g] || result_ready[g]) &&
                       select_valid_c[g];
      for (int c = 0; c < NC; c++)
        dequeue_c[g][c] =
            pop_queue_c[g] && (select_col_c[g] == CW'(c));
    end

    // Deliberately do not depend on same-edge dequeue. This keeps the global
    // compute enable off the arbitration critical path; a full FIFO incurs
    // one conservative recovery cycle.
    ingress_ready = 1'b1;
    for (int g = 0; g < NG; g++)
      for (int c = 0; c < NC; c++)
        if (queue_count_r[g][c] == QUEUE_DEPTH)
          ingress_ready = 1'b0;
  end

  always_ff @(posedge clk) begin
    if (!rst_n || start) begin
      for (int g = 0; g < NG; g++) begin
        for (int c = 0; c < NC; c++) begin
          queue_head_ptr_r[g][c] <= '0;
          queue_tail_ptr_r[g][c] <= '0;
          queue_count_r[g][c] <= '0;
        end
      end
    end else begin
      for (int g = 0; g < NG; g++) begin
        for (int c = 0; c < NC; c++) begin
          if (enq_valid_c[g][c]) begin
            queue_mem_r[g][c][queue_tail_ptr_r[g][c]] <=
                enq_packet_c[g][c];
            if (queue_tail_ptr_r[g][c] == QUEUE_DEPTH - 1)
              queue_tail_ptr_r[g][c] <= '0;
            else
              queue_tail_ptr_r[g][c] <=
                  queue_tail_ptr_r[g][c] + 1'b1;
          end
          if (dequeue_c[g][c]) begin
            if (queue_head_ptr_r[g][c] == QUEUE_DEPTH - 1)
              queue_head_ptr_r[g][c] <= '0;
            else
              queue_head_ptr_r[g][c] <=
                  queue_head_ptr_r[g][c] + 1'b1;
          end
          case ({enq_valid_c[g][c], dequeue_c[g][c]})
            2'b10: queue_count_r[g][c] <= queue_count_r[g][c] + 1'b1;
            2'b01: queue_count_r[g][c] <= queue_count_r[g][c] - 1'b1;
            default: queue_count_r[g][c] <= queue_count_r[g][c];
          endcase
        end
      end
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n || start) begin
      for (int g = 0; g < NG; g++) begin
        rr_col_r[g]        <= '0;
        result_valid_r[g]  <= 1'b0;
        result_packet_r[g] <= '0;
      end
    end else if (drain_en) begin
      for (int g = 0; g < NG; g++) begin
        if (!result_valid_r[g] || result_ready[g]) begin
          if (select_valid_c[g]) begin
            result_valid_r[g] <= 1'b1;
            result_packet_r[g] <=
                queue_mem_r[g][select_col_c[g]]
                           [queue_head_ptr_r[g][select_col_c[g]]];
            if (select_col_c[g] == NC - 1) rr_col_r[g] <= '0;
            else rr_col_r[g] <= select_col_c[g] + 1'b1;
          end else begin
            result_valid_r[g] <= 1'b0;
          end
        end
      end
    end
  end

  always_comb begin
    idle = 1'b1;
    for (int g = 0; g < NG; g++) begin
      result_valid[g]      = result_valid_r[g];
      result_acc_lo[g]     = result_packet_r[g].acc_lo;
      result_acc_hi[g]     = result_packet_r[g].acc_hi;
      result_lane_mask[g]  = result_packet_r[g].lane_mask;
      result_addr_lo[g]    = result_packet_r[g].addr_lo;
      result_addr_hi[g]    = result_packet_r[g].addr_hi;
      result_channel_lo[g] = result_packet_r[g].channel_lo;
      result_channel_hi[g] = result_packet_r[g].channel_hi;
      result_fc_mode[g]    = result_packet_r[g].fc_mode;
      result_layer_id[g]   = result_packet_r[g].layer_id;

      idle = idle && !result_valid_r[g] && !tag_pending[g];
      for (int c = 0; c < NC; c++) begin
        idle = idle && (queue_count_r[g][c] == 0);
        idle = idle && !(|acc_valid_in[g][c]);
      end
    end
  end

`ifdef SIMULATION
  assert property (@(posedge clk) disable iff (!rst_n)
      advance_in |-> ingress_ready);

  for (genvar ag = 0; ag < NG; ag++) begin : g_assert_row
    assert property (@(posedge clk) disable iff (!rst_n)
        (result_valid[ag] && !result_ready[ag]) |=> $stable({
          result_acc_lo[ag], result_acc_hi[ag], result_lane_mask[ag],
          result_addr_lo[ag], result_addr_hi[ag],
          result_channel_lo[ag], result_channel_hi[ag],
          result_fc_mode[ag], result_layer_id[ag]
        }));
    for (genvar ac = 0; ac < NC; ac++) begin : g_assert_col
      assert property (@(posedge clk) disable iff (!rst_n)
          tag_out[ag][ac].valid == (|acc_valid_in[ag][ac]));
      assert property (@(posedge clk) disable iff (!rst_n)
          queue_count_r[ag][ac] <= QUEUE_DEPTH);
    end
  end
`endif

endmodule
