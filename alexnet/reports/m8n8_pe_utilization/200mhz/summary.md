# M8xN8 PE utilization profile at 200 MHz

Date: 2026-09-14

The profile uses cycle-accurate RTL simulation with an always-valid feeder
source, an always-ready feeder sink, and no artificial CE stalls in the
profiled shared Conv2 chunk. Useful PE utilization counts active logical
M-by-N cells, so spatial tail lanes are correctly treated as idle.

## Feeder-only measurements

| AlexNet shape | Total cycles | Issue cycles | Input scan | BRAM read issue | BRAM read capture | Useful PE utilization |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Conv1, 224x224 C3 K11/s4 | 142,167 | 137,577 | 51,984 | 379 | 379 | 96.548% |
| Conv2, 27x27 C8 K5/s1 | 19,085 | 18,400 | 961 | 92 | 92 | 95.494% |
| Conv3/4/5, 13x13 C8 K3/s1 | 1,754 | 1,584 | 225 | 22 | 22 | 86.716% |

The scanner now fills the ring while the current window is being issued. Flat
M groups continue across raster-row boundaries, so padding is paid only once at
the complete tensor tail instead of once per output row. Registered endpoint
planning and per-lane ring addresses keep the BRAM path routable at 200 MHz.
Conv1 issue duty is 96.771%; the difference to 96.548% useful utilization is
the final tensor tail. The physical ring is `kernel + stride` rows rather than
`kernel + 1`, because a stride-four group can consume endpoints from two
successive output rows before the scanner may overwrite the oldest row.

## Complete shared Conv2 chunk

The accumulator now releases the compute side as soon as `issue_last` is
accepted. A pending descriptor and two-entry outstanding-result counter let the
next tile issue while the previous result wavefront reaches the snapshot. The
snapshot still owns a distinct descriptor/data holding set, so random output
backpressure cannot overwrite the previous tile.

| Class | Before A4 | After A4 | After share of compute window |
| --- | ---: | ---: | ---: |
| Useful issue | 18,400 | 18,400 | 94.963% |
| Feeder/source starvation | 92 | 92 | 0.475% |
| Post-reduce result scan/accumulation drain | 1,469 | 0 | 0.000% |
| Inter-tile transition | 415 | 883 | 4.557% |
| Other boundary | 1 | 1 | 0.005% |
| CE stall | 0 | 0 | 0.000% |
| Issue-ready backpressure | 0 | 0 | 0.000% |

The complete compute window falls from 20,377 to 19,376 cycles and
lane-weighted useful PE utilization rises from 89.439% to 94.060%. The
containing command falls from 22,172 to 21,171 cycles, including the same 1,785
input-DMA-active cycles. This is a 4.51% latency reduction and a 4.73%
throughput increase for this profiled command. The larger inter-tile class is
the remaining control/replay boundary exposed after the post-reduce class is
removed; total non-issue cycles still fall by 1,001.

## Bottleneck decision

AXI backpressure and the global CE are not the current simulated compute
bottlenecks. A4 removes the measured post-reduce bubble without creating issue
backpressure. The largest remaining class is now the 883-cycle inter-tile
control/replay boundary (4.557%), followed by 92 source-starvation cycles
(0.475%). The next on-chip optimization is descriptor/weight-replay prefetch at
that boundary. A dedicated HP3 weight MM2S path follows during functional graph
integration; board AXI counters are still required because this simulation
proves the on-chip supply path, not external DDR bandwidth.
