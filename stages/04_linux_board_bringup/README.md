# Stage 04 — KV260 Linux Board Bring-up

This stage contains the Linux-only support required to run the Stage05
accelerator on the real KV260. It does not change the compute RTL.

## Why a small kernel driver is required

The accelerator descriptor stores 32-bit physical DDR addresses and the AXI
DMA is attached to the non-coherent HP0 port. The stock Ubuntu image provides
the generic `/dev/udmabuf` DMA-BUF exporter, but it does not expose the DMA bus
address needed by the descriptor. XRT is installed but reports zero devices,
and PYNQ is not installed.

`driver/lenet5_board.c` therefore:

- maps the accelerator and AXI DMA CSR resources;
- enables the firmware-owned 100 MHz PL0 reference without changing its
  parent or divider;
- validates the Stage05 DT metadata for the 149,998,501 Hz MMCM fabric clock;
- allocates one 128 KiB, 32-bit-addressable coherent DMA buffer; because HP0
  is non-coherent, Linux maps it with the required non-cacheable policy;
- exposes safe register read/write ioctls;
- exposes the coherent buffer through `mmap`.

The first userspace test uses polling. IRQ support is deferred until the ID,
DMA, and deterministic logits pass.

## Fixed memory layout

| Region | Offset | Bytes |
|---|---:|---:|
| weights | `0x00000` | 92,736 |
| parameters | `0x16a40` | 1,888 |
| input image | `0x171a0` | 1,024 |
| result | `0x175a0` | 16 allocated, 10 valid |

Every region is 16-byte aligned. The total used space is 95,664 bytes.

## Deterministic first-image result

```text
label  = 7
logits = [-30, -9, -8, -6, -9, -25, -57, 38, -33, 5]
hex    = e2 f7 f8 fa f7 e7 c7 26 df 05
argmax = 7
```

## Build without changing the board

On the host:

```bash
stages/04_linux_board_bringup/scripts/package_firmware.sh
stages/04_linux_board_bringup/scripts/deploy_sources.sh
```

`deploy_sources.sh` compiles the external kernel module and userspace test on
the KV260, verifies module `vermagic`, and applies the DTBO to a copy of the
active device tree. It does not use sudo, unload the active FPGA app, or
program PL.

## Board-changing step

After reviewing the generated files and obtaining sudo, run each destructive
or potentially blocking step separately:

```bash
cd /home/ubuntu/lenet5_stage04
sudo ./scripts/install_and_id_test.sh --load-only
sudo ./scripts/install_and_id_test.sh --probe-only
sudo ./scripts/install_and_id_test.sh --read-one
sudo ./scripts/install_and_id_test.sh --id-only
sudo ./scripts/install_and_id_test.sh --first-image-only
sudo ./scripts/install_and_id_test.sh --stress-resident
sudo ./scripts/install_and_id_test.sh --mnist-10000
```

Confirm SSH remains responsive after each command before running the next.
The no-argument default is `--load-only`. `--full` performs the original
combined load, probe, ID, and deterministic first-image sequence only after
all three isolated gates pass.

## Pass gates

```text
SSH_KEY_AUTH:          PASS
LINUX_ENVIRONMENT:     PASS
BIT_BIN_BUILD:         PASS
DTBO_BUILD:            PASS
DTBO_STATIC_APPLY:     PASS
BOARD_MODULE_BUILD:    PASS
LINUX_FIRMWARE_LOAD:   PASS (FPGA manager accepted bit.bin)
PL_CLOCK_INPUT_100MHZ: PASS (firmware-owned reference; no divider writes)
PL_CLOCK_150MHZ:       PASS (149,998,501 Hz metadata + board operation)
PL_CLOCK_EXACT_200MHZ: DEFERRED (150 MHz timing target selected)
ACCEL_ID:              PASS (0x00024c35)
ONE_IMAGE_BYTE_EXACT:  PASS
100_JOB_STABILITY:     PASS (1 reload + 100 resident jobs)
MNIST_10000_BOARD:     PASS (100,000/100,000 logit bytes)
BOARD_ACCURACY:        PASS (98.93%, 9893/10000)
```

## First live-load finding

The first `fpgautil` load reached `fpga_manager=operating`, but the starter
image's PL0 parent remained selected and produced `99,999,999 Hz`. The initial
driver correctly rejected the mismatch before exposing `/dev/lenet5_board`.

The next live tests showed that stock Ubuntu configures IOPLL, RPLL, and DPLL
at approximately 1.5 GHz, 1.0838 GHz, and 1.0667 GHz. Although IOPLL / 8
would generate 187.5 MHz, the stock PMU firmware rejected
`PM_CLOCK_SETDIVIDER` with `-EACCES`. Therefore neither 187.5 MHz nor 150 MHz
can be selected safely from this Linux driver.

The driver never modifies a PS PLL or divider. Stage05 converts the
firmware-owned 100 MHz PL0 reference to 149,998,501 Hz in PL with an MMCM.
The driver reports both values separately: `pl_input_clock_hz` is measured
through the Linux clock framework, while `pl_clock_hz` is the versioned
Stage05 fabric-clock metadata from the overlay.

The staged test proved that FPGA load and driver binding completed while SSH
remained responsive, but a single read of accelerator offset `0x000` then
blocked. Generated Stage03 RTL now gives the exact cause:
`proc_sys_reset.C_AUX_RESET_HIGH=0` made `aux_reset_in` active-low, while the
BD tied that input to constant zero. The entire AXI fabric and accelerator
therefore remained in reset, so no AXI response could return to the CPU.
Stage05 ties both inactive active-low reset inputs to one, waits for MMCM
lock, and has passed post-route functional and SDF reset-release tests.

After a power cycle, the corrected Stage05 image passed every isolated gate:
load, driver probe, single ID read, full status read, and first-image
byte-exact inference. The same board then passed one reload plus 100
resident-model jobs with no timeout, DMA error, scheduler error, or output
mismatch.

The final dataset run compared every one of the board's 100,000 INT8 logit
bytes against `golden_infer.py`; all bytes matched. Board accuracy was
98.93% (9,893/10,000), exactly matching the Python hardware-emulation model.
Average resident job latency was 12,790.53 cycles (85.271 us at
149,998,501 Hz), giving a cycle-limited 11,727 images/s. End-to-end
per-image userspace throughput was 6,422.55 images/s; this includes one image
file read, `mmap`/`munmap`, CSR polling, and control setup per job.
