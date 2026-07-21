# The solar systems: `geog/*.map`

How a system is loaded and drawn in the original, read out of the binary. The
short version lives in `original.md`; this is the full record.

Everything below comes from **`icSolarSystem::Load`** (`iwar2.dll @ 0x1004bb60`)
and the functions it calls. That one function settles the whole format: it
allocates `count * sizeof(sEntity)` with `sizeof(sEntity) == 0x168` (**360**),
reads the block in one `FcTextFile::Read`, and then `switch`es on the record's
**first byte** to decide which class to construct.

---

## 1. The record

The header is a **u32 big-endian count** and nothing else. The "version byte" we
used to skip at offset 4 is the first record's `kind`, and it is 0 (the system
centre is a body) in every shipped map -- which is exactly why it looked like
padding. **Every field we had was one byte off.**

| off | type | meaning | source |
|---|---|---|---|
| `+0x000` | u8 | **kind** (the switch below) | `icSolarSystem::Load` |
| `+0x001` | char[263] | name, NUL-terminated (rest is dirty buffer) | `FcString(psVar1 + 1)` |
| `+0x108` | f64[3] | position x, y, z, meters, system-centric | `FiSim::SetPosition` |
| `+0x120` | f32[4] | **orientation quaternion, stored (w, x, y, z)** | `FiSim::SetOrientation` |
| `+0x130` | u16 | parent record index | `this+0x1da`, used to look the parent sim up |
| `+0x134` | u32 | kind-dependent info word (see below) | |
| `+0x138` | f32 | **BODY RADIUS, meters** | `FiSim::SetRadius`, in `icPlanet::Load` and `ParseSunInfo` |
| `+0x13c` | u8 | body: `icPlanet::eType` -- 1 rocky, 2 gassy | `icPlanet::Load` -> `icPlanet+0x1e0` |
| `+0x13d` | u8 | body: `SurfaceType(0)` | -> `icPlanet+0x1e4` |
| `+0x13e` | u8 | body: `SurfaceType(1)` | -> `icPlanet+0x1e5` |
| `+0x13f` | u8 | spare (`0xbf` in every shipped record) | |
| `+0x140` | f32[9] | three RGB colours, **0-255** | `icPlanet::ReadColour`, scales by `_DAT_1011b068` = `0.00392157` = 1/255 |
| `+0x164` | i8 | body: atmosphere texture index; **-1 = no atmosphere** | -> `icPlanet+0x200` |
| `+0x165` | u8 | body: **ring count** (0, or 4..8) | `icPlanet::NumberOfRings` |
| `+0x166` | u8[2] | padding | |

The quaternion layout is `(w, x, y, z)`, not `(x, y, z, w)`: every non-L-point
record reads `(1, 0, 0, 0)` and all 76 L-points are unit-norm with a pure yaw.

**A field is only valid for the kinds that write it.** The map writer reused one
360-byte buffer between records, so a station's `+0x138` is whatever its parent
body last put there -- which is how `Junkyard` came to have a "radius" of
1.75e11 m. Read a field only for the kind that owns it.

### The kind byte (`icSolarSystem::Load`'s switch)

| kind | class | parse | notes |
|---|---|---|---|
| 0 | `icPlanet` | `ParseBodyInfo` @ `0x1004e040` | record 0 is the system centre (body type 0, radius 0) |
| 1 | `icStation` | `ParseLocationInfo` @ `0x1004e0a0` | |
| 2 | `icLagrangePointWaypoint` | inline | radius **hard-coded to 500 m** |
| 4 | `icAsteroidBelt` | `ParseAsteroidBeltInfo` @ `0x1004e6b0` | belt radius is the **f32 at `+0x134`**, not `+0x138` |
| 5 | `icSun` | `ParseSunInfo` @ `0x1004e5a0` | |
| 6 | (gunstar) | `ParseGunstarInfo` @ `0x1004e730` -- **empty** | and `Load` **skips `AddSim` for kind 6**: these records are inert |
| 7 | `icNebula` | `ParseNebulaInfo` @ `0x1004e4f0` | nebula radius is the **f32 at `+0x134`**, like a belt -- one record in the whole game |

Counts across the shipped maps: 608 bodies, 756 stations, 76 L-points, 30 suns,
21 belts, 11 gunstars, 1 nebula.

### The nebula record (kind 7) -- The Effrit

`ParseNebulaInfo` is three lines, and the first is the one that matters:

```c
FiSim::SetRadius((FiSim *)nebula, *(float *)(entity + 0x134));   // NOT +0x138
```

It then allocates a plain `icGeography` (`0x10066610`, `0x1e8` bytes) of the same
radius and attaches it as a child at the origin -- a bare collision/geography
proxy, no avatar.

We used to zero this radius, which is why the one nebula in the game had no
volume for the player to be inside of. It is now read:

| | |
|---|---|
| name | **The Effrit** |
| system | Hoffer's Wake (`hoffers_wake`, record 36) |
| position | `(7.2765e8, 0, 1.2603e9)` m, system-centric |
| radius | **2.5e8 m** (`info_f`) |
| parent | record 1 |

**Lucrecia's Base sits 750 m from its centre** -- the campaign's home base is
buried at the very heart of it, so the whole of Act 0 is flown inside a nebula.
That is what the player means by "cloudy all around you".

The record carries no other fields. `icNebula`'s three properties -- `depth`,
`colour`, `texture_url` (property map `0x100674f0`) -- have no home in the map
format, so The Effrit runs on the class constructor's defaults (`0x10067660`):
`depth = 30000` m, `colour = (0.6745, 0.2784, 0.0824)` = `(172, 71, 21)`,
`texture_url = texture:/images/sfx/cloud`. The only sim that ever overrides them
is the multiplayer template `sims/multiplayer/fog_cloud_10000k.ini`
(`radius = 1e7`, `depth = 1e4`, `colour = (0.1, 0.55, 0.44)`, texture
`images/sfx/alien_cloud`), which is how the deathmatch fog arenas are built.

`classify_map.py` now emits `radius`, plus `depth` / `nebula_colour` /
`texture_url` carrying those defaults. **What a nebula looks like from inside is
in `effects.md`** (`icCloudAvatar`).

---

## 2. Body radius -- the `+311` field was never a "map zone radius"

`icPlanet::Load` (`0x10067eb0`) and `ParseSunInfo` both do

```c
FiSim::SetRadius((FiSim *)this, *(float *)(entity + 0x138));
```

That is the body's **physical radius in meters**, and `FiSim::Radius()` is the
same value `icAITarget::CheckLDSAvoidance` and `icSun::Think`'s heat model use.
There is no separate size field anywhere and no derivation.

Our old extractor was reading the right float (its `+311` is this `+0x138`, one
byte of header apart) and then **throwing the value away**: it clamped it to
`8e7` and to half the nearest-neighbour distance. That clamp -- not the format
-- is what made every body the wrong size.

Sanity, from the shipped maps:

| | |
|---|---|
| 608 bodies | min 0, median **5.6e6 m**, p90 6.7e7 m, max 2.6e8 m |
| rocky bodies (`eType` 1) | 8.7e4 .. ~2e7 m -- moons to super-Earths |
| gas giants (`IeBodyType` 4) | 3.2e7 .. 2.6e8 m (Jupiter is 7.1e7) |
| 30 suns | 2.0e7 .. **1.75e11** m |

The suns are **genuinely enormous** in the authored data and that is not a
decode error: `Hoffer's Wake Alpha` really is 1.75e11 m (251 solar radii, class
11 = red), while its companion `Hoffer's Wake Beta` is 1.81e8 m (a plausible
star). The engine takes the number at face value -- `icSun::CreateAvatar` builds
an `FcSphereCollider` of that radius and scales the sun avatar to it. So a few
IW2 stars are hypergiants by design. We render what the map says.

**Only bodies with `1 < IeBodyType < 5` are drawn at all.** `icPlanet::CreateAvatar`
(`0x10067fe0`) gates on exactly that, which is why the system-centre record
(type 0) and the four type-6 records are invisible. Distribution of
`IeBodyType`: 0 x23, 2 x121, 3 x398, 4 x62, 6 x4. **Type 4 is the ringed gas
giant** -- it is the only type that gets rings, and it never gets an atmosphere.
`ParseBodyInfo` additionally registers types 1..6 (`1 << t & 0x7e`) in the
system's LDS-obstacle list.

---

## 3. Stars

### The class picks the texture

`icSunAvatar`'s constructor (`FUN_100d2910 @ 0x100d2910`) branches on
`icSun::eClass`, which is the byte at record `+0x134`:

```c
cls = sun->m_class;                                  // icSun+0x1e0
if      (cls < 3) tex = icPlanetProperties + 0x20;   // images/planets/sun_blue
else if (cls < 7) tex = icPlanetProperties + 0x18;   // images/planets/sun_yellow
else              tex = icPlanetProperties + 0x1c;   // images/planets/sun_red
```

(The four texture slots are loaded in `icPlanetProperties::LoadTextures`,
`0xcbc90`: `+0x14` `sun_halo`, `+0x18` `sun_yellow`, `+0x1c` `sun_red`,
`+0x20` `sun_blue`.) `icSun`'s default class is 6 (yellow). Classes observed in
the shipped maps: 0..15.

The avatar is **scaled to `FiSim::Radius()` on all three axes**, and its bounding
radius is set to `radius * 1.4` (`_DAT_1011a440`, also stored at the node's
`+0xb0`). That extra 40% is the corona -- which is what `sun_halo` is for.

### The class also picks the colour

`icSun::PickColour(eClass)` (`0x1006ac70`) is one line:

```c
FcColour::LERP(out, &m_colours[cls * 2], rand_weight);   // lerp(pair[0], pair[1])
```

`icSun::m_colours` is **16 pairs** (32 `FcColour`s) at `0x101665c0`. It is
written by a runtime static-init (`FUN_10069f70`), so it reads as zeros in the
file -- the values have to be taken from that function's constants:

| class | colour A | colour B |
|---|---|---|
| 0 | (0.05, 0.05, 1.00) | (0.40, 0.50, 1.00) |
| 1 | (0.30, 0.35, 1.00) | (0.70, 0.80, 1.00) |
| 2 | (0.40, 0.60, 1.00) | (1.00, 1.00, 1.00) |
| 3 | (1.00, 1.00, 1.00) | (1.00, 1.00, 0.15) |
| 4 | (1.00, 1.00, 0.90) | (1.00, 0.80, 0.05) |
| 5 | (1.00, 0.90, 0.90) | (0.90, 0.80, 0.05) |
| 6 | (1.00, 0.90, 0.80) | (0.85, 0.90, 0.15) |
| 7 | (1.00, 0.90, 0.40) | (1.00, 0.40, 0.15) |
| 8 | (1.00, 0.70, 0.30) | (1.00, 0.30, 0.05) |
| 9 | (1.00, 0.50, 0.20) | (1.00, 0.10, 0.05) |
| 10 | (1.00, 0.30, 0.05) | (1.00, 0.05, 0.05) |
| 11 | (1.00, 0.30, 0.05) | (1.00, 0.05, 0.05) |
| 12 | (1.00, 0.30, 0.05) | (0.90, 0.05, 0.05) |
| 13 | (0.80, 0.15, 0.05) | (0.80, 0.05, 0.05) |
| 14 | (0.60, 0.05, 0.05) | (0.70, 0.05, 0.05) |
| 15 | (0.50, 0.05, 0.05) | (0.60, 0.05, 0.05) |

Blue-white through white, yellow, orange, to red: a stellar sequence, sixteen
steps. It is a *range* per class, and each star rolls once inside it.

### What is actually attached

`icSun::CreateAvatar` (`0x1006a960`) attaches, in order:

1. the `icSunAvatar` node above (textured, scaled to the radius),
2. an `FcLensFlareNode` (mode `+0xbc = 0`, size `+0xe4 = radius`),
   coloured by `PickColour`,
3. a second `FcLensFlareNode` (mode 2), child of the first, whose variant field
   `+0xe8` is **3 when class <= 2 and 1 otherwise**.

`icSun::UpdateAvatar` (`0x1006a4b0`) then, every frame, **pushes the first flare
toward the camera** (20 m in front of the eye along the sun bearing,
`_DAT_101190b0`) and drives both flares' intensity envelopes from
`distance / radius`. RECOVERED in full (constants read from the PE):

The distance metric is the octagonal norm `max + 0.34375*mid + 0.25*min`
(`_DAT_101191f0` / `_DAT_101191ec`) of |dx|,|dy|,|dz|, divided by the sun's
radius (`this+0x1c`) -- so **r is measured in sun radii**.

**The camera-pushed flare** (envelope at avatar `+0xd0`), piecewise linear:

| r (radii)  | intensity                          | segment          |
|------------|------------------------------------|------------------|
| < 5        | 1.0                                | full             |
| 5 .. 25    | `0.5 + (25 - r) * 0.025`           | 1.0 -> 0.5       |
| 25 .. 75   | `0.15 + (75 - r) * 0.007`          | 0.5 -> 0.15      |
| 75 .. 125  | `(125 - r) * 0.003`                | 0.15 -> 0        |
| >= 125     | 0                                  | off              |

(breakpoints `_DAT_101183f0`=5, `_DAT_101190b0`=20, `_DAT_1011a1c0`=50;
slopes `_DAT_1011b35c`=0.025, `_DAT_1011b358`=0.007, `_DAT_1011b350`=0.003;
levels `_DAT_10117738`=0.5, `_DAT_1011b354`=0.15.) The flare therefore
ignites at **125 sun radii** and steepens as you close -- for Hoffer's Wake
Beta (radius 1.81e8 m) the onset is 2.26e10 m = ~22.6 million km, and the
"all at once" leg is the last 5 radii.

**The sphere node** (avatar `+0x18`): its `+0xe0` field rises
`clamp(r * 0.008, 0, 1)` (`_DAT_1011b348`; reaches 1 exactly at
`_DAT_1011b34c` = 125 radii), and its own `+0xd0` envelope holds
`(1 - clamp(r * 2e-05, 0, 1)) * 0.05` (`_DAT_1011b340`, clamp knee
`_DAT_1011b344` = 50000 radii, scale `_DAT_1011a198` = 0.05) -- a near-flat
0.05 within any system.

**The SIZE law -- `FcLensFlareNode::Render` (flux `0xe6100`), now read.**
The flare is a billboard quad whose WORLD half-extents are the camera right/up
axes scaled by `local_64`, and whose vertex colour is `colour^2 * local_58`
(`local_58 = node+0xe0`, the sphere-node size base above). `local_64` starts as
the envelope value and is then sized by the `node+0xe8` flag byte:

- **bit `0x8` CLEAR (distance billboard):** `local_64 = envelope * viewdist`
  (`viewdist` = `FUN_1004ca50`, the node's distance from the eye). World size
  proportional to distance is **constant SCREEN angular size** -- the sprite
  holds a fixed on-screen size and only its brightness/alpha rides the envelope.
- **bit `0x8` SET (screen-relative):** `local_64 = param+0x108 (screen scale)
  * node+0xe4 (= radius for mode 0) * envelope`, gated by `m_cull_detail`
  (drop if too small) and `m_point_detail` (draw as a single point). Size then
  scales with the sun's authored RADIUS -- so a big star's flare is genuinely
  larger.
- Common tail: `local_64 = m_intensity_scale * local_64`; the vertical extent
  carries `m_global_anamorphic_distortion * node+0xcc`; a second pass draws the
  anamorphic streak (`m_anamorphic_streak_width_ratio`) when `node+0xe8 & 2` or
  the global distortion is high.

Which bit the sun's pushed mode-0 flare sets is the remaining unknown, and it is
the crux: distance mode -> constant screen size (brightness-only bloom); screen
mode -> size proportional to radius, which would make Alpha (radius 1.75e11 m,
~1000x Beta) render a vastly larger flare than Beta at the same envelope. That
one bit, plus a check that Alpha's authored radius is read right, decides the
Alpha-at-spawn look and needs an in-engine comparison against an original
capture to settle.

**The sun-avatar draw holes, now disassembled** (`disasm.py`, Ghidra dropped
them):
- `0x100d2b30` -- the avatar **Prepare**: accumulates a spin phase at `+0xe0`
  (a double) by `game_delta * 0.010472` (`0x1011d248`, = 0.6 deg/s), then
  `FUN_100cf3a0(this, this+0xbc, 1)` and `FiSceneNode::Prepare`.
- `0x100d2b80` -- the avatar **draw**: `FcGraphicsEngine::Push`, a size/colour
  from `this+0x5c * 1.3` (`0x1011d250`), `FindWorldOrientation`, then transforms
  the orientation columns by the camera axes and takes `-atan2(...)` (`fpatan`)
  to spin the billboard sprite to a screen angle -- this atan is the sprite
  ROTATION, not a size law (correcting an earlier over-claim). This is the
  corona/halo billboard that carries the star's surface texture, drawn oriented
  and scaled by the sun radius -- so at ~1.5 radii (Beta from 270-300k km) it
  subtends a large angle and its texture reads through, exactly as observed.

---

## 4. Planets

`data/ini/planets.ini` is loaded into the `icPlanetProperties` singleton
(`LoadTextures` @ `0xcbc90`, arrays at `+0x40` rocky, `+0x4c` gassy, `+0x64`
atmosphere). `icPlanetAvatar`'s shader setup, `FUN_100cdc50 @ 0x100cdc50`, is
the whole answer to "how does a planet choose its look":

```c
switch (planet->Type()) {                    // record +0x13c
  case 0: /* no surface texture at all */    break;
  case 1: tex0 = rocky [planet->SurfaceType(0)];   // record +0x13d
          tex1 = rocky [planet->SurfaceType(1)];   // record +0x13e
          break;
  case 2: tex0 = gassy [planet->SurfaceType(0)];
          tex1 = gassy [planet->SurfaceType(1)];
          if (planet->BodyType() == 4) { ...rings... }
          break;
}
has_atmosphere = (signed char)planet->m_atmosphere >= 0;   // record +0x164
two_surfaces   = tex0 && tex1 && !has_atmosphere;

layer0: tex0,                          tint = SurfaceTint(0)
layer1: tex1,                          tint = SurfaceTint(1)      if two_surfaces
layer2: atmosphere [planet->m_atmosphere],
        tint = lerp(lerp(SurfaceTint(0), SurfaceTint(1), rand), White, rand)
                                                                  if has_atmosphere
```

So:

- **Rocky vs gassy is authored**, in the record, at `+0x13c` (486 rocky, 122
  gassy across the game).
- **The texture is authored**, as an index into the `planets.ini` array for that
  class. `Cracks` is rocky index 7; `gas4` is gassy index 9.
- **The colour is authored**: `SurfaceTint(n)` is the record's colour n over 255.
  `planets.ini`'s `colours[]` really is the last resort it says it is -- nothing
  in the render path reads it.
- **The atmosphere is authored**: `+0x164` is a direct index into
  `atmosphere_planet_textures[]`, with `-1` (0xff) meaning none. Across the game:
  339 bodies have no atmosphere, 269 have one of clouds1..4.
- **A cloud layer and a second surface layer are mutually exclusive** -- with an
  atmosphere you get surface0 + clouds, without one you get surface0 + surface1.
- **Rings**: `NumberOfRings()` is `+0x165`, and rings are only built for
  `IeBodyType == 4`. `icPlanet::Load` refuses to give a ringed body an
  atmosphere. Each ring's radius is `FcRandom::Float(1.75, 2.44) * FiSim::Radius()`
  (2.44 = `_DAT_1011d07c`), from an `FcRandom` **seeded with the body's radius**
  (so it is stable), and its colour is `SurfaceTint(0)`'s hue with value
  `FcRandom::Float(0.2, 0.8)`.

**NOT RECOVERED:** the ring's *width*, and the atmosphere shell's exact blend --
the planet avatar's draw (`0x100ccbb0` / `0x100ccc60` / `0x100ccc80`) is also
left undisassembled. `atmosphere_height = 1.1` in `planets.ini` is the shell
scale.

---

## 5. Stations: the model is in the record

`ParseLocationInfo` (`0x1004e0a0`) does **not** guess from the name:

```c
scene = entity[0x134];
FiSim::Create( icStation::Scene(scene) );   // -> a sim INI path
```

`icStation::Scene(n)` (`0x100698c0`) is `FcINIFile::NumberedString(m_scene_ini,
n, "Stations", "Scene")` -- i.e. **`station_creation.ini` `[Stations] Scene[n]`**,
whose 37 entries are `ini:/sims/stations/*`; each of those has an `[Avatar]`
naming the LWS scene. All 756 station records resolve, and they resolve
*correctly*: "Ottawa Maas Shipyard" is scene 7 = `ShipYardStation`, "Tishomingo
Exile Agricultural Settlement" is scene 2 = `OrbitalGarden`.

`icStation::Load` (`0x10068f70`) reads three more bytes:

| off | meaning |
|---|---|
| `+0x135` | station sub-type (0..122) -- **not identified** |
| `+0x136` | **faction allegiance**, passed to `icFactions::FindFactionByAllegiance` |
| `+0x137` | quantised 3/5/10/15/.../250 -- **not identified** (tech level? wealth?) |

This retires the 100-line name-keyword table we were using to pick station
avatars.

---

## 6. L-points: the orientation is in the record

Every L-point record carries a **unit quaternion at `+0x120`** and
`icSolarSystem::Load` feeds it straight to `FiSim::SetOrientation`. All 76 are a
pure yaw (`x = z = 0` in `(w, x, y, z)` terms), which is what you would expect of
a point on a line between two bodies in the ecliptic.

That closes the loop with `icLagrangePointWaypoint::TryToJump` (`0x1006ad40`),
which refuses a jump unless the ship's offset from the L-point has **local
z < 0**: the record's frame *is* the funnel's frame, and its local +Z is the jump
axis. Nothing in the HUD code sets that basis because the loader already did.

Converting into Godot: the map is left-handed (+Z forward) and we mirror Z, so a
rotation `R` becomes `M R M` with `M = diag(1,1,-1)`; for a quaternion stored
`(w, x, y, z)` that is `(w, -x, -y, z)`. Game +Z is Godot -Z, so the jump axis is
`basis * Vector3.FORWARD`.

The record's `+0x134` for an L-point is a link word that `icSolarSystem::Load`
stores at `icLagrangePointWaypoint+0x20c` and `icCluster::ConnectLagrangePoints`
(`0x10044e50`) consumes. We do not need it -- the destination *names* are in the
file's tail table -- and we have not decoded what it indexes.
