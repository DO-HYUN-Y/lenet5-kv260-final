# AlexNet accelerator AXI-Lite register map

`alexnet_m4n8_accelerator_top` exposes one 32-bit AXI4-Lite slave at
`S_AXI_CTRL`. All offsets are byte offsets from the accelerator control base.
The interface and accelerator run in the same 200 MHz clock domain.

In the routed KV260 board top, the PS physical control map is:

| Base | Owner |
| ---: | --- |
| `0xA0000000` | this accelerator register bank |
| `0xA0010000` | main model/activation AXI DMA |
| `0xA0020000` | PS-owned camera MM2S AXI DMA |

The camera DMA reads exactly 401,408 bytes for one preprocessed `224x224`
frame. Each eight-byte DDR word contains signed INT8 model channels in bytes
0..2 and zero padding in bytes 3..7. See
`stages/01_kv260_m4n8/README.md` for its stream and interrupt ABI.

## Register map

| Offset | Name | Access | Description |
| ---: | --- | --- | --- |
| `0x00` | `ID` | RO | `0x414C0100`: AlexNet module `AL`, RTL ABI version 1 |
| `0x04` | `CONTROL` | WO/W1P | bit 0 submit, bit 1 clear all sticky status, bit 2 cancel pending job |
| `0x08` | `STATUS` | RO | live and sticky state described below |
| `0x0C` | `JOB_TAG` | RW | next-job tag in bits 15:0 |
| `0x10`/`0x14` | `INPUT_LO/HI` | RW | next-job input/camera buffer base |
| `0x18`/`0x1C` | `ACT_A_LO/HI` | RW | activation ping-pong A base |
| `0x20`/`0x24` | `ACT_B_LO/HI` | RW | activation ping-pong B base |
| `0x28`/`0x2C` | `WEIGHTS_LO/HI` | RW | packed-weight blob base |
| `0x30`/`0x34` | `PARAMETERS_LO/HI` | RW | 16-byte quantization-record blob base |
| `0x38`/`0x3C` | `OUTPUT_LO/HI` | RW | final FC8 output base |
| `0x40` | `DMA_TIMEOUT` | RW | timeout cycles per physical DMA transfer; zero selects the DMA default |
| `0x44` | `PROGRESS` | RO | graph phase, layer, completion counts, and DMA source |
| `0x48` | `ERROR` | RO | graph and DMA error detail |
| `0x4C` | `ACTIVE_TAG` | RO | completed tag in 31:16, live graph tag in 15:0 |
| `0x50` | `DMA_ACCEPTED` | RO | accepted logical DMA request count |
| `0x54` | `DMA_ISSUED` | RO | commands issued to AXI DMA |
| `0x58` | `DMA_COMPLETED` | RO | completed physical DMA transfers |
| `0x5C` | `CONV_TILES` | RO | completed post-pool Conv storage tiles |
| `0x60` | `IRQ_ENABLE` | RW | bit 0 completion IRQ, bit 1 failure/fault/rejected-submit IRQ |
| `0x64` | `IRQ_STATUS` | RO/W1C | bits 0..3: done, failed, fault, rejected submit |
| `0x68` | `LAST_JOB_CYCLES` | RO | cycles recorded for the last completed or failed job |
| `0x6C` | `COMPLETED_JOBS` | RO | successful inference count since reset |
| `0x70` | `REJECTED_SUBMITS` | RO | rejected submit count since reset |
| `0x74` | `FAILED_JOBS` | RO | failed inference count since reset |
| `0x78` | `CONFIG_STATUS` | RO | bit 0 valid, bit 1 aligned, bit 2 within 32-bit DMA range, bit 8 pending |
| `0x7C` | `BUILD_CONFIG` | RO | logical M=4, N=8, clock target=200 MHz |

Unmapped reads and writes return AXI `SLVERR`. Byte writes are honored through
`WSTRB`.

## Status fields

`STATUS` uses the following bits:

- bit 0 accelerator busy;
- bit 1 one job is pending;
- bit 2 graph currently accepts a job;
- bits 3, 4, 5: sticky done, failed, and fault;
- bit 6 live graph fault;
- bits 7 and 8: DMA busy and DMA error;
- bit 9 valid Pool5 cache;
- bit 10 interrupt output level;
- bit 11 rejected-submit sticky flag;
- bit 12 shadow configuration valid.

`PROGRESS` contains graph phase in 4:0, active layer in 11:8, completed Conv
layers in 18:16, completed FC layers in 21:20, and active DMA source in 26:24.
`ERROR` contains graph fault code in 3:0 and DMA error code in 7:4.

## Submission and address rules

Software writes the shadow configuration first, then writes `CONTROL.submit`.
The hardware snapshots the entire configuration into a one-entry pending job.
Later software writes cannot alter either that pending snapshot or the active
job. A second submit while the pending slot is occupied returns `SLVERR` and
sets `rejected submit`.

All six bases must be 128-byte aligned and below 4 GiB. The RTL address planner
is internally 64-bit, but the current simple-mode AXI DMA command engine writes
32-bit buffer-address registers. Payload descriptors are 8-byte aligned, so
both AXI DMA channels must be generated with DRE enabled.

Sticky status is cleared through `IRQ_STATUS` W1C or `CONTROL.clear`. A live
accelerator fault immediately reasserts the fault bit; the current graph fault
state requires accelerator reset before another inference.
