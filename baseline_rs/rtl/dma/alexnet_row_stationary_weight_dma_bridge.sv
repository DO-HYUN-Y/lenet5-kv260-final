`timescale 1ns/1ps

// One exact-length N-major DMA command per N token. The DMA must support
// unaligned source addresses (DRE), because Conv1 K_total is 363 bytes.
// DMA completion and TLAST are independent; both must retire before reuse.
module alexnet_row_stationary_weight_dma_bridge (
    input logic clk, rst,
    input logic [63:0] weights_base,
    input logic request_valid,
    output logic request_ready,
    input logic [3:0] request_layer, request_n_count,
    input logic [15:0] request_n_base,
    input logic [13:0] request_k_offset,
    input logic [11:0] request_k_count,
    output logic dma_command_valid,
    input logic dma_command_ready,
    output logic [63:0] dma_command_address,
    output logic [25:0] dma_command_length,
    input logic dma_done, dma_error,
    input logic s_axis_valid,
    output logic s_axis_ready,
    input logic [127:0] s_axis_values,
    input logic [15:0] s_axis_keep,
    input logic s_axis_last,
    output logic weight_valid,
    input logic weight_ready,
    output logic [127:0] weight_values,
    output logic [15:0] weight_keep,
    output logic weight_last,
    output logic busy, fault,
    output logic [63:0] stream_valid_bytes, completed_dma_commands
);
    typedef enum logic [2:0] {IDLE, OFFSET_PAIRS, OFFSET_BYTES, ADDRESS,
                              COMMAND, DATA, DRAIN, FAILED} state_t;
    state_t state_q;
    logic [63:0] address_q;
    logic [13:0] total_k_q;
    logic [11:0] k_count_q, received_q;
    logic [3:0] n_count_q, n_index_q;
    logic dma_done_q;
    logic [31:0] layer_offset;
    logic [13:0] total_k;
    logic [15:0] total_n, expected_keep;
    logic [4:0] beat_bytes;
    logic [63:0] layer_base_q;
    logic [16:0] n_term_q [0:3];
    logic [19:0] n_pair_lo_q, n_pair_hi_q;
    logic [26:0] byte_offset_q;
    logic [13:0] k_offset_q;
    logic descriptor_ok, packet_ok;
    function automatic logic [4:0] popcount16(input logic [15:0] value);
        logic [4:0] count;
        count=0;
        for(int i=0;i<16;i++) count=count+value[i];
        return count;
    endfunction
    // Three-bit shift/add digits form N*K without consuming a MAC DSP.
    // Registered pairs cut the generic multiplier plus 64-bit address path.
    function automatic logic [16:0] mul3(input logic [2:0] digit,
                                        input logic [13:0] factor);
        logic [16:0] a,b,c;
        a=digit[0]?{3'd0,factor}:17'd0;
        b=digit[1]?{2'd0,factor,1'b0}:17'd0;
        c=digit[2]?{1'd0,factor,2'b0}:17'd0;
        return a+b+c;
    endfunction
    always_comb begin
        case (request_layer)
            1: begin layer_offset=0; total_k=363; total_n=64; end
            2: begin layer_offset=23232; total_k=1600; total_n=192; end
            3: begin layer_offset=330432; total_k=1728; total_n=384; end
            4: begin layer_offset=993984; total_k=3456; total_n=256; end
            5: begin layer_offset=1878720; total_k=2304; total_n=256; end
            6: begin layer_offset=2468544; total_k=9216; total_n=4096; end
            7: begin layer_offset=40217280; total_k=4096; total_n=4096; end
            8: begin layer_offset=56994496; total_k=4096; total_n=1000; end
            default: begin layer_offset=0; total_k=0; total_n=0; end
        endcase
        beat_bytes = k_count_q-received_q >= 16 ? 5'd16 : 5'(k_count_q-received_q);
        expected_keep = beat_bytes == 16 ? 16'hffff : (16'h1 << beat_bytes)-1'b1;
    end
    assign descriptor_ok = total_n != 0 && request_n_count >= 1 &&
        request_n_count <= 8 && request_n_base+request_n_count <= total_n &&
        request_k_count >= 1 && request_k_count <= 1408 &&
        request_n_base[15:12] == 0 &&
        request_k_offset+request_k_count <= total_k &&
        weights_base <= 64'hffffffffffffffff - 64'd61090496;
    assign packet_ok = received_q < k_count_q && s_axis_keep == expected_keep &&
        s_axis_last == (received_q+beat_bytes == k_count_q);
    assign request_ready = state_q == IDLE && !fault;
    assign busy = state_q != IDLE;
    assign dma_command_valid = state_q == COMMAND && !fault;
    assign dma_command_address = address_q;
    assign dma_command_length = {14'd0,k_count_q};
    assign weight_valid = state_q == DATA && s_axis_valid && !fault && !dma_error;
    assign s_axis_ready = state_q == DATA && weight_ready && !fault && !dma_error;
    assign weight_values = s_axis_values;
    assign weight_keep = s_axis_keep;
    assign weight_last = s_axis_last;
    always_ff @(posedge clk) begin
        if (rst) begin
            state_q<=IDLE; address_q<=0; total_k_q<=0; k_count_q<=0;
            received_q<=0; n_count_q<=0; n_index_q<=0; dma_done_q<=0;
            fault<=0; stream_valid_bytes<=0; completed_dma_commands<=0;
            layer_base_q<=0; n_pair_lo_q<=0; n_pair_hi_q<=0; byte_offset_q<=0; k_offset_q<=0;
            for(int digit=0;digit<4;digit++) n_term_q[digit]<=0;
        end else begin
            if (request_valid && request_ready) begin
                layer_base_q<=weights_base+layer_offset;
                k_offset_q<=request_k_offset;
                for(int digit=0;digit<4;digit++)
                    n_term_q[digit]<=mul3(request_n_base[digit*3+:3],total_k);
                total_k_q<=total_k; k_count_q<=request_k_count;
                n_count_q<=request_n_count; n_index_q<=0; state_q<=OFFSET_PAIRS;
            end
            case (state_q)
                OFFSET_PAIRS: begin
                    n_pair_lo_q<={3'd0,n_term_q[0]}+{n_term_q[1],3'd0};
                    n_pair_hi_q<={3'd0,n_term_q[2]}+{n_term_q[3],3'd0};
                    state_q<=OFFSET_BYTES;
                end
                OFFSET_BYTES: begin
                    byte_offset_q<={7'd0,n_pair_lo_q}+{1'd0,n_pair_hi_q,6'd0}+{13'd0,k_offset_q};
                    state_q<=ADDRESS;
                end
                ADDRESS: begin address_q<=layer_base_q+byte_offset_q; state_q<=COMMAND; end
                COMMAND: if (dma_command_valid && dma_command_ready) begin
                    state_q<=DATA; received_q<=0; dma_done_q<=0;
                end
                DATA: begin
                    if (dma_done) dma_done_q<=1;
                    if (s_axis_valid && s_axis_ready) begin
                        received_q<=received_q+beat_bytes;
                        stream_valid_bytes<=stream_valid_bytes+popcount16(s_axis_keep);
                        if (s_axis_last) state_q<=DRAIN;
                    end
                end
                DRAIN: if (dma_done_q || dma_done) begin
                    completed_dma_commands<=completed_dma_commands+1;
                    if (n_index_q+1 == n_count_q) state_q<=IDLE;
                    else begin
                        n_index_q<=n_index_q+1; address_q<=address_q+total_k_q;
                        state_q<=COMMAND;
                    end
                end
                default: ;
            endcase
            if ((request_valid && state_q == IDLE && !descriptor_ok) ||
                (s_axis_valid && s_axis_ready && !packet_ok) ||
                (dma_error && state_q != IDLE)) begin
                fault<=1; state_q<=FAILED;
            end
        end
    end
endmodule
