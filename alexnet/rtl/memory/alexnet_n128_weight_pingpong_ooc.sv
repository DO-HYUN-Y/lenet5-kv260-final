`timescale 1ns/1ps

// Compact-pin implementation harness for the N128 resident-weight service.
// It fills both sets, replays both sets, and folds all 1,024 output bits into
// a pipelined signature without exposing the wide internal bus as package IO.
module alexnet_n128_weight_pingpong_ooc #(
    parameter int DEPTH = 4096,
    parameter int ADDR_W = $clog2(DEPTH),
    parameter int COUNT_W = $clog2(DEPTH + 1),
    parameter int WRITE_COUNT_W = $clog2(8 * DEPTH + 1)
) (
    input logic clk,
    input logic rst,
    input logic start,
    input logic [31:0] seed,
    output logic busy,
    output logic done,
    output logic [31:0] result_signature
);

  typedef enum logic [3:0] {
    ST_IDLE,
    ST_FILL0_DESC,
    ST_FILL0_DATA,
    ST_START_OVERLAP,
    ST_OVERLAP,
    ST_REPLAY1_DESC,
    ST_REPLAY1,
    ST_DRAIN
  } state_t;

  state_t state_q;
  logic [31:0] lfsr_q;
  logic replay0_done_q;
  logic fill1_done_q;
  logic [3:0] drain_q;

  logic fill_valid;
  logic fill_ready;
  logic [COUNT_W-1:0] fill_k_count;
  logic [7:0] fill_bank_enable;
  logic [15:0] fill_n_lane_mask [0:7];
  logic [15:0] fill_context_tag;
  logic write_valid;
  logic write_ready;
  logic [127:0] write_values;
  logic write_last;
  logic [ADDR_W-1:0] write_k;
  logic [2:0] write_bank_slot;
  logic replay_valid;
  logic replay_ready;
  logic [COUNT_W-1:0] replay_k_count;
  logic [7:0] replay_bank_enable;
  logic [15:0] replay_n_lane_mask [0:7];
  logic [15:0] replay_context_tag;
  logic weight_valid;
  logic weight_ready;
  logic signed [7:0] weight_values [0:7][0:15];
  logic [ADDR_W-1:0] weight_k;
  logic weight_last;
  logic [7:0] weight_bank_enable;
  logic [15:0] weight_n_lane_mask [0:7];
  logic [15:0] weight_context_tag;
  logic [1:0] set_state [0:1];
  logic [1:0] ready_set_mask;
  logic fill_active;
  logic active_fill_set;
  logic replay_active;
  logic active_replay_set;
  logic [WRITE_COUNT_W-1:0] words_written;
  logic [15:0] completed_fills;
  logic [15:0] completed_replays;
  logic fill_done;
  logic replay_done;
  logic context_error;
  logic protocol_error;
  logic idle;

  logic [15:0] lane_parity_q [0:7];
  logic [7:0] bank_parity_q;

  always_comb begin
    fill_valid = state_q == ST_FILL0_DESC ||
                 state_q == ST_START_OVERLAP;
    fill_k_count = COUNT_W'(DEPTH);
    fill_bank_enable = 8'hff;
    fill_context_tag = state_q == ST_FILL0_DESC ? 16'h5100 : 16'h5200;
    replay_valid = state_q == ST_START_OVERLAP ||
                   state_q == ST_REPLAY1_DESC;
    replay_k_count = COUNT_W'(DEPTH);
    replay_bank_enable = 8'hff;
    replay_context_tag = state_q == ST_REPLAY1_DESC ?
                         16'h5200 : 16'h5100;
    for (int bank = 0; bank < 8; bank++) begin
      fill_n_lane_mask[bank] = 16'hffff;
      replay_n_lane_mask[bank] = 16'hffff;
    end

    write_valid = state_q == ST_FILL0_DATA || state_q == ST_OVERLAP;
    write_last = write_valid && write_k == DEPTH-1 &&
                 write_bank_slot == 3'd7;
    for (int lane = 0; lane < 16; lane++)
      write_values[lane*8 +: 8] =
          lfsr_q[(lane % 4)*8 +: 8] ^ write_k[7:0] ^
          {5'b0, write_bank_slot};
    weight_ready = state_q == ST_OVERLAP || state_q == ST_REPLAY1 ||
                   state_q == ST_DRAIN;
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      state_q <= ST_IDLE;
      lfsr_q <= 32'h1;
      replay0_done_q <= 1'b0;
      fill1_done_q <= 1'b0;
      drain_q <= '0;
      busy <= 1'b0;
      done <= 1'b0;
      result_signature <= '0;
      for (int bank = 0; bank < 8; bank++) begin
        bank_parity_q[bank] <= 1'b0;
        for (int lane = 0; lane < 16; lane++)
          lane_parity_q[bank][lane] <= 1'b0;
      end
    end else begin
      done <= 1'b0;

      if (write_valid && write_ready)
        lfsr_q <= {lfsr_q[30:0],
                   lfsr_q[31] ^ lfsr_q[21] ^ lfsr_q[1] ^ lfsr_q[0]};

      for (int bank = 0; bank < 8; bank++) begin
        if (weight_valid)
          for (int lane = 0; lane < 16; lane++)
            lane_parity_q[bank][lane] <= ^weight_values[bank][lane];
        bank_parity_q[bank] <= ^lane_parity_q[bank];
      end
      if (busy)
        result_signature <=
            {result_signature[30:0], result_signature[31]} ^
            {23'b0, ^bank_parity_q, ^weight_k,
             weight_last, ^weight_bank_enable, ^weight_context_tag,
             ^completed_fills, ^completed_replays, protocol_error};

      case (state_q)
        ST_IDLE: begin
          busy <= 1'b0;
          if (start) begin
            busy <= 1'b1;
            lfsr_q <= seed == 0 ? 32'h1 : seed;
            result_signature <= '0;
            replay0_done_q <= 1'b0;
            fill1_done_q <= 1'b0;
            state_q <= ST_FILL0_DESC;
          end
        end

        ST_FILL0_DESC:
          if (fill_valid && fill_ready)
            state_q <= ST_FILL0_DATA;

        ST_FILL0_DATA:
          if (fill_done)
            state_q <= ST_START_OVERLAP;

        ST_START_OVERLAP:
          if (fill_valid && fill_ready && replay_valid && replay_ready)
            state_q <= ST_OVERLAP;

        ST_OVERLAP: begin
          if (replay_done)
            replay0_done_q <= 1'b1;
          if (fill_done)
            fill1_done_q <= 1'b1;
          if ((replay0_done_q || replay_done) &&
              (fill1_done_q || fill_done))
            state_q <= ST_REPLAY1_DESC;
        end

        ST_REPLAY1_DESC:
          if (replay_valid && replay_ready)
            state_q <= ST_REPLAY1;

        ST_REPLAY1:
          if (replay_done) begin
            drain_q <= '0;
            state_q <= ST_DRAIN;
          end

        ST_DRAIN: begin
          if (drain_q == 4'd7) begin
            busy <= 1'b0;
            done <= 1'b1;
            state_q <= ST_IDLE;
          end else begin
            drain_q <= drain_q + 1'b1;
          end
        end

        default: state_q <= ST_IDLE;
      endcase
    end
  end

  alexnet_n128_weight_pingpong #(
      .DEPTH(DEPTH),
      .ADDR_W(ADDR_W),
      .COUNT_W(COUNT_W),
      .WRITE_COUNT_W(WRITE_COUNT_W)
  ) u_pingpong (
      .clk,
      .rst,
      .fill_valid,
      .fill_ready,
      .fill_k_count,
      .fill_bank_enable,
      .fill_n_lane_mask,
      .fill_context_tag,
      .write_valid,
      .write_ready,
      .write_values,
      .write_last,
      .write_k,
      .write_bank_slot,
      .replay_valid,
      .replay_ready,
      .replay_k_count,
      .replay_bank_enable,
      .replay_n_lane_mask,
      .replay_context_tag,
      .weight_valid,
      .weight_ready,
      .weight_values,
      .weight_k,
      .weight_last,
      .weight_bank_enable,
      .weight_n_lane_mask,
      .weight_context_tag,
      .release_valid(1'b0),
      .release_ready(),
      .release_context_tag(16'b0),
      .set_state,
      .ready_set_mask,
      .fill_active,
      .active_fill_set,
      .replay_active,
      .active_replay_set,
      .words_written,
      .completed_fills,
      .completed_replays,
      .fill_done,
      .replay_done,
      .context_error,
      .protocol_error,
      .idle
  );

endmodule
