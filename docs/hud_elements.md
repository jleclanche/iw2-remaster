# The original IW2 HUD, recovered from the binary

Everything below is read out of `bin/release/iwar2.dll` (via `data/decomp/iwar2.dll.c`
and `tools/ghidra/readconst.py`) or out of the shipped data files. Anything I could
**not** determine is called out explicitly in "Not recovered" at the bottom — those
places keep whatever `game/scripts/hud.gd` already had.

## How to find a HUD class

The `icHUD*` classes export no symbols. Go through the class registry:

1. grep the class-name string, e.g. `PTR_s_icHUDReticle_10163904`. It appears in a
   `FcRegistry::RegisterClass(this, name, base, factory, propmap)` call.
2. The factory does `operator_new(size)` then calls the constructor.
3. The constructor sets the vtable: `*(undefined ***)param_1 = &PTR_LAB_1011e070;`.
4. The vtable is *data*, so it is not in the decompiled C. Read it out of the PE.

| class | registration | factory | ctor | size | vtable |
|---|---|---|---|---|---|
| icHUDReticle | `FUN_100f5970` | `FUN_100f59b0` | `FUN_100f5a90` | 0x3ec | `0x1011e070` |
| icHUDContactList | line 178010 | `FUN_100e4290` | `FUN_100e4330` | 0x68 | |
| icHUDBrackets | line 177584 | | | | |

Reticle draw chain: `FUN_100f6340` (master) calls `FUN_100f73d0` (hull arc),
`FUN_100f6c80`, `FUN_100f76a0` / `FUN_100f7920` + `FUN_100f7b10` (in- vs off-reticle
target marker), `FUN_100f7e10` (the target text block) and `FUN_100f8410` (the status
icon ring, which draws each icon via `FUN_100f8da0`).

## Coordinates: absolute pixels, no scaling

The HUD is laid out in **raw pixels** and does not scale with resolution. Confirmed
against the reference screenshot: it is a 1280x800 render upscaled 1.4984x, and

- reticle ring: measured 95px / 1.4984 = **63.4** vs. the binary's **63**
- status-icon ring: measured 166px / 1.4984 = **110.8** vs. the binary's **110**

Those two independent measurements agree to within 1%, so the numbers below are
literal pixel values.

## Sprites — the whole atlas, recovered

The HUD draws almost everything as textured quads, not vectors:
`FUN_100e9de0(x, y, sprite_id, flags, rotation)`. `sprite_id` indexes a table at
`DAT_101741b0`, stride 0x24 = `{w, h, origin_x, origin_y, u0, v0, u1, v1, texture}`.

That table is in **BSS** (`.data` is raw-backed only to `0x10165000`), so it reads as
garbage from the PE — which is why an earlier pass called it unrecoverable. It is not:
the **builder** is at `0x100e6c60`..`0x100e7f90` (undisassembled by Ghidra), and it
fills every entry with one call to
`FUN_100ee6b0(atlas_x, atlas_y, w, h, origin_x, origin_y, texture)` followed by a
`rep movsd` into the entry. All **95 sprites (0..94)** come straight out of it.
See `docs/original.md` §8c; the cells the HUD uses are in `hud.gd`'s `SPR`/`SPR_RET`.

Textures (pointer list at `0x10162c9c`): 0 = `images/hud/sprites`, 1 = `.../lcd`,
2 = `.../reticle`, 3 = `.../tri`.

Note the decompiler prints small integer sprite ids as denormal floats — `1.26117e-43`
is the float whose *bit pattern* is 90, i.e. sprite **90**.

## Palette

Colours are three consecutive float globals written by tiny static initialisers, so
they read as garbage from the file — you have to grep for `DAT_xxxxxxxx = 0x3f800000;`
and reinterpret the hex as IEEE-754 bits.

| DAT | RGB | used for |
|---|---|---|
| `DAT_10176038` | (0.5, 1.0, 0.0) | HUD chrome / green |
| `DAT_10174fb0` | (1.0, 0.592, 0.0) | reticle status icons (amber) |
| `DAT_10176018` | (1.0, 0.07, 0.0) | hostile / alert (red) |
| `DAT_10174f60` | (1.0, 0.8, 0.0) | healthy end of the damage ramp |
| `DAT_10164e58` | (1.0, 0.749, 0.0) | neutral |
| `DAT_101713d0` | (1.0, 1.0, 0.0) | yellow |
| `DAT_101715e8` | (0.9, 0.43, 0.0) | orange |
| `DAT_101740b8` | (0.1, 0.1, 1.0) | blue |
| `DAT_10174190` | (0.3, 0.6, 1.0) | friendly (light blue) |
| `DAT_10174180` | (0.9, 0.1, 1.0) | magenta |
| `DAT_10174010` | (0.9, 0.95, 1.0) | near-white (cargo / inert) |

### Damage colour ramp — `FUN_100e88c0(out, frac)`

Breakpoints are **0.75** (`_DAT_10117d8c`) and **0.25** (`_DAT_101191ec`):

- `frac > 0.75` — LERP toward `DAT_10174f60` (1.0, 0.8, 0.0)
- `0.25 < frac <= 0.75` — LERP toward `DAT_10176018` red
- `frac <= 0.25` — flat red

The LERP's *other* operand and blend factor were lost by the decompiler (they live on
the x87 stack), so the exact interpolation is not recoverable. We use the thresholds and
endpoint colours the ramp names and interpolate linearly.

## icHUDReticle

Geometry, all absolute pixels:

| value | const | meaning |
|---|---|---|
| 63 | `_DAT_1011e038` | reticle ring radius |
| +10 | `_DAT_101190c0` | a target within 63+10 = 73px of centre counts as "in reticle"; beyond that the off-reticle indicator is drawn instead |
| 80 | `_DAT_1011e034` | base radius of the status-icon ring |
| 110 | 80 + `_DAT_1011e040` (30) | the status-icon ring |
| 150 | 80 + `_DAT_1011e044` (70) | the four mutually-exclusive *mode* icons |
| 24 | `_DAT_1011e0bc` | charge pips ringing an icon |
| 18 | `_DAT_101190bc` | pip ring radius |
| 82 | 80 + `_DAT_10119ec8` (2) | x of the target text block / its hull bar |
| +9 | `_DAT_101190b8` | gap from that bar to the text |
| 0.65 | `_DAT_10119b40` | alpha of the hull arc |

### The status-icon ring

The constructor (`FUN_100f5a90`) builds 15 icons via
`FUN_100f93c0(out, angle, radius_delta, sprite_id, colour, flags)`, which stores

```
+0x00 sprite id     +0x04 angle = arg * PI      +0x08 radius = 80 + radius_delta
+0x0c x = floor(sin(angle) * radius)            +0x10 y = floor(-cos(angle) * radius)
+0x14 visible       +0x18..0x20 FcColour        +0x24 flags   +0x28 charge 0..1
```

The angle argument is in **half-turns**, and angles run **clockwise from twelve
o'clock**.

**The sixth argument is a flag word, not a size.** An earlier pass read the `9` /
`0xb` / `0xd` as pixel sizes; `FUN_100ea2b0` shows they are bits:
`bit0|bit3` → the backing roundel (sprite 53, ring + disc), `bit1` → a wedge
(sprite 50) spinning at 1 rev/s, `bit2` → a 2 s alpha pulse. Glyphs are always drawn
at their **native atlas size**. So every status icon is a 32x32 roundel with a 32x32
glyph on it — that is the "disc" in the reference shot.

The slots (full table, with the atlas cells, in `docs/original.md` §8c):

- **-22.5, -33.75, -45, -56.25** at r=150 — the four mode icons (sprites 0x15-0x18),
  flags 11. `FUN_100f8410` makes at most one visible, indexed through
  `DAT_1011e04c = [-1, 1, 0, 3, 2]` by `icPlayerPilot+0x308`.
- **-22.5** at r=110 — the **LDS drive**: sprite 0x19 while warming up (flags 13,
  charge = warm-up progress) or running (flags 11), and sprite **0x1A = "!"** when
  inhibited or LDSi-disrupted (flags 13, charge = how deep in the field). Colour is
  `DAT_10176038` **green** in every case — the draw never changes it.
- **+22.5** at r=110 — sprite 0x1e, the capsule drive / L-point jump; within 50 km of a
  targeted L-point it also writes the destination's name at (+24, -line).
- **-67.5** at r=110 — sprite 0x1b when a non-turret component is down.
  **RESOLVED** otherwise (autopilot off only): `ship+0x270` is the `iiPilot`
  (`icShip::Pilot`), vfunc +0x40 is `Yoke()` (`0x100af8c0`, the `sYoke` at
  pilot+0x30). Sprite **0x1D** while a lateral thruster input is held
  (yoke+0x0c/+0x10, `HandleLinearMessage` msgs 5/6 = LateralX/Y); sprite
  **0x1C** in free flight (yoke+0x1c = 1, set by FreeHold/FreeToggle in
  `HandleButtonMessage`) with no strafe. So it is the **manoeuvring-state**
  icon: side-arrows = strafing, circular arrow = assist off.
- **+67.5** at r=110 — sprite 0x4e, incoming missile, **red**; one pip per missile.
- **180, 157.5, 135** at r=110 — sprites 0x3e / 0x3f / 0x40 (thermometer / lightning /
  bulb). Each is a `{value, flag}` pair at **`icHUD+0xe8`** (stride 8 — NOT on
  icPlayerPilot as previously written); it appears when the value changes, holds 2 s
  (`DAT_1011e03c`), and goes red + flags 13 when flagged. **The writer is
  `FUN_100e07f0`** (the icHUD player feed): thermometer =
  `(ship+0x288 + ship+0x28c) * 0.75 / icShip::m_heat_damage_threshold` (red at
  >= 0.75, i.e. heat at the damage threshold); lightning = **reactor charge**
  (`ship+0x2a0` is the first `icReactor` subsim; `+0x7c / +0x98`, red below
  0.25); bulb = **`icShip::Brightness()`** (`0x10075420`, the ship's
  visible/EM signature, red above 0.75).
  **Both are now drawn** (`hud.gd`), and both names were misleading:
  * The lightning gauge stores **nothing**. `icReactor::Simulate` (`0x1003a2a0`)
    writes `+0x98` = the *rated* output and `+0x7c` = `efficiency * output *
    ramp`, so the ratio is `efficiency * ramp` -- it settles at the reactor's
    efficiency (1.0 when healthy) and only falls when the reactor is damaged,
    overheated, or throttled down by the player. The HUD feed defaults it to
    **1.0**, not 0, when no reactor is fitted.
  * The bulb gauge is **not** "idle brightness lerped by ThrusterRatio plus LDS
    and weapon-capacitor terms". `icShip::ThrusterRatio` (`0x10075600`) is a
    **stub returning 0.0**, so that lerp is dead; the real terms are
    `min_brightness` scaled by reactor output, plus heat, the sensor disruptor,
    the active sensor, and the CPU's stealth program. Full formula in
    `docs/combat.md`.
- **202.5** at r=110 — sprites 0x56, 0x57 (multiplayer team markers)
- **225** at r=110 — sprites 0x58, 0x59 (multiplayer flag / bomb)

Each icon can carry a charge ring: `FUN_100f8da0` lights `floor(charge * 24)` pips
(sprite 20) on a circle of radius 18, clockwise from twelve, and fades the next one by
the remainder (skipped below 0.05).

### The target text block — `FUN_100f7e10`

At x = 82 to the right of centre: a **vertical segmented bar** showing the target's
hull (coloured by the damage ramp), spanning two text lines. Then at x = 82+9 = 91:

```
<hull%> <NAME>
<range>
<speed>m/s          (omitted when the target is not moving)
```

with `LDS` appended when the target is in linear drive (`hud_lds`).

### Range formatting — `FUN_100f81a0`

- `< 1000 m` — metres
- `1000 m .. 1e6 m` — `"%.1fkm"` (this is the "7.1km" in the reference shot)
- `>= 1e6 m` — kilometres, `"%.0f"`, then commas inserted every three digits, then `km`

Speed: the value is formatted, then `"m/s"` is appended if it ends in `k`, else `"/s"`
(`DAT_10163928` / `DAT_10163924`).

## Contact colour — `FUN_100e8530`

One function decides a contact's colour; the brackets, the contact list and the orb all
just copy what it wrote into the contact record.

| state | colour |
|---|---|
| unidentified | `DAT_10174f60` (1.0, 0.8, 0.0) gold |
| waypoint or L-point (sim type 4 / 5) | `DAT_10176038` (0.5, 1.0, 0.0) chartreuse |
| `sim+0x199` set (meaning unknown) | `DAT_10174190` (0.3, 0.6, 1.0) light blue |
| otherwise | IFF table at `0x10174f70`, stride 12 |

IFF table: **0, 1 -> red** `DAT_10176018`; **2 (the default a contact is constructed
with) -> gold** `DAT_10174f60`; **3, 4 -> blue** `DAT_101740b8` (0.1, 0.1, 1.0).

So neutral is **gold**, not the yellow we had, and blue is reserved for friendlies.

## icHUDBrackets

Draw = `FUN_100e37f0`. It draws **no geometry** — every mark is a sprite quad, and it
picks **no colours** (it copies the contact's). Contact records live at `hud+0x194`,
stride 0x5c.

Untargeted, on-screen contacts:

| condition | mark |
|---|---|
| unidentified | one sprite (49) |
| type 4 (waypoint) | one sprite (47) |
| type 5 (L-point) | one sprite (60) |
| anything else | **four corner brackets** (sprite 4, mirrored into each corner) at the contact's **projected bounding box** |

The bbox is floored, and if it is narrower than **2px** (`_DAT_10119ec8`) both edges
collapse to the centre. There is no distance-based scaling beyond the projection itself.

The **current target** gets the same four-corner treatment with sprite 1, and on
acquisition plays a **slam-in**: an extra bracket (sprite 2) offset outward by
`(1 - t) * 70` px (`DAT_1011d9e0`) with alpha `t`, over `t = elapsed / 0.35`
(`DAT_1011d9dc` = **0.35 s**). Waypoints and L-points get no target bracket.

Two `icPlayerLDA` markers (max 2) can hang above/below a contact at +/-17px on contacts
and +/-19px on the target (`_DAT_1011da18` / `_DAT_1011da14`), sprites 38/39.

## icHUDContactList

Draw = `FUN_100e4440`. **Six rows** (`this+0x3c` scroll offset, `this+0x38` selection);
it scrolls to keep the selected contact in view and draws a scrollbar (alpha 0.3,
`_DAT_1011c034`) only once there are more than six contacts. Row height **16px**
(`DAT_1011d970`). Sorted by **range ascending** (`icPlayerContactList::CompareByRange`).

The row is a **monospace character grid**, not pixel columns. The two format strings:

```
"%-5s %-5s %-5s %-12.12s%c"     normal row   (0x10162b70)
"%-5s %-5s %-5s             %c" selected row (0x10162b50)
```

i.e. **FACTION, TYPE, RANGE, NAME**, and a trailing char that is `'>'` when the name was
longer than 12 and `' '` otherwise. On the **selected** row the name is omitted from the
format and drawn instead by a separate scrolling-text child, so a long target name
*scrolls* rather than being cut.

- **TYPE** is a fixed **5-character, space-padded** abbreviation. `hud.csv` says so in
  as many words ("5 character limit on these abbreviations") and pads them itself:
  `"UTIL "`, `"TUG  "`, `"MINE "`, `"STAR "` vs. `"TRANS"`, `"LAGPT"`, `"WAYPT"`,
  `"CARGO"`. This is why the reference shot has two spaces after `UTIL` and one after
  `TRANS`.
- **FACTION** is the 5-character third column of `faction_names.csv` (`INDPT`, `STPSN`,
  `SOLAN`, ...). It is **blank** for anything with no owner — every `LAGPT` / `VAYPT` /
  `CARGO` row in the reference shot has an empty faction column.
- The list is drawn in the **monospace** font (OCR-B). That is what lines the columns up
  and what makes the original read tighter than a proportional font.
- **There is no highlight box on the selected row.** It differs only by a text-draw mode
  flag (likely inverse/brighter video) and the scrolling name.

### Range — `FUN_100e8730`, and note it is NOT the reticle's formatter

The reference shot shows `7103m` in the list and `7.1km` in the reticle *for the same
contact* (SEA QUEEN).

| range | output |
|---|---|
| `>= FLT_MAX` (set when the contact is in another system) | `"O/SYS"` |
| `< 10 000` | `"%dm"` |
| `10 000 .. 100 000` | `"%d.%dk"` |
| `100 000 .. 1e7` | `"%dk"` |
| `>= 1e7` | `"%dE%dk"`, exponent clamped to 99 |

## Block layout — `iiHUDBlockElement`

Blocks are laid out in **absolute pixels** after `FcGraphicsEngine::SetPixelCamera()`.
Constants: screen margin **6** (`DAT_1011d80c`), border **4** (`DAT_1011d96c`, applied
as 2x4 = 8), inter-block gap **3** (`DAT_1011d810`), header row **16**
(`DAT_1011d970`). Block sizes are rounded up to the 16px grid. Blocks stack in the four
screen corners, so the vertical advance between them is **h + 11**.

The ctor's second arg is the anchor mode: `icHUDTargetMFD` = 0, `icHUDWeapons` = 0,
`icHUDShields` = 1, `icHUDClock` = 1. Mode 0/2 get the +8px x-shift, so **0 is
left-anchored and 1 is right-anchored** — which matches the reference shot.

### Segmented bars — `FUN_100ebde0(x, y, length, frac, style, endcap)`

Style table at `0x10162e00`, stride 0x14. **Both the weapon charge bar and the shield
bar use style 1** (5px pitch, sprite 10 full / 9 partial) **with length 74**, giving
`floor(74/5) = ` **14 segments**. The segment straddling the fill boundary is drawn with
alpha equal to the remainder, so the bar fades rather than snapping.

## icHUDTargetMFD — fully recovered

The master Draw is **`0x10101730`** — missing from the decompiled C because it
dispatches through a jumptable at `0x10101b20`; recovered from raw bytes. The
element is a six-mode machine (`this+0x34`), and the mode decides the block
size, the caption, the icon/model and the overlay effect. Mode select is
`FUN_10102930`; captions are 18 `hud.csv` keys loaded from the table at
`0x10163bd0`.

| mode | set by | caption | block | body |
|---|---|---|---|---|
| 0 | no target (`FUN_10102d30`) | `hud_target_no_target` | 128x**48** | nothing (`FUN_100bb300` is a literal no-op) |
| 1 | unidentified (`FUN_10102db0`) | `hud_target_unknown_target` | 128x48 | class icon 0x31 ("?") |
| 2 | ship target (`FUN_10102e30`) | `hud_target_target_mode` | 128x176 | 3D model + hull bars (`FUN_10101c80`) |
| 3 | waypoint / L-point / icon-class sim (`FUN_10102f70`) | `hud_target_waypoint_mode` | 128x48 | class icon; line 2 = `hud_target_waypoint_details` |
| 4 | cargo pod, category 0xc (`FUN_10102a40`) | `hud_target_ucp_scan_mode` = **"UCP SCAN"** | 128x176 | pod + contents + **barcode bands** (`FUN_10101f00`) |
| 5 | comms (`FUN_10102fd0`) | `hud_target_comm_channel_open` | 128x176 | portrait + **static + scan band** (`FUN_10102490`) |

Shared behaviour (the master Draw):

- **Block sizes**: `FUN_10103e00` restores 128x176 (`DAT_1011e238/23c`);
  `FUN_10103d80` shrinks to 128x**48** (`DAT_1011e240`) for modes 0/1/3.
- **1-second fade-in**: on any mode change `this+0xb0` resets to 0 and ramps at
  `dt / 1.0` (`0x1011e24c`); while < 1 it *is* the master alpha for the whole
  block. Mode 5 skips it (`FUN_10102fd0` writes 1.0 directly).
- Caption at (3,3) (the two `0x40400000` pushes), chartreuse.
- **Text lines** (amber `DAT_10174fb0`): line 1 at `y = h - 4 - 2*line_height
  - 3`, line 2 at `y = h - 4 - line_height + 2` (`_DAT_1011e244` = 4,
  `0x10162c6c` = the runtime line height, `0x10118490` = 3, `0x10119ec8` = 2).
  X-indent **32** (2 x `DAT_1011d970`) in modes 2/3, **0** in modes 4/5.
- **Class icon** (short modes only — the draw literally tests `height == 48`):
  sprite `this+0xdc` at **(16, 32)**, coloured by the contact record's colour,
  then an overlay (icon 0x2f/0x3c -> sprite **0x2e**, icon 0x31 -> **0x30**),
  then roundel **0x33** on top. The icon comes from `FUN_100e86d0`: category
  table `DAT_1011db64` (1 -> 54, 3/4 -> 47, 5 -> **60** the L-point, 0xb -> 58),
  ship-type table `DAT_1011dbe4` (54/55/57/56/58/56 for types 1..6).

### The 3D model render (`FUN_10103060`) — what sits over it

The model is rendered **into a viewport inside the block** (SetViewport) through
a dedicated director camera (**23** for the target, **22** for comms), with a
**global override shader** (`m_p_global_shader = this+0xd4`): an `FiShader`
built in the ctor (`0x10101530`) with one `cLayer(1)` whose **tint is set to
the contact's own colour** (layer+0x18 = the FcColour passed in) and opacity
0.99 (`0x3f7d70a4`). It is drawn **twice** — once solid, once with engine
`+0x17a8 = 2` — and `2` is **proven wireframe**: `+0x17a8` is
`FcGraphicsEngine::eRenderFill` (`SetRenderFillStyle @ flux 0x100141f0`),
dispatched through device vtable `+0xfc/+0x100/+0x104` which set D3D
renderstate 8 (FILLMODE) to POINT(1)/SOLID(3)/WIREFRAME(2)
(`dx7graph 0x10008bb0/0x10008bd0/0x10008bf0`). The solid-dark-plus-wireframe
look. Lighting: one white directional light; while the contact is
unidentified (flag 0x200 on `sim+0x128`) the light is full white, and when the
flag clears `this+0xd8` ramps 0.3 -> 0 (`DAT_1011e250`) making an
**identification flash**: light = white x (2t + 0.8).

Over the model, mode 2 draws the **target-designator lines** (the "effect on
top of the model"): `this+0xb4` starts at 1 on a target change and decays at
**1.5/s** (`_DAT_1011a268`); two vertical and two horizontal chartreuse lines
sweep in from the body edges (x 0/128, y 16/144) toward the **targeted
subsystem's projected position** — or the fixed anchor (64, 96)
(`16*_DAT_101190b4`, `16*_DAT_101183f0 + 16`) when none — with each line's far
end faded to alpha **0.25** (`_DAT_101191ec`). With a subsystem targeted they
lock on (parameter clamps at 0) and sprite **3** marks the subsystem; without
one the parameter continues to -1 (`_DAT_10119ae0`) so the lines sweep back
out and vanish. That is the acquisition animation.

### The hull bars (`FUN_10101c80`) — the "small segmented bar" identified

It **is** the shared segmented-bar routine after all: `FUN_100ebde0(x=1,
y=16*9.5=152, length=2*16-3=29, frac, style 1, 0)` — 5 segments at the 5px
pitch — coloured by the damage ramp `FUN_100e88c0`. With a targeted subsystem
the y=152 bar shows the **subsystem's** health (`+0x54/+0x58` or
`+0x1ac/+0x1b0`) and the hull moves to a second bar at y = 16*10.5 = **168**
(`_DAT_1011e280`); with none, y=152 shows the hull.

### Mode 4 — the UCP barcode

The ctor loads `texture:/images/hud/ucp` (a 256x32 barcode strip: digits in
the top half, bars in the bottom) into `this+0xc0`. `FUN_10101f00` renders the
**pod ghosted** (layer alpha 0.5 for the solid pass) with its **contents**
drawn inside, flashes `hud_target_trade_item` when the cargo is recognised
(`this+0xac`), and scrolls two 16px bands across the body top: the bar half
(v 0.5..1) at y 16..32 with `u = -phase/2 .. 0.5 - phase/2`, and the digit
half (v 0..0.5) at y 32..48 with `u = phase .. 0.5 + phase`; `phase` advances
at **0.2/s** (`_DAT_1011e248`). Chartreuse, alpha 0.25. The two bands
counter-scroll.

### Mode 5 — the comms monitor (the "effect over the speaker")

`FUN_10102490`: a **solid black quad** backs the body (x 0..128, y 16..144),
then either `icComms::RenderPortrait` (FMV feed, `icComms+0x138`) or the
speaking sim's 3D model (white tint, camera 22). On top:

- **Interference static** (`FUN_100ec850`): one horizontal line every **2px**
  over x 2..127, y 19..143, each line's brightness pulled from a **1024-float
  noise table** (`DAT_1017500c`, filled once at HUD init with
  `(1-r)*0.75 + r`, r uniform — so 0.75..1.0), starting at a random index
  every frame. Colour chartreuse x **0.4** (`_DAT_10117558`); the overall
  strength flickers per frame: `(1-r)*0.1 + r*0.3` over video,
  `(1-r)*0.3 + r*0.7` over a 3D feed, pegged 1.0 while the sim is
  unidentified.
- **The scan band**: a 4px-tall (`_DAT_101190b4`) quad, chartreuse x 0.3
  (`_DAT_1011c034`), alpha 0 at its top edge to full at its bottom, sweeping
  down the portrait every **3 s** (`frac(game_ms / 3000)`,
  `_DAT_10118498 = 1/3000`).

Line 1 is the speaker's name (`icComms+0x50`, uppercased); line 2 is
`hud_target_receiving_video` / `hud_target_no_video_feed`.

Text is revealed with a typewriter effect at **30 chars/sec** (`DAT_1011dc0c`)
— the scroll-text child elements at +0x38/+0x64/+0x88 were not reversed
further.

## icHUDWeapons

**112 wide** (`DAT_1011e2f8`), height `32 * rows + 16` (`DAT_1011e2fc` row pitch),
left-anchored, below the MFD. The header is the **weapon's own localised name**,
uppercased — not a `hud.csv` key. Rows = the number of `iiWeapon` members of the
selected weapon group.

Each energy row (`FUN_101053e0`), all in **amber**: a lightning sprite (69) at x=16,
y=row+16; the 14-segment charge bar at x=36, y=row+10; and a **`"%d%%"`** readout.

## icHUDShields

**112 x (32 * bars + 16)**, right-anchored. Header = `hud_shield_status` ->
**"SHIELD STATUS"**. Rows in **amber**: bar at x=2, y=row+10 (14 segments, length 74);
lightning sprite (69) at x=96, y=row+16; status text at x=76, y=row+17 reading
**"TRACKING"** (`hud_tracking`) above 20% charge (`DAT_101607e0`) or **"OFFLINE"** below.
A broken row flashes at 2 Hz and reads "OFFLINE" / "DESTROYED".

The two bars are **not** fore/aft and **not** shield+LDA: the draw enumerates the ship's
components, keeps those of one class, **caps the list at 2**, and sorts the pair by an
orientation-derived value — so the ordering *emerges* from where the components sit.
`hud_lda_status` is **not** referenced by this class at all.

## icHUDClock

Right-anchored, below the shields. Time is game time in **centiseconds**; hours wrap at
100. Format **`"%02d:%02d:%02d.%02d"`** (`0x10162b24`) — hh:mm:ss.cc, matching the
reference shot's `00:06:07.26`. Drawn right-aligned **2px inside the block's right
edge**, at y=2, in **chartreuse** (`DAT_10176038`) — **not** amber/orange.

## Config — `flux.ini`

```
[icHUD]         use_thick_lines=1  flash_delay=6  flash_frequency=3  menu_timeout=30
[icHUDMessage]  message_delay=5  prompt_delay=10
                new_message_flash_frequency=0.333333  caution_flash_frequency=1
[icHUDOrbRadar] use_thick_stalks=1
[FcConsole]     font_url = font:/fonts/ocrb_8pt
```

`[icHUD] elements[0..21]` also gives the **draw order**: ReferenceGrid, LagrangeIcon,
WaypointIcon, Brackets, Contrails, TargetMFD, Weapons, OrbRadar, Shields, Clock,
ContactList, Reticle, MenuReticle, Debug, Message, ShipStatus, EditBoxElement, Starmap,
Engineering, Log, Objectives, Score.

## Not recovered from the binary

These keep the values `hud.gd` already had, and are **guesses, not facts**:

- ~~Which sprite glyph goes in which status-icon slot.~~ **SOLVED** — the table's
  builder is in `.text` even though the table is in BSS. All 95 sprites and every slot's
  glyph are recovered; see above and `docs/original.md` §8c. The text labels are gone.
- **The damage ramp's LERP operands** (see above) — thresholds are real, interpolation
  is ours.
- ~~The exact tick-mark pattern on the reticle ring.~~ **RESOLVED**: the engine
  never scales sprites — `icHUDReticle::Draw` (`0x100f60c0`, raw bytes) builds
  a translate-only matrix to the screen centre and `FUN_100e9de0` blits cells
  1:1 — so sprite 90 (170x170, origin 84,84) IS the on-screen ring, drawn
  native and tinted chartreuse. The art's circle stroke sits at r ~72.5 with
  ticks to ~79; `_DAT_1011e038 = 63` is the *layout* radius (the in-reticle
  test `(63+10)^2` and the gauge ring), not the drawn circle. `hud.gd` now
  draws the sprite itself.
- **Font metrics.** `DAT_10162c68` (char width) and `DAT_10162c6c` (line height) are
  measured at runtime from the loaded font and are zero in the file. Several positions
  are expressed in terms of them, so these are **not** recoverable statically:
  - the **clock block's** pixel width and height,
  - the **MFD's two text-line Y positions** (the *formula* is now recovered —
    `h - 4 - 2*lh - 3` and `h - 4 - lh + 2` — but `lh` is the runtime metric),
  - the **contact list block's width** (`DAT_10173f48`, a width in characters, is never
    assigned anywhere in the decompilation).

  We use our own font's metrics for all of these.
- **Which screen corner each block registers into.** Left/right is established (the
  anchor-mode ctor arg); top/bottom is not — it is inferred from the reference shot.
- ~~The MFD's small segmented bar~~ **RESOLVED** — it *is* the shared bar
  routine after all: the calls live in `FUN_10101c80`, which is reached only
  through the mode jumptable in the undisassembled master Draw (`0x10101730`),
  which is why the earlier pass could not find a caller. `FUN_100ebde0(1, 152,
  29, hull_frac, 1, 0)`, damage-ramp coloured; see the icHUDTargetMFD section.
- **The text primitive's alignment argument** (`FUN_100eb270` args a2/a6/a7). The
  function clearly does half-width/half-height centring, but which argument selects it
  was not pinned down — so we cannot prove how the weapons "100%" readout is aligned
  despite being passed the same X as the bar.
- **What the shield bars actually measure** — the component class they filter on
  (`DAT_10167e5c`) was not resolved. **We draw no shields panel at all**, because our
  sim has no shield components and inventing one would be fabrication.
- **Contact-list max rows and sort order** are now real (6 rows, range ascending), but
  our list still comes from `main.contact_list()`, which caps at 12 before we see it.


---

## Element coverage

`python -m tools.iw2.featurecov --base iiHUD` diffs the engine's own class registry
against what we have built. Every concrete `icHUD*` element is now either implemented
or explicitly stubbed with a reason, via `# @element` / `# @element-stub` markers next
to the code:

| built | where |
|---|---|
| icHUDReticle, icHUDMenuReticle, icHUDShipStatus, icHUDMessage | `hud.gd` |
| icHUDTargetMFD, icHUDWeapons, icHUDOrbRadar, icHUDClock, icHUDContactList | `hud.gd` |
| icHUDBrackets | `hud.gd` |
| icHUDEngineering, icHUDStarmap, icHUDLog, icHUDObjectives | `hud_screens.gd` |
| icHUDLagrangeIcon, icHUDWaypointIcon, icHUDReferenceGrid | `space_fx.gd` |

| stubbed | why |
|---|---|
| icHUDShields | the component class its draw filters on (`DAT_10167e5c`) is unresolved and our sim mounts no shield components |
| icHUDScore | no statistics are tracked anywhere in our sim |
| icHUDContrails | its Draw was not reversed; the trail geometry would be a guess |
| icHUDDebug | the developer overlay; deliberately not built |
| icHUDEditBoxElement | no campaign script ever calls `ihud.GiveEditBoxControl` |

## icHUDShields and icHUDContrails (task #51)

The last two HUD elements. Both are now built.

### icHUDShields -- Draw `0x100fa540`

Registered `0x100fa350` (base `iiHUDBlockElement`), factory `0x100fa390`
(`operator_new(0x60)`), ctor `0x100fa470`, vtable `0x1011e114`, Draw at slot 9.

**The component class it filters on -- `DAT_10167e5c`, the open question in the
old notes -- is `icPlayerLDA`** (registered `0x100ac7a0`). So the shields panel is
the **LDA panel**, and it caps at **two rows** (`cmp esi,2` @ `0x100fa596`).
`icAILDA` is a sibling under `iiLDA`, not a subclass, so an AI shield never
appears here.

* Block: right-anchored (ctor passes 1 to the block base), **112** wide
  (`_DAT_1011e10c`), **16** px header (`DAT_1011d970`) + **32** px per row
  (`_DAT_1011e110`). With **no** LDA fitted the block height is set to **0** and
  the panel disappears entirely.
* Header: `hud_shield_status` = "SHIELD STATUS".
* Fill fraction = `icPlayerLDA +0xa4 / +0x94` (charge / capacity, verified as
  floats at `0x100fa9ca`). Bar: 14 segments, length `112 - 38 = 74`.
* Lightning sprite (69) at `x = 112 - 16 = 96`; status word at `x = 112 - 36 = 76`.
* Status word, working row: **"OFFLINE"** below `min_energy * capacity`
  (`min_energy` is the class static **0.2** @ `0x101607e0`, i.e. flux.ini
  `[icPlayerLDA] min_energy`); **"TRACKING"** when charged *and* `icPlayerLDA
  +0xa0` is non-zero; nothing when charged and +0xa0 is zero.
* Broken row: **flashes at 2 Hz** (`frac(t_ms * 0.001)` vs 0.5 -- `0x10119458` /
  `0x10117738`) and reads **"DESTROYED"** (sprite 31) or **"OFFLINE"** (sprites
  63/65), selected by the subsim's flag bits at +0x68.
* Row order: the two LDAs' forward axes sorted by **Y ascending** (`0x100fa75f`)
  -- the down-facing one first. Every shipped hull mounts them at
  `upper_lda`/`lower_lda` (or `shield_upper`/`shield_lower`) nulls, so we sort on
  the mount-null Y, which gives the same order.

**UNKNOWN:** what writes `icPlayerLDA +0xa0` (the "TRACKING" gate), and the
meanings of the +0x68 bits beyond "bit0 -> DESTROYED". We draw the
charged-and-+0xa0-zero case (bar, no word) rather than invent the gate.

### icHUDContrails -- Update `0x100e4c80`, Draw `0x100e4e60`

Registered `0x100e4ad0` (base `iiHUDUnderlayElement` -- it draws in the *world*,
under the 2D HUD, like the reference grid), factory `0x100e4b10`
(`operator_new(0x1708)`), ctor `0x100e4ba0`, vtable `0x1011daa8`. **Ghidra dropped
both Update and Draw**; recovered from raw bytes.

The 0x1708 decodes exactly: **8 trails x 16 points x 44 bytes**, plus a 0x28-byte
header (`0x28 + 8 * 0x2dc = 0x1708`).

* **Who gets one** (`FUN_100e5390`): a contact that is a ship, is moving faster
  than **50 m/s** (`_DAT_1011da98`), and is within **50 km** (`_DAT_1011daa0`) --
  raised to **150 km** (`_DAT_1011da9c`) while that ship's own LDS drive is
  engaged. Eight at most. The player's own ship always takes the first slot
  (`icHUD+0x104`).
* **Emission** (`FUN_100e5440`): ONE global countdown, reloaded to **0.4 s**
  (`_DAT_1011da8c`). It is **not** distance-based -- every trail drops a point at
  the same instant, 2.5 times a second. The 16-point ring therefore spans exactly
  `16 * 0.4 = 6.4 s`.
* **Fade**: a point's life starts at **0.7** (`_DAT_1011daa4`) and decays at
  **0.109375/s** -- a constant the engine *derives* at `0x100e4b80` as
  `0.7 / (0.4 * 16)`, so it reaches zero exactly as the ring wraps. `life` is used
  as **both the alpha and the line width**.
* **Disappearance**: when a trail stops qualifying it gets a **2 s** grace fade
  (`_DAT_1011da94`) -- every alpha scaled by `1 - timer/2` -- before its slot is
  freed. If it re-qualifies the fade cancels.
* **The player's trail is a LADDER** (`FUN_100e5520`): two rails offset by
  `+/- halfspan` along the **sim's local X axis at the moment each point was
  emitted**, plus a **rung** across every point. `halfspan = icShip::width
  (+0x208, the ship INI's `width`) * 0.5`, scaled in over a **0.35 s** splay ramp
  (`_DAT_1011da90`) each time the element is shown -- so the trail opens out from
  the centreline. The **rails are skipped** on points whose LDS flag is set (the
  flag is `head & 1` while the drive is engaged), which makes them come out
  **dashed** under LDS; the rungs always draw.
* **Everyone else gets a single centre line** (`FUN_100e59d0`).
* **Depth**: the shared line batch is set up with `z0=0, z1=50000` and both alpha
  and width `= 1 - depth/50000` -- a linear fade to nothing exactly at the
  eligibility range.
* The element also draws a small **2D wingtip marker** (sprite 5) at each trailed
  contact's projected screen position, and at both of the player's projected
  wingtips.

Neither class has any INI properties: both `RegisterClass` calls pass the base
`iiHUDElement` property map, and there is no `[icHUDShields]` or
`[icHUDContrails]` section in `flux.ini` / `defaults.ini`. Draw order in
`flux.ini [icHUD]` is unchanged: Contrails `elements[4]`, Shields `elements[8]`.

Constant table (all `iwar2.dll`):

| addr | value | meaning |
|---|---:|---|
| `0x1011e10c` | 112 | shields block width |
| `0x1011e110` | 32 | shields row pitch |
| `0x1011d970` | 16 | header height |
| `0x1011e140` | 38 | `112 - 38 = 74` = bar length |
| `0x101607e0` | 0.2 | `icPlayerLDA::min_energy` |
| `0x10119458` | 0.001 | ms->s for the 2 Hz broken-row flash |
| `0x1011da8c` | 0.4 | contrail emit interval (s) |
| `0x1011da90` | 0.35 | contrail splay-open ramp (s) |
| `0x1011da94` | 2.0 | contrail grace fade-out (s) |
| `0x1011da98` | 50 | minimum speed to leave a trail (m/s) |
| `0x1011da9c` | 150000 | trail range under LDS (m) |
| `0x1011daa0` | 50000 | trail range normally (m) |
| `0x1011daa4` | 0.7 | point life/alpha at emit |
| `0x10173f5c` | 0.109375 | life decay/s, derived at `0x100e4b80` |

---

# The two menu screens (second pass): `icHUDEngineering` and `icHUDStarmap`

`docs/original.md` §8e said of the starmap "its layout is not recovered" and of
the TRI "which corner is which system is unknown". Both are recovered now. The
route was the usual one — class-name string -> `RegisterClass` -> factory ->
ctor -> **vtable read out of the PE** -> raw-byte disassembly of the slots
Ghidra dropped.

## `icHUDEngineering` — the TRI is DRIVE / OFFENSIVE / DEFENSIVE

| | |
|---|---|
| registration | node `hud_menu_eng`, caption `hud_menu_engineering` |
| ctor | `0x101059f0` |
| **vtable** | **`0x1011e334`** |
| slot 9 (shared Draw) | `0x100f1400` |
| slot 11 re-open | `0x10105c10` |
| slot 13 menu input | `0x10105c80` |
| slot 14 body draw | `0x10105d40` -> the TRI half is **`0x10107710`** |
| per-frame feed | **`0x10108890`** |

The five floats an earlier pass reported "parked after the vtable at
`0x1011e348`" were **vtable slots**, not data. The data starts at `0x1011e378`
and is the screen's pixel geometry: `70, 160, 35, 281, 275, 198, 155, 192, 66`.

### The axes — proven four independent ways

`iiShipSystem::TRIWeight()` (`0x1003c170`) returns
`m_tri_weights[ this+0x64 ]`, and `this+0x64` is an **`iiShipSystem::eType`**
written by each subsim's constructor. The base ctor (`0x1003b9f0`) defaults it
to **3** — "no TRI" — and only three groups override it:

| eType | classes | ctor |
|---|---|---|
| **0 — DRIVE** | `icDrive` / `icThrusters` / `icCapsuleDrive` / `icLDSDrive` | `0x10030da0` / `0x1003c590` / `0x10030750` / `0x10036c50` |
| **1 — OFFENSIVE** | `iiWeapon` (all weapons) / `icMissileLauncher` | `0x1003c860` / `0x10031450` |
| **2 — DEFENSIVE** | `icAggressorShield` | `0x1002f290` |

`icPlayerPilot::DistributePower` (`0x100b00d0`) then names them outright — it is
the handler for the four power keys, and each one calls
`iiShipSystem::SetTRIPosition(a, b, c)` with a corner:

| `eButtonCommand` | binding (`FcInputMapper::Register`) | call |
|---|---|---|
| 0x17 | `icPlayerPilot.PowerToOffensive` | `SetTRIPosition(0, `**`1`**`, 0)` |
| 0x18 | `icPlayerPilot.PowerToDefensive` | `SetTRIPosition(0, 0, `**`1`**`)` |
| 0x19 | `icPlayerPilot.PowerToDrive` | `SetTRIPosition(`**`1`**`, 0, 0)` |
| 0x1a | `icPlayerPilot.BalancePower` | `SetTRIPosition(1/3, 1/3, 1/3)` |

The two agree exactly. And the art agrees twice more: the screen draws its three
bars with sprites **66 / 67 / 68** in that row order — a ship with an engine
plume, a ship firing two beams, a ship behind a deflecting arc — and
`images/hud/tri.png`'s three corner nodes carry **those same three glyphs**:

| tri.png node (quad-local px) | glyph | axis |
|---|---|---|
| bottom apex, **(74.5, 119)** | engine plume | **0 DRIVE** |
| top-left, **(20.5, 19)** | two beams firing | **1 OFFENSIVE** |
| top-right, **(127.5, 19)** | deflecting arc | **2 DEFENSIVE** |

So it was never POWER / REPAIR / HEAT.

### What the TRI actually does

`iiShipSystem::SetTRIPosition` (`0x1003c070`) converts each axis position into a
multiplier that every subsim of that type then applies:

```
x = pos * 3 - 1                                  ; 0x10118490 = 3, 0x101171f0 = 1
w = 1 + x * 0.5 * (max_tri_weight - 1)   if x > 0   ; 0x10117738 = 0.5
w = 1 + x * (1 - min_tri_weight)         if x < 0
```

i.e. **weight = `min_tri_weight` at position 0, exactly 1.0 at 1/3, and
`max_tri_weight` at 1.** `min_tri_weight` / `max_tri_weight` are static
`iiShipSystem` INI properties, clamped on load to `[0,1]` and `[1,3]`.
`TRIWeight()` returns a flat 1.0 for anything that is not the player's ship
(`IsPlayer` gate), so the TRI is a player-only system.

Consumers: `iiWeapon::Range` / `::RefireDelay` (`0x1000f090` / `0x1000f0a0`),
`::IsReadyToFire` / `::Fire` (`0x10035120` / `0x100357e0`),
`icLDSDrive::Simulate` (`0x10037040`), the capsule drive (`0x100305e0`) and the
aggressor shield (`0x1002f900`).

### Layout and animation (all `0x10107710` / `0x10108890`)

- the screen is authored for **640x480**: the body draw literally tests
  `cmp eax, 0x280 / cmp ecx, 0x1e0` before drawing its developer-mode rect.
- **the track**: `tri.png` (texture 3) drawn 1:1 as a quad
  **(275,192)-(430,347)**, u/v `0 .. 0.60546875` of a 256px texture = **155px**.
  (`0x1011e388` = 275, `0x1011e394` = 192, `0x1011e390` = 155.)
- **three bars** at x = **35** (`0x1011e380`), y = **212 / 247 / 282** (35px
  pitch), length **217**, style 3, icons **66 / 67 / 68** — one per axis, in
  DRIVE / OFFENSIVE / DEFENSIVE order (`FUN_100ed780`).
- **row 4** = `hud_engineering_resettri`, at **(35, 317)** (`FUN_100ea900`).
  The eleven localised strings come from the key table at `0x10163e94`, in this
  order: `hud_menu_engineering`, `_ship`, `_iff`, `_back`, `_resettri`,
  `_powerhelp_part1`, `_part2`, `_general_enabled`, `_general_disabled`,
  `_powerpod_enabled`, `_powerpod_disabled`.
- **six rows** (`this+0x54`, wrapped 0..5 by `FUN_10105c80`, opening on row 5).
  Rows **1/2/3 are the three TRI axes** (`FUN_10107710` feeds `this+0xc0` /
  `+0xc4` / `+0xc8` to `FUN_101081a0` for exactly those rows) and **row 4 is
  RESET TRI** (`FUN_101092f0` -> `SetTRIPosition(1/3,1/3,1/3)`).
- **the marker** is sprite **45** (a ragged ring), spun one revolution per 2 s
  (`rot = frac(t_ms * 0.0005) * 2*PI`), chased toward the barycentre at
  **50 px/s** (`0x10163f10`). Its final placement is an affine remap of the
  barycentric solve: `x' = (155 - (x - 275)) * 0.85 + 281`,
  `y' = (155 - (y - 192)) * 0.9 + 198` (`0x10119b3c` = 0.85, `0x1011951c` = 0.9,
  `0x1011e384` = 281, `0x1011e38c` = 198). An affine map of a barycentric mix is
  the barycentric mix of the mapped corners, so interpolating the three node
  centres directly gives the same point.
- **three copies of the TRI**, which is where the screen's life comes from
  (`FUN_10108890`): `+0xc0..0xc8` is the **live** `iiShipSystem::m_tri_position`;
  `+0xcc..0xd4` is a **slow ghost** chasing it at 0.15/s (`0x10163f08`) and is
  what the *bars* show; `+0xdc..0xe4` is a **fast ghost** at 0.8/s
  (`0x10163f0c`) and is what the *marker* is solved from. Each ghost's budget is
  shared between the three axes in proportion to their errors.
- **the shimmer**: while an axis's ghost has caught up (`+0xd9/+0xda/+0xdb`, set
  when `|ghost - live|` is inside +/-0.1) and its value is strictly between 0 and
  1, the drawn value wobbles by **+/-0.02** (`0x1011e3b8`) at
  `sin(pi*t)` / `cos(5.0266*t)` / `sin(4.0841*t)`.

### Still UNKNOWN on this screen

- **rows 0 and 5.** Row 0 has an Enter handler (`FUN_10106390(this, 4)`, via the
  dispatch table at `0x10163ec0`, whose other five entries are null); row 5 has
  none and is the row the screen opens on. Their labels and y positions in
  `hud_screens.gd` are ours. The four unused strings
  (`_general_enabled/disabled`, `_powerpod_enabled/disabled`) are two toggle
  pairs, so at least one of these rows is a toggle — which one, and what it
  toggles, is not established.
- what `0x1011e378` = 70 and `0x1011e37c` = 160 position.

## `icHUDStarmap` — a pannable 2D chart, and the data is in `clusters.ini`

| | |
|---|---|
| registration | `FUN_100fb1c0` (node `hud_menu_map`, caption `hud_map_caption`) |
| factory / ctor | `FUN_100fb200` (size **0x1b8**) / `FUN_100fb260` |
| **vtable** | **`0x1011e1d8`** |
| slot 11 re-open | `0x100fba50` |
| slot 12 | `0x100fbc20` |
| slot 13 menu input | `0x100fbc60` |
| slot 14 body draw | **`0x100fbf50`** |
| slot 15 / 16 | `0x100fbce0` / `0x100fbf40` |
| cluster renderer | **`0x100ff0a0`** |
| system renderer | **`0x100fda70`** |

### The state machine (`this+0x74`)

| state | what | input handler |
|---|---|---|
| 0 | **CLUSTER VIEW** | `FUN_100fcd60` |
| 1 | cluster -> system, zooming in | — |
| 2 | **SYSTEM VIEW** | `FUN_100fce60` |
| 3 | system -> cluster, zooming out | — |
| 4 | a drilled-in local view (`this+0x150` is a sim) | `FUN_100fd130` — **not recovered** |

**The two views are not a page flip: they cross-fade through the zoom.** The
body draw runs the cluster renderer whenever the state is not 2 and the system
renderer whenever it is not 0; in states 1 and 3 it blends them by where the
zoom sits between its limits:

```
f = (zoom - 0.001) / (5.0 - 0.001)          ; 0x1011e1a0, 0x1011e194
cluster_alpha *= f ;  system_alpha *= (1 - f)
```

Entering a system (`FUN_100fcd60` case 0 — the UP menu command) sets state 1 and
**multiplies the zoom target by 0.001**; backing out (`FUN_100fce60` case 1)
sets state 3 and multiplies it by **1000.0** (`0x1011e198`). So diving into a
system is one continuous dive down the cluster chart until the system fills the
screen. Menu commands in the cluster: **0 = enter, 1 = back, 2/3 = prev/next
system, 5 = close**. The ctor also builds eight on-screen key legends
(`FUN_100efbb0(widget, key, keycode, colour)`): `hud_menu_cancel` (0x1f, **red**),
`hud_menu_next` (0x23), `hud_menu_prev` (0x22), `hud_map_zoom_in` (0x24),
`hud_map_zoom_out` (0x25), `hud_map_select`, `hud_map_select_destination`,
`hud_map_jump_destination`.

### The projection — `FUN_100ff0a0`

The body draw pushes a matrix whose translation is **(screen_w/2, screen_h/2)**,
so everything below is drawn about the screen centre. Then, per system:

```
sx = (sys.map_x - cam_x) * scale
sy = (sys.map_y - cam_y) * scale
scale = min(screen_w, screen_h) * 0.45 / zoom      ; FUN_100ff9f0, 0x1011e1a8 = 0.45
```

`sys.map_x` / `map_y` are `icSolarSystem+0x624` / `+0x628`, and
**`icCluster::Load` (`0x10044360`) reads them straight out of
`geog/clusters.ini`'s `map_coords[n]`** via `FcINIFile::NumberedVector`. That
file *is* the cluster map — 16 systems with hand-placed 2D chart positions, plus
`label[n]` / `label_coords[n]` for the two cluster names (`badlands_cluster` at
`(-2,-4)`, `gagarin_cluster` at `(10,-3)`). It is a **flat spatial chart, not
the jump graph**; the jump links are drawn *on* it.

Selecting a system (`FUN_100fda10`) re-centres the camera on that system's
`map_coords` and parks the zoom at its maximum, **5.0** — so the chart is
larger than the screen and you pan it by cycling the selection. The camera then
eases in at `5 * distance` per second (`0x1011e190`).

### What the cluster view draws

- **jump links**: lines from the table at `this+0x9c` (count `+0x94`, stride
  0x20), line width **0.5**, fade width **1.5**, colour `DAT_10174fb0` **amber**.
- **each system**: one sprite, drawn **additively** (`SetBlend(2)`), with its
  localised name **16px to the right** (`0x101184a0`). The alpha carries the
  save game:

  | alpha | when |
  |---|---|
  | **1.0** | selected, or the system you are in |
  | **0.7** (`0x101191e8`) | **visited** — the system's name is hashed and looked up in `icSaveGame`'s hash set |
  | **0.3** (`0x1011c034`) | never visited |

- **the two cluster labels**, at their `label_coords`.
- mouse picking (`FUN_100ffb50`) takes the nearest system within
  `sqrt(144) = 12px` (`0x1011e234`).
- two header glyphs at the fixed pixels **(36,126)** and **(72,126)** — roundel
  sprite 53 with sprite **36** (zoom-in) or **37** (zoom-out) over the first and
  sprite **29** over the second, blinking at
  `alpha = (|frac(t*0.0005) - 0.5| * 1.8 + 0.1)` while a zoom or a pan is still
  in flight.
- three text lines at x = **20**; `FUN_100eb270` puts two of them at
  **y = 60** and **y = 80**.

### What the system view draws — `FUN_100fda70`

Orbits are real circles (`FcGraphicsEngine::DrawCircle`) in amber at line width
0.5; the plotted **ROUTE** is drawn over them at line width **2.0**; bodies,
stations and L-points are sprites; there is a **red** (`DAT_10176018`) marker
sprite. Its zoom is a **double** (`this+0xe8` / `+0xf0`), because the radii are
in metres.

### Still UNKNOWN on this screen

- the **sprite id for a cluster node** — the draw reads it out of a runtime list
  at `this+0x90` that is filled elsewhere. We use the roundel, sprite 53.
- **state 4**, the drilled-in local view (`FUN_100fd130`).
- the system view's **initial zoom** (set in `FUN_100fd440`, a Ghidra hole). We
  fit the system to the page instead.
- `icSaveGame`'s visited-system set is not persisted in the remaster; we keep an
  in-session set instead, which is the same mechanism with a shorter memory.

## New atlas cells

Read out of the same table builder (`0x100e6c60` ->
`FUN_100ee6b0(x, y, w, h, origin_x, origin_y, texture)`), all texture 0
(`images/hud/sprites.png`):

| id | atlas | size | origin | what |
|---|---|---|---|---|
| 36 | (198, 125) | 32x32 | 16,16 | starmap zoom-in arrow |
| 37 | (198, 158) | 32x32 | 16,16 | starmap zoom-out arrow |
| 45 | (66, 59) | 32x32 | 16,16 | the TRI marker (a ragged ring) |
| 66 | (99, 191) | 32x32 | 16,16 | TRI axis 0 — ship + engine plume |
| 67 | (132, 191) | 32x32 | 16,16 | TRI axis 1 — ship + two beams |
| 68 | (165, 191) | 32x32 | 16,16 | TRI axis 2 — ship + deflecting arc |
