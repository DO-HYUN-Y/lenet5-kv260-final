"""Collect exact integer dynamic ranges and zero-skip statistics before RTL."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import time
from typing import Any

import torch
import torch.nn.functional as functional
from torchvision.models import AlexNet_Weights

from .calibrate_int8 import CalibrationImages
from .compare_full_int8_cpp import (
    configure_library,
    cpp_conv_accumulate,
    cpp_linear_accumulate,
    cpp_pool,
)
from .int8_reference import load_quantized_alexnet, quantize_activation, requantize_int8


COUNTER_KEYS = (
    "image_count",
    "input_elements",
    "input_zero_count",
    "output_elements",
    "output_zero_count",
    "output_minus128_count",
    "output_plus127_count",
    "window_tokens",
    "valid_window_tokens",
    "valid_window_zero_count",
    "padding_window_tokens",
    "valid_packed_pairs",
    "packed_pair_both_zero_count",
    "valid_m32_vectors",
    "m32_all_zero_count",
    "valid_4x4_blocks",
    "block_4x4_all_zero_count",
    "valid_kernel_rows",
    "kernel_row_all_zero_count",
    "valid_windows",
    "full_window_all_zero_count",
)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def new_raw_layer(op: str) -> dict[str, Any]:
    result: dict[str, Any] = {
        "op": op,
        "accumulator_min": None,
        "accumulator_max": None,
        "post_bias_min": None,
        "post_bias_max": None,
    }
    result.update({key: 0 for key in COUNTER_KEYS})
    return result


def update_extrema(record: dict[str, Any], key: str, value: int) -> None:
    current = record[key]
    if current is None:
        record[key] = value
    elif key.endswith("_min"):
        record[key] = min(current, value)
    else:
        record[key] = max(current, value)


def update_activation_counts(
    record: dict[str, Any], input_tensor: torch.Tensor, output_tensor: torch.Tensor
) -> None:
    record["image_count"] += int(input_tensor.shape[0])
    record["input_elements"] += input_tensor.numel()
    record["input_zero_count"] += int(torch.count_nonzero(input_tensor == 0))
    record["output_elements"] += output_tensor.numel()
    record["output_zero_count"] += int(torch.count_nonzero(output_tensor == 0))
    record["output_minus128_count"] += int(
        torch.count_nonzero(output_tensor == -128)
    )
    record["output_plus127_count"] += int(
        torch.count_nonzero(output_tensor == 127)
    )


def update_accumulator_counts(
    record: dict[str, Any], accumulators: torch.Tensor, bias: torch.Tensor
) -> None:
    update_extrema(record, "accumulator_min", int(accumulators.min()))
    update_extrema(record, "accumulator_max", int(accumulators.max()))
    shape = (1, -1) + (1,) * (accumulators.ndim - 2)
    post_bias = accumulators.to(torch.int64) + bias.to(torch.int64).reshape(shape)
    update_extrema(record, "post_bias_min", int(post_bias.min()))
    update_extrema(record, "post_bias_max", int(post_bias.max()))


def update_window_counts(
    record: dict[str, Any], value: torch.Tensor, layer
) -> None:
    if value.shape[0] != 1 or layer.groups != 1:
        raise ValueError("pre-RTL window profiling currently requires N=1 and groups=1")
    kernel = tuple(layer.weight.shape[-2:])
    columns = functional.unfold(
        value.to(torch.float32), kernel, dilation=layer.dilation,
        padding=layer.padding, stride=layer.stride
    )[0]
    valid = functional.unfold(
        torch.ones_like(value, dtype=torch.float32), kernel,
        dilation=layer.dilation, padding=layer.padding, stride=layer.stride
    )[0].to(torch.bool)
    zeros = columns == 0
    record["window_tokens"] += columns.numel()
    record["valid_window_tokens"] += int(valid.sum())
    record["valid_window_zero_count"] += int(torch.count_nonzero(valid & zeros))
    record["padding_window_tokens"] += int(torch.count_nonzero(~valid))

    k_depth, m_count = columns.shape
    channels = value.shape[1]
    kernel_h, kernel_w = kernel
    row_valid_elements = valid.reshape(channels, kernel_h, kernel_w, m_count).permute(
        1, 2, 0, 3
    )
    row_zero_elements = zeros.reshape(channels, kernel_h, kernel_w, m_count).permute(
        1, 2, 0, 3
    )
    row_valid = row_valid_elements.any(dim=(1, 2))
    row_zero = torch.where(
        row_valid_elements, row_zero_elements, torch.ones_like(row_zero_elements)
    ).all(dim=(1, 2))
    record["valid_kernel_rows"] += int(row_valid.sum())
    record["kernel_row_all_zero_count"] += int(
        torch.count_nonzero(row_valid & row_zero)
    )

    paired_m = (m_count // 2) * 2
    if paired_m:
        pair_valid = valid[:, :paired_m].reshape(k_depth, -1, 2).all(dim=2)
        pair_zero = zeros[:, :paired_m].reshape(k_depth, -1, 2).all(dim=2)
        record["valid_packed_pairs"] += int(pair_valid.sum())
        record["packed_pair_both_zero_count"] += int(
            torch.count_nonzero(pair_valid & pair_zero)
        )

    m32_count = m_count // 32
    if m32_count:
        cropped = m32_count * 32
        vector_valid = valid[:, :cropped].reshape(k_depth, m32_count, 32).all(dim=2)
        vector_zero = zeros[:, :cropped].reshape(k_depth, m32_count, 32).all(dim=2)
        record["valid_m32_vectors"] += int(vector_valid.sum())
        record["m32_all_zero_count"] += int(
            torch.count_nonzero(vector_valid & vector_zero)
        )

    k4 = (k_depth // 4) * 4
    m4 = (m_count // 4) * 4
    if k4 and m4:
        block_valid = valid[:k4, :m4].reshape(k4 // 4, 4, m4 // 4, 4).all(
            dim=(1, 3)
        )
        block_zero = zeros[:k4, :m4].reshape(k4 // 4, 4, m4 // 4, 4).all(
            dim=(1, 3)
        )
        record["valid_4x4_blocks"] += int(block_valid.sum())
        record["block_4x4_all_zero_count"] += int(
            torch.count_nonzero(block_valid & block_zero)
        )

    valid_windows = valid.any(dim=0)
    zero_windows = torch.where(valid, zeros, torch.ones_like(zeros)).all(dim=0)
    record["valid_windows"] += int(valid_windows.sum())
    record["full_window_all_zero_count"] += int(
        torch.count_nonzero(valid_windows & zero_windows)
    )


def required_signed_bits(minimum: int, maximum: int) -> int:
    for bits in range(1, 65):
        if minimum >= -(1 << (bits - 1)) and maximum <= (1 << (bits - 1)) - 1:
            return bits
    raise OverflowError("range exceeds signed 64-bit width")


def percentage(numerator: int, denominator: int) -> float | None:
    return 100.0 * numerator / denominator if denominator else None


def finalize_layer(record: dict[str, Any], output_channels: int) -> dict[str, Any]:
    result = dict(record)
    result["accumulator_required_signed_bits"] = required_signed_bits(
        record["accumulator_min"], record["accumulator_max"]
    )
    result["post_bias_required_signed_bits"] = required_signed_bits(
        record["post_bias_min"], record["post_bias_max"]
    )
    result["input_zero_percent"] = percentage(
        record["input_zero_count"], record["input_elements"]
    )
    result["output_zero_percent"] = percentage(
        record["output_zero_count"], record["output_elements"]
    )
    result["output_minus128_percent"] = percentage(
        record["output_minus128_count"], record["output_elements"]
    )
    result["output_plus127_percent"] = percentage(
        record["output_plus127_count"], record["output_elements"]
    )
    result["valid_window_zero_percent"] = percentage(
        record["valid_window_zero_count"], record["valid_window_tokens"]
    )
    result["padding_window_token_percent"] = percentage(
        record["padding_window_tokens"], record["window_tokens"]
    )
    result["packed_pair_both_zero_percent"] = percentage(
        record["packed_pair_both_zero_count"], record["valid_packed_pairs"]
    )
    result["m32_all_zero_percent"] = percentage(
        record["m32_all_zero_count"], record["valid_m32_vectors"]
    )
    result["block_4x4_all_zero_percent"] = percentage(
        record["block_4x4_all_zero_count"], record["valid_4x4_blocks"]
    )
    result["kernel_row_all_zero_percent"] = percentage(
        record["kernel_row_all_zero_count"], record["valid_kernel_rows"]
    )
    result["full_window_all_zero_percent"] = percentage(
        record["full_window_all_zero_count"], record["valid_windows"]
    )
    result["rs_valid_operand_reuse_per_input"] = (
        record["valid_window_tokens"] / record["input_elements"]
        if record["input_elements"] and record["window_tokens"] else None
    )
    result["output_positions_per_image"] = (
        record["output_elements"] / output_channels / record["image_count"]
    )
    return result


def static_layer_record(layer) -> dict[str, Any]:
    weight = layer.weight
    flat_weight = weight.reshape(weight.shape[0], -1)
    worst_accumulator_min: int | None = None
    worst_accumulator_max: int | None = None
    worst_post_bias_min: int | None = None
    worst_post_bias_max: int | None = None
    # Do not expand FC6's 36 MiB INT8 weight tensor into several full INT64
    # temporaries. The identities below are exact and keep worker memory bounded:
    # max = 127*sum(w) - 255*sum(w<0), min = -128*sum(w) + 255*sum(w<0).
    for start in range(0, flat_weight.shape[0], 128):
        stop = min(start + 128, flat_weight.shape[0])
        chunk = flat_weight[start:stop]
        weight_sum = chunk.sum(dim=1, dtype=torch.int64)
        negative_sum = chunk.clamp_max(0).sum(dim=1, dtype=torch.int64)
        accumulator_max = 127 * weight_sum - 255 * negative_sum
        accumulator_min = -128 * weight_sum + 255 * negative_sum
        bias = layer.bias[start:stop].to(torch.int64)
        post_bias_max = accumulator_max + bias
        post_bias_min = accumulator_min + bias
        chunk_values = (
            int(accumulator_min.min()), int(accumulator_max.max()),
            int(post_bias_min.min()), int(post_bias_max.max())
        )
        worst_accumulator_min = (
            chunk_values[0] if worst_accumulator_min is None
            else min(worst_accumulator_min, chunk_values[0])
        )
        worst_accumulator_max = (
            chunk_values[1] if worst_accumulator_max is None
            else max(worst_accumulator_max, chunk_values[1])
        )
        worst_post_bias_min = (
            chunk_values[2] if worst_post_bias_min is None
            else min(worst_post_bias_min, chunk_values[2])
        )
        worst_post_bias_max = (
            chunk_values[3] if worst_post_bias_max is None
            else max(worst_post_bias_max, chunk_values[3])
        )
    assert worst_accumulator_min is not None and worst_accumulator_max is not None
    assert worst_post_bias_min is not None and worst_post_bias_max is not None
    weight_zero_count = int(torch.count_nonzero(weight == 0))
    return {
        "op": layer.op,
        "weight_shape": list(weight.shape),
        "weight_elements": weight.numel(),
        "weight_zero_count": weight_zero_count,
        "weight_zero_percent": percentage(
            weight_zero_count, weight.numel()
        ),
        "weight_min": int(weight.min()),
        "weight_max": int(weight.max()),
        "bias_min": int(layer.bias.min()),
        "bias_max": int(layer.bias.max()),
        "multiplier_min": int(layer.multiplier.min()),
        "multiplier_max": int(layer.multiplier.max()),
        "right_shift_min": int(layer.right_shift.min()),
        "right_shift_max": int(layer.right_shift.max()),
        "all_int8_input_accumulator_min": worst_accumulator_min,
        "all_int8_input_accumulator_max": worst_accumulator_max,
        "all_int8_input_accumulator_required_signed_bits": required_signed_bits(
            worst_accumulator_min, worst_accumulator_max
        ),
        "all_int8_input_post_bias_min": worst_post_bias_min,
        "all_int8_input_post_bias_max": worst_post_bias_max,
        "all_int8_input_post_bias_required_signed_bits": required_signed_bits(
            worst_post_bias_min, worst_post_bias_max
        ),
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model-manifest", type=Path, required=True)
    parser.add_argument("--image-dir", type=Path, required=True)
    parser.add_argument("--image-list", type=Path, required=True)
    parser.add_argument("--dll", type=Path, required=True)
    parser.add_argument("--limit", type=int, default=1000)
    parser.add_argument("--offset", type=int, default=0)
    parser.add_argument("--report", type=Path, required=True)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    quantized = load_quantized_alexnet(args.model_manifest)
    dataset = CalibrationImages(
        args.image_dir, args.image_list, AlexNet_Weights.IMAGENET1K_V1.transforms(),
        args.limit, args.offset
    )
    library, dll_handles = configure_library(args.dll.resolve())
    raw_layers = {
        name: new_raw_layer(layer.op) for name, layer in quantized.layers.items()
    }
    static_layers = {
        name: static_layer_record(layer) for name, layer in quantized.layers.items()
    }
    image_names: list[str] = []
    started = time.perf_counter()

    for index in range(len(dataset)):
        image, image_name = dataset[index]
        image_names.append(image_name)
        value = quantize_activation(image.unsqueeze(0), quantized.input_scale).contiguous()
        for name in ("conv1", "conv2", "conv3", "conv4", "conv5"):
            layer = quantized.layers[name]
            record = raw_layers[name]
            update_window_counts(record, value, layer)
            accumulators = cpp_conv_accumulate(library, value, layer)
            output = requantize_int8(accumulators, layer).contiguous()
            update_accumulator_counts(record, accumulators, layer.bias)
            update_activation_counts(record, value, output)
            value = output
            if name in {"conv1", "conv2", "conv5"}:
                value = cpp_pool(library, value)

        value = value.flatten(1).contiguous()
        for name in ("fc6", "fc7", "fc8"):
            layer = quantized.layers[name]
            record = raw_layers[name]
            accumulators = cpp_linear_accumulate(library, value, layer)
            output = requantize_int8(accumulators, layer).contiguous()
            update_accumulator_counts(record, accumulators, layer.bias)
            update_activation_counts(record, value, output)
            value = output
        if (index + 1) % 10 == 0 or index + 1 == len(dataset):
            print(f"profiled {index + 1}/{len(dataset)}", flush=True)

    report = {
        "status": "pass",
        "model_manifest_sha256": sha256_file(args.model_manifest),
        "image_list_sha256": sha256_file(args.image_list),
        "offset": args.offset,
        "image_count": len(dataset),
        "elapsed_seconds": time.perf_counter() - started,
        "images": image_names,
        "static_layers": static_layers,
        "raw_layers": raw_layers,
        "layers": {
            name: finalize_layer(raw_layers[name], layer.weight.shape[0])
            for name, layer in quantized.layers.items()
        },
    }
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(f"pre-RTL profile: {args.report}")
    _ = dll_handles


if __name__ == "__main__":
    main()
