# AlexNet M8xN126 next optimization plan

Date: 2026-09-17

## 2026-09-16 graph-payload top update

The earlier pre-raster checkpoint integrated the descriptor scheduler, N128
weight ping-pong, M16 patch ping-pong,
physical M8xN128 SA, parallel requantizer, result packer and four-HP KV260
shell are now integrated in one board top. HP3 owns an independent weight
MM2S DMA. The SA-to-requant boundary now captures 64 INT32 results and slice
metadata in fabric registers. That checkpoint generated a clean 200 MHz bitstream and
XSA without recovery: WNS/TNS/WHS are `+0.151/0.000/+0.010 ns`, failed route
nets and DRC errors/critical warnings are zero, and the implemented resources
are 78,971 LUT, 87,800 registers, 9 BRAM tiles, 36 URAM and 576 DSP48E2.

Conv1 raster assembly and the format-v2 N16-aligned weight ABI are integrated
in the same board top. The 2026-09-17 clean 200 MHz bitstream closes at
WNS/TNS/WHS `0.000/0.000/+0.010 ns` with the timing report marked MET, zero
failed route nets and zero DRC errors or critical warnings. It uses 89,451
LUT, 90,271 registers, 73 BRAM tiles, 40 URAM and 576 DSP48E2. Conv1 HP0 reads
fall from the 1,103,520-byte K-major patch tape to a 401,408-byte N8 raster, a
702,112-byte (63.6%) static reduction.

The next 2026-09-17 checkpoint connects exact scatter/in-place-pool storage to
a later-layer N8 activation cache. Conv2-5 windows, Pool5-to-FC6 channel-major
flattening and FC7/8 linear reads are now generated inside the integrated top;
the legacy later-layer patch tape is removed. Its clean 200 MHz route closes at
WNS/WHS `+0.001/+0.008 ns`, with zero failed nets and zero DRC errors/critical
warnings. It uses 90,251 CLB LUTs, 91,247 registers, 96 BRAM tiles, 40 URAM and
576 DSP48E2. The graph is structurally connected but is not yet claimed as
bit-exact end-to-end inference: layerwise/full-image golden comparison and
physical-board validation remain. Weight fill is also still serialized before
compute.
The completed capture stage adds exactly one active cycle per emitted N8 slice;
it does not add a cycle to every K issue.

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
  HP2 camera MM2S, and HP3 now carries an independent weight MM2S DMA.
- The 200 MHz resource-probe bitstream passes route and DRC with WNS/WHS
  +0.006/+0.011 ns, 70,951 LUT, 117.5 BRAM tiles, 32 URAM and 576 DSP48E2.
- The current M8xN126 bitstream accepts a normal Conv1 raster, scatter-stores
  every result, pools layers 1/2/5 in place, and reloads each later activation
  tensor once into the exact Conv2-FC8 patch/flatten service. The service uses
  zero DSP and 14 RAMB36E2 plus one RAMB18E2 OOC. Full-graph numerical proof
  and board measurement are the remaining functional gates.

## Full-graph descriptor checkpoint

The batch-1 Conv1-through-FC8 scheduler is now RTL rather than a spreadsheet
projection. Randomized command/completion backpressure XSim verifies 1,635
work descriptors, 714,188,480 useful MACs, 61,090,496 logical weight bytes and
61,123,264 N16-aligned transfer bytes. The standalone scheduler routes at
200 MHz with 260 CLB LUTs, 97 registers, WNS +0.459 ns and WHS +0.088 ns. This proves graph
enumeration and all M/N/K tails; it does not yet prove the numerical payload
path.

The physical-slot accounting is intentionally reported separately from useful
work:

| Boundary | Useful MACs | Physical M8xN128 slots | Slot utilization |
| --- | ---: | ---: | ---: |
| FC6 | 37,748,736 | 2,415,919,104 | 1.5625% |
| FC7 | 16,777,216 | 1,073,741,824 | 1.5625% |
| FC8 | 4,096,000 | 264,241,152 | 1.5501% |
| FC6-FC8 | 58,621,952 | 3,753,902,080 | 1.5616% |
| Conv1-FC8 | 714,188,480 | 4,595,623,936 | 15.5406% |

The FC percentage is low because batch 1 uses one of eight physical M rows
and one bandwidth-matched N16 bank out of eight. It is not a claim that an
enabled FC compute burst performs at 1% efficiency. At the 0.4096 physical
peak, the descriptor-only full-graph ceiling is about 0.06365 TOPS and 44.56
images/s before feeder, control and DDR protocol overhead. These are analytic
RTL scheduling ceilings, not board measurements.

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

## B: functional M8xN126 graph migration (in progress)

0. **Completed:** add a two-set M16 activation-patch ping-pong. Each set is
   4,096 x 128 bit, so address K supplies sixteen spatial values to the dynamic
   array. Randomized overlap/backpressure XSim passes, and the block routes at
   200 MHz with four URAM, WNS +0.434 ns and WHS +0.055 ns.
1. **Completed bridge checkpoint:** the existing 16-read M16 feeder now fills
   the inactive patch set while the other set replays. Golden-coordinate XSim
   passes stride 4/K11/padding, stride 1/K3, cross-row groups, M tails and
   randomized replay backpressure. The complete bridge routes at 200 MHz with
   6,862 CLB LUTs, 3,101 registers, 112 RAMB36E2, four URAM, WNS +0.185 ns,
   WHS +0.055 ns, zero routing errors and zero DRC checks. Replace the
   replicated read store with x-mod-4 banking behind this verified interface
   to reduce BRAM cost.
2. **Completed control checkpoint:** replace the resource-probe command
   generator with a batch-1 Conv1-through-FC8 work scheduler. It uses split
   `2xM8xN64` for Conv1/2, logical N126 masks for Conv3-5, and one N16 bank for
   bandwidth-matched FC6-8. All layer counts, FC6 K chunks and tails pass
   XSim.
3. **Completed graph-payload checkpoint:** descriptors now drive the N128
   weight ping-pong, M16 patch ping-pong, dynamic SA, parallel requantizer and
   result stream. Two Conv1 tiles pass integrated XSim and the four-HP board
   top produces a timing-clean bitstream/XSA. The registered SA-to-requant
   boundary gives the clean top WNS `+0.151 ns`; tile and graph OOC WNS are
   `+0.099 ns` and `+0.024 ns`.
4. **Completed Conv1 raster checkpoint:** AXIS128 normal raster input now feeds
   the x-mod-4 M16 patch service. Standalone XSim covers full 224x224 Conv1 and
   randomized backpressure; OOC route closes at WNS/WHS `+0.057/+0.101 ns`
   with 64 RAMB36, four URAM and zero DSP. The integrated clean top closes at
   WNS/WHS `+0.016/+0.010 ns` and reduces the Conv1 DDR-read contract by 63.6%.
5. **Completed and promoted into the 200 MHz bitstream:** Conv3..5 now use N112
   tiles so every `n_base` and transfer stays N16 aligned without changing
   command count, useful MACs or physical slot count. The format-v2 exporter
   emits scheduler-N-tile/K/N16 order and zero-pads only FC8's final N8 tail.
   Official-checkpoint export and the independent verifier pass for
   61,123,264 transferred bytes (61,090,496 logical plus 32,768 padding). The
   rebuilt top closes at WNS/WHS `0.000/+0.010 ns` with zero failed nets and
   generated a bitstream and bitstream-bearing XSA.
6. **Completed and promoted into the 200 MHz bitstream:** result slices use
   exact N8-tile-major scatter addresses, Pool1/2/5 compact in place, and the
   activation service loads each later tensor once before assembling Conv2-5
   K-major M16 windows, FC6 channel-major flatten order and FC7/8 linear order.
   XSim checks seven loads, nine representative requests and 21,632 words. The
   integrated top closes at WNS/WHS `+0.001/+0.008 ns` with 90,251 CLB LUTs,
   96 BRAM tiles, 40 URAM, 576 DSP48E2 and zero failed route nets.
7. **Next:** compare every layer with the C++ golden model, then run a complete
   image comparison with exact INT8/requant parameters. Add timeout, tile/tag
   ordering, result-count and non-overwrite assertions around the full loop.
8. After correctness, add counters around the one-lane activation service and
   pipeline/bank it according to measured activation-starvation and issue
   stalls rather than analytic bandwidth alone.

Exit gates:

- Conv1 through FC8 match the golden model;
- no XSim assertion, timeout, or AXI protocol failure under randomized
  backpressure;
- top route has zero failed nets, zero DRC errors and non-negative WNS/WHS.

## C: dedicate HP3 to weight traffic

1. **Completed:** instantiate an independent MM2S engine for weights and
   connect it to HP3.
2. **Next:** fill the inactive URAM ping-pong set while the active set replays.
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
