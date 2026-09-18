`timescale 1ns/1ps

// Trained Conv1 numerical checkpoint at the PS-facing integrated top. A
// compact DMA model can check either the first 8x8 scatter write or all 190
// Conv1 descriptors and the complete 193,600-byte N8-tile-major boundary.
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
  localparam int CONV1_PARAMETER_BEATS = 64;
  localparam int CONV1_RESULT_ROWS = 193600 / 8;
  localparam int CONV1_COMMANDS = 190;
  localparam int CONV1_RESULT_TRANSFERS = 3032;
  localparam int CONV1_ISSUES = CONV1_COMMANDS * 363;
  localparam int ACT_MEMORY_BYTES = 193600;
  localparam int FINAL_OUTPUT_BYTES = 1000;
  localparam int WEIGHT_IMAGE_BYTES = 61123264;
  localparam int PARAMETER_IMAGE_BYTES = 165504;
  localparam int POOL1_RESULT_ROWS = 46656 / 8;
  localparam int CONV2_RESULT_ROWS = 139968 / 8;
  localparam int POOL2_RESULT_ROWS = 32448 / 8;
  localparam int CONV3_RESULT_ROWS = 64896 / 8;
  localparam int CONV4_RESULT_ROWS = 43264 / 8;
  localparam int CONV5_RESULT_ROWS = 43264 / 8;
  localparam int POOL5_RESULT_ROWS = 9216 / 8;
  localparam int FC6_RESULT_ROWS = 4096 / 8;
  localparam int FC7_RESULT_ROWS = 4096 / 8;
  localparam int FC8_RESULT_ROWS = 1000 / 8;
  localparam int FULL_GRAPH_COMMANDS = 1635;
  localparam int FULL_GRAPH_ISSUES = 4487914;

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
  logic [127:0] parameter_memory [0:CONV1_PARAMETER_BEATS-1];
  logic [63:0] expected_result_rows [0:CONV1_RESULT_ROWS-1];
  bit result_row_seen [0:CONV1_RESULT_ROWS-1];
  logic [7:0] activation_a_memory [0:ACT_MEMORY_BYTES-1];
  logic [7:0] activation_b_memory [0:ACT_MEMORY_BYTES-1];
  logic [7:0] final_output_memory [0:FINAL_OUTPUT_BYTES-1];
  logic [63:0] expected_pool1_rows [0:POOL1_RESULT_ROWS-1];
  logic [63:0] expected_conv2_rows [0:CONV2_RESULT_ROWS-1];
  logic [63:0] expected_pool2_rows [0:POOL2_RESULT_ROWS-1];
  logic [63:0] expected_conv3_rows [0:CONV3_RESULT_ROWS-1];
  logic [63:0] expected_conv4_rows [0:CONV4_RESULT_ROWS-1];
  logic [63:0] expected_conv5_rows [0:CONV5_RESULT_ROWS-1];
  logic [63:0] expected_pool5_rows [0:POOL5_RESULT_ROWS-1];
  logic [63:0] expected_fc6_rows [0:FC6_RESULT_ROWS-1];
  logic [63:0] expected_fc7_rows [0:FC7_RESULT_ROWS-1];
  logic [63:0] expected_fc8_rows [0:FC8_RESULT_ROWS-1];
  bit pool1_row_seen [0:POOL1_RESULT_ROWS-1];
  bit conv2_row_seen [0:CONV2_RESULT_ROWS-1];
  bit pool2_row_seen [0:POOL2_RESULT_ROWS-1];
  bit conv3_row_seen [0:CONV3_RESULT_ROWS-1];
  bit conv4_row_seen [0:CONV4_RESULT_ROWS-1];
  bit conv5_row_seen [0:CONV5_RESULT_ROWS-1];
  bit pool5_row_seen [0:POOL5_RESULT_ROWS-1];
  bit fc6_row_seen [0:FC6_RESULT_ROWS-1];
  bit fc7_row_seen [0:FC7_RESULT_ROWS-1];
  bit fc8_row_seen [0:FC8_RESULT_ROWS-1];
  bit full_conv1, full_graph;
  integer last_reported_layer;
  string vector_root, board_root;
  integer weight_file, parameter_file;
  logic [127:0] weight_file_word_q;

  bit main_aw_seen, main_w_seen;
  logic [31:0] main_aw_hold, main_w_hold;
  logic [31:0] main_mm2s_address, main_s2mm_address;
  bit main_mm2s_active, main_mm2s_done;
  int main_mm2s_beats, main_mm2s_index, main_completed_mm2s;
  int main_mm2s_bytes;
  bit main_s2mm_active, main_s2mm_done;
  int main_s2mm_beats, main_s2mm_index, main_completed_s2mm;
  int main_s2mm_bytes;

  bit weight_aw_seen, weight_w_seen;
  logic [31:0] weight_aw_hold, weight_w_hold;
  logic [31:0] weight_mm2s_address;
  bit weight_transfer_active, weight_transfer_done;
  int weight_transfer_beats, weight_transfer_index;
  int weight_completed_transfers;
  longint unsigned weight_payload_bytes;

  alexnet_m8n126_graph_accelerator_top dut (
      .aclk(clk), .aresetn, .*
  );

  always @(posedge clk) begin
    if (!aresetn) begin
      last_reported_layer = -1;
    end else if (full_graph && dut.engine_busy &&
                 dut.engine_active_layer_id != last_reported_layer) begin
      last_reported_layer = dut.engine_active_layer_id;
      $display("FULL_GRAPH_LAYER_START layer=%0d commands=%0d issues=%0d active_cycles=%0d",
               dut.engine_active_layer_id, dut.engine_completed_commands,
               dut.engine_issue_cycles, dut.engine_active_cycles);
    end
  end

  task automatic read_binary_word(input integer file_handle,
                                  output logic [127:0] word);
    integer value;
    begin
      word = 0;
      for (int lane = 0; lane < 16; lane++) begin
        value = $fgetc(file_handle);
        if (value < 0)
          $fatal(1, "unexpected end of binary DMA image");
        word[lane*8 +: 8] = value[7:0];
      end
    end
  endtask

  function automatic logic [7:0] activation_byte(
      input logic [31:0] address);
    int offset;
    begin
      if (address >= ACT_A_BASE &&
          address < ACT_A_BASE + ACT_MEMORY_BYTES) begin
        offset = address - ACT_A_BASE;
        activation_byte = activation_a_memory[offset];
      end else if (address >= ACT_B_BASE &&
                   address < ACT_B_BASE + ACT_MEMORY_BYTES) begin
        offset = address - ACT_B_BASE;
        activation_byte = activation_b_memory[offset];
      end else begin
        activation_byte = 0;
      end
    end
  endfunction

  task automatic write_ddr_byte(input logic [31:0] address,
                                input logic [7:0] value);
    int offset;
    begin
      if (address >= ACT_A_BASE &&
          address < ACT_A_BASE + ACT_MEMORY_BYTES) begin
        offset = address - ACT_A_BASE;
        activation_a_memory[offset] = value;
      end else if (address >= ACT_B_BASE &&
                   address < ACT_B_BASE + ACT_MEMORY_BYTES) begin
        offset = address - ACT_B_BASE;
        activation_b_memory[offset] = value;
      end else if (address >= OUTPUT_BASE &&
                   address < OUTPUT_BASE + FINAL_OUTPUT_BYTES) begin
        offset = address - OUTPUT_BASE;
        final_output_memory[offset] = value;
      end else begin
        $fatal(1, "S2MM byte outside modeled DDR address=%h", address);
      end
    end
  endtask

  task automatic check_full_graph_row(input int layer_id,
                                      input bit pooled,
                                      input int row_index,
                                      input logic [63:0] value);
    begin
      if (pooled) begin
        case (layer_id)
          1: begin
            if (row_index < 0 || row_index >= POOL1_RESULT_ROWS ||
                value !== expected_pool1_rows[row_index])
              $fatal(1, "Pool1 mismatch row=%0d got=%016h", row_index,
                     value);
            if (pool1_row_seen[row_index])
              $fatal(1, "duplicate Pool1 row=%0d", row_index);
            pool1_row_seen[row_index] = 1;
          end
          2: begin
            if (row_index < 0 || row_index >= POOL2_RESULT_ROWS ||
                value !== expected_pool2_rows[row_index])
              $fatal(1, "Pool2 mismatch row=%0d got=%016h", row_index,
                     value);
            if (pool2_row_seen[row_index])
              $fatal(1, "duplicate Pool2 row=%0d", row_index);
            pool2_row_seen[row_index] = 1;
          end
          5: begin
            if (row_index < 0 || row_index >= POOL5_RESULT_ROWS ||
                value !== expected_pool5_rows[row_index])
              $fatal(1, "Pool5 mismatch row=%0d got=%016h", row_index,
                     value);
            if (pool5_row_seen[row_index])
              $fatal(1, "duplicate Pool5 row=%0d", row_index);
            pool5_row_seen[row_index] = 1;
          end
          default: $fatal(1, "unexpected pooled layer=%0d", layer_id);
        endcase
      end else begin
        case (layer_id)
          1: begin
            if (row_index < 0 || row_index >= CONV1_RESULT_ROWS ||
                value !== expected_result_rows[row_index])
              $fatal(1, "Conv1 mismatch row=%0d got=%016h", row_index,
                     value);
            if (result_row_seen[row_index])
              $fatal(1, "duplicate Conv1 row=%0d", row_index);
            result_row_seen[row_index] = 1;
          end
          2: begin
            if (row_index < 0 || row_index >= CONV2_RESULT_ROWS ||
                value !== expected_conv2_rows[row_index])
              $fatal(1, "Conv2 mismatch row=%0d got=%016h", row_index,
                     value);
            if (conv2_row_seen[row_index])
              $fatal(1, "duplicate Conv2 row=%0d", row_index);
            conv2_row_seen[row_index] = 1;
          end
          3: begin
            if (row_index < 0 || row_index >= CONV3_RESULT_ROWS ||
                value !== expected_conv3_rows[row_index])
              $fatal(1, "Conv3 mismatch row=%0d got=%016h", row_index,
                     value);
            if (conv3_row_seen[row_index])
              $fatal(1, "duplicate Conv3 row=%0d", row_index);
            conv3_row_seen[row_index] = 1;
          end
          4: begin
            if (row_index < 0 || row_index >= CONV4_RESULT_ROWS ||
                value !== expected_conv4_rows[row_index])
              $fatal(1, "Conv4 mismatch row=%0d got=%016h", row_index,
                     value);
            if (conv4_row_seen[row_index])
              $fatal(1, "duplicate Conv4 row=%0d", row_index);
            conv4_row_seen[row_index] = 1;
          end
          5: begin
            if (row_index < 0 || row_index >= CONV5_RESULT_ROWS ||
                value !== expected_conv5_rows[row_index])
              $fatal(1, "Conv5 mismatch row=%0d got=%016h", row_index,
                     value);
            if (conv5_row_seen[row_index])
              $fatal(1, "duplicate Conv5 row=%0d", row_index);
            conv5_row_seen[row_index] = 1;
          end
          6: begin
            if (row_index < 0 || row_index >= FC6_RESULT_ROWS ||
                value !== expected_fc6_rows[row_index])
              $fatal(1, "FC6 mismatch row=%0d got=%016h", row_index,
                     value);
            if (fc6_row_seen[row_index])
              $fatal(1, "duplicate FC6 row=%0d", row_index);
            fc6_row_seen[row_index] = 1;
          end
          7: begin
            if (row_index < 0 || row_index >= FC7_RESULT_ROWS ||
                value !== expected_fc7_rows[row_index])
              $fatal(1, "FC7 mismatch row=%0d got=%016h", row_index,
                     value);
            if (fc7_row_seen[row_index])
              $fatal(1, "duplicate FC7 row=%0d", row_index);
            fc7_row_seen[row_index] = 1;
          end
          8: begin
            if (row_index < 0 || row_index >= FC8_RESULT_ROWS ||
                value !== expected_fc8_rows[row_index])
              $fatal(1, "FC8 mismatch row=%0d got=%016h", row_index,
                     value);
            if (fc8_row_seen[row_index])
              $fatal(1, "duplicate FC8 row=%0d", row_index);
            fc8_row_seen[row_index] = 1;
          end
          default: $fatal(1, "unexpected result layer=%0d", layer_id);
        endcase
      end
    end
  endtask

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
    else if (full_graph &&
             ((main_mm2s_address >= ACT_A_BASE &&
               main_mm2s_address < ACT_A_BASE + ACT_MEMORY_BYTES) ||
              (main_mm2s_address >= ACT_B_BASE &&
               main_mm2s_address < ACT_B_BASE + ACT_MEMORY_BYTES))) begin
      for (int lane = 0; lane < 16; lane++)
        s_axis_mm2s_tdata[lane*8 +: 8] = activation_byte(
            main_mm2s_address + main_mm2s_index * 16 + lane);
    end
    if (full_graph && s_axis_mm2s_tlast && main_mm2s_bytes[3:0] != 0)
      s_axis_mm2s_tkeep = (17'h1 << main_mm2s_bytes[3:0]) - 1'b1;

    s_axis_weight_tdata = full_graph ? weight_file_word_q :
        weight_mm2s_address == WEIGHT_BASE &&
                         weight_transfer_index < WEIGHT_BEATS ?
        weight_memory[weight_transfer_index] :
        weight_mm2s_address >= PARAMETER_BASE &&
        weight_mm2s_address < PARAMETER_BASE + 64 * 16 &&
        ((weight_mm2s_address - PARAMETER_BASE) >> 4) +
            weight_transfer_index < CONV1_PARAMETER_BEATS ?
        parameter_memory[((weight_mm2s_address - PARAMETER_BASE) >> 4) +
                         weight_transfer_index] :
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
    int result_row_index;
    int active_result_layer;
    bit pooled_result;
    logic [15:0] expected_keep;
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
      main_mm2s_bytes = 0;
      main_mm2s_index = 0;
      main_completed_mm2s = 0;
      main_s2mm_active = 0;
      main_s2mm_done = 0;
      main_s2mm_beats = 0;
      main_s2mm_bytes = 0;
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
        if (!full_conv1 && !full_graph)
          $display("TRAINED_TOP_MAIN_DMA_WRITE address=%08h data=%08h",
                   committed_address, committed_data);
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
            main_mm2s_bytes = committed_data;
            main_mm2s_beats = (committed_data + 15) / 16;
            if ((!full_graph &&
                 !(main_mm2s_address == INPUT_BASE &&
                   committed_data == 401408)) ||
                (full_graph &&
                 !((main_mm2s_address == INPUT_BASE &&
                    committed_data == 401408) ||
                   (main_mm2s_address >= ACT_A_BASE &&
                    main_mm2s_address + committed_data <=
                        ACT_A_BASE + ACT_MEMORY_BYTES) ||
                   (main_mm2s_address >= ACT_B_BASE &&
                    main_mm2s_address + committed_data <=
                        ACT_B_BASE + ACT_MEMORY_BYTES))))
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
            main_s2mm_bytes = committed_data;
            main_s2mm_beats = (committed_data + 15) / 16;
            if ((!full_conv1 && !full_graph &&
                 (main_s2mm_address != ACT_A_BASE ||
                  committed_data != 64)) ||
                (full_conv1 && !full_graph &&
                 (main_s2mm_address < ACT_A_BASE ||
                  main_s2mm_address + committed_data >
                      ACT_A_BASE + 193600 ||
                  main_s2mm_address[2:0] != 0 ||
                  (committed_data != 64 && committed_data != 8))) ||
                (full_graph &&
                 !((main_s2mm_address >= ACT_A_BASE &&
                    main_s2mm_address + committed_data <=
                        ACT_A_BASE + ACT_MEMORY_BYTES) ||
                   (main_s2mm_address >= ACT_B_BASE &&
                    main_s2mm_address + committed_data <=
                        ACT_B_BASE + ACT_MEMORY_BYTES) ||
                   (main_s2mm_address >= OUTPUT_BASE &&
                    main_s2mm_address + committed_data <=
                        OUTPUT_BASE + FINAL_OUTPUT_BYTES))))
              $fatal(1,
                     "unexpected S2MM address=%h bytes=%0d",
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
        expected_keep = 16'hffff;
        if (main_s2mm_index + 1 == main_s2mm_beats &&
            main_s2mm_bytes[3:0] != 0)
          expected_keep = (17'h1 << main_s2mm_bytes[3:0]) - 1'b1;
        if (full_graph) begin
          if (main_s2mm_address >= ACT_A_BASE &&
              main_s2mm_address < ACT_A_BASE + ACT_MEMORY_BYTES)
            result_row_index = ((main_s2mm_address - ACT_A_BASE) >> 3) +
                               2 * main_s2mm_index;
          else if (main_s2mm_address >= ACT_B_BASE &&
                   main_s2mm_address < ACT_B_BASE + ACT_MEMORY_BYTES)
            result_row_index = ((main_s2mm_address - ACT_B_BASE) >> 3) +
                               2 * main_s2mm_index;
          else
            result_row_index = ((main_s2mm_address - OUTPUT_BASE) >> 3) +
                               2 * main_s2mm_index;
          pooled_result = dut.pool_busy;
          active_result_layer = pooled_result ?
              dut.engine_layer_complete_id : dut.engine_active_layer_id;
          if (expected_keep[7:0] == 8'hff)
            check_full_graph_row(active_result_layer, pooled_result,
                                 result_row_index,
                                 m_axis_s2mm_tdata[63:0]);
          if (expected_keep[15:8] == 8'hff)
            check_full_graph_row(active_result_layer, pooled_result,
                                 result_row_index + 1,
                                 m_axis_s2mm_tdata[127:64]);
          for (int lane = 0; lane < 16; lane++) begin
            if (m_axis_s2mm_tkeep[lane])
              write_ddr_byte(main_s2mm_address + main_s2mm_index * 16 + lane,
                             m_axis_s2mm_tdata[lane*8 +: 8]);
          end
        end else begin
          result_row_index = ((main_s2mm_address - ACT_A_BASE) >> 3) +
                             2 * main_s2mm_index;
          if (result_row_index >= CONV1_RESULT_ROWS ||
              m_axis_s2mm_tdata[63:0] !==
                  expected_result_rows[result_row_index])
            $fatal(1,
                   "trained top result mismatch address=%h row=%0d got=%016h expected=%016h",
                   main_s2mm_address, result_row_index,
                   m_axis_s2mm_tdata[63:0],
                   expected_result_rows[result_row_index]);
          if (full_conv1 && result_row_seen[result_row_index])
            $fatal(1, "duplicate Conv1 result row=%0d address=%h",
                   result_row_index, main_s2mm_address);
          result_row_seen[result_row_index] = 1;
          if (expected_keep == 16'hffff) begin
            if (result_row_index + 1 >= CONV1_RESULT_ROWS ||
                m_axis_s2mm_tdata[127:64] !==
                    expected_result_rows[result_row_index+1])
              $fatal(1,
                     "trained top upper result mismatch address=%h row=%0d got=%016h expected=%016h",
                     main_s2mm_address, result_row_index + 1,
                     m_axis_s2mm_tdata[127:64],
                     expected_result_rows[result_row_index+1]);
            if (full_conv1 && result_row_seen[result_row_index+1])
              $fatal(1, "duplicate Conv1 result row=%0d address=%h",
                     result_row_index + 1, main_s2mm_address);
            result_row_seen[result_row_index+1] = 1;
          end
        end
        if (m_axis_s2mm_tkeep != expected_keep ||
            m_axis_s2mm_tlast !=
                (main_s2mm_index + 1 == main_s2mm_beats))
          $fatal(1,
                 "trained top result framing mismatch beat=%0d keep=%h expected_keep=%h last=%0b",
                 main_s2mm_index, m_axis_s2mm_tkeep, expected_keep,
                 m_axis_s2mm_tlast);
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
    integer seek_status;
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
      weight_payload_bytes = 0;
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
        if (!full_conv1 && !full_graph)
          $display("TRAINED_TOP_WEIGHT_DMA_WRITE address=%08h data=%08h",
                   committed_address, committed_data);
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
            if ((!full_graph && !((weight_mm2s_address == WEIGHT_BASE &&
                   committed_data == 4 * 363 * 16) ||
                  (weight_mm2s_address >= PARAMETER_BASE &&
                   weight_mm2s_address + committed_data <=
                       PARAMETER_BASE + 64 * 16 &&
                   weight_mm2s_address[3:0] == 0 &&
                   committed_data == 128))) ||
                (full_graph &&
                 !((weight_mm2s_address >= WEIGHT_BASE &&
                    weight_mm2s_address + committed_data <=
                        WEIGHT_BASE + WEIGHT_IMAGE_BYTES) ||
                   (weight_mm2s_address >= PARAMETER_BASE &&
                    weight_mm2s_address + committed_data <=
                        PARAMETER_BASE + PARAMETER_IMAGE_BYTES))))
              $fatal(1,
                     "unexpected weight/parameter DMA address=%h bytes=%0d",
                     weight_mm2s_address, committed_data);
            if (full_graph) begin
              if (committed_data == 0 || committed_data[3:0] != 0)
                $fatal(1, "binary DMA transfer is not AXIS128 aligned bytes=%0d",
                       committed_data);
              if (weight_mm2s_address >= WEIGHT_BASE &&
                  weight_mm2s_address < WEIGHT_BASE + WEIGHT_IMAGE_BYTES) begin
                seek_status = $fseek(weight_file,
                                     weight_mm2s_address - WEIGHT_BASE, 0);
                weight_payload_bytes += committed_data;
                if (seek_status != 0)
                  $fatal(1, "weight binary seek failed offset=%0d",
                         weight_mm2s_address - WEIGHT_BASE);
                read_binary_word(weight_file, weight_file_word_q);
              end else begin
                seek_status = $fseek(parameter_file,
                                     weight_mm2s_address - PARAMETER_BASE, 0);
                if (seek_status != 0)
                  $fatal(1, "parameter binary seek failed offset=%0d",
                         weight_mm2s_address - PARAMETER_BASE);
                read_binary_word(parameter_file, weight_file_word_q);
              end
            end
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
          if (full_graph) begin
            if (weight_mm2s_address >= WEIGHT_BASE &&
                weight_mm2s_address < WEIGHT_BASE + WEIGHT_IMAGE_BYTES)
              read_binary_word(weight_file, weight_file_word_q);
            else
              read_binary_word(parameter_file, weight_file_word_q);
          end
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
    int timeout_limit;
    full_conv1 = $test$plusargs("FULL_CONV1");
    full_graph = $test$plusargs("FULL_GRAPH");
    if (!$value$plusargs("VECTOR_ROOT=%s", vector_root))
      $fatal(1, "VECTOR_ROOT plusarg is required");
    if (full_graph && !$value$plusargs("BOARD_ROOT=%s", board_root))
      $fatal(1, "BOARD_ROOT plusarg is required for FULL_GRAPH");
    for (int beat = 0; beat < CONV1_PARAMETER_BEATS; beat++)
      parameter_memory[beat] = 0;
    for (int row = 0; row < CONV1_RESULT_ROWS; row++) begin
      expected_result_rows[row] = 0;
      result_row_seen[row] = 0;
    end
    for (int index = 0; index < ACT_MEMORY_BYTES; index++) begin
      activation_a_memory[index] = 0;
      activation_b_memory[index] = 0;
    end
    for (int index = 0; index < FINAL_OUTPUT_BYTES; index++)
      final_output_memory[index] = 0;
    for (int row = 0; row < POOL1_RESULT_ROWS; row++)
      pool1_row_seen[row] = 0;
    for (int row = 0; row < CONV2_RESULT_ROWS; row++)
      conv2_row_seen[row] = 0;
    for (int row = 0; row < POOL2_RESULT_ROWS; row++)
      pool2_row_seen[row] = 0;
    for (int row = 0; row < CONV3_RESULT_ROWS; row++)
      conv3_row_seen[row] = 0;
    for (int row = 0; row < CONV4_RESULT_ROWS; row++)
      conv4_row_seen[row] = 0;
    for (int row = 0; row < CONV5_RESULT_ROWS; row++)
      conv5_row_seen[row] = 0;
    for (int row = 0; row < POOL5_RESULT_ROWS; row++)
      pool5_row_seen[row] = 0;
    for (int row = 0; row < FC6_RESULT_ROWS; row++)
      fc6_row_seen[row] = 0;
    for (int row = 0; row < FC7_RESULT_ROWS; row++)
      fc7_row_seen[row] = 0;
    for (int row = 0; row < FC8_RESULT_ROWS; row++)
      fc8_row_seen[row] = 0;

    path = full_graph ?
        $sformatf("%s/top_conv1_full/input_axis128.mem", vector_root) :
        $sformatf("%s/input_axis128.mem", vector_root);
    $readmemh(path, input_memory);
    if (full_graph) begin
      path = $sformatf("%s/full_graph_axis64/conv1.mem", vector_root);
      $readmemh(path, expected_result_rows);
      path = $sformatf("%s/full_graph_axis64/pool1.mem", vector_root);
      $readmemh(path, expected_pool1_rows);
      path = $sformatf("%s/full_graph_axis64/conv2.mem", vector_root);
      $readmemh(path, expected_conv2_rows);
      path = $sformatf("%s/full_graph_axis64/pool2.mem", vector_root);
      $readmemh(path, expected_pool2_rows);
      path = $sformatf("%s/full_graph_axis64/conv3.mem", vector_root);
      $readmemh(path, expected_conv3_rows);
      path = $sformatf("%s/full_graph_axis64/conv4.mem", vector_root);
      $readmemh(path, expected_conv4_rows);
      path = $sformatf("%s/full_graph_axis64/conv5.mem", vector_root);
      $readmemh(path, expected_conv5_rows);
      path = $sformatf("%s/full_graph_axis64/pool5.mem", vector_root);
      $readmemh(path, expected_pool5_rows);
      path = $sformatf("%s/full_graph_axis64/fc6.mem", vector_root);
      $readmemh(path, expected_fc6_rows);
      path = $sformatf("%s/full_graph_axis64/fc7.mem", vector_root);
      $readmemh(path, expected_fc7_rows);
      path = $sformatf("%s/full_graph_axis64/fc8.mem", vector_root);
      $readmemh(path, expected_fc8_rows);
      path = $sformatf("%s/weights_board.bin", board_root);
      weight_file = $fopen(path, "rb");
      path = $sformatf("%s/parameters_board.bin", board_root);
      parameter_file = $fopen(path, "rb");
      if (weight_file == 0 || parameter_file == 0)
        $fatal(1, "cannot open full-graph board DMA images");
    end else begin
      path = $sformatf("%s/weight_axis128.mem", vector_root);
      $readmemh(path, weight_memory);
      path = $sformatf("%s/parameter_axis128.mem", vector_root);
      $readmemh(path, parameter_memory);
      path = $sformatf("%s/expected_result_axis64.mem", vector_root);
      $readmemh(path, expected_result_rows);
    end

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

    // The full graph intentionally exercises every production DMA transfer
    // and all 4.49 M issue cycles.  Conv1-Conv3 alone consume about 15 M
    // clock cycles, so the former 15 M guard was only a partial-graph limit.
    timeout_limit = full_graph ? 300_000_000 :
                    full_conv1 ? 2_000_000 : 500_000;
    if (full_graph &&
        $value$plusargs("FULL_GRAPH_TIMEOUT=%d", timeout_limit))
      $display("FULL_GRAPH_TIMEOUT_OVERRIDE cycles=%0d", timeout_limit);
    for (int timeout = 0; timeout < timeout_limit; timeout++) begin
      @(negedge clk);
      if (accelerator_fault)
        $fatal(1,
               "trained graph top fault state=%0d layer=%0d main=%0d weight=%0d service=%0b engine_fault=%0b failed=%0b main_error=%0b weight_error=%0b loader=%0b raster=%0b pool=%0b activation=%0b mapping=%0b completed=%0d s2mm=%0d slices=%0d result_index=%0d pending_m=%0d engine_m=%0d n=%0d payload_state=%0d",
               dut.main_state_q, dut.engine_active_layer_id,
               {dut.unused_main_s2mm_state, dut.unused_main_mm2s_state},
               dut.unused_weight_dma_state, dut.service_fault_q,
               dut.engine_fault, dut.engine_failed, dut.main_dma_error,
               dut.weight_dma_error, dut.loader_fault, dut.raster_fault,
               dut.pool_layer_error, dut.activation_fault,
               dut.result_mapping_error, dut.engine_completed_commands,
               main_completed_s2mm, dut.completed_result_slices,
               dut.result_slice_index_q, dut.pending_result_m_base_q,
               dut.engine_result_m_base, dut.engine_result_n_base,
               dut.u_graph_payload.state_q);
      if (!full_conv1 && !full_graph && main_completed_s2mm == 1) begin
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
      if (full_conv1 && !full_graph &&
          dut.engine_completed_commands == CONV1_COMMANDS) begin
        if (main_completed_mm2s != 1 ||
            main_completed_s2mm != CONV1_RESULT_TRANSFERS ||
            weight_completed_transfers != CONV1_RESULT_TRANSFERS + 1 ||
            dut.engine_issue_cycles != CONV1_ISSUES ||
            dut.completed_result_slices != CONV1_RESULT_TRANSFERS)
          $fatal(1,
                 "full Conv1 accounting mm2s=%0d s2mm=%0d weight=%0d commands=%0d issues=%0d slices=%0d",
                 main_completed_mm2s, main_completed_s2mm,
                 weight_completed_transfers,
                 dut.engine_completed_commands, dut.engine_issue_cycles,
                 dut.completed_result_slices);
        for (int row = 0; row < CONV1_RESULT_ROWS; row++) begin
          if (!result_row_seen[row])
            $fatal(1, "full Conv1 missing result row=%0d", row);
        end
        $display("ALEXNET_M8N126_GRAPH_TOP_TRAINED_CONV1_FULL_PASS commands=%0d issues=%0d s2mm=%0d result_bytes=193600",
                 dut.engine_completed_commands, dut.engine_issue_cycles,
                 main_completed_s2mm);
        $finish;
      end
      if (full_graph && dut.engine_done) begin
        if (dut.engine_completed_commands != FULL_GRAPH_COMMANDS ||
            dut.engine_issue_cycles != FULL_GRAPH_ISSUES ||
            dut.useful_mac_count != 64'd714188480 ||
            dut.physical_mac_slot_count != 64'd4595623936 ||
            weight_payload_bytes != WEIGHT_IMAGE_BYTES ||
            dut.weight_byte_offset_q != WEIGHT_IMAGE_BYTES)
          $fatal(1,
                 "full graph accounting commands=%0d issues=%0d useful=%0d slots=%0d weight_bytes=%0d offset=%0d",
                 dut.engine_completed_commands, dut.engine_issue_cycles,
                 dut.useful_mac_count, dut.physical_mac_slot_count,
                 weight_payload_bytes, dut.weight_byte_offset_q);
        for (int row = 0; row < CONV1_RESULT_ROWS; row++)
          if (!result_row_seen[row])
            $fatal(1, "full graph missing Conv1 row=%0d", row);
        for (int row = 0; row < POOL1_RESULT_ROWS; row++)
          if (!pool1_row_seen[row])
            $fatal(1, "full graph missing Pool1 row=%0d", row);
        for (int row = 0; row < CONV2_RESULT_ROWS; row++)
          if (!conv2_row_seen[row])
            $fatal(1, "full graph missing Conv2 row=%0d", row);
        for (int row = 0; row < POOL2_RESULT_ROWS; row++)
          if (!pool2_row_seen[row])
            $fatal(1, "full graph missing Pool2 row=%0d", row);
        for (int row = 0; row < CONV3_RESULT_ROWS; row++)
          if (!conv3_row_seen[row])
            $fatal(1, "full graph missing Conv3 row=%0d", row);
        for (int row = 0; row < CONV4_RESULT_ROWS; row++)
          if (!conv4_row_seen[row])
            $fatal(1, "full graph missing Conv4 row=%0d", row);
        for (int row = 0; row < CONV5_RESULT_ROWS; row++)
          if (!conv5_row_seen[row])
            $fatal(1, "full graph missing Conv5 row=%0d", row);
        for (int row = 0; row < POOL5_RESULT_ROWS; row++)
          if (!pool5_row_seen[row])
            $fatal(1, "full graph missing Pool5 row=%0d", row);
        for (int row = 0; row < FC6_RESULT_ROWS; row++)
          if (!fc6_row_seen[row])
            $fatal(1, "full graph missing FC6 row=%0d", row);
        for (int row = 0; row < FC7_RESULT_ROWS; row++)
          if (!fc7_row_seen[row])
            $fatal(1, "full graph missing FC7 row=%0d", row);
        for (int row = 0; row < FC8_RESULT_ROWS; row++)
          if (!fc8_row_seen[row])
            $fatal(1, "full graph missing FC8 row=%0d", row);
        $display("ALEXNET_M8N126_GRAPH_TOP_TRAINED_FULL_GRAPH_PASS commands=%0d issues=%0d weight_bytes=%0d",
                 dut.engine_completed_commands, dut.engine_issue_cycles,
                 weight_payload_bytes);
        $fclose(weight_file);
        $fclose(parameter_file);
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
