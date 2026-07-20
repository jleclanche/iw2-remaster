"""Do native handlers actually WRITE the return value their SDK header declares?

Issue #24's gating question. The headers state intent, not a guarantee:
`GUI.SetEditBoxValue` is declared `string` but its handler never touches the
POG return slot (docs/original.md). Before the ported GDScript can be given
return types, every declaration has to be validated against its handler.

The binary side is uniform enough to audit mechanically. Every wrapper DLL
(the game install's bin/release/*.dll POG packages) registers its natives as

    push <handler>            ; 68 imm32 -> .text
    push <name>               ; 68 imm32 -> a NUL-terminated ASCII name
    mov  ecx, eax
    call [FcPackage::RegisterNative]

and every handler receives `FcArgs&` at [esp+4], whose FIRST dword is the
return slot. A handler that returns something writes through a register
holding that pointer:

    mov  [args], reg/imm      -> int / bool / handle
    mov  byte [args], al      -> bool
    fstp dword [args]         -> float
    (args pointer escapes into a call -> indirect write, e.g. FcString
     assignment for string returns -- classified MAYBE)

So: enumerate registrations, disassemble each handler up to the next known
handler, track which registers alias the FcArgs pointer, and classify.
Cross-checked against the SDK declarations (tools/iw2/pogsig.py). Read-only
on the game install; nothing here is committed game data (law 2).

Usage:  python -m tools.iw2.pogret [--verbose] [--pkg iship]
"""

from __future__ import annotations

import os
import re
import struct
import sys
from pathlib import Path

import capstone

GAME = Path(os.environ.get(
    "IW2_GAME_DIR",
    r"C:\Program Files (x86)\GOG Galaxy\Games\Independence War 2"))
RELEASE = GAME / "bin" / "release"

# DLL basename -> POG package name where they differ
_PKG_OF = {"gui_pkg": "gui"}

_NAME_RE = re.compile(rb"^[A-Za-z_][A-Za-z0-9_]*$")


def _sections(data: bytes):
    pe = struct.unpack_from("<I", data, 0x3C)[0]
    assert data[pe:pe + 4] == b"PE\0\0"
    n_sec = struct.unpack_from("<H", data, pe + 6)[0]
    opt_size = struct.unpack_from("<H", data, pe + 20)[0]
    base = struct.unpack_from("<I", data, pe + 24 + 28)[0]
    sec_off = pe + 24 + opt_size
    out = []
    for i in range(n_sec):
        o = sec_off + i * 40
        nm = data[o:o + 8].rstrip(b"\x00")
        va = struct.unpack_from("<I", data, o + 12)[0]
        vsz = struct.unpack_from("<I", data, o + 8)[0]
        raw = struct.unpack_from("<I", data, o + 20)[0]
        rsz = struct.unpack_from("<I", data, o + 16)[0]
        out.append((nm, va, vsz, raw, rsz))
    return base, out


def _param_bytes(sig: str, i: int) -> tuple[int, int] | None:
    """Stack bytes of ONE mangled parameter starting at sig[i] -> (bytes, next).

    Just enough of the MSVC scheme for the flux/iwar2 APIs: primitives,
    pointers/references (skip the pointee), by-value classes are unsupported
    (None -> the caller treats the whole callee as unknown)."""
    c = sig[i]
    if c in "CDEFGHIJKM":                  # char..uint, float
        return 4, i + 1
    if c == "N":                           # double
        return 8, i + 1
    if c == "X":                           # void (terminator)
        return 0, i + 1
    if c == "_":                           # _N bool, _J/_K int64
        c2 = sig[i + 1]
        return (8 if c2 in "JK" else 4), i + 2
    if c == "P" and i + 1 < len(sig) and sig[i + 1] == "6":
        # P6<conv><ret><params>@Z: pointer to function -- 4 bytes, skip to
        # the closing @Z of the function type
        end = sig.find("@Z", i)
        if end < 0:
            return None
        return 4, end + 2
    if c in "PAQ" and i + 1 < len(sig) and sig[i + 1] in "ABCD":
        # P[ABCD]<type> pointer / A[AB]<type> reference: 4 bytes, skip pointee
        j = i + 2
        if sig[j] in "VUT":                # class/struct/union pointee
            end = sig.find("@@", j)
            if end < 0:
                return None
            return 4, end + 2
        skipped = _param_bytes(sig, j)
        if skipped is None:
            return None
        return 4, skipped[1]
    if c in "VUT":                         # by-value class: size unknowable
        return None
    if c == "W":                           # W4<enum>@@: an enum, int-sized
        end = sig.find("@@", i)
        if end < 0:
            return None
        return 4, end + 2
    return None


def _callee_stack_bytes(mangled: str) -> int | None:
    """How many argument bytes a CALLEE-CLEANED import pops, from its mangled
    name. None = unknown or caller-cleaned (contributes nothing)."""
    if not mangled.startswith("?"):
        return None                        # extern "C" (kernel32 etc.)
    at = mangled.find("@@")
    if at < 0:
        return None
    sig = mangled[at + 2:]
    # member functions: [access][A|B (const)][E thiscall | G stdcall | A cdecl]
    # statics: S[A cdecl | G stdcall]; free: YA/YG
    conv = ""
    i = 0
    if sig[0] in "QUIMEA" and len(sig) > 2 and sig[1] in "AB" \
            and sig[2] in "EGA":
        conv = sig[2]
        i = 3
    elif sig[0] == "S" and sig[1] in "AG":
        conv = "G" if sig[1] == "G" else "A"
        i = 2
    elif sig[0] == "Y":
        conv = sig[1]
        i = 2
    else:
        return None
    if conv == "A":
        return 0                           # cdecl: caller cleans (add esp)
    total = 0
    # return type: ?A/?B prefix = qualified value return -> hidden sret arg
    if sig[i] == "?":
        i += 2
    if sig[i] in "VUT":                    # class returned by value: +sret
        total += 4
        end = sig.find("@@", i)
        if end < 0:
            return None
        i = end + 2
    elif sig[i] == "T":
        total += 4
    else:
        r = _param_bytes(sig, i)
        if r is None:
            return None
        i = r[1]
    while i < len(sig) and sig[i] != "Z":
        if sig[i] == "@":                  # end of arg list
            break
        r = _param_bytes(sig, i)
        if r is None:
            return None
        total += r[0]
        i = r[1]
    return total


class Dll:
    def __init__(self, path: Path):
        self.path = path
        self.data = path.read_bytes()
        self.base, self.secs = _sections(self.data)
        self.text = next(s for s in self.secs if s[0] == b".text")
        self.iat = self._imports()
        self._ret_pop: dict[int, int] = {}

    def callee_pop(self, va: int) -> int:
        """Stack bytes a LOCAL function pops on return: its `ret n`.
        Thiscall helpers (set.dll's rehash) clean their own arguments, and
        without this every such call drifts the caller's depth tracking."""
        if va in self._ret_pop:
            return self._ret_pop[va]
        pop = 0
        md = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_32)
        for ins in md.disasm(self.read_at_va(va, 0x400), va):
            if ins.mnemonic == "ret":
                pop = int(ins.op_str, 0) if ins.op_str else 0
                break
            if ins.mnemonic == "jmp":
                if ins.op_str.startswith("0x"):
                    # a thunk: the target's ret decides
                    pop = self.callee_pop(int(ins.op_str, 16))
                else:
                    # `jmp [import]` (the allocator thunks to msvcrt malloc):
                    # the import's convention decides; extern-C/cdecl -> 0.
                    # Scanning PAST an unresolved jmp picked up a stray
                    # `ret 0xc` from the next function -- never fall through.
                    im = re.fullmatch(r"dword ptr \[(0x[0-9a-f]+)\]",
                                      ins.op_str)
                    if im:
                        pop = _callee_stack_bytes(
                            self.iat.get(int(im.group(1), 16), "")) or 0
                break
        self._ret_pop[va] = pop
        return pop

    def _rva_off(self, rva: int) -> int:
        for _, sva, vsz, raw, _ in self.secs:
            if sva <= rva < sva + vsz:
                return raw + rva - sva
        return -1

    def _imports(self) -> dict[int, str]:
        """IAT slot VA -> imported (mangled) name."""
        pe = struct.unpack_from("<I", self.data, 0x3C)[0]
        opt = pe + 24
        imp_rva = struct.unpack_from("<I", self.data, opt + 104)[0]
        out: dict[int, str] = {}
        if not imp_rva:
            return out
        d = self._rva_off(imp_rva)
        while d >= 0:
            ilt, _, _, _, iat = struct.unpack_from("<IIIII", self.data, d)
            if not ilt and not iat:
                break
            lo = self._rva_off(ilt or iat)
            slot = iat
            while True:
                ent = struct.unpack_from("<I", self.data, lo)[0]
                if ent == 0:
                    break
                if not ent & 0x80000000:
                    no = self._rva_off(ent) + 2
                    name = self.data[no:self.data.find(b"\x00", no)]
                    out[self.base + slot] = name.decode(errors="replace")
                slot += 4
                lo += 4
            d += 20
        return out

    def va_ok(self, va: int, sec) -> bool:
        return sec[1] <= va - self.base < sec[1] + sec[2]

    def read_at_va(self, va: int, n: int) -> bytes:
        for _, sva, vsz, raw, _ in self.secs:
            off = va - self.base - sva
            if 0 <= off < vsz:
                return self.data[raw + off:raw + off + n]
        return b""

    def cstr_at_va(self, va: int) -> bytes:
        blob = self.read_at_va(va, 96)
        i = blob.find(b"\x00")
        return blob[:i] if i > 0 else b""

    def registrations(self) -> dict[int, str]:
        """handler VA -> native name, from every push/push RegisterNative pair."""
        _, tva, _, traw, trsz = self.text
        blob = self.data[traw:traw + trsz]
        out: dict[int, str] = {}
        i = 0
        while True:
            i = blob.find(b"\x68", i)
            if i < 0 or i + 10 > len(blob):
                break
            if blob[i + 5] != 0x68:          # need back-to-back push imm32
                i += 1
                continue
            handler = struct.unpack_from("<I", blob, i + 1)[0]
            name_va = struct.unpack_from("<I", blob, i + 6)[0]
            if self.va_ok(handler, self.text):
                name = self.cstr_at_va(name_va)
                if name and _NAME_RE.match(name):
                    out[handler] = name.decode()
            i += 1
        return out


# classification verdicts, strongest-evidence-first
NEVER, MAYBE, INT, BOOL, FLOAT = "never", "maybe", "int", "bool", "float"


def classify(dll: Dll, handler: int, hi: int, verbose=False) -> str:
    """What does this handler do to the return slot ([FcArgs+0])?

    Linear sweep to `hi` (the next known handler). Registers aliasing the
    FcArgs pointer are tracked through moves; eax/ecx/edx drop at calls
    (caller-saved). A write through an aliased register at displacement 0 is
    a typed return; the pointer escaping into a call (push / mov ecx / lea)
    is MAYBE -- an indirect write such as a string assignment.
    """
    code = dll.read_at_va(handler, min(hi - handler, 0x1000))
    md = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_32)
    md.detail = True
    args_regs: set[str] = set()
    verdict = NEVER
    order = [NEVER, MAYBE, INT, BOOL, FLOAT]
    # `[esp + 4]` is the FcArgs pointer only at the ENTRY depth; every push
    # shifts it. Track the depth or a local reload (`mov eax, [esp+0x20]`)
    # reads as the args pointer and poisons everything after it -- exactly
    # the false positive the ground-truth check caught.
    depth = 0
    ecx_fresh = -99                        # instr index of the last mov->ecx
    reg_import: dict[str, str] = {}        # register -> cached import name
    weak_reload: dict[str, int] = {}       # register -> idx of an esp reload
    framed = False                         # saw `mov ebp, esp` (frame pointer)
    idx = 0

    debug = bool(os.environ.get("POGRET_DEBUG"))
    cur = [None]

    def raise_to(v: str):
        nonlocal verdict
        if debug and order.index(v) > order.index(verdict):
            print("  raise %s at %s" % (v, cur[0]))
        if order.index(v) > order.index(verdict):
            verdict = v

    seen_ret = False
    for ins in md.disasm(code, handler):
        m, ops = ins.mnemonic, ins.op_str
        cur[0] = "%x: %s %s" % (ins.address, m, ops)
        # nop/int3 after a ret is FUNCTION PADDING: what follows is a local
        # helper with its own frame, whose [esp+8] is its own argument, not
        # FcArgs. Same-function exit blocks jump in with no padding.
        if m in ("nop", "int3") and seen_ret:
            break
        if m == "ret":
            seen_ret = True
        elif m != "nop":
            seen_ret = False
        idx += 1
        if m == "push":
            # a push at depth 0 is a prologue SAVE of a callee-saved register
            # (every wrapper saves before it loads), never an argument pass --
            # without this, a local helper's `push ebx` after the previous
            # function's ret reads as an escape
            if ops in args_regs and depth > 0:
                raise_to(MAYBE)            # args passed as an argument
            depth += 4
            continue
        if m == "pop":
            depth -= 4
            continue
        if m in ("sub", "add") and ops.startswith("esp, "):
            try:
                n = int(ops.split(", ")[1], 0)
                depth += n if m == "sub" else -n
            except ValueError:
                pass
            continue
        if m == "ret":
            # handlers have several exits; keep scanning. Depth resets, and
            # only CALLEE-SAVED registers keep their args tracking: a block
            # after a ret belongs to the same function reached by a branch
            # (ebx/esi/edi/ebp still hold what the entry loaded -- Brightness-
            # Of's float exit sits after its int `return 0` exit), or to a
            # local helper, whose own prologue re-derives everything.
            depth = 0
            args_regs &= {"ebx", "esi", "edi", "ebp"}
            continue
        if m == "mov" and ops == "ebp, esp":
            framed = True                  # frame pointer: args is [ebp + 8]
            continue
        if m == "mov" and framed:
            wm_bp = re.fullmatch(
                r"(e[a-d]x|e[sd]i|ebx), dword ptr \[ebp \+ 8\]", ops)
            if wm_bp:
                args_regs.add(wm_bp.group(1))
                if wm_bp.group(1) == "ecx":
                    ecx_fresh = idx
                continue
        wm_esp = re.fullmatch(
            r"(e[a-d]x|e[sd]i|ebp|ebx), dword ptr \[esp(?: \+ (\w+))?\]", ops)
        if m == "mov" and wm_esp:
            disp = int(wm_esp.group(2), 0) if wm_esp.group(2) else 0
            dst = wm_esp.group(1)
            if disp == depth + 4:
                args_regs.add(dst)         # the FcArgs pointer, depth-adjusted
            else:
                args_regs.discard(dst)
                # depth accounting is best-effort (unknown callees): remember
                # ANY esp reload briefly -- a write THROUGH it within a few
                # instructions is the string-return idiom (`mov edx,[esp+X];
                # mov [edx], str_obj`), which nothing else in these thin
                # wrappers looks like
                weak_reload[dst] = idx
            if dst == "ecx":
                ecx_fresh = idx
            continue
        if m == "mov":
            dst, _, src = ops.partition(", ")
            if dst == "ecx" and re.fullmatch(r"e[a-z]{2}", src):
                ecx_fresh = idx
            if re.fullmatch(r"e[a-z]{2}", dst):
                # wrappers cache imports in callee-saved registers
                # (`mov ebx, [Instance]; ... call ebx`); remember which import
                # a register holds so `call reg` pops the right stack bytes
                sm = re.fullmatch(r"dword ptr \[(0x[0-9a-f]+)\]", src)
                if sm and int(sm.group(1), 16) in dll.iat:
                    reg_import[dst] = dll.iat[int(sm.group(1), 16)]
                else:
                    reg_import.pop(dst, None)
            if src in args_regs and re.fullmatch(r"e[a-z]{2}", dst):
                args_regs.add(dst)
                continue
            if re.fullmatch(r"e[a-z]{2}", dst):
                args_regs.discard(dst)
            wm = re.fullmatch(r"(byte|word|dword) ptr \[(e[a-z]{2})\](.*)", dst)
            if wm and (wm.group(2) in args_regs
                    or idx - weak_reload.get(wm.group(2), -99) <= 4):
                raise_to(BOOL if wm.group(1) == "byte" else INT)
                continue
        if m in ("fstp", "fst"):
            wm = re.fullmatch(r"dword ptr \[(e[a-z]{2})\]", ops)
            if wm and (wm.group(1) in args_regs
                    or idx - weak_reload.get(wm.group(1), -99) <= 4):
                raise_to(FLOAT)
                continue
        if m == "lea":
            dst, _, src = ops.partition(", ")
            base = re.search(r"\[(e[a-z]{2})", src)
            if base and base.group(1) in args_regs:
                args_regs.add(dst)     # &args[k] still reaches the slot region
            elif re.fullmatch(r"e[a-z]{2}", dst):
                args_regs.discard(dst)
            if dst == "ecx":
                ecx_fresh = idx
            continue
        if m == "call":
            # thiscall escape: only when ecx was DELIBERATELY set just before
            # the call -- an entry-loaded args pointer still sitting in ecx at
            # an unrelated call (list.Append's allocator) is not an escape
            if "ecx" in args_regs and idx - ecx_fresh <= 3:
                raise_to(MAYBE)
            for r in ("eax", "ecx", "edx"):
                args_regs.discard(r)
            # a thiscall/stdcall import CLEANS ITS OWN stack arguments; not
            # accounting for that drifts the depth +4 per FindInstance-style
            # call, and every later args RELOAD ([esp + depth+4]) misreads as
            # a local -- the false-vestigial factory the wide run exposed
            mangled = ""
            im = re.fullmatch(r"dword ptr \[(0x[0-9a-f]+)\]", ops)
            if im:
                mangled = dll.iat.get(int(im.group(1), 16), "")
            elif ops in reg_import:
                mangled = reg_import[ops]
            popped = _callee_stack_bytes(mangled)
            if popped:
                depth -= popped
            elif ops.startswith("0x"):
                # a direct call to a local function: its `ret n` says what
                # it pops (thiscall helpers clean their own arguments)
                depth -= dll.callee_pop(int(ops, 16))
            continue
    return verdict


def main() -> None:
    from .pogsig import signatures
    verbose = "--verbose" in sys.argv
    only = ""
    if "--pkg" in sys.argv:
        only = sys.argv[sys.argv.index("--pkg") + 1].lower()
    sigs = signatures()

    audited: dict[str, str] = {}          # pkg.func (lower) -> verdict
    for dll_path in sorted(RELEASE.glob("*.dll")):
        pkg = _PKG_OF.get(dll_path.stem.lower(), dll_path.stem.lower())
        if only and pkg != only:
            continue
        # only DLLs that are POG packages: they register natives
        try:
            dll = Dll(dll_path)
        except (AssertionError, StopIteration):
            continue
        regs = dll.registrations()
        if not regs:
            continue
        bounds = sorted(regs) + [dll.base + dll.text[1] + dll.text[2]]
        for k, (hva, fn) in enumerate(sorted(regs.items())):
            hi = bounds[bounds.index(hva) + 1]
            v = classify(dll, hva, hi, verbose)
            audited["%s.%s" % (pkg, fn.lower())] = v

    # ---- cross-check against the SDK declarations
    n_match = n_vest = n_undecl = n_type = 0
    vestigial: list[str] = []
    undeclared: list[str] = []
    mismatch: list[str] = []
    unmatched = 0
    for key, v in sorted(audited.items()):
        sig = sigs.get(key)
        if sig is None:
            unmatched += 1
            continue
        ret = sig[0]                       # "" = void
        wrote = v not in (NEVER,)
        declared = ret not in ("", "task")
        if declared and v == NEVER:
            vestigial.append("%-44s declared %-8s handler never writes"
                             % (key, ret))
            n_vest += 1
        elif not declared and v in (INT, BOOL, FLOAT):
            undeclared.append("%-44s declared void, handler writes %s"
                              % (key, v))
            n_undecl += 1
        elif declared and v == FLOAT and ret not in ("float",):
            mismatch.append("%-44s declared %-8s handler writes float"
                            % (key, ret))
            n_type += 1
        elif declared and v in (INT, BOOL) and ret == "float":
            mismatch.append("%-44s declared float,   handler writes %s"
                            % (key, v))
            n_type += 1
        else:
            n_match += 1

    print("audited %d handlers across the wrapper DLLs" % len(audited))
    print("matched against %d SDK declarations (%d handler names have no "
          "SDK entry)" % (len(audited) - unmatched, unmatched))
    print("  agree (incl. MAYBE-indirect for declared returns): %d" % n_match)
    print("  VESTIGIAL declarations (declared, never written):  %d" % n_vest)
    print("  undeclared returns (void, but written):            %d" % n_undecl)
    print("  float/int type mismatches:                         %d" % n_type)
    for title, rows in [("VESTIGIAL", vestigial), ("UNDECLARED", undeclared),
                        ("TYPE MISMATCH", mismatch)]:
        if rows:
            print("\n-- %s --" % title)
            for r in rows:
                print("  " + r)


if __name__ == "__main__":
    main()
