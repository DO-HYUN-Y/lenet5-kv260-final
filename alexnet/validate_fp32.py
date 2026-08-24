"""AlexNet FP32 모델을 실행하고 구조·추론·정확도를 검증하는 프로그램.

사용 예시:

1. 모델 구조만 빠르게 검사
   ``python -m alexnet.validate_fp32 --no-pretrained``
2. 공식 checkpoint까지 불러와 검사
   ``python -m alexnet.validate_fp32``
3. 한 장의 사진 분류
   ``python -m alexnet.validate_fp32 --image 사진.jpg``
4. ImageNet 전체 정확도 측정
   ``python -m alexnet.validate_fp32 --data-root 데이터셋경로``
"""

from __future__ import annotations

# Python 기본 라이브러리: 명령행 옵션, hash, 보고서, 실행환경 정보를 다룬다.
import argparse
import hashlib
import json
import os
import platform
import time
from pathlib import Path
from typing import Any
from urllib.parse import urlparse

# 외부 라이브러리: PyTorch 모델 실행, 이미지 읽기, ImageNet loader에 사용한다.
import torch
from PIL import Image
from torch.utils.data import DataLoader, Subset
from torchvision import __version__ as torchvision_version
from torchvision import datasets

# 같은 alexnet package의 model.py에서 우리가 만든 기준 모델과 도우미를 가져온다.
from .model import (
    CLASS_COUNT,
    INPUT_SHAPE,
    AlexNet,
    capture_activations,
    capture_layer_shapes,
    count_macs,
    create_alexnet,
)


# torchvision이 공개한 공식 V1 checkpoint의 ImageNet-1K 기준 정확도이다.
# 저장소에서 직접 측정한 값과 비교하기 위한 기준이며 실측값 자체는 아니다.
REFERENCE_TOP1 = 56.522
REFERENCE_TOP5 = 79.066


def parse_args() -> argparse.Namespace:
    """터미널에서 전달한 실행 옵션을 읽어 Namespace로 반환한다.

    예를 들어 ``--batch-size 32``를 입력하면 ``args.batch_size``가 32가 된다.
    """

    parser = argparse.ArgumentParser(
        description="224x224 torchvision 호환 AlexNet FP32 기준 모델을 검증합니다."
    )
    parser.add_argument(
        "--data-root",
        type=Path,
        help="공식 devkit과 validation archive/directory가 있는 ImageNet 루트 경로",
    )
    parser.add_argument("--image", type=Path, help="사진 한 장을 분류하고 Top-5 출력")
    parser.add_argument("--batch-size", type=int, default=64)
    parser.add_argument("--workers", type=int, default=4)
    parser.add_argument("--limit", type=int, default=0, help="앞의 N장만 검사(0이면 전체)")
    parser.add_argument("--device", default="auto", help="auto, cpu, cuda 또는 PyTorch device 문자열")
    parser.add_argument(
        "--no-pretrained",
        action="store_true",
        help="checkpoint를 받지 않고 구조만 검사",
    )
    parser.add_argument(
        "--dump-dir",
        type=Path,
        help="사진 한 장의 입력과 layer별 FP32 출력을 .npy로 저장할 폴더",
    )
    parser.add_argument("--report", type=Path, help="검증 결과를 저장할 JSON 경로")
    parser.add_argument("--print-every", type=int, default=50, help="N개 batch마다 진행률 출력")
    return parser.parse_args()


def select_device(requested: str) -> torch.device:
    """모델을 실행할 CPU 또는 GPU를 선택한다."""

    if requested == "auto":
        # NVIDIA CUDA GPU를 쓸 수 있으면 GPU, 아니면 CPU를 자동 선택한다.
        return torch.device("cuda" if torch.cuda.is_available() else "cpu")

    # 사용자가 --device로 직접 지정한 문자열을 PyTorch device로 바꾼다.
    device = torch.device(requested)
    if device.type == "cuda" and not torch.cuda.is_available():
        # GPU가 없는 PC에서 cuda를 요청하면 조용히 CPU로 바꾸지 않고 오류를 낸다.
        raise RuntimeError("CUDA was requested, but torch.cuda.is_available() is false")
    return device


def sha256_file(path: Path) -> str:
    """파일 전체의 SHA-256 hash를 계산한다.

    checkpoint가 바뀌지 않았는지 확인하는 디지털 지문 역할을 한다. 큰 파일을
    한 번에 메모리에 올리지 않고 1 MiB씩 나누어 읽는다.
    """

    digest = hashlib.sha256()
    with path.open("rb") as stream:
        # b""가 나오면 파일 끝에 도달했다는 뜻이다.
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def checkpoint_metadata(weights: object | None) -> dict[str, Any] | None:
    """사용한 checkpoint의 이름, URL, 파일명, hash를 보고서 형식으로 만든다."""

    if weights is None:
        # --no-pretrained 실행에서는 checkpoint가 없으므로 기록할 것도 없다.
        return None

    url = str(weights.url)
    # URL의 마지막 부분에서 실제 checkpoint 파일명만 꺼낸다.
    filename = Path(urlparse(url).path).name
    # torchvision이 다운로드 파일을 보관하는 기본 cache 경로이다.
    cache_path = Path(torch.hub.get_dir()) / "checkpoints" / filename
    return {
        "name": str(weights),
        "url": url,
        "cache_filename": filename,
        "sha256": sha256_file(cache_path) if cache_path.is_file() else None,
    }


def runtime_metadata(device: torch.device) -> dict[str, Any]:
    """결과 재현에 필요한 Python/PyTorch 버전과 실행 device를 기록한다."""

    return {
        "python": platform.python_version(),
        "torch": torch.__version__,
        "torchvision": torchvision_version,
        "device": str(device),
        "cuda_available": torch.cuda.is_available(),
    }


def run_smoke_test(model: AlexNet, device: torch.device) -> dict[str, Any]:
    """가짜 0 입력 한 장으로 모델 구조와 고정 수치를 빠르게 검사한다.

    smoke test는 실제 정확도를 재는 시험이 아니다. 모델이 실행되는지, shape와
    파라미터/MAC 수가 우리가 정한 계약과 같은지를 빠르게 잡아낸다.
    """

    # 실제 사진 대신 모든 값이 0인 [1, 3, 224, 224] FP32 tensor를 만든다.
    x = torch.zeros(INPUT_SHAPE, dtype=torch.float32, device=device)

    # model.py의 도우미로 layer shape와 연산량을 자동 수집한다.
    shapes = capture_layer_shapes(model, x)
    macs_by_layer, macs_per_image = count_macs(model, x)

    # numel()은 tensor에 들어 있는 숫자의 개수이다. 모든 parameter를 합산한다.
    parameter_count = sum(parameter.numel() for parameter in model.parameters())

    # 아래 값이 달라지면 모델 구조가 실수로 변경됐다는 뜻이므로 즉시 중단한다.
    if shapes["conv1"] != (1, 64, 55, 55):
        raise AssertionError(f"Conv1 contract mismatch: {shapes['conv1']}")
    if shapes["pool5"] != (1, 256, 6, 6):
        raise AssertionError(f"Pool5 contract mismatch: {shapes['pool5']}")
    if shapes["logits"] != (1, CLASS_COUNT):
        raise AssertionError(f"Logit contract mismatch: {shapes['logits']}")
    if parameter_count != 61_100_840:
        raise AssertionError(f"Parameter-count mismatch: {parameter_count}")
    if macs_per_image != 714_188_480:
        raise AssertionError(f"MAC-count mismatch: {macs_per_image}")

    # 사람이 터미널에서 바로 확인할 수 있는 결과를 출력한다.
    print("FP32 shape smoke test: PASS")
    for name, shape in shapes.items():
        print(f"  {name:8s} {list(shape)}")
    print(f"  parameters={parameter_count:,}")
    print(f"  MAC/image={macs_per_image:,}  OPS/image={2 * macs_per_image:,}")
    # 같은 결과를 JSON 보고서에도 넣을 수 있도록 dictionary로 반환한다.
    return {
        "status": "pass",
        "parameter_count": parameter_count,
        "macs_per_image": macs_per_image,
        "ops_per_image_1mac_equals_2ops": 2 * macs_per_image,
        "macs_by_layer": macs_by_layer,
        "layer_shapes": {name: list(shape) for name, shape in shapes.items()},
    }


def run_single_image(
    model: AlexNet,
    weights: object,
    image_path: Path,
    device: torch.device,
    dump_dir: Path | None,
) -> dict[str, Any]:
    """이미지 한 장을 전처리하고 AlexNet Top-5 예측을 반환한다."""

    if not image_path.is_file():
        raise FileNotFoundError(image_path)

    # 다양한 이미지 형식을 열고 AlexNet 입력 규격인 RGB 3채널로 통일한다.
    image = Image.open(image_path).convert("RGB")

    # weights.transforms()가 resize 256 -> center crop 224 -> normalize를 수행한다.
    # unsqueeze(0)는 [3, 224, 224] 앞에 batch 차원을 붙여 [1, 3, 224, 224]로 만든다.
    x = weights.transforms()(image).unsqueeze(0).to(device)

    # 추론에서는 학습용 gradient가 필요 없으므로 inference_mode를 사용한다.
    with torch.inference_mode():
        # model 출력 logit에 softmax를 적용하면 합이 1인 class 확률이 된다.
        probabilities = model(x).softmax(dim=1)[0]

    # 확률이 가장 높은 5개의 확률(values)과 class 번호(indices)를 고른다.
    values, indices = probabilities.topk(5)
    # weights metadata에는 0~999 class 번호에 대응하는 사람이 읽는 이름이 있다.
    categories = weights.meta["categories"]
    predictions = [
        {"index": int(index), "label": categories[int(index)], "probability": float(value)}
        for value, index in zip(values.cpu(), indices.cpu())
    ]

    print(f"image: {image_path}")
    for rank, item in enumerate(predictions, start=1):
        print(f"  {rank}: {item['label']} ({item['probability'] * 100:.3f}%)")

    if dump_dir is not None:
        # parents=True는 상위 폴더도 만들고, exist_ok=True는 이미 있어도 허용한다.
        dump_dir.mkdir(parents=True, exist_ok=True)
        import numpy as np

        # .npy는 shape와 dtype을 함께 보존하는 NumPy 파일 형식이다.
        np.save(dump_dir / "input_fp32.npy", x.detach().cpu().numpy())
        # 모든 layer 중간 출력을 C++/INT8/RTL 비교용 golden tensor로 저장한다.
        for name, tensor in capture_activations(model, x).items():
            np.save(dump_dir / f"{name}_fp32.npy", tensor.numpy())
        print(f"saved FP32 golden tensors: {dump_dir}")

    return {"path": str(image_path), "top5": predictions, "dump_dir": str(dump_dir) if dump_dir else None}


def validate_imagenet(
    model: AlexNet,
    weights: object,
    data_root: Path,
    device: torch.device,
    batch_size: int,
    workers: int,
    limit: int,
    print_every: int,
) -> dict[str, Any]:
    """ImageNet validation set에서 Top-1/Top-5 정확도를 측정한다."""

    if not data_root.exists():
        raise FileNotFoundError(data_root)

    try:
        # torchvision ImageNet loader를 쓰면 공식 class 번호 매핑을 적용할 수 있다.
        dataset = datasets.ImageNet(data_root, split="val", transform=weights.transforms())
    except Exception as exc:
        raise RuntimeError(
            "ImageNet could not be opened. Use the official torchvision ImageNet layout "
            "with ILSVRC2012_devkit_t12.tar.gz and ILSVRC2012_img_val.tar, or an already "
            "parsed val directory plus meta.bin."
        ) from exc

    if limit < 0:
        raise ValueError("--limit must be zero or positive")
    if limit:
        # 개발 중 빠른 확인을 위해 전체 대신 앞의 N장만 선택할 수 있다.
        dataset = Subset(dataset, range(min(limit, len(dataset))))

    # DataLoader가 이미지를 batch 단위로 읽어 모델에 공급한다.
    loader = DataLoader(
        dataset,
        batch_size=batch_size,
        # 정확도 측정에서는 입력 순서를 바꿀 필요가 없어 shuffle=False로 둔다.
        shuffle=False,
        # workers는 디스크에서 이미지를 병렬로 읽는 보조 process 수이다.
        num_workers=workers,
        # GPU 사용 시 pinned memory가 CPU->GPU 복사를 빠르게 할 수 있다.
        pin_memory=device.type == "cuda",
        persistent_workers=workers > 0,
    )

    # 전체 이미지 수와 정답 개수를 누적할 변수들이다.
    total = 0
    top1_correct = 0
    top5_correct = 0
    start = time.perf_counter()
    with torch.inference_mode():
        for batch_index, (images, targets) in enumerate(loader, start=1):
            # non_blocking=True는 가능한 환경에서 데이터 전송을 비동기로 시도한다.
            images = images.to(device, non_blocking=True)
            targets = targets.to(device, non_blocking=True)

            # logits shape는 [batch, 1000], predictions는 각 이미지의 Top-5 class 번호이다.
            logits = model(images)
            predictions = logits.topk(5, dim=1).indices

            # targets[:, None]은 정답 [batch]를 [batch, 1]로 바꿔 Top-5와 비교한다.
            matches = predictions.eq(targets[:, None])
            # 첫 번째 예측이 맞으면 Top-1 정답이다.
            top1_correct += int(matches[:, :1].sum().item())
            # 다섯 개 중 하나라도 맞으면 Top-5 정답이다.
            top5_correct += int(matches.any(dim=1).sum().item())
            total += int(targets.numel())
            if batch_index % print_every == 0:
                print(
                    f"  images={total} top1={100.0 * top1_correct / total:.3f}% "
                    f"top5={100.0 * top5_correct / total:.3f}%"
                )

    # 정확도뿐 아니라 소프트웨어 검증 실행 속도도 함께 기록한다.
    elapsed = time.perf_counter() - start
    result = {
        "images": total,
        "top1_percent": 100.0 * top1_correct / total,
        "top5_percent": 100.0 * top5_correct / total,
        "elapsed_seconds": elapsed,
        "images_per_second": total / elapsed,
        "limited_subset": bool(limit),
    }
    print(
        f"ImageNet FP32: top1={result['top1_percent']:.3f}% "
        f"top5={result['top5_percent']:.3f}% images={total} "
        f"throughput={result['images_per_second']:.2f} image/s"
    )
    if not limit:
        # 전체 50,000장을 측정했을 때만 공식 값과의 차이를 의미 있게 기록한다.
        result["reference_top1_percent"] = REFERENCE_TOP1
        result["reference_top5_percent"] = REFERENCE_TOP5
        result["top1_delta_pp"] = result["top1_percent"] - REFERENCE_TOP1
        result["top5_delta_pp"] = result["top5_percent"] - REFERENCE_TOP5
    return result


def main() -> None:
    """명령행 옵션에 따라 smoke/image/ImageNet 검증을 순서대로 실행한다."""

    args = parse_args()

    # 잘못된 옵션 조합을 계산 시작 전에 사용자에게 알려 준다.
    if args.batch_size <= 0 or args.workers < 0 or args.print_every <= 0:
        raise ValueError("batch size and print interval must be positive; workers must be nonnegative")
    if args.dump_dir is not None and args.image is None:
        raise ValueError("--dump-dir requires --image")
    if args.no_pretrained and (args.image is not None or args.data_root is not None):
        raise ValueError("image inference and validation require pretrained weights")

    # 같은 실행에서 임의 값이 필요할 경우 결과가 반복되도록 seed를 고정한다.
    torch.manual_seed(0)
    device = select_device(args.device)

    # 모델과 checkpoint/전처리 정보를 만들고 추론 모드로 전환한다.
    model, weights = create_alexnet(pretrained=not args.no_pretrained)
    # eval()은 Dropout을 끄고, to(device)는 모델을 CPU 또는 GPU로 옮긴다.
    model.eval().to(device)

    # 모든 실행에서 공통으로 남길 기본 보고서 항목이다.
    report: dict[str, Any] = {
        "contract_version": 1,
        "runtime": runtime_metadata(device),
        "checkpoint": checkpoint_metadata(weights),
        "reference_accuracy_percent": {"top1": REFERENCE_TOP1, "top5": REFERENCE_TOP5},
    }
    # image나 ImageNet 옵션과 관계없이 구조 smoke test는 항상 먼저 수행한다.
    report["smoke_test"] = run_smoke_test(model, device)

    # 사용자가 옵션을 준 작업만 추가로 수행한다.
    if args.image is not None:
        report["single_image"] = run_single_image(model, weights, args.image, device, args.dump_dir)
    if args.data_root is not None:
        report["imagenet_validation"] = validate_imagenet(
            model,
            weights,
            args.data_root,
            device,
            args.batch_size,
            args.workers,
            args.limit,
            args.print_every,
        )

    if args.report is not None:
        # 보고서 상위 폴더가 없으면 만든 뒤, UTF-8 JSON으로 저장한다.
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(report, indent=2, ensure_ascii=False) + os.linesep, encoding="utf-8")
        print(f"saved report: {args.report}")


if __name__ == "__main__":
    # 이 파일을 직접 실행했을 때만 main()을 호출한다.
    # 다른 파일에서 import할 때는 자동 실행되지 않는다.
    main()
