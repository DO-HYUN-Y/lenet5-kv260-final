`timescale 1ns/1ps

module tb_activation_scalar_reader;
  localparam int ACT_W = 8;
  localparam int NC = 8;
  localparam int ADDR_W = 10;
  localparam int DIM_W = 8;
  localparam int CHANNEL_W = 8;
  localparam int DEPTH = 1 << ADDR_W;

  logic clk;
  logic rst_n;
  logic start;
  logic consume;
  logic [DIM_W-1:0] cfg_width;
  logic [DIM_W-1:0] cfg_height;
  logic [CHANNEL_W-1:0] cfg_channels;
  logic [ADDR_W-1:0] cfg_base_word;
  logic [ADDR_W:0] cfg_plane_words;
  logic bank_en [0:NC-1];
  logic [ADDR_W-1:0] bank_addr [0:NC-1];
  logic [15:0] bank_rdata [0:NC-1];
  logic signed [ACT_W-1:0] pix_data;
  logic pix_valid;

  logic [15:0] mem [0:NC-1][0:DEPTH-1];
  int accepted_count;
  int active_width;
  int active_height;
  int active_channels;
  int active_case;

  activation_scalar_reader #(
    .ACT_W(ACT_W), .NC(NC), .ADDR_W(ADDR_W),
    .DIM_W(DIM_W), .CHANNEL_W(CHANNEL_W)
  ) dut (.*);

  always #5 clk = ~clk;

  always_ff @(posedge clk) begin
    for (int c = 0; c < NC; c++) begin
      if (bank_en[c]) bank_rdata[c] <= mem[c][bank_addr[c]];
    end
  end

  function automatic int sample_value(
      input int case_id,
      input int channel,
      input int y,
      input int x
  );
    sample_value =
        ((case_id * 41 + channel * 29 + y * 17 + x * 5) % 256) - 128;
  endfunction

  always @(posedge clk) begin
    if (rst_n && consume) begin
      int row_width;
      int y;
      int in_row;
      int ch;
      int x;
      int expected;
      if (!pix_valid)
        $fatal(1, "ACT_READER consumed invalid data");
      row_width = active_channels * active_width;
      y = accepted_count / row_width;
      in_row = accepted_count % row_width;
      ch = in_row / active_width;
      x = in_row % active_width;
      expected = sample_value(active_case, ch, y, x);
      if ($signed(pix_data) !== expected)
        $fatal(1,
            "ACT_READER data idx=%0d y=%0d ch=%0d x=%0d got=%0d exp=%0d",
            accepted_count, y, ch, x, $signed(pix_data), expected);
      accepted_count = accepted_count + 1;
    end
  end

  task automatic run_case(
      input int case_id,
      input int width,
      input int height,
      input int channels,
      input int base_word,
      input int seed
  );
    int plane_words;
    int total_pixels;
    int ignored;
    begin
      plane_words = (width * height + 1) / 2;
      total_pixels = width * height * channels;
      for (int c = 0; c < NC; c++) begin
        bank_rdata[c] = '0;
        for (int a = 0; a < DEPTH; a++) mem[c][a] = '0;
      end
      for (int ch = 0; ch < channels; ch++) begin
        int bank;
        int slot;
        bank = ch % NC;
        slot = ch / NC;
        for (int y = 0; y < height; y++) begin
          for (int x = 0; x < width; x++) begin
            int position;
            int address;
            int value;
            position = y * width + x;
            address = base_word + slot * plane_words + position / 2;
            value = sample_value(case_id, ch, y, x);
            if (position[0])
              mem[bank][address][15:8] = value[7:0];
            else
              mem[bank][address][7:0] = value[7:0];
          end
        end
      end

      @(negedge clk);
      active_width = width;
      active_height = height;
      active_channels = channels;
      active_case = case_id;
      accepted_count = 0;
      cfg_width = DIM_W'(width);
      cfg_height = DIM_W'(height);
      cfg_channels = CHANNEL_W'(channels);
      cfg_base_word = ADDR_W'(base_word);
      cfg_plane_words = (ADDR_W+1)'(plane_words);
      consume = 1'b0;
      start = 1'b1;
      ignored = $urandom(seed);
      @(negedge clk);
      start = 1'b0;

      for (int guard = 0;
           guard < total_pixels * 4 && accepted_count < total_pixels;
           guard++) begin
        consume = ($urandom_range(0, 3) != 0);
        @(negedge clk);
      end
      consume = 1'b0;
      if (accepted_count != total_pixels)
        $fatal(1, "ACT_READER timeout case=%0d got=%0d exp=%0d",
               case_id, accepted_count, total_pixels);
      @(posedge clk);
      #1;
      if (pix_valid)
        $fatal(1, "ACT_READER valid remained after final consume case=%0d",
               case_id);
      $display(
          "ACT_READER CASE PASSED id=%0d shape=%0dx%0dx%0d pixels=%0d",
          case_id, width, height, channels, accepted_count);
    end
  endtask

  initial begin
    clk = 1'bx;
    rst_n = 1'bx;
    start = 1'bx;
    consume = 1'bx;
    cfg_width = 'x;
    cfg_height = 'x;
    cfg_channels = 'x;
    cfg_base_word = 'x;
    cfg_plane_words = 'x;
    accepted_count = 0;
    active_width = 0;
    active_height = 0;
    active_channels = 0;
    active_case = 0;

    #2;
    clk = 1'b0;
    rst_n = 1'b0;
    start = 1'b0;
    consume = 1'b0;
    cfg_width = '0;
    cfg_height = '0;
    cfg_channels = '0;
    cfg_base_word = '0;
    cfg_plane_words = '0;
    repeat (4) @(negedge clk);
    rst_n = 1'b1;
    @(posedge clk);
    #1;
    if ($isunknown({pix_valid, pix_data}))
      $fatal(1, "ACT_READER XPROP visible output unknown after reset");

    run_case(1, 14, 14, 6, 13, 20260724);
    run_case(2, 5, 5, 16, 101, 20260725);
    $display("ACTIVATION_SCALAR_READER TEST PASSED");
    $finish;
  end

endmodule
