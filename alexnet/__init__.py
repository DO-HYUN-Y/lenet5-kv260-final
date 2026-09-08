"""FP32 AlexNet reference package for the KV260 accelerator project."""

# 별표 import를 할 때 외부에 공개할 이름을 명확히 제한한다.
__all__ = ["AlexNet", "create_alexnet"]


def __getattr__(name: str):
    """Load the PyTorch model only when a caller explicitly requests it."""

    if name in __all__:
        # KV260 board-control modules can now import ``alexnet.software``
        # without installing the much larger PyTorch runtime.
        from .model import AlexNet, create_alexnet

        return {"AlexNet": AlexNet, "create_alexnet": create_alexnet}[name]
    raise AttributeError(f"module {__name__!r} has no attribute {name!r}")
