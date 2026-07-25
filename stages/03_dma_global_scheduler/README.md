# Stage 03 — DMA-Aware Global Scheduler

This stage adds the system-level controller that was missing above the
ten-operation LeNet-5 compute controller. A single host descriptor can now
reload the resident model when required, transfer one image from DDR, run the
complete accelerator, transfer ten logits back to DDR, and raise one final
completion interrupt.

## Implemented RTL

| Module | Responsibility |
|---|---|
| `rtl/axi_dma_simple_master.sv` | AXI4-Lite master that starts and polls AMD AXI DMA simple-mode channels |
| `rtl/lenet_system_scheduler.sv` | Descriptor validation, model/input/output DMA ordering, compute launch, timeout/error handling, one pending descriptor |
| `rtl/lenet_axi_lite_regs.sv` | Version-2 autonomous descriptor/status CSR bank |
| `rtl/lenet5_axis_wrapper.sv` | Manual/autonomous arbitration, scheduler/DMA integration, final IRQ policy |

`lenet_global_controller.sv` remains the internal C1→S2→C3→S4→C5→F6→OUT
sequencer. `lenet_system_scheduler.sv` is the outer global controller that owns
DDR transfers and whole-job lifecycle.

## Autonomous sequence

```text
validate descriptor
  -> [MM2S weights -> MM2S parameters]  optional model reload
  -> MM2S input
  -> ten-operation LeNet compute
  -> arm S2MM
  -> stream ten INT8 logits
  -> final IRQ / completed job ID
```

The model remains in on-chip BRAM after the first load. The first job therefore
uses three MM2S transfers plus one S2MM transfer; a model-resident job uses one
MM2S transfer plus one S2MM transfer.

## Transfer contract

| Payload | Bytes | 128-bit beats |
|---|---:|---:|
| Weights | 92,736 | 5,796 |
| Parameters | 1,888 | 118 |
| Input image | 1,024 | 64 |
| Output logits | 10 | 1 with `TKEEP=0x03ff` |

All DDR addresses must be 16-byte aligned because DRE is disabled. The AXIS
width is 128 bits for bandwidth; each activation, weight, and result element is
still signed INT8.

## Software-visible CSR map

Accelerator CSR base: `0xA000_0000`.

| Offset | Name | Direction | Meaning |
|---:|---|---|---|
| `0x00` | ID | R | `0x0002_4c35` |
| `0x04` | CTRL | W | bit 0 core, 1 load, 2 result, 3 clear, 4 autonomous submit |
| `0x08` | STATUS | R | manual state plus autonomous busy/done/error/queue/state |
| `0x30` | AUTO_CFG | R/W | bit 0 reload model |
| `0x34` | WEIGHT_ADDR | R/W | DDR physical address |
| `0x38` | PARAM_ADDR | R/W | DDR physical address |
| `0x3c` | INPUT_ADDR | R/W | DDR physical address |
| `0x40` | RESULT_ADDR | R/W | DDR physical address |
| `0x44` | TIMEOUT | R/W | per-phase timeout cycles |
| `0x48` | JOB_ID | R/W | software tag |
| `0x4c` | AUTO_STATUS | R | busy/done/error/queue/ready/state |
| `0x50` | AUTO_ERROR | R | sticky error code |
| `0x54` | COMPLETED_JOB | R | last completed job ID |
| `0x58` | JOB_CYCLES | R | last/current job cycles |
| `0x5c` | DMA_CYCLES | R | last/current DMA-phase cycles |
| `0x60` | COMPLETED_COUNT | R | completed job count |

Software must not access the AXI DMA CSR bank while autonomous busy is set.
For the non-coherent HP0 path, flush weight/parameter/input buffers before
submit and invalidate the result buffer after completion.

## Verification

| Test | Result |
|---|---|
| AXI DMA master directed | PASS |
| AXI DMA master seeded random, 128 commands | PASS |
| Scheduler happy path, pending queue, errors, reset | PASS |
| Scheduler seeded random, 128 jobs | PASS |
| CSR directed plus seeded random, 64 transactions | PASS |
| Full RTL wrapper, no stalls | PASS, 27,499 cycles |
| Full RTL wrapper, seeded AXI/AXIS stalls | PASS, 33,274 cycles |
| Post-route OOC functional controller smoke | PASS |

Seed: `20260725`. The full wrapper test includes one manual inference, one
model-reload autonomous inference, and one model-resident autonomous inference.
All ten output bytes are compared with the DPI-C golden model.

The post-route gate smoke intentionally checks the bounded CSR→descriptor
validation→error IRQ→clear path. Full-inference numeric equivalence is checked
at RTL with DPI-C, while every routed datapath setup/hold endpoint is checked by
STA.

## KV260 implementation result

| Item | Result |
|---|---:|
| Part | `xck26-sfvc784-2LV-c` |
| Clock | 5.000 ns / 200 MHz |
| Full-system WNS | +0.015 ns |
| Full-system WHS | +0.010 ns |
| Failed route nets | 0 |
| DRC errors / critical warnings | 0 / 0 |
| CLB LUT | 26,905 / 117,120 = 22.97% |
| CLB register | 35,263 / 234,240 = 15.05% |
| BRAM tile | 46 / 144 = 31.94% |
| DSP48E2 | 48 / 1,248 = 3.85% |

OOC wrapper STA independently passed with WNS `+0.206 ns` and WHS
`+0.046 ns`. The complete PS+PL design generated:

```text
stages/03_dma_global_scheduler/build/output/lenet5_kv260.bit
stages/03_dma_global_scheduler/build/output/lenet5_kv260.xsa
```

## Reproduction

All Vivado implementation scripts set `general.maxThreads` to 8.

```bash
/tools/Xilinx/2025.1/Vivado/bin/vivado -mode batch \
  -source stages/03_dma_global_scheduler/scripts/build_kv260_system.tcl

/tools/Xilinx/2025.1/Vivado/bin/vivado -mode batch \
  -source scripts/synth_impl_lenet5_axis_wrapper.tcl

/tools/Xilinx/2025.1/Vivado/bin/vivado -mode batch \
  -source stages/03_dma_global_scheduler/scripts/export_wrapper_netlists.tcl

XILINX_VIVADO=/tools/Xilinx/2025.1/Vivado \
/tools/Xilinx/2025.1/Vivado/bin/vivado -mode batch \
  -source stages/03_dma_global_scheduler/scripts/run_wrapper_netlist_dpic.tcl \
  -tclargs 20260725
```

## Remaining hardware step

The generated bitstream/XSA are complete. The remaining external step is a
powered KV260 JTAG scan followed by PS software/board bring-up. A board result
must not be marked PASS until Vivado detects the K26 and the DDR→accelerator→DDR
job is verified against the software golden model.
