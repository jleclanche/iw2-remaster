"""Decoder for IW2 ``geog/*.map`` star-system files.

The layout below is not reverse-engineered by inspection: it is read straight
out of ``icSolarSystem::Load`` (``iwar2.dll @ 0x1004bb60``), which walks the
file as ``count * sizeof(sEntity)`` with ``sizeof(sEntity) == 0x168`` (360) and
dispatches on the record's first byte.  The per-kind field meanings come from
the ``Parse*Info`` / ``*::Load`` functions it calls.

    header:  u32 BIG-endian record count.  There is no version byte -- the
             byte at offset 4 is the first record's ``kind``, and it is 0
             (the system centre is a body), which is what made it look like
             padding.
    records: count * 360 bytes, starting at offset 4:

    +0x000  u8       kind (see KIND below); the switch in icSolarSystem::Load
    +0x001  char[263] name, NUL-terminated (the rest of the region is dirty
            buffer garbage reused between writes -- ignore after the NUL)
    +0x108  f64[3]   position x, y, z in meters, system-centric
                     (FiSim::SetPosition)
    +0x120  f32[4]   orientation quaternion, stored (w, x, y, z)
                     (FiSim::SetOrientation).  Bodies/stations are all
                     identity (1,0,0,0); L-points carry a real yaw.
    +0x130  u16      parent record index (orbital/grouping hierarchy)
    +0x134  u32      kind-dependent "info" word:
                       kind 0 body    -> u8  IeBodyType   (icPlanet::Load)
                       kind 5 sun     -> u8  icSun::eClass(ParseSunInfo)
                       kind 1 station -> u8  scene index into
                                         station_creation.ini [Stations]
                                         (ParseLocationInfo -> icStation::Scene)
                       kind 4 belt    -> f32 belt radius (ParseAsteroidBeltInfo)
                       kind 2 lpoint  -> u32 link word (icSolarSystem::Load
                                         stores it at icLagrangePointWaypoint
                                         +0x20c; icCluster::ConnectLagrangePoints)
    +0x135  u8       station: sub-type index      (icStation::Load)
    +0x136  u8       station: faction allegiance  (icStation::Load ->
                     icFactions::FindFactionByAllegiance)
    +0x137  u8       station: unknown (quantised 5/10/15/... -- see docs)
    +0x138  f32      BODY RADIUS in meters -- FiSim::SetRadius, for kind 0 and
                     kind 5.  (kind 4 puts a u32 here instead.)
    +0x13c  u8       body: icPlanet::eType   1 = rocky, 2 = gassy
    +0x13d  u8       body: SurfaceType(0) -- index into planets.ini
                     rocky_planet_textures[] / gassy_planet_textures[]
    +0x13e  u8       body: SurfaceType(1) -- second surface layer
    +0x13f  u8       spare (0xbf in every shipped record)
    +0x140  f32[9]   three RGB colours, 0-255.  icPlanet::ReadColour scales by
                     1/255 (_DAT_1011b068 = 0.00392157).  [0] = SurfaceTint(0),
                     [1] = SurfaceTint(1), [2] = a third tint (icPlanet+0x204).
    +0x164  i8       body: atmosphere texture index into
                     atmosphere_planet_textures[]; -1 (0xff) = no atmosphere
    +0x165  u8       body: number of rings (0, or 4..8; planets.ini max_rings=8)
    +0x166  u8[2]    padding

    Fields a given kind does not write are left over from the previous record
    (the writer reused one buffer), so a station's +0x138 is its parent body's
    radius.  Only read a field for the kinds that own it.

    tail: capsule-jump table -- which Lagrange-point records jump where:
        u8 pad, u16 zero, u32le 17, u32le 17, u32le n_entries, then n_entries of
        { u32le ref (record index | 0x8000), u8 len,
          char[len] destinations (NUL-incl ";"-separated system names;
          " " = no outbound jumps, "0" = placeholder) }
        separated by 3 zero bytes (no separator after the last).

    Some maps (microsystem.map) are IFF ``FORM`` files instead -- skipped.

Usage:  python -m tools.iw2.map_decoder [output_dir]
"""

from __future__ import annotations

import json
import struct
import sys
from pathlib import Path

from .resources import ResourceFS

RECORD_SIZE = 360
HEADER_SIZE = 4

# icSolarSystem::Load's switch on the record's first byte
KIND = {
    0: "body",       # icPlanet          -> ParseBodyInfo
    1: "location",   # icStation         -> ParseLocationInfo
    2: "lpoint",     # icLagrangePointWaypoint
    4: "belt",       # icAsteroidBelt    -> ParseAsteroidBeltInfo
    5: "sun",        # icSun             -> ParseSunInfo
    6: "gunstar",    # ParseGunstarInfo is empty AND Load never adds the sim
    7: "nebula",     # icNebula          -> ParseNebulaInfo
}


def decode_record(buf: bytes) -> dict:
    kind = buf[0]
    name = buf[1:264].split(b"\x00", 1)[0].decode("latin-1")
    x, y, z = struct.unpack_from("<3d", buf, 0x108)
    qw, qx, qy, qz = struct.unpack_from("<4f", buf, 0x120)
    (parent,) = struct.unpack_from("<H", buf, 0x130)
    (info,) = struct.unpack_from("<I", buf, 0x134)
    (info_f,) = struct.unpack_from("<f", buf, 0x134)
    (radius,) = struct.unpack_from("<f", buf, 0x138)
    colors = struct.unpack_from("<9f", buf, 0x140)
    return {
        "name": name,
        "kind": kind,
        "kind_name": KIND.get(kind, "?"),
        "pos": [x, y, z],
        "orientation": [qw, qx, qy, qz],
        "parent": parent,
        "info": info,
        "info_f": info_f,
        "radius": radius,
        "body_type": buf[0x134],
        "sun_class": buf[0x134],
        "scene": buf[0x134],
        "station_subtype": buf[0x135],
        "faction_id": buf[0x136],
        "station_unknown": buf[0x137],
        "planet_type": buf[0x13C],
        "surface": [buf[0x13D], buf[0x13E]],
        "colors": [list(colors[0:3]), list(colors[3:6]), list(colors[6:9])],
        "atmosphere": buf[0x164] - 256 if buf[0x164] > 127 else buf[0x164],
        "rings": buf[0x165],
    }


def decode_links(tail: bytes) -> list[dict]:
    links = []
    if len(tail) < 15:
        return links
    n = struct.unpack_from("<I", tail, 11)[0]
    off = 15
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
        start = HEADER_SIZE + i * RECORD_SIZE
        records.append({"index": i, **decode_record(data[start: start + RECORD_SIZE])})
    tail = data[HEADER_SIZE + count * RECORD_SIZE:]
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
