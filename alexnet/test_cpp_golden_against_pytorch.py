"""Cross-check the C++ INT8 golden library against PyTorch operators.

Build ``alexnet/cpp`` first so that ``libalexnet_golden_dpi.dll`` exists.  The
test uses small integer ranges for Conv/Pool so conversion through PyTorch's
floating operator remains mathematically exact; accumulation is compared as
INT32 with no quantization ambiguity.
"""

from __future__ import annotations

import ctypes
import itertools
import os
from pathlib import Path
import random
import shutil
import unittest

import torch
import torch.nn.functional as functional


INT8_POINTER = ctypes.POINTER(ctypes.c_int8)
INT32_POINTER = ctypes.POINTER(ctypes.c_int32)
UINT8_POINTER = ctypes.POINTER(ctypes.c_uint8)


def _pointer(tensor: torch.Tensor, pointer_type: type[ctypes._Pointer]):
    """Return a ctypes pointer to a contiguous CPU tensor."""

    if tensor.device.type != "cpu" or not tensor.is_contiguous():
        raise ValueError("ctypes tensors must be contiguous CPU tensors")
    return ctypes.cast(tensor.data_ptr(), pointer_type)


def _round_half_away(value: int, right_shift: int) -> int:
    if right_shift == 0:
        return value
    magnitude = abs(value)
    rounded = (magnitude + (1 << (right_shift - 1))) >> right_shift
    return -rounded if value < 0 else rounded


class CppGoldenParityTest(unittest.TestCase):
    """Compare architecture-independent integer operators byte-for-byte."""

    @classmethod
    def setUpClass(cls) -> None:
        dll_path = (
            Path(__file__).resolve().parent
            / "cpp"
            / "build"
            / "libalexnet_golden_dpi.dll"
        )
        if not dll_path.is_file():
            raise FileNotFoundError(
                f"{dll_path} does not exist; build alexnet/cpp before this test"
            )
        cls.dll_directory_handles = []
        if os.name == "nt":
            cls.dll_directory_handles.append(os.add_dll_directory(str(dll_path.parent)))
            compiler = shutil.which("g++")
            if compiler is not None:
                cls.dll_directory_handles.append(
                    os.add_dll_directory(str(Path(compiler).resolve().parent))
                )
        cls.library = ctypes.CDLL(str(dll_path))

        cls.library.alexnet_golden_packed_products.argtypes = [
            ctypes.c_int8,
            ctypes.c_int8,
            ctypes.c_int8,
            INT32_POINTER,
            INT32_POINTER,
        ]
        cls.library.alexnet_golden_packed_products.restype = ctypes.c_int
        cls.library.alexnet_golden_requantize.argtypes = [
            ctypes.c_int32,
            ctypes.c_int32,
            ctypes.c_int32,
            ctypes.c_uint8,
            ctypes.c_uint8,
            INT8_POINTER,
        ]
        cls.library.alexnet_golden_requantize.restype = ctypes.c_int
        cls.library.alexnet_golden_conv2d_accumulate.argtypes = [
            INT8_POINTER,
            ctypes.c_int,
            ctypes.c_int,
            ctypes.c_int,
            ctypes.c_int,
            INT8_POINTER,
            ctypes.c_int,
            ctypes.c_int,
            ctypes.c_int,
            ctypes.c_int,
            ctypes.c_int,
            ctypes.c_int,
            ctypes.c_int,
            ctypes.c_int,
            ctypes.c_int,
            ctypes.c_int,
            ctypes.c_int,
            INT32_POINTER,
            ctypes.c_int,
        ]
        cls.library.alexnet_golden_conv2d_accumulate.restype = ctypes.c_int
        cls.library.alexnet_golden_linear_accumulate.argtypes = [
            INT8_POINTER,
            ctypes.c_int,
            ctypes.c_int,
            INT8_POINTER,
            ctypes.c_int,
            INT32_POINTER,
            ctypes.c_int,
        ]
        cls.library.alexnet_golden_linear_accumulate.restype = ctypes.c_int
        cls.library.alexnet_golden_maxpool2d.argtypes = [
            INT8_POINTER,
            ctypes.c_int,
            ctypes.c_int,
            ctypes.c_int,
            ctypes.c_int,
            ctypes.c_int,
            ctypes.c_int,
            ctypes.c_int,
            ctypes.c_int,
            ctypes.c_int,
            ctypes.c_int,
            INT8_POINTER,
            ctypes.c_int,
        ]
        cls.library.alexnet_golden_maxpool2d.restype = ctypes.c_int
        cls.library.alexnet_golden_packed_os_matmul.argtypes = [
            INT8_POINTER,
            ctypes.c_int,
            ctypes.c_int,
            INT8_POINTER,
            ctypes.c_int,
            INT32_POINTER,
            ctypes.c_int,
        ]
        cls.library.alexnet_golden_packed_os_matmul.restype = ctypes.c_int
        cls.library.alexnet_golden_conv2d_int8.argtypes = [
            INT8_POINTER, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_int,
            INT8_POINTER, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_int,
            ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_int,
            ctypes.c_int, ctypes.c_int, INT32_POINTER, INT32_POINTER,
            UINT8_POINTER, ctypes.c_uint8, INT8_POINTER, ctypes.c_int,
        ]
        cls.library.alexnet_golden_conv2d_int8.restype = ctypes.c_int
        cls.library.alexnet_golden_linear_int8.argtypes = [
            INT8_POINTER, ctypes.c_int, ctypes.c_int, INT8_POINTER,
            ctypes.c_int, INT32_POINTER, INT32_POINTER, UINT8_POINTER,
            ctypes.c_uint8, INT8_POINTER, ctypes.c_int,
        ]
        cls.library.alexnet_golden_linear_int8.restype = ctypes.c_int

    def test_packed_products_match_pytorch(self) -> None:
        generator = torch.Generator().manual_seed(1729)
        activations = torch.randint(-128, 128, (4096, 2), dtype=torch.int8,
                                    generator=generator)
        weights = torch.randint(-128, 128, (4096,), dtype=torch.int8,
                                generator=generator)
        expected = activations.to(torch.int32) * weights.to(torch.int32)[:, None]
        for index in range(activations.shape[0]):
            lo = ctypes.c_int32()
            hi = ctypes.c_int32()
            status = self.library.alexnet_golden_packed_products(
                int(activations[index, 0]), int(activations[index, 1]),
                int(weights[index]), ctypes.byref(lo), ctypes.byref(hi)
            )
            self.assertEqual(status, 0)
            self.assertEqual((lo.value, hi.value), tuple(expected[index].tolist()))

    def test_requantization_contract(self) -> None:
        rng = random.Random(20260827)
        directed = [
            (3, 0, 1, 1, False),
            (-3, 0, 1, 1, False),
            (127, 1, 2, 1, False),
            (-128, 0, 3, 0, True),
        ]
        vectors = directed + [
            (
                rng.randint(-1_000_000, 1_000_000),
                rng.randint(-100_000, 100_000),
                rng.randint(0, 20_000),
                rng.randint(0, 24),
                bool(rng.getrandbits(1)),
            )
            for _ in range(2048)
        ]
        for accumulator, bias, multiplier, shift, relu in vectors:
            scaled = _round_half_away((accumulator + bias) * multiplier, shift)
            if relu:
                scaled = max(scaled, 0)
            expected = max(-128, min(127, scaled))
            actual = ctypes.c_int8()
            status = self.library.alexnet_golden_requantize(
                accumulator, bias, multiplier, shift, int(relu),
                ctypes.byref(actual)
            )
            self.assertEqual(status, 0)
            self.assertEqual(actual.value, expected)

    def _compare_conv(
        self,
        shape: tuple[int, int, int, int],
        output_channels: int,
        kernel: tuple[int, int],
        stride: tuple[int, int],
        padding: tuple[int, int],
        dilation: tuple[int, int],
        groups: int,
        seed: int,
    ) -> None:
        generator = torch.Generator().manual_seed(seed)
        batch, input_channels, input_h, input_w = shape
        input_tensor = torch.randint(-8, 8, shape, dtype=torch.int8,
                                     generator=generator).contiguous()
        weight_shape = (
            output_channels,
            input_channels // groups,
            kernel[0],
            kernel[1],
        )
        weights = torch.randint(-8, 8, weight_shape, dtype=torch.int8,
                                generator=generator).contiguous()
        expected = functional.conv2d(
            input_tensor.to(torch.float32), weights.to(torch.float32),
            stride=stride, padding=padding, dilation=dilation, groups=groups
        ).to(torch.int32).contiguous()
        actual = torch.empty_like(expected)
        status = self.library.alexnet_golden_conv2d_accumulate(
            _pointer(input_tensor, INT8_POINTER), batch, input_channels,
            input_h, input_w, _pointer(weights, INT8_POINTER), output_channels,
            input_channels // groups, kernel[0], kernel[1], groups, stride[0],
            stride[1], padding[0], padding[1], dilation[0], dilation[1],
            _pointer(actual, INT32_POINTER), actual.numel()
        )
        self.assertEqual(status, 0)
        torch.testing.assert_close(actual, expected, rtol=0, atol=0)

    def test_dense_grouped_and_conv1_geometry(self) -> None:
        self._compare_conv((2, 3, 9, 8), 5, (3, 3), (2, 1), (1, 1),
                           (1, 1), 1, 100)
        self._compare_conv((1, 4, 7, 7), 6, (3, 3), (1, 1), (1, 1),
                           (1, 1), 2, 200)
        self._compare_conv((1, 3, 31, 31), 4, (11, 11), (4, 4), (2, 2),
                           (1, 1), 1, 300)

    def test_linear_and_packed_sa_match_pytorch(self) -> None:
        generator = torch.Generator().manual_seed(400)
        activations = torch.randint(-16, 16, (33, 17), dtype=torch.int8,
                                    generator=generator).contiguous()
        weights = torch.randint(-16, 16, (65, 17), dtype=torch.int8,
                                generator=generator).contiguous()
        expected = (
            activations.to(torch.int32) @ weights.to(torch.int32).t()
        ).contiguous()
        for function_name in (
            "alexnet_golden_linear_accumulate",
            "alexnet_golden_packed_os_matmul",
        ):
            actual = torch.empty_like(expected)
            function = getattr(self.library, function_name)
            status = function(
                _pointer(activations, INT8_POINTER), activations.shape[0],
                activations.shape[1], _pointer(weights, INT8_POINTER),
                weights.shape[0], _pointer(actual, INT32_POINTER), actual.numel()
            )
            self.assertEqual(status, 0)
            torch.testing.assert_close(actual, expected, rtol=0, atol=0)

    def test_maxpool_matches_pytorch(self) -> None:
        generator = torch.Generator().manual_seed(500)
        input_tensor = torch.randint(-128, 128, (2, 3, 13, 13), dtype=torch.int8,
                                     generator=generator).contiguous()
        expected = functional.max_pool2d(
            input_tensor.to(torch.float32), kernel_size=3, stride=2
        ).to(torch.int8).contiguous()
        actual = torch.empty_like(expected)
        status = self.library.alexnet_golden_maxpool2d(
            _pointer(input_tensor, INT8_POINTER), 2, 3, 13, 13, 3, 3, 2, 2,
            0, 0, _pointer(actual, INT8_POINTER), actual.numel()
        )
        self.assertEqual(status, 0)
        torch.testing.assert_close(actual, expected, rtol=0, atol=0)

    @staticmethod
    def _requantize_channels(
        accumulators: torch.Tensor,
        bias: torch.Tensor,
        multiplier: torch.Tensor,
        shift: torch.Tensor,
        relu: bool,
    ) -> torch.Tensor:
        expected = torch.empty_like(accumulators, dtype=torch.int8)
        ranges = [range(size) for size in accumulators.shape]
        for coordinate in itertools.product(*ranges):
            channel = coordinate[1]
            value = (int(accumulators[coordinate]) + int(bias[channel]))
            value *= int(multiplier[channel])
            value = _round_half_away(value, int(shift[channel]))
            if relu:
                value = max(value, 0)
            expected[coordinate] = max(-128, min(127, value))
        return expected

    def test_full_tensor_conv_and_linear_requantize(self) -> None:
        generator = torch.Generator().manual_seed(600)
        value = torch.randint(-8, 9, (1, 3, 7, 7), dtype=torch.int8,
                              generator=generator).contiguous()
        weight = torch.randint(-8, 9, (4, 3, 3, 3), dtype=torch.int8,
                               generator=generator).contiguous()
        bias = torch.tensor([-7, 0, 11, 23], dtype=torch.int32)
        multiplier = torch.tensor([3, 5, 7, 9], dtype=torch.int32)
        shift = torch.tensor([4, 5, 6, 7], dtype=torch.uint8)
        accumulators = functional.conv2d(
            value.float(), weight.float(), padding=1
        ).to(torch.int32)
        expected = self._requantize_channels(
            accumulators, bias, multiplier, shift, True
        ).contiguous()
        actual = torch.empty_like(expected)
        status = self.library.alexnet_golden_conv2d_int8(
            _pointer(value, INT8_POINTER), 1, 3, 7, 7,
            _pointer(weight, INT8_POINTER), 4, 3, 3, 3, 1, 1, 1, 1, 1, 1, 1,
            _pointer(bias, INT32_POINTER), _pointer(multiplier, INT32_POINTER),
            _pointer(shift, UINT8_POINTER), 1, _pointer(actual, INT8_POINTER),
            actual.numel(),
        )
        self.assertEqual(status, 0)
        torch.testing.assert_close(actual, expected, rtol=0, atol=0)

        linear_input = torch.randint(-8, 9, (2, 7), dtype=torch.int8,
                                     generator=generator).contiguous()
        linear_weight = torch.randint(-8, 9, (4, 7), dtype=torch.int8,
                                      generator=generator).contiguous()
        linear_acc = (linear_input.to(torch.int32) @ linear_weight.to(torch.int32).t())
        linear_expected = self._requantize_channels(
            linear_acc, bias, multiplier, shift, False
        ).contiguous()
        linear_actual = torch.empty_like(linear_expected)
        status = self.library.alexnet_golden_linear_int8(
            _pointer(linear_input, INT8_POINTER), 2, 7,
            _pointer(linear_weight, INT8_POINTER), 4,
            _pointer(bias, INT32_POINTER), _pointer(multiplier, INT32_POINTER),
            _pointer(shift, UINT8_POINTER), 0,
            _pointer(linear_actual, INT8_POINTER), linear_actual.numel(),
        )
        self.assertEqual(status, 0)
        torch.testing.assert_close(linear_actual, linear_expected, rtol=0, atol=0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
