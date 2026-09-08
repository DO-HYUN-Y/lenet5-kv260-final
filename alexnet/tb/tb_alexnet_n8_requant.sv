`timescale 1ns/1ps

module tb_alexnet_n8_requant;

  import "DPI-C" function int alexnet_golden_requantize(
      input int accumulator, input int bias, input int multiplier,
      input byte right_shift, input byte relu, output byte result);

  localparam int MAX_EXPECTED = 2048;

  logic clk = 1'b0;
  logic rst;
  logic cfg_valid;
  logic cfg_ready;
  logic signed [31:0] cfg_bias [0:7];
  logic signed [17:0] cfg_multiplier [0:7];
  logic [5:0] cfg_right_shift [0:7];
  logic [7:0] cfg_relu;
  logic ingress_valid;
  logic ingress_ready;
  logic signed [31:0] ingress_accumulator [0:7];
  logic [7:0] ingress_lane_mask;
  logic [4:0] ingress_m;
  logic [15:0] ingress_tile_tag;
  logic egress_valid;
  logic egress_ready;
  logic [63:0] egress_values;
  logic [7:0] egress_lane_mask;
  logic [4:0] egress_m;
  logic [15:0] egress_tile_tag;
  logic idle;

  logic [63:0] expected_values [0:MAX_EXPECTED-1];
  logic [7:0] expected_mask [0:MAX_EXPECTED-1];
  logic [4:0] expected_m [0:MAX_EXPECTED-1];
  logic [15:0] expected_tag [0:MAX_EXPECTED-1];
  int expected_write;
  int expected_read;
  int accepted_inputs;
  int accepted_outputs;
  int configuration_count;

  logic stalled_q;
  logic [63:0] stalled_values_q;
  logic [7:0] stalled_mask_q;
  logic [4:0] stalled_m_q;
  logic [15:0] stalled_tag_q;
  logic force_ready;

  alexnet_n8_requant dut (.*);

  always #2.5 clk = ~clk;

  always @(negedge clk) begin
    if (rst)
      egress_ready <= 1'b0;
    else if (force_ready)
      egress_ready <= 1'b1;
    else
      egress_ready <= ($urandom_range(0, 3) != 0);
  end

  always @(posedge clk) begin : scoreboard
    longint unsigned packed_values;
    byte golden_result;
    int status;

    if (rst) begin
      expected_write = 0;
      expected_read = 0;
      accepted_inputs = 0;
      accepted_outputs = 0;
      configuration_count = 0;
      stalled_q <= 1'b0;
      stalled_values_q <= '0;
      stalled_mask_q <= '0;
      stalled_m_q <= '0;
      stalled_tag_q <= '0;
    end else begin
      if (cfg_ready !== idle)
        $fatal(1, "requant cfg_ready/idle mismatch");

      if (stalled_q) begin
        if (!egress_valid || egress_values !== stalled_values_q ||
            egress_lane_mask !== stalled_mask_q || egress_m !== stalled_m_q ||
            egress_tile_tag !== stalled_tag_q)
          $fatal(1, "requant output changed while stalled");
      end

      stalled_q <= egress_valid && !egress_ready;
      if (egress_valid && !egress_ready) begin
        stalled_values_q <= egress_values;
        stalled_mask_q <= egress_lane_mask;
        stalled_m_q <= egress_m;
        stalled_tag_q <= egress_tile_tag;
      end

      if (cfg_valid && cfg_ready)
        configuration_count = configuration_count + 1;

      if (ingress_valid && ingress_ready) begin
        if (expected_write >= MAX_EXPECTED)
          $fatal(1, "requant scoreboard overflow");
        packed_values = '0;
        for (int lane = 0; lane < 8; lane++) begin
          if (ingress_lane_mask[lane]) begin
            status = alexnet_golden_requantize(
                ingress_accumulator[lane], cfg_bias[lane],
                cfg_multiplier[lane], cfg_right_shift[lane],
                cfg_relu[lane], golden_result);
            if (status != 0)
              $fatal(1, "C++ requant failed lane=%0d status=%0d", lane, status);
            packed_values[lane*8 +: 8] = golden_result;
          end
        end
        expected_values[expected_write] = packed_values;
        expected_mask[expected_write] = ingress_lane_mask;
        expected_m[expected_write] = ingress_m;
        expected_tag[expected_write] = ingress_tile_tag;
        expected_write = expected_write + 1;
        accepted_inputs = accepted_inputs + 1;
      end

      if (egress_valid && egress_ready) begin
        if (expected_read >= expected_write)
          $fatal(1, "requant produced an unexpected output");
        if (egress_values !== expected_values[expected_read] ||
            egress_lane_mask !== expected_mask[expected_read] ||
            egress_m !== expected_m[expected_read] ||
            egress_tile_tag !== expected_tag[expected_read])
          $fatal(1,
                 "requant mismatch index=%0d values=%016x/%016x mask=%02x/%02x m=%0d/%0d tag=%0d/%0d",
                 expected_read, egress_values, expected_values[expected_read],
                 egress_lane_mask, expected_mask[expected_read], egress_m,
                 expected_m[expected_read], egress_tile_tag,
                 expected_tag[expected_read]);
        expected_read = expected_read + 1;
        accepted_outputs = accepted_outputs + 1;
      end
    end
  end

  task automatic configure(input int phase);
    logic accepted;
    begin
      for (int lane = 0; lane < 8; lane++) begin
        if (phase == 0) begin
          cfg_bias[lane] = (lane - 4) * 12345;
          cfg_multiplier[lane] = 65540 + lane * 9000;
          cfg_right_shift[lane] = 23 + lane;
          cfg_relu[lane] = (lane % 3) == 0;
        end else begin
          cfg_bias[lane] = (3 - lane) * 27183;
          cfg_multiplier[lane] = 131067 - lane * 7001;
          cfg_right_shift[lane] = 32 - lane;
          cfg_relu[lane] = (lane % 2) == 0;
        end
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

  function automatic logic [7:0] tail_mask(input int packet_index);
    begin
      case (packet_index % 6)
        0: tail_mask = 8'hff;
        1: tail_mask = 8'h7f;
        2: tail_mask = 8'h1f;
        3: tail_mask = 8'h0f;
        4: tail_mask = 8'h03;
        default: tail_mask = 8'h01;
      endcase
    end
  endfunction

  task automatic send_packet(input int phase, input int packet_index);
    int biased_value;
    logic accepted;
    begin
      ingress_lane_mask = tail_mask(packet_index);
      ingress_m = packet_index & 31;
      ingress_tile_tag = (phase << 12) | (packet_index & 12'hfff);

      for (int lane = 0; lane < 8; lane++) begin
        case ((packet_index + lane) % 10)
          0: biased_value = -67108864;
          1: biased_value =  67108863;
          2: biased_value = -1;
          3: biased_value = 0;
          4: biased_value = 1;
          5: biased_value = 16383;
          6: biased_value = -16384;
          7: biased_value = $urandom_range(0, 2097151) - 1048576;
          8: biased_value = $urandom_range(0, 33554431) - 16777216;
          default:
            biased_value = $urandom_range(0, 134217727) - 67108864;
        endcase
        ingress_accumulator[lane] = biased_value - $signed(cfg_bias[lane]);
      end

      ingress_valid = 1'b1;
      accepted = 1'b0;
      while (!accepted) begin
        @(posedge clk);
        accepted = ingress_ready;
      end
      @(negedge clk);
      ingress_valid = 1'b0;
    end
  endtask

  initial begin
    int seed;
    int seed_sink;
    int timeout;

    rst = 1'b1;
    cfg_valid = 1'b0;
    cfg_relu = '0;
    ingress_valid = 1'b0;
    ingress_lane_mask = 8'hff;
    ingress_m = '0;
    ingress_tile_tag = '0;
    egress_ready = 1'b0;
    force_ready = 1'b0;
    seed = 32'h5a17c0de;
    seed_sink = $urandom(seed);
    for (int lane = 0; lane < 8; lane++) begin
      cfg_bias[lane] = '0;
      cfg_multiplier[lane] = 18'sd65540;
      cfg_right_shift[lane] = 6'd23;
      ingress_accumulator[lane] = '0;
    end

    repeat (5) @(negedge clk);
    rst = 1'b0;
    @(negedge clk);

    if (ingress_ready)
      $fatal(1, "unconfigured requant accepted ingress");

    configure(0);
    for (int packet = 0; packet < 512; packet++)
      send_packet(0, packet);

    // This request is deliberately issued with data still in flight. The RTL
    // must stop new ingress, drain, then atomically install the next N8 set.
    configure(1);
    for (int packet = 0; packet < 257; packet++)
      send_packet(1, packet);

    force_ready = 1'b1;
    timeout = 0;
    while ((!idle || expected_read != expected_write) && timeout < 2000) begin
      @(negedge clk);
      timeout = timeout + 1;
    end
    if (timeout == 2000)
      $fatal(1, "requant drain timeout");
    if (accepted_inputs != 769 || accepted_outputs != 769 ||
        expected_read != expected_write || configuration_count != 2)
      $fatal(1,
             "requant final counts input=%0d output=%0d queued=%0d configs=%0d",
             accepted_inputs, accepted_outputs,
             expected_write - expected_read, configuration_count);

    $display("ALEXNET_N8_REQUANT_TEST_PASSED beats=%0d configs=%0d seed=%0d",
             accepted_outputs, configuration_count, seed);
    $finish;
  end

endmodule
