`timescale 1ns/1ps

module tb_alexnet_m8n126_graph_payload_engine;
  logic clk = 1'b0;
  logic rst;
  logic start_valid, start_ready;
  logic [15:0] start_tag;

  logic weight_request_valid, weight_request_ready;
  logic [3:0] weight_request_layer_id;
  logic [15:0] weight_request_n_base;
  logic [13:0] weight_request_k_offset;
  logic [12:0] weight_request_k_count;
  logic [7:0] weight_request_bank_enable;
  logic [15:0] weight_request_n_lane_mask [0:7];
  logic [15:0] weight_request_context_tag;
  logic weight_axis_valid, weight_axis_ready;
  logic [127:0] weight_axis_data;
  logic weight_axis_last;

  logic patch_request_valid, patch_request_ready;
  logic [3:0] patch_request_layer_id;
  logic [12:0] patch_request_m_base;
  logic [13:0] patch_request_k_offset;
  logic [12:0] patch_request_k_count;
  logic [15:0] patch_request_m_lane_mask;
  logic [15:0] patch_request_context_tag;
  logic patch_axis_valid, patch_axis_ready;
  logic [127:0] patch_axis_data;
  logic patch_axis_last;

  logic parameter_request_valid, parameter_request_ready;
  logic [3:0] parameter_request_layer_id;
  logic [15:0] parameter_request_n_base;
  logic [15:0] parameter_request_context_tag;
  logic parameter_valid, parameter_ready;
  logic [15:0] parameter_n_base, parameter_context_tag;
  logic signed [31:0] parameter_bias [0:7];
  logic signed [17:0] parameter_multiplier [0:7];
  logic [5:0] parameter_right_shift [0:7];
  logic [7:0] parameter_relu;

  logic result_valid, result_ready;
  logic [63:0] result_values [0:7];
  logic [7:0] result_lane_mask [0:7];
  logic [3:0] result_m_count;
  logic [12:0] result_m_base;
  logic [15:0] result_n_base;
  logic [15:0] result_tile_tag;
  logic result_last_slice;

  logic busy, inference_done, inference_failed, fault;
  logic [3:0] active_layer_id;
  logic [15:0] completed_commands;
  logic [31:0] active_cycles, issue_cycles;
  logic [31:0] patch_stall_cycles, weight_stall_cycles;
  logic [31:0] result_stall_cycles;
  logic [31:0] weight_words_loaded, patch_words_loaded;
  logic [31:0] completed_result_slices;
  logic [63:0] useful_mac_count, physical_mac_slot_count;

  int result_bytes_checked;
  int result_slices_checked;
  int result_last_checked;
  bit forced_result_stall;

  alexnet_m8n126_graph_payload_engine #(
      .SERVICE_TIMEOUT_CYCLES(100000)
  ) dut (.*);

  always #2.5 clk = ~clk;

  task automatic send_weight_fill();
    int words;
    begin
      wait (weight_request_valid);
      if (weight_request_layer_id != 1 || weight_request_n_base != 0 ||
          weight_request_k_offset != 0 || weight_request_k_count != 363 ||
          weight_request_bank_enable != 8'h0f)
        $fatal(1, "unexpected first Conv1 weight request");
      for (int bank = 0; bank < 4; bank++)
        if (weight_request_n_lane_mask[bank] != 16'hffff)
          $fatal(1, "weight lane mask mismatch bank=%0d", bank);
      for (int bank = 4; bank < 8; bank++)
        if (weight_request_n_lane_mask[bank] != 0)
          $fatal(1, "upper split bank must not be externally filled bank=%0d",
                 bank);
      @(posedge clk);

      words = 4 * 363;
      for (int word_index = 0; word_index < words; word_index++) begin
        @(negedge clk);
        weight_axis_valid = 1'b1;
        weight_axis_data = {16{8'sd1}};
        weight_axis_last = word_index == words-1;
        do @(posedge clk); while (!weight_axis_ready);
      end
      @(negedge clk);
      weight_axis_valid = 1'b0;
      weight_axis_last = 1'b0;
    end
  endtask

  task automatic send_patch_fill(input int expected_m_base);
    begin
      wait (patch_request_valid);
      if (patch_request_layer_id != 1 ||
          patch_request_m_base != expected_m_base ||
          patch_request_k_offset != 0 || patch_request_k_count != 363 ||
          patch_request_m_lane_mask != 16'hffff)
        $fatal(1, "unexpected Conv1 patch request m_base=%0d",
               expected_m_base);
      @(posedge clk);

      for (int k = 0; k < 363; k++) begin
        @(negedge clk);
        patch_axis_valid = 1'b1;
        patch_axis_data = {16{8'sd1}};
        patch_axis_last = k == 362;
        do @(posedge clk); while (!patch_axis_ready);
      end
      @(negedge clk);
      patch_axis_valid = 1'b0;
      patch_axis_last = 1'b0;
    end
  endtask

  always_comb begin
    parameter_request_ready = 1'b1;
    parameter_valid = 1'b1;
    parameter_n_base = parameter_request_n_base;
    parameter_context_tag = parameter_request_context_tag;
    parameter_relu = 8'h00;
    for (int lane = 0; lane < 8; lane++) begin
      parameter_bias[lane] = 0;
      parameter_multiplier[lane] = 18'sd65540;
      parameter_right_shift[lane] = 6'd23;
    end
  end

  always @(negedge clk) begin
    if (rst) begin
      result_ready = 1'b0;
      forced_result_stall = 1'b0;
    end else if (result_valid && !forced_result_stall) begin
      result_ready = 1'b0;
      forced_result_stall = 1'b1;
    end else begin
      result_ready = $urandom_range(0, 3) != 0;
    end
  end

  always @(posedge clk) begin
    if (!rst && result_valid && result_ready) begin
      int expected_command;
      int expected_group_base;
      expected_command = result_m_base >= 16;
      expected_group_base = expected_command ? 16 : 0;
      if (result_m_base != expected_group_base &&
          result_m_base != expected_group_base + 8)
        $fatal(1, "unexpected result M base %0d", result_m_base);
      if (result_n_base > 56 || result_n_base[2:0] != 0)
        $fatal(1, "unexpected result N base %0d", result_n_base);
      if (result_tile_tag != start_tag + expected_command)
        $fatal(1, "result tag mismatch got=%0h expected=%0h",
               result_tile_tag, start_tag + expected_command);
      if (result_m_count != 8)
        $fatal(1, "result M count mismatch got=%0d", result_m_count);
      for (int row = 0; row < 8; row++) begin
        if (result_lane_mask[row] != 8'hff)
          $fatal(1, "result lane mask mismatch row=%0d", row);
        for (int lane = 0; lane < 8; lane++) begin
          if ($signed(result_values[row][lane*8 +: 8]) !== 8'sd3)
            $fatal(1,
                   "golden mismatch m=%0d n=%0d got=%0d expected=3",
                   result_m_base + row, result_n_base + lane,
                   $signed(result_values[row][lane*8 +: 8]));
          result_bytes_checked++;
        end
      end
      result_slices_checked++;
      if (result_last_slice) begin
        if (result_m_base != expected_group_base + 8 ||
            result_n_base != 56)
          $fatal(1, "result_last_slice asserted on wrong slice");
        result_last_checked++;
      end
    end
  end

  initial begin
    int seed_sink;
    seed_sink = $urandom(32'h8126_0001);
    rst = 1'b1;
    start_valid = 1'b0;
    start_tag = 16'h6200;
    weight_request_ready = 1'b1;
    weight_axis_valid = 1'b0;
    weight_axis_data = '0;
    weight_axis_last = 1'b0;
    patch_request_ready = 1'b1;
    patch_axis_valid = 1'b0;
    patch_axis_data = '0;
    patch_axis_last = 1'b0;
    result_ready = 1'b0;
    forced_result_stall = 1'b0;
    result_bytes_checked = 0;
    result_slices_checked = 0;
    result_last_checked = 0;

    repeat (8) @(negedge clk);
    rst = 1'b0;
    @(negedge clk);
    start_valid = 1'b1;
    do @(posedge clk); while (!start_ready);
    @(negedge clk);
    start_valid = 1'b0;

    send_weight_fill();
    send_patch_fill(0);
    wait (completed_commands == 1);

    // The second M16 tile must reuse the resident Conv1 N64 weight set.
    fork
      begin
        wait (weight_request_valid);
        $fatal(1, "second Conv1 M tile unexpectedly reloaded weights");
      end
      begin
        send_patch_fill(16);
      end
    join_any
    disable fork;

    for (int timeout = 0; timeout < 10000; timeout++) begin
      @(posedge clk);
      if (completed_commands == 2)
        break;
      if (fault || inference_failed)
        $fatal(1, "graph payload engine faulted");
      if (timeout == 9999)
        $fatal(1, "second Conv1 command timeout");
    end
    repeat (4) @(posedge clk);

    if (fault || inference_failed)
      $fatal(1, "graph payload engine ended in fault");
    if (weight_words_loaded != 4*363)
      $fatal(1, "weight load count mismatch got=%0d", weight_words_loaded);
    if (patch_words_loaded != 2*363)
      $fatal(1, "patch load count mismatch got=%0d", patch_words_loaded);
    if (issue_cycles != 2*363)
      $fatal(1, "issue count mismatch got=%0d", issue_cycles);
    if (useful_mac_count != 64'd2*363*16*64 ||
        physical_mac_slot_count != 64'd2*363*1024)
      $fatal(1, "engine MAC accounting mismatch useful=%0d physical=%0d",
             useful_mac_count, physical_mac_slot_count);
    if (result_slices_checked != 32 || completed_result_slices != 32 ||
        result_bytes_checked != 2048 || result_last_checked != 2)
      $fatal(1,
             "result coverage mismatch slices=%0d engine_slices=%0d bytes=%0d last=%0d",
             result_slices_checked, completed_result_slices,
             result_bytes_checked, result_last_checked);
    if (result_stall_cycles == 0)
      $fatal(1, "result backpressure was not observed");

    $display("ALEXNET_M8N126_GRAPH_PAYLOAD_ENGINE_TEST_PASSED commands=%0d weight_words=%0d patch_words=%0d result_bytes=%0d issue=%0d active=%0d result_stall=%0d",
             completed_commands, weight_words_loaded, patch_words_loaded,
             result_bytes_checked, issue_cycles, active_cycles,
             result_stall_cycles);
    $finish;
  end

endmodule
