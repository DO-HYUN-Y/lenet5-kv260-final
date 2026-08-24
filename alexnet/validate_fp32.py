"""Smoke-test, inspect, and validate the frozen FP32 AlexNet reference."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import time
from pathlib import Path
from typing import Any
from urllib.parse import urlparse

import torch
from PIL import Image
from torch.utils.data import DataLoader, Subset
from torchvision import __version__ as torchvision_version
from torchvision import datasets

from .model import (
    CLASS_COUNT,
    INPUT_SHAPE,
    AlexNet,
    capture_activations,
    capture_layer_shapes,
    count_macs,
    create_alexnet,
)


REFERENCE_TOP1 = 56.522
REFERENCE_TOP5 = 79.066


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Validate the torchvision-compatible 224x224 AlexNet FP32 reference."
    )
    parser.add_argument(
        "--data-root",
        type=Path,
        help="ImageNet root containing the official devkit and validation archive/directory.",
    )
    parser.add_argument("--image", type=Path, help="Run top-5 inference on one image.")
    parser.add_argument("--batch-size", type=int, default=64)
    parser.add_argument("--workers", type=int, default=4)
    parser.add_argument("--limit", type=int, default=0, help="Validate only the first N images (0 = all).")
    parser.add_argument("--device", default="auto", help="auto, cpu, cuda, or a torch device string.")
    parser.add_argument("--no-pretrained", action="store_true", help="Skip checkpoint loading for an offline shape test.")
    parser.add_argument("--dump-dir", type=Path, help="Save one image's FP32 input and per-layer .npy tensors.")
    parser.add_argument("--report", type=Path, help="Write machine-readable validation results as JSON.")
    parser.add_argument("--print-every", type=int, default=50, help="Print validation progress every N batches.")
    return parser.parse_args()


def select_device(requested: str) -> torch.device:
    if requested == "auto":
        return torch.device("cuda" if torch.cuda.is_available() else "cpu")
    device = torch.device(requested)
    if device.type == "cuda" and not torch.cuda.is_available():
        raise RuntimeError("CUDA was requested, but torch.cuda.is_available() is false")
    return device


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def checkpoint_metadata(weights: object | None) -> dict[str, Any] | None:
    if weights is None:
        return None
    url = str(weights.url)
    filename = Path(urlparse(url).path).name
    cache_path = Path(torch.hub.get_dir()) / "checkpoints" / filename
    return {
        "name": str(weights),
        "url": url,
        "cache_filename": filename,
        "sha256": sha256_file(cache_path) if cache_path.is_file() else None,
    }


def runtime_metadata(device: torch.device) -> dict[str, Any]:
    return {
        "python": platform.python_version(),
        "torch": torch.__version__,
        "torchvision": torchvision_version,
        "device": str(device),
        "cuda_available": torch.cuda.is_available(),
    }


def run_smoke_test(model: AlexNet, device: torch.device) -> dict[str, Any]:
    x = torch.zeros(INPUT_SHAPE, dtype=torch.float32, device=device)
    shapes = capture_layer_shapes(model, x)
    macs_by_layer, macs_per_image = count_macs(model, x)
    parameter_count = sum(parameter.numel() for parameter in model.parameters())
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

    print("FP32 shape smoke test: PASS")
    for name, shape in shapes.items():
        print(f"  {name:8s} {list(shape)}")
    print(f"  parameters={parameter_count:,}")
    print(f"  MAC/image={macs_per_image:,}  OPS/image={2 * macs_per_image:,}")
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
    if not image_path.is_file():
        raise FileNotFoundError(image_path)

    image = Image.open(image_path).convert("RGB")
    x = weights.transforms()(image).unsqueeze(0).to(device)
    with torch.inference_mode():
        probabilities = model(x).softmax(dim=1)[0]
    values, indices = probabilities.topk(5)
    categories = weights.meta["categories"]
    predictions = [
        {"index": int(index), "label": categories[int(index)], "probability": float(value)}
        for value, index in zip(values.cpu(), indices.cpu())
    ]

    print(f"image: {image_path}")
    for rank, item in enumerate(predictions, start=1):
        print(f"  {rank}: {item['label']} ({item['probability'] * 100:.3f}%)")

    if dump_dir is not None:
        dump_dir.mkdir(parents=True, exist_ok=True)
        import numpy as np

        np.save(dump_dir / "input_fp32.npy", x.detach().cpu().numpy())
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
    if not data_root.exists():
        raise FileNotFoundError(data_root)

    try:
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
        dataset = Subset(dataset, range(min(limit, len(dataset))))

    loader = DataLoader(
        dataset,
        batch_size=batch_size,
        shuffle=False,
        num_workers=workers,
        pin_memory=device.type == "cuda",
        persistent_workers=workers > 0,
    )

    total = 0
    top1_correct = 0
    top5_correct = 0
    start = time.perf_counter()
    with torch.inference_mode():
        for batch_index, (images, targets) in enumerate(loader, start=1):
            images = images.to(device, non_blocking=True)
            targets = targets.to(device, non_blocking=True)
            logits = model(images)
            predictions = logits.topk(5, dim=1).indices
            matches = predictions.eq(targets[:, None])
            top1_correct += int(matches[:, :1].sum().item())
            top5_correct += int(matches.any(dim=1).sum().item())
            total += int(targets.numel())
            if batch_index % print_every == 0:
                print(
                    f"  images={total} top1={100.0 * top1_correct / total:.3f}% "
                    f"top5={100.0 * top5_correct / total:.3f}%"
                )

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
        result["reference_top1_percent"] = REFERENCE_TOP1
        result["reference_top5_percent"] = REFERENCE_TOP5
        result["top1_delta_pp"] = result["top1_percent"] - REFERENCE_TOP1
        result["top5_delta_pp"] = result["top5_percent"] - REFERENCE_TOP5
    return result


def main() -> None:
    args = parse_args()
    if args.batch_size <= 0 or args.workers < 0 or args.print_every <= 0:
        raise ValueError("batch size and print interval must be positive; workers must be nonnegative")
    if args.dump_dir is not None and args.image is None:
        raise ValueError("--dump-dir requires --image")
    if args.no_pretrained and (args.image is not None or args.data_root is not None):
        raise ValueError("image inference and validation require pretrained weights")

    torch.manual_seed(0)
    device = select_device(args.device)
    model, weights = create_alexnet(pretrained=not args.no_pretrained)
    model.eval().to(device)

    report: dict[str, Any] = {
        "contract_version": 1,
        "runtime": runtime_metadata(device),
        "checkpoint": checkpoint_metadata(weights),
        "reference_accuracy_percent": {"top1": REFERENCE_TOP1, "top5": REFERENCE_TOP5},
    }
    report["smoke_test"] = run_smoke_test(model, device)

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
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(report, indent=2, ensure_ascii=False) + os.linesep, encoding="utf-8")
        print(f"saved report: {args.report}")


if __name__ == "__main__":
    main()
