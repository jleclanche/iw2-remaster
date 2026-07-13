"""What the original game is MADE OF, and how much of it we have built.

`apicov.py` measures one axis: the POG native API. That is a real axis, but it
is not the only one, and measuring only what you instrumented is how you end up
never building the TRI screen.

The native census counts `Call <pkg>.<Func>` sites in the mission bytecode. So a
component the scripts rarely call is *invisible to it by construction*:
`icHUDStarmap` and `icHUDEngineering` generate almost no call sites, so a
call-weighted work queue will never surface them, however carefully you read it.
`ihud.CurrentMenuNode` shows up as 70 honest calls to an honest stub -- and
nothing anywhere says "the HUD element behind that binding does not exist".

The engine, however, registers every one of its classes by name:

    FcRegistry::RegisterClass(inst, "icHUDStarmap", "iiHUDOverlayElement",
                              factory, property_map)

That registry IS the inventory. 257 of them in iwar2.dll. This tool extracts it,
groups the classes by their base class (which is what tells you *what kind of
thing* each one is), and diffs it against what we have actually built -- so the
question "what is missing?" has an answer that does not depend on anyone
remembering to ask it.

We declare what we have built with a marker anywhere in game/scripts:

    # @element icHUDReticle          -- really implemented
    # @element-stub icHUDStarmap     -- deliberately not, with a reason

Same honesty rule as apicov: a stub is not an implementation, and the two are
counted separately.

Usage:
    python -m tools.iw2.featurecov                 # the whole inventory
    python -m tools.iw2.featurecov --base iiHUD    # one family
    python -m tools.iw2.featurecov --todo          # what is not built
"""

from __future__ import annotations

import argparse
import collections
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DECOMP = ROOT / "data" / "decomp"
SCRIPTS = ROOT / "game" / "scripts"

# The decompiler renders the registration as a run of pointer loads followed by
# the call. The class and its base are the two string pointers in that run.
_PTR = re.compile(r"PTR_s_(\w+?)_[0-9a-f]{8}")
_REG = re.compile(r"FcRegistry::RegisterClass")

_MARK = re.compile(r"#\s*@element\s+(\w+)")
_MARK_STUB = re.compile(r"#\s*@element-stub\s+(\w+)")


def inventory(binary: str = "iwar2.dll") -> dict[str, str]:
    """class name -> base class name, from the engine's own registry."""
    src = (DECOMP / ("%s.c" % binary)).read_text(encoding="utf-8",
                                                 errors="replace")
    out: dict[str, str] = {}
    lines = src.splitlines()
    for i, line in enumerate(lines):
        if not _REG.search(line):
            continue
        # walk back over the pointer loads that feed this call
        names: list[str] = []
        for j in range(max(0, i - 12), i + 1):
            for m in _PTR.finditer(lines[j]):
                n = m.group(1)
                if n not in names:
                    names.append(n)
        # the class is the first, its base the second; anything else is noise
        cls = next((n for n in names if n.startswith(("ic", "ii", "Fc", "Fi"))),
                   None)
        if cls is None:
            continue
        base = next((n for n in names[names.index(cls) + 1:]
                     if n.startswith(("ic", "ii", "Fc", "Fi"))), "?")
        out[cls] = base
    return out


def built() -> tuple[set[str], set[str]]:
    real: set[str] = set()
    stub: set[str] = set()
    if not SCRIPTS.is_dir():
        return real, stub
    for f in SCRIPTS.rglob("*.gd"):
        t = f.read_text(encoding="utf-8", errors="replace")
        real |= {m.group(1) for m in _MARK.finditer(t)}
        stub |= {m.group(1) for m in _MARK_STUB.finditer(t)}
    return real, stub - real


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", help="only classes whose base starts with this")
    ap.add_argument("--todo", action="store_true")
    args = ap.parse_args()

    inv = inventory()
    real, stub = built()

    fams: dict[str, list[str]] = collections.defaultdict(list)
    for cls, base in sorted(inv.items()):
        if args.base and not base.startswith(args.base):
            continue
        fams[base].append(cls)

    if args.todo:
        print("# registered by the engine, not built by us")
        for base in sorted(fams, key=lambda b: -len(fams[b])):
            missing = [c for c in fams[base] if c not in real and c not in stub]
            if missing:
                print("\n%s (%d)" % (base, len(missing)))
                for c in missing:
                    print("   " + c)
        return

    print("The engine registers %d classes. What we have built:\n" % len(inv))
    hdr = "%-28s %5s %5s %5s  %s" % ("base class", "total", "built", "stub",
                                     "coverage")
    print(hdr)
    print("-" * len(hdr))
    tb = ts = tt = 0
    for base in sorted(fams, key=lambda b: -len(fams[b])):
        cs = fams[base]
        b = sum(1 for c in cs if c in real)
        s = sum(1 for c in cs if c in stub)
        tb += b
        ts += s
        tt += len(cs)
        print("%-28s %5d %5d %5d  %6.0f%%"
              % (base, len(cs), b, s, 100.0 * b / len(cs)))
    print("\nTOTAL  %d/%d built (%.0f%%), %d stubbed, %d not started"
          % (tb, tt, 100.0 * tb / tt if tt else 0, ts, tt - tb - ts))
    print("\nThis is the axis apicov cannot see: a component the mission scripts")
    print("rarely call generates almost no call sites, so a call-weighted queue")
    print("never surfaces it. The engine's own registry does.")


if __name__ == "__main__":
    main()
