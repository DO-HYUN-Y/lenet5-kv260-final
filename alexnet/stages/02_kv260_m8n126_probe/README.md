# KV260 logical M8xN126 resource probe

This stage places and routes the physical M8xN128 systolic array on the K26.
The 512 packed-MAC DSP48E2s compute 128 physical columns; the last two result
lanes are masked, so the software-visible shape is M8xN126.  A separate
64-DSP requantizer makes the complete probe contract 576 DSP48E2s.

The image is a self-testable compute island, not yet a complete AlexNet graph.
It integrates the M16 feeder, N128 URAM weight ping-pong, dynamic SA and result
requant/drain path to measure timing, resource headroom and stalls before the
full graph scheduler is migrated.

## HP routing

All four 128-bit PS HP interfaces are enabled and clocked at 200 MHz.  Current
independent traffic paths are mapped as follows:

- HP0: main DMA MM2S
- HP1: main DMA S2MM
- HP2: camera DMA MM2S
- HP3: reserved for the dedicated weight MM2S master in full-graph integration

The fourth port does not add bandwidth until that independent weight master is
connected.  The first three paths already avoid the old three-to-one HP0
SmartConnect arbitration point.

## Probe registers

The accelerator AXI-Lite base remains `0xA0000000`.  Submit a self-test with
bit 0 at offset `0x04`; the job tag at `0x0c` seeds the deterministic workload.

| Offset | Value |
| --- | --- |
| `0x7c` | `{M=8, N=126, clock_MHz=200}` |
| `0x80` | Active cycles |
| `0x84` | SA issue cycles |
| `0x88` | Weight-stall cycles |
| `0x8c` | Activation-stall cycles |
| `0x90` | Result-drain-stall cycles |
| `0x94/0x98` | Useful MAC count, low/high |
| `0x9c/0xa0` | Physical peak MAC slots, low/high |
| `0xa4` | Result signature |
| `0xa8` | Completed spatial tile pairs |

## Build

Run Vivado in batch mode with:

```sh
vivado -mode batch -source scripts/build_kv260_m8n126_probe.tcl
```

The script publishes `.bit` and `.xsa` files only after route, setup/hold,
DRC, and the 512-SA/576-total DSP resource contracts pass.

If a fully routed run misses setup only because of routing congestion, preserve
the generated checkpoint and run:

```sh
vivado -mode batch -source scripts/recover_kv260_m8n126_timing.tcl
```

The clean build uses Vivado's `Performance_ExplorePostRoutePhysOpt`
implementation strategy. The recovery flow is a fallback for preserving and
examining a routed checkpoint; it applies post-route physical optimization and
rerouting, then repeats every timing, route, DRC and resource gate before
publishing files.

## Verified build (2026-09-15)

Vivado 2025.2 completed synthesis, placement, routing and bitstream generation
at 200 MHz:

| Check | Result |
| --- | ---: |
| WNS / WHS | +0.006 ns / +0.011 ns |
| Failed route nets | 0 |
| DRC errors / critical warnings | 0 / 0 |
| LUT / FF | 70,951 (60.58%) / 74,521 (31.81%) |
| BRAM tile / URAM | 117.5 (81.60%) / 32 (50.00%) |
| SA DSP / total DSP | 512 / 576 (46.15% of device) |

Published files:

- `build/output/alexnet_m8n126_kv260.bit`
- `build/output/alexnet_m8n126_kv260.xsa`
- `build/reports/build_summary.txt`
- `build/reports/timing_summary.rpt`
- `build/reports/utilization.rpt`

SHA-256:

- `.bit`: `b7f893e78659c8eb858c49b0485de44e94b1a6c81a8f164bd2ffcce74821866a`
- `.xsa`: `bd7346e7cfe28e2e810fcdce0b75472347d79dc7d47152938505639d07baf9f5`

The vectorless power estimate is 3.562 W for the complete device, including
2.435 W attributed to the PS. It is not the board TOPS/W result; final TOPS/W
must use measured VCC_SOM power and elapsed hardware-counter cycles.
