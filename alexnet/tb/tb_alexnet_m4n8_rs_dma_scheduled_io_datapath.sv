`timescale 1ns/1ps

module tb_alexnet_m4n8_rs_dma_scheduled_io_datapath;

  localparam int SLICE_INDEX = 1;
  localparam int FIFO_DEPTH = 64;
  localparam int WEIGHT_DEPTH = 968;
  localparam int SEGMENT_DEPTH = 512;
  localparam int WEIGHT_COUNT_W = $clog2(WEIGHT_DEPTH + 1);
  localparam int ACTIVATION_COUNT_W = $clog2(2 * SEGMENT_DEPTH + 1);
  localparam int BANK_COUNT_W = $clog2(2 * SEGMENT_DEPTH + 1);
`ifdef CONV3_GEOMETRY
  localparam int INPUT_H = 13;
  localparam int INPUT_W = 13;
  localparam int CHANNELS = 8;
  localparam int KERNEL = 3;
  localparam int STRIDE = 1;
  localparam int PADDING = 1;
  localparam int OUTPUT_W = 13;
`else
  localparam int INPUT_H = 27;
  localparam int INPUT_W = 27;
  localparam int CHANNELS = 8;
  localparam int KERNEL = 5;
  localparam int STRIDE = 1;
  localparam int PADDING = 2;
  localparam int OUTPUT_W = 27;
`endif
  localparam int OUTPUT_WORDS = INPUT_H * INPUT_W;
  localparam int RESULT_BEATS = (OUTPUT_WORDS + 1) / 2;
  localparam int K_COUNT = KERNEL * KERNEL * CHANNELS;
  localparam int TILES_PER_CHUNK = INPUT_H * ((OUTPUT_W + 3) / 4);
  localparam int CHUNK_COUNT = 2;
  localparam logic [1:0] DMA_ACTIVATION_DIRECT = 2'd0;
  localparam logic [1:0] DMA_ACTIVATION_POOLED = 2'd1;
  localparam logic [1:0] DMA_WEIGHT = 2'd2;

  logic clk = 1'b0;
  logic rst;
  logic ce;
  logic cfg_valid;
  logic cfg_ready;
  logic [1:0] cfg_destination;
  logic [15:0] cfg_n64_tile_base;
  logic [7:0] cfg_lane_mask;
  logic signed [31:0] cfg_bias [0:7];
  logic signed [17:0] cfg_multiplier [0:7];
  logic [5:0] cfg_right_shift [0:7];
  logic [7:0] cfg_relu;

  logic command_valid;
  logic command_ready;
  logic [15:0] command_id;
  logic [1:0] command_activation_destination;
  logic [ACTIVATION_COUNT_W-1:0] command_activation_word_count;
  logic [15:0] command_activation_byte_count;
  logic [7:0] command_activation_lane_mask;
  logic [15:0] command_activation_tensor_tag;
  logic [ACTIVATION_COUNT_W-1:0] command_weight_word_count;
  logic [15:0] command_weight_byte_count;
  logic [7:0] command_weight_lane_mask;
  logic [15:0] command_weight_context_tag;
  logic command_result_enable;
  logic [BANK_COUNT_W-1:0] command_result_word_count;
  logic [15:0] command_result_byte_count;
  logic [1:0] command_result_destination;
  logic [2:0] command_result_slice;
  logic [15:0] command_result_n_base;
  logic [7:0] command_result_lane_mask;
  logic [15:0] command_result_first_tile_tag;
  logic [7:0] command_chunk_input_h;
  logic [7:0] command_chunk_input_w;
  logic [3:0] command_chunk_channel_count;
  logic [7:0] command_chunk_input_lane_mask;
  logic [3:0] command_chunk_kernel;
  logic [2:0] command_chunk_stride;
  logic [2:0] command_chunk_padding;
  logic [WEIGHT_COUNT_W-1:0] command_chunk_k_count;
  logic [15:0] command_chunk_weight_context_tag;
  logic [BANK_COUNT_W-1:0] command_chunk_word_count;
  logic [7:0] command_chunk_output_width;
  logic [15:0] command_chunk_accum_context_tag;
  logic [15:0] command_chunk_tile_tag_base;
  logic [7:0] command_chunk_index;
  logic command_chunk_first;
  logic command_chunk_final;
  logic clear_fault;

  logic [127:0] s_axis_tdata;
  logic [15:0] s_axis_tkeep;
  logic s_axis_tvalid;
  logic s_axis_tready;
  logic s_axis_tlast;
  logic [127:0] m_axis_tdata;
  logic [15:0] m_axis_tkeep;
  logic m_axis_tvalid;
  logic m_axis_tready;
  logic m_axis_tlast;

  logic scheduler_busy;
  logic scheduler_fault;
  logic [3:0] scheduler_fault_code;
  logic [4:0] scheduler_phase;
  logic command_done;
  logic command_rejected;
  logic fault_cleared;
  logic command_error;
  logic [15:0] active_command_id;
  logic [15:0] completed_command_id;
  logic [15:0] accepted_commands;
  logic [15:0] completed_commands;
  logic [15:0] rejected_commands;

  logic configured;
  logic chunk_frame_active;
  logic chunk_done;
  logic chunk_rejected;
  logic compute_busy;
  logic transaction_active;
  logic accum_chunk_active;
  logic transaction_done;
  logic pipeline_idle;
  logic datapath_pipeline_idle;
  logic protocol_error;
  logic datapath_protocol_error;
  logic activation_context_error;
  logic accum_context_error;
  logic weight_context_error;
  logic [15:0] completed_tile_count;
  logic [15:0] completed_weight_replays;
  logic [1:0] weight_bank_state;
  logic weight_resident_valid;
  logic [WEIGHT_COUNT_W-1:0] resident_weight_k_count;
  logic [WEIGHT_COUNT_W-1:0] resident_weight_words_written;
  logic [7:0] resident_weight_n_lane_mask;
  logic [15:0] resident_weight_context_tag;
  logic weight_replay_done;
  logic [2:0] accum_bank_state;
  logic [$clog2(FIFO_DEPTH+1)-1:0] queued_count;
  logic activation_ready_tensor_valid;
  logic activation_ready_tensor_bank;
  logic [15:0] activation_ready_tensor_tag;
  logic [1:0] activation_ready_count;
  logic activation_fill_active;
  logic activation_fill_bank;
  logic activation_read_active;
  logic activation_read_bank;
  logic activation_read_segment;
  logic activation_read_done;
  logic [ACTIVATION_COUNT_W-1:0] activation_words_forwarded;

  logic dma_busy;
  logic dma_transfer_active;
  logic dma_transfer_done;
  logic dma_descriptor_rejected;
  logic dma_descriptor_error;
  logic dma_stream_error;
  logic dma_protocol_error;
  logic [1:0] dma_active_destination;
  logic [ACTIVATION_COUNT_W-1:0] dma_words_transferred;
  logic [15:0] dma_completed_transfers;

  logic result_dma_busy;
  logic result_dma_transfer_active;
  logic result_dma_transfer_done;
  logic result_dma_descriptor_rejected;
  logic result_dma_descriptor_error;
  logic result_dma_metadata_error;
  logic result_dma_protocol_error;
  logic [1:0] result_dma_active_destination;
  logic [2:0] result_dma_active_slice;
  logic [15:0] result_dma_active_n_base;
  logic [7:0] result_dma_active_lane_mask;
  logic [15:0] result_dma_active_first_tile_tag;
  logic [BANK_COUNT_W-1:0] result_dma_words_accepted;
  logic [BANK_COUNT_W-1:0] result_dma_words_transferred;
  logic [BANK_COUNT_W-1:0] result_dma_beats_transferred;
  logic [15:0] result_dma_completed_transfers;
  logic [15:0] result_dma_completed_first_tile_tag;
  logic [15:0] result_dma_completed_last_tile_tag;
  logic rs_mm2s_request_valid, rs_mm2s_request_ready;
  logic [1:0] rs_mm2s_request_destination;
  logic [ACTIVATION_COUNT_W-1:0] rs_mm2s_request_word_count;
  logic [15:0] rs_mm2s_request_byte_count;
  logic [15:0] rs_mm2s_request_tag, rs_mm2s_request_n_base;
  logic [7:0] rs_mm2s_request_chunk_index;
  logic rs_s2mm_request_valid, rs_s2mm_request_ready;
  logic [BANK_COUNT_W-1:0] rs_s2mm_request_word_count;
  logic [15:0] rs_s2mm_request_byte_count;
  logic [15:0] rs_s2mm_request_n_base, rs_s2mm_request_tag;

  int seed;
  int seed_sink;
  int cycles;
  int input_axis_beats;
  int input_dma_words;
  int input_dma_done_pulses;
  int input_dma_rejects;
  int result_dma_done_pulses;
  int result_words_received;
  int result_axis_beats;
  int command_done_pulses;
  int command_reject_pulses;
  int fault_clear_pulses;
  int chunk_completions;
  int transaction_completions;
  int activation_reads;
  int replay_pulses;
  int segment_transitions;
  int max_queued;
  int result_stall_run;
  int maximum_result_stall;
  int physical_mm2s_requests;
  int physical_s2mm_requests;
  logic previous_read_segment;
  logic random_compute_stalls;
  logic random_result_stalls;
  logic force_result_block;
  logic held_result_valid;
  logic [127:0] held_result_data;
  logic [15:0] held_result_keep;
  logic held_result_last;

  alexnet_m4n8_rs_dma_scheduled_io_datapath #(
      .SLICE_INDEX(SLICE_INDEX),
      .FIFO_DEPTH(FIFO_DEPTH),
      .WEIGHT_DEPTH(WEIGHT_DEPTH),
      .SEGMENT_DEPTH(SEGMENT_DEPTH)
  ) dut (
      .shared_cfg_valid(),
      .shared_cfg_ready('0),
      .shared_cfg_destination(),
      .shared_cfg_n64_tile_base(),
      .shared_cfg_slice_index(),
      .shared_cfg_lane_mask(),
      .shared_cfg_bias(),
      .shared_cfg_multiplier(),
      .shared_cfg_right_shift(),
      .shared_cfg_relu(),
      .shared_chunk_valid(),
      .shared_chunk_ready('0),
      .shared_chunk_word_count(),
      .shared_chunk_output_width(),
      .shared_chunk_n_lane_mask(),
      .shared_chunk_context_tag(),
      .shared_chunk_tile_tag_base(),
      .shared_chunk_index(),
      .shared_chunk_first(),
      .shared_chunk_final(),
      .shared_tile_start_valid(),
      .shared_tile_start_ready('0),
      .shared_tile_m_count(),
      .shared_tile_n_lane_mask(),
      .shared_tile_tag(),
      .shared_issue_valid(),
      .shared_issue_ready('0),
      .shared_issue_last(),
      .shared_issue_act_lo(),
      .shared_issue_act_hi(),
      .shared_issue_weight(),
      .shared_egress_valid('0),
      .shared_egress_ready(),
      .shared_egress_values('0),
      .shared_egress_lane_mask('0),
      .shared_egress_destination('0),
      .shared_egress_slice('0),
      .shared_egress_m('0),
      .shared_egress_n_base('0),
      .shared_egress_tile_tag('0),
      .shared_configured('0),
      .shared_compute_busy('0),
      .shared_transaction_active('0),
      .shared_chunk_active('0),
      .shared_tile_done('0),
      .shared_chunk_done('0),
      .shared_transaction_done('0),
      .shared_datapath_idle('0),
      .shared_accum_bank_state('0),
      .shared_accum_context_error('0),
      .shared_protocol_error('0),
      .shared_queued_count('0),
      .clk(clk),
      .rst(rst),
      .ce(ce),
      .cfg_valid(cfg_valid),
      .cfg_ready(cfg_ready),
      .cfg_destination(cfg_destination),
      .cfg_n64_tile_base(cfg_n64_tile_base),
      .cfg_slice_index(3'(SLICE_INDEX)),
      .cfg_lane_mask(cfg_lane_mask),
      .cfg_bias(cfg_bias),
      .cfg_multiplier(cfg_multiplier),
      .cfg_right_shift(cfg_right_shift),
      .cfg_relu(cfg_relu),
      .command_valid(command_valid),
      .command_ready(command_ready),
      .command_id(command_id),
      .command_activation_destination(command_activation_destination),
      .command_activation_word_count(command_activation_word_count),
      .command_activation_byte_count(command_activation_byte_count),
      .command_activation_lane_mask(command_activation_lane_mask),
      .command_activation_tensor_tag(command_activation_tensor_tag),
      .command_weight_word_count(command_weight_word_count),
      .command_weight_byte_count(command_weight_byte_count),
      .command_weight_lane_mask(command_weight_lane_mask),
      .command_weight_context_tag(command_weight_context_tag),
      .command_result_enable(command_result_enable),
      .command_result_word_count(command_result_word_count),
      .command_result_byte_count(command_result_byte_count),
      .command_result_destination(command_result_destination),
      .command_result_slice(command_result_slice),
      .command_result_n_base(command_result_n_base),
      .command_result_lane_mask(command_result_lane_mask),
      .command_result_first_tile_tag(command_result_first_tile_tag),
      .command_chunk_input_h(command_chunk_input_h),
      .command_chunk_input_w(command_chunk_input_w),
      .command_chunk_channel_count(command_chunk_channel_count),
      .command_chunk_input_lane_mask(command_chunk_input_lane_mask),
      .command_chunk_kernel(command_chunk_kernel),
      .command_chunk_stride(command_chunk_stride),
      .command_chunk_padding(command_chunk_padding),
      .command_chunk_k_count(command_chunk_k_count),
      .command_chunk_weight_context_tag(
          command_chunk_weight_context_tag),
      .command_chunk_word_count(command_chunk_word_count),
      .command_chunk_output_width(command_chunk_output_width),
      .command_chunk_accum_context_tag(command_chunk_accum_context_tag),
      .command_chunk_tile_tag_base(command_chunk_tile_tag_base),
      .command_chunk_index(command_chunk_index),
      .command_chunk_first(command_chunk_first),
      .command_chunk_final(command_chunk_final),
      .clear_fault(clear_fault),
      .s_axis_tdata(s_axis_tdata),
      .s_axis_tkeep(s_axis_tkeep),
      .s_axis_tvalid(s_axis_tvalid),
      .s_axis_tready(s_axis_tready),
      .s_axis_tlast(s_axis_tlast),
      .rs_mm2s_request_valid(rs_mm2s_request_valid),
      .rs_mm2s_request_ready(rs_mm2s_request_ready),
      .rs_mm2s_request_destination(rs_mm2s_request_destination),
      .rs_mm2s_request_word_count(rs_mm2s_request_word_count),
      .rs_mm2s_request_byte_count(rs_mm2s_request_byte_count),
      .rs_mm2s_request_tag(rs_mm2s_request_tag),
      .rs_mm2s_request_n_base(rs_mm2s_request_n_base),
      .rs_mm2s_request_chunk_index(rs_mm2s_request_chunk_index),
      .rs_s2mm_request_valid(rs_s2mm_request_valid),
      .rs_s2mm_request_ready(rs_s2mm_request_ready),
      .rs_s2mm_request_word_count(rs_s2mm_request_word_count),
      .rs_s2mm_request_byte_count(rs_s2mm_request_byte_count),
      .rs_s2mm_request_n_base(rs_s2mm_request_n_base),
      .rs_s2mm_request_tag(rs_s2mm_request_tag),
      .m_axis_tdata(m_axis_tdata),
      .m_axis_tkeep(m_axis_tkeep),
      .m_axis_tvalid(m_axis_tvalid),
      .m_axis_tready(m_axis_tready),
      .m_axis_tlast(m_axis_tlast),
      .scheduler_busy(scheduler_busy),
      .scheduler_fault(scheduler_fault),
      .scheduler_fault_code(scheduler_fault_code),
      .scheduler_phase(scheduler_phase),
      .command_done(command_done),
      .command_rejected(command_rejected),
      .fault_cleared(fault_cleared),
      .command_error(command_error),
      .active_command_id(active_command_id),
      .completed_command_id(completed_command_id),
      .accepted_commands(accepted_commands),
      .completed_commands(completed_commands),
      .rejected_commands(rejected_commands),
      .configured(configured),
      .chunk_frame_active(chunk_frame_active),
      .chunk_done(chunk_done),
      .chunk_rejected(chunk_rejected),
      .compute_busy(compute_busy),
      .transaction_active(transaction_active),
      .accum_chunk_active(accum_chunk_active),
      .transaction_done(transaction_done),
      .pipeline_idle(pipeline_idle),
      .datapath_pipeline_idle(datapath_pipeline_idle),
      .protocol_error(protocol_error),
      .datapath_protocol_error(datapath_protocol_error),
      .activation_context_error(activation_context_error),
      .accum_context_error(accum_context_error),
      .weight_context_error(weight_context_error),
      .completed_tile_count(completed_tile_count),
      .completed_weight_replays(completed_weight_replays),
      .weight_bank_state(weight_bank_state),
      .weight_resident_valid(weight_resident_valid),
      .resident_weight_k_count(resident_weight_k_count),
      .resident_weight_words_written(resident_weight_words_written),
      .resident_weight_n_lane_mask(resident_weight_n_lane_mask),
      .resident_weight_context_tag(resident_weight_context_tag),
      .weight_replay_done(weight_replay_done),
      .accum_bank_state(accum_bank_state),
      .queued_count(queued_count),
      .activation_ready_tensor_valid(activation_ready_tensor_valid),
      .activation_ready_tensor_bank(activation_ready_tensor_bank),
      .activation_ready_tensor_tag(activation_ready_tensor_tag),
      .activation_ready_count(activation_ready_count),
      .activation_fill_active(activation_fill_active),
      .activation_fill_bank(activation_fill_bank),
      .activation_read_active(activation_read_active),
      .activation_read_bank(activation_read_bank),
      .activation_read_segment(activation_read_segment),
      .activation_read_done(activation_read_done),
      .activation_words_forwarded(activation_words_forwarded),
      .dma_busy(dma_busy),
      .dma_transfer_active(dma_transfer_active),
      .dma_transfer_done(dma_transfer_done),
      .dma_descriptor_rejected(dma_descriptor_rejected),
      .dma_descriptor_error(dma_descriptor_error),
      .dma_stream_error(dma_stream_error),
      .dma_protocol_error(dma_protocol_error),
      .dma_active_destination(dma_active_destination),
      .dma_words_transferred(dma_words_transferred),
      .dma_completed_transfers(dma_completed_transfers),
      .result_dma_busy(result_dma_busy),
      .result_dma_transfer_active(result_dma_transfer_active),
      .result_dma_transfer_done(result_dma_transfer_done),
      .result_dma_descriptor_rejected(result_dma_descriptor_rejected),
      .result_dma_descriptor_error(result_dma_descriptor_error),
      .result_dma_metadata_error(result_dma_metadata_error),
      .result_dma_protocol_error(result_dma_protocol_error),
      .result_dma_active_destination(result_dma_active_destination),
      .result_dma_active_slice(result_dma_active_slice),
      .result_dma_active_n_base(result_dma_active_n_base),
      .result_dma_active_lane_mask(result_dma_active_lane_mask),
      .result_dma_active_first_tile_tag(result_dma_active_first_tile_tag),
      .result_dma_words_accepted(result_dma_words_accepted),
      .result_dma_words_transferred(result_dma_words_transferred),
      .result_dma_beats_transferred(result_dma_beats_transferred),
      .result_dma_completed_transfers(result_dma_completed_transfers),
      .result_dma_completed_first_tile_tag(
          result_dma_completed_first_tile_tag),
      .result_dma_completed_last_tile_tag(
          result_dma_completed_last_tile_tag)
  );

  always #2.5 clk = ~clk;

  function automatic int valid_axis_count(input int coordinate);
    int low;
    int high;
    begin
      low = coordinate - PADDING;
      if (low < 0)
        low = 0;
      high = coordinate + PADDING;
      if (high >= INPUT_W)
        high = INPUT_W - 1;
      valid_axis_count = high - low + 1;
    end
  endfunction

  function automatic logic [7:0] expected_output_byte(
      input int y,
      input int x);
    int accumulator;
    longint scaled;
    int rounded;
    begin
      accumulator = valid_axis_count(y) * valid_axis_count(x) *
                    CHANNELS * CHUNK_COUNT;
      scaled = accumulator * 65540;
      rounded = (scaled + (1 << 23)) >> 24;
      if (rounded > 127)
        rounded = 127;
      expected_output_byte = rounded[7:0];
    end
  endfunction

  function automatic logic [63:0] expected_output_word(input int index);
    int y;
    int x;
    logic [7:0] value;
    begin
      y = index / OUTPUT_W;
      x = index % OUTPUT_W;
      value = expected_output_byte(y, x);
      expected_output_word = {8{value}};
    end
  endfunction

  always @(negedge clk) begin
    if (rst) begin
      ce <= 1'b1;
      m_axis_tready <= 1'b0;
      rs_mm2s_request_ready <= 1'b0;
      rs_s2mm_request_ready <= 1'b0;
    end else begin
      rs_mm2s_request_ready <= $urandom_range(0, 3) != 0;
      rs_s2mm_request_ready <= $urandom_range(0, 3) != 0;
      if (random_compute_stalls)
        ce <= $urandom_range(0, 15) != 0;
      else
        ce <= 1'b1;

      if (force_result_block)
        m_axis_tready <= 1'b0;
      else if (random_result_stalls)
        m_axis_tready <= $urandom_range(0, 4) != 0;
      else
        m_axis_tready <= 1'b1;
    end
  end

  always @(posedge clk) begin : scoreboard
    int words_this_beat;
    logic [127:0] expected_data;
    logic [15:0] expected_keep;
    logic expected_last;

    if (rst) begin
      cycles = 0;
      input_dma_done_pulses = 0;
      input_dma_rejects = 0;
      result_dma_done_pulses = 0;
      result_words_received = 0;
      result_axis_beats = 0;
      command_done_pulses = 0;
      command_reject_pulses = 0;
      fault_clear_pulses = 0;
      chunk_completions = 0;
      transaction_completions = 0;
      activation_reads = 0;
      replay_pulses = 0;
      segment_transitions = 0;
      max_queued = 0;
      result_stall_run = 0;
      maximum_result_stall = 0;
      physical_mm2s_requests = 0;
      physical_s2mm_requests = 0;
      previous_read_segment = 1'b0;
      held_result_valid = 1'b0;
      held_result_data = '0;
      held_result_keep = '0;
      held_result_last = 1'b0;
    end else begin
      cycles = cycles + 1;
      if (rs_mm2s_request_valid && rs_mm2s_request_ready) begin
        physical_mm2s_requests = physical_mm2s_requests + 1;
        if (rs_mm2s_request_n_base != 16'd1032 ||
            rs_mm2s_request_chunk_index != command_chunk_index)
          $fatal(1, "physical MM2S request lost captured command coordinates");
      end
      if (rs_s2mm_request_valid && rs_s2mm_request_ready) begin
        physical_s2mm_requests = physical_s2mm_requests + 1;
        if (rs_s2mm_request_word_count != OUTPUT_WORDS ||
            rs_s2mm_request_byte_count != OUTPUT_WORDS * 8 ||
            rs_s2mm_request_n_base != 16'd1032 ||
            rs_s2mm_request_tag != 16'h4000)
          $fatal(1, "physical S2MM request metadata mismatch");
      end
      if (cycles > 1200000)
        $fatal(1, "scheduled DMA-loop integration watchdog expired phase=%0d",
               scheduler_phase);
      if (dma_transfer_done)
        input_dma_done_pulses = input_dma_done_pulses + 1;
      if (dma_descriptor_rejected)
        input_dma_rejects = input_dma_rejects + 1;
      if (result_dma_transfer_done)
        result_dma_done_pulses = result_dma_done_pulses + 1;
      if (command_done)
        command_done_pulses = command_done_pulses + 1;
      if (command_rejected)
        command_reject_pulses = command_reject_pulses + 1;
      if (fault_cleared)
        fault_clear_pulses = fault_clear_pulses + 1;
      if (chunk_done)
        chunk_completions = chunk_completions + 1;
      if (transaction_done)
        transaction_completions = transaction_completions + 1;
      if (activation_read_done)
        activation_reads = activation_reads + 1;
      if (weight_replay_done)
        replay_pulses = replay_pulses + 1;
      if (activation_read_active && !previous_read_segment &&
          activation_read_segment)
        segment_transitions = segment_transitions + 1;
      previous_read_segment = activation_read_active &&
                              activation_read_segment;
      if (queued_count > max_queued)
        max_queued = queued_count;

      if (held_result_valid &&
          (!m_axis_tvalid || m_axis_tdata != held_result_data ||
           m_axis_tkeep != held_result_keep ||
           m_axis_tlast != held_result_last))
        $fatal(1, "scheduled DMA-loop output changed under backpressure");

      if (m_axis_tvalid) begin
        if (result_words_received >= OUTPUT_WORDS)
          $fatal(1, "scheduled DMA-loop emitted an extra result beat");
        words_this_beat = OUTPUT_WORDS - result_words_received >= 2 ? 2 : 1;
        expected_data = '0;
        expected_data[63:0] = expected_output_word(result_words_received);
        if (words_this_beat == 2)
          expected_data[127:64] =
              expected_output_word(result_words_received + 1);
        expected_keep = words_this_beat == 2 ? 16'hffff : 16'h00ff;
        expected_last = result_words_received + words_this_beat ==
                        OUTPUT_WORDS;
        if (m_axis_tdata != expected_data ||
            m_axis_tkeep != expected_keep ||
            m_axis_tlast != expected_last)
          $fatal(1,
                 "scheduled DMA-loop result mismatch word=%0d data=%032x/%032x keep=%04x/%04x last=%0b/%0b",
                 result_words_received, m_axis_tdata, expected_data,
                 m_axis_tkeep, expected_keep, m_axis_tlast,
                 expected_last);
        if (m_axis_tready) begin
          result_words_received = result_words_received + words_this_beat;
          result_axis_beats = result_axis_beats + 1;
          result_stall_run = 0;
        end else begin
          result_stall_run = result_stall_run + 1;
          if (result_stall_run > maximum_result_stall)
            maximum_result_stall = result_stall_run;
        end
      end else begin
        result_stall_run = 0;
      end

      held_result_valid = m_axis_tvalid && !m_axis_tready;
      if (held_result_valid) begin
        held_result_data = m_axis_tdata;
        held_result_keep = m_axis_tkeep;
        held_result_last = m_axis_tlast;
      end
    end
  end

  task automatic configure_datapath;
    begin
      cfg_destination = 2'd1;
      cfg_n64_tile_base = 16'd1024;
      cfg_lane_mask = 8'hff;
      cfg_relu = '0;
      for (int lane = 0; lane < 8; lane++) begin
        cfg_bias[lane] = 0;
        cfg_multiplier[lane] = 18'sd65540;
        cfg_right_shift[lane] = 6'd24;
      end
      cfg_valid = 1'b1;
      while (!cfg_ready)
        @(negedge clk);
      @(posedge clk);
      @(negedge clk);
      cfg_valid = 1'b0;
    end
  endtask

  task automatic prepare_command(
      input int chunk_number,
      input logic final_chunk,
      input logic bad_relationship,
      input logic bad_activation_byte_count);
    begin
      command_id = 16'h0100 + chunk_number;
      command_activation_destination =
          chunk_number[0] ? DMA_ACTIVATION_POOLED : DMA_ACTIVATION_DIRECT;
      command_activation_word_count = OUTPUT_WORDS;
      command_activation_byte_count = bad_activation_byte_count ?
          16'(OUTPUT_WORDS * 8 - 1) : 16'(OUTPUT_WORDS * 8);
      command_activation_lane_mask = 8'hff;
      command_activation_tensor_tag = 16'h2000 + chunk_number;
      command_weight_word_count = K_COUNT;
      command_weight_byte_count = K_COUNT * 8;
      command_weight_lane_mask = 8'hff;
      command_weight_context_tag = 16'h1000 + chunk_number;
      command_result_enable = bad_relationship ? !final_chunk : final_chunk;
      command_result_word_count = OUTPUT_WORDS;
      command_result_byte_count = OUTPUT_WORDS * 8;
      command_result_destination = 2'd1;
      command_result_slice = SLICE_INDEX;
      command_result_n_base = 16'd1032;
      command_result_lane_mask = 8'hff;
      command_result_first_tile_tag = 16'h4000;
      command_chunk_input_h = INPUT_H;
      command_chunk_input_w = INPUT_W;
      command_chunk_channel_count = CHANNELS;
      command_chunk_input_lane_mask = 8'hff;
      command_chunk_kernel = KERNEL;
      command_chunk_stride = STRIDE;
      command_chunk_padding = PADDING;
      command_chunk_k_count = K_COUNT;
      command_chunk_weight_context_tag = 16'h1000 + chunk_number;
      command_chunk_word_count = OUTPUT_WORDS;
      command_chunk_output_width = OUTPUT_W;
      command_chunk_accum_context_tag = 16'h4400;
      command_chunk_tile_tag_base = 16'h4000;
      command_chunk_index = chunk_number;
      command_chunk_first = chunk_number == 0;
      command_chunk_final = final_chunk;
    end
  endtask

  task automatic submit_command;
    begin
      while (!command_ready)
        @(negedge clk);
      command_valid = 1'b1;
      @(posedge clk);
      @(negedge clk);
      command_valid = 1'b0;
    end
  endtask

  task automatic recover_fault(input logic expect_datapath_error);
    begin
      while (!scheduler_fault)
        @(negedge clk);
      if (!protocol_error || scheduler_phase != 5'd14 || command_ready ||
          (expect_datapath_error && !datapath_protocol_error) ||
          (!expect_datapath_error && datapath_protocol_error))
        $fatal(1,
               "scheduled DMA-loop fault status mismatch code=%0d top=%0b datapath=%0b",
               scheduler_fault_code, protocol_error,
               datapath_protocol_error);
      clear_fault = 1'b1;
      @(posedge clk);
      @(negedge clk);
      clear_fault = 1'b0;
      while (!fault_cleared)
        @(negedge clk);
      if (scheduler_fault || protocol_error || datapath_protocol_error ||
          dma_protocol_error || result_dma_protocol_error)
        $fatal(1, "scheduled DMA-loop fault recovery failed");
      @(negedge clk);
    end
  endtask

  task automatic drive_input_dma_payload(input int word_count);
    int word_index;
    int words_this_beat;
    begin
      word_index = 0;
      while (word_index < word_count) begin
        repeat ($urandom_range(0, 3)) @(negedge clk);
        @(negedge clk);
        while (!s_axis_tready)
          @(negedge clk);
        words_this_beat = word_count - word_index >= 2 ? 2 : 1;
        s_axis_tdata = '0;
        s_axis_tdata[63:0] = 64'h0101_0101_0101_0101;
        if (words_this_beat == 2)
          s_axis_tdata[127:64] = 64'h0101_0101_0101_0101;
        s_axis_tkeep = words_this_beat == 2 ? 16'hffff : 16'h00ff;
        s_axis_tlast = word_index + words_this_beat == word_count;
        s_axis_tvalid = 1'b1;
        @(posedge clk);
        input_axis_beats = input_axis_beats + 1;
        @(negedge clk);
        s_axis_tvalid = 1'b0;
        word_index = word_index + words_this_beat;
      end
    end
  endtask

  task automatic drive_one_scheduler_input_transfer(
      input logic [1:0] expected_destination,
      input int word_count);
    int completed_before;
    begin
      completed_before = dma_completed_transfers;
      while (!dma_transfer_active)
        @(negedge clk);
      if (dma_active_destination != expected_destination)
        $fatal(1,
               "scheduler input destination mismatch got=%0d expected=%0d",
               dma_active_destination, expected_destination);
      drive_input_dma_payload(word_count);
      while (!dma_transfer_done)
        @(negedge clk);
      if (dma_words_transferred != word_count ||
          dma_completed_transfers != completed_before + 1 ||
          dma_protocol_error)
        $fatal(1,
               "scheduled input DMA transfer failed destination=%0d words=%0d/%0d completed=%0d/%0d error=%0b",
               expected_destination, dma_words_transferred, word_count,
               dma_completed_transfers, completed_before + 1,
               dma_protocol_error);
      input_dma_words = input_dma_words + word_count;
      @(negedge clk);
    end
  endtask

  task automatic feed_command_payloads(input int chunk_number);
    begin
      drive_one_scheduler_input_transfer(
          chunk_number[0] ? DMA_ACTIVATION_POOLED : DMA_ACTIVATION_DIRECT,
          OUTPUT_WORDS);
      drive_one_scheduler_input_transfer(DMA_WEIGHT, K_COUNT);
    end
  endtask

  task automatic wait_command_completion(input int chunk_number);
    int timeout;
    begin
      timeout = 0;
      while (!command_done && timeout < 220000) begin
        @(negedge clk);
        timeout = timeout + 1;
      end
      if (timeout == 220000 ||
          completed_command_id != 16'(16'h0100 + chunk_number))
        $fatal(1,
               "scheduled command completion failed chunk=%0d timeout=%0d id=%0h phase=%0d scheduler_busy=%0b datapath_idle=%0b dma_busy=%0b result_busy=%0b weight_state=%0d chunk_frame=%0b compute=%0b transaction=%0b accum=%0b queue=%0d activation_ready=%0d fill=%0b read=%0b segment=%0b request=%0b/%0b launch=%0b children=%0b child_ready=%0b/%0b errors=%0b/%0b",
               chunk_number, timeout, completed_command_id,
               scheduler_phase, scheduler_busy, datapath_pipeline_idle,
               dma_busy, result_dma_busy, weight_bank_state,
               chunk_frame_active, compute_busy, transaction_active,
               accum_chunk_active, queued_count, activation_ready_count,
               activation_fill_active, activation_read_active,
               activation_read_segment,
               dut.u_datapath.u_dma_fed_datapath.u_datapath.request_pending_q,
               dut.u_datapath.u_dma_fed_datapath.u_datapath.request_validation_done_q,
               dut.u_datapath.u_dma_fed_datapath.u_datapath.launch_fire,
               dut.u_datapath.u_dma_fed_datapath.u_datapath.u_activation.children_head_match,
               dut.u_datapath.u_dma_fed_datapath.u_datapath.u_activation.segment0_read_start_ready,
               dut.u_datapath.u_dma_fed_datapath.u_datapath.u_activation.segment1_read_start_ready,
               scheduler_fault,
               datapath_protocol_error);
      @(negedge clk);
    end
  endtask

  initial begin
    int timeout;

    seed = 32'h7d62_4a17;
    seed_sink = $urandom(seed);
    rst = 1'b1;
    ce = 1'b1;
    cfg_valid = 1'b0;
    cfg_destination = '0;
    cfg_n64_tile_base = '0;
    cfg_lane_mask = '0;
    cfg_relu = '0;
    command_valid = 1'b0;
    command_id = '0;
    command_activation_destination = '0;
    command_activation_word_count = '0;
    command_activation_byte_count = '0;
    command_activation_lane_mask = '0;
    command_activation_tensor_tag = '0;
    command_weight_word_count = '0;
    command_weight_byte_count = '0;
    command_weight_lane_mask = '0;
    command_weight_context_tag = '0;
    command_result_enable = 1'b0;
    command_result_word_count = '0;
    command_result_byte_count = '0;
    command_result_destination = '0;
    command_result_slice = '0;
    command_result_n_base = '0;
    command_result_lane_mask = '0;
    command_result_first_tile_tag = '0;
    command_chunk_input_h = '0;
    command_chunk_input_w = '0;
    command_chunk_channel_count = '0;
    command_chunk_input_lane_mask = '0;
    command_chunk_kernel = '0;
    command_chunk_stride = '0;
    command_chunk_padding = '0;
    command_chunk_k_count = '0;
    command_chunk_weight_context_tag = '0;
    command_chunk_word_count = '0;
    command_chunk_output_width = '0;
    command_chunk_accum_context_tag = '0;
    command_chunk_tile_tag_base = '0;
    command_chunk_index = '0;
    command_chunk_first = 1'b0;
    command_chunk_final = 1'b0;
    clear_fault = 1'b0;
    s_axis_tdata = '0;
    s_axis_tkeep = '0;
    s_axis_tvalid = 1'b0;
    s_axis_tlast = 1'b0;
    m_axis_tready = 1'b0;
    random_compute_stalls = 1'b0;
    random_result_stalls = 1'b1;
    force_result_block = 1'b0;
    input_axis_beats = 0;
    input_dma_words = 0;
    for (int lane = 0; lane < 8; lane++) begin
      cfg_bias[lane] = 0;
      cfg_multiplier[lane] = 18'sd65540;
      cfg_right_shift[lane] = 6'd24;
    end

    repeat (5) @(negedge clk);
    rst = 1'b0;
    repeat (2) @(negedge clk);
    if (command_ready || configured || !pipeline_idle || scheduler_busy ||
        scheduler_fault || protocol_error || weight_bank_state != 0)
      $fatal(1, "scheduled DMA-loop reset readiness mismatch");

    configure_datapath();
    if (!configured || !command_ready || !pipeline_idle)
      $fatal(1, "scheduled DMA-loop configuration readiness mismatch");

    // Reject a cross-field-invalid command before either DMA sees it.
    prepare_command(7, 1'b1, 1'b1, 1'b0);
    submit_command();
    while (!scheduler_fault)
      @(negedge clk);
    if (scheduler_fault_code != 4'd5 || !command_error ||
        dma_completed_transfers != 0 || dma_descriptor_rejected)
      $fatal(1, "scheduled local-command rejection mismatch");
    recover_fault(1'b0);

    // Pass malformed byte count to the real ingress and recover its fault.
    prepare_command(8, 1'b0, 1'b0, 1'b1);
    submit_command();
    while (!dma_descriptor_rejected)
      @(negedge clk);
    while (!scheduler_fault)
      @(negedge clk);
    if (scheduler_fault_code != 4'd2 || !dma_descriptor_error ||
        dma_transfer_active || dma_completed_transfers != 0)
      $fatal(1, "scheduled downstream descriptor rejection mismatch");
    recover_fault(1'b1);

    random_compute_stalls = 1'b1;

    // Non-final chunk: no result descriptor and no output transfer.
    prepare_command(0, 1'b0, 1'b0, 1'b0);
    submit_command();
    feed_command_payloads(0);
    wait_command_completion(0);
    if (result_dma_completed_transfers != 0 ||
        result_dma_transfer_active || weight_bank_state != 0 ||
        activation_ready_count != 0 || completed_tile_count !=
            TILES_PER_CHUNK)
      $fatal(1, "scheduled non-final command ownership mismatch");

    // Final chunk: keep S2MM blocked until compute retires and FIFO fills.
    force_result_block = 1'b1;
    prepare_command(1, 1'b1, 1'b0, 1'b0);
    submit_command();
    feed_command_payloads(1);
    timeout = 0;
    while (chunk_completions != CHUNK_COUNT && timeout < 200000) begin
      @(negedge clk);
      timeout = timeout + 1;
    end
    while (scheduler_phase != 5'd12 && timeout < 200000) begin
      @(negedge clk);
      timeout = timeout + 1;
    end
    if (timeout == 200000 || !result_dma_transfer_active)
      $fatal(1,
             "scheduled final chunk did not retire into result wait phase timeout=%0d phase=%0d result_active=%0b",
             timeout, scheduler_phase, result_dma_transfer_active);
    repeat (400) @(negedge clk);
    if (max_queued != FIFO_DEPTH)
      $fatal(1, "scheduled DMA-loop did not fill router queue depth=%0d",
             max_queued);
    force_result_block = 1'b0;
    random_compute_stalls = 1'b0;
    wait_command_completion(1);

    timeout = 0;
    while (!pipeline_idle && timeout < 200000) begin
      @(negedge clk);
      timeout = timeout + 1;
    end
    if (timeout == 200000)
      $fatal(1, "scheduled DMA-loop final idle timeout");
    repeat (3) @(negedge clk);

    if (accepted_commands != 4 || completed_commands != 2 ||
        rejected_commands != 2 || command_done_pulses != 2 ||
        command_reject_pulses != 2 || fault_clear_pulses != 2 ||
        completed_command_id != 16'h0101 ||
        dma_completed_transfers != 4 || input_dma_done_pulses != 4 ||
        input_dma_rejects != 1 ||
        input_dma_words != 2 * OUTPUT_WORDS + 2 * K_COUNT ||
        input_axis_beats != 2 * ((OUTPUT_WORDS + 1) / 2) + K_COUNT ||
        result_dma_completed_transfers != 1 ||
        result_dma_done_pulses != 1 ||
        physical_mm2s_requests != 5 || physical_s2mm_requests != 1 ||
        result_dma_words_accepted != OUTPUT_WORDS ||
        result_dma_words_transferred != OUTPUT_WORDS ||
        result_dma_beats_transferred != RESULT_BEATS ||
        result_words_received != OUTPUT_WORDS ||
        result_axis_beats != RESULT_BEATS ||
        result_dma_completed_first_tile_tag != 16'h4000 ||
        result_dma_completed_last_tile_tag !=
            16'(16'h4000 + INPUT_H * ((OUTPUT_W + 3) / 4) - 1) ||
        chunk_completions != CHUNK_COUNT ||
        transaction_completions != 1 || activation_reads != CHUNK_COUNT ||
        completed_weight_replays != CHUNK_COUNT * TILES_PER_CHUNK ||
        replay_pulses != CHUNK_COUNT * TILES_PER_CHUNK ||
        segment_transitions !=
            (OUTPUT_WORDS > SEGMENT_DEPTH ? CHUNK_COUNT : 0) ||
        max_queued != FIFO_DEPTH ||
        scheduler_busy || scheduler_fault || command_error ||
        protocol_error || datapath_protocol_error || dma_protocol_error ||
        result_dma_protocol_error || activation_context_error ||
        accum_context_error || weight_context_error || transaction_active ||
        activation_ready_count != 0 || weight_bank_state != 0)
      $fatal(1,
             "scheduled DMA-loop final mismatch accepted=%0d completed=%0d rejected=%0d done=%0d rejects=%0d clears=%0d id=%0h input_dma=%0d/%0d input_rejects=%0d words=%0d beats=%0d result_dma=%0d/%0d result=%0d/%0d beats=%0d/%0d chunks=%0d tx=%0d reads=%0d replays=%0d/%0d transitions=%0d maxq=%0d faults=%0b/%0b/%0b/%0b/%0b",
             accepted_commands, completed_commands, rejected_commands,
             command_done_pulses, command_reject_pulses,
             fault_clear_pulses, completed_command_id,
             dma_completed_transfers, input_dma_done_pulses,
             input_dma_rejects, input_dma_words, input_axis_beats,
             result_dma_completed_transfers, result_dma_done_pulses,
             result_dma_words_transferred, result_words_received,
             result_dma_beats_transferred, result_axis_beats,
             chunk_completions, transaction_completions, activation_reads,
             completed_weight_replays, replay_pulses, segment_transitions,
             max_queued, scheduler_fault, protocol_error,
             datapath_protocol_error, dma_protocol_error,
             result_dma_protocol_error);

    $display(
        "ALEXNET_M4N8_RS_DMA_SCHEDULED_IO_DATAPATH_TEST_PASSED commands=4 completed=2 rejected=2 input_dma_transfers=%0d input_dma_words=%0d input_axis_beats=%0d result_dma_transfers=%0d result_words=%0d result_axis_beats=%0d chunks=%0d tiles=%0d replays=%0d transitions=%0d input_descriptor_rejects=%0d fault_clears=%0d maxq=%0d max_s2mm_stall=%0d seed=%0d",
        dma_completed_transfers, input_dma_words, input_axis_beats,
        result_dma_completed_transfers, result_words_received,
        result_axis_beats, chunk_completions,
        CHUNK_COUNT * TILES_PER_CHUNK, completed_weight_replays,
        segment_transitions, input_dma_rejects, fault_clear_pulses,
        max_queued, maximum_result_stall, seed);
    $finish;
  end

endmodule
