`timescale 1ns/1ps

// Intercept FC6 activation read requests and source them from Pool5 storage
// through the channel-major flatten reader. Weight reads and all FC7/FC8
// reads remain physical-memory requests. The generated N8 stream is packed
// to the same 128-bit MM2S interface consumed by shared compute.
module alexnet_fc6_flatten_injector (
    input logic clk,
    input logic rst,

    input  logic request_valid,
    output logic request_ready,
    input  logic [3:0] active_layer_id,
    input  logic [13:0] active_k_offset,
    input  logic [9:0] active_k_count,
    input  logic [1:0] request_destination,
    input  logic [9:0] request_word_count,
    input  logic [15:0] request_byte_count,
    input  logic [2:0] request_m_count,
    input  logic [15:0] request_tag,

    output logic external_request_valid,
    input  logic external_request_ready,
    output logic [3:0] external_request_layer_id,
    output logic [13:0] external_request_k_offset,
    output logic [9:0] external_request_k_count,
    output logic [1:0] external_request_destination,
    output logic [9:0] external_request_word_count,
    output logic [15:0] external_request_byte_count,
    output logic [2:0] external_request_m_count,
    output logic [15:0] external_request_tag,

    output logic pool5_read_request_valid,
    input  logic pool5_read_request_ready,
    output logic [10:0] pool5_read_request_word_address,
    output logic [2:0] pool5_read_request_lane,
    output logic [13:0] pool5_read_request_flat_index,
    output logic [15:0] pool5_read_request_tag,
    input  logic pool5_read_response_valid,
    output logic pool5_read_response_ready,
    input  logic signed [7:0] pool5_read_response_value,
    input  logic pool5_read_response_error,

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

    output logic flatten_active,
    output logic flatten_done,
    output logic fault,
    output logic [3:0] completed_chunks,
    output logic [13:0] completed_scalars,
    output logic [10:0] completed_words
);
  logic intercept;
  logic request_fields_valid;
  logic flatten_active_q;
  logic fault_q;
  logic flatten_start_valid, flatten_start_ready;
  logic flatten_word_valid, flatten_word_ready, flatten_word_last;
  logic [63:0] flatten_word_values;
  logic [7:0] flatten_word_lane_mask;
  logic [13:0] flatten_word_k_base;
  logic [15:0] flatten_word_tag;
  logic reader_busy, reader_done, reader_fault;
  logic [13:0] reader_scalars_completed;
  logic [9:0] reader_words_completed;
  logic packer_busy, packer_fault;
  logic [127:0] flatten_axis_tdata;
  logic [15:0] flatten_axis_tkeep;
  logic flatten_axis_tvalid, flatten_axis_tready, flatten_axis_tlast;
  logic flatten_axis_fire;
  logic request_fire;

  assign intercept = active_layer_id == 6 && request_destination == 0;
  assign request_fields_valid = request_word_count == (active_k_count >> 3) &&
      request_byte_count == {6'b0, request_word_count, 3'b000} &&
      request_m_count == 1 && active_k_count != 0 &&
      active_k_count[2:0] == 0 && active_k_offset[2:0] == 0 &&
      active_k_offset + active_k_count <= 14'd9216;
  assign flatten_start_valid = request_valid && intercept &&
                               request_fields_valid && !flatten_active_q;
  assign request_ready = intercept ?
      (flatten_start_ready && !flatten_active_q) : external_request_ready;
  assign request_fire = request_valid && request_ready;

  assign external_request_valid = request_valid && !intercept;
  assign external_request_layer_id = active_layer_id;
  assign external_request_k_offset = active_k_offset;
  assign external_request_k_count = active_k_count;
  assign external_request_destination = request_destination;
  assign external_request_word_count = request_word_count;
  assign external_request_byte_count = request_byte_count;
  assign external_request_m_count = request_m_count;
  assign external_request_tag = request_tag;

  assign compute_axis_tdata = flatten_active_q ? flatten_axis_tdata :
                                                   external_axis_tdata;
  assign compute_axis_tkeep = flatten_active_q ? flatten_axis_tkeep :
                                                   external_axis_tkeep;
  assign compute_axis_tvalid = flatten_active_q ? flatten_axis_tvalid :
                                                    external_axis_tvalid;
  assign compute_axis_tlast = flatten_active_q ? flatten_axis_tlast :
                                                  external_axis_tlast;
  assign flatten_axis_tready = flatten_active_q && compute_axis_tready;
  assign external_axis_tready = !flatten_active_q && compute_axis_tready;
  assign flatten_axis_fire = flatten_axis_tvalid && flatten_axis_tready;
  assign flatten_active = flatten_active_q;
  assign fault = fault_q || reader_fault || packer_fault;

  alexnet_pool5_fc6_flatten_reader u_reader (
      .clk(clk), .rst(rst),
      .start_valid(flatten_start_valid), .start_ready(flatten_start_ready),
      .start_k_offset(active_k_offset), .start_k_count(active_k_count),
      .start_tag(request_tag),
      .read_request_valid(pool5_read_request_valid),
      .read_request_ready(pool5_read_request_ready),
      .read_request_word_address(pool5_read_request_word_address),
      .read_request_lane(pool5_read_request_lane),
      .read_request_flat_index(pool5_read_request_flat_index),
      .read_request_tag(pool5_read_request_tag),
      .read_response_valid(pool5_read_response_valid),
      .read_response_ready(pool5_read_response_ready),
      .read_response_value(pool5_read_response_value),
      .read_response_error(pool5_read_response_error),
      .m_valid(flatten_word_valid), .m_ready(flatten_word_ready),
      .m_values(flatten_word_values),
      .m_lane_mask(flatten_word_lane_mask),
      .m_k_base(flatten_word_k_base), .m_tag(flatten_word_tag),
      .m_last(flatten_word_last), .busy(reader_busy), .done(reader_done),
      .fault(reader_fault),
      .scalars_completed(reader_scalars_completed),
      .words_completed(reader_words_completed)
  );

  alexnet_n8_to_axis128_packer u_packer (
      .clk(clk), .rst(rst), .clear_error(request_fire && intercept),
      .s_valid(flatten_word_valid), .s_ready(flatten_word_ready),
      .s_values(flatten_word_values),
      .s_byte_keep(flatten_word_lane_mask), .s_last(flatten_word_last),
      .m_axis_tdata(flatten_axis_tdata),
      .m_axis_tkeep(flatten_axis_tkeep),
      .m_axis_tvalid(flatten_axis_tvalid),
      .m_axis_tready(flatten_axis_tready),
      .m_axis_tlast(flatten_axis_tlast), .busy(packer_busy),
      .protocol_error(packer_fault)
  );

  always_ff @(posedge clk) begin
    if (rst) begin
      flatten_active_q <= 1'b0;
      flatten_done <= 1'b0;
      fault_q <= 1'b0;
      completed_chunks <= 0;
      completed_scalars <= 0;
      completed_words <= 0;
    end else begin
      flatten_done <= 1'b0;
      if (request_fire && intercept) begin
        flatten_active_q <= request_fields_valid;
        fault_q <= !request_fields_valid;
      end
      if (flatten_axis_fire && flatten_axis_tlast) begin
        flatten_active_q <= 1'b0;
        flatten_done <= 1'b1;
        completed_chunks <= completed_chunks + 1'b1;
        completed_scalars <= completed_scalars + reader_scalars_completed;
        completed_words <= completed_words + reader_words_completed;
      end
      if (pool5_read_response_error)
        fault_q <= 1'b1;
    end
  end

`ifndef SYNTHESIS
  always_ff @(posedge clk) begin
    if (!rst) begin
      if (request_fire && intercept && !request_fields_valid)
        $warning("FC6 flatten injector rejected malformed activation request");
      if (flatten_axis_fire && flatten_axis_tlast &&
          (reader_scalars_completed != active_k_count ||
           reader_words_completed != request_word_count))
        $fatal(1, "FC6 flatten chunk retired with incomplete counts");
    end
  end
`endif
endmodule
