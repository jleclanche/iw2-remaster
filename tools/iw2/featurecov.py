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

That registry IS the inventory: 257 registrations in iwar2.dll plus 127 in
flux.dll (gui.dll and EdgeOfChaos.exe register none). This tool extracts it,
groups the classes by their base class (which is what tells you *what kind of
thing* each one is), and diffs it against what we have actually built -- so the
question "what is missing?" has an answer that does not depend on anyone
remembering to ask it.

Extraction notes (the decompiler renders the call several ways):
  * class/base as `PTR_s_<Name>_<addr>` pointer loads,
  * class/base as `<Class>::m_static_class_name` named statics,
  * base as `*(char **)m_static_class_name_exref` -- an import of another
    binary's class-name static, with no address in the C text.  For those we
    follow the factory argument into the constructor chain and take the base
    class whose constructor it calls (`FcGame::FcGame((FcGame *)this)`), which
    is also how you would recover it in a debugger,
  * base as `(char *)0x0` -- a root class, reported as "(root)".

We declare what we have built with a marker anywhere in game/scripts:

    # @element icHUDReticle                      -- really implemented
    # @element-stub icHUDStarmap -- reason       -- deliberately not, and why

The stub reason's leading tag classifies it (see CATEGORIES):
    covered-elsewhere / engine-internal / mp-only / editor-only /
    debug-only / GENUINE GAP
game/scripts/element_markers.gd is the ledger holding the classification for
everything not implemented in a specific file.

Same honesty rule as apicov: a stub is not an implementation, and the two are
counted separately.

Usage:
    python -m tools.iw2.featurecov                 # the whole inventory
    python -m tools.iw2.featurecov --base iiHUD    # one family
    python -m tools.iw2.featurecov --binary flux.dll
    python -m tools.iw2.featurecov --todo          # GENUINE gaps only
    python -m tools.iw2.featurecov --todo --all    # every not-built class
"""

from __future__ import annotations

import argparse
import collections
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DECOMP = ROOT / "data" / "decomp"
SCRIPTS = ROOT / "game" / "scripts"

BINARIES = ("iwar2.dll", "flux.dll", "gui.dll", "EdgeOfChaos.exe")

# ---------------------------------------------------------------- extraction

_HDR = re.compile(r"^// ==== (\S+) @ ([0-9a-f]+) ====")
# A string pointer: PTR_s_icDebugScreen_10159ac0, or the doubled form the
# decompiler emits for aliased addresses: PTR_s_iiSPGUIScreen_1015ab5f_1_1015ab54.
# Non-greedy so the name stops at the first 8-hex-digit suffix.
_PTR_S = re.compile(r"PTR_s_(\w+?)_[0-9a-f]{8}")
_NAMED = re.compile(r"([A-Za-z_]\w*)::m_static_class_name\b")
_EXREF = re.compile(r"m_static_class_name_exref")
_NULL = re.compile(r"\(\s*char\s*\*\s*\)\s*0x0")
_CALL = re.compile(r"FcRegistry::RegisterClass\s*\(([^;]*?)\)\s*;", re.S)
# One class (icAITarget) registers through the static-registrar helper instead:
#   FcRegistry::cRegistrar::cRegistrar(&X::m_registrar, cls, base, factory, ..)
_CALL_REGISTRAR = re.compile(
    r"FcRegistry::cRegistrar::cRegistrar\s*\(([^;]*?)\)\s*;", re.S)
_STATIC_NAME = re.compile(r"([A-Za-z_]\w*)::StaticClassName\s*\(\)")
_FUN = re.compile(r"\bFUN_([0-9a-f]{8})\b")
# a constructor call: Base::Base(  -- same identifier on both sides of ::
_CTOR_CALL = re.compile(r"\b([A-Za-z_]\w*)::\1\s*\(")


class _Binary:
    """One decompiled binary, split into `// ==== name @ addr ====` blocks."""

    def __init__(self, path: Path):
        self.text = path.read_text(encoding="utf-8", errors="replace")
        self.blocks: list[tuple[str, str, str]] = []   # (name, addr, body)
        self.by_addr: dict[str, int] = {}
        cur_name = cur_addr = None
        cur: list[str] = []
        for line in self.text.splitlines():
            m = _HDR.match(line)
            if m:
                if cur_name is not None:
                    self._push(cur_name, cur_addr, cur)
                cur_name, cur_addr = m.group(1), m.group(2)
                cur = []
            else:
                cur.append(line)
        if cur_name is not None:
            self._push(cur_name, cur_addr, cur)
        # constructor blocks by class name: `X * __thiscall X::X(X *this)`
        self.ctors: dict[str, int] = {}
        sig = re.compile(r"__thiscall (\w+)::\1\s*\(")
        for i, (_, _, body) in enumerate(self.blocks):
            m = sig.search(body[:400])
            if m and m.group(1) not in self.ctors:
                self.ctors[m.group(1)] = i

    def _push(self, name: str, addr: str, lines: list[str]) -> None:
        self.by_addr[addr] = len(self.blocks)
        self.blocks.append((name, addr, "\n".join(lines)))

    # -- resolving one RegisterClass argument to a class name ---------------

    def _resolve_expr(self, expr: str, body: str, call_pos: int) -> str | None:
        """Turn one argument expression into a class name, or 'EXREF'/None."""
        expr = expr.strip()
        if _NULL.search(expr):
            return "(root)"
        m = _PTR_S.search(expr)
        if m:
            return m.group(1)
        m = _NAMED.search(expr)
        if m:
            return m.group(1)
        m = _STATIC_NAME.search(expr)
        if m:
            return m.group(1)
        if _EXREF.search(expr):
            return "EXREF"
        # a plain variable: find its last assignment before the call
        var = re.escape(expr)
        best = None
        for m in re.finditer(r"\b%s\s*=([^;=][^;]*);" % var, body):
            if m.start() < call_pos:
                best = m.group(1)
        if best is not None:
            return self._resolve_expr(best, body, call_pos)
        return None

    def _resolve_raw(self, expr: str, body: str, call_pos: int) -> str:
        """Chase a variable to its assigned expression (for the factory arg)."""
        expr = expr.strip()
        if _FUN.search(expr) or "::" in expr:
            return expr
        var = re.escape(expr)
        best = expr
        for m in re.finditer(r"\b%s\s*=([^;=][^;]*);" % var, body):
            if m.start() < call_pos:
                best = m.group(1).strip()
        return best

    # -- following the factory into the constructor chain -------------------

    def _base_from_ctor_chain(self, skip: set[str],
                              factory_expr: str) -> str | None:
        """The base class is the one whose constructor the class's ctor calls.

        A constructor's first act is to call its base's constructor, so we walk
        the block in *statement order*: a named `Base::Base(` call wins; an
        anonymous `FUN_xxxxxxxx(` call is descended into (that is how the
        decompiler renders a ctor it could not name).  `skip` holds the class
        (and, in the fallback pass, its subclass) whose own ctor calls must not
        be mistaken for a base.
        """
        seen: set[int] = set()
        step = re.compile(r"\b([A-Za-z_]\w*)::\1\s*\(|\bFUN_([0-9a-f]{8})\b")

        def scan(idx: int, depth: int) -> str | None:
            if idx in seen or depth > 4:
                return None
            seen.add(idx)
            body = self.blocks[idx][2]
            for m in step.finditer(body):
                if m.group(1):
                    if m.group(1) not in skip:
                        return m.group(1)
                else:
                    j = self.by_addr.get(m.group(2))
                    if j is not None:
                        got = scan(j, depth + 1)
                        if got:
                            return got
            return None

        # prefer the class's own named constructor if the binary has one
        for cls in skip:
            if cls in self.ctors:
                got = scan(self.ctors[cls], 0)
                if got:
                    return got
        m = _FUN.search(factory_expr)
        if m and m.group(1) in self.by_addr:
            return scan(self.by_addr[m.group(1)], 0)
        m = re.search(r"(\w+)::CreateInstance", factory_expr)
        if m and m.group(1) in self.ctors:
            return scan(self.ctors[m.group(1)], 0)
        return None

    # -- the registry --------------------------------------------------------

    def inventory(self) -> dict[str, str]:
        out: dict[str, str] = {}
        factories: dict[str, str] = {}
        for _, _, body in self.blocks:
            # both shapes carry (this-or-registrar, class, base, factory, ...)
            for call in list(_CALL.finditer(body)) + list(
                    _CALL_REGISTRAR.finditer(body)):
                args = [a.strip() for a in call.group(1).replace("\n", " ")
                        .split(",")]
                if len(args) < 4:
                    continue
                cls = self._resolve_expr(args[1], body, call.start())
                base = self._resolve_expr(args[2], body, call.start())
                factory = self._resolve_raw(args[3], body, call.start())
                if cls in (None, "EXREF", "(root)"):
                    raise SystemExit("featurecov: cannot resolve class name in "
                                     "block:\n%s" % body[:400])
                if base == "EXREF":
                    base = self._base_from_ctor_chain({cls}, factory) or "?"
                if base is None:
                    base = "?"
                out[cls] = base
                factories[cls] = factory
        # Fallback for abstract classes registered with a NULL factory: walk a
        # subclass's factory instead -- its ctor calls the abstract class's
        # anonymous ctor, which calls the base we are after.
        for cls, base in list(out.items()):
            if base != "?":
                continue
            # every registered descendant of cls: their ctor chains all pass
            # through cls's ctor, so any of them with a real factory will do.
            desc = {cls}
            while True:
                more = {c for c, b in out.items() if b in desc} - desc
                if not more:
                    break
                desc |= more
            for sub in sorted(desc - {cls}):
                got = self._base_from_ctor_chain(desc,
                                                 factories.get(sub, ""))
                if got:
                    out[cls] = got
                    break
        return out


def inventory(binary: str = "iwar2.dll") -> dict[str, str]:
    """class name -> base class name, from the engine's own registry."""
    return _Binary(DECOMP / ("%s.c" % binary)).inventory()


def inventories() -> dict[str, dict[str, str]]:
    """binary -> {class -> base}, for every decompiled binary that registers."""
    out: dict[str, dict[str, str]] = {}
    for b in BINARIES:
        p = DECOMP / ("%s.c" % b)
        if p.is_file():
            inv = inventory(b)
            if inv:
                out[b] = inv
    return out


# ---------------------------------------------------------------- our side

_MARK = re.compile(r"#\s*@element\s+(\w+)")
_MARK_STUB = re.compile(r"#\s*@element-stub\s+(\w+)(?:\s*--\s*(.*))?")

# Recognised classification tags, checked against the start of the stub reason.
# GENUINE GAP is the one --todo exists to surface.
CATEGORIES = ("GENUINE GAP", "covered-elsewhere", "engine-internal",
              "mp-only", "editor-only", "debug-only")


def category(reason: str) -> str:
    for c in CATEGORIES:
        if reason.lower().startswith(c.lower()):
            return c
    return "(uncategorised)"


def built() -> tuple[set[str], dict[str, str]]:
    """(implemented classes, stubbed class -> reason)."""
    real: set[str] = set()
    stub: dict[str, str] = {}
    if not SCRIPTS.is_dir():
        return real, stub
    for f in SCRIPTS.rglob("*.gd"):
        t = f.read_text(encoding="utf-8", errors="replace")
        real |= {m.group(1) for m in _MARK.finditer(t)}
        for m in _MARK_STUB.finditer(t):
            stub.setdefault(m.group(1), (m.group(2) or "").strip())
    for c in real:
        stub.pop(c, None)
    return real, stub


# ---------------------------------------------------------------- reporting

def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", help="only classes whose base starts with this")
    ap.add_argument("--binary", help="only this binary (e.g. flux.dll)")
    ap.add_argument("--todo", action="store_true",
                    help="not-built classes; GENUINE gaps and unclassified only")
    ap.add_argument("--all", action="store_true",
                    help="with --todo: every not-built class, with category")
    args = ap.parse_args()

    invs = inventories()
    if args.binary:
        invs = {b: v for b, v in invs.items() if b == args.binary}
        if not invs:
            raise SystemExit("no registry found in %s" % args.binary)
    real, stub = built()

    if args.todo:
        shown = 0
        for b, inv in invs.items():
            fams: dict[str, list[str]] = collections.defaultdict(list)
            for cls, base in sorted(inv.items()):
                if args.base and not base.startswith(args.base):
                    continue
                if cls in real:
                    continue
                cat = category(stub.get(cls, "")) if cls in stub else "(unmarked)"
                if not args.all and cat not in ("GENUINE GAP", "(unmarked)",
                                                "(uncategorised)"):
                    continue
                fams[base].append("%-34s %s" % (cls, cat))
            if not fams:
                continue
            print("# %s -- registered by the engine, not built by us" % b)
            for base in sorted(fams, key=lambda x: -len(fams[x])):
                print("\n%s (%d)" % (base, len(fams[base])))
                for line in fams[base]:
                    print("   " + line)
                    shown += 1
            print()
        if shown == 0:
            print("nothing to do%s" % ("" if args.all else
                  " -- no GENUINE gaps or unclassified classes; "
                  "--all shows the rest"))
        return

    grand_t = grand_b = grand_s = 0
    for b, inv in invs.items():
        fams: dict[str, list[str]] = collections.defaultdict(list)
        for cls, base in sorted(inv.items()):
            if args.base and not base.startswith(args.base):
                continue
            fams[base].append(cls)
        if not fams:
            continue
        total = sum(len(v) for v in fams.values())
        print("%s registers %d classes.  What we have built:\n" % (b, total))
        hdr = "%-28s %5s %5s %5s  %s" % ("base class", "total", "built", "stub",
                                         "coverage")
        print(hdr)
        print("-" * len(hdr))
        tb = ts = tt = 0
        for base in sorted(fams, key=lambda x: (-len(fams[x]), x)):
            cs = fams[base]
            nb = sum(1 for c in cs if c in real)
            ns = sum(1 for c in cs if c in stub)
            tb += nb
            ts += ns
            tt += len(cs)
            print("%-28s %5d %5d %5d  %6.0f%%"
                  % (base, len(cs), nb, ns, 100.0 * nb / len(cs)))
        print("\n%s TOTAL  %d/%d built (%.0f%%), %d stubbed, %d not started\n"
              % (b, tb, tt, 100.0 * tb / tt if tt else 0, ts, tt - tb - ts))
        grand_t += tt
        grand_b += tb
        grand_s += ts

    # classification summary over everything not built
    cats: collections.Counter[str] = collections.Counter()
    for b, inv in invs.items():
        for cls, base in inv.items():
            if cls in real or (args.base and not base.startswith(args.base)):
                continue
            cats[category(stub[cls]) if cls in stub else "(unmarked)"] += 1
    if grand_t:
        print("ALL BINARIES  %d classes, %d built, %d stubbed/classified"
              % (grand_t, grand_b, grand_s))
        if cats:
            print("not-built classification: "
                  + ", ".join("%s %d" % (c, n) for c, n in cats.most_common()))
    print("\nThis is the axis apicov cannot see: a component the mission scripts")
    print("rarely call generates almost no call sites, so a call-weighted queue")
    print("never surfaces it. The engine's own registry does.")


if __name__ == "__main__":
    main()
