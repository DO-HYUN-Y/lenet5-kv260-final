"""Frozen torchvision-compatible AlexNet FP32 architecture.

This is intentionally kept separate from the future INT8 and RTL models.  Its
state_dict keys match torchvision.models.alexnet so that the official
IMAGENET1K_V1 checkpoint can be loaded without key conversion.
"""

from __future__ import annotations

from collections import OrderedDict
from typing import Callable

import torch
from torch import Tensor, nn


INPUT_SHAPE = (1, 3, 224, 224)
CLASS_COUNT = 1000


class AlexNet(nn.Module):
    """The torchvision AlexNet topology with an explicit 224x224 contract."""

    def __init__(self, num_classes: int = CLASS_COUNT, dropout: float = 0.5) -> None:
        super().__init__()
        self.features = nn.Sequential(
            nn.Conv2d(3, 64, kernel_size=11, stride=4, padding=2),
            nn.ReLU(inplace=True),
            nn.MaxPool2d(kernel_size=3, stride=2),
            nn.Conv2d(64, 192, kernel_size=5, padding=2),
            nn.ReLU(inplace=True),
            nn.MaxPool2d(kernel_size=3, stride=2),
            nn.Conv2d(192, 384, kernel_size=3, padding=1),
            nn.ReLU(inplace=True),
            nn.Conv2d(384, 256, kernel_size=3, padding=1),
            nn.ReLU(inplace=True),
            nn.Conv2d(256, 256, kernel_size=3, padding=1),
            nn.ReLU(inplace=True),
            nn.MaxPool2d(kernel_size=3, stride=2),
        )
        self.avgpool = nn.AdaptiveAvgPool2d((6, 6))
        self.classifier = nn.Sequential(
            nn.Dropout(p=dropout),
            nn.Linear(256 * 6 * 6, 4096),
            nn.ReLU(inplace=True),
            nn.Dropout(p=dropout),
            nn.Linear(4096, 4096),
            nn.ReLU(inplace=True),
            nn.Linear(4096, num_classes),
        )

    def forward(self, x: Tensor) -> Tensor:
        x = self.features(x)
        x = self.avgpool(x)
        x = torch.flatten(x, 1)
        return self.classifier(x)


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
    """Create the frozen model and optionally load torchvision V1 weights.

    Returns the model together with the torchvision weight enum.  The latter
    owns the exact resize/crop/normalization transform used by the checkpoint.
    """

    model = AlexNet()
    if not pretrained:
        return model, None

    from torchvision.models import AlexNet_Weights

    weights = AlexNet_Weights.IMAGENET1K_V1
    state_dict = weights.get_state_dict(progress=progress, check_hash=True)
    model.load_state_dict(state_dict, strict=True)
    return model, weights


def capture_layer_shapes(model: AlexNet, x: Tensor) -> OrderedDict[str, tuple[int, ...]]:
    """Run one forward pass and capture contract-relevant tensor shapes."""

    shapes: OrderedDict[str, tuple[int, ...]] = OrderedDict()
    handles = []

    for name, accessor in LAYER_MODULES.items():
        module = accessor(model)

        def hook(_module: nn.Module, _inputs: tuple[Tensor, ...], output: Tensor, *, key: str = name) -> None:
            shapes[key] = tuple(output.shape)

        handles.append(module.register_forward_hook(hook))

    try:
        with torch.inference_mode():
            logits = model(x)
        shapes["logits"] = tuple(logits.shape)
    finally:
        for handle in handles:
            handle.remove()

    return shapes


def count_macs(model: AlexNet, x: Tensor) -> tuple[OrderedDict[str, int], int]:
    """Count Conv/Linear MACs for the supplied batch shape.

    Bias additions, activations, and pooling are deliberately excluded.  The
    project performance convention converts this result with 1 MAC = 2 OPS.
    """

    macs: OrderedDict[str, int] = OrderedDict()
    handles = []

    for name, accessor in LAYER_MODULES.items():
        module = accessor(model)
        if not isinstance(module, (nn.Conv2d, nn.Linear)):
            continue

        def hook(active_module: nn.Module, _inputs: tuple[Tensor, ...], output: Tensor, *, key: str = name) -> None:
            if isinstance(active_module, nn.Conv2d):
                kernel_height, kernel_width = active_module.kernel_size
                products_per_output = (
                    active_module.in_channels // active_module.groups
                ) * kernel_height * kernel_width
                macs[key] = output.numel() * products_per_output
            elif isinstance(active_module, nn.Linear):
                macs[key] = output.numel() * active_module.in_features

        handles.append(module.register_forward_hook(hook))

    try:
        with torch.inference_mode():
            model(x)
    finally:
        for handle in handles:
            handle.remove()

    return macs, sum(macs.values())


def capture_activations(model: AlexNet, x: Tensor) -> OrderedDict[str, Tensor]:
    """Capture CPU copies of FP32 layer outputs for future bit-exact checks."""

    activations: OrderedDict[str, Tensor] = OrderedDict()
    handles = []

    for name, accessor in LAYER_MODULES.items():
        module = accessor(model)

        def hook(_module: nn.Module, _inputs: tuple[Tensor, ...], output: Tensor, *, key: str = name) -> None:
            # Clone is required because the following in-place ReLU would
            # otherwise modify a saved convolution output.
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
