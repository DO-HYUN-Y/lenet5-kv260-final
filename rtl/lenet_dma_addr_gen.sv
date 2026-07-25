`timescale 1ns/1ps
// lenet_dma_addr_gen.sv -- sequential DMA-unit to on-chip address mapping.
//
// Unit definitions:
//   WEIGHT: one 512-bit row across eight 64-bit weight banks.
//   PARAM:  one 64-bit {reserved, scale, bias} record.
//   INPUT:  one 16-bit activation word in one activation bank.
//   RESULT: one 16-bit result word striped across activation banks.
//
// The downstream adapter owns advance. While advance is low, every visible
// address and the last tag remain stable.

module lenet_dma_addr_gen #(
  parameter int NC           = 8,
  parameter int COUNT_W      = 16,
  parameter int BASE_W       = 16,
  parameter int WGT_ADDR_W   = 11,
  parameter int PARAM_ADDR_W = 8,
  parameter int BANK_ADDR_W  = 9,
  parameter int BANK_W       = (NC < 2) ? 1 : $clog2(NC)
) (
  input  logic clk,
  input  logic rst_n,
  input  logic start,
  input  logic clear_error,
  input  logic advance,

  input  logic [1:0]             cfg_mode,
  input  logic [COUNT_W-1:0]     cfg_count,
  input  logic [BASE_W-1:0]      cfg_base,
  input  logic [BANK_W-1:0]      cfg_bank_base,

  output logic                   busy,
  output logic                   valid,
  output logic                   last,
  output logic                   done,
  output logic                   error,
  output logic [1:0]             mode,
  output logic [COUNT_W-1:0]     unit_index,
  output logic [WGT_ADDR_W-1:0]  weight_addr,
  output logic [PARAM_ADDR_W-1:0] param_addr,
  output logic [BANK_W-1:0]      bank_index,
  output logic [BANK_ADDR_W-1:0] bank_word_addr
);

  localparam logic [1:0] MODE_WEIGHT = 2'd0;
  localparam logic [1:0] MODE_PARAM  = 2'd1;
  localparam logic [1:0] MODE_INPUT  = 2'd2;
  localparam logic [1:0] MODE_RESULT = 2'd3;

  logic [1:0] mode_r;
  logic [COUNT_W-1:0] count_r;
  logic [COUNT_W-1:0] unit_index_r;
  logic [BASE_W-1:0] base_r;
  logic [BANK_W-1:0] bank_base_r;
  logic [COUNT_W-1:0] result_linear_c;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      busy <= 1'b0;
      done <= 1'b0;
      error <= 1'b0;
      mode_r <= MODE_WEIGHT;
      count_r <= COUNT_W'(1);
      unit_index_r <= '0;
      base_r <= '0;
      bank_base_r <= '0;
    end else begin
      done <= 1'b0;
      if (clear_error)
        error <= 1'b0;

      if (start) begin
        if (busy) begin
          error <= 1'b1;
        end else begin
          mode_r <= cfg_mode;
          count_r <= (cfg_count == '0) ? COUNT_W'(1) : cfg_count;
          unit_index_r <= '0;
          base_r <= cfg_base;
          bank_base_r <= cfg_bank_base;
          busy <= 1'b1;
          if (cfg_count == '0)
            error <= 1'b1;
        end
      end else if (busy && advance) begin
        if (unit_index_r == count_r - 1'b1) begin
          busy <= 1'b0;
          done <= 1'b1;
        end else begin
          unit_index_r <= unit_index_r + 1'b1;
        end
      end
    end
  end

  always_comb begin
    valid = busy;
    last = busy && (unit_index_r == count_r - 1'b1);
    mode = mode_r;
    unit_index = unit_index_r;
    weight_addr = '0;
    param_addr = '0;
    bank_index = '0;
    bank_word_addr = '0;
    result_linear_c = COUNT_W'(bank_base_r) + unit_index_r;

    case (mode_r)
      MODE_WEIGHT: begin
        weight_addr =
            WGT_ADDR_W'(base_r) + WGT_ADDR_W'(unit_index_r);
      end
      MODE_PARAM: begin
        param_addr =
            PARAM_ADDR_W'(base_r) + PARAM_ADDR_W'(unit_index_r);
      end
      MODE_INPUT: begin
        bank_index = bank_base_r;
        bank_word_addr =
            BANK_ADDR_W'(base_r) + BANK_ADDR_W'(unit_index_r);
      end
      MODE_RESULT: begin
        bank_index = BANK_W'(result_linear_c % NC);
        bank_word_addr =
            BANK_ADDR_W'(base_r) +
            BANK_ADDR_W'(result_linear_c / NC);
      end
      default: begin
        weight_addr = '0;
        param_addr = '0;
        bank_index = '0;
        bank_word_addr = '0;
      end
    endcase
  end

`ifdef SIMULATION
  assert property (@(posedge clk) disable iff (!rst_n)
      valid == busy);
  assert property (@(posedge clk) disable iff (!rst_n)
      (valid && !advance && !start) |=> $stable({
        mode, unit_index, last, weight_addr, param_addr,
        bank_index, bank_word_addr
      }));
  assert property (@(posedge clk) disable iff (!rst_n)
      (valid && advance && last) |=> (done && !busy));
  assert property (@(posedge clk) disable iff (!rst_n)
      busy |-> (count_r != '0));
`endif

endmodule
