"""Turn decoded ``.map`` records into renderable objects.

Nothing here is guessed from names any more.  Every field below is the one the
engine itself reads (see ``map_decoder`` for the record layout and the source
addresses):

* the record's **kind byte** is the category (``icSolarSystem::Load``'s switch);
* a station's **scene index** (+0x134) indexes ``station_creation.ini``
  ``[Stations] Scene[n]``, whose sim INI names the avatar
  (``icStation::Scene`` -> ``FcINIFile::NumberedString``);
* a body's **radius** is the f32 at +0x138 (``FiSim::SetRadius``), its rocky /
  gassy type is +0x13c, and its surface / cloud textures are indices into
  ``planets.ini``;
* a sun's **class** (+0x134) picks the surface texture and the colour range
  (``icSunAvatar`` ctor @ 0x100d2910, ``icSun::PickColour`` @ 0x1006ac70).

Adds to every record in ``data/json/systems/*.json``:
    category   system | star | lpoint | body | station | belt | gunstar | nebula
    renders    bool -- whether the engine actually gives the record an avatar
    avatar     for stations: gltf path relative to data/avatars/
    plus per-category render fields (see ``classify_system``).

Usage:  python -m tools.iw2.classify_map
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

INI_DIR = Path("data/ini")
AVATAR_DIR = Path("data/avatars")

# planets.ini [Planets] -- the renderer's own config
PLANETS_INI = INI_DIR / "planets.ini"

# icSun::PickColour (0x1006ac70) LERPs between the two colours of the class's
# entry in icSun::m_colours[32] with a rand() weight.  The table is written by
# a runtime static-init (iwar2.dll FUN_10069f70 @ 0x10069f70), so it reads as
# zeros in the file and has to be taken from that function's constants.
SUN_COLOURS = [
    [[0.05, 0.05, 1.00], [0.40, 0.50, 1.00]],   # 0
    [[0.30, 0.35, 1.00], [0.70, 0.80, 1.00]],   # 1
    [[0.40, 0.60, 1.00], [1.00, 1.00, 1.00]],   # 2
    [[1.00, 1.00, 1.00], [1.00, 1.00, 0.15]],   # 3
    [[1.00, 1.00, 0.90], [1.00, 0.80, 0.05]],   # 4
    [[1.00, 0.90, 0.90], [0.90, 0.80, 0.05]],   # 5
    [[1.00, 0.90, 0.80], [0.85, 0.90, 0.15]],   # 6
    [[1.00, 0.90, 0.40], [1.00, 0.40, 0.15]],   # 7
    [[1.00, 0.70, 0.30], [1.00, 0.30, 0.05]],   # 8
    [[1.00, 0.50, 0.20], [1.00, 0.10, 0.05]],   # 9
    [[1.00, 0.30, 0.05], [1.00, 0.05, 0.05]],   # 10
    [[1.00, 0.30, 0.05], [1.00, 0.05, 0.05]],   # 11
    [[1.00, 0.30, 0.05], [0.90, 0.05, 0.05]],   # 12
    [[0.80, 0.15, 0.05], [0.80, 0.05, 0.05]],   # 13
    [[0.60, 0.05, 0.05], [0.70, 0.05, 0.05]],   # 14
    [[0.50, 0.05, 0.05], [0.60, 0.05, 0.05]],   # 15
]


def sun_texture(cls: int) -> str:
    """icSunAvatar ctor, 0x100d2910: three-way branch on icSun::eClass."""
    if cls < 3:
        return "sun_blue"
    if cls < 7:
        return "sun_yellow"
    return "sun_red"


def load_planet_textures() -> dict[str, list[str]]:
    """rocky / gassy / atmosphere texture tables from planets.ini, in order."""
    out: dict[str, list[str]] = {"rocky": [], "gassy": [], "atmosphere": []}
    key = {"rocky_planet_textures": "rocky",
           "gassy_planet_textures": "gassy",
           "atmosphere_planet_textures": "atmosphere"}
    for line in PLANETS_INI.read_text(encoding="utf-8").splitlines():
        m = re.match(r'\s*(\w+)\[\]\s*=\s*"texture:/images/planets/(\S+?)"', line)
        if m and m.group(1) in key:
            out[key[m.group(1)]].append(m.group(2).lower())
    return out


def load_station_avatars() -> dict[int, str]:
    """station_creation.ini Scene[n] -> the sim INI's [Avatar] gltf path.

    icStation::Scene(index) looks the index up in [Stations]; ParseLocationInfo
    then FiSim::Create()s that INI, whose [Avatar] names the LWS scene.  Our
    avatar exporter writes those as data/avatars/<lowercased lws path>.gltf.
    """
    text = (INI_DIR / "station_creation.ini").read_text(encoding="utf-8")
    out: dict[int, str] = {}
    for m in re.finditer(r"Scene\[(\d+)\]\s*=\s*ini:/(\S+)", text):
        idx, sim = int(m.group(1)), m.group(2)
        path = INI_DIR / (sim + ".ini")
        if not path.exists():
            continue
        av = re.search(r"\[Avatar\]\s*\r?\n\s*name\s*=\s*lws:/(\S+)",
                       path.read_text(encoding="utf-8", errors="replace"))
        if not av:
            continue
        gltf = av.group(1).lower() + ".gltf"
        if (AVATAR_DIR / gltf).exists():
            out[idx] = gltf
    return out


def classify_system(sys_: dict, textures: dict[str, list[str]],
                    stations: dict[int, str]) -> None:
    linked = {l["record"]: l["destinations"] for l in sys_["links"]}

    for o in sys_["objects"]:
        kind = o["kind"]
        o["renders"] = False

        if kind == 0:
            # icPlanet.  CreateAvatar (0x10067fe0) only builds an avatar when
            # 1 < IeBodyType < 5, which is also why the system centre (record 0,
            # body type 0, radius 0) is invisible.
            bt = o["body_type"]
            o["category"] = "system" if o["index"] == 0 else "body"
            o["renders"] = 1 < bt < 5 and o["radius"] > 0.0
            ptype = o["planet_type"]
            o["surface_class"] = {1: "rocky", 2: "gassy"}.get(ptype, "none")
            table = textures.get(o["surface_class"], [])
            o["surface_textures"] = [table[i] for i in o["surface"]
                                     if i < len(table)]
            # icPlanet::Load: rings and clouds are mutually exclusive -- a
            # ringed body (or IeBodyType 4) gets no atmosphere layer.
            has_atmo = (o["rings"] == 0 and bt != 4 and o["atmosphere"] >= 0
                        and o["atmosphere"] < len(textures["atmosphere"]))
            o["atmosphere_texture"] = (textures["atmosphere"][o["atmosphere"]]
                                       if has_atmo else "")
            # rings are only drawn for IeBodyType 4 (icPlanetAvatar, 0x100cdc50)
            o["ring_count"] = o["rings"] if bt == 4 else 0

        elif kind == 5:
            o["category"] = "star"
            o["renders"] = True
            cls = min(o["sun_class"], len(SUN_COLOURS) - 1)
            o["sun_class"] = cls
            o["sun_texture"] = sun_texture(cls)
            o["sun_colours"] = SUN_COLOURS[cls]

        elif kind == 1:
            o["category"] = "station"
            # a station's +0x138 is its parent body's radius left over in the
            # write buffer; icStation never reads it (its extent comes from the
            # avatar's collision hull).  Do not let that garbage escape.
            o["radius"] = 0.0
            avatar = stations.get(o["scene"])
            if avatar:
                o["avatar"] = avatar
                o["renders"] = True

        elif kind == 2:
            o["category"] = "lpoint"
            # icSolarSystem::Load hard-codes FiSim::SetRadius(500) for L-points;
            # the +0x138 field is left over from the previous record.
            o["radius"] = 500.0

        elif kind == 4:
            o["category"] = "belt"
            o["radius"] = o["info_f"]  # ParseAsteroidBeltInfo reads +0x134

        elif kind == 6:
            # icSolarSystem::Load skips AddSim for kind 6 -- gunstar records are
            # inert markers; the real gunstars are spawned by POG.
            o["category"] = "gunstar"
            o["radius"] = 0.0

        elif kind == 7:
            o["category"] = "nebula"
            o["radius"] = 0.0

        else:
            o["category"] = "body"

        if o["index"] in linked:
            o["jumps_to"] = linked[o["index"]]


def norm_system(name: str) -> str:
    """Normalize a system display/destination name for matching."""
    n = name.lower().replace("_", " ").replace("'", "").strip()
    for suffix in (" system centre", " system"):
        n = n.removesuffix(suffix)
    return n


def main(sys_dir: str = "data/json/systems") -> None:
    textures = load_planet_textures()
    stations = load_station_avatars()
    counts: dict[str, int] = {}
    systems: dict[str, dict] = {}
    name2stem: dict[str, str] = {}
    for path in sorted(Path(sys_dir).glob("*.json")):
        if path.name == "_index.json":
            continue
        sys_ = json.loads(path.read_text(encoding="utf-8"))
        classify_system(sys_, textures, stations)
        systems[str(path)] = sys_
        name2stem[norm_system(sys_["objects"][0]["name"])] = path.stem

    unresolved = 0
    no_avatar = 0
    for path, sys_ in systems.items():
        for o in sys_["objects"]:
            if "jumps_to" in o:
                stems = [name2stem.get(norm_system(d)) for d in o["jumps_to"]]
                o["jumps_to_stems"] = [s for s in stems if s]
                unresolved += sum(1 for s in stems if s is None)
            if o["category"] == "station" and not o.get("avatar"):
                no_avatar += 1
        Path(path).write_text(json.dumps(sys_, indent=1), encoding="utf-8")
        for o in sys_["objects"]:
            counts[o["category"]] = counts.get(o["category"], 0) + 1
    print("classified:", counts)
    print("unresolved jump destinations:", unresolved,
          "| stations with no scene avatar:", no_avatar)


if __name__ == "__main__":
    main(*sys.argv[1:])
