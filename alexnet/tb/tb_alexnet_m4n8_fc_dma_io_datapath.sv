`timescale 1ns/1ps
module tb_alexnet_m4n8_fc_dma_io_datapath #(
    parameter bit RUNTIME_SLICE_INDEX = 1'b0
);
  import "DPI-C" function int alexnet_golden_requantize(
      input int accumulator, input int bias, input int multiplier,
      input byte right_shift, input byte relu, output byte result);
  logic clk = 0;
  logic rst = 1;
  logic ce = 0;
  logic cfg_valid = 0;
  logic cfg_ready;
  logic [1:0] cfg_destination = 0;
  logic [15:0] cfg_n64_tile_base = 0;
  logic [2:0] cfg_slice_index = 0;
  logic [7:0] cfg_lane_mask = 0;
  logic signed [31:0] cfg_bias [0:7];
  logic signed [17:0] cfg_multiplier [0:7];
  logic [5:0] cfg_right_shift [0:7];
  logic [7:0] cfg_relu = 0;
  logic dma_descriptor_valid = 0;
  logic dma_descriptor_ready;
  logic [1:0] dma_descriptor_destination = 0;
  logic [9:0] dma_descriptor_word_count = 0;
  logic [15:0] dma_descriptor_byte_count = 0;
  logic [7:0] dma_descriptor_lane_mask = 0;
  logic [15:0] dma_descriptor_tag = 0;
  logic [9:0] dma_descriptor_k_count = 0;
  logic [2:0] dma_descriptor_m_count = 0;
  logic [127:0] s_axis_tdata = 0;
  logic [15:0] s_axis_tkeep = 0;
  logic s_axis_tvalid = 0;
  logic s_axis_tready;
  logic s_axis_tlast = 0;
  logic [127:0] m_axis_tdata;
  logic [15:0] m_axis_tkeep;
  logic m_axis_tvalid;
  logic m_axis_tready = 0;
  logic m_axis_tlast;
  logic dma_busy;
  logic [1:0] dma_phase;
  logic dma_transfer_done;
  logic dma_transfer_failed;
  logic dma_descriptor_rejected;
  logic dma_stream_error;
  logic [9:0] dma_words_transferred;
  logic [15:0] dma_accepted_descriptors;
  logic [15:0] dma_rejected_descriptors;
  logic [15:0] dma_completed_transfers;
  logic [15:0] dma_failed_transfers;
  logic result_dma_busy;
  logic result_dma_transfer_done;
  logic result_dma_protocol_error;
  logic [2:0] result_dma_words_transferred;
  logic [15:0] result_dma_completed_transfers;
  logic weight_release_valid = 0;
  logic weight_release_ready;
  logic chunk_valid = 0;
  logic chunk_ready;
  logic [9:0] chunk_k_count = 0;
  logic [2:0] chunk_m_count = 0;
  logic [7:0] chunk_n_lane_mask = 0;
  logic [15:0] chunk_activation_tensor_tag = 0;
  logic [15:0] chunk_weight_context_tag = 0;
  logic [15:0] chunk_context_tag = 0;
  logic [15:0] chunk_tile_tag = 0;
  logic [7:0] chunk_index = 0;
  logic chunk_first = 0;
  logic chunk_final = 0;
  logic [1:0] activation_bank_state;
  logic activation_fill_active;
  logic activation_read_active;
  logic [9:0] activation_words_forwarded;
  logic configured;
  logic chunk_active;
  logic chunk_done;
  logic chunk_rejected;
  logic chunk_failed;
  logic transaction_active;
  logic transaction_done;
  logic compute_busy;
  logic pipeline_idle;
  logic fault;
  logic [1:0] phase;
  logic [1:0] weight_bank_state;
  logic [2:0] accum_bank_state;
  logic [15:0] completed_replays;
  logic [15:0] accepted_chunks;
  logic [15:0] completed_chunks;
  logic [15:0] rejected_chunks;
  logic [15:0] failed_chunks;
  logic [31:0] completed_k_tokens;
  logic [6:0] queued_count;
  wire weight_fill_valid = dut.u_core.weight_fill_valid;
  wire weight_fill_ready = dut.u_core.weight_fill_ready;
  wire [9:0] weight_fill_k_count = dut.u_core.weight_fill_k_count;
  wire [7:0] weight_fill_n_lane_mask = dut.u_core.weight_fill_n_lane_mask;
  wire [15:0] weight_fill_context_tag = dut.u_core.weight_fill_context_tag;
  wire weight_write_valid = dut.u_core.weight_write_valid;
  wire weight_write_ready = dut.u_core.weight_write_ready;
  wire [63:0] weight_write_values = dut.u_core.weight_write_values;
  wire [7:0] weight_write_n_lane_mask = dut.u_core.weight_write_n_lane_mask;
  wire weight_write_last = dut.u_core.weight_write_last;
  wire activation_fill_valid = dut.u_core.activation_fill_valid;
  wire activation_fill_ready = dut.u_core.activation_fill_ready;
  wire [9:0] activation_fill_k_count = dut.u_core.activation_fill_k_count;
  wire [2:0] activation_fill_m_count = dut.u_core.activation_fill_m_count;
  wire [15:0] activation_fill_tensor_tag = dut.u_core.activation_fill_tensor_tag;
  wire activation_write_valid = dut.u_core.activation_write_valid;
  wire activation_write_ready = dut.u_core.activation_write_ready;
  wire [63:0] activation_write_values = dut.u_core.activation_write_values;
  wire [7:0] activation_write_lane_mask = dut.u_core.activation_write_lane_mask;
  wire activation_write_last = dut.u_core.activation_write_last;
  wire [15:0] activation_write_tensor_tag = dut.u_core.activation_write_tensor_tag;
  wire activation_fill_done = dut.u_core.activation_fill_done;
  wire activation_fill_rejected = dut.u_core.activation_fill_rejected;
  wire activation_fill_failed = dut.u_core.activation_fill_failed;
  wire activation_read_done = dut.u_core.activation_read_done;
  wire [9:0] activation_word_count = dut.u_core.activation_word_count;
  wire [15:0] accepted_activation_fills = dut.u_core.accepted_activation_fills;
  wire [15:0] completed_activation_fills = dut.u_core.completed_activation_fills;
  wire [15:0] rejected_activation_fills = dut.u_core.rejected_activation_fills;
  wire [15:0] failed_activation_fills = dut.u_core.failed_activation_fills;
  wire egress_valid = dut.u_core.egress_valid;
  wire egress_ready = dut.u_core.egress_ready;
  wire [63:0] egress_values = dut.u_core.egress_values;
  wire [7:0] egress_lane_mask = dut.u_core.egress_lane_mask;
  wire [1:0] egress_destination = dut.u_core.egress_destination;
  wire [2:0] egress_slice = dut.u_core.egress_slice;
  wire [4:0] egress_m = dut.u_core.egress_m;
  wire [15:0] egress_n_base = dut.u_core.egress_n_base;
  wire [15:0] egress_tile_tag = dut.u_core.egress_tile_tag;
  bit block_output = 0, expect_fault = 0, allow_final = 0, wide_partial_seen = 0;
  int seed = 32'h4643444d;
  int seed_init;
  int sum [0:3][0:7], partial [0:3][0:7];
  logic [63:0] expected [0:3];
  int scan_m = 0, emit_m = 0, output_m = 0, active_m = 0;
  int n_mask, tile_id, destination, n_base, output_slice;
  logic [7:0] placement_seen = 0;
  int pending_placement_checks = 0;
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
  wire [98:0] read_packet = {dut.u_core.bank_read_values, dut.u_core.bank_read_mask,
      dut.u_core.bank_read_index, dut.u_core.bank_read_tag, dut.u_core.bank_read_last};
  logic [63:0] expected_read_word;
  int read_pos_m, read_block_k, read_count_k, expected_read_mask;
  logic stalled_q = 0;
  logic axis_stalled_q = 0;
  logic [144:0] axis_packet_q;
  wire [144:0] axis_packet = {m_axis_tdata, m_axis_tkeep, m_axis_tlast};
  logic [63:0] dma_words [0:967];
  int input_payload_read = 0, sent_input_words = 0, expected_dma_rejections = 0;
  int dma_commands = 0, dma_rejections = 0, dma_successes = 0, dma_failures = 0;
  int mm2s_beats = 0, s2mm_beats = 0, s2mm_words = 0, result_arms = 0, result_transfers = 0;
  int axis_output_m = 0, odd_inputs = 0, odd_outputs = 0, early_core_retire_cycles = 0;
  bit injecting_result_error = 0;
  logic [113:0] packet_q;
  wire [113:0] packet = {egress_values, egress_lane_mask, egress_destination,
      egress_slice, egress_m, egress_n_base, egress_tile_tag};

  alexnet_m4n8_fc_dma_io_datapath #(
      .SLICE_INDEX(1), .RUNTIME_SLICE_INDEX(RUNTIME_SLICE_INDEX)
  ) dut (
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
.*);
  always #2.5 clk = ~clk;
  always @(negedge clk) begin
    ce <= !rst && ($urandom_range(0, 4) != 0);
    m_axis_tready <= !rst && !block_output && ($urandom_range(0, 3) != 0);
  end
  initial begin
    #5000000;
    $fatal(1, "FC integration watchdog phase=%0d issuer=%0d bank=%0d accum=%0d",
        phase, dut.u_core.u_core.u_issuer.phase, weight_bank_state, accum_bank_state);
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
      axis_stalled_q <= 0;
      read_stalled_q <= 0;
    end
    else begin
      if (fault && !expect_fault) $fatal(1, "unexpected FC fault");
      if (cfg_valid && cfg_ready) config_count++;
      if (dma_descriptor_valid && dma_descriptor_ready) dma_commands++;
      if (dma_descriptor_rejected) dma_rejections++;
      if (dma_transfer_done) dma_successes++;
      if (dma_transfer_failed) dma_failures++;
      if (s_axis_tvalid && s_axis_tready) begin
        mm2s_beats++;
        if (s_axis_tlast && s_axis_tkeep == 16'h00ff) odd_inputs++;
      end
      if (activation_write_valid && activation_write_ready ||
          weight_write_valid && weight_write_ready) begin
        if ((activation_write_valid ? activation_write_values : weight_write_values) !== dma_words[input_payload_read])
          $fatal(1, "MM2S low/high unpack mismatch word=%0d", input_payload_read);
        input_payload_read++;
      end
      if (dut.result_descriptor_valid && dut.result_descriptor_ready) begin
        result_arms++;
        if (dut.u_egress.descriptor_slice !== 3'(output_slice) ||
            dut.u_egress.descriptor_n_base !== 16'(n_base + output_slice*8))
          $fatal(1, "result descriptor used live/stale output placement");
        if (!allow_final || !chunk_active || read_starts <= result_transfers)
          $fatal(1, "result armed before validated final chunk");
      end
      if (result_dma_transfer_done) result_transfers++;
      if (axis_stalled_q && (!m_axis_tvalid || axis_packet !== axis_packet_q))
        $fatal(1, "S2MM payload changed under backpressure");
      axis_stalled_q <= m_axis_tvalid && !m_axis_tready;
      axis_packet_q <= axis_packet;
      if (m_axis_tvalid && !allow_final) $fatal(1, "nonfinal S2MM output");
      if (m_axis_tvalid && !m_axis_tready) begin
        stall_cycles++;
        if (!dut.core_chunk_active) early_core_retire_cycles++;
      end
      if (m_axis_tvalid && m_axis_tready) begin
        if (axis_output_m >= active_m ||
            m_axis_tdata[63:0] !== expected[axis_output_m] ||
            m_axis_tlast != (axis_output_m + 2 >= active_m))
          $fatal(1, "S2MM low word/last mismatch");
        if (axis_output_m + 1 < active_m) begin
          if (m_axis_tkeep != 16'hffff || m_axis_tdata[127:64] !== expected[axis_output_m+1])
            $fatal(1, "S2MM high word/keep mismatch");
          axis_output_m += 2;
          s2mm_words += 2;
        end else begin
          if (m_axis_tkeep != 16'h00ff || m_axis_tdata[127:64] != 0)
            $fatal(1, "S2MM odd tail mismatch");
          axis_output_m++;
          s2mm_words++;
          odd_outputs++;
        end
        s2mm_beats++;
      end
      if (chunk_valid && chunk_ready) total_chunks++;
      if (chunk_valid && chunk_ready && weight_release_ready)
        $fatal(1, "simultaneous release stole accepted descriptor weights");
      if (chunk_done) total_done++;
      if (chunk_failed) total_failed++;
      if (chunk_rejected) total_rejects++;
      if (transaction_done) begin
        total_transactions++;
        if (output_m != active_m || axis_output_m != active_m || !pipeline_idle)
          $fatal(1, "transaction completed before all output transfers");
      end
      if (dut.u_core.u_core.replay_valid && dut.u_core.u_core.replay_ready) total_replays++;
      if (dut.u_core.u_core.issue_valid && dut.u_core.u_core.issue_ready) total_k++;
      if (dut.u_core.u_core.issue_valid && !ce) ce_stalls++;
      if (activation_fill_valid && activation_fill_ready) total_fills++;
      if (activation_fill_done) total_fill_done++;
      if (activation_fill_rejected) total_fill_rejects++;
      if (activation_fill_failed) total_fill_failed++;
      if (activation_write_valid && activation_write_ready) total_activation++;
      if (dut.u_core.bank_read_start) read_starts++;
      if (activation_read_done) read_completes++;
      if (activation_word_count > max_activation_words) max_activation_words = activation_word_count;
      if (read_stalled_q && (!dut.u_core.bank_read_valid || read_packet !== read_packet_q))
        $fatal(1, "activation bank read changed under backpressure");
      read_stalled_q <= dut.u_core.bank_read_valid && !dut.u_core.bank_read_ready;
      read_packet_q <= read_packet;
      if (dut.u_core.bank_read_valid && !dut.u_core.bank_read_ready) read_stall_cycles++;
      if (dut.u_core.bank_read_valid && dut.u_core.bank_read_ready) begin
        read_pos_m = dut.u_core.bank_read_index % active_m;
        read_block_k = (dut.u_core.bank_read_index / active_m) * 8;
        expected_read_word = 0;
        expected_read_mask = 0;
        for (int lane = 0; lane < 8; lane++) begin
          if (read_block_k + lane < read_count_k) begin
            expected_read_word[lane*8 +: 8] = 8'(act(active_offset+read_block_k+lane, read_pos_m));
            expected_read_mask |= 1 << lane;
          end
        end
        if (dut.u_core.bank_read_values !== expected_read_word ||
            dut.u_core.read_k_mask != expected_read_mask || dut.u_core.bank_read_mask != 255 ||
            dut.u_core.bank_read_tag != (injecting_read_error ? 16'hfffe : activation_fill_tensor_tag) ||
            dut.u_core.bank_read_last != (dut.u_core.bank_read_index == ((read_count_k+7)/8)*active_m-1))
          $fatal(1, "FC stored activation mismatch index=%0d", dut.u_core.bank_read_index);
        if (expected_read_mask != 255) read_tail_words++;
        read_words++;
      end
      if (weight_write_valid && weight_write_ready) total_weights++;
      if (chunk_active && (weight_release_valid || dma_descriptor_valid)) begin
        owner_checks++;
        if (weight_release_ready || dma_descriptor_ready)
          $fatal(1, "weight owner escaped an active descriptor");
      end
      if (queued_count > maxq) maxq = queued_count;
      if (dut.u_core.u_core.g_local.u_base.u_output_slice.scanner_valid &&
          dut.u_core.u_core.g_local.u_base.u_output_slice.scanner_ready) begin
        if (scan_m >= active_m) $fatal(1, "extra partial-sum word");
        for (int n = 0; n < 8; n++)
          if (n_mask & (1 << n))
            if (dut.u_core.u_core.g_local.u_base.u_output_slice.scanner_accumulator[n] !== partial[scan_m][n])
              $fatal(1, "chunk dot mismatch m=%0d n=%0d got=%0d expected=%0d",
                  scan_m, n, dut.u_core.u_core.g_local.u_base.u_output_slice.scanner_accumulator[n], partial[scan_m][n]);
        scan_m++;
        scanned_words++;
      end
      if (dut.u_core.u_core.g_local.u_base.u_output_slice.bank_egress_valid &&
          dut.u_core.u_core.g_local.u_base.u_output_slice.bank_egress_ready) begin
        if (!allow_final || emit_m >= active_m)
          $fatal(1, "nonfinal/extra accumulated output");
        for (int n = 0; n < 8; n++)
          if (dut.u_core.u_core.g_local.u_base.u_output_slice.bank_egress_accumulator[n] !==
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
      if (egress_valid && egress_ready) begin
        if (output_m >= active_m || egress_values !== expected[output_m] ||
            egress_m != output_m || egress_lane_mask != n_mask ||
            egress_tile_tag != (injecting_result_error ? 16'hfffe : tile_id) || egress_destination != destination ||
            egress_slice != output_slice || egress_n_base != n_base + output_slice*8)
          $fatal(1, "final packet mismatch m=%0d got=%h expected=%h",
              output_m, egress_values, expected[output_m]);
        output_m++;
        total_outputs++;
        if (!expect_fault) placement_seen[egress_slice] = 1;
      end
    end
  end

  task automatic configure(input int mask, input int id);
    @(negedge clk);
    cfg_lane_mask = mask;
    cfg_destination = id % 3;
    cfg_n64_tile_base = RUNTIME_SLICE_INDEX ? (id / 8) * 64 : id * 64;
    cfg_slice_index = id % 8;
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
    output_slice = RUNTIME_SLICE_INDEX ? cfg_slice_index : 1;
    // Both modes must ignore live placement pins after config acceptance.
    cfg_slice_index = 3'bxxx;
    cfg_n64_tile_base = 16'hxxxx;
    cfg_destination = 2'bxx;
  endtask

  task automatic release_weights;
    @(negedge clk);
    weight_release_valid = 1;
    do @(posedge clk); while (!weight_release_ready);
    @(negedge clk);
    weight_release_valid = 0;
    if (weight_bank_state != 0) $fatal(1, "release did not empty weight bank");
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
    int before_replays, before_k, before_reads, before_result_arms;
    before_replays = total_replays;
    before_k = total_k;
    before_reads = read_starts;
    before_result_arms = result_arms;
    send_descriptor();
    while (!chunk_rejected) @(negedge clk);
    if (result_arms != before_result_arms || result_dma_busy || fault ||
        activation_bank_state != 2 || read_starts != before_reads ||
        total_replays != before_replays || total_k != before_k)
      $fatal(1, "rejected descriptor changed a child owner");
    @(negedge clk);
  endtask



  task automatic send_dma_descriptor;
    @(negedge clk);
    dma_descriptor_valid = 1;
    chunk_valid = 1;
    weight_release_valid = 1;
    do @(posedge clk); while (!dma_descriptor_ready);
    if (chunk_ready || weight_release_ready) $fatal(1, "input descriptor lost priority");
    @(negedge clk);
    dma_descriptor_valid = 0;
    chunk_valid = 0;
    weight_release_valid = 0;
  endtask

  task automatic set_dma_descriptor(input int dst, input int k, input int m,
      input int mask, input int tag);
    dma_descriptor_destination = dst;
    dma_descriptor_k_count = k;
    dma_descriptor_m_count = m;
    dma_descriptor_word_count = dst == 0 ? ((k+7)/8)*m : k;
    dma_descriptor_byte_count = dma_descriptor_word_count * 8;
    dma_descriptor_lane_mask = mask;
    dma_descriptor_tag = tag;
  endtask

  task automatic reject_dma;
    int old_a, old_w, old_words;
    old_a = activation_bank_state;
    old_w = weight_bank_state;
    old_words = total_activation + total_weights;
    send_dma_descriptor();
    while (!dma_descriptor_rejected) @(negedge clk);
    if (fault || s_axis_tready || activation_bank_state != old_a ||
        weight_bank_state != old_w || total_activation + total_weights != old_words)
      $fatal(1, "rejected DMA descriptor changed storage/payload");
    expected_dma_rejections++;
    @(negedge clk);
  endtask

  task automatic send_dma_payload(input int word_count, input int error_mode);
    input_payload_read = 0;
    sent_input_words = word_count;
    send_dma_descriptor();
    // The accepted descriptor must be independent of changing external pins.
    dma_descriptor_destination = 3;
    dma_descriptor_word_count = 0;
    dma_descriptor_byte_count = 0;
    dma_descriptor_lane_mask = 8'h55;
    dma_descriptor_tag = 16'hffff;
    dma_descriptor_k_count = 0;
    dma_descriptor_m_count = 7;
    for (int w = 0; w < word_count; w += 2) begin
      repeat ($urandom_range(0, 3)) @(negedge clk);
      s_axis_tdata = {64'hdeadbeefcafebabe, dma_words[w]};
      s_axis_tkeep = 16'h00ff;
      if (w+1 < word_count) begin
        s_axis_tdata[127:64] = dma_words[w+1];
        s_axis_tkeep = 16'hffff;
      end
      s_axis_tlast = w+2 >= word_count;
      if (error_mode == 1 && w == 0) s_axis_tkeep = 16'hfffe;
      if (error_mode == 2 && w == 0) s_axis_tlast = 1;
      if (error_mode == 3 && w+2 >= word_count) s_axis_tlast = 0;
      s_axis_tvalid = 1;
      do @(posedge clk); while (!s_axis_tready);
      @(negedge clk);
      s_axis_tvalid = 0;
    end
    while (!(dma_transfer_done || dma_transfer_failed)) @(negedge clk);
    if (dma_transfer_failed != (error_mode != 0) || dma_words_transferred != word_count ||
        input_payload_read != word_count)
      $fatal(1, "DMA transfer retirement mismatch mode=%0d count=%0d actual=%0d",
          error_mode, word_count, input_payload_read);
    @(negedge clk);
  endtask

  task automatic load_weights(input int offset, input int k_count, input int tag);
    if (weight_bank_state == 2) release_weights();
    set_dma_descriptor(2, k_count, 0, n_mask, tag);
    for (int k = 0; k < k_count; k++)
      for (int n = 0; n < 8; n++) dma_words[k][n*8 +: 8] = 8'(weight(offset+k, n));
    send_dma_payload(k_count, 0);
  endtask

  task automatic load_activations(input int offset, input int k_count, input int error_mode);
    int w;
    active_offset = offset;
    read_count_k = k_count;
    set_dma_descriptor(0, k_count, active_m, 255, chunk_activation_tensor_tag);
    w = 0;
    for (int block_k = 0; block_k < k_count; block_k += 8) begin
      for (int m = 0; m < active_m; m++) begin
        dma_words[w] = 0;
        for (int lane = 0; lane < 8; lane++)
          if (block_k + lane < k_count)
            dma_words[w][lane*8 +: 8] = 8'(act(offset+block_k+lane, m));
        w++;
      end
    end
    if (error_mode == 4) dma_words[w-1][63:56] = 8'h7e;
    send_dma_payload(w, error_mode);
  endtask

  task automatic reset_dut;
    @(negedge clk);
    rst = 1;
    repeat (5) @(negedge clk);
    rst = 0;
    @(negedge clk);
  endtask

  task automatic check_bad_input(input int destination_kind, input int error_mode);
    int before_reads, before_k, before_outputs;
    before_reads = read_starts;
    before_k = total_k;
    before_outputs = total_outputs;
    expect_fault = 1;
    if (destination_kind == 0) begin
      active_m = 3;
      chunk_activation_tensor_tag = 16'h900 + error_mode;
      load_activations(0, 9, error_mode);
    end else begin
      set_dma_descriptor(2, 9, 0, 7, 16'h800+error_mode);
      for (int k = 0; k < 9; k++)
        for (int n = 0; n < 8; n++) dma_words[k][n*8 +: 8] = 8'(weight(k, n));
      send_dma_payload(9, error_mode);
    end
    chunk_valid = 1;
    dma_descriptor_valid = 1;
    cfg_valid = 1;
    weight_release_valid = 1;
    repeat (8) begin
      @(negedge clk);
      if (!fault || dma_descriptor_ready || s_axis_tready || chunk_ready ||
          cfg_ready || weight_release_ready || activation_read_active ||
          chunk_done || transaction_done || m_axis_tvalid || result_dma_busy)
        $fatal(1, "malformed DMA transfer escaped quarantine");
    end
    chunk_valid = 0;
    dma_descriptor_valid = 0;
    cfg_valid = 0;
    weight_release_valid = 0;
    if (read_starts != before_reads || total_k != before_k || total_outputs != before_outputs)
      $fatal(1, "malformed MM2S input reached compute");
    reset_dut();
    expect_fault = 0;
  endtask

  task automatic check_dma_descriptor_rejections;
    set_dma_descriptor(0, 9, 3, 255, 16'h800);
    dma_descriptor_destination = 1; reject_dma();
    dma_descriptor_destination = 3; reject_dma();
    dma_descriptor_destination = 0;
    dma_descriptor_k_count = 0; reject_dma();
    dma_descriptor_k_count = 969; reject_dma();
    dma_descriptor_k_count = 9;
    dma_descriptor_m_count = 0; reject_dma();
    dma_descriptor_m_count = 5; reject_dma();
    dma_descriptor_m_count = 3;
    dma_descriptor_word_count = 0; reject_dma();
    dma_descriptor_word_count = 5; reject_dma();
    dma_descriptor_word_count = 7; reject_dma();
    dma_descriptor_word_count = 513; reject_dma();
    dma_descriptor_word_count = 6;
    dma_descriptor_byte_count = 40; reject_dma();
    dma_descriptor_byte_count = 49; reject_dma();
    dma_descriptor_byte_count = 48;
    dma_descriptor_lane_mask = 127; reject_dma();
    dma_descriptor_lane_mask = 0; reject_dma();
    set_dma_descriptor(2, 9, 0, 7, 16'h801);
    dma_descriptor_word_count = 8; reject_dma();
    dma_descriptor_word_count = 9;
    dma_descriptor_k_count = 8; reject_dma();
    dma_descriptor_k_count = 9;
    dma_descriptor_m_count = 1; reject_dma();
    dma_descriptor_m_count = 0;
    dma_descriptor_lane_mask = 85; reject_dma();
    dma_descriptor_lane_mask = 0; reject_dma();
    set_dma_descriptor(2, 969, 0, 7, 16'h801); reject_dma();
  endtask

  task automatic run_transaction(input int full_k, input int m_count,
      input int mask, input int id, input bit check_rejects, input int bad_tag);
    int count_k, chunk_no, offset;
    byte result;
    configure(mask, id);
    n_mask = mask;
    active_m = m_count;
    tile_id = id * 257;
    output_m = 0;
    axis_output_m = 0;
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
        // READY owners cannot be overwritten by an otherwise valid descriptor.
        set_dma_descriptor(0, count_k, m_count, 255, chunk_activation_tensor_tag); reject_dma();
        set_dma_descriptor(2, count_k, 0, mask, chunk_weight_context_tag); reject_dma();
        chunk_final = 1;
        chunk_activation_tensor_tag++; reject_descriptor(); chunk_activation_tensor_tag--;
        chunk_final = 0;
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
        cfg_slice_index = (output_slice + 3) % 8;
        cfg_n64_tile_base = 16'hffc0;
        cfg_destination = 2;
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
      if (bad_tag == 1) begin
        // Inject before read_start, so even stalled valid metadata stays
        // stable. This exercises both the wrapper and inner error paths.
        injecting_read_error = 1;
        force dut.u_core.bank_read_tag = 16'hfffe;
      end else if (bad_tag == 2) begin
        injecting_result_error = 1;
        force dut.core_egress_tile_tag = 16'hfffe;
      end
      // Attempt owner changes both before replay and after the last K beat.
      weight_release_valid = 1;
      dma_descriptor_valid = 1;

      if (chunk_final) begin
        while (!m_axis_tvalid) @(negedge clk);
        // A future placement cannot commit merely because the inner core
        // has finished: the old AXIS result owner must drain first.
        cfg_slice_index = (output_slice + 1) % 8;
        cfg_n64_tile_base = 16'hffc0;
        cfg_destination = 2;
        cfg_valid = 1;
        repeat (40) begin
          @(negedge clk);
          if (cfg_ready || chunk_done || chunk_failed || transaction_done || !chunk_active)
            $fatal(1, "FC retired while final output was stalled");
          if (dut.cfg_slice_q != output_slice || dut.cfg_n_base_q != n_base + output_slice*8)
            $fatal(1, "blocked config changed the DMA placement shadow");
          pending_placement_checks++;
        end
        cfg_valid = 0;
        cfg_slice_index = 3'bxxx;
        cfg_n64_tile_base = 16'hxxxx;
        weight_release_valid = 0;
        dma_descriptor_valid = 0;
        block_output = 0;
      end else begin
        // Retract probe requests before the next owner boundary.
        while (dut.u_core.completed_k_tokens == 0 || dut.u_core.u_core.u_issuer.phase != 6)
          @(negedge clk);
        weight_release_valid = 0;
        dma_descriptor_valid = 0;
      end
      while (!(chunk_done || chunk_failed)) @(negedge clk);
      dma_descriptor_valid = 0;
      if (bad_tag == 1) begin
        release dut.u_core.bank_read_tag;
        injecting_read_error = 0;
      end else if (bad_tag == 2) begin
        release dut.core_egress_tile_tag;
        injecting_result_error = 0;
      end
      if (activation_bank_state != 0 || activation_words_forwarded != ((count_k+7)/8)*m_count)
        $fatal(1, "FC activation ownership/count did not retire");
      if (scan_m != m_count || (chunk_failed != (bad_tag != 0)))
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
    if (output_m != m_count || axis_output_m != m_count || emit_m != m_count || !pipeline_idle)
      $fatal(1, "final transaction did not fully drain");
  endtask

  initial begin
    seed_init = $urandom(seed);
    repeat (8) @(negedge clk);
    rst = 0;
    check_dma_descriptor_rejections();
    run_transaction(9216, 4, 255, 1, 1, 0);
    if (!wide_partial_seen) $fatal(1, "missing cross-chunk INT32 range coverage");
    run_transaction(4096, 3, 31, 2, 0, 0);
    run_transaction(4096, 1, 1, 3, 0, 0);
    run_transaction(17, 2, 3, 4, 0, 0);
    for (int tail = 1; tail <= 7; tail++)
      run_transaction(8+tail, 1+(tail%4), (1<<tail)-1, 10+tail, 0, 0);
    run_transaction(1, 4, 255, 20, 0, 0);
    if (accepted_chunks != 49 || completed_chunks != 30 || rejected_chunks != 19 ||
        completed_replays != 30 || completed_k_tokens != 17510 ||
        dma_completed_transfers != 60 || result_dma_completed_transfers != 12)
      $fatal(1, "clean FC DMA hardware counters mismatch");
    expect_fault = 1;
    run_transaction(9, 2, 3, 22, 0, 1);
    if (!fault || chunk_ready || failed_chunks != 1 || completed_chunks != 30)
      $fatal(1, "final read fault did not report failure/quarantine");
    reset_dut();
    run_transaction(17, 2, 3, 23, 0, 1);
    if (!fault || !transaction_active || failed_chunks != 1 || completed_chunks != 0)
      $fatal(1, "nonfinal read fault did not retain poisoned partial sums");
    reset_dut();
    run_transaction(7, 3, 7, 24, 0, 2);
    if (!fault || !result_dma_protocol_error || failed_chunks != 1)
      $fatal(1, "result metadata fault did not retire as failed");
    reset_dut();
    expect_fault = 0;
    for (int mode = 1; mode <= 4; mode++) check_bad_input(0, mode);
    for (int mode = 1; mode <= 3; mode++) check_bad_input(2, mode);
    run_transaction(7, 2, 3, 21, 0, 0);
    release_weights();
    repeat (5) @(negedge clk);
    if (total_done != 31 || total_failed != 3 || total_transactions != 13 ||
        total_rejects != 19 || total_replays != 34 || total_k != 17543 ||
        dma_rejections != expected_dma_rejections || dma_successes != 68 ||
        dma_failures != 7 || result_arms != 15 || result_transfers != 15 ||
        read_starts != 34 || read_completes != 34 ||
        max_activation_words != 484 || read_tail_words == 0 || read_stall_cycles == 0 ||
        stall_cycles < 400 || ce_stalls == 0 || owner_checks == 0 || maxq > 4 ||
        odd_inputs == 0 || odd_outputs == 0 || early_core_retire_cycles == 0 ||
        s2mm_words != total_outputs || fault || !pipeline_idle)
      $fatal(1, "FC DMA integration final coverage mismatch");
    if (RUNTIME_SLICE_INDEX) begin
      // One SA visits every N8 position of the same N64 group, with distinct
      // configurations and two K chunks each. Also exercise FC8's last N8.
      for (int position = 0; position < 8; position++)
        run_transaction(17, 1+(position%4), (1<<(1+position))-1, 32+position, 0, 0);
      run_transaction(9, 1, 255, 124, 0, 0); // N=992..999
      release_weights();
      repeat (5) @(negedge clk);
      if (placement_seen != 255 || total_transactions != 22 ||
          total_k != 17688 || total_done != 48 || result_arms != 24 ||
          pending_placement_checks < 800 || fault || !pipeline_idle)
        $fatal(1, "runtime FC placement coverage mismatch");
      $display("ALEXNET_M4N8_FC_DMA_RUNTIME_PLACEMENT_TEST_PASSED positions=%02x pending_config_checks=%0d transactions=%0d",
          placement_seen, pending_placement_checks, total_transactions);
    end
    $display("ALEXNET_M4N8_FC_DMA_IO_DATAPATH_TEST_PASSED descriptors=%0d completed=%0d rejected=%0d failed=%0d transactions=%0d dma_commands=%0d dma_completed=%0d dma_rejected=%0d dma_failed=%0d mm2s_beats=%0d result_transfers=%0d s2mm_beats=%0d s2mm_words=%0d odd_inputs=%0d odd_outputs=%0d replays=%0d k_tokens=%0d activation_words=%0d weight_words=%0d partial_words=%0d output_stall_cycles=%0d read_stall_cycles=%0d ce_stall_cycles=%0d owner_checks=%0d early_core_retire_cycles=%0d max_activation_words=%0d maxq=%0d seed=%0d",
        total_chunks, total_done, total_rejects, total_failed, total_transactions,
        dma_commands, dma_successes, dma_rejections, dma_failures, mm2s_beats,
        result_transfers, s2mm_beats, s2mm_words, odd_inputs, odd_outputs,
        total_replays, total_k, total_activation, total_weights, scanned_words,
        stall_cycles, read_stall_cycles, ce_stalls, owner_checks, early_core_retire_cycles,
        max_activation_words, maxq, seed);
    $finish;
  end
endmodule
