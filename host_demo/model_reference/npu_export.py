"""Export the NPU-friendly traffic-sign CNN to maxcpu S4 artifacts.

What it does
------------
1. Fold BatchNorm into each conv (weight + bias).
2. Calibrate per-layer activation ranges on the training split.
3. Quantize weights per output channel (int8), activations per tensor.
4. Compute the NPU requant parameters: per-lane M (uint16), per-layer shift,
   and per-lane int32 bias.
5. Simulate the exact int8 datapath (conv -> +bias -> *M >> s -> sat -> ReLU)
   and report test accuracy.
6. Emit `wgt_bank0..3.hex` (1024 x 64-bit each, AW=10) and `npu_layers.h`
   with the layer table, M/bias arrays, and integer FC weights.

Usage
-----
    python npu_export.py \
        --checkpoint runs\traffic_npu_32\best.pt \
        --out-dir    runs\traffic_npu_32\npu \
        --calib 512
"""
import argparse
import json
import math
import os

import numpy as np
import torch
from torch import nn
from torch.nn import functional as F

from data import build_dataset
from model import build_model


# --------------------------------------------------------------------------
# 1. BN folding
# --------------------------------------------------------------------------
def fold_bn(model):
    """Return a list of dicts: folded weight/bias + conv geometry."""
    feats = model.features
    layers = []
    for i in range(0, len(feats), 3):
        conv, bn = feats[i], feats[i + 1]
        w = conv.weight.detach().double()
        gamma = bn.weight.detach().double()
        beta = bn.bias.detach().double()
        mean = bn.running_mean.detach().double()
        var = bn.running_var.detach().double()
        std = torch.sqrt(var + float(bn.eps))
        w_fold = w * (gamma / std).view(-1, 1, 1, 1)
        b_fold = beta - gamma * mean / std
        layers.append({
            "w": w_fold,
            "b": b_fold,
            "cin": int(conv.in_channels),
            "cout": int(conv.out_channels),
            "k": int(conv.kernel_size[0]),
            "stride": int(conv.stride[0]),
            "pad": int(conv.padding[0]),
        })
    return layers


# --------------------------------------------------------------------------
# 2. Calibration
# --------------------------------------------------------------------------
def normalize_images(imgs):
    x = torch.from_numpy(np.asarray(imgs)).permute(0, 3, 1, 2).float() / 255.0
    return (x - 0.5) / 0.5


@torch.no_grad()
def collect_stats(layers, calib_x, batch=64):
    """Per-layer max |input| and max |ReLU output| over the calibration set."""
    stats = [{"in": 0.0, "out": 0.0} for _ in layers]
    for s in range(0, len(calib_x), batch):
        x = calib_x[s:s + batch]
        for i, L in enumerate(layers):
            stats[i]["in"] = max(stats[i]["in"], float(x.abs().max()))
            y = F.conv2d(x, L["w"].float(), L["b"].float(),
                         stride=L["stride"], padding=L["pad"])
            y = F.relu(y)
            stats[i]["out"] = max(stats[i]["out"], float(y.abs().max()))
            x = y
    return stats


# --------------------------------------------------------------------------
# 3. Quantization
# --------------------------------------------------------------------------
def quantize_layers(layers, stats, input_scale):
    """Per-output-channel weights, per-tensor activations, NPU M/s/bias."""
    s_x = [0.0] * len(layers)
    s_y = [0.0] * len(layers)
    s_x[0] = input_scale
    for i in range(len(layers)):
        if i > 0:
            s_x[i] = s_y[i - 1]
        # 5% headroom against calibration outliers
        s_y[i] = max(stats[i]["out"], 1e-6) * 1.05 / 127.0

    q_layers = []
    for i, L in enumerate(layers):
        w = L["w"]
        absmax = w.abs().amax(dim=(1, 2, 3))
        scale_w = torch.clamp(absmax / 127.0, min=1e-8)
        q_w = torch.round(w / scale_w.view(-1, 1, 1, 1)).clamp(-127, 127).to(torch.int8)

        ratio = scale_w * s_x[i] / s_y[i]
        max_r = max(float(ratio.max()), 1e-12)
        # largest shift such that max M still fits uint16
        shift = int(math.floor(math.log2(65535.0 / max_r)))
        shift = max(0, min(shift, 31))
        m = torch.round(ratio * (2.0 ** shift)).clamp(1, 65535).to(torch.int32)

        bias_q = torch.round(L["b"] / (scale_w * s_x[i]))
        bias_q = torch.clamp(bias_q, -2 ** 31, 2 ** 31 - 1).to(torch.int32)

        q_layers.append({
            "q_w": q_w,
            "m": m,
            "shift": shift,
            "bias_q": bias_q,
            "scale_w": scale_w,
            "s_x": s_x[i],
            "s_y": s_y[i],
            "cin": L["cin"],
            "cout": L["cout"],
            "k": L["k"],
            "stride": L["stride"],
            "pad": L["pad"],
        })
    return q_layers


# --------------------------------------------------------------------------
# 4. Bit-exact int8 simulation
# --------------------------------------------------------------------------
@torch.no_grad()
def simulate_int8(q_layers, x, input_scale, batch=128):
    """Return quantized logits using the same arithmetic as npu_core/requant."""
    outs = []
    for s in range(0, len(x), batch):
        q = torch.round(x[s:s + batch] / input_scale).clamp(-127, 127).double()
        for L in q_layers:
            acc = F.conv2d(q, L["q_w"].double(), None,
                           stride=L["stride"], padding=L["pad"])
            acc = acc + L["bias_q"].view(1, -1, 1, 1).double()
            # Hardware: (acc * M) >>> shift, i.e. floor for negatives.
            y = torch.floor(acc * L["m"].view(1, -1, 1, 1).double() / (2.0 ** L["shift"]))
            q = torch.relu(y.clamp(-128, 127))
        outs.append(q)
    return torch.cat(outs, 0)


def accuracy_from_logits(logits, labels):
    return float((logits.argmax(1) == labels).float().mean())


# --------------------------------------------------------------------------
# 5. Weight / header export
# --------------------------------------------------------------------------
def weight_bases(q_layers):
    bases, t = [], 0
    for L in q_layers:
        bases.append(t)
        t += L["cin"] * L["k"] * L["k"]
    return bases, t


def write_weight_hex(q_layers, bases, out_dir, aw=10):
    depth = 1 << aw
    banks = [np.zeros((depth, 8), dtype=np.uint8) for _ in range(4)]
    for L, base in zip(q_layers, bases):
        q_w = L["q_w"].numpy()
        cout, cin, k, _ = q_w.shape
        tap = 0
        for kh in range(k):
            for kw in range(k):
                for ic in range(cin):
                    for b in range(4):
                        for j in range(8):
                            oc = 8 * b + j
                            if oc < cout:
                                banks[b][base + tap, j] = np.uint8(int(q_w[oc, ic, kh, kw]) & 0xFF)
                    tap += 1
        assert base + tap <= depth, f"weight ROM overflow: {base + tap} > {depth}"

    for b in range(4):
        path = os.path.join(out_dir, f"wgt_bank{b}.hex")
        with open(path, "w", encoding="ascii") as f:
            for a in range(depth):
                # wgt_rom = {wb3,wb2,wb1,wb0}; lane 0 = LSB of bank0.
                # $readmemh is MSB-first, so print bytes j=7..0.
                line = "".join(f"{int(banks[b][a, j]):02x}" for j in range(7, -1, -1))
                f.write(line + "\n")
        print(f"wrote {path}  ({depth} lines)")


def layer_geometry(L):
    out_w = (32 if L["k"] == 3 and L["stride"] == 1 else None)
    # generic, from the known input sizes
    return out_w


def write_header(q_layers, bases, classes, fc, out_dir, final_scale, input_scale,
                 acc_int8, acc_float, acc_int_fc):
    # Integer FC: per-tensor weight scale, bias folded to the same integer domain.
    fc_w = fc.weight.detach().double()
    fc_b = fc.bias.detach().double()
    fc_scale = max(float(fc_w.abs().max()) / 127.0, 1e-8)
    q_fc = torch.round(fc_w / fc_scale).clamp(-127, 127).to(torch.int8)
    fc_bias_q = torch.round(fc_b * 64.0 / (final_scale * fc_scale)).to(torch.int32)

    lines = []
    lines.append("#ifndef NPU_LAYERS_H")
    lines.append("#define NPU_LAYERS_H")
    lines.append("")
    lines.append("#include <stdint.h>")
    lines.append("")
    lines.append("/* maxcpu S4 NPU layer table, generated by npu_export.py */")
    lines.append("#define NPU_NUM_LAYERS   %d" % len(q_layers))
    lines.append("#define NPU_NUM_CLASSES  %d" % len(classes))
    lines.append("#define NPU_BUF_A        0x00000u")
    lines.append("#define NPU_BUF_B        0x08000u")
    lines.append("#define NPU_INPUT_BASE   NPU_BUF_A")
    lines.append("#define NPU_FINAL_BASE   NPU_BUF_B")
    lines.append("#define NPU_FINAL_W      8")
    lines.append("#define NPU_FINAL_H      8")
    lines.append("#define NPU_FINAL_C      32")
    lines.append("")
    lines.append("typedef struct {")
    lines.append("    uint32_t img_base, out_base;")
    lines.append("    uint16_t img_w, img_h, cin, cout, k, stride, pad, out_w, out_h;")
    lines.append("    uint16_t wgt_base;")
    lines.append("    uint8_t  shift, act;")
    lines.append("    uint16_t m[32];")
    lines.append("    int32_t  bias[32];")
    lines.append("} npu_layer_t;")
    lines.append("")
    lines.append("static const npu_layer_t npu_layers[NPU_NUM_LAYERS] = {")

    img_w = 32
    for i, L in enumerate(q_layers):
        out_w = (img_w + 2 * L["pad"] - L["k"]) // L["stride"] + 1
        img_base = "NPU_BUF_A" if i % 2 == 0 else "NPU_BUF_B"
        out_base = "NPU_BUF_B" if i % 2 == 0 else "NPU_BUF_A"
        m = [int(x) for x in L["m"]] + [0] * (32 - L["cout"])
        b = [int(x) for x in L["bias_q"]] + [0] * (32 - L["cout"])
        lines.append("    { %s, %s, %d, %d, %d, %d, %d, %d, %d, %d, %d, %du, %d, 1,"
                     % (img_base, out_base, img_w, img_w, L["cin"], L["cout"],
                        L["k"], L["stride"], L["pad"], out_w, out_w, bases[i], L["shift"]))
        lines.append("      { %s }," % ", ".join(str(x) for x in m))
        lines.append("      { %s } }," % ", ".join(str(x) for x in b))
        img_w = out_w
    lines.append("};")
    lines.append("")
    lines.append("/* FC 32 -> 20, integer weights; argmax(sum(gap)*q_w + bias_q) */")
    lines.append("static const int8_t npu_fc_w[NPU_NUM_CLASSES][32] = {")
    for r in range(len(classes)):
        vals = [int(x) for x in q_fc[r]]
        lines.append("    { %s }," % ", ".join(str(x) for x in vals))
    lines.append("};")
    lines.append("static const int32_t npu_fc_bias[NPU_NUM_CLASSES] = {")
    lines.append("    " + ", ".join(str(int(x)) for x in fc_bias_q))
    lines.append("};")
    lines.append("")
    lines.append("static const char *npu_classes[NPU_NUM_CLASSES] = {")
    for c in classes:
        lines.append('    "%s",' % c)
    lines.append("};")
    lines.append("")
    lines.append("#endif /* NPU_LAYERS_H */")

    path = os.path.join(out_dir, "npu_layers.h")
    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    print(f"wrote {path}")

    report = {
        "float_test_acc": acc_float,
        "int8_test_acc": acc_int8,
        "int8_int_fc_acc": acc_int_fc,
        "input_scale": input_scale,
        "final_scale": final_scale,
        "fc_scale": fc_scale,
        "layers": [
            {
                "cin": L["cin"], "cout": L["cout"], "k": L["k"],
                "stride": L["stride"], "pad": L["pad"],
                "s_x": L["s_x"], "s_y": L["s_y"], "shift": L["shift"],
                "m_min": int(L["m"].min()), "m_max": int(L["m"].max()),
                "wgt_base": bases[i],
            }
            for i, L in enumerate(q_layers)
        ],
    }
    with open(os.path.join(out_dir, "quant_report.json"), "w", encoding="utf-8") as f:
        json.dump(report, f, indent=2)
    print(f"wrote {os.path.join(out_dir, 'quant_report.json')}")
    return report


# --------------------------------------------------------------------------
# main
# --------------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--checkpoint", default=r"runs\traffic_npu_32\best.pt")
    ap.add_argument("--out-dir", default=r"runs\traffic_npu_32\npu")
    ap.add_argument("--data-root", default=r"D:\study\data\traffic_signs\TT100K_Cropped\DataSet")
    ap.add_argument("--cache", default=r"D:\study\data\traffic_signs\traffic_cls\cache")
    ap.add_argument("--top-k", type=int, default=20)
    ap.add_argument("--calib", type=int, default=512)
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--aw", type=int, default=10)
    args = ap.parse_args()

    os.makedirs(args.out_dir, exist_ok=True)
    ckpt = torch.load(args.checkpoint, map_location="cpu", weights_only=False)
    arch = ckpt.get("arch", "resnet8")
    if arch != "npu":
        raise SystemExit(f"checkpoint arch={arch}; this exporter is for NpuNet only")
    classes = [str(c) for c in ckpt["classes"]]
    model = build_model("npu", num_classes=len(classes), dropout=0.0)
    model.load_state_dict(ckpt["model"])
    model.eval()
    print(f"arch={arch} classes={len(classes)} params={sum(p.numel() for p in model.parameters()):,}")

    tr_x, tr_y, te_x, te_y, data_classes = build_dataset(
        args.data_root, size=int(ckpt.get("img_size", 32)), top_k=args.top_k, cache=args.cache)
    assert data_classes == classes, "class list mismatch"

    layers = fold_bn(model)
    rng = np.random.RandomState(args.seed)
    idx = rng.choice(len(tr_x), size=min(args.calib, len(tr_x)), replace=False)
    calib_x = normalize_images(tr_x[idx])
    stats = collect_stats(layers, calib_x)
    input_scale = max(1.0, stats[0]["in"]) / 127.0
    print("input_scale", input_scale)

    q_layers = quantize_layers(layers, stats, input_scale)
    for i, L in enumerate(q_layers):
        print(f"layer {i}: {L['cin']:2d}->{L['cout']:2d} k={L['k']} s={L['stride']} "
              f"shift={L['shift']:2d} M=[{int(L['m'].min())},{int(L['m'].max())}] "
              f"s_x={L['s_x']:.6f} s_y={L['s_y']:.6f}")

    test_x = normalize_images(te_x)
    test_y = torch.from_numpy(np.asarray(te_y)).long()
    with torch.no_grad():
        logits_f = model(test_x)
    acc_float = accuracy_from_logits(logits_f, test_y)

    q_final = simulate_int8(q_layers, test_x, input_scale)
    final_scale = q_layers[-1]["s_y"]
    gap_sum = q_final.sum(dim=(2, 3)).double()  # [N,32]
    gap = gap_sum / float(q_final.shape[2] * q_final.shape[3]) * final_scale
    fc = model.fc
    logits_i = F.linear(gap.float(), fc.weight, fc.bias)
    acc_int8 = accuracy_from_logits(logits_i, test_y)

    # Integer FC path (what the CPU will actually run)
    fc_w = fc.weight.detach().double()
    fc_scale = max(float(fc_w.abs().max()) / 127.0, 1e-8)
    q_fc = torch.round(fc_w / fc_scale).clamp(-127, 127)
    fc_bias_q = torch.round(fc.bias.detach().double() * 64.0 / (final_scale * fc_scale))
    int_logits = gap_sum @ q_fc.T + fc_bias_q
    acc_int_fc = accuracy_from_logits(int_logits, test_y)

    print(f"float test acc = {acc_float:.4f}")
    print(f"int8  test acc = {acc_int8:.4f}")
    print(f"int8+intFC acc = {acc_int_fc:.4f}")

    bases, total_taps = weight_bases(q_layers)
    print("weight bases", bases, "total taps", total_taps)
    write_weight_hex(q_layers, bases, args.out_dir, aw=args.aw)
    write_header(q_layers, bases, classes, fc, args.out_dir, final_scale, input_scale,
                 acc_int8, acc_float, acc_int_fc)

    if acc_int_fc < 0.95:
        print("WARNING: int8 accuracy below 95%; consider QAT or more calibration")
    else:
        print("OK: int8 accuracy above 95%")


if __name__ == "__main__":
    main()