"""Extract ships, stations, and subsims from an IW2 install into JSON.

Usage:  python -m tools.iw2.extract_sims [output_dir]

Produces (under output_dir, default ``data/json``):
- ships.json / stations.json / sims_other.json — one record per sim template
- subsims.json — weapons, systems, mountpoints, dockports
- strings.json — localized string table (English)
"""

from __future__ import annotations

import csv
import io
import json
import sys
from pathlib import Path

from .ini_parser import indexed_to_list, parse_ini
from .lws import parse_scene
from .resources import ResourceFS

# --- attach nulls -----------------------------------------------------------
#
# Where a subsim actually sits on its hull. FiSim::Load (flux.dll 0x100bbc00)
# loads the ini's [SetupScene] into an FcScene, and for every [Subsims]
# template[i] it reads the sibling key null[i] and calls
#
#   FiSim::PlaceSubsimAtNull(subsim, scene, name)      flux.dll 0x100bcb10
#     if (subsim && name.length())
#       if (sNull *n = FcScene::FindElement(scene, name))   flux.dll 0x1002bfb0
#         n->track.GetFrame(0.0, &pos, &quat, &scale)
#         subsim->SetPosition(pos); subsim->SetOrientation(quat)
#
# So the attach nulls are named nodes of the *setup scene* -- NOT of the
# avatar. The avatar is a separate [Avatar] lws loaded a few lines further up
# in the same function and is never searched for mount names.
#
# Three details we reproduce exactly:
#  * FindElement/FindElementRecursive (0x1002e140) is a depth-first search over
#    the scene's root list, comparing the node name for equality.
#  * GetFrame(0.0) is the node's *local* frame-0 transform. PlaceSubsimAtNull
#    never walks the parent chain, so a parented null would contribute only its
#    own offset. (In the shipped data every null a ship ini names is a scene
#    root, so this never bites -- main() asserts it.)
#  * When the name is absent/empty, or names a null the scene does not have,
#    SetPosition is never called and the subsim keeps the FcSubsim ctor's
#    defaults (flux.dll 0x100c2190: +0x20..0x28 = 0, +0x2c = 1.0f) -- i.e. the
#    hull origin with identity orientation. `attach_pos` is null in that case,
#    and consumers must keep it at the origin: that is the original's behaviour,
#    not a lookup failure.
#
# Positions/rotations are stored raw, in LightWave axes (+Z forward, degrees
# heading/pitch/bank), like everything else under data/json/scenes. The Godot
# side applies the usual LWS -> engine conversion (negate Z; see gltf_builder).


def _scene_nulls(fs: ResourceFS, ref: str, cache: dict) -> dict[str, dict]:
    """Named nulls of a `lws:/...` setup scene, keyed by name (as authored).

    Only `kind == "null"` nodes can match: LoadObject nodes are keyed by their
    .lwo path and the tagged nulls (`<scene name=...>`, `<detail_switch ...>`)
    keep their angle brackets in the name FindElement compares against, so
    neither can ever equal a plain ini name.
    """
    if ref in cache:
        return cache[ref]
    out: dict[str, dict] = {}
    path = ref.split(":/", 1)[-1] + ".lws"
    try:
        # ResourceFS is case-insensitive, as the original's resource lookup is:
        # militaryoutpost.ini asks for `lws:/sims/stations/MilitaryOutpost` and
        # gets the shipped militaryoutpost.lws.
        scene = parse_scene(fs.read_text(path))
    except Exception as exc:
        # Three sims name a [SetupScene] that is not in the shipped resources at
        # all (sims/ships/navy/comsec, sims/stations/custom/gunstar,
        # sims/multiplayer/test). FiSim::Load bails out on a scene that will not
        # load -- `if (!FcScene::Load(...)) return false` -- so these sims never
        # loaded in the original either. Their mounts stay at the origin.
        print(f"WARN setup scene {path}: {exc}")
        cache[ref] = out
        return out
    for node in scene.get("nodes", []):
        if node.get("kind") == "null" and node.get("name"):
            out.setdefault(node["name"], node)  # DFS order: first match wins
    cache[ref] = out
    return out


def load_strings(fs: ResourceFS) -> dict[str, str]:
    from .pogdata import _clean_csv  # same repairs the runtime tables get
    table: dict[str, str] = {}
    for path in fs.list("text/", ".csv"):
        text = _clean_csv(fs.read_text(path), path)
        for row in csv.reader(io.StringIO(text)):
            if len(row) >= 2 and row[0].strip() and not row[0].startswith(";"):
                table.setdefault(row[0].strip(), row[1].strip())
    return table


def parse_sim(fs: ResourceFS, path: str, scenes: dict | None = None) -> dict:
    doc = parse_ini(fs.read_text(path))
    scenes = {} if scenes is None else scenes
    rec: dict = {"path": path}
    cls = doc.get("Class", {}).get("name")
    if cls:
        rec["class"] = cls
    for section, key in (("Avatar", "avatar"), ("CollisionHull", "collision_hull"),
                         ("SetupScene", "setup_scene")):
        name = doc.get(section, {}).get("name")
        if name:
            rec[key] = name
    subsims = doc.get("Subsims")
    if subsims:
        templates = subsims.get("template")
        nulls = subsims.get("null") or {}
        # the scene FiSim::Load searches for this sim's mount names
        by_name = _scene_nulls(fs, rec["setup_scene"], scenes) \
            if rec.get("setup_scene") else {}
        if isinstance(templates, dict):
            loadout = []
            for i, ref in sorted(templates.items()):
                if ref is None:
                    continue
                name = nulls.get(i) if isinstance(nulls, dict) else None
                mount: dict = {"template": ref, "attach_null": name}
                # PlaceSubsimAtNull: no name, or a name the scene has not got,
                # leaves the subsim at the hull origin. Say so explicitly rather
                # than inventing a position.
                node = by_name.get(name) if name else None
                if node is not None:
                    mount["attach_pos"] = node["pos"]
                    mount["attach_hpb"] = node["hpb"]
                    if node.get("parent") is not None:
                        mount["attach_parented"] = True
                elif name:
                    mount["attach_missing"] = True
                loadout.append(mount)
            rec["subsims"] = loadout
    props = doc.get("Properties")
    if props:
        rec["properties"] = props
    # keep any sections we didn't explicitly model so nothing is lost
    known = {"Class", "Avatar", "CollisionHull", "SetupScene", "Subsims", "Properties"}
    extra = {k: v for k, v in doc.items() if k not in known}
    if extra:
        rec["other_sections"] = extra
    return rec


def main(out_dir: str = "data/json") -> None:
    fs = ResourceFS()
    out = Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)

    strings = load_strings(fs)

    scenes: dict = {}
    buckets: dict[str, list] = {"ships": [], "stations": [], "sims_other": [], "subsims": []}
    for path in fs.list("sims/", ".ini") + fs.list("subsims/", ".ini"):
        try:
            rec = parse_sim(fs, path, scenes)
        except Exception as exc:  # keep going; report at the end
            print(f"WARN {path}: {exc}")
            continue
        name_id = rec.get("properties", {}).get("name")
        if isinstance(name_id, str) and name_id in strings:
            rec["display_name"] = strings[name_id]
        if path.startswith("subsims/"):
            buckets["subsims"].append(rec)
        elif path.startswith("sims/ships/"):
            buckets["ships"].append(rec)
        elif path.startswith("sims/stations/"):
            buckets["stations"].append(rec)
        else:
            buckets["sims_other"].append(rec)

    for name, records in buckets.items():
        p = out / f"{name}.json"
        p.write_text(json.dumps(records, indent=1), encoding="utf-8")
        print(f"{p}: {len(records)} records")
    (out / "strings.json").write_text(
        json.dumps(strings, indent=1, ensure_ascii=False), encoding="utf-8")
    print(f"{out / 'strings.json'}: {len(strings)} strings")

    # attach-null resolution: how many mounts got a real position, how many the
    # ini deliberately leaves at the origin, and how many name a null that is
    # not in the setup scene (a genuine miss -- there should be none).
    placed = origin = missing = parented = 0
    misses: list[str] = []
    for name in ("ships", "stations", "sims_other"):
        for rec in buckets[name]:
            for m in rec.get("subsims", []):
                if m.get("attach_missing"):
                    missing += 1
                    misses.append(f"{rec['path']} -> {m['attach_null']}")
                elif "attach_pos" in m:
                    placed += 1
                    parented += bool(m.get("attach_parented"))
                else:
                    origin += 1
    print(f"attach nulls: {placed} placed, {origin} unnamed (hull origin), "
          f"{missing} named-but-absent, {parented} parented")
    for m in misses[:10]:
        print(f"  MISS {m}")


if __name__ == "__main__":
    main(*sys.argv[1:])
