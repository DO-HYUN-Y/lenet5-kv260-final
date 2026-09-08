`timescale 1ns/1ps

// Two-segment A/B activation storage. Each segment is one unchanged activation
// ping-pong unit, so logical A and B tensors each have two 512-word physical
// banks. Tensors larger than one segment split at word 512. Shorter tensors
// are mirrored into both segments and read in lockstep; this preserves paired
// ping-pong bank ownership without adding storage or padding DMA payloads.
// Both segment descriptors and read starts are atomic.
module alexnet_n8_activation_dual_segment_pingpong #(
    parameter int SEGMENT_DEPTH = 512,
    parameter int TENSOR_TAG_W = 16,
    parameter int LOCAL_ADDR_W = $clog2(SEGMENT_DEPTH),
    parameter int LOCAL_COUNT_W = $clog2(SEGMENT_DEPTH + 1),
    parameter int GLOBAL_ADDR_W = $clog2(2 * SEGMENT_DEPTH),
    parameter int TOTAL_COUNT_W = $clog2(2 * SEGMENT_DEPTH + 1)
) (
    input logic clk,
    input logic rst,

    input  logic fill_valid,
    output logic fill_ready,
    input  logic fill_is_pooled,
    input  logic [TOTAL_COUNT_W-1:0] fill_word_count,
    input  logic [7:0] fill_lane_mask,
    input  logic [TENSOR_TAG_W-1:0] fill_tensor_tag,

    input  logic direct_valid,
    output logic direct_ready,
    input  logic [63:0] direct_values,
    input  logic [7:0] direct_lane_mask,
    input  logic direct_last,

    input  logic pooled_valid,
    output logic pooled_ready,
    input  logic [63:0] pooled_values,
    input  logic [7:0] pooled_lane_mask,
    input  logic pooled_last,

    input  logic read_start_valid,
    output logic read_start_ready,
    input  logic [TENSOR_TAG_W-1:0] read_start_tensor_tag,

    output logic read_valid,
    input  logic read_ready,
    output logic [63:0] read_values,
    output logic [7:0] read_lane_mask,
    output logic [GLOBAL_ADDR_W-1:0] read_index,
    output logic read_last,
    output logic [TENSOR_TAG_W-1:0] read_tensor_tag,
    output logic read_done,

    output logic ready_tensor_valid,
    output logic ready_tensor_bank,
    output logic [TENSOR_TAG_W-1:0] ready_tensor_tag,
    output logic [1:0] ready_count,
    output logic fill_active,
    output logic fill_bank,
    output logic active_fill_is_pooled,
    output logic read_active,
    output logic read_bank,
    output logic read_segment,
    output logic [1:0] segment0_bank0_state,
    output logic [1:0] segment0_bank1_state,
    output logic [1:0] segment1_bank0_state,
    output logic [1:0] segment1_bank1_state,
    output logic context_error,
    output logic protocol_error,
    output logic idle
);

  localparam logic [LOCAL_COUNT_W-1:0] FULL_SEGMENT_WORDS =
      SEGMENT_DEPTH;

  logic fill_active_q;
  logic fill_is_pooled_q;
  logic fill_replicated_q;
  logic [TOTAL_COUNT_W-1:0] fill_word_count_q;
  logic [TOTAL_COUNT_W-1:0] fill_words_accepted_q;
  logic [7:0] fill_lane_mask_q;
  logic [TENSOR_TAG_W-1:0] fill_tensor_tag_q;

  logic read_active_q;
  logic read_bank_q;
  logic read_segment_q;
  logic read_replicated_q;

  logic [1:0] ready_count_q;
  logic ready_bank0_q;
  logic ready_bank1_q;
  logic [TENSOR_TAG_W-1:0] ready_tag0_q;
  logic [TENSOR_TAG_W-1:0] ready_tag1_q;
  logic ready_replicated0_q;
  logic ready_replicated1_q;

  logic context_error_q;
  logic protocol_error_q;

  logic descriptor_ok;
  logic descriptor_replicated;
  logic [LOCAL_COUNT_W-1:0] segment0_word_count;
  logic [LOCAL_COUNT_W-1:0] segment1_word_count;
  logic fill_fire;
  logic fill_in_segment1;
  logic selected_source_valid;
  logic [63:0] selected_source_values;
  logic [7:0] selected_source_lane_mask;
  logic selected_source_last;
  logic selected_source_ok;
  logic expected_global_last;
  logic expected_local_last;
  logic selected_child_write_ready;
  logic segment0_selected_write_ready;
  logic segment1_selected_write_ready;
  logic child_source_valid;
  logic write_fire;
  logic fill_complete_fire;

  logic ready_tag_match;
  logic children_head_match;
  logic read_start_fire;
  logic segment0_read_complete_fire;
  logic read_complete_fire;

  logic segment0_fill_ready;
  logic segment0_direct_valid;
  logic segment0_direct_ready;
  logic segment0_pooled_valid;
  logic segment0_pooled_ready;
  logic segment0_read_start_ready;
  logic segment0_read_valid;
  logic segment0_read_ready;
  logic [63:0] segment0_read_values;
  logic [7:0] segment0_read_lane_mask;
  logic [LOCAL_ADDR_W-1:0] segment0_read_index;
  logic segment0_read_last;
  logic [TENSOR_TAG_W-1:0] segment0_read_tensor_tag;
  logic segment0_read_done;
  logic segment0_ready_tensor_valid;
  logic segment0_ready_tensor_bank;
  logic [TENSOR_TAG_W-1:0] segment0_ready_tensor_tag;
  logic [1:0] segment0_ready_count;
  logic segment0_fill_active;
  logic segment0_fill_bank;
  logic segment0_read_active;
  logic segment0_read_bank;
  logic segment0_context_error;
  logic segment0_protocol_error;
  logic segment0_idle;

  logic segment1_fill_ready;
  logic segment1_direct_valid;
  logic segment1_direct_ready;
  logic segment1_pooled_valid;
  logic segment1_pooled_ready;
  logic segment1_read_start_ready;
  logic segment1_read_valid;
  logic segment1_read_ready;
  logic [63:0] segment1_read_values;
  logic [7:0] segment1_read_lane_mask;
  logic [LOCAL_ADDR_W-1:0] segment1_read_index;
  logic segment1_read_last;
  logic [TENSOR_TAG_W-1:0] segment1_read_tensor_tag;
  logic segment1_read_done;
  logic segment1_ready_tensor_valid;
  logic segment1_ready_tensor_bank;
  logic [TENSOR_TAG_W-1:0] segment1_ready_tensor_tag;
  logic [1:0] segment1_ready_count;
  logic segment1_fill_active;
  logic segment1_fill_bank;
  logic segment1_read_active;
  logic segment1_read_bank;
  logic segment1_context_error;
  logic segment1_protocol_error;
  logic segment1_idle;

  assign descriptor_ok = fill_word_count != 0 &&
                         fill_word_count <= 2 * SEGMENT_DEPTH &&
                         fill_lane_mask != 0;
  assign descriptor_replicated = fill_word_count <= SEGMENT_DEPTH;
  assign segment0_word_count = descriptor_replicated ?
      LOCAL_COUNT_W'(fill_word_count) : FULL_SEGMENT_WORDS;
  assign segment1_word_count = descriptor_replicated ?
      LOCAL_COUNT_W'(fill_word_count) :
      LOCAL_COUNT_W'(fill_word_count - SEGMENT_DEPTH);
  assign fill_ready = !fill_active_q && descriptor_ok &&
                      segment0_fill_ready && segment1_fill_ready;
  assign fill_fire = fill_valid && fill_ready;

  always_comb begin
    if (fill_is_pooled_q) begin
      selected_source_valid = pooled_valid;
      selected_source_values = pooled_values;
      selected_source_lane_mask = pooled_lane_mask;
      selected_source_last = pooled_last;
    end else begin
      selected_source_valid = direct_valid;
      selected_source_values = direct_values;
      selected_source_lane_mask = direct_lane_mask;
      selected_source_last = direct_last;
    end
  end

  assign fill_in_segment1 = fill_words_accepted_q >= SEGMENT_DEPTH;
  assign expected_global_last = fill_words_accepted_q + 1'b1 ==
                                fill_word_count_q;
  assign expected_local_last = fill_replicated_q ? expected_global_last :
      (fill_in_segment1 ? expected_global_last :
       fill_words_accepted_q + 1'b1 == SEGMENT_DEPTH);
  assign selected_source_ok = selected_source_lane_mask == fill_lane_mask_q &&
                              selected_source_last == expected_global_last;
  assign segment0_selected_write_ready = fill_is_pooled_q ?
      segment0_pooled_ready : segment0_direct_ready;
  assign segment1_selected_write_ready = fill_is_pooled_q ?
      segment1_pooled_ready : segment1_direct_ready;
  assign selected_child_write_ready = fill_replicated_q ?
      (segment0_selected_write_ready && segment1_selected_write_ready) :
      (fill_in_segment1 ? segment1_selected_write_ready :
                          segment0_selected_write_ready);
  assign direct_ready = fill_active_q && !fill_is_pooled_q &&
                        selected_child_write_ready && selected_source_ok;
  assign pooled_ready = fill_active_q && fill_is_pooled_q &&
                        selected_child_write_ready && selected_source_ok;
  assign write_fire = (direct_valid && direct_ready) ||
                      (pooled_valid && pooled_ready);
  assign fill_complete_fire = write_fire && expected_global_last;
  assign child_source_valid = selected_source_valid && selected_source_ok;

  assign segment0_direct_valid = fill_active_q && !fill_is_pooled_q &&
      child_source_valid &&
      (fill_replicated_q ? segment1_direct_ready : !fill_in_segment1);
  assign segment0_pooled_valid = fill_active_q && fill_is_pooled_q &&
      child_source_valid &&
      (fill_replicated_q ? segment1_pooled_ready : !fill_in_segment1);
  assign segment1_direct_valid = fill_active_q && !fill_is_pooled_q &&
      child_source_valid &&
      (fill_replicated_q ? segment0_direct_ready : fill_in_segment1);
  assign segment1_pooled_valid = fill_active_q && fill_is_pooled_q &&
      child_source_valid &&
      (fill_replicated_q ? segment0_pooled_ready : fill_in_segment1);

  assign ready_tensor_valid = ready_count_q != 0;
  assign ready_tensor_bank = ready_bank0_q;
  assign ready_tensor_tag = ready_tag0_q;
  assign ready_tag_match = read_start_tensor_tag == ready_tag0_q;
  assign children_head_match = segment0_ready_tensor_valid &&
                               segment1_ready_tensor_valid &&
                               segment0_ready_tensor_bank == ready_bank0_q &&
                               segment1_ready_tensor_bank == ready_bank0_q &&
                               segment0_ready_tensor_tag == ready_tag0_q &&
                               segment1_ready_tensor_tag == ready_tag0_q;
  assign read_start_ready = !read_active_q && ready_tensor_valid &&
                            ready_tag_match && children_head_match &&
                            segment0_read_start_ready &&
                            segment1_read_start_ready;
  assign read_start_fire = read_start_valid && read_start_ready;

  always_comb begin
    read_valid = 1'b0;
    read_values = '0;
    read_lane_mask = '0;
    read_index = '0;
    read_last = 1'b0;
    read_tensor_tag = '0;
    if (read_active_q) begin
      if (read_replicated_q) begin
        read_valid = segment0_read_valid && segment1_read_valid;
        read_values = segment0_read_values;
        read_lane_mask = segment0_read_lane_mask;
        read_index = segment0_read_index;
        read_last = segment0_read_last && segment1_read_last;
        read_tensor_tag = segment0_read_tensor_tag;
      end else if (read_segment_q) begin
        read_valid = segment1_read_valid;
        read_values = segment1_read_values;
        read_lane_mask = segment1_read_lane_mask;
        read_index = SEGMENT_DEPTH + segment1_read_index;
        read_last = segment1_read_last;
        read_tensor_tag = segment1_read_tensor_tag;
      end else begin
        read_valid = segment0_read_valid;
        read_values = segment0_read_values;
        read_lane_mask = segment0_read_lane_mask;
        read_index = segment0_read_index;
        read_tensor_tag = segment0_read_tensor_tag;
      end
    end
  end

  assign segment0_read_ready = read_active_q &&
      (read_replicated_q ? (read_ready && segment1_read_valid) :
                           (!read_segment_q && read_ready));
  assign segment1_read_ready = read_active_q &&
      (read_replicated_q ? (read_ready && segment0_read_valid) :
                           (read_segment_q && read_ready));
  assign segment0_read_complete_fire = read_valid && read_ready &&
      !read_replicated_q && !read_segment_q && segment0_read_last;
  assign read_complete_fire = read_valid && read_ready &&
      (read_replicated_q ? read_last :
                           (read_segment_q && segment1_read_last));

  assign ready_count = ready_count_q;
  assign fill_active = fill_active_q;
  assign fill_bank = fill_active_q ? segment1_fill_bank : 1'b0;
  assign active_fill_is_pooled = fill_is_pooled_q;
  assign read_active = read_active_q;
  assign read_bank = read_bank_q;
  assign read_segment = read_segment_q;
  assign context_error = context_error_q || segment0_context_error ||
                         segment1_context_error;
  assign protocol_error = protocol_error_q || segment0_protocol_error ||
                          segment1_protocol_error;
  assign idle = segment0_idle && segment1_idle && !fill_active_q &&
                !read_active_q && ready_count_q == 0;

  alexnet_n8_activation_pingpong #(
      .DEPTH(SEGMENT_DEPTH),
      .TENSOR_TAG_W(TENSOR_TAG_W),
      .ADDR_W(LOCAL_ADDR_W),
      .COUNT_W(LOCAL_COUNT_W)
  ) segment0 (
      .clk(clk),
      .rst(rst),
      .fill_valid(fill_fire),
      .fill_ready(segment0_fill_ready),
      .fill_is_pooled(fill_is_pooled),
      .fill_word_count(segment0_word_count),
      .fill_lane_mask(fill_lane_mask),
      .fill_tensor_tag(fill_tensor_tag),
      .direct_valid(segment0_direct_valid),
      .direct_ready(segment0_direct_ready),
      .direct_values(selected_source_values),
      .direct_lane_mask(fill_lane_mask_q),
      .direct_last(expected_local_last),
      .pooled_valid(segment0_pooled_valid),
      .pooled_ready(segment0_pooled_ready),
      .pooled_values(selected_source_values),
      .pooled_lane_mask(fill_lane_mask_q),
      .pooled_last(expected_local_last),
      .read_start_valid(read_start_fire),
      .read_start_ready(segment0_read_start_ready),
      .read_start_tensor_tag(read_start_tensor_tag),
      .read_valid(segment0_read_valid),
      .read_ready(segment0_read_ready),
      .read_values(segment0_read_values),
      .read_lane_mask(segment0_read_lane_mask),
      .read_index(segment0_read_index),
      .read_last(segment0_read_last),
      .read_tensor_tag(segment0_read_tensor_tag),
      .read_done(segment0_read_done),
      .ready_tensor_valid(segment0_ready_tensor_valid),
      .ready_tensor_bank(segment0_ready_tensor_bank),
      .ready_tensor_tag(segment0_ready_tensor_tag),
      .ready_count(segment0_ready_count),
      .fill_active(segment0_fill_active),
      .fill_bank(segment0_fill_bank),
      .active_fill_is_pooled(),
      .read_active(segment0_read_active),
      .read_bank(segment0_read_bank),
      .bank0_state(segment0_bank0_state),
      .bank1_state(segment0_bank1_state),
      .bank0_words_written(),
      .bank1_words_written(),
      .context_error(segment0_context_error),
      .protocol_error(segment0_protocol_error),
      .idle(segment0_idle)
  );

  alexnet_n8_activation_pingpong #(
      .DEPTH(SEGMENT_DEPTH),
      .TENSOR_TAG_W(TENSOR_TAG_W),
      .ADDR_W(LOCAL_ADDR_W),
      .COUNT_W(LOCAL_COUNT_W)
  ) segment1 (
      .clk(clk),
      .rst(rst),
      .fill_valid(fill_fire),
      .fill_ready(segment1_fill_ready),
      .fill_is_pooled(fill_is_pooled),
      .fill_word_count(segment1_word_count),
      .fill_lane_mask(fill_lane_mask),
      .fill_tensor_tag(fill_tensor_tag),
      .direct_valid(segment1_direct_valid),
      .direct_ready(segment1_direct_ready),
      .direct_values(selected_source_values),
      .direct_lane_mask(fill_lane_mask_q),
      .direct_last(expected_local_last),
      .pooled_valid(segment1_pooled_valid),
      .pooled_ready(segment1_pooled_ready),
      .pooled_values(selected_source_values),
      .pooled_lane_mask(fill_lane_mask_q),
      .pooled_last(expected_local_last),
      .read_start_valid(read_start_fire),
      .read_start_ready(segment1_read_start_ready),
      .read_start_tensor_tag(read_start_tensor_tag),
      .read_valid(segment1_read_valid),
      .read_ready(segment1_read_ready),
      .read_values(segment1_read_values),
      .read_lane_mask(segment1_read_lane_mask),
      .read_index(segment1_read_index),
      .read_last(segment1_read_last),
      .read_tensor_tag(segment1_read_tensor_tag),
      .read_done(segment1_read_done),
      .ready_tensor_valid(segment1_ready_tensor_valid),
      .ready_tensor_bank(segment1_ready_tensor_bank),
      .ready_tensor_tag(segment1_ready_tensor_tag),
      .ready_count(segment1_ready_count),
      .fill_active(segment1_fill_active),
      .fill_bank(segment1_fill_bank),
      .active_fill_is_pooled(),
      .read_active(segment1_read_active),
      .read_bank(segment1_read_bank),
      .bank0_state(segment1_bank0_state),
      .bank1_state(segment1_bank1_state),
      .bank0_words_written(),
      .bank1_words_written(),
      .context_error(segment1_context_error),
      .protocol_error(segment1_protocol_error),
      .idle(segment1_idle)
  );

  always_ff @(posedge clk) begin
    if (rst) begin
      fill_active_q <= 1'b0;
      fill_is_pooled_q <= 1'b0;
      fill_replicated_q <= 1'b0;
      fill_word_count_q <= '0;
      fill_words_accepted_q <= '0;
      fill_lane_mask_q <= '0;
      fill_tensor_tag_q <= '0;
      read_active_q <= 1'b0;
      read_bank_q <= 1'b0;
      read_segment_q <= 1'b0;
      read_replicated_q <= 1'b0;
      ready_count_q <= '0;
      ready_bank0_q <= 1'b0;
      ready_bank1_q <= 1'b0;
      ready_tag0_q <= '0;
      ready_tag1_q <= '0;
      ready_replicated0_q <= 1'b0;
      ready_replicated1_q <= 1'b0;
      context_error_q <= 1'b0;
      protocol_error_q <= 1'b0;
      read_done <= 1'b0;
    end else begin
      read_done <= 1'b0;

      if (fill_fire) begin
        fill_active_q <= 1'b1;
        fill_is_pooled_q <= fill_is_pooled;
        fill_replicated_q <= descriptor_replicated;
        fill_word_count_q <= fill_word_count;
        fill_words_accepted_q <= '0;
        fill_lane_mask_q <= fill_lane_mask;
        fill_tensor_tag_q <= fill_tensor_tag;
      end

      if (write_fire) begin
        fill_words_accepted_q <= fill_words_accepted_q + 1'b1;
        if (expected_global_last)
          fill_active_q <= 1'b0;
      end

      if (read_start_fire) begin
        read_active_q <= 1'b1;
        read_bank_q <= ready_bank0_q;
        read_segment_q <= 1'b0;
        read_replicated_q <= ready_replicated0_q;
      end
      if (segment0_read_complete_fire)
        read_segment_q <= 1'b1;
      if (read_complete_fire) begin
        read_active_q <= 1'b0;
        read_segment_q <= 1'b0;
        read_replicated_q <= 1'b0;
        read_done <= 1'b1;
      end

      case ({fill_complete_fire, read_start_fire})
        2'b10: begin
          if (ready_count_q == 0) begin
            ready_bank0_q <= segment1_fill_bank;
            ready_tag0_q <= fill_tensor_tag_q;
            ready_replicated0_q <= fill_replicated_q;
          end else begin
            ready_bank1_q <= segment1_fill_bank;
            ready_tag1_q <= fill_tensor_tag_q;
            ready_replicated1_q <= fill_replicated_q;
          end
          ready_count_q <= ready_count_q + 1'b1;
        end
        2'b01: begin
          ready_bank0_q <= ready_bank1_q;
          ready_tag0_q <= ready_tag1_q;
          ready_replicated0_q <= ready_replicated1_q;
          ready_bank1_q <= 1'b0;
          ready_tag1_q <= '0;
          ready_replicated1_q <= 1'b0;
          ready_count_q <= ready_count_q - 1'b1;
        end
        2'b11: begin
          ready_bank0_q <= segment1_fill_bank;
          ready_tag0_q <= fill_tensor_tag_q;
          ready_replicated0_q <= fill_replicated_q;
          ready_bank1_q <= 1'b0;
          ready_tag1_q <= '0;
          ready_replicated1_q <= 1'b0;
        end
        default: ready_count_q <= ready_count_q;
      endcase

      if (fill_valid && !fill_active_q && !descriptor_ok)
        protocol_error_q <= 1'b1;
      if (fill_active_q && selected_source_valid &&
          selected_child_write_ready && !selected_source_ok)
        protocol_error_q <= 1'b1;
      if (read_start_valid && !read_active_q && ready_tensor_valid &&
          !ready_tag_match)
        context_error_q <= 1'b1;
    end
  end

`ifndef SYNTHESIS
  initial begin
    if (SEGMENT_DEPTH < 2 ||
        (1 << LOCAL_ADDR_W) < SEGMENT_DEPTH ||
        (1 << LOCAL_COUNT_W) <= SEGMENT_DEPTH ||
        (1 << GLOBAL_ADDR_W) < 2 * SEGMENT_DEPTH ||
        (1 << TOTAL_COUNT_W) <= 2 * SEGMENT_DEPTH)
      $fatal(1, "dual-segment activation parameterization is invalid");
  end

  always_ff @(posedge clk) begin
    if (!rst) begin
      if (ready_count_q > 2)
        $fatal(1, "dual-segment activation READY queue overflowed");
      if (ready_count_q != 0 && !children_head_match)
        $fatal(1, "dual-segment activation child READY heads diverged");
      if (fill_active_q && !segment1_fill_active)
        $fatal(1, "dual-segment activation lost segment-1 fill owner");
      if (fill_active_q && !fill_in_segment1 &&
          (!segment0_fill_active || segment0_fill_bank != segment1_fill_bank))
        $fatal(1, "dual-segment activation fill banks diverged");
      if (read_active_q && !segment1_read_active)
        $fatal(1, "dual-segment activation lost segment-1 read owner");
      if (read_active_q && !read_segment_q &&
          (!segment0_read_active || segment0_read_bank != segment1_read_bank))
        $fatal(1, "dual-segment activation read banks diverged");
      if (read_active_q && read_bank_q != segment1_read_bank)
        $fatal(1, "dual-segment activation global read bank diverged");
      if (fill_complete_fire && ready_count_q == 2)
        $fatal(1, "dual-segment activation completed into a full queue");
      if (fill_complete_fire && read_start_fire && ready_count_q != 1)
        $fatal(1, "dual-segment activation simultaneous queue update invalid");
      if (segment0_read_complete_fire && read_index != SEGMENT_DEPTH - 1)
        $fatal(1, "dual-segment activation segment-0 index ended early");
      if (segment0_ready_count < segment1_ready_count)
        $fatal(1, "dual-segment activation segment-1 queue passed segment 0");
    end
  end
`endif

endmodule
