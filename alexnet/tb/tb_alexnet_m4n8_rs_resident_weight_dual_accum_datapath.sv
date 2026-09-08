`timescale 1ns/1ps

module tb_alexnet_m4n8_rs_resident_weight_dual_accum_datapath;

  localparam int SLICE_INDEX = 2;
  localparam int FIFO_DEPTH = 64;
  localparam int WEIGHT_DEPTH = 968;
  localparam int SEGMENT_DEPTH = 512;
  localparam int WEIGHT_COUNT_W = $clog2(WEIGHT_DEPTH + 1);
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
  localparam int CHUNK_COUNT = 12;
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

  logic s_valid;
  logic s_ready;
  logic [63:0] s_values;
  logic [7:0] s_lane_mask;

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
  logic compute_busy;
  logic transaction_active;
  logic accum_chunk_active;
  logic transaction_done;
  logic pipeline_idle;
  logic protocol_error;
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

  logic [63:0] pixels [0:INPUT_H*INPUT_W-1];
  longint signed golden_accum [0:OUTPUT_WORDS-1][0:7];
  logic [63:0] expected_values [0:MAX_EXPECTED-1];
  logic [7:0] expected_mask [0:MAX_EXPECTED-1];
  logic [1:0] expected_destination [0:MAX_EXPECTED-1];
  logic [2:0] expected_slice [0:MAX_EXPECTED-1];
  logic [4:0] expected_m [0:MAX_EXPECTED-1];
  logic [15:0] expected_n_base [0:MAX_EXPECTED-1];
  logic [15:0] expected_tag [0:MAX_EXPECTED-1];

  logic [1:0] active_destination;
  logic [15:0] active_n64_tile_base;
  logic [7:0] active_lane_mask;
  logic signed [31:0] active_bias [0:7];
  logic signed [17:0] active_multiplier [0:7];
  logic [5:0] active_right_shift [0:7];
  logic [7:0] active_relu;

  int expected_write;
  int expected_read;
  int configuration_count;
  int submitted_chunks;
  int completed_chunks;
  int completed_transactions;
  int total_fill_words;
  int total_replay_pulses;
  int total_source_words;
  int context_rejections;
  int chunks_while_cfg_pending;
  int max_queued;
  logic pending_configuration_done;
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

  alexnet_m4n8_rs_resident_weight_dual_accum_datapath #(
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
      value = ((chunk_number * 13 + y * 7 + x * 5 + channel * 3) % 15) - 7;
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
      configuration_count = 0;
      submitted_chunks = 0;
      completed_chunks = 0;
      completed_transactions = 0;
      total_fill_words = 0;
      total_replay_pulses = 0;
      total_source_words = 0;
      chunks_while_cfg_pending = 0;
      max_queued = 0;
      stalled_q <= 1'b0;
      stalled_values_q <= '0;
      stalled_mask_q <= '0;
      stalled_destination_q <= '0;
      stalled_slice_q <= '0;
      stalled_m_q <= '0;
      stalled_n_base_q <= '0;
      stalled_tag_q <= '0;
    end else begin
      if (cfg_valid && cfg_ready)
        configuration_count = configuration_count + 1;
      if (chunk_valid && chunk_ready) begin
        submitted_chunks = submitted_chunks + 1;
        if (cfg_valid)
          chunks_while_cfg_pending = chunks_while_cfg_pending + 1;
      end
      if (chunk_done)
        completed_chunks = completed_chunks + 1;
      if (transaction_done)
        completed_transactions = completed_transactions + 1;
      if (weight_write_valid && weight_write_ready)
        total_fill_words = total_fill_words + 1;
      if (weight_replay_done)
        total_replay_pulses = total_replay_pulses + 1;
      if (s_valid && s_ready)
        total_source_words = total_source_words + 1;
      if (queued_count > max_queued)
        max_queued = queued_count;

      if (stalled_q) begin
        if (!egress_valid || egress_values !== stalled_values_q ||
            egress_lane_mask !== stalled_mask_q ||
            egress_destination !== stalled_destination_q ||
            egress_slice !== stalled_slice_q || egress_m !== stalled_m_q ||
            egress_n_base !== stalled_n_base_q ||
            egress_tile_tag !== stalled_tag_q)
          $fatal(1, "resident accum output changed while stalled");
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
          $fatal(1, "resident accum emitted an unexpected packet");
        if (egress_values !== expected_values[expected_read] ||
            egress_lane_mask !== expected_mask[expected_read] ||
            egress_destination !== expected_destination[expected_read] ||
            egress_slice !== expected_slice[expected_read] ||
            egress_m !== expected_m[expected_read] ||
            egress_n_base !== expected_n_base[expected_read] ||
            egress_tile_tag !== expected_tag[expected_read])
          $fatal(1,
                 "resident accum packet mismatch index=%0d values=%016x/%016x mask=%02x/%02x dest=%0d/%0d slice=%0d/%0d m=%0d/%0d n=%0d/%0d tag=%0d/%0d",
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

  task automatic configure_datapath(input int phase);
    logic accepted;
    begin
      cfg_destination = phase == 0 ? 2'd1 : 2'd2;
      cfg_n64_tile_base = phase == 0 ? 16'd512 : 16'd1536;
      cfg_lane_mask = phase == 0 ? 8'hff : 8'h0f;
      for (int lane = 0; lane < 8; lane++) begin
        cfg_bias[lane] = (lane - 4) * (phase + 1) * 137;
        cfg_multiplier[lane] = 65540 + lane * 1200 + phase * 500;
        cfg_right_shift[lane] = 24 + (lane % 6);
        cfg_relu[lane] = ((lane + phase) % 4) == 0;
      end

      cfg_valid = 1'b1;
      accepted = 1'b0;
      while (!accepted) begin
        @(posedge clk);
        accepted = cfg_ready;
      end

      active_destination = cfg_destination;
      active_n64_tile_base = cfg_n64_tile_base;
      active_lane_mask = cfg_lane_mask;
      active_relu = cfg_relu;
      for (int lane = 0; lane < 8; lane++) begin
        active_bias[lane] = cfg_bias[lane];
        active_multiplier[lane] = cfg_multiplier[lane];
        active_right_shift[lane] = cfg_right_shift[lane];
      end

      @(negedge clk);
      cfg_valid = 1'b0;
      if (phase != 0)
        pending_configuration_done = 1'b1;
    end
  endtask

  task automatic drive_chunk_descriptor(input int chunk_number);
    begin
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

  task automatic prepare_chunk_and_oracle(input int chunk_number);
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
      status = alexnet_golden_window_m4_reset(
          INPUT_H, INPUT_W, CHANNELS, KERNEL, STRIDE, PADDING);
      if (status != 0)
        $fatal(1, "resident accum window reset failed status=%0d", status);

      for (int y = 0; y < INPUT_H; y++) begin
        for (int x = 0; x < INPUT_W; x++) begin
          pixel_word = '0;
          for (int channel = 0; channel < CHANNELS; channel++)
            pixel_word[channel*8 +: 8] =
                make_pixel_byte(chunk_number, y, x, channel);
          pixels[y * INPUT_W + x] = pixel_word;
          status = alexnet_golden_window_m4_set_pixel(y, x, pixel_word);
          if (status != 0)
            $fatal(1, "resident accum set pixel failed status=%0d", status);
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
            if (status != 0 || golden_m_mask[3:0] !=
                    ((5'b1 << m_count) - 1'b1) ||
                golden_clear[0] != (k == 0) ||
                golden_last[0] != (k == K_COUNT - 1))
              $fatal(1,
                     "resident accum golden window metadata failed chunk=%0d k=%0d status=%0d",
                     chunk_number, k, status);

            for (int row = 0; row < 2; row++) begin
              act_lo = activations[(2*row)*8 +: 8];
              act_hi = activations[(2*row+1)*8 +: 8];
              for (int lane = 0; lane < 8; lane++) begin
                weight_byte = make_weight(chunk_number, k, lane);
                status = alexnet_golden_packed_products(
                    act_lo, act_hi, weight_byte, product_lo, product_hi);
                if (status != 0)
                  $fatal(1,
                         "resident accum packed golden failed status=%0d",
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
  endtask

  task automatic build_expected_packets;
    byte golden_result;
    longint unsigned packed_values;
    int status;
    int tile_index;
    begin
      expected_write = 0;
      for (int word = 0; word < OUTPUT_WORDS; word++) begin
        if (expected_write >= MAX_EXPECTED)
          $fatal(1, "resident accum expected queue overflow");
        packed_values = '0;
        for (int lane = 0; lane < 8; lane++) begin
          if (active_lane_mask[lane]) begin
            if (golden_accum[word][lane] + $signed(active_bias[lane]) <
                    -67108864 ||
                golden_accum[word][lane] + $signed(active_bias[lane]) >
                    67108863)
              $fatal(1, "resident accum signed-27 bound exceeded");
            status = alexnet_golden_requantize(
                golden_accum[word][lane], active_bias[lane],
                active_multiplier[lane], active_right_shift[lane],
                active_relu[lane], golden_result);
            if (status != 0)
              $fatal(1, "resident accum requant failed status=%0d", status);
            packed_values[lane*8 +: 8] = golden_result;
          end
        end

        tile_index = (word / OUTPUT_W) * ((OUTPUT_W + 3) / 4) +
                     ((word % OUTPUT_W) / 4);
        expected_values[expected_write] = packed_values;
        expected_mask[expected_write] = active_lane_mask;
        expected_destination[expected_write] = active_destination;
        expected_slice[expected_write] = SLICE_INDEX;
        expected_m[expected_write] = (word % OUTPUT_W) % 4;
        expected_n_base[expected_write] =
            active_n64_tile_base + SLICE_INDEX * 8;
        expected_tag[expected_write] = 16'h4000 + tile_index;
        expected_write = expected_write + 1;
      end
    end
  endtask

  task automatic fill_weight_tile(input int chunk_number);
    logic pending_write;
    logic write_fire;
    int write_index;
    begin
      drive_chunk_descriptor(chunk_number);
      #1;
      if (weight_bank_state != 0 || weight_resident_valid ||
          !weight_fill_ready)
        $fatal(1,
               "resident accum bank not empty before fill chunk=%0d state=%0d ready=%0b",
               chunk_number, weight_bank_state, weight_fill_ready);

      weight_fill_k_count = K_COUNT;
      weight_fill_n_lane_mask = active_lane_mask;
      weight_fill_context_tag = 16'h1000 + chunk_number;
      weight_fill_valid = 1'b1;
      @(posedge clk);
      if (!weight_fill_ready)
        $fatal(1, "resident accum fill descriptor lost ready");
      @(negedge clk);
      weight_fill_valid = 1'b0;

      write_index = 0;
      pending_write = 1'b0;
      while (write_index < K_COUNT) begin
        if (!pending_write && $urandom_range(0, 5) != 0)
          pending_write = 1'b1;
        weight_write_valid = pending_write;
        weight_write_values = make_weight_word(chunk_number, write_index);
        weight_write_n_lane_mask = active_lane_mask;
        weight_write_last = write_index == K_COUNT - 1;
        #1;
        write_fire = weight_write_valid && weight_write_ready;
        if (weight_fill_ready || weight_release_ready)
          $fatal(1, "resident accum bank changed owner while filling");
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
          resident_weight_n_lane_mask != active_lane_mask ||
          resident_weight_context_tag != 16'h1000 + chunk_number)
        $fatal(1, "resident accum bank descriptor mismatch after fill");
    end
  endtask

  task automatic reject_bad_contexts(input int chunk_number);
    begin
      drive_chunk_descriptor(chunk_number);
      chunk_valid = 1'b1;
      chunk_weight_context_tag = 16'h7000 + chunk_number;
      weight_release_valid = 1'b1;
      #1;
      if (chunk_ready || weight_release_ready)
        $fatal(1, "resident accum accepted wrong weight context");
      @(posedge clk);
      @(negedge clk);
      if (!weight_context_error || chunk_frame_active)
        $fatal(1, "resident accum did not latch wrong context error");
      context_rejections = context_rejections + 1;

      chunk_weight_context_tag = 16'h1000 + chunk_number;
      chunk_k_count = K_COUNT - 1;
      #1;
      if (chunk_ready || weight_release_ready)
        $fatal(1, "resident accum accepted wrong K count");
      @(posedge clk);
      @(negedge clk);
      if (!weight_context_error || chunk_frame_active)
        $fatal(1, "resident accum lost context error");
      context_rejections = context_rejections + 1;

      chunk_valid = 1'b0;
      weight_release_valid = 1'b0;
      drive_chunk_descriptor(chunk_number);
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
        $fatal(1, "resident accum chunk lost ready");
      @(negedge clk);
      chunk_valid = 1'b0;
      if (!chunk_frame_active || !accum_chunk_active)
        $fatal(1, "resident accum accepted chunk did not activate");
    end
  endtask

  task automatic release_weight_tile(input int chunk_number);
    begin
      chunk_valid = 1'b0;
      weight_release_valid = 1'b1;
      #1;
      if (!weight_release_ready)
        $fatal(1,
               "resident accum weight not releasable after chunk=%0d state=%0d frame=%0b accum=%0b",
               chunk_number, weight_bank_state, chunk_frame_active,
               accum_chunk_active);
      @(posedge clk);
      @(negedge clk);
      weight_release_valid = 1'b0;
      #1;
      if (weight_bank_state != 0 || weight_resident_valid ||
          resident_weight_words_written != 0 || weight_context_error)
        $fatal(1, "resident accum weight release did not clear bank");
    end
  endtask

  task automatic run_chunk(input int chunk_number);
    int input_index;
    int replay_before;
    int cycles;
    logic pending_input;
    logic input_fire;
    logic done_seen;
    begin
      prepare_chunk_and_oracle(chunk_number);
      fill_weight_tile(chunk_number);
      if (chunk_number == 0 || chunk_number == 1)
        reject_bad_contexts(chunk_number);
      if (chunk_number == CHUNK_COUNT - 1) begin
        build_expected_packets();
        force_output_block = 1'b1;
      end

      replay_before = completed_weight_replays;
      input_index = 0;
      cycles = 0;
      pending_input = 1'b0;
      done_seen = 1'b0;
      start_chunk(chunk_number);

      weight_release_valid = 1'b1;
      weight_fill_valid = 1'b1;
      while (!done_seen) begin
        ce = $urandom_range(0, 15) != 0;
        if (!pending_input && input_index < INPUT_H * INPUT_W &&
            $urandom_range(0, 5) != 0)
          pending_input = 1'b1;
        s_valid = pending_input;
        if (input_index < INPUT_H * INPUT_W)
          s_values = pixels[input_index];
        else
          s_values = '0;
        s_lane_mask = 8'hff;
        #1;
        input_fire = s_valid && s_ready;
        if (weight_release_ready || weight_fill_ready)
          $fatal(1, "resident accum exposed weight owner change mid-chunk");
        if (chunk_number != CHUNK_COUNT - 1 && egress_valid)
          $fatal(1, "resident accum exposed non-final INT8 output");
        @(posedge clk);
        if (input_fire) begin
          input_index = input_index + 1;
          pending_input = 1'b0;
        end
        @(negedge clk);
        if (chunk_done)
          done_seen = 1'b1;
        cycles = cycles + 1;
        if (cycles > 100000)
          $fatal(1, "resident accum chunk timeout chunk=%0d", chunk_number);
      end

      s_valid = 1'b0;
      weight_release_valid = 1'b0;
      weight_fill_valid = 1'b0;
      ce = 1'b1;
      #1;
      if (input_index != INPUT_H * INPUT_W ||
          completed_tile_count != TILES_PER_CHUNK ||
          completed_weight_replays - replay_before != TILES_PER_CHUNK ||
          weight_bank_state != 2 || !weight_resident_valid ||
          accum_chunk_active || protocol_error || accum_context_error)
        $fatal(1,
               "resident accum chunk mismatch chunk=%0d in=%0d/%0d tiles=%0d/%0d replays=%0d/%0d bank=%0d resident=%0b accum=%0b errors=%0b/%0b",
               chunk_number, input_index, INPUT_H * INPUT_W,
               completed_tile_count, TILES_PER_CHUNK,
               completed_weight_replays - replay_before, TILES_PER_CHUNK,
               weight_bank_state, weight_resident_valid,
               accum_chunk_active, protocol_error, accum_context_error);
      if (!transaction_active)
        $fatal(1, "resident accum transaction dropped at chunk boundary");

      release_weight_tile(chunk_number);
      if (chunk_number != CHUNK_COUNT - 1 && !transaction_active)
        $fatal(1, "resident accum partial sums lost after weight release");

      $display(
          "ALEXNET_M4N8_RS_RESIDENT_WEIGHT_DUAL_ACCUM_PROGRESS chunk=%0d/%0d tiles=%0d replays=%0d source_words=%0d time=%0t",
          chunk_number + 1, CHUNK_COUNT,
          (chunk_number + 1) * TILES_PER_CHUNK,
          completed_weight_replays, total_source_words, $time);
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
    s_valid = 1'b0;
    s_values = '0;
    s_lane_mask = '0;
    egress_ready = 1'b0;
    expected_write = 0;
    context_rejections = 0;
    pending_configuration_done = 1'b0;
    force_output_block = 1'b0;
    force_output_ready = 1'b0;
    active_destination = '0;
    active_n64_tile_base = '0;
    active_lane_mask = '0;
    active_relu = '0;
    seed = 32'h72d2_c831;
    seed_sink = $urandom(seed);

    for (int lane = 0; lane < 8; lane++) begin
      cfg_bias[lane] = '0;
      cfg_multiplier[lane] = 18'sd65540;
      cfg_right_shift[lane] = 6'd24;
      active_bias[lane] = '0;
      active_multiplier[lane] = '0;
      active_right_shift[lane] = '0;
    end
    for (int word = 0; word < OUTPUT_WORDS; word++)
      for (int lane = 0; lane < 8; lane++)
        golden_accum[word][lane] = 0;

    repeat (5) @(negedge clk);
    rst = 1'b0;
    @(negedge clk);

    if (configured || chunk_ready || weight_fill_ready == 0)
      $fatal(1, "resident accum reset readiness mismatch");

    configure_datapath(0);
    run_chunk(0);

    fork
      begin
        configure_datapath(1);
      end
    join_none

    for (int chunk = 1; chunk < CHUNK_COUNT; chunk++)
      run_chunk(chunk);

    // Hold final output long enough to fill the complete 64-entry router.
    repeat (400) @(negedge clk);
    force_output_block = 1'b0;
    force_output_ready = 1'b1;
    timeout = 0;
    while ((!pipeline_idle || expected_read != expected_write ||
            !pending_configuration_done) && timeout < 200000) begin
      @(negedge clk);
      timeout = timeout + 1;
    end
    if (timeout == 200000)
      $fatal(1, "resident accum final drain timeout");

    if (configuration_count != 2 || submitted_chunks != CHUNK_COUNT ||
        completed_chunks != CHUNK_COUNT || completed_transactions != 1 ||
        completed_weight_replays != CHUNK_COUNT * TILES_PER_CHUNK ||
        total_replay_pulses != CHUNK_COUNT * TILES_PER_CHUNK ||
        total_fill_words != CHUNK_COUNT * K_COUNT ||
        total_source_words != CHUNK_COUNT * INPUT_H * INPUT_W ||
        expected_read != OUTPUT_WORDS || expected_read != expected_write ||
        context_rejections != 4 ||
        chunks_while_cfg_pending != CHUNK_COUNT - 1 ||
        max_queued != FIFO_DEPTH || protocol_error || accum_context_error ||
        weight_context_error || transaction_active ||
        weight_bank_state != 0)
      $fatal(1,
             "resident accum final mismatch cfg=%0d chunks=%0d/%0d tx=%0d tiles=%0d replays=%0d fills=%0d source=%0d packets=%0d/%0d rejects=%0d pending=%0d maxq=%0d errors=%0b/%0b/%0b txactive=%0b bank=%0d",
             configuration_count, completed_chunks, submitted_chunks,
             completed_transactions,
             CHUNK_COUNT * TILES_PER_CHUNK, completed_weight_replays,
             total_fill_words, total_source_words, expected_read,
             expected_write, context_rejections, chunks_while_cfg_pending,
             max_queued, protocol_error, accum_context_error,
             weight_context_error, transaction_active, weight_bank_state);

    $display(
        "ALEXNET_M4N8_RS_RESIDENT_WEIGHT_DUAL_ACCUM_DATAPATH_TEST_PASSED chunks=%0d tiles=%0d replays=%0d replay_words=%0d fill_words=%0d source_words=%0d packets=%0d rejects=%0d configs=%0d maxq=%0d pending_chunks=%0d seed=%0d",
        completed_chunks, CHUNK_COUNT * TILES_PER_CHUNK,
        completed_weight_replays,
        CHUNK_COUNT * TILES_PER_CHUNK * K_COUNT, total_fill_words,
        total_source_words, expected_read, context_rejections,
        configuration_count, max_queued, chunks_while_cfg_pending, seed);
    $finish;
  end

  initial begin : watchdog
    repeat (4000000) @(posedge clk);
    $fatal(1,
           "resident accum watchdog expired chunk=%0d/%0d frame=%0b tx=%0b accum=%0b bank=%0d tile=%0d replay=%0d packets=%0d/%0d",
           completed_chunks, submitted_chunks, chunk_frame_active,
           transaction_active, accum_chunk_active, weight_bank_state,
           completed_tile_count, completed_weight_replays, expected_read,
           expected_write);
  end

endmodule
