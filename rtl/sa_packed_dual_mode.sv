`timescale 1ns/1ps
// sa_packed_dual_mode.sv -- one 4x8 DSP array shared by Conv and FC.
//
// Conv: packed operand = two spatial activations, common operand = col weight.
// FC:   packed operand = two local filter weights, common operand = activation.

module sa_packed_dual_mode #(
  parameter int DATA_W = 8,
  parameter int ACC_W  = 32,
  parameter int NG     = 4,
  parameter int NC     = 8
) (
  input  logic clk,
  input  logic rst_n,
  input  logic en,
  input  logic fc_mode,

  input  logic signed [DATA_W-1:0] conv_act_lo [0:NG-1],
  input  logic signed [DATA_W-1:0] conv_act_hi [0:NG-1],
  input  logic                    conv_valid [0:NG-1],
  input  logic [1:0]              conv_mask [0:NG-1],
  input  logic                    conv_last [0:NG-1],
  input  logic signed [DATA_W-1:0] conv_weight [0:NC-1],

  input  logic signed [DATA_W-1:0] fc_activation [0:NG-1],
  input  logic signed [DATA_W-1:0] fc_weight_lo [0:NG-1][0:NC-1],
  input  logic signed [DATA_W-1:0] fc_weight_hi [0:NG-1][0:NC-1],
  input  logic                    fc_valid [0:NG-1],
  input  logic [1:0]              fc_mask [0:NG-1][0:NC-1],
  input  logic                    fc_last [0:NG-1],

  output logic signed [ACC_W-1:0] acc_lo_out [0:NG-1][0:NC-1],
  output logic signed [ACC_W-1:0] acc_hi_out [0:NG-1][0:NC-1],
  output logic [1:0]              acc_valid [0:NG-1][0:NC-1]
);

  logic signed [DATA_W-1:0] hop_packed_lo [0:NG-1][0:NC-1];
  logic signed [DATA_W-1:0] hop_packed_hi [0:NG-1][0:NC-1];
  logic signed [DATA_W-1:0] hop_common [0:NG-1][0:NC-1];
  logic conv_ctrl_valid [0:NG-1][0:NC-1];
  logic [1:0] conv_ctrl_mask [0:NG-1][0:NC-1];
  logic conv_ctrl_last [0:NG-1][0:NC-1];

  generate
    for (genvar g = 0; g < NG; g++) begin : g_conv_ctrl
      assign conv_ctrl_valid[g][0] = conv_valid[g];
      assign conv_ctrl_mask[g][0] = conv_mask[g];
      assign conv_ctrl_last[g][0] = conv_last[g];
      for (genvar c = 1; c < NC; c++) begin : g_ctrl_hop
        always_ff @(posedge clk) begin
          if (!rst_n) begin
            conv_ctrl_valid[g][c] <= 1'b0;
            conv_ctrl_mask[g][c] <= 2'b00;
            conv_ctrl_last[g][c] <= 1'b0;
          end else if (en) begin
            conv_ctrl_valid[g][c] <= conv_ctrl_valid[g][c-1];
            conv_ctrl_mask[g][c] <= conv_ctrl_mask[g][c-1];
            conv_ctrl_last[g][c] <= conv_ctrl_last[g][c-1];
          end
        end
      end
    end
  endgenerate

  generate
    for (genvar g = 0; g < NG; g++) begin : g_row
      for (genvar c = 0; c < NC; c++) begin : g_col
        logic signed [DATA_W-1:0] packed_lo_pe;
        logic signed [DATA_W-1:0] packed_hi_pe;
        logic signed [DATA_W-1:0] common_pe;
        logic valid_pe;
        logic [1:0] mask_pe;
        logic last_pe;

        always_comb begin
          if (fc_mode) begin
            packed_lo_pe = fc_weight_lo[g][c];
            packed_hi_pe = fc_weight_hi[g][c];
            common_pe = fc_activation[g];
            valid_pe = fc_valid[g];
            mask_pe = fc_mask[g][c];
            last_pe = fc_last[g];
          end else begin
            packed_lo_pe =
                (c == 0) ? conv_act_lo[g] : hop_packed_lo[g][c-1];
            packed_hi_pe =
                (c == 0) ? conv_act_hi[g] : hop_packed_hi[g][c-1];
            common_pe =
                (g == 0) ? conv_weight[c] : hop_common[g-1][c];
            valid_pe = conv_ctrl_valid[g][c];
            mask_pe = conv_ctrl_mask[g][c];
            last_pe = conv_ctrl_last[g][c];
          end
        end

        packed_pe #(
          .ACT_W(DATA_W), .WGT_W(DATA_W), .ACC_W(ACC_W)
        ) u_ppe (
          .clk(clk), .rst_n(rst_n), .en(en),
          .act_lo_in(packed_lo_pe), .act_hi_in(packed_hi_pe),
          .weight_in(common_pe), .pair_valid(valid_pe),
          .lane_mask(mask_pe), .depth_last(last_pe),
          .act_lo_out(hop_packed_lo[g][c]),
          .act_hi_out(hop_packed_hi[g][c]),
          .weight_out(hop_common[g][c]),
          .acc_lo_out(acc_lo_out[g][c]),
          .acc_hi_out(acc_hi_out[g][c]), .acc_valid(acc_valid[g][c])
        );
      end
    end
  endgenerate

`ifdef SIMULATION
  assert property (@(posedge clk) disable iff (!rst_n)
      ((|acc_valid[0][0]) || conv_valid[0] || fc_valid[0]) |=>
        $stable(fc_mode));
`endif

endmodule
