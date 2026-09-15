`timescale 1ns/1ps

module tb_alexnet_m8n128_compute_island;

  logic clk = 1'b0;
  logic rst = 1'b1;
  logic start_valid = 1'b0;
  logic start_ready;
  logic [31:0] seed = 32'h1357_9bdf;
  logic busy;
  logic done;
  logic fault;
  logic [31:0] result_signature;
  logic [15:0] completed_tiles;
  logic [31:0] active_cycles;
  logic [31:0] issue_cycles;
  logic [31:0] weight_stall_cycles;
  logic [31:0] activation_stall_cycles;
  logic [31:0] result_stall_cycles;
  logic [63:0] useful_mac_count;
  logic [63:0] peak_mac_slot_count;

  always #2.5 clk = ~clk;

  alexnet_m8n128_compute_island dut (.*);

  task automatic run_probe(input logic [31:0] transaction_seed,
                           output logic [31:0] signature);
    int timeout;
    begin
      while (!start_ready)
        @(posedge clk);
      seed <= transaction_seed;
      start_valid <= 1'b1;
      @(posedge clk);
      start_valid <= 1'b0;

      timeout = 0;
      while (!done && timeout < 200000) begin
        @(posedge clk);
        timeout++;
      end
      if (!done) begin
        $display("TIMEOUT state=%0d feeder_state=%0d pixels=%0d weights=%0d ready_sets=%b feeder_valid=%0b feeder_k=%0d weight_valid=%0b weight_k=%0d slices=%0d/%0d tiles=%0d frame_done=%0b",
                 dut.state_q, dut.u_feeder.u_feeder.state_q,
                 dut.pixel_count_q, dut.weight_beat_count_q,
                 dut.weight_ready_set_mask, dut.feeder_m_valid,
                 dut.feeder_k, dut.weight_valid, dut.weight_k,
                 dut.result_slice_issue_q, dut.result_slice_egress_q,
                 completed_tiles, dut.frame_done_seen_q);
        $fatal(1, "M8xN128 compute-island timeout");
      end
      if (fault)
        $fatal(1, "M8xN128 compute-island raised fault");
      if (completed_tiles != 16)
        $fatal(1, "completed tiles %0d, expected 16", completed_tiles);
      if (issue_cycles != 16 * 27)
        $fatal(1, "issue cycles %0d, expected %0d", issue_cycles, 16*27);
      if (useful_mac_count != 64'(16 * 27 * 1008))
        $fatal(1, "useful MAC count %0d, expected %0d",
               useful_mac_count, 16*27*1008);
      if (peak_mac_slot_count != 64'(16 * 27 * 1024))
        $fatal(1, "physical peak slot count %0d, expected %0d",
               peak_mac_slot_count, 16*27*1024);
      if (active_cycles <= issue_cycles)
        $fatal(1, "active-cycle counter omitted non-issue work");
      if (result_stall_cycles == 0)
        $fatal(1, "result drain did not expose its expected pipeline wait");
      if (result_signature == 0)
        $fatal(1, "result signature unexpectedly zero");
      signature = result_signature;
      @(posedge clk);
    end
  endtask

  initial begin
    logic [31:0] signature_a;
    logic [31:0] signature_b;

    repeat (8) @(posedge clk);
    rst <= 1'b0;
    repeat (3) @(posedge clk);

    run_probe(32'h1357_9bdf, signature_a);
    run_probe(32'h2468_ace1, signature_b);
    if (signature_a == signature_b)
      $fatal(1, "different seeds produced the same result signature");

    $display("ALEXNET_M8N128_COMPUTE_ISLAND_TEST_PASSED tiles=%0d issues=%0d active=%0d weight_stall=%0d activation_stall=%0d result_stall=%0d useful_macs=%0d signature=%08x",
             completed_tiles, issue_cycles, active_cycles,
             weight_stall_cycles, activation_stall_cycles,
             result_stall_cycles, useful_mac_count, result_signature);
    $finish;
  end

endmodule
