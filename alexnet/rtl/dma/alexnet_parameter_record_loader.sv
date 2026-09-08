`timescale 1ns/1ps

// Convert one 128-byte DDR parameter tile into eight lane-local requantization
// records. The frozen software format is one little-endian 16-byte record per
// output channel:
//   byte  0..3  signed INT32 bias
//   byte  4..7  signed INT32 multiplier (must fit the RTL's positive INT18)
//   byte     8  right shift
//   byte     9  ReLU enable
//   byte 10..15 zero padding
// One AXI4-Stream beat therefore carries exactly one output-channel record.
module alexnet_parameter_record_loader (
    input logic clk,
    input logic rst,

    input  logic start_valid,
    output logic start_ready,
    input  logic start_is_fc,
    input  logic [3:0] start_layer_id,
    input  logic [15:0] start_job_tag,
    input  logic [15:0] start_n_base,

    input  logic [127:0] s_axis_tdata,
    input  logic [15:0] s_axis_tkeep,
    input  logic s_axis_tvalid,
    output logic s_axis_tready,
    input  logic s_axis_tlast,

    output logic parameter_valid,
    input  logic parameter_ready,
    output logic parameter_is_fc,
    output logic [3:0] parameter_layer_id,
    output logic [15:0] parameter_job_tag,
    output logic [15:0] parameter_n_base,
    output logic signed [31:0] parameter_bias [0:7],
    output logic signed [17:0] parameter_multiplier [0:7],
    output logic [5:0] parameter_right_shift [0:7],

    output logic busy,
    output logic fault,
    output logic [2:0] active_lane,
    output logic [31:0] accepted_tiles,
    output logic [31:0] completed_tiles,
    output logic [31:0] rejected_tiles
);
  logic loading_q;
  logic response_valid_q;
  logic record_error_q;
  logic fault_q;
  logic is_fc_q;
  logic [3:0] layer_id_q;
  logic [15:0] job_tag_q, n_base_q;
  logic [2:0] lane_q;
  logic start_fire, axis_fire, response_fire;
  logic start_fields_valid;
  logic beat_fields_valid;
  logic expected_relu;
  integer lane;

  assign start_ready = !loading_q && !response_valid_q && !fault_q;
  assign start_fire = start_valid && start_ready;
  assign s_axis_tready = loading_q;
  assign axis_fire = s_axis_tvalid && s_axis_tready;
  assign parameter_valid = response_valid_q;
  assign response_fire = parameter_valid && parameter_ready;
  assign parameter_is_fc = is_fc_q;
  assign parameter_layer_id = layer_id_q;
  assign parameter_job_tag = job_tag_q;
  assign parameter_n_base = n_base_q;
  assign busy = loading_q || response_valid_q;
  assign fault = fault_q;
  assign active_lane = lane_q;

  assign start_fields_valid =
      (!start_is_fc && start_layer_id >= 1 && start_layer_id <= 5) ||
      (start_is_fc && start_layer_id >= 6 && start_layer_id <= 8);
  assign expected_relu = layer_id_q != 8;
  assign beat_fields_valid = s_axis_tkeep == 16'hffff &&
      s_axis_tlast == (lane_q == 7) && s_axis_tdata[127:80] == 0 &&
      s_axis_tdata[63:50] == 0 && s_axis_tdata[71:70] == 0 &&
      s_axis_tdata[79:72] == {7'b0, expected_relu};

  always_ff @(posedge clk) begin
    if (rst) begin
      loading_q <= 1'b0;
      response_valid_q <= 1'b0;
      record_error_q <= 1'b0;
      fault_q <= 1'b0;
      is_fc_q <= 1'b0;
      layer_id_q <= 0;
      job_tag_q <= 0;
      n_base_q <= 0;
      lane_q <= 0;
      accepted_tiles <= 0;
      completed_tiles <= 0;
      rejected_tiles <= 0;
      for (lane = 0; lane < 8; lane = lane + 1) begin
        parameter_bias[lane] <= 0;
        parameter_multiplier[lane] <= 0;
        parameter_right_shift[lane] <= 0;
      end
    end else begin
      if (response_fire) begin
        response_valid_q <= 1'b0;
        completed_tiles <= completed_tiles + 1'b1;
      end

      if (start_fire) begin
        if (start_fields_valid) begin
          loading_q <= 1'b1;
          record_error_q <= 1'b0;
          is_fc_q <= start_is_fc;
          layer_id_q <= start_layer_id;
          job_tag_q <= start_job_tag;
          n_base_q <= start_n_base;
          lane_q <= 0;
          accepted_tiles <= accepted_tiles + 1'b1;
        end else begin
          fault_q <= 1'b1;
          rejected_tiles <= rejected_tiles + 1'b1;
        end
      end

      if (axis_fire) begin
        parameter_bias[lane_q] <= $signed(s_axis_tdata[31:0]);
        parameter_multiplier[lane_q] <= $signed(s_axis_tdata[49:32]);
        parameter_right_shift[lane_q] <= s_axis_tdata[69:64];

        if (!beat_fields_valid)
          record_error_q <= 1'b1;

        // Early TLAST terminates a malformed physical transfer immediately;
        // lane 7 always terminates because the programmed DMA length is fixed.
        if (s_axis_tlast || lane_q == 7) begin
          loading_q <= 1'b0;
          if (lane_q == 7 && beat_fields_valid && !record_error_q) begin
            response_valid_q <= 1'b1;
          end else begin
            fault_q <= 1'b1;
            rejected_tiles <= rejected_tiles + 1'b1;
          end
        end else begin
          lane_q <= lane_q + 1'b1;
        end
      end
    end
  end

`ifndef SYNTHESIS
  always_ff @(posedge clk) begin
    if (!rst) begin
      if (s_axis_tvalid && !loading_q)
        $warning("parameter loader received data without an active tile");
      if (response_valid_q && loading_q)
        $fatal(1, "parameter loader exposed a response while still loading");
    end
  end
`endif
endmodule
