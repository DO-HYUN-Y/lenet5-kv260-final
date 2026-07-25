`timescale 1ns/1ps
// fc_vector_gen.sv -- one-activation-per-cycle FC source scheduler.

module fc_vector_gen #(
  parameter int ACT_W  = 8,
  parameter int KOUT_W = 9
) (
  input  logic clk,
  input  logic rst_n,
  input  logic en,
  input  logic start,
  input  logic [KOUT_W-1:0] cfg_depth,

  input  logic signed [ACT_W-1:0] pix_in,
  input  logic                    pix_valid,
  output logic                    pix_rd_en,

  output logic signed [ACT_W-1:0] activation,
  output logic                    act_valid,
  output logic                    depth_last,
  output logic [KOUT_W-1:0]       k_out,
  output logic                    source_done
);

  logic active_r;
  logic [KOUT_W-1:0] depth_r;
  logic [KOUT_W-1:0] k_r;

  assign activation = pix_valid ? pix_in : '0;
  assign act_valid = active_r && pix_valid;
  assign depth_last = act_valid && (k_r == depth_r - 1'b1);
  assign k_out = k_r;
  assign pix_rd_en = en && act_valid;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      active_r <= 1'b0;
      depth_r <= '0;
      k_r <= '0;
      source_done <= 1'b0;
    end else begin
      source_done <= 1'b0;
      if (start) begin
        active_r <= 1'b1;
        depth_r <= cfg_depth;
        k_r <= '0;
      end else if (en && act_valid) begin
        if (depth_last) begin
          active_r <= 1'b0;
          source_done <= 1'b1;
        end else begin
          k_r <= k_r + 1'b1;
        end
      end
    end
  end

`ifdef SIMULATION
  assert property (@(posedge clk) disable iff (!rst_n)
      start |-> (cfg_depth != 0));
  assert property (@(posedge clk) disable iff (!rst_n)
      act_valid |-> pix_valid);
  assert property (@(posedge clk) disable iff (!rst_n)
      !en |=> $stable({active_r, k_r}));
`endif

endmodule
