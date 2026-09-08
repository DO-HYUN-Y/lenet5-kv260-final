`timescale 1ns/1ps

// One 512-word physical partial-sum bank for eight signed INT32 N lanes.
//
//   EMPTY -> INGEST_FIRST -> READY -> INGEST_ACCUM -> READY ...
//         -> EMITTING -> EMPTY
//
// The first input-channel chunk replaces each word. Later chunks perform a
// BRAM read-add-write at signed INT32 precision. Only a descriptor marked as
// the final chunk makes the accumulated raster visible to requantization.
module alexnet_n8_int32_partial_sum_bank #(
    parameter int DEPTH = 512,
    parameter int CONTEXT_TAG_W = 16,
    parameter int CHUNK_INDEX_W = 8,
    parameter int ADDR_W = $clog2(DEPTH),
    parameter int COUNT_W = $clog2(DEPTH + 1)
) (
    input logic clk,
    input logic rst,

    input  logic descriptor_valid,
    output logic descriptor_ready,
    input  logic [COUNT_W-1:0] descriptor_word_count,
    input  logic [7:0] descriptor_n_lane_mask,
    input  logic [CONTEXT_TAG_W-1:0] descriptor_context_tag,
    input  logic [CHUNK_INDEX_W-1:0] descriptor_chunk_index,
    input  logic descriptor_first_chunk,
    input  logic descriptor_final_chunk,

    input  logic ingress_valid,
    output logic ingress_ready,
    input  logic signed [31:0] ingress_accumulator [0:7],
    input  logic [7:0] ingress_n_lane_mask,
    input  logic [ADDR_W-1:0] ingress_word_index,
    input  logic ingress_last,

    output logic egress_valid,
    input  logic egress_ready,
    output logic signed [31:0] egress_accumulator [0:7],
    output logic [7:0] egress_n_lane_mask,
    output logic [ADDR_W-1:0] egress_word_index,
    output logic egress_last,
    output logic [CONTEXT_TAG_W-1:0] egress_context_tag,

    output logic [2:0] bank_state,
    output logic resident_valid,
    output logic [COUNT_W-1:0] resident_word_count,
    output logic [7:0] resident_n_lane_mask,
    output logic [CONTEXT_TAG_W-1:0] resident_context_tag,
    output logic [CHUNK_INDEX_W-1:0] next_chunk_index,
    output logic [CHUNK_INDEX_W:0] completed_chunks,
    output logic [COUNT_W-1:0] words_accepted,
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

  (* ram_style = "block" *) logic [255:0] mem [0:DEPTH-1];

  logic current_final_chunk_q;
  logic chunk_input_complete_q;

  logic rmw_pending_q;
  logic [255:0] mem_read_q;
  logic [255:0] rmw_input_word_q;
  logic [ADDR_W-1:0] rmw_index_q;
  logic rmw_last_q;
  // Keep one explicit register boundary between the cascaded BRAM output and
  // the eight INT32 adders. Without it, a full KV260 placement has a
  // BRAM-cascade -> carry-chain -> BRAM path in one 5 ns cycle.
  (* keep = "true" *) logic [255:0] rmw_read_pipe_q;
  logic [255:0] rmw_input_pipe_q;
  logic [ADDR_W-1:0] rmw_index_pipe_q;
  logic rmw_last_pipe_q;
  logic rmw_write_pending_q;
  logic [255:0] rmw_sum_word;

  logic [COUNT_W-1:0] emit_reads_issued_q;
  logic emit_read_pending_q;
  logic [ADDR_W-1:0] emit_pending_index_q;
  logic emit_pending_last_q;
  logic [255:0] egress_word_q;

  logic mem_write_enable;
  logic [ADDR_W-1:0] mem_write_addr;
  logic [255:0] mem_write_data;
  logic mem_read_enable;
  logic [ADDR_W-1:0] mem_read_addr;

  logic descriptor_fire;
  logic ingress_fire;
  logic egress_fire;
  logic first_descriptor_valid;
  logic continuation_match;
  logic ingress_metadata_match;
  logic expected_ingress_last;
  logic [255:0] packed_ingress_word;
  logic egress_slot_ready;
  logic emit_read_stage_ready;
  logic issue_emit_read;

  assign idle = bank_state == STATE_EMPTY;
  assign resident_valid = bank_state != STATE_EMPTY;

  assign first_descriptor_valid =
      (descriptor_word_count != 0) &&
      (descriptor_word_count <= DEPTH) &&
      (descriptor_n_lane_mask != 0) &&
      ((descriptor_n_lane_mask & (descriptor_n_lane_mask + 1'b1)) == 0) &&
      descriptor_first_chunk &&
      (descriptor_chunk_index == 0);

  assign continuation_match =
      !descriptor_first_chunk &&
      (descriptor_word_count == resident_word_count) &&
      (descriptor_n_lane_mask == resident_n_lane_mask) &&
      (descriptor_context_tag == resident_context_tag) &&
      (descriptor_chunk_index == next_chunk_index);

  always_comb begin
    descriptor_ready = 1'b0;
    if (bank_state == STATE_EMPTY)
      descriptor_ready = first_descriptor_valid;
    else if (bank_state == STATE_READY)
      descriptor_ready = continuation_match;
  end

  assign descriptor_fire = descriptor_valid && descriptor_ready;

  assign expected_ingress_last =
      words_accepted + 1'b1 == resident_word_count;
  assign ingress_metadata_match =
      (ingress_word_index == words_accepted[ADDR_W-1:0]) &&
      (ingress_n_lane_mask == resident_n_lane_mask) &&
      (ingress_last == expected_ingress_last);
  assign ingress_ready =
      ((bank_state == STATE_INGEST_FIRST) ||
       (bank_state == STATE_INGEST_ACCUM)) &&
      !chunk_input_complete_q && ingress_metadata_match;
  assign ingress_fire = ingress_valid && ingress_ready;

  assign egress_fire = egress_valid && egress_ready;
  assign egress_slot_ready = !egress_valid || egress_ready;
  assign emit_read_stage_ready = !emit_read_pending_q || egress_slot_ready;
  assign issue_emit_read = (bank_state == STATE_EMITTING) &&
                           emit_read_stage_ready &&
                           (emit_reads_issued_q < resident_word_count);

  // Express the payload as exactly one write port and one synchronous read
  // port so the 512x256 storage can infer RAMB36E2 primitives.
  always_comb begin
    mem_write_enable = 1'b0;
    mem_write_addr = '0;
    mem_write_data = '0;
    if ((bank_state == STATE_INGEST_FIRST) && ingress_fire) begin
      mem_write_enable = 1'b1;
      mem_write_addr = ingress_word_index;
      mem_write_data = packed_ingress_word;
    end else if ((bank_state == STATE_INGEST_ACCUM) &&
                 rmw_write_pending_q) begin
      mem_write_enable = 1'b1;
      mem_write_addr = rmw_index_pipe_q;
      mem_write_data = rmw_sum_word;
    end
  end

  always_comb begin
    mem_read_enable = 1'b0;
    mem_read_addr = '0;
    if ((bank_state == STATE_INGEST_ACCUM) && ingress_fire) begin
      mem_read_enable = 1'b1;
      mem_read_addr = ingress_word_index;
    end else if (issue_emit_read) begin
      mem_read_enable = 1'b1;
      mem_read_addr = emit_reads_issued_q[ADDR_W-1:0];
    end
  end

  always_comb begin
    packed_ingress_word = '0;
    rmw_sum_word = '0;
    for (int lane = 0; lane < 8; lane++) begin
      if (resident_n_lane_mask[lane]) begin
        packed_ingress_word[lane*32 +: 32] = ingress_accumulator[lane];
        rmw_sum_word[lane*32 +: 32] =
            $signed(rmw_read_pipe_q[lane*32 +: 32]) +
            $signed(rmw_input_pipe_q[lane*32 +: 32]);
      end
      egress_accumulator[lane] =
          $signed(egress_word_q[lane*32 +: 32]);
    end
  end

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
      chunk_input_complete_q <= 1'b0;
      rmw_pending_q <= 1'b0;
      mem_read_q <= '0;
      rmw_input_word_q <= '0;
      rmw_index_q <= '0;
      rmw_last_q <= 1'b0;
      rmw_read_pipe_q <= '0;
      rmw_input_pipe_q <= '0;
      rmw_index_pipe_q <= '0;
      rmw_last_pipe_q <= 1'b0;
      rmw_write_pending_q <= 1'b0;
      emit_reads_issued_q <= '0;
      emit_read_pending_q <= 1'b0;
      emit_pending_index_q <= '0;
      emit_pending_last_q <= 1'b0;
      egress_valid <= 1'b0;
      egress_word_q <= '0;
      egress_n_lane_mask <= '0;
      egress_word_index <= '0;
      egress_last <= 1'b0;
      egress_context_tag <= '0;
      chunk_done <= 1'b0;
      emit_done <= 1'b0;
      context_error <= 1'b0;
      protocol_error <= 1'b0;
    end else begin
      chunk_done <= 1'b0;
      emit_done <= 1'b0;

      if (mem_write_enable)
        mem[mem_write_addr] <= mem_write_data;
      if (mem_read_enable)
        mem_read_q <= mem[mem_read_addr];

      if (egress_fire)
        egress_valid <= 1'b0;

      if (descriptor_valid && !descriptor_ready) begin
        if (bank_state == STATE_READY)
          context_error <= 1'b1;
        else if (bank_state == STATE_EMPTY)
          protocol_error <= 1'b1;
      end

      if (descriptor_fire) begin
        words_accepted <= '0;
        current_final_chunk_q <= descriptor_final_chunk;
        chunk_input_complete_q <= 1'b0;
        rmw_pending_q <= 1'b0;
        rmw_write_pending_q <= 1'b0;

        if (bank_state == STATE_EMPTY) begin
          bank_state <= STATE_INGEST_FIRST;
          resident_word_count <= descriptor_word_count;
          resident_n_lane_mask <= descriptor_n_lane_mask;
          resident_context_tag <= descriptor_context_tag;
          next_chunk_index <= 1;
          completed_chunks <= '0;
          context_error <= 1'b0;
          protocol_error <= 1'b0;
        end else begin
          bank_state <= STATE_INGEST_ACCUM;
        end
      end

      if (ingress_valid &&
          ((bank_state == STATE_INGEST_FIRST) ||
           (bank_state == STATE_INGEST_ACCUM)) &&
          !chunk_input_complete_q && !ingress_metadata_match)
        protocol_error <= 1'b1;

      if (ingress_fire) begin
        words_accepted <= words_accepted + 1'b1;
        if (ingress_last)
          chunk_input_complete_q <= 1'b1;

        if (bank_state == STATE_INGEST_FIRST) begin
          if (ingress_last) begin
            completed_chunks <= 1;
            next_chunk_index <= 1;
            chunk_done <= 1'b1;
            chunk_input_complete_q <= 1'b0;
            if (current_final_chunk_q) begin
              bank_state <= STATE_EMITTING;
              emit_reads_issued_q <= '0;
              emit_read_pending_q <= 1'b0;
              egress_valid <= 1'b0;
            end else begin
              bank_state <= STATE_READY;
            end
          end
        end else begin
          rmw_input_word_q <= packed_ingress_word;
          rmw_index_q <= ingress_word_index;
          rmw_last_q <= ingress_last;
          rmw_pending_q <= 1'b1;
        end
      end

      if ((bank_state == STATE_INGEST_ACCUM) && rmw_pending_q) begin
        rmw_read_pipe_q <= mem_read_q;
        rmw_input_pipe_q <= rmw_input_word_q;
        rmw_index_pipe_q <= rmw_index_q;
        rmw_last_pipe_q <= rmw_last_q;
      end

      if (bank_state == STATE_INGEST_ACCUM) begin
        // Reads, the explicit timing register, and writes can all advance on
        // the same cycle, preserving one accumulated word per clock.
        rmw_pending_q <= ingress_fire;
        rmw_write_pending_q <= rmw_pending_q;
        if (rmw_write_pending_q && rmw_last_pipe_q) begin
          completed_chunks <= completed_chunks + 1'b1;
          next_chunk_index <= next_chunk_index + 1'b1;
          chunk_done <= 1'b1;
          chunk_input_complete_q <= 1'b0;
          if (current_final_chunk_q) begin
            bank_state <= STATE_EMITTING;
            emit_reads_issued_q <= '0;
            emit_read_pending_q <= 1'b0;
            egress_valid <= 1'b0;
          end else begin
            bank_state <= STATE_READY;
          end
        end
      end

      if (emit_read_stage_ready) begin
        if (emit_read_pending_q) begin
          egress_valid <= 1'b1;
          egress_word_q <= mem_read_q;
          egress_n_lane_mask <= resident_n_lane_mask;
          egress_word_index <= emit_pending_index_q;
          egress_last <= emit_pending_last_q;
          egress_context_tag <= resident_context_tag;
        end

        emit_read_pending_q <= issue_emit_read;
        if (issue_emit_read) begin
          emit_pending_index_q <= emit_reads_issued_q[ADDR_W-1:0];
          emit_pending_last_q <=
              emit_reads_issued_q + 1'b1 == resident_word_count;
          emit_reads_issued_q <= emit_reads_issued_q + 1'b1;
        end
      end

      if (egress_fire && egress_last) begin
        bank_state <= STATE_EMPTY;
        resident_word_count <= '0;
        resident_n_lane_mask <= '0;
        resident_context_tag <= '0;
        next_chunk_index <= '0;
        completed_chunks <= '0;
        words_accepted <= '0;
        current_final_chunk_q <= 1'b0;
        chunk_input_complete_q <= 1'b0;
        rmw_pending_q <= 1'b0;
        rmw_write_pending_q <= 1'b0;
        emit_reads_issued_q <= '0;
        emit_read_pending_q <= 1'b0;
        emit_done <= 1'b1;
      end
    end
  end

`ifndef SYNTHESIS
  initial begin
    if (DEPTH < 2 || (1 << ADDR_W) < DEPTH ||
        (1 << COUNT_W) <= DEPTH)
      $fatal(1, "partial-sum bank parameterization is invalid");
  end

  always_ff @(posedge clk) begin
    if (!rst) begin
      if (descriptor_fire && descriptor_n_lane_mask !=
          (8'hff >> (8 - $countones(descriptor_n_lane_mask))))
        $fatal(1, "partial-sum bank N mask must be a low-lane tail");
      if (ingress_fire && ingress_word_index >= resident_word_count)
        $fatal(1, "partial-sum bank ingress index exceeded word count");
      if (egress_fire && egress_word_index >= resident_word_count)
        $fatal(1, "partial-sum bank egress index exceeded word count");
      if (egress_valid && !egress_ready && emit_done)
        $fatal(1, "partial-sum bank emitted done while output stalled");
    end
  end
`endif

endmodule
