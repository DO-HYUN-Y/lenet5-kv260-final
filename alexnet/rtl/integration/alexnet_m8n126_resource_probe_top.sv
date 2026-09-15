`timescale 1ns/1ps

// KV260 implementation-probe boundary for a logical M8xN126 accelerator.
// The physical array remains M8xN128 (512 packed-MAC DSP48E2s); software and
// the eventual graph result writer discard the final two N lanes.  This top
// deliberately runs the self-contained compute island so utilization, timing,
// power and stall counters can be measured before the full graph is migrated.
module alexnet_m8n126_resource_probe_top #(
    parameter int CTRL_ADDR_W = 8
) (
    input logic aclk,
    input logic aresetn,

    input logic [CTRL_ADDR_W-1:0] s_axi_ctrl_awaddr,
    input logic [2:0] s_axi_ctrl_awprot,
    input logic s_axi_ctrl_awvalid,
    output logic s_axi_ctrl_awready,
    input logic [31:0] s_axi_ctrl_wdata,
    input logic [3:0] s_axi_ctrl_wstrb,
    input logic s_axi_ctrl_wvalid,
    output logic s_axi_ctrl_wready,
    output logic [1:0] s_axi_ctrl_bresp,
    output logic s_axi_ctrl_bvalid,
    input logic s_axi_ctrl_bready,
    input logic [CTRL_ADDR_W-1:0] s_axi_ctrl_araddr,
    input logic [2:0] s_axi_ctrl_arprot,
    input logic s_axi_ctrl_arvalid,
    output logic s_axi_ctrl_arready,
    output logic [31:0] s_axi_ctrl_rdata,
    output logic [1:0] s_axi_ctrl_rresp,
    output logic s_axi_ctrl_rvalid,
    input logic s_axi_ctrl_rready,

    input logic [63:0] s_axis_camera_tdata,
    input logic [7:0] s_axis_camera_tkeep,
    input logic s_axis_camera_tvalid,
    output logic s_axis_camera_tready,
    input logic s_axis_camera_tlast,

    input logic [127:0] s_axis_mm2s_tdata,
    input logic [15:0] s_axis_mm2s_tkeep,
    input logic s_axis_mm2s_tvalid,
    output logic s_axis_mm2s_tready,
    input logic s_axis_mm2s_tlast,
    output logic [127:0] m_axis_s2mm_tdata,
    output logic [15:0] m_axis_s2mm_tkeep,
    output logic m_axis_s2mm_tvalid,
    input logic m_axis_s2mm_tready,
    output logic m_axis_s2mm_tlast,

    output logic [31:0] m_axi_dma_awaddr,
    output logic [2:0] m_axi_dma_awprot,
    output logic m_axi_dma_awvalid,
    input logic m_axi_dma_awready,
    output logic [31:0] m_axi_dma_wdata,
    output logic [3:0] m_axi_dma_wstrb,
    output logic m_axi_dma_wvalid,
    input logic m_axi_dma_wready,
    input logic [1:0] m_axi_dma_bresp,
    input logic m_axi_dma_bvalid,
    output logic m_axi_dma_bready,
    output logic [31:0] m_axi_dma_araddr,
    output logic [2:0] m_axi_dma_arprot,
    output logic m_axi_dma_arvalid,
    input logic m_axi_dma_arready,
    input logic [31:0] m_axi_dma_rdata,
    input logic [1:0] m_axi_dma_rresp,
    input logic m_axi_dma_rvalid,
    output logic m_axi_dma_rready,

    output logic irq,
    output logic accelerator_busy,
    output logic accelerator_fault
);
  logic rst;
  logic core_start_valid;
  logic core_start_ready;
  logic [15:0] core_start_tag;
  logic [15:0] active_tag_q;
  logic island_done;
  logic island_fault;
  logic [31:0] result_signature;
  logic [15:0] completed_tiles;
  logic [31:0] active_cycles;
  logic [31:0] issue_cycles;
  logic [31:0] weight_stall_cycles;
  logic [31:0] activation_stall_cycles;
  logic [31:0] result_stall_cycles;
  logic [63:0] useful_mac_count;
  logic [63:0] peak_mac_slot_count;

  logic [63:0] unused_active_input_base;
  logic [63:0] unused_active_activation_a_base;
  logic [63:0] unused_active_activation_b_base;
  logic [63:0] unused_active_weights_base;
  logic [63:0] unused_active_parameters_base;
  logic [63:0] unused_active_final_output_base;
  logic [31:0] unused_active_dma_timeout_cycles;
  logic unused_start_pending;
  logic unused_done_sticky;
  logic unused_failed_sticky;
  logic unused_fault_sticky;
  logic unused_start_rejected_sticky;

  assign rst = !aresetn;
  assign accelerator_fault = island_fault;

  // The resource probe does not consume board DMA payloads.  Keeping the
  // interfaces protocol-safe lets the same packaged-IP shell be reused while
  // HP-port routing and interconnect cost are measured realistically.
  assign s_axis_camera_tready = 1'b1;
  assign s_axis_mm2s_tready = 1'b1;
  assign m_axis_s2mm_tdata = '0;
  assign m_axis_s2mm_tkeep = '0;
  assign m_axis_s2mm_tvalid = 1'b0;
  assign m_axis_s2mm_tlast = 1'b0;

  assign m_axi_dma_awaddr = '0;
  assign m_axi_dma_awprot = '0;
  assign m_axi_dma_awvalid = 1'b0;
  assign m_axi_dma_wdata = '0;
  assign m_axi_dma_wstrb = '0;
  assign m_axi_dma_wvalid = 1'b0;
  assign m_axi_dma_bready = 1'b1;
  assign m_axi_dma_araddr = '0;
  assign m_axi_dma_arprot = '0;
  assign m_axi_dma_arvalid = 1'b0;
  assign m_axi_dma_rready = 1'b1;

  always_ff @(posedge aclk) begin
    if (rst)
      active_tag_q <= '0;
    else if (core_start_valid && core_start_ready)
      active_tag_q <= core_start_tag;
  end

  alexnet_axi_lite_regs #(
      .ADDR_W(CTRL_ADDR_W),
      .MODULE_ID(16'h4d38),
      .VERSION(8'h7e),
      .BUILD_M(8'd8),
      .BUILD_N(8'd126),
      .BUILD_CLOCK_MHZ(16'd200)
  ) u_control_regs (
      .clk(aclk),
      .rst(rst),
      .s_axi_awaddr(s_axi_ctrl_awaddr),
      .s_axi_awvalid(s_axi_ctrl_awvalid),
      .s_axi_awready(s_axi_ctrl_awready),
      .s_axi_wdata(s_axi_ctrl_wdata),
      .s_axi_wstrb(s_axi_ctrl_wstrb),
      .s_axi_wvalid(s_axi_ctrl_wvalid),
      .s_axi_wready(s_axi_ctrl_wready),
      .s_axi_bresp(s_axi_ctrl_bresp),
      .s_axi_bvalid(s_axi_ctrl_bvalid),
      .s_axi_bready(s_axi_ctrl_bready),
      .s_axi_araddr(s_axi_ctrl_araddr),
      .s_axi_arvalid(s_axi_ctrl_arvalid),
      .s_axi_arready(s_axi_ctrl_arready),
      .s_axi_rdata(s_axi_ctrl_rdata),
      .s_axi_rresp(s_axi_ctrl_rresp),
      .s_axi_rvalid(s_axi_ctrl_rvalid),
      .s_axi_rready(s_axi_ctrl_rready),
      .core_start_valid(core_start_valid),
      .core_start_ready(core_start_ready),
      .core_start_tag(core_start_tag),
      .active_input_base(unused_active_input_base),
      .active_activation_a_base(unused_active_activation_a_base),
      .active_activation_b_base(unused_active_activation_b_base),
      .active_weights_base(unused_active_weights_base),
      .active_parameters_base(unused_active_parameters_base),
      .active_final_output_base(unused_active_final_output_base),
      .active_dma_timeout_cycles(unused_active_dma_timeout_cycles),
      .core_busy(accelerator_busy),
      .inference_done(island_done && !island_fault),
      .inference_failed(island_done && island_fault),
      .core_fault(island_fault),
      .fault_code(island_fault ? 4'h1 : 4'h0),
      .fault_detail(8'd0),
      .graph_phase(accelerator_busy ? 5'd1 : 5'd0),
      .active_layer_id(4'd0),
      .active_inference_tag(active_tag_q),
      .completed_conv_layers(3'd0),
      .completed_fc_layers(2'd0),
      .pool5_cache_valid(1'b0),
      .dma_busy(1'b0),
      .dma_error(1'b0),
      .dma_error_code(4'd0),
      .dma_active_source(3'd0),
      .dma_accepted_requests(32'd0),
      .dma_issued_commands(32'd0),
      .dma_completed_transfers(32'd0),
      .conv_storage_completed_tiles({16'd0, completed_tiles}),
      .perf_active_cycles(active_cycles),
      .perf_issue_cycles(issue_cycles),
      .perf_weight_stall_cycles(weight_stall_cycles),
      .perf_activation_stall_cycles(activation_stall_cycles),
      .perf_result_stall_cycles(result_stall_cycles),
      .perf_useful_mac_count(useful_mac_count),
      .perf_peak_mac_slot_count(peak_mac_slot_count),
      .perf_result_signature(result_signature),
      .perf_completed_tiles(completed_tiles),
      .irq(irq),
      .start_pending(unused_start_pending),
      .done_sticky(unused_done_sticky),
      .failed_sticky(unused_failed_sticky),
      .fault_sticky(unused_fault_sticky),
      .start_rejected_sticky(unused_start_rejected_sticky)
  );

  alexnet_m8n128_compute_island u_compute_island (
      .clk(aclk),
      .rst(rst),
      .start_valid(core_start_valid),
      .start_ready(core_start_ready),
      .seed({core_start_tag, 16'h8128}),
      .busy(accelerator_busy),
      .done(island_done),
      .fault(island_fault),
      .result_signature,
      .completed_tiles,
      .active_cycles,
      .issue_cycles,
      .weight_stall_cycles,
      .activation_stall_cycles,
      .result_stall_cycles,
      .useful_mac_count,
      .peak_mac_slot_count
  );

endmodule
