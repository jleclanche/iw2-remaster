# Particles and special effects

How the original builds an explosion, a weapon impact, a muzzle flash and a
bolt. Same rules as `original.md`: every claim carries its source, and what we
could not read out of the game is in **Open questions**, not guessed.

Companion docs: `original.md` (the evidence log), `formats.md` (LWS, INI, the
channel expression language).

---

## 1. There are two layers, and we only had one of them

`data/ini/sfx/<name>/` holds **particle systems** -- twelve of them, each a
`node.ini` + `emitter.ini` + `dynamics.ini` + `draw.ini`. That is the layer we
already had extracted, and on its own it explains nothing: nothing in
`sims/weapons/*.ini` references it, and only two of the twelve are named
anywhere in the INI tree (`fields/asteroid.ini` -> `kibble`,
`fields/debris.ini` -> `cornflake_field`).

The layer above it is **`sfx/*.lws`**, twenty-three LightWave scenes in
`resource.zip` that our extraction drops on the floor. *Those* are the effects
the game fires. A scene is a bag of null objects, each tagged with a `<node>`
directive, and it composes particle systems, a sprite flipbook, a sound and a
light into one effect.

The engine reaches them through **`icVisualEffects`** (`iwar2.dll`; the class
name and its string table are at `0x10162078` / `0x10161f14`). The table is
twelve URL *prefixes*:

```
lws:/sfx/explosion_           lws:/sfx/reactor_explosion_
lws:/sfx/small_explosion_     lws:/sfx/antimatter_explosion_
lws:/sfx/hull_impact_         lws:/sfx/alien_explosion_
lws:/sfx/asteroid_impact_     lws:/sfx/ldsi_explosion_
lws:/sfx/beam_impact_         lws:/sfx/collision_
lws:/sfx/lda_impact_
lws:/sfx/plasma_fire_
```

and two format strings, `"%slow"` and `"%shigh_%d"` (`0x101620a0`,
`0x101620a8`), so the effect resolves to `lws:/sfx/hull_impact_low` or
`lws:/sfx/explosion_high_2` depending on the detail setting (also at that
address: the keys `low_detail` and `cull_detail`). `explosion` and
`small_explosion` are the only ones with three `high_` variants; the game picks
one at random.

**A weapon does not name its effects.** `pbc_bolt.ini` has no effect key at
all. The effect is chosen by the engine from the *kind* of event -- bolt hits
hull, bolt hits asteroid, beam hits, ship dies -- which is why grepping the INI
tree for the link finds nothing.

### What each scene contains

Read out of `resource.zip:sfx/*.lws`.

| effect | flipbook | particle systems | sound | light |
|---|---|---|---|---|
| `explosion_high_0..2` | `deba`, 50 frames, scale 5 | `cornflakes`, `spark_shower` | `large_explosion_1` | 255,165,25 range 50 |
| `explosion_low` | `deba`, 50 frames | -- | `large_explosion_1` | same |
| `small_explosion_high_0..2` | `fzgb`, 40 frames, scale 5 | `cornflakes`, `spark_shower` | `small_explosion_1` | same |
| `hull_impact_high_0` | -- | `pbc_spark` | `impact` | 255,165,25 range 60 |
| `beam_impact_high_0` | -- | `pbc_spark` | `impact` | same |
| `asteroid_impact_high_0` | -- | `pbc_spark`, `asteroid_impact` | -- | same |
| `lda_impact_high_0` | `icLDAAvatar` | -- | `shield_hit` | 177,89,255 range 400 |
| `collision_high_0` | -- | -- | `collision` | -- |
| `reactor_explosion_high_0` | `icShockwaveAvatar tint=(1.0,0.6,0.1) lifetime=2` | -- | -- | 255,255,255 |
| `antimatter_explosion_high_0` | `icShockwaveAvatar` | -- | -- | -- |
| `alien_explosion_high_0` | `icShockwaveAvatar tint=(1.0,0.15,0.1) lifetime=6` | -- | `alien_death` | 191,218,44 range 3000 |
| `ldsi_explosion_high_0` | `icShockwaveAvatar tint=(0.4,1.0,0.2) lifetime=3` | -- | -- | 113,210,66 range 4000 |

The directives:

```
<node class=icMovieAvatar url=texture||images|sfx|deba frame_count=50>
<node template=ini||sfx|cornflakes|node>      instantiate a particle system
<node template=ini||audio|sfx|large_explosion_1>
<node class=icShockwaveAvatar tint=(0.4,1.0,0.2) lifetime=3>
```

(`||` is `:/` and `|` is `/`; `formats.md` already had this.) The light is a
plain LightWave `AddLight` with an `LgtIntensity (envelope)` and `LensFlare 1`.
`explosion_high_0`: 60 fps, keys at frames 0/3/18/60 = intensities 0/1/0.3/0
-- a 50 ms flash decaying over a second. `hull_impact_high_0`: 30 fps, keys at
0/2/15 = 0/1/0 -- a half-second flash.

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
`data/gltf/models/`.

**`icCornflakeDraw`** (`iwar2.dll @ 0x100bc340`): **no properties at all** --
its property map is the base map, which is why `cornflakes/draw.ini` has an
empty `[Properties]` block. It hardcodes two textures,
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

`eBlend` is a 4-value enum (`0/1/2/3` all appear); the HUD and sprites use `2`
and `3`, particles use `1`. The enum-to-D3D mapping lives in `dx7graph.dll`,
which we have not decompiled -- but **`1` must be additive**, on two independent
pieces of evidence: the colour arrays carry no alpha and every ramp *ends* at
`(0, 0, 0)`, and `fade_on_emitter_age` fades a particle out by scaling its
colour toward black. Black can only mean "invisible" under `src=ONE, dst=ONE`.
The ramp is an emitted intensity, not a tint.

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
- **`game/scripts/explosion_fx.gd`** (`ExplosionFx`) -- rewritten from a
  hand-rolled billboard animation into the **composite** player: `RECIPES` is
  the `sfx/*.lws` table above, and `ExplosionFx.play(main, key, xform, size)`
  instantiates the particle systems, the flipbook, the light (driven by the
  scene's real LightWave intensity envelope) and the sound. `boom()` still
  exists and now resolves to the `explosion` recipe, so `main.gd` did not have
  to change for ship deaths.
- **Muzzle flash**: `ExplosionFx.muzzle_flash()`, the `fire?o(5.0)` lens-flare
  light, fired from `weapons.gd::_spawn_at`.
- **Bolt**: `ExplosionFx.bolt_mesh()`, the 4 x 800 m `icBeamAvatar` streak
  textured with `images/sfx/pbc_standard`, replacing the emissive box.
- **Impact**: `main.gd::on_bolt_hit` now plays the `hull_impact` recipe with
  the sparks thrown back along the surface normal, replacing the ad-hoc sphere
  flash and bare sound.

---

## 5. Open questions

- **The `eBlend` enum.** We know particles use `1` and the HUD uses `2`, and we
  are confident `1` is additive (above), but the enum is only *applied* in
  `dx7graph.dll`, which is not decompiled. The other three values are unknown.
- **`icCornflakeDraw`'s size.** The class has no properties and we did not find
  the constant that sizes a flake. `ParticleFx.CORNFLAKE_SIZE` is an explicit
  placeholder, scaled by the emitter transform like everything else.
- **`icCornflakeDraw`'s blend mode and atlas-cell choice.** We infer
  alpha-blended from the existence of the mask sheet, and pick a cell at
  random. Neither is read from the binary.
- **`icMovieAvatar`'s playback rate.** The scenes are 60 frames long at 60 fps
  (`explosion`) or 30 fps (`hull_impact`), but the flipbooks have 50 and 40
  frames. Nothing says whether the movie plays at the scene rate, is stretched
  over the scene, or has its own. Ours runs at 25 fps, inherited from the old
  code.
- **`icShockwaveAvatar`, `icLDAAvatar`, `icBeamAvatar`, `icMovieAvatar`
  geometry.** We have their names, textures and tint/lifetime parameters from
  the LWS scenes, but not their meshes or draw code. The antimatter, reactor,
  alien and LDSI explosions are all shockwave-driven and we do not play them.
- **`icDisruptorDynamics` and `icTeleportDynamics`.** The property maps are
  recovered; the behaviour behind `follow_edge` (crawl over the target's
  geometry) and `prob_jump` is not, so `disruptor`, `ldsi`, `infection`,
  `kibble` and `cornflake_field` have no player.
- **The `sfx/*.lws` files are not in `data/`.** `tools/` should extract them so
  `ExplosionFx.RECIPES` can be data-driven instead of transcribed. Until then
  the table in the script is the only copy.
- **Which effect the engine fires for which event.** We know the twelve names
  and matched the obvious ones (bolt-on-hull -> `hull_impact`, ship death ->
  `explosion`), but the call sites in `icBullet` / `icShockwave` / the ship
  death code are not traced, so e.g. when `small_explosion` is used instead of
  `explosion`, or what fires `plasma_fire`, is unknown.
