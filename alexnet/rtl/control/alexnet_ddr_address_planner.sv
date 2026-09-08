`timescale 1ns/1ps

// Translate fixed AlexNet layer coordinates into physical DDR descriptors.
// Base addresses are programmable so the later AXI-Lite/PS shell owns the
// memory map. Activations use two reused N8-tile-major buffers; packed weights
// and 16-byte quantization records are contiguous across Conv1..FC8.
//
// request_kind: 0 activation read, 1 packed-weight read,
//               2 parameter-record read, 3 result write.
// buffer_id:    0 camera/input, 1 activation A, 2 activation B,
//               3 weights, 4 parameters, 5 final output.
module alexnet_ddr_address_planner (
    input logic clk,
    input logic rst,

    input logic [63:0] input_base,
    input logic [63:0] activation_a_base,
    input logic [63:0] activation_b_base,
    input logic [63:0] weights_base,
    input logic [63:0] parameters_base,
    input logic [63:0] final_output_base,

    input  logic request_valid,
    output logic request_ready,
    input  logic [2:0] request_kind,
    input  logic [3:0] request_layer_id,
    input  logic [15:0] request_n_base,
    input  logic [7:0] request_chunk_index,
    input  logic [13:0] request_k_offset,
    input  logic [9:0] request_k_count,
    input  logic [12:0] request_word_count,
    input  logic [15:0] request_byte_count,
    input  logic [2:0] request_m_count,
    input  logic [15:0] request_tag,

    output logic descriptor_valid,
    input  logic descriptor_ready,
    output logic descriptor_error,
    output logic [2:0] descriptor_kind,
    output logic [2:0] descriptor_buffer_id,
    output logic [3:0] descriptor_layer_id,
    output logic [63:0] descriptor_address,
    output logic [15:0] descriptor_byte_count,
    output logic [12:0] descriptor_word_count,
    output logic [15:0] descriptor_tag,

    output logic busy,
    output logic fault,
    output logic [31:0] accepted_requests,
    output logic [31:0] rejected_requests,
    output logic [31:0] completed_descriptors
);
  localparam logic [2:0] KIND_ACTIVATION = 0;
  localparam logic [2:0] KIND_WEIGHT = 1;
  localparam logic [2:0] KIND_PARAMETER = 2;
  localparam logic [2:0] KIND_RESULT = 3;

  logic descriptor_valid_q;
  logic stage_valid_q;
  logic stage_error_q;
  logic [2:0] stage_kind_q, stage_buffer_q;
  logic [3:0] stage_layer_q;
  logic [63:0] stage_base_q, stage_offset_q;
  logic [15:0] stage_bytes_q, stage_tag_q;
  logic [12:0] stage_words_q;
  logic fault_q;
  logic request_fire, descriptor_fire;
  logic fields_valid;
  logic [2:0] selected_buffer;
  logic [63:0] selected_base;
  (* use_dsp = "no" *) logic [63:0] byte_offset;
  logic [12:0] expected_words;
  logic [15:0] expected_bytes;
  logic [13:0] total_k;
  logic [12:0] total_n;
  logic [13:0] layer_k_depth;
  logic [5:0] input_chunks;
  logic [12:0] input_spatial_words;
  logic [11:0] stored_spatial_words;
  logic [31:0] weight_layer_offset;
  logic [31:0] parameter_layer_offset;
  logic [9:0] n8_tiles;
  logic [13:0] chunk_k_words;
  logic [15:0] n8_index;
  logic base_alignment_valid;

  function automatic logic [63:0] conv_activation_offset(
      input logic [3:0] layer,
      input logic [7:0] chunk);
    logic [63:0] x;
    begin
      x = chunk;
      case (layer)
        2: conv_activation_offset = (x << 12) + (x << 10) + (x << 9) +
                                    (x << 7) + (x << 6) + (x << 3); // 5832
        3,4,5: conv_activation_offset = (x << 10) + (x << 8) +
                                          (x << 6) + (x << 3); // 1352
        default: conv_activation_offset = 0;
      endcase
    end
  endfunction

  function automatic logic [63:0] conv_weight_offset(
      input logic [3:0] layer,
      input logic [15:0] tile,
      input logic [7:0] chunk);
    logic [63:0] t;
    logic [63:0] c;
    begin
      t = tile;
      c = chunk;
      case (layer)
        1: conv_weight_offset = (t << 11) + (t << 9) + (t << 8) +
                                (t << 6) + (t << 4) + (t << 3); // 2904
        2: conv_weight_offset = (t << 13) + (t << 12) + (t << 9) +
                                (c << 10) + (c << 9) + (c << 6);
        3: conv_weight_offset = (t << 13) + (t << 12) + (t << 10) +
                                (t << 9) + (c << 9) + (c << 6);
        4: conv_weight_offset = (t << 14) + (t << 13) + (t << 11) +
                                (t << 10) + (c << 9) + (c << 6);
        5: conv_weight_offset = (t << 14) + (t << 11) +
                                (c << 9) + (c << 6);
        default: conv_weight_offset = 0;
      endcase
    end
  endfunction

  function automatic logic [63:0] conv_result_offset(
      input logic [3:0] layer,
      input logic [15:0] tile);
    logic [63:0] t;
    begin
      t = tile;
      case (layer)
        1: conv_result_offset = (t << 12) + (t << 10) + (t << 9) +
                                (t << 7) + (t << 6) + (t << 3); // 5832
        2,3,4: conv_result_offset = (t << 10) + (t << 8) +
                                      (t << 6) + (t << 3); // 1352
        5: conv_result_offset = (t << 8) + (t << 5); // 288
        default: conv_result_offset = 0;
      endcase
    end
  endfunction

  function automatic logic [63:0] fc_weight_offset(
      input logic [3:0] layer,
      input logic [15:0] tile,
      input logic [13:0] k_offset);
    logic [63:0] t;
    logic [63:0] k;
    begin
      t = tile;
      k = k_offset;
      case (layer)
        6: fc_weight_offset = (t << 16) + (t << 13) + (k << 3);
        7,8: fc_weight_offset = (t << 15) + (k << 3);
        default: fc_weight_offset = 0;
      endcase
    end
  endfunction

  assign request_ready = !stage_valid_q && !descriptor_valid_q;
  assign request_fire = request_valid && request_ready;
  assign descriptor_valid = descriptor_valid_q;
  assign descriptor_fire = descriptor_valid && descriptor_ready;
  assign busy = stage_valid_q || descriptor_valid_q;
  assign fault = fault_q;
  assign n8_index = request_n_base >> 3;
  assign base_alignment_valid = input_base[6:0] == 0 &&
      activation_a_base[6:0] == 0 && activation_b_base[6:0] == 0 &&
      weights_base[6:0] == 0 && parameters_base[6:0] == 0 &&
      final_output_base[6:0] == 0;

  always_comb begin
    total_k = 0;
    total_n = 0;
    layer_k_depth = 0;
    input_chunks = 0;
    input_spatial_words = 0;
    stored_spatial_words = 0;
    weight_layer_offset = 0;
    parameter_layer_offset = 0;
    n8_tiles = 0;
    chunk_k_words = 0;
    case (request_layer_id)
      1: begin
        total_k = 363; total_n = 64; layer_k_depth = 363;
        input_chunks = 1; input_spatial_words = 0;
        stored_spatial_words = 729; n8_tiles = 8;
        weight_layer_offset = 0; parameter_layer_offset = 0;
        chunk_k_words = 363;
      end
      2: begin
        total_k = 1600; total_n = 192; layer_k_depth = 1600;
        input_chunks = 8; input_spatial_words = 729;
        stored_spatial_words = 169; n8_tiles = 24;
        weight_layer_offset = 23232; parameter_layer_offset = 1024;
        chunk_k_words = 200;
      end
      3: begin
        total_k = 1728; total_n = 384; layer_k_depth = 1728;
        input_chunks = 24; input_spatial_words = 169;
        stored_spatial_words = 169; n8_tiles = 48;
        weight_layer_offset = 330432; parameter_layer_offset = 4096;
        chunk_k_words = 72;
      end
      4: begin
        total_k = 3456; total_n = 256; layer_k_depth = 3456;
        input_chunks = 48; input_spatial_words = 169;
        stored_spatial_words = 169; n8_tiles = 32;
        weight_layer_offset = 993984; parameter_layer_offset = 10240;
        chunk_k_words = 72;
      end
      5: begin
        total_k = 2304; total_n = 256; layer_k_depth = 2304;
        input_chunks = 32; input_spatial_words = 169;
        stored_spatial_words = 36; n8_tiles = 32;
        weight_layer_offset = 1878720; parameter_layer_offset = 14336;
        chunk_k_words = 72;
      end
      6: begin
        total_k = 9216; total_n = 4096; layer_k_depth = 9216;
        n8_tiles = 512; weight_layer_offset = 2468544;
        parameter_layer_offset = 18432;
      end
      7: begin
        total_k = 4096; total_n = 4096; layer_k_depth = 4096;
        n8_tiles = 512; weight_layer_offset = 40217280;
        parameter_layer_offset = 83968;
      end
      8: begin
        total_k = 4096; total_n = 1000; layer_k_depth = 4096;
        n8_tiles = 125; weight_layer_offset = 56994496;
        parameter_layer_offset = 149504;
      end
      default: begin end
    endcase
  end

  always_comb begin
    fields_valid = base_alignment_valid && request_layer_id >= 1 &&
                   request_layer_id <= 8 && request_kind <= KIND_RESULT &&
                   request_n_base[2:0] == 0 && n8_index < n8_tiles;
    selected_buffer = 0;
    selected_base = input_base;
    byte_offset = 0;
    expected_words = 0;
    expected_bytes = 0;

    case (request_kind)
      KIND_ACTIVATION: begin
        if (request_layer_id >= 2 && request_layer_id <= 5) begin
          selected_buffer = request_layer_id[0] ? 3'd2 : 3'd1;
          selected_base = request_layer_id[0] ? activation_b_base :
                                                activation_a_base;
          byte_offset = conv_activation_offset(request_layer_id,
                                               request_chunk_index);
          expected_words = input_spatial_words;
          expected_bytes = input_spatial_words << 3;
          fields_valid = fields_valid && request_chunk_index < input_chunks;
        end else if (request_layer_id == 7 || request_layer_id == 8) begin
          selected_buffer = request_layer_id == 7 ? 3'd2 : 3'd1;
          selected_base = request_layer_id == 7 ? activation_b_base :
                                                  activation_a_base;
          byte_offset = request_k_offset;
          expected_words = request_k_count >> 3;
          expected_bytes = request_k_count;
          fields_valid = fields_valid && request_m_count == 1 &&
              request_k_count != 0 && request_k_count[2:0] == 0 &&
              request_k_offset[2:0] == 0 &&
              request_k_offset + request_k_count <= total_k;
        end else begin
          // Conv1 is direct camera streaming and FC6 is internally flattened.
          fields_valid = 1'b0;
        end
      end
      KIND_WEIGHT: begin
        selected_buffer = 3;
        selected_base = weights_base;
        if (request_layer_id <= 5) begin
          byte_offset = weight_layer_offset +
              conv_weight_offset(request_layer_id, n8_index,
                                 request_chunk_index);
          expected_words = chunk_k_words;
          expected_bytes = chunk_k_words << 3;
          fields_valid = fields_valid && request_chunk_index < input_chunks;
        end else begin
          byte_offset = weight_layer_offset +
              fc_weight_offset(request_layer_id, n8_index, request_k_offset);
          expected_words = request_k_count;
          expected_bytes = request_k_count << 3;
          fields_valid = fields_valid && request_k_count != 0 &&
              request_k_offset + request_k_count <= total_k;
        end
      end
      KIND_PARAMETER: begin
        selected_buffer = 4;
        selected_base = parameters_base;
        byte_offset = parameter_layer_offset +
                      (64'(request_n_base) << 4);
        expected_words = 16;
        expected_bytes = 128;
      end
      KIND_RESULT: begin
        if (request_layer_id <= 5) begin
          selected_buffer = request_layer_id[0] ? 3'd1 : 3'd2;
          selected_base = request_layer_id[0] ? activation_a_base :
                                                activation_b_base;
          byte_offset = conv_result_offset(request_layer_id, n8_index);
          expected_words = stored_spatial_words;
          expected_bytes = stored_spatial_words << 3;
        end else begin
          selected_buffer = request_layer_id == 6 ? 3'd2 :
                            request_layer_id == 7 ? 3'd1 : 3'd5;
          selected_base = request_layer_id == 6 ? activation_b_base :
                          request_layer_id == 7 ? activation_a_base :
                                                  final_output_base;
          byte_offset = request_n_base;
          expected_words = request_m_count;
          expected_bytes = {13'b0, request_m_count} << 3;
          fields_valid = fields_valid && request_m_count == 1;
        end
      end
      default: fields_valid = 1'b0;
    endcase

    fields_valid = fields_valid && request_word_count == expected_words &&
                   request_byte_count == expected_bytes;
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      descriptor_valid_q <= 1'b0;
      stage_valid_q <= 1'b0;
      stage_error_q <= 1'b0;
      stage_kind_q <= 0;
      stage_buffer_q <= 0;
      stage_layer_q <= 0;
      stage_base_q <= 0;
      stage_offset_q <= 0;
      stage_bytes_q <= 0;
      stage_words_q <= 0;
      stage_tag_q <= 0;
      descriptor_error <= 1'b0;
      descriptor_kind <= 0;
      descriptor_buffer_id <= 0;
      descriptor_layer_id <= 0;
      descriptor_address <= 0;
      descriptor_byte_count <= 0;
      descriptor_word_count <= 0;
      descriptor_tag <= 0;
      fault_q <= 1'b0;
      accepted_requests <= 0;
      rejected_requests <= 0;
      completed_descriptors <= 0;
    end else begin
      if (descriptor_fire) begin
        descriptor_valid_q <= 1'b0;
        completed_descriptors <= completed_descriptors + 1'b1;
      end

      // The first stage registers the layer/coordinate decode and shift/add
      // offset. The second stage performs only the physical-base addition,
      // keeping the programmable 64-bit address path inside 200 MHz.
      if (stage_valid_q && !descriptor_valid_q) begin
        stage_valid_q <= 1'b0;
        descriptor_valid_q <= 1'b1;
        descriptor_error <= stage_error_q;
        descriptor_kind <= stage_kind_q;
        descriptor_buffer_id <= stage_buffer_q;
        descriptor_layer_id <= stage_layer_q;
        descriptor_address <= stage_base_q + stage_offset_q;
        descriptor_byte_count <= stage_bytes_q;
        descriptor_word_count <= stage_words_q;
        descriptor_tag <= stage_tag_q;
      end
      if (request_fire) begin
        stage_valid_q <= 1'b1;
        stage_error_q <= !fields_valid;
        stage_kind_q <= request_kind;
        stage_buffer_q <= selected_buffer;
        stage_layer_q <= request_layer_id;
        stage_base_q <= selected_base;
        stage_offset_q <= byte_offset;
        stage_bytes_q <= expected_bytes;
        stage_words_q <= expected_words;
        stage_tag_q <= request_tag;
        if (fields_valid)
          accepted_requests <= accepted_requests + 1'b1;
        else begin
          rejected_requests <= rejected_requests + 1'b1;
          fault_q <= 1'b1;
        end
      end
    end
  end

`ifndef SYNTHESIS
  always_ff @(posedge clk) begin
    if (!rst && descriptor_valid && !descriptor_error &&
        (descriptor_address[2:0] != 0 || descriptor_byte_count[2:0] != 0))
      $fatal(1, "DDR planner emitted an unaligned descriptor");
  end
`endif
endmodule
