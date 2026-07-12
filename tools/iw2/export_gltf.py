"""Export all IW2 PSO meshes to glTF 2.0.

One .gltf/.bin pair per .pso, mirroring the resource tree under
``data/gltf/``. Textures reference the PNGs produced by tools.iw2.textures
via relative URIs (matched by filename stem).

Coordinates: LightWave/DirectX are left-handed (+Z forward); glTF is
right-handed (-Z forward). We negate Z on positions/normals and flip
triangle winding. UVs pass through unchanged (DX top-left origin matches
glTF).

Extra (non-standard but allowed) data preserved per material in "extras":
original surface name (contains #tags and <glow> channels), lightmap
texture (UV1), envmap name, the two shading coefficients.

Usage:  python -m tools.iw2.export_gltf [out_dir] [textures_dir]
"""

from __future__ import annotations

import json
import struct
import sys
from pathlib import Path, PurePosixPath

from .pso import parse_pso
from .resources import ResourceFS


def build_texture_index(textures_dir: Path) -> dict[str, list[Path]]:
    index: dict[str, list[Path]] = {}
    for png in textures_dir.rglob("*.png"):
        index.setdefault(png.stem.lower(), []).append(png)
    return index


def resolve_texture(index: dict, name: str | None, pso_dir: str) -> Path | None:
    if not name:
        return None
    stem = PurePosixPath(name.replace("\\", "/")).stem.lower()
    candidates = index.get(stem)
    if not candidates:
        return None
    for c in candidates:  # prefer texture living in the same avatar folder
        if c.parent.as_posix().lower().endswith(pso_dir.lower()):
            return c
    return candidates[0]


def export_pso(data: bytes, out_gltf: Path, tex_index: dict, pso_dir: str) -> dict:
    mesh = parse_pso(data)
    blob = bytearray()
    accessors, buffer_views, primitives = [], [], []
    materials, images, textures_json, samplers = [], [], [], [{"wrapS": 10497, "wrapT": 10497}]
    image_ids: dict[str, int] = {}

    def add_view(raw: bytes, target: int) -> int:
        while len(blob) % 4:
            blob.append(0)
        buffer_views.append({"buffer": 0, "byteOffset": len(blob), "byteLength": len(raw), "target": target})
        blob.extend(raw)
        return len(buffer_views) - 1

    def add_accessor(view: int, comp: int, count: int, type_: str, mn=None, mx=None) -> int:
        acc = {"bufferView": view, "componentType": comp, "count": count, "type": type_}
        if mn is not None:
            acc["min"], acc["max"] = mn, mx
        accessors.append(acc)
        return len(accessors) - 1

    def add_image(png: Path) -> int:
        key = png.as_posix()
        if key not in image_ids:
            uri = PurePosixPath(*png.parts).as_posix()
            rel = Path(uri)
            try:
                rel = png.relative_to(out_gltf.parent)
            except ValueError:
                import os
                rel = Path(os.path.relpath(png, out_gltf.parent))
            images.append({"uri": rel.as_posix()})
            textures_json.append({"source": len(images) - 1, "sampler": 0})
            image_ids[key] = len(textures_json) - 1
        return image_ids[key]

    for s in mesh.surfaces:
        nv = len(s.positions) // 3
        if nv == 0 or not s.indices:
            continue
        # flip Z for handedness
        pos = list(s.positions)
        nrm = list(s.normals)
        pos[2::3] = [-z for z in pos[2::3]]
        nrm[2::3] = [-z for z in nrm[2::3]]
        idx = list(s.indices)
        idx[1::3], idx[2::3] = idx[2::3], idx[1::3]  # flip winding

        pv = add_view(struct.pack(f"<{len(pos)}f", *pos), 34962)
        xs, ys, zs = pos[0::3], pos[1::3], pos[2::3]
        pa = add_accessor(pv, 5126, nv, "VEC3",
                          [min(xs), min(ys), min(zs)], [max(xs), max(ys), max(zs)])
        nvw = add_view(struct.pack(f"<{len(nrm)}f", *nrm), 34962)
        na = add_accessor(nvw, 5126, nv, "VEC3")
        attrs = {"POSITION": pa, "NORMAL": na}
        if s.uvs:
            uv_v = add_view(struct.pack(f"<{len(s.uvs)}f", *s.uvs), 34962)
            attrs["TEXCOORD_0"] = add_accessor(uv_v, 5126, nv, "VEC2")
        if s.uvs2:
            uv2_v = add_view(struct.pack(f"<{len(s.uvs2)}f", *s.uvs2), 34962)
            attrs["TEXCOORD_1"] = add_accessor(uv2_v, 5126, nv, "VEC2")
        iv = add_view(struct.pack(f"<{len(idx)}H", *idx), 34963)
        ia = add_accessor(iv, 5123, len(idx), "SCALAR")

        mat: dict = {
            "name": s.name,
            "pbrMetallicRoughness": {
                "baseColorFactor": [*s.color, 1.0],
                "metallicFactor": 0.1,
                "roughnessFactor": 0.85,
            },
            "extras": {"coeffs": list(s.coeffs)},
        }
        png = resolve_texture(tex_index, s.texture, pso_dir)
        if png is not None:
            mat["pbrMetallicRoughness"]["baseColorTexture"] = {"index": add_image(png), "texCoord": 0}
            mat["pbrMetallicRoughness"]["baseColorFactor"] = [1.0, 1.0, 1.0, 1.0]
        if s.texture2:
            mat["extras"]["lightmap"] = s.texture2
        if s.envmap:
            mat["extras"]["envmap"] = s.envmap
        if "<glow" in s.name:
            mat["emissiveFactor"] = [*s.color] if any(s.color) else [1.0, 1.0, 1.0]
            if png is not None:
                mat["emissiveTexture"] = {"index": image_ids[png.as_posix()], "texCoord": 0}
        materials.append(mat)
        primitives.append({"attributes": attrs, "indices": ia, "material": len(materials) - 1})

    gltf = {
        "asset": {"version": "2.0", "generator": "iw2-remaster pso exporter"},
        "scene": 0,
        "scenes": [{"nodes": [0]}],
        "nodes": [{"mesh": 0, "name": out_gltf.stem}],
        "meshes": [{"primitives": primitives}],
        "materials": materials,
        "accessors": accessors,
        "bufferViews": buffer_views,
        "buffers": [{"uri": out_gltf.with_suffix(".bin").name, "byteLength": len(blob)}],
        "samplers": samplers,
    }
    if images:
        gltf["images"] = images
        gltf["textures"] = textures_json
    out_gltf.parent.mkdir(parents=True, exist_ok=True)
    out_gltf.with_suffix(".bin").write_bytes(bytes(blob))
    out_gltf.write_text(json.dumps(gltf), encoding="utf-8")
    return {"surfaces": len(primitives), "animated": mesh.has_animation}


def main(out_dir: str = "data/gltf", textures_dir: str = "data/textures") -> None:
    fs = ResourceFS()
    out = Path(out_dir)
    tex_index = build_texture_index(Path(textures_dir))
    ok, failed = 0, []
    missing_tex = 0
    for p in fs.list("", ".pso"):
        rel = Path(p).with_suffix(".gltf")
        try:
            export_pso(fs.read_bytes(p), out / rel, tex_index, str(Path(p).parent.as_posix()))
            ok += 1
        except Exception as exc:
            failed.append((p, str(exc)))
    print(f"exported {ok}, failed {len(failed)}")
    for p, e in failed[:10]:
        print(f"  FAIL {p}: {e}")


if __name__ == "__main__":
    main(*sys.argv[1:])
