`timescale 1ns/1ps
// banked_maxpool2x2.sv -- eight-bank, stride-2 signed-INT8 MaxPool engine.
//
// Activation-bank layout:
//   bank = channel % NC
//   slot = channel / NC
//   word = base + slot*plane_words + floor(position/2)
//
// Each input bank uses both BRAM read ports in the same cycle: port A reads
// the top horizontal pair and port B the bottom pair. Eight scalar MaxPool
// lanes therefore produce up to eight INT8 outputs per cycle. The output
// bank write uses one byte enable per result; no requantization or FIFO is
// present. rd_*_data must have exactly one registered-read cycle of latency.

module banked_maxpool2x2 #(
  parameter int NC              = 8,
  parameter int ADDR_W          = 10,
  parameter int DIM_W           = 8,
  parameter int CHANNEL_W       = 8,
  parameter int MAX_CHANNELS    = 16
) (
  input  logic clk,
  input  logic rst_n,
  input  logic start,

  input  logic [DIM_W-1:0]     cfg_in_w,
  input  logic [DIM_W-1:0]     cfg_in_h,
  input  logic [CHANNEL_W-1:0] cfg_channels,
  input  logic [ADDR_W-1:0]    cfg_in_base_word,
  input  logic [ADDR_W-1:0]    cfg_out_base_word,
  input  logic [ADDR_W-1:0]    cfg_in_plane_words,
  input  logic [ADDR_W-1:0]    cfg_out_plane_words,

  output logic                  rd_en [0:NC-1],
  output logic [ADDR_W-1:0]     rd_top_addr [0:NC-1],
  output logic [ADDR_W-1:0]     rd_bottom_addr [0:NC-1],
  input  logic [15:0]           rd_top_data [0:NC-1],
  input  logic [15:0]           rd_bottom_data [0:NC-1],

  output logic                  wr_en [0:NC-1],
  output logic [ADDR_W-1:0]     wr_addr [0:NC-1],
  output logic [15:0]           wr_data [0:NC-1],
  output logic [1:0]            wr_strb [0:NC-1],

  output logic busy,
  output logic done
);

  logic [DIM_W-1:0] in_w_r;
  logic [DIM_W-1:0] out_w_r;
  logic [DIM_W-1:0] out_h_r;
  logic [CHANNEL_W-1:0] channels_r;
  logic [ADDR_W-1:0] in_plane_words_r;
  logic [ADDR_W-1:0] out_plane_words_r;

  logic issuing_r;
  logic [DIM_W-1:0] out_x_r;
  logic [DIM_W-1:0] out_y_r;
  logic [CHANNEL_W-1:0] slot_channel_base_r;
  logic [ADDR_W-1:0] in_slot_base_r;
  logic [ADDR_W-1:0] out_slot_base_r;
  logic [ADDR_W-1:0] top_row_addr_r;
  logic [ADDR_W-1:0] bottom_row_addr_r;
  logic [ADDR_W-1:0] out_word_addr_r;
  logic out_byte_sel_r;

  logic active_mask_c [0:NC-1];
  logic issue_last_c;

  always_comb begin
    for (int c = 0; c < NC; c++) begin
      active_mask_c[c] =
          (CHANNEL_W'(slot_channel_base_r + CHANNEL_W'(c)) < channels_r);
      rd_en[c] = issuing_r && active_mask_c[c];
      rd_top_addr[c] = top_row_addr_r + ADDR_W'(out_x_r);
      rd_bottom_addr[c] = bottom_row_addr_r + ADDR_W'(out_x_r);
    end
    issue_last_c =
        (out_x_r == out_w_r - 1'b1) &&
        (out_y_r == out_h_r - 1'b1) &&
        (CHANNEL_W'(slot_channel_base_r + CHANNEL_W'(NC)) >= channels_r);
  end

  logic rd_rsp_valid_r;
  logic rd_rsp_last_r;
  logic rd_rsp_active_r [0:NC-1];
  logic [ADDR_W-1:0] rd_rsp_out_addr_r;
  logic rd_rsp_byte_sel_r;

  logic pool_in_ready [0:NC-1];
  logic pool_out_valid [0:NC-1];
  logic signed [7:0] pool_out_data [0:NC-1];
  logic pool_meta_valid_r;
  logic pool_meta_last_r;
  logic pool_meta_active_r [0:NC-1];
  logic [ADDR_W-1:0] pool_meta_addr_r;
  logic pool_meta_byte_sel_r;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      in_w_r <= '0;
      out_w_r <= '0;
      out_h_r <= '0;
      channels_r <= '0;
      in_plane_words_r <= '0;
      out_plane_words_r <= '0;
      issuing_r <= 1'b0;
      busy <= 1'b0;
      done <= 1'b0;
      out_x_r <= '0;
      out_y_r <= '0;
      slot_channel_base_r <= '0;
      in_slot_base_r <= '0;
      out_slot_base_r <= '0;
      top_row_addr_r <= '0;
      bottom_row_addr_r <= '0;
      out_word_addr_r <= '0;
      out_byte_sel_r <= 1'b0;
      rd_rsp_valid_r <= 1'b0;
      rd_rsp_last_r <= 1'b0;
      rd_rsp_out_addr_r <= '0;
      rd_rsp_byte_sel_r <= 1'b0;
      for (int c = 0; c < NC; c++)
        rd_rsp_active_r[c] <= 1'b0;
    end else begin
      done <= 1'b0;

      if (start) begin
        in_w_r <= cfg_in_w;
        out_w_r <= cfg_in_w >> 1;
        out_h_r <= cfg_in_h >> 1;
        channels_r <= cfg_channels;
        in_plane_words_r <= cfg_in_plane_words;
        out_plane_words_r <= cfg_out_plane_words;
        issuing_r <= 1'b1;
        busy <= 1'b1;
        out_x_r <= '0;
        out_y_r <= '0;
        slot_channel_base_r <= '0;
        in_slot_base_r <= cfg_in_base_word;
        out_slot_base_r <= cfg_out_base_word;
        top_row_addr_r <= cfg_in_base_word;
        bottom_row_addr_r <=
            cfg_in_base_word + ADDR_W'(cfg_in_w >> 1);
        out_word_addr_r <= cfg_out_base_word;
        out_byte_sel_r <= 1'b0;
        rd_rsp_valid_r <= 1'b0;
        rd_rsp_last_r <= 1'b0;
        for (int c = 0; c < NC; c++)
          rd_rsp_active_r[c] <= 1'b0;
      end else begin
        rd_rsp_valid_r <= issuing_r;
        rd_rsp_last_r <= issuing_r && issue_last_c;
        rd_rsp_out_addr_r <= out_word_addr_r;
        rd_rsp_byte_sel_r <= out_byte_sel_r;
        for (int c = 0; c < NC; c++)
          rd_rsp_active_r[c] <= issuing_r && active_mask_c[c];

        if (issuing_r) begin
          if (out_byte_sel_r) begin
            out_word_addr_r <= out_word_addr_r + 1'b1;
            out_byte_sel_r <= 1'b0;
          end else begin
            out_byte_sel_r <= 1'b1;
          end

          if (out_x_r == out_w_r - 1'b1) begin
            out_x_r <= '0;
            if (out_y_r == out_h_r - 1'b1) begin
              out_y_r <= '0;
              if (issue_last_c) begin
                issuing_r <= 1'b0;
              end else begin
                slot_channel_base_r <=
                    slot_channel_base_r + CHANNEL_W'(NC);
                in_slot_base_r <=
                    in_slot_base_r + in_plane_words_r;
                out_slot_base_r <=
                    out_slot_base_r + out_plane_words_r;
                top_row_addr_r <=
                    in_slot_base_r + in_plane_words_r;
                bottom_row_addr_r <=
                    in_slot_base_r + in_plane_words_r +
                    ADDR_W'(in_w_r >> 1);
                out_word_addr_r <=
                    out_slot_base_r + out_plane_words_r;
                out_byte_sel_r <= 1'b0;
              end
            end else begin
              out_y_r <= out_y_r + 1'b1;
              top_row_addr_r <= top_row_addr_r + ADDR_W'(in_w_r);
              bottom_row_addr_r <=
                  bottom_row_addr_r + ADDR_W'(in_w_r);
            end
          end else begin
            out_x_r <= out_x_r + 1'b1;
          end
        end

        if (pool_meta_valid_r && pool_meta_last_r) begin
          done <= 1'b1;
          busy <= 1'b0;
        end
      end
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n || start) begin
      pool_meta_valid_r <= 1'b0;
      pool_meta_last_r <= 1'b0;
      pool_meta_addr_r <= '0;
      pool_meta_byte_sel_r <= 1'b0;
      for (int c = 0; c < NC; c++)
        pool_meta_active_r[c] <= 1'b0;
    end else begin
      pool_meta_valid_r <= rd_rsp_valid_r;
      pool_meta_last_r <= rd_rsp_last_r;
      pool_meta_addr_r <= rd_rsp_out_addr_r;
      pool_meta_byte_sel_r <= rd_rsp_byte_sel_r;
      for (int c = 0; c < NC; c++)
        pool_meta_active_r[c] <= rd_rsp_active_r[c];
    end
  end

  generate
    for (genvar c = 0; c < NC; c++) begin : g_pool_lane
      maxpool2x2_int8 u_pool (
        .clk(clk), .rst_n(rst_n), .flush(start),
        .in_valid(rd_rsp_valid_r && rd_rsp_active_r[c]),
        .in_ready(pool_in_ready[c]),
        .top_pair(rd_top_data[c]),
        .bottom_pair(rd_bottom_data[c]),
        .out_valid(pool_out_valid[c]), .out_ready(1'b1),
        .out_data(pool_out_data[c])
      );

      always_comb begin
        wr_en[c] = pool_out_valid[c] &&
                   pool_meta_valid_r && pool_meta_active_r[c];
        wr_addr[c] = pool_meta_addr_r;
        if (pool_meta_byte_sel_r) begin
          wr_data[c] = {pool_out_data[c], 8'h00};
          wr_strb[c] = 2'b10;
        end else begin
          wr_data[c] = {8'h00, pool_out_data[c]};
          wr_strb[c] = 2'b01;
        end
      end
    end
  endgenerate

`ifdef SIMULATION
  assert property (@(posedge clk) disable iff (!rst_n)
      start |-> (!busy &&
                 (cfg_in_w != 0) && !cfg_in_w[0] &&
                 (cfg_in_h != 0) && !cfg_in_h[0] &&
                 (cfg_channels != 0) &&
                 (cfg_channels <= MAX_CHANNELS)));
  for (genvar c = 0; c < NC; c++) begin : g_pool_assert
    assert property (@(posedge clk) disable iff (!rst_n)
        rd_rsp_active_r[c] |-> pool_in_ready[c]);
    assert property (@(posedge clk) disable iff (!rst_n)
        wr_en[c] |-> !$isunknown({wr_addr[c], wr_data[c], wr_strb[c]}));
  end
`endif

endmodule
