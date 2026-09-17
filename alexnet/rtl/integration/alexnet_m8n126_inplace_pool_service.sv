`timescale 1ns/1ps

// Reuse one AXI DMA in sequential MM2S/S2MM phases to pool a complete
// Conv1, Conv2, or Conv5 result tensor in place.  One raw N8 channel tile is
// buffered at a time, so the largest storage requirement is Conv1's
// 55*55*8 = 24,200 bytes rather than the complete feature map.
module alexnet_m8n126_inplace_pool_service (
    input logic clk,
    input logic rst,

    input  logic layer_valid,
    output logic layer_ready,
    input  logic [3:0] layer_id,
    input  logic [15:0] layer_job_tag,
    input  logic [31:0] layer_buffer_base,

    output logic dma_command_valid,
    input  logic dma_command_ready,
    output logic dma_command_s2mm,
    output logic [31:0] dma_command_address,
    output logic [25:0] dma_command_length,
    input  logic dma_armed,
    input  logic dma_done,
    input  logic dma_error,

    input  logic [127:0] s_axis_tdata,
    input  logic [15:0] s_axis_tkeep,
    input  logic s_axis_tvalid,
    output logic s_axis_tready,
    input  logic s_axis_tlast,

    output logic [127:0] m_axis_tdata,
    output logic [15:0] m_axis_tkeep,
    output logic m_axis_tvalid,
    input  logic m_axis_tready,
    output logic m_axis_tlast,

    output logic layer_done,
    output logic layer_error,
    output logic busy,
    output logic [5:0] completed_tiles,
    output logic [31:0] raw_words_read,
    output logic [31:0] pooled_words_written
);
  localparam int MAX_RAW_BEATS = 1513;

  typedef enum logic [3:0] {
    ST_IDLE,
    ST_POOL_DESC,
    ST_READ_COMMAND,
    ST_READ_ARM,
    ST_READ_STREAM,
    ST_READ_DRAIN,
    ST_WRITE_COMMAND,
    ST_WRITE_ARM,
    ST_REPLAY,
    ST_WRITE_DRAIN,
    ST_LAYER_FINISH,
    ST_FAILED
  } state_t;

  state_t state_q;
  logic [3:0] layer_id_q;
  logic [15:0] job_tag_q;
  logic [31:0] buffer_base_q;
  logic [5:0] tile_index_q;
  logic [7:0] raw_h, raw_w;
  logic [5:0] stored_h, stored_w, n8_tiles;
  logic [12:0] raw_words_per_tile, stored_words_per_tile;
  logic [11:0] raw_beats_per_tile;
  logic [25:0] raw_bytes_per_tile, stored_bytes_per_tile;
  (* use_dsp = "no" *) logic [31:0] raw_tile_offset;
  (* use_dsp = "no" *) logic [31:0] stored_tile_offset;

  (* ram_style = "block" *) logic [127:0] raw_tile_buffer
      [0:MAX_RAW_BEATS-1];
  logic [10:0] capture_index_q;
  logic [10:0] replay_fetch_index_q, replay_index_q;
  logic [127:0] replay_data_q;
  logic replay_valid_q;
  logic dma_done_seen_q, pool_done_seen_q, fault_q;
  logic command_fire, input_fire, replay_fire, output_fire;
  logic expected_input_last;
  logic [15:0] expected_input_keep;

  logic pool_layer_valid, pool_layer_ready, pool_layer_done;
  logic [2:0] pool_completed_layer_id;
  logic [15:0] pool_completed_job_tag;
  logic pool_layer_error, pool_busy, pool_fault;
  logic [31:0] pool_raw_words, pool_stored_words;
  logic [5:0] pool_input_tiles, pool_output_tiles;
  logic pool_input_ready;
  logic [127:0] pool_output_data;
  logic [15:0] pool_output_keep;
  logic pool_output_valid, pool_output_last;

  assign layer_ready = state_q == ST_IDLE;
  assign busy = state_q != ST_IDLE;
  assign layer_error = fault_q || pool_fault || dma_error;
  assign dma_command_valid = state_q == ST_READ_COMMAND ||
                             state_q == ST_WRITE_COMMAND;
  assign dma_command_s2mm = state_q == ST_WRITE_COMMAND;
  assign dma_command_address = buffer_base_q +
      (dma_command_s2mm ? stored_tile_offset : raw_tile_offset);
  assign dma_command_length = dma_command_s2mm ? stored_bytes_per_tile :
                                                  raw_bytes_per_tile;
  assign command_fire = dma_command_valid && dma_command_ready;

  assign s_axis_tready = (state_q == ST_READ_ARM ||
                          state_q == ST_READ_STREAM) &&
                         capture_index_q < raw_beats_per_tile;
  assign input_fire = s_axis_tvalid && s_axis_tready;
  assign expected_input_last = capture_index_q + 1'b1 ==
                               raw_beats_per_tile;
  assign expected_input_keep = expected_input_last ? 16'h00ff : 16'hffff;

  assign pool_layer_valid = state_q == ST_POOL_DESC;
  assign replay_fire = state_q == ST_REPLAY && replay_valid_q &&
                       pool_input_ready;

  assign m_axis_tdata = pool_output_data;
  assign m_axis_tkeep = pool_output_keep;
  assign m_axis_tvalid = (state_q == ST_REPLAY ||
                          state_q == ST_WRITE_DRAIN) && pool_output_valid;
  assign m_axis_tlast = pool_output_last;
  assign output_fire = m_axis_tvalid && m_axis_tready;

  always_comb begin
    raw_h = 0;
    raw_w = 0;
    stored_h = 0;
    stored_w = 0;
    n8_tiles = 0;
    raw_words_per_tile = 0;
    stored_words_per_tile = 0;
    case (layer_id_q)
      1: begin
        raw_h = 55; raw_w = 55; stored_h = 27; stored_w = 27;
        n8_tiles = 8; raw_words_per_tile = 3025;
        stored_words_per_tile = 729;
      end
      2: begin
        raw_h = 27; raw_w = 27; stored_h = 13; stored_w = 13;
        n8_tiles = 24; raw_words_per_tile = 729;
        stored_words_per_tile = 169;
      end
      5: begin
        raw_h = 13; raw_w = 13; stored_h = 6; stored_w = 6;
        n8_tiles = 32; raw_words_per_tile = 169;
        stored_words_per_tile = 36;
      end
      default: begin end
    endcase
    raw_beats_per_tile = (raw_words_per_tile + 1'b1) >> 1;
    raw_bytes_per_tile = {10'd0, raw_words_per_tile, 3'b000};
    stored_bytes_per_tile = {10'd0, stored_words_per_tile, 3'b000};

    case (layer_id_q)
      1: raw_tile_offset = (tile_index_q << 14) +
          (tile_index_q << 12) + (tile_index_q << 11) +
          (tile_index_q << 10) + (tile_index_q << 9) +
          (tile_index_q << 7) + (tile_index_q << 3);
      2: raw_tile_offset = (tile_index_q << 12) +
          (tile_index_q << 10) + (tile_index_q << 9) +
          (tile_index_q << 7) + (tile_index_q << 6) +
          (tile_index_q << 3);
      5: raw_tile_offset = (tile_index_q << 10) +
          (tile_index_q << 8) + (tile_index_q << 6) +
          (tile_index_q << 3);
      default: raw_tile_offset = 0;
    endcase
    case (layer_id_q)
      1: stored_tile_offset = (tile_index_q << 12) +
          (tile_index_q << 10) + (tile_index_q << 9) +
          (tile_index_q << 7) + (tile_index_q << 6) +
          (tile_index_q << 3);
      2: stored_tile_offset = (tile_index_q << 10) +
          (tile_index_q << 8) + (tile_index_q << 6) +
          (tile_index_q << 3);
      5: stored_tile_offset = (tile_index_q << 8) +
          (tile_index_q << 5);
      default: stored_tile_offset = 0;
    endcase
  end

  alexnet_conv_result_pool_service u_pool_service (
      .clk, .rst,
      .layer_valid(pool_layer_valid), .layer_ready(pool_layer_ready),
      .layer_id(layer_id_q[2:0]), .layer_job_tag(job_tag_q),
      .layer_raw_h(raw_h), .layer_raw_w(raw_w),
      .layer_n8_tiles(n8_tiles), .layer_pool_enable(1'b1),
      .layer_stored_h(stored_h), .layer_stored_w(stored_w),
      .s_axis_tdata(replay_data_q),
      .s_axis_tkeep(replay_index_q + 1'b1 == raw_beats_per_tile ?
                    16'h00ff : 16'hffff),
      .s_axis_tvalid(state_q == ST_REPLAY && replay_valid_q),
      .s_axis_tready(pool_input_ready),
      .s_axis_tlast(replay_index_q + 1'b1 == raw_beats_per_tile),
      .m_axis_tdata(pool_output_data), .m_axis_tkeep(pool_output_keep),
      .m_axis_tvalid(pool_output_valid),
      .m_axis_tready(m_axis_tready &&
          (state_q == ST_REPLAY || state_q == ST_WRITE_DRAIN)),
      .m_axis_tlast(pool_output_last),
      .layer_done(pool_layer_done),
      .completed_layer_id(pool_completed_layer_id),
      .completed_job_tag(pool_completed_job_tag),
      .layer_error(pool_layer_error), .busy(pool_busy), .fault(pool_fault),
      .raw_words_accepted(pool_raw_words),
      .stored_words_transferred(pool_stored_words),
      .input_tiles_completed(pool_input_tiles),
      .output_tiles_completed(pool_output_tiles)
  );

  always_ff @(posedge clk) begin
    if (rst) begin
      state_q <= ST_IDLE;
      layer_id_q <= 0;
      job_tag_q <= 0;
      buffer_base_q <= 0;
      tile_index_q <= 0;
      capture_index_q <= 0;
      replay_fetch_index_q <= 0;
      replay_index_q <= 0;
      replay_data_q <= 0;
      replay_valid_q <= 1'b0;
      dma_done_seen_q <= 1'b0;
      pool_done_seen_q <= 1'b0;
      fault_q <= 1'b0;
      layer_done <= 1'b0;
      completed_tiles <= 0;
      raw_words_read <= 0;
      pooled_words_written <= 0;
    end else begin
      layer_done <= 1'b0;
      if (dma_done)
        dma_done_seen_q <= 1'b1;
      if (pool_layer_done)
        pool_done_seen_q <= 1'b1;

      if (state_q == ST_IDLE && layer_valid && layer_ready) begin
        layer_id_q <= layer_id;
        job_tag_q <= layer_job_tag;
        buffer_base_q <= layer_buffer_base;
        tile_index_q <= 0;
        completed_tiles <= 0;
        raw_words_read <= 0;
        pooled_words_written <= 0;
        fault_q <= layer_buffer_base[2:0] != 0 ||
                   !(layer_id == 1 || layer_id == 2 || layer_id == 5);
        pool_done_seen_q <= 1'b0;
        if (layer_buffer_base[2:0] != 0 ||
            !(layer_id == 1 || layer_id == 2 || layer_id == 5))
          state_q <= ST_FAILED;
        else
          state_q <= ST_POOL_DESC;
      end

      if (state_q == ST_POOL_DESC && pool_layer_valid && pool_layer_ready)
        state_q <= ST_READ_COMMAND;

      if (command_fire) begin
        dma_done_seen_q <= 1'b0;
        if (state_q == ST_READ_COMMAND) begin
          capture_index_q <= 0;
          state_q <= ST_READ_ARM;
        end else begin
          replay_fetch_index_q <= 0;
          replay_index_q <= 0;
          replay_valid_q <= 1'b0;
          state_q <= ST_WRITE_ARM;
        end
      end

      if (state_q == ST_READ_ARM && dma_armed)
        state_q <= ST_READ_STREAM;

      if (input_fire) begin
        raw_tile_buffer[capture_index_q] <= s_axis_tdata;
        capture_index_q <= capture_index_q + 1'b1;
        if (s_axis_tkeep != expected_input_keep ||
            s_axis_tlast != expected_input_last)
          fault_q <= 1'b1;
        if (expected_input_last) begin
          raw_words_read <= raw_words_read + raw_words_per_tile;
          if (dma_done_seen_q || dma_done)
            state_q <= ST_WRITE_COMMAND;
          else
            state_q <= ST_READ_DRAIN;
        end
      end

      if (state_q == ST_READ_DRAIN && dma_done) begin
        dma_done_seen_q <= 1'b0;
        state_q <= ST_WRITE_COMMAND;
      end

      if (state_q == ST_WRITE_ARM && dma_armed)
        state_q <= ST_REPLAY;

      if (state_q == ST_REPLAY &&
          (!replay_valid_q || replay_fire) &&
          replay_fetch_index_q < raw_beats_per_tile) begin
        replay_data_q <= raw_tile_buffer[replay_fetch_index_q];
        replay_index_q <= replay_fetch_index_q;
        replay_fetch_index_q <= replay_fetch_index_q + 1'b1;
        replay_valid_q <= 1'b1;
      end else if (replay_fire) begin
        replay_valid_q <= 1'b0;
      end

      if (output_fire && m_axis_tlast) begin
        pooled_words_written <= pooled_words_written + stored_words_per_tile;
        if (dma_done_seen_q || dma_done) begin
          completed_tiles <= completed_tiles + 1'b1;
          if (tile_index_q + 1'b1 == n8_tiles)
            state_q <= ST_LAYER_FINISH;
          else begin
            tile_index_q <= tile_index_q + 1'b1;
            state_q <= ST_READ_COMMAND;
          end
        end else begin
          state_q <= ST_WRITE_DRAIN;
        end
      end

      if (state_q == ST_WRITE_DRAIN && dma_done) begin
        completed_tiles <= completed_tiles + 1'b1;
        dma_done_seen_q <= 1'b0;
        if (tile_index_q + 1'b1 == n8_tiles)
          state_q <= ST_LAYER_FINISH;
        else begin
          tile_index_q <= tile_index_q + 1'b1;
          state_q <= ST_READ_COMMAND;
        end
      end

      if (state_q == ST_LAYER_FINISH &&
          (pool_done_seen_q || pool_layer_done)) begin
        if (pool_completed_layer_id != layer_id_q[2:0] ||
            pool_completed_job_tag != job_tag_q || pool_layer_error ||
            completed_tiles != n8_tiles)
          fault_q <= 1'b1;
        layer_done <= 1'b1;
        state_q <= ST_IDLE;
      end

      if (dma_error || pool_fault) begin
        fault_q <= 1'b1;
        state_q <= ST_FAILED;
      end
    end
  end

`ifndef SYNTHESIS
  always_ff @(posedge clk) begin
    if (!rst) begin
      if (command_fire && dma_command_s2mm &&
          tile_index_q + 1'b1 < n8_tiles &&
          stored_tile_offset + stored_bytes_per_tile >
          raw_tile_offset + raw_bytes_per_tile)
        $fatal(1, "in-place pooling write overtook unread raw data");
      if (input_fire && capture_index_q >= MAX_RAW_BEATS)
        $fatal(1, "in-place pooling tile buffer overflow");
    end
  end
`endif

endmodule
