`timescale 1ns/1ps

module tb_alexnet_ddr_address_planner;
  localparam logic [63:0] INPUT_BASE = 64'h0000_0000_1000_0000;
  localparam logic [63:0] A_BASE = 64'h0000_0000_1100_0000;
  localparam logic [63:0] B_BASE = 64'h0000_0000_1200_0000;
  localparam logic [63:0] WEIGHT_BASE = 64'h0000_0000_2000_0000;
  localparam logic [63:0] PARAM_BASE = 64'h0000_0000_3000_0000;
  localparam logic [63:0] FINAL_BASE = 64'h0000_0000_4000_0000;

  logic clk = 1'b0;
  logic rst;
  logic [63:0] input_base, activation_a_base, activation_b_base;
  logic [63:0] weights_base, parameters_base, final_output_base;
  logic request_valid, request_ready;
  logic [2:0] request_kind;
  logic [3:0] request_layer_id;
  logic [15:0] request_n_base;
  logic [7:0] request_chunk_index;
  logic [13:0] request_k_offset;
  logic [9:0] request_k_count;
  logic [12:0] request_word_count;
  logic [15:0] request_byte_count;
  logic [2:0] request_m_count;
  logic [15:0] request_tag;
  logic descriptor_valid, descriptor_ready, descriptor_error;
  logic [2:0] descriptor_kind, descriptor_buffer_id;
  logic [3:0] descriptor_layer_id;
  logic [63:0] descriptor_address;
  logic [15:0] descriptor_byte_count;
  logic [12:0] descriptor_word_count;
  logic [15:0] descriptor_tag;
  logic busy, fault;
  logic [31:0] accepted_requests, rejected_requests, completed_descriptors;

  int positive_requests;
  int request_sequence;

  alexnet_ddr_address_planner dut (.*);

  always #2.5 clk = ~clk;

  function automatic int conv_tiles(input int layer);
    case (layer)
      1: conv_tiles = 8;
      2: conv_tiles = 24;
      3: conv_tiles = 48;
      4,5: conv_tiles = 32;
      default: conv_tiles = 0;
    endcase
  endfunction

  function automatic int conv_chunks(input int layer);
    case (layer)
      1: conv_chunks = 1;
      2: conv_chunks = 8;
      3: conv_chunks = 24;
      4: conv_chunks = 48;
      5: conv_chunks = 32;
      default: conv_chunks = 0;
    endcase
  endfunction

  function automatic int conv_input_spatial(input int layer);
    case (layer)
      2: conv_input_spatial = 729;
      3,4,5: conv_input_spatial = 169;
      default: conv_input_spatial = 0;
    endcase
  endfunction

  function automatic int conv_stored_spatial(input int layer);
    case (layer)
      1: conv_stored_spatial = 729;
      2,3,4: conv_stored_spatial = 169;
      5: conv_stored_spatial = 36;
      default: conv_stored_spatial = 0;
    endcase
  endfunction

  function automatic int conv_chunk_k(input int layer);
    case (layer)
      1: conv_chunk_k = 363;
      2: conv_chunk_k = 200;
      3,4,5: conv_chunk_k = 72;
      default: conv_chunk_k = 0;
    endcase
  endfunction

  function automatic int layer_k(input int layer);
    case (layer)
      1: layer_k = 363;
      2: layer_k = 1600;
      3: layer_k = 1728;
      4: layer_k = 3456;
      5: layer_k = 2304;
      6: layer_k = 9216;
      7,8: layer_k = 4096;
      default: layer_k = 0;
    endcase
  endfunction

  function automatic int weight_offset(input int layer);
    case (layer)
      1: weight_offset = 0;
      2: weight_offset = 23232;
      3: weight_offset = 330432;
      4: weight_offset = 993984;
      5: weight_offset = 1878720;
      6: weight_offset = 2468544;
      7: weight_offset = 40217280;
      8: weight_offset = 56994496;
      default: weight_offset = 0;
    endcase
  endfunction

  function automatic int parameter_offset(input int layer);
    case (layer)
      1: parameter_offset = 0;
      2: parameter_offset = 1024;
      3: parameter_offset = 4096;
      4: parameter_offset = 10240;
      5: parameter_offset = 14336;
      6: parameter_offset = 18432;
      7: parameter_offset = 83968;
      8: parameter_offset = 149504;
      default: parameter_offset = 0;
    endcase
  endfunction

  function automatic int fc_tiles(input int layer);
    case (layer)
      6,7: fc_tiles = 512;
      8: fc_tiles = 125;
      default: fc_tiles = 0;
    endcase
  endfunction

  task automatic issue_request(
      input int kind,
      input int layer,
      input int n_base,
      input int chunk_index,
      input int k_offset,
      input int k_count,
      input int words,
      input int bytes,
      input int m_count,
      input int expected_buffer,
      input logic [63:0] expected_address,
      input logic expected_error);
    logic [63:0] held_address;
    begin
      request_kind = kind;
      request_layer_id = layer;
      request_n_base = n_base;
      request_chunk_index = chunk_index;
      request_k_offset = k_offset;
      request_k_count = k_count;
      request_word_count = words;
      request_byte_count = bytes;
      request_m_count = m_count;
      request_tag = request_sequence[15:0];
      request_valid = 1'b1;
      #1;
      while (!request_ready) @(negedge clk);
      @(posedge clk);
      @(negedge clk);
      request_valid = 1'b0;
      while (!descriptor_valid) @(negedge clk);
      if (!descriptor_valid || descriptor_error != expected_error ||
          descriptor_kind != kind || descriptor_buffer_id != expected_buffer ||
          descriptor_layer_id != layer ||
          descriptor_address != expected_address ||
          descriptor_byte_count != bytes || descriptor_word_count != words ||
          descriptor_tag != request_sequence[15:0])
        $fatal(1,
               "DDR descriptor mismatch seq=%0d kind=%0d layer=%0d n=%0d chunk=%0d k=%0d/%0d addr=%h/%h words=%0d/%0d bytes=%0d/%0d err=%0b/%0b",
               request_sequence, kind, layer, n_base, chunk_index, k_offset,
               k_count, descriptor_address, expected_address,
               descriptor_word_count, words, descriptor_byte_count, bytes,
               descriptor_error, expected_error);
      held_address = descriptor_address;
      repeat (2) begin
        descriptor_ready = 1'b0;
        @(negedge clk);
        if (!descriptor_valid || descriptor_address != held_address)
          $fatal(1, "DDR descriptor changed under backpressure");
      end
      descriptor_ready = 1'b1;
      @(posedge clk);
      @(negedge clk);
      descriptor_ready = 1'b0;
      if (descriptor_valid || busy)
        $fatal(1, "DDR descriptor did not retire");
      if (!expected_error)
        positive_requests = positive_requests + 1;
      request_sequence = request_sequence + 1;
    end
  endtask

  initial begin
    int tiles;
    int chunks;
    int input_words;
    int stored_words;
    int chunk_words;
    int total_k;
    int k_offset;
    int k_count;
    int fc_chunk;
    logic [63:0] source_base;
    logic [63:0] result_base;
    rst = 1'b1;
    input_base = INPUT_BASE;
    activation_a_base = A_BASE;
    activation_b_base = B_BASE;
    weights_base = WEIGHT_BASE;
    parameters_base = PARAM_BASE;
    final_output_base = FINAL_BASE;
    request_valid = 0;
    request_kind = 0;
    request_layer_id = 0;
    request_n_base = 0;
    request_chunk_index = 0;
    request_k_offset = 0;
    request_k_count = 0;
    request_word_count = 0;
    request_byte_count = 0;
    request_m_count = 0;
    request_tag = 0;
    descriptor_ready = 0;
    positive_requests = 0;
    request_sequence = 1;
    repeat (5) @(negedge clk);
    rst = 1'b0;
    @(negedge clk);

    // Full physical Conv1..Conv5 service plan.
    for (int layer = 1; layer <= 5; layer++) begin
      tiles = conv_tiles(layer);
      chunks = conv_chunks(layer);
      input_words = conv_input_spatial(layer);
      stored_words = conv_stored_spatial(layer);
      chunk_words = conv_chunk_k(layer);
      source_base = layer[0] ? B_BASE : A_BASE;
      result_base = layer[0] ? A_BASE : B_BASE;
      for (int tile = 0; tile < tiles; tile++) begin
        issue_request(2, layer, tile * 8, 0, 0, 0, 16, 128, 0, 4,
            PARAM_BASE + parameter_offset(layer) + tile * 8 * 16, 1'b0);
        for (int chunk = 0; chunk < chunks; chunk++) begin
          if (layer != 1)
            issue_request(0, layer, tile * 8, chunk, 0, 0,
                input_words, input_words * 8, 0, layer[0] ? 2 : 1,
                source_base + chunk * input_words * 8, 1'b0);
          issue_request(1, layer, tile * 8, chunk, 0, 0,
              chunk_words, chunk_words * 8, 0, 3,
              WEIGHT_BASE + weight_offset(layer) +
                  (tile * layer_k(layer) + chunk * chunk_words) * 8, 1'b0);
        end
        issue_request(3, layer, tile * 8, 0, 0, 0,
            stored_words, stored_words * 8, 0, layer[0] ? 1 : 2,
            result_base + tile * stored_words * 8, 1'b0);
      end
    end

    // Full physical FC6..FC8 plan. FC6 activation is intentionally absent:
    // it is supplied by alexnet_fc6_flatten_injector.
    for (int layer = 6; layer <= 8; layer++) begin
      tiles = fc_tiles(layer);
      total_k = layer_k(layer);
      for (int tile = 0; tile < tiles; tile++) begin
        issue_request(2, layer, tile * 8, 0, 0, 0, 16, 128, 0, 4,
            PARAM_BASE + parameter_offset(layer) + tile * 8 * 16, 1'b0);
        k_offset = 0;
        fc_chunk = 0;
        while (k_offset < total_k) begin
          k_count = total_k - k_offset > 968 ? 968 : total_k - k_offset;
          if (layer != 6)
            issue_request(0, layer, tile * 8, 0, k_offset, k_count,
                k_count / 8, k_count, 1, layer == 7 ? 2 : 1,
                (layer == 7 ? B_BASE : A_BASE) + k_offset, 1'b0);
          issue_request(1, layer, tile * 8, fc_chunk, k_offset, k_count,
              k_count, k_count * 8, 0, 3,
              WEIGHT_BASE + weight_offset(layer) +
                  (tile * total_k + k_offset) * 8, 1'b0);
          k_offset = k_offset + k_count;
          fc_chunk = fc_chunk + 1;
        end
        issue_request(3, layer, tile * 8, 0, 0, 0, 1, 8, 1,
            layer == 6 ? 2 : layer == 7 ? 1 : 5,
            (layer == 6 ? B_BASE : layer == 7 ? A_BASE : FINAL_BASE) +
                tile * 8, 1'b0);
      end
    end

    // Conv1 activation must use the direct camera stream, never a DDR read.
    issue_request(0, 1, 0, 0, 0, 0, 0, 0, 0, 0, INPUT_BASE, 1'b1);
    repeat (5) begin
      if (!fault)
        $fatal(1, "DDR planner rejection fault did not remain stable");
      @(negedge clk);
    end

    if (positive_requests != 21892 || accepted_requests != 21892 ||
        rejected_requests != 1 || completed_descriptors != 21893)
      $fatal(1,
             "DDR planner aggregate mismatch positive=%0d accepted=%0d rejected=%0d completed=%0d",
             positive_requests, accepted_requests, rejected_requests,
             completed_descriptors);
    $display(
        "ALEXNET_DDR_ADDRESS_PLANNER_TEST_PASSED descriptors=21893 accepted=21892 rejected=1 conv1_direct_stream=protected fc6_flatten=internal weight_bytes=61090496 parameter_bytes=165504");
    $finish;
  end
endmodule
