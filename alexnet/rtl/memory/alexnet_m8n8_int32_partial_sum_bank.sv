`timescale 1ns/1ps

// One independently addressed N8 word lane. Eight instances form a physical
// M8 bank, allowing a complete 8x8 accumulator group to read or write per
// clock while preserving block-RAM inference.
module alexnet_m8n8_int32_bank_lane #(
    parameter int DEPTH = 512,
    parameter int ADDR_W = $clog2(DEPTH)
) (
    input logic clk,
    input logic write_enable,
    input logic [ADDR_W-1:0] write_addr,
    input logic [255:0] write_data,
    input logic read_enable,
    input logic [ADDR_W-1:0] read_addr,
    output logic [255:0] read_data
);

  (* ram_style = "block" *) logic [255:0] mem [0:DEPTH-1];
  logic [255:0] mem_read_q;

  always_ff @(posedge clk) begin
    if (write_enable)
      mem[write_addr] <= write_data;
    if (read_enable)
      mem_read_q <= mem[read_addr];
    // Keep a fabric register after the synchronous BRAM output. Besides
    // cutting the 256-bit route, this gives the placer a local destination
    // next to each independently placed M bank.
    read_data <= mem_read_q;
  end

endmodule

// Eight-way M-banked cross-channel accumulator. The public word count remains
// the logical number of M positions, while each physical address contains one
// complete M8xN8 group. Conv row tails are represented by ingress_m_count and
// consume one group address without creating invalid output words.
module alexnet_m8n8_int32_partial_sum_bank #(
    parameter int LOGICAL_DEPTH = 4096,
    parameter int GROUP_DEPTH = (LOGICAL_DEPTH + 7) / 8,
    parameter int CONTEXT_TAG_W = 16,
    parameter int CHUNK_INDEX_W = 8,
    parameter int LOGICAL_COUNT_W = $clog2(LOGICAL_DEPTH + 1),
    parameter int GROUP_ADDR_W = $clog2(GROUP_DEPTH),
    parameter int GROUP_COUNT_W = $clog2(GROUP_DEPTH + 1),
    parameter int M_COUNT_W = 4
) (
    input logic clk,
    input logic rst,

    input  logic descriptor_valid,
    output logic descriptor_ready,
    input  logic [LOGICAL_COUNT_W-1:0] descriptor_word_count,
    input  logic [7:0] descriptor_n_lane_mask,
    input  logic [CONTEXT_TAG_W-1:0] descriptor_context_tag,
    input  logic [CHUNK_INDEX_W-1:0] descriptor_chunk_index,
    input  logic descriptor_first_chunk,
    input  logic descriptor_final_chunk,

    input  logic ingress_valid,
    output logic ingress_ready,
    input  logic [M_COUNT_W-1:0] ingress_m_count,
    input  logic signed [31:0] ingress_accumulator [0:7][0:7],
    input  logic [7:0] ingress_n_lane_mask,
    input  logic [GROUP_ADDR_W-1:0] ingress_group_index,
    input  logic ingress_last,

    output logic egress_valid,
    input  logic egress_ready,
    output logic [M_COUNT_W-1:0] egress_m_count,
    output logic signed [31:0] egress_accumulator [0:7][0:7],
    output logic [7:0] egress_n_lane_mask,
    output logic [GROUP_ADDR_W-1:0] egress_group_index,
    output logic egress_last,
    output logic [CONTEXT_TAG_W-1:0] egress_context_tag,

    output logic [2:0] bank_state,
    output logic resident_valid,
    output logic [LOGICAL_COUNT_W-1:0] resident_word_count,
    output logic [GROUP_COUNT_W-1:0] resident_group_count,
    output logic [7:0] resident_n_lane_mask,
    output logic [CONTEXT_TAG_W-1:0] resident_context_tag,
    output logic [CHUNK_INDEX_W-1:0] next_chunk_index,
    output logic [CHUNK_INDEX_W:0] completed_chunks,
    output logic [LOGICAL_COUNT_W-1:0] words_accepted,
    output logic [GROUP_COUNT_W-1:0] groups_accepted,
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

  logic current_final_chunk_q;
  logic chunk_input_complete_q;
  logic [M_COUNT_W-1:0] group_m_count_mem [0:GROUP_DEPTH-1];

  logic rmw_pending_q;
  logic rmw_data_pending_q;
  logic [255:0] rmw_input_word_q [0:7];
  logic [GROUP_ADDR_W-1:0] rmw_index_q;
  logic rmw_last_q;
  logic [255:0] rmw_read_pipe_q [0:7];
  logic [255:0] rmw_input_pipe_q [0:7];
  logic [GROUP_ADDR_W-1:0] rmw_index_pipe_q;
  logic rmw_last_pipe_q;
  logic rmw_write_pending_q;

  logic [GROUP_COUNT_W-1:0] emit_reads_issued_q;
  logic emit_read_pending_q;
  logic emit_read_data_pending_q;
  logic [GROUP_ADDR_W-1:0] emit_pending_index_q;
  logic [M_COUNT_W-1:0] emit_pending_m_count_q;
  logic emit_pending_last_q;
  logic [255:0] egress_word_q [0:7];

  logic mem_write_enable;
  logic [GROUP_ADDR_W-1:0] mem_write_addr;
  logic [255:0] mem_write_data [0:7];
  logic mem_read_enable;
  logic [GROUP_ADDR_W-1:0] mem_read_addr;
  logic [255:0] mem_read_data [0:7];
  logic [255:0] packed_ingress_word [0:7];
  logic [255:0] rmw_sum_word [0:7];

  logic descriptor_fire;
  logic ingress_fire;
  logic egress_fire;
  logic first_descriptor_valid;
  logic continuation_match;
  logic ingress_metadata_match;
  logic expected_ingress_last;
  logic issue_emit_read;

  assign idle = bank_state == STATE_EMPTY;
  assign resident_valid = bank_state != STATE_EMPTY;

  assign first_descriptor_valid =
      (descriptor_word_count != 0) &&
      (descriptor_word_count <= LOGICAL_DEPTH) &&
      (descriptor_n_lane_mask != 0) &&
      ((descriptor_n_lane_mask & (descriptor_n_lane_mask + 1'b1)) == 0) &&
      descriptor_first_chunk && (descriptor_chunk_index == 0);

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
      words_accepted + ingress_m_count == resident_word_count;
  assign ingress_metadata_match =
      (ingress_m_count != 0) && (ingress_m_count <= 8) &&
      (ingress_group_index == groups_accepted[GROUP_ADDR_W-1:0]) &&
      (ingress_n_lane_mask == resident_n_lane_mask) &&
      (words_accepted + ingress_m_count <= resident_word_count) &&
      (ingress_last == expected_ingress_last);
  assign ingress_ready =
      ((bank_state == STATE_INGEST_FIRST) ||
       (bank_state == STATE_INGEST_ACCUM)) &&
      !chunk_input_complete_q && ingress_metadata_match &&
      ((bank_state == STATE_INGEST_FIRST) ||
       (!rmw_pending_q && !rmw_data_pending_q &&
        !rmw_write_pending_q));
  assign ingress_fire = ingress_valid && ingress_ready;

  assign egress_fire = egress_valid && egress_ready;
  assign issue_emit_read = (bank_state == STATE_EMITTING) &&
                           !emit_read_pending_q &&
                           !emit_read_data_pending_q &&
                           !egress_valid &&
                           (emit_reads_issued_q < resident_group_count);

  always_comb begin
    mem_write_enable = 1'b0;
    mem_write_addr = '0;
    mem_read_enable = 1'b0;
    mem_read_addr = '0;
    for (int m = 0; m < 8; m++) begin
      packed_ingress_word[m] = '0;
      rmw_sum_word[m] = '0;
      for (int n = 0; n < 8; n++) begin
        if ((M_COUNT_W'(m) < ingress_m_count) &&
            ingress_n_lane_mask[n])
          packed_ingress_word[m][n*32 +: 32] =
              ingress_accumulator[m][n];
        if (resident_n_lane_mask[n])
          rmw_sum_word[m][n*32 +: 32] =
              $signed(rmw_read_pipe_q[m][n*32 +: 32]) +
              $signed(rmw_input_pipe_q[m][n*32 +: 32]);
        egress_accumulator[m][n] =
            $signed(egress_word_q[m][n*32 +: 32]);
      end

      if ((bank_state == STATE_INGEST_FIRST) && ingress_fire)
        mem_write_data[m] = packed_ingress_word[m];
      else
        mem_write_data[m] = rmw_sum_word[m];
    end

    if ((bank_state == STATE_INGEST_FIRST) && ingress_fire) begin
      mem_write_enable = 1'b1;
      mem_write_addr = ingress_group_index;
    end else if ((bank_state == STATE_INGEST_ACCUM) &&
                 rmw_write_pending_q) begin
      mem_write_enable = 1'b1;
      mem_write_addr = rmw_index_pipe_q;
    end

    if ((bank_state == STATE_INGEST_ACCUM) && ingress_fire) begin
      mem_read_enable = 1'b1;
      mem_read_addr = ingress_group_index;
    end else if (issue_emit_read) begin
      mem_read_enable = 1'b1;
      mem_read_addr = emit_reads_issued_q[GROUP_ADDR_W-1:0];
    end
  end

  for (genvar m = 0; m < 8; m++) begin : g_m_bank
    alexnet_m8n8_int32_bank_lane #(
        .DEPTH(GROUP_DEPTH), .ADDR_W(GROUP_ADDR_W)
    ) u_lane (
        .clk(clk),
        .write_enable(mem_write_enable),
        .write_addr(mem_write_addr),
        .write_data(mem_write_data[m]),
        .read_enable(mem_read_enable),
        .read_addr(mem_read_addr),
        .read_data(mem_read_data[m])
    );
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      bank_state <= STATE_EMPTY;
      resident_word_count <= '0;
      resident_group_count <= '0;
      resident_n_lane_mask <= '0;
      resident_context_tag <= '0;
      next_chunk_index <= '0;
      completed_chunks <= '0;
      words_accepted <= '0;
      groups_accepted <= '0;
      current_final_chunk_q <= 1'b0;
      chunk_input_complete_q <= 1'b0;
      rmw_pending_q <= 1'b0;
      rmw_data_pending_q <= 1'b0;
      rmw_index_q <= '0;
      rmw_last_q <= 1'b0;
      rmw_index_pipe_q <= '0;
      rmw_last_pipe_q <= 1'b0;
      rmw_write_pending_q <= 1'b0;
      emit_reads_issued_q <= '0;
      emit_read_pending_q <= 1'b0;
      emit_read_data_pending_q <= 1'b0;
      emit_pending_index_q <= '0;
      emit_pending_m_count_q <= '0;
      emit_pending_last_q <= 1'b0;
      egress_valid <= 1'b0;
      egress_m_count <= '0;
      egress_n_lane_mask <= '0;
      egress_group_index <= '0;
      egress_last <= 1'b0;
      egress_context_tag <= '0;
      chunk_done <= 1'b0;
      emit_done <= 1'b0;
      context_error <= 1'b0;
      protocol_error <= 1'b0;
      for (int m = 0; m < 8; m++) begin
        rmw_input_word_q[m] <= '0;
        rmw_read_pipe_q[m] <= '0;
        rmw_input_pipe_q[m] <= '0;
        egress_word_q[m] <= '0;
      end
    end else begin
      chunk_done <= 1'b0;
      emit_done <= 1'b0;

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
        groups_accepted <= '0;
        current_final_chunk_q <= descriptor_final_chunk;
        chunk_input_complete_q <= 1'b0;
        rmw_pending_q <= 1'b0;
        rmw_data_pending_q <= 1'b0;
        rmw_write_pending_q <= 1'b0;
        if (bank_state == STATE_EMPTY) begin
          bank_state <= STATE_INGEST_FIRST;
          resident_word_count <= descriptor_word_count;
          resident_group_count <= '0;
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
        words_accepted <= words_accepted + ingress_m_count;
        groups_accepted <= groups_accepted + 1'b1;
        if (bank_state == STATE_INGEST_FIRST)
          group_m_count_mem[ingress_group_index] <= ingress_m_count;
        if (ingress_last)
          chunk_input_complete_q <= 1'b1;

        if (bank_state == STATE_INGEST_FIRST) begin
          if (ingress_last) begin
            resident_group_count <= groups_accepted + 1'b1;
            completed_chunks <= 1;
            next_chunk_index <= 1;
            chunk_done <= 1'b1;
            chunk_input_complete_q <= 1'b0;
            if (current_final_chunk_q) begin
              bank_state <= STATE_EMITTING;
              emit_reads_issued_q <= '0;
              emit_read_pending_q <= 1'b0;
              emit_read_data_pending_q <= 1'b0;
              egress_valid <= 1'b0;
            end else begin
              bank_state <= STATE_READY;
            end
          end
        end else begin
          for (int m = 0; m < 8; m++)
            rmw_input_word_q[m] <= packed_ingress_word[m];
          rmw_index_q <= ingress_group_index;
          rmw_last_q <= ingress_last;
          rmw_pending_q <= 1'b1;
        end
      end

      if ((bank_state == STATE_INGEST_ACCUM) && rmw_data_pending_q) begin
        for (int m = 0; m < 8; m++) begin
          rmw_read_pipe_q[m] <= mem_read_data[m];
          rmw_input_pipe_q[m] <= rmw_input_word_q[m];
        end
        rmw_index_pipe_q <= rmw_index_q;
        rmw_last_pipe_q <= rmw_last_q;
      end

      if (bank_state == STATE_INGEST_ACCUM) begin
        rmw_pending_q <= ingress_fire;
        rmw_data_pending_q <= rmw_pending_q;
        rmw_write_pending_q <= rmw_data_pending_q;
        if (rmw_write_pending_q && rmw_last_pipe_q) begin
          completed_chunks <= completed_chunks + 1'b1;
          next_chunk_index <= next_chunk_index + 1'b1;
          chunk_done <= 1'b1;
          chunk_input_complete_q <= 1'b0;
          if (current_final_chunk_q) begin
            bank_state <= STATE_EMITTING;
            emit_reads_issued_q <= '0;
            emit_read_pending_q <= 1'b0;
            emit_read_data_pending_q <= 1'b0;
            egress_valid <= 1'b0;
          end else begin
            bank_state <= STATE_READY;
          end
        end
      end

      emit_read_pending_q <= issue_emit_read;
      emit_read_data_pending_q <= emit_read_pending_q;
      if (issue_emit_read) begin
        emit_pending_index_q <=
            emit_reads_issued_q[GROUP_ADDR_W-1:0];
        emit_pending_m_count_q <=
            group_m_count_mem[emit_reads_issued_q[GROUP_ADDR_W-1:0]];
        emit_pending_last_q <=
            emit_reads_issued_q + 1'b1 == resident_group_count;
        emit_reads_issued_q <= emit_reads_issued_q + 1'b1;
      end

      if (emit_read_data_pending_q) begin
        egress_valid <= 1'b1;
        for (int m = 0; m < 8; m++)
          egress_word_q[m] <= mem_read_data[m];
        egress_m_count <= emit_pending_m_count_q;
        egress_n_lane_mask <= resident_n_lane_mask;
        egress_group_index <= emit_pending_index_q;
        egress_last <= emit_pending_last_q;
        egress_context_tag <= resident_context_tag;
      end

      if (egress_fire && egress_last) begin
        bank_state <= STATE_EMPTY;
        resident_word_count <= '0;
        resident_group_count <= '0;
        resident_n_lane_mask <= '0;
        resident_context_tag <= '0;
        next_chunk_index <= '0;
        completed_chunks <= '0;
        words_accepted <= '0;
        groups_accepted <= '0;
        current_final_chunk_q <= 1'b0;
        chunk_input_complete_q <= 1'b0;
        rmw_pending_q <= 1'b0;
        rmw_data_pending_q <= 1'b0;
        rmw_write_pending_q <= 1'b0;
        emit_reads_issued_q <= '0;
        emit_read_pending_q <= 1'b0;
        emit_read_data_pending_q <= 1'b0;
        emit_done <= 1'b1;
      end
    end
  end

`ifndef SYNTHESIS
  initial begin
    if (LOGICAL_DEPTH < 8 || GROUP_DEPTH < (LOGICAL_DEPTH + 7) / 8)
      $fatal(1, "M8 partial-sum bank depth is invalid");
  end

  always_ff @(posedge clk) begin
    if (!rst) begin
      if (ingress_fire && groups_accepted >= GROUP_DEPTH)
        $fatal(1, "M8 partial-sum group depth exceeded");
      if (ingress_fire && bank_state == STATE_INGEST_ACCUM &&
          ingress_m_count != group_m_count_mem[ingress_group_index])
        $fatal(1, "M8 partial-sum chunk changed its M-tail shape");
      if (egress_fire && egress_group_index >= resident_group_count)
        $fatal(1, "M8 partial-sum egress group index exceeded count");
    end
  end
`endif

endmodule
