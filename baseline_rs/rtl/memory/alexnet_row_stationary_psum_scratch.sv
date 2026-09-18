`timescale 1ns/1ps

// Reuse one original 512 x 256-bit N8 BRAM lane (16 KiB). Layout is
// [N8 group][valid M row][N lane]. No arithmetic or weight storage is here:
// completed spatial reductions replace each word, and later K blocks read it.
module alexnet_row_stationary_psum_scratch #(
    parameter int DEPTH = 512,
    parameter int ADDR_W = $clog2(DEPTH)
) (
    input logic clk, rst,
    input logic command_valid,
    output logic command_ready,
    input logic [3:0] command_layer, command_m_count, command_n_count,
    input logic [12:0] command_m_base,
    input logic [15:0] command_n_base,
    input logic [13:0] command_k_offset,
    input logic [11:0] command_k_count,
    output logic psum_in_valid,
    input logic psum_in_ready,
    output logic signed [31:0] psum_in_values [0:7],
    input logic psum_out_valid,
    output logic psum_out_ready,
    input logic signed [31:0] psum_out_values [0:7],
    input logic [3:0] psum_out_m_count,
    input logic [12:0] psum_out_m_base,
    input logic [15:0] psum_out_n,
    output logic busy, fault,
    output logic [63:0] read_word_bytes, write_word_bytes,
    output logic [63:0] read_valid_bytes, write_valid_bytes
);
    typedef enum logic [2:0] {IDLE, READ_ISSUE, READ_WAIT, READ_CAPTURE,
                              ACTIVE, WRITE_ROWS, FAILED} state_t;
    state_t state_q;
    logic [3:0] m_count_q, n_count_q, row_q, in_n_q, out_n_q;
    logic [12:0] m_base_q;
    logic [15:0] n_base_q;
    logic final_q;
    logic [ADDR_W-1:0] base_address_q;
    logic [255:0] read_group_q [0:7], write_group_q [0:7];
    logic mem_read_enable, mem_write_enable;
    logic [ADDR_W-1:0] mem_address;
    logic [255:0] mem_read_data, mem_write_data;
    logic context_valid_q;
    logic [3:0] context_layer_q, context_m_count_q;
    logic [12:0] context_m_base_q;
    logic [15:0] expected_n_q;
    logic [13:0] expected_k_q;
    logic [15:0] total_n;
    logic [13:0] total_k;
    (* use_dsp = "no" *) logic [19:0] word_address, required_words;
    logic descriptor_ok, context_ok, output_ok;
    logic input_valid_q, output_ready_q;

    always_comb begin
        case (command_layer)
            1: begin total_n=64; total_k=363; end
            2: begin total_n=192; total_k=1600; end
            3: begin total_n=384; total_k=1728; end
            4: begin total_n=256; total_k=3456; end
            5: begin total_n=256; total_k=2304; end
            6: begin total_n=4096; total_k=9216; end
            7: begin total_n=4096; total_k=4096; end
            8: begin total_n=1000; total_k=4096; end
            default: begin total_n=0; total_k=0; end
        endcase
    end
    // Force address/control products into fabric; reserve DSPs for the SA.
    always_comb begin
        word_address = (command_n_base >> 3) * command_m_count;
        required_words = ((total_n+7) >> 3) * command_m_count;
    end
    assign descriptor_ok = total_n != 0 && command_m_count >= 1 &&
        command_m_count <= 8 && command_n_count >= 1 && command_n_count <= 8 &&
        command_n_base[2:0] == 0 && command_n_base+command_n_count <= total_n &&
        (command_n_count == 8 || command_n_base+command_n_count == total_n) &&
        command_k_count >= 1 && command_k_count <= 1408 &&
        command_k_offset+command_k_count <= total_k && required_words <= DEPTH;
    assign context_ok = (command_n_base == 0 && command_k_offset == 0) ||
        (context_valid_q && command_layer == context_layer_q &&
         command_m_base == context_m_base_q && command_m_count == context_m_count_q &&
         command_n_base == expected_n_q && command_k_offset == expected_k_q);
    // Check metadata at acceptance, rather than placing layer decoders and
    // address multipliers on the core's high-fanout command/reset path.
    assign command_ready = state_q == IDLE && !fault;
    assign busy = state_q != IDLE;
    assign psum_in_valid = input_valid_q;
    assign output_ok = psum_out_m_count == m_count_q &&
        psum_out_m_base == m_base_q && psum_out_n == n_base_q+out_n_q;
    // Registered credits have the same cycle-level behavior as the count
    // checks, while keeping comparators off the global SA/DSP enable path.
    assign psum_out_ready = output_ready_q;
    assign mem_read_enable = state_q == READ_ISSUE;
    assign mem_write_enable = state_q == WRITE_ROWS;
    assign mem_address = base_address_q + ADDR_W'(row_q);
    assign mem_write_data = write_group_q[row_q[2:0]];
    always_comb begin
        for (int m=0; m<8; m++)
            psum_in_values[m] = m < m_count_q ?
                $signed(read_group_q[m][in_n_q[2:0]*32 +: 32]) : 32'sd0;
    end
    alexnet_m8n8_int32_bank_lane #(.DEPTH(DEPTH), .ADDR_W(ADDR_W)) u_storage (
        .clk, .write_enable(mem_write_enable), .write_addr(mem_address),
        .write_data(mem_write_data), .read_enable(mem_read_enable),
        .read_addr(mem_address), .read_data(mem_read_data)
    );
    always_ff @(posedge clk) begin
        if (rst) begin
            state_q<=IDLE; fault<=0; context_valid_q<=0;
            input_valid_q<=0; output_ready_q<=0;
            context_layer_q<=0; context_m_count_q<=0; context_m_base_q<=0;
            expected_n_q<=0; expected_k_q<=0;
            m_count_q<=0; n_count_q<=0; m_base_q<=0; n_base_q<=0;
            row_q<=0; in_n_q<=0; out_n_q<=0; final_q<=0; base_address_q<=0;
            read_word_bytes<=0; write_word_bytes<=0;
            read_valid_bytes<=0; write_valid_bytes<=0;
            for (int m=0; m<8; m++) begin read_group_q[m]<=0; write_group_q[m]<=0; end
        end else begin
            if (command_valid && command_ready) begin
                m_count_q<=command_m_count; n_count_q<=command_n_count;
                m_base_q<=command_m_base; n_base_q<=command_n_base;
                final_q<=command_k_offset+command_k_count == total_k;
                base_address_q<=ADDR_W'(word_address); row_q<=0; out_n_q<=0;
                in_n_q<=command_k_offset == 0 ? command_n_count : 0;
                state_q<=command_k_offset == 0 ? ACTIVE : READ_ISSUE;
                input_valid_q<=0;
                output_ready_q<=command_k_offset == 0 && command_k_offset+command_k_count < total_k;
                for (int m=0; m<8; m++) write_group_q[m]<=0;
                context_layer_q<=command_layer; context_m_base_q<=command_m_base;
                context_m_count_q<=command_m_count; context_valid_q<=1;
                if (command_n_base+command_n_count == total_n) begin
                    expected_n_q<=0;
                    expected_k_q<=command_k_offset+command_k_count;
                    if (command_k_offset+command_k_count == total_k) context_valid_q<=0;
                end else begin
                    expected_n_q<=command_n_base+command_n_count;
                    expected_k_q<=command_k_offset;
                end
            end
            case (state_q)
                READ_ISSUE: begin state_q<=READ_WAIT; read_word_bytes<=read_word_bytes+32; end
                READ_WAIT: state_q<=READ_CAPTURE;
                READ_CAPTURE: begin
                    read_group_q[row_q[2:0]]<=mem_read_data;
                    if (row_q+1 == m_count_q) begin
                        row_q<=0; state_q<=ACTIVE; input_valid_q<=1; output_ready_q<=!final_q;
                    end
                    else begin row_q<=row_q+1; state_q<=READ_ISSUE; end
                end
                ACTIVE: begin
                    if (psum_in_valid && psum_in_ready) begin
                        in_n_q<=in_n_q+1;
                        if(in_n_q+1 == n_count_q) input_valid_q<=0;
                        read_valid_bytes<=read_valid_bytes+(m_count_q << 2);
                    end
                    if (psum_out_valid && psum_out_ready) begin
                        for (int m=0; m<8; m++)
                            if (m < m_count_q)
                                write_group_q[m][out_n_q[2:0]*32 +: 32]<=psum_out_values[m];
                        out_n_q<=out_n_q+1;
                        if(out_n_q+1 == n_count_q) output_ready_q<=0;
                        write_valid_bytes<=write_valid_bytes+(m_count_q << 2);
                    end
                    if (final_q && in_n_q == n_count_q) state_q<=IDLE;
                    if (!final_q && in_n_q == n_count_q && out_n_q == n_count_q) begin
                        row_q<=0; state_q<=WRITE_ROWS;
                    end
                end
                WRITE_ROWS: begin
                    write_word_bytes<=write_word_bytes+32;
                    if (row_q+1 == m_count_q) begin row_q<=0; state_q<=IDLE; end
                    else row_q<=row_q+1;
                end
                default: ;
            endcase
            if ((command_valid && state_q == IDLE && (!descriptor_ok || !context_ok)) ||
                (psum_out_valid && state_q == ACTIVE && !final_q && !output_ok)) begin
                fault<=1; state_q<=FAILED; input_valid_q<=0; output_ready_q<=0;
            end
        end
    end
endmodule
