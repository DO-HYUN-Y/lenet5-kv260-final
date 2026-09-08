`timescale 1ns/1ps

// First combined Conv/FC integration top (not the KV260 board/AXI-MM top).
// Both measured DMA/control paths share ONE M4xN8 SA, scanner, 4096-word
// INT32 bank, requantizer and router. Activation/weight banks remain separate.
// Acquire an owner, submit its existing jobs/commands, and release only after
// all partial sums and output transfers drain. FC release additionally waits
// for the external result-commit acknowledgements required by its controller.
// This root arbitrates ownership and accepts a direct Conv1 activation stream;
// it does NOT yet schedule the complete graph, supply DDR addresses, perform
// Pool5 flattening, or instantiate pool/PS IP.
// Faults never authorize a mode change. Quiesce external services before reset.
module alexnet_m4n8_shared_compute_top (
    input logic clk, rst, ce,
    input logic owner_valid,
    output logic owner_ready,
    input logic owner_fc,
    input logic owner_release_valid,
    output logic owner_release_ready,
    output logic owner_active,
    output logic active_owner_fc,
    output logic owner_released,
    output logic fault,
    output logic [127:0] m_axis_tdata,
    output logic [15:0] m_axis_tkeep,
    output logic m_axis_tvalid,
    input logic m_axis_tready,
    output logic m_axis_tlast,
    input logic [127:0] s_axis_tdata,
    input logic [15:0] s_axis_tkeep,
    input logic s_axis_tvalid,
    output logic s_axis_tready,
    input logic s_axis_tlast,
    output logic rs_mm2s_request_valid,
    input logic rs_mm2s_request_ready,
    output logic [1:0] rs_mm2s_request_destination,
    output logic [10:0] rs_mm2s_request_word_count,
    output logic [15:0] rs_mm2s_request_byte_count,
    output logic [15:0] rs_mm2s_request_tag,
    output logic [15:0] rs_mm2s_request_n_base,
    output logic [7:0] rs_mm2s_request_chunk_index,
    output logic rs_s2mm_request_valid,
    input logic rs_s2mm_request_ready,
    output logic [12:0] rs_s2mm_request_word_count,
    output logic [15:0] rs_s2mm_request_byte_count,
    output logic [15:0] rs_s2mm_request_n_base,
    output logic [15:0] rs_s2mm_request_tag,
    input logic rs_activation_stream_valid,
    output logic rs_activation_stream_ready,
    input logic [63:0] rs_activation_stream_values,
    input logic [7:0] rs_activation_stream_lane_mask,
    input logic rs_activation_stream_last,
    input logic rs_cfg_valid,
    output logic rs_cfg_ready,
    input logic [1:0] rs_cfg_destination,
    input logic [15:0] rs_cfg_n64_tile_base,
    input logic [2:0] rs_cfg_slice_index,
    input logic [7:0] rs_cfg_lane_mask,
    input logic signed [31:0] rs_cfg_bias [0:7],
    input logic signed [17:0] rs_cfg_multiplier [0:7],
    input logic [5:0] rs_cfg_right_shift [0:7],
    input logic [7:0] rs_cfg_relu,
    input logic rs_command_valid,
    output logic rs_command_ready,
    input logic [15:0] rs_command_id,
    input logic rs_command_activation_streaming,
    input logic [1:0] rs_command_activation_destination,
    input logic [10:0] rs_command_activation_word_count,
    input logic [15:0] rs_command_activation_byte_count,
    input logic [7:0] rs_command_activation_lane_mask,
    input logic [15:0] rs_command_activation_tensor_tag,
    input logic [10:0] rs_command_weight_word_count,
    input logic [15:0] rs_command_weight_byte_count,
    input logic [7:0] rs_command_weight_lane_mask,
    input logic [15:0] rs_command_weight_context_tag,
    input logic rs_command_result_enable,
    input logic [12:0] rs_command_result_word_count,
    input logic [15:0] rs_command_result_byte_count,
    input logic [1:0] rs_command_result_destination,
    input logic [2:0] rs_command_result_slice,
    input logic [15:0] rs_command_result_n_base,
    input logic [7:0] rs_command_result_lane_mask,
    input logic [15:0] rs_command_result_first_tile_tag,
    input logic [7:0] rs_command_chunk_input_h,
    input logic [7:0] rs_command_chunk_input_w,
    input logic [3:0] rs_command_chunk_channel_count,
    input logic [7:0] rs_command_chunk_input_lane_mask,
    input logic [3:0] rs_command_chunk_kernel,
    input logic [2:0] rs_command_chunk_stride,
    input logic [2:0] rs_command_chunk_padding,
    input logic [9:0] rs_command_chunk_k_count,
    input logic [15:0] rs_command_chunk_weight_context_tag,
    input logic [12:0] rs_command_chunk_word_count,
    input logic [7:0] rs_command_chunk_output_width,
    input logic [15:0] rs_command_chunk_accum_context_tag,
    input logic [15:0] rs_command_chunk_tile_tag_base,
    input logic [7:0] rs_command_chunk_index,
    input logic rs_command_chunk_first,
    input logic rs_command_chunk_final,
    input logic rs_clear_fault,
    output logic rs_scheduler_busy,
    output logic rs_scheduler_fault,
    output logic [3:0] rs_scheduler_fault_code,
    output logic [4:0] rs_scheduler_phase,
    output logic rs_command_done,
    output logic rs_command_rejected,
    output logic rs_fault_cleared,
    output logic rs_command_error,
    output logic [15:0] rs_active_command_id,
    output logic [15:0] rs_completed_command_id,
    output logic [15:0] rs_accepted_commands,
    output logic [15:0] rs_completed_commands,
    output logic [15:0] rs_rejected_commands,
    output logic rs_configured,
    output logic rs_chunk_frame_active,
    output logic rs_chunk_done,
    output logic rs_chunk_rejected,
    output logic rs_compute_busy,
    output logic rs_transaction_active,
    output logic rs_accum_chunk_active,
    output logic rs_transaction_done,
    output logic rs_pipeline_idle,
    output logic rs_datapath_pipeline_idle,
    output logic rs_protocol_error,
    output logic rs_datapath_protocol_error,
    output logic rs_activation_context_error,
    output logic rs_accum_context_error,
    output logic rs_weight_context_error,
    output logic [15:0] rs_completed_tile_count,
    output logic [15:0] rs_completed_weight_replays,
    output logic [1:0] rs_weight_bank_state,
    output logic rs_weight_resident_valid,
    output logic [9:0] rs_resident_weight_k_count,
    output logic [9:0] rs_resident_weight_words_written,
    output logic [7:0] rs_resident_weight_n_lane_mask,
    output logic [15:0] rs_resident_weight_context_tag,
    output logic rs_weight_replay_done,
    output logic [2:0] rs_accum_bank_state,
    output logic [6:0] rs_queued_count,
    output logic rs_activation_ready_tensor_valid,
    output logic rs_activation_ready_tensor_bank,
    output logic [15:0] rs_activation_ready_tensor_tag,
    output logic [1:0] rs_activation_ready_count,
    output logic rs_activation_fill_active,
    output logic rs_activation_fill_bank,
    output logic rs_activation_read_active,
    output logic rs_activation_read_bank,
    output logic rs_activation_read_segment,
    output logic rs_activation_read_done,
    output logic [10:0] rs_activation_words_forwarded,
    output logic [15:0] rs_activation_stream_words_forwarded,
    output logic rs_dma_busy,
    output logic rs_dma_transfer_active,
    output logic rs_dma_transfer_done,
    output logic rs_dma_descriptor_rejected,
    output logic rs_dma_descriptor_error,
    output logic rs_dma_stream_error,
    output logic rs_dma_protocol_error,
    output logic [1:0] rs_dma_active_destination,
    output logic [10:0] rs_dma_words_transferred,
    output logic [15:0] rs_dma_completed_transfers,
    output logic rs_result_dma_busy,
    output logic rs_result_dma_transfer_active,
    output logic rs_result_dma_transfer_done,
    output logic rs_result_dma_descriptor_rejected,
    output logic rs_result_dma_descriptor_error,
    output logic rs_result_dma_metadata_error,
    output logic rs_result_dma_protocol_error,
    output logic [1:0] rs_result_dma_active_destination,
    output logic [2:0] rs_result_dma_active_slice,
    output logic [15:0] rs_result_dma_active_n_base,
    output logic [7:0] rs_result_dma_active_lane_mask,
    output logic [15:0] rs_result_dma_active_first_tile_tag,
    output logic [12:0] rs_result_dma_words_accepted,
    output logic [12:0] rs_result_dma_words_transferred,
    output logic [12:0] rs_result_dma_beats_transferred,
    output logic [15:0] rs_result_dma_completed_transfers,
    output logic [15:0] rs_result_dma_completed_first_tile_tag,
    output logic [15:0] rs_result_dma_completed_last_tile_tag,
    input logic fc_job_valid,
    output logic fc_job_ready,
    input logic [3:0] fc_job_layer_id,
    input logic [2:0] fc_job_m_count,
    input logic [15:0] fc_job_tag,
    output logic fc_parameter_request_valid,
    output logic [3:0] fc_active_layer_id,
    output logic [2:0] fc_active_m_count,
    output logic [15:0] fc_active_job_tag,
    output logic [15:0] fc_active_n_base,
    output logic [13:0] fc_active_k_offset,
    output logic [9:0] fc_active_k_count,
    input logic fc_parameter_valid,
    output logic fc_parameter_ready,
    input logic [3:0] fc_parameter_layer_id,
    input logic [15:0] fc_parameter_job_tag,
    input logic [15:0] fc_parameter_n_base,
    input logic signed [31:0] fc_parameter_bias [0:7],
    input logic signed [17:0] fc_parameter_multiplier [0:7],
    input logic [5:0] fc_parameter_right_shift [0:7],
    output logic fc_read_request_valid,
    input logic fc_read_request_ready,
    output logic [1:0] fc_read_request_destination,
    output logic [9:0] fc_read_request_word_count,
    output logic [15:0] fc_read_request_byte_count,
    output logic [2:0] fc_read_request_m_count,
    output logic [15:0] fc_read_request_tag,
    output logic fc_result_request_valid,
    input logic fc_result_request_ready,
    output logic [1:0] fc_result_request_destination,
    output logic [15:0] fc_result_request_byte_count,
    output logic [15:0] fc_result_request_tag,
    input logic fc_result_complete_valid,
    output logic fc_result_complete_ready,
    input logic [15:0] fc_result_complete_n_base,
    input logic [15:0] fc_result_complete_tag,
    input logic fc_result_complete_error,
    input logic fc_service_error,
    output logic fc_busy,
    output logic fc_layer_done,
    output logic fc_job_rejected,
    output logic fc_layer_failed,
    output logic fc_fault,
    output logic [3:0] fc_fault_code,
    output logic [4:0] fc_phase,
    output logic [9:0] fc_completed_n_tiles,
    output logic [13:0] fc_completed_chunks,
    output logic [23:0] fc_completed_k_tokens,
    output logic [11:0] fc_completed_output_words
);
  logic rs_shared_cfg_valid;
  logic rs_shared_cfg_ready;
  logic [1:0] rs_shared_cfg_destination;
  logic [15:0] rs_shared_cfg_n64_tile_base;
  logic [2:0] rs_shared_cfg_slice_index;
  logic [7:0] rs_shared_cfg_lane_mask;
  logic signed [31:0] rs_shared_cfg_bias [0:7];
  logic signed [17:0] rs_shared_cfg_multiplier [0:7];
  logic [5:0] rs_shared_cfg_right_shift [0:7];
  logic [7:0] rs_shared_cfg_relu;
  logic rs_shared_chunk_valid;
  logic rs_shared_chunk_ready;
  logic [12:0] rs_shared_chunk_word_count;
  logic [7:0] rs_shared_chunk_output_width;
  logic [7:0] rs_shared_chunk_n_lane_mask;
  logic [15:0] rs_shared_chunk_context_tag;
  logic [15:0] rs_shared_chunk_tile_tag_base;
  logic [7:0] rs_shared_chunk_index;
  logic rs_shared_chunk_first;
  logic rs_shared_chunk_final;
  logic rs_shared_tile_start_valid;
  logic rs_shared_tile_start_ready;
  logic [2:0] rs_shared_tile_m_count;
  logic [7:0] rs_shared_tile_n_lane_mask;
  logic [15:0] rs_shared_tile_tag;
  logic rs_shared_issue_valid;
  logic rs_shared_issue_ready;
  logic rs_shared_issue_last;
  logic signed [7:0] rs_shared_issue_act_lo [0:1];
  logic signed [7:0] rs_shared_issue_act_hi [0:1];
  logic signed [7:0] rs_shared_issue_weight [0:7];
  logic rs_shared_egress_valid;
  logic rs_shared_egress_ready;
  logic [63:0] rs_shared_egress_values;
  logic [7:0] rs_shared_egress_lane_mask;
  logic [1:0] rs_shared_egress_destination;
  logic [2:0] rs_shared_egress_slice;
  logic [4:0] rs_shared_egress_m;
  logic [15:0] rs_shared_egress_n_base;
  logic [15:0] rs_shared_egress_tile_tag;
  logic rs_shared_configured;
  logic rs_shared_compute_busy;
  logic rs_shared_transaction_active;
  logic rs_shared_chunk_active;
  logic rs_shared_tile_done;
  logic rs_shared_chunk_done;
  logic rs_shared_transaction_done;
  logic rs_shared_datapath_idle;
  logic [2:0] rs_shared_accum_bank_state;
  logic rs_shared_accum_context_error;
  logic rs_shared_protocol_error;
  logic [6:0] rs_shared_queued_count;
  logic fc_shared_cfg_valid;
  logic fc_shared_cfg_ready;
  logic [1:0] fc_shared_cfg_destination;
  logic [15:0] fc_shared_cfg_n64_tile_base;
  logic [2:0] fc_shared_cfg_slice_index;
  logic [7:0] fc_shared_cfg_lane_mask;
  logic signed [31:0] fc_shared_cfg_bias [0:7];
  logic signed [17:0] fc_shared_cfg_multiplier [0:7];
  logic [5:0] fc_shared_cfg_right_shift [0:7];
  logic [7:0] fc_shared_cfg_relu;
  logic fc_shared_chunk_valid;
  logic fc_shared_chunk_ready;
  logic [12:0] fc_shared_chunk_word_count;
  logic [7:0] fc_shared_chunk_output_width;
  logic [7:0] fc_shared_chunk_n_lane_mask;
  logic [15:0] fc_shared_chunk_context_tag;
  logic [15:0] fc_shared_chunk_tile_tag_base;
  logic [7:0] fc_shared_chunk_index;
  logic fc_shared_chunk_first;
  logic fc_shared_chunk_final;
  logic fc_shared_tile_start_valid;
  logic fc_shared_tile_start_ready;
  logic [2:0] fc_shared_tile_m_count;
  logic [7:0] fc_shared_tile_n_lane_mask;
  logic [15:0] fc_shared_tile_tag;
  logic fc_shared_issue_valid;
  logic fc_shared_issue_ready;
  logic fc_shared_issue_last;
  logic signed [7:0] fc_shared_issue_act_lo [0:1];
  logic signed [7:0] fc_shared_issue_act_hi [0:1];
  logic signed [7:0] fc_shared_issue_weight [0:7];
  logic fc_shared_egress_valid;
  logic fc_shared_egress_ready;
  logic [63:0] fc_shared_egress_values;
  logic [7:0] fc_shared_egress_lane_mask;
  logic [1:0] fc_shared_egress_destination;
  logic [2:0] fc_shared_egress_slice;
  logic [4:0] fc_shared_egress_m;
  logic [15:0] fc_shared_egress_n_base;
  logic [15:0] fc_shared_egress_tile_tag;
  logic fc_shared_configured;
  logic fc_shared_compute_busy;
  logic fc_shared_transaction_active;
  logic fc_shared_chunk_active;
  logic fc_shared_tile_done;
  logic fc_shared_chunk_done;
  logic fc_shared_transaction_done;
  logic fc_shared_datapath_idle;
  logic [2:0] fc_shared_accum_bank_state;
  logic fc_shared_accum_context_error;
  logic fc_shared_protocol_error;
  logic [6:0] fc_shared_queued_count;
  logic bus_shared_cfg_valid;
  logic bus_shared_cfg_ready;
  logic [1:0] bus_shared_cfg_destination;
  logic [15:0] bus_shared_cfg_n64_tile_base;
  logic [2:0] bus_shared_cfg_slice_index;
  logic [7:0] bus_shared_cfg_lane_mask;
  logic signed [31:0] bus_shared_cfg_bias [0:7];
  logic signed [17:0] bus_shared_cfg_multiplier [0:7];
  logic [5:0] bus_shared_cfg_right_shift [0:7];
  logic [7:0] bus_shared_cfg_relu;
  logic bus_shared_chunk_valid;
  logic bus_shared_chunk_ready;
  logic [12:0] bus_shared_chunk_word_count;
  logic [7:0] bus_shared_chunk_output_width;
  logic [7:0] bus_shared_chunk_n_lane_mask;
  logic [15:0] bus_shared_chunk_context_tag;
  logic [15:0] bus_shared_chunk_tile_tag_base;
  logic [7:0] bus_shared_chunk_index;
  logic bus_shared_chunk_first;
  logic bus_shared_chunk_final;
  logic bus_shared_tile_start_valid;
  logic bus_shared_tile_start_ready;
  logic [2:0] bus_shared_tile_m_count;
  logic [7:0] bus_shared_tile_n_lane_mask;
  logic [15:0] bus_shared_tile_tag;
  logic bus_shared_issue_valid;
  logic bus_shared_issue_ready;
  logic bus_shared_issue_last;
  logic signed [7:0] bus_shared_issue_act_lo [0:1];
  logic signed [7:0] bus_shared_issue_act_hi [0:1];
  logic signed [7:0] bus_shared_issue_weight [0:7];
  logic bus_shared_egress_valid;
  logic bus_shared_egress_ready;
  logic [63:0] bus_shared_egress_values;
  logic [7:0] bus_shared_egress_lane_mask;
  logic [1:0] bus_shared_egress_destination;
  logic [2:0] bus_shared_egress_slice;
  logic [4:0] bus_shared_egress_m;
  logic [15:0] bus_shared_egress_n_base;
  logic [15:0] bus_shared_egress_tile_tag;
  logic bus_shared_configured;
  logic bus_shared_compute_busy;
  logic bus_shared_transaction_active;
  logic bus_shared_chunk_active;
  logic bus_shared_tile_done;
  logic bus_shared_chunk_done;
  logic bus_shared_transaction_done;
  logic bus_shared_datapath_idle;
  logic [2:0] bus_shared_accum_bank_state;
  logic bus_shared_accum_context_error;
  logic bus_shared_protocol_error;
  logic [6:0] bus_shared_queued_count;

  logic rs_selected, fc_selected, fault_q;
  logic rs_axis_ready, fc_axis_ready, rs_axis_valid, fc_axis_valid;
  logic [127:0] rs_axis_data, fc_axis_data;
  logic [15:0] rs_axis_keep, fc_axis_keep;
  logic rs_axis_last, fc_axis_last;
  logic fc_job_ready_i;
  logic shared_rst;
  assign rs_selected = owner_active && !active_owner_fc;
  assign fc_selected = owner_active && active_owner_fc;
  // Releasing an owner must not reset the shared SA/accumulator. A subsequent
  // Conv/FC owner therefore proves a true drained handoff on retained state.
  assign shared_rst = rst;
  // Front-end faults retain their existing recovery policy: RS may clear a
  // rejected/DMA command in place, while FC recovers through reset. Only a
  // shared-bank/compute fault is latched at this new ownership boundary.
  assign fault = fault_q || (fc_selected && fc_fault) ||
                 (rs_selected && rs_scheduler_fault);
  assign owner_ready = !owner_active && !fault && !rst;
  assign owner_release_ready = owner_active && !fault &&
      bus_shared_datapath_idle &&
      (active_owner_fc ?
       (!fc_busy && !fc_job_valid && !fc_axis_valid) :
       (rs_pipeline_idle && !rs_scheduler_fault && !rs_cfg_valid &&
        !rs_command_valid && !rs_axis_valid));
  assign fc_job_ready = fc_selected && fc_job_ready_i;
  assign s_axis_tready = (rs_selected && rs_axis_ready) ||
                        (fc_selected && fc_axis_ready);
  assign m_axis_tvalid = (rs_selected && rs_axis_valid) ||
                        (fc_selected && fc_axis_valid);
  assign m_axis_tdata = active_owner_fc ? fc_axis_data : rs_axis_data;
  assign m_axis_tkeep = active_owner_fc ? fc_axis_keep : rs_axis_keep;
  assign m_axis_tlast = active_owner_fc ? fc_axis_last : rs_axis_last;

  always_ff @(posedge clk) begin
    if (rst) begin
      owner_active <= 1'b0;
      active_owner_fc <= 1'b0;
      owner_released <= 1'b0;
      fault_q <= 1'b0;
    end else begin
      fault_q <= fault_q || bus_shared_protocol_error ||
                 bus_shared_accum_context_error;
      owner_released <= 1'b0;
      if (owner_valid && owner_ready) begin
        owner_active <= 1'b1;
        active_owner_fc <= owner_fc;
      end
      if (owner_release_valid && owner_release_ready) begin
        owner_active <= 1'b0;
        owner_released <= 1'b1;
      end
    end
  end
  assign bus_shared_cfg_valid = active_owner_fc ? fc_shared_cfg_valid : rs_shared_cfg_valid;
  assign rs_shared_cfg_ready = rs_selected ? bus_shared_cfg_ready : '0;
  assign fc_shared_cfg_ready = fc_selected ? bus_shared_cfg_ready : '0;
  assign bus_shared_cfg_destination = active_owner_fc ? fc_shared_cfg_destination : rs_shared_cfg_destination;
  assign bus_shared_cfg_n64_tile_base = active_owner_fc ? fc_shared_cfg_n64_tile_base : rs_shared_cfg_n64_tile_base;
  assign bus_shared_cfg_slice_index = active_owner_fc ? fc_shared_cfg_slice_index : rs_shared_cfg_slice_index;
  assign bus_shared_cfg_lane_mask = active_owner_fc ? fc_shared_cfg_lane_mask : rs_shared_cfg_lane_mask;
  assign bus_shared_cfg_bias = active_owner_fc ? fc_shared_cfg_bias : rs_shared_cfg_bias;
  assign bus_shared_cfg_multiplier = active_owner_fc ? fc_shared_cfg_multiplier : rs_shared_cfg_multiplier;
  assign bus_shared_cfg_right_shift = active_owner_fc ? fc_shared_cfg_right_shift : rs_shared_cfg_right_shift;
  assign bus_shared_cfg_relu = active_owner_fc ? fc_shared_cfg_relu : rs_shared_cfg_relu;
  assign bus_shared_chunk_valid = active_owner_fc ? fc_shared_chunk_valid : rs_shared_chunk_valid;
  assign rs_shared_chunk_ready = rs_selected ? bus_shared_chunk_ready : '0;
  assign fc_shared_chunk_ready = fc_selected ? bus_shared_chunk_ready : '0;
  assign bus_shared_chunk_word_count = active_owner_fc ? fc_shared_chunk_word_count : rs_shared_chunk_word_count;
  assign bus_shared_chunk_output_width = active_owner_fc ? fc_shared_chunk_output_width : rs_shared_chunk_output_width;
  assign bus_shared_chunk_n_lane_mask = active_owner_fc ? fc_shared_chunk_n_lane_mask : rs_shared_chunk_n_lane_mask;
  assign bus_shared_chunk_context_tag = active_owner_fc ? fc_shared_chunk_context_tag : rs_shared_chunk_context_tag;
  assign bus_shared_chunk_tile_tag_base = active_owner_fc ? fc_shared_chunk_tile_tag_base : rs_shared_chunk_tile_tag_base;
  assign bus_shared_chunk_index = active_owner_fc ? fc_shared_chunk_index : rs_shared_chunk_index;
  assign bus_shared_chunk_first = active_owner_fc ? fc_shared_chunk_first : rs_shared_chunk_first;
  assign bus_shared_chunk_final = active_owner_fc ? fc_shared_chunk_final : rs_shared_chunk_final;
  assign bus_shared_tile_start_valid = active_owner_fc ? fc_shared_tile_start_valid : rs_shared_tile_start_valid;
  assign rs_shared_tile_start_ready = rs_selected ? bus_shared_tile_start_ready : '0;
  assign fc_shared_tile_start_ready = fc_selected ? bus_shared_tile_start_ready : '0;
  assign bus_shared_tile_m_count = active_owner_fc ? fc_shared_tile_m_count : rs_shared_tile_m_count;
  assign bus_shared_tile_n_lane_mask = active_owner_fc ? fc_shared_tile_n_lane_mask : rs_shared_tile_n_lane_mask;
  assign bus_shared_tile_tag = active_owner_fc ? fc_shared_tile_tag : rs_shared_tile_tag;
  assign bus_shared_issue_valid = active_owner_fc ? fc_shared_issue_valid : rs_shared_issue_valid;
  assign rs_shared_issue_ready = rs_selected ? bus_shared_issue_ready : '0;
  assign fc_shared_issue_ready = fc_selected ? bus_shared_issue_ready : '0;
  assign bus_shared_issue_last = active_owner_fc ? fc_shared_issue_last : rs_shared_issue_last;
  assign bus_shared_issue_act_lo = active_owner_fc ? fc_shared_issue_act_lo : rs_shared_issue_act_lo;
  assign bus_shared_issue_act_hi = active_owner_fc ? fc_shared_issue_act_hi : rs_shared_issue_act_hi;
  assign bus_shared_issue_weight = active_owner_fc ? fc_shared_issue_weight : rs_shared_issue_weight;
  assign rs_shared_egress_valid = rs_selected ? bus_shared_egress_valid : '0;
  assign fc_shared_egress_valid = fc_selected ? bus_shared_egress_valid : '0;
  assign bus_shared_egress_ready = active_owner_fc ? fc_shared_egress_ready : rs_shared_egress_ready;
  assign rs_shared_egress_values = rs_selected ? bus_shared_egress_values : '0;
  assign fc_shared_egress_values = fc_selected ? bus_shared_egress_values : '0;
  assign rs_shared_egress_lane_mask = rs_selected ? bus_shared_egress_lane_mask : '0;
  assign fc_shared_egress_lane_mask = fc_selected ? bus_shared_egress_lane_mask : '0;
  assign rs_shared_egress_destination = rs_selected ? bus_shared_egress_destination : '0;
  assign fc_shared_egress_destination = fc_selected ? bus_shared_egress_destination : '0;
  assign rs_shared_egress_slice = rs_selected ? bus_shared_egress_slice : '0;
  assign fc_shared_egress_slice = fc_selected ? bus_shared_egress_slice : '0;
  assign rs_shared_egress_m = rs_selected ? bus_shared_egress_m : '0;
  assign fc_shared_egress_m = fc_selected ? bus_shared_egress_m : '0;
  assign rs_shared_egress_n_base = rs_selected ? bus_shared_egress_n_base : '0;
  assign fc_shared_egress_n_base = fc_selected ? bus_shared_egress_n_base : '0;
  assign rs_shared_egress_tile_tag = rs_selected ? bus_shared_egress_tile_tag : '0;
  assign fc_shared_egress_tile_tag = fc_selected ? bus_shared_egress_tile_tag : '0;
  assign rs_shared_configured = rs_selected ? bus_shared_configured : '0;
  assign fc_shared_configured = fc_selected ? bus_shared_configured : '0;
  assign rs_shared_compute_busy = rs_selected ? bus_shared_compute_busy : '0;
  assign fc_shared_compute_busy = fc_selected ? bus_shared_compute_busy : '0;
  assign rs_shared_transaction_active = rs_selected ? bus_shared_transaction_active : '0;
  assign fc_shared_transaction_active = fc_selected ? bus_shared_transaction_active : '0;
  assign rs_shared_chunk_active = rs_selected ? bus_shared_chunk_active : '0;
  assign fc_shared_chunk_active = fc_selected ? bus_shared_chunk_active : '0;
  assign rs_shared_tile_done = rs_selected ? bus_shared_tile_done : '0;
  assign fc_shared_tile_done = fc_selected ? bus_shared_tile_done : '0;
  assign rs_shared_chunk_done = rs_selected ? bus_shared_chunk_done : '0;
  assign fc_shared_chunk_done = fc_selected ? bus_shared_chunk_done : '0;
  assign rs_shared_transaction_done = rs_selected ? bus_shared_transaction_done : '0;
  assign fc_shared_transaction_done = fc_selected ? bus_shared_transaction_done : '0;
  assign rs_shared_datapath_idle = rs_selected ? bus_shared_datapath_idle : 1'b1;
  assign fc_shared_datapath_idle = fc_selected ? bus_shared_datapath_idle : 1'b1;
  assign rs_shared_accum_bank_state = rs_selected ? bus_shared_accum_bank_state : '0;
  assign fc_shared_accum_bank_state = fc_selected ? bus_shared_accum_bank_state : '0;
  assign rs_shared_accum_context_error = rs_selected ? bus_shared_accum_context_error : '0;
  assign fc_shared_accum_context_error = fc_selected ? bus_shared_accum_context_error : '0;
  assign rs_shared_protocol_error = rs_selected ? bus_shared_protocol_error : '0;
  assign fc_shared_protocol_error = fc_selected ? bus_shared_protocol_error : '0;
  assign rs_shared_queued_count = rs_selected ? bus_shared_queued_count : '0;
  assign fc_shared_queued_count = fc_selected ? bus_shared_queued_count : '0;

  alexnet_m4n8_rs_dma_scheduled_io_datapath #(
      .EXTERNAL_COMPUTE(1'b1),
      .RESULT_MAX_WORDS(4096),
      .BANK_COUNT_W(13)
  ) u_rs (
      .shared_cfg_valid(rs_shared_cfg_valid),
      .shared_cfg_ready(rs_shared_cfg_ready),
      .shared_cfg_destination(rs_shared_cfg_destination),
      .shared_cfg_n64_tile_base(rs_shared_cfg_n64_tile_base),
      .shared_cfg_slice_index(rs_shared_cfg_slice_index),
      .shared_cfg_lane_mask(rs_shared_cfg_lane_mask),
      .shared_cfg_bias(rs_shared_cfg_bias),
      .shared_cfg_multiplier(rs_shared_cfg_multiplier),
      .shared_cfg_right_shift(rs_shared_cfg_right_shift),
      .shared_cfg_relu(rs_shared_cfg_relu),
      .shared_chunk_valid(rs_shared_chunk_valid),
      .shared_chunk_ready(rs_shared_chunk_ready),
      .shared_chunk_word_count(rs_shared_chunk_word_count),
      .shared_chunk_output_width(rs_shared_chunk_output_width),
      .shared_chunk_n_lane_mask(rs_shared_chunk_n_lane_mask),
      .shared_chunk_context_tag(rs_shared_chunk_context_tag),
      .shared_chunk_tile_tag_base(rs_shared_chunk_tile_tag_base),
      .shared_chunk_index(rs_shared_chunk_index),
      .shared_chunk_first(rs_shared_chunk_first),
      .shared_chunk_final(rs_shared_chunk_final),
      .shared_tile_start_valid(rs_shared_tile_start_valid),
      .shared_tile_start_ready(rs_shared_tile_start_ready),
      .shared_tile_m_count(rs_shared_tile_m_count),
      .shared_tile_n_lane_mask(rs_shared_tile_n_lane_mask),
      .shared_tile_tag(rs_shared_tile_tag),
      .shared_issue_valid(rs_shared_issue_valid),
      .shared_issue_ready(rs_shared_issue_ready),
      .shared_issue_last(rs_shared_issue_last),
      .shared_issue_act_lo(rs_shared_issue_act_lo),
      .shared_issue_act_hi(rs_shared_issue_act_hi),
      .shared_issue_weight(rs_shared_issue_weight),
      .shared_egress_valid(rs_shared_egress_valid),
      .shared_egress_ready(rs_shared_egress_ready),
      .shared_egress_values(rs_shared_egress_values),
      .shared_egress_lane_mask(rs_shared_egress_lane_mask),
      .shared_egress_destination(rs_shared_egress_destination),
      .shared_egress_slice(rs_shared_egress_slice),
      .shared_egress_m(rs_shared_egress_m),
      .shared_egress_n_base(rs_shared_egress_n_base),
      .shared_egress_tile_tag(rs_shared_egress_tile_tag),
      .shared_configured(rs_shared_configured),
      .shared_compute_busy(rs_shared_compute_busy),
      .shared_transaction_active(rs_shared_transaction_active),
      .shared_chunk_active(rs_shared_chunk_active),
      .shared_tile_done(rs_shared_tile_done),
      .shared_chunk_done(rs_shared_chunk_done),
      .shared_transaction_done(rs_shared_transaction_done),
      .shared_datapath_idle(rs_shared_datapath_idle),
      .shared_accum_bank_state(rs_shared_accum_bank_state),
      .shared_accum_context_error(rs_shared_accum_context_error),
      .shared_protocol_error(rs_shared_protocol_error),
      .shared_queued_count(rs_shared_queued_count),
      .clk(clk),
      .rst(rst),
      .ce(ce),
      .cfg_valid(rs_cfg_valid && rs_selected),
      .cfg_ready(rs_cfg_ready),
      .cfg_destination(rs_cfg_destination),
      .cfg_n64_tile_base(rs_cfg_n64_tile_base),
      .cfg_slice_index(rs_cfg_slice_index),
      .cfg_lane_mask(rs_cfg_lane_mask),
      .cfg_bias(rs_cfg_bias),
      .cfg_multiplier(rs_cfg_multiplier),
      .cfg_right_shift(rs_cfg_right_shift),
      .cfg_relu(rs_cfg_relu),
      .command_valid(rs_command_valid && rs_selected),
      .command_ready(rs_command_ready),
      .command_id(rs_command_id),
      .command_activation_streaming(rs_command_activation_streaming),
      .command_activation_destination(rs_command_activation_destination),
      .command_activation_word_count(rs_command_activation_word_count),
      .command_activation_byte_count(rs_command_activation_byte_count),
      .command_activation_lane_mask(rs_command_activation_lane_mask),
      .command_activation_tensor_tag(rs_command_activation_tensor_tag),
      .command_weight_word_count(rs_command_weight_word_count),
      .command_weight_byte_count(rs_command_weight_byte_count),
      .command_weight_lane_mask(rs_command_weight_lane_mask),
      .command_weight_context_tag(rs_command_weight_context_tag),
      .command_result_enable(rs_command_result_enable),
      .command_result_word_count(rs_command_result_word_count),
      .command_result_byte_count(rs_command_result_byte_count),
      .command_result_destination(rs_command_result_destination),
      .command_result_slice(rs_command_result_slice),
      .command_result_n_base(rs_command_result_n_base),
      .command_result_lane_mask(rs_command_result_lane_mask),
      .command_result_first_tile_tag(rs_command_result_first_tile_tag),
      .command_chunk_input_h(rs_command_chunk_input_h),
      .command_chunk_input_w(rs_command_chunk_input_w),
      .command_chunk_channel_count(rs_command_chunk_channel_count),
      .command_chunk_input_lane_mask(rs_command_chunk_input_lane_mask),
      .command_chunk_kernel(rs_command_chunk_kernel),
      .command_chunk_stride(rs_command_chunk_stride),
      .command_chunk_padding(rs_command_chunk_padding),
      .command_chunk_k_count(rs_command_chunk_k_count),
      .command_chunk_weight_context_tag(rs_command_chunk_weight_context_tag),
      .command_chunk_word_count(rs_command_chunk_word_count),
      .command_chunk_output_width(rs_command_chunk_output_width),
      .command_chunk_accum_context_tag(rs_command_chunk_accum_context_tag),
      .command_chunk_tile_tag_base(rs_command_chunk_tile_tag_base),
      .command_chunk_index(rs_command_chunk_index),
      .command_chunk_first(rs_command_chunk_first),
      .command_chunk_final(rs_command_chunk_final),
      .clear_fault(rs_clear_fault && rs_selected),
      .s_axis_tdata(s_axis_tdata),
      .s_axis_tkeep(s_axis_tkeep),
      .s_axis_tvalid(s_axis_tvalid && rs_selected),
      .s_axis_tready(rs_axis_ready),
      .s_axis_tlast(s_axis_tlast),
      .rs_mm2s_request_valid(rs_mm2s_request_valid),
      .rs_mm2s_request_ready(rs_mm2s_request_ready),
      .rs_mm2s_request_destination(rs_mm2s_request_destination),
      .rs_mm2s_request_word_count(rs_mm2s_request_word_count),
      .rs_mm2s_request_byte_count(rs_mm2s_request_byte_count),
      .rs_mm2s_request_tag(rs_mm2s_request_tag),
      .rs_mm2s_request_n_base(rs_mm2s_request_n_base),
      .rs_mm2s_request_chunk_index(rs_mm2s_request_chunk_index),
      .rs_s2mm_request_valid(rs_s2mm_request_valid),
      .rs_s2mm_request_ready(rs_s2mm_request_ready),
      .rs_s2mm_request_word_count(rs_s2mm_request_word_count),
      .rs_s2mm_request_byte_count(rs_s2mm_request_byte_count),
      .rs_s2mm_request_n_base(rs_s2mm_request_n_base),
      .rs_s2mm_request_tag(rs_s2mm_request_tag),
      .activation_stream_valid(rs_activation_stream_valid && rs_selected),
      .activation_stream_ready(rs_activation_stream_ready),
      .activation_stream_values(rs_activation_stream_values),
      .activation_stream_lane_mask(rs_activation_stream_lane_mask),
      .activation_stream_last(rs_activation_stream_last),
      .m_axis_tdata(rs_axis_data),
      .m_axis_tkeep(rs_axis_keep),
      .m_axis_tvalid(rs_axis_valid),
      .m_axis_tready(m_axis_tready && rs_selected),
      .m_axis_tlast(rs_axis_last),
      .scheduler_busy(rs_scheduler_busy),
      .scheduler_fault(rs_scheduler_fault),
      .scheduler_fault_code(rs_scheduler_fault_code),
      .scheduler_phase(rs_scheduler_phase),
      .command_done(rs_command_done),
      .command_rejected(rs_command_rejected),
      .fault_cleared(rs_fault_cleared),
      .command_error(rs_command_error),
      .active_command_id(rs_active_command_id),
      .completed_command_id(rs_completed_command_id),
      .accepted_commands(rs_accepted_commands),
      .completed_commands(rs_completed_commands),
      .rejected_commands(rs_rejected_commands),
      .configured(rs_configured),
      .chunk_frame_active(rs_chunk_frame_active),
      .chunk_done(rs_chunk_done),
      .chunk_rejected(rs_chunk_rejected),
      .compute_busy(rs_compute_busy),
      .transaction_active(rs_transaction_active),
      .accum_chunk_active(rs_accum_chunk_active),
      .transaction_done(rs_transaction_done),
      .pipeline_idle(rs_pipeline_idle),
      .datapath_pipeline_idle(rs_datapath_pipeline_idle),
      .protocol_error(rs_protocol_error),
      .datapath_protocol_error(rs_datapath_protocol_error),
      .activation_context_error(rs_activation_context_error),
      .accum_context_error(rs_accum_context_error),
      .weight_context_error(rs_weight_context_error),
      .completed_tile_count(rs_completed_tile_count),
      .completed_weight_replays(rs_completed_weight_replays),
      .weight_bank_state(rs_weight_bank_state),
      .weight_resident_valid(rs_weight_resident_valid),
      .resident_weight_k_count(rs_resident_weight_k_count),
      .resident_weight_words_written(rs_resident_weight_words_written),
      .resident_weight_n_lane_mask(rs_resident_weight_n_lane_mask),
      .resident_weight_context_tag(rs_resident_weight_context_tag),
      .weight_replay_done(rs_weight_replay_done),
      .accum_bank_state(rs_accum_bank_state),
      .queued_count(rs_queued_count),
      .activation_ready_tensor_valid(rs_activation_ready_tensor_valid),
      .activation_ready_tensor_bank(rs_activation_ready_tensor_bank),
      .activation_ready_tensor_tag(rs_activation_ready_tensor_tag),
      .activation_ready_count(rs_activation_ready_count),
      .activation_fill_active(rs_activation_fill_active),
      .activation_fill_bank(rs_activation_fill_bank),
      .activation_read_active(rs_activation_read_active),
      .activation_read_bank(rs_activation_read_bank),
      .activation_read_segment(rs_activation_read_segment),
      .activation_read_done(rs_activation_read_done),
      .activation_words_forwarded(rs_activation_words_forwarded),
      .activation_stream_words_forwarded(
          rs_activation_stream_words_forwarded),
      .dma_busy(rs_dma_busy),
      .dma_transfer_active(rs_dma_transfer_active),
      .dma_transfer_done(rs_dma_transfer_done),
      .dma_descriptor_rejected(rs_dma_descriptor_rejected),
      .dma_descriptor_error(rs_dma_descriptor_error),
      .dma_stream_error(rs_dma_stream_error),
      .dma_protocol_error(rs_dma_protocol_error),
      .dma_active_destination(rs_dma_active_destination),
      .dma_words_transferred(rs_dma_words_transferred),
      .dma_completed_transfers(rs_dma_completed_transfers),
      .result_dma_busy(rs_result_dma_busy),
      .result_dma_transfer_active(rs_result_dma_transfer_active),
      .result_dma_transfer_done(rs_result_dma_transfer_done),
      .result_dma_descriptor_rejected(rs_result_dma_descriptor_rejected),
      .result_dma_descriptor_error(rs_result_dma_descriptor_error),
      .result_dma_metadata_error(rs_result_dma_metadata_error),
      .result_dma_protocol_error(rs_result_dma_protocol_error),
      .result_dma_active_destination(rs_result_dma_active_destination),
      .result_dma_active_slice(rs_result_dma_active_slice),
      .result_dma_active_n_base(rs_result_dma_active_n_base),
      .result_dma_active_lane_mask(rs_result_dma_active_lane_mask),
      .result_dma_active_first_tile_tag(rs_result_dma_active_first_tile_tag),
      .result_dma_words_accepted(rs_result_dma_words_accepted),
      .result_dma_words_transferred(rs_result_dma_words_transferred),
      .result_dma_beats_transferred(rs_result_dma_beats_transferred),
      .result_dma_completed_transfers(rs_result_dma_completed_transfers),
      .result_dma_completed_first_tile_tag(rs_result_dma_completed_first_tile_tag),
      .result_dma_completed_last_tile_tag(rs_result_dma_completed_last_tile_tag)
  );

  alexnet_m4n8_fc_layer_datapath #(.EXTERNAL_COMPUTE(1'b1)) u_fc (
      .shared_cfg_valid(fc_shared_cfg_valid),
      .shared_cfg_ready(fc_shared_cfg_ready),
      .shared_cfg_destination(fc_shared_cfg_destination),
      .shared_cfg_n64_tile_base(fc_shared_cfg_n64_tile_base),
      .shared_cfg_slice_index(fc_shared_cfg_slice_index),
      .shared_cfg_lane_mask(fc_shared_cfg_lane_mask),
      .shared_cfg_bias(fc_shared_cfg_bias),
      .shared_cfg_multiplier(fc_shared_cfg_multiplier),
      .shared_cfg_right_shift(fc_shared_cfg_right_shift),
      .shared_cfg_relu(fc_shared_cfg_relu),
      .shared_chunk_valid(fc_shared_chunk_valid),
      .shared_chunk_ready(fc_shared_chunk_ready),
      .shared_chunk_word_count(fc_shared_chunk_word_count),
      .shared_chunk_output_width(fc_shared_chunk_output_width),
      .shared_chunk_n_lane_mask(fc_shared_chunk_n_lane_mask),
      .shared_chunk_context_tag(fc_shared_chunk_context_tag),
      .shared_chunk_tile_tag_base(fc_shared_chunk_tile_tag_base),
      .shared_chunk_index(fc_shared_chunk_index),
      .shared_chunk_first(fc_shared_chunk_first),
      .shared_chunk_final(fc_shared_chunk_final),
      .shared_tile_start_valid(fc_shared_tile_start_valid),
      .shared_tile_start_ready(fc_shared_tile_start_ready),
      .shared_tile_m_count(fc_shared_tile_m_count),
      .shared_tile_n_lane_mask(fc_shared_tile_n_lane_mask),
      .shared_tile_tag(fc_shared_tile_tag),
      .shared_issue_valid(fc_shared_issue_valid),
      .shared_issue_ready(fc_shared_issue_ready),
      .shared_issue_last(fc_shared_issue_last),
      .shared_issue_act_lo(fc_shared_issue_act_lo),
      .shared_issue_act_hi(fc_shared_issue_act_hi),
      .shared_issue_weight(fc_shared_issue_weight),
      .shared_egress_valid(fc_shared_egress_valid),
      .shared_egress_ready(fc_shared_egress_ready),
      .shared_egress_values(fc_shared_egress_values),
      .shared_egress_lane_mask(fc_shared_egress_lane_mask),
      .shared_egress_destination(fc_shared_egress_destination),
      .shared_egress_slice(fc_shared_egress_slice),
      .shared_egress_m(fc_shared_egress_m),
      .shared_egress_n_base(fc_shared_egress_n_base),
      .shared_egress_tile_tag(fc_shared_egress_tile_tag),
      .shared_configured(fc_shared_configured),
      .shared_compute_busy(fc_shared_compute_busy),
      .shared_transaction_active(fc_shared_transaction_active),
      .shared_chunk_active(fc_shared_chunk_active),
      .shared_tile_done(fc_shared_tile_done),
      .shared_chunk_done(fc_shared_chunk_done),
      .shared_transaction_done(fc_shared_transaction_done),
      .shared_datapath_idle(fc_shared_datapath_idle),
      .shared_accum_bank_state(fc_shared_accum_bank_state),
      .shared_accum_context_error(fc_shared_accum_context_error),
      .shared_protocol_error(fc_shared_protocol_error),
      .shared_queued_count(fc_shared_queued_count),
      .clk(clk),
      .rst(rst),
      .job_valid(fc_job_valid && fc_selected),
      .job_ready(fc_job_ready_i),
      .job_layer_id(fc_job_layer_id),
      .job_m_count(fc_job_m_count),
      .job_tag(fc_job_tag),
      .parameter_request_valid(fc_parameter_request_valid),
      .active_layer_id(fc_active_layer_id),
      .active_m_count(fc_active_m_count),
      .active_job_tag(fc_active_job_tag),
      .active_n_base(fc_active_n_base),
      .active_k_offset(fc_active_k_offset),
      .active_k_count(fc_active_k_count),
      .parameter_valid(fc_parameter_valid && fc_selected),
      .parameter_ready(fc_parameter_ready),
      .parameter_layer_id(fc_parameter_layer_id),
      .parameter_job_tag(fc_parameter_job_tag),
      .parameter_n_base(fc_parameter_n_base),
      .parameter_bias(fc_parameter_bias),
      .parameter_multiplier(fc_parameter_multiplier),
      .parameter_right_shift(fc_parameter_right_shift),
      .read_request_valid(fc_read_request_valid),
      .read_request_ready(fc_read_request_ready),
      .read_request_destination(fc_read_request_destination),
      .read_request_word_count(fc_read_request_word_count),
      .read_request_byte_count(fc_read_request_byte_count),
      .read_request_m_count(fc_read_request_m_count),
      .read_request_tag(fc_read_request_tag),
      .result_request_valid(fc_result_request_valid),
      .result_request_ready(fc_result_request_ready),
      .result_request_destination(fc_result_request_destination),
      .result_request_byte_count(fc_result_request_byte_count),
      .result_request_tag(fc_result_request_tag),
      .result_complete_valid(fc_result_complete_valid && fc_selected),
      .result_complete_ready(fc_result_complete_ready),
      .result_complete_n_base(fc_result_complete_n_base),
      .result_complete_tag(fc_result_complete_tag),
      .result_complete_error(fc_result_complete_error),
      .service_error(fc_service_error && fc_selected),
      .ce(ce),
      .s_axis_tdata(s_axis_tdata),
      .s_axis_tkeep(s_axis_tkeep),
      .s_axis_tvalid(s_axis_tvalid && fc_selected),
      .s_axis_tready(fc_axis_ready),
      .s_axis_tlast(s_axis_tlast),
      .m_axis_tdata(fc_axis_data),
      .m_axis_tkeep(fc_axis_keep),
      .m_axis_tvalid(fc_axis_valid),
      .m_axis_tready(m_axis_tready && fc_selected),
      .m_axis_tlast(fc_axis_last),
      .busy(fc_busy),
      .layer_done(fc_layer_done),
      .job_rejected(fc_job_rejected),
      .layer_failed(fc_layer_failed),
      .fault(fc_fault),
      .fault_code(fc_fault_code),
      .phase(fc_phase),
      .completed_n_tiles(fc_completed_n_tiles),
      .completed_chunks(fc_completed_chunks),
      .completed_k_tokens(fc_completed_k_tokens),
      .completed_output_words(fc_completed_output_words)
  );

  alexnet_m4n8_accum_base_datapath #(
      .BANK_DEPTH(4096), .RUNTIME_SLICE_INDEX(1'b1)
  ) u_shared (
      .clk(clk), .rst(shared_rst), .ce(ce && owner_active),
      .cfg_valid(bus_shared_cfg_valid),
      .cfg_ready(bus_shared_cfg_ready),
      .cfg_destination(bus_shared_cfg_destination),
      .cfg_n64_tile_base(bus_shared_cfg_n64_tile_base),
      .cfg_slice_index(bus_shared_cfg_slice_index),
      .cfg_lane_mask(bus_shared_cfg_lane_mask),
      .cfg_bias(bus_shared_cfg_bias),
      .cfg_multiplier(bus_shared_cfg_multiplier),
      .cfg_right_shift(bus_shared_cfg_right_shift),
      .cfg_relu(bus_shared_cfg_relu),
      .chunk_valid(bus_shared_chunk_valid),
      .chunk_ready(bus_shared_chunk_ready),
      .chunk_word_count(bus_shared_chunk_word_count),
      .chunk_output_width(bus_shared_chunk_output_width),
      .chunk_n_lane_mask(bus_shared_chunk_n_lane_mask),
      .chunk_context_tag(bus_shared_chunk_context_tag),
      .chunk_tile_tag_base(bus_shared_chunk_tile_tag_base),
      .chunk_index(bus_shared_chunk_index),
      .chunk_first(bus_shared_chunk_first),
      .chunk_final(bus_shared_chunk_final),
      .tile_start_valid(bus_shared_tile_start_valid),
      .tile_start_ready(bus_shared_tile_start_ready),
      .tile_m_count(bus_shared_tile_m_count),
      .tile_n_lane_mask(bus_shared_tile_n_lane_mask),
      .tile_tag(bus_shared_tile_tag),
      .issue_valid(bus_shared_issue_valid),
      .issue_ready(bus_shared_issue_ready),
      .issue_last(bus_shared_issue_last),
      .issue_act_lo(bus_shared_issue_act_lo),
      .issue_act_hi(bus_shared_issue_act_hi),
      .issue_weight(bus_shared_issue_weight),
      .egress_valid(bus_shared_egress_valid),
      .egress_ready(bus_shared_egress_ready),
      .egress_values(bus_shared_egress_values),
      .egress_lane_mask(bus_shared_egress_lane_mask),
      .egress_destination(bus_shared_egress_destination),
      .egress_slice(bus_shared_egress_slice),
      .egress_m(bus_shared_egress_m),
      .egress_n_base(bus_shared_egress_n_base),
      .egress_tile_tag(bus_shared_egress_tile_tag),
      .configured(bus_shared_configured),
      .compute_busy(bus_shared_compute_busy),
      .transaction_active(bus_shared_transaction_active),
      .chunk_active(bus_shared_chunk_active),
      .tile_done(bus_shared_tile_done),
      .chunk_done(bus_shared_chunk_done),
      .transaction_done(bus_shared_transaction_done),
      .datapath_idle(bus_shared_datapath_idle),
      .accum_bank_state(bus_shared_accum_bank_state),
      .accum_context_error(bus_shared_accum_context_error),
      .protocol_error(bus_shared_protocol_error),
      .queued_count(bus_shared_queued_count)
  );

`ifndef SYNTHESIS
  logic previous_owner_active, previous_owner_fc, previous_release;
  always_ff @(posedge clk) begin
    if (rst) begin
      previous_owner_active <= 0;
      previous_owner_fc <= 0;
      previous_release <= 0;
    end else begin
      if (previous_owner_active && owner_active &&
          active_owner_fc != previous_owner_fc)
        $fatal(1, "shared compute owner changed without a drained boundary");
      if (previous_owner_active && !owner_active && !previous_release)
        $fatal(1, "shared compute owner dropped without accepted release");
      if (rs_shared_issue_valid && fc_shared_issue_valid)
        $fatal(1, "both frontends issued to the shared SA");
      previous_owner_active <= owner_active;
      previous_owner_fc <= active_owner_fc;
      previous_release <= owner_release_valid && owner_release_ready;
    end
  end
`endif
endmodule
