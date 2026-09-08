`timescale 1ns/1ps

// Full Conv1 geometry proof for the resource-saving activation bypass.
// A 224x224x3 N8 raster is consumed by the RS feeder without first being
// copied into the 1,024-word activation ping-pong. The one shared M4xN8
// compute slice retains the complete 55x55 result in a 4,096-word bank.
module tb_alexnet_m4n8_rs_conv1_streaming_datapath;
  localparam int INPUT_H = 224;
  localparam int INPUT_W = 224;
  localparam int INPUT_WORDS = INPUT_H * INPUT_W;
  localparam int CHANNELS = 3;
  localparam int KERNEL = 11;
  localparam int K_COUNT = CHANNELS * KERNEL * KERNEL;
  localparam int OUTPUT_H = 55;
  localparam int OUTPUT_W = 55;
  localparam int OUTPUT_WORDS = OUTPUT_H * OUTPUT_W;

  logic clk = 1'b0;
  always #2.5 clk = ~clk;
  logic rst = 1'b1;
  logic ce = 1'b1;

  logic cfg_valid, cfg_ready;
  logic signed [31:0] cfg_bias [0:7];
  logic signed [17:0] cfg_multiplier [0:7];
  logic [5:0] cfg_right_shift [0:7];
  logic weight_fill_valid, weight_fill_ready;
  logic weight_write_valid, weight_write_ready, weight_write_last;
  logic chunk_valid, chunk_ready;
  logic activation_stream_valid, activation_stream_ready;
  logic activation_stream_last;
  logic egress_valid, egress_ready;
  logic [63:0] egress_values;
  logic [7:0] egress_lane_mask;
  logic [1:0] egress_destination;
  logic [2:0] egress_slice;
  logic [4:0] egress_m;
  logic [15:0] egress_n_base, egress_tile_tag;
  logic configured, chunk_frame_active, chunk_done;
  logic transaction_active, transaction_done, pipeline_idle;
  logic protocol_error, activation_context_error, accum_context_error;
  logic weight_context_error;
  logic [15:0] activation_stream_words_forwarded;

  logic shared_cfg_valid, shared_cfg_ready;
  logic [1:0] shared_cfg_destination;
  logic [15:0] shared_cfg_n64_tile_base;
  logic [2:0] shared_cfg_slice_index;
  logic [7:0] shared_cfg_lane_mask;
  logic signed [31:0] shared_cfg_bias [0:7];
  logic signed [17:0] shared_cfg_multiplier [0:7];
  logic [5:0] shared_cfg_right_shift [0:7];
  logic [7:0] shared_cfg_relu;
  logic shared_chunk_valid, shared_chunk_ready;
  logic [12:0] shared_chunk_word_count;
  logic [7:0] shared_chunk_output_width, shared_chunk_n_lane_mask;
  logic [15:0] shared_chunk_context_tag, shared_chunk_tile_tag_base;
  logic [7:0] shared_chunk_index;
  logic shared_chunk_first, shared_chunk_final;
  logic shared_tile_start_valid, shared_tile_start_ready;
  logic [2:0] shared_tile_m_count;
  logic [7:0] shared_tile_n_lane_mask;
  logic [15:0] shared_tile_tag;
  logic shared_issue_valid, shared_issue_ready, shared_issue_last;
  logic signed [7:0] shared_issue_act_lo [0:1];
  logic signed [7:0] shared_issue_act_hi [0:1];
  logic signed [7:0] shared_issue_weight [0:7];
  logic shared_egress_valid, shared_egress_ready;
  logic [63:0] shared_egress_values;
  logic [7:0] shared_egress_lane_mask;
  logic [1:0] shared_egress_destination;
  logic [2:0] shared_egress_slice;
  logic [4:0] shared_egress_m;
  logic [15:0] shared_egress_n_base, shared_egress_tile_tag;
  logic shared_configured, shared_compute_busy;
  logic shared_transaction_active, shared_chunk_active;
  logic shared_tile_done, shared_chunk_done, shared_transaction_done;
  logic shared_datapath_idle;
  logic [2:0] shared_accum_bank_state;
  logic shared_accum_context_error, shared_protocol_error;
  logic [6:0] shared_queued_count;

  int output_words;
  int stream_handshakes;
  int chunk_done_pulses;
  int transaction_done_pulses;
  int cycles;

  alexnet_m4n8_rs_activation_resident_weight_dual_accum_datapath #(
      .EXTERNAL_COMPUTE(1'b1),
      .BANK_COUNT_W(13)
  ) dut (
      .clk(clk), .rst(rst), .ce(ce),
      .cfg_valid(cfg_valid), .cfg_ready(cfg_ready),
      .cfg_destination(2'd0), .cfg_n64_tile_base(16'd0),
      .cfg_slice_index(3'd0), .cfg_lane_mask(8'hff),
      .cfg_bias(cfg_bias), .cfg_multiplier(cfg_multiplier),
      .cfg_right_shift(cfg_right_shift), .cfg_relu(8'hff),
      .activation_fill_valid(1'b0), .activation_fill_ready(),
      .activation_fill_is_pooled(1'b0),
      .activation_fill_word_count('0), .activation_fill_lane_mask('0),
      .activation_fill_tensor_tag('0), .activation_direct_valid(1'b0),
      .activation_direct_ready(),
      .activation_direct_values('0), .activation_direct_lane_mask('0),
      .activation_direct_last(1'b0), .activation_pooled_valid(1'b0),
      .activation_pooled_ready(),
      .activation_pooled_values('0), .activation_pooled_lane_mask('0),
      .activation_pooled_last(1'b0),
      .activation_stream_valid(activation_stream_valid),
      .activation_stream_ready(activation_stream_ready),
      .activation_stream_values(64'h0000_0000_0001_0101),
      .activation_stream_lane_mask(8'h07),
      .activation_stream_last(activation_stream_last),
      .weight_fill_valid(weight_fill_valid),
      .weight_fill_ready(weight_fill_ready),
      .weight_fill_k_count(10'(K_COUNT)),
      .weight_fill_n_lane_mask(8'hff),
      .weight_fill_context_tag(16'h1100),
      .weight_write_valid(weight_write_valid),
      .weight_write_ready(weight_write_ready),
      .weight_write_values(64'h0101_0101_0101_0101),
      .weight_write_n_lane_mask(8'hff),
      .weight_write_last(weight_write_last),
      .weight_release_valid(1'b0), .weight_release_ready(),
      .chunk_valid(chunk_valid), .chunk_ready(chunk_ready),
      .chunk_activation_streaming(1'b1),
      .chunk_activation_tensor_tag(16'h2200),
      .chunk_input_h(8'(INPUT_H)), .chunk_input_w(8'(INPUT_W)),
      .chunk_channel_count(4'(CHANNELS)),
      .chunk_input_lane_mask(8'h07), .chunk_kernel(4'(KERNEL)),
      .chunk_stride(3'd4), .chunk_padding(3'd2),
      .chunk_k_count(10'(K_COUNT)),
      .chunk_weight_context_tag(16'h1100),
      .chunk_word_count(13'(OUTPUT_WORDS)),
      .chunk_output_width(8'(OUTPUT_W)),
      .chunk_accum_context_tag(16'h3300),
      .chunk_tile_tag_base(16'h4000), .chunk_index(8'd0),
      .chunk_first(1'b1), .chunk_final(1'b1),
      .egress_valid(egress_valid), .egress_ready(egress_ready),
      .egress_values(egress_values), .egress_lane_mask(egress_lane_mask),
      .egress_destination(egress_destination), .egress_slice(egress_slice),
      .egress_m(egress_m), .egress_n_base(egress_n_base),
      .egress_tile_tag(egress_tile_tag), .configured(configured),
      .chunk_frame_active(chunk_frame_active), .chunk_done(chunk_done),
      .compute_busy(), .transaction_active(transaction_active),
      .accum_chunk_active(), .transaction_done(transaction_done),
      .pipeline_idle(pipeline_idle), .protocol_error(protocol_error),
      .activation_context_error(activation_context_error),
      .accum_context_error(accum_context_error),
      .weight_context_error(weight_context_error),
      .completed_tile_count(), .completed_weight_replays(),
      .weight_bank_state(), .weight_resident_valid(),
      .resident_weight_k_count(), .resident_weight_words_written(),
      .resident_weight_n_lane_mask(), .resident_weight_context_tag(),
      .weight_replay_done(), .accum_bank_state(), .queued_count(),
      .activation_ready_tensor_valid(), .activation_ready_tensor_bank(),
      .activation_ready_tensor_tag(), .activation_ready_count(),
      .activation_fill_active(), .activation_fill_bank(),
      .activation_read_active(), .activation_read_bank(),
      .activation_read_segment(), .activation_read_done(),
      .activation_words_forwarded(),
      .activation_stream_words_forwarded(
          activation_stream_words_forwarded),
      .shared_cfg_valid(shared_cfg_valid),
      .shared_cfg_ready(shared_cfg_ready),
      .shared_cfg_destination(shared_cfg_destination),
      .shared_cfg_n64_tile_base(shared_cfg_n64_tile_base),
      .shared_cfg_slice_index(shared_cfg_slice_index),
      .shared_cfg_lane_mask(shared_cfg_lane_mask),
      .shared_cfg_bias(shared_cfg_bias),
      .shared_cfg_multiplier(shared_cfg_multiplier),
      .shared_cfg_right_shift(shared_cfg_right_shift),
      .shared_cfg_relu(shared_cfg_relu),
      .shared_chunk_valid(shared_chunk_valid),
      .shared_chunk_ready(shared_chunk_ready),
      .shared_chunk_word_count(shared_chunk_word_count),
      .shared_chunk_output_width(shared_chunk_output_width),
      .shared_chunk_n_lane_mask(shared_chunk_n_lane_mask),
      .shared_chunk_context_tag(shared_chunk_context_tag),
      .shared_chunk_tile_tag_base(shared_chunk_tile_tag_base),
      .shared_chunk_index(shared_chunk_index),
      .shared_chunk_first(shared_chunk_first),
      .shared_chunk_final(shared_chunk_final),
      .shared_tile_start_valid(shared_tile_start_valid),
      .shared_tile_start_ready(shared_tile_start_ready),
      .shared_tile_m_count(shared_tile_m_count),
      .shared_tile_n_lane_mask(shared_tile_n_lane_mask),
      .shared_tile_tag(shared_tile_tag),
      .shared_issue_valid(shared_issue_valid),
      .shared_issue_ready(shared_issue_ready),
      .shared_issue_last(shared_issue_last),
      .shared_issue_act_lo(shared_issue_act_lo),
      .shared_issue_act_hi(shared_issue_act_hi),
      .shared_issue_weight(shared_issue_weight),
      .shared_egress_valid(shared_egress_valid),
      .shared_egress_ready(shared_egress_ready),
      .shared_egress_values(shared_egress_values),
      .shared_egress_lane_mask(shared_egress_lane_mask),
      .shared_egress_destination(shared_egress_destination),
      .shared_egress_slice(shared_egress_slice),
      .shared_egress_m(shared_egress_m),
      .shared_egress_n_base(shared_egress_n_base),
      .shared_egress_tile_tag(shared_egress_tile_tag),
      .shared_configured(shared_configured),
      .shared_compute_busy(shared_compute_busy),
      .shared_transaction_active(shared_transaction_active),
      .shared_chunk_active(shared_chunk_active),
      .shared_tile_done(shared_tile_done),
      .shared_chunk_done(shared_chunk_done),
      .shared_transaction_done(shared_transaction_done),
      .shared_datapath_idle(shared_datapath_idle),
      .shared_accum_bank_state(shared_accum_bank_state),
      .shared_accum_context_error(shared_accum_context_error),
      .shared_protocol_error(shared_protocol_error),
      .shared_queued_count(shared_queued_count)
  );

  alexnet_m4n8_accum_base_datapath #(
      .BANK_DEPTH(4096), .RUNTIME_SLICE_INDEX(1'b1)
  ) u_shared (
      .clk(clk), .rst(rst), .ce(ce),
      .cfg_valid(shared_cfg_valid), .cfg_ready(shared_cfg_ready),
      .cfg_destination(shared_cfg_destination),
      .cfg_n64_tile_base(shared_cfg_n64_tile_base),
      .cfg_slice_index(shared_cfg_slice_index),
      .cfg_lane_mask(shared_cfg_lane_mask), .cfg_bias(shared_cfg_bias),
      .cfg_multiplier(shared_cfg_multiplier),
      .cfg_right_shift(shared_cfg_right_shift), .cfg_relu(shared_cfg_relu),
      .chunk_valid(shared_chunk_valid), .chunk_ready(shared_chunk_ready),
      .chunk_word_count(shared_chunk_word_count),
      .chunk_output_width(shared_chunk_output_width),
      .chunk_n_lane_mask(shared_chunk_n_lane_mask),
      .chunk_context_tag(shared_chunk_context_tag),
      .chunk_tile_tag_base(shared_chunk_tile_tag_base),
      .chunk_index(shared_chunk_index), .chunk_first(shared_chunk_first),
      .chunk_final(shared_chunk_final),
      .tile_start_valid(shared_tile_start_valid),
      .tile_start_ready(shared_tile_start_ready),
      .tile_m_count(shared_tile_m_count),
      .tile_n_lane_mask(shared_tile_n_lane_mask),
      .tile_tag(shared_tile_tag), .issue_valid(shared_issue_valid),
      .issue_ready(shared_issue_ready), .issue_last(shared_issue_last),
      .issue_act_lo(shared_issue_act_lo), .issue_act_hi(shared_issue_act_hi),
      .issue_weight(shared_issue_weight),
      .egress_valid(shared_egress_valid),
      .egress_ready(shared_egress_ready),
      .egress_values(shared_egress_values),
      .egress_lane_mask(shared_egress_lane_mask),
      .egress_destination(shared_egress_destination),
      .egress_slice(shared_egress_slice), .egress_m(shared_egress_m),
      .egress_n_base(shared_egress_n_base),
      .egress_tile_tag(shared_egress_tile_tag),
      .configured(shared_configured), .compute_busy(shared_compute_busy),
      .transaction_active(shared_transaction_active),
      .chunk_active(shared_chunk_active), .tile_done(shared_tile_done),
      .chunk_done(shared_chunk_done),
      .transaction_done(shared_transaction_done),
      .datapath_idle(shared_datapath_idle),
      .accum_bank_state(shared_accum_bank_state),
      .accum_context_error(shared_accum_context_error),
      .protocol_error(shared_protocol_error),
      .queued_count(shared_queued_count)
  );

  always @(posedge clk) begin
    if (rst) begin
      output_words <= 0;
      stream_handshakes <= 0;
      chunk_done_pulses <= 0;
      transaction_done_pulses <= 0;
      cycles <= 0;
    end else begin
      cycles <= cycles + 1;
      if (cycles > 1500000)
        $fatal(1, "Conv1 streaming watchdog expired outputs=%0d input=%0d",
               output_words, stream_handshakes);
      if (activation_stream_valid && activation_stream_ready)
        stream_handshakes <= stream_handshakes + 1;
      if (chunk_done)
        chunk_done_pulses <= chunk_done_pulses + 1;
      if (transaction_done)
        transaction_done_pulses <= transaction_done_pulses + 1;
      if (egress_valid && egress_ready) begin
        if (egress_values != 64'h0101_0101_0101_0101 ||
            egress_lane_mask != 8'hff || egress_destination != 0 ||
            egress_slice != 0 || egress_n_base != 0 ||
            egress_m != (output_words % OUTPUT_W) % 4 ||
            egress_tile_tag != 16'(16'h4000 +
                (output_words / OUTPUT_W) * ((OUTPUT_W + 3) / 4) +
                (output_words % OUTPUT_W) / 4))
          $fatal(1,
                 "Conv1 result mismatch word=%0d value=%h mask=%h m=%0d tag=%h",
                 output_words, egress_values, egress_lane_mask,
                 egress_m, egress_tile_tag);
        output_words <= output_words + 1;
      end
    end
  end

  task automatic pulse_configuration;
    begin
      cfg_valid = 1'b1;
      while (!cfg_ready) @(negedge clk);
      @(posedge clk);
      @(negedge clk);
      cfg_valid = 1'b0;
    end
  endtask

  task automatic fill_weights;
    begin
      weight_fill_valid = 1'b1;
      while (!weight_fill_ready) @(negedge clk);
      @(posedge clk);
      @(negedge clk);
      weight_fill_valid = 1'b0;
      for (int k = 0; k < K_COUNT; k++) begin
        weight_write_valid = 1'b1;
        weight_write_last = k == K_COUNT - 1;
        do @(posedge clk); while (!weight_write_ready);
        @(negedge clk);
        weight_write_valid = 1'b0;
      end
    end
  endtask

  task automatic submit_chunk;
    begin
      chunk_valid = 1'b1;
      while (!chunk_ready) @(negedge clk);
      @(posedge clk);
      @(negedge clk);
      chunk_valid = 1'b0;
    end
  endtask

  task automatic stream_frame;
    begin
      for (int word_index = 0; word_index < INPUT_WORDS; word_index++) begin
        activation_stream_valid = 1'b1;
        activation_stream_last = word_index == INPUT_WORDS - 1;
        do @(posedge clk); while (!activation_stream_ready);
        @(negedge clk);
        activation_stream_valid = 1'b0;
      end
    end
  endtask

  initial begin
    cfg_valid = 1'b0;
    weight_fill_valid = 1'b0;
    weight_write_valid = 1'b0;
    weight_write_last = 1'b0;
    chunk_valid = 1'b0;
    activation_stream_valid = 1'b0;
    activation_stream_last = 1'b0;
    egress_ready = 1'b1;
    for (int lane = 0; lane < 8; lane++) begin
      cfg_bias[lane] = 0;
      cfg_multiplier[lane] = 18'sd65540;
      cfg_right_shift[lane] = 6'd24;
    end

    repeat (8) @(negedge clk);
    rst = 1'b0;
    repeat (3) @(negedge clk);
    pulse_configuration();
    fill_weights();
    submit_chunk();
    stream_frame();

    while (output_words != OUTPUT_WORDS || chunk_done_pulses != 1 ||
           transaction_done_pulses != 1)
      @(negedge clk);
    repeat (5) @(negedge clk);

    if (stream_handshakes != INPUT_WORDS ||
        activation_stream_words_forwarded != 0 || !pipeline_idle ||
        transaction_active || chunk_frame_active || protocol_error ||
        activation_context_error || accum_context_error ||
        weight_context_error)
      $fatal(1,
             "Conv1 streaming retirement mismatch in=%0d visible=%0d out=%0d chunk=%0d tx=%0d idle=%0b errors=%0b/%0b/%0b/%0b",
             stream_handshakes, activation_stream_words_forwarded,
             output_words, chunk_done_pulses, transaction_done_pulses,
             pipeline_idle, protocol_error, activation_context_error,
             accum_context_error, weight_context_error);

    $display("ALEXNET_M4N8_RS_CONV1_STREAMING_TEST_PASSED input_words=%0d k=%0d output_words=%0d bank_words=4096",
             stream_handshakes, K_COUNT, output_words);
    $finish;
  end
endmodule
