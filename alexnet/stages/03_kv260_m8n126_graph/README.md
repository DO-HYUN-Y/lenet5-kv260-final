# KV260 M8xN126 graph-payload integration

This stage replaces the stage-02 resource probe with the descriptor-driven
batch-one AlexNet scheduler, N128 weight ping-pong, M16 patch ping-pong,
physical M8xN128 compute array, parallel requantizer, result packer and AXI-Lite
performance counters. The logical output width remains N126 and the physical
compute contract remains 512 SA DSP48E2 plus 64 requantizer DSP48E2.

## Four independent HP paths

- HP0: patch and parameter MM2S
- HP1: result S2MM
- HP2: camera MM2S
- HP3: weight MM2S

The main and weight AXI DMA register banks are controlled independently by the
accelerator. Weight traffic therefore no longer shares the main MM2S memory
port. The current graph engine requests a weight tile and then computes it;
overlapping the inactive weight ping-pong fill with the active tile is a later
scheduling optimization and is not claimed by this checkpoint.

## Storage contract

The patch stream currently uses the engine's transposed K-major M16 tape. It is
not yet an autonomous raster feature-map-to-patch traversal. Consequently this
stage validates the integrated graph-payload hardware and board routing, but a
board-run image packer must supply the documented tape format. Connecting the
x-mod-4 raster assembler and writing each layer's results in the exact next-layer
layout remain the final functional full-graph storage milestone.

## Build

From this directory, run:

```sh
vivado -mode batch -source scripts/build_kv260_m8n126_graph.tcl
```

The script publishes the `.bit` and `.xsa` only after synthesis, route, setup,
hold, DRC, 512-SA/576-total DSP, and 36-URAM checks all pass.

If the clean flow leaves only a small setup violation, preserve its post-route
checkpoint and run:

```sh
vivado -mode batch -source scripts/recover_kv260_m8n126_graph_timing.tcl
```

The recovery flow applies aggressive post-route physical optimization and, if
needed, timing-driven rerouting before repeating all signoff gates.

## Verified 200 MHz checkpoint

Vivado 2025.2 generated the graph-payload `.bit` and fixed `.xsa` on
2026-09-16. An explicit SA-result capture stage now registers all 64 INT32
values plus slice metadata before the parallel requantizer. The clean build,
without post-route recovery, closes at WNS `+0.151 ns`, TNS `0.000 ns`, WHS
`+0.010 ns` and THS `0.000 ns`. All 393,038 setup/hold endpoints meet timing.
Route status has zero failed, unrouted or partially routed nets, and DRC has
zero errors or critical warnings.

| Resource | Used | Available | Utilization |
| --- | ---: | ---: | ---: |
| CLB LUT | 78,971 | 117,120 | 67.43% |
| CLB register | 87,800 | 234,240 | 37.48% |
| BRAM tile | 9 | 144 | 6.25% |
| URAM | 36 | 64 | 56.25% |
| DSP48E2 | 576 | 1,248 | 46.15% |

The DSP split is exactly 512 for the physical M8xN128 SA and 64 for parallel
requantization. Vectorless Vivado power is 3.422 W at medium confidence; it is
not a board TOPS/W measurement. The capture boundary costs one cycle per
emitted N8 result slice, not one cycle per K issue. The tile XSim active count
changes from 281 to 302 and the two-command graph test from 1,088 to 1,123,
while all result bytes, masks, tags and MAC accounting remain bit-exact. The
tile and graph-payload OOC routes close at WNS `+0.099 ns` and `+0.024 ns`,
respectively.

The following XSim gates pass after the bitstream build:

- full scheduler: 1,635 commands, 714,188,480 useful MACs;
- x-mod-4 M16 patch bridge: 205 fills/replays and 69,714 overlap cycles;
- M8xN128 tile payload: 886 result bytes with
  wide/split/FC/K-continuation/result-stall coverage;
- integrated graph payload: two Conv1 tiles, 1,452 weight words, 726 patch
  words and 2,048 result bytes; capture-stage active cycles are included.
- AXI DMA alignment/control, AXI-Lite registers, parameter-record loader and
  N128 weight ping-pong unit regressions also pass.

Published local build hashes:

- `.bit`: `cf8521fc18fb3eef95019ea50a6bc228e01a216f3ed108b2f36b7c2e616808a1`
- `.xsa`: `89b507df304b7326c1985f96c84eeda56f670655b586b6043da30758cb33d40e`
- timing-clean `.dcp`:
  `601b851e8ab81b131a4e2c52e76ee677938d5bbdb3d43fb05831582b0ef12405`

Build products remain under the ignored `build/` directory; the committed
sources, scripts, reports and hashes reproduce and identify the checkpoint.

## Next functional milestone

1. Connect the x-mod-4 raster assembler to the top so software can submit
   normal feature-map rasters instead of pretransposed K-major M16 tape.
2. Store every layer in the exact layout consumed by the next layer and close
   the Conv1-through-FC8 numerical loop against the C++ golden model.
3. Schedule inactive-set weight fill concurrently with active-set compute,
   then use the hardware counters to compare shared versus dedicated HP3
   traffic.
4. Only after the batch-one board baseline is bit-exact, add batch 8 for FC
   weight amortization and measure images/s, DDR bytes/image and VCC_SOM
   energy over the same inference interval.
