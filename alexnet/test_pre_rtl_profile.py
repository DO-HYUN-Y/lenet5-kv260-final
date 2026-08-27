"""Unit tests for pre-RTL range and sparsity counter definitions."""

from __future__ import annotations

from types import SimpleNamespace
import unittest

import torch

from .profile_pre_rtl import (
    new_raw_layer,
    required_signed_bits,
    static_layer_record,
    update_window_counts,
)


class PreRtlProfileTest(unittest.TestCase):
    def test_required_signed_bits(self) -> None:
        self.assertEqual(required_signed_bits(-128, 127), 8)
        self.assertEqual(required_signed_bits(-129, 127), 9)
        self.assertEqual(required_signed_bits(-1, 0), 1)
        self.assertEqual(required_signed_bits(0, 1), 2)

    def test_window_padding_and_natural_zero_are_separate(self) -> None:
        value = torch.tensor([[[[0, 1], [0, 0]]]], dtype=torch.int8)
        layer = SimpleNamespace(
            weight=torch.zeros((1, 1, 2, 2), dtype=torch.int8),
            dilation=(1, 1),
            padding=(1, 1),
            stride=(1, 1),
            groups=1,
        )
        record = new_raw_layer("conv2d")
        update_window_counts(record, value, layer)
        self.assertEqual(record["window_tokens"], 36)
        self.assertEqual(record["valid_window_tokens"], 16)
        self.assertEqual(record["padding_window_tokens"], 20)
        self.assertEqual(record["valid_window_zero_count"], 12)
        self.assertEqual(record["valid_kernel_rows"], 12)
        self.assertEqual(record["kernel_row_all_zero_count"], 8)
        self.assertEqual(record["valid_windows"], 9)
        self.assertEqual(record["full_window_all_zero_count"], 5)

    def test_static_bound_covers_every_int8_input(self) -> None:
        layer = SimpleNamespace(
            op="linear",
            weight=torch.tensor([[1, -2]], dtype=torch.int8),
            bias=torch.tensor([3], dtype=torch.int32),
            multiplier=torch.tensor([65536], dtype=torch.int32),
            right_shift=torch.tensor([24], dtype=torch.uint8),
        )
        record = static_layer_record(layer)
        self.assertEqual(record["all_int8_input_accumulator_min"], -382)
        self.assertEqual(record["all_int8_input_accumulator_max"], 383)
        self.assertEqual(record["all_int8_input_post_bias_min"], -379)
        self.assertEqual(record["all_int8_input_post_bias_max"], 386)
        self.assertEqual(
            record["all_int8_input_post_bias_required_signed_bits"], 10
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
