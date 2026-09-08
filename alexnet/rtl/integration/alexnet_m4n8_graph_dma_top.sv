`timescale 1ns/1ps

// Full AlexNet graph/data plane with one physical AXI DMA simple-mode command
// owner. The remaining board shell supplies the AXI DMA IP, PS memory map,
// AXI-Lite interconnect, clock/reset, and camera preprocessing stream.
module alexnet_m4n8_graph_dma_top #(
    parameter logic [31:0] DMA_BASE_ADDR = 32'ha001_0000
) (
    input logic clk,
    input logic rst,
    input logic ce,
    input logic start_valid,
    output logic start_ready,
    input logic [15:0] start_tag,

    input logic [63:0] input_base,
    input logic [63:0] activation_a_base,
    input logic [63:0] activation_b_base,
    input logic [63:0] weights_base,
    input logic [63:0] parameters_base,
    input logic [63:0] final_output_base,
    input logic [31:0] dma_timeout_cycles,

    // Conv1 direct stream after PS camera resize/normalize/INT8 packing.
    input logic camera_n8_valid,
    output logic camera_n8_ready,
    input logic [63:0] camera_n8_values,
    input logic [7:0] camera_n8_lane_mask,
    input logic camera_n8_last,

    // AXI DMA MM2S and S2MM payload interfaces, both 128 bits wide.
    input logic [127:0] s_axis_mm2s_tdata,
    input logic [15:0] s_axis_mm2s_tkeep,
    input logic s_axis_mm2s_tvalid,
    output logic s_axis_mm2s_tready,
    input logic s_axis_mm2s_tlast,
    output logic [127:0] m_axis_s2mm_tdata,
    output logic [15:0] m_axis_s2mm_tkeep,
    output logic m_axis_s2mm_tvalid,
    input logic m_axis_s2mm_tready,
    output logic m_axis_s2mm_tlast,

    // AXI-Lite master to the AXI DMA control register bank.
    output logic [31:0] m_axi_dma_awaddr,
    output logic [2:0] m_axi_dma_awprot,
    output logic m_axi_dma_awvalid,
    input logic m_axi_dma_awready,
    output logic [31:0] m_axi_dma_wdata,
    output logic [3:0] m_axi_dma_wstrb,
    output logic m_axi_dma_wvalid,
    input logic m_axi_dma_wready,
    input logic [1:0] m_axi_dma_bresp,
    input logic m_axi_dma_bvalid,
    output logic m_axi_dma_bready,
    output logic [31:0] m_axi_dma_araddr,
    output logic [2:0] m_axi_dma_arprot,
    output logic m_axi_dma_arvalid,
    input logic m_axi_dma_arready,
    input logic [31:0] m_axi_dma_rdata,
    input logic [1:0] m_axi_dma_rresp,
    input logic m_axi_dma_rvalid,
    output logic m_axi_dma_rready,

    output logic busy,
    output logic inference_done,
    output logic inference_failed,
    output logic fault,
    output logic [3:0] fault_code,
    output logic [7:0] fault_detail,
    output logic [4:0] graph_phase,
    output logic [3:0] active_layer_id,
    output logic [15:0] active_inference_tag,
    output logic [2:0] completed_conv_layers,
    output logic [1:0] completed_fc_layers,
    output logic pool5_cache_valid,
    output logic dma_busy,
    output logic dma_armed,
    output logic dma_done,
    output logic dma_error,
    output logic [3:0] dma_error_code,
    output logic [2:0] dma_active_source,
    output logic [31:0] dma_accepted_requests,
    output logic [31:0] dma_issued_commands,
    output logic [31:0] dma_completed_transfers,
    output logic [31:0] conv_storage_completed_tiles
);
  localparam logic [2:0] SOURCE_CONV_PARAMETER = 3'd2;
  localparam logic [2:0] SOURCE_FC_PARAMETER = 3'd5;
  localparam logic [2:0] SOURCE_CONV_RESULT = 3'd6;
  localparam logic [2:0] SOURCE_FC_RESULT = 3'd7;

  logic [127:0] graph_mm2s_tdata, graph_storage_tdata;
  logic [15:0] graph_mm2s_tkeep, graph_storage_tkeep;
  logic graph_mm2s_tvalid, graph_mm2s_tready, graph_mm2s_tlast;
  logic graph_storage_tvalid, graph_storage_tready, graph_storage_tlast;
  logic storage_owner_fc;

  logic rs_mm2s_request_valid, rs_mm2s_request_ready;
  logic [1:0] rs_mm2s_request_destination;
  logic [10:0] rs_mm2s_request_word_count;
  logic [15:0] rs_mm2s_request_byte_count, rs_mm2s_request_tag;
  logic [15:0] rs_mm2s_request_n_base;
  logic [7:0] rs_mm2s_request_chunk_index;
  logic local_rs_s2mm_request_valid;
  logic [12:0] local_rs_s2mm_request_word_count;
  logic [15:0] local_rs_s2mm_request_byte_count;
  logic [15:0] local_rs_s2mm_request_n_base, local_rs_s2mm_request_tag;

  logic conv_parameter_request_valid, conv_parameter_request_ready;
  logic [2:0] conv_parameter_request_layer_id;
  logic [15:0] conv_parameter_request_job_tag;
  logic [15:0] conv_parameter_request_n_base;
  logic conv_parameter_valid, conv_parameter_ready;
  logic [2:0] conv_parameter_layer_id;
  logic [15:0] conv_parameter_job_tag, conv_parameter_n_base;
  logic signed [31:0] conv_parameter_bias [0:7];
  logic signed [17:0] conv_parameter_multiplier [0:7];
  logic [5:0] conv_parameter_right_shift [0:7];

  logic fc_parameter_request_valid, fc_parameter_valid, fc_parameter_ready;
  logic [3:0] fc_active_layer_id;
  logic [2:0] fc_active_m_count;
  logic [15:0] fc_active_job_tag, fc_active_n_base;
  logic [13:0] fc_active_k_offset;
  logic [9:0] fc_active_k_count;
  logic [3:0] fc_parameter_layer_id;
  logic [15:0] fc_parameter_job_tag, fc_parameter_n_base;
  logic signed [31:0] fc_parameter_bias [0:7];
  logic signed [17:0] fc_parameter_multiplier [0:7];
  logic [5:0] fc_parameter_right_shift [0:7];

  logic conv_write_request_valid, conv_write_request_ready;
  logic [2:0] conv_write_request_layer_id;
  logic [15:0] conv_write_request_tag;
  logic [12:0] conv_write_request_word_count;
  logic [15:0] conv_write_request_byte_count;
  logic conv_write_complete_valid, conv_write_complete_ready;
  logic [2:0] conv_write_complete_layer_id;
  logic [15:0] conv_write_complete_tag;
  logic conv_write_complete_error;

  logic fc_external_request_valid, fc_external_request_ready;
  logic [3:0] fc_external_request_layer_id;
  logic [13:0] fc_external_request_k_offset;
  logic [9:0] fc_external_request_k_count;
  logic [1:0] fc_external_request_destination;
  logic [9:0] fc_external_request_word_count;
  logic [15:0] fc_external_request_byte_count;
  logic [2:0] fc_external_request_m_count;
  logic [15:0] fc_external_request_tag;

  logic fc_result_request_valid, fc_result_request_ready;
  logic [1:0] fc_result_request_destination;
  logic [15:0] fc_result_request_byte_count, fc_result_request_tag;
  logic fc_result_complete_valid, fc_result_complete_ready;
  logic [15:0] fc_result_complete_n_base, fc_result_complete_tag;
  logic fc_result_complete_error;

  logic graph_busy, graph_fault, compute_fault, data_service_fault;
  logic camera_replay_valid, camera_replay_ready, camera_replay_last;
  logic [63:0] camera_replay_values;
  logic [7:0] camera_replay_lane_mask;
  logic camera_frame_valid, camera_replay_busy, camera_replay_fault;
  logic [3:0] camera_completed_replays;
  logic start_fire;
  logic [15:0] pool5_cache_tag;
  logic pool5_cache_write_done, fc6_flatten_active, fc6_flatten_done;
  logic [31:0] conv_raw_words, conv_stored_words;
  logic [13:0] fc6_completed_scalars;
  logic [10:0] fc6_completed_words;

  logic conv_dma_request_valid, conv_dma_request_ready;
  logic [3:0] conv_dma_request_layer_id;
  logic [15:0] conv_dma_request_n_base;
  logic [12:0] conv_dma_request_word_count;
  logic [15:0] conv_dma_request_byte_count, conv_dma_request_tag;
  logic [127:0] conv_dma_axis_tdata;
  logic [15:0] conv_dma_axis_tkeep;
  logic conv_dma_axis_tvalid, conv_dma_axis_tready, conv_dma_axis_tlast;
  logic conv_storage_axis_ready, conv_transfer_complete_ready;
  logic conv_storage_busy, conv_storage_fault;
  logic [5:0] conv_storage_active_tile;
  logic [15:0] conv_storage_active_bytes;
  logic [31:0] conv_storage_completed_layers;

  logic bridge_cmd_valid, bridge_cmd_ready, bridge_cmd_s2mm;
  logic [31:0] bridge_cmd_address;
  logic [25:0] bridge_cmd_length_bytes;
  logic [31:0] bridge_cmd_timeout_cycles;
  logic [2:0] bridge_cmd_source, bridge_cmd_buffer_id;
  logic [3:0] bridge_cmd_layer_id;
  logic [15:0] bridge_cmd_n_base, bridge_cmd_tag;
  logic bridge_transfer_complete_valid, bridge_transfer_complete_error;
  logic [2:0] bridge_transfer_complete_source;
  logic [3:0] bridge_transfer_complete_layer_id;
  logic [15:0] bridge_transfer_complete_n_base;
  logic [15:0] bridge_transfer_complete_tag;
  logic bridge_busy, bridge_fault, bridge_request_rejected;
  logic [31:0] bridge_rejected_requests;

  logic router_launch_ready, router_busy, router_fault;
  logic parameter_valid, parameter_ready, parameter_is_fc;
  logic [3:0] parameter_layer_id;
  logic [15:0] parameter_job_tag, parameter_n_base;
  logic signed [31:0] parameter_bias [0:7];
  logic signed [17:0] parameter_multiplier [0:7];
  logic [5:0] parameter_right_shift [0:7];
  logic [25:0] router_bytes_transferred;
  logic [31:0] router_launched_reads, router_completed_reads;

  logic dma_master_cmd_ready, dma_master_busy;
  logic dma_master_cmd_valid, router_launch_valid;
  logic [31:0] dma_last_status, dma_active_cycles;
  logic [3:0] dma_state_debug;
  logic physical_backend_fault;
  logic bridge_conv_parameter_ready, bridge_fc_parameter_ready;
  logic bridge_fc_external_ready, bridge_fc_result_ready;
  logic bridge_rs_s2mm_ready;

  assign parameter_ready = parameter_is_fc ? fc_parameter_ready :
                                              conv_parameter_ready;
  assign conv_parameter_valid = parameter_valid && !parameter_is_fc;
  assign conv_parameter_layer_id = parameter_layer_id[2:0];
  assign conv_parameter_job_tag = parameter_job_tag;
  assign conv_parameter_n_base = parameter_n_base;
  assign conv_parameter_bias = parameter_bias;
  assign conv_parameter_multiplier = parameter_multiplier;
  assign conv_parameter_right_shift = parameter_right_shift;
  assign fc_parameter_valid = parameter_valid && parameter_is_fc;
  assign fc_parameter_layer_id = parameter_layer_id;
  assign fc_parameter_job_tag = parameter_job_tag;
  assign fc_parameter_n_base = parameter_n_base;
  assign fc_parameter_bias = parameter_bias;
  assign fc_parameter_multiplier = parameter_multiplier;
  assign fc_parameter_right_shift = parameter_right_shift;

  // Both the DMA CSR master and read owner must accept an MM2S command in the
  // same cycle. S2MM commands see router_launch_ready asserted without taking
  // read-stream ownership.
  assign bridge_cmd_ready = dma_master_cmd_ready && router_launch_ready;
  assign dma_master_cmd_valid = bridge_cmd_valid && router_launch_ready;
  assign router_launch_valid = bridge_cmd_valid && dma_master_cmd_ready;

  assign start_fire = start_valid && start_ready;
  assign physical_backend_fault = bridge_fault || router_fault ||
                                  conv_storage_fault || dma_error ||
                                  camera_replay_fault;
  // Preserve the existing four-bit graph fault code and expose the physical
  // source separately for board bring-up.  These bits are intentionally
  // orthogonal: more than one sticky source may be set after propagation.
  assign fault_detail = {
      physical_backend_fault, graph_fault, dma_error, conv_storage_fault,
      router_fault, bridge_fault,
      data_service_fault || camera_replay_fault, compute_fault
  };
  assign busy = graph_busy || bridge_busy || router_busy || camera_replay_busy ||
                conv_storage_busy || dma_master_busy;
  assign fault = graph_fault || physical_backend_fault;
  assign dma_busy = dma_master_busy;
  assign dma_active_source = bridge_cmd_valid ? bridge_cmd_source :
                                                bridge_transfer_complete_source;

  // Conv results pass through optional pool first. FC results are already in
  // final stream form and go directly to the physical S2MM input.
  assign graph_storage_tready = storage_owner_fc ? m_axis_s2mm_tready :
                                                  conv_storage_axis_ready;
  assign m_axis_s2mm_tdata = storage_owner_fc ? graph_storage_tdata :
                                               conv_dma_axis_tdata;
  assign m_axis_s2mm_tkeep = storage_owner_fc ? graph_storage_tkeep :
                                               conv_dma_axis_tkeep;
  assign m_axis_s2mm_tvalid = storage_owner_fc ? graph_storage_tvalid :
                                                conv_dma_axis_tvalid;
  assign m_axis_s2mm_tlast = storage_owner_fc ? graph_storage_tlast :
                                               conv_dma_axis_tlast;

  assign conv_parameter_request_ready = bridge_conv_parameter_ready;
  assign fc_external_request_ready = bridge_fc_external_ready;
  assign fc_result_request_ready = bridge_fc_result_ready;

  assign conv_dma_request_ready = bridge_rs_s2mm_ready;

  assign fc_result_complete_valid = bridge_transfer_complete_valid &&
      bridge_transfer_complete_source == SOURCE_FC_RESULT;
  assign fc_result_complete_n_base = bridge_transfer_complete_n_base;
  assign fc_result_complete_tag = bridge_transfer_complete_tag;
  assign fc_result_complete_error = bridge_transfer_complete_error;

  alexnet_m4n8_graph_data_top #(
      .EXTERNAL_CONV_STORAGE_COMPLETION(1'b1)
  ) u_graph_data (
      .clk(clk), .rst(rst), .ce(ce), .start_valid(start_valid),
      .start_ready(start_ready), .start_tag(start_tag),
      .external_mm2s_axis_tdata(graph_mm2s_tdata),
      .external_mm2s_axis_tkeep(graph_mm2s_tkeep),
      .external_mm2s_axis_tvalid(graph_mm2s_tvalid),
      .external_mm2s_axis_tready(graph_mm2s_tready),
      .external_mm2s_axis_tlast(graph_mm2s_tlast),
      .storage_axis_tdata(graph_storage_tdata),
      .storage_axis_tkeep(graph_storage_tkeep),
      .storage_axis_tvalid(graph_storage_tvalid),
      .storage_axis_tready(graph_storage_tready),
      .storage_axis_tlast(graph_storage_tlast),
      .storage_owner_fc(storage_owner_fc),
      .rs_mm2s_request_valid(rs_mm2s_request_valid),
      .rs_mm2s_request_ready(rs_mm2s_request_ready),
      .rs_mm2s_request_destination(rs_mm2s_request_destination),
      .rs_mm2s_request_word_count(rs_mm2s_request_word_count),
      .rs_mm2s_request_byte_count(rs_mm2s_request_byte_count),
      .rs_mm2s_request_tag(rs_mm2s_request_tag),
      .rs_mm2s_request_n_base(rs_mm2s_request_n_base),
      .rs_mm2s_request_chunk_index(rs_mm2s_request_chunk_index),
      .rs_s2mm_request_valid(local_rs_s2mm_request_valid),
      .rs_s2mm_request_ready(1'b1),
      .rs_s2mm_request_word_count(local_rs_s2mm_request_word_count),
      .rs_s2mm_request_byte_count(local_rs_s2mm_request_byte_count),
      .rs_s2mm_request_n_base(local_rs_s2mm_request_n_base),
      .rs_s2mm_request_tag(local_rs_s2mm_request_tag),
      .rs_activation_stream_valid(camera_replay_valid),
      .rs_activation_stream_ready(camera_replay_ready),
      .rs_activation_stream_values(camera_replay_values),
      .rs_activation_stream_lane_mask(camera_replay_lane_mask),
      .rs_activation_stream_last(camera_replay_last),
      .conv_parameter_request_valid(conv_parameter_request_valid),
      .conv_parameter_request_ready(conv_parameter_request_ready),
      .conv_parameter_request_layer_id(conv_parameter_request_layer_id),
      .conv_parameter_request_job_tag(conv_parameter_request_job_tag),
      .conv_parameter_request_n_base(conv_parameter_request_n_base),
      .conv_parameter_valid(conv_parameter_valid),
      .conv_parameter_ready(conv_parameter_ready),
      .conv_parameter_layer_id(conv_parameter_layer_id),
      .conv_parameter_job_tag(conv_parameter_job_tag),
      .conv_parameter_n_base(conv_parameter_n_base),
      .conv_parameter_bias(conv_parameter_bias),
      .conv_parameter_multiplier(conv_parameter_multiplier),
      .conv_parameter_right_shift(conv_parameter_right_shift),
      .fc_parameter_request_valid(fc_parameter_request_valid),
      .fc_active_layer_id(fc_active_layer_id),
      .fc_active_m_count(fc_active_m_count),
      .fc_active_job_tag(fc_active_job_tag),
      .fc_active_n_base(fc_active_n_base),
      .fc_active_k_offset(fc_active_k_offset),
      .fc_active_k_count(fc_active_k_count),
      .fc_parameter_valid(fc_parameter_valid),
      .fc_parameter_ready(fc_parameter_ready),
      .fc_parameter_layer_id(fc_parameter_layer_id),
      .fc_parameter_job_tag(fc_parameter_job_tag),
      .fc_parameter_n_base(fc_parameter_n_base),
      .fc_parameter_bias(fc_parameter_bias),
      .fc_parameter_multiplier(fc_parameter_multiplier),
      .fc_parameter_right_shift(fc_parameter_right_shift),
      .conv_write_request_valid(conv_write_request_valid),
      .conv_write_request_ready(conv_write_request_ready),
      .conv_write_request_layer_id(conv_write_request_layer_id),
      .conv_write_request_tag(conv_write_request_tag),
      .conv_write_request_word_count(conv_write_request_word_count),
      .conv_write_request_byte_count(conv_write_request_byte_count),
      .conv_write_complete_valid(conv_write_complete_valid),
      .conv_write_complete_ready(conv_write_complete_ready),
      .conv_write_complete_layer_id(conv_write_complete_layer_id),
      .conv_write_complete_tag(conv_write_complete_tag),
      .conv_write_complete_error(conv_write_complete_error),
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
      .fc_result_request_valid(fc_result_request_valid),
      .fc_result_request_ready(fc_result_request_ready),
      .fc_result_request_destination(fc_result_request_destination),
      .fc_result_request_byte_count(fc_result_request_byte_count),
      .fc_result_request_tag(fc_result_request_tag),
      .fc_result_complete_valid(fc_result_complete_valid),
      .fc_result_complete_ready(fc_result_complete_ready),
      .fc_result_complete_n_base(fc_result_complete_n_base),
      .fc_result_complete_tag(fc_result_complete_tag),
      .fc_result_complete_error(fc_result_complete_error),
      .fc_backend_error(physical_backend_fault),
      .busy(graph_busy), .inference_done(inference_done),
      .inference_failed(inference_failed), .fault(graph_fault),
      .fault_code(fault_code), .graph_phase(graph_phase),
      .active_layer_id(active_layer_id),
      .active_inference_tag(active_inference_tag),
      .completed_conv_layers(completed_conv_layers),
      .completed_fc_layers(completed_fc_layers),
      .pool5_cache_valid(pool5_cache_valid),
      .pool5_cache_tag(pool5_cache_tag),
      .pool5_cache_write_done(pool5_cache_write_done),
      .fc6_flatten_active(fc6_flatten_active),
      .fc6_flatten_done(fc6_flatten_done),
      .conv_raw_words(conv_raw_words),
      .conv_stored_words(conv_stored_words),
      .fc6_completed_scalars(fc6_completed_scalars),
      .fc6_completed_words(fc6_completed_words),
      .compute_fault(compute_fault),
      .data_service_fault(data_service_fault)
  );

  alexnet_camera_frame_replay #(
      .FRAME_WORDS(224 * 224), .REPLAY_COUNT(8)
  ) u_camera_frame_replay (
      .clk(clk), .rst(rst), .ce(ce), .start(start_fire),
      .s_valid(camera_n8_valid), .s_ready(camera_n8_ready),
      .s_values(camera_n8_values), .s_lane_mask(camera_n8_lane_mask),
      .s_last(camera_n8_last),
      .m_valid(camera_replay_valid), .m_ready(camera_replay_ready),
      .m_values(camera_replay_values),
      .m_lane_mask(camera_replay_lane_mask), .m_last(camera_replay_last),
      .frame_valid(camera_frame_valid), .busy(camera_replay_busy),
      .fault(camera_replay_fault),
      .completed_replays(camera_completed_replays)
  );

  alexnet_conv_storage_dma_scheduler u_conv_storage (
      .clk(clk), .rst(rst),
      .layer_start_valid(conv_write_request_valid),
      .layer_start_ready(conv_write_request_ready),
      .layer_start_id(conv_write_request_layer_id),
      .layer_start_tag(conv_write_request_tag),
      .layer_start_word_count(conv_write_request_word_count),
      .layer_start_byte_count(conv_write_request_byte_count),
      .request_valid(conv_dma_request_valid),
      .request_ready(conv_dma_request_ready),
      .request_layer_id(conv_dma_request_layer_id),
      .request_n_base(conv_dma_request_n_base),
      .request_word_count(conv_dma_request_word_count),
      .request_byte_count(conv_dma_request_byte_count),
      .request_tag(conv_dma_request_tag),
      .transfer_complete_valid(bridge_transfer_complete_valid &&
          bridge_transfer_complete_source == SOURCE_CONV_RESULT),
      .transfer_complete_ready(conv_transfer_complete_ready),
      .transfer_complete_error(bridge_transfer_complete_error),
      .transfer_complete_layer_id(bridge_transfer_complete_layer_id),
      .transfer_complete_n_base(bridge_transfer_complete_n_base),
      .transfer_complete_tag(bridge_transfer_complete_tag),
      .storage_axis_tdata(graph_storage_tdata),
      .storage_axis_tkeep(graph_storage_tkeep),
      .storage_axis_tvalid(graph_storage_tvalid && !storage_owner_fc),
      .storage_axis_tready(conv_storage_axis_ready),
      .storage_axis_tlast(graph_storage_tlast),
      .dma_axis_tdata(conv_dma_axis_tdata),
      .dma_axis_tkeep(conv_dma_axis_tkeep),
      .dma_axis_tvalid(conv_dma_axis_tvalid),
      .dma_axis_tready(conv_dma_axis_tready),
      .dma_axis_tlast(conv_dma_axis_tlast),
      .layer_complete_valid(conv_write_complete_valid),
      .layer_complete_ready(conv_write_complete_ready),
      .layer_complete_id(conv_write_complete_layer_id),
      .layer_complete_tag(conv_write_complete_tag),
      .layer_complete_error(conv_write_complete_error),
      .busy(conv_storage_busy), .fault(conv_storage_fault),
      .active_tile_index(conv_storage_active_tile),
      .active_tile_bytes(conv_storage_active_bytes),
      .completed_tiles(conv_storage_completed_tiles),
      .completed_layers(conv_storage_completed_layers)
  );

  // The scheduler's storage-ready output is equivalent to the already
  // selected graph_storage_tready when Conv owns the stream.
  assign conv_dma_axis_tready = m_axis_s2mm_tready;

  alexnet_graph_dma_descriptor_bridge u_descriptor_bridge (
      .clk(clk), .rst(rst),
      .input_base(input_base), .activation_a_base(activation_a_base),
      .activation_b_base(activation_b_base), .weights_base(weights_base),
      .parameters_base(parameters_base),
      .final_output_base(final_output_base),
      .dma_timeout_cycles(dma_timeout_cycles),
      .rs_mm2s_request_valid(rs_mm2s_request_valid),
      .rs_mm2s_request_ready(rs_mm2s_request_ready),
      .rs_active_layer_id(active_layer_id),
      .rs_mm2s_request_destination(rs_mm2s_request_destination),
      .rs_mm2s_request_word_count(rs_mm2s_request_word_count),
      .rs_mm2s_request_byte_count(rs_mm2s_request_byte_count),
      .rs_mm2s_request_tag(rs_mm2s_request_tag),
      .rs_mm2s_request_n_base(rs_mm2s_request_n_base),
      .rs_mm2s_request_chunk_index(rs_mm2s_request_chunk_index),
      .rs_s2mm_request_valid(conv_dma_request_valid),
      .rs_s2mm_request_ready(bridge_rs_s2mm_ready),
      .rs_s2mm_request_word_count(conv_dma_request_word_count),
      .rs_s2mm_request_byte_count(conv_dma_request_byte_count),
      .rs_s2mm_request_n_base(conv_dma_request_n_base),
      .rs_s2mm_request_tag(conv_dma_request_tag),
      .conv_parameter_request_valid(conv_parameter_request_valid),
      .conv_parameter_request_ready(bridge_conv_parameter_ready),
      .conv_parameter_request_layer_id(conv_parameter_request_layer_id),
      .conv_parameter_request_n_base(conv_parameter_request_n_base),
      .conv_parameter_request_tag(conv_parameter_request_job_tag),
      .fc_parameter_request_valid(fc_parameter_request_valid),
      .fc_parameter_request_ready(bridge_fc_parameter_ready),
      .fc_parameter_request_layer_id(fc_active_layer_id),
      .fc_parameter_request_n_base(fc_active_n_base),
      .fc_parameter_request_tag(fc_active_job_tag),
      .fc_external_request_valid(fc_external_request_valid),
      .fc_external_request_ready(bridge_fc_external_ready),
      .fc_external_request_layer_id(fc_external_request_layer_id),
      .fc_external_request_n_base(fc_active_n_base),
      .fc_external_request_k_offset(fc_external_request_k_offset),
      .fc_external_request_k_count(fc_external_request_k_count),
      .fc_external_request_destination(fc_external_request_destination),
      .fc_external_request_word_count(fc_external_request_word_count),
      .fc_external_request_byte_count(fc_external_request_byte_count),
      .fc_external_request_m_count(fc_external_request_m_count),
      .fc_external_request_tag(fc_external_request_tag),
      .fc_result_request_valid(fc_result_request_valid),
      .fc_result_request_ready(bridge_fc_result_ready),
      .fc_result_request_layer_id(fc_active_layer_id),
      .fc_result_request_n_base(fc_active_n_base),
      .fc_result_request_m_count(fc_active_m_count),
      .fc_result_request_destination(fc_result_request_destination),
      .fc_result_request_byte_count(fc_result_request_byte_count),
      .fc_result_request_tag(fc_result_request_tag),
      .dma_cmd_valid(bridge_cmd_valid), .dma_cmd_ready(bridge_cmd_ready),
      .dma_cmd_s2mm(bridge_cmd_s2mm),
      .dma_cmd_address(bridge_cmd_address),
      .dma_cmd_length_bytes(bridge_cmd_length_bytes),
      .dma_cmd_timeout_cycles(bridge_cmd_timeout_cycles),
      .dma_cmd_source(bridge_cmd_source),
      .dma_cmd_layer_id(bridge_cmd_layer_id),
      .dma_cmd_buffer_id(bridge_cmd_buffer_id),
      .dma_cmd_n_base(bridge_cmd_n_base), .dma_cmd_tag(bridge_cmd_tag),
      .dma_armed(dma_armed), .dma_done(dma_done), .dma_error(dma_error),
      .transfer_complete_valid(bridge_transfer_complete_valid),
      .transfer_complete_error(bridge_transfer_complete_error),
      .transfer_complete_source(bridge_transfer_complete_source),
      .transfer_complete_layer_id(bridge_transfer_complete_layer_id),
      .transfer_complete_n_base(bridge_transfer_complete_n_base),
      .transfer_complete_tag(bridge_transfer_complete_tag),
      .busy(bridge_busy), .fault(bridge_fault),
      .request_rejected(bridge_request_rejected),
      .accepted_requests(dma_accepted_requests),
      .issued_commands(dma_issued_commands),
      .completed_transfers(dma_completed_transfers),
      .rejected_requests(bridge_rejected_requests)
  );

  alexnet_graph_dma_read_router u_read_router (
      .clk(clk), .rst(rst), .launch_valid(router_launch_valid),
      .launch_ready(router_launch_ready), .launch_s2mm(bridge_cmd_s2mm),
      .launch_source(bridge_cmd_source),
      .launch_layer_id(bridge_cmd_layer_id),
      .launch_n_base(bridge_cmd_n_base), .launch_tag(bridge_cmd_tag),
      .launch_length_bytes(bridge_cmd_length_bytes),
      .dma_done(dma_done), .dma_error(dma_error),
      .s_axis_tdata(s_axis_mm2s_tdata),
      .s_axis_tkeep(s_axis_mm2s_tkeep),
      .s_axis_tvalid(s_axis_mm2s_tvalid),
      .s_axis_tready(s_axis_mm2s_tready),
      .s_axis_tlast(s_axis_mm2s_tlast),
      .graph_axis_tdata(graph_mm2s_tdata),
      .graph_axis_tkeep(graph_mm2s_tkeep),
      .graph_axis_tvalid(graph_mm2s_tvalid),
      .graph_axis_tready(graph_mm2s_tready),
      .graph_axis_tlast(graph_mm2s_tlast),
      .parameter_valid(parameter_valid), .parameter_ready(parameter_ready),
      .parameter_is_fc(parameter_is_fc),
      .parameter_layer_id(parameter_layer_id),
      .parameter_job_tag(parameter_job_tag),
      .parameter_n_base(parameter_n_base),
      .parameter_bias(parameter_bias),
      .parameter_multiplier(parameter_multiplier),
      .parameter_right_shift(parameter_right_shift),
      .busy(router_busy), .fault(router_fault),
      .active_source(), .bytes_transferred(router_bytes_transferred),
      .launched_reads(router_launched_reads),
      .completed_reads(router_completed_reads)
  );

  axi_dma_simple_master #(
      .DMA_BASE_ADDR(DMA_BASE_ADDR), .DMA_ALIGNMENT_BYTES(8)
  ) u_dma_master (
      .clk(clk), .rst_n(!rst), .clear_error(1'b0),
      .cmd_valid(dma_master_cmd_valid), .cmd_ready(dma_master_cmd_ready),
      .cmd_s2mm(bridge_cmd_s2mm),
      .cmd_buffer_addr(bridge_cmd_address),
      .cmd_length_bytes(bridge_cmd_length_bytes),
      .cmd_timeout_cycles(bridge_cmd_timeout_cycles),
      .armed(dma_armed), .busy(dma_master_busy), .done(dma_done),
      .error(dma_error), .error_code(dma_error_code),
      .last_status(dma_last_status), .active_cycles(dma_active_cycles),
      .state_debug(dma_state_debug),
      .m_axi_awaddr(m_axi_dma_awaddr), .m_axi_awprot(m_axi_dma_awprot),
      .m_axi_awvalid(m_axi_dma_awvalid), .m_axi_awready(m_axi_dma_awready),
      .m_axi_wdata(m_axi_dma_wdata), .m_axi_wstrb(m_axi_dma_wstrb),
      .m_axi_wvalid(m_axi_dma_wvalid), .m_axi_wready(m_axi_dma_wready),
      .m_axi_bresp(m_axi_dma_bresp), .m_axi_bvalid(m_axi_dma_bvalid),
      .m_axi_bready(m_axi_dma_bready), .m_axi_araddr(m_axi_dma_araddr),
      .m_axi_arprot(m_axi_dma_arprot), .m_axi_arvalid(m_axi_dma_arvalid),
      .m_axi_arready(m_axi_dma_arready), .m_axi_rdata(m_axi_dma_rdata),
      .m_axi_rresp(m_axi_dma_rresp), .m_axi_rvalid(m_axi_dma_rvalid),
      .m_axi_rready(m_axi_dma_rready)
  );

`ifndef SYNTHESIS
  always_ff @(posedge clk) begin
    if (!rst) begin
      if (bridge_transfer_complete_valid &&
          bridge_transfer_complete_source == SOURCE_CONV_RESULT &&
          !conv_transfer_complete_ready)
        $fatal(1, "Conv physical completion arrived outside scheduler wait");
      if (fc_result_complete_valid && !fc_result_complete_ready)
        $fatal(1, "FC physical completion arrived before controller wait");
      if (parameter_valid &&
          ((parameter_is_fc && parameter_layer_id < 6) ||
           (!parameter_is_fc && parameter_layer_id > 5)))
        $fatal(1, "parameter loader response routed to wrong controller");
    end
  end
`endif
endmodule
