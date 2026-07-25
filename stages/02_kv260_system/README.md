# Stage 02 — KV260 PS / AXI DMA System

## Result

The complete KV260 physical system has been generated and implemented for the
Kria K26 device. Vivado block-design validation, synthesis, placement, routing,
setup/hold timing, DRC, methodology, CDC, bitstream generation, and XSA export
all pass.

```text
BOARD:                  xilinx.com:kv260_som:part0:1.4
PART:                   xck26-sfvc784-2LV-c
TOP:                    system_wrapper
PL CLOCK:               199.998001 MHz
SYNTHESIS:              PASS
IMPLEMENTATION:         PASS
SETUP WNS:              +0.052 ns
HOLD WHS:               +0.010 ns
FAILED ROUTE NETS:      0
DRC ERROR:              0
DRC CRITICAL WARNING:   0
METHODOLOGY VIOLATIONS: 0
CDC:                    PASS, all paths safely timed
BITSTREAM:              GENERATED
XSA:                    GENERATED, bitstream included
BOARD TEST:             BLOCKED, USB bridge detected but no JTAG device
```

## System architecture

```text
                        AXI4-Lite, 32 bit
Zynq MPSoC M_AXI_HPM0_FPD ── SmartConnect ──┬── LeNet-5 CSR
                                            └── AXI DMA CSR

DDR ── PS S_AXI_HP0_FPD ── SmartConnect ── AXI DMA MM2S
                                              │ 128-bit AXIS
                                              ▼
                                      LeNet-5 accelerator
                                              │ 128-bit AXIS
                                              ▼
DDR ◀─ PS S_AXI_HP0_FPD ── SmartConnect ── AXI DMA S2MM

LeNet-5 done/error ─┐
DMA MM2S IRQ ───────┼── pl_ps_irq0[2:0]
DMA S2MM IRQ ───────┘
```

All control, DMA, stream, and compute logic is in one PL clock domain. The
actual PS-generated frequency is 199.998001 MHz. The timing constraint is
5.000 ns.

## Fixed interface decisions

| Item | Configuration |
|---|---|
| DMA mode | Direct register / simple mode |
| Scatter-gather | Disabled |
| MM2S / S2MM | Both enabled |
| DDR port | PS `S_AXI_HP0_FPD`, non-coherent |
| Memory data width | 128 bits |
| Stream data width | 128 bits |
| Burst length | 64 beats |
| DRE | Disabled |
| Buffer alignment | 16-byte aligned |
| Address width | 32 bits |
| PL clock domains | One |
| IRQ bit 0 | Accelerator completion/error |
| IRQ bit 1 | DMA MM2S |
| IRQ bit 2 | DMA S2MM |

The accelerator values remain signed INT8. A 128-bit stream beat transports 16
INT8 values; it does not change arithmetic precision.

Because HP0 is non-coherent, software must flush every input buffer before
MM2S and invalidate every output buffer after S2MM. DRE is intentionally
disabled to save logic because the planned buffers are 16-byte aligned.

## Address map

| PS address | Range | Target |
|---:|---:|---|
| `0xA000_0000` | 64 KiB | LeNet-5 AXI4-Lite CSR |
| `0xA001_0000` | 64 KiB | AXI DMA AXI4-Lite CSR |
| `0x0000_0000` | 2 GiB | HP0 DDR window for MM2S |
| `0x0000_0000` | 2 GiB | HP0 DDR window for S2MM |

## Resource use

| Resource | Used | Available | Utilization |
|---|---:|---:|---:|
| CLB LUT | 25,611 | 117,120 | 21.87% |
| CLB register | 34,206 | 234,240 | 14.60% |
| BRAM tile | 46 | 144 | 31.94% |
| DSP48E2 | 48 | 1,248 | 3.85% |
| URAM | 0 | 64 | 0.00% |

The increase from the custom-IP OOC result is the AXI DMA, two SmartConnect
instances, reset infrastructure, and PS interface logic.

## Sign-off interpretation

- Timing has no failing setup, hold, or pulse-width endpoint.
- The unconstrained path table is empty.
- `check_timing` reports no register/latch clocking problem.
- Every routable net is fully routed.
- DRC has zero errors and zero critical warnings.
- Methodology reports zero violations.
- CDC reports `All paths are Safely Timed`; the complete design uses one PL
  clock domain.
- The power estimate is 3.230 W total, 2.926 W dynamic, and 0.304 W static,
  with medium confidence because no post-simulation activity file was used.
  This is an estimate, not a measured board-power result.

Remaining DRC warnings are non-sign-off advisories:

- 6 DSP input-pipeline, 1 DSP PREG, and 16 DSP MREG recommendations. The
  routed design already meets 200 MHz, so changing these now would alter
  cycle latency for no current timing need.
- 6 `NO_CHANGE` BRAM collision advisories occur only in AMD AXI DMA internal
  FIFOs, not in the custom activation or weight memories.
- One `RTSTAT-10` group is unused SmartConnect reset-pipeline plumbing. It has
  no related violation and all routable nets are fully routed.

## Rebuild

Run one Vivado process at a time:

```bash
cd /home/yun/lenet5
/tools/Xilinx/2025.1/Vivado/bin/vivado -mode batch \
  -source stages/02_kv260_system/scripts/package_lenet5_axis_ip.tcl
/tools/Xilinx/2025.1/Vivado/bin/vivado -mode batch \
  -source stages/02_kv260_system/scripts/create_kv260_system.tcl
/tools/Xilinx/2025.1/Vivado/bin/vivado -mode batch \
  -source stages/02_kv260_system/scripts/build_kv260_system.tcl
```

The scripts set `general.maxThreads` to 8 and launch synthesis and
implementation with `-jobs 8`.

Generated outputs:

```text
build/output/lenet5_kv260.bit
build/output/lenet5_kv260.xsa
build/reports/build_summary.txt
build/reports/timing_summary.rpt
build/reports/check_timing.rpt
build/reports/utilization.rpt
build/reports/route_status.rpt
build/reports/drc.rpt
build/reports/methodology.rpt
build/reports/cdc.rpt
build/reports/power.rpt
```

Artifact checksums from the successful run:

```text
e1afbc26e31f6d9d9d23412b6f1529359f150b88344e2d6f77c077079ffc5b0a  lenet5_kv260.bit
ea5508fa60678a1615fd1db47f1ce423d269dc41d08c89533383b920872bfc39  lenet5_kv260.xsa
```

## Board state

The host detects all four ports of the Xilinx ML Carrier Card FT4232H:

```text
usb-Xilinx_ML_Carrier_Card_XFL1IMHF0A5A-if00-port0
usb-Xilinx_ML_Carrier_Card_XFL1IMHF0A5A-if01-port0
usb-Xilinx_ML_Carrier_Card_XFL1IMHF0A5A-if02-port0
usb-Xilinx_ML_Carrier_Card_XFL1IMHF0A5A-if03-port0
```

Vivado `hw_server` can open the cable target, but currently reports `No devices
detected`. Power the KV260 and confirm its boot-mode/JTAG state, then run:

```bash
/tools/Xilinx/2025.1/Vivado/bin/vivado -mode batch \
  -source stages/02_kv260_system/scripts/scan_kv260_hw.tcl
```

The scan script is read-only and does not program the FPGA.

## Decision required before Stage 03

The hardware platform is complete. The board software path now changes the
files and boot flow materially, so one choice is required:

1. **Standalone bare-metal first** — recommended for the first deterministic
   smoke test. Use the XSA, AXI DMA simple-mode driver, explicit cache
   flush/invalidate, CSR polling/IRQ, and byte-exact logits comparison.
2. **Linux deployment first** — create the device tree and kernel/UIO/DMA
   integration for a Linux application. This is closer to final deployment but
   is a larger initial bring-up step.

The existing bitstream/XSA is a complete static PS+PL platform. Using the stock
Kria Ubuntu DFX/XRT overlay flow would be a separate platform-integration
decision and would require adapting this block design to the Kria base
platform.
