"""Batch-convert IW2 FTEX textures (.ftc compressed / .ftu uncompressed) to PNG.

Decoding is handled by Pillow's built-in FtexImagePlugin, which was written
for exactly this game.

Usage:  python -m tools.iw2.textures [output_dir]
"""

from __future__ import annotations

import io
import sys
from pathlib import Path

from PIL import Image

from .resources import ResourceFS


def main(out_dir: str = "data/textures") -> None:
    fs = ResourceFS()
    out = Path(out_dir)
    ok = 0
    failed: list[tuple[str, str]] = []
    ftu = fs.list("", ".ftu")
    have_ftu = {p[:-4] for p in ftu}
    # many textures ship in both formats; prefer lossless .ftu over DXT .ftc
    paths = ftu + [p for p in fs.list("", ".ftc") if p[:-4] not in have_ftu]
    for path in paths:
        try:
            img = Image.open(io.BytesIO(fs.read_bytes(path)))
            dest = out / Path(path).with_suffix(".png")
            dest.parent.mkdir(parents=True, exist_ok=True)
            img.save(dest)
            ok += 1
        except Exception as exc:
            failed.append((path, str(exc)))
    print(f"converted {ok}/{len(paths)}")
    if failed:
        log = out / "_failed.txt"
        log.write_text("\n".join(f"{p}\t{e}" for p, e in failed), encoding="utf-8")
        print(f"{len(failed)} failures logged to {log}")
        for p, e in failed[:10]:
            print(f"  FAIL {p}: {e}")


if __name__ == "__main__":
    main(*sys.argv[1:])
