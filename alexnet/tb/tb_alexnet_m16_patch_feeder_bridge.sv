`timescale 1ns/1ps

module tb_alexnet_m16_patch_feeder_bridge;
  localparam int PATCH_DEPTH = 512;
  localparam int COUNT_W = $clog2(PATCH_DEPTH + 1);
  localparam int ADDR_W = $clog2(PATCH_DEPTH);

  logic clk = 1'b0;
  logic rst;
  logic frame_valid, frame_ready;
  logic [7:0] frame_input_h, frame_input_w;
  logic [3:0] frame_channel_count;
  logic [7:0] frame_lane_mask;
  logic [3:0] frame_kernel;
  logic [2:0] frame_stride, frame_padding;
  logic [COUNT_W-1:0] frame_k_count;
  logic [15:0] frame_tag;
  logic s_valid, s_ready;
  logic [63:0] s_values;
  logic [7:0] s_lane_mask;
  logic replay_valid, replay_ready;
  logic [COUNT_W-1:0] replay_k_count;
  logic [15:0] replay_m_lane_mask;
  logic [15:0] replay_context_tag;
  logic patch_valid, patch_ready;
  logic signed [7:0] patch_values [0:15];
  logic [ADDR_W-1:0] patch_k;
  logic patch_last;
  logic [15:0] patch_m_lane_mask, patch_context_tag;
  logic frame_active, frame_done;
  logic [15:0] completed_patch_fills, completed_patch_replays;
  logic [1:0] ready_set_mask;
  logic fill_active, replay_active, overlap_active, fault, idle;

  int overlap_cycles;
  int checked_words;

  alexnet_m16_patch_feeder_bridge #(
      .PATCH_DEPTH(PATCH_DEPTH),
      .COUNT_W(COUNT_W),
      .ADDR_W(ADDR_W)
  ) dut (.*);

  always #2.5 clk = ~clk;

  function automatic logic [7:0] pixel_value(
      input int tag, input int y, input int x, input int channel);
    pixel_value = (tag * 7 + y * 17 + x * 13 + channel * 29) & 8'hff;
  endfunction

  function automatic logic [7:0] low_mask(input int count);
    if (count == 8)
      low_mask = 8'hff;
    else
      low_mask = (9'b1 << count) - 1'b1;
  endfunction

  function automatic logic [15:0] m_mask_for(
      input int group, input int output_positions);
    int remaining;
    begin
      remaining = output_positions - group * 16;
      if (remaining >= 16)
        m_mask_for = 16'hffff;
      else if (remaining <= 0)
        m_mask_for = 0;
      else
        m_mask_for = (17'b1 << remaining) - 1'b1;
    end
  endfunction

  task automatic send_pixels(
      input int input_h, input int input_w, input int channels,
      input int tag);
    int wait_cycles;
    begin
      for (int y = 0; y < input_h; y++) begin
        for (int x = 0; x < input_w; x++) begin
          @(negedge clk);
          s_valid = 1'b1;
          s_lane_mask = low_mask(channels);
          s_values = 0;
          for (int channel = 0; channel < 8; channel++)
            if (channel < channels)
              s_values[channel*8 +: 8] =
                  pixel_value(tag, y, x, channel);
          wait_cycles = 0;
          while (!s_ready) begin
            @(negedge clk);
            wait_cycles++;
            if (wait_cycles > 20000)
              $fatal(1, "source handshake timeout y=%0d x=%0d", y, x);
          end
          @(posedge clk);
        end
      end
      @(negedge clk);
      s_valid = 1'b0;
      s_values = 0;
    end
  endtask

  task automatic replay_and_check(
      input int input_h, input int input_w, input int channels,
      input int kernel, input int stride, input int padding,
      input int tag, input int output_w, input int output_positions,
      input int groups);
    int accepted;
    int flat_position;
    int output_y, output_x;
    int output_h;
    int group_start_position, group_start_y, group_start_x;
    int group_span_capacity, group_count;
    int tmp_k, ky, kx, ic;
    int input_y, input_x;
    logic [7:0] expected;
    logic [15:0] expected_mask;
    int wait_cycles;
    begin
      output_h = output_positions / output_w;
      group_start_position = 0;
      for (int group = 0; group < groups; group++) begin
        group_start_y = group_start_position / output_w;
        group_start_x = group_start_position % output_w;
        group_span_capacity = output_w - group_start_x;
        if (group_start_y + 1 < output_h)
          group_span_capacity += output_w;
        group_count = group_span_capacity < 16 ? group_span_capacity : 16;
        expected_mask = m_mask_for(0, group_count);
        @(negedge clk);
        replay_valid = 1'b1;
        replay_k_count = kernel * kernel * channels;
        replay_m_lane_mask = expected_mask;
        replay_context_tag = tag + group;
        wait_cycles = 0;
        while (1) begin
          @(posedge clk);
          if (replay_ready)
            break;
          wait_cycles++;
          if (wait_cycles > 20000)
            $fatal(1,
                   "replay descriptor timeout group=%0d ready_sets=%b req=(%0d,%h,%h) set0=(%0d,%h,%h) set1=(%0d,%h,%h)",
                   group, ready_set_mask, replay_k_count,
                   replay_m_lane_mask, replay_context_tag,
                   dut.u_patch_pingpong.set_k_count_q[0],
                   dut.u_patch_pingpong.set_m_lane_mask_q[0],
                   dut.u_patch_pingpong.set_context_tag_q[0],
                   dut.u_patch_pingpong.set_k_count_q[1],
                   dut.u_patch_pingpong.set_m_lane_mask_q[1],
                   dut.u_patch_pingpong.set_context_tag_q[1]);
        end
        @(negedge clk);
        replay_valid = 1'b0;

        accepted = 0;
        wait_cycles = 0;
        while (accepted < kernel * kernel * channels) begin
          patch_ready = $urandom_range(0, 5) != 0;
          #1;
          if (patch_valid) begin
            if (patch_k != accepted ||
                patch_last != (accepted == kernel*kernel*channels-1) ||
                patch_m_lane_mask != expected_mask ||
                patch_context_tag != tag + group)
              $fatal(1, "patch metadata mismatch group=%0d k=%0d", group,
                     accepted);

            ic = accepted % channels;
            tmp_k = accepted / channels;
            kx = tmp_k % kernel;
            ky = tmp_k / kernel;
            for (int lane = 0; lane < 16; lane++) begin
              expected = 0;
              flat_position = group_start_position + lane;
              if (lane < group_count) begin
                output_y = flat_position / output_w;
                output_x = flat_position % output_w;
                input_y = output_y * stride + ky - padding;
                input_x = output_x * stride + kx - padding;
                if (input_y >= 0 && input_y < input_h &&
                    input_x >= 0 && input_x < input_w)
                  expected = pixel_value(tag, input_y, input_x, ic);
              end
              if (patch_values[lane] !== $signed(expected))
                $fatal(1,
                       "patch value mismatch group=%0d k=%0d lane=%0d got=%0d expected=%0d",
                       group, accepted, lane, patch_values[lane],
                       $signed(expected));
            end
          end
          if (patch_valid && patch_ready) begin
            accepted++;
            checked_words++;
          end
          @(posedge clk);
          @(negedge clk);
          wait_cycles++;
          if (wait_cycles > 40000)
            $fatal(1, "patch replay data timeout group=%0d accepted=%0d",
                   group, accepted);
        end
        patch_ready = 1'b0;
        group_start_position += group_count;
      end
    end
  endtask

  task automatic run_geometry(
      input int input_h, input int input_w, input int channels,
      input int kernel, input int stride, input int padding,
      input int tag);
    int output_h, output_w, output_positions, groups;
    begin
      output_h = (input_h + 2*padding - kernel) / stride + 1;
      output_w = (input_w + 2*padding - kernel) / stride + 1;
      output_positions = output_h * output_w;
      groups = (output_positions + 15) / 16;

      @(negedge clk);
      frame_valid = 1'b1;
      frame_input_h = input_h;
      frame_input_w = input_w;
      frame_channel_count = channels;
      frame_lane_mask = low_mask(channels);
      frame_kernel = kernel;
      frame_stride = stride;
      frame_padding = padding;
      frame_k_count = kernel * kernel * channels;
      frame_tag = tag;
      while (!frame_ready)
        @(negedge clk);
      @(posedge clk);
      @(negedge clk);
      frame_valid = 1'b0;

      fork
        send_pixels(input_h, input_w, channels, tag);
        replay_and_check(input_h, input_w, channels, kernel, stride,
                         padding, tag, output_w, output_positions, groups);
      join

      for (int timeout = 0; timeout < 10000; timeout++) begin
        @(negedge clk);
        if (!frame_active && idle)
          break;
        if (timeout == 9999)
          $fatal(1, "patch bridge did not return idle");
      end
    end
  endtask

  always_ff @(posedge clk) begin
    if (rst)
      overlap_cycles <= 0;
    else if (overlap_active)
      overlap_cycles <= overlap_cycles + 1;
  end

  initial begin
    int seed_sink;
    seed_sink = $urandom(32'h16fa_1260);
    rst = 1'b1;
    frame_valid = 1'b0;
    frame_input_h = 0;
    frame_input_w = 0;
    frame_channel_count = 0;
    frame_lane_mask = 0;
    frame_kernel = 0;
    frame_stride = 0;
    frame_padding = 0;
    frame_k_count = 0;
    frame_tag = 0;
    s_valid = 1'b0;
    s_values = 0;
    s_lane_mask = 0;
    replay_valid = 1'b0;
    replay_k_count = 0;
    replay_m_lane_mask = 0;
    replay_context_tag = 0;
    patch_ready = 1'b0;
    checked_words = 0;

    repeat (8) @(negedge clk);
    rst = 1'b0;

    // Stride-four, padding, cross-row M16 groups and a one-lane final tail.
    run_geometry(32, 32, 3, 11, 4, 2, 16'h4100);
    // Stride-one, eight input channels, cross-row groups and a nine-lane tail.
    run_geometry(13, 13, 8, 3, 1, 1, 16'h5200);

    if (fault || completed_patch_fills != 15 ||
        completed_patch_replays != 15 || checked_words != 2244 ||
        overlap_cycles == 0)
      $fatal(1,
             "patch bridge coverage mismatch fills=%0d replays=%0d words=%0d overlap=%0d fault=%0b",
             completed_patch_fills, completed_patch_replays, checked_words,
             overlap_cycles, fault);
    $display("ALEXNET_M16_PATCH_FEEDER_BRIDGE_TEST_PASSED fills=%0d replays=%0d words=%0d overlap=%0d",
             completed_patch_fills, completed_patch_replays, checked_words,
             overlap_cycles);
    $finish;
  end

endmodule
