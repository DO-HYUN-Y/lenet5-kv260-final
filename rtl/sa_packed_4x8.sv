`timescale 1ns/1ps
// Systolic array top: physical 4x8 packed_pe grid = logical 8x8 output positions
// (my_self.md sec.3 mapping/dataflow/output structure). No adder tree at the
// bottom -- each PPE's 2 external accumulators (lo/hi lanes) are independent
// logical results (32 PPE x 2 lanes = 64 logical acc_out, sec.3.3).
//
// Row g (0..3) = physical PPE row, carries 1 activation pair (logical output
//   rows 2g, 2g+1) -- hops LEFT->RIGHT across columns c=0..7, 1 cycle/hop.
//   packed_pe's own act_lo_out/act_hi_out passthrough register IS this hop.
// Col c (0..7) = output filter/channel, carries 1 common weight W[k,c] --
//   hops TOP->BOTTOM across rows g=0..3, 1 cycle/hop. packed_pe's own
//   weight_out passthrough register IS this hop.
//
// packed_pe has no output port forwarding pair_valid/lane_mask/depth_last
// (those are consumed only internally, into its own 4-stage tag_pipe, to
// time its own acc_valid). So this module carries a parallel control-tag
// shift chain alongside the horizontal activation hop, one register per
// column hop, so PPE[g][c]'s control tag arrives on the same cycle as its
// act_lo_in/act_hi_in (both delayed c cycles from row entry) -- matching
// my_self.md sec.4.3's "처리 사이클 = g + c + k".
//
// Inputs here are the ALREADY-SKEWED per-row/per-col signals (skew_buf.sv's
// output boundary): act_lo_in[g]/act_hi_in[g]/pair_valid[g]/lane_mask[g]/
// depth_last[g] pre-delayed by g cycles, weight_in[c] pre-delayed by c
// cycles, per sec.4.2. skew_buf.sv itself is a separate module (not yet
// built) that would feed these ports externally.
module sa_packed_4x8 #(
    parameter int ACT_W = 8,
    parameter int WGT_W = 8,
    parameter int ACC_W = 32,
    parameter int NG    = 4,   // physical groups (rows)
    parameter int NC    = 8    // columns (filters)
) (
    input  logic clk,
    input  logic rst_n,        // async active-low, fabric regs only
    input  logic en,           // en=0 holds every register in the array together

    // per-group (row) activation pair inputs -- pre-skewed by g cycles upstream
    input  logic signed [ACT_W-1:0] act_lo_in  [0:NG-1],
    input  logic signed [ACT_W-1:0] act_hi_in  [0:NG-1],
    input  logic                    pair_valid [0:NG-1],
    input  logic [1:0]              lane_mask  [0:NG-1],
    input  logic                    depth_last [0:NG-1],

    // per-col weight inputs -- pre-skewed by c cycles upstream
    input  logic signed [WGT_W-1:0] weight_in  [0:NC-1],

    // 32 physical PPE x 2 lanes = 64 logical results, no adder tree
    output logic signed [ACC_W-1:0] acc_lo_out [0:NG-1][0:NC-1],
    output logic signed [ACC_W-1:0] acc_hi_out [0:NG-1][0:NC-1],
    output logic [1:0]              acc_valid  [0:NG-1][0:NC-1]
);

  // hop wires: packed_pe's own registered passthrough outputs
  logic signed [ACT_W-1:0] hop_act_lo [0:NG-1][0:NC-1];
  logic signed [ACT_W-1:0] hop_act_hi [0:NG-1][0:NC-1];
  logic signed [WGT_W-1:0] hop_wgt    [0:NG-1][0:NC-1];

  // control tag shift chain (parallel to horizontal act hop, same delay/hop)
  logic       ctrl_valid [0:NG-1][0:NC-1];
  logic [1:0] ctrl_mask  [0:NG-1][0:NC-1];
  logic       ctrl_last  [0:NG-1][0:NC-1];

  genvar g, c;
  generate
    for (g = 0; g < NG; g++) begin : g_ctrl
      // column 0: direct wire, same cycle as act_lo_in[g]/act_hi_in[g] entry
      assign ctrl_valid[g][0] = pair_valid[g];
      assign ctrl_mask[g][0]  = lane_mask[g];
      assign ctrl_last[g][0]  = depth_last[g];

      for (c = 1; c < NC; c++) begin : g_ctrl_hop
        always_ff @(posedge clk or negedge rst_n) begin
          if (!rst_n) begin
            ctrl_valid[g][c] <= 1'b0;
            ctrl_mask[g][c]  <= 2'b00;
            ctrl_last[g][c]  <= 1'b0;
          end else if (en) begin
            ctrl_valid[g][c] <= ctrl_valid[g][c-1];
            ctrl_mask[g][c]  <= ctrl_mask[g][c-1];
            ctrl_last[g][c]  <= ctrl_last[g][c-1];
          end
        end
      end
    end
  endgenerate

  generate
    for (g = 0; g < NG; g++) begin : row
      for (c = 0; c < NC; c++) begin : col
        logic signed [ACT_W-1:0] act_lo_pe, act_hi_pe;
        logic signed [WGT_W-1:0] wgt_pe;

        assign act_lo_pe = (c == 0) ? act_lo_in[g] : hop_act_lo[g][c-1];
        assign act_hi_pe = (c == 0) ? act_hi_in[g] : hop_act_hi[g][c-1];
        assign wgt_pe    = (g == 0) ? weight_in[c] : hop_wgt[g-1][c];

        packed_pe #(
            .ACT_W(ACT_W), .WGT_W(WGT_W), .ACC_W(ACC_W)
        ) u_ppe (
            .clk        (clk),
            .rst_n      (rst_n),
            .en         (en),
            .act_lo_in  (act_lo_pe),
            .act_hi_in  (act_hi_pe),
            .weight_in  (wgt_pe),
            .pair_valid (ctrl_valid[g][c]),
            .lane_mask  (ctrl_mask[g][c]),
            .depth_last (ctrl_last[g][c]),
            .act_lo_out (hop_act_lo[g][c]),
            .act_hi_out (hop_act_hi[g][c]),
            .weight_out (hop_wgt[g][c]),
            .acc_lo_out (acc_lo_out[g][c]),
            .acc_hi_out (acc_hi_out[g][c]),
            .acc_valid  (acc_valid[g][c])
        );
      end
    end
  endgenerate

endmodule
