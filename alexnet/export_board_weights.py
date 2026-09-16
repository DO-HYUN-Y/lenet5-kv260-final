"""Recreate the frozen INT8 AlexNet files and pack the KV260 DDR images.

The checked-in calibration contract already contains the activation scales and
the expected hash of every logical layer weight/parameter file. Consequently,
the large ImageNet calibration set is not needed for this export: only the
official torchvision FP32 checkpoint is downloaded (or supplied explicitly).
"""

from __future__ import annotations

import argparse
from collections import OrderedDict
import hashlib
import json
from pathlib import Path
import struct
from typing import BinaryIO
from urllib.parse import urlparse

import torch

from .int8_reference import LAYER_ORDER, QuantizedLayer, build_quantized_alexnet
from .model import create_alexnet


DEFAULT_CONTRACT = Path("alexnet/calibration/int8_mlcommons500_contract.json")
DEFAULT_OUTPUT = Path("alexnet_output/int8_mlcommons500_board")
CHECKPOINT_URL = "https://download.pytorch.org/models/alexnet-owt-7be5be79.pth"

WEIGHT_OFFSETS = OrderedDict(
    (
        ("conv1", 0),
        ("conv2", 23_232),
        ("conv3", 330_432),
        ("conv4", 993_984),
        ("conv5", 1_878_720),
        ("fc6", 2_468_544),
        ("fc7", 40_217_280),
        ("fc8", 56_994_496),
    )
)
PARAMETER_OFFSETS = OrderedDict(
    (
        ("conv1", 0),
        ("conv2", 1_024),
        ("conv3", 4_096),
        ("conv4", 10_240),
        ("conv5", 14_336),
        ("fc6", 18_432),
        ("fc7", 83_968),
        ("fc8", 149_504),
    )
)
EXPECTED_LOGICAL_WEIGHT_BYTES = 61_090_496
EXPECTED_WEIGHT_BYTES = 61_123_264
EXPECTED_PARAMETER_BYTES = 165_504

CONV_OUTPUT_TILE = {
    "conv1": 64,
    "conv2": 64,
    "conv3": 112,
    "conv4": 112,
    "conv5": 112,
}
FC_OUTPUT_TILE = 16


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def parameter_bytes(layer: QuantizedLayer) -> bytes:
    result = bytearray()
    for bias, multiplier, shift in zip(
        layer.bias.tolist(), layer.multiplier.tolist(), layer.right_shift.tolist()
    ):
        result.extend(
            struct.pack("<iiBB6x", bias, multiplier, shift, int(layer.relu))
        )
    return bytes(result)


def packed_conv_chunks(layer: QuantizedLayer, output_tile: int | None = None):
    """Yield scheduler tiles in `[N tile][K][enabled N16 bank]` order."""

    weight = layer.weight
    output_channels, input_channels, _kernel_h, _kernel_w = weight.shape
    tile = output_tile if output_tile is not None else CONV_OUTPUT_TILE[layer.name]
    if tile % 16 or output_channels % 16:
        raise ValueError(f"{layer.name} convolution output is not N16 aligned")
    for output_base in range(0, output_channels, tile):
        output_count = min(tile, output_channels - output_base)
        if output_count % 16:
            raise ValueError(f"{layer.name} convolution tail is not N16 aligned")
        # OIHW -> HWI(N). K is [ky][kx][input_channel], and the final
        # dimension is emitted as ascending N16 banks for each K value.
        yield (
            weight[output_base : output_base + output_count, :, :, :]
            .permute(2, 3, 1, 0)
            .contiguous()
            .numpy()
            .tobytes()
        )


def packed_fc_chunks(layer: QuantizedLayer):
    """Yield `[N16 tile][K][N lane]`, zero-padding the final N tail."""

    weight = layer.weight
    output_channels, input_features = weight.shape
    if output_channels % 8:
        raise ValueError(f"{layer.name} output channels are not N8 aligned")
    for output_base in range(0, output_channels, FC_OUTPUT_TILE):
        output_count = min(FC_OUTPUT_TILE, output_channels - output_base)
        physical = torch.zeros(
            (FC_OUTPUT_TILE, input_features), dtype=weight.dtype
        )
        physical[:output_count, :] = weight[
            output_base : output_base + output_count, :
        ]
        yield physical.transpose(0, 1).contiguous().numpy().tobytes()


def write_packed_layer(stream: BinaryIO, layer: QuantizedLayer) -> tuple[int, str]:
    digest = hashlib.sha256()
    byte_count = 0
    chunks = (
        packed_conv_chunks(layer) if layer.op == "conv2d" else packed_fc_chunks(layer)
    )
    for chunk in chunks:
        stream.write(chunk)
        digest.update(chunk)
        byte_count += len(chunk)
    return byte_count, digest.hexdigest()


def load_model(checkpoint: Path | None):
    if checkpoint is None:
        model, weights = create_alexnet(pretrained=True)
        assert weights is not None
        checkpoint_name = Path(urlparse(str(weights.url)).path).name
        checkpoint_path = Path(torch.hub.get_dir()) / "checkpoints" / checkpoint_name
        return model, checkpoint_path, list(weights.meta["categories"])

    model, _ = create_alexnet(pretrained=False)
    state_dict = torch.load(checkpoint, map_location="cpu", weights_only=True)
    model.load_state_dict(state_dict, strict=True)
    from torchvision.models import AlexNet_Weights

    categories = list(AlexNet_Weights.IMAGENET1K_V1.meta["categories"])
    return model, checkpoint, categories


def compare_layer_contract(
    name: str,
    layer: QuantizedLayer,
    record: dict,
    logical_weight: bytes,
    parameters: bytes,
) -> None:
    comparisons = {
        "weight_shape": list(layer.weight.shape),
        "weight_scale_per_output_channel": layer.weight_scale.tolist(),
        "bias_int32_per_output_channel": layer.bias.tolist(),
        "multiplier_int32_per_output_channel": layer.multiplier.tolist(),
        "right_shift_per_output_channel": layer.right_shift.tolist(),
        "input_scale": layer.input_scale,
        "output_scale": layer.output_scale,
        "relu": layer.relu,
        "stride": list(layer.stride),
        "padding": list(layer.padding),
        "dilation": list(layer.dilation),
        "groups": layer.groups,
    }
    for field, actual in comparisons.items():
        if actual != record[field]:
            raise RuntimeError(f"{name} contract mismatch in {field}")
    if sha256_bytes(logical_weight) != record["weight_sha256"]:
        raise RuntimeError(f"{name} logical weight SHA-256 mismatch")
    if sha256_bytes(parameters) != record["parameter_sha256"]:
        raise RuntimeError(f"{name} parameter SHA-256 mismatch")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--contract", type=Path, default=DEFAULT_CONTRACT)
    parser.add_argument("--output-dir", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument(
        "--checkpoint",
        type=Path,
        help="optional local official checkpoint; otherwise torchvision downloads it",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    contract = json.loads(args.contract.read_text(encoding="utf-8"))
    if tuple(contract["layers"]) != LAYER_ORDER:
        raise RuntimeError("contract layer order does not match the RTL layer order")
    if contract["multiplier_storage_bits"] != 18:
        raise RuntimeError("the M4xN8 RTL requires the frozen signed-18 multiplier")

    model, checkpoint_path, categories = load_model(args.checkpoint)
    checkpoint_hash = sha256_file(checkpoint_path)
    expected_checkpoint_hash = contract["calibration"]["checkpoint_sha256"]
    if checkpoint_hash != expected_checkpoint_hash:
        raise RuntimeError(
            f"checkpoint SHA-256 mismatch: {checkpoint_hash} != "
            f"{expected_checkpoint_hash}"
        )

    quantized = build_quantized_alexnet(
        model,
        contract["calibration"]["activation_scales"],
        contract["multiplier_storage_bits"],
    )
    del model

    output_dir = args.output_dir
    logical_dir = output_dir / "logical_weights_oihw_nk"
    parameter_dir = output_dir / "layer_parameters"
    logical_dir.mkdir(parents=True, exist_ok=True)
    parameter_dir.mkdir(parents=True, exist_ok=True)
    board_weight_path = output_dir / "weights_board.bin"
    board_parameter_path = output_dir / "parameters_board.bin"

    layer_manifest = OrderedDict()
    parameter_blob = bytearray()
    with board_weight_path.open("wb") as board_weights:
        for name in LAYER_ORDER:
            layer = quantized.layers[name]
            contract_record = contract["layers"][name]
            logical_weight = layer.weight.numpy().tobytes()
            parameters = parameter_bytes(layer)
            compare_layer_contract(
                name, layer, contract_record, logical_weight, parameters
            )

            logical_path = logical_dir / f"{name}.bin"
            parameter_path = parameter_dir / f"{name}.bin"
            logical_path.write_bytes(logical_weight)
            parameter_path.write_bytes(parameters)

            if board_weights.tell() != WEIGHT_OFFSETS[name]:
                raise RuntimeError(
                    f"{name} weight offset {board_weights.tell()} does not match "
                    f"RTL offset {WEIGHT_OFFSETS[name]}"
                )
            if len(parameter_blob) != PARAMETER_OFFSETS[name]:
                raise RuntimeError(
                    f"{name} parameter offset {len(parameter_blob)} does not match "
                    f"RTL offset {PARAMETER_OFFSETS[name]}"
                )

            packed_bytes, packed_hash = write_packed_layer(board_weights, layer)
            if name != "fc8" and packed_bytes != len(logical_weight):
                raise RuntimeError(f"{name} packed weight byte count changed")
            if name == "fc8" and packed_bytes - len(logical_weight) != 32_768:
                raise RuntimeError("fc8 N16 tail padding byte count changed")
            parameter_blob.extend(parameters)
            layer_manifest[name] = {
                "layer_id": LAYER_ORDER.index(name) + 1,
                "shape": list(layer.weight.shape),
                "logical_layout": "OIHW" if layer.op == "conv2d" else "NK",
                "logical_file": logical_path.relative_to(output_dir).as_posix(),
                "logical_sha256": contract_record["weight_sha256"],
                "weight_offset": WEIGHT_OFFSETS[name],
                "weight_bytes": packed_bytes,
                "logical_weight_bytes": len(logical_weight),
                "output_tile_channels": (
                    CONV_OUTPUT_TILE[name]
                    if layer.op == "conv2d"
                    else FC_OUTPUT_TILE
                ),
                "packed_sha256": packed_hash,
                "parameter_file": parameter_path.relative_to(output_dir).as_posix(),
                "parameter_offset": PARAMETER_OFFSETS[name],
                "parameter_bytes": len(parameters),
                "parameter_sha256": contract_record["parameter_sha256"],
            }

    board_parameter_path.write_bytes(parameter_blob)
    if sum(layer.weight.numel() for layer in quantized.layers.values()) != (
        EXPECTED_LOGICAL_WEIGHT_BYTES
    ):
        raise RuntimeError("logical weight byte count does not match AlexNet")
    if board_weight_path.stat().st_size != EXPECTED_WEIGHT_BYTES:
        raise RuntimeError("board weight image size does not match the RTL planner")
    if board_parameter_path.stat().st_size != EXPECTED_PARAMETER_BYTES:
        raise RuntimeError("board parameter image size does not match the RTL planner")
    # Blob bases are 128-byte aligned. Layer offsets remain contiguous; every
    # current N128 service transfer is a whole 128-bit N16 beat.
    if board_weight_path.stat().st_size % 16 or board_parameter_path.stat().st_size % 8:
        raise RuntimeError("board images violate their stream word alignment")

    manifest = {
        "format_version": 2,
        "source": "torchvision AlexNet_Weights.IMAGENET1K_V1",
        "source_url": CHECKPOINT_URL,
        "checkpoint_file": checkpoint_path.name,
        "checkpoint_sha256": checkpoint_hash,
        "quantization_contract": args.contract.as_posix(),
        "quantization_contract_sha256": sha256_file(args.contract),
        "input_scale": quantized.input_scale,
        "output_scale": quantized.layers["fc8"].output_scale,
        "categories": categories,
        "logical_weight_layout": "OIHW_for_conv_NK_for_linear",
        "board_weight_layout": {
            "conv": "layer_scheduler_Ntile_K_enabled_N16bank_Nlane",
            "fc": "layer_N16tile_K_Nlane_zero_padded_tail",
            "axis_word": "sixteen_signed_int8_N_lanes_little_endian",
        },
        "parameter_layout": "layer_output_channel_little_endian_<iiBB6x>",
        "weights": {
            "file": board_weight_path.name,
            "bytes": board_weight_path.stat().st_size,
            "sha256": sha256_file(board_weight_path),
        },
        "parameters": {
            "file": board_parameter_path.name,
            "bytes": board_parameter_path.stat().st_size,
            "sha256": sha256_file(board_parameter_path),
        },
        "layers": layer_manifest,
    }
    manifest_path = output_dir / "board_manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")

    print(f"checkpoint verified: {checkpoint_path}")
    print(
        f"board weights: {board_weight_path} "
        f"bytes={manifest['weights']['bytes']} sha256={manifest['weights']['sha256']}"
    )
    print(
        f"board parameters: {board_parameter_path} "
        f"bytes={manifest['parameters']['bytes']} "
        f"sha256={manifest['parameters']['sha256']}"
    )
    print(f"board manifest: {manifest_path}")
    print("ALEXNET_BOARD_WEIGHT_EXPORT_PASS")


if __name__ == "__main__":
    main()
