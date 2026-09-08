"""Run saved-image or live USB-camera AlexNet inference on KV260."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import time

import numpy as np

from .alexnet_board import AlexNetBoard
from .preprocess import format_prediction, preprocess_bgr_frame


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", default="/dev/alexnet_board")
    parser.add_argument(
        "--board-dir",
        type=Path,
        default=Path("alexnet_output/int8_mlcommons500_board"),
    )
    parser.add_argument("--image", type=Path, help="run one saved image")
    parser.add_argument("--camera", type=int, default=0)
    parser.add_argument(
        "--inspect", action="store_true", help="check board identity and exit"
    )
    parser.add_argument("--once", action="store_true", help="classify one camera frame")
    parser.add_argument("--interval", type=float, default=0.25)
    parser.add_argument("--timeout", type=float, default=10.0)
    parser.add_argument("--topk", type=int, default=5)
    return parser.parse_args()


def classify(
    board: AlexNetBoard,
    frame: np.ndarray,
    manifest: dict,
    timeout_s: float,
    topk: int,
) -> None:
    packed = preprocess_bgr_frame(frame, float(manifest["input_scale"]))
    start = time.monotonic()
    raw_logits = board.infer(packed, timeout_s)
    elapsed_ms = (time.monotonic() - start) * 1000.0
    logits = np.frombuffer(raw_logits, dtype=np.int8)
    order = np.argsort(-logits.astype(np.int16), kind="stable")[:topk]
    winner = int(np.argmax(logits))
    categories = manifest["categories"]
    print(format_prediction(winner, categories[winner], int(logits[winner])))
    top_text = ", ".join(
        f"{categories[int(index)]}={int(logits[int(index)])}"
        for index in order
    )
    print(f"Top-{topk}: {top_text} / PL 왕복 {elapsed_ms:.1f} ms", flush=True)


def main() -> None:
    args = parse_args()
    if not 1 <= args.topk <= 1000:
        raise SystemExit("--topk must be in 1..1000")
    with AlexNetBoard(args.device) as board:
        board.require_identity()
        if args.inspect:
            print(json.dumps(board.inspect(), indent=2))
            print("ALEXNET_KV260_BOARD_INSPECT_PASS")
            return
        try:
            import cv2
        except ImportError as error:
            raise SystemExit("OpenCV is required: install python3-opencv") from error
        manifest = board.load_model(args.board_dir)
        board.configure()
        print(
            f"AlexNet 준비 완료: PL={board.pl_clock_hz} Hz, "
            f"DMA=0x{board.dma_addr:08x}, 모델 적재 완료",
            flush=True,
        )

        if args.image is not None:
            frame = cv2.imread(str(args.image), cv2.IMREAD_COLOR)
            if frame is None:
                raise SystemExit(f"cannot read image: {args.image}")
            classify(board, frame, manifest, args.timeout, args.topk)
            return

        camera = cv2.VideoCapture(args.camera, cv2.CAP_V4L2)
        if not camera.isOpened():
            raise SystemExit(f"cannot open V4L2 camera index {args.camera}")
        print("USB 카메라 분류 시작 (종료: Ctrl+C)", flush=True)
        try:
            while True:
                ok, frame = camera.read()
                if not ok:
                    raise RuntimeError("USB camera frame capture failed")
                classify(board, frame, manifest, args.timeout, args.topk)
                if args.once:
                    break
                if args.interval > 0:
                    time.sleep(args.interval)
        except KeyboardInterrupt:
            print("카메라 분류 종료")
        finally:
            camera.release()


if __name__ == "__main__":
    main()
