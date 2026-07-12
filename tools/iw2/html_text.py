"""Extract the game's html/ tree (prison dossiers, emails, encyclopedia —
the original's own screen UI) to data/html, transcoded Latin-1 -> UTF-8
so the engine can read it with plain UTF-8 text APIs.

Usage:  python -m tools.iw2.html_text [out_dir]
"""

from __future__ import annotations

import sys
from pathlib import Path

from .resources import ResourceFS


def main(out_dir: str = "data/html") -> None:
    fs = ResourceFS()
    out = Path(out_dir)
    n = 0
    for path in fs.list("html/", ".html"):
        text = fs.read_bytes(path).decode("latin-1")
        dest = out / Path(path[len("html/"):])
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_text(text, encoding="utf-8")
        n += 1
    print(f"extracted {n} html pages to {out}")


if __name__ == "__main__":
    main(*sys.argv[1:])
