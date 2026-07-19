"""Native signatures, read from the POG SDK headers.

The bytecode gives us a native's name and, from its call sites, how many
arguments it is passed. It does not give us types. The SDK ships 153 headers
that declare every native properly:

    prototype hgroup Group.NthGroup( hgroup group, int nth );
    prototype int    Group.GroupCount( hgroup group );

which is where return types, parameter types and parameter names come from.
That is an authored source, not an inference, so it settles questions the
bytecode cannot (law 1).

The headers are Particle Systems copyright, exactly like the game data: this
reads them from the local SDK install and never copies them into the tree.
Point IW2_POG_SDK at it if it is not in the default place.

Usage:
    python -m tools.iw2.pogsig            # dump the table
    python -m tools.iw2.pogsig --check    # cross-check against our natives
"""

from __future__ import annotations

import os
import re
from pathlib import Path

SDK = Path(os.environ.get(
    "IW2_POG_SDK", Path.home() / "Projects" / "pog-scripting-sdk"))

# `prototype` .. `;`, with the comment forms (`// prototype ...`) left out.
_PROTO = re.compile(
    r"^[ \t]*prototype\s+(.*?);", re.MULTILINE | re.DOTALL)
# <ret>? <Pkg>.<Func> ( <args> )
_SIG = re.compile(
    r"^(?:([A-Za-z_][A-Za-z0-9_]*)\s+)?"
    r"([A-Za-z_][A-Za-z0-9_]*)\.([A-Za-z_][A-Za-z0-9_]*)\s*\((.*)\)$",
    re.DOTALL)


def _args(blob: str) -> list[tuple[str, str]]:
    out = []
    for part in blob.split(","):
        toks = part.split()
        if len(toks) >= 2:
            out.append((toks[-2], toks[-1]))
        elif toks:
            out.append((toks[0], ""))
    return out


def signatures() -> dict[str, tuple[str, list[tuple[str, str]]]]:
    """`pkg.func` (lowercased) -> (return type or "", [(type, name)])."""
    inc = SDK / "include"
    if not inc.is_dir():
        raise SystemExit(
            "POG SDK headers not found at %s -- set IW2_POG_SDK" % inc)
    out: dict[str, tuple[str, list[tuple[str, str]]]] = {}
    for h in sorted(inc.glob("*.h")):
        text = h.read_text(encoding="utf-8", errors="replace")
        for blob in _PROTO.findall(text):
            m = _SIG.match(" ".join(blob.split()))
            if not m:
                continue
            ret, pkg, fn, argblob = m.groups()
            # `task` is a declaration kind, not a return type
            ret = "" if ret in (None, "task") else ret
            out["%s.%s" % (pkg.lower(), fn.lower())] = (ret, _args(argblob))
    return out


def main() -> None:
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args()

    sigs = signatures()
    if not args.check:
        for k in sorted(sigs):
            ret, a = sigs[k]
            print("%-46s %-10s (%s)"
                  % (k, ret or "void",
                     ", ".join("%s %s" % t for t in a)))
        print("\n%d native signatures from %s" % (len(sigs), SDK / "include"))
        return

    from .pogport import native_bindings
    from .pogdec import argc_census

    # The census keys keep the function's original case (`group.NthGroup`);
    # everything else here is lowercased, so fold it once rather than compare
    # two spellings and silently match nothing.
    census = {k.lower(): v for k, v in argc_census().items()}
    bound = set()
    for pkg, fns in native_bindings().items():
        for fn in fns:
            bound.add("%s.%s" % (pkg.lower(), fn.lower()))

    have = bound & set(sigs)
    print("bound natives:            %d" % len(bound))
    print("  with an SDK signature:  %d" % len(have))
    print("  no SDK signature:       %d" % len(bound - set(sigs)))
    print("SDK natives we do not bind: %d" % len(set(sigs) - bound))

    # The bytecode says how many arguments each native is CALLED with; the
    # header says how many it DECLARES. A disagreement is a real defect in
    # one of the two, so list them rather than average them away.
    bad = []
    for k in sorted(have):
        declared = len(sigs[k][1])
        called = census.get(k)
        if called is not None and called != declared:
            bad.append((k, called, declared))
    print("\narity disagreements (bytecode call sites vs SDK header): %d"
          % len(bad))
    for k, called, declared in bad[:20]:
        print("   %-44s called %d, declared %d" % (k, called, declared))


if __name__ == "__main__":
    main()
