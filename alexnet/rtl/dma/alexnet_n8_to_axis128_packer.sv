`timescale 1ns/1ps

// Pack ordered 64-bit N8 words into a low-word-first 128-bit AXI4-Stream.
// Packet boundaries are preserved. An odd final word occupies only the low
// half and produces tkeep=16'h00ff.
module alexnet_n8_to_axis128_packer (
    input logic clk,
    input logic rst,
    input logic clear_error,

    input  logic s_valid,
    output logic s_ready,
    input  logic [63:0] s_values,
    input  logic [7:0] s_byte_keep,
    input  logic s_last,

    output logic [127:0] m_axis_tdata,
    output logic [15:0] m_axis_tkeep,
    output logic m_axis_tvalid,
    input  logic m_axis_tready,
    output logic m_axis_tlast,

    output logic busy,
    output logic protocol_error
);
  logic [1:0] word_count_q;
  logic [63:0] low_values_q, high_values_q;
  logic [7:0] low_keep_q, high_keep_q;
  logic low_last_q, high_last_q;
  logic error_q;
  logic word_fire;
  logic axis_fire;

  // Do not accept a new packet word in the same cycle as an output beat.
  // This intentionally registers the service boundary and keeps the packer
  // off the already-tight shared-compute timing paths.
  assign m_axis_tvalid = word_count_q == 2 ||
                         (word_count_q == 1 && low_last_q);
  assign s_ready = word_count_q < 2 && !m_axis_tvalid;
  assign word_fire = s_valid && s_ready;
  assign axis_fire = m_axis_tvalid && m_axis_tready;
  assign m_axis_tdata = {word_count_q == 2 ? high_values_q : 64'b0,
                         low_values_q};
  assign m_axis_tkeep = {word_count_q == 2 ? high_keep_q : 8'b0,
                         low_keep_q};
  assign m_axis_tlast = word_count_q == 2 ? high_last_q : low_last_q;
  assign busy = word_count_q != 0;
  assign protocol_error = error_q;

  always_ff @(posedge clk) begin
    if (rst) begin
      word_count_q <= 0;
      low_values_q <= 0;
      high_values_q <= 0;
      low_keep_q <= 0;
      high_keep_q <= 0;
      low_last_q <= 1'b0;
      high_last_q <= 1'b0;
      error_q <= 1'b0;
    end else begin
      if (clear_error)
        error_q <= 1'b0;

      if (axis_fire) begin
        word_count_q <= 0;
        low_last_q <= 1'b0;
        high_last_q <= 1'b0;
      end

      if (word_fire) begin
        if (s_byte_keep == 0 || (!s_last && s_byte_keep != 8'hff))
          error_q <= 1'b1;
        if (word_count_q == 0) begin
          low_values_q <= s_values;
          low_keep_q <= s_byte_keep;
          low_last_q <= s_last;
          word_count_q <= 1;
        end else begin
          high_values_q <= s_values;
          high_keep_q <= s_byte_keep;
          high_last_q <= s_last;
          word_count_q <= 2;
        end
      end
    end
  end

`ifndef SYNTHESIS
  always_ff @(posedge clk) begin
    if (!rst && word_fire && word_count_q == 1 && low_last_q)
      $fatal(1, "N8-to-AXIS packer accepted data after a packet boundary");
  end
`endif
endmodule
