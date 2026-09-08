`timescale 1ns/1ps
module tb_alexnet_fc_layer_controller;
  logic clk, rst;
  logic job_valid;
  logic job_ready;
  logic [3:0] job_layer_id;
  logic [2:0] job_m_count;
  logic [15:0] job_tag;
  logic parameter_request_valid;
  logic [3:0] active_layer_id;
  logic [2:0] active_m_count;
  logic [15:0] active_job_tag;
  logic [15:0] active_n_base;
  logic [13:0] active_k_offset;
  logic [9:0] active_k_count;
  logic parameter_valid;
  logic parameter_ready;
  logic [3:0] parameter_layer_id;
  logic [15:0] parameter_job_tag;
  logic [15:0] parameter_n_base;
  logic signed [31:0] parameter_bias [0:7];
  logic signed [17:0] parameter_multiplier [0:7];
  logic [5:0] parameter_right_shift [0:7];
  logic read_request_valid;
  logic read_request_ready;
  logic [1:0] read_request_destination;
  logic [9:0] read_request_word_count;
  logic [15:0] read_request_byte_count;
  logic [2:0] read_request_m_count;
  logic [15:0] read_request_tag;
  logic result_request_valid;
  logic result_request_ready;
  logic [1:0] result_request_destination;
  logic [15:0] result_request_byte_count;
  logic [15:0] result_request_tag;
  logic result_complete_valid;
  logic result_complete_ready;
  logic [15:0] result_complete_n_base;
  logic [15:0] result_complete_tag;
  logic result_complete_error;
  logic service_error;
  logic cfg_valid;
  logic cfg_ready;
  logic [1:0] cfg_destination;
  logic [15:0] cfg_n64_tile_base;
  logic [2:0] cfg_slice_index;
  logic [7:0] cfg_lane_mask;
  logic signed [31:0] cfg_bias [0:7];
  logic signed [17:0] cfg_multiplier [0:7];
  logic [5:0] cfg_right_shift [0:7];
  logic [7:0] cfg_relu;
  logic dma_descriptor_valid;
  logic dma_descriptor_ready;
  logic [1:0] dma_descriptor_destination;
  logic [9:0] dma_descriptor_word_count;
  logic [15:0] dma_descriptor_byte_count;
  logic [7:0] dma_descriptor_lane_mask;
  logic [15:0] dma_descriptor_tag;
  logic [9:0] dma_descriptor_k_count;
  logic [2:0] dma_descriptor_m_count;
  logic weight_release_valid;
  logic weight_release_ready;
  logic chunk_valid;
  logic chunk_ready;
  logic [9:0] chunk_k_count;
  logic [2:0] chunk_m_count;
  logic [7:0] chunk_n_lane_mask;
  logic [15:0] chunk_activation_tensor_tag;
  logic [15:0] chunk_weight_context_tag;
  logic [15:0] chunk_context_tag;
  logic [15:0] chunk_tile_tag;
  logic [7:0] chunk_index;
  logic chunk_first;
  logic chunk_final;
  logic core_fault;
  logic core_pipeline_idle;
  logic core_chunk_active;
  logic core_chunk_done;
  logic core_chunk_rejected;
  logic core_chunk_failed;
  logic core_transaction_active;
  logic core_transaction_done;
  logic core_dma_busy;
  logic core_dma_transfer_done;
  logic core_dma_descriptor_rejected;
  logic core_dma_transfer_failed;
  logic [1:0] core_weight_bank_state;
  logic [1:0] core_activation_bank_state;
  logic busy;
  logic layer_done;
  logic job_rejected;
  logic layer_failed;
  logic fault;
  logic [3:0] fault_code;
  logic [4:0] phase;
  logic [9:0] completed_n_tiles;
  logic [13:0] completed_chunks;
  logic [23:0] completed_k_tokens;
  logic [11:0] completed_output_words;
  alexnet_fc_layer_controller dut (.*);
  initial clk = 0;
  always #2.5 clk = ~clk;
  int configs = 0, dma_commands = 0, chunks = 0, result_requests = 0;
  int tokens = 0, clean_layers = 0, rejects = 0, failures = 0;
  int config_stalls = 0, read_stalls = 0, commit_wait_checks = 0;
  bit expect_fault = 0;
  logic [447:0] packed_cfg;
  for (genvar n = 0; n < 8; n++)
    assign packed_cfg[n*56 +: 56] = {cfg_bias[n], cfg_multiplier[n], cfg_right_shift[n]};
  wire [484:0] cfg_packet = {cfg_destination, cfg_n64_tile_base, cfg_slice_index,
      cfg_lane_mask, cfg_relu, packed_cfg};
  wire [117:0] read_packet = {active_layer_id, active_job_tag, active_n_base,
      active_k_offset, active_k_count, read_request_destination,
      read_request_word_count, read_request_byte_count, read_request_m_count,
      read_request_tag};
  logic cfg_stalled_q = 0, read_stalled_q = 0;
  logic [484:0] held_cfg;
  logic [117:0] held_read;
  always @(posedge clk) begin
    if (rst || fault) begin cfg_stalled_q <= 0; read_stalled_q <= 0; end
    else begin
      if (cfg_stalled_q && (!cfg_valid || cfg_packet !== held_cfg))
        $fatal(1, "configuration changed while stalled");
      if (read_stalled_q && (!read_request_valid || read_packet !== held_read))
        $fatal(1, "read request changed while stalled");
      cfg_stalled_q <= cfg_valid && !cfg_ready;
      read_stalled_q <= read_request_valid && !read_request_ready;
      held_cfg <= cfg_packet; held_read <= read_packet;
      if (cfg_valid && !cfg_ready) config_stalls++;
      if (read_request_valid && !read_request_ready) read_stalls++;
      if (cfg_valid && cfg_ready) configs++;
      if (dma_descriptor_valid && dma_descriptor_ready) dma_commands++;
      if (chunk_valid && chunk_ready) begin chunks++; tokens += chunk_k_count; end
      if (result_request_valid && result_request_ready) result_requests++;
    end
    if (!rst) begin
      if (fault && !expect_fault) $fatal(1, "unexpected controller fault %0d", fault_code);
      if (layer_done) clean_layers++;
      if (job_rejected) rejects++;
      if (layer_failed) failures++;
    end
  end
  initial begin #10000000; $fatal(1, "controller watchdog phase=%0d", phase); end

  task automatic tick(input int count = 1);
    repeat (count) @(negedge clk);
  endtask
  task automatic reset_dut;
    rst = 1;
    job_valid = 0;
    job_layer_id = 0;
    job_m_count = 0;
    job_tag = 0;
    parameter_valid = 0;
    parameter_layer_id = 0;
    parameter_job_tag = 0;
    parameter_n_base = 0;
    read_request_ready = 0;
    result_request_ready = 0;
    result_complete_valid = 0;
    result_complete_n_base = 0;
    result_complete_tag = 0;
    result_complete_error = 0;
    service_error = 0;
    cfg_ready = 0;
    dma_descriptor_ready = 0;
    weight_release_ready = 0;
    chunk_ready = 0;
    core_fault = 0;
    core_pipeline_idle = 0;
    core_chunk_active = 0;
    core_chunk_done = 0;
    core_chunk_rejected = 0;
    core_chunk_failed = 0;
    core_transaction_active = 0;
    core_transaction_done = 0;
    core_dma_busy = 0;
    core_dma_transfer_done = 0;
    core_dma_descriptor_rejected = 0;
    core_dma_transfer_failed = 0;
    core_weight_bank_state = 0;
    core_activation_bank_state = 0;
    core_pipeline_idle = 1;
    for (int n = 0; n < 8; n++) begin
      parameter_bias[n] = 0; parameter_multiplier[n] = 0; parameter_right_shift[n] = 0;
    end
    tick(5); rst = 0; expect_fault = 0; tick();
  endtask
  task automatic submit_job(input int id, input int m, input int tag);
    job_layer_id = id; job_m_count = m; job_tag = tag; job_valid = 1;
    while (!job_ready) tick();
    tick(); job_valid = 0;
    job_layer_id = 'x; job_m_count = 'x; job_tag = 'x;
  endtask
  task automatic supply_parameters(input int bad = 0);
    while (!parameter_request_valid) tick();
    tick(2);
    parameter_layer_id = active_layer_id;
    parameter_job_tag = active_job_tag;
    parameter_n_base = active_n_base;
    for (int n = 0; n < 8; n++) begin
      parameter_bias[n] = active_n_base + n - 2048;
      parameter_multiplier[n] = 65540 + n*7000;
      parameter_right_shift[n] = 23+n;
    end
    case (bad)
      1: parameter_layer_id ^= 1;
      2: parameter_job_tag ^= 1;
      3: parameter_n_base ^= 8;
      4: parameter_multiplier[2] = 65539;
      5: parameter_multiplier[3] = 131068;
      6: parameter_multiplier[4] = -1;
      7: parameter_right_shift[5] = 22;
      8: parameter_right_shift[6] = 33;
    endcase
    parameter_valid = 1; tick(); parameter_valid = 0;
    parameter_layer_id = 'x; parameter_job_tag = 'x; parameter_n_base = 'x;
    for (int n = 0; n < 8; n++) begin
      parameter_bias[n] = 'x; parameter_multiplier[n] = 'x; parameter_right_shift[n] = 'x;
    end
  endtask
  task automatic release_bank;
    while (!weight_release_valid) tick();
    tick(2); weight_release_ready = 1; tick(); weight_release_ready = 0;
    core_weight_bank_state = 0;
  endtask
  task automatic input_transfer(input int dest, input int nbase, input int koff,
      input int kcount, input int m, input int tag);
    int words;
    words = dest == 2 ? kcount : ((kcount+7)/8)*m;
    while (!read_request_valid) tick();
    if (active_n_base != nbase || active_k_offset != koff || active_k_count != kcount ||
        read_request_destination != dest || read_request_word_count != words ||
        read_request_byte_count != words*8 || read_request_m_count != (dest == 2 ? 0 : m) ||
        read_request_tag != 16'(tag)) $fatal(1, "read geometry/order mismatch");
    tick(2); read_request_ready = 1; tick(); read_request_ready = 0;
    while (!dma_descriptor_valid) tick();
    if (dma_descriptor_destination != dest || dma_descriptor_k_count != kcount ||
        dma_descriptor_word_count != words || dma_descriptor_byte_count != words*8 ||
        dma_descriptor_tag != 16'(tag) || dma_descriptor_lane_mask != 255 ||
        dma_descriptor_m_count != (dest == 2 ? 0 : m))
      $fatal(1, "DMA geometry/order mismatch");
    tick(2); dma_descriptor_ready = 1; tick(); dma_descriptor_ready = 0;
    core_dma_busy = 1; tick(3); core_dma_busy = 0;
    if (dest == 0) core_activation_bank_state = 2; else core_weight_bank_state = 2;
    core_dma_transfer_done = 1; tick(); core_dma_transfer_done = 0;
  endtask
  task automatic acknowledge_result(input int nbase, input int tag, input int bad = 0);
    result_complete_n_base = nbase;
    result_complete_tag = tag;
    result_complete_error = bad == 3;
    if (bad == 1) result_complete_n_base ^= 8;
    if (bad == 2) result_complete_tag ^= 1;
    result_complete_valid = 1;
    while (!result_complete_ready) tick();
    tick(); result_complete_valid = 0; result_complete_error = 0;
  endtask
  task automatic check_fault(input int code);
    while (!fault) tick();
    tick(3);
    if (fault_code != code) $fatal(1, "fault code mismatch %0d/%0d", fault_code, code);
    repeat (10) begin
      if (job_ready || cfg_valid || read_request_valid || dma_descriptor_valid ||
          chunk_valid || result_request_valid || layer_done || weight_release_valid)
        $fatal(1, "fault escaped quarantine");
      tick();
    end
  endtask

  task automatic run_layer(input int id, input int m, input int tag, input int bad_ack = 0);
    int full_k, full_n, jobs_chunks, nchunks, kcount, nbase, koff;
    bit final_chunk, early_ack;
    full_k = id == 6 ? 9216 : 4096; full_n = id == 8 ? 1000 : 4096;
    nchunks = (full_k+967)/968; jobs_chunks = 0;
    submit_job(id,m,tag);
    for (int ntile = 0; ntile < full_n/8; ntile++) begin
      nbase = ntile*8;
      supply_parameters();
      while (!cfg_valid) tick();
      if (cfg_n64_tile_base != (nbase/64)*64 || cfg_slice_index != ntile%8 ||
          cfg_lane_mask != 255 || cfg_destination != (id == 8 ? 2 : 0) ||
          cfg_relu != (id == 8 ? 0 : 255)) $fatal(1, "FC layer configuration mismatch");
      for (int n = 0; n < 8; n++)
        if (cfg_bias[n] !== nbase+n-2048 || cfg_multiplier[n] != 65540+n*7000 ||
            cfg_right_shift[n] != 23+n) $fatal(1, "parameter capture mismatch");
      tick(3); cfg_ready = 1; tick(); cfg_ready = 0;
      if (core_weight_bank_state == 2) release_bank();
      koff = 0;
      for (int kc = 0; kc < nchunks; kc++) begin
        kcount = full_k-koff > 968 ? 968 : full_k-koff;
        final_chunk = kc == nchunks-1;
        early_ack = final_chunk && (ntile%2 == 0) && bad_ack == 0;
        input_transfer(0,nbase,koff,kcount,m,tag+jobs_chunks);
        input_transfer(2,nbase,koff,kcount,m,tag+jobs_chunks);
        if (final_chunk) begin
          while (!result_request_valid) tick();
          if (active_n_base != nbase || result_request_byte_count != m*8 ||
              result_request_tag != 16'(tag+ntile) ||
              result_request_destination != (id == 8 ? 2 : 0))
            $fatal(1, "result request geometry mismatch");
          tick(3); result_request_ready = 1; tick(); result_request_ready = 0;
        end
        while (!chunk_valid) tick();
        if (chunk_k_count != kcount || chunk_m_count != m || chunk_n_lane_mask != 255 ||
            chunk_first != (kc == 0) || chunk_final != final_chunk || chunk_index != kc ||
            chunk_activation_tensor_tag != 16'(tag+jobs_chunks) ||
            chunk_weight_context_tag != 16'(tag+jobs_chunks) ||
            chunk_tile_tag != 16'(tag+ntile) || chunk_context_tag != 16'(tag+ntile))
          $fatal(1, "chunk geometry/context mismatch");
        tick(2); chunk_ready = 1; tick(); chunk_ready = 0;
        core_chunk_active = 1; core_pipeline_idle = 0; core_transaction_active = 1;
        if (early_ack) acknowledge_result(nbase,tag+ntile);
        tick(5);
        core_chunk_active = 0; core_activation_bank_state = 0;
        core_chunk_done = 1; tick(); core_chunk_done = 0;
        if (final_chunk) begin
          // Deliberately separate core chunk and transaction done pulses.
          tick(3); core_pipeline_idle = 1; core_transaction_active = 0;
          core_transaction_done = 1; tick(); core_transaction_done = 0;
        end
        release_bank();
        if (final_chunk && !early_ack) begin
          repeat (ntile == full_n/8-1 ? 50 : 12) begin
            tick(); commit_wait_checks++;
            if (!busy || job_ready || layer_done || parameter_request_valid ||
                read_request_valid || cfg_valid) $fatal(1, "advanced before external result commit");
          end
          acknowledge_result(nbase,tag+ntile,bad_ack);
          if (bad_ack) begin check_fault(4); return; end
        end
        jobs_chunks++; koff += kcount;
      end
    end
    while (!layer_done) tick();
    if (completed_n_tiles != full_n/8 || completed_chunks != (full_n/8)*nchunks ||
        completed_k_tokens != (full_n/8)*full_k || completed_output_words != (full_n/8)*m ||
        busy || !job_ready || core_weight_bank_state != 0)
      $fatal(1, "full layer counter/retirement mismatch");
    $display("FC_LAYER_GEOMETRY_PASS layer=%0d m=%0d tiles=%0d chunks=%0d k_tokens=%0d",
        id,m,completed_n_tiles,completed_chunks,completed_k_tokens);
    tick(2);
  endtask

  initial begin
    reset_dut();
    for (int mode = 0; mode < 6; mode++) begin
      submit_job(mode == 0 ? 5 : mode == 1 ? 9 : mode == 2 ? 15 : 8,
          mode < 3 ? 1 : mode == 3 ? 0 : mode == 4 ? 5 : 7, 0);
      while (!job_rejected) tick();
      if (fault || cfg_valid || read_request_valid || parameter_request_valid)
        $fatal(1, "invalid job had side effects");
      tick(2);
    end
    core_weight_bank_state = 2; // harmless stale weights are released.
    run_layer(6,4,16'hff00);
    run_layer(7,3,16'h1200);
    run_layer(8,1,16'h2400);
    run_layer(8,2,16'h3400);
    for (int mode = 1; mode <= 8; mode++) begin
      reset_dut(); expect_fault = 1; submit_job(8,1,16'h4000);
      supply_parameters(mode); check_fault(1);
    end
    for (int mode = 1; mode <= 3; mode++) begin
      reset_dut(); expect_fault = 1; run_layer(8,2,16'h5000,mode);
    end
    for (int mode = 0; mode < 3; mode++) begin
      reset_dut(); expect_fault = 1; submit_job(8,1,16'h6000);
      while (!parameter_request_valid) tick();
      if (mode == 0) service_error = 1;
      if (mode == 1) core_dma_descriptor_rejected = 1;
      if (mode == 2) core_chunk_failed = 1;
      tick();
      service_error = 0; core_dma_descriptor_rejected = 0; core_chunk_failed = 0;
      check_fault(mode == 0 ? 2 : 3);
    end
    reset_dut();
    if (clean_layers != 4 || rejects != 6 || failures != 14 ||
        config_stalls == 0 || read_stalls == 0 || commit_wait_checks == 0)
      $fatal(1, "controller coverage mismatch layers=%0d rejects=%0d failures=%0d",clean_layers,rejects,failures);
    $display("ALEXNET_FC_LAYER_CONTROLLER_TEST_PASSED layers=%0d rejects=%0d failures=%0d configs=%0d dma_commands=%0d chunks=%0d k_tokens=%0d results=%0d config_stalls=%0d read_stalls=%0d commit_wait_checks=%0d",
        clean_layers,rejects,failures,configs,dma_commands,chunks,tokens,result_requests,
        config_stalls,read_stalls,commit_wait_checks);
    $finish;
  end
endmodule
