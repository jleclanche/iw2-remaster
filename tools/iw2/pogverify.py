"""Check the decompiler against the bytecode it came from.

The port rests on pogdec being right, and "it boots and does not error" is a
weak thing to rest on. This is a stronger one.

For every function, the bytecode and the decompiled AST must agree on two
things that no correct decompilation can change:

  * **the calls it makes** -- every `Call pkg.Func` in the bytecode must appear
    in the AST, and the AST must not invent one that is not there;
  * **the string literals it loads** -- likewise.

A dropped branch, a statement swallowed by a mis-shaped loop, a switch arm that
never got inlined, an `if` whose body was attributed to the wrong side: all of
them surface here as a call or a string that went missing.

The one asymmetry that is *legitimate* is duplication. `pogdec` inlines switch
arms and shared exits, so a call can appear more times in the AST than in the
bytecode. That is expected and is reported separately from the two things that
are always bugs:

    MISSING   in the bytecode, not in the AST  -- we lost code
    INVENTED  in the AST, not in the bytecode  -- we made code up

Neither should ever be non-zero.

Usage:
    python -m tools.iw2.pogverify              # every package
    python -m tools.iw2.pogverify iact0mission10 [-v]
"""

from __future__ import annotations

import argparse
import collections
from pathlib import Path

from .pogdec import (Assign, Bin, Call, Const, Debug, Decompiler, Dispatch, Do,
                     DoWhile, Every, Every as _E, Expr, If, Ret, Str, Un, Var,
                     While, argc_census)
from .pogdis import decode, parse_pkg
from .resources import ResourceFS


def _bytecode_facts(pkg: dict, lo: int, hi: int, live: set[int]):
    """(calls, strings) the *reachable* bytecode of [lo, hi) contains.

    Only reachable code counts. A decompiler is entitled to omit an instruction
    that can never run, and the shipped packages do contain dead code -- so
    counting it would flag correct output as broken.
    """
    calls: collections.Counter = collections.Counter()
    strings: collections.Counter = collections.Counter()
    for off, mn, args in decode(pkg["code"]):
        if not (lo <= off < hi) or (live is not None and off not in live):
            continue
        if mn in ("Call", "Start"):
            t = pkg["call_sites"].get(off)
            if t:
                calls[t.lower()] += 1
        elif mn in ("CallLocal", "StartLocal"):
            calls["local_%d" % args[1]] += 1
        elif mn == "LoadString":
            i = args[0]
            if i < len(pkg["strings"]):
                strings[pkg["strings"][i]] += 1
    return calls, strings


def _ast_facts(body):
    """(calls, strings) the decompiled AST says the same function contains."""
    calls: collections.Counter = collections.Counter()
    strings: collections.Counter = collections.Counter()

    def expr(e):
        if isinstance(e, Call):
            # `clone` is the CloneObject opcode rendered as a call, not a call
            if e.target != "clone" and not e.target.startswith("_"):
                calls[e.target.lower()] += 1
            for a in e.args:
                expr(a)
        elif isinstance(e, Str):
            strings[e.s] += 1
        elif isinstance(e, Bin):
            expr(e.a)
            expr(e.b)
        elif isinstance(e, Un):
            expr(e.a)

    def walk(stmts):
        for s in stmts:
            if isinstance(s, Assign):
                expr(s.expr)
            elif isinstance(s, Do):
                expr(s.expr)
            elif isinstance(s, Ret):
                if s.expr is not None:
                    expr(s.expr)
            elif isinstance(s, If):
                expr(s.cond)
                walk(s.then)
                walk(s.els)
            elif isinstance(s, (While, DoWhile)):
                expr(s.cond)
                walk(s.body)
            elif isinstance(s, (Every, Debug)):
                walk(s.body)
            elif isinstance(s, Dispatch):
                for _addr, blk in s.blocks:
                    walk(blk)

    walk(body)
    return calls, strings


def verify(name: str, fs: ResourceFS, argcs: dict, verbose: bool = False):
    pkg = parse_pkg(fs.read_bytes("packages/%s.pkg" % name))
    d = Decompiler(pkg, argcs)
    funcs = d.functions()

    entries = sorted(f.entry for f in funcs)
    stats = {"funcs": len(funcs), "missing": 0, "invented": 0,
             "dup": 0, "bad_funcs": 0, "bad_dispatch": 0, "bad_structured": 0,
             "dispatch": sum(1 for f in funcs if f.unstructured)}

    for f in funcs:
        k = entries.index(f.entry)
        stop = entries[k + 1] if k + 1 < len(entries) else d.end
        # reachable-from-entry, using the decompiler's own CFG
        live = {f.entry}
        stack = [f.entry]
        while stack:
            n = stack.pop()
            for t in d._succs(n, f.entry, stop):
                if t not in live:
                    live.add(t)
                    stack.append(t)
        # Two different baselines, deliberately.
        #   MISSING  is measured against *reachable* code: losing something that
        #            can run is always a bug.
        #   INVENTED is measured against *all* code in the range: emitting a
        #            dead block (the dispatch form does) is harmless, but
        #            emitting a call that is nowhere in the bytecode is not.
        bc, bs = _bytecode_facts(pkg, f.entry, stop, live)
        allc, alls = _bytecode_facts(pkg, f.entry, stop, None)
        ac, as_ = _ast_facts(f.body)

        # `clone` is CloneObject, an opcode, not a call; local_N in the AST is
        # rendered by name, so map the bytecode's local_N through the same names
        def rename(c):
            return collections.Counter(
                {(d._name_of(int(t.split("_")[1])).lower()
                  if t.startswith("local_") else t): n for t, n in c.items()})

        bc = rename(bc)
        allc = rename(allc)

        missing = {t: bc[t] - ac.get(t, 0)
                   for t in bc if bc[t] > ac.get(t, 0)}
        invented = {t: ac[t] for t in ac if t not in allc}
        dup = {t: ac[t] - bc[t] for t in ac if t in bc and ac[t] > bc[t]}

        smissing = {s: bs[s] - as_.get(s, 0)
                    for s in bs if bs[s] > as_.get(s, 0)}
        sinvented = {s: as_[s] for s in as_ if s not in alls}

        bad = bool(missing or invented or smissing or sinvented)
        if bad:
            stats["bad_funcs"] += 1
            stats["bad_dispatch" if f.unstructured else "bad_structured"] += 1
        stats["missing"] += sum(missing.values()) + sum(smissing.values())
        stats["invented"] += sum(invented.values()) + sum(sinvented.values())
        stats["dup"] += sum(dup.values())

        if bad or (verbose and dup):
            print("  %s.%s%s" % (name, f.name,
                                 "  [dispatch]" if f.unstructured else ""))
            for t, n in sorted(missing.items()):
                print("      MISSING  call %s x%d" % (t, n))
            for t, n in sorted(invented.items()):
                print("      INVENTED call %s x%d" % (t, n))
            for s, n in sorted(smissing.items()):
                print("      MISSING  str  %r x%d" % (s[:48], n))
            for s, n in sorted(sinvented.items()):
                print("      INVENTED str  %r x%d" % (s[:48], n))
            if verbose:
                for t, n in sorted(dup.items()):
                    print("      dup      call %s +%d (inlined)" % (t, n))
    return stats


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("package", nargs="?")
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args()

    fs = ResourceFS()
    argcs = argc_census()
    names = ([args.package] if args.package
             else [Path(p).stem.lower() for p in fs.list("packages/", ".pkg")])

    total = collections.Counter()
    for n in names:
        s = verify(n, fs, argcs, args.verbose)
        for k, v in s.items():
            total[k] += v

    print("\n== %d packages, %d functions" % (len(names), total["funcs"]))
    print("   MISSING  %d   (bytecode says it is there, the AST lost it)"
          % total["missing"])
    print("   INVENTED %d   (the AST says it is there, the bytecode does not)"
          % total["invented"])
    print("   duplicated %d (switch arms and shared exits, inlined -- expected)"
          % total["dup"])
    ok = total["funcs"] - total["bad_funcs"]
    print("\n   %d/%d functions provably agree with their bytecode (%.1f%%)"
          % (ok, total["funcs"], 100.0 * ok / total["funcs"]))
    print("   of the %d that do not: %d are structured, %d are dispatch"
          % (total["bad_funcs"], total["bad_structured"],
             total["bad_dispatch"]))
    print("   (%d functions use the dispatch form in total)" % total["dispatch"])
    raise SystemExit(1 if total["bad_funcs"] else 0)


if __name__ == "__main__":
    main()
