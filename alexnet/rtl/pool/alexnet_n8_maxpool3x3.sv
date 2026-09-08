`timescale 1ns/1ps

// One independent N8 streaming max-pool slice. Input pixels arrive in raster
// order for one frame. One read-first line memory alternates between an even
// row and the vertical maximum of that even row with the following odd row.
// The next even row completes the vertical 3-tap maximum; three horizontal
// taps then form the 3x3 result. Output coordinates implement kernel=3,
// stride=2, padding=0 exactly.
module alexnet_n8_maxpool3x3 #(
    parameter int MAX_INPUT_WIDTH = 55,
    parameter int DIM_W = 6,
    parameter int N_BASE_W = 16,
    parameter int FRAME_TAG_W = 16
) (
    input logic clk,
    input logic rst,

    input  logic frame_valid,
    output logic frame_ready,
    input  logic [DIM_W-1:0] frame_input_h,
    input  logic [DIM_W-1:0] frame_input_w,
    input  logic [7:0] frame_lane_mask,
    input  logic [N_BASE_W-1:0] frame_n_base,
    input  logic [FRAME_TAG_W-1:0] frame_tag,

    input  logic s_valid,
    output logic s_ready,
    input  logic [63:0] s_values,
    input  logic [7:0] s_lane_mask,

    output logic m_valid,
    input  logic m_ready,
    output logic [63:0] m_values,
    output logic [7:0] m_lane_mask,
    output logic [DIM_W-1:0] m_y,
    output logic [DIM_W-1:0] m_x,
    output logic [N_BASE_W-1:0] m_n_base,
    output logic [FRAME_TAG_W-1:0] m_frame_tag,

    output logic frame_active,
    output logic frame_done,
    output logic idle
);

  (* ram_style = "block" *) logic [63:0] line_mem [0:MAX_INPUT_WIDTH-1];

  logic [DIM_W-1:0] input_h_q;
  logic [DIM_W-1:0] input_w_q;
  logic [7:0] lane_mask_q;
  logic [N_BASE_W-1:0] n_base_q;
  logic [FRAME_TAG_W-1:0] frame_tag_q;
  logic [DIM_W-1:0] in_y_q;
  logic [DIM_W-1:0] in_x_q;
  logic input_complete_q;
  logic stage_complete_q;

  logic rd_valid_q;
  logic rd_last_q;
  logic [DIM_W-1:0] rd_y_q;
  logic [DIM_W-1:0] rd_x_q;
  logic [63:0] rd_values_q;
  logic [63:0] line_read_q;

  logic [63:0] vertical_d1_q;
  logic [63:0] vertical_d2_q;

  logic [63:0] s_values_masked;
  logic [63:0] vertical_now;
  logic [63:0] pooled_values;
  logic rd_will_emit;
  logic output_slot_ready;
  logic stage_advance;
  logic s_fire;
  logic frame_fire;

  function automatic logic signed [7:0] max2(
      input logic signed [7:0] a,
      input logic signed [7:0] b);
    max2 = (a > b) ? a : b;
  endfunction

  assign idle = !frame_active && !rd_valid_q && !m_valid;
  assign frame_ready = idle;
  assign frame_fire = frame_valid && frame_ready;

  assign rd_will_emit = rd_valid_q && (rd_y_q >= 2) && (rd_x_q >= 2) &&
                        !rd_y_q[0] && !rd_x_q[0];
  assign output_slot_ready = !m_valid || m_ready;
  assign stage_advance = !rd_valid_q || !rd_will_emit || output_slot_ready;
  assign s_ready = frame_active && !input_complete_q && stage_advance;
  assign s_fire = s_valid && s_ready;

  always_comb begin
    s_values_masked = '0;
    vertical_now = '0;
    pooled_values = '0;
    for (int lane = 0; lane < 8; lane++) begin
      if (s_lane_mask[lane])
        s_values_masked[lane*8 +: 8] = s_values[lane*8 +: 8];
      vertical_now[lane*8 +: 8] = max2(
          $signed(line_read_q[lane*8 +: 8]),
          $signed(rd_values_q[lane*8 +: 8]));
      if (lane_mask_q[lane]) begin
        pooled_values[lane*8 +: 8] = max2(
            max2($signed(vertical_d2_q[lane*8 +: 8]),
                 $signed(vertical_d1_q[lane*8 +: 8])),
            $signed(vertical_now[lane*8 +: 8]));
      end
    end
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      input_h_q <= '0;
      input_w_q <= '0;
      lane_mask_q <= '0;
      n_base_q <= '0;
      frame_tag_q <= '0;
      in_y_q <= '0;
      in_x_q <= '0;
      input_complete_q <= 1'b0;
      stage_complete_q <= 1'b0;
      rd_valid_q <= 1'b0;
      rd_last_q <= 1'b0;
      rd_y_q <= '0;
      rd_x_q <= '0;
      rd_values_q <= '0;
      line_read_q <= '0;
      vertical_d1_q <= '0;
      vertical_d2_q <= '0;
      m_valid <= 1'b0;
      m_values <= '0;
      m_lane_mask <= '0;
      m_y <= '0;
      m_x <= '0;
      m_n_base <= '0;
      m_frame_tag <= '0;
      frame_active <= 1'b0;
      frame_done <= 1'b0;
    end else begin
      frame_done <= 1'b0;

      if (m_valid && m_ready)
        m_valid <= 1'b0;

      if (frame_fire) begin
        input_h_q <= frame_input_h;
        input_w_q <= frame_input_w;
        lane_mask_q <= frame_lane_mask;
        n_base_q <= frame_n_base;
        frame_tag_q <= frame_tag;
        in_y_q <= '0;
        in_x_q <= '0;
        input_complete_q <= 1'b0;
        stage_complete_q <= 1'b0;
        frame_active <= 1'b1;
      end

      if (stage_advance) begin
        if (rd_valid_q) begin
          // Odd rows replace the stored even row with their lane-wise pair
          // maximum. Even rows consume that pair maximum and then become the
          // stored base for the following odd row.
          if (rd_y_q[0])
            line_mem[rd_x_q] <= vertical_now;
          else
            line_mem[rd_x_q] <= rd_values_q;

          if (!rd_y_q[0] && rd_x_q == 0) begin
            vertical_d1_q <= vertical_now;
            vertical_d2_q <= '0;
          end else if (!rd_y_q[0]) begin
            vertical_d2_q <= vertical_d1_q;
            vertical_d1_q <= vertical_now;
          end

          if (rd_will_emit) begin
            m_valid <= 1'b1;
            m_values <= pooled_values;
            m_lane_mask <= lane_mask_q;
            m_y <= (rd_y_q - 2) >> 1;
            m_x <= (rd_x_q - 2) >> 1;
            m_n_base <= n_base_q;
            m_frame_tag <= frame_tag_q;
          end

          if (rd_last_q)
            stage_complete_q <= 1'b1;
        end

        rd_valid_q <= s_fire;
        if (s_fire) begin
          rd_y_q <= in_y_q;
          rd_x_q <= in_x_q;
          rd_values_q <= s_values_masked;
          rd_last_q <= (in_y_q == input_h_q - 1) &&
                       (in_x_q == input_w_q - 1);
          line_read_q <= line_mem[in_x_q];

          if (in_x_q == input_w_q - 1) begin
            in_x_q <= '0;
            if (in_y_q == input_h_q - 1) begin
              input_complete_q <= 1'b1;
            end else begin
              in_y_q <= in_y_q + 1'b1;
            end
          end else begin
            in_x_q <= in_x_q + 1'b1;
          end
        end
      end

      if (frame_active && stage_complete_q && !rd_valid_q && !m_valid) begin
        frame_active <= 1'b0;
        frame_done <= 1'b1;
      end
    end
  end

`ifndef SYNTHESIS
  always_ff @(posedge clk) begin
    if (!rst) begin
      if (frame_fire && (frame_input_h < 3 || frame_input_w < 3 ||
                         frame_input_w > MAX_INPUT_WIDTH))
        $fatal(1, "maxpool frame dimensions are outside the supported range");
      if (frame_fire && s_valid)
        $fatal(1, "maxpool frame descriptor requires a standalone source cycle");
      if (s_valid && !frame_active)
        $fatal(1, "maxpool input arrived without an active frame");
      if (s_fire && s_lane_mask != lane_mask_q)
        $fatal(1, "maxpool input lane mask changed inside a frame");
      if (s_valid && input_complete_q)
        $fatal(1, "maxpool received data after the final frame pixel");
    end
  end
`endif

endmodule
