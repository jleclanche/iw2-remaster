"""Census of the POG native API: what the shipped campaign actually calls.

The engine exposes its functionality to the mission scripts as native
packages (iship.dll, iai.dll, ihud.dll ... one DLL per POG namespace).
That set of functions IS the game's behavioural surface: if we implement
it, the original bytecode runs.

This walks every disassembled package (data/pogdis/*.pogasm), counts the
`Call <pkg>.<Func>` sites, and reports the surface ordered by how much
the campaign leans on it -- which is the order worth implementing in.

With --coverage it diffs against the natives the Godot VM registers
(game/scripts/pog/natives/*.gd, `# @native pkg.Func` markers) and prints
the implemented percentage, weighted by call count.

Usage:
    python -m tools.iw2.apicov                 # the surface, by call count
    python -m tools.iw2.apicov --coverage      # implemented vs not
    python -m tools.iw2.apicov --pkg iship     # one package
"""

from __future__ import annotations

import argparse
import collections
import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parents[2]
POGDIS = ROOT / "data" / "pogdis"
NATIVES = ROOT / "game" / "scripts" / "pog" / "natives"

CALL = re.compile(r"^\s*\d+\s+(?:Call|StartLocal|Start|CallLocal)\s+([a-z_0-9]+)\.(\w+)\s+argc=(\d+)")
# `# @native iship.IsInLDS` markers in the GDScript native modules
MARKER = re.compile(r"#\s*@native\s+([a-z_0-9]+)\.(\w+)")


def script_packages() -> set[str]:
    """Packages whose bytecode we have -- the VM runs these, no port needed."""
    return {f.stem.lower() for f in POGDIS.glob("*.pogasm")}


def census() -> tuple[dict[tuple[str, str], int], dict[tuple[str, str], set[str]]]:
    """(pkg, func) -> call count, and -> set of packages that call it."""
    counts: dict[tuple[str, str], int] = collections.Counter()
    callers: dict[tuple[str, str], set[str]] = collections.defaultdict(set)
    for f in sorted(POGDIS.glob("*.pogasm")):
        for line in f.read_text(encoding="utf-8", errors="replace").splitlines():
            m = CALL.match(line)
            if m:
                key = (m.group(1), m.group(2))
                counts[key] += 1
                callers[key].add(f.stem)
    return counts, callers


def implemented() -> set[tuple[str, str]]:
    out: set[tuple[str, str]] = set()
    if not NATIVES.is_dir():
        return out
    for f in NATIVES.glob("*.gd"):
        for m in MARKER.finditer(f.read_text(encoding="utf-8", errors="replace")):
            out.add((m.group(1), m.group(2)))
    return out


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--coverage", action="store_true")
    ap.add_argument("--pkg")
    ap.add_argument("--todo", action="store_true", help="only the unimplemented, by call count")
    ap.add_argument("--list", nargs="*", metavar="PKG",
                    help="list each package's functions with call counts")
    args = ap.parse_args()

    counts, callers = census()
    scripts = script_packages()
    # A call into a package we have bytecode for costs us nothing: the VM
    # runs it. Only calls into the engine's native packages must be ported.
    script_calls = sum(n for (p, _), n in counts.items() if p in scripts)
    counts = {k: v for k, v in counts.items() if k[0] not in scripts}

    if args.pkg:
        counts = {k: v for k, v in counts.items() if k[0] == args.pkg}

    done = implemented() if (args.coverage or args.todo or args.list is not None) else set()

    by_pkg: dict[str, list[tuple[str, int]]] = collections.defaultdict(list)
    for (pkg, fn), n in counts.items():
        by_pkg[pkg].append((fn, n))

    if args.list is not None:
        want = args.list or sorted(by_pkg, key=lambda p: -sum(n for _, n in by_pkg[p]))
        for pkg in want:
            fns = sorted(by_pkg.get(pkg, []), key=lambda fn: -fn[1])
            print("%s  (%d functions, %d calls)"
                  % (pkg, len(fns), sum(n for _, n in fns)))
            for fn, n in fns:
                mark = " " if (pkg, fn) in done else "*"
                print("   %s %-34s %5d" % (mark, fn, n))
            print()
        return

    if args.todo:
        todo = [(k, v) for k, v in counts.items() if k not in done]
        todo.sort(key=lambda kv: -kv[1])
        print("# unimplemented natives, most-called first")
        for (pkg, fn), n in todo:
            print("%5d  %s.%s   (%d packages)" % (n, pkg, fn, len(callers[(pkg, fn)])))
        return

    total_fns = len(counts)
    total_calls = sum(counts.values())
    print("POG NATIVE API surface -- what the engine must provide")
    print("  %d distinct functions across %d native packages, %d call sites"
          % (total_fns, len(by_pkg), total_calls))
    print("  (%d further call sites land in the %d POG script packages,"
          % (script_calls, len(scripts)))
    print("   whose bytecode we already have -- the VM runs those for free)\n")

    hdr = "%-16s %6s %8s" % ("package", "funcs", "calls")
    if args.coverage:
        hdr += "  %8s %s" % ("done", "coverage")
    print(hdr)
    print("-" * (len(hdr) + 4))

    for pkg in sorted(by_pkg, key=lambda p: -sum(n for _, n in by_pkg[p])):
        fns = by_pkg[pkg]
        calls = sum(n for _, n in fns)
        line = "%-16s %6d %8d" % (pkg, len(fns), calls)
        if args.coverage:
            d = sum(1 for fn, _ in fns if (pkg, fn) in done)
            dc = sum(n for fn, n in fns if (pkg, fn) in done)
            line += "  %8d %6.0f%%" % (d, 100.0 * dc / calls if calls else 0)
        print(line)

    if args.coverage:
        dc = sum(n for k, n in counts.items() if k in done)
        df = sum(1 for k in counts if k in done)
        print("\nTOTAL  %d/%d functions (%.0f%%),  %d/%d call sites (%.0f%%)"
              % (df, total_fns, 100.0 * df / total_fns,
                 dc, total_calls, 100.0 * dc / total_calls))


if __name__ == "__main__":
    main()
