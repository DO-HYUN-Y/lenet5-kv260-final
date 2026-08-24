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

## Accuracy status

The torchvision checkpoint metadata reports ImageNet-1K Top-1 56.522% and
Top-5 79.066%. These are not yet measurements made from this repository.
Measured accuracy remains pending because the ILSVRC2012 validation set is not
present in the workspace. The baseline is considered accuracy-verified only
after all 50,000 validation images are run with `validate_fp32.py` and the
resulting report is recorded.
