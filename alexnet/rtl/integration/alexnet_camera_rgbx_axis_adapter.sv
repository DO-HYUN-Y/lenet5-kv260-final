`timescale 1ns/1ps

// Board ingress adapter for a PS-preprocessed Conv1 image. Software stores one
// signed INT8 RGB pixel in every eight-byte DDR word:
//   byte 0 = channel 0, byte 1 = channel 1, byte 2 = channel 2,
//   bytes 3..7 = zero padding.
//
// A dedicated 64-bit AXI DMA therefore emits one DDR word per pixel with
// TKEEP=8'hff. The AlexNet Conv1 feeder instead needs an N8 word with exactly
// three live lanes. This adapter removes the padding lanes without changing
// the one-pixel-per-cycle ready/valid timing.
module alexnet_camera_rgbx_axis_adapter #(
    parameter int FRAME_PIXELS = 224 * 224
) (
    input  logic        aclk,
    input  logic        aresetn,

    input  logic [63:0] s_axis_tdata,
    input  logic [7:0]  s_axis_tkeep,
    input  logic        s_axis_tvalid,
    output logic        s_axis_tready,
    input  logic        s_axis_tlast,

    output logic [63:0] m_axis_tdata,
    output logic [7:0]  m_axis_tkeep,
    output logic        m_axis_tvalid,
    input  logic        m_axis_tready,
    output logic        m_axis_tlast,

    output logic        format_error
);
  localparam int COUNT_W = (FRAME_PIXELS <= 1) ? 1 : $clog2(FRAME_PIXELS);
  localparam logic [COUNT_W-1:0] LAST_PIXEL = COUNT_W'(FRAME_PIXELS - 1);

  logic [COUNT_W-1:0] pixel_index_q;
  logic transfer;

  initial begin
    if (FRAME_PIXELS < 1) begin
      $fatal(1, "FRAME_PIXELS must be positive");
    end
  end

  assign m_axis_tdata = {40'b0, s_axis_tdata[23:0]};
  assign m_axis_tkeep = 8'h07;
  assign m_axis_tvalid = s_axis_tvalid;
  assign s_axis_tready = m_axis_tready;
  assign m_axis_tlast = s_axis_tlast;
  assign transfer = s_axis_tvalid && s_axis_tready;

  always_ff @(posedge aclk) begin
    if (!aresetn) begin
      pixel_index_q <= '0;
      format_error <= 1'b0;
    end else if (transfer) begin
      if (s_axis_tkeep != 8'hff) begin
        format_error <= 1'b1;
      end
      if (s_axis_tlast != (pixel_index_q == LAST_PIXEL)) begin
        format_error <= 1'b1;
      end

      if (s_axis_tlast || (pixel_index_q == LAST_PIXEL)) begin
        pixel_index_q <= '0;
      end else begin
        pixel_index_q <= pixel_index_q + 1'b1;
      end
    end
  end

endmodule
