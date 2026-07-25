`timescale 1ns/1ps

module tb_lenet5_axis_wrapper;
  localparam int AXIS_W = 128;
  localparam int AXIS_BYTES = 16;
  localparam int WEIGHT_ROWS = 1449;
  localparam int PARAM_RECORDS = 236;
  localparam int INPUT_WORDS = 512;
  localparam logic [31:0] DMA_BASE = 32'ha001_0000;

  logic clk;
  logic rst_n;
  logic [7:0] s_axi_awaddr;
  logic s_axi_awvalid;
  logic s_axi_awready;
  logic [31:0] s_axi_wdata;
  logic [3:0] s_axi_wstrb;
  logic s_axi_wvalid;
  logic s_axi_wready;
  logic [1:0] s_axi_bresp;
  logic s_axi_bvalid;
  logic s_axi_bready;
  logic [7:0] s_axi_araddr;
  logic s_axi_arvalid;
  logic s_axi_arready;
  logic [31:0] s_axi_rdata;
  logic [1:0] s_axi_rresp;
  logic s_axi_rvalid;
  logic s_axi_rready;
  logic [31:0] m_axi_dma_awaddr;
  logic [2:0] m_axi_dma_awprot;
  logic m_axi_dma_awvalid;
  logic m_axi_dma_awready;
  logic [31:0] m_axi_dma_wdata;
  logic [3:0] m_axi_dma_wstrb;
  logic m_axi_dma_wvalid;
  logic m_axi_dma_wready;
  logic [1:0] m_axi_dma_bresp;
  logic m_axi_dma_bvalid;
  logic m_axi_dma_bready;
  logic [31:0] m_axi_dma_araddr;
  logic [2:0] m_axi_dma_arprot;
  logic m_axi_dma_arvalid;
  logic m_axi_dma_arready;
  logic [31:0] m_axi_dma_rdata;
  logic [1:0] m_axi_dma_rresp;
  logic m_axi_dma_rvalid;
  logic m_axi_dma_rready;
  logic [AXIS_W-1:0] s_axis_tdata;
  logic [AXIS_BYTES-1:0] s_axis_tkeep;
  logic s_axis_tvalid;
  logic s_axis_tready;
  logic s_axis_tlast;
  logic [AXIS_W-1:0] m_axis_tdata;
  logic [AXIS_BYTES-1:0] m_axis_tkeep;
  logic m_axis_tvalid;
  logic m_axis_tready;
  logic m_axis_tlast;
  logic irq;

  int seed;
  int random_stalls;
  int netlist_smoke;
  int plusarg_status;
  int random_seed_value;
  int cycle_count;
  logic dma_aw_seen_r;
  logic [31:0] dma_awaddr_r;
  logic dma_w_seen_r;
  logic [31:0] dma_wdata_r;
  logic [31:0] dma_mm2s_buffer_r;
  logic [31:0] dma_s2mm_buffer_r;
  logic [31:0] dma_mm2s_status_r;
  logic [31:0] dma_s2mm_status_r;
  logic dma_mm2s_launch_r;
  logic [31:0] dma_mm2s_launch_addr_r;
  logic [31:0] dma_mm2s_launch_length_r;
  logic dma_aw_hs_c;
  logic dma_w_hs_c;
  logic dma_write_commit_c;
  logic [31:0] dma_write_addr_c;
  logic [31:0] dma_write_data_c;
  int dma_mm2s_transfer_count;
  int dma_s2mm_transfer_count;
  logic [127:0] dma_last_result_r;
  logic [15:0] dma_last_result_keep_r;

  import "DPI-C" function int wrapper_param_bias(input int address);
  import "DPI-C" function int wrapper_param_scale(input int address);
  import "DPI-C" function int wrapper_expected_logit(input int index);
  import "DPI-C" function int wrapper_expected_counter(input int select);

  lenet5_axis_wrapper dut (.*);

  assign m_axi_dma_awready = 1'b1;
  assign m_axi_dma_wready = 1'b1;
  assign m_axi_dma_arready = !m_axi_dma_rvalid;
  assign dma_aw_hs_c = m_axi_dma_awvalid && m_axi_dma_awready;
  assign dma_w_hs_c = m_axi_dma_wvalid && m_axi_dma_wready;
  assign dma_write_commit_c =
      !m_axi_dma_bvalid &&
      (dma_aw_seen_r || dma_aw_hs_c) &&
      (dma_w_seen_r || dma_w_hs_c);
  assign dma_write_addr_c =
      dma_aw_hs_c ? m_axi_dma_awaddr : dma_awaddr_r;
  assign dma_write_data_c =
      dma_w_hs_c ? m_axi_dma_wdata : dma_wdata_r;

  // Match the implemented PL clock: 200 MHz.
  always #2.5 clk = ~clk;

  always @(posedge clk) begin
    if (!rst_n)
      cycle_count <= 0;
    else
      cycle_count <= cycle_count + 1;
  end

  always @(posedge clk) begin
    if (netlist_smoke && rst_n && ((cycle_count % 25) == 0))
      $display(
          "WRAPPER NETLIST PROGRESS cycle=%0d arvalid=%0d arready=%0d rvalid=%0d irq=%0d",
          cycle_count, s_axi_arvalid, s_axi_arready, s_axi_rvalid, irq);
  end

  task automatic send_aw(input logic [7:0] address, input int delay_cycles);
    begin
      repeat (delay_cycles) @(negedge clk);
      s_axi_awaddr = address;
      s_axi_awvalid = 1'b1;
      do @(posedge clk); while (!s_axi_awready);
      @(negedge clk);
      s_axi_awvalid = 1'b0;
    end
  endtask

  task automatic send_w(
      input logic [31:0] data,
      input logic [3:0] strobe,
      input int delay_cycles);
    begin
      repeat (delay_cycles) @(negedge clk);
      s_axi_wdata = data;
      s_axi_wstrb = strobe;
      s_axi_wvalid = 1'b1;
      do @(posedge clk); while (!s_axi_wready);
      @(negedge clk);
      s_axi_wvalid = 1'b0;
    end
  endtask

  task automatic axi_write(
      input logic [7:0] address,
      input logic [31:0] data);
    int ordering;
    int response_stalls;
    begin
      ordering = random_stalls ? $urandom_range(0, 2) : 0;
      response_stalls = random_stalls ? $urandom_range(0, 3) : 0;
      s_axi_bready = 1'b0;
      fork
        send_aw(address, (ordering == 1) ? 2 : 0);
        send_w(data, 4'hf, (ordering == 2) ? 2 : 0);
      join
      while (!s_axi_bvalid) @(negedge clk);
      repeat (response_stalls) begin
        logic [1:0] held_resp;
        held_resp = s_axi_bresp;
        @(negedge clk);
        if (!s_axi_bvalid || (s_axi_bresp !== held_resp))
          $fatal(1, "WRAPPER B channel unstable cycle=%0d", cycle_count);
      end
      if (s_axi_bresp != 2'b00)
        $fatal(1, "WRAPPER write addr=%02h resp=%0h",
               address, s_axi_bresp);
      s_axi_bready = 1'b1;
      @(posedge clk);
      @(negedge clk);
      s_axi_bready = 1'b0;
    end
  endtask

  task automatic axi_read(
      input logic [7:0] address,
      output logic [31:0] data);
    int response_stalls;
    begin
      response_stalls = random_stalls ? $urandom_range(0, 3) : 0;
      s_axi_rready = 1'b0;
      @(negedge clk);
      s_axi_araddr = address;
      s_axi_arvalid = 1'b1;
      do @(posedge clk); while (!s_axi_arready);
      @(negedge clk);
      s_axi_arvalid = 1'b0;
      while (!s_axi_rvalid) @(negedge clk);
      repeat (response_stalls) begin
        logic [31:0] held_data;
        held_data = s_axi_rdata;
        @(negedge clk);
        if (!s_axi_rvalid || (s_axi_rdata !== held_data))
          $fatal(1, "WRAPPER R channel unstable cycle=%0d", cycle_count);
      end
      if (s_axi_rresp != 2'b00)
        $fatal(1, "WRAPPER read addr=%02h resp=%0h",
               address, s_axi_rresp);
      data = s_axi_rdata;
      s_axi_rready = 1'b1;
      @(posedge clk);
      @(negedge clk);
      s_axi_rready = 1'b0;
    end
  endtask

  task automatic axis_send(
      input logic [127:0] data,
      input logic [15:0] keep,
      input logic last);
    int gap;
    begin
      gap = random_stalls ? $urandom_range(0, 2) : 0;
      repeat (gap) @(negedge clk);
      s_axis_tdata = data;
      s_axis_tkeep = keep;
      s_axis_tlast = last;
      s_axis_tvalid = 1'b1;
      do @(posedge clk); while (!s_axis_tready);
      @(negedge clk);
      s_axis_tvalid = 1'b0;
    end
  endtask

  function automatic logic [63:0] param_record(input int address);
    logic [63:0] value;
    begin
      value = '0;
      value[31:0] = 32'(wrapper_param_bias(address));
      value[49:32] = 18'(wrapper_param_scale(address));
      return value;
    end
  endfunction

  task automatic drive_dma_mm2s(
      input logic [31:0] buffer_address,
      input logic [31:0] length_bytes);
    logic [127:0] beat_data;
    begin
      if ((buffer_address == 32'h1000_0000) &&
          (length_bytes == 32'd92736)) begin
        for (int beat = 0; beat < 4 * WEIGHT_ROWS; beat++)
          axis_send('0, 16'hffff, beat == (4 * WEIGHT_ROWS - 1));
      end else if ((buffer_address == 32'h1002_0000) &&
                   (length_bytes == 32'd1888)) begin
        for (int beat = 0; beat < PARAM_RECORDS / 2; beat++) begin
          beat_data[63:0] = param_record(2 * beat);
          beat_data[127:64] = param_record(2 * beat + 1);
          axis_send(beat_data, 16'hffff,
                    beat == (PARAM_RECORDS / 2 - 1));
        end
      end else if (((buffer_address == 32'h1003_0000) ||
                    (buffer_address == 32'h1005_0000)) &&
                   (length_bytes == 32'd1024)) begin
        for (int beat = 0; beat < INPUT_WORDS / 8; beat++)
          axis_send('0, 16'hffff, beat == (INPUT_WORDS / 8 - 1));
      end else begin
        $fatal(1,
            "DMA MM2S unexpected buffer=%08h length=%0d",
            buffer_address, length_bytes);
      end
    end
  endtask

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      dma_aw_seen_r <= 1'b0;
      dma_awaddr_r <= '0;
      dma_w_seen_r <= 1'b0;
      dma_wdata_r <= '0;
      m_axi_dma_bresp <= 2'b00;
      m_axi_dma_bvalid <= 1'b0;
      m_axi_dma_rdata <= '0;
      m_axi_dma_rresp <= 2'b00;
      m_axi_dma_rvalid <= 1'b0;
      dma_mm2s_buffer_r <= '0;
      dma_s2mm_buffer_r <= '0;
      dma_mm2s_status_r <= '0;
      dma_s2mm_status_r <= '0;
      dma_mm2s_launch_r <= 1'b0;
      dma_mm2s_launch_addr_r <= '0;
      dma_mm2s_launch_length_r <= '0;
      dma_mm2s_transfer_count <= 0;
      dma_s2mm_transfer_count <= 0;
      dma_last_result_r <= '0;
      dma_last_result_keep_r <= '0;
    end else begin
      dma_mm2s_launch_r <= 1'b0;

      if (dma_aw_hs_c) begin
        dma_aw_seen_r <= 1'b1;
        dma_awaddr_r <= m_axi_dma_awaddr;
      end
      if (dma_w_hs_c) begin
        dma_w_seen_r <= 1'b1;
        dma_wdata_r <= m_axi_dma_wdata;
      end

      if (dma_write_commit_c) begin
        dma_aw_seen_r <= 1'b0;
        dma_w_seen_r <= 1'b0;
        m_axi_dma_bresp <= 2'b00;
        m_axi_dma_bvalid <= 1'b1;
        unique case (dma_write_addr_c)
          DMA_BASE + 32'h04:
            dma_mm2s_status_r <=
                dma_mm2s_status_r & ~dma_write_data_c;
          DMA_BASE + 32'h18:
            dma_mm2s_buffer_r <= dma_write_data_c;
          DMA_BASE + 32'h28: begin
            dma_mm2s_status_r[12] <= 1'b1;
            dma_mm2s_launch_r <= 1'b1;
            dma_mm2s_launch_addr_r <= dma_mm2s_buffer_r;
            dma_mm2s_launch_length_r <= dma_write_data_c;
            dma_mm2s_transfer_count <=
                dma_mm2s_transfer_count + 1;
          end
          DMA_BASE + 32'h34:
            dma_s2mm_status_r <=
                dma_s2mm_status_r & ~dma_write_data_c;
          DMA_BASE + 32'h48:
            dma_s2mm_buffer_r <= dma_write_data_c;
          DMA_BASE + 32'h58: begin
            if (dma_s2mm_buffer_r != 32'h1004_0000)
              $fatal(1, "DMA S2MM unexpected buffer=%08h",
                     dma_s2mm_buffer_r);
            if (dma_write_data_c != 32'd10)
              $fatal(1, "DMA S2MM unexpected length=%0d",
                     dma_write_data_c);
            dma_s2mm_transfer_count <=
                dma_s2mm_transfer_count + 1;
          end
          default: begin
          end
        endcase
      end else if (m_axi_dma_bvalid && m_axi_dma_bready) begin
        m_axi_dma_bvalid <= 1'b0;
      end

      if (m_axi_dma_arvalid && m_axi_dma_arready) begin
        m_axi_dma_rresp <= 2'b00;
        m_axi_dma_rvalid <= 1'b1;
        unique case (m_axi_dma_araddr)
          DMA_BASE + 32'h04:
            m_axi_dma_rdata <= dma_mm2s_status_r;
          DMA_BASE + 32'h34:
            m_axi_dma_rdata <= dma_s2mm_status_r;
          default: begin
            m_axi_dma_rdata <= '0;
            m_axi_dma_rresp <= 2'b10;
          end
        endcase
      end else if (m_axi_dma_rvalid && m_axi_dma_rready) begin
        m_axi_dma_rvalid <= 1'b0;
      end

      if (m_axis_tvalid && m_axis_tready) begin
        dma_last_result_r <= m_axis_tdata;
        dma_last_result_keep_r <= m_axis_tkeep;
        dma_s2mm_status_r[12] <= 1'b1;
      end
    end
  end

  always @(posedge clk) begin
    if (dma_mm2s_launch_r)
      fork
        drive_dma_mm2s(
            dma_mm2s_launch_addr_r,
            dma_mm2s_launch_length_r);
      join_none
  end

  task automatic wait_status_bit(
      input int bit_index,
      input logic expected,
      input int timeout);
    logic [31:0] status;
    int guard;
    begin
      status = '0;
      guard = 0;
      while ((status[bit_index] !== expected) && guard < timeout) begin
        axi_read(8'h08, status);
        guard++;
      end
      if (status[bit_index] !== expected)
        $fatal(1,
            "WRAPPER status bit %0d did not become %0d status=%08h",
            bit_index, expected, status);
    end
  endtask

  task automatic clear_status;
    logic [31:0] status;
    begin
      axi_write(8'h04, 32'h0000_0008);
      repeat (2) @(negedge clk);
      axi_read(8'h08, status);
      if (status[18] || status[17] || status[6] ||
          status[5] || status[3] || status[1] || irq)
        $fatal(1, "WRAPPER clear failed status=%08h irq=%0d",
               status, irq);
    end
  endtask

  task automatic run_autonomous_job(
      input logic reload_model,
      input logic [31:0] input_address,
      input logic [31:0] job_id,
      input int expected_mm2s_transfers);
    logic [31:0] status;
    logic [31:0] value;
    int mm2s_before;
    int s2mm_before;
    begin
      mm2s_before = dma_mm2s_transfer_count;
      s2mm_before = dma_s2mm_transfer_count;
      axi_write(8'h30, {31'd0, reload_model});
      axi_write(8'h34, 32'h1000_0000);
      axi_write(8'h38, 32'h1002_0000);
      axi_write(8'h3c, input_address);
      axi_write(8'h40, 32'h1004_0000);
      axi_write(8'h44, 32'd100_000);
      axi_write(8'h48, job_id);
      m_axis_tready = 1'b1;
      axi_write(8'h04, 32'h0000_0010);
      wait_status_bit(17, 1'b1, 50000);
      axi_read(8'h08, status);
      if (status[18] || status[6] || status[16])
        $fatal(1, "AUTO job failed status=%08h", status);
      if (!irq)
        $fatal(1, "AUTO completion IRQ missing");
      axi_read(8'h50, value);
      if (value != 32'd0)
        $fatal(1, "AUTO error code=%08h", value);
      axi_read(8'h54, value);
      if (value != job_id)
        $fatal(1, "AUTO completed job=%08h expected=%08h",
               value, job_id);
      if ((dma_mm2s_transfer_count - mm2s_before) !=
          expected_mm2s_transfers)
        $fatal(1,
            "AUTO MM2S transfers=%0d expected=%0d",
            dma_mm2s_transfer_count - mm2s_before,
            expected_mm2s_transfers);
      if ((dma_s2mm_transfer_count - s2mm_before) != 1)
        $fatal(1, "AUTO S2MM transfer count mismatch");
      if (dma_last_result_keep_r != 16'h03ff)
        $fatal(1, "AUTO result keep=%04h",
               dma_last_result_keep_r);
      for (int index = 0; index < 10; index++) begin
        int got;
        int expected;
        got = $signed(dma_last_result_r[index*8 +: 8]);
        expected = wrapper_expected_logit(index);
        if (got != expected)
          $fatal(1,
              "AUTO logit index=%0d got=%0d expected=%0d",
              index, got, expected);
      end
      m_axis_tready = 1'b0;
      $display(
          "WRAPPER AUTO JOB PASSED id=%08h reload=%0d mm2s=%0d",
          job_id, reload_model, expected_mm2s_transfers);
    end
  endtask

  task automatic load_weights;
    begin
      axi_write(8'h0c, (WEIGHT_ROWS << 16) | 32'd0);
      axi_write(8'h10, 32'd0);
      axi_write(8'h04, 32'h0000_0002);
      for (int beat = 0; beat < 4 * WEIGHT_ROWS; beat++)
        axis_send('0, 16'hffff, beat == (4 * WEIGHT_ROWS - 1));
      wait_status_bit(3, 1'b1, 100);
      $display("WRAPPER WEIGHT LOAD PASSED cycle=%0d", cycle_count);
    end
  endtask

  task automatic load_params;
    logic [127:0] beat_data;
    begin
      clear_status();
      axi_write(8'h0c, (PARAM_RECORDS << 16) | 32'd1);
      axi_write(8'h10, 32'd0);
      axi_write(8'h04, 32'h0000_0002);
      for (int beat = 0; beat < PARAM_RECORDS / 2; beat++) begin
        beat_data[63:0] = param_record(2 * beat);
        beat_data[127:64] = param_record(2 * beat + 1);
        axis_send(beat_data, 16'hffff,
                  beat == (PARAM_RECORDS / 2 - 1));
      end
      wait_status_bit(3, 1'b1, 100);
      $display("WRAPPER PARAM LOAD PASSED cycle=%0d", cycle_count);
    end
  endtask

  task automatic load_input;
    logic [31:0] status;
    begin
      clear_status();
      // MODE_INPUT=2, bank=0, set=0: the first operation reads set 0.
      axi_write(8'h0c, (INPUT_WORDS << 16) | 32'd2);
      axi_write(8'h10, 32'd0);
      axi_write(8'h04, 32'h0000_0002);
      for (int beat = 0; beat < INPUT_WORDS / 8; beat++)
        axis_send('0, 16'hffff, beat == (INPUT_WORDS / 8 - 1));
      wait_status_bit(3, 1'b1, 100);
      axi_read(8'h08, status);
      if (!status[7] || !status[8] || status[6])
        $fatal(1,
            "WRAPPER model/input validity wrong status=%08h", status);
      $display("WRAPPER INPUT LOAD PASSED cycle=%0d", cycle_count);
    end
  endtask

  task automatic receive_result;
    logic [127:0] held_data;
    logic [15:0] held_keep;
    int sink_stalls;
    begin
      m_axis_tready = 1'b0;
      while (!m_axis_tvalid) @(negedge clk);
      held_data = m_axis_tdata;
      held_keep = m_axis_tkeep;
      sink_stalls = random_stalls ? $urandom_range(1, 8) : 0;
      repeat (sink_stalls) begin
        @(negedge clk);
        if (!m_axis_tvalid || (m_axis_tdata !== held_data) ||
            (m_axis_tkeep !== held_keep) || !m_axis_tlast)
          $fatal(1, "WRAPPER output changed under backpressure");
      end
      if ((m_axis_tkeep !== 16'h03ff) || !m_axis_tlast)
        $fatal(1, "WRAPPER result framing keep=%04h last=%0d",
               m_axis_tkeep, m_axis_tlast);
      for (int index = 0; index < 10; index++) begin
        int got;
        int expected;
        got = $signed(m_axis_tdata[index*8 +: 8]);
        expected = wrapper_expected_logit(index);
        if (got != expected)
          $fatal(1,
              "WRAPPER logit index=%0d got=%0d expected=%0d",
              index, got, expected);
      end
      m_axis_tready = 1'b1;
      @(posedge clk);
      @(negedge clk);
      m_axis_tready = 1'b0;
      $display("WRAPPER RESULT PACKET PASSED cycle=%0d", cycle_count);
    end
  endtask

  task automatic reset_dut;
    begin
      rst_n = 1'b0;
      s_axi_awaddr = 'x;
      s_axi_awvalid = 1'b0;
      s_axi_wdata = 'x;
      s_axi_wstrb = 'x;
      s_axi_wvalid = 1'b0;
      s_axi_bready = 1'b0;
      s_axi_araddr = 'x;
      s_axi_arvalid = 1'b0;
      s_axi_rready = 1'b0;
      s_axis_tdata = 'x;
      s_axis_tkeep = 'x;
      s_axis_tvalid = 1'b0;
      s_axis_tlast = 1'bx;
      m_axis_tready = 1'b0;
      if (netlist_smoke)
        repeat (30) @(negedge clk);
      else
        repeat (6) @(negedge clk);
      rst_n = 1'b1;
      repeat (3) @(negedge clk);
      if ($isunknown({s_axi_awready, s_axi_wready, s_axi_bresp,
                      s_axi_bvalid, s_axi_arready, s_axi_rdata,
                      s_axi_rresp, s_axi_rvalid, s_axis_tready,
                      m_axis_tdata, m_axis_tkeep, m_axis_tvalid,
                      m_axis_tlast, irq}))
        $fatal(1, "WRAPPER reset left unknown outputs");
    end
  endtask

  initial begin
    logic [31:0] value;
    logic [31:0] busy_value;
    logic [31:0] compute_value;
    logic [31:0] pool_value;
    logic [31:0] param_value;
    clk = 1'b0;
    seed = 20260725;
    random_stalls = 0;
    netlist_smoke = 0;
    plusarg_status = $value$plusargs("SEED=%d", seed);
    plusarg_status = $value$plusargs("RANDOM_STALLS=%d", random_stalls);
    plusarg_status = $value$plusargs("NETLIST_SMOKE=%d", netlist_smoke);
    random_seed_value = $urandom(seed);
    $display("WRAPPER seed=%0d random_stalls=%0d netlist_smoke=%0d",
             seed, random_stalls, netlist_smoke);

    reset_dut();
    axi_read(8'h00, value);
    if (value !== 32'h0002_4c35)
      $fatal(1, "WRAPPER ID mismatch %08h", value);

    if (netlist_smoke) begin
      logic [31:0] smoke_status;
      logic [31:0] smoke_error;

      // Keep post-route/SDF verification bounded: exercise the complete
      // CSR-to-scheduler error/IRQ path with an invalid descriptor. Full
      // inference equivalence is covered by the RTL+DPI-C runs above.
      axi_write(8'h30, 32'd0);
      axi_write(8'h34, 32'h1000_0000);
      axi_write(8'h38, 32'h1002_0000);
      axi_write(8'h3c, 32'h1003_0001);
      axi_write(8'h40, 32'h1004_0000);
      axi_write(8'h44, 32'd100);
      axi_write(8'h48, 32'h0000_1001);
      axi_write(8'h04, 32'h0000_0010);
      wait_status_bit(18, 1'b1, 100);
      axi_read(8'h08, smoke_status);
      axi_read(8'h50, smoke_error);
      if (!irq || smoke_status[16] || (smoke_error != 32'h1))
        $fatal(1,
            "WRAPPER netlist control smoke failed status=%08h error=%08h irq=%0d",
            smoke_status, smoke_error, irq);
      clear_status();
      $display(
          "LENET5_AXIS_WRAPPER TEST PASSED random_stalls=%0d cycles=%0d",
          random_stalls, cycle_count);
      $finish;
    end

    // A start before model/input completion must be rejected and latched.
    axi_write(8'h04, 32'h0000_0001);
    wait_status_bit(6, 1'b1, 10);
    if (!irq)
      $fatal(1, "WRAPPER command error did not raise IRQ");
    clear_status();

    load_weights();
    load_params();
    load_input();
    clear_status();

    axi_write(8'h04, 32'h0000_0001);
    wait_status_bit(1, 1'b1, 30000);
    if (!irq)
      $fatal(1, "WRAPPER completion IRQ missing");
    axi_read(8'h20, busy_value);
    axi_read(8'h24, compute_value);
    axi_read(8'h28, pool_value);
    axi_read(8'h2c, param_value);
    if ((busy_value != wrapper_expected_counter(0)) ||
        (compute_value != wrapper_expected_counter(1)) ||
        (pool_value != wrapper_expected_counter(2)) ||
        (param_value != wrapper_expected_counter(3)))
      $fatal(1,
          "WRAPPER counters busy=%0d compute=%0d pool=%0d param=%0d",
          busy_value, compute_value, pool_value, param_value);
    $display(
        "WRAPPER COMPUTE PASSED busy=%0d compute=%0d pool=%0d param=%0d",
        busy_value, compute_value, pool_value, param_value);

    // Defaults are result_count=5, base=0, bank_base=0.
    axi_write(8'h04, 32'h0000_0004);
    receive_result();
    wait_status_bit(5, 1'b1, 100);
    clear_status();

    reset_dut();
    run_autonomous_job(
        1'b1, 32'h1003_0000, 32'h0000_1001, 3);
    clear_status();
    run_autonomous_job(
        1'b0, 32'h1005_0000, 32'h0000_1002, 1);
    clear_status();

    $display(
        "LENET5_AXIS_WRAPPER TEST PASSED random_stalls=%0d cycles=%0d",
        random_stalls, cycle_count);
    $finish;
  end

endmodule
