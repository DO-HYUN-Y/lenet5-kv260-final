`timescale 1ns/1ps

// Layer-scoped Conv result service. Raw 128-bit result DMA packets are
// unpacked into N8 words, optionally passed through one reused 3x3/stride-2
// max-pool engine, and packed back into a DDR-write AXI stream. Each N8 output
// channel tile is one AXIS packet. No complete feature map is stored in PL.
module alexnet_conv_result_pool_service (
    input logic clk,
    input logic rst,

    input  logic layer_valid,
    output logic layer_ready,
    input  logic [2:0] layer_id,
    input  logic [15:0] layer_job_tag,
    input  logic [7:0] layer_raw_h,
    input  logic [7:0] layer_raw_w,
    input  logic [5:0] layer_n8_tiles,
    input  logic layer_pool_enable,
    input  logic [5:0] layer_stored_h,
    input  logic [5:0] layer_stored_w,

    input  logic [127:0] s_axis_tdata,
    input  logic [15:0] s_axis_tkeep,
    input  logic s_axis_tvalid,
    output logic s_axis_tready,
    input  logic s_axis_tlast,

    output logic [127:0] m_axis_tdata,
    output logic [15:0] m_axis_tkeep,
    output logic m_axis_tvalid,
    input  logic m_axis_tready,
    output logic m_axis_tlast,

    output logic layer_done,
    output logic [2:0] completed_layer_id,
    output logic [15:0] completed_job_tag,
    output logic layer_error,
    output logic busy,
    output logic fault,
    output logic [31:0] raw_words_accepted,
    output logic [31:0] stored_words_transferred,
    output logic [5:0] input_tiles_completed,
    output logic [5:0] output_tiles_completed
);
  logic active_q;
  logic [2:0] layer_id_q;
  logic [15:0] job_tag_q;
  logic [7:0] raw_h_q, raw_w_q;
  logic [5:0] n8_tiles_q;
  logic pool_enable_q;
  logic [5:0] stored_h_q, stored_w_q;
  logic [12:0] raw_words_per_tile_q;
  logic [12:0] raw_word_in_tile_q;
  logic fault_q;
  logic clear_data_errors;
  logic descriptor_fire;
  logic descriptor_valid;

  logic unpack_axis_valid;
  logic unpack_axis_ready;
  logic unpack_valid, unpack_ready, unpack_last;
  logic [63:0] unpack_values;
  logic [7:0] unpack_keep;
  logic unpack_busy, unpack_error;
  logic unpack_fire;

  logic pool_frame_valid, pool_frame_ready, pool_frame_active;
  logic pool_frame_done, pool_idle;
  logic pool_input_open;
  logic pool_s_ready;
  logic pool_m_valid, pool_m_ready;
  logic [63:0] pool_m_values;
  logic [7:0] pool_m_lane_mask;
  logic [5:0] pool_m_y, pool_m_x;
  logic [15:0] pool_m_n_base, pool_m_tag;
  logic [5:0] pool_frames_started_q;
  logic pool_word_last;

  logic pack_s_valid, pack_s_ready, pack_s_last;
  logic [63:0] pack_s_values;
  logic [7:0] pack_s_keep;
  logic pack_busy, pack_error;
  logic pack_word_fire;
  logic output_axis_fire;

  function automatic logic [12:0] fixed_raw_words(
      input logic [2:0] id);
    case (id)
      1: fixed_raw_words = 3025;
      2: fixed_raw_words = 729;
      3,4,5: fixed_raw_words = 169;
      default: fixed_raw_words = 0;
    endcase
  endfunction

  assign descriptor_valid = layer_id >= 1 && layer_id <= 5 &&
      layer_raw_h != 0 && layer_raw_w != 0 && layer_raw_w <= 55 &&
      layer_n8_tiles != 0 && layer_stored_h != 0 && layer_stored_w != 0 &&
      (!layer_pool_enable ||
       (layer_raw_h >= 3 && layer_raw_w >= 3 &&
       (layer_stored_h == ((layer_raw_h - 3) >> 1) + 1 &&
        layer_stored_w == ((layer_raw_w - 3) >> 1) + 1))) &&
      (layer_pool_enable ||
       (layer_stored_h == layer_raw_h[5:0] &&
        layer_stored_w == layer_raw_w[5:0])) &&
      ((layer_id == 1 && layer_raw_h == 55 && layer_raw_w == 55 &&
        layer_n8_tiles == 8 && layer_pool_enable &&
        layer_stored_h == 27 && layer_stored_w == 27) ||
       (layer_id == 2 && layer_raw_h == 27 && layer_raw_w == 27 &&
        layer_n8_tiles == 24 && layer_pool_enable &&
        layer_stored_h == 13 && layer_stored_w == 13) ||
       (layer_id == 3 && layer_raw_h == 13 && layer_raw_w == 13 &&
        layer_n8_tiles == 48 && !layer_pool_enable &&
        layer_stored_h == 13 && layer_stored_w == 13) ||
       (layer_id == 4 && layer_raw_h == 13 && layer_raw_w == 13 &&
        layer_n8_tiles == 32 && !layer_pool_enable &&
        layer_stored_h == 13 && layer_stored_w == 13) ||
       (layer_id == 5 && layer_raw_h == 13 && layer_raw_w == 13 &&
        layer_n8_tiles == 32 && layer_pool_enable &&
        layer_stored_h == 6 && layer_stored_w == 6));
  assign layer_ready = !active_q && !unpack_busy && !pack_busy && pool_idle;
  assign descriptor_fire = layer_valid && layer_ready;
  assign clear_data_errors = descriptor_fire;
  assign busy = active_q || unpack_busy || pack_busy || !pool_idle;
  assign fault = fault_q || unpack_error || pack_error;
  assign layer_error = fault;

  // A pool frame descriptor occupies its own cycle. Raw data is held until
  // the max-pool instance reports frame_active.
  assign pool_frame_valid = active_q && pool_enable_q && pool_idle &&
                            pool_frames_started_q < n8_tiles_q;
  assign pool_input_open = pool_frame_active &&
                           pool_frames_started_q > input_tiles_completed;
  assign unpack_axis_valid = s_axis_tvalid && active_q &&
                             (!pool_enable_q || pool_input_open);
  assign s_axis_tready = unpack_axis_ready && active_q &&
                         (!pool_enable_q || pool_input_open);

  assign unpack_ready = pool_enable_q ? pool_s_ready : pack_s_ready;
  assign unpack_fire = unpack_valid && unpack_ready;

  assign pool_m_ready = pool_enable_q && pack_s_ready;
  assign pool_word_last = pool_m_y == stored_h_q - 1'b1 &&
                          pool_m_x == stored_w_q - 1'b1;
  assign pack_s_valid = pool_enable_q ? pool_m_valid : unpack_valid;
  assign pack_s_values = pool_enable_q ? pool_m_values : unpack_values;
  assign pack_s_keep = pool_enable_q ? pool_m_lane_mask : unpack_keep;
  assign pack_s_last = pool_enable_q ? pool_word_last : unpack_last;
  assign pack_word_fire = pack_s_valid && pack_s_ready;
  assign output_axis_fire = m_axis_tvalid && m_axis_tready;

  alexnet_axis128_to_n8_unpacker u_unpack (
      .clk(clk), .rst(rst), .clear_error(clear_data_errors),
      .s_axis_tdata(s_axis_tdata), .s_axis_tkeep(s_axis_tkeep),
      .s_axis_tvalid(unpack_axis_valid),
      .s_axis_tready(unpack_axis_ready), .s_axis_tlast(s_axis_tlast),
      .m_valid(unpack_valid), .m_ready(unpack_ready),
      .m_values(unpack_values), .m_byte_keep(unpack_keep),
      .m_last(unpack_last), .busy(unpack_busy),
      .protocol_error(unpack_error)
  );

  alexnet_n8_maxpool3x3 #(.MAX_INPUT_WIDTH(55)) u_pool (
      .clk(clk), .rst(rst),
      .frame_valid(pool_frame_valid), .frame_ready(pool_frame_ready),
      .frame_input_h(raw_h_q[5:0]), .frame_input_w(raw_w_q[5:0]),
      .frame_lane_mask(8'hff),
      .frame_n_base({7'b0, pool_frames_started_q, 3'b000}),
      .frame_tag(job_tag_q + pool_frames_started_q),
      .s_valid(unpack_valid && pool_enable_q), .s_ready(pool_s_ready),
      .s_values(unpack_values), .s_lane_mask(unpack_keep),
      .m_valid(pool_m_valid), .m_ready(pool_m_ready),
      .m_values(pool_m_values), .m_lane_mask(pool_m_lane_mask),
      .m_y(pool_m_y), .m_x(pool_m_x), .m_n_base(pool_m_n_base),
      .m_frame_tag(pool_m_tag), .frame_active(pool_frame_active),
      .frame_done(pool_frame_done), .idle(pool_idle)
  );

  alexnet_n8_to_axis128_packer u_pack (
      .clk(clk), .rst(rst), .clear_error(clear_data_errors),
      .s_valid(pack_s_valid), .s_ready(pack_s_ready),
      .s_values(pack_s_values), .s_byte_keep(pack_s_keep),
      .s_last(pack_s_last), .m_axis_tdata(m_axis_tdata),
      .m_axis_tkeep(m_axis_tkeep), .m_axis_tvalid(m_axis_tvalid),
      .m_axis_tready(m_axis_tready), .m_axis_tlast(m_axis_tlast),
      .busy(pack_busy), .protocol_error(pack_error)
  );

  always_ff @(posedge clk) begin
    if (rst) begin
      active_q <= 1'b0;
      layer_id_q <= 0;
      job_tag_q <= 0;
      raw_h_q <= 0;
      raw_w_q <= 0;
      n8_tiles_q <= 0;
      pool_enable_q <= 1'b0;
      stored_h_q <= 0;
      stored_w_q <= 0;
      raw_words_per_tile_q <= 0;
      raw_word_in_tile_q <= 0;
      pool_frames_started_q <= 0;
      fault_q <= 1'b0;
      raw_words_accepted <= 0;
      stored_words_transferred <= 0;
      input_tiles_completed <= 0;
      output_tiles_completed <= 0;
      layer_done <= 1'b0;
      completed_layer_id <= 0;
      completed_job_tag <= 0;
    end else begin
      layer_done <= 1'b0;

      if (descriptor_fire) begin
        active_q <= descriptor_valid;
        layer_id_q <= layer_id;
        job_tag_q <= layer_job_tag;
        raw_h_q <= layer_raw_h;
        raw_w_q <= layer_raw_w;
        n8_tiles_q <= layer_n8_tiles;
        pool_enable_q <= layer_pool_enable;
        stored_h_q <= layer_stored_h;
        stored_w_q <= layer_stored_w;
        raw_words_per_tile_q <= fixed_raw_words(layer_id);
        raw_word_in_tile_q <= 0;
        pool_frames_started_q <= 0;
        fault_q <= !descriptor_valid;
        raw_words_accepted <= 0;
        stored_words_transferred <= 0;
        input_tiles_completed <= 0;
        output_tiles_completed <= 0;
      end

      if (pool_frame_valid && pool_frame_ready)
        pool_frames_started_q <= pool_frames_started_q + 1'b1;

      if (unpack_fire) begin
        raw_words_accepted <= raw_words_accepted + 1'b1;
        if (unpack_keep != 8'hff ||
            unpack_last != (raw_word_in_tile_q + 1'b1 ==
                            raw_words_per_tile_q))
          fault_q <= 1'b1;
        if (raw_word_in_tile_q + 1'b1 == raw_words_per_tile_q) begin
          raw_word_in_tile_q <= 0;
          input_tiles_completed <= input_tiles_completed + 1'b1;
        end else begin
          raw_word_in_tile_q <= raw_word_in_tile_q + 1'b1;
        end
      end

      if (pack_word_fire)
        stored_words_transferred <= stored_words_transferred + 1'b1;

      if (output_axis_fire && m_axis_tlast) begin
        output_tiles_completed <= output_tiles_completed + 1'b1;
        if (output_tiles_completed + 1'b1 == n8_tiles_q) begin
          active_q <= 1'b0;
          layer_done <= 1'b1;
          completed_layer_id <= layer_id_q;
          completed_job_tag <= job_tag_q;
          if (input_tiles_completed != n8_tiles_q)
            fault_q <= 1'b1;
        end
      end
    end
  end

`ifndef SYNTHESIS
  always_ff @(posedge clk) begin
    if (!rst) begin
      if (pool_m_valid && (pool_m_n_base[15:3] !=
          (pool_frames_started_q - 1'b1) ||
          pool_m_tag != job_tag_q + pool_frames_started_q - 1'b1))
        $fatal(1, "Conv result pool metadata changed between N8 tiles");
      if (layer_done && (input_tiles_completed != n8_tiles_q ||
                         output_tiles_completed != n8_tiles_q))
        $fatal(1, "Conv result service completed before all tiles drained");
    end
  end
`endif
endmodule
