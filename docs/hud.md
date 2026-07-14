# HUD underlay elements (world-space HUD)

Everything below is read out of `bin/release/iwar2.dll` (Ghidra image base
0x10000000). Addresses are virtual addresses in that image, so they can be
re-checked with

    python tools/ghidra/readconst.py "<install>/bin/release/iwar2.dll" 0x1011dc7c

`flux.ini [icHUD]` lists the elements in draw order; `elements[0]` is
`icHUDReferenceGrid` and `elements[1]` is `icHUDLagrangeIcon`. Both derive from
`iiHUDUnderlayElement`, i.e. they are drawn in the 3D scene, under the 2D HUD.

There are NO `[icHUDLagrangeIcon]` or `[icHUDReferenceGrid]` sections in
flux.ini and no L-point art in resource.zip. Both elements are 100% procedural
line geometry with hard-coded constants.

## How the classes were found

The icHUD* classes export no symbols. Route in:

1. class-name string -> `FcRegistry::RegisterClass` call
2. -> factory (`operator_new(size)`) -> constructor -> vtable pointer
3. vtable slot 9 (`+0x24`) is the element's Draw method.

| class | register | factory | ctor | vtable | object size | Draw |
|---|---|---|---|---|---|---|
| icHUDLagrangeIcon | 0x100ee7e0 | 0x100ee820 | 0x100ee8b0 | 0x1011dc90 | 0x620 | **0x100ee920** |
| icHUDReferenceGrid | 0x100f5430 | 0x100f5470 | 0x100f54d0 | 0x1011e004 | 0x38 | **0x100f5550** |
| icHUDWaypointIcon | 0x10103f70 | 0x10103fb0 | 0x10104040 | 0x1011e2cc | 0xb0 | **0x101040b0** |

Note: `FUN_100ee920` (the Lagrange draw) is **missing from
`data/decomp/iwar2.dll.c`** - Ghidra left 0x100ee920..0x100eebf0 undisassembled.
It was recovered by disassembling those bytes directly. The grid draw
(`FUN_100f5550`) and the Lagrange geometry builder (`FUN_100eebf0`) are in the
decomp.

## The shared line renderer

Three functions in iwar2.dll do all world-space HUD line drawing:

- `FUN_100e8960(z0, z1, a0, a1, w0, w1, force_thin)` - begin a batch.
  Sets the depth range [z0,z1] and two attributes lerped across it.
- `FUN_100e9060(float rgb[3])` - push a colour; subsequent lines use it.
- `FUN_100e8b30(&p0, &p1, w0, w1)` - add a line (local space; transformed by
  the graphics engine's current matrix).
- `FUN_100e91b0()` - flush/draw.

Semantics recovered from `FUN_100e8b30` (decomp ~line 180280) and the flush
(~line 180654): for each endpoint at view depth `z`,

    t     = clamp(1 - (z - z0) / (z1 - z0), 0, 1)     # 1 at the camera, 0 at z1
    width = lerp(w0, w1, t)
    alpha = lerp(a0, a1, t)

Lines whose depth is outside [near_plane, z1] are dropped, so **z1 is a hard
far-clip for the batch**. `use_thick_lines` (flux.ini `[icHUD]`, global
`DAT_101628bc`) selects a widened-quad path; the quad half-width is
`2.0 * t` (`_DAT_1011db60`) and `1.0 * t` (`_DAT_1011db5c`) in screen units, and
an endpoint falls back to a 1px line when `t < 1/(2+1) = 1/3`.

Both our elements pass `w0=0, w1=1` and per-line widths of 1.0, so `t` is
exactly the depth fade factor.

## icHUDLagrangeIcon - the double funnel

### Geometry (built once in the constructor, FUN_100eebf0 @ 0x100eebf0)

An 84-vertex / 132-line wireframe **hourglass**, stored in the object at +0x20
(vertices) and +0x410 (line index pairs). 0x410 + 132*2*2 = 0x620 = the object
size, which confirms the counts exactly.

    SEGMENTS   = 12                       # angle step 0.523599 = 2*pi/12  (_DAT_1011dcbc)
    RINGS      =  7
    LENGTH     = 3000.0                   # _DAT_1011dc7c
    z(r)       = LENGTH * -0.5 + r * LENGTH * (1/6)      # _DAT_1011a460 = -0.5, _DAT_1011cbd0 = 1/6
               = -1500, -1000, -500, 0, +500, +1000, +1500
    radius(z)  = (3 - 2*cos(z * PI / LENGTH)) * 375.0    # _DAT_10119464 = pi, DAT_1011dc80 = 375
    vertex     = (cos(a)*radius, sin(a)*radius, z)       # funnel axis = local +Z

So: waist radius **375 m** at z=0, mouth radius **1125 m** at z=+-1500 m, total
length **3000 m**.

### Line index list (order matters - the colours key off it)

    lines  0.. 11 : the 12 circumference segments of ring 3 (z = 0, the waist)
    lines 12.. 71 : rings 0,1,2 (z = -1500,-1000,-500): 12 circumference segments each,
                    plus 12 axial spokes ring0->ring1 and 12 spokes ring1->ring2
    lines 72..131 : rings 4,5,6 (z = +500,+1000,+1500): same, spokes ring4->ring5, ring5->ring6

There are deliberately **no spokes across the waist** (ring2 -> ring3 -> ring4),
so the two cones read as separate funnels joined by a free-floating waist ring.

### Colours (from the draw, 0x100eeb31 .. 0x100eeb8c)

    lines  0..11  : DAT_10176038 = (0.5, 1.0, 0.0)   yellow-green   (waist ring)
    lines 12..71  : (0.0, 0.0, 1.0)                  BLUE           (the -Z cone)
    lines 72..131 : (1.0, 0.0, 0.0)                  RED            (the +Z cone)

`DAT_10176038` is set by the static ctor `FUN_100e67b0` @ 0x100e67b0.

### What blue vs red actually means

Not near/far and not approach/exit-by-camera: it is fixed to the L-point's own
axis. `icLagrangePointWaypoint::TryToJump` (0x1006ad40) proves it:

- the L-point's local **Z axis** (matrix row at +0x104/+0x108/+0x10c) is the
  jump axis; the jumping ship's own Z axis must be within `m_max_jump_angle`
  of it;
- the ship's offset from the L-point, rotated into the L-point's frame, must
  have **local z < 0** or the jump is refused.

So **blue = the -Z half = the side you must be on to jump (the entry funnel);
red = the +Z half = the exit side.**

Related hard-coded statics (no INI):

    m_min_jump_speed = 100    m/s     0x1015d224
    m_max_jump_speed = 2500   m/s     0x1015d228
    m_max_jump_range = 500    m       0x1015d22c
    m_max_jump_angle = 30             0x1015d230

### Which L-point is drawn

Exactly one, and it is **not** the target. The draw reads
`icPlayerContactList::m_p_instance` (0x10167de8) `+ 0x14`, which
`icPlayerContactList::NearestLagrangePoint` (0x10002800) shows is literally
`return *(icContact**)(this + 0x14)` - the **nearest** L-point. It then
`FcRegistry::FindInstance(contact->id)` and requires
`IsKindOf(icLagrangePointWaypoint)` (static class ptr at 0x1016674c).

### Culling, distance and fade

    bounding radius = sqrt(3000 * 3000 * 0.5) = 2121.32 m     # computed at 0x100ee890 into DAT_10176050
    FcGraphicsEngine::OutsideViewFrustrum(relpos, 2121.32)  -> skip
    view depth d of the L-point centre must be <= 50000.0     # _DAT_1011dc84, hard 50 km cutoff
    FUN_100e8960(0.0, d + 2121.32, 0.4, 1.0, 0.0, 1.0, 0)

so per-vertex `alpha = 0.4 + 0.6 * t`, `t = 1 - depth/(d + 2121.32)`: ~1.0 right
on top of it, tending to 0.4 at long range, then a hard cut at 50 km.

The element also requires the L-point and the player ship to share the same
`+0x12c` pointer (the world/scene node) and draws with a world matrix built from
the L-point's 3x3 orientation (+0xec..+0x10c) and its position relative to that
node's origin (+0x60).

## icHUDReferenceGrid - the motion grid

Draw: `FUN_100f5550` @ 0x100f5550. It is **not** a grid of lines; it is a
9x9x9 lattice of **729 short streaks**, one per lattice point, each drawn
backwards along the player's velocity.

    v      = player ship velocity (ship+0x70..0x78).
             While the LDS drive is engaged AND icShip::IsOnTrolley(), v is
             instead recomputed as (pos - pos_last_frame) / dt, using the
             double-precision positions (ship+0x48/0x50/0x58) cached in the
             element at +0x20/+0x28/+0x30.
    speed  = |v|;  nothing is drawn if speed < 1e-6           (_DAT_101178fc)

    fade   = clamp(speed * 0.007, 0, 1)                       (_DAT_1011b358; full at ~142.9 m/s)
    e      = clamp(floor(log10(speed) + 0.3), 3, 10)          (_DAT_1011c034 = 0.3; clamp is in asm at 0x100f576a)
    cell   = pow(10.0, e)                                     # 1e3 .. 1e10 metres
    streak = v * (1/3)                                        (_DAT_10119454)

    start_axis = -4.5 * cell - fmod(player_pos_axis, cell)    (_DAT_1011e030 = 4.5)
    for i,j,k in 0..8:  p = start + (i,j,k)*cell
                        line(p, p - streak)

    FUN_100e8960(0.0, 5.5 * cell, 0.0, fade, 0.0, 1.0, 0)

So: spacing snaps to a power of ten chosen by speed; the lattice is anchored to
absolute world coordinates (the `fmod` on the player position) and slides through
the ship; each streak's length is 1/3 second of travel; alpha is
`fade * t` with `t = 1 - depth/(5.5*cell)`, i.e. it fades out at 5.5 cells.

### Grid colour

    LDS drive engaged  : DAT_10176038 = (0.5,   1.0,   0.0)   yellow-green
    otherwise          : DAT_10174fb0 = (1.0,   0.592, 0.0)   amber
                         (static ctor FUN_100e6750 @ 0x100e6750; 0x3f178d50 = 0.592)

"LDS engaged" is `ship+0x25c != 0 && *(ship+0x25c)+0x84 == 2`.

The grid is **not** blue/red. It is amber, and green under LDS. Only the
Lagrange funnel is blue/red.

## icHUDWaypointIcon (skimmed)

Geometry builder `FUN_10104380`: the 8 corners of a **cube**, side
`_DAT_1011e2b4 = 300.0` m (so +-150 m), wireframe. Draw 0x101040b0: same
renderer, draw distance `_DAT_1011e2b8 = 15000.0` m, fade `0.3 -> 1.0`
(`_DAT_1011e2bc`, `_DAT_1011e2c0`). Our existing beacon cube is therefore
right in kind; only its size (26 m) is invented. Not changed here.

## What could NOT be determined

1. **The L-point's orientation.** The funnel is drawn in the L-point sim's own
   frame and the sim's local +Z is the jump axis (proved by TryToJump above),
   but nothing in the HUD code *sets* that basis - it comes from the solar
   system loader / geography attachment. Our extracted system JSON
   (`data/json/systems/*.json`) carries no orientation for `lpoint` records at
   all (only pos/scale/parent/radius). So the true axis is not available to the
   remaster from our data.
   `game/scripts/space_fx.gd` therefore takes the axis as a parameter and
   `main.gd` passes a **clearly-marked placeholder**: the direction from the
   system primary (the star) to the L-point. This is NOT from the binary.
   Fixing it needs the L-point orientation re-extracted from the system files.
2. **Per-vertex screen-space line width.** The original widens lines into quads
   with half-width `2*t` px. Godot's `PRIMITIVE_LINES` has no per-vertex width,
   so only the alpha fade is reproduced. `use_thick_lines = 1` is noted but not
   reproduced.
3. `FUN_100e8960`'s exact viewport-depth convention (`TransformToViewport`) was
   read from the call site, not re-derived; the remaster uses the camera-forward
   projection of each vertex as the depth, which is the same quantity.

---

# Two overlay elements, redrawn with the engine's own primitives

Second pass. Both of these were previously **approximations** - hand-rolled
rectangles and vector text. Both are now the engine's calls, sprite for sprite.

## The shared primitives (all in iwar2.dll)

### `FUN_100e9de0(x, y, sprite, flags, rot)` - the atlas blit

Already known, with one thing the last pass missed: **the fourth argument is a
mirror mask, not a spare**.

    bit0 (0x100e9e0d) : mirror in X about the anchor -> x spans [ox - w, ox]
                        instead of [-ox, w - ox]
    bit1 (0x100e9e3a) : mirror in Y  ->  y spans [oy - h, oy]

That is load-bearing, not decoration. It is how **one** 9x11 lamp cell makes the
ship-status damage/power PAIR, how **one** 9x18 chevron caps **both** ends of a
rail, and how **one** 85x85 cell makes the **whole** 170x170 menu reticle. The
old menu reticle drew that cell once, so three quarters of it were missing.

`FUN_100ea7e0(x, y, sprite, rot)` @ `0x100ea7e0` is just the four-mirror blit:
the same cell with flags 0, 1, 3, 2.

### `FUN_100eaf90(x, y, w, thin, cap, rail)` @ `0x100eaf90` - the RAIL

The primitive both elements are built out of, and one we did not have at all.

    caps : blit `cap` at (x, y), and again at (x + w, y) with the X-mirror flag
    rail : stretch `rail`'s narrow column into one quad from x to x + w,
           spanning y - origin_y .. y + (h - origin_y)
    alpha: thin == 0 -> 0.5 * master;  nonzero -> 1.0 * master

The rail sprites are 2-4 px wide with a bright row at the top and another at the
bottom, so a "panel" in this HUD is **two horizontal rails between two chevrons**
- never a filled box.

    ship-status strip : cap 76 (9x18, origin 9,9)   rail 77 (2x18, origin 0,9)
    menu node box     : cap 40 (16x32, origin 16,16) rail 41 (4x32, origin 0,16)

### The text calls

`FUN_100eb270(font, style, x, y, str, halign, valign)` @ `0x100eb270`.

* `font` indexes the table at `0x10162c60` (stride 0x14), whose four entries are
  **`fonts/ocrb_8pt`, `fonts/ocrb_10pt`, `fonts/ocrb_18pt`, `images/hud/sprites`**.
  So the HUD's text is OCR-B at three sizes; Handel Gothic is not in this table.
* `style` indexes the alpha table at `0x10162cb0` (stride 8):
  **style 0 = 0.6, style 1 = 1.0, style 2 = 0.75** (times the master alpha).
* `halign` 2 centres on x, 1 right-aligns (`0x100eb7c2`).
* `valign` 2 centres on y (`y - h/2 - 1`, `0x100eb7aa`), 1 bottom-aligns.
  The y it takes is the TOP of the line; the baseline is added inside.

`FUN_100ea830` -> `FUN_100ea900` (`0x100ea830` / `0x100ea900`) is "a labelled
node box": measure the string, build a rail around it, optionally put an icon in
it. See the menu reticle below - that IS this call.

## icHUDShipStatus - the top-centre lights

`Draw = FUN_100fabd0` @ `0x100fabd0`. Reads the screen size off the icHUD
(`this+0x18`, `+0x14` / `+0x18`) and calls

    FUN_100fac60(x = screen_w * 0.5, y = 14.0, avail = screen_w - 320)
                                   ^0x41600000        ^_DAT_1011e174 = 320

(`0x100fabf0`'s `floor((avail - 8*3) * 0.25)` is computed and then **popped** -
dead code.)

`FUN_100fac60` @ `0x100fac60` is the entire element:

    n_max = ftol((avail - 2 * SPR[76].w) / 6)      # _DAT_1011cbd0 = 1/6
    n     = min(*(int*)(icShip + 0x138), n_max)    # the component count
    w     = n * 6                                  # _DAT_1011a1a0 = 6, the PITCH
    x     = cx - w * 0.5
    colour = chartreuse DAT_10176038;  alpha = master
    FUN_100eaf90(x, 14, w, 0, 76, 77)              # the rails, at HALF alpha
    x -= 1                                         # _DAT_101171f0
    for each component:
        <damage colour>  FUN_100e9de0(x, 14, 16, 0, 0)   # lamp ABOVE the anchor
        <power colour>   FUN_100e9de0(x, 14, 16, 2, 0)   # the SAME lamp, Y-mirrored
        x += 6

**It is one lamp PAIR per mounted subsim on a 6px pitch - damage over power -
exactly as the manual says.** It is not eight labelled bars for eight groups;
that was invented and is now gone. Sprite 16 is `(144,0) 9x11, origin (0,9)`: a
round glow whose lit disc sits 3px off the anchor, so the upright copy lands
above y = 14 and the Y-mirrored copy below it, framed by rails 9px either side.

`DAT_10174c60` is not a mystery constant - it is `sprite_table[76].w`
(`0x101741b0 + 76*0x24`), i.e. the strip can be as wide as the screen minus 320
minus its two chevrons.

### The two colours

The damage lamp, in the order the code tests (`0x100fadc0`..):

| subsim state | lamp |
|---|---|
| flag `0x10` (disrupted, `icShip::Disrupt`) | amber `DAT_10174fb0` * `rand()/32768` - it hashes |
| flag `0x08` (hit points < 0, set in `iiShipSystem::Simulate` @ `0x1003bd2f`) | **black** |
| `hp_max == 0` (cannot be damaged) | chartreuse |
| `hp / hp_max <= 0` | **black** |
| otherwise | the damage ramp `FUN_100e88c0(hp/hp_max)` |

The power lamp:

| subsim state | lamp |
|---|---|
| flag `0x10` | blue * `rand()/32768` |
| flag `0x04` (underpowered: supply ratio <= 0.25, `0x1003bd8b`) | **black** |
| `power_required == 0` | full blue |
| otherwise | blue * (`+0x70` / `+0x44`) |

and the blue is `DAT_10174190/94/98` = **(0.3, 0.6, 1.0)**, scaled by the power
fraction - a half-fed subsim is literally a half-bright lamp.

`+0x70 / +0x44` is the subsim's **power satisfaction** - `iiShipSystem::Simulate`
@ `0x1003bd53` sets `+0x70 = (got / drain) * required` where
`drain = (usage * 0.75 + 0.25) * required`. `ship_systems.gd` runs that exact
distribution but does not keep the ratio, so `hud.gd::_power_ratios()` recomputes
it read-only, in mount order, from the same stored `usage` / `power` and the same
reactor pool. It is not an approximation of the value; it is the value.

### The flash

    t = game_time_ms * 0.002        # _DAT_1011dfd0
    if frac(t) > 0.5:  draw the lamp a SECOND time

2 Hz, 50% duty, on the damage lamp while `hp < hp_max` and on the power lamp
while the ratio < 1. Under the engine's **additive** blend a second blit doubles
the lamp's brightness, so a damaged system's light pulses.

Which is why the strip is drawn on its own additive `CanvasItem` in the remaster
(`Hud.StatusLights`, blend mode ADD): for this one element the blend mode is
load-bearing, not cosmetic - a destroyed subsim's lamp is drawn in **black**
(`FUN_100fac60` @ `0x100faf34`), which only reads as "off" if the blend is
additive, and the flash only reads as a flash if a second blit brightens.
Everything else in our HUD stays on the ordinary alpha-blended canvas.

## icHUDMenuReticle - the arrow-key menu

`Draw = FUN_100f1d60` @ `0x100f1d60` (Ghidra dropped it; disassembled by hand).
It gates on `icHUD+0x1b4`, pushes a translate to the screen centre, and draws:
the reticle, the four spinning quadrants, the focused node's name, the timeout,
and the four link boxes - in that order.

### Which input is being held drives the whole look

`icHUD+0x1bc` = "a menu input is down", `icHUD+0x1c0` = which one, in the input
mapper's slot order (`FUN_100e1bf0`): **0 up, 1 down, 2 left, 3 right, 4 select**
- the same order as the link offsets `+0x14`/`+0x18`/`+0x1c`/`+0x20`.
`icHUD+0x1b6` is `ihud.LockMenu`, and while it is set nothing counts as held.

| thing | alpha | where |
|---|---|---|
| the reticle (sprite 91 x4) | **0.5** while a direction **that has a live link** is held, else 1.0 | `0x100f1e40` / `0x100f1f9f` |
| the four quadrants (93 x4) | **1.0** only while SELECT (input 4) is held, else 0.5 | `0x100f1ff4` |
| the focused node's name | style 1 (1.0) while SELECT is held, else style 0 (0.6) | `0x100f2151` |
| a link's box and label | **1.0** if THAT direction is the one held, else 0.5 / style 0 | `0x100ea949` |

So the reticle dims as it hands you off, the quadrants flash on the "click", and
the box you are moving towards lights up. None of that was in our version.

### The spin is a KICK, not a rotation

`0x100f1e73`. On the frame a menu key **goes down** (latched through
`this+0x2c`):

    this+0x24 (rate) = sign(rand()/32768 - 0.5) * PI    # _DAT_10119ae0 = -1, _DAT_10119464 = PI
    this+0x28 (timer) = rand()/32768                    # a random duration under 1 s

and every frame after that:

    if timer > 0:  timer -= game_dt;  angle (this+0x20) += rate * timer

i.e. a random-direction spin that decays linearly to a stop. **Between keypresses
the quadrants are perfectly still.** Our constant 0.05 rev/s drift was invented.

### The centre

* sprite **91** (`reticle.png` (85,0) 85x85, origin (0,85)) blitted **four times**
  through `FUN_100ea7e0(0, 0, 0x5b, 0)` - one per mirror pair. The cell is ONE
  QUADRANT of the 170x170 reticle.
* sprite **93** ((0,186) 70x70, origin (0,70)) blitted four times, rotated by
  `angle + i * PI/2` (`_DAT_1011a454`).
* the focused node's name (`node+8`, a `hud.csv` key resolved through
  `FcLocalisedText::Field`) in **font 2 = ocrb_18pt**, centred on the reticle in
  both axes.
* the timeout **only on the ROOT node** (`cmp ebx, [icHUD+0x198]` @ `0x100f20a2`)
  and only under 10 s (`_DAT_101190c0`): `hud_menu_timeout` ("TIME: ") plus
  `AppendFormat("%0.1fs", icHUD+0x1b8)`, font 0 = ocrb_8pt, style 0, at
  **(0, +30)** (`0x41f00000`). We used to draw it on every node, as an integer.

### A node box IS `FUN_100ea830`

Per direction `i` (skipping a null link, and skipping a link whose node is
**disabled**, `node+0x10 == 0` @ `0x100f2187` - a disabled node is not greyed
out, it is not drawn):

    anchor = centre + offset[i]        # (0,-100) (0,+100) (-100,0) (+100,0)
    align  = DAT_1011dec8[i] = [2, 2, 1, 0]   # UP/DOWN centred, LEFT right-aligned,
                                              # RIGHT left-aligned: they hang outward
    FUN_100ea830(0, 0, name, node->sprite, node->colour, align, held == i)

and `FUN_100ea830` / `FUN_100ea900`:

    w  = text_width + (32 if sprite else 0) - 16      # _DAT_1011848c, _DAT_101184a0
    x  = floor(anchor.x) - 1;  align 2: x -= floor(w/2);  align 1: x -= w
    x  = floor(x) - 1
    FUN_100eaf90(x, y, w, held, 40, 41)               # the rail: 32px tall, 16px chevrons
    tx = x - 8                                        # _DAT_10117b28
    if sprite:                                        # icon nodes only
        ix = tx + 12                                  # _DAT_10119ec4
        if held: blit roundel 51 under it
        blit the sprite at ix, in the NODE'S colour, at FULL alpha
        tx = ix + 16;  colour reverts to chartreuse
    if name: FUN_100eb270(font 1 = ocrb_10pt, held ? 1 : 0, tx, y, name, 0, 2)

The label is drawn **8px left of the rail**, and the rail is **16px shorter than
the label**, so the text overhangs 8px into each chevron: the box reads
`<[ LABEL ]>`. That is why it is a rail primitive and not a rectangle.

### The node colours

Every node is built by `FUN_100efbb0(this, name, sprite, colour)` @ `0x100efbb0`
(`+0xc = 1`, `+0x10 = 1` enabled, `+0x14` sprite, `+0x18..+0x20` colour). Across
the whole tree that is called with **sprite 0 and `DAT_10176038` chartreuse** -
so the tree is uniformly green, and our amber-for-screens rule was invented and
is gone. The exceptions are all inside the carousels:

* `hud_menu_prev` / `hud_menu_next`: sprites **0x20 / 0x21**, chartreuse
  (`0x100f2 ctor block`, e.g. the autopilot's at `0x100efe50`) - these are the
  carousel's UP / DOWN links, so they draw as icon boxes.
* `hud_menu_autopilot_disengage`: sprite **0**, **amber** `DAT_10174fb0`.
* the autopilot's four items (`approach` / `formate` / `dock` / `pursuit`,
  `item+0x24` = engine mode 2 / 1 / 3 / 4): sprites **0x15..0x18** - the same
  four mode glyphs the reticle's icon ring uses - in **amber**.
* `hud_menu_cancel`: sprite **0x1f**, colour (1, 0, 0) red (`0x100f0200`).

## What stays UNKNOWN

1. **How a carousel node displays its selected item.** The centre text is the
   focused node's `+8` name and nothing else; the item nodes exist (with amber
   mode icons) but the draw never reaches them from the focus node. Whether the
   engine swaps the focus node's name for the item's, or draws the item node
   somewhere we have not found, is not settled. `hud.gd` keeps the earlier pass's
   "AUTOPILOT: APPROACH" composite - it is ours, not the binary's.
2. **`hud_menu_cancel`'s place in the tree.** It is built (red, sprite 0x1f) but
   we did not find who links it.
3. **The subsim flag bits above 0x10.** `+0x68` bits 0/2/3/4 are pinned (see the
   table above); 0x20, 0x40, 0x80, 0x100, 0x200 are set in several places and
   the status strip does not read them.
4. **The exact glyph the engine gets for `icShip+0x138`'s ordering.** We iterate
   `ship_systems.gd`'s `systems` array, which is INI mount order. The engine's
   component list is built by `icShip::OnAttachSubsim` in the same order, but we
   have not proved no other code reorders it.

---
