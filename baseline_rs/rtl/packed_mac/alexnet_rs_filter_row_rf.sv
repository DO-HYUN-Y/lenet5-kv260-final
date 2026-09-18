`timescale 1ns/1ps
// One filter-row RF multicasts a tap to four packed PEs. Load strobes and
// byte selectors are generated once at the SA boundary, shared across rows.
(* use_dsp="no" *) module alexnet_rs_filter_row_rf (
    input logic clk,rst,
    input logic [10:0] load_mask,
    input logic signed [7:0] load_values[0:10],
    input logic [3:0] tap,
    input logic read_active,
    output logic signed [7:0] weight
);
    (* ram_style="registers" *) logic signed [7:0] weights_q[0:10];
    for(genvar t=0;t<11;t++) always_ff @(posedge clk)
        if(rst) weights_q[t]<=0;
        else if(load_mask[t]) weights_q[t]<=load_values[t];
    assign weight=read_active?weights_q[tap]:8'sd0;
endmodule
