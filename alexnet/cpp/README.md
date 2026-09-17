# AlexNet INT8 C++ golden models

This directory contains the common bit-exact operator and layout reference used
by the future SystemVerilog testbenches. It deliberately does not model RTL
latency. The exception is `skew_ref`, whose only function is cycle alignment.

## Frozen numeric behavior

- signed INT8 activation and weight
- symmetric numeric zero with bit-pattern zero
- exact signed INT8 product
- checked signed INT32 accumulation
- signed INT32 bias added before scaling
- model-wide checked post-bias bound: signed 27 bits for every INT8 input
- non-negative signed 18-bit fixed-point multiplier
- exact signed 45-bit product, matching one DSP48E2 `27x18` multiplier
- right shift rounded half away from zero
- optional ReLU after scaling
- signed INT8 saturation

`calibrate_int8.py` supplies the actual per-output bias, multiplier and shift
as 16-byte little-endian records (`int32 bias`, `int32 multiplier`, `uint8
right_shift`, `uint8 relu`, six reserved zero bytes). No trained values are
hardcoded in this library.

## Modules

| Module | Responsibility |
|---|---|
| `quant_ref` | bias, fixed-point rounding, ReLU and INT8 saturation |
| `packed_mac_ref` | WP487 two-product split and two-lane OS accumulation |
| `sa_tile_ref` | packed physical M pairs combined into a logical MxN OS tile |
| `window_ref` | K-major windows, stride, padding, M-tail and group channels |
| `conv2d_ref` | dense or grouped logical OIHW convolution |
| `maxpool_ref` | AlexNet 3x3/stride-2 max pool |
| `linear_ref` | batch x K by N x K fully connected reference |
| `layout_ref` | NCHW bytes, K-major N tiles, DMA bursts, ping/pong ownership, N64/M32 postprocess scanner |
| `output_router_ref` | eight independent N8/64-bit routers, descriptor tags, FIFO and ready/valid cycle behavior |
| `activation_bank_ref` | N8 activation-bank ownership, lane-tail masking, sequential fill/read data |
| `activation_pingpong_ref` | Ordered activation A/B ownership, direct/pooled source binding, tag matching, cross-bank overlap, and fixed two-segment composition |
| `weight_tile_bank_ref` | Resident N8 weight-tile fill, context-matched repeatable K replay, and release ownership |
| `partial_sum_bank_ref` | N8 signed-INT32 first/continuation/final channel-chunk accumulation and ordered emit ownership |
| `descriptor_ref` | runtime K/M/N derivation, tile schedule and DDR address calculation |
| `skew_ref` | local M8xN8 activation/weight delay chains and tag timing |
| `alexnet_ref` | five Conv, three Pool and three FC operators connected end-to-end |
| `dpi_wrappers` | scalar/tensor C ABI entry points for SV DPI and Python parity tests, including cached M4 window-token queries |

`conv2d_ref` and `descriptor_ref` support `groups > 1`. The currently frozen
`alexnet_contract.yaml` still selects the torchvision `groups=1` model; support
for groups prevents the golden library from being rewritten if the historical
two-GPU variant is selected later.

## Build and test

From the repository root on Windows PowerShell:

```powershell
cmake -S alexnet/cpp -B alexnet/cpp/build -G "MinGW Makefiles"
cmake --build alexnet/cpp/build
ctest --test-dir alexnet/cpp/build --output-on-failure
```

With the CUDA Python environment from `alexnet/README.md`, compare the compiled
C++ operators directly against PyTorch:

```powershell
& $alexnetPython -m unittest alexnet.test_cpp_golden_against_pytorch -v
```

This parity test covers packed products, requantization, dense/grouped Conv2D,
AlexNet Conv1 geometry, FC, packed OS SA including odd M/N tails, and MaxPool.
All comparisons require exact equality (`rtol=0`, `atol=0`).

The test executable checks product corner cases and deterministic random packed
MACs, quantization, K-major window/weight order, dense/grouped convolution,
pooling, FC, descriptors/DDR addresses, DMA burst tails, ping/pong ownership,
local skew timing, 64-lane postprocess scan/tail/stall order, eight N8 output
routers including full-FIFO turnover and independent backpressure, the cached
M4 window DPI wrapper, C ABI wrappers, and a small end-to-end network.

Full `224x224` vectors are generated as `.bin + manifest + SHA-256` by
`calibrate_int8.py`. `compare_full_int8_cpp.py` loads the raw model and vector
files, executes compiled C++ Conv/Pool/FC code, and requires an exact match at
all eleven captured boundaries. The vectors are data, not a second
implementation of these operators.

For the checked board-weight export, the Release-only full-graph executable
does not require PyTorch. It loads the logical OIHW/NK weight files and
`<iiBB6x>` parameter records, runs the trained batch-one Conv1-through-FC8
graph on a fixed full-range input, and serializes every boundary in the RTL
N8-tile-major DDR layout. Regenerate all boundaries and compare their byte
counts and SHA-256 values with the frozen contract using:

```sh
cmake -S alexnet/cpp -B alexnet/cpp/build-release -DCMAKE_BUILD_TYPE=Release
cmake --build alexnet/cpp/build-release --parallel
python3 alexnet/cpp/tools/verify_board_full_graph_golden.py \
  --output-dir alexnet/cpp/build-release/full_graph_pattern_v1
```

The large board model and generated `.bin` files remain build artifacts; only
`vectors/full_graph_pattern_v1.json` is committed. These are the layerwise
golden DDR images used by the following focused RTL comparisons.

The generator also emits one trained physical-array tile for every layer under
`<output-dir>/rtl_tiles`. Conv1/2 use split M16xN64, Conv3-5 use M8xN112, and
FC6-8 use M1xN16. Run those vectors through the real M8xN128 packed SA,
continuation accumulator, 64-DSP requantizer and result path with:

```sh
vivado -mode batch \
  -source alexnet/scripts/run_alexnet_m8n128_trained_layer_tiles.tcl \
  -notrace
```

The regression checks 26,859 K issues and 4,784 exact result bytes. FC6 is
split into 4,096 + 4,096 + 1,024 K chunks, so this also checks continuation
state across the hardware command limit. This is an exact trained tile gate
for every layer; the integrated graph top still requires an all-tile,
full-image comparison before it is called end-to-end numerically proven.

The generator also emits the raster, first physical weight request, first
parameter records and first Conv1 result slice needed by the integrated-top
smoke under `<output-dir>/top_conv1_smoke`. Run it with:

```sh
vivado -mode batch \
  -source alexnet/scripts/run_alexnet_m8n126_graph_top_trained_conv1_smoke.tcl \
  -notrace
```

This test programs the actual DMA control ports, starts the complete Conv1
raster MM2S, computes the first trained tile and compares its 64-byte scatter
S2MM exactly. It also requires that the result write complete before the long
raster read, exercising concurrent main-DMA MM2S/S2MM operation. It remains a
first-tile checkpoint rather than a full-image claim.
