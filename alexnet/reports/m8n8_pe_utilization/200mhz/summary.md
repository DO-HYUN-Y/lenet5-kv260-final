# M8xN8 PE utilization profile at 200 MHz

Date: 2026-09-10

The profile uses cycle-accurate RTL simulation with an always-valid feeder
source, an always-ready feeder sink, and no artificial CE stalls in the
profiled shared Conv2 chunk. Useful PE utilization counts active logical
M-by-N cells, so spatial tail lanes are correctly treated as idle.

## Feeder-only measurements

| AlexNet shape | Total cycles | Issue cycles | Input scan | BRAM read issue | BRAM read capture | Useful PE utilization |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Conv1, 224x224 C3 K11/s4 | 284,909 | 139,755 | 51,984 | 46,585 | 46,585 | 48.177% |
| Conv2, 27x27 C8 K5/s1 | 27,961 | 21,600 | 961 | 2,700 | 2,700 | 65.180% |
| Conv3/4/5, 13x13 C8 K3/s1 | 2,565 | 1,872 | 225 | 234 | 234 | 59.298% |

Conv1 spends 93,170 cycles, or 32.70% of its feeder lifetime, in the repeated
two-cycle BRAM read sequence. Its issue duty is 49.053%; the difference to
48.177% useful utilization is the final M7 spatial tail in every row.

## Complete shared Conv2 chunk

| Class | Cycles | Share of compute window |
| --- | ---: | ---: |
| Useful issue | 21,600 | 73.522% |
| Feeder/source starvation | 5,292 | 18.013% |
| Post-reduce result scan/accumulation drain | 2,025 | 6.893% |
| Inter-tile transition | 461 | 1.569% |
| Other boundary | 1 | 0.003% |
| CE stall | 0 | 0.000% |
| Issue-ready backpressure | 0 | 0.000% |

The complete compute window is 29,379 cycles. Lane-weighted useful PE
utilization is 62.034%; the M3 tail of each 27-pixel row accounts for the gap
between issue duty and useful utilization. The containing command takes
31,142 cycles, including 1,753 input-DMA-active cycles. No egress backpressure
occurs in the profiled non-final chunk.

## Bottleneck decision

AXI backpressure and the global CE are not the current compute bottlenecks.
The first optimization target is the feeder's repeated BRAM read/capture pair,
especially for C3 Conv1. A Conv1-specific line buffer keeps the required row
history but snapshots the next window into a ping-pong issue buffer, allowing
the SA to consume one K token per cycle without re-entering the two-cycle read
state for every kernel position. Larger SA configurations must expand the
window/weight banks and partial-sum storage together; blindly adding DSPs alone
would amplify the measured starvation.
