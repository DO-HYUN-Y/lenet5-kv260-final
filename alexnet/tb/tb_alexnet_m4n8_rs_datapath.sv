`timescale 1ns/1ps

module tb_alexnet_m4n8_rs_datapath;

  localparam int SLICE_INDEX = 2;
  localparam int FIFO_DEPTH = 64;
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
  logic frame_valid;
  logic frame_ready;
  logic [7:0] frame_input_h;
  logic [7:0] frame_input_w;
  logic [3:0] frame_channel_count;
  logic [7:0] frame_input_lane_mask;
  logic [3:0] frame_kernel;
  logic [2:0] frame_stride;
  logic [2:0] frame_padding;
  logic [15:0] frame_tag_base;
  logic s_valid;
  logic s_ready;
  logic [63:0] s_values;
  logic [7:0] s_lane_mask;
  logic weight_tile_valid;
  logic weight_tile_ready;
  logic [15:0] weight_tile_index;
  logic [2:0] weight_tile_m_count;
  logic [7:0] weight_tile_output_y;
  logic [7:0] weight_tile_output_x;
  logic [15:0] weight_tile_tag;
  logic weight_valid;
  logic weight_ready;
  logic signed [7:0] weight_values [0:7];
  logic [9:0] weight_k;
  logic weight_last;
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
  logic [15:0] completed_tile_count;
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
  int total_contexts;
  int total_weight_tokens;
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
  int expected_context_y;
  int expected_context_x;
  int frame_contexts;

  logic egress_hold_active;
  logic [63:0] egress_hold_values;
  logic [7:0] egress_hold_mask;
  logic [1:0] egress_hold_destination;
  logic [2:0] egress_hold_slice;
  logic [4:0] egress_hold_m;
  logic [15:0] egress_hold_n_base;
  logic [15:0] egress_hold_tag;
  logic context_hold_active;
  logic [15:0] context_hold_index;
  logic [2:0] context_hold_count;
  logic [7:0] context_hold_y;
  logic [7:0] context_hold_x;
  logic [15:0] context_hold_tag;

  alexnet_m4n8_rs_datapath #(
      .SLICE_INDEX(SLICE_INDEX),
      .FIFO_DEPTH(FIFO_DEPTH)
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
      input int tile_index, input int k_index, input int lane);
    int value;
    begin
      if (tile_index == 0 && k_index == 0)
        value = lane[0] ? 127 : -128;
      else
        value = ((tile_index * 17 + k_index * 11 + lane * 23) % 31) - 15;
      make_weight = value;
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
          $fatal(1, "RS datapath egress changed while backpressured");
      end

      if (egress_valid && egress_ready) begin
        if (expected_read >= expected_write)
          $fatal(1, "RS datapath emitted an unexpected packet");
        if (egress_values != expected_values[expected_read] ||
            egress_lane_mask != expected_mask[expected_read] ||
            egress_destination != expected_destination[expected_read] ||
            egress_slice != expected_slice[expected_read] ||
            egress_m != expected_m[expected_read] ||
            egress_n_base != expected_n_base[expected_read] ||
            egress_tile_tag != expected_tag[expected_read])
          $fatal(1,
                 "RS datapath packet mismatch index=%0d values=%016x/%016x mask=%02x/%02x dest=%0d/%0d slice=%0d/%0d m=%0d/%0d n=%0d/%0d tag=%0d/%0d",
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

  task automatic check_weight_context;
    begin
      if (context_hold_active) begin
        if (!weight_tile_valid || weight_tile_index != context_hold_index ||
            weight_tile_m_count != context_hold_count ||
            weight_tile_output_y != context_hold_y ||
            weight_tile_output_x != context_hold_x ||
            weight_tile_tag != context_hold_tag)
          $fatal(1, "RS datapath weight context changed while stalled");
      end

      if (weight_tile_valid && !weight_tile_ready) begin
        context_hold_active = 1'b1;
        context_hold_index = weight_tile_index;
        context_hold_count = weight_tile_m_count;
        context_hold_y = weight_tile_output_y;
        context_hold_x = weight_tile_output_x;
        context_hold_tag = weight_tile_tag;
      end else begin
        context_hold_active = 1'b0;
      end
    end
  endtask

  task automatic prepare_expected_context;
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
    int expected_count;
    longint unsigned packed_values;
    begin
      if (current_out_w - expected_context_x >= 4)
        expected_count = 4;
      else
        expected_count = current_out_w - expected_context_x;

      if (weight_tile_index != frame_contexts ||
          weight_tile_output_y != expected_context_y ||
          weight_tile_output_x != expected_context_x ||
          weight_tile_m_count != expected_count ||
          weight_tile_tag != current_tag_base + frame_contexts)
        $fatal(1,
               "RS datapath context mismatch index=%0d/%0d y=%0d/%0d x=%0d/%0d count=%0d/%0d tag=%0d/%0d",
               weight_tile_index, frame_contexts, weight_tile_output_y,
               expected_context_y, weight_tile_output_x, expected_context_x,
               weight_tile_m_count, expected_count, weight_tile_tag,
               current_tag_base + frame_contexts);

      for (int m = 0; m < 4; m++)
        for (int lane = 0; lane < 8; lane++)
          accumulator[m][lane] = 0;

      for (int k = 0; k < current_depth; k++) begin
        status = alexnet_golden_window_m4_token(
            expected_context_y, expected_context_x, expected_count, k,
            activations, golden_m_mask, golden_clear, golden_last);
        if (status != 0 || golden_m_mask[3:0] != low_mask4(expected_count) ||
            golden_clear[0] != (k == 0) ||
            golden_last[0] != (k == current_depth - 1))
          $fatal(1, "RS datapath golden window metadata failed k=%0d status=%0d",
                 k, status);

        for (int row = 0; row < 2; row++) begin
          act_lo = activations[(2*row)*8 +: 8];
          act_hi = activations[(2*row+1)*8 +: 8];
          for (int lane = 0; lane < 8; lane++) begin
            weight_byte = make_weight(frame_contexts, k, lane);
            status = alexnet_golden_packed_products(
                act_lo, act_hi, weight_byte, product_lo, product_hi);
            if (status != 0)
              $fatal(1, "RS datapath packed golden failed status=%0d", status);
            accumulator[2*row][lane] += product_lo;
            accumulator[2*row+1][lane] += product_hi;
          end
        end
      end

      for (int m = 0; m < expected_count; m++) begin
        if (expected_write >= MAX_EXPECTED)
          $fatal(1, "RS datapath expected packet queue overflow");
        packed_values = '0;
        for (int lane = 0; lane < 8; lane++) begin
          if (cfg_lane_mask[lane]) begin
            status = alexnet_golden_requantize(
                accumulator[m][lane], cfg_bias[lane], cfg_multiplier[lane],
                cfg_right_shift[lane], cfg_relu[lane], golden_result);
            if (status != 0)
              $fatal(1, "RS datapath requant golden failed status=%0d", status);
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
        expected_tag[expected_write] = current_tag_base + frame_contexts;
        expected_write = expected_write + 1;
      end

      frame_contexts = frame_contexts + 1;
      total_contexts = total_contexts + 1;
      if (expected_context_x + 4 >= current_out_w) begin
        expected_context_x = 0;
        expected_context_y = expected_context_y + 1;
      end else begin
        expected_context_x = expected_context_x + 4;
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

  task automatic fill_frame(input int frame_index);
    logic [63:0] pixel_word;
    int value;
    int status;
    begin
      status = alexnet_golden_window_m4_reset(
          current_h, current_w, current_channels, current_kernel,
          current_stride, current_padding);
      if (status != 0)
        $fatal(1, "RS datapath window reset failed status=%0d", status);

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
            $fatal(1, "RS datapath window pixel failed status=%0d", status);
        end
      end
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
      input int tag_base);
    int input_index;
    int weight_index;
    int frame_weight_tokens;
    int expected_tiles;
    int expected_packets_before;
    int cycles;
    logic pending_input;
    logic pending_weight;
    logic weight_active;
    logic input_fire;
    logic context_fire;
    logic weight_fire;
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
      expected_context_y = 0;
      expected_context_x = 0;
      frame_contexts = 0;
      input_index = 0;
      weight_index = 0;
      frame_weight_tokens = 0;
      expected_tiles = current_out_h * ((current_out_w + 3) / 4);
      expected_packets_before = expected_write;
      cycles = 0;
      pending_input = 1'b0;
      pending_weight = 1'b0;
      weight_active = 1'b0;
      done_seen = 1'b0;
      egress_hold_active = 1'b0;
      context_hold_active = 1'b0;
      fill_frame(frame_index);

      frame_valid = 1'b1;
      frame_input_h = height;
      frame_input_w = width;
      frame_channel_count = channels;
      frame_input_lane_mask = low_mask8(channels);
      frame_kernel = kernel;
      frame_stride = stride;
      frame_padding = padding;
      frame_tag_base = tag_base;
      s_valid = 1'b0;
      weight_valid = 1'b0;
      weight_tile_ready = 1'b0;
      egress_ready = 1'b0;
      #1;
      if (!frame_ready)
        $fatal(1, "RS datapath frame was not ready after drain");
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

        weight_tile_ready = ($urandom_range(0, 3) != 0);
        if (weight_active && !pending_weight &&
            $urandom_range(0, 3) != 0)
          pending_weight = 1'b1;
        weight_valid = pending_weight;
        weight_k = weight_index;
        weight_last = weight_index == current_depth - 1;
        for (int lane = 0; lane < 8; lane++)
          weight_values[lane] = make_weight(frame_contexts - 1,
                                            weight_index, lane);

        if (cycles < 41 || (cycles % 97) < 11)
          egress_ready = 1'b0;
        else
          egress_ready = ($urandom_range(0, 4) != 0);

        #1;
        input_fire = s_valid && s_ready;
        context_fire = weight_tile_valid && weight_tile_ready;
        weight_fire = weight_valid && weight_ready;
        check_weight_context();
        check_egress();

        @(posedge clk);
        if (input_fire) begin
          input_index = input_index + 1;
          pending_input = 1'b0;
        end
        if (context_fire) begin
          if (weight_active)
            $fatal(1, "RS datapath opened a weight context before K completion");
          prepare_expected_context();
          weight_index = 0;
          pending_weight = 1'b0;
          weight_active = 1'b1;
        end
        if (weight_fire) begin
          pending_weight = 1'b0;
          frame_weight_tokens = frame_weight_tokens + 1;
          total_weight_tokens = total_weight_tokens + 1;
          if (weight_index == current_depth - 1) begin
            weight_active = 1'b0;
            weight_index = 0;
          end else begin
            weight_index = weight_index + 1;
          end
        end
        if (queued_count > max_queued)
          max_queued = queued_count;
        @(negedge clk);

        if (frame_done)
          done_seen = 1'b1;
        cycles = cycles + 1;
        if (cycles > 500000)
          $fatal(1, "RS datapath frame timeout");
      end

      s_valid = 1'b0;
      weight_valid = 1'b0;
      weight_tile_ready = 1'b0;
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
        cycles = cycles + 1;
      end
      if (cycles == 10000)
        $fatal(1, "RS datapath output drain timeout");

      if (input_index != height * width || weight_active || protocol_error ||
          frame_contexts != expected_tiles ||
          completed_tile_count != expected_tiles ||
          frame_weight_tokens != expected_tiles * current_depth ||
          expected_context_y != current_out_h || expected_context_x != 0 ||
          expected_write - expected_packets_before !=
              current_out_h * current_out_w)
        $fatal(1,
               "RS datapath frame count mismatch in=%0d/%0d contexts=%0d/%0d completed=%0d weights=%0d/%0d coord=%0d,%0d packets=%0d/%0d error=%0b",
               input_index, height * width, frame_contexts, expected_tiles,
               completed_tile_count, frame_weight_tokens,
               expected_tiles * current_depth, expected_context_y,
               expected_context_x, expected_write - expected_packets_before,
               current_out_h * current_out_w, protocol_error);
      tested_frames = tested_frames + 1;
    end
  endtask

  initial begin
    int seed;
    int seed_sink;
    seed = 32'h7154_2a39;
    seed_sink = $urandom(seed);

    rst = 1'b1;
    ce = 1'b1;
    cfg_valid = 1'b0;
    cfg_destination = '0;
    cfg_n64_tile_base = '0;
    cfg_lane_mask = '0;
    cfg_relu = '0;
    frame_valid = 1'b0;
    frame_input_h = '0;
    frame_input_w = '0;
    frame_channel_count = '0;
    frame_input_lane_mask = '0;
    frame_kernel = '0;
    frame_stride = '0;
    frame_padding = '0;
    frame_tag_base = '0;
    s_valid = 1'b0;
    s_values = '0;
    s_lane_mask = '0;
    weight_tile_ready = 1'b0;
    weight_valid = 1'b0;
    weight_k = '0;
    weight_last = 1'b0;
    egress_ready = 1'b0;
    expected_write = 0;
    expected_read = 0;
    configuration_count = 0;
    tested_frames = 0;
    total_contexts = 0;
    total_weight_tokens = 0;
    max_queued = 0;
    egress_hold_active = 1'b0;
    context_hold_active = 1'b0;
    for (int lane = 0; lane < 8; lane++) begin
      cfg_bias[lane] = '0;
      cfg_multiplier[lane] = 18'sd65540;
      cfg_right_shift[lane] = 6'd23;
      weight_values[lane] = '0;
    end

    repeat (5) @(negedge clk);
    rst = 1'b0;
    @(negedge clk);

    configure_datapath(0);
    run_frame(0, 5, 6, 8, 3, 1, 1, 16'h1000);
    configure_datapath(1);
    run_frame(1, 7, 7, 8, 5, 1, 2, 16'h2000);
    configure_datapath(2);
    run_frame(2, 16, 16, 3, 11, 4, 2, 16'h3000);

    if (configuration_count != 3 || tested_frames != 3 ||
        total_contexts != 27 || total_weight_tokens != 4609 ||
        expected_read != expected_write || expected_read != 88 ||
        protocol_error)
      $fatal(1,
             "RS datapath final mismatch cfg=%0d frames=%0d contexts=%0d weights=%0d packets=%0d/%0d maxq=%0d error=%0b",
             configuration_count, tested_frames, total_contexts,
             total_weight_tokens, expected_read, expected_write, max_queued,
             protocol_error);

    $display(
        "ALEXNET_M4N8_RS_DATAPATH_TEST_PASSED frames=%0d tiles=%0d k_tokens=%0d packets=%0d configs=%0d maxq=%0d seed=%0d",
        tested_frames, total_contexts, total_weight_tokens, expected_read,
        configuration_count, max_queued, seed);
    $finish;
  end

endmodule
