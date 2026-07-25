`timescale 1ns/1ps

module tb_axis_lenet_ingress;
  localparam int DATA_W = 8;
  localparam int NG = 4;
  localparam int NC = 8;
  localparam int AXIS_W = 128;
  localparam int AXIS_BYTES = 16;
  localparam int COUNT_W = 16;
  localparam int BASE_W = 16;
  localparam int WGT_ADDR_W = 11;
  localparam int PARAM_ADDR_W = 8;
  localparam int BANK_ADDR_W = 9;
  localparam int ACC_W = 32;
  localparam int SCALE_W = 18;
  localparam int BANK_W = $clog2(NC);
  localparam int WEIGHT_WORD_W = 64;

  logic clk;
  logic rst_n;
  logic start;
  logic clear_error;
  logic [1:0] cfg_mode;
  logic [COUNT_W-1:0] cfg_count;
  logic [BASE_W-1:0] cfg_base;
  logic [BANK_W-1:0] cfg_bank_base;
  logic cfg_activation_set;
  logic [AXIS_W-1:0] s_axis_tdata;
  logic [AXIS_BYTES-1:0] s_axis_tkeep;
  logic s_axis_tvalid;
  logic s_axis_tready;
  logic s_axis_tlast;
  logic model_host_ready;
  logic weight_host_wr_en [0:NC-1];
  logic [WGT_ADDR_W-1:0] weight_host_wr_addr;
  logic [WEIGHT_WORD_W-1:0] weight_host_wr_data [0:NC-1];
  logic param_host_wr_en;
  logic [PARAM_ADDR_W-1:0] param_host_wr_addr;
  logic signed [ACC_W-1:0] param_host_wr_bias;
  logic signed [SCALE_W-1:0] param_host_wr_scale;
  logic activation_host_ready;
  logic activation_host_set;
  logic activation_host_en [0:NC-1];
  logic [1:0] activation_host_we [0:NC-1];
  logic [BANK_ADDR_W-1:0] activation_host_addr [0:NC-1];
  logic [15:0] activation_host_wdata [0:NC-1];
  logic busy;
  logic done;
  logic error;

  int seed;
  int random_count;
  int plusarg_status;
  int random_seed_value;
  int random_stalls;
  int current_tx;
  int current_mode;
  int current_count;
  int current_base;
  int current_bank;
  int current_set;
  int weight_seen;
  int param_seen;
  int activation_seen;
  int cycle_count;
  int monitor_enable;

  import "DPI-C" function int ingress_weight_byte(
      input int seed, input int transaction, input int byte_index);
  import "DPI-C" function int ingress_param_bias(
      input int seed, input int transaction, input int index);
  import "DPI-C" function int ingress_param_scale(
      input int seed, input int transaction, input int index);
  import "DPI-C" function int ingress_activation_word(
      input int seed, input int transaction, input int index);

  axis_lenet_ingress dut (.*);

  always #5 clk = ~clk;

  always @(negedge clk) begin
    if (!rst_n) begin
      model_host_ready <= 1'b0;
      activation_host_ready <= 1'b0;
    end else if (random_stalls) begin
      model_host_ready <= ($urandom_range(0, 3) != 0);
      activation_host_ready <= ($urandom_range(0, 3) != 0);
    end else begin
      model_host_ready <= 1'b1;
      activation_host_ready <= 1'b1;
    end
  end

  always @(posedge clk) begin
    if (!rst_n) begin
      cycle_count <= 0;
    end else begin
      cycle_count <= cycle_count + 1;
      if (monitor_enable) begin
        if (weight_host_wr_en[0]) begin
          if (current_mode != 0)
            $fatal(1, "INGRESS unexpected weight event cycle=%0d",
                   cycle_count);
          if (weight_host_wr_addr !==
              WGT_ADDR_W'(current_base + weight_seen))
            $fatal(1,
                "INGRESS weight addr cycle=%0d tx=%0d got=%0d exp=%0d",
                cycle_count, current_tx, weight_host_wr_addr,
                current_base + weight_seen);
          for (int c = 0; c < NC; c++) begin
            if (!weight_host_wr_en[c])
              $fatal(1,
                  "INGRESS weight enable cycle=%0d bank=%0d missing",
                  cycle_count, c);
            for (int b = 0; b < 8; b++) begin
              int exp_byte;
              int byte_index;
              byte_index = weight_seen * 64 + c * 8 + b;
              exp_byte = ingress_weight_byte(
                  seed, current_tx, byte_index);
              if (weight_host_wr_data[c][b*8 +: 8] !== 8'(exp_byte))
                $fatal(1,
                    "INGRESS weight data cycle=%0d tx=%0d row=%0d bank=%0d byte=%0d got=%0h exp=%0h",
                    cycle_count, current_tx, weight_seen, c, b,
                    weight_host_wr_data[c][b*8 +: 8], exp_byte);
            end
          end
          weight_seen <= weight_seen + 1;
        end

        if (param_host_wr_en) begin
          int exp_bias;
          int exp_scale;
          if (current_mode != 1)
            $fatal(1, "INGRESS unexpected param event cycle=%0d",
                   cycle_count);
          exp_bias = ingress_param_bias(seed, current_tx, param_seen);
          exp_scale = ingress_param_scale(seed, current_tx, param_seen);
          if (param_host_wr_addr !==
              PARAM_ADDR_W'(current_base + param_seen))
            $fatal(1,
                "INGRESS param addr cycle=%0d tx=%0d got=%0d exp=%0d",
                cycle_count, current_tx, param_host_wr_addr,
                current_base + param_seen);
          if ((param_host_wr_bias !== ACC_W'(exp_bias)) ||
              (param_host_wr_scale !== SCALE_W'(exp_scale)))
            $fatal(1,
                "INGRESS param data cycle=%0d tx=%0d idx=%0d got=(%0d,%0d) exp=(%0d,%0d)",
                cycle_count, current_tx, param_seen,
                param_host_wr_bias, param_host_wr_scale,
                exp_bias, exp_scale);
          param_seen <= param_seen + 1;
        end

        for (int c = 0; c < NC; c++) begin
          if (activation_host_en[c]) begin
            int exp_word;
            if (current_mode != 2)
              $fatal(1,
                  "INGRESS unexpected activation event cycle=%0d",
                  cycle_count);
            exp_word = ingress_activation_word(
                seed, current_tx, activation_seen);
            if (c != current_bank)
              $fatal(1,
                  "INGRESS activation bank cycle=%0d got=%0d exp=%0d",
                  cycle_count, c, current_bank);
            if ((activation_host_addr[c] !==
                 BANK_ADDR_W'(current_base + activation_seen)) ||
                (activation_host_wdata[c] !== 16'(exp_word)) ||
                (activation_host_we[c] !== 2'b11) ||
                (activation_host_set !== current_set))
              $fatal(1,
                  "INGRESS activation cycle=%0d tx=%0d idx=%0d addr=%0d data=%0h set=%0d",
                  cycle_count, current_tx, activation_seen,
                  activation_host_addr[c], activation_host_wdata[c],
                  activation_host_set);
            activation_seen <= activation_seen + 1;
          end
        end
      end
    end
  end

  task automatic reset_dut;
    begin
      rst_n = 1'b0;
      start = 1'bx;
      clear_error = 1'bx;
      cfg_mode = 'x;
      cfg_count = 'x;
      cfg_base = 'x;
      cfg_bank_base = 'x;
      cfg_activation_set = 1'bx;
      s_axis_tdata = 'x;
      s_axis_tkeep = 'x;
      s_axis_tvalid = 1'bx;
      s_axis_tlast = 1'bx;
      random_stalls = 0;
      monitor_enable = 0;
      repeat (4) @(negedge clk);
      start = 1'b0;
      clear_error = 1'b0;
      cfg_mode = '0;
      cfg_count = '0;
      cfg_base = '0;
      cfg_bank_base = '0;
      cfg_activation_set = 1'b0;
      s_axis_tdata = '0;
      s_axis_tkeep = '0;
      s_axis_tvalid = 1'b0;
      s_axis_tlast = 1'b0;
      rst_n = 1'b1;
      repeat (2) @(negedge clk);
      if ($isunknown({s_axis_tready, busy, done, error,
                      weight_host_wr_addr, param_host_wr_en,
                      activation_host_set}))
        $fatal(1, "INGRESS reset left unknown outputs");
    end
  endtask

  task automatic begin_transfer(
      input int tx,
      input int transfer_mode,
      input int transfer_count,
      input int transfer_base,
      input int transfer_bank,
      input int transfer_set,
      input int stalls
  );
    begin
      current_tx = tx;
      current_mode = transfer_mode;
      current_count = transfer_count;
      current_base = transfer_base;
      current_bank = transfer_bank;
      current_set = transfer_set;
      weight_seen = 0;
      param_seen = 0;
      activation_seen = 0;
      random_stalls = stalls;
      monitor_enable = 1;
      @(negedge clk);
      cfg_mode = 2'(transfer_mode);
      cfg_count = COUNT_W'(transfer_count);
      cfg_base = BASE_W'(transfer_base);
      cfg_bank_base = BANK_W'(transfer_bank);
      cfg_activation_set = transfer_set;
      start = 1'b1;
      @(negedge clk);
      start = 1'b0;
      if (!busy)
        $fatal(1, "INGRESS tx=%0d did not start", tx);
    end
  endtask

  task automatic send_beat(
      input logic [127:0] data,
      input logic [15:0] keep,
      input logic last
  );
    int guard;
    begin
      if (random_stalls) begin
        repeat ($urandom_range(0, 2)) @(negedge clk);
      end
      @(negedge clk);
      s_axis_tdata = data;
      s_axis_tkeep = keep;
      s_axis_tlast = last;
      s_axis_tvalid = 1'b1;
      guard = 0;
      while (guard < 2000) begin
        @(posedge clk);
        if (s_axis_tready)
          break;
        guard++;
      end
      if (guard >= 2000)
        $fatal(1, "INGRESS AXIS source timeout tx=%0d", current_tx);
      @(negedge clk);
      s_axis_tvalid = 1'b0;
      s_axis_tdata = '0;
      s_axis_tkeep = '0;
      s_axis_tlast = 1'b0;
    end
  endtask

  task automatic send_weight_transfer(
      input int tx, input int rows, input int base, input int stalls
  );
    begin
      begin_transfer(tx, 0, rows, base, 0, 0, stalls);
      for (int beat = 0; beat < rows * 4; beat++) begin
        logic [127:0] data;
        data = '0;
        for (int b = 0; b < 16; b++)
          data[b*8 +: 8] =
              8'(ingress_weight_byte(seed, tx, beat * 16 + b));
        send_beat(data, 16'hffff, beat == rows * 4 - 1);
      end
      wait_done_and_check(rows);
    end
  endtask

  task automatic send_param_transfer(
      input int tx, input int records, input int base, input int stalls
  );
    int beats;
    begin
      begin_transfer(tx, 1, records, base, 0, 0, stalls);
      beats = (records + 1) / 2;
      for (int beat = 0; beat < beats; beat++) begin
        logic [127:0] data;
        logic [15:0] keep;
        int first;
        data = '0;
        first = beat * 2;
        for (int r = 0; r < 2; r++) begin
          if (first + r < records) begin
            data[r*64 +: 32] =
                32'(ingress_param_bias(seed, tx, first + r));
            data[r*64 + 32 +: 18] =
                18'(ingress_param_scale(seed, tx, first + r));
          end
        end
        keep = ((records - first) >= 2) ? 16'hffff : 16'h00ff;
        send_beat(data, keep, beat == beats - 1);
      end
      wait_done_and_check(records);
    end
  endtask

  task automatic send_activation_transfer(
      input int tx, input int words, input int base,
      input int bank, input int set_id, input int stalls
  );
    int beats;
    begin
      begin_transfer(tx, 2, words, base, bank, set_id, stalls);
      beats = (words + 7) / 8;
      for (int beat = 0; beat < beats; beat++) begin
        logic [127:0] data;
        logic [15:0] keep;
        int first;
        int remaining;
        data = '0;
        keep = '0;
        first = beat * 8;
        remaining = words - first;
        for (int w = 0; w < 8; w++) begin
          if (first + w < words) begin
            data[w*16 +: 16] =
                16'(ingress_activation_word(seed, tx, first + w));
            keep[w*2 +: 2] = 2'b11;
          end
        end
        send_beat(data, keep, beat == beats - 1);
      end
      wait_done_and_check(words);
    end
  endtask

  task automatic wait_done_and_check(input int expected);
    int guard;
    begin
      guard = 0;
      while (!done && guard < 5000) begin
        @(posedge clk);
        #1;
        guard++;
      end
      if (!done)
        $fatal(1, "INGRESS tx=%0d completion timeout", current_tx);
      case (current_mode)
        0: if (weight_seen != expected)
             $fatal(1, "INGRESS weight seen=%0d exp=%0d",
                    weight_seen, expected);
        1: if (param_seen != expected)
             $fatal(1, "INGRESS param seen=%0d exp=%0d",
                    param_seen, expected);
        2: if (activation_seen != expected)
             $fatal(1, "INGRESS activation seen=%0d exp=%0d",
                    activation_seen, expected);
        default: begin
        end
      endcase
      monitor_enable = 0;
      random_stalls = 0;
      $display(
          "INGRESS TX PASSED tx=%0d mode=%0d count=%0d stalls=%0d",
          current_tx, current_mode, expected, random_stalls);
      repeat (2) @(negedge clk);
    end
  endtask

  task automatic malformed_transfer;
    logic [127:0] data;
    begin
      begin_transfer(90, 2, 1, 0, 0, 0, 0);
      data = '0;
      data[15:0] =
          16'(ingress_activation_word(seed, 90, 0));
      send_beat(data, 16'hffff, 1'b0);
      wait_done_and_check(1);
      if (!error)
        $fatal(1, "INGRESS malformed transfer did not flag error");
      @(negedge clk);
      clear_error = 1'b1;
      @(negedge clk);
      clear_error = 1'b0;
      repeat (2) @(negedge clk);
      if (error)
        $fatal(1, "INGRESS clear_error failed");
      $display("MALFORMED_TRANSFER PASSED");
    end
  endtask

  task automatic reset_mid_transfer;
    logic [127:0] data;
    begin
      begin_transfer(91, 0, 2, 0, 0, 0, 0);
      data = '0;
      for (int b = 0; b < 16; b++)
        data[b*8 +: 8] =
            8'(ingress_weight_byte(seed, 91, b));
      send_beat(data, 16'hffff, 1'b0);
      @(negedge clk);
      rst_n = 1'b0;
      monitor_enable = 0;
      repeat (3) @(negedge clk);
      rst_n = 1'b1;
      repeat (2) @(negedge clk);
      if (busy || done || error)
        $fatal(1, "INGRESS reset-mid-transfer did not clear state");
      $display("RESET_MID_TRANSFER PASSED");
    end
  endtask

  initial begin
    clk = 1'b0;
    seed = 20260725;
    random_count = 0;
    plusarg_status = $value$plusargs("SEED=%d", seed);
    plusarg_status = $value$plusargs("RANDOM_COUNT=%d", random_count);
    random_seed_value = $urandom(seed);
    $display("INGRESS seed=%0d random_count=%0d", seed, random_count);

    reset_dut();
    send_weight_transfer(1, 2, 3, 0);
    send_param_transfer(2, 5, 7, 1);
    send_activation_transfer(3, 10, 20, 0, 0, 1);
    send_activation_transfer(4, 1, 9, 3, 1, 0);
    malformed_transfer();
    reset_mid_transfer();

    for (int n = 0; n < random_count; n++) begin
      int m;
      int count;
      int base;
      int bank;
      m = $urandom_range(0, 2);
      base = $urandom_range(0, 40);
      bank = $urandom_range(0, NC - 1);
      case (m)
        0: begin
          count = $urandom_range(1, 4);
          send_weight_transfer(100 + n, count, base, 1);
        end
        1: begin
          count = $urandom_range(1, 9);
          send_param_transfer(100 + n, count, base, 1);
        end
        default: begin
          count = $urandom_range(1, 17);
          send_activation_transfer(
              100 + n, count, base, bank, n & 1, 1);
        end
      endcase
    end

    $display(
        "AXIS_LENET_INGRESS TEST PASSED seed=%0d random_count=%0d",
        seed, random_count);
    $finish;
  end

endmodule
