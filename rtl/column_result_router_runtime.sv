`timescale 1ns/1ps
// column_result_router_runtime.sv -- C1/C3 runtime CHW address mapping.

module column_result_router_runtime #(
  parameter int ACC_W        = 32,
  parameter int NG           = 4,
  parameter int NC           = 8,
  parameter int DIM_W        = 6,
  parameter int OUT_ADDR_W   = 16,
  parameter int OUT_CH_W     = 8,
  parameter int LAYER_ID_W   = 3,
  parameter int GROUP_W      = (NG < 2) ? 1 : $clog2(NG),
  parameter int BASE_LATENCY = 5,
  parameter int MAX_TILES    = 4,
  parameter int TILE_W       =
      (MAX_TILES < 2) ? 1 : $clog2(MAX_TILES + 1)
) (
  input  logic clk,
  input  logic rst_n,
  input  logic start,
  input  logic advance_in,
  input  logic issue_last,
  input  logic [1:0] issue_lane_mask [0:NG-1],

  input  logic [DIM_W-1:0]      cfg_out_w,
  input  logic [DIM_W-1:0]      cfg_out_h,
  input  logic [OUT_ADDR_W-1:0] cfg_out_plane_size,
  input  logic [OUT_ADDR_W-1:0] cfg_out_base_addr,
  input  logic [OUT_CH_W-1:0]   cfg_out_ch_base,
  input  logic [OUT_CH_W-1:0]   cfg_pass_channels,
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

  localparam int TILE = 2 * NG;

  logic [DIM_W-1:0] out_w_r;
  logic [DIM_W-1:0] out_h_r;
  logic [OUT_ADDR_W-1:0] plane_size_r;
  logic [OUT_ADDR_W-1:0] out_base_r;
  logic [OUT_CH_W-1:0] ch_base_r;
  logic [OUT_CH_W-1:0] pass_channels_r;
  logic [LAYER_ID_W-1:0] layer_id_r;
  logic [TILE_W-1:0] num_tiles_r;
  logic [DIM_W-1:0] issue_y_r;
  logic [TILE_W-1:0] issue_tile_r;
  logic [OUT_ADDR_W-1:0] issue_row_position_r;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      out_w_r <= '0;
      out_h_r <= '0;
      plane_size_r <= '0;
      out_base_r <= '0;
      ch_base_r <= '0;
      pass_channels_r <= '0;
      layer_id_r <= '0;
      num_tiles_r <= '0;
      issue_y_r <= '0;
      issue_tile_r <= '0;
      issue_row_position_r <= '0;
    end else if (start) begin
      out_w_r <= cfg_out_w;
      out_h_r <= cfg_out_h;
      plane_size_r <= cfg_out_plane_size;
      out_base_r <= cfg_out_base_addr;
      ch_base_r <= cfg_out_ch_base;
      pass_channels_r <= cfg_pass_channels;
      layer_id_r <= cfg_layer_id;
      num_tiles_r <=
          TILE_W'((int'(cfg_out_w) + TILE - 1) / TILE);
      issue_y_r <= '0;
      issue_tile_r <= '0;
      issue_row_position_r <= '0;
    end else if (advance_in && issue_last) begin
      if (issue_tile_r == num_tiles_r - 1'b1) begin
        issue_tile_r <= '0;
        if (issue_y_r == out_h_r - 1'b1) begin
          issue_y_r <= '0;
          issue_row_position_r <= '0;
        end else begin
          issue_y_r <= issue_y_r + 1'b1;
          issue_row_position_r <=
              issue_row_position_r + OUT_ADDR_W'(out_w_r);
        end
      end else begin
        issue_tile_r <= issue_tile_r + 1'b1;
      end
    end
  end

  logic [OUT_ADDR_W-1:0] issue_position_c;
  logic [OUT_ADDR_W-1:0] issue_addr_base_c;
  always_comb begin
    issue_position_c =
        issue_row_position_r +
        OUT_ADDR_W'(issue_tile_r) * OUT_ADDR_W'(TILE);
    issue_addr_base_c =
        out_base_r + OUT_ADDR_W'(ch_base_r) * plane_size_r;
  end

  typedef struct packed {
    logic valid;
    logic [1:0] lane_mask;
    logic [OUT_ADDR_W-1:0] addr_base;
    logic [OUT_ADDR_W-1:0] position_base;
    logic [OUT_ADDR_W-1:0] plane_size;
    logic [OUT_CH_W-1:0] channel_base;
    logic [OUT_CH_W-1:0] channel_count;
    logic [LAYER_ID_W-1:0] layer_id;
  } route_tag_t;

  typedef struct packed {
    logic signed [ACC_W-1:0] acc_lo;
    logic signed [ACC_W-1:0] acc_hi;
    logic [1:0] lane_mask;
    logic [OUT_ADDR_W-1:0] addr_lo;
    logic [OUT_ADDR_W-1:0] addr_hi;
    logic [OUT_CH_W-1:0] channel;
    logic [GROUP_W-1:0] group_idx;
    logic [LAYER_ID_W-1:0] layer_id;
  } packet_t;

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
            valid: issue_last && (|issue_lane_mask[g]),
            lane_mask: issue_lane_mask[g],
            addr_base: issue_addr_base_c,
            position_base: issue_position_c,
            plane_size: plane_size_r,
            channel_base: ch_base_r,
            channel_count: pass_channels_r,
            layer_id: layer_id_r
          };
          for (int i = 1; i < ROW_LAT; i++)
            tag_pipe[i] <= tag_pipe[i-1];
        end
      end

      always_comb begin
        tag_pending[g] = 1'b0;
        for (int i = 0; i < ROW_LAT; i++)
          tag_pending[g] |= tag_pipe[i].valid;
      end

      for (genvar c = 0; c < NC; c++) begin : g_tag_tap
        assign tag_out[g][c] =
            tag_pipe[BASE_LATENCY + g + c - 1];
      end
    end
  endgenerate

  packet_t candidate_packet_c [0:NG-1][0:NC-1];
  logic candidate_valid_c [0:NG-1][0:NC-1];

  always_comb begin
    for (int g = 0; g < NG; g++) begin
      for (int c = 0; c < NC; c++) begin
        logic [OUT_CH_W-1:0] channel;
        logic [OUT_ADDR_W-1:0] lane_base;
        logic [1:0] legal_mask;
        channel = tag_out[g][c].channel_base + OUT_CH_W'(c);
        lane_base =
            tag_out[g][c].addr_base +
            OUT_ADDR_W'(c) * tag_out[g][c].plane_size +
            tag_out[g][c].position_base + OUT_ADDR_W'(2 * g);
        legal_mask =
            acc_valid_in[g][c] & tag_out[g][c].lane_mask;
        if (OUT_CH_W'(c) >= tag_out[g][c].channel_count)
          legal_mask = 2'b00;

        candidate_packet_c[g][c] = '0;
        candidate_packet_c[g][c].acc_lo = acc_lo_in[g][c];
        candidate_packet_c[g][c].acc_hi = acc_hi_in[g][c];
        candidate_packet_c[g][c].lane_mask = legal_mask;
        candidate_packet_c[g][c].addr_lo = lane_base;
        candidate_packet_c[g][c].addr_hi = lane_base + 1'b1;
        candidate_packet_c[g][c].channel = channel;
        candidate_packet_c[g][c].group_idx = GROUP_W'(g);
        candidate_packet_c[g][c].layer_id =
            tag_out[g][c].layer_id;
        candidate_valid_c[g][c] =
            advance_in && tag_out[g][c].valid && (|legal_mask);
      end
    end
  end

  logic selected_valid_c [0:NC-1];
  packet_t selected_packet_c [0:NC-1];
  logic slot_valid_r [0:NC-1];
  packet_t slot_packet_r [0:NC-1];

  always_comb begin
    ingress_ready = 1'b1;
    for (int c = 0; c < NC; c++) begin
      selected_valid_c[c] = 1'b0;
      selected_packet_c[c] = '0;
      for (int g = 0; g < NG; g++) begin
        if (!selected_valid_c[c] && candidate_valid_c[g][c]) begin
          selected_valid_c[c] = 1'b1;
          selected_packet_c[c] = candidate_packet_c[g][c];
        end
      end
      ingress_ready &=
          (!slot_valid_r[c] || result_ready[c]);
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n || start) begin
      for (int c = 0; c < NC; c++) begin
        slot_valid_r[c] <= 1'b0;
        slot_packet_r[c] <= '0;
      end
    end else begin
      for (int c = 0; c < NC; c++) begin
        if (!slot_valid_r[c] || result_ready[c]) begin
          slot_valid_r[c] <= selected_valid_c[c];
          if (selected_valid_c[c])
            slot_packet_r[c] <= selected_packet_c[c];
        end
      end
    end
  end

  always_comb begin
    idle = 1'b1;
    for (int c = 0; c < NC; c++) begin
      result_valid[c] = slot_valid_r[c];
      result_acc_lo[c] = slot_packet_r[c].acc_lo;
      result_acc_hi[c] = slot_packet_r[c].acc_hi;
      result_lane_mask[c] = slot_packet_r[c].lane_mask;
      result_addr_lo[c] = slot_packet_r[c].addr_lo;
      result_addr_hi[c] = slot_packet_r[c].addr_hi;
      result_channel_lo[c] = slot_packet_r[c].channel;
      result_channel_hi[c] = slot_packet_r[c].channel;
      result_group[c] = slot_packet_r[c].group_idx;
      result_fc_mode[c] = 1'b0;
      result_layer_id[c] = slot_packet_r[c].layer_id;
      idle &= !slot_valid_r[c];
      for (int g = 0; g < NG; g++)
        idle &= !(|acc_valid_in[g][c]);
    end
    for (int g = 0; g < NG; g++)
      idle &= !tag_pending[g];
  end

`ifdef SIMULATION
  for (genvar c = 0; c < NC; c++) begin : g_assert_col
    logic [NG-1:0] candidate_vec;
    for (genvar g = 0; g < NG; g++) begin : g_vec
      assign candidate_vec[g] = candidate_valid_c[g][c];
      assert property (@(posedge clk) disable iff (!rst_n)
          tag_out[g][c].valid == (|acc_valid_in[g][c]));
    end
    assert property (@(posedge clk) disable iff (!rst_n)
        $onehot0(candidate_vec));
    assert property (@(posedge clk) disable iff (!rst_n)
        (result_valid[c] && !result_ready[c]) |=> $stable({
          result_acc_lo[c], result_acc_hi[c], result_lane_mask[c],
          result_addr_lo[c], result_addr_hi[c], result_channel_lo[c],
          result_group[c], result_layer_id[c]
        }));
  end
`endif

endmodule
