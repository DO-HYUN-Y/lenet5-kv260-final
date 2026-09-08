`timescale 1ns/1ps

module tb_alexnet_conv_layer_controller;
  logic clk = 1'b0;
  always #2.5 clk = ~clk;
  logic rst = 1'b1;

  logic job_valid, job_ready;
  logic [2:0] job_layer_id;
  logic [15:0] job_tag;
  logic [8:0] job_input_h, job_input_w;
  logic [9:0] job_input_channels, job_output_channels;
  logic [7:0] job_output_h, job_output_w;
  logic [3:0] job_kernel;
  logic [2:0] job_stride, job_padding;
  logic [5:0] job_n8_tiles, job_input_chunks;
  logic job_activation_streaming, job_pool_enable, job_flatten_output;
  logic [5:0] job_pool_output_h, job_pool_output_w;

  logic parameter_request_valid, parameter_request_ready;
  logic [2:0] parameter_request_layer_id;
  logic [15:0] parameter_request_job_tag, parameter_request_n_base;
  logic parameter_valid, parameter_ready;
  logic [2:0] parameter_layer_id;
  logic [15:0] parameter_job_tag, parameter_n_base;
  logic signed [31:0] parameter_bias [0:7];
  logic signed [17:0] parameter_multiplier [0:7];
  logic [5:0] parameter_right_shift [0:7];

  logic result_commit_request_valid, result_commit_request_ready;
  logic [2:0] result_commit_layer_id;
  logic [15:0] result_commit_job_tag;
  logic [7:0] result_commit_output_h, result_commit_output_w;
  logic [9:0] result_commit_output_channels;
  logic result_commit_pool_enable, result_commit_flatten_output;
  logic [5:0] result_commit_pool_output_h, result_commit_pool_output_w;
  logic result_complete_valid, result_complete_ready;
  logic [2:0] result_complete_layer_id;
  logic [15:0] result_complete_job_tag;
  logic result_complete_error, service_error;

  logic cfg_valid, cfg_ready;
  logic [1:0] cfg_destination;
  logic [15:0] cfg_n64_tile_base;
  logic [2:0] cfg_slice_index;
  logic [7:0] cfg_lane_mask, cfg_relu;
  logic signed [31:0] cfg_bias [0:7];
  logic signed [17:0] cfg_multiplier [0:7];
  logic [5:0] cfg_right_shift [0:7];

  logic command_valid, command_ready;
  logic [15:0] command_id;
  logic command_activation_streaming;
  logic [1:0] command_activation_destination;
  logic [10:0] command_activation_word_count;
  logic [15:0] command_activation_byte_count;
  logic [7:0] command_activation_lane_mask;
  logic [15:0] command_activation_tensor_tag;
  logic [10:0] command_weight_word_count;
  logic [15:0] command_weight_byte_count;
  logic [7:0] command_weight_lane_mask;
  logic [15:0] command_weight_context_tag;
  logic command_result_enable;
  logic [12:0] command_result_word_count;
  logic [15:0] command_result_byte_count;
  logic [1:0] command_result_destination;
  logic [2:0] command_result_slice;
  logic [15:0] command_result_n_base;
  logic [7:0] command_result_lane_mask;
  logic [15:0] command_result_first_tile_tag;
  logic [7:0] command_chunk_input_h, command_chunk_input_w;
  logic [3:0] command_chunk_channel_count, command_chunk_kernel;
  logic [7:0] command_chunk_input_lane_mask;
  logic [2:0] command_chunk_stride, command_chunk_padding;
  logic [9:0] command_chunk_k_count;
  logic [15:0] command_chunk_weight_context_tag;
  logic [12:0] command_chunk_word_count;
  logic [7:0] command_chunk_output_width;
  logic [15:0] command_chunk_accum_context_tag;
  logic [15:0] command_chunk_tile_tag_base;
  logic [7:0] command_chunk_index;
  logic command_chunk_first, command_chunk_final;
  logic command_done, command_rejected, command_error;
  logic [15:0] completed_command_id;
  logic core_fault;

  logic complete_valid, complete_ready;
  logic [2:0] complete_layer_id;
  logic [15:0] complete_job_tag;
  logic complete_error, busy, fault;
  logic [3:0] fault_code, phase;
  logic [5:0] active_n8_tile, active_input_chunk;
  logic [12:0] completed_commands;
  logic [5:0] completed_n8_tiles;
  logic [15:0] completed_output_words;

  int total_commands;
  int total_tiles;
  int cycles;

  alexnet_conv_layer_controller dut (.*);

  always @(posedge clk) begin
    if (rst)
      cycles <= 0;
    else begin
      cycles <= cycles + 1;
      if (cycles > 80000)
        $fatal(1, "Conv layer controller watchdog phase=%0d layer=%0d tile=%0d chunk=%0d",
               phase, complete_layer_id, active_n8_tile, active_input_chunk);
    end
  end

  task automatic set_layer(input int layer, input logic [15:0] tag);
    begin
      job_layer_id = layer;
      job_tag = tag;
      job_activation_streaming = 0;
      job_pool_enable = 0;
      job_flatten_output = 0;
      job_pool_output_h = 0;
      job_pool_output_w = 0;
      case (layer)
        1: begin
          job_input_h=224; job_input_w=224; job_input_channels=3;
          job_output_channels=64; job_output_h=55; job_output_w=55;
          job_kernel=11; job_stride=4; job_padding=2;
          job_n8_tiles=8; job_input_chunks=1;
          job_activation_streaming=1; job_pool_enable=1;
          job_pool_output_h=27; job_pool_output_w=27;
        end
        2: begin
          job_input_h=27; job_input_w=27; job_input_channels=64;
          job_output_channels=192; job_output_h=27; job_output_w=27;
          job_kernel=5; job_stride=1; job_padding=2;
          job_n8_tiles=24; job_input_chunks=8;
          job_pool_enable=1; job_pool_output_h=13; job_pool_output_w=13;
        end
        3: begin
          job_input_h=13; job_input_w=13; job_input_channels=192;
          job_output_channels=384; job_output_h=13; job_output_w=13;
          job_kernel=3; job_stride=1; job_padding=1;
          job_n8_tiles=48; job_input_chunks=24;
        end
        4: begin
          job_input_h=13; job_input_w=13; job_input_channels=384;
          job_output_channels=256; job_output_h=13; job_output_w=13;
          job_kernel=3; job_stride=1; job_padding=1;
          job_n8_tiles=32; job_input_chunks=48;
        end
        default: begin
          job_input_h=13; job_input_w=13; job_input_channels=256;
          job_output_channels=256; job_output_h=13; job_output_w=13;
          job_kernel=3; job_stride=1; job_padding=1;
          job_n8_tiles=32; job_input_chunks=32;
          job_pool_enable=1; job_pool_output_h=6; job_pool_output_w=6;
          job_flatten_output=1;
        end
      endcase
    end
  endtask

  task automatic submit_job(input int layer, input logic [15:0] tag);
    begin
      set_layer(layer, tag);
      job_valid = 1;
      while (!job_ready) @(negedge clk);
      @(posedge clk);
      @(negedge clk);
      job_valid = 0;
    end
  endtask

  task automatic serve_parameters(input int layer, input logic [15:0] tag,
                                  input int n_base);
    begin
      while (!parameter_request_valid) @(negedge clk);
      if (parameter_request_layer_id != layer ||
          parameter_request_job_tag != tag ||
          parameter_request_n_base != n_base)
        $fatal(1, "Conv parameter request mismatch layer=%0d n=%0d/%0d",
               layer, parameter_request_n_base, n_base);
      repeat ($urandom_range(0, 2)) @(negedge clk);
      parameter_request_ready = 1;
      @(posedge clk);
      @(negedge clk);
      parameter_request_ready = 0;

      parameter_layer_id = layer;
      parameter_job_tag = tag;
      parameter_n_base = n_base;
      for (int lane = 0; lane < 8; lane++) begin
        parameter_bias[lane] = layer * 32 + n_base + lane;
        parameter_multiplier[lane] = 18'sd70000 + lane;
        parameter_right_shift[lane] = 24 + (lane & 1);
      end
      repeat ($urandom_range(0, 2)) @(negedge clk);
      parameter_valid = 1;
      while (!parameter_ready) @(negedge clk);
      @(posedge clk);
      @(negedge clk);
      parameter_valid = 0;

      while (!cfg_valid) @(negedge clk);
      if (cfg_destination != 0 || cfg_n64_tile_base != (n_base & 16'hffc0) ||
          cfg_slice_index != ((n_base >> 3) & 7) || cfg_lane_mask != 8'hff ||
          cfg_relu != 8'hff)
        $fatal(1, "Conv config metadata mismatch layer=%0d n=%0d", layer,
               n_base);
      for (int lane = 0; lane < 8; lane++) begin
        if (cfg_bias[lane] != layer * 32 + n_base + lane ||
            cfg_multiplier[lane] != 18'sd70000 + lane ||
            cfg_right_shift[lane] != 24 + (lane & 1))
          $fatal(1, "Conv config parameter mismatch lane=%0d", lane);
      end
      repeat ($urandom_range(0, 2)) @(negedge clk);
      cfg_ready = 1;
      @(posedge clk);
      @(negedge clk);
      cfg_ready = 0;
    end
  endtask

  task automatic serve_command(input int layer, input logic [15:0] tag,
                               input int tile, input int chunk,
                               input int chunks, input int output_words,
                               input int expected_id);
    int activation_words;
    int weight_words;
    int input_dim;
    int output_dim;
    int channels;
    int lane_mask;
    int tile_tag;
    begin
      activation_words = layer == 1 ? 0 : (layer == 2 ? 729 : 169);
      weight_words = layer == 1 ? 363 : (layer == 2 ? 200 : 72);
      input_dim = layer == 1 ? 224 : (layer == 2 ? 27 : 13);
      output_dim = layer == 1 ? 55 : (layer == 2 ? 27 : 13);
      channels = layer == 1 ? 3 : 8;
      lane_mask = layer == 1 ? 8'h07 : 8'hff;
      tile_tag = (tag + tile * output_words) & 16'hffff;
      while (!command_valid) @(negedge clk);
      if (command_id != (expected_id & 16'hffff) ||
          command_activation_streaming != (layer == 1) ||
          command_activation_word_count != activation_words ||
          command_activation_byte_count != activation_words * 8 ||
          command_activation_lane_mask != lane_mask ||
          command_activation_tensor_tag != (expected_id & 16'hffff) ||
          command_weight_word_count != weight_words ||
          command_weight_byte_count != weight_words * 8 ||
          command_weight_lane_mask != 8'hff ||
          command_weight_context_tag != (expected_id & 16'hffff) ||
          command_result_enable != (chunk + 1 == chunks) ||
          command_result_word_count != output_words ||
          command_result_byte_count != output_words * 8 ||
          command_result_destination != 0 ||
          command_result_slice != (tile & 7) ||
          command_result_n_base != tile * 8 ||
          command_result_lane_mask != 8'hff ||
          command_result_first_tile_tag != tile_tag ||
          command_chunk_input_h != input_dim ||
          command_chunk_input_w != input_dim ||
          command_chunk_channel_count != channels ||
          command_chunk_input_lane_mask != lane_mask ||
          command_chunk_kernel != (layer == 1 ? 11 :
                                   (layer == 2 ? 5 : 3)) ||
          command_chunk_stride != (layer == 1 ? 4 : 1) ||
          command_chunk_padding != (layer < 3 ? 2 : 1) ||
          command_chunk_k_count != weight_words ||
          command_chunk_weight_context_tag != (expected_id & 16'hffff) ||
          command_chunk_word_count != output_words ||
          command_chunk_output_width != output_dim ||
          command_chunk_accum_context_tag != tile_tag ||
          command_chunk_tile_tag_base != tile_tag ||
          command_chunk_index != chunk ||
          command_chunk_first != (chunk == 0) ||
          command_chunk_final != (chunk + 1 == chunks))
        $fatal(1, "Conv command mismatch layer=%0d tile=%0d chunk=%0d id=%h/%h",
               layer, tile, chunk, command_id, expected_id & 16'hffff);
      repeat ($urandom_range(0, 2)) @(negedge clk);
      command_ready = 1;
      @(posedge clk);
      @(negedge clk);
      command_ready = 0;
      repeat ($urandom_range(0, 2)) @(negedge clk);
      completed_command_id = expected_id;
      command_done = 1;
      @(posedge clk);
      @(negedge clk);
      command_done = 0;
      total_commands = total_commands + 1;
    end
  endtask

  task automatic start_result_service(input int layer,
                                      input logic [15:0] tag);
    begin
      while (!result_commit_request_valid) @(negedge clk);
      if (result_commit_layer_id != layer || result_commit_job_tag != tag ||
          result_commit_output_h != (layer == 1 ? 55 :
                                    (layer == 2 ? 27 : 13)) ||
          result_commit_output_w != result_commit_output_h ||
          result_commit_output_channels !=
              (layer == 1 ? 64 : (layer == 2 ? 192 :
                                  (layer == 3 ? 384 : 256))) ||
          result_commit_pool_enable !=
              (layer == 1 || layer == 2 || layer == 5) ||
          result_commit_pool_output_h !=
              (layer == 1 ? 27 : (layer == 2 ? 13 : (layer == 5 ? 6 : 0))) ||
          result_commit_pool_output_w != result_commit_pool_output_h ||
          result_commit_flatten_output != (layer == 5))
        $fatal(1, "Conv result commit metadata mismatch layer=%0d", layer);
      result_commit_request_ready = 1;
      @(posedge clk);
      @(negedge clk);
      result_commit_request_ready = 0;
    end
  endtask

  task automatic finish_layer(input int layer, input logic [15:0] tag,
                              input int tiles, input int chunks,
                              input int output_words);
    begin
      repeat ($urandom_range(0, 2)) @(negedge clk);
      result_complete_layer_id = layer;
      result_complete_job_tag = tag;
      result_complete_error = 0;
      result_complete_valid = 1;
      while (!result_complete_ready) @(negedge clk);
      @(posedge clk);
      @(negedge clk);
      result_complete_valid = 0;
      while (!complete_valid) @(negedge clk);
      if (complete_error || complete_layer_id != layer ||
          complete_job_tag != tag || fault || completed_n8_tiles != tiles ||
          completed_commands != tiles * chunks ||
          completed_output_words != tiles * output_words)
        $fatal(1, "Conv layer retirement mismatch layer=%0d tiles=%0d commands=%0d words=%0d",
               layer, completed_n8_tiles, completed_commands,
               completed_output_words);
      @(negedge clk);
      total_tiles = total_tiles + tiles;
    end
  endtask

  task automatic run_layer(input int layer, input logic [15:0] tag);
    int tiles;
    int chunks;
    int output_words;
    int expected_id;
    begin
      tiles = layer == 1 ? 8 : (layer == 2 ? 24 :
              (layer == 3 ? 48 : 32));
      chunks = layer == 1 ? 1 : (layer == 2 ? 8 :
               (layer == 3 ? 24 : (layer == 4 ? 48 : 32)));
      output_words = layer == 1 ? 3025 : (layer == 2 ? 729 : 169);
      expected_id = tag;
      submit_job(layer, tag);
      start_result_service(layer, tag);
      for (int tile = 0; tile < tiles; tile++) begin
        serve_parameters(layer, tag, tile * 8);
        for (int chunk = 0; chunk < chunks; chunk++) begin
          serve_command(layer, tag, tile, chunk, chunks, output_words,
                        expected_id);
          expected_id = (expected_id + 1) & 16'hffff;
        end
      end
      finish_layer(layer, tag, tiles, chunks, output_words);
    end
  endtask

  initial begin
    job_valid = 0;
    parameter_request_ready = 0;
    parameter_valid = 0;
    result_commit_request_ready = 0;
    result_complete_valid = 0;
    result_complete_error = 0;
    service_error = 0;
    cfg_ready = 0;
    command_ready = 0;
    command_done = 0;
    command_rejected = 0;
    command_error = 0;
    completed_command_id = 0;
    core_fault = 0;
    complete_ready = 1;
    total_commands = 0;
    total_tiles = 0;
    for (int lane = 0; lane < 8; lane++) begin
      parameter_bias[lane] = 0;
      parameter_multiplier[lane] = 18'sd70000;
      parameter_right_shift[lane] = 24;
    end

    repeat (6) @(negedge clk);
    rst = 0;
    repeat (2) @(negedge clk);
    for (int layer = 1; layer <= 5; layer++)
      run_layer(layer, 16'(16'h4000 + layer * 16'h0800));

    if (total_commands != 3912 || total_tiles != 144 || fault || busy)
      $fatal(1, "Conv full schedule mismatch commands=%0d tiles=%0d fault=%0b busy=%0b",
             total_commands, total_tiles, fault, busy);

    // Reset the ownership domain and prove that a mismatched command
    // completion cannot advance even the first Conv1 tile.
    rst = 1;
    repeat (4) @(negedge clk);
    rst = 0;
    repeat (2) @(negedge clk);
    submit_job(1, 16'h7100);
    start_result_service(1, 16'h7100);
    serve_parameters(1, 16'h7100, 0);
    while (!command_valid) @(negedge clk);
    command_ready = 1;
    @(posedge clk);
    @(negedge clk);
    command_ready = 0;
    completed_command_id = 16'h71ff;
    command_done = 1;
    @(posedge clk);
    @(negedge clk);
    command_done = 0;
    while (!fault) @(negedge clk);
    repeat (4) begin
      if (!complete_valid || !complete_error || fault_code != 4 ||
          active_n8_tile != 0 || active_input_chunk != 0)
        $fatal(1, "Conv command metadata fault was not stable");
      @(negedge clk);
    end

    $display("ALEXNET_CONV_LAYER_CONTROLLER_TEST_PASSED layers=5 n8_tiles=%0d commands=%0d raw_output_words=60624 metadata_fault=stable",
             total_tiles, total_commands);
    $finish;
  end
endmodule
