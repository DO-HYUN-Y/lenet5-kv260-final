# AlexNet M8xN128 dynamic-array bandwidth contract — 2026-09-11

## Decision

The physical compute fabric is eight local `M8xN16` banks.  Runtime scheduling
supports one `M8xN128` tile or two independent `M8xN64` tiles.  The latter acts
as `M16xN64` for Conv1/Conv2 by assigning a different spatial M group to each
four-bank cluster.  Physical compute remains 512 packed DSP48E2s, 1,024 logical
INT8 MAC/cycle and 0.4096 arithmetic-peak TOPS at 200 MHz.

The array is feasible only with the following memory changes:

1. Keep all systolic skew local to N16 banks.
2. Supply two independent M8 activation groups in split mode.
3. Implement the 1,024-bit/cycle weight replay port as eight 128-bit N16
   URAM banks.
4. Do not scale the existing full-raster N8 partial-sum BRAM by sixteen.
   Traverse K chunks consecutively for one output tile and retain its partial
   sums in the PE accumulators until the true final K token.
5. Drain the 4 KiB INT32 result holding set through 64 pipelined postprocess
   lanes in sixteen cycles while the next reduction executes.

## Implemented and measured in this milestone

The compute and activation-read widths are now physical RTL results rather
than projections:

| Block | Routed resources | 200 MHz timing | Verified behavior |
| --- | --- | --- | --- |
| Dynamic SA | 512 DSP48E2, 46,694 CLB LUT, 57,036 FF | WNS +0.564 ns, WHS +0.046 ns | M8xN128, 2xM8xN64, independent tags/tails/backpressure and per-N16 bank enable |
| M16 RS feeder | 112 RAMB36E2, 6,476 CLB LUT, 2,717 FF | WNS +0.229 ns, WHS +0.087 ns | Sixteen correct activation positions per issue, including padded/strided AlexNet geometry |

The dynamic-SA OOC harness reduces every PE result through a registered
parity tree.  The tree is present only to retain all 512 compute paths without
exposing thousands of package pins; its LUT/FF counts are not a prediction of
the complete accelerator top.  DSP count and routed timing are the relevant
compute-fabric results.

The M16 feeder performance regression measured the following scheduling
efficiency.  The first three small-channel cases deliberately expose fixed
scanner/prefetch overhead; the final row is the full Conv1 input geometry.

| Geometry | Issue duty | Useful PE-slot utilization | Status |
| --- | ---: | ---: | --- |
| 16x16, C8, K3, S1 | 88.684% | 88.684% | Divisible spatial case |
| 27x27, C8, K5, S1 | 95.406% | 94.499% | Conv2 geometry |
| 13x13, C8, K3, S1 | 78.728% | 75.596% | Conv3-5 geometry |
| 224x224, C3, K11, S4 | 95.186% | 94.717% | Full Conv1 geometry |

For Conv1 the corresponding logical-array arithmetic-rate estimate is about
0.3819 TOPS (`0.4032 * 0.94717`). The 25.6 GB/s BRAM read fabric meets 200 MHz;
the scanner's 51,984 cycles are now hidden under 68,970 issue cycles. The next
controller target is the shared path's remaining inter-tile descriptor/replay
boundary, not another increase in BRAM read ports.

## Clock-domain bandwidth

All values below use the only experiment clock, 200 MHz.

| Boundary | Width/cycle | Peak bandwidth | Requirement |
| --- | ---: | ---: | --- |
| Existing PS HP0 / main AXI DMA | 128 bit | 3.2 GB/s | External fill/drain ceiling before protocol loss |
| Wide M8 activation at SA pins | 64 bit | 1.6 GB/s | One M8 source group |
| Split 2xM8 activation at SA pins | 128 bit | 3.2 GB/s | Two independent M8 source groups |
| M8 feeder ring-memory reads | 8 x 64 bit | 12.8 GB/s | Eight spatial word reads select eight INT8 activations |
| M16 feeder ring-memory reads | 16 x 64 bit | 25.6 GB/s | Sixteen spatial word reads select sixteen INT8 activations |
| N128 resident-weight replay | 1,024 bit | 25.6 GB/s | Eight N16 banks, 128 bit/bank/cycle |
| M16 patch ping-pong replay | 128 bit | 3.2 GB/s | Sixteen INT8 spatial values for one K |
| 64-lane INT32 postprocess ingress | 2,048 bit | 51.2 GB/s | Sixteen-cycle drain of one 1,024-result tile |
| Postprocessed INT8 burst | 512 bit | 12.8 GB/s | Local N16 FIFOs absorb the burst |

The internal weight port is eight times wider than one external HP0 port.  It
is a replay port, not a direct DDR-to-PE connection.  DDR fills a resident
bank slowly; the bank then replays that weight tile for many spatial M groups.

The representative full shared Conv2 profile now measures 96.337% useful PE
utilization after A5 removes the source and inter-tile control bubbles.
Projecting that measured duty onto logical M8xN126 gives 0.3884 TOPS at
200 MHz. This remains an RTL compute-path estimate, not board throughput.

## Convolution weight-overlap proof

For an N64 tile, one AXI fill takes `K * 64 / 16 = 4K` cycles.  For an N128
tile it takes `8K` cycles.  The compute interval below excludes small clear,
skew and result-drain overhead, so it is conservative for overlap capacity.

| Layer | Runtime mode | Weight tile | AXI fill | Compute reuse interval | Compute/fill |
| --- | --- | ---: | ---: | ---: | ---: |
| Conv1 | `2xM8xN64` | 23,232 B, shared by both clusters | 1,452 cycles | 68,970 cycles | 47.5x |
| Conv2 | `2xM8xN64`, per N64 tile | 102,400 B | 6,400 cycles | 73,600 cycles | 11.5x |
| Conv3 | `M8xN128`, per N128 tile | 221,184 B | 13,824 cycles | 38,016 cycles | 2.75x |
| Conv4 | `M8xN128`, per N128 tile | 442,368 B | 27,648 cycles | 76,032 cycles | 2.75x |
| Conv5 | `M8xN128`, per N128 tile | 294,912 B | 18,432 cycles | 50,688 cycles | 2.75x |

Every convolution has enough compute reuse to fill the next ping-pong weight
bank through one 128-bit HP port before the current bank retires, assuming
long bursts and no competing owner.  Conv1 broadcasts the same N64 weights to
both spatial clusters, so split mode does not duplicate external weight
traffic.

## FC bandwidth limit

An FC N128 weight tile requires 128 bytes for each K token.  HP0 supplies only
16 bytes/cycle, so a fill takes `8K` cycles.  Batch 1 through batch 8 use at
most one physical M8 group and compute the tile in `K` cycles.  They therefore
remain eight-times weight-bandwidth limited when considered at the FC layer
boundary.

| Layer | N128 tile bytes | One-port fill | Batch-1 compute | Ratio |
| --- | ---: | ---: | ---: | ---: |
| FC6 | 1,179,648 B | 73,728 cycles | 9,216 cycles | 8x |
| FC7 | 524,288 B | 32,768 cycles | 4,096 cycles | 8x |
| FC8 full tile | 524,288 B | 32,768 cycles | 4,096 cycles | 8x |

The dynamic bank mask therefore provides a bandwidth-matched FC mode:

| Available DDR read width | Concurrent N16 banks | Internal weight width | Batch needed for full sustained array peak |
| --- | ---: | ---: | ---: |
| One 128-bit HP port | 1 | 128 bit/cycle | 64 |
| Two 128-bit HP ports | 2 | 256 bit/cycle | 32 |
| Four 128-bit HP ports | 4 | 512 bit/cycle | 16 |
| Eight equivalent ports | 8 | 1,024 bit/cycle | 8 |

K26 does not provide eight independent ports for this accelerator.  With the
current one-port shell, only one N16 bank should toggle during steady-state FC
weight streaming unless prefetched data is resident.  Other banks are clock-
enabled only for already-filled bursts.  This preserves the maximum possible
FC throughput of the external port while reducing idle DSP/URAM switching.

The present block design also connects main MM2S, main S2MM and camera MM2S to
one HP0 through a three-input SmartConnect.  Its aggregate ceiling is still
3.2 GB/s and arbitration lowers sustained bandwidth.  A later full-shell
throughput build should separate weight MM2S, activation/result traffic and
camera traffic onto distinct PS HP ports before claiming a multi-port number.

## Result bandwidth

One full dynamic tile produces 1,024 INT32 accumulators, or 4,096 bytes.  A
64-lane postprocessor consumes that holding set in sixteen clocks.  Conv1 is
the shortest reduction at K=363, so the next result set cannot arrive for at
least 363 issue clocks.  Local FIFOs have at least 347 clocks of headroom.

After requantization the tile is 1,024 bytes.  A 128-bit AXI stream drains it
in 64 clocks, still below Conv1's 363-clock production interval.  Result DDR
bandwidth is therefore sufficient if the 64-lane burst is first distributed
into N16-local FIFOs instead of being connected to one global ready path.

## Memory-resource projection

The routed M8 system currently uses 89 RAMB36E2, three RAMB18E2 and 13
URAM288.  Its M8 feeder accounts for 40 RAMB36E2 and its full-raster M8xN8
partial-sum bank accounts for 32 RAMB36E2.

| Change | RAMB36 effect | URAM effect |
| --- | ---: | ---: |
| M8 feeder to stride-safe 16-read M16 feeder | +72 | 0 |
| Remove full-raster partial-sum bank | -32 | 0 |
| Move current N8 weight bank out of BRAM | -2 | 0 |
| N128 weight ping-pong, 15 URAM per 1,024-bit bank set | 0 | +30 |
| Existing Conv1 frame replay | 0 | existing 13 |

The routed resource probe realizes 116 RAMB36E2, three RAMB18E2 and 32 URAM,
or 81.60% of the K26 block-RAM tiles and 50.00% of URAM. The M16 feeder uses
112 RAMB36E2 because the safe ring depth is `kernel + stride` and every one of
the sixteen read copies needs seven width banks. A full N128 raster partial-sum
expansion would still require roughly 512 RAMB36 equivalents and is explicitly
rejected.

## Release gates

- **PASS:** Dynamic SA numerical regression passes wide N128, split N64,
  independent M tails/tags, output backpressure and single-N16 bank gating.
- **PASS:** The compact-pin dynamic SA routes with exactly 512 compute
  DSP48E2 and positive setup/hold slack at 200 MHz.
- **PASS:** The M16 feeder produces sixteen correct activation lanes, uses
  exactly 112 RAMB36E2, and routes at 200 MHz with WNS +0.229 ns.
- **PASS:** Scanner/issue overlap and flat spatial grouping raise full Conv1
  issue duty to 95.186% and useful M-lane utilization to 94.717%.
- **PASS:** The N128 URAM weight ping-pong, 512-DSP SA and 64-DSP requant path
  synthesize together with exactly 576 DSP48E2 and WNS +0.468 ns.
- **PASS:** The KV260 probe top routes at 200 MHz with WNS +0.006 ns, WHS
  +0.011 ns, zero failed-route nets and zero DRC errors/critical warnings.
- **PASS:** Post-reduce overlap removes all 1,469 classified post-reduce cycles
  in the representative shared command, raises useful PE utilization from
  89.439% to 94.060%, and keeps issue-ready stalls at zero.
- **PASS:** A5 eliminates the 92 source-starve cycles, reduces the corrected
  steady-state inter-tile boundary to 379 cycles, and raises useful PE
  utilization to 96.337%. Full shared M8 OOC route passes with WNS +0.040 ns
  and WHS +0.046 ns.
- **PASS:** The new two-set M16 activation-patch ping-pong sustains one
  128-bit K word per replay cycle after startup, overlaps fill and replay under
  randomized backpressure, infers exactly four URAM, and routes at 200 MHz
  with WNS +0.434 ns and WHS +0.055 ns.
- **NEXT:** Build the x-mod-4 activation store/patch assembler, migrate the
  dynamic compute island into the functional graph, then connect HP3 to an
  independent weight MM2S master. Full-shell bandwidth claims still require
  AXI performance counters; theoretical 3.2 GB/s-per-port values are not board
  measurements.
