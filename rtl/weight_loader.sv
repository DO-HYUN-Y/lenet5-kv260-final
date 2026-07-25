`timescale 1ns/1ps
// weight_loader.sv -- passive BRAM-address-driven weight reader
// (my_self.md sec.11.10, window_gen.sv header: "Weight Loader is a passive
// BRAM-address-driven reader that just follows k_out -- no independent FSM
// on that side"). No FSM here: address is combinational from k_out plus
// the quasi-static base_layer/pass_idx config inputs, memory read is
// registered (1-cycle latency, matches real SDP BRAM output register).
//
// 8 independent column banks (bank c = physical systolic column / filter),
// each addressed identically:
//   addr = base_layer + pass_idx*DEPTH + k_out      (DEPTH = K*K*C_IN)
// Conv mode only (fc_mode bank remap per sec.11.10/11.5.1 deferred until fc
// layers are built). Dummy-flush cycles from window_gen (band_n_active==0:
// pair_valid=1, depth_last=1, k_out=0(don't-care)) need no special handling
// here -- win_q is all-zero on that cycle so the data-gated MAC (sec.9.2)
// forces product=0 regardless of which weight word gets fetched.
//
// SDP: independent write (preload) / read (compute) ports. A one-cycle
// write-side register slice removes the high-fanout BRAM address/decode path
// from the external DMA timing boundary without reducing the one-word/cycle
// preload bandwidth. Layer/pass configuration is captured in token gaps and
// held while valid k tokens flow, so it cannot become a live I/O timing path.

module weight_loader #(
  parameter int ACT_W     = 8,
  parameter int NC        = 8,
  parameter int K         = 5,
  parameter int C_IN      = 2,
  parameter int DEPTH     = K * K * C_IN,
  parameter int MEM_DEPTH = 200,
  parameter int ADDR_W    = $clog2(MEM_DEPTH),
  parameter int KOUT_W    = $clog2(K*K*C_IN > 1 ? K*K*C_IN : 2)
) (
  input  logic clk,
  input  logic rst_n,          // async active-low
  input  logic en,             // shared compute enable; holds read payload on a stall

  // preload write port (DMA-style: same addr broadcast, per-bank data)
  input  logic                    wr_en,
  input  logic [ADDR_W-1:0]       wr_addr,
  input  logic signed [ACT_W-1:0] wr_data [0:NC-1],

  // compute-time follow of window_gen's k_out stream
  input  logic                    k_valid,       // = pair_valid[0]
  input  logic [KOUT_W-1:0]       k_out,
  input  logic                    depth_last_in, // = depth_last[0]
  input  logic [ADDR_W-1:0]       base_layer,    // quasi-static, set per layer
  input  logic [ADDR_W-1:0]       pass_idx,      // quasi-static, set per pass

  output logic signed [ACT_W-1:0] wgt_q [0:NC-1],
  output logic                    wgt_valid,
  output logic                    wgt_depth_last,
  output logic [KOUT_W-1:0]       wgt_k_out       // debug/scoreboard transaction tag
);

  // Write-side register slice. wr_en_q is deliberately independent of en:
  // weight DMA may fill a disjoint future-layer region while compute uses the
  // read port. The final preload word commits one clock after wr_en
  // deasserts; controller software must leave that normal pipeline drain.
  logic                    wr_en_q;
  logic [ADDR_W-1:0]       wr_addr_q;
  logic signed [ACT_W-1:0] wr_data_q [0:NC-1];
  logic [ADDR_W-1:0]       base_layer_q, pass_idx_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wr_en_q      <= 1'b0;
      wr_addr_q    <= '0;
      base_layer_q <= '0;
      pass_idx_q   <= '0;
      for (int c = 0; c < NC; c++) wr_data_q[c] <= '0;
    end else begin
      wr_en_q <= wr_en;
      if (wr_en) begin
        wr_addr_q <= wr_addr;
        for (int c = 0; c < NC; c++) wr_data_q[c] <= wr_data[c];
      end
      // k_valid is low during preload, line-buffer fill, band setup, and
      // drain. Once the stream is active this freezes the addressing config
      // for every real weight transaction.
      if (!k_valid) begin
        base_layer_q <= base_layer;
        pass_idx_q   <= pass_idx;
      end
    end
  end

  // Eight independent banks provide one weight per physical array column.
  // en controls only compute-time read state so a global datapath stall
  // preserves activation/weight alignment.
  // Wide combinational address calc: base_layer/pass_idx/k_out are each
  // ADDR_W or KOUT_W bits, but base_layer + pass_idx*DEPTH + k_out can need
  // more bits than ADDR_W alone before the caller-guaranteed in-range
  // truncation -- widen explicitly instead of letting a narrow declared
  // width silently wrap (see feedback: clog2/modulo-width overflow).
  // Address arithmetic is control-plane work; reserve DSP48s exclusively for
  // the 4x8 packed MAC array. DEPTH is a compile-time constant, so Vivado can
  // realize this small multiply as shift/add LUT logic.
  (* use_dsp = "no" *) logic [31:0] pass_offset;
  logic [31:0] addr_calc;
  always_comb begin
    pass_offset = 32'(pass_idx_q) * DEPTH;
    addr_calc = 32'(base_layer_q) + pass_offset + 32'(k_out);
  end

  // A separate process per column forces eight true independent BRAM banks.
  // The common address yields an 8-INT8 weight word every accepted k token.
  generate
    for (genvar c = 0; c < NC; c++) begin : g_weight_bank
      (* ram_style = "block" *)
      logic signed [ACT_W-1:0] mem [0:MEM_DEPTH-1];

      always_ff @(posedge clk) begin
        if (!rst_n) begin
          wgt_q[c] <= '0;
        end else begin
          if (wr_en_q) mem[wr_addr_q] <= wr_data_q[c];
          if (en) begin
            if (k_valid) wgt_q[c] <= mem[addr_calc[ADDR_W-1:0]];
            else wgt_q[c] <= '0;
          end
        end
      end
    end
  endgenerate

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wgt_valid      <= 1'b0;
      wgt_depth_last <= 1'b0;
      wgt_k_out      <= '0;
    end else if (en) begin
      wgt_valid      <= k_valid;
      wgt_depth_last <= k_valid && depth_last_in;
      wgt_k_out      <= k_valid ? k_out : '0;
    end
  end

`ifdef SIMULATION
  assert property (@(posedge clk) disable iff (!rst_n)
      !en |=> $stable({wgt_valid, wgt_depth_last, wgt_k_out}));
`endif

endmodule
