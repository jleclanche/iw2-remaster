"""Parser for IW2 PSO/PSO2 mesh files (Particle Systems Object).

IFF-style container. The SHDR layout below mirrors the engine's own reader,
FcModel::ReadPSOGeometry @ 0x100652e0 (flux.dll.c:99120-99347):

    FORM <u32be size> ("PSO " | "PSO2")
    OHDR: u32be a, u32be b, u32be n_textures, then n_textures NUL-strings
          (.LBM texture names; converted PNGs share the stem)
    then per surface:
    SHDR: NUL-str surface name,
          f32be[4]: diffuse RGB + opacity,
          THREE texture slots, each { f32be brightness, u32be index
          (1-based into OHDR list, 0=none), u32be mode }:
            slot 0 = base layer, slot 1 = modulate lightmap layer,
            slot 2 = additive glow layer (see CreateRenderSurface below),
          NUL-str envmap filename (may be empty),
          tail: u32be n_verts, u32be n_uv_channels
    VERT: n_verts * f32le[3 pos + 3 normal + 2*n_uv uv]   (little-endian!)
          UV channels are assigned to TEXTURED slots in slot order
          (ReadPSOGeometry's set counter, flux.dll.c:99174-99177); the
          envmap uses generated sphere-map coords, no VERT channel.
    INDX: 2-byte prefix (meaning unknown; NOT a reliable count), then
          (size-2)/6 triangles as 3 u16le indices each
    DELT: vertex-morph delta block for the preceding surface:
          u32be a (start/flags?), u32be b (group?), then N * f32le[3] deltas
          (N = (size-8)/12). Used for character facial animation (Az, Jafs
          etc.) driven by MORPHGIZMO .giz group/weight tracks.
    FRAM: u32be frame_count, u32be group_count, then per group: u32be id,
          NUL-str name, weight track (f32 data). Partially decoded; raw
          bytes preserved.

Mixed endianness: IFF headers/metadata big-endian, vertex/index payload
little-endian (DirectX-ready buffers).

How the engine renders the slots (FcModel::CreateRenderSurface @ 0x10066600,
layer ops named by "RAMSD"[op] in dx7graph @ 0x1000ab30):

- slot 0 -> the lit base layer ('A' opaque / 'R' translucent).
- slot 1 -> a MODULATE layer ('M'): multiplies the base (single-pass
  D3DTOP_MODULATE(2X), or a ZERO/SRCCOLOR multiply pass in the multipass
  fallback @ 0x1000b6b8). Never additive, never lit.
- slot 2 -> an ADDITIVE glow layer ('A' as a later pass: SRCALPHA/ONE
  @ 0x1000b442), unlit (flags bit0 -> SetMaterial emissive @ 0x100127d0).
  This is what makes windows/engine lozenges glow; its alpha is channel-
  driven for <glow channel=EXPR> surfaces (AddSurfaceChannel).
- The authored surface COLOUR is discarded (forced to FcColour::White())
  whenever slot 0 has a texture (flux.dll.c:99181-99184); textured layers
  keep the cLayer ctor's white tint (0x10067f10). LightWave's random
  per-surface colours therefore never render on textured surfaces.
"""

from __future__ import annotations

import struct
from dataclasses import dataclass, field


@dataclass
class Surface:
    name: str
    color: tuple  # RGB 0..1; engine renders it ONLY on untextured surfaces
    coeffs: tuple  # (opacity, slot-0 brightness) per ReadPSOGeometry
    texture: str | None  # slot 0: base texture
    texture2: str | None  # slot 1: MODULATE lightmap (never additive)
    envmap: str | None
    # slot mode words: SAMPLER ADDRESSING bitfields (SetTextureMode @
    # flux.dll.c:98806 -- low nibble 3/4 = CLAMP, else WRAP; bit 0x20 =
    # filter flag). NOT blend modes; the layer op is fixed by the slot.
    tex2_mode: int = 0
    texture3: str | None = None  # slot 2: ADDITIVE glow layer (unlit, white)
    tex3_mode: int = 0
    positions: list = field(default_factory=list)  # flat [x,y,z,...]
    normals: list = field(default_factory=list)
    uvs: list = field(default_factory=list)  # slot-0 channel, flat [u,v,...]
    uvs2: list = field(default_factory=list)  # slot-1 (lightmap) channel
    uvs3: list = field(default_factory=list)  # slot-2 (glow) channel
    indices: list = field(default_factory=list)  # flat triangle indices


@dataclass
class Pso:
    version: str
    textures: list[str]
    surfaces: list[Surface]
    has_animation: bool = False
    morphs: list = None  # per surface-group DELT blocks
    fram_raw: bytes = b""


def _zstr(b: bytes, off: int) -> tuple[str, int]:
    end = b.index(0, off)
    return b[off:end].decode("latin-1"), end + 1


def _parse_shdr(body: bytes, textures: list[str]) -> Surface:
    name, off = _zstr(body, 0)
    color = struct.unpack_from(">3f", body, off)
    opacity, bri0 = struct.unpack_from(">2f", body, off + 12)
    slots = []
    q = off + 16
    for _ in range(3):  # {brightness f32, index u32, mode u32} x3
        idx, mode = struct.unpack_from(">2I", body, q + 4)
        slots.append((textures[idx - 1] if 1 <= idx <= len(textures) else None,
                      mode))
        q += 12
    envmap, q = _zstr(body, q)
    if not envmap:
        envmap = None
    s = Surface(name, tuple(color), (opacity, bri0),
                slots[0][0], slots[1][0], envmap,
                tex2_mode=slots[1][1],
                texture3=slots[2][0], tex3_mode=slots[2][1])
    nv, nuv = struct.unpack_from(">2I", body, len(body) - 8)
    s._nv, s._nuv = nv, nuv  # type: ignore[attr-defined]
    return s


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
            pending = _parse_shdr(body, pso.textures)
        elif tag == b"VERT" and pending is not None:
            nv, nuv = pending._nv, pending._nuv  # type: ignore[attr-defined]
            stride = 24 + 8 * nuv
            if nv * stride != size:
                raise ValueError(f"VERT size mismatch in {pending.name}: {nv}*{stride} != {size}")
            # UV channels belong to TEXTURED slots in slot order (see module
            # docstring); pick each slot's channel index up front
            chans: list[list] = [[] for _ in range(nuv)]
            for v in range(nv):
                vals = struct.unpack_from(f"<{stride // 4}f", body, v * stride)
                pending.positions.extend(vals[0:3])
                pending.normals.extend(vals[3:6])
                for c in range(nuv):
                    chans[c].extend(vals[6 + 2 * c:8 + 2 * c])
            c = 0
            for tex, attr in ((pending.texture, "uvs"),
                              (pending.texture2, "uvs2"),
                              (pending.texture3, "uvs3")):
                if tex and c < nuv:
                    setattr(pending, attr, chans[c])
                    c += 1
        elif tag == b"INDX" and pending is not None:
            ntri = (size - 2) // 6
            pending.indices = list(struct.unpack_from(f"<{ntri * 3}H", body, 2))
            pso.surfaces.append(pending)
            pending = None
        elif tag == b"DELT":
            pso.has_animation = True
            a, b_ = struct.unpack_from(">2I", body, 0)
            n = (size - 8) // 12
            deltas = struct.unpack_from(f"<{n * 3}f", body, 8)
            if pso.morphs is None:
                pso.morphs = []
            pso.morphs.append({"surface": len(pso.surfaces) - 1, "a": a,
                               "b": b_, "deltas": deltas})
        elif tag == b"FRAM":
            pso.has_animation = True
            pso.fram_raw = bytes(body)
    return pso
