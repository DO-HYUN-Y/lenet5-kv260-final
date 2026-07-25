# Stage 01 — AXI DMA Bridge

## Result

The custom-IP side of the AXI/DMA bridge is implemented. The accelerator now
exposes only:

- one 32-bit AXI4-Lite control/status slave;
- one 128-bit AXI4-Stream MM2S input;
- one 128-bit AXI4-Stream S2MM output;
- one level-sensitive interrupt.

The Xilinx AXI DMA IP, Zynq PS, SmartConnect, clock/reset block, and physical
top remain the next Vivado block-design stage.

Canonical sources are in the project-level `rtl/`, `tb/`, `golden/`,
`scripts/`, and `constraints/` directories.

## Data format

All weights, activations, and logits are signed INT8 elements. Widths of 16,
64, 128, and 512 bits are only transport or memory packing widths.

| Mode | Address-generator unit | 128-bit AXIS packing |
|---|---|---|
| Weight | one 512-bit row, eight banks × 64-bit | four beats |
| Parameter | one 64-bit `{reserved[13:0], scale[17:0], bias[31:0]}` | two records per beat |
| Input | one 16-bit `{act_hi, act_lo}` word | eight words per beat |
| Result | one 16-bit `{logit_hi, logit_lo}` word | five words in one beat |

Little-endian byte order is used within each beat. `tdata[7:0]` is the first
byte in memory order.

Fixed complete-image transfer sizes are:

```text
weight:    1449 rows = 5796 AXIS beats = 92736 bytes
parameter: 236 records = 118 AXIS beats = 1888 bytes
input:     512 words = 64 AXIS beats = 1024 bytes
result:    5 words = 10 valid bytes in one AXIS beat
```

The input image is loaded into activation set 0, bank 0, words 0–511. Final
logits are read from activation set 1 and gathered from banks 0–4, word 0.

## AXI4-Lite register map

| Offset | Name | Access | Description |
|---:|---|---|---|
| `0x00` | ID | RO | `{8'h00, VERSION=1, MODULE_ID=16'h4c35}` |
| `0x04` | CONTROL | WO | bit 0 core start, bit 1 load start, bit 2 result start, bit 3 clear status |
| `0x08` | STATUS | RO | busy/done/error/model/input/result/host-ready/op-index |
| `0x0c` | LOAD_CFG | RW | `[31:16] count`, `[5:3] bank`, bit 2 set, `[1:0] mode` |
| `0x10` | LOAD_BASE | RW | internal unit base address |
| `0x14` | RESULT_CFG | RW | `[31:16] word count`, `[2:0] bank base` |
| `0x18` | RESULT_BASE | RW | result word base |
| `0x20` | BUSY_CYCLES | RO | core busy-cycle counter |
| `0x24` | COMPUTE_CYCLES | RO | Conv/FC active cycles |
| `0x28` | POOL_CYCLES | RO | pooling active cycles |
| `0x2c` | PARAM_CYCLES | RO | parameter-load active cycles |

AXI4-Lite AW and W are buffered independently and may arrive in either order.
Read and write responses remain stable under backpressure. Unknown or
read-only writes return `SLVERR`.

## Control rules

- More than one start command in the same control write is rejected.
- Core start is accepted only when full weights, parameters, and input are
  valid.
- Result start is accepted only after a completed inference.
- Ingress and result access to activation BRAM are mutually exclusive.
- Invalid commands and transfer/protocol errors set sticky error status.
- `irq` is a level signal and remains high after completion or error until
  software writes `clear status`.
- Raw reset is asynchronously asserted and synchronously deasserted through a
  two-flop synchronizer before reaching functional logic.

## Address-generator timing contract

```text
start accepted while idle:
  valid/busy rises on the following cycle with unit_index=0.

valid && advance:
  current unit is accepted at that edge.
  next unit appears after the edge, or done pulses if current unit was last.

valid && !advance:
  mode, unit_index, last, and every address remain stable.

cfg_count=0:
  clamped to one unit and error is asserted.

reset:
  busy, valid, done, and error clear.
```

## Implemented files

```text
rtl/lenet_dma_addr_gen.sv
rtl/axis_lenet_ingress.sv
rtl/axis_lenet_result.sv
rtl/lenet_axi_lite_regs.sv
rtl/lenet5_axis_wrapper.sv

golden/lenet_dma_addr_gen_golden.c
golden/axis_lenet_ingress_golden.c
golden/axis_lenet_result_golden.c
golden/lenet_axi_lite_regs_golden.c
golden/lenet5_axis_wrapper_golden.c
```

## Verification and implementation status

| Check | Result |
|---|---|
| Address generator directed | PASS |
| Address generator seeded random | PASS, 256 transfers, seed 20260725 |
| Ingress directed protocol/reset/backpressure | PASS |
| Ingress seeded random | PASS, 128 transfers, seed 20260725 |
| Result directed protocol/reset/backpressure | PASS |
| Result seeded random | PASS, 128 transfers, seed 20260725 |
| AXI4-Lite directed | PASS |
| AXI4-Lite seeded random | PASS, 256 transactions, seed 20260725 |
| Full wrapper, no injected stalls | PASS, 16856 cycles |
| Full wrapper, seeded AXI/AXIS stalls | PASS, 22699 cycles, seed 20260725 |
| Byte-exact output | PASS, logits `-5` through `+4` |
| Core counters | PASS, busy 10001 / compute 9184 / pool 250 / param 520 |

K26 out-of-context post-route result at 200 MHz:

```text
PART:             xck26-sfvc784-2LV-c
CLOCK:            5.000 ns
WNS:              +0.078 ns
WHS:              +0.046 ns
UNCONSTRAINED:     0 register/latch pins
CDC:               0 unwaived crossings
RESET CDC WAIVER:  1 reviewed async-assert path into reset synchronizer
ROUTE:             0 failed/unrouted/partially-routed nets
CLB LUT:           19729 / 117120 = 16.85%
CLB registers:     26056 / 234240 = 11.12%
BRAM tiles:        41 / 144 = 28.47%
DSP48E2:           48 / 1248 = 3.85%
```

DRC has zero errors and zero critical warnings. Remaining warnings are the 16
postprocess-DSP MREG power/performance recommendations and one expected
out-of-context no-routable-load warning for top-level ports.

```text
RTL_SIM:      PASS (directed and seeded-random)
NETLIST_SIM:  SKIPPED
OOC_IMPL:     PASS
DRC_ERRORS:   0
CHECK_TIMING: PASS
CDC:          PASS with one reviewed reset waiver
BITSTREAM:    SKIPPED (system block design not implemented)
XSA:          SKIPPED (system block design not implemented)
BOARD_TEST:   SKIPPED (system block design not implemented)
```

## Next stage

1. Package `lenet5_axis_wrapper` as reusable Vivado IP.
2. Build a Zynq UltraScale+ PS + AXI DMA + SmartConnect + reset block design.
3. Connect AXI-Lite, 128-bit MM2S/S2MM streams, and IRQ.
4. Assign PS–PL clock/reset and DDR HP port, then validate addresses.
5. Run full physical-top implementation and timing/CDC/DRC.
6. Generate bitstream and XSA.
7. Add PS software for cache maintenance, DMA sequencing, CSR control, IRQ,
   and byte-exact result comparison.
