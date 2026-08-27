"""Calibrate and export the signed-INT8 AlexNet reference."""

from __future__ import annotations

import argparse
from collections import OrderedDict
import hashlib
import io
import json
from pathlib import Path
import tarfile
from typing import Callable

from PIL import Image
import torch
from torch import Tensor, nn
from torch.utils.data import DataLoader, Dataset
from scipy.io import loadmat

from .int8_reference import (
    build_quantized_alexnet,
    export_integer_vectors,
    export_quantized_alexnet,
    run_integer_alexnet,
)
from .model import AlexNet, create_alexnet


MLPERF_LIST_URL = (
    "https://raw.githubusercontent.com/mlcommons/inference/master/"
    "calibration/ImageNet/cal_image_list_option_1.txt"
)
MLPERF_LIST_SHA256 = "7662247d1d9407d6cb564268f64c5a4a6cf9f1a34fd2e6cdc3b94dcf278b3dc9"
CHECKPOINT_SHA256 = "7be5be791159472b1fbf3c69796f7cb30dca7ad8466c2df70058c37116cdee02"
IMAGENET_DEVKIT_MD5 = "fa75699e90414af021442c21a62c3abf"


class CalibrationImages(Dataset[tuple[Tensor, str]]):
    def __init__(
        self,
        image_dir: Path,
        list_path: Path,
        transform: Callable[[Image.Image], Tensor],
        limit: int,
        offset: int = 0,
    ) -> None:
        names = [line.strip() for line in list_path.read_text().splitlines() if line.strip()]
        if offset < 0:
            raise ValueError("dataset offset must be non-negative")
        names = names[offset:]
        if limit > 0:
            names = names[:limit]
        missing = [name for name in names if not (image_dir / name).is_file()]
        if missing:
            raise FileNotFoundError(
                f"{len(missing)} calibration images are missing; first={missing[0]}"
            )
        self.image_dir = image_dir
        self.names = names
        self.transform = transform

    def __len__(self) -> int:
        return len(self.names)

    def __getitem__(self, index: int) -> tuple[Tensor, str]:
        name = self.names[index]
        with Image.open(self.image_dir / name) as image:
            tensor = self.transform(image.convert("RGB"))
        return tensor, name


class ActivationSampler:
    """Keep a deterministic uniform sample of large activation tensors."""

    def __init__(self, values_per_batch: int = 65_536) -> None:
        self.values_per_batch = values_per_batch
        self.chunks: list[Tensor] = []
        self.observed_absmax = 0.0

    def add(self, values: Tensor) -> None:
        flat = values.detach().abs().flatten()
        self.observed_absmax = max(self.observed_absmax, float(flat.max()))
        step = max(1, flat.numel() // self.values_per_batch)
        sample = flat[::step][: self.values_per_batch].to("cpu", torch.float32)
        self.chunks.append(sample)

    def finish(self, percentile: float) -> tuple[float, dict[str, float | int]]:
        if not self.chunks:
            raise RuntimeError("activation sampler did not receive values")
        values = torch.cat(self.chunks)
        threshold = float(torch.quantile(values, percentile / 100.0))
        threshold = max(threshold, torch.finfo(torch.float32).eps)
        return threshold / 127.0, {
            "sampled_values": values.numel(),
            "observed_absmax": self.observed_absmax,
            "percentile_absmax": threshold,
        }


CALIBRATION_HOOKS: "OrderedDict[str, Callable[[AlexNet], nn.Module]]" = OrderedDict(
    [
        ("conv1", lambda model: model.features[1]),
        ("conv2", lambda model: model.features[4]),
        ("conv3", lambda model: model.features[7]),
        ("conv4", lambda model: model.features[9]),
        ("conv5", lambda model: model.features[11]),
        ("fc6", lambda model: model.classifier[2]),
        ("fc7", lambda model: model.classifier[5]),
        ("fc8", lambda model: model.classifier[6]),
    ]
)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def dataset_digest(image_dir: Path, names: list[str]) -> str:
    digest = hashlib.sha256()
    for name in names:
        digest.update(name.encode("utf-8") + b"\0")
        digest.update(bytes.fromhex(sha256_file(image_dir / name)))
    return digest.hexdigest()


def load_imagenet_validation_targets(devkit_path: Path) -> dict[str, int]:
    """Map official validation filenames to torchvision's sorted-WNID indices."""

    with tarfile.open(devkit_path, "r:gz") as archive:
        meta_member = archive.extractfile("ILSVRC2012_devkit_t12/data/meta.mat")
        truth_member = archive.extractfile(
            "ILSVRC2012_devkit_t12/data/ILSVRC2012_validation_ground_truth.txt"
        )
        if meta_member is None or truth_member is None:
            raise RuntimeError("ImageNet devkit is missing metadata")
        meta = loadmat(io.BytesIO(meta_member.read()), squeeze_me=True)["synsets"]
        ground_truth = [int(line) for line in truth_member.read().decode().splitlines()]
    leaf_records = [record for record in meta if int(record[4]) == 0]
    id_to_wnid = {int(record[0]): str(record[1]) for record in leaf_records}
    sorted_wnids = sorted(id_to_wnid.values())
    wnid_to_class = {wnid: index for index, wnid in enumerate(sorted_wnids)}
    return {
        f"ILSVRC2012_val_{index:08d}.JPEG": wnid_to_class[id_to_wnid[label_id]]
        for index, label_id in enumerate(ground_truth, start=1)
    }


def collect_activation_scales(
    model: AlexNet,
    loader: DataLoader[tuple[Tensor, tuple[str, ...]]],
    device: torch.device,
    percentile: float,
) -> tuple[dict[str, float], dict[str, dict[str, float | int]]]:
    samplers = {"input": ActivationSampler()}
    samplers.update({name: ActivationSampler() for name in CALIBRATION_HOOKS})
    handles = []
    for name, accessor in CALIBRATION_HOOKS.items():
        def hook(
            _module: nn.Module,
            _inputs: tuple[Tensor, ...],
            output: Tensor,
            *,
            key: str = name,
        ) -> None:
            samplers[key].add(output)

        handles.append(accessor(model).register_forward_hook(hook))

    try:
        with torch.inference_mode():
            for batch_index, (images, _names) in enumerate(loader, start=1):
                images = images.to(device, non_blocking=True)
                samplers["input"].add(images)
                model(images)
                print(f"calibration batch {batch_index}/{len(loader)}", flush=True)
    finally:
        for handle in handles:
            handle.remove()

    scales: dict[str, float] = {}
    statistics: dict[str, dict[str, float | int]] = {}
    for name, sampler in samplers.items():
        scales[name], statistics[name] = sampler.finish(percentile)
    return scales, statistics


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--image-dir", type=Path, required=True)
    parser.add_argument("--calibration-list", type=Path, required=True)
    parser.add_argument(
        "--devkit",
        type=Path,
        help="optional official ILSVRC2012 devkit used to attach ground-truth labels",
    )
    parser.add_argument("--output-dir", type=Path, default=Path("alexnet_output/int8"))
    parser.add_argument(
        "--contract-output",
        type=Path,
        help="optional source-controlled JSON copy of all fixed quantization values",
    )
    parser.add_argument("--device", default="cuda")
    parser.add_argument("--batch-size", type=int, default=32)
    parser.add_argument("--workers", type=int, default=0)
    parser.add_argument("--limit", type=int, default=500)
    parser.add_argument("--percentile", type=float, default=100.0)
    parser.add_argument("--vector-count", type=int, default=1)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    if not 0 < args.percentile <= 100:
        raise ValueError("--percentile must be in (0, 100]")
    if sha256_file(args.calibration_list) != MLPERF_LIST_SHA256:
        raise RuntimeError("MLCommons calibration list SHA-256 mismatch")

    device = torch.device(args.device)
    if device.type == "cuda" and not torch.cuda.is_available():
        raise RuntimeError("CUDA was requested but is unavailable")
    model, weights = create_alexnet(pretrained=True)
    assert weights is not None
    model.eval().to(device)
    dataset = CalibrationImages(
        args.image_dir, args.calibration_list, weights.transforms(), args.limit
    )
    loader = DataLoader(
        dataset,
        batch_size=args.batch_size,
        shuffle=False,
        num_workers=args.workers,
        pin_memory=device.type == "cuda",
    )

    scales, statistics = collect_activation_scales(
        model, loader, device, args.percentile
    )
    quantized = build_quantized_alexnet(model, scales)
    selected_names = dataset.names
    targets = (
        load_imagenet_validation_targets(args.devkit) if args.devkit is not None else {}
    )
    calibration_metadata = {
        "model": "torchvision AlexNet_Weights.IMAGENET1K_V1",
        "checkpoint_sha256": CHECKPOINT_SHA256,
        "dataset": "ILSVRC2012 validation / MLCommons option 1",
        "source_list_url": MLPERF_LIST_URL,
        "source_list_sha256": MLPERF_LIST_SHA256,
        "image_count": len(dataset),
        "image_set_sha256": dataset_digest(args.image_dir, selected_names),
        "percentile": args.percentile,
        "sampling": "deterministic_uniform_stride_up_to_65536_values_per_batch_layer",
        "activation_scales": scales,
        "activation_statistics": statistics,
        "torch": torch.__version__,
        "device": str(device),
    }
    if args.devkit is not None:
        calibration_metadata["devkit_md5"] = hashlib.md5(
            args.devkit.read_bytes()
        ).hexdigest()
        if calibration_metadata["devkit_md5"] != IMAGENET_DEVKIT_MD5:
            raise RuntimeError("ImageNet devkit MD5 mismatch")
    manifest_path = export_quantized_alexnet(
        quantized, args.output_dir, calibration_metadata
    )
    if args.contract_output is not None:
        exported_manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        contract_layers = {}
        for name, layer in quantized.layers.items():
            exported = exported_manifest["layers"][name]
            contract_layers[name] = {
                "op": layer.op,
                "weight_shape": list(layer.weight.shape),
                "weight_sha256": exported["weight_sha256"],
                "parameter_sha256": exported["parameter_sha256"],
                "input_scale": layer.input_scale,
                "output_scale": layer.output_scale,
                "weight_scale_per_output_channel": layer.weight_scale.tolist(),
                "bias_int32_per_output_channel": layer.bias.tolist(),
                "multiplier_int32_per_output_channel": layer.multiplier.tolist(),
                "right_shift_per_output_channel": layer.right_shift.tolist(),
                "relu": layer.relu,
                "stride": list(layer.stride),
                "padding": list(layer.padding),
                "dilation": list(layer.dilation),
                "groups": layer.groups,
            }
        contract = {
            "format_version": 1,
            "numeric_contract": exported_manifest["numeric_contract"],
            "parameter_record": "little_endian_<iiBB6x>_16_bytes_per_output_channel",
            "input_scale": quantized.input_scale,
            "calibration": calibration_metadata,
            "layers": contract_layers,
        }
        args.contract_output.parent.mkdir(parents=True, exist_ok=True)
        with args.contract_output.open("w", encoding="utf-8", newline="\n") as stream:
            stream.write(json.dumps(contract, indent=2) + "\n")
        print(f"quantization contract: {args.contract_output}")

    vector_reports = []
    for index in range(min(args.vector_count, len(dataset))):
        input_tensor, name = dataset[index]
        input_tensor = input_tensor.unsqueeze(0)
        outputs = run_integer_alexnet(quantized, input_tensor, device)
        vector_dir = args.output_dir / "vectors" / f"{index:04d}_{Path(name).stem}"
        export_integer_vectors(outputs, vector_dir)
        with torch.inference_mode():
            fp32_top1 = int(model(input_tensor.to(device)).argmax(dim=1)[0])
        int8_top1 = int(outputs["fc8"].argmax(dim=1)[0])
        report = {
            "source_image": name,
            "source_sha256": sha256_file(args.image_dir / name),
            "target": targets.get(name),
            "fp32_top1": fp32_top1,
            "int8_top1": int8_top1,
            "top1_agreement": fp32_top1 == int8_top1,
            "fp32_top1_correct": (
                fp32_top1 == targets[name] if name in targets else None
            ),
            "int8_top1_correct": (
                int8_top1 == targets[name] if name in targets else None
            ),
        }
        (vector_dir / "source.json").write_text(
            json.dumps(report, indent=2) + "\n", encoding="utf-8"
        )
        vector_reports.append(report)
        print(f"vector {index}: {name} fp32={fp32_top1} int8={int8_top1}")

    summary_path = args.output_dir / "calibration_report.json"
    summary_path.write_text(
        json.dumps(
            {
                "status": "pass",
                "manifest": manifest_path.name,
                "vectors": vector_reports,
                **calibration_metadata,
            },
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )
    print(f"exported INT8 model: {manifest_path}")
    print(f"calibration report: {summary_path}")


if __name__ == "__main__":
    main()
