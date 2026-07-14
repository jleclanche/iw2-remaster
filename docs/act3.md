# Act 3: the aliens — evidence log

How the Act 3 alien mechanics were recovered from the binaries and what the
remaster does with them. Everything with an address was read out of the DLLs
(`data/decomp/*.c` where Ghidra decompiled it, `tools/ghidra/disasm.py` raw
disassembly where it did not); UNKNOWNs are flagged. The task split across
`iwar2.dll` (the classes), `sim.dll` / `isim.dll` / `iship.dll` (the POG
native bindings — these per-package DLLs in `bin/release/` are where
`RegisterNative` lives, not the exe), and `flux.dll` (the particle base
classes).

## 1. What the mission scripts actually drive

- `iactthree.gd:262-267` — the alien "attack": when an alien closes inside
  **700 m** of a ship, the script does `isim.set_alien_infection_damage(v3,
  140.0)` + `isim.alien_infection_effect(v3, 1)`. A weaker variant at
  `:1715` uses 10.0; `iact3mission10.gd:136` uses 70.0;
  `iact3mission08.gd:1237` 500.0. The aliens themselves fit no weapons.
- `iactthree.gd:1805 / :3205`, `iact3mission10.gd:738` — the counter-weapon:
  `sim.add_subsim(ship, subsim.create("ini:/subsims/systems/nonplayer/
  nps_antimatter_pbc"))` on NPC cruisers, and `.../player/antimatter_pbc` on
  the player.
- `ideathscript.gd:157-199` — death scripts turn the infection off and zero
  its damage.
- `iact2mission05.gd:111` grants the tracker as cargo (`iinventory.add(312,
  1)`, type 312 = `Cargo_HyperspaceTracker`, `icargoscript.gd:5055`);
  `iact2mission22.gd:168-175` polls `iship.has_hyper_space_tracker(player)`
  and compares `iship.hyper_space_tracker_target()` (no arguments) against
  destination sims.
- `iact3mission08.gd:1214` creates `ini:/sims/ships/aliens/alienswarm` — an
  INI that **does not exist**, not even in the shipped `resource.zip` (only
  `sfx/alienswarm/*` does). In the original that `FiSim::Create` returned
  null and the follow-up calls no-op'd on the null handle.

## 2. icAlienSwarm (iwar2.dll)

Registered at `0x1002c080` with parent **icShip** and *icShip's own property
map* — the class adds no properties. `sims/ships/aliens/alien.ini`: class
icAlienSwarm, hit_points 2000, armour 52, radius 200, speed (1000,1000,1000),
accel (190,190,190), type `T_Alien`, avatar `lws:/avatars/aliens/setup_red`.

- **ctor `0x1002c0f0`**: clears a was-hit flag at `+0x300`, raises sim flag
  `0x80000` (meaning UNKNOWN — nothing else in the decomp tests that bit).
- **`OnPropertiesChanged` `0x1002c1c0`**: width/height/length (`+0x208/20c/
  210`) = 2 × radius (`+0x1c`).
- **`ApplyWeaponDamage` `0x1002c2c0`** — the whole fight in one function:
  1. `+0x300 = 1` (arms the pain channel), for EVERY hit;
  2. flinch: `velocity += normalize(pos − impact) × 0.7 (0x101191e8) ×
     MaxSpeed().z` (the length is the alpha-max-beta-min approximation,
     constants 0.25/0.34375 @ `0x101191ec/f0`);
  3. gate: calls the damaging sim's vtable `+0xdc`. Dumping iiSim's vtable
     (`0x1011bf2c`, found via the real dtor at `0x10078100` — `0x1002bed0`
     is just a `jmp`) identifies slot `+0xdc` as
     **`iiSim::IsAntimatterBasedWeapon` (`0x10001520`)**; icMissile
     overrides it at `0x1000f7d0`. Only if it returns true does
     `icShip::ApplyWeaponDamage` run; otherwise the function returns 0.0.
     The flag comes from the projectile INI: `antimatter_based=1` is set by
     exactly two weapons, `sims/weapons/antimatter_bolt.ini` (damage 700,
     penetration 70, half_time 0.6, speed 6550, lifetime 2.3) and
     `antimatter_beam.ini`.
- **`UpdateAvatar` `0x1002c1f0`**: avatar node scale (`+0x5c/60/64`) = ship
  radius; if the hit flag is set, ONE random pain channel — `rand() % 6 >>
  1`, uniform over the table at `0x1015aff8` = FcStrings `"pain1"/"pain2"/
  "pain3"` (built at `0x1002bf60` region from literals `0x1015b018/20/28`) —
  is set to 1.0 and the flag clears; otherwise all three are forced to 0.
  If max hitpoints (`+0x1b0`) > 0, channel `"damage"` (`0x1015b030`) =
  `1 − hp(+0x1ac)/max`.
- **`OnExplode` `0x1002c4b0`**: creates `ini:/sims/explosions/
  alien_explosion` (icShockwave, `final_radius=1, lifetime=6,
  initial_damage_rate=2000, alien=1`), overwrites its final radius (`+0x1e0`)
  with **swarm radius × 4.0 (`0x101190b4`)**, copies position and velocity,
  inserts it, returns **true** — which suppresses the standard four-puff
  `DoFinalExplosion`.

The avatar scene (`avatars/aliens/setup_red.lws`, converted to
`data/json/scenes/avatars/aliens/setup_red.json` / the gltf) contains: the
`ini:/sfx/alienswarm/node` particle node, five animated icBeamAvatar
tentacles under spinning `beam_scaler` nulls, `<anim channel="pain1?o(1.0)
pain2?o(1.0) pain3?o(1.0)">` parenting a `pain_flare` light, `<anim
channel="damage?+s(2.0)">` parenting `damage_flare`, and sound nodes
`audio/sfx/alien_loop.ini` (FcLoopSoundNode, pitch_bend 1.1, min_range 2000)
plus `alien_pain{,2,3}.ini` with `play_channel=pain1/2/3` — the pain
channels fire the flare AND the shriek.

## 3. icAlienSwarmAvatar / Dynamics / Draw

- **icAlienSwarmAvatar** (factory `0x100b9640`, ctor `0x100b96a0`): a stock
  `FcParticleEmitterNode` (`+0x24 = 30`, `+0xb0 = 1.0`), no properties.
  `sfx/alienswarm/node.ini` points it at the alienswarm emitter/dynamics and
  **`draw = ini:/sfx/cornflakes/draw` (icCornflakeDraw)**.
- **icAlienSwarmDynamics** (ctor `0x100ba270`, map `0x100b9fe0`, vtable
  `0x1011c8f8`; Spawn `0x100ba5d0`, Update `0x100ba9e0`, Radius `0x100bace0`
  — all Ghidra holes, recovered by raw disassembly). **Each particle is a
  point on its own Lorenz attractor**: σ=10 (`0x101190c0`), ρ=28
  (`0x1011c950`), β=8/3 (`0x1011c94c`), integrated in adaptive substeps
  (k = 0.0253 (`0x1011c8f4`) × dt, dt clamp 5.0 @ `0x101183f0`) until the
  squared step sum + 0.015/step (`0x1011c948`) reaches 0.5 (`0x10117738`) —
  constant apparent motion per frame. Divergence guard: any |component| > 60
  (`0x1011c954/58`) resets the state to `rand()·0.7` (`0x101191e8`).
  Position = **0.05 (ctor `+0x1c`) × a per-particle axis permutation** (xyz /
  xzy / zyx, uniform thirds @ `0x1011c944/40`) of the state, and every
  particle keeps a **point-mirrored twin** (vector B at `+0x48`, filled at
  `0x100bad20` with pos = −pos). Particles never die: Update never ages
  them, Reset (`0x100c4a40`) is a bare `ret`. Property reinterpretation
  (confirmed by the INI's own comments): `min/max_death_age` = the SIZE
  range (uniform, not centre-weighted), `angular_velocity` = the
  colour-phase step (phase ping-pongs in [0,1]); `speed` and
  `max_particles` are registered but never read — the real cap is
  allocator-pool-block/52 (UNKNOWN; the remaster uses 128 pairs). Spawn
  direction: unit vector in `cone_angle` (360° shipped = fully random);
  birth rate 1/s through the standard channel-scaled accumulator.
- **icAlienSwarmDraw** (vtable `0x1011c8c0`, Draw `0x100b9d20`, raw): two
  concentric camera-facing billboards per particle (outer size =
  particle[+0] × scale_on_death, inner half size) textured with a quadrant
  of the shared lens-flare atlas; colour = the gradient sampled at constant
  1.0, and the intended per-particle sample at `phase × 0.5` is computed
  and **discarded** (original bug); max_age is written and never read.
  **No shipped INI instantiates this class** — the swarm ships through
  icCornflakeDraw instead, so the size range and colour phase are dormant
  in the shipped game.

## 4. The infection (isim.AlienInfection*)

All four natives are `iiThrusterSim` methods bound by `isim.dll`
(`SetAlienInfectionDamage` / `AlienInfectionEffect` / `AlienInfectionDamage`
/ `IsAlienInfectionEffectOn` at file strings 0x732c-0x7374):

- **state**: `iiThrusterSim +0x258` (damage/s), set at `0x1007ed70`, read at
  `0x1007ee60`. The VISUAL is independent state: `IsAlienEffectOn`
  (`0x1007ee70`) just tests `FindChildByClass(avatar, <effect class>) !=
  null`.
- **the DoT**: `iiThrusterSim::Simulate` (`0x1007e200`), before anything
  else: `if (damage > 0) ApplyDamage(dt × damage, 5, self)` — vtable
  `+0xd0` = `ApplyDamage` (`iiSim` @ `0x10079920`), eDamageSource **5**,
  raw hull path (no armour, no subsim criticals), continuous per tick.
- **the visual**: `AlienInfectionEffect(true)` (`0x1007ed80`) creates
  `ini:/sfx/infection/node` — an **icElectricEffectAvatar** running
  **icDisruptorDynamics** (NOT a shader): `FUN_100c3ce0` hands it the sim's
  models and radius, sets node scale `max(1, radius/15)` (the icDisruptor
  weapon uses /25), and `FUN_100c4150(node, 0.0)` = eternal emitter.
  `AlienInfectionEffect(false)` destroys the node.
- **icDisruptorDynamics** (ctor `0x100c4900`, vtable `0x1011ce74`; Spawn
  `0x100c4e20`+`0x100c5a10`, Update `0x100c4fe0`, NoiseKick `0x100c5f30`,
  intake `0x100c5430`): the model is broken into long polyline edges
  (radius/3 ≤ len < 2×radius, min capped 25 m @ `0x10119454/0x1011a920`),
  subdivided one anchor per 25 m (0.04 @ `0x1011cebc`). Particles spawn in
  TRIPLES on an anchor; `prob_jump` is the chance of a random anchor instead
  of the next one; with `follow_edge=1` (infection: birth 100/s, life 1-3 s,
  100 particles, prob_jump 0.2) the leader crawls the edge at
  seglen/lifetime, its copy follows, the third rides one sub-segment ahead;
  jitter = a 128-entry [-1,1] noise table (`0x101716fc`) at amplitude
  (radius/120 capped 2.0 @ `0x1011cec0/0x10119ec8`) × seglen, ~50%
  sign-flipped, constrained ALONG the edge. Expired particles respawn in
  place while the emitter lives. `speed/cone_angle/angular_velocity` in the
  INIs are dead keys (7-entry property map @ `0x100c46f0` — verified).
  `prob_jump` (`+0x68`) is **not initialised by the ctor** — garbage unless
  the INI sets it (all three shipped INIs do).

## 5. The hyperspace tracker (iship.dll / sim.dll / icCPU)

- **`sim.AddSubsim`** (`sim.dll @ 0x10004e90`): resolve both handles
  (FiSim-derived + FcSubsim-derived) else return false; if the subsim has an
  owner, `FiSim::RemoveSubsim` it; `FiSim::AddSubsim` (`flux @ 0x100bc420`)
  appends it, sets its sim pointer, fires `OnAttachSubsim` (vtable `+0xac`);
  return true. `sim.FindSubsimByName` (`0x10004fe0`) = first subsim whose
  FcSubsim name matches.
- **icProgram** (registered `0x10031d30`, FcSubsim + one property
  `program_id` at `+0x40`, map `0x10031e80`): a bitmask carrier.
  `hyperspace_tracker.ini` = icProgram, `program_id=2048` (= 0x800).
- **icCPU**: `programs` int property at `+0x80` (map `0x100308a0`);
  `icShip::HasProgram` (`0x10002a70`) = `cpu(+0x29c).programs & bit`;
  `icShip::CPU` (`0x10002a30`) returns `+0x29c`, cached by
  `icShip::SetupSystems` (`0x10074830`). The mask is ORed at fitting time by
  the loadout system (`icLoadout::LoadComputerPrograms` `0x10095ea0`, the
  CPU-programs screen `0x1008b080` — `cpu.programs |= program.program_id`).
- **`iship.HasHyperSpaceTracker`** (`iship.dll @ 0x10002f70`): resolve
  handle, must be icShip, then `cpu = ship+0x29c; return (cpu+0x80) & 0x800`.
- **`iship.HyperSpaceTrackerTarget`** (`0x10003080`, NO arguments): player
  ship's `cpu+0xa0` — the DESTINATION of the tracked jump.
  **`HyperSpaceTrackerContact`** (`0x10003020`): `cpu+0x9c`, the jumper.
- **who sets them**: icCapsuleSpace's jump intake (`0x10040530` region,
  before `IsJumping` @ `0x10040c00`): when a ship jumps, if the player has
  program 0x800 AND the jumper is the player's current contact-list target,
  `cpu+0x9c = jumper id; cpu+0xa0 = destination id`, log event 0x67, and
  `SetSimFlag(jumper, 0x40)` (flag meaning UNKNOWN).

## 6. icTeleportDynamics (kibble / cornflake_field)

Ctor `0x100c8870`, map `0x100c86d0` (min/max_birth_rate, max_particles,
angular_velocity), vtable `0x1011cf6c`; Spawn `0x100c8c80`, Update
`0x100c91f0`, SpawnPos `0x100c94b0` (raw-disassembled). **"Teleport" is the
camera teleporting, not the particles**: the class is a shell of world-fixed
ambient motes around the viewpoint. Field radius = max(viewport dimension) ×
the draw's radius × 0.5; spawning is driven by accumulated world movement
(process every √10 m @ `0x101190c0`), on a cone 0.2 (`0x100c9589`) ahead of
travel at speed ≥ 1 m/s, a uniform shell when drifting, radius uniform in
[0.1r, r] (`0x101184b0`) when still; a camera swing faster than π/2 rad/s
(`0x1011a454`) bursts 40% (`0x10117558`) of the cap. A frame that moves
further than the shell radius flushes everything; ≤ 2000 m (`0x1011cfb4`)
refills the whole field instantly, beyond that (LDS/capsule) it regrows at
the birth rate. Update: shift by the graphics delta-focus, integrate
per-particle spin (uniform in [0, angular_velocity] deg/s, `0x10119930`
converts), cull outside the shell or nearer than 5 m (`0x1011cf68`).
Shipped: kibble (rates 20-40, 300 motes, model draw kibble01-04 × 0.4, no
spin), cornflake_field (200 motes, cornflake draw, spin 250°/s).

## 7. What the remaster does (and where)

- `game/scripts/alien.gd` (NEW, `AlienShip extends AiShip`): flinch +
  antimatter gate + pain/damage channels + alien_loop/pain audio + the
  alien_explosion death (radius × 4), avatar scaled by radius, pursues but
  never fires. Spawned by `world.gd::_create_ship` whenever the ships.json
  record's class is `icAlienSwarm`.
- `game/scripts/particle_fx.gd`: `icAlienSwarmDynamics` (Lorenz swarm +
  mirrored twins, drawn through the existing cornflake path),
  `icDisruptorDynamics` (edge intake from the host model's meshes, crawling
  triples, in-place respawn, noise table) via `spawn_on_model()`, and
  `icTeleportDynamics` (movement-driven shell fed by `shift_world`, which is
  exactly the engine's delta-focus in our folded scene).
- `game/scripts/ship_systems.gd`: `infection_damage` (+ `SRC_INFECTION :=
  5`), ticked at the top of `simulate()` exactly as `0x1007e200` does.
- `game/scripts/ai_ship.gd`: `infection_damage` proxy (ShipSystems when a
  subsim model is fitted, raw hull otherwise), death via `main.kill_ai`;
  `bolt_spec` for runtime-fitted cannons (fires the authored projectile with
  its own refire_delay).
- `game/scripts/pog/natives/world.gd`: `sim.AddSubsim` /
  `sim.FindSubsimByName` (fitted list + program mask + cannon spec wiring),
  the `isim.AlienInfection*` trio, `iship.HasHyperSpaceTracker` /
  `HyperSpaceTrackerTarget` / `HyperSpaceTrackerContact`, and the tracker
  capture inside `isim.CapsuleJump`.

### Deliberate divergences

- **Tracker = possession.** The original requires fitting the program on the
  loadout CPU-programs screen; the remaster has no such screen, so owning
  `Cargo_HyperspaceTracker` (type 312) counts as fitted. The runtime
  `sim.AddSubsim` route sets the real program mask either way.
- **Player antimatter fit replaces the bolt spec.** The original fires the
  antimatter PBC alongside the other cannons; our player weapon model is a
  single `bolt_spec`, so fitting `antimatter_pbc` switches it (and the 1.5 s
  refire).
- **The alien death also plays main.kill_ai's generic `boom(70)`** on top of
  the alien_explosion — main.gd is owned elsewhere (see "changes needed").
- **The alien_explosion shockwave deals no damage** (`initial_damage_rate
  2000` in the INI): icShockwave's damaging front is not modelled by the
  remaster at all (pre-existing; explosion_fx.gd owned elsewhere).
- **Swarm particle cap 128 pairs** (engine cap = pool block/52, unread).
- `sfx/alienswarm`'s size range / colour phase are computed but visually
  dormant, faithfully to the shipped draw class (section 3).

### UNKNOWN

- sim flag `0x80000` (icAlienSwarm ctor) and flag `0x40` on a tracked
  jumper.
- The engine's model-point iterator behind the edge intake (`vfn[0x4c]`,
  unresolved vtable): whether it walks true mesh edges or vertex order. We
  walk Godot surface vertex order with the same length filter.
- icCornflakeDraw's Radius slot (feeds the teleport field radius);
  FcAllocatorGlobalPool block size (both particle caps).
- `icAlienSwarmDynamics`'s `time` property (int, default 1000): registered,
  never referenced in any disassembled method.
