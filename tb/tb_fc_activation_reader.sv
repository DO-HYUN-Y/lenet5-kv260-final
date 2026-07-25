`timescale 1ns/1ps

module tb_fc_activation_reader;
  localparam int ACT_W = 8;
  localparam int NG = 4;
  localparam int NC = 8;
  localparam int ADDR_W = 10;
  localparam int KOUT_W = 9;
  localparam int CHANNEL_W = 8;
  localparam int DEPTH = 1 << ADDR_W;

  logic clk;
  logic rst_n;
  logic start;
  logic consume;
  logic packed_layout;
  logic [KOUT_W-1:0] cfg_length;
  logic [CHANNEL_W-1:0] cfg_channels;
  logic [KOUT_W-1:0] cfg_plane_bytes;
  logic [ADDR_W-1:0] cfg_plane_words;
  logic [ADDR_W-1:0] cfg_base_word;
  logic bank_en [0:NC-1];
  logic [ADDR_W-1:0] bank_addr [0:NC-1];
  logic [15:0] bank_rdata [0:NC-1];
  logic signed [ACT_W-1:0] pix_data;
  logic pix_valid;
  logic [15:0] mem [0:NC-1][0:DEPTH-1];

  int accepted_count;
  int active_case;

  fc_activation_reader #(
    .ACT_W(ACT_W), .NG(NG), .NC(NC), .ADDR_W(ADDR_W),
    .KOUT_W(KOUT_W), .CHANNEL_W(CHANNEL_W)
  ) dut (.*);

  always #5 clk = ~clk;
  always_ff @(posedge clk)
    for (int c = 0; c < NC; c++)
      if (bank_en[c]) bank_rdata[c] <= mem[c][bank_addr[c]];

  function automatic int sample_value(input int case_id, input int index);
    sample_value = ((case_id * 43 + index * 23) % 256) - 128;
  endfunction

  always @(posedge clk) begin
    if (rst_n && consume) begin
      int expected;
      if (!pix_valid) $fatal(1, "FC_ACT_READER consumed invalid");
      expected = sample_value(active_case, accepted_count);
      if ($signed(pix_data) !== expected)
        $fatal(1, "FC_ACT_READER data case=%0d idx=%0d got=%0d exp=%0d",
               active_case, accepted_count, $signed(pix_data), expected);
      accepted_count = accepted_count + 1;
    end
  end

  task automatic clear_mem;
    begin
      for (int c = 0; c < NC; c++) begin
        bank_rdata[c] = '0;
        for (int a = 0; a < DEPTH; a++) mem[c][a] = '0;
      end
    end
  endtask

  task automatic consume_all(input int count, input int seed);
    int ignored;
    begin
      ignored = $urandom(seed);
      for (int guard = 0;
           guard < count * 5 && accepted_count < count; guard++) begin
        consume = ($urandom_range(0, 3) != 0);
        @(negedge clk);
      end
      consume = 1'b0;
      if (accepted_count != count)
        $fatal(1, "FC_ACT_READER timeout got=%0d exp=%0d",
               accepted_count, count);
      @(posedge clk);
      #1;
      if (pix_valid) $fatal(1, "FC_ACT_READER valid after final consume");
    end
  endtask

  task automatic run_chw;
    int channels;
    int plane_bytes;
    int plane_words;
    int length;
    int base_word;
    begin
      channels = 16;
      plane_bytes = 25;
      plane_words = 13;
      length = channels * plane_bytes;
      base_word = 19;
      clear_mem();
      for (int index = 0; index < length; index++) begin
        int ch;
        int position;
        int bank;
        int slot;
        int addr;
        int value;
        ch = index / plane_bytes;
        position = index % plane_bytes;
        bank = ch % NC;
        slot = ch / NC;
        addr = base_word + slot * plane_words + position / 2;
        value = sample_value(1, index);
        if (position[0]) mem[bank][addr][15:8] = value[7:0];
        else mem[bank][addr][7:0] = value[7:0];
      end
      @(negedge clk);
      active_case = 1;
      accepted_count = 0;
      packed_layout = 1'b0;
      cfg_length = KOUT_W'(length);
      cfg_channels = CHANNEL_W'(channels);
      cfg_plane_bytes = KOUT_W'(plane_bytes);
      cfg_plane_words = ADDR_W'(plane_words);
      cfg_base_word = ADDR_W'(base_word);
      start = 1'b1;
      @(negedge clk);
      start = 1'b0;
      consume_all(length, 20260724);
      $display("FC_ACT_READER CHW PASSED elements=%0d", length);
    end
  endtask

  task automatic run_packed;
    int length;
    int base_word;
    begin
      length = 120;
      base_word = 101;
      clear_mem();
      for (int index = 0; index < length; index++) begin
        int bank;
        int addr;
        int value;
        bank = (index % (2 * NC)) / 2;
        addr = base_word + index / (2 * NC);
        value = sample_value(2, index);
        if (index[0]) mem[bank][addr][15:8] = value[7:0];
        else mem[bank][addr][7:0] = value[7:0];
      end
      @(negedge clk);
      active_case = 2;
      accepted_count = 0;
      packed_layout = 1'b1;
      cfg_length = KOUT_W'(length);
      cfg_channels = '0;
      cfg_plane_bytes = '0;
      cfg_plane_words = '0;
      cfg_base_word = ADDR_W'(base_word);
      start = 1'b1;
      @(negedge clk);
      start = 1'b0;
      consume_all(length, 20260725);
      $display("FC_ACT_READER PACKED PASSED elements=%0d", length);
    end
  endtask

  initial begin
    clk = 1'bx;
    rst_n = 1'bx;
    start = 1'bx;
    consume = 1'bx;
    packed_layout = 1'bx;
    cfg_length = 'x;
    cfg_channels = 'x;
    cfg_plane_bytes = 'x;
    cfg_plane_words = 'x;
    cfg_base_word = 'x;
    accepted_count = 0;
    active_case = 0;

    #2;
    clk = 1'b0;
    rst_n = 1'b0;
    start = 1'b0;
    consume = 1'b0;
    packed_layout = 1'b0;
    cfg_length = '0;
    cfg_channels = '0;
    cfg_plane_bytes = '0;
    cfg_plane_words = '0;
    cfg_base_word = '0;
    repeat (4) @(negedge clk);
    rst_n = 1'b1;
    @(posedge clk);
    #1;
    if ($isunknown({pix_valid, pix_data}))
      $fatal(1, "FC_ACT_READER XPROP after reset");

    run_chw();
    run_packed();
    $display("FC_ACTIVATION_READER TEST PASSED");
    $finish;
  end

endmodule
