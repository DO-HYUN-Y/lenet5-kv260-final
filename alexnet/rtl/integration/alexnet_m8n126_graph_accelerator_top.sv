`timescale 1ns/1ps

// PS-facing batch-one M8xN126 graph-payload accelerator.
//
// HP0 first supplies the normal 224x224xN8 input raster.  An x-mod-4 feeder
// assembles Conv1 M16 patches locally. Conv2-FC8 activations are cached once
// per layer from the N8-tile-major A/B tensors and gathered into the exact
// K-major M16 stream. HP1 scatter-writes results and HP3 fills weights.
module alexnet_m8n126_graph_accelerator_top #(
    parameter int CTRL_ADDR_W = 8
) (
    input logic aclk,
    input logic aresetn,

    input logic [CTRL_ADDR_W-1:0] s_axi_ctrl_awaddr,
    input logic [2:0] s_axi_ctrl_awprot,
    input logic s_axi_ctrl_awvalid,
    output logic s_axi_ctrl_awready,
    input logic [31:0] s_axi_ctrl_wdata,
    input logic [3:0] s_axi_ctrl_wstrb,
    input logic s_axi_ctrl_wvalid,
    output logic s_axi_ctrl_wready,
    output logic [1:0] s_axi_ctrl_bresp,
    output logic s_axi_ctrl_bvalid,
    input logic s_axi_ctrl_bready,
    input logic [CTRL_ADDR_W-1:0] s_axi_ctrl_araddr,
    input logic [2:0] s_axi_ctrl_arprot,
    input logic s_axi_ctrl_arvalid,
    output logic s_axi_ctrl_arready,
    output logic [31:0] s_axi_ctrl_rdata,
    output logic [1:0] s_axi_ctrl_rresp,
    output logic s_axi_ctrl_rvalid,
    input logic s_axi_ctrl_rready,

    input logic [63:0] s_axis_camera_tdata,
    input logic [7:0] s_axis_camera_tkeep,
    input logic s_axis_camera_tvalid,
    output logic s_axis_camera_tready,
    input logic s_axis_camera_tlast,

    input logic [127:0] s_axis_mm2s_tdata,
    input logic [15:0] s_axis_mm2s_tkeep,
    input logic s_axis_mm2s_tvalid,
    output logic s_axis_mm2s_tready,
    input logic s_axis_mm2s_tlast,

    input logic [127:0] s_axis_weight_tdata,
    input logic [15:0] s_axis_weight_tkeep,
    input logic s_axis_weight_tvalid,
    output logic s_axis_weight_tready,
    input logic s_axis_weight_tlast,

    output logic [127:0] m_axis_s2mm_tdata,
    output logic [15:0] m_axis_s2mm_tkeep,
    output logic m_axis_s2mm_tvalid,
    input logic m_axis_s2mm_tready,
    output logic m_axis_s2mm_tlast,

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

    output logic [31:0] m_axi_weight_dma_awaddr,
    output logic [2:0] m_axi_weight_dma_awprot,
    output logic m_axi_weight_dma_awvalid,
    input logic m_axi_weight_dma_awready,
    output logic [31:0] m_axi_weight_dma_wdata,
    output logic [3:0] m_axi_weight_dma_wstrb,
    output logic m_axi_weight_dma_wvalid,
    input logic m_axi_weight_dma_wready,
    input logic [1:0] m_axi_weight_dma_bresp,
    input logic m_axi_weight_dma_bvalid,
    output logic m_axi_weight_dma_bready,
    output logic [31:0] m_axi_weight_dma_araddr,
    output logic [2:0] m_axi_weight_dma_arprot,
    output logic m_axi_weight_dma_arvalid,
    input logic m_axi_weight_dma_arready,
    input logic [31:0] m_axi_weight_dma_rdata,
    input logic [1:0] m_axi_weight_dma_rresp,
    input logic m_axi_weight_dma_rvalid,
    output logic m_axi_weight_dma_rready,

    output logic irq,
    output logic accelerator_busy,
    output logic accelerator_fault
);

  typedef enum logic [3:0] {
    MAIN_IDLE,
    MAIN_RASTER_COMMAND,
    MAIN_RASTER_ARM,
    MAIN_RASTER_STREAM,
    MAIN_RASTER_DRAIN,
    MAIN_PARAMETER_STREAM,
    MAIN_PARAMETER_DRAIN,
    MAIN_RESULT_COMMAND,
    MAIN_RESULT_ARM,
    MAIN_RESULT_WAIT,
    MAIN_RESULT_DRAIN,
    MAIN_FAILED
  } main_state_t;

  logic rst;
  main_state_t main_state_q;
  logic service_fault_q;
  logic main_s2mm_done_seen_q, weight_dma_done_seen_q;
  logic weight_service_active_q, weight_stream_done_q;
  logic parameter_service_active_q, raster_stream_active_q;
  logic result_slice_reset_pending_q;
  logic [31:0] weight_byte_offset_q;
  logic [4:0] result_slice_index_q;
  logic [12:0] patch_m_base_q;
  logic [3:0] patch_lower_m_count_q, patch_upper_m_count_q;
  logic [3:0] pending_result_m_count_q;
  logic [12:0] pending_result_m_base_q;
  logic [15:0] pending_result_n_base_q;
  logic [25:0] pending_result_bytes_q;
  logic [31:0] pending_result_address_q;

  logic core_start_valid, core_start_ready;
  logic engine_start_ready;
  logic engine_start_valid, engine_start_fire;
  logic [15:0] core_start_tag;
  logic [15:0] active_inference_tag_q;
  logic [63:0] active_input_base, active_activation_a_base;
  logic [63:0] active_activation_b_base, active_weights_base;
  logic [63:0] active_parameters_base, active_final_output_base;
  logic [31:0] active_dma_timeout_cycles;

  logic engine_weight_request_valid, engine_weight_request_ready;
  logic [3:0] engine_weight_request_layer_id;
  logic [15:0] engine_weight_request_n_base;
  logic [13:0] engine_weight_request_k_offset;
  logic [12:0] engine_weight_request_k_count;
  logic [7:0] engine_weight_request_bank_enable;
  logic [15:0] engine_weight_request_n_lane_mask [0:7];
  logic [15:0] engine_weight_request_context_tag;
  logic engine_weight_axis_ready;

  logic engine_patch_request_valid, engine_patch_request_ready;
  logic [3:0] engine_patch_request_layer_id;
  logic [12:0] engine_patch_request_m_base;
  logic [13:0] engine_patch_request_k_offset;
  logic [12:0] engine_patch_request_k_count;
  logic [15:0] engine_patch_request_m_lane_mask;
  logic [15:0] engine_patch_request_context_tag;
  logic engine_patch_axis_ready;

  logic raster_frame_valid, raster_frame_ready;
  logic raster_axis_ready;
  logic raster_request_ready;
  logic raster_patch_axis_valid, raster_patch_axis_ready;
  logic [127:0] raster_patch_axis_data;
  logic raster_patch_axis_last;
  logic raster_active, raster_frame_active, raster_frame_done;
  logic [15:0] raster_completed_fills, raster_completed_replays;
  logic raster_overlap_active, raster_fault, raster_idle;
  logic raster_patch_active_q;
  logic engine_start_pending_q;

  logic activation_request_valid, activation_request_ready;
  logic activation_dma_cmd_valid, activation_dma_cmd_ready;
  logic activation_dma_selected, activation_mm2s_ready;
  logic [31:0] activation_dma_cmd_address;
  logic [25:0] activation_dma_cmd_length;
  logic [127:0] activation_patch_axis_data;
  logic activation_patch_axis_valid, activation_patch_axis_last;
  logic activation_busy, activation_fault, activation_cache_load_active;
  logic [3:0] activation_cached_layer_id;
  logic [15:0] unused_activation_context_tag;
  logic [7:0] unused_activation_m_count;
  logic [31:0] activation_cache_loads, activation_completed_patches;
  logic [31:0] activation_emitted_patch_words;

  logic engine_parameter_request_valid, engine_parameter_request_ready;
  logic [3:0] engine_parameter_request_layer_id;
  logic [15:0] engine_parameter_request_n_base;
  logic [15:0] engine_parameter_request_context_tag;
  logic engine_parameter_valid, engine_parameter_ready;
  logic [15:0] engine_parameter_n_base, engine_parameter_context_tag;
  logic signed [31:0] engine_parameter_bias [0:7];
  logic signed [17:0] engine_parameter_multiplier [0:7];
  logic [5:0] engine_parameter_right_shift [0:7];
  logic [7:0] engine_parameter_relu;

  logic engine_result_valid, engine_result_ready;
  logic [63:0] engine_result_values [0:7];
  logic [7:0] engine_result_lane_mask [0:7];
  logic [3:0] engine_result_m_count;
  logic [12:0] engine_result_m_base;
  logic [15:0] engine_result_n_base, engine_result_tile_tag;
  logic engine_result_last_slice;
  logic engine_layer_complete_valid, engine_layer_complete_ready;
  logic [3:0] engine_layer_complete_id;
  logic engine_layer_complete_requires_pool;
  logic engine_busy, engine_done, engine_failed, engine_fault;
  logic [3:0] engine_active_layer_id;
  logic [15:0] engine_completed_commands;
  logic [31:0] engine_active_cycles, engine_issue_cycles;
  logic [31:0] engine_patch_stall_cycles, engine_weight_stall_cycles;
  logic [31:0] engine_result_stall_cycles;
  logic [31:0] weight_words_loaded, patch_words_loaded;
  logic [31:0] completed_result_slices;
  logic [63:0] useful_mac_count, physical_mac_slot_count;

  logic pool_layer_valid, pool_layer_ready, pool_layer_done;
  logic pool_layer_error, pool_busy;
  logic pool_layer_accepted_q;
  logic [31:0] pool_layer_base;
  logic pool_dma_cmd_valid, pool_dma_cmd_ready, pool_dma_cmd_s2mm;
  logic [31:0] pool_dma_cmd_address;
  logic [25:0] pool_dma_cmd_length;
  logic pool_mm2s_ready;
  logic pool_dma_active_s2mm_q, pool_command_fire;
  logic [127:0] pool_s2mm_data;
  logic [15:0] pool_s2mm_keep;
  logic pool_s2mm_valid, pool_s2mm_ready, pool_s2mm_last;
  logic [5:0] pool_completed_tiles;
  logic [31:0] pool_raw_words, pool_stored_words;

  logic main_mm2s_cmd_valid, main_mm2s_cmd_ready;
  logic [31:0] main_mm2s_cmd_address;
  logic [25:0] main_mm2s_cmd_length;
  logic main_s2mm_cmd_valid, main_s2mm_cmd_ready;
  logic [31:0] main_s2mm_cmd_address;
  logic [25:0] main_s2mm_cmd_length;
  logic main_mm2s_armed, main_mm2s_busy, main_mm2s_done;
  logic main_mm2s_error;
  logic main_s2mm_armed, main_s2mm_busy, main_s2mm_done;
  logic main_s2mm_error;
  logic [3:0] main_mm2s_error_code, main_s2mm_error_code;
  logic [3:0] unused_main_mm2s_state, unused_main_s2mm_state;
  logic main_dma_busy, main_dma_error;
  logic [3:0] main_dma_error_code;

  logic weight_dma_cmd_valid, weight_dma_cmd_ready;
  logic [31:0] weight_dma_cmd_address;
  logic [25:0] weight_dma_cmd_length;
  logic weight_dma_armed, weight_dma_busy, weight_dma_done;
  logic weight_dma_error;
  logic [3:0] weight_dma_error_code, unused_weight_dma_state;
  logic [31:0] unused_weight_dma_status, unused_weight_dma_cycles;

  logic loader_start_valid, loader_start_ready;
  logic loader_axis_ready, loader_parameter_valid, loader_parameter_ready;
  logic loader_parameter_is_fc;
  logic [3:0] loader_parameter_layer_id;
  logic [15:0] loader_parameter_tag, loader_parameter_n_base;
  logic signed [31:0] loader_parameter_bias [0:7];
  logic signed [17:0] loader_parameter_multiplier [0:7];
  logic [5:0] loader_parameter_right_shift [0:7];
  logic loader_busy, loader_fault;
  logic [2:0] unused_loader_lane;
  logic [31:0] unused_loader_accepted, unused_loader_completed;
  logic [31:0] unused_loader_rejected;

  logic result_packer_active_q;
  logic [3:0] result_packer_m_count_q, result_packer_index_q;
  logic [63:0] result_packer_values_q [0:7];
  logic result_packer_fire, result_packer_done;
  logic [31:0] result_signature_q;
  logic [31:0] result_signature_fold;

  logic [3:0] requested_result_m_count;
  logic [25:0] weight_request_bytes;
  logic [31:0] parameter_address;
  logic [31:0] selected_result_base;
  logic [12:0] predicted_result_m_base;
  logic [31:0] mapped_result_address;
  logic [25:0] mapped_result_bytes;
  logic result_mapping_error;
  logic main_mm2s_command_fire, main_s2mm_command_fire;
  logic weight_command_fire, parameter_command_fire;
  logic weight_fill_command_selected, parameter_command_selected;
  logic raster_stream_fire, raster_patch_fire;
  logic parameter_stream_fire, weight_stream_fire;
  logic core_start_fire;

  function automatic logic [3:0] popcount8(input logic [7:0] value);
    logic [3:0] count;
    begin
      count = 0;
      for (int bit_index = 0; bit_index < 8; bit_index++)
        count = count + value[bit_index];
      return count;
    end
  endfunction

  function automatic logic [25:0] weight_bytes(
      input logic [12:0] k_count,
      input logic [7:0] bank_enable);
    logic [3:0] banks;
    logic [25:0] k_bytes;
    begin
      banks = popcount8(bank_enable);
      k_bytes = {9'd0, k_count, 4'b0000};
      case (banks)
        1: weight_bytes = k_bytes;
        2: weight_bytes = k_bytes << 1;
        3: weight_bytes = k_bytes + (k_bytes << 1);
        4: weight_bytes = k_bytes << 2;
        5: weight_bytes = k_bytes + (k_bytes << 2);
        6: weight_bytes = (k_bytes << 1) + (k_bytes << 2);
        7: weight_bytes = (k_bytes << 3) - k_bytes;
        8: weight_bytes = k_bytes << 3;
        default: weight_bytes = 0;
      endcase
    end
  endfunction

  function automatic logic [31:0] parameter_layer_offset(
      input logic [3:0] layer_id);
    begin
      case (layer_id)
        1: parameter_layer_offset = 0;
        2: parameter_layer_offset = 1024;
        3: parameter_layer_offset = 4096;
        4: parameter_layer_offset = 10240;
        5: parameter_layer_offset = 14336;
        6: parameter_layer_offset = 18432;
        7: parameter_layer_offset = 83968;
        8: parameter_layer_offset = 149504;
        default: parameter_layer_offset = 0;
      endcase
    end
  endfunction

  assign rst = !aresetn;
  assign core_start_ready = main_state_q == MAIN_IDLE &&
                            engine_start_ready && raster_frame_ready &&
                            !accelerator_fault;
  assign core_start_fire = core_start_valid && core_start_ready;
  assign engine_start_valid = engine_start_pending_q &&
                              main_state_q == MAIN_RASTER_ARM &&
                              !accelerator_fault;
  assign engine_start_fire = engine_start_valid && engine_start_ready;
  assign raster_frame_valid = core_start_valid && core_start_ready;
  assign s_axis_camera_tready = 1'b1;
  assign activation_request_valid = engine_patch_request_valid &&
      engine_patch_request_layer_id != 1 && main_state_q == MAIN_IDLE &&
      !pool_busy && !main_mm2s_busy && !accelerator_fault;
  assign activation_dma_cmd_ready = activation_dma_selected &&
                                    main_mm2s_cmd_ready;

  assign weight_request_bytes = weight_bytes(
      engine_weight_request_k_count, engine_weight_request_bank_enable);
  assign requested_result_m_count =
      engine_parameter_request_layer_id <= 2 &&
      patch_upper_m_count_q != 0 && result_slice_index_q >= 8 ?
      patch_upper_m_count_q : patch_lower_m_count_q;
  assign parameter_address = active_parameters_base[31:0] +
      parameter_layer_offset(engine_parameter_request_layer_id) +
      {12'd0, engine_parameter_request_n_base, 4'b0000};
  assign selected_result_base =
      engine_parameter_request_layer_id == 1 ||
      engine_parameter_request_layer_id == 3 ||
      engine_parameter_request_layer_id == 5 ||
      engine_parameter_request_layer_id == 7 ?
      active_activation_a_base[31:0] :
      engine_parameter_request_layer_id == 8 ?
      active_final_output_base[31:0] : active_activation_b_base[31:0];
  assign pool_layer_base = engine_layer_complete_id == 2 ?
                           active_activation_b_base[31:0] :
                           active_activation_a_base[31:0];
  assign pool_layer_valid = engine_layer_complete_valid &&
                            engine_layer_complete_requires_pool &&
                            !pool_layer_accepted_q &&
                            main_state_q == MAIN_IDLE &&
                            !result_packer_active_q &&
                            !main_mm2s_busy && !main_s2mm_busy;
  assign engine_layer_complete_ready = engine_layer_complete_valid &&
      (engine_layer_complete_requires_pool ? pool_layer_done : 1'b1);
  assign predicted_result_m_base = patch_m_base_q +
      (engine_parameter_request_layer_id <= 2 &&
       patch_upper_m_count_q != 0 && result_slice_index_q >= 8 ? 13'd8 : 0);

  alexnet_m8n126_result_address_mapper u_result_address_mapper (
      .result_base(selected_result_base),
      .layer_id(engine_parameter_request_layer_id),
      .result_m_base(predicted_result_m_base),
      .result_n_base(engine_parameter_request_n_base),
      .result_m_count(requested_result_m_count),
      .result_address(mapped_result_address),
      .result_byte_count(mapped_result_bytes),
      .layer_spatial_count(),
      .descriptor_error(result_mapping_error)
  );

  always_comb begin
    main_mm2s_cmd_valid = 1'b0;
    main_mm2s_cmd_address = 0;
    main_mm2s_cmd_length = 0;
    main_s2mm_cmd_valid = 1'b0;
    main_s2mm_cmd_address = 0;
    main_s2mm_cmd_length = 0;
    engine_patch_request_ready = 1'b0;
    activation_dma_selected = 1'b0;

    if (pool_dma_cmd_valid && !accelerator_fault) begin
      if (pool_dma_cmd_s2mm) begin
        main_s2mm_cmd_valid = 1'b1;
        main_s2mm_cmd_address = pool_dma_cmd_address;
        main_s2mm_cmd_length = pool_dma_cmd_length;
      end else begin
        main_mm2s_cmd_valid = 1'b1;
        main_mm2s_cmd_address = pool_dma_cmd_address;
        main_mm2s_cmd_length = pool_dma_cmd_length;
      end
    end else if (main_state_q == MAIN_RASTER_COMMAND && !accelerator_fault) begin
      main_mm2s_cmd_valid = 1'b1;
      main_mm2s_cmd_address = active_input_base[31:0];
      main_mm2s_cmd_length = 26'd401408;
    end else if (engine_patch_request_valid &&
                 engine_patch_request_layer_id == 1 &&
                 !accelerator_fault) begin
      engine_patch_request_ready = raster_request_ready;
    end else if (main_state_q == MAIN_IDLE && !accelerator_fault) begin
      if (activation_dma_cmd_valid) begin
        activation_dma_selected = 1'b1;
        main_mm2s_cmd_valid = 1'b1;
        main_mm2s_cmd_address = activation_dma_cmd_address;
        main_mm2s_cmd_length = activation_dma_cmd_length;
      end else if (engine_patch_request_valid &&
                   engine_patch_request_layer_id != 1) begin
        engine_patch_request_ready = activation_request_ready;
      end
    end else if (main_state_q == MAIN_RESULT_COMMAND &&
                 !accelerator_fault) begin
      main_s2mm_cmd_valid = 1'b1;
      main_s2mm_cmd_address = pending_result_address_q;
      main_s2mm_cmd_length = pending_result_bytes_q;
    end
  end

  assign main_mm2s_command_fire = main_mm2s_cmd_valid &&
                                   main_mm2s_cmd_ready;
  assign main_s2mm_command_fire = main_s2mm_cmd_valid &&
                                   main_s2mm_cmd_ready;
  assign pool_dma_cmd_ready = pool_dma_cmd_valid && !accelerator_fault &&
      (pool_dma_cmd_s2mm ? main_s2mm_cmd_ready : main_mm2s_cmd_ready);
  assign pool_command_fire = pool_dma_cmd_valid && pool_dma_cmd_ready;
  assign weight_fill_command_selected = engine_weight_request_valid &&
      !weight_service_active_q && !parameter_service_active_q &&
      !accelerator_fault;
  assign parameter_command_selected = !weight_fill_command_selected &&
      engine_parameter_request_valid && loader_start_ready &&
      main_state_q == MAIN_IDLE && !weight_service_active_q &&
      !parameter_service_active_q && !accelerator_fault;
  assign weight_dma_cmd_valid = weight_fill_command_selected ||
                                parameter_command_selected;
  assign weight_dma_cmd_address = parameter_command_selected ?
      parameter_address : active_weights_base[31:0] + weight_byte_offset_q;
  assign weight_dma_cmd_length = parameter_command_selected ?
                                 26'd128 : weight_request_bytes;
  assign engine_weight_request_ready = weight_fill_command_selected &&
                                       weight_dma_cmd_ready;
  assign engine_parameter_request_ready = parameter_command_selected &&
                                          weight_dma_cmd_ready;
  assign loader_start_valid = engine_parameter_request_ready;
  assign weight_command_fire = weight_dma_cmd_valid && weight_dma_cmd_ready;
  assign parameter_command_fire = parameter_command_selected &&
                                  weight_dma_cmd_ready;

  assign s_axis_weight_tready = weight_service_active_q ?
                                engine_weight_axis_ready :
                                parameter_service_active_q ?
                                loader_axis_ready : 1'b0;
  assign weight_stream_fire = weight_service_active_q &&
      s_axis_weight_tvalid && s_axis_weight_tready;
  assign raster_stream_fire = raster_stream_active_q &&
      s_axis_mm2s_tvalid && raster_axis_ready;
  assign raster_patch_fire = raster_patch_axis_valid &&
                             raster_patch_axis_ready;
  assign parameter_stream_fire = parameter_service_active_q &&
      main_state_q == MAIN_PARAMETER_STREAM &&
      s_axis_weight_tvalid && loader_axis_ready;
  assign s_axis_mm2s_tready =
      pool_busy ? pool_mm2s_ready :
      activation_cache_load_active ? activation_mm2s_ready :
      raster_stream_active_q ? raster_axis_ready : 1'b0;

  assign engine_parameter_valid = loader_parameter_valid &&
                                  main_state_q == MAIN_RESULT_WAIT;
  assign loader_parameter_ready = engine_parameter_ready &&
                                  main_state_q == MAIN_RESULT_WAIT;
  assign engine_parameter_n_base = loader_parameter_n_base;
  assign engine_parameter_context_tag = loader_parameter_tag;
  assign engine_parameter_relu = loader_parameter_layer_id == 8 ?
                                  8'h00 : 8'hff;
  always_comb begin
    for (int lane = 0; lane < 8; lane++) begin
      engine_parameter_bias[lane] = loader_parameter_bias[lane];
      engine_parameter_multiplier[lane] =
          loader_parameter_multiplier[lane];
      engine_parameter_right_shift[lane] =
          loader_parameter_right_shift[lane];
    end
  end

  assign engine_result_ready = main_state_q == MAIN_RESULT_WAIT &&
                               !result_packer_active_q;
  assign m_axis_s2mm_tvalid = pool_busy ? pool_s2mm_valid :
                                          result_packer_active_q;
  assign m_axis_s2mm_tdata = pool_busy ? pool_s2mm_data : {
      result_packer_index_q + 1'b1 < result_packer_m_count_q ?
          result_packer_values_q[result_packer_index_q+1'b1] : 64'd0,
      result_packer_values_q[result_packer_index_q]
  };
  assign m_axis_s2mm_tkeep = pool_busy ? pool_s2mm_keep :
      (result_packer_index_q + 1'b1 < result_packer_m_count_q ?
          16'hffff : 16'h00ff);
  assign m_axis_s2mm_tlast = pool_busy ? pool_s2mm_last :
      result_packer_index_q + 2 >= result_packer_m_count_q;
  assign pool_s2mm_ready = pool_busy && m_axis_s2mm_tready;
  assign result_packer_fire = !pool_busy && m_axis_s2mm_tvalid &&
                              m_axis_s2mm_tready;
  assign result_packer_done = result_packer_fire && m_axis_s2mm_tlast;

  always_comb begin
    result_signature_fold = 0;
    for (int row = 0; row < 8; row++)
      result_signature_fold = result_signature_fold ^
                              engine_result_values[row][31:0] ^
                              engine_result_values[row][63:32];
  end

  assign main_dma_busy = main_mm2s_busy || main_s2mm_busy;
  assign main_dma_error = main_mm2s_error || main_s2mm_error;
  assign main_dma_error_code = main_mm2s_error ? main_mm2s_error_code :
                               main_s2mm_error_code;
  assign accelerator_fault = service_fault_q || engine_fault ||
      engine_failed || main_dma_error || weight_dma_error || loader_fault ||
      raster_fault || pool_layer_error || activation_fault;
  assign accelerator_busy = engine_busy || main_state_q != MAIN_IDLE ||
      weight_service_active_q || main_dma_busy || weight_dma_busy ||
      result_packer_active_q || pool_busy || activation_busy;

  always_ff @(posedge aclk) begin
    if (rst) begin
      main_state_q <= MAIN_IDLE;
      service_fault_q <= 1'b0;
      main_s2mm_done_seen_q <= 1'b0;
      weight_dma_done_seen_q <= 1'b0;
      weight_service_active_q <= 1'b0;
      weight_stream_done_q <= 1'b0;
      parameter_service_active_q <= 1'b0;
      raster_stream_active_q <= 1'b0;
      result_slice_reset_pending_q <= 1'b0;
      pool_layer_accepted_q <= 1'b0;
      pool_dma_active_s2mm_q <= 1'b0;
      weight_byte_offset_q <= 0;
      result_slice_index_q <= 0;
      patch_m_base_q <= 0;
      patch_lower_m_count_q <= 0;
      patch_upper_m_count_q <= 0;
      pending_result_m_count_q <= 0;
      pending_result_m_base_q <= 0;
      pending_result_n_base_q <= 0;
      pending_result_bytes_q <= 0;
      pending_result_address_q <= 0;
      result_packer_active_q <= 1'b0;
      result_packer_m_count_q <= 0;
      result_packer_index_q <= 0;
      result_signature_q <= 0;
      active_inference_tag_q <= 0;
      for (int row = 0; row < 8; row++)
        result_packer_values_q[row] <= 0;
      engine_start_pending_q <= 1'b0;
      raster_patch_active_q <= 1'b0;
    end else begin
      if (core_start_fire) begin
        engine_start_pending_q <= 1'b1;
        active_inference_tag_q <= core_start_tag;
        weight_byte_offset_q <= 0;
        result_slice_index_q <= 0;
        result_signature_q <= 0;
        raster_stream_active_q <= 1'b0;
        result_slice_reset_pending_q <= 1'b0;
      end

      if (engine_start_fire)
        engine_start_pending_q <= 1'b0;

      // A layer-complete request is level-held until the pool-done pulse is
      // consumed by the scheduler. The pool service returns to IDLE on that
      // same pulse, so remember the first acceptance and prevent a second
      // launch during the one-cycle scheduler retirement window.
      if (!engine_layer_complete_valid)
        pool_layer_accepted_q <= 1'b0;
      else if (pool_layer_valid && pool_layer_ready)
        pool_layer_accepted_q <= 1'b1;

      if (engine_patch_request_valid && engine_patch_request_ready &&
          engine_patch_request_layer_id == 1) begin
        raster_patch_active_q <= 1'b1;
        patch_m_base_q <= engine_patch_request_m_base;
        patch_lower_m_count_q <=
            popcount8(engine_patch_request_m_lane_mask[7:0]);
        patch_upper_m_count_q <=
            popcount8(engine_patch_request_m_lane_mask[15:8]);
        if (main_state_q == MAIN_IDLE) begin
          result_slice_index_q <= 0;
          result_slice_reset_pending_q <= 1'b0;
        end else begin
          // Patch fill may overlap retirement of the preceding descriptor.
          // Defer the new slice epoch until that old S2MM drain completes;
          // otherwise its final +1 overwrites this reset one cycle later.
          result_slice_reset_pending_q <= 1'b1;
        end
      end
      if (raster_patch_fire && raster_patch_axis_last)
        raster_patch_active_q <= 1'b0;

      if (engine_patch_request_valid && engine_patch_request_ready &&
          engine_patch_request_layer_id != 1) begin
        patch_m_base_q <= engine_patch_request_m_base;
        patch_lower_m_count_q <=
            popcount8(engine_patch_request_m_lane_mask[7:0]);
        patch_upper_m_count_q <=
            popcount8(engine_patch_request_m_lane_mask[15:8]);
        if (main_state_q == MAIN_IDLE) begin
          result_slice_index_q <= 0;
          result_slice_reset_pending_q <= 1'b0;
        end else begin
          result_slice_reset_pending_q <= 1'b1;
        end
      end

      if (main_s2mm_done)
        main_s2mm_done_seen_q <= 1'b1;
      if (weight_dma_done)
        weight_dma_done_seen_q <= 1'b1;

      if (weight_command_fire && weight_fill_command_selected) begin
        weight_service_active_q <= 1'b1;
        weight_stream_done_q <= 1'b0;
        weight_dma_done_seen_q <= 1'b0;
        weight_byte_offset_q <= weight_byte_offset_q +
                                weight_request_bytes;
      end
      if (parameter_command_fire) begin
        parameter_service_active_q <= 1'b1;
        weight_dma_done_seen_q <= 1'b0;
      end
      if (pool_command_fire)
        pool_dma_active_s2mm_q <= pool_dma_cmd_s2mm;
      if (weight_stream_fire) begin
        if (s_axis_weight_tkeep != 16'hffff)
          service_fault_q <= 1'b1;
        if (s_axis_weight_tlast)
          weight_stream_done_q <= 1'b1;
      end
      if (weight_service_active_q &&
          (weight_stream_done_q ||
           (weight_stream_fire && s_axis_weight_tlast)) &&
          (weight_dma_done_seen_q || weight_dma_done)) begin
        weight_service_active_q <= 1'b0;
        weight_stream_done_q <= 1'b0;
        weight_dma_done_seen_q <= 1'b0;
      end

      if (result_packer_fire) begin
        if (result_packer_done)
          result_packer_active_q <= 1'b0;
        else
          result_packer_index_q <= result_packer_index_q + 2;
      end

      case (main_state_q)
        MAIN_IDLE: begin
          if (core_start_fire) begin
            main_state_q <= MAIN_RASTER_COMMAND;
          end else if (engine_parameter_request_valid &&
                       engine_parameter_request_ready) begin
            pending_result_m_count_q <= requested_result_m_count;
            pending_result_m_base_q <= predicted_result_m_base;
            pending_result_n_base_q <= engine_parameter_request_n_base;
            pending_result_bytes_q <= mapped_result_bytes;
            pending_result_address_q <= mapped_result_address;
            if (result_mapping_error)
              service_fault_q <= 1'b1;
            main_state_q <= MAIN_PARAMETER_STREAM;
          end
        end

        MAIN_RASTER_COMMAND: if (main_mm2s_command_fire) begin
          raster_stream_active_q <= 1'b1;
          main_state_q <= MAIN_RASTER_ARM;
        end

        MAIN_RASTER_ARM: begin
          if (engine_start_fire)
            main_state_q <= MAIN_IDLE;
        end

        MAIN_RASTER_STREAM, MAIN_RASTER_DRAIN:
          main_state_q <= MAIN_IDLE;

        MAIN_PARAMETER_STREAM: if (parameter_stream_fire) begin
          if (s_axis_weight_tkeep != 16'hffff)
            service_fault_q <= 1'b1;
          if (s_axis_weight_tlast) begin
            main_state_q <= MAIN_PARAMETER_DRAIN;
          end
        end

        MAIN_PARAMETER_DRAIN:
          if ((weight_dma_done_seen_q || weight_dma_done) &&
              loader_parameter_valid) begin
            weight_dma_done_seen_q <= 1'b0;
            parameter_service_active_q <= 1'b0;
            main_state_q <= MAIN_RESULT_COMMAND;
          end

        MAIN_RESULT_COMMAND: if (main_s2mm_command_fire) begin
          main_s2mm_done_seen_q <= 1'b0;
          main_state_q <= MAIN_RESULT_ARM;
        end

        MAIN_RESULT_ARM: if (main_s2mm_armed)
          main_state_q <= MAIN_RESULT_WAIT;

        MAIN_RESULT_WAIT: if (engine_result_valid && engine_result_ready) begin
          if (engine_result_m_count != pending_result_m_count_q ||
              engine_result_m_count == 0 ||
              engine_result_m_base != pending_result_m_base_q ||
              engine_result_n_base != pending_result_n_base_q)
            service_fault_q <= 1'b1;
          for (int row = 0; row < 8; row++) begin
            result_packer_values_q[row] <= engine_result_values[row];
          end
          result_signature_q <= result_signature_q ^ result_signature_fold;
          result_packer_m_count_q <= engine_result_m_count;
          result_packer_index_q <= 0;
          result_packer_active_q <= 1'b1;
          main_state_q <= MAIN_RESULT_DRAIN;
        end

        MAIN_RESULT_DRAIN:
          if (!result_packer_active_q &&
              (main_s2mm_done_seen_q || main_s2mm_done)) begin
            main_s2mm_done_seen_q <= 1'b0;
            if (result_slice_reset_pending_q ||
                (engine_patch_request_valid &&
                 engine_patch_request_ready)) begin
              result_slice_index_q <= 0;
              result_slice_reset_pending_q <= 1'b0;
            end else begin
              result_slice_index_q <= result_slice_index_q + 1'b1;
            end
            main_state_q <= MAIN_IDLE;
          end

        MAIN_FAILED: main_state_q <= MAIN_FAILED;
        default: begin
          service_fault_q <= 1'b1;
          main_state_q <= MAIN_FAILED;
        end
      endcase

      if (main_dma_error || weight_dma_error || loader_fault || raster_fault ||
          pool_layer_error || activation_fault || engine_fault ||
          engine_failed) begin
        service_fault_q <= 1'b1;
        main_state_q <= MAIN_FAILED;
      end

      if (raster_stream_fire && s_axis_mm2s_tlast)
        raster_stream_active_q <= 1'b0;
    end
  end

  assign raster_patch_axis_ready = raster_patch_active_q &&
                                   engine_patch_axis_ready;

  alexnet_m16_raster_patch_service u_conv1_raster_patches (
      .clk(aclk), .rst,
      .frame_valid(raster_frame_valid), .frame_ready(raster_frame_ready),
      .frame_input_h(8'd224), .frame_input_w(8'd224),
      .frame_channel_count(4'd3), .frame_lane_mask(8'h07),
      .frame_kernel(4'd11), .frame_stride(3'd4), .frame_padding(3'd2),
      .frame_k_count(13'd363), .frame_tag(core_start_tag),
      .s_axis_tdata(s_axis_mm2s_tdata),
      .s_axis_tkeep(s_axis_mm2s_tkeep),
      .s_axis_tvalid(s_axis_mm2s_tvalid && raster_stream_active_q),
      .s_axis_tready(raster_axis_ready), .s_axis_tlast(s_axis_mm2s_tlast),
      .request_valid(engine_patch_request_valid &&
          engine_patch_request_layer_id == 1),
      .request_ready(raster_request_ready),
      .request_k_count(engine_patch_request_k_count),
      .request_m_lane_mask(engine_patch_request_m_lane_mask),
      .request_context_tag(engine_patch_request_context_tag),
      .patch_axis_valid(raster_patch_axis_valid),
      .patch_axis_ready(raster_patch_axis_ready),
      .patch_axis_data(raster_patch_axis_data),
      .patch_axis_last(raster_patch_axis_last),
      .raster_active, .frame_active(raster_frame_active),
      .frame_done(raster_frame_done),
      .completed_patch_fills(raster_completed_fills),
      .completed_patch_replays(raster_completed_replays),
      .overlap_active(raster_overlap_active), .fault(raster_fault),
      .idle(raster_idle)
  );

  alexnet_m8n126_activation_patch_service u_activation_patches (
      .clk(aclk), .rst,
      .request_valid(activation_request_valid),
      .request_ready(activation_request_ready),
      .request_layer_id(engine_patch_request_layer_id),
      .request_m_base(engine_patch_request_m_base),
      .request_k_offset(engine_patch_request_k_offset),
      .request_k_count(engine_patch_request_k_count),
      .request_m_lane_mask(engine_patch_request_m_lane_mask),
      .request_context_tag(engine_patch_request_context_tag),
      .activation_a_base(active_activation_a_base[31:0]),
      .activation_b_base(active_activation_b_base[31:0]),
      .dma_command_valid(activation_dma_cmd_valid),
      .dma_command_ready(activation_dma_cmd_ready),
      .dma_command_address(activation_dma_cmd_address),
      .dma_command_length(activation_dma_cmd_length),
      .dma_armed(main_mm2s_armed), .dma_done(main_mm2s_done),
      .dma_error(main_mm2s_error),
      .s_axis_tdata(s_axis_mm2s_tdata),
      .s_axis_tkeep(s_axis_mm2s_tkeep),
      .s_axis_tvalid(s_axis_mm2s_tvalid && activation_cache_load_active),
      .s_axis_tready(activation_mm2s_ready),
      .s_axis_tlast(s_axis_mm2s_tlast),
      .patch_axis_tdata(activation_patch_axis_data),
      .patch_axis_tvalid(activation_patch_axis_valid),
      .patch_axis_tready(engine_patch_axis_ready),
      .patch_axis_tlast(activation_patch_axis_last),
      .busy(activation_busy), .fault(activation_fault),
      .cache_load_active(activation_cache_load_active),
      .cached_layer_id(activation_cached_layer_id),
      .active_context_tag(unused_activation_context_tag),
      .active_m_count(unused_activation_m_count),
      .cache_loads(activation_cache_loads),
      .completed_patches(activation_completed_patches),
      .emitted_patch_words(activation_emitted_patch_words)
  );

  alexnet_m8n126_graph_payload_engine u_graph_payload (
      .clk(aclk), .rst,
      .start_valid(engine_start_valid),
      .start_ready(engine_start_ready), .start_tag(active_inference_tag_q),
      .weight_request_valid(engine_weight_request_valid),
      .weight_request_ready(engine_weight_request_ready),
      .weight_request_layer_id(engine_weight_request_layer_id),
      .weight_request_n_base(engine_weight_request_n_base),
      .weight_request_k_offset(engine_weight_request_k_offset),
      .weight_request_k_count(engine_weight_request_k_count),
      .weight_request_bank_enable(engine_weight_request_bank_enable),
      .weight_request_n_lane_mask(engine_weight_request_n_lane_mask),
      .weight_request_context_tag(engine_weight_request_context_tag),
      .weight_axis_valid(s_axis_weight_tvalid && weight_service_active_q),
      .weight_axis_ready(engine_weight_axis_ready),
      .weight_axis_data(s_axis_weight_tdata),
      .weight_axis_last(s_axis_weight_tlast),
      .patch_request_valid(engine_patch_request_valid),
      .patch_request_ready(engine_patch_request_ready),
      .patch_request_layer_id(engine_patch_request_layer_id),
      .patch_request_m_base(engine_patch_request_m_base),
      .patch_request_k_offset(engine_patch_request_k_offset),
      .patch_request_k_count(engine_patch_request_k_count),
      .patch_request_m_lane_mask(engine_patch_request_m_lane_mask),
      .patch_request_context_tag(engine_patch_request_context_tag),
      .patch_axis_valid(raster_patch_active_q ? raster_patch_axis_valid :
                                               activation_patch_axis_valid),
      .patch_axis_ready(engine_patch_axis_ready),
      .patch_axis_data(raster_patch_active_q ? raster_patch_axis_data :
                                               activation_patch_axis_data),
      .patch_axis_last(raster_patch_active_q ? raster_patch_axis_last :
                                               activation_patch_axis_last),
      .parameter_request_valid(engine_parameter_request_valid),
      .parameter_request_ready(engine_parameter_request_ready),
      .parameter_request_layer_id(engine_parameter_request_layer_id),
      .parameter_request_n_base(engine_parameter_request_n_base),
      .parameter_request_context_tag(engine_parameter_request_context_tag),
      .parameter_valid(engine_parameter_valid),
      .parameter_ready(engine_parameter_ready),
      .parameter_n_base(engine_parameter_n_base),
      .parameter_context_tag(engine_parameter_context_tag),
      .parameter_bias(engine_parameter_bias),
      .parameter_multiplier(engine_parameter_multiplier),
      .parameter_right_shift(engine_parameter_right_shift),
      .parameter_relu(engine_parameter_relu),
      .result_valid(engine_result_valid),
      .result_ready(engine_result_ready),
      .result_values(engine_result_values),
      .result_lane_mask(engine_result_lane_mask),
      .result_m_count(engine_result_m_count),
      .result_m_base(engine_result_m_base),
      .result_n_base(engine_result_n_base),
      .result_tile_tag(engine_result_tile_tag),
      .result_last_slice(engine_result_last_slice),
      .layer_complete_valid(engine_layer_complete_valid),
      .layer_complete_ready(engine_layer_complete_ready),
      .layer_complete_id(engine_layer_complete_id),
      .layer_complete_requires_pool(engine_layer_complete_requires_pool),
      .busy(engine_busy), .inference_done(engine_done),
      .inference_failed(engine_failed), .fault(engine_fault),
      .active_layer_id(engine_active_layer_id),
      .completed_commands(engine_completed_commands),
      .active_cycles(engine_active_cycles),
      .issue_cycles(engine_issue_cycles),
      .patch_stall_cycles(engine_patch_stall_cycles),
      .weight_stall_cycles(engine_weight_stall_cycles),
      .result_stall_cycles(engine_result_stall_cycles),
      .weight_words_loaded, .patch_words_loaded,
      .completed_result_slices, .useful_mac_count,
      .physical_mac_slot_count
  );

  alexnet_parameter_record_loader u_parameter_loader (
      .clk(aclk), .rst,
      .start_valid(loader_start_valid), .start_ready(loader_start_ready),
      .start_is_fc(engine_parameter_request_layer_id >= 6),
      .start_layer_id(engine_parameter_request_layer_id),
      .start_job_tag(engine_parameter_request_context_tag),
      .start_n_base(engine_parameter_request_n_base),
      .s_axis_tdata(s_axis_weight_tdata),
      .s_axis_tkeep(s_axis_weight_tkeep),
      .s_axis_tvalid(s_axis_weight_tvalid &&
          parameter_service_active_q),
      .s_axis_tready(loader_axis_ready), .s_axis_tlast(s_axis_weight_tlast),
      .parameter_valid(loader_parameter_valid),
      .parameter_ready(loader_parameter_ready),
      .parameter_is_fc(loader_parameter_is_fc),
      .parameter_layer_id(loader_parameter_layer_id),
      .parameter_job_tag(loader_parameter_tag),
      .parameter_n_base(loader_parameter_n_base),
      .parameter_bias(loader_parameter_bias),
      .parameter_multiplier(loader_parameter_multiplier),
      .parameter_right_shift(loader_parameter_right_shift),
      .busy(loader_busy), .fault(loader_fault),
      .active_lane(unused_loader_lane),
      .accepted_tiles(unused_loader_accepted),
      .completed_tiles(unused_loader_completed),
      .rejected_tiles(unused_loader_rejected)
  );

  alexnet_m8n126_inplace_pool_service u_inplace_pool_service (
      .clk(aclk), .rst,
      .layer_valid(pool_layer_valid), .layer_ready(pool_layer_ready),
      .layer_id(engine_layer_complete_id),
      .layer_job_tag(active_inference_tag_q),
      .layer_buffer_base(pool_layer_base),
      .dma_command_valid(pool_dma_cmd_valid),
      .dma_command_ready(pool_dma_cmd_ready),
      .dma_command_s2mm(pool_dma_cmd_s2mm),
      .dma_command_address(pool_dma_cmd_address),
      .dma_command_length(pool_dma_cmd_length),
      .dma_armed(pool_dma_active_s2mm_q ? main_s2mm_armed :
                                                 main_mm2s_armed),
      .dma_done(pool_dma_active_s2mm_q ? main_s2mm_done : main_mm2s_done),
      .dma_error(pool_dma_active_s2mm_q ? main_s2mm_error :
                                                 main_mm2s_error),
      .s_axis_tdata(s_axis_mm2s_tdata),
      .s_axis_tkeep(s_axis_mm2s_tkeep),
      .s_axis_tvalid(s_axis_mm2s_tvalid && pool_busy),
      .s_axis_tready(pool_mm2s_ready), .s_axis_tlast(s_axis_mm2s_tlast),
      .m_axis_tdata(pool_s2mm_data), .m_axis_tkeep(pool_s2mm_keep),
      .m_axis_tvalid(pool_s2mm_valid), .m_axis_tready(pool_s2mm_ready),
      .m_axis_tlast(pool_s2mm_last), .layer_done(pool_layer_done),
      .layer_error(pool_layer_error), .busy(pool_busy),
      .completed_tiles(pool_completed_tiles),
      .raw_words_read(pool_raw_words),
      .pooled_words_written(pool_stored_words)
  );

  alexnet_axi_dma_dual_channel_master #(
      .DMA_BASE_ADDR(32'ha001_0000),
      .MM2S_ALIGNMENT_BYTES(8), .S2MM_ALIGNMENT_BYTES(8)
  ) u_main_dma_control (
      .clk(aclk), .rst_n(aresetn),
      .mm2s_cmd_valid(main_mm2s_cmd_valid),
      .mm2s_cmd_ready(main_mm2s_cmd_ready),
      .mm2s_cmd_address(main_mm2s_cmd_address),
      .mm2s_cmd_length(main_mm2s_cmd_length),
      .mm2s_timeout_cycles(active_dma_timeout_cycles),
      .mm2s_armed(main_mm2s_armed), .mm2s_busy(main_mm2s_busy),
      .mm2s_done(main_mm2s_done), .mm2s_error(main_mm2s_error),
      .mm2s_error_code(main_mm2s_error_code),
      .mm2s_state(unused_main_mm2s_state),
      .s2mm_cmd_valid(main_s2mm_cmd_valid),
      .s2mm_cmd_ready(main_s2mm_cmd_ready),
      .s2mm_cmd_address(main_s2mm_cmd_address),
      .s2mm_cmd_length(main_s2mm_cmd_length),
      .s2mm_timeout_cycles(active_dma_timeout_cycles),
      .s2mm_armed(main_s2mm_armed), .s2mm_busy(main_s2mm_busy),
      .s2mm_done(main_s2mm_done), .s2mm_error(main_s2mm_error),
      .s2mm_error_code(main_s2mm_error_code),
      .s2mm_state(unused_main_s2mm_state),
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

  axi_dma_simple_master #(
      .DMA_BASE_ADDR(32'ha003_0000), .DMA_ALIGNMENT_BYTES(16)
  ) u_weight_dma_control (
      .clk(aclk), .rst_n(aresetn), .clear_error(1'b0),
      .cmd_valid(weight_dma_cmd_valid), .cmd_ready(weight_dma_cmd_ready),
      .cmd_s2mm(1'b0), .cmd_buffer_addr(weight_dma_cmd_address),
      .cmd_length_bytes(weight_dma_cmd_length),
      .cmd_timeout_cycles(active_dma_timeout_cycles),
      .armed(weight_dma_armed), .busy(weight_dma_busy),
      .done(weight_dma_done), .error(weight_dma_error),
      .error_code(weight_dma_error_code),
      .last_status(unused_weight_dma_status),
      .active_cycles(unused_weight_dma_cycles),
      .state_debug(unused_weight_dma_state),
      .m_axi_awaddr(m_axi_weight_dma_awaddr),
      .m_axi_awprot(m_axi_weight_dma_awprot),
      .m_axi_awvalid(m_axi_weight_dma_awvalid),
      .m_axi_awready(m_axi_weight_dma_awready),
      .m_axi_wdata(m_axi_weight_dma_wdata),
      .m_axi_wstrb(m_axi_weight_dma_wstrb),
      .m_axi_wvalid(m_axi_weight_dma_wvalid),
      .m_axi_wready(m_axi_weight_dma_wready),
      .m_axi_bresp(m_axi_weight_dma_bresp),
      .m_axi_bvalid(m_axi_weight_dma_bvalid),
      .m_axi_bready(m_axi_weight_dma_bready),
      .m_axi_araddr(m_axi_weight_dma_araddr),
      .m_axi_arprot(m_axi_weight_dma_arprot),
      .m_axi_arvalid(m_axi_weight_dma_arvalid),
      .m_axi_arready(m_axi_weight_dma_arready),
      .m_axi_rdata(m_axi_weight_dma_rdata),
      .m_axi_rresp(m_axi_weight_dma_rresp),
      .m_axi_rvalid(m_axi_weight_dma_rvalid),
      .m_axi_rready(m_axi_weight_dma_rready)
  );

  alexnet_axi_lite_regs #(
      .ADDR_W(CTRL_ADDR_W), .MODULE_ID(16'h4d38), .VERSION(8'h81),
      .BUILD_M(8'd8), .BUILD_N(8'd126), .BUILD_CLOCK_MHZ(16'd200)
  ) u_control_regs (
      .clk(aclk), .rst,
      .s_axi_awaddr(s_axi_ctrl_awaddr),
      .s_axi_awvalid(s_axi_ctrl_awvalid),
      .s_axi_awready(s_axi_ctrl_awready),
      .s_axi_wdata(s_axi_ctrl_wdata), .s_axi_wstrb(s_axi_ctrl_wstrb),
      .s_axi_wvalid(s_axi_ctrl_wvalid),
      .s_axi_wready(s_axi_ctrl_wready), .s_axi_bresp(s_axi_ctrl_bresp),
      .s_axi_bvalid(s_axi_ctrl_bvalid),
      .s_axi_bready(s_axi_ctrl_bready),
      .s_axi_araddr(s_axi_ctrl_araddr),
      .s_axi_arvalid(s_axi_ctrl_arvalid),
      .s_axi_arready(s_axi_ctrl_arready),
      .s_axi_rdata(s_axi_ctrl_rdata), .s_axi_rresp(s_axi_ctrl_rresp),
      .s_axi_rvalid(s_axi_ctrl_rvalid),
      .s_axi_rready(s_axi_ctrl_rready),
      .core_start_valid, .core_start_ready, .core_start_tag,
      .active_input_base, .active_activation_a_base,
      .active_activation_b_base, .active_weights_base,
      .active_parameters_base, .active_final_output_base,
      .active_dma_timeout_cycles,
      .core_busy(accelerator_busy), .inference_done(engine_done),
      .inference_failed(engine_failed), .core_fault(accelerator_fault),
      .fault_code(accelerator_fault ? 4'h8 : 4'h0),
      .fault_detail({main_dma_error_code, weight_dma_error_code}),
      .graph_phase({1'b0, main_state_q}),
      .active_layer_id(engine_active_layer_id),
      .active_inference_tag(active_inference_tag_q),
      .completed_conv_layers(engine_done ? 3'd5 :
          engine_active_layer_id <= 1 ? 3'd0 :
          engine_active_layer_id > 5 ? 3'd5 :
          engine_active_layer_id[2:0] - 1'b1),
      .completed_fc_layers(engine_done ? 2'd3 :
          engine_active_layer_id <= 6 ? 2'd0 :
          engine_active_layer_id >= 8 ? 2'd2 : 2'd1),
      .pool5_cache_valid(1'b0),
      .dma_busy(main_dma_busy || weight_dma_busy),
      .dma_error(main_dma_error || weight_dma_error),
      .dma_error_code(main_dma_error ? main_dma_error_code :
                      weight_dma_error_code),
      .dma_active_source(weight_service_active_q ? 3'd1 :
                         activation_busy ? 3'd2 :
                         main_state_q == MAIN_PARAMETER_STREAM ? 3'd3 :
                         main_state_q >= MAIN_RESULT_COMMAND ? 3'd4 : 3'd0),
      .dma_accepted_requests(weight_words_loaded + patch_words_loaded),
      .dma_issued_commands({16'd0, engine_completed_commands}),
      .dma_completed_transfers(completed_result_slices),
      .conv_storage_completed_tiles(completed_result_slices),
      .perf_active_cycles(engine_active_cycles),
      .perf_issue_cycles(engine_issue_cycles),
      .perf_weight_stall_cycles(engine_weight_stall_cycles),
      .perf_activation_stall_cycles(engine_patch_stall_cycles),
      .perf_result_stall_cycles(engine_result_stall_cycles),
      .perf_useful_mac_count(useful_mac_count),
      .perf_peak_mac_slot_count(physical_mac_slot_count),
      .perf_result_signature(result_signature_q),
      .perf_completed_tiles(engine_completed_commands),
      .irq,
      .start_pending(), .done_sticky(), .failed_sticky(),
      .fault_sticky(), .start_rejected_sticky()
  );

`ifndef SYNTHESIS
  always_ff @(posedge aclk) begin
    if (!rst) begin
      if (weight_command_fire && weight_request_bytes == 0)
        $fatal(1, "weight DMA accepted a zero-length graph request");
      if ((main_mm2s_command_fire && main_mm2s_cmd_length == 0) ||
          (main_s2mm_command_fire && main_s2mm_cmd_length == 0))
        $fatal(1, "main DMA accepted a zero-length graph request");
      if (engine_result_valid && engine_result_ready &&
          (engine_result_m_count != pending_result_m_count_q ||
           pending_result_bytes_q != engine_result_m_count * 8))
        $fatal(1, "result DMA length does not match graph result slice");
    end
  end
`endif

endmodule
