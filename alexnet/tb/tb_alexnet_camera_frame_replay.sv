`timescale 1ns/1ps

module tb_alexnet_camera_frame_replay;
  localparam int FRAME_WORDS = 5;
  localparam int REPLAY_COUNT = 3;
  localparam int TOTAL_OUTPUTS = FRAME_WORDS * REPLAY_COUNT;

  logic clk = 1'b0;
  logic rst, ce, start;
  logic s_valid, s_ready;
  logic [63:0] s_values;
  logic [7:0] s_lane_mask;
  logic s_last;
  logic m_valid, m_ready;
  logic [63:0] m_values;
  logic [7:0] m_lane_mask;
  logic m_last;
  logic frame_valid, busy, fault;
  logic [$clog2(REPLAY_COUNT + 1)-1:0] completed_replays;

  int cycle_count, accepted_outputs, expected_base;

  always #2.5 clk = ~clk;

  alexnet_camera_frame_replay #(
      .FRAME_WORDS(FRAME_WORDS), .REPLAY_COUNT(REPLAY_COUNT)
  ) dut (.*);

  assign m_ready = cycle_count[1:0] != 2'b01;

  function automatic logic [63:0] word_value(input int base, input int index);
    word_value = 64'h1234_0000_0000_0000 | 64'(base + index);
  endfunction

  task automatic reset_dut;
    begin
      rst = 1'b1;
      ce = 1'b1;
      start = 1'b0;
      s_valid = 1'b0;
      s_values = '0;
      s_lane_mask = 8'h07;
      s_last = 1'b0;
      repeat (4) @(posedge clk);
      rst = 1'b0;
      @(negedge clk);
    end
  endtask

  task automatic start_frame(input int base);
    begin
      expected_base = base;
      accepted_outputs = 0;
      @(negedge clk);
      start = 1'b1;
      @(posedge clk);
      @(negedge clk);
      start = 1'b0;
    end
  endtask

  task automatic send_word(
      input int base,
      input int index,
      input logic [7:0] lane_mask,
      input logic last
  );
    begin
      @(negedge clk);
      s_values = word_value(base, index);
      s_lane_mask = lane_mask;
      s_last = last;
      s_valid = 1'b1;
      do @(posedge clk); while (!s_ready);
      @(negedge clk);
      s_valid = 1'b0;
      s_last = 1'b0;
    end
  endtask

  task automatic send_valid_frame(input int base);
    int index;
    begin
      for (index = 0; index < FRAME_WORDS; index++)
        send_word(base, index, 8'h07, index == FRAME_WORDS - 1);
    end
  endtask

  task automatic wait_for_complete;
    int watchdog;
    begin
      watchdog = 0;
      while ((accepted_outputs != TOTAL_OUTPUTS || busy) && watchdog < 500) begin
        @(posedge clk);
        watchdog++;
      end
      if (watchdog == 500)
        $fatal(1, "camera replay timed out outputs=%0d busy=%0b",
               accepted_outputs, busy);
      if (!frame_valid || fault || completed_replays != REPLAY_COUNT)
        $fatal(1, "camera replay status mismatch frame=%0b fault=%0b replays=%0d",
               frame_valid, fault, completed_replays);
    end
  endtask

  always_ff @(posedge clk) begin
    int expected_index;
    if (rst) begin
      cycle_count <= 0;
    end else begin
      cycle_count <= cycle_count + 1;
      if (m_valid && m_ready) begin
        expected_index = accepted_outputs % FRAME_WORDS;
        if (m_values !== word_value(expected_base, expected_index) ||
            m_lane_mask !== 8'h07 ||
            m_last !== (expected_index == FRAME_WORDS - 1)) begin
          $fatal(1, "camera replay data mismatch output=%0d value=%h last=%0b",
                 accepted_outputs, m_values, m_last);
        end
        accepted_outputs <= accepted_outputs + 1;
      end
    end
  end

  initial begin
    reset_dut();
    start_frame(10);
    send_valid_frame(10);
    wait_for_complete();

    // A new inference replaces the retained frame without requiring reset.
    start_frame(100);
    send_valid_frame(100);
    wait_for_complete();

    reset_dut();
    start_frame(200);
    send_word(200, 0, 8'h07, 1'b1);
    @(posedge clk);
    if (!fault || frame_valid)
      $fatal(1, "early TLAST was not rejected");

    reset_dut();
    start_frame(300);
    send_word(300, 0, 8'hff, 1'b0);
    @(posedge clk);
    if (!fault || frame_valid)
      $fatal(1, "bad lane mask was not rejected");

    $display("ALEXNET_CAMERA_FRAME_REPLAY_TEST_PASSED words=%0d replays=%0d outputs=%0d",
             FRAME_WORDS, REPLAY_COUNT, 2 * TOTAL_OUTPUTS);
    $finish;
  end
endmodule
