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

Every result slice is now scatter-written in N8-tile-major raster order. The
address mapper uses `base + (n_base / 8) * spatial * 8 + m_base * 8`, including
the second M8 half of split M16 convolution windows. Pool1, Pool2 and Pool5 are
also owned by the graph barrier: one complete raw N8 tile is read, max-pooled
through the shared pool service, and compacted in place before the scheduler
advances to the next layer. This correctness-first serialized path adds
465,152 bytes of DDR traffic per image (raw reads plus pooled writes).

Conv2 through FC8 input patches still come from the legacy K-major patch-tape
service. A later-layer patch assembler that consumes the new N8-tile-major
A/B tensors, plus the Pool5-to-FC6 flatten read, must therefore be connected
before this checkpoint can be called autonomous full-graph board inference.
The frozen format-v2 weight ABI is aligned to the N128 service: Conv3-5 use
N112 scheduler tiles and FC8's final N8 tail is zero-padded to one N16 beat.

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

## Verified 200 MHz result-layout and pooling checkpoint

Vivado 2025.2 generated the result-layout/pooling graph-payload `.bit` and
fixed `.xsa` on 2026-09-17. The clean flow's built-in post-route physical
optimization closes at WNS `+0.010 ns` (MET), TNS `0.000 ns`, WHS `+0.010 ns`
and THS `0.000 ns`; the separate recovery script was not needed. All 405,587
setup/hold endpoints meet timing. Route status has zero failed, unrouted or
partially routed nets, and DRC has zero errors or critical warnings.

| Resource | Used | Available | Utilization |
| --- | ---: | ---: | ---: |
| CLB LUT | 90,598 | 117,120 | 77.35% |
| CLB register | 90,869 | 234,240 | 38.79% |
| BRAM tile | 81.5 | 144 | 56.60% |
| URAM | 40 | 64 | 62.50% |
| DSP48E2 | 576 | 1,248 | 46.15% |

The DSP split is exactly 512 for the physical M8xN128 SA and 64 for parallel
requantization. Vectorless Vivado power is 3.575 W at medium confidence; it is
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
- exhaustive result address mapping across every N8 tile and layer boundary;
- in-place Pool1/2/5 service: all 64 N8 tiles and 11,040 golden output words,
  including randomized MM2S/S2MM backpressure;
- AXI DMA alignment/control, AXI-Lite registers, parameter-record loader and
  N128 weight ping-pong unit regressions also pass.

The C++ bit-exact golden `ctest`, five Linux runtime contract tests and the
full-byte format-v2 board-weight verifier pass at the same checkpoint.

Published local build hashes:

- `.bit`: `cf08108cc7e0aceb4ee122f6f8f52aea8563c7fb72444958423f9ed214826f8b`
- `.xsa`: `87b53c41633fee6e955ea25682fd0cddfc89f3531a19c68b85ae6ee5c1008dce`
- timing-clean `.dcp`:
  `b4299c42d98c83d46f934ca7e441395fe608a7c188f9ba39c6e0e8fb3dd1e316`

Build products remain under the ignored `build/` directory; the committed
sources, scripts, reports and hashes reproduce and identify the checkpoint.

## Next functional milestone

1. Assemble Conv2-5 patches directly from the N8-tile-major A/B buffers and
   connect Pool5 flattening to FC6, then close each layer and the complete
   Conv1-through-FC8 loop against the C++ golden model.
2. Schedule inactive-set weight fill concurrently with active-set compute,
   then use the hardware counters to compare shared versus dedicated HP3
   traffic.
3. Only after the batch-one board baseline is bit-exact, add batch 8 for FC
   weight amortization and measure images/s, DDR bytes/image and VCC_SOM
   energy over the same inference interval.
