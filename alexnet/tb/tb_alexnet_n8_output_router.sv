`timescale 1ns/1ps

module tb_alexnet_n8_output_router #(
    parameter bit RUNTIME_SLICE_INDEX = 1'b0
);

  localparam int SLICE_INDEX = 3;
  localparam int FIFO_DEPTH = 64;

  import "DPI-C" function int alexnet_golden_router_reset(
      input int slice, input int fifo_depth);
  import "DPI-C" function int alexnet_golden_router_configure(
      input byte destination, input int n64_tile_base);
  import "DPI-C" function int alexnet_golden_router_tick(
      input byte ingress_valid, input int ingress_m,
      input int ingress_tile_tag, input byte ingress_lane_mask,
      input longint unsigned ingress_values, input byte egress_ready,
      output byte ingress_ready, output byte egress_valid,
      output byte egress_destination, output int egress_slice,
      output int egress_m, output int egress_n_base,
      output int egress_tile_tag, output byte egress_lane_mask,
      output longint unsigned egress_values);
  import "DPI-C" function int alexnet_golden_router_queued(
      output int queued_packets);

  logic clk = 1'b0;
  logic rst;
  logic cfg_valid;
  logic cfg_ready;
  logic [1:0] cfg_destination;
  logic [15:0] cfg_n64_tile_base;
  logic [2:0] cfg_slice_index = 3;
  logic [7:0] cfg_lane_mask;
  logic ingress_valid;
  logic ingress_ready;
  logic [63:0] ingress_values;
  logic [7:0] ingress_lane_mask;
  logic [4:0] ingress_m;
  logic [15:0] ingress_tile_tag;
  logic egress_valid;
  logic egress_ready;
  logic [63:0] egress_values;
  logic [7:0] egress_lane_mask;
  logic [1:0] egress_destination;
  logic [2:0] egress_slice;
  logic [4:0] egress_m;
  logic [15:0] egress_n_base;
  logic [15:0] egress_tile_tag;
  logic idle;
  logic [$clog2(FIFO_DEPTH+1)-1:0] queued_count;

  alexnet_n8_output_router #(
      .SLICE_INDEX(SLICE_INDEX),
      .RUNTIME_SLICE_INDEX(RUNTIME_SLICE_INDEX),
      .FIFO_DEPTH(FIFO_DEPTH)
  ) dut (.*);

  always #2.5 clk = ~clk;

  int checked_cycles;
  int checked_packets;
  int blocked_configs = 0;
  logic [7:0] positions_seen = 0;

  initial begin
    #100000;
    $fatal(1, "router watchdog");
  end

  function automatic logic [63:0] make_values(
      input int packet_index, input logic [7:0] mask);
    logic [63:0] values;
    begin
      values = '0;
      for (int lane = 0; lane < 8; lane++)
        if (mask[lane])
          values[lane*8 +: 8] = (packet_index * 11 + lane * 17) & 8'hff;
      make_values = values;
    end
  endfunction

  task automatic step_cycle(
      input logic drive_cfg_valid,
      input logic [1:0] drive_destination,
      input int drive_n64_base,
      input logic [7:0] drive_cfg_mask,
      input logic drive_ingress_valid,
      input int drive_m,
      input int drive_tile_tag,
      input logic [7:0] drive_mask,
      input logic [63:0] drive_values,
      input logic drive_egress_ready);
    byte golden_ingress_ready;
    byte golden_egress_valid;
    byte golden_destination;
    byte golden_mask;
    longint unsigned golden_values;
    int golden_slice;
    int golden_m;
    int golden_n_base;
    int golden_tile_tag;
    int golden_queued;
    int status;
    begin
      cfg_valid = drive_cfg_valid;
      cfg_destination = drive_destination;
      cfg_n64_tile_base = drive_n64_base;
      cfg_lane_mask = drive_cfg_mask;
      ingress_valid = drive_ingress_valid;
      ingress_m = drive_m;
      ingress_tile_tag = drive_tile_tag;
      ingress_lane_mask = drive_mask;
      ingress_values = drive_values;
      egress_ready = drive_egress_ready;
      #1;

      status = alexnet_golden_router_queued(golden_queued);
      if (status != 0 || queued_count != golden_queued)
        $fatal(1, "router occupancy mismatch rtl=%0d golden=%0d status=%0d",
               queued_count, golden_queued, status);
      if (cfg_ready !== (golden_queued == 0))
        $fatal(1, "router configuration readiness mismatch");
      if (drive_cfg_valid && !cfg_ready) blocked_configs++;

      status = alexnet_golden_router_tick(
          drive_cfg_valid ? 0 : drive_ingress_valid,
          ingress_m, drive_tile_tag, drive_mask, drive_values,
          drive_egress_ready, golden_ingress_ready, golden_egress_valid,
          golden_destination, golden_slice, golden_m, golden_n_base,
          golden_tile_tag, golden_mask, golden_values);
      if (status != 0)
        $fatal(1, "C++ router tick failed status=%0d", status);

      if (ingress_ready !== (drive_cfg_valid ? 1'b0 : golden_ingress_ready[0]))
        $fatal(1, "router ingress_ready mismatch rtl=%0b golden=%0b",
               ingress_ready, golden_ingress_ready[0]);
      if (egress_valid !== golden_egress_valid[0])
        $fatal(1, "router egress_valid mismatch rtl=%0b golden=%0b",
               egress_valid, golden_egress_valid[0]);
      if (egress_valid) begin
        if (egress_destination != golden_destination[1:0] ||
            egress_slice != golden_slice || egress_m != golden_m ||
            egress_n_base != golden_n_base ||
            egress_tile_tag != golden_tile_tag ||
            egress_lane_mask != golden_mask || egress_values != golden_values)
          $fatal(1,
                 "router packet mismatch m=%0d/%0d n=%0d/%0d tag=%0d/%0d mask=%02x/%02x values=%016x/%016x",
                 egress_m, golden_m, egress_n_base, golden_n_base,
                 egress_tile_tag, golden_tile_tag, egress_lane_mask,
                 golden_mask, egress_values, golden_values);
        if (drive_egress_ready)
          checked_packets = checked_packets + 1;
      end

      if (drive_cfg_valid && cfg_ready) begin
        // A new fixed-slice C++ oracle at an empty boundary models runtime
        // descriptor selection without borrowing the RTL address expression.
        if (RUNTIME_SLICE_INDEX) begin
          status = alexnet_golden_router_reset(cfg_slice_index, FIFO_DEPTH);
          if (status != 0) $fatal(1, "runtime C++ router reset failed");
          positions_seen[cfg_slice_index] = 1;
        end
        status = alexnet_golden_router_configure(
            drive_destination, drive_n64_base);
        if (status != 0)
          $fatal(1, "C++ router configure failed status=%0d", status);
      end

      checked_cycles = checked_cycles + 1;
      @(negedge clk);
    end
  endtask

  initial begin
    int status;
    int held_index;

    rst = 1'b1;
    cfg_valid = 1'b0;
    cfg_destination = '0;
    cfg_n64_tile_base = '0;
    cfg_lane_mask = 8'hff;
    ingress_valid = 1'b0;
    ingress_values = '0;
    ingress_lane_mask = 8'hff;
    ingress_m = '0;
    ingress_tile_tag = '0;
    egress_ready = 1'b0;
    checked_cycles = 0;
    checked_packets = 0;

    status = alexnet_golden_router_reset(SLICE_INDEX, FIFO_DEPTH);
    if (status != 0)
      $fatal(1, "C++ router reset failed status=%0d", status);

    repeat (5) @(negedge clk);
    rst = 1'b0;
    @(negedge clk);

    // Unconfigured ingress is rejected.
    step_cycle(1'b0, 0, 0, 8'hff, 1'b1, 0, 1, 8'hff,
               make_values(0, 8'hff), 1'b0);

    // Configure slice 3 at FC8's final N64 tile base.
    step_cycle(1'b1, 2, 960, 8'hff, 1'b0, 0, 0, 8'hff, '0, 1'b0);

    // Fill all 64 entries while output is blocked.
    for (int packet = 0; packet < FIFO_DEPTH; packet++)
      step_cycle(1'b0, 0, 0, 8'hff, 1'b1, packet, 23, 8'hff,
                 make_values(packet, 8'hff), 1'b0);

    // Hold the 65th input stable while full.
    held_index = FIFO_DEPTH;
    repeat (3)
      step_cycle(1'b0, 0, 0, 8'hff, 1'b1, held_index, 23, 8'hff,
                 make_values(held_index, 8'hff), 1'b0);

    // A blocked configuration cannot mutate a full FIFO's descriptor.
    cfg_slice_index = 7;
    step_cycle(1'b1, 1, 65472, 8'h01, 1'b1, held_index, 23, 8'hff,
               make_values(held_index, 8'hff), 1'b0);
    cfg_slice_index = 3'bxxx;

    // Full-FIFO pop/push turnover must accept that held input.
    step_cycle(1'b0, 0, 0, 8'hff, 1'b1, held_index, 23, 8'hff,
               make_values(held_index, 8'hff), 1'b1);

    // Drain with random backpressure.
    while (!idle)
      step_cycle(1'b0, 0, 0, 8'hff, 1'b0, 0, 0, 8'hff, '0,
                 $urandom_range(0, 3) != 0);

    // Descriptor change is legal only at an empty boundary; exercise N tail.
    cfg_slice_index = 3;
    step_cycle(1'b1, 0, 0, 8'h0f, 1'b0, 0, 0, 8'hff, '0, 1'b0);
    step_cycle(1'b0, 0, 0, 8'h0f, 1'b1, 31, 99, 8'h0f,
               make_values(91, 8'h0f), 1'b0);
    step_cycle(1'b0, 0, 0, 8'h0f, 1'b0, 0, 0, 8'hff, '0, 1'b1);
    step_cycle(1'b0, 0, 0, 8'h0f, 1'b0, 0, 0, 8'hff, '0, 1'b0);

    if (!idle || queued_count != 0)
      $fatal(1, "router did not drain");

    // All eight placements in FC8's last N64 block and the highest N64
    // block representable by the 16-bit ABI. The static run deliberately
    // drives the same changing pins, but must always remain slice 3.
    for (int group_index = 0; group_index < 2; group_index++) begin
      for (int position = 0; position < 8; position++) begin
        cfg_slice_index = position;
        // Simultaneous input must lose to an accepted configuration.
        step_cycle(1, position%3, group_index ? 65472 : 960, (1<<(position+1))-1,
                   1, 0, 500+position, 8'hff, make_values(0, 8'hff), 0);
        cfg_slice_index = 3'bxxx;
        for (int packet_index = 0; packet_index < 4; packet_index++)
          step_cycle(0, 0, 0, 8'hff, 1, packet_index, 500+position,
                     (1<<(position+1))-1, make_values(packet_index, (1<<(position+1))-1), 0);
        // Hold a different descriptor through a blocked output and its last
        // drain edge. No new configuration is accepted on the final pop.
        cfg_slice_index = (position+1)%8;
        repeat (3)
          step_cycle(1, 2, 0, 8'hff, 1, 0, 0, 8'hff, '0, 0);
        while (!idle)
          step_cycle(1, 2, 0, 8'hff, 1, 0, 0, 8'hff, '0, 1);
      end
    end
    cfg_valid = 0;
    ingress_valid = 0;
    if (blocked_configs != 113 || (RUNTIME_SLICE_INDEX && positions_seen != 255))
      $fatal(1, "router placement coverage mismatch");
    if (RUNTIME_SLICE_INDEX)
      $display("ALEXNET_N8_ROUTER_RUNTIME_PLACEMENT_TEST_PASSED positions=%02x blocked_configs=%0d",
               positions_seen, blocked_configs);

    $display("ALEXNET_N8_ROUTER_TEST_PASSED cycles=%0d packets=%0d",
             checked_cycles, checked_packets);
    $finish;
  end

endmodule

module tb_alexnet_n8_output_router_runtime;
  tb_alexnet_n8_output_router #(.RUNTIME_SLICE_INDEX(1'b1)) test_case ();
endmodule
