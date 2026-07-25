`timescale 1ns/1ps
// fc_group_skew.sv -- row-only skew for direct local FC operands.
//
// Group g is delayed by g cycles. Columns do not skew because each PPE gets
// its own local weight pair directly from the 512-bit weight-buffer word.

module fc_group_skew #(
  parameter int DATA_W = 8,
  parameter int NG     = 4,
  parameter int NC     = 8
) (
  input  logic clk,
  input  logic rst_n,
  input  logic en,

  input  logic signed [DATA_W-1:0] activation_in,
  input  logic signed [DATA_W-1:0] weight_lo_in [0:NG-1][0:NC-1],
  input  logic signed [DATA_W-1:0] weight_hi_in [0:NG-1][0:NC-1],
  input  logic                    valid_in,
  input  logic                    depth_last_in,
  input  logic [1:0]              lane_mask_in [0:NG-1][0:NC-1],

  output logic signed [DATA_W-1:0] activation_out [0:NG-1],
  output logic signed [DATA_W-1:0] weight_lo_out [0:NG-1][0:NC-1],
  output logic signed [DATA_W-1:0] weight_hi_out [0:NG-1][0:NC-1],
  output logic                    valid_out [0:NG-1],
  output logic                    depth_last_out [0:NG-1],
  output logic [1:0]              lane_mask_out [0:NG-1][0:NC-1]
);

  generate
    for (genvar g = 0; g < NG; g++) begin : g_skew
      if (g == 0) begin : g_direct
        assign activation_out[g] = activation_in;
        assign valid_out[g] = valid_in;
        assign depth_last_out[g] = depth_last_in;
        for (genvar c = 0; c < NC; c++) begin : g_direct_col
          assign weight_lo_out[g][c] = weight_lo_in[g][c];
          assign weight_hi_out[g][c] = weight_hi_in[g][c];
          assign lane_mask_out[g][c] = lane_mask_in[g][c];
        end
      end else begin : g_delay
        logic signed [DATA_W-1:0] d_act [0:g-1];
        logic d_valid [0:g-1];
        logic d_last [0:g-1];
        logic signed [DATA_W-1:0] d_lo [0:g-1][0:NC-1];
        logic signed [DATA_W-1:0] d_hi [0:g-1][0:NC-1];
        logic [1:0] d_mask [0:g-1][0:NC-1];

        always_ff @(posedge clk) begin
          if (!rst_n) begin
            for (int d = 0; d < g; d++) begin
              d_act[d] <= '0;
              d_valid[d] <= 1'b0;
              d_last[d] <= 1'b0;
              for (int c = 0; c < NC; c++) begin
                d_lo[d][c] <= '0;
                d_hi[d][c] <= '0;
                d_mask[d][c] <= '0;
              end
            end
          end else if (en) begin
            d_act[0] <= activation_in;
            d_valid[0] <= valid_in;
            d_last[0] <= depth_last_in;
            for (int c = 0; c < NC; c++) begin
              d_lo[0][c] <= weight_lo_in[g][c];
              d_hi[0][c] <= weight_hi_in[g][c];
              d_mask[0][c] <= lane_mask_in[g][c];
            end
            for (int d = 1; d < g; d++) begin
              d_act[d] <= d_act[d-1];
              d_valid[d] <= d_valid[d-1];
              d_last[d] <= d_last[d-1];
              for (int c = 0; c < NC; c++) begin
                d_lo[d][c] <= d_lo[d-1][c];
                d_hi[d][c] <= d_hi[d-1][c];
                d_mask[d][c] <= d_mask[d-1][c];
              end
            end
          end
        end

        assign activation_out[g] = d_act[g-1];
        assign valid_out[g] = d_valid[g-1];
        assign depth_last_out[g] = d_last[g-1];
        for (genvar c = 0; c < NC; c++) begin : g_delay_col
          assign weight_lo_out[g][c] = d_lo[g-1][c];
          assign weight_hi_out[g][c] = d_hi[g-1][c];
          assign lane_mask_out[g][c] = d_mask[g-1][c];
        end
      end
    end
  endgenerate

endmodule
