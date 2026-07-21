# Asteroid and debris fields

How the original populates a "belt" with rocks, read out of `iwar2.dll`.
Implemented in `game/scripts/fields.gd`, wired in `main.gd` (belt records,
per-frame tick) and `pog/natives/world.gd` (`sim.Create` of the
`icFieldSphere` region templates).

The one-sentence answer: **rocks are not placed, they are conjured.** Two
field singletons exist for the whole game -- one `icAsteroidField`, one
`icDebrisField` -- and geography only carries *zones* that switch them on.
An active field keeps a fixed pool of `count` rocks teleporting around the
player: anything farther than 1.1 x (100 x its own radius) is silently taken
back, anything in the pool respawns on a 100-radii shell ahead of you. Live +
pooled = `count`, always. That is the entire streaming/LOD story, and it is
how a "belt" whose authored ring radius is 3.7e11 m never costs more than 100
rocks.

---

## 1. The classes and where they live

| class | registered | notes |
|---|---|---|
| `iiSimField` | `FUN_10048fa0 @ 0x10048fa0` | abstract base, all the machinery |
| `icAsteroidField` | `FUN_1003f830 @ 0x1003f830` | subclass; ctor `FUN_1003f8c0 @ 0x1003f8c0` reads `ini:/fields/asteroid [Properties]` |
| `icDebrisField` | `FUN_10046b70 @ 0x10046b70` | subclass; ctor `FUN_10046c00 @ 0x10046c00` reads `ini:/fields/debris` |
| `icFieldSim` | `FUN_10064730 @ 0x10064730` | one rock; subclass of `icInertSim`, size 0x1f0, owner field ptr at `+0x1e8` |
| `icAsteroidBelt` | `FUN_100649d0 @ 0x100649d0` | map kind-4 geography; property `width` -> `+0x1e0` (`FUN_10064a70`) |
| `icFieldSphere` | `FUN_10066440 @ 0x10066440` | script-droppable region; `contains_asteroids`/`contains_debris` -> `+0x1e0`/`+0x1e1` (`FUN_100664e0 @ 0x100664e0`) |
| `icAsteroidAvatar` | `FUN_100bb190 @ 0x100bb190` | thin FiSceneNode wrapper (`FUN_100bb1d0`); the geometry is the LWS avatar |

The singletons are built in `icClient::CreateWorld @ 0x100b2260` under the
progress strings `"Loading asteroids"` / `"Loading debris"`
(`DAT_10165f20` / `DAT_10165fbc`), and **both are ticked every frame** by
`icClient::Tick @ 0x100b39c0` (game state 6) via `iiSimField::Think`.

## 2. The tuning: `ini:/fields/*.ini` through the property map

`FUN_10049020 @ 0x10049020` builds `iiSimField`'s property map (10 entries):

| property | offset | asteroid.ini | debris.ini |
|---|---|---|---|
| `sim_templates[]` | +0x14 | `sims/inert/asteroid1..4` | `sims/inert/debris1..5` |
| `count` (int) | +0x20 | **100** | **50** |
| `particle_field` | +0x24 | `ini:/sfx/kibble/node` | `ini:/sfx/cornflake_field/node` |
| `min_radius` | +0x28 | 50.0 | 50.0 |
| `max_radius` | +0x2c | 400.0 | 200.0 |
| `min_rotation_rate` | +0x30 | 5.0 deg/s | 0.0 |
| `max_rotation_rate` | +0x34 | 60.0 deg/s | 20.0 |
| `min_speed` | +0x38 | 2.0 m/s | 0.0 |
| `max_speed` | +0x3c | 75.0 m/s | 0.0 |
| `max_clump_size` | +0x40 | (unset, ctor default 1) | (unset) |

`max_clump_size` is registered but **no recovered code reads +0x40** --
UNKNOWN what it was meant to do.

After `ReadProperties`, virtual slot `+0x18` runs the init that Ghidra
dropped (**raw disasm @ `0x10049400`**): resolve the `particle_field` scene
node into `+0x44`, then create `count` sims -- each one `FiSim::Create` of a
**uniform random** `sim_templates[]` pick, class-checked against `icFieldSim`
(`FUN_10049c30 @ 0x10049c30`) -- push them all into the pool (`+0x54/+0x5c`),
and finally set

```
this+0x64 = 100.0 * max_radius        ; fmul [0x10119fa0]
```

## 3. `iiSimField::Think @ 0x10049570` -- the whole field, every frame

1. **Cull.** For every live sim (`+0x48/+0x50`): let `R = FiSim::Radius() *
   100.0` (`FUN_100649b0 @ 0x100649b0`, `_DAT_10119fa0 = 100.0`) and `cull =
   R * 1.1` (`_DAT_10119e94`). If any |camera-relative axis| > `cull` (cube
   test) or distance^2 > `cull`^2, the sim is removed from the world and
   **returned to the pool** (`FUN_100498f0 @ 0x100498f0`). This loop runs
   whether or not the field is active -- leaving a zone strands the rocks and
   the shell test reaps them.
2. **Flush at shell-per-frame displacement.** If the field is active (`+0x60`
   refcount > 0), Think squares `+0x64` = **100 x max_radius** against the
   **per-frame focus displacement** `FcWorld+0x50..0x58` -- the same delta
   vector it divides by `m_game_delta_time_seconds` immediately below to get
   the cone speed. It is a DISPLACEMENT test, not a velocity test (an earlier
   reading of this step as "speed > 40 km/s" is what made our LDS cruise
   teleport-respawn the whole field around the player every frame -- the
   reported asteroid-swarm-in-LDS bug). Only when the player crosses the
   entire spawn shell in a single tick (asteroids 40 km/frame, debris
   20 km/frame) is every live sim pooled, and the spawn below runs with speed
   treated as 0 -- the field re-teleports rather than switching off.

   **Why the original shows no rocks during LDS cruise:** there is no LDS
   gate anywhere in the field system (no `icLDSDrive` coupling; the zone
   Thinks `@ 0x100667b0` / `@ 0x10064cf0` test position only, and
   `icClient::Tick @ 0x100b39c0` runs the field Thinks unconditionally). The
   suppression is emergent ordering: the Thinks run BEFORE `FcClient::Tick`
   integrates the world, so the speed-0 respawn places rocks about the LAST
   tick's focus (`world+0x38`, read pre-integration). At shell-per-frame
   speeds the respawned shell is already a full frame's travel astern of the
   render position, strands outside the 1.1x cull, and is reaped -- unseen --
   on the next tick. The remaster now reproduces the ordering LITERALLY:
   `fields.tick` runs in `main._physics_process` (before `ShipFlight`
   integrates), and the world fold runs post-integration in
   `main.late_physics` (issue #51, docs/lds.md) -- so `px/py/pz` at Think
   time IS the pre-integration focus and the stranding emerges with no
   `- vel * delta` reconstruction.
3. **Spawn** (`FUN_10049fe0 @ 0x10049fe0` -> `FUN_1004a030 @ 0x1004a030`),
   budget = `count` per frame, so an empty field fills in one tick:
   - stationary (speed < 1e-6): random unit vector, distance uniform in
     `[0.1, 1.0] x R` (`_DAT_101184b0 = 0.1`);
   - moving: `FnRandom::ConeVector` (flux @ `0x10048200`) about the travel
     direction with half-angle from `FUN_1004a430 @ 0x1004a430`:
     `t = clamp((v - 1) * 0.00200401, 0, 1)` (`_DAT_10119fc8` = 1/499, capped
     at `_DAT_10119fcc` = 500 m/s), `angle = t*0.4 + (1-t)*PI`
     (`_DAT_10117558` = 0.4 rad, `_DAT_10119464` = PI). Distance exactly `R`.
   - **Sign RESOLVED (2026-07-21): the cone opens ASTERN.**
     `FnRandom::ConeVector` (flux @ `0x10048200`) builds a quaternion from
     its two half-angle rolls and returns it applied to **+Z** (the output
     is the rotation matrix's third column: `x = 2(xz + wy)`,
     `y = 2(yz - wx)`, `z = 1 - 2(x^2 + y^2)`). `FUN_1004a030` then builds
     an orthonormal basis from `d = -direction` (`local_74 = -*param_2`,
     with cross-products against world X/Y/Z fallbacks) and mixes the cone
     vector as `cone.x * side + cone.y * third + cone.z * d` -- the cone's
     mean axis IS the negated travel direction. Moving respawns land
     BEHIND the traveller at the full shell radius `R`: at cruise the
     field visibly thins out ahead (nothing ever pops in in front), and it
     refills all around only when the half-angle widens back to PI below
     ~1 m/s. The earlier AHEAD reading -- rationalised as "the only way a
     traversed field refreshes" -- was wrong precisely because the
     original does NOT refresh a traversed field ahead; leaving the rocks
     behind is the authored behaviour.
4. **Rock kinematics** (`FUN_10049d70 @ 0x10049d70`):
   - orientation: random;
   - spin: `size_frac = clamp((r - min_radius)/(max_radius - min_radius))`,
     `k = (1 - size_frac) * (rand*0.9 + 0.1)` (`_DAT_1011951c = 0.9`,
     `_DAT_101184b0 = 0.1`), rate = `k*max_rot + (1-k)*min_rot` deg/s
     converted by `_DAT_10119930 = 0.0174533`, random axis. **Big rocks
     tumble slowly.**
   - velocity: random direction, magnitude uniform `[min_speed, max_speed]`,
     skipped entirely when `max_speed <= 0` (debris drifts dead).

Positions are taken relative to the world's `+0x38` camera block; the belt
test below uses `+0x60`. Which of the two is the camera and which the player
reference sim is UNKNOWN -- we use the player for both.

## 4. What a rock is

`sims/inert/asteroid1..4.ini` / `debris1..5.ini`: class `icFieldSim`, avatar
`lws:/avatars/asteroids/setupN` / `lws:/avatars/debris/dN_setup`, a collision
hull, `type = T_Asteroid`, `threat = 0`, **`hit_points = 5000`, `armour =
0`**. The authored `width/height/length` match the LOD0 model bounds
(asteroid1 = 450 x 300 x 280); `FiSim::Radius()` comes from the avatar, as
for every sim we stream.

Two `icFieldSim` overrides (both dropped by Ghidra, raw disasm):

- **`0x100648b0`** (the kill path): if the rock has an owner field
  (`+0x1e8`), dying calls the field's remove (`FUN_100498f0`) -- a shot-dead
  rock goes back into the pool and respawns elsewhere. Rocks are effectively
  infinite.
- **`0x100648d0`** (`CanCollide` override): the other sim's speed is
  approximated as `max + 0.34375*mid + 0.25*min` of the |velocity| components
  (`_DAT_101191f0`/`_DAT_101191ec`) and if it exceeds
  **`_DAT_1011a18c` = 10 000 m/s** the rock refuses the collision -- an
  LDS-speed ship passes clean through the field.

Bullet impacts on rocks play the dedicated `asteroid_impact` effect (our
`sfx_effects.json`, "icBullet hitting ... (rock)").

The avatar LWS (`avatars/asteroids/setup1.lws` et al.) is three
detail-switched LODs (108 / 108 / 20 tris) at apparent-size fractions
1.0-0.1 / 0.1-0.01 / 0.01-0. At 108 triangles for LOD0 we render the
full-detail model always and skip the switch.

## 5. The zones

### `icAsteroidBelt` (map kind 4)

`ParseAsteroidBeltInfo @ 0x1004e6b0`:

- ring radius = **record `+0x134`** -> `FiSim::SetRadius` (JSON `info_f`),
- **width = record `+0x138`** -> belt `+0x1e0` (JSON `radius` -- for a belt
  that float is the width, not a body radius),
- centre = the **parent geography's position** (copied into `+0x1e8..+0x1fc`).

`Think @ 0x10064cf0` evaluates `FUN_10064d50 @ 0x10064d50`:

```
inside :=  |d . Y| < width
       and (R - width)^2 <= (d.X)^2 + (d.Z)^2 <= (R + width)^2
```

with `d` = player - parent position in the belt's frame. On an edge it
activates/deactivates **the asteroid singleton only** (`FUN_10049890` /
`FUN_100498c0 @ 0x10049890/0x100498c0` -- a refcount; 0->1 also attaches the
particle field node via `icSolarSystem::AddParticleField @ 0x1004e7c0`).

**All 21 shipped belt records have width == radius**, so the annulus
degenerates to a disc of radius 2R and half-thickness R about the parent.
Consequences we verified against the map data: Hoffer's Gap (the Act 0
scrapyard) sits exactly ON the ring of Hoffer's Asteroid Belt -> ambient
rocks at the junkyard; Alexander L-Point (free-flight start) is outside.

### `icFieldSphere` (`ini:/sims/regions/asteroid|asteroid25k|debris`)

A script-created geography sphere: radius 10 km (25 km for `asteroid25k`),
`contains_asteroids` / `contains_debris` flags. `Think @ 0x100667b0` runs a
cube-then-sphere player test (`FUN_10066840 @ 0x10066840`) and drives either
singleton per its flags. The Junkyard's ambient junk is exactly this:
`istartsystem.FinalSetup` does `sim.create("ini:/sims/regions/debris")` +
`sim.place_at(..., "Lucrecia's Base")` once the player's base system is Santa
Romera. Act 0's Hoffer's Gap gets no script sphere -- its ambient rocks come
from the belt above, and the *authored* junk sims are separate props.

## 6. The particle field: `icTeleportDynamics` (the ambient dust)

While a field is active, its `particle_field` node hangs off the solar system
(`AddParticleField @ 0x1004e7c0` / `RemoveParticleField @ 0x1004e8b0`).
Asteroids: `sfx/kibble/node` -- `FcParticleEmitterNode` +
**`icTeleportDynamics`** (ctor `0x100c8870`; `min/max_birth_rate` 20-40,
`max_particles` 300, no `angular_velocity` at all) + `FcParticleDrawModel`
(kibble01..04 at scale 0.4). Debris: `sfx/cornflake_field/node` -- same
dynamics, 200 particles, `angular_velocity` 250 deg/s, `icCornflakeDraw` hull
plates.

This section was previously all inference and it was **wrong in both of the
ways the player noticed**. The real class, raw-disassembled (Ghidra dropped
both methods): **`Spawn @ 0x100c8c80`**, **`Update @ 0x100c91f0`**, emit
position helper **`@ 0x100c94b0`**.

### 6.1 The motes are world-fixed. That is the parallax.

Particle coordinates are stored **relative to the viewpoint**, and `Update`
begins by adding the world's graphics delta-focus to every one of them:

```
pos   += FcWorld::GraphicsDeltaFocus()      ; world+0x78,  0x100c92d6..0x100c92f4
angle += dt * spin                          ; +0x28 += dt * +0x2c
```

and `FcWorld::SetGraphicsFocus` (flux `@ 0x1004f100`) sets

```
world+0x78 = previous_focus - current_focus         (both doubles, stored f32)
```

so the delta-focus is **minus the viewpoint's movement this frame**. Adding it
to a viewpoint-relative coordinate every frame is exactly the fold that holds a
mote **still in the world** while the shell re-centres on the camera. They are
not attached to the camera; you fly through them and they stream past. (Our old
"40 m box wrapped around the camera" was a reconstruction and it is the reason
they did not move when the player moved.)

Corroboration from the emit path, which resolves the sign independently: the
spawn cone is built about **`-normalize(delta_focus)`** (the three `fchs` at
`0x100c95a5/0x100c95b6/0x100c95ce`) = **+direction of travel**. Dust is only
ever laid down in front of you. Under the opposite sign convention both the
fold and the cone would be backwards; under this one, both are right.

### 6.2 The near cull is 5 m. That is the cockpit rule.

The rest of `Update` is one keep-test per mote (`0x100c9323..0x100c9337`):

```
keep iff   near^2 <= |pos|^2 <= R^2      near = _DAT_1011cf68 = 5.0
```

Anything **closer than 5 metres to the viewpoint is killed**, in `Update`,
**before the draw**. There is no separate near pass and no depth trick: the
cockpit hangs off the camera, and the original simply refuses to keep a mote
you have got that close to. A mote you fly into is dead the frame it comes
within 5 m, so it is never drawn inside the cockpit. That is the number; we use
it, not a fudge.

### 6.3 The shell radius R is a pixel, not a distance

`Spawn` recomputes R every frame (`0x100c8ce2..0x100c8d0f`):

```
R = 0.5 (_DAT_10117738) * max(screen_w, screen_h) * draw->Size()
      screen_w/h = FcGraphicsEngine +0x13c / +0x140
      Size()     = vtable slot +0x24 of the draw object (emitter+0x18)
```

| draw class | `Size()` | value |
|---|---|---|
| `FcParticleDrawModel` | flux `@ 0x10068070` returns `+0x34`, which `OnPropertiesChanged` (flux `@ 0x100520c0`) sets to `scale * MAX model radius` | kibble: 0.4 x the kibble0N bounds radius (~1.31 m for our glTF) |
| `icCornflakeDraw` | iwar2 `@ 0x100bc440`: `fld [0x1011cb8c]; ret` -- a **hardcoded constant** | **2.828427** |

Invert `FcGraphicsEngine::PixelRadius` (flux `@ 0x10014150`, `pixels =
max(w,h) * radius / distance`) and **R is precisely the distance at which a mote
of radius `Size()/2` covers one pixel**. The shell reaches exactly as far as a
mote is still visible, and it is *resolution-dependent by design*. At 1920x1080
that is **R = 1254 m for kibble and 2715 m for cornflakes** (measured, harness
below) -- not the 40 m we had guessed, which is why 200 motes used to be packed
into the cockpit instead of spread over a couple of kilometres.

### 6.4 The rest of Spawn, verbatim

Runs only when the dynamics is enabled (`+0x2c`) and `|dt| >= 1e-6`. `d` =
delta-focus, `v = d/dt`, `speed = |v|`:

1. **Movement gate** (`+0x40`, `0x100c8d6b..0x100c8dc1`): accumulate `d`; if
   `|accum|^2 < 10.0` (`_DAT_101190c0`) **return, emitting nothing**. So dust is
   only laid down once the viewpoint has travelled `sqrt(10) = 3.16 m` since the
   last emission -- **a parked ship grows no dust at all**; the field is fed by
   flying through it. Then the accumulator is reset to zero.
2. **Birth rate** (`0x100c8e34`): when the countdown `+0x30` reaches 0, roll
   `FnRandom::CentreWeighted(min_birth_rate, max_birth_rate)` into both `+0x3c`
   (the rate) and `+0x30` (a countdown of that many particles), and zero the
   fractional accumulator `+0x38`.
3. **Flush** (`0x100c8e9b`): if the viewpoint moved further than the shell in
   one frame (`|d|^2 > R^2`), every mote is stale -- **drop them all**. Then:
   - `|d|^2 >= 4.0e6` (`_DAT_1011cfb4`, i.e. **> 2 km**: an LDS/capsule jump) ->
     return, and let the field regrow at the birth rate;
   - otherwise (a short hop) -> spawn count = `max_particles`: the whole shell
     refills in one tick.
   (Our old note guessed "refills instantly for jumps under 2 km". That half was
   right, by luck.)
4. **Swing burst** (`0x100c8f37..0x100c8f77`): otherwise, take the viewpoint's
   forward vector (`FcGraphicsEngine+0xf8`), `rate = acos(dot(fwd, prev_fwd))/dt`
   against the previous frame's; if it exceeds **PI/2 rad/s** (`_DAT_1011a454`,
   90 deg/s) the spawn count is **0.4 x max_particles** (`_DAT_10117558`) -- a
   fast pan swings in frustum the shell has never filled, so it bursts. Else the
   count is the ordinary `birth_rate * dt`.
5. **Emit** while the fractional accumulator `>= 1`, decrementing it and the
   birth-rate countdown. Position (`@ 0x100c94b0`), relative to the viewpoint:
   - `speed < 1.0` m/s -> `FnRandom::UnitVector()`, distance **uniform in
     `[0.1 R, R]`** (`_DAT_101184b0` = 0.1) -- an isotropic shell you can drift
     around inside;
   - otherwise -> `FnRandom::ConeVector(0.2 rad)` (`0x3e4ccccd`) about the
     direction of travel, at distance **exactly R**.

   Spin is **uniform in `[0, angular_velocity]`** (`0x100c9094..0x100c90f1`),
   initial roll `rand * 2*PI` (`_DAT_10119f94`), and the particle's **own
   velocity is set to zero** (`0x100c911e`): a mote never moves under its own
   power, it only holds still while the world slides past. Since `kibble/
   dynamics.ini` declares no `angular_velocity`, **asteroid kibble does not
   tumble at all** (the ctor leaves `+0x28` zero); only cornflakes (250 deg/s)
   do.

The particle lists at `+0x5c` are a vector-of-vectors, **one list per draw
model** (walked per list by the draw dispatcher `@ 0x100c8950`); the per-list
cap `+0x68` is `(pool_block_size / 52) >> 4` and the list count is
`ceil(max_particles / cap)` (`0x100c8ac0`). That is allocator bucketing only --
the total is `max_particles`.

### 6.5 The 40.0 is a node SCALE, not an emitter box

`icDebrisField`'s ctor ends (`0x10046c80..0x10046c92`) with
`node->+0x5c/+0x60/+0x64 = 40.0`, and `FiSceneNode::SetScale` (flux
`@ 0x1004dd80`) writes **exactly those three offsets** -- it is
`SetScale(40,40,40)` on the emitter node, not a 40 m emission volume.
`FcParticleEmitterNode::Prepare` (flux `@ 0xe1e20`) pushes the node's world
scale into the emitter (`FiParticleEmitter::SetTransform`, `+0x30..+0x38`), and
`icCornflakeDraw` reads it straight back (`0x100bc6cd`: `[draw+0x14]->[+0x38]`)
and multiplies by **0.075** (`_DAT_1011cb98`) -- so the debris field's
cornflakes are **3.0 m hull plates** (halved to 1.5 m half-extents at
`0x100bc76b`). `icAsteroidField`'s ctor (`0x1003f8c0`) pokes nothing, so the
kibble node keeps scale 1 and its chunk models draw at their authored 0.4.

## 7. What we implemented (`game/scripts/fields.gd`)

- Two persistent `Field` singletons with the ini specs above; pools built
  lazily on first activation (the original builds them at world load -- a
  deliberate boot-time divergence, behaviour identical from the first active
  frame).
- Belt zones registered by `main._load_system` from the kind-4 records
  (ring radius = `info_f`, width = `radius`, centre = parent position);
  sphere zones are `main.objects` records with category `field_sphere`,
  created by the `sim.Create` native for the three region templates
  (`pog/natives/world.gd`), so `PlaceAt` moves them and `sim.Destroy` kills
  them for free.
- The Think loop verbatim: 1.1 x 100r cube+sphere cull, 100 x max_radius
  PER-FRAME-displacement flush (spawning about the last tick's focus, section
  3 step 2 -- the emergent no-rocks-in-LDS behaviour), per-frame spawn budget
  = `count`, stationary shell `[0.1, 1.0] x 100r`, moving cone PI -> 0.4 rad
  over 1..500 m/s, spin/velocity rolls as recovered. Rock positions are
  stored ABSOLUTE (three GDScript doubles) and re-folded against `px/py/pz`
  every tick, because the original's rocks are world-fixed and a script
  teleport must strand them into the cull shell.
- Collision: live rocks near the player push it via `main._collide_sphere`
  (sphere at 0.66 x bounds radius, same convention as prop avatars), gated by
  the recovered 10 km/s `CanCollide` cutoff and by the same docked/jump guard
  as `main._collisions`.
- Damage: PBC bolts are swept against live rocks (reading
  `weapons.bolts`, no edits to weapons.gd); hits play `asteroid_impact`,
  apply the bolt's aged damage to the rock's 5000 hp bare hull, and a dead
  rock explodes (`ExplosionFx.boom`) and returns to the pool, as per the
  `0x100648b0` override.
- Dust: `fields.gd` only **attaches and detaches** the `particle_field` node
  (`AddParticleField` / `RemoveParticleField`), spawning a `ParticleFx` for
  `ini:/sfx/kibble/node` or `ini:/sfx/cornflake_field/node` on the activation
  edge, with the debris node scaled by **40** (the `SetScale` its ctor does).
  `icTeleportDynamics` itself lives in `particle_fx.gd` and runs section 6
  verbatim: world-fixed motes in scene coordinates (re-anchored by
  `main._fold_motion`'s `shift_world`, which is precisely the engine's
  `pos += GraphicsDeltaFocus`), the resolution-derived shell R, the 5 m near
  cull, the sqrt(10) m movement gate, the 2 km flush rule, the 90 deg/s swing
  burst, the 0.2 rad forward cone, spin uniform in `[0, angular_velocity]`.
  Cornflakes now draw as the real tumbling lit 3 m hull plates (the previous
  code drew kibble chunks as a stand-in for them). Kibble draws through one
  MultiMesh per model -- which is also how the engine buckets them.

  **This replaces the old 40 m camera-locked wrap box, which was the bug**: it
  was reconstruction, not extraction, and it got both halves wrong. Motes were
  glued to the camera (no parallax) and packed within 40 m of the eye (inside
  the cockpit). Both symptoms in task #64 come from that one guess.

**Live-rock cap: `count` per field = 100 asteroids + 50 debris = 150 rocks
maximum**, ever, exactly the original's budget (live + pooled = count). Rocks
are ~108 triangles each; the per-frame cost is one pass over <= 150 rocks
plus <= 500 dust transforms, and only while a zone is active.

Verification: `--mechcheck` grew a fields phase (checks.gd) asserting the
recovered numbers -- `field-count` (100/50), `field-shell` (all spawns inside
`[0.1, 1.0] x 100r`), `field-kinematics` (spin 5..60 deg/s, speed 2..75 m/s,
debris motionless), `field-cull` (deactivate + teleport reaps every rock).
20/20 ALL PASS; `--campcheck`, `--jumpcheck`, headless boot all clean.

The dust was verified with a throwaway headless harness that drives
`_update_teleport` through main's every-frame origin fold, at 1920x1080:

```
system=cornflake_field max_particles=200 spin=250.0 draw=icCornflakeDraw scale=40.0
shell radius R = 2715.3 m
flew 500 m in 120 frames; 64 motes seen, 6 live at peak
  max drift of a mote's WORLD position     : 0.0068 m     <- world-anchored
  max drift of a mote's CAMERA-REL position: 325.0 m      <- parallax
  flew STRAIGHT AT a mote: culled at 5.47 m               <- the cockpit rule
system=kibble max_particles=300 spin=0.0 draw=FcParticleDrawModel scale=1.0
shell radius R = 1253.9 m
  max drift of a mote's WORLD position     : 0.0021 m
  max drift of a mote's CAMERA-REL position: 408.3 m
  flew STRAIGHT AT a mote: culled at 6.54 m
```

(The centimetre of world drift is float32 round-off over 120 folds at km range;
the engine stores these coordinates in float32 and folds them the same way.)

## UNKNOWNs

- `max_clump_size` (+0x40): registered, never read by recovered code.
- Which world position block (+0x38 vs +0x60) is camera vs player reference
  in the zone/cull tests; we use the player for both.
- Whether field rocks entered the original's contact list (the
  `hud_type_asteroid` strings exist); ours stay off it.
- `FiSim::Radius()` for a template: we take the avatar bounds sphere (the
  authored width/height/length match the LOD0 AABB); the engine's exact
  derivation (hull vs avatar vs dims) was not chased.
- The `icCornflakeDraw::Size()` constant is 2.828427 (= 2 sqrt 2) and the plate
  it actually draws is 3.0 m (0.075 x scale 40). Why the shell radius uses a
  hardcoded near-miss of the real plate size rather than reading the emitter is
  UNKNOWN -- but both numbers are extracted, not guessed.
- `FcModel`'s radius (+0x3c), which `FcParticleDrawModel::Size()` multiplies by
  `scale`: we take the glTF bounds-sphere radius. The engine's exact derivation
  was not chased (same caveat as `FiSim::Radius()` above).

RESOLVED since the last pass: the spawn cone's fore/aft sign (it is AHEAD --
`Spawn` negates the delta-focus at `0x100c95a5`, and the delta-focus is itself
`old - new`, so the cone opens along the direction of travel), and
`icTeleportDynamics`'s update rule and emitter volume (section 6 -- there is no
emitter volume; the 40.0 was a node scale).
