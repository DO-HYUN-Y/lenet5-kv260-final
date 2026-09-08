`timescale 1ns/1ps

module tb_alexnet_dma_chunk_scheduler;

  localparam int COUNT_W = 11;
  localparam int RESULT_COUNT_W = 13;
  localparam int BYTE_COUNT_W = 16;
  localparam int DIM_W = 8;
  localparam int K_COUNT_W = 10;
  localparam int TILE_TAG_W = 16;
  localparam int TENSOR_TAG_W = 16;
  localparam int WEIGHT_CONTEXT_TAG_W = 16;
  localparam int ACCUM_CONTEXT_TAG_W = 16;
  localparam int CHUNK_INDEX_W = 8;
  localparam int N_BASE_W = 16;
  localparam int COMMAND_ID_W = 16;

  localparam logic [4:0] ST_IDLE = 5'd0;
  localparam logic [4:0] ST_ACTIVATION_DESCRIPTOR = 5'd2;
  localparam logic [4:0] ST_PRE_WEIGHT_RELEASE = 5'd4;
  localparam logic [4:0] ST_WEIGHT_DESCRIPTOR = 5'd5;
  localparam logic [4:0] ST_RESULT_DESCRIPTOR = 5'd7;
  localparam logic [4:0] ST_WAIT_RESULT_ARMED = 5'd8;
  localparam logic [4:0] ST_CHUNK = 5'd9;
  localparam logic [4:0] ST_WAIT_CHUNK = 5'd10;
  localparam logic [4:0] ST_POST_WEIGHT_RELEASE = 5'd11;
  localparam logic [4:0] ST_WAIT_RESULT = 5'd12;
  localparam logic [4:0] ST_FAULT = 5'd14;
  localparam logic [4:0] ST_CLEAR_ERRORS = 5'd15;

  logic clk = 1'b0;
  logic rst;

  logic command_valid;
  logic command_ready;
  logic [COMMAND_ID_W-1:0] command_id;
  logic command_activation_streaming;
  logic [1:0] command_activation_destination;
  logic [COUNT_W-1:0] command_activation_word_count;
  logic [BYTE_COUNT_W-1:0] command_activation_byte_count;
  logic [7:0] command_activation_lane_mask;
  logic [TENSOR_TAG_W-1:0] command_activation_tensor_tag;
  logic [COUNT_W-1:0] command_weight_word_count;
  logic [BYTE_COUNT_W-1:0] command_weight_byte_count;
  logic [7:0] command_weight_lane_mask;
  logic [WEIGHT_CONTEXT_TAG_W-1:0] command_weight_context_tag;
  logic command_result_enable;
  logic [RESULT_COUNT_W-1:0] command_result_word_count;
  logic [BYTE_COUNT_W-1:0] command_result_byte_count;
  logic [1:0] command_result_destination;
  logic [2:0] command_result_slice;
  logic [N_BASE_W-1:0] command_result_n_base;
  logic [7:0] command_result_lane_mask;
  logic [TILE_TAG_W-1:0] command_result_first_tile_tag;
  logic [DIM_W-1:0] command_chunk_input_h;
  logic [DIM_W-1:0] command_chunk_input_w;
  logic [3:0] command_chunk_channel_count;
  logic [7:0] command_chunk_input_lane_mask;
  logic [3:0] command_chunk_kernel;
  logic [2:0] command_chunk_stride;
  logic [2:0] command_chunk_padding;
  logic [K_COUNT_W-1:0] command_chunk_k_count;
  logic [WEIGHT_CONTEXT_TAG_W-1:0]
      command_chunk_weight_context_tag;
  logic [RESULT_COUNT_W-1:0] command_chunk_word_count;
  logic [DIM_W-1:0] command_chunk_output_width;
  logic [ACCUM_CONTEXT_TAG_W-1:0] command_chunk_accum_context_tag;
  logic [TILE_TAG_W-1:0] command_chunk_tile_tag_base;
  logic [CHUNK_INDEX_W-1:0] command_chunk_index;
  logic command_chunk_first;
  logic command_chunk_final;

  logic datapath_configured;
  logic command_boundary_idle;
  logic pipeline_idle;
  logic protocol_error;
  logic dma_busy;
  logic dma_transfer_done;
  logic dma_descriptor_rejected;
  logic result_dma_busy;
  logic result_dma_transfer_active;
  logic result_dma_transfer_done;
  logic result_dma_descriptor_rejected;
  logic weight_resident_valid;
  logic chunk_done;
  logic chunk_rejected;

  logic dma_clear_error;
  logic dma_descriptor_valid;
  logic dma_descriptor_ready;
  logic [1:0] dma_descriptor_destination;
  logic [COUNT_W-1:0] dma_descriptor_word_count;
  logic [BYTE_COUNT_W-1:0] dma_descriptor_byte_count;
  logic [7:0] dma_descriptor_lane_mask;
  logic [TENSOR_TAG_W-1:0] dma_descriptor_tag;

  logic result_dma_clear_error;
  logic result_dma_descriptor_valid;
  logic result_dma_descriptor_ready;
  logic [RESULT_COUNT_W-1:0] result_dma_descriptor_word_count;
  logic [BYTE_COUNT_W-1:0] result_dma_descriptor_byte_count;
  logic [1:0] result_dma_descriptor_destination;
  logic [2:0] result_dma_descriptor_slice;
  logic [N_BASE_W-1:0] result_dma_descriptor_n_base;
  logic [7:0] result_dma_descriptor_lane_mask;
  logic [TILE_TAG_W-1:0] result_dma_descriptor_first_tile_tag;

  logic weight_release_valid;
  logic weight_release_ready;

  logic chunk_valid;
  logic chunk_ready;
  logic chunk_activation_streaming;
  logic [TENSOR_TAG_W-1:0] chunk_activation_tensor_tag;
  logic [DIM_W-1:0] chunk_input_h;
  logic [DIM_W-1:0] chunk_input_w;
  logic [3:0] chunk_channel_count;
  logic [7:0] chunk_input_lane_mask;
  logic [3:0] chunk_kernel;
  logic [2:0] chunk_stride;
  logic [2:0] chunk_padding;
  logic [K_COUNT_W-1:0] chunk_k_count;
  logic [WEIGHT_CONTEXT_TAG_W-1:0] chunk_weight_context_tag;
  logic [RESULT_COUNT_W-1:0] chunk_word_count;
  logic [DIM_W-1:0] chunk_output_width;
  logic [ACCUM_CONTEXT_TAG_W-1:0] chunk_accum_context_tag;
  logic [TILE_TAG_W-1:0] chunk_tile_tag_base;
  logic [CHUNK_INDEX_W-1:0] chunk_index;
  logic chunk_first;
  logic chunk_final;

  logic clear_fault;
  logic scheduler_busy;
  logic scheduler_fault;
  logic [3:0] fault_code;
  logic [4:0] phase;
  logic command_done;
  logic command_rejected;
  logic fault_cleared;
  logic command_error;
  logic [COMMAND_ID_W-1:0] active_command_id;
  logic [COMMAND_ID_W-1:0] completed_command_id;
  logic [15:0] accepted_commands;
  logic [15:0] completed_commands;
  logic [15:0] rejected_commands;

  int seed;
  int seed_sink;
  int cycles;
  int command_done_pulses;
  int command_reject_pulses;
  int fault_clear_pulses;
  int input_descriptor_handshakes;
  int result_descriptor_handshakes;
  int chunk_handshakes;
  int weight_release_handshakes;
  int input_ready_stall_cycles;
  int result_ready_stall_cycles;
  int chunk_ready_stall_cycles;
  int recovery_wait_cycles;
  logic held_input_descriptor;
  logic [1:0] held_input_destination;
  logic [COUNT_W-1:0] held_input_word_count;
  logic [BYTE_COUNT_W-1:0] held_input_byte_count;
  logic [7:0] held_input_lane_mask;
  logic [TENSOR_TAG_W-1:0] held_input_tag;
  logic held_result_descriptor;
  logic [RESULT_COUNT_W-1:0] held_result_word_count;
  logic [BYTE_COUNT_W-1:0] held_result_byte_count;
  logic [1:0] held_result_destination;
  logic [2:0] held_result_slice;
  logic [N_BASE_W-1:0] held_result_n_base;
  logic [7:0] held_result_lane_mask;
  logic [TILE_TAG_W-1:0] held_result_first_tag;
  logic held_chunk;
  logic [TENSOR_TAG_W-1:0] held_chunk_activation_tag;
  logic [WEIGHT_CONTEXT_TAG_W-1:0] held_chunk_weight_tag;
  logic [TILE_TAG_W-1:0] held_chunk_tile_tag;

  alexnet_dma_chunk_scheduler #(
      .COUNT_W(COUNT_W),
      .RESULT_COUNT_W(RESULT_COUNT_W)
  ) dut (.*);

  always #2.5 clk = ~clk;

  task automatic wait_phase(input logic [4:0] expected_phase);
    begin
      while (phase != expected_phase)
        @(negedge clk);
    end
  endtask

  task automatic load_command(
      input int id,
      input logic final_chunk,
      input logic matching_result_enable,
      input logic bad_activation_byte_count);
    begin
      command_id = COMMAND_ID_W'(id);
      command_activation_streaming = 1'b0;
      command_activation_destination = id[0] ? 2'd1 : 2'd0;
      command_activation_word_count = COUNT_W'(729);
      command_activation_byte_count =
          bad_activation_byte_count ? BYTE_COUNT_W'(5824) :
                                      BYTE_COUNT_W'(5832);
      command_activation_lane_mask = 8'hff;
      command_activation_tensor_tag = TENSOR_TAG_W'(16'h1000 + id);
      command_weight_word_count = COUNT_W'(200);
      command_weight_byte_count = BYTE_COUNT_W'(1600);
      command_weight_lane_mask = 8'hff;
      command_weight_context_tag =
          WEIGHT_CONTEXT_TAG_W'(16'h2000 + id);
      command_result_enable = matching_result_enable ? final_chunk :
                                                       !final_chunk;
      command_result_word_count = RESULT_COUNT_W'(729);
      command_result_byte_count = BYTE_COUNT_W'(5832);
      command_result_destination = 2'd2;
      command_result_slice = 3'd0;
      command_result_n_base = N_BASE_W'(16);
      command_result_lane_mask = 8'hff;
      command_result_first_tile_tag =
          TILE_TAG_W'(16'h3000 + id * 16);
      command_chunk_input_h = DIM_W'(27);
      command_chunk_input_w = DIM_W'(27);
      command_chunk_channel_count = 4'd8;
      command_chunk_input_lane_mask = 8'hff;
      command_chunk_kernel = 4'd5;
      command_chunk_stride = 3'd1;
      command_chunk_padding = 3'd2;
      command_chunk_k_count = K_COUNT_W'(200);
      command_chunk_weight_context_tag =
          WEIGHT_CONTEXT_TAG_W'(16'h2000 + id);
      command_chunk_word_count = RESULT_COUNT_W'(729);
      command_chunk_output_width = DIM_W'(27);
      command_chunk_accum_context_tag =
          ACCUM_CONTEXT_TAG_W'(16'h4000);
      command_chunk_tile_tag_base = TILE_TAG_W'(16'h3000 + id * 16);
      command_chunk_index = CHUNK_INDEX_W'(id);
      command_chunk_first = !final_chunk;
      command_chunk_final = final_chunk;
    end
  endtask

  task automatic submit_command;
    begin
      while (!command_ready)
        @(negedge clk);
      command_valid = 1'b1;
      @(posedge clk);
      @(negedge clk);
      command_valid = 1'b0;
      pipeline_idle = 1'b0;
    end
  endtask

  task automatic accept_input_descriptor(input logic weight_descriptor);
    int stalls;
    begin
      wait_phase(weight_descriptor ? ST_WEIGHT_DESCRIPTOR :
                                     ST_ACTIVATION_DESCRIPTOR);
      if (!dma_descriptor_valid)
        $fatal(1, "missing input descriptor valid");
      if (weight_descriptor) begin
        if (dma_descriptor_destination != 2'd2 ||
            dma_descriptor_word_count != command_weight_word_count ||
            dma_descriptor_byte_count != command_weight_byte_count ||
            dma_descriptor_lane_mask != command_weight_lane_mask)
          $fatal(1, "weight descriptor mismatch");
      end else begin
        if (dma_descriptor_destination != command_id[0] ||
            dma_descriptor_word_count != command_activation_word_count ||
            dma_descriptor_byte_count != command_activation_byte_count ||
            dma_descriptor_lane_mask != command_activation_lane_mask)
          $fatal(1, "activation descriptor mismatch");
      end
      stalls = $urandom_range(1, 5);
      repeat (stalls) begin
        dma_descriptor_ready = 1'b0;
        @(negedge clk);
      end
      dma_descriptor_ready = 1'b1;
      @(posedge clk);
      @(negedge clk);
      dma_descriptor_ready = 1'b0;
    end
  endtask

  task automatic complete_input_transfer(input logic commit_weight);
    int delay_cycles;
    begin
      dma_busy = 1'b1;
      delay_cycles = $urandom_range(2, 7);
      repeat (delay_cycles)
        @(negedge clk);
      dma_busy = 1'b0;
      if (commit_weight)
        weight_resident_valid = 1'b1;
      dma_transfer_done = 1'b1;
      @(posedge clk);
      @(negedge clk);
      dma_transfer_done = 1'b0;
    end
  endtask

  task automatic accept_weight_release(input logic pre_release);
    int stalls;
    begin
      wait_phase(pre_release ? ST_PRE_WEIGHT_RELEASE :
                               ST_POST_WEIGHT_RELEASE);
      stalls = $urandom_range(1, 4);
      repeat (stalls) begin
        weight_release_ready = 1'b0;
        @(negedge clk);
      end
      weight_release_ready = 1'b1;
      @(posedge clk);
      @(negedge clk);
      weight_release_ready = 1'b0;
      weight_resident_valid = 1'b0;
    end
  endtask

  task automatic accept_result_descriptor;
    int stalls;
    begin
      wait_phase(ST_RESULT_DESCRIPTOR);
      if (!result_dma_descriptor_valid ||
          result_dma_descriptor_word_count != command_result_word_count ||
          result_dma_descriptor_byte_count != command_result_byte_count ||
          result_dma_descriptor_destination != command_result_destination ||
          result_dma_descriptor_slice != command_result_slice ||
          result_dma_descriptor_n_base != command_result_n_base ||
          result_dma_descriptor_lane_mask != command_result_lane_mask ||
          result_dma_descriptor_first_tile_tag !=
              command_chunk_tile_tag_base)
        $fatal(1, "result descriptor mismatch");
      stalls = $urandom_range(1, 5);
      repeat (stalls) begin
        result_dma_descriptor_ready = 1'b0;
        @(negedge clk);
      end
      result_dma_descriptor_ready = 1'b1;
      @(posedge clk);
      @(negedge clk);
      result_dma_descriptor_ready = 1'b0;
      wait_phase(ST_WAIT_RESULT_ARMED);
      repeat ($urandom_range(2, 6)) begin
        if (chunk_valid)
          $fatal(1, "final chunk launched before result DMA active");
        @(negedge clk);
      end
      result_dma_busy = 1'b1;
      result_dma_transfer_active = 1'b1;
      @(posedge clk);
      @(negedge clk);
    end
  endtask

  task automatic accept_and_complete_chunk;
    int stalls;
    begin
      wait_phase(ST_CHUNK);
      if (!chunk_valid ||
          chunk_activation_streaming != command_activation_streaming ||
          chunk_activation_tensor_tag != command_activation_tensor_tag ||
          chunk_weight_context_tag != command_weight_context_tag ||
          chunk_input_h != command_chunk_input_h ||
          chunk_input_w != command_chunk_input_w ||
          chunk_channel_count != command_chunk_channel_count ||
          chunk_input_lane_mask != command_chunk_input_lane_mask ||
          chunk_kernel != command_chunk_kernel ||
          chunk_stride != command_chunk_stride ||
          chunk_padding != command_chunk_padding ||
          chunk_k_count != command_chunk_k_count ||
          chunk_word_count != command_chunk_word_count ||
          chunk_output_width != command_chunk_output_width ||
          chunk_tile_tag_base != command_chunk_tile_tag_base ||
          chunk_final != command_chunk_final)
        $fatal(1, "chunk descriptor mismatch");
      stalls = $urandom_range(1, 5);
      repeat (stalls) begin
        chunk_ready = 1'b0;
        @(negedge clk);
      end
      chunk_ready = 1'b1;
      @(posedge clk);
      @(negedge clk);
      chunk_ready = 1'b0;
      wait_phase(ST_WAIT_CHUNK);
      repeat ($urandom_range(4, 10))
        @(negedge clk);
      chunk_done = 1'b1;
      pipeline_idle = 1'b1;
      @(posedge clk);
      @(negedge clk);
      chunk_done = 1'b0;
    end
  endtask

  task automatic complete_result_transfer;
    begin
      wait_phase(ST_WAIT_RESULT);
      repeat ($urandom_range(2, 6))
        @(negedge clk);
      result_dma_busy = 1'b0;
      result_dma_transfer_active = 1'b0;
      result_dma_transfer_done = 1'b1;
      @(posedge clk);
      @(negedge clk);
      result_dma_transfer_done = 1'b0;
    end
  endtask

  task automatic wait_command_done(input int expected_id);
    begin
      while (!command_done)
        @(negedge clk);
      if (completed_command_id != COMMAND_ID_W'(expected_id))
        $fatal(1, "completed command ID mismatch got=%0d expected=%0d",
               completed_command_id, expected_id);
      @(negedge clk);
    end
  endtask

  task automatic recover_from_fault(input logic hold_busy);
    begin
      wait_phase(ST_FAULT);
      if (!scheduler_fault || command_ready || !scheduler_busy)
        $fatal(1, "invalid scheduler fault-state status");
      if (hold_busy) begin
        dma_busy = 1'b1;
        pipeline_idle = 1'b0;
      end
      clear_fault = 1'b1;
      @(posedge clk);
      @(negedge clk);
      clear_fault = 1'b0;
      if (hold_busy) begin
        repeat (4) begin
          if (dma_clear_error || result_dma_clear_error)
            $fatal(1, "scheduler cleared errors before owned work drained");
          recovery_wait_cycles = recovery_wait_cycles + 1;
          @(negedge clk);
        end
        dma_busy = 1'b0;
        pipeline_idle = 1'b1;
      end
      wait_phase(ST_CLEAR_ERRORS);
      if (!dma_clear_error || !result_dma_clear_error)
        $fatal(1, "scheduler did not clear both DMA error domains");
      protocol_error = 1'b0;
      while (!fault_cleared)
        @(negedge clk);
      if (scheduler_fault || fault_code != 0)
        $fatal(1, "scheduler fault status did not clear");
      @(negedge clk);
    end
  endtask

  always @(posedge clk) begin
    if (rst) begin
      cycles = 0;
      command_done_pulses = 0;
      command_reject_pulses = 0;
      fault_clear_pulses = 0;
      input_descriptor_handshakes = 0;
      result_descriptor_handshakes = 0;
      chunk_handshakes = 0;
      weight_release_handshakes = 0;
      input_ready_stall_cycles = 0;
      result_ready_stall_cycles = 0;
      chunk_ready_stall_cycles = 0;
      recovery_wait_cycles = 0;
      held_input_descriptor = 1'b0;
      held_result_descriptor = 1'b0;
      held_chunk = 1'b0;
    end else begin
      cycles = cycles + 1;
      if (cycles > 5000)
        $fatal(1, "DMA chunk scheduler watchdog expired phase=%0d", phase);

      if (command_done)
        command_done_pulses = command_done_pulses + 1;
      if (command_rejected)
        command_reject_pulses = command_reject_pulses + 1;
      if (fault_cleared)
        fault_clear_pulses = fault_clear_pulses + 1;
      if (dma_descriptor_valid && dma_descriptor_ready)
        input_descriptor_handshakes = input_descriptor_handshakes + 1;
      if (result_dma_descriptor_valid && result_dma_descriptor_ready)
        result_descriptor_handshakes = result_descriptor_handshakes + 1;
      if (chunk_valid && chunk_ready)
        chunk_handshakes = chunk_handshakes + 1;
      if (weight_release_valid && weight_release_ready)
        weight_release_handshakes = weight_release_handshakes + 1;
      if (dma_descriptor_valid && !dma_descriptor_ready)
        input_ready_stall_cycles = input_ready_stall_cycles + 1;
      if (result_dma_descriptor_valid && !result_dma_descriptor_ready)
        result_ready_stall_cycles = result_ready_stall_cycles + 1;
      if (chunk_valid && !chunk_ready)
        chunk_ready_stall_cycles = chunk_ready_stall_cycles + 1;

      if (held_input_descriptor &&
          (!dma_descriptor_valid ||
           dma_descriptor_destination != held_input_destination ||
           dma_descriptor_word_count != held_input_word_count ||
           dma_descriptor_byte_count != held_input_byte_count ||
           dma_descriptor_lane_mask != held_input_lane_mask ||
           dma_descriptor_tag != held_input_tag))
        $fatal(1, "input descriptor changed under backpressure");
      held_input_descriptor = dma_descriptor_valid &&
                              !dma_descriptor_ready;
      held_input_destination = dma_descriptor_destination;
      held_input_word_count = dma_descriptor_word_count;
      held_input_byte_count = dma_descriptor_byte_count;
      held_input_lane_mask = dma_descriptor_lane_mask;
      held_input_tag = dma_descriptor_tag;

      if (held_result_descriptor &&
          (!result_dma_descriptor_valid ||
           result_dma_descriptor_word_count != held_result_word_count ||
           result_dma_descriptor_byte_count != held_result_byte_count ||
           result_dma_descriptor_destination != held_result_destination ||
           result_dma_descriptor_slice != held_result_slice ||
           result_dma_descriptor_n_base != held_result_n_base ||
           result_dma_descriptor_lane_mask != held_result_lane_mask ||
           result_dma_descriptor_first_tile_tag != held_result_first_tag))
        $fatal(1, "result descriptor changed under backpressure");
      held_result_descriptor = result_dma_descriptor_valid &&
                               !result_dma_descriptor_ready;
      held_result_word_count = result_dma_descriptor_word_count;
      held_result_byte_count = result_dma_descriptor_byte_count;
      held_result_destination = result_dma_descriptor_destination;
      held_result_slice = result_dma_descriptor_slice;
      held_result_n_base = result_dma_descriptor_n_base;
      held_result_lane_mask = result_dma_descriptor_lane_mask;
      held_result_first_tag = result_dma_descriptor_first_tile_tag;

      if (held_chunk &&
          (!chunk_valid ||
           chunk_activation_tensor_tag != held_chunk_activation_tag ||
           chunk_weight_context_tag != held_chunk_weight_tag ||
           chunk_tile_tag_base != held_chunk_tile_tag))
        $fatal(1, "chunk descriptor changed under backpressure");
      held_chunk = chunk_valid && !chunk_ready;
      held_chunk_activation_tag = chunk_activation_tensor_tag;
      held_chunk_weight_tag = chunk_weight_context_tag;
      held_chunk_tile_tag = chunk_tile_tag_base;

      if (dma_descriptor_valid && result_dma_descriptor_valid)
        $fatal(1, "input and result descriptors issued concurrently");
      if (scheduler_fault &&
          (dma_descriptor_valid || result_dma_descriptor_valid ||
           chunk_valid || weight_release_valid))
        $fatal(1, "scheduler drove a request while faulted");
    end
  end

  initial begin
    seed = 32'h7c53_19a1;
    seed_sink = $urandom(seed);
    rst = 1'b1;
    command_valid = 1'b0;
    command_id = '0;
    command_activation_streaming = 1'b0;
    command_activation_destination = '0;
    command_activation_word_count = '0;
    command_activation_byte_count = '0;
    command_activation_lane_mask = '0;
    command_activation_tensor_tag = '0;
    command_weight_word_count = '0;
    command_weight_byte_count = '0;
    command_weight_lane_mask = '0;
    command_weight_context_tag = '0;
    command_result_enable = 1'b0;
    command_result_word_count = '0;
    command_result_byte_count = '0;
    command_result_destination = '0;
    command_result_slice = '0;
    command_result_n_base = '0;
    command_result_lane_mask = '0;
    command_result_first_tile_tag = '0;
    command_chunk_input_h = '0;
    command_chunk_input_w = '0;
    command_chunk_channel_count = '0;
    command_chunk_input_lane_mask = '0;
    command_chunk_kernel = '0;
    command_chunk_stride = '0;
    command_chunk_padding = '0;
    command_chunk_k_count = '0;
    command_chunk_weight_context_tag = '0;
    command_chunk_word_count = '0;
    command_chunk_output_width = '0;
    command_chunk_accum_context_tag = '0;
    command_chunk_tile_tag_base = '0;
    command_chunk_index = '0;
    command_chunk_first = 1'b0;
    command_chunk_final = 1'b0;
    datapath_configured = 1'b0;
    command_boundary_idle = 1'b1;
    pipeline_idle = 1'b1;
    protocol_error = 1'b0;
    dma_busy = 1'b0;
    dma_transfer_done = 1'b0;
    dma_descriptor_rejected = 1'b0;
    result_dma_busy = 1'b0;
    result_dma_transfer_active = 1'b0;
    result_dma_transfer_done = 1'b0;
    result_dma_descriptor_rejected = 1'b0;
    weight_resident_valid = 1'b0;
    chunk_done = 1'b0;
    chunk_rejected = 1'b0;
    dma_descriptor_ready = 1'b0;
    result_dma_descriptor_ready = 1'b0;
    weight_release_ready = 1'b0;
    chunk_ready = 1'b0;
    clear_fault = 1'b0;

    repeat (5)
      @(posedge clk);
    @(negedge clk);
    rst = 1'b0;

    repeat (3) begin
      if (command_ready)
        $fatal(1, "scheduler ready before datapath configuration");
      @(negedge clk);
    end
    datapath_configured = 1'b1;

    // Local cross-field validation rejects a final chunk without result DMA.
    load_command(9, 1'b1, 1'b0, 1'b0);
    submit_command();
    wait_phase(ST_FAULT);
    if (fault_code != 4'd5 || !command_error ||
        input_descriptor_handshakes != 0)
      $fatal(1, "local command rejection status mismatch");
    pipeline_idle = 1'b1;
    recover_from_fault(1'b0);

    // A non-final chunk exercises stale-weight release and skips S2MM setup.
    load_command(10, 1'b0, 1'b1, 1'b0);
    weight_resident_valid = 1'b1;
    submit_command();
    accept_input_descriptor(1'b0);
    complete_input_transfer(1'b0);
    accept_weight_release(1'b1);
    accept_input_descriptor(1'b1);
    complete_input_transfer(1'b1);
    if (result_dma_descriptor_valid)
      $fatal(1, "non-final command attempted to arm result DMA");
    accept_and_complete_chunk();
    accept_weight_release(1'b0);
    wait_command_done(10);

    // Conv1 bypasses the 1024-word activation banks. Its 50,176 input words
    // arrive on the direct stream after the scheduler has loaded weights and
    // armed the complete 3,025-word result transfer.
    load_command(13, 1'b1, 1'b1, 1'b0);
    command_activation_streaming = 1'b1;
    command_activation_word_count = 0;
    command_activation_byte_count = 0;
    command_activation_lane_mask = 8'h07;
    command_weight_word_count = COUNT_W'(363);
    command_weight_byte_count = BYTE_COUNT_W'(2904);
    command_result_word_count = RESULT_COUNT_W'(3025);
    command_result_byte_count = BYTE_COUNT_W'(24200);
    command_chunk_input_h = DIM_W'(224);
    command_chunk_input_w = DIM_W'(224);
    command_chunk_channel_count = 4'd3;
    command_chunk_input_lane_mask = 8'h07;
    command_chunk_kernel = 4'd11;
    command_chunk_stride = 3'd4;
    command_chunk_padding = 3'd2;
    command_chunk_k_count = K_COUNT_W'(363);
    command_chunk_word_count = RESULT_COUNT_W'(3025);
    command_chunk_output_width = DIM_W'(55);
    submit_command();
    // Any activation descriptor would prove that the direct-stream bypass
    // was not selected. The first input descriptor must be the weight tile.
    accept_input_descriptor(1'b1);
    complete_input_transfer(1'b1);
    accept_result_descriptor();
    accept_and_complete_chunk();
    accept_weight_release(1'b0);
    complete_result_transfer();
    wait_command_done(13);

    // A malformed activation byte count is owned and rejected downstream.
    load_command(11, 1'b0, 1'b1, 1'b1);
    submit_command();
    accept_input_descriptor(1'b0);
    dma_descriptor_rejected = 1'b1;
    protocol_error = 1'b1;
    @(posedge clk);
    @(negedge clk);
    dma_descriptor_rejected = 1'b0;
    wait_phase(ST_FAULT);
    if (fault_code != 4'd2)
      $fatal(1, "downstream input-descriptor fault code mismatch");
    recover_from_fault(1'b1);

    // Restart with a final command. S2MM must be active before chunk launch.
    load_command(12, 1'b1, 1'b1, 1'b0);
    submit_command();
    accept_input_descriptor(1'b0);
    complete_input_transfer(1'b0);
    accept_input_descriptor(1'b1);
    complete_input_transfer(1'b1);
    accept_result_descriptor();
    accept_and_complete_chunk();
    accept_weight_release(1'b0);
    complete_result_transfer();
    wait_command_done(12);

    repeat (3)
      @(negedge clk);
    if (phase != ST_IDLE || scheduler_busy || scheduler_fault ||
        accepted_commands != 5 || completed_commands != 3 ||
        rejected_commands != 2 || command_done_pulses != 3 ||
        command_reject_pulses != 2 || fault_clear_pulses != 2 ||
        input_descriptor_handshakes != 6 ||
        result_descriptor_handshakes != 2 || chunk_handshakes != 3 ||
        weight_release_handshakes != 4 ||
        completed_command_id != 12 || command_error)
      $fatal(1,
             "scheduler totals mismatch accepted=%0d complete=%0d rejected=%0d done_pulses=%0d reject_pulses=%0d clears=%0d input_desc=%0d result_desc=%0d chunks=%0d releases=%0d completed_id=%0d phase=%0d busy=%0b fault=%0b command_error=%0b",
             accepted_commands, completed_commands, rejected_commands,
             command_done_pulses, command_reject_pulses,
             fault_clear_pulses, input_descriptor_handshakes,
             result_descriptor_handshakes, chunk_handshakes,
             weight_release_handshakes, completed_command_id, phase,
             scheduler_busy, scheduler_fault, command_error);

    $display("ALEXNET_DMA_CHUNK_SCHEDULER_TEST_PASSED commands=5 completed=3 rejected=2 conv1_streaming=1 input_descriptors=6 result_descriptors=2 chunks=3 weight_releases=4 input_stall_cycles=%0d result_stall_cycles=%0d chunk_stall_cycles=%0d recovery_wait_cycles=%0d seed=%0d",
             input_ready_stall_cycles, result_ready_stall_cycles,
             chunk_ready_stall_cycles, recovery_wait_cycles, seed);
    $finish;
  end

endmodule
