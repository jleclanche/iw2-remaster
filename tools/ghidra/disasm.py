"""Raw-disassemble a VA range of a PE with capstone.

Ghidra's decompiler silently drops functions it cannot recover ("could not
recover jumptable", or regions its disassembler never reached).  The bytes
are still in the file: this reads them straight out of the PE section table
and prints x86 disassembly, annotating call/jmp targets with names from the
matching data/decomp/<name>.symbols.txt and dereferencing import thunks.

Usage:
  python tools/ghidra/disasm.py build/bin/iwar2.dll 0x100d2b30 [end|+len]
  python tools/ghidra/disasm.py build/bin/dx7graph.dll 0x10007600 +0x200
"""

from __future__ import annotations

import os
import struct
import sys

import capstone


def sections(data: bytes):
    pe = struct.unpack_from("<I", data, 0x3C)[0]
    assert data[pe:pe + 4] == b"PE\0\0", "not a PE"
    n_sec = struct.unpack_from("<H", data, pe + 6)[0]
    opt_size = struct.unpack_from("<H", data, pe + 20)[0]
    base = struct.unpack_from("<I", data, pe + 24 + 28)[0]
    sec_off = pe + 24 + opt_size
    out = []
    for i in range(n_sec):
        o = sec_off + i * 40
        va = struct.unpack_from("<I", data, o + 12)[0]
        vsz = struct.unpack_from("<I", data, o + 8)[0]
        raw = struct.unpack_from("<I", data, o + 20)[0]
        rawsz = struct.unpack_from("<I", data, o + 16)[0]
        out.append((va, vsz, raw, rawsz))
    return base, out


def va_to_off(base, secs, va):
    rva = va - base
    for sva, vsz, raw, rawsz in secs:
        if sva <= rva < sva + max(vsz, 1):
            return raw + (rva - sva), min(rawsz - (rva - sva), vsz - (rva - sva))
    raise SystemExit("VA 0x%x not in any section" % va)


def imports(data: bytes, base: int, secs):
    """IAT entry VA -> dll!name, so `call [0x1001xxxx]` resolves."""
    pe = struct.unpack_from("<I", data, 0x3C)[0]
    imp_rva = struct.unpack_from("<I", data, pe + 24 + 104)[0]
    out = {}
    if not imp_rva:
        return out
    off, _ = va_to_off(base, secs, base + imp_rva)
    while True:
        oft, _, _, name_rva, iat = struct.unpack_from("<IIIII", data, off)
        if not (oft or iat):
            break
        doff, _ = va_to_off(base, secs, base + name_rva)
        dll = data[doff:data.index(b"\0", doff)].decode()
        toff, _ = va_to_off(base, secs, base + (oft or iat))
        slot = iat
        while True:
            thunk = struct.unpack_from("<I", data, toff)[0]
            if not thunk:
                break
            if thunk & 0x80000000:
                nm = "#%d" % (thunk & 0xFFFF)
            else:
                noff, _ = va_to_off(base, secs, base + thunk)
                nm = data[noff + 2:data.index(b"\0", noff + 2)].decode()
            out[base + slot] = "%s!%s" % (dll, nm)
            toff += 4
            slot += 4
        off += 20
    return out


def load_symbols(pe_path):
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    p = os.path.join(root, "data", "decomp",
                     os.path.basename(pe_path) + ".symbols.txt")
    syms = {}
    if os.path.exists(p):
        for line in open(p, encoding="utf-8", errors="replace"):
            parts = line.rstrip("\n").split("\t")
            if len(parts) >= 2:
                try:
                    syms[int(parts[0], 16)] = parts[1]
                except ValueError:
                    pass
    return syms


def main(argv):
    path = argv[0]
    start = int(argv[1], 16)
    if len(argv) > 2:
        end = start + int(argv[2], 16) if argv[2].startswith("+") \
            else int(argv[2], 16)
    else:
        end = start + 0x400
    data = open(path, "rb").read()
    base, secs = sections(data)
    iat = imports(data, base, secs)
    syms = load_symbols(path)
    off, avail = va_to_off(base, secs, start)
    code = data[off:off + min(end - start, avail)]
    md = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_32)
    md.detail = False
    for insn in md.disasm(code, start):
        note = ""
        ops = insn.op_str
        # annotate direct call/jmp targets and [mem] operands
        for tok in ops.replace("[", " ").replace("]", " ").replace(",", " ").split():
            if tok.startswith("0x"):
                v = int(tok, 16)
                if v in syms:
                    note = "  ; " + syms[v]
                elif v in iat:
                    note = "  ; -> " + iat[v]
        print("%08x  %-7s %s%s" % (insn.address, insn.mnemonic, ops, note))
        if insn.mnemonic == "ret" and insn.address + insn.size >= end:
            break


if __name__ == "__main__":
    main(sys.argv[1:])
