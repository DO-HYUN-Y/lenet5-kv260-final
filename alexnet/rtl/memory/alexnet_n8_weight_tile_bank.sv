`timescale 1ns/1ps

// One resident N8 weight tile with repeatable K-major replay.
//
// Ownership is explicit:
//
//   EMPTY -> WRITING -> READY <-> REPLAYING -> READY -> EMPTY
//
// A successful replay retains the tile, so the same stationary weights can be
// rewound for every spatial M group. The requested K count, N-tail mask, and
// weight-context tag must match the resident descriptor before replay starts.
module alexnet_n8_weight_tile_bank #(
    parameter int DEPTH = 968,
    parameter int CONTEXT_TAG_W = 16,
    parameter int ADDR_W = $clog2(DEPTH),
    parameter int COUNT_W = $clog2(DEPTH + 1)
) (
    input logic clk,
    input logic rst,

    input  logic fill_valid,
    output logic fill_ready,
    input  logic [COUNT_W-1:0] fill_k_count,
    input  logic [7:0] fill_n_lane_mask,
    input  logic [CONTEXT_TAG_W-1:0] fill_context_tag,

    input  logic write_valid,
    output logic write_ready,
    input  logic [63:0] write_values,
    input  logic [7:0] write_n_lane_mask,
    input  logic write_last,

    input  logic replay_valid,
    output logic replay_ready,
    input  logic [COUNT_W-1:0] replay_k_count,
    input  logic [7:0] replay_n_lane_mask,
    input  logic [CONTEXT_TAG_W-1:0] replay_context_tag,

    output logic weight_valid,
    input  logic weight_ready,
    output logic signed [7:0] weight_values [0:7],
    output logic [ADDR_W-1:0] weight_k,
    output logic weight_last,
    output logic [7:0] weight_n_lane_mask,
    output logic [CONTEXT_TAG_W-1:0] weight_context_tag,

    input  logic release_valid,
    output logic release_ready,

    output logic [1:0] bank_state,
    output logic resident_valid,
    output logic [COUNT_W-1:0] resident_k_count,
    output logic [7:0] resident_n_lane_mask,
    output logic [CONTEXT_TAG_W-1:0] resident_context_tag,
    output logic [COUNT_W-1:0] words_written,
    output logic [15:0] completed_replays,
    output logic replay_done,
    output logic context_error,
    output logic idle
);

  localparam logic [1:0] STATE_EMPTY = 2'd0;
  localparam logic [1:0] STATE_WRITING = 2'd1;
  localparam logic [1:0] STATE_READY = 2'd2;
  localparam logic [1:0] STATE_REPLAYING = 2'd3;

  (* ram_style = "block" *) logic [63:0] mem [0:DEPTH-1];

  logic [ADDR_W-1:0] write_addr_q;
  logic [COUNT_W-1:0] reads_issued_q;

  logic [63:0] masked_write_values;
  logic [63:0] packed_weight_values;
  logic context_match;
  logic fill_fire;
  logic write_fire;
  logic replay_fire;
  logic weight_fire;
  logic release_fire;
  logic output_slot_ready;
  logic issue_read;

  assign idle = bank_state == STATE_EMPTY;
  assign resident_valid = (bank_state == STATE_READY) ||
                          (bank_state == STATE_REPLAYING);
  assign fill_ready = bank_state == STATE_EMPTY;
  assign write_ready = bank_state == STATE_WRITING;

  assign context_match = (replay_k_count == resident_k_count) &&
                         (replay_n_lane_mask == resident_n_lane_mask) &&
                         (replay_context_tag == resident_context_tag);
  assign replay_ready = (bank_state == STATE_READY) && context_match;
  assign release_ready = (bank_state == STATE_READY) && !replay_valid;

  assign fill_fire = fill_valid && fill_ready;
  assign write_fire = write_valid && write_ready;
  assign replay_fire = replay_valid && replay_ready;
  assign weight_fire = weight_valid && weight_ready;
  assign release_fire = release_valid && release_ready;

  assign output_slot_ready = !weight_valid || weight_ready;
  // The replay handshake supplies address zero directly to the synchronous
  // BRAM read. Subsequent reads replace a consumed output beat in place, so
  // one register stage sustains one K word per cycle without the former empty
  // cycle between replay acceptance and the first weight.
  assign issue_read = ((bank_state == STATE_REPLAYING) || replay_fire) &&
                      output_slot_ready &&
                      (reads_issued_q < resident_k_count);

  always_comb begin
    masked_write_values = '0;
    for (int lane = 0; lane < 8; lane++) begin
      if (write_n_lane_mask[lane])
        masked_write_values[lane*8 +: 8] = write_values[lane*8 +: 8];
      weight_values[lane] = $signed(packed_weight_values[lane*8 +: 8]);
    end
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      bank_state <= STATE_EMPTY;
      resident_k_count <= '0;
      resident_n_lane_mask <= '0;
      resident_context_tag <= '0;
      write_addr_q <= '0;
      words_written <= '0;
      reads_issued_q <= '0;
      weight_valid <= 1'b0;
      packed_weight_values <= '0;
      weight_k <= '0;
      weight_last <= 1'b0;
      weight_n_lane_mask <= '0;
      weight_context_tag <= '0;
      completed_replays <= '0;
      replay_done <= 1'b0;
      context_error <= 1'b0;
    end else begin
      replay_done <= 1'b0;

      if (weight_fire)
        weight_valid <= 1'b0;

      if (fill_fire) begin
        bank_state <= STATE_WRITING;
        resident_k_count <= fill_k_count;
        resident_n_lane_mask <= fill_n_lane_mask;
        resident_context_tag <= fill_context_tag;
        write_addr_q <= '0;
        words_written <= '0;
        context_error <= 1'b0;
      end

      if (write_fire) begin
        mem[write_addr_q] <= masked_write_values;
        words_written <= words_written + 1'b1;
        if ((words_written + 1'b1 == resident_k_count) && write_last) begin
          bank_state <= STATE_READY;
        end else begin
          write_addr_q <= write_addr_q + 1'b1;
        end
      end

      if ((bank_state == STATE_READY) && replay_valid && !context_match)
        context_error <= 1'b1;

      if (replay_fire) begin
        bank_state <= STATE_REPLAYING;
        reads_issued_q <= '0;
        weight_valid <= 1'b0;
      end

      if (issue_read) begin
        weight_valid <= 1'b1;
        packed_weight_values <= mem[reads_issued_q[ADDR_W-1:0]];
        weight_k <= reads_issued_q[ADDR_W-1:0];
        weight_last <= reads_issued_q + 1'b1 == resident_k_count;
        weight_n_lane_mask <= resident_n_lane_mask;
        weight_context_tag <= resident_context_tag;
        reads_issued_q <= reads_issued_q + 1'b1;
      end

      if (weight_fire && weight_last) begin
        bank_state <= STATE_READY;
        reads_issued_q <= '0;
        completed_replays <= completed_replays + 1'b1;
        replay_done <= 1'b1;
      end

      if (release_fire) begin
        bank_state <= STATE_EMPTY;
        resident_k_count <= '0;
        resident_n_lane_mask <= '0;
        resident_context_tag <= '0;
        write_addr_q <= '0;
        words_written <= '0;
        reads_issued_q <= '0;
        weight_valid <= 1'b0;
        context_error <= 1'b0;
      end
    end
  end

`ifndef SYNTHESIS
  initial begin
    if (DEPTH < 2 || (1 << ADDR_W) < DEPTH ||
        (1 << COUNT_W) <= DEPTH)
      $fatal(1, "weight tile bank parameterization is invalid");
  end

  always_ff @(posedge clk) begin
    if (!rst) begin
      if (fill_fire && (fill_k_count == 0 || fill_k_count > DEPTH ||
                        fill_n_lane_mask == 0))
        $fatal(1, "weight tile bank fill descriptor is invalid");
      if (write_fire && write_n_lane_mask != resident_n_lane_mask)
        $fatal(1, "weight tile bank N lane mask changed during fill");
      if (write_fire &&
          (write_last != (words_written + 1'b1 == resident_k_count)))
        $fatal(1, "weight tile bank write_last does not match K count");
      if (weight_fire && weight_k >= resident_k_count)
        $fatal(1, "weight tile bank replay K exceeded resident count");
      if (weight_valid &&
          ((packed_weight_values & ~{
              {8{resident_n_lane_mask[7]}},
              {8{resident_n_lane_mask[6]}},
              {8{resident_n_lane_mask[5]}},
              {8{resident_n_lane_mask[4]}},
              {8{resident_n_lane_mask[3]}},
              {8{resident_n_lane_mask[2]}},
              {8{resident_n_lane_mask[1]}},
              {8{resident_n_lane_mask[0]}}
          }) != 0))
        $fatal(1, "weight tile bank emitted nonzero invalid N lane");
    end
  end
`endif

endmodule
