"""Minimal glTF 2.0 document builder shared by the export tools.

Handles the LightWave(left-handed, +Z fwd) -> glTF(right-handed, -Z fwd)
conversion: geometry Z is negated (winding flipped), node translations get
Z negated, and HPB rotations become quaternion Ry(-H)*Rx(-P)*Rz(B)
(change of basis with S=diag(1,1,-1)).
"""

from __future__ import annotations

import json
import math
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

    def material(self, surface, texture_uri: str | None) -> int:
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
        if surface.texture2:
            mat["extras"]["lightmap"] = surface.texture2
        if surface.envmap:
            mat["extras"]["envmap"] = surface.envmap
        if "<glow" in surface.name:
            mat["emissiveFactor"] = list(surface.color) if any(surface.color) else [1, 1, 1]
            if texture_uri:
                mat["emissiveTexture"] = {"index": self._image_ids[texture_uri], "texCoord": 0}
        self.doc["materials"].append(mat)
        return len(self.doc["materials"]) - 1

    def mesh_from_pso(self, key: str, pso, resolve_texture) -> int | None:
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
            prims.append({"attributes": attrs, "indices": ia,
                          "material": self.material(s, resolve_texture(s))})
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
            n["scale"] = list(scale)
        if extras:
            n["extras"] = extras
        self.doc["nodes"].append(n)
        idx = len(self.doc["nodes"]) - 1
        if parent is None:
            self.doc["scenes"][0]["nodes"].append(idx)
        else:
            self.doc["nodes"][parent].setdefault("children", []).append(idx)
        return idx

    def save(self, out_gltf: Path) -> None:
        out_gltf.parent.mkdir(parents=True, exist_ok=True)
        if not self.doc["images"]:
            for k in ("images", "textures"):
                self.doc.pop(k)
        self.doc["buffers"] = [{"uri": out_gltf.with_suffix(".bin").name,
                                "byteLength": len(self.blob)}]
        out_gltf.with_suffix(".bin").write_bytes(bytes(self.blob))
        out_gltf.write_text(json.dumps(self.doc), encoding="utf-8")
