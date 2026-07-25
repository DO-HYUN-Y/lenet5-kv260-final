`timescale 1ns/1ps
// fc_stream_datapath.sv -- 64-output-lane FC mode using the shared 32 PPEs.

module fc_stream_datapath #(
  parameter int DATA_W        = 8,
  parameter int ACC_W         = 32,
  parameter int NG            = 4,
  parameter int NC            = 8,
  parameter int MEM_DEPTH     = 2048,
  parameter int WGT_ADDR_W    = $clog2(MEM_DEPTH),
  parameter int KOUT_W        = 9,
  parameter int OUT_ADDR_W    = 16,
  parameter int OUT_CH_W      = 8,
  parameter int LAYER_ID_W    = 3,
  parameter int SCALE_W       = 18,
  parameter int BANK_ADDR_W   = 9,
  parameter int LANE_COUNT    = 2 * NG * NC,
  parameter int LANE_ID_W     =
      (LANE_COUNT < 2) ? 1 : $clog2(LANE_COUNT)
) (
  input  logic clk,
  input  logic rst_n,
  input  logic en,
  input  logic start,

  input  logic signed [DATA_W-1:0] pix_in,
  input  logic                    pix_valid,
  output logic                    pix_rd_en,

  input  logic                    weight_wr_en [0:NC-1],
  input  logic [WGT_ADDR_W-1:0]   weight_wr_addr,
  input  logic [2*NG*DATA_W-1:0]  weight_wr_data [0:NC-1],
  input  logic [WGT_ADDR_W-1:0]   weight_read_base,
  input  logic [KOUT_W-1:0]       cfg_depth,

  input  logic [OUT_ADDR_W-1:0] out_base_addr,
  input  logic [OUT_CH_W-1:0]   out_ch_base,
  input  logic [OUT_CH_W-1:0]   out_channels,
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

  output logic busy,
  output logic done
);

  logic pipe_en;
  logic router_ingress_ready;
  logic router_idle;
  logic postprocess_idle;

  logic signed [DATA_W-1:0] raw_activation;
  logic raw_valid;
  logic raw_last;
  logic [KOUT_W-1:0] raw_k;
  logic source_done;

  fc_vector_gen #(
    .ACT_W(DATA_W), .KOUT_W(KOUT_W)
  ) u_vector_gen (
    .clk(clk), .rst_n(rst_n), .en(pipe_en), .start(start),
    .cfg_depth(cfg_depth), .pix_in(pix_in), .pix_valid(pix_valid),
    .pix_rd_en(pix_rd_en), .activation(raw_activation),
    .act_valid(raw_valid), .depth_last(raw_last), .k_out(raw_k),
    .source_done(source_done)
  );

  logic signed [DATA_W-1:0] src_activation_r;
  logic src_valid_r;
  logic src_last_r;
  logic [KOUT_W-1:0] src_k_r;
  logic signed [DATA_W-1:0] conv_weight_unused [0:NC-1];
  logic signed [DATA_W-1:0] fc_weight_lo [0:NG-1][0:NC-1];
  logic signed [DATA_W-1:0] fc_weight_hi [0:NG-1][0:NC-1];
  logic weight_valid;
  logic weight_last;
  logic [KOUT_W-1:0] weight_k;

  always_ff @(posedge clk) begin
    if (!rst_n || start) begin
      src_activation_r <= '0;
      src_valid_r <= 1'b0;
      src_last_r <= 1'b0;
      src_k_r <= '0;
    end else if (pipe_en) begin
      src_activation_r <= raw_activation;
      src_valid_r <= raw_valid;
      src_last_r <= raw_last;
      src_k_r <= raw_k;
    end
  end

  dual_mode_weight_buffer #(
    .WGT_W(DATA_W), .NG(NG), .NC(NC),
    .MEM_DEPTH(MEM_DEPTH), .ADDR_W(WGT_ADDR_W), .KOUT_W(KOUT_W)
  ) u_weight_buffer (
    .clk(clk), .rst_n(rst_n), .en(pipe_en),
    .wr_en(weight_wr_en), .wr_addr(weight_wr_addr),
    .wr_data(weight_wr_data), .k_valid(raw_valid), .k_out(raw_k),
    .depth_last_in(raw_last), .read_base_addr(weight_read_base),
    .conv_weight(conv_weight_unused),
    .fc_weight_lo(fc_weight_lo), .fc_weight_hi(fc_weight_hi),
    .weight_valid(weight_valid), .weight_depth_last(weight_last),
    .weight_k_out(weight_k)
  );

  logic [1:0] fc_lane_mask_c [0:NG-1][0:NC-1];
  always_comb begin
    for (int g = 0; g < NG; g++) begin
      for (int c = 0; c < NC; c++) begin
        int filter_lo;
        filter_lo = int'(out_ch_base) + g * (2 * NC) + 2 * c;
        fc_lane_mask_c[g][c][0] = (filter_lo < int'(out_channels));
        fc_lane_mask_c[g][c][1] = (filter_lo + 1 < int'(out_channels));
      end
    end
  end

  logic signed [DATA_W-1:0] skew_activation [0:NG-1];
  logic signed [DATA_W-1:0] skew_weight_lo [0:NG-1][0:NC-1];
  logic signed [DATA_W-1:0] skew_weight_hi [0:NG-1][0:NC-1];
  logic skew_valid [0:NG-1];
  logic skew_last [0:NG-1];
  logic [1:0] skew_mask [0:NG-1][0:NC-1];

  fc_group_skew #(
    .DATA_W(DATA_W), .NG(NG), .NC(NC)
  ) u_fc_skew (
    .clk(clk), .rst_n(rst_n), .en(pipe_en),
    .activation_in(src_activation_r),
    .weight_lo_in(fc_weight_lo), .weight_hi_in(fc_weight_hi),
    .valid_in(src_valid_r && weight_valid),
    .depth_last_in(src_last_r && weight_last),
    .lane_mask_in(fc_lane_mask_c),
    .activation_out(skew_activation),
    .weight_lo_out(skew_weight_lo), .weight_hi_out(skew_weight_hi),
    .valid_out(skew_valid), .depth_last_out(skew_last),
    .lane_mask_out(skew_mask)
  );

  logic signed [DATA_W-1:0] zero_conv_act [0:NG-1];
  logic zero_conv_valid [0:NG-1];
  logic [1:0] zero_conv_mask [0:NG-1];
  logic zero_conv_last [0:NG-1];
  logic signed [DATA_W-1:0] zero_conv_weight [0:NC-1];
  always_comb begin
    for (int g = 0; g < NG; g++) begin
      zero_conv_act[g] = '0;
      zero_conv_valid[g] = 1'b0;
      zero_conv_mask[g] = '0;
      zero_conv_last[g] = 1'b0;
    end
    for (int c = 0; c < NC; c++) zero_conv_weight[c] = '0;
  end

  logic signed [ACC_W-1:0] acc_lo [0:NG-1][0:NC-1];
  logic signed [ACC_W-1:0] acc_hi [0:NG-1][0:NC-1];
  logic [1:0] acc_valid [0:NG-1][0:NC-1];

  sa_packed_dual_mode #(
    .DATA_W(DATA_W), .ACC_W(ACC_W), .NG(NG), .NC(NC)
  ) u_sa (
    .clk(clk), .rst_n(rst_n), .en(pipe_en), .fc_mode(1'b1),
    .conv_act_lo(zero_conv_act), .conv_act_hi(zero_conv_act),
    .conv_valid(zero_conv_valid), .conv_mask(zero_conv_mask),
    .conv_last(zero_conv_last), .conv_weight(zero_conv_weight),
    .fc_activation(skew_activation),
    .fc_weight_lo(skew_weight_lo), .fc_weight_hi(skew_weight_hi),
    .fc_valid(skew_valid), .fc_mask(skew_mask), .fc_last(skew_last),
    .acc_lo_out(acc_lo), .acc_hi_out(acc_hi), .acc_valid(acc_valid)
  );

  logic routed_valid [0:NC-1];
  logic routed_ready [0:NC-1];
  logic signed [ACC_W-1:0] routed_acc_lo [0:NC-1];
  logic signed [ACC_W-1:0] routed_acc_hi [0:NC-1];
  logic [1:0] routed_mask [0:NC-1];
  logic [OUT_ADDR_W-1:0] routed_addr_lo [0:NC-1];
  logic [OUT_ADDR_W-1:0] routed_addr_hi [0:NC-1];
  logic [OUT_CH_W-1:0] routed_channel_lo [0:NC-1];
  logic [OUT_CH_W-1:0] routed_channel_hi [0:NC-1];
  logic [$clog2(NG)-1:0] routed_group [0:NC-1];
  logic routed_fc_mode [0:NC-1];
  logic [LAYER_ID_W-1:0] routed_layer [0:NC-1];

  fc_result_router #(
    .ACC_W(ACC_W), .NG(NG), .NC(NC),
    .OUT_ADDR_W(OUT_ADDR_W), .OUT_CH_W(OUT_CH_W),
    .LAYER_ID_W(LAYER_ID_W)
  ) u_result_router (
    .clk(clk), .rst_n(rst_n), .start(start),
    .advance_in(pipe_en), .cfg_out_base_addr(out_base_addr),
    .cfg_out_ch_base(out_ch_base), .cfg_out_channels(out_channels),
    .cfg_layer_id(layer_id), .acc_lo_in(acc_lo), .acc_hi_in(acc_hi),
    .acc_valid_in(acc_valid), .ingress_ready(router_ingress_ready),
    .idle(router_idle), .result_valid(routed_valid),
    .result_ready(routed_ready), .result_acc_lo(routed_acc_lo),
    .result_acc_hi(routed_acc_hi), .result_lane_mask(routed_mask),
    .result_addr_lo(routed_addr_lo), .result_addr_hi(routed_addr_hi),
    .result_channel_lo(routed_channel_lo),
    .result_channel_hi(routed_channel_hi),
    .result_group(routed_group), .result_fc_mode(routed_fc_mode),
    .result_layer_id(routed_layer)
  );

  logic result_valid [0:NC-1];
  logic result_ready [0:NC-1];
  logic [15:0] result_data [0:NC-1];
  logic [1:0] result_mask [0:NC-1];
  logic [OUT_ADDR_W-1:0] result_addr_lo [0:NC-1];
  logic [OUT_ADDR_W-1:0] result_addr_hi [0:NC-1];
  logic [OUT_CH_W-1:0] result_channel_lo [0:NC-1];
  logic [OUT_CH_W-1:0] result_channel_hi [0:NC-1];
  logic [$clog2(NG)-1:0] result_group [0:NC-1];
  logic result_fc_mode [0:NC-1];
  logic [LAYER_ID_W-1:0] result_layer [0:NC-1];

  postprocess_array #(
    .ACC_W(ACC_W), .NG(NG), .NC(NC), .SCALE_W(SCALE_W),
    .OUT_ADDR_W(OUT_ADDR_W), .OUT_CH_W(OUT_CH_W),
    .LAYER_ID_W(LAYER_ID_W)
  ) u_postprocess (
    .clk(clk), .rst_n(rst_n), .flush(start),
    .param_wr_en(param_wr_en), .param_wr_lane(param_wr_lane),
    .param_wr_bias(param_wr_bias), .param_wr_scale(param_wr_scale),
    .cfg_relu_en(relu_en),
    .in_valid(routed_valid), .in_ready(routed_ready),
    .in_acc_lo(routed_acc_lo), .in_acc_hi(routed_acc_hi),
    .in_lane_mask(routed_mask),
    .in_addr_lo(routed_addr_lo), .in_addr_hi(routed_addr_hi),
    .in_channel_lo(routed_channel_lo),
    .in_channel_hi(routed_channel_hi), .in_group(routed_group),
    .in_fc_mode(routed_fc_mode), .in_layer_id(routed_layer),
    .out_valid(result_valid), .out_ready(result_ready),
    .out_data(result_data), .out_lane_mask(result_mask),
    .out_addr_lo(result_addr_lo), .out_addr_hi(result_addr_hi),
    .out_channel_lo(result_channel_lo),
    .out_channel_hi(result_channel_hi), .out_group(result_group),
    .out_fc_mode(result_fc_mode), .out_layer_id(result_layer),
    .idle(postprocess_idle)
  );

  banked_activation_writer #(
    .NC(NC), .BYTE_ADDR_W(OUT_ADDR_W), .WORD_ADDR_W(BANK_ADDR_W)
  ) u_writer (
    .clk(clk), .rst_n(rst_n), .start(start),
    .cfg_bank_base_word(cfg_bank_base_word),
    .in_valid(result_valid), .in_ready(result_ready),
    .in_data(result_data), .in_lane_mask(result_mask),
    .in_addr_lo(result_addr_lo), .in_addr_hi(result_addr_hi),
    .bank_we(bank_we), .bank_ready(bank_ready),
    .bank_word_addr(bank_word_addr), .bank_wdata(bank_wdata),
    .bank_wstrb(bank_wstrb)
  );

  assign pipe_en = en && router_ingress_ready;

  logic source_done_pending_r;
  logic [7:0] write_lane_count_r;
  logic [7:0] expected_lane_count_r;
  logic [4:0] lane_add_c;
  always_comb begin
    lane_add_c = '0;
    for (int c = 0; c < NC; c++) begin
      if (bank_we[c])
        lane_add_c = lane_add_c + bank_wstrb[c][0] + bank_wstrb[c][1];
    end
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
        if (out_channels > out_ch_base + OUT_CH_W'(LANE_COUNT))
          expected_lane_count_r <= 8'(LANE_COUNT);
        else
          expected_lane_count_r <= 8'(out_channels - out_ch_base);
        busy <= 1'b1;
      end else begin
        if (source_done) source_done_pending_r <= 1'b1;
        if (lane_add_c != 0)
          write_lane_count_r <= write_lane_count_r + lane_add_c;
        if (source_done_pending_r &&
            (write_lane_count_r >= expected_lane_count_r) &&
            router_idle && postprocess_idle) begin
          source_done_pending_r <= 1'b0;
          busy <= 1'b0;
          done <= 1'b1;
        end
      end
    end
  end

`ifdef SIMULATION
  assert property (@(posedge clk) disable iff (!rst_n)
      pipe_en |-> (src_valid_r == weight_valid));
  assert property (@(posedge clk) disable iff (!rst_n)
      (pipe_en && weight_valid) |-> (src_k_r == weight_k));
  assert property (@(posedge clk) disable iff (!rst_n)
      start |-> (!busy && (out_channels > out_ch_base)));
`endif

endmodule
