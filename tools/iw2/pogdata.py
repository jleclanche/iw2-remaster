"""Extract the data the POG scripts read at runtime: the INI tree and the CSVs.

Two native packages read files rather than the world:

  inifile.Create("ini:/sims/ships/utility/flitter")  -> the game's INI tree
  text.Add("csv:/text/act_1/act1_master")            -> the localised strings,
  text.Field(key, column)                               which every line of
                                                        dialogue comes out of

Both are shipped inside resource.zip, and both are Latin-1. We convert them to
UTF-8 here rather than teaching the runtime to cope with two encodings -- the
same rule as the rest of the pipeline: normalise at extraction, never patch at
runtime.

Output (gitignored, like every other extracted asset):
    data/ini/**.ini      779 files, mirroring the original paths
    data/text/**.csv     178 files

Usage:
    python -m tools.iw2.pogdata
"""

from __future__ import annotations

import pathlib

from .resources import ResourceFS

ROOT = pathlib.Path(__file__).resolve().parents[2]
DATA = ROOT / "data"


def _write(rel: str, raw: bytes, out_root: pathlib.Path) -> None:
    dst = out_root / rel
    dst.parent.mkdir(parents=True, exist_ok=True)
    # Latin-1 always decodes; the originals are cp1252-ish, and the only
    # non-ASCII in them is punctuation in the prose.
    text = raw.decode("utf-8-sig", errors="strict") \
        if raw[:3] == b"\xef\xbb\xbf" else raw.decode("latin-1")
    dst.write_text(text, encoding="utf-8", newline="\n")


def main() -> None:
    fs = ResourceFS()

    inis = fs.list("", ".ini")
    for rel in inis:
        _write(rel, fs.read_bytes(rel), DATA / "ini")

    # The CSV paths already begin with "text/", and that is exactly what
    # text.Add("csv:/text/...") asks for, so mirror them under data/ as-is.
    csvs = fs.list("", ".csv")
    for rel in csvs:
        _write(rel, fs.read_bytes(rel), DATA)

    print("extracted %d INI files -> %s" % (len(inis), DATA / "ini"))
    print("extracted %d CSV files -> %s" % (len(csvs), DATA / "text"))


if __name__ == "__main__":
    main()
