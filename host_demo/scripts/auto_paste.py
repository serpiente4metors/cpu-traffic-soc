#!/usr/bin/env python3
"""Paste frame_lines/*.txt into the focused remote serial terminal.

This helper uses only the Windows standard library. It does not open a COM
port: the browser/web terminal keeps its existing serial connection, while
this script pastes through the clipboard and presses Enter after every file.

Run it only after the final-soc firmware has printed READY:

    start
    2
    READY
    <start this tool and click the terminal input box during the countdown>
"""
from __future__ import annotations

import argparse
import ctypes
import os
import sys
import time
from pathlib import Path

HOST_DEMO = Path(__file__).resolve().parents[1]
DEFAULT_DIR = HOST_DEMO / "output" / "frame_lines"

if os.name != "nt":
    raise SystemExit("auto_paste.py currently supports Windows only")

CF_UNICODETEXT = 13
GMEM_MOVEABLE = 0x0002
VK_CONTROL = 0x11
VK_V = 0x56
VK_RETURN = 0x0D
KEYEVENTF_KEYUP = 0x0002

user32 = ctypes.windll.user32
kernel32 = ctypes.windll.kernel32

user32.OpenClipboard.argtypes = [ctypes.c_void_p]
user32.OpenClipboard.restype = ctypes.c_bool
user32.EmptyClipboard.restype = ctypes.c_bool
user32.CloseClipboard.restype = ctypes.c_bool
user32.SetClipboardData.argtypes = [ctypes.c_uint, ctypes.c_void_p]
user32.SetClipboardData.restype = ctypes.c_void_p
kernel32.GlobalAlloc.argtypes = [ctypes.c_uint, ctypes.c_size_t]
kernel32.GlobalAlloc.restype = ctypes.c_void_p
kernel32.GlobalLock.argtypes = [ctypes.c_void_p]
kernel32.GlobalLock.restype = ctypes.c_void_p
kernel32.GlobalUnlock.argtypes = [ctypes.c_void_p]
kernel32.GlobalUnlock.restype = ctypes.c_bool


def set_clipboard(text: str) -> None:
    data = text.encode("utf-16-le") + b"\x00\x00"
    opened = False
    for _ in range(40):
        if user32.OpenClipboard(None):
            opened = True
            break
        time.sleep(0.05)
    if not opened:
        raise RuntimeError("OpenClipboard failed; another application is locking the clipboard")

    try:
        if not user32.EmptyClipboard():
            raise RuntimeError("EmptyClipboard failed")
        handle = kernel32.GlobalAlloc(GMEM_MOVEABLE, len(data))
        if not handle:
            raise RuntimeError("GlobalAlloc failed")
        pointer = kernel32.GlobalLock(handle)
        if not pointer:
            raise RuntimeError("GlobalLock failed")
        ctypes.memmove(pointer, data, len(data))
        kernel32.GlobalUnlock(handle)
        if not user32.SetClipboardData(CF_UNICODETEXT, handle):
            raise RuntimeError("SetClipboardData failed")
    finally:
        user32.CloseClipboard()


def tap(vk: int) -> None:
    user32.keybd_event(vk, 0, 0, 0)
    time.sleep(0.02)
    user32.keybd_event(vk, 0, KEYEVENTF_KEYUP, 0)


def paste_and_enter(delay_ms: int, key_delay_ms: int) -> None:
    user32.keybd_event(VK_CONTROL, 0, 0, 0)
    time.sleep(key_delay_ms / 1000.0)
    tap(VK_V)
    time.sleep(key_delay_ms / 1000.0)
    user32.keybd_event(VK_CONTROL, 0, KEYEVENTF_KEYUP, 0)
    time.sleep(key_delay_ms / 1000.0)
    tap(VK_RETURN)
    time.sleep(delay_ms / 1000.0)


def resolve_frame_dir(value: str) -> Path:
    path = Path(value).expanduser()
    if not path.is_absolute():
        path = HOST_DEMO / path
    return path.resolve()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--dir", default=str(DEFAULT_DIR), help="folder with 00_img.txt ... 49_crc.txt")
    parser.add_argument("--delay-ms", type=int, default=700, help="wait after each Enter")
    parser.add_argument("--start-delay", type=int, default=5, help="countdown before first paste")
    parser.add_argument("--dry-run", action="store_true", help="only validate and print file order")
    args = parser.parse_args()

    folder = resolve_frame_dir(args.dir)
    if not folder.is_dir():
        print(f"missing frame_lines folder: {folder}", file=sys.stderr)
        print("Generate a frame first with make_frame.py or START_HERE.bat.", file=sys.stderr)
        return 2

    files = sorted(p for p in folder.glob("*.txt") if p.name.lower() != "readme.txt")
    if len(files) != 50:
        print(f"expected 50 frame files, found {len(files)} in {folder}", file=sys.stderr)
        for path in files:
            print(f"  {path.name}", file=sys.stderr)
        return 2

    print(f"folder: {folder}")
    print(f"files : {len(files)}  first: {files[0].name}  last: {files[-1].name}")
    if args.dry_run:
        for path in files:
            print(f"would paste+Enter: {path.name}")
        return 0

    print()
    print("Click the web serial terminal input box NOW.")
    print(f"Pasting starts in {args.start_delay} seconds...")
    for remaining in range(args.start_delay, 0, -1):
        print(f"  {remaining}...", flush=True)
        time.sleep(1)

    for number, path in enumerate(files, start=1):
        set_clipboard(path.read_text(encoding="ascii"))
        paste_and_enter(args.delay_ms, 200)
        print(f"[{number:2d}/{len(files)}] {path.name}", flush=True)

    print()
    print("Frame sent. Wait for the recognition result and DONE in the web terminal.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())