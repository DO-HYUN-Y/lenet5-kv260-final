`timescale 1ns/1ps
// lenet_system_scheduler.sv -- autonomous DMA/compute/result job sequencer.
//
// The host submits physical DDR addresses through CSR registers. This module
// owns autonomous sequencing and a one-entry pending descriptor queue. The
// AXI DMA protocol itself is owned by axi_dma_simple_master.

module lenet_system_scheduler #(
  parameter int DMA_LEN_W = 26,
  parameter logic [31:0] DEFAULT_TIMEOUT = 32'd10_000_000,
  parameter int WEIGHT_ROWS = 1449,
  parameter int PARAM_RECORDS = 236,
  parameter int INPUT_WORDS = 512,
  parameter int RESULT_WORDS = 5,
  parameter int WEIGHT_BYTES = 92736,
  parameter int PARAM_BYTES = 1888,
  parameter int INPUT_BYTES = 1024,
  parameter int RESULT_BYTES = 10
) (
  input  logic                 clk,
  input  logic                 rst_n,
  input  logic                 submit,
  output logic                 submit_ready,
  output logic                 submit_rejected,
  input  logic                 clear_status,

  input  logic                 cfg_reload_model,
  input  logic [31:0]          cfg_weight_addr,
  input  logic [31:0]          cfg_param_addr,
  input  logic [31:0]          cfg_input_addr,
  input  logic [31:0]          cfg_result_addr,
  input  logic [31:0]          cfg_timeout_cycles,
  input  logic [31:0]          cfg_job_id,

  input  logic                 resources_idle,
  input  logic                 model_valid,
  input  logic                 ingress_busy,
  input  logic                 ingress_done,
  input  logic                 ingress_error,
  input  logic                 core_busy,
  input  logic                 core_done,
  input  logic                 result_busy,
  input  logic                 result_done,
  input  logic                 result_error,

  output logic                 ingress_start,
  output logic [1:0]           ingress_mode,
  output logic [15:0]          ingress_count,
  output logic [15:0]          ingress_base,
  output logic [2:0]           ingress_bank_base,
  output logic                 ingress_activation_set,
  output logic                 core_start,
  output logic                 result_start,
  output logic [15:0]          result_word_count,
  output logic [15:0]          result_base,
  output logic [2:0]           result_bank_base,

  output logic                 dma_cmd_valid,
  input  logic                 dma_cmd_ready,
  output logic                 dma_cmd_s2mm,
  output logic [31:0]          dma_cmd_addr,
  output logic [DMA_LEN_W-1:0] dma_cmd_length,
  output logic [31:0]          dma_cmd_timeout,
  input  logic                 dma_armed,
  input  logic                 dma_busy,
  input  logic                 dma_done,
  input  logic                 dma_error,
  input  logic [3:0]           dma_error_code,

  output logic                 busy,
  output logic                 done,
  output logic                 error,
  output logic                 queue_full,
  output logic [7:0]           error_code,
  output logic [4:0]           state_debug,
  output logic [31:0]          completed_job_id,
  output logic [31:0]          last_job_cycles,
  output logic [31:0]          last_dma_cycles,
  output logic [31:0]          completed_jobs
);

  localparam logic [1:0] MODE_WEIGHT = 2'd0;
  localparam logic [1:0] MODE_PARAM  = 2'd1;
  localparam logic [1:0] MODE_INPUT  = 2'd2;

  typedef struct packed {
    logic reload_model;
    logic [31:0] weight_addr;
    logic [31:0] param_addr;
    logic [31:0] input_addr;
    logic [31:0] result_addr;
    logic [31:0] timeout_cycles;
    logic [31:0] job_id;
  } descriptor_t;

  typedef enum logic [4:0] {
    ST_IDLE,
    ST_VALIDATE,
    ST_WEIGHT_LAUNCH,
    ST_WEIGHT_WAIT,
    ST_PARAM_LAUNCH,
    ST_PARAM_WAIT,
    ST_INPUT_LAUNCH,
    ST_INPUT_WAIT,
    ST_CORE_LAUNCH,
    ST_CORE_WAIT,
    ST_OUTPUT_DMA_LAUNCH,
    ST_OUTPUT_DMA_ARM,
    ST_RESULT_LAUNCH,
    ST_RESULT_WAIT,
    ST_COMPLETE,
    ST_ERROR
  } state_t;

  state_t state_r;
  descriptor_t active_desc_r;
  descriptor_t pending_desc_r;
  logic pending_valid_r;
  logic need_model_r;
  logic dma_done_seen_r;
  logic stream_done_seen_r;
  logic error_r;
  logic [7:0] error_code_r;
  logic [31:0] phase_cycles_r;
  logic [31:0] job_cycles_r;
  logic [31:0] dma_cycles_r;
  logic [31:0] last_job_cycles_r;
  logic [31:0] last_dma_cycles_r;
  logic [31:0] completed_job_id_r;
  logic [31:0] completed_jobs_r;
  logic [31:0] active_timeout_c;
  logic phase_wait_c;
  logic dma_phase_c;

  function automatic logic aligned_16(input logic [31:0] address);
    return address[3:0] == 4'd0;
  endfunction

  always_comb begin
    busy = (state_r != ST_IDLE) && (state_r != ST_ERROR);
    error = error_r;
    error_code = error_code_r;
    queue_full = pending_valid_r;
    state_debug = 5'(state_r);
    completed_job_id = completed_job_id_r;
    last_job_cycles = last_job_cycles_r;
    last_dma_cycles = last_dma_cycles_r;
    completed_jobs = completed_jobs_r;
    submit_ready =
        ((state_r == ST_IDLE) && !error_r && resources_idle) ||
        (busy && (state_r != ST_COMPLETE) && !pending_valid_r);

    active_timeout_c =
        (active_desc_r.timeout_cycles == 32'd0)
            ? DEFAULT_TIMEOUT : active_desc_r.timeout_cycles;

    ingress_start = 1'b0;
    ingress_mode = MODE_INPUT;
    ingress_count = 16'(INPUT_WORDS);
    ingress_base = 16'd0;
    ingress_bank_base = 3'd0;
    ingress_activation_set = 1'b0;
    core_start = 1'b0;
    result_start = 1'b0;
    result_word_count = 16'(RESULT_WORDS);
    result_base = 16'd0;
    result_bank_base = 3'd0;

    dma_cmd_valid = 1'b0;
    dma_cmd_s2mm = 1'b0;
    dma_cmd_addr = active_desc_r.input_addr;
    dma_cmd_length = DMA_LEN_W'(INPUT_BYTES);
    dma_cmd_timeout = active_timeout_c;

    unique case (state_r)
      ST_WEIGHT_LAUNCH: begin
        ingress_mode = MODE_WEIGHT;
        ingress_count = 16'(WEIGHT_ROWS);
        dma_cmd_valid = !ingress_busy;
        dma_cmd_addr = active_desc_r.weight_addr;
        dma_cmd_length = DMA_LEN_W'(WEIGHT_BYTES);
        ingress_start = dma_cmd_valid && dma_cmd_ready;
      end
      ST_PARAM_LAUNCH: begin
        ingress_mode = MODE_PARAM;
        ingress_count = 16'(PARAM_RECORDS);
        dma_cmd_valid = !ingress_busy;
        dma_cmd_addr = active_desc_r.param_addr;
        dma_cmd_length = DMA_LEN_W'(PARAM_BYTES);
        ingress_start = dma_cmd_valid && dma_cmd_ready;
      end
      ST_INPUT_LAUNCH: begin
        ingress_mode = MODE_INPUT;
        ingress_count = 16'(INPUT_WORDS);
        dma_cmd_valid = !ingress_busy;
        dma_cmd_addr = active_desc_r.input_addr;
        dma_cmd_length = DMA_LEN_W'(INPUT_BYTES);
        ingress_start = dma_cmd_valid && dma_cmd_ready;
      end
      ST_CORE_LAUNCH: begin
        core_start = !core_busy;
      end
      ST_OUTPUT_DMA_LAUNCH: begin
        dma_cmd_valid = 1'b1;
        dma_cmd_s2mm = 1'b1;
        dma_cmd_addr = active_desc_r.result_addr;
        dma_cmd_length = DMA_LEN_W'(RESULT_BYTES);
      end
      ST_RESULT_LAUNCH: begin
        result_start = !result_busy;
      end
      default: begin
      end
    endcase

    phase_wait_c =
        (state_r == ST_WEIGHT_LAUNCH) ||
        (state_r == ST_WEIGHT_WAIT) ||
        (state_r == ST_PARAM_LAUNCH) ||
        (state_r == ST_PARAM_WAIT) ||
        (state_r == ST_INPUT_LAUNCH) ||
        (state_r == ST_INPUT_WAIT) ||
        (state_r == ST_CORE_LAUNCH) ||
        (state_r == ST_CORE_WAIT) ||
        (state_r == ST_OUTPUT_DMA_LAUNCH) ||
        (state_r == ST_OUTPUT_DMA_ARM) ||
        (state_r == ST_RESULT_LAUNCH) ||
        (state_r == ST_RESULT_WAIT);
    dma_phase_c =
        (state_r == ST_WEIGHT_LAUNCH) ||
        (state_r == ST_WEIGHT_WAIT) ||
        (state_r == ST_PARAM_LAUNCH) ||
        (state_r == ST_PARAM_WAIT) ||
        (state_r == ST_INPUT_LAUNCH) ||
        (state_r == ST_INPUT_WAIT) ||
        (state_r == ST_OUTPUT_DMA_LAUNCH) ||
        (state_r == ST_OUTPUT_DMA_ARM) ||
        ((state_r == ST_RESULT_WAIT) && !dma_done_seen_r);
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state_r <= ST_IDLE;
      active_desc_r <= '0;
      pending_desc_r <= '0;
      pending_valid_r <= 1'b0;
      need_model_r <= 1'b0;
      dma_done_seen_r <= 1'b0;
      stream_done_seen_r <= 1'b0;
      submit_rejected <= 1'b0;
      done <= 1'b0;
      error_r <= 1'b0;
      error_code_r <= 8'd0;
      phase_cycles_r <= 32'd0;
      job_cycles_r <= 32'd0;
      dma_cycles_r <= 32'd0;
      last_job_cycles_r <= 32'd0;
      last_dma_cycles_r <= 32'd0;
      completed_job_id_r <= 32'd0;
      completed_jobs_r <= 32'd0;
    end else begin
      submit_rejected <= 1'b0;
      done <= 1'b0;

      if (clear_status) begin
        state_r <= ST_IDLE;
        pending_valid_r <= 1'b0;
        need_model_r <= 1'b0;
        dma_done_seen_r <= 1'b0;
        stream_done_seen_r <= 1'b0;
        error_r <= 1'b0;
        error_code_r <= 8'd0;
        phase_cycles_r <= 32'd0;
        job_cycles_r <= 32'd0;
        dma_cycles_r <= 32'd0;
      end else begin
        if (busy)
          job_cycles_r <= job_cycles_r + 1'b1;
        if (dma_phase_c)
          dma_cycles_r <= dma_cycles_r + 1'b1;
        if (phase_wait_c)
          phase_cycles_r <= phase_cycles_r + 1'b1;

        if (submit) begin
          if (!submit_ready) begin
            submit_rejected <= 1'b1;
          end else if (state_r == ST_IDLE) begin
            active_desc_r.reload_model <= cfg_reload_model;
            active_desc_r.weight_addr <= cfg_weight_addr;
            active_desc_r.param_addr <= cfg_param_addr;
            active_desc_r.input_addr <= cfg_input_addr;
            active_desc_r.result_addr <= cfg_result_addr;
            active_desc_r.timeout_cycles <= cfg_timeout_cycles;
            active_desc_r.job_id <= cfg_job_id;
            job_cycles_r <= 32'd0;
            dma_cycles_r <= 32'd0;
            phase_cycles_r <= 32'd0;
            state_r <= ST_VALIDATE;
          end else begin
            pending_desc_r.reload_model <= cfg_reload_model;
            pending_desc_r.weight_addr <= cfg_weight_addr;
            pending_desc_r.param_addr <= cfg_param_addr;
            pending_desc_r.input_addr <= cfg_input_addr;
            pending_desc_r.result_addr <= cfg_result_addr;
            pending_desc_r.timeout_cycles <= cfg_timeout_cycles;
            pending_desc_r.job_id <= cfg_job_id;
            pending_valid_r <= 1'b1;
          end
        end

        unique case (state_r)
          ST_IDLE: begin
          end

          ST_VALIDATE: begin
            need_model_r <= active_desc_r.reload_model || !model_valid;
            if (!aligned_16(active_desc_r.input_addr) ||
                !aligned_16(active_desc_r.result_addr) ||
                ((active_desc_r.reload_model || !model_valid) &&
                 (!aligned_16(active_desc_r.weight_addr) ||
                  !aligned_16(active_desc_r.param_addr)))) begin
              state_r <= ST_ERROR;
              error_r <= 1'b1;
              error_code_r <= 8'h01;
              pending_valid_r <= 1'b0;
            end else if (ingress_error) begin
              state_r <= ST_ERROR;
              error_r <= 1'b1;
              error_code_r <= 8'h04;
              pending_valid_r <= 1'b0;
            end else if (result_error) begin
              state_r <= ST_ERROR;
              error_r <= 1'b1;
              error_code_r <= 8'h05;
              pending_valid_r <= 1'b0;
            end else if (active_desc_r.reload_model || !model_valid) begin
              state_r <= ST_WEIGHT_LAUNCH;
            end else begin
              state_r <= ST_INPUT_LAUNCH;
            end
          end

          ST_WEIGHT_LAUNCH: begin
            if (dma_error) begin
              state_r <= ST_ERROR;
              error_r <= 1'b1;
              error_code_r <= {4'h2, dma_error_code};
              pending_valid_r <= 1'b0;
            end else if (ingress_error) begin
              state_r <= ST_ERROR;
              error_r <= 1'b1;
              error_code_r <= 8'h04;
              pending_valid_r <= 1'b0;
            end else if (dma_cmd_valid && dma_cmd_ready) begin
              dma_done_seen_r <= 1'b0;
              stream_done_seen_r <= 1'b0;
              phase_cycles_r <= 32'd0;
              state_r <= ST_WEIGHT_WAIT;
            end else if (phase_cycles_r >= active_timeout_c - 1'b1) begin
              state_r <= ST_ERROR;
              error_r <= 1'b1;
              error_code_r <= 8'h03;
              pending_valid_r <= 1'b0;
            end
          end

          ST_WEIGHT_WAIT: begin
            if (dma_done)
              dma_done_seen_r <= 1'b1;
            if (ingress_done)
              stream_done_seen_r <= 1'b1;
            if (dma_error) begin
              state_r <= ST_ERROR;
              error_r <= 1'b1;
              error_code_r <= {4'h2, dma_error_code};
              pending_valid_r <= 1'b0;
            end else if (ingress_error) begin
              state_r <= ST_ERROR;
              error_r <= 1'b1;
              error_code_r <= 8'h04;
              pending_valid_r <= 1'b0;
            end else if ((dma_done_seen_r || dma_done) &&
                         (stream_done_seen_r || ingress_done)) begin
              phase_cycles_r <= 32'd0;
              state_r <= ST_PARAM_LAUNCH;
            end else if (phase_cycles_r >= active_timeout_c - 1'b1) begin
              state_r <= ST_ERROR;
              error_r <= 1'b1;
              error_code_r <= 8'h03;
              pending_valid_r <= 1'b0;
            end
          end

          ST_PARAM_LAUNCH: begin
            if (dma_error) begin
              state_r <= ST_ERROR;
              error_r <= 1'b1;
              error_code_r <= {4'h2, dma_error_code};
              pending_valid_r <= 1'b0;
            end else if (ingress_error) begin
              state_r <= ST_ERROR;
              error_r <= 1'b1;
              error_code_r <= 8'h04;
              pending_valid_r <= 1'b0;
            end else if (dma_cmd_valid && dma_cmd_ready) begin
              dma_done_seen_r <= 1'b0;
              stream_done_seen_r <= 1'b0;
              phase_cycles_r <= 32'd0;
              state_r <= ST_PARAM_WAIT;
            end else if (phase_cycles_r >= active_timeout_c - 1'b1) begin
              state_r <= ST_ERROR;
              error_r <= 1'b1;
              error_code_r <= 8'h03;
              pending_valid_r <= 1'b0;
            end
          end

          ST_PARAM_WAIT: begin
            if (dma_done)
              dma_done_seen_r <= 1'b1;
            if (ingress_done)
              stream_done_seen_r <= 1'b1;
            if (dma_error) begin
              state_r <= ST_ERROR;
              error_r <= 1'b1;
              error_code_r <= {4'h2, dma_error_code};
              pending_valid_r <= 1'b0;
            end else if (ingress_error) begin
              state_r <= ST_ERROR;
              error_r <= 1'b1;
              error_code_r <= 8'h04;
              pending_valid_r <= 1'b0;
            end else if ((dma_done_seen_r || dma_done) &&
                         (stream_done_seen_r || ingress_done)) begin
              phase_cycles_r <= 32'd0;
              state_r <= ST_INPUT_LAUNCH;
            end else if (phase_cycles_r >= active_timeout_c - 1'b1) begin
              state_r <= ST_ERROR;
              error_r <= 1'b1;
              error_code_r <= 8'h03;
              pending_valid_r <= 1'b0;
            end
          end

          ST_INPUT_LAUNCH: begin
            if (dma_error) begin
              state_r <= ST_ERROR;
              error_r <= 1'b1;
              error_code_r <= {4'h2, dma_error_code};
              pending_valid_r <= 1'b0;
            end else if (ingress_error) begin
              state_r <= ST_ERROR;
              error_r <= 1'b1;
              error_code_r <= 8'h04;
              pending_valid_r <= 1'b0;
            end else if (dma_cmd_valid && dma_cmd_ready) begin
              dma_done_seen_r <= 1'b0;
              stream_done_seen_r <= 1'b0;
              phase_cycles_r <= 32'd0;
              state_r <= ST_INPUT_WAIT;
            end else if (phase_cycles_r >= active_timeout_c - 1'b1) begin
              state_r <= ST_ERROR;
              error_r <= 1'b1;
              error_code_r <= 8'h03;
              pending_valid_r <= 1'b0;
            end
          end

          ST_INPUT_WAIT: begin
            if (dma_done)
              dma_done_seen_r <= 1'b1;
            if (ingress_done)
              stream_done_seen_r <= 1'b1;
            if (dma_error) begin
              state_r <= ST_ERROR;
              error_r <= 1'b1;
              error_code_r <= {4'h2, dma_error_code};
              pending_valid_r <= 1'b0;
            end else if (ingress_error) begin
              state_r <= ST_ERROR;
              error_r <= 1'b1;
              error_code_r <= 8'h04;
              pending_valid_r <= 1'b0;
            end else if ((dma_done_seen_r || dma_done) &&
                         (stream_done_seen_r || ingress_done)) begin
              phase_cycles_r <= 32'd0;
              state_r <= ST_CORE_LAUNCH;
            end else if (phase_cycles_r >= active_timeout_c - 1'b1) begin
              state_r <= ST_ERROR;
              error_r <= 1'b1;
              error_code_r <= 8'h03;
              pending_valid_r <= 1'b0;
            end
          end

          ST_CORE_LAUNCH: begin
            if (core_start) begin
              phase_cycles_r <= 32'd0;
              state_r <= ST_CORE_WAIT;
            end else if (phase_cycles_r >= active_timeout_c - 1'b1) begin
              state_r <= ST_ERROR;
              error_r <= 1'b1;
              error_code_r <= 8'h03;
              pending_valid_r <= 1'b0;
            end
          end

          ST_CORE_WAIT: begin
            if (core_done) begin
              phase_cycles_r <= 32'd0;
              state_r <= ST_OUTPUT_DMA_LAUNCH;
            end else if (phase_cycles_r >= active_timeout_c - 1'b1) begin
              state_r <= ST_ERROR;
              error_r <= 1'b1;
              error_code_r <= 8'h03;
              pending_valid_r <= 1'b0;
            end
          end

          ST_OUTPUT_DMA_LAUNCH: begin
            if (dma_error) begin
              state_r <= ST_ERROR;
              error_r <= 1'b1;
              error_code_r <= {4'h2, dma_error_code};
              pending_valid_r <= 1'b0;
            end else if (dma_cmd_valid && dma_cmd_ready) begin
              dma_done_seen_r <= 1'b0;
              stream_done_seen_r <= 1'b0;
              phase_cycles_r <= 32'd0;
              state_r <= ST_OUTPUT_DMA_ARM;
            end else if (phase_cycles_r >= active_timeout_c - 1'b1) begin
              state_r <= ST_ERROR;
              error_r <= 1'b1;
              error_code_r <= 8'h03;
              pending_valid_r <= 1'b0;
            end
          end

          ST_OUTPUT_DMA_ARM: begin
            if (dma_error) begin
              state_r <= ST_ERROR;
              error_r <= 1'b1;
              error_code_r <= {4'h2, dma_error_code};
              pending_valid_r <= 1'b0;
            end else if (dma_armed) begin
              phase_cycles_r <= 32'd0;
              state_r <= ST_RESULT_LAUNCH;
            end else if (phase_cycles_r >= active_timeout_c - 1'b1) begin
              state_r <= ST_ERROR;
              error_r <= 1'b1;
              error_code_r <= 8'h03;
              pending_valid_r <= 1'b0;
            end
          end

          ST_RESULT_LAUNCH: begin
            if (result_error) begin
              state_r <= ST_ERROR;
              error_r <= 1'b1;
              error_code_r <= 8'h05;
              pending_valid_r <= 1'b0;
            end else if (result_start) begin
              phase_cycles_r <= 32'd0;
              state_r <= ST_RESULT_WAIT;
            end else if (phase_cycles_r >= active_timeout_c - 1'b1) begin
              state_r <= ST_ERROR;
              error_r <= 1'b1;
              error_code_r <= 8'h03;
              pending_valid_r <= 1'b0;
            end
          end

          ST_RESULT_WAIT: begin
            if (dma_done)
              dma_done_seen_r <= 1'b1;
            if (result_done)
              stream_done_seen_r <= 1'b1;
            if (dma_error) begin
              state_r <= ST_ERROR;
              error_r <= 1'b1;
              error_code_r <= {4'h2, dma_error_code};
              pending_valid_r <= 1'b0;
            end else if (result_error) begin
              state_r <= ST_ERROR;
              error_r <= 1'b1;
              error_code_r <= 8'h05;
              pending_valid_r <= 1'b0;
            end else if ((dma_done_seen_r || dma_done) &&
                         (stream_done_seen_r || result_done)) begin
              completed_job_id_r <= active_desc_r.job_id;
              completed_jobs_r <= completed_jobs_r + 1'b1;
              last_job_cycles_r <= job_cycles_r + 1'b1;
              last_dma_cycles_r <= dma_cycles_r;
              done <= 1'b1;
              state_r <= ST_COMPLETE;
            end else if (phase_cycles_r >= active_timeout_c - 1'b1) begin
              state_r <= ST_ERROR;
              error_r <= 1'b1;
              error_code_r <= 8'h03;
              pending_valid_r <= 1'b0;
            end
          end

          ST_COMPLETE: begin
            if (pending_valid_r) begin
              active_desc_r <= pending_desc_r;
              pending_valid_r <= 1'b0;
              need_model_r <= 1'b0;
              dma_done_seen_r <= 1'b0;
              stream_done_seen_r <= 1'b0;
              phase_cycles_r <= 32'd0;
              job_cycles_r <= 32'd0;
              dma_cycles_r <= 32'd0;
              state_r <= ST_VALIDATE;
            end else begin
              state_r <= ST_IDLE;
            end
          end

          ST_ERROR: begin
          end

          default: begin
            state_r <= ST_ERROR;
            error_r <= 1'b1;
            error_code_r <= 8'h03;
            pending_valid_r <= 1'b0;
          end
        endcase
      end
    end
  end

`ifdef SIMULATION
  assert property (@(posedge clk) disable iff (!rst_n)
      $onehot0({ingress_start, core_start, result_start}));
  assert property (@(posedge clk) disable iff (!rst_n)
      ingress_start |-> (dma_cmd_valid && dma_cmd_ready));
  assert property (@(posedge clk) disable iff (!rst_n)
      result_start |-> !result_busy);
  assert property (@(posedge clk) disable iff (!rst_n)
      dma_cmd_valid && dma_cmd_s2mm |->
          (state_r == ST_OUTPUT_DMA_LAUNCH));
  assert property (@(posedge clk) disable iff (!rst_n)
      pending_valid_r |-> busy);
  assert property (@(posedge clk) disable iff (!rst_n)
      error_r |-> (state_r == ST_ERROR));
`endif

endmodule
