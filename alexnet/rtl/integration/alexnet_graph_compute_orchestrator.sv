`timescale 1ns/1ps

// Control-plane integration boundary for one full AlexNet inference.
// It connects the fixed Conv1..FC8 graph to the Conv layer expander, the
// shared-compute ownership port, the RS command port, and the existing FC
// layer-job port. Payload and result services remain explicit interfaces.
module alexnet_graph_compute_orchestrator (
    input logic clk,
    input logic rst,
    input logic start_valid,
    output logic start_ready,
    input logic [15:0] start_tag,

    output logic owner_valid,
    input  logic owner_ready,
    output logic owner_fc,
    output logic owner_release_valid,
    input  logic owner_release_ready,
    input  logic owner_active,
    input  logic active_owner_fc,
    input  logic owner_released,
    input  logic owner_fault,

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

    output logic conv_result_commit_request_valid,
    input  logic conv_result_commit_request_ready,
    output logic [2:0] conv_result_commit_layer_id,
    output logic [15:0] conv_result_commit_job_tag,
    output logic [7:0] conv_result_commit_output_h,
    output logic [7:0] conv_result_commit_output_w,
    output logic [9:0] conv_result_commit_output_channels,
    output logic conv_result_commit_pool_enable,
    output logic [5:0] conv_result_commit_pool_output_h,
    output logic [5:0] conv_result_commit_pool_output_w,
    output logic conv_result_commit_flatten_output,
    input  logic conv_result_complete_valid,
    output logic conv_result_complete_ready,
    input  logic [2:0] conv_result_complete_layer_id,
    input  logic [15:0] conv_result_complete_job_tag,
    input  logic conv_result_complete_error,
    input  logic conv_service_error,

    output logic rs_cfg_valid,
    input  logic rs_cfg_ready,
    output logic [1:0] rs_cfg_destination,
    output logic [15:0] rs_cfg_n64_tile_base,
    output logic [2:0] rs_cfg_slice_index,
    output logic [7:0] rs_cfg_lane_mask,
    output logic signed [31:0] rs_cfg_bias [0:7],
    output logic signed [17:0] rs_cfg_multiplier [0:7],
    output logic [5:0] rs_cfg_right_shift [0:7],
    output logic [7:0] rs_cfg_relu,

    output logic rs_command_valid,
    input  logic rs_command_ready,
    output logic [15:0] rs_command_id,
    output logic rs_command_activation_streaming,
    output logic [1:0] rs_command_activation_destination,
    output logic [10:0] rs_command_activation_word_count,
    output logic [15:0] rs_command_activation_byte_count,
    output logic [7:0] rs_command_activation_lane_mask,
    output logic [15:0] rs_command_activation_tensor_tag,
    output logic [10:0] rs_command_weight_word_count,
    output logic [15:0] rs_command_weight_byte_count,
    output logic [7:0] rs_command_weight_lane_mask,
    output logic [15:0] rs_command_weight_context_tag,
    output logic rs_command_result_enable,
    output logic [12:0] rs_command_result_word_count,
    output logic [15:0] rs_command_result_byte_count,
    output logic [1:0] rs_command_result_destination,
    output logic [2:0] rs_command_result_slice,
    output logic [15:0] rs_command_result_n_base,
    output logic [7:0] rs_command_result_lane_mask,
    output logic [15:0] rs_command_result_first_tile_tag,
    output logic [7:0] rs_command_chunk_input_h,
    output logic [7:0] rs_command_chunk_input_w,
    output logic [3:0] rs_command_chunk_channel_count,
    output logic [7:0] rs_command_chunk_input_lane_mask,
    output logic [3:0] rs_command_chunk_kernel,
    output logic [2:0] rs_command_chunk_stride,
    output logic [2:0] rs_command_chunk_padding,
    output logic [9:0] rs_command_chunk_k_count,
    output logic [15:0] rs_command_chunk_weight_context_tag,
    output logic [12:0] rs_command_chunk_word_count,
    output logic [7:0] rs_command_chunk_output_width,
    output logic [15:0] rs_command_chunk_accum_context_tag,
    output logic [15:0] rs_command_chunk_tile_tag_base,
    output logic [7:0] rs_command_chunk_index,
    output logic rs_command_chunk_first,
    output logic rs_command_chunk_final,
    input logic rs_command_done,
    input logic rs_command_rejected,
    input logic rs_command_error,
    input logic [15:0] rs_completed_command_id,
    input logic rs_scheduler_fault,

    output logic fc_job_valid,
    input  logic fc_job_ready,
    output logic [3:0] fc_job_layer_id,
    output logic [2:0] fc_job_m_count,
    output logic [15:0] fc_job_tag,
    input logic fc_layer_done,
    input logic fc_job_rejected,
    input logic fc_layer_failed,
    input logic [3:0] fc_active_layer_id,
    input logic [15:0] fc_active_job_tag,
    input logic fc_service_error,

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
    output logic [12:0] active_conv_completed_commands,
    output logic [5:0] active_conv_completed_n8_tiles,
    output logic [15:0] active_conv_completed_output_words
);
  logic conv_job_valid;
  logic conv_job_ready;
  logic [2:0] conv_layer_id;
  logic [15:0] conv_job_tag;
  logic [8:0] conv_input_h, conv_input_w;
  logic [9:0] conv_input_channels, conv_output_channels;
  logic [7:0] conv_output_h, conv_output_w;
  logic [3:0] conv_kernel;
  logic [2:0] conv_stride, conv_padding;
  logic [5:0] conv_n8_tiles, conv_input_chunks;
  logic conv_activation_streaming, conv_pool_enable, conv_flatten_output;
  logic [5:0] conv_pool_output_h, conv_pool_output_w;
  logic conv_complete_valid, conv_complete_ready;
  logic [2:0] conv_complete_layer_id;
  logic [15:0] conv_complete_tag;
  logic conv_complete_error;
  logic conv_control_fault;
  logic [3:0] conv_control_fault_code;
  logic [3:0] conv_control_phase;
  logic [5:0] active_conv_n8_tile, active_conv_input_chunk;
  logic fc_complete_valid;
  logic fc_complete_ready;
  logic fc_complete_error;

  assign fc_complete_valid = fc_layer_done || fc_job_rejected ||
                             fc_layer_failed;
  assign fc_complete_error = fc_job_rejected || fc_layer_failed;

  alexnet_graph_controller u_graph (
      .clk(clk), .rst(rst),
      .start_valid(start_valid), .start_ready(start_ready),
      .start_tag(start_tag),
      .owner_valid(owner_valid), .owner_ready(owner_ready),
      .owner_fc(owner_fc),
      .owner_release_valid(owner_release_valid),
      .owner_release_ready(owner_release_ready),
      .owner_active(owner_active), .active_owner_fc(active_owner_fc),
      .owner_released(owner_released), .owner_fault(owner_fault),
      .conv_job_valid(conv_job_valid), .conv_job_ready(conv_job_ready),
      .conv_layer_id(conv_layer_id), .conv_job_tag(conv_job_tag),
      .conv_input_h(conv_input_h), .conv_input_w(conv_input_w),
      .conv_input_channels(conv_input_channels),
      .conv_output_channels(conv_output_channels),
      .conv_output_h(conv_output_h), .conv_output_w(conv_output_w),
      .conv_kernel(conv_kernel), .conv_stride(conv_stride),
      .conv_padding(conv_padding), .conv_n8_tiles(conv_n8_tiles),
      .conv_input_chunks(conv_input_chunks),
      .conv_activation_streaming(conv_activation_streaming),
      .conv_pool_enable(conv_pool_enable),
      .conv_pool_output_h(conv_pool_output_h),
      .conv_pool_output_w(conv_pool_output_w),
      .conv_flatten_output(conv_flatten_output),
      .conv_complete_valid(conv_complete_valid),
      .conv_complete_ready(conv_complete_ready),
      .conv_complete_layer_id(conv_complete_layer_id),
      .conv_complete_tag(conv_complete_tag),
      .conv_complete_error(conv_complete_error),
      .fc_job_valid(fc_job_valid), .fc_job_ready(fc_job_ready),
      .fc_layer_id(fc_job_layer_id), .fc_m_count(fc_job_m_count),
      .fc_job_tag(fc_job_tag), .fc_complete_valid(fc_complete_valid),
      .fc_complete_ready(fc_complete_ready),
      .fc_complete_layer_id(fc_active_layer_id),
      .fc_complete_tag(fc_active_job_tag),
      .fc_complete_error(fc_complete_error),
      .service_error(conv_service_error || fc_service_error),
      .busy(busy), .inference_done(inference_done),
      .inference_failed(inference_failed), .fault(fault),
      .fault_code(fault_code), .phase(graph_phase),
      .active_layer_id(active_layer_id),
      .active_inference_tag(active_inference_tag),
      .completed_conv_layers(completed_conv_layers),
      .completed_fc_layers(completed_fc_layers)
  );

  alexnet_conv_layer_controller u_conv (
      .clk(clk), .rst(rst),
      .job_valid(conv_job_valid), .job_ready(conv_job_ready),
      .job_layer_id(conv_layer_id), .job_tag(conv_job_tag),
      .job_input_h(conv_input_h), .job_input_w(conv_input_w),
      .job_input_channels(conv_input_channels),
      .job_output_channels(conv_output_channels),
      .job_output_h(conv_output_h), .job_output_w(conv_output_w),
      .job_kernel(conv_kernel), .job_stride(conv_stride),
      .job_padding(conv_padding), .job_n8_tiles(conv_n8_tiles),
      .job_input_chunks(conv_input_chunks),
      .job_activation_streaming(conv_activation_streaming),
      .job_pool_enable(conv_pool_enable),
      .job_pool_output_h(conv_pool_output_h),
      .job_pool_output_w(conv_pool_output_w),
      .job_flatten_output(conv_flatten_output),
      .parameter_request_valid(conv_parameter_request_valid),
      .parameter_request_ready(conv_parameter_request_ready),
      .parameter_request_layer_id(conv_parameter_request_layer_id),
      .parameter_request_job_tag(conv_parameter_request_job_tag),
      .parameter_request_n_base(conv_parameter_request_n_base),
      .parameter_valid(conv_parameter_valid),
      .parameter_ready(conv_parameter_ready),
      .parameter_layer_id(conv_parameter_layer_id),
      .parameter_job_tag(conv_parameter_job_tag),
      .parameter_n_base(conv_parameter_n_base),
      .parameter_bias(conv_parameter_bias),
      .parameter_multiplier(conv_parameter_multiplier),
      .parameter_right_shift(conv_parameter_right_shift),
      .result_commit_request_valid(conv_result_commit_request_valid),
      .result_commit_request_ready(conv_result_commit_request_ready),
      .result_commit_layer_id(conv_result_commit_layer_id),
      .result_commit_job_tag(conv_result_commit_job_tag),
      .result_commit_output_h(conv_result_commit_output_h),
      .result_commit_output_w(conv_result_commit_output_w),
      .result_commit_output_channels(conv_result_commit_output_channels),
      .result_commit_pool_enable(conv_result_commit_pool_enable),
      .result_commit_pool_output_h(conv_result_commit_pool_output_h),
      .result_commit_pool_output_w(conv_result_commit_pool_output_w),
      .result_commit_flatten_output(conv_result_commit_flatten_output),
      .result_complete_valid(conv_result_complete_valid),
      .result_complete_ready(conv_result_complete_ready),
      .result_complete_layer_id(conv_result_complete_layer_id),
      .result_complete_job_tag(conv_result_complete_job_tag),
      .result_complete_error(conv_result_complete_error),
      .service_error(conv_service_error),
      .cfg_valid(rs_cfg_valid), .cfg_ready(rs_cfg_ready),
      .cfg_destination(rs_cfg_destination),
      .cfg_n64_tile_base(rs_cfg_n64_tile_base),
      .cfg_slice_index(rs_cfg_slice_index),
      .cfg_lane_mask(rs_cfg_lane_mask), .cfg_bias(rs_cfg_bias),
      .cfg_multiplier(rs_cfg_multiplier),
      .cfg_right_shift(rs_cfg_right_shift), .cfg_relu(rs_cfg_relu),
      .command_valid(rs_command_valid), .command_ready(rs_command_ready),
      .command_id(rs_command_id),
      .command_activation_streaming(rs_command_activation_streaming),
      .command_activation_destination(rs_command_activation_destination),
      .command_activation_word_count(rs_command_activation_word_count),
      .command_activation_byte_count(rs_command_activation_byte_count),
      .command_activation_lane_mask(rs_command_activation_lane_mask),
      .command_activation_tensor_tag(rs_command_activation_tensor_tag),
      .command_weight_word_count(rs_command_weight_word_count),
      .command_weight_byte_count(rs_command_weight_byte_count),
      .command_weight_lane_mask(rs_command_weight_lane_mask),
      .command_weight_context_tag(rs_command_weight_context_tag),
      .command_result_enable(rs_command_result_enable),
      .command_result_word_count(rs_command_result_word_count),
      .command_result_byte_count(rs_command_result_byte_count),
      .command_result_destination(rs_command_result_destination),
      .command_result_slice(rs_command_result_slice),
      .command_result_n_base(rs_command_result_n_base),
      .command_result_lane_mask(rs_command_result_lane_mask),
      .command_result_first_tile_tag(rs_command_result_first_tile_tag),
      .command_chunk_input_h(rs_command_chunk_input_h),
      .command_chunk_input_w(rs_command_chunk_input_w),
      .command_chunk_channel_count(rs_command_chunk_channel_count),
      .command_chunk_input_lane_mask(rs_command_chunk_input_lane_mask),
      .command_chunk_kernel(rs_command_chunk_kernel),
      .command_chunk_stride(rs_command_chunk_stride),
      .command_chunk_padding(rs_command_chunk_padding),
      .command_chunk_k_count(rs_command_chunk_k_count),
      .command_chunk_weight_context_tag(
          rs_command_chunk_weight_context_tag),
      .command_chunk_word_count(rs_command_chunk_word_count),
      .command_chunk_output_width(rs_command_chunk_output_width),
      .command_chunk_accum_context_tag(rs_command_chunk_accum_context_tag),
      .command_chunk_tile_tag_base(rs_command_chunk_tile_tag_base),
      .command_chunk_index(rs_command_chunk_index),
      .command_chunk_first(rs_command_chunk_first),
      .command_chunk_final(rs_command_chunk_final),
      .command_done(rs_command_done),
      .command_rejected(rs_command_rejected),
      .command_error(rs_command_error),
      .completed_command_id(rs_completed_command_id),
      .core_fault(rs_scheduler_fault || owner_fault),
      .complete_valid(conv_complete_valid),
      .complete_ready(conv_complete_ready),
      .complete_layer_id(conv_complete_layer_id),
      .complete_job_tag(conv_complete_tag),
      .complete_error(conv_complete_error),
      .busy(), .fault(conv_control_fault),
      .fault_code(conv_control_fault_code), .phase(conv_control_phase),
      .active_n8_tile(active_conv_n8_tile),
      .active_input_chunk(active_conv_input_chunk),
      .completed_commands(active_conv_completed_commands),
      .completed_n8_tiles(active_conv_completed_n8_tiles),
      .completed_output_words(active_conv_completed_output_words)
  );

`ifndef SYNTHESIS
  always_ff @(posedge clk) begin
    if (!rst) begin
      if (rs_command_valid && (!owner_active || active_owner_fc))
        $fatal(1, "orchestrator issued Conv command without Conv ownership");
      if (fc_job_valid && (!owner_active || !active_owner_fc))
        $fatal(1, "orchestrator issued FC job without FC ownership");
      if (conv_control_fault && !conv_complete_valid)
        $fatal(1, "orchestrator lost Conv controller fault completion");
    end
  end
`endif
endmodule
