import os
import struct

import numpy as np
import torch
import torch.nn.functional as F
from torchvision import datasets, transforms

from train_and_extract import LeNet5, OUT_DIR

WEIGHT_PATH = os.path.join(OUT_DIR, "weights_hw.bin")
PARAM_PATH = os.path.join(OUT_DIR, "params_hw.bin")
IMAGES_PATH = os.path.join(OUT_DIR, "test_images.bin")
LABELS_PATH = os.path.join(OUT_DIR, "test_labels.bin")
LOGITS_PATH = os.path.join(OUT_DIR, "test_logits_hw.bin")
CKPT_PATH = os.path.join(OUT_DIR, "lenet5.pth")

LAYER_SPECS = {
    "conv1": dict(kind="conv", param_base=0,   out_ch_total=6,   C_in=1, K=5, passes=[(0, 6)]),
    "conv2": dict(kind="conv", param_base=6,   out_ch_total=16,  C_in=6, K=5, passes=[(25, 8), (175, 8)]),
    "fc1":   dict(kind="fc",   param_base=22,  out_ch_total=120, depth=400, passes=[(325, 64), (725, 56)]),
    "fc2":   dict(kind="fc",   param_base=142, out_ch_total=84,  depth=120, passes=[(1125, 64), (1245, 20)]),
    "fc3":   dict(kind="fc",   param_base=226, out_ch_total=10,  depth=84,  passes=[(1365, 10)]),
}

RELU = {"conv1": True, "conv2": True, "fc1": True, "fc2": True, "fc3": False}


def s8(b):
    return b - 256 if b >= 128 else b


def decode_conv_weight(weight_array, spec):
    C_in, K, out_ch_total = spec["C_in"], spec["K"], spec["out_ch_total"]
    depth = C_in * K * K
    w_flat = np.zeros((out_ch_total, depth), dtype=np.int64)
    oc_start = 0
    for base, pass_size in spec["passes"]:
        for local_idx in range(pass_size):
            col = local_idx * 8  # bank=local_idx, byte_off=0
            for k in range(depth):
                row_off = (base + k) * 64
                w_flat[oc_start + local_idx, k] = s8(int(weight_array[row_off + col]))
        oc_start += pass_size
    # k = (kh*K+kw)*C_in + c_in  ->  reshape(out,K,K,C_in) then to [out,C_in,K,K]
    w4 = w_flat.reshape(out_ch_total, K, K, C_in).transpose(0, 3, 1, 2)
    return torch.from_numpy(w4.copy()).double()


def decode_fc_weight(weight_array, spec):
    depth, out_ch_total = spec["depth"], spec["out_ch_total"]
    w = np.zeros((out_ch_total, depth), dtype=np.int64)
    oc_start = 0
    for base, pass_size in spec["passes"]:
        for local_idx in range(pass_size):
            lane = local_idx % 2
            g = local_idx // 16
            bank = (local_idx % 16) // 2
            byte_off = 2 * g + lane
            col = bank * 8 + byte_off
            for k in range(depth):
                row_off = (base + k) * 64
                w[oc_start + local_idx, k] = s8(int(weight_array[row_off + col]))
        oc_start += pass_size
    return torch.from_numpy(w.copy()).double()


def decode_params(param_array, spec):
    param_base, out_ch_total = spec["param_base"], spec["out_ch_total"]
    bias = np.zeros(out_ch_total, dtype=np.int64)
    m_fixed_list = []
    for oc in range(out_ch_total):
        word = struct.unpack_from("<Q", param_array, (param_base + oc) * 8)[0]
        b32 = word & 0xFFFFFFFF
        if b32 & 0x80000000:
            b32 -= 1 << 32
        mf = (word >> 32) & 0x3FFFF
        if mf & 0x20000:
            mf -= 1 << 18
        bias[oc] = b32
        m_fixed_list.append(mf)
    assert len(set(m_fixed_list)) == 1, f"m_fixed not uniform across oc: {set(m_fixed_list)}"
    return torch.from_numpy(bias).long(), m_fixed_list[0]


def requantize(acc_double, bias, m_fixed, relu):
    # acc_double: float64 tensor, exact integer values from conv2d/matmul
    value = acc_double.round().long() + bias
    if relu:
        value = torch.clamp_min(value, 0)
    value = torch.clamp(value, -(1 << 26), (1 << 26) - 1)
    product = value * m_fixed
    magnitude = (product.abs() + (1 << 16)) >> 17
    result = torch.sign(product) * magnitude
    result = torch.clamp(result, -128, 127)
    return result


def main():
    weight_array = np.fromfile(WEIGHT_PATH, dtype=np.uint8)
    param_array = np.fromfile(PARAM_PATH, dtype=np.uint8)
    images = np.fromfile(IMAGES_PATH, dtype=np.int8).reshape(-1, 32, 32)
    labels = np.fromfile(LABELS_PATH, dtype=np.uint8)
    n = images.shape[0]
    print(f"loaded {n} test images")

    weights, biases, mfixeds = {}, {}, {}
    for name, spec in LAYER_SPECS.items():
        if spec["kind"] == "conv":
            weights[name] = decode_conv_weight(weight_array, spec)
        else:
            weights[name] = decode_fc_weight(weight_array, spec)
        biases[name], mfixeds[name] = decode_params(param_array, spec)
        print(f"  {name}: weight {tuple(weights[name].shape)}  m_fixed={mfixeds[name]}")

    x = torch.from_numpy(images.astype(np.int64)).double().unsqueeze(1)  # [N,1,32,32]

    correct = 0
    batch = 500
    all_preds = []
    all_logits = []
    for i in range(0, n, batch):
        xb = x[i:i + batch]

        acc = F.conv2d(xb, weights["conv1"])
        act = requantize(acc, biases["conv1"].view(1, -1, 1, 1), mfixeds["conv1"], RELU["conv1"])
        act = F.max_pool2d(act.double(), 2, 2)

        acc = F.conv2d(act, weights["conv2"])
        act = requantize(acc, biases["conv2"].view(1, -1, 1, 1), mfixeds["conv2"], RELU["conv2"])
        act = F.max_pool2d(act.double(), 2, 2)

        flat = act.long().reshape(act.shape[0], -1).double()  # [B,400] C,H,W flatten order

        acc = flat @ weights["fc1"].T
        act = requantize(acc, biases["fc1"].view(1, -1), mfixeds["fc1"], RELU["fc1"]).double()

        acc = act @ weights["fc2"].T
        act = requantize(acc, biases["fc2"].view(1, -1), mfixeds["fc2"], RELU["fc2"]).double()

        acc = act @ weights["fc3"].T
        out = requantize(acc, biases["fc3"].view(1, -1), mfixeds["fc3"], RELU["fc3"])

        preds = out.argmax(dim=1).numpy()
        all_preds.append(preds)
        all_logits.append(out.numpy().astype(np.int8, copy=False))
        correct += (preds == labels[i:i + batch]).sum()
        print(f"  {i + xb.shape[0]}/{n}  running_acc={correct/(i+xb.shape[0])*100:.2f}%", end="\r")

    print()
    hw_acc = correct / n * 100
    print(f"\nINT8 HW-emulated accuracy: {hw_acc:.2f}%  ({correct}/{n})")
    logits = np.concatenate(all_logits, axis=0)
    assert logits.shape == (n, 10)
    logits.tofile(LOGITS_PATH)
    print(f"saved {LOGITS_PATH}  ({logits.nbytes} bytes)")

    # fp32 baseline for comparison
    model = LeNet5()
    model.load_state_dict(torch.load(CKPT_PATH, map_location="cpu"))
    model.eval()
    transform = transforms.Compose([
        transforms.Resize((32, 32)),
        transforms.ToTensor(),
        transforms.Normalize((0.1307,), (0.3081,))
    ])
    test_ds = datasets.MNIST("data", train=False, download=True, transform=transform)
    loader = torch.utils.data.DataLoader(test_ds, batch_size=1000)
    fp32_correct = 0
    with torch.no_grad():
        for imgs, lbls in loader:
            fp32_correct += (model(imgs).argmax(1) == lbls).sum().item()
    fp32_acc = fp32_correct / len(test_ds) * 100
    print(f"fp32 baseline accuracy:    {fp32_acc:.2f}%  ({fp32_correct}/{len(test_ds)})")
    print(f"delta: {fp32_acc - hw_acc:.2f} pp")


if __name__ == "__main__":
    main()
