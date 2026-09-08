`timescale 1ns/1ps

// Gather Pool5's N8-tile-major [channel_group][y][x][lane] storage into the
// channel-major PyTorch flatten order consumed by FC6. One scalar read is
// outstanding at a time; eight returned scalars form one FC activation word.
module alexnet_pool5_fc6_flatten_reader #(
    parameter int CHANNELS = 256,
    parameter int HEIGHT = 6,
    parameter int WIDTH = 6,
    parameter int K_W = 14,
    parameter int COUNT_W = 10,
    parameter int ADDRESS_W = 11,
    parameter int TAG_W = 16
) (
    input  logic clk,
    input  logic rst,

    input  logic start_valid,
    output logic start_ready,
    input  logic [K_W-1:0] start_k_offset,
    input  logic [COUNT_W-1:0] start_k_count,
    input  logic [TAG_W-1:0] start_tag,

    output logic read_request_valid,
    input  logic read_request_ready,
    output logic [ADDRESS_W-1:0] read_request_word_address,
    output logic [2:0] read_request_lane,
    output logic [K_W-1:0] read_request_flat_index,
    output logic [TAG_W-1:0] read_request_tag,
    input  logic read_response_valid,
    output logic read_response_ready,
    input  logic signed [7:0] read_response_value,
    input  logic read_response_error,

    output logic m_valid,
    input  logic m_ready,
    output logic [63:0] m_values,
    output logic [7:0] m_lane_mask,
    output logic [K_W-1:0] m_k_base,
    output logic [TAG_W-1:0] m_tag,
    output logic m_last,

    output logic busy,
    output logic done,
    output logic fault,
    output logic [K_W-1:0] scalars_completed,
    output logic [COUNT_W-1:0] words_completed
);
  localparam int SPATIAL_WORDS = HEIGHT * WIDTH;
  localparam int TOTAL_FEATURES = CHANNELS * SPATIAL_WORDS;

  logic active_q;
  logic outstanding_q;
  logic fault_q;
  logic [1:0] init_phase_q;
  logic [K_W-1:0] k_offset_q;
  logic [COUNT_W-1:0] k_count_q;
  logic [TAG_W-1:0] tag_q;
  logic [2:0] pack_lane_q;
  logic [63:0] pack_values_q;
  logic [K_W-1:0] flat_index_q;
  logic [K_W-1:0] decoded_channel_q;
  logic [K_W-1:0] decoded_spatial_q;
  logic [K_W-1:0] decoded_channel_group;
  (* use_dsp = "no" *) logic [ADDRESS_W-1:0] decoded_group_base;
  logic [5:0] spatial_q;
  logic [ADDRESS_W-1:0] word_address_q;
  logic [2:0] source_lane_q;
  logic request_fire;
  logic response_fire;
  logic output_fire;
  logic scalar_is_last;
  logic word_is_complete;
  logic [63:0] completed_word;

  assign start_ready = !active_q && init_phase_q == 0 &&
                       !outstanding_q && !m_valid && !fault_q;
  assign busy = init_phase_q != 0 || active_q || outstanding_q || m_valid;
  assign fault = fault_q;
  assign read_request_valid = active_q && !outstanding_q && !m_valid &&
                              scalars_completed < k_count_q;
  assign read_request_word_address = word_address_q;
  assign read_request_lane = source_lane_q;
  assign read_request_flat_index = flat_index_q;
  assign read_request_tag = tag_q;
  assign decoded_channel_group = decoded_channel_q >> 3;
  assign decoded_group_base =
      (ADDRESS_W'(decoded_channel_group) << 5) +
      (ADDRESS_W'(decoded_channel_group) << 2);
  assign request_fire = read_request_valid && read_request_ready;
  assign read_response_ready = outstanding_q && !m_valid;
  assign response_fire = read_response_valid && read_response_ready;
  assign scalar_is_last = scalars_completed + 1'b1 == k_count_q;
  assign word_is_complete = pack_lane_q == 3'd7 || scalar_is_last;
  assign output_fire = m_valid && m_ready;

  always_comb begin
    completed_word = pack_values_q;
    completed_word[pack_lane_q*8 +: 8] = read_response_value;
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      active_q <= 1'b0;
      outstanding_q <= 1'b0;
      fault_q <= 1'b0;
      init_phase_q <= 0;
      k_offset_q <= 0;
      k_count_q <= 0;
      tag_q <= 0;
      pack_lane_q <= 0;
      pack_values_q <= 0;
      flat_index_q <= 0;
      decoded_channel_q <= 0;
      decoded_spatial_q <= 0;
      spatial_q <= 0;
      word_address_q <= 0;
      source_lane_q <= 0;
      m_valid <= 1'b0;
      m_values <= 0;
      m_lane_mask <= 0;
      m_k_base <= 0;
      m_tag <= 0;
      m_last <= 1'b0;
      done <= 1'b0;
      scalars_completed <= 0;
      words_completed <= 0;
    end else begin
      done <= 1'b0;

      if (start_valid && start_ready) begin
        init_phase_q <= 1;
        k_offset_q <= start_k_offset;
        k_count_q <= start_k_count;
        tag_q <= start_tag;
        pack_lane_q <= 0;
        pack_values_q <= 0;
        scalars_completed <= 0;
        words_completed <= 0;
      end

      // Split constant /36 decoding and tile-major address formation across
      // two setup cycles. The active read path then uses only registered
      // coordinates and small +/- counters, keeping it off the 200 MHz
      // critical path.
      if (init_phase_q == 1) begin
        decoded_channel_q <= k_offset_q / SPATIAL_WORDS;
        decoded_spatial_q <= k_offset_q % SPATIAL_WORDS;
        flat_index_q <= k_offset_q;
        init_phase_q <= 2;
      end else if (init_phase_q == 2) begin
        spatial_q <= decoded_spatial_q[5:0];
        source_lane_q <= decoded_channel_q[2:0];
        word_address_q <= decoded_group_base +
                          ADDRESS_W'(decoded_spatial_q);
        init_phase_q <= 0;
        active_q <= 1'b1;
      end

      if (request_fire)
        outstanding_q <= 1'b1;

      if (response_fire) begin
        outstanding_q <= 1'b0;
        if (read_response_error) begin
          fault_q <= 1'b1;
          active_q <= 1'b0;
        end else begin
          pack_values_q <= completed_word;
          scalars_completed <= scalars_completed + 1'b1;
          flat_index_q <= flat_index_q + 1'b1;
          if (spatial_q == SPATIAL_WORDS - 1) begin
            spatial_q <= 0;
            if (source_lane_q == 3'd7) begin
              source_lane_q <= 0;
              word_address_q <= word_address_q + 1'b1;
            end else begin
              source_lane_q <= source_lane_q + 1'b1;
              word_address_q <= word_address_q - (SPATIAL_WORDS - 1);
            end
          end else begin
            spatial_q <= spatial_q + 1'b1;
            word_address_q <= word_address_q + 1'b1;
          end
          if (word_is_complete) begin
            m_valid <= 1'b1;
            m_values <= completed_word;
            m_lane_mask <= 8'hff >> (3'd7 - pack_lane_q);
            m_k_base <= flat_index_q - pack_lane_q;
            m_tag <= tag_q;
            m_last <= scalar_is_last;
          end else begin
            pack_lane_q <= pack_lane_q + 1'b1;
          end
        end
      end

      if (output_fire) begin
        m_valid <= 1'b0;
        words_completed <= words_completed + 1'b1;
        if (m_last) begin
          active_q <= 1'b0;
          done <= 1'b1;
        end else begin
          pack_lane_q <= 0;
          pack_values_q <= 0;
        end
      end
    end
  end

`ifndef SYNTHESIS
  initial begin
    if (CHANNELS != 256 || HEIGHT != 6 || WIDTH != 6 ||
        TOTAL_FEATURES != 9216 || ADDRESS_W < 11)
      $fatal(1, "Pool5 flatten reader parameterization is invalid");
  end

  always_ff @(posedge clk) begin
    if (!rst) begin
      if (start_valid && start_ready &&
          (start_k_count == 0 || start_k_offset[2:0] != 0 ||
           start_k_count[2:0] != 0 ||
           K_W'(start_k_offset + start_k_count) > TOTAL_FEATURES))
        $fatal(1, "Pool5 flatten request is outside FC6 K space");
      if (read_response_valid && !outstanding_q)
        $fatal(1, "Pool5 flatten response arrived without a request");
      if (request_fire &&
          (read_request_word_address >= (CHANNELS/8)*SPATIAL_WORDS ||
           read_request_lane !=
               (read_request_flat_index / SPATIAL_WORDS) % 8))
        $fatal(1, "Pool5 flatten address mapping is invalid");
      if (m_valid && m_lane_mask != 8'hff)
        $fatal(1, "Pool5 flatten FC6 chunk must contain complete N8 words");
    end
  end
`endif
endmodule
