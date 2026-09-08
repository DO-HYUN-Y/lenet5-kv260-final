`timescale 1ns/1ps

// Registered one-command sequencer for the measured full DMA/compute loop.
//
// Software supplies one activation/weight/chunk/result command. The scheduler
// presents every downstream request until its ready/valid handshake and only
// advances on the corresponding completion event. A final chunk is not
// launched until the result S2MM descriptor has become active. Any downstream
// rejection or composite protocol error enters a stable fault state; owned
// transfers are allowed to drain before clear_error is presented to the DMA
// adapters.
module alexnet_dma_chunk_scheduler #(
    parameter int COUNT_W = 11,
    parameter int RESULT_COUNT_W = COUNT_W,
    parameter int BYTE_COUNT_W = 16,
    parameter int DIM_W = 8,
    parameter int K_COUNT_W = 10,
    parameter int TILE_TAG_W = 16,
    parameter int TENSOR_TAG_W = 16,
    parameter int WEIGHT_CONTEXT_TAG_W = 16,
    parameter int ACCUM_CONTEXT_TAG_W = 16,
    parameter int CHUNK_INDEX_W = 8,
    parameter int N_BASE_W = 16,
    parameter int COMMAND_ID_W = 16
) (
    input logic clk,
    input logic rst,

    input  logic command_valid,
    output logic command_ready,
    input  logic [COMMAND_ID_W-1:0] command_id,
    input  logic command_activation_streaming,
    input  logic [1:0] command_activation_destination,
    input  logic [COUNT_W-1:0] command_activation_word_count,
    input  logic [BYTE_COUNT_W-1:0] command_activation_byte_count,
    input  logic [7:0] command_activation_lane_mask,
    input  logic [TENSOR_TAG_W-1:0] command_activation_tensor_tag,
    input  logic [COUNT_W-1:0] command_weight_word_count,
    input  logic [BYTE_COUNT_W-1:0] command_weight_byte_count,
    input  logic [7:0] command_weight_lane_mask,
    input  logic [WEIGHT_CONTEXT_TAG_W-1:0]
        command_weight_context_tag,
    input  logic command_result_enable,
    input  logic [RESULT_COUNT_W-1:0] command_result_word_count,
    input  logic [BYTE_COUNT_W-1:0] command_result_byte_count,
    input  logic [1:0] command_result_destination,
    input  logic [2:0] command_result_slice,
    input  logic [N_BASE_W-1:0] command_result_n_base,
    input  logic [7:0] command_result_lane_mask,
    input  logic [TILE_TAG_W-1:0] command_result_first_tile_tag,
    input  logic [DIM_W-1:0] command_chunk_input_h,
    input  logic [DIM_W-1:0] command_chunk_input_w,
    input  logic [3:0] command_chunk_channel_count,
    input  logic [7:0] command_chunk_input_lane_mask,
    input  logic [3:0] command_chunk_kernel,
    input  logic [2:0] command_chunk_stride,
    input  logic [2:0] command_chunk_padding,
    input  logic [K_COUNT_W-1:0] command_chunk_k_count,
    input  logic [WEIGHT_CONTEXT_TAG_W-1:0]
        command_chunk_weight_context_tag,
    input  logic [RESULT_COUNT_W-1:0] command_chunk_word_count,
    input  logic [DIM_W-1:0] command_chunk_output_width,
    input  logic [ACCUM_CONTEXT_TAG_W-1:0]
        command_chunk_accum_context_tag,
    input  logic [TILE_TAG_W-1:0] command_chunk_tile_tag_base,
    input  logic [CHUNK_INDEX_W-1:0] command_chunk_index,
    input  logic command_chunk_first,
    input  logic command_chunk_final,

    input logic datapath_configured,
    input logic command_boundary_idle,
    input logic pipeline_idle,
    input logic protocol_error,
    input logic dma_busy,
    input logic dma_transfer_done,
    input logic dma_descriptor_rejected,
    input logic result_dma_busy,
    input logic result_dma_transfer_active,
    input logic result_dma_transfer_done,
    input logic result_dma_descriptor_rejected,
    input logic weight_resident_valid,
    input logic chunk_done,
    input logic chunk_rejected,

    output logic dma_clear_error,
    output logic dma_descriptor_valid,
    input  logic dma_descriptor_ready,
    output logic [1:0] dma_descriptor_destination,
    output logic [COUNT_W-1:0] dma_descriptor_word_count,
    output logic [BYTE_COUNT_W-1:0] dma_descriptor_byte_count,
    output logic [7:0] dma_descriptor_lane_mask,
    output logic [TENSOR_TAG_W-1:0] dma_descriptor_tag,

    output logic result_dma_clear_error,
    output logic result_dma_descriptor_valid,
    input  logic result_dma_descriptor_ready,
    output logic [RESULT_COUNT_W-1:0] result_dma_descriptor_word_count,
    output logic [BYTE_COUNT_W-1:0]
        result_dma_descriptor_byte_count,
    output logic [1:0] result_dma_descriptor_destination,
    output logic [2:0] result_dma_descriptor_slice,
    output logic [N_BASE_W-1:0] result_dma_descriptor_n_base,
    output logic [7:0] result_dma_descriptor_lane_mask,
    output logic [TILE_TAG_W-1:0]
        result_dma_descriptor_first_tile_tag,

    output logic weight_release_valid,
    input  logic weight_release_ready,

    output logic chunk_valid,
    input  logic chunk_ready,
    output logic chunk_activation_streaming,
    output logic [TENSOR_TAG_W-1:0] chunk_activation_tensor_tag,
    output logic [DIM_W-1:0] chunk_input_h,
    output logic [DIM_W-1:0] chunk_input_w,
    output logic [3:0] chunk_channel_count,
    output logic [7:0] chunk_input_lane_mask,
    output logic [3:0] chunk_kernel,
    output logic [2:0] chunk_stride,
    output logic [2:0] chunk_padding,
    output logic [K_COUNT_W-1:0] chunk_k_count,
    output logic [WEIGHT_CONTEXT_TAG_W-1:0] chunk_weight_context_tag,
    output logic [RESULT_COUNT_W-1:0] chunk_word_count,
    output logic [DIM_W-1:0] chunk_output_width,
    output logic [ACCUM_CONTEXT_TAG_W-1:0] chunk_accum_context_tag,
    output logic [TILE_TAG_W-1:0] chunk_tile_tag_base,
    output logic [CHUNK_INDEX_W-1:0] chunk_index,
    output logic chunk_first,
    output logic chunk_final,

    input  logic clear_fault,
    output logic scheduler_busy,
    output logic scheduler_fault,
    output logic [3:0] fault_code,
    output logic [4:0] phase,
    output logic command_done,
    output logic command_rejected,
    output logic fault_cleared,
    output logic command_error,
    output logic [COMMAND_ID_W-1:0] active_command_id,
    output logic [COMMAND_ID_W-1:0] completed_command_id,
    output logic [15:0] accepted_commands,
    output logic [15:0] completed_commands,
    output logic [15:0] rejected_commands
);

  localparam logic [1:0] DEST_WEIGHT = 2'd2;

  localparam logic [3:0] FAULT_NONE = 4'd0;
  localparam logic [3:0] FAULT_PROTOCOL = 4'd1;
  localparam logic [3:0] FAULT_INPUT_DESCRIPTOR = 4'd2;
  localparam logic [3:0] FAULT_RESULT_DESCRIPTOR = 4'd3;
  localparam logic [3:0] FAULT_CHUNK = 4'd4;
  localparam logic [3:0] FAULT_COMMAND = 4'd5;

  typedef enum logic [4:0] {
    ST_IDLE = 5'd0,
    ST_VALIDATE = 5'd1,
    ST_ACTIVATION_DESCRIPTOR = 5'd2,
    ST_WAIT_ACTIVATION = 5'd3,
    ST_PRE_WEIGHT_RELEASE = 5'd4,
    ST_WEIGHT_DESCRIPTOR = 5'd5,
    ST_WAIT_WEIGHT = 5'd6,
    ST_RESULT_DESCRIPTOR = 5'd7,
    ST_WAIT_RESULT_ARMED = 5'd8,
    ST_CHUNK = 5'd9,
    ST_WAIT_CHUNK = 5'd10,
    ST_POST_WEIGHT_RELEASE = 5'd11,
    ST_WAIT_RESULT = 5'd12,
    ST_COMPLETE = 5'd13,
    ST_FAULT = 5'd14,
    ST_CLEAR_ERRORS = 5'd15,
    ST_WAIT_CLEAR = 5'd16,
    ST_WAIT_COMMAND_IDLE = 5'd17
  } state_t;

  state_t state_q;

  logic [COMMAND_ID_W-1:0] command_id_q;
  logic activation_streaming_q;
  logic [1:0] activation_destination_q;
  logic [COUNT_W-1:0] activation_word_count_q;
  logic [BYTE_COUNT_W-1:0] activation_byte_count_q;
  logic [7:0] activation_lane_mask_q;
  logic [TENSOR_TAG_W-1:0] activation_tensor_tag_q;
  logic [COUNT_W-1:0] weight_word_count_q;
  logic [BYTE_COUNT_W-1:0] weight_byte_count_q;
  logic [7:0] weight_lane_mask_q;
  logic [WEIGHT_CONTEXT_TAG_W-1:0] weight_context_tag_q;
  logic result_enable_q;
  logic [RESULT_COUNT_W-1:0] result_word_count_q;
  logic [BYTE_COUNT_W-1:0] result_byte_count_q;
  logic [1:0] result_destination_q;
  logic [2:0] result_slice_q;
  logic [N_BASE_W-1:0] result_n_base_q;
  logic [7:0] result_lane_mask_q;
  logic [TILE_TAG_W-1:0] result_first_tile_tag_q;
  logic [DIM_W-1:0] chunk_input_h_q;
  logic [DIM_W-1:0] chunk_input_w_q;
  logic [3:0] chunk_channel_count_q;
  logic [7:0] chunk_input_lane_mask_q;
  logic [3:0] chunk_kernel_q;
  logic [2:0] chunk_stride_q;
  logic [2:0] chunk_padding_q;
  logic [K_COUNT_W-1:0] chunk_k_count_q;
  logic [WEIGHT_CONTEXT_TAG_W-1:0] chunk_weight_context_tag_q;
  logic [RESULT_COUNT_W-1:0] chunk_word_count_q;
  logic [DIM_W-1:0] chunk_output_width_q;
  logic [ACCUM_CONTEXT_TAG_W-1:0] chunk_accum_context_tag_q;
  logic [TILE_TAG_W-1:0] chunk_tile_tag_base_q;
  logic [CHUNK_INDEX_W-1:0] chunk_index_q;
  logic chunk_first_q;
  logic chunk_final_q;

  logic scheduler_fault_q;
  logic [3:0] fault_code_q;
  logic recovery_requested_q;
  logic result_done_seen_q;
  logic command_relationship_valid;
  logic command_fire;
  logic dma_descriptor_fire;
  logic result_descriptor_fire;
  logic weight_release_fire;
  logic chunk_fire;
  logic downstream_fault_event;

  assign command_ready = state_q == ST_IDLE && datapath_configured &&
                         command_boundary_idle && !dma_busy &&
                         !result_dma_busy && !protocol_error;
  assign command_fire = command_valid && command_ready;
  assign scheduler_busy = state_q != ST_IDLE;
  assign scheduler_fault = scheduler_fault_q;
  assign fault_code = fault_code_q;
  assign phase = state_q;
  assign active_command_id = command_id_q;

  assign command_relationship_valid =
      (activation_streaming_q ?
           (activation_word_count_q == 0 && activation_byte_count_q == 0) :
           (activation_destination_q <= 2'd1)) &&
      result_enable_q == chunk_final_q &&
      activation_tensor_tag_q == chunk_activation_tensor_tag &&
      activation_lane_mask_q == chunk_input_lane_mask_q &&
      weight_word_count_q == COUNT_W'(chunk_k_count_q) &&
      weight_context_tag_q == chunk_weight_context_tag_q &&
      (!result_enable_q ||
       (result_word_count_q == chunk_word_count_q &&
        result_first_tile_tag_q == chunk_tile_tag_base_q &&
        result_lane_mask_q == weight_lane_mask_q));

  assign dma_clear_error = state_q == ST_CLEAR_ERRORS;
  assign result_dma_clear_error = state_q == ST_CLEAR_ERRORS;

  assign dma_descriptor_valid =
      state_q == ST_ACTIVATION_DESCRIPTOR ||
      state_q == ST_WEIGHT_DESCRIPTOR;
  assign dma_descriptor_destination =
      state_q == ST_WEIGHT_DESCRIPTOR ? DEST_WEIGHT :
                                        activation_destination_q;
  assign dma_descriptor_word_count =
      state_q == ST_WEIGHT_DESCRIPTOR ? weight_word_count_q :
                                        activation_word_count_q;
  assign dma_descriptor_byte_count =
      state_q == ST_WEIGHT_DESCRIPTOR ? weight_byte_count_q :
                                        activation_byte_count_q;
  assign dma_descriptor_lane_mask =
      state_q == ST_WEIGHT_DESCRIPTOR ? weight_lane_mask_q :
                                        activation_lane_mask_q;
  assign dma_descriptor_tag =
      state_q == ST_WEIGHT_DESCRIPTOR ?
          TENSOR_TAG_W'(weight_context_tag_q) : activation_tensor_tag_q;
  assign dma_descriptor_fire = dma_descriptor_valid &&
                               dma_descriptor_ready;

  assign result_dma_descriptor_valid = state_q == ST_RESULT_DESCRIPTOR;
  assign result_dma_descriptor_word_count = result_word_count_q;
  assign result_dma_descriptor_byte_count = result_byte_count_q;
  assign result_dma_descriptor_destination = result_destination_q;
  assign result_dma_descriptor_slice = result_slice_q;
  assign result_dma_descriptor_n_base = result_n_base_q;
  assign result_dma_descriptor_lane_mask = result_lane_mask_q;
  assign result_dma_descriptor_first_tile_tag = result_first_tile_tag_q;
  assign result_descriptor_fire = result_dma_descriptor_valid &&
                                  result_dma_descriptor_ready;

  assign weight_release_valid =
      state_q == ST_PRE_WEIGHT_RELEASE ||
      state_q == ST_POST_WEIGHT_RELEASE;
  assign weight_release_fire = weight_release_valid && weight_release_ready;

  assign chunk_valid = state_q == ST_CHUNK;
  assign chunk_activation_streaming = activation_streaming_q;
  assign chunk_activation_tensor_tag = activation_tensor_tag_q;
  assign chunk_input_h = chunk_input_h_q;
  assign chunk_input_w = chunk_input_w_q;
  assign chunk_channel_count = chunk_channel_count_q;
  assign chunk_input_lane_mask = chunk_input_lane_mask_q;
  assign chunk_kernel = chunk_kernel_q;
  assign chunk_stride = chunk_stride_q;
  assign chunk_padding = chunk_padding_q;
  assign chunk_k_count = chunk_k_count_q;
  assign chunk_weight_context_tag = chunk_weight_context_tag_q;
  assign chunk_word_count = chunk_word_count_q;
  assign chunk_output_width = chunk_output_width_q;
  assign chunk_accum_context_tag = chunk_accum_context_tag_q;
  assign chunk_tile_tag_base = chunk_tile_tag_base_q;
  assign chunk_index = chunk_index_q;
  assign chunk_first = chunk_first_q;
  assign chunk_final = chunk_final_q;
  assign chunk_fire = chunk_valid && chunk_ready;

  assign downstream_fault_event = dma_descriptor_rejected ||
                                  result_dma_descriptor_rejected ||
                                  chunk_rejected || protocol_error;

  always_ff @(posedge clk) begin
    if (rst) begin
      state_q <= ST_IDLE;
      command_id_q <= '0;
      activation_streaming_q <= 1'b0;
      activation_destination_q <= '0;
      activation_word_count_q <= '0;
      activation_byte_count_q <= '0;
      activation_lane_mask_q <= '0;
      activation_tensor_tag_q <= '0;
      weight_word_count_q <= '0;
      weight_byte_count_q <= '0;
      weight_lane_mask_q <= '0;
      weight_context_tag_q <= '0;
      result_enable_q <= 1'b0;
      result_word_count_q <= '0;
      result_byte_count_q <= '0;
      result_destination_q <= '0;
      result_slice_q <= '0;
      result_n_base_q <= '0;
      result_lane_mask_q <= '0;
      result_first_tile_tag_q <= '0;
      chunk_input_h_q <= '0;
      chunk_input_w_q <= '0;
      chunk_channel_count_q <= '0;
      chunk_input_lane_mask_q <= '0;
      chunk_kernel_q <= '0;
      chunk_stride_q <= '0;
      chunk_padding_q <= '0;
      chunk_k_count_q <= '0;
      chunk_weight_context_tag_q <= '0;
      chunk_word_count_q <= '0;
      chunk_output_width_q <= '0;
      chunk_accum_context_tag_q <= '0;
      chunk_tile_tag_base_q <= '0;
      chunk_index_q <= '0;
      chunk_first_q <= 1'b0;
      chunk_final_q <= 1'b0;
      scheduler_fault_q <= 1'b0;
      fault_code_q <= FAULT_NONE;
      recovery_requested_q <= 1'b0;
      result_done_seen_q <= 1'b0;
      command_done <= 1'b0;
      command_rejected <= 1'b0;
      fault_cleared <= 1'b0;
      command_error <= 1'b0;
      completed_command_id <= '0;
      accepted_commands <= '0;
      completed_commands <= '0;
      rejected_commands <= '0;
    end else begin
      command_done <= 1'b0;
      command_rejected <= 1'b0;
      fault_cleared <= 1'b0;

      if (result_dma_transfer_done &&
          (state_q == ST_WAIT_CHUNK ||
           state_q == ST_POST_WEIGHT_RELEASE ||
           state_q == ST_WAIT_RESULT))
        result_done_seen_q <= 1'b1;

      case (state_q)
        ST_IDLE: begin
          recovery_requested_q <= 1'b0;
          result_done_seen_q <= 1'b0;
          if (command_fire) begin
            command_id_q <= command_id;
            activation_streaming_q <= command_activation_streaming === 1'b1;
            activation_destination_q <= command_activation_destination;
            activation_word_count_q <= command_activation_word_count;
            activation_byte_count_q <= command_activation_byte_count;
            activation_lane_mask_q <= command_activation_lane_mask;
            activation_tensor_tag_q <= command_activation_tensor_tag;
            weight_word_count_q <= command_weight_word_count;
            weight_byte_count_q <= command_weight_byte_count;
            weight_lane_mask_q <= command_weight_lane_mask;
            weight_context_tag_q <= command_weight_context_tag;
            result_enable_q <= command_result_enable;
            result_word_count_q <= command_result_word_count;
            result_byte_count_q <= command_result_byte_count;
            result_destination_q <= command_result_destination;
            result_slice_q <= command_result_slice;
            result_n_base_q <= command_result_n_base;
            result_lane_mask_q <= command_result_lane_mask;
            result_first_tile_tag_q <=
                command_result_first_tile_tag;
            chunk_input_h_q <= command_chunk_input_h;
            chunk_input_w_q <= command_chunk_input_w;
            chunk_channel_count_q <= command_chunk_channel_count;
            chunk_input_lane_mask_q <= command_chunk_input_lane_mask;
            chunk_kernel_q <= command_chunk_kernel;
            chunk_stride_q <= command_chunk_stride;
            chunk_padding_q <= command_chunk_padding;
            chunk_k_count_q <= command_chunk_k_count;
            chunk_weight_context_tag_q <=
                command_chunk_weight_context_tag;
            chunk_word_count_q <= command_chunk_word_count;
            chunk_output_width_q <= command_chunk_output_width;
            chunk_accum_context_tag_q <=
                command_chunk_accum_context_tag;
            chunk_tile_tag_base_q <= command_chunk_tile_tag_base;
            chunk_index_q <= command_chunk_index;
            chunk_first_q <= command_chunk_first;
            chunk_final_q <= command_chunk_final;
            accepted_commands <= accepted_commands + 1'b1;
            state_q <= ST_VALIDATE;
          end
        end

        ST_VALIDATE: begin
          if (command_relationship_valid) begin
            if (activation_streaming_q) begin
              if (weight_resident_valid)
                state_q <= ST_PRE_WEIGHT_RELEASE;
              else
                state_q <= ST_WEIGHT_DESCRIPTOR;
            end else begin
              state_q <= ST_ACTIVATION_DESCRIPTOR;
            end
          end
          else begin
            scheduler_fault_q <= 1'b1;
            fault_code_q <= FAULT_COMMAND;
            command_error <= 1'b1;
            command_rejected <= 1'b1;
            rejected_commands <= rejected_commands + 1'b1;
            state_q <= ST_FAULT;
          end
        end

        ST_ACTIVATION_DESCRIPTOR: begin
          if (dma_descriptor_fire)
            state_q <= ST_WAIT_ACTIVATION;
        end

        ST_WAIT_ACTIVATION: begin
          if (dma_transfer_done) begin
            if (weight_resident_valid)
              state_q <= ST_PRE_WEIGHT_RELEASE;
            else
              state_q <= ST_WEIGHT_DESCRIPTOR;
          end
        end

        ST_PRE_WEIGHT_RELEASE: begin
          if (weight_release_fire)
            state_q <= ST_WEIGHT_DESCRIPTOR;
        end

        ST_WEIGHT_DESCRIPTOR: begin
          if (dma_descriptor_fire)
            state_q <= ST_WAIT_WEIGHT;
        end

        ST_WAIT_WEIGHT: begin
          if (dma_transfer_done) begin
            if (result_enable_q)
              state_q <= ST_RESULT_DESCRIPTOR;
            else
              state_q <= ST_CHUNK;
          end
        end

        ST_RESULT_DESCRIPTOR: begin
          if (result_descriptor_fire)
            state_q <= ST_WAIT_RESULT_ARMED;
        end

        ST_WAIT_RESULT_ARMED: begin
          if (result_dma_transfer_active) begin
            state_q <= ST_CHUNK;
          end
        end

        ST_CHUNK: begin
          if (chunk_fire)
            state_q <= ST_WAIT_CHUNK;
        end

        ST_WAIT_CHUNK: begin
          if (chunk_done)
            state_q <= ST_POST_WEIGHT_RELEASE;
        end

        ST_POST_WEIGHT_RELEASE: begin
          if (weight_release_fire) begin
            if (!result_enable_q)
              state_q <= ST_COMPLETE;
            else if (result_done_seen_q || result_dma_transfer_done)
              state_q <= ST_WAIT_COMMAND_IDLE;
            else
              state_q <= ST_WAIT_RESULT;
          end
        end

        ST_WAIT_RESULT: begin
          if (result_done_seen_q || result_dma_transfer_done)
            state_q <= ST_WAIT_COMMAND_IDLE;
        end

        ST_WAIT_COMMAND_IDLE: begin
          if (pipeline_idle && !dma_busy && !result_dma_busy)
            state_q <= ST_COMPLETE;
        end

        ST_COMPLETE: begin
          command_done <= 1'b1;
          completed_command_id <= command_id_q;
          completed_commands <= completed_commands + 1'b1;
          state_q <= ST_IDLE;
        end

        ST_FAULT: begin
          if (clear_fault)
            recovery_requested_q <= 1'b1;
          if ((clear_fault || recovery_requested_q) &&
              command_boundary_idle && !dma_busy && !result_dma_busy) begin
            recovery_requested_q <= 1'b0;
            state_q <= ST_CLEAR_ERRORS;
          end
        end

        ST_CLEAR_ERRORS: state_q <= ST_WAIT_CLEAR;

        ST_WAIT_CLEAR: begin
          if (!protocol_error) begin
            scheduler_fault_q <= 1'b0;
            fault_code_q <= FAULT_NONE;
            command_error <= 1'b0;
            fault_cleared <= 1'b1;
            state_q <= ST_IDLE;
          end
        end

        default: begin
          scheduler_fault_q <= 1'b1;
          fault_code_q <= FAULT_PROTOCOL;
          state_q <= ST_FAULT;
        end
      endcase

      // Rejection pulses identify the most useful software-visible cause.
      // They take priority over the composite protocol level from the same
      // downstream adapter.
      if (state_q != ST_FAULT && state_q != ST_CLEAR_ERRORS &&
          state_q != ST_WAIT_CLEAR && downstream_fault_event) begin
        scheduler_fault_q <= 1'b1;
        recovery_requested_q <= 1'b0;
        command_rejected <= 1'b1;
        if (state_q != ST_IDLE)
          rejected_commands <= rejected_commands + 1'b1;
        if (dma_descriptor_rejected)
          fault_code_q <= FAULT_INPUT_DESCRIPTOR;
        else if (result_dma_descriptor_rejected)
          fault_code_q <= FAULT_RESULT_DESCRIPTOR;
        else if (chunk_rejected)
          fault_code_q <= FAULT_CHUNK;
        else
          fault_code_q <= FAULT_PROTOCOL;
        state_q <= ST_FAULT;
      end
    end
  end

`ifndef SYNTHESIS
  always_ff @(posedge clk) begin
    if (!rst) begin
      if (command_fire && !datapath_configured)
        $fatal(1, "scheduler accepted a command before configuration");
      if (dma_descriptor_valid && state_q != ST_ACTIVATION_DESCRIPTOR &&
          state_q != ST_WEIGHT_DESCRIPTOR)
        $fatal(1, "scheduler asserted an input descriptor in an invalid phase");
      if (result_dma_descriptor_valid && !result_enable_q)
        $fatal(1, "scheduler armed a result transfer for a non-final chunk");
      if (chunk_fire && result_enable_q && !result_dma_transfer_active)
        $fatal(1, "scheduler launched a final chunk before result DMA active");
      if (command_done && scheduler_fault_q)
        $fatal(1, "scheduler completed a command while faulted");
    end
  end
`endif

endmodule
