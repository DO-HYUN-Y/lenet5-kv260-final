`timescale 1ns/1ps

module tb_banked_activation_writer;
  localparam int NC = 8;
  localparam int BYTE_ADDR_W = 16;
  localparam int WORD_ADDR_W = BYTE_ADDR_W - 1;

  logic clk;
  logic rst_n;
  logic start;
  logic [WORD_ADDR_W-1:0] cfg_bank_base_word;
  logic in_valid [0:NC-1];
  logic in_ready [0:NC-1];
  logic [15:0] in_data [0:NC-1];
  logic [1:0] in_lane_mask [0:NC-1];
  logic [BYTE_ADDR_W-1:0] in_addr_lo [0:NC-1];
  logic [BYTE_ADDR_W-1:0] in_addr_hi [0:NC-1];
  logic bank_we [0:NC-1];
  logic bank_ready [0:NC-1];
  logic [WORD_ADDR_W-1:0] bank_word_addr [0:NC-1];
  logic [15:0] bank_wdata [0:NC-1];
  logic [1:0] bank_wstrb [0:NC-1];

  logic [WORD_ADDR_W-1:0] expected_addr [0:NC-1];
  int accepted_count [0:NC-1];

  banked_activation_writer #(
    .NC(NC), .BYTE_ADDR_W(BYTE_ADDR_W), .WORD_ADDR_W(WORD_ADDR_W)
  ) dut (.*);

  always #5 clk = ~clk;

  always @(posedge clk) begin
    if (rst_n && !start) begin
      for (int c = 0; c < NC; c++) begin
        if ($isunknown({in_ready[c], bank_we[c], bank_word_addr[c],
                        bank_wdata[c], bank_wstrb[c]}))
          $fatal(1, "BANK_WRITER XPROP bank=%0d", c);
        if (in_ready[c] !== bank_ready[c])
          $fatal(1, "BANK_WRITER ready bank=%0d", c);
        if (bank_we[c] !== (in_valid[c] && bank_ready[c]))
          $fatal(1, "BANK_WRITER we bank=%0d", c);
        if (bank_we[c]) begin
          if (bank_word_addr[c] !== expected_addr[c])
            $fatal(1, "BANK_WRITER addr bank=%0d got=%0d exp=%0d",
                   c, bank_word_addr[c], expected_addr[c]);
          if ({bank_wdata[c], bank_wstrb[c]} !==
              {in_data[c], in_lane_mask[c]})
            $fatal(1, "BANK_WRITER payload bank=%0d", c);
          expected_addr[c] = expected_addr[c] + 1'b1;
          accepted_count[c] = accepted_count[c] + 1;
        end
      end
    end

    if (!rst_n || start) begin
      for (int c = 0; c < NC; c++)
        expected_addr[c] = cfg_bank_base_word;
    end
  end

  task automatic clear_sources;
    begin
      for (int c = 0; c < NC; c++) begin
        in_valid[c] = 1'b0;
        in_data[c] = '0;
        in_lane_mask[c] = 2'b01;
        in_addr_lo[c] = '0;
        in_addr_hi[c] = '0;
      end
    end
  endtask

  initial begin
    int seed;
    int random_cycles;
    int ignored;
    int source_seq [0:NC-1];

    clk = 1'bx;
    rst_n = 1'bx;
    start = 1'bx;
    cfg_bank_base_word = 'x;
    for (int c = 0; c < NC; c++) begin
      in_valid[c] = 1'bx;
      in_data[c] = 'x;
      in_lane_mask[c] = 'x;
      in_addr_lo[c] = 'x;
      in_addr_hi[c] = 'x;
      bank_ready[c] = 1'bx;
      expected_addr[c] = '0;
      accepted_count[c] = 0;
      source_seq[c] = 0;
    end
    seed = 20260724;
    random_cycles = 0;
    ignored = $value$plusargs("SEED=%d", seed);
    ignored = $value$plusargs("RANDOM_CYCLES=%d", random_cycles);
    ignored = $urandom(seed);
    $display("BANK_WRITER seed=%0d random_cycles=%0d",
             seed, random_cycles);

    #2;
    clk = 1'b0;
    rst_n = 1'b0;
    start = 1'b0;
    cfg_bank_base_word = WORD_ADDR_W'(37);
    clear_sources();
    for (int c = 0; c < NC; c++) bank_ready[c] = 1'b0;
    repeat (4) @(negedge clk);
    rst_n = 1'b1;
    start = 1'b1;
    @(negedge clk);
    start = 1'b0;

    for (int c = 0; c < NC; c++) begin
      in_valid[c] = 1'b1;
      in_data[c] = {8'(c), 8'(c + 16)};
      in_lane_mask[c] = (c == NC-1) ? 2'b01 : 2'b11;
      in_addr_lo[c] = BYTE_ADDR_W'(2 * c);
      in_addr_hi[c] = BYTE_ADDR_W'(2 * c + 1);
      bank_ready[c] = (c[0] == 1'b0);
    end
    @(negedge clk);
    for (int c = 0; c < NC; c++) begin
      if (bank_ready[c]) in_valid[c] = 1'b0;
      bank_ready[c] = 1'b1;
    end
    @(negedge clk);
    for (int c = 0; c < NC; c++) begin
      if (bank_ready[c]) in_valid[c] = 1'b0;
    end
    repeat (2) @(negedge clk);
    for (int c = 0; c < NC; c++) begin
      if (accepted_count[c] != 1)
        $fatal(1, "BANK_WRITER directed count bank=%0d got=%0d",
               c, accepted_count[c]);
    end
    $display("BANK_WRITER DIRECTED PASSED banks=%0d", NC);

    for (int cycle = 0; cycle < random_cycles; cycle++) begin
      @(negedge clk);
      for (int c = 0; c < NC; c++) begin
        if (!in_valid[c] || bank_ready[c]) begin
          in_valid[c] = ($urandom_range(0, 3) != 0);
          if (in_valid[c]) begin
            in_data[c] = {8'(c), 8'(source_seq[c])};
            in_lane_mask[c] =
                ($urandom_range(0, 7) == 0) ? 2'b01 : 2'b11;
            in_addr_lo[c] = BYTE_ADDR_W'(source_seq[c] * 2);
            in_addr_hi[c] = BYTE_ADDR_W'(source_seq[c] * 2 + 1);
            source_seq[c] = source_seq[c] + 1;
          end
        end
        bank_ready[c] = ($urandom_range(0, 3) != 0);
      end
    end

    for (int guard = 0; guard < 1000; guard++) begin
      bit any_valid;
      @(negedge clk);
      any_valid = 1'b0;
      for (int c = 0; c < NC; c++) begin
        if (in_valid[c] && bank_ready[c]) in_valid[c] = 1'b0;
        bank_ready[c] = 1'b1;
        any_valid |= in_valid[c];
      end
      if (!any_valid) break;
    end
    repeat (2) @(negedge clk);

    for (int c = 0; c < NC; c++) begin
      if (expected_addr[c] != WORD_ADDR_W'(37 + accepted_count[c]))
        $fatal(1, "BANK_WRITER final addr bank=%0d", c);
    end
    if (random_cycles > 0)
      $display("BANK_WRITER RANDOM PASSED cycles=%0d seed=%0d",
               random_cycles, seed);
    $display("BANKED_ACTIVATION_WRITER TEST PASSED");
    $finish;
  end

endmodule
