`timescale 1ns/1ps

module tb_alexnet_m4n8_base_datapath;

  localparam int SLICE_INDEX = 1;
  localparam int FIFO_DEPTH = 64;
  localparam int MAX_K = 64;
  localparam int MAX_EXPECTED = 2048;

  import "DPI-C" function int alexnet_golden_packed_products(
      input byte act_lo, input byte act_hi, input byte weight,
      output int product_lo, output int product_hi);
  import "DPI-C" function int alexnet_golden_requantize(
      input int accumulator, input int bias, input int multiplier,
      input byte right_shift, input byte relu, output byte result);

  logic clk = 1'b0;
  logic rst;
  logic ce;
  logic cfg_valid;
  logic cfg_ready;
  logic [1:0] cfg_destination;
  logic [15:0] cfg_n64_tile_base;
  logic [7:0] cfg_lane_mask;
  logic signed [31:0] cfg_bias [0:7];
  logic signed [17:0] cfg_multiplier [0:7];
  logic [5:0] cfg_right_shift [0:7];
  logic [7:0] cfg_relu;
  logic tile_start_valid;
  logic tile_start_ready;
  logic [2:0] tile_m_count;
  logic [7:0] tile_n_lane_mask;
  logic [15:0] tile_tag;
  logic issue_valid;
  logic issue_ready;
  logic issue_last;
  logic signed [7:0] issue_act_lo [0:1];
  logic signed [7:0] issue_act_hi [0:1];
  logic signed [7:0] issue_weight [0:7];
  logic egress_valid;
  logic egress_ready;
  logic [63:0] egress_values;
  logic [7:0] egress_lane_mask;
  logic [1:0] egress_destination;
  logic [2:0] egress_slice;
  logic [4:0] egress_m;
  logic [15:0] egress_n_base;
  logic [15:0] egress_tile_tag;
  logic configured;
  logic compute_busy;
  logic tile_done;
  logic datapath_idle;
  logic [$clog2(FIFO_DEPTH+1)-1:0] queued_count;

  logic signed [7:0] tile_act_lo [0:MAX_K-1][0:1];
  logic signed [7:0] tile_act_hi [0:MAX_K-1][0:1];
  logic signed [7:0] tile_weight [0:MAX_K-1][0:7];
  longint signed tile_accumulator [0:3][0:7];

  logic [63:0] expected_values [0:MAX_EXPECTED-1];
  logic [7:0] expected_mask [0:MAX_EXPECTED-1];
  logic [1:0] expected_destination [0:MAX_EXPECTED-1];
  logic [2:0] expected_slice [0:MAX_EXPECTED-1];
  logic [4:0] expected_m [0:MAX_EXPECTED-1];
  logic [15:0] expected_n_base [0:MAX_EXPECTED-1];
  logic [15:0] expected_tag [0:MAX_EXPECTED-1];
  int expected_write;
  int expected_read;
  int configuration_count;
  int submitted_tiles;
  int completed_tiles;
  int accepted_k_tokens;
  int expected_k_tokens;
  int max_queued;
  int blocked_output_cycles;
  logic force_ready;

  logic stalled_q;
  logic [63:0] stalled_values_q;
  logic [7:0] stalled_mask_q;
  logic [1:0] stalled_destination_q;
  logic [2:0] stalled_slice_q;
  logic [4:0] stalled_m_q;
  logic [15:0] stalled_n_base_q;
  logic [15:0] stalled_tag_q;

  alexnet_m4n8_base_datapath #(
      .SLICE_INDEX(SLICE_INDEX),
      .FIFO_DEPTH(FIFO_DEPTH)
  ) dut (.*);

  always #2.5 clk = ~clk;

  function automatic logic signed [7:0] random_i8(input bit full_range);
    if (full_range)
      random_i8 = $urandom_range(0, 255) - 128;
    else
      random_i8 = $urandom_range(0, 31) - 16;
  endfunction

  always @(negedge clk) begin
    if (rst)
      egress_ready <= 1'b0;
    else if (force_ready)
      egress_ready <= 1'b1;
    else if (blocked_output_cycles > 0) begin
      egress_ready <= 1'b0;
      blocked_output_cycles = blocked_output_cycles - 1;
    end else
      egress_ready <= ($urandom_range(0, 3) != 0);
  end

  always @(posedge clk) begin : scoreboard
    if (rst) begin
      expected_write = 0;
      expected_read = 0;
      configuration_count = 0;
      submitted_tiles = 0;
      completed_tiles = 0;
      accepted_k_tokens = 0;
      expected_k_tokens = 0;
      max_queued = 0;
      stalled_q <= 1'b0;
      stalled_values_q <= '0;
      stalled_mask_q <= '0;
      stalled_destination_q <= '0;
      stalled_slice_q <= '0;
      stalled_m_q <= '0;
      stalled_n_base_q <= '0;
      stalled_tag_q <= '0;
    end else begin
      if (cfg_valid && tile_start_ready)
        $fatal(1, "base datapath accepted a tile during reconfiguration");
      if (cfg_valid && cfg_ready)
        configuration_count = configuration_count + 1;
      if (tile_start_valid && tile_start_ready)
        submitted_tiles = submitted_tiles + 1;
      if (issue_valid && issue_ready)
        accepted_k_tokens = accepted_k_tokens + 1;
      if (tile_done)
        completed_tiles = completed_tiles + 1;
      if (queued_count > max_queued)
        max_queued = queued_count;

      if (stalled_q) begin
        if (!egress_valid || egress_values !== stalled_values_q ||
            egress_lane_mask !== stalled_mask_q ||
            egress_destination !== stalled_destination_q ||
            egress_slice !== stalled_slice_q || egress_m !== stalled_m_q ||
            egress_n_base !== stalled_n_base_q ||
            egress_tile_tag !== stalled_tag_q)
          $fatal(1, "base datapath output changed while stalled");
      end

      stalled_q <= egress_valid && !egress_ready;
      if (egress_valid && !egress_ready) begin
        stalled_values_q <= egress_values;
        stalled_mask_q <= egress_lane_mask;
        stalled_destination_q <= egress_destination;
        stalled_slice_q <= egress_slice;
        stalled_m_q <= egress_m;
        stalled_n_base_q <= egress_n_base;
        stalled_tag_q <= egress_tile_tag;
      end

      if (egress_valid && egress_ready) begin
        if (expected_read >= expected_write)
          $fatal(1, "base datapath produced an unexpected packet");
        if (egress_values !== expected_values[expected_read] ||
            egress_lane_mask !== expected_mask[expected_read] ||
            egress_destination !== expected_destination[expected_read] ||
            egress_slice !== expected_slice[expected_read] ||
            egress_m !== expected_m[expected_read] ||
            egress_n_base !== expected_n_base[expected_read] ||
            egress_tile_tag !== expected_tag[expected_read])
          $fatal(1,
                 "base packet mismatch index=%0d values=%016x/%016x mask=%02x/%02x dest=%0d/%0d slice=%0d/%0d m=%0d/%0d n=%0d/%0d tag=%0d/%0d",
                 expected_read, egress_values, expected_values[expected_read],
                 egress_lane_mask, expected_mask[expected_read],
                 egress_destination, expected_destination[expected_read],
                 egress_slice, expected_slice[expected_read], egress_m,
                 expected_m[expected_read], egress_n_base,
                 expected_n_base[expected_read], egress_tile_tag,
                 expected_tag[expected_read]);
        expected_read = expected_read + 1;
      end
    end
  end

  task automatic configure_datapath(input int phase);
    logic accepted;
    begin
      case (phase)
        0: begin
          cfg_destination = 1;
          cfg_n64_tile_base = 64;
          cfg_lane_mask = 8'hff;
        end
        1: begin
          cfg_destination = 2;
          cfg_n64_tile_base = 960;
          cfg_lane_mask = 8'h0f;
        end
        default: begin
          cfg_destination = 0;
          cfg_n64_tile_base = 0;
          cfg_lane_mask = 8'h01;
        end
      endcase

      for (int lane = 0; lane < 8; lane++) begin
        case (phase)
          0: begin
            cfg_bias[lane] = (lane - 4) * 4093;
            cfg_multiplier[lane] = 65540 + lane * 8000;
            cfg_right_shift[lane] = 25 + lane;
            cfg_relu[lane] = (lane % 3) == 0;
          end
          1: begin
            cfg_bias[lane] = (3 - lane) * 8191;
            cfg_multiplier[lane] = 131067 - lane * 7001;
            cfg_right_shift[lane] = 32 - lane;
            cfg_relu[lane] = (lane % 2) == 0;
          end
          default: begin
            cfg_bias[lane] = (lane - 2) * 3079;
            cfg_multiplier[lane] = 70001 + lane * 7333;
            cfg_right_shift[lane] = 24 + lane;
            cfg_relu[lane] = lane >= 4;
          end
        endcase
      end

      cfg_valid = 1'b1;
      accepted = 1'b0;
      while (!accepted) begin
        @(posedge clk);
        accepted = cfg_ready;
      end
      @(negedge clk);
      cfg_valid = 1'b0;
    end
  endtask

  task automatic prepare_tile(
      input int depth, input int m_count, input int tag_value,
      input bit full_range);
    int product_lo;
    int product_hi;
    int status;
    longint unsigned packed_values;
    byte golden_result;
    begin
      for (int m = 0; m < 4; m++)
        for (int lane = 0; lane < 8; lane++)
          tile_accumulator[m][lane] = 0;

      for (int k = 0; k < depth; k++) begin
        for (int row = 0; row < 2; row++) begin
          tile_act_lo[k][row] = random_i8(full_range);
          tile_act_hi[k][row] = random_i8(full_range);
        end
        for (int lane = 0; lane < 8; lane++)
          tile_weight[k][lane] = random_i8(full_range);

        if (tag_value == 16'h0100 && k == 0) begin
          tile_act_lo[k][0] = -128;
          tile_act_hi[k][0] = 127;
          tile_act_lo[k][1] = -127;
          tile_act_hi[k][1] = 126;
          for (int lane = 0; lane < 8; lane++)
            tile_weight[k][lane] = lane[0] ? 127 : -128;
        end

        for (int row = 0; row < 2; row++) begin
          for (int lane = 0; lane < 8; lane++) begin
            status = alexnet_golden_packed_products(
                tile_act_lo[k][row], tile_act_hi[k][row],
                tile_weight[k][lane], product_lo, product_hi);
            if (status != 0)
              $fatal(1, "C++ packed product failed status=%0d", status);
            tile_accumulator[2*row][lane] += product_lo;
            tile_accumulator[2*row+1][lane] += product_hi;
          end
        end
      end

      for (int m = 0; m < m_count; m++) begin
        if (expected_write >= MAX_EXPECTED)
          $fatal(1, "base datapath scoreboard overflow");
        packed_values = '0;
        for (int lane = 0; lane < 8; lane++) begin
          if (cfg_lane_mask[lane]) begin
            if (tile_accumulator[m][lane] + $signed(cfg_bias[lane]) <
                    -67108864 ||
                tile_accumulator[m][lane] + $signed(cfg_bias[lane]) >
                    67108863)
              $fatal(1, "base test vector exceeded signed-27 post-bias bound");
            status = alexnet_golden_requantize(
                tile_accumulator[m][lane], cfg_bias[lane],
                cfg_multiplier[lane], cfg_right_shift[lane],
                cfg_relu[lane], golden_result);
            if (status != 0)
              $fatal(1, "C++ base requant failed lane=%0d status=%0d",
                     lane, status);
            packed_values[lane*8 +: 8] = golden_result;
          end
        end
        expected_values[expected_write] = packed_values;
        expected_mask[expected_write] = cfg_lane_mask;
        expected_destination[expected_write] = cfg_destination;
        expected_slice[expected_write] = SLICE_INDEX;
        expected_m[expected_write] = m;
        expected_n_base[expected_write] =
            cfg_n64_tile_base + SLICE_INDEX * 8;
        expected_tag[expected_write] = tag_value;
        expected_write = expected_write + 1;
      end
      expected_k_tokens = expected_k_tokens + depth;
    end
  endtask

  task automatic run_tile(
      input int depth, input int m_count, input int tag_value,
      input bit bubbles, input bit ce_stalls, input bit full_range);
    logic accepted;
    begin
      prepare_tile(depth, m_count, tag_value, full_range);

      while (!tile_start_ready)
        @(negedge clk);
      tile_m_count = m_count;
      tile_n_lane_mask = cfg_lane_mask;
      tile_tag = tag_value;
      tile_start_valid = 1'b1;
      accepted = 1'b0;
      while (!accepted) begin
        @(posedge clk);
        accepted = tile_start_ready;
      end
      @(negedge clk);
      tile_start_valid = 1'b0;

      for (int k = 0; k < depth; k++) begin
        if (bubbles && ($urandom_range(0, 3) == 0)) begin
          issue_valid = 1'b0;
          repeat ($urandom_range(1, 3))
            @(negedge clk);
        end

        for (int row = 0; row < 2; row++) begin
          issue_act_lo[row] = tile_act_lo[k][row];
          issue_act_hi[row] = tile_act_hi[k][row];
        end
        for (int lane = 0; lane < 8; lane++)
          issue_weight[lane] = tile_weight[k][lane];
        issue_last = (k == depth - 1);
        issue_valid = 1'b1;

        if (ce_stalls && ($urandom_range(0, 7) == 0)) begin
          ce = 1'b0;
          repeat ($urandom_range(1, 4))
            @(negedge clk);
          ce = 1'b1;
        end

        accepted = 1'b0;
        while (!accepted) begin
          @(posedge clk);
          accepted = issue_ready;
        end
        @(negedge clk);
        issue_valid = 1'b0;
      end
      issue_last = 1'b0;

      while (!tile_done)
        @(negedge clk);
      @(negedge clk);
    end
  endtask

  initial begin
    int seed;
    int seed_sink;
    int timeout;

    rst = 1'b1;
    ce = 1'b1;
    cfg_valid = 1'b0;
    cfg_destination = '0;
    cfg_n64_tile_base = '0;
    cfg_lane_mask = 8'hff;
    cfg_relu = '0;
    tile_start_valid = 1'b0;
    tile_m_count = 1;
    tile_n_lane_mask = 8'hff;
    tile_tag = '0;
    issue_valid = 1'b0;
    issue_last = 1'b0;
    egress_ready = 1'b0;
    force_ready = 1'b0;
    blocked_output_cycles = 0;
    seed = 32'h4d34_4244;
    seed_sink = $urandom(seed);

    for (int lane = 0; lane < 8; lane++) begin
      cfg_bias[lane] = '0;
      cfg_multiplier[lane] = 18'sd65540;
      cfg_right_shift[lane] = 6'd23;
      issue_weight[lane] = '0;
    end
    for (int row = 0; row < 2; row++) begin
      issue_act_lo[row] = '0;
      issue_act_hi[row] = '0;
    end

    repeat (5) @(negedge clk);
    rst = 1'b0;
    @(negedge clk);

    if (configured || tile_start_ready || issue_ready)
      $fatal(1, "unconfigured base datapath exposed a ready input");

    configure_datapath(0);
    blocked_output_cycles = 700;
    for (int tile = 0; tile < 20; tile++)
      run_tile(1, 4, 16'h0100 + tile, 1'b0, 1'b0, tile == 0);
    for (int tile = 0; tile < 12; tile++)
      run_tile((tile * 5) % 16 + 1, (tile % 4) + 1,
               16'h0200 + tile, 1'b1, 1'b1, tile == 0);

    configure_datapath(1);
    blocked_output_cycles = 100;
    for (int tile = 0; tile < 24; tile++)
      run_tile((tile * 7) % 32 + 1, (tile % 4) + 1,
               16'h2000 + tile, 1'b1, 1'b1, (tile % 8) == 0);

    configure_datapath(2);
    for (int tile = 0; tile < 12; tile++)
      run_tile((tile * 3) % 16 + 1, (tile % 4) + 1,
               16'h3000 + tile, 1'b1, 1'b1, tile == 0);

    force_ready = 1'b1;
    ce = 1'b1;
    timeout = 0;
    while ((!datapath_idle || expected_read != expected_write) &&
           timeout < 6000) begin
      @(negedge clk);
      timeout = timeout + 1;
    end
    if (timeout == 6000)
      $fatal(1, "base datapath drain timeout");
    if (configuration_count != 3 || submitted_tiles != 68 ||
        completed_tiles != submitted_tiles ||
        accepted_k_tokens != expected_k_tokens ||
        max_queued != FIFO_DEPTH || expected_read != expected_write ||
        expected_read != 200)
      $fatal(1,
             "base final counts cfg=%0d tiles=%0d/%0d k=%0d/%0d packets=%0d/%0d maxq=%0d",
             configuration_count, completed_tiles, submitted_tiles,
             accepted_k_tokens, expected_k_tokens, expected_read,
             expected_write, max_queued);

    $display("ALEXNET_M4N8_BASE_DATAPATH_TEST_PASSED tiles=%0d k_tokens=%0d packets=%0d configs=%0d maxq=%0d seed=%0d",
             completed_tiles, accepted_k_tokens, expected_read,
             configuration_count, max_queued, seed);
    $finish;
  end

endmodule
