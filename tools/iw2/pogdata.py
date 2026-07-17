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

import csv
import io
import pathlib

from .resources import ResourceFS

ROOT = pathlib.Path(__file__).resolve().parents[2]
DATA = ROOT / "data"


def _repair_line(line: str) -> str:
    """Fix a data line with an odd number of quotes (four ship: three stray
    trailing-quote runs -- `undock now.""`, `La Campanas\"\"\"` twice -- and
    input.csv's never-closed `"Hat Right`). Trim the end-of-line quote run to
    one closing quote if the last field opened with a quote, to nothing if it
    did not; a field still left open is closed at end-of-line."""
    stripped = line.rstrip('"')
    head = stripped.rsplit(",", 1)[-1].lstrip()
    if len(stripped) < len(line):
        keep = 1 if head.startswith('"') and stripped.count('"') % 2 else 0
        line = stripped + '"' * keep
    if line.count('"') % 2:
        line += '"'
    return line


def _parse_fields(line: str) -> list[str]:
    """Split one data line the way the game's own reader did.

    Strict CSV cannot express the shipped tables: they put whitespace between
    the comma and the opening quote (`key, "value, with commas"` -- a strict
    reader sees an UNQUOTED field and splits the value at its first comma,
    truncating 894 dialogue lines), a tab in input.csv (`,\\t"^"`), and junk
    after a closing quote. Skip field-leading whitespace, honour quotes with
    "" escapes, drop anything between a closing quote and the next comma.
    """
    fields: list[str] = []
    i, n = 0, len(line)
    while True:
        while i < n and line[i] in " \t":
            i += 1
        if i < n and line[i] == '"':
            i += 1
            buf: list[str] = []
            while i < n:
                if line[i] == '"':
                    if i + 1 < n and line[i + 1] == '"':
                        buf.append('"')
                        i += 2
                        continue
                    i += 1
                    break
                buf.append(line[i])
                i += 1
            while i < n and line[i] != ",":
                i += 1
            fields.append("".join(buf))
        else:
            j = line.find(",", i)
            j = n if j < 0 else j
            fields.append(line[i:j].strip())
            i = j
        if i >= n:
            return fields
        i += 1
        if i >= n:
            fields.append("")
            return fields


def _canon_line(line: str) -> str:
    """Re-emit one data line as strict CSV Godot's get_csv_line reads back."""
    row = _parse_fields(line)
    if not row:
        return line
    # doubled-quoted fields (`"""DirectX8"""`, `" ""INDIES VS CORPORATES"""`
    # -- 15 ship) still parse to a value wrapped in literal quotes; the
    # visible string has none (key_text_circumflex is the ^ key's label).
    # Strip one wrapping pair.
    out: list[str] = []
    for f in row:
        g = f.strip()
        if len(g) >= 2 and g[0] == '"' and g[-1] == '"':
            f = g[1:-1]
        out.append(f)
    buf = io.StringIO()
    csv.writer(buf, lineterminator="").writerow(out)
    return buf.getvalue()


def _clean_csv(text: str, rel: str) -> str:
    """Make the tables strict-CSV-clean.

    The engine's own reader (FcLocalisedText) was line-based and never parsed
    a comment, but a strict CSV reader (Godot's get_csv_line) sees gui.csv:74's
    stray quote inside a ';' comment open a quoted field that swallows every
    following key until the next stray quote (~280 lines lost). Comments are
    prose: drop their quotes. Data lines with unbalanced quotes (four shipped
    typos) are repaired to their obvious intent, then every data line is
    re-emitted as canonical CSV (see _canon_line).
    """
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    out = []
    for i, line in enumerate(text.split("\n"), 1):
        if line.lstrip().startswith(";"):
            line = line.replace('"', "'")
        else:
            if line.count('"') % 2:
                fixed = _repair_line(line)
                print(f"NOTE {rel}:{i}: repaired unbalanced quote:"
                      f" {line!r} -> {fixed!r}")
                line = fixed
            line = _canon_line(line)
        out.append(line)
    return "\n".join(out)


def _write(rel: str, raw: bytes, out_root: pathlib.Path) -> None:
    dst = out_root / rel
    dst.parent.mkdir(parents=True, exist_ok=True)
    # Latin-1 always decodes; the originals are cp1252-ish, and the only
    # non-ASCII in them is punctuation in the prose.
    text = raw.decode("utf-8-sig", errors="strict") \
        if raw[:3] == b"\xef\xbb\xbf" else raw.decode("latin-1")
    if rel.lower().endswith(".csv"):
        text = _clean_csv(text, rel)
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
