"""Verify ImageNet validation data and extract the MLCommons 500-image subset."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import shutil
import tarfile
import urllib.request

from .calibrate_int8 import MLPERF_LIST_SHA256, MLPERF_LIST_URL, dataset_digest


IMAGENET_VAL_BYTES = 6_744_924_160
IMAGENET_VAL_MD5 = "29b22e2961454d5413ddabcf34fc5622"


def file_digest(path: Path, algorithm: str) -> str:
    digest = hashlib.new(algorithm)
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(4 * 1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", type=Path, required=True)
    parser.add_argument(
        "--list",
        type=Path,
        default=Path("data/imagenet/cal_image_list_option_1.txt"),
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=Path("data/imagenet/calibration_mlcommons_option1"),
    )
    parser.add_argument("--skip-archive-md5", action="store_true")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    if not args.archive.is_file():
        raise FileNotFoundError(args.archive)
    if args.archive.stat().st_size != IMAGENET_VAL_BYTES:
        raise RuntimeError("ImageNet validation archive byte count mismatch")
    if not args.skip_archive_md5:
        print("verifying 6.28 GiB ImageNet archive MD5...", flush=True)
        if file_digest(args.archive, "md5") != IMAGENET_VAL_MD5:
            raise RuntimeError("ImageNet validation archive MD5 mismatch")

    args.list.parent.mkdir(parents=True, exist_ok=True)
    if not args.list.is_file():
        urllib.request.urlretrieve(MLPERF_LIST_URL, args.list)
    if file_digest(args.list, "sha256") != MLPERF_LIST_SHA256:
        raise RuntimeError("MLCommons calibration list SHA-256 mismatch")
    names = [line.strip() for line in args.list.read_text().splitlines() if line.strip()]
    if len(names) != 500 or len(set(names)) != 500:
        raise RuntimeError("MLCommons calibration list must contain 500 unique names")

    wanted = set(names)
    args.output_dir.mkdir(parents=True, exist_ok=True)
    extracted = set()
    with tarfile.open(args.archive, "r") as archive:
        for member in archive:
            name = Path(member.name).name
            if name not in wanted or not member.isfile():
                continue
            source = archive.extractfile(member)
            if source is None:
                raise RuntimeError(f"could not read {member.name}")
            with source, (args.output_dir / name).open("wb") as destination:
                shutil.copyfileobj(source, destination)
            extracted.add(name)
    missing = wanted.difference(extracted)
    if missing:
        raise RuntimeError(f"archive is missing {len(missing)} requested images")

    manifest = {
        "dataset": "ILSVRC2012 validation / MLCommons calibration option 1",
        "archive": args.archive.name,
        "archive_bytes": args.archive.stat().st_size,
        "archive_md5": IMAGENET_VAL_MD5,
        "list_url": MLPERF_LIST_URL,
        "list_sha256": MLPERF_LIST_SHA256,
        "image_count": len(names),
        "ordered_image_set_sha256": dataset_digest(args.output_dir, names),
    }
    manifest_path = args.output_dir / "dataset_manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(f"prepared calibration dataset: {args.output_dir} ({len(names)} images)")
    print(f"dataset manifest: {manifest_path}")


if __name__ == "__main__":
    main()
