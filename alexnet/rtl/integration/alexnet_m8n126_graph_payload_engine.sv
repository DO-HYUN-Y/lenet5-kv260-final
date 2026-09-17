`timescale 1ns/1ps

// Batch-one Conv1..FC8 descriptor/payload integration boundary.
//
// The graph scheduler owns M/N/K ordering.  For every descriptor this engine
// optionally fills a resident N128 weight set, fills one transposed M16 patch,
// atomically starts both replays and the dynamic-array payload, retires all
// postprocessed N8 slices, and releases the weight set at its final reuse.
//
// Patch data is deliberately exposed as a scheduled K-major M16 stream.  This
// is the stable boundary shared by the verified x-mod-4 raster assembler and
// a later direct DDR patch DMA; it avoids coupling compute correctness to one
// external memory policy.
module alexnet_m8n126_graph_payload_engine #(
    parameter int SERVICE_TIMEOUT_CYCLES = 32'h0100_0000
) (
    input logic clk,
    input logic rst,

    input  logic start_valid,
    output logic start_ready,
    input  logic [15:0] start_tag,

    output logic weight_request_valid,
    input  logic weight_request_ready,
    output logic [3:0] weight_request_layer_id,
    output logic [15:0] weight_request_n_base,
    output logic [13:0] weight_request_k_offset,
    output logic [12:0] weight_request_k_count,
    output logic [7:0] weight_request_bank_enable,
    output logic [15:0] weight_request_n_lane_mask [0:7],
    output logic [15:0] weight_request_context_tag,
    input  logic weight_axis_valid,
    output logic weight_axis_ready,
    input  logic [127:0] weight_axis_data,
    input  logic weight_axis_last,

    output logic patch_request_valid,
    input  logic patch_request_ready,
    output logic [3:0] patch_request_layer_id,
    output logic [12:0] patch_request_m_base,
    output logic [13:0] patch_request_k_offset,
    output logic [12:0] patch_request_k_count,
    output logic [15:0] patch_request_m_lane_mask,
    output logic [15:0] patch_request_context_tag,
    input  logic patch_axis_valid,
    output logic patch_axis_ready,
    input  logic [127:0] patch_axis_data,
    input  logic patch_axis_last,

    output logic parameter_request_valid,
    input  logic parameter_request_ready,
    output logic [3:0] parameter_request_layer_id,
    output logic [15:0] parameter_request_n_base,
    output logic [15:0] parameter_request_context_tag,
    input  logic parameter_valid,
    output logic parameter_ready,
    input  logic [15:0] parameter_n_base,
    input  logic [15:0] parameter_context_tag,
    input  logic signed [31:0] parameter_bias [0:7],
    input  logic signed [17:0] parameter_multiplier [0:7],
    input  logic [5:0] parameter_right_shift [0:7],
    input  logic [7:0] parameter_relu,

    output logic result_valid,
    input  logic result_ready,
    output logic [63:0] result_values [0:7],
    output logic [7:0] result_lane_mask [0:7],
    output logic [3:0] result_m_count,
    output logic [12:0] result_m_base,
    output logic [15:0] result_n_base,
    output logic [15:0] result_tile_tag,
    output logic result_last_slice,

    output logic layer_complete_valid,
    input  logic layer_complete_ready,
    output logic [3:0] layer_complete_id,
    output logic layer_complete_requires_pool,

    output logic busy,
    output logic inference_done,
    output logic inference_failed,
    output logic fault,
    output logic [3:0] active_layer_id,
    output logic [15:0] completed_commands,
    output logic [31:0] active_cycles,
    output logic [31:0] issue_cycles,
    output logic [31:0] patch_stall_cycles,
    output logic [31:0] weight_stall_cycles,
    output logic [31:0] result_stall_cycles,
    output logic [31:0] weight_words_loaded,
    output logic [31:0] patch_words_loaded,
    output logic [31:0] completed_result_slices,
    output logic [63:0] useful_mac_count,
    output logic [63:0] physical_mac_slot_count
);

  typedef enum logic [3:0] {
    ST_IDLE,
    ST_WEIGHT_DESC,
    ST_WEIGHT_DATA,
    ST_PATCH_DESC,
    ST_PATCH_DATA,
    ST_LAUNCH,
    ST_PAYLOAD,
    ST_RELEASE,
    ST_FAIL
  } state_t;

  state_t state_q;
  logic engine_fault_q;
  logic [31:0] service_timeout_q;

  logic scheduler_command_valid, scheduler_command_ready;
  logic [3:0] scheduler_command_layer_id;
  logic scheduler_command_is_fc, scheduler_command_mode_split_n64;
  logic [7:0] scheduler_command_bank_enable;
  logic [15:0] scheduler_command_n_lane_mask [0:7];
  logic [15:0] scheduler_command_n_base;
  logic [7:0] scheduler_command_n_count;
  logic [12:0] scheduler_command_m_base;
  logic [4:0] scheduler_command_m_count;
  logic [3:0] scheduler_command_group0_m_count;
  logic [3:0] scheduler_command_group1_m_count;
  logic [13:0] scheduler_command_k_offset;
  logic [12:0] scheduler_command_k_count;
  logic scheduler_command_accum_first, scheduler_command_accum_final;
  logic scheduler_command_weight_fill, scheduler_command_weight_release;
  logic scheduler_command_result_enable;
  logic [15:0] scheduler_command_context_tag;
  logic [15:0] scheduler_command_tile_tag;
  logic scheduler_command_done_q, scheduler_command_error_q;
  logic scheduler_busy, scheduler_fault;

  logic [3:0] layer_id_q;
  logic mode_split_q;
  logic [7:0] bank_enable_q;
  logic [15:0] n_lane_mask_q [0:7];
  logic [15:0] n_base_q;
  logic [7:0] n_count_q;
  logic [12:0] m_base_q;
  logic [3:0] group_m_count_q [0:1];
  logic [13:0] k_offset_q;
  logic [12:0] k_count_q;
  logic accum_first_q, accum_final_q;
  logic weight_fill_q, weight_release_q, result_enable_q;
  logic [15:0] weight_context_tag_q, patch_context_tag_q, tile_tag_q;
  logic [7:0] service_bank_enable_q;
  logic [15:0] service_n_lane_mask_q [0:7];
  logic [15:0] patch_m_lane_mask_q;

  logic weight_fill_valid, weight_fill_ready;
  logic weight_write_ready;
  logic weight_replay_valid, weight_replay_ready;
  logic weight_valid, weight_ready;
  logic signed [7:0] weight_values [0:7][0:15];
  logic [11:0] weight_k;
  logic weight_last;
  logic [7:0] weight_bank_enable;
  logic [15:0] weight_n_lane_mask [0:7];
  logic [15:0] weight_context_tag;
  logic weight_release_valid, weight_release_ready;
  logic [1:0] weight_set_state [0:1];
  logic [1:0] weight_ready_set_mask;
  logic weight_fill_active, weight_active_fill_set;
  logic weight_replay_active, weight_active_replay_set;
  logic [15:0] weight_words_written;
  logic [15:0] weight_completed_fills, weight_completed_replays;
  logic weight_fill_done, weight_replay_done;
  logic weight_context_error, weight_protocol_error, weight_idle;

  logic patch_fill_valid, patch_fill_ready;
  logic patch_write_ready;
  logic patch_replay_valid, patch_replay_ready;
  logic patch_valid, patch_ready;
  logic signed [7:0] patch_values [0:15];
  logic [11:0] patch_k;
  logic patch_last;
  logic [15:0] patch_m_lane_mask, patch_context_tag;
  logic [1:0] patch_set_state [0:1];
  logic [1:0] patch_ready_set_mask;
  logic patch_fill_active, patch_active_fill_set;
  logic patch_replay_active, patch_active_replay_set;
  logic [12:0] patch_words_written;
  logic [15:0] patch_completed_fills, patch_completed_replays;
  logic patch_fill_done, patch_replay_done;
  logic patch_context_error, patch_protocol_error, patch_idle;

  logic payload_command_valid, payload_command_ready;
  logic payload_done, payload_error, payload_busy, accumulator_open;
  logic payload_fault;
  logic launch_fire;

  assign scheduler_command_ready = state_q == ST_IDLE && !fault;
  assign busy = scheduler_busy || state_q != ST_IDLE;
  assign fault = engine_fault_q || scheduler_fault || payload_fault ||
                 weight_context_error || weight_protocol_error ||
                 patch_context_error || patch_protocol_error;

  assign weight_request_valid = state_q == ST_WEIGHT_DESC &&
                                weight_fill_ready;
  assign weight_fill_valid = state_q == ST_WEIGHT_DESC &&
                             weight_request_ready;
  assign weight_axis_ready = state_q == ST_WEIGHT_DATA &&
                             weight_write_ready;
  assign weight_request_layer_id = layer_id_q;
  assign weight_request_n_base = n_base_q;
  assign weight_request_k_offset = k_offset_q;
  assign weight_request_k_count = k_count_q;
  assign weight_request_bank_enable = service_bank_enable_q;
  assign weight_request_context_tag = weight_context_tag_q;

  assign patch_request_valid = state_q == ST_PATCH_DESC && patch_fill_ready;
  assign patch_fill_valid = state_q == ST_PATCH_DESC && patch_request_ready;
  assign patch_axis_ready = state_q == ST_PATCH_DATA && patch_write_ready;
  assign patch_request_layer_id = layer_id_q;
  assign patch_request_m_base = m_base_q;
  assign patch_request_k_offset = k_offset_q;
  assign patch_request_k_count = k_count_q;
  assign patch_request_m_lane_mask = patch_m_lane_mask_q;
  assign patch_request_context_tag = patch_context_tag_q;

  assign payload_command_valid = state_q == ST_LAUNCH &&
      patch_replay_ready && weight_replay_ready;
  assign patch_replay_valid = state_q == ST_LAUNCH &&
      payload_command_ready && weight_replay_ready;
  assign weight_replay_valid = state_q == ST_LAUNCH &&
      payload_command_ready && patch_replay_ready;
  assign launch_fire = payload_command_valid && payload_command_ready &&
                       patch_replay_valid && patch_replay_ready &&
                       weight_replay_valid && weight_replay_ready;
  assign weight_release_valid = state_q == ST_RELEASE;

  always_comb begin
    patch_m_lane_mask_q = '0;
    for (int lane = 0; lane < 8; lane++) begin
      patch_m_lane_mask_q[lane] = lane < group_m_count_q[0];
      patch_m_lane_mask_q[lane+8] = lane < group_m_count_q[1];
    end
    for (int bank = 0; bank < 8; bank++) begin
      weight_request_n_lane_mask[bank] = service_n_lane_mask_q[bank];
    end
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      state_q <= ST_IDLE;
      engine_fault_q <= 1'b0;
      service_timeout_q <= '0;
      scheduler_command_done_q <= 1'b0;
      scheduler_command_error_q <= 1'b0;
      layer_id_q <= '0;
      mode_split_q <= 1'b0;
      bank_enable_q <= '0;
      n_base_q <= '0;
      n_count_q <= '0;
      m_base_q <= '0;
      group_m_count_q[0] <= '0;
      group_m_count_q[1] <= '0;
      k_offset_q <= '0;
      k_count_q <= '0;
      accum_first_q <= 1'b0;
      accum_final_q <= 1'b0;
      weight_fill_q <= 1'b0;
      weight_release_q <= 1'b0;
      result_enable_q <= 1'b0;
      weight_context_tag_q <= '0;
      patch_context_tag_q <= '0;
      tile_tag_q <= '0;
      service_bank_enable_q <= '0;
      weight_words_loaded <= '0;
      patch_words_loaded <= '0;
      completed_result_slices <= '0;
      for (int bank = 0; bank < 8; bank++) begin
        n_lane_mask_q[bank] <= '0;
        service_n_lane_mask_q[bank] <= '0;
      end
    end else begin
      scheduler_command_done_q <= 1'b0;
      scheduler_command_error_q <= 1'b0;

      if (state_q == ST_IDLE)
        service_timeout_q <= '0;
      else if (service_timeout_q != SERVICE_TIMEOUT_CYCLES)
        service_timeout_q <= service_timeout_q + 1'b1;

      if (weight_axis_valid && weight_axis_ready)
        weight_words_loaded <= weight_words_loaded + 1'b1;
      if (patch_axis_valid && patch_axis_ready)
        patch_words_loaded <= patch_words_loaded + 1'b1;
      if (result_valid && result_ready)
        completed_result_slices <= completed_result_slices + 1'b1;

      if (scheduler_command_valid && scheduler_command_ready) begin
        layer_id_q <= scheduler_command_layer_id;
        mode_split_q <= scheduler_command_mode_split_n64;
        bank_enable_q <= scheduler_command_bank_enable;
        n_base_q <= scheduler_command_n_base;
        n_count_q <= scheduler_command_n_count;
        m_base_q <= scheduler_command_m_base;
        group_m_count_q[0] <= scheduler_command_group0_m_count;
        group_m_count_q[1] <= scheduler_command_group1_m_count;
        k_offset_q <= scheduler_command_k_offset;
        k_count_q <= scheduler_command_k_count;
        accum_first_q <= scheduler_command_accum_first;
        accum_final_q <= scheduler_command_accum_final;
        weight_fill_q <= scheduler_command_weight_fill;
        weight_release_q <= scheduler_command_weight_release;
        result_enable_q <= scheduler_command_result_enable;
        weight_context_tag_q <= scheduler_command_context_tag;
        patch_context_tag_q <= scheduler_command_tile_tag ^
                               {2'b00, scheduler_command_k_offset};
        tile_tag_q <= scheduler_command_tile_tag;
        service_bank_enable_q <= scheduler_command_mode_split_n64 ?
                                 (scheduler_command_bank_enable & 8'h0f) :
                                 scheduler_command_bank_enable;
        for (int bank = 0; bank < 8; bank++) begin
          n_lane_mask_q[bank] <= scheduler_command_n_lane_mask[bank];
          if (scheduler_command_mode_split_n64 && bank >= 4)
            service_n_lane_mask_q[bank] <= '0;
          else
            service_n_lane_mask_q[bank] <=
                scheduler_command_n_lane_mask[bank];
        end
        state_q <= scheduler_command_weight_fill ? ST_WEIGHT_DESC :
                                                    ST_PATCH_DESC;
      end

      case (state_q)
        ST_WEIGHT_DESC: if (weight_request_valid && weight_request_ready)
          state_q <= ST_WEIGHT_DATA;

        ST_WEIGHT_DATA: if (weight_fill_done)
          state_q <= ST_PATCH_DESC;

        ST_PATCH_DESC: if (patch_request_valid && patch_request_ready)
          state_q <= ST_PATCH_DATA;

        ST_PATCH_DATA: if (patch_fill_done)
          state_q <= ST_LAUNCH;

        ST_LAUNCH: if (launch_fire)
          state_q <= ST_PAYLOAD;

        ST_PAYLOAD: if (payload_done) begin
          if (payload_error || payload_fault) begin
            engine_fault_q <= 1'b1;
            scheduler_command_done_q <= 1'b1;
            scheduler_command_error_q <= 1'b1;
            state_q <= ST_FAIL;
          end else if (weight_release_q) begin
            state_q <= ST_RELEASE;
          end else begin
            scheduler_command_done_q <= 1'b1;
            state_q <= ST_IDLE;
          end
        end

        ST_RELEASE: if (weight_release_valid && weight_release_ready) begin
          scheduler_command_done_q <= 1'b1;
          state_q <= ST_IDLE;
        end

        ST_FAIL: state_q <= ST_FAIL;

        default: ;
      endcase

      if (state_q != ST_IDLE && service_timeout_q ==
          SERVICE_TIMEOUT_CYCLES-1) begin
        engine_fault_q <= 1'b1;
        scheduler_command_done_q <= 1'b1;
        scheduler_command_error_q <= 1'b1;
        state_q <= ST_FAIL;
      end
      if (weight_protocol_error || patch_protocol_error ||
          weight_context_error || patch_context_error) begin
        engine_fault_q <= 1'b1;
        scheduler_command_done_q <= 1'b1;
        scheduler_command_error_q <= 1'b1;
        state_q <= ST_FAIL;
      end
    end
  end

  alexnet_m8n126_graph_scheduler u_scheduler (
      .clk, .rst, .start_valid, .start_ready, .start_tag,
      .command_valid(scheduler_command_valid),
      .command_ready(scheduler_command_ready),
      .command_layer_id(scheduler_command_layer_id),
      .command_is_fc(scheduler_command_is_fc),
      .command_mode_split_n64(scheduler_command_mode_split_n64),
      .command_bank_enable(scheduler_command_bank_enable),
      .command_n_lane_mask(scheduler_command_n_lane_mask),
      .command_n_base(scheduler_command_n_base),
      .command_n_count(scheduler_command_n_count),
      .command_m_base(scheduler_command_m_base),
      .command_m_count(scheduler_command_m_count),
      .command_group0_m_count(scheduler_command_group0_m_count),
      .command_group1_m_count(scheduler_command_group1_m_count),
      .command_k_offset(scheduler_command_k_offset),
      .command_k_count(scheduler_command_k_count),
      .command_accum_first(scheduler_command_accum_first),
      .command_accum_final(scheduler_command_accum_final),
      .command_weight_fill(scheduler_command_weight_fill),
      .command_weight_release(scheduler_command_weight_release),
      .command_result_enable(scheduler_command_result_enable),
      .command_context_tag(scheduler_command_context_tag),
      .command_tile_tag(scheduler_command_tile_tag),
      .command_done(scheduler_command_done_q),
      .command_error(scheduler_command_error_q),
      .layer_complete_valid, .layer_complete_ready, .layer_complete_id,
      .layer_complete_requires_pool,
      .busy(scheduler_busy), .inference_done, .inference_failed,
      .fault(scheduler_fault), .active_layer_id, .completed_commands
  );

  alexnet_n128_weight_pingpong u_weight_pingpong (
      .clk, .rst,
      .fill_valid(weight_fill_valid), .fill_ready(weight_fill_ready),
      .fill_k_count(k_count_q), .fill_bank_enable(service_bank_enable_q),
      .fill_n_lane_mask(service_n_lane_mask_q),
      .fill_context_tag(weight_context_tag_q),
      .write_valid(weight_axis_valid && state_q == ST_WEIGHT_DATA),
      .write_ready(weight_write_ready), .write_values(weight_axis_data),
      .write_last(weight_axis_last), .write_k(), .write_bank_slot(),
      .replay_valid(weight_replay_valid), .replay_ready(weight_replay_ready),
      .replay_k_count(k_count_q),
      .replay_bank_enable(service_bank_enable_q),
      .replay_n_lane_mask(service_n_lane_mask_q),
      .replay_context_tag(weight_context_tag_q),
      .weight_valid, .weight_ready, .weight_values, .weight_k,
      .weight_last, .weight_bank_enable, .weight_n_lane_mask,
      .weight_context_tag,
      .release_valid(weight_release_valid), .release_ready(weight_release_ready),
      .release_context_tag(weight_context_tag_q),
      .set_state(weight_set_state), .ready_set_mask(weight_ready_set_mask),
      .fill_active(weight_fill_active),
      .active_fill_set(weight_active_fill_set),
      .replay_active(weight_replay_active),
      .active_replay_set(weight_active_replay_set),
      .words_written(weight_words_written),
      .completed_fills(weight_completed_fills),
      .completed_replays(weight_completed_replays),
      .fill_done(weight_fill_done), .replay_done(weight_replay_done),
      .context_error(weight_context_error),
      .protocol_error(weight_protocol_error), .idle(weight_idle)
  );

  alexnet_m16_patch_pingpong u_patch_pingpong (
      .clk, .rst,
      .fill_valid(patch_fill_valid), .fill_ready(patch_fill_ready),
      .fill_k_count(k_count_q), .fill_m_lane_mask(patch_m_lane_mask_q),
      .fill_context_tag(patch_context_tag_q),
      .write_valid(patch_axis_valid && state_q == ST_PATCH_DATA),
      .write_ready(patch_write_ready), .write_values(patch_axis_data),
      .write_last(patch_axis_last), .write_k(),
      .replay_valid(patch_replay_valid), .replay_ready(patch_replay_ready),
      .replay_k_count(k_count_q),
      .replay_m_lane_mask(patch_m_lane_mask_q),
      .replay_context_tag(patch_context_tag_q),
      .patch_valid, .patch_ready, .patch_values, .patch_k, .patch_last,
      .patch_m_lane_mask, .patch_context_tag,
      .set_state(patch_set_state), .ready_set_mask(patch_ready_set_mask),
      .fill_active(patch_fill_active),
      .active_fill_set(patch_active_fill_set),
      .replay_active(patch_replay_active),
      .active_replay_set(patch_active_replay_set),
      .words_written(patch_words_written),
      .completed_fills(patch_completed_fills),
      .completed_replays(patch_completed_replays),
      .fill_done(patch_fill_done), .replay_done(patch_replay_done),
      .context_error(patch_context_error),
      .protocol_error(patch_protocol_error), .idle(patch_idle)
  );

  alexnet_m8n128_tile_payload u_payload (
      .clk, .rst,
      .command_valid(payload_command_valid),
      .command_ready(payload_command_ready),
      .command_layer_id(layer_id_q),
      .command_mode_split_n64(mode_split_q),
      .command_bank_enable(bank_enable_q),
      .command_n_lane_mask(n_lane_mask_q),
      .command_n_base(n_base_q), .command_n_count(n_count_q),
      .command_m_base(m_base_q),
      .command_group0_m_count(group_m_count_q[0]),
      .command_group1_m_count(group_m_count_q[1]),
      .command_k_count(k_count_q), .command_accum_first(accum_first_q),
      .command_accum_final(accum_final_q),
      .command_result_enable(result_enable_q),
      .command_weight_context_tag(weight_context_tag_q),
      .command_patch_context_tag(patch_context_tag_q),
      .command_tile_tag(tile_tag_q),
      .patch_valid, .patch_ready, .patch_values, .patch_k, .patch_last,
      .patch_m_lane_mask, .patch_context_tag,
      .weight_valid, .weight_ready, .weight_values, .weight_k,
      .weight_last, .weight_bank_enable, .weight_n_lane_mask,
      .weight_context_tag,
      .parameter_request_valid, .parameter_request_ready,
      .parameter_request_layer_id, .parameter_request_n_base,
      .parameter_request_context_tag, .parameter_valid, .parameter_ready,
      .parameter_n_base, .parameter_context_tag, .parameter_bias,
      .parameter_multiplier, .parameter_right_shift, .parameter_relu,
      .result_valid, .result_ready, .result_values, .result_lane_mask,
      .result_m_count, .result_m_base, .result_n_base, .result_tile_tag,
      .result_last_slice, .command_done(payload_done),
      .command_error(payload_error), .busy(payload_busy),
      .accumulator_open, .fault(payload_fault), .active_cycles,
      .issue_cycles, .patch_stall_cycles, .weight_stall_cycles,
      .result_stall_cycles, .useful_mac_count, .physical_mac_slot_count
  );

`ifndef SYNTHESIS
  always_ff @(posedge clk) begin
    if (!rst) begin
      if (launch_fire && (!patch_replay_ready || !weight_replay_ready ||
                          !payload_command_ready))
        $fatal(1, "graph payload launch lost atomicity");
      if (scheduler_command_valid && scheduler_command_ready &&
          scheduler_command_mode_split_n64 &&
          scheduler_command_bank_enable != 8'hff)
        $fatal(1, "split descriptor did not expose all physical banks");
      if (weight_axis_valid && weight_axis_ready &&
          weight_axis_last != (weight_words_written + 1'b1 ==
              k_count_q * $countones(service_bank_enable_q)))
        $fatal(1, "graph weight stream TLAST mismatch");
      if (patch_axis_valid && patch_axis_ready &&
          patch_axis_last != (patch_words_written + 1'b1 == k_count_q))
        $fatal(1, "graph patch stream TLAST mismatch");
    end
  end
`endif

endmodule
