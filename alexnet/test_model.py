"""Architecture contract tests for the FP32 AlexNet reference."""

import unittest

import torch
from torchvision.models import alexnet as torchvision_alexnet

from .model import AlexNet, INPUT_SHAPE, capture_layer_shapes, count_macs


class AlexNetContractTest(unittest.TestCase):
    def test_shapes_and_parameter_count(self) -> None:
        model = AlexNet().eval()
        shapes = capture_layer_shapes(model, torch.zeros(INPUT_SHAPE))
        self.assertEqual(shapes["conv1"], (1, 64, 55, 55))
        self.assertEqual(shapes["pool1"], (1, 64, 27, 27))
        self.assertEqual(shapes["conv2"], (1, 192, 27, 27))
        self.assertEqual(shapes["pool2"], (1, 192, 13, 13))
        self.assertEqual(shapes["conv3"], (1, 384, 13, 13))
        self.assertEqual(shapes["conv4"], (1, 256, 13, 13))
        self.assertEqual(shapes["conv5"], (1, 256, 13, 13))
        self.assertEqual(shapes["pool5"], (1, 256, 6, 6))
        self.assertEqual(shapes["logits"], (1, 1000))
        self.assertEqual(sum(parameter.numel() for parameter in model.parameters()), 61_100_840)
        macs_by_layer, total_macs = count_macs(model, torch.zeros(INPUT_SHAPE))
        self.assertEqual(total_macs, 714_188_480)
        self.assertEqual(macs_by_layer["conv1"], 70_276_800)
        self.assertEqual(macs_by_layer["fc8"], 4_096_000)

    def test_state_dict_and_output_match_torchvision(self) -> None:
        torch.manual_seed(1234)
        reference = torchvision_alexnet(weights=None).eval()
        model = AlexNet().eval()
        model.load_state_dict(reference.state_dict(), strict=True)
        x = torch.randn(1, 3, 224, 224)
        with torch.inference_mode():
            expected = reference(x)
            actual = model(x)
        torch.testing.assert_close(actual, expected, rtol=0.0, atol=0.0)


if __name__ == "__main__":
    unittest.main()
