"""Unit tests for the frozen AlexNet integer quantization contract."""

from __future__ import annotations

import unittest

import torch

from .int8_reference import (
    QuantizedLayer,
    _fixed_point_multiplier,
    quantize_activation,
    requantize_int8,
    round_half_away_from_zero,
)


class Int8ReferenceTest(unittest.TestCase):
    def test_round_half_away_from_zero(self) -> None:
        values = torch.tensor([-2.5, -1.5, -0.5, 0.5, 1.5, 2.5])
        expected = torch.tensor([-3.0, -2.0, -1.0, 1.0, 2.0, 3.0])
        torch.testing.assert_close(round_half_away_from_zero(values), expected)

    def test_activation_quantization_saturates(self) -> None:
        values = torch.tensor([-200.0, -1.5, -0.5, 0.5, 1.5, 200.0])
        expected = torch.tensor([-128, -2, -1, 1, 2, 127], dtype=torch.int8)
        torch.testing.assert_close(quantize_activation(values, 1.0), expected)

    def test_fixed_point_multiplier_is_int32_and_precise(self) -> None:
        for real in (1e-7, 0.003125, 0.75, 1.0, 3.5, 127.0):
            multiplier, shift = _fixed_point_multiplier(real)
            self.assertGreater(multiplier, 0)
            self.assertLessEqual(multiplier, (1 << 31) - 1)
            self.assertGreaterEqual(shift, 0)
            approximation = multiplier / (1 << shift)
            self.assertLessEqual(abs(approximation - real), 0.5 / (1 << shift))

    def test_fixed_point_multiplier_fits_signed_18_bit_dsp_input(self) -> None:
        for real in (1e-7, 0.003125, 0.75, 1.0, 3.5):
            multiplier, shift = _fixed_point_multiplier(real, storage_bits=18)
            self.assertGreater(multiplier, 0)
            self.assertLessEqual(multiplier, (1 << 17) - 1)
            approximation = multiplier / (1 << shift)
            self.assertLessEqual(abs(approximation - real), 0.5 / (1 << shift))

    def test_requantize_channel_parameters_and_relu(self) -> None:
        layer = QuantizedLayer(
            name="test",
            op="linear",
            weight=torch.zeros((2, 1), dtype=torch.int8),
            weight_scale=torch.ones(2, dtype=torch.float64),
            bias=torch.tensor([1, -1], dtype=torch.int32),
            multiplier=torch.tensor([3, 5], dtype=torch.int32),
            right_shift=torch.tensor([1, 2], dtype=torch.uint8),
            input_scale=1.0,
            output_scale=1.0,
            relu=True,
        )
        accumulators = torch.tensor([[0, 0], [100, -100]], dtype=torch.int32)
        expected = torch.tensor([[2, 0], [127, 0]], dtype=torch.int8)
        torch.testing.assert_close(requantize_int8(accumulators, layer), expected)


if __name__ == "__main__":
    unittest.main(verbosity=2)
