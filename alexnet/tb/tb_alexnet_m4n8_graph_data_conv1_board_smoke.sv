`timescale 1ns/1ps

// Board-derived Conv1 smoke test.  It advances the complete graph/data top
// through ownership, layer storage arming, parameter load, the 363-word
// weight transfer, and result-egress arming.  Camera data is intentionally
// held off so any fault before the first pixel is a control/data-plane bug.
module tb_alexnet_m4n8_graph_data_conv1_board_smoke;
  logic clk = 1'b0;
  always #2.5 clk = ~clk;

  logic rst = 1'b1;
  logic start_valid = 1'b0;
  logic start_ready;

  logic [127:0] external_mm2s_axis_tdata = '0;
  logic [15:0] external_mm2s_axis_tkeep = '0;
  logic external_mm2s_axis_tvalid = 1'b0;
  logic external_mm2s_axis_tready;
  logic external_mm2s_axis_tlast = 1'b0;

  logic rs_mm2s_request_valid;
  logic [1:0] rs_mm2s_request_destination;
  logic [10:0] rs_mm2s_request_word_count;
  logic [15:0] rs_mm2s_request_byte_count;
  logic [15:0] rs_mm2s_request_tag;
  logic [15:0] rs_mm2s_request_n_base;
  logic [7:0] rs_mm2s_request_chunk_index;
  logic rs_s2mm_request_valid;
  logic [12:0] rs_s2mm_request_word_count;
  logic [15:0] rs_s2mm_request_byte_count;
  logic rs_activation_stream_valid = 1'b0;
  logic rs_activation_stream_ready;
  logic [63:0] rs_activation_stream_values = '0;
  logic rs_activation_stream_last = 1'b0;

  logic conv_parameter_request_valid;
  logic [2:0] conv_parameter_request_layer_id;
  logic [15:0] conv_parameter_request_job_tag;
  logic [15:0] conv_parameter_request_n_base;
  logic conv_parameter_valid = 1'b0;
  logic conv_parameter_ready;
  logic [2:0] conv_parameter_layer_id = '0;
  logic [15:0] conv_parameter_job_tag = '0;
  logic [15:0] conv_parameter_n_base = '0;
  logic signed [31:0] conv_parameter_bias [0:7];
  logic signed [17:0] conv_parameter_multiplier [0:7];
  logic [5:0] conv_parameter_right_shift [0:7];

  logic signed [31:0] fc_parameter_bias [0:7];
  logic signed [17:0] fc_parameter_multiplier [0:7];
  logic [5:0] fc_parameter_right_shift [0:7];

  logic conv_write_request_valid;
  logic [2:0] conv_write_request_layer_id;
  logic [15:0] conv_write_request_tag;
  logic [12:0] conv_write_request_word_count;
  logic [15:0] conv_write_request_byte_count;

  logic busy, inference_done, inference_failed, fault;
  logic [3:0] fault_code, active_layer_id;
  logic [4:0] graph_phase;
  logic compute_fault, data_service_fault;
  integer sent_pixels = 0;

  alexnet_m4n8_graph_data_top #(
      .EXTERNAL_CONV_STORAGE_COMPLETION(1'b1)
  ) dut (
      .clk(clk), .rst(rst), .ce(1'b1),
      .start_valid(start_valid), .start_ready(start_ready),
      .start_tag(16'h0001),
      .external_mm2s_axis_tdata(external_mm2s_axis_tdata),
      .external_mm2s_axis_tkeep(external_mm2s_axis_tkeep),
      .external_mm2s_axis_tvalid(external_mm2s_axis_tvalid),
      .external_mm2s_axis_tready(external_mm2s_axis_tready),
      .external_mm2s_axis_tlast(external_mm2s_axis_tlast),
      .storage_axis_tready(1'b1),
      .rs_mm2s_request_valid(rs_mm2s_request_valid),
      .rs_mm2s_request_ready(1'b1),
      .rs_mm2s_request_destination(rs_mm2s_request_destination),
      .rs_mm2s_request_word_count(rs_mm2s_request_word_count),
      .rs_mm2s_request_byte_count(rs_mm2s_request_byte_count),
      .rs_mm2s_request_tag(rs_mm2s_request_tag),
      .rs_mm2s_request_n_base(rs_mm2s_request_n_base),
      .rs_mm2s_request_chunk_index(rs_mm2s_request_chunk_index),
      .rs_s2mm_request_valid(rs_s2mm_request_valid),
      .rs_s2mm_request_ready(1'b1),
      .rs_s2mm_request_word_count(rs_s2mm_request_word_count),
      .rs_s2mm_request_byte_count(rs_s2mm_request_byte_count),
      .rs_activation_stream_valid(rs_activation_stream_valid),
      .rs_activation_stream_ready(rs_activation_stream_ready),
      .rs_activation_stream_values(rs_activation_stream_values),
      .rs_activation_stream_lane_mask(8'h07),
      .rs_activation_stream_last(rs_activation_stream_last),
      .conv_parameter_request_valid(conv_parameter_request_valid),
      .conv_parameter_request_ready(1'b1),
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
      .fc_parameter_valid(1'b0),
      .fc_parameter_layer_id('0), .fc_parameter_job_tag('0),
      .fc_parameter_n_base('0), .fc_parameter_bias(fc_parameter_bias),
      .fc_parameter_multiplier(fc_parameter_multiplier),
      .fc_parameter_right_shift(fc_parameter_right_shift),
      .conv_write_request_valid(conv_write_request_valid),
      .conv_write_request_ready(1'b1),
      .conv_write_request_layer_id(conv_write_request_layer_id),
      .conv_write_request_tag(conv_write_request_tag),
      .conv_write_request_word_count(conv_write_request_word_count),
      .conv_write_request_byte_count(conv_write_request_byte_count),
      .conv_write_complete_valid(1'b0),
      .conv_write_complete_layer_id('0), .conv_write_complete_tag('0),
      .conv_write_complete_error(1'b0),
      .fc_external_request_ready(1'b1),
      .fc_result_request_ready(1'b1),
      .fc_result_complete_valid(1'b0),
      .fc_result_complete_n_base('0), .fc_result_complete_tag('0),
      .fc_result_complete_error(1'b0), .fc_backend_error(1'b0),
      .busy(busy), .inference_done(inference_done),
      .inference_failed(inference_failed), .fault(fault),
      .fault_code(fault_code), .graph_phase(graph_phase),
      .active_layer_id(active_layer_id),
      .compute_fault(compute_fault), .data_service_fault(data_service_fault)
  );

  task automatic send_weight_words(input int word_count);
    int word_index;
    int words_this_beat;
    begin
      word_index = 0;
      while (word_index < word_count) begin
        while (!external_mm2s_axis_tready)
          @(negedge clk);
        words_this_beat = word_count - word_index >= 2 ? 2 : 1;
        external_mm2s_axis_tdata = {
            64'h0101_0101_0101_0101, 64'h0101_0101_0101_0101};
        external_mm2s_axis_tkeep = words_this_beat == 2 ?
                                   16'hffff : 16'h00ff;
        external_mm2s_axis_tlast =
            word_index + words_this_beat == word_count;
        external_mm2s_axis_tvalid = 1'b1;
        @(posedge clk);
        @(negedge clk);
        external_mm2s_axis_tvalid = 1'b0;
        external_mm2s_axis_tlast = 1'b0;
        word_index += words_this_beat;
      end
    end
  endtask

  initial begin
    for (int lane = 0; lane < 8; lane++) begin
      conv_parameter_bias[lane] = 0;
      conv_parameter_multiplier[lane] = 18'sd65540;
      conv_parameter_right_shift[lane] = 6'd24;
      fc_parameter_bias[lane] = 0;
      fc_parameter_multiplier[lane] = 18'sd65540;
      fc_parameter_right_shift[lane] = 6'd24;
    end

    repeat (5) @(negedge clk);
    rst = 1'b0;
    while (!start_ready) @(negedge clk);
    start_valid = 1'b1;
    @(posedge clk);
    @(negedge clk);
    start_valid = 1'b0;

    while (!conv_write_request_valid) @(negedge clk);
    if (conv_write_request_layer_id != 1 ||
        conv_write_request_word_count != 5832 ||
        conv_write_request_byte_count != 46656)
      $fatal(1, "Conv1 storage descriptor mismatch");

    while (!conv_parameter_request_valid) @(negedge clk);
    conv_parameter_layer_id = conv_parameter_request_layer_id;
    conv_parameter_job_tag = conv_parameter_request_job_tag;
    conv_parameter_n_base = conv_parameter_request_n_base;
    conv_parameter_valid = 1'b1;
    while (!conv_parameter_ready) @(negedge clk);
    @(posedge clk);
    @(negedge clk);
    conv_parameter_valid = 1'b0;

    while (!rs_mm2s_request_valid) @(negedge clk);
    if (rs_mm2s_request_destination != 2 ||
        rs_mm2s_request_word_count != 363 ||
        rs_mm2s_request_byte_count != 2904)
      $fatal(1, "Conv1 weight descriptor mismatch");
    @(posedge clk);
    @(negedge clk);
    send_weight_words(363);

    for (int pixel = 0; pixel < 50176; pixel++) begin
      while (!rs_activation_stream_ready && !fault) @(negedge clk);
      if (fault)
        break;
      rs_activation_stream_values = 64'h0000_0000_0003_0201;
      rs_activation_stream_last = pixel == 50175;
      rs_activation_stream_valid = 1'b1;
      @(posedge clk);
      @(negedge clk);
      rs_activation_stream_valid = 1'b0;
      rs_activation_stream_last = 1'b0;
      sent_pixels = pixel + 1;
    end
    repeat (100) @(negedge clk);
    $display("BOARD_SMOKE graph_phase=%0d layer=%0d fault=%0b/%0d compute=%0b data=%0b rs_phase=%0d rs_fault=%0b/%0d datapath_error=%0b dma_error=%0b result_error=%0b chunk_rejected=%0b weight_state=%0d weight_valid=%0b result_active=%0b",
        graph_phase, active_layer_id, fault, fault_code, compute_fault,
        data_service_fault, dut.u_graph.u_compute.rs_scheduler_phase,
        dut.u_graph.u_compute.rs_scheduler_fault,
        dut.u_graph.u_compute.rs_scheduler_fault_code,
        dut.u_graph.u_compute.rs_datapath_protocol_error,
        dut.u_graph.u_compute.rs_dma_protocol_error,
        dut.u_graph.u_compute.rs_result_dma_protocol_error,
        dut.u_graph.u_compute.rs_chunk_rejected,
        dut.u_graph.u_compute.rs_weight_bank_state,
        dut.u_graph.u_compute.rs_weight_resident_valid,
        dut.u_graph.u_compute.rs_result_dma_transfer_active);
    if (fault || inference_failed)
      $fatal(1, "Conv1 faulted before its first camera word");
    if (!rs_s2mm_request_valid &&
        !dut.u_graph.u_compute.rs_result_dma_transfer_active)
      $fatal(1, "Conv1 result egress was not armed");
    $display("ALEXNET_GRAPH_DATA_CONV1_BOARD_SMOKE_PASS");
    $finish;
  end

  initial begin
    #2000000;
    $display("BOARD_SMOKE_WATCHDOG pixels=%0d graph=%0d fault=%0b/%0d compute=%0b data=%0b rs_phase=%0d rs_fault=%0b/%0d chunk_frame=%0b compute_busy=%0b transaction=%0b accum=%0b ready=%0b queue=%0d feeder_state=%0d",
        sent_pixels, graph_phase, fault, fault_code, compute_fault,
        data_service_fault, dut.u_graph.u_compute.rs_scheduler_phase,
        dut.u_graph.u_compute.rs_scheduler_fault,
        dut.u_graph.u_compute.rs_scheduler_fault_code,
        dut.u_graph.u_compute.rs_chunk_frame_active,
        dut.u_graph.u_compute.rs_compute_busy,
        dut.u_graph.u_compute.rs_transaction_active,
        dut.u_graph.u_compute.rs_accum_chunk_active,
        rs_activation_stream_ready, dut.u_graph.u_compute.rs_queued_count,
        dut.u_graph.u_compute.u_rs.u_datapath.u_dma_fed_datapath.u_datapath.u_core.u_feeder.state_q);
    $fatal(1, "Conv1 board smoke watchdog expired");
  end
endmodule
