`timescale 1ns/1ps

module tb_alexnet_m8n128_tile_payload;
  logic clk = 1'b0;
  logic rst;
  logic command_valid, command_ready;
  logic [3:0] command_layer_id;
  logic command_mode_split_n64;
  logic [7:0] command_bank_enable;
  logic [15:0] command_n_lane_mask [0:7];
  logic [15:0] command_n_base;
  logic [7:0] command_n_count;
  logic [12:0] command_m_base;
  logic [3:0] command_group0_m_count, command_group1_m_count;
  logic [12:0] command_k_count;
  logic command_accum_first, command_accum_final, command_result_enable;
  logic [15:0] command_weight_context_tag, command_patch_context_tag;
  logic [15:0] command_tile_tag;

  logic patch_valid, patch_ready;
  logic signed [7:0] patch_values [0:15];
  logic [11:0] patch_k;
  logic patch_last;
  logic [15:0] patch_m_lane_mask;
  logic [15:0] patch_context_tag;
  logic weight_valid, weight_ready;
  logic signed [7:0] weight_values [0:7][0:15];
  logic [11:0] weight_k;
  logic weight_last;
  logic [7:0] weight_bank_enable;
  logic [15:0] weight_n_lane_mask [0:7];
  logic [15:0] weight_context_tag;

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
  logic command_done, command_error, busy, accumulator_open, fault;
  logic [31:0] active_cycles, issue_cycles;
  logic [31:0] patch_stall_cycles, weight_stall_cycles;
  logic [31:0] result_stall_cycles;
  logic [63:0] useful_mac_count, physical_mac_slot_count;

  longint signed expected_accum [0:15][0:127];
  bit expected_seen [0:15][0:127];
  int active_m_total, active_n_total;
  int active_m_base, active_n_base;
  int result_bytes_checked;
  logic [15:0] active_tile_tag;
  bit forced_result_stall;

  alexnet_m8n128_tile_payload dut (.*);

  always #2.5 clk = ~clk;

  function automatic logic [7:0] golden_requant(
      input longint signed accumulator);
    longint signed product;
    longint signed adjusted;
    longint signed rounded;
    begin
      product = accumulator * 65540;
      if (product < 0)
        adjusted = product + ((64'sd1 <<< 22) - 1);
      else
        adjusted = product + (64'sd1 <<< 22);
      rounded = adjusted >>> 23;
      if (rounded > 127)
        golden_requant = 8'h7f;
      else if (rounded < -128)
        golden_requant = 8'h80;
      else
        golden_requant = rounded[7:0];
    end
  endfunction

  function automatic logic signed [7:0] activation_value(input int m,
                                                           input int k);
    activation_value = ((m + 2*k) % 13) - 6;
  endfunction

  function automatic logic signed [7:0] weight_value(input int n,
                                                       input int k);
    weight_value = ((3*n + k) % 11) - 5;
  endfunction

  task automatic clear_expected();
    for (int m = 0; m < 16; m++)
      for (int n = 0; n < 128; n++) begin
        expected_accum[m][n] = 0;
        expected_seen[m][n] = 1'b0;
      end
  endtask

  task automatic configure_command(
      input bit split_mode,
      input int n_count,
      input int m0_count,
      input int m1_count,
      input int k_count,
      input bit accum_first,
      input bit accum_final,
      input int k_seed,
      input logic [15:0] tile_tag);
    int bank_count;
    begin
      command_layer_id = split_mode ? 1 : 3;
      command_mode_split_n64 = split_mode;
      command_n_base = split_mode ? 16'd64 : 16'd126;
      command_n_count = n_count;
      command_m_base = split_mode ? 13'd160 : 13'd32;
      command_group0_m_count = m0_count;
      command_group1_m_count = m1_count;
      command_k_count = k_count;
      command_accum_first = accum_first;
      command_accum_final = accum_final;
      command_result_enable = accum_final;
      command_weight_context_tag = 16'hca00 | command_layer_id;
      command_patch_context_tag = tile_tag;
      command_tile_tag = tile_tag;
      command_bank_enable = 0;
      for (int bank = 0; bank < 8; bank++)
        command_n_lane_mask[bank] = 0;
      bank_count = (n_count + 15) / 16;
      if (split_mode) begin
        command_bank_enable = 8'hff;
        for (int bank = 0; bank < 4; bank++) begin
          for (int lane = 0; lane < 16; lane++) begin
            command_n_lane_mask[bank][lane] = 16*bank + lane < n_count;
            command_n_lane_mask[bank+4][lane] =
                command_n_lane_mask[bank][lane];
          end
        end
      end else begin
        for (int bank = 0; bank < 8; bank++) begin
          command_bank_enable[bank] = bank < bank_count;
          for (int lane = 0; lane < 16; lane++)
            command_n_lane_mask[bank][lane] =
                16*bank + lane < n_count;
        end
      end

      if (accum_first) begin
        clear_expected();
        active_m_total = m0_count + m1_count;
        active_n_total = n_count;
        active_m_base = command_m_base;
        active_n_base = command_n_base;
        active_tile_tag = tile_tag;
      end

      for (int k = 0; k < k_count; k++) begin
        for (int m = 0; m < active_m_total; m++) begin
          int patch_lane;
          patch_lane = split_mode && m >= m0_count ? m - m0_count + 8 : m;
          for (int n = 0; n < n_count; n++)
            expected_accum[m][n] +=
                activation_value(patch_lane, k_seed+k) *
                weight_value(n, k_seed+k);
        end
      end
    end
  endtask

  task automatic send_command_and_payload(
      input bit split_mode,
      input int n_count,
      input int m0_count,
      input int m1_count,
      input int k_count,
      input bit accum_first,
      input bit accum_final,
      input int k_seed,
      input logic [15:0] tile_tag);
    bit accepted;
    begin
      configure_command(split_mode, n_count, m0_count, m1_count, k_count,
                        accum_first, accum_final, k_seed, tile_tag);
      @(negedge clk);
      command_valid = 1'b1;
      do @(posedge clk); while (!command_ready);
      @(negedge clk);
      command_valid = 1'b0;

      for (int k = 0; k < k_count; k++) begin
        for (int lane = 0; lane < 16; lane++)
          patch_values[lane] = activation_value(lane, k_seed+k);
        patch_k = k;
        weight_k = k;
        patch_last = k == k_count-1;
        weight_last = patch_last;
        patch_m_lane_mask = 0;
        for (int lane = 0; lane < 8; lane++) begin
          patch_m_lane_mask[lane] = lane < m0_count;
          patch_m_lane_mask[lane+8] = split_mode && lane < m1_count;
        end
        patch_context_tag = tile_tag;
        weight_context_tag = command_weight_context_tag;
        weight_bank_enable = split_mode ? 8'h0f : command_bank_enable;
        for (int bank = 0; bank < 8; bank++) begin
          weight_n_lane_mask[bank] = split_mode && bank >= 4 ? 0 :
                                     command_n_lane_mask[bank];
          for (int lane = 0; lane < 16; lane++)
            weight_values[bank][lane] =
                weight_value(16*bank + lane, k_seed+k);
        end

        // Deterministically exercise both independent payload boundaries;
        // randomized valid gaps below add wider phase variation.
        if (k == 0) begin
          @(negedge clk);
          patch_valid = 1'b1;
          weight_valid = 1'b0;
          @(posedge clk);
        end else if (k == 1) begin
          @(negedge clk);
          patch_valid = 1'b0;
          weight_valid = 1'b1;
          @(posedge clk);
        end

        accepted = 1'b0;
        while (!accepted) begin
          @(negedge clk);
          patch_valid = $urandom_range(0, 4) != 0;
          weight_valid = $urandom_range(0, 4) != 0;
          @(posedge clk);
          accepted = patch_valid && patch_ready && weight_valid && weight_ready;
        end
        @(negedge clk);
        patch_valid = 1'b0;
        weight_valid = 1'b0;
      end

      for (int timeout = 0; timeout < 4000; timeout++) begin
        @(posedge clk);
        if (command_done) begin
          if (command_error || fault)
            $fatal(1, "payload command failed split=%0d final=%0d",
                   split_mode, accum_final);
          if (accum_final && accumulator_open)
            $fatal(1, "final payload command left accumulator open");
          if (!accum_final && !accumulator_open)
            $fatal(1, "non-final payload command closed accumulator");
          return;
        end
      end
      $fatal(1, "payload command timeout split=%0d final=%0d state=%0d",
             split_mode, accum_final, dut.state_q);
    end
  endtask

  always @(negedge clk) begin
    if (rst) begin
      result_ready = 1'b0;
      forced_result_stall = 1'b0;
    end else if (!forced_result_stall && result_valid) begin
      result_ready = 1'b0;
      forced_result_stall = 1'b1;
    end else begin
      result_ready = $urandom_range(0, 3) != 0;
    end
  end

  always_comb begin
    parameter_request_ready = 1'b1;
    parameter_valid = 1'b1;
    parameter_n_base = parameter_request_n_base;
    parameter_context_tag = parameter_request_context_tag;
    parameter_relu = 0;
    for (int lane = 0; lane < 8; lane++) begin
      parameter_bias[lane] = 0;
      parameter_multiplier[lane] = 18'sd65540;
      parameter_right_shift[lane] = 6'd23;
    end
  end

  always @(posedge clk) begin
    if (!rst && result_valid && result_ready) begin
      int group_offset;
      group_offset = result_m_base - active_m_base;
      if (result_tile_tag != active_tile_tag)
        $fatal(1, "payload result tag mismatch");
      for (int m = 0; m < 8; m++) begin
        for (int lane = 0; lane < 8; lane++) begin
          int logical_m;
          int logical_n;
          logic [7:0] got;
          logical_m = group_offset + m;
          logical_n = result_n_base - active_n_base + lane;
          got = result_values[m][lane*8 +: 8];
          if (m < result_m_count && logical_n < active_n_total &&
              result_lane_mask[m][lane]) begin
            if (got !== golden_requant(expected_accum[logical_m][logical_n]))
              $fatal(1,
                     "payload result mismatch m=%0d n=%0d got=%0d expected=%0d accum=%0d",
                     logical_m, logical_n, $signed(got),
                     $signed(golden_requant(expected_accum[logical_m][logical_n])),
                     expected_accum[logical_m][logical_n]);
            if (expected_seen[logical_m][logical_n])
              $fatal(1, "payload duplicated result m=%0d n=%0d",
                     logical_m, logical_n);
            expected_seen[logical_m][logical_n] = 1'b1;
            result_bytes_checked++;
          end else if (m < result_m_count &&
                       (got != 0 || result_lane_mask[m][lane])) begin
            $fatal(1, "payload failed to zero/mask inactive result m=%0d n=%0d",
                   logical_m, logical_n);
          end
        end
      end
    end
  end

  task automatic verify_all_seen();
    for (int m = 0; m < active_m_total; m++)
      for (int n = 0; n < active_n_total; n++)
        if (!expected_seen[m][n])
          $fatal(1, "payload omitted result m=%0d n=%0d", m, n);
  endtask

  initial begin
    int seed_sink;
    seed_sink = $urandom(32'h8128_1260);
    rst = 1'b1;
    command_valid = 1'b0;
    patch_valid = 1'b0;
    weight_valid = 1'b0;
    result_ready = 1'b0;
    forced_result_stall = 1'b0;
    result_bytes_checked = 0;
    clear_expected();
    for (int bank = 0; bank < 8; bank++) begin
      command_n_lane_mask[bank] = 0;
      weight_n_lane_mask[bank] = 0;
      for (int lane = 0; lane < 16; lane++)
        weight_values[bank][lane] = 0;
    end
    for (int lane = 0; lane < 16; lane++)
      patch_values[lane] = 0;

    repeat (8) @(negedge clk);
    rst = 1'b0;

    // Wide N18 tile: retain PE accumulators across two K commands.
    send_command_and_payload(0, 18, 3, 0, 2, 1, 0, 0, 16'h4100);
    send_command_and_payload(0, 18, 3, 0, 3, 0, 1, 2, 16'h4100);
    verify_all_seen();

    // Split mode: lower four streamed banks are broadcast into the upper
    // cluster, producing independent M8 and M5 result groups over the same N64.
    send_command_and_payload(1, 64, 8, 5, 5, 1, 1, 11, 16'h5200);
    verify_all_seen();

    if (issue_cycles != 10)
      $fatal(1, "payload issue count mismatch got=%0d expected=10", issue_cycles);
    if (result_bytes_checked != 54 + 832)
      $fatal(1, "payload result byte count mismatch got=%0d", result_bytes_checked);
    if (patch_stall_cycles == 0 || weight_stall_cycles == 0 ||
        result_stall_cycles == 0)
      $fatal(1, "payload randomized stalls did not exercise every boundary");
    if (useful_mac_count != 54*5 + 832*5 ||
        physical_mac_slot_count != 64'd10*1024)
      $fatal(1, "payload MAC accounting mismatch useful=%0d physical=%0d",
             useful_mac_count, physical_mac_slot_count);

    $display("ALEXNET_M8N128_TILE_PAYLOAD_TEST_PASSED bytes=%0d issues=%0d active=%0d patch_stall=%0d weight_stall=%0d result_stall=%0d",
             result_bytes_checked, issue_cycles, active_cycles,
             patch_stall_cycles, weight_stall_cycles, result_stall_cycles);
    $finish;
  end

endmodule
