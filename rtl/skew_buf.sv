`timescale 1ns/1ps
// skew_buf.sv -- activation pair-skew + weight column-skew delay chains
// (my_self.md sec.11.6, "4 activation pairs" design).
//
// Pure timing/wiring module: delays each of the 4 activation pairs (group g)
// by g cycles, and each of the 8 weight columns (col c) by c cycles, so that
// sa_packed_4x8's own internal g-cycle vertical / c-cycle horizontal hop
// chains land every value at PPE[g][c] on the same absolute cycle
// (source(k) + g + c). Outputs connect directly to sa_packed_4x8's
// act_lo_in/act_hi_in/pair_valid/lane_mask/depth_last/weight_in ports.
//
// win_q[0:7] pairs up as (win_q[2g], win_q[2g+1]) = (lo, hi) for group g.
// Group 0 / column 0 are 0-stage (pure wire) paths, matching the FF budget:
// activation side (0+1+2+3)*20b = 120 FF, weight side (0+..+7)*8b = 224 FF,
// 344 FF total. en=0 holds every shift stage together (my_self.md sec.11.7).

module skew_buf #(
  parameter int ACT_W = 8,
  parameter int WGT_W = 8,
  parameter int NG    = 4,
  parameter int NC    = 8
) (
  input  logic clk,
  input  logic rst_n,        // async active-low, fabric regs only
  input  logic en,           // en=0 holds every register together

  input  logic signed [ACT_W-1:0] win_q         [0:2*NG-1],
  input  logic                    pair_valid_in  [0:NG-1],
  input  logic [1:0]              lane_mask_in   [0:NG-1],
  input  logic                    depth_last_in  [0:NG-1],
  input  logic signed [WGT_W-1:0] weight_q       [0:NC-1],
  input  logic                    weight_valid_in,
  input  logic                    weight_depth_last_in,

  output logic signed [ACT_W-1:0] act_lo_out    [0:NG-1],
  output logic signed [ACT_W-1:0] act_hi_out    [0:NG-1],
  output logic                    pair_valid_out [0:NG-1],
  output logic [1:0]              lane_mask_out  [0:NG-1],
  output logic                    depth_last_out [0:NG-1],
  output logic signed [WGT_W-1:0] weight_out    [0:NC-1],
  output logic                    weight_valid_out [0:NC-1],
  output logic                    weight_depth_last_out [0:NC-1]
);

  generate
    for (genvar g = 0; g < NG; g++) begin : pair_skew
      if (g == 0) begin : g0
        assign act_lo_out[g]     = win_q[2*g];
        assign act_hi_out[g]     = win_q[2*g+1];
        assign pair_valid_out[g] = pair_valid_in[g];
        assign lane_mask_out[g]  = lane_mask_in[g];
        assign depth_last_out[g] = depth_last_in[g];
      end else begin : gn
        logic signed [ACT_W-1:0] d_lo [0:g-1];
        logic signed [ACT_W-1:0] d_hi [0:g-1];
        logic                    d_pv [0:g-1];
        logic [1:0]              d_lm [0:g-1];
        logic                    d_dl [0:g-1];

        always_ff @(posedge clk or negedge rst_n) begin
          if (!rst_n) begin
            for (int i = 0; i < g; i++) begin
              d_lo[i] <= '0; d_hi[i] <= '0; d_pv[i] <= 1'b0;
              d_lm[i] <= '0; d_dl[i] <= 1'b0;
            end
          end else if (en) begin
            d_lo[0] <= win_q[2*g];
            d_hi[0] <= win_q[2*g+1];
            d_pv[0] <= pair_valid_in[g];
            d_lm[0] <= lane_mask_in[g];
            d_dl[0] <= depth_last_in[g];
            for (int i = 1; i < g; i++) begin
              d_lo[i] <= d_lo[i-1]; d_hi[i] <= d_hi[i-1]; d_pv[i] <= d_pv[i-1];
              d_lm[i] <= d_lm[i-1]; d_dl[i] <= d_dl[i-1];
            end
          end
        end

        assign act_lo_out[g]     = d_lo[g-1];
        assign act_hi_out[g]     = d_hi[g-1];
        assign pair_valid_out[g] = d_pv[g-1];
        assign lane_mask_out[g]  = d_lm[g-1];
        assign depth_last_out[g] = d_dl[g-1];
      end
    end
  endgenerate

  generate
    for (genvar c = 0; c < NC; c++) begin : wgt_skew
      if (c == 0) begin : c0
        assign weight_out[c]            = weight_q[c];
        assign weight_valid_out[c]      = weight_valid_in;
        assign weight_depth_last_out[c] = weight_depth_last_in;
      end else begin : cn
        logic signed [WGT_W-1:0] d_w [0:c-1];
        logic                    d_wv [0:c-1];
        logic                    d_wdl [0:c-1];

        always_ff @(posedge clk or negedge rst_n) begin
          if (!rst_n) begin
            for (int i = 0; i < c; i++) begin
              d_w[i] <= '0;
              d_wv[i] <= 1'b0;
              d_wdl[i] <= 1'b0;
            end
          end else if (en) begin
            d_w[0] <= weight_q[c];
            d_wv[0] <= weight_valid_in;
            d_wdl[0] <= weight_depth_last_in;
            for (int i = 1; i < c; i++) begin
              d_w[i] <= d_w[i-1];
              d_wv[i] <= d_wv[i-1];
              d_wdl[i] <= d_wdl[i-1];
            end
          end
        end

        assign weight_out[c]            = d_w[c-1];
        assign weight_valid_out[c]      = d_wv[c-1];
        assign weight_depth_last_out[c] = d_wdl[c-1];
      end
    end
  endgenerate

endmodule
