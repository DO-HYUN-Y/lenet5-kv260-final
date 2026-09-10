`timescale 1ns/1ps

module tb_alexnet_n8_rs_m8_feeder;

  tb_alexnet_n8_rs_m4_feeder #(
      .PHYS_ROWS(4),
      .M_GROUP(8)
  ) u_test ();

endmodule
