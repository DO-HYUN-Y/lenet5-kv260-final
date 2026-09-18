`timescale 1ns/1ps
// Pure RS PS-facing shell. DDR is restricted to 32-bit physical addresses,
// matching the existing DMA controller. Weight DMA requires DRE (byte alignment).
// Camera input is unused; PS supplies the quantized N8 input raster in DDR.
(* use_dsp = "no" *) module alexnet_row_stationary_accelerator_top #(
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

    input logic [127:0] s_axis_weight_tdata,
    input logic [15:0] s_axis_weight_tkeep,
    input logic s_axis_weight_tvalid,
    output logic s_axis_weight_tready,
    input logic s_axis_weight_tlast,

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

    output logic [31:0] m_axi_weight_dma_awaddr,
    output logic [2:0] m_axi_weight_dma_awprot,
    output logic m_axi_weight_dma_awvalid,
    input logic m_axi_weight_dma_awready,
    output logic [31:0] m_axi_weight_dma_wdata,
    output logic [3:0] m_axi_weight_dma_wstrb,
    output logic m_axi_weight_dma_wvalid,
    input logic m_axi_weight_dma_wready,
    input logic [1:0] m_axi_weight_dma_bresp,
    input logic m_axi_weight_dma_bvalid,
    output logic m_axi_weight_dma_bready,
    output logic [31:0] m_axi_weight_dma_araddr,
    output logic [2:0] m_axi_weight_dma_arprot,
    output logic m_axi_weight_dma_arvalid,
    input logic m_axi_weight_dma_arready,
    input logic [31:0] m_axi_weight_dma_rdata,
    input logic [1:0] m_axi_weight_dma_rresp,
    input logic m_axi_weight_dma_rvalid,
    output logic m_axi_weight_dma_rready,

    output logic irq,
    output logic accelerator_busy,
    output logic accelerator_fault
);


  logic rst,core_start_valid,core_start_ready;
  logic [15:0] core_start_tag,active_tag_q;
  logic [63:0] active_input_base,active_activation_a_base,active_activation_b_base;
  logic [63:0] active_weights_base,active_parameters_base,active_final_output_base;
  logic [31:0] active_dma_timeout_cycles;
  logic main_dma_cmd_valid,main_dma_cmd_ready,main_dma_cmd_s2mm;
  logic [63:0] main_address64,weight_address64;
  logic [31:0] main_dma_cmd_address,weight_dma_cmd_address;
  logic [25:0] main_dma_cmd_length,weight_dma_cmd_length;
  logic main_dma_armed,main_dma_busy,main_dma_done,main_dma_error;
  logic weight_dma_cmd_valid,weight_dma_cmd_ready,weight_dma_armed,weight_dma_busy,weight_dma_done,weight_dma_error;
  logic [3:0] main_dma_error_code,weight_dma_error_code;
  logic engine_done,engine_busy,engine_fault,failed_pulse_q,fault_seen_q;
  logic [3:0] active_layer;
  logic [31:0] completed_commands,completed_input_tiles,main_completed_transfers,stored_packets,result_signature;
  logic [63:0] useful_mac_count,main_read_axis_bytes,main_write_axis_bytes,weight_service_bytes,gather_requested_bytes;
  logic [63:0] read_before_q,write_before_q,weight_before_q,gather_before_q,mac_before_q;
  logic [31:0] packets_before_q,transfers_before_q;
  logic [31:0] accepted_commands_q,accepted_before_q,active_cycles_q;
  logic [CTRL_ADDR_W-1:0] legacy_araddr;
  logic legacy_arvalid,legacy_arready,legacy_rvalid,legacy_rready;
  logic [31:0] legacy_rdata,extra_rdata_q,telemetry_data;
  logic [1:0] legacy_rresp,extra_rresp_q;
  logic extra_rvalid_q,extra_read;
  logic [63:0] read_job,write_job,weight_job,gather_job,total_job;
  assign rst=!aresetn;
  assign s_axis_camera_tready=1'b1;
  assign main_dma_cmd_address=main_address64[31:0];
  assign weight_dma_cmd_address=weight_address64[31:0];
  assign accelerator_fault=engine_fault || main_dma_error || weight_dma_error;
  assign accelerator_busy=engine_busy || main_dma_busy || weight_dma_busy;
  assign read_job=main_read_axis_bytes-read_before_q;
  assign write_job=main_write_axis_bytes-write_before_q;
  assign weight_job=weight_service_bytes-weight_before_q;
  assign gather_job=gather_requested_bytes-gather_before_q;
  assign total_job=read_job+write_job+weight_job;
  assign extra_read=s_axi_ctrl_araddr>=CTRL_ADDR_W'(8'hb0);
  assign legacy_araddr=s_axi_ctrl_araddr;
  assign legacy_arvalid=s_axi_ctrl_arvalid && !extra_read && !extra_rvalid_q;
  assign s_axi_ctrl_arready=!extra_rvalid_q && !legacy_rvalid && (extra_read || legacy_arready);
  assign s_axi_ctrl_rvalid=extra_rvalid_q || legacy_rvalid;
  assign s_axi_ctrl_rdata=extra_rvalid_q ? extra_rdata_q : legacy_rdata;
  assign s_axi_ctrl_rresp=extra_rvalid_q ? extra_rresp_q : legacy_rresp;
  assign legacy_rready=s_axi_ctrl_rready && !extra_rvalid_q;
  always_comb begin
    telemetry_data=0;
    case(s_axi_ctrl_araddr)
      'hb0:telemetry_data=read_job[31:0]; 'hb4:telemetry_data=read_job[63:32];
      'hb8:telemetry_data=write_job[31:0]; 'hbc:telemetry_data=write_job[63:32];
      'hc0:telemetry_data=weight_job[31:0]; 'hc4:telemetry_data=weight_job[63:32];
      'hc8:telemetry_data=gather_job[31:0]; 'hcc:telemetry_data=gather_job[63:32];
      'hd0:telemetry_data=stored_packets-packets_before_q;
      'hd4:telemetry_data=completed_commands;
      'hd8:telemetry_data=main_completed_transfers-transfers_before_q;
      'hdc:telemetry_data=accepted_commands_q-accepted_before_q;
      'he0:telemetry_data=total_job[31:0]; 'he4:telemetry_data=total_job[63:32];
      'he8:telemetry_data=completed_input_tiles;
      default:telemetry_data=0;
    endcase
  end
  always_ff @(posedge aclk) begin
    if(rst) begin
      active_tag_q<=0;failed_pulse_q<=0;fault_seen_q<=0;extra_rvalid_q<=0;extra_rdata_q<=0;extra_rresp_q<=0;
      read_before_q<=0;write_before_q<=0;weight_before_q<=0;gather_before_q<=0;mac_before_q<=0;
      packets_before_q<=0;transfers_before_q<=0;
      accepted_commands_q<=0;accepted_before_q<=0;active_cycles_q<=0;
    end else begin
      failed_pulse_q<=accelerator_fault && !fault_seen_q;
      if(accelerator_fault) fault_seen_q<=1;
      if(core_start_valid && core_start_ready) begin
        active_tag_q<=core_start_tag;read_before_q<=main_read_axis_bytes;write_before_q<=main_write_axis_bytes;
        weight_before_q<=weight_service_bytes;gather_before_q<=gather_requested_bytes;mac_before_q<=useful_mac_count;
        packets_before_q<=stored_packets;transfers_before_q<=main_completed_transfers;
        accepted_before_q<=accepted_commands_q;active_cycles_q<=0;
      end else if(accelerator_busy) active_cycles_q<=active_cycles_q+1;
      accepted_commands_q<=accepted_commands_q+32'(main_dma_cmd_valid&&main_dma_cmd_ready)+32'(weight_dma_cmd_valid&&weight_dma_cmd_ready);
      if(extra_rvalid_q && s_axi_ctrl_rready) extra_rvalid_q<=0;
      if(s_axi_ctrl_arvalid && s_axi_ctrl_arready && extra_read) begin
        extra_rdata_q<=telemetry_data;extra_rvalid_q<=1;
        extra_rresp_q<=s_axi_ctrl_araddr[1:0]!=0 || s_axi_ctrl_araddr>'he8 ? 2'b10 : 2'b00;
      end
    end
  end
  alexnet_row_stationary_ddr_engine u_engine (
    .clk(aclk),.rst,.start_valid(core_start_valid),.start_ready(core_start_ready),.start_tag(core_start_tag),
    .input_base(active_input_base),.activation_a_base(active_activation_a_base),.activation_b_base(active_activation_b_base),
    .weights_base(active_weights_base),.parameters_base(active_parameters_base),.final_output_base(active_final_output_base),
    .main_command_valid(main_dma_cmd_valid),.main_command_ready(main_dma_cmd_ready),.main_command_s2mm(main_dma_cmd_s2mm),
    .main_command_address(main_address64),.main_command_length(main_dma_cmd_length),
    .main_dma_armed,.main_dma_done,.main_dma_error,
    .main_read_data(s_axis_mm2s_tdata),.main_read_keep(s_axis_mm2s_tkeep),.main_read_valid(s_axis_mm2s_tvalid),
    .main_read_last(s_axis_mm2s_tlast),.main_read_ready(s_axis_mm2s_tready),
    .main_write_data(m_axis_s2mm_tdata),.main_write_keep(m_axis_s2mm_tkeep),.main_write_valid(m_axis_s2mm_tvalid),
    .main_write_last(m_axis_s2mm_tlast),.main_write_ready(m_axis_s2mm_tready),
    .weight_dma_command_valid(weight_dma_cmd_valid),.weight_dma_command_ready(weight_dma_cmd_ready),
    .weight_dma_command_address(weight_address64),.weight_dma_command_length(weight_dma_cmd_length),
    .weight_dma_done,.weight_dma_error,.weight_axis_valid(s_axis_weight_tvalid),.weight_axis_ready(s_axis_weight_tready),
    .weight_axis_values(s_axis_weight_tdata),.weight_axis_keep(s_axis_weight_tkeep),.weight_axis_last(s_axis_weight_tlast),
    .inference_done(engine_done),.busy(engine_busy),.fault(engine_fault),.active_layer,.completed_commands,.completed_input_tiles,
    .useful_mac_count,.main_read_axis_bytes,.main_write_axis_bytes,.weight_service_bytes,.gather_requested_bytes,
    .main_completed_transfers,.stored_packets,.result_signature
  );
  axi_dma_simple_master #(
      .DMA_BASE_ADDR(32'ha001_0000), .DMA_ALIGNMENT_BYTES(8)
  ) u_main_dma_control (
      .clk(aclk), .rst_n(aresetn), .clear_error(1'b0),
      .cmd_valid(main_dma_cmd_valid), .cmd_ready(main_dma_cmd_ready),
      .cmd_s2mm(main_dma_cmd_s2mm),
      .cmd_buffer_addr(main_dma_cmd_address),
      .cmd_length_bytes(main_dma_cmd_length),
      .cmd_timeout_cycles(active_dma_timeout_cycles),
      .armed(main_dma_armed), .busy(main_dma_busy), .done(main_dma_done),
      .error(main_dma_error), .error_code(main_dma_error_code),
      .last_status(),
      .active_cycles(),
      .state_debug(),
      .m_axi_awaddr(m_axi_dma_awaddr), .m_axi_awprot(m_axi_dma_awprot),
      .m_axi_awvalid(m_axi_dma_awvalid), .m_axi_awready(m_axi_dma_awready),
      .m_axi_wdata(m_axi_dma_wdata), .m_axi_wstrb(m_axi_dma_wstrb),
      .m_axi_wvalid(m_axi_dma_wvalid), .m_axi_wready(m_axi_dma_wready),
      .m_axi_bresp(m_axi_dma_bresp), .m_axi_bvalid(m_axi_dma_bvalid),
      .m_axi_bready(m_axi_dma_bready), .m_axi_araddr(m_axi_dma_araddr),
      .m_axi_arprot(m_axi_dma_arprot), .m_axi_arvalid(m_axi_dma_arvalid),
      .m_axi_arready(m_axi_dma_arready), .m_axi_rdata(m_axi_dma_rdata),
      .m_axi_rresp(m_axi_dma_rresp), .m_axi_rvalid(m_axi_dma_rvalid),
      .m_axi_rready(m_axi_dma_rready)
  );

  axi_dma_simple_master #(
      .DMA_BASE_ADDR(32'ha003_0000), .DMA_ALIGNMENT_BYTES(1)
  ) u_weight_dma_control (
      .clk(aclk), .rst_n(aresetn), .clear_error(1'b0),
      .cmd_valid(weight_dma_cmd_valid), .cmd_ready(weight_dma_cmd_ready),
      .cmd_s2mm(1'b0), .cmd_buffer_addr(weight_dma_cmd_address),
      .cmd_length_bytes(weight_dma_cmd_length),
      .cmd_timeout_cycles(active_dma_timeout_cycles),
      .armed(weight_dma_armed), .busy(weight_dma_busy),
      .done(weight_dma_done), .error(weight_dma_error),
      .error_code(weight_dma_error_code),
      .last_status(),
      .active_cycles(),
      .state_debug(),
      .m_axi_awaddr(m_axi_weight_dma_awaddr),
      .m_axi_awprot(m_axi_weight_dma_awprot),
      .m_axi_awvalid(m_axi_weight_dma_awvalid),
      .m_axi_awready(m_axi_weight_dma_awready),
      .m_axi_wdata(m_axi_weight_dma_wdata),
      .m_axi_wstrb(m_axi_weight_dma_wstrb),
      .m_axi_wvalid(m_axi_weight_dma_wvalid),
      .m_axi_wready(m_axi_weight_dma_wready),
      .m_axi_bresp(m_axi_weight_dma_bresp),
      .m_axi_bvalid(m_axi_weight_dma_bvalid),
      .m_axi_bready(m_axi_weight_dma_bready),
      .m_axi_araddr(m_axi_weight_dma_araddr),
      .m_axi_arprot(m_axi_weight_dma_arprot),
      .m_axi_arvalid(m_axi_weight_dma_arvalid),
      .m_axi_arready(m_axi_weight_dma_arready),
      .m_axi_rdata(m_axi_weight_dma_rdata),
      .m_axi_rresp(m_axi_weight_dma_rresp),
      .m_axi_rvalid(m_axi_weight_dma_rvalid),
      .m_axi_rready(m_axi_weight_dma_rready)
  );

  alexnet_axi_lite_regs #(
      .ADDR_W(CTRL_ADDR_W), .MODULE_ID(16'h5253), .VERSION(8'h01),
      .BUILD_M(8'd8), .BUILD_N(8'd128), .BUILD_CLOCK_MHZ(16'd200)
  ) u_control_regs (
      .clk(aclk), .rst,
      .s_axi_awaddr(s_axi_ctrl_awaddr),
      .s_axi_awvalid(s_axi_ctrl_awvalid),
      .s_axi_awready(s_axi_ctrl_awready),
      .s_axi_wdata(s_axi_ctrl_wdata), .s_axi_wstrb(s_axi_ctrl_wstrb),
      .s_axi_wvalid(s_axi_ctrl_wvalid),
      .s_axi_wready(s_axi_ctrl_wready), .s_axi_bresp(s_axi_ctrl_bresp),
      .s_axi_bvalid(s_axi_ctrl_bvalid),
      .s_axi_bready(s_axi_ctrl_bready),
      .s_axi_araddr(legacy_araddr),
      .s_axi_arvalid(legacy_arvalid),
      .s_axi_arready(legacy_arready),
      .s_axi_rdata(legacy_rdata), .s_axi_rresp(legacy_rresp),
      .s_axi_rvalid(legacy_rvalid),
      .s_axi_rready(legacy_rready),
      .core_start_valid, .core_start_ready, .core_start_tag,
      .active_input_base, .active_activation_a_base,
      .active_activation_b_base, .active_weights_base,
      .active_parameters_base, .active_final_output_base,
      .active_dma_timeout_cycles,
      .core_busy(accelerator_busy), .inference_done(engine_done),
      .inference_failed(failed_pulse_q), .core_fault(accelerator_fault),
      .fault_code(accelerator_fault ? 4'h8 : 4'h0),
      .fault_detail({main_dma_error_code, weight_dma_error_code}),
      .graph_phase({1'b0, u_engine.state_q}),
      .active_layer_id(active_layer),
      .active_inference_tag(active_tag_q),
      .completed_conv_layers(engine_done ? 3'd5 :
          active_layer <= 1 ? 3'd0 :
          active_layer > 5 ? 3'd5 :
          active_layer[2:0] - 1'b1),
      .completed_fc_layers(engine_done ? 2'd3 :
          active_layer <= 6 ? 2'd0 :
          active_layer >= 8 ? 2'd2 : 2'd1),
      .pool5_cache_valid(1'b0),
      .dma_busy(main_dma_busy || weight_dma_busy),
      .dma_error(main_dma_error || weight_dma_error),
      .dma_error_code(main_dma_error ? main_dma_error_code :
                      weight_dma_error_code),
      .dma_active_source(weight_dma_busy ? 3'd1 : main_dma_busy ? 3'd2 : 3'd0),
      .dma_accepted_requests(accepted_commands_q-accepted_before_q),
      .dma_issued_commands(accepted_commands_q-accepted_before_q),
      .dma_completed_transfers(stored_packets-packets_before_q),
      .conv_storage_completed_tiles(stored_packets-packets_before_q),
      .perf_active_cycles(active_cycles_q),
      .perf_issue_cycles(32'd0),
      .perf_weight_stall_cycles(32'd0),
      .perf_activation_stall_cycles(32'd0),
      .perf_result_stall_cycles(32'd0),
      .perf_useful_mac_count(useful_mac_count-mac_before_q),
      .perf_peak_mac_slot_count(64'd0),
      .perf_result_signature(result_signature),
      .perf_completed_tiles(16'(completed_commands)),
      .irq,
      .start_pending(), .done_sticky(), .failed_sticky(),
      .fault_sticky(), .start_rejected_sticky()
  );

endmodule
