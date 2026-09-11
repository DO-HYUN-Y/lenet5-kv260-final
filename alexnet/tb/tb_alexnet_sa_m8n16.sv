`timescale 1ns/1ps

module tb_alexnet_sa_m8n16;

  tb_alexnet_sa_m4n8 #(
      .PHYS_ROWS(4),
      .COLS(16)
  ) u_test ();

endmodule
