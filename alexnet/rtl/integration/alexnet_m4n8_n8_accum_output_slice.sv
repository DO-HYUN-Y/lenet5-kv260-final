`timescale 1ns/1ps

// Accumulator-aware M4/M8xN8 output path. PHYS_ROWS=4 selects a fully M8-
// banked snapshot, partial-sum, and 64-DSP requant pipeline. PHYS_ROWS=2 keeps
// the original scalar M4 path for compatibility and focused regressions.
//
// Each chunk covers one complete raster segment beginning at x=0. Scanner
// tile tags are checked against the row-local M4 sequence. The final replay
// reconstructs the same M coordinate and tile tag without storing metadata in
// the 256-bit partial-sum BRAM payload.
module alexnet_m4n8_n8_accum_output_slice #(
    parameter int PHYS_ROWS = 2,
    parameter int M_GROUP = 2 * PHYS_ROWS,
    parameter int M_COUNT_W = $clog2(M_GROUP + 1),
    parameter int M_INDEX_W = $clog2(M_GROUP),
    parameter int SLICE_INDEX = 0,
    parameter int FIFO_DEPTH = 64,
    parameter int BANK_DEPTH = 512,
    parameter int DIM_W = 8,
    parameter int TILE_TAG_W = 16,
    parameter int CONTEXT_TAG_W = 16,
    parameter int CHUNK_INDEX_W = 8,
    parameter int N_BASE_W = 16,
    parameter int BANK_ADDR_W = $clog2(BANK_DEPTH),
    parameter int BANK_COUNT_W = $clog2(BANK_DEPTH + 1),
    parameter bit RUNTIME_SLICE_INDEX = 1'b0
) (
    input logic clk,
    input logic rst,

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

    input  logic tile_valid,
    output logic tile_ready,
    input  logic [M_COUNT_W-1:0] tile_m_count,
    input  logic [7:0] tile_n_lane_mask,
    input  logic [TILE_TAG_W-1:0] tile_tag,

    input  logic hold_valid [0:PHYS_ROWS-1][0:7],
    output logic hold_ready [0:PHYS_ROWS-1][0:7],
    input  logic signed [31:0] hold_lo [0:PHYS_ROWS-1][0:7],
    input  logic signed [31:0] hold_hi [0:PHYS_ROWS-1][0:7],
    input  logic [1:0] hold_m_lane_mask [0:PHYS_ROWS-1][0:7],

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
  localparam int M8_GROUP_DEPTH = (BANK_DEPTH + 7) / 8;
  localparam int M8_GROUP_ADDR_W = $clog2(M8_GROUP_DEPTH);
  localparam int M8_GROUP_COUNT_W = $clog2(M8_GROUP_DEPTH + 1);
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
  logic [M_INDEX_W-1:0] scanner_m;
  logic [7:0] scanner_lane_mask;
  logic [TILE_TAG_W-1:0] scanner_tile_tag;
  logic scanner_busy;
  logic bank_accepting_scanner_words;
  logic scanner_metadata_match;
  logic scanner_fire;

  // M8-wide path probes are deliberately module-visible. The generated
  // shared-compute scoreboard checks every accumulator before banking.
  logic wide_scanner_valid;
  logic wide_scanner_ready;
  logic [M_COUNT_W-1:0] wide_scanner_m_count;
  logic signed [31:0] wide_scanner_accumulator [0:7][0:7];
  logic [7:0] wide_scanner_lane_mask;
  logic [TILE_TAG_W-1:0] wide_scanner_tile_tag;

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

  logic [M8_GROUP_COUNT_W-1:0] bank_resident_group_count;
  logic [M8_GROUP_COUNT_W-1:0] bank_groups_accepted;
  logic [M_COUNT_W-1:0] wide_bank_egress_m_count;
  logic signed [31:0] wide_bank_egress_accumulator [0:7][0:7];
  logic [M8_GROUP_ADDR_W-1:0] wide_bank_egress_group_index;

  // Simulation-only scalar mirrors keep the established layer scoreboards
  // checking every M word while the functional M8 path transfers one group.
  logic scanner_debug_valid_q;
  logic [2:0] scanner_debug_m_q;
  logic [M_COUNT_W-1:0] scanner_debug_m_count_q;
  logic signed [31:0] scanner_debug_accumulator_q [0:7][0:7];
  logic [7:0] scanner_debug_lane_mask_q;
  logic [TILE_TAG_W-1:0] scanner_debug_tile_tag_q;
  logic bank_debug_valid_q;
  logic [2:0] bank_debug_m_q;
  logic [M_COUNT_W-1:0] bank_debug_m_count_q;
  logic signed [31:0] bank_debug_accumulator_q [0:7][0:7];

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

  assign slice_idle = !scanner_busy && bank_idle && requant_idle &&
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
        if (PHYS_ROWS == 4) begin
          ingress_tile_index_q <= ingress_tile_index_q + 1'b1;
          if (ingress_raster_x_q + wide_scanner_m_count ==
              resident_output_width_q)
            ingress_raster_x_q <= '0;
          else
            ingress_raster_x_q <=
                ingress_raster_x_q + wide_scanner_m_count;
        end else begin
          // M groups are flattened across raster-row boundaries.  A row
          // boundary therefore advances only the raster coordinate; the tile
          // index advances after the fourth sequential output word.
          if (bank_words_accepted[M_INDEX_W-1:0] ==
              M_INDEX_W'(M_GROUP-1))
            ingress_tile_index_q <= ingress_tile_index_q + 1'b1;
          if (ingress_raster_x_q + 1'b1 == resident_output_width_q)
            ingress_raster_x_q <= '0;
          else
            ingress_raster_x_q <= ingress_raster_x_q + 1'b1;
        end
      end

      if (bank_chunk_done)
        chunk_active_q <= 1'b0;

      if (bank_egress_fire) begin
        if (PHYS_ROWS == 4) begin
          egress_words_transferred_q <=
              egress_words_transferred_q + wide_bank_egress_m_count;
          egress_tile_index_q <= egress_tile_index_q + 1'b1;
        end else begin
          egress_words_transferred_q <= egress_words_transferred_q + 1'b1;
          if (egress_words_transferred_q[M_INDEX_W-1:0] ==
              M_INDEX_W'(M_GROUP-1))
            egress_tile_index_q <= egress_tile_index_q + 1'b1;
          if (egress_raster_x_q + 1'b1 == resident_output_width_q)
            egress_raster_x_q <= '0;
          else
            egress_raster_x_q <= egress_raster_x_q + 1'b1;
        end
      end

      // Keep the established scalar verification coordinate advancing beside
      // the simulation-only M8 bank mirror. Functional M8 metadata uses the
      // group index above and does not depend on this counter.
      if (PHYS_ROWS == 4 && bank_egress_valid && bank_egress_ready)
        egress_raster_x_q <= egress_raster_x_q + 1'b1;

      if (bank_emit_done) begin
        resident_output_width_q <= '0;
        resident_tile_tag_base_q <= '0;
        resident_word_count_q <= '0;
      end

      if ((PHYS_ROWS == 4 ? wide_scanner_valid : scanner_valid) &&
          !scanner_metadata_match)
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

  generate
    if (PHYS_ROWS == 4) begin : g_m8_parallel
      logic [M8_GROUP_ADDR_W-1:0] wide_bank_ingress_group_index;
      logic wide_bank_ingress_last;
      logic wide_bank_egress_valid;
      logic wide_bank_egress_ready;
      logic wide_bank_egress_admit;
      logic [7:0] wide_bank_egress_n_lane_mask;
      logic wide_bank_egress_last;
      logic [CONTEXT_TAG_W-1:0] wide_bank_egress_context_tag;

      alexnet_m8n8_result_snapshot #(
          .TILE_TAG_W(TILE_TAG_W), .M_COUNT_W(M_COUNT_W)
      ) u_snapshot (
          .clk(clk), .rst(rst),
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
          .out_valid(wide_scanner_valid),
          .out_ready(wide_scanner_ready),
          .out_m_count(wide_scanner_m_count),
          .out_accumulator(wide_scanner_accumulator),
          .out_n_lane_mask(wide_scanner_lane_mask),
          .out_tile_tag(wide_scanner_tile_tag),
          .busy(scanner_busy),
          .tile_done(tile_scan_done)
      );

      assign scanner_metadata_match =
          (wide_scanner_tile_tag ==
           resident_tile_tag_base_q + ingress_tile_index_q);
      assign wide_bank_ingress_group_index =
          bank_groups_accepted[M8_GROUP_ADDR_W-1:0];
      assign wide_bank_ingress_last =
          bank_words_accepted + wide_scanner_m_count ==
          bank_resident_word_count;
      assign wide_scanner_ready = bank_ingress_ready &&
                                  scanner_metadata_match;
      assign scanner_fire = wide_scanner_valid && wide_scanner_ready;

      assign bank_ingress_valid = 1'b0;
      assign bank_ingress_word_index = '0;
      assign bank_ingress_last = 1'b0;

`ifndef SYNTHESIS
      assign scanner_valid = scanner_debug_valid_q;
      assign scanner_ready = scanner_debug_valid_q;
      assign scanner_m = M_INDEX_W'(scanner_debug_m_q);
      assign scanner_lane_mask = scanner_debug_lane_mask_q;
      assign scanner_tile_tag = scanner_debug_tile_tag_q;
      for (genvar n = 0; n < 8; n++) begin : g_scalar_scanner_probe
        assign scanner_accumulator[n] =
            scanner_debug_accumulator_q[scanner_debug_m_q][n];
        assign bank_egress_accumulator[n] =
            bank_debug_accumulator_q[bank_debug_m_q][n];
      end
`else
      assign scanner_valid = 1'b0;
      assign scanner_ready = 1'b0;
      assign scanner_m = '0;
      assign scanner_lane_mask = '0;
      assign scanner_tile_tag = '0;
      for (genvar n = 0; n < 8; n++) begin : g_zero_scalar_probe
        assign scanner_accumulator[n] = '0;
        assign bank_egress_accumulator[n] = '0;
      end
`endif

      alexnet_m8n8_int32_partial_sum_bank #(
          .LOGICAL_DEPTH(BANK_DEPTH),
          .GROUP_DEPTH(M8_GROUP_DEPTH),
          .CONTEXT_TAG_W(CONTEXT_TAG_W),
          .CHUNK_INDEX_W(CHUNK_INDEX_W),
          .LOGICAL_COUNT_W(BANK_COUNT_W),
          .GROUP_ADDR_W(M8_GROUP_ADDR_W),
          .GROUP_COUNT_W(M8_GROUP_COUNT_W),
          .M_COUNT_W(M_COUNT_W)
      ) u_parallel_partial_sum_bank (
          .clk(clk), .rst(rst),
          .descriptor_valid(bank_descriptor_valid),
          .descriptor_ready(bank_descriptor_ready),
          .descriptor_word_count(chunk_word_count),
          .descriptor_n_lane_mask(chunk_n_lane_mask),
          .descriptor_context_tag(chunk_context_tag),
          .descriptor_chunk_index(chunk_index),
          .descriptor_first_chunk(chunk_first),
          .descriptor_final_chunk(chunk_final),
          .ingress_valid(wide_scanner_valid && scanner_metadata_match),
          .ingress_ready(bank_ingress_ready),
          .ingress_m_count(wide_scanner_m_count),
          .ingress_accumulator(wide_scanner_accumulator),
          .ingress_n_lane_mask(wide_scanner_lane_mask),
          .ingress_group_index(wide_bank_ingress_group_index),
          .ingress_last(wide_bank_ingress_last),
          .egress_valid(wide_bank_egress_valid),
          .egress_ready(wide_bank_egress_ready),
          .egress_m_count(wide_bank_egress_m_count),
          .egress_accumulator(wide_bank_egress_accumulator),
          .egress_n_lane_mask(wide_bank_egress_n_lane_mask),
          .egress_group_index(wide_bank_egress_group_index),
          .egress_last(wide_bank_egress_last),
          .egress_context_tag(wide_bank_egress_context_tag),
          .bank_state(accum_bank_state),
          .resident_valid(bank_resident_valid),
          .resident_word_count(bank_resident_word_count),
          .resident_group_count(bank_resident_group_count),
          .resident_n_lane_mask(bank_resident_n_lane_mask),
          .resident_context_tag(bank_resident_context_tag),
          .next_chunk_index(bank_next_chunk_index),
          .completed_chunks(bank_completed_chunks),
          .words_accepted(bank_words_accepted),
          .groups_accepted(bank_groups_accepted),
          .chunk_done(bank_chunk_done),
          .emit_done(bank_emit_done),
          .context_error(bank_context_error),
          .protocol_error(bank_protocol_error),
          .idle(bank_idle)
      );

`ifndef SYNTHESIS
      assign wide_bank_egress_admit =
          !bank_debug_valid_q ||
          M_COUNT_W'(bank_debug_m_q) == bank_debug_m_count_q - 1'b1;
`else
      assign wide_bank_egress_admit = 1'b1;
`endif
      assign wide_bank_egress_ready = requant_ready &&
                                      wide_bank_egress_admit;
`ifndef SYNTHESIS
      assign bank_egress_valid = bank_debug_valid_q;
      assign bank_egress_ready = bank_debug_valid_q;
`else
      assign bank_egress_valid = 1'b0;
      assign bank_egress_ready = 1'b0;
`endif
      assign bank_egress_n_lane_mask = wide_bank_egress_n_lane_mask;
      assign bank_egress_word_index = '0;
      assign bank_egress_last = wide_bank_egress_last;
      assign bank_egress_context_tag = wide_bank_egress_context_tag;
      assign bank_egress_fire = wide_bank_egress_valid &&
                                wide_bank_egress_ready;

      alexnet_m8n8_requant_serializer #(
          .TILE_TAG_W(TILE_TAG_W), .M_COUNT_W(M_COUNT_W)
      ) u_requant (
          .clk(clk), .rst(rst),
          .cfg_valid(cfg_fire),
          .cfg_ready(requant_cfg_ready),
          .cfg_bias(cfg_bias),
          .cfg_multiplier(cfg_multiplier),
          .cfg_right_shift(cfg_right_shift),
          .cfg_relu(cfg_relu),
          .ingress_valid(wide_bank_egress_valid &&
                         wide_bank_egress_admit),
          .ingress_ready(requant_ready),
          .ingress_m_count(wide_bank_egress_m_count),
          .ingress_accumulator(wide_bank_egress_accumulator),
          .ingress_lane_mask(wide_bank_egress_n_lane_mask),
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

`ifndef SYNTHESIS
      always_ff @(posedge clk) begin
        if (rst) begin
          scanner_debug_valid_q <= 1'b0;
          scanner_debug_m_q <= '0;
          scanner_debug_m_count_q <= '0;
          scanner_debug_lane_mask_q <= '0;
          scanner_debug_tile_tag_q <= '0;
          bank_debug_valid_q <= 1'b0;
          bank_debug_m_q <= '0;
          bank_debug_m_count_q <= '0;
          for (int m = 0; m < 8; m++) begin
            for (int n = 0; n < 8; n++) begin
              scanner_debug_accumulator_q[m][n] <= '0;
              bank_debug_accumulator_q[m][n] <= '0;
            end
          end
        end else begin
          if (scanner_debug_valid_q) begin
            if (M_COUNT_W'(scanner_debug_m_q) ==
                scanner_debug_m_count_q - 1'b1) begin
              scanner_debug_valid_q <= 1'b0;
              scanner_debug_m_q <= '0;
            end else begin
              scanner_debug_m_q <= scanner_debug_m_q + 1'b1;
            end
          end
          if (scanner_fire) begin
            if (scanner_debug_valid_q &&
                M_COUNT_W'(scanner_debug_m_q) !=
                    scanner_debug_m_count_q - 1'b1)
              $fatal(1, "M8 scanner debug mirror overflow");
            scanner_debug_valid_q <= 1'b1;
            scanner_debug_m_q <= '0;
            scanner_debug_m_count_q <= wide_scanner_m_count;
            scanner_debug_lane_mask_q <= wide_scanner_lane_mask;
            scanner_debug_tile_tag_q <= wide_scanner_tile_tag;
            for (int m = 0; m < 8; m++)
              for (int n = 0; n < 8; n++)
                scanner_debug_accumulator_q[m][n] <=
                    wide_scanner_accumulator[m][n];
          end

          if (bank_debug_valid_q) begin
            if (M_COUNT_W'(bank_debug_m_q) ==
                bank_debug_m_count_q - 1'b1) begin
              bank_debug_valid_q <= 1'b0;
              bank_debug_m_q <= '0;
            end else begin
              bank_debug_m_q <= bank_debug_m_q + 1'b1;
            end
          end
          if (bank_egress_fire) begin
            if (bank_debug_valid_q &&
                M_COUNT_W'(bank_debug_m_q) !=
                    bank_debug_m_count_q - 1'b1)
              $fatal(1, "M8 bank debug mirror overflow");
            bank_debug_valid_q <= 1'b1;
            bank_debug_m_q <= '0;
            bank_debug_m_count_q <= wide_bank_egress_m_count;
            for (int m = 0; m < 8; m++)
              for (int n = 0; n < 8; n++)
                bank_debug_accumulator_q[m][n] <=
                    wide_bank_egress_accumulator[m][n];
          end
          if (wide_bank_egress_valid &&
              wide_bank_egress_context_tag != bank_resident_context_tag)
            $fatal(1, "M8 accum output-slice final context tag mismatch");
        end
      end
`endif
    end else begin : g_m4_scalar
      assign wide_scanner_valid = 1'b0;
      assign wide_scanner_ready = 1'b0;
      assign wide_scanner_m_count = '0;
      assign wide_scanner_lane_mask = '0;
      assign wide_scanner_tile_tag = '0;
      assign wide_bank_egress_m_count = '0;
      assign wide_bank_egress_group_index = '0;
      assign bank_resident_group_count = '0;
      assign bank_groups_accepted = '0;
      for (genvar m = 0; m < 8; m++) begin : g_zero_wide_probe_m
        for (genvar n = 0; n < 8; n++) begin : g_zero_wide_probe_n
          assign wide_scanner_accumulator[m][n] = '0;
          assign wide_bank_egress_accumulator[m][n] = '0;
        end
      end

      alexnet_m4n8_result_scanner #(
          .PHYS_ROWS(PHYS_ROWS), .COLS(8), .TILE_TAG_W(TILE_TAG_W)
      ) u_scanner (
          .clk(clk), .rst(rst),
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
          (scanner_m == bank_words_accepted[M_INDEX_W-1:0]) &&
          (scanner_tile_tag ==
           resident_tile_tag_base_q + ingress_tile_index_q);
      assign bank_ingress_valid = scanner_valid && scanner_metadata_match;
      assign scanner_ready = bank_ingress_ready && scanner_metadata_match;
      assign scanner_fire = scanner_valid && scanner_ready;
      assign bank_ingress_word_index =
          bank_words_accepted[BANK_ADDR_W-1:0];
      assign bank_ingress_last =
          bank_words_accepted + 1'b1 == bank_resident_word_count;

      alexnet_n8_int32_partial_sum_bank #(
          .DEPTH(BANK_DEPTH), .CONTEXT_TAG_W(CONTEXT_TAG_W),
          .CHUNK_INDEX_W(CHUNK_INDEX_W)
      ) u_partial_sum_bank (
          .clk(clk), .rst(rst),
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
          .M_W(5), .TILE_TAG_W(TILE_TAG_W)
      ) u_requant (
          .clk(clk), .rst(rst),
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
          .ingress_m(5'(egress_words_transferred_q[M_INDEX_W-1:0])),
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
    end
  endgenerate

  alexnet_n8_output_router #(
      .SLICE_INDEX(SLICE_INDEX),
      .RUNTIME_SLICE_INDEX(RUNTIME_SLICE_INDEX),
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
      .cfg_slice_index(cfg_slice_index),
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
    if ((BANK_DEPTH != 512 && BANK_DEPTH != 1024 && BANK_DEPTH != 4096) ||
        DIM_W < 6 || (PHYS_ROWS != 2 && PHYS_ROWS != 4))
      $fatal(1, "accum output slice supports 512, 1024, or 4096 words");
  end

  always_ff @(posedge clk) begin
    if (!rst) begin
      if (cfg_fire && (!requant_cfg_ready || !router_cfg_ready))
        $fatal(1, "accum output-slice configuration was not atomic");
      if (chunk_fire && chunk_first &&
          ((chunk_word_count % chunk_output_width) != 0))
        $fatal(1, "accum output-slice raster words must cover whole rows");
      if (tile_valid && tile_ready &&
          tile_n_lane_mask != bank_resident_n_lane_mask)
        $fatal(1, "accum output-slice tile N mask changed within transaction");
      if (PHYS_ROWS != 4 && scanner_fire &&
          bank_ingress_word_index >= bank_resident_word_count)
        $fatal(1, "accum output-slice scanner exceeded raster word count");
      if (PHYS_ROWS != 4 && bank_egress_fire &&
          bank_egress_word_index !=
              egress_words_transferred_q[BANK_ADDR_W-1:0])
        $fatal(1, "accum output-slice final raster order mismatch");
      if (PHYS_ROWS == 4 && bank_egress_fire &&
          wide_bank_egress_group_index !=
              egress_tile_index_q[M8_GROUP_ADDR_W-1:0])
        $fatal(1, "M8 accum output-slice final group order mismatch");
      if (PHYS_ROWS != 4 && bank_egress_valid &&
          bank_egress_context_tag != bank_resident_context_tag)
        $fatal(1, "accum output-slice final context tag mismatch");
      if (bank_emit_done && egress_words_transferred_q !=
          resident_word_count_q)
        $fatal(1, "accum output-slice final word count mismatch");
      if (PHYS_ROWS == 4 && chunk_fire && chunk_first &&
          ((chunk_word_count / chunk_output_width) *
           ((chunk_output_width + 7) / 8) > M8_GROUP_DEPTH))
        $fatal(1, "M8 accum output-slice padded group depth exceeded");
    end
  end
`endif

endmodule
