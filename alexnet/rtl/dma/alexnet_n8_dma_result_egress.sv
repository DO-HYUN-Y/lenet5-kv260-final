`timescale 1ns/1ps

// Ordered 64-bit N8 result packets to one 128-bit AXI4-Stream S2MM payload.
//
// A registered descriptor fixes the transfer length and static router
// metadata. Two consecutive N8 values are packed low-word first into each
// AXIS beat. Metadata mismatches latch a sticky error, but the descriptor-
// counted transfer still drains so software can recover without wedging the
// result router.
module alexnet_n8_dma_result_egress #(
    parameter int M_GROUP = 4,
    parameter int AXIS_W = 128,
    parameter int AXIS_BYTES = AXIS_W / 8,
    parameter int COUNT_W = 11,
    parameter int BYTE_COUNT_W = 16,
    parameter int N_BASE_W = 16,
    parameter int TILE_TAG_W = 16,
    parameter int MAX_WORDS = 1024
) (
    input logic clk,
    input logic rst,
    input logic clear_error,

    input  logic descriptor_valid,
    output logic descriptor_ready,
    input  logic [COUNT_W-1:0] descriptor_word_count,
    input  logic [BYTE_COUNT_W-1:0] descriptor_byte_count,
    input  logic [1:0] descriptor_destination,
    input  logic [2:0] descriptor_slice,
    input  logic [N_BASE_W-1:0] descriptor_n_base,
    input  logic [7:0] descriptor_lane_mask,
    input  logic [TILE_TAG_W-1:0] descriptor_first_tile_tag,

    input  logic packet_valid,
    output logic packet_ready,
    input  logic [63:0] packet_values,
    input  logic [7:0] packet_lane_mask,
    input  logic [1:0] packet_destination,
    input  logic [2:0] packet_slice,
    input  logic [4:0] packet_m,
    input  logic [N_BASE_W-1:0] packet_n_base,
    input  logic [TILE_TAG_W-1:0] packet_tile_tag,

    output logic [AXIS_W-1:0] m_axis_tdata,
    output logic [AXIS_BYTES-1:0] m_axis_tkeep,
    output logic m_axis_tvalid,
    input  logic m_axis_tready,
    output logic m_axis_tlast,

    output logic busy,
    output logic transfer_active,
    output logic transfer_done,
    output logic descriptor_rejected,
    output logic descriptor_error,
    output logic metadata_error,
    output logic protocol_error,
    output logic [1:0] active_destination,
    output logic [2:0] active_slice,
    output logic [N_BASE_W-1:0] active_n_base,
    output logic [7:0] active_lane_mask,
    output logic [TILE_TAG_W-1:0] active_first_tile_tag,
    output logic [COUNT_W-1:0] words_accepted,
    output logic [COUNT_W-1:0] words_transferred,
    output logic [COUNT_W-1:0] beats_transferred,
    output logic [15:0] completed_transfers,
    output logic [TILE_TAG_W-1:0] completed_first_tile_tag,
    output logic [TILE_TAG_W-1:0] completed_last_tile_tag
);

  logic command_pending_q;
  logic [COUNT_W-1:0] command_word_count_q;
  logic [BYTE_COUNT_W-1:0] command_byte_count_q;
  logic [1:0] command_destination_q;
  logic [2:0] command_slice_q;
  logic [N_BASE_W-1:0] command_n_base_q;
  logic [7:0] command_lane_mask_q;
  logic [TILE_TAG_W-1:0] command_first_tile_tag_q;

  logic transfer_active_q;
  logic [COUNT_W-1:0] active_word_count_q;
  logic [1:0] active_destination_q;
  logic [2:0] active_slice_q;
  logic [N_BASE_W-1:0] active_n_base_q;
  logic [7:0] active_lane_mask_q;
  logic [TILE_TAG_W-1:0] active_first_tile_tag_q;
  logic [COUNT_W-1:0] words_accepted_q;
  logic [COUNT_W-1:0] words_transferred_q;
  logic [COUNT_W-1:0] beats_transferred_q;

  logic [1:0] buffer_count_q;
  logic [63:0] low_word_q;
  logic [63:0] high_word_q;
  logic low_word_last_q;
  logic high_word_last_q;

  logic previous_packet_valid_q;
  logic [4:0] previous_packet_m_q;
  logic [TILE_TAG_W-1:0] previous_packet_tile_tag_q;

  logic descriptor_fire;
  logic command_count_valid;
  logic command_byte_count_valid;
  logic command_destination_valid;
  logic command_n_base_valid;
  logic command_lane_mask_valid;
  logic command_fields_valid;
  logic command_commit;
  logic command_reject;
  logic [BYTE_COUNT_W-1:0] expected_byte_count;

  logic packet_fire;
  logic packet_is_last;
  logic packet_static_metadata_valid;
  logic packet_order_metadata_valid;
  logic packet_masked_values_valid;
  logic packet_metadata_valid;
  logic [63:0] masked_packet_values;
  logic axis_fire;
  logic [1:0] axis_word_count;

  function automatic logic contiguous_lane_mask(input logic [7:0] mask);
    begin
      case (mask)
        8'h01, 8'h03, 8'h07, 8'h0f,
        8'h1f, 8'h3f, 8'h7f, 8'hff:
          contiguous_lane_mask = 1'b1;
        default:
          contiguous_lane_mask = 1'b0;
      endcase
    end
  endfunction

  function automatic logic [63:0] apply_lane_mask(
      input logic [63:0] values,
      input logic [7:0] mask);
    logic [63:0] result;
    begin
      result = '0;
      for (int lane = 0; lane < 8; lane++) begin
        if (mask[lane])
          result[lane*8 +: 8] = values[lane*8 +: 8];
      end
      apply_lane_mask = result;
    end
  endfunction

  assign descriptor_ready = !command_pending_q && !transfer_active_q &&
                            buffer_count_q == 0;
  assign descriptor_fire = descriptor_valid && descriptor_ready;
  assign command_count_valid = command_word_count_q != 0 &&
                               command_word_count_q <= COUNT_W'(MAX_WORDS);
  assign expected_byte_count =
      BYTE_COUNT_W'(command_word_count_q) << 3;
  assign command_byte_count_valid =
      command_byte_count_q == expected_byte_count &&
      command_byte_count_q[2:0] == 3'b000;
  assign command_destination_valid = command_destination_q <= 2'd2;
  assign command_n_base_valid = command_n_base_q[2:0] == 3'b000;
  assign command_lane_mask_valid =
      contiguous_lane_mask(command_lane_mask_q);
  assign command_fields_valid = command_count_valid &&
                                command_byte_count_valid &&
                                command_destination_valid &&
                                command_n_base_valid &&
                                command_lane_mask_valid;
  assign command_commit = command_pending_q && command_fields_valid;
  assign command_reject = command_pending_q && !command_fields_valid;

  assign m_axis_tdata = {
      (buffer_count_q == 2 ? high_word_q : 64'b0), low_word_q};
  assign m_axis_tkeep = buffer_count_q == 2 ?
                        {AXIS_BYTES{1'b1}} : 16'h00ff;
  assign m_axis_tlast = buffer_count_q == 2 ? high_word_last_q :
                                                    low_word_last_q;
  assign m_axis_tvalid = transfer_active_q &&
                         (buffer_count_q == 2 ||
                          (buffer_count_q == 1 && low_word_last_q));
  assign axis_fire = m_axis_tvalid && m_axis_tready;
  assign axis_word_count = buffer_count_q;

  // A full non-final beat can pop while the next packet enters the low-word
  // register, avoiding an avoidable source bubble at the packer boundary.
  assign packet_ready = transfer_active_q &&
                        words_accepted_q < active_word_count_q &&
                        (buffer_count_q < 2 || axis_fire);
  assign packet_fire = packet_valid && packet_ready;
  assign packet_is_last =
      words_accepted_q + 1'b1 == active_word_count_q;

  assign packet_static_metadata_valid =
      packet_destination == active_destination_q &&
      packet_slice == active_slice_q &&
      packet_n_base == active_n_base_q &&
      packet_lane_mask == active_lane_mask_q;
  assign packet_order_metadata_valid =
      !previous_packet_valid_q ?
          (packet_m == 0 &&
           packet_tile_tag == active_first_tile_tag_q) :
          ((packet_tile_tag == previous_packet_tile_tag_q &&
            previous_packet_m_q < M_GROUP - 1 &&
            packet_m == previous_packet_m_q + 1'b1) ||
           (packet_tile_tag == previous_packet_tile_tag_q + 1'b1 &&
            packet_m == 0));
  assign masked_packet_values =
      apply_lane_mask(packet_values, active_lane_mask_q);
  assign packet_masked_values_valid =
      masked_packet_values == packet_values;
  assign packet_metadata_valid = packet_static_metadata_valid &&
                                 packet_order_metadata_valid &&
                                 packet_masked_values_valid;

  assign busy = command_pending_q || transfer_active_q || buffer_count_q != 0;
  assign transfer_active = transfer_active_q;
  assign protocol_error = descriptor_error || metadata_error;
  assign active_destination = active_destination_q;
  assign active_slice = active_slice_q;
  assign active_n_base = active_n_base_q;
  assign active_lane_mask = active_lane_mask_q;
  assign active_first_tile_tag = active_first_tile_tag_q;
  assign words_accepted = words_accepted_q;
  assign words_transferred = words_transferred_q;
  assign beats_transferred = beats_transferred_q;

  always_ff @(posedge clk) begin
    if (rst) begin
      command_pending_q <= 1'b0;
      command_word_count_q <= '0;
      command_byte_count_q <= '0;
      command_destination_q <= '0;
      command_slice_q <= '0;
      command_n_base_q <= '0;
      command_lane_mask_q <= '0;
      command_first_tile_tag_q <= '0;
      transfer_active_q <= 1'b0;
      active_word_count_q <= '0;
      active_destination_q <= '0;
      active_slice_q <= '0;
      active_n_base_q <= '0;
      active_lane_mask_q <= '0;
      active_first_tile_tag_q <= '0;
      words_accepted_q <= '0;
      words_transferred_q <= '0;
      beats_transferred_q <= '0;
      buffer_count_q <= '0;
      low_word_q <= '0;
      high_word_q <= '0;
      low_word_last_q <= 1'b0;
      high_word_last_q <= 1'b0;
      previous_packet_valid_q <= 1'b0;
      previous_packet_m_q <= '0;
      previous_packet_tile_tag_q <= '0;
      transfer_done <= 1'b0;
      descriptor_rejected <= 1'b0;
      descriptor_error <= 1'b0;
      metadata_error <= 1'b0;
      completed_transfers <= '0;
      completed_first_tile_tag <= '0;
      completed_last_tile_tag <= '0;
    end else begin
      transfer_done <= 1'b0;
      descriptor_rejected <= 1'b0;

      if (clear_error) begin
        descriptor_error <= 1'b0;
        metadata_error <= 1'b0;
      end

      if (descriptor_fire) begin
        command_pending_q <= 1'b1;
        command_word_count_q <= descriptor_word_count;
        command_byte_count_q <= descriptor_byte_count;
        command_destination_q <= descriptor_destination;
        command_slice_q <= descriptor_slice;
        command_n_base_q <= descriptor_n_base;
        command_lane_mask_q <= descriptor_lane_mask;
        command_first_tile_tag_q <= descriptor_first_tile_tag;
      end

      if (command_reject) begin
        command_pending_q <= 1'b0;
        descriptor_rejected <= 1'b1;
        descriptor_error <= 1'b1;
      end

      if (command_commit) begin
        command_pending_q <= 1'b0;
        transfer_active_q <= 1'b1;
        active_word_count_q <= command_word_count_q;
        active_destination_q <= command_destination_q;
        active_slice_q <= command_slice_q;
        active_n_base_q <= command_n_base_q;
        active_lane_mask_q <= command_lane_mask_q;
        active_first_tile_tag_q <= command_first_tile_tag_q;
        words_accepted_q <= '0;
        words_transferred_q <= '0;
        beats_transferred_q <= '0;
        buffer_count_q <= '0;
        low_word_q <= '0;
        high_word_q <= '0;
        low_word_last_q <= 1'b0;
        high_word_last_q <= 1'b0;
        previous_packet_valid_q <= 1'b0;
        previous_packet_m_q <= '0;
        previous_packet_tile_tag_q <= '0;
      end

      if (axis_fire) begin
        words_transferred_q <= words_transferred_q + axis_word_count;
        beats_transferred_q <= beats_transferred_q + 1'b1;
        if (!packet_fire) begin
          buffer_count_q <= '0;
          low_word_q <= '0;
          high_word_q <= '0;
          low_word_last_q <= 1'b0;
          high_word_last_q <= 1'b0;
        end
        if (m_axis_tlast) begin
          transfer_active_q <= 1'b0;
          transfer_done <= 1'b1;
          completed_transfers <= completed_transfers + 1'b1;
          completed_first_tile_tag <= active_first_tile_tag_q;
          completed_last_tile_tag <= previous_packet_tile_tag_q;
        end
      end

      if (packet_fire) begin
        words_accepted_q <= words_accepted_q + 1'b1;
        previous_packet_valid_q <= 1'b1;
        previous_packet_m_q <= packet_m;
        previous_packet_tile_tag_q <= packet_tile_tag;
        if (!packet_metadata_valid)
          metadata_error <= 1'b1;

        if (axis_fire || buffer_count_q == 0) begin
          low_word_q <= masked_packet_values;
          high_word_q <= '0;
          low_word_last_q <= packet_is_last;
          high_word_last_q <= 1'b0;
          buffer_count_q <= 1;
        end else begin
          high_word_q <= masked_packet_values;
          high_word_last_q <= packet_is_last;
          buffer_count_q <= 2;
        end
      end
    end
  end

`ifndef SYNTHESIS
  initial begin
    if (AXIS_W != 128 || AXIS_BYTES != 16)
      $fatal(1, "AlexNet N8 DMA result egress requires 128-bit AXIS");
    if (MAX_WORDS > (1 << COUNT_W) - 1)
      $fatal(1, "AlexNet N8 DMA result count width is too small");
    if (M_GROUP != 4 && M_GROUP != 8)
      $fatal(1, "AlexNet N8 DMA result egress supports M4 or M8 order");
  end

  always_ff @(posedge clk) begin
    if (!rst) begin
      if (descriptor_rejected &&
          (transfer_active_q || packet_ready || m_axis_tvalid))
        $fatal(1, "rejected DMA result descriptor consumed payload");
      if (buffer_count_q > 2)
        $fatal(1, "DMA result packer buffer count overflow");
      if (words_accepted_q > active_word_count_q ||
          words_transferred_q > active_word_count_q)
        $fatal(1, "DMA result word counter overflow");
      if (m_axis_tvalid && !transfer_active_q)
        $fatal(1, "DMA result AXIS payload exists outside a transfer");
      if (transfer_done &&
          words_transferred_q != active_word_count_q)
        $fatal(1, "DMA result transfer completed before every word drained");
    end
  end
`endif

endmodule
