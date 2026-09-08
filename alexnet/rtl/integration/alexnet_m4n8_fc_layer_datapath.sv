`timescale 1ns/1ps

// Full-layer logical service boundary around exactly one unchanged FC DMA
// datapath. The controller owns configuration, input descriptors, K chunks,
// and weight release. External services supply parameters/packed AXIS words
// and commit result requests; no AXI DMA IP, DDR addressing, or flatten packer.
module alexnet_m4n8_fc_layer_datapath #(
    parameter bit EXTERNAL_COMPUTE = 1'b0
) (
    input logic clk, rst,
    input logic job_valid,
    output logic job_ready,
    input logic [3:0] job_layer_id,
    input logic [2:0] job_m_count,
    input logic [15:0] job_tag,

    output logic parameter_request_valid,
    output logic [3:0] active_layer_id,
    output logic [2:0] active_m_count,
    output logic [15:0] active_job_tag,
    output logic [15:0] active_n_base,
    output logic [13:0] active_k_offset,
    output logic [9:0] active_k_count,
    input logic parameter_valid,
    output logic parameter_ready,
    input logic [3:0] parameter_layer_id,
    input logic [15:0] parameter_job_tag,
    input logic [15:0] parameter_n_base,
    input logic signed [31:0] parameter_bias [0:7],
    input logic signed [17:0] parameter_multiplier [0:7],
    input logic [5:0] parameter_right_shift [0:7],

    output logic read_request_valid,
    input logic read_request_ready,
    output logic [1:0] read_request_destination,
    output logic [9:0] read_request_word_count,
    output logic [15:0] read_request_byte_count,
    output logic [2:0] read_request_m_count,
    output logic [15:0] read_request_tag,
    output logic result_request_valid,
    input logic result_request_ready,
    output logic [1:0] result_request_destination,
    output logic [15:0] result_request_byte_count,
    output logic [15:0] result_request_tag,
    input logic result_complete_valid,
    output logic result_complete_ready,
    input logic [15:0] result_complete_n_base,
    input logic [15:0] result_complete_tag,
    input logic result_complete_error,
    input logic service_error,


    input logic ce,
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

    output logic busy,
    output logic layer_done,
    output logic job_rejected,
    output logic layer_failed,
    output logic fault,
    output logic [3:0] fault_code,
    output logic [4:0] phase,
    output logic [9:0] completed_n_tiles,
    output logic [13:0] completed_chunks,
    output logic [23:0] completed_k_tokens,
    output logic [11:0] completed_output_words,

    // Optional shared compute link; ignored by the default local implementation.
    output logic shared_cfg_valid,
    input logic shared_cfg_ready,
    output logic [1:0] shared_cfg_destination,
    output logic [15:0] shared_cfg_n64_tile_base,
    output logic [2:0] shared_cfg_slice_index,
    output logic [7:0] shared_cfg_lane_mask,
    output logic signed [31:0] shared_cfg_bias [0:7],
    output logic signed [17:0] shared_cfg_multiplier [0:7],
    output logic [5:0] shared_cfg_right_shift [0:7],
    output logic [7:0] shared_cfg_relu,
    output logic shared_chunk_valid,
    input logic shared_chunk_ready,
    output logic [12:0] shared_chunk_word_count,
    output logic [7:0] shared_chunk_output_width,
    output logic [7:0] shared_chunk_n_lane_mask,
    output logic [15:0] shared_chunk_context_tag,
    output logic [15:0] shared_chunk_tile_tag_base,
    output logic [7:0] shared_chunk_index,
    output logic shared_chunk_first,
    output logic shared_chunk_final,
    output logic shared_tile_start_valid,
    input logic shared_tile_start_ready,
    output logic [2:0] shared_tile_m_count,
    output logic [7:0] shared_tile_n_lane_mask,
    output logic [15:0] shared_tile_tag,
    output logic shared_issue_valid,
    input logic shared_issue_ready,
    output logic shared_issue_last,
    output logic signed [7:0] shared_issue_act_lo [0:1],
    output logic signed [7:0] shared_issue_act_hi [0:1],
    output logic signed [7:0] shared_issue_weight [0:7],
    input logic shared_egress_valid,
    output logic shared_egress_ready,
    input logic [63:0] shared_egress_values,
    input logic [7:0] shared_egress_lane_mask,
    input logic [1:0] shared_egress_destination,
    input logic [2:0] shared_egress_slice,
    input logic [4:0] shared_egress_m,
    input logic [15:0] shared_egress_n_base,
    input logic [15:0] shared_egress_tile_tag,
    input logic shared_configured,
    input logic shared_compute_busy,
    input logic shared_transaction_active,
    input logic shared_chunk_active,
    input logic shared_tile_done,
    input logic shared_chunk_done,
    input logic shared_transaction_done,
    input logic shared_datapath_idle,
    input logic [2:0] shared_accum_bank_state,
    input logic shared_accum_context_error,
    input logic shared_protocol_error,
    input logic [6:0] shared_queued_count
);
  logic cfg_valid;
  logic cfg_ready;
  logic [1:0] cfg_destination;
  logic [15:0] cfg_n64_tile_base;
  logic [2:0] cfg_slice_index;
  logic [7:0] cfg_lane_mask;
  logic signed [31:0] cfg_bias [0:7];
  logic signed [17:0] cfg_multiplier [0:7];
  logic [5:0] cfg_right_shift [0:7];
  logic [7:0] cfg_relu;
  logic dma_descriptor_valid;
  logic dma_descriptor_ready;
  logic [1:0] dma_descriptor_destination;
  logic [9:0] dma_descriptor_word_count;
  logic [15:0] dma_descriptor_byte_count;
  logic [7:0] dma_descriptor_lane_mask;
  logic [15:0] dma_descriptor_tag;
  logic [9:0] dma_descriptor_k_count;
  logic [2:0] dma_descriptor_m_count;
  logic weight_release_valid;
  logic weight_release_ready;
  logic chunk_valid;
  logic chunk_ready;
  logic [9:0] chunk_k_count;
  logic [2:0] chunk_m_count;
  logic [7:0] chunk_n_lane_mask;
  logic [15:0] chunk_activation_tensor_tag;
  logic [15:0] chunk_weight_context_tag;
  logic [15:0] chunk_context_tag;
  logic [15:0] chunk_tile_tag;
  logic [7:0] chunk_index;
  logic chunk_first;
  logic chunk_final;
  logic core_fault;
  logic core_pipeline_idle;
  logic core_chunk_active;
  logic core_chunk_done;
  logic core_chunk_rejected;
  logic core_chunk_failed;
  logic core_transaction_active;
  logic core_transaction_done;
  logic core_dma_busy;
  logic core_dma_transfer_done;
  logic core_dma_descriptor_rejected;
  logic core_dma_transfer_failed;
  logic [1:0] core_weight_bank_state;
  logic [1:0] core_activation_bank_state;

  alexnet_fc_layer_controller u_controller (.*);
  alexnet_m4n8_fc_dma_io_datapath #(
      .EXTERNAL_COMPUTE(EXTERNAL_COMPUTE),
      .RUNTIME_SLICE_INDEX(1'b1)
  ) u_core (
      .shared_cfg_valid(shared_cfg_valid),
      .shared_cfg_ready(shared_cfg_ready),
      .shared_cfg_destination(shared_cfg_destination),
      .shared_cfg_n64_tile_base(shared_cfg_n64_tile_base),
      .shared_cfg_slice_index(shared_cfg_slice_index),
      .shared_cfg_lane_mask(shared_cfg_lane_mask),
      .shared_cfg_bias(shared_cfg_bias),
      .shared_cfg_multiplier(shared_cfg_multiplier),
      .shared_cfg_right_shift(shared_cfg_right_shift),
      .shared_cfg_relu(shared_cfg_relu),
      .shared_chunk_valid(shared_chunk_valid),
      .shared_chunk_ready(shared_chunk_ready),
      .shared_chunk_word_count(shared_chunk_word_count),
      .shared_chunk_output_width(shared_chunk_output_width),
      .shared_chunk_n_lane_mask(shared_chunk_n_lane_mask),
      .shared_chunk_context_tag(shared_chunk_context_tag),
      .shared_chunk_tile_tag_base(shared_chunk_tile_tag_base),
      .shared_chunk_index(shared_chunk_index),
      .shared_chunk_first(shared_chunk_first),
      .shared_chunk_final(shared_chunk_final),
      .shared_tile_start_valid(shared_tile_start_valid),
      .shared_tile_start_ready(shared_tile_start_ready),
      .shared_tile_m_count(shared_tile_m_count),
      .shared_tile_n_lane_mask(shared_tile_n_lane_mask),
      .shared_tile_tag(shared_tile_tag),
      .shared_issue_valid(shared_issue_valid),
      .shared_issue_ready(shared_issue_ready),
      .shared_issue_last(shared_issue_last),
      .shared_issue_act_lo(shared_issue_act_lo),
      .shared_issue_act_hi(shared_issue_act_hi),
      .shared_issue_weight(shared_issue_weight),
      .shared_egress_valid(shared_egress_valid),
      .shared_egress_ready(shared_egress_ready),
      .shared_egress_values(shared_egress_values),
      .shared_egress_lane_mask(shared_egress_lane_mask),
      .shared_egress_destination(shared_egress_destination),
      .shared_egress_slice(shared_egress_slice),
      .shared_egress_m(shared_egress_m),
      .shared_egress_n_base(shared_egress_n_base),
      .shared_egress_tile_tag(shared_egress_tile_tag),
      .shared_configured(shared_configured),
      .shared_compute_busy(shared_compute_busy),
      .shared_transaction_active(shared_transaction_active),
      .shared_chunk_active(shared_chunk_active),
      .shared_tile_done(shared_tile_done),
      .shared_chunk_done(shared_chunk_done),
      .shared_transaction_done(shared_transaction_done),
      .shared_datapath_idle(shared_datapath_idle),
      .shared_accum_bank_state(shared_accum_bank_state),
      .shared_accum_context_error(shared_accum_context_error),
      .shared_protocol_error(shared_protocol_error),
      .shared_queued_count(shared_queued_count),
      .cfg_valid(cfg_valid),
      .cfg_ready(cfg_ready),
      .cfg_destination(cfg_destination),
      .cfg_n64_tile_base(cfg_n64_tile_base),
      .cfg_slice_index(cfg_slice_index),
      .cfg_lane_mask(cfg_lane_mask),
      .cfg_bias(cfg_bias),
      .cfg_multiplier(cfg_multiplier),
      .cfg_right_shift(cfg_right_shift),
      .cfg_relu(cfg_relu),
      .dma_descriptor_valid(dma_descriptor_valid),
      .dma_descriptor_ready(dma_descriptor_ready),
      .dma_descriptor_destination(dma_descriptor_destination),
      .dma_descriptor_word_count(dma_descriptor_word_count),
      .dma_descriptor_byte_count(dma_descriptor_byte_count),
      .dma_descriptor_lane_mask(dma_descriptor_lane_mask),
      .dma_descriptor_tag(dma_descriptor_tag),
      .dma_descriptor_k_count(dma_descriptor_k_count),
      .dma_descriptor_m_count(dma_descriptor_m_count),
      .weight_release_valid(weight_release_valid),
      .weight_release_ready(weight_release_ready),
      .chunk_valid(chunk_valid),
      .chunk_ready(chunk_ready),
      .chunk_k_count(chunk_k_count),
      .chunk_m_count(chunk_m_count),
      .chunk_n_lane_mask(chunk_n_lane_mask),
      .chunk_activation_tensor_tag(chunk_activation_tensor_tag),
      .chunk_weight_context_tag(chunk_weight_context_tag),
      .chunk_context_tag(chunk_context_tag),
      .chunk_tile_tag(chunk_tile_tag),
      .chunk_index(chunk_index),
      .chunk_first(chunk_first),
      .chunk_final(chunk_final),
      .fault(core_fault),
      .pipeline_idle(core_pipeline_idle),
      .chunk_active(core_chunk_active),
      .chunk_done(core_chunk_done),
      .chunk_rejected(core_chunk_rejected),
      .chunk_failed(core_chunk_failed),
      .transaction_active(core_transaction_active),
      .transaction_done(core_transaction_done),
      .dma_busy(core_dma_busy),
      .dma_transfer_done(core_dma_transfer_done),
      .dma_descriptor_rejected(core_dma_descriptor_rejected),
      .dma_transfer_failed(core_dma_transfer_failed),
      .weight_bank_state(core_weight_bank_state),
      .activation_bank_state(core_activation_bank_state),
      .clk(clk),
      .rst(rst),
      .ce(ce),
      .s_axis_tdata(s_axis_tdata),
      .s_axis_tkeep(s_axis_tkeep),
      .s_axis_tvalid(s_axis_tvalid),
      .s_axis_tready(s_axis_tready),
      .s_axis_tlast(s_axis_tlast),
      .m_axis_tdata(m_axis_tdata),
      .m_axis_tkeep(m_axis_tkeep),
      .m_axis_tvalid(m_axis_tvalid),
      .m_axis_tready(m_axis_tready),
      .m_axis_tlast(m_axis_tlast),
      .dma_phase(),
      .dma_stream_error(),
      .dma_words_transferred(),
      .dma_accepted_descriptors(),
      .dma_rejected_descriptors(),
      .dma_completed_transfers(),
      .dma_failed_transfers(),
      .result_dma_busy(),
      .result_dma_transfer_done(),
      .result_dma_protocol_error(),
      .result_dma_words_transferred(),
      .result_dma_completed_transfers(),
      .activation_fill_active(),
      .activation_read_active(),
      .activation_words_forwarded(),
      .configured(),
      .compute_busy(),
      .phase(),
      .accum_bank_state(),
      .completed_replays(),
      .accepted_chunks(),
      .completed_chunks(),
      .rejected_chunks(),
      .failed_chunks(),
      .completed_k_tokens(),
      .queued_count()
  );
endmodule
