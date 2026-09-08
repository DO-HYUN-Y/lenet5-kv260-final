`timescale 1ns/1ps

// Complete logical graph plus connected data plane.  This is the last RTL
// boundary before physical AXI DMA/AXI-Lite integration:
//   * Conv output is routed through the one-engine pool/bypass service.
//   * Pool5 is retained locally and injected into FC6 without a DDR reread.
//   * FC6 weight traffic and all FC7/8 traffic use the external MM2S stream.
//   * Conv stored tensors and FC outputs share one external S2MM stream.
//
// The external request ports are logical DMA descriptors.  Physical addresses
// are deliberately supplied by alexnet_ddr_address_planner in the next shell.
module alexnet_m4n8_graph_data_top #(
    parameter bit EXTERNAL_CONV_STORAGE_COMPLETION = 1'b0
) (
    input logic clk,
    input logic rst,
    input logic ce,
    input logic start_valid,
    output logic start_ready,
    input logic [15:0] start_tag,

    input logic [127:0] external_mm2s_axis_tdata,
    input logic [15:0] external_mm2s_axis_tkeep,
    input logic external_mm2s_axis_tvalid,
    output logic external_mm2s_axis_tready,
    input logic external_mm2s_axis_tlast,

    output logic [127:0] storage_axis_tdata,
    output logic [15:0] storage_axis_tkeep,
    output logic storage_axis_tvalid,
    input logic storage_axis_tready,
    output logic storage_axis_tlast,
    output logic storage_owner_fc,

    output logic rs_mm2s_request_valid,
    input logic rs_mm2s_request_ready,
    output logic [1:0] rs_mm2s_request_destination,
    output logic [10:0] rs_mm2s_request_word_count,
    output logic [15:0] rs_mm2s_request_byte_count,
    output logic [15:0] rs_mm2s_request_tag,
    output logic [15:0] rs_mm2s_request_n_base,
    output logic [7:0] rs_mm2s_request_chunk_index,
    output logic rs_s2mm_request_valid,
    input logic rs_s2mm_request_ready,
    output logic [12:0] rs_s2mm_request_word_count,
    output logic [15:0] rs_s2mm_request_byte_count,
    output logic [15:0] rs_s2mm_request_n_base,
    output logic [15:0] rs_s2mm_request_tag,

    input logic rs_activation_stream_valid,
    output logic rs_activation_stream_ready,
    input logic [63:0] rs_activation_stream_values,
    input logic [7:0] rs_activation_stream_lane_mask,
    input logic rs_activation_stream_last,

    output logic conv_parameter_request_valid,
    input  logic conv_parameter_request_ready,
    output logic [2:0] conv_parameter_request_layer_id,
    output logic [15:0] conv_parameter_request_job_tag,
    output logic [15:0] conv_parameter_request_n_base,
    input  logic conv_parameter_valid,
    output logic conv_parameter_ready,
    input  logic [2:0] conv_parameter_layer_id,
    input  logic [15:0] conv_parameter_job_tag,
    input  logic [15:0] conv_parameter_n_base,
    input  logic signed [31:0] conv_parameter_bias [0:7],
    input  logic signed [17:0] conv_parameter_multiplier [0:7],
    input  logic [5:0] conv_parameter_right_shift [0:7],

    output logic fc_parameter_request_valid,
    output logic [3:0] fc_active_layer_id,
    output logic [2:0] fc_active_m_count,
    output logic [15:0] fc_active_job_tag,
    output logic [15:0] fc_active_n_base,
    output logic [13:0] fc_active_k_offset,
    output logic [9:0] fc_active_k_count,
    input logic fc_parameter_valid,
    output logic fc_parameter_ready,
    input logic [3:0] fc_parameter_layer_id,
    input logic [15:0] fc_parameter_job_tag,
    input logic [15:0] fc_parameter_n_base,
    input logic signed [31:0] fc_parameter_bias [0:7],
    input logic signed [17:0] fc_parameter_multiplier [0:7],
    input logic [5:0] fc_parameter_right_shift [0:7],

    output logic conv_write_request_valid,
    input logic conv_write_request_ready,
    output logic [2:0] conv_write_request_layer_id,
    output logic [15:0] conv_write_request_tag,
    output logic [12:0] conv_write_request_word_count,
    output logic [15:0] conv_write_request_byte_count,
    input logic conv_write_complete_valid,
    output logic conv_write_complete_ready,
    input logic [2:0] conv_write_complete_layer_id,
    input logic [15:0] conv_write_complete_tag,
    input logic conv_write_complete_error,

    output logic fc_external_request_valid,
    input logic fc_external_request_ready,
    output logic [3:0] fc_external_request_layer_id,
    output logic [13:0] fc_external_request_k_offset,
    output logic [9:0] fc_external_request_k_count,
    output logic [1:0] fc_external_request_destination,
    output logic [9:0] fc_external_request_word_count,
    output logic [15:0] fc_external_request_byte_count,
    output logic [2:0] fc_external_request_m_count,
    output logic [15:0] fc_external_request_tag,

    output logic fc_result_request_valid,
    input logic fc_result_request_ready,
    output logic [1:0] fc_result_request_destination,
    output logic [15:0] fc_result_request_byte_count,
    output logic [15:0] fc_result_request_tag,
    input logic fc_result_complete_valid,
    output logic fc_result_complete_ready,
    input logic [15:0] fc_result_complete_n_base,
    input logic [15:0] fc_result_complete_tag,
    input logic fc_result_complete_error,
    input logic fc_backend_error,

    output logic busy,
    output logic inference_done,
    output logic inference_failed,
    output logic fault,
    output logic [3:0] fault_code,
    output logic [4:0] graph_phase,
    output logic [3:0] active_layer_id,
    output logic [15:0] active_inference_tag,
    output logic [2:0] completed_conv_layers,
    output logic [1:0] completed_fc_layers,
    output logic pool5_cache_valid,
    output logic [15:0] pool5_cache_tag,
    output logic pool5_cache_write_done,
    output logic fc6_flatten_active,
    output logic fc6_flatten_done,
    output logic [31:0] conv_raw_words,
    output logic [31:0] conv_stored_words,
    output logic [13:0] fc6_completed_scalars,
    output logic [10:0] fc6_completed_words,
    output logic compute_fault,
    output logic data_service_fault
);
  logic [127:0] s_axis_tdata, m_axis_tdata;
  logic [15:0] s_axis_tkeep, m_axis_tkeep;
  logic s_axis_tvalid, s_axis_tready, s_axis_tlast;
  logic m_axis_tvalid, m_axis_tready, m_axis_tlast;
  logic conv_raw_axis_tready;

  logic conv_result_commit_request_valid;
  logic conv_result_commit_request_ready;
  logic [2:0] conv_result_commit_layer_id;
  logic [15:0] conv_result_commit_job_tag;
  logic [7:0] conv_result_commit_output_h;
  logic [7:0] conv_result_commit_output_w;
  logic [9:0] conv_result_commit_output_channels;
  logic conv_result_commit_pool_enable;
  logic [5:0] conv_result_commit_pool_output_h;
  logic [5:0] conv_result_commit_pool_output_w;
  logic conv_result_commit_flatten_output;
  logic conv_result_complete_valid, conv_result_complete_ready;
  logic [2:0] conv_result_complete_layer_id;
  logic [15:0] conv_result_complete_job_tag;
  logic conv_result_complete_error, conv_service_error;

  logic fc_read_request_valid, fc_read_request_ready;
  logic [1:0] fc_read_request_destination;
  logic [9:0] fc_read_request_word_count;
  logic [15:0] fc_read_request_byte_count;
  logic [2:0] fc_read_request_m_count;
  logic [15:0] fc_read_request_tag;
  logic fc_service_error;

  logic conv_data_layer_ready, conv_data_layer_done;
  logic [2:0] conv_data_completed_layer_id;
  logic [15:0] conv_data_completed_job_tag;
  logic [127:0] conv_stored_axis_tdata;
  logic [15:0] conv_stored_axis_tkeep;
  logic conv_stored_axis_tvalid, conv_stored_axis_tready;
  logic conv_stored_axis_tlast;
  logic [12:0] conv_write_words;
  logic graph_fault;
  logic graph_output_is_conv;
  logic [12:0] active_conv_completed_commands;
  logic [5:0] active_conv_completed_n8_tiles;
  logic [15:0] active_conv_completed_output_words;
  logic rs_scheduler_busy, rs_scheduler_fault;
  logic fc_busy, fc_fault;
  logic storage_completion_fault;

  always_comb begin
    case (conv_result_commit_layer_id)
      1: conv_write_words = 13'd5832;
      2: conv_write_words = 13'd4056;
      3: conv_write_words = 13'd8112;
      4: conv_write_words = 13'd5408;
      5: conv_write_words = 13'd1152;
      default: conv_write_words = 0;
    endcase
  end

  assign conv_write_request_valid = conv_result_commit_request_valid &&
                                    conv_data_layer_ready;
  assign conv_write_request_layer_id = conv_result_commit_layer_id;
  assign conv_write_request_tag = conv_result_commit_job_tag;
  assign conv_write_request_word_count = conv_write_words;
  assign conv_write_request_byte_count = {conv_write_words, 3'b000};
  assign conv_result_commit_request_ready = conv_data_layer_ready &&
                                            conv_write_request_ready;

  generate
    if (!EXTERNAL_CONV_STORAGE_COMPLETION) begin : g_axis_only_completion
      assign conv_write_complete_ready = 1'b0;
      assign conv_result_complete_valid = conv_data_layer_done;
      assign conv_result_complete_layer_id = conv_data_completed_layer_id;
      assign conv_result_complete_job_tag = conv_data_completed_job_tag;
      assign conv_result_complete_error = data_service_fault;
      assign storage_completion_fault = 1'b0;
    end else begin : g_physical_storage_completion
      logic data_done_q, write_done_q;
      logic write_error_q;
      logic [2:0] expected_layer_q, data_layer_q;
      logic [15:0] expected_tag_q, data_tag_q;
      logic result_complete_fire;

      assign conv_write_complete_ready = !write_done_q;
      assign conv_result_complete_valid = data_done_q && write_done_q;
      assign conv_result_complete_layer_id = data_layer_q;
      assign conv_result_complete_job_tag = data_tag_q;
      assign conv_result_complete_error = data_service_fault || write_error_q;
      assign result_complete_fire = conv_result_complete_valid &&
                                    conv_result_complete_ready;
      assign storage_completion_fault = write_error_q;

      always_ff @(posedge clk) begin
        if (rst) begin
          data_done_q <= 1'b0;
          write_done_q <= 1'b0;
          write_error_q <= 1'b0;
          expected_layer_q <= 0;
          expected_tag_q <= 0;
          data_layer_q <= 0;
          data_tag_q <= 0;
        end else begin
          if (conv_result_commit_request_valid &&
              conv_result_commit_request_ready) begin
            data_done_q <= 1'b0;
            write_done_q <= 1'b0;
            write_error_q <= 1'b0;
            expected_layer_q <= conv_result_commit_layer_id;
            expected_tag_q <= conv_result_commit_job_tag;
          end
          if (conv_data_layer_done) begin
            data_done_q <= 1'b1;
            data_layer_q <= conv_data_completed_layer_id;
            data_tag_q <= conv_data_completed_job_tag;
            if (conv_data_completed_layer_id != expected_layer_q ||
                conv_data_completed_job_tag != expected_tag_q)
              write_error_q <= 1'b1;
          end
          if (conv_write_complete_valid && conv_write_complete_ready) begin
            write_done_q <= 1'b1;
            if (conv_write_complete_error ||
                conv_write_complete_layer_id != expected_layer_q ||
                conv_write_complete_tag != expected_tag_q)
              write_error_q <= 1'b1;
          end
          if (result_complete_fire) begin
            data_done_q <= 1'b0;
            write_done_q <= 1'b0;
          end
        end
      end
    end
  endgenerate

  assign conv_service_error = data_service_fault || storage_completion_fault;
  assign fc_service_error = fc_backend_error || data_service_fault;

  assign graph_output_is_conv = active_layer_id <= 5;
  assign storage_owner_fc = !graph_output_is_conv;
  assign m_axis_tready = graph_output_is_conv ? conv_raw_axis_tready :
                                               storage_axis_tready;
  assign conv_stored_axis_tready = graph_output_is_conv &&
                                   storage_axis_tready;
  assign storage_axis_tdata = graph_output_is_conv ? conv_stored_axis_tdata :
                                                    m_axis_tdata;
  assign storage_axis_tkeep = graph_output_is_conv ? conv_stored_axis_tkeep :
                                                    m_axis_tkeep;
  assign storage_axis_tvalid = graph_output_is_conv ? conv_stored_axis_tvalid :
                                                     m_axis_tvalid;
  assign storage_axis_tlast = graph_output_is_conv ? conv_stored_axis_tlast :
                                                    m_axis_tlast;

  assign fault = graph_fault || data_service_fault || storage_completion_fault;

  alexnet_m4n8_graph_compute_top u_graph (
      .fault(graph_fault),
      .*
  );

  alexnet_conv_fc_data_service u_data_service (
      .clk(clk), .rst(rst),
      .conv_layer_valid(conv_result_commit_request_valid &&
                        conv_write_request_ready),
      .conv_layer_ready(conv_data_layer_ready),
      .conv_layer_id(conv_result_commit_layer_id),
      .conv_layer_job_tag(conv_result_commit_job_tag),
      .conv_layer_raw_h(conv_result_commit_output_h),
      .conv_layer_raw_w(conv_result_commit_output_w),
      .conv_layer_n8_tiles(conv_result_commit_output_channels[8:3]),
      .conv_layer_pool_enable(conv_result_commit_pool_enable),
      .conv_layer_stored_h(conv_result_commit_pool_enable ?
          conv_result_commit_pool_output_h : conv_result_commit_output_h[5:0]),
      .conv_layer_stored_w(conv_result_commit_pool_enable ?
          conv_result_commit_pool_output_w : conv_result_commit_output_w[5:0]),
      .conv_raw_axis_tdata(m_axis_tdata),
      .conv_raw_axis_tkeep(m_axis_tkeep),
      .conv_raw_axis_tvalid(m_axis_tvalid && graph_output_is_conv),
      .conv_raw_axis_tready(conv_raw_axis_tready),
      .conv_raw_axis_tlast(m_axis_tlast),
      .conv_stored_axis_tdata(conv_stored_axis_tdata),
      .conv_stored_axis_tkeep(conv_stored_axis_tkeep),
      .conv_stored_axis_tvalid(conv_stored_axis_tvalid),
      .conv_stored_axis_tready(conv_stored_axis_tready),
      .conv_stored_axis_tlast(conv_stored_axis_tlast),
      .conv_layer_done(conv_data_layer_done),
      .conv_completed_layer_id(conv_data_completed_layer_id),
      .conv_completed_job_tag(conv_data_completed_job_tag),
      .fc_request_valid(fc_read_request_valid),
      .fc_request_ready(fc_read_request_ready),
      .fc_active_layer_id(fc_active_layer_id),
      .fc_active_k_offset(fc_active_k_offset),
      .fc_active_k_count(fc_active_k_count),
      .fc_request_destination(fc_read_request_destination),
      .fc_request_word_count(fc_read_request_word_count),
      .fc_request_byte_count(fc_read_request_byte_count),
      .fc_request_m_count(fc_read_request_m_count),
      .fc_request_tag(fc_read_request_tag),
      .fc_external_request_valid(fc_external_request_valid),
      .fc_external_request_ready(fc_external_request_ready),
      .fc_external_request_layer_id(fc_external_request_layer_id),
      .fc_external_request_k_offset(fc_external_request_k_offset),
      .fc_external_request_k_count(fc_external_request_k_count),
      .fc_external_request_destination(fc_external_request_destination),
      .fc_external_request_word_count(fc_external_request_word_count),
      .fc_external_request_byte_count(fc_external_request_byte_count),
      .fc_external_request_m_count(fc_external_request_m_count),
      .fc_external_request_tag(fc_external_request_tag),
      .external_axis_tdata(external_mm2s_axis_tdata),
      .external_axis_tkeep(external_mm2s_axis_tkeep),
      .external_axis_tvalid(external_mm2s_axis_tvalid),
      .external_axis_tready(external_mm2s_axis_tready),
      .external_axis_tlast(external_mm2s_axis_tlast),
      .compute_axis_tdata(s_axis_tdata),
      .compute_axis_tkeep(s_axis_tkeep),
      .compute_axis_tvalid(s_axis_tvalid),
      .compute_axis_tready(s_axis_tready),
      .compute_axis_tlast(s_axis_tlast),
      .pool5_cache_valid(pool5_cache_valid),
      .pool5_cache_tag(pool5_cache_tag),
      .pool5_cache_write_done(pool5_cache_write_done),
      .fc6_flatten_active(fc6_flatten_active),
      .fc6_flatten_done(fc6_flatten_done),
      .fault(data_service_fault),
      .conv_raw_words(conv_raw_words),
      .conv_stored_words(conv_stored_words),
      .fc6_completed_scalars(fc6_completed_scalars),
      .fc6_completed_words(fc6_completed_words)
  );

`ifndef SYNTHESIS
  always_ff @(posedge clk) begin
    if (!rst) begin
      if (!EXTERNAL_CONV_STORAGE_COMPLETION && conv_data_layer_done &&
          !conv_result_complete_ready)
        $fatal(1, "Conv result completion was not accepted by graph control");
      if (!graph_output_is_conv && conv_stored_axis_tvalid)
        $fatal(1, "Conv data service remained active during FC output");
    end
  end
`endif
endmodule
