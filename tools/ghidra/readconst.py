"""Read constants (float/double/int) out of a PE by Ghidra virtual address.

Ghidra maps these DLLs at their preferred image base, so the _DAT_xxxxxxxx
symbols in the decompiled C are directly readable here — that is how the
hard-coded engine constants (LDS dropout factor, HUD radii, ...) come out.

Usage:  python tools/ghidra/readconst.py build/bin/iwar2.dll 0x1011945c [...]
"""

from __future__ import annotations

import struct
import sys


def sections(data: bytes):
    pe = struct.unpack_from("<I", data, 0x3C)[0]
    assert data[pe:pe + 4] == b"PE\0\0", "not a PE"
    n_sec = struct.unpack_from("<H", data, pe + 6)[0]
    opt_size = struct.unpack_from("<H", data, pe + 20)[0]
    base = struct.unpack_from("<I", data, pe + 24 + 28)[0]  # ImageBase
    sec_off = pe + 24 + opt_size
    out = []
    for i in range(n_sec):
        o = sec_off + i * 40
        va = struct.unpack_from("<I", data, o + 12)[0]
        vsz = struct.unpack_from("<I", data, o + 8)[0]
        raw = struct.unpack_from("<I", data, o + 20)[0]
        out.append((va, vsz, raw))
    return base, out


def read(data: bytes, base: int, secs, va: int, n: int = 4) -> bytes:
    rva = va - base
    for sva, vsz, raw in secs:
        if sva <= rva < sva + max(vsz, 1):
            off = raw + (rva - sva)
            return data[off:off + n]
    raise SystemExit("VA 0x%x not in any section" % va)


def main(argv):
    data = open(argv[0], "rb").read()
    base, secs = sections(data)
    for a in argv[1:]:
        va = int(a, 16)
        b = read(data, base, secs, va, 8)
        f = struct.unpack_from("<f", b)[0]
        d = struct.unpack_from("<d", b)[0]
        i = struct.unpack_from("<i", b)[0]
        print("0x%08x  float=%-14g double=%-16g int=%d  bytes=%s"
              % (va, f, d, i, b.hex(" ")))


if __name__ == "__main__":
    main(sys.argv[1:])
