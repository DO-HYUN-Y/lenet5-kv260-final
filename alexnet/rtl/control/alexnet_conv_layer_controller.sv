`timescale 1ns/1ps

// One Conv layer job becomes an N8-major / input-chunk-minor command stream
// for alexnet_m4n8_shared_compute_top. The fixed AlexNet geometry is checked
// at the boundary, parameters are acquired once per output N8 tile, and the
// layer is not retired until the external output/pool service drains it.  The
// service descriptor is armed before the first command so real result AXIS
// traffic can never deadlock waiting for a late descriptor.
//
// This block owns control metadata only. External services still provide the
// activation/weight AXIS payloads, Conv1's direct activation stream, output
// storage, and Pool1/2/5 execution.
module alexnet_conv_layer_controller (
    input logic clk,
    input logic rst,

    input  logic job_valid,
    output logic job_ready,
    input  logic [2:0] job_layer_id,
    input  logic [15:0] job_tag,
    input  logic [8:0] job_input_h,
    input  logic [8:0] job_input_w,
    input  logic [9:0] job_input_channels,
    input  logic [9:0] job_output_channels,
    input  logic [7:0] job_output_h,
    input  logic [7:0] job_output_w,
    input  logic [3:0] job_kernel,
    input  logic [2:0] job_stride,
    input  logic [2:0] job_padding,
    input  logic [5:0] job_n8_tiles,
    input  logic [5:0] job_input_chunks,
    input  logic job_activation_streaming,
    input  logic job_pool_enable,
    input  logic [5:0] job_pool_output_h,
    input  logic [5:0] job_pool_output_w,
    input  logic job_flatten_output,

    output logic parameter_request_valid,
    input  logic parameter_request_ready,
    output logic [2:0] parameter_request_layer_id,
    output logic [15:0] parameter_request_job_tag,
    output logic [15:0] parameter_request_n_base,
    input  logic parameter_valid,
    output logic parameter_ready,
    input  logic [2:0] parameter_layer_id,
    input  logic [15:0] parameter_job_tag,
    input  logic [15:0] parameter_n_base,
    input  logic signed [31:0] parameter_bias [0:7],
    input  logic signed [17:0] parameter_multiplier [0:7],
    input  logic [5:0] parameter_right_shift [0:7],

    output logic result_commit_request_valid,
    input  logic result_commit_request_ready,
    output logic [2:0] result_commit_layer_id,
    output logic [15:0] result_commit_job_tag,
    output logic [7:0] result_commit_output_h,
    output logic [7:0] result_commit_output_w,
    output logic [9:0] result_commit_output_channels,
    output logic result_commit_pool_enable,
    output logic [5:0] result_commit_pool_output_h,
    output logic [5:0] result_commit_pool_output_w,
    output logic result_commit_flatten_output,
    input  logic result_complete_valid,
    output logic result_complete_ready,
    input  logic [2:0] result_complete_layer_id,
    input  logic [15:0] result_complete_job_tag,
    input  logic result_complete_error,
    input  logic service_error,

    output logic cfg_valid,
    input  logic cfg_ready,
    output logic [1:0] cfg_destination,
    output logic [15:0] cfg_n64_tile_base,
    output logic [2:0] cfg_slice_index,
    output logic [7:0] cfg_lane_mask,
    output logic signed [31:0] cfg_bias [0:7],
    output logic signed [17:0] cfg_multiplier [0:7],
    output logic [5:0] cfg_right_shift [0:7],
    output logic [7:0] cfg_relu,

    output logic command_valid,
    input  logic command_ready,
    output logic [15:0] command_id,
    output logic command_activation_streaming,
    output logic [1:0] command_activation_destination,
    output logic [10:0] command_activation_word_count,
    output logic [15:0] command_activation_byte_count,
    output logic [7:0] command_activation_lane_mask,
    output logic [15:0] command_activation_tensor_tag,
    output logic [10:0] command_weight_word_count,
    output logic [15:0] command_weight_byte_count,
    output logic [7:0] command_weight_lane_mask,
    output logic [15:0] command_weight_context_tag,
    output logic command_result_enable,
    output logic [12:0] command_result_word_count,
    output logic [15:0] command_result_byte_count,
    output logic [1:0] command_result_destination,
    output logic [2:0] command_result_slice,
    output logic [15:0] command_result_n_base,
    output logic [7:0] command_result_lane_mask,
    output logic [15:0] command_result_first_tile_tag,
    output logic [7:0] command_chunk_input_h,
    output logic [7:0] command_chunk_input_w,
    output logic [3:0] command_chunk_channel_count,
    output logic [7:0] command_chunk_input_lane_mask,
    output logic [3:0] command_chunk_kernel,
    output logic [2:0] command_chunk_stride,
    output logic [2:0] command_chunk_padding,
    output logic [9:0] command_chunk_k_count,
    output logic [15:0] command_chunk_weight_context_tag,
    output logic [12:0] command_chunk_word_count,
    output logic [7:0] command_chunk_output_width,
    output logic [15:0] command_chunk_accum_context_tag,
    output logic [15:0] command_chunk_tile_tag_base,
    output logic [7:0] command_chunk_index,
    output logic command_chunk_first,
    output logic command_chunk_final,
    input logic command_done,
    input logic command_rejected,
    input logic command_error,
    input logic [15:0] completed_command_id,
    input logic core_fault,

    output logic complete_valid,
    input  logic complete_ready,
    output logic [2:0] complete_layer_id,
    output logic [15:0] complete_job_tag,
    output logic complete_error,
    output logic busy,
    output logic fault,
    output logic [3:0] fault_code,
    output logic [3:0] phase,
    output logic [5:0] active_n8_tile,
    output logic [5:0] active_input_chunk,
    output logic [12:0] completed_commands,
    output logic [5:0] completed_n8_tiles,
    output logic [15:0] completed_output_words
);
  typedef enum logic [3:0] {
    ST_IDLE = 4'd0,
    ST_CHECK_JOB = 4'd1,
    ST_PARAMETER_REQUEST = 4'd2,
    ST_PARAMETER_RESPONSE = 4'd3,
    ST_CONFIGURE = 4'd4,
    ST_COMMAND = 4'd5,
    ST_WAIT_COMMAND = 4'd6,
    ST_NEXT = 4'd7,
    ST_COMMIT_REQUEST = 4'd8,
    ST_COMMIT_RESPONSE = 4'd9,
    ST_COMPLETE = 4'd10,
    ST_FAILED = 4'd11
  } state_t;

  localparam logic [3:0] FAULT_NONE = 4'd0;
  localparam logic [3:0] FAULT_JOB = 4'd1;
  localparam logic [3:0] FAULT_PARAMETER = 4'd2;
  localparam logic [3:0] FAULT_COMMAND = 4'd3;
  localparam logic [3:0] FAULT_COMMAND_METADATA = 4'd4;
  localparam logic [3:0] FAULT_RESULT = 4'd5;
  localparam logic [3:0] FAULT_SERVICE = 4'd6;

  state_t state_q;
  logic [2:0] layer_q;
  logic [15:0] tag_q;
  logic [8:0] input_h_q, input_w_q;
  logic [9:0] input_channels_q, output_channels_q;
  logic [7:0] output_h_q, output_w_q;
  logic [3:0] kernel_q;
  logic [2:0] stride_q, padding_q;
  logic [5:0] n8_tiles_q, input_chunks_q;
  logic activation_streaming_q, pool_enable_q, flatten_output_q;
  logic [5:0] pool_output_h_q, pool_output_w_q;
  logic [5:0] n8_tile_q, input_chunk_q;
  logic [15:0] n_base_q, tile_tag_base_q, command_id_q;
  logic [10:0] activation_words_q, weight_words_q;
  logic [12:0] output_words_q;
  logic [3:0] chunk_channels_q;
  logic [7:0] chunk_lane_mask_q;
  logic fault_q;
  logic [3:0] fault_code_q;
  logic result_service_started_q;
  logic result_service_completed_q;
  logic job_fields_valid;
  logic parameter_fields_valid;
  logic final_chunk;
  logic final_tile;

  assign job_ready = state_q == ST_IDLE && !core_fault && !service_error;
  assign busy = state_q != ST_IDLE;
  assign fault = fault_q;
  assign fault_code = fault_code_q;
  assign phase = state_q;
  assign active_n8_tile = n8_tile_q;
  assign active_input_chunk = input_chunk_q;

  always_comb begin
    job_fields_valid = 1'b0;
    case (layer_q)
      3'd1: job_fields_valid = input_h_q == 224 && input_w_q == 224 &&
          input_channels_q == 3 && output_channels_q == 64 &&
          output_h_q == 55 && output_w_q == 55 && kernel_q == 11 &&
          stride_q == 4 && padding_q == 2 && n8_tiles_q == 8 &&
          input_chunks_q == 1 && activation_streaming_q && pool_enable_q &&
          pool_output_h_q == 27 && pool_output_w_q == 27 &&
          !flatten_output_q;
      3'd2: job_fields_valid = input_h_q == 27 && input_w_q == 27 &&
          input_channels_q == 64 && output_channels_q == 192 &&
          output_h_q == 27 && output_w_q == 27 && kernel_q == 5 &&
          stride_q == 1 && padding_q == 2 && n8_tiles_q == 24 &&
          input_chunks_q == 8 && !activation_streaming_q && pool_enable_q &&
          pool_output_h_q == 13 && pool_output_w_q == 13 &&
          !flatten_output_q;
      3'd3: job_fields_valid = input_h_q == 13 && input_w_q == 13 &&
          input_channels_q == 192 && output_channels_q == 384 &&
          output_h_q == 13 && output_w_q == 13 && kernel_q == 3 &&
          stride_q == 1 && padding_q == 1 && n8_tiles_q == 48 &&
          input_chunks_q == 24 && !activation_streaming_q && !pool_enable_q &&
          pool_output_h_q == 0 && pool_output_w_q == 0 && !flatten_output_q;
      3'd4: job_fields_valid = input_h_q == 13 && input_w_q == 13 &&
          input_channels_q == 384 && output_channels_q == 256 &&
          output_h_q == 13 && output_w_q == 13 && kernel_q == 3 &&
          stride_q == 1 && padding_q == 1 && n8_tiles_q == 32 &&
          input_chunks_q == 48 && !activation_streaming_q && !pool_enable_q &&
          pool_output_h_q == 0 && pool_output_w_q == 0 && !flatten_output_q;
      3'd5: job_fields_valid = input_h_q == 13 && input_w_q == 13 &&
          input_channels_q == 256 && output_channels_q == 256 &&
          output_h_q == 13 && output_w_q == 13 && kernel_q == 3 &&
          stride_q == 1 && padding_q == 1 && n8_tiles_q == 32 &&
          input_chunks_q == 32 && !activation_streaming_q && pool_enable_q &&
          pool_output_h_q == 6 && pool_output_w_q == 6 && flatten_output_q;
      default: job_fields_valid = 1'b0;
    endcase
  end

  assign parameter_request_valid = state_q == ST_PARAMETER_REQUEST &&
                                   !fault_q;
  assign parameter_request_layer_id = layer_q;
  assign parameter_request_job_tag = tag_q;
  assign parameter_request_n_base = n_base_q;
  assign parameter_ready = state_q == ST_PARAMETER_RESPONSE && !fault_q;
  always_comb begin
    parameter_fields_valid = parameter_layer_id == layer_q &&
        parameter_job_tag == tag_q && parameter_n_base == n_base_q;
    for (int lane = 0; lane < 8; lane++) begin
      if (parameter_multiplier[lane] <= 0 ||
          parameter_right_shift[lane] < 23 ||
          parameter_right_shift[lane] > 32)
        parameter_fields_valid = 1'b0;
    end
  end

  assign cfg_valid = state_q == ST_CONFIGURE && !fault_q;
  assign cfg_destination = 2'd0;
  assign cfg_n64_tile_base = {n_base_q[15:6], 6'b0};
  assign cfg_slice_index = n_base_q[5:3];
  assign cfg_lane_mask = 8'hff;
  assign cfg_relu = 8'hff;

  assign final_chunk = input_chunk_q + 1'b1 == input_chunks_q;
  assign final_tile = n8_tile_q + 1'b1 == n8_tiles_q;
  assign command_valid = state_q == ST_COMMAND && !fault_q;
  assign command_id = command_id_q;
  assign command_activation_streaming = activation_streaming_q;
  assign command_activation_destination = command_id_q[0] ? 2'd1 : 2'd0;
  assign command_activation_word_count = activation_streaming_q ? 0 :
                                         activation_words_q;
  assign command_activation_byte_count = activation_streaming_q ? 0 :
      {2'b0, activation_words_q, 3'b000};
  assign command_activation_lane_mask = chunk_lane_mask_q;
  assign command_activation_tensor_tag = command_id_q;
  assign command_weight_word_count = weight_words_q;
  assign command_weight_byte_count = {2'b0, weight_words_q, 3'b000};
  assign command_weight_lane_mask = 8'hff;
  assign command_weight_context_tag = command_id_q;
  assign command_result_enable = final_chunk;
  assign command_result_word_count = output_words_q;
  assign command_result_byte_count = {output_words_q, 3'b000};
  assign command_result_destination = 2'd0;
  assign command_result_slice = n_base_q[5:3];
  assign command_result_n_base = n_base_q;
  assign command_result_lane_mask = 8'hff;
  assign command_result_first_tile_tag = tile_tag_base_q;
  assign command_chunk_input_h = input_h_q[7:0];
  assign command_chunk_input_w = input_w_q[7:0];
  assign command_chunk_channel_count = chunk_channels_q;
  assign command_chunk_input_lane_mask = chunk_lane_mask_q;
  assign command_chunk_kernel = kernel_q;
  assign command_chunk_stride = stride_q;
  assign command_chunk_padding = padding_q;
  assign command_chunk_k_count = weight_words_q[9:0];
  assign command_chunk_weight_context_tag = command_id_q;
  assign command_chunk_word_count = output_words_q;
  assign command_chunk_output_width = output_w_q;
  assign command_chunk_accum_context_tag = tile_tag_base_q;
  assign command_chunk_tile_tag_base = tile_tag_base_q;
  assign command_chunk_index = {2'b00, input_chunk_q};
  assign command_chunk_first = input_chunk_q == 0;
  assign command_chunk_final = final_chunk;

  assign result_commit_request_valid = state_q == ST_COMMIT_REQUEST &&
                                       !fault_q;
  assign result_commit_layer_id = layer_q;
  assign result_commit_job_tag = tag_q;
  assign result_commit_output_h = output_h_q;
  assign result_commit_output_w = output_w_q;
  assign result_commit_output_channels = output_channels_q;
  assign result_commit_pool_enable = pool_enable_q;
  assign result_commit_pool_output_h = pool_output_h_q;
  assign result_commit_pool_output_w = pool_output_w_q;
  assign result_commit_flatten_output = flatten_output_q;
  // The final service beat can retire in the same cycle as the compute
  // command.  Accept and remember that completion from the moment the service
  // has been armed instead of requiring a one-cycle pulse to arrive later.
  assign result_complete_ready = result_service_started_q &&
                                 !result_service_completed_q && !fault_q;

  assign complete_valid = state_q == ST_COMPLETE || state_q == ST_FAILED;
  assign complete_layer_id = layer_q;
  assign complete_job_tag = tag_q;
  assign complete_error = state_q == ST_FAILED;

  always_ff @(posedge clk) begin
    if (rst) begin
      state_q <= ST_IDLE;
      layer_q <= 0;
      tag_q <= 0;
      input_h_q <= 0;
      input_w_q <= 0;
      input_channels_q <= 0;
      output_channels_q <= 0;
      output_h_q <= 0;
      output_w_q <= 0;
      kernel_q <= 0;
      stride_q <= 0;
      padding_q <= 0;
      n8_tiles_q <= 0;
      input_chunks_q <= 0;
      activation_streaming_q <= 0;
      pool_enable_q <= 0;
      pool_output_h_q <= 0;
      pool_output_w_q <= 0;
      flatten_output_q <= 0;
      n8_tile_q <= 0;
      input_chunk_q <= 0;
      n_base_q <= 0;
      tile_tag_base_q <= 0;
      command_id_q <= 0;
      activation_words_q <= 0;
      weight_words_q <= 0;
      output_words_q <= 0;
      chunk_channels_q <= 0;
      chunk_lane_mask_q <= 0;
      fault_q <= 0;
      fault_code_q <= FAULT_NONE;
      result_service_started_q <= 1'b0;
      result_service_completed_q <= 1'b0;
      completed_commands <= 0;
      completed_n8_tiles <= 0;
      completed_output_words <= 0;
      for (int lane = 0; lane < 8; lane++) begin
        cfg_bias[lane] <= 0;
        cfg_multiplier[lane] <= 0;
        cfg_right_shift[lane] <= 0;
      end
    end else begin
      if (state_q != ST_IDLE && state_q != ST_COMPLETE &&
          state_q != ST_FAILED && (core_fault || service_error)) begin
        fault_q <= 1'b1;
        fault_code_q <= core_fault ? FAULT_COMMAND : FAULT_SERVICE;
        state_q <= ST_FAILED;
      end else begin
        case (state_q)
          ST_IDLE: if (job_valid && job_ready) begin
            layer_q <= job_layer_id;
            tag_q <= job_tag;
            input_h_q <= job_input_h;
            input_w_q <= job_input_w;
            input_channels_q <= job_input_channels;
            output_channels_q <= job_output_channels;
            output_h_q <= job_output_h;
            output_w_q <= job_output_w;
            kernel_q <= job_kernel;
            stride_q <= job_stride;
            padding_q <= job_padding;
            n8_tiles_q <= job_n8_tiles;
            input_chunks_q <= job_input_chunks;
            activation_streaming_q <= job_activation_streaming;
            pool_enable_q <= job_pool_enable;
            pool_output_h_q <= job_pool_output_h;
            pool_output_w_q <= job_pool_output_w;
            flatten_output_q <= job_flatten_output;
            n8_tile_q <= 0;
            input_chunk_q <= 0;
            n_base_q <= 0;
            tile_tag_base_q <= job_tag;
            command_id_q <= job_tag;
            fault_q <= 0;
            fault_code_q <= FAULT_NONE;
            result_service_started_q <= 1'b0;
            result_service_completed_q <= 1'b0;
            completed_commands <= 0;
            completed_n8_tiles <= 0;
            completed_output_words <= 0;
            state_q <= ST_CHECK_JOB;
          end

          ST_CHECK_JOB: begin
            if (!job_fields_valid) begin
              fault_q <= 1'b1;
              fault_code_q <= FAULT_JOB;
              state_q <= ST_FAILED;
            end else begin
              case (layer_q)
                1: begin
                  activation_words_q <= 0;
                  weight_words_q <= 363;
                  output_words_q <= 3025;
                  chunk_channels_q <= 3;
                  chunk_lane_mask_q <= 8'h07;
                end
                2: begin
                  activation_words_q <= 729;
                  weight_words_q <= 200;
                  output_words_q <= 729;
                  chunk_channels_q <= 8;
                  chunk_lane_mask_q <= 8'hff;
                end
                default: begin
                  activation_words_q <= 169;
                  weight_words_q <= 72;
                  output_words_q <= 169;
                  chunk_channels_q <= 8;
                  chunk_lane_mask_q <= 8'hff;
                end
              endcase
              state_q <= ST_COMMIT_REQUEST;
            end
          end

          // Despite the historical "commit" port name this handshake arms
          // the streaming result sink before any command can emit data.
          ST_COMMIT_REQUEST: if (result_commit_request_valid &&
                                result_commit_request_ready) begin
            result_service_started_q <= 1'b1;
            state_q <= ST_PARAMETER_REQUEST;
          end

          ST_PARAMETER_REQUEST: if (parameter_request_valid &&
                                    parameter_request_ready)
            state_q <= ST_PARAMETER_RESPONSE;

          ST_PARAMETER_RESPONSE: if (parameter_valid && parameter_ready) begin
            if (!parameter_fields_valid) begin
              fault_q <= 1'b1;
              fault_code_q <= FAULT_PARAMETER;
              state_q <= ST_FAILED;
            end else begin
              for (int lane = 0; lane < 8; lane++) begin
                cfg_bias[lane] <= parameter_bias[lane];
                cfg_multiplier[lane] <= parameter_multiplier[lane];
                cfg_right_shift[lane] <= parameter_right_shift[lane];
              end
              state_q <= ST_CONFIGURE;
            end
          end

          ST_CONFIGURE: if (cfg_valid && cfg_ready)
            state_q <= ST_COMMAND;

          ST_COMMAND: if (command_valid && command_ready)
            state_q <= ST_WAIT_COMMAND;

          ST_WAIT_COMMAND: begin
            if (command_rejected || command_error) begin
              fault_q <= 1'b1;
              fault_code_q <= FAULT_COMMAND;
              state_q <= ST_FAILED;
            end else if (command_done) begin
              if (completed_command_id != command_id_q) begin
                fault_q <= 1'b1;
                fault_code_q <= FAULT_COMMAND_METADATA;
                state_q <= ST_FAILED;
              end else begin
                completed_commands <= completed_commands + 1'b1;
                command_id_q <= command_id_q + 1'b1;
                state_q <= ST_NEXT;
              end
            end
          end

          ST_NEXT: begin
            if (!final_chunk) begin
              input_chunk_q <= input_chunk_q + 1'b1;
              state_q <= ST_COMMAND;
            end else begin
              completed_n8_tiles <= completed_n8_tiles + 1'b1;
              completed_output_words <= completed_output_words + output_words_q;
              if (final_tile) begin
                state_q <= result_service_completed_q ? ST_COMPLETE :
                                                        ST_COMMIT_RESPONSE;
              end else begin
                n8_tile_q <= n8_tile_q + 1'b1;
                n_base_q <= n_base_q + 16'd8;
                tile_tag_base_q <= tile_tag_base_q + output_words_q;
                input_chunk_q <= 0;
                state_q <= ST_PARAMETER_REQUEST;
              end
            end
          end

          ST_COMMIT_RESPONSE: if (result_service_completed_q)
            state_q <= ST_COMPLETE;

          ST_COMPLETE: if (complete_valid && complete_ready)
            state_q <= ST_IDLE;

          ST_FAILED: state_q <= ST_FAILED;

          default: begin
            fault_q <= 1'b1;
            fault_code_q <= FAULT_SERVICE;
            state_q <= ST_FAILED;
          end
          endcase

          if (result_complete_valid && result_complete_ready) begin
            if (result_complete_error ||
                result_complete_layer_id != layer_q ||
                result_complete_job_tag != tag_q) begin
              fault_q <= 1'b1;
              fault_code_q <= FAULT_RESULT;
              state_q <= ST_FAILED;
            end else begin
              result_service_completed_q <= 1'b1;
            end
          end
      end
    end
  end

`ifndef SYNTHESIS
  always_ff @(posedge clk) begin
    if (!rst) begin
      if (command_valid && command_result_enable != command_chunk_final)
        $fatal(1, "Conv layer controller result/final relationship changed");
      if (command_valid && command_weight_word_count !=
          command_chunk_k_count)
        $fatal(1, "Conv layer controller weight/K relationship changed");
      if (command_valid && command_chunk_first != (input_chunk_q == 0))
        $fatal(1, "Conv layer controller first-chunk marker changed");
      if (state_q == ST_COMPLETE &&
          (completed_n8_tiles != n8_tiles_q ||
           completed_output_words != output_words_q * n8_tiles_q))
        $fatal(1, "Conv layer controller retired incomplete layer");
    end
  end
`endif
endmodule
