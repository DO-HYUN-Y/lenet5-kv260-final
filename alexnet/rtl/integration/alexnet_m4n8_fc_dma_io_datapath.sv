`timescale 1ns/1ps

// Serialized, owner-safe MM2S -> buffered FC -> S2MM integration.
// Software supplies input descriptors and explicit K-chunk commands; final
// result descriptors are derived from validated commands/config automatically.
// Correctable descriptor rejection has no child side effects. Stream faults
// latch until reset; already owned transfers drain their declared word count.
// Raw result_dma_transfer_done includes failed transfers: only transaction_done
// certifies clean completion. This is an AXIS boundary, not an AXI DMA IP/PS top.
module alexnet_m4n8_fc_dma_io_datapath #(
    parameter bit EXTERNAL_COMPUTE = 1'b0,
    parameter int SLICE_INDEX = 0,
    parameter int FIFO_DEPTH = 64,
    parameter int BANK_DEPTH = 512,
    parameter int WEIGHT_DEPTH = 968,
    parameter int ACTIVATION_DEPTH = 512,
    parameter int ACTIVATION_COUNT_W = $clog2(ACTIVATION_DEPTH + 1),
    parameter int TILE_TAG_W = 16,
    parameter int TENSOR_TAG_W = 16,
    parameter int CONTEXT_TAG_W = 16,
    parameter int WEIGHT_CONTEXT_TAG_W = 16,
    parameter int CHUNK_INDEX_W = 8,
    parameter int N_BASE_W = 16,
    parameter int K_COUNT_W = $clog2(WEIGHT_DEPTH + 1),
    parameter int DMA_COUNT_W = (K_COUNT_W > ACTIVATION_COUNT_W ? K_COUNT_W : ACTIVATION_COUNT_W),
    parameter int DMA_BYTE_COUNT_W = 16,
    parameter bit RUNTIME_SLICE_INDEX = 1'b0
) (
    input logic clk,
    input logic rst,
    input logic ce,

    input logic cfg_valid,
    output logic cfg_ready,
    input logic [1:0] cfg_destination,
    input logic [N_BASE_W-1:0] cfg_n64_tile_base,
    input logic [2:0] cfg_slice_index,
    input logic [7:0] cfg_lane_mask,
    input logic signed [31:0] cfg_bias [0:7],
    input logic signed [17:0] cfg_multiplier [0:7],
    input logic [5:0] cfg_right_shift [0:7],
    input logic [7:0] cfg_relu,

    // destination: 0 = padded FC activation, 2 = resident weight.
    // K/M accompany activation descriptors; weight descriptors require M=0.
    input logic dma_descriptor_valid,
    output logic dma_descriptor_ready,
    input logic [1:0] dma_descriptor_destination,
    input logic [DMA_COUNT_W-1:0] dma_descriptor_word_count,
    input logic [DMA_BYTE_COUNT_W-1:0] dma_descriptor_byte_count,
    input logic [7:0] dma_descriptor_lane_mask,
    input logic [TENSOR_TAG_W-1:0] dma_descriptor_tag,
    input logic [K_COUNT_W-1:0] dma_descriptor_k_count,
    input logic [2:0] dma_descriptor_m_count,
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

    output logic dma_busy,
    output logic [1:0] dma_phase,
    output logic dma_transfer_done,
    output logic dma_transfer_failed,
    output logic dma_descriptor_rejected,
    output logic dma_stream_error,
    output logic [DMA_COUNT_W-1:0] dma_words_transferred,
    output logic [15:0] dma_accepted_descriptors,
    output logic [15:0] dma_rejected_descriptors,
    output logic [15:0] dma_completed_transfers,
    output logic [15:0] dma_failed_transfers,
    output logic result_dma_busy,
    output logic result_dma_transfer_done,
    output logic result_dma_protocol_error,
    output logic [2:0] result_dma_words_transferred,
    output logic [15:0] result_dma_completed_transfers,

    input logic weight_release_valid,
    output logic weight_release_ready,

    input logic chunk_valid,
    output logic chunk_ready,
    input logic [K_COUNT_W-1:0] chunk_k_count,
    input logic [2:0] chunk_m_count,
    input logic [7:0] chunk_n_lane_mask,
    input logic [TENSOR_TAG_W-1:0] chunk_activation_tensor_tag,
    input logic [WEIGHT_CONTEXT_TAG_W-1:0] chunk_weight_context_tag,
    input logic [CONTEXT_TAG_W-1:0] chunk_context_tag,
    input logic [TILE_TAG_W-1:0] chunk_tile_tag,
    input logic [CHUNK_INDEX_W-1:0] chunk_index,
    input logic chunk_first,
    input logic chunk_final,

    output logic [1:0] activation_bank_state,
    output logic activation_fill_active,
    output logic activation_read_active,
    output logic [ACTIVATION_COUNT_W-1:0] activation_words_forwarded,

    output logic configured,
    output logic chunk_active,
    output logic chunk_done,
    output logic chunk_rejected,
    output logic chunk_failed,
    output logic transaction_active,
    output logic transaction_done,
    output logic compute_busy,
    output logic pipeline_idle,
    output logic fault,
    output logic [1:0] phase,
    output logic [1:0] weight_bank_state,
    output logic [2:0] accum_bank_state,
    output logic [15:0] completed_replays,
    output logic [15:0] accepted_chunks,
    output logic [15:0] completed_chunks,
    output logic [15:0] rejected_chunks,
    output logic [15:0] failed_chunks,
    output logic [31:0] completed_k_tokens,
    output logic [$clog2(FIFO_DEPTH+1)-1:0] queued_count,

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

  typedef enum logic [1:0] {I_IDLE, I_CHECK, I_SUBMIT, I_RUN} input_state_t;
  typedef enum logic [1:0] {C_IDLE, C_CHECK, C_SUBMIT, C_RUN} chunk_state_t;
  typedef struct packed {
    logic [1:0] destination;
    logic [DMA_COUNT_W-1:0] word_count;
    logic [DMA_BYTE_COUNT_W-1:0] byte_count;
    logic [7:0] lane_mask;
    logic [TENSOR_TAG_W-1:0] tag;
    logic [K_COUNT_W-1:0] k_count;
    logic [2:0] m_count;
  } input_request_t;
  typedef struct packed {
    logic [K_COUNT_W-1:0] k_count;
    logic [2:0] m_count;
    logic [7:0] n_lane_mask;
    logic [TENSOR_TAG_W-1:0] activation_tensor_tag;
    logic [WEIGHT_CONTEXT_TAG_W-1:0] weight_context_tag;
    logic [CONTEXT_TAG_W-1:0] context_tag;
    logic [TILE_TAG_W-1:0] tile_tag;
    logic [CHUNK_INDEX_W-1:0] index;
    logic first;
    logic final_chunk;
  } chunk_request_t;
  input_state_t input_state_q;
  chunk_state_t state_q;
  input_request_t input_q;
  chunk_request_t request_q;
  logic [1:0] cfg_destination_q;
  logic [N_BASE_W-1:0] cfg_n_base_q;
  logic [2:0] cfg_slice_q;
  wire [2:0] selected_slice = RUNTIME_SLICE_INDEX ? cfg_slice_index : 3'(SLICE_INDEX);
  logic input_valid_shape, input_owner_empty, output_cfg_valid;
  logic [K_COUNT_W:0] input_blocks;
  logic [K_COUNT_W+2:0] input_words_wide;
  logic [DMA_BYTE_COUNT_W-1:0] input_expected_bytes;
  logic boundary_idle, fault_q;
  logic input_done_seen_q, fill_done_seen_q;
  logic core_done_seen_q, core_failed_seen_q, result_done_seen_q;
  logic validated_chunk_q, result_armed_q;

  logic core_cfg_ready, core_chunk_ready, core_chunk_active;
  logic core_chunk_done, core_chunk_failed, core_chunk_rejected, core_fault;
  logic core_pipeline_idle, core_weight_release_ready;
  logic core_activation_fill_done, core_activation_fill_failed, core_activation_fill_rejected;
  logic core_egress_valid, core_egress_ready;
  logic [63:0] core_egress_values;
  logic [7:0] core_egress_lane_mask;
  logic [1:0] core_egress_destination;
  logic [2:0] core_egress_slice;
  logic [4:0] core_egress_m;
  logic [N_BASE_W-1:0] core_egress_n_base;
  logic [TILE_TAG_W-1:0] core_egress_tile_tag;

  logic ingress_descriptor_ready, ingress_busy, ingress_done, ingress_error;
  logic ing_activation_fill_valid, ing_activation_fill_ready;
  logic [TENSOR_TAG_W-1:0] ing_activation_tag;
  logic ing_activation_write_valid, ing_activation_write_ready, ing_activation_last;
  logic [63:0] ing_activation_values;
  logic [7:0] ing_activation_write_mask;
  logic ing_weight_fill_valid, ing_weight_fill_ready;
  logic [K_COUNT_W-1:0] ing_weight_k_count;
  logic [7:0] ing_weight_mask;
  logic [WEIGHT_CONTEXT_TAG_W-1:0] ing_weight_tag;
  logic ing_weight_write_valid, ing_weight_write_ready, ing_weight_last;
  logic [63:0] ing_weight_values;
  logic [7:0] ing_weight_write_mask;
  logic result_descriptor_valid, result_descriptor_ready, result_busy;

  assign phase = state_q;
  assign dma_phase = input_state_q;
  assign chunk_active = state_q != C_IDLE;
  assign dma_busy = input_state_q != I_IDLE || ingress_busy;
  assign result_dma_busy = result_busy || result_descriptor_valid;
  assign fault = fault_q || core_fault || ingress_error || result_dma_protocol_error ||
                 core_activation_fill_rejected;
  assign boundary_idle = state_q == C_IDLE && input_state_q == I_IDLE &&
                         !core_chunk_active && !ingress_busy && !result_busy;
  assign pipeline_idle = boundary_idle && core_pipeline_idle;
  assign cfg_ready = boundary_idle && !fault && core_cfg_ready;
  // Input descriptors take priority over a simultaneous compute or release.
  // Config and input capture may coexist; neither consumes the other's owner.
  assign dma_descriptor_ready = boundary_idle && !fault;
  assign chunk_ready = boundary_idle && !fault && !dma_descriptor_valid &&
                       core_chunk_ready && (transaction_active || !cfg_valid);
  assign weight_release_ready = boundary_idle && !fault && !dma_descriptor_valid &&
                                !chunk_valid && core_weight_release_ready;

  assign input_blocks = ({1'b0, input_q.k_count} + (K_COUNT_W+1)'(7)) >> 3;
  always_comb begin
    case (input_q.m_count)
      1: input_words_wide = (K_COUNT_W+3)'(input_blocks);
      2: input_words_wide = (K_COUNT_W+3)'(input_blocks) << 1;
      3: input_words_wide = ((K_COUNT_W+3)'(input_blocks) << 1) + input_blocks;
      4: input_words_wide = (K_COUNT_W+3)'(input_blocks) << 2;
      default: input_words_wide = '0;
    endcase
  end
  assign input_expected_bytes = DMA_BYTE_COUNT_W'(input_q.word_count) << 3;
  assign input_valid_shape = input_q.k_count != 0 && input_q.k_count <= WEIGHT_DEPTH &&
      input_q.byte_count == input_expected_bytes && input_q.word_count != 0 &&
      ((input_q.destination == 0 && input_q.m_count >= 1 && input_q.m_count <= 4 &&
        input_words_wide <= ACTIVATION_DEPTH && input_q.word_count == input_words_wide &&
        input_q.lane_mask == 8'hff) ||
       (input_q.destination == 2 && input_q.m_count == 0 &&
        input_q.word_count == input_q.k_count && input_q.lane_mask != 0 &&
        (input_q.lane_mask & (input_q.lane_mask + 1'b1)) == 0));
  assign input_owner_empty = input_q.destination == 0 ?
      (activation_bank_state == 0 && !activation_fill_active) : weight_bank_state == 0;
  // The auto result descriptor must satisfy the unchanged egress adapter's
  // destination/alignment contract before compute can acquire any owner.
  assign output_cfg_valid = cfg_destination_q <= 2 && cfg_n_base_q[2:0] == 0;
  // Read activity proves all inner activation/weight/N/accumulator validation
  // passed. No result owner is armed for a rejected final descriptor.
  assign result_descriptor_valid = state_q == C_RUN && request_q.final_chunk &&
                                   validated_chunk_q && !result_armed_q;

  always_ff @(posedge clk) begin
    if (rst) begin
      input_state_q <= I_IDLE;
      input_q <= '0;
      input_done_seen_q <= 1'b0;
      fill_done_seen_q <= 1'b0;
      fault_q <= 1'b0;
      dma_transfer_done <= 1'b0;
      dma_transfer_failed <= 1'b0;
      dma_descriptor_rejected <= 1'b0;
      dma_accepted_descriptors <= '0;
      dma_rejected_descriptors <= '0;
      dma_completed_transfers <= '0;
      dma_failed_transfers <= '0;
    end else begin
      fault_q <= fault;
      dma_transfer_done <= 1'b0;
      dma_transfer_failed <= 1'b0;
      dma_descriptor_rejected <= 1'b0;
      case (input_state_q)
        I_IDLE: if (dma_descriptor_valid && dma_descriptor_ready) begin
          input_q.destination <= dma_descriptor_destination;
          input_q.word_count <= dma_descriptor_word_count;
          input_q.byte_count <= dma_descriptor_byte_count;
          input_q.lane_mask <= dma_descriptor_lane_mask;
          input_q.tag <= dma_descriptor_tag;
          input_q.k_count <= dma_descriptor_k_count;
          input_q.m_count <= dma_descriptor_m_count;
          dma_accepted_descriptors <= dma_accepted_descriptors + 1'b1;
          input_done_seen_q <= 1'b0;
          fill_done_seen_q <= 1'b0;
          input_state_q <= I_CHECK;
        end
        I_CHECK: begin
          if (!input_valid_shape || !input_owner_empty) begin
            dma_descriptor_rejected <= 1'b1;
            dma_rejected_descriptors <= dma_rejected_descriptors + 1'b1;
            input_state_q <= I_IDLE;
          end else input_state_q <= I_SUBMIT;
        end
        I_SUBMIT: if (ingress_descriptor_ready && !fault) input_state_q <= I_RUN;
        I_RUN: begin
          if (ingress_done) input_done_seen_q <= 1'b1;
          if (core_activation_fill_done || core_activation_fill_failed) fill_done_seen_q <= 1'b1;
          if ((input_done_seen_q || ingress_done) && !ingress_busy &&
              ((input_q.destination == 2 && weight_bank_state == 2) ||
               (input_q.destination == 0 && (fill_done_seen_q || core_activation_fill_done ||
                                             core_activation_fill_failed)))) begin
            if (fault) begin
              dma_transfer_failed <= 1'b1;
              dma_failed_transfers <= dma_failed_transfers + 1'b1;
            end else begin
              dma_transfer_done <= 1'b1;
              dma_completed_transfers <= dma_completed_transfers + 1'b1;
            end
            input_state_q <= I_IDLE;
          end
        end
        default: input_state_q <= I_IDLE;
      endcase
    end
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      state_q <= C_IDLE;
      request_q <= '0;
      cfg_destination_q <= '0;
      cfg_n_base_q <= '0;
      cfg_slice_q <= 3'(SLICE_INDEX);
      core_done_seen_q <= 1'b0;
      core_failed_seen_q <= 1'b0;
      result_done_seen_q <= 1'b0;
      validated_chunk_q <= 1'b0;
      result_armed_q <= 1'b0;
      chunk_done <= 1'b0;
      chunk_failed <= 1'b0;
      chunk_rejected <= 1'b0;
      transaction_done <= 1'b0;
      accepted_chunks <= '0;
      completed_chunks <= '0;
      rejected_chunks <= '0;
      failed_chunks <= '0;
    end else begin
      chunk_done <= 1'b0;
      chunk_failed <= 1'b0;
      chunk_rejected <= 1'b0;
      transaction_done <= 1'b0;
      if (cfg_valid && cfg_ready) begin
        cfg_destination_q <= cfg_destination;
        // Capture the same accepted placement as the router. Live config
        // changes must not alter a later final-chunk result descriptor.
        cfg_n_base_q <= cfg_n64_tile_base + (N_BASE_W'(selected_slice) << 3);
        cfg_slice_q <= selected_slice;
      end
      case (state_q)
        C_IDLE: if (chunk_valid && chunk_ready) begin
          request_q.k_count <= chunk_k_count;
          request_q.m_count <= chunk_m_count;
          request_q.n_lane_mask <= chunk_n_lane_mask;
          request_q.activation_tensor_tag <= chunk_activation_tensor_tag;
          request_q.weight_context_tag <= chunk_weight_context_tag;
          request_q.context_tag <= chunk_context_tag;
          request_q.tile_tag <= chunk_tile_tag;
          request_q.index <= chunk_index;
          request_q.first <= chunk_first;
          request_q.final_chunk <= chunk_final;
          core_done_seen_q <= 1'b0;
          core_failed_seen_q <= 1'b0;
          result_done_seen_q <= 1'b0;
          validated_chunk_q <= 1'b0;
          result_armed_q <= 1'b0;
          accepted_chunks <= accepted_chunks + 1'b1;
          state_q <= C_CHECK;
        end
        C_CHECK: begin
          if (!output_cfg_valid) begin
            chunk_rejected <= 1'b1;
            rejected_chunks <= rejected_chunks + 1'b1;
            state_q <= C_IDLE;
          end else state_q <= C_SUBMIT;
        end
        C_SUBMIT: if (core_chunk_ready && !fault) state_q <= C_RUN;
        C_RUN: begin
          if (activation_read_active) validated_chunk_q <= 1'b1;
          if (result_descriptor_valid && result_descriptor_ready) result_armed_q <= 1'b1;
          if (result_dma_transfer_done) result_done_seen_q <= 1'b1;
          if (core_chunk_done || core_chunk_failed) core_done_seen_q <= 1'b1;
          if (core_chunk_failed) core_failed_seen_q <= 1'b1;
          if (core_chunk_rejected) begin
            chunk_rejected <= 1'b1;
            rejected_chunks <= rejected_chunks + 1'b1;
            state_q <= C_IDLE;
          end else if ((core_done_seen_q || core_chunk_done || core_chunk_failed) &&
                       !core_chunk_active &&
                       (!request_q.final_chunk ||
                        ((result_done_seen_q || result_dma_transfer_done) &&
                         !result_busy && core_pipeline_idle))) begin
            if (fault || core_failed_seen_q || core_chunk_failed) begin
              chunk_failed <= 1'b1;
              failed_chunks <= failed_chunks + 1'b1;
            end else begin
              chunk_done <= 1'b1;
              transaction_done <= request_q.final_chunk;
              completed_chunks <= completed_chunks + 1'b1;
            end
            state_q <= C_IDLE;
          end
        end
        default: state_q <= C_IDLE;
      endcase
    end
  end

  alexnet_n8_dma_ingress #(
      .COUNT_W(DMA_COUNT_W), .ACTIVATION_COUNT_W(ACTIVATION_COUNT_W),
      .WEIGHT_COUNT_W(K_COUNT_W), .BYTE_COUNT_W(DMA_BYTE_COUNT_W),
      .TAG_W(TENSOR_TAG_W), .ACTIVATION_MAX_WORDS(ACTIVATION_DEPTH),
      .WEIGHT_MAX_WORDS(WEIGHT_DEPTH)
  ) u_ingress (
      .clk(clk), .rst(rst), .clear_error(1'b0),
      .descriptor_valid(input_state_q == I_SUBMIT && !fault),
      .descriptor_ready(ingress_descriptor_ready),
      .descriptor_destination(input_q.destination), .descriptor_word_count(input_q.word_count),
      .descriptor_byte_count(input_q.byte_count), .descriptor_lane_mask(input_q.lane_mask),
      .descriptor_tag(input_q.tag), .s_axis_tdata(s_axis_tdata), .s_axis_tkeep(s_axis_tkeep),
      .s_axis_tvalid(s_axis_tvalid), .s_axis_tready(s_axis_tready), .s_axis_tlast(s_axis_tlast),
      .activation_fill_valid(ing_activation_fill_valid), .activation_fill_ready(ing_activation_fill_ready),
      .activation_fill_is_pooled(), .activation_fill_word_count(), .activation_fill_lane_mask(),
      .activation_fill_tensor_tag(ing_activation_tag),
      .activation_direct_valid(ing_activation_write_valid), .activation_direct_ready(ing_activation_write_ready),
      .activation_direct_values(ing_activation_values), .activation_direct_lane_mask(ing_activation_write_mask),
      .activation_direct_last(ing_activation_last), .activation_pooled_valid(),
      .activation_pooled_ready(1'b0), .activation_pooled_values(), .activation_pooled_lane_mask(),
      .activation_pooled_last(), .weight_fill_valid(ing_weight_fill_valid),
      .weight_fill_ready(ing_weight_fill_ready), .weight_fill_k_count(ing_weight_k_count),
      .weight_fill_n_lane_mask(ing_weight_mask), .weight_fill_context_tag(ing_weight_tag),
      .weight_write_valid(ing_weight_write_valid), .weight_write_ready(ing_weight_write_ready),
      .weight_write_values(ing_weight_values), .weight_write_n_lane_mask(ing_weight_write_mask),
      .weight_write_last(ing_weight_last), .busy(ingress_busy), .transfer_active(),
      .transfer_done(ingress_done), .descriptor_rejected(), .descriptor_error(),
      .stream_error(dma_stream_error), .protocol_error(ingress_error), .active_destination(),
      .words_transferred(dma_words_transferred), .completed_transfers()
  );

  alexnet_m4n8_fc_activation_resident_weight_accum_datapath #(
      .EXTERNAL_COMPUTE(EXTERNAL_COMPUTE),
      .RUNTIME_SLICE_INDEX(RUNTIME_SLICE_INDEX),
      .SLICE_INDEX(SLICE_INDEX), .FIFO_DEPTH(FIFO_DEPTH), .BANK_DEPTH(BANK_DEPTH),
      .WEIGHT_DEPTH(WEIGHT_DEPTH), .ACTIVATION_DEPTH(ACTIVATION_DEPTH),
      .ACTIVATION_COUNT_W(ACTIVATION_COUNT_W), .TILE_TAG_W(TILE_TAG_W),
      .TENSOR_TAG_W(TENSOR_TAG_W), .CONTEXT_TAG_W(CONTEXT_TAG_W),
      .WEIGHT_CONTEXT_TAG_W(WEIGHT_CONTEXT_TAG_W), .CHUNK_INDEX_W(CHUNK_INDEX_W),
      .N_BASE_W(N_BASE_W), .K_COUNT_W(K_COUNT_W)
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
      .cfg_valid(cfg_valid && cfg_ready),
      .cfg_ready(core_cfg_ready),
      .cfg_destination(cfg_destination),
      .cfg_n64_tile_base(cfg_n64_tile_base),
      .cfg_slice_index(cfg_slice_index),
      .cfg_lane_mask(cfg_lane_mask),
      .cfg_bias(cfg_bias),
      .cfg_multiplier(cfg_multiplier),
      .cfg_right_shift(cfg_right_shift),
      .cfg_relu(cfg_relu),
      .weight_fill_valid(ing_weight_fill_valid),
      .weight_fill_ready(ing_weight_fill_ready),
      .weight_fill_k_count(ing_weight_k_count),
      .weight_fill_n_lane_mask(ing_weight_mask),
      .weight_fill_context_tag(ing_weight_tag),
      .weight_write_valid(ing_weight_write_valid),
      .weight_write_ready(ing_weight_write_ready),
      .weight_write_values(ing_weight_values),
      .weight_write_n_lane_mask(ing_weight_write_mask),
      .weight_write_last(ing_weight_last),
      .weight_release_valid(weight_release_valid && weight_release_ready),
      .weight_release_ready(core_weight_release_ready),
      .chunk_valid(state_q == C_SUBMIT && !fault),
      .chunk_ready(core_chunk_ready),
      .chunk_k_count(request_q.k_count),
      .chunk_m_count(request_q.m_count),
      .chunk_n_lane_mask(request_q.n_lane_mask),
      .chunk_activation_tensor_tag(request_q.activation_tensor_tag),
      .chunk_weight_context_tag(request_q.weight_context_tag),
      .chunk_context_tag(request_q.context_tag),
      .chunk_tile_tag(request_q.tile_tag),
      .chunk_index(request_q.index),
      .chunk_first(request_q.first),
      .chunk_final(request_q.final_chunk),
      .activation_fill_valid(ing_activation_fill_valid),
      .activation_fill_ready(ing_activation_fill_ready),
      .activation_fill_k_count(input_q.k_count),
      .activation_fill_m_count(input_q.m_count),
      .activation_fill_tensor_tag(ing_activation_tag),
      .activation_write_valid(ing_activation_write_valid),
      .activation_write_ready(ing_activation_write_ready),
      .activation_write_values(ing_activation_values),
      .activation_write_lane_mask(ing_activation_write_mask),
      .activation_write_last(ing_activation_last),
      .activation_write_tensor_tag(input_q.tag),
      .activation_fill_active(activation_fill_active),
      .activation_fill_done(core_activation_fill_done),
      .activation_fill_rejected(core_activation_fill_rejected),
      .activation_fill_failed(core_activation_fill_failed),
      .activation_read_active(activation_read_active),
      .activation_read_done(),
      .activation_bank_state(activation_bank_state),
      .activation_word_count(),
      .activation_words_forwarded(activation_words_forwarded),
      .accepted_activation_fills(),
      .completed_activation_fills(),
      .rejected_activation_fills(),
      .failed_activation_fills(),
      .egress_valid(core_egress_valid),
      .egress_ready(core_egress_ready),
      .egress_values(core_egress_values),
      .egress_lane_mask(core_egress_lane_mask),
      .egress_destination(core_egress_destination),
      .egress_slice(core_egress_slice),
      .egress_m(core_egress_m),
      .egress_n_base(core_egress_n_base),
      .egress_tile_tag(core_egress_tile_tag),
      .configured(configured),
      .chunk_active(core_chunk_active),
      .chunk_done(core_chunk_done),
      .chunk_rejected(core_chunk_rejected),
      .chunk_failed(core_chunk_failed),
      .transaction_active(transaction_active),
      .transaction_done(),
      .compute_busy(compute_busy),
      .pipeline_idle(core_pipeline_idle),
      .fault(core_fault),
      .phase(),
      .weight_bank_state(weight_bank_state),
      .accum_bank_state(accum_bank_state),
      .completed_replays(completed_replays),
      .accepted_chunks(),
      .completed_chunks(),
      .rejected_chunks(),
      .failed_chunks(),
      .completed_k_tokens(completed_k_tokens),
      .queued_count(queued_count)
  );

  alexnet_n8_dma_result_egress #(
      .COUNT_W(3), .BYTE_COUNT_W(DMA_BYTE_COUNT_W),
      .N_BASE_W(N_BASE_W), .TILE_TAG_W(TILE_TAG_W), .MAX_WORDS(4)
  ) u_egress (
      .clk(clk), .rst(rst), .clear_error(1'b0),
      .descriptor_valid(result_descriptor_valid), .descriptor_ready(result_descriptor_ready),
      .descriptor_word_count(request_q.m_count),
      .descriptor_byte_count(DMA_BYTE_COUNT_W'(request_q.m_count) << 3),
      .descriptor_destination(cfg_destination_q), .descriptor_slice(cfg_slice_q),
      .descriptor_n_base(cfg_n_base_q), .descriptor_lane_mask(request_q.n_lane_mask),
      .descriptor_first_tile_tag(request_q.tile_tag),
      .packet_valid(core_egress_valid), .packet_ready(core_egress_ready),
      .packet_values(core_egress_values), .packet_lane_mask(core_egress_lane_mask),
      .packet_destination(core_egress_destination), .packet_slice(core_egress_slice),
      .packet_m(core_egress_m), .packet_n_base(core_egress_n_base), .packet_tile_tag(core_egress_tile_tag),
      .m_axis_tdata(m_axis_tdata), .m_axis_tkeep(m_axis_tkeep), .m_axis_tvalid(m_axis_tvalid),
      .m_axis_tready(m_axis_tready), .m_axis_tlast(m_axis_tlast),
      .busy(result_busy), .transfer_active(), .transfer_done(result_dma_transfer_done),
      .descriptor_rejected(), .descriptor_error(), .metadata_error(),
      .protocol_error(result_dma_protocol_error), .active_destination(), .active_slice(),
      .active_n_base(), .active_lane_mask(), .active_first_tile_tag(),
      .words_accepted(), .words_transferred(result_dma_words_transferred), .beats_transferred(),
      .completed_transfers(result_dma_completed_transfers),
      .completed_first_tile_tag(), .completed_last_tile_tag()
  );

`ifndef SYNTHESIS
  initial begin
    if (TENSOR_TAG_W != WEIGHT_CONTEXT_TAG_W || DMA_COUNT_W < K_COUNT_W ||
        DMA_COUNT_W < ACTIVATION_COUNT_W || DMA_BYTE_COUNT_W < DMA_COUNT_W + 3)
      $fatal(1, "FC DMA count/tag parameterization is invalid");
  end
  always_ff @(posedge clk) begin
    if (!rst) begin
      if (chunk_active && (dma_descriptor_ready || cfg_ready || weight_release_ready))
        $fatal(1, "FC DMA owner changed during an accepted chunk");
      if (dma_busy && (chunk_ready || cfg_ready || weight_release_ready))
        $fatal(1, "FC compute/config/release escaped input DMA ownership");
      if (core_chunk_rejected && (result_armed_q || result_descriptor_valid || result_busy))
        $fatal(1, "rejected FC chunk armed a result DMA owner");
      if (transaction_done && (!pipeline_idle || m_axis_tvalid || fault))
        $fatal(1, "FC DMA final completion preceded clean S2MM drain");
      if (ing_activation_fill_valid && !input_valid_shape)
        $fatal(1, "unvalidated FC activation DMA acquired storage");
    end
  end
`endif
endmodule
