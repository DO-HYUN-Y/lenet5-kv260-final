`timescale 1ns/1ps

// One physical N8 activation-memory bank. Direct router packets and pooled
// raster packets use the same sequential write stream. Ownership is explicit:
// EMPTY -> WRITING -> READY -> READING -> EMPTY. Independent A/B instances may
// overlap, but a single bank never reads and writes concurrently.
module alexnet_n8_activation_bank #(
    parameter int DEPTH = 512,
    parameter int TENSOR_TAG_W = 16,
    parameter int ADDR_W = $clog2(DEPTH),
    parameter int COUNT_W = $clog2(DEPTH + 1)
) (
    input logic clk,
    input logic rst,

    input  logic fill_valid,
    output logic fill_ready,
    input  logic [COUNT_W-1:0] fill_word_count,
    input  logic [7:0] fill_lane_mask,
    input  logic [TENSOR_TAG_W-1:0] fill_tensor_tag,

    input  logic write_valid,
    output logic write_ready,
    input  logic [63:0] write_values,
    input  logic [7:0] write_lane_mask,
    input  logic write_last,

    input  logic read_start_valid,
    output logic read_start_ready,

    output logic read_valid,
    input  logic read_ready,
    output logic [63:0] read_values,
    output logic [7:0] read_lane_mask,
    output logic [ADDR_W-1:0] read_index,
    output logic read_last,
    output logic [TENSOR_TAG_W-1:0] read_tensor_tag,

    output logic [1:0] bank_state,
    output logic [COUNT_W-1:0] words_written,
    output logic read_done,
    output logic idle
);

  localparam logic [1:0] STATE_EMPTY = 2'd0;
  localparam logic [1:0] STATE_WRITING = 2'd1;
  localparam logic [1:0] STATE_READY = 2'd2;
  localparam logic [1:0] STATE_READING = 2'd3;

  (* ram_style = "block" *) logic [63:0] mem [0:DEPTH-1];

  logic [COUNT_W-1:0] word_count_q;
  logic [7:0] lane_mask_q;
  logic [TENSOR_TAG_W-1:0] tensor_tag_q;
  logic [ADDR_W-1:0] write_addr_q;
  logic [COUNT_W-1:0] reads_issued_q;

  logic read_pending_q;
  logic [63:0] mem_read_q;
  logic [ADDR_W-1:0] pending_index_q;
  logic pending_last_q;

  logic [63:0] masked_write_values;
  logic fill_fire;
  logic write_fire;
  logic read_start_fire;
  logic read_output_fire;
  logic output_slot_ready;
  logic read_stage_ready;
  logic issue_read;

  assign idle = bank_state == STATE_EMPTY;
  assign fill_ready = bank_state == STATE_EMPTY;
  assign write_ready = bank_state == STATE_WRITING;
  assign read_start_ready = bank_state == STATE_READY;

  assign fill_fire = fill_valid && fill_ready;
  assign write_fire = write_valid && write_ready;
  assign read_start_fire = read_start_valid && read_start_ready;
  assign read_output_fire = read_valid && read_ready;

  assign output_slot_ready = !read_valid || read_ready;
  assign read_stage_ready = !read_pending_q || output_slot_ready;
  assign issue_read = bank_state == STATE_READING && read_stage_ready &&
                      (reads_issued_q < word_count_q);

  always_comb begin
    masked_write_values = '0;
    for (int lane = 0; lane < 8; lane++) begin
      if (write_lane_mask[lane])
        masked_write_values[lane*8 +: 8] = write_values[lane*8 +: 8];
    end
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      bank_state <= STATE_EMPTY;
      word_count_q <= '0;
      lane_mask_q <= '0;
      tensor_tag_q <= '0;
      write_addr_q <= '0;
      words_written <= '0;
      reads_issued_q <= '0;
      read_pending_q <= 1'b0;
      mem_read_q <= '0;
      pending_index_q <= '0;
      pending_last_q <= 1'b0;
      read_valid <= 1'b0;
      read_values <= '0;
      read_lane_mask <= '0;
      read_index <= '0;
      read_last <= 1'b0;
      read_tensor_tag <= '0;
      read_done <= 1'b0;
    end else begin
      read_done <= 1'b0;

      if (read_output_fire)
        read_valid <= 1'b0;

      if (fill_fire) begin
        bank_state <= STATE_WRITING;
        word_count_q <= fill_word_count;
        lane_mask_q <= fill_lane_mask;
        tensor_tag_q <= fill_tensor_tag;
        write_addr_q <= '0;
        words_written <= '0;
      end

      if (write_fire) begin
        mem[write_addr_q] <= masked_write_values;
        words_written <= words_written + 1'b1;
        if ((words_written + 1'b1 == word_count_q) && write_last) begin
          bank_state <= STATE_READY;
        end else begin
          write_addr_q <= write_addr_q + 1'b1;
        end
      end

      if (read_start_fire) begin
        bank_state <= STATE_READING;
        reads_issued_q <= '0;
        read_pending_q <= 1'b0;
      end

      if (read_stage_ready) begin
        if (read_pending_q) begin
          read_valid <= 1'b1;
          read_values <= mem_read_q;
          read_lane_mask <= lane_mask_q;
          read_index <= pending_index_q;
          read_last <= pending_last_q;
          read_tensor_tag <= tensor_tag_q;
        end

        read_pending_q <= issue_read;
        if (issue_read) begin
          mem_read_q <= mem[reads_issued_q[ADDR_W-1:0]];
          pending_index_q <= reads_issued_q[ADDR_W-1:0];
          pending_last_q <= reads_issued_q + 1'b1 == word_count_q;
          reads_issued_q <= reads_issued_q + 1'b1;
        end
      end

      if (read_output_fire && read_last) begin
        bank_state <= STATE_EMPTY;
        word_count_q <= '0;
        lane_mask_q <= '0;
        tensor_tag_q <= '0;
        write_addr_q <= '0;
        words_written <= '0;
        reads_issued_q <= '0;
        read_pending_q <= 1'b0;
        read_done <= 1'b1;
      end
    end
  end

`ifndef SYNTHESIS
  initial begin
    if (DEPTH < 2 || (1 << ADDR_W) < DEPTH)
      $fatal(1, "activation bank parameterization is invalid");
  end

  always_ff @(posedge clk) begin
    if (!rst) begin
      if (fill_fire && (fill_word_count == 0 || fill_word_count > DEPTH ||
                        fill_lane_mask == 0))
        $fatal(1, "activation bank fill descriptor is invalid");
      if (write_fire && write_lane_mask != lane_mask_q)
        $fatal(1, "activation bank lane mask changed during fill");
      if (write_fire &&
          (write_last != (words_written + 1'b1 == word_count_q)))
        $fatal(1, "activation bank write_last does not match word_count");
      if (read_output_fire && read_index >= word_count_q)
        $fatal(1, "activation bank read index exceeded word_count");
    end
  end
`endif

endmodule
