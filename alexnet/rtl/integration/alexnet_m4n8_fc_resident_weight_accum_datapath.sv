`timescale 1ns/1ps

// One FC M1..4/N1..8 output tile, accumulated over explicit K chunks.
// Activation ABI: [chunk-local K block][M][K lane], weight ABI: [K][N].
// The parent loads weights before each descriptor, and explicitly releases
// them between K chunks. No pool5 flattening or layer geometry is implied.
// Rejected descriptors have no child side effects and can be corrected.
// A source/protocol fault poisons the transaction until reset: the owned
// chunk drains, but reports chunk_failed instead of chunk_done. Its output
// must be discarded by the parent, including packets accepted before fault.
module alexnet_m4n8_fc_resident_weight_accum_datapath #(
    parameter bit EXTERNAL_COMPUTE = 1'b0,
    parameter int SLICE_INDEX = 0,
    parameter int FIFO_DEPTH = 64,
    parameter int BANK_DEPTH = 512,
    parameter int WEIGHT_DEPTH = 968,
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

    input logic activation_valid,
    output logic activation_ready,
    input logic [63:0] activation_values,
    input logic [7:0] activation_lane_mask,
    input logic activation_last,
    input logic [TENSOR_TAG_W-1:0] activation_tensor_tag,

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
  localparam int BANK_COUNT_W = $clog2(BANK_DEPTH + 1);
  typedef enum logic [1:0] {IDLE, CHECK, LAUNCH, RUN} state_t;
  state_t state_q;
  logic [K_COUNT_W-1:0] k_q;
  logic [2:0] m_q;
  logic [7:0] mask_q, cfg_mask_q;
  logic [TENSOR_TAG_W-1:0] activation_tag_q;
  logic [WEIGHT_CONTEXT_TAG_W-1:0] weight_tag_q;
  logic [CONTEXT_TAG_W-1:0] context_q, resident_context_q;
  logic [TILE_TAG_W-1:0] tag_q, resident_tag_q;
  logic [CHUNK_INDEX_W-1:0] index_q, next_index_q;
  logic first_q, final_q, open_q;
  logic [2:0] resident_m_q;
  logic issuer_done_seen_q, accum_done_seen_q, fault_q;
  logic shape_ok, context_ok, launch_fire, boundary_idle;
  logic base_cfg_ready, base_chunk_ready, base_chunk_active, base_chunk_done;
  logic base_idle, base_error, accum_error;
  logic issuer_ready, issuer_idle, issuer_done, issuer_error, issuer_rejected;
  logic bank_fill_ready, bank_write_ready, bank_release_ready, bank_error;
  logic [K_COUNT_W-1:0] resident_k;
  logic [7:0] resident_mask;
  logic [WEIGHT_CONTEXT_TAG_W-1:0] resident_weight_tag;
  logic replay_valid, replay_ready, weight_valid, weight_ready, weight_last;
  logic [K_COUNT_W-1:0] replay_k, weight_k;
  logic [7:0] replay_mask, weight_mask;
  logic [WEIGHT_CONTEXT_TAG_W-1:0] replay_tag, weight_tag;
  logic signed [7:0] weight_values [0:7];
  logic tile_valid, tile_ready, tile_done, issue_valid, issue_ready, issue_last;
  logic [2:0] tile_m;
  logic [7:0] tile_mask;
  logic [TILE_TAG_W-1:0] tile_tag;
  logic signed [7:0] issue_act_lo [0:1], issue_act_hi [0:1];
  logic signed [7:0] issue_weight [0:7];

  assign phase = state_q;
  assign chunk_active = state_q != IDLE;
  assign boundary_idle = !chunk_active && issuer_idle &&
                         !compute_busy && !base_chunk_active;
  assign fault = fault_q || issuer_error || issuer_rejected ||
                 bank_error || base_error || accum_error;
  // An open partial-sum transaction intentionally is not pipeline-idle.
  assign pipeline_idle = boundary_idle && base_idle &&
                         weight_bank_state != 2'd1 &&
                         weight_bank_state != 2'd3;
  assign cfg_ready = boundary_idle && !fault && base_cfg_ready;
  // A pending config must not block continuation chunks of the old config.
  assign chunk_ready = boundary_idle && configured && !fault &&
                       weight_bank_state == 2'd2 &&
                       (open_q || !cfg_valid);
  assign weight_fill_ready = boundary_idle && !fault && bank_fill_ready;
  assign weight_write_ready = bank_write_ready && !fault;
  // A descriptor wins over simultaneous release; its resident context stays
  // immutable from acceptance through validation, replay, and retirement.
  assign weight_release_ready = boundary_idle && !fault &&
                                !chunk_valid && bank_release_ready;

  assign shape_ok = k_q != 0 && k_q <= WEIGHT_DEPTH &&
                    m_q != 0 && m_q <= 4 && mask_q != 0 &&
                    (mask_q & (mask_q + 1'b1)) == 0 && mask_q == cfg_mask_q &&
                    (final_q || !(&index_q));
  assign context_ok = weight_bank_state == 2'd2 &&
                      k_q == resident_k && mask_q == resident_mask &&
                      weight_tag_q == resident_weight_tag &&
                      ((first_q && !open_q && index_q == 0) ||
                       (!first_q && open_q && index_q == next_index_q &&
                        m_q == resident_m_q && context_q == resident_context_q &&
                        tag_q == resident_tag_q));
  assign launch_fire = state_q == LAUNCH && issuer_ready &&
                       base_chunk_ready && !fault;

  always_ff @(posedge clk) begin
    if (rst) begin
      state_q <= IDLE;
      k_q <= '0;
      m_q <= '0;
      mask_q <= '0;
      cfg_mask_q <= '0;
      activation_tag_q <= '0;
      weight_tag_q <= '0;
      context_q <= '0;
      tag_q <= '0;
      index_q <= '0;
      first_q <= 1'b0;
      final_q <= 1'b0;
      open_q <= 1'b0;
      resident_m_q <= '0;
      resident_context_q <= '0;
      resident_tag_q <= '0;
      next_index_q <= '0;
      issuer_done_seen_q <= 1'b0;
      accum_done_seen_q <= 1'b0;
      fault_q <= 1'b0;
      chunk_done <= 1'b0;
      chunk_rejected <= 1'b0;
      chunk_failed <= 1'b0;
      transaction_done <= 1'b0;
      accepted_chunks <= '0;
      completed_chunks <= '0;
      rejected_chunks <= '0;
      failed_chunks <= '0;
    end else begin
      fault_q <= fault;
      chunk_done <= 1'b0;
      chunk_rejected <= 1'b0;
      chunk_failed <= 1'b0;
      transaction_done <= 1'b0;
      if (cfg_valid && cfg_ready) cfg_mask_q <= cfg_lane_mask;
      case (state_q)
        IDLE: if (chunk_valid && chunk_ready) begin
          k_q <= chunk_k_count;
          m_q <= chunk_m_count;
          mask_q <= chunk_n_lane_mask;
          activation_tag_q <= chunk_activation_tensor_tag;
          weight_tag_q <= chunk_weight_context_tag;
          context_q <= chunk_context_tag;
          tag_q <= chunk_tile_tag;
          index_q <= chunk_index;
          first_q <= chunk_first;
          final_q <= chunk_final;
          accepted_chunks <= accepted_chunks + 1'b1;
          issuer_done_seen_q <= 1'b0;
          accum_done_seen_q <= 1'b0;
          state_q <= CHECK;
        end
        CHECK: begin
          if (!shape_ok || !context_ok) begin
            chunk_rejected <= 1'b1;
            rejected_chunks <= rejected_chunks + 1'b1;
            state_q <= IDLE;
          end else state_q <= LAUNCH;
        end
        LAUNCH: if (launch_fire) begin
          resident_m_q <= m_q;
          resident_context_q <= context_q;
          resident_tag_q <= tag_q;
          next_index_q <= index_q + 1'b1;
          state_q <= RUN;
        end
        RUN: begin
          if (issuer_done) issuer_done_seen_q <= 1'b1;
          if (base_chunk_done) accum_done_seen_q <= 1'b1;
          if ((issuer_done_seen_q || issuer_done) &&
              (accum_done_seen_q || base_chunk_done) &&
              !compute_busy && !base_chunk_active &&
              weight_bank_state == 2'd2 && (!final_q || base_idle)) begin
            open_q <= !final_q;
            if (fault) begin
              chunk_failed <= 1'b1;
              failed_chunks <= failed_chunks + 1'b1;
            end else begin
              chunk_done <= 1'b1;
              transaction_done <= final_q;
              completed_chunks <= completed_chunks + 1'b1;
            end
            state_q <= IDLE;
          end
        end
        default: state_q <= IDLE;
      endcase
    end
  end

  alexnet_n8_weight_tile_bank #(
      .DEPTH(WEIGHT_DEPTH), .CONTEXT_TAG_W(WEIGHT_CONTEXT_TAG_W),
      .ADDR_W(K_COUNT_W), .COUNT_W(K_COUNT_W)
  ) u_weight_bank (
      .clk(clk), .rst(rst),
      .fill_valid(weight_fill_valid && weight_fill_ready),
      .fill_ready(bank_fill_ready), .fill_k_count(weight_fill_k_count),
      .fill_n_lane_mask(weight_fill_n_lane_mask),
      .fill_context_tag(weight_fill_context_tag),
      .write_valid(weight_write_valid && weight_write_ready),
      .write_ready(bank_write_ready), .write_values(weight_write_values),
      .write_n_lane_mask(weight_write_n_lane_mask), .write_last(weight_write_last),
      .replay_valid(replay_valid), .replay_ready(replay_ready),
      .replay_k_count(replay_k), .replay_n_lane_mask(replay_mask),
      .replay_context_tag(replay_tag), .weight_valid(weight_valid),
      .weight_ready(weight_ready), .weight_values(weight_values),
      .weight_k(weight_k), .weight_last(weight_last),
      .weight_n_lane_mask(weight_mask), .weight_context_tag(weight_tag),
      .release_valid(weight_release_valid && weight_release_ready),
      .release_ready(bank_release_ready), .bank_state(weight_bank_state),
      .resident_valid(), .resident_k_count(resident_k),
      .resident_n_lane_mask(resident_mask),
      .resident_context_tag(resident_weight_tag), .words_written(),
      .completed_replays(completed_replays), .replay_done(),
      .context_error(bank_error), .idle()
  );

  alexnet_n8_fc_m4_issuer #(
      .K_COUNT_W(K_COUNT_W), .TILE_TAG_W(TILE_TAG_W),
      .TENSOR_TAG_W(TENSOR_TAG_W), .WEIGHT_CONTEXT_TAG_W(WEIGHT_CONTEXT_TAG_W)
  ) u_issuer (
      .clk(clk), .rst(rst), .descriptor_valid(launch_fire),
      .descriptor_ready(issuer_ready), .descriptor_k_count(k_q),
      .descriptor_m_count(m_q), .descriptor_n_lane_mask(mask_q),
      .descriptor_activation_tensor_tag(activation_tag_q),
      .descriptor_weight_context_tag(weight_tag_q), .descriptor_tile_tag(tag_q),
      .activation_valid(activation_valid), .activation_ready(activation_ready),
      .activation_values(activation_values), .activation_lane_mask(activation_lane_mask),
      .activation_last(activation_last), .activation_tensor_tag(activation_tensor_tag),
      .weight_replay_valid(replay_valid), .weight_replay_ready(replay_ready),
      .weight_replay_k_count(replay_k), .weight_replay_n_lane_mask(replay_mask),
      .weight_replay_context_tag(replay_tag), .weight_valid(weight_valid),
      .weight_ready(weight_ready), .weight_values(weight_values),
      .weight_k(weight_k), .weight_last(weight_last),
      .weight_n_lane_mask(weight_mask), .weight_context_tag(weight_tag),
      .tile_start_valid(tile_valid), .tile_start_ready(tile_ready),
      .tile_m_count(tile_m), .tile_n_lane_mask(tile_mask), .tile_tag(tile_tag),
      .issue_valid(issue_valid), .issue_ready(issue_ready), .issue_last(issue_last),
      .issue_act_lo(issue_act_lo), .issue_act_hi(issue_act_hi),
      .issue_weight(issue_weight), .tile_done(tile_done), .issuer_idle(issuer_idle),
      .descriptor_active(), .descriptor_done(issuer_done),
      .descriptor_rejected(issuer_rejected), .protocol_error(issuer_error),
      .phase(), .active_k(), .activation_words_consumed(),
      .accepted_descriptors(), .completed_descriptors(), .rejected_descriptors(),
      .completed_k_tokens(completed_k_tokens)
  );

  generate if (EXTERNAL_COMPUTE) begin : g_shared
    assign shared_cfg_valid = cfg_valid && cfg_ready;
    assign base_cfg_ready = shared_cfg_ready;
    assign shared_cfg_destination = cfg_destination;
    assign shared_cfg_n64_tile_base = cfg_n64_tile_base;
    assign shared_cfg_slice_index = cfg_slice_index;
    assign shared_cfg_lane_mask = cfg_lane_mask;
    assign shared_cfg_bias = cfg_bias;
    assign shared_cfg_multiplier = cfg_multiplier;
    assign shared_cfg_right_shift = cfg_right_shift;
    assign shared_cfg_relu = cfg_relu;
    assign shared_chunk_valid = launch_fire;
    assign base_chunk_ready = shared_chunk_ready;
    assign shared_chunk_word_count = BANK_COUNT_W'(m_q);
    assign shared_chunk_output_width = 8'(m_q);
    assign shared_chunk_n_lane_mask = mask_q;
    assign shared_chunk_context_tag = context_q;
    assign shared_chunk_tile_tag_base = tag_q;
    assign shared_chunk_index = index_q;
    assign shared_chunk_first = first_q;
    assign shared_chunk_final = final_q;
    assign shared_tile_start_valid = tile_valid;
    assign tile_ready = shared_tile_start_ready;
    assign shared_tile_m_count = tile_m;
    assign shared_tile_n_lane_mask = tile_mask;
    assign shared_tile_tag = tile_tag;
    assign shared_issue_valid = issue_valid;
    assign issue_ready = shared_issue_ready;
    assign shared_issue_last = issue_last;
    assign shared_issue_act_lo = issue_act_lo;
    assign shared_issue_act_hi = issue_act_hi;
    assign shared_issue_weight = issue_weight;
    assign egress_valid = shared_egress_valid;
    assign shared_egress_ready = egress_ready;
    assign egress_values = shared_egress_values;
    assign egress_lane_mask = shared_egress_lane_mask;
    assign egress_destination = shared_egress_destination;
    assign egress_slice = shared_egress_slice;
    assign egress_m = shared_egress_m;
    assign egress_n_base = shared_egress_n_base;
    assign egress_tile_tag = shared_egress_tile_tag;
    assign configured = shared_configured;
    assign compute_busy = shared_compute_busy;
    assign transaction_active = shared_transaction_active;
    assign base_chunk_active = shared_chunk_active;
    assign tile_done = shared_tile_done;
    assign base_chunk_done = shared_chunk_done;
    assign base_idle = shared_datapath_idle;
    assign accum_bank_state = shared_accum_bank_state;
    assign accum_error = shared_accum_context_error;
    assign base_error = shared_protocol_error;
    assign queued_count = shared_queued_count;
  end else begin : g_local
  alexnet_m4n8_accum_base_datapath #(
      .RUNTIME_SLICE_INDEX(RUNTIME_SLICE_INDEX),
      .SLICE_INDEX(SLICE_INDEX), .FIFO_DEPTH(FIFO_DEPTH), .BANK_DEPTH(BANK_DEPTH),
      .TILE_TAG_W(TILE_TAG_W), .CONTEXT_TAG_W(CONTEXT_TAG_W),
      .CHUNK_INDEX_W(CHUNK_INDEX_W), .N_BASE_W(N_BASE_W)
  ) u_base (
      .clk(clk), .rst(rst), .ce(ce),
      .cfg_valid(cfg_valid && cfg_ready), .cfg_ready(base_cfg_ready),
      .cfg_destination(cfg_destination), .cfg_n64_tile_base(cfg_n64_tile_base),
      .cfg_slice_index(cfg_slice_index),
      .cfg_lane_mask(cfg_lane_mask), .cfg_bias(cfg_bias),
      .cfg_multiplier(cfg_multiplier), .cfg_right_shift(cfg_right_shift),
      .cfg_relu(cfg_relu), .chunk_valid(launch_fire), .chunk_ready(base_chunk_ready),
      .chunk_word_count(BANK_COUNT_W'(m_q)), .chunk_output_width(8'(m_q)),
      .chunk_n_lane_mask(mask_q), .chunk_context_tag(context_q),
      .chunk_tile_tag_base(tag_q), .chunk_index(index_q),
      .chunk_first(first_q), .chunk_final(final_q),
      .tile_start_valid(tile_valid), .tile_start_ready(tile_ready),
      .tile_m_count(tile_m), .tile_n_lane_mask(tile_mask), .tile_tag(tile_tag),
      .issue_valid(issue_valid), .issue_ready(issue_ready), .issue_last(issue_last),
      .issue_act_lo(issue_act_lo), .issue_act_hi(issue_act_hi),
      .issue_weight(issue_weight), .egress_valid(egress_valid),
      .egress_ready(egress_ready), .egress_values(egress_values),
      .egress_lane_mask(egress_lane_mask), .egress_destination(egress_destination),
      .egress_slice(egress_slice), .egress_m(egress_m), .egress_n_base(egress_n_base),
      .egress_tile_tag(egress_tile_tag), .configured(configured),
      .compute_busy(compute_busy), .transaction_active(transaction_active),
      .chunk_active(base_chunk_active), .tile_done(tile_done),
      .chunk_done(base_chunk_done), .transaction_done(), .datapath_idle(base_idle),
      .accum_bank_state(accum_bank_state), .accum_context_error(accum_error),
      .protocol_error(base_error), .queued_count(queued_count)
  );

    assign shared_cfg_valid = '0;
    assign shared_cfg_destination = '0;
    assign shared_cfg_n64_tile_base = '0;
    assign shared_cfg_slice_index = '0;
    assign shared_cfg_lane_mask = '0;
    assign shared_cfg_bias = '{default:'0};
    assign shared_cfg_multiplier = '{default:'0};
    assign shared_cfg_right_shift = '{default:'0};
    assign shared_cfg_relu = '0;
    assign shared_chunk_valid = '0;
    assign shared_chunk_word_count = '0;
    assign shared_chunk_output_width = '0;
    assign shared_chunk_n_lane_mask = '0;
    assign shared_chunk_context_tag = '0;
    assign shared_chunk_tile_tag_base = '0;
    assign shared_chunk_index = '0;
    assign shared_chunk_first = '0;
    assign shared_chunk_final = '0;
    assign shared_tile_start_valid = '0;
    assign shared_tile_m_count = '0;
    assign shared_tile_n_lane_mask = '0;
    assign shared_tile_tag = '0;
    assign shared_issue_valid = '0;
    assign shared_issue_last = '0;
    assign shared_issue_act_lo = '{default:'0};
    assign shared_issue_act_hi = '{default:'0};
    assign shared_issue_weight = '{default:'0};
    assign shared_egress_ready = '0;
  end endgenerate
`ifndef SYNTHESIS
  initial begin
    if (BANK_DEPTH < 4 || K_COUNT_W < 4 || (1 << K_COUNT_W) <= WEIGHT_DEPTH)
      $fatal(1, "FC resident accumulator parameterization is invalid");
  end
  always_ff @(posedge clk) begin
    if (!rst) begin
      if (chunk_active && (weight_fill_ready || weight_release_ready || cfg_ready))
        $fatal(1, "FC owner changed during a chunk");
      if (launch_fire && (!shape_ok || !context_ok))
        $fatal(1, "FC launched an unvalidated descriptor");
      if (transaction_done && (!pipeline_idle || egress_valid || fault))
        $fatal(1, "FC reported success before clean final-output drain");
    end
  end
`endif
endmodule
