#!/usr/bin/env python3
"""Regenerate and verify trained full-graph C++ layer-boundary vectors."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile


REPO_ROOT = Path(__file__).resolve().parents[3]


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--executable",
        type=Path,
        default=REPO_ROOT
        / "alexnet/cpp/build-release/alexnet_board_full_graph_golden",
    )
    parser.add_argument(
        "--board-dir",
        type=Path,
        default=REPO_ROOT / "alexnet_output/int8_mlcommons500_board",
    )
    parser.add_argument(
        "--contract",
        type=Path,
        default=REPO_ROOT
        / "alexnet/cpp/vectors/full_graph_pattern_v1.json",
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        help="keep generated .bin vectors here instead of a temporary directory",
    )
    return parser.parse_args()


def verify(args: argparse.Namespace, output_dir: Path) -> None:
    contract = json.loads(args.contract.read_text(encoding="utf-8"))
    model_manifest = args.board_dir / "board_manifest.json"
    actual_model_hash = sha256(model_manifest)
    expected_model_hash = contract["model_manifest_sha256"]
    if actual_model_hash != expected_model_hash:
        raise RuntimeError(
            "board model manifest SHA-256 mismatch: "
            f"{actual_model_hash} != {expected_model_hash}"
        )

    subprocess.run(
        [str(args.executable), str(args.board_dir), str(output_dir)],
        check=True,
    )

    for name, record in contract["vectors"].items():
        path = output_dir / name
        actual_bytes = path.stat().st_size
        actual_hash = sha256(path)
        if actual_bytes != int(record["bytes"]):
            raise RuntimeError(
                f"{name}: byte count {actual_bytes} != {record['bytes']}"
            )
        if actual_hash != record["sha256"]:
            raise RuntimeError(
                f"{name}: SHA-256 {actual_hash} != {record['sha256']}"
            )
        print(f"{name:12s} exact {actual_bytes:6d} bytes {actual_hash}")

    print(
        "ALEXNET_BOARD_FULL_GRAPH_GOLDEN_VERIFY_PASS "
        f"boundaries={len(contract['vectors']) - 1}"
    )


def main() -> None:
    args = parse_args()
    args.executable = args.executable.resolve()
    args.board_dir = args.board_dir.resolve()
    args.contract = args.contract.resolve()
    if args.output_dir is not None:
        args.output_dir.mkdir(parents=True, exist_ok=True)
        verify(args, args.output_dir.resolve())
    else:
        with tempfile.TemporaryDirectory(prefix="alexnet_full_graph_") as temp:
            verify(args, Path(temp))


if __name__ == "__main__":
    main()
