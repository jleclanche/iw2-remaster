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
from .resources import ResourceFS


def load_strings(fs: ResourceFS) -> dict[str, str]:
    table: dict[str, str] = {}
    for path in fs.list("text/", ".csv"):
        text = fs.read_text(path)
        for row in csv.reader(io.StringIO(text)):
            if len(row) >= 2 and row[0].strip():
                table.setdefault(row[0].strip(), row[1].strip())
    return table


def parse_sim(fs: ResourceFS, path: str) -> dict:
    doc = parse_ini(fs.read_text(path))
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
        if isinstance(templates, dict):
            loadout = []
            for i, ref in sorted(templates.items()):
                if ref is None:
                    continue
                loadout.append({"template": ref, "attach_null": nulls.get(i) if isinstance(nulls, dict) else None})
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

    buckets: dict[str, list] = {"ships": [], "stations": [], "sims_other": [], "subsims": []}
    for path in fs.list("sims/", ".ini") + fs.list("subsims/", ".ini"):
        try:
            rec = parse_sim(fs, path)
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


if __name__ == "__main__":
    main(*sys.argv[1:])
