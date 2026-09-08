`timescale 1ns/1ps

// Reuse the full dense/DPI/error regression with runtime output placement.
module tb_alexnet_m4n8_fc_dma_runtime_placement;
  tb_alexnet_m4n8_fc_dma_io_datapath #(.RUNTIME_SLICE_INDEX(1'b1)) test_case ();
endmodule
