"""Decompile POG bytecode back to source.

pogdis gives us instructions and pogsummary gives us the constant arguments,
but neither gives us *code*: the branches are still jump targets and the
expressions are still a stack machine. This rebuilds both, so a mission comes
back as something you can read, review, and port.

Two stages:

1. **Expressions.** Symbolically execute each basic block with a stack of
   expression trees instead of values. `Load 3` pushes a variable, `AddI` pops
   two and pushes a sum, `Call` pops its arguments and pushes a call node. A
   statement falls out whenever a value is discarded (`Pop`) or stored
   (`Store`, which in POG does *not* pop -- assignment is an expression, so the
   compiler emits a trailing Pop when it was a statement).

2. **Control flow.** The compiler emits reducible, source-ordered code, so the
   jumps can be read straight back:

       while:    L: <cond> GoFalse X ; <body> ; Goto L ; X:
       if/else:  <cond> GoFalse E ; <then> ; Goto X ; E: <else> ; X:
       if:       <cond> GoFalse X ; <then> ; X:
       every:    L: EndTimeslice ; TimedJump X,slot,secs ; <body> ; Goto L ; X:

   Anything that does not fit one of those shapes is emitted as a labelled
   goto rather than guessed at, so the output never lies about the original.

The AST then has two backends: `pog` (near-original source, for reading against
the game) and `gd` (GDScript, the starting point for a native port).

Usage:
    python -m tools.iw2.pogdec <package> [-f Func] [--lang pog|gd]
    python -m tools.iw2.pogdec --all [out_dir] [--lang gd]
"""

from __future__ import annotations

import argparse
import re
import struct
from pathlib import Path

from .pogdis import decode, parse_pkg

ROOT = Path(__file__).resolve().parents[2]
POGDIS = ROOT / "data" / "pogdis"

# --- expressions -----------------------------------------------------------


class Expr:
    prec = 100


class Const(Expr):
    def __init__(self, v):
        self.v = v

    def __str__(self):
        if isinstance(self.v, float):
            return repr(self.v) if self.v != int(self.v) else "%.1f" % self.v
        return str(self.v)


class Str(Expr):
    def __init__(self, s):
        self.s = s

    def __str__(self):
        return '"%s"' % self.s.replace("\\", "\\\\").replace('"', '\\"') \
            .replace("\n", "\\n").replace("\r", "\\r")


class Null(Expr):
    def __str__(self):
        return "null"


class Var(Expr):
    def __init__(self, n, name=None):
        self.n = n
        self.name = name

    def __str__(self):
        return self.name or "v%d" % self.n


class Bin(Expr):
    def __init__(self, op, a, b, prec):
        self.op, self.a, self.b = op, a, b
        self.prec = prec

    def __str__(self):
        def side(e):
            return "(%s)" % e if e.prec < self.prec else str(e)
        return "%s %s %s" % (side(self.a), self.op, side(self.b))


class Un(Expr):
    prec = 12

    def __init__(self, op, a):
        self.op, self.a = op, a

    def __str__(self):
        return "%s%s" % (self.op, "(%s)" % self.a
                         if self.a.prec < self.prec else self.a)


class Call(Expr):
    def __init__(self, target, args, spawn=False):
        self.target, self.args, self.spawn = target, args, spawn

    def __str__(self):
        s = "%s(%s)" % (self.target, ", ".join(str(a) for a in self.args))
        return ("start " + s) if self.spawn else s


# --- statements ------------------------------------------------------------


class Stmt:
    pass


class Assign(Stmt):
    def __init__(self, var, expr):
        self.var, self.expr = var, expr


class Do(Stmt):
    def __init__(self, expr):
        self.expr = expr


class Ret(Stmt):
    def __init__(self, expr):
        self.expr = expr


class Halt(Stmt):
    pass


class Yield(Stmt):
    pass


class If(Stmt):
    def __init__(self, cond, then, els):
        self.cond, self.then, self.els = cond, then, els


class While(Stmt):
    def __init__(self, cond, body):
        self.cond, self.body = cond, body


class Every(Stmt):
    """`EndTimeslice; TimedJump` -- run the body at most every N seconds."""

    def __init__(self, secs, body):
        self.secs, self.body = secs, body


class Goto(Stmt):
    def __init__(self, target):
        self.target = target


class Break(Stmt):
    pass


class Continue(Stmt):
    pass


class Label(Stmt):
    def __init__(self, addr):
        self.addr = addr


class Debug(Stmt):
    """A `debug { ... }` block: skipped unless developer mode is on."""

    def __init__(self, body):
        self.body = body


# --- decompiler ------------------------------------------------------------

_BIN = {
    "AddI": ("+", 6), "SubtractI": ("-", 6), "MultiplyI": ("*", 7),
    "DivideI": ("/", 7), "ModulusI": ("%", 7),
    "AddF": ("+", 6), "SubtractF": ("-", 6), "MultiplyF": ("*", 7),
    "DivideF": ("/", 7),
    "Equal": ("==", 4), "NotEqual": ("!=", 4), "EqualObjects": ("==", 4),
    "GreaterI": (">", 5), "LessI": ("<", 5),
    "GreaterEqualI": (">=", 5), "LessEqualI": ("<=", 5),
    "GreaterF": (">", 5), "LessF": ("<", 5),
    "GreaterEqualF": (">=", 5), "LessEqualF": ("<=", 5),
    "LogicalAnd": ("&&", 3), "LogicalOr": ("||", 2),
    "BitAnd": ("&", 8), "BitOr": ("|", 8), "BitXor": ("^", 8),
}
_UN = {"NegateI": "-", "NegateF": "-", "LogicalNot": "!", "BitNot": "~"}
_JUMPS = ("Goto", "GoFalse", "GoTrue")


class Func:
    def __init__(self, name, entry, argc):
        self.name = name
        self.entry = entry
        self.argc = argc
        self.body: list[Stmt] = []
        self.nlocals = 0


class Decompiler:
    def __init__(self, pkg: dict, argcs: dict[str, int]):
        self.pkg = pkg
        self.argcs = argcs
        self.instrs = decode(pkg["code"])
        self.at = {off: i for i, (off, _, _) in enumerate(self.instrs)}
        self.end = (self.instrs[-1][0] + 1) if self.instrs else 0
        self.labels: set[int] = set()
        # A loop is a backward jump. Its target is the header; the *last* such
        # jump is the latch, which fixes the loop's extent. (POG's compiler emits
        # reducible code, so this is exact rather than a heuristic.)
        self.loops: dict[int, int] = {}
        for off, mn, args in self.instrs:
            if mn in _JUMPS and args[0] <= off:
                h = args[0]
                self.loops[h] = max(self.loops.get(h, 0), off)

    # -- helpers

    def _size(self, i: int) -> int:
        nxt = self.instrs[i + 1][0] if i + 1 < len(self.instrs) else self.end
        return nxt - self.instrs[i][0]

    def _next_addr(self, addr: int) -> int:
        i = self.at[addr]
        return self.instrs[i + 1][0] if i + 1 < len(self.instrs) else self.end

    def _target(self, addr: int) -> int | None:
        """If `addr` holds a Goto, its target."""
        i = self.at.get(addr)
        if i is None:
            return None
        _, mn, args = self.instrs[i]
        return args[0] if mn == "Goto" else None

    def _last_before(self, addr: int) -> int | None:
        i = self.at.get(addr)
        if i is None or i == 0:
            return None
        return self.instrs[i - 1][0]

    # -- function discovery

    def functions(self) -> list[Func]:
        entries: dict[int, str] = dict(
            (e, n) for n, e in self.pkg["exports"].items())
        argc: dict[int, int] = {}
        for off, mn, args in self.instrs:
            if mn in ("CallLocal", "StartLocal"):
                entries.setdefault(args[1], "local_%d" % args[1])
                argc[args[1]] = args[2]
        for e, n in entries.items():
            if e not in argc:
                argc[e] = self.argcs.get(
                    "%s.%s" % (self.pkg["name"].lower(), n), 0)

        ordered = sorted(entries)
        out = []
        for k, e in enumerate(ordered):
            stop = ordered[k + 1] if k + 1 < len(ordered) else self.end
            f = Func(entries[e], e, argc.get(e, 0))
            f.body = self._block(e, stop)
            out.append(f)
        return out

    # -- structuring

    def _block(self, lo: int, hi: int, ctx: tuple | None = None) -> list[Stmt]:
        """Structure [lo, hi). ctx = (break_to, continue_to) of the open loop."""
        out: list[Stmt] = []
        stack: list[Expr] = []
        addr = lo
        while addr < hi:
            i = self.at[addr]
            _, mn, args = self.instrs[i]

            # --- a loop starts here (something jumps back to this address)
            if addr in self.loops and self.loops[addr] < hi:
                latch = self.loops[addr]
                exit_at = self._next_addr(latch)
                out.append(self._loop(addr, latch, exit_at))
                addr = exit_at
                continue

            if mn == "EndTimeslice":
                out.append(Yield())
                addr = self._next_addr(addr)
                continue

            if mn == "DebugSkip":
                out.append(Debug(self._block(self._next_addr(addr), args[0], ctx)))
                addr = args[0]
                continue

            # --- conditional
            if mn in ("GoFalse", "GoTrue"):
                cond = stack.pop() if stack else Const(0)
                if mn == "GoTrue":
                    cond = Un("!", cond)
                tgt = args[0]
                body_lo = self._next_addr(addr)

                jump = self._jump_stmt(tgt, ctx)
                if jump is not None and not isinstance(jump, Goto):
                    out.append(If(cond, [jump], []))   # break / continue
                    addr = body_lo
                    continue

                if addr < tgt <= hi:
                    # if / if-else: an else exists when the then-part ends with
                    # a forward Goto over it.
                    els_end = None
                    b = self._last_before(tgt)
                    if b is not None and b >= body_lo:
                        t2 = self._target(b)
                        if t2 is not None and tgt < t2 <= hi:
                            els_end = t2
                    if els_end is not None:
                        out.append(If(cond,
                                      self._block(body_lo, b, ctx),
                                      self._block(tgt, els_end, ctx)))
                        addr = els_end
                    else:
                        out.append(If(cond, self._block(body_lo, tgt, ctx), []))
                        addr = tgt
                    continue

                self.labels.add(tgt)
                out.append(If(cond, [Goto(tgt)], []))
                addr = body_lo
                continue

            if mn == "Goto":
                tgt = args[0]
                if tgt == hi:
                    return out          # the jump that converges on this region's
                                        # end: structure already expresses it
                jump = self._jump_stmt(tgt, ctx)
                if jump is not None:
                    out.append(jump)
                    if isinstance(jump, Goto):
                        self.labels.add(tgt)
                if tgt >= hi:
                    return out
                addr = self._next_addr(addr)
                continue

            addr = self._step(i, stack, out)
        return out

    def _jump_stmt(self, tgt: int, ctx) -> Stmt | None:
        """A jump out of the current loop is a break; back to its head, continue."""
        if ctx is not None:
            brk, cont = ctx
            if tgt == brk:
                return Break()
            if tgt == cont:
                return Continue()
        return Goto(tgt)

    def _loop(self, header: int, latch: int, exit_at: int) -> Stmt:
        ctx = (exit_at, header)
        i = self.at[header]
        _, mn, _ = self.instrs[i]

        # `every N seconds`: yield each frame, and skip the body until N has
        # elapsed. TimedJump's target is the bottom of the loop, not its exit.
        if mn == "EndTimeslice":
            nxt = self._next_addr(header)
            j = self.at.get(nxt)
            if j is not None and self.instrs[j][1] == "TimedJump":
                _, _, ta = self.instrs[j]
                skip = ta[0]
                secs = struct.unpack("<f", struct.pack("<I", ta[2]))[0]
                if header < skip <= latch:
                    body = self._block(self._next_addr(nxt), skip, ctx)
                    tail = self._block(skip, latch, ctx)
                    return Every(secs, body + tail)

        # `while (cond)`: the header evaluates a condition that jumps to the
        # loop's exit. If the condition region also has side effects, we cannot
        # hoist it, so emit while(true) with an explicit break.
        cond, pre, body_lo = self._loop_cond(header, latch, exit_at)
        if cond is not None and not pre:
            return While(cond, self._block(body_lo, latch, ctx))
        if cond is not None:
            body = pre + [If(Un("!", cond), [Break()], [])]
            return While(Const(1), body + self._block(body_lo, latch, ctx))
        return While(Const(1), self._block(header, latch, ctx))

    def _loop_cond(self, header: int, latch: int, exit_at: int):
        """The header's exit test, if it has one: (cond, stmts_before, body_lo)."""
        stack: list[Expr] = []
        stmts: list[Stmt] = []
        addr = header
        while addr < latch:
            i = self.at[addr]
            _, mn, args = self.instrs[i]
            if mn in ("GoFalse", "GoTrue"):
                if args[0] != exit_at:
                    return None, [], header
                cond = stack.pop() if stack else Const(0)
                if mn == "GoTrue":
                    cond = Un("!", cond)
                return cond, stmts, self._next_addr(addr)
            if mn in _JUMPS or mn in ("EndTimeslice", "TimedJump", "DebugSkip"):
                return None, [], header
            addr = self._step(i, stack, stmts)
        return None, [], header

    def _step(self, i: int, stack: list[Expr], out: list[Stmt]) -> int:
        off, mn, args = self.instrs[i]
        nxt = self._next_addr(off)
        p = self.pkg

        if mn in ("LoadZero",):
            stack.append(Const(0))
        elif mn == "LoadOne":
            stack.append(Const(1))
        elif mn.startswith("LoadImmediate"):
            stack.append(Const(args[0]))
        elif mn == "LoadString":
            s = p["strings"][args[0]] if args[0] < len(p["strings"]) else "?"
            stack.append(Str(s))
        elif mn == "Load":
            stack.append(Var(args[0]))
        elif mn == "Store" or mn == "StoreObject":
            if stack:
                out.append(Assign(Var(args[0]), stack[-1]))
                stack[-1] = Var(args[0])
        elif mn == "Reserve":
            pass
        elif mn == "Pop":
            if stack:
                e = stack.pop()
                if isinstance(e, Call):
                    out.append(Do(e))
        elif mn == "PopN":
            for _ in range(args[0]):
                if stack:
                    stack.pop()
        elif mn == "Copy":
            if stack:
                stack.append(stack[-1])
        elif mn == "NewObject":
            stack.append(Null())
        elif mn in ("MarkObject", "DeleteMarkedObjects", "BeginAtomic",
                    "EndAtomic"):
            pass                       # engine-side object scoping / atomicity
        elif mn == "CloneObject":
            if stack:
                stack[-1] = Call("clone", [stack[-1]])
        elif mn in _BIN:
            b = stack.pop() if stack else Const(0)
            a = stack.pop() if stack else Const(0)
            op, prec = _BIN[mn]
            stack.append(Bin(op, a, b, prec))
        elif mn in _UN:
            a = stack.pop() if stack else Const(0)
            stack.append(Un(_UN[mn], a))
        elif mn in ("IntToFloat", "FloatToInt", "ToBool"):
            pass                       # coercions the types already imply
        elif mn in ("Call", "Start", "CallLocal", "StartLocal"):
            argc = args[2]
            call_args = [stack.pop() for _ in range(min(argc, len(stack)))][::-1]
            if mn in ("Call", "Start"):
                target = p["call_sites"].get(off, "?")
            else:
                target = self._name_of(args[1])
            stack.append(Call(target, call_args, spawn=mn.startswith("Start")))
        elif mn == "Return":
            out.append(Ret(stack.pop() if stack else None))
        elif mn == "Halt":
            out.append(Halt())
        return nxt

    def _name_of(self, entry: int) -> str:
        for n, e in self.pkg["exports"].items():
            if e == entry:
                return n
        return "local_%d" % entry


# --- backends --------------------------------------------------------------


def _ind(n):
    return "\t" * n


class PogBackend:
    """Near-original source: what the mission looked like before compiling."""

    def func(self, f: Func) -> str:
        params = ", ".join("v%d" % i for i in range(f.argc))
        head = "function %s(%s) {" % (f.name, params)
        return "\n".join([head] + self.body(f.body, 1) + ["}", ""])

    def body(self, stmts, d) -> list[str]:
        out = []
        for s in stmts:
            out += self.stmt(s, d)
        return out or [_ind(d) + ";"]

    def stmt(self, s, d) -> list[str]:
        i = _ind(d)
        if isinstance(s, Assign):
            return ["%s%s = %s;" % (i, s.var, s.expr)]
        if isinstance(s, Do):
            return ["%s%s;" % (i, s.expr)]
        if isinstance(s, Ret):
            return ["%sreturn%s;" % (i, " " + str(s.expr) if s.expr else "")]
        if isinstance(s, Halt):
            return [i + "halt;"]
        if isinstance(s, Yield):
            return [i + "yield;"]
        if isinstance(s, Break):
            return [i + "break;"]
        if isinstance(s, Continue):
            return [i + "continue;"]
        if isinstance(s, Goto):
            return ["%sgoto L%d;" % (i, s.target)]
        if isinstance(s, Label):
            return ["L%d:" % s.addr]
        if isinstance(s, Debug):
            return [i + "debug {"] + self.body(s.body, d + 1) + [i + "}"]
        if isinstance(s, Every):
            return ["%severy %g seconds {" % (i, s.secs)] \
                + self.body(s.body, d + 1) + [i + "}"]
        if isinstance(s, While):
            return ["%swhile (%s) {" % (i, s.cond)] \
                + self.body(s.body, d + 1) + [i + "}"]
        if isinstance(s, If):
            out = ["%sif (%s) {" % (i, s.cond)] + self.body(s.then, d + 1)
            if s.els:
                out += [i + "} else {"] + self.body(s.els, d + 1)
            return out + [i + "}"]
        return [i + "; // ?"]


class GdBackend:
    """GDScript. The starting point for a native port, not a drop-in."""

    def func(self, f: Func) -> str:
        params = ", ".join("v%d" % i for i in range(f.argc))
        head = "func %s(%s) -> void:" % (_snake(f.name), params)
        return "\n".join([head] + self.body(f.body, 1) + [""])

    def body(self, stmts, d) -> list[str]:
        out = []
        for s in stmts:
            out += self.stmt(s, d)
        return out or [_ind(d) + "pass"]

    def stmt(self, s, d) -> list[str]:
        i = _ind(d)
        if isinstance(s, Assign):
            return ["%s%s = %s" % (i, s.var, _gx(s.expr))]
        if isinstance(s, Do):
            return ["%s%s" % (i, _gx(s.expr))]
        if isinstance(s, Ret):
            return ["%sreturn" % i] if s.expr is None \
                else ["%sreturn %s" % (i, _gx(s.expr))]
        if isinstance(s, Halt):
            return [i + "return"]
        if isinstance(s, Yield):
            return [i + "await get_tree().process_frame"]
        if isinstance(s, Break):
            return [i + "break"]
        if isinstance(s, Continue):
            return [i + "continue"]
        if isinstance(s, Goto):
            return ["%s# goto L%d  (unstructured; needs a human)" % (i, s.target)]
        if isinstance(s, Label):
            return ["# L%d:" % s.addr]
        if isinstance(s, Debug):
            return ["%sif OS.is_debug_build():" % i] + self.body(s.body, d + 1)
        if isinstance(s, Every):
            return ["%swhile true:  # every %gs" % (i, s.secs)] \
                + self.body(s.body, d + 1) \
                + ["%sawait _wait(%g)" % (_ind(d + 1), s.secs)]
        if isinstance(s, While):
            return ["%swhile %s:" % (i, _gx(s.cond))] + self.body(s.body, d + 1)
        if isinstance(s, If):
            out = ["%sif %s:" % (i, _gx(s.cond))] + self.body(s.then, d + 1)
            if s.els:
                out += [i + "else:"] + self.body(s.els, d + 1)
            return out
        return [i + "pass"]


def _snake(n: str) -> str:
    return re.sub(r"(?<!^)(?=[A-Z])", "_", n).lower()


def _gx(e) -> str:
    """Expression -> GDScript."""
    if isinstance(e, Call):
        target = e.target
        if "." in target:
            pkg, fn = target.split(".", 1)
            target = "%s.%s" % (pkg.lower(), _snake(fn))
        else:
            target = _snake(target)
        s = "%s(%s)" % (target, ", ".join(_gx(a) for a in e.args))
        return ("start(%s)" % s) if e.spawn else s
    if isinstance(e, Bin):
        op = {"&&": "and", "||": "or"}.get(e.op, e.op)
        return "%s %s %s" % (_gx(e.a), op, _gx(e.b))
    if isinstance(e, Un):
        return ("not %s" % _gx(e.a)) if e.op == "!" else "%s%s" % (e.op, _gx(e.a))
    if isinstance(e, Null):
        return "null"
    return str(e)


# --- driver ----------------------------------------------------------------


_CALL = re.compile(r"(?:Call|Start)\s+([a-z_0-9]+)\.(\w+)\s+argc=(\d+)")


def argc_census() -> dict[str, int]:
    """Argument counts for every exported function, read off its call sites."""
    out: dict[str, int] = {}
    for f in POGDIS.glob("*.pogasm"):
        for m in _CALL.finditer(f.read_text(encoding="utf-8", errors="replace")):
            out["%s.%s" % (m.group(1), m.group(2))] = int(m.group(3))
    return out


def decompile(name: str, lang: str, only: str | None = None) -> str:
    from .resources import ResourceFS
    pkg = parse_pkg(ResourceFS().read_bytes("packages/%s.pkg" % name))
    d = Decompiler(pkg, argc_census())
    funcs = d.functions()
    be = GdBackend() if lang == "gd" else PogBackend()

    head = ["# package %s -- decompiled from the original bytecode" % pkg["name"],
            "# tools/iw2/pogdec.py; review before trusting.", ""]
    body = [be.func(f) for f in funcs
            if only is None or f.name.lower() == only.lower()]
    return "\n".join(head + body)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("package", nargs="?")
    ap.add_argument("-f", "--func")
    ap.add_argument("--lang", choices=["pog", "gd"], default="pog")
    ap.add_argument("--all", nargs="?", const="data/pogsrc", metavar="DIR")
    args = ap.parse_args()

    if args.all:
        from .resources import ResourceFS
        out = Path(args.all)
        out.mkdir(parents=True, exist_ok=True)
        fs = ResourceFS()
        ext = "gd" if args.lang == "gd" else "pog"
        n = 0
        for path in fs.list("packages/", ".pkg"):
            stem = Path(path).stem.lower()
            (out / ("%s.%s" % (stem, ext))).write_text(
                decompile(stem, args.lang), encoding="utf-8")
            n += 1
        print("decompiled %d packages -> %s" % (n, out))
        return

    if not args.package:
        ap.error("need a package (or --all)")
    print(decompile(args.package, args.lang, args.func))


if __name__ == "__main__":
    main()
