`timescale 1ns/1ps

// Batch-one AlexNet work scheduler for the physical M8xN128 array.
//
// Conv1/2 use the split 2xM8xN64 mode.  Conv3..5 use an N16-aligned logical
// M8xN112 tile on the physical M8xN128 array.  FC6..8 use a
// single N16 bank so their sustained issue rate matches one 128-bit DDR read
// port.  FC6 is split into 4096/4096/1024 K chunks; the consumer must retain
// the accumulator until command_accum_final.
//
// This block deliberately describes work only.  Weight/activation DMA,
// patch assembly, accumulation and result retirement acknowledge each work
// descriptor through command_done/error.  Keeping this boundary explicit
// lets the functional graph replace the resource-probe generator without
// silently changing the batch-one bandwidth contract.
module alexnet_m8n126_graph_scheduler (
    input logic clk,
    input logic rst,

    input  logic start_valid,
    output logic start_ready,
    input  logic [15:0] start_tag,

    output logic command_valid,
    input  logic command_ready,
    output logic [3:0] command_layer_id,
    output logic command_is_fc,
    output logic command_mode_split_n64,
    output logic [7:0] command_bank_enable,
    output logic [15:0] command_n_lane_mask [0:7],
    output logic [15:0] command_n_base,
    output logic [7:0] command_n_count,
    output logic [12:0] command_m_base,
    output logic [4:0] command_m_count,
    output logic [3:0] command_group0_m_count,
    output logic [3:0] command_group1_m_count,
    output logic [13:0] command_k_offset,
    output logic [12:0] command_k_count,
    output logic command_accum_first,
    output logic command_accum_final,
    output logic command_weight_fill,
    output logic command_weight_release,
    output logic command_result_enable,
    output logic [15:0] command_context_tag,
    output logic [15:0] command_tile_tag,

    input logic command_done,
    input logic command_error,

    // Held after the final descriptor of layers 1..7.  The graph data path
    // acknowledges only after any required pooling/storage operation has
    // committed, so the next layer cannot observe an incomplete tensor.
    output logic layer_complete_valid,
    input  logic layer_complete_ready,
    output logic [3:0] layer_complete_id,
    output logic layer_complete_requires_pool,

    output logic busy,
    output logic inference_done,
    output logic inference_failed,
    output logic fault,
    output logic [3:0] active_layer_id,
    output logic [15:0] completed_commands
);

  typedef enum logic [2:0] {
    ST_IDLE,
    ST_ISSUE,
    ST_WAIT,
    ST_NEXT,
    ST_LAYER_WAIT,
    ST_COMPLETE,
    ST_FAILED
  } state_t;

  state_t state_q;
  logic [3:0] layer_q;
  logic [15:0] inference_tag_q;
  logic [15:0] n_base_q;
  logic [12:0] m_base_q;
  logic [13:0] k_offset_q;
  logic [15:0] tile_tag_q;

  logic [15:0] layer_n_total;
  logic [12:0] layer_m_total;
  logic [13:0] layer_k_total;
  logic [7:0] layer_n_tile;
  logic [4:0] layer_m_tile;
  logic [7:0] current_n_count;
  logic [4:0] current_m_count;
  logic [12:0] current_k_count;
  logic n_last;
  logic m_last;
  logic k_last;
  logic descriptor_valid;

  assign start_ready = state_q == ST_IDLE;
  assign command_valid = state_q == ST_ISSUE && descriptor_valid;
  assign busy = state_q != ST_IDLE;
  assign fault = state_q == ST_FAILED;
  assign active_layer_id = layer_q;
  assign layer_complete_valid = state_q == ST_LAYER_WAIT;
  assign layer_complete_id = layer_q;
  assign layer_complete_requires_pool = layer_q == 1 || layer_q == 2 ||
                                        layer_q == 5;

  always_comb begin
    layer_n_total = 0;
    layer_m_total = 0;
    layer_k_total = 0;
    layer_n_tile = 0;
    layer_m_tile = 0;
    case (layer_q)
      4'd1: begin
        layer_n_total = 64;   layer_m_total = 3025;
        layer_k_total = 363;  layer_n_tile = 64;  layer_m_tile = 16;
      end
      4'd2: begin
        layer_n_total = 192;  layer_m_total = 729;
        layer_k_total = 1600; layer_n_tile = 64;  layer_m_tile = 16;
      end
      4'd3: begin
        layer_n_total = 384;  layer_m_total = 169;
        layer_k_total = 1728; layer_n_tile = 112; layer_m_tile = 8;
      end
      4'd4: begin
        layer_n_total = 256;  layer_m_total = 169;
        layer_k_total = 3456; layer_n_tile = 112; layer_m_tile = 8;
      end
      4'd5: begin
        layer_n_total = 256;  layer_m_total = 169;
        layer_k_total = 2304; layer_n_tile = 112; layer_m_tile = 8;
      end
      4'd6: begin
        layer_n_total = 4096; layer_m_total = 1;
        layer_k_total = 9216; layer_n_tile = 16;  layer_m_tile = 1;
      end
      4'd7: begin
        layer_n_total = 4096; layer_m_total = 1;
        layer_k_total = 4096; layer_n_tile = 16;  layer_m_tile = 1;
      end
      4'd8: begin
        layer_n_total = 1000; layer_m_total = 1;
        layer_k_total = 4096; layer_n_tile = 16;  layer_m_tile = 1;
      end
      default: begin end
    endcase
  end

  always_comb begin
    descriptor_valid = layer_q >= 1 && layer_q <= 8;

    if (n_base_q + layer_n_tile >= layer_n_total)
      current_n_count = layer_n_total - n_base_q;
    else
      current_n_count = layer_n_tile;

    if (m_base_q + layer_m_tile >= layer_m_total)
      current_m_count = layer_m_total - m_base_q;
    else
      current_m_count = layer_m_tile;

    if (k_offset_q + 14'd4096 >= layer_k_total)
      current_k_count = layer_k_total - k_offset_q;
    else
      current_k_count = 13'd4096;

    n_last = n_base_q + current_n_count >= layer_n_total;
    m_last = m_base_q + current_m_count >= layer_m_total;
    k_last = k_offset_q + current_k_count >= layer_k_total;

    command_layer_id = layer_q;
    command_is_fc = layer_q >= 6;
    command_mode_split_n64 = layer_q == 1 || layer_q == 2;
    command_n_base = n_base_q;
    command_n_count = current_n_count;
    command_m_base = m_base_q;
    command_m_count = current_m_count;
    command_group0_m_count = current_m_count >= 8 ? 8 :
                                                     current_m_count[3:0];
    command_group1_m_count = command_mode_split_n64 &&
                             current_m_count > 8 ? current_m_count - 8 : 0;
    command_k_offset = k_offset_q;
    command_k_count = current_k_count;
    command_accum_first = k_offset_q == 0;
    command_accum_final = k_last;
    command_weight_fill = command_is_fc ||
                          (m_base_q == 0 && k_offset_q == 0);
    command_weight_release = command_is_fc || m_last;
    command_result_enable = k_last;
    command_context_tag = inference_tag_q ^
        {4'b0, layer_q, n_base_q[7:0]};
    command_tile_tag = tile_tag_q;

    command_bank_enable = 0;
    for (int bank = 0; bank < 8; bank++)
      command_n_lane_mask[bank] = 0;

    if (command_is_fc) begin
      // One external 128-bit read supplies exactly one N16 bank per cycle.
      command_bank_enable[0] = 1'b1;
      for (int lane = 0; lane < 16; lane++)
        command_n_lane_mask[0][lane] = lane < current_n_count;
    end else if (command_mode_split_n64) begin
      // The upper cluster computes the second M8 group with the same N64
      // weights.  The integration wrapper broadcasts each lower-cluster
      // N16 word into the corresponding upper-cluster bank.
      command_bank_enable = 8'hff;
      for (int bank = 0; bank < 4; bank++) begin
        for (int lane = 0; lane < 16; lane++) begin
          command_n_lane_mask[bank][lane] =
              16*bank + lane < current_n_count;
          command_n_lane_mask[bank+4][lane] =
              16*bank + lane < current_n_count;
        end
      end
    end else begin
      // N112 keeps every Conv3..5 descriptor and n_base on an N16 boundary.
      // Tail descriptors enable only the remaining whole N16 banks.
      for (int bank = 0; bank < 8; bank++) begin
        for (int lane = 0; lane < 16; lane++) begin
          command_n_lane_mask[bank][lane] =
              16*bank + lane < current_n_count;
        end
        command_bank_enable[bank] = |command_n_lane_mask[bank];
      end
    end
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      state_q <= ST_IDLE;
      layer_q <= 0;
      inference_tag_q <= 0;
      n_base_q <= 0;
      m_base_q <= 0;
      k_offset_q <= 0;
      tile_tag_q <= 0;
      completed_commands <= 0;
      inference_done <= 1'b0;
      inference_failed <= 1'b0;
    end else begin
      inference_done <= 1'b0;
      inference_failed <= 1'b0;
      case (state_q)
        ST_IDLE: if (start_valid && start_ready) begin
          layer_q <= 1;
          inference_tag_q <= start_tag;
          n_base_q <= 0;
          m_base_q <= 0;
          k_offset_q <= 0;
          tile_tag_q <= start_tag;
          completed_commands <= 0;
          state_q <= ST_ISSUE;
        end
        ST_ISSUE: if (command_valid && command_ready)
          state_q <= ST_WAIT;
        ST_WAIT: if (command_done) begin
          if (command_error) begin
            inference_failed <= 1'b1;
            state_q <= ST_FAILED;
          end else begin
            completed_commands <= completed_commands + 1'b1;
            state_q <= ST_NEXT;
          end
        end
        ST_NEXT: begin
          // All K chunks of one output tile own the same accumulator and tag.
          // Advance the tag only after the true final K chunk retires.
          if (k_last)
            tile_tag_q <= tile_tag_q + 1'b1;
          if (!k_last) begin
            k_offset_q <= k_offset_q + current_k_count;
          end else if (!m_last) begin
            k_offset_q <= 0;
            m_base_q <= m_base_q + current_m_count;
          end else if (!n_last) begin
            k_offset_q <= 0;
            m_base_q <= 0;
            n_base_q <= n_base_q + current_n_count;
          end else if (layer_q != 8) begin
            state_q <= ST_LAYER_WAIT;
          end else begin
            state_q <= ST_COMPLETE;
          end
          if (!(n_last && m_last && k_last))
            state_q <= ST_ISSUE;
        end
        ST_LAYER_WAIT: if (layer_complete_valid && layer_complete_ready) begin
          layer_q <= layer_q + 1'b1;
          k_offset_q <= 0;
          m_base_q <= 0;
          n_base_q <= 0;
          state_q <= ST_ISSUE;
        end
        ST_COMPLETE: begin
          inference_done <= 1'b1;
          state_q <= ST_IDLE;
        end
        ST_FAILED: state_q <= ST_FAILED;
        default: state_q <= ST_FAILED;
      endcase
    end
  end

`ifndef SYNTHESIS
  always_ff @(posedge clk) begin
    if (!rst) begin
      if (command_done && state_q != ST_WAIT)
        $fatal(1, "M8N126 graph scheduler received stray completion");
      if (command_valid && command_is_fc && command_bank_enable != 8'h01)
        $fatal(1, "batch-one FC must enable exactly one N16 bank");
      if (command_valid && !command_is_fc &&
          !command_mode_split_n64 && command_n_lane_mask[7][15:14] != 0)
        $fatal(1, "logical N126 mask enabled physical lanes 126/127");
      if (command_valid && !command_is_fc &&
          (command_n_base[3:0] != 0 || command_n_count[3:0] != 0))
        $fatal(1, "convolution N descriptor is not N16 aligned");
      if (command_valid && command_k_count == 0)
        $fatal(1, "M8N126 graph scheduler emitted zero K count");
    end
  end
`endif

endmodule
