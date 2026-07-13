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
