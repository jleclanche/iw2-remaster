"""Extract the game's HTML pages to data/, transcoded Latin-1 -> UTF-8
so the engine can read it with plain UTF-8 text APIs.  Two trees carry them:

* ``html/``  -- prison dossiers, encyclopedia, credits, generated-mission mail
* ``text/``  -- the story emails (``text/act_*/**.html``), the bodies that
  ``iemail.SendEmail``'s ``html:/text/...`` URLs point at

Usage:  python -m tools.iw2.html_text [out_dir]
"""

from __future__ import annotations

import sys
from pathlib import Path

from .resources import ResourceFS


def main(out_dir: str = "data") -> None:
    fs = ResourceFS()
    out = Path(out_dir)
    n = 0
    for prefix in ("html/", "text/"):
        for path in fs.list(prefix, ".html"):
            text = fs.read_bytes(path).decode("latin-1")
            dest = out / Path(path)
            dest.parent.mkdir(parents=True, exist_ok=True)
            dest.write_text(text, encoding="utf-8")
            n += 1
    print(f"extracted {n} html pages to {out}")


if __name__ == "__main__":
    main(*sys.argv[1:])
