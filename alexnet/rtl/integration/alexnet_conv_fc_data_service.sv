`timescale 1ns/1ps

// Connected streaming data service for the graph compute boundary:
//   raw Conv result -> optional Pool1/2/5 -> DDR-write AXIS
//                                          + Pool5 two-BRAM cache
//   Pool5 cache -> FC6 flatten -> shared-compute MM2S AXIS
//   external DDR MM2S -> shared-compute MM2S AXIS for every other payload
//
// The physical address planner is a separate control service so the next
// AXI/PS top can arbitrate its descriptors with parameter and result traffic.
module alexnet_conv_fc_data_service (
    input logic clk,
    input logic rst,

    input  logic conv_layer_valid,
    output logic conv_layer_ready,
    input  logic [2:0] conv_layer_id,
    input  logic [15:0] conv_layer_job_tag,
    input  logic [7:0] conv_layer_raw_h,
    input  logic [7:0] conv_layer_raw_w,
    input  logic [5:0] conv_layer_n8_tiles,
    input  logic conv_layer_pool_enable,
    input  logic [5:0] conv_layer_stored_h,
    input  logic [5:0] conv_layer_stored_w,

    input  logic [127:0] conv_raw_axis_tdata,
    input  logic [15:0] conv_raw_axis_tkeep,
    input  logic conv_raw_axis_tvalid,
    output logic conv_raw_axis_tready,
    input  logic conv_raw_axis_tlast,
    output logic [127:0] conv_stored_axis_tdata,
    output logic [15:0] conv_stored_axis_tkeep,
    output logic conv_stored_axis_tvalid,
    input  logic conv_stored_axis_tready,
    output logic conv_stored_axis_tlast,

    output logic conv_layer_done,
    output logic [2:0] conv_completed_layer_id,
    output logic [15:0] conv_completed_job_tag,

    input  logic fc_request_valid,
    output logic fc_request_ready,
    input  logic [3:0] fc_active_layer_id,
    input  logic [13:0] fc_active_k_offset,
    input  logic [9:0] fc_active_k_count,
    input  logic [1:0] fc_request_destination,
    input  logic [9:0] fc_request_word_count,
    input  logic [15:0] fc_request_byte_count,
    input  logic [2:0] fc_request_m_count,
    input  logic [15:0] fc_request_tag,
    output logic fc_external_request_valid,
    input  logic fc_external_request_ready,
    output logic [3:0] fc_external_request_layer_id,
    output logic [13:0] fc_external_request_k_offset,
    output logic [9:0] fc_external_request_k_count,
    output logic [1:0] fc_external_request_destination,
    output logic [9:0] fc_external_request_word_count,
    output logic [15:0] fc_external_request_byte_count,
    output logic [2:0] fc_external_request_m_count,
    output logic [15:0] fc_external_request_tag,

    input  logic [127:0] external_axis_tdata,
    input  logic [15:0] external_axis_tkeep,
    input  logic external_axis_tvalid,
    output logic external_axis_tready,
    input  logic external_axis_tlast,
    output logic [127:0] compute_axis_tdata,
    output logic [15:0] compute_axis_tkeep,
    output logic compute_axis_tvalid,
    input  logic compute_axis_tready,
    output logic compute_axis_tlast,

    output logic pool5_cache_valid,
    output logic [15:0] pool5_cache_tag,
    output logic pool5_cache_write_done,
    output logic fc6_flatten_active,
    output logic fc6_flatten_done,
    output logic fault,
    output logic [31:0] conv_raw_words,
    output logic [31:0] conv_stored_words,
    output logic [13:0] fc6_completed_scalars,
    output logic [10:0] fc6_completed_words
);
  logic pool_layer_ready;
  logic [127:0] pool_axis_tdata;
  logic [15:0] pool_axis_tkeep;
  logic pool_axis_tvalid, pool_axis_tready, pool_axis_tlast;
  logic pool_layer_error, pool_busy, pool_fault;
  logic [5:0] pool_input_tiles, pool_output_tiles;

  logic pool5_start_valid, pool5_start_ready;
  logic pool5_write_ready, pool5_write_active, pool5_fault;
  logic [9:0] pool5_beats_written;
  logic [5:0] pool5_tiles_written;
  logic pool5_read_request_valid, pool5_read_request_ready;
  logic [10:0] pool5_read_request_word_address;
  logic [2:0] pool5_read_request_lane;
  logic [13:0] pool5_read_request_flat_index;
  logic [15:0] pool5_read_request_tag;
  logic pool5_read_response_valid, pool5_read_response_ready;
  logic signed [7:0] pool5_read_response_value;
  logic pool5_read_response_error;

  logic injector_fault;
  logic [3:0] injector_completed_chunks;
  logic layer_is_pool5;
  logic combined_layer_fire;
  logic combined_output_fire;

  assign layer_is_pool5 = conv_layer_id == 5;
  assign conv_layer_ready = pool_layer_ready &&
      (!layer_is_pool5 || pool5_start_ready);
  assign combined_layer_fire = conv_layer_valid && conv_layer_ready;
  assign pool5_start_valid = combined_layer_fire && layer_is_pool5;

  // A Pool5 beat advances only when both the external writer and the local
  // cache accept it. Other layers do not touch the cache.
  assign conv_stored_axis_tdata = pool_axis_tdata;
  assign conv_stored_axis_tkeep = pool_axis_tkeep;
  assign conv_stored_axis_tvalid = pool_axis_tvalid &&
      (!pool5_write_active || pool5_write_ready);
  assign conv_stored_axis_tlast = pool_axis_tlast;
  assign pool_axis_tready = conv_stored_axis_tready &&
      (!pool5_write_active || pool5_write_ready);
  assign combined_output_fire = pool_axis_tvalid && pool_axis_tready;

  alexnet_conv_result_pool_service u_conv_results (
      .clk(clk), .rst(rst),
      .layer_valid(combined_layer_fire), .layer_ready(pool_layer_ready),
      .layer_id(conv_layer_id), .layer_job_tag(conv_layer_job_tag),
      .layer_raw_h(conv_layer_raw_h), .layer_raw_w(conv_layer_raw_w),
      .layer_n8_tiles(conv_layer_n8_tiles),
      .layer_pool_enable(conv_layer_pool_enable),
      .layer_stored_h(conv_layer_stored_h),
      .layer_stored_w(conv_layer_stored_w),
      .s_axis_tdata(conv_raw_axis_tdata),
      .s_axis_tkeep(conv_raw_axis_tkeep),
      .s_axis_tvalid(conv_raw_axis_tvalid),
      .s_axis_tready(conv_raw_axis_tready),
      .s_axis_tlast(conv_raw_axis_tlast),
      .m_axis_tdata(pool_axis_tdata), .m_axis_tkeep(pool_axis_tkeep),
      .m_axis_tvalid(pool_axis_tvalid), .m_axis_tready(pool_axis_tready),
      .m_axis_tlast(pool_axis_tlast), .layer_done(conv_layer_done),
      .completed_layer_id(conv_completed_layer_id),
      .completed_job_tag(conv_completed_job_tag),
      .layer_error(pool_layer_error), .busy(pool_busy), .fault(pool_fault),
      .raw_words_accepted(conv_raw_words),
      .stored_words_transferred(conv_stored_words),
      .input_tiles_completed(pool_input_tiles),
      .output_tiles_completed(pool_output_tiles)
  );

  alexnet_pool5_n8_store u_pool5_cache (
      .clk(clk), .rst(rst), .start_valid(pool5_start_valid),
      .start_ready(pool5_start_ready), .start_tag(conv_layer_job_tag),
      .write_valid(combined_output_fire && pool5_write_active),
      .write_ready(pool5_write_ready), .write_data(pool_axis_tdata),
      .write_keep(pool_axis_tkeep), .write_last(pool_axis_tlast),
      .read_request_valid(pool5_read_request_valid),
      .read_request_ready(pool5_read_request_ready),
      .read_request_word_address(pool5_read_request_word_address),
      .read_request_lane(pool5_read_request_lane),
      .read_request_tag(pool5_read_request_tag),
      .read_response_valid(pool5_read_response_valid),
      .read_response_ready(pool5_read_response_ready),
      .read_response_value(pool5_read_response_value),
      .read_response_error(pool5_read_response_error),
      .write_active(pool5_write_active),
      .write_done(pool5_cache_write_done),
      .cache_valid(pool5_cache_valid), .cache_tag(pool5_cache_tag),
      .fault(pool5_fault), .beats_written(pool5_beats_written),
      .tiles_written(pool5_tiles_written)
  );

  alexnet_fc6_flatten_injector u_fc6_injector (
      .clk(clk), .rst(rst), .request_valid(fc_request_valid),
      .request_ready(fc_request_ready),
      .active_layer_id(fc_active_layer_id),
      .active_k_offset(fc_active_k_offset),
      .active_k_count(fc_active_k_count),
      .request_destination(fc_request_destination),
      .request_word_count(fc_request_word_count),
      .request_byte_count(fc_request_byte_count),
      .request_m_count(fc_request_m_count), .request_tag(fc_request_tag),
      .external_request_valid(fc_external_request_valid),
      .external_request_ready(fc_external_request_ready),
      .external_request_layer_id(fc_external_request_layer_id),
      .external_request_k_offset(fc_external_request_k_offset),
      .external_request_k_count(fc_external_request_k_count),
      .external_request_destination(fc_external_request_destination),
      .external_request_word_count(fc_external_request_word_count),
      .external_request_byte_count(fc_external_request_byte_count),
      .external_request_m_count(fc_external_request_m_count),
      .external_request_tag(fc_external_request_tag),
      .pool5_read_request_valid(pool5_read_request_valid),
      .pool5_read_request_ready(pool5_read_request_ready),
      .pool5_read_request_word_address(pool5_read_request_word_address),
      .pool5_read_request_lane(pool5_read_request_lane),
      .pool5_read_request_flat_index(pool5_read_request_flat_index),
      .pool5_read_request_tag(pool5_read_request_tag),
      .pool5_read_response_valid(pool5_read_response_valid),
      .pool5_read_response_ready(pool5_read_response_ready),
      .pool5_read_response_value(pool5_read_response_value),
      .pool5_read_response_error(pool5_read_response_error),
      .external_axis_tdata(external_axis_tdata),
      .external_axis_tkeep(external_axis_tkeep),
      .external_axis_tvalid(external_axis_tvalid),
      .external_axis_tready(external_axis_tready),
      .external_axis_tlast(external_axis_tlast),
      .compute_axis_tdata(compute_axis_tdata),
      .compute_axis_tkeep(compute_axis_tkeep),
      .compute_axis_tvalid(compute_axis_tvalid),
      .compute_axis_tready(compute_axis_tready),
      .compute_axis_tlast(compute_axis_tlast),
      .flatten_active(fc6_flatten_active), .flatten_done(fc6_flatten_done),
      .fault(injector_fault),
      .completed_chunks(injector_completed_chunks),
      .completed_scalars(fc6_completed_scalars),
      .completed_words(fc6_completed_words)
  );

  assign fault = pool_fault || pool5_fault || injector_fault;

`ifndef SYNTHESIS
  always_ff @(posedge clk) begin
    if (!rst) begin
      if (fc6_flatten_active && !pool5_cache_valid)
        $fatal(1, "FC6 flatten started before Pool5 cache completion");
    end
  end
`endif
endmodule
