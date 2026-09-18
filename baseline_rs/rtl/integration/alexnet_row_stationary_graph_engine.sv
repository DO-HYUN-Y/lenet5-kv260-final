`timescale 1ns/1ps
// Connected batch-one Conv1..FC8 pure-RS baseline. Bank/DDR ownership is an
// external service, as in the GitHub graph-payload boundary. input_done must
// follow the last accepted PE input load. Weight requests authorize one N8
// group's N-major / K-major stream; no weight is reused across requests.
// command_* numerical parameters accompany parameter_valid and must match
// the current weight_request_layer_id/n_base; held until parameter_ready.
module alexnet_row_stationary_graph_engine (
    input logic clk, rst,
    input logic input_load_valid,
    output logic input_load_ready,
    input logic [11:0] input_load_k,
    input logic [63:0] input_load_values,
    input logic signed [31:0] command_bias [0:7],
    input logic signed [17:0] command_multiplier [0:7],
    input logic [5:0] command_right_shift [0:7],
    input logic [7:0] command_relu,
    input logic weight_axis_valid,
    output logic weight_axis_ready,
    input logic [127:0] weight_axis_values,
    input logic [15:0] weight_axis_keep,
    input logic weight_axis_last,
    input logic psum_in_valid,
    output logic psum_in_ready,
    input logic signed [31:0] psum_in_values [0:7],
    output logic psum_out_valid,
    input logic psum_out_ready,
    output logic signed [31:0] psum_out_values [0:7],
    output logic [3:0] psum_out_m_count,
    output logic [12:0] psum_out_m_base,
    output logic [15:0] psum_out_n, psum_out_tag,
    output logic output_valid,
    input logic output_ready,
    output logic [63:0] output_values,
    output logic [7:0] output_lane_mask,
    output logic [12:0] output_m,
    output logic [15:0] output_n_base, output_tag,
    output logic [1:0] output_destination,
    output logic [63:0] input_service_bytes, weight_service_bytes,
    output logic [63:0] psum_read_service_bytes, psum_write_service_bytes,
    output logic [63:0] output_service_bytes, useful_mac_count,
    input logic start_valid,
    output logic start_ready,
    input logic [15:0] start_tag,
    output logic input_request_valid,
    input logic input_request_ready,
    output logic [3:0] input_request_layer_id,
    output logic [12:0] input_request_m_base,
    output logic [3:0] input_request_m_count,
    output logic [13:0] input_request_k_offset,
    output logic [11:0] input_request_k_count,
    input logic input_done, input_error,
    output logic weight_request_valid,
    input logic weight_request_ready,
    output logic [3:0] weight_request_layer_id,
    output logic [15:0] weight_request_n_base,
    output logic [3:0] weight_request_n_count,
    output logic [13:0] weight_request_k_offset,
    output logic [11:0] weight_request_k_count,
    output logic parameter_request_valid,
    input logic parameter_valid,
    output logic parameter_ready,
    input logic [1:0] result_destination,
    output logic layer_complete_valid,
    input logic layer_complete_ready,
    output logic [3:0] layer_complete_id,
    output logic layer_requires_pool,
    output logic inference_done, engine_busy, engine_fault,
    output logic [31:0] completed_commands, completed_input_tiles
);
    logic input_begin_valid;
    logic input_begin_ready;
    logic [11:0] input_begin_k_count;
    logic [3:0] input_begin_m_count;
    logic command_valid;
    logic command_ready;
    logic [3:0] command_m_count, command_n_count;
    logic [11:0] command_k_count;
    logic [12:0] command_m_base;
    logic [15:0] command_n_base, command_tag;
    logic command_first_k, command_final_k;
    logic [1:0] command_destination;
    logic command_done, busy, fault;
  logic scheduler_input_valid, scheduler_input_ready;
  logic scheduler_command_valid, scheduler_command_ready;
  logic scheduler_busy, scheduler_fault;
  logic fault_completion, command_inflight_q;
  logic [3:0] scheduler_layer, scheduler_m_count, scheduler_n_count;
  logic [12:0] scheduler_m_base;
  logic [13:0] scheduler_k_offset;
  logic [11:0] scheduler_k_count;
  logic [15:0] scheduler_n_base, scheduler_tag;
  logic scheduler_first, scheduler_final;
  logic [3:0] scheduler_row_width;
  logic [2:0] scheduler_stride;
  assign engine_busy=scheduler_busy || busy;
  assign engine_fault=scheduler_fault || fault;
  assign input_request_valid=scheduler_input_valid && input_begin_ready;
  assign scheduler_input_ready=input_request_ready && input_begin_ready;
  assign input_begin_valid=scheduler_input_valid && input_request_ready;
  assign input_begin_k_count=scheduler_k_count;
  assign input_begin_m_count=scheduler_m_count;
  assign input_request_layer_id=scheduler_layer;
  assign input_request_m_base=scheduler_m_base;
  assign input_request_m_count=scheduler_m_count;
  assign input_request_k_offset=scheduler_k_offset;
  assign input_request_k_count=scheduler_k_count;
  assign weight_request_valid=scheduler_command_valid && command_ready &&
      (!scheduler_final || parameter_valid) && !engine_fault;
  assign scheduler_command_ready=command_ready && weight_request_ready &&
      (!scheduler_final || parameter_valid) && !engine_fault;
  assign command_valid=scheduler_command_valid && weight_request_ready &&
      (!scheduler_final || parameter_valid) && !engine_fault;
  assign parameter_request_valid=scheduler_command_valid && scheduler_final && !engine_fault;
  assign parameter_ready=command_valid && command_ready && scheduler_final;
  assign weight_request_layer_id=scheduler_layer;
  assign weight_request_n_base=scheduler_n_base;
  assign weight_request_n_count=scheduler_n_count;
  assign weight_request_k_offset=scheduler_k_offset;
  assign weight_request_k_count=scheduler_k_count;
  assign command_m_count=scheduler_m_count;
  assign command_n_count=scheduler_n_count;
  assign command_k_count=scheduler_k_count;
  assign command_m_base=scheduler_m_base;
  assign command_n_base=scheduler_n_base;
  assign command_tag=scheduler_tag;
  assign command_first_k=scheduler_first;
  assign command_final_k=scheduler_final;
  assign command_destination=result_destination;
  assign layer_complete_id=scheduler_layer;
  assign fault_completion=fault && command_inflight_q;
  always_ff @(posedge clk) begin
    if(rst) command_inflight_q<=0;
    else begin
      if(command_valid && command_ready) command_inflight_q<=1;
      if(command_done || fault_completion) command_inflight_q<=0;
    end
  end
  alexnet_row_stationary_graph_scheduler u_scheduler (
      .clk, .rst, .start_valid, .start_ready, .start_tag,
      .input_request_valid(scheduler_input_valid), .input_request_ready(scheduler_input_ready),
      .row_width(scheduler_row_width),.window_stride(scheduler_stride),
      .layer_id(scheduler_layer), .m_base(scheduler_m_base), .m_count(scheduler_m_count),
      .k_offset(scheduler_k_offset), .k_count(scheduler_k_count), .input_done, .input_error,
      .command_valid(scheduler_command_valid), .command_ready(scheduler_command_ready),
      .n_base(scheduler_n_base), .n_count(scheduler_n_count), .first_k(scheduler_first),
      .final_k(scheduler_final), .command_tag(scheduler_tag),
      .command_done(command_done || fault_completion), .command_error(fault),
      .layer_complete_valid, .layer_complete_ready, .layer_requires_pool,
      .inference_done, .fault(scheduler_fault), .busy(scheduler_busy),
      .completed_commands, .completed_input_tiles
  );
  alexnet_m8r128_row_stationary_core u_core (
      .clk,
      .rst,
      .input_begin_valid,
      .input_begin_ready,
      .input_begin_k_count,
      .input_begin_m_count,
      .input_begin_row_width(scheduler_row_width),.input_begin_stride(scheduler_stride),
      .input_load_valid,
      .input_load_ready,
      .input_load_k,
      .input_load_values,
      .command_valid,
      .command_ready,
      .command_m_count,
      .command_n_count,
      .command_k_count,
      .command_m_base,
      .command_n_base,
      .command_tag,
      .command_first_k,
      .command_final_k,
      .command_destination,
      .command_bias,
      .command_multiplier,
      .command_right_shift,
      .command_relu,
      .weight_axis_valid,
      .weight_axis_ready,
      .weight_axis_values,
      .weight_axis_keep,
      .weight_axis_last,
      .psum_in_valid,
      .psum_in_ready,
      .psum_in_values,
      .psum_out_valid,
      .psum_out_ready,
      .psum_out_values,
      .psum_out_m_count,
      .psum_out_m_base,
      .psum_out_n,
      .psum_out_tag,
      .output_valid,
      .output_ready,
      .output_values,
      .output_lane_mask,
      .output_m,
      .output_n_base,
      .output_tag,
      .output_destination,
      .command_done,
      .busy,
      .fault,
      .input_service_bytes,
      .weight_service_bytes,
      .psum_read_service_bytes,
      .psum_write_service_bytes,
      .output_service_bytes,
      .useful_mac_count
  );
endmodule
