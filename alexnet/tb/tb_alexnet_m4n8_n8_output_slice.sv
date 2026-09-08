`timescale 1ns/1ps

module tb_alexnet_m4n8_n8_output_slice;

  localparam int SLICE_INDEX = 2;
  localparam int FIFO_DEPTH = 64;
  localparam int MAX_EXPECTED = 2048;

  import "DPI-C" function int alexnet_golden_requantize(
      input int accumulator, input int bias, input int multiplier,
      input byte right_shift, input byte relu, output byte result);

  logic clk = 1'b0;
  logic rst;
  logic cfg_valid;
  logic cfg_ready;
  logic [1:0] cfg_destination;
  logic [15:0] cfg_n64_tile_base;
  logic [7:0] cfg_lane_mask;
  logic signed [31:0] cfg_bias [0:7];
  logic signed [17:0] cfg_multiplier [0:7];
  logic [5:0] cfg_right_shift [0:7];
  logic [7:0] cfg_relu;
  logic tile_valid;
  logic tile_ready;
  logic [2:0] tile_m_count;
  logic [7:0] tile_n_lane_mask;
  logic [15:0] tile_tag;
  logic hold_valid [0:1][0:7];
  logic hold_ready [0:1][0:7];
  logic signed [31:0] hold_lo [0:1][0:7];
  logic signed [31:0] hold_hi [0:1][0:7];
  logic [1:0] hold_m_lane_mask [0:1][0:7];
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
  logic slice_idle;
  logic tile_scan_done;
  logic [$clog2(FIFO_DEPTH+1)-1:0] queued_count;

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
  int completed_scans;
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

  alexnet_m4n8_n8_output_slice #(
      .SLICE_INDEX(SLICE_INDEX),
      .FIFO_DEPTH(FIFO_DEPTH)
  ) dut (.*);

  always #2.5 clk = ~clk;

  function automatic int biased_value(
      input int tag_value, input int m_value, input int lane);
    int selector;
    int mixed;
    begin
      selector = (tag_value + m_value + lane) % 12;
      case (selector)
        0: biased_value = -67108864;
        1: biased_value =  67108863;
        2: biased_value = -1;
        3: biased_value = 0;
        4: biased_value = 1;
        5: biased_value = 16383;
        6: biased_value = -16384;
        default: begin
          mixed = (tag_value * 7919 + m_value * 997 + lane * 101) & 21'h1fffff;
          biased_value = mixed - 1048576;
        end
      endcase
    end
  endfunction

  always_ff @(posedge clk) begin
    if (rst) begin
      for (int row = 0; row < 2; row++)
        for (int lane = 0; lane < 8; lane++)
          hold_valid[row][lane] <= 1'b0;
    end else begin
      for (int row = 0; row < 2; row++)
        for (int lane = 0; lane < 8; lane++)
          if (hold_valid[row][lane] && hold_ready[row][lane])
            hold_valid[row][lane] <= 1'b0;
    end
  end

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
      completed_scans = 0;
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
      if (cfg_valid && tile_ready)
        $fatal(1, "integrated slice accepted a tile during reconfiguration");
      if (cfg_valid && cfg_ready)
        configuration_count = configuration_count + 1;
      if (tile_valid && tile_ready)
        submitted_tiles = submitted_tiles + 1;
      if (tile_scan_done)
        completed_scans = completed_scans + 1;
      if (queued_count > max_queued)
        max_queued = queued_count;

      if (stalled_q) begin
        if (!egress_valid || egress_values !== stalled_values_q ||
            egress_lane_mask !== stalled_mask_q ||
            egress_destination !== stalled_destination_q ||
            egress_slice !== stalled_slice_q || egress_m !== stalled_m_q ||
            egress_n_base !== stalled_n_base_q ||
            egress_tile_tag !== stalled_tag_q)
          $fatal(1, "integrated output packet changed while stalled");
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
          $fatal(1, "integrated slice produced an unexpected packet");
        if (egress_values !== expected_values[expected_read] ||
            egress_lane_mask !== expected_mask[expected_read] ||
            egress_destination !== expected_destination[expected_read] ||
            egress_slice !== expected_slice[expected_read] ||
            egress_m !== expected_m[expected_read] ||
            egress_n_base !== expected_n_base[expected_read] ||
            egress_tile_tag !== expected_tag[expected_read])
          $fatal(1,
                 "integrated packet mismatch index=%0d values=%016x/%016x mask=%02x/%02x dest=%0d/%0d slice=%0d/%0d m=%0d/%0d n=%0d/%0d tag=%0d/%0d",
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

  task automatic configure_slice(input int phase);
    logic accepted;
    begin
      case (phase)
        0: begin
          cfg_destination = 1;
          cfg_n64_tile_base = 128;
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
            cfg_bias[lane] = (lane - 4) * 12345;
            cfg_multiplier[lane] = 65540 + lane * 9000;
            cfg_right_shift[lane] = 23 + lane;
            cfg_relu[lane] = (lane % 3) == 0;
          end
          1: begin
            cfg_bias[lane] = (3 - lane) * 27183;
            cfg_multiplier[lane] = 131067 - lane * 7001;
            cfg_right_shift[lane] = 32 - lane;
            cfg_relu[lane] = (lane % 2) == 0;
          end
          default: begin
            cfg_bias[lane] = (lane - 2) * 8191;
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

  task automatic enqueue_expected_tile(
      input int m_count, input int tag_value);
    longint unsigned packed_values;
    byte golden_result;
    int accumulator;
    int status;
    begin
      for (int m = 0; m < m_count; m++) begin
        if (expected_write >= MAX_EXPECTED)
          $fatal(1, "integrated scoreboard overflow");
        packed_values = '0;
        for (int lane = 0; lane < 8; lane++) begin
          if (cfg_lane_mask[lane]) begin
            accumulator = biased_value(tag_value, m, lane) -
                          $signed(cfg_bias[lane]);
            status = alexnet_golden_requantize(
                accumulator, cfg_bias[lane], cfg_multiplier[lane],
                cfg_right_shift[lane], cfg_relu[lane], golden_result);
            if (status != 0)
              $fatal(1, "C++ integrated requant failed lane=%0d status=%0d",
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
    end
  endtask

  task automatic run_tile(
      input int m_count, input int tag_value, input bit stagger_holdings);
    logic [1:0] row_mask [0:1];
    logic accepted;
    begin
      while (!tile_ready)
        @(negedge clk);

      row_mask[0] = (m_count == 1) ? 2'b01 : 2'b11;
      if (m_count <= 2)
        row_mask[1] = 2'b00;
      else
        row_mask[1] = (m_count == 3) ? 2'b01 : 2'b11;

      for (int row = 0; row < 2; row++) begin
        for (int lane = 0; lane < 8; lane++) begin
          hold_valid[row][lane] = 1'b0;
          hold_m_lane_mask[row][lane] = row_mask[row];
          hold_lo[row][lane] = biased_value(tag_value, 2*row, lane) -
                               $signed(cfg_bias[lane]);
          hold_hi[row][lane] = biased_value(tag_value, 2*row+1, lane) -
                               $signed(cfg_bias[lane]);
        end
      end

      enqueue_expected_tile(m_count, tag_value);
      tile_m_count = m_count;
      tile_n_lane_mask = cfg_lane_mask;
      tile_tag = tag_value;
      tile_valid = 1'b1;
      accepted = 1'b0;
      while (!accepted) begin
        @(posedge clk);
        accepted = tile_ready;
      end
      @(negedge clk);
      tile_valid = 1'b0;

      for (int row = 0; row < 2; row++) begin
        if (row_mask[row] != 0) begin
          for (int lane = 0; lane < 8; lane++) begin
            hold_valid[row][lane] = 1'b1;
            if (stagger_holdings)
              @(negedge clk);
          end
        end
      end

      while (!tile_scan_done)
        @(negedge clk);
      @(negedge clk);

      for (int row = 0; row < 2; row++)
        for (int lane = 0; lane < 8; lane++)
          if (hold_valid[row][lane])
            $fatal(1, "integrated scanner failed to release holding [%0d][%0d]",
                   row, lane);
    end
  endtask

  initial begin
    int seed;
    int seed_sink;
    int timeout;

    rst = 1'b1;
    cfg_valid = 1'b0;
    cfg_destination = '0;
    cfg_n64_tile_base = '0;
    cfg_lane_mask = 8'hff;
    cfg_relu = '0;
    tile_valid = 1'b0;
    tile_m_count = 1;
    tile_n_lane_mask = 8'hff;
    tile_tag = '0;
    egress_ready = 1'b0;
    force_ready = 1'b0;
    blocked_output_cycles = 0;
    seed = 32'h6f75_7453;
    seed_sink = $urandom(seed);

    for (int lane = 0; lane < 8; lane++) begin
      cfg_bias[lane] = '0;
      cfg_multiplier[lane] = 18'sd65540;
      cfg_right_shift[lane] = 6'd23;
      for (int row = 0; row < 2; row++) begin
        hold_valid[row][lane] = 1'b0;
        hold_lo[row][lane] = '0;
        hold_hi[row][lane] = '0;
        hold_m_lane_mask[row][lane] = '0;
      end
    end

    repeat (5) @(negedge clk);
    rst = 1'b0;
    @(negedge clk);

    if (configured || tile_ready)
      $fatal(1, "unconfigured integrated slice accepted a tile");

    configure_slice(0);
    blocked_output_cycles = 350;
    for (int tile = 0; tile < 24; tile++)
      run_tile(4, 16'h0100 + tile, tile == 0);
    for (int tile = 24; tile < 44; tile++)
      run_tile((tile % 4) + 1, 16'h0100 + tile, (tile % 9) == 0);

    // Request a new descriptor while old packets remain buffered. New tile
    // admission stops until scanner, requant pipeline, and FIFO all drain.
    configure_slice(1);
    blocked_output_cycles = 100;
    for (int tile = 0; tile < 30; tile++)
      run_tile((tile % 4) + 1, 16'h2000 + tile, (tile % 11) == 0);

    configure_slice(2);
    for (int tile = 0; tile < 12; tile++)
      run_tile((tile % 4) + 1, 16'h3000 + tile, 1'b0);

    force_ready = 1'b1;
    timeout = 0;
    while ((!slice_idle || expected_read != expected_write) && timeout < 4000) begin
      @(negedge clk);
      timeout = timeout + 1;
    end
    if (timeout == 4000)
      $fatal(1, "integrated slice drain timeout");
    if (configuration_count != 3 || submitted_tiles != 86 ||
        completed_scans != submitted_tiles || max_queued != FIFO_DEPTH ||
        expected_read != expected_write)
      $fatal(1,
             "integrated final counts cfg=%0d tiles=%0d scans=%0d packets=%0d/%0d maxq=%0d",
             configuration_count, submitted_tiles, completed_scans,
             expected_read, expected_write, max_queued);

    for (int row = 0; row < 2; row++)
      for (int lane = 0; lane < 8; lane++)
        if (hold_valid[row][lane])
          $fatal(1, "holding remained valid after final drain");

    $display("ALEXNET_M4N8_N8_OUTPUT_SLICE_TEST_PASSED tiles=%0d packets=%0d configs=%0d maxq=%0d seed=%0d",
             submitted_tiles, expected_read, configuration_count, max_queued,
             seed);
    $finish;
  end

endmodule
