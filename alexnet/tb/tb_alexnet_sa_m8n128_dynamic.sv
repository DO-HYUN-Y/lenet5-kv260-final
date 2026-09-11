`timescale 1ns/1ps

module tb_alexnet_sa_m8n128_dynamic;

  localparam int TILE_TAG_W = 16;

  logic clk = 1'b0;
  logic rst;
  logic mode_split_n64;
  logic [7:0] bank_enable;
  logic group_ce [0:1];
  logic signed [7:0] group_act_lo [0:1][0:3];
  logic signed [7:0] group_act_hi [0:1][0:3];
  logic group_issue_valid [0:1];
  logic group_tile_clear [0:1];
  logic group_reduce_last [0:1];
  logic [1:0] group_m_lane_mask [0:1][0:3];
  logic [TILE_TAG_W-1:0] group_tile_tag [0:1];
  logic signed [7:0] bank_weight [0:7][0:15];
  logic result_valid [0:7][0:3][0:15];
  logic result_ready [0:7][0:3][0:15];
  logic signed [31:0] result_lo [0:7][0:3][0:15];
  logic signed [31:0] result_hi [0:7][0:3][0:15];
  logic [1:0] result_lane_mask [0:7][0:3][0:15];
  logic bank_source_group [0:7];
  logic [2:0] bank_n16_slot [0:7];
  logic [TILE_TAG_W-1:0] bank_result_tag [0:7];

  longint signed expected_lo [0:7][0:3][0:15];
  longint signed expected_hi [0:7][0:3][0:15];
  logic [1:0] expected_mask [0:7][0:3][0:15];
  bit expected_valid [0:7][0:3][0:15];
  bit result_seen [0:7][0:3][0:15];
  int checked_results;

  alexnet_sa_m8n128_dynamic dut (.*);

  always #2.5 clk = ~clk;

  function automatic logic signed [7:0] random_int8();
    random_int8 = $urandom_range(0, 255) - 128;
  endfunction

  task automatic set_m_count(input int group, input int count);
    for (int row = 0; row < 4; row++) begin
      if (count >= 2*row + 2)
        group_m_lane_mask[group][row] = 2'b11;
      else if (count == 2*row + 1)
        group_m_lane_mask[group][row] = 2'b01;
      else
        group_m_lane_mask[group][row] = 2'b00;
    end
  endtask

  task automatic clear_scoreboard();
    for (int bank = 0; bank < 8; bank++) begin
      for (int row = 0; row < 4; row++) begin
        for (int col = 0; col < 16; col++) begin
          expected_lo[bank][row][col] = 0;
          expected_hi[bank][row][col] = 0;
          expected_mask[bank][row][col] = '0;
          expected_valid[bank][row][col] = 1'b0;
          result_seen[bank][row][col] = 1'b0;
        end
      end
    end
  endtask

  task automatic source_idle();
    @(negedge clk);
    for (int group = 0; group < 2; group++) begin
      group_issue_valid[group] = 1'b0;
      group_tile_clear[group] = 1'b0;
      group_reduce_last[group] = 1'b0;
    end
  endtask

  task automatic run_tile(
      input bit split_mode,
      input int depth,
      input int group0_m_count,
      input int group1_m_count,
      input bit stall_upper,
      input logic [7:0] active_bank_mask);
    int source_group;
    begin
      clear_scoreboard();
      mode_split_n64 = split_mode;
      bank_enable = active_bank_mask;
      set_m_count(0, group0_m_count);
      set_m_count(1, group1_m_count);
      group_tile_tag[0] = group_tile_tag[0] + 16'd1;
      group_tile_tag[1] = group_tile_tag[1] + 16'd3;

      @(negedge clk);
      group_tile_clear[0] = 1'b1;
      group_tile_clear[1] = split_mode;
      group_issue_valid[0] = 1'b0;
      group_issue_valid[1] = 1'b0;
      group_reduce_last[0] = 1'b0;
      group_reduce_last[1] = 1'b0;

      @(negedge clk);
      group_tile_clear[0] = 1'b0;
      group_tile_clear[1] = 1'b0;

      for (int k = 0; k < depth; k++) begin
        for (int group = 0; group < 2; group++) begin
          for (int row = 0; row < 4; row++) begin
            group_act_lo[group][row] = random_int8();
            group_act_hi[group][row] = random_int8();
          end
        end
        for (int bank = 0; bank < 8; bank++)
          for (int col = 0; col < 16; col++)
            bank_weight[bank][col] = random_int8();

        group_issue_valid[0] = 1'b1;
        group_issue_valid[1] = split_mode;
        group_reduce_last[0] = k == depth-1;
        group_reduce_last[1] = split_mode && k == depth-1;

        for (int bank = 0; bank < 8; bank++) begin
          source_group = split_mode && bank >= 4 ? 1 : 0;
          for (int row = 0; row < 4; row++) begin
            if (active_bank_mask[bank] &&
                group_m_lane_mask[source_group][row] != 2'b00) begin
              for (int col = 0; col < 16; col++) begin
                expected_lo[bank][row][col] +=
                    $signed(group_act_lo[source_group][row]) *
                    $signed(bank_weight[bank][col]);
                expected_hi[bank][row][col] +=
                    $signed(group_act_hi[source_group][row]) *
                    $signed(bank_weight[bank][col]);
                expected_mask[bank][row][col] =
                    group_m_lane_mask[source_group][row];
                if (k == depth-1)
                  expected_valid[bank][row][col] = 1'b1;
              end
            end
          end
        end
        @(negedge clk);
      end

      group_issue_valid[0] = 1'b0;
      group_issue_valid[1] = 1'b0;
      group_reduce_last[0] = 1'b0;
      group_reduce_last[1] = 1'b0;

      if (stall_upper) begin
        for (int bank = 4; bank < 8; bank++)
          for (int row = 0; row < 4; row++)
            for (int col = 0; col < 16; col++)
              result_ready[bank][row][col] = 1'b0;
        repeat (32) @(negedge clk);
        for (int bank = 4; bank < 8; bank++)
          for (int row = 0; row < 4; row++)
            for (int col = 0; col < 16; col++)
              result_ready[bank][row][col] = 1'b1;
      end

      for (int timeout = 0; timeout < 400; timeout++) begin
        bit pending;
        pending = 1'b0;
        for (int bank = 0; bank < 8; bank++)
          for (int row = 0; row < 4; row++)
            for (int col = 0; col < 16; col++)
              if (expected_valid[bank][row][col] &&
                  !result_seen[bank][row][col])
                pending = 1'b1;
        if (!pending)
          return;
        @(negedge clk);
      end
      $fatal(1, "dynamic SA result drain timeout split=%0d depth=%0d",
             split_mode, depth);
    end
  endtask

  always @(posedge clk) begin
    if (!rst) begin
      for (int bank = 0; bank < 8; bank++) begin
        for (int row = 0; row < 4; row++) begin
          for (int col = 0; col < 16; col++) begin
            if (result_valid[bank][row][col] &&
                result_ready[bank][row][col]) begin
              if (!expected_valid[bank][row][col] ||
                  result_seen[bank][row][col])
                $fatal(1, "unexpected dynamic result bank=%0d row=%0d col=%0d",
                       bank, row, col);
              if ($signed(result_lo[bank][row][col]) !=
                      expected_lo[bank][row][col] ||
                  $signed(result_hi[bank][row][col]) !=
                      expected_hi[bank][row][col] ||
                  result_lane_mask[bank][row][col] !==
                      expected_mask[bank][row][col])
                $fatal(1,
                       "dynamic result mismatch bank=%0d row=%0d col=%0d got=(%0d,%0d,%b) expected=(%0d,%0d,%b)",
                       bank, row, col,
                       $signed(result_lo[bank][row][col]),
                       $signed(result_hi[bank][row][col]),
                       result_lane_mask[bank][row][col],
                       expected_lo[bank][row][col],
                       expected_hi[bank][row][col],
                       expected_mask[bank][row][col]);
              if (bank_result_tag[bank] !==
                  group_tile_tag[bank_source_group[bank]])
                $fatal(1, "dynamic result tag mismatch bank=%0d", bank);
              result_seen[bank][row][col] = 1'b1;
              checked_results = checked_results + 1;
            end
          end
        end
      end
    end
  end

  initial begin
    int seed;
    int plusarg_status;
    int seed_sink;

    seed = 32'h4d38_8032;
    plusarg_status = $value$plusargs("SEED=%d", seed);
    seed_sink = $urandom(seed);

    rst = 1'b1;
    mode_split_n64 = 1'b0;
    bank_enable = 8'hff;
    checked_results = 0;
    for (int group = 0; group < 2; group++) begin
      group_ce[group] = 1'b1;
      group_issue_valid[group] = 1'b0;
      group_tile_clear[group] = 1'b0;
      group_reduce_last[group] = 1'b0;
      group_tile_tag[group] = group;
      for (int row = 0; row < 4; row++) begin
        group_act_lo[group][row] = '0;
        group_act_hi[group][row] = '0;
        group_m_lane_mask[group][row] = 2'b11;
      end
    end
    for (int bank = 0; bank < 8; bank++) begin
      for (int col = 0; col < 16; col++) begin
        bank_weight[bank][col] = '0;
        for (int row = 0; row < 4; row++)
          result_ready[bank][row][col] = 1'b1;
      end
    end
    clear_scoreboard();

    repeat (8) @(negedge clk);
    rst = 1'b0;

    // Wide mode: all eight banks share source zero and cover N128.
    run_tile(1'b0, 17, 8, 0, 1'b0, 8'hff);
    repeat (8) @(negedge clk);

    // Split mode: the two N64 clusters use independent M tails and tags.
    run_tile(1'b1, 23, 7, 5, 1'b1, 8'hff);
    repeat (8) @(negedge clk);

    // A single enabled N16 bank models one-port bandwidth-matched FC mode.
    run_tile(1'b0, 31, 2, 0, 1'b0, 8'h04);
    repeat (8) @(negedge clk);

    // Repeated mode changes at quiescent tile boundaries exercise local bank
    // routing without changing the physical array.
    for (int tile = 0; tile < 12; tile++) begin
      bit split;
      split = tile[0];
      run_tile(split, $urandom_range(1, 48),
               $urandom_range(1, 8),
               split ? $urandom_range(1, 8) : 0,
               1'b0, 8'hff);
      repeat (4) @(negedge clk);
    end

    $display("ALEXNET_SA_M8N128_DYNAMIC_TEST_PASSED results=%0d seed=%0d",
             checked_results, seed);
    $finish;
  end

endmodule
