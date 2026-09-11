`timescale 1ns/1ps

// Captures all 64 logical M8xN8 accumulators in one cycle. The registered
// result group drains independently while the SA starts the following tile.
module alexnet_m8n8_result_snapshot #(
    parameter int TILE_TAG_W = 16,
    parameter int M_COUNT_W = 4
) (
    input logic clk,
    input logic rst,

    input  logic                  tile_valid,
    output logic                  tile_ready,
    input  logic [M_COUNT_W-1:0]  tile_m_count,
    input  logic [7:0]            tile_n_lane_mask,
    input  logic [TILE_TAG_W-1:0] tile_tag,

    input  logic hold_valid [0:3][0:7],
    output logic hold_ready [0:3][0:7],
    input  logic signed [31:0] hold_lo [0:3][0:7],
    input  logic signed [31:0] hold_hi [0:3][0:7],
    input  logic [1:0] hold_m_lane_mask [0:3][0:7],

    output logic out_valid,
    input  logic out_ready,
    output logic [M_COUNT_W-1:0] out_m_count,
    output logic signed [31:0] out_accumulator [0:7][0:7],
    output logic [7:0] out_n_lane_mask,
    output logic [TILE_TAG_W-1:0] out_tile_tag,

    output logic busy,
    output logic tile_done
);

  logic descriptor_active_q;
  logic [M_COUNT_W-1:0] descriptor_m_count_q;
  logic [7:0] descriptor_n_lane_mask_q;
  logic [TILE_TAG_W-1:0] descriptor_tile_tag_q;
  logic all_active_holds_valid;
  logic capture_fire;

  assign tile_ready = !descriptor_active_q;
  assign busy = descriptor_active_q || out_valid;

  always_comb begin
    all_active_holds_valid = 1'b1;
    for (int g = 0; g < 4; g++) begin
      if (M_COUNT_W'(2*g) < descriptor_m_count_q)
        for (int n = 0; n < 8; n++)
          all_active_holds_valid &= hold_valid[g][n];
    end
  end

  assign capture_fire = descriptor_active_q && !out_valid &&
                        all_active_holds_valid;

  always_comb begin
    for (int g = 0; g < 4; g++)
      for (int n = 0; n < 8; n++)
        hold_ready[g][n] = capture_fire &&
                           (M_COUNT_W'(2*g) < descriptor_m_count_q);
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      descriptor_active_q <= 1'b0;
      descriptor_m_count_q <= '0;
      descriptor_n_lane_mask_q <= '0;
      descriptor_tile_tag_q <= '0;
      out_valid <= 1'b0;
      out_m_count <= '0;
      out_n_lane_mask <= '0;
      out_tile_tag <= '0;
      tile_done <= 1'b0;
      for (int m = 0; m < 8; m++)
        for (int n = 0; n < 8; n++)
          out_accumulator[m][n] <= '0;
    end else begin
      tile_done <= 1'b0;

      if (out_valid && out_ready)
        out_valid <= 1'b0;

      if (tile_valid && tile_ready) begin
        descriptor_active_q <= 1'b1;
        descriptor_m_count_q <= tile_m_count;
        descriptor_n_lane_mask_q <= tile_n_lane_mask;
        descriptor_tile_tag_q <= tile_tag;
      end

      if (capture_fire) begin
        descriptor_active_q <= 1'b0;
        out_valid <= 1'b1;
        out_m_count <= descriptor_m_count_q;
        out_n_lane_mask <= descriptor_n_lane_mask_q;
        out_tile_tag <= descriptor_tile_tag_q;
        tile_done <= 1'b1;
        for (int m = 0; m < 8; m++) begin
          for (int n = 0; n < 8; n++) begin
            if (M_COUNT_W'(m) >= descriptor_m_count_q ||
                !descriptor_n_lane_mask_q[n] ||
                !hold_m_lane_mask[m/2][n][m%2])
              out_accumulator[m][n] <= '0;
            else if ((m % 2) != 0)
              out_accumulator[m][n] <= hold_hi[m/2][n];
            else
              out_accumulator[m][n] <= hold_lo[m/2][n];
          end
        end
      end
    end
  end

`ifndef SYNTHESIS
  always_ff @(posedge clk) begin
    logic [1:0] expected_m_mask;
    if (!rst) begin
      if (tile_valid && tile_ready) begin
        if (tile_m_count < 1 || tile_m_count > 8)
          $fatal(1, "M8 snapshot tile_m_count is outside 1..8");
        if (tile_n_lane_mask == 0 ||
            ((tile_n_lane_mask & (tile_n_lane_mask + 1'b1)) != 0))
          $fatal(1, "M8 snapshot N mask must be a nonzero low-lane tail");
      end
      if (capture_fire) begin
        for (int g = 0; g < 4; g++) begin
          if (M_COUNT_W'(2*g + 1) == descriptor_m_count_q)
            expected_m_mask = 2'b01;
          else if (M_COUNT_W'(2*g) < descriptor_m_count_q)
            expected_m_mask = 2'b11;
          else
            expected_m_mask = 2'b00;
          if (expected_m_mask != 0)
            for (int n = 0; n < 8; n++)
              if (hold_m_lane_mask[g][n] !== expected_m_mask)
                $fatal(1, "M8 snapshot M mask mismatch row=%0d n=%0d", g, n);
        end
      end
    end
  end
`endif

endmodule
