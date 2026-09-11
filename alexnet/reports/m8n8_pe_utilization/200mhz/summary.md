# M8xN8 PE utilization profile at 200 MHz

Date: 2026-09-11

The profile uses cycle-accurate RTL simulation with an always-valid feeder
source, an always-ready feeder sink, and no artificial CE stalls in the
profiled shared Conv2 chunk. Useful PE utilization counts active logical
M-by-N cells, so spatial tail lanes are correctly treated as idle.

## Feeder-only measurements

| AlexNet shape | Total cycles | Issue cycles | Input scan | BRAM read issue | BRAM read capture | Useful PE utilization |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Conv1, 224x224 C3 K11/s4 | 192,509 | 139,755 | 51,984 | 385 | 385 | 71.300% |
| Conv2, 27x27 C8 K5/s1 | 22,777 | 21,600 | 961 | 108 | 108 | 80.015% |
| Conv3/4/5, 13x13 C8 K3/s1 | 2,149 | 1,872 | 225 | 26 | 26 | 70.777% |

The parallel-read feeder now prefetches the next kernel position into a second
window register while the current word emits its three or eight channel beats.
Only the initial issue/capture pair remains for each spatial group. Conv1's
repeated BRAM-read cost therefore fell from 93,170 to 770 cycles and its issue
duty rose from 49.053% to 72.597%. The difference to 71.300% useful utilization
is the final M7 spatial tail in every output row.

## Complete shared Conv2 chunk

| Class | Cycles | Share of compute window |
| --- | ---: | ---: |
| Useful issue | 21,600 | 90.585% |
| Feeder/source starvation | 108 | 0.453% |
| Post-reduce result scan/accumulation drain | 1,674 | 7.020% |
| Inter-tile transition | 462 | 1.938% |
| Other boundary | 1 | 0.004% |
| CE stall | 0 | 0.000% |
| Issue-ready backpressure | 0 | 0.000% |

The complete compute window is 23,845 cycles. Lane-weighted useful PE
utilization is 76.431%; the M3 tail of each 27-pixel row accounts for most of
the gap between issue duty and useful utilization. The containing command
takes 25,616 cycles, including 1,759 input-DMA-active cycles. No egress
backpressure occurs in the profiled non-final chunk.

## Bottleneck decision

AXI backpressure and the global CE are not the current compute bottlenecks. The
window ping-pong prefetch has removed 97.96% of the measured Conv2 source
starvation and 99.17% of Conv1's explicit read-state cycles. The result
snapshot now releases every PE together and overlaps serialization with the
next tile; this cuts the measured post-reduce class from 2,025 to 1,674 cycles
and raises useful PE utilization from 75.325% to 76.431%. The remaining
post-reduce/partial-sum work is the largest class, followed by the 462-cycle
inter-tile transition. Larger SA configurations must expand the window/weight
banks and partial-sum storage together so that added DSP lanes do not recreate
a memory-supply bottleneck.
