`timescale 1ns/1ps

// Convert one post-pool Conv layer store into one S2MM transaction per N8
// tile. This is intentionally downstream of max-pool: Conv1/2/5 therefore
// use 729/169/36 stored words per tile instead of the SA's raw result size.
module alexnet_conv_storage_dma_scheduler (
    input logic clk,
    input logic rst,

    input  logic layer_start_valid,
    output logic layer_start_ready,
    input  logic [2:0] layer_start_id,
    input  logic [15:0] layer_start_tag,
    input  logic [12:0] layer_start_word_count,
    input  logic [15:0] layer_start_byte_count,

    output logic request_valid,
    input  logic request_ready,
    output logic [3:0] request_layer_id,
    output logic [15:0] request_n_base,
    output logic [12:0] request_word_count,
    output logic [15:0] request_byte_count,
    output logic [15:0] request_tag,

    input  logic transfer_complete_valid,
    output logic transfer_complete_ready,
    input  logic transfer_complete_error,
    input  logic [3:0] transfer_complete_layer_id,
    input  logic [15:0] transfer_complete_n_base,
    input  logic [15:0] transfer_complete_tag,

    input  logic [127:0] storage_axis_tdata,
    input  logic [15:0] storage_axis_tkeep,
    input  logic storage_axis_tvalid,
    output logic storage_axis_tready,
    input  logic storage_axis_tlast,
    output logic [127:0] dma_axis_tdata,
    output logic [15:0] dma_axis_tkeep,
    output logic dma_axis_tvalid,
    input  logic dma_axis_tready,
    output logic dma_axis_tlast,

    output logic layer_complete_valid,
    input  logic layer_complete_ready,
    output logic [2:0] layer_complete_id,
    output logic [15:0] layer_complete_tag,
    output logic layer_complete_error,

    output logic busy,
    output logic fault,
    output logic [5:0] active_tile_index,
    output logic [15:0] active_tile_bytes,
    output logic [31:0] completed_tiles,
    output logic [31:0] completed_layers
);
  typedef enum logic [2:0] {
    ST_IDLE,
    ST_REQUEST,
    ST_STREAM,
    ST_WAIT_COMPLETION,
    ST_LAYER_COMPLETE
  } state_t;

  state_t state_q;
  logic [2:0] layer_id_q;
  logic [15:0] layer_tag_q;
  logic [5:0] tile_count_q, tile_index_q;
  logic [12:0] tile_words_q;
  logic [15:0] tile_bytes_q, bytes_seen_q;
  logic fault_q, layer_error_q;
  logic layer_start_fire, request_fire, axis_fire, completion_fire;
  logic layer_done_fire;
  logic start_fields_valid;
  logic completion_fields_valid;
  logic [4:0] beat_bytes;
  logic [16:0] next_bytes;
  integer keep_index;

  function automatic logic [5:0] fixed_tile_count(input logic [2:0] id);
    case (id)
      1: fixed_tile_count = 8;
      2: fixed_tile_count = 24;
      3: fixed_tile_count = 48;
      4,5: fixed_tile_count = 32;
      default: fixed_tile_count = 0;
    endcase
  endfunction

  function automatic logic [12:0] fixed_tile_words(input logic [2:0] id);
    case (id)
      1: fixed_tile_words = 729;
      2,3,4: fixed_tile_words = 169;
      5: fixed_tile_words = 36;
      default: fixed_tile_words = 0;
    endcase
  endfunction

  function automatic logic [12:0] fixed_layer_words(input logic [2:0] id);
    case (id)
      1: fixed_layer_words = 5832;
      2: fixed_layer_words = 4056;
      3: fixed_layer_words = 8112;
      4: fixed_layer_words = 5408;
      5: fixed_layer_words = 1152;
      default: fixed_layer_words = 0;
    endcase
  endfunction

  always_comb begin
    beat_bytes = 0;
    for (keep_index = 0; keep_index < 16; keep_index = keep_index + 1)
      beat_bytes = beat_bytes + storage_axis_tkeep[keep_index];
  end

  assign start_fields_valid = layer_start_id >= 1 && layer_start_id <= 5 &&
      layer_start_word_count == fixed_layer_words(layer_start_id) &&
      layer_start_byte_count == {layer_start_word_count, 3'b000};
  assign layer_start_ready = state_q == ST_IDLE && !fault_q;
  assign layer_start_fire = layer_start_valid && layer_start_ready;

  // The graph uses one serialized DMA command engine for MM2S and S2MM.
  // Waiting for the first post-pool beat keeps the result channel from
  // occupying that engine while activation and weight reads are still
  // required. AXI-Stream holds this first beat stable until the S2MM command
  // is accepted and ST_STREAM raises ready.
  assign request_valid = state_q == ST_REQUEST && !fault_q &&
                         storage_axis_tvalid;
  assign request_layer_id = {1'b0, layer_id_q};
  assign request_n_base = {7'b0, tile_index_q, 3'b000};
  assign request_word_count = tile_words_q;
  assign request_byte_count = tile_bytes_q;
  assign request_tag = layer_tag_q + tile_index_q;
  assign request_fire = request_valid && request_ready;

  assign dma_axis_tdata = storage_axis_tdata;
  assign dma_axis_tkeep = storage_axis_tkeep;
  assign dma_axis_tvalid = state_q == ST_STREAM && storage_axis_tvalid;
  assign dma_axis_tlast = storage_axis_tlast;
  assign storage_axis_tready = state_q == ST_STREAM && dma_axis_tready;
  assign axis_fire = storage_axis_tvalid && storage_axis_tready;
  assign next_bytes = {1'b0, bytes_seen_q} + beat_bytes;

  assign transfer_complete_ready = state_q == ST_WAIT_COMPLETION;
  assign completion_fire = transfer_complete_valid && transfer_complete_ready;
  assign completion_fields_valid = !transfer_complete_error &&
      transfer_complete_layer_id == {1'b0, layer_id_q} &&
      transfer_complete_n_base == {7'b0, tile_index_q, 3'b000} &&
      transfer_complete_tag == layer_tag_q + tile_index_q;

  assign layer_complete_valid = state_q == ST_LAYER_COMPLETE;
  assign layer_complete_id = layer_id_q;
  assign layer_complete_tag = layer_tag_q;
  assign layer_complete_error = layer_error_q || fault_q;
  assign layer_done_fire = layer_complete_valid && layer_complete_ready;
  assign busy = state_q != ST_IDLE;
  assign fault = fault_q;
  assign active_tile_index = tile_index_q;
  assign active_tile_bytes = bytes_seen_q;

  always_ff @(posedge clk) begin
    if (rst) begin
      state_q <= ST_IDLE;
      layer_id_q <= 0;
      layer_tag_q <= 0;
      tile_count_q <= 0;
      tile_index_q <= 0;
      tile_words_q <= 0;
      tile_bytes_q <= 0;
      bytes_seen_q <= 0;
      fault_q <= 1'b0;
      layer_error_q <= 1'b0;
      completed_tiles <= 0;
      completed_layers <= 0;
    end else begin
      if (layer_start_fire) begin
        layer_id_q <= layer_start_id;
        layer_tag_q <= layer_start_tag;
        tile_count_q <= fixed_tile_count(layer_start_id);
        tile_index_q <= 0;
        tile_words_q <= fixed_tile_words(layer_start_id);
        tile_bytes_q <= fixed_tile_words(layer_start_id) << 3;
        bytes_seen_q <= 0;
        layer_error_q <= !start_fields_valid;
        if (start_fields_valid)
          state_q <= ST_REQUEST;
        else begin
          fault_q <= 1'b1;
          state_q <= ST_LAYER_COMPLETE;
        end
      end

      if (request_fire) begin
        bytes_seen_q <= 0;
        state_q <= ST_STREAM;
      end

      if (axis_fire) begin
        bytes_seen_q <= next_bytes[15:0];
        if (next_bytes > {1'b0, tile_bytes_q} ||
            (storage_axis_tlast &&
             next_bytes != {1'b0, tile_bytes_q}) ||
            (!storage_axis_tlast &&
             next_bytes >= {1'b0, tile_bytes_q})) begin
          fault_q <= 1'b1;
          layer_error_q <= 1'b1;
        end
        if (storage_axis_tlast) begin
          if (next_bytes == {1'b0, tile_bytes_q})
            state_q <= ST_WAIT_COMPLETION;
          else
            state_q <= ST_LAYER_COMPLETE;
        end
      end

      if (completion_fire) begin
        if (!completion_fields_valid) begin
          fault_q <= 1'b1;
          layer_error_q <= 1'b1;
          state_q <= ST_LAYER_COMPLETE;
        end else begin
          completed_tiles <= completed_tiles + 1'b1;
          if (tile_index_q + 1'b1 == tile_count_q) begin
            state_q <= ST_LAYER_COMPLETE;
          end else begin
            tile_index_q <= tile_index_q + 1'b1;
            state_q <= ST_REQUEST;
          end
        end
      end

      if (layer_done_fire) begin
        if (!layer_complete_error) begin
          completed_layers <= completed_layers + 1'b1;
          state_q <= ST_IDLE;
        end
      end
    end
  end

`ifndef SYNTHESIS
  always_ff @(posedge clk) begin
    if (!rst) begin
      if (dma_axis_tvalid && !dma_axis_tready &&
          ({dma_axis_tdata, dma_axis_tkeep, dma_axis_tlast} !==
           {storage_axis_tdata, storage_axis_tkeep, storage_axis_tlast}))
        $fatal(1, "Conv storage DMA scheduler changed a stalled beat");
      if (completion_fire && !completion_fields_valid)
        $warning("Conv storage DMA completion metadata mismatch");
    end
  end
`endif
endmodule
