# KV260 M8xN126 graph-payload integration

This stage replaces the stage-02 resource probe with the descriptor-driven
batch-one AlexNet scheduler, N128 weight ping-pong, M16 patch ping-pong,
physical M8xN128 compute array, parallel requantizer, result packer and AXI-Lite
performance counters. The logical output width remains N126 and the physical
compute contract remains 512 SA DSP48E2 plus 64 requantizer DSP48E2.

## Four independent HP paths

- HP0: Conv1 raster, later-layer patch and parameter MM2S
- HP1: result S2MM
- HP2: camera MM2S
- HP3: weight MM2S

The main and weight AXI DMA register banks are controlled independently by the
accelerator. Weight traffic therefore no longer shares the main MM2S memory
port. The current graph engine requests a weight tile and then computes it;
overlapping the inactive weight ping-pong fill with the active tile is a later
scheduling optimization and is not claimed by this checkpoint.

## Storage contract

Conv1 now accepts the normal `224x224xN8` raster contract. HP0 reads 401,408
bytes, the AXIS128 unpacker restores N8 words, and the x-mod-4 feeder assembles
the K-major M16 patches consumed by the graph engine. The previous Conv1 patch
tape was 1,103,520 bytes, so the RTL byte contract removes 702,112 bytes
(63.6%) of Conv1 DDR reads per image. This is a static traffic reduction, not a
measured board-throughput result.

Conv2 through FC8 still use the legacy patch-tape service. Exact result
placement and Pool1/2/5 ownership must therefore be completed before this
checkpoint can be called an autonomous full-graph board inference. The frozen
format-v2 weight ABI is now aligned to the N128 service: Conv3-5 use N112
scheduler tiles and FC8's final N8 tail is zero-padded to one N16 beat.

## Build

From this directory, run:

```sh
vivado -mode batch -source scripts/build_kv260_m8n126_graph.tcl
```

The script publishes the `.bit` and `.xsa` only after synthesis, route, setup,
hold, DRC, 512-SA/576-total DSP, and 40-URAM checks all pass.

If the clean flow leaves only a small setup violation, preserve its post-route
checkpoint and run:

```sh
vivado -mode batch -source scripts/recover_kv260_m8n126_graph_timing.tcl
```

The recovery flow applies aggressive post-route physical optimization and, if
needed, timing-driven rerouting before repeating all signoff gates.

## Verified 200 MHz format-v2 checkpoint

Vivado 2025.2 generated the Conv1-raster graph-payload `.bit` and fixed `.xsa`
on 2026-09-17. The clean flow's built-in post-route physical optimization
closes at WNS `0.000 ns` (MET), TNS `0.000 ns`, WHS `+0.010 ns` and THS
`0.000 ns`; the separate recovery script was not needed. All 403,103
setup/hold endpoints meet timing. Route status has zero failed, unrouted or
partially routed nets, and DRC has zero errors or critical warnings.

| Resource | Used | Available | Utilization |
| --- | ---: | ---: | ---: |
| CLB LUT | 89,451 | 117,120 | 76.38% |
| CLB register | 90,271 | 234,240 | 38.54% |
| BRAM tile | 73 | 144 | 50.69% |
| URAM | 40 | 64 | 62.50% |
| DSP48E2 | 576 | 1,248 | 46.15% |

The DSP split is exactly 512 for the physical M8xN128 SA and 64 for parallel
requantization. Vectorless Vivado power is 3.558 W at medium confidence; it is
not a board TOPS/W measurement. The scheduler still emits 1,635 commands and
714,188,480 useful MACs. Its physical weight-transfer contract is 61,123,264
bytes: 61,090,496 logical weights plus 32,768 zero-padding bytes at the FC8
tail. The capture boundary costs one cycle per emitted N8 result slice, not
one cycle per K issue.

The following XSim gates pass after the bitstream build:

- full scheduler: 1,635 commands, 714,188,480 useful MACs;
- x-mod-4 M16 patch bridge: 205 fills/replays and 69,714 overlap cycles;
- AXIS128 raster-to-M16 patch service: 205 fills/replays and 71,214 checked
  patch words across K11/s4/p2, K3/s1/p1 and full 224x224 Conv1 cases;
- M8xN128 tile payload: 886 result bytes with
  wide/split/FC/K-continuation/result-stall coverage;
- integrated graph payload: two Conv1 tiles, 1,452 weight words, 726 patch
  words and 2,048 result bytes; capture-stage active cycles are included.
- AXI DMA alignment/control, AXI-Lite registers, parameter-record loader and
  N128 weight ping-pong unit regressions also pass.

Published local build hashes:

- `.bit`: `cf34a9eaa88774ac6a726e5e5d6d9200c210b84acf39ec3823f6ef8e9b36b9cd`
- `.xsa`: `5b3b88dd35a804ac54dab609f1fecbfc469dd1cd4692fdfddba14415dc7c7413`
- timing-clean `.dcp`:
  `469216d7c001c573e0e1034c52455b539d99df132ec198840a09f7838d296927`

Build products remain under the ignored `build/` directory; the committed
sources, scripts, reports and hashes reproduce and identify the checkpoint.

## Next functional milestone

1. Store every layer in the exact layout consumed by the next layer, integrate
   Pool1/2/5 ownership, and close
   the Conv1-through-FC8 numerical loop against the C++ golden model.
2. Schedule inactive-set weight fill concurrently with active-set compute,
   then use the hardware counters to compare shared versus dedicated HP3
   traffic.
3. Only after the batch-one board baseline is bit-exact, add batch 8 for FC
   weight amortization and measure images/s, DDR bytes/image and VCC_SOM
   energy over the same inference interval.
