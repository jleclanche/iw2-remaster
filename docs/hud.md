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

### `FUN_100e2620(this)` @ `0x100e2620` - the BLOCK FRAME (panel chrome)

This is the one that was missing, and the one the user kept flagging: **every**
flight-HUD panel draws its border here, and it is neither a filled rectangle nor
a 1-px outline. A block is a rectangle with **one 16-px chamfered corner** - the
corner that faces the screen interior - plus a translucent fill, a soft outward
glow, a bright chamfered edge outline, a faint 16-px grid, and (for top-anchored
blocks) a header band. It is a vector shape; there are **no dedicated corner
sprites** (the corner cells 40/41/76/77 belong to the rail primitive above, not
to panels).

Confirmed callers (all raw-disassembled - Ghidra dropped most of these draws):

    icHUDTargetMFD   Draw 0x10101730   call 0x100e2620 @ 0x101017ad
    icHUDWeapons     Draw 0x101046e0   call 0x100e2620 @ 0x101047b2
    icHUDShields     Draw 0x100fa540   call 0x100e2620 @ 0x100fa622
    icHUDContactList Draw 0x100e4440   call 0x100e2620 @ 0x100e4481
    icHUDOrbRadar    Draw 0x100f4520   call 0x100e2620 @ 0x100f4532
    icHUDClock       Draw 0x100e40f0   call 0x100e2620 @ 0x100e40f9

(icHUDShipStatus is the exception: it is the top-centre RAIL strip, not a block,
and draws no frame.)

What the function draws, in order (all colour = chartreuse `DAT_10176038`):

    fill     Begin(3) alpha-blend : the chamfered pentagon, colour GREEN *
             _DAT_1011b354 (0.15), per-vertex alpha 0.5  -> a dark translucent
             green backing you can see the world through
    glow     same Begin(3)        : a _DAT_1011d96c (4) px ring around the
             pentagon, alpha 0.5 at the edge -> 0 outward
    outline  Begin(2) ADDITIVE    : the pentagon edge, alpha _DAT_101184b0 (0.1)
             - the crisp line that turns the chamfered corner
    grid     Begin(1) ADDITIVE    : vertical lines at x = 16*i, horizontal at
             y = 16*i (DAT_1011d970 = 16), alpha _DAT_1011d9cc (0.04)
    header   FUN_100e3360(0,0,W,16) ADDITIVE : a filled band, alpha _DAT_101191ec
             (0.25), only for modes 0/1 and only when H > 16 (0x10101792 branch)

The chamfered corner is selected by the element's **anchor mode** (icHUDElement +
0x20, the argument to the base ctor `FUN_100e2470(this, mode)`):

    mode 0  left column   MFD, Weapons            -> chamfer BOTTOM-RIGHT
    mode 1  right column  Orb, Shields, Clock     -> chamfer BOTTOM-LEFT
    mode 3  bottom        ContactList             -> chamfer TOP-LEFT

The 5 outline points (block-local, chamfer CH = 16) reduce to:

    mode 0 : (0,0) (0,H) (W-CH,H) (W,H-CH) (W,0)
    mode 1 : (W,0) (W,H) (CH,H) (0,H-CH) (0,0)
    mode 3 : (W,H) (W,0) (CH,0) (0,CH) (0,H)

Block dimensions (ctor `FUN_100e2540(this, W, H)`):

    MFD      W = DAT_1011e238 (128), H = DAT_1011e23c (176) / DAT_1011e240 (48 short)
    Orb      W = DAT_1011df88 (128), H = 16 + 128 = 144   (WIDER than the rest)
    Weapons  W = DAT_1011e2f8 (112), H = 16 + 32*rows
    Shields  W = DAT_1011e10c (112), H = 16 + 32*rows  (0 rows -> H 0, panel gone)
    Clock    W = timestring width + pad, H = timestring height + pad

Ours (`hud.gd`): `_frame(pos, size, mode)` draws the pentagon + glow + grid +
outline; `_panel(pos, size, title, mode)` adds the header band + caption. Because
Godot's `_draw` is normal-blend, the additive outline/grid/header alphas are
raised a little (outline 0.1 -> 0.5, header 0.25 -> 0.32, grid 0.04 -> 0.06) to
reproduce the additive-over-near-black brightness the engine gets - the geometry
(the chamfer) is exact.

### The text calls

`FUN_100eb270(font, style, x, y, str, halign, valign)` @ `0x100eb270`. **47 call
sites** - found by scanning `.text` for `E8` displacements onto it, because
Ghidra's listing only shows about half.

* `font` indexes the table at `0x10162c60` (stride 0x14), whose four entries are
  **`fonts/ocrb_8pt`, `fonts/ocrb_10pt`, `fonts/ocrb_18pt`, `images/hud/sprites`**.
  Handel Gothic is not in this table: nothing on the flight HUD uses it.
* `style` indexes the alpha table at `0x10162cb0` (stride 8):
  **style 0 = 0.6, style 1 = 1.0, style 2 = 0.75** (times the master alpha).
* `halign` **0 left, 1 right (`x - w`), 2 centre (`x - w/2`)** (`0x100eb390`).
* `valign` **0 top, 1 bottom (`y - h`), 2 middle (`y - h/2 - 1`)** (`0x100eb7a2`).
  The y it takes is the TOP of the line; the baseline is added inside (DrawText
  adds `FcFont+0x24`, the ascent, at `0x100606f6`).

Font index 0 is a **misnomer in the game's own data**. `fonts/ocrb_8pt.frf`'s
FHDR names its atlas `"andale mono_7pt.lbm"`, its family `"andale mono"` and its
point size **7** - and the frf's glyph rects capture **100%** of the ink on
`andale mono_7pt.ftu` against **62.9%** on `ocrb_8pt.ftu`. Font 0 IS Andale Mono
7pt; `ocrb_8pt.ftu` is a stale atlas nothing reads. (Which is why the reticle's
numerics are a different, tighter face than the menu's.)

#### The letter spacing (`m_additional_kern`) - task #65

**The 5th field of each font-table entry is the face's LETTER SPACING**, and it
is the whole of the HUD's kerning:

| idx | font | `+0x10` | `'M'` cell | HUD cell |
|-----|------|--------:|-----------:|---------:|
| 0 | `ocrb_8pt` (Andale Mono 7pt) | **+1** | 5 | **6** |
| 1 | `ocrb_10pt` | **-6** | 15 | **9** |
| 2 | `ocrb_18pt` | **-5** | 20 | **15** |

The HUD's loader (`FUN_100e8220` @ `0x100e8220`) measures `'M'`, adds that field
to get the entry's `char_width`, and stamps the field **straight into
`FcFont::m_additional_kern` (`FcFont+0x34`)**:

    100e8271  call GetGlyph(font, 'M')
    100e827c  sub  edx, edi              ; M.lx1 - M.lx0
    100e8290  fadd dword ptr [esi+0xc]   ; + the entry's spacing
    100e8293  fstp dword ptr [esi+4]     ; -> entry.char_width
    100e82a9  fld  dword ptr [esi+0xc]
    100e82ac  call ftol
    100e82b4  mov  dword ptr [edi+0x34], eax   ; font.m_additional_kern

`FcFont::Kern` (`0x100828e0`) then returns **exactly `m_additional_kern`** for
every pair of every HUD face: the 236 pairs the `FcFont` ctor registers
(`0x100800b0`) all pass `italic=true` and land in the ITALIC table, which no HUD
face reads, and the non-italic table is never populated by any DLL. So the pen
just steps `(lx1 - lx0) + spacing`.

> We got this wrong twice by grepping for a *call* to `SetAdditionalFontKern`
> (`0x10068000`) and finding none. **iwar2 never calls it - it inlines the store.**
> That is what made the arrow menu's OCR-B 10pt advance 15px per character
> instead of 9, i.e. two thirds too wide, which is the whole of task #65.

It lives on the three FcFont **instances in this table**, not in the `.frf`, so
it applies to HUD text and nothing else. The MFD panels, the contacts list and
the stellar-map labels draw the same faces with spacing 0 - in the original, the
map's star labels measure a **5px** cell for `ocrb_8pt`, its raw cell, not the
6px cell the HUD uses. `tools/iw2/fonts.py` therefore emits the raw `.frf`
metrics and `hud.gd` applies the spacing (`HUD_KERN`) on the HUD path only.

#### The metric

The two fonts measure through **different code**, both via `FUN_100ebd70`
(`0x100ebd70`):

**Font 0 never looks at a glyph.** It is a fixed-cell face - the blitter
(`0x100eb689`) steps `entry.char_width` for *every* character, spaces included,
and drops each glyph at `pen + ink_x0` with no bearing trim:

    w = len(str) * char_width      # 0x100ebd7e
    h = ascent + descent           # 0x100ebd8d (the entry's line height)

**Fonts 1 and 2** go to `FcFont::GetTextSize` (`0x100827a0`), whose pen steps the
glyph's LOGICAL width (`lx1 - lx0`, the frf's first and third int32 - `FcGlyph`
reads the ten ints in file order, `0x1007fe60`) plus `Kern(c, next)`; the last
glyph's "next" is the NUL terminator, for which `Kern` returns 0 (`0x100828e4`).
`DrawText` applies the same kern when it renders, not just when it measures
(`0x10060969`). Two trims are NOT optional, and both are visible:

    w = sum(lx1 - lx0) + (n-1) * spacing
        - first.ink_x0                    # 0x10082803
        - (last.lx1 - last.ink_x1)        # 0x1008286f
    h = max(-ink_y0) + max(ink_y1)        # 0x10082883: the INK height of THIS
                                          # string, not the font's line box

and `DrawText` backs the pen up by `first.ink_x0` (`0x1006074d`) so the ink
starts flush on x - the font-0 blitter does not. `hud.gd` reproduces all of it in
`_text_metrics` / `_hud_text`.

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
  `FcLocalisedText::Field` @ `0x100f2142`) - **and nothing else**. The call at
  `0x100f2161` is, argument for argument:

      FUN_100eb270(font 2 = ocrb_18pt, style = (select held) ? 1 : 0,
                   x = 0, y = 0, name, halign 2, valign 2)

  so it is centred on the reticle in both axes and sits at **alpha 0.6** until
  you hold select, when it goes to **1.0**. At 18pt (20px per character) a nine
  letter node name is 180px wide and all but touches the left and right boxes at
  +/-100 - that is the engine's own geometry, not a bug in ours.
* the timeout **only on the ROOT node** (`cmp ebx, [icHUD+0x198]` @ `0x100f20a2`)
  and only under 10 s (`_DAT_101190c0`): `hud_menu_timeout` ("TIME: ") plus
  `AppendFormat("%0.1fs", icHUD+0x1b8)`. The call at `0x100f2124`:

      FUN_100eb270(font 0 = Andale Mono 7pt, style 0, x = 0, y = 30 (0x41f00000),
                   str, halign 2, valign 0)

  We used to draw it on every node, as an integer.

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

(the label call is `0x100eab54`: **font 1, style = held ? 1 : 0, halign 0 LEFT,
valign 2 MIDDLE** - so the label is dim at 0.6 and lights to 1.0 with its rail,
which is on the plain 0.5 / 1.0 pair at `0x100ea949`. `text_width` is the engine
width, trims and all: `FUN_100ea830` measures with `FUN_100ebd70(1, ...)`, the
same measure `FUN_100eb270` uses.)

The label is drawn **8px left of the rail**, and the rail is **16px shorter than
the label**, so the text overhangs 8px into each chevron: the box reads
`<[ LABEL ]>`. That is why it is a rail primitive and not a rectangle.

### A carousel puts its selected item in the LEFT box

`FUN_100f0420` @ `0x100f0420` - the carousel's refresh, run after every step -
**rewrites the carousel's own direction links**:

    +0x1c (LEFT)  = items[sel]                 the selected command itself
    +0x14 (UP)    = PREV, or NULL at sel == 0
    +0x18 (DOWN)  = NEXT, or NULL at the last item  (3 < sel + 1)
    +0x20 (RIGHT) = untouched - the way back out

and while the autopilot is engaged (`icPlayerPilot+0x308` != 0) it swaps LEFT for
the DISENGAGE node (`+0x58`) and NULLs both PREV and NEXT. So the item is an
ordinary **node box on the left**, drawn by the same loop as every other link,
and the reticle's centre only ever holds the carousel's own name. Walking LEFT
runs the command (`FUN_100efaf0`, the default direction handler, just follows the
link). The autopilot's slots `+0x40..+0x4c` are, in order,
**approach / formate / pursuit / dock**, with sprites **21 / 22 / 23 / 24** in
**amber** - so the selected item's box carries its mode glyph. Every wingmen and
T-fighter item goes through `FUN_100efc30`, which is
`FUN_100efbb0(name, sprite 0, chartreuse)`: plain green, no icon.

### The rest of the reticle's text

The same call, the same style table, but not the same font - checked against all
47 call sites:

| string | call site | font | style |
|---|---|---|---|
| own speed, left of the reticle | `0x100f7076` | 0 (Andale 7pt) | 2 (0.75), halign 1, valign 2 |
| target `"<hull%> <NAME>"` | `0x100f7f2b` | 0 (Andale 7pt) | 2 |
| **target range** | `0x100f7ffe` | **1 (ocrb_10pt)** | 2, at `x - 1` |
| target `"<speed>m/s"` | `0x100f812c` | 0 (Andale 7pt) | 2 |
| target LDS destination | `0x100f8070` | 0 (Andale 7pt) | 2 |
| no-target placeholder (`DAT_10174124`) | `0x100f8149` | 1 (ocrb_10pt) | 2 |

**The range is the one line in the reticle that is not in the little Andale
face** - it is set in OCR-B 10pt, roughly twice the size of the name above it,
and the block's line steps follow each line's own font (`0x10162c6c` for font 0,
`0x10162c80` for font 1). We had the whole block in font 0, which is why it read
flat. All six are style 2 = **alpha 0.75**, not the 0.95/0.7 we were passing.

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

1. ~~How a carousel node displays its selected item.~~ **RESOLVED** - see "a
   carousel puts its selected item in the LEFT box" above. `FUN_100f0420` writes
   `items[sel]` into the carousel's own `+0x1c` LEFT link, so the item is drawn
   by the ordinary node-box loop. The "AUTOPILOT: APPROACH" composite the earlier
   pass invented is gone; the centre is only ever `Field(node+8)`.
2. **`hud_menu_cancel`'s place in the tree.** It is built (red, sprite 0x1f) but
   we did not find who links it.
3. **The subsim flag bits above 0x10.** `+0x68` bits 0/2/3/4 are pinned (see the
   table above); 0x20, 0x40, 0x80, 0x100, 0x200 are set in several places and
   the status strip does not read them.
4. **The exact glyph the engine gets for `icShip+0x138`'s ordering.** We iterate
   `ship_systems.gd`'s `systems` array, which is INI mount order. The engine's
   component list is built by `icShip::OnAttachSubsim` in the same order, but we
   have not proved no other code reorders it.
5. ~~**The fifth float in each font-table row**~~ - **RESOLVED (task #65)**. It is
   the face's **letter spacing**, and it is the reason the arrow menu's text was
   two thirds too wide. `FUN_100e8220` (`0x100e8220`) reads it at `[esi+0xc]`
   while walking the table with a computed pointer - which is exactly why the
   xref search on `0x10162c70` came up empty - and stores it into
   `FcFont::m_additional_kern` (`0x100e82b4`). See "The letter spacing" above.
   **Moral: a data address with no xref is not unread; it may be walked.**
6. **Whether the reticle's "set speed" second line exists in the original.** The
   velocity readout at `0x100f7076` is one call; we draw a second line under it.

---

# NAVIGATION LOCK vs TARGET LOCK, and the flight-HUD palette (nav-lock pass)

A side-by-side pass on the flight HUD. Task: a base set as the nav / BASE-RETURN
target was drawing "TARGET LOCK" with a 3D EO render, where the original shows
"NAVIGATION LOCK" with a class icon and no render, plus questions about colour,
the shield-panel position and the weapon panel. Everything below is out of
`iwar2.dll` (image base `0x10000000`), verified against a windowed screenshot
(`--hudnavshot`, `build/shots/hud_navlock.png`).

## The MFD mode is chosen by the CLASS-ICON lookup, not "is it a ship"

Mode select is `FUN_10102930` @ `0x10102930` (in the decomp). It keys off the
target sim's category (`sim+0x194`):

- `== 4` (waypoint) -> `FUN_10102f70` = **mode 3** (NAVIGATION LOCK)
- `== 0xc` (cargo pod) -> `FUN_10102a40` = **mode 4** (UCP SCAN)
- **else** -> `FUN_10102e30` = the mode-2 handler, **which is not unconditional**.

`FUN_10102e30` @ `0x10102e30` first calls `FUN_100e86d0(sim)`; **if that returns a
non-zero class-icon sprite it redirects to `FUN_10102f70` (mode 3)** and only
stays mode 2 (the 3D EO render) when the lookup returns 0.

`FUN_100e86d0` @ `0x100e86d0` (in the decomp):

    cat = sim+0x194
    if cat == 2:    return DAT_1011dbe4[ sim+0x218 ]      # ship-type table
    if cat != 0xe:  return DAT_1011db64[ cat ]            # category table
    # cat == 0xe (icStation): 0x3a/0x3b by sub-type +0x1e4, 0x3d in [0x14..0x19]

Both tables read out of the PE (`tools/ghidra/readconst.py`):

    DAT_1011db64 (category): [0, 54, 0, 47, 47, 60, 0,0,0,0, 0, 58, 0,0,0,0]
    DAT_1011dbe4 (ship-type): [0, 54, 55, 57, 56, 58, 56, 0]

So the **only** targets that get the 3D render (mode 2, icon 0) are a bare
category-2 ship of ship-type 0. Waypoints (cat 4 -> 47), L-points (cat 5 -> 60),
category-0xb objects (-> 58), **stations/bases (cat 0xe -> 58/59/61)** and
typed ships (types 1-6 -> 54..58) all return a non-zero glyph and therefore draw
as **mode 3 NAVIGATION LOCK with a class icon and no EO feed.**

That is the fix: **a targeted base is a station (cat 0xe), so it is a NAVIGATION
LOCK, not a TARGET LOCK.** The remaster was routing everything that was not an
lpoint/waypoint to mode 2. `hud.gd::_draw_mfd` now routes `station`/`gunstar`/
`base` (as well as `lpoint`/`waypoint`) to mode 3, with the class icon from
`_nav_class_icon` (lpoint 60, waypoint 47, station 58).

### The captions are literal

Loaded once by `FUN_100e8470(0x12, 0x10163bd0, &DAT_10176330)` from the 18-key
table at `0x10163bd0`; resolved through `data/text/hud.csv`:

| key | text |
|---|---|
| `hud_target_target_mode` (mode 2) | **"TARGET LOCK"** |
| `hud_target_waypoint_mode` (mode 3) | **"NAVIGATION LOCK"** |
| `hud_target_waypoint_details` (mode 3 line 2) | **"WAYPOINT"** |
| `hud_target_no_target` / `hud_target_ucp_scan_mode` | "NO TARGET" / "UCP SCAN" |

Line 2 is `hud_target_waypoint_details` = "WAYPOINT" for **every** mode-3 lock —
so a base reads "LUCRECIA'S BASE / WAYPOINT", exactly the reference.

## Colour: the flight HUD is GREEN chrome + amber accents, NOT amber + purple

The side-by-side description called the reticle/lock/orb chrome "amber" and the
nav elements "purple". **The shipped `iwar2.dll` does neither.** Recovered:

- **Reticle ring** = `DAT_10176038` **green** (0.5,1.0,0). `FUN_100f6340` @
  `0x100f6352` sets the active colour to `DAT_10176038` and blits ring sprite 90
  under it (`0x100f635f`), unconditionally — there is no per-lock recolour of the
  ring.
- **Nav / waypoint contact colour** = `DAT_10176038` **green**. `FUN_100e8530` @
  `0x100e8530` (the one place a contact's colour is chosen): unidentified -> gold
  `DAT_10174f60`; **category 4 or 5 -> green `DAT_10176038`** (lines with
  `param_2[0x65]==4||==5`); `+0x199` -> light blue `DAT_10174190`; else the IFF
  table `DAT_10174f70` (0/1 red, **2 neutral gold**, 3/4 blue). A base is IFF 2 ->
  **gold**, not purple.
- **The magenta/purple** `DAT_10174180` (0.9,0.1,1.0) **is initialised
  (`0x100e6...`) but never read anywhere in the image** — no draw site reinterprets
  it. There is no purple nav crosshair in this binary.
- **Amber `DAT_10174fb0`** (1.0,0.592,0) is used, deliberately and narrowly, for:
  the MFD's two text lines; the weapon charge rows (`FUN_101053e0`); the shield
  rows; and the reticle's status/gauge icons — the four autopilot mode glyphs
  (`FUN_100f93c0(...,&DAT_10174fb0,0xb)` @ `0x100f7... 187938`), the
  system-down icon (`187978`), the thermometer/lightning/bulb gauges
  (`188006`) and the incoming-missile pip. The LDS/capsule/team icons and the
  contacts orb are green (`188022`..`188048`, `&DAT_10176038`).

So the outer ring is green, unconditionally. The coloured mark the divergence
list called a "purple X" is a **separate element drawn over the ring** — the
INNER reticle target marker — and its colour is the target's **allegiance**
(blue for a friendly "don't shoot", red hostile, gold neutral, green nav), not a
fixed purple. That element was genuinely missing from the remaster; it is
recovered and implemented below. (The magenta `DAT_10174180` really is never
read; the friendly blue is `DAT_101740b8`.)

## The inner reticle — the allegiance-coloured target marker

A SECOND marker, drawn on and over the green outer ring, centred on the reticle,
in the **target's own colour**. Recovered in full from three functions Ghidra
kept (`FUN_100f76a0` / `FUN_100f7920` / `FUN_100f7b10`), dispatched by the reticle
master `FUN_100f6340`:

- The master sets the active colour to the **target contact's colour**
  (`icHUD+0x120`, at `0x100f647c`: `pFVar3+0x1778 = *(iVar5+0x120)`) *before*
  drawing the marker, so the marker inherits it.
- **In-reticle** (target within `(_DAT_1011e038 + _DAT_101190c0)` = 63+10 px of
  centre): `FUN_100f76a0` @ `0x100f76a0`. Sprite by target category
  (`param_1[3]`), all from **reticle.png** (texture 2), drawn NATIVE:
  * cat 4/5 (waypoint / L-point) -> **sprite 94**, blitted **4-mirror**
    (`FUN_100ea7e0`, flags 0/1/3/2) into a symmetric marker;
  * a moving target (`param_1[10] != 0 || *(sim+0x20) < 3`) -> **sprite 93**,
    four copies **spun** about the centre (angle on `reticle+0x20`);
  * else (static ship / station) -> **sprite 92**, 4-mirror — the **X-in-ring**.
- **Off-reticle**: `FUN_100f7920` (an edge chevron, sprite 35, rotated to the
  bearing) + `FUN_100f7b10` (the class glyph pulled to the ring edge: 47/60 for
  cat 4/5, 44/45 otherwise).

The sprite cells were read out of the table builder (`0x100e7f00`ff, verified
against the known 90/91/93):

| sprite | reticle.png cell | origin | role |
|---|---|---|---|
| 92 | (186, 0, 70, 70) | (70, 0) | static in-reticle marker (the X) |
| 93 | (0, 186, 70, 70) | (0, 70) | moving-target marker (spun) |
| 94 | (186, 80, 70, 70) | (70, 0) | waypoint / L-point in-reticle marker |

### The allegiance -> colour map (`FUN_100e8530` @ `0x100e8530`)

The marker colour is the contact colour, and `FUN_100e8530` is the single place
that colour is chosen (the ORB and contact list copy it too). Full recovered map:

| target state | colour | DAT |
|---|---|---|
| unidentified | gold | `DAT_10174f60` (1.0,0.8,0) |
| category 4/5 (waypoint / L-point) | green | `DAT_10176038` (0.5,1,0) |
| `sim+0x199` set | light blue | `DAT_10174190` (0.3,0.6,1) |
| IFF 0/1 (hostile) | red | `DAT_10176018` (1.0,0.07,0) |
| IFF 2 (neutral, the default) | gold | `DAT_10174f60` |
| **IFF 3/4 (friendly)** | **blue** | **`DAT_101740b8` (0.1,0.1,1)** |

So the "blue X for friendlies" the user described is IFF 3/4 -> `DAT_101740b8`.

### What we implemented

`hud.gd::_reticle_marker` draws the inner marker centred on the reticle whenever a
target is in-reticle, 4-mirror, in `_target_color()` (which now returns the
allegiance colour: hostile red, non-hostile ship friendly blue, nav green,
station/neutral gold). Sprite 92 for ships/stations, 94 for waypoint/L-point.
Verified with `--hudnavshot`: `build/shots/hud_hostile.png` (red X),
`hud_friendly.png` (blue X), `hud_navlock.png` (gold X, base) — each marker a
distinct colour over the same green ring.

**Limits / UNKNOWN.** (1) Our sim carries a category and a hostile flag
(`behavior == "attack"`) but no per-contact **IFF feeling**, so friendly-vs-neutral
cannot be told apart from data: we follow the codebase's existing convention
(non-hostile ship -> friendly blue, station/object -> neutral gold). A genuine
neutral trader would read blue here where the engine would read gold; a
main-side IFF/feeling hook would fix that (see the report). (2) The moving-target
**sprite-93 spin** (select condition `param_1[10]` / `*(sim+0x20) < 3`) is not
mapped to our data, so we draw the static 92 for all ships. (3) No **cyan**
appears in `FUN_100e8530`; if the game ever shows a cyan/other marker it is a
mission script overriding a specific contact's colour, not this path.

## Shield panel position: under the ORB

`flux.ini [icHUD]` draw order is `... OrbRadar(7), Shields(8), Clock(9) ...`, all
right-anchored, so the stack top-to-bottom on the right is **ORB -> SHIELD STATUS
-> CLOCK**. The remaster anchored the shields at the screen margin (on top of the
ORB). `hud.gd` now threads a right-hand cursor `_rhs_y`: `_draw_orb` seeds it at
the ORB's bottom, `_draw_shield_panel` draws there and advances it, and the clock
lands under the shields. With no `icPlayerLDA` fitted the shields block is
height 0 and the clock falls straight under the ORB (matches `FUN_100e2540(this,
112, 0)`).

## Weapon panel: one row per GROUP

`icHUDWeapons` heads the block with the selected weapon **group's** own localised
name and draws one row per `iiWeapon` member. A linked "QUAD LIGHT PBC" is ONE
group -> ONE row. The remaster was splitting `main.weapon_name` on `"/"` to draw a
two-row "L-PBC / R-PBC" pair — invented. `hud.gd` now always draws the single
group row (`rows := 1`). The group NAME comes from `weapons.group_label()`
(main.gd owns the fit).

**Non-issue:** the "QUAD LIGHT PBC" the reference showed is simply a **different
ship's loadout** (weapons are customised at base and differ per hull), not a HUD
bug. Our single-row panel is correct; whatever the fitted group's `group_label()`
returns is the right caption. No change needed beyond the single-row fix.

---

## Reticle collisions + the warning font (task #67)

- **The own-speed readout's right anchor is −100, not −82**: the reticle
  master's `FUN_100eb270` call @ `0x100f7076` passes
  `-(_DAT_1011e034 + _DAT_101190b0)` = −(80+20). Our −82 borrowed the target
  block's `TEXT_X` (a different anchor, 80+2, right side). Fixed (`SPEED_X`).
- **The menu replaces the reticle readouts.** The menu reticle's LEFT box
  right-aligns on exactly the same −100 anchor the speed text right-aligns on,
  so the engine can never display both; and the pills' boxes cross the r=110
  status-icon ring. While `menu_active` we now suppress the speed/set-speed
  readouts and the status-icon ring — this kills both reported collisions
  (velocity vs NAV pill, CMD pill vs capsule icon). Inference from the shared
  anchor, not a decompiled branch — flagged as such.
- **Warnings draw in OCR-B 18pt.** The reticle warning flasher is our
  reconstruction (no hud.csv key); the HUD's text system can only draw the
  font table at `0x10162c60` = ocrb_8pt / ocrb_10pt / ocrb_18pt (+ sprites).
  `handelgothic bt_12pt` DOES ship (`fonts/handelgothic bt_12pt.frf`) — the
  old "fabricated font" concern is dead — but it is the base GUI's
  "largenumber" font (`ibasegui.pog:6`), never a HUD face. The front-end
  fancy buttons, meanwhile, use `GUI_title_font` = square721 bdex bt_8pt
  (`igui.pog:31/245`); menu.gd now does too.
