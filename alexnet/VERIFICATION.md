# FP32 verification record

Date: 2026-08-24 (Asia/Seoul)

## Frozen baseline

- Model: `torchvision.models.alexnet`
- Weights: `AlexNet_Weights.IMAGENET1K_V1`
- Input: RGB `NCHW [1, 3, 224, 224]`
- Conv1: `3 -> 64`, kernel 11, stride 4, padding 2
- Grouped convolution: none (`groups=1` on every convolution)
- Parameters: 61,100,840
- Compute: 714,188,480 MAC/image
- TOPS convention compute: 1,428,376,960 OPS/image (`1 MAC = 2 OPS`)

## Checkpoint

```text
filename: alexnet-owt-7be5be79.pth
SHA-256: 7be5be791159472b1fbf3c69796f7cb30dca7ad8466c2df70058c37116cdee02
```

The checkpoint was downloaded through the torchvision weight enum with hash
checking enabled.

## Executed checks

Environment:

```text
Python 3.12.10
torch 2.13.0+cpu
torchvision 0.28.0+cpu
```

CUDA environment:

```text
NVIDIA GeForce RTX 3050 8GB (compute capability 8.6)
NVIDIA driver 560.94 / driver-supported CUDA 12.6
torch 2.13.0+cu126
torchvision 0.28.0+cu126
CUDA available: true
```

Commands:

```powershell
python -m unittest alexnet.test_model -v
python -m alexnet.validate_fp32 --report alexnet_output\smoke_report.json
python -m pip check
```

Results:

- 2/2 unit tests passed.
- The repository model accepted the torchvision state dictionary with
  `strict=True` and produced bit-for-bit identical logits to the torchvision
  implementation for the deterministic test input.
- Conv1 output was `[1, 64, 55, 55]`.
- Final output was `[1, 1000]`.
- Every Conv/Pool/FC layer shape matched `alexnet_contract.yaml`.
- Parameter and MAC counts matched the frozen contract.
- The Python dependency environment passed `pip check`.
- A CUDA tensor matrix multiplication completed on `cuda:0`.
- `validate_fp32.py` selected `device=cuda` automatically and passed the full
  checkpoint/shape/MAC smoke test.

## Local RTX 3050 benchmark

This is a short synthetic-data benchmark, so it excludes ImageNet file loading
and augmentation overhead. Training used automatic mixed precision (AMP FP16).

```text
training batch 16:  209.853 image/s
training batch 32:  336.706 image/s
training batch 64:  479.822 image/s
training batch 128: 617.178 image/s
training batch 256: 697.996 image/s, peak torch allocation 1.434 GiB
inference batch 64: 1759.407 image/s
```

At the measured batch-256 compute rate, 90 ImageNet epochs contain about 45.9
hours of model compute. Real end-to-end training should be budgeted at roughly
50-60 hours after image decoding, augmentation, validation, and checkpoint I/O.

## Accuracy status

The torchvision checkpoint metadata reports ImageNet-1K Top-1 56.522% and
Top-5 79.066%. The official validation archive and devkit are now available in
the local ignored `data/` directory. The MLCommons option-1 500-image subset
measured FP32 Top-1 58.0% and Top-5 77.6%. This subset also supplies INT8
activation calibration, so it is a reproducible implementation check but not
an unbiased replacement for the complete 50,000-image validation run. Full-set
accuracy sign-off remains pending.

## INT8 calibration and export

Calibration source and identity:

```text
ILSVRC2012_img_val.tar: 6,744,924,160 bytes
archive MD5: 29b22e2961454d5413ddabcf34fc5622
ILSVRC2012 devkit MD5: fa75699e90414af021442c21a62c3abf
MLCommons option-1 list: 500 unique images
list SHA-256: 7662247d1d9407d6cb564268f64c5a4a6cf9f1a34fd2e6cdc3b94dcf278b3dc9
ordered image-set SHA-256: 3ac0e8c994678ead04eee6479cae87d1c80c5600c6cd03fae17883f5ef6d9cec
```

Three activation-range candidates were evaluated on the first 50 list entries:

| Absolute percentile | INT8 Top-1 | INT8 Top-5 | FP32 Top-1 agreement |
|---:|---:|---:|---:|
| 99.99 | 48.0% | 64.0% | 84.0% |
| 99.999 | 50.0% | 64.0% | 86.0% |
| 100.0 | 52.0% | 64.0% | 90.0% |

The frozen contract therefore uses sampled abs-max (`100.0`). Weights are
signed symmetric INT8 per output channel; activations are signed symmetric
INT8 per tensor/layer. The export contains 61,090,496 weight bytes and 165,504
parameter bytes. All 10,344 output channels have an independent signed INT32
bias, non-negative signed INT32 multiplier and 0..62 right shift in a 16-byte
little-endian record. Exact values and file hashes are tracked in
`calibration/int8_mlcommons500_contract.json`.

The selected input scale is `0.020787402400820273`. Layer summaries are:

| Layer | Output scale | Bias INT32 range | Right-shift range |
|---|---:|---:|---:|
| Conv1 | 0.3221652114 | -102825..38116 | 42..44 |
| Conv2 | 0.6464929656 | -615..1117 | 37..42 |
| Conv3 | 0.8195159792 | -517..783 | 38..41 |
| Conv4 | 0.7341894916 | -1277..901 | 39..41 |
| Conv5 | 0.3391598979 | -695..4015 | 39..40 |
| FC6 | 0.2235676473 | -699..927 | 41..45 |
| FC7 | 0.2909000126 | -572..1983 | 41..46 |
| FC8 | 0.3300604933 | -721..684 | 40..42 |

Measured on all 500 calibration images:

| Model | Top-1 | Top-5 |
|---|---:|---:|
| FP32 pretrained | 58.0% (290/500) | 77.6% (388/500) |
| compiled C++ INT8 | 56.8% (284/500) | 76.6% (383/500) |

The observed loss is 1.2 percentage points Top-1 and 1.0 point Top-5. FP32 and
INT8 Top-1 predictions agree on 459/500 images (91.8%). These numbers are not
an unbiased final-accuracy estimate because calibration and measurement use the
same 500 images.

## C++ INT8 golden parity

Date: 2026-08-27 (Asia/Seoul)

The compiled C++ golden DLL was loaded from Python and compared directly with
PyTorch using deterministic tensors. Commands:

```powershell
cmake --build alexnet/cpp/build
& $alexnetPython -m unittest alexnet.test_cpp_golden_against_pytorch -v
```

Results:

- 6/6 cross-language parity tests passed with exact equality.
- 4,096 signed INT8 packed lo/hi product vectors matched PyTorch INT32 products.
- 2,052 directed/random requantization vectors matched the frozen rounding,
  ReLU and saturation contract.
- Dense Conv, grouped Conv and AlexNet Conv1 `11x11/s4/p2` accumulation matched.
- FC and the packed OS SA model matched PyTorch INT32 matrix multiplication,
  including odd `M=33` and output tail `N=65`.
- AlexNet `3x3/s2` MaxPool matched.

The trained, calibrated network was also checked on
`ILSVRC2012_val_00027145.JPEG`. Compiled C++ exactly matched the independent
Python integer reference at Conv1, Pool1, Conv2, Pool2, Conv3, Conv4, Conv5,
Pool5, FC6, FC7 and FC8: all eleven mismatch counts were zero. This closes the
software full-network byte-exact gate; RTL timing/backpressure verification is
still a later phase.
