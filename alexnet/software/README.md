# KV260 AlexNet Linux runtime

This directory contains the first board-runtime boundary for the routed
200 MHz M4xN8 bitstream. It is designed for polling bring-up first; IRQ-driven
operation can follow after one saved image completes correctly.

## What is implemented

- `driver/alexnet_board.c` maps the accelerator, main AXI DMA, and camera AXI
  DMA registers, verifies the stock PS PL0 input is near 100 MHz and checks the
  fixed 199,998,002 Hz MMCM fabric-clock metadata, allocates one
  page-aligned 61,767,680-byte coherent DMA region below 4 GiB, and exposes bounded register
  ioctls plus buffer `mmap` through `/dev/alexnet_board`.
- `runtime/alexnet_camera_demo.py` verifies and loads the generated model,
  performs the frozen resize/center-crop/RGB-normalize/INT8 packing, starts the
  camera DMA once and the graph, waits for FC8, and prints ImageNet top-k. The
  PL frame cache supplies Conv1's eight input replays. Dog indices print in the
  requested form, for example `결과: 강아지 (golden retriever)`.
- `overlay/alexnet_kv260.dts` describes the three fixed PS register windows.
- `scripts/package_firmware.sh` converts the routed `.bit` for FPGA manager and
  compiles the overlay.

This software has passed its four contract tests on both the host and KV260.
The preceding non-cache release passed coherent DMA/CSR inspection, saved-image
inference, and live USB-camera dog classification. The frame-cache update
removes seven camera DMA launches/waits per inference and has a timing-clean
200 MHz bitstream. That new firmware is copied to the board and hash-verified,
but must still be loaded with `sudo` before its new latency is measured.

## Coherent DDR layout

| Region | Offset | Allocated bytes |
| --- | ---: | ---: |
| preprocessed camera input | 0 | 401,408 |
| activation A | 401,408 | 64,896 |
| activation B | 466,304 | 43,264 |
| packed weights | 509,568 | 61,090,496 |
| quantization parameters | 61,600,128 | 165,504 |
| FC8 output | 61,765,632 | 1,024 (1,000 valid) |

Every region base is 128-byte aligned. The activation sizes cover the largest
tensor assigned to each reused buffer: Conv3 for A and Conv4 for B.
The listed regions use 61,766,656 bytes. The coherent allocation adds 1,024
unused bytes at the end so Linux can map the whole buffer on a 4 KiB page
boundary.

The allocation is intentionally kernel-owned. Stock generic DMA-BUF mappings
do not provide a portable physical/bus address that this 32-bit simple-mode
AXI DMA can consume. Ensure the board boot arguments reserve at least 128 MiB
of CMA (for example `cma=128M`) before loading the module.

## Host-side checks

Generate and verify the model images, then run the software contract tests:

```sh
python -m alexnet.export_board_weights
python -m alexnet.verify_board_weights
python -m unittest alexnet.software.runtime.test_runtime
```

Package the FPGA-manager files. When Xilinx tools are not on `PATH`, pass their
locations explicitly:

```sh
BOOTGEN=/path/to/Vivado/bin/bootgen \
DTC=/path/to/Vivado/bin/dtc \
alexnet/software/scripts/package_firmware.sh
```

## Board-side order

After copying this directory, the generated board model directory, the
`.bit.bin`, and `.dtbo` to the KV260:

```sh
cd /home/ubuntu/alexnet_kv260
sudo alexnet/software/scripts/install_board.sh --load-and-probe
```

The installer verifies the exact timing-clean firmware hashes before changing
the FPGA, unloads the stock starter-kit overlay, loads the AlexNet full
bitstream/overlay, probes the driver, and creates `/dev/alexnet_board`. Use
`--load-only` and `--probe-only` when debugging those two stages separately.

1. Build `driver/` with `make` against the running kernel headers.
2. Install the `.bit.bin` under `/lib/firmware` and apply the overlay using the
   board's FPGA-manager/configfs flow.
3. Load `alexnet_board.ko`. Probe must report PL0 input near 100 MHz and fabric
   metadata 199,998,002 Hz, then create `/dev/alexnet_board`. The accelerator,
   DMAs, and AXI interconnect run from the internal MMCM fabric clock, not
   directly from PL0.
4. Before installing or opening a camera, verify the board ID, M4xN8/200 build
   word, clock, and status:

```sh
python3 -m alexnet.software.runtime.alexnet_camera_demo --inspect
```

5. Install `python3-opencv` and `python3-numpy` if they are absent.
6. First classify one saved image:

```sh
python3 -m alexnet.software.runtime.alexnet_camera_demo \
  --board-dir alexnet_output/int8_mlcommons500_board \
  --image test.jpg
```

7. Only after that passes, start a V4L2 USB camera:

```sh
python3 -m alexnet.software.runtime.alexnet_camera_demo \
  --board-dir alexnet_output/int8_mlcommons500_board --camera 0
```

The runtime uses polling and a single captured frame at a time. Each frame has
one PS camera-DMA launch; PL replays it eight times internally for Conv1.
`Ctrl+C` stops the live loop. OpenCV bilinear resize is used on the PS; its
final board accuracy must be measured because pixel interpolation can differ
slightly from torchvision.
