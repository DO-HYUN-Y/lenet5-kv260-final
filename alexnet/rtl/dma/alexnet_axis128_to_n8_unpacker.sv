`timescale 1ns/1ps

// Split one 128-bit AXI4-Stream payload into ordered 64-bit N8 words.
// The result egress always places the first word in the low half. A packet
// may end with either a full beat or one low-half word (tkeep=16'h00ff).
module alexnet_axis128_to_n8_unpacker (
    input logic clk,
    input logic rst,
    input logic clear_error,

    input  logic [127:0] s_axis_tdata,
    input  logic [15:0] s_axis_tkeep,
    input  logic s_axis_tvalid,
    output logic s_axis_tready,
    input  logic s_axis_tlast,

    output logic m_valid,
    input  logic m_ready,
    output logic [63:0] m_values,
    output logic [7:0] m_byte_keep,
    output logic m_last,

    output logic busy,
    output logic protocol_error
);
  logic beat_valid_q;
  logic high_word_q;
  logic [127:0] data_q;
  logic [15:0] keep_q;
  logic last_q;
  logic error_q;
  logic axis_fire;
  logic word_fire;
  logic keep_valid;

  assign s_axis_tready = !beat_valid_q;
  assign axis_fire = s_axis_tvalid && s_axis_tready;
  assign m_valid = beat_valid_q;
  assign m_values = high_word_q ? data_q[127:64] : data_q[63:0];
  assign m_byte_keep = high_word_q ? keep_q[15:8] : keep_q[7:0];
  assign m_last = last_q && (high_word_q || keep_q[15:8] == 0);
  assign word_fire = m_valid && m_ready;
  assign busy = beat_valid_q;
  assign protocol_error = error_q;
  assign keep_valid = s_axis_tkeep == 16'hffff ||
                      (s_axis_tlast && s_axis_tkeep == 16'h00ff);

  always_ff @(posedge clk) begin
    if (rst) begin
      beat_valid_q <= 1'b0;
      high_word_q <= 1'b0;
      data_q <= 0;
      keep_q <= 0;
      last_q <= 1'b0;
      error_q <= 1'b0;
    end else begin
      if (clear_error)
        error_q <= 1'b0;

      if (axis_fire) begin
        beat_valid_q <= 1'b1;
        high_word_q <= 1'b0;
        data_q <= s_axis_tdata;
        keep_q <= s_axis_tkeep;
        last_q <= s_axis_tlast;
        if (!keep_valid || (!s_axis_tlast && s_axis_tkeep != 16'hffff))
          error_q <= 1'b1;
      end

      if (word_fire) begin
        if (!high_word_q && keep_q[15:8] != 0)
          high_word_q <= 1'b1;
        else begin
          beat_valid_q <= 1'b0;
          high_word_q <= 1'b0;
        end
      end
    end
  end

`ifndef SYNTHESIS
  always_ff @(posedge clk) begin
    if (!rst && m_valid && m_byte_keep == 0)
      $fatal(1, "AXIS-to-N8 unpacker exposed an empty word");
  end
`endif
endmodule
