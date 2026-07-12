"""Convert IW2 bitmap fonts (.frf + .ftu atlas) to BMFont .fnt + RGBA PNG.

The ``fonts/*.frf`` files are IFF ``FORM FONT``:

    FHDR (70B): u32be first_char, last_char, first_char(again),
        line_height, descent, tex_w, tex_h, unknown(147), point_size,
        then two NUL strings: atlas name (*.lbm) and family name.
    GLYP per char (first..last): u8 present flag; if present, 10 x s32be:
        logical box  (x0, y0, x1, y1)   y relative to baseline (up = -)
        ink box      (x0, y0, x1, y1)
        atlas position (tex_x, tex_y)

Output: ``data/fonts/<stem>.fnt`` (BMFont text) + ``<atlas>.png`` with
alpha from luminance — Godot's FontFile.load_bitmap_font reads these
directly, so the game renders with the game's own OCR-B / Handel Gothic /
Square721 faces.

Usage:  python -m tools.iw2.fonts
"""

from __future__ import annotations

import struct
from pathlib import Path

from PIL import Image

from .resources import ResourceFS


def parse_frf(data: bytes) -> dict:
    assert data[:4] == b"FORM" and data[8:12] == b"FONT"
    off = 12
    font: dict = {"glyphs": {}}
    while off + 8 <= len(data):
        tag = data[off:off + 4]
        (size,) = struct.unpack_from(">I", data, off + 4)
        body = data[off + 8: off + 8 + size]
        if tag == b"FHDR":
            (first, last, _f2, line_h, descent, tex_w, tex_h, _u,
             point) = struct.unpack_from(">9I", body, 0)
            strings = body[38:].split(b"\x00")
            font.update(first=first, last=last, line_height=line_h,
                        descent=descent, tex_w=tex_w, tex_h=tex_h,
                        point=point, atlas=strings[0].decode("latin-1"),
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


def write_bmfont(font: dict, atlas_png: str, out_path: Path) -> None:
    base = font["line_height"] - font["descent"]
    lines = [
        'info face="%s" size=%d bold=0 italic=0 charset="" unicode=1 '
        'stretchH=100 smooth=0 aa=0 padding=0,0,0,0 spacing=0,0'
        % (font["family"], font["point"]),
        "common lineHeight=%d base=%d scaleW=%d scaleH=%d pages=1 packed=0"
        % (font["line_height"], base, font["tex_w"], font["tex_h"]),
        'page id=0 file="%s"' % atlas_png,
        "chars count=%d" % len(font["glyphs"]),
    ]
    for code, g in sorted(font["glyphs"].items()):
        lx0, ly0, lx1, ly1, ix0, iy0, ix1, iy1, tx, ty = g
        w = max(ix1 - ix0 + 1, 0)
        h = max(iy1 - iy0 + 1, 0)
        advance = lx1  # logical right edge = pen advance
        if w <= 0 or h <= 0:
            w = 0
            h = 0
        lines.append(
            "char id=%d x=%d y=%d width=%d height=%d xoffset=%d yoffset=%d "
            "xadvance=%d page=0 chnl=15"
            % (code, tx, ty, w, h, ix0, base + iy0, advance))
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
        write_bmfont(font, atlas_png, out / f"{stem}.fnt")
        print(f"{stem}: {len(font['glyphs'])} glyphs, atlas {atlas_png}, "
              f"line {font['line_height']}")


if __name__ == "__main__":
    main()
