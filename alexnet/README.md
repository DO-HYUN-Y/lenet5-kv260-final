# AlexNet FP32 reference

This directory freezes the software reference that must be correct before INT8,
C++, or RTL work starts.  The selected model is torchvision AlexNet with
`AlexNet_Weights.IMAGENET1K_V1`, a `3x224x224` RGB input, and Conv1 padding 2.
This is the 64/192/384/256/256-channel torchvision variant; it does not use the
grouped convolutions from the historical two-GPU Caffe model.

## Environment

From the repository root on Windows PowerShell:

```powershell
python -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r alexnet\requirements.txt
```

On a Windows installation with the legacy path-length limit, the first pip run
can report `WinError 206` after torch itself has been installed. Re-run the same
pip command once; pip then completes the remaining torchvision installation.

## Architecture and checkpoint smoke test

The first run downloads the official checkpoint into the PyTorch cache:

```powershell
.\.venv\Scripts\python.exe -m alexnet.validate_fp32 --report alexnet_output\smoke_report.json
```

For an offline architecture-only check:

```powershell
.\.venv\Scripts\python.exe -m alexnet.validate_fp32 --no-pretrained
.\.venv\Scripts\python.exe -m unittest alexnet.test_model
```

## One-image inference and golden tensor dump

```powershell
.\.venv\Scripts\python.exe -m alexnet.validate_fp32 `
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
.\.venv\Scripts\python.exe -m alexnet.validate_fp32 `
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
