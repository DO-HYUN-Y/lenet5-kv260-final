import os
import struct

import torch
from torchvision import datasets, transforms
from torch.utils.data import DataLoader

from train_and_extract import LeNet5, quantize_to_int8, OUT_DIR

WEIGHT_ROWS = 1449
PARAM_RECORDS = 236
WEIGHT_BYTES = WEIGHT_ROWS * 64
PARAM_BYTES = PARAM_RECORDS * 8


def conv_weight_flat(qw):
    # [out_ch,in_ch,K,K] -> [out_ch, K*K*in_ch], order (kh,kw,c_in)
    # matches window_gen.sv line 446: k_out = (kh*K+kw)*C_IN+c_in
    out_ch = qw.shape[0]
    return qw.permute(0, 2, 3, 1).contiguous().view(out_ch, -1)


def fc_lane(local_idx):
    # matches dual_mode_weight_buffer.sv filter_lo = out_ch_base + g*16 + 2*c
    lane = local_idx % 2
    g = local_idx // 16
    bank = (local_idx % 16) // 2
    byte_off = 2 * g + lane
    return bank, byte_off


def clip_i32(v):
    return max(-(2 ** 31), min(2 ** 31 - 1, int(v)))


def clip_i18(v):
    return max(-131072, min(131071, int(v)))


def calibrate(model, test_ds):
    loader = DataLoader(test_ds, batch_size=1000)
    keys = ["input", "conv1_output", "conv2_output", "fc1_output", "fc2_output", "fc3_output"]
    maxes = {k: 0.0 for k in keys}
    with torch.no_grad():
        for imgs, _ in loader:
            maxes["input"] = max(maxes["input"], imgs.abs().max().item())

            c1 = model.act(model.conv1(imgs))
            maxes["conv1_output"] = max(maxes["conv1_output"], c1.abs().max().item())
            p1 = model.pool(c1)

            c2 = model.act(model.conv2(p1))
            maxes["conv2_output"] = max(maxes["conv2_output"], c2.abs().max().item())
            p2 = model.pool(c2)

            flat = p2.view(-1, 16 * 5 * 5)
            f1 = model.act(model.fc1(flat))
            maxes["fc1_output"] = max(maxes["fc1_output"], f1.abs().max().item())

            f2 = model.act(model.fc2(f1))
            maxes["fc2_output"] = max(maxes["fc2_output"], f2.abs().max().item())

            f3 = model.fc3(f2)
            maxes["fc3_output"] = max(maxes["fc3_output"], f3.abs().max().item())

    return {k: v / 127.0 for k, v in maxes.items()}


def main():
    model = LeNet5()
    ckpt_path = os.path.join(OUT_DIR, "lenet5.pth")
    model.load_state_dict(torch.load(ckpt_path, map_location="cpu"))
    model.eval()

    transform = transforms.Compose([
        transforms.Resize((32, 32)),
        transforms.ToTensor(),
        transforms.Normalize((0.1307,), (0.3081,))
    ])
    test_ds = datasets.MNIST("data", train=False, download=True, transform=transform)

    print("calibrating over full test set (10000 images)...")
    scales = calibrate(model, test_ds)
    for k, v in scales.items():
        print(f"  {k:14s} {v:.8f}")

    input_scale_for = {
        "conv1": scales["input"],
        "conv2": scales["conv1_output"],
        "fc1":   scales["conv2_output"],
        "fc2":   scales["fc1_output"],
        "fc3":   scales["fc2_output"],
    }
    output_scale_for = {
        "conv1": scales["conv1_output"],
        "conv2": scales["conv2_output"],
        "fc1":   scales["fc1_output"],
        "fc2":   scales["fc2_output"],
        "fc3":   scales["fc3_output"],
    }

    LAYER_SPECS = {
        "conv1": dict(layer=model.conv1, kind="conv", param_base=0,   out_ch_total=6,   depth=25,  passes=[(0, 6)]),
        "conv2": dict(layer=model.conv2, kind="conv", param_base=6,   out_ch_total=16,  depth=150, passes=[(25, 8), (175, 8)]),
        "fc1":   dict(layer=model.fc1,   kind="fc",   param_base=22,  out_ch_total=120, depth=400, passes=[(325, 64), (725, 56)]),
        "fc2":   dict(layer=model.fc2,   kind="fc",   param_base=142, out_ch_total=84,  depth=120, passes=[(1125, 64), (1245, 20)]),
        "fc3":   dict(layer=model.fc3,   kind="fc",   param_base=226, out_ch_total=10,  depth=84,  passes=[(1365, 10)]),
    }

    weight_array = bytearray(WEIGHT_BYTES)
    param_array = bytearray(PARAM_BYTES)
    weight_scales = {}
    m_fixed_dbg = {}

    for name in ["conv1", "conv2", "fc1", "fc2", "fc3"]:
        spec = LAYER_SPECS[name]
        layer = spec["layer"]

        qw, sw = quantize_to_int8(layer.weight)
        weight_scales[name] = sw
        if spec["kind"] == "conv":
            qw_flat = conv_weight_flat(qw)
        else:
            qw_flat = qw.view(spec["out_ch_total"], -1)
        qw_flat = qw_flat.numpy()

        in_scale = input_scale_for[name]
        out_scale = output_scale_for[name]
        m_real = in_scale * sw / out_scale
        m_fixed = clip_i18(round(m_real * (1 << 17)))
        m_fixed_dbg[name] = m_fixed

        oc_start = 0
        for weight_base, pass_size in spec["passes"]:
            pass_weights = qw_flat[oc_start:oc_start + pass_size]
            for k in range(spec["depth"]):
                row = bytearray(64)
                for local_idx in range(pass_size):
                    val = int(pass_weights[local_idx, k]) & 0xFF
                    if spec["kind"] == "conv":
                        bank, byte_off = local_idx, 0
                    else:
                        bank, byte_off = fc_lane(local_idx)
                    row[bank * 8 + byte_off] = val
                row_index = weight_base + k
                weight_array[row_index * 64:(row_index + 1) * 64] = row
            oc_start += pass_size
        assert oc_start == spec["out_ch_total"], f"{name}: pass sizes don't sum to out_ch_total"

        bias_fp32 = layer.bias.detach()
        for oc in range(spec["out_ch_total"]):
            bias_i32 = clip_i32(round(bias_fp32[oc].item() / (in_scale * sw)))
            word = (bias_i32 & 0xFFFFFFFF) | ((m_fixed & 0x3FFFF) << 32)
            rec_index = spec["param_base"] + oc
            struct.pack_into("<Q", param_array, rec_index * 8, word)

    assert len(weight_array) == WEIGHT_BYTES
    assert len(param_array) == PARAM_BYTES

    weight_path = os.path.join(OUT_DIR, "weights_hw.bin")
    param_path = os.path.join(OUT_DIR, "params_hw.bin")
    scale_path = os.path.join(OUT_DIR, "scales_hw.txt")

    with open(weight_path, "wb") as f:
        f.write(weight_array)
    with open(param_path, "wb") as f:
        f.write(param_array)
    with open(scale_path, "w") as f:
        for k, v in scales.items():
            f.write(f"{k} {v:.8f}\n")
        for name in ["conv1", "conv2", "fc1", "fc2", "fc3"]:
            f.write(f"{name}_weight {weight_scales[name]:.8f}\n")
            f.write(f"{name}_m_fixed {m_fixed_dbg[name]}\n")

    print(f"\nsaved {weight_path}  ({len(weight_array)} bytes, expect {WEIGHT_BYTES})")
    print(f"saved {param_path}  ({len(param_array)} bytes, expect {PARAM_BYTES})")
    print(f"saved {scale_path}")

    # spot checks
    print("\n--- spot check ---")
    print("conv1 m_fixed:", m_fixed_dbg["conv1"], " weight_scale:", weight_scales["conv1"])
    print("conv1 row0 (k=0) bytes:", weight_array[0:64].hex())
    print("conv1 oc0 param record (bias|scale):", param_array[0:8].hex())
    fc3_last_row = (1365 + 84 - 1) * 64
    print("fc3 last depth row bytes:", weight_array[fc3_last_row:fc3_last_row + 64].hex())
    print("fc3 oc9 param record:", param_array[(226 + 9) * 8:(226 + 9) * 8 + 8].hex())


if __name__ == "__main__":
    main()
