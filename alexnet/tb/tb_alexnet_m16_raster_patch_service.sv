`timescale 1ns/1ps

module tb_alexnet_m16_raster_patch_service;
  localparam int PATCH_DEPTH = 512;
  localparam int COUNT_W = $clog2(PATCH_DEPTH + 1);

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
  logic [127:0] s_axis_tdata;
  logic [15:0] s_axis_tkeep;
  logic s_axis_tvalid, s_axis_tready, s_axis_tlast;
  logic request_valid, request_ready;
  logic [COUNT_W-1:0] request_k_count;
  logic [15:0] request_m_lane_mask, request_context_tag;
  logic patch_axis_valid, patch_axis_ready;
  logic [127:0] patch_axis_data;
  logic patch_axis_last;
  logic raster_active, frame_active, frame_done;
  logic [15:0] completed_patch_fills, completed_patch_replays;
  logic overlap_active, fault, idle;

  int overlap_cycles;
  int checked_words;

  alexnet_m16_raster_patch_service #(
      .PATCH_DEPTH(PATCH_DEPTH), .COUNT_W(COUNT_W)
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

  function automatic logic [63:0] packed_pixel(
      input int input_w, input int channels, input int tag,
      input int flat_position);
    logic [63:0] value;
    int y, x;
    begin
      value = 0;
      y = flat_position / input_w;
      x = flat_position % input_w;
      for (int channel = 0; channel < 8; channel++)
        if (channel < channels)
          value[channel*8 +: 8] = pixel_value(tag, y, x, channel);
      return value;
    end
  endfunction

  function automatic logic [15:0] m_mask_for(input int count);
    if (count >= 16)
      m_mask_for = 16'hffff;
    else
      m_mask_for = (17'b1 << count) - 1'b1;
  endfunction

  task automatic send_axis_frame(
      input int input_h, input int input_w, input int channels,
      input int tag);
    int pixels, flat, wait_cycles;
    begin
      pixels = input_h * input_w;
      flat = 0;
      while (flat < pixels) begin
        @(negedge clk);
        s_axis_tvalid = 1'b1;
        s_axis_tdata[63:0] = packed_pixel(input_w, channels, tag, flat);
        if (flat + 1 < pixels) begin
          s_axis_tdata[127:64] =
              packed_pixel(input_w, channels, tag, flat + 1);
          s_axis_tkeep = 16'hffff;
        end else begin
          s_axis_tdata[127:64] = 0;
          s_axis_tkeep = 16'h00ff;
        end
        s_axis_tlast = flat + 2 >= pixels;
        wait_cycles = 0;
        while (!s_axis_tready) begin
          @(negedge clk);
          wait_cycles++;
          if (wait_cycles > 40000)
            $fatal(1, "raster AXIS handshake timeout flat=%0d", flat);
        end
        @(posedge clk);
        flat += 2;
      end
      @(negedge clk);
      s_axis_tvalid = 1'b0;
      s_axis_tdata = 0;
      s_axis_tkeep = 0;
      s_axis_tlast = 1'b0;
    end
  endtask

  task automatic replay_and_check(
      input int input_h, input int input_w, input int channels,
      input int kernel, input int stride, input int padding,
      input int tag, input int output_w, input int output_positions,
      input int groups);
    int accepted, flat_position, output_y, output_x, output_h;
    int group_start_position, group_start_y, group_start_x;
    int group_span_capacity, group_count;
    int tmp_k, ky, kx, ic, input_y, input_x, wait_cycles;
    logic [7:0] expected, observed;
    logic [15:0] expected_mask;
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
        expected_mask = m_mask_for(group_count);

        @(negedge clk);
        request_valid = 1'b1;
        request_k_count = kernel * kernel * channels;
        request_m_lane_mask = expected_mask;
        request_context_tag = tag + group;
        wait_cycles = 0;
        while (1) begin
          @(posedge clk);
          if (request_ready)
            break;
          wait_cycles++;
          if (wait_cycles > 40000)
            $fatal(1, "patch request timeout group=%0d", group);
        end
        @(negedge clk);
        request_valid = 1'b0;

        accepted = 0;
        wait_cycles = 0;
        while (accepted < kernel * kernel * channels) begin
          patch_axis_ready = $urandom_range(0, 5) != 0;
          #1;
          if (patch_axis_valid) begin
            if (patch_axis_last !=
                (accepted == kernel*kernel*channels-1))
              $fatal(1, "patch last mismatch group=%0d k=%0d", group,
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
              observed = patch_axis_data[lane*8 +: 8];
              if (observed !== expected)
                $fatal(1,
                       "patch mismatch group=%0d k=%0d lane=%0d got=%0d expected=%0d",
                       group, accepted, lane, $signed(observed),
                       $signed(expected));
            end
          end
          if (patch_axis_valid && patch_axis_ready) begin
            accepted++;
            checked_words++;
          end
          @(posedge clk);
          @(negedge clk);
          wait_cycles++;
          if (wait_cycles > 80000)
            $fatal(1, "patch replay timeout group=%0d accepted=%0d",
                   group, accepted);
        end
        patch_axis_ready = 1'b0;
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
        send_axis_frame(input_h, input_w, channels, tag);
        replay_and_check(input_h, input_w, channels, kernel, stride,
                         padding, tag, output_w, output_positions, groups);
      join

      for (int timeout = 0; timeout < 20000; timeout++) begin
        @(negedge clk);
        if (idle)
          break;
        if (timeout == 19999)
          $fatal(1, "raster patch service did not return idle");
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
    seed_sink = $urandom(32'h16fa_1280);
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
    s_axis_tdata = 0;
    s_axis_tkeep = 0;
    s_axis_tvalid = 1'b0;
    s_axis_tlast = 1'b0;
    request_valid = 1'b0;
    request_k_count = 0;
    request_m_lane_mask = 0;
    request_context_tag = 0;
    patch_axis_ready = 1'b0;
    checked_words = 0;

    repeat (8) @(negedge clk);
    rst = 1'b0;

    run_geometry(32, 32, 3, 11, 4, 2, 16'h4100);
    run_geometry(13, 13, 8, 3, 1, 1, 16'h5200);
    run_geometry(224, 224, 3, 11, 4, 2, 16'h6300);

    if (fault || completed_patch_fills != 205 ||
        completed_patch_replays != 205 || checked_words != 71214 ||
        overlap_cycles == 0)
      $fatal(1,
             "raster patch coverage mismatch fills=%0d replays=%0d words=%0d overlap=%0d fault=%0b",
             completed_patch_fills, completed_patch_replays, checked_words,
             overlap_cycles, fault);
    $display("ALEXNET_M16_RASTER_PATCH_SERVICE_TEST_PASSED fills=%0d replays=%0d words=%0d overlap=%0d",
             completed_patch_fills, completed_patch_replays, checked_words,
             overlap_cycles);
    $finish;
  end
endmodule
