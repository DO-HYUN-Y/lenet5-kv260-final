"""torchvision과 호환되는 AlexNet FP32 기준 모델.

이 파일은 앞으로 만들 INT8 모델과 RTL의 정답(golden reference)이 된다.
클래스와 layer 순서를 torchvision AlexNet과 동일하게 만들었기 때문에 공식
IMAGENET1K_V1 가중치를 이름 변환 없이 그대로 불러올 수 있다.
"""

# 타입 힌트에서 아직 정의되지 않은 클래스 이름도 사용할 수 있게 해 준다.
# 모델 계산에는 영향을 주지 않는 Python 문법 설정이다.
from __future__ import annotations

from collections import OrderedDict
from typing import Callable

import torch
from torch import Tensor, nn


# PyTorch 영상 tensor 순서는 NCHW이다.
# N=한 번에 처리할 이미지 수, C=RGB 채널, H/W=영상 높이와 너비이다.
INPUT_SHAPE = (1, 3, 224, 224)

# ImageNet-1K은 분류 대상이 1,000종이므로 마지막 출력도 1,000개이다.
CLASS_COUNT = 1000


class AlexNet(nn.Module):
    """224x224 입력을 사용하는 torchvision 방식의 AlexNet.

    ``nn.Module``은 모든 PyTorch 신경망의 기본 클래스이다. 이 클래스를
    상속하면 학습 파라미터 저장, CPU/GPU 이동, 추론 실행 등을 PyTorch가
    관리해 준다.
    """

    def __init__(self, num_classes: int = CLASS_COUNT, dropout: float = 0.5) -> None:
        # 부모 클래스(nn.Module)의 초기화를 먼저 실행해야 layer가 정상 등록된다.
        super().__init__()

        # features는 영상에서 특징을 뽑는 합성곱 부분이다.
        # nn.Sequential 안의 layer들은 위에서 아래 순서대로 자동 실행된다.
        self.features = nn.Sequential(
            # 입력 [N, 3, 224, 224] -> Conv1 출력 [N, 64, 55, 55]
            # padding=2를 사용하므로 224 입력에서도 출력 크기가 55가 된다.
            nn.Conv2d(3, 64, kernel_size=11, stride=4, padding=2),
            # ReLU는 음수를 0으로 바꾸는 활성화 함수이다. 크기는 변하지 않는다.
            nn.ReLU(inplace=True),
            # 주변 3x3 값 중 최댓값만 선택해 55x55 -> 27x27로 줄인다.
            nn.MaxPool2d(kernel_size=3, stride=2),

            # Conv2: [N, 64, 27, 27] -> [N, 192, 27, 27]
            nn.Conv2d(64, 192, kernel_size=5, padding=2),
            nn.ReLU(inplace=True),
            # Pool2: [N, 192, 27, 27] -> [N, 192, 13, 13]
            nn.MaxPool2d(kernel_size=3, stride=2),

            # Conv3: channel 수만 192 -> 384로 바뀌고 공간 크기는 13x13 유지
            nn.Conv2d(192, 384, kernel_size=3, padding=1),
            nn.ReLU(inplace=True),
            # Conv4: [N, 384, 13, 13] -> [N, 256, 13, 13]
            nn.Conv2d(384, 256, kernel_size=3, padding=1),
            nn.ReLU(inplace=True),
            # Conv5: [N, 256, 13, 13] -> [N, 256, 13, 13]
            nn.Conv2d(256, 256, kernel_size=3, padding=1),
            nn.ReLU(inplace=True),
            # 마지막 pooling: [N, 256, 13, 13] -> [N, 256, 6, 6]
            nn.MaxPool2d(kernel_size=3, stride=2),
        )

        # 입력 크기가 약간 달라도 FC 입력을 항상 256x6x6으로 맞추는 안전장치다.
        # 우리 계약 입력은 224x224라서 이미 6x6이며 실제 크기는 변하지 않는다.
        self.avgpool = nn.AdaptiveAvgPool2d((6, 6))

        # classifier는 뽑힌 특징을 1,000개 class 점수로 바꾸는 완전연결(FC) 부분이다.
        self.classifier = nn.Sequential(
            # Dropout은 학습 중 일부 값을 무작위로 끄지만 model.eval() 추론에서는 꺼진다.
            nn.Dropout(p=dropout),
            # 256 * 6 * 6 = 9,216개 특징을 4,096개로 변환하는 FC6
            nn.Linear(256 * 6 * 6, 4096),
            nn.ReLU(inplace=True),
            nn.Dropout(p=dropout),
            # FC7: 4,096 -> 4,096
            nn.Linear(4096, 4096),
            nn.ReLU(inplace=True),
            # FC8: 4,096 -> ImageNet class 점수 1,000개
            nn.Linear(4096, num_classes),
        )

    def forward(self, x: Tensor) -> Tensor:
        """입력 영상 tensor를 받아 class별 점수(logit)를 반환한다.

        입력 shape:  [N, 3, 224, 224]
        출력 shape:  [N, 1000]

        출력은 확률이 아니라 logit이다. 확률이 필요하면 바깥에서 softmax를
        적용한다. 학습 시에는 CrossEntropyLoss가 softmax 역할까지 처리한다.
        """

        # 1) Conv/ReLU/Pool을 통과시켜 영상 특징을 추출한다.
        x = self.features(x)
        # 2) FC에 넣을 공간 크기를 6x6으로 확정한다.
        x = self.avgpool(x)
        # 3) [N, 256, 6, 6]을 [N, 9216]의 한 줄 vector로 펼친다.
        x = torch.flatten(x, 1)
        # 4) 세 개의 FC layer를 거쳐 class별 logit 1,000개를 만든다.
        return self.classifier(x)


# nn.Sequential은 layer를 숫자 index로 보관한다. 아래 표는 사람이 읽기 쉬운
# 이름(conv1, pool1 등)을 실제 layer index와 연결한다. shape/MAC/중간 출력
# 수집 함수들이 같은 이름을 사용하도록 한곳에서 관리한다.
LAYER_MODULES: "OrderedDict[str, Callable[[AlexNet], nn.Module]]" = OrderedDict(
    [
        ("conv1", lambda model: model.features[0]),
        ("relu1", lambda model: model.features[1]),
        ("pool1", lambda model: model.features[2]),
        ("conv2", lambda model: model.features[3]),
        ("relu2", lambda model: model.features[4]),
        ("pool2", lambda model: model.features[5]),
        ("conv3", lambda model: model.features[6]),
        ("relu3", lambda model: model.features[7]),
        ("conv4", lambda model: model.features[8]),
        ("relu4", lambda model: model.features[9]),
        ("conv5", lambda model: model.features[10]),
        ("relu5", lambda model: model.features[11]),
        ("pool5", lambda model: model.features[12]),
        ("avgpool", lambda model: model.avgpool),
        ("fc6", lambda model: model.classifier[1]),
        ("relu6", lambda model: model.classifier[2]),
        ("fc7", lambda model: model.classifier[4]),
        ("relu7", lambda model: model.classifier[5]),
        ("fc8", lambda model: model.classifier[6]),
    ]
)


def create_alexnet(
    pretrained: bool = True,
    *,
    progress: bool = True,
) -> tuple[AlexNet, object | None]:
    """AlexNet 객체를 만들고 필요하면 공식 학습 가중치를 불러온다.

    ``pretrained=True``이면 ImageNet으로 학습된 V1 checkpoint를 사용한다.
    반환값은 ``(model, weights)`` 두 개이다. ``weights``에는 가중치뿐 아니라
    resize, center crop, mean/std 정규화 규칙도 들어 있다.
    """

    # 우선 구조만 가진 빈 모델을 만든다. 이 시점의 가중치는 임의 값이다.
    model = AlexNet()
    if not pretrained:
        # 오프라인 구조 시험에서는 checkpoint 다운로드 없이 빈 모델을 반환한다.
        return model, None

    from torchvision.models import AlexNet_Weights

    # 우리가 고정한 공식 checkpoint를 선택한다.
    weights = AlexNet_Weights.IMAGENET1K_V1
    # 파일 hash를 확인하면서 state_dict(학습된 weight/bias 묶음)를 받는다.
    state_dict = weights.get_state_dict(progress=progress, check_hash=True)
    # strict=True는 layer 이름이나 shape가 하나라도 다르면 즉시 실패하게 한다.
    model.load_state_dict(state_dict, strict=True)
    return model, weights


def capture_layer_shapes(model: AlexNet, x: Tensor) -> OrderedDict[str, tuple[int, ...]]:
    """추론을 한 번 실행하며 각 layer 출력 shape를 순서대로 기록한다.

    hook은 layer가 실행될 때 PyTorch가 자동으로 호출해 주는 관찰 함수다.
    모델 계산을 바꾸지 않고 중간 결과만 확인할 때 사용한다.
    """

    # OrderedDict는 입력한 순서를 유지하므로 출력 보고서도 layer 순서가 된다.
    shapes: OrderedDict[str, tuple[int, ...]] = OrderedDict()
    # 등록한 hook을 마지막에 제거하기 위해 handle을 모아 둔다.
    handles = []

    for name, accessor in LAYER_MODULES.items():
        module = accessor(model)

        def hook(
            _module: nn.Module,
            _inputs: tuple[Tensor, ...],
            output: Tensor,
            *,
            key: str = name,
        ) -> None:
            # 예: output.shape가 torch.Size([1, 64, 55, 55])이면 tuple로 저장한다.
            shapes[key] = tuple(output.shape)

        handles.append(module.register_forward_hook(hook))

    try:
        # 추론만 하므로 gradient를 만들지 않아 메모리와 시간을 절약한다.
        with torch.inference_mode():
            logits = model(x)
        shapes["logits"] = tuple(logits.shape)
    finally:
        # 중간에 오류가 나도 hook은 반드시 제거해야 다음 추론에 중복 실행되지 않는다.
        for handle in handles:
            handle.remove()

    return shapes


def count_macs(model: AlexNet, x: Tensor) -> tuple[OrderedDict[str, int], int]:
    """입력 shape 기준으로 Conv/FC의 MAC 횟수를 계산한다.

    MAC은 ``한 번의 곱셈 + 한 번의 누산``을 뜻한다. bias 덧셈, ReLU, Pool은
    이 숫자에서 제외한다. 프로젝트 성능 표기에서는 ``1 MAC = 2 OPS``이다.
    """

    macs: OrderedDict[str, int] = OrderedDict()
    handles = []

    for name, accessor in LAYER_MODULES.items():
        module = accessor(model)
        # 실제 곱셈이 많은 Conv와 Linear(FC)만 세고 ReLU/Pool은 건너뛴다.
        if not isinstance(module, (nn.Conv2d, nn.Linear)):
            continue

        def hook(
            active_module: nn.Module,
            _inputs: tuple[Tensor, ...],
            output: Tensor,
            *,
            key: str = name,
        ) -> None:
            if isinstance(active_module, nn.Conv2d):
                kernel_height, kernel_width = active_module.kernel_size
                # 출력 값 하나를 만들 때 필요한 곱셈 수:
                # (입력 channel / group 수) * kernel 높이 * kernel 너비
                products_per_output = (
                    active_module.in_channels // active_module.groups
                ) * kernel_height * kernel_width
                # 전체 출력 원소 수와 원소 하나당 곱셈 수를 곱하면 layer MAC이다.
                macs[key] = output.numel() * products_per_output
            elif isinstance(active_module, nn.Linear):
                # FC 출력 하나는 모든 입력 feature와 한 번씩 곱한다.
                macs[key] = output.numel() * active_module.in_features

        handles.append(module.register_forward_hook(hook))

    try:
        with torch.inference_mode():
            model(x)
    finally:
        for handle in handles:
            handle.remove()

    # layer별 MAC 표와 모든 layer를 합친 총 MAC을 함께 반환한다.
    return macs, sum(macs.values())


def capture_activations(model: AlexNet, x: Tensor) -> OrderedDict[str, Tensor]:
    """각 layer의 FP32 출력값을 CPU tensor로 복사해 기록한다.

    나중에 Python INT8, C++, RTL 결과와 layer별로 비교하기 위한 golden
    tensor를 만들 때 사용한다.
    """

    activations: OrderedDict[str, Tensor] = OrderedDict()
    handles = []

    for name, accessor in LAYER_MODULES.items():
        module = accessor(model)

        def hook(
            _module: nn.Module,
            _inputs: tuple[Tensor, ...],
            output: Tensor,
            *,
            key: str = name,
        ) -> None:
            # detach(): gradient 계산 관계를 끊는다.
            # cpu(): GPU에서 실행했더라도 저장용 tensor를 CPU로 옮긴다.
            # clone(): 다음 inplace ReLU가 이전 Conv 출력을 덮어쓰지 못하게 복사한다.
            activations[key] = output.detach().cpu().clone()

        handles.append(module.register_forward_hook(hook))

    try:
        with torch.inference_mode():
            logits = model(x)
        activations["logits"] = logits.detach().cpu().clone()
    finally:
        for handle in handles:
            handle.remove()

    return activations
