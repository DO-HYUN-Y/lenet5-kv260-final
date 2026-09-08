`timescale 1ns/1ps

module tb_alexnet_graph_dma_descriptor_bridge;
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
  logic [31:0] dma_timeout_cycles;
  logic rs_mm2s_request_valid, rs_mm2s_request_ready;
  logic [3:0] rs_active_layer_id;
  logic [1:0] rs_mm2s_request_destination;
  logic [10:0] rs_mm2s_request_word_count;
  logic [15:0] rs_mm2s_request_byte_count, rs_mm2s_request_tag;
  logic [15:0] rs_mm2s_request_n_base;
  logic [7:0] rs_mm2s_request_chunk_index;
  logic rs_s2mm_request_valid, rs_s2mm_request_ready;
  logic [12:0] rs_s2mm_request_word_count;
  logic [15:0] rs_s2mm_request_byte_count;
  logic [15:0] rs_s2mm_request_n_base, rs_s2mm_request_tag;
  logic conv_parameter_request_valid, conv_parameter_request_ready;
  logic [2:0] conv_parameter_request_layer_id;
  logic [15:0] conv_parameter_request_n_base;
  logic [15:0] conv_parameter_request_tag;
  logic fc_parameter_request_valid, fc_parameter_request_ready;
  logic [3:0] fc_parameter_request_layer_id;
  logic [15:0] fc_parameter_request_n_base, fc_parameter_request_tag;
  logic fc_external_request_valid, fc_external_request_ready;
  logic [3:0] fc_external_request_layer_id;
  logic [15:0] fc_external_request_n_base;
  logic [13:0] fc_external_request_k_offset;
  logic [9:0] fc_external_request_k_count;
  logic [1:0] fc_external_request_destination;
  logic [9:0] fc_external_request_word_count;
  logic [15:0] fc_external_request_byte_count;
  logic [2:0] fc_external_request_m_count;
  logic [15:0] fc_external_request_tag;
  logic fc_result_request_valid, fc_result_request_ready;
  logic [3:0] fc_result_request_layer_id;
  logic [15:0] fc_result_request_n_base;
  logic [2:0] fc_result_request_m_count;
  logic [1:0] fc_result_request_destination;
  logic [15:0] fc_result_request_byte_count, fc_result_request_tag;
  logic dma_cmd_valid, dma_cmd_ready, dma_cmd_s2mm;
  logic [31:0] dma_cmd_address;
  logic [25:0] dma_cmd_length_bytes;
  logic [31:0] dma_cmd_timeout_cycles;
  logic [2:0] dma_cmd_source, dma_cmd_buffer_id;
  logic [3:0] dma_cmd_layer_id;
  logic [15:0] dma_cmd_n_base;
  logic [15:0] dma_cmd_tag;
  logic dma_armed, dma_done, dma_error;
  logic transfer_complete_valid, transfer_complete_error;
  logic [2:0] transfer_complete_source;
  logic [3:0] transfer_complete_layer_id;
  logic [15:0] transfer_complete_n_base, transfer_complete_tag;
  logic busy, fault, request_rejected;
  logic [31:0] accepted_requests, issued_commands;
  logic [31:0] completed_transfers, rejected_requests;
  int commands_checked;
  int completions_checked;

  alexnet_graph_dma_descriptor_bridge dut (.*);

  always #2.5 clk = ~clk;

  task automatic clear_request_valids;
    begin
      rs_mm2s_request_valid = 1'b0;
      rs_s2mm_request_valid = 1'b0;
      conv_parameter_request_valid = 1'b0;
      fc_parameter_request_valid = 1'b0;
      fc_external_request_valid = 1'b0;
      fc_result_request_valid = 1'b0;
    end
  endtask

  task automatic accept_and_complete(
      input int request_port,
      input logic [2:0] expected_source,
      input logic expected_s2mm,
      input logic [31:0] expected_address,
      input int expected_bytes,
      input int expected_layer,
      input int expected_n_base,
      input logic [15:0] expected_tag);
    logic [100:0] held_command;
    begin
      case (request_port)
        0: conv_parameter_request_valid = 1'b1;
        1: rs_mm2s_request_valid = 1'b1;
        2: rs_s2mm_request_valid = 1'b1;
        3: fc_parameter_request_valid = 1'b1;
        4: fc_external_request_valid = 1'b1;
        5: fc_result_request_valid = 1'b1;
        default: $fatal(1, "invalid bridge test request port");
      endcase
      #1;
      case (request_port)
        0: while (!conv_parameter_request_ready) @(negedge clk);
        1: while (!rs_mm2s_request_ready) @(negedge clk);
        2: while (!rs_s2mm_request_ready) @(negedge clk);
        3: while (!fc_parameter_request_ready) @(negedge clk);
        4: while (!fc_external_request_ready) @(negedge clk);
        5: while (!fc_result_request_ready) @(negedge clk);
      endcase
      @(posedge clk);
      @(negedge clk);
      clear_request_valids();

      while (!dma_cmd_valid) @(negedge clk);
      if (dma_cmd_source != expected_source ||
          dma_cmd_s2mm != expected_s2mm ||
          dma_cmd_address != expected_address ||
          dma_cmd_length_bytes != expected_bytes ||
          dma_cmd_layer_id != expected_layer ||
          dma_cmd_n_base != expected_n_base ||
          dma_cmd_tag != expected_tag ||
          dma_cmd_timeout_cycles != 32'd123456)
        $fatal(1,
               "DMA command mismatch src=%0d/%0d dir=%0b/%0b addr=%h/%h bytes=%0d/%0d layer=%0d/%0d tag=%h/%h",
               dma_cmd_source, expected_source, dma_cmd_s2mm,
               expected_s2mm, dma_cmd_address, expected_address,
               dma_cmd_length_bytes, expected_bytes, dma_cmd_layer_id,
               expected_layer, dma_cmd_tag, expected_tag);
      held_command = {dma_cmd_s2mm, dma_cmd_address,
                      dma_cmd_length_bytes, dma_cmd_source,
                      dma_cmd_layer_id, dma_cmd_buffer_id, dma_cmd_n_base,
                      dma_cmd_tag};
      repeat (3) begin
        dma_cmd_ready = 1'b0;
        @(negedge clk);
        if (!dma_cmd_valid ||
            {dma_cmd_s2mm, dma_cmd_address, dma_cmd_length_bytes,
             dma_cmd_source, dma_cmd_layer_id, dma_cmd_buffer_id,
             dma_cmd_n_base, dma_cmd_tag} != held_command)
          $fatal(1, "DMA command changed under backpressure");
      end
      dma_cmd_ready = 1'b1;
      @(posedge clk);
      @(negedge clk);
      dma_cmd_ready = 1'b0;
      commands_checked = commands_checked + 1;
      if (!busy)
        $fatal(1, "DMA bridge dropped busy after command launch");

      repeat (2) @(negedge clk);
      dma_armed = 1'b1;
      @(posedge clk);
      @(negedge clk);
      dma_armed = 1'b0;
      repeat (3) @(negedge clk);
      dma_done = 1'b1;
      @(posedge clk);
      #1;
      if (!transfer_complete_valid || transfer_complete_error ||
          transfer_complete_source != expected_source ||
          transfer_complete_layer_id != expected_layer ||
          transfer_complete_n_base != expected_n_base ||
          transfer_complete_tag != expected_tag)
        $fatal(1, "DMA completion metadata mismatch");
      @(negedge clk);
      dma_done = 1'b0;
      completions_checked = completions_checked + 1;
      if (busy || fault)
        $fatal(1, "DMA bridge did not return cleanly to idle");
    end
  endtask

  initial begin
    rst = 1'b1;
    input_base = INPUT_BASE;
    activation_a_base = A_BASE;
    activation_b_base = B_BASE;
    weights_base = WEIGHT_BASE;
    parameters_base = PARAM_BASE;
    final_output_base = FINAL_BASE;
    dma_timeout_cycles = 32'd123456;
    clear_request_valids();
    rs_active_layer_id = 0;
    rs_mm2s_request_destination = 0;
    rs_mm2s_request_word_count = 0;
    rs_mm2s_request_byte_count = 0;
    rs_mm2s_request_tag = 0;
    rs_mm2s_request_n_base = 0;
    rs_mm2s_request_chunk_index = 0;
    rs_s2mm_request_word_count = 0;
    rs_s2mm_request_byte_count = 0;
    rs_s2mm_request_n_base = 0;
    rs_s2mm_request_tag = 0;
    conv_parameter_request_layer_id = 0;
    conv_parameter_request_n_base = 0;
    conv_parameter_request_tag = 0;
    fc_parameter_request_layer_id = 0;
    fc_parameter_request_n_base = 0;
    fc_parameter_request_tag = 0;
    fc_external_request_layer_id = 0;
    fc_external_request_n_base = 0;
    fc_external_request_k_offset = 0;
    fc_external_request_k_count = 0;
    fc_external_request_destination = 0;
    fc_external_request_word_count = 0;
    fc_external_request_byte_count = 0;
    fc_external_request_m_count = 0;
    fc_external_request_tag = 0;
    fc_result_request_layer_id = 0;
    fc_result_request_n_base = 0;
    fc_result_request_m_count = 0;
    fc_result_request_destination = 0;
    fc_result_request_byte_count = 0;
    fc_result_request_tag = 0;
    dma_cmd_ready = 1'b0;
    dma_armed = 1'b0;
    dma_done = 1'b0;
    dma_error = 1'b0;
    commands_checked = 0;
    completions_checked = 0;
    repeat (5) @(negedge clk);
    rst = 1'b0;
    @(negedge clk);

    conv_parameter_request_layer_id = 1;
    conv_parameter_request_n_base = 8;
    conv_parameter_request_tag = 16'h1001;
    accept_and_complete(0, 2, 0, PARAM_BASE + 128, 128, 1, 8, 16'h1001);

    rs_active_layer_id = 2;
    rs_mm2s_request_destination = 0;
    rs_mm2s_request_word_count = 729;
    rs_mm2s_request_byte_count = 5832;
    rs_mm2s_request_tag = 16'h2001;
    rs_mm2s_request_n_base = 16;
    rs_mm2s_request_chunk_index = 3;
    accept_and_complete(1, 0, 0, A_BASE + 3 * 5832, 5832, 2, 16,
                        16'h2001);

    rs_mm2s_request_destination = 2;
    rs_mm2s_request_word_count = 200;
    rs_mm2s_request_byte_count = 1600;
    rs_mm2s_request_tag = 16'h2002;
    accept_and_complete(1, 1, 0,
        WEIGHT_BASE + 23232 + (2 * 1600 + 3 * 200) * 8,
        1600, 2, 16, 16'h2002);

    rs_s2mm_request_word_count = 169;
    rs_s2mm_request_byte_count = 1352;
    rs_s2mm_request_n_base = 16;
    rs_s2mm_request_tag = 16'h2003;
    accept_and_complete(2, 6, 1, B_BASE + 2 * 1352, 1352, 2, 16,
                        16'h2003);

    fc_parameter_request_layer_id = 6;
    fc_parameter_request_n_base = 24;
    fc_parameter_request_tag = 16'h6001;
    accept_and_complete(3, 5, 0, PARAM_BASE + 18432 + 24 * 16,
                        128, 6, 24, 16'h6001);

    fc_external_request_layer_id = 6;
    fc_external_request_n_base = 24;
    fc_external_request_k_offset = 968;
    fc_external_request_k_count = 968;
    fc_external_request_destination = 2;
    fc_external_request_word_count = 968;
    fc_external_request_byte_count = 7744;
    fc_external_request_m_count = 0;
    fc_external_request_tag = 16'h6002;
    accept_and_complete(4, 4, 0,
        WEIGHT_BASE + 2468544 + (3 * 9216 + 968) * 8,
        7744, 6, 24, 16'h6002);

    fc_external_request_layer_id = 7;
    fc_external_request_n_base = 32;
    fc_external_request_k_offset = 968;
    fc_external_request_k_count = 968;
    fc_external_request_destination = 0;
    fc_external_request_word_count = 121;
    fc_external_request_byte_count = 968;
    fc_external_request_m_count = 1;
    fc_external_request_tag = 16'h7001;
    accept_and_complete(4, 3, 0, B_BASE + 968, 968, 7, 32, 16'h7001);

    fc_result_request_layer_id = 8;
    fc_result_request_n_base = 8;
    fc_result_request_m_count = 1;
    fc_result_request_destination = 2;
    fc_result_request_byte_count = 8;
    fc_result_request_tag = 16'h8001;
    accept_and_complete(5, 7, 1, FINAL_BASE + 8, 8, 8, 8, 16'h8001);

    // The reused simple-mode AXI DMA controller has a 32-bit address port.
    // A mathematically valid planner descriptor above 4 GiB must be rejected.
    weights_base = 64'h0000_0001_2000_0000;
    fc_external_request_layer_id = 8;
    fc_external_request_n_base = 0;
    fc_external_request_k_offset = 0;
    fc_external_request_k_count = 968;
    fc_external_request_destination = 2;
    fc_external_request_word_count = 968;
    fc_external_request_byte_count = 7744;
    fc_external_request_m_count = 0;
    fc_external_request_tag = 16'h8bad;
    fc_external_request_valid = 1'b1;
    #1;
    while (!fc_external_request_ready) @(negedge clk);
    @(posedge clk);
    @(negedge clk);
    fc_external_request_valid = 1'b0;
    while (!request_rejected) @(negedge clk);
    if (dma_cmd_valid || !fault || rejected_requests != 1)
      $fatal(1, "DMA bridge failed to reject an address above 4 GiB");

    if (commands_checked != 8 || completions_checked != 8 ||
        accepted_requests != 9 || issued_commands != 8 ||
        completed_transfers != 8 || rejected_requests != 1)
      $fatal(1,
          "DMA bridge aggregate mismatch commands=%0d completions=%0d accepted=%0d issued=%0d completed=%0d rejected=%0d",
          commands_checked, completions_checked, accepted_requests,
          issued_commands, completed_transfers, rejected_requests);
    $display(
        "ALEXNET_GRAPH_DMA_DESCRIPTOR_BRIDGE_TEST_PASSED commands=8 mm2s=6 s2mm=2 sources=8 address_backpressure=stable upper32_rejected=1 dre_alignment=8");
    $finish;
  end

  initial begin
    #100000;
    $fatal(1, "DMA descriptor bridge watchdog");
  end
endmodule
