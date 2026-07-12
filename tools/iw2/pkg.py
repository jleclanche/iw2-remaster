"""Extract IW2 POG script packages (packages/*.pkg).

IFF ``FORM PKG``:
    PKHD  package name (NUL-str) + u32 version-ish
    ITAB  u32 import count
    PIMP  imported package name + u32 function count (its FIMPs follow)
    FIMP  imported function name + u32 call count + u32be[] CODE offsets
          of every call site
    ETAB  u32 export count
    FEXP  exported function name + u32 CODE entry offset
    STAB  u32 count + NUL-separated string table (globals, sim/template
          names, localisation keys used by the script)
    CODE  POG VM bytecode

We do not run the VM; instead we emit, per package, the imports grouped
by API package, the exports, the string table, and an offset-ordered
CALL TRACE (which API functions the script invokes, in code order) —
enough to reconstruct mission logic by hand alongside the localized
dialogue/objective strings.

Usage:  python -m tools.iw2.pkg [out_dir]
"""

from __future__ import annotations

import json
import struct
import sys
from pathlib import Path

from .resources import ResourceFS


def _nulstr(body: bytes) -> tuple[str, int]:
    end = body.index(b"\x00")
    return body[:end].decode("latin-1"), end + 1


def parse_pkg(data: bytes) -> dict:
    assert data[:4] == b"FORM" and data[8:12] == b"PKG "
    off = 12
    pkg: dict = {"imports": {}, "exports": {}, "strings": [], "calls": []}
    cur_pkg = None
    while off + 8 <= len(data):
        tag = data[off:off + 4]
        (size,) = struct.unpack_from(">I", data, off + 4)
        body = data[off + 8: off + 8 + size]
        if tag == b"PKHD":
            pkg["name"], _ = _nulstr(body)
        elif tag == b"PIMP":
            cur_pkg, _ = _nulstr(body)
            pkg["imports"][cur_pkg] = []
        elif tag == b"FIMP":
            name, p = _nulstr(body)
            (count,) = struct.unpack_from(">I", body, p)
            sites = struct.unpack_from(f">{count}I", body, p + 4)
            target = cur_pkg if cur_pkg else "?"
            pkg["imports"].setdefault(target, []).append(name)
            for s in sites:
                pkg["calls"].append([s, f"{target}.{name}"])
        elif tag == b"FEXP":
            name, p = _nulstr(body)
            (entry,) = struct.unpack_from(">I", body, p)
            pkg["exports"][name] = entry
        elif tag == b"STAB":
            (count,) = struct.unpack_from(">I", body, 0)
            pkg["strings"] = [s.decode("latin-1")
                              for s in body[4:].split(b"\x00") if s][:count]
        elif tag == b"CODE":
            pkg["code_size"] = size
        off += 8 + size + (size & 1)
    pkg["calls"].sort()
    return pkg


def main(out_dir: str = "data/json/packages") -> None:
    fs = ResourceFS()
    out = Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)
    index = {}
    for path in fs.list("packages/", ".pkg"):
        try:
            pkg = parse_pkg(fs.read_bytes(path))
        except Exception as exc:
            print(f"FAIL {path}: {exc}")
            continue
        stem = Path(path).stem.lower()
        (out / f"{stem}.json").write_text(json.dumps(pkg, indent=1),
                                          encoding="utf-8")
        index[stem] = {"exports": list(pkg["exports"]),
                       "calls": len(pkg["calls"]),
                       "strings": len(pkg["strings"]),
                       "code": pkg.get("code_size", 0)}
    (out / "_index.json").write_text(json.dumps(index, indent=1),
                                     encoding="utf-8")
    print(f"extracted {len(index)} packages")


if __name__ == "__main__":
    main(*sys.argv[1:])
