"""Minimal glTF 2.0 document builder shared by the export tools.

Handles the LightWave(left-handed, +Z fwd) -> glTF(right-handed, -Z fwd)
conversion: geometry Z is negated (winding flipped), node translations get
Z negated, and HPB rotations become quaternion Ry(-H)*Rx(-P)*Rz(B)
(change of basis with S=diag(1,1,-1)).
"""

from __future__ import annotations

import json
import math
import re
import struct
from pathlib import Path


def hpb_to_quat(h: float, p: float, b: float) -> list[float]:
    """LW heading/pitch/bank in degrees -> glTF quaternion [x,y,z,w]."""
    def axis_quat(ax, deg):
        r = math.radians(deg) / 2
        s = math.sin(r)
        return [ax[0] * s, ax[1] * s, ax[2] * s, math.cos(r)]

    def mul(a, q):
        ax, ay, az, aw = a
        bx, by, bz, bw = q
        return [aw * bx + ax * bw + ay * bz - az * by,
                aw * by - ax * bz + ay * bw + az * bx,
                aw * bz + ax * by - ay * bx + az * bw,
                aw * bw - ax * bx - ay * by - az * bz]

    q = axis_quat((0, 1, 0), -h)
    q = mul(q, axis_quat((1, 0, 0), -p))
    q = mul(q, axis_quat((0, 0, 1), b))
    return q


class GltfBuilder:
    def __init__(self):
        self.blob = bytearray()
        self.doc = {
            "asset": {"version": "2.0", "generator": "iw2-remaster"},
            "scene": 0, "scenes": [{"nodes": []}],
            "nodes": [], "meshes": [], "materials": [],
            "accessors": [], "bufferViews": [], "buffers": [],
            "samplers": [{"wrapS": 10497, "wrapT": 10497}],
            "images": [], "textures": [],
        }
        self._image_ids: dict[str, int] = {}
        self._mesh_ids: dict[str, int] = {}
        # mesh key -> {primitive index: channel expression} for surfaces named
        # <glow channel=EXPR> (issue #17): the layer's intensity is CHANNEL
        # DRIVEN in the engine (AddSurfaceChannel, flux.dll.c:99855), not
        # constant. The caller folds this into the instancing node's extras so
        # ship_effects can animate emission at runtime.
        self.glow_channels: dict[str, dict[int, str]] = {}

    def _view(self, raw: bytes, target: int) -> int:
        while len(self.blob) % 4:
            self.blob.append(0)
        self.doc["bufferViews"].append({"buffer": 0, "byteOffset": len(self.blob),
                                        "byteLength": len(raw), "target": target})
        self.blob.extend(raw)
        return len(self.doc["bufferViews"]) - 1

    def _accessor(self, view, comp, count, type_, mn=None, mx=None) -> int:
        acc = {"bufferView": view, "componentType": comp, "count": count, "type": type_}
        if mn is not None:
            acc["min"], acc["max"] = mn, mx
        self.doc["accessors"].append(acc)
        return len(self.doc["accessors"]) - 1

    def image(self, uri: str) -> int:
        if uri not in self._image_ids:
            self.doc["images"].append({"uri": uri})
            self.doc["textures"].append({"source": len(self.doc["images"]) - 1, "sampler": 0})
            self._image_ids[uri] = len(self.doc["textures"]) - 1
        return self._image_ids[uri]

    def material(self, surface, texture_uri: str | None,
                 texture2_uri: str | None = None) -> int:
        mat = {
            "name": surface.name,
            "pbrMetallicRoughness": {
                "baseColorFactor": [*surface.color, 1.0],
                "metallicFactor": 0.1, "roughnessFactor": 0.85,
            },
            "extras": {"coeffs": list(surface.coeffs)},
        }
        if texture_uri:
            tex = self.image(texture_uri)
            mat["pbrMetallicRoughness"]["baseColorTexture"] = {"index": tex, "texCoord": 0}
            mat["pbrMetallicRoughness"]["baseColorFactor"] = [1, 1, 1, 1]
        if texture2_uri:
            # The SHDR's second slot is a LIGHTMAP layer; on period hardware
            # it lands in a MULTIPASS SRCALPHA/ONE additive pass whenever the
            # texture stages are exhausted, so the clamp-addressed
            # white-on-black masks (stern engine lozenges, window strips)
            # read as ADDITIVE light in the original. Emitting those as
            # emissive-on-TEXCOORD_1 tinted by the surface colour reproduces
            # that; the caller passes texture2_uri only for mask-like slots
            # (distinct texture, CLAMP addressing) -- wrap-addressed slots
            # repeating the base are true modulate lightmaps, not lights.
            mat["emissiveFactor"] = \
                list(surface.color) if any(surface.color) else [1, 1, 1]
            mat["emissiveTexture"] = {
                "index": self.image(texture2_uri),
                "texCoord": 1 if surface.uvs2 else 0}
        elif surface.texture2:
            mat["extras"]["lightmap"] = surface.texture2
        if surface.envmap:
            mat["extras"]["envmap"] = surface.envmap
        if "<glow" in surface.name:
            mat["emissiveFactor"] = list(surface.color) if any(surface.color) else [1, 1, 1]
            if texture_uri:
                mat["emissiveTexture"] = {"index": self._image_ids[texture_uri], "texCoord": 0}
        self.doc["materials"].append(mat)
        return len(self.doc["materials"]) - 1

    def mesh_from_pso(self, key: str, pso, resolve_texture,
                      resolve_texture2=None) -> int | None:
        """Add a mesh (once per key); resolve_texture(surface) -> uri or None."""
        if key in self._mesh_ids:
            return self._mesh_ids[key]
        prims = []
        for s in pso.surfaces:
            nv = len(s.positions) // 3
            if nv == 0 or not s.indices:
                continue
            pos = list(s.positions)
            nrm = list(s.normals)
            pos[2::3] = [-z for z in pos[2::3]]
            nrm[2::3] = [-z for z in nrm[2::3]]
            idx = list(s.indices)
            idx[1::3], idx[2::3] = idx[2::3], idx[1::3]
            xs, ys, zs = pos[0::3], pos[1::3], pos[2::3]
            attrs = {
                "POSITION": self._accessor(
                    self._view(struct.pack(f"<{len(pos)}f", *pos), 34962), 5126, nv, "VEC3",
                    [min(xs), min(ys), min(zs)], [max(xs), max(ys), max(zs)]),
                "NORMAL": self._accessor(
                    self._view(struct.pack(f"<{len(nrm)}f", *nrm), 34962), 5126, nv, "VEC3"),
            }
            if s.uvs:
                attrs["TEXCOORD_0"] = self._accessor(
                    self._view(struct.pack(f"<{len(s.uvs)}f", *s.uvs), 34962), 5126, nv, "VEC2")
            if s.uvs2:
                attrs["TEXCOORD_1"] = self._accessor(
                    self._view(struct.pack(f"<{len(s.uvs2)}f", *s.uvs2), 34962), 5126, nv, "VEC2")
            ia = self._accessor(self._view(struct.pack(f"<{len(idx)}H", *idx), 34963),
                                5123, len(idx), "SCALAR")
            # mask-like second slot: a DISTINCT texture with CLAMP addressing
            # (low nibble 3/4 of the mode word, SetTextureMode @ 98806);
            # tiling (WRAP) lightmaps and base-repeating slots are excluded
            glow2 = (s.texture2 and s.texture2 != s.texture
                     and (getattr(s, "tex2_mode", 0) & 0xf) in (3, 4))
            uri2 = resolve_texture2(s) if resolve_texture2 and glow2 else None
            m = re.search(r"<glow\s+channel=([^>]+)>", s.name)
            if m:
                self.glow_channels.setdefault(key, {})[len(prims)] = \
                    m.group(1).strip()
            prims.append({"attributes": attrs, "indices": ia,
                          "material": self.material(s, resolve_texture(s), uri2)})
        if not prims:
            return None
        self.doc["meshes"].append({"primitives": prims, "name": key})
        self._mesh_ids[key] = len(self.doc["meshes"]) - 1
        return self._mesh_ids[key]

    def node(self, name: str, parent: int | None = None, mesh: int | None = None,
             pos=None, hpb=None, scale=None, extras=None) -> int:
        n: dict = {"name": name}
        if mesh is not None:
            n["mesh"] = mesh
        if pos is not None:
            n["translation"] = [pos[0], pos[1], -pos[2]]
        if hpb is not None and any(hpb):
            n["rotation"] = hpb_to_quat(*hpb)
        if scale is not None and scale != [1.0, 1.0, 1.0]:
            # LW hides objects by zero scale; a degenerate basis breaks
            # Godot's quaternion math, so clamp to invisibly small instead
            n["scale"] = [s if abs(s) > 1e-4 else 1e-4 for s in scale]
        if extras:
            n["extras"] = extras
        self.doc["nodes"].append(n)
        idx = len(self.doc["nodes"]) - 1
        if parent is None:
            self.doc["scenes"][0]["nodes"].append(idx)
        else:
            self.doc["nodes"][parent].setdefault("children", []).append(idx)
        return idx

    @staticmethod
    def _subdivide_keys(keys: list[dict]) -> list[dict]:
        """Insert intermediate keys where rotation steps exceed 90 degrees.

        LWS spinners are authored as euler sweeps (0 -> 360 -> ...); naive
        per-key quaternion conversion + LERP collapses or reverses them.
        """
        out = [keys[0]]
        for a, b in zip(keys, keys[1:]):
            max_step = max(abs(b["hpb"][i] - a["hpb"][i]) for i in range(3))
            n = max(1, int(max_step // 90) + (1 if max_step % 90 else 0))
            for j in range(1, n + 1):
                t = j / n
                out.append({
                    "frame": a["frame"] + (b["frame"] - a["frame"]) * t,
                    "pos": [a["pos"][i] + (b["pos"][i] - a["pos"][i]) * t for i in range(3)],
                    "hpb": [a["hpb"][i] + (b["hpb"][i] - a["hpb"][i]) * t for i in range(3)],
                    "scale": [a["scale"][i] + (b["scale"][i] - a["scale"][i]) * t
                              for i in range(3)],
                })
        return out

    @staticmethod
    def _is_cyclic(keys: list[dict]) -> bool:
        """True when the track loops cleanly: last key == first key (position,
        scale, and rotation modulo full turns). Non-cyclic tracks are one-shot
        articulation poses (docking clamps, tug legs) that must NOT be looped —
        looping them plays the move then teleports back every cycle."""
        a, b = keys[0], keys[-1]
        if any(abs(a["pos"][i] - b["pos"][i]) > 1e-4 for i in range(3)):
            return False
        if any(abs(a["scale"][i] - b["scale"][i]) > 1e-4 for i in range(3)):
            return False
        return all(abs(a["hpb"][i] - b["hpb"][i]) % 360.0 < 1e-3
                   or 360.0 - abs(a["hpb"][i] - b["hpb"][i]) % 360.0 < 1e-3
                   for i in range(3))

    def add_animation_channels(self, node_idx: int, keys: list[dict],
                               fps: float = 25.0) -> None:
        """Add translation/rotation/scale channels for LWS keyframes.

        Only cyclic tracks are exported (the engine autoplays animations on
        loop); one-shot pose tracks stay at their rest transform.
        """
        if len(keys) < 2 or not self._is_cyclic(keys):
            return
        keys = self._subdivide_keys(keys)
        if "animations" not in self.doc:
            self.doc["animations"] = [{"name": "default", "channels": [], "samplers": []}]
        anim = self.doc["animations"][0]
        times = [k["frame"] / fps for k in keys]
        t_view = self._view(struct.pack(f"<{len(times)}f", *times), 34962)
        t_acc = self._accessor(t_view, 5126, len(times), "SCALAR",
                               [min(times)], [max(times)])
        outputs = {
            "translation": [v for k in keys for v in
                            (k["pos"][0], k["pos"][1], -k["pos"][2])],
            "rotation": [v for k in keys for v in hpb_to_quat(*k["hpb"])],
            "scale": [v if abs(v) > 1e-4 else 1e-4
                      for k in keys for v in k["scale"]],
        }
        types = {"translation": ("VEC3", 3), "rotation": ("VEC4", 4), "scale": ("VEC3", 3)}
        for path, flat in outputs.items():
            type_, _ = types[path]
            view = self._view(struct.pack(f"<{len(flat)}f", *flat), 34962)
            acc = self._accessor(view, 5126, len(keys), type_)
            anim["samplers"].append({"input": t_acc, "interpolation": "LINEAR",
                                     "output": acc})
            anim["channels"].append({"sampler": len(anim["samplers"]) - 1,
                                     "target": {"node": node_idx, "path": path}})

    def save(self, out_gltf: Path) -> None:
        out_gltf.parent.mkdir(parents=True, exist_ok=True)
        if not self.doc["images"]:
            for k in ("images", "textures"):
                self.doc.pop(k)
        self.doc["buffers"] = [{"uri": out_gltf.with_suffix(".bin").name,
                                "byteLength": len(self.blob)}]
        out_gltf.with_suffix(".bin").write_bytes(bytes(self.blob))
        out_gltf.write_text(json.dumps(self.doc), encoding="utf-8")
