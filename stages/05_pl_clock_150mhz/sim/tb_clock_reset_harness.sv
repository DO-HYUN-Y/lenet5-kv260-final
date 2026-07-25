`timescale 1ps/1ps

module tb_clock_reset_harness;
    localparam time INPUT_HALF_PERIOD_PS = 5_000ps;
    localparam time STARTUP_GRACE_PS     = 120_000ps;
    localparam time LOCK_TIMEOUT_PS      = 200_000_000ps;
    localparam time OUTPUT_PERIOD_MIN_PS = 6_400ps;
    localparam time OUTPUT_PERIOD_MAX_PS = 6_900ps;

    logic clk_in = 1'b0;
    logic clk_out;
    logic locked;
    logic rst_n;
    bit   monitor_enabled = 1'b0;

    time output_edge_0;
    time output_edge_1;
    int  reset_release_cycles;

    clock_reset_harness dut (
        .clk_in (clk_in),
        .clk_out(clk_out),
        .locked (locked),
        .rst_n  (rst_n)
    );

    always #INPUT_HALF_PERIOD_PS clk_in = ~clk_in;

    initial begin
        #STARTUP_GRACE_PS;
        monitor_enabled = 1'b1;
    end

    always @(posedge clk_out) begin
        if (monitor_enabled && locked !== 1'b1 && rst_n !== 1'b0) begin
            $fatal(1,
                "Reset released before MMCM lock: locked=%b rst_n=%b time=%0t",
                locked, rst_n, $time);
        end
    end

    initial begin : timeout_guard
        #LOCK_TIMEOUT_PS;
        $fatal(1, "MMCM did not lock before timeout");
    end

    initial begin : test_sequence
        wait (locked === 1'b1);
        disable timeout_guard;

        @(posedge clk_out);
        output_edge_0 = $time;
        @(posedge clk_out);
        output_edge_1 = $time;
        if ((output_edge_1 - output_edge_0) < OUTPUT_PERIOD_MIN_PS ||
            (output_edge_1 - output_edge_0) > OUTPUT_PERIOD_MAX_PS) begin
            $fatal(1,
                "Generated clock period is not 150 MHz: period=%0t ps",
                output_edge_1 - output_edge_0);
        end

        reset_release_cycles = 0;
        while (rst_n !== 1'b1 && reset_release_cycles < 64) begin
            @(posedge clk_out);
            reset_release_cycles++;
        end
        if (rst_n !== 1'b1) begin
            $fatal(1,
                "Reset did not deassert within 64 fabric cycles after lock");
        end

        repeat (20) begin
            @(posedge clk_out);
            if ($isunknown({clk_out, locked, rst_n})) begin
                $fatal(1,
                    "Clock/reset output contains X/Z after reset release");
            end
            if (locked !== 1'b1 || rst_n !== 1'b1) begin
                $fatal(1,
                    "Clock/reset became unstable: locked=%b rst_n=%b",
                    locked, rst_n);
            end
        end

        $display(
            "CLOCK_RESET_TIMING_SMOKE_PASS period_ps=%0t reset_cycles=%0d",
            output_edge_1 - output_edge_0, reset_release_cycles);
        $finish;
    end
endmodule
