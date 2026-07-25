`timescale 1ns/1ps

module tb_lenet_global_controller;
  localparam int DIM_W = 6;
  localparam int C_W = 3;
  localparam int KOUT_W = 9;
  localparam int WGT_ADDR_W = 11;
  localparam int OUT_ADDR_W = 16;
  localparam int OUT_CH_W = 8;
  localparam int LAYER_ID_W = 3;
  localparam int BANK_ADDR_W = 9;
  localparam int PARAM_ADDR_W = 8;

  logic clk;
  logic rst_n;
  logic start;
  logic model_valid;
  logic compute_busy;
  logic compute_done;
  logic pool_busy;
  logic pool_done;
  logic param_busy;
  logic param_done;
  logic [1:0] owner;
  logic read_set;
  logic write_set;
  logic compute_start;
  logic pool_start;
  logic param_load_start;
  logic cfg_fc_mode;
  logic [DIM_W-1:0] cfg_fmap_w;
  logic [DIM_W-1:0] cfg_fmap_h;
  logic [C_W-1:0] cfg_c_in;
  logic [DIM_W-1:0] cfg_out_w;
  logic [DIM_W-1:0] cfg_out_h;
  logic [KOUT_W-1:0] cfg_depth;
  logic [WGT_ADDR_W-1:0] weight_read_base;
  logic [OUT_ADDR_W-1:0] out_base_addr;
  logic [OUT_ADDR_W-1:0] out_plane_size;
  logic [OUT_CH_W-1:0] out_ch_base;
  logic [OUT_CH_W-1:0] out_channels;
  logic [OUT_CH_W-1:0] pass_channels;
  logic [LAYER_ID_W-1:0] layer_id;
  logic relu_en;
  logic [BANK_ADDR_W-1:0] cfg_bank_base_word;
  logic [DIM_W-1:0] conv_width;
  logic [DIM_W-1:0] conv_height;
  logic [OUT_CH_W-1:0] conv_channels;
  logic [BANK_ADDR_W-1:0] conv_base_word;
  logic [BANK_ADDR_W:0] conv_plane_words;
  logic fc_packed_layout;
  logic [KOUT_W-1:0] fc_length;
  logic [OUT_CH_W-1:0] fc_channels;
  logic [KOUT_W-1:0] fc_plane_bytes;
  logic [BANK_ADDR_W-1:0] fc_plane_words;
  logic [BANK_ADDR_W-1:0] fc_base_word;
  logic [DIM_W-1:0] pool_in_w;
  logic [DIM_W-1:0] pool_in_h;
  logic [OUT_CH_W-1:0] pool_channels;
  logic [BANK_ADDR_W-1:0] pool_in_base_word;
  logic [BANK_ADDR_W-1:0] pool_out_base_word;
  logic [BANK_ADDR_W-1:0] pool_in_plane_words;
  logic [BANK_ADDR_W-1:0] pool_out_plane_words;
  logic [PARAM_ADDR_W-1:0] param_base;
  logic busy;
  logic done;
  logic irq;
  logic result_set;
  logic [3:0] op_index;
  logic [31:0] busy_cycles;
  logic [31:0] compute_cycles;
  logic [31:0] pool_cycles;
  logic [31:0] param_cycles;

  int param_countdown;
  int compute_countdown;
  int pool_countdown;
  int param_starts;
  int compute_starts;
  int pool_starts;

  lenet_global_controller dut (.*);

  always #5 clk = ~clk;

  task automatic check_compute_descriptor(input int op);
    begin
      case (op)
        0: begin
          if (cfg_fc_mode || cfg_fmap_w != 32 || cfg_fmap_h != 32 ||
              cfg_c_in != 1 || cfg_out_w != 28 || cfg_out_h != 28 ||
              weight_read_base != 0 || out_channels != 6 ||
              pass_channels != 6 || read_set != 0 || write_set != 1 ||
              conv_plane_words != 512 || param_base != 0)
            $fatal(1, "CTRL bad C1 descriptor");
        end
        2: begin
          if (cfg_fc_mode || cfg_depth != 150 ||
              weight_read_base != 25 || out_ch_base != 0 ||
              cfg_bank_base_word != 0 || param_base != 6)
            $fatal(1, "CTRL bad C3 pass0 descriptor");
        end
        3: begin
          if (cfg_fc_mode || weight_read_base != 175 ||
              out_ch_base != 8 || cfg_bank_base_word != 50 ||
              param_base != 6)
            $fatal(1, "CTRL bad C3 pass1 descriptor");
        end
        5: begin
          if (!cfg_fc_mode || cfg_depth != 400 ||
              weight_read_base != 325 || out_ch_base != 0 ||
              out_channels != 120 || pass_channels != 64 ||
              fc_packed_layout || fc_length != 400 ||
              fc_plane_bytes != 25 || param_base != 22)
            $fatal(1, "CTRL bad C5 pass0 descriptor");
        end
        6: begin
          if (!cfg_fc_mode || weight_read_base != 725 ||
              out_ch_base != 64 || pass_channels != 56 ||
              cfg_bank_base_word != 4 || param_base != 22)
            $fatal(1, "CTRL bad C5 pass1 descriptor");
        end
        7: begin
          if (!cfg_fc_mode || cfg_depth != 120 ||
              weight_read_base != 1125 || out_channels != 84 ||
              pass_channels != 64 || !fc_packed_layout ||
              fc_length != 120 || read_set != 1 || write_set != 0 ||
              param_base != 142)
            $fatal(1, "CTRL bad F6 pass0 descriptor");
        end
        8: begin
          if (!cfg_fc_mode || weight_read_base != 1245 ||
              out_ch_base != 64 || pass_channels != 20 ||
              cfg_bank_base_word != 4 || param_base != 142)
            $fatal(1, "CTRL bad F6 pass1 descriptor");
        end
        9: begin
          if (!cfg_fc_mode || cfg_depth != 84 ||
              weight_read_base != 1365 || out_channels != 10 ||
              pass_channels != 10 || relu_en ||
              fc_length != 84 || read_set != 0 || write_set != 1 ||
              param_base != 226)
            $fatal(1, "CTRL bad OUT descriptor");
        end
        default: $fatal(1, "CTRL unexpected compute op=%0d", op);
      endcase
    end
  endtask

  task automatic check_pool_descriptor(input int op);
    begin
      if (op == 1) begin
        if (pool_in_w != 28 || pool_in_h != 28 ||
            pool_channels != 6 || pool_in_plane_words != 392 ||
            pool_out_plane_words != 98 ||
            read_set != 1 || write_set != 0)
          $fatal(1, "CTRL bad S2 descriptor");
      end else if (op == 4) begin
        if (pool_in_w != 10 || pool_in_h != 10 ||
            pool_channels != 16 || pool_in_plane_words != 50 ||
            pool_out_plane_words != 13 ||
            read_set != 1 || write_set != 0)
          $fatal(1, "CTRL bad S4 descriptor");
      end else begin
        $fatal(1, "CTRL unexpected pool op=%0d", op);
      end
    end
  endtask

  always @(posedge clk) begin
    if (!rst_n) begin
      param_busy <= 1'b0;
      param_done <= 1'b0;
      compute_busy <= 1'b0;
      compute_done <= 1'b0;
      pool_busy <= 1'b0;
      pool_done <= 1'b0;
      param_countdown <= 0;
      compute_countdown <= 0;
      pool_countdown <= 0;
    end else begin
      param_done <= 1'b0;
      compute_done <= 1'b0;
      pool_done <= 1'b0;

      if (param_load_start) begin
        check_compute_descriptor(op_index);
        param_busy <= 1'b1;
        param_countdown <= $urandom_range(1, 4);
        param_starts <= param_starts + 1;
      end else if (param_busy) begin
        if (param_countdown == 1) begin
          param_busy <= 1'b0;
          param_done <= 1'b1;
          param_countdown <= 0;
        end else begin
          param_countdown <= param_countdown - 1;
        end
      end

      if (compute_start) begin
        check_compute_descriptor(op_index);
        compute_busy <= 1'b1;
        compute_countdown <= $urandom_range(2, 7);
        compute_starts <= compute_starts + 1;
      end else if (compute_busy) begin
        if (compute_countdown == 1) begin
          compute_busy <= 1'b0;
          compute_done <= 1'b1;
          compute_countdown <= 0;
        end else begin
          compute_countdown <= compute_countdown - 1;
        end
      end

      if (pool_start) begin
        check_pool_descriptor(op_index);
        pool_busy <= 1'b1;
        pool_countdown <= $urandom_range(2, 5);
        pool_starts <= pool_starts + 1;
      end else if (pool_busy) begin
        if (pool_countdown == 1) begin
          pool_busy <= 1'b0;
          pool_done <= 1'b1;
          pool_countdown <= 0;
        end else begin
          pool_countdown <= pool_countdown - 1;
        end
      end
    end
  end

  initial begin
    clk = 1'b0;
    rst_n = 1'b0;
    start = 1'b0;
    model_valid = 1'b1;
    compute_busy = 1'b0;
    compute_done = 1'b0;
    pool_busy = 1'b0;
    pool_done = 1'b0;
    param_busy = 1'b0;
    param_done = 1'b0;
    param_countdown = 0;
    compute_countdown = 0;
    pool_countdown = 0;
    param_starts = 0;
    compute_starts = 0;
    pool_starts = 0;
    repeat (5) @(negedge clk);
    rst_n = 1'b1;
    @(negedge clk);
    start = 1'b1;
    @(negedge clk);
    start = 1'b0;

    for (int guard = 0; guard < 1000 && !done; guard++)
      @(negedge clk);
    if (!done)
      $fatal(1, "CTRL timeout op=%0d", op_index);
    if (!irq || !result_set)
      $fatal(1, "CTRL completion irq/result_set");
    if ((param_starts != 8) || (compute_starts != 8) ||
        (pool_starts != 2))
      $fatal(1, "CTRL event counts param=%0d compute=%0d pool=%0d",
             param_starts, compute_starts, pool_starts);
    if ((busy_cycles == 0) || (compute_cycles == 0) ||
        (pool_cycles == 0) || (param_cycles == 0))
      $fatal(1, "CTRL counters busy=%0d compute=%0d pool=%0d param=%0d",
             busy_cycles, compute_cycles, pool_cycles, param_cycles);

    $display(
        "LENET_GLOBAL_CONTROLLER TEST PASSED busy=%0d compute=%0d pool=%0d param=%0d",
        busy_cycles, compute_cycles, pool_cycles, param_cycles);
    $finish;
  end

endmodule
