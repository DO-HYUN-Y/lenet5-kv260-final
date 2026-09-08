`timescale 1ns/1ps

module tb_alexnet_conv_result_pool_service;
  logic clk = 1'b0;
  logic rst;
  logic layer_valid, layer_ready;
  logic [2:0] layer_id;
  logic [15:0] layer_job_tag;
  logic [7:0] layer_raw_h, layer_raw_w;
  logic [5:0] layer_n8_tiles;
  logic layer_pool_enable;
  logic [5:0] layer_stored_h, layer_stored_w;
  logic [127:0] s_axis_tdata;
  logic [15:0] s_axis_tkeep;
  logic s_axis_tvalid, s_axis_tready, s_axis_tlast;
  logic [127:0] m_axis_tdata;
  logic [15:0] m_axis_tkeep;
  logic m_axis_tvalid, m_axis_tready, m_axis_tlast;
  logic layer_done;
  logic [2:0] completed_layer_id;
  logic [15:0] completed_job_tag;
  logic layer_error, busy, fault;
  logic [31:0] raw_words_accepted, stored_words_transferred;
  logic [5:0] input_tiles_completed, output_tiles_completed;

  int total_raw_words;
  int total_stored_words;
  int completed_layers;
  int max_output_stall;
  int output_stall_run;
  logic hold_active;
  logic [127:0] hold_data;
  logic [15:0] hold_keep;
  logic hold_last;

  alexnet_conv_result_pool_service dut (.*);

  always #2.5 clk = ~clk;

  function automatic logic [63:0] make_word(
      input int layer,
      input int tile,
      input int word_index,
      input int width);
    logic [63:0] result;
    int y;
    int x;
    int value;
    begin
      result = 0;
      y = word_index / width;
      x = word_index % width;
      for (int lane = 0; lane < 8; lane++) begin
        value = (layer * 43 + tile * 29 + y * 17 + x * 11 + lane * 37) &
                8'hff;
        value = value - 128;
        result[lane*8 +: 8] = value[7:0];
      end
      make_word = result;
    end
  endfunction

  function automatic logic [63:0] expected_pool_word(
      input int layer,
      input int tile,
      input int output_index,
      input int raw_width,
      input int stored_width);
    logic [63:0] result;
    logic [63:0] source_word;
    logic signed [7:0] candidate;
    logic signed [7:0] best;
    int oy;
    int ox;
    begin
      result = 0;
      oy = output_index / stored_width;
      ox = output_index % stored_width;
      for (int lane = 0; lane < 8; lane++) begin
        best = -128;
        for (int dy = 0; dy < 3; dy++) begin
          for (int dx = 0; dx < 3; dx++) begin
            source_word = make_word(layer, tile,
                (oy * 2 + dy) * raw_width + ox * 2 + dx, raw_width);
            candidate = source_word[lane*8 +: 8];
            if (candidate > best)
              best = candidate;
          end
        end
        result[lane*8 +: 8] = best;
      end
      expected_pool_word = result;
    end
  endfunction

  task automatic check_held_output;
    begin
      if (hold_active && (!m_axis_tvalid || m_axis_tdata != hold_data ||
                          m_axis_tkeep != hold_keep ||
                          m_axis_tlast != hold_last))
        $fatal(1, "Conv result service output changed while stalled");
      if (m_axis_tvalid && !m_axis_tready) begin
        hold_active = 1'b1;
        hold_data = m_axis_tdata;
        hold_keep = m_axis_tkeep;
        hold_last = m_axis_tlast;
        output_stall_run = output_stall_run + 1;
        if (output_stall_run > max_output_stall)
          max_output_stall = output_stall_run;
      end else begin
        hold_active = 1'b0;
        output_stall_run = 0;
      end
    end
  endtask

  task automatic check_output_word(
      input logic [63:0] actual,
      input int layer,
      input int tile,
      input int output_index,
      input int raw_width,
      input int stored_width,
      input logic pool_enable);
    logic [63:0] expected;
    begin
      if (pool_enable)
        expected = expected_pool_word(layer, tile, output_index,
                                      raw_width, stored_width);
      else
        expected = make_word(layer, tile, output_index, raw_width);
      if (actual != expected)
        $fatal(1,
               "Conv result data mismatch layer=%0d tile=%0d word=%0d rtl=%016x expected=%016x",
               layer, tile, output_index, actual, expected);
    end
  endtask

  task automatic run_layer(
      input int this_layer,
      input int raw_h,
      input int raw_w,
      input int tiles,
      input logic pool_enable,
      input int stored_h,
      input int stored_w);
    int source_tile;
    int source_word;
    int sink_tile;
    int sink_word;
    int raw_words;
    int stored_words;
    int cycles;
    int words_in_beat;
    int sink_words_in_beat;
    logic source_fire;
    logic sink_fire;
    logic done_seen;
    begin
      raw_words = raw_h * raw_w;
      stored_words = stored_h * stored_w;
      source_tile = 0;
      source_word = 0;
      sink_tile = 0;
      sink_word = 0;
      cycles = 0;
      done_seen = 1'b0;
      hold_active = 1'b0;
      output_stall_run = 0;

      layer_id = this_layer;
      layer_job_tag = 16'h5100 + this_layer;
      layer_raw_h = raw_h;
      layer_raw_w = raw_w;
      layer_n8_tiles = tiles;
      layer_pool_enable = pool_enable;
      layer_stored_h = stored_h;
      layer_stored_w = stored_w;
      layer_valid = 1'b1;
      s_axis_tvalid = 1'b0;
      m_axis_tready = 1'b0;
      #1;
      if (!layer_ready)
        $fatal(1, "Conv result layer descriptor not ready layer=%0d",
               this_layer);
      @(posedge clk);
      @(negedge clk);
      layer_valid = 1'b0;

      while (!done_seen) begin
        if (source_tile < tiles && (cycles % 13) != 4) begin
          words_in_beat = (source_word + 1 < raw_words) ? 2 : 1;
          s_axis_tvalid = 1'b1;
          s_axis_tdata[63:0] =
              make_word(this_layer, source_tile, source_word, raw_w);
          s_axis_tdata[127:64] = words_in_beat == 2 ?
              make_word(this_layer, source_tile, source_word + 1, raw_w) : 0;
          s_axis_tkeep = words_in_beat == 2 ? 16'hffff : 16'h00ff;
          s_axis_tlast = source_word + words_in_beat == raw_words;
        end else begin
          words_in_beat = 0;
          s_axis_tvalid = 1'b0;
          s_axis_tdata = 0;
          s_axis_tkeep = 0;
          s_axis_tlast = 1'b0;
        end
        m_axis_tready = (cycles % 19) >= 5;

        #1;
        source_fire = s_axis_tvalid && s_axis_tready;
        sink_fire = m_axis_tvalid && m_axis_tready;
        check_held_output();
        if (sink_fire) begin
          sink_words_in_beat = m_axis_tkeep == 16'hffff ? 2 : 1;
          if (m_axis_tkeep != 16'hffff && m_axis_tkeep != 16'h00ff)
            $fatal(1, "Conv result output tkeep is not contiguous");
          check_output_word(m_axis_tdata[63:0], this_layer, sink_tile,
                            sink_word, raw_w, stored_w, pool_enable);
          if (sink_words_in_beat == 2)
            check_output_word(m_axis_tdata[127:64], this_layer, sink_tile,
                              sink_word + 1, raw_w, stored_w, pool_enable);
          if (m_axis_tlast !=
              (sink_word + sink_words_in_beat == stored_words))
            $fatal(1, "Conv result output packet boundary mismatch");
        end

        @(posedge clk);
        if (source_fire) begin
          total_raw_words = total_raw_words + words_in_beat;
          if (source_word + words_in_beat == raw_words) begin
            source_word = 0;
            source_tile = source_tile + 1;
          end else begin
            source_word = source_word + words_in_beat;
          end
        end
        if (sink_fire) begin
          total_stored_words = total_stored_words + sink_words_in_beat;
          if (sink_word + sink_words_in_beat == stored_words) begin
            sink_word = 0;
            sink_tile = sink_tile + 1;
          end else begin
            sink_word = sink_word + sink_words_in_beat;
          end
        end
        @(negedge clk);
        if (layer_done) begin
          if (completed_layer_id != this_layer ||
              completed_job_tag != 16'h5100 + this_layer)
            $fatal(1, "Conv result completion metadata mismatch");
          done_seen = 1'b1;
        end
        cycles = cycles + 1;
        if (cycles > 1000000)
          $fatal(1, "Conv result service timeout layer=%0d", this_layer);
      end

      s_axis_tvalid = 1'b0;
      m_axis_tready = 1'b0;
      if (source_tile != tiles || sink_tile != tiles || fault || busy ||
          raw_words_accepted != tiles * raw_words ||
          stored_words_transferred != tiles * stored_words ||
          input_tiles_completed != tiles || output_tiles_completed != tiles)
        $fatal(1,
               "Conv result layer final count mismatch layer=%0d src=%0d/%0d sink=%0d/%0d raw=%0d stored=%0d fault=%0b busy=%0b",
               this_layer, source_tile, tiles, sink_tile, tiles,
               raw_words_accepted, stored_words_transferred, fault, busy);
      completed_layers = completed_layers + 1;
    end
  endtask

  initial begin
    int seed;
    int seed_sink;
    seed = 32'h260a_1e57;
    seed_sink = $urandom(seed);
    rst = 1'b1;
    layer_valid = 1'b0;
    layer_id = 0;
    layer_job_tag = 0;
    layer_raw_h = 0;
    layer_raw_w = 0;
    layer_n8_tiles = 0;
    layer_pool_enable = 1'b0;
    layer_stored_h = 0;
    layer_stored_w = 0;
    s_axis_tdata = 0;
    s_axis_tkeep = 0;
    s_axis_tvalid = 1'b0;
    s_axis_tlast = 1'b0;
    m_axis_tready = 1'b0;
    total_raw_words = 0;
    total_stored_words = 0;
    completed_layers = 0;
    max_output_stall = 0;
    output_stall_run = 0;
    hold_active = 1'b0;
    repeat (5) @(negedge clk);
    rst = 1'b0;
    @(negedge clk);

    run_layer(1, 55, 55, 8, 1'b1, 27, 27);
    run_layer(2, 27, 27, 24, 1'b1, 13, 13);
    run_layer(3, 13, 13, 48, 1'b0, 13, 13);
    run_layer(4, 13, 13, 32, 1'b0, 13, 13);
    run_layer(5, 13, 13, 32, 1'b1, 6, 6);

    // A malformed layer contract is rejected into a stable service fault.
    layer_id = 5;
    layer_job_tag = 16'h5bad;
    layer_raw_h = 13;
    layer_raw_w = 13;
    layer_n8_tiles = 32;
    layer_pool_enable = 1'b1;
    layer_stored_h = 7;
    layer_stored_w = 6;
    layer_valid = 1'b1;
    #1;
    if (!layer_ready)
      $fatal(1, "Malformed descriptor could not reach checker");
    @(posedge clk);
    @(negedge clk);
    layer_valid = 1'b0;
    repeat (10) begin
      if (!fault || busy)
        $fatal(1, "Malformed descriptor fault did not remain stable");
      @(negedge clk);
    end

    if (total_raw_words != 60624 || total_stored_words != 24560 ||
        completed_layers != 5)
      $fatal(1, "Full Conv result service aggregate count mismatch");
    $display(
        "ALEXNET_CONV_RESULT_POOL_SERVICE_TEST_PASSED layers=%0d raw_words=%0d stored_words=%0d pool_tiles=64 bypass_tiles=80 maxstall=%0d malformed_fault=stable",
        completed_layers, total_raw_words, total_stored_words,
        max_output_stall);
    $finish;
  end
endmodule
