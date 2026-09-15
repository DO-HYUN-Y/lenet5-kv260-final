`timescale 1ns/1ps

// AlexNet fixed-GEMM base systolic tile.
//
// Default logical shape: M4 x N8
// Default physical shape: 2 packed-activation rows x 8 weight columns
//
// The source presents one unskewed K token per enabled cycle. This tile owns
// the row/column skew, systolic operand hops, the shared row-control alignment
// taps, and one result holding register inside each packed PE. Doubling
// PHYS_ROWS=4 selects M8. Power-of-two COLS values from 8 through 256 let the
// physical study scale N without replicating feeder memories: every added
// column reuses the same activation and contributes one packed MAC DSP per
// physical row.
module alexnet_sa_m4n8 #(
    parameter int PHYS_ROWS = 2,
    parameter int COLS = 8,
    parameter int DSP_LATENCY = 4
) (
    input logic clk,
    input logic rst,
    input logic ce,

    input logic signed [7:0] act_lo [0:PHYS_ROWS-1],
    input logic signed [7:0] act_hi [0:PHYS_ROWS-1],
    input logic signed [7:0] weight [0:COLS-1],
    input logic issue_valid,
    input logic tile_clear,
    input logic reduce_last,
    input logic [1:0] m_lane_mask [0:PHYS_ROWS-1],

    output logic result_valid [0:PHYS_ROWS-1][0:COLS-1],
    input  logic result_ready [0:PHYS_ROWS-1][0:COLS-1],
    output logic signed [31:0] result_lo [0:PHYS_ROWS-1][0:COLS-1],
    output logic signed [31:0] result_hi [0:PHYS_ROWS-1][0:COLS-1],
    output logic [1:0] result_lane_mask [0:PHYS_ROWS-1][0:COLS-1]
);

  typedef struct packed {
    logic       valid;
    logic       clear;
    logic       last;
    logic [1:0] mask;
  } control_t;

  logic signed [7:0] row_act_lo [0:PHYS_ROWS-1];
  logic signed [7:0] row_act_hi [0:PHYS_ROWS-1];
  logic signed [7:0] col_weight [0:COLS-1];
  control_t row_control [0:PHYS_ROWS-1];

  // Activation row g is delayed by g cycles at the tile boundary.
  generate
    for (genvar g = 0; g < PHYS_ROWS; g++) begin : g_row_skew
      if (g == 0) begin : g_direct
        assign row_act_lo[g] = act_lo[g];
        assign row_act_hi[g] = act_hi[g];
      end else begin : g_delayed
        logic signed [7:0] lo_pipe [0:g-1];
        logic signed [7:0] hi_pipe [0:g-1];

        always_ff @(posedge clk) begin
          if (rst) begin
            for (int stage = 0; stage < g; stage++) begin
              lo_pipe[stage] <= '0;
              hi_pipe[stage] <= '0;
            end
          end else if (ce) begin
            lo_pipe[0] <= act_lo[g];
            hi_pipe[0] <= act_hi[g];
            for (int stage = 1; stage < g; stage++) begin
              lo_pipe[stage] <= lo_pipe[stage-1];
              hi_pipe[stage] <= hi_pipe[stage-1];
            end
          end
        end

        assign row_act_lo[g] = lo_pipe[g-1];
        assign row_act_hi[g] = hi_pipe[g-1];
      end
    end
  endgenerate

  // Weight column c is delayed by c cycles at the tile boundary.
  generate
    for (genvar c = 0; c < COLS; c++) begin : g_col_skew
      if (c == 0) begin : g_direct
        assign col_weight[c] = weight[c];
      end else begin : g_delayed
        logic signed [7:0] weight_pipe [0:c-1];

        always_ff @(posedge clk) begin
          if (rst) begin
            for (int stage = 0; stage < c; stage++)
              weight_pipe[stage] <= '0;
          end else if (ce) begin
            weight_pipe[0] <= weight[c];
            for (int stage = 1; stage < c; stage++)
              weight_pipe[stage] <= weight_pipe[stage-1];
          end
        end

        assign col_weight[c] = weight_pipe[c-1];
      end
    end
  endgenerate

  // One control tap per physical row covers both row skew and the four-cycle
  // DSP operand pipeline. Horizontal control then advances with activation.
  generate
    for (genvar g = 0; g < PHYS_ROWS; g++) begin : g_row_control
      localparam int CONTROL_DELAY = DSP_LATENCY + g;
      control_t control_pipe [0:CONTROL_DELAY-1];
      control_t control_in;

      always_comb begin
        control_in.valid = issue_valid && (m_lane_mask[g] != 2'b00);
        control_in.clear = tile_clear;
        control_in.last  = reduce_last && (m_lane_mask[g] != 2'b00);
        control_in.mask  = m_lane_mask[g];
      end

      always_ff @(posedge clk) begin
        if (rst) begin
          for (int stage = 0; stage < CONTROL_DELAY; stage++)
            control_pipe[stage] <= '0;
        end else if (ce) begin
          control_pipe[0] <= control_in;
          for (int stage = 1; stage < CONTROL_DELAY; stage++)
            control_pipe[stage] <= control_pipe[stage-1];
        end
      end

      assign row_control[g] = control_pipe[CONTROL_DELAY-1];
    end
  endgenerate

  logic signed [7:0] act_lo_to_pe [0:PHYS_ROWS-1][0:COLS-1];
  logic signed [7:0] act_hi_to_pe [0:PHYS_ROWS-1][0:COLS-1];
  logic signed [7:0] weight_to_pe [0:PHYS_ROWS-1][0:COLS-1];
  control_t control_to_pe [0:PHYS_ROWS-1][0:COLS-1];

  logic signed [7:0] act_lo_hop [0:PHYS_ROWS-1][0:COLS-2];
  logic signed [7:0] act_hi_hop [0:PHYS_ROWS-1][0:COLS-2];
  control_t control_hop [0:PHYS_ROWS-1][0:COLS-2];
  logic signed [7:0] weight_hop [0:PHYS_ROWS-2][0:COLS-1];

  generate
    for (genvar g = 0; g < PHYS_ROWS; g++) begin : g_horizontal
      assign act_lo_to_pe[g][0] = row_act_lo[g];
      assign act_hi_to_pe[g][0] = row_act_hi[g];
      assign control_to_pe[g][0] = row_control[g];

      for (genvar c = 1; c < COLS; c++) begin : g_hop
        always_ff @(posedge clk) begin
          if (rst) begin
            act_lo_hop[g][c-1] <= '0;
            act_hi_hop[g][c-1] <= '0;
            control_hop[g][c-1] <= '0;
          end else if (ce) begin
            act_lo_hop[g][c-1] <= act_lo_to_pe[g][c-1];
            act_hi_hop[g][c-1] <= act_hi_to_pe[g][c-1];
            control_hop[g][c-1] <= control_to_pe[g][c-1];
          end
        end

        assign act_lo_to_pe[g][c] = act_lo_hop[g][c-1];
        assign act_hi_to_pe[g][c] = act_hi_hop[g][c-1];
        assign control_to_pe[g][c] = control_hop[g][c-1];
      end
    end
  endgenerate

  generate
    for (genvar c = 0; c < COLS; c++) begin : g_vertical
      assign weight_to_pe[0][c] = col_weight[c];

      for (genvar g = 1; g < PHYS_ROWS; g++) begin : g_hop
        always_ff @(posedge clk) begin
          if (rst)
            weight_hop[g-1][c] <= '0;
          else if (ce)
            weight_hop[g-1][c] <= weight_to_pe[g-1][c];
        end

        assign weight_to_pe[g][c] = weight_hop[g-1][c];
      end
    end
  endgenerate

  generate
    for (genvar g = 0; g < PHYS_ROWS; g++) begin : g_pe_row
      for (genvar c = 0; c < COLS; c++) begin : g_pe_col
        alexnet_packed_pe u_pe (
            .clk,
            .rst,
            .ce,
            .act_lo(act_lo_to_pe[g][c]),
            .act_hi(act_hi_to_pe[g][c]),
            .weight(weight_to_pe[g][c]),
            .mac_valid(control_to_pe[g][c].valid),
            .acc_clear(control_to_pe[g][c].clear),
            .reduce_last(control_to_pe[g][c].last),
            .lane_mask(control_to_pe[g][c].mask),
            .result_valid(result_valid[g][c]),
            .result_ready(result_ready[g][c]),
            .result_lo(result_lo[g][c]),
            .result_hi(result_hi[g][c]),
            .result_lane_mask(result_lane_mask[g][c])
        );
      end
    end
  endgenerate

`ifndef SYNTHESIS
  initial begin
    if ((PHYS_ROWS != 2 && PHYS_ROWS != 4 && PHYS_ROWS != 8) ||
        COLS < 8 || COLS > 256 ||
        ((COLS & (COLS - 1)) != 0) || DSP_LATENCY != 4)
      $fatal(1,
             "AlexNet SA requires PHYS_ROWS=2/4/8 and power-of-two COLS=8..256");
  end

  always_ff @(posedge clk) begin
    if (!rst && ce) begin
      if (tile_clear && issue_valid)
        $fatal(1, "tile_clear requires a standalone source cycle");
      if (reduce_last && !issue_valid)
        $fatal(1, "reduce_last requires issue_valid");
    end
  end
`endif

endmodule
