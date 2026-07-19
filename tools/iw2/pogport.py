"""Port the missions to native GDScript.

pogdec turns the bytecode back into an AST. This turns that AST into GDScript
that runs on Godot directly -- no interpreter, no bytecode, no resource.zip at
runtime. The VM stays only as a differential oracle: run a mission both ways
and compare.

Two outputs, both under game/scripts/pog/gen/ (generated, committed):

  native_api.gd   a facade per engine package -- api.iship.find_player_ship().
                  Generated from the native bindings we already implemented, so
                  there is exactly one implementation of each native and the
                  ported scripts reach it through a typed method rather than a
                  string.

  <package>.gd    one per POG package, `extends PogScript`. Each declares the
                  packages it imports and binds them in _link(), so a call in
                  the original -- iutilities.SkipMission(...) -- comes out as
                  iutilities.skip_mission(...) and simply works.

The POG runtime concepts map onto Godot's own:

    task.Sleep(task.Current(), 2.0)   ->  await wait(2.0)
    <EndTimeslice>                    ->  await frame()
    start f(a, b)                     ->  spawn(f.bind(a, b))

A POG task is a coroutine, and a GDScript function with an await in it already
is one, so this is a change of spelling rather than of semantics.

Usage:
    python -m tools.iw2.pogport            # generate everything
    python -m tools.iw2.pogport --report   # what ported, what did not
"""

from __future__ import annotations

import argparse
import collections
import re
from pathlib import Path

from .pogdec import (Break, Call, Case, Const, Continue, Debug, Decompiler,
                     Dispatch,
                     DoWhile, Every, Expr, Func, Goto, Halt, If, New, Null,
                     PcSet, Ret, Str, Un, Var, While, Assign, Bin, Do, Yield,
                     argc_census, _gd_new, _snake)
from .pogdis import parse_pkg
from .pogsig import signatures
from .resources import ResourceFS

ROOT = Path(__file__).resolve().parents[2]
GEN = ROOT / "game" / "scripts" / "pog" / "gen"
NATIVES = ROOT / "game" / "scripts" / "pog" / "natives"

# GDScript will not accept these as variable names.
_RESERVED = {"set", "get", "in", "is", "as", "if", "else", "for", "while",
             "match", "func", "var", "const", "class", "extends", "return",
             "signal", "enum", "static", "self", "true", "false", "null",
             "and", "or", "not", "pass", "break", "continue", "await"}


def _pkgvar(name: str) -> str:
    n = name.lower()
    return "p_" + n if n in _RESERVED else n


# A ported POG function becomes a method on a Node, so it must not collide with
# one Godot already has (several packages export Name, Resume, Free, ...).
_TAKEN = {"name", "free", "queue_free", "call", "connect", "duplicate", "owner",
          "print", "notification", "to_string", "get_parent", "add_child",
          "remove_child", "process", "ready", "input", "setup", "resume",
          "suspend", "wait", "frame", "spawn", "halt", "clone", "detach",
          "get_name", "set_name", "get_path", "get_class", "get_index",
          "get_owner", "set_owner", "get_child", "get_children", "get_groups",
          "add_to_group", "is_in_group", "get_script", "set_script",
          # GDScript's own globals
          "load", "preload", "str", "int", "float", "bool", "range", "len",
          "min", "max", "abs", "sign", "round", "floor", "ceil", "clamp",
          "lerp", "randi", "randf", "assert", "hash", "printerr",
          "push_error", "push_warning", "type_of", "weakref", "sqrt", "pow",
          "sin", "cos", "tan", "is_instance_valid", "instance_from_id"}


def _fname(name: str) -> str:
    """Method name for a ported POG function."""
    n = _snake(name)
    return "pog_" + n if (n in _TAKEN or n in _RESERVED) else n


# Kept separate from _RESERVED, which _fname uses: broadening that would
# rename existing ported methods. This is the full GDScript keyword set,
# because the SDK names parameters things like `class_name` and a partial
# list only fails once it reaches the one you left out.
_GD_KEYWORDS = _RESERVED | {
    "class_name", "elif", "when", "super", "breakpoint", "preload", "yield",
    "assert", "void", "tool", "namespace", "trait", "PI", "TAU", "INF", "NAN",
}


def _pname(params: list[tuple[str, str]], i: int) -> str:
    """The SDK's own name for parameter `i`, made safe for GDScript.

    Falls back to `aN` for anything unusable: a missing name, a GDScript
    keyword, or a name that would shadow the facade's own `rt`.
    """
    name = _snake(params[i][1]) if params[i][1] else ""
    if name in _GD_KEYWORDS or name == "rt":
        return "a%d" % i
    if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", name):
        return "a%d" % i
    return name


def _ind(n: int) -> str:
    return "\t" * n


# --- native facades --------------------------------------------------------

_MARK = re.compile(r"#\s*@(?:native|stub)\s+([a-z_0-9]+)\.(\w+)")


def native_bindings() -> dict[str, list[str]]:
    """package -> [Func, ...], from the @native/@stub markers we maintain."""
    out: dict[str, set[str]] = collections.defaultdict(set)
    for f in NATIVES.glob("*.gd"):
        for m in _MARK.finditer(f.read_text(encoding="utf-8", errors="replace")):
            if m.group(1) == "pkg":
                continue        # the `@native pkg.Func` example in the docstring
            out[m.group(1)].add(m.group(2))
    return {k: sorted(v) for k, v in sorted(out.items())}


def gen_native_api() -> str:
    pkgs = native_bindings()
    L = ["class_name PogNativeApi", "extends RefCounted", "",
         "## GENERATED by tools/iw2/pogport.py -- do not edit.",
         "##",
         "## A typed facade over the engine's native packages, so a ported",
         "## mission calls api.iship.find_player_ship() rather than poking a",
         "## string into a dispatch table. The implementations live in",
         "## scripts/pog/natives/ and are shared with the VM oracle.", "",
         "var _rt: PogRuntime", ""]

    # NB the inner class names are prefixed: several packages are called things
    # Godot already owns (object, string, input).
    # The SDK headers declare every native properly, so the facade can name its
    # parameters the way the original API does and cite the prototype it came
    # from. Types are NOT applied here: a native declared `hgroup` whose
    # implementation returns 0 on an error path would turn a silent wrongness
    # into a hard crash, and how often that happens is not yet measured.
    try:
        sigs = signatures()
    except SystemExit:
        sigs = {}                      # SDK not installed: names stay a0, a1

    for pkg, fns in pkgs.items():
        cls = "Pkg" + pkg.capitalize()
        L.append("class %s extends RefCounted:" % cls)
        L.append("\tvar rt: PogRuntime")
        for fn in fns:
            n = _ARGC.get("%s.%s" % (pkg, fn), 0)
            ret, params = sigs.get("%s.%s" % (pkg.lower(), fn.lower()),
                                   ("", []))
            names = [_pname(params, i) for i in range(n)] if len(
                params) == n else ["a%d" % i for i in range(n)]
            args = ", ".join(names)
            if params or ret:
                decl = ", ".join("%s %s" % t for t in params)
                L.append("\t## prototype %s %s.%s(%s)"
                         % (ret or "void", pkg.capitalize(), fn,
                            " %s " % decl if decl else ""))
            L.append("\tfunc %s(%s) -> Variant:" % (_fname(fn), args))
            L.append('\t\treturn rt.native("%s.%s", [%s])'
                     % (pkg, fn.lower(), args))
        L.append("")

    for pkg in pkgs:
        L.append("var %s: Pkg%s" % (_pkgvar(pkg), pkg.capitalize()))
    L.append("")
    L.append("func _init(rt: PogRuntime) -> void:")
    L.append("\t_rt = rt")
    for pkg in pkgs:
        L.append("\t%s = Pkg%s.new()" % (_pkgvar(pkg), pkg.capitalize()))
        L.append("\t%s.rt = rt" % _pkgvar(pkg))
    return "\n".join(L) + "\n"


# --- the GDScript backend for ported scripts -------------------------------


class Port:
    def __init__(self, pkg_name: str, imports: dict[str, bool],
                 taken: set[str] | None = None):
        self.pkg = pkg_name
        self.imports = imports       # package -> is_native
        self.unstructured = 0
        # A package variable must not collide with a function in this same file
        # (several packages export a Group() and also import `group`).
        self.taken = taken or set()

    def pkgvar(self, pkg: str) -> str:
        v = _pkgvar(pkg)
        return "p_" + v if v in self.taken else v

    # -- expressions

    def x(self, e: Expr) -> str:
        if isinstance(e, Call):
            return self.call(e)
        if isinstance(e, Bin):
            # POG compares raw 32-bit words, so `handle == 0` is how a script
            # asks "is this null". GDScript will not compare an Object or a
            # String to an int at all, so that idiom needs a helper.
            if e.op in ("==", "!="):
                z = self._zero_test(e)
                if z is not None:
                    return z
                # Neither side is a literal, so the types are not known here
                # either; compare the POG way.
                if not isinstance(e.a, Const) and not isinstance(e.b, Const):
                    s = "_pog_eq(%s, %s)" % (self.x(e.a), self.x(e.b))
                    return s if e.op == "==" else "not " + s
            op = {"&&": "and", "||": "or"}.get(e.op, e.op)
            return "%s %s %s" % (self._operand(e, e.a), op,
                                 self._operand(e, e.b))
        if isinstance(e, Un):
            if e.op == "!":
                return "not (%s)" % self.x(e.a)
            return "%s(%s)" % (e.op, self.x(e.a))
        if isinstance(e, Null):
            return "null"
        if isinstance(e, New):
            # NewObject. A fresh Array (list/set) or String, *per evaluation* --
            # the whole point is that the object is new and that the natives
            # handed it can fill it in place.
            return _gd_new(e)
        return str(e)

    def _operand(self, parent: Bin, child: Expr) -> str:
        """A Bin operand, parenthesised whenever the reading could regroup.

        This emitter used to add no parentheses at all, trusting the AST's
        shape to survive re-parsing -- it does not. `FrameHeight() - (rise +
        offset + 10)` came out as `FrameHeight() - rise + offset + 10`, which
        is 104 px taller, and every grey-box screen ran off the bottom of the
        frame. GDScript's precedence table also is not POG's (POG gives `&`,
        `|` and `^` a single level), so the safe rule is: parenthesise every
        bound subtree at equal-or-lower precedence, except a same-operator
        associative chain.
        """
        s = self.x(child)
        if not isinstance(child, Bin):
            return s
        if child.prec > parent.prec:
            return s
        if child.op == parent.op and parent.op in ("+", "*", "&&", "||"):
            return s
        return "(%s)" % s

    def _zero_test(self, e: Bin) -> str | None:
        other = None
        if isinstance(e.b, Const) and e.b.v == 0:
            other = e.a
        elif isinstance(e.a, Const) and e.a.v == 0:
            other = e.b
        if other is None:
            return None
        s = "_pog_is_null(%s)" % self.x(other)
        return s if e.op == "==" else "not " + s

    def call(self, e: Call) -> str:
        target = e.target
        args = [self.x(a) for a in e.args]

        if target.startswith("_pog_"):      # a PogScript helper, not a coroutine
            return "%s(%s)" % (target, ", ".join(args))

        if "." in target:
            pkg, fn = target.split(".", 1)
            pkg = pkg.lower()

            # The task package is POG's coroutine runtime; Godot has its own.
            if pkg == "task":
                t = self.task(fn, e.args, args)
                if t is not None:
                    return t

            # PlayMovie blocks the script until the cinematic ends. A native
            # cannot await, so the port turns it back into one.
            if pkg == "igame" and fn.lower() in ("playmovie", "playmovielooped"):
                return "await _pog_movie(%s)" % (args[0] if args else '""')

            recv = self.pkgvar(pkg)
            if self.imports.get(pkg, True):        # native: a plain call
                return "%s.%s(%s)" % (recv, _fname(fn), ", ".join(args))
            # another ported script: it is a coroutine, so it must be awaited
            if e.spawn:
                return "_pog_spawn(%s.%s.bind(%s))" % (recv, _fname(fn),
                                                       ", ".join(args))
            return "await %s.%s(%s)" % (recv, _fname(fn), ", ".join(args))

        # `clone` is CloneObject, which PogScript provides; everything else
        # without a package is a function in this same file.
        if target == "clone":
            return "_pog_clone(%s)" % (args[0] if args else "null")
        if e.spawn:
            return "_pog_spawn(%s.bind(%s))" % (_fname(target), ", ".join(args))
        return "await %s(%s)" % (_fname(target), ", ".join(args))

    def task(self, fn: str, raw: list, args: list[str]) -> str | None:
        """POG's coroutine runtime, rewritten onto Godot's own. Every one of
        these becomes a method on PogScript, so it is valid in statement
        position as well as inside an expression."""
        f = fn.lower()
        a0 = args[0] if args else "null"
        if f == "current":
            return "self"
        if f == "sleep":
            return "await _pog_wait(%s)" % (args[1] if len(args) > 1 else "0.0")
        if f == "ishalted":
            return "(1 - _pog_is_running(%s))" % a0
        if f in ("halt", "isrunning", "detach", "suspend", "resume", "cast"):
            return "_pog_%s(%s)" % ({"isrunning": "is_running",
                                     "cast": "task_cast"}.get(f, f), a0)
        if f in ("suspendall", "resumeall"):
            return "_pog_%s_all()" % f[:-3]
        if f == "call":
            return "await _run_now(%s)" % a0
        return None

    # -- statements

    def body(self, stmts, d) -> list[str]:
        out = []
        for s in stmts:
            out += self.stmt(s, d)
        return out or [_ind(d) + "pass"]

    def stmt(self, s, d) -> list[str]:
        i = _ind(d)
        if isinstance(s, Assign):
            return ["%s%s = %s" % (i, s.var, self.x(s.expr))]
        if isinstance(s, Do):
            return ["%s%s" % (i, self.x(s.expr))]
        if isinstance(s, Ret):
            return [i + "return"] if s.expr is None \
                else ["%sreturn %s" % (i, self.x(s.expr))]
        if isinstance(s, Halt):
            return [i + "return"]
        if isinstance(s, Yield):
            return [i + "await _pog_frame()"]
        if isinstance(s, Break):
            return [i + "break"]
        if isinstance(s, Continue):
            return [i + "continue"]
        if isinstance(s, PcSet):
            return ["%s_pc = %d" % (i, s.target), "%scontinue" % i]
        if isinstance(s, Dispatch):
            # Irreducible control flow, rebuilt as its basic blocks under an
            # explicit pc. Not pretty, but exact -- and it runs.
            self.unstructured += 1
            out = ["%svar _pc: int = %d" % (i, s.entry),
                   "%swhile true:" % i]
            first = True
            for addr, stmts in s.blocks:
                kw = "if" if first else "elif"
                first = False
                out.append("%s%s _pc == %d:" % (_ind(d + 1), kw, addr))
                out += self.body(stmts, d + 2)
            out.append("%selse:" % _ind(d + 1))
            out.append("%sreturn 0" % _ind(d + 2))
            return out
        if isinstance(s, Goto):
            self.unstructured += 1
            return ["%spush_error(\"PORT: unstructured jump to L%d\")"
                    % (i, s.target)]
        if isinstance(s, Debug):
            return ["%sif PogRuntime.TRACE:" % i] + self.body(s.body, d + 1)
        if isinstance(s, Every):
            return ["%swhile true:" % i,
                    "%sawait _pog_wait(%g)" % (_ind(d + 1), s.secs)] \
                + self.body(s.body, d + 1)
        if isinstance(s, While):
            return ["%swhile %s:" % (i, self.x(s.cond))] \
                + self.body(s.body, d + 1)
        if isinstance(s, DoWhile):
            return ["%swhile true:" % i] + self.body(s.body, d + 1) \
                + ["%sif not (%s):" % (_ind(d + 1), self.x(s.cond)),
                   "%sbreak" % _ind(d + 2)]
        if isinstance(s, If):
            out = ["%sif %s:" % (i, self.x(s.cond))] + self.body(s.then, d + 1)
            if s.els:
                out += [i + "else:"] + self.body(s.els, d + 1)
            return out
        if isinstance(s, Case):
            out = ["%smatch %s:" % (i, self.x(s.sel))]
            for vals, body in s.arms:
                out += ["%s%s:" % (_ind(d + 1),
                                   ", ".join(self.x(v) for v in vals))]
                out += self.body(body, d + 2)
            return out
        return [i + "pass"]

    def func(self, f: Func, nlocals: int) -> list[str]:
        params = ", ".join("v%d" % k for k in range(f.argc))
        L = ["func %s(%s) -> Variant:" % (_fname(f.name), params)]
        for k in range(f.argc, nlocals):
            L.append("\tvar v%d: Variant = 0" % k)
        L += self.body(f.body, 1)
        L.append("\treturn 0")
        L.append("")
        return L


def _locals_used(f: Func) -> int:
    """How many locals the function touches, so we can declare them."""
    hi = [f.argc]

    def walk_e(e):
        if isinstance(e, Var):
            hi[0] = max(hi[0], e.n + 1)
        elif isinstance(e, Bin):
            walk_e(e.a)
            walk_e(e.b)
        elif isinstance(e, Un):
            walk_e(e.a)
        elif isinstance(e, Call):
            for a in e.args:
                walk_e(a)

    def walk(stmts):
        for s in stmts:
            if isinstance(s, Assign):
                walk_e(s.var)
                walk_e(s.expr)
            elif isinstance(s, (Do,)):
                walk_e(s.expr)
            elif isinstance(s, Ret) and s.expr is not None:
                walk_e(s.expr)
            elif isinstance(s, If):
                walk_e(s.cond)
                walk(s.then)
                walk(s.els)
            elif isinstance(s, (While, DoWhile)):
                walk_e(s.cond)
                walk(s.body)
            elif isinstance(s, (Every, Debug)):
                walk(s.body)
            elif isinstance(s, Case):
                walk_e(s.sel)
                for _vals, body in s.arms:
                    walk(body)
            elif isinstance(s, Dispatch):
                for _addr, body in s.blocks:
                    walk(body)

    walk(f.body)
    return hi[0]


_ARGC: dict[str, int] = {}
_SCRIPTS: set[str] = set()      # packages we have bytecode for, i.e. ported


def port_package(name: str, fs: ResourceFS, natives: dict) -> tuple[str, int, int]:
    pkg = parse_pkg(fs.read_bytes("packages/%s.pkg" % name))
    d = Decompiler(pkg, _ARGC)
    funcs = d.functions()

    # A package is native only if it has no bytecode of its own. Some do have
    # bytecode *and* a native binding (istation), and the bytecode wins: that is
    # the real implementation, and it is what we ported.
    imports: dict[str, bool] = {}
    for target in pkg["call_sites"].values():
        p = target.split(".", 1)[0].lower()
        imports[p] = p not in _SCRIPTS

    fnames = {_fname(f.name) for f in funcs}
    port = Port(name, imports, fnames)
    lines = ["extends PogScript", "",
             "## GENERATED by tools/iw2/pogport.py from the original bytecode of",
             "## package %s. Do not edit; edit the porter." % pkg["name"], ""]

    used = sorted(p for p in imports if p != "task")
    for p in used:
        lines.append("var %s" % port.pkgvar(p))
    if used:
        lines.append("")
        lines.append("func _link() -> void:")
        for p in used:
            if imports[p]:
                lines.append("\t%s = api.%s" % (port.pkgvar(p), _pkgvar(p)))
            else:
                lines.append('\t%s = rt.script("%s")' % (port.pkgvar(p), p))
        lines.append("")

    bad_funcs = 0
    for f in funcs:
        before = port.unstructured
        lines += port.func(f, _locals_used(f))
        if port.unstructured > before:
            bad_funcs += 1

    return "\n".join(lines) + "\n", len(funcs), bad_funcs


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--report", action="store_true")
    args = ap.parse_args()

    _ARGC.update(argc_census())
    natives = native_bindings()
    GEN.mkdir(parents=True, exist_ok=True)

    (GEN / "native_api.gd").write_text(gen_native_api(), encoding="utf-8")

    fs = ResourceFS()
    _SCRIPTS.update(Path(p).stem.lower() for p in fs.list("packages/", ".pkg"))
    total = clean = pkgs = 0
    broken: list[tuple[str, int, int]] = []
    for path in fs.list("packages/", ".pkg"):
        stem = Path(path).stem.lower()
        src, nfuncs, bad = port_package(stem, fs, natives)
        (GEN / ("%s.gd" % stem)).write_text(src, encoding="utf-8")
        pkgs += 1
        total += nfuncs
        clean += nfuncs - bad
        if bad:
            broken.append((stem, nfuncs, bad))

    print("ported %d packages, %d functions -> %s" % (pkgs, total, GEN))
    print("  %d/%d as structured code (%.1f%%)"
          % (clean, total, 100.0 * clean / total))
    print("  %d as a basic-block dispatch (irreducible, but exact)"
          % (total - clean))
    if args.report:
        for stem, n, bad in sorted(broken, key=lambda x: -x[2]):
            print("    %-28s %d/%d" % (stem, bad, n))


if __name__ == "__main__":
    main()
