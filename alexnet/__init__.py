"""FP32 AlexNet reference package for the KV260 accelerator project."""

from .model import AlexNet, create_alexnet

__all__ = ["AlexNet", "create_alexnet"]
