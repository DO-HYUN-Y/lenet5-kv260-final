`timescale 1ns/1ps

module tb_alexnet_m4n8_rs_resident_weight_datapath;

  localparam int SLICE_INDEX = 3;
  localparam int FIFO_DEPTH = 64;
  localparam int WEIGHT_DEPTH = 968;
  localparam int WEIGHT_COUNT_W = $clog2(WEIGHT_DEPTH + 1);
  localparam int MAX_PIXELS = 224 * 224;
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

  logic frame_valid;
  logic frame_ready;
  logic [7:0] frame_input_h;
  logic [7:0] frame_input_w;
  logic [3:0] frame_channel_count;
  logic [7:0] frame_input_lane_mask;
  logic [3:0] frame_kernel;
  logic [2:0] frame_stride;
  logic [2:0] frame_padding;
  logic [WEIGHT_COUNT_W-1:0] frame_k_count;
  logic [15:0] frame_weight_context_tag;
  logic [15:0] frame_tag_base;
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
  logic frame_active;
  logic frame_done;
  logic compute_busy;
  logic pipeline_idle;
  logic protocol_error;
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
  logic [$clog2(FIFO_DEPTH+1)-1:0] queued_count;

  logic [63:0] pixels [0:MAX_PIXELS-1];
  logic [63:0] expected_values [0:MAX_EXPECTED-1];
  logic [7:0] expected_mask [0:MAX_EXPECTED-1];
  logic [1:0] expected_destination [0:MAX_EXPECTED-1];
  logic [2:0] expected_slice [0:MAX_EXPECTED-1];
  logic [4:0] expected_m [0:MAX_EXPECTED-1];
  logic [15:0] expected_n_base [0:MAX_EXPECTED-1];
  logic [15:0] expected_tag [0:MAX_EXPECTED-1];

  int expected_write;
  int expected_read;
  int configuration_count;
  int tested_frames;
  int total_tiles;
  int total_replay_words;
  int total_weight_fill_words;
  int context_rejections;
  int max_queued;
  int current_h;
  int current_w;
  int current_channels;
  int current_kernel;
  int current_stride;
  int current_padding;
  int current_out_h;
  int current_out_w;
  int current_depth;
  int current_tag_base;
  int current_weight_context_tag;
  int current_weight_pattern;

  logic egress_hold_active;
  logic [63:0] egress_hold_values;
  logic [7:0] egress_hold_mask;
  logic [1:0] egress_hold_destination;
  logic [2:0] egress_hold_slice;
  logic [4:0] egress_hold_m;
  logic [15:0] egress_hold_n_base;
  logic [15:0] egress_hold_tag;

  alexnet_m4n8_rs_resident_weight_datapath #(
      .SLICE_INDEX(SLICE_INDEX),
      .FIFO_DEPTH(FIFO_DEPTH),
      .WEIGHT_DEPTH(WEIGHT_DEPTH)
  ) dut (.*);

  always #2.5 clk = ~clk;

  function automatic logic [7:0] low_mask8(input int count);
    if (count == 8)
      low_mask8 = 8'hff;
    else
      low_mask8 = (9'b1 << count) - 1'b1;
  endfunction

  function automatic logic [3:0] low_mask4(input int count);
    low_mask4 = (5'b1 << count) - 1'b1;
  endfunction

  function automatic logic signed [7:0] make_weight(
      input int pattern, input int k_index, input int lane);
    int value;
    begin
      if (k_index == 0)
        value = lane[0] ? 127 : -128;
      else
        value = ((pattern * 19 + k_index * 11 + lane * 23) % 31) - 15;
      make_weight = value;
    end
  endfunction

  function automatic logic [63:0] make_weight_word(
      input int pattern, input int k_index);
    logic [63:0] packed_result;
    begin
      packed_result = '0;
      for (int lane = 0; lane < 8; lane++)
        packed_result[lane*8 +: 8] = make_weight(pattern, k_index, lane);
      make_weight_word = packed_result;
    end
  endfunction

  task automatic check_egress;
    begin
      if (egress_hold_active) begin
        if (!egress_valid || egress_values != egress_hold_values ||
            egress_lane_mask != egress_hold_mask ||
            egress_destination != egress_hold_destination ||
            egress_slice != egress_hold_slice || egress_m != egress_hold_m ||
            egress_n_base != egress_hold_n_base ||
            egress_tile_tag != egress_hold_tag)
          $fatal(1, "resident RS egress changed while backpressured");
      end

      if (egress_valid && egress_ready) begin
        if (expected_read >= expected_write)
          $fatal(1, "resident RS emitted an unexpected packet");
        if (egress_values != expected_values[expected_read] ||
            egress_lane_mask != expected_mask[expected_read] ||
            egress_destination != expected_destination[expected_read] ||
            egress_slice != expected_slice[expected_read] ||
            egress_m != expected_m[expected_read] ||
            egress_n_base != expected_n_base[expected_read] ||
            egress_tile_tag != expected_tag[expected_read])
          $fatal(1,
                 "resident RS packet mismatch index=%0d values=%016x/%016x mask=%02x/%02x dest=%0d/%0d slice=%0d/%0d m=%0d/%0d n=%0d/%0d tag=%0d/%0d",
                 expected_read, egress_values, expected_values[expected_read],
                 egress_lane_mask, expected_mask[expected_read],
                 egress_destination, expected_destination[expected_read],
                 egress_slice, expected_slice[expected_read], egress_m,
                 expected_m[expected_read], egress_n_base,
                 expected_n_base[expected_read], egress_tile_tag,
                 expected_tag[expected_read]);
        expected_read = expected_read + 1;
      end

      if (egress_valid && !egress_ready) begin
        egress_hold_active = 1'b1;
        egress_hold_values = egress_values;
        egress_hold_mask = egress_lane_mask;
        egress_hold_destination = egress_destination;
        egress_hold_slice = egress_slice;
        egress_hold_m = egress_m;
        egress_hold_n_base = egress_n_base;
        egress_hold_tag = egress_tile_tag;
      end else begin
        egress_hold_active = 1'b0;
      end
    end
  endtask

  task automatic configure_datapath(input int phase);
    logic accepted;
    begin
      cfg_destination = phase == 2 ? 0 : phase + 1;
      cfg_n64_tile_base = 64 + phase * 256;
      cfg_lane_mask = phase == 0 ? 8'hff :
                      phase == 1 ? 8'h0f : 8'h01;
      for (int lane = 0; lane < 8; lane++) begin
        cfg_bias[lane] = (lane - 3) * (phase + 1) * 257;
        cfg_multiplier[lane] = 65540 + phase * 3000 + lane * 2000;
        cfg_right_shift[lane] = 23 + (lane % 8);
        cfg_relu[lane] = ((lane + phase) % 3) == 0;
      end

      cfg_valid = 1'b1;
      accepted = 1'b0;
      while (!accepted) begin
        @(posedge clk);
        accepted = cfg_ready;
      end
      configuration_count = configuration_count + 1;
      @(negedge clk);
      cfg_valid = 1'b0;
    end
  endtask

  task automatic prepare_pixels_and_oracle(input int frame_index);
    logic [63:0] pixel_word;
    int value;
    int status;
    begin
      status = alexnet_golden_window_m4_reset(
          current_h, current_w, current_channels, current_kernel,
          current_stride, current_padding);
      if (status != 0)
        $fatal(1, "resident RS window reset failed status=%0d", status);

      for (int y = 0; y < current_h; y++) begin
        for (int x = 0; x < current_w; x++) begin
          pixel_word = '0;
          for (int channel = 0; channel < current_channels; channel++) begin
            if (frame_index == 0)
              value = (y * 43 + x * 29 + channel * 67 + 11) & 8'hff;
            else
              value = $urandom_range(0, 255);
            pixel_word[channel*8 +: 8] = value[7:0];
          end
          pixels[y * current_w + x] = pixel_word;
          status = alexnet_golden_window_m4_set_pixel(y, x, pixel_word);
          if (status != 0)
            $fatal(1, "resident RS window pixel failed status=%0d", status);
        end
      end
    end
  endtask

  task automatic prepare_expected_frame;
    longint signed accumulator [0:3][0:7];
    int unsigned activations;
    byte golden_m_mask;
    byte golden_clear;
    byte golden_last;
    byte golden_result;
    byte act_lo;
    byte act_hi;
    byte weight_byte;
    int product_lo;
    int product_hi;
    int status;
    int context_index;
    int m_count;
    longint unsigned packed_values;
    begin
      context_index = 0;
      for (int output_y = 0; output_y < current_out_h; output_y++) begin
        for (int output_x = 0; output_x < current_out_w; output_x += 4) begin
          if (current_out_w - output_x >= 4)
            m_count = 4;
          else
            m_count = current_out_w - output_x;

          for (int m = 0; m < 4; m++)
            for (int lane = 0; lane < 8; lane++)
              accumulator[m][lane] = 0;

          for (int k = 0; k < current_depth; k++) begin
            status = alexnet_golden_window_m4_token(
                output_y, output_x, m_count, k, activations,
                golden_m_mask, golden_clear, golden_last);
            if (status != 0 ||
                golden_m_mask[3:0] != low_mask4(m_count) ||
                golden_clear[0] != (k == 0) ||
                golden_last[0] != (k == current_depth - 1))
              $fatal(1,
                     "resident RS golden window metadata failed k=%0d status=%0d",
                     k, status);

            for (int row = 0; row < 2; row++) begin
              act_lo = activations[(2*row)*8 +: 8];
              act_hi = activations[(2*row+1)*8 +: 8];
              for (int lane = 0; lane < 8; lane++) begin
                weight_byte = make_weight(current_weight_pattern, k, lane);
                status = alexnet_golden_packed_products(
                    act_lo, act_hi, weight_byte, product_lo, product_hi);
                if (status != 0)
                  $fatal(1, "resident RS packed golden failed status=%0d",
                         status);
                accumulator[2*row][lane] += product_lo;
                accumulator[2*row+1][lane] += product_hi;
              end
            end
          end

          for (int m = 0; m < m_count; m++) begin
            if (expected_write >= MAX_EXPECTED)
              $fatal(1, "resident RS expected packet queue overflow");
            packed_values = '0;
            for (int lane = 0; lane < 8; lane++) begin
              if (cfg_lane_mask[lane]) begin
                status = alexnet_golden_requantize(
                    accumulator[m][lane], cfg_bias[lane],
                    cfg_multiplier[lane], cfg_right_shift[lane],
                    cfg_relu[lane], golden_result);
                if (status != 0)
                  $fatal(1, "resident RS requant golden failed status=%0d",
                         status);
                packed_values[lane*8 +: 8] = golden_result;
              end
            end
            expected_values[expected_write] = packed_values;
            expected_mask[expected_write] = cfg_lane_mask;
            expected_destination[expected_write] = cfg_destination;
            expected_slice[expected_write] = SLICE_INDEX;
            expected_m[expected_write] = m;
            expected_n_base[expected_write] =
                cfg_n64_tile_base + SLICE_INDEX * 8;
            expected_tag[expected_write] = current_tag_base + context_index;
            expected_write = expected_write + 1;
          end
          context_index = context_index + 1;
        end
      end
    end
  endtask

  task automatic fill_weight_tile;
    int write_index_local;
    logic pending_write;
    logic write_fire_local;
    begin
      if (!pipeline_idle || weight_bank_state != 0 ||
          !weight_fill_ready || weight_resident_valid)
        $fatal(1, "resident RS bank was not empty before fill");

      weight_fill_valid = 1'b1;
      weight_fill_k_count = current_depth;
      weight_fill_n_lane_mask = cfg_lane_mask;
      weight_fill_context_tag = current_weight_context_tag;
      #1;
      if (!weight_fill_ready)
        $fatal(1, "resident RS weight fill descriptor was not accepted");
      @(posedge clk);
      @(negedge clk);
      weight_fill_valid = 1'b0;

      write_index_local = 0;
      pending_write = 1'b0;
      while (write_index_local < current_depth) begin
        if (!pending_write && $urandom_range(0, 4) != 0)
          pending_write = 1'b1;
        weight_write_valid = pending_write;
        weight_write_values =
            make_weight_word(current_weight_pattern, write_index_local);
        weight_write_n_lane_mask = cfg_lane_mask;
        weight_write_last = write_index_local == current_depth - 1;
        #1;
        if (weight_fill_ready || weight_release_ready)
          $fatal(1, "resident RS bank changed owner while filling");
        write_fire_local = weight_write_valid && weight_write_ready;
        @(posedge clk);
        if (write_fire_local) begin
          write_index_local = write_index_local + 1;
          total_weight_fill_words = total_weight_fill_words + 1;
          pending_write = 1'b0;
        end
        @(negedge clk);
      end
      weight_write_valid = 1'b0;
      #1;
      if (weight_bank_state != 2 || !weight_resident_valid ||
          resident_weight_k_count != current_depth ||
          resident_weight_words_written != current_depth ||
          resident_weight_n_lane_mask != cfg_lane_mask ||
          resident_weight_context_tag != current_weight_context_tag)
        $fatal(1, "resident RS bank descriptor mismatch after fill");
    end
  endtask

  task automatic drive_frame_descriptor;
    begin
      frame_input_h = current_h;
      frame_input_w = current_w;
      frame_channel_count = current_channels;
      frame_input_lane_mask = low_mask8(current_channels);
      frame_kernel = current_kernel;
      frame_stride = current_stride;
      frame_padding = current_padding;
      frame_k_count = current_depth;
      frame_weight_context_tag = current_weight_context_tag;
      frame_tag_base = current_tag_base;
    end
  endtask

  task automatic reject_bad_frame_contexts;
    begin
      drive_frame_descriptor();
      frame_valid = 1'b1;
      frame_weight_context_tag = current_weight_context_tag + 1;
      weight_release_valid = 1'b1;
      #1;
      if (frame_ready || weight_release_ready)
        $fatal(1, "resident RS accepted wrong weight context tag");
      @(posedge clk);
      @(negedge clk);
      if (!weight_context_error || frame_active)
        $fatal(1, "resident RS did not latch wrong weight context tag");
      context_rejections = context_rejections + 1;

      frame_weight_context_tag = current_weight_context_tag;
      frame_k_count = current_depth == 1 ? 2 : current_depth - 1;
      #1;
      if (frame_ready || weight_release_ready)
        $fatal(1, "resident RS accepted wrong frame K count");
      @(posedge clk);
      @(negedge clk);
      if (!weight_context_error || frame_active)
        $fatal(1, "resident RS did not retain frame context error");
      context_rejections = context_rejections + 1;

      frame_valid = 1'b0;
      weight_release_valid = 1'b0;
      drive_frame_descriptor();
    end
  endtask

  task automatic release_weight_tile;
    begin
      frame_valid = 1'b0;
      weight_release_valid = 1'b1;
      #1;
      if (!weight_release_ready)
        $fatal(1, "resident RS bank was not releasable after drain");
      @(posedge clk);
      @(negedge clk);
      weight_release_valid = 1'b0;
      #1;
      if (weight_bank_state != 0 || weight_resident_valid ||
          resident_weight_k_count != 0 ||
          resident_weight_words_written != 0 || weight_context_error)
        $fatal(1, "resident RS bank did not clear after release");
    end
  endtask

  task automatic run_frame(
      input int frame_index,
      input int height,
      input int width,
      input int channels,
      input int kernel,
      input int stride,
      input int padding,
      input int tag_base,
      input int weight_context_tag);
    int input_index;
    int expected_tiles;
    int expected_packets_before;
    int replay_count_before;
    int frame_replay_pulses;
    int cycles;
    logic pending_input;
    logic input_fire;
    logic done_seen;
    begin
      current_h = height;
      current_w = width;
      current_channels = channels;
      current_kernel = kernel;
      current_stride = stride;
      current_padding = padding;
      current_out_h = ((height + 2 * padding - kernel) / stride) + 1;
      current_out_w = ((width + 2 * padding - kernel) / stride) + 1;
      current_depth = kernel * kernel * channels;
      current_tag_base = tag_base;
      current_weight_context_tag = weight_context_tag;
      current_weight_pattern = frame_index + 5;
      expected_tiles = current_out_h * ((current_out_w + 3) / 4);
      expected_packets_before = expected_write;
      replay_count_before = completed_weight_replays;
      frame_replay_pulses = 0;
      input_index = 0;
      cycles = 0;
      pending_input = 1'b0;
      done_seen = 1'b0;
      egress_hold_active = 1'b0;

      prepare_pixels_and_oracle(frame_index);
      prepare_expected_frame();
      fill_weight_tile();
      reject_bad_frame_contexts();

      drive_frame_descriptor();
      frame_valid = 1'b1;
      s_valid = 1'b0;
      egress_ready = 1'b0;
      #1;
      if (!frame_ready)
        $fatal(1, "resident RS correct frame was not ready");
      @(posedge clk);
      @(negedge clk);
      frame_valid = 1'b0;

      while (!done_seen) begin
        ce = ($urandom_range(0, 9) != 0);
        if (!pending_input && input_index < height * width &&
            $urandom_range(0, 4) != 0)
          pending_input = 1'b1;
        s_valid = pending_input;
        s_values = pixels[input_index];
        s_lane_mask = low_mask8(channels);

        weight_release_valid = 1'b1;
        weight_fill_valid = 1'b1;
        if (cycles < 41 || (cycles % 97) < 11)
          egress_ready = 1'b0;
        else
          egress_ready = ($urandom_range(0, 4) != 0);

        #1;
        input_fire = s_valid && s_ready;
        check_egress();
        if (weight_release_ready || weight_fill_ready)
          $fatal(1, "resident RS exposed bank owner change during frame");
        if (!weight_resident_valid ||
            resident_weight_words_written != current_depth)
          $fatal(1, "resident RS lost or refilled weights during frame");

        @(posedge clk);
        if (input_fire) begin
          input_index = input_index + 1;
          pending_input = 1'b0;
        end
        if (queued_count > max_queued)
          max_queued = queued_count;
        @(negedge clk);
        if (weight_replay_done)
          frame_replay_pulses = frame_replay_pulses + 1;
        if (frame_done)
          done_seen = 1'b1;
        cycles = cycles + 1;
        if (cycles > 500000)
          $fatal(1, "resident RS frame timeout");
      end

      s_valid = 1'b0;
      weight_release_valid = 1'b0;
      weight_fill_valid = 1'b0;
      ce = 1'b1;
      egress_ready = 1'b1;
      cycles = 0;
      while ((!pipeline_idle || expected_read != expected_write) &&
             cycles < 10000) begin
        #1;
        check_egress();
        @(posedge clk);
        if (queued_count > max_queued)
          max_queued = queued_count;
        @(negedge clk);
        if (weight_replay_done)
          frame_replay_pulses = frame_replay_pulses + 1;
        cycles = cycles + 1;
      end
      if (cycles == 10000)
        $fatal(1, "resident RS output drain timeout");

      if (input_index != height * width || protocol_error ||
          completed_tile_count != expected_tiles ||
          completed_weight_replays - replay_count_before != expected_tiles ||
          frame_replay_pulses != expected_tiles ||
          resident_weight_words_written != current_depth ||
          weight_bank_state != 2 || !weight_resident_valid ||
          expected_write - expected_packets_before !=
              current_out_h * current_out_w)
        $fatal(1,
               "resident RS frame count mismatch in=%0d/%0d tiles=%0d/%0d replays=%0d/%0d pulses=%0d words=%0d/%0d packets=%0d/%0d state=%0d resident=%0b protocol=%0b",
               input_index, height * width, completed_tile_count,
               expected_tiles,
               completed_weight_replays - replay_count_before,
               expected_tiles, frame_replay_pulses,
               resident_weight_words_written, current_depth,
               expected_write - expected_packets_before,
               current_out_h * current_out_w, weight_bank_state,
               weight_resident_valid, protocol_error);

      total_tiles = total_tiles + expected_tiles;
      total_replay_words = total_replay_words + expected_tiles * current_depth;
      tested_frames = tested_frames + 1;
      release_weight_tile();
    end
  endtask

  initial begin
    int seed;
    int seed_sink;
    seed = 32'h7359_4c2d;
    seed_sink = $urandom(seed);

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
    frame_valid = 1'b0;
    frame_input_h = '0;
    frame_input_w = '0;
    frame_channel_count = '0;
    frame_input_lane_mask = '0;
    frame_kernel = '0;
    frame_stride = '0;
    frame_padding = '0;
    frame_k_count = '0;
    frame_weight_context_tag = '0;
    frame_tag_base = '0;
    s_valid = 1'b0;
    s_values = '0;
    s_lane_mask = '0;
    egress_ready = 1'b0;
    expected_write = 0;
    expected_read = 0;
    configuration_count = 0;
    tested_frames = 0;
    total_tiles = 0;
    total_replay_words = 0;
    total_weight_fill_words = 0;
    context_rejections = 0;
    max_queued = 0;
    egress_hold_active = 1'b0;
    for (int lane = 0; lane < 8; lane++) begin
      cfg_bias[lane] = '0;
      cfg_multiplier[lane] = 18'sd65540;
      cfg_right_shift[lane] = 6'd23;
    end

    repeat (5) @(negedge clk);
    rst = 1'b0;
    @(negedge clk);

    configure_datapath(0);
    run_frame(0, 5, 6, 8, 3, 1, 1, 16'h1000, 16'h0101);
    configure_datapath(1);
    run_frame(1, 7, 7, 8, 5, 1, 2, 16'h2000, 16'h0202);
    configure_datapath(2);
    run_frame(2, 16, 16, 3, 11, 4, 2, 16'h3000, 16'h0303);

    if (configuration_count != 3 || tested_frames != 3 ||
        total_tiles != 27 || completed_weight_replays != 27 ||
        total_replay_words != 4609 || total_weight_fill_words != 635 ||
        context_rejections != 6 || expected_read != expected_write ||
        expected_read != 88 || protocol_error || weight_context_error)
      $fatal(1,
             "resident RS final mismatch cfg=%0d frames=%0d tiles=%0d replays=%0d words=%0d fills=%0d rejects=%0d packets=%0d/%0d maxq=%0d protocol=%0b context=%0b",
             configuration_count, tested_frames, total_tiles,
             completed_weight_replays, total_replay_words,
             total_weight_fill_words, context_rejections, expected_read,
             expected_write, max_queued, protocol_error,
             weight_context_error);

    $display(
        "ALEXNET_M4N8_RS_RESIDENT_WEIGHT_DATAPATH_TEST_PASSED frames=%0d tiles=%0d replays=%0d replay_words=%0d fill_words=%0d rejects=%0d packets=%0d configs=%0d maxq=%0d seed=%0d",
        tested_frames, total_tiles, completed_weight_replays,
        total_replay_words, total_weight_fill_words, context_rejections,
        expected_read, configuration_count, max_queued, seed);
    $finish;
  end

endmodule
