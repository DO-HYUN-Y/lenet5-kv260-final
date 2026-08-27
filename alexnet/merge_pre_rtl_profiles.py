"""Merge disjoint pre-RTL profile worker reports."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from .profile_pre_rtl import COUNTER_KEYS, finalize_layer


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("reports", nargs="+", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--expected-count", type=int, required=True)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    workers = [json.loads(path.read_text(encoding="utf-8")) for path in args.reports]
    images = [name for worker in workers for name in worker["images"]]
    if len(images) != args.expected_count or len(images) != len(set(images)):
        raise RuntimeError("profile image count or disjointness check failed")
    first = workers[0]
    for worker in workers[1:]:
        if worker["model_manifest_sha256"] != first["model_manifest_sha256"]:
            raise RuntimeError("profile workers used different models")
        if worker["image_list_sha256"] != first["image_list_sha256"]:
            raise RuntimeError("profile workers used different image lists")
        if worker["static_layers"] != first["static_layers"]:
            raise RuntimeError("profile workers disagree on static layer data")

    raw_layers = {}
    layers = {}
    for name, static in first["static_layers"].items():
        records = [worker["raw_layers"][name] for worker in workers]
        merged = {
            "op": records[0]["op"],
            "accumulator_min": min(record["accumulator_min"] for record in records),
            "accumulator_max": max(record["accumulator_max"] for record in records),
            "post_bias_min": min(record["post_bias_min"] for record in records),
            "post_bias_max": max(record["post_bias_max"] for record in records),
        }
        merged.update({key: sum(record[key] for record in records) for key in COUNTER_KEYS})
        raw_layers[name] = merged
        layers[name] = finalize_layer(merged, static["weight_shape"][0])

    report = {
        "status": "pass",
        "model_manifest_sha256": first["model_manifest_sha256"],
        "image_list_sha256": first["image_list_sha256"],
        "image_count": len(images),
        "worker_count": len(workers),
        "worker_elapsed_seconds_sum": sum(
            worker["elapsed_seconds"] for worker in workers
        ),
        "images": sorted(images),
        "static_layers": first["static_layers"],
        "raw_layers": raw_layers,
        "layers": layers,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(f"merged pre-RTL profile: {args.output}")


if __name__ == "__main__":
    main()
