"""KV260 프로젝트의 AlexNet FP32 기준 모델 package.

이 파일이 있으면 ``alexnet`` 폴더를 Python package로 import할 수 있다.
"""

# 자주 쓰는 두 이름을 ``from alexnet import AlexNet``처럼 짧게 불러오게 한다.
from .model import AlexNet, create_alexnet

# 별표 import를 할 때 외부에 공개할 이름을 명확히 제한한다.
__all__ = ["AlexNet", "create_alexnet"]
