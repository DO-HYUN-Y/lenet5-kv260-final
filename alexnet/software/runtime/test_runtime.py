"""Host-side tests for Linux ioctl, memory, and preprocessing contracts."""

from __future__ import annotations

from pathlib import Path
import re
import unittest

import numpy as np

from . import alexnet_board as board
from .preprocess import coarse_korean_category, preprocess_bgr_frame


class RuntimeContractTest(unittest.TestCase):
    def test_python_layout_matches_driver_header(self) -> None:
        header = (
            Path(__file__).parents[1] / "include" / "alexnet_buffer_layout.h"
        ).read_text(encoding="utf-8")
        macros = {
            name: int(value)
            for name, value in re.findall(
                r"^#define\s+(ALEXNET_[A-Z0-9_]+)\s+(\d+)u$",
                header,
                flags=re.MULTILINE,
            )
        }
        expected = {
            "ALEXNET_CAMERA_BUFFER_BYTES": board.INPUT_BYTES,
            "ALEXNET_ACTIVATION_A_BYTES": board.ACTIVATION_A_BYTES,
            "ALEXNET_ACTIVATION_B_BYTES": board.ACTIVATION_B_BYTES,
            "ALEXNET_WEIGHT_BYTES": board.WEIGHTS_BYTES,
            "ALEXNET_PARAMETER_BYTES": board.PARAMETERS_BYTES,
            "ALEXNET_OUTPUT_VALID_BYTES": board.OUTPUT_VALID_BYTES,
            "ALEXNET_OUTPUT_ALLOC_BYTES": board.OUTPUT_ALLOC_BYTES,
            "ALEXNET_BUFFER_INPUT_OFFSET": board.INPUT_OFFSET,
            "ALEXNET_BUFFER_ACT_A_OFFSET": board.ACTIVATION_A_OFFSET,
            "ALEXNET_BUFFER_ACT_B_OFFSET": board.ACTIVATION_B_OFFSET,
            "ALEXNET_BUFFER_WEIGHTS_OFFSET": board.WEIGHTS_OFFSET,
            "ALEXNET_BUFFER_PARAMETERS_OFFSET": board.PARAMETERS_OFFSET,
            "ALEXNET_BUFFER_OUTPUT_OFFSET": board.OUTPUT_OFFSET,
            "ALEXNET_DMA_USED_BYTES": board.DMA_USED_BYTES,
        }
        self.assertEqual({key: macros[key] for key in expected}, expected)

    def test_memory_layout_is_aligned_nonoverlapping_and_exact(self) -> None:
        regions = (
            (board.INPUT_OFFSET, board.INPUT_BYTES),
            (board.ACTIVATION_A_OFFSET, board.ACTIVATION_A_BYTES),
            (board.ACTIVATION_B_OFFSET, board.ACTIVATION_B_BYTES),
            (board.WEIGHTS_OFFSET, board.WEIGHTS_BYTES),
            (board.PARAMETERS_OFFSET, board.PARAMETERS_BYTES),
            (board.OUTPUT_OFFSET, board.OUTPUT_ALLOC_BYTES),
        )
        previous_end = 0
        for offset, size in regions:
            self.assertEqual(offset % board.BASE_ALIGNMENT, 0)
            self.assertGreaterEqual(offset, previous_end)
            previous_end = offset + size
        self.assertEqual(previous_end, board.DMA_USED_BYTES)
        self.assertEqual(board.DMA_BUFFER_BYTES % board.mmap.PAGESIZE, 0)
        self.assertGreaterEqual(board.DMA_BUFFER_BYTES, board.DMA_USED_BYTES)
        self.assertLess(
            board.DMA_BUFFER_BYTES - board.DMA_USED_BYTES,
            board.mmap.PAGESIZE,
        )
        self.assertGreaterEqual(board.ACTIVATION_A_BYTES, 64 * 55 * 55)
        self.assertGreaterEqual(board.ACTIVATION_B_BYTES, 192 * 27 * 27)
        self.assertLess(
            board.ACTIVATION_A_BYTES - 64 * 55 * 55,
            board.BASE_ALIGNMENT,
        )
        self.assertLess(
            board.ACTIVATION_B_BYTES - 192 * 27 * 27,
            board.BASE_ALIGNMENT,
        )

    def test_ioctl_numbers_match_linux_generic_encoding(self) -> None:
        self.assertEqual(board.IOC_GET_INFO, 0x80304100)
        self.assertEqual(board.IOC_READ_REG, 0xC0104101)
        self.assertEqual(board.IOC_WRITE_REG, 0x40104102)

    def test_preprocess_channel_order_quantization_and_zero_padding(
        self,
    ) -> None:
        # A constant image makes interpolation irrelevant while still checking
        # BGR-to-RGB, normalization, quantization, and the 8-byte ABI.
        bgr = np.empty((224, 224, 3), dtype=np.uint8)
        bgr[:, :, 0] = 10
        bgr[:, :, 1] = 20
        bgr[:, :, 2] = 30
        resized = np.pad(bgr, ((16, 16), (16, 16), (0, 0)))
        packed = np.frombuffer(
            preprocess_bgr_frame(
                bgr,
                0.020787402400820273,
                resize_function=lambda _image, _size: resized,
            ),
            dtype=np.int8,
        ).reshape(224, 224, 8)
        self.assertTrue(np.all(packed == packed[0, 0]))
        self.assertTrue(np.array_equal(packed[0, 0], [-77, -81, -78, 0, 0, 0, 0, 0]))

    def test_korean_dog_category_range(self) -> None:
        self.assertEqual(coarse_korean_category(207), "강아지")
        self.assertEqual(coarse_korean_category(281), "고양이")
        self.assertIsNone(coarse_korean_category(0))


if __name__ == "__main__":
    unittest.main()
