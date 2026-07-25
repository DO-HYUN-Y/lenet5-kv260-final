`timescale 1ns/1ps

module tb_activation_pingpong_subsystem;
  localparam int DATA_W = 8;
  localparam int NG = 4;
  localparam int NC = 8;
  localparam int ADDR_W = 9;
  localparam int DIM_W = 6;
  localparam int CHANNEL_W = 8;
  localparam int KOUT_W = 9;
  localparam int IN_W = 10;
  localparam int IN_H = 10;
  localparam int CHANNELS = 16;
  localparam int IN_PLANE_WORDS = 50;
  localparam int OUT_W = 5;
  localparam int OUT_H = 5;
  localparam int OUT_PLANE_WORDS = 13;

  import "DPI-C" function int maxpool2x2_golden(
      input int top_pair, input int bottom_pair);

  logic clk;
  logic rst_n;
  logic [1:0] owner;
  logic read_set;
  logic write_set;
  logic compute_start;
  logic compute_fc_mode;
  logic core_pix_consume;
  logic signed [DATA_W-1:0] core_pix_data;
  logic core_pix_valid;
  logic core_bank_we [0:NC-1];
  logic [ADDR_W-1:0] core_bank_addr [0:NC-1];
  logic [15:0] core_bank_wdata [0:NC-1];
  logic [1:0] core_bank_wstrb [0:NC-1];
  logic core_bank_ready [0:NC-1];
  logic [DIM_W-1:0] conv_width;
  logic [DIM_W-1:0] conv_height;
  logic [CHANNEL_W-1:0] conv_channels;
  logic [ADDR_W-1:0] conv_base_word;
  logic [ADDR_W:0] conv_plane_words;
  logic fc_packed_layout;
  logic [KOUT_W-1:0] fc_length;
  logic [CHANNEL_W-1:0] fc_channels;
  logic [KOUT_W-1:0] fc_plane_bytes;
  logic [ADDR_W-1:0] fc_plane_words;
  logic [ADDR_W-1:0] fc_base_word;
  logic pool_start;
  logic [DIM_W-1:0] pool_in_w;
  logic [DIM_W-1:0] pool_in_h;
  logic [CHANNEL_W-1:0] pool_channels;
  logic [ADDR_W-1:0] pool_in_base_word;
  logic [ADDR_W-1:0] pool_out_base_word;
  logic [ADDR_W-1:0] pool_in_plane_words;
  logic [ADDR_W-1:0] pool_out_plane_words;
  logic pool_busy;
  logic pool_done;
  logic host_set;
  logic host_en [0:NC-1];
  logic [1:0] host_we [0:NC-1];
  logic [ADDR_W-1:0] host_addr [0:NC-1];
  logic [15:0] host_wdata [0:NC-1];
  logic [15:0] host_rdata [0:NC-1];
  logic host_rvalid;

  int reader_index;
  int seed;

  activation_pingpong_subsystem #(
    .DATA_W(DATA_W), .NG(NG), .NC(NC), .ADDR_W(ADDR_W),
    .DIM_W(DIM_W), .CHANNEL_W(CHANNEL_W), .KOUT_W(KOUT_W)
  ) dut (.*);

  always #5 clk = ~clk;

  function automatic int sample_value(
      input int channel, input int y, input int x);
    sample_value = ((channel * 37 + y * 13 + x * 7 + 29) % 256) - 128;
  endfunction

  function automatic int pooled_value(
      input int channel, input int oy, input int ox);
    int top_pair;
    int bottom_pair;
    begin
      top_pair =
          (sample_value(channel, 2*oy, 2*ox) & 8'hff) |
          ((sample_value(channel, 2*oy, 2*ox+1) & 8'hff) << 8);
      bottom_pair =
          (sample_value(channel, 2*oy+1, 2*ox) & 8'hff) |
          ((sample_value(channel, 2*oy+1, 2*ox+1) & 8'hff) << 8);
      pooled_value = maxpool2x2_golden(top_pair, bottom_pair);
    end
  endfunction

  always @(posedge clk) begin
    if (rst_n && core_pix_consume) begin
      int ch;
      int position;
      int oy;
      int ox;
      int expected;
      if (!core_pix_valid)
        $fatal(1, "PINGPONG reader consumed invalid");
      ch = reader_index / (OUT_W * OUT_H);
      position = reader_index % (OUT_W * OUT_H);
      oy = position / OUT_W;
      ox = position % OUT_W;
      expected = pooled_value(ch, oy, ox);
      if ($signed(core_pix_data) !== expected)
        $fatal(1,
            "PINGPONG reader data idx=%0d ch=%0d y=%0d x=%0d got=%0d exp=%0d",
            reader_index, ch, oy, ox, $signed(core_pix_data), expected);
      reader_index++;
    end
  end

  task automatic host_idle;
    begin
      for (int c = 0; c < NC; c++) begin
        host_en[c] = 1'b0;
        host_we[c] = 2'b00;
        host_addr[c] = '0;
        host_wdata[c] = '0;
      end
    end
  endtask

  task automatic host_write_word_all(
      input bit set_id,
      input int address,
      input bit initialize_output
  );
    begin
      @(negedge clk);
      owner = 2'd0;
      host_set = set_id;
      for (int c = 0; c < NC; c++) begin
        host_en[c] = 1'b1;
        host_we[c] = 2'b11;
        host_addr[c] = ADDR_W'(address);
        if (initialize_output) begin
          host_wdata[c] = 16'hA5A5;
        end else begin
          int slot;
          int position;
          int channel;
          int lo;
          int hi;
          slot = address / IN_PLANE_WORDS;
          position = (address % IN_PLANE_WORDS) * 2;
          channel = c + slot * NC;
          lo = sample_value(channel, position / IN_W, position % IN_W);
          hi = sample_value(
              channel, (position + 1) / IN_W, (position + 1) % IN_W);
          host_wdata[c] = {8'(hi), 8'(lo)};
        end
      end
      @(negedge clk);
      host_idle();
    end
  endtask

  initial begin
    int ignored;
    clk = 1'bx;
    rst_n = 1'bx;
    owner = 'x;
    read_set = 1'bx;
    write_set = 1'bx;
    compute_start = 1'bx;
    compute_fc_mode = 1'bx;
    core_pix_consume = 1'bx;
    conv_width = 'x;
    conv_height = 'x;
    conv_channels = 'x;
    conv_base_word = 'x;
    conv_plane_words = 'x;
    fc_packed_layout = 1'bx;
    fc_length = 'x;
    fc_channels = 'x;
    fc_plane_bytes = 'x;
    fc_plane_words = 'x;
    fc_base_word = 'x;
    pool_start = 1'bx;
    pool_in_w = 'x;
    pool_in_h = 'x;
    pool_channels = 'x;
    pool_in_base_word = 'x;
    pool_out_base_word = 'x;
    pool_in_plane_words = 'x;
    pool_out_plane_words = 'x;
    host_set = 1'bx;
    for (int c = 0; c < NC; c++) begin
      core_bank_we[c] = 1'bx;
      core_bank_addr[c] = 'x;
      core_bank_wdata[c] = 'x;
      core_bank_wstrb[c] = 'x;
      host_en[c] = 1'bx;
      host_we[c] = 'x;
      host_addr[c] = 'x;
      host_wdata[c] = 'x;
    end
    reader_index = 0;
    seed = 20260724;
    ignored = $value$plusargs("SEED=%d", seed);
    ignored = $urandom(seed);

    #2;
    clk = 1'b0;
    rst_n = 1'b0;
    owner = 2'd0;
    read_set = 1'b0;
    write_set = 1'b1;
    compute_start = 1'b0;
    compute_fc_mode = 1'b0;
    core_pix_consume = 1'b0;
    conv_width = '0;
    conv_height = '0;
    conv_channels = '0;
    conv_base_word = '0;
    conv_plane_words = '0;
    fc_packed_layout = 1'b0;
    fc_length = '0;
    fc_channels = '0;
    fc_plane_bytes = '0;
    fc_plane_words = '0;
    fc_base_word = '0;
    pool_start = 1'b0;
    pool_in_w = DIM_W'(IN_W);
    pool_in_h = DIM_W'(IN_H);
    pool_channels = CHANNEL_W'(CHANNELS);
    pool_in_base_word = '0;
    pool_out_base_word = '0;
    pool_in_plane_words = ADDR_W'(IN_PLANE_WORDS);
    pool_out_plane_words = ADDR_W'(OUT_PLANE_WORDS);
    host_set = 1'b0;
    for (int c = 0; c < NC; c++) begin
      core_bank_we[c] = 1'b0;
      core_bank_addr[c] = '0;
      core_bank_wdata[c] = '0;
      core_bank_wstrb[c] = '0;
    end
    host_idle();
    repeat (4) @(negedge clk);
    rst_n = 1'b1;

    // Set0 receives a 10x10x16 feature map.
    for (int a = 0; a < 2 * IN_PLANE_WORDS; a++)
      host_write_word_all(1'b0, a, 1'b0);
    // Set1 is initialized so the odd 25th output byte can be checked.
    for (int a = 0; a < 2 * OUT_PLANE_WORDS; a++)
      host_write_word_all(1'b1, a, 1'b1);

    @(negedge clk);
    owner = 2'd2;
    read_set = 1'b0;
    write_set = 1'b1;
    pool_start = 1'b1;
    @(negedge clk);
    pool_start = 1'b0;
    for (int guard = 0; guard < 200 && !pool_done; guard++)
      @(negedge clk);
    if (!pool_done) $fatal(1, "PINGPONG pool timeout");
    @(negedge clk);
    owner = 2'd0;

    // Read every pooled word back through the host port.
    host_set = 1'b1;
    for (int a = 0; a < 2 * OUT_PLANE_WORDS; a++) begin
      @(negedge clk);
      for (int c = 0; c < NC; c++) begin
        host_en[c] = 1'b1;
        host_we[c] = 2'b00;
        host_addr[c] = ADDR_W'(a);
      end
      @(posedge clk);
      #1;
      if (!host_rvalid) $fatal(1, "PINGPONG host read valid");
      for (int c = 0; c < NC; c++) begin
        int slot;
        int position;
        int channel;
        int expected_lo;
        int expected_hi;
        slot = a / OUT_PLANE_WORDS;
        position = (a % OUT_PLANE_WORDS) * 2;
        channel = c + slot * NC;
        expected_lo = pooled_value(
            channel, position / OUT_W, position % OUT_W);
        if ($signed(host_rdata[c][7:0]) !== expected_lo)
          $fatal(1, "PINGPONG host low ch=%0d pos=%0d", channel, position);
        if (position + 1 < OUT_W * OUT_H) begin
          expected_hi = pooled_value(
              channel, (position + 1) / OUT_W, (position + 1) % OUT_W);
          if ($signed(host_rdata[c][15:8]) !== expected_hi)
            $fatal(1, "PINGPONG host high ch=%0d pos=%0d",
                   channel, position + 1);
        end else if (host_rdata[c][15:8] !== 8'hA5) begin
          $fatal(1, "PINGPONG host byte preserve ch=%0d", channel);
        end
      end
    end
    @(negedge clk);
    host_idle();
    $display("PINGPONG POOL+HOST PASSED");

    // Feed the pooled CHW result through the FC reader.
    owner = 2'd1;
    read_set = 1'b1;
    write_set = 1'b0;
    compute_fc_mode = 1'b1;
    fc_packed_layout = 1'b0;
    fc_length = KOUT_W'(CHANNELS * OUT_W * OUT_H);
    fc_channels = CHANNEL_W'(CHANNELS);
    fc_plane_bytes = KOUT_W'(OUT_W * OUT_H);
    fc_plane_words = ADDR_W'(OUT_PLANE_WORDS);
    fc_base_word = '0;
    reader_index = 0;
    compute_start = 1'b1;
    @(negedge clk);
    compute_start = 1'b0;
    for (int guard = 0;
         guard < 2000 && reader_index < CHANNELS * OUT_W * OUT_H;
         guard++) begin
      core_pix_consume = ($urandom_range(0, 3) != 0);
      @(negedge clk);
    end
    core_pix_consume = 1'b0;
    if (reader_index != CHANNELS * OUT_W * OUT_H)
      $fatal(1, "PINGPONG reader count=%0d", reader_index);
    $display("PINGPONG FC READER PASSED elements=%0d", reader_index);

    // Exercise the compute write mux directly.
    @(negedge clk);
    for (int c = 0; c < NC; c++) begin
      core_bank_we[c] = 1'b1;
      core_bank_addr[c] = ADDR_W'(200);
      core_bank_wdata[c] = {8'(c + 32), 8'(c + 16)};
      core_bank_wstrb[c] = 2'b11;
    end
    @(negedge clk);
    for (int c = 0; c < NC; c++) core_bank_we[c] = 1'b0;
    owner = 2'd0;
    host_set = 1'b0;
    for (int c = 0; c < NC; c++) begin
      host_en[c] = 1'b1;
      host_we[c] = 2'b00;
      host_addr[c] = ADDR_W'(200);
    end
    @(posedge clk);
    #1;
    for (int c = 0; c < NC; c++)
      if (host_rdata[c] !== {8'(c + 32), 8'(c + 16)})
        $fatal(1, "PINGPONG compute write c=%0d", c);

    $display("ACTIVATION_PINGPONG_SUBSYSTEM TEST PASSED");
    $finish;
  end

endmodule
