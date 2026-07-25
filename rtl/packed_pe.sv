`timescale 1ns/1ps
// Packed PE (PPE) — 방식 A DSP48E2 packing, my_self.md §2
// 2 output spatial positions (lo/hi) share 1 DSP multiply via WP487 method A:
//   AD = (act_hi << SHIFT_G) + act_lo   (preadder)
//   P  = AD * weight                    (single multiply)
//   prod_lo = sign_extend(P[17:0])
//   prod_hi = sign_extend(P[35:18]) + P[17]   // P[17] carry correction: act_lo signed
//                                              // can borrow into the hi slice, correction
//                                              // undoes that borrow so hi stays exact.
module packed_pe #(
    parameter int ACT_W   = 8,
    parameter int WGT_W   = 8,
    parameter int ACC_W   = 32,
    parameter int SHIFT_G = 18,   // WP487 method A packing shift
    parameter int AD_W    = 27,   // holds (act_hi<<<SHIFT_G)+act_lo without overflow
    parameter int PROD_W  = 36    // matches spec's P[35:0] indexing
) (
    input  logic clk,
    input  logic rst_n,           // async active-low, fabric regs only (see below)
    input  logic en,              // en=0 holds every register in this module together

    input  logic signed [ACT_W-1:0] act_lo_in,
    input  logic signed [ACT_W-1:0] act_hi_in,
    input  logic signed [WGT_W-1:0] weight_in,
    input  logic                    pair_valid,
    input  logic [1:0]              lane_mask,
    input  logic                    depth_last,

    output logic signed [ACT_W-1:0] act_lo_out,
    output logic signed [ACT_W-1:0] act_hi_out,
    output logic signed [WGT_W-1:0] weight_out,

    output logic signed [ACC_W-1:0] acc_lo_out,
    output logic signed [ACC_W-1:0] acc_hi_out,
    output logic [1:0]              acc_valid
);

  // ---------------------------------------------------------------
  // Hop path: 1-cycle passthrough to neighbor PPE (right / down)
  // ---------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      act_lo_out <= '0;
      act_hi_out <= '0;
      weight_out <= '0;
    end else if (en) begin
      act_lo_out <= act_lo_in;
      act_hi_out <= act_hi_in;
      weight_out <= weight_in;
    end
  end

  // ---------------------------------------------------------------
  // DSP datapath: AREG/DREG/BREG1 -> ADREG/BREG2 -> MREG -> PREG
  // Sync reset only on these: DSP48E2 dedicated registers only support
  // synchronous SR, so an async reset here would force Vivado to build
  // reset logic in fabric instead of mapping cleanly into one DSP48E2.
  // ---------------------------------------------------------------
  logic signed [AD_W-1:0]   AREG, DREG, ADREG;
  logic signed [WGT_W-1:0]  BREG1, BREG2;
  logic signed [PROD_W-1:0] MREG, PREG;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      AREG  <= '0; DREG  <= '0; BREG1 <= '0;
      ADREG <= '0; BREG2 <= '0;
      MREG  <= '0; PREG  <= '0;
    end else if (en) begin
      // capture stage
      AREG  <= signed'(act_hi_in) <<< SHIFT_G;
      DREG  <= AD_W'(act_lo_in);
      BREG1 <= weight_in;
      // ADREG/BREG2 stage
      ADREG <= AREG + DREG;
      BREG2 <= BREG1;
      // MREG stage
      MREG  <= ADREG * BREG2;
      // PREG stage
      PREG  <= MREG;
    end
  end

  // ---------------------------------------------------------------
  // Control tag pipeline: mirrors DSP datapath depth so depth_last/
  // lane_mask land on the same cycle as PREG. Global broadcast of
  // depth_last is forbidden (my_self.md §4.6) — it must ride this
  // per-PPE pipeline instead.
  // ---------------------------------------------------------------
  typedef struct packed {
    logic       valid;
    logic [1:0] lane_mask;
    logic       depth_last;
  } ppe_tag_t;

  ppe_tag_t tag_pipe [0:3];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int i = 0; i < 4; i++) tag_pipe[i] <= '{default: '0};
    end else if (en) begin
      tag_pipe[0] <= '{valid: pair_valid, lane_mask: lane_mask, depth_last: depth_last};
      tag_pipe[1] <= tag_pipe[0];
      tag_pipe[2] <= tag_pipe[1];
      tag_pipe[3] <= tag_pipe[2];
    end
  end

  // ---------------------------------------------------------------
  // Product split (§2.2) + external accumulation (acc stationary, OS)
  // ---------------------------------------------------------------
  logic signed [ACC_W-1:0] prod_lo, prod_hi;
  assign prod_lo = ACC_W'($signed(PREG[17:0]));
  assign prod_hi = ACC_W'($signed(PREG[35:18])) + {{(ACC_W-1){1'b0}}, PREG[17]};

  logic signed [ACC_W-1:0] acc_lo_q, acc_hi_q;
  logic signed [ACC_W-1:0] next_lo, next_hi;
  assign next_lo = acc_lo_q + prod_lo;
  assign next_hi = acc_hi_q + prod_hi;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      acc_lo_q   <= '0;
      acc_hi_q   <= '0;
      acc_lo_out <= '0;
      acc_hi_out <= '0;
      acc_valid  <= 2'b00;
    end else if (en) begin
      acc_valid <= 2'b00;
      if (tag_pipe[3].valid) begin
        if (tag_pipe[3].depth_last) begin
          acc_lo_out <= next_lo;
          acc_hi_out <= next_hi;
          acc_valid  <= tag_pipe[3].lane_mask;
          acc_lo_q   <= '0;
          acc_hi_q   <= '0;
        end else begin
          acc_lo_q <= next_lo;
          acc_hi_q <= next_hi;
        end
      end
    end
  end

endmodule
