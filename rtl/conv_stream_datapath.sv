`timescale 1ns/1ps
// conv_stream_datapath.sv -- integrated activation/weight/skew/SA pipeline.
//
// Ownership is explicit: window_gen owns the sequential activation request
// and compact tap schedule; weight_loader follows that exact k stream; this
// module owns the one-cycle source register that matches the weight BRAM read
// latency; skew_buf and sa_packed_4x8 consume one shared compute enable.
// column_result_router may pause that complete pipeline while its one-entry
// column slots drain into the postprocess pipelines.

module conv_stream_datapath #(
  parameter int ACT_W     = 8,
  parameter int WGT_W     = 8,
  parameter int ACC_W     = 32,
  parameter int NG        = 4,
  parameter int NC        = 8,
  parameter int C_IN      = 2,
  parameter int FMAP_W    = 13,
  parameter int FMAP_H    = 13,
  parameter int K         = 5,
  parameter int OUT_W     = FMAP_W - K + 1,
  parameter int OUT_H     = FMAP_H - K + 1,
  parameter int PREFETCH_ROWS = 2,
  parameter int DEPTH     = K * K * C_IN,
  parameter int MEM_DEPTH = 2048,
  parameter int ADDR_W    = $clog2(MEM_DEPTH),
  parameter int KOUT_W    = $clog2(DEPTH > 1 ? DEPTH : 2),
  parameter int OUT_ADDR_W = 16,
  parameter int OUT_CH_W   = 8,
  parameter int LAYER_ID_W = 3,
  parameter int SCALE_W    = 18,
  parameter int LANE_COUNT = 2 * NG * NC,
  parameter int LANE_ID_W  = (LANE_COUNT < 2) ? 1 : $clog2(LANE_COUNT)
) (
  input  logic clk,
  input  logic rst_n,
  input  logic en,             // Shared hold for every compute pipeline register.
  input  logic start,

  // Activation reader response. The external reader advances only on pix_rd_en.
  input  logic signed [ACT_W-1:0] pix_in,
  output logic                    pix_rd_en,

  // Eight-bank preload port. It is legal while en=0 before a layer starts.
  input  logic                    wr_en,
  input  logic [ADDR_W-1:0]       wr_addr,
  input  logic signed [WGT_W-1:0] wr_data [0:NC-1],
  input  logic [ADDR_W-1:0]       base_layer,
  input  logic [ADDR_W-1:0]       pass_idx,

  // Output-layer mapping captured with every depth_last transaction.
  input  logic [OUT_ADDR_W-1:0] out_base_addr,
  input  logic [OUT_CH_W-1:0]   out_ch_base,
  input  logic [OUT_CH_W-1:0]   out_channels,
  input  logic                  fc_mode,
  input  logic [LAYER_ID_W-1:0] layer_id,

  // The global controller preloads one bias/scale entry per physical logical
  // lane before each output-channel pass.
  input  logic                      param_wr_en,
  input  logic [LANE_ID_W-1:0]      param_wr_lane,
  input  logic signed [ACC_W-1:0]   param_wr_bias,
  input  logic signed [SCALE_W-1:0] param_wr_scale,
  input  logic                      relu_en,

  output logic signed [ACC_W-1:0] acc_lo_out [0:NG-1][0:NC-1],
  output logic signed [ACC_W-1:0] acc_hi_out [0:NG-1][0:NC-1],
  output logic [1:0]              acc_valid  [0:NG-1][0:NC-1],

  // One postprocessed INT8 pair per physical systolic column.
  output logic                    result_valid [0:NC-1],
  input  logic                    result_ready [0:NC-1],
  output logic [15:0]             result_data [0:NC-1],
  output logic [1:0]              result_lane_mask [0:NC-1],
  output logic [OUT_ADDR_W-1:0]   result_addr_lo [0:NC-1],
  output logic [OUT_ADDR_W-1:0]   result_addr_hi [0:NC-1],
  output logic [OUT_CH_W-1:0]     result_channel_lo [0:NC-1],
  output logic [OUT_CH_W-1:0]     result_channel_hi [0:NC-1],
  output logic [$clog2(NG)-1:0]   result_group [0:NC-1],
  output logic                    result_fc_mode [0:NC-1],
  output logic [LAYER_ID_W-1:0]   result_layer_id [0:NC-1],

  output logic                    done
);

  logic signed [ACT_W-1:0] win_raw [0:2*NG-1];
  logic                    pair_valid_raw [0:NG-1];
  logic [1:0]              lane_mask_raw [0:NG-1];
  logic                    depth_last_raw [0:NG-1];
  logic [KOUT_W-1:0]       k_out_raw;

  logic signed [ACT_W-1:0] src_win_q [0:2*NG-1];
  logic                    src_pair_valid [0:NG-1];
  logic [1:0]              src_lane_mask [0:NG-1];
  logic                    src_depth_last [0:NG-1];
  logic [KOUT_W-1:0]       src_k_out;

  logic signed [WGT_W-1:0] wgt_q [0:NC-1];
  logic                    wgt_valid;
  logic                    wgt_depth_last;
  logic [KOUT_W-1:0]       wgt_k_out;

  logic signed [ACT_W-1:0] act_lo_skew [0:NG-1];
  logic signed [ACT_W-1:0] act_hi_skew [0:NG-1];
  logic                    pair_valid_skew [0:NG-1];
  logic [1:0]              lane_mask_skew [0:NG-1];
  logic                    depth_last_skew [0:NG-1];
  logic signed [WGT_W-1:0] weight_skew [0:NC-1];
  logic                    weight_valid_skew [0:NC-1];
  logic                    weight_depth_last_skew [0:NC-1];

  logic pipe_en;
  logic router_ingress_ready;
  logic router_idle;
  logic postprocess_idle;
  logic window_done;
  logic job_drain_pending_r;

  logic                    routed_valid [0:NC-1];
  logic                    routed_ready [0:NC-1];
  logic signed [ACC_W-1:0] routed_acc_lo [0:NC-1];
  logic signed [ACC_W-1:0] routed_acc_hi [0:NC-1];
  logic [1:0]              routed_lane_mask [0:NC-1];
  logic [OUT_ADDR_W-1:0]   routed_addr_lo [0:NC-1];
  logic [OUT_ADDR_W-1:0]   routed_addr_hi [0:NC-1];
  logic [OUT_CH_W-1:0]     routed_channel_lo [0:NC-1];
  logic [OUT_CH_W-1:0]     routed_channel_hi [0:NC-1];
  logic [$clog2(NG)-1:0]   routed_group [0:NC-1];
  logic                    routed_fc_mode [0:NC-1];
  logic [LAYER_ID_W-1:0]   routed_layer_id [0:NC-1];

  // Router backpressure freezes source, weights, skew, PE hops, DSP tags, and
  // accumulators on one identical edge. Its output packet can still drain.
  assign pipe_en = en && router_ingress_ready;

  window_gen #(
    .ACT_W(ACT_W), .NG(NG), .NC(NC), .C_IN(C_IN),
    .FMAP_W(FMAP_W), .FMAP_H(FMAP_H), .K(K), .OUT_W(OUT_W), .OUT_H(OUT_H),
    .PREFETCH_ROWS(PREFETCH_ROWS)
  ) u_window_gen (
    .clk(clk), .rst_n(rst_n), .en(pipe_en), .start(start), .pix_in(pix_in),
    .pix_rd_en(pix_rd_en), .win_q(win_raw), .pair_valid(pair_valid_raw),
    .lane_mask(lane_mask_raw), .depth_last(depth_last_raw), .k_out(k_out_raw),
    .done(window_done)
  );

  // weight_loader captures raw k at the same edge where this stage captures
  // raw activation/control. Their registered outputs therefore denote one
  // identical transaction during the following complete clock cycle.
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      src_k_out <= '0;
      for (int i = 0; i < 2 * NG; i++) src_win_q[i] <= '0;
      for (int g = 0; g < NG; g++) begin
        src_pair_valid[g] <= 1'b0;
        src_lane_mask[g] <= 2'b00;
        src_depth_last[g] <= 1'b0;
      end
    end else if (pipe_en) begin
      src_k_out <= k_out_raw;
      for (int i = 0; i < 2 * NG; i++) src_win_q[i] <= win_raw[i];
      for (int g = 0; g < NG; g++) begin
        src_pair_valid[g] <= pair_valid_raw[g];
        src_lane_mask[g] <= lane_mask_raw[g];
        src_depth_last[g] <= depth_last_raw[g];
      end
    end
  end

  weight_loader #(
    .ACT_W(WGT_W), .NC(NC), .K(K), .C_IN(C_IN), .DEPTH(DEPTH),
    .MEM_DEPTH(MEM_DEPTH), .ADDR_W(ADDR_W), .KOUT_W(KOUT_W)
  ) u_weight_loader (
    .clk(clk), .rst_n(rst_n), .en(pipe_en), .wr_en(wr_en), .wr_addr(wr_addr),
    .wr_data(wr_data), .k_valid(pair_valid_raw[0]), .k_out(k_out_raw),
    .depth_last_in(depth_last_raw[0]), .base_layer(base_layer), .pass_idx(pass_idx),
    .wgt_q(wgt_q), .wgt_valid(wgt_valid), .wgt_depth_last(wgt_depth_last),
    .wgt_k_out(wgt_k_out)
  );

  skew_buf #(
    .ACT_W(ACT_W), .WGT_W(WGT_W), .NG(NG), .NC(NC)
  ) u_skew_buf (
    .clk(clk), .rst_n(rst_n), .en(pipe_en), .win_q(src_win_q),
    .pair_valid_in(src_pair_valid), .lane_mask_in(src_lane_mask),
    .depth_last_in(src_depth_last), .weight_q(wgt_q),
    .weight_valid_in(wgt_valid), .weight_depth_last_in(wgt_depth_last),
    .act_lo_out(act_lo_skew), .act_hi_out(act_hi_skew),
    .pair_valid_out(pair_valid_skew), .lane_mask_out(lane_mask_skew),
    .depth_last_out(depth_last_skew), .weight_out(weight_skew),
    .weight_valid_out(weight_valid_skew),
    .weight_depth_last_out(weight_depth_last_skew)
  );

  sa_packed_4x8 #(
    .ACT_W(ACT_W), .WGT_W(WGT_W), .ACC_W(ACC_W), .NG(NG), .NC(NC)
  ) u_sa (
    .clk(clk), .rst_n(rst_n), .en(pipe_en), .act_lo_in(act_lo_skew),
    .act_hi_in(act_hi_skew), .pair_valid(pair_valid_skew),
    .lane_mask(lane_mask_skew), .depth_last(depth_last_skew),
    .weight_in(weight_skew), .acc_lo_out(acc_lo_out), .acc_hi_out(acc_hi_out),
    .acc_valid(acc_valid)
  );

  column_result_router #(
    .ACC_W(ACC_W), .NG(NG), .NC(NC), .OUT_W(OUT_W), .OUT_H(OUT_H),
    .OUT_ADDR_W(OUT_ADDR_W), .OUT_CH_W(OUT_CH_W),
    .LAYER_ID_W(LAYER_ID_W)
  ) u_column_result_router (
    .clk(clk), .rst_n(rst_n), .start(start),
    .advance_in(pipe_en),
    .issue_last(src_depth_last[0]), .issue_lane_mask(src_lane_mask),
    .cfg_out_base_addr(out_base_addr), .cfg_out_ch_base(out_ch_base),
    .cfg_out_channels(out_channels), .cfg_fc_mode(fc_mode),
    .cfg_layer_id(layer_id),
    .acc_lo_in(acc_lo_out), .acc_hi_in(acc_hi_out), .acc_valid_in(acc_valid),
    .ingress_ready(router_ingress_ready), .idle(router_idle),
    .result_valid(routed_valid), .result_ready(routed_ready),
    .result_acc_lo(routed_acc_lo), .result_acc_hi(routed_acc_hi),
    .result_lane_mask(routed_lane_mask),
    .result_addr_lo(routed_addr_lo), .result_addr_hi(routed_addr_hi),
    .result_channel_lo(routed_channel_lo),
    .result_channel_hi(routed_channel_hi), .result_group(routed_group),
    .result_fc_mode(routed_fc_mode), .result_layer_id(routed_layer_id)
  );

  postprocess_array #(
    .ACC_W(ACC_W), .NG(NG), .NC(NC), .SCALE_W(SCALE_W),
    .OUT_ADDR_W(OUT_ADDR_W), .OUT_CH_W(OUT_CH_W),
    .LAYER_ID_W(LAYER_ID_W)
  ) u_postprocess_array (
    .clk(clk), .rst_n(rst_n), .flush(start),
    .param_wr_en(param_wr_en), .param_wr_lane(param_wr_lane),
    .param_wr_bias(param_wr_bias), .param_wr_scale(param_wr_scale),
    .cfg_relu_en(relu_en),
    .in_valid(routed_valid), .in_ready(routed_ready),
    .in_acc_lo(routed_acc_lo), .in_acc_hi(routed_acc_hi),
    .in_lane_mask(routed_lane_mask),
    .in_addr_lo(routed_addr_lo), .in_addr_hi(routed_addr_hi),
    .in_channel_lo(routed_channel_lo),
    .in_channel_hi(routed_channel_hi), .in_group(routed_group),
    .in_fc_mode(routed_fc_mode), .in_layer_id(routed_layer_id),
    .out_valid(result_valid), .out_ready(result_ready),
    .out_data(result_data), .out_lane_mask(result_lane_mask),
    .out_addr_lo(result_addr_lo), .out_addr_hi(result_addr_hi),
    .out_channel_lo(result_channel_lo),
    .out_channel_hi(result_channel_hi), .out_group(result_group),
    .out_fc_mode(result_fc_mode), .out_layer_id(result_layer_id),
    .idle(postprocess_idle)
  );

  // Window completion means no more PE results can appear. Job completion is
  // delayed until every routed packet has also been accepted downstream.
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      job_drain_pending_r <= 1'b0;
      done                <= 1'b0;
    end else begin
      done <= 1'b0;
      if (start) begin
        job_drain_pending_r <= 1'b0;
      end else begin
        // window_done is a one-cycle event generated only after a legal
        // pipe_en advance. Capture it even if external en is lowered on the
        // following cycle; otherwise a randomized/global pause can lose job
        // completion after every result has already been produced.
        if (window_done) job_drain_pending_r <= 1'b1;
        if ((job_drain_pending_r || window_done) &&
            router_idle && postprocess_idle) begin
          job_drain_pending_r <= 1'b0;
          done                <= 1'b1;
        end
      end
    end
  end

`ifdef SIMULATION
  // This is the source-latency contract. It detects a one-cycle activation /
  // weight mismatch before an incorrect product reaches any PPE.
  assert property (@(posedge clk) disable iff (!rst_n)
      pipe_en |-> (wgt_valid == src_pair_valid[0]));
  assert property (@(posedge clk) disable iff (!rst_n)
      (pipe_en && wgt_valid) |-> (wgt_k_out == src_k_out));
  assert property (@(posedge clk) disable iff (!rst_n)
      (pipe_en && src_pair_valid[0]) |->
        (src_pair_valid[0] == src_pair_valid[NG-1]));
  assert property (@(posedge clk) disable iff (!rst_n)
      !pipe_en |=> $stable({
        src_k_out, src_pair_valid[0], src_lane_mask[0], src_depth_last[0]
      }));
`endif

endmodule
