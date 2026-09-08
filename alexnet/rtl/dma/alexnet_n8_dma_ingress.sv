`timescale 1ns/1ps

// 128-bit AXI4-Stream MM2S payload to one 64-bit N8 storage owner.
//
// A descriptor is captured before any destination owner is committed. Invalid
// descriptors are rejected locally. A valid descriptor waits for the selected
// activation or weight fill port, then exactly one owner is committed and the
// AXIS payload is unpacked low-word first into 64-bit N8 words.
module alexnet_n8_dma_ingress #(
    parameter int AXIS_W = 128,
    parameter int AXIS_BYTES = AXIS_W / 8,
    parameter int COUNT_W = 11,
    parameter int ACTIVATION_COUNT_W = 11,
    parameter int WEIGHT_COUNT_W = 10,
    parameter int BYTE_COUNT_W = 16,
    parameter int TAG_W = 16,
    parameter int ACTIVATION_MAX_WORDS = 1024,
    parameter int WEIGHT_MAX_WORDS = 968
) (
    input logic clk,
    input logic rst,
    input logic clear_error,

    input  logic descriptor_valid,
    output logic descriptor_ready,
    input  logic [1:0] descriptor_destination,
    input  logic [COUNT_W-1:0] descriptor_word_count,
    input  logic [BYTE_COUNT_W-1:0] descriptor_byte_count,
    input  logic [7:0] descriptor_lane_mask,
    input  logic [TAG_W-1:0] descriptor_tag,

    input  logic [AXIS_W-1:0] s_axis_tdata,
    input  logic [AXIS_BYTES-1:0] s_axis_tkeep,
    input  logic s_axis_tvalid,
    output logic s_axis_tready,
    input  logic s_axis_tlast,

    output logic activation_fill_valid,
    input  logic activation_fill_ready,
    output logic activation_fill_is_pooled,
    output logic [ACTIVATION_COUNT_W-1:0] activation_fill_word_count,
    output logic [7:0] activation_fill_lane_mask,
    output logic [TAG_W-1:0] activation_fill_tensor_tag,
    output logic activation_direct_valid,
    input  logic activation_direct_ready,
    output logic [63:0] activation_direct_values,
    output logic [7:0] activation_direct_lane_mask,
    output logic activation_direct_last,
    output logic activation_pooled_valid,
    input  logic activation_pooled_ready,
    output logic [63:0] activation_pooled_values,
    output logic [7:0] activation_pooled_lane_mask,
    output logic activation_pooled_last,

    output logic weight_fill_valid,
    input  logic weight_fill_ready,
    output logic [WEIGHT_COUNT_W-1:0] weight_fill_k_count,
    output logic [7:0] weight_fill_n_lane_mask,
    output logic [TAG_W-1:0] weight_fill_context_tag,
    output logic weight_write_valid,
    input  logic weight_write_ready,
    output logic [63:0] weight_write_values,
    output logic [7:0] weight_write_n_lane_mask,
    output logic weight_write_last,

    output logic busy,
    output logic transfer_active,
    output logic transfer_done,
    output logic descriptor_rejected,
    output logic descriptor_error,
    output logic stream_error,
    output logic protocol_error,
    output logic [1:0] active_destination,
    output logic [COUNT_W-1:0] words_transferred,
    output logic [15:0] completed_transfers
);

  localparam logic [1:0] DEST_ACTIVATION_DIRECT = 2'd0;
  localparam logic [1:0] DEST_ACTIVATION_POOLED = 2'd1;
  localparam logic [1:0] DEST_WEIGHT = 2'd2;

  logic command_pending_q;
  logic [1:0] command_destination_q;
  logic [COUNT_W-1:0] command_word_count_q;
  logic [BYTE_COUNT_W-1:0] command_byte_count_q;
  logic [7:0] command_lane_mask_q;
  logic [TAG_W-1:0] command_tag_q;

  logic transfer_active_q;
  logic [1:0] active_destination_q;
  logic [COUNT_W-1:0] active_word_count_q;
  logic [7:0] active_lane_mask_q;
  logic [COUNT_W-1:0] words_received_q;
  logic [COUNT_W-1:0] words_transferred_q;

  logic beat_buffer_valid_q;
  logic [AXIS_W-1:0] beat_buffer_q;
  logic [1:0] beat_word_count_q;
  logic beat_word_select_q;

  logic descriptor_fire;
  logic command_destination_valid;
  logic command_is_activation;
  logic command_count_valid;
  logic command_byte_count_valid;
  logic command_lane_mask_valid;
  logic command_fields_valid;
  logic command_target_ready;
  logic command_commit;
  logic command_reject;
  logic axis_fire;
  logic payload_valid;
  logic payload_ready;
  logic payload_fire;
  logic payload_last;
  logic [63:0] payload_values;
  logic [COUNT_W-1:0] remaining_receive_words;
  logic [1:0] accepted_beat_words;
  logic [AXIS_BYTES-1:0] expected_tkeep;
  logic expected_tlast;
  logic accepted_beat_protocol_valid;
  logic [BYTE_COUNT_W-1:0] expected_byte_count;

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

  assign descriptor_ready = !command_pending_q && !transfer_active_q &&
                            !beat_buffer_valid_q;
  assign descriptor_fire = descriptor_valid && descriptor_ready;

  assign command_destination_valid =
      command_destination_q == DEST_ACTIVATION_DIRECT ||
      command_destination_q == DEST_ACTIVATION_POOLED ||
      command_destination_q == DEST_WEIGHT;
  assign command_is_activation =
      command_destination_q == DEST_ACTIVATION_DIRECT ||
      command_destination_q == DEST_ACTIVATION_POOLED;
  assign command_count_valid = command_word_count_q != 0 &&
      ((command_is_activation &&
        command_word_count_q <= COUNT_W'(ACTIVATION_MAX_WORDS)) ||
       (command_destination_q == DEST_WEIGHT &&
        command_word_count_q <= COUNT_W'(WEIGHT_MAX_WORDS)));
  assign expected_byte_count =
      BYTE_COUNT_W'(command_word_count_q) << 3;
  assign command_byte_count_valid =
      command_byte_count_q == expected_byte_count &&
      command_byte_count_q[2:0] == 3'b000;
  assign command_lane_mask_valid =
      contiguous_lane_mask(command_lane_mask_q);
  assign command_fields_valid = command_destination_valid &&
                                command_count_valid &&
                                command_byte_count_valid &&
                                command_lane_mask_valid;
  assign command_target_ready =
      command_is_activation ? activation_fill_ready : weight_fill_ready;
  assign command_commit = command_pending_q && command_fields_valid &&
                          command_target_ready;
  assign command_reject = command_pending_q && !command_fields_valid;

  assign activation_fill_valid = command_pending_q &&
                                 command_fields_valid &&
                                 command_is_activation;
  assign activation_fill_is_pooled =
      command_destination_q == DEST_ACTIVATION_POOLED;
  assign activation_fill_word_count =
      command_word_count_q[ACTIVATION_COUNT_W-1:0];
  assign activation_fill_lane_mask = command_lane_mask_q;
  assign activation_fill_tensor_tag = command_tag_q;

  assign weight_fill_valid = command_pending_q && command_fields_valid &&
                             command_destination_q == DEST_WEIGHT;
  assign weight_fill_k_count =
      command_word_count_q[WEIGHT_COUNT_W-1:0];
  assign weight_fill_n_lane_mask = command_lane_mask_q;
  assign weight_fill_context_tag = command_tag_q;

  assign remaining_receive_words = active_word_count_q - words_received_q;
  assign accepted_beat_words =
      remaining_receive_words >= COUNT_W'(2) ? 2'd2 : 2'd1;
  always_comb begin
    expected_tkeep = '0;
    if (accepted_beat_words == 2)
      expected_tkeep = {AXIS_BYTES{1'b1}};
    else
      expected_tkeep[7:0] = 8'hff;
  end
  assign expected_tlast = remaining_receive_words <= COUNT_W'(2);
  assign accepted_beat_protocol_valid =
      s_axis_tkeep == expected_tkeep && s_axis_tlast == expected_tlast;
  assign s_axis_tready = transfer_active_q && !beat_buffer_valid_q &&
                         words_received_q < active_word_count_q;
  assign axis_fire = s_axis_tvalid && s_axis_tready;

  assign payload_valid = beat_buffer_valid_q;
  assign payload_values = beat_word_select_q ? beat_buffer_q[127:64] :
                                               beat_buffer_q[63:0];
  assign payload_last = words_transferred_q + 1'b1 == active_word_count_q;
  always_comb begin
    case (active_destination_q)
      DEST_ACTIVATION_DIRECT: payload_ready = activation_direct_ready;
      DEST_ACTIVATION_POOLED: payload_ready = activation_pooled_ready;
      DEST_WEIGHT: payload_ready = weight_write_ready;
      default: payload_ready = 1'b0;
    endcase
  end
  assign payload_fire = payload_valid && payload_ready;

  assign activation_direct_valid = payload_valid && transfer_active_q &&
                                   active_destination_q ==
                                       DEST_ACTIVATION_DIRECT;
  assign activation_direct_values = payload_values;
  assign activation_direct_lane_mask = active_lane_mask_q;
  assign activation_direct_last = payload_last;
  assign activation_pooled_valid = payload_valid && transfer_active_q &&
                                   active_destination_q ==
                                       DEST_ACTIVATION_POOLED;
  assign activation_pooled_values = payload_values;
  assign activation_pooled_lane_mask = active_lane_mask_q;
  assign activation_pooled_last = payload_last;
  assign weight_write_valid = payload_valid && transfer_active_q &&
                              active_destination_q == DEST_WEIGHT;
  assign weight_write_values = payload_values;
  assign weight_write_n_lane_mask = active_lane_mask_q;
  assign weight_write_last = payload_last;

  assign busy = command_pending_q || transfer_active_q;
  assign transfer_active = transfer_active_q;
  assign active_destination = active_destination_q;
  assign words_transferred = words_transferred_q;
  assign protocol_error = descriptor_error || stream_error;

  always_ff @(posedge clk) begin
    if (rst) begin
      command_pending_q <= 1'b0;
      command_destination_q <= '0;
      command_word_count_q <= '0;
      command_byte_count_q <= '0;
      command_lane_mask_q <= '0;
      command_tag_q <= '0;
      transfer_active_q <= 1'b0;
      active_destination_q <= '0;
      active_word_count_q <= '0;
      active_lane_mask_q <= '0;
      words_received_q <= '0;
      words_transferred_q <= '0;
      beat_buffer_valid_q <= 1'b0;
      beat_buffer_q <= '0;
      beat_word_count_q <= '0;
      beat_word_select_q <= 1'b0;
      transfer_done <= 1'b0;
      descriptor_rejected <= 1'b0;
      descriptor_error <= 1'b0;
      stream_error <= 1'b0;
      completed_transfers <= '0;
    end else begin
      transfer_done <= 1'b0;
      descriptor_rejected <= 1'b0;

      if (clear_error) begin
        descriptor_error <= 1'b0;
        stream_error <= 1'b0;
      end

      if (descriptor_fire) begin
        command_pending_q <= 1'b1;
        command_destination_q <= descriptor_destination;
        command_word_count_q <= descriptor_word_count;
        command_byte_count_q <= descriptor_byte_count;
        command_lane_mask_q <= descriptor_lane_mask;
        command_tag_q <= descriptor_tag;
      end

      if (command_reject) begin
        command_pending_q <= 1'b0;
        descriptor_rejected <= 1'b1;
        descriptor_error <= 1'b1;
      end

      if (command_commit) begin
        command_pending_q <= 1'b0;
        transfer_active_q <= 1'b1;
        active_destination_q <= command_destination_q;
        active_word_count_q <= command_word_count_q;
        active_lane_mask_q <= command_lane_mask_q;
        words_received_q <= '0;
        words_transferred_q <= '0;
        beat_buffer_valid_q <= 1'b0;
        beat_word_count_q <= '0;
        beat_word_select_q <= 1'b0;
      end

      if (axis_fire) begin
        beat_buffer_valid_q <= 1'b1;
        beat_buffer_q <= s_axis_tdata;
        beat_word_count_q <= accepted_beat_words;
        beat_word_select_q <= 1'b0;
        words_received_q <= words_received_q + accepted_beat_words;
        if (!accepted_beat_protocol_valid)
          stream_error <= 1'b1;
      end

      if (payload_fire) begin
        words_transferred_q <= words_transferred_q + 1'b1;
        if (payload_last) begin
          beat_buffer_valid_q <= 1'b0;
          beat_word_count_q <= '0;
          beat_word_select_q <= 1'b0;
          transfer_active_q <= 1'b0;
          transfer_done <= 1'b1;
          completed_transfers <= completed_transfers + 1'b1;
        end else if (!beat_word_select_q && beat_word_count_q == 2) begin
          beat_word_select_q <= 1'b1;
        end else begin
          beat_buffer_valid_q <= 1'b0;
          beat_word_count_q <= '0;
          beat_word_select_q <= 1'b0;
        end
      end
    end
  end

`ifndef SYNTHESIS
  initial begin
    if (AXIS_W != 128 || AXIS_BYTES != 16)
      $fatal(1, "AlexNet N8 DMA ingress requires a 128-bit AXIS port");
    if (ACTIVATION_COUNT_W > COUNT_W || WEIGHT_COUNT_W > COUNT_W)
      $fatal(1, "AlexNet N8 DMA ingress count widths are invalid");
    if (ACTIVATION_MAX_WORDS > (1 << ACTIVATION_COUNT_W) - 1 ||
        WEIGHT_MAX_WORDS > (1 << WEIGHT_COUNT_W) - 1)
      $fatal(1, "AlexNet N8 DMA ingress capacity exceeds output widths");
  end

  always_ff @(posedge clk) begin
    if (!rst) begin
      if (activation_fill_valid && weight_fill_valid)
        $fatal(1, "DMA ingress committed two storage owners");
      if (descriptor_rejected &&
          (activation_fill_valid || weight_fill_valid || transfer_active_q))
        $fatal(1, "rejected DMA descriptor consumed an owner");
      if (payload_valid && !transfer_active_q)
        $fatal(1, "DMA ingress payload exists outside an active transfer");
      if (words_received_q > active_word_count_q ||
          words_transferred_q > active_word_count_q)
        $fatal(1, "DMA ingress word counter overflow");
      if (transfer_done && words_transferred_q != active_word_count_q)
        $fatal(1, "DMA ingress completed before every word transferred");
    end
  end
`endif

endmodule
