`timescale 1ns/1ps

module tb_alexnet_m4n8_rs_activation_resident_weight_dual_accum_datapath;

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
  localparam int OUTPUT_H = 27;
  localparam int OUTPUT_W = 27;
  localparam int OUTPUT_WORDS = OUTPUT_H * OUTPUT_W;
  localparam int K_COUNT = KERNEL * KERNEL * CHANNELS;
  localparam int TILES_PER_CHUNK = OUTPUT_H * ((OUTPUT_W + 3) / 4);
  localparam int CHUNK_COUNT = 2;
  localparam int MAX_EXPECTED = 1024;

  import "DPI-C" function int alexnet_golden_window_m4_reset(
      input int input_h, input int input_w, input int channel_count,
      input int kernel, input int stride, input int padding);
  import "DPI-C" function int alexnet_golden_window_m4_set_pixel(
      input int y, input int x, input longint unsigned values);
  import "DPI-C" function int alexnet_golden_window_m4_token(
      input int output_y, input int output_x_base, input int m_count,
      input int k_index, output int unsigned activations,
      output byte m_lane_mask, output byte tile_clear,
      output byte reduce_last);
  import "DPI-C" function int alexnet_golden_packed_products(
      input byte act_lo, input byte act_hi, input byte weight,
      output int product_lo, output int product_hi);
  import "DPI-C" function int alexnet_golden_requantize(
      input int accumulator, input int bias, input int multiplier,
      input byte right_shift, input byte relu, output byte result);

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

  logic activation_fill_valid;
  logic activation_fill_ready;
  logic activation_fill_is_pooled;
  logic [ACTIVATION_COUNT_W-1:0] activation_fill_word_count;
  logic [7:0] activation_fill_lane_mask;
  logic [15:0] activation_fill_tensor_tag;
  logic activation_direct_valid;
  logic activation_direct_ready;
  logic [63:0] activation_direct_values;
  logic [7:0] activation_direct_lane_mask;
  logic activation_direct_last;
  logic activation_pooled_valid;
  logic activation_pooled_ready;
  logic [63:0] activation_pooled_values;
  logic [7:0] activation_pooled_lane_mask;
  logic activation_pooled_last;

  logic weight_fill_valid;
  logic weight_fill_ready;
  logic [WEIGHT_COUNT_W-1:0] weight_fill_k_count;
  logic [7:0] weight_fill_n_lane_mask;
  logic [15:0] weight_fill_context_tag;
  logic weight_write_valid;
  logic weight_write_ready;
  logic [63:0] weight_write_values;
  logic [7:0] weight_write_n_lane_mask;
  logic weight_write_last;
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

  logic [63:0] pixels [0:CHUNK_COUNT-1][0:INPUT_H*INPUT_W-1];
  longint signed golden_accum [0:OUTPUT_WORDS-1][0:7];
  logic [63:0] expected_values [0:MAX_EXPECTED-1];
  logic [7:0] expected_mask [0:MAX_EXPECTED-1];
  logic [1:0] expected_destination [0:MAX_EXPECTED-1];
  logic [2:0] expected_slice [0:MAX_EXPECTED-1];
  logic [4:0] expected_m [0:MAX_EXPECTED-1];
  logic [15:0] expected_n_base [0:MAX_EXPECTED-1];
  logic [15:0] expected_tag [0:MAX_EXPECTED-1];

  int expected_write;
  int expected_read;
  int submitted_chunks;
  int completed_chunks;
  int completed_transactions;
  int activation_fill_words;
  int activation_reads;
  int total_weight_words;
  int total_replay_pulses;
  int overlap_cycles;
  int segment_transitions;
  int context_rejections;
  int shape_rejections;
  int weight_rejections;
  int max_queued;
  logic previous_read_segment;
  logic saw_weight_context_error;
  logic force_output_block;
  logic force_output_ready;

  logic stalled_q;
  logic [63:0] stalled_values_q;
  logic [7:0] stalled_mask_q;
  logic [1:0] stalled_destination_q;
  logic [2:0] stalled_slice_q;
  logic [4:0] stalled_m_q;
  logic [15:0] stalled_n_base_q;
  logic [15:0] stalled_tag_q;

  alexnet_m4n8_rs_activation_resident_weight_dual_accum_datapath #(
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

  function automatic logic signed [7:0] make_pixel_byte(
      input int chunk_number, input int y, input int x, input int channel);
    int value;
    begin
      value = ((chunk_number * 17 + y * 7 + x * 5 + channel * 3) % 15) - 7;
      make_pixel_byte = value;
    end
  endfunction

  function automatic logic signed [7:0] make_weight(
      input int chunk_number, input int k_index, input int lane);
    int value;
    begin
      value = ((chunk_number * 11 + k_index * 5 + lane * 7) % 15) - 7;
      make_weight = value;
    end
  endfunction

  function automatic logic [63:0] make_weight_word(
      input int chunk_number, input int k_index);
    logic [63:0] packed_result;
    begin
      packed_result = '0;
      for (int lane = 0; lane < 8; lane++)
        packed_result[lane*8 +: 8] =
            make_weight(chunk_number, k_index, lane);
      make_weight_word = packed_result;
    end
  endfunction

  always @(negedge clk) begin
    if (rst)
      egress_ready <= 1'b0;
    else if (force_output_block)
      egress_ready <= 1'b0;
    else if (force_output_ready)
      egress_ready <= 1'b1;
    else
      egress_ready <= $urandom_range(0, 4) != 0;
  end

  always @(posedge clk) begin : scoreboard
    if (rst) begin
      expected_read = 0;
      submitted_chunks = 0;
      completed_chunks = 0;
      completed_transactions = 0;
      activation_fill_words = 0;
      activation_reads = 0;
      total_weight_words = 0;
      total_replay_pulses = 0;
      overlap_cycles = 0;
      segment_transitions = 0;
      max_queued = 0;
      previous_read_segment = 1'b0;
      saw_weight_context_error = 1'b0;
      stalled_q <= 1'b0;
      stalled_values_q <= '0;
      stalled_mask_q <= '0;
      stalled_destination_q <= '0;
      stalled_slice_q <= '0;
      stalled_m_q <= '0;
      stalled_n_base_q <= '0;
      stalled_tag_q <= '0;
    end else begin
      if (dut.launch_fire)
        submitted_chunks = submitted_chunks + 1;
      if (chunk_done)
        completed_chunks = completed_chunks + 1;
      if (transaction_done)
        completed_transactions = completed_transactions + 1;
      if ((activation_direct_valid && activation_direct_ready) ||
          (activation_pooled_valid && activation_pooled_ready))
        activation_fill_words = activation_fill_words + 1;
      if (activation_read_done) begin
        if (activation_words_forwarded != OUTPUT_WORDS)
          $fatal(1, "activation read retired with %0d/%0d words",
                 activation_words_forwarded, OUTPUT_WORDS);
        activation_reads = activation_reads + 1;
      end
      if (weight_write_valid && weight_write_ready)
        total_weight_words = total_weight_words + 1;
      if (weight_replay_done)
        total_replay_pulses = total_replay_pulses + 1;
      if (activation_fill_active && activation_read_active)
        overlap_cycles = overlap_cycles + 1;
      if (activation_read_active && !previous_read_segment &&
          activation_read_segment)
        segment_transitions = segment_transitions + 1;
      previous_read_segment = activation_read_active &&
                              activation_read_segment;
      if (weight_context_error)
        saw_weight_context_error = 1'b1;
      if (queued_count > max_queued)
        max_queued = queued_count;

      if (stalled_q) begin
        if (!egress_valid || egress_values !== stalled_values_q ||
            egress_lane_mask !== stalled_mask_q ||
            egress_destination !== stalled_destination_q ||
            egress_slice !== stalled_slice_q || egress_m !== stalled_m_q ||
            egress_n_base !== stalled_n_base_q ||
            egress_tile_tag !== stalled_tag_q)
          $fatal(1, "activation-buffered output changed while stalled");
      end

      stalled_q <= egress_valid && !egress_ready;
      if (egress_valid && !egress_ready) begin
        stalled_values_q <= egress_values;
        stalled_mask_q <= egress_lane_mask;
        stalled_destination_q <= egress_destination;
        stalled_slice_q <= egress_slice;
        stalled_m_q <= egress_m;
        stalled_n_base_q <= egress_n_base;
        stalled_tag_q <= egress_tile_tag;
      end

      if (egress_valid && egress_ready) begin
        if (expected_read >= expected_write)
          $fatal(1, "activation-buffered path emitted an unexpected packet");
        if (egress_values !== expected_values[expected_read] ||
            egress_lane_mask !== expected_mask[expected_read] ||
            egress_destination !== expected_destination[expected_read] ||
            egress_slice !== expected_slice[expected_read] ||
            egress_m !== expected_m[expected_read] ||
            egress_n_base !== expected_n_base[expected_read] ||
            egress_tile_tag !== expected_tag[expected_read])
          $fatal(1,
                 "activation-buffered packet mismatch index=%0d values=%016x/%016x mask=%02x/%02x dest=%0d/%0d slice=%0d/%0d m=%0d/%0d n=%0d/%0d tag=%0d/%0d",
                 expected_read, egress_values, expected_values[expected_read],
                 egress_lane_mask, expected_mask[expected_read],
                 egress_destination, expected_destination[expected_read],
                 egress_slice, expected_slice[expected_read], egress_m,
                 expected_m[expected_read], egress_n_base,
                 expected_n_base[expected_read], egress_tile_tag,
                 expected_tag[expected_read]);
        expected_read = expected_read + 1;
      end
    end
  end

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

  task automatic configure_datapath;
    logic accepted;
    begin
      cfg_destination = 2'd1;
      cfg_n64_tile_base = 16'd1024;
      cfg_lane_mask = 8'hff;
      for (int lane = 0; lane < 8; lane++) begin
        cfg_bias[lane] = (lane - 4) * 97;
        cfg_multiplier[lane] = 65540 + lane * 1100;
        cfg_right_shift[lane] = 24 + (lane % 6);
        cfg_relu[lane] = lane == 3;
      end
      cfg_valid = 1'b1;
      accepted = 1'b0;
      while (!accepted) begin
        @(posedge clk);
        accepted = cfg_ready;
      end
      @(negedge clk);
      cfg_valid = 1'b0;
    end
  endtask

  task automatic prepare_oracle;
    logic [63:0] pixel_word;
    int unsigned activations;
    byte golden_m_mask;
    byte golden_clear;
    byte golden_last;
    byte act_lo;
    byte act_hi;
    byte weight_byte;
    int product_lo;
    int product_hi;
    int status;
    int m_count;
    int word_index;
    begin
      for (int word = 0; word < OUTPUT_WORDS; word++)
        for (int lane = 0; lane < 8; lane++)
          golden_accum[word][lane] = 0;

      for (int chunk = 0; chunk < CHUNK_COUNT; chunk++) begin
        status = alexnet_golden_window_m4_reset(
            INPUT_H, INPUT_W, CHANNELS, KERNEL, STRIDE, PADDING);
        if (status != 0)
          $fatal(1, "activation-buffered window reset failed status=%0d",
                 status);

        for (int y = 0; y < INPUT_H; y++) begin
          for (int x = 0; x < INPUT_W; x++) begin
            pixel_word = '0;
            for (int channel = 0; channel < CHANNELS; channel++)
              pixel_word[channel*8 +: 8] =
                  make_pixel_byte(chunk, y, x, channel);
            pixels[chunk][y * INPUT_W + x] = pixel_word;
            status = alexnet_golden_window_m4_set_pixel(y, x, pixel_word);
            if (status != 0)
              $fatal(1, "activation-buffered set pixel failed status=%0d",
                     status);
          end
        end

        for (int output_y = 0; output_y < OUTPUT_H; output_y++) begin
          for (int output_x = 0; output_x < OUTPUT_W; output_x += 4) begin
            if (OUTPUT_W - output_x >= 4)
              m_count = 4;
            else
              m_count = OUTPUT_W - output_x;

            for (int k = 0; k < K_COUNT; k++) begin
              status = alexnet_golden_window_m4_token(
                  output_y, output_x, m_count, k, activations,
                  golden_m_mask, golden_clear, golden_last);
              if (status != 0 ||
                  golden_m_mask[3:0] != ((5'b1 << m_count) - 1'b1) ||
                  golden_clear[0] != (k == 0) ||
                  golden_last[0] != (k == K_COUNT - 1))
                $fatal(1,
                       "activation-buffered golden metadata failed chunk=%0d k=%0d status=%0d",
                       chunk, k, status);

              for (int row = 0; row < 2; row++) begin
                act_lo = activations[(2*row)*8 +: 8];
                act_hi = activations[(2*row+1)*8 +: 8];
                for (int lane = 0; lane < 8; lane++) begin
                  weight_byte = make_weight(chunk, k, lane);
                  status = alexnet_golden_packed_products(
                      act_lo, act_hi, weight_byte, product_lo, product_hi);
                  if (status != 0)
                    $fatal(1,
                           "activation-buffered packed golden failed status=%0d",
                           status);
                  if (2*row < m_count) begin
                    word_index = output_y * OUTPUT_W + output_x + 2*row;
                    golden_accum[word_index][lane] += product_lo;
                  end
                  if (2*row + 1 < m_count) begin
                    word_index = output_y * OUTPUT_W + output_x + 2*row + 1;
                    golden_accum[word_index][lane] += product_hi;
                  end
                end
              end
            end
          end
        end
      end
    end
  endtask

  task automatic build_expected_packets;
    byte golden_result;
    longint unsigned packed_values;
    int status;
    int tile_index;
    begin
      expected_write = 0;
      for (int word = 0; word < OUTPUT_WORDS; word++) begin
        packed_values = '0;
        for (int lane = 0; lane < 8; lane++) begin
          status = alexnet_golden_requantize(
              golden_accum[word][lane], cfg_bias[lane],
              cfg_multiplier[lane], cfg_right_shift[lane],
              cfg_relu[lane], golden_result);
          if (status != 0)
            $fatal(1, "activation-buffered requant failed status=%0d",
                   status);
          packed_values[lane*8 +: 8] = golden_result;
        end
        tile_index = (word / OUTPUT_W) * ((OUTPUT_W + 3) / 4) +
                     ((word % OUTPUT_W) / 4);
        expected_values[expected_write] = packed_values;
        expected_mask[expected_write] = cfg_lane_mask;
        expected_destination[expected_write] = cfg_destination;
        expected_slice[expected_write] = SLICE_INDEX;
        expected_m[expected_write] = (word % OUTPUT_W) % 4;
        expected_n_base[expected_write] =
            cfg_n64_tile_base + SLICE_INDEX * 8;
        expected_tag[expected_write] = 16'h4000 + tile_index;
        expected_write = expected_write + 1;
      end
    end
  endtask

  task automatic fill_activation(input int chunk_number,
                                 input logic pooled_source);
    logic pending_word;
    logic word_fire;
    int word_index;
    begin
      activation_fill_is_pooled = pooled_source;
      activation_fill_word_count = OUTPUT_WORDS;
      activation_fill_lane_mask = 8'hff;
      activation_fill_tensor_tag = 16'h2000 + chunk_number;
      activation_fill_valid = 1'b0;
      #1;
      while (!activation_fill_ready)
        @(negedge clk);
      activation_fill_valid = 1'b1;
      @(posedge clk);
      if (!activation_fill_ready)
        $fatal(1, "activation fill descriptor lost ready chunk=%0d",
               chunk_number);
      @(negedge clk);
      activation_fill_valid = 1'b0;

      word_index = 0;
      pending_word = 1'b0;
      while (word_index < OUTPUT_WORDS) begin
        if (!pending_word && $urandom_range(0, 5) != 0)
          pending_word = 1'b1;
        activation_direct_valid = pending_word && !pooled_source;
        activation_direct_values = pixels[chunk_number][word_index];
        activation_direct_lane_mask = 8'hff;
        activation_direct_last = word_index == OUTPUT_WORDS - 1;
        activation_pooled_valid = pending_word && pooled_source;
        activation_pooled_values = pixels[chunk_number][word_index];
        activation_pooled_lane_mask = 8'hff;
        activation_pooled_last = word_index == OUTPUT_WORDS - 1;
        #1;
        if (pooled_source)
          word_fire = activation_pooled_valid && activation_pooled_ready;
        else
          word_fire = activation_direct_valid && activation_direct_ready;
        @(posedge clk);
        if (word_fire) begin
          word_index = word_index + 1;
          pending_word = 1'b0;
        end
        @(negedge clk);
      end
      activation_direct_valid = 1'b0;
      activation_pooled_valid = 1'b0;
      #1;
      if (!activation_ready_tensor_valid)
        $fatal(1, "activation tensor did not enter READY queue chunk=%0d",
               chunk_number);
    end
  endtask

  task automatic fill_weight_tile(input int chunk_number);
    logic pending_write;
    logic write_fire;
    int write_index;
    begin
      drive_chunk_descriptor(chunk_number);
      weight_fill_k_count = K_COUNT;
      weight_fill_n_lane_mask = cfg_lane_mask;
      weight_fill_context_tag = 16'h1000 + chunk_number;
      weight_fill_valid = 1'b0;
      #1;
      while (!weight_fill_ready)
        @(negedge clk);
      weight_fill_valid = 1'b1;
      @(posedge clk);
      if (!weight_fill_ready)
        $fatal(1, "weight fill descriptor lost ready chunk=%0d",
               chunk_number);
      @(negedge clk);
      weight_fill_valid = 1'b0;

      write_index = 0;
      pending_write = 1'b0;
      while (write_index < K_COUNT) begin
        if (!pending_write && $urandom_range(0, 5) != 0)
          pending_write = 1'b1;
        weight_write_valid = pending_write;
        weight_write_values = make_weight_word(chunk_number, write_index);
        weight_write_n_lane_mask = cfg_lane_mask;
        weight_write_last = write_index == K_COUNT - 1;
        #1;
        write_fire = weight_write_valid && weight_write_ready;
        @(posedge clk);
        if (write_fire) begin
          write_index = write_index + 1;
          pending_write = 1'b0;
        end
        @(negedge clk);
      end
      weight_write_valid = 1'b0;
      #1;
      if (weight_bank_state != 2 || !weight_resident_valid ||
          resident_weight_k_count != K_COUNT ||
          resident_weight_words_written != K_COUNT ||
          resident_weight_context_tag != 16'h1000 + chunk_number)
        $fatal(1, "resident weight descriptor mismatch chunk=%0d",
               chunk_number);
    end
  endtask

  task automatic reject_bad_launches;
    begin
      drive_chunk_descriptor(0);
      chunk_activation_tensor_tag = 16'h2bad;
      while (!chunk_ready)
        @(negedge clk);
      chunk_valid = 1'b1;
      @(posedge clk);
      @(negedge clk);
      chunk_valid = 1'b0;
      while (!chunk_rejected)
        @(negedge clk);
      if (!activation_context_error || activation_read_active ||
          chunk_frame_active)
        $fatal(1, "wrong activation tag did not latch context error");
      context_rejections = context_rejections + 1;

      drive_chunk_descriptor(0);
      chunk_input_w = INPUT_W - 1;
      while (!chunk_ready)
        @(negedge clk);
      chunk_valid = 1'b1;
      @(posedge clk);
      @(negedge clk);
      chunk_valid = 1'b0;
      while (!chunk_rejected)
        @(negedge clk);
      if (!protocol_error || activation_read_active || chunk_frame_active)
        $fatal(1, "wrong activation shape did not latch protocol error");
      shape_rejections = shape_rejections + 1;

      drive_chunk_descriptor(0);
      chunk_weight_context_tag = 16'h1bad;
      while (!chunk_ready)
        @(negedge clk);
      chunk_valid = 1'b1;
      @(posedge clk);
      @(negedge clk);
      chunk_valid = 1'b0;
      while (!chunk_rejected)
        @(negedge clk);
      if (!weight_context_error || activation_read_active ||
          chunk_frame_active)
        $fatal(1, "wrong weight context did not latch context error");
      weight_rejections = weight_rejections + 1;

      drive_chunk_descriptor(0);
    end
  endtask

  task automatic start_chunk(input int chunk_number);
    begin
      drive_chunk_descriptor(chunk_number);
      while (!chunk_ready)
        @(negedge clk);
      chunk_valid = 1'b1;
      @(posedge clk);
      if (!chunk_ready)
        $fatal(1, "activation-buffered launch lost ready chunk=%0d",
               chunk_number);
      @(negedge clk);
      chunk_valid = 1'b0;
      while (!chunk_frame_active)
        @(negedge clk);
      if (!chunk_frame_active || !activation_read_active ||
          !accum_chunk_active)
        $fatal(1, "activation-buffered launch was not atomic chunk=%0d",
               chunk_number);
    end
  endtask

  task automatic wait_for_chunk(input int chunk_number);
    int cycles;
    logic done_seen;
    begin
      cycles = 0;
      done_seen = 1'b0;
      weight_release_valid = 1'b1;
      weight_fill_valid = 1'b1;
      while (!done_seen) begin
        ce = $urandom_range(0, 15) != 0;
        #1;
        if (weight_release_ready || weight_fill_ready)
          $fatal(1, "weight owner changed during active chunk=%0d",
                 chunk_number);
        @(posedge clk);
        @(negedge clk);
        if (chunk_done)
          done_seen = 1'b1;
        cycles = cycles + 1;
        if (cycles > 150000)
          $fatal(1, "activation-buffered chunk timeout chunk=%0d",
                 chunk_number);
      end
      weight_release_valid = 1'b0;
      weight_fill_valid = 1'b0;
      ce = 1'b1;
      #1;
      if (activation_words_forwarded != OUTPUT_WORDS ||
          completed_tile_count != TILES_PER_CHUNK ||
          weight_bank_state != 2 || activation_read_active ||
          accum_chunk_active || accum_context_error)
        $fatal(1,
               "activation-buffered chunk mismatch chunk=%0d words=%0d/%0d tiles=%0d/%0d weight=%0d aread=%0b accum=%0b error=%0b",
               chunk_number, activation_words_forwarded, OUTPUT_WORDS,
               completed_tile_count, TILES_PER_CHUNK, weight_bank_state,
               activation_read_active, accum_chunk_active,
               accum_context_error);
    end
  endtask

  task automatic release_weight_tile(input int chunk_number);
    begin
      weight_release_valid = 1'b1;
      while (!weight_release_ready)
        @(negedge clk);
      @(posedge clk);
      @(negedge clk);
      weight_release_valid = 1'b0;
      #1;
      if (weight_bank_state != 0 || weight_resident_valid)
        $fatal(1, "weight release failed chunk=%0d", chunk_number);
    end
  endtask

  initial begin
    int seed;
    int seed_sink;
    int timeout;

    rst = 1'b1;
    ce = 1'b1;
    cfg_valid = 1'b0;
    cfg_destination = '0;
    cfg_n64_tile_base = '0;
    cfg_lane_mask = '0;
    cfg_relu = '0;
    activation_fill_valid = 1'b0;
    activation_fill_is_pooled = 1'b0;
    activation_fill_word_count = '0;
    activation_fill_lane_mask = '0;
    activation_fill_tensor_tag = '0;
    activation_direct_valid = 1'b0;
    activation_direct_values = '0;
    activation_direct_lane_mask = '0;
    activation_direct_last = 1'b0;
    activation_pooled_valid = 1'b0;
    activation_pooled_values = '0;
    activation_pooled_lane_mask = '0;
    activation_pooled_last = 1'b0;
    weight_fill_valid = 1'b0;
    weight_fill_k_count = '0;
    weight_fill_n_lane_mask = '0;
    weight_fill_context_tag = '0;
    weight_write_valid = 1'b0;
    weight_write_values = '0;
    weight_write_n_lane_mask = '0;
    weight_write_last = 1'b0;
    weight_release_valid = 1'b0;
    chunk_valid = 1'b0;
    drive_chunk_descriptor(0);
    egress_ready = 1'b0;
    expected_write = 0;
    context_rejections = 0;
    shape_rejections = 0;
    weight_rejections = 0;
    force_output_block = 1'b0;
    force_output_ready = 1'b0;
    seed = 32'h75a2_c941;
    seed_sink = $urandom(seed);

    for (int lane = 0; lane < 8; lane++) begin
      cfg_bias[lane] = '0;
      cfg_multiplier[lane] = 18'sd65540;
      cfg_right_shift[lane] = 6'd24;
    end

    prepare_oracle();
    repeat (5) @(negedge clk);
    rst = 1'b0;
    @(negedge clk);

    if (configured || chunk_ready || !weight_fill_ready ||
        activation_ready_tensor_valid)
      $fatal(1, "activation-buffered reset readiness mismatch");

    configure_datapath();
    build_expected_packets();
    fill_activation(0, 1'b0);
    fill_weight_tile(0);
    reject_bad_launches();
    start_chunk(0);

    fork
      fill_activation(1, 1'b1);
      wait_for_chunk(0);
    join

    if (overlap_cycles == 0 || activation_ready_count != 1 ||
        activation_ready_tensor_tag != 16'h2001)
      $fatal(1,
             "activation A/B overlap failed cycles=%0d count=%0d tag=%0h",
             overlap_cycles, activation_ready_count,
             activation_ready_tensor_tag);

    release_weight_tile(0);
    fill_weight_tile(1);
    force_output_block = 1'b1;
    start_chunk(1);
    wait_for_chunk(1);
    release_weight_tile(1);

    repeat (400) @(negedge clk);
    force_output_block = 1'b0;
    force_output_ready = 1'b1;
    timeout = 0;
    while ((!pipeline_idle || expected_read != expected_write) &&
           timeout < 200000) begin
      @(negedge clk);
      timeout = timeout + 1;
    end
    if (timeout == 200000)
      $fatal(1, "activation-buffered final drain timeout");

    if (submitted_chunks != CHUNK_COUNT ||
        completed_chunks != CHUNK_COUNT || completed_transactions != 1 ||
        activation_fill_words != CHUNK_COUNT * OUTPUT_WORDS ||
        activation_reads != CHUNK_COUNT ||
        total_weight_words != CHUNK_COUNT * K_COUNT ||
        completed_weight_replays != CHUNK_COUNT * TILES_PER_CHUNK ||
        total_replay_pulses != CHUNK_COUNT * TILES_PER_CHUNK ||
        expected_read != OUTPUT_WORDS || expected_read != expected_write ||
        context_rejections != 1 || shape_rejections != 1 ||
        weight_rejections != 1 || !activation_context_error ||
        !protocol_error || !saw_weight_context_error ||
        dut.activation_storage_protocol_error || dut.core_protocol_error ||
        accum_context_error || transaction_active ||
        activation_ready_count != 0 || weight_bank_state != 0 ||
        overlap_cycles == 0 || segment_transitions != CHUNK_COUNT ||
        max_queued != FIFO_DEPTH)
      $fatal(1,
             "activation-buffered final mismatch chunks=%0d/%0d tx=%0d afill=%0d aread=%0d wfill=%0d replay=%0d/%0d packets=%0d/%0d rejects=%0d/%0d/%0d errors=%0b/%0b/%0b overlap=%0d transitions=%0d maxq=%0d",
             completed_chunks, submitted_chunks, completed_transactions,
             activation_fill_words, activation_reads, total_weight_words,
             completed_weight_replays, total_replay_pulses, expected_read,
             expected_write, context_rejections, shape_rejections,
             weight_rejections, activation_context_error, protocol_error,
             accum_context_error, overlap_cycles, segment_transitions,
             max_queued);

    $display(
        "ALEXNET_M4N8_RS_ACTIVATION_RESIDENT_WEIGHT_DUAL_ACCUM_DATAPATH_TEST_PASSED chunks=%0d activation_words=%0d tiles=%0d replays=%0d replay_words=%0d weight_words=%0d packets=%0d overlap_cycles=%0d transitions=%0d rejects=%0d maxq=%0d seed=%0d",
        completed_chunks, activation_fill_words,
        CHUNK_COUNT * TILES_PER_CHUNK, completed_weight_replays,
        CHUNK_COUNT * TILES_PER_CHUNK * K_COUNT, total_weight_words,
        expected_read, overlap_cycles, segment_transitions,
        context_rejections + shape_rejections + weight_rejections,
        max_queued, seed);
    $finish;
  end

  initial begin : watchdog
    repeat (1000000) @(posedge clk);
    $fatal(1,
           "activation-buffered watchdog expired chunks=%0d/%0d configured=%0b cfg_ready=%0b frame=%0b afill_ready=%0b afill=%0b awords=%0d child_words=%0d seg1=%0b src_valid=%0b src_ok=%0b child_ready=%0b direct=%0b/%0b/%0b pooled=%0b/%0b/%0b aready=%0d aread=%0b weight_fill_ready=%0b tx=%0b bank=%0d tiles=%0d replays=%0d packets=%0d/%0d",
           completed_chunks, submitted_chunks, configured, cfg_ready,
           chunk_frame_active, activation_fill_ready,
           activation_fill_active, activation_fill_words,
           dut.u_activation.fill_words_accepted_q,
           dut.u_activation.fill_in_segment1,
           dut.u_activation.selected_source_valid,
           dut.u_activation.selected_source_ok,
           dut.u_activation.selected_child_write_ready,
           activation_direct_valid, activation_direct_ready,
           activation_direct_last, activation_pooled_valid,
           activation_pooled_ready, activation_pooled_last,
           activation_ready_count, activation_read_active,
           weight_fill_ready, transaction_active,
           weight_bank_state, completed_tile_count,
           completed_weight_replays, expected_read, expected_write);
  end

endmodule
