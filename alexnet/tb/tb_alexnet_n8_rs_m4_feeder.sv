`timescale 1ns/1ps

module tb_alexnet_n8_rs_m4_feeder;

  localparam int MAX_INPUT_WIDTH = 224;
  localparam int MAX_PIXELS = MAX_INPUT_WIDTH * MAX_INPUT_WIDTH;

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

  logic clk = 1'b0;
  logic rst;
  logic frame_valid;
  logic frame_ready;
  logic [7:0] frame_input_h;
  logic [7:0] frame_input_w;
  logic [3:0] frame_channel_count;
  logic [7:0] frame_lane_mask;
  logic [3:0] frame_kernel;
  logic [2:0] frame_stride;
  logic [2:0] frame_padding;
  logic [15:0] frame_tag;
  logic s_valid;
  logic s_ready;
  logic [63:0] s_values;
  logic [7:0] s_lane_mask;
  logic m_valid;
  logic m_ready;
  logic signed [7:0] m_act_lo [0:1];
  logic signed [7:0] m_act_hi [0:1];
  logic [1:0] m_lane_mask [0:1];
  logic m_tile_clear;
  logic m_reduce_last;
  logic [9:0] m_k;
  logic [3:0] m_input_channel;
  logic [2:0] m_count;
  logic [7:0] m_output_y;
  logic [7:0] m_output_x;
  logic [15:0] m_frame_tag;
  logic frame_active;
  logic frame_done;
  logic idle;

  logic [63:0] pixels [0:MAX_PIXELS-1];

  int current_h;
  int current_w;
  int current_channels;
  int current_kernel;
  int current_stride;
  int current_padding;
  int current_out_h;
  int current_out_w;
  int current_depth;
  int current_tag;
  int expected_y;
  int expected_x;
  int expected_k;
  int total_inputs;
  int total_tokens;
  int tested_frames;
  int max_output_stall;
  int output_stall_run;

  logic hold_active;
  logic [31:0] hold_activations;
  logic [3:0] hold_lane_mask;
  logic hold_tile_clear;
  logic hold_reduce_last;
  logic [9:0] hold_k;
  logic [3:0] hold_channel;
  logic [2:0] hold_count;
  logic [7:0] hold_y;
  logic [7:0] hold_x;
  logic [15:0] hold_tag;

  alexnet_n8_rs_m4_feeder dut (.*);

  always #2.5 clk = ~clk;

  function automatic logic [7:0] low_mask(input int count);
    if (count == 8)
      low_mask = 8'hff;
    else
      low_mask = (9'b1 << count) - 1'b1;
  endfunction

  function automatic logic [31:0] packed_activations;
    packed_activations = {
        m_act_hi[1], m_act_lo[1], m_act_hi[0], m_act_lo[0]};
  endfunction

  function automatic logic [3:0] packed_m_mask;
    packed_m_mask = {m_lane_mask[1], m_lane_mask[0]};
  endfunction

  task automatic fill_frame(input int frame_index);
    logic [63:0] pixel_word;
    int value;
    int status;
    begin
      status = alexnet_golden_window_m4_reset(
          current_h, current_w, current_channels, current_kernel,
          current_stride, current_padding);
      if (status != 0)
        $fatal(1, "window golden reset failed status=%0d", status);

      for (int y = 0; y < current_h; y++) begin
        for (int x = 0; x < current_w; x++) begin
          pixel_word = '0;
          for (int channel = 0; channel < current_channels; channel++) begin
            if (frame_index == 0)
              value = (y * 47 + x * 29 + channel * 61 + 17) & 8'hff;
            else
              value = $urandom_range(0, 255);
            pixel_word[channel*8 +: 8] = value[7:0];
          end
          pixels[y * current_w + x] = pixel_word;
          status = alexnet_golden_window_m4_set_pixel(y, x, pixel_word);
          if (status != 0)
            $fatal(1, "window golden set_pixel failed y=%0d x=%0d status=%0d",
                   y, x, status);
        end
      end
    end
  endtask

  task automatic check_output;
    int unsigned golden_activations;
    byte golden_mask;
    byte golden_clear;
    byte golden_last;
    int status;
    int expected_count;
    begin
      if (hold_active) begin
        if (!m_valid || packed_activations() != hold_activations ||
            packed_m_mask() != hold_lane_mask ||
            m_tile_clear != hold_tile_clear ||
            m_reduce_last != hold_reduce_last || m_k != hold_k ||
            m_input_channel != hold_channel || m_count != hold_count ||
            m_output_y != hold_y || m_output_x != hold_x ||
            m_frame_tag != hold_tag)
          $fatal(1, "RS feeder output changed while backpressured");
      end

      if (m_valid) begin
        if (current_out_w - expected_x >= 4)
          expected_count = 4;
        else
          expected_count = current_out_w - expected_x;
        status = alexnet_golden_window_m4_token(
            expected_y, expected_x, expected_count, expected_k,
            golden_activations, golden_mask, golden_clear, golden_last);
        if (status != 0 || packed_activations() != golden_activations ||
            packed_m_mask() != golden_mask[3:0] ||
            m_tile_clear != golden_clear[0] ||
            m_reduce_last != golden_last[0] || m_k != expected_k ||
            m_input_channel != expected_k % current_channels ||
            m_count != expected_count || m_output_y != expected_y ||
            m_output_x != expected_x || m_frame_tag != current_tag)
          $fatal(1,
                 "RS feeder mismatch y=%0d/%0d x=%0d/%0d k=%0d/%0d ic=%0d count=%0d/%0d act=%08x/%08x mask=%x/%x clear=%0b/%0b last=%0b/%0b tag=%0d/%0d status=%0d",
                 m_output_y, expected_y, m_output_x, expected_x, m_k,
                 expected_k, m_input_channel, m_count, expected_count,
                 packed_activations(), golden_activations, packed_m_mask(),
                 golden_mask[3:0], m_tile_clear, golden_clear[0],
                 m_reduce_last, golden_last[0], m_frame_tag, current_tag,
                 status);
      end

      if (m_valid && !m_ready) begin
        hold_active = 1'b1;
        hold_activations = packed_activations();
        hold_lane_mask = packed_m_mask();
        hold_tile_clear = m_tile_clear;
        hold_reduce_last = m_reduce_last;
        hold_k = m_k;
        hold_channel = m_input_channel;
        hold_count = m_count;
        hold_y = m_output_y;
        hold_x = m_output_x;
        hold_tag = m_frame_tag;
        output_stall_run = output_stall_run + 1;
        if (output_stall_run > max_output_stall)
          max_output_stall = output_stall_run;
      end else begin
        hold_active = 1'b0;
        output_stall_run = 0;
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
      input int tag);
    int input_index;
    int frame_tokens;
    int expected_tokens;
    int cycles;
    logic pending_input;
    logic input_fire;
    logic output_fire;
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
      current_tag = tag;
      expected_y = 0;
      expected_x = 0;
      expected_k = 0;
      input_index = 0;
      frame_tokens = 0;
      expected_tokens = current_out_h * ((current_out_w + 3) / 4) *
                        current_depth;
      cycles = 0;
      pending_input = 1'b0;
      done_seen = 1'b0;
      hold_active = 1'b0;
      output_stall_run = 0;
      fill_frame(frame_index);

      frame_valid = 1'b1;
      frame_input_h = height;
      frame_input_w = width;
      frame_channel_count = channels;
      frame_lane_mask = low_mask(channels);
      frame_kernel = kernel;
      frame_stride = stride;
      frame_padding = padding;
      frame_tag = tag;
      s_valid = 1'b0;
      m_ready = 1'b0;
      #1;
      if (!frame_ready)
        $fatal(1, "RS feeder frame descriptor was not accepted at idle");
      @(posedge clk);
      @(negedge clk);
      frame_valid = 1'b0;

      while (!done_seen) begin
        if (!pending_input && input_index < height * width &&
            $urandom_range(0, 4) != 0)
          pending_input = 1'b1;

        s_valid = pending_input;
        s_values = pixels[input_index];
        s_lane_mask = low_mask(channels);
        if (cycles < 19 || (cycles % 71) < 7)
          m_ready = 1'b0;
        else
          m_ready = $urandom_range(0, 4) != 0;

        #1;
        input_fire = s_valid && s_ready;
        output_fire = m_valid && m_ready;
        check_output();

        @(posedge clk);
        if (input_fire) begin
          input_index = input_index + 1;
          pending_input = 1'b0;
          total_inputs = total_inputs + 1;
        end
        if (output_fire) begin
          frame_tokens = frame_tokens + 1;
          total_tokens = total_tokens + 1;
          if (expected_k == current_depth - 1) begin
            expected_k = 0;
            if (expected_x + 4 >= current_out_w) begin
              expected_x = 0;
              expected_y = expected_y + 1;
            end else begin
              expected_x = expected_x + 4;
            end
          end else begin
            expected_k = expected_k + 1;
          end
        end
        @(negedge clk);

        if (frame_done)
          done_seen = 1'b1;
        cycles = cycles + 1;
        if (cycles > 2000000)
          $fatal(1,
                 "RS feeder frame timeout h=%0d w=%0d k=%0d s=%0d p=%0d",
                 height, width, kernel, stride, padding);
      end

      s_valid = 1'b0;
      m_ready = 1'b0;
      if (input_index != height * width || frame_tokens != expected_tokens ||
          expected_y != current_out_h || expected_x != 0 || expected_k != 0 ||
          !idle)
        $fatal(1,
               "RS feeder completion mismatch in=%0d/%0d tokens=%0d/%0d expected=%0d,%0d,%0d out_h=%0d idle=%0b",
               input_index, height * width, frame_tokens, expected_tokens,
               expected_y, expected_x, expected_k, current_out_h, idle);
      tested_frames = tested_frames + 1;
    end
  endtask

  initial begin
    int seed;
    int seed_sink;
    seed = 32'h6b2a_54d7;
    seed_sink = $urandom(seed);

    rst = 1'b1;
    frame_valid = 1'b0;
    frame_input_h = '0;
    frame_input_w = '0;
    frame_channel_count = '0;
    frame_lane_mask = '0;
    frame_kernel = '0;
    frame_stride = '0;
    frame_padding = '0;
    frame_tag = '0;
    s_valid = 1'b0;
    s_values = '0;
    s_lane_mask = '0;
    m_ready = 1'b0;
    total_inputs = 0;
    total_tokens = 0;
    tested_frames = 0;
    max_output_stall = 0;
    output_stall_run = 0;
    hold_active = 1'b0;

    repeat (5) @(negedge clk);
    rst = 1'b0;
    @(negedge clk);

    // Small K11 shape exercises conv1 ordering and an all-M3 row tail.
    run_frame(0, 16, 16, 3, 11, 4, 2, 101);
    // Actual AlexNet conv2 spatial geometry, including a final M3 per row.
    run_frame(1, 27, 27, 8, 5, 1, 2, 102);
    // Actual conv3/4/5 geometry, including a final M1 per row.
    run_frame(2, 13, 13, 8, 3, 1, 1, 103);
    // Actual conv1 geometry crosses every explicit 512-word ring-bank edge.
    run_frame(3, 224, 224, 3, 11, 4, 2, 104);

    $display(
        "ALEXNET_N8_RS_M4_FEEDER_TEST_PASSED frames=%0d inputs=%0d tokens=%0d maxstall=%0d seed=%0d",
        tested_frames, total_inputs, total_tokens, max_output_stall, seed);
    $finish;
  end

endmodule
