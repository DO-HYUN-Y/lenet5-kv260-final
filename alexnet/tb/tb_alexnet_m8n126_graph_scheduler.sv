`timescale 1ns/1ps

module tb_alexnet_m8n126_graph_scheduler;
  logic clk = 1'b0;
  logic rst;
  logic start_valid, start_ready;
  logic [15:0] start_tag;
  logic command_valid, command_ready;
  logic [3:0] command_layer_id;
  logic command_is_fc, command_mode_split_n64;
  logic [7:0] command_bank_enable;
  logic [15:0] command_n_lane_mask [0:7];
  logic [15:0] command_n_base;
  logic [7:0] command_n_count;
  logic [12:0] command_m_base;
  logic [4:0] command_m_count;
  logic [3:0] command_group0_m_count, command_group1_m_count;
  logic [13:0] command_k_offset;
  logic [12:0] command_k_count;
  logic command_accum_first, command_accum_final;
  logic command_weight_fill, command_weight_release;
  logic command_result_enable;
  logic [15:0] command_context_tag, command_tile_tag;
  logic command_done, command_error;
  logic busy, inference_done, inference_failed, fault;
  logic [3:0] active_layer_id;
  logic [15:0] completed_commands;

  longint unsigned useful_macs;
  longint unsigned physical_slots;
  longint unsigned fc_useful_macs;
  longint unsigned fc_physical_slots;
  longint unsigned weight_bytes;
  int layer_commands [1:8];
  int pending_delay;
  bit command_pending;

  alexnet_m8n126_graph_scheduler dut (.*);

  always #2.5 clk = ~clk;

  function automatic int count_mask_bits();
    int result;
    begin
      result = 0;
      for (int bank = 0; bank < 8; bank++)
        for (int lane = 0; lane < 16; lane++)
          result += command_n_lane_mask[bank][lane];
      count_mask_bits = result;
    end
  endfunction

  always @(negedge clk) begin
    command_ready = !command_pending && $urandom_range(0, 4) != 0;
    command_done = 1'b0;
    command_error = 1'b0;
    if (command_pending) begin
      if (pending_delay == 0) begin
        command_done = 1'b1;
        command_pending = 1'b0;
      end else begin
        pending_delay--;
      end
    end
  end

  always @(posedge clk) begin
    if (!rst && command_valid && command_ready) begin
      int mask_bits;
      mask_bits = count_mask_bits();
      if (command_pending)
        $fatal(1, "scheduler issued a second command before completion");
      command_pending = 1'b1;
      pending_delay = $urandom_range(0, 3);
      layer_commands[command_layer_id]++;

      useful_macs += command_m_count * command_n_count * command_k_count;
      physical_slots += 1024 * command_k_count;
      if (command_is_fc) begin
        fc_useful_macs += command_m_count * command_n_count * command_k_count;
        fc_physical_slots += 1024 * command_k_count;
        if (command_m_count != 1 || command_group0_m_count != 1 ||
            command_group1_m_count != 0 || command_bank_enable != 8'h01 ||
            mask_bits != command_n_count)
          $fatal(1, "batch-one FC descriptor is not bandwidth matched");
      end else if (command_mode_split_n64) begin
        if (command_n_count != 64 || command_bank_enable != 8'hff ||
            mask_bits != 2 * command_n_count)
          $fatal(1, "split-N64 descriptor mismatch");
      end else begin
        if (mask_bits != command_n_count || command_n_count > 126)
          $fatal(1, "logical-N126 descriptor mismatch");
      end

      if (command_weight_fill)
        weight_bytes += command_n_count * command_k_count;
      if (command_result_enable != command_accum_final)
        $fatal(1, "result was not tied to the final K chunk");
      if (command_layer_id == 6) begin
        if (command_k_offset == 0 && command_k_count != 4096)
          $fatal(1, "FC6 first K chunk mismatch");
        if (command_k_offset == 4096 && command_k_count != 4096)
          $fatal(1, "FC6 second K chunk mismatch");
        if (command_k_offset == 8192 && command_k_count != 1024)
          $fatal(1, "FC6 tail K chunk mismatch");
      end
    end
  end

  initial begin
    int seed_sink;
    seed_sink = $urandom(32'h1260_0008);
    rst = 1'b1;
    start_valid = 1'b0;
    start_tag = 16'h4a80;
    command_ready = 1'b0;
    command_done = 1'b0;
    command_error = 1'b0;
    command_pending = 1'b0;
    pending_delay = 0;
    useful_macs = 0;
    physical_slots = 0;
    fc_useful_macs = 0;
    fc_physical_slots = 0;
    weight_bytes = 0;
    for (int layer = 1; layer <= 8; layer++)
      layer_commands[layer] = 0;

    repeat (8) @(negedge clk);
    rst = 1'b0;
    @(negedge clk);
    start_valid = 1'b1;
    do @(posedge clk); while (!start_ready);
    @(negedge clk);
    start_valid = 1'b0;

    for (int timeout = 0; timeout < 30000; timeout++) begin
      @(negedge clk);
      if (inference_done) begin
        if (inference_failed || fault)
          $fatal(1, "full graph scheduler failed");
        if (completed_commands != 1635)
          $fatal(1, "command total mismatch got=%0d", completed_commands);
        if (layer_commands[1] != 190 || layer_commands[2] != 138 ||
            layer_commands[3] != 88 || layer_commands[4] != 66 ||
            layer_commands[5] != 66 || layer_commands[6] != 768 ||
            layer_commands[7] != 256 || layer_commands[8] != 63)
          $fatal(1, "per-layer command totals mismatch");
        if (useful_macs != 64'd714188480)
          $fatal(1, "full AlexNet MAC total mismatch got=%0d", useful_macs);
        if (physical_slots != 64'd4595623936)
          $fatal(1, "physical slot total mismatch got=%0d", physical_slots);
        if (fc_useful_macs != 64'd58621952 ||
            fc_physical_slots != 64'd3753902080)
          $fatal(1, "FC utilization accounting mismatch");
        if (weight_bytes != 64'd61090496)
          $fatal(1, "weight byte total mismatch got=%0d", weight_bytes);
        $display("ALEXNET_M8N126_GRAPH_SCHEDULER_TEST_PASSED commands=%0d macs=%0d slots=%0d fc_macs=%0d fc_slots=%0d weights=%0d",
                 completed_commands, useful_macs, physical_slots,
                 fc_useful_macs, fc_physical_slots, weight_bytes);
        $finish;
      end
    end
    $fatal(1, "full graph scheduler timeout");
  end

endmodule
