`timescale 1ns/1ps

// AlexNet M8 x N8 systolic tile.
//
// Four physical rows each pack two activation lanes into one DSP48E2, so the
// tile performs 64 signed INT8 MACs per accepted K token with 32 DSP48E2s.
module alexnet_sa_m8n8 (
    input logic clk,
    input logic rst,
    input logic ce,

    input logic signed [7:0] act_lo [0:3],
    input logic signed [7:0] act_hi [0:3],
    input logic signed [7:0] weight [0:7],
    input logic issue_valid,
    input logic tile_clear,
    input logic reduce_last,
    input logic [1:0] m_lane_mask [0:3],

    output logic result_valid [0:3][0:7],
    input  logic result_ready [0:3][0:7],
    output logic signed [31:0] result_lo [0:3][0:7],
    output logic signed [31:0] result_hi [0:3][0:7],
    output logic [1:0] result_lane_mask [0:3][0:7]
);

  alexnet_sa_m4n8 #(
      .PHYS_ROWS(4),
      .COLS(8),
      .DSP_LATENCY(4)
  ) u_sa (.*);

endmodule
