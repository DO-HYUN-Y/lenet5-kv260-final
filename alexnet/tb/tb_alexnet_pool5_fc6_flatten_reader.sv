`timescale 1ns/1ps

module tb_alexnet_pool5_fc6_flatten_reader;
  localparam int TOTAL_K = 9216;
  localparam int MAX_CHUNK = 968;

  logic clk = 1'b0;
  always #2.5 clk = ~clk;
  logic rst = 1'b1;
  logic start_valid, start_ready;
  logic [13:0] start_k_offset;
  logic [9:0] start_k_count;
  logic [15:0] start_tag;
  logic read_request_valid, read_request_ready;
  logic [10:0] read_request_word_address;
  logic [2:0] read_request_lane;
  logic [13:0] read_request_flat_index;
  logic [15:0] read_request_tag;
  logic read_response_valid, read_response_ready;
  logic signed [7:0] read_response_value;
  logic read_response_error;
  logic m_valid, m_ready;
  logic [63:0] m_values;
  logic [7:0] m_lane_mask;
  logic [13:0] m_k_base;
  logic [15:0] m_tag;
  logic m_last, busy, done, fault;
  logic [13:0] scalars_completed;
  logic [9:0] words_completed;

  int current_offset;
  int current_count;
  int current_output_word;
  int total_reads;
  int total_output_words;
  int completed_jobs;
  int cycles;
  logic held_valid;
  logic [63:0] held_values;
  logic [7:0] held_mask;
  logic [13:0] held_k_base;
  logic held_last;

  alexnet_pool5_fc6_flatten_reader dut (.*);

  always @(negedge clk) begin
    if (rst)
      m_ready <= 1'b0;
    else
      m_ready <= $urandom_range(0, 4) != 0;
  end

  always @(posedge clk) begin
    int flat_index;
    int channel;
    int spatial;
    logic [7:0] expected_value;
    if (rst) begin
      current_output_word <= 0;
      total_output_words <= 0;
      completed_jobs <= 0;
      cycles <= 0;
      held_valid <= 0;
    end else begin
      cycles <= cycles + 1;
      if (cycles > 100000)
        $fatal(1, "Pool5 flatten watchdog reads=%0d outputs=%0d",
               total_reads, total_output_words);
      if (held_valid &&
          (!m_valid || m_values != held_values || m_lane_mask != held_mask ||
           m_k_base != held_k_base || m_last != held_last))
        $fatal(1, "Pool5 flatten output changed under backpressure");
      if (m_valid) begin
        if (m_lane_mask != 8'hff ||
            m_k_base != current_offset + current_output_word * 8 ||
            m_tag != 16'h7000 + completed_jobs ||
            m_last !=
                (current_output_word + 1 == current_count / 8))
          $fatal(1,
                 "Pool5 flatten output metadata mismatch word=%0d mask=%h k=%0d/%0d tag=%h/%h last=%0b/%0b",
                 current_output_word, m_lane_mask, m_k_base,
                 current_offset + current_output_word * 8, m_tag,
                 16'(16'h7000 + completed_jobs), m_last,
                 current_output_word + 1 == current_count / 8);
        for (int lane = 0; lane < 8; lane++) begin
          flat_index = m_k_base + lane;
          channel = flat_index / 36;
          spatial = flat_index % 36;
          expected_value = 8'((channel + spatial) & 8'hff);
          if (m_values[lane*8 +: 8] != expected_value)
            $fatal(1,
                   "Pool5 flatten value mismatch k=%0d lane=%0d got=%0h expected=%0h",
                   flat_index, lane, m_values[lane*8 +: 8],
                   expected_value);
        end
        if (m_ready) begin
          current_output_word <= current_output_word + 1;
          total_output_words <= total_output_words + 1;
        end
      end
      if (done)
        completed_jobs <= completed_jobs + 1;
      held_valid <= m_valid && !m_ready;
      if (m_valid && !m_ready) begin
        held_values <= m_values;
        held_mask <= m_lane_mask;
        held_k_base <= m_k_base;
        held_last <= m_last;
      end
    end
  end

  task automatic serve_one_chunk(input int offset, input int count,
                                 input int job_number);
    int expected_flat;
    int channel;
    int spatial;
    int expected_address;
    begin
      current_offset = offset;
      current_count = count;
      current_output_word = 0;
      start_k_offset = offset;
      start_k_count = count;
      start_tag = 16'h7000 + job_number;
      start_valid = 1'b1;
      while (!start_ready) @(negedge clk);
      @(posedge clk);
      @(negedge clk);
      start_valid = 1'b0;

      for (int scalar = 0; scalar < count; scalar++) begin
        expected_flat = offset + scalar;
        channel = expected_flat / 36;
        spatial = expected_flat % 36;
        expected_address = (channel / 8) * 36 + spatial;
        while (!read_request_valid) @(negedge clk);
        if (read_request_flat_index != expected_flat ||
            read_request_word_address != expected_address ||
            read_request_lane != channel % 8 ||
            read_request_tag != 16'h7000 + job_number)
          $fatal(1,
                 "Pool5 flatten read mapping mismatch k=%0d addr=%0d/%0d lane=%0d/%0d",
                 expected_flat, read_request_word_address, expected_address,
                 read_request_lane, channel % 8);
        repeat ($urandom_range(0, 2)) @(negedge clk);
        read_request_ready = 1'b1;
        @(posedge clk);
        @(negedge clk);
        read_request_ready = 1'b0;
        repeat ($urandom_range(0, 2)) @(negedge clk);
        read_response_value = 8'((channel + spatial) & 8'hff);
        read_response_valid = 1'b1;
        while (!read_response_ready) @(negedge clk);
        @(posedge clk);
        @(negedge clk);
        read_response_valid = 1'b0;
        total_reads = total_reads + 1;
      end

      while (!done) @(negedge clk);
      @(negedge clk);
      if (scalars_completed != count || words_completed != count / 8 ||
          current_output_word != count / 8 || fault || busy)
        $fatal(1,
               "Pool5 flatten chunk retirement mismatch offset=%0d count=%0d scalars=%0d words=%0d/%0d",
               offset, count, scalars_completed, words_completed,
               current_output_word);
    end
  endtask

  initial begin
    int offset;
    int count;
    int job_number;
    start_valid = 0;
    start_k_offset = 0;
    start_k_count = 0;
    start_tag = 0;
    read_request_ready = 0;
    read_response_valid = 0;
    read_response_value = 0;
    read_response_error = 0;
    m_ready = 0;
    current_offset = 0;
    current_count = 0;
    current_output_word = 0;
    total_reads = 0;
    total_output_words = 0;
    completed_jobs = 0;

    repeat (6) @(negedge clk);
    rst = 0;
    repeat (2) @(negedge clk);
    offset = 0;
    job_number = 0;
    while (offset < TOTAL_K) begin
      count = TOTAL_K - offset > MAX_CHUNK ? MAX_CHUNK : TOTAL_K - offset;
      serve_one_chunk(offset, count, job_number);
      offset = offset + count;
      job_number = job_number + 1;
    end

    if (total_reads != TOTAL_K || total_output_words != TOTAL_K / 8 ||
        completed_jobs != 10 || fault)
      $fatal(1,
             "Pool5 flatten full FC6 mismatch reads=%0d words=%0d jobs=%0d fault=%0b",
             total_reads, total_output_words, completed_jobs, fault);
    $display("ALEXNET_POOL5_FC6_FLATTEN_TEST_PASSED scalars=%0d n8_words=%0d chunks=%0d",
             total_reads, total_output_words, completed_jobs);
    $finish;
  end
endmodule
