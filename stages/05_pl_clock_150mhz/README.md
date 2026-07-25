# Stage 05 — Ubuntu-Safe 150 MHz PL Clock and Reset

This stage preserves the Stage03 LeNet-5 compute, autonomous scheduler, AXI
DMA, address map, and data formats. It changes only the board-level clock and
reset architecture required by the stock KV260 Ubuntu image.

## Clock and reset contract

- Firmware-owned PS `pl_clk0`: 100 MHz input only.
- PL Clocking Wizard primitive: MMCM.
- Fabric output: 150 MHz through the Clocking Wizard output buffer.
- Clock domains: one 150 MHz domain for PS AXI clocks, SmartConnect, AXI DMA,
  accelerator control, streams, and compute.
- Reset: `proc_sys_reset` holds all AXI and accelerator resets active until
  the MMCM `locked` output is asserted, then releases reset synchronously to
  the 150 MHz fabric clock.
- `ext_reset_in` and `aux_reset_in` are explicitly active-low and tied to
  logic 1 (inactive). `mb_debug_sys_rst` is active-high and tied to logic 0.
- The design does not depend on PS `pl_resetn0`.
- Linux enables `pl_clk0` but does not reparent PS PLLs or program PS
  dividers.

## External interface and arbitration

The top remains `system_wrapper` and exposes only the Zynq UltraScale+ PS
integration boundary. No accelerator tensor, weight, partial-sum, or per-lane
signals are promoted to package pins. Arbitration ownership is unchanged:
the accelerator scheduler owns its AXI-Lite DMA-control master; SmartConnect
arbitrates the PS and scheduler control masters; AXI DMA owns HP0 bulk-memory
transactions.

## Fixed addresses

- Accelerator CSR: `0xA000_0000`, ID at offset `0x000` is `0x0002_4c35`.
- AXI DMA CSR: `0xA001_0000`.
- HP0 DDR aperture: `0x0000_0000` to `0x7fff_ffff`.

## Verification status

```text
RTL_SIM:              PASS (directed + seeded random stalls)
BLOCK_DESIGN:         PASS
SYNTHESIS:            PASS
IMPLEMENTATION:       PASS
TIMING:               PASS
DRC/METHODOLOGY/CDC:  PASS
CLOCK_RESET_FUNCSIM:  PASS
CLOCK_RESET_SDF:      PASS
BITSTREAM/XSA:        GENERATED
BOARD_LOAD:           PASS
BOARD_ID:             PASS (0x00024c35)
BOARD_FIRST_IMAGE:    PASS (byte exact)
BOARD_100_JOB:        PASS
BOARD_MNIST_10000:    PASS (100,000 logit bytes; 98.93%)
```

Full-system post-route results at the 150 MHz fabric clock:

```text
WNS  = +0.397 ns
TNS  =  0.000 ns
WHS  = +0.010 ns
THS  =  0.000 ns
WPWS = +1.833 ns
TPWS =  0.000 ns
failed route nets = 0
DRC errors/critical warnings = 0/0
```

Utilization is 22.77% LUT, 15.05% registers, 31.94% BRAM, 0% URAM,
and 3.85% DSP. The worst setup path is route-dominated from parameter BRAM
output to a postprocessor bias register. Since it has positive slack and an
extra pipeline stage would change the verified latency contract, no product
RTL pipeline was added in this clock/reset-only stage.

The dedicated post-route clock/reset harness also passed functional and
slow-corner SDF simulations. It measured a 6,667/6,666 ps generated-clock
period and synchronous reset release 46 fabric cycles after MMCM lock. Its
own routed timing was WNS `+5.598 ns`, WHS `+0.084 ns`.

The Stage03 board hang is now explained by generated RTL evidence:
`proc_sys_reset` had `C_AUX_RESET_HIGH=0`, while `aux_reset_in` was tied to
zero. Reset therefore remained asserted permanently, so the first PS
AXI-Lite read never received a response. Stage05 fixes that exact condition.

Artifacts:

```text
bit SHA-256 = 85862fe7f20fdba19cdfc294dc842ce1da559214116de845e26611a96857e985
xsa SHA-256 = 0b62c0cdcc4293f5b4c769a294b6848e2ef6487866dcd8cf0103e64530aaa24e
```

The real KV260 passed load, driver probe, ID, first-image, 100-job resident
stability, and 10,000-image byte-exact dataset gates. Stage05 is PASS.
