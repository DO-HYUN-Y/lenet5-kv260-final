# AlexNet FP32/INT8 reference

## Python 초보자가 먼저 볼 순서

1. `model.py`: AlexNet layer 구성과 입력이 지나가는 순서
2. `validate_fp32.py`: 모델을 실행하고 shape·사진·정확도를 검사하는 방법
3. `test_model.py`: 구조가 바뀌지 않았는지 자동으로 확인하는 방법
4. `alexnet_contract.yaml`: Python/C++/RTL이 공통으로 따라야 할 고정 수치
5. `cpp/README.md`: INT8 모듈별 C++ golden model과 빌드 방법
6. `calibrate_int8.py`: 실제 영상으로 activation scale을 정하고 RTL parameter를 내보내는 방법
7. `compare_full_int8_cpp.py`: Python과 C++ 전체 네트워크 tensor를 층별 비교하는 방법
8. `PRE_RTL_SIGNOFF.md`: 최종 SA/buffer/numeric/zero-skip 결정과 RTL 진입 gate

Python 코드에는 각 함수의 역할, tensor shape, 필요한 이유를 한국어 주석으로
기록했다. 처음에는 `model.py`의 `AlexNet.__init__()`과 `forward()`만 읽고,
그다음 `validate_fp32.py`의 `main()`에서 호출 흐름을 따라가는 것이 쉽다.

This directory freezes the software reference that must be correct before INT8,
C++, or RTL work starts.  The selected model is torchvision AlexNet with
`AlexNet_Weights.IMAGENET1K_V1`, a `3x224x224` RGB input, and Conv1 padding 2.
This is the 64/192/384/256/256-channel torchvision variant; it does not use the
grouped convolutions from the historical two-GPU Caffe model.

## CUDA GPU environment (recommended)

The CUDA torch wheel is large and exceeds the legacy Windows path limit when
the virtual environment is created under this deeply nested repository. Use a
shorter environment path. From the repository root on Windows PowerShell:

```powershell
$alexnetGpuVenv = "$env:USERPROFILE\Documents\Codex\.venvs\alexnet-kv260"
python -m venv $alexnetGpuVenv
& "$alexnetGpuVenv\Scripts\python.exe" -m pip install -r alexnet\requirements-cu126.txt
$alexnetPython = "$alexnetGpuVenv\Scripts\python.exe"
```

Verified hardware/runtime:

```text
NVIDIA GeForce RTX 3050 8GB
NVIDIA driver 560.94 / CUDA driver 12.6
torch 2.13.0+cu126 / torchvision 0.28.0+cu126
```

For a CPU-only fallback, create `.venv` in the repository and install
`alexnet\requirements.txt` instead.

## Architecture and checkpoint smoke test

The first run downloads the official checkpoint into the PyTorch cache:

```powershell
& $alexnetPython -m alexnet.validate_fp32 --report alexnet_output\smoke_report.json
```

For an offline architecture-only check:

```powershell
& $alexnetPython -m alexnet.validate_fp32 --no-pretrained
& $alexnetPython -m unittest alexnet.test_model
```

## One-image inference and golden tensor dump

```powershell
& $alexnetPython -m alexnet.validate_fp32 `
  --image path\to\image.jpg `
  --dump-dir alexnet_output\sample_0001 `
  --report alexnet_output\sample_0001.json
```

The dump contains the normalized FP32 input and each contract-relevant layer
output as NumPy arrays.  These tensors will be the comparison source for the
future INT8 and C++ models.

## ImageNet validation

Use torchvision's official ImageNet dataset layout so that the ILSVRC class
mapping is not replaced by an accidental alphabetical directory mapping:

```powershell
& $alexnetPython -m alexnet.validate_fp32 `
  --data-root D:\datasets\imagenet `
  --batch-size 64 `
  --workers 8 `
  --report alexnet_output\imagenet_fp32.json
```

The published checkpoint metadata is Top-1 56.522% and Top-5 79.066%.  Those
numbers are reference metadata, not a measurement from this repository.  The
project baseline becomes verified only after the 50,000-image validation run is
recorded.

The verified model has 61,100,840 parameters and performs 714,188,480 MAC per
image, or 1,428,376,960 operations under the project's `1 MAC = 2 OPS`
convention. The downloaded checkpoint SHA-256 is recorded in
`alexnet_contract.yaml`.

## INT8 calibration dataset

The reproducible default is the official ILSVRC2012 validation archive plus
MLCommons Inference calibration option 1. The list fixes exactly 500 filenames;
its SHA-256 is checked before calibration. This is a good hardware-calibration
set because it has the same 1,000-class input distribution as the pretrained
AlexNet and is also used by a public inference benchmark. It is not a claim
that the ImageNet images are open-source: their separate ImageNet terms still
apply, and `data/` remains git-ignored.

Download these two official files into `data\imagenet`:

```text
https://image-net.org/data/ILSVRC/2012/ILSVRC2012_img_val.tar
https://image-net.org/data/ILSVRC/2012/ILSVRC2012_devkit_t12.tar.gz
```

Then verify the 6.28 GiB validation archive, download and hash-check the
MLCommons list, and extract only the selected 500 images:

```powershell
& $alexnetPython -m alexnet.prepare_calibration_data `
  --archive data\imagenet\ILSVRC2012_img_val.tar
```

The expected archive byte count is `6,744,924,160`, its MD5 is
`29b22e2961454d5413ddabcf34fc5622`, and the calibration-list SHA-256 is
`7662247d1d9407d6cb564268f64c5a4a6cf9f1a34fd2e6cdc3b94dcf278b3dc9`.

## Calibrate, export, and compare the full INT8 network

The calibration command uses signed symmetric INT8 activations, per-output-
channel symmetric INT8 weights, INT32 bias/accumulation, and one integer
multiplier/right-shift pair per output channel. It writes raw RTL-ready blobs,
a manifest with every file hash, and one full-network tensor vector:

```powershell
& $alexnetPython -m alexnet.calibrate_int8 `
  --image-dir data\imagenet\calibration_mlcommons_option1 `
  --calibration-list data\imagenet\cal_image_list_option_1.txt `
  --devkit data\imagenet\ILSVRC2012_devkit_t12.tar.gz `
  --output-dir alexnet_output\int8_mlcommons500 `
  --contract-output alexnet\calibration\int8_mlcommons500_contract.json `
  --device cuda --batch-size 32 --limit 500 --percentile 100 `
  --multiplier-bits 18
```

Build the C++ library and require byte-exact equality at every Conv, Pool and
FC boundary. Use the vector directory emitted by the calibration command:

```powershell
cmake --build alexnet\cpp\build --config Release
& $alexnetPython -m alexnet.compare_full_int8_cpp `
  --model-manifest alexnet_output\int8_mlcommons500\manifest.json `
  --vector-dir alexnet_output\int8_mlcommons500\vectors\0000_ILSVRC2012_val_00027145 `
  --dll alexnet\cpp\build\libalexnet_golden_dpi.dll
```

Finally, the following command measures FP32 and compiled C++ INT8 top-1/top-5
on the 500 labeled images. Because the same images supplied the activation
calibration, this is an implementation check rather than an unbiased final
accuracy estimate. Final accuracy sign-off still uses a disjoint set or the
complete 50,000-image validation run.

```powershell
& $alexnetPython -m alexnet.evaluate_int8_cpp `
  --model-manifest alexnet_output\int8_mlcommons500\manifest.json `
  --image-dir data\imagenet\calibration_mlcommons_option1 `
  --image-list data\imagenet\cal_image_list_option_1.txt `
  --devkit data\imagenet\ILSVRC2012_devkit_t12.tar.gz `
  --dll alexnet\cpp\build\libalexnet_golden_dpi.dll --limit 500
```

The frozen 2026-08-27 run selected abs-max (`--percentile 100`) after a
50-image comparison against 99.99 and 99.999. On all 500 calibration images,
FP32 measured 58.0%/77.6% and compiled C++ INT8 measured 56.8%/77.0%
Top-1/Top-5. The eleven exported Conv/Pool/FC boundaries all matched the Python
integer reference byte-for-byte. The exact 10,344-channel parameters are in
`calibration/int8_mlcommons500_contract.json`; the compact evidence record is
`calibration/int8_mlcommons500_results.json`.

## Pre-RTL sign-off dataset and profiler

Create a calibration-disjoint, class-balanced validation subset directly from
the official archive. The checked-in lists contain only ImageNet filenames;
the licensed images remain under ignored `data/`:

```powershell
& $alexnetPython -m alexnet.prepare_disjoint_validation `
  --archive data\imagenet\ILSVRC2012_img_val.tar `
  --devkit data\imagenet\ILSVRC2012_devkit_t12.tar.gz `
  --exclude-list data\imagenet\cal_image_list_option_1.txt
```

`imagenet_disjoint_balanced_5000.txt` selects five deterministic images from
each of 1,000 classes. `imagenet_profile_balanced_1000.txt` selects one per
class for accumulator, saturation, structural-padding, kernel-row, packed-pair,
M32-vector and 4x4-block sparsity profiling. The frozen results and RTL-entry
decisions are summarized in `PRE_RTL_SIGNOFF.md`.
