"""Merge disjoint INT8 accuracy-worker reports with duplicate checks."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("reports", nargs="+", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--expected-count", type=int)
    parser.add_argument("--model-manifest", type=Path)
    parser.add_argument("--image-list", type=Path)
    parser.add_argument("--note")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    reports = [json.loads(path.read_text(encoding="utf-8")) for path in args.reports]
    images = [record for report in reports for record in report["images"]]
    names = [record["image"] for record in images]
    if len(names) != len(set(names)):
        raise RuntimeError("accuracy reports contain duplicate images")
    if args.expected_count is not None and len(images) != args.expected_count:
        raise RuntimeError(
            f"expected {args.expected_count} images, merged {len(images)}"
        )

    metric_names = tuple(reports[0]["metrics"])
    for report in reports[1:]:
        if tuple(report["metrics"]) != metric_names:
            raise RuntimeError("accuracy workers reported different metric sets")
    for hash_key in ("model_manifest_sha256", "image_list_sha256"):
        values = {report[hash_key] for report in reports if hash_key in report}
        if len(values) > 1:
            raise RuntimeError(f"accuracy workers disagree on {hash_key}")
    metrics = {}
    for name in metric_names:
        correct = sum(report["metrics"][name]["correct"] for report in reports)
        metrics[name] = {
            "correct": correct,
            "percent": 100.0 * correct / len(images),
        }
    merged = {
        "status": "pass",
        "note": args.note or reports[0]["note"],
        "image_count": len(images),
        "worker_count": len(reports),
        "worker_elapsed_seconds_sum": sum(
            report["elapsed_seconds"] for report in reports
        ),
        "metrics": metrics,
        "images": sorted(images, key=lambda record: record["image"]),
    }
    if args.model_manifest is not None:
        merged["model_manifest_sha256"] = sha256_file(args.model_manifest)
    if args.image_list is not None:
        merged["image_list_sha256"] = sha256_file(args.image_list)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(merged, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(metrics, indent=2))
    print(f"merged accuracy report: {args.output}")


if __name__ == "__main__":
    main()
