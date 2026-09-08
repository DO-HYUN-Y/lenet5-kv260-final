`timescale 1ns/1ps

// Pool5 contains 32 channel groups x 6 x 6 x 8 signed bytes.  The external
// stream supplies 576 full 128-bit beats; a lossless 128-to-144 gearbox stores
// those 73,728 bits as 512 rows.  A 512x144 simple dual-port RAM maps to two
// parallel RAMB36E2 blocks instead of four depth-cascaded 64-bit memories.
module alexnet_pool5_n8_store (
    input logic clk,
    input logic rst,

    input  logic start_valid,
    output logic start_ready,
    input  logic [15:0] start_tag,

    input  logic write_valid,
    output logic write_ready,
    input  logic [127:0] write_data,
    input  logic [15:0] write_keep,
    input  logic write_last,

    input  logic read_request_valid,
    output logic read_request_ready,
    input  logic [10:0] read_request_word_address,
    input  logic [2:0] read_request_lane,
    input  logic [15:0] read_request_tag,
    output logic read_response_valid,
    input  logic read_response_ready,
    output logic signed [7:0] read_response_value,
    output logic read_response_error,

    output logic write_active,
    output logic write_done,
    output logic cache_valid,
    output logic [15:0] cache_tag,
    output logic fault,
    output logic [9:0] beats_written,
    output logic [5:0] tiles_written
);
  localparam int WORDS = 1152;
  localparam int BEATS = 576;
  localparam int BEATS_PER_TILE = 18;
  localparam int ROWS = 512;
  localparam int SCALARS_PER_ROW = 18;

  (* ram_style = "block" *) logic [143:0] row_mem [0:ROWS-1];

  logic [255:0] reservoir_q;
  logic [8:0] reservoir_bits_q;
  logic [8:0] write_row_address_q;
  logic [4:0] tile_beat_q;
  logic all_input_q;
  logic write_active_q;
  logic cache_valid_q;
  logic [15:0] cache_tag_q;
  logic fault_q;

  logic read_decode_pending_q;
  logic read_memory_pending_q;
  logic read_value_pending_q;
  logic [13:0] read_scalar_index_q;
  logic [8:0] read_row_address_q;
  logic [4:0] read_byte_q;
  logic read_error_q;
  logic [143:0] read_row_q;

  logic start_fire;
  logic write_fire;
  logic row_write_fire;
  logic read_fire;
  logic response_fire;
  logic [13:0] request_scalar_index;
  logic unused_read_tag;

  assign start_ready = !write_active_q && !read_decode_pending_q &&
                       !read_memory_pending_q && !read_value_pending_q &&
                       !read_response_valid;
  assign start_fire = start_valid && start_ready;
  assign write_ready = write_active_q && !all_input_q &&
                       (reservoir_bits_q < 9'd144);
  assign write_fire = write_valid && write_ready;
  assign row_write_fire = write_active_q &&
                          (reservoir_bits_q >= 9'd144);
  assign read_request_ready = cache_valid_q && !write_active_q &&
                              !read_decode_pending_q &&
                              !read_memory_pending_q &&
                              !read_value_pending_q &&
                              !read_response_valid;
  assign read_fire = read_request_valid && read_request_ready;
  assign response_fire = read_response_valid && read_response_ready;
  assign request_scalar_index = {read_request_word_address, 3'b000} +
                                read_request_lane;
  assign unused_read_tag = ^read_request_tag;

  assign write_active = write_active_q;
  assign cache_valid = cache_valid_q;
  assign cache_tag = cache_tag_q;
  assign fault = fault_q;

  always_ff @(posedge clk) begin
    if (rst) begin
      reservoir_q <= 0;
      reservoir_bits_q <= 0;
      write_row_address_q <= 0;
      tile_beat_q <= 0;
      all_input_q <= 1'b0;
      write_active_q <= 1'b0;
      cache_valid_q <= 1'b0;
      cache_tag_q <= 0;
      fault_q <= 1'b0;
      read_decode_pending_q <= 1'b0;
      read_memory_pending_q <= 1'b0;
      read_value_pending_q <= 1'b0;
      read_scalar_index_q <= 0;
      read_row_address_q <= 0;
      read_byte_q <= 0;
      read_error_q <= 1'b0;
      read_row_q <= 0;
      read_response_valid <= 1'b0;
      read_response_value <= 0;
      read_response_error <= 1'b0;
      write_done <= 1'b0;
      beats_written <= 0;
      tiles_written <= 0;
    end else begin
      write_done <= 1'b0;

      if (start_fire) begin
        reservoir_q <= 0;
        reservoir_bits_q <= 0;
        write_row_address_q <= 0;
        tile_beat_q <= 0;
        all_input_q <= 1'b0;
        write_active_q <= 1'b1;
        cache_valid_q <= 1'b0;
        cache_tag_q <= start_tag;
        fault_q <= 1'b0;
        beats_written <= 0;
        tiles_written <= 0;
      end

      // Input and row emission are deliberately exclusive.  The reservoir
      // therefore needs only one registered shift/merge operation per cycle.
      if (write_fire) begin
        reservoir_q <= reservoir_q |
                       ({128'b0, write_data} << reservoir_bits_q);
        reservoir_bits_q <= reservoir_bits_q + 9'd128;
        beats_written <= beats_written + 1'b1;

        if (write_keep != 16'hffff ||
            write_last != (tile_beat_q == BEATS_PER_TILE - 1))
          fault_q <= 1'b1;

        if (tile_beat_q == BEATS_PER_TILE - 1) begin
          tile_beat_q <= 0;
          tiles_written <= tiles_written + 1'b1;
        end else begin
          tile_beat_q <= tile_beat_q + 1'b1;
        end

        if (beats_written == BEATS - 1)
          all_input_q <= 1'b1;
      end else if (row_write_fire) begin
        row_mem[write_row_address_q] <= reservoir_q[143:0];
        reservoir_q <= reservoir_q >> 144;
        reservoir_bits_q <= reservoir_bits_q - 9'd144;

        if (write_row_address_q == ROWS - 1) begin
          write_active_q <= 1'b0;
          cache_valid_q <= all_input_q && !fault_q;
          write_done <= 1'b1;
        end else begin
          write_row_address_q <= write_row_address_q + 1'b1;
        end
      end

      // Convert FC6's logical N8 word/lane address into one of the 18 bytes in
      // a physical row.  Staging the constant divide keeps it off the RAM
      // output path and preserves a conventional synchronous BRAM template.
      if (read_fire) begin
        read_decode_pending_q <= 1'b1;
        read_scalar_index_q <= request_scalar_index;
        read_error_q <= read_request_word_address >= WORDS;
        if (read_request_word_address >= WORDS)
          fault_q <= 1'b1;
      end

      if (read_decode_pending_q) begin
        read_decode_pending_q <= 1'b0;
        read_memory_pending_q <= 1'b1;
        if (read_error_q) begin
          read_row_address_q <= 0;
          read_byte_q <= 0;
        end else begin
          read_row_address_q <= read_scalar_index_q / SCALARS_PER_ROW;
          read_byte_q <= read_scalar_index_q % SCALARS_PER_ROW;
        end
      end

      if (read_memory_pending_q) begin
        read_memory_pending_q <= 1'b0;
        read_value_pending_q <= 1'b1;
        read_row_q <= row_mem[read_row_address_q];
      end

      if (read_value_pending_q) begin
        read_value_pending_q <= 1'b0;
        read_response_valid <= 1'b1;
        read_response_value <= read_row_q[read_byte_q*8 +: 8];
        read_response_error <= read_error_q;
      end

      if (response_fire) begin
        read_response_valid <= 1'b0;
        read_response_error <= 1'b0;
      end
    end
  end

`ifndef SYNTHESIS
  always_ff @(posedge clk) begin
    if (!rst) begin
      if (write_valid && !write_active_q)
        $fatal(1, "Pool5 cache write arrived outside a frame");
      if (read_request_valid && cache_valid_q &&
          read_request_word_address >= WORDS)
        $fatal(1, "Pool5 cache read address is out of range");
    end
  end
`endif
endmodule
