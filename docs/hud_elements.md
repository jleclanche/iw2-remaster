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

## Sprites

The HUD draws almost everything as textured quads, not vectors:
`FUN_100e9de0(x, y, sprite_id, flags, rotation)`. `sprite_id` indexes a table at
`DAT_101741b0`, stride 0x24 = `{w, h, origin_x, origin_y, u0, v0, u1, v1, ?}`.

Note the decompiler prints small integer sprite ids as denormal floats — `1.26117e-43`
is the float whose *bit pattern* is 90, i.e. sprite **90**. Ids seen: 90 = the reticle
ring itself (`images/hud/reticle.png`), 20 = a charge pip, and 0x15-0x1e / 0x3e-0x40 /
0x4e / 0x56-0x59 for the status icons (`images/hud/sprites.png`).

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
`FUN_100f93c0(out, angle, radius_delta, sprite_id, colour, size)`, which stores

```
+0x00 sprite id     +0x04 angle = arg * PI      +0x08 radius = 80 + radius_delta
+0x0c x = floor(sin(angle) * radius)            +0x10 y = floor(-cos(angle) * radius)
+0x14 visible       +0x18..0x20 FcColour        +0x24 size    +0x28 charge 0..1
```

So the angle argument is in **half-turns**, and angles run **clockwise from twelve
o'clock**. The slots the constructor lays down:

- **-22.5, -33.75, -45, -56.25** at r=150 — the four mode icons (sprites 0x15-0x18).
  `FUN_100f8410` makes exactly one visible, indexed by a table at `DAT_1011e04c`.
- **-22.5** at r=110 — LDS / capsule drive (sprite 0x19 or 0x1a), with a charge ring
- **+22.5** at r=110 — sprite 0x1e
- **-67.5** at r=110 — sprite 0x1b / 0x1c / 0x1d
- **+67.5** at r=110 — sprite 0x4e
- **135, 157.5, 180** at r=110 — sprites 0x3e-0x40; each turns red (`DAT_10176018`,
  size 0xd) when its flag is set, otherwise amber (`DAT_10174fb0`, size 9)
- **202.5** at r=110 — sprites 0x56, 0x57 (multiplayer team markers)
- **225** at r=110 — sprites 0x58, 0x59 (multiplayer flag / bomb)

Each icon can carry a charge ring: `FUN_100f8da0` lights `floor(charge * 24)` pips on a
circle of radius 18, and fades the next one by the remainder.

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

## icHUDTargetMFD

**128 x 176** (`DAT_1011e238` / `DAT_1011e23c`), left-anchored, top of the stack. Header
label at (3, 3). The body is a wireframe render of the target in **chartreuse**
(`DAT_10176038`). Two text lines sit at the bottom in **amber** (`DAT_10174fb0`),
indented **32px**: line 1 the ship name, line 2 the owner/route. 18 localised keys, all
present in `hud.csv` (`hud_target_target_mode`, `hud_target_no_target`, ...). Text is
revealed with a typewriter effect at **30 chars/sec** (`DAT_1011dc0c`).

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

- **Which sprite glyph goes in which status-icon slot.** The sprite table
  (`DAT_101741b0`) is populated at runtime, not stored in the PE, so sprite id -> atlas
  cell cannot be resolved. The slot *angles and radii* above are real; the icons keep
  our text labels rather than inventing a glyph mapping.
- **The damage ramp's LERP operands** (see above) — thresholds are real, interpolation
  is ours.
- **The exact tick-mark pattern on the reticle ring.** The ring is a texture
  (`images/hud/reticle.png`), not vector geometry; the radius is real, the tick count
  and lengths in `hud.gd` are eyeballed from that texture.
- **Font metrics.** `DAT_10162c68` (char width) and `DAT_10162c6c` (line height) are
  measured at runtime from the loaded font and are zero in the file. Several positions
  are expressed in terms of them, so these are **not** recoverable statically:
  - the **clock block's** pixel width and height,
  - the **MFD's two text-line Y positions**,
  - the **contact list block's width** (`DAT_10173f48`, a width in characters, is never
    assigned anywhere in the decompilation).

  We use our own font's metrics for all of these.
- **Which screen corner each block registers into.** Left/right is established (the
  anchor-mode ctor arg); top/bottom is not — it is inferred from the reference shot.
- **The MFD's small segmented bar** (the thing left of "SEA QUEEN" in the reference
  shot). There is no `FUN_100ebde0` call anywhere in the MFD's draw path, so whatever it
  is, it is not the shared bar routine. Not identified.
- **The text primitive's alignment argument** (`FUN_100eb270` args a2/a6/a7). The
  function clearly does half-width/half-height centring, but which argument selects it
  was not pinned down — so we cannot prove how the weapons "100%" readout is aligned
  despite being passed the same X as the bar.
- **What the shield bars actually measure** — the component class they filter on
  (`DAT_10167e5c`) was not resolved. **We draw no shields panel at all**, because our
  sim has no shield components and inventing one would be fabrication.
- **Contact-list max rows and sort order** are now real (6 rows, range ascending), but
  our list still comes from `main.contact_list()`, which caps at 12 before we see it.
