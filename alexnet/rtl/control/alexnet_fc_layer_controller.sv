`timescale 1ns/1ps

// One layer job, one SA, N8-major / K-chunk-minor FC6/7/8 schedule.
// External services provide channel parameters and packed MM2S data using
// logical coordinates, not DDR addresses. A result service must acknowledge
// each requested N8 output after its own transfer completion. Layer success
// waits for both that acknowledgement and clean FC/AXIS retirement.
// Faults stop new work; owned streams can drain in the unchanged child.
// Reset controller, datapath, and external service ownership together.
module alexnet_fc_layer_controller (
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

    output logic cfg_valid,
    input logic cfg_ready,
    output logic [1:0] cfg_destination,
    output logic [15:0] cfg_n64_tile_base,
    output logic [2:0] cfg_slice_index,
    output logic [7:0] cfg_lane_mask,
    output logic signed [31:0] cfg_bias [0:7],
    output logic signed [17:0] cfg_multiplier [0:7],
    output logic [5:0] cfg_right_shift [0:7],
    output logic [7:0] cfg_relu,
    output logic dma_descriptor_valid,
    input logic dma_descriptor_ready,
    output logic [1:0] dma_descriptor_destination,
    output logic [9:0] dma_descriptor_word_count,
    output logic [15:0] dma_descriptor_byte_count,
    output logic [7:0] dma_descriptor_lane_mask,
    output logic [15:0] dma_descriptor_tag,
    output logic [9:0] dma_descriptor_k_count,
    output logic [2:0] dma_descriptor_m_count,
    output logic weight_release_valid,
    input logic weight_release_ready,
    output logic chunk_valid,
    input logic chunk_ready,
    output logic [9:0] chunk_k_count,
    output logic [2:0] chunk_m_count,
    output logic [7:0] chunk_n_lane_mask,
    output logic [15:0] chunk_activation_tensor_tag,
    output logic [15:0] chunk_weight_context_tag,
    output logic [15:0] chunk_context_tag,
    output logic [15:0] chunk_tile_tag,
    output logic [7:0] chunk_index,
    output logic chunk_first,
    output logic chunk_final,
    input logic core_fault,
    input logic core_pipeline_idle,
    input logic core_chunk_active,
    input logic core_chunk_done,
    input logic core_chunk_rejected,
    input logic core_chunk_failed,
    input logic core_transaction_active,
    input logic core_transaction_done,
    input logic core_dma_busy,
    input logic core_dma_transfer_done,
    input logic core_dma_descriptor_rejected,
    input logic core_dma_transfer_failed,
    input logic [1:0] core_weight_bank_state,
    input logic [1:0] core_activation_bank_state,

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
    output logic [11:0] completed_output_words
);
  typedef enum logic [4:0] {
    IDLE, CHECK_JOB, PARAMETERS, CHECK_PARAMETERS, CONFIGURE, PREPARE,
    RELEASE_OLD, READ_ACTIVATION, DESC_ACTIVATION, WAIT_ACTIVATION,
    READ_WEIGHT, DESC_WEIGHT, WAIT_WEIGHT, REQUEST_RESULT, SUBMIT_CHUNK,
    WAIT_CHUNK, RELEASE_CHUNK, WAIT_RESULT, NEXT_K, NEXT_N, COMPLETE, FAILED
  } state_t;
  state_t state_q;
  logic [3:0] layer_q;
  logic [2:0] m_q;
  logic [15:0] tag_q;
  logic [13:0] total_k_q, k_offset_q;
  logic [12:0] total_n_q, n_base_q;
  logic [7:0] index_q;
  logic parameters_ok_q;
  logic chunk_done_seen_q, transaction_done_seen_q;
  logic result_owned_q, result_ack_seen_q;
  logic [13:0] remaining_k;
  logic [9:0] k_count, activation_words;
  logic [10:0] k_blocks;
  logic [15:0] tile_tag, transfer_tag;
  logic is_final, is_weight, parameter_fields_ok;
  logic downstream_failure, result_ack_bad, stop_new_work;

  assign active_layer_id = layer_q;
  assign active_m_count = m_q;
  assign active_job_tag = tag_q;
  assign active_n_base = {3'b000, n_base_q};
  assign active_k_offset = k_offset_q;
  assign active_k_count = k_count;
  assign remaining_k = total_k_q - k_offset_q;
  assign k_count = remaining_k > 968 ? 10'd968 : remaining_k[9:0];
  assign is_final = remaining_k <= 968;
  assign k_blocks = ({1'b0, k_count} + 11'd7) >> 3;
  always_comb begin
    case (m_q)
      1: activation_words = 10'(k_blocks);
      2: activation_words = 10'(k_blocks) << 1;
      3: activation_words = (10'(k_blocks) << 1) + 10'(k_blocks);
      4: activation_words = 10'(k_blocks) << 2;
      default: activation_words = 0;
    endcase
  end
  // Tags wrap modulo 16 bits; external job_tag identifies the service epoch.
  assign tile_tag = tag_q + {6'b0, n_base_q[12:3]};
  assign transfer_tag = tag_q + {2'b0, completed_chunks};
  assign busy = state_q != IDLE;
  assign phase = state_q;
  assign downstream_failure = core_fault || core_dma_descriptor_rejected ||
      core_dma_transfer_failed || core_chunk_rejected || core_chunk_failed;
  assign result_ack_bad = result_complete_valid && result_complete_ready &&
      (result_complete_error || result_complete_n_base != active_n_base ||
       result_complete_tag != tile_tag);
  assign stop_new_work = state_q == FAILED || downstream_failure ||
                         service_error || result_ack_bad;
  assign fault = stop_new_work;
  assign job_ready = state_q == IDLE && !stop_new_work && core_pipeline_idle &&
      !core_transaction_active && core_activation_bank_state == 0 &&
      (core_weight_bank_state == 0 || core_weight_bank_state == 2);

  // Request metadata is shared via active_* and stable until this N8 tile
  // and all its owned transfers retire. A parameter response completes the
  // parameter request; no second request/response queue exists.
  assign parameter_request_valid = state_q == PARAMETERS && !stop_new_work;
  assign parameter_ready = parameter_request_valid;
  always_comb begin
    parameter_fields_ok = parameter_layer_id == layer_q &&
        parameter_job_tag == tag_q && parameter_n_base == active_n_base;
    for (int n = 0; n < 8; n++)
      if (parameter_multiplier[n] < 18'sd65540 ||
          parameter_multiplier[n] > 18'sd131067 ||
          parameter_right_shift[n] < 23 || parameter_right_shift[n] > 32)
        parameter_fields_ok = 0;
  end

  assign cfg_valid = state_q == CONFIGURE && !stop_new_work;
  assign cfg_destination = layer_q == 8 ? 2'd2 : 2'd0;
  assign cfg_n64_tile_base = {3'b0, n_base_q[12:6], 6'b0};
  assign cfg_slice_index = n_base_q[5:3];
  assign cfg_lane_mask = 8'hff; // 4096 and 1000 are both multiples of eight.
  assign cfg_relu = layer_q == 8 ? 8'h00 : 8'hff;

  assign is_weight = state_q == READ_WEIGHT || state_q == DESC_WEIGHT ||
                     state_q == WAIT_WEIGHT;
  assign read_request_valid = !stop_new_work &&
      (state_q == READ_ACTIVATION || state_q == READ_WEIGHT);
  assign read_request_destination = is_weight ? 2'd2 : 2'd0;
  assign read_request_word_count = is_weight ? k_count : activation_words;
  assign read_request_byte_count = {6'b0, read_request_word_count} << 3;
  assign read_request_m_count = is_weight ? 3'd0 : m_q;
  assign read_request_tag = transfer_tag;
  assign dma_descriptor_valid = !stop_new_work &&
      (state_q == DESC_ACTIVATION || state_q == DESC_WEIGHT);
  assign dma_descriptor_destination = read_request_destination;
  assign dma_descriptor_word_count = read_request_word_count;
  assign dma_descriptor_byte_count = read_request_byte_count;
  assign dma_descriptor_lane_mask = 8'hff;
  assign dma_descriptor_tag = transfer_tag;
  assign dma_descriptor_k_count = k_count;
  assign dma_descriptor_m_count = read_request_m_count;
  assign weight_release_valid = !stop_new_work &&
      (state_q == RELEASE_OLD || state_q == RELEASE_CHUNK);

  assign result_request_valid = state_q == REQUEST_RESULT && !stop_new_work;
  assign result_request_destination = cfg_destination;
  assign result_request_byte_count = {13'b0, m_q} << 3;
  assign result_request_tag = tile_tag;
  // Keep accepting the one outstanding completion even after a fault, but
  // never turn it into layer success or start the next tile.
  assign result_complete_ready = result_owned_q && !result_ack_seen_q;
  assign chunk_valid = state_q == SUBMIT_CHUNK && !stop_new_work;
  assign chunk_k_count = k_count;
  assign chunk_m_count = m_q;
  assign chunk_n_lane_mask = 8'hff;
  assign chunk_activation_tensor_tag = transfer_tag;
  assign chunk_weight_context_tag = transfer_tag;
  assign chunk_context_tag = tile_tag;
  assign chunk_tile_tag = tile_tag;
  assign chunk_index = index_q;
  assign chunk_first = index_q == 0;
  assign chunk_final = is_final;

  always_ff @(posedge clk) begin
    if (rst) begin
      state_q <= IDLE;
      layer_q <= 0;
      m_q <= 0;
      tag_q <= 0;
      total_k_q <= 0;
      total_n_q <= 0;
      k_offset_q <= 0;
      n_base_q <= 0;
      index_q <= 0;
      parameters_ok_q <= 0;
      result_owned_q <= 0;
      result_ack_seen_q <= 0;
      chunk_done_seen_q <= 0;
      transaction_done_seen_q <= 0;
      layer_done <= 0;
      job_rejected <= 0;
      layer_failed <= 0;
      fault_code <= 0;
      completed_n_tiles <= 0;
      completed_chunks <= 0;
      completed_k_tokens <= 0;
      completed_output_words <= 0;
      for (int n = 0; n < 8; n++) begin
        cfg_bias[n] <= 0;
        cfg_multiplier[n] <= 0;
        cfg_right_shift[n] <= 0;
      end
    end else begin
      layer_done <= 0;
      job_rejected <= 0;
      layer_failed <= 0;
      if (result_complete_valid && result_complete_ready)
        result_ack_seen_q <= 1;
      if (state_q == WAIT_CHUNK) begin
        if (core_chunk_done) chunk_done_seen_q <= 1;
        if (core_transaction_done) transaction_done_seen_q <= 1;
      end
      case (state_q)
        IDLE: if (job_valid && job_ready) begin
          layer_q <= job_layer_id;
          m_q <= job_m_count;
          tag_q <= job_tag;
          completed_n_tiles <= 0;
          completed_chunks <= 0;
          completed_k_tokens <= 0;
          completed_output_words <= 0;
          k_offset_q <= 0;
          n_base_q <= 0;
          index_q <= 0;
          state_q <= CHECK_JOB;
        end
        CHECK_JOB: begin
          if (m_q == 0 || m_q > 4 || layer_q < 6 || layer_q > 8) begin
            job_rejected <= 1;
            state_q <= IDLE;
          end else begin
            total_k_q <= layer_q == 6 ? 14'd9216 : 14'd4096;
            total_n_q <= layer_q == 8 ? 13'd1000 : 13'd4096;
            state_q <= PARAMETERS;
          end
        end
        PARAMETERS: if (parameter_valid && parameter_ready) begin
          parameters_ok_q <= parameter_fields_ok;
          for (int n = 0; n < 8; n++) begin
            cfg_bias[n] <= parameter_bias[n];
            cfg_multiplier[n] <= parameter_multiplier[n];
            cfg_right_shift[n] <= parameter_right_shift[n];
          end
          state_q <= CHECK_PARAMETERS;
        end
        CHECK_PARAMETERS: begin
          if (parameters_ok_q) state_q <= CONFIGURE;
          else begin
            state_q <= FAILED;
            fault_code <= 1;
            layer_failed <= 1;
          end
        end
        CONFIGURE: if (cfg_valid && cfg_ready) state_q <= PREPARE;
        PREPARE: begin
          if (core_weight_bank_state == 0) state_q <= READ_ACTIVATION;
          else if (core_weight_bank_state == 2) state_q <= RELEASE_OLD;
        end
        RELEASE_OLD: if (weight_release_valid && weight_release_ready)
          state_q <= READ_ACTIVATION;
        READ_ACTIVATION: if (read_request_valid && read_request_ready)
          state_q <= DESC_ACTIVATION;
        DESC_ACTIVATION: if (dma_descriptor_valid && dma_descriptor_ready)
          state_q <= WAIT_ACTIVATION;
        WAIT_ACTIVATION: if (core_dma_transfer_done) state_q <= READ_WEIGHT;
        READ_WEIGHT: if (read_request_valid && read_request_ready)
          state_q <= DESC_WEIGHT;
        DESC_WEIGHT: if (dma_descriptor_valid && dma_descriptor_ready)
          state_q <= WAIT_WEIGHT;
        WAIT_WEIGHT: if (core_dma_transfer_done)
          state_q <= is_final ? REQUEST_RESULT : SUBMIT_CHUNK;
        REQUEST_RESULT: if (result_request_valid && result_request_ready) begin
          result_owned_q <= 1;
          result_ack_seen_q <= 0;
          state_q <= SUBMIT_CHUNK;
        end
        SUBMIT_CHUNK: if (chunk_valid && chunk_ready) begin
          chunk_done_seen_q <= 0;
          transaction_done_seen_q <= 0;
          state_q <= WAIT_CHUNK;
        end
        WAIT_CHUNK: if ((chunk_done_seen_q || core_chunk_done) &&
            !core_chunk_active && !core_dma_busy &&
            (!is_final || ((transaction_done_seen_q || core_transaction_done) &&
                           core_pipeline_idle))) begin
          // A nonfinal chunk must retain its accumulator owner.
          if (!is_final && !core_transaction_active) begin
            fault_code <= 5;
            layer_failed <= 1;
            state_q <= FAILED;
          end else begin
            completed_chunks <= completed_chunks + 1'b1;
            completed_k_tokens <= completed_k_tokens + {14'b0, k_count};
            state_q <= RELEASE_CHUNK;
          end
        end
        RELEASE_CHUNK: if (weight_release_valid && weight_release_ready)
          state_q <= is_final ? WAIT_RESULT : NEXT_K;
        WAIT_RESULT: if (result_ack_seen_q && core_pipeline_idle &&
            !core_transaction_active && core_weight_bank_state == 0 &&
            core_activation_bank_state == 0) begin
          result_owned_q <= 0;
          result_ack_seen_q <= 0;
          completed_n_tiles <= completed_n_tiles + 1'b1;
          completed_output_words <= completed_output_words + {9'b0, m_q};
          state_q <= n_base_q + 13'd8 == total_n_q ? COMPLETE : NEXT_N;
        end
        NEXT_K: begin
          k_offset_q <= k_offset_q + {4'b0, k_count};
          index_q <= index_q + 1'b1;
          state_q <= READ_ACTIVATION;
        end
        NEXT_N: begin
          n_base_q <= n_base_q + 13'd8;
          k_offset_q <= 0;
          index_q <= 0;
          state_q <= PARAMETERS;
        end
        COMPLETE: begin
          layer_done <= 1;
          state_q <= IDLE;
        end
        FAILED: state_q <= FAILED;
        default: state_q <= FAILED;
      endcase

      // First fault wins. Stop new requests immediately, but do not reset or
      // withdraw a data stream already owned by the child/external service.
      if (state_q != FAILED &&
          (downstream_failure || service_error || result_ack_bad)) begin
        state_q <= FAILED;
        layer_done <= 0;
        layer_failed <= state_q != IDLE;
        if (downstream_failure) fault_code <= 3;
        else if (service_error) fault_code <= 2;
        else fault_code <= 4;
      end
    end
  end
endmodule
