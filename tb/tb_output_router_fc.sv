`timescale 1ns/1ps

// Directed FC-mode mapping and ready/valid hold test for output_router.
module tb_output_router_fc;
  localparam int ACC_W = 32;
  localparam int NG = 1;
  localparam int NC = 2;
  localparam int OUT_ADDR_W = 16;
  localparam int OUT_CH_W = 8;
  localparam int LAYER_ID_W = 3;
  localparam int BASE_LATENCY = 2;

  logic clk, rst_n, start, advance_in, drain_en;
  logic issue_last;
  logic [1:0] issue_lane_mask [0:NG-1];
  logic [OUT_ADDR_W-1:0] cfg_out_base_addr;
  logic [OUT_CH_W-1:0] cfg_out_ch_base, cfg_out_channels;
  logic cfg_fc_mode;
  logic [LAYER_ID_W-1:0] cfg_layer_id;
  logic signed [ACC_W-1:0] acc_lo_in [0:NG-1][0:NC-1];
  logic signed [ACC_W-1:0] acc_hi_in [0:NG-1][0:NC-1];
  logic [1:0] acc_valid_in [0:NG-1][0:NC-1];
  logic ingress_ready, idle;
  logic result_valid [0:NG-1];
  logic result_ready [0:NG-1];
  logic signed [ACC_W-1:0] result_acc_lo [0:NG-1];
  logic signed [ACC_W-1:0] result_acc_hi [0:NG-1];
  logic [1:0] result_lane_mask [0:NG-1];
  logic [OUT_ADDR_W-1:0] result_addr_lo [0:NG-1];
  logic [OUT_ADDR_W-1:0] result_addr_hi [0:NG-1];
  logic [OUT_CH_W-1:0] result_channel_lo [0:NG-1];
  logic [OUT_CH_W-1:0] result_channel_hi [0:NG-1];
  logic result_fc_mode [0:NG-1];
  logic [LAYER_ID_W-1:0] result_layer_id [0:NG-1];

  output_router #(
    .ACC_W(ACC_W), .NG(NG), .NC(NC), .OUT_W(1), .OUT_H(1),
    .OUT_ADDR_W(OUT_ADDR_W), .OUT_CH_W(OUT_CH_W),
    .LAYER_ID_W(LAYER_ID_W), .BASE_LATENCY(BASE_LATENCY),
    .QUEUE_DEPTH(2)
  ) dut (.*);

  always #5 clk = ~clk;

  int packet_count;
  int lane_count;
  logic signed [ACC_W-1:0] held_lo, held_hi;
  logic [1:0] held_mask;
  logic [OUT_ADDR_W-1:0] held_addr_lo, held_addr_hi;
  int held_cycles, held_total;

  always @(posedge clk) begin
    if (rst_n && result_valid[0] && !result_ready[0]) begin
      if (held_cycles == 0) begin
        held_lo = result_acc_lo[0];
        held_hi = result_acc_hi[0];
        held_mask = result_lane_mask[0];
        held_addr_lo = result_addr_lo[0];
        held_addr_hi = result_addr_hi[0];
      end else if ({result_acc_lo[0], result_acc_hi[0], result_lane_mask[0],
                    result_addr_lo[0], result_addr_hi[0]} !==
                   {held_lo, held_hi, held_mask,
                    held_addr_lo, held_addr_hi}) begin
        $fatal(1, "FC ROUTER changed packet while ready=0");
      end
      held_cycles++;
      held_total++;
    end

    if (rst_n && result_valid[0] && result_ready[0]) begin
      if (!result_fc_mode[0] || result_layer_id[0] != 3)
        $fatal(1, "FC ROUTER tag mismatch mode=%0d layer=%0d",
               result_fc_mode[0], result_layer_id[0]);
      case (packet_count)
        0: begin
          if (result_lane_mask[0] !== 2'b11 ||
              result_channel_lo[0] != 7 || result_channel_hi[0] != 8 ||
              result_addr_lo[0] != 1007 || result_addr_hi[0] != 1008 ||
              $signed(result_acc_lo[0]) != 101 ||
              $signed(result_acc_hi[0]) != 102)
            $fatal(1, "FC ROUTER packet0 mismatch");
        end
        1: begin
          if (result_lane_mask[0] !== 2'b01 ||
              result_channel_lo[0] != 9 || result_addr_lo[0] != 1009 ||
              $signed(result_acc_lo[0]) != 201)
            $fatal(1, "FC ROUTER packet1 mismatch");
        end
        default: $fatal(1, "FC ROUTER extra packet");
      endcase
      lane_count += result_lane_mask[0][0] + result_lane_mask[0][1];
      packet_count++;
      held_cycles = 0;
    end
  end

  initial begin
    clk = 1'bx;
    rst_n = 1'bx;
    start = 1'bx;
    advance_in = 1'bx;
    drain_en = 1'bx;
    issue_last = 1'bx;
    issue_lane_mask[0] = 'x;
    cfg_out_base_addr = 'x;
    cfg_out_ch_base = 'x;
    cfg_out_channels = 'x;
    cfg_fc_mode = 1'bx;
    cfg_layer_id = 'x;
    result_ready[0] = 1'bx;
    for (int c = 0; c < NC; c++) begin
      acc_lo_in[0][c] = 'x;
      acc_hi_in[0][c] = 'x;
      acc_valid_in[0][c] = 'x;
    end

    #2;
    clk = 0;
    rst_n = 0;
    start = 0;
    advance_in = 0;
    drain_en = 1;
    issue_last = 0;
    issue_lane_mask[0] = 2'b11;
    cfg_out_base_addr = 1000;
    cfg_out_ch_base = 7;
    cfg_out_channels = 10;
    cfg_fc_mode = 1;
    cfg_layer_id = 3;
    result_ready[0] = 0;
    packet_count = 0;
    lane_count = 0;
    held_cycles = 0;
    held_total = 0;
    for (int c = 0; c < NC; c++) begin
      acc_lo_in[0][c] = '0;
      acc_hi_in[0][c] = '0;
      acc_valid_in[0][c] = '0;
    end

    repeat (3) @(negedge clk);
    rst_n = 1;
    start = 1;
    @(negedge clk);
    start = 0;
    advance_in = 1;
    issue_last = 1;

    // Issue edge t0.
    @(negedge clk);
    issue_last = 0;

    // Advance edge t1.
    @(negedge clk);

    // PE[0][0] result is visible for edge t2.
    acc_lo_in[0][0] = 101;
    acc_hi_in[0][0] = 102;
    acc_valid_in[0][0] = 2'b11;
    @(negedge clk);

    // PE[0][1] result is visible for edge t3. Its high lane is outside the
    // configured exclusive channel limit and must be removed.
    acc_valid_in[0][0] = 2'b00;
    acc_lo_in[0][1] = 201;
    acc_hi_in[0][1] = 202;
    acc_valid_in[0][1] = 2'b11;
    @(negedge clk);
    acc_valid_in[0][1] = 2'b00;

    wait (result_valid[0]);
    repeat (3) @(negedge clk);
    result_ready[0] = 1;

    for (int guard = 0; guard < 20 && packet_count != 2; guard++)
      @(negedge clk);
    if (packet_count != 2 || lane_count != 3)
      $fatal(1, "FC ROUTER count packets=%0d lanes=%0d",
             packet_count, lane_count);
    if (held_total < 3)
      $fatal(1, "FC ROUTER did not exercise held-valid path");
    wait (idle);
    $display("OUTPUT_ROUTER_FC TEST PASSED held_cycles=%0d packets=%0d lanes=%0d",
             held_total, packet_count, lane_count);
    $finish;
  end
endmodule
