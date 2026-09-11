`timescale 1ns/1ps

// Compact-pin implementation harness for alexnet_sa_m8n128_dynamic.
//
// Directly exposing 512 INT32 PE results exceeds the package IO-terminal
// limit during an OOC placement even though those signals remain on-chip in
// the complete accelerator.  This harness creates registered operands and
// folds every result into bank-local signatures, preserving all compute
// logic while presenting only a realistic control/status boundary to the
// placer.
module alexnet_sa_m8n128_dynamic_ooc #(
    parameter int K_DEPTH = 64,
    parameter int K_COUNT_W = $clog2(K_DEPTH)
) (
    input logic clk,
    input logic rst,
    input logic start,
    input logic mode_split_n64,
    input logic [31:0] seed,
    output logic busy,
    output logic done,
    output logic [31:0] result_signature
);

  typedef enum logic [1:0] {
    ST_IDLE,
    ST_CLEAR,
    ST_ISSUE,
    ST_DRAIN
  } state_t;

  state_t state_q;
  logic mode_q;
  logic [31:0] lfsr_q;
  logic [K_COUNT_W-1:0] k_q;

  logic group_ce [0:1];
  logic signed [7:0] group_act_lo [0:1][0:3];
  logic signed [7:0] group_act_hi [0:1][0:3];
  logic group_issue_valid [0:1];
  logic group_tile_clear [0:1];
  logic group_reduce_last [0:1];
  logic [1:0] group_m_lane_mask [0:1][0:3];
  logic [15:0] group_tile_tag [0:1];
  logic signed [7:0] bank_weight [0:7][0:15];

  logic result_valid [0:7][0:3][0:15];
  logic result_ready [0:7][0:3][0:15];
  logic signed [31:0] result_lo [0:7][0:3][0:15];
  logic signed [31:0] result_hi [0:7][0:3][0:15];
  logic [1:0] result_lane_mask [0:7][0:3][0:15];
  logic bank_source_group [0:7];
  logic [2:0] bank_n16_slot [0:7];
  logic [15:0] bank_result_tag [0:7];

  logic leaf_fold [0:7][0:3][0:15];
  logic leaf_fold_q [0:7][0:3][0:15];
  logic fold_l1_q [0:7][0:3][0:7];
  logic fold_l2_q [0:7][0:3][0:3];
  logic fold_l3_q [0:7][0:3][0:1];
  logic row_fold_q [0:7][0:3];
  logic row_pair_fold_q [0:7][0:1];
  logic bank_fold_q [0:7];
  logic [31:0] bank_signature_q [0:7];
  logic [7:0] bank_done_q;
  logic [3:0] drain_q;

  always_comb begin
    for (int group = 0; group < 2; group++) begin
      group_ce[group] = busy;
      group_issue_valid[group] = state_q == ST_ISSUE &&
          (group == 0 || mode_q);
      group_tile_clear[group] = state_q == ST_CLEAR &&
          (group == 0 || mode_q);
      group_reduce_last[group] = state_q == ST_ISSUE &&
          k_q == K_DEPTH-1 && (group == 0 || mode_q);
      group_tile_tag[group] = {seed[13:0], mode_q, group[0]};
      for (int row = 0; row < 4; row++) begin
        group_act_lo[group][row] = $signed(
            lfsr_q[7:0] ^ (8'(group*8'h53 + row*8'h17)));
        group_act_hi[group][row] = $signed(
            lfsr_q[23:16] ^ (8'(group*8'h31 + row*8'h2b)));
        group_m_lane_mask[group][row] = 2'b11;
      end
    end

    for (int bank = 0; bank < 8; bank++) begin
      for (int col = 0; col < 16; col++) begin
        bank_weight[bank][col] = $signed(
            lfsr_q[15:8] ^ (8'(bank*8'h1d + col*8'h0b)) ^ k_q);
        result_ready[bank][0][col] = 1'b1;
        result_ready[bank][1][col] = 1'b1;
        result_ready[bank][2][col] = 1'b1;
        result_ready[bank][3][col] = 1'b1;
      end
    end

    for (int bank = 0; bank < 8; bank++)
      for (int row = 0; row < 4; row++)
        for (int col = 0; col < 16; col++)
          leaf_fold[bank][row][col] = result_valid[bank][row][col] &&
              ^{result_lo[bank][row][col], result_hi[bank][row][col],
                result_lane_mask[bank][row][col],
                bank_source_group[bank]};

    result_signature = '0;
    for (int bank = 0; bank < 8; bank++)
      result_signature = result_signature ^ bank_signature_q[bank] ^
                         {13'b0, bank_result_tag[bank],
                          bank_n16_slot[bank]};
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      state_q <= ST_IDLE;
      mode_q <= 1'b0;
      lfsr_q <= 32'h1;
      k_q <= '0;
      busy <= 1'b0;
      done <= 1'b0;
      bank_done_q <= '0;
      drain_q <= '0;
      for (int bank = 0; bank < 8; bank++) begin
        bank_fold_q[bank] <= '0;
        bank_signature_q[bank] <= '0;
        for (int pair = 0; pair < 2; pair++)
          row_pair_fold_q[bank][pair] <= '0;
        for (int row = 0; row < 4; row++) begin
          row_fold_q[bank][row] <= '0;
          for (int pair = 0; pair < 2; pair++)
            fold_l3_q[bank][row][pair] <= '0;
          for (int quad = 0; quad < 4; quad++)
            fold_l2_q[bank][row][quad] <= '0;
          for (int oct = 0; oct < 8; oct++)
            fold_l1_q[bank][row][oct] <= '0;
          for (int col = 0; col < 16; col++)
            leaf_fold_q[bank][row][col] <= '0;
        end
      end
    end else begin
      done <= 1'b0;

      for (int bank = 0; bank < 8; bank++) begin
        for (int row = 0; row < 4; row++) begin
          for (int col = 0; col < 16; col++)
            leaf_fold_q[bank][row][col] <= leaf_fold[bank][row][col];
          for (int pair = 0; pair < 8; pair++)
            fold_l1_q[bank][row][pair] <=
                leaf_fold_q[bank][row][2*pair] ^
                leaf_fold_q[bank][row][2*pair+1];
          for (int pair = 0; pair < 4; pair++)
            fold_l2_q[bank][row][pair] <=
                fold_l1_q[bank][row][2*pair] ^
                fold_l1_q[bank][row][2*pair+1];
          for (int pair = 0; pair < 2; pair++)
            fold_l3_q[bank][row][pair] <=
                fold_l2_q[bank][row][2*pair] ^
                fold_l2_q[bank][row][2*pair+1];
          row_fold_q[bank][row] <=
              fold_l3_q[bank][row][0] ^ fold_l3_q[bank][row][1];
        end
        row_pair_fold_q[bank][0] <=
            row_fold_q[bank][0] ^ row_fold_q[bank][1];
        row_pair_fold_q[bank][1] <=
            row_fold_q[bank][2] ^ row_fold_q[bank][3];
        bank_fold_q[bank] <=
            row_pair_fold_q[bank][0] ^ row_pair_fold_q[bank][1];
        if (busy)
          bank_signature_q[bank] <=
              {bank_signature_q[bank][30:0], bank_signature_q[bank][31]} ^
              {31'b0, bank_fold_q[bank]};
        if (result_valid[bank][3][15])
          bank_done_q[bank] <= 1'b1;
      end

      case (state_q)
        ST_IDLE: begin
          busy <= 1'b0;
          if (start) begin
            mode_q <= mode_split_n64;
            lfsr_q <= seed == 0 ? 32'h1 : seed;
            k_q <= '0;
            bank_done_q <= '0;
            drain_q <= '0;
            for (int bank = 0; bank < 8; bank++) begin
              bank_fold_q[bank] <= '0;
              bank_signature_q[bank] <= '0;
            end
            busy <= 1'b1;
            state_q <= ST_CLEAR;
          end
        end

        ST_CLEAR: state_q <= ST_ISSUE;

        ST_ISSUE: begin
          lfsr_q <= {lfsr_q[30:0],
                     lfsr_q[31] ^ lfsr_q[21] ^ lfsr_q[1] ^ lfsr_q[0]};
          if (k_q == K_DEPTH-1)
            state_q <= ST_DRAIN;
          else
            k_q <= k_q + 1'b1;
        end

        ST_DRAIN: begin
          if (&bank_done_q) begin
            if (drain_q == 4'd9) begin
              busy <= 1'b0;
              done <= 1'b1;
              state_q <= ST_IDLE;
            end else begin
              drain_q <= drain_q + 1'b1;
            end
          end else begin
            drain_q <= '0;
          end
        end

        default: state_q <= ST_IDLE;
      endcase
    end
  end

  alexnet_sa_m8n128_dynamic u_dynamic (
      .clk,
      .rst,
      .mode_split_n64(mode_q),
      .bank_enable(8'hff),
      .group_ce,
      .group_act_lo,
      .group_act_hi,
      .group_issue_valid,
      .group_tile_clear,
      .group_reduce_last,
      .group_m_lane_mask,
      .group_tile_tag,
      .bank_weight,
      .result_valid,
      .result_ready,
      .result_lo,
      .result_hi,
      .result_lane_mask,
      .bank_source_group,
      .bank_n16_slot,
      .bank_result_tag
  );

  initial begin
    if (K_DEPTH < 1 || K_COUNT_W < 1)
      $fatal(1, "dynamic OOC harness requires a positive K depth");
  end

endmodule
