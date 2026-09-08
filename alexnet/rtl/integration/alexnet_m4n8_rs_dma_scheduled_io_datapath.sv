`timescale 1ns/1ps

// Software-command boundary around the measured full MM2S/compute/S2MM path.
// The scheduler is the only owner of DMA descriptors, weight release, and
// chunk launch. All data-plane children remain unchanged.
module alexnet_m4n8_rs_dma_scheduled_io_datapath #(
    parameter bit EXTERNAL_COMPUTE = 1'b0,
    parameter int SLICE_INDEX = 0,
    parameter int FIFO_DEPTH = 64,
    parameter int MAX_INPUT_WIDTH = 224,
    parameter int WEIGHT_DEPTH = 968,
    parameter int SEGMENT_DEPTH = 512,
    parameter int DIM_W = 8,
    parameter int K_INDEX_W = 10,
    parameter int TILE_TAG_W = 16,
    parameter int TENSOR_TAG_W = 16,
    parameter int WEIGHT_CONTEXT_TAG_W = 16,
    parameter int ACCUM_CONTEXT_TAG_W = 16,
    parameter int CHUNK_INDEX_W = 8,
    parameter int N_BASE_W = 16,
    parameter int DMA_BYTE_COUNT_W = 16,
    parameter int RESULT_MAX_WORDS = 2 * SEGMENT_DEPTH,
    parameter int COMMAND_ID_W = 16,
    parameter int WEIGHT_COUNT_W = $clog2(WEIGHT_DEPTH + 1),
    parameter int ACTIVATION_COUNT_W = $clog2(2 * SEGMENT_DEPTH + 1),
    parameter int BANK_COUNT_W = $clog2(2 * SEGMENT_DEPTH + 1)
) (
    input logic clk,
    input logic rst,
    input logic ce,

    input  logic cfg_valid,
    output logic cfg_ready,
    input  logic [1:0] cfg_destination,
    input  logic [N_BASE_W-1:0] cfg_n64_tile_base,
    input  logic [2:0] cfg_slice_index,
    input  logic [7:0] cfg_lane_mask,
    input  logic signed [31:0] cfg_bias [0:7],
    input  logic signed [17:0] cfg_multiplier [0:7],
    input  logic [5:0] cfg_right_shift [0:7],
    input  logic [7:0] cfg_relu,

    input  logic command_valid,
    output logic command_ready,
    input  logic [COMMAND_ID_W-1:0] command_id,
    input  logic command_activation_streaming,
    input  logic [1:0] command_activation_destination,
    input  logic [ACTIVATION_COUNT_W-1:0]
        command_activation_word_count,
    input  logic [DMA_BYTE_COUNT_W-1:0]
        command_activation_byte_count,
    input  logic [7:0] command_activation_lane_mask,
    input  logic [TENSOR_TAG_W-1:0] command_activation_tensor_tag,
    input  logic [ACTIVATION_COUNT_W-1:0] command_weight_word_count,
    input  logic [DMA_BYTE_COUNT_W-1:0] command_weight_byte_count,
    input  logic [7:0] command_weight_lane_mask,
    input  logic [WEIGHT_CONTEXT_TAG_W-1:0]
        command_weight_context_tag,
    input  logic command_result_enable,
    input  logic [BANK_COUNT_W-1:0] command_result_word_count,
    input  logic [DMA_BYTE_COUNT_W-1:0] command_result_byte_count,
    input  logic [1:0] command_result_destination,
    input  logic [2:0] command_result_slice,
    input  logic [N_BASE_W-1:0] command_result_n_base,
    input  logic [7:0] command_result_lane_mask,
    input  logic [TILE_TAG_W-1:0] command_result_first_tile_tag,
    input  logic [DIM_W-1:0] command_chunk_input_h,
    input  logic [DIM_W-1:0] command_chunk_input_w,
    input  logic [3:0] command_chunk_channel_count,
    input  logic [7:0] command_chunk_input_lane_mask,
    input  logic [3:0] command_chunk_kernel,
    input  logic [2:0] command_chunk_stride,
    input  logic [2:0] command_chunk_padding,
    input  logic [WEIGHT_COUNT_W-1:0] command_chunk_k_count,
    input  logic [WEIGHT_CONTEXT_TAG_W-1:0]
        command_chunk_weight_context_tag,
    input  logic [BANK_COUNT_W-1:0] command_chunk_word_count,
    input  logic [DIM_W-1:0] command_chunk_output_width,
    input  logic [ACCUM_CONTEXT_TAG_W-1:0]
        command_chunk_accum_context_tag,
    input  logic [TILE_TAG_W-1:0] command_chunk_tile_tag_base,
    input  logic [CHUNK_INDEX_W-1:0] command_chunk_index,
    input  logic command_chunk_first,
    input  logic command_chunk_final,
    input  logic clear_fault,

    input  logic [127:0] s_axis_tdata,
    input  logic [15:0] s_axis_tkeep,
    input  logic s_axis_tvalid,
    output logic s_axis_tready,
    input  logic s_axis_tlast,

    // Mirror the scheduler's accepted MM2S/S2MM descriptors to the physical
    // DDR command plane.  Each descriptor is forked atomically: neither the
    // local AXIS adapter nor the external command bridge can consume it alone.
    output logic rs_mm2s_request_valid,
    input  logic rs_mm2s_request_ready,
    output logic [1:0] rs_mm2s_request_destination,
    output logic [ACTIVATION_COUNT_W-1:0] rs_mm2s_request_word_count,
    output logic [DMA_BYTE_COUNT_W-1:0] rs_mm2s_request_byte_count,
    output logic [TENSOR_TAG_W-1:0] rs_mm2s_request_tag,
    output logic [N_BASE_W-1:0] rs_mm2s_request_n_base,
    output logic [CHUNK_INDEX_W-1:0] rs_mm2s_request_chunk_index,
    output logic rs_s2mm_request_valid,
    input  logic rs_s2mm_request_ready,
    output logic [BANK_COUNT_W-1:0] rs_s2mm_request_word_count,
    output logic [DMA_BYTE_COUNT_W-1:0] rs_s2mm_request_byte_count,
    output logic [N_BASE_W-1:0] rs_s2mm_request_n_base,
    output logic [TILE_TAG_W-1:0] rs_s2mm_request_tag,

    input  logic activation_stream_valid,
    output logic activation_stream_ready,
    input  logic [63:0] activation_stream_values,
    input  logic [7:0] activation_stream_lane_mask,
    input  logic activation_stream_last,
    output logic [127:0] m_axis_tdata,
    output logic [15:0] m_axis_tkeep,
    output logic m_axis_tvalid,
    input  logic m_axis_tready,
    output logic m_axis_tlast,

    output logic scheduler_busy,
    output logic scheduler_fault,
    output logic [3:0] scheduler_fault_code,
    output logic [4:0] scheduler_phase,
    output logic command_done,
    output logic command_rejected,
    output logic fault_cleared,
    output logic command_error,
    output logic [COMMAND_ID_W-1:0] active_command_id,
    output logic [COMMAND_ID_W-1:0] completed_command_id,
    output logic [15:0] accepted_commands,
    output logic [15:0] completed_commands,
    output logic [15:0] rejected_commands,

    output logic configured,
    output logic chunk_frame_active,
    output logic chunk_done,
    output logic chunk_rejected,
    output logic compute_busy,
    output logic transaction_active,
    output logic accum_chunk_active,
    output logic transaction_done,
    output logic pipeline_idle,
    output logic datapath_pipeline_idle,
    output logic protocol_error,
    output logic datapath_protocol_error,
    output logic activation_context_error,
    output logic accum_context_error,
    output logic weight_context_error,
    output logic [15:0] completed_tile_count,
    output logic [15:0] completed_weight_replays,
    output logic [1:0] weight_bank_state,
    output logic weight_resident_valid,
    output logic [WEIGHT_COUNT_W-1:0] resident_weight_k_count,
    output logic [WEIGHT_COUNT_W-1:0] resident_weight_words_written,
    output logic [7:0] resident_weight_n_lane_mask,
    output logic [WEIGHT_CONTEXT_TAG_W-1:0]
        resident_weight_context_tag,
    output logic weight_replay_done,
    output logic [2:0] accum_bank_state,
    output logic [$clog2(FIFO_DEPTH+1)-1:0] queued_count,

    output logic activation_ready_tensor_valid,
    output logic activation_ready_tensor_bank,
    output logic [TENSOR_TAG_W-1:0] activation_ready_tensor_tag,
    output logic [1:0] activation_ready_count,
    output logic activation_fill_active,
    output logic activation_fill_bank,
    output logic activation_read_active,
    output logic activation_read_bank,
    output logic activation_read_segment,
    output logic activation_read_done,
    output logic [ACTIVATION_COUNT_W-1:0] activation_words_forwarded,
    output logic [15:0] activation_stream_words_forwarded,

    output logic dma_busy,
    output logic dma_transfer_active,
    output logic dma_transfer_done,
    output logic dma_descriptor_rejected,
    output logic dma_descriptor_error,
    output logic dma_stream_error,
    output logic dma_protocol_error,
    output logic [1:0] dma_active_destination,
    output logic [ACTIVATION_COUNT_W-1:0] dma_words_transferred,
    output logic [15:0] dma_completed_transfers,

    output logic result_dma_busy,
    output logic result_dma_transfer_active,
    output logic result_dma_transfer_done,
    output logic result_dma_descriptor_rejected,
    output logic result_dma_descriptor_error,
    output logic result_dma_metadata_error,
    output logic result_dma_protocol_error,
    output logic [1:0] result_dma_active_destination,
    output logic [2:0] result_dma_active_slice,
    output logic [N_BASE_W-1:0] result_dma_active_n_base,
    output logic [7:0] result_dma_active_lane_mask,
    output logic [TILE_TAG_W-1:0] result_dma_active_first_tile_tag,
    output logic [BANK_COUNT_W-1:0] result_dma_words_accepted,
    output logic [BANK_COUNT_W-1:0] result_dma_words_transferred,
    output logic [BANK_COUNT_W-1:0] result_dma_beats_transferred,
    output logic [15:0] result_dma_completed_transfers,
    output logic [TILE_TAG_W-1:0]
        result_dma_completed_first_tile_tag,
    output logic [TILE_TAG_W-1:0]
        result_dma_completed_last_tile_tag,

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

  logic scheduler_dma_clear_error;
  logic scheduler_dma_descriptor_valid;
  logic scheduler_dma_descriptor_ready;
  logic datapath_dma_descriptor_valid;
  logic datapath_dma_descriptor_ready;
  logic [1:0] scheduler_dma_descriptor_destination;
  logic [ACTIVATION_COUNT_W-1:0]
      scheduler_dma_descriptor_word_count;
  logic [DMA_BYTE_COUNT_W-1:0]
      scheduler_dma_descriptor_byte_count;
  logic [7:0] scheduler_dma_descriptor_lane_mask;
  logic [TENSOR_TAG_W-1:0] scheduler_dma_descriptor_tag;

  logic scheduler_result_dma_clear_error;
  logic scheduler_result_dma_descriptor_valid;
  logic scheduler_result_dma_descriptor_ready;
  logic datapath_result_dma_descriptor_valid;
  logic datapath_result_dma_descriptor_ready;
  logic [BANK_COUNT_W-1:0]
      scheduler_result_dma_descriptor_word_count;
  logic [DMA_BYTE_COUNT_W-1:0]
      scheduler_result_dma_descriptor_byte_count;
  logic [1:0] scheduler_result_dma_descriptor_destination;
  logic [2:0] scheduler_result_dma_descriptor_slice;
  logic [N_BASE_W-1:0] scheduler_result_dma_descriptor_n_base;
  logic [7:0] scheduler_result_dma_descriptor_lane_mask;
  logic [TILE_TAG_W-1:0]
      scheduler_result_dma_descriptor_first_tile_tag;

  logic scheduler_weight_release_valid;
  logic scheduler_weight_release_ready;
  logic scheduler_chunk_valid;
  logic scheduler_chunk_ready;
  logic scheduler_chunk_activation_streaming;
  logic [TENSOR_TAG_W-1:0] scheduler_chunk_activation_tensor_tag;
  logic [DIM_W-1:0] scheduler_chunk_input_h;
  logic [DIM_W-1:0] scheduler_chunk_input_w;
  logic [3:0] scheduler_chunk_channel_count;
  logic [7:0] scheduler_chunk_input_lane_mask;
  logic [3:0] scheduler_chunk_kernel;
  logic [2:0] scheduler_chunk_stride;
  logic [2:0] scheduler_chunk_padding;
  logic [WEIGHT_COUNT_W-1:0] scheduler_chunk_k_count;
  logic [WEIGHT_CONTEXT_TAG_W-1:0]
      scheduler_chunk_weight_context_tag;
  logic [BANK_COUNT_W-1:0] scheduler_chunk_word_count;
  logic [DIM_W-1:0] scheduler_chunk_output_width;
  logic [ACCUM_CONTEXT_TAG_W-1:0]
      scheduler_chunk_accum_context_tag;
  logic [TILE_TAG_W-1:0] scheduler_chunk_tile_tag_base;
  logic [CHUNK_INDEX_W-1:0] scheduler_chunk_index;
  logic scheduler_chunk_first;
  logic scheduler_chunk_final;
  logic datapath_command_boundary_idle;
  logic [N_BASE_W-1:0] physical_n_base_q;
  logic [CHUNK_INDEX_W-1:0] physical_chunk_index_q;

  assign pipeline_idle = datapath_pipeline_idle && !scheduler_busy;
  assign protocol_error = datapath_protocol_error || scheduler_fault;
  assign datapath_command_boundary_idle =
      !chunk_frame_active && !compute_busy && !accum_chunk_active &&
      !activation_read_active;

  // Ready-qualified valids make the fork atomic. This prevents an internal
  // DMA adapter from arming unless the physical DMA command is also accepted,
  // and prevents the command bridge from advancing without the adapter.
  assign rs_mm2s_request_valid = scheduler_dma_descriptor_valid &&
                                  datapath_dma_descriptor_ready;
  assign datapath_dma_descriptor_valid = scheduler_dma_descriptor_valid &&
                                          rs_mm2s_request_ready;
  assign scheduler_dma_descriptor_ready = datapath_dma_descriptor_ready &&
                                           rs_mm2s_request_ready;
  assign rs_mm2s_request_destination = scheduler_dma_descriptor_destination;
  assign rs_mm2s_request_word_count = scheduler_dma_descriptor_word_count;
  assign rs_mm2s_request_byte_count = scheduler_dma_descriptor_byte_count;
  assign rs_mm2s_request_tag = scheduler_dma_descriptor_tag;
  assign rs_mm2s_request_n_base = physical_n_base_q;
  assign rs_mm2s_request_chunk_index = physical_chunk_index_q;

  assign rs_s2mm_request_valid = scheduler_result_dma_descriptor_valid &&
                                  datapath_result_dma_descriptor_ready;
  assign datapath_result_dma_descriptor_valid =
      scheduler_result_dma_descriptor_valid && rs_s2mm_request_ready;
  assign scheduler_result_dma_descriptor_ready =
      datapath_result_dma_descriptor_ready && rs_s2mm_request_ready;
  assign rs_s2mm_request_word_count =
      scheduler_result_dma_descriptor_word_count;
  assign rs_s2mm_request_byte_count =
      scheduler_result_dma_descriptor_byte_count;
  assign rs_s2mm_request_n_base = scheduler_result_dma_descriptor_n_base;
  assign rs_s2mm_request_tag =
      scheduler_result_dma_descriptor_first_tile_tag;

  always_ff @(posedge clk) begin
    if (rst) begin
      physical_n_base_q <= '0;
      physical_chunk_index_q <= '0;
    end else if (command_valid && command_ready) begin
      physical_n_base_q <= command_result_n_base;
      physical_chunk_index_q <= command_chunk_index;
    end
  end

  alexnet_dma_chunk_scheduler #(
      .COUNT_W(ACTIVATION_COUNT_W),
      .RESULT_COUNT_W(BANK_COUNT_W),
      .BYTE_COUNT_W(DMA_BYTE_COUNT_W),
      .DIM_W(DIM_W),
      .K_COUNT_W(WEIGHT_COUNT_W),
      .TILE_TAG_W(TILE_TAG_W),
      .TENSOR_TAG_W(TENSOR_TAG_W),
      .WEIGHT_CONTEXT_TAG_W(WEIGHT_CONTEXT_TAG_W),
      .ACCUM_CONTEXT_TAG_W(ACCUM_CONTEXT_TAG_W),
      .CHUNK_INDEX_W(CHUNK_INDEX_W),
      .N_BASE_W(N_BASE_W),
      .COMMAND_ID_W(COMMAND_ID_W)
  ) u_scheduler (
      .clk(clk),
      .rst(rst),
      .command_valid(command_valid),
      .command_ready(command_ready),
      .command_id(command_id),
      .command_activation_streaming(command_activation_streaming),
      .command_activation_destination(command_activation_destination),
      .command_activation_word_count(command_activation_word_count),
      .command_activation_byte_count(command_activation_byte_count),
      .command_activation_lane_mask(command_activation_lane_mask),
      .command_activation_tensor_tag(command_activation_tensor_tag),
      .command_weight_word_count(command_weight_word_count),
      .command_weight_byte_count(command_weight_byte_count),
      .command_weight_lane_mask(command_weight_lane_mask),
      .command_weight_context_tag(command_weight_context_tag),
      .command_result_enable(command_result_enable),
      .command_result_word_count(command_result_word_count),
      .command_result_byte_count(command_result_byte_count),
      .command_result_destination(command_result_destination),
      .command_result_slice(command_result_slice),
      .command_result_n_base(command_result_n_base),
      .command_result_lane_mask(command_result_lane_mask),
      .command_result_first_tile_tag(command_result_first_tile_tag),
      .command_chunk_input_h(command_chunk_input_h),
      .command_chunk_input_w(command_chunk_input_w),
      .command_chunk_channel_count(command_chunk_channel_count),
      .command_chunk_input_lane_mask(command_chunk_input_lane_mask),
      .command_chunk_kernel(command_chunk_kernel),
      .command_chunk_stride(command_chunk_stride),
      .command_chunk_padding(command_chunk_padding),
      .command_chunk_k_count(command_chunk_k_count),
      .command_chunk_weight_context_tag(
          command_chunk_weight_context_tag),
      .command_chunk_word_count(command_chunk_word_count),
      .command_chunk_output_width(command_chunk_output_width),
      .command_chunk_accum_context_tag(command_chunk_accum_context_tag),
      .command_chunk_tile_tag_base(command_chunk_tile_tag_base),
      .command_chunk_index(command_chunk_index),
      .command_chunk_first(command_chunk_first),
      .command_chunk_final(command_chunk_final),
      .datapath_configured(configured),
      .command_boundary_idle(datapath_command_boundary_idle),
      .pipeline_idle(datapath_pipeline_idle),
      .protocol_error(datapath_protocol_error),
      .dma_busy(dma_busy),
      .dma_transfer_done(dma_transfer_done),
      .dma_descriptor_rejected(dma_descriptor_rejected),
      .result_dma_busy(result_dma_busy),
      .result_dma_transfer_active(result_dma_transfer_active),
      .result_dma_transfer_done(result_dma_transfer_done),
      .result_dma_descriptor_rejected(result_dma_descriptor_rejected),
      .weight_resident_valid(weight_resident_valid),
      .chunk_done(chunk_done),
      .chunk_rejected(chunk_rejected),
      .dma_clear_error(scheduler_dma_clear_error),
      .dma_descriptor_valid(scheduler_dma_descriptor_valid),
      .dma_descriptor_ready(scheduler_dma_descriptor_ready),
      .dma_descriptor_destination(scheduler_dma_descriptor_destination),
      .dma_descriptor_word_count(scheduler_dma_descriptor_word_count),
      .dma_descriptor_byte_count(scheduler_dma_descriptor_byte_count),
      .dma_descriptor_lane_mask(scheduler_dma_descriptor_lane_mask),
      .dma_descriptor_tag(scheduler_dma_descriptor_tag),
      .result_dma_clear_error(scheduler_result_dma_clear_error),
      .result_dma_descriptor_valid(
          scheduler_result_dma_descriptor_valid),
      .result_dma_descriptor_ready(
          scheduler_result_dma_descriptor_ready),
      .result_dma_descriptor_word_count(
          scheduler_result_dma_descriptor_word_count),
      .result_dma_descriptor_byte_count(
          scheduler_result_dma_descriptor_byte_count),
      .result_dma_descriptor_destination(
          scheduler_result_dma_descriptor_destination),
      .result_dma_descriptor_slice(scheduler_result_dma_descriptor_slice),
      .result_dma_descriptor_n_base(scheduler_result_dma_descriptor_n_base),
      .result_dma_descriptor_lane_mask(
          scheduler_result_dma_descriptor_lane_mask),
      .result_dma_descriptor_first_tile_tag(
          scheduler_result_dma_descriptor_first_tile_tag),
      .weight_release_valid(scheduler_weight_release_valid),
      .weight_release_ready(scheduler_weight_release_ready),
      .chunk_valid(scheduler_chunk_valid),
      .chunk_ready(scheduler_chunk_ready),
      .chunk_activation_streaming(scheduler_chunk_activation_streaming),
      .chunk_activation_tensor_tag(scheduler_chunk_activation_tensor_tag),
      .chunk_input_h(scheduler_chunk_input_h),
      .chunk_input_w(scheduler_chunk_input_w),
      .chunk_channel_count(scheduler_chunk_channel_count),
      .chunk_input_lane_mask(scheduler_chunk_input_lane_mask),
      .chunk_kernel(scheduler_chunk_kernel),
      .chunk_stride(scheduler_chunk_stride),
      .chunk_padding(scheduler_chunk_padding),
      .chunk_k_count(scheduler_chunk_k_count),
      .chunk_weight_context_tag(scheduler_chunk_weight_context_tag),
      .chunk_word_count(scheduler_chunk_word_count),
      .chunk_output_width(scheduler_chunk_output_width),
      .chunk_accum_context_tag(scheduler_chunk_accum_context_tag),
      .chunk_tile_tag_base(scheduler_chunk_tile_tag_base),
      .chunk_index(scheduler_chunk_index),
      .chunk_first(scheduler_chunk_first),
      .chunk_final(scheduler_chunk_final),
      .clear_fault(clear_fault),
      .scheduler_busy(scheduler_busy),
      .scheduler_fault(scheduler_fault),
      .fault_code(scheduler_fault_code),
      .phase(scheduler_phase),
      .command_done(command_done),
      .command_rejected(command_rejected),
      .fault_cleared(fault_cleared),
      .command_error(command_error),
      .active_command_id(active_command_id),
      .completed_command_id(completed_command_id),
      .accepted_commands(accepted_commands),
      .completed_commands(completed_commands),
      .rejected_commands(rejected_commands)
  );

  alexnet_m4n8_rs_dma_io_activation_resident_weight_dual_accum_datapath #(
      .EXTERNAL_COMPUTE(EXTERNAL_COMPUTE),
      .SLICE_INDEX(SLICE_INDEX),
      .FIFO_DEPTH(FIFO_DEPTH),
      .MAX_INPUT_WIDTH(MAX_INPUT_WIDTH),
      .WEIGHT_DEPTH(WEIGHT_DEPTH),
      .SEGMENT_DEPTH(SEGMENT_DEPTH),
      .DIM_W(DIM_W),
      .K_INDEX_W(K_INDEX_W),
      .TILE_TAG_W(TILE_TAG_W),
      .TENSOR_TAG_W(TENSOR_TAG_W),
      .WEIGHT_CONTEXT_TAG_W(WEIGHT_CONTEXT_TAG_W),
      .ACCUM_CONTEXT_TAG_W(ACCUM_CONTEXT_TAG_W),
      .CHUNK_INDEX_W(CHUNK_INDEX_W),
      .N_BASE_W(N_BASE_W),
      .DMA_BYTE_COUNT_W(DMA_BYTE_COUNT_W),
      .RESULT_MAX_WORDS(RESULT_MAX_WORDS),
      .WEIGHT_COUNT_W(WEIGHT_COUNT_W),
      .ACTIVATION_COUNT_W(ACTIVATION_COUNT_W),
      .BANK_COUNT_W(BANK_COUNT_W)
  ) u_datapath (
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
      .clk(clk),
      .rst(rst),
      .ce(ce),
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
      .dma_clear_error(scheduler_dma_clear_error),
      .dma_descriptor_valid(datapath_dma_descriptor_valid),
      .dma_descriptor_ready(datapath_dma_descriptor_ready),
      .dma_descriptor_destination(scheduler_dma_descriptor_destination),
      .dma_descriptor_word_count(scheduler_dma_descriptor_word_count),
      .dma_descriptor_byte_count(scheduler_dma_descriptor_byte_count),
      .dma_descriptor_lane_mask(scheduler_dma_descriptor_lane_mask),
      .dma_descriptor_tag(scheduler_dma_descriptor_tag),
      .s_axis_tdata(s_axis_tdata),
      .s_axis_tkeep(s_axis_tkeep),
      .s_axis_tvalid(s_axis_tvalid),
      .s_axis_tready(s_axis_tready),
      .s_axis_tlast(s_axis_tlast),
      .activation_stream_valid(activation_stream_valid),
      .activation_stream_ready(activation_stream_ready),
      .activation_stream_values(activation_stream_values),
      .activation_stream_lane_mask(activation_stream_lane_mask),
      .activation_stream_last(activation_stream_last),
      .result_dma_clear_error(scheduler_result_dma_clear_error),
      .result_dma_descriptor_valid(datapath_result_dma_descriptor_valid),
      .result_dma_descriptor_ready(
          datapath_result_dma_descriptor_ready),
      .result_dma_descriptor_word_count(
          scheduler_result_dma_descriptor_word_count),
      .result_dma_descriptor_byte_count(
          scheduler_result_dma_descriptor_byte_count),
      .result_dma_descriptor_destination(
          scheduler_result_dma_descriptor_destination),
      .result_dma_descriptor_slice(scheduler_result_dma_descriptor_slice),
      .result_dma_descriptor_n_base(scheduler_result_dma_descriptor_n_base),
      .result_dma_descriptor_lane_mask(
          scheduler_result_dma_descriptor_lane_mask),
      .result_dma_descriptor_first_tile_tag(
          scheduler_result_dma_descriptor_first_tile_tag),
      .m_axis_tdata(m_axis_tdata),
      .m_axis_tkeep(m_axis_tkeep),
      .m_axis_tvalid(m_axis_tvalid),
      .m_axis_tready(m_axis_tready),
      .m_axis_tlast(m_axis_tlast),
      .weight_release_valid(scheduler_weight_release_valid),
      .weight_release_ready(scheduler_weight_release_ready),
      .chunk_valid(scheduler_chunk_valid),
      .chunk_ready(scheduler_chunk_ready),
      .chunk_activation_streaming(scheduler_chunk_activation_streaming),
      .chunk_activation_tensor_tag(scheduler_chunk_activation_tensor_tag),
      .chunk_input_h(scheduler_chunk_input_h),
      .chunk_input_w(scheduler_chunk_input_w),
      .chunk_channel_count(scheduler_chunk_channel_count),
      .chunk_input_lane_mask(scheduler_chunk_input_lane_mask),
      .chunk_kernel(scheduler_chunk_kernel),
      .chunk_stride(scheduler_chunk_stride),
      .chunk_padding(scheduler_chunk_padding),
      .chunk_k_count(scheduler_chunk_k_count),
      .chunk_weight_context_tag(scheduler_chunk_weight_context_tag),
      .chunk_word_count(scheduler_chunk_word_count),
      .chunk_output_width(scheduler_chunk_output_width),
      .chunk_accum_context_tag(scheduler_chunk_accum_context_tag),
      .chunk_tile_tag_base(scheduler_chunk_tile_tag_base),
      .chunk_index(scheduler_chunk_index),
      .chunk_first(scheduler_chunk_first),
      .chunk_final(scheduler_chunk_final),
      .configured(configured),
      .chunk_frame_active(chunk_frame_active),
      .chunk_done(chunk_done),
      .chunk_rejected(chunk_rejected),
      .compute_busy(compute_busy),
      .transaction_active(transaction_active),
      .accum_chunk_active(accum_chunk_active),
      .transaction_done(transaction_done),
      .pipeline_idle(datapath_pipeline_idle),
      .protocol_error(datapath_protocol_error),
      .activation_context_error(activation_context_error),
      .accum_context_error(accum_context_error),
      .weight_context_error(weight_context_error),
      .completed_tile_count(completed_tile_count),
      .completed_weight_replays(completed_weight_replays),
      .weight_bank_state(weight_bank_state),
      .weight_resident_valid(weight_resident_valid),
      .resident_weight_k_count(resident_weight_k_count),
      .resident_weight_words_written(resident_weight_words_written),
      .resident_weight_n_lane_mask(resident_weight_n_lane_mask),
      .resident_weight_context_tag(resident_weight_context_tag),
      .weight_replay_done(weight_replay_done),
      .accum_bank_state(accum_bank_state),
      .queued_count(queued_count),
      .activation_ready_tensor_valid(activation_ready_tensor_valid),
      .activation_ready_tensor_bank(activation_ready_tensor_bank),
      .activation_ready_tensor_tag(activation_ready_tensor_tag),
      .activation_ready_count(activation_ready_count),
      .activation_fill_active(activation_fill_active),
      .activation_fill_bank(activation_fill_bank),
      .activation_read_active(activation_read_active),
      .activation_read_bank(activation_read_bank),
      .activation_read_segment(activation_read_segment),
      .activation_read_done(activation_read_done),
      .activation_words_forwarded(activation_words_forwarded),
      .activation_stream_words_forwarded(
          activation_stream_words_forwarded),
      .dma_busy(dma_busy),
      .dma_transfer_active(dma_transfer_active),
      .dma_transfer_done(dma_transfer_done),
      .dma_descriptor_rejected(dma_descriptor_rejected),
      .dma_descriptor_error(dma_descriptor_error),
      .dma_stream_error(dma_stream_error),
      .dma_protocol_error(dma_protocol_error),
      .dma_active_destination(dma_active_destination),
      .dma_words_transferred(dma_words_transferred),
      .dma_completed_transfers(dma_completed_transfers),
      .result_dma_busy(result_dma_busy),
      .result_dma_transfer_active(result_dma_transfer_active),
      .result_dma_transfer_done(result_dma_transfer_done),
      .result_dma_descriptor_rejected(result_dma_descriptor_rejected),
      .result_dma_descriptor_error(result_dma_descriptor_error),
      .result_dma_metadata_error(result_dma_metadata_error),
      .result_dma_protocol_error(result_dma_protocol_error),
      .result_dma_active_destination(result_dma_active_destination),
      .result_dma_active_slice(result_dma_active_slice),
      .result_dma_active_n_base(result_dma_active_n_base),
      .result_dma_active_lane_mask(result_dma_active_lane_mask),
      .result_dma_active_first_tile_tag(result_dma_active_first_tile_tag),
      .result_dma_words_accepted(result_dma_words_accepted),
      .result_dma_words_transferred(result_dma_words_transferred),
      .result_dma_beats_transferred(result_dma_beats_transferred),
      .result_dma_completed_transfers(result_dma_completed_transfers),
      .result_dma_completed_first_tile_tag(
          result_dma_completed_first_tile_tag),
      .result_dma_completed_last_tile_tag(
          result_dma_completed_last_tile_tag)
  );

`ifndef SYNTHESIS
  always_ff @(posedge clk) begin
    if (!rst) begin
      if (command_ready && (!datapath_command_boundary_idle || dma_busy ||
                            result_dma_busy || !configured))
        $fatal(1, "scheduled DMA wrapper exposed command readiness while busy");
      if (command_done && !datapath_command_boundary_idle)
        $fatal(1, "scheduled DMA wrapper completed before command boundary");
      if (!scheduler_busy &&
          (scheduler_dma_descriptor_valid ||
           scheduler_result_dma_descriptor_valid ||
           scheduler_weight_release_valid || scheduler_chunk_valid))
        $fatal(1, "scheduled DMA wrapper drove an unowned child request");
    end
  end
`endif

endmodule
