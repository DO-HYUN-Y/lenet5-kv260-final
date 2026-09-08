`timescale 1ns/1ps

// Own one launched MM2S command until its DMA status completes. Parameter
// commands are diverted to the fixed-record loader; activation and weight
// commands are forwarded unchanged to the shared Conv/FC compute stream.
// S2MM launches do not acquire the read path.
module alexnet_graph_dma_read_router (
    input logic clk,
    input logic rst,

    input  logic launch_valid,
    output logic launch_ready,
    input  logic launch_s2mm,
    input  logic [2:0] launch_source,
    input  logic [3:0] launch_layer_id,
    input  logic [15:0] launch_n_base,
    input  logic [15:0] launch_tag,
    input  logic [25:0] launch_length_bytes,

    input logic dma_done,
    input logic dma_error,

    input  logic [127:0] s_axis_tdata,
    input  logic [15:0] s_axis_tkeep,
    input  logic s_axis_tvalid,
    output logic s_axis_tready,
    input  logic s_axis_tlast,

    output logic [127:0] graph_axis_tdata,
    output logic [15:0] graph_axis_tkeep,
    output logic graph_axis_tvalid,
    input  logic graph_axis_tready,
    output logic graph_axis_tlast,

    output logic parameter_valid,
    input  logic parameter_ready,
    output logic parameter_is_fc,
    output logic [3:0] parameter_layer_id,
    output logic [15:0] parameter_job_tag,
    output logic [15:0] parameter_n_base,
    output logic signed [31:0] parameter_bias [0:7],
    output logic signed [17:0] parameter_multiplier [0:7],
    output logic [5:0] parameter_right_shift [0:7],

    output logic busy,
    output logic fault,
    output logic [2:0] active_source,
    output logic [25:0] bytes_transferred,
    output logic [31:0] launched_reads,
    output logic [31:0] completed_reads
);
  localparam logic [2:0] SOURCE_RS_ACTIVATION = 3'd0;
  localparam logic [2:0] SOURCE_RS_WEIGHT = 3'd1;
  localparam logic [2:0] SOURCE_CONV_PARAMETER = 3'd2;
  localparam logic [2:0] SOURCE_FC_ACTIVATION = 3'd3;
  localparam logic [2:0] SOURCE_FC_WEIGHT = 3'd4;
  localparam logic [2:0] SOURCE_FC_PARAMETER = 3'd5;

  logic route_active_q;
  logic [2:0] source_q;
  logic [25:0] length_q, bytes_q;
  logic stream_complete_q;
  logic dma_done_seen_q;
  logic fault_q;
  logic source_is_parameter, source_is_payload, source_valid;
  logic launch_fire, axis_fire;
  logic stream_complete_fire, read_complete;
  logic [4:0] beat_bytes;
  logic [26:0] next_bytes;
  logic loader_start_valid, loader_start_ready;
  logic loader_s_axis_tready;
  logic loader_busy, loader_fault;
  logic [2:0] loader_active_lane;
  logic [31:0] loader_accepted, loader_completed, loader_rejected;
  integer bit_index;

  always_comb begin
    beat_bytes = 0;
    for (bit_index = 0; bit_index < 16; bit_index = bit_index + 1)
      beat_bytes = beat_bytes + s_axis_tkeep[bit_index];
  end

  assign source_is_parameter = launch_source == SOURCE_CONV_PARAMETER ||
                               launch_source == SOURCE_FC_PARAMETER;
  assign source_is_payload = launch_source == SOURCE_RS_ACTIVATION ||
      launch_source == SOURCE_RS_WEIGHT ||
      launch_source == SOURCE_FC_ACTIVATION ||
      launch_source == SOURCE_FC_WEIGHT;
  assign source_valid = source_is_parameter || source_is_payload;
  assign launch_ready = !fault_q && !dma_error &&
      (launch_s2mm || (!route_active_q && !loader_busy && source_valid &&
       (!source_is_parameter || loader_start_ready)));
  assign launch_fire = launch_valid && launch_ready;

  assign loader_start_valid = launch_valid && launch_ready && !launch_s2mm &&
                              source_is_parameter;
  assign s_axis_tready = route_active_q &&
      ((source_q == SOURCE_CONV_PARAMETER || source_q == SOURCE_FC_PARAMETER) ?
       loader_s_axis_tready : graph_axis_tready);
  assign axis_fire = s_axis_tvalid && s_axis_tready;
  assign next_bytes = {1'b0, bytes_q} + beat_bytes;
  assign stream_complete_fire = axis_fire && s_axis_tlast &&
                                next_bytes == {1'b0, length_q};
  // AXI DMA can raise IOC after its memory-side read has completed while the
  // final payload beats are still buffered behind AXIS backpressure.  Treat
  // the DMA status and stream TLAST as two independent completion events and
  // release ownership only after both have been observed, in either order.
  // Requiring the registered stream-complete flag also cuts the TKEEP byte
  // count and length comparison out of the route-control feedback path.
  assign read_complete = route_active_q &&
                         (dma_done_seen_q || dma_done) &&
                         stream_complete_q;

  assign graph_axis_tdata = s_axis_tdata;
  assign graph_axis_tkeep = s_axis_tkeep;
  assign graph_axis_tvalid = route_active_q &&
      source_q != SOURCE_CONV_PARAMETER && source_q != SOURCE_FC_PARAMETER &&
      s_axis_tvalid;
  assign graph_axis_tlast = s_axis_tlast;
  assign busy = route_active_q || loader_busy;
  assign fault = fault_q || loader_fault;
  assign active_source = source_q;
  assign bytes_transferred = bytes_q;

  alexnet_parameter_record_loader u_parameter_loader (
      .clk(clk), .rst(rst),
      .start_valid(loader_start_valid), .start_ready(loader_start_ready),
      .start_is_fc(launch_source == SOURCE_FC_PARAMETER),
      .start_layer_id(launch_layer_id), .start_job_tag(launch_tag),
      .start_n_base(launch_n_base),
      .s_axis_tdata(s_axis_tdata), .s_axis_tkeep(s_axis_tkeep),
      .s_axis_tvalid(s_axis_tvalid && route_active_q &&
          (source_q == SOURCE_CONV_PARAMETER ||
           source_q == SOURCE_FC_PARAMETER)),
      .s_axis_tready(loader_s_axis_tready), .s_axis_tlast(s_axis_tlast),
      .parameter_valid(parameter_valid), .parameter_ready(parameter_ready),
      .parameter_is_fc(parameter_is_fc),
      .parameter_layer_id(parameter_layer_id),
      .parameter_job_tag(parameter_job_tag),
      .parameter_n_base(parameter_n_base),
      .parameter_bias(parameter_bias),
      .parameter_multiplier(parameter_multiplier),
      .parameter_right_shift(parameter_right_shift),
      .busy(loader_busy), .fault(loader_fault),
      .active_lane(loader_active_lane), .accepted_tiles(loader_accepted),
      .completed_tiles(loader_completed), .rejected_tiles(loader_rejected)
  );

  always_ff @(posedge clk) begin
    if (rst) begin
      route_active_q <= 1'b0;
      source_q <= 0;
      length_q <= 0;
      bytes_q <= 0;
      stream_complete_q <= 1'b0;
      dma_done_seen_q <= 1'b0;
      fault_q <= 1'b0;
      launched_reads <= 0;
      completed_reads <= 0;
    end else begin
      if (launch_fire && !launch_s2mm) begin
        route_active_q <= 1'b1;
        source_q <= launch_source;
        length_q <= launch_length_bytes;
        bytes_q <= 0;
        stream_complete_q <= 1'b0;
        dma_done_seen_q <= 1'b0;
        launched_reads <= launched_reads + 1'b1;
      end

      if (axis_fire) begin
        bytes_q <= next_bytes[25:0];
        if (next_bytes > {1'b0, length_q} ||
            (s_axis_tlast && next_bytes != {1'b0, length_q}) ||
            (!s_axis_tlast && next_bytes >= {1'b0, length_q}))
          fault_q <= 1'b1;
        if (stream_complete_fire)
          stream_complete_q <= 1'b1;
      end

      if (dma_done && route_active_q)
        dma_done_seen_q <= 1'b1;

      if (read_complete) begin
        route_active_q <= 1'b0;
        stream_complete_q <= 1'b0;
        dma_done_seen_q <= 1'b0;
        completed_reads <= completed_reads + 1'b1;
      end
      if (dma_error && route_active_q) begin
        route_active_q <= 1'b0;
        stream_complete_q <= 1'b0;
        dma_done_seen_q <= 1'b0;
        fault_q <= 1'b1;
      end
    end
  end

`ifndef SYNTHESIS
  always_ff @(posedge clk) begin
    if (!rst) begin
      if (launch_fire && !launch_s2mm && !source_valid)
        $fatal(1, "DMA read router accepted an invalid MM2S source");
      if (s_axis_tvalid && !route_active_q)
        $warning("DMA read router received MM2S data without an owner");
      if (dma_done && route_active_q && !stream_complete_q &&
          !stream_complete_fire)
        $info("DMA MM2S status completed before stream TLAST; waiting for buffered payload");
    end
  end
`endif
endmodule
