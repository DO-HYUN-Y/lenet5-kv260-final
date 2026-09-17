`timescale 1ns/1ps

// First numerical checkpoint at the PS-facing integrated top.  A compact DMA
// model supplies the trained Conv1 raster, first physical N64 weight tile and
// first eight parameter records, then checks the first 8x8 scatter write.
module tb_alexnet_m8n126_graph_top_trained_conv1_smoke;
  localparam logic [31:0] INPUT_BASE = 32'h1000_0000;
  localparam logic [31:0] ACT_A_BASE = 32'h2000_0000;
  localparam logic [31:0] ACT_B_BASE = 32'h3000_0000;
  localparam logic [31:0] WEIGHT_BASE = 32'h4000_0000;
  localparam logic [31:0] PARAMETER_BASE = 32'h5000_0000;
  localparam logic [31:0] OUTPUT_BASE = 32'h6000_0000;
  localparam logic [31:0] MAIN_DMA_BASE = 32'ha001_0000;
  localparam logic [31:0] WEIGHT_DMA_BASE = 32'ha003_0000;
  localparam int INPUT_BEATS = 401408 / 16;
  localparam int WEIGHT_BEATS = (4 * 363 * 16) / 16;

  logic clk = 1'b0;
  logic aresetn;
  always #2.5 clk = ~clk;

  logic [7:0] s_axi_ctrl_awaddr;
  logic [2:0] s_axi_ctrl_awprot;
  logic s_axi_ctrl_awvalid, s_axi_ctrl_awready;
  logic [31:0] s_axi_ctrl_wdata;
  logic [3:0] s_axi_ctrl_wstrb;
  logic s_axi_ctrl_wvalid, s_axi_ctrl_wready;
  logic [1:0] s_axi_ctrl_bresp;
  logic s_axi_ctrl_bvalid, s_axi_ctrl_bready;
  logic [7:0] s_axi_ctrl_araddr;
  logic [2:0] s_axi_ctrl_arprot;
  logic s_axi_ctrl_arvalid, s_axi_ctrl_arready;
  logic [31:0] s_axi_ctrl_rdata;
  logic [1:0] s_axi_ctrl_rresp;
  logic s_axi_ctrl_rvalid, s_axi_ctrl_rready;

  logic [63:0] s_axis_camera_tdata;
  logic [7:0] s_axis_camera_tkeep;
  logic s_axis_camera_tvalid, s_axis_camera_tready;
  logic s_axis_camera_tlast;

  logic [127:0] s_axis_mm2s_tdata;
  logic [15:0] s_axis_mm2s_tkeep;
  logic s_axis_mm2s_tvalid, s_axis_mm2s_tready;
  logic s_axis_mm2s_tlast;
  logic [127:0] s_axis_weight_tdata;
  logic [15:0] s_axis_weight_tkeep;
  logic s_axis_weight_tvalid, s_axis_weight_tready;
  logic s_axis_weight_tlast;
  logic [127:0] m_axis_s2mm_tdata;
  logic [15:0] m_axis_s2mm_tkeep;
  logic m_axis_s2mm_tvalid, m_axis_s2mm_tready;
  logic m_axis_s2mm_tlast;

  logic [31:0] m_axi_dma_awaddr;
  logic [2:0] m_axi_dma_awprot;
  logic m_axi_dma_awvalid, m_axi_dma_awready;
  logic [31:0] m_axi_dma_wdata;
  logic [3:0] m_axi_dma_wstrb;
  logic m_axi_dma_wvalid, m_axi_dma_wready;
  logic [1:0] m_axi_dma_bresp;
  logic m_axi_dma_bvalid, m_axi_dma_bready;
  logic [31:0] m_axi_dma_araddr;
  logic [2:0] m_axi_dma_arprot;
  logic m_axi_dma_arvalid, m_axi_dma_arready;
  logic [31:0] m_axi_dma_rdata;
  logic [1:0] m_axi_dma_rresp;
  logic m_axi_dma_rvalid, m_axi_dma_rready;

  logic [31:0] m_axi_weight_dma_awaddr;
  logic [2:0] m_axi_weight_dma_awprot;
  logic m_axi_weight_dma_awvalid, m_axi_weight_dma_awready;
  logic [31:0] m_axi_weight_dma_wdata;
  logic [3:0] m_axi_weight_dma_wstrb;
  logic m_axi_weight_dma_wvalid, m_axi_weight_dma_wready;
  logic [1:0] m_axi_weight_dma_bresp;
  logic m_axi_weight_dma_bvalid, m_axi_weight_dma_bready;
  logic [31:0] m_axi_weight_dma_araddr;
  logic [2:0] m_axi_weight_dma_arprot;
  logic m_axi_weight_dma_arvalid, m_axi_weight_dma_arready;
  logic [31:0] m_axi_weight_dma_rdata;
  logic [1:0] m_axi_weight_dma_rresp;
  logic m_axi_weight_dma_rvalid, m_axi_weight_dma_rready;

  logic irq, accelerator_busy, accelerator_fault;

  logic [127:0] input_memory [0:INPUT_BEATS-1];
  logic [127:0] weight_memory [0:WEIGHT_BEATS-1];
  logic [127:0] parameter_memory [0:7];
  logic [127:0] expected_memory [0:3];
  string vector_root;

  bit main_aw_seen, main_w_seen;
  logic [31:0] main_aw_hold, main_w_hold;
  logic [31:0] main_mm2s_address, main_s2mm_address;
  bit main_mm2s_active, main_mm2s_done;
  int main_mm2s_beats, main_mm2s_index, main_completed_mm2s;
  bit main_s2mm_active, main_s2mm_done;
  int main_s2mm_beats, main_s2mm_index, main_completed_s2mm;

  bit weight_aw_seen, weight_w_seen;
  logic [31:0] weight_aw_hold, weight_w_hold;
  logic [31:0] weight_mm2s_address;
  bit weight_transfer_active, weight_transfer_done;
  int weight_transfer_beats, weight_transfer_index;
  int weight_completed_transfers;

  alexnet_m8n126_graph_accelerator_top dut (
      .aclk(clk), .aresetn, .*
  );

  always_comb begin
    m_axi_dma_awready = !main_aw_seen && !m_axi_dma_bvalid;
    m_axi_dma_wready = !main_w_seen && !m_axi_dma_bvalid;
    m_axi_dma_arready = !m_axi_dma_rvalid;
    m_axi_weight_dma_awready = !weight_aw_seen &&
                               !m_axi_weight_dma_bvalid;
    m_axi_weight_dma_wready = !weight_w_seen &&
                              !m_axi_weight_dma_bvalid;
    m_axi_weight_dma_arready = !m_axi_weight_dma_rvalid;

    s_axis_mm2s_tdata = '0;
    s_axis_mm2s_tkeep = 16'hffff;
    s_axis_mm2s_tvalid = main_mm2s_active;
    s_axis_mm2s_tlast = s_axis_mm2s_tvalid &&
        main_mm2s_index + 1 == main_mm2s_beats;
    if (main_mm2s_address == INPUT_BASE &&
        main_mm2s_index < INPUT_BEATS)
      s_axis_mm2s_tdata = input_memory[main_mm2s_index];
    else if (main_mm2s_address == PARAMETER_BASE &&
             main_mm2s_index < 8)
      s_axis_mm2s_tdata = parameter_memory[main_mm2s_index];

    s_axis_weight_tdata = weight_mm2s_address == WEIGHT_BASE &&
                         weight_transfer_index < WEIGHT_BEATS ?
        weight_memory[weight_transfer_index] :
        weight_mm2s_address == PARAMETER_BASE &&
        weight_transfer_index < 8 ? parameter_memory[weight_transfer_index] :
        '0;
    s_axis_weight_tkeep = 16'hffff;
    s_axis_weight_tvalid = weight_transfer_active;
    s_axis_weight_tlast = s_axis_weight_tvalid &&
        weight_transfer_index + 1 == weight_transfer_beats;
    m_axis_s2mm_tready = main_s2mm_active;
  end

  // Main DMA register model and associated stream endpoint.
  always @(posedge clk) begin : main_dma_model
    bit aw_fire;
    bit w_fire;
    logic [31:0] committed_address;
    logic [31:0] committed_data;
    if (!aresetn) begin
      main_aw_seen = 0;
      main_w_seen = 0;
      main_aw_hold = 0;
      main_w_hold = 0;
      m_axi_dma_bvalid <= 0;
      m_axi_dma_bresp = 0;
      m_axi_dma_rvalid <= 0;
      m_axi_dma_rresp = 0;
      m_axi_dma_rdata = 0;
      main_mm2s_address = 0;
      main_s2mm_address = 0;
      main_mm2s_active = 0;
      main_mm2s_done = 0;
      main_mm2s_beats = 0;
      main_mm2s_index = 0;
      main_completed_mm2s = 0;
      main_s2mm_active = 0;
      main_s2mm_done = 0;
      main_s2mm_beats = 0;
      main_s2mm_index = 0;
      main_completed_s2mm = 0;
    end else begin
      if (m_axi_dma_bvalid && m_axi_dma_bready)
        m_axi_dma_bvalid <= 0;
      if (m_axi_dma_rvalid && m_axi_dma_rready)
        m_axi_dma_rvalid <= 0;

      aw_fire = m_axi_dma_awvalid && m_axi_dma_awready;
      w_fire = m_axi_dma_wvalid && m_axi_dma_wready;
      if (aw_fire) begin
        main_aw_hold = m_axi_dma_awaddr;
        main_aw_seen = 1;
      end
      if (w_fire) begin
        main_w_hold = m_axi_dma_wdata;
        main_w_seen = 1;
        if (m_axi_dma_wstrb !== 4'hf)
          $fatal(1, "main DMA WSTRB mismatch");
      end
      if (main_aw_seen && main_w_seen && !m_axi_dma_bvalid) begin
        committed_address = main_aw_hold;
        committed_data = main_w_hold;
        $display("TRAINED_TOP_MAIN_DMA_WRITE address=%08h data=%08h",
                 committed_address, committed_data);
        $fflush();
        main_aw_seen = 0;
        main_w_seen = 0;
        m_axi_dma_bresp = 0;
        m_axi_dma_bvalid <= 1;
        case (committed_address)
          MAIN_DMA_BASE + 32'h04: main_mm2s_done = 0;
          MAIN_DMA_BASE + 32'h34: main_s2mm_done = 0;
          MAIN_DMA_BASE + 32'h18: main_mm2s_address = committed_data;
          MAIN_DMA_BASE + 32'h48: main_s2mm_address = committed_data;
          MAIN_DMA_BASE + 32'h28: begin
            if (main_mm2s_active)
              $fatal(1, "overlapping main MM2S transfer");
            main_mm2s_active = 1;
            main_mm2s_done = 0;
            main_mm2s_index = 0;
            main_mm2s_beats = (committed_data + 15) / 16;
            if (!((main_mm2s_address == INPUT_BASE &&
                   committed_data == 401408) ||
                  (main_mm2s_address == PARAMETER_BASE &&
                   committed_data == 128)))
              $fatal(1,
                     "unexpected main MM2S address=%h bytes=%0d",
                     main_mm2s_address, committed_data);
          end
          MAIN_DMA_BASE + 32'h58: begin
            if (main_s2mm_active)
              $fatal(1, "overlapping main S2MM transfer");
            main_s2mm_active = 1;
            main_s2mm_done = 0;
            main_s2mm_index = 0;
            main_s2mm_beats = (committed_data + 15) / 16;
            if (main_s2mm_address != ACT_A_BASE || committed_data != 64)
              $fatal(1,
                     "unexpected first S2MM address=%h bytes=%0d",
                     main_s2mm_address, committed_data);
          end
          default: begin
            if (committed_address != MAIN_DMA_BASE + 32'h00 &&
                committed_address != MAIN_DMA_BASE + 32'h30)
              $fatal(1, "unexpected main DMA write address=%h",
                     committed_address);
          end
        endcase
      end

      if (m_axi_dma_arvalid && m_axi_dma_arready) begin
        if (m_axi_dma_araddr != MAIN_DMA_BASE + 32'h04 &&
            m_axi_dma_araddr != MAIN_DMA_BASE + 32'h34)
          $fatal(1, "unexpected main DMA status address=%h",
                 m_axi_dma_araddr);
        m_axi_dma_rdata = m_axi_dma_araddr == MAIN_DMA_BASE + 32'h04 ?
            (main_mm2s_done ? 32'h0000_1000 : 0) :
            (main_s2mm_done ? 32'h0000_1000 : 0);
        m_axi_dma_rresp = 0;
        m_axi_dma_rvalid <= 1;
      end

      if (main_mm2s_active &&
          s_axis_mm2s_tvalid && s_axis_mm2s_tready) begin
        if (main_mm2s_index + 1 == main_mm2s_beats) begin
          main_mm2s_active = 0;
          main_mm2s_done = 1;
          main_completed_mm2s++;
        end else begin
          main_mm2s_index++;
        end
      end
      if (main_s2mm_active &&
          m_axis_s2mm_tvalid && m_axis_s2mm_tready) begin
        if (m_axis_s2mm_tdata !== expected_memory[main_s2mm_index])
          $fatal(1,
                 "trained top result mismatch beat=%0d got=%032h expected=%032h",
                 main_s2mm_index, m_axis_s2mm_tdata,
                 expected_memory[main_s2mm_index]);
        if (m_axis_s2mm_tkeep != 16'hffff ||
            m_axis_s2mm_tlast !=
                (main_s2mm_index + 1 == main_s2mm_beats))
          $fatal(1, "trained top result framing mismatch beat=%0d",
                 main_s2mm_index);
        if (main_s2mm_index + 1 == main_s2mm_beats) begin
          main_s2mm_active = 0;
          main_s2mm_done = 1;
          main_completed_s2mm++;
        end else begin
          main_s2mm_index++;
        end
      end
    end
  end

  // Independent HP3 weight-DMA register model and stream endpoint.
  always @(posedge clk) begin : weight_dma_model
    bit aw_fire;
    bit w_fire;
    logic [31:0] committed_address;
    logic [31:0] committed_data;
    if (!aresetn) begin
      weight_aw_seen = 0;
      weight_w_seen = 0;
      weight_aw_hold = 0;
      weight_w_hold = 0;
      m_axi_weight_dma_bvalid <= 0;
      m_axi_weight_dma_bresp = 0;
      m_axi_weight_dma_rvalid <= 0;
      m_axi_weight_dma_rresp = 0;
      m_axi_weight_dma_rdata = 0;
      weight_mm2s_address = 0;
      weight_transfer_active = 0;
      weight_transfer_done = 0;
      weight_transfer_beats = 0;
      weight_transfer_index = 0;
      weight_completed_transfers = 0;
    end else begin
      if (m_axi_weight_dma_bvalid && m_axi_weight_dma_bready)
        m_axi_weight_dma_bvalid <= 0;
      if (m_axi_weight_dma_rvalid && m_axi_weight_dma_rready)
        m_axi_weight_dma_rvalid <= 0;

      aw_fire = m_axi_weight_dma_awvalid && m_axi_weight_dma_awready;
      w_fire = m_axi_weight_dma_wvalid && m_axi_weight_dma_wready;
      if (aw_fire) begin
        weight_aw_hold = m_axi_weight_dma_awaddr;
        weight_aw_seen = 1;
      end
      if (w_fire) begin
        weight_w_hold = m_axi_weight_dma_wdata;
        weight_w_seen = 1;
        if (m_axi_weight_dma_wstrb !== 4'hf)
          $fatal(1, "weight DMA WSTRB mismatch");
      end
      if (weight_aw_seen && weight_w_seen &&
          !m_axi_weight_dma_bvalid) begin
        committed_address = weight_aw_hold;
        committed_data = weight_w_hold;
        $display("TRAINED_TOP_WEIGHT_DMA_WRITE address=%08h data=%08h",
                 committed_address, committed_data);
        $fflush();
        weight_aw_seen = 0;
        weight_w_seen = 0;
        m_axi_weight_dma_bresp = 0;
        m_axi_weight_dma_bvalid <= 1;
        case (committed_address)
          WEIGHT_DMA_BASE + 32'h04: weight_transfer_done = 0;
          WEIGHT_DMA_BASE + 32'h18: weight_mm2s_address = committed_data;
          WEIGHT_DMA_BASE + 32'h28: begin
            if (weight_transfer_active)
              $fatal(1, "overlapping weight/parameter transfer");
            weight_transfer_active = 1;
            weight_transfer_done = 0;
            weight_transfer_index = 0;
            weight_transfer_beats = (committed_data + 15) / 16;
            if (!((weight_mm2s_address == WEIGHT_BASE &&
                   committed_data == 4 * 363 * 16) ||
                  (weight_mm2s_address == PARAMETER_BASE &&
                   committed_data == 128)))
              $fatal(1,
                     "unexpected weight/parameter DMA address=%h bytes=%0d",
                     weight_mm2s_address, committed_data);
          end
          default: begin
            if (committed_address != WEIGHT_DMA_BASE)
              $fatal(1, "unexpected weight DMA write address=%h",
                     committed_address);
          end
        endcase
      end

      if (m_axi_weight_dma_arvalid && m_axi_weight_dma_arready) begin
        if (m_axi_weight_dma_araddr != WEIGHT_DMA_BASE + 32'h04)
          $fatal(1, "unexpected weight DMA status address=%h",
                 m_axi_weight_dma_araddr);
        m_axi_weight_dma_rdata = weight_transfer_done ? 32'h0000_1000 : 0;
        m_axi_weight_dma_rresp = 0;
        m_axi_weight_dma_rvalid <= 1;
      end

      if (weight_transfer_active && s_axis_weight_tvalid &&
          s_axis_weight_tready) begin
        if (weight_transfer_index + 1 == weight_transfer_beats) begin
          weight_transfer_active = 0;
          weight_transfer_done = 1;
          weight_completed_transfers++;
        end else begin
          weight_transfer_index++;
        end
      end
    end
  end

  task automatic axi_write(input logic [7:0] address,
                           input logic [31:0] data);
    bit aw_done;
    bit w_done;
    begin
      aw_done = 0;
      w_done = 0;
      @(negedge clk);
      s_axi_ctrl_awaddr = address;
      s_axi_ctrl_awvalid = 1;
      s_axi_ctrl_wdata = data;
      s_axi_ctrl_wstrb = 4'hf;
      s_axi_ctrl_wvalid = 1;
      while (!aw_done || !w_done) begin
        @(posedge clk);
        if (s_axi_ctrl_awvalid && s_axi_ctrl_awready)
          aw_done = 1;
        if (s_axi_ctrl_wvalid && s_axi_ctrl_wready)
          w_done = 1;
        @(negedge clk);
        if (aw_done)
          s_axi_ctrl_awvalid = 0;
        if (w_done)
          s_axi_ctrl_wvalid = 0;
      end
      while (!s_axi_ctrl_bvalid)
        @(negedge clk);
      if (s_axi_ctrl_bresp != 0)
        $fatal(1, "control write failed address=%h response=%0d",
               address, s_axi_ctrl_bresp);
      s_axi_ctrl_bready = 1;
      @(posedge clk);
      @(negedge clk);
      s_axi_ctrl_bready = 0;
    end
  endtask

  initial begin
    string path;
    if (!$value$plusargs("VECTOR_ROOT=%s", vector_root))
      $fatal(1, "VECTOR_ROOT plusarg is required");
    path = $sformatf("%s/input_axis128.mem", vector_root);
    $readmemh(path, input_memory);
    path = $sformatf("%s/weight_axis128.mem", vector_root);
    $readmemh(path, weight_memory);
    path = $sformatf("%s/parameter_axis128.mem", vector_root);
    $readmemh(path, parameter_memory);
    path = $sformatf("%s/expected_result_axis128.mem", vector_root);
    $readmemh(path, expected_memory);

    aresetn = 0;
    s_axi_ctrl_awaddr = 0;
    s_axi_ctrl_awprot = 0;
    s_axi_ctrl_awvalid = 0;
    s_axi_ctrl_wdata = 0;
    s_axi_ctrl_wstrb = 0;
    s_axi_ctrl_wvalid = 0;
    s_axi_ctrl_bready = 0;
    s_axi_ctrl_araddr = 0;
    s_axi_ctrl_arprot = 0;
    s_axi_ctrl_arvalid = 0;
    s_axi_ctrl_rready = 0;
    s_axis_camera_tdata = 0;
    s_axis_camera_tkeep = 0;
    s_axis_camera_tvalid = 0;
    s_axis_camera_tlast = 0;

    repeat (10) @(negedge clk);
    aresetn = 1;
    repeat (4) @(negedge clk);

    axi_write(8'h0c, 32'h0000_7a01);
    axi_write(8'h10, INPUT_BASE);
    axi_write(8'h18, ACT_A_BASE);
    axi_write(8'h20, ACT_B_BASE);
    axi_write(8'h28, WEIGHT_BASE);
    axi_write(8'h30, PARAMETER_BASE);
    axi_write(8'h38, OUTPUT_BASE);
    axi_write(8'h40, 32'd2_000_000);
    axi_write(8'h04, 32'h0000_0001);

    for (int timeout = 0; timeout < 500000; timeout++) begin
      @(negedge clk);
      if (accelerator_fault)
        $fatal(1,
               "trained graph top fault state=%0d layer=%0d main=%0d weight=%0d",
               dut.main_state_q, dut.engine_active_layer_id,
               {dut.unused_main_s2mm_state, dut.unused_main_mm2s_state},
               dut.unused_weight_dma_state);
      if (main_completed_s2mm == 1) begin
        if (weight_completed_transfers != 2 ||
            dut.engine_completed_commands != 0 ||
            dut.engine_issue_cycles != 363)
          $fatal(1,
                 "trained top checkpoint accounting mm2s=%0d s2mm=%0d weight=%0d commands=%0d issues=%0d",
                 main_completed_mm2s, main_completed_s2mm,
                 weight_completed_transfers,
                 dut.engine_completed_commands, dut.engine_issue_cycles);
        $display("ALEXNET_M8N126_GRAPH_TOP_TRAINED_CONV1_SMOKE_PASS main_mm2s=%0d main_s2mm=%0d weight_dma=%0d issues=%0d result_beats=4",
                 main_completed_mm2s, main_completed_s2mm,
                 weight_completed_transfers,
                 dut.engine_issue_cycles);
        $finish;
      end
    end
    $fatal(1,
           "trained graph top smoke timeout mm2s=%0d active=%0b index=%0d/%0d ready=%0b s2mm=%0d active=%0b index=%0d/%0d ready=%0b weight=%0d active=%0b index=%0d/%0d ready=%0b state=%0d layer=%0d issues=%0d raster=%0b/%0b/%0b engine=%0d dma_states=%0d/%0d/%0d",
           main_completed_mm2s, main_mm2s_active, main_mm2s_index,
           main_mm2s_beats, s_axis_mm2s_tready, main_completed_s2mm,
           main_s2mm_active, main_s2mm_index, main_s2mm_beats,
           m_axis_s2mm_tready, weight_completed_transfers,
           weight_transfer_active, weight_transfer_index,
           weight_transfer_beats, s_axis_weight_tready, dut.main_state_q,
           dut.engine_active_layer_id, dut.engine_issue_cycles,
           dut.raster_frame_active, dut.raster_active, dut.raster_idle,
           dut.u_graph_payload.state_q, dut.unused_main_mm2s_state,
           dut.unused_main_s2mm_state,
           dut.unused_weight_dma_state);
  end

endmodule
