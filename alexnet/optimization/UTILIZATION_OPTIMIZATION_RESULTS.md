# AlexNet M8xN126 utilization optimization results

## 2026-09-16 integrated graph-payload follow-up

The optimized logical M8xN126 / physical M8xN128 payload is now inside a
four-HP KV260 top rather than only the stage-02 resource probe. HP3 has an
independent weight MM2S DMA. The final 200 MHz recovery checkpoint reports
WNS/TNS/WHS `0.000/0.000/+0.010 ns`, zero failed route nets, zero DRC errors
or critical warnings, 78,630 LUT, 86,172 registers, 9 BRAM tiles, 36 URAM and
576 DSP48E2. Vivado generated both the bitstream and fixed XSA.

Scheduler, x-mod-4 patch bridge, tile payload and integrated graph-payload
XSim regressions all pass after the build. The scheduler covers 1,635 commands
and 714,188,480 useful MACs. This does not replace a board utilization or
TOPS/W result: patch input still uses a pretransposed tape, inactive weight
fill does not yet overlap compute, and the inter-layer result layout is not
closed. Vectorless power is 3.420 W at medium confidence and must not be
reported as measured VCC_SOM power.

The next utilization work is structural timing margin at the SA-to-requant
boundary, normal raster assembly, exact next-layer storage, HP3 fill/compute
overlap, then matched-interval batch-one board cycle and energy measurement.

- Date: 2026-09-15
- Device: Kria K26 (`xck26-sfvc784-2LV-c`)
- Clock: 200 MHz
- Logical array: M8xN126
- Physical array: M8xN128
- Compute mode in the probe: two concurrent M8xN64 spatial groups
- DSP contract: 512 SA + 64 parallel requant = 576 DSP48E2

## Implemented changes

The row-stationary feeder now scans the next input rows while the current
window is issuing. Spatial M groups are flat across raster rows, so a short
tail is paid only once at the end of the tensor. BRAM reads are pipelined, and
each lane carries a registered physical ring address instead of recomputing a
runtime modulo and row multiplication on the BRAM path.

The ring holds `kernel + stride` rows. `kernel + 1` is insufficient for
stride-four Conv1 because one flat group may contain points from two adjacent
output rows while the scanner is already advancing toward the second group's
endpoint. The maximum AlexNet case is therefore 15 rows. Sixteen replicated
read copies, with seven width banks per copy, infer 112 RAMB36E2.

The scalar and dual-accumulator result slices were also changed to derive M
position and tile tag from the flat output-word index. This preserves output
ordering when one M group crosses a raster-row boundary.

The A4 result-overlap change adds one pending output descriptor and tracks up
to two accepted final issues. Compute is released on accepted `issue_last`
instead of waiting for the previous result wavefront and snapshot handshake.
The M8xN126 compute island likewise starts the next tile while the five-stage
requant tail drains; the final tile waits in a separate completion state.

The A5 inter-tile change prepares the next feeder group descriptor while the
current group emits, accepts resident-weight replay and tile start atomically,
and issues the first synchronous BRAM weight read on the replay handshake. It
retains a registered feeder read-address stage: a trial that drove the BRAM
address directly from endpoint arithmetic missed placement timing by about
1.62 ns and was rejected.

## Feeder performance

The table compares the saved pre-change M16 feeder profile with the final
always-valid/always-ready DPI-golden profile.

| Shape | Cycles before | Cycles after | Speedup | Issue duty after | Useful M utilization after |
| --- | ---: | ---: | ---: | ---: | ---: |
| Conv1, 224x224 C3 K11/s4 | 132,284 | 72,458 | 1.825x | 95.186% | 94.717% |
| Conv2, 27x27 C8 K5/s1 | 11,869 | 9,643 | 1.231x | 95.406% | 94.499% |
| Conv3/4/5, 13x13 C8 K3/s1 | 1,187 | 1,006 | 1.180x | 78.728% | 75.596% |
| 16x16 C8 K3/s1 | 1,508 | 1,299 | 1.161x | 88.684% | 88.684% |
| 17x17 C8 K3/s1 | 2,877 | 1,626 | 1.769x | 84.133% | 79.982% |
| 32x32 C8 K3/s1 | 5,892 | 5,075 | 1.161x | 90.798% | 90.798% |

For Conv1, input scan takes 51,984 cycles but is hidden under 68,970 issue
cycles. Explicit BRAM read issue/capture occupies 190 + 190 cycles. The
remaining difference between total and issue cycles is endpoint planning,
initial fill and tensor-boundary control.

## Complete shared-compute stall classification

The complete representative Conv2 command includes DMA-fed activation and
weight storage, feeder, shared SA, accumulation, result scan and output path.
Artificial CE stalls are disabled.

| Class | Before A4 | After A4 | After A5 | A5 share |
| --- | ---: | ---: | ---: | ---: |
| Useful issue | 18,400 | 18,400 | 18,400 | 97.262% |
| Feeder/source starvation | 92 | 92 | 0 | 0.000% |
| Issue-ready backpressure | 0 | 0 | 0 | 0.000% |
| CE stall | 0 | 0 | 0 | 0.000% |
| Post-reduce/result work | 1,469 | 0 | 0 | 0.000% |
| Frontend startup + inter-tile | 415 | 883 | 517 | 2.733% |
| Other | 1 | 1 | 1 | 0.005% |

The A5 monitor separates the final 517-cycle frontend boundary into 138 cycles
before the first tile and 379 steady-state inter-tile cycles. Older profiles
reported these as one class, so 883-to-517 is the like-for-like aggregate
comparison; the reduction is 41.45%. Of the remaining 379 steady cycles, the
feeder is observed in idle/read-wait/read-issue/read-capture/emit for
14/91/91/91/92 cycles. Controller and weight-bank observations are both ready
for all 379 cycles; they overlap rather than add to the total.

A4 first reduced the compute window from 20,377 to 19,376 cycles and raised
lane-weighted useful PE utilization from 89.439% to 94.060%. A5 reduces it
again to 18,918 cycles and raises utilization to 96.337%. The containing
command falls from 21,171 to 20,713 cycles with the same 1,785 DMA-active
cycles: 2.163% lower latency and 2.211% higher throughput over A4. Source
starvation is eliminated without introducing issue-ready, CE, post-reduce, or
egress stalls.

## STA and implemented resources

| Build | WNS | WHS | Result |
| --- | ---: | ---: | --- |
| M16 feeder OOC | +0.229 ns | +0.087 ns | PASS |
| M8 feeder OOC after A5 | +0.343 ns | +0.091 ns | PASS |
| Full shared M8 compute OOC after A5, post-route | +0.040 ns | +0.046 ns | PASS |
| M8xN126 compute island OOC, post-synth | +0.468 ns | +0.046 ns | PASS |
| KV260 probe top, post-route | +0.006 ns | +0.011 ns | PASS |

The KV260 probe top has zero failed-route nets and zero DRC errors or critical
warnings.

| Resource | Used | Available | Utilization | Remaining |
| --- | ---: | ---: | ---: | ---: |
| LUT | 70,951 | 117,120 | 60.58% | 46,169 |
| FF | 74,521 | 234,240 | 31.81% | 159,719 |
| BRAM tile | 117.5 | 144 | 81.60% | 26.5 |
| URAM | 32 | 64 | 50.00% | 32 |
| DSP48E2 | 576 | 1,248 | 46.15% | 672 |

BRAM, not DSP, is the tightest remaining primitive. CLB placement is 79.78%
even though LUT utilization is 60.58%, so future wide control/fanout logic must
also be checked after route rather than accepted from LUT count alone.

The first clean route with `Performance_ExploreWithRemap` missed setup at
-0.102 ns with 981 failing endpoints. Rebuilding with
`Performance_ExplorePostRoutePhysOpt` changed placement, reduced routing
pressure and closed both setup and hold. This is why the implementation
strategy is part of the reproducible build script rather than a manual GUI
setting.

## Throughput and TOPS/W interpretation

At 200 MHz and `1 MAC = 2 OPS`:

- physical M8xN128 peak: 0.4096 TOPS;
- logical M8xN126 peak: 0.4032 TOPS;
- Conv1 feeder-limited estimate at 94.717%: 0.3819 TOPS;
- representative shared-compute estimate after A5 at 96.337%: 0.3884 TOPS.

These are RTL compute rates, not end-to-end AlexNet board throughput. Applying
the shared-compute rate to the model's 1.42837696 GOP/image gives an optimistic
271.9 image/s upper estimate before DDR, pooling, scheduling and software
overhead.

Vivado's vectorless report estimates 3.562 W for the complete device, including
2.435 W attributed to the PS. Dividing by that estimate gives 0.113 logical
peak TOPS/W or 0.109 representative effective TOPS/W. These are planning
numbers only. Reportable TOPS/W must use a board run, hardware cycle counters,
and measured VCC_SOM energy over the same inference interval.

## Verification completed

- C++ golden model CTest: PASS.
- M4, M8 and M16 feeder randomized backpressure plus DPI golden comparison:
  PASS.
- Row-stationary base, resident-weight, accumulator, dual-accumulator and
  activation-resident integration XSim: PASS.
- DMA ingress, full DMA loop and scheduler XSim for Conv2 and Conv3: PASS.
- Dynamic M8xN128 / 2xM8xN64 SA randomized XSim: PASS.
- M8xN128 compute-island XSim: PASS; 435,456 useful MACs, no weight or
  activation stall, deterministic signature `fae9d3f8`, and active cycles
  reduced from 1,403 to 1,328 while result-stall cycles remain 336.
- Full M4 and M8 shared Conv+FC XSim with randomized output backpressure: PASS.
- Graph compute orchestrator and graph controller XSim: PASS.
- A5 weight-bank DPI golden, M8 feeder randomized-backpressure/DPI golden,
  Conv2/Conv3 scheduled DMA loop, shared Conv+FC, graph controller and graph
  orchestrator regressions: PASS.
- M8 feeder and full shared-compute OOC implementation at 200 MHz, plus the
  existing top bitstream resource/timing contracts: PASS.

Published hardware files:

- `alexnet/stages/02_kv260_m8n126_probe/build/output/alexnet_m8n126_kv260.bit`
- `alexnet/stages/02_kv260_m8n126_probe/build/output/alexnet_m8n126_kv260.xsa`

SHA-256:

- `.bit`: `b7f893e78659c8eb858c49b0485de44e94b1a6c81a8f164bd2ffcce74821866a`
- `.xsa`: `bd7346e7cfe28e2e810fcdce0b75472347d79dc7d47152938505639d07baf9f5`

## Next implementation order

1. Integrate the M8xN126 compute island into the functional graph top. The
   current bitstream is a self-testable resource/timing probe and does not
   consume the board DMA payloads.
2. Add a dedicated weight MM2S DMA on the already-enabled HP3 port and fill the
   inactive URAM weight set while the active set replays.
3. Add AXI counters for read bytes, outstanding transactions,
   `ARVALID&&!ARREADY`, stream starvation and overlap cycles.
4. Establish a functional batch-1 board baseline before enabling batch 8, then
   measure end-to-end images/s and VCC_SOM TOPS/W over the same interval.
