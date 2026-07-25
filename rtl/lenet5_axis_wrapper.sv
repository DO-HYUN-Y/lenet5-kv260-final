`timescale 1ns/1ps
// lenet5_axis_wrapper.sv -- software-visible LeNet-5 accelerator boundary.
//
// External interfaces are one AXI4-Lite control port, one 128-bit MM2S
// AXI4-Stream input, one 128-bit S2MM AXI4-Stream output, and a level IRQ.
// Internal 512-bit weight and 16-bit activation ports are packing widths,
// while every weight, activation, and result element remains signed INT8.

module lenet5_axis_wrapper #(
  parameter int AXIS_W = 128,
  parameter int AXI_ADDR_W = 8,
  parameter int NC = 8,
  parameter int WGT_ADDR_W = 11,
  parameter int PARAM_ADDR_W = 8,
  parameter int BANK_ADDR_W = 9,
  parameter int DMA_LEN_W = 26,
  parameter logic [31:0] DMA_BASE_ADDR = 32'ha001_0000
) (
  input  logic                    clk,
  input  logic                    rst_n,

  input  logic [AXI_ADDR_W-1:0]   s_axi_awaddr,
  input  logic                    s_axi_awvalid,
  output logic                    s_axi_awready,
  input  logic [31:0]             s_axi_wdata,
  input  logic [3:0]              s_axi_wstrb,
  input  logic                    s_axi_wvalid,
  output logic                    s_axi_wready,
  output logic [1:0]              s_axi_bresp,
  output logic                    s_axi_bvalid,
  input  logic                    s_axi_bready,
  input  logic [AXI_ADDR_W-1:0]   s_axi_araddr,
  input  logic                    s_axi_arvalid,
  output logic                    s_axi_arready,
  output logic [31:0]             s_axi_rdata,
  output logic [1:0]              s_axi_rresp,
  output logic                    s_axi_rvalid,
  input  logic                    s_axi_rready,

  output logic [31:0]             m_axi_dma_awaddr,
  output logic [2:0]              m_axi_dma_awprot,
  output logic                    m_axi_dma_awvalid,
  input  logic                    m_axi_dma_awready,
  output logic [31:0]             m_axi_dma_wdata,
  output logic [3:0]              m_axi_dma_wstrb,
  output logic                    m_axi_dma_wvalid,
  input  logic                    m_axi_dma_wready,
  input  logic [1:0]              m_axi_dma_bresp,
  input  logic                    m_axi_dma_bvalid,
  output logic                    m_axi_dma_bready,
  output logic [31:0]             m_axi_dma_araddr,
  output logic [2:0]              m_axi_dma_arprot,
  output logic                    m_axi_dma_arvalid,
  input  logic                    m_axi_dma_arready,
  input  logic [31:0]             m_axi_dma_rdata,
  input  logic [1:0]              m_axi_dma_rresp,
  input  logic                    m_axi_dma_rvalid,
  output logic                    m_axi_dma_rready,

  input  logic [AXIS_W-1:0]       s_axis_tdata,
  input  logic [AXIS_W/8-1:0]     s_axis_tkeep,
  input  logic                    s_axis_tvalid,
  output logic                    s_axis_tready,
  input  logic                    s_axis_tlast,

  output logic [AXIS_W-1:0]       m_axis_tdata,
  output logic [AXIS_W/8-1:0]     m_axis_tkeep,
  output logic                    m_axis_tvalid,
  input  logic                    m_axis_tready,
  output logic                    m_axis_tlast,

  output logic                    irq
);

  localparam logic [1:0] MODE_WEIGHT = 2'd0;
  localparam logic [1:0] MODE_PARAM  = 2'd1;
  localparam logic [1:0] MODE_INPUT  = 2'd2;
  localparam int WEIGHT_ROWS = 1449;
  localparam int PARAM_RECORDS = 236;
  localparam int INPUT_WORDS = 512;

  // Raw reset may assert asynchronously at the IP boundary. All functional
  // logic sees a reset that deasserts only after two clean clock edges.
  (* ASYNC_REG = "TRUE" *) logic [1:0] reset_sync_r;
  logic internal_rst_n;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)
      reset_sync_r <= 2'b00;
    else
      reset_sync_r <= {reset_sync_r[0], 1'b1};
  end
  assign internal_rst_n = reset_sync_r[1];

  logic core_start_cmd;
  logic load_start_cmd;
  logic result_start_cmd;
  logic clear_status_cmd;
  logic auto_submit_cmd;
  logic [1:0] load_mode;
  logic load_activation_set;
  logic [2:0] load_bank_base;
  logic [15:0] load_count;
  logic [15:0] load_base;
  logic [2:0] result_bank_base;
  logic [15:0] result_word_count;
  logic [15:0] result_base;
  logic auto_reload_model;
  logic [31:0] auto_weight_addr;
  logic [31:0] auto_param_addr;
  logic [31:0] auto_input_addr;
  logic [31:0] auto_result_addr;
  logic [31:0] auto_timeout_cycles;
  logic [31:0] auto_job_id;

  logic core_start_i;
  logic ingress_start_i;
  logic result_start_i;
  logic command_conflict_c;
  logic command_idle_c;
  logic command_error_c;
  logic scheduler_submit_i;
  logic manual_command_c;
  logic scheduler_resources_idle_c;

  logic core_busy;
  logic core_done;
  logic core_irq;
  logic core_result_set;
  logic [3:0] op_index;
  logic [31:0] busy_cycles;
  logic [31:0] compute_cycles;
  logic [31:0] pool_cycles;
  logic [31:0] param_cycles;
  logic model_host_ready;
  logic activation_host_ready;

  logic ingress_busy;
  logic ingress_done;
  logic ingress_error;
  logic result_busy;
  logic result_done;
  logic result_error;

  logic weight_loaded_r;
  logic param_loaded_r;
  logic input_loaded_r;
  logic core_done_status_r;
  logic ingress_done_status_r;
  logic result_done_status_r;
  logic result_available_r;
  logic result_set_r;
  logic error_status_r;
  logic [1:0] active_load_mode_r;
  logic [15:0] active_load_count_r;
  logic [15:0] active_load_base_r;
  logic [2:0] active_load_bank_r;
  logic active_load_set_r;
  logic model_valid_c;
  logic load_complete_valid_c;
  logic [1:0] selected_load_mode_c;
  logic selected_load_activation_set_c;
  logic [2:0] selected_load_bank_base_c;
  logic [15:0] selected_load_count_c;
  logic [15:0] selected_load_base_c;
  logic [2:0] selected_result_bank_base_c;
  logic [15:0] selected_result_word_count_c;
  logic [15:0] selected_result_base_c;

  logic scheduler_ingress_start;
  logic [1:0] scheduler_ingress_mode;
  logic [15:0] scheduler_ingress_count;
  logic [15:0] scheduler_ingress_base;
  logic [2:0] scheduler_ingress_bank_base;
  logic scheduler_ingress_activation_set;
  logic scheduler_core_start;
  logic scheduler_result_start;
  logic [15:0] scheduler_result_word_count;
  logic [15:0] scheduler_result_base;
  logic [2:0] scheduler_result_bank_base;
  logic scheduler_submit_ready;
  logic scheduler_submit_rejected;
  logic scheduler_busy;
  logic scheduler_done;
  logic scheduler_error;
  logic scheduler_queue_full;
  logic [7:0] scheduler_error_code;
  logic [4:0] scheduler_state;
  logic [31:0] scheduler_completed_job_id;
  logic [31:0] scheduler_job_cycles;
  logic [31:0] scheduler_dma_cycles;
  logic [31:0] scheduler_completed_jobs;
  logic scheduler_done_status_r;

  logic dma_cmd_valid;
  logic dma_cmd_ready;
  logic dma_cmd_s2mm;
  logic [31:0] dma_cmd_addr;
  logic [DMA_LEN_W-1:0] dma_cmd_length;
  logic [31:0] dma_cmd_timeout;
  logic dma_armed;
  logic dma_busy;
  logic dma_done;
  logic dma_error;
  logic [3:0] dma_error_code;
  logic [31:0] dma_last_status;
  logic [31:0] dma_active_cycles;
  logic [3:0] dma_state;

  logic weight_host_wr_en [0:NC-1];
  logic [WGT_ADDR_W-1:0] weight_host_wr_addr;
  logic [63:0] weight_host_wr_data [0:NC-1];
  logic param_host_wr_en;
  logic [PARAM_ADDR_W-1:0] param_host_wr_addr;
  logic signed [31:0] param_host_wr_bias;
  logic signed [17:0] param_host_wr_scale;

  logic ingress_activation_set;
  logic ingress_activation_en [0:NC-1];
  logic [1:0] ingress_activation_we [0:NC-1];
  logic [BANK_ADDR_W-1:0] ingress_activation_addr [0:NC-1];
  logic [15:0] ingress_activation_wdata [0:NC-1];

  logic result_activation_set;
  logic result_activation_en [0:NC-1];
  logic [1:0] result_activation_we [0:NC-1];
  logic [BANK_ADDR_W-1:0] result_activation_addr [0:NC-1];
  logic [15:0] result_activation_wdata [0:NC-1];

  logic core_activation_set;
  logic core_activation_en [0:NC-1];
  logic [1:0] core_activation_we [0:NC-1];
  logic [BANK_ADDR_W-1:0] core_activation_addr [0:NC-1];
  logic [15:0] core_activation_wdata [0:NC-1];
  logic [15:0] core_activation_rdata [0:NC-1];
  logic core_activation_rvalid;

  assign model_valid_c = weight_loaded_r && param_loaded_r;
  assign scheduler_resources_idle_c =
      !core_busy && !ingress_busy && !result_busy &&
      !dma_busy && !dma_error;
  assign command_idle_c =
      scheduler_resources_idle_c && !scheduler_busy && !scheduler_error;
  assign manual_command_c =
      core_start_cmd || load_start_cmd || result_start_cmd;
  assign scheduler_submit_i = auto_submit_cmd && !manual_command_c;
  assign command_conflict_c =
      (core_start_cmd && load_start_cmd) ||
      (core_start_cmd && result_start_cmd) ||
      (load_start_cmd && result_start_cmd) ||
      (auto_submit_cmd && manual_command_c);

  always_comb begin
    selected_load_mode_c = load_mode;
    selected_load_activation_set_c = load_activation_set;
    selected_load_bank_base_c = load_bank_base;
    selected_load_count_c = load_count;
    selected_load_base_c = load_base;
    selected_result_bank_base_c = result_bank_base;
    selected_result_word_count_c = result_word_count;
    selected_result_base_c = result_base;

    if (scheduler_busy) begin
      selected_load_mode_c = scheduler_ingress_mode;
      selected_load_activation_set_c =
          scheduler_ingress_activation_set;
      selected_load_bank_base_c = scheduler_ingress_bank_base;
      selected_load_count_c = scheduler_ingress_count;
      selected_load_base_c = scheduler_ingress_base;
      selected_result_bank_base_c = scheduler_result_bank_base;
      selected_result_word_count_c = scheduler_result_word_count;
      selected_result_base_c = scheduler_result_base;
    end
  end

  always_comb begin
    load_complete_valid_c = 1'b0;
    unique case (active_load_mode_r)
      MODE_WEIGHT:
        load_complete_valid_c =
            !ingress_error &&
            (active_load_count_r == 16'(WEIGHT_ROWS)) &&
            (active_load_base_r == 16'd0);
      MODE_PARAM:
        load_complete_valid_c =
            !ingress_error &&
            (active_load_count_r == 16'(PARAM_RECORDS)) &&
            (active_load_base_r == 16'd0);
      MODE_INPUT:
        load_complete_valid_c =
            !ingress_error &&
            (active_load_count_r == 16'(INPUT_WORDS)) &&
            (active_load_base_r == 16'd0) &&
            (active_load_bank_r == 3'd0) &&
            !active_load_set_r;
      default: load_complete_valid_c = 1'b0;
    endcase
  end

  always_comb begin
    core_start_i = 1'b0;
    ingress_start_i = 1'b0;
    result_start_i = 1'b0;
    command_error_c = 1'b0;

    if (command_conflict_c) begin
      command_error_c = 1'b1;
    end else if (scheduler_busy) begin
      core_start_i = scheduler_core_start;
      ingress_start_i = scheduler_ingress_start;
      result_start_i = scheduler_result_start;
    end else begin
      if (load_start_cmd) begin
        if (command_idle_c && (load_mode != 2'd3))
          ingress_start_i = 1'b1;
        else
          command_error_c = 1'b1;
      end
      if (core_start_cmd) begin
        if (command_idle_c && model_valid_c && input_loaded_r)
          core_start_i = 1'b1;
        else
          command_error_c = 1'b1;
      end
      if (result_start_cmd) begin
        if (command_idle_c && result_available_r)
          result_start_i = 1'b1;
        else
          command_error_c = 1'b1;
      end
    end
  end

  lenet_system_scheduler #(
    .DMA_LEN_W(DMA_LEN_W),
    .WEIGHT_ROWS(WEIGHT_ROWS),
    .PARAM_RECORDS(PARAM_RECORDS),
    .INPUT_WORDS(INPUT_WORDS)
  ) u_scheduler (
    .clk(clk),
    .rst_n(internal_rst_n),
    .submit(scheduler_submit_i),
    .submit_ready(scheduler_submit_ready),
    .submit_rejected(scheduler_submit_rejected),
    .clear_status(clear_status_cmd),
    .cfg_reload_model(auto_reload_model),
    .cfg_weight_addr(auto_weight_addr),
    .cfg_param_addr(auto_param_addr),
    .cfg_input_addr(auto_input_addr),
    .cfg_result_addr(auto_result_addr),
    .cfg_timeout_cycles(auto_timeout_cycles),
    .cfg_job_id(auto_job_id),
    .resources_idle(scheduler_resources_idle_c),
    .model_valid(model_valid_c),
    .ingress_busy(ingress_busy),
    .ingress_done(ingress_done),
    .ingress_error(ingress_error),
    .core_busy(core_busy),
    .core_done(core_done),
    .result_busy(result_busy),
    .result_done(result_done),
    .result_error(result_error),
    .ingress_start(scheduler_ingress_start),
    .ingress_mode(scheduler_ingress_mode),
    .ingress_count(scheduler_ingress_count),
    .ingress_base(scheduler_ingress_base),
    .ingress_bank_base(scheduler_ingress_bank_base),
    .ingress_activation_set(scheduler_ingress_activation_set),
    .core_start(scheduler_core_start),
    .result_start(scheduler_result_start),
    .result_word_count(scheduler_result_word_count),
    .result_base(scheduler_result_base),
    .result_bank_base(scheduler_result_bank_base),
    .dma_cmd_valid(dma_cmd_valid),
    .dma_cmd_ready(dma_cmd_ready),
    .dma_cmd_s2mm(dma_cmd_s2mm),
    .dma_cmd_addr(dma_cmd_addr),
    .dma_cmd_length(dma_cmd_length),
    .dma_cmd_timeout(dma_cmd_timeout),
    .dma_armed(dma_armed),
    .dma_busy(dma_busy),
    .dma_done(dma_done),
    .dma_error(dma_error),
    .dma_error_code(dma_error_code),
    .busy(scheduler_busy),
    .done(scheduler_done),
    .error(scheduler_error),
    .queue_full(scheduler_queue_full),
    .error_code(scheduler_error_code),
    .state_debug(scheduler_state),
    .completed_job_id(scheduler_completed_job_id),
    .last_job_cycles(scheduler_job_cycles),
    .last_dma_cycles(scheduler_dma_cycles),
    .completed_jobs(scheduler_completed_jobs)
  );

  axi_dma_simple_master #(
    .DMA_LEN_W(DMA_LEN_W),
    .DMA_BASE_ADDR(DMA_BASE_ADDR)
  ) u_dma_master (
    .clk(clk),
    .rst_n(internal_rst_n),
    .clear_error(clear_status_cmd),
    .cmd_valid(dma_cmd_valid),
    .cmd_ready(dma_cmd_ready),
    .cmd_s2mm(dma_cmd_s2mm),
    .cmd_buffer_addr(dma_cmd_addr),
    .cmd_length_bytes(dma_cmd_length),
    .cmd_timeout_cycles(dma_cmd_timeout),
    .armed(dma_armed),
    .busy(dma_busy),
    .done(dma_done),
    .error(dma_error),
    .error_code(dma_error_code),
    .last_status(dma_last_status),
    .active_cycles(dma_active_cycles),
    .state_debug(dma_state),
    .m_axi_awaddr(m_axi_dma_awaddr),
    .m_axi_awprot(m_axi_dma_awprot),
    .m_axi_awvalid(m_axi_dma_awvalid),
    .m_axi_awready(m_axi_dma_awready),
    .m_axi_wdata(m_axi_dma_wdata),
    .m_axi_wstrb(m_axi_dma_wstrb),
    .m_axi_wvalid(m_axi_dma_wvalid),
    .m_axi_wready(m_axi_dma_wready),
    .m_axi_bresp(m_axi_dma_bresp),
    .m_axi_bvalid(m_axi_dma_bvalid),
    .m_axi_bready(m_axi_dma_bready),
    .m_axi_araddr(m_axi_dma_araddr),
    .m_axi_arprot(m_axi_dma_arprot),
    .m_axi_arvalid(m_axi_dma_arvalid),
    .m_axi_arready(m_axi_dma_arready),
    .m_axi_rdata(m_axi_dma_rdata),
    .m_axi_rresp(m_axi_dma_rresp),
    .m_axi_rvalid(m_axi_dma_rvalid),
    .m_axi_rready(m_axi_dma_rready)
  );

  lenet_axi_lite_regs #(
    .ADDR_W(AXI_ADDR_W)
  ) u_regs (
    .clk(clk), .rst_n(internal_rst_n),
    .s_axi_awaddr(s_axi_awaddr), .s_axi_awvalid(s_axi_awvalid),
    .s_axi_awready(s_axi_awready), .s_axi_wdata(s_axi_wdata),
    .s_axi_wstrb(s_axi_wstrb), .s_axi_wvalid(s_axi_wvalid),
    .s_axi_wready(s_axi_wready), .s_axi_bresp(s_axi_bresp),
    .s_axi_bvalid(s_axi_bvalid), .s_axi_bready(s_axi_bready),
    .s_axi_araddr(s_axi_araddr), .s_axi_arvalid(s_axi_arvalid),
    .s_axi_arready(s_axi_arready), .s_axi_rdata(s_axi_rdata),
    .s_axi_rresp(s_axi_rresp), .s_axi_rvalid(s_axi_rvalid),
    .s_axi_rready(s_axi_rready),
    .core_start_pulse(core_start_cmd),
    .load_start_pulse(load_start_cmd),
    .result_start_pulse(result_start_cmd),
    .clear_status_pulse(clear_status_cmd),
    .auto_submit_pulse(auto_submit_cmd),
    .load_mode(load_mode), .load_activation_set(load_activation_set),
    .load_bank_base(load_bank_base), .load_count(load_count),
    .load_base(load_base), .result_bank_base(result_bank_base),
    .result_word_count(result_word_count), .result_base(result_base),
    .auto_reload_model(auto_reload_model),
    .auto_weight_addr(auto_weight_addr),
    .auto_param_addr(auto_param_addr),
    .auto_input_addr(auto_input_addr),
    .auto_result_addr(auto_result_addr),
    .auto_timeout_cycles(auto_timeout_cycles),
    .auto_job_id(auto_job_id),
    .core_busy(core_busy), .core_done_status(core_done_status_r),
    .ingress_busy(ingress_busy),
    .ingress_done_status(ingress_done_status_r),
    .result_busy(result_busy),
    .result_done_status(result_done_status_r),
    .error_status(error_status_r), .model_valid(model_valid_c),
    .input_valid(input_loaded_r), .result_set(result_available_r),
    .model_host_ready(model_host_ready),
    .activation_host_ready(activation_host_ready),
    .op_index(op_index), .busy_cycles(busy_cycles),
    .compute_cycles(compute_cycles), .pool_cycles(pool_cycles),
    .param_cycles(param_cycles),
    .auto_busy(scheduler_busy),
    .auto_done_status(scheduler_done_status_r),
    .auto_error(scheduler_error),
    .auto_queue_full(scheduler_queue_full),
    .auto_submit_ready(scheduler_submit_ready),
    .auto_state(scheduler_state),
    .auto_error_code(scheduler_error_code),
    .auto_completed_job_id(scheduler_completed_job_id),
    .auto_job_cycles(scheduler_job_cycles),
    .auto_dma_cycles(scheduler_dma_cycles),
    .auto_completed_jobs(scheduler_completed_jobs)
  );

  axis_lenet_ingress #(
    .NC(NC), .AXIS_W(AXIS_W), .WGT_ADDR_W(WGT_ADDR_W),
    .PARAM_ADDR_W(PARAM_ADDR_W), .BANK_ADDR_W(BANK_ADDR_W)
  ) u_ingress (
    .clk(clk), .rst_n(internal_rst_n), .start(ingress_start_i),
    .clear_error(clear_status_cmd), .cfg_mode(selected_load_mode_c),
    .cfg_count(selected_load_count_c), .cfg_base(selected_load_base_c),
    .cfg_bank_base(selected_load_bank_base_c),
    .cfg_activation_set(selected_load_activation_set_c),
    .s_axis_tdata(s_axis_tdata), .s_axis_tkeep(s_axis_tkeep),
    .s_axis_tvalid(s_axis_tvalid), .s_axis_tready(s_axis_tready),
    .s_axis_tlast(s_axis_tlast),
    .model_host_ready(model_host_ready),
    .weight_host_wr_en(weight_host_wr_en),
    .weight_host_wr_addr(weight_host_wr_addr),
    .weight_host_wr_data(weight_host_wr_data),
    .param_host_wr_en(param_host_wr_en),
    .param_host_wr_addr(param_host_wr_addr),
    .param_host_wr_bias(param_host_wr_bias),
    .param_host_wr_scale(param_host_wr_scale),
    .activation_host_ready(activation_host_ready),
    .activation_host_set(ingress_activation_set),
    .activation_host_en(ingress_activation_en),
    .activation_host_we(ingress_activation_we),
    .activation_host_addr(ingress_activation_addr),
    .activation_host_wdata(ingress_activation_wdata),
    .busy(ingress_busy), .done(ingress_done), .error(ingress_error)
  );

  axis_lenet_result #(
    .NC(NC), .AXIS_W(AXIS_W), .WGT_ADDR_W(WGT_ADDR_W),
    .PARAM_ADDR_W(PARAM_ADDR_W), .BANK_ADDR_W(BANK_ADDR_W)
  ) u_result (
    .clk(clk), .rst_n(internal_rst_n), .start(result_start_i),
    .clear_error(clear_status_cmd),
    .cfg_word_count(selected_result_word_count_c),
    .cfg_base(selected_result_base_c),
    .cfg_bank_base(selected_result_bank_base_c),
    .cfg_activation_set(result_set_r),
    .activation_host_ready(activation_host_ready),
    .activation_host_set(result_activation_set),
    .activation_host_en(result_activation_en),
    .activation_host_we(result_activation_we),
    .activation_host_addr(result_activation_addr),
    .activation_host_wdata(result_activation_wdata),
    .activation_host_rdata(core_activation_rdata),
    .activation_host_rvalid(core_activation_rvalid),
    .m_axis_tdata(m_axis_tdata), .m_axis_tkeep(m_axis_tkeep),
    .m_axis_tvalid(m_axis_tvalid), .m_axis_tready(m_axis_tready),
    .m_axis_tlast(m_axis_tlast),
    .busy(result_busy), .done(result_done), .error(result_error)
  );

  always_comb begin
    core_activation_set =
        result_busy ? result_activation_set : ingress_activation_set;
    for (int c = 0; c < NC; c++) begin
      if (result_busy) begin
        core_activation_en[c] = result_activation_en[c];
        core_activation_we[c] = result_activation_we[c];
        core_activation_addr[c] = result_activation_addr[c];
        core_activation_wdata[c] = result_activation_wdata[c];
      end else begin
        core_activation_en[c] = ingress_activation_en[c];
        core_activation_we[c] = ingress_activation_we[c];
        core_activation_addr[c] = ingress_activation_addr[c];
        core_activation_wdata[c] = ingress_activation_wdata[c];
      end
    end
  end

  lenet5_accelerator_core #(
    .NC(NC), .WGT_ADDR_W(WGT_ADDR_W),
    .BANK_ADDR_W(BANK_ADDR_W)
  ) u_core (
    .clk(clk), .rst_n(internal_rst_n), .start(core_start_i),
    .model_valid(model_valid_c), .busy(core_busy), .done(core_done),
    .irq(core_irq), .result_set(core_result_set), .op_index(op_index),
    .busy_cycles(busy_cycles), .compute_cycles(compute_cycles),
    .pool_cycles(pool_cycles), .param_cycles(param_cycles),
    .weight_host_wr_en(weight_host_wr_en),
    .weight_host_wr_addr(weight_host_wr_addr),
    .weight_host_wr_data(weight_host_wr_data),
    .param_host_wr_en(param_host_wr_en),
    .param_host_wr_addr(param_host_wr_addr),
    .param_host_wr_bias(param_host_wr_bias),
    .param_host_wr_scale(param_host_wr_scale),
    .model_host_ready(model_host_ready),
    .activation_host_set(core_activation_set),
    .activation_host_en(core_activation_en),
    .activation_host_we(core_activation_we),
    .activation_host_addr(core_activation_addr),
    .activation_host_wdata(core_activation_wdata),
    .activation_host_rdata(core_activation_rdata),
    .activation_host_rvalid(core_activation_rvalid),
    .activation_host_ready(activation_host_ready)
  );

  always_ff @(posedge clk) begin
    if (!internal_rst_n) begin
      weight_loaded_r <= 1'b0;
      param_loaded_r <= 1'b0;
      input_loaded_r <= 1'b0;
      core_done_status_r <= 1'b0;
      ingress_done_status_r <= 1'b0;
      result_done_status_r <= 1'b0;
      scheduler_done_status_r <= 1'b0;
      result_available_r <= 1'b0;
      result_set_r <= 1'b1;
      error_status_r <= 1'b0;
      active_load_mode_r <= MODE_WEIGHT;
      active_load_count_r <= '0;
      active_load_base_r <= '0;
      active_load_bank_r <= '0;
      active_load_set_r <= 1'b0;
    end else begin
      if (clear_status_cmd) begin
        core_done_status_r <= 1'b0;
        ingress_done_status_r <= 1'b0;
        result_done_status_r <= 1'b0;
        scheduler_done_status_r <= 1'b0;
        error_status_r <= 1'b0;
      end else begin
        if (command_error_c || ingress_error || result_error ||
            (ingress_done && !load_complete_valid_c) ||
            scheduler_submit_rejected || scheduler_error || dma_error)
          error_status_r <= 1'b1;
        if (ingress_done && !scheduler_busy)
          ingress_done_status_r <= 1'b1;
        if (core_done && !scheduler_busy)
          core_done_status_r <= 1'b1;
        if (result_done && !scheduler_busy)
          result_done_status_r <= 1'b1;
        if (scheduler_done)
          scheduler_done_status_r <= 1'b1;
        if (scheduler_submit_i)
          scheduler_done_status_r <= 1'b0;
      end

      if (ingress_start_i) begin
        active_load_mode_r <= selected_load_mode_c;
        active_load_count_r <= selected_load_count_c;
        active_load_base_r <= selected_load_base_c;
        active_load_bank_r <= selected_load_bank_base_c;
        active_load_set_r <= selected_load_activation_set_c;
        unique case (selected_load_mode_c)
          MODE_WEIGHT: weight_loaded_r <= 1'b0;
          MODE_PARAM: param_loaded_r <= 1'b0;
          MODE_INPUT: input_loaded_r <= 1'b0;
          default: begin
          end
        endcase
      end

      if (ingress_done) begin
        unique case (active_load_mode_r)
          MODE_WEIGHT:
            if (load_complete_valid_c)
              weight_loaded_r <= 1'b1;
          MODE_PARAM:
            if (load_complete_valid_c)
              param_loaded_r <= 1'b1;
          MODE_INPUT:
            if (load_complete_valid_c)
              input_loaded_r <= 1'b1;
          default: begin
          end
        endcase
      end

      if (core_start_i) begin
        core_done_status_r <= 1'b0;
        result_done_status_r <= 1'b0;
        result_available_r <= 1'b0;
      end
      if (core_done) begin
        result_available_r <= 1'b1;
        result_set_r <= core_result_set;
      end
      if (result_start_i)
        result_available_r <= 1'b0;
    end
  end

  assign irq =
      core_done_status_r || scheduler_done_status_r || error_status_r;

`ifdef SIMULATION
  assert property (@(posedge clk) disable iff (!internal_rst_n)
      $onehot0({core_start_i, ingress_start_i, result_start_i}));
  assert property (@(posedge clk) disable iff (!internal_rst_n)
      core_start_i |-> (model_valid_c && input_loaded_r));
  assert property (@(posedge clk) disable iff (!internal_rst_n)
      result_start_i |-> result_available_r);
  assert property (@(posedge clk) disable iff (!internal_rst_n)
      !(ingress_busy && result_busy));
`endif

endmodule
