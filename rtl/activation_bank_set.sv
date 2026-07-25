`timescale 1ns/1ps
// activation_bank_set.sv -- eight independent 16-bit true-dual-port banks.
//
// Port A is read/write with byte enables. Port B is read-only. During conv,
// one ping-pong set uses A for the scalar window read while the other set uses
// A for eight parallel postprocess writes. During pooling, the source set uses
// A+B for top/bottom reads and the destination set uses A for byte writes.

module activation_bank_set #(
  parameter int NC         = 8,
  parameter int ADDR_W     = 9,
  parameter int BANK_DEPTH = 1 << ADDR_W
) (
  input  logic clk,

  input  logic                  a_en [0:NC-1],
  input  logic [1:0]            a_we [0:NC-1],
  input  logic [ADDR_W-1:0]     a_addr [0:NC-1],
  input  logic [15:0]           a_wdata [0:NC-1],
  output logic [15:0]           a_rdata [0:NC-1],

  input  logic                  b_en [0:NC-1],
  input  logic [ADDR_W-1:0]     b_addr [0:NC-1],
  output logic [15:0]           b_rdata [0:NC-1]
);

  generate
    for (genvar c = 0; c < NC; c++) begin : g_bank
      (* ram_style = "block" *)
      logic [15:0] mem [0:BANK_DEPTH-1];

      always_ff @(posedge clk) begin
        if (a_en[c]) begin
          if (a_we[c][0]) mem[a_addr[c]][7:0] <= a_wdata[c][7:0];
          if (a_we[c][1]) mem[a_addr[c]][15:8] <= a_wdata[c][15:8];
          if (!(|a_we[c])) a_rdata[c] <= mem[a_addr[c]];
        end
        if (b_en[c]) b_rdata[c] <= mem[b_addr[c]];
      end
    end
  endgenerate

endmodule
