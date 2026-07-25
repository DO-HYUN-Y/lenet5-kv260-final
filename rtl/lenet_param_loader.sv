`timescale 1ns/1ps
// lenet_param_loader.sv -- on-chip logical bias/scale store and physical
// postprocess-lane preload sequencer.
//
// Logical parameter layout:
//   C1[6], C3[16], C5[120], F6[84], OUT[10] = 236 entries.
//
// Conv maps physical lane {group,column,packed-lane} to one output channel:
//   logical_channel = pass_base + column
// and duplicates that channel's parameter across all groups/packed lanes.
// FC maps every physical lane to a distinct output channel:
//   logical_channel = pass_base + physical_lane.

module lenet_param_loader #(
  parameter int ACC_W          = 32,
  parameter int SCALE_W        = 18,
  parameter int NG             = 4,
  parameter int NC             = 8,
  parameter int OUT_CH_W       = 8,
  parameter int TOTAL_PARAMS   = 236,
  parameter int PARAM_ADDR_W   =
      (TOTAL_PARAMS < 2) ? 1 : $clog2(TOTAL_PARAMS),
  parameter int LANE_COUNT     = 2 * NG * NC,
  parameter int LANE_ID_W      =
      (LANE_COUNT < 2) ? 1 : $clog2(LANE_COUNT),
  parameter int PARAM_WORD_W   = ACC_W + SCALE_W
) (
  input  logic clk,
  input  logic rst_n,

  // Model-preload port. Writes are legal only while no lane load is active.
  input  logic                         host_wr_en,
  input  logic [PARAM_ADDR_W-1:0]      host_wr_addr,
  input  logic signed [ACC_W-1:0]      host_wr_bias,
  input  logic signed [SCALE_W-1:0]    host_wr_scale,
  output logic                         host_ready,

  input  logic                         load_start,
  input  logic                         cfg_fc_mode,
  input  logic [PARAM_ADDR_W-1:0]      cfg_param_base,
  input  logic [OUT_CH_W-1:0]          cfg_out_ch_base,
  input  logic [OUT_CH_W-1:0]          cfg_out_channels,
  input  logic [OUT_CH_W-1:0]          cfg_pass_channels,

  output logic                         param_wr_en,
  output logic [LANE_ID_W-1:0]         param_wr_lane,
  output logic signed [ACC_W-1:0]      param_wr_bias,
  output logic signed [SCALE_W-1:0]    param_wr_scale,
  output logic                         busy,
  output logic                         done
);

  (* ram_style = "block" *)
  logic [PARAM_WORD_W-1:0] param_mem [0:TOTAL_PARAMS-1];

  logic fc_mode_r;
  logic [PARAM_ADDR_W-1:0] param_base_r;
  logic [OUT_CH_W-1:0] out_ch_base_r;
  logic [OUT_CH_W-1:0] out_channels_r;
  logic [OUT_CH_W-1:0] pass_channels_r;

  logic issue_active_r;
  logic [LANE_ID_W-1:0] issue_lane_r;
  logic issue_param_active_c;
  logic [PARAM_ADDR_W-1:0] issue_param_addr_c;

  always_comb begin
    int physical_column;
    int logical_offset;
    int logical_addr;

    physical_column =
        (int'(issue_lane_r) % (2 * NC)) / 2;
    if (fc_mode_r)
      logical_offset =
          int'(out_ch_base_r) + int'(issue_lane_r);
    else
      logical_offset =
          int'(out_ch_base_r) + physical_column;
    logical_addr = int'(param_base_r) + logical_offset;

    if (fc_mode_r)
      issue_param_active_c =
          (logical_offset < int'(out_channels_r));
    else
      issue_param_active_c =
          (physical_column < int'(pass_channels_r)) &&
          (logical_offset < int'(out_channels_r));
    issue_param_active_c =
        issue_param_active_c &&
        (logical_addr >= 0) && (logical_addr < TOTAL_PARAMS);
    issue_param_addr_c = PARAM_ADDR_W'(logical_addr);
  end

  logic rsp_valid_r;
  logic rsp_last_r;
  logic [LANE_ID_W-1:0] rsp_lane_r;
  logic [PARAM_WORD_W-1:0] rsp_word_r;

  assign param_wr_en = rsp_valid_r;
  assign param_wr_lane = rsp_lane_r;
  assign param_wr_bias =
      $signed(rsp_word_r[PARAM_WORD_W-1:SCALE_W]);
  assign param_wr_scale = $signed(rsp_word_r[SCALE_W-1:0]);
  assign busy = issue_active_r || rsp_valid_r;
  assign host_ready = !busy;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      fc_mode_r <= 1'b0;
      param_base_r <= '0;
      out_ch_base_r <= '0;
      out_channels_r <= '0;
      pass_channels_r <= '0;
      issue_active_r <= 1'b0;
      issue_lane_r <= '0;
      rsp_valid_r <= 1'b0;
      rsp_last_r <= 1'b0;
      rsp_lane_r <= '0;
      rsp_word_r <= '0;
      done <= 1'b0;
    end else begin
      done <= 1'b0;

      if (host_wr_en && host_ready)
        param_mem[host_wr_addr] <= {host_wr_bias, host_wr_scale};

      if (load_start) begin
        fc_mode_r <= cfg_fc_mode;
        param_base_r <= cfg_param_base;
        out_ch_base_r <= cfg_out_ch_base;
        out_channels_r <= cfg_out_channels;
        pass_channels_r <= cfg_pass_channels;
        issue_active_r <= 1'b1;
        issue_lane_r <= '0;
        rsp_valid_r <= 1'b0;
        rsp_last_r <= 1'b0;
      end else begin
        rsp_valid_r <= issue_active_r;
        if (issue_active_r) begin
          rsp_lane_r <= issue_lane_r;
          rsp_last_r <= (issue_lane_r == LANE_ID_W'(LANE_COUNT - 1));
          if (issue_param_active_c)
            rsp_word_r <= param_mem[issue_param_addr_c];
          else
            rsp_word_r <= '0;

          if (issue_lane_r == LANE_ID_W'(LANE_COUNT - 1))
            issue_active_r <= 1'b0;
          else
            issue_lane_r <= issue_lane_r + 1'b1;
        end

        if (rsp_valid_r && rsp_last_r)
          done <= 1'b1;
      end
    end
  end

`ifdef SIMULATION
  assert property (@(posedge clk) disable iff (!rst_n)
      load_start |-> (!busy && !host_wr_en &&
                      (cfg_out_channels != 0) &&
                      (cfg_pass_channels != 0)));
  assert property (@(posedge clk) disable iff (!rst_n)
      host_wr_en |-> (host_ready && (host_wr_addr < TOTAL_PARAMS)));
  assert property (@(posedge clk) disable iff (!rst_n)
      param_wr_en |-> (param_wr_lane < LANE_COUNT));
`endif

endmodule
