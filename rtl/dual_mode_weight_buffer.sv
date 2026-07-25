`timescale 1ns/1ps
// dual_mode_weight_buffer.sv -- eight 64-bit SDP weight banks.
//
// Conv mode consumes byte 0 from each bank: eight common column weights.
// FC mode consumes all eight bytes from each bank:
//   byte 2*g+lane -> PPE[g][bank].packed_weight[lane].
// read_base_addr is the already-resolved layer/pass base, so no per-cycle
// variable multiply sits on the BRAM address path.

module dual_mode_weight_buffer #(
  parameter int WGT_W       = 8,
  parameter int NG          = 4,
  parameter int NC          = 8,
  parameter int WORD_W      = 2 * NG * WGT_W,
  parameter int MEM_DEPTH   = 2048,
  parameter int ADDR_W      = $clog2(MEM_DEPTH),
  parameter int KOUT_W      = 9
) (
  input  logic clk,
  input  logic rst_n,
  input  logic en,

  input  logic                    wr_en [0:NC-1],
  input  logic [ADDR_W-1:0]       wr_addr,
  input  logic [WORD_W-1:0]       wr_data [0:NC-1],

  input  logic                    k_valid,
  input  logic [KOUT_W-1:0]       k_out,
  input  logic                    depth_last_in,
  input  logic [ADDR_W-1:0]       read_base_addr,

  output logic signed [WGT_W-1:0] conv_weight [0:NC-1],
  output logic signed [WGT_W-1:0] fc_weight_lo [0:NG-1][0:NC-1],
  output logic signed [WGT_W-1:0] fc_weight_hi [0:NG-1][0:NC-1],
  output logic                    weight_valid,
  output logic                    weight_depth_last,
  output logic [KOUT_W-1:0]       weight_k_out
);

  logic wr_en_q [0:NC-1];
  logic [ADDR_W-1:0] wr_addr_q;
  logic [WORD_W-1:0] wr_data_q [0:NC-1];
  logic [ADDR_W-1:0] read_base_q;
  logic [ADDR_W-1:0] read_addr_c;
  logic [WORD_W-1:0] read_word_q [0:NC-1];

  always_comb begin
    read_addr_c = read_base_q + ADDR_W'(k_out);
    for (int c = 0; c < NC; c++) begin
      conv_weight[c] = $signed(read_word_q[c][WGT_W-1:0]);
      for (int g = 0; g < NG; g++) begin
        fc_weight_lo[g][c] =
            $signed(read_word_q[c][(2*g)*WGT_W +: WGT_W]);
        fc_weight_hi[g][c] =
            $signed(read_word_q[c][(2*g+1)*WGT_W +: WGT_W]);
      end
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      wr_addr_q <= '0;
      read_base_q <= '0;
      for (int c = 0; c < NC; c++) begin
        wr_en_q[c] <= 1'b0;
        wr_data_q[c] <= '0;
      end
    end else begin
      wr_addr_q <= wr_addr;
      for (int c = 0; c < NC; c++) begin
        wr_en_q[c] <= wr_en[c];
        if (wr_en[c]) wr_data_q[c] <= wr_data[c];
      end
      if (!k_valid) read_base_q <= read_base_addr;
    end
  end

  generate
    for (genvar c = 0; c < NC; c++) begin : g_weight_bank
      (* ram_style = "block" *)
      logic [WORD_W-1:0] mem [0:MEM_DEPTH-1];

      always_ff @(posedge clk) begin
        if (wr_en_q[c]) mem[wr_addr_q] <= wr_data_q[c];
        if (!rst_n) begin
          read_word_q[c] <= '0;
        end else if (en) begin
          if (k_valid)
            read_word_q[c] <= mem[read_addr_c];
          else
            read_word_q[c] <= '0;
        end
      end
    end
  endgenerate

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      weight_valid <= 1'b0;
      weight_depth_last <= 1'b0;
      weight_k_out <= '0;
    end else if (en) begin
      weight_valid <= k_valid;
      weight_depth_last <= k_valid && depth_last_in;
      weight_k_out <= k_valid ? k_out : '0;
    end
  end

`ifdef SIMULATION
  assert property (@(posedge clk) disable iff (!rst_n)
      !en |=> $stable({weight_valid, weight_depth_last, weight_k_out}));
  assert property (@(posedge clk) disable iff (!rst_n)
      (en && k_valid) |-> (read_addr_c < MEM_DEPTH));
`endif

endmodule
