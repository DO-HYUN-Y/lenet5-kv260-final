`timescale 1ns/1ps
// lenet_axi_lite_regs.sv -- 32-bit AXI4-Lite control/status registers.
//
// Cycle contract:
// - AW and W may arrive in either order and are buffered independently.
// - A control write creates one-cycle command pulses when the write commits.
// - B and R payloads remain stable while the corresponding ready is low.
// - Only one write response and one read response may be outstanding.

module lenet_axi_lite_regs #(
  parameter logic [15:0] MODULE_ID = 16'h4c35,
  parameter logic [7:0]  VERSION   = 8'h02,
  parameter int ADDR_W = 8
) (
  input  logic              clk,
  input  logic              rst_n,

  input  logic [ADDR_W-1:0] s_axi_awaddr,
  input  logic              s_axi_awvalid,
  output logic              s_axi_awready,
  input  logic [31:0]       s_axi_wdata,
  input  logic [3:0]        s_axi_wstrb,
  input  logic              s_axi_wvalid,
  output logic              s_axi_wready,
  output logic [1:0]        s_axi_bresp,
  output logic              s_axi_bvalid,
  input  logic              s_axi_bready,

  input  logic [ADDR_W-1:0] s_axi_araddr,
  input  logic              s_axi_arvalid,
  output logic              s_axi_arready,
  output logic [31:0]       s_axi_rdata,
  output logic [1:0]        s_axi_rresp,
  output logic              s_axi_rvalid,
  input  logic              s_axi_rready,

  output logic              core_start_pulse,
  output logic              load_start_pulse,
  output logic              result_start_pulse,
  output logic              clear_status_pulse,
  output logic              auto_submit_pulse,

  output logic [1:0]        load_mode,
  output logic              load_activation_set,
  output logic [2:0]        load_bank_base,
  output logic [15:0]       load_count,
  output logic [15:0]       load_base,
  output logic [2:0]        result_bank_base,
  output logic [15:0]       result_word_count,
  output logic [15:0]       result_base,
  output logic              auto_reload_model,
  output logic [31:0]       auto_weight_addr,
  output logic [31:0]       auto_param_addr,
  output logic [31:0]       auto_input_addr,
  output logic [31:0]       auto_result_addr,
  output logic [31:0]       auto_timeout_cycles,
  output logic [31:0]       auto_job_id,

  input  logic              core_busy,
  input  logic              core_done_status,
  input  logic              ingress_busy,
  input  logic              ingress_done_status,
  input  logic              result_busy,
  input  logic              result_done_status,
  input  logic              error_status,
  input  logic              model_valid,
  input  logic              input_valid,
  input  logic              result_set,
  input  logic              model_host_ready,
  input  logic              activation_host_ready,
  input  logic [3:0]        op_index,
  input  logic [31:0]       busy_cycles,
  input  logic [31:0]       compute_cycles,
  input  logic [31:0]       pool_cycles,
  input  logic [31:0]       param_cycles,
  input  logic              auto_busy,
  input  logic              auto_done_status,
  input  logic              auto_error,
  input  logic              auto_queue_full,
  input  logic              auto_submit_ready,
  input  logic [4:0]        auto_state,
  input  logic [7:0]        auto_error_code,
  input  logic [31:0]       auto_completed_job_id,
  input  logic [31:0]       auto_job_cycles,
  input  logic [31:0]       auto_dma_cycles,
  input  logic [31:0]       auto_completed_jobs
);

  localparam logic [ADDR_W-1:0] REG_ID         = ADDR_W'(8'h00);
  localparam logic [ADDR_W-1:0] REG_CTRL       = ADDR_W'(8'h04);
  localparam logic [ADDR_W-1:0] REG_STATUS     = ADDR_W'(8'h08);
  localparam logic [ADDR_W-1:0] REG_LOAD_CFG   = ADDR_W'(8'h0c);
  localparam logic [ADDR_W-1:0] REG_LOAD_BASE  = ADDR_W'(8'h10);
  localparam logic [ADDR_W-1:0] REG_RESULT_CFG = ADDR_W'(8'h14);
  localparam logic [ADDR_W-1:0] REG_RESULT_BASE = ADDR_W'(8'h18);
  localparam logic [ADDR_W-1:0] REG_BUSY_CYCLES = ADDR_W'(8'h20);
  localparam logic [ADDR_W-1:0] REG_COMPUTE_CYCLES = ADDR_W'(8'h24);
  localparam logic [ADDR_W-1:0] REG_POOL_CYCLES = ADDR_W'(8'h28);
  localparam logic [ADDR_W-1:0] REG_PARAM_CYCLES = ADDR_W'(8'h2c);
  localparam logic [ADDR_W-1:0] REG_AUTO_CFG = ADDR_W'(8'h30);
  localparam logic [ADDR_W-1:0] REG_AUTO_WEIGHT_ADDR =
      ADDR_W'(8'h34);
  localparam logic [ADDR_W-1:0] REG_AUTO_PARAM_ADDR =
      ADDR_W'(8'h38);
  localparam logic [ADDR_W-1:0] REG_AUTO_INPUT_ADDR =
      ADDR_W'(8'h3c);
  localparam logic [ADDR_W-1:0] REG_AUTO_RESULT_ADDR =
      ADDR_W'(8'h40);
  localparam logic [ADDR_W-1:0] REG_AUTO_TIMEOUT =
      ADDR_W'(8'h44);
  localparam logic [ADDR_W-1:0] REG_AUTO_JOB_ID =
      ADDR_W'(8'h48);
  localparam logic [ADDR_W-1:0] REG_AUTO_STATUS =
      ADDR_W'(8'h4c);
  localparam logic [ADDR_W-1:0] REG_AUTO_ERROR =
      ADDR_W'(8'h50);
  localparam logic [ADDR_W-1:0] REG_AUTO_COMPLETED_JOB =
      ADDR_W'(8'h54);
  localparam logic [ADDR_W-1:0] REG_AUTO_JOB_CYCLES =
      ADDR_W'(8'h58);
  localparam logic [ADDR_W-1:0] REG_AUTO_DMA_CYCLES =
      ADDR_W'(8'h5c);
  localparam logic [ADDR_W-1:0] REG_AUTO_COMPLETED_COUNT =
      ADDR_W'(8'h60);

  logic aw_pending_r;
  logic [ADDR_W-1:0] awaddr_r;
  logic w_pending_r;
  logic [31:0] wdata_r;
  logic [3:0] wstrb_r;
  logic [31:0] load_cfg_r;
  logic [31:0] load_base_r;
  logic [31:0] result_cfg_r;
  logic [31:0] result_base_r;
  logic [31:0] auto_cfg_r;
  logic [31:0] auto_weight_addr_r;
  logic [31:0] auto_param_addr_r;
  logic [31:0] auto_input_addr_r;
  logic [31:0] auto_result_addr_r;
  logic [31:0] auto_timeout_r;
  logic [31:0] auto_job_id_r;
  logic [31:0] status_c;
  logic [31:0] read_data_c;
  logic [1:0] read_resp_c;

  function automatic logic [31:0] apply_wstrb(
      input logic [31:0] old_value,
      input logic [31:0] new_value,
      input logic [3:0] strobe
  );
    logic [31:0] merged;
    merged = old_value;
    for (int b = 0; b < 4; b++) begin
      if (strobe[b])
        merged[b*8 +: 8] = new_value[b*8 +: 8];
    end
    return merged;
  endfunction

  assign s_axi_awready = !aw_pending_r && !s_axi_bvalid;
  assign s_axi_wready  = !w_pending_r && !s_axi_bvalid;
  assign s_axi_arready = !s_axi_rvalid;

  assign load_mode           = load_cfg_r[1:0];
  assign load_activation_set = load_cfg_r[2];
  assign load_bank_base      = load_cfg_r[5:3];
  assign load_count          = load_cfg_r[31:16];
  assign load_base           = load_base_r[15:0];
  assign result_bank_base    = result_cfg_r[2:0];
  assign result_word_count   = result_cfg_r[31:16];
  assign result_base         = result_base_r[15:0];
  assign auto_reload_model   = auto_cfg_r[0];
  assign auto_weight_addr    = auto_weight_addr_r;
  assign auto_param_addr     = auto_param_addr_r;
  assign auto_input_addr     = auto_input_addr_r;
  assign auto_result_addr    = auto_result_addr_r;
  assign auto_timeout_cycles = auto_timeout_r;
  assign auto_job_id         = auto_job_id_r;

  always_comb begin
    status_c = '0;
    status_c[0] = core_busy;
    status_c[1] = core_done_status;
    status_c[2] = ingress_busy;
    status_c[3] = ingress_done_status;
    status_c[4] = result_busy;
    status_c[5] = result_done_status;
    status_c[6] = error_status;
    status_c[7] = model_valid;
    status_c[8] = input_valid;
    status_c[9] = result_set;
    status_c[10] = model_host_ready;
    status_c[11] = activation_host_ready;
    status_c[15:12] = op_index;
    status_c[16] = auto_busy;
    status_c[17] = auto_done_status;
    status_c[18] = auto_error;
    status_c[19] = auto_queue_full;
    status_c[20] = auto_submit_ready;
    status_c[25:21] = auto_state;

    read_data_c = 32'hdead_beef;
    read_resp_c = 2'b00;
    unique case (s_axi_araddr)
      REG_ID: read_data_c = {8'h00, VERSION, MODULE_ID};
      REG_CTRL: read_data_c = '0;
      REG_STATUS: read_data_c = status_c;
      REG_LOAD_CFG: read_data_c = load_cfg_r;
      REG_LOAD_BASE: read_data_c = load_base_r;
      REG_RESULT_CFG: read_data_c = result_cfg_r;
      REG_RESULT_BASE: read_data_c = result_base_r;
      REG_BUSY_CYCLES: read_data_c = busy_cycles;
      REG_COMPUTE_CYCLES: read_data_c = compute_cycles;
      REG_POOL_CYCLES: read_data_c = pool_cycles;
      REG_PARAM_CYCLES: read_data_c = param_cycles;
      REG_AUTO_CFG: read_data_c = auto_cfg_r;
      REG_AUTO_WEIGHT_ADDR: read_data_c = auto_weight_addr_r;
      REG_AUTO_PARAM_ADDR: read_data_c = auto_param_addr_r;
      REG_AUTO_INPUT_ADDR: read_data_c = auto_input_addr_r;
      REG_AUTO_RESULT_ADDR: read_data_c = auto_result_addr_r;
      REG_AUTO_TIMEOUT: read_data_c = auto_timeout_r;
      REG_AUTO_JOB_ID: read_data_c = auto_job_id_r;
      REG_AUTO_STATUS: begin
        read_data_c = '0;
        read_data_c[0] = auto_busy;
        read_data_c[1] = auto_done_status;
        read_data_c[2] = auto_error;
        read_data_c[3] = auto_queue_full;
        read_data_c[4] = auto_submit_ready;
        read_data_c[12:8] = auto_state;
      end
      REG_AUTO_ERROR: read_data_c = {24'd0, auto_error_code};
      REG_AUTO_COMPLETED_JOB: read_data_c = auto_completed_job_id;
      REG_AUTO_JOB_CYCLES: read_data_c = auto_job_cycles;
      REG_AUTO_DMA_CYCLES: read_data_c = auto_dma_cycles;
      REG_AUTO_COMPLETED_COUNT: read_data_c = auto_completed_jobs;
      default: read_resp_c = 2'b10;
    endcase
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      aw_pending_r <= 1'b0;
      awaddr_r <= '0;
      w_pending_r <= 1'b0;
      wdata_r <= '0;
      wstrb_r <= '0;
      s_axi_bresp <= 2'b00;
      s_axi_bvalid <= 1'b0;
      s_axi_rdata <= '0;
      s_axi_rresp <= 2'b00;
      s_axi_rvalid <= 1'b0;
      load_cfg_r <= {16'd1, 10'd0, 3'd0, 1'b0, 2'd0};
      load_base_r <= '0;
      result_cfg_r <= {16'd5, 13'd0, 3'd0};
      result_base_r <= '0;
      auto_cfg_r <= 32'd0;
      auto_weight_addr_r <= 32'd0;
      auto_param_addr_r <= 32'd0;
      auto_input_addr_r <= 32'd0;
      auto_result_addr_r <= 32'd0;
      auto_timeout_r <= 32'd10_000_000;
      auto_job_id_r <= 32'd0;
      core_start_pulse <= 1'b0;
      load_start_pulse <= 1'b0;
      result_start_pulse <= 1'b0;
      clear_status_pulse <= 1'b0;
      auto_submit_pulse <= 1'b0;
    end else begin
      core_start_pulse <= 1'b0;
      load_start_pulse <= 1'b0;
      result_start_pulse <= 1'b0;
      clear_status_pulse <= 1'b0;
      auto_submit_pulse <= 1'b0;

      if (s_axi_awvalid && s_axi_awready) begin
        aw_pending_r <= 1'b1;
        awaddr_r <= s_axi_awaddr;
      end
      if (s_axi_wvalid && s_axi_wready) begin
        w_pending_r <= 1'b1;
        wdata_r <= s_axi_wdata;
        wstrb_r <= s_axi_wstrb;
      end

      if (aw_pending_r && w_pending_r && !s_axi_bvalid) begin
        aw_pending_r <= 1'b0;
        w_pending_r <= 1'b0;
        s_axi_bresp <= 2'b00;
        s_axi_bvalid <= 1'b1;
        unique case (awaddr_r)
          REG_CTRL: begin
            if (wstrb_r[0]) begin
              core_start_pulse <= wdata_r[0];
              load_start_pulse <= wdata_r[1];
              result_start_pulse <= wdata_r[2];
              clear_status_pulse <= wdata_r[3];
              auto_submit_pulse <= wdata_r[4];
            end
          end
          REG_LOAD_CFG:
            load_cfg_r <= apply_wstrb(load_cfg_r, wdata_r, wstrb_r);
          REG_LOAD_BASE:
            load_base_r <= apply_wstrb(load_base_r, wdata_r, wstrb_r);
          REG_RESULT_CFG:
            result_cfg_r <=
                apply_wstrb(result_cfg_r, wdata_r, wstrb_r);
          REG_RESULT_BASE:
            result_base_r <=
                apply_wstrb(result_base_r, wdata_r, wstrb_r);
          REG_AUTO_CFG:
            auto_cfg_r <= apply_wstrb(auto_cfg_r, wdata_r, wstrb_r);
          REG_AUTO_WEIGHT_ADDR:
            auto_weight_addr_r <=
                apply_wstrb(auto_weight_addr_r, wdata_r, wstrb_r);
          REG_AUTO_PARAM_ADDR:
            auto_param_addr_r <=
                apply_wstrb(auto_param_addr_r, wdata_r, wstrb_r);
          REG_AUTO_INPUT_ADDR:
            auto_input_addr_r <=
                apply_wstrb(auto_input_addr_r, wdata_r, wstrb_r);
          REG_AUTO_RESULT_ADDR:
            auto_result_addr_r <=
                apply_wstrb(auto_result_addr_r, wdata_r, wstrb_r);
          REG_AUTO_TIMEOUT:
            auto_timeout_r <=
                apply_wstrb(auto_timeout_r, wdata_r, wstrb_r);
          REG_AUTO_JOB_ID:
            auto_job_id_r <=
                apply_wstrb(auto_job_id_r, wdata_r, wstrb_r);
          default: s_axi_bresp <= 2'b10;
        endcase
      end else if (s_axi_bvalid && s_axi_bready) begin
        s_axi_bvalid <= 1'b0;
      end

      if (s_axi_arvalid && s_axi_arready) begin
        s_axi_rdata <= read_data_c;
        s_axi_rresp <= read_resp_c;
        s_axi_rvalid <= 1'b1;
      end else if (s_axi_rvalid && s_axi_rready) begin
        s_axi_rvalid <= 1'b0;
      end
    end
  end

`ifdef SIMULATION
  assert property (@(posedge clk) disable iff (!rst_n)
      (s_axi_bvalid && !s_axi_bready) |=>
          s_axi_bvalid && $stable(s_axi_bresp));
  assert property (@(posedge clk) disable iff (!rst_n)
      (s_axi_rvalid && !s_axi_rready) |=>
          s_axi_rvalid && $stable({s_axi_rdata, s_axi_rresp}));
  assert property (@(posedge clk) disable iff (!rst_n)
      (core_start_pulse || load_start_pulse ||
       result_start_pulse || clear_status_pulse ||
       auto_submit_pulse) |-> s_axi_bvalid);
`endif

endmodule
