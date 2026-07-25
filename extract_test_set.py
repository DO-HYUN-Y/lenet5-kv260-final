import os

import torch
from torchvision import datasets, transforms

from train_and_extract import OUT_DIR

SCALES_PATH = os.path.join(OUT_DIR, "scales_hw.txt")


def load_input_scale():
    with open(SCALES_PATH) as f:
        for line in f:
            k, v = line.split()
            if k == "input":
                return float(v)
    raise RuntimeError(f"'input' scale not found in {SCALES_PATH}")


def quantize_fixed(tensor, scale):
    q = (tensor / scale).round().clamp(-128, 127).to(torch.int8)
    return q


def main():
    input_scale = load_input_scale()
    print(f"using fixed input_scale={input_scale:.8f} (from {SCALES_PATH})")

    transform = transforms.Compose([
        transforms.Resize((32, 32)),
        transforms.ToTensor(),
        transforms.Normalize((0.1307,), (0.3081,))
    ])
    test_ds = datasets.MNIST("data", train=False, download=True, transform=transform)
    n = len(test_ds)

    images_path = os.path.join(OUT_DIR, "test_images.bin")
    labels_path = os.path.join(OUT_DIR, "test_labels.bin")

    with open(images_path, "wb") as fi, open(labels_path, "wb") as fl:
        for img, label in test_ds:
            q = quantize_fixed(img.squeeze(0), input_scale)  # [32,32] int8, row-major
            fi.write(q.contiguous().view(-1).numpy().tobytes())
            fl.write(bytes([label]))

    print(f"saved {images_path}  ({n * 1024} bytes, expect {n * 1024})")
    print(f"saved {labels_path}  ({n} bytes, expect {n})")

    with open(images_path, "rb") as f:
        first_img = f.read(1024)
    with open(labels_path, "rb") as f:
        first_label = f.read(1)
    print(f"\nspot check: image0 label={first_label[0]}  first16bytes={first_img[:16].hex()}")


if __name__ == "__main__":
    main()
