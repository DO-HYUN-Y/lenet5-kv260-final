`timescale 1ns/1ps
// banked_activation_writer.sv -- final INT8-pair writeback adapter.
//
// Each physical systolic column owns one independent activation-bank write
// port. The two postprocessed INT8 lanes form one aligned 16-bit word; the
// lane mask becomes the byte-write strobe. Addresses are sequential and
// bank-local, so channel planes do not create sparse holes in each bank.
// The layer controller supplies cfg_bank_base_word for each output pass.

module banked_activation_writer #(
  parameter int NC            = 8,
  parameter int BYTE_ADDR_W   = 16,
  parameter int WORD_ADDR_W   = BYTE_ADDR_W - 1
) (
  input  logic                   clk,
  input  logic                   rst_n,
  input  logic                   start,
  input  logic [WORD_ADDR_W-1:0] cfg_bank_base_word,

  input  logic                   in_valid [0:NC-1],
  output logic                   in_ready [0:NC-1],
  input  logic [15:0]            in_data [0:NC-1],
  input  logic [1:0]             in_lane_mask [0:NC-1],
  input  logic [BYTE_ADDR_W-1:0] in_addr_lo [0:NC-1],
  input  logic [BYTE_ADDR_W-1:0] in_addr_hi [0:NC-1],

  output logic                   bank_we [0:NC-1],
  input  logic                   bank_ready [0:NC-1],
  output logic [WORD_ADDR_W-1:0] bank_word_addr [0:NC-1],
  output logic [15:0]            bank_wdata [0:NC-1],
  output logic [1:0]             bank_wstrb [0:NC-1]
);

  logic [WORD_ADDR_W-1:0] write_addr_r [0:NC-1];

  always_ff @(posedge clk) begin
    if (!rst_n || start) begin
      for (int c = 0; c < NC; c++)
        write_addr_r[c] <= cfg_bank_base_word;
    end else begin
      for (int c = 0; c < NC; c++) begin
        if (in_valid[c] && bank_ready[c])
          write_addr_r[c] <= write_addr_r[c] + 1'b1;
      end
    end
  end

  always_comb begin
    for (int c = 0; c < NC; c++) begin
      in_ready[c] = bank_ready[c];
      bank_we[c] = in_valid[c] && bank_ready[c];
      bank_word_addr[c] = write_addr_r[c];
      bank_wdata[c] = in_data[c];
      bank_wstrb[c] = in_lane_mask[c];
    end
  end

`ifdef SIMULATION
  for (genvar c = 0; c < NC; c++) begin : g_assert_bank
    assert property (@(posedge clk) disable iff (!rst_n)
        (in_valid[c] && in_ready[c]) |->
          ((in_lane_mask[c] != 2'b00) &&
           (!in_lane_mask[c][1] || in_lane_mask[c][0]) &&
           (!in_lane_mask[c][1] ||
             (in_addr_hi[c] == in_addr_lo[c] + 1'b1))));
  end
`endif

endmodule
