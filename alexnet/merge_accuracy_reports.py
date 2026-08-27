"""Merge disjoint INT8 accuracy-worker reports with duplicate checks."""

from __future__ import annotations

import argparse
import json
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("reports", nargs="+", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--expected-count", type=int)
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
    metrics = {}
    for name in metric_names:
        correct = sum(report["metrics"][name]["correct"] for report in reports)
        metrics[name] = {
            "correct": correct,
            "percent": 100.0 * correct / len(images),
        }
    merged = {
        "status": "pass",
        "note": reports[0]["note"],
        "image_count": len(images),
        "worker_count": len(reports),
        "worker_elapsed_seconds_sum": sum(
            report["elapsed_seconds"] for report in reports
        ),
        "metrics": metrics,
        "images": sorted(images, key=lambda record: record["image"]),
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(merged, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(metrics, indent=2))
    print(f"merged accuracy report: {args.output}")


if __name__ == "__main__":
    main()
