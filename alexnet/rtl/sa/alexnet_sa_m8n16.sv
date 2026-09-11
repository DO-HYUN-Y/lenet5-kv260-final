`timescale 1ns/1ps

// AlexNet M8 x N16 systolic tile.
//
// Four packed-activation rows broadcast eight logical M lanes across sixteen
// output-channel columns. The tile performs 128 signed INT8 MACs per accepted
// K token with 64 DSP48E2s and does not require additional feeder read ports.
module alexnet_sa_m8n16 (
    input logic clk,
    input logic rst,
    input logic ce,

    input logic signed [7:0] act_lo [0:3],
    input logic signed [7:0] act_hi [0:3],
    input logic signed [7:0] weight [0:15],
    input logic issue_valid,
    input logic tile_clear,
    input logic reduce_last,
    input logic [1:0] m_lane_mask [0:3],

    output logic result_valid [0:3][0:15],
    input  logic result_ready [0:3][0:15],
    output logic signed [31:0] result_lo [0:3][0:15],
    output logic signed [31:0] result_hi [0:3][0:15],
    output logic [1:0] result_lane_mask [0:3][0:15]
);

  alexnet_sa_m4n8 #(
      .PHYS_ROWS(4),
      .COLS(16),
      .DSP_LATENCY(4)
  ) u_sa (.*);

endmodule
