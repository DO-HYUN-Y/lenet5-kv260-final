`timescale 1ns/1ps
// fc_result_router.sv -- column-aligned FC result mapping and skid slots.

module fc_result_router #(
  parameter int ACC_W       = 32,
  parameter int NG          = 4,
  parameter int NC          = 8,
  parameter int OUT_ADDR_W  = 16,
  parameter int OUT_CH_W    = 8,
  parameter int LAYER_ID_W  = 3,
  parameter int GROUP_W     = (NG < 2) ? 1 : $clog2(NG)
) (
  input  logic clk,
  input  logic rst_n,
  input  logic start,
  input  logic advance_in,

  input  logic [OUT_ADDR_W-1:0] cfg_out_base_addr,
  input  logic [OUT_CH_W-1:0]   cfg_out_ch_base,
  input  logic [OUT_CH_W-1:0]   cfg_out_channels,
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

  typedef struct packed {
    logic signed [ACC_W-1:0] acc_lo;
    logic signed [ACC_W-1:0] acc_hi;
    logic [1:0] lane_mask;
    logic [OUT_ADDR_W-1:0] addr_lo;
    logic [OUT_ADDR_W-1:0] addr_hi;
    logic [OUT_CH_W-1:0] channel_lo;
    logic [OUT_CH_W-1:0] channel_hi;
    logic [GROUP_W-1:0] group_idx;
    logic [LAYER_ID_W-1:0] layer_id;
  } packet_t;

  logic candidate_valid_c [0:NG-1][0:NC-1];
  packet_t candidate_packet_c [0:NG-1][0:NC-1];
  logic selected_valid_c [0:NC-1];
  packet_t selected_packet_c [0:NC-1];
  logic slot_valid_r [0:NC-1];
  packet_t slot_packet_r [0:NC-1];

  always_comb begin
    for (int g = 0; g < NG; g++) begin
      for (int c = 0; c < NC; c++) begin
        logic [OUT_CH_W-1:0] lane_id_lo;
        logic [OUT_CH_W-1:0] lane_id_hi;
        logic [OUT_CH_W-1:0] channel_lo;
        logic [OUT_CH_W-1:0] channel_hi;
        logic [1:0] legal_mask;

        lane_id_lo = OUT_CH_W'(g * 2 * NC + 2 * c);
        lane_id_hi = lane_id_lo + 1'b1;
        channel_lo = cfg_out_ch_base + lane_id_lo;
        channel_hi = cfg_out_ch_base + lane_id_hi;
        legal_mask = acc_valid_in[g][c];
        legal_mask[0] = legal_mask[0] &&
                        (channel_lo < cfg_out_channels);
        legal_mask[1] = legal_mask[1] &&
                        (channel_hi < cfg_out_channels);

        candidate_packet_c[g][c] = '0;
        candidate_packet_c[g][c].acc_lo = acc_lo_in[g][c];
        candidate_packet_c[g][c].acc_hi = acc_hi_in[g][c];
        candidate_packet_c[g][c].lane_mask = legal_mask;
        candidate_packet_c[g][c].addr_lo =
            cfg_out_base_addr + OUT_ADDR_W'(channel_lo);
        candidate_packet_c[g][c].addr_hi =
            cfg_out_base_addr + OUT_ADDR_W'(channel_hi);
        candidate_packet_c[g][c].channel_lo = channel_lo;
        candidate_packet_c[g][c].channel_hi = channel_hi;
        candidate_packet_c[g][c].group_idx = GROUP_W'(g);
        candidate_packet_c[g][c].layer_id = cfg_layer_id;
        candidate_valid_c[g][c] =
            advance_in && (|legal_mask);
      end
    end

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
      ingress_ready = ingress_ready &&
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
      result_channel_lo[c] = slot_packet_r[c].channel_lo;
      result_channel_hi[c] = slot_packet_r[c].channel_hi;
      result_group[c] = slot_packet_r[c].group_idx;
      result_fc_mode[c] = 1'b1;
      result_layer_id[c] = slot_packet_r[c].layer_id;
      idle = idle && !slot_valid_r[c];
      for (int g = 0; g < NG; g++)
        idle = idle && !(|acc_valid_in[g][c]);
    end
  end

`ifdef SIMULATION
  for (genvar c = 0; c < NC; c++) begin : g_assert_col
    logic [NG-1:0] candidate_vec;
    for (genvar g = 0; g < NG; g++) begin : g_vec
      assign candidate_vec[g] = candidate_valid_c[g][c];
    end
    assert property (@(posedge clk) disable iff (!rst_n)
        $onehot0(candidate_vec));
    assert property (@(posedge clk) disable iff (!rst_n)
        (result_valid[c] && !result_ready[c]) |=> $stable({
          result_acc_lo[c], result_acc_hi[c], result_lane_mask[c],
          result_addr_lo[c], result_addr_hi[c],
          result_channel_lo[c], result_channel_hi[c],
          result_group[c], result_layer_id[c]
        }));
  end
`endif

endmodule
