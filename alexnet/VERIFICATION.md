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
Top-5 79.066%. These are not yet measurements made from this repository.
Measured accuracy remains pending because the ILSVRC2012 validation set is not
present in the workspace. The baseline is considered accuracy-verified only
after all 50,000 validation images are run with `validate_fp32.py` and the
resulting report is recorded.
