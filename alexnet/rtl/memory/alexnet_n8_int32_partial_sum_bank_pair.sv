`timescale 1ns/1ps

// Two identical 512-word N8 INT32 partial-sum banks exposed as one ordered
// raster of 1..1024 words. Both children accept every chunk descriptor
// atomically. Long rasters split and rebase at word 512. Short rasters are
// mirrored into both children and drained in lockstep, keeping their retained
// chunk/context state aligned without adding memory.
module alexnet_n8_int32_partial_sum_bank_pair #(
    parameter int SEGMENT_DEPTH = 512,
    parameter int CONTEXT_TAG_W = 16,
    parameter int CHUNK_INDEX_W = 8,
    parameter int SEGMENT_ADDR_W = $clog2(SEGMENT_DEPTH),
    parameter int SEGMENT_COUNT_W = $clog2(SEGMENT_DEPTH + 1),
    parameter int TOTAL_ADDR_W = $clog2(2 * SEGMENT_DEPTH),
    parameter int TOTAL_COUNT_W = $clog2(2 * SEGMENT_DEPTH + 1)
) (
    input logic clk,
    input logic rst,

    input  logic descriptor_valid,
    output logic descriptor_ready,
    input  logic [TOTAL_COUNT_W-1:0] descriptor_word_count,
    input  logic [7:0] descriptor_n_lane_mask,
    input  logic [CONTEXT_TAG_W-1:0] descriptor_context_tag,
    input  logic [CHUNK_INDEX_W-1:0] descriptor_chunk_index,
    input  logic descriptor_first_chunk,
    input  logic descriptor_final_chunk,

    input  logic ingress_valid,
    output logic ingress_ready,
    input  logic signed [31:0] ingress_accumulator [0:7],
    input  logic [7:0] ingress_n_lane_mask,
    input  logic [TOTAL_ADDR_W-1:0] ingress_word_index,
    input  logic ingress_last,

    output logic egress_valid,
    input  logic egress_ready,
    output logic signed [31:0] egress_accumulator [0:7],
    output logic [7:0] egress_n_lane_mask,
    output logic [TOTAL_ADDR_W-1:0] egress_word_index,
    output logic egress_last,
    output logic [CONTEXT_TAG_W-1:0] egress_context_tag,

    output logic [2:0] bank_state,
    output logic resident_valid,
    output logic [TOTAL_COUNT_W-1:0] resident_word_count,
    output logic [7:0] resident_n_lane_mask,
    output logic [CONTEXT_TAG_W-1:0] resident_context_tag,
    output logic [CHUNK_INDEX_W-1:0] next_chunk_index,
    output logic [CHUNK_INDEX_W:0] completed_chunks,
    output logic [TOTAL_COUNT_W-1:0] words_accepted,
    output logic chunk_done,
    output logic emit_done,
    output logic context_error,
    output logic protocol_error,
    output logic idle
);

  localparam logic [2:0] STATE_EMPTY = 3'd0;
  localparam logic [2:0] STATE_INGEST_FIRST = 3'd1;
  localparam logic [2:0] STATE_READY = 3'd2;
  localparam logic [2:0] STATE_INGEST_ACCUM = 3'd3;
  localparam logic [2:0] STATE_EMITTING = 3'd4;

  logic descriptor_shape_valid;
  logic first_descriptor_valid;
  logic continuation_match;
  logic descriptor_fire;
  logic child_descriptor_valid;
  logic [SEGMENT_COUNT_W-1:0] descriptor_segment_count [0:1];
  logic child_descriptor_ready [0:1];

  logic ingress_metadata_match;
  logic resident_replicated;
  logic ingress_select;
  logic [SEGMENT_ADDR_W-1:0] ingress_local_index;
  logic ingress_local_last;
  logic child_ingress_valid [0:1];
  logic child_ingress_ready [0:1];
  logic ingress_fire;

  logic child_egress_valid [0:1];
  logic child_egress_ready [0:1];
  logic signed [31:0] child_egress_accumulator [0:1][0:7];
  logic [7:0] child_egress_n_lane_mask [0:1];
  logic [SEGMENT_ADDR_W-1:0] child_egress_word_index [0:1];
  logic child_egress_last [0:1];
  logic [CONTEXT_TAG_W-1:0] child_egress_context_tag [0:1];
  logic egress_fire;
  logic emit_enabled_q;
  logic emit_segment_q;

  logic [2:0] child_bank_state [0:1];
  logic child_resident_valid [0:1];
  logic [SEGMENT_COUNT_W-1:0] child_resident_word_count [0:1];
  logic [7:0] child_resident_n_lane_mask [0:1];
  logic [CONTEXT_TAG_W-1:0] child_resident_context_tag [0:1];
  logic [CHUNK_INDEX_W-1:0] child_next_chunk_index [0:1];
  logic [CHUNK_INDEX_W:0] child_completed_chunks [0:1];
  logic [SEGMENT_COUNT_W-1:0] child_words_accepted [0:1];
  logic child_chunk_done [0:1];
  logic child_emit_done [0:1];
  logic child_context_error [0:1];
  logic child_protocol_error [0:1];
  logic child_idle [0:1];

  logic chunk_done_seen_q [0:1];
  logic current_final_chunk_q;
  logic children_chunk_complete;
  logic context_error_q;
  logic protocol_error_q;

  assign idle = bank_state == STATE_EMPTY;
  assign resident_valid = bank_state != STATE_EMPTY;

  assign descriptor_shape_valid =
      (descriptor_word_count != 0) &&
      (descriptor_word_count <= 2 * SEGMENT_DEPTH) &&
      (descriptor_n_lane_mask != 0) &&
      ((descriptor_n_lane_mask & (descriptor_n_lane_mask + 1'b1)) == 0);
  assign first_descriptor_valid = descriptor_shape_valid &&
                                  descriptor_first_chunk &&
                                  (descriptor_chunk_index == 0);
  assign continuation_match = descriptor_shape_valid &&
                              !descriptor_first_chunk &&
                              (descriptor_word_count == resident_word_count) &&
                              (descriptor_n_lane_mask == resident_n_lane_mask) &&
                              (descriptor_context_tag == resident_context_tag) &&
                              (descriptor_chunk_index == next_chunk_index);

  always_comb begin
    if (descriptor_word_count <= SEGMENT_DEPTH) begin
      descriptor_segment_count[0] =
          SEGMENT_COUNT_W'(descriptor_word_count);
      descriptor_segment_count[1] =
          SEGMENT_COUNT_W'(descriptor_word_count);
    end else begin
      descriptor_segment_count[0] = SEGMENT_DEPTH;
      descriptor_segment_count[1] =
          SEGMENT_COUNT_W'(descriptor_word_count - SEGMENT_DEPTH);
    end
    descriptor_ready = 1'b0;
    if (bank_state == STATE_EMPTY)
      descriptor_ready = first_descriptor_valid &&
                         child_descriptor_ready[0] &&
                         child_descriptor_ready[1];
    else if (bank_state == STATE_READY)
      descriptor_ready = continuation_match &&
                         child_descriptor_ready[0] &&
                         child_descriptor_ready[1];
  end

  assign descriptor_fire = descriptor_valid && descriptor_ready;
  // Child ready is independent of valid, so this pulse makes their descriptor
  // handshakes atomic even if one child reaches READY earlier than the other.
  assign child_descriptor_valid = descriptor_fire;

  assign resident_replicated = resident_word_count <= SEGMENT_DEPTH;
  assign ingress_select = ingress_word_index >= SEGMENT_DEPTH;
  assign ingress_local_index = ingress_select ?
      ingress_word_index - SEGMENT_DEPTH : ingress_word_index;
  assign ingress_local_last = resident_replicated ? ingress_last :
      (ingress_select ?
      (ingress_word_index + 1'b1 == resident_word_count) :
      (ingress_word_index + 1'b1 == SEGMENT_DEPTH));
  assign ingress_metadata_match =
      (ingress_word_index == words_accepted[TOTAL_ADDR_W-1:0]) &&
      (ingress_n_lane_mask == resident_n_lane_mask) &&
      (ingress_last ==
       (ingress_word_index + 1'b1 == resident_word_count));
  assign child_ingress_valid[0] = ingress_valid && ingress_metadata_match &&
      (resident_replicated ? child_ingress_ready[1] : !ingress_select);
  assign child_ingress_valid[1] = ingress_valid && ingress_metadata_match &&
      (resident_replicated ? child_ingress_ready[0] : ingress_select);
  assign ingress_ready =
      ((bank_state == STATE_INGEST_FIRST) ||
       (bank_state == STATE_INGEST_ACCUM)) && ingress_metadata_match &&
      (resident_replicated ?
          (child_ingress_ready[0] && child_ingress_ready[1]) :
          child_ingress_ready[ingress_select]);
  assign ingress_fire = ingress_valid && ingress_ready;

  always_comb begin
    egress_valid = 1'b0;
    egress_n_lane_mask = '0;
    egress_word_index = '0;
    egress_last = 1'b0;
    egress_context_tag = '0;
    for (int lane = 0; lane < 8; lane++)
      egress_accumulator[lane] = '0;

    if (emit_enabled_q && resident_replicated) begin
      egress_valid = child_egress_valid[0] && child_egress_valid[1];
      egress_n_lane_mask = child_egress_n_lane_mask[0];
      egress_context_tag = child_egress_context_tag[0];
      egress_word_index = child_egress_word_index[0];
      egress_last = child_egress_last[0] && child_egress_last[1];
      for (int lane = 0; lane < 8; lane++)
        egress_accumulator[lane] = child_egress_accumulator[0][lane];
    end else if (emit_enabled_q) begin
      egress_valid = child_egress_valid[emit_segment_q];
      egress_n_lane_mask = child_egress_n_lane_mask[emit_segment_q];
      egress_context_tag = child_egress_context_tag[emit_segment_q];
      if (emit_segment_q) begin
        egress_word_index = SEGMENT_DEPTH +
                            child_egress_word_index[1];
        egress_last = child_egress_last[1];
      end else begin
        egress_word_index = child_egress_word_index[0];
        egress_last = 1'b0;
      end
      for (int lane = 0; lane < 8; lane++)
        egress_accumulator[lane] =
            child_egress_accumulator[emit_segment_q][lane];
    end
  end

  assign egress_fire = egress_valid && egress_ready;
  assign child_egress_ready[0] = emit_enabled_q &&
      (resident_replicated ? (egress_ready && child_egress_valid[1]) :
                             (!emit_segment_q && egress_ready));
  assign child_egress_ready[1] = emit_enabled_q &&
      (resident_replicated ? (egress_ready && child_egress_valid[0]) :
                             (emit_segment_q && egress_ready));

  assign children_chunk_complete =
      (chunk_done_seen_q[0] || child_chunk_done[0]) &&
      (chunk_done_seen_q[1] || child_chunk_done[1]);
  assign context_error = context_error_q || child_context_error[0] ||
                         child_context_error[1];
  assign protocol_error = protocol_error_q || child_protocol_error[0] ||
                          child_protocol_error[1];

  always_ff @(posedge clk) begin
    if (rst) begin
      bank_state <= STATE_EMPTY;
      resident_word_count <= '0;
      resident_n_lane_mask <= '0;
      resident_context_tag <= '0;
      next_chunk_index <= '0;
      completed_chunks <= '0;
      words_accepted <= '0;
      current_final_chunk_q <= 1'b0;
      chunk_done_seen_q[0] <= 1'b0;
      chunk_done_seen_q[1] <= 1'b0;
      emit_enabled_q <= 1'b0;
      emit_segment_q <= 1'b0;
      chunk_done <= 1'b0;
      emit_done <= 1'b0;
      context_error_q <= 1'b0;
      protocol_error_q <= 1'b0;
    end else begin
      chunk_done <= 1'b0;
      emit_done <= 1'b0;

      if (descriptor_valid && !descriptor_ready) begin
        if (bank_state == STATE_READY)
          context_error_q <= 1'b1;
        else
          protocol_error_q <= 1'b1;
      end

      if (descriptor_fire) begin
        bank_state <= descriptor_first_chunk ?
                      STATE_INGEST_FIRST : STATE_INGEST_ACCUM;
        words_accepted <= '0;
        current_final_chunk_q <= descriptor_final_chunk;
        chunk_done_seen_q[0] <= 1'b0;
        chunk_done_seen_q[1] <= 1'b0;
        if (descriptor_first_chunk) begin
          resident_word_count <= descriptor_word_count;
          resident_n_lane_mask <= descriptor_n_lane_mask;
          resident_context_tag <= descriptor_context_tag;
          next_chunk_index <= 1;
          completed_chunks <= '0;
          context_error_q <= 1'b0;
          protocol_error_q <= 1'b0;
        end
      end

      if (ingress_valid &&
          ((bank_state == STATE_INGEST_FIRST) ||
           (bank_state == STATE_INGEST_ACCUM)) &&
          !ingress_metadata_match)
        protocol_error_q <= 1'b1;

      if (ingress_fire)
        words_accepted <= words_accepted + 1'b1;

      if (child_chunk_done[0])
        chunk_done_seen_q[0] <= 1'b1;
      if (child_chunk_done[1])
        chunk_done_seen_q[1] <= 1'b1;

      if (((bank_state == STATE_INGEST_FIRST) ||
           (bank_state == STATE_INGEST_ACCUM)) && children_chunk_complete) begin
        if (bank_state == STATE_INGEST_FIRST) begin
          completed_chunks <= 1;
          next_chunk_index <= 1;
        end else begin
          completed_chunks <= completed_chunks + 1'b1;
          next_chunk_index <= next_chunk_index + 1'b1;
        end
        words_accepted <= '0;
        chunk_done_seen_q[0] <= 1'b0;
        chunk_done_seen_q[1] <= 1'b0;
        chunk_done <= 1'b1;
        if (current_final_chunk_q) begin
          bank_state <= STATE_EMITTING;
          emit_enabled_q <= 1'b1;
          emit_segment_q <= 1'b0;
        end else begin
          bank_state <= STATE_READY;
        end
      end

      if (egress_fire && !resident_replicated && !emit_segment_q &&
          child_egress_last[0])
        emit_segment_q <= 1'b1;

      if (egress_fire &&
          ((resident_replicated && egress_last) ||
           (!resident_replicated && emit_segment_q &&
            child_egress_last[1]))) begin
        bank_state <= STATE_EMPTY;
        resident_word_count <= '0;
        resident_n_lane_mask <= '0;
        resident_context_tag <= '0;
        next_chunk_index <= '0;
        completed_chunks <= '0;
        words_accepted <= '0;
        current_final_chunk_q <= 1'b0;
        emit_enabled_q <= 1'b0;
        emit_segment_q <= 1'b0;
        emit_done <= 1'b1;
        context_error_q <= 1'b0;
        protocol_error_q <= 1'b0;
      end
    end
  end

  generate
    for (genvar segment = 0; segment < 2; segment++) begin : g_segment
      alexnet_n8_int32_partial_sum_bank #(
          .DEPTH(SEGMENT_DEPTH),
          .CONTEXT_TAG_W(CONTEXT_TAG_W),
          .CHUNK_INDEX_W(CHUNK_INDEX_W),
          .ADDR_W(SEGMENT_ADDR_W),
          .COUNT_W(SEGMENT_COUNT_W)
      ) u_bank (
          .clk(clk),
          .rst(rst),
          .descriptor_valid(child_descriptor_valid),
          .descriptor_ready(child_descriptor_ready[segment]),
          .descriptor_word_count(descriptor_segment_count[segment]),
          .descriptor_n_lane_mask(descriptor_n_lane_mask),
          .descriptor_context_tag(descriptor_context_tag),
          .descriptor_chunk_index(descriptor_chunk_index),
          .descriptor_first_chunk(descriptor_first_chunk),
          .descriptor_final_chunk(descriptor_final_chunk),
          .ingress_valid(child_ingress_valid[segment]),
          .ingress_ready(child_ingress_ready[segment]),
          .ingress_accumulator(ingress_accumulator),
          .ingress_n_lane_mask(ingress_n_lane_mask),
          .ingress_word_index(ingress_local_index),
          .ingress_last(ingress_local_last),
          .egress_valid(child_egress_valid[segment]),
          .egress_ready(child_egress_ready[segment]),
          .egress_accumulator(child_egress_accumulator[segment]),
          .egress_n_lane_mask(child_egress_n_lane_mask[segment]),
          .egress_word_index(child_egress_word_index[segment]),
          .egress_last(child_egress_last[segment]),
          .egress_context_tag(child_egress_context_tag[segment]),
          .bank_state(child_bank_state[segment]),
          .resident_valid(child_resident_valid[segment]),
          .resident_word_count(child_resident_word_count[segment]),
          .resident_n_lane_mask(child_resident_n_lane_mask[segment]),
          .resident_context_tag(child_resident_context_tag[segment]),
          .next_chunk_index(child_next_chunk_index[segment]),
          .completed_chunks(child_completed_chunks[segment]),
          .words_accepted(child_words_accepted[segment]),
          .chunk_done(child_chunk_done[segment]),
          .emit_done(child_emit_done[segment]),
          .context_error(child_context_error[segment]),
          .protocol_error(child_protocol_error[segment]),
          .idle(child_idle[segment])
      );
    end
  endgenerate

`ifndef SYNTHESIS
  initial begin
    if (SEGMENT_DEPTH != 512)
      $fatal(1, "partial-sum bank pair requires two measured 512-word banks");
  end

  always_ff @(posedge clk) begin
    if (!rst) begin
      if (descriptor_fire && (!child_descriptor_ready[0] ||
                              !child_descriptor_ready[1]))
        $fatal(1, "partial-sum bank pair descriptor was not atomic");
      if (ingress_fire && ingress_word_index >= resident_word_count)
        $fatal(1, "partial-sum bank pair ingress exceeded raster count");
      if (egress_fire && egress_word_index >= resident_word_count)
        $fatal(1, "partial-sum bank pair egress exceeded raster count");
      if (emit_enabled_q && !children_chunk_complete &&
          bank_state != STATE_EMITTING)
        $fatal(1, "partial-sum bank pair emitted before both chunks completed");
      if (child_emit_done[0] && !resident_replicated && !emit_segment_q)
        $fatal(1, "partial-sum bank pair lost segment switch");
      if (bank_state != STATE_EMITTING &&
          child_resident_valid[0] != child_resident_valid[1])
        $fatal(1, "partial-sum bank pair child ownership diverged");
      if (bank_state == STATE_READY && child_resident_valid[0] &&
          (child_resident_n_lane_mask[0] !=
               child_resident_n_lane_mask[1] ||
           child_resident_context_tag[0] !=
               child_resident_context_tag[1] ||
           child_next_chunk_index[0] != child_next_chunk_index[1]))
        $fatal(1, "partial-sum bank pair child context diverged");
    end
  end
`endif

endmodule
