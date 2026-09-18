`timescale 1ns/1ps
// Two adjacent horizontal windows share one input-row RF. Only the S-tap
// 1D row reduction accumulates here; channel/filter-row reductions leave PE.
module alexnet_row_stationary_pe #(parameter int ACC_W=27,parameter int ROW_W=19) (
    input logic clk,rst,ce,
    input logic input_write_valid,
    input logic [3:0] row_address,mac_hi_tap,
    input logic signed [7:0] input_write_value,
    input logic signed [7:0] row_weight,
    input logic [1:0] mac_mask,
    input logic mac_valid,mac_first,mac_last,
    output logic row_done,
    output logic signed [ACC_W-1:0] row_lo,row_hi
);
    (* ram_style="distributed" *) logic signed [7:0] input_row_q [0:15];
    logic signed [26:0] a_q,d_q,ad_q;
    logic signed [7:0] b1_q,b2_q;
    (* use_dsp="yes" *) logic signed [35:0] mult_q;
    logic signed [35:0] product_q;
    logic [3:0] valid_q,first_q,last_q;
    logic signed [7:0] activation_lo,activation_hi;
    logic signed [ROW_W-1:0] product_lo,product_hi,local_lo_q,local_hi_q;
    logic signed [ROW_W:0] checked_lo,checked_hi;
    assign activation_lo=mac_valid&&mac_mask[0]?input_row_q[row_address]:8'sd0;
    assign activation_hi=mac_valid&&mac_mask[1]?input_row_q[mac_hi_tap]:8'sd0;
    assign product_lo=ROW_W'($signed(product_q[17:0]));
    assign product_hi=ROW_W'($signed(product_q[35:18]))+{{(ROW_W-1){1'b0}},product_q[17]};
    assign checked_lo=first_q[3]?{product_lo[ROW_W-1],product_lo}:
        {local_lo_q[ROW_W-1],local_lo_q}+{product_lo[ROW_W-1],product_lo};
    assign checked_hi=first_q[3]?{product_hi[ROW_W-1],product_hi}:
        {local_hi_q[ROW_W-1],local_hi_q}+{product_hi[ROW_W-1],product_hi};
    assign row_lo=ACC_W'($signed(local_lo_q));
    assign row_hi=ACC_W'($signed(local_hi_q));
    // S<=11: |row sum|<=11*16384=180224, exact in signed19.
    always_ff @(posedge clk) begin
        // Single write port, SPO at the write/low-read address and DPO
        // at the high-read address. Active context is fully loaded before
        // compute, so no RF reset or feature-map initialization is needed.
        if(!rst && input_write_valid) input_row_q[row_address]<=input_write_value;
        if(rst) begin
            a_q<=0;d_q<=0;ad_q<=0;b1_q<=0;b2_q<=0;mult_q<=0;product_q<=0;
            valid_q<=0;first_q<=0;last_q<=0;row_done<=0;local_lo_q<=0;local_hi_q<=0;
        end else if(ce) begin
            a_q<=27'(activation_hi)<<<18;d_q<=27'(activation_lo);
            b1_q<=row_weight;ad_q<=a_q+d_q;b2_q<=b1_q;
            mult_q<=ad_q*b2_q;product_q<=mult_q;
            valid_q<={valid_q[2:0],mac_valid};
            first_q<={first_q[2:0],mac_first};last_q<={last_q[2:0],mac_last};
            row_done<=valid_q[3]&&last_q[3];
            if(valid_q[3]) begin local_lo_q<=checked_lo[ROW_W-1:0];local_hi_q<=checked_hi[ROW_W-1:0];end
        end
    end
`ifndef SYNTHESIS
    always_ff @(posedge clk) if(!rst&&ce&&valid_q[3])
        if(checked_lo[ROW_W]!=checked_lo[ROW_W-1] || checked_hi[ROW_W]!=checked_hi[ROW_W-1])
            $fatal(1,"RS local row reduction overflow");
`endif
endmodule
