`timescale 1ns/1ps
module tb_alexnet_m4n8_fc_activation_resident_weight_accum_datapath;
  import "DPI-C" function int alexnet_golden_requantize(
      input int accumulator, input int bias, input int multiplier,
      input byte right_shift, input byte relu, output byte result);
  logic clk = 0;
  logic rst = 1;
  logic ce;
  logic cfg_valid = 0, cfg_ready;
  logic [1:0] cfg_destination;
  logic [15:0] cfg_n64_tile_base;
  logic [7:0] cfg_lane_mask;
  logic signed [31:0] cfg_bias [0:7];
  logic signed [17:0] cfg_multiplier [0:7];
  logic [5:0] cfg_right_shift [0:7];
  logic [7:0] cfg_relu;
  logic weight_fill_valid = 0, weight_fill_ready;
  logic [9:0] weight_fill_k_count;
  logic [7:0] weight_fill_n_lane_mask;
  logic [15:0] weight_fill_context_tag;
  logic weight_write_valid = 0, weight_write_ready;
  logic [63:0] weight_write_values;
  logic [7:0] weight_write_n_lane_mask;
  logic weight_write_last;
  logic weight_release_valid = 0, weight_release_ready;
  logic chunk_valid = 0, chunk_ready;
  logic [9:0] chunk_k_count;
  logic [2:0] chunk_m_count;
  logic [7:0] chunk_n_lane_mask;
  logic [15:0] chunk_activation_tensor_tag, chunk_weight_context_tag;
  logic [15:0] chunk_context_tag, chunk_tile_tag;
  logic [7:0] chunk_index;
  logic chunk_first, chunk_final;
  logic activation_fill_valid = 0, activation_fill_ready;
  logic [9:0] activation_fill_k_count;
  logic [2:0] activation_fill_m_count;
  logic [15:0] activation_fill_tensor_tag;
  logic activation_write_valid = 0, activation_write_ready;
  logic [63:0] activation_write_values;
  logic [7:0] activation_write_lane_mask;
  logic activation_write_last;
  logic [15:0] activation_write_tensor_tag;
  logic activation_fill_active, activation_fill_done, activation_fill_rejected;
  logic activation_fill_failed, activation_read_active, activation_read_done;
  logic [1:0] activation_bank_state;
  logic [9:0] activation_word_count, activation_words_forwarded;
  logic [15:0] accepted_activation_fills, completed_activation_fills;
  logic [15:0] rejected_activation_fills, failed_activation_fills;
  logic egress_valid, egress_ready;
  logic [63:0] egress_values;
  logic [7:0] egress_lane_mask;
  logic [1:0] egress_destination;
  logic [2:0] egress_slice;
  logic [4:0] egress_m;
  logic [15:0] egress_n_base, egress_tile_tag;
  logic configured, chunk_active, chunk_done, chunk_rejected, chunk_failed;
  logic transaction_active, transaction_done, compute_busy, pipeline_idle, fault;
  logic [1:0] phase, weight_bank_state;
  logic [2:0] accum_bank_state;
  logic [15:0] completed_replays, accepted_chunks, completed_chunks;
  logic [15:0] rejected_chunks, failed_chunks;
  logic [31:0] completed_k_tokens;
  logic [6:0] queued_count;
  bit block_output = 0, expect_fault = 0, allow_final = 0, wide_partial_seen = 0;
  int seed = 32'h46434142;
  int seed_init;
  int sum [0:3][0:7], partial [0:3][0:7];
  logic [63:0] expected [0:3];
  int scan_m = 0, emit_m = 0, output_m = 0, active_m = 0;
  int n_mask, tile_id, destination, n_base;
  int total_chunks = 0, total_done = 0, total_rejects = 0, total_failed = 0;
  int total_transactions = 0, total_replays = 0, total_k = 0;
  int total_activation = 0, total_weights = 0, total_outputs = 0;
  int stall_cycles = 0, ce_stalls = 0, owner_checks = 0, maxq = 0;
  int scanned_words = 0, emitted_words = 0, config_count = 0;
  int total_fills = 0, total_fill_done = 0, total_fill_rejects = 0, total_fill_failed = 0;
  int read_starts = 0, read_completes = 0, read_words = 0, read_tail_words = 0;
  int max_activation_words = 0, active_offset = 0, read_stall_cycles = 0;
  bit read_stalled_q = 0, injecting_read_error = 0;
  logic [98:0] read_packet_q;
  wire [98:0] read_packet = {dut.bank_read_values, dut.bank_read_mask,
      dut.bank_read_index, dut.bank_read_tag, dut.bank_read_last};
  logic [63:0] expected_read_word;
  int read_pos_m, read_block_k, read_count_k, expected_read_mask;
  logic stalled_q = 0;
  logic [113:0] packet_q;
  wire [113:0] packet = {egress_values, egress_lane_mask, egress_destination,
      egress_slice, egress_m, egress_n_base, egress_tile_tag};

  alexnet_m4n8_fc_activation_resident_weight_accum_datapath #(.SLICE_INDEX(1)) dut (
      .shared_cfg_valid(),
      .shared_cfg_ready('0),
      .shared_cfg_destination(),
      .shared_cfg_n64_tile_base(),
      .shared_cfg_slice_index(),
      .shared_cfg_lane_mask(),
      .shared_cfg_bias(),
      .shared_cfg_multiplier(),
      .shared_cfg_right_shift(),
      .shared_cfg_relu(),
      .shared_chunk_valid(),
      .shared_chunk_ready('0),
      .shared_chunk_word_count(),
      .shared_chunk_output_width(),
      .shared_chunk_n_lane_mask(),
      .shared_chunk_context_tag(),
      .shared_chunk_tile_tag_base(),
      .shared_chunk_index(),
      .shared_chunk_first(),
      .shared_chunk_final(),
      .shared_tile_start_valid(),
      .shared_tile_start_ready('0),
      .shared_tile_m_count(),
      .shared_tile_n_lane_mask(),
      .shared_tile_tag(),
      .shared_issue_valid(),
      .shared_issue_ready('0),
      .shared_issue_last(),
      .shared_issue_act_lo(),
      .shared_issue_act_hi(),
      .shared_issue_weight(),
      .shared_egress_valid('0),
      .shared_egress_ready(),
      .shared_egress_values('0),
      .shared_egress_lane_mask('0),
      .shared_egress_destination('0),
      .shared_egress_slice('0),
      .shared_egress_m('0),
      .shared_egress_n_base('0),
      .shared_egress_tile_tag('0),
      .shared_configured('0),
      .shared_compute_busy('0),
      .shared_transaction_active('0),
      .shared_chunk_active('0),
      .shared_tile_done('0),
      .shared_chunk_done('0),
      .shared_transaction_done('0),
      .shared_datapath_idle('0),
      .shared_accum_bank_state('0),
      .shared_accum_context_error('0),
      .shared_protocol_error('0),
      .shared_queued_count('0),
.cfg_slice_index(3'bxxx), .*);
  always #2.5 clk = ~clk;
  always @(negedge clk) begin
    ce <= !rst && ($urandom_range(0, 4) != 0);
    egress_ready <= !rst && !block_output && ($urandom_range(0, 3) != 0);
  end
  initial begin
    #5000000;
    $fatal(1, "FC integration watchdog phase=%0d issuer=%0d bank=%0d accum=%0d",
        phase, dut.u_core.u_issuer.phase, weight_bank_state, accum_bank_state);
  end

  // Independent dense dot-product, indexed by global flattened K (not the
  // issuer's counters). Corner lanes exceed signed-27 midway through FC6,
  // then cancel back into the frozen signed-27 post-bias requant range.
  // Every individual <=968-token PE chunk remains in range.
  function automatic int act(input int k, input int m);
    if (m == 0) return k < 4608 ? 127 : -127;
    return ((k * 37 + m * 53 + (k / 11) * 19) % 256) - 128;
  endfunction
  function automatic int weight(input int k, input int n);
    if (n == 0) return 127;
    if (n == 1) return -128;
    return ((k * 29 + n * 47 + (k / 7) * 13) % 256) - 128;
  endfunction

  always @(posedge clk) begin : scoreboard
    if (rst) begin
      stalled_q <= 0;
      read_stalled_q <= 0;
    end
    else begin
      if (fault && !expect_fault) $fatal(1, "unexpected FC fault");
      if (cfg_valid && cfg_ready) config_count++;
      if (chunk_valid && chunk_ready) total_chunks++;
      if (chunk_valid && chunk_ready && weight_release_ready)
        $fatal(1, "simultaneous release stole accepted descriptor weights");
      if (chunk_done) total_done++;
      if (chunk_failed) total_failed++;
      if (chunk_rejected) total_rejects++;
      if (transaction_done) begin
        total_transactions++;
        if (output_m != active_m || !pipeline_idle)
          $fatal(1, "transaction completed before all output transfers");
      end
      if (dut.u_core.replay_valid && dut.u_core.replay_ready) total_replays++;
      if (dut.u_core.issue_valid && dut.u_core.issue_ready) total_k++;
      if (dut.u_core.issue_valid && !ce) ce_stalls++;
      if (activation_fill_valid && activation_fill_ready) total_fills++;
      if (activation_fill_done) total_fill_done++;
      if (activation_fill_rejected) total_fill_rejects++;
      if (activation_fill_failed) total_fill_failed++;
      if (activation_write_valid && activation_write_ready) total_activation++;
      if (dut.bank_read_start) read_starts++;
      if (activation_read_done) read_completes++;
      if (activation_word_count > max_activation_words) max_activation_words = activation_word_count;
      if (read_stalled_q && (!dut.bank_read_valid || read_packet !== read_packet_q))
        $fatal(1, "activation bank read changed under backpressure");
      read_stalled_q <= dut.bank_read_valid && !dut.bank_read_ready;
      read_packet_q <= read_packet;
      if (dut.bank_read_valid && !dut.bank_read_ready) read_stall_cycles++;
      if (dut.bank_read_valid && dut.bank_read_ready) begin
        read_pos_m = dut.bank_read_index % active_m;
        read_block_k = (dut.bank_read_index / active_m) * 8;
        expected_read_word = 0;
        expected_read_mask = 0;
        for (int lane = 0; lane < 8; lane++) begin
          if (read_block_k + lane < read_count_k) begin
            expected_read_word[lane*8 +: 8] = 8'(act(active_offset+read_block_k+lane, read_pos_m));
            expected_read_mask |= 1 << lane;
          end
        end
        if (dut.bank_read_values !== expected_read_word ||
            dut.read_k_mask != expected_read_mask || dut.bank_read_mask != 255 ||
            dut.bank_read_tag != (injecting_read_error ? 16'hfffe : activation_fill_tensor_tag) ||
            dut.bank_read_last != (dut.bank_read_index == ((read_count_k+7)/8)*active_m-1))
          $fatal(1, "FC stored activation mismatch index=%0d", dut.bank_read_index);
        if (expected_read_mask != 255) read_tail_words++;
        read_words++;
      end
      if (weight_write_valid && weight_write_ready) total_weights++;
      if (chunk_active && (weight_release_valid || weight_fill_valid || activation_fill_valid)) begin
        owner_checks++;
        if (weight_release_ready || weight_fill_ready || activation_fill_ready)
          $fatal(1, "weight owner escaped an active descriptor");
      end
      if (queued_count > maxq) maxq = queued_count;
      if (dut.u_core.g_local.u_base.u_output_slice.scanner_valid &&
          dut.u_core.g_local.u_base.u_output_slice.scanner_ready) begin
        if (scan_m >= active_m) $fatal(1, "extra partial-sum word");
        for (int n = 0; n < 8; n++)
          if (n_mask & (1 << n))
            if (dut.u_core.g_local.u_base.u_output_slice.scanner_accumulator[n] !== partial[scan_m][n])
              $fatal(1, "chunk dot mismatch m=%0d n=%0d got=%0d expected=%0d",
                  scan_m, n, dut.u_core.g_local.u_base.u_output_slice.scanner_accumulator[n], partial[scan_m][n]);
        scan_m++;
        scanned_words++;
      end
      if (dut.u_core.g_local.u_base.u_output_slice.bank_egress_valid &&
          dut.u_core.g_local.u_base.u_output_slice.bank_egress_ready) begin
        if (!allow_final || emit_m >= active_m)
          $fatal(1, "nonfinal/extra accumulated output");
        for (int n = 0; n < 8; n++)
          if (dut.u_core.g_local.u_base.u_output_slice.bank_egress_accumulator[n] !==
              ((n_mask & (1 << n)) ? sum[emit_m][n] : 0))
            $fatal(1, "INT32 cross-chunk mismatch m=%0d n=%0d", emit_m, n);
        emit_m++;
        emitted_words++;
      end
      if (stalled_q && (!egress_valid || packet !== packet_q))
        $fatal(1, "FC output changed under backpressure");
      stalled_q <= egress_valid && !egress_ready;
      packet_q <= packet;
      if (egress_valid && !allow_final) $fatal(1, "nonfinal INT8 output");
      if (egress_valid && !egress_ready) stall_cycles++;
      if (egress_valid && egress_ready) begin
        if (output_m >= active_m || egress_values !== expected[output_m] ||
            egress_m != output_m || egress_lane_mask != n_mask ||
            egress_tile_tag != tile_id || egress_destination != destination ||
            egress_slice != 1 || egress_n_base != n_base + 8)
          $fatal(1, "final packet mismatch m=%0d got=%h expected=%h",
              output_m, egress_values, expected[output_m]);
        output_m++;
        total_outputs++;
      end
    end
  end

  task automatic configure(input int mask, input int id);
    @(negedge clk);
    cfg_lane_mask = mask;
    cfg_destination = id % 3;
    cfg_n64_tile_base = id * 64;
    cfg_relu = 8'h28;
    for (int n = 0; n < 8; n++) begin
      cfg_bias[n] = (n - 4) * 8193;
      cfg_multiplier[n] = 65540 + n * 7000;
      cfg_right_shift[n] = 23 + n;
    end
    cfg_valid = 1;
    do @(posedge clk); while (!cfg_ready);
    @(negedge clk);
    cfg_valid = 0;
    destination = cfg_destination;
    n_base = cfg_n64_tile_base;
  endtask

  task automatic release_weights;
    @(negedge clk);
    weight_release_valid = 1;
    do @(posedge clk); while (!weight_release_ready);
    @(negedge clk);
    weight_release_valid = 0;
    if (weight_bank_state != 0) $fatal(1, "release did not empty weight bank");
  endtask

  task automatic load_weights(input int offset, input int k_count, input int tag);
    if (weight_bank_state == 2) release_weights();
    @(negedge clk);
    weight_fill_k_count = k_count;
    weight_fill_n_lane_mask = n_mask;
    weight_fill_context_tag = tag;
    weight_fill_valid = 1;
    do @(posedge clk); while (!weight_fill_ready);
    @(negedge clk);
    weight_fill_valid = 0;
    for (int k = 0; k < k_count; k++) begin
      repeat ($urandom_range(0, 1)) @(negedge clk);
      for (int n = 0; n < 8; n++) weight_write_values[n*8 +: 8] = 8'(weight(offset+k, n));
      weight_write_n_lane_mask = n_mask;
      weight_write_last = k == k_count - 1;
      weight_write_valid = 1;
      do @(posedge clk); while (!weight_write_ready);
      @(negedge clk);
      weight_write_valid = 0;
    end
  endtask

  task automatic send_descriptor;
    @(negedge clk);
    chunk_valid = 1;
    weight_release_valid = 1;
    do @(posedge clk); while (!chunk_ready);
    @(negedge clk);
    chunk_valid = 0;
    weight_release_valid = 0;
  endtask

  task automatic reject_descriptor;
    int before_replays, before_k, before_reads;
    before_replays = total_replays;
    before_k = total_k;
    before_reads = read_starts;
    send_descriptor();
    while (!chunk_rejected) @(negedge clk);
    if (fault || activation_bank_state != 2 || read_starts != before_reads ||
        total_replays != before_replays || total_k != before_k)
      $fatal(1, "rejected descriptor changed a child owner");
    @(negedge clk);
  endtask


  task automatic send_fill_descriptor;
    @(negedge clk);
    activation_fill_valid = 1;
    do @(posedge clk); while (!activation_fill_ready);
    @(negedge clk);
    activation_fill_valid = 0;
  endtask

  task automatic reject_fill(input int k_count, input int m_count);
    activation_fill_k_count = k_count;
    activation_fill_m_count = m_count;
    activation_fill_tensor_tag = 16'h900;
    send_fill_descriptor();
    while (!activation_fill_rejected) @(negedge clk);
    if (fault || activation_bank_state != 0 || activation_write_ready)
      $fatal(1, "invalid activation fill changed bank ownership");
    @(negedge clk);
  endtask

  // Fixed-mask physical words, including explicit zero K padding. Corruption
  // cases still send the exact declared count so the bounded drain can finish.
  task automatic load_activations(input int offset, input int k_count, input int error_mode);
    activation_fill_k_count = k_count;
    activation_fill_m_count = active_m;
    activation_fill_tensor_tag = chunk_activation_tensor_tag;
    active_offset = offset;
    read_count_k = k_count;
    send_fill_descriptor();
    for (int block_k = 0; block_k < k_count; block_k += 8) begin
      for (int m = 0; m < active_m; m++) begin
        repeat ($urandom_range(0, 2)) @(negedge clk);
        activation_write_values = '0;
        activation_write_lane_mask = 255;
        for (int lane = 0; lane < 8; lane++)
          if (block_k + lane < k_count)
            activation_write_values[lane*8 +: 8] = 8'(act(offset+block_k+lane, m));
        activation_write_tensor_tag = chunk_activation_tensor_tag;
        activation_write_last = block_k + 8 >= k_count && m == active_m - 1;
        if (block_k == 0 && m == 0) begin
          if (error_mode == 1) activation_write_tensor_tag ^= 16'h1;
          if (error_mode == 2) activation_write_lane_mask = 8'h7f;
          if (error_mode == 3) activation_write_last = 1;
        end
        if (error_mode == 4 && block_k + 8 >= k_count && m == active_m - 1)
          activation_write_last = 0;
        if (block_k + 8 > k_count &&
            ((error_mode == 5 && m == 0) || (error_mode == 6 && m == active_m - 1)))
          activation_write_values[63:56] = 8'h7e;
        activation_write_valid = 1;
        do @(posedge clk); while (!activation_write_ready);
        @(negedge clk);
        activation_write_valid = 0;
      end
    end
    if (activation_fill_failed != (error_mode != 0) ||
        activation_fill_done != (error_mode == 0) || activation_bank_state != 2)
      $fatal(1, "activation fill retirement mismatch mode=%0d", error_mode);
    @(negedge clk);
  endtask

  task automatic reset_dut;
    @(negedge clk);
    rst = 1;
    repeat (5) @(negedge clk);
    rst = 0;
    @(negedge clk);
  endtask

  task automatic check_bad_fill(input int error_mode);
    int before_reads, before_k, before_outputs;
    before_reads = read_starts;
    before_k = total_k;
    before_outputs = total_outputs;
    expect_fault = 1;
    active_m = 3;
    chunk_activation_tensor_tag = 16'h900 + error_mode;
    load_activations(0, 10, error_mode);
    // Offer all new owners after a poison; none may accept.
    chunk_valid = 1;
    activation_fill_valid = 1;
    cfg_valid = 1;
    weight_fill_valid = 1;
    weight_release_valid = 1;
    repeat (8) begin
      @(negedge clk);
      if (!fault || activation_fill_ready || activation_write_ready || chunk_ready ||
          cfg_ready || weight_fill_ready || weight_release_ready || activation_read_active ||
          chunk_done || transaction_done || egress_valid)
        $fatal(1, "malformed activation fill escaped quarantine mode=%0d", error_mode);
    end
    chunk_valid = 0;
    activation_fill_valid = 0;
    cfg_valid = 0;
    weight_fill_valid = 0;
    weight_release_valid = 0;
    if (read_starts != before_reads || total_k != before_k || total_outputs != before_outputs)
      $fatal(1, "malformed activation reached compute");
    reset_dut();
    expect_fault = 0;
  endtask

  task automatic run_transaction(input int full_k, input int m_count,
      input int mask, input int id, input bit check_rejects, input bit bad_tag);
    int count_k, chunk_no, offset;
    byte result;
    configure(mask, id);
    n_mask = mask;
    active_m = m_count;
    tile_id = id * 257;
    output_m = 0;
    emit_m = 0;
    allow_final = 0;
    for (int m = 0; m < 4; m++)
      for (int n = 0; n < 8; n++) sum[m][n] = 0;
    offset = 0;
    chunk_no = 0;
    while (offset < full_k) begin
      // Small test deliberately splits on a non-N8-aligned K boundary.
      count_k = full_k == 17 ? ((offset == 0) ? 10 : 7) :
          ((full_k - offset > 968) ? 968 : full_k - offset);
      load_weights(offset, count_k, id * 32 + chunk_no);
      chunk_k_count = count_k;
      chunk_m_count = m_count;
      chunk_n_lane_mask = mask;
      chunk_activation_tensor_tag = id * 64 + chunk_no;
      chunk_weight_context_tag = id * 32 + chunk_no;
      chunk_context_tag = id * 17;
      chunk_tile_tag = tile_id;
      chunk_index = chunk_no;
      chunk_first = chunk_no == 0;
      chunk_final = offset + count_k == full_k;
      load_activations(offset, count_k, 0);
      if (check_rejects && chunk_no == 0) begin
        chunk_activation_tensor_tag++; reject_descriptor(); chunk_activation_tensor_tag--;
        chunk_k_count = count_k - 1; reject_descriptor(); chunk_k_count = count_k;
        chunk_m_count = 3; reject_descriptor(); chunk_m_count = m_count;
        chunk_k_count = 0; reject_descriptor();
        chunk_k_count = 969; reject_descriptor();
        chunk_k_count = count_k;
        chunk_m_count = 0; reject_descriptor();
        chunk_m_count = 5; reject_descriptor();
        chunk_m_count = m_count;
        chunk_n_lane_mask = 0; reject_descriptor();
        chunk_n_lane_mask = 8'h55; reject_descriptor();
        chunk_n_lane_mask = 8'h7f; reject_descriptor();
        chunk_n_lane_mask = mask;
        chunk_weight_context_tag++; reject_descriptor(); chunk_weight_context_tag--;
        chunk_index = 1; reject_descriptor(); chunk_index = 0;
        chunk_first = 0; reject_descriptor(); chunk_first = 1;
      end
      if (check_rejects && chunk_no == 1) begin
        chunk_first = 1; reject_descriptor(); chunk_first = 0;
        chunk_index++; reject_descriptor(); chunk_index--;
        chunk_m_count = 3; reject_descriptor(); chunk_m_count = m_count;
        chunk_context_tag++; reject_descriptor(); chunk_context_tag--;
        chunk_tile_tag++; reject_descriptor(); chunk_tile_tag--;
        // Hold a different future configuration through this continuation.
        cfg_lane_mask = 8'h01;
        cfg_valid = 1;
      end
      scan_m = 0;
      for (int m = 0; m < 4; m++) begin
        expected[m] = 0;
        for (int n = 0; n < 8; n++) begin
          partial[m][n] = 0;
          if (m < m_count && (mask & (1 << n))) begin
            for (int k = 0; k < count_k; k++)
              partial[m][n] += act(offset+k, m) * weight(offset+k, n);
            sum[m][n] += partial[m][n];
            if (sum[m][n] > 67108863 || sum[m][n] < -67108864)
              wide_partial_seen = 1;
            if (alexnet_golden_requantize(sum[m][n], cfg_bias[n], cfg_multiplier[n],
                cfg_right_shift[n], cfg_relu[n], result) != 0)
              $fatal(1, "requant oracle failed");
            expected[m][n*8 +: 8] = result;
          end
        end
      end
      allow_final = chunk_final;
      block_output = chunk_final;
      send_descriptor();
      if (bad_tag) begin
        // Inject before read_start, so even stalled valid metadata stays
        // stable. This exercises both the wrapper and inner error paths.
        injecting_read_error = 1;
        force dut.bank_read_tag = 16'hfffe;
      end
      // Attempt owner changes both before replay and after the last K beat.
      weight_release_valid = 1;
      weight_fill_valid = 1;
      activation_fill_valid = 1;
      if (chunk_final) begin
        while (!egress_valid) @(negedge clk);
        repeat (40) begin
          @(negedge clk);
          if (chunk_done || chunk_failed || transaction_done || !chunk_active)
            $fatal(1, "FC retired while final output was stalled");
        end
        weight_release_valid = 0;
        weight_fill_valid = 0;
        block_output = 0;
      end else begin
        // Retract probe requests before the next owner boundary.
        while (dut.completed_k_tokens == 0 || dut.u_core.u_issuer.phase != 6)
          @(negedge clk);
        weight_release_valid = 0;
        weight_fill_valid = 0;
      end
      while (!(chunk_done || chunk_failed)) @(negedge clk);
      activation_fill_valid = 0;
      if (bad_tag) begin
        release dut.bank_read_tag;
        injecting_read_error = 0;
      end
      if (activation_bank_state != 0 || activation_words_forwarded != ((count_k+7)/8)*m_count)
        $fatal(1, "FC activation ownership/count did not retire");
      if (scan_m != m_count || (chunk_failed != bad_tag))
        $fatal(1, "incorrect FC chunk retirement");
      if (!chunk_final && (!transaction_active || egress_valid || pipeline_idle))
        $fatal(1, "nonfinal transaction ownership lost");
      if (check_rejects && chunk_no == 1) begin
        if (cfg_ready || config_count != 1) $fatal(1, "pending config was accepted early");
        cfg_valid = 0;
        cfg_lane_mask = mask;
      end
      @(negedge clk);
      if (bad_tag && !chunk_final) begin
        if (!fault || !transaction_active || pipeline_idle || egress_valid ||
            chunk_ready || cfg_ready || weight_release_ready)
          $fatal(1, "poisoned nonfinal transaction was not quarantined");
        return;
      end
      offset += count_k;
      chunk_no++;
    end
    if (output_m != m_count || emit_m != m_count || !pipeline_idle)
      $fatal(1, "final transaction did not fully drain");
  endtask

  initial begin
    seed_init = $urandom(seed);
    repeat (8) @(negedge clk);
    rst = 0;
    reject_fill(0, 4);
    reject_fill(969, 4);
    reject_fill(8, 0);
    reject_fill(8, 5);
    run_transaction(9216, 4, 255, 1, 1, 0);
    if (!wide_partial_seen) $fatal(1, "missing cross-chunk INT32 range coverage");
    run_transaction(4096, 3, 31, 2, 0, 0);
    run_transaction(4096, 1, 1, 3, 0, 0);
    run_transaction(17, 2, 3, 4, 0, 0);
    for (int tail = 1; tail <= 7; tail++)
      run_transaction(8+tail, 1+(tail%4), (1<<tail)-1, 10+tail, 0, 0);
    run_transaction(1, 4, 255, 20, 0, 0);
    if (accepted_chunks != 48 || completed_chunks != 30 || rejected_chunks != 18 ||
        completed_replays != 30 || completed_k_tokens != 17510 ||
        completed_activation_fills != 30 || rejected_activation_fills != 4)
      $fatal(1, "clean buffered FC hardware counters mismatch");
    expect_fault = 1;
    run_transaction(9, 2, 3, 22, 0, 1);
    if (!fault || chunk_ready || failed_chunks != 1 || completed_chunks != 30)
      $fatal(1, "final read fault did not report failure/quarantine");
    reset_dut();
    run_transaction(17, 2, 3, 23, 0, 1);
    if (!fault || !transaction_active || failed_chunks != 1 || completed_chunks != 0)
      $fatal(1, "nonfinal read fault did not retain poisoned partial sums");
    reset_dut();
    expect_fault = 0;
    for (int mode = 1; mode <= 6; mode++) check_bad_fill(mode);
    run_transaction(7, 2, 3, 21, 0, 0);
    release_weights();
    repeat (5) @(negedge clk);
    if (total_done != 31 || total_failed != 2 || total_transactions != 13 ||
        total_rejects != 18 || total_replays != 33 || total_k != 17536 ||
        total_fill_done != 33 || total_fill_rejects != 4 || total_fill_failed != 6 ||
        read_starts != 33 || read_completes != 33 || read_words != 6714 ||
        total_activation != 6750 || max_activation_words != 484 ||
        read_tail_words == 0 || read_stall_cycles == 0 ||
        stall_cycles < 400 || ce_stalls == 0 || owner_checks == 0 || maxq != 4 ||
        fault || !pipeline_idle)
      $fatal(1, "buffered FC integration final coverage mismatch");
    $display("ALEXNET_M4N8_FC_ACTIVATION_RESIDENT_WEIGHT_ACCUM_DATAPATH_TEST_PASSED descriptors=%0d completed=%0d rejected=%0d failed=%0d transactions=%0d fills=%0d fill_completed=%0d fill_rejected=%0d fill_failed=%0d reads=%0d read_words=%0d tail_words=%0d replays=%0d k_tokens=%0d activation_write_words=%0d weight_words=%0d partial_words=%0d final_int32_words=%0d output_words=%0d output_stall_cycles=%0d read_stall_cycles=%0d ce_stall_cycles=%0d owner_checks=%0d max_activation_words=%0d maxq=%0d seed=%0d",
        total_chunks, total_done, total_rejects, total_failed, total_transactions,
        total_fills, total_fill_done, total_fill_rejects, total_fill_failed,
        read_starts, read_words, read_tail_words, total_replays, total_k,
        total_activation, total_weights, scanned_words, emitted_words, total_outputs,
        stall_cycles, read_stall_cycles, ce_stalls, owner_checks, max_activation_words, maxq, seed);
    $finish;
  end
endmodule
