`timescale 1ns/1ps

// Banked logical M8xN128 / 2xM8xN64 AlexNet systolic array.
//
// The physical compute fabric is always eight independent M8xN16 banks.  In
// wide mode every bank consumes source group zero and the banks collectively
// cover one M8xN128 output tile.  In split mode banks 0..3 consume source
// group zero while banks 4..7 consume source group one, allowing two
// independent M8xN64 spatial tiles to execute concurrently.  No bitstream or
// physical routing changes when the mode changes; only the registered bank
// source at a quiescent tile boundary changes.
//
// Keeping the systolic skew local to N16 avoids the quadratic N128 input-skew
// storage and gives every four-bank cluster an independent CE.  The caller
// owns tile scheduling, weight-bank addressing and ordered result retirement.
module alexnet_sa_m8n128_dynamic #(
    parameter int TILE_TAG_W = 16
) (
    input logic clk,
    input logic rst,

    // 0: one M8xN128 tile, 1: two independent M8xN64 tiles.
    // The mode must remain stable from tile_clear through the final source
    // issue for both groups.
    input logic mode_split_n64,

    // Runtime bank clock-enable mask.  This permits bandwidth-matched FC
    // operation (for example one N16 bank on one 128-bit HP port) without
    // toggling the other physical DSP banks.
    input logic [7:0] bank_enable,

    input logic group_ce [0:1],
    input logic signed [7:0] group_act_lo [0:1][0:3],
    input logic signed [7:0] group_act_hi [0:1][0:3],
    input logic group_issue_valid [0:1],
    input logic group_tile_clear [0:1],
    input logic group_reduce_last [0:1],
    input logic [1:0] group_m_lane_mask [0:1][0:3],
    input logic [TILE_TAG_W-1:0] group_tile_tag [0:1],

    // One independent N16 weight word per physical bank.  Wide mode maps
    // bank b to logical N16 slot b.  Split mode maps each four-bank cluster to
    // slots 0..3 of its own N64 tile.
    input logic signed [7:0] bank_weight [0:7][0:15],

    output logic result_valid [0:7][0:3][0:15],
    input  logic result_ready [0:7][0:3][0:15],
    output logic signed [31:0] result_lo [0:7][0:3][0:15],
    output logic signed [31:0] result_hi [0:7][0:3][0:15],
    output logic [1:0] result_lane_mask [0:7][0:3][0:15],

    // Tile metadata is captured locally so independently completed clusters
    // can be reordered by downstream N16 result sinks.
    output logic bank_source_group [0:7],
    output logic [2:0] bank_n16_slot [0:7],
    output logic [TILE_TAG_W-1:0] bank_result_tag [0:7]
);

  logic bank_ce [0:7];
  logic signed [7:0] bank_act_lo [0:7][0:3];
  logic signed [7:0] bank_act_hi [0:7][0:3];
  logic bank_issue_valid [0:7];
  logic bank_tile_clear [0:7];
  logic bank_reduce_last [0:7];
  logic [1:0] bank_m_lane_mask [0:7][0:3];
  logic [TILE_TAG_W-1:0] selected_tile_tag [0:7];

  generate
    for (genvar bank = 0; bank < 8; bank++) begin : g_bank
      if (bank < 4) begin : g_lower_cluster
        always_comb begin
          bank_source_group[bank] = 1'b0;
          bank_n16_slot[bank] = bank[2:0];
          bank_ce[bank] = group_ce[0] && bank_enable[bank];
          bank_issue_valid[bank] = group_issue_valid[0];
          bank_tile_clear[bank] = group_tile_clear[0];
          bank_reduce_last[bank] = group_reduce_last[0];
          selected_tile_tag[bank] = group_tile_tag[0];
          for (int row = 0; row < 4; row++) begin
            bank_act_lo[bank][row] = group_act_lo[0][row];
            bank_act_hi[bank][row] = group_act_hi[0][row];
            bank_m_lane_mask[bank][row] = group_m_lane_mask[0][row];
          end
        end
      end else begin : g_upper_cluster
        always_comb begin
          bank_source_group[bank] = mode_split_n64;
          bank_n16_slot[bank] = mode_split_n64 ? bank - 4 : bank;
          bank_ce[bank] = bank_enable[bank] &&
              (mode_split_n64 ? group_ce[1] : group_ce[0]);
          bank_issue_valid[bank] = mode_split_n64 ?
              group_issue_valid[1] : group_issue_valid[0];
          bank_tile_clear[bank] = mode_split_n64 ?
              group_tile_clear[1] : group_tile_clear[0];
          bank_reduce_last[bank] = mode_split_n64 ?
              group_reduce_last[1] : group_reduce_last[0];
          selected_tile_tag[bank] = mode_split_n64 ?
              group_tile_tag[1] : group_tile_tag[0];
          for (int row = 0; row < 4; row++) begin
            bank_act_lo[bank][row] = mode_split_n64 ?
                group_act_lo[1][row] : group_act_lo[0][row];
            bank_act_hi[bank][row] = mode_split_n64 ?
                group_act_hi[1][row] : group_act_hi[0][row];
            bank_m_lane_mask[bank][row] = mode_split_n64 ?
                group_m_lane_mask[1][row] : group_m_lane_mask[0][row];
          end
        end
      end

      always_ff @(posedge clk) begin
        if (rst)
          bank_result_tag[bank] <= '0;
        else if (bank_ce[bank] && bank_tile_clear[bank])
          bank_result_tag[bank] <= selected_tile_tag[bank];
      end

      alexnet_sa_m4n8 #(
          .PHYS_ROWS(4),
          .COLS(16),
          .DSP_LATENCY(4)
      ) u_sa (
          .clk,
          .rst,
          .ce(bank_ce[bank]),
          .act_lo(bank_act_lo[bank]),
          .act_hi(bank_act_hi[bank]),
          .weight(bank_weight[bank]),
          .issue_valid(bank_issue_valid[bank]),
          .tile_clear(bank_tile_clear[bank]),
          .reduce_last(bank_reduce_last[bank]),
          .m_lane_mask(bank_m_lane_mask[bank]),
          .result_valid(result_valid[bank]),
          .result_ready(result_ready[bank]),
          .result_lo(result_lo[bank]),
          .result_hi(result_hi[bank]),
          .result_lane_mask(result_lane_mask[bank])
      );
    end
  endgenerate

`ifndef SYNTHESIS
  logic mode_q;
  logic source_tile_active_q;

  always_ff @(posedge clk) begin
    if (rst) begin
      mode_q <= 1'b0;
      source_tile_active_q <= 1'b0;
    end else begin
      if (group_tile_clear[0] || group_tile_clear[1]) begin
        if (source_tile_active_q)
          $fatal(1, "dynamic SA accepted a new clear before source completion");
        mode_q <= mode_split_n64;
        source_tile_active_q <= 1'b1;
      end

      if (source_tile_active_q && mode_split_n64 != mode_q)
        $fatal(1, "dynamic SA mode changed inside a source tile");

      if (!mode_split_n64 &&
          (group_issue_valid[1] || group_tile_clear[1] ||
           group_reduce_last[1]))
        $fatal(1, "wide N128 mode must leave source group one idle");

      if (mode_split_n64 &&
          (group_issue_valid[0] != group_issue_valid[1] ||
           group_tile_clear[0] != group_tile_clear[1] ||
           group_reduce_last[0] != group_reduce_last[1]))
        $fatal(1, "split N64 groups must preserve a common K cadence");

      if ((!mode_split_n64 && group_issue_valid[0] &&
           group_reduce_last[0]) ||
          (mode_split_n64 && group_issue_valid[0] &&
           group_issue_valid[1] && group_reduce_last[0] &&
           group_reduce_last[1]))
        source_tile_active_q <= 1'b0;
    end
  end
`endif

endmodule
