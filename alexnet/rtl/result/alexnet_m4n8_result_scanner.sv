`timescale 1ns/1ps

// Serializes one logical M4 x N8 holding bank into four N8 accumulator beats.
// Each packed PE holds two adjacent logical M values, so a physical row is
// released only after its last active lo/hi lane transfers.
module alexnet_m4n8_result_scanner #(
    parameter int PHYS_ROWS = 2,
    parameter int COLS = 8,
    parameter int TILE_TAG_W = 16,
    parameter int M_COUNT_W = $clog2(2 * PHYS_ROWS + 1),
    parameter int M_INDEX_W = $clog2(2 * PHYS_ROWS)
) (
    input logic clk,
    input logic rst,

    input  logic                  tile_valid,
    output logic                  tile_ready,
    input  logic [M_COUNT_W-1:0]  tile_m_count,
    input  logic [COLS-1:0]       tile_n_lane_mask,
    input  logic [TILE_TAG_W-1:0] tile_tag,

    input  logic hold_valid [0:PHYS_ROWS-1][0:COLS-1],
    output logic hold_ready [0:PHYS_ROWS-1][0:COLS-1],
    input  logic signed [31:0] hold_lo [0:PHYS_ROWS-1][0:COLS-1],
    input  logic signed [31:0] hold_hi [0:PHYS_ROWS-1][0:COLS-1],
    input  logic [1:0] hold_m_lane_mask [0:PHYS_ROWS-1][0:COLS-1],

    output logic out_valid,
    input  logic out_ready,
    output logic signed [31:0] out_accumulator [0:COLS-1],
    output logic [M_INDEX_W-1:0] out_m,
    output logic [COLS-1:0] out_n_lane_mask,
    output logic [TILE_TAG_W-1:0] out_tile_tag,

    output logic busy,
    output logic tile_done
);

  logic busy_q;
  logic [M_COUNT_W-1:0] m_count_q;
  logic [M_INDEX_W-1:0] scan_m_q;
  logic [COLS-1:0] n_lane_mask_q;
  logic [TILE_TAG_W-1:0] tile_tag_q;

  logic selected_row_valid;
  logic selected_lane_is_hi;
  logic selected_row_release;

  assign tile_ready = !busy_q;
  assign busy = busy_q;
  assign out_m = scan_m_q;
  assign out_n_lane_mask = n_lane_mask_q;
  assign out_tile_tag = tile_tag_q;
  assign selected_lane_is_hi = scan_m_q[0];
  assign selected_row_release =
      selected_lane_is_hi || (M_COUNT_W'(scan_m_q) == (m_count_q - 1'b1));

  always_comb begin
    selected_row_valid = 1'b1;
    for (int c = 0; c < COLS; c++)
      selected_row_valid &= hold_valid[scan_m_q[M_INDEX_W-1:1]][c];
  end

  assign out_valid = busy_q && selected_row_valid;

  always_comb begin
    for (int c = 0; c < COLS; c++) begin
      if (!n_lane_mask_q[c] ||
          !hold_m_lane_mask[scan_m_q[M_INDEX_W-1:1]][c][selected_lane_is_hi])
        out_accumulator[c] = '0;
      else if (selected_lane_is_hi)
        out_accumulator[c] = hold_hi[scan_m_q[M_INDEX_W-1:1]][c];
      else
        out_accumulator[c] = hold_lo[scan_m_q[M_INDEX_W-1:1]][c];
    end
  end

  always_comb begin
    for (int g = 0; g < PHYS_ROWS; g++)
      for (int c = 0; c < COLS; c++)
        hold_ready[g][c] = 1'b0;

    if (out_valid && out_ready && selected_row_release)
      for (int c = 0; c < COLS; c++)
        hold_ready[scan_m_q[M_INDEX_W-1:1]][c] = 1'b1;
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      busy_q <= 1'b0;
      m_count_q <= '0;
      scan_m_q <= '0;
      n_lane_mask_q <= '0;
      tile_tag_q <= '0;
      tile_done <= 1'b0;
    end else begin
      tile_done <= 1'b0;

      if (tile_valid && tile_ready) begin
        busy_q <= 1'b1;
        m_count_q <= tile_m_count;
        scan_m_q <= '0;
        n_lane_mask_q <= tile_n_lane_mask;
        tile_tag_q <= tile_tag;
      end

      if (out_valid && out_ready) begin
        if (M_COUNT_W'(scan_m_q) == (m_count_q - 1'b1)) begin
          busy_q <= 1'b0;
          tile_done <= 1'b1;
        end else begin
          scan_m_q <= scan_m_q + 1'b1;
        end
      end
    end
  end

`ifndef SYNTHESIS
  initial begin
    if ((PHYS_ROWS != 2 && PHYS_ROWS != 4) || COLS != 8)
      $fatal(1, "scanner supports PHYS_ROWS=2/4 and COLS=8");
  end

  always_ff @(posedge clk) begin
    logic [1:0] expected_m_mask;

    if (!rst) begin
      if (tile_valid && tile_ready) begin
        if (tile_m_count < 1 || tile_m_count > 2*PHYS_ROWS)
          $fatal(1, "scanner tile_m_count is outside the physical M range");
        if (tile_n_lane_mask == '0 ||
            ((tile_n_lane_mask & (tile_n_lane_mask + 1'b1)) != '0))
          $fatal(1, "scanner N mask must be a nonzero low-lane tail mask");
      end

      if (out_valid) begin
        if ((M_COUNT_W'(scan_m_q[M_INDEX_W-1:1]) << 1) + 1'b1 ==
            m_count_q)
          expected_m_mask = 2'b01;
        else
          expected_m_mask = 2'b11;

        for (int c = 0; c < COLS; c++) begin
          if (hold_m_lane_mask[scan_m_q[M_INDEX_W-1:1]][c] !== expected_m_mask)
            $fatal(1, "scanner M mask mismatch at row=%0d col=%0d",
                   scan_m_q[M_INDEX_W-1:1], c);
        end
      end
    end
  end
`endif

endmodule
