"""Disassembler for IW2 POG VM bytecode (the CODE chunk of packages/*.pkg).

The opcode table was recovered empirically: the POG SDK's own compiler
(``pc.exe -ma``) emits assembler listings (*.mog) with byte offsets, and
the SDK ships the *source* of three original campaign missions.  Compiling
those and aligning listing offsets against the compiled CODE bytes gives
an unambiguous opcode map (``--selftest`` re-validates the round trip).

CODE chunk layout: u32be code size, then bytecode.  Instructions are an
opcode byte followed by little-endian operands.  Branch operands are
absolute code offsets.  Call/Start are 13 bytes: opcode + three u32le
fields (imported calls are resolved at load time through the FIMP
call-site tables; local calls carry the callee's entry offset in the
second field; the third field is the argument count... except for local
calls where argc lives in the first field pair — we print all three).

Stack machine: LoadZero/LoadOne/LoadImmediate*/Load/Store work a value
stack; Reserve allocates function locals (Load/Store operands are local
slot byte-offsets); MarkObject/DeleteMarkedObjects scope temporary object
handles; LoadString pushes STAB[i]; DebugSkip jumps past ``debug``
statements when debugging is off.

Usage:
    python -m tools.iw2.pogdis <package-name|pkg-path> [-o out.txt]
    python -m tools.iw2.pogdis --all [out_dir]      # every retail package
    python -m tools.iw2.pogdis --selftest           # vs build/pogtests
"""

from __future__ import annotations

import struct
import sys
from pathlib import Path

# opcode -> (mnemonic, operand-format)
#   ""  none                b  s8      B  u8      h  s16     i  s32
#   f   f32                 u  u32     t  u32 branch target
#   C   3 x u32 (Call/Start/TimedJump)
OPS: dict[int, tuple[str, str]] = {
    0x01: ("Pop", ""),
    0x02: ("PopN", "B"),
    0x03: ("Copy", ""),
    0x04: ("LoadZero", ""),
    0x05: ("LoadOne", ""),
    0x06: ("LoadImmediate8I", "b"),
    0x07: ("LoadImmediate16I", "h"),
    0x08: ("LoadImmediate32I", "i"),
    0x0B: ("LoadImmediate32U", "f"),
    0x0C: ("Load", "u"),
    0x0D: ("Store", "u"),
    0x0E: ("Reserve", "u"),
    0x0F: ("Goto", "t"),
    0x10: ("GoFalse", "t"),
    0x11: ("GoTrue", "t"),
    0x13: ("Return", ""),
    0x14: ("CallLocal", "C"),
    0x15: ("Call", "C"),
    0x17: ("StartLocal", "C"),
    0x18: ("Start", "C"),
    0x1A: ("AddI", ""),
    0x1B: ("SubtractI", ""),
    0x1C: ("MultiplyI", ""),
    0x1D: ("DivideI", ""),
    0x1E: ("ModulusI", ""),        # gap-filled; not seen in samples yet
    0x1F: ("NegateI", ""),
    0x20: ("Equal", ""),
    0x21: ("NotEqual", ""),
    0x22: ("GreaterI", ""),
    0x23: ("LessI", ""),
    0x24: ("GreaterEqualI", ""),
    0x25: ("LessEqualI", ""),
    0x26: ("AddF", ""),
    0x27: ("SubtractF", ""),
    0x28: ("MultiplyF", ""),       # gap-filled
    0x29: ("DivideF", ""),         # gap-filled
    0x2B: ("NegateF", ""),
    0x2C: ("GreaterF", ""),
    0x2D: ("LessF", ""),
    0x2E: ("GreaterEqualF", ""),
    0x2F: ("LessEqualF", ""),
    0x30: ("LogicalAnd", ""),
    0x31: ("LogicalOr", ""),
    0x32: ("LogicalNot", ""),
    0x37: ("IntToFloat", ""),
    0x38: ("FloatToInt", ""),
    0x39: ("ToBool", ""),
    0x3A: ("NewObject", "u"),
    0x3B: ("MarkObject", ""),
    0x3C: ("DeleteMarkedObjects", ""),
    0x3D: ("StoreObject", "u"),
    0x3E: ("LoadString", "u"),
    0x3F: ("EqualObjects", ""),
    0x40: ("CloneObject", ""),
    0x41: ("EndTimeslice", ""),
    0x42: ("TimedJump", "C"),
    0x43: ("Debug43", ""),
    0x44: ("Debug44", ""),
    0x45: ("DebugSkip", "t"),
}

_SIZE = {"": 0, "b": 1, "B": 1, "h": 2, "i": 4, "f": 4, "u": 4, "t": 4,
         "C": 12}


def _nulstr(body: bytes, pos: int = 0) -> tuple[str, int]:
    end = body.index(b"\x00", pos)
    return body[pos:end].decode("latin-1"), end + 1


def parse_pkg(data: bytes) -> dict:
    assert data[:4] == b"FORM" and data[8:12] == b"PKG ", "not a PKG form"
    off = 12
    pkg: dict = {"name": "?", "exports": {}, "strings": [],
                 "call_sites": {}, "code": b""}
    cur = None
    while off + 8 <= len(data):
        tag = data[off:off + 4]
        (size,) = struct.unpack_from(">I", data, off + 4)
        body = data[off + 8: off + 8 + size]
        if tag == b"PKHD":
            pkg["name"], _ = _nulstr(body)
        elif tag == b"PIMP":
            cur, _ = _nulstr(body)
        elif tag == b"FIMP":
            name, p = _nulstr(body)
            (count,) = struct.unpack_from(">I", body, p)
            for site in struct.unpack_from(f">{count}I", body, p + 4):
                pkg["call_sites"][site] = f"{cur}.{name}"
        elif tag == b"FEXP":
            name, p = _nulstr(body)
            (entry,) = struct.unpack_from(">I", body, p)
            pkg["exports"][name] = entry
        elif tag == b"STAB":
            (count,) = struct.unpack_from(">I", body, 0)
            pkg["strings"] = [s.decode("latin-1")
                              for s in body[4:].split(b"\x00")][:count]
        elif tag == b"CODE":
            pkg["code"] = body[4:]  # u32be size prefix, then bytecode
        off += 8 + size + (size & 1)
    return pkg


def decode(code: bytes) -> list[tuple[int, str, list]]:
    """Linear decode: (offset, mnemonic, operands)."""
    out = []
    pos = 0
    while pos < len(code):
        op = code[pos]
        mn, fmt = OPS.get(op, ("DB 0x%02X" % op, ""))
        args: list = []
        p = pos + 1
        if fmt == "b":
            args = [struct.unpack_from("<b", code, p)[0]]
        elif fmt == "B":
            args = [code[p]]
        elif fmt == "h":
            args = [struct.unpack_from("<h", code, p)[0]]
        elif fmt == "i":
            args = [struct.unpack_from("<i", code, p)[0]]
        elif fmt == "f":
            args = [struct.unpack_from("<f", code, p)[0]]
        elif fmt in ("u", "t"):
            args = [struct.unpack_from("<I", code, p)[0]]
        elif fmt == "C":
            args = list(struct.unpack_from("<3I", code, p))
        out.append((pos, mn, args))
        pos += 1 + _SIZE[fmt]
    return out


def _esc(s: str) -> str:
    return s.replace("\\", "\\\\").replace("\n", "\\n").replace("\r", "\\r")


def disassemble(pkg: dict) -> str:
    code = pkg["code"]
    instrs = decode(code)
    # name every function entry: exports + local Call/Start targets
    funcs = {entry: name for name, entry in pkg["exports"].items()}
    for off, mn, args in instrs:
        if mn in ("CallLocal", "StartLocal"):
            funcs.setdefault(args[1], "local_%d" % args[1])
    labels = set()
    for off, mn, args in instrs:
        if mn in ("Goto", "GoFalse", "GoTrue", "DebugSkip"):
            labels.add(args[0])
    lines = [f"; package {pkg['name']}  ({len(code)} bytes, "
             f"{len(pkg['strings'])} strings)"]
    for off, mn, args in instrs:
        if off in funcs:
            lines.append("")
            lines.append(f"{funcs[off]}:  ; entry {off}")
        elif off in labels:
            lines.append(f"L{off}:")
        txt = ""
        if mn in ("Call", "Start"):
            target = pkg["call_sites"].get(off, "?imported?")
            txt = f"{mn} {target} argc={args[2]}"
        elif mn in ("CallLocal", "StartLocal"):
            target = funcs.get(args[1], "local_%d" % args[1])
            txt = f"{mn} {target} argc={args[2]}"
        elif mn == "TimedJump":
            txt = f"TimedJump {args[0]} {args[1]} {args[2]}"
        elif mn == "LoadString":
            idx = args[0]
            s = pkg["strings"][idx] if idx < len(pkg["strings"]) else "?"
            txt = f'LoadString #{idx} "{_esc(s)}"'
        elif mn in ("Goto", "GoFalse", "GoTrue", "DebugSkip"):
            txt = f"{mn} L{args[0]}"
        elif mn == "LoadImmediate32U":
            txt = f"{mn} {args[0]!r}"
        else:
            txt = mn + ("" if not args else " " + " ".join(str(a) for a in args))
        lines.append(f"  {off:6d}  {txt}")
    lines.append("")
    return "\n".join(lines)


# --- selftest against the SDK compiler's own listings -----------------------

_MOG_PAIRS = [
    ("t01empty.mog", "t01empty.pkg"),
    ("iAct1Mission05.mog", "iact1mission05.pkg"),
    ("iAct2Mission25.mog", "iact2mission25.pkg"),
    ("challenge_course.mog", "challenge_course.pkg"),
    ("LocationFinder.mog", "locationfinder.pkg"),
]

_ALIAS = {"CallLocal": "Call", "StartLocal": "Start",
          "Debug43": "<unnamed>", "Debug44": "<unnamed>",
          "DebugSkip": "<unnamed>"}


def selftest(tests_dir: str = "build/pogtests") -> int:
    import re
    line_re = re.compile(r"^\s*(\d+):(\S*)")
    fails = 0
    for mog, pkgname in _MOG_PAIRS:
        mp = Path(tests_dir) / mog
        pp = Path(tests_dir) / pkgname
        if not (mp.exists() and pp.exists()):
            print(f"skip {mog}")
            continue
        want = []
        for line in mp.read_text(encoding="latin-1").splitlines():
            if line.lstrip().startswith(";"):
                continue
            m = line_re.match(line)
            if m:
                want.append((int(m.group(1)), m.group(2) or "<unnamed>"))
        pkg = parse_pkg(pp.read_bytes())
        got = [(off, _ALIAS.get(mn, mn)) for off, mn, _ in decode(pkg["code"])]
        if got == want:
            print(f"PASS {pkgname}: {len(got)} instructions")
        else:
            fails += 1
            for i, (g, w) in enumerate(zip(got, want)):
                if g != w:
                    print(f"FAIL {pkgname} at #{i}: got {g}, want {w}")
                    break
            else:
                print(f"FAIL {pkgname}: length {len(got)} vs {len(want)}")
    return fails


def main(argv: list[str]) -> int:
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__)
        return 0
    if argv[0] == "--selftest":
        return selftest(*argv[1:])
    if argv[0] == "--all":
        from .resources import ResourceFS
        out_dir = Path(argv[1] if len(argv) > 1 else "data/pogdis")
        out_dir.mkdir(parents=True, exist_ok=True)
        fs = ResourceFS()
        n = 0
        for path in fs.list("packages/", ".pkg"):
            pkg = parse_pkg(fs.read_bytes(path))
            stem = Path(path).stem.lower()
            (out_dir / f"{stem}.pogasm").write_text(disassemble(pkg),
                                                    encoding="utf-8")
            n += 1
        print(f"disassembled {n} packages -> {out_dir}")
        return 0
    target = argv[0]
    p = Path(target)
    if p.exists():
        data = p.read_bytes()
    else:
        from .resources import ResourceFS
        data = ResourceFS().read_bytes(f"packages/{target}.pkg")
    text = disassemble(parse_pkg(data))
    if len(argv) > 2 and argv[1] == "-o":
        Path(argv[2]).write_text(text, encoding="utf-8")
    else:
        sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
