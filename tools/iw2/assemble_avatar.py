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
from .lws import parse_scene
from .pso import parse_pso
from .resources import ResourceFS


def _pose(key: dict) -> dict:
    """LWS key -> glTF-space pose for engine-side channel interpolation."""
    return {
        "pos": [key["pos"][0], key["pos"][1], -key["pos"][2]],
        "quat": hpb_to_quat(*key["hpb"]),
        "scale": [s if abs(s) > 1e-4 else 1e-4 for s in key["scale"]],
    }


def _key_at(keys: list[dict], frame: float) -> dict:
    """A motion track's pose at `frame` (linear between keys, clamped).

    The engine plays a scene inside [FirstFrame, LastFrame]
    (FcScene::ParseFirstFrame, flux @ 0x1002c3c0, stored at +0x40), so a
    keyed node's REST pose is its track value at FirstFrame -- not the
    frame-0 value. Setup scenes exploit exactly that: the command section
    hides its cs_eng engine-glow pods by keying scale 0 at frame 0 -> 1 at
    frame 1 under FirstFrame 1, so they rest VISIBLE in the play range.
    """
    if frame <= keys[0]["frame"]:
        return keys[0]
    for a, b in zip(keys, keys[1:]):
        if frame <= b["frame"]:
            t = (frame - a["frame"]) / (b["frame"] - a["frame"])
            return {
                "frame": frame,
                "pos": [a["pos"][i] + (b["pos"][i] - a["pos"][i]) * t
                        for i in range(3)],
                "hpb": [a["hpb"][i] + (b["hpb"][i] - a["hpb"][i]) * t
                        for i in range(3)],
                "scale": [a["scale"][i] + (b["scale"][i] - a["scale"][i]) * t
                          for i in range(3)],
            }
    return keys[-1]


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

    def texture_rel(self, scene_dir: str, name) -> str | None:
        """Texture stem -> path relative to data/textures, no suffix.

        For effect-null textures (icSignAvatar) the runtime loads the PNG
        itself via ParticleFx.texture, which roots at data/textures -- the
        glTF-relative form texture_uri returns is useless to it.
        """
        if not name:
            return None
        stem = PurePosixPath(str(name).replace("\\", "/")).stem.lower()
        local = self.textures_root / scene_dir / f"{stem}.png"
        hits = [local] if local.is_file() else \
            list(self.textures_root.rglob(f"{stem}.png"))
        if not hits:
            return None
        return hits[0].relative_to(self.textures_root) \
                      .with_suffix("").as_posix()

    def add_scene(self, scene_path: str, parent: int | None) -> None:
        scene_dir = str(PurePosixPath(scene_path).parent)
        scene = parse_scene(self.fs.read_text(scene_path))
        nodes = scene["nodes"]
        first_frame = float(scene["first_frame"])

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
        forward_parents: list[tuple[int, int]] = []
        for n in nodes:
            if n["index"] in lod_groups and n["index"] != best:
                continue
            if dropped(n):
                continue
            p = n.get("parent")
            gparent = gltf_ids.get(p, parent) if p else parent
            if p and p not in gltf_ids:
                # ParentObject may FORWARD-reference an object defined later
                # in the scene (Hoffer's Gap gantries) — fix up in pass two
                forward_parents.append((n["index"], p))
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
                        lambda s: self.texture_uri(scene_dir, s.texture),
                        lambda s: self.texture_uri(scene_dir, s.texture3))
                else:
                    self.missing_psos.append(pso_path)
            extras = None
            if mesh is not None and pso_path in self.b.glow_channels:
                # <glow channel=EXPR> surfaces (issue #17): the runtime drives
                # each primitive's emission from the named channel expression
                extras = {"iw2_glow_channels": {
                    str(i): expr
                    for i, expr in self.b.glow_channels[pso_path].items()}}
            if mesh is not None and pso_path in self.b.surface_layers:
                # wrap-addressed lightmaps + envmap names (#16/#15): resolved
                # to data/textures-relative paths for the runtime material pass
                lay: dict = {}
                for i, d in self.b.surface_layers[pso_path].items():
                    ent: dict = {}
                    if d.get("lightmap"):
                        rel = self.texture_rel(scene_dir, d["lightmap"])
                        if rel:
                            ent["lightmap"] = rel
                            ent["uv2"] = bool(d.get("uv2"))
                    if d.get("envmap"):
                        ent["envmap"] = d["envmap"]
                    if d.get("glow_uv"):
                        # which UV set the emissive glow samples (2 = the
                        # TEXCOORD_2 channel Godot imports as CUSTOM0)
                        ent["glow_uv"] = d["glow_uv"]
                    if ent:
                        lay[str(i)] = ent
                if lay:
                    extras = (extras or {})
                    extras["iw2_surface_layers"] = lay
            if n["kind"] not in ("object", "null"):
                extras = {"iw2_kind": n["kind"]}
                for attr in ("channel", "class", "template", "tint", "splay",
                             "name", "color", "intensity", "light_type",
                             "lens_flare", "texture", "texture_2", "fps",
                             "repeat",
                             "flare_intensity", "flare_options", "flare_fade",
                             "flare_star_filter", "flare_nominal"):
                    if attr in n:
                        extras["iw2_" + attr] = n[attr]
                # <anim channel=X> nulls are POSE INTERPOLATORS driven by a
                # named ship-state channel (0..1), not time animations: export
                # both end poses for the engine's channel rig
                if n["kind"] == "anim" and n.get("keys"):
                    extras["iw2_pose0"] = _pose(n["keys"][0])
                    extras["iw2_pose1"] = _pose(n["keys"][-1])
                # sign textures live beside the scene's PSO textures; the
                # runtime loads them itself, so resolve to data/textures-
                # relative paths here where the search machinery lives
                if extras.get("iw2_class") == "icSignAvatar":
                    for tk in ("iw2_texture", "iw2_texture_2"):
                        rel = self.texture_rel(scene_dir, extras.get(tk))
                        if rel:
                            extras[tk + "_path"] = rel
            # detail_switch transforms are authoring-time offsets (LOD variants
            # laid out side by side, e.g. the tug's three at x -75/0/+75 once
            # the pivot folds in); the engine treats them as identity
            if n["kind"] == "detail_switch":
                nid = self.b.node(str(name), gparent, mesh, None, None, None, extras)
            else:
                # FcScene::ParsePivotPoint (flux 0x1002c340) folds -pivot into
                # the object's MOTION TRACK (FcMotionTrack::Offset): the whole
                # node -- children included -- shifts by -pivot in parent
                # space. NOT the LightWave rule (geometry-only): the tug's
                # engine-boom nulls are children of the pivoted hull and ride
                # the shift, which is what attaches the four legs to the hull.
                pos = n.get("pos")
                hpb = n.get("hpb")
                scale = n.get("scale")
                pivot = n.get("pivot")
                if pivot and any(pivot):
                    p = pos if pos is not None else [0.0, 0.0, 0.0]
                    pos = [p[0] - pivot[0], p[1] - pivot[1], p[2] - pivot[2]]
                    if n.get("keys"):
                        for k in n["keys"]:
                            k["pos"] = [k["pos"][0] - pivot[0],
                                        k["pos"][1] - pivot[1],
                                        k["pos"][2] - pivot[2]]
                # keyed nodes rest at the FirstFrame pose (see _key_at) --
                # except <anim> nulls, whose keys are the channel-rig poses
                # and whose rest IS pose0 (channel value 0)
                if n.get("keys") and n["kind"] != "anim":
                    k = _key_at(n["keys"], first_frame)
                    pos, hpb, scale = k["pos"], k["hpb"], k["scale"]
                nid = self.b.node(str(name), gparent, mesh,
                                  pos, hpb, scale, extras)
            gltf_ids[n["index"]] = nid
            if n.get("keys") and n["kind"] != "anim":
                self.b.add_animation_channels(nid, n["keys"])
            if n["kind"] == "scene":
                ref = f"{scene_dir}/{n.get('name','')}.lws"
                if self.fs.exists(ref):
                    self.add_scene(ref, nid)
        # pass two: resolve forward ParentObject references
        for idx, p in forward_parents:
            if idx in gltf_ids and p in gltf_ids:
                self._reparent(gltf_ids[idx], gltf_ids[p])

    def _reparent(self, nid: int, new_parent: int) -> None:
        doc = self.b.doc
        roots = doc["scenes"][0]["nodes"]
        if nid in roots:
            roots.remove(nid)
        else:
            for m in doc["nodes"]:
                ch = m.get("children")
                if ch and nid in ch:
                    ch.remove(nid)
                    break
        doc["nodes"][new_parent].setdefault("children", []).append(nid)


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
