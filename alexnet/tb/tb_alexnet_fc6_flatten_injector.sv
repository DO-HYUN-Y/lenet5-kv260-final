`timescale 1ns/1ps

module tb_alexnet_fc6_flatten_injector;
  localparam int TOTAL_K = 9216;
  localparam int MAX_CHUNK = 968;

  logic clk = 1'b0;
  logic rst;
  logic request_valid, request_ready;
  logic [3:0] active_layer_id;
  logic [13:0] active_k_offset;
  logic [9:0] active_k_count;
  logic [1:0] request_destination;
  logic [9:0] request_word_count;
  logic [15:0] request_byte_count;
  logic [2:0] request_m_count;
  logic [15:0] request_tag;
  logic external_request_valid, external_request_ready;
  logic [3:0] external_request_layer_id;
  logic [13:0] external_request_k_offset;
  logic [9:0] external_request_k_count;
  logic [1:0] external_request_destination;
  logic [9:0] external_request_word_count;
  logic [15:0] external_request_byte_count;
  logic [2:0] external_request_m_count;
  logic [15:0] external_request_tag;
  logic pool5_read_request_valid, pool5_read_request_ready;
  logic [10:0] pool5_read_request_word_address;
  logic [2:0] pool5_read_request_lane;
  logic [13:0] pool5_read_request_flat_index;
  logic [15:0] pool5_read_request_tag;
  logic pool5_read_response_valid, pool5_read_response_ready;
  logic signed [7:0] pool5_read_response_value;
  logic pool5_read_response_error;
  logic [127:0] external_axis_tdata;
  logic [15:0] external_axis_tkeep;
  logic external_axis_tvalid, external_axis_tready, external_axis_tlast;
  logic [127:0] compute_axis_tdata;
  logic [15:0] compute_axis_tkeep;
  logic compute_axis_tvalid, compute_axis_tready, compute_axis_tlast;
  logic flatten_active, flatten_done, fault;
  logic [3:0] completed_chunks;
  logic [13:0] completed_scalars;
  logic [10:0] completed_words;

  int current_offset;
  int current_count;
  int current_beat;
  int total_reads;
  int total_words;
  int passthrough_requests;
  int watchdog_cycles;
  logic hold_active;
  logic [127:0] hold_data;
  logic [15:0] hold_keep;
  logic hold_last;

  alexnet_fc6_flatten_injector dut (.*);

  always #2.5 clk = ~clk;

  function automatic logic [7:0] memory_value(input int flat_index);
    int channel;
    int spatial;
    begin
      channel = flat_index / 36;
      spatial = flat_index % 36;
      memory_value = (channel * 3 + spatial * 5 + 8'h29) & 8'hff;
    end
  endfunction

  function automatic logic [63:0] expected_word(input int flat_base);
    logic [63:0] result;
    begin
      result = 0;
      for (int lane = 0; lane < 8; lane++)
        result[lane*8 +: 8] = memory_value(flat_base + lane);
      expected_word = result;
    end
  endfunction

  always @(negedge clk) begin
    if (rst)
      compute_axis_tready <= 1'b0;
    else
      compute_axis_tready <= ($time / 5) % 17 >= 4;
  end

  always @(posedge clk) begin
    int chunk_words;
    int low_word_index;
    int words_in_beat;
    logic expected_last;
    if (rst) begin
      current_beat <= 0;
      total_words <= 0;
      hold_active <= 1'b0;
      watchdog_cycles <= 0;
    end else begin
      watchdog_cycles <= watchdog_cycles + 1;
      if (watchdog_cycles > 300000)
        $fatal(1,
               "FC6 injector watchdog reads=%0d words=%0d chunks=%0d active=%0b req=%0b resp_ready=%0b axis=%0b/%0b",
               total_reads, total_words, completed_chunks, flatten_active,
               pool5_read_request_valid, pool5_read_response_ready,
               compute_axis_tvalid, compute_axis_tready);
      if (hold_active && (!compute_axis_tvalid ||
          compute_axis_tdata != hold_data || compute_axis_tkeep != hold_keep ||
          compute_axis_tlast != hold_last))
        $fatal(1, "FC6 injected AXIS changed while backpressured");

      if (flatten_active && compute_axis_tvalid) begin
        chunk_words = current_count / 8;
        low_word_index = current_beat * 2;
        words_in_beat = low_word_index + 1 < chunk_words ? 2 : 1;
        expected_last = low_word_index + words_in_beat == chunk_words;
        if (compute_axis_tdata[63:0] !=
            expected_word(current_offset + low_word_index * 8) ||
            (words_in_beat == 2 && compute_axis_tdata[127:64] !=
             expected_word(current_offset + (low_word_index + 1) * 8)) ||
            compute_axis_tkeep !=
                (words_in_beat == 2 ? 16'hffff : 16'h00ff) ||
            compute_axis_tlast != expected_last)
          $fatal(1,
                 "FC6 injected AXIS mismatch offset=%0d beat=%0d keep=%h last=%0b",
                 current_offset, current_beat, compute_axis_tkeep,
                 compute_axis_tlast);
        if (compute_axis_tready) begin
          current_beat <= current_beat + 1;
          total_words <= total_words + words_in_beat;
        end
      end

      hold_active <= compute_axis_tvalid && !compute_axis_tready;
      if (compute_axis_tvalid && !compute_axis_tready) begin
        hold_data <= compute_axis_tdata;
        hold_keep <= compute_axis_tkeep;
        hold_last <= compute_axis_tlast;
      end
    end
  end

  task automatic serve_chunk(input int offset, input int count,
                             input int chunk_number);
    int flat_index;
    int channel;
    int spatial;
    int expected_address;
    begin
      current_offset = offset;
      current_count = count;
      current_beat = 0;
      active_layer_id = 6;
      active_k_offset = offset;
      active_k_count = count;
      request_destination = 0;
      request_word_count = count / 8;
      request_byte_count = count;
      request_m_count = 1;
      request_tag = 16'h6600 + chunk_number;
      request_valid = 1'b1;
      #1;
      while (!request_ready) @(negedge clk);
      if (external_request_valid)
        $fatal(1, "FC6 activation leaked to external DDR request");
      @(posedge clk);
      @(negedge clk);
      request_valid = 1'b0;

      for (int scalar = 0; scalar < count; scalar++) begin
        flat_index = offset + scalar;
        channel = flat_index / 36;
        spatial = flat_index % 36;
        expected_address = (channel / 8) * 36 + spatial;
        while (!pool5_read_request_valid) @(negedge clk);
        if (pool5_read_request_flat_index != flat_index ||
            pool5_read_request_word_address != expected_address ||
            pool5_read_request_lane != channel % 8 ||
            pool5_read_request_tag != 16'h6600 + chunk_number)
          $fatal(1, "FC6 injector Pool5 address mismatch k=%0d", flat_index);
        repeat (scalar % 3) @(negedge clk);
        pool5_read_request_ready = 1'b1;
        @(posedge clk);
        @(negedge clk);
        pool5_read_request_ready = 1'b0;
        repeat (scalar % 2) @(negedge clk);
        pool5_read_response_value = memory_value(flat_index);
        pool5_read_response_valid = 1'b1;
        while (!pool5_read_response_ready) @(negedge clk);
        @(posedge clk);
        @(negedge clk);
        pool5_read_response_valid = 1'b0;
        total_reads = total_reads + 1;
      end

      while (!flatten_done) @(negedge clk);
      @(negedge clk);
      if (flatten_active || fault ||
          current_beat != (count / 8 + 1) / 2)
        $fatal(1, "FC6 injector chunk did not drain offset=%0d", offset);
    end
  endtask

  task automatic pass_external_request(
      input int layer,
      input int destination,
      input int k_offset,
      input int k_count,
      input int words,
      input int m_count,
      input int tag);
    begin
      active_layer_id = layer;
      active_k_offset = k_offset;
      active_k_count = k_count;
      request_destination = destination;
      request_word_count = words;
      request_byte_count = words * 8;
      request_m_count = m_count;
      request_tag = tag;
      request_valid = 1'b1;
      external_request_ready = 1'b0;
      repeat (3) begin
        @(negedge clk);
        if (!external_request_valid || request_ready ||
            external_request_layer_id != layer ||
            external_request_k_offset != k_offset ||
            external_request_k_count != k_count ||
            external_request_destination != destination ||
            external_request_word_count != words ||
            external_request_byte_count != words * 8 ||
            external_request_m_count != m_count ||
            external_request_tag != tag)
          $fatal(1, "FC external request passthrough mismatch");
      end
      external_request_ready = 1'b1;
      @(posedge clk);
      @(negedge clk);
      request_valid = 1'b0;
      external_request_ready = 1'b0;
      passthrough_requests = passthrough_requests + 1;
    end
  endtask

  initial begin
    int offset;
    int count;
    int chunk_number;
    rst = 1'b1;
    request_valid = 0;
    active_layer_id = 0;
    active_k_offset = 0;
    active_k_count = 0;
    request_destination = 0;
    request_word_count = 0;
    request_byte_count = 0;
    request_m_count = 0;
    request_tag = 0;
    external_request_ready = 0;
    pool5_read_request_ready = 0;
    pool5_read_response_valid = 0;
    pool5_read_response_value = 0;
    pool5_read_response_error = 0;
    external_axis_tdata = 0;
    external_axis_tkeep = 0;
    external_axis_tvalid = 0;
    external_axis_tlast = 0;
    compute_axis_tready = 0;
    current_offset = 0;
    current_count = 0;
    current_beat = 0;
    total_reads = 0;
    total_words = 0;
    passthrough_requests = 0;
    watchdog_cycles = 0;
    hold_active = 0;
    repeat (6) @(negedge clk);
    rst = 0;
    repeat (2) @(negedge clk);

    offset = 0;
    chunk_number = 0;
    while (offset < TOTAL_K) begin
      count = TOTAL_K - offset > MAX_CHUNK ? MAX_CHUNK : TOTAL_K - offset;
      serve_chunk(offset, count, chunk_number);
      offset = offset + count;
      chunk_number = chunk_number + 1;
    end

    pass_external_request(6, 2, 0, 968, 968, 0, 16'h6a01);
    pass_external_request(7, 0, 0, 968, 121, 1, 16'h7a01);

    // With no flatten job active, external MM2S is a transparent stream.
    external_axis_tdata = 128'hfedcba9876543210_0123456789abcdef;
    external_axis_tkeep = 16'hffff;
    external_axis_tlast = 1'b1;
    external_axis_tvalid = 1'b1;
    while (!external_axis_tready) @(negedge clk);
    #1;
    if (!compute_axis_tvalid || compute_axis_tdata != external_axis_tdata ||
        compute_axis_tkeep != 16'hffff || !compute_axis_tlast)
      $fatal(1, "FC external AXIS passthrough mismatch");
    @(posedge clk);
    @(negedge clk);
    external_axis_tvalid = 1'b0;

    if (total_reads != 9216 || total_words != 1152 ||
        completed_chunks != 10 || completed_scalars != 9216 ||
        completed_words != 1152 || passthrough_requests != 2 || fault)
      $fatal(1,
             "FC6 injector aggregate mismatch reads=%0d words=%0d chunks=%0d scalars=%0d packed=%0d pass=%0d fault=%0b",
             total_reads, total_words, completed_chunks, completed_scalars,
             completed_words, passthrough_requests, fault);
    $display(
        "ALEXNET_FC6_FLATTEN_INJECTOR_TEST_PASSED scalars=9216 n8_words=1152 chunks=10 external_requests=2 axis_passthrough=1");
    $finish;
  end
endmodule
