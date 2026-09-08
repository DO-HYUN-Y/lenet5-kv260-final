`timescale 1ns/1ps

// Serialize the graph's logical DDR requests through the fixed AlexNet
// address planner and present one physical simple-mode AXI DMA command.
// Payload routing and parameter-record unpacking are separate data-plane
// responsibilities; this block owns command address/length/order only.
module alexnet_graph_dma_descriptor_bridge (
    input logic clk,
    input logic rst,

    input logic [63:0] input_base,
    input logic [63:0] activation_a_base,
    input logic [63:0] activation_b_base,
    input logic [63:0] weights_base,
    input logic [63:0] parameters_base,
    input logic [63:0] final_output_base,
    input logic [31:0] dma_timeout_cycles,

    input  logic rs_mm2s_request_valid,
    output logic rs_mm2s_request_ready,
    input  logic [3:0] rs_active_layer_id,
    input  logic [1:0] rs_mm2s_request_destination,
    input  logic [10:0] rs_mm2s_request_word_count,
    input  logic [15:0] rs_mm2s_request_byte_count,
    input  logic [15:0] rs_mm2s_request_tag,
    input  logic [15:0] rs_mm2s_request_n_base,
    input  logic [7:0] rs_mm2s_request_chunk_index,

    input  logic rs_s2mm_request_valid,
    output logic rs_s2mm_request_ready,
    input  logic [12:0] rs_s2mm_request_word_count,
    input  logic [15:0] rs_s2mm_request_byte_count,
    input  logic [15:0] rs_s2mm_request_n_base,
    input  logic [15:0] rs_s2mm_request_tag,

    input  logic conv_parameter_request_valid,
    output logic conv_parameter_request_ready,
    input  logic [2:0] conv_parameter_request_layer_id,
    input  logic [15:0] conv_parameter_request_n_base,
    input  logic [15:0] conv_parameter_request_tag,

    input  logic fc_parameter_request_valid,
    output logic fc_parameter_request_ready,
    input  logic [3:0] fc_parameter_request_layer_id,
    input  logic [15:0] fc_parameter_request_n_base,
    input  logic [15:0] fc_parameter_request_tag,

    input  logic fc_external_request_valid,
    output logic fc_external_request_ready,
    input  logic [3:0] fc_external_request_layer_id,
    input  logic [15:0] fc_external_request_n_base,
    input  logic [13:0] fc_external_request_k_offset,
    input  logic [9:0] fc_external_request_k_count,
    input  logic [1:0] fc_external_request_destination,
    input  logic [9:0] fc_external_request_word_count,
    input  logic [15:0] fc_external_request_byte_count,
    input  logic [2:0] fc_external_request_m_count,
    input  logic [15:0] fc_external_request_tag,

    input  logic fc_result_request_valid,
    output logic fc_result_request_ready,
    input  logic [3:0] fc_result_request_layer_id,
    input  logic [15:0] fc_result_request_n_base,
    input  logic [2:0] fc_result_request_m_count,
    input  logic [1:0] fc_result_request_destination,
    input  logic [15:0] fc_result_request_byte_count,
    input  logic [15:0] fc_result_request_tag,

    output logic dma_cmd_valid,
    input  logic dma_cmd_ready,
    output logic dma_cmd_s2mm,
    output logic [31:0] dma_cmd_address,
    output logic [25:0] dma_cmd_length_bytes,
    output logic [31:0] dma_cmd_timeout_cycles,
    output logic [2:0] dma_cmd_source,
    output logic [3:0] dma_cmd_layer_id,
    output logic [2:0] dma_cmd_buffer_id,
    output logic [15:0] dma_cmd_n_base,
    output logic [15:0] dma_cmd_tag,

    input  logic dma_armed,
    input  logic dma_done,
    input  logic dma_error,
    output logic transfer_complete_valid,
    output logic transfer_complete_error,
    output logic [2:0] transfer_complete_source,
    output logic [3:0] transfer_complete_layer_id,
    output logic [15:0] transfer_complete_n_base,
    output logic [15:0] transfer_complete_tag,

    output logic busy,
    output logic fault,
    output logic request_rejected,
    output logic [31:0] accepted_requests,
    output logic [31:0] issued_commands,
    output logic [31:0] completed_transfers,
    output logic [31:0] rejected_requests
);
  localparam logic [2:0] KIND_ACTIVATION = 3'd0;
  localparam logic [2:0] KIND_WEIGHT = 3'd1;
  localparam logic [2:0] KIND_PARAMETER = 3'd2;
  localparam logic [2:0] KIND_RESULT = 3'd3;
  localparam logic [2:0] KIND_INVALID = 3'd7;

  localparam logic [2:0] SOURCE_RS_ACTIVATION = 3'd0;
  localparam logic [2:0] SOURCE_RS_WEIGHT = 3'd1;
  localparam logic [2:0] SOURCE_CONV_PARAMETER = 3'd2;
  localparam logic [2:0] SOURCE_FC_ACTIVATION = 3'd3;
  localparam logic [2:0] SOURCE_FC_WEIGHT = 3'd4;
  localparam logic [2:0] SOURCE_FC_PARAMETER = 3'd5;
  localparam logic [2:0] SOURCE_RS_RESULT = 3'd6;
  localparam logic [2:0] SOURCE_FC_RESULT = 3'd7;

  logic planner_request_valid, planner_request_ready;
  logic [2:0] planner_request_kind;
  logic [3:0] planner_request_layer_id;
  logic [15:0] planner_request_n_base;
  logic [7:0] planner_request_chunk_index;
  logic [13:0] planner_request_k_offset;
  logic [9:0] planner_request_k_count;
  logic [12:0] planner_request_word_count;
  logic [15:0] planner_request_byte_count;
  logic [2:0] planner_request_m_count;
  logic [15:0] planner_request_tag;

  // The arbiter terminates all graph request handshakes into this one-entry
  // register before driving the address planner. Besides keeping one physical
  // DMA transfer in flight, this register removes the six-way request mux and
  // top-level input delay from the planner's shift/add address path.
  logic request_buffer_valid_q;
  logic [2:0] request_buffer_kind_q;
  logic [3:0] request_buffer_layer_id_q;
  logic [15:0] request_buffer_n_base_q;
  logic [7:0] request_buffer_chunk_index_q;
  logic [13:0] request_buffer_k_offset_q;
  logic [9:0] request_buffer_k_count_q;
  logic [12:0] request_buffer_word_count_q;
  logic [15:0] request_buffer_byte_count_q;
  logic [2:0] request_buffer_m_count_q;
  logic [15:0] request_buffer_tag_q;
  logic [2:0] request_buffer_source_q;

  logic enqueue_valid;
  logic enqueue_ready;
  logic [2:0] enqueue_kind;
  logic [3:0] enqueue_layer_id;
  logic [15:0] enqueue_n_base;
  logic [7:0] enqueue_chunk_index;
  logic [13:0] enqueue_k_offset;
  logic [9:0] enqueue_k_count;
  logic [12:0] enqueue_word_count;
  logic [15:0] enqueue_byte_count;
  logic [2:0] enqueue_m_count;
  logic [15:0] enqueue_tag;
  logic [2:0] enqueue_source;

  logic planner_descriptor_valid, planner_descriptor_ready;
  logic planner_descriptor_error;
  logic [2:0] planner_descriptor_kind;
  logic [2:0] planner_descriptor_buffer_id;
  logic [3:0] planner_descriptor_layer_id;
  logic [63:0] planner_descriptor_address;
  logic [15:0] planner_descriptor_byte_count;
  logic [12:0] planner_descriptor_word_count;
  logic [15:0] planner_descriptor_tag;
  logic planner_busy, planner_fault;
  logic [31:0] planner_accepted, planner_rejected, planner_completed;

  logic [2:0] pending_source_q, active_source_q;
  logic [15:0] pending_n_base_q, active_n_base_q;
  logic [3:0] active_layer_q;
  logic [15:0] active_tag_q;
  logic transfer_active_q;
  logic fault_q;
  logic enqueue_fire, request_fire, descriptor_fire, command_fire;
  logic descriptor_usable;

  assign planner_request_valid = request_buffer_valid_q;
  assign planner_request_kind = request_buffer_kind_q;
  assign planner_request_layer_id = request_buffer_layer_id_q;
  assign planner_request_n_base = request_buffer_n_base_q;
  assign planner_request_chunk_index = request_buffer_chunk_index_q;
  assign planner_request_k_offset = request_buffer_k_offset_q;
  assign planner_request_k_count = request_buffer_k_count_q;
  assign planner_request_word_count = request_buffer_word_count_q;
  assign planner_request_byte_count = request_buffer_byte_count_q;
  assign planner_request_m_count = request_buffer_m_count_q;
  assign planner_request_tag = request_buffer_tag_q;
  assign enqueue_ready = !request_buffer_valid_q && !planner_busy &&
                         !transfer_active_q && !fault_q && !planner_fault &&
                         !dma_error;
  assign enqueue_fire = enqueue_valid && enqueue_ready;
  assign request_fire = planner_request_valid && planner_request_ready;
  assign descriptor_usable = !planner_descriptor_error &&
                             planner_descriptor_address[63:32] == 0;
  assign dma_cmd_valid = planner_descriptor_valid && descriptor_usable &&
                         !fault_q && !planner_fault && !dma_error;
  assign dma_cmd_s2mm = planner_descriptor_kind == KIND_RESULT;
  assign dma_cmd_address = planner_descriptor_address[31:0];
  assign dma_cmd_length_bytes = {10'b0, planner_descriptor_byte_count};
  assign dma_cmd_timeout_cycles = dma_timeout_cycles;
  assign dma_cmd_source = pending_source_q;
  assign dma_cmd_layer_id = planner_descriptor_layer_id;
  assign dma_cmd_buffer_id = planner_descriptor_buffer_id;
  assign dma_cmd_n_base = pending_n_base_q;
  assign dma_cmd_tag = planner_descriptor_tag;
  assign command_fire = dma_cmd_valid && dma_cmd_ready;
  assign planner_descriptor_ready = planner_descriptor_valid &&
      (!descriptor_usable || fault_q || planner_fault || dma_error ||
       dma_cmd_ready);
  assign descriptor_fire = planner_descriptor_valid &&
                           planner_descriptor_ready;

  assign busy = request_buffer_valid_q || planner_busy || transfer_active_q;
  assign fault = fault_q || planner_fault || dma_error;

  always_comb begin
    enqueue_valid = 1'b0;
    enqueue_kind = KIND_INVALID;
    enqueue_layer_id = 0;
    enqueue_n_base = 0;
    enqueue_chunk_index = 0;
    enqueue_k_offset = 0;
    enqueue_k_count = 0;
    enqueue_word_count = 0;
    enqueue_byte_count = 0;
    enqueue_m_count = 0;
    enqueue_tag = 0;
    enqueue_source = 0;
    rs_mm2s_request_ready = 1'b0;
    rs_s2mm_request_ready = 1'b0;
    conv_parameter_request_ready = 1'b0;
    fc_parameter_request_ready = 1'b0;
    fc_external_request_ready = 1'b0;
    fc_result_request_ready = 1'b0;

    if (enqueue_ready) begin
      if (conv_parameter_request_valid) begin
        enqueue_valid = 1'b1;
        enqueue_kind = KIND_PARAMETER;
        enqueue_layer_id = {1'b0, conv_parameter_request_layer_id};
        enqueue_n_base = conv_parameter_request_n_base;
        enqueue_word_count = 13'd16;
        enqueue_byte_count = 16'd128;
        enqueue_tag = conv_parameter_request_tag;
        enqueue_source = SOURCE_CONV_PARAMETER;
        conv_parameter_request_ready = 1'b1;
      end else if (fc_parameter_request_valid) begin
        enqueue_valid = 1'b1;
        enqueue_kind = KIND_PARAMETER;
        enqueue_layer_id = fc_parameter_request_layer_id;
        enqueue_n_base = fc_parameter_request_n_base;
        enqueue_word_count = 13'd16;
        enqueue_byte_count = 16'd128;
        enqueue_tag = fc_parameter_request_tag;
        enqueue_source = SOURCE_FC_PARAMETER;
        fc_parameter_request_ready = 1'b1;
      end else if (rs_s2mm_request_valid) begin
        enqueue_valid = 1'b1;
        enqueue_kind = KIND_RESULT;
        enqueue_layer_id = rs_active_layer_id;
        enqueue_n_base = rs_s2mm_request_n_base;
        enqueue_word_count = rs_s2mm_request_word_count;
        enqueue_byte_count = rs_s2mm_request_byte_count;
        enqueue_tag = rs_s2mm_request_tag;
        enqueue_source = SOURCE_RS_RESULT;
        rs_s2mm_request_ready = 1'b1;
      end else if (rs_mm2s_request_valid) begin
        enqueue_valid = 1'b1;
        enqueue_kind = rs_mm2s_request_destination == 2'd2 ?
                       KIND_WEIGHT : KIND_ACTIVATION;
        if (rs_mm2s_request_destination == 2'd3)
          enqueue_kind = KIND_INVALID;
        enqueue_layer_id = rs_active_layer_id;
        enqueue_n_base = rs_mm2s_request_n_base;
        enqueue_chunk_index = rs_mm2s_request_chunk_index;
        enqueue_word_count = {2'b0, rs_mm2s_request_word_count};
        enqueue_byte_count = rs_mm2s_request_byte_count;
        enqueue_tag = rs_mm2s_request_tag;
        enqueue_source = rs_mm2s_request_destination == 2'd2 ?
                         SOURCE_RS_WEIGHT : SOURCE_RS_ACTIVATION;
        rs_mm2s_request_ready = 1'b1;
      end else if (fc_result_request_valid) begin
        enqueue_valid = 1'b1;
        enqueue_kind = (fc_result_request_destination == 2'd0 ||
                        fc_result_request_destination == 2'd2) ?
                       KIND_RESULT : KIND_INVALID;
        enqueue_layer_id = fc_result_request_layer_id;
        enqueue_n_base = fc_result_request_n_base;
        enqueue_word_count = {10'b0, fc_result_request_m_count};
        enqueue_byte_count = fc_result_request_byte_count;
        enqueue_m_count = fc_result_request_m_count;
        enqueue_tag = fc_result_request_tag;
        enqueue_source = SOURCE_FC_RESULT;
        fc_result_request_ready = 1'b1;
      end else if (fc_external_request_valid) begin
        enqueue_valid = 1'b1;
        enqueue_kind = fc_external_request_destination == 2'd2 ?
                       KIND_WEIGHT : KIND_ACTIVATION;
        if (fc_external_request_destination != 2'd0 &&
            fc_external_request_destination != 2'd2)
          enqueue_kind = KIND_INVALID;
        enqueue_layer_id = fc_external_request_layer_id;
        enqueue_n_base = fc_external_request_n_base;
        enqueue_k_offset = fc_external_request_k_offset;
        enqueue_k_count = fc_external_request_k_count;
        enqueue_word_count = {3'b0, fc_external_request_word_count};
        enqueue_byte_count = fc_external_request_byte_count;
        enqueue_m_count = fc_external_request_m_count;
        enqueue_tag = fc_external_request_tag;
        enqueue_source = fc_external_request_destination == 2'd2 ?
                         SOURCE_FC_WEIGHT : SOURCE_FC_ACTIVATION;
        fc_external_request_ready = 1'b1;
      end
    end
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      request_buffer_valid_q <= 1'b0;
      request_buffer_kind_q <= KIND_INVALID;
      request_buffer_layer_id_q <= 0;
      request_buffer_n_base_q <= 0;
      request_buffer_chunk_index_q <= 0;
      request_buffer_k_offset_q <= 0;
      request_buffer_k_count_q <= 0;
      request_buffer_word_count_q <= 0;
      request_buffer_byte_count_q <= 0;
      request_buffer_m_count_q <= 0;
      request_buffer_tag_q <= 0;
      request_buffer_source_q <= 0;
      pending_source_q <= 0;
      pending_n_base_q <= 0;
      active_source_q <= 0;
      active_n_base_q <= 0;
      active_layer_q <= 0;
      active_tag_q <= 0;
      transfer_active_q <= 1'b0;
      fault_q <= 1'b0;
      transfer_complete_valid <= 1'b0;
      transfer_complete_error <= 1'b0;
      transfer_complete_source <= 0;
      transfer_complete_layer_id <= 0;
      transfer_complete_n_base <= 0;
      transfer_complete_tag <= 0;
      request_rejected <= 1'b0;
      accepted_requests <= 0;
      issued_commands <= 0;
      completed_transfers <= 0;
      rejected_requests <= 0;
    end else begin
      transfer_complete_valid <= 1'b0;
      transfer_complete_error <= 1'b0;
      request_rejected <= 1'b0;
      fault_q <= fault_q || planner_fault || dma_error;

      if (request_fire)
        request_buffer_valid_q <= 1'b0;

      if (enqueue_fire) begin
        request_buffer_valid_q <= 1'b1;
        request_buffer_kind_q <= enqueue_kind;
        request_buffer_layer_id_q <= enqueue_layer_id;
        request_buffer_n_base_q <= enqueue_n_base;
        request_buffer_chunk_index_q <= enqueue_chunk_index;
        request_buffer_k_offset_q <= enqueue_k_offset;
        request_buffer_k_count_q <= enqueue_k_count;
        request_buffer_word_count_q <= enqueue_word_count;
        request_buffer_byte_count_q <= enqueue_byte_count;
        request_buffer_m_count_q <= enqueue_m_count;
        request_buffer_tag_q <= enqueue_tag;
        request_buffer_source_q <= enqueue_source;
        accepted_requests <= accepted_requests + 1'b1;
      end

      if (request_fire) begin
        pending_source_q <= request_buffer_source_q;
        pending_n_base_q <= planner_request_n_base;
      end

      if (descriptor_fire && !descriptor_usable) begin
        fault_q <= 1'b1;
        request_rejected <= 1'b1;
        rejected_requests <= rejected_requests + 1'b1;
      end

      if (command_fire) begin
        transfer_active_q <= 1'b1;
        active_source_q <= pending_source_q;
        active_n_base_q <= pending_n_base_q;
        active_layer_q <= planner_descriptor_layer_id;
        active_tag_q <= planner_descriptor_tag;
        issued_commands <= issued_commands + 1'b1;
      end

      if (dma_done && transfer_active_q) begin
        transfer_active_q <= 1'b0;
        transfer_complete_valid <= 1'b1;
        transfer_complete_error <= 1'b0;
        transfer_complete_source <= active_source_q;
        transfer_complete_layer_id <= active_layer_q;
        transfer_complete_n_base <= active_n_base_q;
        transfer_complete_tag <= active_tag_q;
        completed_transfers <= completed_transfers + 1'b1;
      end else if (dma_error && transfer_active_q) begin
        transfer_active_q <= 1'b0;
        transfer_complete_valid <= 1'b1;
        transfer_complete_error <= 1'b1;
        transfer_complete_source <= active_source_q;
        transfer_complete_layer_id <= active_layer_q;
        transfer_complete_n_base <= active_n_base_q;
        transfer_complete_tag <= active_tag_q;
      end
    end
  end

  alexnet_ddr_address_planner u_planner (
      .clk(clk), .rst(rst),
      .input_base(input_base),
      .activation_a_base(activation_a_base),
      .activation_b_base(activation_b_base),
      .weights_base(weights_base),
      .parameters_base(parameters_base),
      .final_output_base(final_output_base),
      .request_valid(planner_request_valid),
      .request_ready(planner_request_ready),
      .request_kind(planner_request_kind),
      .request_layer_id(planner_request_layer_id),
      .request_n_base(planner_request_n_base),
      .request_chunk_index(planner_request_chunk_index),
      .request_k_offset(planner_request_k_offset),
      .request_k_count(planner_request_k_count),
      .request_word_count(planner_request_word_count),
      .request_byte_count(planner_request_byte_count),
      .request_m_count(planner_request_m_count),
      .request_tag(planner_request_tag),
      .descriptor_valid(planner_descriptor_valid),
      .descriptor_ready(planner_descriptor_ready),
      .descriptor_error(planner_descriptor_error),
      .descriptor_kind(planner_descriptor_kind),
      .descriptor_buffer_id(planner_descriptor_buffer_id),
      .descriptor_layer_id(planner_descriptor_layer_id),
      .descriptor_address(planner_descriptor_address),
      .descriptor_byte_count(planner_descriptor_byte_count),
      .descriptor_word_count(planner_descriptor_word_count),
      .descriptor_tag(planner_descriptor_tag),
      .busy(planner_busy), .fault(planner_fault),
      .accepted_requests(planner_accepted),
      .rejected_requests(planner_rejected),
      .completed_descriptors(planner_completed)
  );

`ifndef SYNTHESIS
  always_ff @(posedge clk) begin
    if (!rst) begin
      if (dma_cmd_valid && dma_cmd_address[2:0] != 0)
        $fatal(1, "DMA bridge emitted a non-8-byte-aligned address");
      if (dma_done && !transfer_active_q)
        $fatal(1, "DMA bridge received completion without an active command");
      if (dma_armed && !transfer_active_q)
        $fatal(1, "DMA bridge observed armed without an active command");
    end
  end
`endif
endmodule
