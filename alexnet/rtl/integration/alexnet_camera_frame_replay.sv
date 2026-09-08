`timescale 1ns/1ps

// Captures one preprocessed 224x224 RGB INT8 frame and replays it for every
// Conv1 N8 output-channel tile.  The cache removes seven repeated DDR camera
// reads and seven PS-side AXI DMA restarts from each inference.  UltraRAM is
// selected deliberately so the BRAM budget remains available for later SA
// expansion.
module alexnet_camera_frame_replay #(
    parameter int FRAME_WORDS = 224 * 224,
    parameter int REPLAY_COUNT = 8
) (
    input logic clk,
    input logic rst,
    input logic ce,
    input logic start,

    input logic s_valid,
    output logic s_ready,
    input logic [63:0] s_values,
    input logic [7:0] s_lane_mask,
    input logic s_last,

    output logic m_valid,
    input logic m_ready,
    output logic [63:0] m_values,
    output logic [7:0] m_lane_mask,
    output logic m_last,

    output logic frame_valid,
    output logic busy,
    output logic fault,
    output logic [$clog2(REPLAY_COUNT + 1)-1:0] completed_replays
);
  localparam int ADDR_W = FRAME_WORDS <= 1 ? 1 : $clog2(FRAME_WORDS);
  localparam int REPLAY_W = REPLAY_COUNT <= 1 ? 1 : $clog2(REPLAY_COUNT);
  localparam logic [ADDR_W-1:0] LAST_ADDR = ADDR_W'(FRAME_WORDS - 1);
  localparam logic [REPLAY_W-1:0] LAST_REPLAY =
      REPLAY_W'(REPLAY_COUNT - 1);

  (* ram_style = "ultra" *) logic [63:0] frame_memory [0:FRAME_WORDS-1];

  logic capture_active_q;
  logic [ADDR_W-1:0] capture_address_q;
  logic [ADDR_W-1:0] read_address_q;
  logic [REPLAY_W-1:0] issued_replay_q;
  logic all_reads_issued_q;
  logic memory_valid_q, memory_last_q;
  logic [63:0] memory_values_q;
  logic output_valid_q, output_last_q;
  logic [63:0] output_values_q;

  logic input_fire, output_fire, output_slot_available;
  logic memory_slot_available, issue_read;
  logic input_is_final_word, input_shape_valid;

  assign input_fire = s_valid && s_ready;
  assign output_fire = m_valid && m_ready;
  assign input_is_final_word = capture_address_q == LAST_ADDR;
  assign input_shape_valid = s_lane_mask == 8'h07 &&
                             s_last == input_is_final_word;
  assign output_slot_available = !output_valid_q || m_ready;
  assign memory_slot_available = !memory_valid_q || output_slot_available;
  assign issue_read = ce && frame_valid && !all_reads_issued_q &&
                      memory_slot_available;

  assign s_ready = ce && capture_active_q && !frame_valid && !fault;
  assign m_valid = ce && output_valid_q;
  assign m_values = output_values_q;
  assign m_lane_mask = 8'h07;
  assign m_last = output_last_q;
  assign busy = capture_active_q || memory_valid_q || output_valid_q ||
                (frame_valid && !all_reads_issued_q);

  always_ff @(posedge clk) begin
    if (rst) begin
      capture_active_q <= 1'b0;
      capture_address_q <= '0;
      read_address_q <= '0;
      issued_replay_q <= '0;
      all_reads_issued_q <= 1'b0;
      memory_valid_q <= 1'b0;
      memory_last_q <= 1'b0;
      output_valid_q <= 1'b0;
      output_last_q <= 1'b0;
      output_values_q <= '0;
      frame_valid <= 1'b0;
      fault <= 1'b0;
      completed_replays <= '0;
    end else if (start) begin
      capture_active_q <= 1'b1;
      capture_address_q <= '0;
      read_address_q <= '0;
      issued_replay_q <= '0;
      all_reads_issued_q <= 1'b0;
      memory_valid_q <= 1'b0;
      memory_last_q <= 1'b0;
      output_valid_q <= 1'b0;
      output_last_q <= 1'b0;
      frame_valid <= 1'b0;
      fault <= 1'b0;
      completed_replays <= '0;
    end else if (ce) begin
      if (input_fire) begin
        if (!input_shape_valid) begin
          capture_active_q <= 1'b0;
          fault <= 1'b1;
        end else begin
          frame_memory[capture_address_q] <= s_values;
          if (input_is_final_word) begin
            capture_active_q <= 1'b0;
            frame_valid <= 1'b1;
          end else begin
            capture_address_q <= capture_address_q + 1'b1;
          end
        end
      end

      // Keep a fabric output register after the inferred UltraRAM read
      // register.  This cuts the long cascaded-URAM-to-Conv1 BRAM path while
      // the two-entry elastic pipeline still sustains one word per cycle.
      if (output_slot_available) begin
        output_valid_q <= memory_valid_q;
        if (memory_valid_q) begin
          output_values_q <= memory_values_q;
          output_last_q <= memory_last_q;
        end
      end

      if (issue_read) begin
        memory_values_q <= frame_memory[read_address_q];
        memory_last_q <= read_address_q == LAST_ADDR;
        memory_valid_q <= 1'b1;
        if (read_address_q == LAST_ADDR) begin
          read_address_q <= '0;
          if (issued_replay_q == LAST_REPLAY) begin
            all_reads_issued_q <= 1'b1;
          end else begin
            issued_replay_q <= issued_replay_q + 1'b1;
          end
        end else begin
          read_address_q <= read_address_q + 1'b1;
        end
      end else if (output_slot_available) begin
        memory_valid_q <= 1'b0;
      end

      if (output_fire && output_last_q)
        completed_replays <= completed_replays + 1'b1;
    end
  end

`ifndef SYNTHESIS
  initial begin
    if (FRAME_WORDS < 1) $fatal(1, "FRAME_WORDS must be positive");
    if (REPLAY_COUNT < 1) $fatal(1, "REPLAY_COUNT must be positive");
  end

  always_ff @(posedge clk) begin
    if (!rst && ce) begin
      if (completed_replays > REPLAY_COUNT)
        $fatal(1, "camera frame replay completion overflow");
      if (frame_valid && capture_active_q)
        $fatal(1, "camera frame cache cannot capture and replay together");
    end
  end
`endif
endmodule
