# Thrusters — icFlameConeAvatar

Recovered from `iwar2.dll`. Ghidra dropped the entire avatar vtable cluster
(`FUN_100bd5b0`..`FUN_100bdad0` decompiled to nothing); everything below was
raw-disassembled with `python tools/ghidra/disasm.py build/bin/iwar2.dll <va>`.

The old remaster stand-in (`ship_effects.gd::_add_flame_cone`) built a plain
untextured `CylinderMesh` with `albedo_color = Color(tint, 0.55)` — no texture,
no animation, no channel response. That is the "flat and constant" the user
reported (task #72). The real avatar scrolls a turbulent plasma texture down a
cone every frame; that scroll is what reads as fire.

## Registry route

- class string `"icFlameConeAvatar"` at `iwar2.dll @ 0x101618e0`
- `FUN_100bcf80 @ 0x100bcf80` → `FcRegistry::RegisterClass(name, base, factory=FUN_100bcfc0, propmap=&DAT_101713e0)`
- factory `FUN_100bcfc0 @ 0x100bcfc0` → `operator_new(0xDC)` → ctor `FUN_100bd350`
- vtable installed by the ctor: `PTR_LAB_1011cbd4 @ 0x1011cbd4`
  - slot 6  (`+0x18`) `0x100bd5b0` — SetChannel (parses the "channel" property)
  - slot 14 (`+0x38`) `0x100bd5f0` — **Prepare** (advances the scroll phase)
  - slot 16 (`+0x40`) `0x100bd630` — **Draw**

## Property map — what the INI/LWS authors

`FUN_100bd030 @ 0x100bd030` builds three `sProperty` records; object size `0xDC`:

| property  | type       | offset  | default                                    |
|-----------|------------|---------|--------------------------------------------|
| `channel` | string (5) | `+0xd0` | `null` string; parsed to `FcChannelExpression` at `+0xd8` |
| `splay`   | float (2)  | `+0xbc` | `0.5`  (`DAT_1011cbc0`)                     |
| `tint`    | FcColour(6)| `+0xc0` | `(1, 1, 0)` (`DAT_101713d0..d8`, all `0x3f800000`/0) |

The per-node values come through the glTF extras (`assemble_avatar.py`):
`iw2_class=icFlameConeAvatar`, `iw2_channel`, `iw2_tint`, `iw2_splay`. The tug's
`engine_flame_lod0.gltf` has, per engine, three cones:
`core` splay 2.0 tint (1,0.7,0.1); `flame` splay 0.5 tint (1,0.7,0.1);
`core` splay 0.5 tint (0.5,0.2,1.0) (a blue inner core).

## The texture

Bound once in the ctor at `0x100bd3d3` into a shared static
`sPolygonState @ 0x10171310` (texture slot `DAT_10171320`):

- URL `"texture:/images/sfx/plasma"` (`PTR_s_texture__images_sfx_plasma_101618c0`)
- extracted PNG: `data/textures/images/sfx/plasma.png` — a cloudy grey noise
  sheet, **no alpha** (density is the luminance, per the engine's particle
  convention, `flux.dll @ 0x1004ffd0`).

## Blend / z state

`sPolygonState @ 0x10171310` fields (`FUN_100bd2d0`):
`_314 = 2` → **blend mode 2 = SRCALPHA/ONE** (alpha-weighted additive);
the two zero bytes at `+0x1c/+0x1d` = z-write off. Godot equivalent:
`render_mode blend_add` + `TRANSPARENCY_ALPHA` (source scaled by alpha ==
SRCALPHA/ONE), `depth_draw_never`, `unshaded`, `cull_disabled`.

## Geometry (Draw @ 0x100bd630)

A **6-facet cone**: three static ring tables of 7 floats each are generated once
at startup by stepping the angle by `π/3` (`DAT_1011cbcc = 1.0472`):

- cos ring `@ 0x10171330` (`FUN_100bd220`, `fcos`)
- sin ring `@ 0x101713b0` (`FUN_100bd260`, `fsin`)
- axial/texcoord ring `@ 0x10171390` = 0, 1/6 … 1 (`FUN_100bd2a0`, step `0.166667`)

The Draw calls `FcGraphicsEngine::Begin(ePrimitiveType 5)` (`0x100bd6a8`), loops
7 rings emitting two `sVertexState` vertices each, then `End`. Ring radius =
`cos/sin * splay` (`fmul [ebx+0xbc]` at `0x100bd78c`/`0x100bd7a0`). Per-vertex
alpha grades from `v * globalalpha * 0.6` at one ring (`0x100bd6ff`, const `0.6`
`@ 0x101192c4`) to `1.0` at the other (`0x100bd7c6`).

(Tail at `0x100bd7ea`, gated by `0x10173b74`, does `FindWorldRadius` /
`FindWorldPosition` and accumulates the flame's screen coverage into a global
bloom/glare sum at `+0x37c` — not geometry; not reproduced.)

## The animation — this is the point

**Prepare `@ 0x100bd5f0`** runs every frame:

```
phase = phase - game_delta * 0.5        ; const 0.5 @ 0x1011cbc4
if phase < 0: phase += 1.0               ; const 1.0 @ 0x101171f0
```

so `phase` (at `+0xcc`) scrolls through `[0,1)` at **0.5 / second**. The Draw
feeds that phase as the axial texture coordinate (`[esi+0x1788] <- [ebx+0xcc]`
at `0x100bd711`), so the turbulent plasma **scrolls along the cone axis**. There
is **no `FcRandom`** in the Draw — the entire "fire" motion is this texture
scroll over the noise sheet. It moves even at a held throttle.

## How the channel drives it

`v = |FcChannelEvaluator::Evaluate(channel)|` (`0x100bd63e`, `fabs` at
`0x100bd655`). If `|v| < 1e-6` (`@ 0x101178fc`) the Draw early-outs → the plume
is invisible at idle. `v` scales the base-ring alpha (`v * 0.6`) and shifts the
texture window (`1 - v` term at `0x100bd6ae`), so as thrust rises the plume
brightens and fills. Length is a **separate** mechanism: the flame-cone node is
a child of an `<anim channel=flame>` null whose two poses key the z-scale from
`-10` to `-40` (tug `engine_flame_lod0.gltf`), so the same channel that lights
the cone also stretches it. Both read the tug's derived channels
(`tug_hull/channels.ini`): `flame = max(lz_smooth, burn_smooth)`,
`core = burn_smooth`.

## Reimplementation (`ship_effects.gd`)

`_add_flame_cone` now builds a `CylinderMesh` (radial_segments 6 = the 6 facets,
wide `top_radius = splay` at the nozzle tapering to a point) with a
`ShaderMaterial`:

- `render_mode blend_add, depth_draw_never, cull_disabled, unshaded` (= blend 2,
  z-write off)
- samples `plasma.png`; `UV.y - TIME*0.5` scrolls it down the axis (Prepare)
- a second decorrelated octave churns the noise so it licks instead of sliding
- `intensity` uniform = the node's own channel value (`flame`/`core`), driven
  each frame in `_physics_process` from the same `named` table the anim rig uses
- alpha grades bright at the nozzle → thin at the tip, gated by `intensity`
  (invisible at idle, matching the `1e-6` early-out).

The channel rig (`<anim>` pose interpolators + `channels.ini` expression
language) is untouched; the cones ride it for length exactly as before.

## Verification

`--flameshot` (a self-contained shot mode added to `ship_effects.gd`, gated on
the player tug) forces full burn, parks an external camera on the engine
centroid, and saves `data/screenshots/flameshot_0..7.png` 0.15 s apart. Because
the channel is pinned constant during the capture, the only per-frame change is
the shader's TIME scroll: consecutive frames differ (~4 % of plume pixels change,
max ΔRGB ≈ 200; all 8 PNGs have distinct md5s), and `data/screenshots/
flame_montage.png` shows one plume across three frames with the hot core/streaks
visibly shifting. Boot clean, `--mechcheck` 29/29 ALL PASS, `--campcheck` PASS.

## Still UNKNOWN / not reproduced

- The exact per-vertex position math of the two-vertex-per-ring strip (inner vs
  outer radius) was not fully traced; the Godot cone is a faithful hexagonal
  cone rather than a bit-exact vertex copy.
- The bloom/glare accumulation (`+0x37c`) the Draw contributes to is not wired.
- The `1 - v` texture-window shift is approximated by the alpha/intensity gate
  rather than an exact V-offset.

## For original.md

`element_markers.gd:142` currently reads:

```
# @element-stub icFlameConeAvatar -- covered-elsewhere: ship_effects.gd additive cone meshes on the channel rig
```

That "covered-elsewhere" was false (untextured constant cone). It is now
genuinely implemented. Suggested replacement:

```
# @element icFlameConeAvatar -- ship_effects.gd::_add_flame_cone: 6-facet cone, plasma texture (iwar2 ctor @0x100bd3d3), SRCALPHA/ONE additive, TIME-scrolled axial UV (Prepare @0x100bd5f0, 0.5/s), channel-driven intensity (Draw @0x100bd630). See docs/thrusters.md.
```
