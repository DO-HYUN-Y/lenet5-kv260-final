`timescale 1ns/1ps

// Vivado-IP boundary for the AlexNet PL accelerator. The PS controls this
// block through S_AXI_CTRL; the accelerator controls one AXI DMA register bank
// through M_AXI_DMA. Camera input is already resized/quantized N8 AXIS data.
// The external AXI DMA IP and ZynqMP PS remain block-design components.
module alexnet_m4n8_accelerator_top #(
    parameter int CTRL_ADDR_W = 8,
    parameter logic [31:0] DMA_BASE_ADDR = 32'ha001_0000
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
  logic core_start_valid, core_start_ready;
  logic [15:0] core_start_tag;
  logic [63:0] active_input_base;
  logic [63:0] active_activation_a_base;
  logic [63:0] active_activation_b_base;
  logic [63:0] active_weights_base;
  logic [63:0] active_parameters_base;
  logic [63:0] active_final_output_base;
  logic [31:0] active_dma_timeout_cycles;

  logic inference_done, inference_failed;
  logic [3:0] fault_code;
  logic [7:0] fault_detail;
  logic [4:0] graph_phase;
  logic [3:0] active_layer_id;
  logic [15:0] active_inference_tag;
  logic [2:0] completed_conv_layers;
  logic [1:0] completed_fc_layers;
  logic pool5_cache_valid;
  logic dma_busy, dma_armed, dma_done, dma_error;
  logic [3:0] dma_error_code;
  logic [2:0] dma_active_source;
  logic [31:0] dma_accepted_requests;
  logic [31:0] dma_issued_commands;
  logic [31:0] dma_completed_transfers;
  logic [31:0] conv_storage_completed_tiles;
  logic start_pending, done_sticky, failed_sticky;
  logic fault_sticky, start_rejected_sticky;

  assign rst = !aresetn;

  alexnet_axi_lite_regs #(
      .ADDR_W(CTRL_ADDR_W)
  ) u_control_regs (
      .clk(aclk), .rst(rst),
      .s_axi_awaddr(s_axi_ctrl_awaddr),
      .s_axi_awvalid(s_axi_ctrl_awvalid),
      .s_axi_awready(s_axi_ctrl_awready),
      .s_axi_wdata(s_axi_ctrl_wdata), .s_axi_wstrb(s_axi_ctrl_wstrb),
      .s_axi_wvalid(s_axi_ctrl_wvalid),
      .s_axi_wready(s_axi_ctrl_wready),
      .s_axi_bresp(s_axi_ctrl_bresp), .s_axi_bvalid(s_axi_ctrl_bvalid),
      .s_axi_bready(s_axi_ctrl_bready),
      .s_axi_araddr(s_axi_ctrl_araddr),
      .s_axi_arvalid(s_axi_ctrl_arvalid),
      .s_axi_arready(s_axi_ctrl_arready),
      .s_axi_rdata(s_axi_ctrl_rdata), .s_axi_rresp(s_axi_ctrl_rresp),
      .s_axi_rvalid(s_axi_ctrl_rvalid),
      .s_axi_rready(s_axi_ctrl_rready),
      .core_start_valid(core_start_valid),
      .core_start_ready(core_start_ready), .core_start_tag(core_start_tag),
      .active_input_base(active_input_base),
      .active_activation_a_base(active_activation_a_base),
      .active_activation_b_base(active_activation_b_base),
      .active_weights_base(active_weights_base),
      .active_parameters_base(active_parameters_base),
      .active_final_output_base(active_final_output_base),
      .active_dma_timeout_cycles(active_dma_timeout_cycles),
      .core_busy(accelerator_busy), .inference_done(inference_done),
      .inference_failed(inference_failed), .core_fault(accelerator_fault),
      .fault_code(fault_code), .fault_detail(fault_detail),
      .graph_phase(graph_phase),
      .active_layer_id(active_layer_id),
      .active_inference_tag(active_inference_tag),
      .completed_conv_layers(completed_conv_layers),
      .completed_fc_layers(completed_fc_layers),
      .pool5_cache_valid(pool5_cache_valid), .dma_busy(dma_busy),
      .dma_error(dma_error), .dma_error_code(dma_error_code),
      .dma_active_source(dma_active_source),
      .dma_accepted_requests(dma_accepted_requests),
      .dma_issued_commands(dma_issued_commands),
      .dma_completed_transfers(dma_completed_transfers),
      .conv_storage_completed_tiles(conv_storage_completed_tiles),
      .perf_active_cycles(32'd0),
      .perf_issue_cycles(32'd0),
      .perf_weight_stall_cycles(32'd0),
      .perf_activation_stall_cycles(32'd0),
      .perf_result_stall_cycles(32'd0),
      .perf_useful_mac_count(64'd0),
      .perf_peak_mac_slot_count(64'd0),
      .perf_result_signature(32'd0),
      .perf_completed_tiles(16'd0),
      .irq(irq), .start_pending(start_pending),
      .done_sticky(done_sticky), .failed_sticky(failed_sticky),
      .fault_sticky(fault_sticky),
      .start_rejected_sticky(start_rejected_sticky)
  );

  alexnet_m4n8_graph_dma_top #(
      .DMA_BASE_ADDR(DMA_BASE_ADDR)
  ) u_graph_dma (
      .clk(aclk), .rst(rst), .ce(1'b1),
      .start_valid(core_start_valid), .start_ready(core_start_ready),
      .start_tag(core_start_tag), .input_base(active_input_base),
      .activation_a_base(active_activation_a_base),
      .activation_b_base(active_activation_b_base),
      .weights_base(active_weights_base),
      .parameters_base(active_parameters_base),
      .final_output_base(active_final_output_base),
      .dma_timeout_cycles(active_dma_timeout_cycles),
      .camera_n8_valid(s_axis_camera_tvalid),
      .camera_n8_ready(s_axis_camera_tready),
      .camera_n8_values(s_axis_camera_tdata),
      .camera_n8_lane_mask(s_axis_camera_tkeep),
      .camera_n8_last(s_axis_camera_tlast),
      .s_axis_mm2s_tdata(s_axis_mm2s_tdata),
      .s_axis_mm2s_tkeep(s_axis_mm2s_tkeep),
      .s_axis_mm2s_tvalid(s_axis_mm2s_tvalid),
      .s_axis_mm2s_tready(s_axis_mm2s_tready),
      .s_axis_mm2s_tlast(s_axis_mm2s_tlast),
      .m_axis_s2mm_tdata(m_axis_s2mm_tdata),
      .m_axis_s2mm_tkeep(m_axis_s2mm_tkeep),
      .m_axis_s2mm_tvalid(m_axis_s2mm_tvalid),
      .m_axis_s2mm_tready(m_axis_s2mm_tready),
      .m_axis_s2mm_tlast(m_axis_s2mm_tlast),
      .m_axi_dma_awaddr(m_axi_dma_awaddr),
      .m_axi_dma_awprot(m_axi_dma_awprot),
      .m_axi_dma_awvalid(m_axi_dma_awvalid),
      .m_axi_dma_awready(m_axi_dma_awready),
      .m_axi_dma_wdata(m_axi_dma_wdata),
      .m_axi_dma_wstrb(m_axi_dma_wstrb),
      .m_axi_dma_wvalid(m_axi_dma_wvalid),
      .m_axi_dma_wready(m_axi_dma_wready),
      .m_axi_dma_bresp(m_axi_dma_bresp),
      .m_axi_dma_bvalid(m_axi_dma_bvalid),
      .m_axi_dma_bready(m_axi_dma_bready),
      .m_axi_dma_araddr(m_axi_dma_araddr),
      .m_axi_dma_arprot(m_axi_dma_arprot),
      .m_axi_dma_arvalid(m_axi_dma_arvalid),
      .m_axi_dma_arready(m_axi_dma_arready),
      .m_axi_dma_rdata(m_axi_dma_rdata),
      .m_axi_dma_rresp(m_axi_dma_rresp),
      .m_axi_dma_rvalid(m_axi_dma_rvalid),
      .m_axi_dma_rready(m_axi_dma_rready),
      .busy(accelerator_busy), .inference_done(inference_done),
      .inference_failed(inference_failed), .fault(accelerator_fault),
      .fault_code(fault_code), .fault_detail(fault_detail),
      .graph_phase(graph_phase),
      .active_layer_id(active_layer_id),
      .active_inference_tag(active_inference_tag),
      .completed_conv_layers(completed_conv_layers),
      .completed_fc_layers(completed_fc_layers),
      .pool5_cache_valid(pool5_cache_valid), .dma_busy(dma_busy),
      .dma_armed(dma_armed), .dma_done(dma_done),
      .dma_error(dma_error), .dma_error_code(dma_error_code),
      .dma_active_source(dma_active_source),
      .dma_accepted_requests(dma_accepted_requests),
      .dma_issued_commands(dma_issued_commands),
      .dma_completed_transfers(dma_completed_transfers),
      .conv_storage_completed_tiles(conv_storage_completed_tiles)
  );

endmodule
