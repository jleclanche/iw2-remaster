"""Parser for LightWave LWS scene files (LWSC version 1, as used by IW2).

IW2 uses LWS scenes for: avatar assemblies (``avatars/*/setup*.lws``),
hardpoint/dockport layouts (``sims/*/common_setups``), effect/sound rigs,
and star-system visual layouts (``geog/*.lws``).

Object records are 1-indexed in load order; ``ParentObject n`` refers to
that order. Null names carry IW2 semantics in angle-bracket tags:

    <detail_switch min=0.0 max=0.08>   LOD group (fraction of view size)
    <scene name="upper_engine_lod0">   instance sibling scene <name>.lws
    <node name=...> / <anim ...> / <glow ...> etc.

Motion channels per keyframe: x y z, heading pitch bank (degrees, LW
left-handed +Z-forward), sx sy sz.

Usage:  python -m tools.iw2.lws [output_dir]   # dump all scenes to JSON
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

from .resources import ResourceFS

_ATTR_RE = re.compile(r'(\w+)=("[^"]*"|\([^)]*\)|\S+)')


def _parse_tag(name: str) -> tuple[str, dict]:
    """'<scene name=\"x\">' -> ('scene', {'name': 'x'}); plain names pass through."""
    name = name.strip()
    if not (name.startswith("<") and name.endswith(">")):
        return "null", {"name": name}
    inner = name[1:-1].strip()
    kind = inner.split()[0] if inner else "null"
    attrs = {}
    for k, v in _ATTR_RE.findall(inner):
        v = v.strip('"')
        try:
            attrs[k] = float(v) if "." in v or "e" in v.lower() else int(v)
        except ValueError:
            attrs[k] = v
    return kind, attrs


def parse_lws(text: str) -> list[dict]:
    lines = [ln.rstrip() for ln in text.splitlines()]
    nodes: list[dict] = []
    cur: dict | None = None
    i = 0
    while i < len(lines):
        ln = lines[i].strip()
        if ln.startswith("LoadObject"):
            path = ln[len("LoadObject"):].strip()
            stem = path.replace("\\", "/").rsplit("/", 1)[-1]
            cur = {"index": len(nodes) + 1, "kind": "object",
                   "lwo": path, "pso_stem": re.sub(r"\.lwo$", "", stem, flags=re.I).lower()}
            nodes.append(cur)
        elif ln.startswith("AddNullObject"):
            kind, attrs = _parse_tag(ln[len("AddNullObject"):].strip())
            cur = {"index": len(nodes) + 1, "kind": kind, **attrs}
            nodes.append(cur)
        elif ln.startswith("ObjectMotion") and cur is not None:
            nchan = int(lines[i + 1].strip())
            nkeys = int(lines[i + 2].strip())
            keys = []
            for k in range(nkeys):
                vals = [float(v) for v in lines[i + 3 + 2 * k].split()]
                meta = [float(v) for v in lines[i + 4 + 2 * k].split()]
                if len(vals) >= 9:
                    keys.append({"frame": meta[0] if meta else 0.0,
                                 "pos": vals[0:3], "hpb": vals[3:6],
                                 "scale": vals[6:9]})
            if keys:
                cur["pos"] = keys[0]["pos"]
                cur["hpb"] = keys[0]["hpb"]
                cur["scale"] = keys[0]["scale"]
            cur["animated"] = nkeys > 1
            if nkeys > 1:
                cur["keys"] = keys
            i += 2 + 2 * nkeys  # skip keyframe pairs
        elif ln.startswith("ParentObject") and cur is not None:
            cur["parent"] = int(ln.split()[1])
        elif ln.startswith("PivotPoint") and cur is not None:
            cur["pivot"] = [float(v) for v in ln.split()[1:4]]
        i += 1
    return nodes


def main(out_dir: str = "data/json/scenes") -> None:
    fs = ResourceFS()
    out = Path(out_dir)
    ok, failed = 0, []
    for path in fs.list("", ".lws"):
        try:
            nodes = parse_lws(fs.read_text(path))
        except Exception as exc:
            failed.append((path, str(exc)))
            continue
        dest = out / Path(path).with_suffix(".json")
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_text(json.dumps({"source": path, "nodes": nodes}, indent=1),
                        encoding="utf-8")
        ok += 1
    print(f"parsed {ok} scenes, {len(failed)} failed")
    for p, e in failed[:10]:
        print(f"  FAIL {p}: {e}")


if __name__ == "__main__":
    main(*sys.argv[1:])
