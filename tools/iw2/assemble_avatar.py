"""Assemble a complete IW2 avatar (ship/station) into a single glTF.

Walks an avatar setup LWS scene: instantiates PSO meshes with their LWS
transforms, recurses into ``<scene name=...>`` references (sibling .lws),
keeps only the highest-detail ``<detail_switch>`` group (max=1.0), and
preserves nulls (hardpoints, effects anchors) as empty nodes with extras.

Usage:
  python -m tools.iw2.assemble_avatar avatars/tug_hull/setup_prefitted [out.gltf]
  python -m tools.iw2.assemble_avatar --all        # every avatars/**/*.lws
"""

from __future__ import annotations

import sys
from pathlib import Path, PurePosixPath

from .gltf_builder import GltfBuilder, hpb_to_quat
from .lws import parse_lws
from .pso import parse_pso
from .resources import ResourceFS


def _pose(key: dict) -> dict:
    """LWS key -> glTF-space pose for engine-side channel interpolation."""
    return {
        "pos": [key["pos"][0], key["pos"][1], -key["pos"][2]],
        "quat": hpb_to_quat(*key["hpb"]),
        "scale": [s if abs(s) > 1e-4 else 1e-4 for s in key["scale"]],
    }


class Assembler:
    def __init__(self, fs: ResourceFS, textures_root: Path, out_path: Path):
        self.fs = fs
        self.textures_root = textures_root
        self.out_path = out_path
        self.b = GltfBuilder()
        self._tex_cache: dict[str, str | None] = {}
        self.missing_psos: list[str] = []

    def texture_uri(self, scene_dir: str, name: str | None) -> str | None:
        if not name:
            return None
        stem = PurePosixPath(name.replace("\\", "/")).stem.lower()
        key = f"{scene_dir}|{stem}"
        if key not in self._tex_cache:
            uri = None
            local = self.textures_root / scene_dir / f"{stem}.png"
            if local.is_file():
                uri = local
            else:
                hits = list(self.textures_root.rglob(f"{stem}.png"))
                uri = hits[0] if hits else None
            if uri is not None:
                import os
                uri = Path(os.path.relpath(uri, self.out_path.parent)).as_posix()
            self._tex_cache[key] = uri
        return self._tex_cache[key]

    def add_scene(self, scene_path: str, parent: int | None) -> None:
        scene_dir = str(PurePosixPath(scene_path).parent)
        nodes = parse_lws(self.fs.read_text(scene_path))

        # keep highest-detail LOD group; drop nodes parented under other groups
        lod_groups = {n["index"]: n for n in nodes if n["kind"] == "detail_switch"}
        best = None
        if lod_groups:
            best = max(lod_groups.values(), key=lambda n: n.get("max", 0))["index"]

        def dropped(n) -> bool:
            seen = set()
            while True:
                p = n.get("parent")
                if p is None or p in seen or not (1 <= p <= len(nodes)):
                    return False
                if p in lod_groups:
                    return p != best
                seen.add(p)
                n = nodes[p - 1]

        gltf_ids: dict[int, int] = {}
        for n in nodes:
            if n["index"] in lod_groups and n["index"] != best:
                continue
            if dropped(n):
                continue
            p = n.get("parent")
            gparent = gltf_ids.get(p, parent) if p else parent
            name = n.get("name") or n.get("lwo", n["kind"])
            mesh = None
            if n["kind"] == "object":
                pso_path = f"{scene_dir}/{n['pso_stem']}.pso"
                if not self.fs.exists(pso_path):
                    # some scenes reference psos living in another avatar dir
                    hits = self.fs.list("avatars/", f"/{n['pso_stem']}.pso")
                    if hits:
                        pso_path = hits[0]
                if self.fs.exists(pso_path):
                    pso = parse_pso(self.fs.read_bytes(pso_path))
                    mesh = self.b.mesh_from_pso(
                        pso_path, pso,
                        lambda s: self.texture_uri(scene_dir, s.texture))
                else:
                    self.missing_psos.append(pso_path)
            extras = None
            if n["kind"] not in ("object", "null"):
                extras = {"iw2_kind": n["kind"]}
                for attr in ("channel", "class", "template", "tint", "splay",
                             "name", "color", "intensity", "light_type",
                             "lens_flare"):
                    if attr in n:
                        extras["iw2_" + attr] = n[attr]
                # <anim channel=X> nulls are POSE INTERPOLATORS driven by a
                # named ship-state channel (0..1), not time animations: export
                # both end poses for the engine's channel rig
                if n["kind"] == "anim" and n.get("keys"):
                    extras["iw2_pose0"] = _pose(n["keys"][0])
                    extras["iw2_pose1"] = _pose(n["keys"][-1])
            # detail_switch transforms are authoring-time offsets (LOD variants
            # laid out side by side); the engine treats them as identity
            if n["kind"] == "detail_switch":
                nid = self.b.node(str(name), gparent, mesh, None, None, None, extras)
            else:
                nid = self.b.node(str(name), gparent, mesh,
                                  n.get("pos"), n.get("hpb"), n.get("scale"), extras)
            # LW pivot: geometry rotates about pivot -> offset children/mesh
            pivot = n.get("pivot")
            if pivot and any(pivot) and mesh is not None:
                self.b.doc["nodes"][nid].pop("mesh")
                self.b.node(f"{name}_pivot", nid, mesh,
                            [-pivot[0], -pivot[1], -pivot[2]])
            gltf_ids[n["index"]] = nid
            if n.get("keys") and n["kind"] != "anim":
                self.b.add_animation_channels(nid, n["keys"])

            if n["kind"] == "scene":
                ref = f"{scene_dir}/{n.get('name','')}.lws"
                if self.fs.exists(ref):
                    self.add_scene(ref, nid)


def assemble(fs: ResourceFS, scene: str, out_path: Path,
             textures_root: Path = Path("data/textures")) -> list[str]:
    a = Assembler(fs, textures_root, out_path)
    a.add_scene(scene if scene.endswith(".lws") else scene + ".lws", None)
    a.b.save(out_path)
    return a.missing_psos


def main() -> None:
    fs = ResourceFS()
    args = [a for a in sys.argv[1:]]
    if args and args[0] == "--all":
        count = 0
        for scene in fs.list("avatars/", ".lws"):
            out = Path("data/avatars") / Path(scene).with_suffix(".gltf")
            try:
                missing = assemble(fs, scene, out)
                count += 1
                if missing:
                    print(f"{scene}: missing {sorted(set(missing))}")
            except Exception as exc:
                print(f"FAIL {scene}: {exc}")
        print(f"assembled {count} avatar setups")
    else:
        scene = args[0] if args else "avatars/tug_hull/setup_prefitted"
        out = Path(args[1]) if len(args) > 1 else \
            Path("data/avatars") / Path(scene).with_suffix(".gltf")
        missing = assemble(fs, scene, out)
        print(f"wrote {out}" + (f", missing psos: {missing}" if missing else ""))


if __name__ == "__main__":
    main()
