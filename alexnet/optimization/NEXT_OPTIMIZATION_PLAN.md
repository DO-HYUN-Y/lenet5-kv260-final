# AlexNet M8xN126 next optimization plan

Date: 2026-09-15

## Baseline entering the next milestone

- Keep the logical M8xN126 / physical M8xN128 array. Do not move to M16: DSP
  headroom exists, but block RAM and placed-CLB headroom are already tighter.
- The SA uses 512 DSP48E2 and the parallel requant path uses 64, for 576 total.
- A5 raises the representative shared Conv2 command from 94.060% to 96.337%
  useful PE utilization. Issue-ready, CE, post-reduce and egress stalls remain
  zero, and source starvation falls from 92 cycles to zero.
- The corrected profile separates 138 first-tile startup cycles from 379
  steady-state inter-tile cycles. The old 883-cycle aggregate included both.
- HP0, HP1, HP2 and HP3 are enabled. HP0 carries main MM2S, HP1 main S2MM,
  HP2 camera MM2S, and HP3 is enabled but has no weight DMA master yet.
- The 200 MHz resource-probe bitstream passes route and DRC with WNS/WHS
  +0.006/+0.011 ns, 70,951 LUT, 117.5 BRAM tiles, 32 URAM and 576 DSP48E2.
- The current M8xN126 bitstream is a self-test/resource probe, not a functional
  end-to-end AlexNet graph.

## A5: remove the remaining on-chip control bubble (completed)

The feeder now forms the next spatial descriptor while the current group emits,
then enters data wait directly instead of revisiting plan and endpoint states.
The issue controller accepts weight replay and the tile descriptor atomically
on the existing tile-clear cycle. The weight bank issues BRAM address zero on
that replay handshake and sustains one K word per cycle. A registered
`READ_ISSUE` stage remains in the feeder because removing it created a roughly
1.62 ns setup violation on the endpoint-to-BRAM-address path.

Exit gates:

- steady-state inter-tile cycles: 379, below 400: PASS;
- issue-ready, CE and egress-block stalls remain zero: PASS;
- useful PE utilization: 96.337%, at least 96%: PASS;
- full shared M8 post-route WNS/WHS: +0.040/+0.046 ns at 200 MHz: PASS.

The profiled command falls from 21,171 to 20,713 cycles, a 2.163% latency
reduction and 2.211% throughput gain over A4. This is an RTL shared-compute
result; it is not yet present in the resource-probe bitstream.

## B: functional M8xN126 graph migration (next)

0. **Completed:** add a two-set M16 activation-patch ping-pong. Each set is
   4,096 x 128 bit, so address K supplies sixteen spatial values to the dynamic
   array. Randomized overlap/backpressure XSim passes, and the block routes at
   200 MHz with four URAM, WNS +0.434 ns and WHS +0.055 ns.
1. Add the x-mod-4 activation store and patch assembler. Its read contract
   must produce one M16 patch word per K while the other patch set replays;
   test stride 4, row crossings, padding, and M tails explicitly.
2. Replace the resource-probe command generator with the graph scheduler and
   real activation/weight/result DMA payload path. Keep a spatial output tile
   resident through the true final K token instead of expanding the raster
   partial-sum BRAM sixteenfold.
3. Retain logical N=126 masking and verify all AlexNet layer tails.
4. Compare every layer with the C++ golden model, then run a complete image
   comparison with exact INT8/requant parameters.
5. Add timeout, tile/tag ordering, result-count and non-overwrite assertions.

Exit gates:

- Conv1 through FC8 match the golden model;
- no XSim assertion, timeout, or AXI protocol failure under randomized
  backpressure;
- top route has zero failed nets, zero DRC errors and non-negative WNS/WHS.

## C: dedicate HP3 to weight traffic

1. Instantiate an independent MM2S engine for weights and connect it to HP3.
2. Fill the inactive URAM ping-pong set while the active set replays.
3. Add counters for bytes, bursts, outstanding reads, `ARVALID&&!ARREADY`,
   stream-starvation cycles and fill/compute overlap cycles.
4. Measure one-port and HP3-separated configurations with identical workloads.

Exit gates:

- no regression in numerical results or timing closure;
- convolution weight fills complete before active-set retirement;
- report measured throughput change instead of theoretical port bandwidth.

## D: batch 8 after the batch-1 board baseline

Batch 8 is intentionally deferred until the functional batch-1 path is
correct and instrumented. Convolution already has spatial reuse; batching is
primarily useful for amortizing FC weight traffic. Implement activation/result
buffer capacity checks, batch tags and FC scheduling only after the HP3
measurement identifies the actual bandwidth limit.

Exit gates:

- batch 1 and batch 8 are bit-exact against the golden model;
- report images/s, per-image latency, DDR bytes/image and energy/image for both;
- reject batch 8 if it raises throughput only by hiding a correctness or queue
  overflow issue.

## E: board measurement and TOPS/W

Use hardware counters to time the exact inference interval and measure
VCC_SOM energy over that same interval. Report arithmetic peak separately from
useful operations, end-to-end images/s and effective TOPS/W. Vivado vectorless
power and RTL PE utilization remain planning numbers, not board results.

Final release requires repeatable warm runs, counter overflow handling, clock
verification at 200 MHz, and archived bitstream/XSA hashes plus the Vivado
timing, utilization, route, DRC and power reports.
