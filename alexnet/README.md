# AlexNet FP32 reference

## Python 초보자가 먼저 볼 순서

1. `model.py`: AlexNet layer 구성과 입력이 지나가는 순서
2. `validate_fp32.py`: 모델을 실행하고 shape·사진·정확도를 검사하는 방법
3. `test_model.py`: 구조가 바뀌지 않았는지 자동으로 확인하는 방법
4. `alexnet_contract.yaml`: Python/C++/RTL이 공통으로 따라야 할 고정 수치

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
