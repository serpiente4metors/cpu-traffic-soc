#!/usr/bin/env python3
"""One-shot Windows demo runner for final soc.

No Tkinter is used, so this works with the local Codex Python runtime. The
native Windows file picker selects an image, the frame is generated, and the
user can launch the 50-part clipboard sender after the board prints READY.
"""
from __future__ import annotations

import ctypes
import os
import subprocess
import sys
from ctypes import wintypes
from pathlib import Path

from PIL import Image

HOST_DEMO = Path(__file__).resolve().parent
SCRIPTS = HOST_DEMO / "scripts"
sys.path.insert(0, str(SCRIPTS))

from make_frame import DEFAULT_OUT, DEFAULT_REPORT, generate_frame  # noqa: E402

OFN_FILEMUSTEXIST = 0x00001000
OFN_PATHMUSTEXIST = 0x00000800
OFN_NOCHANGEDIR = 0x00000008


class OpenFileNameW(ctypes.Structure):
    _fields_ = [
        ("lStructSize", wintypes.DWORD),
        ("hwndOwner", wintypes.HWND),
        ("hInstance", wintypes.HINSTANCE),
        ("lpstrFilter", wintypes.LPCWSTR),
        ("lpstrCustomFilter", wintypes.LPWSTR),
        ("nMaxCustFilter", wintypes.DWORD),
        ("nFilterIndex", wintypes.DWORD),
        ("lpstrFile", wintypes.LPWSTR),
        ("nMaxFile", wintypes.DWORD),
        ("lpstrFileTitle", wintypes.LPWSTR),
        ("nMaxFileTitle", wintypes.DWORD),
        ("lpstrInitialDir", wintypes.LPCWSTR),
        ("lpstrTitle", wintypes.LPCWSTR),
        ("Flags", wintypes.DWORD),
        ("nFileOffset", wintypes.WORD),
        ("nFileExtension", wintypes.WORD),
        ("lpstrDefExt", wintypes.LPCWSTR),
        ("lCustData", wintypes.LPARAM),
        ("lpfnHook", wintypes.LPVOID),
        ("lpTemplateName", wintypes.LPCWSTR),
        ("pvReserved", wintypes.LPVOID),
        ("dwReserved", wintypes.DWORD),
        ("FlagsEx", wintypes.DWORD),
    ]


def choose_image() -> Path | None:
    if os.name != "nt":
        raw = input("Image path: ").strip().strip('"')
        return Path(raw).expanduser().resolve() if raw else None

    buffer = ctypes.create_unicode_buffer(32768)
    dialog = OpenFileNameW()
    dialog.lStructSize = ctypes.sizeof(OpenFileNameW)
    dialog.lpstrFilter = (
        "Image files (*.png;*.jpg;*.jpeg;*.bmp)\0"
        "*.png;*.jpg;*.jpeg;*.bmp\0"
        "All files (*.*)\0*.*\0\0"
    )
    dialog.lpstrFile = ctypes.cast(buffer, wintypes.LPWSTR)
    dialog.nMaxFile = len(buffer)
    dialog.lpstrTitle = "Select a cropped traffic-sign image"
    dialog.lpstrDefExt = "png"
    dialog.Flags = OFN_FILEMUSTEXIST | OFN_PATHMUSTEXIST | OFN_NOCHANGEDIR

    comdlg32 = ctypes.windll.comdlg32
    comdlg32.GetOpenFileNameW.argtypes = [ctypes.POINTER(OpenFileNameW)]
    comdlg32.GetOpenFileNameW.restype = wintypes.BOOL
    if not comdlg32.GetOpenFileNameW(ctypes.byref(dialog)):
        return None
    return Path(buffer.value).resolve()


def save_model_preview(image_path: Path) -> Path:
    output = HOST_DEMO / "output" / "model_input_32x32.png"
    output.parent.mkdir(parents=True, exist_ok=True)
    image = Image.open(image_path).convert("RGB").resize(
        (32, 32), Image.Resampling.BILINEAR
    ).resize((320, 320), Image.Resampling.NEAREST)
    image.save(output)
    return output


def main() -> int:
    print("=" * 64)
    print(" maxcpu final soc - traffic-sign image -> UART frame")
    print("=" * 64)
    print("Board workflow before sending:")
    print("  1. web serial: type start + Enter")
    print("  2. web serial: type 2 + Enter")
    print("  3. wait until READY is printed")
    print()

    image_path = choose_image()
    if image_path is None:
        print("No image selected. Exit.")
        return 1
    if not image_path.is_file():
        print(f"Image not found: {image_path}")
        return 1

    print(f"Image: {image_path}")
    try:
        result = generate_frame(image_path, DEFAULT_OUT, DEFAULT_REPORT, lines_per_chunk=8)
        preview = save_model_preview(image_path)
    except Exception as exc:
        print(f"Frame generation failed: {exc}")
        return 1

    print()
    print(f"Frame : {result['frame']}")
    print(f"Bytes : {result['frame_bytes']} (expected 6205)")
    print(f"CRC   : {result['crc']}")
    print(f"Lines : {result['lines']}")
    print(f"Model input preview: {preview}")
    print()
    print("The model is a 20-class classifier. Use an already-cropped sign image.")
    print("The FPGA performs inference; Python only creates and sends bytes.")
    print()

    answer = input(
        "If the serial terminal shows READY, press Enter to start auto-paste; "
        "type q to stop: "
    ).strip().lower()
    if answer == "q":
        print("Stopped before sending.")
        return 0

    auto_paste = SCRIPTS / "auto_paste.py"
    print()
    print("Click the serial terminal input box within the next 5 seconds.")
    completed = subprocess.run(
        [
            sys.executable,
            str(auto_paste),
            "--dir", result["lines"],
            "--start-delay", "5",
            "--delay-ms", "700",
        ],
        cwd=str(HOST_DEMO),
        check=False,
    )
    if completed.returncode != 0:
        print("Automatic paste failed. See the error above.")
        return completed.returncode

    print()
    print("Frame sent. Wait for the recognition result and DONE in the web terminal.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())