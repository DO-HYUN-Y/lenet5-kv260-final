`timescale 1ns/1ps

module tb_alexnet_graph_controller;
  logic clk = 1'b0;
  always #2.5 clk = ~clk;
  logic rst = 1'b1;
  logic start_valid, start_ready;
  logic [15:0] start_tag;
  logic owner_valid, owner_ready, owner_fc, owner_release_valid;
  logic owner_release_ready, owner_active, active_owner_fc, owner_released;
  logic owner_fault;
  logic conv_job_valid, conv_job_ready;
  logic [2:0] conv_layer_id;
  logic [15:0] conv_job_tag;
  logic [8:0] conv_input_h, conv_input_w;
  logic [9:0] conv_input_channels, conv_output_channels;
  logic [7:0] conv_output_h, conv_output_w;
  logic [3:0] conv_kernel;
  logic [2:0] conv_stride, conv_padding;
  logic [5:0] conv_n8_tiles, conv_input_chunks;
  logic conv_activation_streaming, conv_pool_enable, conv_flatten_output;
  logic [5:0] conv_pool_output_h, conv_pool_output_w;
  logic conv_complete_valid, conv_complete_ready;
  logic [2:0] conv_complete_layer_id;
  logic [15:0] conv_complete_tag;
  logic conv_complete_error;
  logic fc_job_valid, fc_job_ready;
  logic [3:0] fc_layer_id;
  logic [2:0] fc_m_count;
  logic [15:0] fc_job_tag;
  logic fc_complete_valid, fc_complete_ready;
  logic [3:0] fc_complete_layer_id;
  logic [15:0] fc_complete_tag;
  logic fc_complete_error, service_error;
  logic busy, inference_done, inference_failed, fault;
  logic [3:0] fault_code, active_layer_id;
  logic [4:0] phase;
  logic [15:0] active_inference_tag;
  logic [2:0] completed_conv_layers;
  logic [1:0] completed_fc_layers;

  int owner_acquires;
  int owner_releases;
  int done_pulses;
  int cycles;

  alexnet_graph_controller dut (.*);

  always @(posedge clk) begin
    if (rst) begin
      owner_active <= 1'b0;
      active_owner_fc <= 1'b0;
      owner_released <= 1'b0;
      owner_acquires <= 0;
      owner_releases <= 0;
      done_pulses <= 0;
      cycles <= 0;
    end else begin
      owner_released <= 1'b0;
      cycles <= cycles + 1;
      if (cycles > 5000)
        $fatal(1, "graph controller watchdog phase=%0d layer=%0d",
               phase, active_layer_id);
      if (owner_valid && owner_ready) begin
        if (owner_active)
          $fatal(1, "graph controller acquired over an active owner");
        owner_active <= 1'b1;
        active_owner_fc <= owner_fc;
        owner_acquires <= owner_acquires + 1;
      end
      if (owner_release_valid && owner_release_ready) begin
        if (!owner_active)
          $fatal(1, "graph controller released an idle owner");
        owner_active <= 1'b0;
        owner_released <= 1'b1;
        owner_releases <= owner_releases + 1;
      end
      if (inference_done)
        done_pulses <= done_pulses + 1;
    end
  end

  task automatic submit_start(input logic [15:0] tag);
    begin
      start_tag = tag;
      start_valid = 1'b1;
      while (!start_ready) @(negedge clk);
      @(posedge clk);
      @(negedge clk);
      start_valid = 1'b0;
    end
  endtask

  task automatic accept_conv(input int layer);
    int expected_in_h, expected_in_c, expected_out_c;
    int expected_out_h, expected_kernel, expected_stride, expected_padding;
    int expected_tiles, expected_chunks, expected_pool_h;
    begin
      case (layer)
        1: begin expected_in_h=224; expected_in_c=3; expected_out_c=64;
          expected_out_h=55; expected_kernel=11; expected_stride=4;
          expected_padding=2; expected_tiles=8; expected_chunks=1;
          expected_pool_h=27; end
        2: begin expected_in_h=27; expected_in_c=64; expected_out_c=192;
          expected_out_h=27; expected_kernel=5; expected_stride=1;
          expected_padding=2; expected_tiles=24; expected_chunks=8;
          expected_pool_h=13; end
        3: begin expected_in_h=13; expected_in_c=192; expected_out_c=384;
          expected_out_h=13; expected_kernel=3; expected_stride=1;
          expected_padding=1; expected_tiles=48; expected_chunks=24;
          expected_pool_h=0; end
        4: begin expected_in_h=13; expected_in_c=384; expected_out_c=256;
          expected_out_h=13; expected_kernel=3; expected_stride=1;
          expected_padding=1; expected_tiles=32; expected_chunks=48;
          expected_pool_h=0; end
        default: begin expected_in_h=13; expected_in_c=256;
          expected_out_c=256; expected_out_h=13; expected_kernel=3;
          expected_stride=1; expected_padding=1; expected_tiles=32;
          expected_chunks=32; expected_pool_h=6; end
      endcase
      while (!conv_job_valid) @(negedge clk);
      if (conv_layer_id != layer || conv_job_tag != 16'h6000 + layer ||
          conv_input_h != expected_in_h || conv_input_w != expected_in_h ||
          conv_input_channels != expected_in_c ||
          conv_output_channels != expected_out_c ||
          conv_output_h != expected_out_h || conv_output_w != expected_out_h ||
          conv_kernel != expected_kernel || conv_stride != expected_stride ||
          conv_padding != expected_padding || conv_n8_tiles != expected_tiles ||
          conv_input_chunks != expected_chunks ||
          conv_activation_streaming != (layer == 1) ||
          conv_pool_enable != (layer == 1 || layer == 2 || layer == 5) ||
          conv_pool_output_h != expected_pool_h ||
          conv_pool_output_w != expected_pool_h ||
          conv_flatten_output != (layer == 5))
        $fatal(1, "graph Conv%0d descriptor mismatch", layer);
      repeat (layer % 3) @(negedge clk);
      conv_job_ready = 1'b1;
      @(posedge clk);
      @(negedge clk);
      conv_job_ready = 1'b0;
      repeat (2 + layer) @(negedge clk);
      conv_complete_layer_id = layer;
      conv_complete_tag = 16'h6000 + layer;
      conv_complete_valid = 1'b1;
      while (!conv_complete_ready) @(negedge clk);
      @(posedge clk);
      @(negedge clk);
      conv_complete_valid = 1'b0;
    end
  endtask

  task automatic accept_fc(input int layer);
    begin
      while (!fc_job_valid) @(negedge clk);
      if (fc_layer_id != layer || fc_m_count != 1 ||
          fc_job_tag != 16'h6000 + layer)
        $fatal(1, "graph FC%0d descriptor mismatch", layer);
      repeat (layer - 5) @(negedge clk);
      fc_job_ready = 1'b1;
      @(posedge clk);
      @(negedge clk);
      fc_job_ready = 1'b0;
      repeat (layer) @(negedge clk);
      fc_complete_layer_id = layer;
      fc_complete_tag = 16'h6000 + layer;
      fc_complete_valid = 1'b1;
      while (!fc_complete_ready) @(negedge clk);
      @(posedge clk);
      @(negedge clk);
      fc_complete_valid = 1'b0;
    end
  endtask

  initial begin
    start_valid = 0;
    start_tag = 0;
    owner_ready = 1;
    owner_release_ready = 1;
    owner_active = 0;
    active_owner_fc = 0;
    owner_released = 0;
    owner_fault = 0;
    conv_job_ready = 0;
    conv_complete_valid = 0;
    conv_complete_layer_id = 0;
    conv_complete_tag = 0;
    conv_complete_error = 0;
    fc_job_ready = 0;
    fc_complete_valid = 0;
    fc_complete_layer_id = 0;
    fc_complete_tag = 0;
    fc_complete_error = 0;
    service_error = 0;

    repeat (6) @(negedge clk);
    rst = 0;
    repeat (2) @(negedge clk);
    submit_start(16'h6000);
    for (int layer = 1; layer <= 5; layer++)
      accept_conv(layer);
    for (int layer = 6; layer <= 8; layer++)
      accept_fc(layer);
    while (!inference_done) @(negedge clk);
    @(negedge clk);

    if (fault || inference_failed || busy || owner_active ||
        active_inference_tag != 16'h6000 || completed_conv_layers != 5 ||
        completed_fc_layers != 3 || owner_acquires != 2 ||
        owner_releases != 2 || done_pulses != 1)
      $fatal(1,
             "graph retirement mismatch conv=%0d fc=%0d owners=%0d/%0d done=%0d fault=%0b/%0b",
             completed_conv_layers, completed_fc_layers, owner_acquires,
             owner_releases, done_pulses, fault, inference_failed);

    // Reset the complete ownership domain, then prove that a mismatched Conv
    // completion cannot advance the graph or hand ownership to FC.
    rst = 1'b1;
    repeat (4) @(negedge clk);
    rst = 1'b0;
    repeat (2) @(negedge clk);
    submit_start(16'h7100);
    while (!conv_job_valid) @(negedge clk);
    conv_job_ready = 1'b1;
    @(posedge clk);
    @(negedge clk);
    conv_job_ready = 1'b0;
    conv_complete_layer_id = 1;
    conv_complete_tag = 16'h71ff;
    conv_complete_valid = 1'b1;
    while (!conv_complete_ready) @(negedge clk);
    @(posedge clk);
    @(negedge clk);
    conv_complete_valid = 1'b0;
    while (!fault) @(negedge clk);
    repeat (4) begin
      if (phase != 12 || fault_code != 2 || start_ready || fc_job_valid ||
          owner_release_valid)
        $fatal(1, "graph metadata fault was not stable");
      @(negedge clk);
    end

    $display("ALEXNET_GRAPH_CONTROLLER_TEST_PASSED order=Conv1,Conv2,Conv3,Conv4,Conv5,FC6,FC7,FC8 pools=1,2,5 owners=2 metadata_fault=stable");
    $finish;
  end
endmodule
