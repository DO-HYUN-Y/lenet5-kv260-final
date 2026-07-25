`timescale 1ns/1ps
// activation_scalar_reader.sv -- banked CHW memory to H-C-W pixel stream.
//
// On start, address zero of the selected feature map is pre-issued. During
// the following cycle pix_data is already valid for window_gen's first
// S_LOAD consumption. Each consume request simultaneously issues the next
// pixel, hiding the activation BRAM's one-cycle registered-read latency.

module activation_scalar_reader #(
  parameter int ACT_W       = 8,
  parameter int NC          = 8,
  parameter int ADDR_W      = 9,
  parameter int PLANE_W     = ADDR_W + 1,
  parameter int DIM_W       = 8,
  parameter int CHANNEL_W   = 8,
  parameter int BANK_W      = (NC < 2) ? 1 : $clog2(NC)
) (
  input  logic clk,
  input  logic rst_n,
  input  logic start,
  input  logic consume,

  input  logic [DIM_W-1:0]     cfg_width,
  input  logic [DIM_W-1:0]     cfg_height,
  input  logic [CHANNEL_W-1:0] cfg_channels,
  input  logic [ADDR_W-1:0]    cfg_base_word,
  input  logic [PLANE_W-1:0]   cfg_plane_words,

  output logic                 bank_en [0:NC-1],
  output logic [ADDR_W-1:0]    bank_addr [0:NC-1],
  input  logic [15:0]          bank_rdata [0:NC-1],

  output logic signed [ACT_W-1:0] pix_data,
  output logic                    pix_valid
);

  logic [DIM_W-1:0] width_r;
  logic [DIM_W-1:0] height_r;
  logic [CHANNEL_W-1:0] channels_r;
  logic [ADDR_W-1:0] base_word_r;
  logic [PLANE_W-1:0] plane_words_r;

  // Coordinates of the next request after the pre-issued first pixel.
  logic [DIM_W-1:0] req_x_r;
  logic [DIM_W-1:0] req_y_r;
  logic [CHANNEL_W-1:0] req_ch_r;
  logic [15:0] req_row_byte_base_r;
  logic next_req_valid_r;

  logic request_c;
  logic [BANK_W-1:0] request_bank_c;
  logic [ADDR_W-1:0] request_addr_c;
  logic request_byte_sel_c;
  logic request_last_c;
  logic [15:0] request_position_c;
  logic [PLANE_W-1:0] request_slot_offset_c;

  always_comb begin
    request_c = start || (consume && next_req_valid_r);
    if (start) begin
      request_bank_c = '0;
      request_position_c = '0;
      request_slot_offset_c = '0;
      request_addr_c = cfg_base_word;
      request_byte_sel_c = 1'b0;
      request_last_c =
          (cfg_width == 1) && (cfg_height == 1) && (cfg_channels == 1);
    end else begin
      request_bank_c = BANK_W'(req_ch_r % NC);
      request_position_c = req_row_byte_base_r + 16'(req_x_r);
      request_slot_offset_c =
          PLANE_W'(req_ch_r / NC) * plane_words_r;
      request_addr_c = base_word_r +
                       ADDR_W'(request_slot_offset_c) +
                       ADDR_W'(request_position_c >> 1);
      request_byte_sel_c = request_position_c[0];
      request_last_c =
          (req_x_r == width_r - 1'b1) &&
          (req_ch_r == channels_r - 1'b1) &&
          (req_y_r == height_r - 1'b1);
    end

    for (int c = 0; c < NC; c++) begin
      bank_en[c] = request_c && (request_bank_c == BANK_W'(c));
      bank_addr[c] = request_addr_c;
    end
  end

  logic [BANK_W-1:0] rsp_bank_r;
  logic rsp_byte_sel_r;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      width_r <= '0;
      height_r <= '0;
      channels_r <= '0;
      base_word_r <= '0;
      plane_words_r <= '0;
      req_x_r <= '0;
      req_y_r <= '0;
      req_ch_r <= '0;
      req_row_byte_base_r <= '0;
      next_req_valid_r <= 1'b0;
      rsp_bank_r <= '0;
      rsp_byte_sel_r <= 1'b0;
      pix_valid <= 1'b0;
    end else begin
      if (start)
        pix_valid <= 1'b1;
      else if (consume)
        pix_valid <= next_req_valid_r;
      if (request_c) begin
        rsp_bank_r <= request_bank_c;
        rsp_byte_sel_r <= request_byte_sel_c;
      end

      if (start) begin
        width_r <= cfg_width;
        height_r <= cfg_height;
        channels_r <= cfg_channels;
        base_word_r <= cfg_base_word;
        plane_words_r <= cfg_plane_words;
        req_y_r <= '0;
        req_row_byte_base_r <= '0;
        next_req_valid_r <= !request_last_c;
        if (cfg_width > 1) begin
          req_x_r <= DIM_W'(1);
          req_ch_r <= '0;
        end else if (cfg_channels > 1) begin
          req_x_r <= '0;
          req_ch_r <= CHANNEL_W'(1);
        end else begin
          req_x_r <= '0;
          req_ch_r <= '0;
          req_y_r <= DIM_W'(1);
          req_row_byte_base_r <= 16'(cfg_width);
        end
      end else if (consume && next_req_valid_r) begin
        next_req_valid_r <= !request_last_c;
        if (req_x_r == width_r - 1'b1) begin
          req_x_r <= '0;
          if (req_ch_r == channels_r - 1'b1) begin
            req_ch_r <= '0;
            req_y_r <= req_y_r + 1'b1;
            req_row_byte_base_r <=
                req_row_byte_base_r + 16'(width_r);
          end else begin
            req_ch_r <= req_ch_r + 1'b1;
          end
        end else begin
          req_x_r <= req_x_r + 1'b1;
        end
      end
    end
  end

  always_comb begin
    if (!pix_valid)
      pix_data = '0;
    else if (rsp_byte_sel_r)
      pix_data = $signed(bank_rdata[rsp_bank_r][15:8]);
    else
      pix_data = $signed(bank_rdata[rsp_bank_r][7:0]);
  end

`ifdef SIMULATION
  assert property (@(posedge clk) disable iff (!rst_n)
      start |-> ((cfg_width != 0) && (cfg_height != 0) &&
                 (cfg_channels != 0)));
  assert property (@(posedge clk) disable iff (!rst_n)
      consume |-> pix_valid);
  assert property (@(posedge clk) disable iff (!rst_n)
      request_c |-> $onehot(bank_en));
`endif

endmodule
