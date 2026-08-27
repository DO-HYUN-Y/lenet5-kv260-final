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

Calibration still has to supply the actual per-output bias, multiplier and
shift. No trained values are hardcoded in this library.

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
| `dpi_wrappers` | small C ABI entry points suitable for thin SV DPI imports |

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

The test executable checks product corner cases and deterministic random packed
MACs, quantization, K-major window/weight order, dense/grouped convolution,
pooling, FC, descriptors/DDR addresses, DMA burst tails, ping/pong ownership,
local skew timing, postprocess scan order, C ABI wrappers and a small
end-to-end network.

Full `224x224` vectors should be generated as `.bin + manifest + SHA-256` after
the Python integer calibration/export path is frozen. Those vectors are data,
not a second implementation of these operators.
