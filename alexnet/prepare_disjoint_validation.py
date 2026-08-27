"""Create a deterministic class-balanced ImageNet subset disjoint from calibration."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import shutil
import tarfile

from .calibrate_int8 import dataset_digest, load_imagenet_validation_targets
from .prepare_calibration_data import (
    IMAGENET_VAL_BYTES,
    IMAGENET_VAL_MD5,
    file_digest,
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", type=Path, required=True)
    parser.add_argument("--devkit", type=Path, required=True)
    parser.add_argument("--exclude-list", type=Path, required=True)
    parser.add_argument("--per-class", type=int, default=5)
    parser.add_argument("--seed", default="alexnet-pre-rtl-v1")
    parser.add_argument(
        "--selection-list",
        type=Path,
        default=Path("alexnet/calibration/imagenet_disjoint_balanced_5000.txt"),
    )
    parser.add_argument(
        "--profile-list",
        type=Path,
        default=Path("alexnet/calibration/imagenet_profile_balanced_1000.txt"),
        help="one selected image per class for dynamic pre-RTL profiling",
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=Path("data/imagenet/validation_disjoint_balanced_5000"),
    )
    parser.add_argument("--skip-archive-md5", action="store_true")
    return parser.parse_args()


def selection_score(seed: str, name: str) -> bytes:
    return hashlib.sha256(f"{seed}\0{name}".encode("utf-8")).digest()


def main() -> None:
    args = parse_args()
    if args.per_class <= 0:
        raise ValueError("--per-class must be positive")
    if not args.archive.is_file() or args.archive.stat().st_size != IMAGENET_VAL_BYTES:
        raise RuntimeError("ImageNet validation archive byte count mismatch")
    if not args.skip_archive_md5:
        print("verifying ImageNet validation archive MD5...", flush=True)
        if file_digest(args.archive, "md5") != IMAGENET_VAL_MD5:
            raise RuntimeError("ImageNet validation archive MD5 mismatch")

    target_map = load_imagenet_validation_targets(args.devkit)
    excluded = {
        line.strip()
        for line in args.exclude_list.read_text(encoding="utf-8").splitlines()
        if line.strip()
    }
    by_class: dict[int, list[str]] = {class_index: [] for class_index in range(1000)}
    for name, class_index in target_map.items():
        if name not in excluded:
            by_class[class_index].append(name)

    selected: list[str] = []
    for class_index in range(1000):
        candidates = sorted(
            by_class[class_index], key=lambda name: (selection_score(args.seed, name), name)
        )
        if len(candidates) < args.per_class:
            raise RuntimeError(f"class {class_index} has too few disjoint images")
        selected.extend(candidates[: args.per_class])
    if excluded.intersection(selected):
        raise RuntimeError("selected validation images overlap calibration")

    args.selection_list.parent.mkdir(parents=True, exist_ok=True)
    with args.selection_list.open("w", encoding="utf-8", newline="\n") as stream:
        stream.write("\n".join(selected) + "\n")
    profile_names = [selected[index * args.per_class] for index in range(1000)]
    args.profile_list.parent.mkdir(parents=True, exist_ok=True)
    with args.profile_list.open("w", encoding="utf-8", newline="\n") as stream:
        stream.write("\n".join(profile_names) + "\n")

    wanted = set(selected)
    args.output_dir.mkdir(parents=True, exist_ok=True)
    extracted: set[str] = set()
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
        raise RuntimeError(f"archive is missing {len(missing)} selected images")

    manifest = {
        "dataset": "ILSVRC2012 validation deterministic balanced disjoint subset",
        "selection_algorithm": "lowest_sha256(seed + NUL + filename) per class",
        "seed": args.seed,
        "per_class": args.per_class,
        "class_count": 1000,
        "image_count": len(selected),
        "calibration_overlap_count": 0,
        "archive_md5": IMAGENET_VAL_MD5,
        "exclude_list_sha256": file_digest(args.exclude_list, "sha256"),
        "selection_list_sha256": file_digest(args.selection_list, "sha256"),
        "profile_list_sha256": file_digest(args.profile_list, "sha256"),
        "profile_image_count": len(profile_names),
        "ordered_image_set_sha256": dataset_digest(args.output_dir, selected),
    }
    manifest_path = args.output_dir / "dataset_manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(f"selected validation subset: {len(selected)} images, 0 overlap")
    print(f"selection list: {args.selection_list}")
    print(f"profile list: {args.profile_list}")
    print(f"dataset manifest: {manifest_path}")


if __name__ == "__main__":
    main()
