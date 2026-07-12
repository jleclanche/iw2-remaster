"""Dump the PE export table of a DLL.

The IW2 POG packages are one DLL per namespace (iship.dll, iai.dll, ...);
their exports are the handles onto the native bindings the scripts call.

Usage:  python tools/ghidra/pe_exports.py <dll> [...]
"""

from __future__ import annotations

import struct
import sys


def _sections(data: bytes):
    pe = struct.unpack_from("<I", data, 0x3C)[0]
    assert data[pe:pe + 4] == b"PE\0\0", "not a PE"
    n_sec = struct.unpack_from("<H", data, pe + 6)[0]
    opt_size = struct.unpack_from("<H", data, pe + 20)[0]
    opt = pe + 24
    # DataDirectory[0] = export table
    magic = struct.unpack_from("<H", data, opt)[0]
    dd = opt + (96 if magic == 0x10B else 112)
    exp_rva, _exp_sz = struct.unpack_from("<II", data, dd)
    secs = []
    sec_off = opt + opt_size
    for i in range(n_sec):
        o = sec_off + i * 40
        va = struct.unpack_from("<I", data, o + 12)[0]
        vsz = struct.unpack_from("<I", data, o + 8)[0]
        raw = struct.unpack_from("<I", data, o + 20)[0]
        secs.append((va, vsz, raw))
    return exp_rva, secs


def _off(secs, rva: int) -> int:
    for va, vsz, raw in secs:
        if va <= rva < va + max(vsz, 1):
            return raw + (rva - va)
    raise KeyError("RVA 0x%x not mapped" % rva)


def exports(path: str) -> list[str]:
    data = open(path, "rb").read()
    exp_rva, secs = _sections(data)
    if not exp_rva:
        return []
    e = _off(secs, exp_rva)
    n_names = struct.unpack_from("<I", data, e + 24)[0]
    names_rva = struct.unpack_from("<I", data, e + 32)[0]
    if not n_names:
        return []
    names = _off(secs, names_rva)
    out = []
    for i in range(n_names):
        rva = struct.unpack_from("<I", data, names + i * 4)[0]
        o = _off(secs, rva)
        end = data.index(b"\0", o)
        out.append(data[o:end].decode("ascii", "replace"))
    return out


def main(argv):
    for p in argv:
        names = exports(p)
        print("== %s : %d exports" % (p, len(names)))
        for n in names:
            print("   " + n)


if __name__ == "__main__":
    main(sys.argv[1:])
