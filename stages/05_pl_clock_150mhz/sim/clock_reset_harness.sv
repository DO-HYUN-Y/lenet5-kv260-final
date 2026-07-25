`timescale 1ps/1ps

module clock_reset_harness (
    input  logic clk_in,
    output logic clk_out,
    output logic locked,
    output logic rst_n
);
    logic       mb_reset;
    logic [0:0] bus_struct_reset;
    logic [0:0] peripheral_reset;
    logic [0:0] interconnect_aresetn;
    logic [0:0] peripheral_aresetn;

    system_clk_wiz_150_0 u_clk_wiz (
        .clk_out1(clk_out),
        .locked  (locked),
        .clk_in1 (clk_in)
    );

    system_rst_pl_0 u_reset (
        .slowest_sync_clk   (clk_out),
        .ext_reset_in       (1'b1),
        .aux_reset_in       (1'b1),
        .mb_debug_sys_rst   (1'b0),
        .dcm_locked         (locked),
        .mb_reset           (mb_reset),
        .bus_struct_reset   (bus_struct_reset),
        .peripheral_reset   (peripheral_reset),
        .interconnect_aresetn(interconnect_aresetn),
        .peripheral_aresetn (peripheral_aresetn)
    );

    assign rst_n = peripheral_aresetn[0];
endmodule
