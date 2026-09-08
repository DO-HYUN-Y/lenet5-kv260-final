`timescale 1ns/1ps

module tb_alexnet_m4n8_rs_dma_activation_resident_weight_dual_accum_datapath;

  localparam int SLICE_INDEX = 1;
  localparam int FIFO_DEPTH = 64;
  localparam int WEIGHT_DEPTH = 968;
  localparam int SEGMENT_DEPTH = 512;
  localparam int WEIGHT_COUNT_W = $clog2(WEIGHT_DEPTH + 1);
  localparam int ACTIVATION_COUNT_W = $clog2(2 * SEGMENT_DEPTH + 1);
  localparam int BANK_COUNT_W = $clog2(2 * SEGMENT_DEPTH + 1);
  localparam int INPUT_H = 27;
  localparam int INPUT_W = 27;
  localparam int CHANNELS = 8;
  localparam int KERNEL = 5;
  localparam int STRIDE = 1;
  localparam int PADDING = 2;
  localparam int OUTPUT_W = 27;
  localparam int OUTPUT_WORDS = INPUT_H * INPUT_W;
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

  logic dma_clear_error;
  logic dma_descriptor_valid;
  logic dma_descriptor_ready;
  logic [1:0] dma_descriptor_destination;
  logic [ACTIVATION_COUNT_W-1:0] dma_descriptor_word_count;
  logic [15:0] dma_descriptor_byte_count;
  logic [7:0] dma_descriptor_lane_mask;
  logic [15:0] dma_descriptor_tag;
  logic [127:0] s_axis_tdata;
  logic [15:0] s_axis_tkeep;
  logic s_axis_tvalid;
  logic s_axis_tready;
  logic s_axis_tlast;

  logic weight_release_valid;
  logic weight_release_ready;
  logic chunk_valid;
  logic chunk_ready;
  logic [15:0] chunk_activation_tensor_tag;
  logic [7:0] chunk_input_h;
  logic [7:0] chunk_input_w;
  logic [3:0] chunk_channel_count;
  logic [7:0] chunk_input_lane_mask;
  logic [3:0] chunk_kernel;
  logic [2:0] chunk_stride;
  logic [2:0] chunk_padding;
  logic [WEIGHT_COUNT_W-1:0] chunk_k_count;
  logic [15:0] chunk_weight_context_tag;
  logic [BANK_COUNT_W-1:0] chunk_word_count;
  logic [7:0] chunk_output_width;
  logic [15:0] chunk_accum_context_tag;
  logic [15:0] chunk_tile_tag_base;
  logic [7:0] chunk_index;
  logic chunk_first;
  logic chunk_final;

  logic egress_valid;
  logic egress_ready;
  logic [63:0] egress_values;
  logic [7:0] egress_lane_mask;
  logic [1:0] egress_destination;
  logic [2:0] egress_slice;
  logic [4:0] egress_m;
  logic [15:0] egress_n_base;
  logic [15:0] egress_tile_tag;

  logic configured;
  logic chunk_frame_active;
  logic chunk_done;
  logic chunk_rejected;
  logic compute_busy;
  logic transaction_active;
  logic accum_chunk_active;
  logic transaction_done;
  logic pipeline_idle;
  logic protocol_error;
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

  int seed;
  int seed_sink;
  int cycles;
  int axis_beats;
  int dma_words_sent;
  int dma_rejects;
  int dma_done_pulses;
  int chunk_launches;
  int chunk_completions;
  int transaction_completions;
  int activation_reads;
  int replay_pulses;
  int overlap_cycles;
  int segment_transitions;
  int error_interlock_cycles;
  int output_packets;
  int max_queued;
  logic previous_read_segment;
  logic random_compute_stalls;
  logic force_output_block;
  logic force_output_ready;
  logic stalled_output_q;
  logic [63:0] stalled_values_q;
  logic [7:0] stalled_mask_q;
  logic [1:0] stalled_destination_q;
  logic [2:0] stalled_slice_q;
  logic [4:0] stalled_m_q;
  logic [15:0] stalled_n_base_q;
  logic [15:0] stalled_tag_q;

  alexnet_m4n8_rs_dma_activation_resident_weight_dual_accum_datapath #(
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
.*);

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

  always @(negedge clk) begin
    if (rst) begin
      ce <= 1'b1;
      egress_ready <= 1'b0;
    end else begin
      if (random_compute_stalls)
        ce <= $urandom_range(0, 15) != 0;
      else
        ce <= 1'b1;

      if (force_output_block)
        egress_ready <= 1'b0;
      else if (force_output_ready)
        egress_ready <= 1'b1;
      else
        egress_ready <= $urandom_range(0, 4) != 0;
    end
  end

  always @(posedge clk) begin : scoreboard
    int y;
    int x;
    int tile_index;
    logic [7:0] expected_byte;
    logic [63:0] expected_values;

    if (rst) begin
      cycles = 0;
      dma_done_pulses = 0;
      dma_rejects = 0;
      chunk_launches = 0;
      chunk_completions = 0;
      transaction_completions = 0;
      activation_reads = 0;
      replay_pulses = 0;
      overlap_cycles = 0;
      segment_transitions = 0;
      output_packets = 0;
      max_queued = 0;
      previous_read_segment = 1'b0;
      stalled_output_q <= 1'b0;
      stalled_values_q <= '0;
      stalled_mask_q <= '0;
      stalled_destination_q <= '0;
      stalled_slice_q <= '0;
      stalled_m_q <= '0;
      stalled_n_base_q <= '0;
      stalled_tag_q <= '0;
    end else begin
      cycles = cycles + 1;
      if (cycles > 1000000)
        $fatal(1, "DMA-fed RS integration watchdog expired");
      if (dma_transfer_done)
        dma_done_pulses = dma_done_pulses + 1;
      if (dma_descriptor_rejected)
        dma_rejects = dma_rejects + 1;
      if (chunk_valid && chunk_ready)
        chunk_launches = chunk_launches + 1;
      if (chunk_done)
        chunk_completions = chunk_completions + 1;
      if (transaction_done)
        transaction_completions = transaction_completions + 1;
      if (activation_read_done)
        activation_reads = activation_reads + 1;
      if (weight_replay_done)
        replay_pulses = replay_pulses + 1;
      if (activation_fill_active && activation_read_active)
        overlap_cycles = overlap_cycles + 1;
      if (activation_read_active && !previous_read_segment &&
          activation_read_segment)
        segment_transitions = segment_transitions + 1;
      previous_read_segment = activation_read_active &&
                              activation_read_segment;
      if (queued_count > max_queued)
        max_queued = queued_count;

      if (stalled_output_q &&
          (!egress_valid || egress_values != stalled_values_q ||
           egress_lane_mask != stalled_mask_q ||
           egress_destination != stalled_destination_q ||
           egress_slice != stalled_slice_q || egress_m != stalled_m_q ||
           egress_n_base != stalled_n_base_q ||
           egress_tile_tag != stalled_tag_q))
        $fatal(1, "DMA-fed RS output changed under backpressure");

      stalled_output_q <= egress_valid && !egress_ready;
      if (egress_valid && !egress_ready) begin
        stalled_values_q <= egress_values;
        stalled_mask_q <= egress_lane_mask;
        stalled_destination_q <= egress_destination;
        stalled_slice_q <= egress_slice;
        stalled_m_q <= egress_m;
        stalled_n_base_q <= egress_n_base;
        stalled_tag_q <= egress_tile_tag;
      end

      if (egress_valid) begin
        if (output_packets >= OUTPUT_WORDS)
          $fatal(1, "DMA-fed RS emitted an extra output packet");
        y = output_packets / OUTPUT_W;
        x = output_packets % OUTPUT_W;
        tile_index = y * ((OUTPUT_W + 3) / 4) + x / 4;
        expected_byte = expected_output_byte(y, x);
        expected_values = {8{expected_byte}};
        if (egress_values != expected_values ||
            egress_lane_mask != 8'hff || egress_destination != 2'd1 ||
            egress_slice != SLICE_INDEX || egress_m != x % 4 ||
            egress_n_base != 16'd1032 ||
            egress_tile_tag != 16'h4000 + tile_index)
          $fatal(1,
                 "DMA-fed RS packet mismatch index=%0d xy=(%0d,%0d) values=%016x/%016x m=%0d tag=%0h/%0h",
                 output_packets, x, y, egress_values, expected_values,
                 egress_m, egress_tile_tag, 16'h4000 + tile_index);
        if (egress_ready)
          output_packets = output_packets + 1;
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

  task automatic drive_chunk_descriptor(input int chunk_number);
    begin
      chunk_activation_tensor_tag = 16'h2000 + chunk_number;
      chunk_input_h = INPUT_H;
      chunk_input_w = INPUT_W;
      chunk_channel_count = CHANNELS;
      chunk_input_lane_mask = 8'hff;
      chunk_kernel = KERNEL;
      chunk_stride = STRIDE;
      chunk_padding = PADDING;
      chunk_k_count = K_COUNT;
      chunk_weight_context_tag = 16'h1000 + chunk_number;
      chunk_word_count = OUTPUT_WORDS;
      chunk_output_width = OUTPUT_W;
      chunk_accum_context_tag = 16'h4400;
      chunk_tile_tag_base = 16'h4000;
      chunk_index = chunk_number;
      chunk_first = chunk_number == 0;
      chunk_final = chunk_number == CHUNK_COUNT - 1;
    end
  endtask

  task automatic submit_dma_descriptor(
      input logic [1:0] destination,
      input int word_count,
      input int byte_count,
      input logic [15:0] tag);
    begin
      @(negedge clk);
      while (!dma_descriptor_ready)
        @(negedge clk);
      dma_descriptor_destination = destination;
      dma_descriptor_word_count = ACTIVATION_COUNT_W'(word_count);
      dma_descriptor_byte_count = 16'(byte_count);
      dma_descriptor_lane_mask = 8'hff;
      dma_descriptor_tag = tag;
      dma_descriptor_valid = 1'b1;
      @(posedge clk);
      @(negedge clk);
      dma_descriptor_valid = 1'b0;
    end
  endtask

  task automatic drive_dma_payload(input int word_count);
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
        s_axis_tdata = {128{1'b0}};
        s_axis_tdata[63:0] = 64'h0101_0101_0101_0101;
        if (words_this_beat == 2)
          s_axis_tdata[127:64] = 64'h0101_0101_0101_0101;
        s_axis_tkeep = words_this_beat == 2 ? 16'hffff : 16'h00ff;
        s_axis_tlast = word_index + words_this_beat == word_count;
        s_axis_tvalid = 1'b1;
        @(posedge clk);
        axis_beats = axis_beats + 1;
        @(negedge clk);
        s_axis_tvalid = 1'b0;
        word_index = word_index + words_this_beat;
      end
    end
  endtask

  task automatic dma_transfer(
      input logic [1:0] destination,
      input int word_count,
      input logic [15:0] tag);
    int completed_before;
    begin
      completed_before = dma_completed_transfers;
      submit_dma_descriptor(destination, word_count, word_count * 8, tag);
      while (!dma_transfer_active)
        @(negedge clk);
      drive_dma_payload(word_count);
      while (!dma_transfer_done)
        @(negedge clk);
      if (dma_words_transferred != word_count ||
          dma_completed_transfers != completed_before + 1 ||
          dma_protocol_error)
        $fatal(1,
               "DMA-fed owner transfer failed destination=%0d words=%0d/%0d completed=%0d/%0d error=%0b",
               destination, dma_words_transferred, word_count,
               dma_completed_transfers, completed_before + 1,
               dma_protocol_error);
      dma_words_sent = dma_words_sent + word_count;
      @(negedge clk);
    end
  endtask

  task automatic inject_bad_dma_descriptor;
    int activation_count_before;
    logic [1:0] weight_state_before;
    begin
      activation_count_before = activation_ready_count;
      weight_state_before = weight_bank_state;
      submit_dma_descriptor(DMA_ACTIVATION_DIRECT, 7, 55, 16'h2bad);
      while (!dma_descriptor_rejected)
        @(negedge clk);
      if (!dma_descriptor_error || !dma_protocol_error || dma_busy ||
          activation_ready_count != activation_count_before ||
          weight_bank_state != weight_state_before)
        $fatal(1, "bad DMA descriptor changed a real storage owner");
    end
  endtask

  task automatic clear_dma_errors;
    begin
      @(negedge clk);
      dma_clear_error = 1'b1;
      @(posedge clk);
      @(negedge clk);
      dma_clear_error = 1'b0;
      if (dma_protocol_error || dma_descriptor_error || dma_stream_error)
        $fatal(1, "DMA errors failed to clear");
    end
  endtask

  task automatic start_chunk_with_dma_interlock(input int chunk_number);
    begin
      drive_chunk_descriptor(chunk_number);
      @(negedge clk);
      chunk_valid = 1'b1;
      repeat (6) begin
        @(posedge clk);
        if (chunk_ready || chunk_frame_active || activation_read_active)
          $fatal(1, "DMA error failed to block chunk launch");
        error_interlock_cycles = error_interlock_cycles + 1;
        @(negedge clk);
      end
      dma_clear_error = 1'b1;
      @(posedge clk);
      @(negedge clk);
      dma_clear_error = 1'b0;
      while (!chunk_ready)
        @(negedge clk);
      @(posedge clk);
      @(negedge clk);
      chunk_valid = 1'b0;
      while (!chunk_frame_active)
        @(negedge clk);
    end
  endtask

  task automatic start_chunk(input int chunk_number);
    begin
      drive_chunk_descriptor(chunk_number);
      @(negedge clk);
      while (!chunk_ready)
        @(negedge clk);
      chunk_valid = 1'b1;
      @(posedge clk);
      @(negedge clk);
      chunk_valid = 1'b0;
      while (!chunk_frame_active)
        @(negedge clk);
    end
  endtask

  task automatic wait_for_chunk(input int chunk_number);
    int timeout;
    begin
      timeout = 0;
      while (!chunk_done && timeout < 180000) begin
        @(negedge clk);
        timeout = timeout + 1;
      end
      if (timeout == 180000 || activation_words_forwarded != OUTPUT_WORDS ||
          completed_tile_count != TILES_PER_CHUNK ||
          weight_bank_state != 2 || activation_read_active ||
          accum_chunk_active || accum_context_error)
        $fatal(1,
               "DMA-fed chunk failed chunk=%0d timeout=%0d words=%0d tiles=%0d weight=%0d aread=%0b accum=%0b error=%0b",
               chunk_number, timeout, activation_words_forwarded,
               completed_tile_count, weight_bank_state,
               activation_read_active, accum_chunk_active,
               accum_context_error);
      @(negedge clk);
    end
  endtask

  task automatic release_weight(input int chunk_number);
    begin
      weight_release_valid = 1'b1;
      while (!weight_release_ready)
        @(negedge clk);
      @(posedge clk);
      @(negedge clk);
      weight_release_valid = 1'b0;
      if (weight_bank_state != 0 || weight_resident_valid)
        $fatal(1, "DMA-fed weight release failed chunk=%0d", chunk_number);
    end
  endtask

  initial begin
    int timeout;

    seed = 32'h76d4_2b19;
    seed_sink = $urandom(seed);
    rst = 1'b1;
    ce = 1'b1;
    cfg_valid = 1'b0;
    cfg_destination = '0;
    cfg_n64_tile_base = '0;
    cfg_lane_mask = '0;
    cfg_relu = '0;
    dma_clear_error = 1'b0;
    dma_descriptor_valid = 1'b0;
    dma_descriptor_destination = '0;
    dma_descriptor_word_count = '0;
    dma_descriptor_byte_count = '0;
    dma_descriptor_lane_mask = '0;
    dma_descriptor_tag = '0;
    s_axis_tdata = '0;
    s_axis_tkeep = '0;
    s_axis_tvalid = 1'b0;
    s_axis_tlast = 1'b0;
    weight_release_valid = 1'b0;
    chunk_valid = 1'b0;
    drive_chunk_descriptor(0);
    egress_ready = 1'b0;
    random_compute_stalls = 1'b0;
    force_output_block = 1'b0;
    force_output_ready = 1'b0;
    axis_beats = 0;
    dma_words_sent = 0;
    error_interlock_cycles = 0;
    for (int lane = 0; lane < 8; lane++) begin
      cfg_bias[lane] = 0;
      cfg_multiplier[lane] = 18'sd65540;
      cfg_right_shift[lane] = 6'd24;
    end

    repeat (5) @(negedge clk);
    rst = 1'b0;
    repeat (2) @(negedge clk);
    if (!dma_descriptor_ready || configured || chunk_ready ||
        activation_ready_tensor_valid || weight_bank_state != 0 ||
        protocol_error)
      $fatal(1, "DMA-fed RS reset readiness mismatch");

    configure_datapath();
    dma_transfer(DMA_ACTIVATION_DIRECT, OUTPUT_WORDS, 16'h2000);
    dma_transfer(DMA_WEIGHT, K_COUNT, 16'h1000);
    if (activation_ready_count != 1 ||
        activation_ready_tensor_tag != 16'h2000 ||
        weight_bank_state != 2 || resident_weight_k_count != K_COUNT ||
        resident_weight_words_written != K_COUNT ||
        resident_weight_context_tag != 16'h1000)
      $fatal(1, "DMA transfers did not create real READY owners");

    inject_bad_dma_descriptor();
    random_compute_stalls = 1'b1;
    start_chunk_with_dma_interlock(0);

    fork
      dma_transfer(DMA_ACTIVATION_POOLED, OUTPUT_WORDS, 16'h2001);
      wait_for_chunk(0);
    join
    if (overlap_cycles == 0 || activation_ready_count != 1 ||
        activation_ready_tensor_tag != 16'h2001)
      $fatal(1,
             "DMA activation fill/read overlap failed cycles=%0d count=%0d tag=%0h",
             overlap_cycles, activation_ready_count,
             activation_ready_tensor_tag);

    release_weight(0);
    dma_transfer(DMA_WEIGHT, K_COUNT, 16'h1001);
    force_output_block = 1'b1;
    start_chunk(1);
    wait_for_chunk(1);
    release_weight(1);

    repeat (400) @(negedge clk);
    force_output_block = 1'b0;
    force_output_ready = 1'b1;
    random_compute_stalls = 1'b0;
    timeout = 0;
    while ((!pipeline_idle || output_packets != OUTPUT_WORDS) &&
           timeout < 200000) begin
      @(negedge clk);
      timeout = timeout + 1;
    end
    if (timeout == 200000)
      $fatal(1, "DMA-fed RS final drain timeout");

    if (dma_completed_transfers != 4 || dma_done_pulses != 4 ||
        dma_words_sent != 2 * OUTPUT_WORDS + 2 * K_COUNT ||
        axis_beats != 2 * ((OUTPUT_WORDS + 1) / 2) + K_COUNT ||
        dma_rejects != 1 || error_interlock_cycles != 6 ||
        chunk_launches != CHUNK_COUNT ||
        chunk_completions != CHUNK_COUNT ||
        transaction_completions != 1 || activation_reads != CHUNK_COUNT ||
        completed_weight_replays != CHUNK_COUNT * TILES_PER_CHUNK ||
        replay_pulses != CHUNK_COUNT * TILES_PER_CHUNK ||
        output_packets != OUTPUT_WORDS || overlap_cycles == 0 ||
        segment_transitions != CHUNK_COUNT || max_queued != FIFO_DEPTH ||
        protocol_error || dma_protocol_error || activation_context_error ||
        accum_context_error || weight_context_error || transaction_active ||
        activation_ready_count != 0 || weight_bank_state != 0)
      $fatal(1,
             "DMA-fed RS final mismatch dma=%0d/%0d words=%0d beats=%0d rejects=%0d interlock=%0d chunks=%0d/%0d tx=%0d reads=%0d replays=%0d/%0d packets=%0d overlap=%0d transitions=%0d maxq=%0d errors=%0b/%0b/%0b/%0b",
             dma_completed_transfers, dma_done_pulses, dma_words_sent,
             axis_beats, dma_rejects, error_interlock_cycles,
             chunk_launches, chunk_completions, transaction_completions,
             activation_reads, completed_weight_replays, replay_pulses,
             output_packets, overlap_cycles, segment_transitions,
             max_queued, protocol_error, activation_context_error,
             accum_context_error, weight_context_error);

    $display(
        "ALEXNET_M4N8_RS_DMA_ACTIVATION_RESIDENT_WEIGHT_DUAL_ACCUM_DATAPATH_TEST_PASSED chunks=%0d dma_transfers=%0d dma_words=%0d axis_beats=%0d tiles=%0d replays=%0d packets=%0d overlap_cycles=%0d transitions=%0d dma_rejects=%0d interlock_cycles=%0d maxq=%0d seed=%0d",
        chunk_completions, dma_completed_transfers, dma_words_sent,
        axis_beats, CHUNK_COUNT * TILES_PER_CHUNK,
        completed_weight_replays, output_packets, overlap_cycles,
        segment_transitions, dma_rejects, error_interlock_cycles,
        max_queued, seed);
    $finish;
  end

endmodule
