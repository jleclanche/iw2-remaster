"""Classify star-map records into renderable categories.

The ``.map`` records carry no explicit object-type field usable for model
selection (the u32 at +311 turned out to be a float32: the radius in meters
of the record's own body — or, for satellites, of the body they orbit; the
original game uses it to place map icons outside the planet disc).  The
original engine spawns actual station sims from POG scripts, so for the
remaster we classify records by their descriptive names + the parent
hierarchy and assign each station a modular-station avatar.

Adds to every record in ``data/json/systems/*.json``:
    category  system | star | lpoint | body | station
    radius    float32 from the +311 field (body radius, meters)
    avatar    for stations: gltf path relative to data/avatars/

Usage:  python -m tools.iw2.classify_map
"""

from __future__ import annotations

import json
import struct
import sys
from pathlib import Path

# keyword (lowercase, first match wins) -> avatar gltf under data/avatars/
MS = "avatars/modularstations"
STATION_RULES = [
    ("hoffer's gap", "avatars/hoffersgap/setup.gltf"),
    ("haven station", "avatars/haven_station/setup.gltf"),
    ("l.o.r. platform", "avatars/lor_platform/setup.gltf"),
    ("defence star", "avatars/gunstar/setup.gltf"),
    ("defense star", "avatars/gunstar/setup.gltf"),
    ("gunstar", "avatars/gunstar/setup.gltf"),
    ("stc", "avatars/stc/setup.gltf"),
    ("prison", "avatars/prison/setup.gltf"),
    ("stockade", "avatars/prison/setup.gltf"),
    ("reactor", "avatars/reactor/setup.gltf"),
    ("police", f"{MS}/policestation.gltf"),
    ("security station", f"{MS}/securitystation.gltf"),
    ("fortress", f"{MS}/fortressstation.gltf"),
    ("naval", f"{MS}/navalbasestation.gltf"),
    ("military", f"{MS}/navalbasestation.gltf"),
    ("sentry", f"{MS}/militaryoutpost.gltf"),
    ("defense station", f"{MS}/militaryoutpost.gltf"),
    ("defence station", f"{MS}/militaryoutpost.gltf"),
    ("listening post", f"{MS}/militaryoutpost.gltf"),
    ("outpost", f"{MS}/militaryoutpost.gltf"),
    ("marauder", f"{MS}/marauderbase.gltf"),
    ("pirate", f"{MS}/piratebase.gltf"),
    ("underworld", f"{MS}/piratebase.gltf"),
    ("vice den", f"{MS}/casinostation.gltf"),
    ("casino", f"{MS}/casinostation.gltf"),
    ("entertainment", f"{MS}/casinostation.gltf"),
    ("shipyard", f"{MS}/shipyardstation.gltf"),
    ("ship yard", f"{MS}/shipyardstation.gltf"),
    ("ship park", f"{MS}/shipyardstation.gltf"),
    ("construction", f"{MS}/shipyardstation.gltf"),
    ("service yard", f"{MS}/shipyardstation.gltf"),
    ("repair", f"{MS}/shipyardstation.gltf"),
    ("mining", f"{MS}/miningstation.gltf"),
    ("minerals", f"{MS}/miningstation.gltf"),
    (" mine", f"{MS}/miningstation.gltf"),
    ("agri", f"{MS}/orbitalgarden.gltf"),
    ("garden", f"{MS}/orbitalgarden.gltf"),
    ("piggery", f"{MS}/orbitalgarden.gltf"),
    ("manufacturing", f"{MS}/manufacturingplant.gltf"),
    ("energy cell", f"{MS}/manufacturingplant.gltf"),
    ("processing", f"{MS}/processingplant.gltf"),
    ("processor", f"{MS}/processingplant.gltf"),
    ("foundary", f"{MS}/processingplant.gltf"),
    ("foundry", f"{MS}/processingplant.gltf"),
    ("refinery", f"{MS}/processingplant.gltf"),
    ("research", f"{MS}/researchstation.gltf"),
    ("laboratory", f"{MS}/researchstation.gltf"),
    (" lab", f"{MS}/researchstation.gltf"),
    ("orbital transfer", f"{MS}/transferstation.gltf"),
    ("waystation", f"{MS}/transferstation.gltf"),
    ("docking station", f"{MS}/transferstation.gltf"),
    ("supply depot", f"{MS}/transferstation.gltf"),
    ("service depot", f"{MS}/transferstation.gltf"),
    ("warehouse", f"{MS}/transferstation.gltf"),
    ("container yard", f"{MS}/transferstation.gltf"),
    ("collection station", f"{MS}/transferstation.gltf"),
    ("freight", f"{MS}/transferstation.gltf"),
    ("hauler", f"{MS}/transferstation.gltf"),
    ("haualge", f"{MS}/transferstation.gltf"),
    ("haulage", f"{MS}/transferstation.gltf"),
    ("shipping", f"{MS}/transferstation.gltf"),
    ("comms", f"{MS}/communicationsarray.gltf"),
    ("communications", f"{MS}/communicationsarray.gltf"),
    ("transmission", f"{MS}/communicationsarray.gltf"),
    ("transmittion", f"{MS}/communicationsarray.gltf"),
    ("transceiver", f"{MS}/communicationsarray.gltf"),
    ("network", f"{MS}/communicationsarray.gltf"),
    ("relay", f"{MS}/communicationsarray.gltf"),
    ("infonet", f"{MS}/communicationsarray.gltf"),
    ("hq", f"{MS}/corporatehq.gltf"),
    ("headquarters", f"{MS}/corporatehq.gltf"),
    ("administration", f"{MS}/adminstation.gltf"),
    ("admin", f"{MS}/adminstation.gltf"),
    ("government", f"{MS}/adminstation.gltf"),
    ("habitat", f"{MS}/richsettlement.gltf"),
    ("residential", f"{MS}/richsettlement.gltf"),
    ("city", f"{MS}/richsettlement.gltf"),
    ("hospital", f"{MS}/richsettlement.gltf"),
    ("medicare", f"{MS}/richsettlement.gltf"),
    ("medical", f"{MS}/richsettlement.gltf"),
    ("religious", f"{MS}/richsettlement.gltf"),
    ("squatter", f"{MS}/poorsettlement.gltf"),
    ("settlement", f"{MS}/poorsettlement.gltf"),
    ("homestead", f"{MS}/poorsettlement.gltf"),
    ("refuge", f"{MS}/poorsettlement.gltf"),
    ("camp", f"{MS}/poorsettlement.gltf"),
    ("trading", f"{MS}/casinostation.gltf"),
    ("station", f"{MS}/transferstation.gltf"),
    ("orbital", f"{MS}/richsettlement.gltf"),
    ("base", f"{MS}/militaryoutpost.gltf"),
    ("depot", f"{MS}/transferstation.gltf"),
    ("platform", f"{MS}/transferstation.gltf"),
    ("post", f"{MS}/militaryoutpost.gltf"),
    ("yard", f"{MS}/shipyardstation.gltf"),
    ("dock", f"{MS}/shipyardstation.gltf"),
    ("centre", f"{MS}/richsettlement.gltf"),
    ("center", f"{MS}/richsettlement.gltf"),
    ("complex", f"{MS}/casinostation.gltf"),
    ("facility", f"{MS}/researchstation.gltf"),
    ("array", f"{MS}/communicationsarray.gltf"),
    (" co", f"{MS}/casinostation.gltf"),
    ("'s", f"{MS}/casinostation.gltf"),  # named bars/dens: Jim Bob's, The Hole...
]


def station_avatar(name: str) -> str | None:
    low = name.lower()
    for kw, avatar in STATION_RULES:
        if kw in low:
            return avatar
    return None


def classify_system(sys_: dict) -> None:
    objects = sys_["objects"]
    children: dict[int, int] = {}
    for o in objects:
        if o["parent"] != o["index"]:
            children[o["parent"]] = children.get(o["parent"], 0) + 1
    base = objects[0]["name"].removesuffix(" System") if objects else ""
    linked = {l["record"]: l["destinations"] for l in sys_["links"]}

    for o in objects:
        o["radius"] = struct.unpack(">f", bytes.fromhex(o["type_hash"]))[0]
        name = o["name"]
        low = name.lower()
        avatar = None
        if o["index"] == 0:
            cat = "system"
        elif o["index"] == 1 or (base and name.startswith(base) and
                                 name.split()[-1] in ("Alpha", "Beta", "Gamma")):
            cat = "star"
        elif (low.rstrip().endswith(("l-point", "l point"))
                or o["index"] in linked):
            cat = "lpoint"
        else:
            avatar = station_avatar(name)
            cat = "station" if avatar else "body"
        o["category"] = cat
        if avatar:
            o["avatar"] = avatar
        if o["index"] in linked:
            o["jumps_to"] = linked[o["index"]]


def norm_system(name: str) -> str:
    """Normalize a system display/destination name for matching."""
    n = name.lower().replace("_", " ").replace("'", "").strip()
    for suffix in (" system centre", " system"):
        n = n.removesuffix(suffix)
    return n


def main(sys_dir: str = "data/json/systems") -> None:
    counts: dict[str, int] = {}
    systems: dict[str, dict] = {}
    name2stem: dict[str, str] = {}
    for path in sorted(Path(sys_dir).glob("*.json")):
        if path.name == "_index.json":
            continue
        sys_ = json.loads(path.read_text(encoding="utf-8"))
        classify_system(sys_)
        systems[str(path)] = sys_
        name2stem[norm_system(sys_["objects"][0]["name"])] = path.stem

    unresolved = 0
    for path, sys_ in systems.items():
        for o in sys_["objects"]:
            if "jumps_to" in o:
                stems = [name2stem.get(norm_system(d)) for d in o["jumps_to"]]
                o["jumps_to_stems"] = [s for s in stems if s]
                unresolved += sum(1 for s in stems if s is None)
        Path(path).write_text(json.dumps(sys_, indent=1), encoding="utf-8")
        for o in sys_["objects"]:
            counts[o["category"]] = counts.get(o["category"], 0) + 1
    print("classified:", counts, "| unresolved jump destinations:", unresolved)


if __name__ == "__main__":
    main(*sys.argv[1:])
