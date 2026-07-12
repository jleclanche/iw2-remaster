"""Summarize a POG package as near-source pseudo-code.

Walks the disassembled instruction stream with a constant-tracking stack:
LoadString/LoadImmediate*/LoadZero/LoadOne push known constants, and at
every Call/Start the argument values are resolved where constant. Since
mission scripts pass mostly literal arguments, this recovers readable
event sequences (Say lines, objectives, prompts, sim spawns with
positions, waits) — the authoring source for mission.gd scripts.

Usage:  python -m tools.iw2.pogsummary <package-name> [package-name...]
"""

from __future__ import annotations

import sys
from pathlib import Path

from .pogdis import OPS, decode, parse_pkg

INTERESTING = (
    "iconversation.", "iobjectives.", "ihud.", "sim.Create", "sim.Destroy",
    "sim.PlaceRelativeTo", "iutilities.", "igame.", "iemail.",
    "ishipcreation.", "iai.", "group.", "istation.", "iship.",
    "imapentity.", "global.Set", "global.Create", "state.SetProgress",
    "task.Sleep", "imissiontracker.", "iinventory.", "icargoscript.",
    "iscriptedorders.", "ifactionscript.", "irangecheck.", "iwingmen.",
    "iformation.", "icomms.",
)


def summarize(pkg: dict) -> list[str]:
    code = pkg["code"]
    instrs = decode(code)
    funcs = {entry: name for name, entry in pkg["exports"].items()}
    for off, mn, args in instrs:
        if mn in ("CallLocal", "StartLocal"):
            funcs.setdefault(args[1], "local_%d" % args[1])
    out: list[str] = []
    stack: list = []  # constants or None
    for off, mn, args in instrs:
        if off in funcs:
            out.append("")
            out.append(f"== {funcs[off]} ==")
            stack = []
        if mn == "LoadString":
            idx = args[0]
            s = pkg["strings"][idx] if idx < len(pkg["strings"]) else "?"
            stack.append('"%s"' % s.replace("\n", "\\n"))
        elif mn in ("LoadImmediate8I", "LoadImmediate16I", "LoadImmediate32I"):
            stack.append(str(args[0]))
        elif mn == "LoadImmediate32U":
            stack.append("%g" % args[0])
        elif mn == "LoadZero":
            stack.append("0")
        elif mn == "LoadOne":
            stack.append("1")
        elif mn == "Load":
            stack.append("var%d" % (args[0] // 1))
        elif mn in ("Call", "Start", "CallLocal", "StartLocal"):
            if mn in ("Call", "Start"):
                target = pkg["call_sites"].get(off, "?")
            else:
                target = funcs.get(args[1], "local_%d" % args[1])
            argc = args[2]
            argv = []
            for _ in range(argc):
                v = stack.pop() if stack else "?"
                argv.append("<expr>" if v is None else v)
            argv.reverse()
            call = f"{target}({', '.join(argv)})"
            stack.append(None)  # return value, unknown
            low = target.lower()
            if any(low.startswith(p) or p in low for p in
                   [i.lower() for i in INTERESTING]):
                out.append(f"  {off:6d}  {call}")
        elif mn == "TimedJump":
            out.append(f"  {off:6d}  poll-wait (timeout->{args[0]})")
        elif mn == "Pop":
            if stack:
                stack.pop()
        elif mn in ("MarkObject", "DeleteMarkedObjects", "Copy",
                    "Debug43", "Debug44", "DebugSkip", "EndTimeslice"):
            pass  # stack-neutral for our purposes (Copy dups: keep simple)
        elif mn in ("Goto",):
            pass
        elif mn in ("GoFalse", "GoTrue"):
            if stack:
                stack.pop()
        elif mn in ("Store", "StoreObject"):
            pass  # value stays on stack in POG (Store then Pop)
        elif mn == "Return":
            stack = []
        else:
            # unknown effect: arithmetic pops 2 pushes 1, etc. — keep rough
            if OPS.get(code[off], ("", ""))[1] == "" and mn not in ("Return",):
                if len(stack) >= 2 and mn[0] in "ALGNSEMD":
                    stack.pop()
    return out


def main(argv: list[str]) -> int:
    from .resources import ResourceFS
    fs = ResourceFS()
    for name in argv:
        p = Path(name)
        data = p.read_bytes() if p.exists() else \
            fs.read_bytes(f"packages/{name}.pkg")
        pkg = parse_pkg(data)
        print(f"===== {pkg['name']} =====")
        for line in summarize(pkg):
            print(line)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
