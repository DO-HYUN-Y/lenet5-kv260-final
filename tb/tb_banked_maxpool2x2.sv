`timescale 1ns/1ps

module tb_banked_maxpool2x2;
  localparam int NC = 8;
  localparam int ADDR_W = 11;
  localparam int DIM_W = 8;
  localparam int CHANNEL_W = 8;
  localparam int DEPTH = 1 << ADDR_W;

  import "DPI-C" function int maxpool2x2_golden(
      input int top_pair, input int bottom_pair);

  logic clk;
  logic rst_n;
  logic start;
  logic [DIM_W-1:0] cfg_in_w;
  logic [DIM_W-1:0] cfg_in_h;
  logic [CHANNEL_W-1:0] cfg_channels;
  logic [ADDR_W-1:0] cfg_in_base_word;
  logic [ADDR_W-1:0] cfg_out_base_word;
  logic [ADDR_W-1:0] cfg_in_plane_words;
  logic [ADDR_W-1:0] cfg_out_plane_words;
  logic rd_en [0:NC-1];
  logic [ADDR_W-1:0] rd_top_addr [0:NC-1];
  logic [ADDR_W-1:0] rd_bottom_addr [0:NC-1];
  logic [15:0] rd_top_data [0:NC-1];
  logic [15:0] rd_bottom_data [0:NC-1];
  logic wr_en [0:NC-1];
  logic [ADDR_W-1:0] wr_addr [0:NC-1];
  logic [15:0] wr_data [0:NC-1];
  logic [1:0] wr_strb [0:NC-1];
  logic busy;
  logic done;

  logic [15:0] in_mem [0:NC-1][0:DEPTH-1];
  logic [15:0] out_mem [0:NC-1][0:DEPTH-1];
  int read_group_count;
  int write_group_count;
  int write_lane_count;
  int done_pulse_count;

  banked_maxpool2x2 #(
    .NC(NC), .ADDR_W(ADDR_W), .DIM_W(DIM_W),
    .CHANNEL_W(CHANNEL_W), .MAX_CHANNELS(16)
  ) dut (.*);

  always #5 clk = ~clk;

  always_ff @(posedge clk) begin
    for (int c = 0; c < NC; c++) begin
      if (rd_en[c]) begin
        rd_top_data[c] <= in_mem[c][rd_top_addr[c]];
        rd_bottom_data[c] <= in_mem[c][rd_bottom_addr[c]];
      end
      if (wr_en[c]) begin
        if (wr_strb[c][0])
          out_mem[c][wr_addr[c]][7:0] <= wr_data[c][7:0];
        if (wr_strb[c][1])
          out_mem[c][wr_addr[c]][15:8] <= wr_data[c][15:8];
      end
    end
  end

  always @(posedge clk) begin
    bit any_read;
    bit any_write;
    any_read = 1'b0;
    any_write = 1'b0;
    if (rst_n) begin
      for (int c = 0; c < NC; c++) begin
        any_read |= rd_en[c];
        any_write |= wr_en[c];
        if (wr_en[c]) begin
          if (!$onehot(wr_strb[c]))
            $fatal(1, "BANK_POOL write strobe bank=%0d strb=%b",
                   c, wr_strb[c]);
          write_lane_count = write_lane_count + 1;
        end
      end
      if (any_read) read_group_count = read_group_count + 1;
      if (any_write) write_group_count = write_group_count + 1;
      if (done) done_pulse_count = done_pulse_count + 1;
    end
  end

  function automatic int sample_value(
      input int case_id,
      input int channel,
      input int y,
      input int x
  );
    sample_value =
        ((case_id * 53 + channel * 37 + y * 11 + x * 7) % 256) - 128;
  endfunction

  task automatic run_case(
      input int case_id,
      input int in_w,
      input int in_h,
      input int channels,
      input int in_base,
      input int out_base
  );
    int in_plane_words;
    int out_w;
    int out_h;
    int out_size;
    int out_plane_words;
    int expected_groups;
    int expected_lanes;
    begin
      in_plane_words = (in_w * in_h + 1) / 2;
      out_w = in_w / 2;
      out_h = in_h / 2;
      out_size = out_w * out_h;
      out_plane_words = (out_size + 1) / 2;
      expected_groups = ((channels + NC - 1) / NC) * out_size;
      expected_lanes = channels * out_size;

      for (int c = 0; c < NC; c++) begin
        rd_top_data[c] = '0;
        rd_bottom_data[c] = '0;
        for (int a = 0; a < DEPTH; a++) begin
          in_mem[c][a] = 16'h0000;
          out_mem[c][a] = 16'hA55A;
        end
      end

      for (int ch = 0; ch < channels; ch++) begin
        int bank;
        int slot;
        bank = ch % NC;
        slot = ch / NC;
        for (int y = 0; y < in_h; y++) begin
          for (int x = 0; x < in_w; x++) begin
            int position;
            int address;
            int value;
            position = y * in_w + x;
            address = in_base + slot * in_plane_words + position / 2;
            value = sample_value(case_id, ch, y, x);
            if (position[0])
              in_mem[bank][address][15:8] = value[7:0];
            else
              in_mem[bank][address][7:0] = value[7:0];
          end
        end
      end

      @(negedge clk);
      cfg_in_w = DIM_W'(in_w);
      cfg_in_h = DIM_W'(in_h);
      cfg_channels = CHANNEL_W'(channels);
      cfg_in_base_word = ADDR_W'(in_base);
      cfg_out_base_word = ADDR_W'(out_base);
      cfg_in_plane_words = ADDR_W'(in_plane_words);
      cfg_out_plane_words = ADDR_W'(out_plane_words);
      read_group_count = 0;
      write_group_count = 0;
      write_lane_count = 0;
      done_pulse_count = 0;
      start = 1'b1;
      @(negedge clk);
      start = 1'b0;

      for (int guard = 0; guard < expected_groups + 100; guard++) begin
        @(negedge clk);
        if (done) break;
      end
      if (!done)
        $fatal(1, "BANK_POOL timeout case=%0d groups=%0d",
               case_id, expected_groups);
      @(negedge clk);
      if (busy)
        $fatal(1, "BANK_POOL busy after done case=%0d", case_id);
      @(negedge clk);
      if (done)
        $fatal(1, "BANK_POOL done is not one cycle case=%0d", case_id);

      if (read_group_count != expected_groups)
        $fatal(1, "BANK_POOL read groups case=%0d got=%0d exp=%0d",
               case_id, read_group_count, expected_groups);
      if (write_group_count != expected_groups)
        $fatal(1, "BANK_POOL write groups case=%0d got=%0d exp=%0d",
               case_id, write_group_count, expected_groups);
      if (write_lane_count != expected_lanes)
        $fatal(1, "BANK_POOL write lanes case=%0d got=%0d exp=%0d",
               case_id, write_lane_count, expected_lanes);
      if (done_pulse_count != 1)
        $fatal(1, "BANK_POOL done count case=%0d got=%0d",
               case_id, done_pulse_count);

      for (int ch = 0; ch < channels; ch++) begin
        int bank;
        int slot;
        bank = ch % NC;
        slot = ch / NC;
        for (int oy = 0; oy < out_h; oy++) begin
          for (int ox = 0; ox < out_w; ox++) begin
            int top_word;
            int bottom_word;
            int expected;
            int out_position;
            int out_address;
            int got;
            top_word =
                (sample_value(case_id, ch, 2 * oy, 2 * ox) & 8'hff) |
                ((sample_value(case_id, ch, 2 * oy, 2 * ox + 1) &
                  8'hff) << 8);
            bottom_word =
                (sample_value(case_id, ch, 2 * oy + 1, 2 * ox) &
                 8'hff) |
                ((sample_value(case_id, ch, 2 * oy + 1, 2 * ox + 1) &
                  8'hff) << 8);
            expected = maxpool2x2_golden(top_word, bottom_word);
            out_position = oy * out_w + ox;
            out_address =
                out_base + slot * out_plane_words + out_position / 2;
            if (out_position[0])
              got = $signed(out_mem[bank][out_address][15:8]);
            else
              got = $signed(out_mem[bank][out_address][7:0]);
            if (got != expected)
              $fatal(1,
                  "BANK_POOL data case=%0d ch=%0d y=%0d x=%0d got=%0d exp=%0d",
                  case_id, ch, oy, ox, got, expected);
          end
        end
        if (out_size[0]) begin
          int last_address;
          last_address = out_base + slot * out_plane_words +
                         out_size / 2;
          if (out_mem[bank][last_address][15:8] !== 8'hA5)
            $fatal(1, "BANK_POOL byte preserve case=%0d ch=%0d",
                   case_id, ch);
        end
      end

      $display(
          "BANK_POOL CASE PASSED id=%0d in=%0dx%0d ch=%0d groups=%0d lanes=%0d",
          case_id, in_w, in_h, channels,
          read_group_count, write_lane_count);
    end
  endtask

  initial begin
    clk = 1'bx;
    rst_n = 1'bx;
    start = 1'bx;
    cfg_in_w = 'x;
    cfg_in_h = 'x;
    cfg_channels = 'x;
    cfg_in_base_word = 'x;
    cfg_out_base_word = 'x;
    cfg_in_plane_words = 'x;
    cfg_out_plane_words = 'x;
    read_group_count = 0;
    write_group_count = 0;
    write_lane_count = 0;
    done_pulse_count = 0;

    #2;
    clk = 1'b0;
    rst_n = 1'b0;
    start = 1'b0;
    cfg_in_w = '0;
    cfg_in_h = '0;
    cfg_channels = '0;
    cfg_in_base_word = '0;
    cfg_out_base_word = '0;
    cfg_in_plane_words = '0;
    cfg_out_plane_words = '0;
    repeat (4) @(negedge clk);
    rst_n = 1'b1;
    @(posedge clk);
    #1;
    if ($isunknown({busy, done}))
      $fatal(1, "BANK_POOL XPROP visible status unknown after reset");

    run_case(1, 28, 28, 6, 31, 900);
    run_case(2, 10, 10, 16, 77, 500);
    $display("BANKED_MAXPOOL2X2 TEST PASSED");
    $finish;
  end

endmodule
