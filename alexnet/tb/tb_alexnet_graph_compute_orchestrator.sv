`timescale 1ns/1ps

module tb_alexnet_graph_compute_orchestrator;
  logic clk = 1'b0;
  always #2.5 clk = ~clk;
  logic rst = 1'b1;
  logic start_valid, start_ready;
  logic [15:0] start_tag;
  logic owner_valid, owner_ready, owner_fc, owner_release_valid;
  logic owner_release_ready, owner_active, active_owner_fc, owner_released;
  logic owner_fault;

  logic conv_parameter_request_valid, conv_parameter_request_ready;
  logic [2:0] conv_parameter_request_layer_id;
  logic [15:0] conv_parameter_request_job_tag;
  logic [15:0] conv_parameter_request_n_base;
  logic conv_parameter_valid, conv_parameter_ready;
  logic [2:0] conv_parameter_layer_id;
  logic [15:0] conv_parameter_job_tag, conv_parameter_n_base;
  logic signed [31:0] conv_parameter_bias [0:7];
  logic signed [17:0] conv_parameter_multiplier [0:7];
  logic [5:0] conv_parameter_right_shift [0:7];

  logic conv_result_commit_request_valid;
  logic conv_result_commit_request_ready;
  logic [2:0] conv_result_commit_layer_id;
  logic [15:0] conv_result_commit_job_tag;
  logic [7:0] conv_result_commit_output_h, conv_result_commit_output_w;
  logic [9:0] conv_result_commit_output_channels;
  logic conv_result_commit_pool_enable, conv_result_commit_flatten_output;
  logic [5:0] conv_result_commit_pool_output_h;
  logic [5:0] conv_result_commit_pool_output_w;
  logic conv_result_complete_valid, conv_result_complete_ready;
  logic [2:0] conv_result_complete_layer_id;
  logic [15:0] conv_result_complete_job_tag;
  logic conv_result_complete_error, conv_service_error;

  logic rs_cfg_valid, rs_cfg_ready;
  logic [1:0] rs_cfg_destination;
  logic [15:0] rs_cfg_n64_tile_base;
  logic [2:0] rs_cfg_slice_index;
  logic [7:0] rs_cfg_lane_mask, rs_cfg_relu;
  logic signed [31:0] rs_cfg_bias [0:7];
  logic signed [17:0] rs_cfg_multiplier [0:7];
  logic [5:0] rs_cfg_right_shift [0:7];

  logic rs_command_valid, rs_command_ready;
  logic [15:0] rs_command_id;
  logic rs_command_activation_streaming;
  logic [1:0] rs_command_activation_destination;
  logic [10:0] rs_command_activation_word_count;
  logic [15:0] rs_command_activation_byte_count;
  logic [7:0] rs_command_activation_lane_mask;
  logic [15:0] rs_command_activation_tensor_tag;
  logic [10:0] rs_command_weight_word_count;
  logic [15:0] rs_command_weight_byte_count;
  logic [7:0] rs_command_weight_lane_mask;
  logic [15:0] rs_command_weight_context_tag;
  logic rs_command_result_enable;
  logic [12:0] rs_command_result_word_count;
  logic [15:0] rs_command_result_byte_count;
  logic [1:0] rs_command_result_destination;
  logic [2:0] rs_command_result_slice;
  logic [15:0] rs_command_result_n_base;
  logic [7:0] rs_command_result_lane_mask;
  logic [15:0] rs_command_result_first_tile_tag;
  logic [7:0] rs_command_chunk_input_h, rs_command_chunk_input_w;
  logic [3:0] rs_command_chunk_channel_count;
  logic [7:0] rs_command_chunk_input_lane_mask;
  logic [3:0] rs_command_chunk_kernel;
  logic [2:0] rs_command_chunk_stride, rs_command_chunk_padding;
  logic [9:0] rs_command_chunk_k_count;
  logic [15:0] rs_command_chunk_weight_context_tag;
  logic [12:0] rs_command_chunk_word_count;
  logic [7:0] rs_command_chunk_output_width;
  logic [15:0] rs_command_chunk_accum_context_tag;
  logic [15:0] rs_command_chunk_tile_tag_base;
  logic [7:0] rs_command_chunk_index;
  logic rs_command_chunk_first, rs_command_chunk_final;
  logic rs_command_done, rs_command_rejected, rs_command_error;
  logic [15:0] rs_completed_command_id;
  logic rs_scheduler_fault;

  logic fc_job_valid, fc_job_ready;
  logic [3:0] fc_job_layer_id;
  logic [2:0] fc_job_m_count;
  logic [15:0] fc_job_tag;
  logic fc_layer_done, fc_job_rejected, fc_layer_failed;
  logic [3:0] fc_active_layer_id;
  logic [15:0] fc_active_job_tag;
  logic fc_service_error;

  logic busy, inference_done, inference_failed, fault;
  logic [3:0] fault_code, active_layer_id;
  logic [4:0] graph_phase;
  logic [15:0] active_inference_tag;
  logic [2:0] completed_conv_layers;
  logic [1:0] completed_fc_layers;
  logic [12:0] active_conv_completed_commands;
  logic [5:0] active_conv_completed_n8_tiles;
  logic [15:0] active_conv_completed_output_words;

  int owner_acquires;
  int owner_releases;
  int conv_commands;
  int conv_tiles;
  int conv_commits;
  int fc_jobs;
  int cycles;

  alexnet_graph_compute_orchestrator dut (.*);

  assign owner_ready = !owner_active && !owner_fault;
  assign owner_release_ready = 1'b1;

  always @(posedge clk) begin
    if (rst) begin
      owner_active <= 0;
      active_owner_fc <= 0;
      owner_released <= 0;
      owner_acquires <= 0;
      owner_releases <= 0;
      cycles <= 0;
    end else begin
      owner_released <= 0;
      cycles <= cycles + 1;
      if (cycles > 100000)
        $fatal(1, "orchestrator watchdog graph=%0d layer=%0d commands=%0d",
               graph_phase, active_layer_id, conv_commands);
      if (owner_valid && owner_ready) begin
        owner_active <= 1;
        active_owner_fc <= owner_fc;
        owner_acquires <= owner_acquires + 1;
      end
      if (owner_release_valid && owner_release_ready) begin
        owner_active <= 0;
        owner_released <= 1;
        owner_releases <= owner_releases + 1;
      end
    end
  end

  task automatic serve_conv_layer(input int layer);
    int tiles;
    int chunks;
    int expected_tag;
    int expected_id;
    int output_words;
    begin
      tiles = layer == 1 ? 8 : (layer == 2 ? 24 :
              (layer == 3 ? 48 : 32));
      chunks = layer == 1 ? 1 : (layer == 2 ? 8 :
               (layer == 3 ? 24 : (layer == 4 ? 48 : 32)));
      output_words = layer == 1 ? 3025 : (layer == 2 ? 729 : 169);
      expected_tag = 16'h2200 + layer;
      expected_id = expected_tag;

      // The real result sink is armed before the first compute command.
      while (!conv_result_commit_request_valid) @(negedge clk);
      if (conv_result_commit_layer_id != layer ||
          conv_result_commit_job_tag != expected_tag ||
          conv_result_commit_pool_enable !=
              (layer == 1 || layer == 2 || layer == 5) ||
          conv_result_commit_flatten_output != (layer == 5))
        $fatal(1, "orchestrator Conv service-start mismatch layer=%0d", layer);
      conv_result_commit_request_ready = 1;
      @(posedge clk);
      @(negedge clk);
      conv_result_commit_request_ready = 0;

      for (int tile = 0; tile < tiles; tile++) begin
        while (!conv_parameter_request_valid) @(negedge clk);
        if (conv_parameter_request_layer_id != layer ||
            conv_parameter_request_job_tag != expected_tag ||
            conv_parameter_request_n_base != tile * 8)
          $fatal(1, "orchestrator Conv parameter mismatch layer=%0d tile=%0d",
                 layer, tile);
        conv_parameter_request_ready = 1;
        @(posedge clk);
        @(negedge clk);
        conv_parameter_request_ready = 0;
        conv_parameter_layer_id = layer;
        conv_parameter_job_tag = expected_tag;
        conv_parameter_n_base = tile * 8;
        for (int lane = 0; lane < 8; lane++) begin
          conv_parameter_bias[lane] = layer * 8 + lane;
          conv_parameter_multiplier[lane] = 18'sd70000 + lane;
          conv_parameter_right_shift[lane] = 24;
        end
        conv_parameter_valid = 1;
        while (!conv_parameter_ready) @(negedge clk);
        @(posedge clk);
        @(negedge clk);
        conv_parameter_valid = 0;
        while (!rs_cfg_valid) @(negedge clk);
        if (rs_cfg_n64_tile_base != ((tile * 8) & 16'hffc0) ||
            rs_cfg_slice_index != (tile & 7))
          $fatal(1, "orchestrator Conv config mapping mismatch");
        rs_cfg_ready = 1;
        @(posedge clk);
        @(negedge clk);
        rs_cfg_ready = 0;

        for (int chunk = 0; chunk < chunks; chunk++) begin
          while (!rs_command_valid) @(negedge clk);
          if (rs_command_id != (expected_id & 16'hffff) ||
              rs_command_chunk_index != chunk ||
              rs_command_chunk_first != (chunk == 0) ||
              rs_command_chunk_final != (chunk + 1 == chunks) ||
              rs_command_result_enable != (chunk + 1 == chunks) ||
              rs_command_result_word_count != output_words ||
              rs_command_result_n_base != tile * 8 ||
              rs_command_activation_streaming != (layer == 1))
            $fatal(1, "orchestrator Conv command mismatch layer=%0d tile=%0d chunk=%0d",
                   layer, tile, chunk);
          rs_command_ready = 1;
          @(posedge clk);
          @(negedge clk);
          rs_command_ready = 0;
          repeat ($urandom_range(0, 1)) @(negedge clk);
          rs_completed_command_id = expected_id;
          rs_command_done = 1;
          @(posedge clk);
          @(negedge clk);
          rs_command_done = 0;
          expected_id = (expected_id + 1) & 16'hffff;
          conv_commands = conv_commands + 1;
        end
      end

      conv_result_complete_layer_id = layer;
      conv_result_complete_job_tag = expected_tag;
      conv_result_complete_valid = 1;
      while (!conv_result_complete_ready) @(negedge clk);
      @(posedge clk);
      @(negedge clk);
      conv_result_complete_valid = 0;
      conv_tiles = conv_tiles + tiles;
      conv_commits = conv_commits + 1;
    end
  endtask

  task automatic serve_fc_layer(input int layer);
    begin
      while (!fc_job_valid) @(negedge clk);
      if (fc_job_layer_id != layer || fc_job_m_count != 1 ||
          fc_job_tag != 16'h2200 + layer || !owner_active || !active_owner_fc)
        $fatal(1, "orchestrator FC job mismatch layer=%0d", layer);
      fc_job_ready = 1;
      @(posedge clk);
      @(negedge clk);
      fc_job_ready = 0;
      repeat (2 + layer) @(negedge clk);
      fc_active_layer_id = layer;
      fc_active_job_tag = 16'h2200 + layer;
      fc_layer_done = 1;
      @(posedge clk);
      @(negedge clk);
      fc_layer_done = 0;
      fc_jobs = fc_jobs + 1;
    end
  endtask

  initial begin
    start_valid = 0;
    start_tag = 0;
    owner_active = 0;
    active_owner_fc = 0;
    owner_released = 0;
    owner_fault = 0;
    conv_parameter_request_ready = 0;
    conv_parameter_valid = 0;
    conv_result_commit_request_ready = 0;
    conv_result_complete_valid = 0;
    conv_result_complete_error = 0;
    conv_service_error = 0;
    rs_cfg_ready = 0;
    rs_command_ready = 0;
    rs_command_done = 0;
    rs_command_rejected = 0;
    rs_command_error = 0;
    rs_completed_command_id = 0;
    rs_scheduler_fault = 0;
    fc_job_ready = 0;
    fc_layer_done = 0;
    fc_job_rejected = 0;
    fc_layer_failed = 0;
    fc_active_layer_id = 0;
    fc_active_job_tag = 0;
    fc_service_error = 0;
    conv_commands = 0;
    conv_tiles = 0;
    conv_commits = 0;
    fc_jobs = 0;
    for (int lane = 0; lane < 8; lane++) begin
      conv_parameter_bias[lane] = 0;
      conv_parameter_multiplier[lane] = 18'sd70000;
      conv_parameter_right_shift[lane] = 24;
    end

    repeat (6) @(negedge clk);
    rst = 0;
    repeat (2) @(negedge clk);
    start_tag = 16'h2200;
    start_valid = 1;
    while (!start_ready) @(negedge clk);
    @(posedge clk);
    @(negedge clk);
    start_valid = 0;

    for (int layer = 1; layer <= 5; layer++)
      serve_conv_layer(layer);
    for (int layer = 6; layer <= 8; layer++)
      serve_fc_layer(layer);
    while (!inference_done) @(negedge clk);
    @(negedge clk);

    if (fault || inference_failed || busy || owner_active ||
        completed_conv_layers != 5 || completed_fc_layers != 3 ||
        owner_acquires != 2 || owner_releases != 2 ||
        conv_commands != 3912 || conv_tiles != 144 || conv_commits != 5 ||
        fc_jobs != 3)
      $fatal(1, "orchestrator retirement mismatch conv=%0d/%0d/%0d fc=%0d owners=%0d/%0d graph=%0d/%0d",
             conv_commands, conv_tiles, conv_commits, fc_jobs,
             owner_acquires, owner_releases, completed_conv_layers,
             completed_fc_layers);

    $display("ALEXNET_GRAPH_COMPUTE_ORCHESTRATOR_TEST_PASSED conv_layers=5 conv_tiles=%0d conv_commands=%0d conv_commits=%0d fc_layers=%0d owners=2",
             conv_tiles, conv_commands, conv_commits, fc_jobs);
    $finish;
  end
endmodule
