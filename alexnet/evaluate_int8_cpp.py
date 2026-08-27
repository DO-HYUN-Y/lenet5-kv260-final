"""Measure FP32 and exported C++ INT8 AlexNet on labeled ImageNet images."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import time

import torch

from .calibrate_int8 import CalibrationImages, load_imagenet_validation_targets
from .compare_full_int8_cpp import configure_library, run_cpp_alexnet
from .int8_reference import load_quantized_alexnet, quantize_activation
from .model import create_alexnet


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model-manifest", type=Path, required=True)
    parser.add_argument("--image-dir", type=Path, required=True)
    parser.add_argument("--image-list", type=Path, required=True)
    parser.add_argument("--devkit", type=Path, required=True)
    parser.add_argument(
        "--dll",
        type=Path,
        default=Path("alexnet/cpp/build/libalexnet_golden_dpi.dll"),
    )
    parser.add_argument("--device", default="cuda")
    parser.add_argument("--limit", type=int, default=500)
    parser.add_argument("--offset", type=int, default=0)
    parser.add_argument("--report", type=Path)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    device = torch.device(args.device)
    if device.type == "cuda" and not torch.cuda.is_available():
        raise RuntimeError("CUDA was requested but is unavailable")

    fp32_model, weights = create_alexnet(pretrained=True)
    assert weights is not None
    fp32_model.eval().to(device)
    quantized = load_quantized_alexnet(args.model_manifest)
    dataset = CalibrationImages(
        args.image_dir, args.image_list, weights.transforms(), args.limit, args.offset
    )
    target_map = load_imagenet_validation_targets(args.devkit)
    library, dll_handles = configure_library(args.dll.resolve())

    counters = {
        "fp32_top1": 0,
        "fp32_top5": 0,
        "int8_top1": 0,
        "int8_top5": 0,
        "top1_agreement": 0,
    }
    records = []
    started = time.perf_counter()
    for index in range(len(dataset)):
        image, name = dataset[index]
        target = target_map[name]
        batch = image.unsqueeze(0)
        with torch.inference_mode():
            fp32_logits = fp32_model(batch.to(device))[0].detach().cpu()
        input_int8 = quantize_activation(batch, quantized.input_scale).contiguous()
        int8_logits, _ = run_cpp_alexnet(library, input_int8, quantized)
        int8_logits = int8_logits[0]

        fp32_top5 = fp32_logits.topk(5).indices.tolist()
        int8_top5 = int8_logits.topk(5).indices.tolist()
        fp32_top1 = int(fp32_logits.argmax())
        int8_top1 = int(int8_logits.argmax())
        counters["fp32_top1"] += int(fp32_top1 == target)
        counters["fp32_top5"] += int(target in fp32_top5)
        counters["int8_top1"] += int(int8_top1 == target)
        counters["int8_top5"] += int(target in int8_top5)
        counters["top1_agreement"] += int(fp32_top1 == int8_top1)
        records.append(
            {
                "image": name,
                "target": target,
                "fp32_top1": fp32_top1,
                "int8_top1": int8_top1,
            }
        )
        if (index + 1) % 10 == 0 or index + 1 == len(dataset):
            print(f"evaluated {index + 1}/{len(dataset)}", flush=True)

    count = len(dataset)
    metrics = {
        name: {"correct": value, "percent": 100.0 * value / count}
        for name, value in counters.items()
    }
    report = {
        "status": "pass",
        "note": (
            "FP32 and exported C++ INT8 were evaluated with the same deterministic "
            "preprocessing and ordered image list."
        ),
        "model_manifest_sha256": sha256_file(args.model_manifest),
        "image_list_sha256": sha256_file(args.image_list),
        "image_count": count,
        "offset": args.offset,
        "elapsed_seconds": time.perf_counter() - started,
        "metrics": metrics,
        "images": records,
    }
    report_path = args.report or (args.model_manifest.parent / "accuracy_report.json")
    report_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(metrics, indent=2))
    print(f"accuracy report: {report_path}")
    _ = dll_handles


if __name__ == "__main__":
    main()
