`timescale 1ns/1ps

module tb_alexnet_conv_fc_data_service;
  logic clk = 1'b0;
  logic rst;
  logic conv_layer_valid, conv_layer_ready;
  logic [2:0] conv_layer_id;
  logic [15:0] conv_layer_job_tag;
  logic [7:0] conv_layer_raw_h, conv_layer_raw_w;
  logic [5:0] conv_layer_n8_tiles;
  logic conv_layer_pool_enable;
  logic [5:0] conv_layer_stored_h, conv_layer_stored_w;
  logic [127:0] conv_raw_axis_tdata;
  logic [15:0] conv_raw_axis_tkeep;
  logic conv_raw_axis_tvalid, conv_raw_axis_tready, conv_raw_axis_tlast;
  logic [127:0] conv_stored_axis_tdata;
  logic [15:0] conv_stored_axis_tkeep;
  logic conv_stored_axis_tvalid, conv_stored_axis_tready;
  logic conv_stored_axis_tlast;
  logic conv_layer_done;
  logic [2:0] conv_completed_layer_id;
  logic [15:0] conv_completed_job_tag;
  logic fc_request_valid, fc_request_ready;
  logic [3:0] fc_active_layer_id;
  logic [13:0] fc_active_k_offset;
  logic [9:0] fc_active_k_count;
  logic [1:0] fc_request_destination;
  logic [9:0] fc_request_word_count;
  logic [15:0] fc_request_byte_count;
  logic [2:0] fc_request_m_count;
  logic [15:0] fc_request_tag;
  logic fc_external_request_valid, fc_external_request_ready;
  logic [3:0] fc_external_request_layer_id;
  logic [13:0] fc_external_request_k_offset;
  logic [9:0] fc_external_request_k_count;
  logic [1:0] fc_external_request_destination;
  logic [9:0] fc_external_request_word_count;
  logic [15:0] fc_external_request_byte_count;
  logic [2:0] fc_external_request_m_count;
  logic [15:0] fc_external_request_tag;
  logic [127:0] external_axis_tdata;
  logic [15:0] external_axis_tkeep;
  logic external_axis_tvalid, external_axis_tready, external_axis_tlast;
  logic [127:0] compute_axis_tdata;
  logic [15:0] compute_axis_tkeep;
  logic compute_axis_tvalid, compute_axis_tready, compute_axis_tlast;
  logic pool5_cache_valid;
  logic [15:0] pool5_cache_tag;
  logic pool5_cache_write_done;
  logic fc6_flatten_active, fc6_flatten_done, fault;
  logic [31:0] conv_raw_words, conv_stored_words;
  logic [13:0] fc6_completed_scalars;
  logic [10:0] fc6_completed_words;

  int current_offset;
  int current_count;
  int current_beat;
  int injected_words;
  int stored_beats;
  int stored_tiles;
  int watchdog;
  logic hold_active;
  logic [127:0] hold_data;
  logic [15:0] hold_keep;
  logic hold_last;

  alexnet_conv_fc_data_service dut (.*);

  always #2.5 clk = ~clk;

  function automatic logic [63:0] raw_word(
      input int tile,
      input int word_index);
    logic [63:0] result;
    int y;
    int x;
    int value;
    begin
      result = 0;
      y = word_index / 13;
      x = word_index % 13;
      for (int lane = 0; lane < 8; lane++) begin
        value = (tile * 19 + lane * 23 + y * 7 + x * 11) & 8'hff;
        value = value - 128;
        result[lane*8 +: 8] = value[7:0];
      end
      raw_word = result;
    end
  endfunction

  function automatic logic [7:0] pooled_scalar(
      input int channel,
      input int spatial);
    int tile;
    int lane;
    int oy;
    int ox;
    logic [63:0] source;
    logic signed [7:0] candidate;
    logic signed [7:0] best;
    begin
      tile = channel / 8;
      lane = channel % 8;
      oy = spatial / 6;
      ox = spatial % 6;
      best = -128;
      for (int dy = 0; dy < 3; dy++) begin
        for (int dx = 0; dx < 3; dx++) begin
          source = raw_word(tile, (oy * 2 + dy) * 13 + ox * 2 + dx);
          candidate = source[lane*8 +: 8];
          if (candidate > best)
            best = candidate;
        end
      end
      pooled_scalar = best;
    end
  endfunction

  function automatic logic [63:0] flattened_word(input int flat_base);
    logic [63:0] result;
    int flat;
    begin
      result = 0;
      for (int lane = 0; lane < 8; lane++) begin
        flat = flat_base + lane;
        result[lane*8 +: 8] = pooled_scalar(flat / 36, flat % 36);
      end
      flattened_word = result;
    end
  endfunction

  always @(negedge clk) begin
    if (rst) begin
      conv_stored_axis_tready <= 0;
      compute_axis_tready <= 0;
    end else begin
      conv_stored_axis_tready <= ($time / 5) % 23 >= 5;
      compute_axis_tready <= ($time / 5) % 17 >= 3;
    end
  end

  always @(posedge clk) begin
    int chunk_words;
    int low_word;
    int words_in_beat;
    if (rst) begin
      current_beat <= 0;
      injected_words <= 0;
      stored_beats <= 0;
      stored_tiles <= 0;
      watchdog <= 0;
      hold_active <= 0;
    end else begin
      watchdog <= watchdog + 1;
      if (watchdog > 500000)
        $fatal(1, "Conv/FC data service watchdog");
      if (conv_stored_axis_tvalid && conv_stored_axis_tready) begin
        if (conv_stored_axis_tkeep != 16'hffff ||
            conv_stored_axis_tlast != (stored_beats % 18 == 17))
          $fatal(1, "Pool5 stored stream packet mismatch beat=%0d",
                 stored_beats);
        stored_beats <= stored_beats + 1;
        if (conv_stored_axis_tlast)
          stored_tiles <= stored_tiles + 1;
      end

      if (hold_active && (!compute_axis_tvalid ||
          compute_axis_tdata != hold_data || compute_axis_tkeep != hold_keep ||
          compute_axis_tlast != hold_last))
        $fatal(1, "FC6 cached flatten stream changed while stalled");
      if (fc6_flatten_active && compute_axis_tvalid) begin
        chunk_words = current_count / 8;
        low_word = current_beat * 2;
        words_in_beat = low_word + 1 < chunk_words ? 2 : 1;
        if (compute_axis_tdata[63:0] !=
                flattened_word(current_offset + low_word * 8) ||
            (words_in_beat == 2 && compute_axis_tdata[127:64] !=
                flattened_word(current_offset + (low_word + 1) * 8)) ||
            compute_axis_tkeep !=
                (words_in_beat == 2 ? 16'hffff : 16'h00ff) ||
            compute_axis_tlast !=
                (low_word + words_in_beat == chunk_words))
          $fatal(1, "FC6 cached flatten data mismatch offset=%0d beat=%0d",
                 current_offset, current_beat);
        if (compute_axis_tready) begin
          current_beat <= current_beat + 1;
          injected_words <= injected_words + words_in_beat;
        end
      end
      hold_active <= compute_axis_tvalid && !compute_axis_tready;
      if (compute_axis_tvalid && !compute_axis_tready) begin
        hold_data <= compute_axis_tdata;
        hold_keep <= compute_axis_tkeep;
        hold_last <= compute_axis_tlast;
      end
    end
  end

  task automatic run_fc6_chunk(input int offset, input int count,
                               input int chunk_index);
    begin
      current_offset = offset;
      current_count = count;
      current_beat = 0;
      fc_active_layer_id = 6;
      fc_active_k_offset = offset;
      fc_active_k_count = count;
      fc_request_destination = 0;
      fc_request_word_count = count / 8;
      fc_request_byte_count = count;
      fc_request_m_count = 1;
      fc_request_tag = 16'h6600 + chunk_index;
      fc_request_valid = 1'b1;
      #1;
      while (!fc_request_ready) @(negedge clk);
      if (fc_external_request_valid)
        $fatal(1, "Connected FC6 cache request leaked to DDR");
      @(posedge clk);
      @(negedge clk);
      fc_request_valid = 1'b0;
      while (!fc6_flatten_done) @(negedge clk);
      @(negedge clk);
      if (current_beat != (count / 8 + 1) / 2 || fault)
        $fatal(1, "Connected FC6 chunk did not drain");
    end
  endtask

  initial begin
    int source_tile;
    int source_word;
    int words_in_beat;
    int offset;
    int count;
    int chunk;
    logic source_fire;
    rst = 1'b1;
    conv_layer_valid = 0;
    conv_layer_id = 0;
    conv_layer_job_tag = 0;
    conv_layer_raw_h = 0;
    conv_layer_raw_w = 0;
    conv_layer_n8_tiles = 0;
    conv_layer_pool_enable = 0;
    conv_layer_stored_h = 0;
    conv_layer_stored_w = 0;
    conv_raw_axis_tdata = 0;
    conv_raw_axis_tkeep = 0;
    conv_raw_axis_tvalid = 0;
    conv_raw_axis_tlast = 0;
    conv_stored_axis_tready = 0;
    fc_request_valid = 0;
    fc_active_layer_id = 0;
    fc_active_k_offset = 0;
    fc_active_k_count = 0;
    fc_request_destination = 0;
    fc_request_word_count = 0;
    fc_request_byte_count = 0;
    fc_request_m_count = 0;
    fc_request_tag = 0;
    fc_external_request_ready = 1;
    external_axis_tdata = 0;
    external_axis_tkeep = 0;
    external_axis_tvalid = 0;
    external_axis_tlast = 0;
    compute_axis_tready = 0;
    repeat (6) @(negedge clk);
    rst = 0;
    repeat (2) @(negedge clk);

    conv_layer_id = 5;
    conv_layer_job_tag = 16'h5505;
    conv_layer_raw_h = 13;
    conv_layer_raw_w = 13;
    conv_layer_n8_tiles = 32;
    conv_layer_pool_enable = 1;
    conv_layer_stored_h = 6;
    conv_layer_stored_w = 6;
    conv_layer_valid = 1;
    #1;
    while (!conv_layer_ready) @(negedge clk);
    @(posedge clk);
    @(negedge clk);
    conv_layer_valid = 0;

    source_tile = 0;
    source_word = 0;
    while (source_tile < 32) begin
      words_in_beat = source_word + 1 < 169 ? 2 : 1;
      conv_raw_axis_tdata[63:0] = raw_word(source_tile, source_word);
      conv_raw_axis_tdata[127:64] = words_in_beat == 2 ?
          raw_word(source_tile, source_word + 1) : 0;
      conv_raw_axis_tkeep = words_in_beat == 2 ? 16'hffff : 16'h00ff;
      conv_raw_axis_tlast = source_word + words_in_beat == 169;
      conv_raw_axis_tvalid = 1;
      #1;
      source_fire = conv_raw_axis_tready;
      @(posedge clk);
      if (source_fire) begin
        if (source_word + words_in_beat == 169) begin
          source_word = 0;
          source_tile = source_tile + 1;
        end else begin
          source_word = source_word + words_in_beat;
        end
      end
      @(negedge clk);
    end
    conv_raw_axis_tvalid = 0;
    while (!conv_layer_done) @(negedge clk);
    @(negedge clk);
    if (!pool5_cache_valid || pool5_cache_tag != 16'h5505 ||
        stored_beats != 576 || stored_tiles != 32 ||
        conv_raw_words != 5408 || conv_stored_words != 1152 || fault)
      $fatal(1, "Connected Conv5-to-Pool5 cache completion mismatch");

    offset = 0;
    chunk = 0;
    while (offset < 9216) begin
      count = 9216 - offset > 968 ? 968 : 9216 - offset;
      run_fc6_chunk(offset, count, chunk);
      offset = offset + count;
      chunk = chunk + 1;
    end

    if (injected_words != 1152 || fc6_completed_scalars != 9216 ||
        fc6_completed_words != 1152 || fault)
      $fatal(1, "Connected Pool5-to-FC6 aggregate mismatch");
    $display(
        "ALEXNET_CONV_FC_DATA_SERVICE_TEST_PASSED conv5_raw_words=5408 pool5_words=1152 cache_beats=576 cache_bram_target=2 fc6_scalars=9216 fc6_words=1152 chunks=10");
    $finish;
  end
endmodule
