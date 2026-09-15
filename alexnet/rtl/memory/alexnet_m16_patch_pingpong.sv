`timescale 1ns/1ps

// One transposed M16 activation patch. Address K returns all sixteen spatial
// values needed by the dynamic M8xN128 / 2xM8xN64 array in one cycle.
module alexnet_m16_patch_uram #(
    parameter int DEPTH = 4096,
    parameter int ADDR_W = $clog2(DEPTH)
) (
    input logic clk,
    input logic write_enable,
    input logic [ADDR_W-1:0] write_address,
    input logic [127:0] write_data,
    input logic read_enable,
    input logic [ADDR_W-1:0] read_address,
    output logic [127:0] read_data
);

  (* ram_style = "ultra" *) logic [127:0] memory [0:DEPTH-1];

  always_ff @(posedge clk) begin
    if (write_enable)
      memory[write_address] <= write_data;
    if (read_enable)
      read_data <= memory[read_address];
  end

endmodule

// Ping-pong M16 patch buffer.
//
// A patch assembler fills one set while the array replays the other. Each
// accepted write is one complete M16 vector for a K position. Replay is one
// registered 128-bit vector per cycle and a consumed patch is released
// automatically, because unlike stationary weights a spatial patch is not
// reused after its output tile retires.
//
// Set ownership:
//   EMPTY -> WRITING -> READY -> REPLAYING -> EMPTY
module alexnet_m16_patch_pingpong #(
    parameter int DEPTH = 4096,
    parameter int CONTEXT_TAG_W = 16,
    parameter int ADDR_W = $clog2(DEPTH),
    parameter int COUNT_W = $clog2(DEPTH + 1)
) (
    input logic clk,
    input logic rst,

    input  logic fill_valid,
    output logic fill_ready,
    input  logic [COUNT_W-1:0] fill_k_count,
    input  logic [15:0] fill_m_lane_mask,
    input  logic [CONTEXT_TAG_W-1:0] fill_context_tag,

    input  logic write_valid,
    output logic write_ready,
    input  logic [127:0] write_values,
    input  logic write_last,
    output logic [ADDR_W-1:0] write_k,

    input  logic replay_valid,
    output logic replay_ready,
    input  logic [COUNT_W-1:0] replay_k_count,
    input  logic [15:0] replay_m_lane_mask,
    input  logic [CONTEXT_TAG_W-1:0] replay_context_tag,

    output logic patch_valid,
    input  logic patch_ready,
    output logic signed [7:0] patch_values [0:15],
    output logic [ADDR_W-1:0] patch_k,
    output logic patch_last,
    output logic [15:0] patch_m_lane_mask,
    output logic [CONTEXT_TAG_W-1:0] patch_context_tag,

    output logic [1:0] set_state [0:1],
    output logic [1:0] ready_set_mask,
    output logic fill_active,
    output logic active_fill_set,
    output logic replay_active,
    output logic active_replay_set,
    output logic [COUNT_W-1:0] words_written,
    output logic [15:0] completed_fills,
    output logic [15:0] completed_replays,
    output logic fill_done,
    output logic replay_done,
    output logic context_error,
    output logic protocol_error,
    output logic idle
);

  localparam logic [1:0] STATE_EMPTY = 2'd0;
  localparam logic [1:0] STATE_WRITING = 2'd1;
  localparam logic [1:0] STATE_READY = 2'd2;
  localparam logic [1:0] STATE_REPLAYING = 2'd3;

  logic [COUNT_W-1:0] set_k_count_q [0:1];
  logic [15:0] set_m_lane_mask_q [0:1];
  logic [CONTEXT_TAG_W-1:0] set_context_tag_q [0:1];

  logic fill_set_q;
  logic replay_set_q;
  logic [ADDR_W-1:0] write_k_q;
  logic [COUNT_W-1:0] reads_issued_q;
  logic read_pending_q;
  logic [127:0] memory_read_data [0:1];
  logic [127:0] packed_patch_q;
  logic [ADDR_W-1:0] pending_k_q;
  logic pending_last_q;

  logic memory_write_enable [0:1];
  logic memory_read_enable [0:1];
  logic [127:0] masked_write_values;
  logic [1:0] replay_match;
  logic selected_empty_set;
  logic selected_replay_set;
  logic read_owner_set;
  logic [COUNT_W-1:0] read_owner_k_count;
  logic fill_fire;
  logic write_fire;
  logic replay_fire;
  logic patch_fire;
  logic output_slot_ready;
  logic read_stage_ready;
  logic issue_read;
  logic write_is_final;

  always_comb begin
    selected_empty_set = set_state[0] != STATE_EMPTY;
    fill_ready = !fill_active &&
                 ((set_state[0] == STATE_EMPTY) ||
                  (set_state[1] == STATE_EMPTY));

    replay_match[0] = set_state[0] == STATE_READY &&
        set_k_count_q[0] == replay_k_count &&
        set_m_lane_mask_q[0] == replay_m_lane_mask &&
        set_context_tag_q[0] == replay_context_tag;
    replay_match[1] = set_state[1] == STATE_READY &&
        set_k_count_q[1] == replay_k_count &&
        set_m_lane_mask_q[1] == replay_m_lane_mask &&
        set_context_tag_q[1] == replay_context_tag;
    selected_replay_set = !replay_match[0];
    replay_ready = !replay_active && |replay_match;

    fill_fire = fill_valid && fill_ready;
    write_ready = fill_active;
    write_fire = write_valid && write_ready;
    replay_fire = replay_valid && replay_ready;
    patch_fire = patch_valid && patch_ready;

    output_slot_ready = !patch_valid || patch_ready;
    read_stage_ready = !read_pending_q || output_slot_ready;
    read_owner_set = replay_fire ? selected_replay_set : replay_set_q;
    read_owner_k_count = replay_fire ? replay_k_count :
                                             set_k_count_q[replay_set_q];
    // Issue address zero on the replay handshake. The synchronous URAM data
    // is captured on the next clock and thereafter sustains one K per cycle.
    issue_read = (replay_active || replay_fire) && read_stage_ready &&
                 reads_issued_q < read_owner_k_count;
    write_is_final = write_k_q + 1'b1 == set_k_count_q[fill_set_q];

    masked_write_values = '0;
    for (int lane = 0; lane < 16; lane++) begin
      if (set_m_lane_mask_q[fill_set_q][lane])
        masked_write_values[lane*8 +: 8] =
            write_values[lane*8 +: 8];
      patch_values[lane] = $signed(packed_patch_q[lane*8 +: 8]);
    end

    for (int set_index = 0; set_index < 2; set_index++) begin
      memory_write_enable[set_index] = write_fire &&
                                       fill_set_q == set_index;
      memory_read_enable[set_index] = issue_read &&
                                      read_owner_set == set_index;
    end

    write_k = write_k_q;
    active_fill_set = fill_set_q;
    active_replay_set = replay_set_q;
    ready_set_mask[0] = set_state[0] == STATE_READY;
    ready_set_mask[1] = set_state[1] == STATE_READY;
    idle = set_state[0] == STATE_EMPTY && set_state[1] == STATE_EMPTY &&
           !fill_active && !replay_active && !patch_valid &&
           !read_pending_q;
  end

  generate
    for (genvar set_index = 0; set_index < 2; set_index++) begin : g_set
      alexnet_m16_patch_uram #(
          .DEPTH(DEPTH), .ADDR_W(ADDR_W)
      ) u_memory (
          .clk,
          .write_enable(memory_write_enable[set_index]),
          .write_address(write_k_q),
          .write_data(masked_write_values),
          .read_enable(memory_read_enable[set_index]),
          .read_address(reads_issued_q[ADDR_W-1:0]),
          .read_data(memory_read_data[set_index])
      );
    end
  endgenerate

  always_ff @(posedge clk) begin
    if (rst) begin
      set_state[0] <= STATE_EMPTY;
      set_state[1] <= STATE_EMPTY;
      fill_set_q <= 1'b0;
      replay_set_q <= 1'b0;
      fill_active <= 1'b0;
      replay_active <= 1'b0;
      write_k_q <= '0;
      words_written <= '0;
      reads_issued_q <= '0;
      read_pending_q <= 1'b0;
      pending_k_q <= '0;
      pending_last_q <= 1'b0;
      patch_valid <= 1'b0;
      packed_patch_q <= '0;
      patch_k <= '0;
      patch_last <= 1'b0;
      patch_m_lane_mask <= '0;
      patch_context_tag <= '0;
      completed_fills <= '0;
      completed_replays <= '0;
      fill_done <= 1'b0;
      replay_done <= 1'b0;
      context_error <= 1'b0;
      protocol_error <= 1'b0;
      for (int set_index = 0; set_index < 2; set_index++) begin
        set_k_count_q[set_index] <= '0;
        set_m_lane_mask_q[set_index] <= '0;
        set_context_tag_q[set_index] <= '0;
      end
    end else begin
      fill_done <= 1'b0;
      replay_done <= 1'b0;

      if (patch_fire)
        patch_valid <= 1'b0;

      if (fill_fire) begin
        fill_set_q <= selected_empty_set;
        fill_active <= 1'b1;
        set_state[selected_empty_set] <= STATE_WRITING;
        set_k_count_q[selected_empty_set] <= fill_k_count;
        set_m_lane_mask_q[selected_empty_set] <= fill_m_lane_mask;
        set_context_tag_q[selected_empty_set] <= fill_context_tag;
        write_k_q <= '0;
        words_written <= '0;
        context_error <= 1'b0;
        protocol_error <= 1'b0;
      end

      if (write_fire) begin
        if (write_last != write_is_final) begin
          set_state[fill_set_q] <= STATE_EMPTY;
          fill_active <= 1'b0;
          protocol_error <= 1'b1;
        end else begin
          words_written <= words_written + 1'b1;
          if (write_is_final) begin
            set_state[fill_set_q] <= STATE_READY;
            fill_active <= 1'b0;
            fill_done <= 1'b1;
            completed_fills <= completed_fills + 1'b1;
          end else begin
            write_k_q <= write_k_q + 1'b1;
          end
        end
      end

      if ((replay_valid && !replay_ready && |ready_set_mask))
        context_error <= 1'b1;

      if (replay_fire) begin
        replay_set_q <= selected_replay_set;
        replay_active <= 1'b1;
        set_state[selected_replay_set] <= STATE_REPLAYING;
        reads_issued_q <= '0;
        read_pending_q <= 1'b0;
        patch_valid <= 1'b0;
        context_error <= 1'b0;
      end

      if (read_stage_ready) begin
        if (read_pending_q) begin
          patch_valid <= 1'b1;
          packed_patch_q <= memory_read_data[replay_set_q];
          patch_k <= pending_k_q;
          patch_last <= pending_last_q;
          patch_m_lane_mask <= set_m_lane_mask_q[replay_set_q];
          patch_context_tag <= set_context_tag_q[replay_set_q];
        end

        read_pending_q <= issue_read;
        if (issue_read) begin
          pending_k_q <= reads_issued_q[ADDR_W-1:0];
          pending_last_q <= reads_issued_q + 1'b1 == read_owner_k_count;
          reads_issued_q <= reads_issued_q + 1'b1;
        end
      end

      if (patch_fire && patch_last) begin
        set_state[replay_set_q] <= STATE_EMPTY;
        set_k_count_q[replay_set_q] <= '0;
        set_m_lane_mask_q[replay_set_q] <= '0;
        set_context_tag_q[replay_set_q] <= '0;
        replay_active <= 1'b0;
        reads_issued_q <= '0;
        read_pending_q <= 1'b0;
        completed_replays <= completed_replays + 1'b1;
        replay_done <= 1'b1;
      end
    end
  end

`ifndef SYNTHESIS
  initial begin
    if (DEPTH < 2 || (1 << ADDR_W) < DEPTH ||
        (1 << COUNT_W) <= DEPTH)
      $fatal(1, "M16 patch ping-pong parameterization is invalid");
  end

  always_ff @(posedge clk) begin
    if (!rst) begin
      if (fill_fire &&
          (fill_k_count == 0 || fill_k_count > DEPTH ||
           fill_m_lane_mask == 0))
        $fatal(1, "M16 patch fill descriptor is invalid");
      if (patch_fire && patch_k >= set_k_count_q[replay_set_q])
        $fatal(1, "M16 patch replay K exceeded resident count");
      if (fill_active && set_state[fill_set_q] != STATE_WRITING)
        $fatal(1, "M16 patch fill owner/state mismatch");
      if (replay_active && set_state[replay_set_q] != STATE_REPLAYING)
        $fatal(1, "M16 patch replay owner/state mismatch");
      if (fill_active && replay_active && fill_set_q == replay_set_q)
        $fatal(1, "M16 patch read/write owners collided");
    end
  end
`endif

endmodule
