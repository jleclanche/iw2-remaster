"""Extract audio WAVs from resource.zip to data/audio (music MP3s stay in
the game's streams/ dir and are loaded from there directly).

Usage:  python -m tools.iw2.audio [out_dir]
"""

from __future__ import annotations

import sys
from pathlib import Path

from .resources import ResourceFS


def main(out_dir: str = "data/audio") -> None:
    fs = ResourceFS()
    out = Path(out_dir)
    n = 0
    for path in fs.list("audio/", ".wav") + fs.list("", ".wav"):
        dest = out / Path(path)
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_bytes(fs.read_bytes(path))
        n += 1
    print(f"extracted {n} wavs to {out}")


if __name__ == "__main__":
    main(*sys.argv[1:])
