# Stage 03 Architecture — DMA-Aware Global Scheduler

## Scope

This stage adds the missing system-level authority above the existing fixed
ten-operation LeNet-5 sequencer. One host submit command causes the PL to:

1. preload weights and parameters when the resident model is invalid or reload
   is requested;
2. load one input image through AXI DMA MM2S;
3. start the existing ten-operation compute controller;
4. arm AXI DMA S2MM and stream the ten output logits to DDR;
5. report completion, error code, job ID, and cycle counters.

The existing manual load/core/result CSR commands remain available for debug
when the autonomous scheduler is idle.

## Fixed target

| Item | Decision |
|---|---|
| Board / part | KV260 / `xck26-sfvc784-2LV-c` |
| Clock | One 199.998001 MHz PL domain |
| Arithmetic | Signed INT8 operands, INT32 accumulation |
| Compute | Existing logical 8x8 / physical packed 4x8 array |
| DMA | One AMD AXI DMA, simple mode, MM2S and S2MM |
| DDR path | 128-bit non-coherent HP0 |
| Stream | 128 bits, 16 INT8 bytes per beat |
| Alignment | 16-byte physical addresses |
| DRE / SG | Disabled / disabled |
| Scheduler queue | One active descriptor plus one pending descriptor |

## Transfer sizes

| Transfer | Bytes | 128-bit beats | Frequency |
|---|---:|---:|---|
| Weights | 92,736 | 5,796 | Model preload |
| Parameters | 1,888 | 118 | Model preload |
| Input | 1,024 | 64 | Every job |
| Result | 10 valid bytes | 1 | Every job |

At 200 MHz the raw 128-bit stream ceiling is 3.2 GB/s. The input payload takes
64 stream cycles while the current inference takes 10,001 controller cycles.
Input payload time is therefore about 0.64% of compute time before DMA setup
overhead. Model traffic is amortized because weights and parameters remain
on-chip.

## Control ownership

- `lenet_system_scheduler` is the single owner of autonomous job sequencing.
- `axi_dma_simple_master` owns the AXI-Lite master transaction protocol toward
  the DMA register bank.
- The existing `lenet_global_controller` remains the owner of the ten internal
  Conv/Pool/FC operations.
- The AXIS ingress/result adapters remain the owners of stream unpacking,
  packing, and internal memory addresses.
- Software must not write the AXI DMA registers while autonomous status is
  busy. SmartConnect provides electrical arbitration, but software exclusion is
  the functional ownership rule.

## AXI DMA command sequence

For each transfer the PL AXI-Lite master performs:

```text
DMACR  <- RS | IOC_IrqEn | Err_IrqEn
DMASR  <- IOC_Irq | Dly_Irq | Err_Irq       // write-one-to-clear
ADDR   <- aligned DDR physical address
LENGTH <- byte count                         // starts the channel
poll DMASR until IOC_Irq or an error/timeout
```

MM2S offsets are `0x00/0x04/0x18/0x28`; S2MM offsets are
`0x30/0x34/0x48/0x58`. The mapped DMA base is `0xA001_0000`.

The ingress adapter is started on the same edge that accepts an MM2S command,
so it is ready before the DMA reaches the stream phase. For S2MM, the result
adapter starts only after the DMA length write completes and the channel is
armed.

## Scheduler FSM

```text
IDLE
  -> VALIDATE
  -> [WEIGHT_LAUNCH -> WEIGHT_WAIT
      -> PARAM_LAUNCH -> PARAM_WAIT]          // optional resident-model reload
  -> INPUT_LAUNCH -> INPUT_WAIT
  -> CORE_LAUNCH -> CORE_WAIT
  -> OUTPUT_DMA_LAUNCH -> OUTPUT_DMA_ARM
  -> RESULT_LAUNCH -> RESULT_WAIT
  -> COMPLETE
  -> IDLE or VALIDATE for the queued descriptor

Any detected fault -> ERROR -> host clear -> IDLE
```

Every launch is a one-cycle accepted event. Every wait state requires both the
DMA completion and the corresponding stream-adapter completion where
applicable. Timeout and response errors are explicit error transitions.

## Buffering boundary

The active accelerator has two activation sets and alternates them throughout
all ten operations. Neither set is free for the whole compute interval.
Therefore this stage does not claim that input DMA for job N+1 overlaps compute
for job N.

The one-entry pending descriptor queue removes the PS submission gap but not
the input-transfer gap. True input/compute overlap requires one of:

- a third 1,024-byte input activation set;
- a dedicated input staging BRAM plus a wide copy path;
- two complete activation ping-pong pairs.

That expansion will be justified only after board measurements show this
sub-percent payload plus DMA setup is a meaningful bottleneck.

## Error policy

| Code | Meaning | Recovery |
|---:|---|---|
| `0x01` | Invalid or unaligned descriptor | Clear status and resubmit |
| `0x02` | AXI DMA controller error | Clear status; reset/reinitialize DMA |
| `0x03` | Scheduler phase timeout | Clear status after investigating unit |
| `0x04` | AXIS ingress error | Clear status and reload affected payload |
| `0x05` | Result-stream error | Clear status and rerun job |
| `0x06` | Submit rejected / queue full | Wait for queue space and resubmit |

On error, the active job stops, the pending descriptor is discarded, busy
deasserts, and the error remains sticky until explicit clear.

## Performance counters

- current/last autonomous job cycles;
- cycles spent in DMA-related states;
- completed job count;
- completed job ID;
- existing busy/compute/pool/parameter cycle counters.

## Resource budget

The new scheduler and AXI-Lite master contain only FSMs, counters, and
descriptor registers. Expected incremental cost is less than 2,000 LUTs and
2,000 registers, with no DSP, BRAM, or URAM. The Stage 02 baseline is:

```text
LUT  25,611 / 117,120
FF   34,206 / 234,240
BRAM 46 / 144
DSP  48 / 1,248
```

All conservative K26 limits remain satisfied with large headroom.

## Verification contract

- Directed controller tests precede random tests.
- Seed and random count are passed with Tcl arguments.
- The scoreboard compares accepted DMA register transactions and scheduler
  events by cycle and job ID.
- Reset, AXI backpressure, queue full, invalid alignment, DMA status error,
  timeout, and post-error recovery are mandatory.
- RTL, synthesized-netlist, full wrapper, and routed physical-top results are
  reported separately.
- Board test remains blocked until Vivado detects the powered KV260 JTAG
  device; no simulation or STA result is labeled as a board pass.
