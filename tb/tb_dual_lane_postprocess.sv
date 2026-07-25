`timescale 1ns/1ps

module tb_dual_lane_postprocess;
  localparam int ACC_W = 32;
  localparam int SCALE_W = 18;
  localparam int OUT_ADDR_W = 16;
  localparam int OUT_CH_W = 8;
  localparam int GROUP_W = 2;
  localparam int LAYER_ID_W = 3;
  localparam int MAX_TXN = 4096;

  import "DPI-C" function int postprocess_golden(
      input int acc, input int bias, input int scale, input int relu_en);

  logic clk;
  logic rst_n;
  logic flush;
  logic in_valid;
  logic in_ready;
  logic signed [ACC_W-1:0] in_acc_lo;
  logic signed [ACC_W-1:0] in_acc_hi;
  logic [1:0] in_lane_mask;
  logic signed [ACC_W-1:0] in_bias_lo;
  logic signed [ACC_W-1:0] in_bias_hi;
  logic signed [SCALE_W-1:0] in_scale_lo;
  logic signed [SCALE_W-1:0] in_scale_hi;
  logic in_relu_en;
  logic [OUT_ADDR_W-1:0] in_addr_lo;
  logic [OUT_ADDR_W-1:0] in_addr_hi;
  logic [OUT_CH_W-1:0] in_channel_lo;
  logic [OUT_CH_W-1:0] in_channel_hi;
  logic [GROUP_W-1:0] in_group;
  logic in_fc_mode;
  logic [LAYER_ID_W-1:0] in_layer_id;
  logic out_valid;
  logic out_ready;
  logic [15:0] out_data;
  logic [1:0] out_lane_mask;
  logic [OUT_ADDR_W-1:0] out_addr_lo;
  logic [OUT_ADDR_W-1:0] out_addr_hi;
  logic [OUT_CH_W-1:0] out_channel_lo;
  logic [OUT_CH_W-1:0] out_channel_hi;
  logic [GROUP_W-1:0] out_group;
  logic out_fc_mode;
  logic [LAYER_ID_W-1:0] out_layer_id;
  logic idle;

  dual_lane_postprocess dut (.*);

  always #5 clk = ~clk;

  typedef struct {
    int lo;
    int hi;
    logic [1:0] mask;
    logic [OUT_ADDR_W-1:0] addr_lo;
    logic [OUT_ADDR_W-1:0] addr_hi;
    logic [OUT_CH_W-1:0] channel_lo;
    logic [OUT_CH_W-1:0] channel_hi;
    logic [GROUP_W-1:0] group_idx;
    logic fc_mode;
    logic [LAYER_ID_W-1:0] layer_id;
    longint due_advance;
    int txn_id;
  } expected_t;

  expected_t exp_q [0:MAX_TXN-1];
  int q_head;
  int q_tail;
  int next_txn_id;
  longint advance_count;
  int accepted_count;
  int observed_count;

  task automatic check_output(input expected_t exp);
    int got_lo;
    int got_hi;
    begin
      got_lo = $signed(out_data[7:0]);
      got_hi = $signed(out_data[15:8]);
      if (out_lane_mask !== exp.mask)
        $fatal(1, "POST mask txn=%0d got=%b exp=%b",
               exp.txn_id, out_lane_mask, exp.mask);
      if (exp.mask[0] && (got_lo != exp.lo))
        $fatal(1, "POST lo txn=%0d got=%0d exp=%0d",
               exp.txn_id, got_lo, exp.lo);
      if (exp.mask[1] && (got_hi != exp.hi))
        $fatal(1, "POST hi txn=%0d got=%0d exp=%0d",
               exp.txn_id, got_hi, exp.hi);
      if ((!exp.mask[0] && (got_lo != 0)) ||
          (!exp.mask[1] && (got_hi != 0)))
        $fatal(1, "POST masked data txn=%0d got=%h", exp.txn_id, out_data);
      if ({out_addr_lo, out_addr_hi, out_channel_lo, out_channel_hi,
           out_group, out_fc_mode, out_layer_id} !==
          {exp.addr_lo, exp.addr_hi, exp.channel_lo, exp.channel_hi,
           exp.group_idx, exp.fc_mode, exp.layer_id})
        $fatal(1, "POST metadata txn=%0d", exp.txn_id);
    end
  endtask

  always @(posedge clk) begin
    bit ce_before;
    bit fire_before;
    bit consume_before;
    expected_t item;

    ce_before = dut.pipe_ce;
    fire_before = rst_n && in_valid && in_ready;
    consume_before = rst_n && out_valid && out_ready;

    if (consume_before) begin
      if (q_head >= q_tail)
        $fatal(1, "POST output without expected transaction");
      item = exp_q[q_head];
      if (advance_count != item.due_advance)
        $fatal(1, "POST cycle txn=%0d advance=%0d exp=%0d",
               item.txn_id, advance_count, item.due_advance);
      check_output(item);
      q_head = q_head + 1;
      observed_count = observed_count + 1;
    end

    if (fire_before) begin
      if (q_tail >= MAX_TXN)
        $fatal(1, "POST expected queue overflow");
      item.lo = postprocess_golden(
          $signed(in_acc_lo), $signed(in_bias_lo),
          $signed(in_scale_lo), in_relu_en);
      item.hi = postprocess_golden(
          $signed(in_acc_hi), $signed(in_bias_hi),
          $signed(in_scale_hi), in_relu_en);
      item.mask = in_lane_mask;
      item.addr_lo = in_addr_lo;
      item.addr_hi = in_addr_hi;
      item.channel_lo = in_channel_lo;
      item.channel_hi = in_channel_hi;
      item.group_idx = in_group;
      item.fc_mode = in_fc_mode;
      item.layer_id = in_layer_id;
      item.due_advance = advance_count + 4;
      item.txn_id = next_txn_id;
      exp_q[q_tail] = item;
      q_tail = q_tail + 1;
      next_txn_id = next_txn_id + 1;
      accepted_count = accepted_count + 1;
    end

    if (rst_n && ce_before) advance_count = advance_count + 1;
  end

  task automatic drive_one(
      input int acc_lo,
      input int acc_hi,
      input int bias_lo,
      input int bias_hi,
      input int scale_lo,
      input int scale_hi,
      input bit relu_en,
      input logic [1:0] mask
  );
    begin
      @(negedge clk);
      in_valid = 1'b1;
      in_acc_lo = ACC_W'(acc_lo);
      in_acc_hi = ACC_W'(acc_hi);
      in_bias_lo = ACC_W'(bias_lo);
      in_bias_hi = ACC_W'(bias_hi);
      in_scale_lo = SCALE_W'(scale_lo);
      in_scale_hi = SCALE_W'(scale_hi);
      in_relu_en = relu_en;
      in_lane_mask = mask;
      in_addr_lo = OUT_ADDR_W'(next_txn_id * 2);
      in_addr_hi = OUT_ADDR_W'(next_txn_id * 2 + 1);
      in_channel_lo = OUT_CH_W'(next_txn_id);
      in_channel_hi = OUT_CH_W'(next_txn_id + 1);
      in_group = GROUP_W'(next_txn_id);
      in_fc_mode = next_txn_id[0];
      in_layer_id = LAYER_ID_W'(next_txn_id);
      @(posedge clk);
      while (!in_ready) @(posedge clk);
      @(negedge clk);
      in_valid = 1'b0;
    end
  endtask

  task automatic wait_empty;
    begin
      out_ready = 1'b1;
      for (int guard = 0; guard < 1000 && ((q_head != q_tail) || !idle);
           guard++)
        @(negedge clk);
      if ((q_head != q_tail) || !idle)
        $fatal(1, "POST drain timeout head=%0d tail=%0d idle=%0d",
               q_head, q_tail, idle);
    end
  endtask

  initial begin
    int seed;
    int random_count;
    int ignored;

    clk = 1'bx;
    rst_n = 1'bx;
    flush = 1'bx;
    in_valid = 1'bx;
    in_acc_lo = 'x;
    in_acc_hi = 'x;
    in_lane_mask = 'x;
    in_bias_lo = 'x;
    in_bias_hi = 'x;
    in_scale_lo = 'x;
    in_scale_hi = 'x;
    in_relu_en = 1'bx;
    in_addr_lo = 'x;
    in_addr_hi = 'x;
    in_channel_lo = 'x;
    in_channel_hi = 'x;
    in_group = 'x;
    in_fc_mode = 1'bx;
    in_layer_id = 'x;
    out_ready = 1'bx;
    q_head = 0;
    q_tail = 0;
    next_txn_id = 0;
    advance_count = 0;
    accepted_count = 0;
    observed_count = 0;
    seed = 20260724;
    random_count = 0;
    ignored = $value$plusargs("SEED=%d", seed);
    ignored = $value$plusargs("RANDOM_COUNT=%d", random_count);
    ignored = $urandom(seed);
    $display("POSTPROCESS seed=%0d random_count=%0d", seed, random_count);

    #2;
    clk = 1'b0;
    rst_n = 1'b0;
    flush = 1'b0;
    in_valid = 1'b0;
    in_acc_lo = '0;
    in_acc_hi = '0;
    in_lane_mask = '0;
    in_bias_lo = '0;
    in_bias_hi = '0;
    in_scale_lo = '0;
    in_scale_hi = '0;
    in_relu_en = 1'b0;
    in_addr_lo = '0;
    in_addr_hi = '0;
    in_channel_lo = '0;
    in_channel_hi = '0;
    in_group = '0;
    in_fc_mode = 1'b0;
    in_layer_id = '0;
    out_ready = 1'b0;
    repeat (4) @(negedge clk);
    rst_n = 1'b1;
    @(posedge clk);
    #1;
    if ($isunknown({in_ready, out_valid, out_data, idle}))
      $fatal(1, "POST XPROP visible output unknown after reset");

    out_ready = 1'b1;
    drive_one(100, -100, 20, 20, 65536, 65536, 1'b0, 2'b11);
    drive_one(-100, 100, 0, 0, 65536, 65536, 1'b1, 2'b11);
    drive_one(1000000, -1000000, 0, 0, 120000, 120000, 1'b0, 2'b11);
    drive_one(31, -31, 1, -1, 65536, 65536, 1'b0, 2'b01);
    wait_empty();
    $display("POSTPROCESS DIRECTED PASSED vectors=4");

    if (random_count > 0) begin
      fork
        begin : consumer_stalls
          for (int cycle = 0; cycle < random_count * 6; cycle++) begin
            @(negedge clk);
            out_ready = ($urandom_range(0, 3) != 0);
          end
          out_ready = 1'b1;
        end
        begin : random_driver
          for (int n = 0; n < random_count; n++) begin
            int acc_lo;
            int acc_hi;
            int bias_lo;
            int bias_hi;
            int scale_lo;
            int scale_hi;
            logic [1:0] mask;
            acc_lo = $urandom_range(0, 4000000) - 2000000;
            acc_hi = $urandom_range(0, 4000000) - 2000000;
            bias_lo = $urandom_range(0, 20000) - 10000;
            bias_hi = $urandom_range(0, 20000) - 10000;
            scale_lo = $urandom_range(1024, 120000);
            scale_hi = $urandom_range(1024, 120000);
            mask = $urandom_range(1, 3);
            drive_one(acc_lo, acc_hi, bias_lo, bias_hi,
                      scale_lo, scale_hi, $urandom_range(0, 1), mask);
          end
        end
      join
      wait_empty();
      $display("POSTPROCESS RANDOM PASSED vectors=%0d seed=%0d",
               random_count, seed);
    end

    if (accepted_count != observed_count)
      $fatal(1, "POST count accepted=%0d observed=%0d",
             accepted_count, observed_count);
    $display("DUAL_LANE_POSTPROCESS TEST PASSED accepted=%0d",
             accepted_count);
    $finish;
  end

endmodule
