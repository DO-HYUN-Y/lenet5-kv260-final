"""OpenCV camera preprocessing for the frozen torchvision AlexNet contract."""

from __future__ import annotations

from collections.abc import Callable

import numpy as np


RESIZE_SHORT_SIDE = 256
CROP_SIZE = 224
IMAGENET_MEAN = np.asarray((0.485, 0.456, 0.406), dtype=np.float32)
IMAGENET_STD = np.asarray((0.229, 0.224, 0.225), dtype=np.float32)


def round_half_away_from_zero(values: np.ndarray) -> np.ndarray:
    return np.where(values >= 0, np.floor(values + 0.5), np.ceil(values - 0.5))


def preprocess_bgr_frame(
    frame: np.ndarray,
    input_scale: float,
    resize_function: Callable | None = None,
) -> bytes:
    """Return one 224x224x8 RGB INT8 camera-DMA image."""

    if resize_function is None:
        import cv2

        resize_function = lambda image, size: cv2.resize(
            image, size, interpolation=cv2.INTER_LINEAR
        )

    if frame.ndim != 3 or frame.shape[2] != 3:
        raise ValueError(f"expected an HxWx3 BGR frame, got {frame.shape}")
    if frame.dtype != np.uint8:
        raise ValueError(f"expected uint8 camera pixels, got {frame.dtype}")
    if input_scale <= 0:
        raise ValueError("input scale must be positive")

    height, width = frame.shape[:2]
    if width <= height:
        resized_width = RESIZE_SHORT_SIDE
        resized_height = int(RESIZE_SHORT_SIDE * height / width)
    else:
        resized_height = RESIZE_SHORT_SIDE
        resized_width = int(RESIZE_SHORT_SIDE * width / height)
    resized = resize_function(frame, (resized_width, resized_height))
    top = (resized_height - CROP_SIZE) // 2
    left = (resized_width - CROP_SIZE) // 2
    crop_bgr = resized[top : top + CROP_SIZE, left : left + CROP_SIZE]
    rgb = crop_bgr[:, :, ::-1].astype(np.float32) / 255.0
    normalized = (rgb - IMAGENET_MEAN) / IMAGENET_STD
    quantized = round_half_away_from_zero(normalized / input_scale)
    quantized = np.clip(quantized, -128, 127).astype(np.int8)

    packed = np.zeros((CROP_SIZE, CROP_SIZE, 8), dtype=np.int8)
    packed[:, :, :3] = quantized
    return packed.tobytes()


def coarse_korean_category(index: int) -> str | None:
    # torchvision ImageNet-1K indices 151..268 are domestic dog breeds.
    if 151 <= index <= 268:
        return "강아지"
    if 281 <= index <= 285:
        return "고양이"
    return None


def format_prediction(index: int, label: str, score: int) -> str:
    coarse = coarse_korean_category(index)
    if coarse is None:
        return f"결과: {label} (class={index}, int8={score})"
    return f"결과: {coarse} ({label}, class={index}, int8={score})"
