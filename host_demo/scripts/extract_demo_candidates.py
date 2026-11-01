#!/usr/bin/env python3
"""Extract six known-correct test images from npu_demo_image.h.

The source header stores 10 model-input images that were selected by the
training pipeline because the deployed NpuNet classified them correctly.
This script dequantizes the first six useful classes, verifies that the local
make_frame.py preprocessing reproduces the exact same INT8 bytes, and writes
both 32x32 model inputs and enlarged previews.
"""
from __future__ import annotations

import csv
import re
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

HOST_DEMO = Path(__file__).resolve().parents[1]
HEADER = HOST_DEMO / "model_reference" / "npu_demo_image.h"
OUT = HOST_DEMO / "samples" / "demo_candidates"
INPUTS = OUT / "inputs"
PREVIEWS = OUT / "previews"
SCALE = 0.007874015748031496

SELECTED = ["pn", "pne", "i5", "pl40", "pl50", "pl80"]
CHINESE = {
    "pn": "禁止停车",
    "pne": "禁止驶入",
    "i5": "靠右侧道路行驶",
    "pl40": "限速40",
    "pl50": "限速50",
    "pl80": "限速80",
}


def parse_header() -> tuple[dict[str, list[int]], dict[str, int]]:
    text = HEADER.read_text(encoding="utf-8")
    image_block = text.split("npu_demo_images", 1)[1].split("npu_demo_labels", 1)[0]
    values = [int(v) for v in re.findall(r"\b\d+\b", image_block)]
    if len(values) != 10 * 3072:
        raise RuntimeError(f"expected {10 * 3072} image bytes, got {len(values)}")

    names_block = text.split("npu_demo_names[NPU_DEMO_COUNT] = {", 1)[1].split("};", 1)[0]
    names = re.findall(r'"([^"]+)"', names_block)
    if len(names) != 10:
        raise RuntimeError(f"expected 10 class names, got {names}")

    images = {name: values[index * 3072:(index + 1) * 3072] for index, name in enumerate(names)}
    labels = {name: index for index, name in enumerate(names)}
    return images, labels


def dequantize(values: list[int]) -> bytes:
    pixels = bytearray()
    for raw in values:
        signed = raw - 256 if raw >= 128 else raw
        normalized = signed * SCALE
        pixel = round((normalized * 0.5 + 0.5) * 255.0)
        pixels.append(max(0, min(255, pixel)))
    return bytes(pixels)


def main() -> int:
    from make_frame import encode_frame, quantize_image

    images, labels = parse_header()
    INPUTS.mkdir(parents=True, exist_ok=True)
    PREVIEWS.mkdir(parents=True, exist_ok=True)

    records = []
    preview_items = []
    for number, name in enumerate(SELECTED, start=1):
        if name not in images:
            raise KeyError(f"class {name} not present in header")
        raw_quantized = bytes(images[name])
        rgb = dequantize(images[name])
        model_input = Image.frombytes("RGB", (32, 32), rgb)
        stem = f"{number:02d}_{name}"
        input_path = INPUTS / f"{stem}_32x32.png"
        preview_path = PREVIEWS / f"{stem}_preview.png"
        model_input.save(input_path)

        roundtrip = quantize_image(input_path, SCALE)
        exact = roundtrip == raw_quantized
        if not exact:
            raise RuntimeError(f"round-trip mismatch for {name}")

        frame, crc = encode_frame(raw_quantized)
        if len(frame.encode("ascii")) != 6205:
            raise RuntimeError(f"bad frame length for {name}")

        preview = model_input.resize((320, 320), Image.Resampling.NEAREST)
        preview.save(preview_path)
        preview_items.append((name, preview.copy()))

        records.append({
            "number": f"{number:02d}",
            "class_id": labels[name],
            "code": name,
            "chinese": CHINESE[name],
            "input_32x32": str(input_path),
            "preview": str(preview_path),
            "frame_crc": f"{crc:04x}",
            "exact_int8_roundtrip": "yes",
        })

    with (OUT / "expected_labels.csv").open("w", encoding="utf-8-sig", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=list(records[0]))
        writer.writeheader()
        writer.writerows(records)

    cols = 3
    cell_w, cell_h = 340, 375
    rows = (len(preview_items) + cols - 1) // cols
    sheet = Image.new("RGB", (cols * cell_w, rows * cell_h), "white")
    draw = ImageDraw.Draw(sheet)
    font_path = Path(r"C:\Windows\Fonts\msyh.ttc")
    label_font = ImageFont.truetype(str(font_path), 20) if font_path.is_file() else ImageFont.load_default()
    for index, (name, preview) in enumerate(preview_items):
        row, col = divmod(index, cols)
        x = col * cell_w + 10
        y = row * cell_h + 10
        sheet.paste(preview, (x, y))
        draw.text((x + 8, y + 322), f"{index + 1:02d}  {name}  {CHINESE[name]}", fill="black", font=label_font)
    sheet.save(OUT / "contact_sheet.png")

    print(f"wrote {len(records)} demo candidates to {OUT}")
    for record in records:
        print(f"  {record['number']} {record['code']:5s} {record['chinese']}  CRC={record['frame_crc']}")
    print(f"contact sheet: {OUT / 'contact_sheet.png'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
