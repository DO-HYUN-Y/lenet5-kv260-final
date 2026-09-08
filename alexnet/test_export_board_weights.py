"""Small layout tests for the KV260 AlexNet board-weight packer."""

from __future__ import annotations

import unittest

import torch

from .export_board_weights import packed_conv_chunks, packed_fc_chunks
from .int8_reference import QuantizedLayer


def fake_layer(name: str, op: str, weight: torch.Tensor) -> QuantizedLayer:
    outputs = weight.shape[0]
    return QuantizedLayer(
        name=name,
        op=op,
        weight=weight,
        weight_scale=torch.ones(outputs, dtype=torch.float64),
        bias=torch.zeros(outputs, dtype=torch.int32),
        multiplier=torch.ones(outputs, dtype=torch.int32),
        right_shift=torch.zeros(outputs, dtype=torch.uint8),
        input_scale=1.0,
        output_scale=1.0,
        relu=False,
    )


class BoardWeightLayoutTest(unittest.TestCase):
    def test_conv_order_is_tile_chunk_ky_kx_input_lane_n_lane(self) -> None:
        weight = torch.empty((16, 9, 2, 2), dtype=torch.int8)
        for n in range(16):
            for channel in range(9):
                for ky in range(2):
                    for kx in range(2):
                        weight[n, channel, ky, kx] = (
                            n * 31 + channel * 7 + ky * 3 + kx
                        ) % 127
        chunks = list(packed_conv_chunks(fake_layer("conv", "conv2d", weight)))
        self.assertEqual(len(chunks), 4)
        self.assertEqual(len(chunks[0]), 2 * 2 * 8 * 8)
        self.assertEqual(len(chunks[1]), 2 * 2 * 1 * 8)

        first = torch.frombuffer(bytearray(chunks[0]), dtype=torch.int8).reshape(
            2, 2, 8, 8
        )
        tail = torch.frombuffer(bytearray(chunks[1]), dtype=torch.int8).reshape(
            2, 2, 1, 8
        )
        self.assertTrue(torch.equal(first, weight[0:8, 0:8].permute(2, 3, 1, 0)))
        self.assertTrue(torch.equal(tail, weight[0:8, 8:9].permute(2, 3, 1, 0)))

    def test_fc_order_is_tile_k_n_lane(self) -> None:
        weight = torch.arange(16 * 5, dtype=torch.int8).reshape(16, 5)
        chunks = list(packed_fc_chunks(fake_layer("fc", "linear", weight)))
        self.assertEqual(len(chunks), 2)
        first = torch.frombuffer(bytearray(chunks[0]), dtype=torch.int8).reshape(5, 8)
        self.assertTrue(torch.equal(first, weight[0:8].transpose(0, 1)))


if __name__ == "__main__":
    unittest.main()
