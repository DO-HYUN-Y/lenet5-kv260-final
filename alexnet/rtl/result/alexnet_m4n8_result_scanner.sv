`timescale 1ns/1ps

// Snapshots one logical MxN8 holding bank, releases every packed PE together,
// then serializes the registered snapshot into N8 accumulator beats. The
// snapshot can drain while the SA computes the next tile, removing the old
// post-reduce serialization bubble from the compute schedule.
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

  logic descriptor_active_q;
  logic buffer_valid_q;
  logic [M_COUNT_W-1:0] m_count_q;
  logic [M_COUNT_W-1:0] buffer_m_count_q;
  logic [M_INDEX_W-1:0] scan_m_q;
  logic [COLS-1:0] n_lane_mask_q;
  logic [COLS-1:0] buffer_n_lane_mask_q;
  logic [TILE_TAG_W-1:0] tile_tag_q;
  logic [TILE_TAG_W-1:0] buffer_tile_tag_q;
  logic signed [31:0] buffer_accumulator_q
      [0:2*PHYS_ROWS-1][0:COLS-1];

  logic all_active_holds_valid;
  logic capture_fire;

  assign tile_ready = !descriptor_active_q;
  assign busy = descriptor_active_q || buffer_valid_q;
  assign out_m = scan_m_q;
  assign out_n_lane_mask = buffer_n_lane_mask_q;
  assign out_tile_tag = buffer_tile_tag_q;

  always_comb begin
    all_active_holds_valid = 1'b1;
    for (int g = 0; g < PHYS_ROWS; g++) begin
      if (M_COUNT_W'(2*g) < m_count_q)
        for (int c = 0; c < COLS; c++)
          all_active_holds_valid &= hold_valid[g][c];
    end
  end

  assign capture_fire = descriptor_active_q && !buffer_valid_q &&
                        all_active_holds_valid;
  assign out_valid = buffer_valid_q;

  always_comb begin
    for (int c = 0; c < COLS; c++)
      out_accumulator[c] = buffer_accumulator_q[scan_m_q][c];
  end

  always_comb begin
    for (int g = 0; g < PHYS_ROWS; g++)
      for (int c = 0; c < COLS; c++)
        hold_ready[g][c] = 1'b0;

    if (capture_fire)
      for (int g = 0; g < PHYS_ROWS; g++)
        if (M_COUNT_W'(2*g) < m_count_q)
          for (int c = 0; c < COLS; c++)
            hold_ready[g][c] = 1'b1;
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      descriptor_active_q <= 1'b0;
      buffer_valid_q <= 1'b0;
      m_count_q <= '0;
      buffer_m_count_q <= '0;
      scan_m_q <= '0;
      n_lane_mask_q <= '0;
      buffer_n_lane_mask_q <= '0;
      tile_tag_q <= '0;
      buffer_tile_tag_q <= '0;
      for (int m = 0; m < 2*PHYS_ROWS; m++)
        for (int c = 0; c < COLS; c++)
          buffer_accumulator_q[m][c] <= '0;
      tile_done <= 1'b0;
    end else begin
      tile_done <= 1'b0;

      if (tile_valid && tile_ready) begin
        descriptor_active_q <= 1'b1;
        m_count_q <= tile_m_count;
        n_lane_mask_q <= tile_n_lane_mask;
        tile_tag_q <= tile_tag;
      end

      if (capture_fire) begin
        descriptor_active_q <= 1'b0;
        buffer_valid_q <= 1'b1;
        buffer_m_count_q <= m_count_q;
        buffer_n_lane_mask_q <= n_lane_mask_q;
        buffer_tile_tag_q <= tile_tag_q;
        scan_m_q <= '0;
        tile_done <= 1'b1;
        for (int m = 0; m < 2*PHYS_ROWS; m++) begin
          for (int c = 0; c < COLS; c++) begin
            if ((M_COUNT_W'(m) >= m_count_q) || !n_lane_mask_q[c] ||
                !hold_m_lane_mask[m/2][c][m%2])
              buffer_accumulator_q[m][c] <= '0;
            else if ((m % 2) != 0)
              buffer_accumulator_q[m][c] <= hold_hi[m/2][c];
            else
              buffer_accumulator_q[m][c] <= hold_lo[m/2][c];
          end
        end
      end

      if (out_valid && out_ready) begin
        if (M_COUNT_W'(scan_m_q) == (buffer_m_count_q - 1'b1)) begin
          buffer_valid_q <= 1'b0;
          scan_m_q <= '0;
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

      if (capture_fire) begin
        for (int g = 0; g < PHYS_ROWS; g++) begin
          if ((M_COUNT_W'(g) << 1) + 1'b1 == m_count_q)
          expected_m_mask = 2'b01;
          else if (M_COUNT_W'(g) * 2 < m_count_q)
            expected_m_mask = 2'b11;
          else
            expected_m_mask = 2'b00;

          for (int c = 0; c < COLS; c++) begin
            // Inactive physical rows can retain the lane mask from an older
            // tile because no result is produced or consumed for those PEs.
            // They are explicitly zeroed in the snapshot above; only active
            // rows carry a meaningful mask for this descriptor.
            if (expected_m_mask != 2'b00 &&
                hold_m_lane_mask[g][c] !== expected_m_mask)
              $fatal(1, "scanner M mask mismatch at row=%0d col=%0d", g, c);
          end
        end
      end
    end
  end
`endif

endmodule
