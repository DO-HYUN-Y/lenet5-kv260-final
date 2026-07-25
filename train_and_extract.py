import torch
import torch.nn as nn
import torch.optim as optim
from torchvision import datasets, transforms
from torch.utils.data import DataLoader
import numpy as np
import os

OUT_DIR = "output"
os.makedirs(OUT_DIR, exist_ok=True)


class LeNet5(nn.Module):
    def __init__(self):
        super().__init__()
        self.conv1 = nn.Conv2d(1, 6, 5)
        self.conv2 = nn.Conv2d(6, 16, 5)
        self.fc1   = nn.Linear(16 * 5 * 5, 120)
        self.fc2   = nn.Linear(120, 84)
        self.fc3   = nn.Linear(84, 10)
        self.pool  = nn.MaxPool2d(2, 2)
        self.act   = nn.ReLU()

    def forward(self, x):
        x = self.pool(self.act(self.conv1(x)))
        x = self.pool(self.act(self.conv2(x)))
        x = x.view(-1, 16 * 5 * 5)
        x = self.act(self.fc1(x))
        x = self.act(self.fc2(x))
        x = self.fc3(x)
        return x


def quantize_to_int8(tensor):
    t = tensor.detach().float()
    scale = t.abs().max() / 127.0
    if scale == 0:
        scale = torch.tensor(1.0)
    q = (t / scale).round().clamp(-128, 127).to(torch.int8)
    return q, scale.item()


def save_bin(arr_int8, name):
    path = os.path.join(OUT_DIR, name)
    arr_int8.numpy().tofile(path)
    print(f"  saved {path}  shape={arr_int8.shape}")


def train():
    transform = transforms.Compose([
        transforms.Resize((32, 32)),
        transforms.ToTensor(),
        transforms.Normalize((0.1307,), (0.3081,))
    ])
    train_ds = datasets.MNIST("data", train=True,  download=True, transform=transform)
    test_ds  = datasets.MNIST("data", train=False, download=True, transform=transform)
    train_loader = DataLoader(train_ds, batch_size=64, shuffle=True)
    test_loader  = DataLoader(test_ds,  batch_size=1000)

    device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    print(f"Training on {device}")
    model = LeNet5().to(device)
    optimizer = optim.Adam(model.parameters(), lr=1e-3)
    criterion = nn.CrossEntropyLoss()

    for epoch in range(10):
        model.train()
        for imgs, labels in train_loader:
            imgs, labels = imgs.to(device), labels.to(device)
            optimizer.zero_grad()
            loss = criterion(model(imgs), labels)
            loss.backward()
            optimizer.step()

        model.eval()
        correct = 0
        with torch.no_grad():
            for imgs, labels in test_loader:
                imgs, labels = imgs.to(device), labels.to(device)
                correct += (model(imgs).argmax(1) == labels).sum().item()
        print(f"Epoch {epoch+1}/10  acc={correct/len(test_ds)*100:.2f}%")

    torch.save(model.state_dict(), os.path.join(OUT_DIR, "lenet5.pth"))
    return model.cpu(), test_ds


def extract(model, test_ds):
    model.eval()

    # 테스트 이미지 1장 (index 0)
    img, label = test_ds[0]
    print(f"\nInput image label: {label}")
    img_batch = img.unsqueeze(0)  # [1,1,32,32]

    # input 저장 — [1, 32, 32] row-major, window generator가 row씩 읽음
    q_input, s_input = quantize_to_int8(img_batch.squeeze(0))  # [1,32,32]
    save_bin(q_input.contiguous().view(-1), "input.bin")

    # weights + biases 추출
    layers = {
        "conv1": model.conv1,
        "conv2": model.conv2,
        "fc1":   model.fc1,
        "fc2":   model.fc2,
        "fc3":   model.fc3,
    }

    scales = {"input": s_input}
    for name, layer in layers.items():
        qw, sw = quantize_to_int8(layer.weight)
        # Conv: [out_ch, in_ch, 5, 5] → contiguous row-major = out_ch→in_ch→row→col
        # FC:   [out, in] → row-major
        # .contiguous().view(-1) 으로 streaming 순서 보장
        save_bin(qw.contiguous().view(-1), f"{name}_weight.bin")
        scales[f"{name}_weight"] = sw

        if layer.bias is not None:
            qb, sb = quantize_to_int8(layer.bias)
            save_bin(qb.contiguous().view(-1), f"{name}_bias.bin")
            scales[f"{name}_bias"] = sb

    # scale 저장
    scale_path = os.path.join(OUT_DIR, "scales.txt")
    with open(scale_path, "w") as f:
        for k, v in scales.items():
            f.write(f"{k} {v:.8f}\n")
    print(f"  saved {scale_path}")

    # shape 메타데이터
    meta_path = os.path.join(OUT_DIR, "shapes.txt")
    with open(meta_path, "w") as f:
        f.write(f"input          {list(img_batch.shape)}\n")
        for name, layer in layers.items():
            f.write(f"{name}_weight    {list(layer.weight.shape)}\n")
            if layer.bias is not None:
                f.write(f"{name}_bias      {list(layer.bias.shape)}\n")
    print(f"  saved {meta_path}")

    print(f"\nAll files in ./{OUT_DIR}/")


if __name__ == "__main__":
    model, test_ds = train()
    print("\n--- Extracting INT8 weights & input ---")
    extract(model, test_ds)
