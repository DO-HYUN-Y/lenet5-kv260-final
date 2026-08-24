"""FP32 AlexNet reference package for the KV260 accelerator project."""

# 자주 쓰는 두 이름을 ``from alexnet import AlexNet``처럼 짧게 불러오게 한다.
from .model import AlexNet, create_alexnet

# 별표 import를 할 때 외부에 공개할 이름을 명확히 제한한다.
__all__ = ["AlexNet", "create_alexnet"]
