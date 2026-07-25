`timescale 1ns/1ps
// maxpool2x2_int8.sv -- signed INT8 max over two packed horizontal pairs.
//
// top_pair and bottom_pair each contain two INT8 pixels. The selected output
// remains INT8 with the same quantization scale and zero point.

module maxpool2x2_int8 (
  input  logic clk,
  input  logic rst_n,
  input  logic flush,

  input  logic        in_valid,
  output logic        in_ready,
  input  logic [15:0] top_pair,
  input  logic [15:0] bottom_pair,

  output logic              out_valid,
  input  logic              out_ready,
  output logic signed [7:0] out_data
);

  logic signed [7:0] top_lo;
  logic signed [7:0] top_hi;
  logic signed [7:0] bottom_lo;
  logic signed [7:0] bottom_hi;
  logic signed [7:0] top_max;
  logic signed [7:0] bottom_max;
  logic signed [7:0] pool_max;

  assign top_lo = $signed(top_pair[7:0]);
  assign top_hi = $signed(top_pair[15:8]);
  assign bottom_lo = $signed(bottom_pair[7:0]);
  assign bottom_hi = $signed(bottom_pair[15:8]);
  assign top_max = (top_lo > top_hi) ? top_lo : top_hi;
  assign bottom_max = (bottom_lo > bottom_hi) ? bottom_lo : bottom_hi;
  assign pool_max = (top_max > bottom_max) ? top_max : bottom_max;
  assign in_ready = !out_valid || out_ready;

  always_ff @(posedge clk) begin
    if (!rst_n || flush) begin
      out_valid <= 1'b0;
      out_data <= '0;
    end else if (in_ready) begin
      out_valid <= in_valid;
      if (in_valid) out_data <= pool_max;
    end
  end

`ifdef SIMULATION
  assert property (@(posedge clk) disable iff (!rst_n)
      (out_valid && !out_ready) |=> $stable(out_data));
`endif

endmodule
