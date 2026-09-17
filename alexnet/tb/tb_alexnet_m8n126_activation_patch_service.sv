`timescale 1ns/1ps

module tb_alexnet_m8n126_activation_patch_service;
  localparam logic [31:0] ACT_A_BASE = 32'h2100_0000;
  localparam logic [31:0] ACT_B_BASE = 32'h2200_0000;

  logic clk = 1'b0;
  logic rst;
  logic request_valid, request_ready;
  logic [3:0] request_layer_id;
  logic [12:0] request_m_base;
  logic [13:0] request_k_offset;
  logic [12:0] request_k_count;
  logic [15:0] request_m_lane_mask;
  logic [15:0] request_context_tag;
  logic [31:0] activation_a_base, activation_b_base;
  logic dma_command_valid, dma_command_ready;
  logic [31:0] dma_command_address;
  logic [25:0] dma_command_length;
  logic dma_armed, dma_done, dma_error;
  logic [127:0] s_axis_tdata;
  logic [15:0] s_axis_tkeep;
  logic s_axis_tvalid, s_axis_tready, s_axis_tlast;
  logic [127:0] patch_axis_tdata;
  logic patch_axis_tvalid, patch_axis_tready, patch_axis_tlast;
  logic busy, fault, cache_load_active;
  logic [3:0] cached_layer_id;
  logic [15:0] active_context_tag;
  logic [7:0] active_m_count;
  logic [31:0] cache_loads, completed_patches, emitted_patch_words;

  int checked_words;

  alexnet_m8n126_activation_patch_service dut (.*);

  always #2.5 clk = ~clk;

  function automatic int channels(input int layer);
    case (layer)
      2: channels = 64;
      3: channels = 192;
      4: channels = 384;
      5: channels = 256;
      6: channels = 256;
      7, 8: channels = 4096;
      default: channels = 0;
    endcase
  endfunction

  function automatic int spatial(input int layer);
    case (layer)
      2: spatial = 729;
      3, 4, 5: spatial = 169;
      6: spatial = 36;
      7, 8: spatial = 1;
      default: spatial = 0;
    endcase
  endfunction

  function automatic int input_width(input int layer);
    case (layer)
      2: input_width = 27;
      3, 4, 5: input_width = 13;
      6: input_width = 6;
      default: input_width = 1;
    endcase
  endfunction

  function automatic int kernel(input int layer);
    case (layer)
      2: kernel = 5;
      3, 4, 5: kernel = 3;
      default: kernel = 1;
    endcase
  endfunction

  function automatic int cache_bytes(input int layer);
    cache_bytes = channels(layer) * spatial(layer);
  endfunction

  function automatic logic [31:0] cache_base(input int layer);
    if (layer == 2 || layer == 4 || layer == 6 || layer == 8)
      cache_base = ACT_A_BASE;
    else
      cache_base = ACT_B_BASE;
  endfunction

  function automatic logic [7:0] activation_value(
      input int layer, input int channel, input int position);
    activation_value =
        (layer * 19 + channel * 7 + position * 3 + 8'h41) & 8'hff;
  endfunction

  function automatic logic [127:0] cache_beat(
      input int layer, input int beat_index);
    logic [127:0] result;
    int byte_index;
    int word_index;
    int tile;
    int position;
    int lane;
    int channel;
    begin
      result = 0;
      for (int byte_lane = 0; byte_lane < 16; byte_lane++) begin
        byte_index = beat_index * 16 + byte_lane;
        word_index = byte_index / 8;
        lane = byte_index % 8;
        tile = word_index / spatial(layer);
        position = word_index % spatial(layer);
        channel = tile * 8 + lane;
        if (channel < channels(layer))
          result[byte_lane*8 +: 8] =
              activation_value(layer, channel, position);
      end
      return result;
    end
  endfunction

  function automatic logic [7:0] expected_patch_byte(
      input int layer, input int m_base, input int k_offset,
      input int local_k, input int lane, input int m_count);
    int global_k;
    int channel;
    int tmp;
    int ky;
    int kx;
    int out_y;
    int out_x;
    int in_y;
    int in_x;
    int position;
    begin
      expected_patch_byte = 0;
      if (lane >= m_count)
        return expected_patch_byte;
      global_k = k_offset + local_k;
      if (layer >= 2 && layer <= 5) begin
        channel = global_k % channels(layer);
        tmp = global_k / channels(layer);
        kx = tmp % kernel(layer);
        ky = tmp / kernel(layer);
        out_y = (m_base + lane) / input_width(layer);
        out_x = (m_base + lane) % input_width(layer);
        in_y = out_y + ky - 1;
        in_x = out_x + kx - 1;
        if (layer == 2) begin
          in_y = out_y + ky - 2;
          in_x = out_x + kx - 2;
        end
        if (in_y >= 0 && in_y < input_width(layer) &&
            in_x >= 0 && in_x < input_width(layer)) begin
          position = in_y * input_width(layer) + in_x;
          expected_patch_byte = activation_value(layer, channel, position);
        end
      end else if (layer == 6) begin
        channel = global_k / 36;
        position = global_k % 36;
        expected_patch_byte = activation_value(layer, channel, position);
      end else begin
        expected_patch_byte = activation_value(layer, global_k, 0);
      end
    end
  endfunction

  function automatic logic [15:0] low_mask(input int count);
    if (count == 16)
      low_mask = 16'hffff;
    else
      low_mask = (17'b1 << count) - 1'b1;
  endfunction

  task automatic accept_and_fill_cache(input int layer);
    int beats;
    begin
      while (!dma_command_valid) @(negedge clk);
      if (dma_command_address != cache_base(layer) ||
          dma_command_length != cache_bytes(layer))
        $fatal(1,
               "cache DMA command mismatch layer=%0d addr=%h/%h len=%0d/%0d",
               layer, dma_command_address, cache_base(layer),
               dma_command_length, cache_bytes(layer));
      dma_command_ready = 1'b1;
      @(posedge clk);
      @(negedge clk);
      dma_command_ready = 1'b0;
      dma_armed = 1'b1;
      @(posedge clk);
      @(negedge clk);
      dma_armed = 1'b0;

      beats = cache_bytes(layer) / 16;
      for (int beat = 0; beat < beats; beat++) begin
        s_axis_tdata = cache_beat(layer, beat);
        s_axis_tkeep = 16'hffff;
        s_axis_tlast = beat == beats-1;
        s_axis_tvalid = 1'b1;
        do @(posedge clk); while (!s_axis_tready);
        @(negedge clk);
      end
      s_axis_tvalid = 1'b0;
      s_axis_tlast = 1'b0;
      s_axis_tkeep = 0;
      dma_done = 1'b1;
      @(posedge clk);
      @(negedge clk);
      dma_done = 1'b0;
    end
  endtask

  task automatic receive_and_check_patch(
      input int layer, input int m_base, input int k_offset,
      input int k_count, input int m_count);
    logic [7:0] got;
    logic [7:0] expected;
    int accepted;
    int timeout;
    begin
      accepted = 0;
      timeout = 0;
      while (accepted < k_count) begin
        patch_axis_tready = $urandom_range(0, 5) != 0;
        #1;
        if (patch_axis_tvalid) begin
          if (patch_axis_tlast != (accepted == k_count-1))
            $fatal(1, "patch last mismatch layer=%0d k=%0d", layer,
                   accepted);
          for (int lane = 0; lane < 16; lane++) begin
            got = patch_axis_tdata[lane*8 +: 8];
            expected = expected_patch_byte(layer, m_base, k_offset,
                                           accepted, lane, m_count);
            if (got !== expected)
              $fatal(1,
                     "activation patch mismatch layer=%0d k=%0d lane=%0d got=%0d expected=%0d",
                     layer, accepted, lane, $signed(got),
                     $signed(expected));
          end
        end
        if (patch_axis_tvalid && patch_axis_tready) begin
          accepted++;
          checked_words++;
        end
        @(posedge clk);
        @(negedge clk);
        timeout++;
        if (timeout > k_count * 80 + 10000)
          $fatal(1, "patch timeout layer=%0d accepted=%0d", layer,
                 accepted);
      end
      patch_axis_tready = 1'b0;
    end
  endtask

  task automatic run_request(
      input int layer, input int m_base, input int k_offset,
      input int k_count, input int m_count, input bit expect_load);
    begin
      while (!request_ready) @(negedge clk);
      request_layer_id = layer;
      request_m_base = m_base;
      request_k_offset = k_offset;
      request_k_count = k_count;
      request_m_lane_mask = low_mask(m_count);
      request_context_tag = 16'h6000 + layer * 16 + m_count;
      request_valid = 1'b1;
      @(posedge clk);
      @(negedge clk);
      request_valid = 1'b0;
      if (expect_load)
        accept_and_fill_cache(layer);
      receive_and_check_patch(layer, m_base, k_offset, k_count, m_count);
      while (!request_ready) @(negedge clk);
      if (fault)
        $fatal(1, "activation patch service faulted after layer %0d", layer);
    end
  endtask

  initial begin
    int seed_sink;
    seed_sink = $urandom(32'h126a_c710);
    rst = 1'b1;
    request_valid = 1'b0;
    request_layer_id = 0;
    request_m_base = 0;
    request_k_offset = 0;
    request_k_count = 0;
    request_m_lane_mask = 0;
    request_context_tag = 0;
    activation_a_base = ACT_A_BASE;
    activation_b_base = ACT_B_BASE;
    dma_command_ready = 1'b0;
    dma_armed = 1'b0;
    dma_done = 1'b0;
    dma_error = 1'b0;
    s_axis_tdata = 0;
    s_axis_tkeep = 0;
    s_axis_tvalid = 1'b0;
    s_axis_tlast = 1'b0;
    patch_axis_tready = 1'b0;
    checked_words = 0;
    repeat (8) @(negedge clk);
    rst = 1'b0;
    @(negedge clk);

    run_request(2, 16, 0, 1600, 16, 1'b1);
    run_request(2, 720, 0, 1600, 9, 1'b0);
    run_request(3, 160, 0, 1728, 8, 1'b1);
    run_request(3, 168, 0, 1728, 1, 1'b0);
    run_request(4, 160, 0, 3456, 8, 1'b1);
    run_request(5, 160, 0, 2304, 8, 1'b1);
    run_request(6, 0, 8192, 1024, 1, 1'b1);
    run_request(7, 0, 0, 4096, 1, 1'b1);
    run_request(8, 0, 0, 4096, 1, 1'b1);

    if (cache_loads != 7 || completed_patches != 9 ||
        emitted_patch_words != 21632 || checked_words != 21632)
      $fatal(1,
             "activation patch aggregate mismatch loads=%0d patches=%0d emitted=%0d checked=%0d",
             cache_loads, completed_patches, emitted_patch_words,
             checked_words);
    $display("ALEXNET_M8N126_ACTIVATION_PATCH_SERVICE_TEST_PASSED loads=%0d patches=%0d words=%0d",
             cache_loads, completed_patches, checked_words);
    $finish;
  end
endmodule
