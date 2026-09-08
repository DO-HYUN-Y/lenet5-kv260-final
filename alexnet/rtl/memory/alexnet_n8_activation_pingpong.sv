`timescale 1ns/1ps

// Two unchanged N8 activation banks with ordered A/B ownership. One physical
// bank may be filled while the other is read, but no bank is ever read and
// written concurrently. A fill descriptor fixes the direct/pooled source for
// the complete tensor. Completed tensors enter a two-entry FIFO so consumers
// always observe descriptor order even when both banks are READY.
module alexnet_n8_activation_pingpong #(
    parameter int DEPTH = 512,
    parameter int TENSOR_TAG_W = 16,
    parameter int ADDR_W = $clog2(DEPTH),
    parameter int COUNT_W = $clog2(DEPTH + 1)
) (
    input logic clk,
    input logic rst,

    input  logic fill_valid,
    output logic fill_ready,
    input  logic fill_is_pooled,
    input  logic [COUNT_W-1:0] fill_word_count,
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
    output logic [ADDR_W-1:0] read_index,
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
    output logic [1:0] bank0_state,
    output logic [1:0] bank1_state,
    output logic [COUNT_W-1:0] bank0_words_written,
    output logic [COUNT_W-1:0] bank1_words_written,
    output logic context_error,
    output logic protocol_error,
    output logic idle
);

  logic fill_preference_q;
  logic fill_active_q;
  logic fill_bank_q;
  logic fill_is_pooled_q;
  logic [COUNT_W-1:0] fill_word_count_q;
  logic [COUNT_W-1:0] fill_words_accepted_q;
  logic [7:0] fill_lane_mask_q;
  logic [TENSOR_TAG_W-1:0] bank0_tensor_tag_q;
  logic [TENSOR_TAG_W-1:0] bank1_tensor_tag_q;

  logic read_active_q;
  logic read_bank_q;
  logic [1:0] ready_count_q;
  logic ready_bank0_q;
  logic ready_bank1_q;

  logic selected_fill_bank;
  logic fill_descriptor_ok;
  logic fill_fire;
  logic selected_write_ready;
  logic selected_source_valid;
  logic [63:0] selected_source_values;
  logic [7:0] selected_source_lane_mask;
  logic selected_source_last;
  logic selected_source_ok;
  logic expected_write_last;
  logic write_fire;
  logic fill_complete_fire;

  logic read_tag_match;
  logic selected_read_start_ready;
  logic read_start_fire;
  logic read_complete_fire;

  logic bank0_fill_valid;
  logic bank0_fill_ready;
  logic bank0_write_valid;
  logic bank0_write_ready;
  logic bank0_read_start_valid;
  logic bank0_read_start_ready;
  logic bank0_read_valid;
  logic bank0_read_ready;
  logic [63:0] bank0_read_values;
  logic [7:0] bank0_read_lane_mask;
  logic [ADDR_W-1:0] bank0_read_index;
  logic bank0_read_last;
  logic [TENSOR_TAG_W-1:0] bank0_read_tensor_tag;
  logic bank0_read_done;
  logic bank0_idle;

  logic bank1_fill_valid;
  logic bank1_fill_ready;
  logic bank1_write_valid;
  logic bank1_write_ready;
  logic bank1_read_start_valid;
  logic bank1_read_start_ready;
  logic bank1_read_valid;
  logic bank1_read_ready;
  logic [63:0] bank1_read_values;
  logic [7:0] bank1_read_lane_mask;
  logic [ADDR_W-1:0] bank1_read_index;
  logic bank1_read_last;
  logic [TENSOR_TAG_W-1:0] bank1_read_tensor_tag;
  logic bank1_read_done;
  logic bank1_idle;

  always_comb begin
    if (fill_preference_q) begin
      if (bank1_fill_ready)
        selected_fill_bank = 1'b1;
      else
        selected_fill_bank = 1'b0;
    end else begin
      if (bank0_fill_ready)
        selected_fill_bank = 1'b0;
      else
        selected_fill_bank = 1'b1;
    end
  end

  assign fill_descriptor_ok = fill_word_count != 0 &&
                              fill_word_count <= DEPTH &&
                              fill_lane_mask != 0;
  assign fill_ready = !fill_active_q &&
                      (bank0_fill_ready || bank1_fill_ready) &&
                      fill_descriptor_ok;
  assign fill_fire = fill_valid && fill_ready;
  assign bank0_fill_valid = fill_fire && !selected_fill_bank;
  assign bank1_fill_valid = fill_fire && selected_fill_bank;

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

  assign selected_write_ready = fill_bank_q ? bank1_write_ready :
                                                 bank0_write_ready;
  assign expected_write_last = fill_words_accepted_q + 1'b1 ==
                               fill_word_count_q;
  assign selected_source_ok = selected_source_lane_mask == fill_lane_mask_q &&
                              selected_source_last == expected_write_last;
  assign direct_ready = fill_active_q && !fill_is_pooled_q &&
                        selected_write_ready && selected_source_ok;
  assign pooled_ready = fill_active_q && fill_is_pooled_q &&
                        selected_write_ready && selected_source_ok;
  assign write_fire = (direct_valid && direct_ready) ||
                      (pooled_valid && pooled_ready);
  assign fill_complete_fire = write_fire && expected_write_last;
  assign bank0_write_valid = write_fire && !fill_bank_q;
  assign bank1_write_valid = write_fire && fill_bank_q;

  assign ready_tensor_valid = ready_count_q != 0;
  assign ready_tensor_bank = ready_bank0_q;
  assign ready_tensor_tag = ready_bank0_q ? bank1_tensor_tag_q :
                                            bank0_tensor_tag_q;
  assign read_tag_match = read_start_tensor_tag == ready_tensor_tag;
  assign selected_read_start_ready = ready_bank0_q ?
                                     bank1_read_start_ready :
                                     bank0_read_start_ready;
  assign read_start_ready = !read_active_q && ready_tensor_valid &&
                            selected_read_start_ready && read_tag_match;
  assign read_start_fire = read_start_valid && read_start_ready;
  assign bank0_read_start_valid = read_start_fire && !ready_bank0_q;
  assign bank1_read_start_valid = read_start_fire && ready_bank0_q;

  always_comb begin
    read_valid = 1'b0;
    read_values = '0;
    read_lane_mask = '0;
    read_index = '0;
    read_last = 1'b0;
    read_tensor_tag = '0;
    if (read_active_q) begin
      if (read_bank_q) begin
        read_valid = bank1_read_valid;
        read_values = bank1_read_values;
        read_lane_mask = bank1_read_lane_mask;
        read_index = bank1_read_index;
        read_last = bank1_read_last;
        read_tensor_tag = bank1_read_tensor_tag;
      end else begin
        read_valid = bank0_read_valid;
        read_values = bank0_read_values;
        read_lane_mask = bank0_read_lane_mask;
        read_index = bank0_read_index;
        read_last = bank0_read_last;
        read_tensor_tag = bank0_read_tensor_tag;
      end
    end
  end

  assign bank0_read_ready = read_active_q && !read_bank_q && read_ready;
  assign bank1_read_ready = read_active_q && read_bank_q && read_ready;
  assign read_complete_fire = read_valid && read_ready && read_last;

  assign ready_count = ready_count_q;
  assign fill_active = fill_active_q;
  assign fill_bank = fill_bank_q;
  assign active_fill_is_pooled = fill_is_pooled_q;
  assign read_active = read_active_q;
  assign read_bank = read_bank_q;
  assign idle = bank0_idle && bank1_idle && !fill_active_q &&
                !read_active_q && ready_count_q == 0;

  alexnet_n8_activation_bank #(
      .DEPTH(DEPTH),
      .TENSOR_TAG_W(TENSOR_TAG_W),
      .ADDR_W(ADDR_W),
      .COUNT_W(COUNT_W)
  ) bank0 (
      .clk(clk),
      .rst(rst),
      .fill_valid(bank0_fill_valid),
      .fill_ready(bank0_fill_ready),
      .fill_word_count(fill_word_count),
      .fill_lane_mask(fill_lane_mask),
      .fill_tensor_tag(fill_tensor_tag),
      .write_valid(bank0_write_valid),
      .write_ready(bank0_write_ready),
      .write_values(selected_source_values),
      .write_lane_mask(selected_source_lane_mask),
      .write_last(selected_source_last),
      .read_start_valid(bank0_read_start_valid),
      .read_start_ready(bank0_read_start_ready),
      .read_valid(bank0_read_valid),
      .read_ready(bank0_read_ready),
      .read_values(bank0_read_values),
      .read_lane_mask(bank0_read_lane_mask),
      .read_index(bank0_read_index),
      .read_last(bank0_read_last),
      .read_tensor_tag(bank0_read_tensor_tag),
      .bank_state(bank0_state),
      .words_written(bank0_words_written),
      .read_done(bank0_read_done),
      .idle(bank0_idle)
  );

  alexnet_n8_activation_bank #(
      .DEPTH(DEPTH),
      .TENSOR_TAG_W(TENSOR_TAG_W),
      .ADDR_W(ADDR_W),
      .COUNT_W(COUNT_W)
  ) bank1 (
      .clk(clk),
      .rst(rst),
      .fill_valid(bank1_fill_valid),
      .fill_ready(bank1_fill_ready),
      .fill_word_count(fill_word_count),
      .fill_lane_mask(fill_lane_mask),
      .fill_tensor_tag(fill_tensor_tag),
      .write_valid(bank1_write_valid),
      .write_ready(bank1_write_ready),
      .write_values(selected_source_values),
      .write_lane_mask(selected_source_lane_mask),
      .write_last(selected_source_last),
      .read_start_valid(bank1_read_start_valid),
      .read_start_ready(bank1_read_start_ready),
      .read_valid(bank1_read_valid),
      .read_ready(bank1_read_ready),
      .read_values(bank1_read_values),
      .read_lane_mask(bank1_read_lane_mask),
      .read_index(bank1_read_index),
      .read_last(bank1_read_last),
      .read_tensor_tag(bank1_read_tensor_tag),
      .bank_state(bank1_state),
      .words_written(bank1_words_written),
      .read_done(bank1_read_done),
      .idle(bank1_idle)
  );

  always_ff @(posedge clk) begin
    if (rst) begin
      fill_preference_q <= 1'b0;
      fill_active_q <= 1'b0;
      fill_bank_q <= 1'b0;
      fill_is_pooled_q <= 1'b0;
      fill_word_count_q <= '0;
      fill_words_accepted_q <= '0;
      fill_lane_mask_q <= '0;
      bank0_tensor_tag_q <= '0;
      bank1_tensor_tag_q <= '0;
      read_active_q <= 1'b0;
      read_bank_q <= 1'b0;
      ready_count_q <= '0;
      ready_bank0_q <= 1'b0;
      ready_bank1_q <= 1'b0;
      read_done <= 1'b0;
      context_error <= 1'b0;
      protocol_error <= 1'b0;
    end else begin
      read_done <= 1'b0;

      if (fill_fire) begin
        fill_active_q <= 1'b1;
        fill_bank_q <= selected_fill_bank;
        fill_is_pooled_q <= fill_is_pooled;
        fill_word_count_q <= fill_word_count;
        fill_words_accepted_q <= '0;
        fill_lane_mask_q <= fill_lane_mask;
        fill_preference_q <= !selected_fill_bank;
        if (selected_fill_bank)
          bank1_tensor_tag_q <= fill_tensor_tag;
        else
          bank0_tensor_tag_q <= fill_tensor_tag;
      end

      if (write_fire) begin
        fill_words_accepted_q <= fill_words_accepted_q + 1'b1;
        if (expected_write_last)
          fill_active_q <= 1'b0;
      end

      if (read_start_fire) begin
        read_active_q <= 1'b1;
        read_bank_q <= ready_bank0_q;
      end

      if (read_complete_fire) begin
        read_active_q <= 1'b0;
        read_done <= 1'b1;
      end

      case ({fill_complete_fire, read_start_fire})
        2'b10: begin
          if (ready_count_q == 0)
            ready_bank0_q <= fill_bank_q;
          else
            ready_bank1_q <= fill_bank_q;
          ready_count_q <= ready_count_q + 1'b1;
        end
        2'b01: begin
          ready_bank0_q <= ready_bank1_q;
          ready_bank1_q <= 1'b0;
          ready_count_q <= ready_count_q - 1'b1;
        end
        2'b11: begin
          ready_bank0_q <= fill_bank_q;
          ready_bank1_q <= 1'b0;
        end
        default: ready_count_q <= ready_count_q;
      endcase

      if (fill_valid && !fill_active_q &&
          (bank0_fill_ready || bank1_fill_ready) && !fill_descriptor_ok)
        protocol_error <= 1'b1;
      if (fill_active_q && selected_source_valid && selected_write_ready &&
          !selected_source_ok)
        protocol_error <= 1'b1;
      if (read_start_valid && !read_active_q && ready_tensor_valid &&
          !read_tag_match)
        context_error <= 1'b1;
    end
  end

`ifndef SYNTHESIS
  initial begin
    if (DEPTH < 2 || (1 << ADDR_W) < DEPTH ||
        (1 << COUNT_W) <= DEPTH)
      $fatal(1, "activation ping-pong parameterization is invalid");
  end

  always_ff @(posedge clk) begin
    if (!rst) begin
      if (ready_count_q > 2)
        $fatal(1, "activation ping-pong READY queue overflowed");
      if (ready_count_q != 0 &&
          ((!ready_bank0_q && bank0_state != 2) ||
           (ready_bank0_q && bank1_state != 2)))
        $fatal(1, "activation ping-pong READY head lost ownership");
      if (ready_count_q == 2 &&
          (ready_bank0_q == ready_bank1_q || bank0_state != 2 ||
           bank1_state != 2))
        $fatal(1, "activation ping-pong READY queue is inconsistent");
      if (fill_active_q &&
          ((!fill_bank_q && bank0_state != 1) ||
           (fill_bank_q && bank1_state != 1)))
        $fatal(1, "activation ping-pong fill owner is inconsistent");
      if (read_active_q &&
          ((!read_bank_q && bank0_state != 3) ||
           (read_bank_q && bank1_state != 3)))
        $fatal(1, "activation ping-pong read owner is inconsistent");
      if (fill_active_q && read_active_q && fill_bank_q == read_bank_q)
        $fatal(1, "activation ping-pong read/write owners collided");
      if (fill_complete_fire && ready_count_q == 2)
        $fatal(1, "activation ping-pong completed a fill into a full queue");
      if (bank0_read_done != (read_done && !read_bank_q) ||
          bank1_read_done != (read_done && read_bank_q))
        $fatal(1, "activation ping-pong child completion was misaligned");
    end
  end
`endif

endmodule
