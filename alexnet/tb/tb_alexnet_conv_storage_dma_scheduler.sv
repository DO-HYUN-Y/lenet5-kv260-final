`timescale 1ns/1ps

module tb_alexnet_conv_storage_dma_scheduler;
  logic clk = 1'b0;
  logic rst;
  logic layer_start_valid, layer_start_ready;
  logic [2:0] layer_start_id;
  logic [15:0] layer_start_tag;
  logic [12:0] layer_start_word_count;
  logic [15:0] layer_start_byte_count;
  logic request_valid, request_ready;
  logic [3:0] request_layer_id;
  logic [15:0] request_n_base;
  logic [12:0] request_word_count;
  logic [15:0] request_byte_count, request_tag;
  logic transfer_complete_valid, transfer_complete_ready;
  logic transfer_complete_error;
  logic [3:0] transfer_complete_layer_id;
  logic [15:0] transfer_complete_n_base, transfer_complete_tag;
  logic [127:0] storage_axis_tdata, dma_axis_tdata;
  logic [15:0] storage_axis_tkeep, dma_axis_tkeep;
  logic storage_axis_tvalid, storage_axis_tready, storage_axis_tlast;
  logic dma_axis_tvalid, dma_axis_tready, dma_axis_tlast;
  logic layer_complete_valid, layer_complete_ready;
  logic [2:0] layer_complete_id;
  logic [15:0] layer_complete_tag;
  logic layer_complete_error;
  logic busy, fault;
  logic [5:0] active_tile_index;
  logic [15:0] active_tile_bytes;
  logic [31:0] completed_tiles, completed_layers;
  integer tile;
  integer beat;
  integer tile_words;
  integer tile_count;
  integer total_words;
  integer total_descriptors;

  alexnet_conv_storage_dma_scheduler dut (.*);
  always #2.5 clk = ~clk;

  function automatic integer words_per_tile(input integer id);
    case (id)
      1: words_per_tile = 729;
      2,3,4: words_per_tile = 169;
      5: words_per_tile = 36;
      default: words_per_tile = 0;
    endcase
  endfunction

  function automatic integer tiles_per_layer(input integer id);
    case (id)
      1: tiles_per_layer = 8;
      2: tiles_per_layer = 24;
      3: tiles_per_layer = 48;
      4,5: tiles_per_layer = 32;
      default: tiles_per_layer = 0;
    endcase
  endfunction

  task automatic run_layer(input integer id, input logic [15:0] tag);
    begin
      tile_words = words_per_tile(id);
      tile_count = tiles_per_layer(id);
      total_words = tile_words * tile_count;
      layer_start_id = id;
      layer_start_tag = tag;
      layer_start_word_count = total_words;
      layer_start_byte_count = total_words * 8;
      layer_start_valid = 1'b1;
      #1;
      while (!layer_start_ready) @(negedge clk);
      @(posedge clk);
      @(negedge clk);
      layer_start_valid = 1'b0;
      for (tile = 0; tile < tile_count; tile = tile + 1) begin
        repeat (2) begin
          @(negedge clk);
          if (request_valid)
            $fatal(1, "result DMA armed before tile data layer=%0d tile=%0d",
                   id, tile);
        end
        storage_axis_tdata = {32'(id), 32'(tile), 32'd0, 32'hcafe1234};
        storage_axis_tkeep = 16'hffff;
        storage_axis_tlast = 1'b0;
        storage_axis_tvalid = 1'b1;
        while (!request_valid) @(negedge clk);
        if (request_layer_id != id || request_n_base != tile * 8 ||
            request_word_count != tile_words ||
            request_byte_count != tile_words * 8 ||
            request_tag != tag + tile)
          $fatal(1, "post-pool descriptor mismatch layer=%0d tile=%0d", id,
                 tile);
        repeat (2) begin
          @(negedge clk);
          if (!request_valid || request_n_base != tile * 8)
            $fatal(1, "post-pool descriptor changed under backpressure");
        end
        request_ready = 1'b1;
        @(posedge clk);
        @(negedge clk);
        request_ready = 1'b0;
        total_descriptors = total_descriptors + 1;
        for (beat = 0; beat < (tile_words + 1) / 2; beat = beat + 1) begin
          storage_axis_tdata = {32'(id), 32'(tile), 32'(beat), 32'hcafe1234};
          storage_axis_tkeep = (beat + 1 == (tile_words + 1) / 2 &&
                                tile_words[0]) ? 16'h00ff : 16'hffff;
          storage_axis_tlast = beat + 1 == (tile_words + 1) / 2;
          storage_axis_tvalid = 1'b1;
          dma_axis_tready = beat % 3 != 1;
          #1;
          while (!storage_axis_tready) begin
            @(negedge clk);
            dma_axis_tready = 1'b1;
            #1;
          end
          if (!dma_axis_tvalid || dma_axis_tdata != storage_axis_tdata ||
              dma_axis_tkeep != storage_axis_tkeep ||
              dma_axis_tlast != storage_axis_tlast)
            $fatal(1, "post-pool AXIS forwarding mismatch");
          @(posedge clk);
          @(negedge clk);
          storage_axis_tvalid = 1'b0;
          if (fault || (dut.state_q != 2 &&
                        beat + 1 != (tile_words + 1) / 2))
            $fatal(1,
                   "stream terminated early layer=%0d tile=%0d beat=%0d/%0d state=%0d seen=%0d target=%0d keep=%h last=%0b",
                   id, tile, beat, (tile_words + 1) / 2, dut.state_q,
                   active_tile_bytes, dut.tile_bytes_q, storage_axis_tkeep,
                   storage_axis_tlast);
        end
        dma_axis_tready = 1'b0;
        while (!transfer_complete_ready) @(negedge clk);
        transfer_complete_layer_id = id;
        transfer_complete_n_base = tile * 8;
        transfer_complete_tag = tag + tile;
        transfer_complete_error = 1'b0;
        transfer_complete_valid = 1'b1;
        @(posedge clk);
        @(negedge clk);
        transfer_complete_valid = 1'b0;
      end

      while (!layer_complete_valid) @(negedge clk);
      if (layer_complete_id != id || layer_complete_tag != tag ||
          layer_complete_error || fault)
        $fatal(1, "post-pool layer completion mismatch layer=%0d", id);
      layer_complete_ready = 1'b1;
      @(posedge clk);
      @(negedge clk);
      layer_complete_ready = 1'b0;
      if (busy)
        $fatal(1, "post-pool scheduler remained busy after layer %0d", id);
    end
  endtask

  initial begin
    rst = 1'b1;
    layer_start_valid = 1'b0;
    layer_start_id = 0;
    layer_start_tag = 0;
    layer_start_word_count = 0;
    layer_start_byte_count = 0;
    request_ready = 1'b0;
    transfer_complete_valid = 1'b0;
    transfer_complete_error = 1'b0;
    transfer_complete_layer_id = 0;
    transfer_complete_n_base = 0;
    transfer_complete_tag = 0;
    storage_axis_tdata = 0;
    storage_axis_tkeep = 0;
    storage_axis_tvalid = 1'b0;
    storage_axis_tlast = 1'b0;
    dma_axis_tready = 1'b0;
    layer_complete_ready = 1'b0;
    total_descriptors = 0;
    repeat (5) @(negedge clk);
    rst = 1'b0;
    @(negedge clk);

    run_layer(1, 16'h1000);
    run_layer(2, 16'h2000);
    run_layer(3, 16'h3000);
    run_layer(4, 16'h4000);
    run_layer(5, 16'h5000);

    if (total_descriptors != 144 || completed_tiles != 144 ||
        completed_layers != 5 || fault)
      $fatal(1, "post-pool scheduler aggregate mismatch");
    $display("ALEXNET_CONV_STORAGE_DMA_SCHEDULER_TEST_PASSED layers=5 tiles=144 stored_words=24560 descriptors=144 pooled_geometry=verified");
    $finish;
  end

  initial begin
    #2000000;
    $fatal(1, "Conv storage DMA scheduler watchdog state=%0d tile=%0d bytes=%0d fault=%0b",
           dut.state_q, active_tile_index, active_tile_bytes, fault);
  end
endmodule
