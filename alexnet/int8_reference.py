"""Integer AlexNet reference shared by calibration, export, and parity tests."""

from __future__ import annotations

from collections import OrderedDict
from dataclasses import dataclass
import hashlib
import json
import math
from pathlib import Path
import struct
from typing import Any

import numpy as np
import torch
import torch.nn.functional as functional
from torch import nn

from .model import AlexNet


CONV_ACCESSORS = OrderedDict(
    [
        ("conv1", lambda model: model.features[0]),
        ("conv2", lambda model: model.features[3]),
        ("conv3", lambda model: model.features[6]),
        ("conv4", lambda model: model.features[8]),
        ("conv5", lambda model: model.features[10]),
    ]
)
LINEAR_ACCESSORS = OrderedDict(
    [
        ("fc6", lambda model: model.classifier[1]),
        ("fc7", lambda model: model.classifier[4]),
        ("fc8", lambda model: model.classifier[6]),
    ]
)
RELU_LAYERS = frozenset({"conv1", "conv2", "conv3", "conv4", "conv5", "fc6", "fc7"})
LAYER_ORDER = tuple(CONV_ACCESSORS) + tuple(LINEAR_ACCESSORS)


@dataclass
class QuantizedLayer:
    name: str
    op: str
    weight: torch.Tensor
    weight_scale: torch.Tensor
    bias: torch.Tensor
    multiplier: torch.Tensor
    right_shift: torch.Tensor
    input_scale: float
    output_scale: float
    relu: bool
    stride: tuple[int, int] = (1, 1)
    padding: tuple[int, int] = (0, 0)
    dilation: tuple[int, int] = (1, 1)
    groups: int = 1


@dataclass
class QuantizedAlexNet:
    input_scale: float
    layers: "OrderedDict[str, QuantizedLayer]"


def round_half_away_from_zero(values: torch.Tensor) -> torch.Tensor:
    """Round floating values with the same tie rule used by the RTL contract."""

    return torch.where(values < 0, torch.ceil(values - 0.5), torch.floor(values + 0.5))


def quantize_activation(values: torch.Tensor, scale: float) -> torch.Tensor:
    if not scale > 0:
        raise ValueError("activation scale must be positive")
    quantized = round_half_away_from_zero(values / scale)
    return quantized.clamp(-128, 127).to(torch.int8)


def _checked_int32(values: torch.Tensor, context: str) -> torch.Tensor:
    minimum = int(values.min())
    maximum = int(values.max())
    if minimum < -(1 << 31) or maximum > (1 << 31) - 1:
        raise OverflowError(
            f"{context} is outside signed INT32: min={minimum}, max={maximum}"
        )
    return values.to(torch.int32)


def _fixed_point_multiplier(real_multiplier: float) -> tuple[int, int]:
    """Approximate a positive real multiplier as integer / 2**right_shift."""

    if not real_multiplier >= 0:
        raise ValueError("real multiplier must be non-negative")
    if real_multiplier == 0:
        return 0, 0
    int32_max = (1 << 31) - 1
    for right_shift in range(62, -1, -1):
        multiplier = int(math.floor(real_multiplier * (1 << right_shift) + 0.5))
        if 0 < multiplier <= int32_max:
            return multiplier, right_shift
    raise OverflowError(f"cannot represent multiplier {real_multiplier}")


def _quantize_layer(
    name: str,
    module: nn.Conv2d | nn.Linear,
    input_scale: float,
    output_scale: float,
) -> QuantizedLayer:
    weight_fp64 = module.weight.detach().cpu().to(torch.float64)
    reduce_dimensions = tuple(range(1, weight_fp64.ndim))
    weight_absmax = weight_fp64.abs().amax(dim=reduce_dimensions)
    weight_scale = torch.where(weight_absmax > 0, weight_absmax / 127.0,
                               torch.ones_like(weight_absmax))
    scale_shape = (weight_fp64.shape[0],) + (1,) * (weight_fp64.ndim - 1)
    weight = round_half_away_from_zero(
        weight_fp64 / weight_scale.reshape(scale_shape)
    ).clamp(-127, 127).to(torch.int8)

    if module.bias is None:
        bias_fp64 = torch.zeros(weight_fp64.shape[0], dtype=torch.float64)
    else:
        bias_fp64 = module.bias.detach().cpu().to(torch.float64)
    bias_rounded = round_half_away_from_zero(
        bias_fp64 / (input_scale * weight_scale)
    )
    bias = _checked_int32(bias_rounded, f"{name} quantized bias")

    multipliers = []
    shifts = []
    for channel_scale in weight_scale.tolist():
        multiplier, shift = _fixed_point_multiplier(
            input_scale * float(channel_scale) / output_scale
        )
        multipliers.append(multiplier)
        shifts.append(shift)

    common: dict[str, Any] = {
        "name": name,
        "op": "conv2d" if isinstance(module, nn.Conv2d) else "linear",
        "weight": weight.contiguous(),
        "weight_scale": weight_scale.contiguous(),
        "bias": bias.contiguous(),
        "multiplier": torch.tensor(multipliers, dtype=torch.int32),
        "right_shift": torch.tensor(shifts, dtype=torch.uint8),
        "input_scale": input_scale,
        "output_scale": output_scale,
        "relu": name in RELU_LAYERS,
    }
    if isinstance(module, nn.Conv2d):
        common.update(
            stride=tuple(module.stride),
            padding=tuple(module.padding),
            dilation=tuple(module.dilation),
            groups=module.groups,
        )
    return QuantizedLayer(**common)


def build_quantized_alexnet(
    model: AlexNet, activation_scales: dict[str, float]
) -> QuantizedAlexNet:
    required = {
        "input", "conv1", "conv2", "conv3", "conv4", "conv5",
        "fc6", "fc7", "fc8",
    }
    missing = required.difference(activation_scales)
    if missing:
        raise ValueError(f"missing activation scales: {sorted(missing)}")

    layers: "OrderedDict[str, QuantizedLayer]" = OrderedDict()
    input_scale = float(activation_scales["input"])
    previous_scale = input_scale
    for name, accessor in CONV_ACCESSORS.items():
        output_scale = float(activation_scales[name])
        layers[name] = _quantize_layer(
            name, accessor(model), previous_scale, output_scale
        )
        previous_scale = output_scale
    for name, accessor in LINEAR_ACCESSORS.items():
        output_scale = float(activation_scales[name])
        layers[name] = _quantize_layer(
            name, accessor(model), previous_scale, output_scale
        )
        previous_scale = output_scale
    return QuantizedAlexNet(input_scale=input_scale, layers=layers)


def _conv_output_dim(
    input_size: int, kernel: int, stride: int, padding: int, dilation: int
) -> int:
    return (input_size + 2 * padding - dilation * (kernel - 1) - 1) // stride + 1


def conv2d_accumulate_int32(input_tensor: torch.Tensor, layer: QuantizedLayer) -> torch.Tensor:
    """Compute exact INT32 Conv using PyTorch unfold and exact FP64 matmul.

    PyTorch CUDA does not expose general INT32 batched matmul. Every AlexNet
    accumulator is far below 2**53, so FP64 represents every integer product
    and sum exactly before the checked conversion to INT32.
    """

    if layer.op != "conv2d" or input_tensor.dtype != torch.int8:
        raise ValueError("conv2d reference requires an INT8 Conv layer")
    batch, input_channels, input_h, input_w = input_tensor.shape
    output_channels, channels_per_group, kernel_h, kernel_w = layer.weight.shape
    output_h = _conv_output_dim(
        input_h, kernel_h, layer.stride[0], layer.padding[0], layer.dilation[0]
    )
    output_w = _conv_output_dim(
        input_w, kernel_w, layer.stride[1], layer.padding[1], layer.dilation[1]
    )
    columns = functional.unfold(
        input_tensor.to(torch.float64),
        (kernel_h, kernel_w),
        dilation=layer.dilation,
        padding=layer.padding,
        stride=layer.stride,
    )
    outputs = []
    output_channels_per_group = output_channels // layer.groups
    k_per_group = channels_per_group * kernel_h * kernel_w
    weight = layer.weight.to(device=input_tensor.device, dtype=torch.float64)
    for group in range(layer.groups):
        column_begin = group * k_per_group
        output_begin = group * output_channels_per_group
        group_columns = columns[:, column_begin:column_begin + k_per_group, :]
        group_weights = weight[
            output_begin:output_begin + output_channels_per_group
        ].reshape(output_channels_per_group, k_per_group)
        group_weights = group_weights.unsqueeze(0).expand(batch, -1, -1)
        outputs.append(torch.matmul(group_weights, group_columns))
    output = torch.cat(outputs, dim=1)
    return _checked_int32(output, f"{layer.name} accumulator").reshape(
        batch, output_channels, output_h, output_w
    )


def requantize_int8(accumulators: torch.Tensor, layer: QuantizedLayer) -> torch.Tensor:
    channel_shape = (1, -1) + (1,) * (accumulators.ndim - 2)
    bias = layer.bias.to(accumulators.device, torch.int64).reshape(channel_shape)
    multiplier = layer.multiplier.to(accumulators.device, torch.int64).reshape(channel_shape)
    shift = layer.right_shift.to(accumulators.device, torch.int64).reshape(channel_shape)
    product = (accumulators.to(torch.int64) + bias) * multiplier
    magnitude = product.abs()
    rounding = torch.bitwise_left_shift(
        torch.ones_like(shift), torch.clamp(shift - 1, min=0)
    )
    rounded = torch.bitwise_right_shift(magnitude + rounding, shift)
    rounded = torch.where(shift == 0, magnitude, rounded)
    scaled = torch.where(product < 0, -rounded, rounded)
    if layer.relu:
        scaled = scaled.clamp_min(0)
    return scaled.clamp(-128, 127).to(torch.int8)


def linear_accumulate_int32(input_tensor: torch.Tensor, layer: QuantizedLayer) -> torch.Tensor:
    if layer.op != "linear" or input_tensor.dtype != torch.int8:
        raise ValueError("linear reference requires an INT8 Linear layer")
    weight = layer.weight.to(device=input_tensor.device, dtype=torch.float64)
    accumulators = torch.matmul(input_tensor.to(torch.float64), weight.t())
    return _checked_int32(accumulators, f"{layer.name} accumulator")


def run_integer_alexnet(
    quantized: QuantizedAlexNet,
    input_fp32: torch.Tensor,
    device: torch.device | str = "cpu",
) -> "OrderedDict[str, torch.Tensor]":
    """Run the fused Conv/ReLU/Pool/FC integer graph and capture every output."""

    active_device = torch.device(device)
    value = quantize_activation(input_fp32.to(active_device), quantized.input_scale)
    outputs: "OrderedDict[str, torch.Tensor]" = OrderedDict()
    outputs["input"] = value.detach().cpu().contiguous()

    for name in ("conv1", "conv2", "conv3", "conv4", "conv5"):
        layer = quantized.layers[name]
        value = requantize_int8(conv2d_accumulate_int32(value, layer), layer)
        outputs[name] = value.detach().cpu().contiguous()
        if name in {"conv1", "conv2", "conv5"}:
            value = functional.max_pool2d(value.to(torch.float32), 3, 2).to(torch.int8)
            pool_name = {"conv1": "pool1", "conv2": "pool2", "conv5": "pool5"}[name]
            outputs[pool_name] = value.detach().cpu().contiguous()

    value = value.flatten(1)
    for name in ("fc6", "fc7", "fc8"):
        layer = quantized.layers[name]
        value = requantize_int8(linear_accumulate_int32(value, layer), layer)
        outputs[name] = value.detach().cpu().contiguous()
    return outputs


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def export_quantized_alexnet(
    quantized: QuantizedAlexNet,
    output_dir: Path,
    calibration_metadata: dict[str, Any],
) -> Path:
    """Write raw RTL-ready weight/parameter blobs plus a hashed manifest."""

    output_dir.mkdir(parents=True, exist_ok=True)
    weights_dir = output_dir / "weights"
    params_dir = output_dir / "params"
    weights_dir.mkdir(exist_ok=True)
    params_dir.mkdir(exist_ok=True)
    manifest: dict[str, Any] = {
        "format_version": 1,
        "tensor_layout": "NCHW",
        "weight_layout": "OIHW_for_conv_NK_for_linear",
        "numeric_contract": "signed_int8_symmetric_int32_acc_round_half_away",
        "input_scale": quantized.input_scale,
        "calibration": calibration_metadata,
        "layers": {},
    }

    for name, layer in quantized.layers.items():
        weight_path = weights_dir / f"{name}.bin"
        parameter_path = params_dir / f"{name}.bin"
        layer.weight.numpy().tofile(weight_path)
        with parameter_path.open("wb") as stream:
            for bias, multiplier, shift in zip(
                layer.bias.tolist(), layer.multiplier.tolist(), layer.right_shift.tolist()
            ):
                stream.write(struct.pack("<iiBB6x", bias, multiplier, shift, int(layer.relu)))
        manifest["layers"][name] = {
            "op": layer.op,
            "weight_shape": list(layer.weight.shape),
            "weight_file": str(weight_path.relative_to(output_dir)).replace("\\", "/"),
            "weight_sha256": _sha256(weight_path),
            "parameter_file": str(parameter_path.relative_to(output_dir)).replace("\\", "/"),
            "parameter_sha256": _sha256(parameter_path),
            "parameter_count": layer.bias.numel(),
            "input_scale": layer.input_scale,
            "output_scale": layer.output_scale,
            "weight_scale": layer.weight_scale.tolist(),
            "relu": layer.relu,
            "stride": list(layer.stride),
            "padding": list(layer.padding),
            "dilation": list(layer.dilation),
            "groups": layer.groups,
        }
    manifest_path = output_dir / "manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    return manifest_path


def load_quantized_alexnet(manifest_path: Path) -> QuantizedAlexNet:
    """Load a previously exported model and verify every recorded file hash."""

    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    root = manifest_path.parent
    layers: "OrderedDict[str, QuantizedLayer]" = OrderedDict()
    for name in LAYER_ORDER:
        record = manifest["layers"][name]
        weight_path = root / record["weight_file"]
        parameter_path = root / record["parameter_file"]
        if _sha256(weight_path) != record["weight_sha256"]:
            raise RuntimeError(f"{name} weight SHA-256 mismatch")
        if _sha256(parameter_path) != record["parameter_sha256"]:
            raise RuntimeError(f"{name} parameter SHA-256 mismatch")
        weight_array = np.fromfile(weight_path, dtype=np.int8).copy()
        weight = torch.from_numpy(weight_array).reshape(record["weight_shape"])
        parameter_bytes = parameter_path.read_bytes()
        expected_bytes = int(record["parameter_count"]) * 16
        if len(parameter_bytes) != expected_bytes:
            raise RuntimeError(f"{name} parameter byte count mismatch")
        bias = []
        multiplier = []
        right_shift = []
        relu_flags = []
        for offset in range(0, len(parameter_bytes), 16):
            b, m, s, r = struct.unpack_from("<iiBB6x", parameter_bytes, offset)
            bias.append(b)
            multiplier.append(m)
            right_shift.append(s)
            relu_flags.append(bool(r))
        if any(flag != bool(record["relu"]) for flag in relu_flags):
            raise RuntimeError(f"{name} ReLU flag mismatch")
        layers[name] = QuantizedLayer(
            name=name,
            op=record["op"],
            weight=weight.contiguous(),
            weight_scale=torch.tensor(record["weight_scale"], dtype=torch.float64),
            bias=torch.tensor(bias, dtype=torch.int32),
            multiplier=torch.tensor(multiplier, dtype=torch.int32),
            right_shift=torch.tensor(right_shift, dtype=torch.uint8),
            input_scale=float(record["input_scale"]),
            output_scale=float(record["output_scale"]),
            relu=bool(record["relu"]),
            stride=tuple(record["stride"]),
            padding=tuple(record["padding"]),
            dilation=tuple(record["dilation"]),
            groups=int(record["groups"]),
        )
    return QuantizedAlexNet(float(manifest["input_scale"]), layers)


def export_integer_vectors(
    outputs: "OrderedDict[str, torch.Tensor]", output_dir: Path
) -> dict[str, Any]:
    output_dir.mkdir(parents=True, exist_ok=True)
    tensors: dict[str, Any] = {}
    for name, tensor in outputs.items():
        path = output_dir / f"{name}.bin"
        tensor.numpy().tofile(path)
        tensors[name] = {
            "shape": list(tensor.shape),
            "dtype": "int8",
            "file": path.name,
            "sha256": _sha256(path),
        }
    vector_manifest = output_dir / "manifest.json"
    vector_manifest.write_text(
        json.dumps({"format_version": 1, "tensors": tensors}, indent=2) + "\n",
        encoding="utf-8",
    )
    return tensors
