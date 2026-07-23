"""Bake the SHDR glow layer into per-model texture atlases.

What the original OBSERVABLY renders per surface (docs/original.md 7x,
incl. the open question there): the lit base pass and the unlit additive
glow (slot 2, SRCALPHA/ONE 'At' @ 0x1000b442). The slot-1 lightmap /
envmap pair (`StMt`) exists in CreateRenderSurface at shader_quality > 1
and the GOG install runs quality 2, yet reference captures (Clay's comm
head, the base underside) show the plain base with neither a modulate
darkening nor an additive spec -- so the pair is NOT reproduced here;
the discrepancy is logged in original.md's Open questions.

The glow's texture rides its own UV channel, which Godot materials cannot
address past two sets -- so glow surfaces are unwrapped with xatlas and
both their base and glow are re-rendered into a per-model atlas pair on
the ONE new UV set:

    albedo = base texture      emission = glow texture (white factor;
                                          channel energy stays runtime)

Sampling happens on the STORED 8-bit values (bilinear, one resample).

Surfaces are unwrapped with xatlas into one atlas pair per .pso; base-only
surfaces keep their original texture and UVs (baking them would only lose
tiling resolution). Atlas resolution follows the source texel density
(median texels-per-world-unit of the base layer), capped at MAX_ATLAS.

Outputs, cached under data/textures/baked/<pso path>:
    <stem>_alb.png   baked albedo atlas (sRGB)
    <stem>_em.png    baked emission atlas (only when a glow layer exists)
    <stem>.npz       per-surface remap: vmapping / indices / atlas UVs

Usage:  python -m tools.iw2.bake [--force]   (bakes every .pso; the
gltf exporters call bake_for() lazily and reuse the cache)
"""

from __future__ import annotations

import sys
from dataclasses import dataclass, field
from pathlib import Path, PurePosixPath

import numpy as np
from PIL import Image

MAX_ATLAS = 2048
PADDING = 4  # xatlas chart padding, backed by the same-width dilation
DILATE = 6


def _clamp_mode(mode: int) -> bool:
    # SetTextureMode @ flux.dll.c:98806 -- low nibble 3/4 = CLAMP, else WRAP
    return (mode & 0xF) in (3, 4)


@dataclass
class SurfaceBake:
    vmapping: np.ndarray  # new vertex -> original vertex index
    indices: np.ndarray  # (nt, 3) into the remapped vertices
    uvs: np.ndarray  # (nv, 2) atlas UVs, normalised
    has_emission: bool


@dataclass
class Bake:
    albedo_png: Path
    emission_png: Path | None
    surfaces: dict = field(default_factory=dict)  # surface index -> SurfaceBake


class _TexCache:
    """stem -> float32 RGB array in stored (gamma) bytes."""

    def __init__(self, textures_root: Path):
        self.root = textures_root
        self.index: dict[str, list[Path]] = {}
        for png in textures_root.rglob("*.png"):
            self.index.setdefault(png.stem.lower(), []).append(png)
        self.cache: dict[Path, np.ndarray] = {}

    def resolve(self, name: str | None, pso_dir: str) -> Path | None:
        if not name:
            return None
        stem = PurePosixPath(name.replace("\\", "/")).stem.lower()
        cands = self.index.get(stem)
        if not cands:
            return None
        for c in cands:
            if c.parent.as_posix().lower().endswith(pso_dir.lower()):
                return c
        return cands[0]

    def load(self, path: Path) -> np.ndarray:
        if path not in self.cache:
            img = Image.open(path).convert("RGB")
            self.cache[path] = np.asarray(img, dtype=np.float32)
        return self.cache[path]


_tex_caches: dict[Path, _TexCache] = {}


def _texcache(root: Path) -> _TexCache:
    if root not in _tex_caches:
        _tex_caches[root] = _TexCache(root)
    return _tex_caches[root]


def _sample(tex: np.ndarray, uv: np.ndarray, clamp: bool) -> np.ndarray:
    """Bilinear sample (N,2) UVs from an (H,W,3) gamma-byte array."""
    h, w = tex.shape[:2]
    x = uv[:, 0] * w - 0.5
    y = uv[:, 1] * h - 0.5
    x0 = np.floor(x).astype(np.int64)
    y0 = np.floor(y).astype(np.int64)
    fx = (x - x0)[:, None]
    fy = (y - y0)[:, None]

    def at(xi, yi):
        if clamp:
            xi = np.clip(xi, 0, w - 1)
            yi = np.clip(yi, 0, h - 1)
        else:
            xi = np.mod(xi, w)
            yi = np.mod(yi, h)
        return tex[yi, xi]

    return (at(x0, y0) * (1 - fx) * (1 - fy) + at(x0 + 1, y0) * fx * (1 - fy)
            + at(x0, y0 + 1) * (1 - fx) * fy + at(x0 + 1, y0 + 1) * fx * fy)


def _density(pos: np.ndarray, uvs: np.ndarray, idx: np.ndarray,
             tex_size: tuple[int, int]) -> float:
    """Median source-texture texels per world unit over the triangles."""
    a, b, c = idx[:, 0], idx[:, 1], idx[:, 2]
    px = uvs * np.array(tex_size, dtype=np.float32)
    e1 = np.linalg.norm(px[b] - px[a], axis=1) + 1e-9
    e2 = np.linalg.norm(px[c] - px[a], axis=1) + 1e-9
    w1 = np.linalg.norm(pos[b] - pos[a], axis=1) + 1e-9
    w2 = np.linalg.norm(pos[c] - pos[a], axis=1) + 1e-9
    return float(np.median(np.concatenate([e1 / w1, e2 / w2])))


def _dilate(img: np.ndarray, mask: np.ndarray, passes: int) -> np.ndarray:
    """Grow filled texels into the empty border so bilinear/mip sampling
    never reads black seams."""
    for _ in range(passes):
        grown = mask.copy()
        acc = np.zeros_like(img)
        cnt = np.zeros(mask.shape, dtype=np.float32)
        for dy in (-1, 0, 1):
            for dx in (-1, 0, 1):
                if dx == 0 and dy == 0:
                    continue
                sm = np.roll(np.roll(mask, dy, axis=0), dx, axis=1)
                si = np.roll(np.roll(img, dy, axis=0), dx, axis=1)
                take = sm & ~mask
                acc[take] += si[take]
                cnt[take] += 1
                grown |= sm
        fill = (cnt > 0) & ~mask
        img[fill] = acc[fill] / cnt[fill, None]
        mask = grown
    return img


def bake_for(pso_path: str, pso, textures_root: Path = Path("data/textures"),
             out_root: Path | None = None, force: bool = False) -> Bake | None:
    """Bake one parsed pso; returns None when nothing needs baking.

    Results are cached on disk (atlas PNGs + an .npz with the remap
    arrays); reruns load the cache unless force is set.
    """
    out_root = out_root or textures_root / "baked"
    rel = PurePosixPath(pso_path).with_suffix("")
    out_base = out_root / Path(rel)
    alb_png = out_base.parent / (out_base.name + "_alb.png")
    em_png = out_base.parent / (out_base.name + "_em.png")
    npz = out_base.parent / (out_base.name + ".npz")
    pso_dir = str(PurePosixPath(pso_path).parent)

    # only glow surfaces need the bake (the slot-1/envmap pair is not
    # reproduced -- see module docstring); everything else keeps its
    # authored texture and UVs untouched
    baked_idx = [i for i, s in enumerate(pso.surfaces)
                 if s.texture and len(s.indices) >= 3 and s.texture3]
    if not baked_idx:
        return None

    if npz.is_file() and alb_png.is_file() and not force:
        data = np.load(npz)
        bake = Bake(alb_png, em_png if em_png.is_file() else None)
        for i in baked_idx:
            if f"vm_{i}" not in data:
                break
            bake.surfaces[i] = SurfaceBake(
                data[f"vm_{i}"], data[f"idx_{i}"], data[f"uv_{i}"],
                bool(data[f"em_{i}"]))
        else:
            return bake

    tc = _texcache(textures_root)
    import xatlas

    atlas = xatlas.Atlas()
    dens = []
    metas = []
    for i in baked_idx:
        s = pso.surfaces[i]
        pos = np.asarray(s.positions, dtype=np.float32).reshape(-1, 3)
        idx = np.asarray(s.indices, dtype=np.uint32).reshape(-1, 3)
        atlas.add_mesh(pos, idx)
        base_path = tc.resolve(s.texture, pso_dir)
        base = tc.load(base_path) if base_path else None
        if base is not None and s.uvs:
            uv = np.asarray(s.uvs, dtype=np.float32).reshape(-1, 2)
            dens.append(_density(pos, uv, idx.astype(np.int64),
                                 (base.shape[1], base.shape[0])))
        metas.append((i, s, pos, idx))

    tpu = float(np.median(dens)) if dens else 64.0
    for _ in range(4):  # shrink until the atlas fits the cap
        po = xatlas.PackOptions()
        po.padding = PADDING
        po.texels_per_unit = tpu
        atlas.generate(pack_options=po)
        if max(atlas.width, atlas.height) <= MAX_ATLAS:
            break
        tpu *= MAX_ATLAS / max(atlas.width, atlas.height) * 0.98

    w, h = atlas.width, atlas.height
    alb = np.zeros((h, w, 3), dtype=np.float32)
    em = np.zeros((h, w, 3), dtype=np.float32)
    mask = np.zeros((h, w), dtype=bool)
    any_em = False
    bake = Bake(alb_png, None)

    for mi, (i, s, pos, idx) in enumerate(metas):
        vm, ni, nuv = atlas.get_mesh(mi)
        vm = vm.astype(np.int64)
        base_path = tc.resolve(s.texture, pso_dir)
        base = tc.load(base_path) if base_path else None
        glow = None
        if s.texture3:
            p = tc.resolve(s.texture3, pso_dir)
            glow = tc.load(p) if p else None

        uv0 = np.asarray(s.uvs, dtype=np.float32).reshape(-1, 2) \
            if s.uvs else None
        uv2 = np.asarray(s.uvs3, dtype=np.float32).reshape(-1, 2) \
            if s.uvs3 else None

        apix = nuv * np.array([w, h], dtype=np.float32)
        for t in ni:
            pa, pb, pc = apix[t[0]], apix[t[1]], apix[t[2]]
            x0 = max(int(np.floor(min(pa[0], pb[0], pc[0]))) - 1, 0)
            x1 = min(int(np.ceil(max(pa[0], pb[0], pc[0]))) + 1, w - 1)
            y0 = max(int(np.floor(min(pa[1], pb[1], pc[1]))) - 1, 0)
            y1 = min(int(np.ceil(max(pa[1], pb[1], pc[1]))) + 1, h - 1)
            if x1 < x0 or y1 < y0:
                continue
            xs, ys = np.meshgrid(np.arange(x0, x1 + 1) + 0.5,
                                 np.arange(y0, y1 + 1) + 0.5)
            d = ((pb[1] - pc[1]) * (pa[0] - pc[0])
                 + (pc[0] - pb[0]) * (pa[1] - pc[1]))
            if abs(d) < 1e-12:
                continue
            l0 = ((pb[1] - pc[1]) * (xs - pc[0])
                  + (pc[0] - pb[0]) * (ys - pc[1])) / d
            l1 = ((pc[1] - pa[1]) * (xs - pc[0])
                  + (pa[0] - pc[0]) * (ys - pc[1])) / d
            l2 = 1.0 - l0 - l1
            inside = (l0 >= -1e-4) & (l1 >= -1e-4) & (l2 >= -1e-4)
            if not inside.any():
                continue
            li = np.stack([l0[inside], l1[inside], l2[inside]], axis=1)
            ov = vm[t]  # original vertex ids of the triangle corners

            def lerp(attr):
                return li @ attr[ov]

            out = np.full((li.shape[0], 3), 255.0, dtype=np.float32)
            if base is not None and uv0 is not None:
                out = _sample(base, lerp(uv0), _clamp_mode(s.tex_mode))
            yi, xi = np.where(inside)
            alb[yi + y0, xi + x0] = out
            mask[yi + y0, xi + x0] = True
            if glow is not None and uv2 is not None:
                em[yi + y0, xi + x0] = _sample(
                    glow, lerp(uv2), _clamp_mode(s.tex3_mode))
                any_em = True

        bake.surfaces[i] = SurfaceBake(vm, ni.astype(np.uint32), nuv,
                                       bool(glow is not None and uv2 is not None))

    alb = _dilate(alb, mask.copy(), DILATE)
    alb_png.parent.mkdir(parents=True, exist_ok=True)
    Image.fromarray(np.clip(alb + 0.5, 0, 255).astype(np.uint8)).save(alb_png)
    if any_em:
        em = _dilate(em, mask.copy(), DILATE)
        Image.fromarray(np.clip(em + 0.5, 0, 255).astype(np.uint8)).save(em_png)
        bake.emission_png = em_png
    arrays = {}
    for i, sb in bake.surfaces.items():
        arrays[f"vm_{i}"] = sb.vmapping
        arrays[f"idx_{i}"] = sb.indices
        arrays[f"uv_{i}"] = sb.uvs
        arrays[f"em_{i}"] = np.array(sb.has_emission)
    np.savez_compressed(npz, **arrays)
    return bake


def main() -> None:
    from .pso import parse_pso
    from .resources import ResourceFS
    force = "--force" in sys.argv[1:]
    fs = ResourceFS()
    baked = skipped = failed = 0
    for p in fs.list("", ".pso"):
        try:
            b = bake_for(p, parse_pso(fs.read_bytes(p)), force=force)
            if b is None:
                skipped += 1
            else:
                baked += 1
        except Exception as exc:
            failed += 1
            print(f"FAIL {p}: {exc}")
    print(f"baked {baked}, no-layers {skipped}, failed {failed}")


if __name__ == "__main__":
    main()
