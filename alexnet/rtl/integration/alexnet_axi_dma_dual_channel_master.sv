`timescale 1ns/1ps

// Run the independent MM2S and S2MM channels of one AXI DMA concurrently.
// Each existing simple-channel controller owns only its channel's disjoint
// register addresses.  This wrapper arbitrates complete AXI-Lite write and
// read responses so split AW/W handshakes can never change owner mid-request.
module alexnet_axi_dma_dual_channel_master #(
    parameter logic [31:0] DMA_BASE_ADDR = 32'ha001_0000,
    parameter int MM2S_ALIGNMENT_BYTES = 16,
    parameter int S2MM_ALIGNMENT_BYTES = 8
) (
    input logic clk,
    input logic rst_n,

    input logic mm2s_cmd_valid,
    output logic mm2s_cmd_ready,
    input logic [31:0] mm2s_cmd_address,
    input logic [25:0] mm2s_cmd_length,
    input logic [31:0] mm2s_timeout_cycles,
    output logic mm2s_armed,
    output logic mm2s_busy,
    output logic mm2s_done,
    output logic mm2s_error,
    output logic [3:0] mm2s_error_code,
    output logic [3:0] mm2s_state,

    input logic s2mm_cmd_valid,
    output logic s2mm_cmd_ready,
    input logic [31:0] s2mm_cmd_address,
    input logic [25:0] s2mm_cmd_length,
    input logic [31:0] s2mm_timeout_cycles,
    output logic s2mm_armed,
    output logic s2mm_busy,
    output logic s2mm_done,
    output logic s2mm_error,
    output logic [3:0] s2mm_error_code,
    output logic [3:0] s2mm_state,

    output logic [31:0] m_axi_awaddr,
    output logic [2:0] m_axi_awprot,
    output logic m_axi_awvalid,
    input logic m_axi_awready,
    output logic [31:0] m_axi_wdata,
    output logic [3:0] m_axi_wstrb,
    output logic m_axi_wvalid,
    input logic m_axi_wready,
    input logic [1:0] m_axi_bresp,
    input logic m_axi_bvalid,
    output logic m_axi_bready,
    output logic [31:0] m_axi_araddr,
    output logic [2:0] m_axi_arprot,
    output logic m_axi_arvalid,
    input logic m_axi_arready,
    input logic [31:0] m_axi_rdata,
    input logic [1:0] m_axi_rresp,
    input logic m_axi_rvalid,
    output logic m_axi_rready
);

  logic [31:0] channel_awaddr [0:1];
  logic [2:0] channel_awprot [0:1];
  logic channel_awvalid [0:1], channel_awready [0:1];
  logic [31:0] channel_wdata [0:1];
  logic [3:0] channel_wstrb [0:1];
  logic channel_wvalid [0:1], channel_wready [0:1];
  logic [1:0] channel_bresp [0:1];
  logic channel_bvalid [0:1], channel_bready [0:1];
  logic [31:0] channel_araddr [0:1];
  logic [2:0] channel_arprot [0:1];
  logic channel_arvalid [0:1], channel_arready [0:1];
  logic [31:0] channel_rdata [0:1];
  logic [1:0] channel_rresp [0:1];
  logic channel_rvalid [0:1], channel_rready [0:1];
  logic write_owner_valid_q, write_owner_q;
  logic read_owner_valid_q, read_owner_q;
  logic selected_write_owner, selected_read_owner;
  logic write_request_present, read_request_present;

  // Prefer S2MM when both channels first request the bus. Once any AW or W
  // phase is exposed, retain that owner through the B response.
  always_comb begin
    write_request_present = channel_awvalid[0] || channel_wvalid[0] ||
                            channel_awvalid[1] || channel_wvalid[1];
    selected_write_owner = write_owner_valid_q ? write_owner_q :
        (channel_awvalid[1] || channel_wvalid[1]);
    read_request_present = channel_arvalid[0] || channel_arvalid[1];
    selected_read_owner = read_owner_valid_q ? read_owner_q :
        channel_arvalid[1];

    m_axi_awaddr = 0;
    m_axi_awprot = 0;
    m_axi_awvalid = 0;
    m_axi_wdata = 0;
    m_axi_wstrb = 0;
    m_axi_wvalid = 0;
    m_axi_bready = 0;
    m_axi_araddr = 0;
    m_axi_arprot = 0;
    m_axi_arvalid = 0;
    m_axi_rready = 0;
    for (int channel = 0; channel < 2; channel++) begin
      channel_awready[channel] = 0;
      channel_wready[channel] = 0;
      channel_bresp[channel] = m_axi_bresp;
      channel_bvalid[channel] = 0;
      channel_arready[channel] = 0;
      channel_rdata[channel] = m_axi_rdata;
      channel_rresp[channel] = m_axi_rresp;
      channel_rvalid[channel] = 0;
    end

    if (write_owner_valid_q || write_request_present) begin
      m_axi_awaddr = channel_awaddr[selected_write_owner];
      m_axi_awprot = channel_awprot[selected_write_owner];
      m_axi_awvalid = channel_awvalid[selected_write_owner];
      m_axi_wdata = channel_wdata[selected_write_owner];
      m_axi_wstrb = channel_wstrb[selected_write_owner];
      m_axi_wvalid = channel_wvalid[selected_write_owner];
      m_axi_bready = channel_bready[selected_write_owner];
      channel_awready[selected_write_owner] = m_axi_awready;
      channel_wready[selected_write_owner] = m_axi_wready;
      channel_bvalid[selected_write_owner] = m_axi_bvalid;
    end
    if (read_owner_valid_q || read_request_present) begin
      m_axi_araddr = channel_araddr[selected_read_owner];
      m_axi_arprot = channel_arprot[selected_read_owner];
      m_axi_arvalid = channel_arvalid[selected_read_owner];
      m_axi_rready = channel_rready[selected_read_owner];
      channel_arready[selected_read_owner] = m_axi_arready;
      channel_rvalid[selected_read_owner] = m_axi_rvalid;
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      write_owner_valid_q <= 0;
      write_owner_q <= 0;
      read_owner_valid_q <= 0;
      read_owner_q <= 0;
    end else begin
      if (!write_owner_valid_q && write_request_present) begin
        write_owner_valid_q <= 1;
        write_owner_q <= selected_write_owner;
      end
      if (write_owner_valid_q && m_axi_bvalid && m_axi_bready)
        write_owner_valid_q <= 0;
      if (!read_owner_valid_q && read_request_present) begin
        read_owner_valid_q <= 1;
        read_owner_q <= selected_read_owner;
      end
      if (read_owner_valid_q && m_axi_rvalid && m_axi_rready)
        read_owner_valid_q <= 0;
    end
  end

  axi_dma_simple_master #(
      .DMA_BASE_ADDR(DMA_BASE_ADDR),
      .DMA_ALIGNMENT_BYTES(MM2S_ALIGNMENT_BYTES)
  ) u_mm2s (
      .clk, .rst_n, .clear_error(1'b0),
      .cmd_valid(mm2s_cmd_valid), .cmd_ready(mm2s_cmd_ready),
      .cmd_s2mm(1'b0), .cmd_buffer_addr(mm2s_cmd_address),
      .cmd_length_bytes(mm2s_cmd_length),
      .cmd_timeout_cycles(mm2s_timeout_cycles),
      .armed(mm2s_armed), .busy(mm2s_busy), .done(mm2s_done),
      .error(mm2s_error), .error_code(mm2s_error_code),
      .last_status(), .active_cycles(), .state_debug(mm2s_state),
      .m_axi_awaddr(channel_awaddr[0]),
      .m_axi_awprot(channel_awprot[0]),
      .m_axi_awvalid(channel_awvalid[0]),
      .m_axi_awready(channel_awready[0]),
      .m_axi_wdata(channel_wdata[0]), .m_axi_wstrb(channel_wstrb[0]),
      .m_axi_wvalid(channel_wvalid[0]),
      .m_axi_wready(channel_wready[0]),
      .m_axi_bresp(channel_bresp[0]), .m_axi_bvalid(channel_bvalid[0]),
      .m_axi_bready(channel_bready[0]),
      .m_axi_araddr(channel_araddr[0]),
      .m_axi_arprot(channel_arprot[0]),
      .m_axi_arvalid(channel_arvalid[0]),
      .m_axi_arready(channel_arready[0]),
      .m_axi_rdata(channel_rdata[0]), .m_axi_rresp(channel_rresp[0]),
      .m_axi_rvalid(channel_rvalid[0]),
      .m_axi_rready(channel_rready[0])
  );

  axi_dma_simple_master #(
      .DMA_BASE_ADDR(DMA_BASE_ADDR),
      .DMA_ALIGNMENT_BYTES(S2MM_ALIGNMENT_BYTES)
  ) u_s2mm (
      .clk, .rst_n, .clear_error(1'b0),
      .cmd_valid(s2mm_cmd_valid), .cmd_ready(s2mm_cmd_ready),
      .cmd_s2mm(1'b1), .cmd_buffer_addr(s2mm_cmd_address),
      .cmd_length_bytes(s2mm_cmd_length),
      .cmd_timeout_cycles(s2mm_timeout_cycles),
      .armed(s2mm_armed), .busy(s2mm_busy), .done(s2mm_done),
      .error(s2mm_error), .error_code(s2mm_error_code),
      .last_status(), .active_cycles(), .state_debug(s2mm_state),
      .m_axi_awaddr(channel_awaddr[1]),
      .m_axi_awprot(channel_awprot[1]),
      .m_axi_awvalid(channel_awvalid[1]),
      .m_axi_awready(channel_awready[1]),
      .m_axi_wdata(channel_wdata[1]), .m_axi_wstrb(channel_wstrb[1]),
      .m_axi_wvalid(channel_wvalid[1]),
      .m_axi_wready(channel_wready[1]),
      .m_axi_bresp(channel_bresp[1]), .m_axi_bvalid(channel_bvalid[1]),
      .m_axi_bready(channel_bready[1]),
      .m_axi_araddr(channel_araddr[1]),
      .m_axi_arprot(channel_arprot[1]),
      .m_axi_arvalid(channel_arvalid[1]),
      .m_axi_arready(channel_arready[1]),
      .m_axi_rdata(channel_rdata[1]), .m_axi_rresp(channel_rresp[1]),
      .m_axi_rvalid(channel_rvalid[1]),
      .m_axi_rready(channel_rready[1])
  );

`ifndef SYNTHESIS
  always_ff @(posedge clk) begin
    if (rst_n) begin
      if (channel_awready[0] && channel_awready[1])
        $fatal(1, "dual DMA granted both write channels");
      if (channel_arready[0] && channel_arready[1])
        $fatal(1, "dual DMA granted both read channels");
    end
  end
`endif

endmodule
