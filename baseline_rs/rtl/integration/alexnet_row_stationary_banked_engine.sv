`timescale 1ns/1ps
// Bank-connected pure RS graph engine. Ingress and egress retain the original
// M16/K4096 input ping-pong banks, N8 output banks and a 16-KiB psum lane.
// External input service assembles M8 K-vectors; weights use N-major DMA.
// A layer barrier is released only after output banks drain.
module alexnet_row_stationary_banked_engine (
    input logic clk, rst,
    input logic signed [31:0] command_bias [0:7],
    input logic signed [17:0] command_multiplier [0:7],
    input logic [5:0] command_right_shift [0:7],
    input logic [7:0] command_relu,
    input logic weight_axis_valid,
    output logic weight_axis_ready,
    input logic [127:0] weight_axis_values,
    input logic [15:0] weight_axis_keep,
    input logic weight_axis_last,
    output logic output_valid,
    input logic output_ready,
    output logic [63:0] output_values,
    output logic [7:0] output_lane_mask,
    output logic [12:0] output_m,
    output logic [15:0] output_n_base, output_tag,
    output logic [1:0] output_destination,
    output logic [63:0] input_service_bytes, weight_service_bytes,
    output logic [63:0] psum_read_service_bytes, psum_write_service_bytes,
    output logic [63:0] output_service_bytes, useful_mac_count,
    input logic start_valid,
    output logic start_ready,
    input logic [15:0] start_tag,
    output logic input_request_valid,
    input logic input_request_ready,
    output logic [3:0] input_request_layer_id,
    output logic [12:0] input_request_m_base,
    output logic [3:0] input_request_m_count,
    output logic [13:0] input_request_k_offset,
    output logic [11:0] input_request_k_count,
    output logic weight_request_valid,
    output logic [3:0] weight_request_layer_id,
    output logic [15:0] weight_request_n_base,
    output logic [3:0] weight_request_n_count,
    output logic [13:0] weight_request_k_offset,
    output logic [11:0] weight_request_k_count,
    output logic parameter_request_valid,
    input logic parameter_valid,
    output logic parameter_ready,
    input logic [1:0] result_destination,
    output logic layer_complete_valid,
    input logic layer_complete_ready,
    output logic [3:0] layer_complete_id,
    output logic layer_requires_pool,
    output logic inference_done, engine_busy, engine_fault,
    output logic [31:0] completed_commands, completed_input_tiles,
    input logic input_axis_valid,
    output logic input_axis_ready,
    input logic [127:0] input_axis_values,
    input logic input_axis_last,
    input logic [63:0] weights_base,
    output logic weight_dma_command_valid,
    input logic weight_dma_command_ready,
    output logic [63:0] weight_dma_command_address,
    output logic [25:0] weight_dma_command_length,
    input logic weight_dma_done, weight_dma_error,
    output logic [3:0] output_layer,
    output logic output_last,
    output logic [63:0] psum_sram_read_word_bytes, psum_sram_write_word_bytes,
    output logic [63:0] weight_completed_dma_commands,
    output logic [63:0] input_axis_transport_bytes, output_axis_transport_bytes,
    output logic [63:0] weight_dma_requested_bytes,
    output logic [1:0] input_bank0_state, input_bank1_state,
    output logic [1:0] output_bank0_state, output_bank1_state
);

    logic engine_start_ready, engine_start_valid, engine_done, core_busy, core_fault;
    logic engine_input_request_valid, engine_input_request_ready;
    logic engine_weight_request_valid, engine_weight_request_ready;
    logic engine_layer_complete_valid, engine_layer_complete_ready;
    logic input_read_valid, input_read_ready, input_read_last, input_done_q;
    logic [63:0] input_read_values;
    logic [11:0] input_read_index;
    logic input_fill_ready, input_replay_ready, input_replay_pending_q, input_read_active, input_idle;
    logic [15:0] input_context_tag_q;
    logic [11:0] resident_k_count_q;
    logic signed [7:0] input_patch_values [0:15];
    logic [1:0] input_set_state [0:1];
    logic input_protocol_error, input_context_error;
    logic [3:0] resident_m_count_q, resident_layer_q;
    logic [12:0] resident_m_base_q;
    logic weight_stream_valid, weight_stream_ready, weight_stream_last;
    logic [127:0] weight_stream_values;
    logic [15:0] weight_stream_keep;
    logic bridge_ready, bridge_fault, bridge_busy, scratch_ready, scratch_fault, scratch_busy;
    logic psum_in_valid, psum_in_ready, psum_out_valid, psum_out_ready;
    logic signed [31:0] psum_in_values [0:7], psum_out_values [0:7];
    logic [3:0] psum_out_m_count;
    logic [12:0] psum_out_m_base;
    logic [15:0] psum_out_n, psum_out_tag;
    logic core_output_valid, core_output_ready, output_direct_ready;
    logic [63:0] core_output_values;
    logic [7:0] core_output_lane_mask;
    logic [12:0] core_output_m;
    logic [15:0] core_output_n_base, core_output_tag;
    logic [1:0] core_output_destination;
    logic output_fill_valid, output_fill_ready, output_fill_active, output_idle;
    logic output_tensor_valid, output_read_active, output_protocol_error, output_context_error;
    logic [15:0] output_tensor_tag, packet_tag_q;
    logic output_write_last, output_read_last;
    logic [8:0] output_read_index;
    logic [3:0] collecting_m_count_q, write_index_q;
    logic [12:0] collecting_m_base_q;
    logic [15:0] collecting_n_base_q, collecting_tag_q;
    logic [7:0] collecting_mask_q;
    typedef struct packed {
        logic [3:0] layer, m_count;
        logic [12:0] m_base;
        logic [15:0] n_base, tag;
        logic [1:0] destination;
    } metadata_t;
    metadata_t metadata_q [0:1];
    logic metadata_head_q, metadata_tail_q;
    logic [1:0] metadata_count_q;
    logic metadata_push, metadata_pop, local_fault_q, done_seen_q, drained;
    logic [15:0] input_mask, resident_input_mask;
    logic [63:0] unused_bridge_bytes, unused_scratch_read_bytes, unused_scratch_write_bytes;
    function automatic logic [3:0] popcount8(input logic [7:0] value);
        logic [3:0] count;
        count=0;
        for(int i=0;i<8;i++) count=count+value[i];
        return count;
    endfunction
    assign input_mask=(16'h1 << input_request_m_count)-1'b1;
    assign resident_input_mask=(16'h1 << resident_m_count_q)-1'b1;
    assign input_bank0_state=input_set_state[0];
    assign input_bank1_state=input_set_state[1];
    always_comb begin
        for(int m=0;m<8;m++) input_read_values[m*8+:8]=input_patch_values[m];
    end
    assign engine_input_request_ready=input_request_ready && input_fill_ready && !engine_fault;
    assign input_request_valid=engine_input_request_valid && input_fill_ready && !engine_fault;
    assign weight_request_valid=engine_weight_request_valid && scratch_ready && !engine_fault;
    assign engine_weight_request_ready=bridge_ready && scratch_ready && !engine_fault;
    assign engine_fault=core_fault || bridge_fault || scratch_fault || local_fault_q ||
        input_protocol_error || input_context_error || output_protocol_error || output_context_error;
    assign drained=input_idle && output_idle && metadata_count_q == 0 && !scratch_busy && !bridge_busy;
    assign start_ready=engine_start_ready && drained && !engine_fault;
    assign engine_start_valid=start_valid && drained && !engine_fault;
    assign engine_busy=core_busy || !drained || done_seen_q;
    assign layer_complete_valid=engine_layer_complete_valid && drained && !engine_fault;
    assign engine_layer_complete_ready=layer_complete_ready && drained && !engine_fault;
    assign output_fill_valid=core_output_valid && !output_fill_active &&
        metadata_count_q < 2 && !engine_fault;
    assign metadata_push=output_fill_valid && output_fill_ready;
    assign metadata_pop=output_valid && output_ready && output_read_last;
    assign output_write_last=write_index_q+1 == collecting_m_count_q;
    assign core_output_ready=output_direct_ready && !engine_fault;
    assign output_last=output_read_last;
    assign output_layer=metadata_q[metadata_head_q].layer;
    assign output_m=metadata_q[metadata_head_q].m_base+13'(output_read_index);
    assign output_n_base=metadata_q[metadata_head_q].n_base;
    assign output_tag=metadata_q[metadata_head_q].tag;
    assign output_destination=metadata_q[metadata_head_q].destination;
    always_ff @(posedge clk) begin
        if(rst) begin
            resident_m_count_q<=0; resident_m_base_q<=0; resident_layer_q<=0;
            resident_k_count_q<=0; input_context_tag_q<=0; input_replay_pending_q<=0;
            input_done_q<=0; metadata_head_q<=0; metadata_tail_q<=0; metadata_count_q<=0;
            collecting_m_count_q<=0; collecting_m_base_q<=0; collecting_n_base_q<=0;
            collecting_tag_q<=0; collecting_mask_q<=0; write_index_q<=0; packet_tag_q<=0;
            metadata_q[0]<='0; metadata_q[1]<='0;
            local_fault_q<=0; done_seen_q<=0; inference_done<=0;
            input_axis_transport_bytes<=0; output_axis_transport_bytes<=0; weight_dma_requested_bytes<=0;
        end else begin
            input_done_q<=input_read_valid && input_read_ready && input_read_last;
            inference_done<=0;
            if(input_axis_valid && input_axis_ready) input_axis_transport_bytes<=input_axis_transport_bytes+16;
            if(output_valid && output_ready) output_axis_transport_bytes<=output_axis_transport_bytes+popcount8(output_lane_mask);
            if(weight_dma_command_valid && weight_dma_command_ready)
                weight_dma_requested_bytes<=weight_dma_requested_bytes+weight_dma_command_length;
            if(engine_done) done_seen_q<=1;
            if(done_seen_q && drained && !engine_fault) begin inference_done<=1; done_seen_q<=0; end
            if(start_valid && start_ready) done_seen_q<=0;
            if(input_request_valid && input_request_ready) begin
                resident_m_count_q<=input_request_m_count;
                resident_m_base_q<=input_request_m_base; resident_layer_q<=input_request_layer_id;
                resident_k_count_q<=input_request_k_count;
                input_context_tag_q<=completed_input_tiles[15:0]; input_replay_pending_q<=1;
            end
            if(input_replay_pending_q && input_replay_ready) input_replay_pending_q<=0;
            if(metadata_push) begin
                metadata_q[metadata_tail_q].layer<=resident_layer_q;
                metadata_q[metadata_tail_q].m_count<=resident_m_count_q;
                metadata_q[metadata_tail_q].m_base<=core_output_m;
                metadata_q[metadata_tail_q].n_base<=core_output_n_base;
                metadata_q[metadata_tail_q].tag<=core_output_tag;
                metadata_q[metadata_tail_q].destination<=core_output_destination;
                metadata_tail_q<=!metadata_tail_q;
                collecting_m_count_q<=resident_m_count_q; collecting_m_base_q<=core_output_m;
                collecting_n_base_q<=core_output_n_base; collecting_tag_q<=core_output_tag;
                collecting_mask_q<=core_output_lane_mask; write_index_q<=0;
                packet_tag_q<=packet_tag_q+1;
                if(core_output_m != resident_m_base_q) local_fault_q<=1;
            end
            if(core_output_valid && core_output_ready) begin
                write_index_q<=write_index_q+1;
                if(core_output_m != collecting_m_base_q+write_index_q ||
                    core_output_n_base != collecting_n_base_q || core_output_tag != collecting_tag_q ||
                    core_output_lane_mask != collecting_mask_q) local_fault_q<=1;
            end
            if(metadata_pop) metadata_head_q<=!metadata_head_q;
            case({metadata_push,metadata_pop})
                2'b10: metadata_count_q<=metadata_count_q+1;
                2'b01: metadata_count_q<=metadata_count_q-1;
                default: ;
            endcase
        end
    end
    // Same unchanged M16/K4096 input patch banks as the GitHub hybrid engine.
    // Only the eight used M lanes are loaded; the upper half is masked to zero.
    // Prevent pruning the unused M8 half: the baseline comparison retains
    // the hybrid's complete physical M16 bank capacity, not a smaller bank.
    (* keep_hierarchy = "yes", dont_touch = "yes" *) alexnet_m16_patch_pingpong u_input_banks (
        .clk, .rst, .fill_valid(engine_input_request_valid && input_request_ready && !engine_fault),
        .fill_ready(input_fill_ready), .fill_k_count({1'b0,input_request_k_count}),
        .fill_m_lane_mask(input_mask), .fill_context_tag(completed_input_tiles[15:0]),
        .write_valid(input_axis_valid), .write_ready(input_axis_ready),
        .write_values(input_axis_values), .write_last(input_axis_last), .write_k(),
        .replay_valid(input_replay_pending_q), .replay_ready(input_replay_ready),
        .replay_k_count({1'b0,resident_k_count_q}), .replay_m_lane_mask(resident_input_mask),
        .replay_context_tag(input_context_tag_q),
        .patch_valid(input_read_valid), .patch_ready(input_read_ready), .patch_values(input_patch_values),
        .patch_k(input_read_index), .patch_last(input_read_last), .patch_m_lane_mask(), .patch_context_tag(),
        .set_state(input_set_state), .ready_set_mask(),
        .fill_active(), .active_fill_set(), .replay_active(input_read_active), .active_replay_set(),
        .words_written(), .completed_fills(), .completed_replays(), .fill_done(), .replay_done(),
        .context_error(input_context_error), .protocol_error(input_protocol_error), .idle(input_idle)
    );
    alexnet_n8_activation_pingpong u_output_banks (
        .clk, .rst, .fill_valid(output_fill_valid), .fill_ready(output_fill_ready),
        .fill_is_pooled(1'b0), .fill_word_count({6'd0,resident_m_count_q}),
        .fill_lane_mask(core_output_lane_mask), .fill_tensor_tag(packet_tag_q),
        .direct_valid(core_output_valid && !engine_fault), .direct_ready(output_direct_ready),
        .direct_values(core_output_values), .direct_lane_mask(core_output_lane_mask),
        .direct_last(output_write_last), .pooled_valid(1'b0), .pooled_ready(),
        .pooled_values(64'd0), .pooled_lane_mask(8'd0), .pooled_last(1'b0),
        .read_start_valid(output_tensor_valid), .read_start_ready(), .read_start_tensor_tag(output_tensor_tag),
        .read_valid(output_valid), .read_ready(output_ready), .read_values(output_values),
        .read_lane_mask(output_lane_mask), .read_index(output_read_index), .read_last(output_read_last),
        .read_tensor_tag(), .read_done(), .ready_tensor_valid(output_tensor_valid),
        .ready_tensor_bank(), .ready_tensor_tag(output_tensor_tag), .ready_count(),
        .fill_active(output_fill_active), .fill_bank(), .active_fill_is_pooled(),
        .read_active(output_read_active), .read_bank(),
        .bank0_state(output_bank0_state), .bank1_state(output_bank1_state),
        .bank0_words_written(), .bank1_words_written(),
        .context_error(output_context_error), .protocol_error(output_protocol_error), .idle(output_idle)
    );
    alexnet_row_stationary_psum_scratch u_psum_scratch (
        .clk, .rst, .command_valid(engine_weight_request_valid && bridge_ready && !engine_fault), .command_ready(scratch_ready),
        .command_layer(weight_request_layer_id), .command_m_count(resident_m_count_q),
        .command_n_count(weight_request_n_count), .command_m_base(resident_m_base_q),
        .command_n_base(weight_request_n_base), .command_k_offset(weight_request_k_offset),
        .command_k_count(weight_request_k_count), .psum_in_valid, .psum_in_ready, .psum_in_values,
        .psum_out_valid, .psum_out_ready, .psum_out_values, .psum_out_m_count, .psum_out_m_base, .psum_out_n,
        .busy(scratch_busy), .fault(scratch_fault), .read_word_bytes(psum_sram_read_word_bytes),
        .write_word_bytes(psum_sram_write_word_bytes), .read_valid_bytes(unused_scratch_read_bytes),
        .write_valid_bytes(unused_scratch_write_bytes)
    );
    alexnet_row_stationary_weight_dma_bridge u_weight_dma (
        .clk, .rst, .weights_base, .request_valid(weight_request_valid), .request_ready(bridge_ready),
        .request_layer(weight_request_layer_id), .request_n_count(weight_request_n_count),
        .request_n_base(weight_request_n_base), .request_k_offset(weight_request_k_offset),
        .request_k_count(weight_request_k_count),
        .dma_command_valid(weight_dma_command_valid), .dma_command_ready(weight_dma_command_ready),
        .dma_command_address(weight_dma_command_address), .dma_command_length(weight_dma_command_length),
        .dma_done(weight_dma_done), .dma_error(weight_dma_error),
        .s_axis_valid(weight_axis_valid), .s_axis_ready(weight_axis_ready), .s_axis_values(weight_axis_values),
        .s_axis_keep(weight_axis_keep), .s_axis_last(weight_axis_last),
        .weight_valid(weight_stream_valid), .weight_ready(weight_stream_ready), .weight_values(weight_stream_values),
        .weight_keep(weight_stream_keep), .weight_last(weight_stream_last),
        .busy(bridge_busy), .fault(bridge_fault), .stream_valid_bytes(unused_bridge_bytes),
        .completed_dma_commands(weight_completed_dma_commands)
    );
    alexnet_row_stationary_graph_engine u_engine (
        .clk(clk),
        .rst(rst),
        .input_load_valid(input_read_valid),
        .input_load_ready(input_read_ready),
        .input_load_k(input_read_index),
        .input_load_values(input_read_values),
        .command_bias(command_bias),
        .command_multiplier(command_multiplier),
        .command_right_shift(command_right_shift),
        .command_relu(command_relu),
        .weight_axis_valid(weight_stream_valid),
        .weight_axis_ready(weight_stream_ready),
        .weight_axis_values(weight_stream_values),
        .weight_axis_keep(weight_stream_keep),
        .weight_axis_last(weight_stream_last),
        .psum_in_valid(psum_in_valid),
        .psum_in_ready(psum_in_ready),
        .psum_in_values(psum_in_values),
        .psum_out_valid(psum_out_valid),
        .psum_out_ready(psum_out_ready),
        .psum_out_values(psum_out_values),
        .psum_out_m_count(psum_out_m_count),
        .psum_out_m_base(psum_out_m_base),
        .psum_out_n(psum_out_n),
        .psum_out_tag(psum_out_tag),
        .output_valid(core_output_valid),
        .output_ready(core_output_ready),
        .output_values(core_output_values),
        .output_lane_mask(core_output_lane_mask),
        .output_m(core_output_m),
        .output_n_base(core_output_n_base),
        .output_tag(core_output_tag),
        .output_destination(core_output_destination),
        .input_service_bytes(input_service_bytes),
        .weight_service_bytes(weight_service_bytes),
        .psum_read_service_bytes(psum_read_service_bytes),
        .psum_write_service_bytes(psum_write_service_bytes),
        .output_service_bytes(output_service_bytes),
        .useful_mac_count(useful_mac_count),
        .start_valid(engine_start_valid),
        .start_ready(engine_start_ready),
        .start_tag(start_tag),
        .input_request_valid(engine_input_request_valid),
        .input_request_ready(engine_input_request_ready),
        .input_request_layer_id(input_request_layer_id),
        .input_request_m_base(input_request_m_base),
        .input_request_m_count(input_request_m_count),
        .input_request_k_offset(input_request_k_offset),
        .input_request_k_count(input_request_k_count),
        .input_done(input_done_q),
        .input_error(input_protocol_error || input_context_error),
        .weight_request_valid(engine_weight_request_valid),
        .weight_request_ready(engine_weight_request_ready),
        .weight_request_layer_id(weight_request_layer_id),
        .weight_request_n_base(weight_request_n_base),
        .weight_request_n_count(weight_request_n_count),
        .weight_request_k_offset(weight_request_k_offset),
        .weight_request_k_count(weight_request_k_count),
        .parameter_request_valid(parameter_request_valid),
        .parameter_valid(parameter_valid),
        .parameter_ready(parameter_ready),
        .result_destination(result_destination),
        .layer_complete_valid(engine_layer_complete_valid),
        .layer_complete_ready(engine_layer_complete_ready),
        .layer_complete_id(layer_complete_id),
        .layer_requires_pool(layer_requires_pool),
        .inference_done(engine_done),
        .engine_busy(core_busy),
        .engine_fault(core_fault),
        .completed_commands(completed_commands),
        .completed_input_tiles(completed_input_tiles)
    );
endmodule
