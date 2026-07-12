"""Export POG packages into a VM-ready form for the Godot runtime.

The shipped .pkg is an IFF FORM with the imports left *unresolved*: the
compiler emits `Call 0 0 argc` and the engine's loader patches operands 0
and 1 from the FIMP call-site tables (and rewrites the opcode to the
native variant when the import turns out to be a DLL package).

We do that resolution here, at extraction, rather than in the game: each
call site is written out as a plain "pkg.Func" name, so the runtime never
has to touch the IFF container or the patch tables.

Output (data/pog/, gitignored like every other extracted asset):
    <name>.json     strings, exports, call-site -> name, base64 code
    manifest.json   package list + which imports are native (no bytecode)

Usage:
    python -m tools.iw2.pogexport
"""

from __future__ import annotations

import base64
import json
import pathlib

from .pogdis import decode, parse_pkg
from .resources import ResourceFS

ROOT = pathlib.Path(__file__).resolve().parents[2]
OUT = ROOT / "data" / "pog"

# Opcodes whose call site is resolved through the FIMP tables.
_IMPORT_OPS = {"Call", "Start"}


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    fs = ResourceFS()
    names: list[str] = []
    imported: set[str] = set()

    for path in fs.list("packages/", ".pkg"):
        pkg = parse_pkg(fs.read_bytes(path))
        stem = pathlib.Path(path).stem.lower()
        names.append(stem)

        # call-site offset -> "pkg.Func", for every imported Call/Start
        imports: dict[str, str] = {}
        for off, mn, _args in decode(pkg["code"]):
            if mn in _IMPORT_OPS:
                target = pkg["call_sites"].get(off)
                if target:
                    imports[str(off)] = target
                    imported.add(target.split(".", 1)[0].lower())

        (OUT / f"{stem}.json").write_text(json.dumps({
            "name": pkg["name"],
            "strings": pkg["strings"],
            "exports": pkg["exports"],
            "imports": imports,
            "code": base64.b64encode(pkg["code"]).decode("ascii"),
        }), encoding="utf-8")

    have = set(names)
    native = sorted(p for p in imported if p not in have)
    (OUT / "manifest.json").write_text(json.dumps({
        "packages": sorted(names),
        "native": native,
    }, indent=1), encoding="utf-8")

    print(f"exported {len(names)} packages -> {OUT}")
    print(f"  {len(native)} native packages must be provided by the engine:")
    print("  " + " ".join(native))


if __name__ == "__main__":
    main()
