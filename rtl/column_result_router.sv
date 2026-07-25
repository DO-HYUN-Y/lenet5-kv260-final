`timescale 1ns/1ps
// column_result_router.sv -- deterministic column-aligned systolic egress.
//
// PE[g][c] completes at BASE_LATENCY+g+c accepted advances after the source
// tile-final token. With tile-final tokens spaced by at least NG advances,
// at most one physical row can complete in a fixed column per cycle. Each
// column therefore needs only a 4-to-1 row selector and one elastic output
// register, not a FIFO per PE.

module column_result_router #(
  parameter int ACC_W         = 32,
  parameter int NG            = 4,
  parameter int NC            = 8,
  parameter int OUT_W         = 9,
  parameter int OUT_H         = 9,
  parameter int OUT_ADDR_W    = 16,
  parameter int OUT_CH_W      = 8,
  parameter int LAYER_ID_W    = 3,
  parameter int GROUP_W       = (NG < 2) ? 1 : $clog2(NG),
  parameter int BASE_LATENCY  = 5
) (
  input  logic clk,
  input  logic rst_n,
  input  logic start,
  input  logic advance_in,

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

  output logic                    result_valid [0:NC-1],
  input  logic                    result_ready [0:NC-1],
  output logic signed [ACC_W-1:0] result_acc_lo [0:NC-1],
  output logic signed [ACC_W-1:0] result_acc_hi [0:NC-1],
  output logic [1:0]              result_lane_mask [0:NC-1],
  output logic [OUT_ADDR_W-1:0]   result_addr_lo [0:NC-1],
  output logic [OUT_ADDR_W-1:0]   result_addr_hi [0:NC-1],
  output logic [OUT_CH_W-1:0]     result_channel_lo [0:NC-1],
  output logic [OUT_CH_W-1:0]     result_channel_hi [0:NC-1],
  output logic [GROUP_W-1:0]      result_group [0:NC-1],
  output logic                    result_fc_mode [0:NC-1],
  output logic [LAYER_ID_W-1:0]   result_layer_id [0:NC-1]
);

  localparam int TILE       = 2 * NG;
  localparam int NUM_TILES  = (OUT_W + TILE - 1) / TILE;
  localparam int OUT_SIZE   = OUT_W * OUT_H;
  localparam int YW         = (OUT_H < 2) ? 1 : $clog2(OUT_H);
  localparam int TXW        = (NUM_TILES < 2) ? 1 : $clog2(NUM_TILES);

  typedef struct packed {
    logic                      valid;
    logic [1:0]                lane_mask;
    logic [OUT_ADDR_W-1:0]     addr_base;
    logic [OUT_ADDR_W-1:0]     position_base;
    logic [OUT_CH_W-1:0]       channel_base;
    logic [OUT_CH_W-1:0]       channel_count;
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
    logic [GROUP_W-1:0]        group_idx;
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
        if (issue_y_r == OUT_H - 1)
          issue_y_r <= '0;
        else
          issue_y_r <= issue_y_r + 1'b1;
      end else begin
        issue_tile_r <= issue_tile_r + 1'b1;
      end
    end
  end

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
            channel_count: cfg_out_channels,
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

  result_packet_t candidate_packet_c [0:NG-1][0:NC-1];
  logic candidate_valid_c [0:NG-1][0:NC-1];

  always_comb begin
    for (int g = 0; g < NG; g++) begin
      for (int c = 0; c < NC; c++) begin
        logic [OUT_CH_W-1:0] conv_ch;
        logic [OUT_CH_W-1:0] fc_offset_lo;
        logic [OUT_CH_W-1:0] fc_offset_hi;
        logic [OUT_CH_W-1:0] fc_ch_lo;
        logic [OUT_CH_W-1:0] fc_ch_hi;
        logic [OUT_ADDR_W-1:0] conv_lane_base;
        logic [1:0] legal_mask;

        conv_ch = tag_out[g][c].channel_base + OUT_CH_W'(c);
        fc_offset_lo = OUT_CH_W'(g * (2 * NC) + c * 2);
        fc_offset_hi = fc_offset_lo + 1'b1;
        fc_ch_lo = tag_out[g][c].channel_base + fc_offset_lo;
        fc_ch_hi = tag_out[g][c].channel_base + fc_offset_hi;
        conv_lane_base = tag_out[g][c].addr_base +
                         OUT_ADDR_W'(c * OUT_SIZE) +
                         tag_out[g][c].position_base +
                         OUT_ADDR_W'(2 * g);

        legal_mask = acc_valid_in[g][c] & tag_out[g][c].lane_mask;
        if (tag_out[g][c].fc_mode) begin
          legal_mask[0] = legal_mask[0] &&
                          (fc_offset_lo < tag_out[g][c].channel_count);
          legal_mask[1] = legal_mask[1] &&
                          (fc_offset_hi < tag_out[g][c].channel_count);
        end else if (OUT_CH_W'(c) >= tag_out[g][c].channel_count) begin
          legal_mask = 2'b00;
        end

        candidate_packet_c[g][c] = '0;
        candidate_packet_c[g][c].acc_lo = acc_lo_in[g][c];
        candidate_packet_c[g][c].acc_hi = acc_hi_in[g][c];
        candidate_packet_c[g][c].lane_mask = legal_mask;
        candidate_packet_c[g][c].group_idx = GROUP_W'(g);
        candidate_packet_c[g][c].fc_mode = tag_out[g][c].fc_mode;
        candidate_packet_c[g][c].layer_id = tag_out[g][c].layer_id;

        if (tag_out[g][c].fc_mode) begin
          candidate_packet_c[g][c].channel_lo = fc_ch_lo;
          candidate_packet_c[g][c].channel_hi = fc_ch_hi;
          candidate_packet_c[g][c].addr_lo =
              tag_out[g][c].addr_base + OUT_ADDR_W'(fc_offset_lo);
          candidate_packet_c[g][c].addr_hi =
              tag_out[g][c].addr_base + OUT_ADDR_W'(fc_offset_hi);
        end else begin
          candidate_packet_c[g][c].channel_lo = conv_ch;
          candidate_packet_c[g][c].channel_hi = conv_ch;
          candidate_packet_c[g][c].addr_lo = conv_lane_base;
          candidate_packet_c[g][c].addr_hi = conv_lane_base + 1'b1;
        end

        candidate_valid_c[g][c] =
            advance_in && tag_out[g][c].valid && (|legal_mask);
      end
    end
  end

  logic selected_valid_c [0:NC-1];
  result_packet_t selected_packet_c [0:NC-1];
  logic result_valid_r [0:NC-1];
  result_packet_t result_packet_r [0:NC-1];

  always_comb begin
    for (int c = 0; c < NC; c++) begin
      selected_valid_c[c] = 1'b0;
      selected_packet_c[c] = '0;
      for (int g = 0; g < NG; g++) begin
        if (!selected_valid_c[c] && candidate_valid_c[g][c]) begin
          selected_valid_c[c] = 1'b1;
          selected_packet_c[c] = candidate_packet_c[g][c];
        end
      end
    end

    ingress_ready = 1'b1;
    for (int c = 0; c < NC; c++)
      ingress_ready = ingress_ready &&
                      (!result_valid_r[c] || result_ready[c]);
  end

  always_ff @(posedge clk) begin
    if (!rst_n || start) begin
      for (int c = 0; c < NC; c++) begin
        result_valid_r[c] <= 1'b0;
        result_packet_r[c] <= '0;
      end
    end else begin
      for (int c = 0; c < NC; c++) begin
        if (!result_valid_r[c] || result_ready[c]) begin
          result_valid_r[c] <= selected_valid_c[c];
          if (selected_valid_c[c])
            result_packet_r[c] <= selected_packet_c[c];
        end
      end
    end
  end

  always_comb begin
    idle = 1'b1;
    for (int c = 0; c < NC; c++) begin
      result_valid[c]      = result_valid_r[c];
      result_acc_lo[c]     = result_packet_r[c].acc_lo;
      result_acc_hi[c]     = result_packet_r[c].acc_hi;
      result_lane_mask[c]  = result_packet_r[c].lane_mask;
      result_addr_lo[c]    = result_packet_r[c].addr_lo;
      result_addr_hi[c]    = result_packet_r[c].addr_hi;
      result_channel_lo[c] = result_packet_r[c].channel_lo;
      result_channel_hi[c] = result_packet_r[c].channel_hi;
      result_group[c]      = result_packet_r[c].group_idx;
      result_fc_mode[c]    = result_packet_r[c].fc_mode;
      result_layer_id[c]   = result_packet_r[c].layer_id;
      idle = idle && !result_valid_r[c];
    end
    for (int g = 0; g < NG; g++) begin
      idle = idle && !tag_pending[g];
      for (int c = 0; c < NC; c++)
        idle = idle && !(|acc_valid_in[g][c]);
    end
  end

`ifdef SIMULATION
  for (genvar ac = 0; ac < NC; ac++) begin : g_assert_col
    logic [NG-1:0] candidate_valid_vec;
    for (genvar ag = 0; ag < NG; ag++) begin : g_candidate_vec
      assign candidate_valid_vec[ag] = candidate_valid_c[ag][ac];
    end
    assert property (@(posedge clk) disable iff (!rst_n)
        $onehot0(candidate_valid_vec));
    assert property (@(posedge clk) disable iff (!rst_n)
        (result_valid[ac] && !result_ready[ac]) |=> $stable({
          result_acc_lo[ac], result_acc_hi[ac], result_lane_mask[ac],
          result_addr_lo[ac], result_addr_hi[ac],
          result_channel_lo[ac], result_channel_hi[ac],
          result_group[ac], result_fc_mode[ac], result_layer_id[ac]
        }));
  end
  for (genvar ag = 0; ag < NG; ag++) begin : g_assert_tag_row
    for (genvar ac = 0; ac < NC; ac++) begin : g_assert_tag_col
      assert property (@(posedge clk) disable iff (!rst_n)
          tag_out[ag][ac].valid == (|acc_valid_in[ag][ac]));
    end
  end
`endif

endmodule
