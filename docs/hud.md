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
