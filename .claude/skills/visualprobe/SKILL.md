---
name: visualprobe
description: Verify render output against the original game — temporary screenshot probe flags, windowed capture, and Pillow pixel comparison. Use when investigating visual parity (colors, textures, effects) or after changing world/sky/effect rendering.
---

# Visual parity probes

## Pixel forensics first (no game launch needed)

Compare an original-game screenshot against the decoded source texture —
if the original's pixels equal the texture bytes, the original renders it
verbatim and any deviation is OURS. Decode straight from the install:

```python
import io
from PIL import Image
from tools.iw2.resources import ResourceFS   # run from repo root
fs = ResourceFS()
img = Image.open(io.BytesIO(fs.read_bytes("models/foo_0.ftc")))
```

- `.ftc` = DXT (what the engine loads), `.ftu` = uncompressed authoring
  copy (often cleaner). Pillow's FtexImagePlugin decodes both.
- Sample screenshot regions with `crop(box).resize((1,1), Image.BOX)` for
  mean color; use scanline slices to tell filtering artifacts apart
  (continuous ramp = bilinear, flat plateaus = nearest, 4-px blocks = DXT).
- Zoom crops for the eye: `crop(...).resize(4x, Image.NEAREST)`, save to
  the scratchpad, then Read the PNG.

## Known color-space laws (already established, don't re-derive)

- Godot Forward+ round-trips unlit texels byte-exact (srgbprobe,
  main_state.gd `_load_gltf` NOTE) — but ONLY at texel centers.
- D3D7 filtered/blended gamma bytes; Godot decodes sRGB BEFORE filtering.
  Faithful pattern: sample the texture with a NON-source_color uniform
  (raw), convert sRGB→linear in the shader AFTER filtering — see
  `_make_additive` / `_additive_backdrop_shader` in main_world.gd.
- No post-processing: glow off, no ambient, BG_COLOR black.

## In-game capture probe

Screenshots need a real window (headless won't render). Pattern
(`--nebshot` in space_fx.gd and `_sunshot` in checks.gd are the models):

1. Add `"<name>probe"` to the flag list in main.gd `_ready`, a
   `var <name>probe := false` in main_state.gd, a branch at the TOP of
   `CheckRunner.step()` in checks.gd.
2. Probe body: wait `demo_t > 1.2` for streaming; aim via
   `m.ship.global_transform` + `m.cam_mode = 0` + `m._apply_view()`;
   hide `m.hud.visible` / `m.menu.visible`; call `_shot("name")` (saves to
   `data/screenshots/`); `m.get_tree().quit()` when done.
3. Run: `<godot> --path game --resolution 1600x900 -- --<name>probe`
   (window flashes briefly; that's fine).
4. **STRIP before commit** and assert:
   `git grep -n "<name>probe" -- game/` must return nothing.

`<godot>` = the full console-exe path in CLAUDE.md.
