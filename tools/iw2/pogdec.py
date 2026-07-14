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


class New(Expr):
    """NewObject: a *fresh* script object of one of POG's three object types.

    flux.dll @ 0x1003b190 (FcScriptTask::Execute), case 0x3a:

        eVar5 = *pc++;                       // the linked eType
        pFVar16 = FiScriptObject::Create(eVar5);
        *++sp = pFVar16;                     // pushed, nothing popped

    and FiScriptObject::Create (flux.dll @ 0x1003a960) switches on that enum:
    1 -> FcScriptString, 2 -> FcScriptList, 3 -> FcScriptSet (anything else is
    a null pointer). The operand is a link-time fixup, zero in the file; the
    OIMP chunk names the type -- see pogdis.parse_pkg.

    Rendering this `null` -- which is what we used to do -- destroys every list
    the scripts build. `list l;` compiles to `NewObject FcScriptList; Store`,
    and the natives that take a list (iinventory.FillInventoryListBox,
    igui.CreateGreyBoxStyleScreen) *fill the object the script handed them*.
    With `null` in the local there is nothing to fill, so the script's parallel
    handle list comes out empty and every row index misses.
    """

    KINDS = {"FcScriptString": "string", "FcScriptList": "list",
             "FcScriptSet": "set"}

    def __init__(self, kind: str):
        self.kind = kind             # "FcScriptList" / "FcScriptSet" / ...

    @property
    def what(self) -> str:
        return self.KINDS.get(self.kind, "object")

    def __str__(self):
        return "new %s" % self.what


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


class DoWhile(Stmt):
    """`do { body } while (cond)` -- a loop whose test is the back edge itself."""

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


class PcSet(Stmt):
    """Inside a Dispatch: go to a block."""

    def __init__(self, target):
        self.target = target


class Dispatch(Stmt):
    """A function whose control flow does not reduce to structured code.

    Rather than emit a goto we cannot honour, the function is rebuilt as its
    basic blocks under an explicit program counter. It is not pretty, but it is
    exactly the original, and it runs. About 8% of the game needs it.
    """

    def __init__(self, entry, blocks):
        self.entry = entry
        self.blocks = blocks      # [(addr, [Stmt])], each ending in PcSet/Ret


# --- decompiler ------------------------------------------------------------

_INVERSE = {"==": "!=", "!=": "==", "<": ">=", ">=": "<",
            ">": "<=", "<=": ">"}


def _not(e: Expr) -> Expr:
    """Logical negation, folded: `!!x` is x, and `!(a == b)` is `a != b`."""
    if isinstance(e, Un) and e.op == "!":
        return e.a
    if isinstance(e, Bin) and e.op in _INVERSE:
        return Bin(_INVERSE[e.op], e.a, e.b, e.prec)
    return Un("!", e)


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
        self.unstructured = False   # rebuilt as a block dispatch


def _has_call(e) -> bool:
    """Does this expression do anything? Discarding a value is not the same as
    not computing it: `f() == 2` popped is still a call to f."""
    if isinstance(e, Call):
        return True
    if isinstance(e, Bin):
        return _has_call(e.a) or _has_call(e.b)
    if isinstance(e, Un):
        return _has_call(e.a)
    return False


def _keep_discarded(e) -> bool:
    """Must a discarded value still be emitted as a statement?

    Calls, because discarding a value does not un-call the function that
    produced it. And string literals, because the verifier counts them: a few
    debug blocks load a string and then just pop it (the print was compiled
    out), and dropping the load silently would be indistinguishable from
    dropping a branch. A bare literal statement is a no-op either way.
    """
    if isinstance(e, Str):
        return True
    if isinstance(e, Call):
        return True
    if isinstance(e, Bin):
        return _keep_discarded(e.a) or _keep_discarded(e.b)
    if isinstance(e, Un):
        return _keep_discarded(e.a)
    return False


def _flush(stack, stmts) -> None:
    """A block ends with values still on its stack. They belong to expressions
    the compiler discarded, but discarding a value does not un-call the function
    that produced it, so anything with a side effect still has to be emitted."""
    for e in stack:
        if _keep_discarded(e):
            stmts.append(Do(e))
    stack.clear()


def _has_goto(stmts) -> bool:
    for s in stmts:
        if isinstance(s, Goto):
            return True
        if isinstance(s, If) and (_has_goto(s.then) or _has_goto(s.els)):
            return True
        if isinstance(s, (While, DoWhile, Every, Debug)) and _has_goto(s.body):
            return True
    return False


class Decompiler:
    def __init__(self, pkg: dict, argcs: dict[str, int]):
        self.pkg = pkg
        self.argcs = argcs
        self.instrs = decode(pkg["code"])
        self.at = {off: i for i, (off, _, _) in enumerate(self.instrs)}
        self.end = (self.instrs[-1][0] + 1) if self.instrs else 0
        self.labels: set[int] = set()
        self.func_hi = self.end
        self._tail_stack: list[Expr] = []
        self._inlining: set[int] = set()
        # Every instruction the structured form actually consumed. Skipping
        # forward over a switch's case bodies is only sound if those bodies are
        # inlined back in at the branches that select them; when inlining fails
        # they would otherwise be dropped in silence. So we check.
        self._covered: set[int] = set()
        self.latch: dict[int, int] = {}
        self.loops: dict[int, int] = {}

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
            self.func_hi = stop
            self._find_loops(e, stop)
            f = Func(entries[e], e, argc.get(e, 0))
            self._covered = set()
            f.body = self._block(e, stop)
            # Two ways the structured form can be a lie, and both fall back to
            # the block dispatch, which is exact by construction:
            #
            #   a goto we could not shape -- it would not run; and
            #
            #   code we skipped and never put back. Jumping the cursor forward
            #   over a switch's case bodies is only sound if those bodies are
            #   inlined at the branches that select them. When inlining fails
            #   the code is simply gone, and the output looks perfectly clean
            #   while missing statements. So compare what we emitted against
            #   what is reachable, and never ship the difference.
            if _has_goto(f.body) or self._lost_code(e, stop):
                f.body = [self._linear(e, stop)]
                f.unstructured = True
            out.append(f)
        return out

    def _lost_code(self, lo: int, hi: int) -> bool:
        """Did the structured form drop any instruction that can actually run?"""
        seen = {lo}
        stack = [lo]
        while stack:
            n = stack.pop()
            for t in self._succs(n, lo, hi):
                if t not in seen:
                    seen.add(t)
                    stack.append(t)
        return bool(seen - self._covered)

    # -- structuring

    def _block(self, lo: int, hi: int, ctx: tuple | None = None) -> list[Stmt]:
        """Structure [lo, hi). ctx = (break_to, header, latch) of the open loop.

        Leaves whatever expression the region ended mid-evaluation in
        `_tail_stack`: a do-while's condition is exactly that.
        """
        out: list[Stmt] = []
        stack: list[Expr] = []
        self._tail_stack = stack
        addr = lo
        while addr < hi:
            i = self.at[addr]
            _, mn, args = self.instrs[i]
            self._covered.add(addr)

            # --- a loop starts here (something jumps back to this address)
            if addr in self.loops and self.loops[addr] < hi:
                exit_at = self._next_addr(self.loops[addr])
                out.append(self._loop(addr, self.latch[addr], exit_at))
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
                    cond = _not(cond)
                tgt = args[0]
                body_lo = self._next_addr(addr)

                jump = self._jump_stmt(tgt, ctx)
                if isinstance(jump, Goto):
                    epi = self._epilogue(tgt, stack)
                    if epi is not None:
                        jump = epi
                if not isinstance(jump, Goto):
                    # `cond` is the condition to FALL THROUGH (GoFalse jumps when
                    # it is false; GoTrue was negated above), so the jump is
                    # taken on its negation.
                    out.append(If(_not(cond), [jump], []))
                    addr = body_lo
                    continue

                if addr < tgt <= hi and not self._splits_loop(body_lo, tgt):
                    # if / if-else: an else exists when the then-part ends with
                    # a forward Goto over it.
                    els_end = None
                    b = self._last_before(tgt)
                    if b is not None and b >= body_lo:
                        t2 = self._target(b)
                        if (t2 is not None and tgt < t2 <= hi
                                and not self._splits_loop(tgt, t2)):
                            els_end = t2
                    if els_end is not None:
                        then = self._block(body_lo, b, ctx)
                        tail = list(self._tail_stack)
                        if not tail:
                            # the then-part's trailing Goto over the else
                            # became the if/else itself
                            self._covered.add(b)
                            out.append(If(cond, then,
                                          self._block(tgt, els_end, ctx)))
                            addr = els_end
                            continue
                        # The then-part ends mid-expression: its Goto carries a
                        # value to the join, so this is not a statement-level
                        # if/else. If the join is the shared exit, the branch is
                        # an early `return <value>`; otherwise leave the Goto to
                        # the plain-if shape below, which structures it honestly
                        # (inline, epilogue, or an explicit goto -- never a
                        # silent drop).
                        epi = self._epilogue(els_end, tail)
                        if epi is not None:
                            self._covered.add(b)
                            out.append(If(cond, then + [epi], []))
                            addr = tgt
                            continue
                    out.append(If(cond, self._block(body_lo, tgt, ctx), []))
                    addr = tgt
                    continue

                # Last resort before a goto: a switch arm, or an early exit into
                # shared cleanup -- straight-line code that ends by returning,
                # so it can simply be pasted in where it is branched to.
                inlined = self._inline(tgt, stack)
                if inlined is not None:
                    out.append(If(_not(cond), inlined, []))
                    addr = body_lo
                    continue

                self.labels.add(tgt)
                out.append(If(_not(cond), [Goto(tgt)], []))
                addr = body_lo
                continue

            if mn == "Goto":
                tgt = args[0]

                # A pre-tested loop: the compiler jumps forward to the test,
                # which sits at the bottom and jumps back over the body.
                #     Goto COND ; H: <body> ; COND: <cond> ; GoTrue H
                nxt = self._next_addr(addr)
                if nxt in self.loops:
                    h, latch = nxt, self.loops[nxt]
                    if h < tgt <= latch and latch < hi:
                        out.append(self._pretested(h, tgt, latch))
                        addr = self._next_addr(latch)
                        continue

                if tgt == hi:
                    self._tail_stack = stack
                    return out          # converges on this region's end: the
                                        # structure already expresses it

                if tgt >= self.func_hi:
                    out.append(Ret(None))   # jump to the tail: a bare return
                    self._tail_stack = stack
                    return out
                jump = self._jump_stmt(tgt, ctx)
                if isinstance(jump, Goto):
                    epi = self._epilogue(tgt, stack)
                    if epi is not None:
                        out.append(epi)
                        self._tail_stack = stack
                        return out
                    if tgt > addr:
                        # An unconditional forward jump inside the region simply
                        # moves the cursor: whatever it skipped is reachable only
                        # through other jumps (this is how a switch skips over
                        # its case bodies to reach the dispatch), and those get
                        # inlined at their jump sites.
                        addr = tgt
                        continue
                    inlined = self._inline(tgt, stack)
                    if inlined is not None:
                        out += inlined
                        self._tail_stack = stack
                        return out
                    self.labels.add(tgt)
                out.append(jump)
                if tgt >= hi:
                    self._tail_stack = stack
                    return out
                addr = self._next_addr(addr)
                continue

            addr = self._step(i, stack, out)
        self._tail_stack = stack
        return out

    def _speculate(self, fn):
        """Run `fn` with a scratch coverage set, merged back only on success.

        `_epilogue` and `_inline` simulate code they may decide not to use. The
        simulation must not mark anything covered when it fails (that would let
        `_lost_code` miss genuinely dropped code), and it MUST mark everything
        covered when it succeeds (the simulated instructions become the emitted
        `return` / inlined arm, so they are represented in the output).
        """
        outer = self._covered
        self._covered = set()
        try:
            r = fn()
            if r is not None:
                outer |= self._covered
            return r
        finally:
            self._covered = outer

    def _epilogue(self, tgt: int, stack: list[Expr] | None = None) -> Stmt | None:
        return self._speculate(lambda: self._epilogue_raw(tgt, stack))

    def _epilogue_raw(self, tgt: int, stack: list[Expr] | None = None) -> Stmt | None:
        """If everything from `tgt` to the end of the function is just the
        shared exit -- scope cleanup and a Return -- then a jump to it is a
        plain `return`, not a goto. Most jumps in the game are exactly this.

        The exit runs on whatever the jumping code left on the stack (a switch
        arm loads its result and jumps straight to `CloneObject; Return`), so it
        is simulated from the caller's stack rather than an empty one.
        """
        allowed = {"DeleteMarkedObjects", "MarkObject", "Pop", "LoadZero",
                   "LoadOne", "Load", "LoadString", "CloneObject", "NewObject",
                   "Copy"}
        sim: list[Expr] = list(stack) if stack else []
        addr = tgt
        while addr < self.func_hi:
            i = self.at.get(addr)
            if i is None:
                return None
            _, mn, args = self.instrs[i]
            if mn == "Halt":
                self._covered.add(addr)
                return Halt()
            if mn == "Return":
                self._covered.add(addr)
                return Ret(sim[-1] if sim else None)
            if mn not in allowed:
                return None
            self._step(i, sim, [])      # side-effect free by construction
            addr = self._next_addr(addr)
        return None

    # -- loops, properly

    def _succs(self, off: int, lo: int, hi: int) -> list[int]:
        _, mn, args = self.instrs[self.at[off]]
        nxt = self._next_addr(off)
        if mn == "Goto":
            s = [args[0]]
        elif mn in ("GoFalse", "GoTrue", "DebugSkip", "TimedJump"):
            s = [args[0], nxt]
        elif mn in ("Return", "Halt"):
            s = []
        else:
            s = [nxt]
        return [t for t in s if lo <= t < hi]

    def _find_loops(self, lo: int, hi: int) -> None:
        """Loops for one function.

        A backward jump is NOT enough to make a loop: the compiler emits a
        switch as `goto dispatch; <cases>; dispatch: compare-and-jump back into
        a case`, so those back edges jump into code that never encloses them.
        A back edge n -> h is a loop only if h *dominates* n -- if every path
        from the entry to n runs through h. Anything else is a jump table.
        """
        nodes = [off for off, _, _ in self.instrs if lo <= off < hi]
        succ = {n: self._succs(n, lo, hi) for n in nodes}

        def dominates(h: int, n: int) -> bool:
            """Does every path from the entry to `n` pass through `h`?
            Equivalently: with `h` removed, is `n` still reachable?"""
            if h == n:
                return True
            seen = {h}
            stack = [lo]
            if lo == h:
                return True
            while stack:
                x = stack.pop()
                if x == n:
                    return False
                if x in seen:
                    continue
                seen.add(x)
                stack.extend(succ.get(x, ()))
            return True

        self.latch = {}
        for n in nodes:
            _, mn, args = self.instrs[self.at[n]]
            if mn in _JUMPS and lo <= args[0] <= n:
                h = args[0]
                if dominates(h, n):              # a real loop, not a jump table
                    self.latch[h] = max(self.latch.get(h, 0), n)

        # A loop's extent is not its latch: a nested loop's own back edge can
        # sit after the outer loop's, so the outer body runs on past it.
        self.loops = dict(self.latch)
        changed = True
        while changed:
            changed = False
            for h, end in list(self.loops.items()):
                for h2, end2 in self.loops.items():
                    if h < h2 <= end and end2 > end:
                        self.loops[h] = end2
                        end = end2
                        changed = True

    def _linear(self, lo: int, hi: int) -> Dispatch:
        """Rebuild a function as basic blocks under an explicit pc.

        The fallback for the ~8% of functions whose control flow is genuinely
        irreducible (multi-level exits out of nested loops, mostly). Every jump
        becomes an assignment to the pc, so nothing is approximated: the result
        is the original program, just spelled as a state machine.
        """
        leaders = {lo}
        for off, mn, args in self.instrs:
            if not (lo <= off < hi):
                continue
            if mn in _JUMPS or mn in ("DebugSkip", "TimedJump"):
                if lo <= args[0] < hi:
                    leaders.add(args[0])
                nxt = self._next_addr(off)
                if lo <= nxt < hi:
                    leaders.add(nxt)
        order = sorted(leaders)

        blocks: list[tuple[int, list[Stmt]]] = []
        # A block boundary can land in the middle of an expression -- a debug
        # block's skip target does exactly that -- so a value computed in one
        # block is consumed by a branch in the next. Giving each block a fresh
        # stack drops that value, and the calls inside it vanish with it. The
        # stack therefore carries across a fall-through edge, and only there.
        carry: list[Expr] = []
        for k, start in enumerate(order):
            stop = order[k + 1] if k + 1 < len(order) else hi
            stmts: list[Stmt] = []
            stack: list[Expr] = carry
            carry = []
            addr = start
            done = False
            while addr < stop:
                i = self.at[addr]
                _, mn, args = self.instrs[i]
                nxt = self._next_addr(addr)
                if mn == "Goto":
                    if stack:
                        # The block jumps out with values on its stack -- a
                        # switch arm carrying its result to the shared exit.
                        # PcSet would drop them (each arm carries a *different*
                        # value, so the exit block cannot embed them all); if
                        # the target is the shared exit, fold it in right here.
                        epi = self._epilogue(args[0], stack)
                        if epi is not None:
                            stmts.append(epi)
                            done = True
                            break
                    _flush(stack, stmts)
                    stmts.append(PcSet(args[0]))
                    done = True
                    break
                if mn in ("GoFalse", "GoTrue"):
                    cond = stack.pop() if stack else Const(0)
                    if mn == "GoTrue":
                        cond = _not(cond)
                    # cond is the fall-through condition. The fall-through
                    # successor is the lexically next block, so pure leftover
                    # values (a switch's compare ladder keeps the selector on
                    # the stack between tests) carry across exactly like a
                    # plain fall-through. Values with side effects ran before
                    # the branch in the bytecode, so they cannot be deferred
                    # into one arm -- emit them here instead.
                    if stack and not any(_has_call(e) for e in stack):
                        carry = list(stack)
                        stack.clear()
                    else:
                        _flush(stack, stmts)
                    stmts.append(If(cond, [PcSet(nxt)], [PcSet(args[0])]))
                    done = True
                    break
                if mn == "DebugSkip":
                    _flush(stack, stmts)
                    stmts.append(PcSet(args[0]))   # developer mode off
                    done = True
                    break
                if mn == "EndTimeslice":
                    stmts.append(Yield())
                    addr = nxt
                    continue
                if mn == "TimedJump":
                    secs = struct.unpack("<f", struct.pack("<I", args[2]))[0]
                    stmts.append(If(Call("_pog_every", [Const(addr),
                                                        Const(secs)]),
                                    [PcSet(nxt)], [PcSet(args[0])]))
                    done = True
                    break
                if mn in ("Return", "Halt"):
                    rv = stack.pop() if (mn == "Return" and stack) else None
                    _flush(stack, stmts)
                    stmts.append(Ret(rv) if mn == "Return" else Halt())
                    done = True
                    break
                addr = self._step(i, stack, stmts)
            if not done:
                # fell through to the next block: whatever is still on the stack
                # belongs to an expression that continues there
                carry = stack
                stmts.append(PcSet(stop) if stop < hi else Ret(None))
            blocks.append((start, stmts))
        return Dispatch(lo, blocks)

    def _inline(self, tgt: int, stack: list[Expr]) -> list[Stmt] | None:
        return self._speculate(lambda: self._inline_raw(tgt, stack))

    def _inline_raw(self, tgt: int, stack: list[Expr]) -> list[Stmt] | None:
        """A switch arm, inlined at its jump site.

        The compiler lays a switch out as `goto dispatch; <cases>; dispatch:
        compare-and-jump into a case`, so the case bodies sit *before* the code
        that selects them and can only be reached by jumping backwards. Each arm
        is straight-line and ends by jumping to the function's shared exit, so it
        can simply be pasted in where it is selected -- no label, no goto.

        Returns None if the target is not that shape, in which case the caller
        keeps its honest goto.
        """
        if tgt in self._inlining:
            return None                  # not straight-line after all
        sim: list[Expr] = list(stack)
        stmts: list[Stmt] = []
        addr = tgt
        self._inlining.add(tgt)
        try:
            while addr < self.func_hi:
                i = self.at.get(addr)
                if i is None:
                    return None
                _, mn, args = self.instrs[i]
                if mn in ("Return", "Halt"):
                    self._covered.add(addr)
                    stmts.append(Ret(sim[-1] if sim else None)
                                 if mn == "Return" else Halt())
                    return stmts
                if mn == "Goto":
                    epi = self._epilogue(args[0], sim)
                    if epi is None:
                        return None
                    # the Goto itself became the fall into the shared exit
                    self._covered.add(addr)
                    stmts.append(epi)
                    return stmts
                if mn == "DebugSkip":
                    # A `debug { ... }` block inside the arm (several switch
                    # defaults print a warning first). Statement-level and
                    # straight-line, or the arm does not inline.
                    dbg = self._debug_body(addr, args[0])
                    if dbg is None:
                        return None
                    self._covered.add(addr)
                    stmts.append(Debug(dbg))
                    addr = args[0]
                    continue
                if mn in _JUMPS or mn in ("EndTimeslice", "TimedJump"):
                    return None          # not straight-line
                addr = self._step(i, sim, stmts)
            return None
        finally:
            self._inlining.discard(tgt)

    def _debug_body(self, at: int, skip: int) -> list[Stmt] | None:
        """The body of a DebugSkip at `at`, if it is a straight-line statement
        block (no jumps, no suspension, net-zero stack). None otherwise."""
        stmts: list[Stmt] = []
        sim: list[Expr] = []
        addr = self._next_addr(at)
        while addr < skip:
            i = self.at.get(addr)
            if i is None:
                return None
            mn = self.instrs[i][1]
            if mn in _JUMPS or mn in ("EndTimeslice", "TimedJump", "DebugSkip",
                                      "Return", "Halt"):
                return None
            addr = self._step(i, sim, stmts)
        if sim:
            return None                  # not statement-level after all
        return stmts

    def _splits_loop(self, lo: int, hi: int) -> bool:
        """Would a region ending at `hi` cut a loop that starts inside it?

        If so the branch is not an if-join at all, and treating it as one hides
        the loop from the structurer -- which is what left thousands of gotos.
        """
        for h, latch in self.loops.items():
            if lo <= h < hi <= latch:
                return True
        return False

    def _jump_stmt(self, tgt: int, ctx) -> Stmt | None:
        """Out of the current loop is a break; to its head or its latch (the
        back edge at the bottom) is a continue."""
        if ctx is not None:
            brk, head, latch = ctx
            if tgt == brk:
                return Break()
            if tgt == head or tgt == latch:
                return Continue()
        return Goto(tgt)

    def _loop(self, header: int, latch: int, exit_at: int) -> Stmt:
        ctx = (exit_at, header, latch)
        i = self.at[header]
        _, mn, _ = self.instrs[i]
        _, latch_mn, _ = self.instrs[self.at[latch]]

        # The loop runs past its own back edge because a nested loop ends later.
        # Its shape is then just "loop forever, leaving via break": the back
        # edges inside become continues.
        if self._next_addr(latch) != exit_at:
            return While(Const(1), self._block(header, exit_at, ctx))

        # From here on every shape ends its body at `latch` exclusive: the latch
        # instruction itself (the back edge, or the do-while's test-and-jump) is
        # consumed by the loop structure rather than visited by _block.
        self._covered.add(latch)

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
                    self._covered.add(nxt)      # the TimedJump is the `every`
                    body = self._block(self._next_addr(nxt), skip, ctx)
                    tail = self._block(skip, latch, ctx)
                    return Every(secs, body + tail)

        # `do { } while (cond)`: the back edge is itself the test, so the
        # condition is whatever the body leaves on the stack at the latch.
        if latch_mn in ("GoTrue", "GoFalse"):
            body = self._block(header, latch, ctx)
            cond = self._tail_stack[-1] if self._tail_stack else Const(1)
            if latch_mn == "GoFalse":
                cond = _not(cond)
            return DoWhile(cond, body)

        # `while (cond)`: the header evaluates a condition that jumps to the
        # loop's exit. If the condition region also has side effects we cannot
        # hoist it, so emit while(true) with an explicit break.
        cond, pre, body_lo = self._loop_cond(header, latch, exit_at)
        if cond is not None and not pre:
            return While(cond, self._block(body_lo, latch, ctx))
        if cond is not None:
            body = pre + [If(_not(cond), [Break()], [])]
            return While(Const(1), body + self._block(body_lo, latch, ctx))
        return While(Const(1), self._block(header, latch, ctx))

    def _pretested(self, header: int, cond_at: int, latch: int) -> Stmt:
        """`while (cond) { body }`, emitted by the compiler as a jump to the
        bottom test. Body is [header, cond_at); the test is [cond_at, latch]."""
        exit_at = self._next_addr(latch)
        ctx = (exit_at, header, latch)
        self._covered.add(latch)        # the bottom test became the while cond
        body = self._block(header, cond_at, ctx)
        stmts, stack = self._eval(cond_at, latch)
        cond = stack[-1] if stack else Const(1)
        if self.instrs[self.at[latch]][1] == "GoFalse":
            cond = _not(cond)
        if not stmts:
            return While(cond, body)
        # The test has side effects, so it cannot be hoisted into the header.
        return While(Const(1),
                     body + stmts + [If(_not(cond), [Break()], [])])

    def _eval(self, lo: int, hi: int):
        """Straight-line symbolic execution of [lo, hi): (statements, stack)."""
        stack: list[Expr] = []
        stmts: list[Stmt] = []
        addr = lo
        while addr < hi:
            i = self.at[addr]
            if self.instrs[i][1] in _JUMPS:
                break
            addr = self._step(i, stack, stmts)
        return stmts, stack

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
                    cond = _not(cond)
                self._covered.add(addr)     # the exit test became the while cond
                return cond, stmts, self._next_addr(addr)
            if mn in _JUMPS or mn in ("EndTimeslice", "TimedJump", "DebugSkip"):
                return None, [], header
            addr = self._step(i, stack, stmts)
        return None, [], header

    def _step(self, i: int, stack: list[Expr], out: list[Stmt]) -> int:
        off, mn, args = self.instrs[i]
        self._covered.add(off)
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
                if _keep_discarded(e):
                    out.append(Do(e))
        elif mn == "PopN":
            for _ in range(args[0]):
                if stack:
                    e = stack.pop()
                    if _keep_discarded(e):
                        out.append(Do(e))
        elif mn == "Copy":
            if stack:
                stack.append(stack[-1])
        elif mn == "NewObject":
            stack.append(New(p["obj_sites"].get(off, "FcScriptList")))
        elif mn in ("MarkObject", "DeleteMarkedObjects", "BeginAtomic",
                    "EndAtomic"):
            pass                       # engine-side object scoping / atomicity
        elif mn == "CloneObject":
            if stack:
                stack[-1] = Call("clone", [stack[-1]])
        elif mn in _BIN:
            # The compiler pushes the RIGHT operand first, so the LEFT one is on
            # top. FcScriptTask::Execute is unambiguous: SubtractI (0x1b) is
            # `second = top - second`, and LessI (0x23) is `top < second`.
            # Reading them the other way round silently reverses every
            # subtraction, division, modulus and comparison in the game.
            lhs = stack.pop() if stack else Const(0)
            rhs = stack.pop() if stack else Const(0)
            op, prec = _BIN[mn]
            stack.append(Bin(op, lhs, rhs, prec))
        elif mn in _UN:
            a = stack.pop() if stack else Const(0)
            stack.append(_not(a) if mn == "LogicalNot" else Un(_UN[mn], a))
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
        if isinstance(s, PcSet):
            return ["%spc = %d;" % (i, s.target)]
        if isinstance(s, Dispatch):
            out = ["%s// irreducible: rebuilt as its basic blocks" % i,
                   "%sint pc = %d;" % (i, s.entry),
                   "%swhile (1) switch (pc) {" % i]
            for addr, stmts in s.blocks:
                out.append("%scase %d:" % (_ind(d + 1), addr))
                out += self.body(stmts, d + 2)
            return out + [i + "}"]
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
        if isinstance(s, DoWhile):
            return [i + "do {"] + self.body(s.body, d + 1) \
                + ["%s} while (%s);" % (i, s.cond)]
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
        if isinstance(s, DoWhile):
            # GDScript has no do/while; the body must run once before the test.
            return ["%swhile true:" % i] + self.body(s.body, d + 1) \
                + ["%sif not (%s):" % (_ind(d + 1), _gx(s.cond)),
                   "%sbreak" % _ind(d + 2)]
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
    if isinstance(e, New):
        return _gd_new(e)
    return str(e)


def _gd_new(e: New) -> str:
    """A fresh POG object, as GDScript. A POG list and a POG set are both a
    plain Array here (scripts/pog/natives/std.gd implements list.* and set.*
    over Array), and a POG string is a String."""
    if e.kind == "FcScriptString":
        return '""'
    return "[]"


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
