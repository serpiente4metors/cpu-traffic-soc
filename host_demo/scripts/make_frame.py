#!/usr/bin/env python3
"""Convert one image into the UART frame expected by final soc.

The FPGA does not decode JPEG/PNG. This tool converts the image using the
same preprocessing as the integrated NpuNet model:

    RGB -> bilinear resize to 32x32
        -> (pixel / 255 - 0.5) / 0.5
        -> divide by input_scale, round, clamp [-127, 127]
        -> signed int8 bytes in HWC order

The resulting frame is:

    IMG
    48 lines x 128 lowercase hex characters
    CRC=xxxx

All paths default to this host_demo directory, so the tool works regardless
of the current working directory.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any

from PIL import Image

HOST_DEMO = Path(__file__).resolve().parents[1]
DEFAULT_REPORT = HOST_DEMO / "config" / "quant_report.json"
DEFAULT_OUT = HOST_DEMO / "output" / "frame.txt"
IMAGE_BYTES = 32 * 32 * 3
LINES = 48
LINE_BYTES = 64


def load_input_scale(report_path: str | Path) -> float:
    path = Path(report_path).expanduser().resolve()
    with path.open("r", encoding="utf-8") as f:
        report = json.load(f)
    scale = float(report["input_scale"])
    if not scale > 0:
        raise ValueError(f"invalid input_scale in {path}: {scale}")
    return scale


def quantize_image(image_path: str | Path, input_scale: float) -> bytes:
    path = Path(image_path).expanduser().resolve()
    if not path.is_file():
        raise FileNotFoundError(f"image not found: {path}")

    image = Image.open(path).convert("RGB")
    image = image.resize((32, 32), Image.Resampling.BILINEAR)
    out = bytearray()

    for y in range(32):
        for x in range(32):
            r, g, b = image.getpixel((x, y))
            for pixel in (r, g, b):
                normalized = (pixel / 255.0 - 0.5) / 0.5
                quantized = int(round(normalized / input_scale))
                quantized = max(-127, min(127, quantized))
                out.append(quantized & 0xFF)

    if len(out) != IMAGE_BYTES:
        raise RuntimeError(f"internal error: expected {IMAGE_BYTES} bytes, got {len(out)}")
    return bytes(out)


def encode_frame(image_bytes: bytes) -> tuple[str, int]:
    if len(image_bytes) != IMAGE_BYTES:
        raise ValueError(f"expected {IMAGE_BYTES} image bytes, got {len(image_bytes)}")

    lines = ["IMG"]
    for line_number in range(LINES):
        chunk = image_bytes[line_number * LINE_BYTES:(line_number + 1) * LINE_BYTES]
        lines.append("".join(f"{value:02x}" for value in chunk))

    crc = sum(image_bytes) & 0xFFFF
    lines.append(f"CRC={crc:04x}")
    return "\n".join(lines) + "\n", crc


def _write_chunks(frame: str, out_path: Path, lines_per_chunk: int) -> Path:
    target = out_path.with_name(out_path.stem + "_chunks")
    target.mkdir(parents=True, exist_ok=True)

    frame_lines = frame.splitlines()
    data_lines = frame_lines[1:-1]
    crc_line = frame_lines[-1]

    (target / "00_header.txt").write_text("IMG\n", encoding="ascii", newline="\n")
    number = 0
    for index in range(0, len(data_lines), lines_per_chunk):
        number += 1
        part = data_lines[index:index + lines_per_chunk]
        (target / f"{number:02d}.txt").write_text(
            "\n".join(part) + "\n", encoding="ascii", newline="\n"
        )
    (target / f"{number + 1:02d}_crc.txt").write_text(
        crc_line + "\n", encoding="ascii", newline="\n"
    )
    return target


def _write_line_files(frame: str, out_path: Path) -> Path:
    target = out_path.with_name(out_path.stem + "_lines")
    target.mkdir(parents=True, exist_ok=True)

    frame_lines = frame.splitlines()
    data_lines = frame_lines[1:-1]
    crc_line = frame_lines[-1]

    (target / "00_img.txt").write_text("IMG\n", encoding="ascii", newline="\n")
    for number, line in enumerate(data_lines, start=1):
        (target / f"{number:02d}.txt").write_text(
            line + "\n", encoding="ascii", newline="\n"
        )
    (target / f"{len(data_lines) + 1:02d}_crc.txt").write_text(
        crc_line + "\n", encoding="ascii", newline="\n"
    )
    (target / "README.txt").write_text(
        "Paste in order: 00_img, 01..48, 49_crc.\n",
        encoding="ascii",
        newline="\n",
    )
    return target


def generate_frame(
    image_path: str | Path,
    out_path: str | Path = DEFAULT_OUT,
    report_path: str | Path = DEFAULT_REPORT,
    lines_per_chunk: int = 8,
) -> dict[str, Any]:
    if lines_per_chunk <= 0:
        raise ValueError("lines_per_chunk must be positive")

    output = Path(out_path).expanduser().resolve()
    output.parent.mkdir(parents=True, exist_ok=True)

    scale = load_input_scale(report_path)
    image_bytes = quantize_image(image_path, scale)
    frame, crc = encode_frame(image_bytes)
    frame_data = frame.encode("ascii")
    if len(frame_data) != 6205:
        raise RuntimeError(f"internal error: frame must be 6205 bytes, got {len(frame_data)}")

    output.write_bytes(frame_data)
    chunks_dir = _write_chunks(frame, output, lines_per_chunk)
    lines_dir = _write_line_files(frame, output)

    return {
        "image": str(Path(image_path).expanduser().resolve()),
        "report": str(Path(report_path).expanduser().resolve()),
        "input_scale": scale,
        "frame": str(output),
        "frame_bytes": len(frame_data),
        "image_bytes": len(image_bytes),
        "crc": f"{crc:04x}",
        "chunks": str(chunks_dir),
        "lines": str(lines_dir),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Image -> final soc UART ASCII frame")
    parser.add_argument("image", help="JPG/PNG/BMP image path")
    parser.add_argument("--out", default=str(DEFAULT_OUT), help="full frame output path")
    parser.add_argument("--report", default=str(DEFAULT_REPORT), help="quant_report.json path")
    parser.add_argument("--chunks", type=int, default=8, help="data lines per chunk")
    args = parser.parse_args()

    result = generate_frame(args.image, args.out, args.report, args.chunks)
    print(f"image : {result['image']}")
    print(f"scale : {result['input_scale']:.12f}")
    print(f"bytes : {result['image_bytes']}")
    print(f"CRC   : {result['crc']}")
    print(f"frame : {result['frame']} ({result['frame_bytes']} bytes)")
    print(f"chunks: {result['chunks']}")
    print(f"lines : {result['lines']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())