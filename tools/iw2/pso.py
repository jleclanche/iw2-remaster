"""Parser for IW2 PSO/PSO2 mesh files (Particle Systems Object).

IFF-style container, reverse-engineered:

    FORM <u32be size> ("PSO " | "PSO2")
    OHDR: u32be a, u32be b, u32be n_textures, then n_textures NUL-strings
          (.LBM texture names; converted PNGs share the stem)
    then per surface:
    SHDR: NUL-str surface name,
          f32be[5]: diffuse RGB + 2 coefficients,
          two texture slots { u32be index (1-based into OHDR list, 0=none),
                              u32be mode (0x21/0x24 seen), u32be pad },
          8 bytes zeros, optional NUL-str envmap filename, sometimes extra
          slot data (glow channels) — parsed leniently,
          tail: u32be n_verts, u32be n_uv_channels
    VERT: n_verts * f32le[3 pos + 3 normal + 2*n_uv uv]   (little-endian!)
    INDX: 2-byte prefix (meaning unknown; NOT a reliable count), then
          (size-2)/6 triangles as 3 u16le indices each
    DELT / FRAM: deltas/animation, not yet decoded (preserved as raw)

Mixed endianness: IFF headers/metadata big-endian, vertex/index payload
little-endian (DirectX-ready buffers).
"""

from __future__ import annotations

import struct
from dataclasses import dataclass, field


@dataclass
class Surface:
    name: str
    color: tuple  # RGB 0..1
    coeffs: tuple
    texture: str | None  # OHDR texture name for UV0 slot
    texture2: str | None  # second layer (lightmap), UV1
    envmap: str | None
    positions: list = field(default_factory=list)  # flat [x,y,z,...]
    normals: list = field(default_factory=list)
    uvs: list = field(default_factory=list)  # first channel only, flat [u,v,...]
    uvs2: list = field(default_factory=list)
    indices: list = field(default_factory=list)  # flat triangle indices


@dataclass
class Pso:
    version: str
    textures: list[str]
    surfaces: list[Surface]
    has_animation: bool = False


def _zstr(b: bytes, off: int) -> tuple[str, int]:
    end = b.index(0, off)
    return b[off:end].decode("latin-1"), end + 1


def _parse_shdr(body: bytes, textures: list[str]) -> tuple:
    name, off = _zstr(body, 0)
    color = struct.unpack_from(">3f", body, off)
    coeffs = struct.unpack_from(">2f", body, off + 12)
    off += 20
    nv, nuv = struct.unpack_from(">2I", body, len(body) - 8)

    def tex_at(o):
        if o + 4 > len(body) - 8:
            return None
        (i,) = struct.unpack_from(">I", body, o)
        return textures[i - 1] if 1 <= i <= len(textures) else None

    texture = tex_at(off)
    texture2 = tex_at(off + 12)
    # optional envmap: longest printable ascii run in the remainder
    envmap = None
    mid = body[off + 24: len(body) - 8]
    run, best = bytearray(), b""
    for c in mid:
        if 32 <= c < 127:
            run.append(c)
        else:
            if len(run) > len(best):
                best = bytes(run)
            run = bytearray()
    if len(run) > len(best):
        best = bytes(run)
    if len(best) >= 5 and (b"." in best):
        envmap = best.decode("latin-1")
    return name, color, coeffs, texture, texture2, envmap, nv, nuv


def parse_pso(data: bytes) -> Pso:
    if data[:4] != b"FORM" or data[8:12] not in (b"PSO ", b"PSO2"):
        raise ValueError("not a PSO file")
    pso = Pso(version=data[8:12].decode().strip(), textures=[], surfaces=[])
    off = 12
    pending = None
    while off + 8 <= len(data):
        tag = data[off:off + 4]
        (size,) = struct.unpack_from(">I", data, off + 4)
        body = data[off + 8: off + 8 + size]
        off += 8 + size + (size & 1)
        if tag == b"OHDR":
            (_, _, ntex) = struct.unpack_from(">3I", body, 0)
            p = 12
            for _ in range(ntex):
                s, p = _zstr(body, p)
                pso.textures.append(s)
        elif tag == b"SHDR":
            name, color, coeffs, tex, tex2, env, nv, nuv = _parse_shdr(body, pso.textures)
            pending = Surface(name, tuple(color), tuple(coeffs), tex, tex2, env)
            pending._nv, pending._nuv = nv, nuv  # type: ignore[attr-defined]
        elif tag == b"VERT" and pending is not None:
            nv, nuv = pending._nv, pending._nuv  # type: ignore[attr-defined]
            stride = 24 + 8 * nuv
            if nv * stride != size:
                raise ValueError(f"VERT size mismatch in {pending.name}: {nv}*{stride} != {size}")
            for v in range(nv):
                vals = struct.unpack_from(f"<{stride // 4}f", body, v * stride)
                pending.positions.extend(vals[0:3])
                pending.normals.extend(vals[3:6])
                if nuv >= 1:
                    pending.uvs.extend(vals[6:8])
                if nuv >= 2:
                    pending.uvs2.extend(vals[8:10])
        elif tag == b"INDX" and pending is not None:
            ntri = (size - 2) // 6
            pending.indices = list(struct.unpack_from(f"<{ntri * 3}H", body, 2))
            pso.surfaces.append(pending)
            pending = None
        elif tag in (b"DELT", b"FRAM"):
            pso.has_animation = True
    return pso
