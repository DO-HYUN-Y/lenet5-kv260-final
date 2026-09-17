`timescale 1ns/1ps

// Cache one completed activation tensor from DDR and assemble the exact
// K-major M16 stream consumed by alexnet_m16_patch_pingpong.
//
// DDR layout is [N8 channel tile][spatial position][8 INT8 lanes].  Conv2-5
// gather windows from that layout.  FC6 converts Pool5's tiled 256x6x6 tensor
// to channel-major K order; FC7/8 read their already-linear N8 tensors.
// Loading once per layer removes the legacy pretransposed patch-tape ABI.
module alexnet_m8n126_activation_patch_service #(
    parameter int MAX_CACHE_BEATS = 4056
) (
    input logic clk,
    input logic rst,

    input  logic request_valid,
    output logic request_ready,
    input  logic [3:0] request_layer_id,
    input  logic [12:0] request_m_base,
    input  logic [13:0] request_k_offset,
    input  logic [12:0] request_k_count,
    input  logic [15:0] request_m_lane_mask,
    input  logic [15:0] request_context_tag,
    input  logic [31:0] activation_a_base,
    input  logic [31:0] activation_b_base,

    output logic dma_command_valid,
    input  logic dma_command_ready,
    output logic [31:0] dma_command_address,
    output logic [25:0] dma_command_length,
    input  logic dma_armed,
    input  logic dma_done,
    input  logic dma_error,

    input  logic [127:0] s_axis_tdata,
    input  logic [15:0] s_axis_tkeep,
    input  logic s_axis_tvalid,
    output logic s_axis_tready,
    input  logic s_axis_tlast,

    output logic [127:0] patch_axis_tdata,
    output logic patch_axis_tvalid,
    input  logic patch_axis_tready,
    output logic patch_axis_tlast,

    output logic busy,
    output logic fault,
    output logic cache_load_active,
    output logic [3:0] cached_layer_id,
    output logic [15:0] active_context_tag,
    output logic [7:0] active_m_count,
    output logic [31:0] cache_loads,
    output logic [31:0] completed_patches,
    output logic [31:0] emitted_patch_words
);
  typedef enum logic [3:0] {
    ST_IDLE,
    ST_LOAD_COMMAND,
    ST_LOAD_ARM,
    ST_LOAD_STREAM,
    ST_LOAD_DRAIN,
    ST_INIT_POSITION,
    ST_PREPARE_WORD,
    ST_ADDRESS,
    ST_ASSEMBLE,
    ST_CAPTURE,
    ST_OUTPUT,
    ST_FAILED
  } state_t;

  state_t state_q;
  logic fault_q, cache_valid_q, dma_done_seen_q;
  logic [3:0] layer_id_q;
  logic [12:0] k_count_q, local_k_q;
  logic [15:0] m_lane_mask_q, context_tag_q;
  logic [4:0] m_count_q, m_lane_index_q;

  logic [11:0] cache_write_index_q;
  logic [11:0] cache_beat_index_q;
  logic [127:0] cache_read_data_q;
  logic [3:0] cache_read_byte_q;
  logic [127:0] patch_word_q;

  logic [9:0] conv_channel_q;
  logic [2:0] conv_kx_q, conv_ky_q;
  logic [12:0] position_remainder_q;
  logic [7:0] base_output_y_q, base_output_x_q;
  logic [7:0] current_output_y_q, current_output_x_q;
  logic [8:0] fc_channel_q;
  logic [5:0] fc_spatial_q;
  logic [12:0] fc_linear_q;

  (* ram_style = "block" *) logic [127:0] activation_cache
      [0:MAX_CACHE_BEATS-1];

  logic [7:0] input_h, input_w, output_w;
  logic [12:0] input_spatial;
  logic [9:0] input_channels;
  logic [3:0] kernel, padding;
  logic [31:0] configured_base;
  logic [25:0] configured_bytes;
  logic [11:0] configured_beats;
  logic layer_is_conv, layer_is_fc;

  logic signed [9:0] input_y_signed, input_x_signed;
  logic coordinate_valid, lane_active, cache_read_valid;
  logic [31:0] spatial_index;
  logic [31:0] cache_word_index;
  logic [9:0] conv_input_y, conv_input_x;
  logic [6:0] conv_channel_tile;
  logic [5:0] fc_channel_tile;
  logic [31:0] conv_channel_tile_wide, fc_channel_tile_wide;
  logic [11:0] cache_beat_index;
  logic [3:0] cache_byte_index;

  logic request_fire, command_fire, input_fire, patch_fire;
  logic expected_input_last, request_fields_valid;
  logic [4:0] requested_m_count;

  function automatic logic [4:0] popcount16(input logic [15:0] value);
    logic [4:0] count;
    begin
      count = 0;
      for (int bit_index = 0; bit_index < 16; bit_index++)
        count = count + value[bit_index];
      return count;
    end
  endfunction

  assign requested_m_count = popcount16(request_m_lane_mask);
  assign request_ready = state_q == ST_IDLE && !fault_q;
  assign request_fire = request_valid && request_ready;
  assign busy = state_q != ST_IDLE;
  assign fault = fault_q || dma_error;
  assign cache_load_active = state_q == ST_LOAD_COMMAND ||
      state_q == ST_LOAD_ARM || state_q == ST_LOAD_STREAM ||
      state_q == ST_LOAD_DRAIN;
  assign active_context_tag = context_tag_q;
  assign active_m_count = {3'd0, m_count_q};

  assign dma_command_valid = state_q == ST_LOAD_COMMAND;
  assign dma_command_address = configured_base;
  assign dma_command_length = configured_bytes;
  assign command_fire = dma_command_valid && dma_command_ready;
  assign s_axis_tready = (state_q == ST_LOAD_ARM ||
                          state_q == ST_LOAD_STREAM) &&
                         cache_write_index_q < configured_beats;
  assign input_fire = s_axis_tvalid && s_axis_tready;
  assign expected_input_last = cache_write_index_q + 1'b1 ==
                               configured_beats;

  assign patch_axis_tdata = patch_word_q;
  assign patch_axis_tvalid = state_q == ST_OUTPUT;
  assign patch_axis_tlast = local_k_q + 1'b1 == k_count_q;
  assign patch_fire = patch_axis_tvalid && patch_axis_tready;

  always_comb begin
    input_h = 0;
    input_w = 0;
    output_w = 0;
    input_spatial = 0;
    input_channels = 0;
    kernel = 0;
    padding = 0;
    configured_base = 0;
    configured_bytes = 0;
    layer_is_conv = layer_id_q >= 2 && layer_id_q <= 5;
    layer_is_fc = layer_id_q >= 6 && layer_id_q <= 8;
    case (layer_id_q)
      2: begin
        input_h = 27; input_w = 27; output_w = 27;
        input_spatial = 729; input_channels = 64;
        kernel = 5; padding = 2;
        configured_base = activation_a_base;
        configured_bytes = 26'd46656;
      end
      3: begin
        input_h = 13; input_w = 13; output_w = 13;
        input_spatial = 169; input_channels = 192;
        kernel = 3; padding = 1;
        configured_base = activation_b_base;
        configured_bytes = 26'd32448;
      end
      4: begin
        input_h = 13; input_w = 13; output_w = 13;
        input_spatial = 169; input_channels = 384;
        kernel = 3; padding = 1;
        configured_base = activation_a_base;
        configured_bytes = 26'd64896;
      end
      5: begin
        input_h = 13; input_w = 13; output_w = 13;
        input_spatial = 169; input_channels = 256;
        kernel = 3; padding = 1;
        configured_base = activation_b_base;
        configured_bytes = 26'd43264;
      end
      6: begin
        input_h = 6; input_w = 6; input_spatial = 36;
        input_channels = 256;
        configured_base = activation_a_base;
        configured_bytes = 26'd9216;
      end
      7: begin
        input_spatial = 1; input_channels = 10'd0;
        configured_base = activation_b_base;
        configured_bytes = 26'd4096;
      end
      8: begin
        input_spatial = 1; input_channels = 10'd0;
        configured_base = activation_a_base;
        configured_bytes = 26'd4096;
      end
      default: begin end
    endcase
    configured_beats = configured_bytes[15:4];
  end

  always_comb begin
    request_fields_valid = request_layer_id >= 2 && request_layer_id <= 8 &&
        request_m_lane_mask != 0 &&
        request_m_lane_mask == ((17'b1 << requested_m_count) - 1'b1) &&
        request_k_count != 0 && activation_a_base[3:0] == 0 &&
        activation_b_base[3:0] == 0;
    case (request_layer_id)
      2: request_fields_valid &= request_k_offset == 0 &&
          request_k_count == 1600 && requested_m_count <= 16 &&
          request_m_base + requested_m_count <= 729;
      3: request_fields_valid &= request_k_offset == 0 &&
          request_k_count == 1728 && requested_m_count <= 8 &&
          request_m_base + requested_m_count <= 169;
      4: request_fields_valid &= request_k_offset == 0 &&
          request_k_count == 3456 && requested_m_count <= 8 &&
          request_m_base + requested_m_count <= 169;
      5: request_fields_valid &= request_k_offset == 0 &&
          request_k_count == 2304 && requested_m_count <= 8 &&
          request_m_base + requested_m_count <= 169;
      6: request_fields_valid &= requested_m_count == 1 &&
          request_m_base == 0 &&
          ((request_k_offset == 0 && request_k_count == 4096) ||
           (request_k_offset == 4096 && request_k_count == 4096) ||
           (request_k_offset == 8192 && request_k_count == 1024));
      7, 8: request_fields_valid &= requested_m_count == 1 &&
          request_m_base == 0 && request_k_offset == 0 &&
          request_k_count == 4096;
      default: request_fields_valid = 1'b0;
    endcase
  end

  always_comb begin
    input_y_signed = $signed({1'b0, current_output_y_q}) +
                     $signed({7'd0, conv_ky_q}) -
                     $signed({6'd0, padding});
    input_x_signed = $signed({1'b0, current_output_x_q}) +
                     $signed({7'd0, conv_kx_q}) -
                     $signed({6'd0, padding});
    coordinate_valid = input_y_signed >= 0 && input_y_signed < input_h &&
                       input_x_signed >= 0 && input_x_signed < input_w;
    lane_active = m_lane_index_q < m_count_q &&
                  m_lane_mask_q[m_lane_index_q];

    spatial_index = 0;
    cache_word_index = 0;
    cache_byte_index = 0;
    conv_input_y = $unsigned(input_y_signed);
    conv_input_x = $unsigned(input_x_signed);
    conv_channel_tile = conv_channel_q[9:3];
    fc_channel_tile = fc_channel_q[8:3];
    conv_channel_tile_wide = {25'd0, conv_channel_tile};
    fc_channel_tile_wide = {26'd0, fc_channel_tile};
    if (layer_is_conv) begin
      case (layer_id_q)
        2: begin
          // 27*y and 729*channel_tile, written as shift/add so that
          // activation address generation never consumes a DSP48E2.
          spatial_index = (conv_input_y << 4) +
                          (conv_input_y << 3) +
                          (conv_input_y << 1) + conv_input_y +
                          conv_input_x;
          cache_word_index = (conv_channel_tile_wide << 9) +
                             (conv_channel_tile_wide << 7) +
                             (conv_channel_tile_wide << 6) +
                             (conv_channel_tile_wide << 4) +
                             (conv_channel_tile_wide << 3) +
                             conv_channel_tile_wide + spatial_index;
        end
        default: begin
          // 13*y and 169*channel_tile.
          spatial_index = (conv_input_y << 3) +
                          (conv_input_y << 2) + conv_input_y +
                          conv_input_x;
          cache_word_index = (conv_channel_tile_wide << 7) +
                             (conv_channel_tile_wide << 5) +
                             (conv_channel_tile_wide << 3) +
                             conv_channel_tile_wide + spatial_index;
        end
      endcase
      cache_byte_index = {cache_word_index[0], conv_channel_q[2:0]};
    end else if (layer_id_q == 6) begin
      // 36*channel_tile = 32*channel_tile + 4*channel_tile.
      cache_word_index = (fc_channel_tile_wide << 5) +
                         (fc_channel_tile_wide << 2) + fc_spatial_q;
      cache_byte_index = {cache_word_index[0], fc_channel_q[2:0]};
    end else begin
      cache_word_index = fc_linear_q >> 3;
      cache_byte_index = fc_linear_q[3:0];
    end
    cache_beat_index = cache_word_index[12:1];
    cache_read_valid = lane_active &&
        (layer_is_fc || coordinate_valid);
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      state_q <= ST_IDLE;
      fault_q <= 1'b0;
      cache_valid_q <= 1'b0;
      cached_layer_id <= 0;
      dma_done_seen_q <= 1'b0;
      layer_id_q <= 0;
      k_count_q <= 0;
      local_k_q <= 0;
      m_lane_mask_q <= 0;
      context_tag_q <= 0;
      m_count_q <= 0;
      m_lane_index_q <= 0;
      cache_write_index_q <= 0;
      cache_beat_index_q <= 0;
      cache_read_data_q <= 0;
      cache_read_byte_q <= 0;
      patch_word_q <= 0;
      conv_channel_q <= 0;
      conv_kx_q <= 0;
      conv_ky_q <= 0;
      position_remainder_q <= 0;
      base_output_y_q <= 0;
      base_output_x_q <= 0;
      current_output_y_q <= 0;
      current_output_x_q <= 0;
      fc_channel_q <= 0;
      fc_spatial_q <= 0;
      fc_linear_q <= 0;
      cache_loads <= 0;
      completed_patches <= 0;
      emitted_patch_words <= 0;
    end else begin
      if (dma_done)
        dma_done_seen_q <= 1'b1;

      if (request_fire) begin
        layer_id_q <= request_layer_id;
        k_count_q <= request_k_count;
        local_k_q <= 0;
        m_lane_mask_q <= request_m_lane_mask;
        context_tag_q <= request_context_tag;
        m_count_q <= requested_m_count;
        m_lane_index_q <= 0;
        conv_channel_q <= 0;
        conv_kx_q <= 0;
        conv_ky_q <= 0;
        case (request_k_offset)
          14'd4096: begin
            fc_channel_q <= 9'd113;
            fc_spatial_q <= 6'd28;
          end
          14'd8192: begin
            fc_channel_q <= 9'd227;
            fc_spatial_q <= 6'd20;
          end
          default: begin
            fc_channel_q <= 0;
            fc_spatial_q <= 0;
          end
        endcase
        fc_linear_q <= request_k_offset[12:0];
        patch_word_q <= 0;
        position_remainder_q <= request_m_base;
        base_output_y_q <= 0;
        base_output_x_q <= 0;
        if (!request_fields_valid) begin
          fault_q <= 1'b1;
          state_q <= ST_FAILED;
        end else begin
          state_q <= ST_INIT_POSITION;
        end
      end

      if (state_q == ST_INIT_POSITION) begin
        if (layer_is_conv && position_remainder_q >= input_w) begin
          position_remainder_q <= position_remainder_q - input_w;
          base_output_y_q <= base_output_y_q + 1'b1;
        end else begin
          base_output_x_q <= position_remainder_q[7:0];
          if (cache_valid_q && cached_layer_id == layer_id_q) begin
            state_q <= ST_PREPARE_WORD;
          end else begin
            cache_valid_q <= 1'b0;
            cache_write_index_q <= 0;
            state_q <= ST_LOAD_COMMAND;
          end
        end
      end

      if (command_fire) begin
        dma_done_seen_q <= 1'b0;
        cache_write_index_q <= 0;
        state_q <= ST_LOAD_ARM;
      end

      if (state_q == ST_LOAD_ARM && dma_armed)
        state_q <= ST_LOAD_STREAM;

      if (input_fire) begin
        activation_cache[cache_write_index_q] <= s_axis_tdata;
        cache_write_index_q <= cache_write_index_q + 1'b1;
        if (s_axis_tkeep != 16'hffff ||
            s_axis_tlast != expected_input_last)
          fault_q <= 1'b1;
        if (expected_input_last) begin
          if (dma_done_seen_q || dma_done) begin
            cache_valid_q <= 1'b1;
            cached_layer_id <= layer_id_q;
            cache_loads <= cache_loads + 1'b1;
            state_q <= ST_PREPARE_WORD;
          end else begin
            state_q <= ST_LOAD_DRAIN;
          end
        end
      end

      if (state_q == ST_LOAD_DRAIN && dma_done) begin
        dma_done_seen_q <= 1'b0;
        cache_valid_q <= 1'b1;
        cached_layer_id <= layer_id_q;
        cache_loads <= cache_loads + 1'b1;
        state_q <= ST_PREPARE_WORD;
      end

      if (state_q == ST_PREPARE_WORD) begin
        patch_word_q <= 0;
        m_lane_index_q <= 0;
        current_output_y_q <= base_output_y_q;
        current_output_x_q <= base_output_x_q;
        state_q <= ST_ADDRESS;
      end

      if (state_q == ST_ADDRESS) begin
        if (cache_read_valid) begin
          cache_beat_index_q <= cache_beat_index;
          cache_read_byte_q <= cache_byte_index;
          state_q <= ST_ASSEMBLE;
        end else if (m_lane_index_q + 1'b1 >= m_count_q) begin
          state_q <= ST_OUTPUT;
        end else begin
          m_lane_index_q <= m_lane_index_q + 1'b1;
          if (layer_is_conv) begin
            if (current_output_x_q + 1'b1 >= input_w) begin
              current_output_x_q <= 0;
              current_output_y_q <= current_output_y_q + 1'b1;
            end else begin
              current_output_x_q <= current_output_x_q + 1'b1;
            end
          end
        end
      end

      if (state_q == ST_ASSEMBLE) begin
          cache_read_data_q <= activation_cache[cache_beat_index_q];
          state_q <= ST_CAPTURE;
      end

      if (state_q == ST_CAPTURE) begin
        patch_word_q[m_lane_index_q*8 +: 8] <=
            cache_read_data_q[cache_read_byte_q*8 +: 8];
        if (m_lane_index_q + 1'b1 >= m_count_q)
          state_q <= ST_OUTPUT;
        else begin
          m_lane_index_q <= m_lane_index_q + 1'b1;
          if (layer_is_conv) begin
            if (current_output_x_q + 1'b1 >= input_w) begin
              current_output_x_q <= 0;
              current_output_y_q <= current_output_y_q + 1'b1;
            end else begin
              current_output_x_q <= current_output_x_q + 1'b1;
            end
          end
          state_q <= ST_ADDRESS;
        end
      end

      if (patch_fire) begin
        emitted_patch_words <= emitted_patch_words + 1'b1;
        if (patch_axis_tlast) begin
          completed_patches <= completed_patches + 1'b1;
          state_q <= ST_IDLE;
        end else begin
          local_k_q <= local_k_q + 1'b1;
          if (layer_is_conv) begin
            if (conv_channel_q + 1'b1 < input_channels)
              conv_channel_q <= conv_channel_q + 1'b1;
            else begin
              conv_channel_q <= 0;
              if (conv_kx_q + 1'b1 < kernel)
                conv_kx_q <= conv_kx_q + 1'b1;
              else begin
                conv_kx_q <= 0;
                conv_ky_q <= conv_ky_q + 1'b1;
              end
            end
          end else if (layer_id_q == 6) begin
            if (fc_spatial_q == 35) begin
              fc_spatial_q <= 0;
              fc_channel_q <= fc_channel_q + 1'b1;
            end else begin
              fc_spatial_q <= fc_spatial_q + 1'b1;
            end
          end else begin
            fc_linear_q <= fc_linear_q + 1'b1;
          end
          state_q <= ST_PREPARE_WORD;
        end
      end

      if (dma_error) begin
        fault_q <= 1'b1;
        state_q <= ST_FAILED;
      end
    end
  end

`ifndef SYNTHESIS
  always_ff @(posedge clk) begin
    if (!rst) begin
      if (input_fire && cache_write_index_q >= MAX_CACHE_BEATS)
        $fatal(1, "activation patch cache overflow");
      if (state_q == ST_ADDRESS && cache_read_valid &&
          cache_beat_index >= MAX_CACHE_BEATS)
        $fatal(1, "activation patch cache read overflow");
      if (patch_fire && patch_axis_tlast &&
          emitted_patch_words + 1'b1 < k_count_q)
        $fatal(1, "activation patch service retired an early last");
    end
  end
`endif

endmodule
