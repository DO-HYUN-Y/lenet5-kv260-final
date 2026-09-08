`timescale 1ns/1ps

// Two-segment accumulator-aware M4xN8 output path for rasters larger than one
// 512-word physical partial-sum bank. Scanner words retain one global raster
// order across the 512-word split, and final bank-pair emission reconstructs
// row-local M coordinates and tile tags before requantization.
module alexnet_m4n8_n8_dual_accum_output_slice #(
    parameter int SLICE_INDEX = 0,
    parameter int FIFO_DEPTH = 64,
    parameter int SEGMENT_DEPTH = 512,
    parameter int DIM_W = 8,
    parameter int TILE_TAG_W = 16,
    parameter int CONTEXT_TAG_W = 16,
    parameter int CHUNK_INDEX_W = 8,
    parameter int N_BASE_W = 16,
    parameter int BANK_ADDR_W = $clog2(2 * SEGMENT_DEPTH),
    parameter int BANK_COUNT_W = $clog2(2 * SEGMENT_DEPTH + 1)
) (
    input logic clk,
    input logic rst,

    input  logic cfg_valid,
    output logic cfg_ready,
    input  logic [1:0] cfg_destination,
    input  logic [N_BASE_W-1:0] cfg_n64_tile_base,
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

    input  logic tile_valid,
    output logic tile_ready,
    input  logic [2:0] tile_m_count,
    input  logic [7:0] tile_n_lane_mask,
    input  logic [TILE_TAG_W-1:0] tile_tag,

    input  logic hold_valid [0:1][0:7],
    output logic hold_ready [0:1][0:7],
    input  logic signed [31:0] hold_lo [0:1][0:7],
    input  logic signed [31:0] hold_hi [0:1][0:7],
    input  logic [1:0] hold_m_lane_mask [0:1][0:7],

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
    output logic slice_idle,
    output logic transaction_active,
    output logic chunk_active,
    output logic tile_scan_done,
    output logic chunk_done,
    output logic transaction_done,
    output logic [2:0] accum_bank_state,
    output logic accum_context_error,
    output logic protocol_error,
    output logic [$clog2(FIFO_DEPTH+1)-1:0] queued_count
);

  logic configured_q;
  logic cfg_fire;
  logic requant_cfg_ready;
  logic router_cfg_ready;
  logic requant_idle;
  logic router_idle;

  logic chunk_fire;
  logic chunk_active_q;
  logic slice_descriptor_shape_valid;
  logic slice_descriptor_context_match;
  logic first_chunk_boundary_ready;
  logic continuation_boundary_ready;
  logic bank_descriptor_valid;
  logic bank_descriptor_ready;

  logic [DIM_W-1:0] resident_output_width_q;
  logic [TILE_TAG_W-1:0] resident_tile_tag_base_q;
  logic [BANK_COUNT_W-1:0] resident_word_count_q;
  logic slice_context_error_q;
  logic slice_protocol_error_q;

  logic scanner_tile_valid;
  logic scanner_tile_ready;
  logic scanner_valid;
  logic scanner_ready;
  logic signed [31:0] scanner_accumulator [0:7];
  logic [1:0] scanner_m;
  logic [7:0] scanner_lane_mask;
  logic [TILE_TAG_W-1:0] scanner_tile_tag;
  logic scanner_busy;
  logic bank_accepting_scanner_words;
  logic scanner_metadata_match;
  logic scanner_fire;

  logic [DIM_W-1:0] ingress_raster_x_q;
  logic [15:0] ingress_tile_index_q;

  logic bank_ingress_valid;
  logic bank_ingress_ready;
  logic [BANK_ADDR_W-1:0] bank_ingress_word_index;
  logic bank_ingress_last;
  logic [BANK_COUNT_W-1:0] bank_resident_word_count;
  logic [7:0] bank_resident_n_lane_mask;
  logic [CONTEXT_TAG_W-1:0] bank_resident_context_tag;
  logic [CHUNK_INDEX_W-1:0] bank_next_chunk_index;
  logic [CHUNK_INDEX_W:0] bank_completed_chunks;
  logic [BANK_COUNT_W-1:0] bank_words_accepted;
  logic bank_resident_valid;
  logic bank_chunk_done;
  logic bank_emit_done;
  logic bank_context_error;
  logic bank_protocol_error;
  logic bank_idle;

  logic bank_egress_valid;
  logic bank_egress_ready;
  logic signed [31:0] bank_egress_accumulator [0:7];
  logic [7:0] bank_egress_n_lane_mask;
  logic [BANK_ADDR_W-1:0] bank_egress_word_index;
  logic bank_egress_last;
  logic [CONTEXT_TAG_W-1:0] bank_egress_context_tag;
  logic bank_egress_fire;

  logic [DIM_W-1:0] egress_raster_x_q;
  logic [15:0] egress_tile_index_q;
  logic [BANK_COUNT_W-1:0] egress_words_transferred_q;

  logic requant_valid;
  logic requant_ready;
  logic requant_ready_to_router;
  logic [63:0] requant_values;
  logic [7:0] requant_lane_mask;
  logic [4:0] requant_m;
  logic [TILE_TAG_W-1:0] requant_tile_tag;

  assign configured = configured_q;
  assign chunk_active = chunk_active_q;
  assign transaction_active = bank_resident_valid;
  assign chunk_done = bank_chunk_done;
  assign transaction_done = bank_emit_done;
  assign accum_context_error = bank_context_error || slice_context_error_q;
  assign protocol_error = bank_protocol_error || slice_protocol_error_q;

  assign slice_idle = scanner_tile_ready && bank_idle && requant_idle &&
                      router_idle && !chunk_active_q;
  assign cfg_ready = slice_idle;
  assign cfg_fire = cfg_valid && cfg_ready;

  always_ff @(posedge clk) begin
    if (rst)
      configured_q <= 1'b0;
    else if (cfg_fire)
      configured_q <= 1'b1;
  end

  assign slice_descriptor_shape_valid =
      (chunk_output_width != 0) &&
      (chunk_word_count != 0) &&
      (chunk_word_count <= 2 * SEGMENT_DEPTH) &&
      (chunk_output_width <= chunk_word_count) &&
      (chunk_n_lane_mask == cfg_lane_mask);

  assign slice_descriptor_context_match =
      chunk_first ||
      ((chunk_output_width == resident_output_width_q) &&
       (chunk_tile_tag_base == resident_tile_tag_base_q));

  assign first_chunk_boundary_ready =
      chunk_first && !cfg_valid && scanner_tile_ready && bank_idle &&
      requant_idle && router_idle;
  assign continuation_boundary_ready =
      !chunk_first && scanner_tile_ready && bank_resident_valid &&
      !chunk_active_q;

  assign bank_descriptor_valid =
      chunk_valid && configured_q && slice_descriptor_shape_valid &&
      slice_descriptor_context_match &&
      (first_chunk_boundary_ready || continuation_boundary_ready);
  assign chunk_ready = configured_q && slice_descriptor_shape_valid &&
                       slice_descriptor_context_match &&
                       (first_chunk_boundary_ready ||
                        continuation_boundary_ready) &&
                       bank_descriptor_ready;
  assign chunk_fire = chunk_valid && chunk_ready;

  always_ff @(posedge clk) begin
    if (rst) begin
      chunk_active_q <= 1'b0;
      resident_output_width_q <= '0;
      resident_tile_tag_base_q <= '0;
      resident_word_count_q <= '0;
      slice_context_error_q <= 1'b0;
      slice_protocol_error_q <= 1'b0;
      ingress_raster_x_q <= '0;
      ingress_tile_index_q <= '0;
      egress_raster_x_q <= '0;
      egress_tile_index_q <= '0;
      egress_words_transferred_q <= '0;
    end else begin
      if (chunk_valid && !chunk_ready) begin
        if (bank_resident_valid && !chunk_first &&
            !slice_descriptor_context_match)
          slice_context_error_q <= 1'b1;
        else if (!bank_resident_valid || chunk_first)
          slice_protocol_error_q <= 1'b1;
      end

      if (chunk_fire) begin
        chunk_active_q <= 1'b1;
        ingress_raster_x_q <= '0;
        ingress_tile_index_q <= '0;
        if (chunk_first) begin
          resident_output_width_q <= chunk_output_width;
          resident_tile_tag_base_q <= chunk_tile_tag_base;
          resident_word_count_q <= chunk_word_count;
          slice_context_error_q <= 1'b0;
          slice_protocol_error_q <= 1'b0;
        end
        if (chunk_final) begin
          egress_raster_x_q <= '0;
          egress_tile_index_q <= '0;
          egress_words_transferred_q <= '0;
        end
      end

      if (scanner_fire) begin
        if ((ingress_raster_x_q + 1'b1 == resident_output_width_q) ||
            (ingress_raster_x_q[1:0] == 2'b11))
          ingress_tile_index_q <= ingress_tile_index_q + 1'b1;
        if (ingress_raster_x_q + 1'b1 == resident_output_width_q)
          ingress_raster_x_q <= '0;
        else
          ingress_raster_x_q <= ingress_raster_x_q + 1'b1;
      end

      if (bank_chunk_done)
        chunk_active_q <= 1'b0;

      if (bank_egress_fire) begin
        egress_words_transferred_q <= egress_words_transferred_q + 1'b1;
        if ((egress_raster_x_q + 1'b1 == resident_output_width_q) ||
            (egress_raster_x_q[1:0] == 2'b11))
          egress_tile_index_q <= egress_tile_index_q + 1'b1;
        if (egress_raster_x_q + 1'b1 == resident_output_width_q)
          egress_raster_x_q <= '0;
        else
          egress_raster_x_q <= egress_raster_x_q + 1'b1;
      end

      if (bank_emit_done) begin
        resident_output_width_q <= '0;
        resident_tile_tag_base_q <= '0;
        resident_word_count_q <= '0;
      end

      if (scanner_valid && !scanner_metadata_match)
        slice_protocol_error_q <= 1'b1;
    end
  end

  assign bank_accepting_scanner_words =
      ((accum_bank_state == 3'd1) || (accum_bank_state == 3'd3)) &&
      (bank_words_accepted < bank_resident_word_count);
  assign tile_ready = configured_q && chunk_active_q &&
                      bank_accepting_scanner_words && scanner_tile_ready;
  assign scanner_tile_valid = tile_valid && configured_q && chunk_active_q &&
                              bank_accepting_scanner_words;

  alexnet_m4n8_result_scanner #(
      .PHYS_ROWS(2),
      .COLS(8),
      .TILE_TAG_W(TILE_TAG_W)
  ) u_scanner (
      .clk(clk),
      .rst(rst),
      .tile_valid(scanner_tile_valid),
      .tile_ready(scanner_tile_ready),
      .tile_m_count(tile_m_count),
      .tile_n_lane_mask(tile_n_lane_mask),
      .tile_tag(tile_tag),
      .hold_valid(hold_valid),
      .hold_ready(hold_ready),
      .hold_lo(hold_lo),
      .hold_hi(hold_hi),
      .hold_m_lane_mask(hold_m_lane_mask),
      .out_valid(scanner_valid),
      .out_ready(scanner_ready),
      .out_accumulator(scanner_accumulator),
      .out_m(scanner_m),
      .out_n_lane_mask(scanner_lane_mask),
      .out_tile_tag(scanner_tile_tag),
      .busy(scanner_busy),
      .tile_done(tile_scan_done)
  );

  assign scanner_metadata_match =
      (scanner_m == ingress_raster_x_q[1:0]) &&
      (scanner_tile_tag ==
       resident_tile_tag_base_q + ingress_tile_index_q);
  assign bank_ingress_valid = scanner_valid && scanner_metadata_match;
  assign scanner_ready = bank_ingress_ready && scanner_metadata_match;
  assign scanner_fire = scanner_valid && scanner_ready;
  assign bank_ingress_word_index =
      bank_words_accepted[BANK_ADDR_W-1:0];
  assign bank_ingress_last =
      bank_words_accepted + 1'b1 == bank_resident_word_count;

  alexnet_n8_int32_partial_sum_bank_pair #(
      .SEGMENT_DEPTH(SEGMENT_DEPTH),
      .CONTEXT_TAG_W(CONTEXT_TAG_W),
      .CHUNK_INDEX_W(CHUNK_INDEX_W)
  ) u_partial_sum_bank_pair (
      .clk(clk),
      .rst(rst),
      .descriptor_valid(bank_descriptor_valid),
      .descriptor_ready(bank_descriptor_ready),
      .descriptor_word_count(chunk_word_count),
      .descriptor_n_lane_mask(chunk_n_lane_mask),
      .descriptor_context_tag(chunk_context_tag),
      .descriptor_chunk_index(chunk_index),
      .descriptor_first_chunk(chunk_first),
      .descriptor_final_chunk(chunk_final),
      .ingress_valid(bank_ingress_valid),
      .ingress_ready(bank_ingress_ready),
      .ingress_accumulator(scanner_accumulator),
      .ingress_n_lane_mask(scanner_lane_mask),
      .ingress_word_index(bank_ingress_word_index),
      .ingress_last(bank_ingress_last),
      .egress_valid(bank_egress_valid),
      .egress_ready(bank_egress_ready),
      .egress_accumulator(bank_egress_accumulator),
      .egress_n_lane_mask(bank_egress_n_lane_mask),
      .egress_word_index(bank_egress_word_index),
      .egress_last(bank_egress_last),
      .egress_context_tag(bank_egress_context_tag),
      .bank_state(accum_bank_state),
      .resident_valid(bank_resident_valid),
      .resident_word_count(bank_resident_word_count),
      .resident_n_lane_mask(bank_resident_n_lane_mask),
      .resident_context_tag(bank_resident_context_tag),
      .next_chunk_index(bank_next_chunk_index),
      .completed_chunks(bank_completed_chunks),
      .words_accepted(bank_words_accepted),
      .chunk_done(bank_chunk_done),
      .emit_done(bank_emit_done),
      .context_error(bank_context_error),
      .protocol_error(bank_protocol_error),
      .idle(bank_idle)
  );

  assign bank_egress_ready = requant_ready;
  assign bank_egress_fire = bank_egress_valid && bank_egress_ready;

  alexnet_n8_requant #(
      .M_W(5),
      .TILE_TAG_W(TILE_TAG_W)
  ) u_requant (
      .clk(clk),
      .rst(rst),
      .cfg_valid(cfg_fire),
      .cfg_ready(requant_cfg_ready),
      .cfg_bias(cfg_bias),
      .cfg_multiplier(cfg_multiplier),
      .cfg_right_shift(cfg_right_shift),
      .cfg_relu(cfg_relu),
      .ingress_valid(bank_egress_valid),
      .ingress_ready(requant_ready),
      .ingress_accumulator(bank_egress_accumulator),
      .ingress_lane_mask(bank_egress_n_lane_mask),
      .ingress_m({3'b000, egress_raster_x_q[1:0]}),
      .ingress_tile_tag(
          resident_tile_tag_base_q + egress_tile_index_q),
      .egress_valid(requant_valid),
      .egress_ready(requant_ready_to_router),
      .egress_values(requant_values),
      .egress_lane_mask(requant_lane_mask),
      .egress_m(requant_m),
      .egress_tile_tag(requant_tile_tag),
      .idle(requant_idle)
  );

  alexnet_n8_output_router #(
      .SLICE_INDEX(SLICE_INDEX),
      .FIFO_DEPTH(FIFO_DEPTH),
      .M_W(5),
      .N_BASE_W(N_BASE_W),
      .TILE_TAG_W(TILE_TAG_W)
  ) u_router (
      .clk(clk),
      .rst(rst),
      .cfg_valid(cfg_fire),
      .cfg_ready(router_cfg_ready),
      .cfg_destination(cfg_destination),
      .cfg_n64_tile_base(cfg_n64_tile_base),
      .cfg_slice_index(3'(SLICE_INDEX)),
      .cfg_lane_mask(cfg_lane_mask),
      .ingress_valid(requant_valid),
      .ingress_ready(requant_ready_to_router),
      .ingress_values(requant_values),
      .ingress_lane_mask(requant_lane_mask),
      .ingress_m(requant_m),
      .ingress_tile_tag(requant_tile_tag),
      .egress_valid(egress_valid),
      .egress_ready(egress_ready),
      .egress_values(egress_values),
      .egress_lane_mask(egress_lane_mask),
      .egress_destination(egress_destination),
      .egress_slice(egress_slice),
      .egress_m(egress_m),
      .egress_n_base(egress_n_base),
      .egress_tile_tag(egress_tile_tag),
      .idle(router_idle),
      .queued_count(queued_count)
  );

`ifndef SYNTHESIS
  initial begin
    if (SEGMENT_DEPTH != 512 || DIM_W < 6)
      $fatal(1, "dual accum output slice requires two measured 512-word banks");
  end

  always_ff @(posedge clk) begin
    if (!rst) begin
      if (cfg_fire && (!requant_cfg_ready || !router_cfg_ready))
        $fatal(1, "dual accum output-slice configuration was not atomic");
      if (chunk_fire && chunk_first &&
          ((chunk_word_count % chunk_output_width) != 0))
        $fatal(1, "dual accum raster words must cover whole rows");
      if (tile_valid && tile_ready &&
          tile_n_lane_mask != bank_resident_n_lane_mask)
        $fatal(1, "dual accum tile N mask changed within transaction");
      if (scanner_fire && bank_ingress_word_index >= bank_resident_word_count)
        $fatal(1, "dual accum scanner exceeded raster word count");
      if (bank_egress_fire &&
          bank_egress_word_index !=
              egress_words_transferred_q[BANK_ADDR_W-1:0])
        $fatal(1, "dual accum final raster order mismatch");
      if (bank_egress_valid &&
          bank_egress_context_tag != bank_resident_context_tag)
        $fatal(1, "dual accum final context tag mismatch");
      if (bank_emit_done && egress_words_transferred_q !=
          resident_word_count_q)
        $fatal(1, "dual accum final word count mismatch");
    end
  end
`endif

endmodule
