"""Parser for LightWave LWOB objects (LWO v1, as used by IW2).

Covers collision hulls (``collisionhulls/*.lwo``) and the remaining loose
meshes. IFF big-endian chunks:

    PNTS: f32be x,y,z per point
    SRFS: NUL-separated surface names (1-indexed by POLS)
    POLS: per polygon: u16be nverts, nverts*u16be indices, s16be surface
    SURF: surface attributes (ignored here)

Usage:  python -m tools.iw2.lwo            # export all to data/gltf + hulls json
"""

from __future__ import annotations

import json
import struct
import sys
from pathlib import Path


def parse_lwob(data: bytes) -> dict:
    if data[:4] != b"FORM" or data[8:12] != b"LWOB":
        raise ValueError("not an LWOB file")
    points: list[tuple] = []
    polys: list[tuple] = []  # (indices..., surface)
    surfaces: list[str] = []
    off = 12
    while off + 8 <= len(data):
        tag = data[off:off + 4]
        (size,) = struct.unpack_from(">I", data, off + 4)
        body = data[off + 8: off + 8 + size]
        off += 8 + size + (size & 1)
        if tag == b"PNTS":
            for i in range(0, size - 11, 12):
                points.append(struct.unpack_from(">3f", body, i))
        elif tag == b"SRFS":
            surfaces = [s.decode("latin-1") for s in body.split(b"\x00") if s]
        elif tag == b"POLS":
            p = 0
            while p + 2 <= size:
                (n,) = struct.unpack_from(">H", body, p)
                p += 2
                idx = struct.unpack_from(f">{n}H", body, p)
                p += 2 * n
                (surf,) = struct.unpack_from(">h", body, p)
                p += 2
                if surf < 0:  # detail polygons follow; count then skip marker
                    surf = -surf
                polys.append((list(idx), surf))
    return {"points": points, "polys": polys, "surfaces": surfaces}


def triangulate(polys: list) -> list[tuple[int, int, int]]:
    tris = []
    for idx, _surf in polys:
        for i in range(1, len(idx) - 1):  # fan
            tris.append((idx[0], idx[i], idx[i + 1]))
    return tris


def main() -> None:
    from .resources import ResourceFS
    fs = ResourceFS()
    out_hulls = Path("data/json/collisionhulls")
    out_hulls.mkdir(parents=True, exist_ok=True)
    ok, failed = 0, []
    for path in fs.list("", ".lwo"):
        try:
            mesh = parse_lwob(fs.read_bytes(path))
        except Exception as exc:
            failed.append((path, str(exc)))
            continue
        ok += 1
        if path.startswith("collisionhulls/"):
            # z-flip to match the glTF/engine frame
            pts = [[x, y, -z] for x, y, z in mesh["points"]]
            rec = {"source": path, "points": pts,
                   "triangles": triangulate(mesh["polys"])}
            dest = out_hulls / (Path(path).stem + ".json")
            dest.write_text(json.dumps(rec), encoding="utf-8")
    print(f"parsed {ok} lwo files ({len(failed)} failed), hulls -> {out_hulls}")
    for p, e in failed[:8]:
        print(f"  FAIL {p}: {e}")


if __name__ == "__main__":
    main()
