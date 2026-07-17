# Particles and special effects

How the original builds an explosion, a weapon impact, a muzzle flash and a
bolt. Same rules as `original.md`: every claim carries its source, and what we
could not read out of the game is in **Open questions**, not guessed.

Companion docs: `original.md` (the evidence log), `formats.md` (LWS, INI, the
channel expression language).

---

## 1. There are two layers, and both are now extracted

`data/ini/sfx/<name>/` holds **particle systems** -- twelve of them, each a
`node.ini` + `emitter.ini` + `dynamics.ini` + `draw.ini`. That is the layer we
already had extracted, and on its own it explains nothing: nothing in
`sims/weapons/*.ini` references it, and only two of the twelve are named
anywhere in the INI tree (`fields/asteroid.ini` -> `kibble`,
`fields/debris.ini` -> `cornflake_field`).

The layer above it is **`sfx/*.lws`**, twenty-three LightWave scenes in
`resource.zip`. *Those* are the effects the game fires. A scene is a bag of null
objects, each tagged with a `<node>` directive, and it composes particle
systems, a sprite flipbook, a sound, a special avatar and a light into one
effect. **`tools/iw2/sfx.py` now extracts all 23 into
`data/json/sfx_effects.json`**, which is what `ExplosionFx` plays; nothing about
an individual effect is written in GDScript any more.

The engine reaches them through **`icVisualEffects`** (`iwar2.dll`; the class
name and its prefix table are at `0x10162078` / `0x10161f14`). The table is
twelve URL *prefixes*, and the index is the effect's identity everywhere in the
engine:

```
0 lws:/sfx/explosion_        4 lws:/sfx/beam_impact_    8 lws:/sfx/antimatter_explosion_
1 lws:/sfx/small_explosion_  5 lws:/sfx/lda_impact_     9 lws:/sfx/alien_explosion_
2 lws:/sfx/hull_impact_      6 lws:/sfx/plasma_fire_   10 lws:/sfx/ldsi_explosion_
3 lws:/sfx/asteroid_impact_  7 lws:/sfx/reactor_explosion_  11 lws:/sfx/collision_
```

The constructor (`0x100d3050`) preloads, per effect, `high_0..2` (stopping at
the first that fails to load) and `low`, into twelve 20-byte slots of
`{count, high[3], low}` -- exactly the `operator_new(0x104)` it allocates.

**A weapon does not name its effects.** `pbc_bolt.ini` has no effect key at
all. The effect is chosen by the engine from the *kind* of event, which is why
grepping the INI tree for the link finds nothing.

### `low` vs `high_%d` is a distance LOD, not a quality setting

This was the open question. `0x100d33e0`, called from the play function
`0x100d3210`:

```
apparent = size * SIZE_WEIGHT[effect] / distance_to_camera
apparent < cull_detail * gfx  ->  nothing is drawn
apparent < low_detail  * gfx  ->  the `_low` scene; if the effect ships none,
                                  nothing is drawn
otherwise                     ->  a uniformly RANDOM high_%d
                                  (rand() % (2*count) >> 1)
```

`SIZE_WEIGHT` is a `float[12]` at `0x1011d254` = `20, 20, 15, 15, 15, 35, 20,
30, 30, 30, 30, 30`. `cull_detail` (0.005) and `low_detail` (0.04) are
`icVisualEffects`' two registered properties, defaults at `0x10161f0c` /
`0x10161f10`; `gfx` is a graphics-engine detail scalar (`+0x108`).

So `high_%d` is **not** a size tier: `explosion_high_0/1/2` differ *only* in
flipbook and sound, and the choice is a coin toss. And a hull impact
(`size = 1`, weight 15) drops to its `_low` scene -- a bare light, no sparks --
past `15/0.04` = **375 m**. That is original behaviour, not a bug.

The play function also sets the effect node's scale to `size` on all three axes,
positions it from a local offset in the firing sim's basis, and attaches it to
that sim.

### What each scene contains

Read out of `resource.zip:sfx/*.lws` (and now out of `sfx_effects.json`). Light
colours are `r,g,b` 0-255; envelope keys are `(frame, intensity)` at the scene's
own fps.

| effect | flipbook | particle systems | sound | light |
|---|---|---|---|---|
| `explosion_high_0` | `deba`, 50 fr, scale 5 | `cornflakes`, `spark_shower` | `large_explosion_1` | 255,165,25 r50, 60 fps, 0/3/18/60 = 0/1/0.3/0 |
| `explosion_high_1` | **`fzgb`, 40 fr** | `cornflakes`, `spark_shower` | `large_explosion_2` | same |
| `explosion_high_2` | `deba`, 50 fr | `cornflakes`, `spark_shower` | `large_explosion_3` | same |
| `explosion_low` | `deba`, 50 fr | -- | `large_explosion_1` | same, constant 1.0 |
| `small_explosion_high_0/1` | `fzgb`, 40 fr | `cornflakes`, `spark_shower` | `small_explosion_1`/`_2` | as `explosion` |
| `small_explosion_high_2` | **`deba`, 50 fr** | `cornflakes`, `spark_shower` | `small_explosion_3` | same |
| `small_explosion_low` | `deba`, 50 fr | -- | `small_explosion_1` | same, constant |
| `hull_impact_high_0` | -- | `pbc_spark` | `impact` | 255,165,25 r60, 30 fps, 0/2/15 = 0/1/0 |
| `hull_impact_low` | -- | -- | -- | 255,165,25 **r400**, constant 1.0 |
| `beam_impact_high_0` | -- | `pbc_spark` | `impact` | 255,165,25 r60, **constant 1.0** |
| `asteroid_impact_high_0` | -- | `pbc_spark`, `asteroid_impact` | -- | 255,165,25 r60, 0/2/15 |
| `lda_impact_high_0` | `icLDAAvatar` | -- | `shield_hit` | 177,89,255 r400, 0/15/30 = 0/**1.5**/0 |
| `lda_impact_low` | -- | -- | -- | same light, no avatar |
| `plasma_fire_high_0` | -- | `plasma` (scale 0.1, on an animated `scaler`), `hull_impact` (scale 5) | `critical_hit` | three: 255,180,40 r500 flare; 255,67,4 r50 **12-key flicker to frame 150**; 255,150,30 r500 flare |
| `plasma_fire_low` | -- | -- | `critical_hit` | 255,180,40 r500 |
| `collision_high_0` | -- | -- | `collision` | -- |
| `reactor_explosion_high_0` | `icShockwaveAvatar tint=(1.0,0.6,0.1) lifetime=2` | -- | -- | 255,255,255, **LightType 0, no range** |
| `antimatter_explosion_high_0` | `icShockwaveAvatar tint=(0.1,0.2,1.0) lifetime=3` **+ 8 `icBeamAvatar` (`SearchBeam`) spikes** | -- | `antimatter_explosion` -> `large_explosion_3.wav` | 255,255,255 **r75000**, 0/5/45/90 = 0/**5**/1/0 |
| `alien_explosion_high_0` | `icShockwaveAvatar tint=(1.0,0.15,0.1) lifetime=6` | -- | `alien_death` | 191,218,44 r3000, 0/3/9/18/60 = 0/1/0.5/0.25/0 |
| `ldsi_explosion_high_0` | `icShockwaveAvatar tint=(0.4,1.0,0.2) lifetime=3` | -- | -- | 113,210,66 r4000, 5 keys |

Two things the previous hand-transcription got wrong, and which the extractor
now gets right: **the flipbook is per variant** (`explosion_high_1` is `fzgb`,
not `deba`) and **the sound is bound to the variant**, not picked at random from
a list -- `high_0/1/2` carry `large_explosion_1/2/3` respectively. Randomising
the sound independently of the flipbook was our invention.

The sound node is an indirection, not an alias: `audio/sfx/antimatter_explosion`
is an `FcSoundNode` INI whose `url` is `sound:/audio/sfx/**large_explosion_3**`.
The extractor resolves it, and carries `volume` and `min_range` across.

The directives:

```
<node class=icMovieAvatar url=texture||images|sfx|deba frame_count=50>
<node template=ini||sfx|cornflakes|node>      instantiate a particle system
<node template=ini||audio|sfx|large_explosion_1>
<node class=icShockwaveAvatar tint=(0.4,1.0,0.2) lifetime=3>
```

(`||` is `:/` and `|` is `/`; `formats.md` already had this.) The light is a
plain LightWave `AddLight` with an `LgtIntensity (envelope)` and `LensFlare 1`.
Nulls with plain names (`scaler`, `beam_scaler_thick`, `FatBeamsH`) are
animation/parenting helpers: `plasma_fire`'s `plasma` system hangs off a
`scaler` whose scale runs 0 -> 0.8 -> 1.3 -> 0.9 -> 0 over **600 frames (20 s)**,
which is the hull fire burning down.

### Which effect fires for which event

Recovered from the call sites of the play function `0x100d3210`. **The
decompiled `iwar2.dll.c` shows only four of the seven** -- Ghidra dropped three
-- so they were found by scanning `.text` for `E8` calls to `0x100d3210`. Do
not trust the `.c` for a call-site census.

| effect | fired by | condition |
|---|---|---|
| `explosion` / `small_explosion` | `icExplosion` | its radius >= / < **150 m** (`0x1011a81c`) |
| `hull_impact` | `icBullet` | default |
| `asteroid_impact` | `icBullet` | target category (`sim+0x194`) `0xb`/`0xe` and a name test on `sim+0x184` passes |
| `beam_impact` | `icBeam` | on hit |
| `lda_impact` | LDA ship-system (`0x10036210`) | shot crossing the LDA shield **ellipsoid** (axes `ship+0x208/0x20c/0x210`); drawn at the ray/ellipsoid intersection, only if the ship mounts an LDA |
| `plasma_fire` | `icShip::ApplyWeaponDamage` | probabilistic: `p = (1 - armour/max_armour) * damage_fraction` -- the burning hull, sound `critical_hit` |
| `reactor_explosion` | `icShockwave` | no type flag (default) |
| `antimatter_explosion` | `icShockwave` | `antimatter=1` (`+0x1e8`) |
| `alien_explosion` | `icShockwave` | `alien=1` (`+0x1ea`) |
| `ldsi_explosion` | `icShockwave` | `ldsi=1` (`+0x1e9`) |
| `collision` | `iiSim::ProcessContact` | two sims touching |

The four `icShockwave` flags are confirmed independently by the data:
`sims/explosions/*.ini` are all `name=icShockwave` and carry exactly
`antimatter=1`, `alien=1`, `ldsi=1`, or nothing (`reactor_explosion.ini`,
`harmless_shockwave_explosion.ini`).

### A ship death is four explosions and a shockwave

`iiSim::DoFinalExplosion` (`0x1007c990`), for a sim of radius `R`:

```
4 x icExplosion:  radius = R * lerp(0.3, 0.6, rand)     0x1011c034 / 0x101192c4
                  position = centre + UnitVector() * R * 0.4       0x10117558
                  velocity = the dying sim's velocity
1 x sim ini:/sims/explosions/reactor_explosion  (an icShockwave), unless the
                  sim sets no_shockwave=1  (+0x19f; only the power-ups do)
                  final_radius = R * 4.0                          0x101190b4
                  scale *= clamp(R / 200, 0.25, 4.0)   mean_radius_of_reactor_
                                       explosion_sim = 200, defaults.ini:446
```

Each puff then picks its *own* effect against the 150 m rule. A fighter has
`R` ~ 60-70 m, so its puffs are 20-40 m and every one of them is a
**`small_explosion`**; you need `R` > ~250 m before a puff can reach 150 m and
become the big `explosion`. **That is why `small_explosion` exists**, and it
answers the old open question. `ExplosionFx.boom()` now reproduces this exactly.

### The muzzle flash and the bolt

Neither is a particle system.

- **Muzzle flash**: `avatars/standard_pbc/setup_effects.lws` is a lens-flare
  light (`LightColor 252 180 16`, `LightRange 300`, `FlareNominalDistance 10`)
  parented to an `<anim channel="fire?o(5.0)">` null whose two poses are scale
  0 and scale 1. So it is the *channel* rig we already have in
  `ship_effects.gd`: one-shot pulse on the rising edge of `fire`, decaying at
  5/s. Every cannon has one (`light_pbc`, `heavy_pbc`, `neutron_pbc`, ...).
- **Bolt**: `avatars/standard_pbc_bolt/setup.lws` is a single
  `<node class=icBeamAvatar texture=pbc_standard>` with object scale
  **`4 1 800`** plus a glow light (252,128,16, range 300). The 800 is exactly
  the `length=800` in `sims/weapons/pbc_bolt.ini`: the bolt is an 800 m
  textured streak, not a bullet. Each PBC variant has its own texture
  (`pbc_light`, `pbc_heavy`, `pbc_standard`, `am_pbc`, `neutron`, ...).

---

## 2. The particle system format

### `node.ini` -- the scene-graph node

```ini
[Class]
name=FcParticleEmitterNode
[Properties]
emitter  = ini:/sfx/cornflakes/emitter
dynamics = ini:/sfx/cornflakes/dynamics
draw     = ini:/sfx/cornflakes/draw
```

Three URL properties, offsets `0xbc/0xc0/0xc4` (`flux.dll @ 0x100e1980`). Two
subclasses in `iwar2.dll` (`icAlienSwarmAvatar` `0x100b9640`,
`icElectricEffectAvatar` `0x100c39a0`) whose factories both return an
`FcParticleEmitterNode` and add no properties.

`sfx/ldsi/node.ini` points `draw` at **`ini:/sfx/lidsi/draw`** -- a typo in the
shipped data. That path does not exist. (Our loader falls back to the sibling
`draw.ini`.)

### `emitter.ini` -- `FiParticleEmitter` (`flux.dll @ 0x1005a7a0`)

| key | type | offset | meaning |
|---|---|---|---|
| `time` | float | `0x6c` | the emitter's lifetime in seconds. `0` = eternal. |
| `fixed_particles` | int | `0x70` | **read as a bool** |
| `respect_orientation` | bool | `0x74` | rotate particle positions by the emitter's basis at draw time |

`fixed_particles` is declared `int` and the data uses `0`, `1` **and `2`** --
but `FiParticleEmitter::FixedParticles` (`0x1004f6f0`) is literally
`return *(int *)(this + 0x70) != 0;`. **1 and 2 mean the same thing.** Nothing
in either binary compares that field to 2.

What it selects (`FcParticleDynamics::Spawn` `0x10053f80`, and
`FcParticleDrawBillBoard::Setup` `0x10050770`):

- **`0` -- world particles.** Born at the emitter's world position, inheriting
  the emitter's velocity, then integrated in world space. The emitter moves;
  they stay put. (`pbc_spark` `= 1`, but `cornflakes`, `spark_shower`,
  `hull_impact`, `asteroid_impact` are all `0`.)
- **non-zero -- emitter-local particles.** Position stored relative to the
  emitter and offset by the emitter's *current* position when drawn, so the
  whole cloud follows the emitter. No inherited velocity.

### `dynamics.ini` -- `FcParticleDynamics` (`flux.dll @ 0x100536b0`)

| key | type | offset |
|---|---|---|
| `min_birth_rate` / `max_birth_rate` | float | `0x20` / `0x24` |
| `min_lifetime` / `max_lifetime` | float | `0x28` / `0x2c` |
| `cone_angle` | float | `0x30` |
| `min_speed` / `max_speed` | float | `0x34` / `0x38` |
| `angular_velocity` | float | `0x3c` |
| `max_particles` | int | `0x40` |
| `channel` | string | `0x1c` |
| `once` | bool | `0x44` |
| `motion_blurred` | bool | `0x45` |

`channel` is undocumented in every shipped `dynamics.ini` but the property is
real: an `FcChannelEvaluator` at `+0x7c` scales the birth rate each tick
(`Spawn`: `rate = CentreWeighted(min,max) * channel_value * dt`). Same
expression language as `ship_effects.gd`. No shipped effect uses it.

Three subclasses in `iwar2.dll` replace this map wholesale, and they are *not*
supersets -- properties the INIs set but the class never declares are silently
ignored:

- **`icDisruptorDynamics`** (`0x100c46f0`, 7 props): `min/max_birth_rate`,
  `min_death_age` / `max_death_age`, `prob_jump`, `max_particles`,
  `follow_edge`. Used by `disruptor`, `ldsi`, `infection`. **`cone_angle`,
  `angular_velocity` and `speed` in those three `dynamics.ini` files are dead
  keys** -- copy-paste from the base class; nothing reads them.
- **`icTeleportDynamics`** (`0x100c86d0`, 4 props): `min/max_birth_rate`,
  `max_particles`, `angular_velocity`. Used by `kibble`, `cornflake_field`.
  **Fully recovered -- see docs/fields.md section 6** (`Spawn @ 0x100c8c80`,
  `Update @ 0x100c91f0`, both raw-disassembled; Ghidra dropped them). In one
  line: a shell of **world-fixed** motes that re-centres on the viewpoint every
  frame (`pos += FcWorld::GraphicsDeltaFocus`), radius `0.5 x max(screen w,h) x
  draw->Size()` = the distance at which a mote is one pixel, **culled inside
  5 m** (`0x1011cf68`) and outside the shell, emitted only after the viewpoint
  has moved sqrt(10) m, inside a 0.2 rad cone about the direction of travel.
  The motes carry **no velocity of their own** -- they hold still and you fly
  through them. `angular_velocity` is a spin rate rolled **uniform in
  `[0, angular_velocity]`**; `kibble/dynamics.ini` omits it, so asteroid kibble
  does not tumble at all.
- **`icAlienSwarmDynamics`** (`0x100b9fe0`, 10 props): adds `min/max_death_age`,
  a single `speed`, and an int `time`.

Note the rename: the subclasses call the lifetime `min_death_age` /
`max_death_age`, the base class calls it `min_lifetime` / `max_lifetime`. Same
quantity.

### `draw.ini` -- three classes

**`FcParticleDrawBillBoard`** (`flux.dll @ 0x1004f8d0`):

| key | type | offset | in the data? |
|---|---|---|---|
| `texture` | string | `0x2c` | yes |
| `max_age` | float | `0x50` | **never set** |
| `scale_on_birth` / `scale_on_death` | float | `0x30` / `0x34` | yes |
| `render` | bool | `0x28` | never set |
| `fade_on_emitter_age` | bool | `0x54` | never set |
| `colours[]` | colour array | `0x38` | yes |
| `colour_positions[]` | float array | `0x44` | yes |
| `scale_by_emitter` | bool | `0x55` | yes |
| `motion_blurred` | bool | `0x20` | yes |
| `motion_taper` | float | `0x58` | yes |
| `white_centre_size_ratio` | float | `0x5c` | yes |

**`FcParticleDrawModel`** (`0x10051db0`): `model_urls[]` (string array, `0x18`)
and `scale` (float, `0x24`). Used by `kibble` and `asteroid_impact`; the models
are `model:/models/kibble01..04`, which we already extract to
`data/gltf/models/`. `OnPropertiesChanged` (`flux @ 0x100520c0`) also caches a
derived **`Size()` at `+0x34` = `scale x MAX(model radius)`** over the loaded
models (each `FcModel`'s radius is its `+0x3c`), returned by vtable slot `+0x24`
(`flux @ 0x10068070`). Particles are kept in **one list per model** and drawn
per list, which is why we batch them one MultiMesh per model.

**`icCornflakeDraw`** (`iwar2.dll @ 0x100bc340`): **no properties at all** --
its property map is the base map, which is why `cornflakes/draw.ini` has an
empty `[Properties]` block. Its `Size()` (vtable `+0x24`, `@ 0x100bc440`) is a
bare `fld [0x1011cb8c]; ret` -- the **constant 2.828427**, ignoring the emitter.
The plate it actually draws is sized off the **emitter's world scale** instead
(`0x100bc6cd`: `[draw+0x14]->[+0x38] x 0.075`), so the debris field's
`SetScale(40)` (icDebrisField ctor `@ 0x10046c00`) makes its cornflakes **3.0 m**
across. It hardcodes two textures,
`texture:/images/sfx/cornflakes` and `texture:/images/sfx/cornflake_masks`
(strings at `0x1016178c` / `0x101617ac`). Both are 128x128 and are a **4x4
atlas of sixteen torn hull-plate silhouettes**: the first sheet is the lit
colour art, the second the matching white-on-black cutout mask.

---

## 3. Runtime semantics

### Emission (`FcParticleDynamics::Spawn`, `flux.dll @ 0x10053f80`)

```
if emitter.time has elapsed:            stop
if once and total_spawned >= max_particles:  stop
accum += CentreWeighted(min_birth_rate, max_birth_rate) * channel * dt
while accum >= 1 and live < max_particles:
    accum -= 1; emit one
```

So `max_particles` is both the live cap *and*, when `once=1`, the total budget:
`pbc_spark` fires 20 sparks, once, and never again.

Per particle:

```
dir      = emitter_basis * Rot(pitch, yaw) * +Z
           pitch, yaw = CentreWeighted(-cone_angle, +cone_angle)   [degrees]
speed    = CentreWeighted(min_speed, max_speed) * max(emitter scale x,y,z)
lifetime = CentreWeighted(min_lifetime, max_lifetime)
spin     = CentreWeighted(-angular_velocity, +angular_velocity)
```

**Speed is multiplied by the emitter's scale.** That is what `hull_impact`'s
comment "In units per second (will get scaled up)" means, and why the shipped
speeds are things like `0.8`-`1.2`: the emitter's transform sizes the effect to
the thing that blew up.

### `FnRandom::CentreWeighted` (`flux.dll @ 0x100480b0`)

Fully recovered. One uniform sample pushed through an S-curve, so it is biased
toward the middle of the range -- *not* a triangular distribution and not a
mean of two samples:

```
u = rand()/RAND_MAX
w = 2*u^2                  if u < 0.5
w = 1 - 2*(1-u)^2          otherwise
return a + (b-a)*w
```

### Ageing and the ramps (`FcParticleDrawBillBoard::Setup`, `0x10050770`)

`FiParticle::AgeStep` (`0x1004da70`) is `*(float *)this -= dt` -- the particle's
first field is its **remaining life, counting down**. `Setup` then computes

```
t = clamp(1 - remaining_life / max_age, 0, 1)         # max_age default 1.0
size   = lerp(scale_on_birth, scale_on_death, t)
       * emitter_scale        if scale_by_emitter
colour = TableLERP(colours[], colour_positions[], t)
       * emitter_age/emitter_time   if fade_on_emitter_age
```

with `1/max_age` precomputed in `OnPropertiesChanged` (`0x1004ff20`), which
also **forces `max_age` to 1.0 when it is absent or zero.**

This is the non-obvious one. **No shipped `draw.ini` sets `max_age`**, so every
ramp in the game is keyed on *seconds remaining*, not on normalised lifetime:
the ramp plays over the **final one second** of a particle's life and is
clamped to `colour_positions[0]` before that. A `pbc_spark` (life 0.3-0.9 s)
starts partway up its ramp -- white/blue -- and cools through yellow and orange
to black exactly as the comment "Firey cooling colour ramp" says. A
`spark_shower` particle (life 2-3 s) sits at its first ramp entry, `(0,0,0)`,
for its first 1-2 seconds and only then flares. Reading `t` as `age/lifetime`
gets both of them wrong.

### Blending

`OnDisplay` (`0x1004ffd0`) sets, inline, `eBlend = 1`, `eZTest = 2`,
z-write off, then walks the particles through `FcBillBoard::Add(pos, size,
roll)`. So a particle is a camera-facing quad that spins about the view axis.

**The `eBlend` enum is now fully resolved.** `dx7graph.dll` is decompiled
(`data/decomp/dx7graph.dll.c`); the enum is applied by
`fcGraphicsDeviceD3D`'s SetBlend implementation (vtable `0x1001526c` slot
`+0xb4` -> `dx7graph.dll @ 0x10007e00`, reached from
`FcGraphicsEngine::DispatchState`, `flux.dll @ 0x1005d540`, engine state
`+0x175c`), through two 4-entry lookup tables the device builds from the D3D
caps in `dx7graph.dll @ 0x10004a10` ("Building source/destination blend
factor lookup table"). Best-case (every 2001 card):

| eBlend | SRCBLEND | DESTBLEND | meaning |
|---|---|---|---|
| 0 | -- | -- | blending and alpha test disabled: opaque |
| 1 | ONE | ONE | pure additive (particles, beams, Draw4x4) |
| 2 | SRCALPHA | ONE | additive scaled by alpha (HUD, shockwave state, movies, LDA) |
| 3 | SRCALPHA | INVSRCALPHA | standard alpha blend (cornflakes, planet atmosphere) |

For non-zero modes the device also enables alpha *test* iff the source
factor is SRCALPHA (`0x10007e86`). This confirms the additive inference
below, and pins the other three values.

---

## 4. What we built

- **`game/scripts/particle_fx.gd`** (`ParticleFx`) -- a generic, data-driven
  player. `ParticleFx.spawn(parent, base, "pbc_spark", xform, scale)` parses
  the four INIs (cached), runs the emission and integration model above on the
  CPU, and draws through a `MultiMeshInstance3D`: camera-facing quads oriented
  on the CPU (Godot's `BILLBOARD_ENABLED` overwrites the basis and would lose
  the per-particle roll), additive, depth-test on, depth-write off. Nothing is
  hardcoded per effect.
  Draw classes: `FcParticleDrawBillBoard`, `icCornflakeDraw` (a small shader
  picks the atlas cell out of the combined colour+mask sheet; alpha-blended,
  since a cutout mask is meaningless for additive art), `FcParticleDrawModel`
  (instances the extracted kibble glTF).
- **`tools/iw2/sfx.py`** -- extracts the 23 `sfx/*.lws` scenes into
  **`data/json/sfx_effects.json`**: per effect, its engine index, its
  `size_weight`, the event that fires it, and its `low` / `high[]` variants,
  each with fps, last frame, flipbook, particle systems (with parenting
  resolved and any animated scaler's keys), sounds (resolved through the
  `FcSoundNode` INI to the actual wave, with volume and min range), lights
  (colour, range, and the real intensity envelope) and the special avatars with
  their tint/lifetime. Avatars additionally carry their per-axis static chain
  scale (`scale_xyz`; for an `icBeamAvatar` x = half-width, z = length), the
  chain's scale envelope (`scale_keys`, `[frame, value]` -- from the link
  whose scale actually *animates*, e.g. `beam_scaler_thick/_thin`, so a
  scaler keyed 0 at frame 0 doesn't zero the static product) and, when
  parented, `parents`: the parent nulls innermost-first, each with its
  frame-0 `hpb`/`scale` and -- if keyframed -- `keys` as
  `[{frame, hpb, scale}]` (scene frames, degrees). That is the whole
  antimatter beam rig: the `FatBeamsH/P` / `SkinnyBeamsH/P` spinners and the
  `beam_scaler_*` envelopes, verbatim from the LWS. Plus the engine block:
  `cull_detail`, `low_detail`, the 150 m threshold and the `DoFinalExplosion`
  constants. Runs in `extract_all`.
- **`tools/iw2/lws.py`** -- the scene parser was silently dropping exactly what
  this needed. It now keeps `FramesPerSecond` / `FirstFrame` / `LastFrame`,
  `LightRange`, and `LgtIntensity (envelope)` -- whose key blocks are
  *value-first, frame-second*, the reverse of `ObjectMotion`. (It previously hit
  `float("(envelope)")`, swallowed the `ValueError` and moved on, so every
  animated light in the game read as intensity 0.)
- **`game/scripts/explosion_fx.gd`** (`ExplosionFx`) -- now **fully
  data-driven**: the hand-transcribed `RECIPES` table is gone, and
  `ExplosionFx.play(main, key, xform, size)` reads `sfx_effects.json`, picks the
  variant with the engine's own apparent-size LOD rule (including "draw nothing"
  when the effect has no `_low` scene and is too small), and instantiates the
  particle systems, the flipbook, the lights (driven by the scene's real
  envelope, at the scene's own fps) and the sound. It drives an animated
  emitter scaler per frame, so `plasma_fire`'s 20-second hull fire works.
  `icBeamAvatar` nodes (the antimatter spikes) come entirely from the JSON
  too: width/length from `scale_xyz`, the `beam_scaler_*` envelope from
  `scale_keys`, and the spinner nulls from `parents`.
  `boom()` keeps its signature but now implements `DoFinalExplosion`: four
  scattered puffs, each choosing `explosion`/`small_explosion` by its own
  radius, plus the reactor shockwave.
- **Muzzle flash**: `ExplosionFx.muzzle_flash()`, the `fire?o(5.0)` lens-flare
  light, fired from `weapons.gd::_spawn_at`.
- **Bolt**: `ExplosionFx.bolt_mesh()`, the 4 x 800 m `icBeamAvatar` streak
  textured with `images/sfx/pbc_standard`, replacing the emissive box.
- **Impact**: `main.gd::on_bolt_hit` now plays the `hull_impact` recipe with
  the sparks thrown back along the surface normal, replacing the ad-hoc sphere
  flash and bare sound.

---

## 5. Open questions

Resolved this pass (details in section 6): ~~the `eBlend` enum~~,
~~`icCornflakeDraw`'s size / blend / cell choice~~, ~~`icMovieAvatar`'s
playback rate and quad size~~, ~~`icShockwaveAvatar` / `icLDAAvatar` /
`icBeamAvatar` geometry~~, ~~the sun corona~~ -- all recovered by
decompiling `dx7graph.dll` and raw-disassembling the draw methods Ghidra
drops from `iwar2.dll.c` (`tools/ghidra/disasm.py`).

~~**The extractor drops the beam rig.**~~ Resolved: `tools/iw2/sfx.py` now
exports every avatar's per-axis chain scale (`scale_xyz`), takes the chain's
scale envelope from the link whose scale actually animates (so the rotation-
only `FatBeamsH`-style spinners no longer shadow the `beam_scaler_*`
envelopes, and their static scale is no longer dropped -- the old collapse
that wrote `"scale": 0.0` for every beam), and exports the parent-null chain
(`parents`) with its authored rotation/scale keys. `explosion_fx.gd` plays
the rig from the JSON; the hand-transcribed `AM_BEAM_RIG` stopgap is retired.
One deliberate change against the stopgap: the LWS authors the skinny fan's
180 in `SkinnyBeamsH`'s *pitch* channel at frame 0 (unwinding to 0 by frame
60), which `AM_BEAM_RIG` had approximated as a static *heading* offset; the
runtime now plays the authored channels, so the skinny fan's mid-flight
orientation differs from the stopgap (widths, lengths, envelopes and spin
rates are bit-identical).

Still open:
- **`m_game_time` units.** The shockwave spin is
  `frac(FnTimeWin32::m_game_time * 1e-5) * 2pi`; `m_game_time` is a uint we
  believe is milliseconds (giving 3.6 deg/s), but we have not read the
  variable's writer in flux.dll. `SHOCKWAVE_SPIN` assumes ms.
- **The sun/planet LOD camera scalar.** The apparent-size cull in
  `FUN_100ce2d0` (`0x100ce2d0`) is `radius / cameraZ < 0.0025
  (_DAT_1011d068) * camera+0x34`; `camera+0x34` is an unread camera parameter
  (fov-derived). We draw the sun unconditionally -- the cull only matters at
  extreme range.
- **`icPlanetAvatar`'s atmosphere/halo pass.** The display virtual
  (`0x100ccc80`, ~3.8 KB of FPU code) is structurally recovered (section 6)
  but the atmosphere-ring vertex construction is not fully decoded; the
  remaster's planet halo stays as it is.
- **Does the light range scale with the effect's size?** The engine sets the
  effect node's scale to `size` (`0x100d3210`) and the light hangs inside that
  node, so we multiply `LightRange` by `size`. Whether the original's D3D light
  really inherits the node scale is applied in `dx7graph.dll` and unverified.
  Likewise `LIGHT_ENERGY` (8.0) is a renderer fit, not game data: LightWave
  intensities are 0..1.5 (5.0 for antimatter) and mean nothing to Godot.
- **`icDisruptorDynamics` and `icTeleportDynamics`.** The property maps are
  recovered; the behaviour behind `follow_edge` (crawl over the target's
  geometry) and `prob_jump` is not, so `disruptor`, `ldsi`, `infection`,
  `kibble` and `cornflake_field` have no player.
- **The `asteroid_impact` name test.** `icBullet` picks it when the target's
  category (`sim+0x194`) is `0xb` or `0xe` **and** an `FcString::Find`-shaped
  import (`0x10116a0c`) on the target's string field (`sim+0x184`), against a
  runtime-initialised global (`0x10166318`), returns >= 0. Both the category
  enum and the global's value are set at runtime, so "what counts as rock" is
  known by shape but not by name -- we do not fire `asteroid_impact` yet.

---

## 6. The avatar draws, recovered by raw disassembly

Ghidra's decompiler **silently omits** functions it cannot recover ("could
not recover jumptable", or regions its disassembler never reaches) -- in both
`iwar2.dll` *and* `dx7graph.dll` (`fcGraphicsDeviceD3D`'s vtable methods are
missing from `dx7graph.dll.c` even though the DLL decompiles). The bytes are
in the file: `tools/ghidra/disasm.py <dll> <va> [end|+len]` reads them out of
the PE section table and disassembles with capstone, resolving import thunks
and `symbols.txt` names. Vtables are data, so dispatch targets are read with
a 4-byte scan at the vtable VA (the method used for the HUD sprite atlas,
`docs/hud_elements.md`).

Every `Fi/FcSceneNode` subclass below shares one vtable shape: **slot 14
(`+0x38`) is Prepare, slot 16 (`+0x40`) is the display draw**; slot 15 is
Build (push onto the display list).

### The engine state block (flux.dll -> device)

`FcGraphicsEngine` keeps the current polygon state at `this+0x1758` and
`DispatchState` (`flux.dll @ 0x1005d540`) forwards dirty entries to
`fcGraphicsDeviceD3D` (vtable `dx7graph.dll @ 0x1001526c`):

| engine | dirty bit | device slot | meaning |
|---|---|---|---|
| `+0x1758` | 8 | `+0xb0` | eCull (device table `+0x864`: 0 = none) |
| `+0x175c` | 9 | `+0xb4` `0x10007e00` | eBlend (see section 3) |
| `+0x1760` | 10 | `+0xb8` `0x10007f00` | eZTest |
| `+0x1764` | 11 | `+0xbc` `0x10007f80` | z-write enable (renderstate 0xe) |
| `+0x1768` | 13 | `+0xc4` -> SetTexture stage 0 | current sTexture |
| `+0x1774` | 14 | `+0xcc` -> `FUN_10008010` | texture filter (min/mag) |
| `+0x1778..` | 0/1 | -- | current vertex colour RGBA (`+0x1784` = alpha) |

An avatar's `sPolygonState` is `{eCull, eBlend, eZTest, bool zwrite, bool,
sTexture}` -- each avatar class keeps one static instance, built by a static
initialiser that Ghidra *does* decompile, which is where the blend/ztest
values below come from.

### FcBillBoard::Draw4x4 (`flux.dll @ 0x1004c420`)

`Draw4x4(pos, roll, scale_vec, intensity, colour, fade_by_depth, depth_cull)`
draws **one texture quadrant mirrored 4x**: an 8-triangle fan around `pos`,
centre UV exactly `(1, 1)`, corners `(0.0078125, 0.0078125)` (a half-texel
inset), edge midpoints at the texture's other two corners. The quad axes are
the camera's world-space right (`engine+0xe0`) and up (`engine+0xec`) rotated
by `roll`, scaled by `scale_vec.x` / `.y` (`.z` unused). It **forces
`eBlend = 1` (pure additive) and `eCull = 0`**, and writes
`colour * intensity` (optionally scaled by `(far - depth)/far` when
`fade_by_depth`). This is the primitive behind both the sun corona and the
shockwave; `StarFx.quadrant_fan_mesh()` is its Godot form.

### icSunAvatar (ctor `0x100d2910`, Prepare `0x100d2b30`, draw `0x100d2b80`, vtable `0x1011d1fc`)

This is the answer to "the halo moves":

- **Prepare**: `phase (this+0xe0, double) += dt * 0.010472` (double @
  `0x1011d248` = 0.6 deg/s), then positions the node on the sim.
- **Draw**: two `Draw4x4` calls at the sun's position, scale = `radius * 1.3`
  (`_DAT_1011d250`; the ctor's 1.4 @ `_DAT_1011a440` is only the *bounding*
  radius), texture = `icPlanetProperties+0x14` = `images/planets/sun_halo`
  (`LoadTextures @ 0x100cbc90`), through `Push`/`Pop` with linear filtering.
  - roll = `-atan2(sunY . cam_up, sunY . cam_right)` where sunY is the node's
    world Y axis (`this+0x8c`) -- **the halo counter-rotates as the camera
    rolls**, which is the motion the original shows.
  - layer 1: `roll + phase`, colour `this+0xc0`; layer 2: `roll - phase`,
    colour `this+0xcc`, scale * **1.05** (`0x100d2d40`). The two colours are
    two *independent* `icSun::PickColour` draws from the ctor, so the layers
    differ in tint and counter-rotate at 1.2 deg/s.
- **The disc** is one of the three `planets.ini planet_models[]` LOD spheres
  (`icPlanetProperties+0x28`), LOD-picked by `FUN_100ce2d0` (cull below
  apparent size `0.0025 * camera+0x34`, thresholds = `detail_switch[]`),
  rendered with the avatar's class-texture shader as
  `FiSurface::m_p_global_shader`.

### icShockwaveAvatar (ctor `0x100cfa50`, Prepare `0x100cfc90`, draw `0x100cfcb0`, vtable `0x1011d140`)

- struct: tint at `+0xbc..0xc4` (property `tint`), lifetime at `+0xc8`
  (property `lifetime`), age at `+0xcc`, random unit axis at `+0xd0`.
- `sPolygonState` @ `0x10171e10` (init `0x100cf9d0`): cull 0, **blend 2**,
  ztest 1, z-write off, texture `images/sfx/shockwave` -- but `Draw4x4`
  then forces blend 1, so the shockwave is **pure additive**.
- Prepare: `age += dt`.
- Draw: **two counter-rotating `Draw4x4` fans**, scale = the node's
  **world radius** (the LWS animates the null's scale 0 -> 1 over the scene,
  x the effect size), colour = `tint`, intensity = `clamp(1 - age/lifetime)`,
  both depth-fade bools true. Roll = `-atan2(axis . cam_up, axis . cam_right)
  +/- frac(m_game_time * 1e-5) * 2pi` (`0x1011d18c` / `0x10119f94`).

### icBeamAvatar (ctor `0x100bb5e0`, Prepare `0x100bb810`, draw `0x100bb830`, vtable `0x1011c9b0`)

- properties (`0x100bb3d0`): `repeat` (float, `+0xbc`, default 1), `speed`
  (float, `+0xc0`, default 0), `texture` (string, `+0xc4`).
- `sPolygonState` @ `0x10168230` (init `0x100bb560`): cull 0, **blend 1
  (pure additive)**, ztest 2, z-write off.
- Prepare: `u_phase (+0xc8) += dt * speed` -- the texture scrolls.
- Draw: an **axial billboard**: one quad from the node origin along local +Z
  x `world_scale.z`, half-width = `world_scale.x`, turned about the beam axis
  to face the camera (`side = normalize(cross(beamZ, campos - pos))`).
  UVs: u runs `phase .. repeat + phase` along the LENGTH, v `0..1` across.
  So the PBC bolt (LWS scale `4 1 800`) is **8 m wide** and 800 m long.
- LOD: apparent = `scale.x / cameraZ`; below `2e-05 * gfx` (`0x1011c9a8`)
  nothing; below `0.001 * gfx` (`0x1011c9ac`) a **line primitive** from
  (0,0,0) to (0,0,1) with blend 2 and alpha fading in the transition band
  (`gfx` = `engine+0x108`, the detail scalar).

### icLDAAvatar (ctor `0x100c9bf0`, Prepare `0x100c9d80`, draw `0x100c9dd0`, vtable `0x1011cfcc`)

- texture `images/sfx/lda`; `sPolygonState` @ `0x10171b10` (init
  `0x100c9af0`): cull 0, **blend 2**, ztest 2, z-write off. Age at `+0xbc`.
- Prepare: `age += dt`; **self-destructs after 1 s** (`0x1011cfc0`).
- Draw (fan helper `FUN_100c9f40 @ 0x100c9f40`): a **16-triangle cone**,
  apex at local `+Z * 4.0` (`0x1011cfbc`), rim on the z=0 circle. Rim radius
  = `(2 * 30 / life) * age` for the first half of the life (`0x10117738` =
  0.5), then **30** (`0x1011cfb8`) while alpha = `2 * (1 - age/life)` fades
  out. Apex UV u = 0.5, rim u alternates 0/1 per triangle; **v scrolls
  rim-to-apex**: apex v = `-age * 1.0` (`0x1011cfc4`), rim v = `1 - age`.
  Apex alpha = the fade, **rim alpha = 0**. Vertex colour white; the purple
  is the texture and the scene light.

### icMovieAvatar (ctor `0x100ca660`, Prepare `0x100ca990`, draw `0x100caa50`, vtable `0x1011d018`)

- properties (`0x100ca410`): `url` (string, `+0xbc`), `frame_count` (int,
  `+0xc0`); per-frame textures in a grown array at `+0xc4`; frame counter at
  `+0xc8`; **random unit roll axis** at `+0xcc` from the ctor.
- `sPolygonState` @ `0x10171be8` (init `0x100ca5e0`): cull 0, **blend 2**,
  ztest 2, z-write off.
- Prepare: `frame += 0.5` **per rendered frame** (`0x10117738`), gated on
  `m_game_delta_time > 0` -- playback is framerate-locked (30 flipbook fps at
  the original's 60 Hz), not clock-based.
- Draw: stops once `floor(frame) > frame_count`. Builds a billboard basis
  around the camera view direction with the random axis fixing the roll,
  quad **half-extent = the node's world radius** (LWS scale x effect size;
  ctor base radius 1.0). Draws **two quads, frame N and N+1, alpha-crossfaded
  by the fractional frame** (`alpha = 1 - |i - frame|`) -- that is why the
  state is blend 2, not 1.

### icCornflakeDraw (ctor `0x100bc340`, draw `0x100bc620`, vtable `0x1011cb58`)

- `sPolygonState` @ `0x101682c8` (init `0x100bc2b0`): cull 0,
  **blend 3 (standard alpha)**, ztest 2, **z-write ON** -- the flakes are the
  only alpha-cutout in the effect system, which is what the mask sheet is for.
- The ctor builds one combined colour+mask texture from
  `images/sfx/cornflakes` + `cornflake_masks`.
- `FUN_100bc480 @ 0x100bc480` precomputes **4 random tumble axes x 256
  rotation steps** (step = 2pi/256, `0x1011cb90`).
- Draw, per particle: a **tumbling world-space plate** (not a billboard):
  rotation = the particle's roll angle (x 256/2pi, `0x1011cb94`) about axis
  `index & 3`; half-extents `size x size/2` where **size = 0.075
  (`0x1011cb98`) x the emitter scale**; atlas cell = **`index & 15`,
  sequential** (UV table `0x1011ca58`, row-major 4x4); colour =
  `(normal . world_light_dir)^2` grey (`FcWorld+0x60c`) -- the flakes are
  *lit*, tumbling dark as they turn edge-on to the sun.

### icPlanetAvatar (Prepare `0x100ccbb0`, Build `0x100ccc60`, draw `0x100ccc80`)

Structurally recovered, not fully decoded:

- Prepare positions the avatar on the sim and -- property `3rfts_mode`
  (`0x100cc820`, a bool) -- pulses the X/Y scale with `sin^2/cos^2` of game
  time, the engine's joke mode.
- Build pushes onto the display list iff the global planet-visibility byte
  `0x10171df0` is set.
- The draw builds the world transform from orientation x scale, LOD-picks the
  `planet_models[]` sphere with the same `FUN_100ce2d0` as the sun, renders
  it with the class shader, and -- when the record has an atmosphere and
  `sim+0x210 > 0` -- builds a camera-facing basis for the atmosphere pass
  (`sPolygonState` @ `0x10171dc0`: cull 0, blend 3, **ztest 0**, z-write
  off -- `planethalo`). The atmosphere-ring vertex loop is not decoded; see
  Open questions.

### What we built from this

- `star_fx.gd`: the real corona -- two counter-rotating, camera-roll-tracking
  quadrant fans at radius x 1.3 / x 1.365, independent PickColour tints,
  0.6 deg/s phase. (`# @element icSunAvatar`)
- `explosion_fx.gd`: `icShockwaveAvatar` (the reactor / antimatter / alien /
  LDSI explosions now draw), `icMovieAvatar` (real quad size, framerate-locked
  crossfade -- `MOVIE_QUAD`/`MOVIE_FPS` placeholders retired),
  `icLDAAvatar` (the shield-hit cone), and the antimatter 8-beam rig
  (`icBeamAvatar` axial billboards, driven by the `scale_xyz` / `scale_keys` /
  `parents` fields in `sfx_effects.json`; the interim `AM_BEAM_RIG` constant
  is retired).
- `particle_fx.gd`: `icCornflakeDraw` -- real size (0.075), 2:1 plate, 3D
  tumble, sequential atlas cell, sun-lit grey.
- `tools/ghidra/disasm.py`: the raw-disassembly tool.

---

## 7. Inside a nebula: `icNebula` + `icCloudAvatar`

The ledger had `icNebula` and `icNebulaAvatar` both down as "covered elsewhere:
the per-system sky backdrop". That was wrong, and it is why the Effrit did not
render. **`icNebulaAvatar` is only the distant backdrop model**; a nebula is a
*volume*, and what you see from inside it is a different class the ledger did
not know existed -- **`icCloudAvatar`**.

### `icNebula`, the sim

| | |
|---|---|
| registered | `0x10067450` (`FcRegistry::RegisterClass`, name `icNebula`, parent `icGeography`) |
| factory / ctor | `0x10067480` -> `0x10067660`, `0x200` bytes |
| property map | `0x100674f0` |
| vtable | `0x1011ae48` |
| map kind | 7; `icSolarSystem::ParseNebulaInfo` @ `0x1004e4f0` |

Three properties, and the map record carries none of them, so the game's one
nebula runs entirely on the constructor's defaults:

| property | offset | type | default (`0x10067660`) |
|---|---|---|---|
| `depth` | `+0x1e0` | float | **30000.0** (`0x46ea6000`) -- visibility inside, meters |
| `colour` | `+0x1e4` | FcColour | **(0.6745, 0.2784, 0.0824)** = `(172, 71, 21)` |
| `texture_url` | `+0x1f0` | FcString | **`texture:/images/sfx/cloud`** |

plus `radius`, which comes from the map record's `+0x134` (see `geography.md`).
`+0x1f4` is the "am I inside" latch, `+0x1f8` the sim's own avatar.

**`icNebula::Think`** (vtable slot 13, `0x10067870`) is the whole simulation:

```
Think(dt):                                              ; 0x10067870
    if solar_system(+0x12c) != FcWorld::m_p_active_world: return
    o = Opacity()                                       ; 0x10067990
    inside = (o > 0)
    if inside != was_inside(+0x1f4):
        inside ? EnterNebula()   ; 0x10067ae0 -> icSolarSystem::EnterNebula 0x1004eaa0
               : LeaveNebula()   ; 0x10067b20 -> icSolarSystem::LeaveNebula  0x1004eb40
        was_inside = inside
    if inside: icSolarSystem::SetNebulaOpacity(o)       ; 0x1004eaf0, clamps 0..1

Opacity():                                              ; 0x10067990
    d = |player - centre|                               ; plain sphere test
    if d >  radius:              return 0
    if d <= radius * 0.75:       return 1               ; _DAT_10117d8c = 0.75
    return 1 - (d - 0.75r) / (0.25r)                    ; linear rim ramp
```

That is *all* it does. **A nebula does not fog sensors, does not damage, does
not inhibit LDS, and has no density model** -- the volume is uniform, and the
only thing the opacity feeds is the renderer. (The one thing it does to the
*game*: `icAIServices::InnerMarkerRadius` special-cases it to `radius * 0.9`
and `OuterMarkerRadius` to its plain radius -- already in `original.md` s4a.)

### What the opacity does: `icSolarSystem::Render` @ `0x1004d150`

```c
if (opacity(+0x5fc) <= 0) { gfx.FogEnabled = false; far = m_far_clip; }
else {
    far = opacity * depth(+0x5f8) + (1 - opacity) * m_far_clip;
    gfx.FogParameters = { colour.rgb, start = 100.0f, end = far };   // gfx+0x1794
    gfx.FogEnabled = true;                                           // gfx+0x17ac
    far *= 1.1f;                                                     // _DAT_10119e94
}
gfx.NearClip = 0.1f;  gfx.FarClip = far;
...
if (opacity < 1) { scene.Add(starfield); scene.Add(cyclorama); }   // <-- BOTH DROPPED AT 1
if (opacity > 0) { cloud->opacity(+0x16c) = opacity; scene.Add(cloud); }
```

So: hardware fog in the nebula colour from **100 m** to the visibility depth,
the far clip hauled in to `end * 1.1`, **the starfield and the geog backdrop
stop being drawn at all once you are past `0.75 * radius`**, and the
`icCloudAvatar` singleton (`DAT_10171638`, built at `0x100c27e0`) gets switched
on with the opacity.

### `icCloudAvatar`, what you actually see

Registered `0x100c2740` (name string `0x10161a78`), ctor `0x100c27e0`, `0x170`
bytes, vtable `0x1011cddc`. **Ghidra dropped both of its draws**; they were
raw-disassembled.

Layout: `+0xbc` colour, `+0xc8` texture url, `+0xcc` `depth`, **`+0xd0` = cell
size = `depth * 0.25`** (`_DAT_101191ec`), `+0xd4` = cell `* 0.9`, `+0xd8` the
loaded texture, **`+0xdc` a ring of 4 cells, stride `0x10`**, `+0x11c` the front
cell index, `+0x120` the scroll phase, `+0x124/+0x128` the lateral scroll,
`+0x130/+0x134/+0x138` the shared UV + roll, `+0x13c` the previous camera basis
(3x3), `+0x160` the previous camera position, `+0x16c` the opacity.

Each cell is four floats, rolled in the ctor and again on every recycle:

| | |
|---|---|
| `+0x0`, `+0x4` | random UV offset, `rand(0, 1)` each |
| `+0x8` | random UV scale, **`rand(0.1, 0.3)`** (`0x3dcccccd` .. `0x3e99999a`) |
| `+0xc` | random angle, `rand(0, 2*pi)` -- **generated and never read; dead** |

**Draw @ `0x100c2bf0`** (slot 17), the cloud layers:

```
z_j   = phase + (3 - j) * cell,   j = 0..3        ; 4 screen-filling billboards
far   = cell * 4.0                               ; _DAT_101190b4 -- exactly `depth`
fade  = far  * 0.5                               ; _DAT_10117738
a     = opacity * 0.4                            ; _DAT_10117558
if z > far:   a  = 0
if z > fade:  a *= 1 - (z - fade) / fade         ; far fade
if z < cell:  a *= clamp(z / cell, 0, 1)         ; near fade-in as a layer arrives
gfx.SetAlpha(clamp(a, 0, 1))                     ; * GlobalAlpha
gfx.SetBlend(2)      = SRCALPHA-ONE (additive)   ; gfx+0x175c
gfx.SetZTest(2)      = normal depth test         ; gfx+0x1760
gfx.SetZWrite(false)                             ; gfx+0x1764
gfx.SetTextureImage(cloud)                       ; gfx+0x1768
gfx.FogEnabled = false                           ; the clouds are not fogged
FcBillBoard::Add(eye + fwd * (near + z), w = z * gfx[0x108], uv[8])
  uv corners = uv_scroll + cell.uv  +/- A * s  +/- B * s
    A = (cos angle, sin angle),  B = (-sin angle, cos angle)
    s = (z * gfx[0x108]) / cell * cell.scale     ; tile has a fixed size in METERS
```

`w = z * gfx[0x108]` is the projection half-angle, so **every layer exactly
fills the screen at its own depth**; only the UVs differ. The cells are a ring
buffer: `phase` slides by the camera's forward displacement, and when it falls
out of `[0, cell)` the index steps and the cell that wrapped round is handed a
fresh random tile -- so flying forwards is an endless supply of new cloud.

The shared scroll and roll (`0x100c3150` + `0x100c3700`) come from the camera's
own motion: the roll of the camera basis since the last frame goes into `angle`;
the yaw and the pitch go **straight into the UV offset in radians** (a radian of
turn slides the tiles by a full period); the camera's sideways translation
divided by the cell size slides them too. There is no world-space cloud field --
it is all screen-space parallax off the camera delta.

**Draw @ `0x100c2a40`** (slot 16) is the other half, and the reason the nebula
is opaque: **one untextured, ALPHA-blended (`SetBlend(3)`), Z-WRITING
(`SetZWrite(true)`) billboard of the flat nebula colour at `z = depth`**, alpha
= opacity. That is the wall that hides everything past the visibility distance
-- and, with the starfield and cyclorama dropped at opacity 1, it is why the
inside of a nebula is a solid coloured murk rather than clouds over stars.

### `icNebulaAvatar` is not this

`icNebulaAvatar` (registered `0x100cb4e0` region, ctor `0x100cb520`,
`OnPropertiesChanged` `0x100cb590`, Build `0x100cb660`, Render `0x100cb680`) has
exactly one property, `url`, loads that model, forces `GlobalTextureQuality(1)`,
and sets **every material to blend 1 (additive) at alpha `0.99`
(`0x3f7d70a4`)**. It is the distant backdrop model out of `geog/*.lws`, and
`icSolarSystem::SetCycloramaRenderPosition` (`0x1004e740`) exempts it and
`icStarfieldAvatar` from being forced into render pass 3 -- they are the sky.
`main.gd::_setup_sky` already builds it, and that part was correct all along.

### What we built from this

- `space_fx.gd`: `# @element icNebula` + `# @element icCloudAvatar`. The
  opacity ramp (`SpaceFx.nebula_opacity`), the 4-cell ring with the real cell
  size / scroll / recycle / random tiles, the four screen-filling additive
  billboards with the real alpha ramps, and the fog.
- `tools/iw2/classify_map.py`: kind-7 records now keep their radius (from
  `+0x134`) and carry `icNebula`'s three property defaults.

### What the inside is *supposed* to look like, numerically

Worth writing down, because two rounds of "it looks like a flat orange sheet"
were argued about on aesthetics and settled on arithmetic.

Sample the real tile (`data/textures/images/sfx/cloud.png`, 256x256 greyscale,
no alpha): mean 0.315, **p05 0.090, p95 0.886, max 1.0** -- it is high-contrast,
not a mid-grey. In linear that is p05 **0.009**, p95 **0.76**. At opacity 1 the
framebuffer is the `(172, 71, 21)` wall plus the layers (`sum(alpha) = 1.0`):

| tile value | framebuffer |
|---|---|
| darkest | **(172, 71, 21)** -- the bare wall |
| mean | (183, 76, 23) |
| p95 | (221, 94, 30) |
| brightest | **(234, 99, 33)** |

**So the original spans 172 -> 234 across the screen. It does not wash out.**
(In practice the top of that range is rare: the three live layers carry
independent random offsets, so their sum concentrates and the real spread is
nearer 172 -> 210. Still plainly cloudy.)

That table is also the regression test. If a render of the deep interior does
not bottom out at `(172, 71, 21)` in the gaps between the billows, something is
adding light that should not be.

### Two bugs this caught, both ours

**The wall was exactly 2x too bright, and it ate the clouds.** Deep inside, the
background measured `(234, 99, 33)` -- and a render with the four layers forced
invisible measured `(234, 99, 33)` *as well*. The layers were contributing one
level out of 255. The cause was not occlusion and not the layers: it was
`main.gd::_setup_sky`'s geog backdrop dome, which is **additive**. Fogged, it
became flat nebula colour -- and then *added* that colour on top of the equally
fogged sky behind it. Fog + fog = 2x, which lands precisely on `(234, 99, 33)`,
the brightest value the engine's own maths ever reaches. Everything clipped
there. `Render` drops the cyclorama at opacity 1 for exactly this reason; we now
drop it too, and the wall bottoms out at `(172, 71, 21)` as it should.

**The far clip mattered, and not cosmetically.** `Render` hauls the far plane in
to `end * 1.1` (33 km at full opacity). We had left it at 600 km on the theory
that the fog would hide anything beyond `depth` anyway. It does not:
`main.gd` draws bodies as impostors *capped* to 250 km and `star_fx`'s corona is
emissive, so **the sun burned a hole straight through the murk**. Pulling the
plane in culls them, which is what the original is doing.

**Deviations, and why.**

- The slot-16 wall and the hardware fog are reproduced *together* by Godot's
  `FOG_MODE_DEPTH` (same colour, same 100 m -> `depth` range, `fog_sky_affect =
  opacity`, which is precisely the alpha-blended wall over the starfield).
- The geog backdrop dome is dropped as soon as the far plane would cut it
  (`NEB_SKY_DOME`), not only at opacity 1. The original's cyclorama is a sky
  pass and cannot be far-clipped; ours is a real mesh parked at a fixed 4.8e5 m,
  and the incoming far plane slices it into a hard wedge across the sky.
- **Colour space.** The original does all of this in 8-bit gamma. Fed raw into
  Godot's linear pipeline the cloud tile lands twice as bright, so it is sampled
  `source_color` and the shader tint is linearised. `fog_light_color`, by
  contrast, is an `Environment` colour and the renderer linearises it *itself* --
  linearising it again by hand drops the rust `(172, 71, 21)` to a blood red
  `(146, 28, 4)`. Decode each exactly once. The numbers are the engine's; only
  the decode is ours.
- Glow is switched off inside the volume. The original has no bloom at all, and
  on a full-screen wall that already sits near the top of the range ours only
  ever pushed it over.
- The per-cell random rotation (`cell+0xc`) is dead in the original, so we do
  not generate it.
- `--nebshot` (in `space_fx.gd`) parks the player beside Lucrecia's Base and
  again out on the rim and writes `data/screenshots/nebula_{inside,rim}.png`.

**Not bugs, checked:** the fog does reach geometry (forced to `end = 500 m`, the
base renders at exactly `(172, 71, 21)`); Lucrecia's Base looks near-black
inside the nebula because its near face is ~1 km away, where the engine's linear
fog contributes ~3%, and it is turned away from the sun with no starfield left
to bounce anything back.

---

## The prison dossier bust — an amber hologram (task #74)

The front end / pause PDA shows a slowly-turning 3D prison-character head beside
its scrolling dossier (`html/prison/*.html`). In the original it is an **amber
hologram**, the twin of Clay's real-time **red** comm hologram (`comms.gd`):
both are drawn by the engine's comms head system — **`icComms` + the
`icHUDTargetMFD` compositor, all in `iwar2.dll`** (the `html_prison` screen is
only the text backdrop; the 3D head is `icComms::RenderPortrait`).

Our first pass rendered the head as an opaque, naturalistically-lit solid and
turned it to a hard profile. That produced three "bugs" that were all one
mistake — *not rendering it as the hologram*:

- **The "gold triangle" by the mouth** (opaque build) was a specular highlight
  thrown by the warm rim light on the cheek. It is in **no texture** — a scan of
  all three `az_anchor_*.png` finds zero gold texels — so it is a lighting
  artifact, not geometry and not a morph. Rendering the head **unshaded**
  (holograms are self-lit, no lights) removes all specular, so it is gone.
- **Untextured surfaces must keep their own dark colour.** The RT heads carry
  small untextured surfaces — `Black` (eyebrow/mouth lines and, on Lori, a flat
  *backing card* at `z=-0.02`, `lori_anchor` prim0) and jaffs' `MouthInner` —
  all with `baseColorFactor` black. Tinting *every* surface flat amber turned
  those into solid **gold blobs** (worst on Lori, where the backing card, drawn
  with depth-write off, floated over the whole face). Fix: tint by
  `sourceColour × amber` (black → black) and render the head **opaque with depth
  writing on**, so the face occludes the backing card. The holographic
  translucency is applied afterwards in 2D, when the viewport is composited.
- **The "missing back of the skull"** is not missing: these real-time avatar
  heads (`az`, `clay`, `smith` …) are hollow **front shells** — the `Body`
  surface of `az_anchor` has **zero** rear-facing triangles. Lit opaquely and
  turned to `-62°` (near profile) the open back shows. The original sits at a
  gentle **3/4 (~40°)** and is **translucent**, so the open back never reads.
- **"Malformed / flat grey-green"** was just the opaque lighting; the amber
  tint + unshaded self-glow restores the intended look.

**The model was already correct.** The bust loads `avatars/az/az_anchor.gltf`
(bare head, slicked-back hair). The sibling `tf_az_anchor.gltf` is a **different
model** — it adds a helmet, headphone rubber and a green `HUDVisor` (the
in-cockpit flight-suit variant), so it is *wrong* for the dossier. Neutral pose
is morph weights all `0` (the menu never touches the blend shapes). No extractor
change was needed — `export_gltf.py` extracts the mesh and its 5 DELT morphs
faithfully.

**Recovered hologram constants** (`iwar2.dll`, cited at point of use in
`menu.gd`):

| thing | value | source |
|---|---|---|
| amber tint | `(1.0, 0.749, 0.0)` | `icComms` ctor `0x1007f720`, `FcColour[0]` (`iwar2.dll.c:105107-109`) — `0x3f800000,0x3f3fbe77,0`. Identical to `GUI_focused` (`igui.pog:38-40`). |
| sweep-flash colour | `(1.0, 0.592, 0.0)` | `DAT_10174fb0`, `FUN_100e6750 0x100e6750` (`iwar2.dll.c:195396-398`) — `0x3f800000,0x3f178d50,0` |
| scanline/panel texture | `texture:/images/hud/ucp` | `icHUDTargetMFD` ctor `0x10101530` (`iwar2.dll.c:195533`), scrolled in V over time (`:195797-804`) |
| panel shader alpha | `0.990` | `iwar2.dll.c:195545` (`0x3f7d70a4`) |
| sweep motion | time-driven, wrapped `0..1` | `iwar2.dll.c:195961-967` |
| rotation | `cos(t·speed)·amp` around base | `icComms::RenderPortrait` `0x100810e0` (`iwar2.dll.c:106525-535`) |

**UNKNOWN** (un-inlined `.rdata`/`.data` the decomp left as `DAT_1011xxxx` /
unnamed FcString tables): the grid cell size (the grid is *baked into* the
`icHUDTargetMFD` panel texture, not drawn as a pixel loop), the scanline spacing,
and the sweep / scanline / rotation **rates and amplitude**. Also UNKNOWN: the
literal `m_speaker_scene_urls` / backdrop strings (which head `.lws` per speaker)
— only the loader (`FcAvatarLoader::Load`, `icComms::CreateHeads 0x1007fcc0`) and
its indexing are visible. These would need a raw `.data`/`.rdata` dump at those
addresses. Our grid/scanline/sweep spacings and rates are **reconstructed** to
match the original's look and are named constants at the top of `menu.gd`.

**Implementation** (`menu.gd`): `_holo_bust()` re-skins every bust surface with
an unshaded, **opaque**, `sourceColour × amber`-tinted `StandardMaterial3D`
(source texture kept, so features/hair still read; no specular; depth on so the
head occludes itself). `_holo_grid()` draws the fine amber grid across the
**whole screen**; the head is then drawn translucently (`draw_texture_rect`
modulate α = 0.86) over a faint amber volume, and `_holo_overlay()` draws the
scrolling scanlines + the soft, bright **upward** sweep band over it. Verify with
`--bustshot` (windowed): it opens the menu on each prison character in turn and
writes `data/screenshots/bustshot_<who>_{a,b}.png` 0.14 s apart — the sweep band
rises ~18-23 px between the two frames. All four heads (az, lori, smith, jaffs)
render whole and correctly.

---

## The prison dossier bust, round 2 — it is a PRE-RENDERED MOVIE (task #75)

Everything above about rendering the bust as a real-time head — hologram-amber
or naturally lit — chased the wrong system. Playtesting kept showing a face with
far more texture detail (eyebrows, lipstick, ear geometry) plus **shoulders**
that no `*_anchor` head model has. The `icGUIMovie` recovery
(`docs/original.md`, "The prison-dossier bust is a PRE-RENDERED MOVIE") settled
it: the original pairs `movies/<who>.bik` (400×400 pre-rendered Bink: head,
shoulders, lighting and rotation baked in) with `html/prison/<who>.html`, six
characters (`az, ocal, ycal, jaffs, lori, smith`, registration order =
**cycle** order), enabled per character via `[icGUIMovie]` config bools
(Act One turns on all but `ycal`), **random start then cycle** per screen open
(`FUN_10017850`).

`menu.gd` now plays `data/movies/<who>.ogv` (the existing Bink→Theora
extraction) in a `VideoStreamPlayer`, **blend-mode ADD** so the black frame
background is transparent and the page's amber grid reads through the dark
regions, exactly as the original composites it. The scanline + sweep overlay
and the scrolling dossier draw in a layer *above* the movie. The sweep band
was also corrected against an original screenshot: a **narrow bright bar
(~5.5 % of the panel) inside a soft warm halo ~3× as tall** — the old 14 %
triangular smear was far too wide. Enabled characters are read from
`user://pog_system.cfg [icGUIMovie]` (written by our `iactone.gd` port),
falling back to the Act One five on a fresh profile. The whole SubViewport /
lights / re-skin-shader rig is gone. `--bustshot` now captures all six
characters (`--bustwait=N` delays the grab to inspect the dossier scroll).

**Panel size and dossier layout** (measured against a let's-play video of the
original front end at 1024×768): the GUI draws the movie window at its
**native 400×400 pixels** in a fixed-pixel layout — 400/768 ≈ **0.521 of the
screen height**, top edge ~9 % down, head in the upper half. (The first cut
wrongly assumed 400/480 = 0.833 — at 640×480 it would be, but fixed-pixel
windows shrink relative to larger screens, and the reference ran 1024×768.)
The dossier is a **tall column below the movie** (left edge ~5 % inside the
panel's, wrap width ~93 % of the panel), running to the bottom of the screen;
lines scroll upward and **fade out over the ~19 %-of-panel gap under the
movie's bottom edge** as they slide beneath the window, then the document
re-enters from the bottom. Dossier HTML is reflowed like a browser would:
raw newlines fold to spaces, only `<p>`/`<br>` break lines — the source files
hard-wrap their paragraphs, which previously produced ragged columns.

**Round 3 — the page geometry EXTRACTED from the binaries** (raw `.rdata`
floats dumped from the DLL images and reinterpreted, same trick as the HUD
palette; renderers read via decomp + `disasm.py` where Ghidra dropped them):

| thing | value | source |
|---|---|---|
| movie window | **400×400 native px at y=0**, x centred between the menu bar's right edge and the screen's right edge, clamped to fit | `icMovie::MovieView` 0x18140 (raw-disassembled; the 400s are immediates, `DAT_10117d90` = 400.0) |
| dossier text rect | movie rect **inset 24 px** each side, from **movie-bottom+2** to the screen bottom | `icMovie::TextView` 0x18220 |
| dossier font | `font:/fonts/handelgothic bt_8pt` | `FUN_100184b0` (the dossier is a real `FcTextWindow`) |
| dossier scroll | **18.0 px/s** (`DAT_10117d40`); **on completion the screen advances to the next character** (vtable+0x3c) | `icMovie::Tick` 0x17e90 |
| grid | **16.0 native px** cell (`DAT_1011d970`) — the same graph-paper grid every HUD block frame draws | `FUN_100e2620` |
| sweep bar | **hard 4.0 px** quad (`DAT_101190b4`), colour **chrome × 0.30** (`DAT_1011c034`), additive, **no halo, no texture** | comm-MFD sweep renderer `FUN_10102490` (the only sweep renderer recovered; the page one assumed identical) |
| sweep motion | **downward sawtooth, 3.0 s period** — `y = frac(time_ms × DAT_10118498 (1/3000)) × travel`; the "reflect" compares against 0.0 so it never bounces | `FUN_10102490` |
| "ucp" texture | **a barcode ribbon** (256×32, digits over bars) scrolled along the MFD frame — NOT a scanline pattern (corrects the old note) | `images/hud/ucp` + `FUN_10101f00` block |

Still reconstructed, with no binary source found: the **fine scanlines**
(possibly a video artifact in the references) and the **text fade-out** under
the movie (`FcGraphicsEngine::DrawText` 0x609c0 hard-scissors glyphs with UV
interpolation — no alpha ramp; the fade matches the reference video and hides
the whole-line pop, so we keep it, flagged as reconstruction). `menu.gd` uses
all extracted values scaled by screen height against the 1024×768 reference.

---

## Comm portraits — every speaker is a real-time head (task #77)

The in-flight comm portraits were half-vibed: Clay rendered live but everyone
else played their **prison-dossier movie** — wrong system. iwar2.dll's string
table loads `lws:/avatars/<who>/<who>_anim01` for **eight speakers** (az, cal,
clay, jafs, lori, maas, smith, young_cal): every comm portrait is a real-time
head. The anim01 scenes (extracted verbatim from resource.zip) share a shape —
head anchor at origin, ambient white 0.25, camera on the z axis (LightWave
`ZoomFactor` → hfov = 2·atan(1/zf)), a white point key light — plus a coloured
**"HeadupGlow"**: steady warm-white for az/jafs/lori, and for cal / smith /
maas / young_cal a **flickering** cockpit-readout wash (shared 60-frame 25 fps
envelope, per-speaker colour/amplitude: cool blue on the Cals, **red on
Smith**, **green on Maas** — Maas' scene has no white light at all, just the
green). Clay alone has the steady red lamp, the 19-key 300-frame motion loop
(which also **drifts the head back** from frame 151 — previously dropped), and
a wider lens (zf 3.2 vs 6.667). On top, `icComms::RenderPortrait` (0x100810e0)
sways every head: yaw = −0.2 rad (`DAT_101184ac`) × cos(t × 0.6π
(`DAT_1011c3e8`)), second axis coupled at 0.25× (`DAT_101191ec`).

`comms.gd` now builds the portrait viewport per speaker from a RIGS table of
the extracted scenes; the movies are gone from comms entirely. The HUD's
comm-MFD interference always uses the 3D-feed mix now (there is no FMV feed).
Verify with `--commshot`: writes `data/screenshots/commshot_<who>.png` for all
eight rigs. UNKNOWN: the per-state anim-speed factor (icComms+0x148) scaling
the sway clock, and old_cal/minor NPCs have no scene (blank channel, like the
original's "no video feed").

## Suns are flare glows, never discs (task #82)

Hoffer's Wake really has TWO suns in the map: **Alpha, a red giant with
radius 1.751e11 m** (class 11, sun_red) at the system centre, and **Beta**
(class 2, sun_blue, r 1.81e8) 3e12 m out. From the Act 0 junkyard the red
giant's true angular size is **65 degrees** -- and our angular-correct
impostor dutifully drew it that way, which is the "massive red sun" report.
The original can never show that: its far plane (600 km) cannot contain a
sun at map distances, so the disc is always culled, and what the player sees
is the icSun's **FcLensFlareNode glow** -- whose world-space branch scales
the flare quad BY DISTANCE (`FcLensFlareNode::Render`, flux 0xe6100:
`size = base * dist`), i.e. **constant apparent size**. Both suns therefore
read as small glows (the reference screenshot's two orange flares = Alpha +
Beta). main.gd now draws stars at a constant apparent half-angle
(STAR_FLARE_DEG = 1.6 deg, reconstructed from reference footage; the
per-variant FcLensFlareNode size tables remain unextracted).

## Round 2 on the sky: grid precision, flare glows, far-planet glows, FOV

- **The "streaks slide upward" bug was 32-bit truncation**: the reference
  grid's anchor is `fmod(true_position, cell)`, but the position was passed
  as a Vector3 -- 32-bit components quantise to ~1e5 m at map coordinates
  (1e12 m), so the anchor wandered. The grid now takes the three 64-bit
  floats and uses fposmod (no sign flip at the origin).
- **Stars render flare-style**: the icSunAvatar's plasma-textured disc is
  only ever visible inside 250 km of a photosphere (never); at the flare cap
  the noise texture read as a "snowball"/"donut". The disc is now a small
  hot core (class colour lerped 0.7 to white) and the corona layers draw at
  2.2x (FLARE_BOOST, reconstructed) standing in for the unextracted
  FcLensFlareNode atlas.
- **Far bodies get their glow**: the original shows a distant planet as a
  bright star-like flare (the reference's Griffon at 371 million km) -- that
  is how you navigate, and why bodies feel "real" as you approach. Body
  impostors now carry a FarGlow billboard (sun_halo, tinted toward white),
  shown while the true disc is smaller than ~0.55 deg half-angle.
- **The flux.ini fields of view are HORIZONTAL** (1.1 rad internal / 1.2 rad
  external): binding them to Godot's vertical axis made the cockpit read far
  wider than the original. The camera is KEEP_WIDTH now.
