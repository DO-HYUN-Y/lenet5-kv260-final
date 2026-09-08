`timescale 1ns/1ps

// One independent N8 output-router slice. The 64-entry registered FIFO stores
// one 8-byte INT8 payload and its destination/coordinate tags per M position.
module alexnet_n8_output_router #(
    parameter int SLICE_INDEX = 0,
    parameter int FIFO_DEPTH = 64,
    parameter int M_W = 5,
    parameter int N_BASE_W = 16,
    parameter int TILE_TAG_W = 16,
    parameter bit RUNTIME_SLICE_INDEX = 1'b0
) (
    input logic clk,
    input logic rst,

    input  logic cfg_valid,
    output logic cfg_ready,
    input  logic [1:0] cfg_destination,
    input  logic [N_BASE_W-1:0] cfg_n64_tile_base,
    input  logic [2:0] cfg_slice_index,
    input  logic [7:0] cfg_lane_mask,

    input  logic ingress_valid,
    output logic ingress_ready,
    input  logic [63:0] ingress_values,
    input  logic [7:0] ingress_lane_mask,
    input  logic [M_W-1:0] ingress_m,
    input  logic [TILE_TAG_W-1:0] ingress_tile_tag,

    output logic egress_valid,
    input  logic egress_ready,
    output logic [63:0] egress_values,
    output logic [7:0] egress_lane_mask,
    output logic [1:0] egress_destination,
    output logic [2:0] egress_slice,
    output logic [M_W-1:0] egress_m,
    output logic [N_BASE_W-1:0] egress_n_base,
    output logic [TILE_TAG_W-1:0] egress_tile_tag,

    output logic idle,
    output logic [$clog2(FIFO_DEPTH+1)-1:0] queued_count
);

  localparam int PTR_W = $clog2(FIFO_DEPTH);
  localparam int COUNT_W = $clog2(FIFO_DEPTH + 1);

  typedef struct packed {
    logic [M_W-1:0] m;
    logic [TILE_TAG_W-1:0] tile_tag;
    logic [63:0] values;
  } packet_t;

  localparam int PACKET_W = $bits(packet_t);

  // A flat packed word gives Vivado one unambiguous 64-deep asynchronous-read
  // memory template. The packet struct is used only at the read/write edges.
  (* ram_style = "distributed" *) logic [PACKET_W-1:0]
      fifo_mem [0:FIFO_DEPTH-1];
  logic [PTR_W-1:0] read_ptr_q;
  logic [PTR_W-1:0] write_ptr_q;
  logic [COUNT_W-1:0] count_q;
  logic configured_q;
  logic [1:0] destination_q;
  logic [N_BASE_W-1:0] n_base_q;
  logic [2:0] slice_q;
  wire [2:0] selected_slice = RUNTIME_SLICE_INDEX ? cfg_slice_index : 3'(SLICE_INDEX);
  logic [7:0] lane_mask_q;
  packet_t front_packet;
  packet_t push_packet;
  logic pop;
  logic push;

  assign cfg_ready = (count_q == 0);
  assign idle = (count_q == 0);
  assign queued_count = count_q;
  assign egress_valid = (count_q != 0);
  assign front_packet = fifo_mem[read_ptr_q];
  assign pop = egress_valid && egress_ready;
  assign ingress_ready = configured_q && !cfg_valid &&
                         ((count_q < FIFO_DEPTH) || pop);
  assign push = ingress_valid && ingress_ready;

  always_comb begin
    push_packet.m = ingress_m;
    push_packet.tile_tag = ingress_tile_tag;
    for (int lane = 0; lane < 8; lane++) begin
      if (ingress_lane_mask[lane])
        push_packet.values[lane*8 +: 8] = ingress_values[lane*8 +: 8];
      else
        push_packet.values[lane*8 +: 8] = '0;
    end
  end

  // Descriptor fields remain constant until the FIFO drains, so storing them
  // in every entry would duplicate 26 bits across all 64 locations.
  assign egress_destination = destination_q;
  assign egress_n_base = n_base_q;
  assign egress_m = front_packet.m;
  assign egress_tile_tag = front_packet.tile_tag;
  assign egress_lane_mask = lane_mask_q;
  assign egress_values = front_packet.values;
  // Runtime selection is descriptor metadata, not a live output mux. The
  // default constant branch preserves the original fixed-slice interface.
  assign egress_slice = RUNTIME_SLICE_INDEX ? slice_q : 3'(SLICE_INDEX);

  always_ff @(posedge clk) begin
    if (rst) begin
      read_ptr_q <= '0;
      write_ptr_q <= '0;
      count_q <= '0;
      configured_q <= 1'b0;
      destination_q <= '0;
      n_base_q <= '0;
      slice_q <= 3'(SLICE_INDEX);
      lane_mask_q <= '0;
    end else begin
      if (cfg_valid && cfg_ready) begin
        configured_q <= 1'b1;
        destination_q <= cfg_destination;
        n_base_q <= cfg_n64_tile_base + (N_BASE_W'(selected_slice) << 3);
        slice_q <= selected_slice;
        lane_mask_q <= cfg_lane_mask;
      end

      if (push) begin
        fifo_mem[write_ptr_q] <= push_packet;
        write_ptr_q <= write_ptr_q + 1'b1;
      end
      if (pop)
        read_ptr_q <= read_ptr_q + 1'b1;

      case ({push, pop})
        2'b10: count_q <= count_q + 1'b1;
        2'b01: count_q <= count_q - 1'b1;
        default: count_q <= count_q;
      endcase
    end
  end

`ifndef SYNTHESIS
  initial begin
    if (N_BASE_W < 6 || SLICE_INDEX < 0 || SLICE_INDEX > 7 || FIFO_DEPTH != 64 ||
        (FIFO_DEPTH & (FIFO_DEPTH - 1)) != 0)
      $fatal(1, "N8 router requires slice 0..7 and FIFO_DEPTH=64");
  end

  always_ff @(posedge clk) begin
    if (!rst) begin
      if (cfg_valid && cfg_ready) begin
        if (RUNTIME_SLICE_INDEX && $isunknown(cfg_slice_index))
          $fatal(1, "runtime output-router slice must be known at config acceptance");
        if (cfg_destination > 2)
          $fatal(1, "invalid output-router destination");
        if (cfg_n64_tile_base[5:0] != 0)
          $fatal(1, "output-router N tile base must be N64 aligned");
        if (cfg_lane_mask == 0 ||
            ((cfg_lane_mask & (cfg_lane_mask + 1'b1)) != 0))
          $fatal(1, "output-router lane mask must be a low-lane tail mask");
      end
      if (ingress_valid && ingress_ready) begin
        if (ingress_lane_mask == 0)
          $fatal(1, "output-router ingress mask must be nonzero");
        if (ingress_lane_mask != lane_mask_q)
          $fatal(1, "output-router ingress mask changed within descriptor");
        for (int lane = 0; lane < 8; lane++) begin
          if (!ingress_lane_mask[lane] &&
              ingress_values[lane*8 +: 8] != 0)
            $fatal(1, "masked output-router lane %0d must be zero", lane);
        end
      end
    end
  end
`endif

endmodule
