`timescale 1ns/1ps

// Complete local accumulator-aware M4xN8 base datapath. The packed PE and SA
// RTL are unchanged. This wrapper coordinates standalone SA clears, spatial
// tile descriptors, channel-chunk ownership, and the accumulator-aware output
// slice from signed INT8 K issue through final tagged INT8 packets.
module alexnet_m4n8_accum_base_datapath #(
    parameter int PHYS_ROWS = 2,
    parameter int M_GROUP = 2 * PHYS_ROWS,
    parameter int M_COUNT_W = $clog2(M_GROUP + 1),
    parameter int SLICE_INDEX = 0,
    parameter int FIFO_DEPTH = 64,
    parameter int BANK_DEPTH = 512,
    parameter int DIM_W = 8,
    parameter int TILE_TAG_W = 16,
    parameter int CONTEXT_TAG_W = 16,
    parameter int CHUNK_INDEX_W = 8,
    parameter int N_BASE_W = 16,
    parameter int BANK_COUNT_W = $clog2(BANK_DEPTH + 1),
    parameter bit RUNTIME_SLICE_INDEX = 1'b0
) (
    input logic clk,
    input logic rst,
    input logic ce,

    input  logic cfg_valid,
    output logic cfg_ready,
    input  logic [1:0] cfg_destination,
    input  logic [N_BASE_W-1:0] cfg_n64_tile_base,
    input  logic [2:0] cfg_slice_index,
    input  logic [7:0] cfg_lane_mask,
    input  logic signed [31:0] cfg_bias [0:7],
    input  logic signed [17:0] cfg_multiplier [0:7],
    input  logic [5:0] cfg_right_shift [0:7],
    input  logic [7:0] cfg_relu,

    input  logic chunk_valid,
    output logic chunk_ready,
    input  logic [BANK_COUNT_W-1:0] chunk_word_count,
    input  logic [DIM_W-1:0] chunk_output_width,
    input  logic [7:0] chunk_n_lane_mask,
    input  logic [CONTEXT_TAG_W-1:0] chunk_context_tag,
    input  logic [TILE_TAG_W-1:0] chunk_tile_tag_base,
    input  logic [CHUNK_INDEX_W-1:0] chunk_index,
    input  logic chunk_first,
    input  logic chunk_final,

    input  logic tile_start_valid,
    output logic tile_start_ready,
    input  logic [M_COUNT_W-1:0] tile_m_count,
    input  logic [7:0] tile_n_lane_mask,
    input  logic [TILE_TAG_W-1:0] tile_tag,

    input  logic issue_valid,
    output logic issue_ready,
    input  logic issue_last,
    input  logic signed [7:0] issue_act_lo [0:PHYS_ROWS-1],
    input  logic signed [7:0] issue_act_hi [0:PHYS_ROWS-1],
    input  logic signed [7:0] issue_weight [0:7],

    output logic egress_valid,
    input  logic egress_ready,
    output logic [63:0] egress_values,
    output logic [7:0] egress_lane_mask,
    output logic [1:0] egress_destination,
    output logic [2:0] egress_slice,
    output logic [4:0] egress_m,
    output logic [N_BASE_W-1:0] egress_n_base,
    output logic [TILE_TAG_W-1:0] egress_tile_tag,

    output logic configured,
    output logic compute_busy,
    output logic transaction_active,
    output logic chunk_active,
    output logic tile_done,
    output logic chunk_done,
    output logic transaction_done,
    output logic datapath_idle,
    output logic [2:0] accum_bank_state,
    output logic accum_context_error,
    output logic protocol_error,
    output logic [$clog2(FIFO_DEPTH+1)-1:0] queued_count
);

  logic tile_active_q;
  logic issue_open_q;
  logic [1:0] m_lane_mask_q [0:PHYS_ROWS-1];
  logic tile_start_fire;
  logic issue_fire;
  logic cfg_fire;

  logic [7:0] cfg_lane_mask_q;
  logic [7:0] output_cfg_lane_mask;

  logic sa_result_valid [0:PHYS_ROWS-1][0:7];
  logic sa_result_ready [0:PHYS_ROWS-1][0:7];
  logic signed [31:0] sa_result_lo [0:PHYS_ROWS-1][0:7];
  logic signed [31:0] sa_result_hi [0:PHYS_ROWS-1][0:7];
  logic [1:0] sa_result_lane_mask [0:PHYS_ROWS-1][0:7];

  logic output_cfg_ready;
  logic output_chunk_valid;
  logic output_chunk_ready;
  logic output_tile_valid;
  logic output_tile_ready;
  logic [M_COUNT_W-1:0] output_tile_m_count;
  logic [7:0] output_tile_n_lane_mask;
  logic [TILE_TAG_W-1:0] output_tile_tag;
  logic output_descriptor_pending_q;
  logic [M_COUNT_W-1:0] pending_tile_m_count_q;
  logic [7:0] pending_tile_n_lane_mask_q;
  logic [TILE_TAG_W-1:0] pending_tile_tag_q;
  logic [1:0] outstanding_result_count_q;
  logic output_configured;
  logic output_slice_idle;
  logic output_transaction_active;
  logic output_chunk_active;
  logic output_tile_scan_done;
  logic output_chunk_done;
  logic output_transaction_done;

  assign configured = output_configured;
  assign compute_busy = tile_active_q;
  assign transaction_active = output_transaction_active;
  assign chunk_active = output_chunk_active;
  assign chunk_done = output_chunk_done;
  assign transaction_done = output_transaction_done;
  assign datapath_idle = !tile_active_q && !output_descriptor_pending_q &&
                         output_slice_idle;

  // A configuration request wins over a new first chunk at the fully drained
  // boundary. Once a transaction owns the partial-sum bank, however, a pending
  // request cannot block its remaining tiles or continuation chunks.
  assign cfg_ready = !tile_active_q && output_cfg_ready;
  assign cfg_fire = cfg_valid && cfg_ready;
  assign output_chunk_valid = chunk_valid && !tile_active_q &&
                              (output_transaction_active || !cfg_valid);
  assign chunk_ready = !tile_active_q &&
                       (output_transaction_active || !cfg_valid) &&
                       output_chunk_ready;

  // The PE holding register and accumulator are independent.  Keep at most one
  // scanner descriptor queued locally so the next tile can clear/start while
  // the previous result wavefront is still reaching the snapshot.  A two-entry
  // outstanding limit prevents a later reduce_last from overwriting a PE hold.
  assign tile_start_ready = output_configured && output_chunk_active &&
                            !tile_active_q && !output_descriptor_pending_q &&
                            (outstanding_result_count_q < 2) && ce;
  assign tile_start_fire = tile_start_valid && tile_start_ready;
  assign output_tile_valid = output_descriptor_pending_q || tile_start_fire;
  assign output_tile_m_count = output_descriptor_pending_q ?
                               pending_tile_m_count_q : tile_m_count;
  assign output_tile_n_lane_mask = output_descriptor_pending_q ?
                                   pending_tile_n_lane_mask_q :
                                   tile_n_lane_mask;
  assign output_tile_tag = output_descriptor_pending_q ?
                           pending_tile_tag_q : tile_tag;

  assign issue_ready = tile_active_q && issue_open_q && ce &&
                       (!issue_last || outstanding_result_count_q < 2);
  assign issue_fire = issue_valid && issue_ready;

  // The accumulator-aware slice consults cfg_lane_mask on every continuation
  // descriptor. Keep only that accepted field stable while a later config is
  // pending; requant and router already latch every other field on cfg_fire.
  // Bypass the old shadow on cfg_fire for the same-edge child handshake.
  assign output_cfg_lane_mask = cfg_fire ? cfg_lane_mask : cfg_lane_mask_q;

  always_ff @(posedge clk) begin
    if (rst) begin
      tile_active_q <= 1'b0;
      issue_open_q <= 1'b0;
      for (int g = 0; g < PHYS_ROWS; g++)
        m_lane_mask_q[g] <= '0;
      output_descriptor_pending_q <= 1'b0;
      pending_tile_m_count_q <= '0;
      pending_tile_n_lane_mask_q <= '0;
      pending_tile_tag_q <= '0;
      outstanding_result_count_q <= '0;
      tile_done <= 1'b0;
      cfg_lane_mask_q <= '0;
    end else begin
      tile_done <= 1'b0;

      if (cfg_fire)
        cfg_lane_mask_q <= cfg_lane_mask;

      if (tile_start_fire) begin
        tile_active_q <= 1'b1;
        issue_open_q <= 1'b1;
        if (!output_tile_ready) begin
          output_descriptor_pending_q <= 1'b1;
          pending_tile_m_count_q <= tile_m_count;
          pending_tile_n_lane_mask_q <= tile_n_lane_mask;
          pending_tile_tag_q <= tile_tag;
        end
        for (int g = 0; g < PHYS_ROWS; g++) begin
          if (tile_m_count <= 2*g)
            m_lane_mask_q[g] <= 2'b00;
          else if (tile_m_count == 2*g + 1)
            m_lane_mask_q[g] <= 2'b01;
          else
            m_lane_mask_q[g] <= 2'b11;
        end
      end

      if (output_descriptor_pending_q && output_tile_ready)
        output_descriptor_pending_q <= 1'b0;

      if (issue_fire && issue_last) begin
        issue_open_q <= 1'b0;
        tile_active_q <= 1'b0;
        tile_done <= 1'b1;
      end

      case ({tile_start_fire, output_tile_scan_done})
        2'b10: outstanding_result_count_q <=
                   outstanding_result_count_q + 1'b1;
        2'b01: outstanding_result_count_q <=
                   outstanding_result_count_q - 1'b1;
        default: outstanding_result_count_q <= outstanding_result_count_q;
      endcase
    end
  end

  alexnet_sa_m4n8 #(
      .PHYS_ROWS(PHYS_ROWS)
  ) u_sa (
      .clk(clk),
      .rst(rst),
      .ce(ce),
      .act_lo(issue_act_lo),
      .act_hi(issue_act_hi),
      .weight(issue_weight),
      .issue_valid(issue_fire),
      .tile_clear(tile_start_fire),
      .reduce_last(issue_fire && issue_last),
      .m_lane_mask(m_lane_mask_q),
      .result_valid(sa_result_valid),
      .result_ready(sa_result_ready),
      .result_lo(sa_result_lo),
      .result_hi(sa_result_hi),
      .result_lane_mask(sa_result_lane_mask)
  );

  alexnet_m4n8_n8_accum_output_slice #(
      .PHYS_ROWS(PHYS_ROWS),
      .SLICE_INDEX(SLICE_INDEX),
      .RUNTIME_SLICE_INDEX(RUNTIME_SLICE_INDEX),
      .FIFO_DEPTH(FIFO_DEPTH),
      .BANK_DEPTH(BANK_DEPTH),
      .DIM_W(DIM_W),
      .TILE_TAG_W(TILE_TAG_W),
      .CONTEXT_TAG_W(CONTEXT_TAG_W),
      .CHUNK_INDEX_W(CHUNK_INDEX_W),
      .N_BASE_W(N_BASE_W)
  ) u_output_slice (
      .clk(clk),
      .rst(rst),
      .cfg_valid(cfg_fire),
      .cfg_ready(output_cfg_ready),
      .cfg_destination(cfg_destination),
      .cfg_n64_tile_base(cfg_n64_tile_base),
      .cfg_slice_index(cfg_slice_index),
      .cfg_lane_mask(output_cfg_lane_mask),
      .cfg_bias(cfg_bias),
      .cfg_multiplier(cfg_multiplier),
      .cfg_right_shift(cfg_right_shift),
      .cfg_relu(cfg_relu),
      .chunk_valid(output_chunk_valid),
      .chunk_ready(output_chunk_ready),
      .chunk_word_count(chunk_word_count),
      .chunk_output_width(chunk_output_width),
      .chunk_n_lane_mask(chunk_n_lane_mask),
      .chunk_context_tag(chunk_context_tag),
      .chunk_tile_tag_base(chunk_tile_tag_base),
      .chunk_index(chunk_index),
      .chunk_first(chunk_first),
      .chunk_final(chunk_final),
      .tile_valid(output_tile_valid),
      .tile_ready(output_tile_ready),
      .tile_m_count(output_tile_m_count),
      .tile_n_lane_mask(output_tile_n_lane_mask),
      .tile_tag(output_tile_tag),
      .hold_valid(sa_result_valid),
      .hold_ready(sa_result_ready),
      .hold_lo(sa_result_lo),
      .hold_hi(sa_result_hi),
      .hold_m_lane_mask(sa_result_lane_mask),
      .egress_valid(egress_valid),
      .egress_ready(egress_ready),
      .egress_values(egress_values),
      .egress_lane_mask(egress_lane_mask),
      .egress_destination(egress_destination),
      .egress_slice(egress_slice),
      .egress_m(egress_m),
      .egress_n_base(egress_n_base),
      .egress_tile_tag(egress_tile_tag),
      .configured(output_configured),
      .slice_idle(output_slice_idle),
      .transaction_active(output_transaction_active),
      .chunk_active(output_chunk_active),
      .tile_scan_done(output_tile_scan_done),
      .chunk_done(output_chunk_done),
      .transaction_done(output_transaction_done),
      .accum_bank_state(accum_bank_state),
      .accum_context_error(accum_context_error),
      .protocol_error(protocol_error),
      .queued_count(queued_count)
  );

`ifndef SYNTHESIS
  always_ff @(posedge clk) begin
    if (!rst) begin
      if (tile_start_fire && issue_valid)
        $fatal(1,
               "accum base datapath tile clear requires a standalone source cycle");
      if (issue_valid && !tile_active_q)
        $fatal(1,
               "accum base datapath received a K token without an active tile");
      if (issue_valid && tile_active_q && !issue_open_q)
        $fatal(1,
               "accum base datapath received a K token after issue_last");
      if (output_tile_scan_done && outstanding_result_count_q == 0)
        $fatal(1, "accum base datapath observed an unowned result snapshot");
      if (outstanding_result_count_q > 2)
        $fatal(1, "accum base datapath exceeded two outstanding result sets");
      if (issue_fire && issue_last && outstanding_result_count_q >= 2)
        $fatal(1, "accum base datapath allowed PE holding overflow");
      if (output_chunk_done && tile_active_q && !output_tile_scan_done)
        $fatal(1,
               "accum base datapath completed a chunk with compute still active");
      if (cfg_fire && output_transaction_active)
        $fatal(1,
               "accum base datapath reconfigured an active transaction");
    end
  end
`endif

endmodule
