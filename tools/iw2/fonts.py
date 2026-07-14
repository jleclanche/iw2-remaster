"""Convert IW2 bitmap fonts (.frf + .ftu atlas) to BMFont .fnt + RGBA PNG.

The ``fonts/*.frf`` files are IFF ``FORM FONT``.  Field names below are the
engine's, read straight out of ``FcFont``'s loader (flux.dll @ 0x10082e50,
the FHDR reader at 0x10083084..0x100831c0) -- NOT guessed from the layout:

    FHDR: 9 x s32be, then 2 x bool8, then two NUL strings.
        first_char, last_char, default_char,   -> FcFont +0x18, +0x1c, +0x20
        ascent, descent,                       -> FcFont +0x24, +0x28
        tex_w, tex_h,                          -> FcFont +0x38, +0x3c
        num_glyphs, point_size,                -> loop count, FcFont +0x2c
        bold, italic (bool8 each)              -> FcFont +0x30, +0x31
        atlas name (*.lbm), family name        -> FcFont +0x40, +0x48
    GLYP per char: u8 present flag; if present, 10 x s32be, read by
    FcGlyph::FcGlyph(FcFont*, FcIFFFile&) (flux.dll @ 0x1007fe60) into:
        logical box  lx0, ly0, lx1, ly1   (+0x00 +0x04 +0x08 +0x0c)
        ink box      ix0, iy0, ix1, iy1   (+0x10 +0x14 +0x18 +0x1c)
        atlas pos    tx, ty               (+0x30 +0x34)
    y is relative to the baseline, up = negative.

*** The engine's text layout, extracted, not guessed ***

FcGraphicsEngine::DrawText (flux.dll @ 0x100609c0) is the pen loop:

    baseline_y = y + font.ascent                    ; font +0x24
    pen = x - (first_glyph.ix0 - first_glyph.lx0)   ; trim first left bearing
    for each char c (spaces draw no quad but still advance):
        quad  = (pen + ix0, baseline_y + iy0) .. (pen + ix1, baseline_y + iy1)
        uv    = (tx, ty) .. (tx + ix1 - ix0, ty + iy1 - iy0)   ; AddGlyph 0x10081d60
        pen  += (lx1 - lx0) + FcFont::Kern(c, next_c)

so the source rect is EXCLUSIVE: width = ix1 - ix0, height = iy1 - iy0,
blitted 1:1 -- there is no +1, and the pen advance is the logical box WIDTH
(lx1 - lx0), never the absolute right edge lx1.

FcFont::GetTextSize (flux.dll @ 0x100827a0) measures the same way, and then
trims the first glyph's left bearing and the last glyph's right bearing, so a
string's reported width is its INK extent:

    w = sum(lx1 - lx0) + sum(kern) - (ix0_first - lx0_first)
                                   - (lx1_last  - ix1_last)

*** Kerning ***

FcFont::Kern (flux.dll @ 0x100828e0) returns, for a font that is neither
fixed-width (+0x32, never set by anything -- always false) nor italic (+0x31):

    Kern(a, b) = font.m_additional_kern            ; FcFont +0x34

It never consults a pair table: the 236 pairs registered in the FcFont ctor
(flux.dll @ 0x100800b0) all pass italic=true, so they land in the *italic*
table only; the non-italic table is never populated by any DLL.  Italic faces
additionally get a flat -3 for pairs missing from that table.

m_additional_kern is NOT in the .frf.  The HUD sets it on its own three FcFont
instances when it loads its font table (iwar2.dll FUN_100e8220 @ 0x100e8220):

    100e8271  call GetGlyph(font, 'M')
    100e827c  sub  edx, edi              ; M.lx1 - M.lx0
    100e8290  fadd dword ptr [esi+0xc]   ; + table entry's kern field
    100e8293  fstp dword ptr [esi+4]     ; -> entry.char_width
    100e82a9  fld  dword ptr [esi+0xc]
    100e82ac  call ftol
    100e82b4  mov  dword ptr [edi+0x34], eax   ; font.m_additional_kern = kern

so only HUD text (iwar2.dll FUN_100eb270) is spaced by it -- see hud.gd.  This
converter emits the .frf's own metrics, which is what every other consumer of
these faces renders with.

Output: ``data/fonts/<stem>.fnt`` (BMFont text) + ``<atlas>.png`` with
alpha from luminance -- Godot's FontFile.load_bitmap_font reads these
directly, so the game renders with the game's own OCR-B / Handel Gothic /
Square721 faces.

Usage:  python -m tools.iw2.fonts
"""

from __future__ import annotations

import struct
from pathlib import Path

from PIL import Image

from .resources import ResourceFS


# *** m_additional_kern is deliberately NOT baked in here. ***
#
# It is not a property of the .frf -- it is a property of the three FcFont
# *instances* the HUD keeps in its own font table, and only text drawn through
# the HUD's FUN_100eb270 gets it (+1 / -6 / -5 for font 0 / 1 / 2).  The same
# faces drawn by anything else -- the MFD panels, the contacts list, the
# stellar-map labels -- keep the ctor default of 0 and advance by the raw
# logical width.  Ground truth: in the original, the map's star labels and the
# contacts list both measure a 5px cell for ocrb_8pt, whose raw cell is 5 and
# whose HUD cell is 6.  Baking the kern into the .fnt would widen every one of
# them.  game/scripts/hud.gd owns that table (HUD_KERN) and applies it as glyph
# spacing on the HUD text path only.
#
# Italic faces are different: FcFont::Kern gives ANY draw path a flat -3 for
# pairs absent from the italic pair table (flux.dll @ 0x10082779:
# (-(italic) & 0xfffffffd) + m_additional_kern), so that one IS a property of
# the font and is baked.  The 236 registered pairs adjust it by 0..-5; no HUD
# face is italic, so that residual is not modelled.
ITALIC_DEFAULT_KERN = -3


def parse_frf(data: bytes) -> dict:
    assert data[:4] == b"FORM" and data[8:12] == b"FONT"
    off = 12
    font: dict = {"glyphs": {}}
    while off + 8 <= len(data):
        tag = data[off:off + 4]
        (size,) = struct.unpack_from(">I", data, off + 4)
        body = data[off + 8: off + 8 + size]
        if tag == b"FHDR":
            # 9 x s32be, then bold/italic as bool8, then the two strings.
            (first, last, default, ascent, descent, tex_w, tex_h, _nglyphs,
             point) = struct.unpack_from(">9I", body, 0)
            bold, italic = body[36], body[37]
            strings = body[38:].split(b"\x00")
            font.update(first=first, last=last, default=default,
                        ascent=ascent, descent=descent,
                        tex_w=tex_w, tex_h=tex_h, point=point,
                        bold=bool(bold), italic=bool(italic),
                        atlas=strings[0].decode("latin-1"),
                        family=strings[1].decode("latin-1") if len(strings) > 1 else "")
            font["_next"] = first
        elif tag == b"GLYP":
            code = font["_next"]
            font["_next"] += 1
            if body[0] and len(body) >= 41:
                g = struct.unpack_from(">10i", body, 1)
                font["glyphs"][code] = g
        off += 8 + size + (size & 1)
    return font


def write_bmfont(font: dict, atlas_png: str, out_path: Path, kern: int = 0) -> None:
    """Emit BMFont metrics that reproduce the engine's layout exactly.

    base       = ascent                (DrawText: baseline_y = y + font+0x24)
    lineHeight = ascent + descent      (FcFont::FontHeight, flux @ 0x10015240)
    xadvance   = (lx1 - lx0) + kern    (DrawText pen step + FcFont::Kern)
    xoffset    = ix0                   (quad left = pen + ix0)
    yoffset    = ascent + iy0          (quad top  = baseline + iy0)
    width      = ix1 - ix0             (source rect is exclusive: no +1)
    height     = iy1 - iy0
    """
    base = font["ascent"]
    line_height = font["ascent"] + font["descent"]
    lines = [
        'info face="%s" size=%d bold=%d italic=%d charset="" unicode=1 '
        'stretchH=100 smooth=0 aa=0 padding=0,0,0,0 spacing=0,0'
        % (font["family"], font["point"], font["bold"], font["italic"]),
        "common lineHeight=%d base=%d scaleW=%d scaleH=%d pages=1 packed=0"
        % (line_height, base, font["tex_w"], font["tex_h"]),
        'page id=0 file="%s"' % atlas_png,
        "chars count=%d" % len(font["glyphs"]),
    ]
    for code, g in sorted(font["glyphs"].items()):
        lx0, ly0, lx1, ly1, ix0, iy0, ix1, iy1, tx, ty = g
        w = max(ix1 - ix0, 0)
        h = max(iy1 - iy0, 0)
        if w <= 0 or h <= 0:  # e.g. space: advances, draws nothing
            w = 0
            h = 0
        lines.append(
            "char id=%d x=%d y=%d width=%d height=%d xoffset=%d yoffset=%d "
            "xadvance=%d page=0 chnl=15"
            % (code, tx, ty, w, h, ix0, base + iy0, (lx1 - lx0) + kern))
    out_path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main(out_dir: str = "data/fonts") -> None:
    fs = ResourceFS()
    out = Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)
    textures = Path("data/textures/fonts")
    done_atlases: set[str] = set()
    for path in fs.list("fonts/", ".frf"):
        font = parse_frf(fs.read_bytes(path))
        atlas_stem = Path(font["atlas"]).stem.lower()
        atlas_png = f"{atlas_stem}.png"
        if atlas_stem not in done_atlases:
            done_atlases.add(atlas_stem)
            src = textures / atlas_png
            if src.is_file():
                img = Image.open(src).convert("L")
                rgba = Image.merge("RGBA", (
                    Image.new("L", img.size, 255), Image.new("L", img.size, 255),
                    Image.new("L", img.size, 255), img))
                rgba.save(out / atlas_png)
            else:
                print(f"WARN missing atlas {src}")
        stem = Path(path).stem.lower()
        kern = ITALIC_DEFAULT_KERN if font["italic"] else 0
        write_bmfont(font, atlas_png, out / f"{stem}.fnt", kern)
        print(f"{stem}: {len(font['glyphs'])} glyphs, atlas {atlas_png}, "
              f"family {font['family']!r}, ascent {font['ascent']} "
              f"descent {font['descent']} kern {kern:+d}")


if __name__ == "__main__":
    main()
