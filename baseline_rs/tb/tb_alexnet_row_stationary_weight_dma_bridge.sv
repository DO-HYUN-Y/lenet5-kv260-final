`timescale 1ns/1ps
module tb_alexnet_row_stationary_weight_dma_bridge;
    logic clk=0, rst=1;
    always #2.5 clk=~clk;
    logic [63:0] weights_base;
    logic request_valid, request_ready;
    logic [3:0] request_layer, request_n_count;
    logic [15:0] request_n_base;
    logic [13:0] request_k_offset;
    logic [11:0] request_k_count;
    logic dma_command_valid, dma_command_ready;
    logic [63:0] dma_command_address;
    logic [25:0] dma_command_length;
    logic dma_done, dma_error, s_axis_valid, s_axis_ready, s_axis_last;
    logic [127:0] s_axis_values;
    logic [15:0] s_axis_keep;
    logic weight_valid, weight_ready, weight_last;
    logic [127:0] weight_values;
    logic [15:0] weight_keep;
    logic busy, fault;
    logic [63:0] stream_valid_bytes, completed_dma_commands;
    int cycles, packets, accepted;
    alexnet_row_stationary_weight_dma_bridge dut (.*);
    always @(negedge clk) begin
        cycles++;
        dma_command_ready=cycles%3!=0;
        weight_ready=cycles%5!=0;
    end
    always @(posedge clk) if(!rst && weight_valid && weight_ready) begin
        if(weight_values!==s_axis_values || weight_keep!==s_axis_keep || weight_last!==s_axis_last)
            $fatal(1,"weight DMA modified streaming payload");
        accepted++;
    end
    task automatic request(input int layer,kt);
        @(negedge clk);request_valid=1;request_layer=4'(layer);
        request_n_base=layer==6 || layer==7 ? 4088 : layer==8 ? 992 : 16;
        request_n_count=3;request_k_offset=14'(kt-17);request_k_count=17;
        do @(posedge clk);while(!request_ready);
        @(negedge clk);request_valid=0;
    endtask
    task automatic serve(input longint layer_offset, input int kt);
        for(int n=int'(request_n_base);n<int'(request_n_base)+3;n++) begin
            logic [63:0] address;
            address=weights_base+64'(layer_offset)+64'(n*kt+kt-17);
            wait(dma_command_valid);
            if(dma_command_address!==address || dma_command_length!=17)
                $fatal(1,"weight manifest offset/stride mismatch got=%h expected=%h",dma_command_address,address);
            do @(posedge clk);while(!dma_command_ready);
            for(int beat=0;beat<2;beat++) begin
                @(negedge clk);s_axis_valid=1;s_axis_values={4{32'(n*100+beat)}};
                s_axis_keep=beat==0?16'hffff:16'h0001;s_axis_last=beat==1;
                dma_done=n%2==0 && beat==0;
                do @(posedge clk);while(!s_axis_ready);
                @(negedge clk);s_axis_valid=0;dma_done=0;
            end
            if(n%2==1) begin
                repeat(3) @(negedge clk);
                if(dma_command_valid) $fatal(1,"weight bridge ignored late DMA completion");
                dma_done=1;@(negedge clk);dma_done=0;
            end
            packets++;
        end
        wait(!busy);
    endtask
    initial begin
        int kt [0:7]; int nt [0:7]; longint offset;
        kt='{363,1600,1728,3456,2304,9216,4096,4096};
        nt='{64,192,384,256,256,4096,4096,1000};
        cycles=0;packets=0;accepted=0;offset=0;weights_base=64'h130000000;
        request_valid=0;request_layer=0;request_n_base=0;request_n_count=0;
        request_k_offset=0;request_k_count=0;dma_command_ready=1;dma_done=0;dma_error=0;
        s_axis_valid=0;s_axis_values=0;s_axis_keep=0;s_axis_last=0;weight_ready=1;
        repeat(8) @(negedge clk);rst=0;
        for(int layer=1;layer<=8;layer++) begin
            request(layer,kt[layer-1]);serve(offset,kt[layer-1]);
            offset+=longint'(kt[layer-1])*nt[layer-1];
            if(fault) $fatal(1,"valid weight DMA request faulted");
        end
        if(offset!=61090496 || packets!=24 || accepted!=48 ||
            completed_dma_commands!=24 || stream_valid_bytes!=408)
            $fatal(1,"weight DMA accounting mismatch");
        // A bad 17-byte tail must latch a fault and reject further commands.
        request(1,363);
        wait(dma_command_valid);do @(posedge clk);while(!dma_command_ready);
        @(negedge clk);s_axis_valid=1;s_axis_values=0;s_axis_keep=16'h0001;s_axis_last=1;
        do @(posedge clk);while(!s_axis_ready);
        @(negedge clk);s_axis_valid=0;
        if(!fault || request_ready || dma_command_valid || weight_valid || stream_valid_bytes!=409)
            $fatal(1,"weight DMA accepted malformed early TLAST");
        $display("ALEXNET_ROW_STATIONARY_WEIGHT_DMA_TEST_PASSED packets=%0d beats=%0d valid_bytes=408",packets,accepted-1);
        $finish;
    end
    initial begin #100000; $fatal(1,"weight DMA timeout");end
endmodule
