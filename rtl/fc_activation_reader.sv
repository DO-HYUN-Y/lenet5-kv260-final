`timescale 1ns/1ps
// fc_activation_reader.sv -- registered bank reader for FC input vectors.
//
// packed_layout=0: channel-major plane layout used by S4 (C5 input).
// packed_layout=1: physical FC-result layout written by column c/group g.

module fc_activation_reader #(
  parameter int ACT_W       = 8,
  parameter int NG          = 4,
  parameter int NC          = 8,
  parameter int ADDR_W      = 9,
  parameter int KOUT_W      = 9,
  parameter int CHANNEL_W   = 8,
  parameter int BANK_W      = (NC < 2) ? 1 : $clog2(NC)
) (
  input  logic clk,
  input  logic rst_n,
  input  logic start,
  input  logic consume,
  input  logic packed_layout,

  input  logic [KOUT_W-1:0]    cfg_length,
  input  logic [CHANNEL_W-1:0] cfg_channels,
  input  logic [KOUT_W-1:0]    cfg_plane_bytes,
  input  logic [ADDR_W-1:0]    cfg_plane_words,
  input  logic [ADDR_W-1:0]    cfg_base_word,

  output logic                 bank_en [0:NC-1],
  output logic [ADDR_W-1:0]    bank_addr [0:NC-1],
  input  logic [15:0]          bank_rdata [0:NC-1],

  output logic signed [ACT_W-1:0] pix_data,
  output logic                    pix_valid
);

  logic packed_r;
  logic [KOUT_W-1:0] length_r;
  logic [CHANNEL_W-1:0] channels_r;
  logic [KOUT_W-1:0] plane_bytes_r;
  logic [ADDR_W-1:0] plane_words_r;
  logic [ADDR_W-1:0] base_word_r;

  // Next request after the pre-issued logical element zero.
  logic [KOUT_W-1:0] req_index_r;
  logic [CHANNEL_W-1:0] req_channel_r;
  logic [KOUT_W-1:0] req_position_r;
  logic next_req_valid_r;

  logic request_c;
  logic [BANK_W-1:0] request_bank_c;
  logic [ADDR_W-1:0] request_addr_c;
  logic request_byte_sel_c;
  logic request_last_c;

  always_comb begin
    request_c = start || (consume && next_req_valid_r);
    request_bank_c = '0;
    request_addr_c = cfg_base_word;
    request_byte_sel_c = 1'b0;
    request_last_c = (cfg_length == 1);

    if (!start) begin
      request_last_c = (req_index_r == length_r - 1'b1);
      if (packed_r) begin
        request_bank_c =
            BANK_W'((req_index_r % (2 * NC)) >> 1);
        request_addr_c =
            base_word_r + ADDR_W'(req_index_r / (2 * NC));
        request_byte_sel_c = req_index_r[0];
      end else begin
        request_bank_c = BANK_W'(req_channel_r % NC);
        request_addr_c =
            base_word_r +
            ADDR_W'(req_channel_r / NC) * plane_words_r +
            ADDR_W'(req_position_r >> 1);
        request_byte_sel_c = req_position_r[0];
      end
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
      packed_r <= 1'b0;
      length_r <= '0;
      channels_r <= '0;
      plane_bytes_r <= '0;
      plane_words_r <= '0;
      base_word_r <= '0;
      req_index_r <= '0;
      req_channel_r <= '0;
      req_position_r <= '0;
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
        packed_r <= packed_layout;
        length_r <= cfg_length;
        channels_r <= cfg_channels;
        plane_bytes_r <= cfg_plane_bytes;
        plane_words_r <= cfg_plane_words;
        base_word_r <= cfg_base_word;
        req_index_r <= KOUT_W'(1);
        req_channel_r <= '0;
        req_position_r <= KOUT_W'(1);
        next_req_valid_r <= !request_last_c;
        if (!packed_layout && (cfg_plane_bytes == 1)) begin
          req_position_r <= '0;
          req_channel_r <= CHANNEL_W'(1);
        end
      end else if (consume && next_req_valid_r) begin
        next_req_valid_r <= !request_last_c;
        req_index_r <= req_index_r + 1'b1;
        if (!packed_r) begin
          if (req_position_r == plane_bytes_r - 1'b1) begin
            req_position_r <= '0;
            req_channel_r <= req_channel_r + 1'b1;
          end else begin
            req_position_r <= req_position_r + 1'b1;
          end
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
      start |-> ((cfg_length != 0) &&
                 (packed_layout || ((cfg_channels != 0) &&
                                    (cfg_plane_bytes != 0)))));
  assert property (@(posedge clk) disable iff (!rst_n)
      consume |-> pix_valid);
  assert property (@(posedge clk) disable iff (!rst_n)
      request_c |-> $onehot(bank_en));
`endif

endmodule
