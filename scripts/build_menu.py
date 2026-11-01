#!/usr/bin/env python3
"""Build the combined maxcpu menu firmware.

    python scripts/build_menu.py                 # final: CoreMark 4000 iters
    python scripts/build_menu.py --iters 1       # short simulation image
    python scripts/build_menu.py --out sw/menu.mem

The image is linked in this order:
    crt0 -> CoreMark -> menu/NPU
so the CoreMark code layout stays as close as possible to the
standalone coremark build.
"""
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TOOL = r"D:\study\project\riscv cpu\tools\riscv-gcc\xpack-riscv-none-elf-gcc-15.2.0-1\bin"
GCC = os.path.join(TOOL, "riscv-none-elf-gcc.exe")
OBJCOPY = os.path.join(TOOL, "riscv-none-elf-objcopy.exe")

COREMARK_SRCS = [
    "sw/coremark/core_main.c",
    "sw/coremark/core_list_join.c",
    "sw/coremark/core_matrix.c",
    "sw/coremark/core_state.c",
    "sw/coremark/core_util.c",
    "sw/coremark/core_portme.c",
    "sw/coremark/ee_printf.c",
]

MENU_SRCS = [
    "sw/menu/menu.c",
    "sw/menu/npu_infer.c",
]

COMMON = [
    "-march=rv32im_zicsr", "-mabi=ilp32",
    "-nostdlib", "-nostartfiles", "-ffreestanding",
    "-msmall-data-limit=0",
    "-O3", "-funroll-loops", "-finline-functions", "-ftracer", "-Wall",
    "-I", "sw/coremark",
    "-I", "sw/menu",
    "-I", "sw/npu_demo",
    "-Wl,--no-relax",
]


def run(cmd, what):
    r = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
    if r.returncode != 0:
        print("FAILED:", what)
        print(r.stdout[-5000:])
        print(r.stderr[-5000:])
        raise SystemExit(1)
    if r.stderr.strip():
        print("--- warnings:", what, "---")
        print(r.stderr.strip()[:3000])
    return r


def pack_bin_to_mem(bin_path, mem_out):
    data = open(bin_path, "rb").read()
    if len(data) % 8:
        data += b"\x00" * (8 - len(data) % 8)
    lines = ["%016X" % int.from_bytes(data[i:i + 8], "little")
             for i in range(0, len(data), 8)]
    with open(mem_out, "w", encoding="ascii") as f:
        f.write("\n".join(lines) + "\n")
    return len(data), len(lines)


def main():
    iters = 4000
    out_mem = "sw/menu.mem"
    pad = 0
    clk = 94500000
    args = sys.argv[1:]
    i = 0
    while i < len(args):
        if args[i] == "--iters":
            iters = int(args[i + 1]); i += 2
        elif args[i] == "--out":
            out_mem = args[i + 1]; i += 2
        elif args[i] == "--pad":
            pad = int(args[i + 1]); i += 2
        elif args[i] == "--clk":
            clk = int(args[i + 1]); i += 2
        else:
            print("unknown arg", args[i]); return 1

    build = os.path.join(ROOT, "build", "menu")
    os.makedirs(build, exist_ok=True)
    elf = os.path.join(build, "menu.elf")
    binf = os.path.join(build, "menu.bin")

    objs = []
    flags = COMMON + [
        "-DITERATIONS=%d" % iters,
        "-DCLOCKS_PER_SEC=%d" % clk,
    ]
    if pad:
        flags.append("-DLAYOUT_PAD=%d" % pad)

    # crt0: keep the same optional layout pad as the standalone build
    crt_obj = os.path.join(build, "crt0.o")
    run([GCC] + flags + ["-c", "sw/crt0.S", "-o", crt_obj], "crt0.S")
    objs.append(crt_obj)

    # CoreMark first; only core_main.c gets the main rename
    for src in COREMARK_SRCS:
        obj = os.path.join(build, os.path.basename(src).replace(".c", ".o"))
        extra = ["-Dmain=coremark_main"] if src.endswith("core_main.c") else []
        run([GCC] + flags + extra + ["-c", src, "-o", obj], src)
        objs.append(obj)

    # menu/NPU last
    for src in MENU_SRCS:
        obj = os.path.join(build, os.path.basename(src).replace(".c", ".o"))
        run([GCC] + flags + ["-c", src, "-o", obj], src)
        objs.append(obj)

    run([GCC] + flags + ["-T", "sw/link_c.ld", "-o", elf] + objs, "link")
    run([OBJCOPY, "-O", "binary", elf, binf], "objcopy")

    nbyte, nline = pack_bin_to_mem(binf, os.path.join(ROOT, out_mem))
    print("==> %s : %d bytes, %d lines (iters=%d)" % (out_mem, nbyte, nline, iters))
    if nbyte > 0x10000:
        print("!! ERROR: image %d > 0x10000, it would collide with the stack/NPU window" % nbyte)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())