`timescale 1ns/1ps

// Full graph-control plus shared-compute integration boundary.
// One start request drives Conv1..Conv5 command expansion, the drained
// Conv-to-FC ownership handoff, and FC6..FC8 layer jobs into exactly one
// alexnet_m4n8_shared_compute_top instance.
//
// The ports below are logical parameter/payload/result services. Physical
// DDR addressing, pooling storage, FC6 flatten injection, AXI-Lite control,
// and the KV260 PS/camera runtime are intentionally outside this top.
module alexnet_m4n8_graph_compute_top (
    input logic clk,
    input logic rst,
    input logic ce,
    input logic start_valid,
    output logic start_ready,
    input logic [15:0] start_tag,

    input logic [127:0] s_axis_tdata,
    input logic [15:0] s_axis_tkeep,
    input logic s_axis_tvalid,
    output logic s_axis_tready,
    input logic s_axis_tlast,
    output logic [127:0] m_axis_tdata,
    output logic [15:0] m_axis_tkeep,
    output logic m_axis_tvalid,
    input logic m_axis_tready,
    output logic m_axis_tlast,

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

    output logic conv_parameter_request_valid,
    input  logic conv_parameter_request_ready,
    output logic [2:0] conv_parameter_request_layer_id,
    output logic [15:0] conv_parameter_request_job_tag,
    output logic [15:0] conv_parameter_request_n_base,
    input  logic conv_parameter_valid,
    output logic conv_parameter_ready,
    input  logic [2:0] conv_parameter_layer_id,
    input  logic [15:0] conv_parameter_job_tag,
    input  logic [15:0] conv_parameter_n_base,
    input  logic signed [31:0] conv_parameter_bias [0:7],
    input  logic signed [17:0] conv_parameter_multiplier [0:7],
    input  logic [5:0] conv_parameter_right_shift [0:7],

    output logic conv_result_commit_request_valid,
    input  logic conv_result_commit_request_ready,
    output logic [2:0] conv_result_commit_layer_id,
    output logic [15:0] conv_result_commit_job_tag,
    output logic [7:0] conv_result_commit_output_h,
    output logic [7:0] conv_result_commit_output_w,
    output logic [9:0] conv_result_commit_output_channels,
    output logic conv_result_commit_pool_enable,
    output logic [5:0] conv_result_commit_pool_output_h,
    output logic [5:0] conv_result_commit_pool_output_w,
    output logic conv_result_commit_flatten_output,
    input  logic conv_result_complete_valid,
    output logic conv_result_complete_ready,
    input  logic [2:0] conv_result_complete_layer_id,
    input  logic [15:0] conv_result_complete_job_tag,
    input  logic conv_result_complete_error,
    input  logic conv_service_error,

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

    output logic busy,
    output logic inference_done,
    output logic inference_failed,
    output logic fault,
    output logic [3:0] fault_code,
    output logic [4:0] graph_phase,
    output logic [3:0] active_layer_id,
    output logic [15:0] active_inference_tag,
    output logic [2:0] completed_conv_layers,
    output logic [1:0] completed_fc_layers,
    output logic [12:0] active_conv_completed_commands,
    output logic [5:0] active_conv_completed_n8_tiles,
    output logic [15:0] active_conv_completed_output_words,
    output logic compute_fault,
    output logic rs_scheduler_busy,
    output logic rs_scheduler_fault,
    output logic fc_busy,
    output logic fc_fault
);
  logic owner_valid, owner_ready, owner_fc;
  logic owner_release_valid, owner_release_ready;
  logic owner_active, active_owner_fc, owner_released;
  logic owner_fault;

  logic rs_cfg_valid, rs_cfg_ready;
  logic [1:0] rs_cfg_destination;
  logic [15:0] rs_cfg_n64_tile_base;
  logic [2:0] rs_cfg_slice_index;
  logic [7:0] rs_cfg_lane_mask, rs_cfg_relu;
  logic signed [31:0] rs_cfg_bias [0:7];
  logic signed [17:0] rs_cfg_multiplier [0:7];
  logic [5:0] rs_cfg_right_shift [0:7];
  logic rs_command_valid, rs_command_ready;
  logic [15:0] rs_command_id;
  logic rs_command_activation_streaming;
  logic [1:0] rs_command_activation_destination;
  logic [10:0] rs_command_activation_word_count;
  logic [15:0] rs_command_activation_byte_count;
  logic [7:0] rs_command_activation_lane_mask;
  logic [15:0] rs_command_activation_tensor_tag;
  logic [10:0] rs_command_weight_word_count;
  logic [15:0] rs_command_weight_byte_count;
  logic [7:0] rs_command_weight_lane_mask;
  logic [15:0] rs_command_weight_context_tag;
  logic rs_command_result_enable;
  logic [12:0] rs_command_result_word_count;
  logic [15:0] rs_command_result_byte_count;
  logic [1:0] rs_command_result_destination;
  logic [2:0] rs_command_result_slice;
  logic [15:0] rs_command_result_n_base;
  logic [7:0] rs_command_result_lane_mask;
  logic [15:0] rs_command_result_first_tile_tag;
  logic [7:0] rs_command_chunk_input_h, rs_command_chunk_input_w;
  logic [3:0] rs_command_chunk_channel_count;
  logic [7:0] rs_command_chunk_input_lane_mask;
  logic [3:0] rs_command_chunk_kernel;
  logic [2:0] rs_command_chunk_stride, rs_command_chunk_padding;
  logic [9:0] rs_command_chunk_k_count;
  logic [15:0] rs_command_chunk_weight_context_tag;
  logic [12:0] rs_command_chunk_word_count;
  logic [7:0] rs_command_chunk_output_width;
  logic [15:0] rs_command_chunk_accum_context_tag;
  logic [15:0] rs_command_chunk_tile_tag_base;
  logic [7:0] rs_command_chunk_index;
  logic rs_command_chunk_first, rs_command_chunk_final;
  logic rs_command_done, rs_command_rejected, rs_command_error;
  logic [15:0] rs_completed_command_id;
  logic rs_clear_fault;
  logic [3:0] rs_scheduler_fault_code;
  logic [4:0] rs_scheduler_phase;
  logic rs_fault_cleared;
  logic [15:0] rs_active_command_id;
  logic [15:0] rs_accepted_commands;
  logic [15:0] rs_completed_commands;
  logic [15:0] rs_rejected_commands;
  logic rs_configured;
  logic rs_chunk_frame_active;
  logic rs_chunk_done;
  logic rs_chunk_rejected;
  logic rs_compute_busy;
  logic rs_transaction_active;
  logic rs_accum_chunk_active;
  logic rs_transaction_done;
  logic rs_pipeline_idle;
  logic rs_datapath_pipeline_idle;
  logic rs_protocol_error;
  logic rs_datapath_protocol_error;
  logic rs_activation_context_error;
  logic rs_accum_context_error;
  logic rs_weight_context_error;
  logic [15:0] rs_completed_tile_count;
  logic [15:0] rs_completed_weight_replays;
  logic [1:0] rs_weight_bank_state;
  logic rs_weight_resident_valid;
  logic [9:0] rs_resident_weight_k_count;
  logic [9:0] rs_resident_weight_words_written;
  logic [7:0] rs_resident_weight_n_lane_mask;
  logic [15:0] rs_resident_weight_context_tag;
  logic rs_weight_replay_done;
  logic [2:0] rs_accum_bank_state;
  logic [6:0] rs_queued_count;
  logic rs_activation_ready_tensor_valid;
  logic rs_activation_ready_tensor_bank;
  logic [15:0] rs_activation_ready_tensor_tag;
  logic [1:0] rs_activation_ready_count;
  logic rs_activation_fill_active;
  logic rs_activation_fill_bank;
  logic rs_activation_read_active;
  logic rs_activation_read_bank;
  logic rs_activation_read_segment;
  logic rs_activation_read_done;
  logic [10:0] rs_activation_words_forwarded;
  logic [15:0] rs_activation_stream_words_forwarded;
  logic rs_dma_busy;
  logic rs_dma_transfer_active;
  logic rs_dma_transfer_done;
  logic rs_dma_descriptor_rejected;
  logic rs_dma_descriptor_error;
  logic rs_dma_stream_error;
  logic rs_dma_protocol_error;
  logic [1:0] rs_dma_active_destination;
  logic [10:0] rs_dma_words_transferred;
  logic [15:0] rs_dma_completed_transfers;
  logic rs_result_dma_busy;
  logic rs_result_dma_transfer_active;
  logic rs_result_dma_transfer_done;
  logic rs_result_dma_descriptor_rejected;
  logic rs_result_dma_descriptor_error;
  logic rs_result_dma_metadata_error;
  logic rs_result_dma_protocol_error;
  logic [1:0] rs_result_dma_active_destination;
  logic [2:0] rs_result_dma_active_slice;
  logic [15:0] rs_result_dma_active_n_base;
  logic [7:0] rs_result_dma_active_lane_mask;
  logic [15:0] rs_result_dma_active_first_tile_tag;
  logic [12:0] rs_result_dma_words_accepted;
  logic [12:0] rs_result_dma_words_transferred;
  logic [12:0] rs_result_dma_beats_transferred;
  logic [15:0] rs_result_dma_completed_transfers;
  logic [15:0] rs_result_dma_completed_first_tile_tag;
  logic [15:0] rs_result_dma_completed_last_tile_tag;

  logic fc_job_valid, fc_job_ready;
  logic [3:0] fc_job_layer_id;
  logic [2:0] fc_job_m_count;
  logic [15:0] fc_job_tag;
  logic fc_layer_done, fc_job_rejected, fc_layer_failed;
  logic [3:0] fc_fault_code;
  logic [4:0] fc_phase;
  logic [9:0] fc_completed_n_tiles;
  logic [13:0] fc_completed_chunks;
  logic [23:0] fc_completed_k_tokens;
  logic [11:0] fc_completed_output_words;

  assign owner_fault = compute_fault;
  assign rs_clear_fault = 1'b0;

  alexnet_graph_compute_orchestrator u_orchestrator (
      .owner_fault(owner_fault),
      .rs_completed_command_id(rs_completed_command_id),
      .rs_cfg_bias(rs_cfg_bias),
      .rs_cfg_multiplier(rs_cfg_multiplier),
      .rs_cfg_right_shift(rs_cfg_right_shift),
      .*
  );

  alexnet_m4n8_shared_compute_top #(
      .PHYS_ROWS(4)
  ) u_compute (
      .fault(compute_fault),
      .rs_cfg_bias(rs_cfg_bias),
      .rs_cfg_multiplier(rs_cfg_multiplier),
      .rs_cfg_right_shift(rs_cfg_right_shift),
      .*
  );

`ifndef SYNTHESIS
  initial begin
    if ($bits(rs_command_result_word_count) != 13)
      $fatal(1, "graph compute top lost 4096-word result command width");
  end

  always_ff @(posedge clk) begin
    if (!rst) begin
      if (owner_active && active_owner_fc && rs_command_valid)
        $fatal(1, "graph compute top exposed Conv command during FC ownership");
      if (owner_active && !active_owner_fc && fc_job_valid)
        $fatal(1, "graph compute top exposed FC job during Conv ownership");
    end
  end
`endif
endmodule
