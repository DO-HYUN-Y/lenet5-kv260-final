# AlexNet INT8 C++ golden models

This directory contains the common bit-exact operator and layout reference used
by the future SystemVerilog testbenches. It deliberately does not model RTL
latency. The exception is `skew_ref`, whose only function is cycle alignment.

## Frozen numeric behavior

- signed INT8 activation and weight
- symmetric numeric zero with bit-pattern zero
- exact signed INT8 product
- checked signed INT32 accumulation
- bias added before scaling using a wider C++ intermediate
- non-negative fixed-point multiplier
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
| `layout_ref` | NCHW bytes, K-major N tiles, DMA bursts, ping/pong ownership, result scan |
| `descriptor_ref` | runtime K/M/N derivation, tile schedule and DDR address calculation |
| `skew_ref` | local M8xN8 activation/weight delay chains and tag timing |
| `alexnet_ref` | five Conv, three Pool and three FC operators connected end-to-end |
| `dpi_wrappers` | scalar and tensor C ABI entry points for SV DPI and Python parity tests |

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
local skew timing, postprocess scan order, C ABI wrappers and a small
end-to-end network.

Full `224x224` vectors are generated as `.bin + manifest + SHA-256` by
`calibrate_int8.py`. `compare_full_int8_cpp.py` loads the raw model and vector
files, executes compiled C++ Conv/Pool/FC code, and requires an exact match at
all eleven captured boundaries. The vectors are data, not a second
implementation of these operators.
