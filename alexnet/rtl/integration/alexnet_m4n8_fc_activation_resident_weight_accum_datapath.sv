`timescale 1ns/1ps

// One consuming 512-word activation bank around the unchanged FC datapath.
// Fill ABI: [K block][M][8 K lanes], mask=FF on every physical word, zero
// padding in unused K lanes, exactly ceil(K/8)*M words and final-word last.
// Read masks are reconstructed from K/M and word index for the FC issuer.
// Malformed fills drain their declared word count and quarantine until reset.
// Correctable compute rejection leaves both activation and weight owners intact.
module alexnet_m4n8_fc_activation_resident_weight_accum_datapath #(
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

    input logic weight_fill_valid,
    output logic weight_fill_ready,
    input logic [K_COUNT_W-1:0] weight_fill_k_count,
    input logic [7:0] weight_fill_n_lane_mask,
    input logic [WEIGHT_CONTEXT_TAG_W-1:0] weight_fill_context_tag,
    input logic weight_write_valid,
    output logic weight_write_ready,
    input logic [63:0] weight_write_values,
    input logic [7:0] weight_write_n_lane_mask,
    input logic weight_write_last,
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

    input logic activation_fill_valid,
    output logic activation_fill_ready,
    input logic [K_COUNT_W-1:0] activation_fill_k_count,
    input logic [2:0] activation_fill_m_count,
    input logic [TENSOR_TAG_W-1:0] activation_fill_tensor_tag,
    input logic activation_write_valid,
    output logic activation_write_ready,
    input logic [63:0] activation_write_values,
    input logic [7:0] activation_write_lane_mask,
    input logic activation_write_last,
    input logic [TENSOR_TAG_W-1:0] activation_write_tensor_tag,
    output logic activation_fill_active,
    output logic activation_fill_done,
    output logic activation_fill_rejected,
    output logic activation_fill_failed,
    output logic activation_read_active,
    output logic activation_read_done,
    output logic [1:0] activation_bank_state,
    output logic [ACTIVATION_COUNT_W-1:0] activation_word_count,
    output logic [ACTIVATION_COUNT_W-1:0] activation_words_forwarded,
    output logic [15:0] accepted_activation_fills,
    output logic [15:0] completed_activation_fills,
    output logic [15:0] rejected_activation_fills,
    output logic [15:0] failed_activation_fills,

    output logic egress_valid,
    input logic egress_ready,
    output logic [63:0] egress_values,
    output logic [7:0] egress_lane_mask,
    output logic [1:0] egress_destination,
    output logic [2:0] egress_slice,
    output logic [4:0] egress_m,
    output logic [N_BASE_W-1:0] egress_n_base,
    output logic [TILE_TAG_W-1:0] egress_tile_tag,

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

  typedef enum logic [1:0] {IDLE, CHECK, SUBMIT, RUN} state_t;
  typedef enum logic [1:0] {F_IDLE, F_CHECK, F_START, F_WRITE} fill_state_t;
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
  } request_t;
  state_t state_q;
  fill_state_t fill_state_q;
  request_t request_q;

  logic [K_COUNT_W-1:0] fill_k_q;
  logic [2:0] fill_m_q;
  logic [TENSOR_TAG_W-1:0] fill_tag_q;
  logic [K_COUNT_W:0] fill_blocks;
  logic [K_COUNT_W+2:0] fill_words_wide;
  logic [ACTIVATION_COUNT_W-1:0] word_count_q, tail_start_q;
  logic [7:0] tail_mask_q, write_k_mask, read_k_mask;
  logic fill_shape_ok, write_metadata_ok, write_padding_ok, read_metadata_ok;
  logic write_fire, write_expected_last, fill_error_q, local_fault_q;
  logic [63:0] bank_write_values;
  logic bank_fill_ready, bank_write_ready, bank_read_start_ready;
  logic bank_read_start, bank_read_valid, bank_read_ready, bank_read_last;
  logic [63:0] bank_read_values;
  logic [7:0] bank_read_mask;
  logic [ACTIVATION_COUNT_W-1:0] bank_read_index, bank_words_written;
  logic [TENSOR_TAG_W-1:0] bank_read_tag;
  logic core_cfg_ready, core_chunk_ready, core_chunk_active, core_chunk_done;
  logic core_chunk_rejected, core_chunk_failed, core_pipeline_idle, core_fault;
  logic core_weight_fill_ready, core_weight_release_ready, core_activation_ready;
  logic read_done_seen_q, core_done_seen_q, core_failed_seen_q;
  logic boundary_idle, request_activation_match;

  assign phase = state_q;
  assign chunk_active = state_q != IDLE;
  assign boundary_idle = state_q == IDLE && !core_chunk_active;
  assign fault = local_fault_q || core_fault;
  assign pipeline_idle = boundary_idle && core_pipeline_idle &&
                         fill_state_q == F_IDLE && activation_bank_state == 0;
  assign cfg_ready = boundary_idle && !fault && core_cfg_ready;
  assign weight_fill_ready = boundary_idle && !fault && core_weight_fill_ready;
  assign weight_release_ready = boundary_idle && !fault && !chunk_valid &&
                                core_weight_release_ready;
  assign chunk_ready = boundary_idle && !fault && configured &&
                       activation_bank_state == 2 && fill_state_q == F_IDLE &&
                       weight_bank_state == 2 && (transaction_active || !cfg_valid);
  assign activation_fill_ready = boundary_idle && !fault &&
                                 fill_state_q == F_IDLE && activation_bank_state == 0;
  assign activation_fill_active = fill_state_q != F_IDLE;
  // Drain the already accepted fill to its declared word count even after
  // malformed metadata. New ownership is interlocked until reset.
  assign activation_write_ready = fill_state_q == F_WRITE && bank_write_ready;
  assign activation_read_active = activation_bank_state == 3;
  assign activation_word_count = word_count_q;
  assign write_fire = activation_write_valid && activation_write_ready;
  assign write_expected_last = bank_words_written + 1'b1 == word_count_q;
  assign write_k_mask = bank_words_written >= tail_start_q ? tail_mask_q : 8'hff;
  assign read_k_mask = bank_read_index >= tail_start_q ? tail_mask_q : 8'hff;
  assign write_metadata_ok = activation_write_lane_mask == 8'hff &&
                            activation_write_tensor_tag == fill_tag_q &&
                            activation_write_last == write_expected_last;

  // ceil(K/8)*M, with explicit shifts/addition so no multiplier DSP is added.
  assign fill_blocks = ({1'b0, fill_k_q} + (K_COUNT_W+1)'(7)) >> 3;
  always_comb begin
    case (fill_m_q)
      1: fill_words_wide = (K_COUNT_W+3)'(fill_blocks);
      2: fill_words_wide = (K_COUNT_W+3)'(fill_blocks) << 1;
      3: fill_words_wide = ((K_COUNT_W+3)'(fill_blocks) << 1) + fill_blocks;
      4: fill_words_wide = (K_COUNT_W+3)'(fill_blocks) << 2;
      default: fill_words_wide = '0;
    endcase
  end
  assign fill_shape_ok = fill_k_q != 0 && fill_k_q <= WEIGHT_DEPTH &&
                         fill_m_q != 0 && fill_m_q <= 4 &&
                         fill_words_wide != 0 && fill_words_wide <= ACTIVATION_DEPTH;
  always_comb begin
    bank_write_values = '0;
    write_padding_ok = 1'b1;
    for (int lane = 0; lane < 8; lane++) begin
      if (write_k_mask[lane])
        bank_write_values[lane*8 +: 8] = activation_write_values[lane*8 +: 8];
      else if (activation_write_values[lane*8 +: 8] != 0)
        write_padding_ok = 1'b0;
    end
  end
  assign request_activation_match = request_q.k_count == fill_k_q &&
                                    request_q.m_count == fill_m_q &&
                                    request_q.activation_tensor_tag == fill_tag_q;
  // The inner descriptor has its own registered validation. Do NOT consume
  // the activation bank on inner acceptance: a later N/weight/accum rejection
  // must leave it READY. Activation demand proves the inner launch succeeded.
  assign bank_read_start = state_q == RUN && core_activation_ready &&
                           bank_read_start_ready;
  assign bank_read_ready = state_q == RUN && core_activation_ready;
  assign read_metadata_ok = bank_read_index == activation_words_forwarded &&
                            bank_read_mask == 8'hff && bank_read_tag == fill_tag_q &&
                            bank_read_last == (activation_words_forwarded + 1'b1 == word_count_q);

  always_ff @(posedge clk) begin
    if (rst) begin
      fill_state_q <= F_IDLE;
      fill_k_q <= '0;
      fill_m_q <= '0;
      fill_tag_q <= '0;
      word_count_q <= '0;
      tail_start_q <= '0;
      tail_mask_q <= '0;
      fill_error_q <= 1'b0;
      local_fault_q <= 1'b0;
      activation_fill_done <= 1'b0;
      activation_fill_rejected <= 1'b0;
      activation_fill_failed <= 1'b0;
      accepted_activation_fills <= '0;
      completed_activation_fills <= '0;
      rejected_activation_fills <= '0;
      failed_activation_fills <= '0;
      activation_words_forwarded <= '0;
    end else begin
      activation_fill_done <= 1'b0;
      activation_fill_rejected <= 1'b0;
      activation_fill_failed <= 1'b0;
      case (fill_state_q)
        F_IDLE: if (activation_fill_valid && activation_fill_ready) begin
          fill_k_q <= activation_fill_k_count;
          fill_m_q <= activation_fill_m_count;
          fill_tag_q <= activation_fill_tensor_tag;
          fill_error_q <= 1'b0;
          accepted_activation_fills <= accepted_activation_fills + 1'b1;
          fill_state_q <= F_CHECK;
        end
        F_CHECK: begin
          if (!fill_shape_ok) begin
            activation_fill_rejected <= 1'b1;
            rejected_activation_fills <= rejected_activation_fills + 1'b1;
            fill_state_q <= F_IDLE;
          end else begin
            word_count_q <= ACTIVATION_COUNT_W'(fill_words_wide);
            tail_start_q <= ACTIVATION_COUNT_W'(fill_words_wide) - fill_m_q;
            tail_mask_q <= fill_k_q[2:0] == 0 ? 8'hff :
                           (8'h1 << fill_k_q[2:0]) - 1'b1;
            fill_state_q <= F_START;
          end
        end
        F_START: if (bank_fill_ready) fill_state_q <= F_WRITE;
        F_WRITE: if (write_fire) begin
          if (!write_metadata_ok || !write_padding_ok) begin
            fill_error_q <= 1'b1;
            local_fault_q <= 1'b1;
          end
          if (write_expected_last) begin
            if (fill_error_q || !write_metadata_ok || !write_padding_ok) begin
              activation_fill_failed <= 1'b1;
              failed_activation_fills <= failed_activation_fills + 1'b1;
            end else begin
              activation_fill_done <= 1'b1;
              completed_activation_fills <= completed_activation_fills + 1'b1;
            end
            fill_state_q <= F_IDLE;
          end
        end
        default: fill_state_q <= F_IDLE;
      endcase
      if (bank_read_start) activation_words_forwarded <= '0;
      if (bank_read_valid && bank_read_ready) begin
        activation_words_forwarded <= activation_words_forwarded + 1'b1;
        if (!read_metadata_ok) local_fault_q <= 1'b1;
      end
    end
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      state_q <= IDLE;
      request_q <= '0;
      read_done_seen_q <= 1'b0;
      core_done_seen_q <= 1'b0;
      core_failed_seen_q <= 1'b0;
      chunk_done <= 1'b0;
      chunk_rejected <= 1'b0;
      chunk_failed <= 1'b0;
      transaction_done <= 1'b0;
      accepted_chunks <= '0;
      completed_chunks <= '0;
      rejected_chunks <= '0;
      failed_chunks <= '0;
    end else begin
      chunk_done <= 1'b0;
      chunk_rejected <= 1'b0;
      chunk_failed <= 1'b0;
      transaction_done <= 1'b0;
      case (state_q)
        IDLE: if (chunk_valid && chunk_ready) begin
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
          accepted_chunks <= accepted_chunks + 1'b1;
          read_done_seen_q <= 1'b0;
          core_done_seen_q <= 1'b0;
          core_failed_seen_q <= 1'b0;
          state_q <= CHECK;
        end
        CHECK: begin
          if (!request_activation_match) begin
            chunk_rejected <= 1'b1;
            rejected_chunks <= rejected_chunks + 1'b1;
            state_q <= IDLE;
          end else state_q <= SUBMIT;
        end
        SUBMIT: if (core_chunk_ready && !fault) state_q <= RUN;
        RUN: begin
          if (activation_read_done) read_done_seen_q <= 1'b1;
          if (core_chunk_done || core_chunk_failed) core_done_seen_q <= 1'b1;
          if (core_chunk_failed) core_failed_seen_q <= 1'b1;
          if (core_chunk_rejected) begin
            chunk_rejected <= 1'b1;
            rejected_chunks <= rejected_chunks + 1'b1;
            state_q <= IDLE;
          end else if ((read_done_seen_q || activation_read_done) &&
                       (core_done_seen_q || core_chunk_done || core_chunk_failed) &&
                       !core_chunk_active && activation_bank_state == 0) begin
            if (fault || core_failed_seen_q || core_chunk_failed) begin
              chunk_failed <= 1'b1;
              failed_chunks <= failed_chunks + 1'b1;
            end else begin
              chunk_done <= 1'b1;
              transaction_done <= request_q.final_chunk;
              completed_chunks <= completed_chunks + 1'b1;
            end
            state_q <= IDLE;
          end
        end
        default: state_q <= IDLE;
      endcase
    end
  end

  alexnet_n8_activation_bank #(
      .DEPTH(ACTIVATION_DEPTH), .TENSOR_TAG_W(TENSOR_TAG_W),
      .ADDR_W(ACTIVATION_COUNT_W), .COUNT_W(ACTIVATION_COUNT_W)
  ) u_activation_bank (
      .clk(clk), .rst(rst), .fill_valid(fill_state_q == F_START),
      .fill_ready(bank_fill_ready), .fill_word_count(word_count_q),
      .fill_lane_mask(8'hff), .fill_tensor_tag(fill_tag_q),
      .write_valid(write_fire), .write_ready(bank_write_ready),
      .write_values(bank_write_values), .write_lane_mask(8'hff),
      .write_last(write_expected_last), .read_start_valid(bank_read_start),
      .read_start_ready(bank_read_start_ready), .read_valid(bank_read_valid),
      .read_ready(bank_read_ready), .read_values(bank_read_values),
      .read_lane_mask(bank_read_mask), .read_index(bank_read_index),
      .read_last(bank_read_last), .read_tensor_tag(bank_read_tag),
      .bank_state(activation_bank_state), .words_written(bank_words_written),
      .read_done(activation_read_done), .idle()
  );

  alexnet_m4n8_fc_resident_weight_accum_datapath #(
      .EXTERNAL_COMPUTE(EXTERNAL_COMPUTE),
      .RUNTIME_SLICE_INDEX(RUNTIME_SLICE_INDEX),
      .SLICE_INDEX(SLICE_INDEX), .FIFO_DEPTH(FIFO_DEPTH), .BANK_DEPTH(BANK_DEPTH),
      .WEIGHT_DEPTH(WEIGHT_DEPTH), .TILE_TAG_W(TILE_TAG_W),
      .TENSOR_TAG_W(TENSOR_TAG_W), .CONTEXT_TAG_W(CONTEXT_TAG_W),
      .WEIGHT_CONTEXT_TAG_W(WEIGHT_CONTEXT_TAG_W),
      .CHUNK_INDEX_W(CHUNK_INDEX_W), .N_BASE_W(N_BASE_W), .K_COUNT_W(K_COUNT_W)
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
      .weight_fill_valid(weight_fill_valid && weight_fill_ready),
      .weight_fill_ready(core_weight_fill_ready),
      .weight_fill_k_count(weight_fill_k_count),
      .weight_fill_n_lane_mask(weight_fill_n_lane_mask),
      .weight_fill_context_tag(weight_fill_context_tag),
      .weight_write_valid(weight_write_valid),
      .weight_write_ready(weight_write_ready),
      .weight_write_values(weight_write_values),
      .weight_write_n_lane_mask(weight_write_n_lane_mask),
      .weight_write_last(weight_write_last),
      .weight_release_valid(weight_release_valid && weight_release_ready),
      .weight_release_ready(core_weight_release_ready),
      .chunk_valid(state_q == SUBMIT && !fault),
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
      .activation_valid(bank_read_valid && state_q == RUN),
      .activation_ready(core_activation_ready),
      .activation_values(bank_read_values),
      .activation_lane_mask(read_k_mask),
      .activation_last(bank_read_last),
      .activation_tensor_tag(bank_read_tag),
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

`ifndef SYNTHESIS
  initial begin
    if (ACTIVATION_DEPTH < 4 || (1 << ACTIVATION_COUNT_W) <= ACTIVATION_DEPTH)
      $fatal(1, "FC activation buffer parameterization is invalid");
  end
  always_ff @(posedge clk) begin
    if (!rst) begin
      if (bank_read_start && (!request_activation_match || core_chunk_rejected))
        $fatal(1, "FC consumed an unvalidated activation tensor");
      if (core_chunk_rejected && (activation_bank_state != 2 || activation_read_active))
        $fatal(1, "FC inner rejection consumed its activation bank");
      if (chunk_active && (cfg_ready || weight_fill_ready ||
                           weight_release_ready || activation_fill_ready))
        $fatal(1, "FC activation-buffered owner changed during a chunk");
      if (transaction_done && (!pipeline_idle || egress_valid || fault))
        $fatal(1, "FC activation-buffered final completion before clean drain");
    end
  end
`endif
endmodule
