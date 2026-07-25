`timescale 1ns/1ps
// lenet_compute_core.sv -- one physical compute/postprocess path for Conv+FC.

module lenet_compute_core #(
  parameter int DATA_W         = 8,
  parameter int ACC_W          = 32,
  parameter int NG             = 4,
  parameter int NC             = 8,
  parameter int K              = 5,
  parameter int MAX_C_IN       = 6,
  parameter int MAX_FMAP_W     = 32,
  parameter int MAX_FMAP_H     = 32,
  parameter int DIM_W          = $clog2(MAX_FMAP_W + 1),
  parameter int C_W            = $clog2(MAX_C_IN + 1),
  parameter int KOUT_W         = 9,
  parameter int MEM_DEPTH      = 2048,
  parameter int WGT_ADDR_W     = $clog2(MEM_DEPTH),
  parameter int OUT_ADDR_W     = 16,
  parameter int OUT_CH_W       = 8,
  parameter int LAYER_ID_W     = 3,
  parameter int SCALE_W        = 18,
  parameter int BANK_ADDR_W    = 9,
  parameter int LANE_COUNT     = 2 * NG * NC,
  parameter int LANE_ID_W      =
      (LANE_COUNT < 2) ? 1 : $clog2(LANE_COUNT)
) (
  input  logic clk,
  input  logic rst_n,
  input  logic en,
  input  logic start,
  input  logic cfg_fc_mode,

  input  logic [DIM_W-1:0] cfg_fmap_w,
  input  logic [DIM_W-1:0] cfg_fmap_h,
  input  logic [C_W-1:0]   cfg_c_in,
  input  logic [DIM_W-1:0] cfg_out_w,
  input  logic [DIM_W-1:0] cfg_out_h,
  input  logic [KOUT_W-1:0] cfg_depth,

  input  logic signed [DATA_W-1:0] pix_in,
  input  logic                    pix_valid,
  output logic                    pix_rd_en,

  input  logic                    weight_wr_en [0:NC-1],
  input  logic [WGT_ADDR_W-1:0]   weight_wr_addr,
  input  logic [2*NG*DATA_W-1:0]  weight_wr_data [0:NC-1],
  input  logic [WGT_ADDR_W-1:0]   weight_read_base,

  input  logic [OUT_ADDR_W-1:0] out_base_addr,
  input  logic [OUT_ADDR_W-1:0] out_plane_size,
  input  logic [OUT_CH_W-1:0]   out_ch_base,
  input  logic [OUT_CH_W-1:0]   out_channels,
  input  logic [OUT_CH_W-1:0]   pass_channels,
  input  logic [LAYER_ID_W-1:0] layer_id,

  input  logic                      param_wr_en,
  input  logic [LANE_ID_W-1:0]      param_wr_lane,
  input  logic signed [ACC_W-1:0]   param_wr_bias,
  input  logic signed [SCALE_W-1:0] param_wr_scale,
  input  logic                      relu_en,

  input  logic [BANK_ADDR_W-1:0] cfg_bank_base_word,
  input  logic                   bank_ready [0:NC-1],
  output logic                   bank_we [0:NC-1],
  output logic [BANK_ADDR_W-1:0] bank_word_addr [0:NC-1],
  output logic [15:0]            bank_wdata [0:NC-1],
  output logic [1:0]             bank_wstrb [0:NC-1],

  output logic signed [ACC_W-1:0] debug_acc_lo [0:NG-1][0:NC-1],
  output logic signed [ACC_W-1:0] debug_acc_hi [0:NG-1][0:NC-1],
  output logic [1:0]              debug_acc_valid [0:NG-1][0:NC-1],
  output logic                    busy,
  output logic                    done
);

  logic mode_fc_r;
  logic relu_r;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      mode_fc_r <= 1'b0;
      relu_r <= 1'b0;
    end else if (start) begin
      mode_fc_r <= cfg_fc_mode;
      relu_r <= relu_en;
    end
  end

  logic pipe_en;
  logic selected_router_ready;

  logic signed [DATA_W-1:0] conv_win_raw [0:2*NG-1];
  logic conv_valid_raw [0:NG-1];
  logic [1:0] conv_mask_raw [0:NG-1];
  logic conv_last_raw [0:NG-1];
  logic [KOUT_W-1:0] conv_k_raw;
  logic conv_pix_rd_en;
  logic conv_source_done;

  window_gen_runtime #(
    .ACT_W(DATA_W), .NG(NG), .NC(NC), .K(K),
    .MAX_C_IN(MAX_C_IN), .MAX_FMAP_W(MAX_FMAP_W),
    .MAX_FMAP_H(MAX_FMAP_H), .KOUT_W(KOUT_W)
  ) u_conv_window (
    .clk(clk), .rst_n(rst_n), .en(pipe_en),
    .start(start && !cfg_fc_mode),
    .cfg_fmap_w(cfg_fmap_w), .cfg_fmap_h(cfg_fmap_h),
    .cfg_c_in(cfg_c_in), .cfg_out_w(cfg_out_w),
    .cfg_out_h(cfg_out_h), .pix_in(pix_in), .pix_valid(pix_valid),
    .pix_rd_en(conv_pix_rd_en), .win_q(conv_win_raw),
    .pair_valid(conv_valid_raw), .lane_mask(conv_mask_raw),
    .depth_last(conv_last_raw), .k_out(conv_k_raw),
    .done(conv_source_done)
  );

  logic signed [DATA_W-1:0] fc_activation_raw;
  logic fc_valid_raw;
  logic fc_last_raw;
  logic [KOUT_W-1:0] fc_k_raw;
  logic fc_pix_rd_en;
  logic fc_source_done;

  fc_vector_gen #(
    .ACT_W(DATA_W), .KOUT_W(KOUT_W)
  ) u_fc_vector (
    .clk(clk), .rst_n(rst_n), .en(pipe_en),
    .start(start && cfg_fc_mode), .cfg_depth(cfg_depth),
    .pix_in(pix_in), .pix_valid(pix_valid),
    .pix_rd_en(fc_pix_rd_en), .activation(fc_activation_raw),
    .act_valid(fc_valid_raw), .depth_last(fc_last_raw),
    .k_out(fc_k_raw), .source_done(fc_source_done)
  );

  assign pix_rd_en = mode_fc_r ? fc_pix_rd_en : conv_pix_rd_en;

  logic selected_raw_valid;
  logic selected_raw_last;
  logic [KOUT_W-1:0] selected_raw_k;
  always_comb begin
    if (mode_fc_r) begin
      selected_raw_valid = fc_valid_raw;
      selected_raw_last = fc_last_raw;
      selected_raw_k = fc_k_raw;
    end else begin
      selected_raw_valid = conv_valid_raw[0];
      selected_raw_last = conv_last_raw[0];
      selected_raw_k = conv_k_raw;
    end
  end

  logic signed [DATA_W-1:0] conv_src_win [0:2*NG-1];
  logic conv_src_valid [0:NG-1];
  logic [1:0] conv_src_mask [0:NG-1];
  logic conv_src_last [0:NG-1];
  logic signed [DATA_W-1:0] fc_src_activation;
  logic fc_src_valid;
  logic fc_src_last;
  logic [KOUT_W-1:0] src_k_r;

  always_ff @(posedge clk) begin
    if (!rst_n || start) begin
      src_k_r <= '0;
      fc_src_activation <= '0;
      fc_src_valid <= 1'b0;
      fc_src_last <= 1'b0;
      for (int i = 0; i < 2 * NG; i++) conv_src_win[i] <= '0;
      for (int g = 0; g < NG; g++) begin
        conv_src_valid[g] <= 1'b0;
        conv_src_mask[g] <= '0;
        conv_src_last[g] <= 1'b0;
      end
    end else if (pipe_en) begin
      src_k_r <= selected_raw_k;
      fc_src_activation <= fc_activation_raw;
      fc_src_valid <= fc_valid_raw;
      fc_src_last <= fc_last_raw;
      for (int i = 0; i < 2 * NG; i++)
        conv_src_win[i] <= conv_win_raw[i];
      for (int g = 0; g < NG; g++) begin
        conv_src_valid[g] <= conv_valid_raw[g];
        conv_src_mask[g] <= conv_mask_raw[g];
        conv_src_last[g] <= conv_last_raw[g];
      end
    end
  end

  logic signed [DATA_W-1:0] conv_weight [0:NC-1];
  logic signed [DATA_W-1:0] fc_weight_lo [0:NG-1][0:NC-1];
  logic signed [DATA_W-1:0] fc_weight_hi [0:NG-1][0:NC-1];
  logic weight_valid;
  logic weight_last;
  logic [KOUT_W-1:0] weight_k;

  dual_mode_weight_buffer #(
    .WGT_W(DATA_W), .NG(NG), .NC(NC),
    .MEM_DEPTH(MEM_DEPTH), .ADDR_W(WGT_ADDR_W), .KOUT_W(KOUT_W)
  ) u_weight_buffer (
    .clk(clk), .rst_n(rst_n), .en(pipe_en),
    .wr_en(weight_wr_en), .wr_addr(weight_wr_addr),
    .wr_data(weight_wr_data), .k_valid(selected_raw_valid),
    .k_out(selected_raw_k), .depth_last_in(selected_raw_last),
    .read_base_addr(weight_read_base), .conv_weight(conv_weight),
    .fc_weight_lo(fc_weight_lo), .fc_weight_hi(fc_weight_hi),
    .weight_valid(weight_valid), .weight_depth_last(weight_last),
    .weight_k_out(weight_k)
  );

  logic signed [DATA_W-1:0] conv_act_lo_skew [0:NG-1];
  logic signed [DATA_W-1:0] conv_act_hi_skew [0:NG-1];
  logic conv_valid_skew [0:NG-1];
  logic [1:0] conv_mask_skew [0:NG-1];
  logic conv_last_skew [0:NG-1];
  logic signed [DATA_W-1:0] conv_weight_skew [0:NC-1];
  logic conv_weight_valid_skew [0:NC-1];
  logic conv_weight_last_skew [0:NC-1];

  skew_buf #(
    .ACT_W(DATA_W), .WGT_W(DATA_W), .NG(NG), .NC(NC)
  ) u_conv_skew (
    .clk(clk), .rst_n(rst_n), .en(pipe_en),
    .win_q(conv_src_win), .pair_valid_in(conv_src_valid),
    .lane_mask_in(conv_src_mask), .depth_last_in(conv_src_last),
    .weight_q(conv_weight), .weight_valid_in(weight_valid),
    .weight_depth_last_in(weight_last),
    .act_lo_out(conv_act_lo_skew), .act_hi_out(conv_act_hi_skew),
    .pair_valid_out(conv_valid_skew), .lane_mask_out(conv_mask_skew),
    .depth_last_out(conv_last_skew), .weight_out(conv_weight_skew),
    .weight_valid_out(conv_weight_valid_skew),
    .weight_depth_last_out(conv_weight_last_skew)
  );

  logic [1:0] fc_lane_mask_c [0:NG-1][0:NC-1];
  always_comb begin
    for (int g = 0; g < NG; g++) begin
      for (int c = 0; c < NC; c++) begin
        int filter_lo;
        filter_lo = int'(out_ch_base) + g * (2 * NC) + 2 * c;
        fc_lane_mask_c[g][c][0] =
            (filter_lo < int'(out_channels));
        fc_lane_mask_c[g][c][1] =
            (filter_lo + 1 < int'(out_channels));
      end
    end
  end

  logic signed [DATA_W-1:0] fc_activation_skew [0:NG-1];
  logic signed [DATA_W-1:0] fc_weight_lo_skew [0:NG-1][0:NC-1];
  logic signed [DATA_W-1:0] fc_weight_hi_skew [0:NG-1][0:NC-1];
  logic fc_valid_skew [0:NG-1];
  logic fc_last_skew [0:NG-1];
  logic [1:0] fc_mask_skew [0:NG-1][0:NC-1];

  fc_group_skew #(
    .DATA_W(DATA_W), .NG(NG), .NC(NC)
  ) u_fc_skew (
    .clk(clk), .rst_n(rst_n), .en(pipe_en),
    .activation_in(fc_src_activation),
    .weight_lo_in(fc_weight_lo), .weight_hi_in(fc_weight_hi),
    .valid_in(fc_src_valid && weight_valid),
    .depth_last_in(fc_src_last && weight_last),
    .lane_mask_in(fc_lane_mask_c),
    .activation_out(fc_activation_skew),
    .weight_lo_out(fc_weight_lo_skew),
    .weight_hi_out(fc_weight_hi_skew),
    .valid_out(fc_valid_skew), .depth_last_out(fc_last_skew),
    .lane_mask_out(fc_mask_skew)
  );

  sa_packed_dual_mode #(
    .DATA_W(DATA_W), .ACC_W(ACC_W), .NG(NG), .NC(NC)
  ) u_sa (
    .clk(clk), .rst_n(rst_n), .en(pipe_en), .fc_mode(mode_fc_r),
    .conv_act_lo(conv_act_lo_skew), .conv_act_hi(conv_act_hi_skew),
    .conv_valid(conv_valid_skew), .conv_mask(conv_mask_skew),
    .conv_last(conv_last_skew), .conv_weight(conv_weight_skew),
    .fc_activation(fc_activation_skew),
    .fc_weight_lo(fc_weight_lo_skew), .fc_weight_hi(fc_weight_hi_skew),
    .fc_valid(fc_valid_skew), .fc_mask(fc_mask_skew),
    .fc_last(fc_last_skew),
    .acc_lo_out(debug_acc_lo), .acc_hi_out(debug_acc_hi),
    .acc_valid(debug_acc_valid)
  );

  logic [1:0] conv_acc_valid [0:NG-1][0:NC-1];
  logic [1:0] fc_acc_valid [0:NG-1][0:NC-1];
  always_comb begin
    for (int g = 0; g < NG; g++)
      for (int c = 0; c < NC; c++) begin
        conv_acc_valid[g][c] =
            mode_fc_r ? 2'b00 : debug_acc_valid[g][c];
        fc_acc_valid[g][c] =
            mode_fc_r ? debug_acc_valid[g][c] : 2'b00;
      end
  end

  logic conv_router_ready;
  logic conv_router_idle;
  logic conv_routed_valid [0:NC-1];
  logic conv_routed_ready [0:NC-1];
  logic signed [ACC_W-1:0] conv_routed_lo [0:NC-1];
  logic signed [ACC_W-1:0] conv_routed_hi [0:NC-1];
  logic [1:0] conv_routed_mask [0:NC-1];
  logic [OUT_ADDR_W-1:0] conv_routed_addr_lo [0:NC-1];
  logic [OUT_ADDR_W-1:0] conv_routed_addr_hi [0:NC-1];
  logic [OUT_CH_W-1:0] conv_routed_ch_lo [0:NC-1];
  logic [OUT_CH_W-1:0] conv_routed_ch_hi [0:NC-1];
  logic [$clog2(NG)-1:0] conv_routed_group [0:NC-1];
  logic conv_routed_fc [0:NC-1];
  logic [LAYER_ID_W-1:0] conv_routed_layer [0:NC-1];

  column_result_router_runtime #(
    .ACC_W(ACC_W), .NG(NG), .NC(NC), .DIM_W(DIM_W),
    .OUT_ADDR_W(OUT_ADDR_W), .OUT_CH_W(OUT_CH_W),
    .LAYER_ID_W(LAYER_ID_W)
  ) u_conv_router (
    .clk(clk), .rst_n(rst_n), .start(start && !cfg_fc_mode),
    .advance_in(pipe_en && !mode_fc_r),
    .issue_last(conv_src_last[0]), .issue_lane_mask(conv_src_mask),
    .cfg_out_w(cfg_out_w), .cfg_out_h(cfg_out_h),
    .cfg_out_plane_size(out_plane_size),
    .cfg_out_base_addr(out_base_addr), .cfg_out_ch_base(out_ch_base),
    .cfg_pass_channels(pass_channels), .cfg_layer_id(layer_id),
    .acc_lo_in(debug_acc_lo), .acc_hi_in(debug_acc_hi),
    .acc_valid_in(conv_acc_valid), .ingress_ready(conv_router_ready),
    .idle(conv_router_idle), .result_valid(conv_routed_valid),
    .result_ready(conv_routed_ready), .result_acc_lo(conv_routed_lo),
    .result_acc_hi(conv_routed_hi),
    .result_lane_mask(conv_routed_mask),
    .result_addr_lo(conv_routed_addr_lo),
    .result_addr_hi(conv_routed_addr_hi),
    .result_channel_lo(conv_routed_ch_lo),
    .result_channel_hi(conv_routed_ch_hi),
    .result_group(conv_routed_group),
    .result_fc_mode(conv_routed_fc),
    .result_layer_id(conv_routed_layer)
  );

  logic fc_router_ready;
  logic fc_router_idle;
  logic fc_routed_valid [0:NC-1];
  logic fc_routed_ready [0:NC-1];
  logic signed [ACC_W-1:0] fc_routed_lo [0:NC-1];
  logic signed [ACC_W-1:0] fc_routed_hi [0:NC-1];
  logic [1:0] fc_routed_mask [0:NC-1];
  logic [OUT_ADDR_W-1:0] fc_routed_addr_lo [0:NC-1];
  logic [OUT_ADDR_W-1:0] fc_routed_addr_hi [0:NC-1];
  logic [OUT_CH_W-1:0] fc_routed_ch_lo [0:NC-1];
  logic [OUT_CH_W-1:0] fc_routed_ch_hi [0:NC-1];
  logic [$clog2(NG)-1:0] fc_routed_group [0:NC-1];
  logic fc_routed_fc [0:NC-1];
  logic [LAYER_ID_W-1:0] fc_routed_layer [0:NC-1];

  fc_result_router #(
    .ACC_W(ACC_W), .NG(NG), .NC(NC),
    .OUT_ADDR_W(OUT_ADDR_W), .OUT_CH_W(OUT_CH_W),
    .LAYER_ID_W(LAYER_ID_W)
  ) u_fc_router (
    .clk(clk), .rst_n(rst_n), .start(start && cfg_fc_mode),
    .advance_in(pipe_en && mode_fc_r),
    .cfg_out_base_addr(out_base_addr), .cfg_out_ch_base(out_ch_base),
    .cfg_out_channels(out_channels), .cfg_layer_id(layer_id),
    .acc_lo_in(debug_acc_lo), .acc_hi_in(debug_acc_hi),
    .acc_valid_in(fc_acc_valid), .ingress_ready(fc_router_ready),
    .idle(fc_router_idle), .result_valid(fc_routed_valid),
    .result_ready(fc_routed_ready), .result_acc_lo(fc_routed_lo),
    .result_acc_hi(fc_routed_hi), .result_lane_mask(fc_routed_mask),
    .result_addr_lo(fc_routed_addr_lo),
    .result_addr_hi(fc_routed_addr_hi),
    .result_channel_lo(fc_routed_ch_lo),
    .result_channel_hi(fc_routed_ch_hi),
    .result_group(fc_routed_group), .result_fc_mode(fc_routed_fc),
    .result_layer_id(fc_routed_layer)
  );

  logic selected_valid [0:NC-1];
  logic selected_ready [0:NC-1];
  logic signed [ACC_W-1:0] selected_acc_lo [0:NC-1];
  logic signed [ACC_W-1:0] selected_acc_hi [0:NC-1];
  logic [1:0] selected_mask [0:NC-1];
  logic [OUT_ADDR_W-1:0] selected_addr_lo [0:NC-1];
  logic [OUT_ADDR_W-1:0] selected_addr_hi [0:NC-1];
  logic [OUT_CH_W-1:0] selected_ch_lo [0:NC-1];
  logic [OUT_CH_W-1:0] selected_ch_hi [0:NC-1];
  logic [$clog2(NG)-1:0] selected_group [0:NC-1];
  logic selected_fc [0:NC-1];
  logic [LAYER_ID_W-1:0] selected_layer [0:NC-1];

  always_comb begin
    selected_router_ready =
        mode_fc_r ? fc_router_ready : conv_router_ready;
    for (int c = 0; c < NC; c++) begin
      conv_routed_ready[c] = mode_fc_r ? 1'b1 : selected_ready[c];
      fc_routed_ready[c] = mode_fc_r ? selected_ready[c] : 1'b1;
      if (mode_fc_r) begin
        selected_valid[c] = fc_routed_valid[c];
        selected_acc_lo[c] = fc_routed_lo[c];
        selected_acc_hi[c] = fc_routed_hi[c];
        selected_mask[c] = fc_routed_mask[c];
        selected_addr_lo[c] = fc_routed_addr_lo[c];
        selected_addr_hi[c] = fc_routed_addr_hi[c];
        selected_ch_lo[c] = fc_routed_ch_lo[c];
        selected_ch_hi[c] = fc_routed_ch_hi[c];
        selected_group[c] = fc_routed_group[c];
        selected_fc[c] = fc_routed_fc[c];
        selected_layer[c] = fc_routed_layer[c];
      end else begin
        selected_valid[c] = conv_routed_valid[c];
        selected_acc_lo[c] = conv_routed_lo[c];
        selected_acc_hi[c] = conv_routed_hi[c];
        selected_mask[c] = conv_routed_mask[c];
        selected_addr_lo[c] = conv_routed_addr_lo[c];
        selected_addr_hi[c] = conv_routed_addr_hi[c];
        selected_ch_lo[c] = conv_routed_ch_lo[c];
        selected_ch_hi[c] = conv_routed_ch_hi[c];
        selected_group[c] = conv_routed_group[c];
        selected_fc[c] = conv_routed_fc[c];
        selected_layer[c] = conv_routed_layer[c];
      end
    end
  end

  logic pp_valid [0:NC-1];
  logic pp_ready [0:NC-1];
  logic [15:0] pp_data [0:NC-1];
  logic [1:0] pp_mask [0:NC-1];
  logic [OUT_ADDR_W-1:0] pp_addr_lo [0:NC-1];
  logic [OUT_ADDR_W-1:0] pp_addr_hi [0:NC-1];
  logic [OUT_CH_W-1:0] pp_ch_lo [0:NC-1];
  logic [OUT_CH_W-1:0] pp_ch_hi [0:NC-1];
  logic [$clog2(NG)-1:0] pp_group [0:NC-1];
  logic pp_fc [0:NC-1];
  logic [LAYER_ID_W-1:0] pp_layer [0:NC-1];
  logic postprocess_idle;

  postprocess_array #(
    .ACC_W(ACC_W), .NG(NG), .NC(NC), .SCALE_W(SCALE_W),
    .OUT_ADDR_W(OUT_ADDR_W), .OUT_CH_W(OUT_CH_W),
    .LAYER_ID_W(LAYER_ID_W)
  ) u_postprocess (
    .clk(clk), .rst_n(rst_n), .flush(start),
    .param_wr_en(param_wr_en), .param_wr_lane(param_wr_lane),
    .param_wr_bias(param_wr_bias), .param_wr_scale(param_wr_scale),
    .cfg_relu_en(relu_r),
    .in_valid(selected_valid), .in_ready(selected_ready),
    .in_acc_lo(selected_acc_lo), .in_acc_hi(selected_acc_hi),
    .in_lane_mask(selected_mask),
    .in_addr_lo(selected_addr_lo), .in_addr_hi(selected_addr_hi),
    .in_channel_lo(selected_ch_lo), .in_channel_hi(selected_ch_hi),
    .in_group(selected_group), .in_fc_mode(selected_fc),
    .in_layer_id(selected_layer), .out_valid(pp_valid),
    .out_ready(pp_ready), .out_data(pp_data),
    .out_lane_mask(pp_mask), .out_addr_lo(pp_addr_lo),
    .out_addr_hi(pp_addr_hi), .out_channel_lo(pp_ch_lo),
    .out_channel_hi(pp_ch_hi), .out_group(pp_group),
    .out_fc_mode(pp_fc), .out_layer_id(pp_layer),
    .idle(postprocess_idle)
  );

  banked_activation_writer #(
    .NC(NC), .BYTE_ADDR_W(OUT_ADDR_W), .WORD_ADDR_W(BANK_ADDR_W)
  ) u_writer (
    .clk(clk), .rst_n(rst_n), .start(start),
    .cfg_bank_base_word(cfg_bank_base_word),
    .in_valid(pp_valid), .in_ready(pp_ready),
    .in_data(pp_data), .in_lane_mask(pp_mask),
    .in_addr_lo(pp_addr_lo), .in_addr_hi(pp_addr_hi),
    .bank_we(bank_we), .bank_ready(bank_ready),
    .bank_word_addr(bank_word_addr), .bank_wdata(bank_wdata),
    .bank_wstrb(bank_wstrb)
  );

  assign pipe_en = en && selected_router_ready;

  logic source_done_pending_r;
  logic [15:0] write_lane_count_r;
  logic [15:0] expected_lane_count_r;
  logic [OUT_ADDR_W+$clog2(NC+1)-1:0] conv_expected_lanes_c;
  logic [4:0] lane_add_c;
  logic selected_router_idle;
  logic selected_source_done;
  always_comb begin
    lane_add_c = '0;
    conv_expected_lanes_c = '0;
    for (int c = 0; c < NC; c++)
      if (bank_we[c])
        lane_add_c += bank_wstrb[c][0] + bank_wstrb[c][1];
    // Conv pass count is plane_size repeated once per active output
    // channel. Express it as a short adder chain so control bookkeeping
    // cannot consume a 49th DSP.
    for (int c = 0; c < NC; c++)
      if (OUT_CH_W'(c) < pass_channels)
        conv_expected_lanes_c += out_plane_size;
    selected_router_idle =
        mode_fc_r ? fc_router_idle : conv_router_idle;
    selected_source_done =
        mode_fc_r ? fc_source_done : conv_source_done;
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      source_done_pending_r <= 1'b0;
      write_lane_count_r <= '0;
      expected_lane_count_r <= '0;
      busy <= 1'b0;
      done <= 1'b0;
    end else begin
      done <= 1'b0;
      if (start) begin
        source_done_pending_r <= 1'b0;
        write_lane_count_r <= '0;
        if (cfg_fc_mode) begin
          if (out_channels > out_ch_base + OUT_CH_W'(LANE_COUNT))
            expected_lane_count_r <= 16'(LANE_COUNT);
          else
            expected_lane_count_r <=
                16'(out_channels - out_ch_base);
        end else begin
          expected_lane_count_r <=
              conv_expected_lanes_c[15:0];
        end
        busy <= 1'b1;
      end else begin
        if (selected_source_done)
          source_done_pending_r <= 1'b1;
        if (lane_add_c != 0)
          write_lane_count_r <= write_lane_count_r + lane_add_c;
        if (source_done_pending_r &&
            (write_lane_count_r >= expected_lane_count_r) &&
            selected_router_idle && postprocess_idle) begin
          source_done_pending_r <= 1'b0;
          busy <= 1'b0;
          done <= 1'b1;
        end
      end
    end
  end

`ifdef SIMULATION
  assert property (@(posedge clk) disable iff (!rst_n)
      start |-> (!busy && (pass_channels != 0)));
  assert property (@(posedge clk) disable iff (!rst_n)
      pipe_en |-> (weight_valid ==
                   (mode_fc_r ? fc_src_valid : conv_src_valid[0])));
  assert property (@(posedge clk) disable iff (!rst_n)
      (pipe_en && weight_valid) |-> (weight_k == src_k_r));
`endif

endmodule
