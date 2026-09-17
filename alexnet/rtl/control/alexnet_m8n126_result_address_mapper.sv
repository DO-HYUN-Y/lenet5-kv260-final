`timescale 1ns/1ps

// Map one requantized MxN8 result slice into an N8-tile-major tensor.
//
// A slice contains result_m_count spatial positions and eight output channels.
// The byte layout is:
//   [N8 tile][spatial position][8 signed INT8 lanes]
//
// The M8xN126 payload emits N8 slices in physical-bank order.  Conv1/2 split
// mode can emit the same N8 tile twice, first for m_base and then m_base+8;
// result_m_base already includes that group offset before it reaches here.
module alexnet_m8n126_result_address_mapper (
    input  logic [31:0] result_base,
    input  logic [3:0]  layer_id,
    input  logic [12:0] result_m_base,
    input  logic [15:0] result_n_base,
    input  logic [3:0]  result_m_count,

    output logic [31:0] result_address,
    output logic [25:0] result_byte_count,
    output logic [12:0] layer_spatial_count,
    output logic descriptor_error
);
  logic [12:0] layer_output_channels;
  logic [31:0] n8_index;
  (* use_dsp = "no" *) logic [31:0] n8_byte_offset;
  logic [31:0] m_byte_offset;
  logic [32:0] address_sum;
  logic [13:0] m_end;

  always_comb begin
    layer_output_channels = 0;
    layer_spatial_count = 0;
    case (layer_id)
      1: begin
        layer_output_channels = 64;
        layer_spatial_count = 3025;
      end
      2: begin
        layer_output_channels = 192;
        layer_spatial_count = 729;
      end
      3: begin
        layer_output_channels = 384;
        layer_spatial_count = 169;
      end
      4, 5: begin
        layer_output_channels = 256;
        layer_spatial_count = 169;
      end
      6, 7: begin
        layer_output_channels = 4096;
        layer_spatial_count = 1;
      end
      8: begin
        layer_output_channels = 1000;
        layer_spatial_count = 1;
      end
      default: begin end
    endcase

    n8_index = {16'd0, result_n_base} >> 3;
    // Constant shift/add forms keep the address path out of DSP48E2s.
    case (layer_id)
      1: n8_byte_offset = (n8_index << 14) + (n8_index << 12) +
          (n8_index << 11) + (n8_index << 10) + (n8_index << 9) +
          (n8_index << 7) + (n8_index << 3); // 3025 * 8 = 24200
      2: n8_byte_offset = (n8_index << 12) + (n8_index << 10) +
          (n8_index << 9) + (n8_index << 7) + (n8_index << 6) +
          (n8_index << 3); // 729 * 8 = 5832
      3, 4, 5: n8_byte_offset = (n8_index << 10) +
          (n8_index << 8) + (n8_index << 6) +
          (n8_index << 3); // 169 * 8 = 1352
      6, 7, 8: n8_byte_offset = n8_index << 3;
      default: n8_byte_offset = 0;
    endcase

    m_byte_offset = {16'd0, result_m_base, 3'b000};
    address_sum = {1'b0, result_base} + {1'b0, n8_byte_offset} +
                  {1'b0, m_byte_offset};
    m_end = {1'b0, result_m_base} + result_m_count;
    result_address = address_sum[31:0];
    result_byte_count = {19'd0, result_m_count, 3'b000};

    descriptor_error = layer_id < 1 || layer_id > 8 ||
        result_base[2:0] != 0 || result_n_base[2:0] != 0 ||
        result_n_base >= layer_output_channels || result_m_count == 0 ||
        result_m_count > 8 || m_end > layer_spatial_count ||
        address_sum[32];
  end

`ifndef SYNTHESIS
  always_comb begin
    if (!descriptor_error && result_address[2:0] != 0)
      $error("M8N126 result mapper emitted a non-eight-byte address");
  end
`endif

endmodule
