`timescale 1ns/1ps
// Batch-one pure RS service shell: real raw tensor gather, frozen parameters,
// result scatter and the unchanged in-place pool service. Two DMA engines:
// main MM2S/S2MM and independent weight MM2S. No weight replay is introduced.
(* use_dsp = "no" *) module alexnet_row_stationary_ddr_engine (
    input logic clk, rst,
    input logic start_valid,
    output logic start_ready,
    input logic [15:0] start_tag,
    input logic [63:0] input_base, activation_a_base, activation_b_base,
    input logic [63:0] weights_base, parameters_base, final_output_base,
    output logic main_command_valid,
    input logic main_command_ready,
    output logic main_command_s2mm,
    output logic [63:0] main_command_address,
    output logic [25:0] main_command_length,
    input logic main_dma_armed, main_dma_done, main_dma_error,
    input logic [127:0] main_read_data,
    input logic [15:0] main_read_keep,
    input logic main_read_valid, main_read_last,
    output logic main_read_ready,
    output logic [127:0] main_write_data,
    output logic [15:0] main_write_keep,
    output logic main_write_valid, main_write_last,
    input logic main_write_ready,
    output logic weight_dma_command_valid,
    input logic weight_dma_command_ready,
    output logic [63:0] weight_dma_command_address,
    output logic [25:0] weight_dma_command_length,
    input logic weight_dma_done, weight_dma_error,
    input logic weight_axis_valid,
    output logic weight_axis_ready,
    input logic [127:0] weight_axis_values,
    input logic [15:0] weight_axis_keep,
    input logic weight_axis_last,
    output logic inference_done, busy, fault,
    output logic [3:0] active_layer,
    output logic [31:0] completed_commands, completed_input_tiles,
    output logic [63:0] useful_mac_count,
    output logic [63:0] main_read_axis_bytes, main_write_axis_bytes,
    output logic [63:0] weight_service_bytes, gather_requested_bytes,
    output logic [31:0] main_completed_transfers, stored_packets,
    output logic [31:0] result_signature
);
    typedef enum logic [3:0] {IDLE, GATHER_STREAM, GATHER_DRAIN, GATHER_RESPONSE,
        PARAM_STREAM, PARAM_DRAIN, WRITE_STREAM, WRITE_DRAIN, POOL, FAILED} state_t;
    state_t state_q;
    logic bank_start_ready, bank_start_valid, bank_done, bank_busy, bank_fault;
    logic input_request_valid, input_request_ready;
    logic [3:0] input_request_layer_id, input_request_m_count;
    logic [12:0] input_request_m_base;
    logic [13:0] input_request_k_offset;
    logic [11:0] input_request_k_count;
    logic input_axis_valid, input_axis_ready, input_axis_last;
    logic [127:0] input_axis_values;
    logic [3:0] weight_request_layer_id;
    logic [15:0] weight_request_n_base;
    logic parameter_request_valid, parameter_valid, parameter_ready;
    logic signed [31:0] command_bias [0:7];
    logic signed [17:0] command_multiplier [0:7];
    logic [5:0] command_right_shift [0:7];
    logic [7:0] command_relu;
    logic output_valid, output_ready, output_last;
    logic [63:0] output_values;
    logic [7:0] output_lane_mask;
    logic [12:0] output_m;
    logic [15:0] output_n_base, output_tag;
    logic [3:0] output_layer;
    logic layer_complete_valid, layer_complete_ready, layer_requires_pool;
    logic [3:0] layer_complete_id;
    logic [63:0] source_base;
    logic gather_read_valid, gather_read_ready, gather_response_valid, gather_response_ready;
    logic [63:0] gather_read_address, gather_response_values_q;
    logic gather_busy, gather_fault;
    logic loader_start_valid, loader_start_ready, loader_axis_ready, loader_valid, loader_ready;
    logic loader_busy, loader_fault, parameter_started_q, parameter_dma_complete_q;
    logic parameter_checked_q, parameter_supported_q;
    logic [3:0] loader_layer;
    logic [63:0] packet_values_q [0:7];
    logic [3:0] packet_count_q, packet_words_q;
    logic [2:0] write_index_q;
    logic packet_full_q;
    logic [63:0] packet_address_q;
    logic [12:0] packet_m_q;
    logic [15:0] packet_n_q, packet_tag_q;
    logic [3:0] packet_layer_q;
    logic [7:0] packet_mask_q;
    logic pool_start_valid, pool_ready, pool_done, pool_busy, pool_fault;
    logic pool_command_valid, pool_command_ready, pool_command_s2mm;
    logic [31:0] pool_command_address, pool_base;
    logic [25:0] pool_command_length;
    logic pool_read_ready, pool_write_valid, pool_write_ready, pool_write_last;
    logic [127:0] pool_write_data;
    logic [15:0] pool_write_keep;
    logic dma_done_seen_q, service_fault_q, done_pending_q, pool_completed_q;
    logic [15:0] job_tag_q;
    logic service_idle, address_supported, command_fire, read_fire, write_fire, parameters_supported;
    logic [31:0] signature_fold;
    function automatic logic [4:0] popcount16(input logic [15:0] mask);
        logic [4:0] result;
        result=0; for(int i=0;i<16;i++) result=result+mask[i]; return result;
    endfunction
    function automatic logic [31:0] parameter_offset(input logic [3:0] layer);
        case(layer)
            1: return 0; 2: return 1024; 3: return 4096; 4: return 10240;
            5: return 14336; 6: return 18432; 7: return 83968; 8: return 149504;
            default: return 0;
        endcase
    endfunction
    (* use_dsp = "no" *) function automatic logic [31:0] result_offset(
        input logic [3:0] layer, input logic [12:0] m, input logic [15:0] n
    );
        case(layer)
            1: return ((32'(n>>3)*3025)+m)<<3;
            2: return ((32'(n>>3)*729)+m)<<3;
            3,4,5: return ((32'(n>>3)*169)+m)<<3;
            default: return 32'(n)+32'(m)*8;
        endcase
    endfunction
    function automatic logic [63:0] result_base(input logic [3:0] layer);
        if(layer==8) return final_output_base;
        return layer[0] ? activation_a_base : activation_b_base;
    endfunction
    assign source_base=input_request_layer_id==1 ? input_base :
        input_request_layer_id[0] ? activation_b_base : activation_a_base;
    assign pool_base=layer_complete_id==2 ? activation_b_base[31:0] : activation_a_base[31:0];
    assign address_supported=(input_base[63:32]|activation_a_base[63:32]|
        activation_b_base[63:32]|weights_base[63:32]|parameters_base[63:32]|
        final_output_base[63:32])==0;
    assign service_idle=state_q==IDLE && !packet_full_q && packet_count_q==0 &&
        !gather_busy && !loader_busy && !parameter_started_q && !pool_busy;
    assign start_ready=bank_start_ready && service_idle && !done_pending_q && !fault && address_supported;
    assign bank_start_valid=start_valid && service_idle && !done_pending_q && !fault && address_supported;
    assign busy=bank_busy || !service_idle || done_pending_q;
    assign fault=service_fault_q || bank_fault || gather_fault || loader_fault || pool_fault ||
        main_dma_error || weight_dma_error;
    assign layer_complete_ready=service_idle && (!layer_requires_pool || pool_completed_q) && !fault;
    assign pool_start_valid=state_q==IDLE && layer_complete_valid && layer_requires_pool &&
        !pool_completed_q && !packet_full_q && packet_count_q==0 && !gather_busy && !loader_busy && !fault;
    assign output_ready=!packet_full_q && !fault;
    assign parameter_valid=loader_valid && parameter_dma_complete_q && parameter_checked_q && parameter_supported_q && !fault;
    assign loader_ready=parameter_ready && parameter_dma_complete_q && parameter_checked_q && parameter_supported_q && !fault;
    assign command_relu=loader_layer==8 ? 8'h00 : 8'hff;
    assign gather_response_valid=state_q==GATHER_RESPONSE && !fault;
    assign pool_command_ready=state_q==POOL && main_command_ready && !fault;
    assign command_fire=main_command_valid && main_command_ready;
    assign read_fire=main_read_valid && main_read_ready;
    assign write_fire=main_write_valid && main_write_ready;
    always_comb begin
        parameters_supported=1;
        for(int n=0;n<8;n++) if(command_multiplier[n]<18'sd65540 || command_multiplier[n]>18'sd131067 ||
            command_right_shift[n]<23 || command_right_shift[n]>32) parameters_supported=0;
        signature_fold=0;
        for(int n=0;n<8;n++) if(output_lane_mask[n])
            signature_fold=signature_fold ^ (32'(output_values[n*8+:8]) << ((n%4)*8));
        main_command_valid=0; main_command_s2mm=0; main_command_address=0; main_command_length=0;
        gather_read_ready=0; loader_start_valid=0;
        if(!fault) begin
            if(state_q==POOL) begin
                main_command_valid=pool_command_valid; main_command_s2mm=pool_command_s2mm;
                main_command_address={32'd0,pool_command_address}; main_command_length=pool_command_length;
            end else if(state_q==IDLE && !pool_start_valid) begin
                // Committing collected output first prevents two-bank deadlock.
                if(packet_full_q) begin
                    main_command_valid=1; main_command_s2mm=1;
                    main_command_address=packet_address_q; main_command_length=26'(packet_words_q)<<3;
                end else if(parameter_request_valid && !parameter_started_q && loader_start_ready) begin
                    main_command_valid=1;
                    main_command_address=parameters_base+parameter_offset(weight_request_layer_id)+
                        (64'(weight_request_n_base)<<4);
                    main_command_length=128; loader_start_valid=main_command_ready;
                end else if(gather_read_valid) begin
                    main_command_valid=1; main_command_address=gather_read_address; main_command_length=8;
                    gather_read_ready=main_command_ready;
                end
            end
        end
        main_read_ready=state_q==GATHER_STREAM ? !fault :
            state_q==PARAM_STREAM ? loader_axis_ready && !fault :
            state_q==POOL ? pool_read_ready && !fault : 1'b0;
        main_write_valid=state_q==WRITE_STREAM && !fault;
        main_write_data={write_index_q+1<packet_words_q ? packet_values_q[write_index_q+1] : 64'd0,
            packet_values_q[write_index_q]};
        main_write_keep=write_index_q+1<packet_words_q ? 16'hffff : 16'h00ff;
        main_write_last=write_index_q+2>=packet_words_q;
        if(state_q==POOL) begin
            main_write_valid=pool_write_valid && !fault; main_write_data=pool_write_data;
            main_write_keep=pool_write_keep; main_write_last=pool_write_last;
        end
        pool_write_ready=state_q==POOL && main_write_ready && !fault;
    end
    always_ff @(posedge clk) begin
        if(rst) begin
            state_q<=IDLE; packet_count_q<=0; packet_words_q<=0; packet_full_q<=0;
            packet_address_q<=0; packet_m_q<=0; packet_n_q<=0; packet_tag_q<=0;
            packet_layer_q<=0; packet_mask_q<=0; write_index_q<=0;
            dma_done_seen_q<=0; service_fault_q<=0; done_pending_q<=0; pool_completed_q<=0;
            parameter_started_q<=0; parameter_dma_complete_q<=0; parameter_checked_q<=0; parameter_supported_q<=0; job_tag_q<=0;
            gather_response_values_q<=0; inference_done<=0; active_layer<=0;
            main_read_axis_bytes<=0; main_write_axis_bytes<=0;
            main_completed_transfers<=0; stored_packets<=0; result_signature<=0;
            for(int i=0;i<8;i++) packet_values_q[i]<=0;
        end else begin
            inference_done<=0;
            if(start_valid && start_ready) begin job_tag_q<=start_tag; active_layer<=1; result_signature<=0; end
            if(((start_valid && service_idle) || bank_busy) && !address_supported) service_fault_q<=1;
            if(bank_done) done_pending_q<=1;
            if(done_pending_q && service_idle && !fault) begin inference_done<=1; done_pending_q<=0; end
            if(layer_complete_valid && layer_complete_ready) begin
                pool_completed_q<=0; active_layer<=layer_complete_id+1;
            end
            if(read_fire) main_read_axis_bytes<=main_read_axis_bytes+popcount16(main_read_keep);
            if(write_fire) main_write_axis_bytes<=main_write_axis_bytes+popcount16(main_write_keep);
            if(main_dma_done) begin dma_done_seen_q<=1; main_completed_transfers<=main_completed_transfers+1; end
            if(loader_valid && !parameter_checked_q) begin
                parameter_checked_q<=1; parameter_supported_q<=parameters_supported;
                if(!parameters_supported) service_fault_q<=1;
            end
            if(loader_valid && loader_ready) begin
                parameter_started_q<=0; parameter_dma_complete_q<=0; parameter_checked_q<=0; parameter_supported_q<=0;
            end
            if(output_valid && output_ready) begin
                packet_values_q[packet_count_q[2:0]]<=output_values;
                packet_count_q<=packet_count_q+1;
                result_signature<=result_signature ^ signature_fold;
                if(packet_count_q==0) begin
                    packet_m_q<=output_m; packet_n_q<=output_n_base; packet_tag_q<=output_tag;
                    packet_layer_q<=output_layer; packet_mask_q<=output_lane_mask;
                    packet_address_q<=result_base(output_layer)+result_offset(output_layer,output_m,output_n_base);
                end else if(output_m!=packet_m_q+packet_count_q || output_n_base!=packet_n_q ||
                    output_tag!=packet_tag_q || output_layer!=packet_layer_q || output_lane_mask!=packet_mask_q)
                    service_fault_q<=1;
                if(output_last) begin packet_full_q<=1; packet_words_q<=packet_count_q+1; end
                else if(packet_count_q==7) service_fault_q<=1;
            end
            case(state_q)
                IDLE: begin
                    dma_done_seen_q<=0;
                    if(pool_start_valid && pool_ready) state_q<=POOL;
                    else if(command_fire) begin
                        dma_done_seen_q<=0;
                        if(main_command_s2mm) begin write_index_q<=0; state_q<=WRITE_STREAM; end
                        else if(loader_start_valid) begin
                            parameter_started_q<=1; parameter_checked_q<=0; parameter_supported_q<=0; state_q<=PARAM_STREAM;
                        end
                        else state_q<=GATHER_STREAM;
                    end
                end
                GATHER_STREAM: if(read_fire) begin
                    if(main_read_keep!=16'h00ff || !main_read_last) service_fault_q<=1;
                    gather_response_values_q<=main_read_data[63:0]; state_q<=GATHER_DRAIN;
                end
                GATHER_DRAIN: if(dma_done_seen_q || main_dma_done) state_q<=GATHER_RESPONSE;
                GATHER_RESPONSE: if(gather_response_ready) state_q<=IDLE;
                PARAM_STREAM: if(read_fire && main_read_last) state_q<=PARAM_DRAIN;
                PARAM_DRAIN: if((dma_done_seen_q || main_dma_done) && loader_valid) begin
                    parameter_dma_complete_q<=1; state_q<=IDLE;
                end
                WRITE_STREAM: if(write_fire) begin
                    if(main_write_last) state_q<=WRITE_DRAIN;
                    else write_index_q<=write_index_q+2;
                end
                WRITE_DRAIN: if(dma_done_seen_q || main_dma_done) begin
                    packet_full_q<=0; packet_count_q<=0; stored_packets<=stored_packets+1; state_q<=IDLE;
                end
                POOL: if(pool_done) begin pool_completed_q<=1; state_q<=IDLE; end
                default: ;
            endcase
            if(fault) begin service_fault_q<=1; state_q<=FAILED; end
        end
    end
    alexnet_row_stationary_gather u_gather (
        .clk, .rst, .request_valid(input_request_valid && !fault), .request_ready(input_request_ready),
        .request_layer(input_request_layer_id), .request_m_count(input_request_m_count),
        .request_m_base(input_request_m_base), .request_k_offset(input_request_k_offset),
        .request_k_count(input_request_k_count), .request_source_base(source_base),
        .read_valid(gather_read_valid), .read_ready(gather_read_ready), .read_address(gather_read_address),
        .response_valid(gather_response_valid), .response_ready(gather_response_ready),
        .response_values(gather_response_values_q), .response_error(main_dma_error),
        .axis_valid(input_axis_valid), .axis_ready(input_axis_ready), .axis_values(input_axis_values),
        .axis_last(input_axis_last), .busy(gather_busy), .fault(gather_fault),
        .raw_read_bytes(gather_requested_bytes), .completed_tiles()
    );
    alexnet_parameter_record_loader u_parameter_loader (
        .clk, .rst, .start_valid(loader_start_valid), .start_ready(loader_start_ready),
        .start_is_fc(weight_request_layer_id>=6), .start_layer_id(weight_request_layer_id),
        .start_job_tag(job_tag_q), .start_n_base(weight_request_n_base),
        .s_axis_tdata(main_read_data), .s_axis_tkeep(main_read_keep),
        .s_axis_tvalid(main_read_valid && state_q==PARAM_STREAM && !fault),
        .s_axis_tready(loader_axis_ready), .s_axis_tlast(main_read_last),
        .parameter_valid(loader_valid), .parameter_ready(loader_ready),
        .parameter_is_fc(), .parameter_layer_id(loader_layer), .parameter_job_tag(), .parameter_n_base(),
        .parameter_bias(command_bias), .parameter_multiplier(command_multiplier),
        .parameter_right_shift(command_right_shift), .busy(loader_busy), .fault(loader_fault),
        .active_lane(), .accepted_tiles(), .completed_tiles(), .rejected_tiles()
    );
    alexnet_m8n126_inplace_pool_service u_pool (
        .clk, .rst, .layer_valid(pool_start_valid), .layer_ready(pool_ready), .layer_id(layer_complete_id),
        .layer_job_tag(job_tag_q), .layer_buffer_base(pool_base),
        .dma_command_valid(pool_command_valid), .dma_command_ready(pool_command_ready),
        .dma_command_s2mm(pool_command_s2mm), .dma_command_address(pool_command_address),
        .dma_command_length(pool_command_length), .dma_armed(main_dma_armed && state_q==POOL),
        .dma_done(main_dma_done && state_q==POOL), .dma_error(main_dma_error),
        .s_axis_tdata(main_read_data), .s_axis_tkeep(main_read_keep),
        .s_axis_tvalid(main_read_valid && state_q==POOL && !fault), .s_axis_tready(pool_read_ready),
        .s_axis_tlast(main_read_last), .m_axis_tdata(pool_write_data), .m_axis_tkeep(pool_write_keep),
        .m_axis_tvalid(pool_write_valid), .m_axis_tready(pool_write_ready), .m_axis_tlast(pool_write_last),
        .layer_done(pool_done), .layer_error(pool_fault), .busy(pool_busy),
        .completed_tiles(), .raw_words_read(), .pooled_words_written()
    );
    alexnet_row_stationary_banked_engine u_banked (
        .clk, .rst, .command_bias, .command_multiplier, .command_right_shift, .command_relu,
        .weight_axis_valid, .weight_axis_ready, .weight_axis_values, .weight_axis_keep, .weight_axis_last,
        .output_valid, .output_ready, .output_values, .output_lane_mask, .output_m, .output_n_base,
        .output_tag, .output_destination(), .input_service_bytes(), .weight_service_bytes,
        .psum_read_service_bytes(), .psum_write_service_bytes(), .output_service_bytes(), .useful_mac_count,
        .start_valid(bank_start_valid), .start_ready(bank_start_ready), .start_tag,
        .input_request_valid, .input_request_ready, .input_request_layer_id, .input_request_m_base,
        .input_request_m_count, .input_request_k_offset, .input_request_k_count,
        .weight_request_valid(), .weight_request_layer_id, .weight_request_n_base, .weight_request_n_count(),
        .weight_request_k_offset(), .weight_request_k_count(), .parameter_request_valid,
        .parameter_valid, .parameter_ready, .result_destination(2'd0),
        .layer_complete_valid, .layer_complete_ready, .layer_complete_id, .layer_requires_pool,
        .inference_done(bank_done), .engine_busy(bank_busy), .engine_fault(bank_fault),
        .completed_commands, .completed_input_tiles, .input_axis_valid, .input_axis_ready,
        .input_axis_values, .input_axis_last, .weights_base,
        .weight_dma_command_valid, .weight_dma_command_ready, .weight_dma_command_address,
        .weight_dma_command_length, .weight_dma_done, .weight_dma_error, .output_layer, .output_last,
        .psum_sram_read_word_bytes(), .psum_sram_write_word_bytes(), .weight_completed_dma_commands(),
        .input_axis_transport_bytes(), .output_axis_transport_bytes(), .weight_dma_requested_bytes(),
        .input_bank0_state(), .input_bank1_state(), .output_bank0_state(), .output_bank1_state()
    );
endmodule
