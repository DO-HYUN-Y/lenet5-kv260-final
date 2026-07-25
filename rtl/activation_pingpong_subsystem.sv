`timescale 1ns/1ps
// activation_pingpong_subsystem.sv -- two 8-bank activation sets and muxing.

module activation_pingpong_subsystem #(
  parameter int DATA_W       = 8,
  parameter int NG           = 4,
  parameter int NC           = 8,
  parameter int ADDR_W       = 9,
  parameter int BANK_DEPTH   = 1 << ADDR_W,
  parameter int DIM_W        = 6,
  parameter int CHANNEL_W    = 8,
  parameter int KOUT_W       = 9
) (
  input  logic clk,
  input  logic rst_n,

  // 0: host/idle, 1: compute, 2: pool.
  input  logic [1:0] owner,
  input  logic       read_set,
  input  logic       write_set,

  input  logic compute_start,
  input  logic compute_fc_mode,
  input  logic core_pix_consume,
  output logic signed [DATA_W-1:0] core_pix_data,
  output logic                    core_pix_valid,
  input  logic                    core_bank_we [0:NC-1],
  input  logic [ADDR_W-1:0]       core_bank_addr [0:NC-1],
  input  logic [15:0]             core_bank_wdata [0:NC-1],
  input  logic [1:0]              core_bank_wstrb [0:NC-1],
  output logic                    core_bank_ready [0:NC-1],

  input  logic [DIM_W-1:0]     conv_width,
  input  logic [DIM_W-1:0]     conv_height,
  input  logic [CHANNEL_W-1:0] conv_channels,
  input  logic [ADDR_W-1:0]    conv_base_word,
  input  logic [ADDR_W:0]      conv_plane_words,

  input  logic                    fc_packed_layout,
  input  logic [KOUT_W-1:0]       fc_length,
  input  logic [CHANNEL_W-1:0]    fc_channels,
  input  logic [KOUT_W-1:0]       fc_plane_bytes,
  input  logic [ADDR_W-1:0]       fc_plane_words,
  input  logic [ADDR_W-1:0]       fc_base_word,

  input  logic pool_start,
  input  logic [DIM_W-1:0]     pool_in_w,
  input  logic [DIM_W-1:0]     pool_in_h,
  input  logic [CHANNEL_W-1:0] pool_channels,
  input  logic [ADDR_W-1:0]    pool_in_base_word,
  input  logic [ADDR_W-1:0]    pool_out_base_word,
  input  logic [ADDR_W-1:0]    pool_in_plane_words,
  input  logic [ADDR_W-1:0]    pool_out_plane_words,
  output logic                 pool_busy,
  output logic                 pool_done,

  // 128-bit host/DMA-facing bank port, legal only when owner==0.
  input  logic                 host_set,
  input  logic                 host_en [0:NC-1],
  input  logic [1:0]           host_we [0:NC-1],
  input  logic [ADDR_W-1:0]    host_addr [0:NC-1],
  input  logic [15:0]          host_wdata [0:NC-1],
  output logic [15:0]          host_rdata [0:NC-1],
  output logic                 host_rvalid
);

  logic conv_rd_en [0:NC-1];
  logic [ADDR_W-1:0] conv_rd_addr [0:NC-1];
  logic [15:0] selected_read_a_data [0:NC-1];
  logic [15:0] selected_read_b_data [0:NC-1];
  logic signed [DATA_W-1:0] conv_pix_data;
  logic conv_pix_valid;

  activation_scalar_reader #(
    .ACT_W(DATA_W), .NC(NC), .ADDR_W(ADDR_W),
    .DIM_W(DIM_W), .CHANNEL_W(CHANNEL_W)
  ) u_conv_reader (
    .clk(clk), .rst_n(rst_n),
    .start(compute_start && !compute_fc_mode),
    .consume(core_pix_consume && !compute_fc_mode),
    .cfg_width(conv_width), .cfg_height(conv_height),
    .cfg_channels(conv_channels), .cfg_base_word(conv_base_word),
    .cfg_plane_words(conv_plane_words),
    .bank_en(conv_rd_en), .bank_addr(conv_rd_addr),
    .bank_rdata(selected_read_a_data),
    .pix_data(conv_pix_data), .pix_valid(conv_pix_valid)
  );

  logic fc_rd_en [0:NC-1];
  logic [ADDR_W-1:0] fc_rd_addr [0:NC-1];
  logic signed [DATA_W-1:0] fc_pix_data;
  logic fc_pix_valid;

  fc_activation_reader #(
    .ACT_W(DATA_W), .NG(NG), .NC(NC), .ADDR_W(ADDR_W),
    .KOUT_W(KOUT_W), .CHANNEL_W(CHANNEL_W)
  ) u_fc_reader (
    .clk(clk), .rst_n(rst_n),
    .start(compute_start && compute_fc_mode),
    .consume(core_pix_consume && compute_fc_mode),
    .packed_layout(fc_packed_layout), .cfg_length(fc_length),
    .cfg_channels(fc_channels), .cfg_plane_bytes(fc_plane_bytes),
    .cfg_plane_words(fc_plane_words), .cfg_base_word(fc_base_word),
    .bank_en(fc_rd_en), .bank_addr(fc_rd_addr),
    .bank_rdata(selected_read_a_data),
    .pix_data(fc_pix_data), .pix_valid(fc_pix_valid)
  );

  always_comb begin
    if (compute_fc_mode) begin
      core_pix_data = fc_pix_data;
      core_pix_valid = fc_pix_valid;
    end else begin
      core_pix_data = conv_pix_data;
      core_pix_valid = conv_pix_valid;
    end
    for (int c = 0; c < NC; c++)
      core_bank_ready[c] = (owner == 2'd1);
  end

  logic pool_rd_en [0:NC-1];
  logic [ADDR_W-1:0] pool_top_addr [0:NC-1];
  logic [ADDR_W-1:0] pool_bottom_addr [0:NC-1];
  logic pool_wr_en [0:NC-1];
  logic [ADDR_W-1:0] pool_wr_addr [0:NC-1];
  logic [15:0] pool_wr_data [0:NC-1];
  logic [1:0] pool_wr_strb [0:NC-1];

  banked_maxpool2x2 #(
    .NC(NC), .ADDR_W(ADDR_W), .DIM_W(DIM_W),
    .CHANNEL_W(CHANNEL_W), .MAX_CHANNELS(16)
  ) u_pool (
    .clk(clk), .rst_n(rst_n), .start(pool_start),
    .cfg_in_w(pool_in_w), .cfg_in_h(pool_in_h),
    .cfg_channels(pool_channels),
    .cfg_in_base_word(pool_in_base_word),
    .cfg_out_base_word(pool_out_base_word),
    .cfg_in_plane_words(pool_in_plane_words),
    .cfg_out_plane_words(pool_out_plane_words),
    .rd_en(pool_rd_en), .rd_top_addr(pool_top_addr),
    .rd_bottom_addr(pool_bottom_addr),
    .rd_top_data(selected_read_a_data),
    .rd_bottom_data(selected_read_b_data),
    .wr_en(pool_wr_en), .wr_addr(pool_wr_addr),
    .wr_data(pool_wr_data), .wr_strb(pool_wr_strb),
    .busy(pool_busy), .done(pool_done)
  );

  logic set0_a_en [0:NC-1];
  logic [1:0] set0_a_we [0:NC-1];
  logic [ADDR_W-1:0] set0_a_addr [0:NC-1];
  logic [15:0] set0_a_wdata [0:NC-1];
  logic [15:0] set0_a_rdata [0:NC-1];
  logic set0_b_en [0:NC-1];
  logic [ADDR_W-1:0] set0_b_addr [0:NC-1];
  logic [15:0] set0_b_rdata [0:NC-1];

  logic set1_a_en [0:NC-1];
  logic [1:0] set1_a_we [0:NC-1];
  logic [ADDR_W-1:0] set1_a_addr [0:NC-1];
  logic [15:0] set1_a_wdata [0:NC-1];
  logic [15:0] set1_a_rdata [0:NC-1];
  logic set1_b_en [0:NC-1];
  logic [ADDR_W-1:0] set1_b_addr [0:NC-1];
  logic [15:0] set1_b_rdata [0:NC-1];

  always_comb begin
    for (int c = 0; c < NC; c++) begin
      set0_a_en[c] = 1'b0;
      set0_a_we[c] = 2'b00;
      set0_a_addr[c] = '0;
      set0_a_wdata[c] = '0;
      set0_b_en[c] = 1'b0;
      set0_b_addr[c] = '0;
      set1_a_en[c] = 1'b0;
      set1_a_we[c] = 2'b00;
      set1_a_addr[c] = '0;
      set1_a_wdata[c] = '0;
      set1_b_en[c] = 1'b0;
      set1_b_addr[c] = '0;

      if (owner == 2'd0) begin
        if (!host_set) begin
          set0_a_en[c] = host_en[c];
          set0_a_we[c] = host_we[c];
          set0_a_addr[c] = host_addr[c];
          set0_a_wdata[c] = host_wdata[c];
        end else begin
          set1_a_en[c] = host_en[c];
          set1_a_we[c] = host_we[c];
          set1_a_addr[c] = host_addr[c];
          set1_a_wdata[c] = host_wdata[c];
        end
      end else if (owner == 2'd1) begin
        if (!read_set) begin
          set0_a_en[c] =
              compute_fc_mode ? fc_rd_en[c] : conv_rd_en[c];
          set0_a_addr[c] =
              compute_fc_mode ? fc_rd_addr[c] : conv_rd_addr[c];
        end else begin
          set1_a_en[c] =
              compute_fc_mode ? fc_rd_en[c] : conv_rd_en[c];
          set1_a_addr[c] =
              compute_fc_mode ? fc_rd_addr[c] : conv_rd_addr[c];
        end
        if (!write_set) begin
          set0_a_en[c] = core_bank_we[c];
          set0_a_we[c] = core_bank_wstrb[c];
          set0_a_addr[c] = core_bank_addr[c];
          set0_a_wdata[c] = core_bank_wdata[c];
        end else begin
          set1_a_en[c] = core_bank_we[c];
          set1_a_we[c] = core_bank_wstrb[c];
          set1_a_addr[c] = core_bank_addr[c];
          set1_a_wdata[c] = core_bank_wdata[c];
        end
      end else if (owner == 2'd2) begin
        if (!read_set) begin
          set0_a_en[c] = pool_rd_en[c];
          set0_a_addr[c] = pool_top_addr[c];
          set0_b_en[c] = pool_rd_en[c];
          set0_b_addr[c] = pool_bottom_addr[c];
        end else begin
          set1_a_en[c] = pool_rd_en[c];
          set1_a_addr[c] = pool_top_addr[c];
          set1_b_en[c] = pool_rd_en[c];
          set1_b_addr[c] = pool_bottom_addr[c];
        end
        if (!write_set) begin
          set0_a_en[c] = pool_wr_en[c];
          set0_a_we[c] = pool_wr_strb[c];
          set0_a_addr[c] = pool_wr_addr[c];
          set0_a_wdata[c] = pool_wr_data[c];
        end else begin
          set1_a_en[c] = pool_wr_en[c];
          set1_a_we[c] = pool_wr_strb[c];
          set1_a_addr[c] = pool_wr_addr[c];
          set1_a_wdata[c] = pool_wr_data[c];
        end
      end
    end
  end

  activation_bank_set #(
    .NC(NC), .ADDR_W(ADDR_W), .BANK_DEPTH(BANK_DEPTH)
  ) u_set0 (
    .clk(clk), .a_en(set0_a_en), .a_we(set0_a_we),
    .a_addr(set0_a_addr), .a_wdata(set0_a_wdata),
    .a_rdata(set0_a_rdata), .b_en(set0_b_en),
    .b_addr(set0_b_addr), .b_rdata(set0_b_rdata)
  );

  activation_bank_set #(
    .NC(NC), .ADDR_W(ADDR_W), .BANK_DEPTH(BANK_DEPTH)
  ) u_set1 (
    .clk(clk), .a_en(set1_a_en), .a_we(set1_a_we),
    .a_addr(set1_a_addr), .a_wdata(set1_a_wdata),
    .a_rdata(set1_a_rdata), .b_en(set1_b_en),
    .b_addr(set1_b_addr), .b_rdata(set1_b_rdata)
  );

  always_comb begin
    for (int c = 0; c < NC; c++) begin
      selected_read_a_data[c] =
          read_set ? set1_a_rdata[c] : set0_a_rdata[c];
      selected_read_b_data[c] =
          read_set ? set1_b_rdata[c] : set0_b_rdata[c];
      host_rdata[c] =
          host_set ? set1_a_rdata[c] : set0_a_rdata[c];
    end
  end

  logic host_read_fire_c;
  always_comb begin
    host_read_fire_c = 1'b0;
    for (int c = 0; c < NC; c++)
      host_read_fire_c |=
          (owner == 2'd0) && host_en[c] && !(|host_we[c]);
  end
  always_ff @(posedge clk) begin
    if (!rst_n)
      host_rvalid <= 1'b0;
    else
      host_rvalid <= host_read_fire_c;
  end

`ifdef SIMULATION
  assert property (@(posedge clk) disable iff (!rst_n)
      ((owner == 2'd1) || (owner == 2'd2)) |->
        (read_set != write_set));
  assert property (@(posedge clk) disable iff (!rst_n)
      owner <= 2'd2);
`endif

endmodule
