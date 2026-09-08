`timescale 1ns/1ps
module tb_alexnet_m4n8_fc_layer_datapath;
  import "DPI-C" function int alexnet_golden_requantize(
      input int accumulator, input int bias, input int multiplier,
      input byte right_shift, input byte relu, output byte result);
  import "DPI-C" function int alexnet_golden_linear_point(
      input byte input_values [0:4095], input byte weights [0:4095],
      input int k_depth, output int accumulator);
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
  logic ce;
  logic [127:0] s_axis_tdata;
  logic [15:0] s_axis_tkeep;
  logic s_axis_tvalid;
  logic s_axis_tready;
  logic s_axis_tlast;
  logic [127:0] m_axis_tdata;
  logic [15:0] m_axis_tkeep;
  logic m_axis_tvalid;
  logic m_axis_tready;
  logic m_axis_tlast;
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
  alexnet_m4n8_fc_layer_datapath dut (
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
  initial clk = 0;
  always #2.5 clk = ~clk;
  int seed = 32'h46434c59, seed_init;
  bit expect_fault = 0, inject_input_error = 0, inject_ack_error = 0;
  bit source_active = 0, sink_armed = 0, sink_received = 0;
  bit input_fire_q = 0, parameter_fire_q = 0, ack_fire_q = 0;
  int source_destination, source_k_offset, source_k_count, source_n_base;
  int source_m_count, source_words, source_index;
  int sink_n_base, sink_tag, sink_m_count, sink_index, sink_block_count, ack_delay;
  int expected_n_base = 0, expected_k_offset = 0, expected_chunk = 0;
  int expected_full_k = 4096, expected_job_tag = 0, expected_m = 1;
  int job_chunks = 0, job_input_transfers = 0, job_results = 0, job_words = 0;
  int issue_offset = 0, issue_index = 0, issue_n_base = 0;
  int total_chunks = 0, total_results = 0, total_words = 0, total_k = 0;
  int total_inputs = 0, total_mm2s_beats = 0, total_s2mm_beats = 0;
  int output_stalls = 0, ce_stalls = 0, commit_waits = 0, checked_parameters = 0;
  int failures = 0, clean_layers = 0, cfg_mismatches = 0;
  logic [63:0] expected_values [0:3];
  int expected_sum [0:3][0:7];
  bit axis_stalled_q = 0;
  logic [144:0] held_axis;
  wire [144:0] axis_packet = {m_axis_tdata,m_axis_tkeep,m_axis_tlast};

  function automatic int activation(input int k, input int m);
    return ((k*7+k/3+m*17)%255)-127;
  endfunction
  function automatic int weight(input int k, input int n);
    return ((k*11+k/5+n*31)%255)-127;
  endfunction
  function automatic int bias(input int n);
    return ((n%101)-50)*32768;
  endfunction
  function automatic logic [63:0] source_word(input int index);
    logic [63:0] word_value;
    int k,m;
    word_value = 0;
    if (source_destination == 2) begin
      for (int n = 0; n < 8; n++)
        word_value[n*8 +: 8] = 8'(weight(source_k_offset+index,source_n_base+n));
    end else begin
      m = index % source_m_count;
      for (int lane = 0; lane < 8; lane++) begin
        k = (index/source_m_count)*8+lane;
        if (k < source_k_count)
          word_value[lane*8 +: 8] = 8'(activation(source_k_offset+k,m));
      end
    end
    return word_value;
  endfunction
  task automatic make_expected(input int nbase);
    byte value;
    int dense_sum, av, wv, cpp_sum;
    byte dense_input [0:4095], dense_weight [0:4095];
    for (int m = 0; m < 4; m++) begin
      expected_values[m] = 0;
      for (int n = 0; n < 8; n++) begin
        expected_sum[m][n] = 0;
        if (m < expected_m) begin
          dense_sum = 0;
          for (int k = 0; k < expected_full_k; k++) begin
            av = activation(k,m);
            wv = weight(k,nbase+n);
            dense_input[k] = av;
            dense_weight[k] = wv;
            dense_sum = dense_sum + av*wv;
          end
          // Keep reduction in a scalar and independently cross-check it in
          // C++; do not rely on a compound update of an unpacked array cell.
          if (alexnet_golden_linear_point(dense_input,dense_weight,expected_full_k,cpp_sum) != 0 ||
              cpp_sum != dense_sum)
            $fatal(1,"C++ dense dot-product mismatch rtl_fixture=%0d cpp=%0d",dense_sum,cpp_sum);
          expected_sum[m][n] = dense_sum;
          if (nbase == 0 && m == 0 && n == 0 && dense_sum != 47479)
            $fatal(1,"independent dense fixture checksum mismatch %0d K=%0d",dense_sum,expected_full_k);
          if (alexnet_golden_requantize(expected_sum[m][n],bias(nbase+n),
              65540+n*7000,32,0,value) != 0) $fatal(1, "DPI requant failed");
          expected_values[m][n*8 +: 8] = value;
        end
      end
    end
  endtask

  // External data/parameter/result services. Every source holds its payload
  // until handshake; logical request coordinates are checked independently.
  always @(negedge clk) begin
    if (rst) begin
      ce = 0; parameter_valid = 0; read_request_ready = 0;
      s_axis_tvalid = 0; s_axis_tdata = 0; s_axis_tkeep = 0; s_axis_tlast = 0;
      result_request_ready = 0; m_axis_tready = 0; result_complete_valid = 0;
    end else begin
      ce = $urandom_range(0,4) != 0;
      if (parameter_fire_q) begin
        parameter_valid = 0;
        parameter_n_base = 'x; parameter_layer_id = 'x; parameter_job_tag = 'x;
        for (int n = 0; n < 8; n++) begin
          parameter_bias[n] = 'x; parameter_multiplier[n] = 'x; parameter_right_shift[n] = 'x;
        end
      end else if (!parameter_valid && parameter_request_valid && $urandom_range(0,3) == 0) begin
        parameter_valid = 1;
        parameter_layer_id = active_layer_id;
        parameter_job_tag = active_job_tag;
        parameter_n_base = active_n_base;
        for (int n = 0; n < 8; n++) begin
          parameter_bias[n] = bias(active_n_base+n);
          parameter_multiplier[n] = 65540+n*7000;
          parameter_right_shift[n] = 32;
        end
      end
      read_request_ready = !source_active && $urandom_range(0,3) != 0;
      if (!s_axis_tvalid || input_fire_q) begin
        s_axis_tvalid = source_active && $urandom_range(0,3) != 0;
        if (s_axis_tvalid) begin
          s_axis_tdata[63:0] = source_word(source_index);
          s_axis_tdata[127:64] = source_index+1 < source_words ? source_word(source_index+1) : 0;
          s_axis_tkeep = source_index+1 < source_words ? 16'hffff : 16'h00ff;
          s_axis_tlast = source_index+2 >= source_words;
          if (inject_input_error && source_index == 0) s_axis_tkeep = 16'hfffe;
        end
      end
      result_request_ready = !sink_armed && $urandom_range(0,3) != 0;
      if (sink_armed && m_axis_tvalid && sink_block_count > 0) sink_block_count--;
      m_axis_tready = sink_armed && sink_block_count == 0 && $urandom_range(0,3) != 0;
      if (ack_fire_q) result_complete_valid = 0;
      else if (sink_received && !result_complete_valid) begin
        if (ack_delay > 0) ack_delay--;
        else begin
          result_complete_valid = 1;
          result_complete_n_base = sink_n_base;
          result_complete_tag = sink_tag ^ (inject_ack_error ? 1 : 0);
          result_complete_error = 0;
        end
      end
    end
  end

  always @(posedge clk) begin : check_and_service
    int kcount, words, tag, beat_words;
    if (rst) begin
      source_active = 0; sink_armed = 0; sink_received = 0;
      source_index = 0; sink_index = 0;
      input_fire_q = 0; parameter_fire_q = 0; ack_fire_q = 0; axis_stalled_q = 0;
    end else begin
      input_fire_q = s_axis_tvalid && s_axis_tready;
      parameter_fire_q = parameter_valid && parameter_ready;
      ack_fire_q = result_complete_valid && result_complete_ready;
      if (fault && !expect_fault) $fatal(1, "unexpected full FC fault code=%0d core=%0b",fault_code,dut.core_fault);
      if (layer_failed) failures++;
      if (layer_done) clean_layers++;
      if (parameter_fire_q) begin
        if (active_n_base != expected_n_base || active_k_offset != 0 ||
            active_job_tag != expected_job_tag || active_m_count != expected_m ||
            active_layer_id != 8) $fatal(1, "parameter request skipped/repeated a tile");
        make_expected(expected_n_base);
        checked_parameters++;
      end
      if (dut.cfg_valid && dut.cfg_ready) begin
        for (int n = 0; n < 8; n++)
          if (dut.cfg_bias[n] !== bias(expected_n_base+n) ||
              dut.cfg_multiplier[n] != 65540+n*7000 || dut.cfg_right_shift[n] != 32)
            $fatal(1, "integrated parameter capture mismatch lane=%0d bias=%0d/%0d mult=%0d shift=%0d",
                n,dut.cfg_bias[n],bias(expected_n_base+n),dut.cfg_multiplier[n],dut.cfg_right_shift[n]);
        if (dut.cfg_n64_tile_base != (expected_n_base/64)*64 ||
            dut.cfg_slice_index != (expected_n_base/8)%8 ||
            dut.cfg_lane_mask != 255 || dut.cfg_destination != 2 || dut.cfg_relu != 0)
          $fatal(1, "integrated FC8 configuration mismatch");
      end
      if (read_request_valid && read_request_ready) begin
        kcount = expected_full_k-expected_k_offset > 968 ? 968 : expected_full_k-expected_k_offset;
        words = read_request_destination == 2 ? kcount : ((kcount+7)/8)*expected_m;
        if (source_active || active_n_base != expected_n_base || active_k_offset != expected_k_offset ||
            active_k_count != kcount || read_request_word_count != words ||
            read_request_byte_count != words*8 || read_request_tag != 16'(expected_job_tag+job_chunks) ||
            read_request_destination != (job_input_transfers%2 == 0 ? 0 : 2) ||
            read_request_m_count != (read_request_destination == 2 ? 0 : expected_m))
          $fatal(1, "integrated input request mismatch n=%0d k=%0d",active_n_base,active_k_offset);
        source_active = 1; source_destination = read_request_destination;
        source_n_base = active_n_base; source_k_offset = active_k_offset;
        source_k_count = active_k_count; source_m_count = expected_m;
        source_words = words; source_index = 0;
        job_input_transfers++; total_inputs++;
      end
      if (input_fire_q) begin
        total_mm2s_beats++;
        if (!source_active) $fatal(1, "input AXIS without a request");
        source_index += source_index+1 < source_words ? 2 : 1;
        if (source_index == source_words) source_active = 0;
      end
      if (result_request_valid && result_request_ready) begin
        if (sink_armed || active_n_base != expected_n_base ||
            active_k_offset != 3872 || active_k_count != 224 ||
            result_request_destination != 2 || result_request_byte_count != expected_m*8 ||
            result_request_tag != 16'(expected_job_tag+expected_n_base/8))
          $fatal(1, "result request did not precede correct final chunk");
        sink_armed = 1; sink_received = 0; sink_n_base = active_n_base;
        sink_tag = result_request_tag; sink_m_count = expected_m; sink_index = 0;
        sink_block_count = 30;
      end
      if (dut.chunk_valid && dut.chunk_ready) begin
        kcount = expected_full_k-expected_k_offset > 968 ? 968 : expected_full_k-expected_k_offset;
        tag = expected_job_tag+expected_n_base/8;
        if (dut.chunk_k_count != kcount || dut.chunk_index != expected_chunk ||
            dut.chunk_m_count != expected_m || dut.chunk_first != (expected_chunk == 0) ||
            dut.chunk_final != (expected_k_offset+kcount == expected_full_k) ||
            dut.chunk_tile_tag != 16'(tag) || dut.chunk_context_tag != 16'(tag) ||
            dut.chunk_n_lane_mask != 255 ||
            dut.chunk_activation_tensor_tag != 16'(expected_job_tag+job_chunks) ||
            dut.chunk_weight_context_tag != 16'(expected_job_tag+job_chunks))
          $fatal(1, "integrated FC chunk sequence mismatch");
        if (dut.chunk_final && !sink_armed) $fatal(1, "final compute before result service armed");
        issue_offset = expected_k_offset; issue_index = 0; issue_n_base = expected_n_base;
        job_chunks++; total_chunks++; total_k += kcount;
        expected_chunk++;
        expected_k_offset += kcount;
        if (expected_k_offset == expected_full_k) begin expected_k_offset = 0; expected_chunk = 0; end
      end
      if (dut.u_core.u_core.u_core.issue_valid && !ce) ce_stalls++;
      if (dut.u_core.u_core.u_core.issue_valid && dut.u_core.u_core.u_core.issue_ready) begin
        for (int m = 0; m < expected_m; m++) begin
          if ((m%2 == 0 ? dut.u_core.u_core.u_core.issue_act_lo[m/2] :
                          dut.u_core.u_core.u_core.issue_act_hi[m/2]) !==
              8'(activation(issue_offset+issue_index,m)))
            $fatal(1,"FC issue activation mismatch k=%0d m=%0d got=%0d expected=%0d",
                issue_offset+issue_index,m,dut.u_core.u_core.u_core.issue_act_lo[m/2],
                activation(issue_offset+issue_index,m));
        end
        for (int n = 0; n < 8; n++)
          if (dut.u_core.u_core.u_core.issue_weight[n] !==
              8'(weight(issue_offset+issue_index,issue_n_base+n)))
            $fatal(1,"FC issue weight mismatch k=%0d n=%0d got=%0d expected=%0d",
                issue_offset+issue_index,issue_n_base+n,dut.u_core.u_core.u_core.issue_weight[n],
                weight(issue_offset+issue_index,issue_n_base+n));
        issue_index++;
      end
      if (dut.u_core.core_egress_valid && dut.u_core.core_egress_ready) begin
        if (dut.u_core.core_egress_values !== expected_values[dut.u_core.core_egress_m] ||
            dut.u_core.core_egress_n_base != sink_n_base ||
            dut.u_core.core_egress_slice != (sink_n_base/8)%8 ||
            dut.u_core.core_egress_destination != 2 || dut.u_core.core_egress_lane_mask != 255 ||
            dut.u_core.core_egress_tile_tag != sink_tag)
          $fatal(1, "full FC8 routed mismatch n=%0d/%0d m=%0d values=%h/%h slice=%0d/%0d dest=%0d mask=%h tag=%h/%h",
              dut.u_core.core_egress_n_base,sink_n_base,dut.u_core.core_egress_m,
              dut.u_core.core_egress_values,expected_values[dut.u_core.core_egress_m],
              dut.u_core.core_egress_slice,(sink_n_base/8)%8,dut.u_core.core_egress_destination,
              dut.u_core.core_egress_lane_mask,dut.u_core.core_egress_tile_tag,sink_tag);
      end
      if (dut.u_core.u_core.u_core.g_local.u_base.u_output_slice.bank_egress_valid &&
          dut.u_core.u_core.u_core.g_local.u_base.u_output_slice.bank_egress_ready) begin
        for (int n = 0; n < 8; n++)
          if (dut.u_core.u_core.u_core.g_local.u_base.u_output_slice.bank_egress_accumulator[n] !==
              expected_sum[dut.u_core.u_core.u_core.g_local.u_base.u_output_slice.egress_raster_x_q][n])
            $fatal(1, "final INT32 mismatch n=%0d m=%0d actual=%0d expected=%0d",
                n,dut.u_core.u_core.u_core.g_local.u_base.u_output_slice.egress_raster_x_q,
                dut.u_core.u_core.u_core.g_local.u_base.u_output_slice.bank_egress_accumulator[n],
                expected_sum[dut.u_core.u_core.u_core.g_local.u_base.u_output_slice.egress_raster_x_q][n]);
      end
      if (axis_stalled_q && (!m_axis_tvalid || axis_packet !== held_axis))
        $fatal(1, "result AXIS changed while stalled");
      axis_stalled_q = m_axis_tvalid && !m_axis_tready; held_axis = axis_packet;
      if (axis_stalled_q) output_stalls++;
      if (m_axis_tvalid && m_axis_tready) begin
        if (!sink_armed || sink_received) $fatal(1, "unowned/extra result AXIS beat");
        beat_words = sink_index+1 < sink_m_count ? 2 : 1;
        if (m_axis_tdata[63:0] !== expected_values[sink_index] ||
            m_axis_tdata[127:64] !== (beat_words == 2 ? expected_values[sink_index+1] : 64'b0) ||
            m_axis_tkeep != (beat_words == 2 ? 16'hffff : 16'h00ff) ||
            m_axis_tlast != (sink_index+beat_words == sink_m_count))
          $fatal(1, "FC8 packed INT8 result mismatch n=%0d m=%0d got=%h expected=%h",
              sink_n_base,sink_index,m_axis_tdata,expected_values[sink_index]);
        sink_index += beat_words; job_words += beat_words; total_words += beat_words;
        total_s2mm_beats++;
        if (m_axis_tlast) begin
          sink_received = 1;
          ack_delay = sink_n_base == 992 ? 100 : ((sink_n_base/8)%2 ? 35 : 0);
        end
      end
      if (sink_received && !ack_fire_q && !fault) begin
        commit_waits++;
        if (layer_done || parameter_request_valid || read_request_valid)
          $fatal(1, "controller advanced before real test sink committed output");
      end
      if (ack_fire_q) begin
        if (!sink_received) $fatal(1, "test completion before AXIS sink received last");
        sink_armed = 0; sink_received = 0; job_results++; total_results++;
        expected_n_base += 8;
      end
      if (layer_done && (job_results != 125 || job_words != 125*expected_m ||
          completed_n_tiles != 125 || completed_chunks != 625 ||
          completed_k_tokens != 512000 || completed_output_words != 125*expected_m ||
          job_chunks != 625 || job_input_transfers != 1250 || !dut.core_pipeline_idle ||
          dut.core_weight_bank_state != 0 || busy))
        $fatal(1, "FC8 layer completion/counter mismatch");
    end
  end
  initial begin #100000000; $fatal(1,"full FC layer watchdog phase=%0d n=%0d k=%0d",phase,active_n_base,active_k_offset); end
  task automatic tick(input int count = 1);
    repeat (count) @(negedge clk);
    #0.1;
  endtask
  task automatic reset_dut;
    rst = 1; job_valid = 0; service_error = 0; parameter_valid = 0;
    result_complete_valid = 0; result_complete_error = 0;
    inject_input_error = 0; inject_ack_error = 0;
    tick(6); rst = 0; expect_fault = 0; tick();
  endtask
  task automatic start_job(input int m, input int tag);
    expected_m = m; expected_job_tag = tag; expected_n_base = 0;
    expected_k_offset = 0; expected_chunk = 0;
    job_chunks = 0; job_input_transfers = 0; job_results = 0; job_words = 0;
    job_layer_id = 8; job_m_count = m; job_tag = tag; job_valid = 1;
    while (!job_ready) tick();
    tick(); job_valid = 0; job_layer_id = 'x; job_m_count = 'x; job_tag = 'x;
  endtask
  initial begin
    seed_init = $urandom(seed);
    reset_dut();
    expect_fault = 1; inject_input_error = 1; start_job(3,16'h7000);
    while (!layer_failed) tick();
    while (dut.core_dma_busy || source_active) tick();
    tick(10);
    if (!fault || fault_code != 3 || completed_chunks != 0 ||
        job_chunks != 0 || job_results != 0 || !dut.core_fault)
      $fatal(1, "malformed MM2S not drained/quarantined");
    reset_dut();
    start_job(1,16'h8000);
    while (!layer_done) tick();
    $display("FC8_FULL_NUMERICAL_PASS n=1000 k=4096 m=1 tiles=125 chunks=625 k_tokens=512000");
    tick(5);
    expect_fault = 1; inject_ack_error = 1; start_job(3,16'h9000);
    while (!layer_failed) tick();
    tick(20);
    if (!fault || fault_code != 4 || dut.core_fault || completed_n_tiles != 0 ||
        job_results != 1 || job_chunks != 5 || !dut.core_pipeline_idle || layer_done)
      $fatal(1, "bad result completion metadata escaped quarantine");
    reset_dut();
    tick(5);
    if (!job_ready || fault || failures != 2 || clean_layers != 1 ||
        total_chunks != 630 || total_k != 516096 || total_results != 126 ||
        total_words != 128 || total_inputs != 1261 ||
        output_stalls == 0 || ce_stalls == 0 || commit_waits < 100)
      $fatal(1,"full FC layer coverage mismatch chunks=%0d inputs=%0d results=%0d failures=%0d layers=%0d",
          total_chunks,total_inputs,total_results,failures,clean_layers);
    $display("ALEXNET_M4N8_FC_LAYER_DATAPATH_TEST_PASSED full_fc8_layers=%0d failures=%0d chunks=%0d k_tokens=%0d input_transfers=%0d mm2s_beats=%0d result_transfers=%0d result_words=%0d s2mm_beats=%0d parameter_tiles=%0d output_stalls=%0d ce_stalls=%0d commit_wait_checks=%0d seed=%0d",
        clean_layers,failures,total_chunks,total_k,total_inputs,total_mm2s_beats,total_results,
        total_words,total_s2mm_beats,checked_parameters,output_stalls,ce_stalls,commit_waits,seed);
    $finish;
  end
endmodule
