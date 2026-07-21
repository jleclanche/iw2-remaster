"""Extract the engine's HUD sprite-cell table (issue #49).

The engine fills its sprite table (DAT_101741b0, stride 0x24) at startup in
FUN_100e6c60: each cell is built by a FUN_100ee6b0(x, y, w, h, origin_x,
origin_y, texture) call whose arguments are immediates, and the result is
copied into its slot by a `rep movsd` behind a `mov edi, DAT_101741b0 +
id*0x24`.  This walks that fill run with capstone, pairs every slot write
with the preceding call's pushed arguments, and emits the COMPLETE
id -> [x, y, w, h, ox, oy, tex] table -- replacing the part-eyeballed hand
dicts in hud.gd / hud_screens.gd as the authority (they stay as fallback and
as the per-id semantic documentation).

Self-check: slot 60 (the L-point icon) must decode to its independently
verified cell [231, 226, 24, 24, 12, 12]; the run aborts otherwise.

Usage (from repo root):
  <python> -m tools.iw2.spritetable
Writes  data/json/hud_sprites.json  and a labelled contact sheet
  build/hud_sprites_sheet.png  (texture-0 cells over images/hud/sprites.png).
"""

from __future__ import annotations

import json
import struct
import sys
from pathlib import Path

import capstone

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "ghidra"))
import disasm  # noqa: E402  (tools/ghidra/disasm.py: sections, va_to_off)

ROOT = Path(__file__).resolve().parents[2]
PE = ROOT / "build" / "bin" / "iwar2.dll"
BUILDER_VA = 0x100E6C60   # FUN_100e6c60, the table fill run
BUILDER_LEN = 0x3000      # generous; the walk stops at the final ret
CELL_CALL = 0x100EE6B0    # FUN_100ee6b0(x, y, w, h, ox, oy, tex)
TABLE_VA = 0x101741B0     # DAT_101741b0, stride 0x24
STRIDE = 0x24
# the texture pointer table the HUD ctor registers (0x10162c9c..):
# index n in a cell's `tex` field selects the n-th of these sheets
TEX_PTRS_VA = 0x10162C9C
TEX_COUNT = 4
KNOWN_GOOD = {60: [231, 226, 24, 24, 12, 12, 0]}


def _f32(v: int) -> float:
    return struct.unpack("<f", struct.pack("<I", v))[0]


def decode(data: bytes) -> dict[int, list[float]]:
    base, secs = disasm.sections(data)
    off, avail = disasm.va_to_off(base, secs, BUILDER_VA)
    code = data[off:off + min(BUILDER_LEN, avail)]
    md = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_32)
    md.detail = False
    pushes: list[float] = []
    last_call_args: list[float] | None = None
    cur_slot: int | None = None
    cells: dict[int, list[float]] = {}
    for insn in md.disasm(code, BUILDER_VA):
        if insn.mnemonic == "push":
            tok = insn.op_str
            if tok.startswith("0x"):
                pushes.append(_f32(int(tok, 16)))
            elif tok.isdigit():
                pushes.append(float(tok))
            continue
        if insn.mnemonic == "mov" and insn.op_str.startswith("edi, 0x"):
            cur_slot = int(insn.op_str.split(", ")[1], 16)
            continue
        if "movsd" in insn.mnemonic and cur_slot is not None \
                and last_call_args is not None:
            slot = cur_slot - TABLE_VA
            if slot % STRIDE == 0 and slot >= 0:
                cells[slot // STRIDE] = last_call_args
            cur_slot = None
            continue
        if insn.mnemonic == "call" and insn.op_str == hex(CELL_CALL):
            last_call_args = list(reversed(pushes[-7:]))
            pushes = []
            continue
        if insn.mnemonic == "ret":
            break
    return cells


def texture_names(data: bytes) -> list[str]:
    base, secs = disasm.sections(data)
    names = []
    for i in range(TEX_COUNT):
        off, _ = disasm.va_to_off(base, secs, TEX_PTRS_VA + i * 4)
        ptr = struct.unpack_from("<I", data, off)[0]
        soff, _ = disasm.va_to_off(base, secs, ptr)
        s = data[soff:data.index(b"\0", soff)].decode()
        names.append(s.removeprefix("texture:/"))
    return names


def contact_sheet(cells: dict[int, list[int]], out: Path) -> None:
    from PIL import Image, ImageDraw

    atlas = Image.open(
        ROOT / "data" / "textures" / "images" / "hud" / "sprites.png"
    ).convert("RGB")
    sheet = atlas.resize((atlas.width * 3, atlas.height * 3), Image.NEAREST)
    d = ImageDraw.Draw(sheet)
    for i, c in sorted(cells.items()):
        if int(c[6]) != 0:
            continue
        x, y, w, h = (int(c[0]) * 3, int(c[1]) * 3, int(c[2]) * 3,
                      int(c[3]) * 3)
        d.rectangle([x, y, x + w - 1, y + h - 1], outline=(255, 64, 64))
        d.text((x + 2, y + 1), str(i), fill=(64, 255, 64))
    out.parent.mkdir(parents=True, exist_ok=True)
    sheet.save(out)


def main() -> None:
    data = PE.read_bytes()
    raw = decode(data)
    cells = {i: [int(v) for v in args] for i, args in sorted(raw.items())}
    for i, want in KNOWN_GOOD.items():
        got = cells.get(i)
        if got != want:
            raise SystemExit(
                "self-check FAILED: slot %d decoded %r, expected %r"
                % (i, got, want))
    out = {
        "source": "iwar2.dll FUN_100e6c60 (tools/iw2/spritetable.py)",
        "textures": texture_names(data),
        "cells": {str(i): c for i, c in cells.items()},
    }
    dest = ROOT / "data" / "json" / "hud_sprites.json"
    dest.write_text(json.dumps(out, indent=1))
    print("wrote %s: %d cells, textures %s"
          % (dest, len(cells), out["textures"]))
    contact_sheet(cells, ROOT / "build" / "hud_sprites_sheet.png")
    print("wrote build/hud_sprites_sheet.png")


if __name__ == "__main__":
    main()
