`timescale 1ns/1ps

module tb_alexnet_m8n8_parallel_requant;

  import "DPI-C" function int alexnet_golden_requantize(
      input int accumulator, input int bias, input int multiplier,
      input byte right_shift, input byte relu, output byte result);

  localparam int M_ROWS = 8;
  localparam int GROUPS = 160;

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
  logic [3:0] ingress_m_count;
  logic signed [31:0] ingress_accumulator [0:M_ROWS-1][0:7];
  logic [7:0] ingress_lane_mask;
  logic [15:0] ingress_tile_tag;
  logic egress_valid;
  logic egress_ready;
  logic [3:0] egress_m_count;
  logic [63:0] egress_values [0:M_ROWS-1];
  logic [7:0] egress_lane_mask [0:M_ROWS-1];
  logic [15:0] egress_tile_tag;
  logic idle;

  logic [63:0] expected_values [0:GROUPS-1][0:M_ROWS-1];
  logic [3:0] expected_m_count [0:GROUPS-1];
  logic [15:0] expected_tag [0:GROUPS-1];
  int accepted_inputs;
  int accepted_outputs;
  logic force_ready;

  alexnet_m8n8_parallel_requant dut (.*);

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
    byte golden_result;
    int status;
    logic [63:0] packed_values;

    if (rst) begin
      accepted_inputs = 0;
      accepted_outputs = 0;
    end else begin
      if (ingress_valid && ingress_ready) begin
        expected_m_count[accepted_inputs] = ingress_m_count;
        expected_tag[accepted_inputs] = ingress_tile_tag;
        for (int m = 0; m < M_ROWS; m++) begin
          packed_values = '0;
          if (m < ingress_m_count) begin
            for (int lane = 0; lane < 8; lane++) begin
              status = alexnet_golden_requantize(
                  ingress_accumulator[m][lane], cfg_bias[lane],
                  cfg_multiplier[lane], cfg_right_shift[lane],
                  cfg_relu[lane], golden_result);
              if (status != 0)
                $fatal(1, "golden requant failed row=%0d lane=%0d", m, lane);
              packed_values[lane*8 +: 8] = golden_result;
            end
          end
          expected_values[accepted_inputs][m] = packed_values;
        end
        accepted_inputs = accepted_inputs + 1;
      end

      if (egress_valid && egress_ready) begin
        if (accepted_outputs >= accepted_inputs ||
            egress_m_count != expected_m_count[accepted_outputs] ||
            egress_tile_tag != expected_tag[accepted_outputs])
          $fatal(1, "parallel requant group metadata mismatch index=%0d",
                 accepted_outputs);
        for (int m = 0; m < M_ROWS; m++) begin
          if (m < egress_m_count) begin
            if (egress_values[m] !== expected_values[accepted_outputs][m] ||
                egress_lane_mask[m] != 8'hff)
              $fatal(1, "parallel requant value mismatch group=%0d row=%0d",
                     accepted_outputs, m);
          end
        end
        accepted_outputs = accepted_outputs + 1;
      end
    end
  end

  task automatic send_group(input int group_index);
    bit accepted;
    begin
      ingress_m_count = (group_index % M_ROWS) + 1;
      ingress_tile_tag = 16'h6000 + group_index;
      for (int m = 0; m < M_ROWS; m++)
        for (int lane = 0; lane < 8; lane++)
          ingress_accumulator[m][lane] =
              group_index * 2000 + m * 127 + lane * 11 - 90000;
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
    int seed_sink;
    int timeout;

    seed_sink = $urandom(32'h6d38_4e51);
    rst = 1'b1;
    cfg_valid = 1'b0;
    cfg_relu = 8'h49;
    ingress_valid = 1'b0;
    ingress_m_count = 1;
    ingress_lane_mask = 8'hff;
    ingress_tile_tag = '0;
    egress_ready = 1'b0;
    force_ready = 1'b0;
    for (int lane = 0; lane < 8; lane++) begin
      cfg_bias[lane] = (lane - 3) * 113;
      cfg_multiplier[lane] = 18'sd65540 + lane * 1200;
      cfg_right_shift[lane] = 6'd23 + (lane % 4);
      for (int m = 0; m < M_ROWS; m++)
        ingress_accumulator[m][lane] = '0;
    end

    repeat (5) @(negedge clk);
    rst = 1'b0;
    @(negedge clk);

    cfg_valid = 1'b1;
    while (!cfg_ready)
      @(negedge clk);
    @(posedge clk);
    @(negedge clk);
    cfg_valid = 1'b0;

    for (int group_index = 0; group_index < GROUPS; group_index++)
      send_group(group_index);

    force_ready = 1'b1;
    timeout = 0;
    while ((!idle || accepted_outputs != GROUPS) && timeout < 3000) begin
      @(negedge clk);
      timeout = timeout + 1;
    end
    if (timeout == 3000 || accepted_inputs != GROUPS ||
        accepted_outputs != GROUPS)
      $fatal(1, "parallel requant drain failed inputs=%0d outputs=%0d",
             accepted_inputs, accepted_outputs);

    $display("ALEXNET_M8N8_PARALLEL_REQUANT_TEST_PASSED groups=%0d dsp=64",
             accepted_outputs);
    $finish;
  end

endmodule
