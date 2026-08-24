"""Architecture contract tests for the FP32 AlexNet reference."""

import unittest

import torch
from torchvision.models import alexnet as torchvision_alexnet

from .model import AlexNet, INPUT_SHAPE, capture_layer_shapes, count_macs


class AlexNetContractTest(unittest.TestCase):
    """Verify the frozen AlexNet structure and torchvision compatibility."""

    def test_shapes_and_parameter_count(self) -> None:
        """Check layer shapes, parameter count, and MAC count."""

        # eval()은 학습이 아니라 추론 모드로 바꿔 Dropout을 끈다.
        model = AlexNet().eval()

        # 실제 사진 대신 모든 값이 0인 입력 한 장으로 중간 shape를 수집한다.
        shapes = capture_layer_shapes(model, torch.zeros(INPUT_SHAPE))

        # assertEqual(실제값, 기대값): 두 값이 다르면 이 테스트는 실패한다.
        self.assertEqual(shapes["conv1"], (1, 64, 55, 55))
        self.assertEqual(shapes["pool1"], (1, 64, 27, 27))
        self.assertEqual(shapes["conv2"], (1, 192, 27, 27))
        self.assertEqual(shapes["pool2"], (1, 192, 13, 13))
        self.assertEqual(shapes["conv3"], (1, 384, 13, 13))
        self.assertEqual(shapes["conv4"], (1, 256, 13, 13))
        self.assertEqual(shapes["conv5"], (1, 256, 13, 13))
        self.assertEqual(shapes["pool5"], (1, 256, 6, 6))
        self.assertEqual(shapes["logits"], (1, 1000))

        # 모든 weight와 bias 원소 수를 더한 결과가 공식 AlexNet과 같은지 확인한다.
        self.assertEqual(sum(parameter.numel() for parameter in model.parameters()), 61_100_840)

        # layer별/전체 MAC 수가 성능 계약값과 같은지 확인한다.
        macs_by_layer, total_macs = count_macs(model, torch.zeros(INPUT_SHAPE))
        self.assertEqual(total_macs, 714_188_480)
        self.assertEqual(macs_by_layer["conv1"], 70_276_800)
        self.assertEqual(macs_by_layer["fc8"], 4_096_000)

    def test_state_dict_and_output_match_torchvision(self) -> None:
        """Check exact output equivalence with torchvision AlexNet."""

        # 두 모델의 임의 입력과 초기 상태를 반복 가능하게 만들기 위한 seed이다.
        torch.manual_seed(1234)

        # torchvision 공식 구조와 우리가 작성한 구조를 각각 만든다.
        reference = torchvision_alexnet(weights=None).eval()
        model = AlexNet().eval()

        # 공식 모델의 모든 weight/bias를 우리 모델에 복사한다.
        # strict=True이므로 layer 이름이나 shape가 다르면 여기서 바로 실패한다.
        model.load_state_dict(reference.state_dict(), strict=True)

        # 실제 입력 규격과 같은 임의의 FP32 이미지 tensor 한 장을 만든다.
        x = torch.randn(1, 3, 224, 224)

        # 같은 입력을 두 모델에 넣고 결과를 얻는다.
        with torch.inference_mode():
            expected = reference(x)
            actual = model(x)

        # rtol=0, atol=0은 작은 오차도 허용하지 않는 bit-for-bit 비교이다.
        torch.testing.assert_close(actual, expected, rtol=0.0, atol=0.0)


if __name__ == "__main__":
    # ``python -m alexnet.test_model``로 실행하면 위의 test_* 함수들을 수행한다.
    unittest.main()
