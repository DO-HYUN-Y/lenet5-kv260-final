`timescale 1ns/1ps

// Descriptor-driven payload boundary for the physical M8xN128 dynamic array.
//
// One command consumes an already assembled M16 activation patch stream and
// one resident-weight replay stream.  Wide mode maps the lower M8 patch to an
// M8xN128 tile.  Split mode maps the two M8 patch halves to two M8xN64 tiles
// while broadcasting the four externally filled N16 weight words into the
// upper cluster.  A non-final K command drains the systolic pipelines without
// clearing the PE accumulators; the next command resumes the same tile.  Only
// the true final K command requests parameters, releases PE result holdings,
// requantizes each N8 slice, and emits results.
module alexnet_m8n128_tile_payload #(
    parameter int TILE_TAG_W = 16,
    parameter int CONTEXT_TAG_W = 16,
    parameter int PIPE_FLUSH_CYCLES = 32
) (
    input logic clk,
    input logic rst,

    input  logic command_valid,
    output logic command_ready,
    input  logic [3:0] command_layer_id,
    input  logic command_mode_split_n64,
    input  logic [7:0] command_bank_enable,
    input  logic [15:0] command_n_lane_mask [0:7],
    input  logic [15:0] command_n_base,
    input  logic [7:0] command_n_count,
    input  logic [12:0] command_m_base,
    input  logic [3:0] command_group0_m_count,
    input  logic [3:0] command_group1_m_count,
    input  logic [12:0] command_k_count,
    input  logic command_accum_first,
    input  logic command_accum_final,
    input  logic command_result_enable,
    input  logic [CONTEXT_TAG_W-1:0] command_weight_context_tag,
    input  logic [CONTEXT_TAG_W-1:0] command_patch_context_tag,
    input  logic [TILE_TAG_W-1:0] command_tile_tag,

    input  logic patch_valid,
    output logic patch_ready,
    input  logic signed [7:0] patch_values [0:15],
    input  logic [11:0] patch_k,
    input  logic patch_last,
    input  logic [15:0] patch_m_lane_mask,
    input  logic [CONTEXT_TAG_W-1:0] patch_context_tag,

    input  logic weight_valid,
    output logic weight_ready,
    input  logic signed [7:0] weight_values [0:7][0:15],
    input  logic [11:0] weight_k,
    input  logic weight_last,
    input  logic [7:0] weight_bank_enable,
    input  logic [15:0] weight_n_lane_mask [0:7],
    input  logic [CONTEXT_TAG_W-1:0] weight_context_tag,

    output logic parameter_request_valid,
    input  logic parameter_request_ready,
    output logic [3:0] parameter_request_layer_id,
    output logic [15:0] parameter_request_n_base,
    output logic [CONTEXT_TAG_W-1:0] parameter_request_context_tag,
    input  logic parameter_valid,
    output logic parameter_ready,
    input  logic [15:0] parameter_n_base,
    input  logic [CONTEXT_TAG_W-1:0] parameter_context_tag,
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
    output logic [TILE_TAG_W-1:0] result_tile_tag,
    output logic result_last_slice,

    output logic command_done,
    output logic command_error,
    output logic busy,
    output logic accumulator_open,
    output logic fault,
    output logic [31:0] active_cycles,
    output logic [31:0] issue_cycles,
    output logic [31:0] patch_stall_cycles,
    output logic [31:0] weight_stall_cycles,
    output logic [31:0] result_stall_cycles,
    output logic [63:0] useful_mac_count,
    output logic [63:0] physical_mac_slot_count
);

  typedef enum logic [3:0] {
    ST_IDLE,
    ST_CLEAR,
    ST_ISSUE,
    ST_FLUSH,
    ST_WAIT_SLICE,
    ST_PARAM_REQ,
    ST_PARAM_WAIT,
    ST_CFG,
    ST_REQUANT,
    ST_RESULT,
    ST_DISCARD,
    ST_ERROR
  } state_t;

  state_t state_q;
  logic [3:0] layer_id_q;
  logic mode_split_q;
  logic [7:0] bank_enable_q;
  logic [15:0] n_lane_mask_q [0:7];
  logic [15:0] n_base_q;
  logic [7:0] n_count_q;
  logic [12:0] m_base_q;
  logic [3:0] group_m_count_q [0:1];
  logic [12:0] k_count_q;
  logic accum_first_q, accum_final_q;
  logic [CONTEXT_TAG_W-1:0] weight_context_tag_q;
  logic [CONTEXT_TAG_W-1:0] patch_context_tag_q;
  logic [TILE_TAG_W-1:0] tile_tag_q;
  logic [11:0] expected_k_q;
  logic [$clog2(PIPE_FLUSH_CYCLES+1)-1:0] flush_count_q;
  logic [4:0] result_slice_q;

  logic accum_open_q;
  logic accum_mode_split_q;
  logic [7:0] accum_bank_enable_q;
  logic [15:0] accum_n_base_q;
  logic [12:0] accum_m_base_q;
  logic [3:0] accum_group_m_count_q [0:1];
  logic [TILE_TAG_W-1:0] accum_tile_tag_q;

  logic signed [31:0] requant_cfg_bias_q [0:7];
  logic signed [17:0] requant_cfg_multiplier_q [0:7];
  logic [5:0] requant_cfg_right_shift_q [0:7];
  logic [7:0] requant_cfg_relu_q;

  logic group_ce [0:1];
  logic signed [7:0] group_act_lo [0:1][0:3];
  logic signed [7:0] group_act_hi [0:1][0:3];
  logic group_issue_valid [0:1];
  logic group_tile_clear [0:1];
  logic group_reduce_last [0:1];
  logic [1:0] group_m_lane_mask [0:1][0:3];
  logic [TILE_TAG_W-1:0] group_tile_tag [0:1];
  logic signed [7:0] sa_bank_weight [0:7][0:15];
  logic sa_result_valid [0:7][0:3][0:15];
  logic sa_result_ready [0:7][0:3][0:15];
  logic signed [31:0] sa_result_lo [0:7][0:3][0:15];
  logic signed [31:0] sa_result_hi [0:7][0:3][0:15];
  logic [1:0] sa_result_lane_mask [0:7][0:3][0:15];
  logic sa_bank_source_group [0:7];
  logic [2:0] sa_bank_n16_slot [0:7];
  logic [TILE_TAG_W-1:0] sa_bank_result_tag [0:7];

  logic requant_cfg_valid, requant_cfg_ready;
  logic requant_ingress_valid, requant_ingress_ready;
  logic signed [31:0] requant_accumulator [0:7][0:7];
  logic requant_egress_valid, requant_egress_ready;
  logic [3:0] requant_egress_m_count;
  logic [63:0] requant_egress_values [0:7];
  logic [7:0] requant_egress_lane_mask [0:7];
  logic [TILE_TAG_W-1:0] requant_egress_tile_tag;
  logic requant_idle;

  logic command_fire, issue_fire, issue_metadata_ok;
  logic parameter_fire, requant_cfg_fire, requant_ingress_fire;
  logic result_fire;
  logic command_descriptor_ok, continuation_ok;
  logic command_effective_split;
  logic [7:0] command_effective_bank_enable;
  logic [7:0] command_logical_n_count;
  logic [15:0] expected_patch_mask;
  logic [7:0] expected_weight_bank_enable;
  logic [2:0] selected_bank;
  logic selected_half, selected_group;
  logic [3:0] selected_m_count;
  logic [15:0] selected_n_base;
  logic [7:0] selected_n_lane_mask;
  logic [31:0] selected_slice_valid_vector;
  logic selected_slice_valid;
  logic [4:0] next_physical_slice;
  logic next_physical_found;
  logic physical_last_slice;
  logic output_last_slice;
  logic [4:0] issue_m_count;
  (* use_dsp = "no" *) logic [12:0] issue_useful_macs;

  assign command_ready = state_q == ST_IDLE && !fault;
  assign command_fire = command_valid && command_ready;
  assign busy = state_q != ST_IDLE;
  assign accumulator_open = accum_open_q;

  assign patch_ready = state_q == ST_ISSUE && weight_valid;
  assign weight_ready = state_q == ST_ISSUE && patch_valid;
  assign issue_fire = patch_valid && patch_ready;

  assign parameter_request_valid = state_q == ST_PARAM_REQ;
  assign parameter_request_layer_id = layer_id_q;
  assign parameter_request_n_base = selected_n_base;
  assign parameter_request_context_tag = weight_context_tag_q;
  assign parameter_ready = state_q == ST_PARAM_WAIT;
  assign parameter_fire = parameter_valid && parameter_ready;

  assign requant_cfg_valid = state_q == ST_CFG;
  assign requant_cfg_fire = requant_cfg_valid && requant_cfg_ready;
  assign requant_ingress_valid = state_q == ST_REQUANT &&
                                 selected_slice_valid;
  assign requant_ingress_fire = requant_ingress_valid &&
                                 requant_ingress_ready;
  assign requant_egress_ready = state_q == ST_RESULT && result_ready;
  assign result_valid = state_q == ST_RESULT && requant_egress_valid;
  assign result_fire = result_valid && result_ready;
  assign result_m_count = requant_egress_m_count;
  assign result_m_base = m_base_q + (selected_group ? 13'd8 : 13'd0);
  assign result_n_base = selected_n_base;
  assign result_tile_tag = requant_egress_tile_tag;
  assign result_last_slice = output_last_slice;
  assign issue_m_count = group_m_count_q[0] + group_m_count_q[1];
  assign issue_useful_macs = issue_m_count * n_count_q;

  always_comb begin
    // A final Conv1 spatial tile can contain only the lower M group.  Keep
    // the graph descriptor in split-N64 form, but run the physical array as
    // one lower four-bank group so no unconsumed upper-cluster result is
    // created.
    command_effective_split = command_mode_split_n64 &&
                              command_group1_m_count != 0;
    command_effective_bank_enable = command_mode_split_n64 &&
                                    command_group1_m_count == 0 ?
                                    (command_bank_enable & 8'h0f) :
                                    command_bank_enable;
    command_logical_n_count = '0;
    for (int bank = 0; bank < 8; bank++) begin
      if ((!command_mode_split_n64 || bank < 4) &&
          command_bank_enable[bank]) begin
        for (int lane = 0; lane < 16; lane++)
          command_logical_n_count += command_n_lane_mask[bank][lane];
      end
    end

    expected_patch_mask = '0;
    for (int lane = 0; lane < 8; lane++) begin
      expected_patch_mask[lane] = lane < group_m_count_q[0];
      expected_patch_mask[lane+8] = mode_split_q &&
                                    lane < group_m_count_q[1];
    end
    expected_weight_bank_enable = mode_split_q ?
        {4'b0, bank_enable_q[3:0]} : bank_enable_q;

    issue_metadata_ok = patch_k == expected_k_q &&
                        weight_k == expected_k_q &&
                        patch_last == (expected_k_q + 1'b1 == k_count_q) &&
                        weight_last == (expected_k_q + 1'b1 == k_count_q) &&
                        patch_m_lane_mask == expected_patch_mask &&
                        patch_context_tag == patch_context_tag_q &&
                        weight_context_tag == weight_context_tag_q &&
                        weight_bank_enable == expected_weight_bank_enable;
    for (int bank = 0; bank < 8; bank++) begin
      if (mode_split_q) begin
        if (bank < 4)
          issue_metadata_ok &=
              weight_n_lane_mask[bank] == n_lane_mask_q[bank];
      end else begin
        issue_metadata_ok &=
            weight_n_lane_mask[bank] == n_lane_mask_q[bank];
      end
    end

    continuation_ok = !accum_open_q ||
        (!command_accum_first &&
         command_effective_split == accum_mode_split_q &&
         command_effective_bank_enable == accum_bank_enable_q &&
         command_n_base == accum_n_base_q &&
         command_m_base == accum_m_base_q &&
         command_group0_m_count == accum_group_m_count_q[0] &&
         command_group1_m_count == accum_group_m_count_q[1] &&
         command_tile_tag == accum_tile_tag_q);
    command_descriptor_ok = command_k_count >= 1 &&
        command_k_count <= 4096 && command_bank_enable != 0 &&
        command_n_count >= 1 && command_n_count <= 128 &&
        command_n_count == command_logical_n_count &&
        command_group0_m_count >= 1 && command_group0_m_count <= 8 &&
        command_result_enable == command_accum_final &&
        command_accum_first == !accum_open_q && continuation_ok;
    if (command_mode_split_n64)
      command_descriptor_ok &= command_group1_m_count <= 8 &&
                               command_bank_enable == 8'hff;
    else
      command_descriptor_ok &= command_group1_m_count == 0;
  end

  always_comb begin
    selected_group = mode_split_q && result_slice_q >= 8;
    if (selected_group)
      selected_bank = 4 + ((result_slice_q - 8) >> 1);
    else
      selected_bank = result_slice_q >> 1;
    selected_half = result_slice_q[0];
    selected_m_count = group_m_count_q[selected_group];
    if (mode_split_q)
      selected_n_base = n_base_q + ({13'b0, result_slice_q[2:0]} << 3);
    else
      selected_n_base = n_base_q + ({11'b0, result_slice_q} << 3);
    selected_n_lane_mask = selected_half ?
        n_lane_mask_q[selected_bank][15:8] :
        n_lane_mask_q[selected_bank][7:0];

    for (int row = 0; row < 4; row++) begin
      for (int col = 0; col < 8; col++) begin
        selected_slice_valid_vector[row*8+col] =
            2*row < selected_m_count ?
            sa_result_valid[selected_bank][row][selected_half*8+col] : 1'b1;
      end
    end
    selected_slice_valid = &selected_slice_valid_vector;

    next_physical_slice = result_slice_q;
    next_physical_found = 1'b0;
    output_last_slice = 1'b1;
    for (int slice = 0; slice < 16; slice++) begin
      if (!next_physical_found && slice > result_slice_q &&
          bank_enable_q[slice >> 1]) begin
        next_physical_slice = slice;
        next_physical_found = 1'b1;
      end
      if (slice > result_slice_q && bank_enable_q[slice >> 1] &&
          (slice[0] ? |n_lane_mask_q[slice >> 1][15:8] :
                      |n_lane_mask_q[slice >> 1][7:0]))
        output_last_slice = 1'b0;
    end
    physical_last_slice = !next_physical_found;
  end

  always_comb begin
    for (int group = 0; group < 2; group++) begin
      group_ce[group] = state_q == ST_CLEAR || state_q == ST_ISSUE ||
                        state_q == ST_FLUSH || state_q == ST_WAIT_SLICE ||
                        state_q == ST_PARAM_REQ || state_q == ST_PARAM_WAIT ||
                        state_q == ST_CFG || state_q == ST_REQUANT ||
                        state_q == ST_RESULT || state_q == ST_DISCARD;
      group_issue_valid[group] = issue_fire && issue_metadata_ok &&
                                 (group == 0 || mode_split_q);
      group_tile_clear[group] = state_q == ST_CLEAR && accum_first_q &&
                                (group == 0 || mode_split_q);
      group_reduce_last[group] = issue_fire && issue_metadata_ok &&
                                  patch_last && accum_final_q &&
                                  (group == 0 || mode_split_q);
      group_tile_tag[group] = tile_tag_q;
      for (int row = 0; row < 4; row++) begin
        group_act_lo[group][row] = patch_values[group*8 + 2*row];
        group_act_hi[group][row] = patch_values[group*8 + 2*row + 1];
        group_m_lane_mask[group][row][0] =
            2*row < group_m_count_q[group];
        group_m_lane_mask[group][row][1] =
            2*row + 1 < group_m_count_q[group];
      end
    end

    for (int bank = 0; bank < 8; bank++) begin
      for (int lane = 0; lane < 16; lane++) begin
        if (mode_split_q && bank >= 4)
          sa_bank_weight[bank][lane] = weight_values[bank-4][lane];
        else
          sa_bank_weight[bank][lane] = weight_values[bank][lane];
      end
    end

    for (int bank = 0; bank < 8; bank++) begin
      for (int row = 0; row < 4; row++) begin
        for (int col = 0; col < 16; col++)
          sa_result_ready[bank][row][col] = 1'b0;
      end
    end
    if (state_q == ST_REQUANT || state_q == ST_DISCARD) begin
      for (int row = 0; row < 4; row++) begin
        if (2*row < selected_m_count) begin
          for (int col = 0; col < 8; col++)
            sa_result_ready[selected_bank][row][selected_half*8+col] =
                state_q == ST_DISCARD ? 1'b1 :
                requant_ingress_valid && requant_ingress_ready;
        end
      end
    end

    for (int row = 0; row < 4; row++) begin
      for (int col = 0; col < 8; col++) begin
        requant_accumulator[2*row][col] =
            sa_result_lo[selected_bank][row][selected_half*8+col];
        requant_accumulator[2*row+1][col] =
            sa_result_hi[selected_bank][row][selected_half*8+col];
      end
    end

    for (int row = 0; row < 8; row++) begin
      result_values[row] = requant_egress_values[row];
      result_lane_mask[row] = requant_egress_lane_mask[row];
    end
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      state_q <= ST_IDLE;
      layer_id_q <= '0;
      mode_split_q <= 1'b0;
      bank_enable_q <= '0;
      n_base_q <= '0;
      n_count_q <= '0;
      m_base_q <= '0;
      group_m_count_q[0] <= '0;
      group_m_count_q[1] <= '0;
      k_count_q <= '0;
      accum_first_q <= 1'b0;
      accum_final_q <= 1'b0;
      weight_context_tag_q <= '0;
      patch_context_tag_q <= '0;
      tile_tag_q <= '0;
      expected_k_q <= '0;
      flush_count_q <= '0;
      result_slice_q <= '0;
      accum_open_q <= 1'b0;
      accum_mode_split_q <= 1'b0;
      accum_bank_enable_q <= '0;
      accum_n_base_q <= '0;
      accum_m_base_q <= '0;
      accum_group_m_count_q[0] <= '0;
      accum_group_m_count_q[1] <= '0;
      accum_tile_tag_q <= '0;
      requant_cfg_relu_q <= '0;
      command_done <= 1'b0;
      command_error <= 1'b0;
      fault <= 1'b0;
      active_cycles <= '0;
      issue_cycles <= '0;
      patch_stall_cycles <= '0;
      weight_stall_cycles <= '0;
      result_stall_cycles <= '0;
      useful_mac_count <= '0;
      physical_mac_slot_count <= '0;
      for (int bank = 0; bank < 8; bank++)
        n_lane_mask_q[bank] <= '0;
      for (int lane = 0; lane < 8; lane++) begin
        requant_cfg_bias_q[lane] <= '0;
        requant_cfg_multiplier_q[lane] <= '0;
        requant_cfg_right_shift_q[lane] <= '0;
      end
    end else begin
      command_done <= 1'b0;
      command_error <= 1'b0;
      if (busy)
        active_cycles <= active_cycles + 1'b1;
      if (state_q == ST_ISSUE && patch_valid && !weight_valid)
        weight_stall_cycles <= weight_stall_cycles + 1'b1;
      if (state_q == ST_ISSUE && weight_valid && !patch_valid)
        patch_stall_cycles <= patch_stall_cycles + 1'b1;
      if (state_q == ST_RESULT && requant_egress_valid && !result_ready)
        result_stall_cycles <= result_stall_cycles + 1'b1;
      if (issue_fire && issue_metadata_ok) begin
        useful_mac_count <= useful_mac_count + issue_useful_macs;
        physical_mac_slot_count <= physical_mac_slot_count + 64'd1024;
      end

      if (command_fire) begin
        layer_id_q <= command_layer_id;
        mode_split_q <= command_effective_split;
        bank_enable_q <= command_effective_bank_enable;
        n_base_q <= command_n_base;
        n_count_q <= command_n_count;
        m_base_q <= command_m_base;
        group_m_count_q[0] <= command_group0_m_count;
        group_m_count_q[1] <= command_group1_m_count;
        k_count_q <= command_k_count;
        accum_first_q <= command_accum_first;
        accum_final_q <= command_accum_final;
        weight_context_tag_q <= command_weight_context_tag;
        patch_context_tag_q <= command_patch_context_tag;
        tile_tag_q <= command_tile_tag;
        expected_k_q <= '0;
        result_slice_q <= '0;
        for (int bank = 0; bank < 8; bank++) begin
          if (command_mode_split_n64 && command_group1_m_count == 0 &&
              bank >= 4)
            n_lane_mask_q[bank] <= '0;
          else
            n_lane_mask_q[bank] <= command_n_lane_mask[bank];
        end

        if (!command_descriptor_ok) begin
          fault <= 1'b1;
          state_q <= ST_ERROR;
        end else begin
          if (command_accum_first) begin
            accum_open_q <= 1'b1;
            accum_mode_split_q <= command_effective_split;
            accum_bank_enable_q <= command_effective_bank_enable;
            accum_n_base_q <= command_n_base;
            accum_m_base_q <= command_m_base;
            accum_group_m_count_q[0] <= command_group0_m_count;
            accum_group_m_count_q[1] <= command_group1_m_count;
            accum_tile_tag_q <= command_tile_tag;
            state_q <= ST_CLEAR;
          end else begin
            state_q <= ST_ISSUE;
          end
        end
      end

      case (state_q)
        ST_CLEAR: state_q <= ST_ISSUE;

        ST_ISSUE: if (issue_fire) begin
          if (!issue_metadata_ok) begin
            fault <= 1'b1;
            state_q <= ST_ERROR;
          end else begin
            issue_cycles <= issue_cycles + 1'b1;
            if (patch_last) begin
              if (accum_final_q)
                state_q <= ST_WAIT_SLICE;
              else begin
                flush_count_q <= '0;
                state_q <= ST_FLUSH;
              end
            end else begin
              expected_k_q <= expected_k_q + 1'b1;
            end
          end
        end

        ST_FLUSH: begin
          if (flush_count_q + 1'b1 >= PIPE_FLUSH_CYCLES) begin
            command_done <= 1'b1;
            state_q <= ST_IDLE;
          end else begin
            flush_count_q <= flush_count_q + 1'b1;
          end
        end

        ST_WAIT_SLICE: if (selected_slice_valid) begin
          if (selected_n_lane_mask == 0)
            state_q <= ST_DISCARD;
          else
            state_q <= ST_PARAM_REQ;
        end

        ST_PARAM_REQ: if (parameter_request_valid && parameter_request_ready)
          state_q <= ST_PARAM_WAIT;

        ST_PARAM_WAIT: if (parameter_fire) begin
          if (parameter_n_base != selected_n_base ||
              parameter_context_tag != weight_context_tag_q) begin
            fault <= 1'b1;
            state_q <= ST_ERROR;
          end else begin
            for (int lane = 0; lane < 8; lane++) begin
              requant_cfg_bias_q[lane] <= parameter_bias[lane];
              requant_cfg_multiplier_q[lane] <= parameter_multiplier[lane];
              requant_cfg_right_shift_q[lane] <=
                  parameter_right_shift[lane];
            end
            requant_cfg_relu_q <= parameter_relu;
            state_q <= ST_CFG;
          end
        end

        ST_CFG: if (requant_cfg_fire)
          state_q <= ST_REQUANT;

        ST_REQUANT: if (requant_ingress_fire)
          state_q <= ST_RESULT;

        ST_RESULT: if (result_fire) begin
          if (physical_last_slice) begin
            accum_open_q <= 1'b0;
            command_done <= 1'b1;
            state_q <= ST_IDLE;
          end else begin
            result_slice_q <= next_physical_slice;
            state_q <= ST_WAIT_SLICE;
          end
        end

        ST_DISCARD: begin
          if (physical_last_slice) begin
            accum_open_q <= 1'b0;
            command_done <= 1'b1;
            state_q <= ST_IDLE;
          end else begin
            result_slice_q <= next_physical_slice;
            state_q <= ST_WAIT_SLICE;
          end
        end

        ST_ERROR: begin
          command_done <= 1'b1;
          command_error <= 1'b1;
          state_q <= ST_IDLE;
        end

        default: ;
      endcase
    end
  end

  alexnet_sa_m8n128_dynamic #(
      .TILE_TAG_W(TILE_TAG_W)
  ) u_dynamic_sa (
      .clk,
      .rst,
      .mode_split_n64(mode_split_q),
      .bank_enable(bank_enable_q),
      .group_ce,
      .group_act_lo,
      .group_act_hi,
      .group_issue_valid,
      .group_tile_clear,
      .group_reduce_last,
      .group_m_lane_mask,
      .group_tile_tag,
      .bank_weight(sa_bank_weight),
      .result_valid(sa_result_valid),
      .result_ready(sa_result_ready),
      .result_lo(sa_result_lo),
      .result_hi(sa_result_hi),
      .result_lane_mask(sa_result_lane_mask),
      .bank_source_group(sa_bank_source_group),
      .bank_n16_slot(sa_bank_n16_slot),
      .bank_result_tag(sa_bank_result_tag)
  );

  alexnet_m8n8_parallel_requant u_requant (
      .clk,
      .rst,
      .cfg_valid(requant_cfg_valid),
      .cfg_ready(requant_cfg_ready),
      .cfg_bias(requant_cfg_bias_q),
      .cfg_multiplier(requant_cfg_multiplier_q),
      .cfg_right_shift(requant_cfg_right_shift_q),
      .cfg_relu(requant_cfg_relu_q),
      .ingress_valid(requant_ingress_valid),
      .ingress_ready(requant_ingress_ready),
      .ingress_m_count(selected_m_count),
      .ingress_accumulator(requant_accumulator),
      .ingress_lane_mask(selected_n_lane_mask),
      .ingress_tile_tag(tile_tag_q),
      .egress_valid(requant_egress_valid),
      .egress_ready(requant_egress_ready),
      .egress_m_count(requant_egress_m_count),
      .egress_values(requant_egress_values),
      .egress_lane_mask(requant_egress_lane_mask),
      .egress_tile_tag(requant_egress_tile_tag),
      .idle(requant_idle)
  );

`ifndef SYNTHESIS
  initial begin
    if (PIPE_FLUSH_CYCLES < 24)
      $fatal(1, "M8N128 payload flush interval is shorter than SA latency");
  end

  always_ff @(posedge clk) begin
    if (!rst) begin
      if (issue_fire && issue_metadata_ok && patch_k != weight_k)
        $fatal(1, "M8N128 payload activation/weight K mismatch");
      if (state_q == ST_REQUANT && selected_m_count == 0)
        $fatal(1, "M8N128 payload selected an empty M result group");
      if (result_valid && result_n_base + 8 < result_n_base)
        $fatal(1, "M8N128 payload result N base overflowed");
    end
  end
`endif

endmodule
