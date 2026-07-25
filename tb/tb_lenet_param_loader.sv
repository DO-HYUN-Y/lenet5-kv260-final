`timescale 1ns/1ps

module tb_lenet_param_loader;
  localparam int ACC_W = 32;
  localparam int SCALE_W = 18;
  localparam int NG = 4;
  localparam int NC = 8;
  localparam int OUT_CH_W = 8;
  localparam int TOTAL_PARAMS = 236;
  localparam int PARAM_ADDR_W = $clog2(TOTAL_PARAMS);
  localparam int LANE_COUNT = 2 * NG * NC;
  localparam int LANE_ID_W = $clog2(LANE_COUNT);

  logic clk;
  logic rst_n;
  logic host_wr_en;
  logic [PARAM_ADDR_W-1:0] host_wr_addr;
  logic signed [ACC_W-1:0] host_wr_bias;
  logic signed [SCALE_W-1:0] host_wr_scale;
  logic host_ready;
  logic load_start;
  logic cfg_fc_mode;
  logic [PARAM_ADDR_W-1:0] cfg_param_base;
  logic [OUT_CH_W-1:0] cfg_out_ch_base;
  logic [OUT_CH_W-1:0] cfg_out_channels;
  logic [OUT_CH_W-1:0] cfg_pass_channels;
  logic param_wr_en;
  logic [LANE_ID_W-1:0] param_wr_lane;
  logic signed [ACC_W-1:0] param_wr_bias;
  logic signed [SCALE_W-1:0] param_wr_scale;
  logic busy;
  logic done;

  int observed;
  int case_index;

  lenet_param_loader dut (.*);

  always #5 clk = ~clk;

  function automatic int expected_logical_addr(input int lane);
    int physical_column;
    int logical_offset;
    begin
      physical_column = (lane % (2 * NC)) / 2;
      if (cfg_fc_mode)
        logical_offset = cfg_out_ch_base + lane;
      else
        logical_offset = cfg_out_ch_base + physical_column;
      if (cfg_fc_mode) begin
        if (logical_offset >= cfg_out_channels)
          expected_logical_addr = -1;
        else
          expected_logical_addr = cfg_param_base + logical_offset;
      end else begin
        if ((physical_column >= cfg_pass_channels) ||
            (logical_offset >= cfg_out_channels))
          expected_logical_addr = -1;
        else
          expected_logical_addr = cfg_param_base + logical_offset;
      end
    end
  endfunction

  always @(posedge clk) begin
    if (rst_n && param_wr_en) begin
      int exp_addr;
      exp_addr = expected_logical_addr(param_wr_lane);
      if (param_wr_lane != observed)
        $fatal(1, "PARAM lane order case=%0d got=%0d exp=%0d",
               case_index, param_wr_lane, observed);
      if (exp_addr < 0) begin
        if ((param_wr_bias !== 0) || (param_wr_scale !== 0))
          $fatal(1, "PARAM inactive lane=%0d bias=%0d scale=%0d",
                 param_wr_lane, param_wr_bias, param_wr_scale);
      end else begin
        if (param_wr_bias !== (32'sd100000 + exp_addr))
          $fatal(1, "PARAM bias lane=%0d got=%0d exp_addr=%0d",
                 param_wr_lane, param_wr_bias, exp_addr);
        if (param_wr_scale !== (18'sd2000 + exp_addr))
          $fatal(1, "PARAM scale lane=%0d got=%0d exp_addr=%0d",
                 param_wr_lane, param_wr_scale, exp_addr);
      end
      observed++;
    end
  end

  task automatic run_case(
      input bit fc_mode,
      input int param_base,
      input int ch_base,
      input int channels,
      input int pass_channels
  );
    int guard;
    begin
      @(negedge clk);
      cfg_fc_mode = fc_mode;
      cfg_param_base = PARAM_ADDR_W'(param_base);
      cfg_out_ch_base = OUT_CH_W'(ch_base);
      cfg_out_channels = OUT_CH_W'(channels);
      cfg_pass_channels = OUT_CH_W'(pass_channels);
      observed = 0;
      load_start = 1'b1;
      @(negedge clk);
      load_start = 1'b0;

      guard = 0;
      while (!done && guard < 100) begin
        @(negedge clk);
        guard++;
      end
      if (!done)
        $fatal(1, "PARAM timeout case=%0d observed=%0d",
               case_index, observed);
      if (observed != LANE_COUNT)
        $fatal(1, "PARAM count case=%0d got=%0d exp=%0d",
               case_index, observed, LANE_COUNT);
      case_index++;
      @(negedge clk);
    end
  endtask

  initial begin
    clk = 1'b0;
    rst_n = 1'b0;
    host_wr_en = 1'b0;
    host_wr_addr = '0;
    host_wr_bias = '0;
    host_wr_scale = '0;
    load_start = 1'b0;
    cfg_fc_mode = 1'b0;
    cfg_param_base = '0;
    cfg_out_ch_base = '0;
    cfg_out_channels = '0;
    cfg_pass_channels = '0;
    observed = 0;
    case_index = 0;

    repeat (4) @(negedge clk);
    rst_n = 1'b1;

    for (int addr = 0; addr < TOTAL_PARAMS; addr++) begin
      @(negedge clk);
      host_wr_en = 1'b1;
      host_wr_addr = PARAM_ADDR_W'(addr);
      host_wr_bias = 32'sd100000 + addr;
      host_wr_scale = 18'sd2000 + addr;
    end
    @(negedge clk);
    host_wr_en = 1'b0;

    run_case(1'b0, 0, 0, 6, 6);
    run_case(1'b0, 6, 8, 16, 8);
    run_case(1'b1, 22, 64, 120, 56);
    run_case(1'b1, 226, 0, 10, 10);

    $display("LENET_PARAM_LOADER TEST PASSED cases=%0d", case_index);
    $finish;
  end

endmodule
