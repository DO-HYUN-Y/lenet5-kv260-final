`timescale 1ns/1ps

// Activation-buffered conv datapath. A completed dual-segment activation set
// and one resident weight tile are launched atomically into the unchanged RS
// feeder/compute/dual-accumulator path. The wrapper mirrors activation fill
// metadata so a tensor cannot be consumed by a mismatched frame descriptor.
module alexnet_m4n8_rs_activation_resident_weight_dual_accum_datapath #(
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
    parameter int WEIGHT_COUNT_W = $clog2(WEIGHT_DEPTH + 1),
    parameter int ACTIVATION_ADDR_W = $clog2(2 * SEGMENT_DEPTH),
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

    input  logic activation_fill_valid,
    output logic activation_fill_ready,
    input  logic activation_fill_is_pooled,
    input  logic [ACTIVATION_COUNT_W-1:0] activation_fill_word_count,
    input  logic [7:0] activation_fill_lane_mask,
    input  logic [TENSOR_TAG_W-1:0] activation_fill_tensor_tag,
    input  logic activation_direct_valid,
    output logic activation_direct_ready,
    input  logic [63:0] activation_direct_values,
    input  logic [7:0] activation_direct_lane_mask,
    input  logic activation_direct_last,
    input  logic activation_pooled_valid,
    output logic activation_pooled_ready,
    input  logic [63:0] activation_pooled_values,
    input  logic [7:0] activation_pooled_lane_mask,
    input  logic activation_pooled_last,

    // Conv1 bypass: 224x224 input is consumed directly by the row-stationary
    // feeder and therefore does not allocate a 50,176-word activation bank.
    input  logic activation_stream_valid,
    output logic activation_stream_ready,
    input  logic [63:0] activation_stream_values,
    input  logic [7:0] activation_stream_lane_mask,
    input  logic activation_stream_last,

    input  logic weight_fill_valid,
    output logic weight_fill_ready,
    input  logic [WEIGHT_COUNT_W-1:0] weight_fill_k_count,
    input  logic [7:0] weight_fill_n_lane_mask,
    input  logic [WEIGHT_CONTEXT_TAG_W-1:0] weight_fill_context_tag,
    input  logic weight_write_valid,
    output logic weight_write_ready,
    input  logic [63:0] weight_write_values,
    input  logic [7:0] weight_write_n_lane_mask,
    input  logic weight_write_last,
    input  logic weight_release_valid,
    output logic weight_release_ready,

    input  logic chunk_valid,
    output logic chunk_ready,
    input  logic chunk_activation_streaming,
    input  logic [TENSOR_TAG_W-1:0] chunk_activation_tensor_tag,
    input  logic [DIM_W-1:0] chunk_input_h,
    input  logic [DIM_W-1:0] chunk_input_w,
    input  logic [3:0] chunk_channel_count,
    input  logic [7:0] chunk_input_lane_mask,
    input  logic [3:0] chunk_kernel,
    input  logic [2:0] chunk_stride,
    input  logic [2:0] chunk_padding,
    input  logic [WEIGHT_COUNT_W-1:0] chunk_k_count,
    input  logic [WEIGHT_CONTEXT_TAG_W-1:0]
        chunk_weight_context_tag,
    input  logic [BANK_COUNT_W-1:0] chunk_word_count,
    input  logic [DIM_W-1:0] chunk_output_width,
    input  logic [ACCUM_CONTEXT_TAG_W-1:0] chunk_accum_context_tag,
    input  logic [TILE_TAG_W-1:0] chunk_tile_tag_base,
    input  logic [CHUNK_INDEX_W-1:0] chunk_index,
    input  logic chunk_first,
    input  logic chunk_final,

    output logic egress_valid,
    input  logic egress_ready,
    output logic [63:0] egress_values,
    output logic [7:0] egress_lane_mask,
    output logic [1:0] egress_destination,
    output logic [2:0] egress_slice,
    output logic [4:0] egress_m,
    output logic [N_BASE_W-1:0] egress_n_base,
    output logic [TILE_TAG_W-1:0] egress_tile_tag,

    output logic configured,
    output logic chunk_frame_active,
    output logic chunk_done,
    output logic chunk_rejected,
    output logic compute_busy,
    output logic transaction_active,
    output logic accum_chunk_active,
    output logic transaction_done,
    output logic pipeline_idle,
    output logic protocol_error,
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

  logic activation_read_start_valid;
  logic activation_read_start_ready;
  logic [63:0] activation_read_values;
  logic [7:0] activation_read_lane_mask;
  logic [ACTIVATION_ADDR_W-1:0] activation_read_index;
  logic activation_read_last;
  logic [TENSOR_TAG_W-1:0] activation_read_tensor_tag;
  logic activation_read_valid;
  logic activation_read_ready;
  logic core_source_valid;
  logic [63:0] core_source_values;
  logic [7:0] core_source_lane_mask;
  logic core_source_last;
  logic core_source_ready;
  logic [1:0] activation_segment0_bank0_state;
  logic [1:0] activation_segment0_bank1_state;
  logic [1:0] activation_segment1_bank0_state;
  logic [1:0] activation_segment1_bank1_state;
  logic activation_storage_context_error;
  logic activation_storage_protocol_error;
  logic activation_storage_idle;

  logic core_chunk_valid;
  logic core_chunk_ready;
  logic core_chunk_frame_active;
  logic core_chunk_done;
  logic core_pipeline_idle;
  logic core_protocol_error;
  logic core_weight_context_error;
  logic core_cfg_valid;
  logic core_cfg_ready;
  logic core_weight_fill_valid;
  logic core_weight_fill_ready;
  logic core_weight_release_valid;
  logic core_weight_release_ready;

  logic fill_descriptor_fire;
  logic fill_complete_fire;
  logic request_fire;
  logic request_reject;
  logic launch_fire;
  logic activation_word_fire;
  logic source_done_event;
  logic chunk_streaming_requested;
  logic metadata_push;
  logic metadata_pop;

  logic [ACTIVATION_COUNT_W-1:0] fill_word_count_q;
  logic [7:0] fill_lane_mask_q;
  logic [TENSOR_TAG_W-1:0] fill_tensor_tag_q;

  logic [1:0] metadata_count_q;
  logic [ACTIVATION_COUNT_W-1:0] metadata_word_count0_q;
  logic [ACTIVATION_COUNT_W-1:0] metadata_word_count1_q;
  logic [7:0] metadata_lane_mask0_q;
  logic [7:0] metadata_lane_mask1_q;
  logic [TENSOR_TAG_W-1:0] metadata_tensor_tag0_q;
  logic [TENSOR_TAG_W-1:0] metadata_tensor_tag1_q;
  logic metadata_bank0_q;
  logic metadata_bank1_q;

  logic metadata_queue_aligned;
  logic request_metadata_tag_match;
  logic request_metadata_shape_match;
  logic request_weight_available;
  logic request_weight_context_match;
  logic request_validation_pass;
  logic request_launch_eligible;
  logic [2*DIM_W-1:0] request_input_word_count;

  logic request_pending_q;
  logic request_validation_done_q;
  logic request_streaming_q;
  logic [TENSOR_TAG_W-1:0] request_activation_tensor_tag_q;
  logic [DIM_W-1:0] request_input_h_q;
  logic [DIM_W-1:0] request_input_w_q;
  logic [3:0] request_channel_count_q;
  logic [7:0] request_input_lane_mask_q;
  logic [3:0] request_kernel_q;
  logic [2:0] request_stride_q;
  logic [2:0] request_padding_q;
  logic [WEIGHT_COUNT_W-1:0] request_k_count_q;
  logic [WEIGHT_CONTEXT_TAG_W-1:0] request_weight_context_tag_q;
  logic [BANK_COUNT_W-1:0] request_word_count_q;
  logic [DIM_W-1:0] request_output_width_q;
  logic [ACCUM_CONTEXT_TAG_W-1:0] request_accum_context_tag_q;
  logic [TILE_TAG_W-1:0] request_tile_tag_base_q;
  logic [CHUNK_INDEX_W-1:0] request_chunk_index_q;
  logic request_first_q;
  logic request_final_q;
  logic [7:0] configured_n_lane_mask_q;

  logic chunk_active_q;
  logic active_streaming_q;
  logic activation_done_seen_q;
  logic core_done_seen_q;
  logic local_protocol_error_q;
  logic local_context_error_q;
  logic local_weight_context_error_q;
  logic [15:0] active_word_count_q;
  logic [7:0] active_lane_mask_q;
  logic [TENSOR_TAG_W-1:0] active_tensor_tag_q;
  logic [15:0] activation_words_forwarded_q;

  assign fill_descriptor_fire = activation_fill_valid &&
                                activation_fill_ready;
  assign chunk_streaming_requested = chunk_activation_streaming === 1'b1;
  assign fill_complete_fire =
      (activation_direct_valid && activation_direct_ready &&
       activation_direct_last) ||
      (activation_pooled_valid && activation_pooled_ready &&
       activation_pooled_last);
  assign metadata_push = fill_complete_fire;
  assign metadata_pop = launch_fire && !request_streaming_q;

  assign metadata_queue_aligned = metadata_count_q != 0 &&
                                  activation_ready_tensor_valid &&
                                  activation_ready_count == metadata_count_q &&
                                  activation_ready_tensor_bank ==
                                      metadata_bank0_q &&
                                  activation_ready_tensor_tag ==
                                      metadata_tensor_tag0_q;
  assign request_input_word_count = request_input_h_q * request_input_w_q;
  assign request_metadata_tag_match = request_activation_tensor_tag_q ==
                                      metadata_tensor_tag0_q;
  assign request_metadata_shape_match =
      request_input_word_count == metadata_word_count0_q &&
      request_input_lane_mask_q == metadata_lane_mask0_q;
  assign request_weight_available = weight_bank_state == 2'd2 &&
                                    weight_resident_valid;
  assign request_weight_context_match =
      resident_weight_k_count == request_k_count_q &&
      resident_weight_n_lane_mask == configured_n_lane_mask_q &&
      resident_weight_context_tag == request_weight_context_tag_q;
  assign request_validation_pass = request_weight_available &&
                                   request_weight_context_match &&
      (request_streaming_q ?
          (metadata_count_q == 0 && activation_storage_idle &&
           request_input_word_count != 0) :
          (metadata_queue_aligned && request_metadata_tag_match &&
           request_metadata_shape_match));
  assign request_launch_eligible = request_pending_q &&
                                   request_validation_done_q;
  assign request_reject = request_pending_q &&
                          !request_validation_done_q &&
                          !request_validation_pass;

  // Cross-gating makes the activation read and compute chunk handshakes
  // indivisible. The external request is registered first, so no descriptor
  // input lies on the feeder's frame-start control path.
  assign core_chunk_valid = request_launch_eligible &&
      (request_streaming_q || activation_read_start_ready);
  assign activation_read_start_valid = request_launch_eligible &&
                                       !request_streaming_q &&
                                       core_chunk_ready;
  assign chunk_ready = configured && !request_pending_q && !chunk_active_q &&
                       (chunk_streaming_requested ?
                            (metadata_count_q == 0 && activation_storage_idle) :
                            metadata_queue_aligned) &&
                       request_weight_available &&
                       !cfg_valid;
  assign request_fire = chunk_valid && chunk_ready;
  assign launch_fire = core_chunk_valid && core_chunk_ready;

  assign core_cfg_valid = cfg_valid && !request_pending_q && !chunk_active_q;
  assign cfg_ready = core_cfg_ready && !request_pending_q && !chunk_active_q &&
                     !chunk_valid;

  assign core_weight_fill_valid = weight_fill_valid && !request_pending_q &&
                                  !chunk_active_q && !chunk_valid;
  assign weight_fill_ready = core_weight_fill_ready && !request_pending_q &&
                             !chunk_active_q && !chunk_valid;
  assign core_weight_release_valid = weight_release_valid &&
                                     !request_pending_q && !chunk_active_q &&
                                     !chunk_valid;
  assign weight_release_ready = core_weight_release_ready &&
                                !request_pending_q && !chunk_active_q &&
                                !chunk_valid;

  assign activation_read_ready = core_chunk_frame_active &&
                                 !active_streaming_q &&
                                 activation_read_active &&
                                 core_source_ready;
  assign activation_stream_ready = core_chunk_frame_active &&
                                   active_streaming_q && core_source_ready;
  assign core_source_valid = active_streaming_q ? activation_stream_valid :
                                                  activation_read_valid;
  assign core_source_values = active_streaming_q ? activation_stream_values :
                                                   activation_read_values;
  assign core_source_lane_mask = active_streaming_q ?
      activation_stream_lane_mask : activation_read_lane_mask;
  assign core_source_last = active_streaming_q ? activation_stream_last :
                                                activation_read_last;
  assign activation_word_fire = core_source_valid && core_source_ready;
  assign source_done_event = active_streaming_q ?
      (activation_word_fire && activation_stream_last) : activation_read_done;

  assign chunk_frame_active = chunk_active_q;
  assign activation_words_forwarded =
      ACTIVATION_COUNT_W'(activation_words_forwarded_q);
  assign activation_stream_words_forwarded =
      active_streaming_q ? activation_words_forwarded_q : 16'd0;
  assign pipeline_idle = activation_storage_idle && core_pipeline_idle &&
                         !request_pending_q && !chunk_active_q &&
                         metadata_count_q == 0;
  assign protocol_error = activation_storage_protocol_error ||
                          core_protocol_error || local_protocol_error_q;
  assign activation_context_error = activation_storage_context_error ||
                                    local_context_error_q;
  assign weight_context_error = core_weight_context_error ||
                                local_weight_context_error_q;

  always_ff @(posedge clk) begin
    if (rst) begin
      fill_word_count_q <= '0;
      fill_lane_mask_q <= '0;
      fill_tensor_tag_q <= '0;
      metadata_count_q <= '0;
      metadata_word_count0_q <= '0;
      metadata_word_count1_q <= '0;
      metadata_lane_mask0_q <= '0;
      metadata_lane_mask1_q <= '0;
      metadata_tensor_tag0_q <= '0;
      metadata_tensor_tag1_q <= '0;
      metadata_bank0_q <= 1'b0;
      metadata_bank1_q <= 1'b0;
      request_pending_q <= 1'b0;
      request_validation_done_q <= 1'b0;
      request_streaming_q <= 1'b0;
      request_activation_tensor_tag_q <= '0;
      request_input_h_q <= '0;
      request_input_w_q <= '0;
      request_channel_count_q <= '0;
      request_input_lane_mask_q <= '0;
      request_kernel_q <= '0;
      request_stride_q <= '0;
      request_padding_q <= '0;
      request_k_count_q <= '0;
      request_weight_context_tag_q <= '0;
      request_word_count_q <= '0;
      request_output_width_q <= '0;
      request_accum_context_tag_q <= '0;
      request_tile_tag_base_q <= '0;
      request_chunk_index_q <= '0;
      request_first_q <= 1'b0;
      request_final_q <= 1'b0;
      configured_n_lane_mask_q <= '0;
      chunk_active_q <= 1'b0;
      active_streaming_q <= 1'b0;
      chunk_done <= 1'b0;
      chunk_rejected <= 1'b0;
      activation_done_seen_q <= 1'b0;
      core_done_seen_q <= 1'b0;
      local_protocol_error_q <= 1'b0;
      local_context_error_q <= 1'b0;
      local_weight_context_error_q <= 1'b0;
      active_word_count_q <= '0;
      active_lane_mask_q <= '0;
      active_tensor_tag_q <= '0;
      activation_words_forwarded_q <= '0;
    end else begin
      chunk_done <= 1'b0;
      chunk_rejected <= 1'b0;

      if (core_cfg_valid && core_cfg_ready)
        configured_n_lane_mask_q <= cfg_lane_mask;

      if (fill_descriptor_fire) begin
        fill_word_count_q <= activation_fill_word_count;
        fill_lane_mask_q <= activation_fill_lane_mask;
        fill_tensor_tag_q <= activation_fill_tensor_tag;
      end

      case ({metadata_push, metadata_pop})
        2'b10: begin
          if (metadata_count_q == 0) begin
            metadata_word_count0_q <= fill_word_count_q;
            metadata_lane_mask0_q <= fill_lane_mask_q;
            metadata_tensor_tag0_q <= fill_tensor_tag_q;
            metadata_bank0_q <= activation_fill_bank;
          end else begin
            metadata_word_count1_q <= fill_word_count_q;
            metadata_lane_mask1_q <= fill_lane_mask_q;
            metadata_tensor_tag1_q <= fill_tensor_tag_q;
            metadata_bank1_q <= activation_fill_bank;
          end
          metadata_count_q <= metadata_count_q + 1'b1;
        end
        2'b01: begin
          metadata_word_count0_q <= metadata_word_count1_q;
          metadata_lane_mask0_q <= metadata_lane_mask1_q;
          metadata_tensor_tag0_q <= metadata_tensor_tag1_q;
          metadata_bank0_q <= metadata_bank1_q;
          metadata_word_count1_q <= '0;
          metadata_lane_mask1_q <= '0;
          metadata_tensor_tag1_q <= '0;
          metadata_bank1_q <= 1'b0;
          metadata_count_q <= metadata_count_q - 1'b1;
        end
        2'b11: begin
          metadata_word_count0_q <= fill_word_count_q;
          metadata_lane_mask0_q <= fill_lane_mask_q;
          metadata_tensor_tag0_q <= fill_tensor_tag_q;
          metadata_bank0_q <= activation_fill_bank;
          metadata_word_count1_q <= '0;
          metadata_lane_mask1_q <= '0;
          metadata_tensor_tag1_q <= '0;
          metadata_bank1_q <= 1'b0;
        end
        default: metadata_count_q <= metadata_count_q;
      endcase

      if (request_fire) begin
        request_pending_q <= 1'b1;
        request_validation_done_q <= 1'b0;
        request_streaming_q <= chunk_streaming_requested;
        request_activation_tensor_tag_q <= chunk_activation_tensor_tag;
        request_input_h_q <= chunk_input_h;
        request_input_w_q <= chunk_input_w;
        request_channel_count_q <= chunk_channel_count;
        request_input_lane_mask_q <= chunk_input_lane_mask;
        request_kernel_q <= chunk_kernel;
        request_stride_q <= chunk_stride;
        request_padding_q <= chunk_padding;
        request_k_count_q <= chunk_k_count;
        request_weight_context_tag_q <= chunk_weight_context_tag;
        request_word_count_q <= chunk_word_count;
        request_output_width_q <= chunk_output_width;
        request_accum_context_tag_q <= chunk_accum_context_tag;
        request_tile_tag_base_q <= chunk_tile_tag_base;
        request_chunk_index_q <= chunk_index;
        request_first_q <= chunk_first;
        request_final_q <= chunk_final;
      end

      if (request_pending_q && !request_validation_done_q &&
          request_validation_pass)
        request_validation_done_q <= 1'b1;

      if (request_reject) begin
        request_pending_q <= 1'b0;
        request_validation_done_q <= 1'b0;
        chunk_rejected <= 1'b1;
        if (!request_streaming_q && !request_metadata_tag_match)
          local_context_error_q <= 1'b1;
        else if (!request_streaming_q && !request_metadata_shape_match)
          local_protocol_error_q <= 1'b1;
        else if (request_weight_available &&
                 !request_weight_context_match)
          local_weight_context_error_q <= 1'b1;
      end

      if (launch_fire) begin
        request_pending_q <= 1'b0;
        request_validation_done_q <= 1'b0;
        chunk_active_q <= 1'b1;
        active_streaming_q <= request_streaming_q;
        activation_done_seen_q <= 1'b0;
        core_done_seen_q <= 1'b0;
        active_word_count_q <= request_streaming_q ?
            16'(request_input_word_count) : 16'(metadata_word_count0_q);
        active_lane_mask_q <= request_streaming_q ?
            request_input_lane_mask_q : metadata_lane_mask0_q;
        active_tensor_tag_q <= request_streaming_q ?
            request_activation_tensor_tag_q : metadata_tensor_tag0_q;
        activation_words_forwarded_q <= '0;
      end

      if (activation_word_fire)
        activation_words_forwarded_q <=
            activation_words_forwarded_q + 1'b1;
      if (source_done_event)
        activation_done_seen_q <= 1'b1;
      if (core_chunk_done)
        core_done_seen_q <= 1'b1;

      if (chunk_active_q &&
          (activation_done_seen_q || source_done_event) &&
          (core_done_seen_q || core_chunk_done)) begin
        chunk_active_q <= 1'b0;
        active_streaming_q <= 1'b0;
        chunk_done <= 1'b1;
        activation_done_seen_q <= 1'b0;
        core_done_seen_q <= 1'b0;
      end

      if (activation_word_fire &&
          ((!active_streaming_q &&
            (16'(activation_read_index) != activation_words_forwarded_q ||
             activation_read_tensor_tag != active_tensor_tag_q)) ||
           core_source_lane_mask != active_lane_mask_q ||
           core_source_last !=
               (activation_words_forwarded_q + 1'b1 == active_word_count_q)))
        local_protocol_error_q <= 1'b1;
    end
  end

  alexnet_n8_activation_dual_segment_pingpong #(
      .SEGMENT_DEPTH(SEGMENT_DEPTH),
      .TENSOR_TAG_W(TENSOR_TAG_W),
      .GLOBAL_ADDR_W(ACTIVATION_ADDR_W),
      .TOTAL_COUNT_W(ACTIVATION_COUNT_W)
  ) u_activation (
      .clk(clk),
      .rst(rst),
      .fill_valid(activation_fill_valid),
      .fill_ready(activation_fill_ready),
      .fill_is_pooled(activation_fill_is_pooled),
      .fill_word_count(activation_fill_word_count),
      .fill_lane_mask(activation_fill_lane_mask),
      .fill_tensor_tag(activation_fill_tensor_tag),
      .direct_valid(activation_direct_valid),
      .direct_ready(activation_direct_ready),
      .direct_values(activation_direct_values),
      .direct_lane_mask(activation_direct_lane_mask),
      .direct_last(activation_direct_last),
      .pooled_valid(activation_pooled_valid),
      .pooled_ready(activation_pooled_ready),
      .pooled_values(activation_pooled_values),
      .pooled_lane_mask(activation_pooled_lane_mask),
      .pooled_last(activation_pooled_last),
      .read_start_valid(activation_read_start_valid),
      .read_start_ready(activation_read_start_ready),
      .read_start_tensor_tag(request_activation_tensor_tag_q),
      .read_valid(activation_read_valid),
      .read_ready(activation_read_ready),
      .read_values(activation_read_values),
      .read_lane_mask(activation_read_lane_mask),
      .read_index(activation_read_index),
      .read_last(activation_read_last),
      .read_tensor_tag(activation_read_tensor_tag),
      .read_done(activation_read_done),
      .ready_tensor_valid(activation_ready_tensor_valid),
      .ready_tensor_bank(activation_ready_tensor_bank),
      .ready_tensor_tag(activation_ready_tensor_tag),
      .ready_count(activation_ready_count),
      .fill_active(activation_fill_active),
      .fill_bank(activation_fill_bank),
      .active_fill_is_pooled(),
      .read_active(activation_read_active),
      .read_bank(activation_read_bank),
      .read_segment(activation_read_segment),
      .segment0_bank0_state(activation_segment0_bank0_state),
      .segment0_bank1_state(activation_segment0_bank1_state),
      .segment1_bank0_state(activation_segment1_bank0_state),
      .segment1_bank1_state(activation_segment1_bank1_state),
      .context_error(activation_storage_context_error),
      .protocol_error(activation_storage_protocol_error),
      .idle(activation_storage_idle)
  );

  alexnet_m4n8_rs_resident_weight_dual_accum_datapath #(
      .EXTERNAL_COMPUTE(EXTERNAL_COMPUTE),
      .SLICE_INDEX(SLICE_INDEX),
      .FIFO_DEPTH(FIFO_DEPTH),
      .MAX_INPUT_WIDTH(MAX_INPUT_WIDTH),
      .WEIGHT_DEPTH(WEIGHT_DEPTH),
      .SEGMENT_DEPTH(SEGMENT_DEPTH),
      .DIM_W(DIM_W),
      .K_INDEX_W(K_INDEX_W),
      .TILE_TAG_W(TILE_TAG_W),
      .WEIGHT_CONTEXT_TAG_W(WEIGHT_CONTEXT_TAG_W),
      .ACCUM_CONTEXT_TAG_W(ACCUM_CONTEXT_TAG_W),
      .CHUNK_INDEX_W(CHUNK_INDEX_W),
      .N_BASE_W(N_BASE_W),
      .WEIGHT_COUNT_W(WEIGHT_COUNT_W),
      .BANK_COUNT_W(BANK_COUNT_W)
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
      .clk(clk),
      .rst(rst),
      .ce(ce),
      .cfg_valid(core_cfg_valid),
      .cfg_ready(core_cfg_ready),
      .cfg_destination(cfg_destination),
      .cfg_n64_tile_base(cfg_n64_tile_base),
      .cfg_slice_index(cfg_slice_index),
      .cfg_lane_mask(cfg_lane_mask),
      .cfg_bias(cfg_bias),
      .cfg_multiplier(cfg_multiplier),
      .cfg_right_shift(cfg_right_shift),
      .cfg_relu(cfg_relu),
      .weight_fill_valid(core_weight_fill_valid),
      .weight_fill_ready(core_weight_fill_ready),
      .weight_fill_k_count(weight_fill_k_count),
      .weight_fill_n_lane_mask(weight_fill_n_lane_mask),
      .weight_fill_context_tag(weight_fill_context_tag),
      .weight_write_valid(weight_write_valid),
      .weight_write_ready(weight_write_ready),
      .weight_write_values(weight_write_values),
      .weight_write_n_lane_mask(weight_write_n_lane_mask),
      .weight_write_last(weight_write_last),
      .weight_release_valid(core_weight_release_valid),
      .weight_release_ready(core_weight_release_ready),
      .chunk_valid(core_chunk_valid),
      .chunk_ready(core_chunk_ready),
      .chunk_input_h(request_input_h_q),
      .chunk_input_w(request_input_w_q),
      .chunk_channel_count(request_channel_count_q),
      .chunk_input_lane_mask(request_input_lane_mask_q),
      .chunk_kernel(request_kernel_q),
      .chunk_stride(request_stride_q),
      .chunk_padding(request_padding_q),
      .chunk_k_count(request_k_count_q),
      .chunk_weight_context_tag(request_weight_context_tag_q),
      .chunk_word_count(request_word_count_q),
      .chunk_output_width(request_output_width_q),
      .chunk_accum_context_tag(request_accum_context_tag_q),
      .chunk_tile_tag_base(request_tile_tag_base_q),
      .chunk_index(request_chunk_index_q),
      .chunk_first(request_first_q),
      .chunk_final(request_final_q),
      .s_valid(core_source_valid),
      .s_ready(core_source_ready),
      .s_values(core_source_values),
      .s_lane_mask(core_source_lane_mask),
      .egress_valid(egress_valid),
      .egress_ready(egress_ready),
      .egress_values(egress_values),
      .egress_lane_mask(egress_lane_mask),
      .egress_destination(egress_destination),
      .egress_slice(egress_slice),
      .egress_m(egress_m),
      .egress_n_base(egress_n_base),
      .egress_tile_tag(egress_tile_tag),
      .configured(configured),
      .chunk_frame_active(core_chunk_frame_active),
      .chunk_done(core_chunk_done),
      .compute_busy(compute_busy),
      .transaction_active(transaction_active),
      .accum_chunk_active(accum_chunk_active),
      .transaction_done(transaction_done),
      .pipeline_idle(core_pipeline_idle),
      .protocol_error(core_protocol_error),
      .accum_context_error(accum_context_error),
      .weight_context_error(core_weight_context_error),
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
      .queued_count(queued_count)
  );

`ifndef SYNTHESIS
  initial begin
    if (SEGMENT_DEPTH < 2 ||
        (1 << ACTIVATION_ADDR_W) < 2 * SEGMENT_DEPTH ||
        (1 << ACTIVATION_COUNT_W) <= 2 * SEGMENT_DEPTH)
      $fatal(1, "activation-buffered RS parameterization is invalid");
  end

  always_ff @(posedge clk) begin
    if (!rst) begin
      if (metadata_count_q > 2)
        $fatal(1, "activation launch metadata queue overflowed");
      if (activation_ready_count != metadata_count_q)
        $fatal(1, "activation launch metadata count diverged");
      if (metadata_count_q != 0 && !metadata_queue_aligned)
        $fatal(1, "activation launch metadata head diverged");
      if (metadata_push && metadata_count_q == 2)
        $fatal(1, "activation metadata completed into a full queue");
      if (metadata_push && metadata_pop && metadata_count_q != 1)
        $fatal(1, "activation metadata simultaneous queue update invalid");
      if (launch_fire != (core_chunk_valid && core_chunk_ready) ||
          (!request_streaming_q && launch_fire !=
              (activation_read_start_valid && activation_read_start_ready)))
        $fatal(1, "activation and RS launch handshakes diverged");
      if (activation_word_fire && !chunk_active_q)
        $fatal(1, "activation word transferred outside an active chunk");
      if (!active_streaming_q && activation_read_done &&
          activation_words_forwarded_q != active_word_count_q)
        $fatal(1, "activation read completed at the wrong word count");
      if (core_chunk_done &&
          !(activation_done_seen_q || source_done_event))
        $fatal(1, "RS chunk completed before activation source retirement");
      if (chunk_done &&
          activation_words_forwarded_q != active_word_count_q)
        $fatal(1, "activation-buffered chunk retired with missing words");
    end
  end
`endif

endmodule
