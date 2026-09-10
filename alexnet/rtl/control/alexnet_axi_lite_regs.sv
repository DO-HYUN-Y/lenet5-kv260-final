`timescale 1ns/1ps

// Software-visible control/status shell for one AlexNet inference engine.
// Configuration writes update shadow registers. A submit snapshots the shadow
// configuration into a one-entry pending job; the active configuration changes
// only when the graph accepts that job. This keeps every DDR base stable for
// the complete inference even if software prepares the next job concurrently.
module alexnet_axi_lite_regs #(
    parameter int ADDR_W = 8,
    parameter logic [15:0] MODULE_ID = 16'h414c,
    parameter logic [7:0] VERSION = 8'h01
) (
    input  logic clk,
    input  logic rst,

    input  logic [ADDR_W-1:0] s_axi_awaddr,
    input  logic s_axi_awvalid,
    output logic s_axi_awready,
    input  logic [31:0] s_axi_wdata,
    input  logic [3:0] s_axi_wstrb,
    input  logic s_axi_wvalid,
    output logic s_axi_wready,
    output logic [1:0] s_axi_bresp,
    output logic s_axi_bvalid,
    input  logic s_axi_bready,
    input  logic [ADDR_W-1:0] s_axi_araddr,
    input  logic s_axi_arvalid,
    output logic s_axi_arready,
    output logic [31:0] s_axi_rdata,
    output logic [1:0] s_axi_rresp,
    output logic s_axi_rvalid,
    input  logic s_axi_rready,

    output logic core_start_valid,
    input  logic core_start_ready,
    output logic [15:0] core_start_tag,
    output logic [63:0] active_input_base,
    output logic [63:0] active_activation_a_base,
    output logic [63:0] active_activation_b_base,
    output logic [63:0] active_weights_base,
    output logic [63:0] active_parameters_base,
    output logic [63:0] active_final_output_base,
    output logic [31:0] active_dma_timeout_cycles,

    input logic core_busy,
    input logic inference_done,
    input logic inference_failed,
    input logic core_fault,
    input logic [3:0] fault_code,
    input logic [7:0] fault_detail,
    input logic [4:0] graph_phase,
    input logic [3:0] active_layer_id,
    input logic [15:0] active_inference_tag,
    input logic [2:0] completed_conv_layers,
    input logic [1:0] completed_fc_layers,
    input logic pool5_cache_valid,
    input logic dma_busy,
    input logic dma_error,
    input logic [3:0] dma_error_code,
    input logic [2:0] dma_active_source,
    input logic [31:0] dma_accepted_requests,
    input logic [31:0] dma_issued_commands,
    input logic [31:0] dma_completed_transfers,
    input logic [31:0] conv_storage_completed_tiles,

    output logic irq,
    output logic start_pending,
    output logic done_sticky,
    output logic failed_sticky,
    output logic fault_sticky,
    output logic start_rejected_sticky
);
  localparam logic [ADDR_W-1:0] REG_ID = ADDR_W'(8'h00);
  localparam logic [ADDR_W-1:0] REG_CONTROL = ADDR_W'(8'h04);
  localparam logic [ADDR_W-1:0] REG_STATUS = ADDR_W'(8'h08);
  localparam logic [ADDR_W-1:0] REG_JOB_TAG = ADDR_W'(8'h0c);
  localparam logic [ADDR_W-1:0] REG_INPUT_LO = ADDR_W'(8'h10);
  localparam logic [ADDR_W-1:0] REG_INPUT_HI = ADDR_W'(8'h14);
  localparam logic [ADDR_W-1:0] REG_ACT_A_LO = ADDR_W'(8'h18);
  localparam logic [ADDR_W-1:0] REG_ACT_A_HI = ADDR_W'(8'h1c);
  localparam logic [ADDR_W-1:0] REG_ACT_B_LO = ADDR_W'(8'h20);
  localparam logic [ADDR_W-1:0] REG_ACT_B_HI = ADDR_W'(8'h24);
  localparam logic [ADDR_W-1:0] REG_WEIGHTS_LO = ADDR_W'(8'h28);
  localparam logic [ADDR_W-1:0] REG_WEIGHTS_HI = ADDR_W'(8'h2c);
  localparam logic [ADDR_W-1:0] REG_PARAMETERS_LO = ADDR_W'(8'h30);
  localparam logic [ADDR_W-1:0] REG_PARAMETERS_HI = ADDR_W'(8'h34);
  localparam logic [ADDR_W-1:0] REG_OUTPUT_LO = ADDR_W'(8'h38);
  localparam logic [ADDR_W-1:0] REG_OUTPUT_HI = ADDR_W'(8'h3c);
  localparam logic [ADDR_W-1:0] REG_DMA_TIMEOUT = ADDR_W'(8'h40);
  localparam logic [ADDR_W-1:0] REG_PROGRESS = ADDR_W'(8'h44);
  localparam logic [ADDR_W-1:0] REG_ERROR = ADDR_W'(8'h48);
  localparam logic [ADDR_W-1:0] REG_ACTIVE_TAG = ADDR_W'(8'h4c);
  localparam logic [ADDR_W-1:0] REG_DMA_ACCEPTED = ADDR_W'(8'h50);
  localparam logic [ADDR_W-1:0] REG_DMA_ISSUED = ADDR_W'(8'h54);
  localparam logic [ADDR_W-1:0] REG_DMA_COMPLETED = ADDR_W'(8'h58);
  localparam logic [ADDR_W-1:0] REG_CONV_TILES = ADDR_W'(8'h5c);
  localparam logic [ADDR_W-1:0] REG_IRQ_ENABLE = ADDR_W'(8'h60);
  localparam logic [ADDR_W-1:0] REG_IRQ_STATUS = ADDR_W'(8'h64);
  localparam logic [ADDR_W-1:0] REG_LAST_JOB_CYCLES = ADDR_W'(8'h68);
  localparam logic [ADDR_W-1:0] REG_COMPLETED_JOBS = ADDR_W'(8'h6c);
  localparam logic [ADDR_W-1:0] REG_REJECTED_SUBMITS = ADDR_W'(8'h70);
  localparam logic [ADDR_W-1:0] REG_FAILED_JOBS = ADDR_W'(8'h74);
  localparam logic [ADDR_W-1:0] REG_CONFIG_STATUS = ADDR_W'(8'h78);
  localparam logic [ADDR_W-1:0] REG_BUILD_CONFIG = ADDR_W'(8'h7c);

  logic aw_pending_q;
  logic [ADDR_W-1:0] awaddr_q;
  logic w_pending_q;
  logic [31:0] wdata_q;
  logic [3:0] wstrb_q;

  logic [15:0] cfg_job_tag_q;
  logic [63:0] cfg_input_base_q;
  logic [63:0] cfg_activation_a_base_q;
  logic [63:0] cfg_activation_b_base_q;
  logic [63:0] cfg_weights_base_q;
  logic [63:0] cfg_parameters_base_q;
  logic [63:0] cfg_final_output_base_q;
  logic [31:0] cfg_dma_timeout_q;

  logic [15:0] pending_job_tag_q;
  logic [63:0] pending_input_base_q;
  logic [63:0] pending_activation_a_base_q;
  logic [63:0] pending_activation_b_base_q;
  logic [63:0] pending_weights_base_q;
  logic [63:0] pending_parameters_base_q;
  logic [63:0] pending_final_output_base_q;
  logic [31:0] pending_dma_timeout_q;

  logic [1:0] irq_enable_q;
  logic [31:0] current_job_cycles_q;
  logic [31:0] last_job_cycles_q;
  logic [31:0] completed_jobs_q;
  logic [31:0] failed_jobs_q;
  logic [31:0] rejected_submits_q;
  logic [15:0] completed_job_tag_q;
  logic [31:0] read_data_c;
  logic [1:0] read_resp_c;
  logic config_alignment_valid;
  logic config_address_range_valid;
  logic config_valid;
  logic core_start_fire;

  function automatic logic [31:0] apply_wstrb(
      input logic [31:0] old_value,
      input logic [31:0] new_value,
      input logic [3:0] strobe
  );
    logic [31:0] merged;
    begin
      merged = old_value;
      for (int byte_index = 0; byte_index < 4; byte_index++) begin
        if (strobe[byte_index])
          merged[byte_index*8 +: 8] = new_value[byte_index*8 +: 8];
      end
      return merged;
    end
  endfunction

  assign s_axi_awready = !aw_pending_q && !s_axi_bvalid;
  assign s_axi_wready = !w_pending_q && !s_axi_bvalid;
  assign s_axi_arready = !s_axi_rvalid;

  assign config_alignment_valid = cfg_input_base_q[6:0] == 0 &&
      cfg_activation_a_base_q[6:0] == 0 &&
      cfg_activation_b_base_q[6:0] == 0 &&
      cfg_weights_base_q[6:0] == 0 &&
      cfg_parameters_base_q[6:0] == 0 &&
      cfg_final_output_base_q[6:0] == 0;
  assign config_address_range_valid = cfg_input_base_q[63:32] == 0 &&
      cfg_activation_a_base_q[63:32] == 0 &&
      cfg_activation_b_base_q[63:32] == 0 &&
      cfg_weights_base_q[63:32] == 0 &&
      cfg_parameters_base_q[63:32] == 0 &&
      cfg_final_output_base_q[63:32] == 0;
  assign config_valid = config_alignment_valid && config_address_range_valid;

  assign core_start_valid = start_pending && !core_fault;
  assign core_start_tag = pending_job_tag_q;
  assign core_start_fire = core_start_valid && core_start_ready;
  assign irq = (irq_enable_q[0] && done_sticky) ||
               (irq_enable_q[1] && (failed_sticky || fault_sticky ||
                                    start_rejected_sticky));

  always_comb begin
    read_data_c = 32'hdead_beef;
    read_resp_c = 2'b00;
    unique case (s_axi_araddr)
      REG_ID: read_data_c = {MODULE_ID, VERSION, 8'h00};
      REG_CONTROL: read_data_c = 32'd0;
      REG_STATUS: begin
        read_data_c = 32'd0;
        read_data_c[0] = core_busy;
        read_data_c[1] = start_pending;
        read_data_c[2] = core_start_ready;
        read_data_c[3] = done_sticky;
        read_data_c[4] = failed_sticky;
        read_data_c[5] = fault_sticky;
        read_data_c[6] = core_fault;
        read_data_c[7] = dma_busy;
        read_data_c[8] = dma_error;
        read_data_c[9] = pool5_cache_valid;
        read_data_c[10] = irq;
        read_data_c[11] = start_rejected_sticky;
        read_data_c[12] = config_valid;
      end
      REG_JOB_TAG: read_data_c = {16'd0, cfg_job_tag_q};
      REG_INPUT_LO: read_data_c = cfg_input_base_q[31:0];
      REG_INPUT_HI: read_data_c = cfg_input_base_q[63:32];
      REG_ACT_A_LO: read_data_c = cfg_activation_a_base_q[31:0];
      REG_ACT_A_HI: read_data_c = cfg_activation_a_base_q[63:32];
      REG_ACT_B_LO: read_data_c = cfg_activation_b_base_q[31:0];
      REG_ACT_B_HI: read_data_c = cfg_activation_b_base_q[63:32];
      REG_WEIGHTS_LO: read_data_c = cfg_weights_base_q[31:0];
      REG_WEIGHTS_HI: read_data_c = cfg_weights_base_q[63:32];
      REG_PARAMETERS_LO: read_data_c = cfg_parameters_base_q[31:0];
      REG_PARAMETERS_HI: read_data_c = cfg_parameters_base_q[63:32];
      REG_OUTPUT_LO: read_data_c = cfg_final_output_base_q[31:0];
      REG_OUTPUT_HI: read_data_c = cfg_final_output_base_q[63:32];
      REG_DMA_TIMEOUT: read_data_c = cfg_dma_timeout_q;
      REG_PROGRESS: begin
        read_data_c = 32'd0;
        read_data_c[4:0] = graph_phase;
        read_data_c[11:8] = active_layer_id;
        read_data_c[18:16] = completed_conv_layers;
        read_data_c[21:20] = completed_fc_layers;
        read_data_c[26:24] = dma_active_source;
      end
      REG_ERROR: begin
        read_data_c = 32'd0;
        read_data_c[3:0] = fault_code;
        read_data_c[7:4] = dma_error_code;
        read_data_c[11:8] = active_layer_id;
        read_data_c[20:16] = graph_phase;
        read_data_c[31:24] = fault_detail;
      end
      REG_ACTIVE_TAG: read_data_c = {completed_job_tag_q,
                                     active_inference_tag};
      REG_DMA_ACCEPTED: read_data_c = dma_accepted_requests;
      REG_DMA_ISSUED: read_data_c = dma_issued_commands;
      REG_DMA_COMPLETED: read_data_c = dma_completed_transfers;
      REG_CONV_TILES: read_data_c = conv_storage_completed_tiles;
      REG_IRQ_ENABLE: read_data_c = {30'd0, irq_enable_q};
      REG_IRQ_STATUS: begin
        read_data_c = 32'd0;
        read_data_c[0] = done_sticky;
        read_data_c[1] = failed_sticky;
        read_data_c[2] = fault_sticky;
        read_data_c[3] = start_rejected_sticky;
        read_data_c[8] = inference_done;
        read_data_c[9] = inference_failed;
        read_data_c[10] = core_fault;
      end
      REG_LAST_JOB_CYCLES: read_data_c = last_job_cycles_q;
      REG_COMPLETED_JOBS: read_data_c = completed_jobs_q;
      REG_REJECTED_SUBMITS: read_data_c = rejected_submits_q;
      REG_FAILED_JOBS: read_data_c = failed_jobs_q;
      REG_CONFIG_STATUS: begin
        read_data_c = 32'd0;
        read_data_c[0] = config_valid;
        read_data_c[1] = config_alignment_valid;
        read_data_c[2] = config_address_range_valid;
        read_data_c[8] = start_pending;
      end
      REG_BUILD_CONFIG: read_data_c = {8'd8, 8'd8, 16'd200};
      default: read_resp_c = 2'b10;
    endcase
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      aw_pending_q <= 1'b0;
      awaddr_q <= '0;
      w_pending_q <= 1'b0;
      wdata_q <= '0;
      wstrb_q <= '0;
      s_axi_bresp <= 2'b00;
      s_axi_bvalid <= 1'b0;
      s_axi_rdata <= 32'd0;
      s_axi_rresp <= 2'b00;
      s_axi_rvalid <= 1'b0;

      cfg_job_tag_q <= 16'd0;
      cfg_input_base_q <= 64'd0;
      cfg_activation_a_base_q <= 64'd0;
      cfg_activation_b_base_q <= 64'd0;
      cfg_weights_base_q <= 64'd0;
      cfg_parameters_base_q <= 64'd0;
      cfg_final_output_base_q <= 64'd0;
      cfg_dma_timeout_q <= 32'd10_000_000;
      pending_job_tag_q <= 16'd0;
      pending_input_base_q <= 64'd0;
      pending_activation_a_base_q <= 64'd0;
      pending_activation_b_base_q <= 64'd0;
      pending_weights_base_q <= 64'd0;
      pending_parameters_base_q <= 64'd0;
      pending_final_output_base_q <= 64'd0;
      pending_dma_timeout_q <= 32'd10_000_000;
      active_input_base <= 64'd0;
      active_activation_a_base <= 64'd0;
      active_activation_b_base <= 64'd0;
      active_weights_base <= 64'd0;
      active_parameters_base <= 64'd0;
      active_final_output_base <= 64'd0;
      active_dma_timeout_cycles <= 32'd10_000_000;
      start_pending <= 1'b0;
      done_sticky <= 1'b0;
      failed_sticky <= 1'b0;
      fault_sticky <= 1'b0;
      start_rejected_sticky <= 1'b0;
      irq_enable_q <= 2'b00;
      current_job_cycles_q <= 32'd0;
      last_job_cycles_q <= 32'd0;
      completed_jobs_q <= 32'd0;
      failed_jobs_q <= 32'd0;
      rejected_submits_q <= 32'd0;
      completed_job_tag_q <= 16'd0;
    end else begin
      if (s_axi_awvalid && s_axi_awready) begin
        aw_pending_q <= 1'b1;
        awaddr_q <= s_axi_awaddr;
      end
      if (s_axi_wvalid && s_axi_wready) begin
        w_pending_q <= 1'b1;
        wdata_q <= s_axi_wdata;
        wstrb_q <= s_axi_wstrb;
      end

      if (aw_pending_q && w_pending_q && !s_axi_bvalid) begin
        aw_pending_q <= 1'b0;
        w_pending_q <= 1'b0;
        s_axi_bresp <= 2'b00;
        s_axi_bvalid <= 1'b1;
        unique case (awaddr_q)
          REG_CONTROL: if (wstrb_q[0]) begin
            if (wdata_q[1]) begin
              done_sticky <= 1'b0;
              failed_sticky <= 1'b0;
              fault_sticky <= 1'b0;
              start_rejected_sticky <= 1'b0;
            end
            if (wdata_q[2])
              start_pending <= 1'b0;
            if (wdata_q[0]) begin
              if (!start_pending && config_valid && !core_fault) begin
                start_pending <= 1'b1;
                pending_job_tag_q <= cfg_job_tag_q;
                pending_input_base_q <= cfg_input_base_q;
                pending_activation_a_base_q <= cfg_activation_a_base_q;
                pending_activation_b_base_q <= cfg_activation_b_base_q;
                pending_weights_base_q <= cfg_weights_base_q;
                pending_parameters_base_q <= cfg_parameters_base_q;
                pending_final_output_base_q <= cfg_final_output_base_q;
                pending_dma_timeout_q <= cfg_dma_timeout_q;
              end else begin
                s_axi_bresp <= 2'b10;
                start_rejected_sticky <= 1'b1;
                rejected_submits_q <= rejected_submits_q + 1'b1;
              end
            end
          end
          REG_JOB_TAG: cfg_job_tag_q <= apply_wstrb(
              {16'd0, cfg_job_tag_q}, wdata_q, wstrb_q);
          REG_INPUT_LO: cfg_input_base_q[31:0] <= apply_wstrb(
              cfg_input_base_q[31:0], wdata_q, wstrb_q);
          REG_INPUT_HI: cfg_input_base_q[63:32] <= apply_wstrb(
              cfg_input_base_q[63:32], wdata_q, wstrb_q);
          REG_ACT_A_LO: cfg_activation_a_base_q[31:0] <= apply_wstrb(
              cfg_activation_a_base_q[31:0], wdata_q, wstrb_q);
          REG_ACT_A_HI: cfg_activation_a_base_q[63:32] <= apply_wstrb(
              cfg_activation_a_base_q[63:32], wdata_q, wstrb_q);
          REG_ACT_B_LO: cfg_activation_b_base_q[31:0] <= apply_wstrb(
              cfg_activation_b_base_q[31:0], wdata_q, wstrb_q);
          REG_ACT_B_HI: cfg_activation_b_base_q[63:32] <= apply_wstrb(
              cfg_activation_b_base_q[63:32], wdata_q, wstrb_q);
          REG_WEIGHTS_LO: cfg_weights_base_q[31:0] <= apply_wstrb(
              cfg_weights_base_q[31:0], wdata_q, wstrb_q);
          REG_WEIGHTS_HI: cfg_weights_base_q[63:32] <= apply_wstrb(
              cfg_weights_base_q[63:32], wdata_q, wstrb_q);
          REG_PARAMETERS_LO: cfg_parameters_base_q[31:0] <= apply_wstrb(
              cfg_parameters_base_q[31:0], wdata_q, wstrb_q);
          REG_PARAMETERS_HI: cfg_parameters_base_q[63:32] <= apply_wstrb(
              cfg_parameters_base_q[63:32], wdata_q, wstrb_q);
          REG_OUTPUT_LO: cfg_final_output_base_q[31:0] <= apply_wstrb(
              cfg_final_output_base_q[31:0], wdata_q, wstrb_q);
          REG_OUTPUT_HI: cfg_final_output_base_q[63:32] <= apply_wstrb(
              cfg_final_output_base_q[63:32], wdata_q, wstrb_q);
          REG_DMA_TIMEOUT: cfg_dma_timeout_q <= apply_wstrb(
              cfg_dma_timeout_q, wdata_q, wstrb_q);
          REG_IRQ_ENABLE: irq_enable_q <= apply_wstrb(
              {30'd0, irq_enable_q}, wdata_q, wstrb_q);
          REG_IRQ_STATUS: if (wstrb_q[0]) begin
            if (wdata_q[0]) done_sticky <= 1'b0;
            if (wdata_q[1]) failed_sticky <= 1'b0;
            if (wdata_q[2]) fault_sticky <= 1'b0;
            if (wdata_q[3]) start_rejected_sticky <= 1'b0;
          end
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

      if (core_start_fire) begin
        start_pending <= 1'b0;
        active_input_base <= pending_input_base_q;
        active_activation_a_base <= pending_activation_a_base_q;
        active_activation_b_base <= pending_activation_b_base_q;
        active_weights_base <= pending_weights_base_q;
        active_parameters_base <= pending_parameters_base_q;
        active_final_output_base <= pending_final_output_base_q;
        active_dma_timeout_cycles <= pending_dma_timeout_q;
        current_job_cycles_q <= 32'd0;
      end else if (core_busy) begin
        current_job_cycles_q <= current_job_cycles_q + 1'b1;
      end

      // Event capture follows software W1C handling, so a new event cannot be
      // lost when it arrives in the same cycle as a status clear.
      if (inference_done) begin
        done_sticky <= 1'b1;
        completed_jobs_q <= completed_jobs_q + 1'b1;
        completed_job_tag_q <= active_inference_tag;
        last_job_cycles_q <= current_job_cycles_q + core_busy;
      end
      if (inference_failed) begin
        failed_sticky <= 1'b1;
        failed_jobs_q <= failed_jobs_q + 1'b1;
        completed_job_tag_q <= active_inference_tag;
        last_job_cycles_q <= current_job_cycles_q + core_busy;
      end
      if (core_fault || dma_error)
        fault_sticky <= 1'b1;
    end
  end

`ifndef SYNTHESIS
  assert property (@(posedge clk) disable iff (rst)
      (s_axi_bvalid && !s_axi_bready) |=>
          s_axi_bvalid && $stable(s_axi_bresp));
  assert property (@(posedge clk) disable iff (rst)
      (s_axi_rvalid && !s_axi_rready) |=>
          s_axi_rvalid && $stable({s_axi_rdata, s_axi_rresp}));
  assert property (@(posedge clk) disable iff (rst)
      (core_start_valid && !core_start_ready) |=>
          core_start_valid &&
          $stable({core_start_tag, pending_input_base_q,
                   pending_activation_a_base_q, pending_activation_b_base_q,
                   pending_weights_base_q, pending_parameters_base_q,
                   pending_final_output_base_q, pending_dma_timeout_q}));
  assert property (@(posedge clk) disable iff (rst)
      core_busy |=> $stable({active_input_base, active_activation_a_base,
                             active_activation_b_base, active_weights_base,
                             active_parameters_base, active_final_output_base,
                             active_dma_timeout_cycles}));
`endif
endmodule
