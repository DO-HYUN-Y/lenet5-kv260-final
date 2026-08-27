"""Compare every exported Python INT8 AlexNet tensor with the C++ golden DLL."""

from __future__ import annotations

import argparse
import ctypes
import json
import os
from pathlib import Path
import shutil
import time

import numpy as np
import torch

from .int8_reference import QuantizedLayer, load_quantized_alexnet


I8P = ctypes.POINTER(ctypes.c_int8)
I32P = ctypes.POINTER(ctypes.c_int32)
U8P = ctypes.POINTER(ctypes.c_uint8)


def pointer(tensor: torch.Tensor, pointer_type: type[ctypes._Pointer]):
    if tensor.device.type != "cpu" or not tensor.is_contiguous():
        raise ValueError("C ABI tensor must be contiguous on CPU")
    return ctypes.cast(tensor.data_ptr(), pointer_type)


def configure_library(path: Path) -> tuple[ctypes.CDLL, list[object]]:
    handles: list[object] = []
    if os.name == "nt":
        handles.append(os.add_dll_directory(str(path.parent)))
        compiler = shutil.which("g++")
        if compiler:
            handles.append(os.add_dll_directory(str(Path(compiler).resolve().parent)))
    library = ctypes.CDLL(str(path))
    library.alexnet_golden_conv2d_int8.argtypes = [
        I8P, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_int,
        I8P, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_int,
        ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_int,
        ctypes.c_int, ctypes.c_int, I32P, I32P, U8P, ctypes.c_uint8,
        I8P, ctypes.c_int,
    ]
    library.alexnet_golden_conv2d_int8.restype = ctypes.c_int
    library.alexnet_golden_linear_int8.argtypes = [
        I8P, ctypes.c_int, ctypes.c_int, I8P, ctypes.c_int,
        I32P, I32P, U8P, ctypes.c_uint8, I8P, ctypes.c_int,
    ]
    library.alexnet_golden_linear_int8.restype = ctypes.c_int
    library.alexnet_golden_maxpool2d.argtypes = [
        I8P, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_int,
        ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_int,
        ctypes.c_int, ctypes.c_int, I8P, ctypes.c_int,
    ]
    library.alexnet_golden_maxpool2d.restype = ctypes.c_int
    return library, handles


def output_dim(input_size: int, kernel: int, stride: int, padding: int) -> int:
    return (input_size + 2 * padding - kernel) // stride + 1


def cpp_conv(library: ctypes.CDLL, value: torch.Tensor, layer: QuantizedLayer) -> torch.Tensor:
    batch, input_channels, input_h, input_w = value.shape
    output_channels, channels_per_group, kernel_h, kernel_w = layer.weight.shape
    output_h = output_dim(input_h, kernel_h, layer.stride[0], layer.padding[0])
    output_w = output_dim(input_w, kernel_w, layer.stride[1], layer.padding[1])
    output = torch.empty(
        (batch, output_channels, output_h, output_w), dtype=torch.int8
    ).contiguous()
    status = library.alexnet_golden_conv2d_int8(
        pointer(value, I8P), batch, input_channels, input_h, input_w,
        pointer(layer.weight, I8P), output_channels, channels_per_group,
        kernel_h, kernel_w, layer.groups, layer.stride[0], layer.stride[1],
        layer.padding[0], layer.padding[1], layer.dilation[0], layer.dilation[1],
        pointer(layer.bias, I32P), pointer(layer.multiplier, I32P),
        pointer(layer.right_shift, U8P), int(layer.relu), pointer(output, I8P),
        output.numel(),
    )
    if status != 0:
        raise RuntimeError(f"C++ {layer.name} returned status {status}")
    return output


def cpp_pool(library: ctypes.CDLL, value: torch.Tensor) -> torch.Tensor:
    batch, channels, input_h, input_w = value.shape
    output_h = output_dim(input_h, 3, 2, 0)
    output_w = output_dim(input_w, 3, 2, 0)
    output = torch.empty((batch, channels, output_h, output_w), dtype=torch.int8)
    status = library.alexnet_golden_maxpool2d(
        pointer(value, I8P), batch, channels, input_h, input_w,
        3, 3, 2, 2, 0, 0, pointer(output, I8P), output.numel(),
    )
    if status != 0:
        raise RuntimeError(f"C++ MaxPool returned status {status}")
    return output


def cpp_linear(library: ctypes.CDLL, value: torch.Tensor, layer: QuantizedLayer) -> torch.Tensor:
    batch, k_depth = value.shape
    n_count = layer.weight.shape[0]
    output = torch.empty((batch, n_count), dtype=torch.int8)
    status = library.alexnet_golden_linear_int8(
        pointer(value, I8P), batch, k_depth, pointer(layer.weight, I8P), n_count,
        pointer(layer.bias, I32P), pointer(layer.multiplier, I32P),
        pointer(layer.right_shift, U8P), int(layer.relu), pointer(output, I8P),
        output.numel(),
    )
    if status != 0:
        raise RuntimeError(f"C++ {layer.name} returned status {status}")
    return output


def run_cpp_alexnet(
    library: ctypes.CDLL,
    input_tensor: torch.Tensor,
    quantized,
    capture: bool = False,
) -> tuple[torch.Tensor, dict[str, torch.Tensor]]:
    """Run the complete integer graph through the compiled C++ golden model."""

    value = input_tensor.contiguous()
    outputs: dict[str, torch.Tensor] = {"input": value} if capture else {}
    for name in ("conv1", "conv2", "conv3", "conv4", "conv5"):
        value = cpp_conv(library, value, quantized.layers[name])
        if capture:
            outputs[name] = value
        if name in {"conv1", "conv2", "conv5"}:
            value = cpp_pool(library, value)
            if capture:
                pool_name = {
                    "conv1": "pool1", "conv2": "pool2", "conv5": "pool5"
                }[name]
                outputs[pool_name] = value
    value = value.flatten(1).contiguous()
    for name in ("fc6", "fc7", "fc8"):
        value = cpp_linear(library, value, quantized.layers[name])
        if capture:
            outputs[name] = value
    return value, outputs


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model-manifest", type=Path, required=True)
    parser.add_argument("--vector-dir", type=Path, required=True)
    parser.add_argument(
        "--dll",
        type=Path,
        default=Path("alexnet/cpp/build/libalexnet_golden_dpi.dll"),
    )
    parser.add_argument("--report", type=Path)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    quantized = load_quantized_alexnet(args.model_manifest)
    vector_manifest = json.loads(
        (args.vector_dir / "manifest.json").read_text(encoding="utf-8")
    )["tensors"]

    def expected(name: str) -> torch.Tensor:
        record = vector_manifest[name]
        array = np.fromfile(args.vector_dir / record["file"], dtype=np.int8).copy()
        return torch.from_numpy(array).reshape(record["shape"]).contiguous()

    library, dll_handles = configure_library(args.dll.resolve())
    value = expected("input")
    results = []
    started = time.perf_counter()

    def compare(name: str, actual: torch.Tensor) -> None:
        reference = expected(name)
        mismatch = int(torch.count_nonzero(actual != reference))
        results.append(
            {"layer": name, "shape": list(actual.shape), "mismatch_count": mismatch}
        )
        if mismatch:
            raise AssertionError(f"{name}: {mismatch} C++/Python byte mismatches")
        print(f"{name:6s} exact-match {list(actual.shape)}", flush=True)

    for name in ("conv1", "conv2", "conv3", "conv4", "conv5"):
        value = cpp_conv(library, value, quantized.layers[name])
        compare(name, value)
        if name in {"conv1", "conv2", "conv5"}:
            value = cpp_pool(library, value)
            pool_name = {"conv1": "pool1", "conv2": "pool2", "conv5": "pool5"}[name]
            compare(pool_name, value)
    value = value.flatten(1).contiguous()
    for name in ("fc6", "fc7", "fc8"):
        value = cpp_linear(library, value, quantized.layers[name])
        compare(name, value)

    report = {
        "status": "pass",
        "model_manifest": str(args.model_manifest),
        "vector_dir": str(args.vector_dir),
        "elapsed_seconds": time.perf_counter() - started,
        "layers": results,
    }
    report_path = args.report or (args.vector_dir / "cpp_parity_report.json")
    report_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(f"full-network C++ parity: PASS ({report['elapsed_seconds']:.3f}s)")
    _ = dll_handles  # Keep Windows DLL search handles alive through the final call.


if __name__ == "__main__":
    main()
