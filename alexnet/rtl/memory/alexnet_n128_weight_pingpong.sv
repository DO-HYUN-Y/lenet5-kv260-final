`timescale 1ns/1ps

// One 128-bit N16 slice of a resident weight set.  A 4096-deep instance maps
// to two UltraRAMs on K26 while preserving one read and one write per cycle.
module alexnet_n16_weight_uram #(
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

// Ping-pong resident N128 weight service.
//
// External fill is one 128-bit beat per cycle.  Beats are K-major and visit
// enabled N16 banks in ascending bank order.  Replay reads every enabled bank
// concurrently and produces one 1024-bit K word per cycle after the URAM read
// latency.  The inactive set may be filled while the active set replays.
//
// Set ownership:
//   EMPTY -> WRITING -> READY <-> REPLAYING -> READY -> EMPTY
module alexnet_n128_weight_pingpong #(
    parameter int DEPTH = 4096,
    parameter int CONTEXT_TAG_W = 16,
    parameter int ADDR_W = $clog2(DEPTH),
    parameter int COUNT_W = $clog2(DEPTH + 1),
    parameter int WRITE_COUNT_W = $clog2(8 * DEPTH + 1)
) (
    input logic clk,
    input logic rst,

    input  logic fill_valid,
    output logic fill_ready,
    input  logic [COUNT_W-1:0] fill_k_count,
    input  logic [7:0] fill_bank_enable,
    input  logic [15:0] fill_n_lane_mask [0:7],
    input  logic [CONTEXT_TAG_W-1:0] fill_context_tag,

    input  logic write_valid,
    output logic write_ready,
    input  logic [127:0] write_values,
    input  logic write_last,
    output logic [ADDR_W-1:0] write_k,
    output logic [2:0] write_bank_slot,

    input  logic replay_valid,
    output logic replay_ready,
    input  logic [COUNT_W-1:0] replay_k_count,
    input  logic [7:0] replay_bank_enable,
    input  logic [15:0] replay_n_lane_mask [0:7],
    input  logic [CONTEXT_TAG_W-1:0] replay_context_tag,

    output logic weight_valid,
    input  logic weight_ready,
    output logic signed [7:0] weight_values [0:7][0:15],
    output logic [ADDR_W-1:0] weight_k,
    output logic weight_last,
    output logic [7:0] weight_bank_enable,
    output logic [15:0] weight_n_lane_mask [0:7],
    output logic [CONTEXT_TAG_W-1:0] weight_context_tag,

    input  logic release_valid,
    output logic release_ready,
    input  logic [CONTEXT_TAG_W-1:0] release_context_tag,

    output logic [1:0] set_state [0:1],
    output logic [1:0] ready_set_mask,
    output logic fill_active,
    output logic active_fill_set,
    output logic replay_active,
    output logic active_replay_set,
    output logic [WRITE_COUNT_W-1:0] words_written,
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
  logic [7:0] set_bank_enable_q [0:1];
  logic [15:0] set_n_lane_mask_q [0:1][0:7];
  logic [CONTEXT_TAG_W-1:0] set_context_tag_q [0:1];

  logic fill_set_q;
  logic replay_set_q;
  logic [ADDR_W-1:0] write_k_q;
  logic [2:0] write_bank_q;
  logic [COUNT_W-1:0] reads_issued_q;
  logic read_pending_q;
  logic [127:0] memory_read_data [0:1][0:7];
  logic [127:0] packed_weight_q [0:7];
  logic [ADDR_W-1:0] pending_k_q;
  logic pending_last_q;

  logic memory_write_enable [0:1][0:7];
  logic memory_read_enable [0:1][0:7];
  logic [127:0] masked_write_values;
  logic [1:0] replay_match;
  logic [1:0] release_match;
  logic selected_empty_set;
  logic selected_replay_set;
  logic selected_release_set;
  logic fill_fire;
  logic write_fire;
  logic replay_fire;
  logic release_fire;
  logic weight_fire;
  logic output_slot_ready;
  logic read_stage_ready;
  logic issue_read;
  logic write_is_last_bank;
  logic write_is_final;

  function automatic logic [2:0] first_enabled_bank(
      input logic [7:0] enable_mask);
    logic found;
    begin
      first_enabled_bank = '0;
      found = 1'b0;
      for (int bank = 0; bank < 8; bank++) begin
        if (!found && enable_mask[bank]) begin
          first_enabled_bank = bank[2:0];
          found = 1'b1;
        end
      end
    end
  endfunction

  function automatic logic [2:0] next_enabled_bank(
      input logic [7:0] enable_mask,
      input logic [2:0] current_bank);
    logic found;
    begin
      next_enabled_bank = current_bank;
      found = 1'b0;
      for (int bank = 0; bank < 8; bank++) begin
        if (!found && bank > current_bank && enable_mask[bank]) begin
          next_enabled_bank = bank[2:0];
          found = 1'b1;
        end
      end
    end
  endfunction

  function automatic logic is_last_enabled_bank(
      input logic [7:0] enable_mask,
      input logic [2:0] current_bank);
    logic higher_enabled;
    begin
      higher_enabled = 1'b0;
      for (int bank = 0; bank < 8; bank++)
        if (bank > current_bank && enable_mask[bank])
          higher_enabled = 1'b1;
      is_last_enabled_bank = !higher_enabled;
    end
  endfunction

  always_comb begin
    selected_empty_set = set_state[0] != STATE_EMPTY;
    fill_ready = !fill_active &&
                 ((set_state[0] == STATE_EMPTY) ||
                  (set_state[1] == STATE_EMPTY));

    replay_match = '0;
    for (int set_index = 0; set_index < 2; set_index++) begin
      replay_match[set_index] = set_state[set_index] == STATE_READY &&
          set_k_count_q[set_index] == replay_k_count &&
          set_bank_enable_q[set_index] == replay_bank_enable &&
          set_context_tag_q[set_index] == replay_context_tag;
      for (int bank = 0; bank < 8; bank++)
        replay_match[set_index] &=
            set_n_lane_mask_q[set_index][bank] ==
            replay_n_lane_mask[bank];
    end
    selected_replay_set = !replay_match[0];
    replay_ready = !replay_active && |replay_match;

    release_match[0] = set_state[0] == STATE_READY &&
                       set_context_tag_q[0] == release_context_tag;
    release_match[1] = set_state[1] == STATE_READY &&
                       set_context_tag_q[1] == release_context_tag;
    selected_release_set = !release_match[0];
    release_ready = !replay_valid && |release_match;

    fill_fire = fill_valid && fill_ready;
    write_ready = fill_active;
    write_fire = write_valid && write_ready;
    replay_fire = replay_valid && replay_ready;
    release_fire = release_valid && release_ready;
    weight_fire = weight_valid && weight_ready;

    output_slot_ready = !weight_valid || weight_ready;
    read_stage_ready = !read_pending_q || output_slot_ready;
    issue_read = replay_active && read_stage_ready &&
                 reads_issued_q < set_k_count_q[replay_set_q];

    write_is_last_bank = is_last_enabled_bank(
        set_bank_enable_q[fill_set_q], write_bank_q);
    write_is_final = write_is_last_bank &&
        write_k_q + 1'b1 == set_k_count_q[fill_set_q];

    masked_write_values = '0;
    for (int lane = 0; lane < 16; lane++)
      if (set_n_lane_mask_q[fill_set_q][write_bank_q][lane])
        masked_write_values[lane*8 +: 8] =
            write_values[lane*8 +: 8];

    for (int set_index = 0; set_index < 2; set_index++) begin
      for (int bank = 0; bank < 8; bank++) begin
        memory_write_enable[set_index][bank] = write_fire &&
            fill_set_q == set_index && write_bank_q == bank;
        memory_read_enable[set_index][bank] = issue_read &&
            replay_set_q == set_index &&
            set_bank_enable_q[set_index][bank];
      end
    end

    write_k = write_k_q;
    write_bank_slot = write_bank_q;
    active_fill_set = fill_set_q;
    active_replay_set = replay_set_q;
    ready_set_mask[0] = set_state[0] == STATE_READY;
    ready_set_mask[1] = set_state[1] == STATE_READY;
    idle = set_state[0] == STATE_EMPTY && set_state[1] == STATE_EMPTY &&
           !fill_active && !replay_active && !weight_valid &&
           !read_pending_q;

    weight_bank_enable = set_bank_enable_q[replay_set_q];
    weight_context_tag = set_context_tag_q[replay_set_q];
    for (int bank = 0; bank < 8; bank++) begin
      weight_n_lane_mask[bank] =
          set_n_lane_mask_q[replay_set_q][bank];
      for (int lane = 0; lane < 16; lane++)
        weight_values[bank][lane] =
            $signed(packed_weight_q[bank][lane*8 +: 8]);
    end
  end

  generate
    for (genvar set_index = 0; set_index < 2; set_index++) begin : g_set
      for (genvar bank = 0; bank < 8; bank++) begin : g_bank
        alexnet_n16_weight_uram #(
            .DEPTH(DEPTH),
            .ADDR_W(ADDR_W)
        ) u_memory (
            .clk,
            .write_enable(memory_write_enable[set_index][bank]),
            .write_address(write_k_q),
            .write_data(masked_write_values),
            .read_enable(memory_read_enable[set_index][bank]),
            .read_address(reads_issued_q[ADDR_W-1:0]),
            .read_data(memory_read_data[set_index][bank])
        );
      end
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
      write_bank_q <= '0;
      words_written <= '0;
      reads_issued_q <= '0;
      read_pending_q <= 1'b0;
      pending_k_q <= '0;
      pending_last_q <= 1'b0;
      weight_valid <= 1'b0;
      weight_k <= '0;
      weight_last <= 1'b0;
      completed_fills <= '0;
      completed_replays <= '0;
      fill_done <= 1'b0;
      replay_done <= 1'b0;
      context_error <= 1'b0;
      protocol_error <= 1'b0;
      for (int set_index = 0; set_index < 2; set_index++) begin
        set_k_count_q[set_index] <= '0;
        set_bank_enable_q[set_index] <= '0;
        set_context_tag_q[set_index] <= '0;
        for (int bank = 0; bank < 8; bank++)
          set_n_lane_mask_q[set_index][bank] <= '0;
      end
      for (int bank = 0; bank < 8; bank++)
        packed_weight_q[bank] <= '0;
    end else begin
      fill_done <= 1'b0;
      replay_done <= 1'b0;

      if (weight_fire)
        weight_valid <= 1'b0;

      if (fill_fire) begin
        fill_set_q <= selected_empty_set;
        fill_active <= 1'b1;
        set_state[selected_empty_set] <= STATE_WRITING;
        set_k_count_q[selected_empty_set] <= fill_k_count;
        set_bank_enable_q[selected_empty_set] <= fill_bank_enable;
        set_context_tag_q[selected_empty_set] <= fill_context_tag;
        for (int bank = 0; bank < 8; bank++)
          set_n_lane_mask_q[selected_empty_set][bank] <=
              fill_n_lane_mask[bank];
        write_k_q <= '0;
        write_bank_q <= first_enabled_bank(fill_bank_enable);
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
          end else if (write_is_last_bank) begin
            write_k_q <= write_k_q + 1'b1;
            write_bank_q <=
                first_enabled_bank(set_bank_enable_q[fill_set_q]);
          end else begin
            write_bank_q <= next_enabled_bank(
                set_bank_enable_q[fill_set_q], write_bank_q);
          end
        end
      end

      if ((replay_valid && !replay_ready && |ready_set_mask) ||
          (release_valid && !release_ready && |ready_set_mask))
        context_error <= 1'b1;

      if (replay_fire) begin
        replay_set_q <= selected_replay_set;
        replay_active <= 1'b1;
        set_state[selected_replay_set] <= STATE_REPLAYING;
        reads_issued_q <= '0;
        read_pending_q <= 1'b0;
        weight_valid <= 1'b0;
        context_error <= 1'b0;
      end

      if (read_stage_ready) begin
        if (read_pending_q) begin
          weight_valid <= 1'b1;
          for (int bank = 0; bank < 8; bank++) begin
            if (set_bank_enable_q[replay_set_q][bank])
              packed_weight_q[bank] <=
                  memory_read_data[replay_set_q][bank];
            else
              packed_weight_q[bank] <= '0;
          end
          weight_k <= pending_k_q;
          weight_last <= pending_last_q;
        end

        read_pending_q <= issue_read;
        if (issue_read) begin
          pending_k_q <= reads_issued_q[ADDR_W-1:0];
          pending_last_q <=
              reads_issued_q + 1'b1 == set_k_count_q[replay_set_q];
          reads_issued_q <= reads_issued_q + 1'b1;
        end
      end

      if (weight_fire && weight_last) begin
        set_state[replay_set_q] <= STATE_READY;
        replay_active <= 1'b0;
        reads_issued_q <= '0;
        read_pending_q <= 1'b0;
        completed_replays <= completed_replays + 1'b1;
        replay_done <= 1'b1;
      end

      if (release_fire) begin
        set_state[selected_release_set] <= STATE_EMPTY;
        set_k_count_q[selected_release_set] <= '0;
        set_bank_enable_q[selected_release_set] <= '0;
        set_context_tag_q[selected_release_set] <= '0;
        for (int bank = 0; bank < 8; bank++)
          set_n_lane_mask_q[selected_release_set][bank] <= '0;
        context_error <= 1'b0;
      end
    end
  end

`ifndef SYNTHESIS
  initial begin
    if (DEPTH < 2 || (1 << ADDR_W) < DEPTH ||
        (1 << COUNT_W) <= DEPTH ||
        (1 << WRITE_COUNT_W) <= 8 * DEPTH)
      $fatal(1, "N128 weight ping-pong parameterization is invalid");
  end

  always_ff @(posedge clk) begin
    if (!rst) begin
      if (fill_fire &&
          (fill_k_count == 0 || fill_k_count > DEPTH ||
           fill_bank_enable == 0))
        $fatal(1, "N128 weight fill descriptor is invalid");
      if (fill_fire)
        for (int bank = 0; bank < 8; bank++) begin
          if (fill_bank_enable[bank] && fill_n_lane_mask[bank] == 0)
            $fatal(1, "enabled N16 weight bank has an empty lane mask");
          if (!fill_bank_enable[bank] && fill_n_lane_mask[bank] != 0)
            $fatal(1, "disabled N16 weight bank has a nonzero lane mask");
        end
      if (weight_fire && weight_k >= set_k_count_q[replay_set_q])
        $fatal(1, "N128 weight replay K exceeded resident count");
      if (fill_active && set_state[fill_set_q] != STATE_WRITING)
        $fatal(1, "N128 fill owner/state mismatch");
      if (replay_active && set_state[replay_set_q] != STATE_REPLAYING)
        $fatal(1, "N128 replay owner/state mismatch");
      if (fill_active && replay_active && fill_set_q == replay_set_q)
        $fatal(1, "N128 ping-pong read/write owners collided");
    end
  end
`endif

endmodule
