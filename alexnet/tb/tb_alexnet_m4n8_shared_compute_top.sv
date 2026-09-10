`timescale 1ns/1ps
module tb_alexnet_m4n8_shared_compute_top #(
    parameter int PHYS_ROWS = 2,
    parameter bit PERF_PROFILE = 1'b0
);
  logic clk = 0;
  always #2.5 clk = ~clk;
  logic bootstrap_rst = 1, phase_fc = 0, rs_run = 0, fc_run = 0;
  logic rs_test_done, fc_test_done;
  wire rst = bootstrap_rst || (phase_fc ? u_fc_test.rst : u_rs_test.rst);
  wire ce = phase_fc ? u_fc_test.ce : u_rs_test.ce;
  logic owner_valid = 1, owner_ready, owner_active, active_owner_fc;
  wire owner_fc = owner_active ? !phase_fc : phase_fc;
  logic manual_release = 0, owner_release_ready, owner_released, fault;
  wire probe_release = owner_active && (phase_fc ? u_fc_test.busy :
      (u_rs_test.transaction_active || u_rs_test.scheduler_busy));
  wire owner_release_valid = manual_release || probe_release;
  logic [127:0] m_axis_tdata;
  logic [15:0] m_axis_tkeep;
  logic m_axis_tvalid, m_axis_tlast, s_axis_tready;
  logic rs_activation_stream_ready;
  wire [127:0] s_axis_tdata = phase_fc ? u_fc_test.s_axis_tdata : u_rs_test.s_axis_tdata;
  wire [15:0] s_axis_tkeep = phase_fc ? u_fc_test.s_axis_tkeep : u_rs_test.s_axis_tkeep;
  wire s_axis_tvalid = phase_fc ? u_fc_test.s_axis_tvalid : u_rs_test.s_axis_tvalid;
  wire s_axis_tlast = phase_fc ? u_fc_test.s_axis_tlast : u_rs_test.s_axis_tlast;
  wire m_axis_tready = phase_fc ? u_fc_test.m_axis_tready : u_rs_test.m_axis_tready;
  assign u_rs_test.s_axis_tready = !phase_fc && s_axis_tready;
  assign u_fc_test.s_axis_tready = phase_fc && s_axis_tready;
  assign u_rs_test.m_axis_tvalid = !phase_fc && m_axis_tvalid;
  assign u_fc_test.m_axis_tvalid = phase_fc && m_axis_tvalid;
  assign u_rs_test.m_axis_tdata = m_axis_tdata;
  assign u_fc_test.m_axis_tdata = m_axis_tdata;
  assign u_rs_test.m_axis_tkeep = m_axis_tkeep;
  assign u_fc_test.m_axis_tkeep = m_axis_tkeep;
  assign u_rs_test.m_axis_tlast = m_axis_tlast;
  assign u_fc_test.m_axis_tlast = m_axis_tlast;

  shared_rs_test_driver u_rs_test(
      .clk(clk && rs_run), .run(rs_run), .profile_mode(PERF_PROFILE),
      .test_done(rs_test_done));
  shared_fc_test_driver u_fc_test(.clk(clk && fc_run), .run(fc_run), .test_done(fc_test_done));

  alexnet_m4n8_shared_compute_top #(
      .PHYS_ROWS(PHYS_ROWS)
  ) dut (
      .clk(clk), .rst(rst), .ce(ce),
      .owner_valid(owner_valid), .owner_ready(owner_ready), .owner_fc(owner_fc),
      .owner_release_valid(owner_release_valid), .owner_release_ready(owner_release_ready),
      .owner_active(owner_active), .active_owner_fc(active_owner_fc),
      .owner_released(owner_released), .fault(fault),
      .s_axis_tdata(s_axis_tdata), .s_axis_tkeep(s_axis_tkeep),
      .s_axis_tvalid(s_axis_tvalid), .s_axis_tready(s_axis_tready), .s_axis_tlast(s_axis_tlast),
      .rs_mm2s_request_valid(u_rs_test.rs_mm2s_request_valid),
      .rs_mm2s_request_ready(u_rs_test.rs_mm2s_request_ready),
      .rs_mm2s_request_destination(u_rs_test.rs_mm2s_request_destination),
      .rs_mm2s_request_word_count(u_rs_test.rs_mm2s_request_word_count),
      .rs_mm2s_request_byte_count(u_rs_test.rs_mm2s_request_byte_count),
      .rs_mm2s_request_tag(u_rs_test.rs_mm2s_request_tag),
      .rs_mm2s_request_n_base(u_rs_test.rs_mm2s_request_n_base),
      .rs_mm2s_request_chunk_index(u_rs_test.rs_mm2s_request_chunk_index),
      .rs_s2mm_request_valid(u_rs_test.rs_s2mm_request_valid),
      .rs_s2mm_request_ready(u_rs_test.rs_s2mm_request_ready),
      .rs_s2mm_request_word_count(u_rs_test.rs_s2mm_request_word_count),
      .rs_s2mm_request_byte_count(u_rs_test.rs_s2mm_request_byte_count),
      .rs_s2mm_request_n_base(u_rs_test.rs_s2mm_request_n_base),
      .rs_s2mm_request_tag(u_rs_test.rs_s2mm_request_tag),
      .rs_activation_stream_valid(1'b0),
      .rs_activation_stream_ready(rs_activation_stream_ready),
      .rs_activation_stream_values('0),
      .rs_activation_stream_lane_mask('0),
      .rs_activation_stream_last(1'b0),
      .m_axis_tdata(m_axis_tdata), .m_axis_tkeep(m_axis_tkeep),
      .m_axis_tvalid(m_axis_tvalid), .m_axis_tready(m_axis_tready), .m_axis_tlast(m_axis_tlast),
      .rs_cfg_valid(phase_fc ? 1'b1 : u_rs_test.cfg_valid),
      .rs_cfg_ready(u_rs_test.cfg_ready),
      .rs_cfg_destination(u_rs_test.cfg_destination),
      .rs_cfg_n64_tile_base(u_rs_test.cfg_n64_tile_base),
      .rs_cfg_slice_index(3'd1),
      .rs_cfg_lane_mask(u_rs_test.cfg_lane_mask),
      .rs_cfg_bias(u_rs_test.cfg_bias),
      .rs_cfg_multiplier(u_rs_test.cfg_multiplier),
      .rs_cfg_right_shift(u_rs_test.cfg_right_shift),
      .rs_cfg_relu(u_rs_test.cfg_relu),
      .rs_command_valid(phase_fc ? 1'b1 : u_rs_test.command_valid),
      .rs_command_ready(u_rs_test.command_ready),
      .rs_command_id(u_rs_test.command_id),
      .rs_command_activation_streaming(1'b0),
      .rs_command_activation_destination(u_rs_test.command_activation_destination),
      .rs_command_activation_word_count(u_rs_test.command_activation_word_count),
      .rs_command_activation_byte_count(u_rs_test.command_activation_byte_count),
      .rs_command_activation_lane_mask(u_rs_test.command_activation_lane_mask),
      .rs_command_activation_tensor_tag(u_rs_test.command_activation_tensor_tag),
      .rs_command_weight_word_count(u_rs_test.command_weight_word_count),
      .rs_command_weight_byte_count(u_rs_test.command_weight_byte_count),
      .rs_command_weight_lane_mask(u_rs_test.command_weight_lane_mask),
      .rs_command_weight_context_tag(u_rs_test.command_weight_context_tag),
      .rs_command_result_enable(u_rs_test.command_result_enable),
      .rs_command_result_word_count(
          13'(u_rs_test.command_result_word_count)),
      .rs_command_result_byte_count(u_rs_test.command_result_byte_count),
      .rs_command_result_destination(u_rs_test.command_result_destination),
      .rs_command_result_slice(u_rs_test.command_result_slice),
      .rs_command_result_n_base(u_rs_test.command_result_n_base),
      .rs_command_result_lane_mask(u_rs_test.command_result_lane_mask),
      .rs_command_result_first_tile_tag(u_rs_test.command_result_first_tile_tag),
      .rs_command_chunk_input_h(u_rs_test.command_chunk_input_h),
      .rs_command_chunk_input_w(u_rs_test.command_chunk_input_w),
      .rs_command_chunk_channel_count(u_rs_test.command_chunk_channel_count),
      .rs_command_chunk_input_lane_mask(u_rs_test.command_chunk_input_lane_mask),
      .rs_command_chunk_kernel(u_rs_test.command_chunk_kernel),
      .rs_command_chunk_stride(u_rs_test.command_chunk_stride),
      .rs_command_chunk_padding(u_rs_test.command_chunk_padding),
      .rs_command_chunk_k_count(u_rs_test.command_chunk_k_count),
      .rs_command_chunk_weight_context_tag(u_rs_test.command_chunk_weight_context_tag),
      .rs_command_chunk_word_count(
          13'(u_rs_test.command_chunk_word_count)),
      .rs_command_chunk_output_width(u_rs_test.command_chunk_output_width),
      .rs_command_chunk_accum_context_tag(u_rs_test.command_chunk_accum_context_tag),
      .rs_command_chunk_tile_tag_base(u_rs_test.command_chunk_tile_tag_base),
      .rs_command_chunk_index(u_rs_test.command_chunk_index),
      .rs_command_chunk_first(u_rs_test.command_chunk_first),
      .rs_command_chunk_final(u_rs_test.command_chunk_final),
      .rs_clear_fault(u_rs_test.clear_fault),
      .rs_scheduler_busy(u_rs_test.scheduler_busy),
      .rs_scheduler_fault(u_rs_test.scheduler_fault),
      .rs_scheduler_fault_code(u_rs_test.scheduler_fault_code),
      .rs_scheduler_phase(u_rs_test.scheduler_phase),
      .rs_command_done(u_rs_test.command_done),
      .rs_command_rejected(u_rs_test.command_rejected),
      .rs_fault_cleared(u_rs_test.fault_cleared),
      .rs_command_error(u_rs_test.command_error),
      .rs_active_command_id(u_rs_test.active_command_id),
      .rs_completed_command_id(u_rs_test.completed_command_id),
      .rs_accepted_commands(u_rs_test.accepted_commands),
      .rs_completed_commands(u_rs_test.completed_commands),
      .rs_rejected_commands(u_rs_test.rejected_commands),
      .rs_configured(u_rs_test.configured),
      .rs_chunk_frame_active(u_rs_test.chunk_frame_active),
      .rs_chunk_done(u_rs_test.chunk_done),
      .rs_chunk_rejected(u_rs_test.chunk_rejected),
      .rs_compute_busy(u_rs_test.compute_busy),
      .rs_transaction_active(u_rs_test.transaction_active),
      .rs_accum_chunk_active(u_rs_test.accum_chunk_active),
      .rs_transaction_done(u_rs_test.transaction_done),
      .rs_pipeline_idle(u_rs_test.pipeline_idle),
      .rs_datapath_pipeline_idle(u_rs_test.datapath_pipeline_idle),
      .rs_protocol_error(u_rs_test.protocol_error),
      .rs_datapath_protocol_error(u_rs_test.datapath_protocol_error),
      .rs_activation_context_error(u_rs_test.activation_context_error),
      .rs_accum_context_error(u_rs_test.accum_context_error),
      .rs_weight_context_error(u_rs_test.weight_context_error),
      .rs_completed_tile_count(u_rs_test.completed_tile_count),
      .rs_completed_weight_replays(u_rs_test.completed_weight_replays),
      .rs_weight_bank_state(u_rs_test.weight_bank_state),
      .rs_weight_resident_valid(u_rs_test.weight_resident_valid),
      .rs_resident_weight_k_count(u_rs_test.resident_weight_k_count),
      .rs_resident_weight_words_written(u_rs_test.resident_weight_words_written),
      .rs_resident_weight_n_lane_mask(u_rs_test.resident_weight_n_lane_mask),
      .rs_resident_weight_context_tag(u_rs_test.resident_weight_context_tag),
      .rs_weight_replay_done(u_rs_test.weight_replay_done),
      .rs_accum_bank_state(u_rs_test.accum_bank_state),
      .rs_queued_count(u_rs_test.queued_count),
      .rs_activation_ready_tensor_valid(u_rs_test.activation_ready_tensor_valid),
      .rs_activation_ready_tensor_bank(u_rs_test.activation_ready_tensor_bank),
      .rs_activation_ready_tensor_tag(u_rs_test.activation_ready_tensor_tag),
      .rs_activation_ready_count(u_rs_test.activation_ready_count),
      .rs_activation_fill_active(u_rs_test.activation_fill_active),
      .rs_activation_fill_bank(u_rs_test.activation_fill_bank),
      .rs_activation_read_active(u_rs_test.activation_read_active),
      .rs_activation_read_bank(u_rs_test.activation_read_bank),
      .rs_activation_read_segment(u_rs_test.activation_read_segment),
      .rs_activation_read_done(u_rs_test.activation_read_done),
      .rs_activation_words_forwarded(u_rs_test.activation_words_forwarded),
      .rs_dma_busy(u_rs_test.dma_busy),
      .rs_dma_transfer_active(u_rs_test.dma_transfer_active),
      .rs_dma_transfer_done(u_rs_test.dma_transfer_done),
      .rs_dma_descriptor_rejected(u_rs_test.dma_descriptor_rejected),
      .rs_dma_descriptor_error(u_rs_test.dma_descriptor_error),
      .rs_dma_stream_error(u_rs_test.dma_stream_error),
      .rs_dma_protocol_error(u_rs_test.dma_protocol_error),
      .rs_dma_active_destination(u_rs_test.dma_active_destination),
      .rs_dma_words_transferred(u_rs_test.dma_words_transferred),
      .rs_dma_completed_transfers(u_rs_test.dma_completed_transfers),
      .rs_result_dma_busy(u_rs_test.result_dma_busy),
      .rs_result_dma_transfer_active(u_rs_test.result_dma_transfer_active),
      .rs_result_dma_transfer_done(u_rs_test.result_dma_transfer_done),
      .rs_result_dma_descriptor_rejected(u_rs_test.result_dma_descriptor_rejected),
      .rs_result_dma_descriptor_error(u_rs_test.result_dma_descriptor_error),
      .rs_result_dma_metadata_error(u_rs_test.result_dma_metadata_error),
      .rs_result_dma_protocol_error(u_rs_test.result_dma_protocol_error),
      .rs_result_dma_active_destination(u_rs_test.result_dma_active_destination),
      .rs_result_dma_active_slice(u_rs_test.result_dma_active_slice),
      .rs_result_dma_active_n_base(u_rs_test.result_dma_active_n_base),
      .rs_result_dma_active_lane_mask(u_rs_test.result_dma_active_lane_mask),
      .rs_result_dma_active_first_tile_tag(u_rs_test.result_dma_active_first_tile_tag),
      .rs_result_dma_words_accepted(u_rs_test.result_dma_words_accepted),
      .rs_result_dma_words_transferred(u_rs_test.result_dma_words_transferred),
      .rs_result_dma_beats_transferred(u_rs_test.result_dma_beats_transferred),
      .rs_result_dma_completed_transfers(u_rs_test.result_dma_completed_transfers),
      .rs_result_dma_completed_first_tile_tag(u_rs_test.result_dma_completed_first_tile_tag),
      .rs_result_dma_completed_last_tile_tag(u_rs_test.result_dma_completed_last_tile_tag),
      .fc_job_valid(phase_fc ? u_fc_test.job_valid : 1'b1),
      .fc_job_ready(u_fc_test.job_ready),
      .fc_job_layer_id(u_fc_test.job_layer_id),
      .fc_job_m_count(u_fc_test.job_m_count),
      .fc_job_tag(u_fc_test.job_tag),
      .fc_parameter_request_valid(u_fc_test.parameter_request_valid),
      .fc_active_layer_id(u_fc_test.active_layer_id),
      .fc_active_m_count(u_fc_test.active_m_count),
      .fc_active_job_tag(u_fc_test.active_job_tag),
      .fc_active_n_base(u_fc_test.active_n_base),
      .fc_active_k_offset(u_fc_test.active_k_offset),
      .fc_active_k_count(u_fc_test.active_k_count),
      .fc_parameter_valid(u_fc_test.parameter_valid),
      .fc_parameter_ready(u_fc_test.parameter_ready),
      .fc_parameter_layer_id(u_fc_test.parameter_layer_id),
      .fc_parameter_job_tag(u_fc_test.parameter_job_tag),
      .fc_parameter_n_base(u_fc_test.parameter_n_base),
      .fc_parameter_bias(u_fc_test.parameter_bias),
      .fc_parameter_multiplier(u_fc_test.parameter_multiplier),
      .fc_parameter_right_shift(u_fc_test.parameter_right_shift),
      .fc_read_request_valid(u_fc_test.read_request_valid),
      .fc_read_request_ready(u_fc_test.read_request_ready),
      .fc_read_request_destination(u_fc_test.read_request_destination),
      .fc_read_request_word_count(u_fc_test.read_request_word_count),
      .fc_read_request_byte_count(u_fc_test.read_request_byte_count),
      .fc_read_request_m_count(u_fc_test.read_request_m_count),
      .fc_read_request_tag(u_fc_test.read_request_tag),
      .fc_result_request_valid(u_fc_test.result_request_valid),
      .fc_result_request_ready(u_fc_test.result_request_ready),
      .fc_result_request_destination(u_fc_test.result_request_destination),
      .fc_result_request_byte_count(u_fc_test.result_request_byte_count),
      .fc_result_request_tag(u_fc_test.result_request_tag),
      .fc_result_complete_valid(u_fc_test.result_complete_valid),
      .fc_result_complete_ready(u_fc_test.result_complete_ready),
      .fc_result_complete_n_base(u_fc_test.result_complete_n_base),
      .fc_result_complete_tag(u_fc_test.result_complete_tag),
      .fc_result_complete_error(u_fc_test.result_complete_error),
      .fc_service_error(u_fc_test.service_error),
      .fc_busy(u_fc_test.busy),
      .fc_layer_done(u_fc_test.layer_done),
      .fc_job_rejected(u_fc_test.job_rejected),
      .fc_layer_failed(u_fc_test.layer_failed),
      .fc_fault(u_fc_test.fault),
      .fc_fault_code(u_fc_test.fault_code),
      .fc_phase(u_fc_test.phase),
      .fc_completed_n_tiles(u_fc_test.completed_n_tiles),
      .fc_completed_chunks(u_fc_test.completed_chunks),
      .fc_completed_k_tokens(u_fc_test.completed_k_tokens),
      .fc_completed_output_words(u_fc_test.completed_output_words)
  );

  int blocked_release_cycles = 0, fc_commit_block_cycles = 0;
  int idle_sum_block_cycles = 0, clean_handoffs = 0;
  bit fc_clean_seen = 0;
  bit pe_profile_active = 0;
  bit pe_compute_window = 0;
  longint pe_command_cycles = 0;
  longint pe_compute_cycles = 0;
  longint pe_issue_cycles = 0;
  longint pe_useful_cell_cycles = 0;
  longint pe_source_starve_cycles = 0;
  longint pe_issue_block_cycles = 0;
  longint pe_ce_stall_cycles = 0;
  longint pe_post_reduce_cycles = 0;
  longint pe_intertile_cycles = 0;
  longint pe_other_cycles = 0;
  longint pe_dma_active_cycles = 0;
  longint pe_egress_block_cycles = 0;
  int pe_n_lanes = 8;
  real pe_issue_duty_pct;
  real pe_util_pct;
  always @(posedge clk) begin : pe_utilization_monitor
    int active_m_lanes;
    if (rst) begin
      pe_profile_active = 0;
      pe_compute_window = 0;
    end else if (PERF_PROFILE && !phase_fc) begin
      if (u_rs_test.command_valid && u_rs_test.command_ready &&
          u_rs_test.command_id == 16'h0100) begin
        pe_profile_active = 1;
        pe_compute_window = 0;
        pe_command_cycles = 0;
        pe_compute_cycles = 0;
        pe_issue_cycles = 0;
        pe_useful_cell_cycles = 0;
        pe_source_starve_cycles = 0;
        pe_issue_block_cycles = 0;
        pe_ce_stall_cycles = 0;
        pe_post_reduce_cycles = 0;
        pe_intertile_cycles = 0;
        pe_other_cycles = 0;
        pe_dma_active_cycles = 0;
        pe_egress_block_cycles = 0;
        pe_n_lanes = 8;
      end
      if (pe_profile_active) begin
        pe_command_cycles = pe_command_cycles + 1;
        if (u_rs_test.dma_transfer_active)
          pe_dma_active_cycles = pe_dma_active_cycles + 1;
        if (dut.bus_shared_egress_valid && !dut.bus_shared_egress_ready)
          pe_egress_block_cycles = pe_egress_block_cycles + 1;
        if (dut.rs_shared_chunk_valid && dut.rs_shared_chunk_ready) begin
          pe_compute_window = 1;
          pe_n_lanes = $countones(dut.rs_shared_chunk_n_lane_mask);
        end
        if (pe_compute_window) begin
          pe_compute_cycles = pe_compute_cycles + 1;
          if (!ce) begin
            pe_ce_stall_cycles = pe_ce_stall_cycles + 1;
          end else if (dut.bus_shared_issue_valid &&
                       dut.bus_shared_issue_ready) begin
            active_m_lanes = 0;
            for (int g = 0; g < PHYS_ROWS; g++)
              active_m_lanes = active_m_lanes +
                  dut.u_shared.m_lane_mask_q[g][0] +
                  dut.u_shared.m_lane_mask_q[g][1];
            pe_issue_cycles = pe_issue_cycles + 1;
            pe_useful_cell_cycles = pe_useful_cell_cycles +
                                    active_m_lanes * pe_n_lanes;
          end else if (dut.u_shared.tile_active_q &&
                       dut.u_shared.issue_open_q) begin
            if (dut.bus_shared_issue_valid)
              pe_issue_block_cycles = pe_issue_block_cycles + 1;
            else
              pe_source_starve_cycles = pe_source_starve_cycles + 1;
          end else if (dut.u_shared.tile_active_q) begin
            pe_post_reduce_cycles = pe_post_reduce_cycles + 1;
          end else if (dut.bus_shared_chunk_active) begin
            pe_intertile_cycles = pe_intertile_cycles + 1;
          end else begin
            pe_other_cycles = pe_other_cycles + 1;
          end
        end
        if (dut.rs_shared_chunk_done) begin
          pe_compute_window = 0;
          pe_profile_active = 0;
          pe_issue_duty_pct = 100.0 * pe_issue_cycles /
                              pe_compute_cycles;
          pe_util_pct = 100.0 * pe_useful_cell_cycles /
                        (pe_compute_cycles * PHYS_ROWS * 2 * 8);
          if (pe_compute_cycles != pe_issue_cycles +
                  pe_source_starve_cycles + pe_issue_block_cycles +
                  pe_ce_stall_cycles + pe_post_reduce_cycles +
                  pe_intertile_cycles + pe_other_cycles)
            $fatal(1, "PE profile cycle accounting mismatch");
          $display(
              "ALEXNET_M8N8_SHARED_PE_PROFILE command_cycles=%0d dma_active_cycles=%0d compute_cycles=%0d issue_cycles=%0d source_starve_cycles=%0d issue_block_cycles=%0d ce_stall_cycles=%0d post_reduce_cycles=%0d intertile_cycles=%0d other_cycles=%0d egress_block_cycles=%0d useful_cell_cycles=%0d issue_duty_pct=%0.3f pe_util_pct=%0.3f",
              pe_command_cycles, pe_dma_active_cycles, pe_compute_cycles,
              pe_issue_cycles, pe_source_starve_cycles,
              pe_issue_block_cycles, pe_ce_stall_cycles,
              pe_post_reduce_cycles, pe_intertile_cycles, pe_other_cycles,
              pe_egress_block_cycles, pe_useful_cell_cycles,
              pe_issue_duty_pct, pe_util_pct);
        end
      end
    end
  end
  always @(posedge clk) if (!rst && owner_active) begin
    if (owner_ready) $fatal(1, "acquire allowed during an active owner");
    if (active_owner_fc != phase_fc) $fatal(1, "unrequested mode change");
    if (probe_release) begin
      blocked_release_cycles++;
      if (owner_release_ready) $fatal(1, "release accepted during owned work");
    end
    if (!phase_fc && u_rs_test.transaction_active && !u_rs_test.scheduler_busy) begin
      idle_sum_block_cycles++;
      if (owner_release_ready) $fatal(1, "release allowed with resident partial sums");
    end
    if (phase_fc && dut.u_fc.busy && dut.u_fc.core_pipeline_idle) begin
      fc_commit_block_cycles++;
      if (owner_release_ready) $fatal(1, "release allowed before layer commit");
    end
    if (!phase_fc && dut.u_fc.busy) $fatal(1, "inactive FC accepted poison job");
    if (phase_fc && dut.u_rs.scheduler_busy) $fatal(1, "inactive RS accepted poison command");
    if (phase_fc && u_fc_test.layer_done && !fc_clean_seen) begin
      if (u_fc_test.reset_calls != 1) $fatal(1, "FC numerical test did not follow Conv without reset");
      fc_clean_seen = 1;
    end
  end
  task automatic release_owner;
    owner_valid = 0;
    manual_release = 1;
    while (!owner_release_ready) @(negedge clk);
    @(negedge clk);
    if (owner_active || !owner_released) $fatal(1, "owner release did not retire");
    manual_release = 0;
  endtask
  initial begin
    repeat (3) @(negedge clk);
    rs_run = 1;
    @(negedge clk);
    bootstrap_rst = 0;
    wait(rs_test_done);
    @(negedge clk);
    rs_run = 0;
    if (PERF_PROFILE) begin
      if (pe_issue_cycles == 0 || pe_compute_window || pe_profile_active ||
          fault)
        $fatal(1, "M8 PE utilization profile did not complete cleanly");
      $display("ALEXNET_M8N8_SHARED_PE_PROFILE_PASS");
      $finish;
    end
    release_owner();
    // No reset occurs here: replace a completed Conv owner with a clean FC8.
    phase_fc = 1;
    fc_run = 1;
    owner_valid = 1;
    clean_handoffs++;
    wait(fc_test_done);
    @(negedge clk);
    fc_run = 0;
    release_owner();
    if (!fc_clean_seen || fault || blocked_release_cycles < 1000 ||
        idle_sum_block_cycles == 0 || fc_commit_block_cycles < 100)
      $fatal(1, "shared top coverage incomplete");
    if (PHYS_ROWS == 4)
      $display("ALEXNET_M8N8_SHARED_COMPUTE_TOP_TEST_PASSED sa_instances=1 conv_chunks=2 full_fc8=1 clean_handoffs=%0d blocked_release_cycles=%0d partial_sum_wait_cycles=%0d fc_commit_wait_cycles=%0d",
          clean_handoffs, blocked_release_cycles, idle_sum_block_cycles,
          fc_commit_block_cycles);
    else
      $display("ALEXNET_M4N8_SHARED_COMPUTE_TOP_TEST_PASSED sa_instances=1 conv_chunks=2 full_fc8=1 clean_handoffs=%0d blocked_release_cycles=%0d partial_sum_wait_cycles=%0d fc_commit_wait_cycles=%0d",
          clean_handoffs, blocked_release_cycles, idle_sum_block_cycles,
          fc_commit_block_cycles);
    $finish;
  end
  initial begin #200000000; $fatal(1, "shared top watchdog"); end
endmodule
