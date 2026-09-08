`timescale 1ns/1ps

module tb_alexnet_n8_dma_result_egress;

  localparam int COUNT_W = 11;
  localparam int BYTE_COUNT_W = 16;
  localparam int N_BASE_W = 16;
  localparam int TILE_TAG_W = 16;

  logic clk = 1'b0;
  logic rst;
  logic clear_error;
  logic descriptor_valid;
  logic descriptor_ready;
  logic [COUNT_W-1:0] descriptor_word_count;
  logic [BYTE_COUNT_W-1:0] descriptor_byte_count;
  logic [1:0] descriptor_destination;
  logic [2:0] descriptor_slice;
  logic [N_BASE_W-1:0] descriptor_n_base;
  logic [7:0] descriptor_lane_mask;
  logic [TILE_TAG_W-1:0] descriptor_first_tile_tag;
  logic packet_valid;
  logic packet_ready;
  logic [63:0] packet_values;
  logic [7:0] packet_lane_mask;
  logic [1:0] packet_destination;
  logic [2:0] packet_slice;
  logic [4:0] packet_m;
  logic [N_BASE_W-1:0] packet_n_base;
  logic [TILE_TAG_W-1:0] packet_tile_tag;
  logic [127:0] m_axis_tdata;
  logic [15:0] m_axis_tkeep;
  logic m_axis_tvalid;
  logic m_axis_tready;
  logic m_axis_tlast;
  logic busy;
  logic transfer_active;
  logic transfer_done;
  logic descriptor_rejected;
  logic descriptor_error;
  logic metadata_error;
  logic protocol_error;
  logic [1:0] active_destination;
  logic [2:0] active_slice;
  logic [N_BASE_W-1:0] active_n_base;
  logic [7:0] active_lane_mask;
  logic [TILE_TAG_W-1:0] active_first_tile_tag;
  logic [COUNT_W-1:0] words_accepted;
  logic [COUNT_W-1:0] words_transferred;
  logic [COUNT_W-1:0] beats_transferred;
  logic [15:0] completed_transfers;
  logic [TILE_TAG_W-1:0] completed_first_tile_tag;
  logic [TILE_TAG_W-1:0] completed_last_tile_tag;

  int seed;
  int seed_sink;
  int cycles;
  int total_packets;
  int total_axis_words;
  int total_axis_beats;
  int rejected_descriptors;
  int completed_pulses;
  int source_backpressure_cycles;
  int axis_stall_run;
  int maximum_axis_stall;
  int current_transaction;
  int current_word_count;
  int current_output_width;
  int current_axis_word_index;
  logic [1:0] current_destination;
  logic [2:0] current_slice;
  logic [N_BASE_W-1:0] current_n_base;
  logic [7:0] current_lane_mask;
  logic [TILE_TAG_W-1:0] current_first_tile_tag;
  logic monitor_transfer;
  logic random_axis_stalls;
  logic held_axis_valid;
  logic [127:0] held_axis_data;
  logic [15:0] held_axis_keep;
  logic held_axis_last;

  alexnet_n8_dma_result_egress dut (.*);

  always #2.5 clk = ~clk;

  function automatic logic [63:0] make_word(
      input int transaction,
      input int word_index);
    logic [63:0] result;
    int value;
    begin
      result = '0;
      for (int lane = 0; lane < 8; lane++) begin
        value = (transaction * 71 + word_index * 47 + lane * 31 + 13) &
                8'hff;
        result[lane*8 +: 8] = value[7:0];
      end
      make_word = result;
    end
  endfunction

  function automatic logic [63:0] mask_word(
      input logic [63:0] values,
      input logic [7:0] mask);
    logic [63:0] result;
    begin
      result = '0;
      for (int lane = 0; lane < 8; lane++) begin
        if (mask[lane])
          result[lane*8 +: 8] = values[lane*8 +: 8];
      end
      mask_word = result;
    end
  endfunction

  function automatic logic [4:0] packet_m_for_index(
      input int word_index,
      input int output_width);
    begin
      packet_m_for_index = 5'((word_index % output_width) % 4);
    end
  endfunction

  function automatic logic [TILE_TAG_W-1:0] packet_tag_for_index(
      input int word_index,
      input int output_width,
      input logic [TILE_TAG_W-1:0] first_tag);
    int row;
    int x;
    int groups_per_row;
    begin
      row = word_index / output_width;
      x = word_index % output_width;
      groups_per_row = (output_width + 3) / 4;
      packet_tag_for_index =
          first_tag + TILE_TAG_W'(row * groups_per_row + x / 4);
    end
  endfunction

  always @(negedge clk) begin
    if (rst)
      m_axis_tready <= 1'b0;
    else if (random_axis_stalls)
      m_axis_tready <= $urandom_range(0, 4) != 0;
    else
      m_axis_tready <= 1'b1;
  end

  always @(posedge clk) begin
    int words_this_beat;
    logic [127:0] expected_data;
    logic [15:0] expected_keep;
    logic expected_last;

    if (rst) begin
      cycles = 0;
      total_packets = 0;
      total_axis_words = 0;
      total_axis_beats = 0;
      rejected_descriptors = 0;
      completed_pulses = 0;
      source_backpressure_cycles = 0;
      axis_stall_run = 0;
      maximum_axis_stall = 0;
      held_axis_valid = 1'b0;
    end else begin
      cycles = cycles + 1;
      if (cycles > 100000)
        $fatal(1, "DMA result egress watchdog expired");

      if (descriptor_rejected)
        rejected_descriptors = rejected_descriptors + 1;
      if (transfer_done)
        completed_pulses = completed_pulses + 1;
      if (packet_valid && !packet_ready)
        source_backpressure_cycles = source_backpressure_cycles + 1;
      if (packet_valid && packet_ready)
        total_packets = total_packets + 1;

      if (held_axis_valid &&
          (!m_axis_tvalid || m_axis_tdata != held_axis_data ||
           m_axis_tkeep != held_axis_keep ||
           m_axis_tlast != held_axis_last))
        $fatal(1, "DMA result AXIS output changed under backpressure");

      if (m_axis_tvalid) begin
        if (!monitor_transfer ||
            current_axis_word_index >= current_word_count)
          $fatal(1, "DMA result produced output outside monitored transfer");
        words_this_beat =
            current_word_count - current_axis_word_index >= 2 ? 2 : 1;
        expected_data = '0;
        expected_data[63:0] = mask_word(
            make_word(current_transaction, current_axis_word_index),
            current_lane_mask);
        if (words_this_beat == 2)
          expected_data[127:64] = mask_word(
              make_word(current_transaction, current_axis_word_index + 1),
              current_lane_mask);
        expected_keep = words_this_beat == 2 ? 16'hffff : 16'h00ff;
        expected_last = current_axis_word_index + words_this_beat ==
                        current_word_count;
        if (m_axis_tdata != expected_data ||
            m_axis_tkeep != expected_keep ||
            m_axis_tlast != expected_last)
          $fatal(1,
                 "DMA result beat mismatch tx=%0d word=%0d data=%032x/%032x keep=%04x/%04x last=%0b/%0b",
                 current_transaction, current_axis_word_index,
                 m_axis_tdata, expected_data, m_axis_tkeep, expected_keep,
                 m_axis_tlast, expected_last);

        if (m_axis_tready) begin
          current_axis_word_index = current_axis_word_index +
                                    words_this_beat;
          total_axis_words = total_axis_words + words_this_beat;
          total_axis_beats = total_axis_beats + 1;
          axis_stall_run = 0;
        end else begin
          axis_stall_run = axis_stall_run + 1;
          if (axis_stall_run > maximum_axis_stall)
            maximum_axis_stall = axis_stall_run;
        end
      end else begin
        axis_stall_run = 0;
      end

      held_axis_valid = m_axis_tvalid && !m_axis_tready;
      if (held_axis_valid) begin
        held_axis_data = m_axis_tdata;
        held_axis_keep = m_axis_tkeep;
        held_axis_last = m_axis_tlast;
      end
    end
  end

  task automatic submit_descriptor(
      input int word_count,
      input int byte_count,
      input logic [1:0] destination,
      input logic [2:0] slice,
      input logic [N_BASE_W-1:0] n_base,
      input logic [7:0] lane_mask,
      input logic [TILE_TAG_W-1:0] first_tile_tag);
    begin
      @(negedge clk);
      while (!descriptor_ready)
        @(negedge clk);
      descriptor_word_count = COUNT_W'(word_count);
      descriptor_byte_count = BYTE_COUNT_W'(byte_count);
      descriptor_destination = destination;
      descriptor_slice = slice;
      descriptor_n_base = n_base;
      descriptor_lane_mask = lane_mask;
      descriptor_first_tile_tag = first_tile_tag;
      descriptor_valid = 1'b1;
      @(posedge clk);
      @(negedge clk);
      descriptor_valid = 1'b0;
    end
  endtask

  task automatic reject_descriptor(
      input int word_count,
      input int byte_count,
      input logic [1:0] destination,
      input logic [N_BASE_W-1:0] n_base,
      input logic [7:0] lane_mask);
    int completed_before;
    int packets_before;
    begin
      completed_before = completed_transfers;
      packets_before = total_packets;
      monitor_transfer = 1'b0;
      submit_descriptor(word_count, byte_count, destination, 3'd0,
                        n_base, lane_mask,
                        TILE_TAG_W'(16'hd000 + rejected_descriptors));
      while (!descriptor_rejected)
        @(negedge clk);
      if (busy || transfer_active || packet_ready || m_axis_tvalid ||
          completed_transfers != completed_before ||
          total_packets != packets_before)
        $fatal(1, "rejected DMA result descriptor consumed payload");
      @(negedge clk);
    end
  endtask

  task automatic drive_packets(
      input int transaction,
      input int word_count,
      input int output_width,
      input logic [1:0] destination,
      input logic [2:0] slice,
      input logic [N_BASE_W-1:0] n_base,
      input logic [7:0] lane_mask,
      input logic [TILE_TAG_W-1:0] first_tile_tag,
      input logic inject_metadata_errors);
    logic [63:0] driven_values;
    logic [7:0] driven_mask;
    logic [1:0] driven_destination;
    logic [2:0] driven_slice;
    logic [N_BASE_W-1:0] driven_n_base;
    logic [4:0] driven_m;
    logic [TILE_TAG_W-1:0] driven_tag;
    begin
      for (int word_index = 0; word_index < word_count; word_index++) begin
        repeat ($urandom_range(0, 2)) @(negedge clk);
        driven_values = mask_word(make_word(transaction, word_index),
                                  lane_mask);
        driven_mask = lane_mask;
        driven_destination = destination;
        driven_slice = slice;
        driven_n_base = n_base;
        driven_m = packet_m_for_index(word_index, output_width);
        driven_tag = packet_tag_for_index(word_index, output_width,
                                          first_tile_tag);

        if (inject_metadata_errors) begin
          case (word_index)
            1: driven_destination = destination + 1'b1;
            2: driven_slice = slice + 1'b1;
            3: driven_n_base = n_base + 8;
            4: driven_mask = 8'h03;
            5: driven_m = 5'd4;
            6: driven_values = make_word(transaction, word_index);
            default: begin end
          endcase
        end

        @(negedge clk);
        packet_values = driven_values;
        packet_lane_mask = driven_mask;
        packet_destination = driven_destination;
        packet_slice = driven_slice;
        packet_m = driven_m;
        packet_n_base = driven_n_base;
        packet_tile_tag = driven_tag;
        packet_valid = 1'b1;
        @(posedge clk);
        while (!packet_ready) begin
          @(negedge clk);
          @(posedge clk);
        end
        @(negedge clk);
        packet_valid = 1'b0;
      end
    end
  endtask

  task automatic run_transfer(
      input int transaction,
      input int word_count,
      input int output_width,
      input logic [1:0] destination,
      input logic [2:0] slice,
      input logic [N_BASE_W-1:0] n_base,
      input logic [7:0] lane_mask,
      input logic [TILE_TAG_W-1:0] first_tile_tag,
      input logic inject_metadata_errors);
    int completed_before;
    logic [TILE_TAG_W-1:0] expected_last_tag;
    begin
      current_transaction = transaction;
      current_word_count = word_count;
      current_output_width = output_width;
      current_axis_word_index = 0;
      current_destination = destination;
      current_slice = slice;
      current_n_base = n_base;
      current_lane_mask = lane_mask;
      current_first_tile_tag = first_tile_tag;
      monitor_transfer = 1'b1;
      completed_before = completed_transfers;
      expected_last_tag = packet_tag_for_index(word_count - 1,
                                               output_width,
                                               first_tile_tag);

      submit_descriptor(word_count, word_count * 8, destination, slice,
                        n_base, lane_mask, first_tile_tag);
      while (!transfer_active)
        @(negedge clk);
      if (active_destination != destination || active_slice != slice ||
          active_n_base != n_base || active_lane_mask != lane_mask ||
          active_first_tile_tag != first_tile_tag)
        $fatal(1, "DMA result active descriptor mismatch");

      drive_packets(transaction, word_count, output_width, destination,
                    slice, n_base, lane_mask, first_tile_tag,
                    inject_metadata_errors);
      while (!transfer_done)
        @(negedge clk);
      if (current_axis_word_index != word_count ||
          words_accepted != word_count ||
          words_transferred != word_count ||
          beats_transferred != (word_count + 1) / 2 ||
          completed_transfers != completed_before + 1 ||
          completed_first_tile_tag != first_tile_tag ||
          completed_last_tile_tag != expected_last_tag)
        $fatal(1,
               "DMA result completion mismatch tx=%0d axis=%0d/%0d accepted=%0d transferred=%0d beats=%0d completed=%0d/%0d first=%0h/%0h last=%0h/%0h",
               transaction, current_axis_word_index, word_count,
               words_accepted, words_transferred, beats_transferred,
               completed_transfers, completed_before + 1,
               completed_first_tile_tag, first_tile_tag,
               completed_last_tile_tag, expected_last_tag);
      monitor_transfer = 1'b0;
      @(negedge clk);
    end
  endtask

  task automatic clear_errors;
    begin
      @(negedge clk);
      clear_error = 1'b1;
      @(posedge clk);
      @(negedge clk);
      clear_error = 1'b0;
      if (protocol_error || descriptor_error || metadata_error)
        $fatal(1, "DMA result sticky errors did not clear");
    end
  endtask

  initial begin
    seed = 32'h7a53_19d1;
    seed_sink = $urandom(seed);
    rst = 1'b1;
    clear_error = 1'b0;
    descriptor_valid = 1'b0;
    descriptor_word_count = '0;
    descriptor_byte_count = '0;
    descriptor_destination = '0;
    descriptor_slice = '0;
    descriptor_n_base = '0;
    descriptor_lane_mask = '0;
    descriptor_first_tile_tag = '0;
    packet_valid = 1'b0;
    packet_values = '0;
    packet_lane_mask = '0;
    packet_destination = '0;
    packet_slice = '0;
    packet_m = '0;
    packet_n_base = '0;
    packet_tile_tag = '0;
    m_axis_tready = 1'b0;
    random_axis_stalls = 1'b0;
    monitor_transfer = 1'b0;
    current_transaction = 0;
    current_word_count = 0;
    current_output_width = 1;
    current_axis_word_index = 0;
    current_destination = '0;
    current_slice = '0;
    current_n_base = '0;
    current_lane_mask = '0;
    current_first_tile_tag = '0;

    repeat (5) @(negedge clk);
    rst = 1'b0;
    repeat (2) @(negedge clk);
    if ($isunknown({descriptor_ready, packet_ready, m_axis_tvalid,
                    m_axis_tkeep, m_axis_tlast, busy, transfer_active,
                    transfer_done, descriptor_rejected, protocol_error,
                    completed_transfers}))
      $fatal(1, "DMA result reset left unknown outputs");

    reject_descriptor(0, 0, 2'd2, 16'd0, 8'hff);
    reject_descriptor(1025, 8200, 2'd2, 16'd0, 8'hff);
    reject_descriptor(10, 79, 2'd2, 16'd0, 8'hff);
    reject_descriptor(10, 80, 2'd3, 16'd0, 8'hff);
    reject_descriptor(10, 80, 2'd2, 16'd7, 8'hff);
    reject_descriptor(10, 80, 2'd2, 16'd0, 8'h81);
    if (rejected_descriptors != 6 || !descriptor_error || !protocol_error)
      $fatal(1, "DMA result descriptor rejection coverage mismatch");
    clear_errors();

    random_axis_stalls = 1'b1;
    run_transfer(0, 8, 4, 2'd2, 3'd0, 16'd0, 8'hff,
                 16'h1000, 1'b0);
    run_transfer(1, 729, 27, 2'd1, 3'd1, 16'd1032, 8'hff,
                 16'h2000, 1'b0);
    run_transfer(2, 17, 5, 2'd0, 3'd7, 16'd2040, 8'h3f,
                 16'h3000, 1'b0);
    if (protocol_error)
      $fatal(1, "valid DMA result transfers raised protocol error");

    run_transfer(3, 9, 3, 2'd2, 3'd2, 16'd64, 8'h0f,
                 16'h4000, 1'b1);
    if (!metadata_error || !protocol_error || descriptor_error)
      $fatal(1, "malformed result metadata did not raise isolated error");
    clear_errors();

    random_axis_stalls = 1'b0;
    repeat (4) @(negedge clk);
    if (busy || transfer_active || !descriptor_ready || packet_ready ||
        m_axis_tvalid || completed_transfers != 4 ||
        completed_pulses != 4 || total_packets != 763 ||
        total_axis_words != 763 || total_axis_beats != 383 ||
        rejected_descriptors != 6 || protocol_error)
      $fatal(1,
             "DMA result final mismatch transfers=%0d pulses=%0d packets=%0d words=%0d beats=%0d rejects=%0d",
             completed_transfers, completed_pulses, total_packets,
             total_axis_words, total_axis_beats, rejected_descriptors);

    $display(
        "ALEXNET_N8_DMA_RESULT_EGRESS_TEST_PASSED transfers=%0d packets=%0d axis_beats=%0d rejects=%0d metadata_error_packets=6 source_backpressure_cycles=%0d maxstall=%0d seed=%0d",
        completed_transfers, total_packets, total_axis_beats,
        rejected_descriptors, source_backpressure_cycles,
        maximum_axis_stall, seed);
    $finish;
  end

endmodule
