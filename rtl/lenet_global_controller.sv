`timescale 1ns/1ps
// lenet_global_controller.sv -- fixed autonomous LeNet-5 layer sequencer.
//
// Operation order:
//   0 C1, 1 S2, 2 C3 pass0, 3 C3 pass1, 4 S4,
//   5 C5 pass0, 6 C5 pass1,
//   7 F6 pass0, 8 F6 pass1, 9 OUT.

module lenet_global_controller #(
  parameter int DIM_W          = 6,
  parameter int C_W            = 3,
  parameter int KOUT_W         = 9,
  parameter int WGT_ADDR_W     = 11,
  parameter int OUT_ADDR_W     = 16,
  parameter int OUT_CH_W       = 8,
  parameter int LAYER_ID_W     = 3,
  parameter int BANK_ADDR_W    = 9,
  parameter int PARAM_ADDR_W   = 8
) (
  input  logic clk,
  input  logic rst_n,
  input  logic start,
  input  logic model_valid,

  input  logic compute_busy,
  input  logic compute_done,
  input  logic pool_busy,
  input  logic pool_done,
  input  logic param_busy,
  input  logic param_done,

  output logic [1:0] owner,
  output logic       read_set,
  output logic       write_set,
  output logic       compute_start,
  output logic       pool_start,
  output logic       param_load_start,

  output logic                    cfg_fc_mode,
  output logic [DIM_W-1:0]        cfg_fmap_w,
  output logic [DIM_W-1:0]        cfg_fmap_h,
  output logic [C_W-1:0]          cfg_c_in,
  output logic [DIM_W-1:0]        cfg_out_w,
  output logic [DIM_W-1:0]        cfg_out_h,
  output logic [KOUT_W-1:0]       cfg_depth,
  output logic [WGT_ADDR_W-1:0]   weight_read_base,
  output logic [OUT_ADDR_W-1:0]   out_base_addr,
  output logic [OUT_ADDR_W-1:0]   out_plane_size,
  output logic [OUT_CH_W-1:0]     out_ch_base,
  output logic [OUT_CH_W-1:0]     out_channels,
  output logic [OUT_CH_W-1:0]     pass_channels,
  output logic [LAYER_ID_W-1:0]   layer_id,
  output logic                    relu_en,
  output logic [BANK_ADDR_W-1:0]  cfg_bank_base_word,

  output logic [DIM_W-1:0]        conv_width,
  output logic [DIM_W-1:0]        conv_height,
  output logic [OUT_CH_W-1:0]     conv_channels,
  output logic [BANK_ADDR_W-1:0]  conv_base_word,
  output logic [BANK_ADDR_W:0]    conv_plane_words,

  output logic                    fc_packed_layout,
  output logic [KOUT_W-1:0]       fc_length,
  output logic [OUT_CH_W-1:0]     fc_channels,
  output logic [KOUT_W-1:0]       fc_plane_bytes,
  output logic [BANK_ADDR_W-1:0]  fc_plane_words,
  output logic [BANK_ADDR_W-1:0]  fc_base_word,

  output logic [DIM_W-1:0]        pool_in_w,
  output logic [DIM_W-1:0]        pool_in_h,
  output logic [OUT_CH_W-1:0]     pool_channels,
  output logic [BANK_ADDR_W-1:0]  pool_in_base_word,
  output logic [BANK_ADDR_W-1:0]  pool_out_base_word,
  output logic [BANK_ADDR_W-1:0]  pool_in_plane_words,
  output logic [BANK_ADDR_W-1:0]  pool_out_plane_words,

  output logic [PARAM_ADDR_W-1:0] param_base,

  output logic                    busy,
  output logic                    done,
  output logic                    irq,
  output logic                    result_set,
  output logic [3:0]              op_index,
  output logic [31:0]             busy_cycles,
  output logic [31:0]             compute_cycles,
  output logic [31:0]             pool_cycles,
  output logic [31:0]             param_cycles
);

  typedef enum logic [2:0] {
    ST_IDLE,
    ST_PREPARE,
    ST_PARAM_WAIT,
    ST_COMPUTE_WAIT,
    ST_POOL_WAIT,
    ST_FINISH
  } state_t;

  state_t state_r;
  logic op_is_pool_c;
  assign op_is_pool_c = (op_index == 4'd1) || (op_index == 4'd4);

  always_comb begin
    owner = 2'd0;
    if ((state_r != ST_IDLE) && (state_r != ST_FINISH))
      owner = op_is_pool_c ? 2'd2 : 2'd1;
  end

  // Fixed memory and compute descriptors. All byte-plane sizes describe CHW
  // logical addresses; bank-base values describe compact physical bank words.
  always_comb begin
    read_set = 1'b0;
    write_set = 1'b1;

    cfg_fc_mode = 1'b0;
    cfg_fmap_w = DIM_W'(32);
    cfg_fmap_h = DIM_W'(32);
    cfg_c_in = C_W'(1);
    cfg_out_w = DIM_W'(28);
    cfg_out_h = DIM_W'(28);
    cfg_depth = KOUT_W'(25);
    weight_read_base = WGT_ADDR_W'(0);
    out_base_addr = '0;
    out_plane_size = OUT_ADDR_W'(784);
    out_ch_base = OUT_CH_W'(0);
    out_channels = OUT_CH_W'(6);
    pass_channels = OUT_CH_W'(6);
    layer_id = LAYER_ID_W'(0);
    relu_en = 1'b1;
    cfg_bank_base_word = BANK_ADDR_W'(0);

    conv_width = DIM_W'(32);
    conv_height = DIM_W'(32);
    conv_channels = OUT_CH_W'(1);
    conv_base_word = BANK_ADDR_W'(0);
    conv_plane_words = (BANK_ADDR_W+1)'(512);

    fc_packed_layout = 1'b0;
    fc_length = KOUT_W'(1);
    fc_channels = OUT_CH_W'(1);
    fc_plane_bytes = KOUT_W'(1);
    fc_plane_words = BANK_ADDR_W'(1);
    fc_base_word = BANK_ADDR_W'(0);

    pool_in_w = DIM_W'(28);
    pool_in_h = DIM_W'(28);
    pool_channels = OUT_CH_W'(6);
    pool_in_base_word = BANK_ADDR_W'(0);
    pool_out_base_word = BANK_ADDR_W'(0);
    pool_in_plane_words = BANK_ADDR_W'(392);
    pool_out_plane_words = BANK_ADDR_W'(98);

    param_base = PARAM_ADDR_W'(0);

    case (op_index)
      4'd0: begin
        // C1: 32x32x1 -> 28x28x6.
      end

      4'd1: begin
        // S2: 28x28x6 -> 14x14x6.
        read_set = 1'b1;
        write_set = 1'b0;
      end

      4'd2, 4'd3: begin
        // C3: two 8-channel passes, 14x14x6 -> 10x10x16.
        read_set = 1'b0;
        write_set = 1'b1;
        cfg_fmap_w = DIM_W'(14);
        cfg_fmap_h = DIM_W'(14);
        cfg_c_in = C_W'(6);
        cfg_out_w = DIM_W'(10);
        cfg_out_h = DIM_W'(10);
        cfg_depth = KOUT_W'(150);
        out_plane_size = OUT_ADDR_W'(100);
        out_channels = OUT_CH_W'(16);
        pass_channels = OUT_CH_W'(8);
        layer_id = LAYER_ID_W'(1);
        conv_width = DIM_W'(14);
        conv_height = DIM_W'(14);
        conv_channels = OUT_CH_W'(6);
        conv_plane_words = (BANK_ADDR_W+1)'(98);
        param_base = PARAM_ADDR_W'(6);
        if (op_index == 4'd2) begin
          weight_read_base = WGT_ADDR_W'(25);
          out_ch_base = OUT_CH_W'(0);
          cfg_bank_base_word = BANK_ADDR_W'(0);
        end else begin
          weight_read_base = WGT_ADDR_W'(175);
          out_ch_base = OUT_CH_W'(8);
          cfg_bank_base_word = BANK_ADDR_W'(50);
        end
      end

      4'd4: begin
        // S4: 10x10x16 -> 5x5x16.
        read_set = 1'b1;
        write_set = 1'b0;
        pool_in_w = DIM_W'(10);
        pool_in_h = DIM_W'(10);
        pool_channels = OUT_CH_W'(16);
        pool_in_plane_words = BANK_ADDR_W'(50);
        pool_out_plane_words = BANK_ADDR_W'(13);
      end

      4'd5, 4'd6: begin
        // C5 implemented as 400x120 FC, two 64-lane passes.
        read_set = 1'b0;
        write_set = 1'b1;
        cfg_fc_mode = 1'b1;
        cfg_depth = KOUT_W'(400);
        out_channels = OUT_CH_W'(120);
        layer_id = LAYER_ID_W'(2);
        fc_packed_layout = 1'b0;
        fc_length = KOUT_W'(400);
        fc_channels = OUT_CH_W'(16);
        fc_plane_bytes = KOUT_W'(25);
        fc_plane_words = BANK_ADDR_W'(13);
        param_base = PARAM_ADDR_W'(22);
        if (op_index == 4'd5) begin
          weight_read_base = WGT_ADDR_W'(325);
          out_ch_base = OUT_CH_W'(0);
          pass_channels = OUT_CH_W'(64);
          cfg_bank_base_word = BANK_ADDR_W'(0);
        end else begin
          weight_read_base = WGT_ADDR_W'(725);
          out_ch_base = OUT_CH_W'(64);
          pass_channels = OUT_CH_W'(56);
          cfg_bank_base_word = BANK_ADDR_W'(4);
        end
      end

      4'd7, 4'd8: begin
        // F6: 120x84 FC, two passes.
        read_set = 1'b1;
        write_set = 1'b0;
        cfg_fc_mode = 1'b1;
        cfg_depth = KOUT_W'(120);
        out_channels = OUT_CH_W'(84);
        layer_id = LAYER_ID_W'(3);
        fc_packed_layout = 1'b1;
        fc_length = KOUT_W'(120);
        fc_channels = OUT_CH_W'(0);
        fc_plane_bytes = KOUT_W'(0);
        fc_plane_words = BANK_ADDR_W'(0);
        param_base = PARAM_ADDR_W'(142);
        if (op_index == 4'd7) begin
          weight_read_base = WGT_ADDR_W'(1125);
          out_ch_base = OUT_CH_W'(0);
          pass_channels = OUT_CH_W'(64);
          cfg_bank_base_word = BANK_ADDR_W'(0);
        end else begin
          weight_read_base = WGT_ADDR_W'(1245);
          out_ch_base = OUT_CH_W'(64);
          pass_channels = OUT_CH_W'(20);
          cfg_bank_base_word = BANK_ADDR_W'(4);
        end
      end

      4'd9: begin
        // Output: 84x10 FC, signed logits without ReLU.
        read_set = 1'b0;
        write_set = 1'b1;
        cfg_fc_mode = 1'b1;
        cfg_depth = KOUT_W'(84);
        weight_read_base = WGT_ADDR_W'(1365);
        out_ch_base = OUT_CH_W'(0);
        out_channels = OUT_CH_W'(10);
        pass_channels = OUT_CH_W'(10);
        layer_id = LAYER_ID_W'(4);
        relu_en = 1'b0;
        cfg_bank_base_word = BANK_ADDR_W'(0);
        fc_packed_layout = 1'b1;
        fc_length = KOUT_W'(84);
        fc_channels = OUT_CH_W'(0);
        fc_plane_bytes = KOUT_W'(0);
        fc_plane_words = BANK_ADDR_W'(0);
        param_base = PARAM_ADDR_W'(226);
      end

      default: begin
      end
    endcase
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state_r <= ST_IDLE;
      op_index <= '0;
      compute_start <= 1'b0;
      pool_start <= 1'b0;
      param_load_start <= 1'b0;
      busy <= 1'b0;
      done <= 1'b0;
      irq <= 1'b0;
      result_set <= 1'b1;
      busy_cycles <= '0;
      compute_cycles <= '0;
      pool_cycles <= '0;
      param_cycles <= '0;
    end else begin
      compute_start <= 1'b0;
      pool_start <= 1'b0;
      param_load_start <= 1'b0;
      done <= 1'b0;
      irq <= 1'b0;

      if (busy)
        busy_cycles <= busy_cycles + 1'b1;
      if (compute_busy)
        compute_cycles <= compute_cycles + 1'b1;
      if (pool_busy)
        pool_cycles <= pool_cycles + 1'b1;
      if (param_busy)
        param_cycles <= param_cycles + 1'b1;

      case (state_r)
        ST_IDLE: begin
          if (start && model_valid) begin
            op_index <= 4'd0;
            busy <= 1'b1;
            result_set <= 1'b1;
            busy_cycles <= '0;
            compute_cycles <= '0;
            pool_cycles <= '0;
            param_cycles <= '0;
            state_r <= ST_PREPARE;
          end
        end

        ST_PREPARE: begin
          if (op_is_pool_c) begin
            pool_start <= 1'b1;
            state_r <= ST_POOL_WAIT;
          end else begin
            param_load_start <= 1'b1;
            state_r <= ST_PARAM_WAIT;
          end
        end

        ST_PARAM_WAIT: begin
          if (param_done) begin
            compute_start <= 1'b1;
            state_r <= ST_COMPUTE_WAIT;
          end
        end

        ST_COMPUTE_WAIT: begin
          if (compute_done) begin
            if (op_index == 4'd9)
              state_r <= ST_FINISH;
            else begin
              op_index <= op_index + 1'b1;
              state_r <= ST_PREPARE;
            end
          end
        end

        ST_POOL_WAIT: begin
          if (pool_done) begin
            op_index <= op_index + 1'b1;
            state_r <= ST_PREPARE;
          end
        end

        ST_FINISH: begin
          busy <= 1'b0;
          done <= 1'b1;
          irq <= 1'b1;
          state_r <= ST_IDLE;
        end

        default: state_r <= ST_IDLE;
      endcase
    end
  end

`ifdef SIMULATION
  assert property (@(posedge clk) disable iff (!rst_n)
      start |-> model_valid);
  assert property (@(posedge clk) disable iff (!rst_n)
      compute_start |-> ((owner == 2'd1) && !compute_busy &&
                         !param_busy && !op_is_pool_c));
  assert property (@(posedge clk) disable iff (!rst_n)
      pool_start |-> ((owner == 2'd2) && !pool_busy && op_is_pool_c));
  assert property (@(posedge clk) disable iff (!rst_n)
      param_load_start |-> (!param_busy && !op_is_pool_c));
  assert property (@(posedge clk) disable iff (!rst_n)
      busy |-> (op_index <= 4'd9));
`endif

endmodule
