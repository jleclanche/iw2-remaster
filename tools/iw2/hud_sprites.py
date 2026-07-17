"""Extract the HUD sprite-atlas geometry table from iwar2.dll.

The table (95+ entries, 36 bytes each) lives in BSS at 0x101741b0 and is
filled by a static initializer at 0x100e6c60: one call to the entry ctor
FUN_100ee6b0(this, px, py, w, h, ax, ay, texId) per sprite, followed by a
``rep movsd`` copying the 9 dwords into the table. The ctor stores::

    +0x00 w   +0x04 h   +0x08 ax   +0x0c ay          (pixels)
    +0x10 u0 = px/256   +0x14 v0 = py/256
    +0x18 u1 = (px+w)/256  +0x1c v1 = (py+h)/256     (_DAT_1011dc78 = 1/256)
    +0x20 texture id (0 = sprites.png, 1 = lcd, 2 = reticle.png, 3 = tri.png)

This script walks the initializer's disassembly, pairs each ctor call's
7 immediate pushes with the following ``rep movsd`` destination, and writes
data/json/hud_sprites.json keyed by sprite index. The drawer FUN_100e9de0
(iwar2.dll.c:180678) consumes the table: quad centred at (x,y) offset by
the anchor, flip bit0 = mirror X, bit1 = mirror Y.

Usage:  python -m tools.iw2.hud_sprites
"""

from __future__ import annotations

import json
import struct
import subprocess
import sys
from pathlib import Path

DLL = "build/bin/iwar2.dll"
INIT_VA = "0x100e6c60"
CTOR_VA = "0x100ee6b0"
TABLE_VA = 0x101741B0
UV_SCALE = 0.00390625  # _DAT_1011dc78 = 1/256


def as_float(v: int) -> float:
    return struct.unpack("<f", struct.pack("<I", v & 0xFFFFFFFF))[0]


def main(out_path: str = "data/json/hud_sprites.json") -> None:
    out = subprocess.run(
        [sys.executable, "tools/ghidra/disasm.py", DLL, INIT_VA, "+0x3000"],
        capture_output=True, text=True, check=True).stdout
    pushes: list[int] = []
    cur = None
    dst = None
    entries: dict[int, dict] = {}
    for line in out.splitlines():
        parts = line.split(None, 1)
        if len(parts) < 2:
            continue
        addr = int(parts[0], 16)
        ins = parts[1].strip()
        if ins.startswith("push"):
            arg = ins.split()[1]
            try:
                pushes.append(int(arg, 0))
            except ValueError:
                pass  # register pushes don't carry sprite data
        elif ins.startswith("call") and CTOR_VA in ins:
            cur = pushes[-7:]
            pushes = []
        elif ins.startswith("mov") and "edi, 0x" in ins:
            dst = int(ins.split(", ")[1], 16)
        elif ins.startswith("rep movsd") and cur is not None and dst is not None:
            ay, ax, h, w, py, px = [as_float(v) for v in cur[1:]]
            idx = (dst - TABLE_VA) // 36
            entries[idx] = {
                "px": px, "py": py, "w": w, "h": h, "ax": ax, "ay": ay,
                "u0": px * UV_SCALE, "v0": py * UV_SCALE,
                "u1": (px + w) * UV_SCALE, "v1": (py + h) * UV_SCALE,
                # the texture id is pushed as a raw small int (a denormal if
                # read as float) -- keep the dword
                "tex": cur[0] & 0xFFFFFFFF,
            }
            cur = None
            dst = None
        elif ins.startswith("ret") and addr > 0x100E6D00:
            break
    dest = Path(out_path)
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_text(json.dumps(
        {str(k): entries[k] for k in sorted(entries)}, indent=1))
    print(f"wrote {dest}: {len(entries)} sprites")


if __name__ == "__main__":
    main(*sys.argv[1:])
