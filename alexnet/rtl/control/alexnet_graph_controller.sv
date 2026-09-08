`timescale 1ns/1ps

// One-image AlexNet graph root. It owns the shared compute fabric first as
// Conv and then as FC, issuing exactly Conv1..Conv5 and FC6..FC8. Pool1,
// Pool2, Pool5, Conv1 direct streaming, and Pool5-to-FC6 flatten requirements
// are explicit job fields rather than software-only conventions.
module alexnet_graph_controller (
    input  logic clk,
    input  logic rst,

    input  logic start_valid,
    output logic start_ready,
    input  logic [15:0] start_tag,

    output logic owner_valid,
    input  logic owner_ready,
    output logic owner_fc,
    output logic owner_release_valid,
    input  logic owner_release_ready,
    input  logic owner_active,
    input  logic active_owner_fc,
    input  logic owner_released,
    input  logic owner_fault,

    output logic conv_job_valid,
    input  logic conv_job_ready,
    output logic [2:0] conv_layer_id,
    output logic [15:0] conv_job_tag,
    output logic [8:0] conv_input_h,
    output logic [8:0] conv_input_w,
    output logic [9:0] conv_input_channels,
    output logic [9:0] conv_output_channels,
    output logic [7:0] conv_output_h,
    output logic [7:0] conv_output_w,
    output logic [3:0] conv_kernel,
    output logic [2:0] conv_stride,
    output logic [2:0] conv_padding,
    output logic [5:0] conv_n8_tiles,
    output logic [5:0] conv_input_chunks,
    output logic conv_activation_streaming,
    output logic conv_pool_enable,
    output logic [5:0] conv_pool_output_h,
    output logic [5:0] conv_pool_output_w,
    output logic conv_flatten_output,
    input  logic conv_complete_valid,
    output logic conv_complete_ready,
    input  logic [2:0] conv_complete_layer_id,
    input  logic [15:0] conv_complete_tag,
    input  logic conv_complete_error,

    output logic fc_job_valid,
    input  logic fc_job_ready,
    output logic [3:0] fc_layer_id,
    output logic [2:0] fc_m_count,
    output logic [15:0] fc_job_tag,
    input  logic fc_complete_valid,
    output logic fc_complete_ready,
    input  logic [3:0] fc_complete_layer_id,
    input  logic [15:0] fc_complete_tag,
    input  logic fc_complete_error,

    input  logic service_error,
    output logic busy,
    output logic inference_done,
    output logic inference_failed,
    output logic fault,
    output logic [3:0] fault_code,
    output logic [4:0] phase,
    output logic [3:0] active_layer_id,
    output logic [15:0] active_inference_tag,
    output logic [2:0] completed_conv_layers,
    output logic [1:0] completed_fc_layers
);
  typedef enum logic [4:0] {
    ST_IDLE = 5'd0,
    ST_ACQUIRE_CONV = 5'd1,
    ST_ISSUE_CONV = 5'd2,
    ST_WAIT_CONV = 5'd3,
    ST_RELEASE_CONV = 5'd4,
    ST_WAIT_CONV_RELEASE = 5'd5,
    ST_ACQUIRE_FC = 5'd6,
    ST_ISSUE_FC = 5'd7,
    ST_WAIT_FC = 5'd8,
    ST_RELEASE_FC = 5'd9,
    ST_WAIT_FC_RELEASE = 5'd10,
    ST_COMPLETE = 5'd11,
    ST_FAILED = 5'd12
  } state_t;

  localparam logic [3:0] FAULT_NONE = 4'd0;
  localparam logic [3:0] FAULT_OWNER = 4'd1;
  localparam logic [3:0] FAULT_CONV_METADATA = 4'd2;
  localparam logic [3:0] FAULT_CONV_SERVICE = 4'd3;
  localparam logic [3:0] FAULT_FC_METADATA = 4'd4;
  localparam logic [3:0] FAULT_FC_SERVICE = 4'd5;

  state_t state_q;
  logic [15:0] tag_q;
  logic [2:0] conv_layer_q;
  logic [3:0] fc_layer_q;
  logic fault_q;
  logic [3:0] fault_code_q;
  logic conv_response_bad;
  logic fc_response_bad;

  assign start_ready = state_q == ST_IDLE && !owner_active && !owner_fault &&
                       !service_error;
  assign busy = state_q != ST_IDLE;
  assign fault = fault_q;
  assign fault_code = fault_code_q;
  assign phase = state_q;
  assign active_inference_tag = tag_q;
  assign active_layer_id = state_q >= ST_ACQUIRE_FC ? fc_layer_q :
                                                     {1'b0, conv_layer_q};

  assign owner_valid = state_q == ST_ACQUIRE_CONV ||
                       state_q == ST_ACQUIRE_FC;
  assign owner_fc = state_q == ST_ACQUIRE_FC;
  assign owner_release_valid = state_q == ST_RELEASE_CONV ||
                               state_q == ST_RELEASE_FC;

  assign conv_job_valid = state_q == ST_ISSUE_CONV && !fault_q;
  assign conv_layer_id = conv_layer_q;
  assign conv_job_tag = tag_q + {13'd0, conv_layer_q};
  assign conv_complete_ready = state_q == ST_WAIT_CONV;
  assign conv_response_bad = conv_complete_layer_id != conv_layer_q ||
      conv_complete_tag != conv_job_tag;

  assign fc_job_valid = state_q == ST_ISSUE_FC && !fault_q;
  assign fc_layer_id = fc_layer_q;
  assign fc_m_count = 3'd1;
  assign fc_job_tag = tag_q + {12'd0, fc_layer_q};
  assign fc_complete_ready = state_q == ST_WAIT_FC;
  assign fc_response_bad = fc_complete_layer_id != fc_layer_q ||
                           fc_complete_tag != fc_job_tag;

  always_comb begin
    conv_input_h = 0;
    conv_input_w = 0;
    conv_input_channels = 0;
    conv_output_channels = 0;
    conv_output_h = 0;
    conv_output_w = 0;
    conv_kernel = 0;
    conv_stride = 0;
    conv_padding = 0;
    conv_n8_tiles = 0;
    conv_input_chunks = 0;
    conv_activation_streaming = 1'b0;
    conv_pool_enable = 1'b0;
    conv_pool_output_h = 0;
    conv_pool_output_w = 0;
    conv_flatten_output = 1'b0;
    case (conv_layer_q)
      1: begin
        conv_input_h = 224; conv_input_w = 224;
        conv_input_channels = 3; conv_output_channels = 64;
        conv_output_h = 55; conv_output_w = 55;
        conv_kernel = 11; conv_stride = 4; conv_padding = 2;
        conv_n8_tiles = 8; conv_input_chunks = 1;
        conv_activation_streaming = 1'b1;
        conv_pool_enable = 1'b1;
        conv_pool_output_h = 27; conv_pool_output_w = 27;
      end
      2: begin
        conv_input_h = 27; conv_input_w = 27;
        conv_input_channels = 64; conv_output_channels = 192;
        conv_output_h = 27; conv_output_w = 27;
        conv_kernel = 5; conv_stride = 1; conv_padding = 2;
        conv_n8_tiles = 24; conv_input_chunks = 8;
        conv_pool_enable = 1'b1;
        conv_pool_output_h = 13; conv_pool_output_w = 13;
      end
      3: begin
        conv_input_h = 13; conv_input_w = 13;
        conv_input_channels = 192; conv_output_channels = 384;
        conv_output_h = 13; conv_output_w = 13;
        conv_kernel = 3; conv_stride = 1; conv_padding = 1;
        conv_n8_tiles = 48; conv_input_chunks = 24;
      end
      4: begin
        conv_input_h = 13; conv_input_w = 13;
        conv_input_channels = 384; conv_output_channels = 256;
        conv_output_h = 13; conv_output_w = 13;
        conv_kernel = 3; conv_stride = 1; conv_padding = 1;
        conv_n8_tiles = 32; conv_input_chunks = 48;
      end
      5: begin
        conv_input_h = 13; conv_input_w = 13;
        conv_input_channels = 256; conv_output_channels = 256;
        conv_output_h = 13; conv_output_w = 13;
        conv_kernel = 3; conv_stride = 1; conv_padding = 1;
        conv_n8_tiles = 32; conv_input_chunks = 32;
        conv_pool_enable = 1'b1;
        conv_pool_output_h = 6; conv_pool_output_w = 6;
        conv_flatten_output = 1'b1;
      end
      default: begin end
    endcase
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      state_q <= ST_IDLE;
      tag_q <= 0;
      conv_layer_q <= 1;
      fc_layer_q <= 6;
      fault_q <= 1'b0;
      fault_code_q <= FAULT_NONE;
      inference_done <= 1'b0;
      inference_failed <= 1'b0;
      completed_conv_layers <= 0;
      completed_fc_layers <= 0;
    end else begin
      inference_done <= 1'b0;
      inference_failed <= 1'b0;

      if (state_q != ST_IDLE && state_q != ST_COMPLETE &&
          state_q != ST_FAILED && (owner_fault || service_error)) begin
        fault_q <= 1'b1;
        fault_code_q <= FAULT_OWNER;
        inference_failed <= 1'b1;
        state_q <= ST_FAILED;
      end else begin
        case (state_q)
          ST_IDLE: if (start_valid && start_ready) begin
            tag_q <= start_tag;
            conv_layer_q <= 1;
            fc_layer_q <= 6;
            completed_conv_layers <= 0;
            completed_fc_layers <= 0;
            fault_q <= 1'b0;
            fault_code_q <= FAULT_NONE;
            state_q <= ST_ACQUIRE_CONV;
          end
          ST_ACQUIRE_CONV: if (owner_valid && owner_ready)
            state_q <= ST_ISSUE_CONV;
          ST_ISSUE_CONV: if (conv_job_valid && conv_job_ready)
            state_q <= ST_WAIT_CONV;
          ST_WAIT_CONV: if (conv_complete_valid && conv_complete_ready) begin
            if (conv_complete_error) begin
              fault_q <= 1'b1;
              fault_code_q <= FAULT_CONV_SERVICE;
              inference_failed <= 1'b1;
              state_q <= ST_FAILED;
            end else if (conv_response_bad) begin
              fault_q <= 1'b1;
              fault_code_q <= FAULT_CONV_METADATA;
              inference_failed <= 1'b1;
              state_q <= ST_FAILED;
            end else begin
              completed_conv_layers <= completed_conv_layers + 1'b1;
              if (conv_layer_q == 5)
                state_q <= ST_RELEASE_CONV;
              else begin
                conv_layer_q <= conv_layer_q + 1'b1;
                state_q <= ST_ISSUE_CONV;
              end
            end
          end
          ST_RELEASE_CONV: if (owner_release_valid && owner_release_ready)
            state_q <= ST_WAIT_CONV_RELEASE;
          ST_WAIT_CONV_RELEASE: if (owner_released || !owner_active)
            state_q <= ST_ACQUIRE_FC;
          ST_ACQUIRE_FC: if (owner_valid && owner_ready)
            state_q <= ST_ISSUE_FC;
          ST_ISSUE_FC: if (fc_job_valid && fc_job_ready)
            state_q <= ST_WAIT_FC;
          ST_WAIT_FC: if (fc_complete_valid && fc_complete_ready) begin
            if (fc_complete_error) begin
              fault_q <= 1'b1;
              fault_code_q <= FAULT_FC_SERVICE;
              inference_failed <= 1'b1;
              state_q <= ST_FAILED;
            end else if (fc_response_bad) begin
              fault_q <= 1'b1;
              fault_code_q <= FAULT_FC_METADATA;
              inference_failed <= 1'b1;
              state_q <= ST_FAILED;
            end else begin
              completed_fc_layers <= completed_fc_layers + 1'b1;
              if (fc_layer_q == 8)
                state_q <= ST_RELEASE_FC;
              else begin
                fc_layer_q <= fc_layer_q + 1'b1;
                state_q <= ST_ISSUE_FC;
              end
            end
          end
          ST_RELEASE_FC: if (owner_release_valid && owner_release_ready)
            state_q <= ST_WAIT_FC_RELEASE;
          ST_WAIT_FC_RELEASE: if (owner_released || !owner_active)
            state_q <= ST_COMPLETE;
          ST_COMPLETE: begin
            inference_done <= 1'b1;
            state_q <= ST_IDLE;
          end
          ST_FAILED: state_q <= ST_FAILED;
          default: begin
            fault_q <= 1'b1;
            fault_code_q <= FAULT_OWNER;
            inference_failed <= 1'b1;
            state_q <= ST_FAILED;
          end
        endcase
      end
    end
  end

`ifndef SYNTHESIS
  always_ff @(posedge clk) begin
    if (!rst) begin
      if (conv_job_valid && (!owner_active || active_owner_fc))
        $fatal(1, "graph controller issued Conv without Conv ownership");
      if (fc_job_valid && (!owner_active || !active_owner_fc))
        $fatal(1, "graph controller issued FC without FC ownership");
      if (conv_job_valid && conv_layer_q == 1 &&
          (!conv_activation_streaming || conv_input_h != 224 ||
           conv_output_h != 55))
        $fatal(1, "graph controller lost Conv1 streaming geometry");
      if (conv_job_valid && conv_layer_q == 5 &&
          (!conv_pool_enable || !conv_flatten_output ||
           conv_pool_output_h != 6 || conv_pool_output_w != 6))
        $fatal(1, "graph controller lost Pool5 flatten boundary");
      if (inference_done && (completed_conv_layers != 5 ||
                             completed_fc_layers != 3))
        $fatal(1, "graph controller completed an incomplete graph");
    end
  end
`endif
endmodule
