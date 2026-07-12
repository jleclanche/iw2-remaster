"""Decoder for IW2 ``geog/*.map`` star-system files.

Format (reverse-engineered, packed; record count is BIG-endian, fields little):

    header: u32be record_count + 1 byte (version? always 0)
    records: record_count * 360 bytes
        +0    name, NUL-terminated (rest of the 263-byte region is dirty
              buffer garbage reused between writes — ignore after first NUL)
        +263  f64[3]  position x, y, z in meters (system-centric)
        +287  f32     scale (usually 1.0)
        +291  12 bytes, zeros in all observed records
        +303  u32     parent record index (orbital/grouping hierarchy)
        +307  u8[4]   unknown (faction/flags?)
        +311  f32     body radius in meters (self for planets/stars; for
                      satellites, the radius of the body they orbit — used
                      by the map screen to place icons outside the disc).
                      Kept hex-encoded as "type_hash" for compatibility;
                      classify_map.py decodes it into a "radius" field.
        +315  u8[4]   unknown
        +319  f32[9]  three RGB colors, 0-255 (map display)
        +355  u32     unknown (0x000000FF observed)
        +359  u8      object kind (1=body/station, 5=system root, ...)
    tail: capsule-jump table — which Lagrange-point records jump where:
        u16 zero, u32le 17, u32le 17, u32le n_entries, then n_entries of
        { u32le ref (record index | 0x8000), u8 len,
          char[len] destinations (NUL-incl ";"-separated system names;
          " " = no outbound jumps, "0" = placeholder) }
        separated by 3 zero bytes (no separator after the last).

    Some maps (microsystem.map) are IFF ``FORM`` files instead — skipped.

Usage:  python -m tools.iw2.map_decoder [output_dir]
"""

from __future__ import annotations

import json
import struct
import sys
from pathlib import Path

from .resources import ResourceFS

RECORD_SIZE = 360
FIELDS = 263  # offset where the field block starts


def decode_record(buf: bytes) -> dict:
    name = buf.split(b"\x00", 1)[0].decode("latin-1")
    x, y, z = struct.unpack_from("<3d", buf, FIELDS)
    (scale,) = struct.unpack_from("<f", buf, 287)
    (parent,) = struct.unpack_from("<I", buf, 303)
    unknown1 = buf[307:311].hex()
    (type_hash,) = struct.unpack_from("<I", buf, 311)
    unknown2 = buf[315:319].hex()
    colors = struct.unpack_from("<9f", buf, 319)
    (unknown3,) = struct.unpack_from("<I", buf, 355)
    kind = buf[359]
    return {
        "name": name,
        "pos": [x, y, z],
        "scale": scale,
        "parent": parent,
        "type_hash": f"{type_hash:08x}",
        "kind": kind,
        "colors": [list(colors[0:3]), list(colors[3:6]), list(colors[6:9])],
        "unknown1": unknown1,
        "unknown2": unknown2,
        "unknown3": unknown3,
    }


def decode_links(tail: bytes) -> list[dict]:
    links = []
    if len(tail) < 14:
        return links
    n = struct.unpack_from("<I", tail, 10)[0]
    off = 14
    for _ in range(n):
        if off + 5 > len(tail):
            break
        (ref,) = struct.unpack_from("<I", tail, off)
        length = tail[off + 4]
        raw = tail[off + 5: off + 5 + length].split(b"\x00")[0].decode("latin-1")
        off += 5 + length + 3  # 3 zero bytes between entries
        dests = [d for d in raw.split(";") if d.strip() and d.strip() != "0"]
        links.append({"record": ref & 0x7FFF, "destinations": dests})
    return links


def decode_map(data: bytes) -> dict:
    if data[:4] == b"FORM":
        raise ValueError("IFF FORM file, not a map")
    (count,) = struct.unpack_from(">I", data, 0)
    records = []
    for i in range(count):
        start = 5 + i * RECORD_SIZE
        records.append({"index": i, **decode_record(data[start: start + RECORD_SIZE])})
    tail = data[5 + count * RECORD_SIZE:]
    return {"objects": records, "links": decode_links(tail), "tail_raw": tail.hex()}


def main(out_dir: str = "data/json/systems") -> None:
    fs = ResourceFS()
    out = Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)
    index = {}
    for path in fs.list("geog/", ".map"):
        data = fs.read_bytes(path)
        try:
            system = decode_map(data)
        except Exception as exc:
            print(f"WARN {path}: {exc}")
            continue
        system["source"] = path
        stem = Path(path).stem.lower()
        (out / f"{stem}.json").write_text(json.dumps(system, indent=1), encoding="utf-8")
        index[stem] = {
            "source": path,
            "objects": len(system["objects"]),
            "links": [d for l in system["links"] for d in l["destinations"]],
        }
        print(f"{stem}: {len(system['objects'])} objects, {len(system['links'])} links")
    (out / "_index.json").write_text(json.dumps(index, indent=1), encoding="utf-8")


if __name__ == "__main__":
    main(*sys.argv[1:])
