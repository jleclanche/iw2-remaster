# Capsule space: the jump between systems

Evidence log for task #48. Everything below was read out of `iwar2.dll`
(decomp in `data/decomp/iwar2.dll.c`, raw bytes via
`tools/ghidra/disasm.py` / `readconst.py` against `build/bin/iwar2.dll`),
`flux.ini` in the game install, and the extracted `data/ini` tree.
Implementation: `game/scripts/capsule_fx.gd` (new) and the `jump_state`
machine in `game/scripts/main.gd`.

## 1. What icCapsuleSpace actually is

Three classes share the name and split the job:

- **icCapsuleSpace** (ctor `0x1003ffb0`, registered via
  `FcRegistry::RegisterClass` with property map `min_exit_speed` /
  `max_exit_speed` @ `0x10165f48`/`0x10165f5c`, flux-set to 500/2000) is a
  singleton **jump manager**, not a place. It keeps an array of `sJump`
  records (0x30 bytes each: from-sim id, dest-sim id, state at +0x08,
  countdown at +0x0c, exit speed at +0x10, exit offset +0x14..0x1c, exit
  velocity +0x20..0x28, `scripted` byte +0x2c, `effects` byte +0x2d —
  layout from `RegisterJump` @ `0x10040440`) and steps them once per frame
  in `PerformJumps` @ `0x10040cc0`.

- **icCapsuleSpaceSystem** (ctor `0x100480b0`) IS a place: a subclass of
  `icSolarSystem` owned by `icCluster` (+0x2c,
  `icCluster::CapsuleSpaceSystem` @ `0x1000b4f0`). It is a real mini-world
  the ship is moved into for the duration of the jump. Its entire scene
  graph is one `icCapsuleSpaceAvatar` plus the cockpit node
  (`Render` @ `0x100481e0` adds the avatar, an optional non-player world,
  and `DAT_101682b8` — created at the "Loading cockpit" boot stage,
  `0x100bbe80` ctor). No sky, no starfield, no sun. `Render` also forces
  near/far planes 0.1 / 100000 (`0x3dcccccd` / `0x47c35000`) and pins the
  avatar's position to the **camera** every frame, orientation identity.

- **icCapsuleSpaceAvatar** (registered `0x100c0560`, factory `0x100c05a0`
  allocates **0xdfa8** bytes, ctor `0x100c1be0`) is the tunnel itself
  (section 3).

So: yes, a separate mini-space the ship genuinely flies through.

## 2. Choreography — the sJump state machine

`PerformJumps` @ `0x10040cc0`, states in `sJump+0x08`:

| state | what happens | exit condition |
|---|---|---|
| 0 | `MakeEffect` @ `0x10042f80`. Player: state:=1, countdown:=**2.0 s** (`0x40000000`), yoke zeroed, control lock `icPlayerPilot+0x31c`++, Director cue 0xf. NPC: distance test vs 100 km (`_DAT_10119d18`) picks Full/Entering/Leaving/NoEffect. | immediate |
| 1 | queue delay | countdown < 0 → `FullEffect` @ `0x10042ea0`: `AttachEffect`, state:=4 |
| 2 | `LeavingSystemEffect` @ `0x10042de0` path (NPC leaving player's view): hold velocity, run entry flash | flash done → `DoCapsuleJump` + `DetachEffect`, done |
| 3 | `EnteringSystemEffect` @ `0x10042e10` path (NPC arriving): teleport first, then flash-in | flash done → done |
| 4 | entry blank flash runs (section 4); velocity pinned to `sJump+0x20` | flash done → state:=5, blank avatar SetState(2) (tunnel loop sound), **player: ship attached to the capsule system + `SendShipDownTunnel` @ `0x10043740`**, countdown := rand[**8.0, 12.0**] s (`_DAT_10117b28` / `_DAT_10119ec4`) if player and not scripted, else 0 |
| 5 | in capsule space. Director cue 0x10 every frame; during the final 1.0 s cue 0x11 | countdown ≤ 0 → attach to dest world, **`DoCapsuleJump` @ `0x10042730` (the teleport)**, `OnEffectExit`, state:=6, blank avatar SetState(1) (exit flash + sound + force feedback) |
| 6 | exit flash decays | flash done → `DetachEffect`, countdown:=0, state:=7 |
| 7 | one frame | player: `icDirector::ChangeMode(0)` (camera restored), control lock `+0x31c`--; jump record removed |

**Duration: random 8–12 s. NOT distance-based.** `icCapsuleSpace::Skip` @
`0x10043330` just zeroes the state-5 countdown (used by the skip key).

`SendShipDownTunnel` @ `0x10043740`: inside the capsule system the ship
gets velocity **(0, 0, 500)** (`0x43fa0000`), zero angular velocity, and
the **identity orientation** (so the tunnel's world +Z is the ship's
forward), children likewise.

`DoCapsuleJump` @ `0x10042730` (the actual jump):
- position := dest L-point position + exit offset (`sJump+0x14` rotated
  into the dest frame) − exit-velocity-direction × ship radius
- orientation := **the dest L-point's own quaternion**
  (`FiSim::SetOrientation(dest+0x60)`)
- velocity := dest forward (+Z) × exit speed, where exit speed (when
  `sJump+0x10` is 0) = `sqrt(2 · accel · 3000)` (`_DAT_10119ec8` = 2.0,
  3000.0 literal), the **player's accel scaled by 0.8² = 0.64**
  (`_DAT_1011959c`), floored at 10, and if `radius / v ≥ 2.5` then
  `v := radius / 2.5`; finally clamped to
  `[min_exit_speed, max_exit_speed]` = **[500, 2000]** (flux.ini
  `[icCapsuleSpace]`). For the tug (accel 150): `sqrt(2·96·3000)` ≈
  **759 m/s**.

Entry gate (recap; details in docs/geography.md):
`icLagrangePointWaypoint::TryToJump` @ `0x1006ad40` requires local z < 0,
per-axis range ≤ `m_max_jump_range`, angle vs the jump axis, and axis
speed within `[m_min_jump_speed, m_max_jump_speed]` = **[100, 2500]**
(`0x1015d224` / `0x1015d228`; no flux override, compiled defaults) —
then calls `RegisterJump(player, destLP, 0, 0, 0, false)`. The AI
autopilot that flies you there (`icAITarget::GetNewCapsuleJumpStage` @
`0x1005c5af`) approaches at radius 10000, queues
(`icLagrangePointWaypoint::AddJumper`), waits for the icCapsuleDrive
charge, then runs in at `AverageJumpSpeed()` @ `0x1000b000` =
`(100 + 2500) / 2` = **1300 m/s**. Group/staggered jumps scatter the exit
offset by up to **375 m** (`DAT_1011dc80`, `RegisterJump` @ `0x100401e0`).

## 3. The tunnel — icCapsuleSpaceAvatar

Structure (ctor `0x100c1be0` + `FUN_100c1170` @ `0x100c1170`): a ring
buffer of **99 segments**, 0x240 bytes each; segment = 33 ring points
(x, y, z, u — 16 bytes each), centre (+0x21c/0x220/0x224), texture phase
(+0x228), inner/outer flag (+0x22c), beam offsets jx/jy (+0x230/0x234,
rand ±50 / ±10, `_DAT_1011a1c0`/`_DAT_101190c0`), beam half-width
(+0x23c, rand [**180**, **460**], `_DAT_10119920`/`_DAT_1011cd70`).

Ring construction (`FUN_100c0700` @ `0x100c0700`):
- rings alternate bands (spawn flag `2-(i&1)`; respawn passes the
  previous ring's flag + 1): **outer radius walks in [960, 1000]**
  (`DAT_1011cd58` = 1000, band `_DAT_1011849c` = 40), **inner in
  [600, 640]** (`DAT_1011cd54` = 600)
- 32 points per ring; the radius random-walks point to point (step up to
  half the band, reflected at the band edge)
- centre chains from the previous spawned ring (walk ±10,
  `_DAT_101190c0`), scatter scale 600 × 0.2 = **±120**
  (`_DAT_101188e8` = 0.2)
- texture V phase: outer rand[0.5, 0.8] (`_DAT_10117738`/`_DAT_1011959c`),
  inner rand[0, 0.3] (`_DAT_1011c034`)
- point U = a shared wobble envelope built once (`FUN_100c2040`): keys
  every **1/27** (`_DAT_1011cdd8` = 0.037037) alternating rand[0.5, 1] /
  rand[0, 0.5], zero ends, sampled at `i · 0.030303` (`_DAT_1011cd74`)

Motion (`FUN_100c11e0` @ `0x100c11e0`, `FUN_100c0d80` @ `0x100c0d80`,
called from Prepare @ `0x100c1d30` with the game dt):
- spacing **1000 m** (`_DAT_1011945c`), initial span z = −49500 … +48500
  (99 km, `_DAT_1011cd68`)
- every ring streams past at **7000 m/s** (`_DAT_1011cd7c`), per-frame
  step clamped to 1000 m (`_DAT_1011cd78`)
- centres jitter **±15 m per frame** (`_DAT_101183ec`)
- a ring **36000 m behind** (`_DAT_1011cd80`) respawns 1000 m ahead of
  the front; draw culls pairs beyond −66000 (`_DAT_1011cd84`)
- texture scroll += dt × **0.001** (`_DAT_1011803c`)

Draw (@ `0x100c1dd0`, vtable `0x1011cd88` slot 16; disassembled — Ghidra
dropped it), three passes over the 98 consecutive ring pairs as triangle
strips (`FUN_100c1300`) plus ribbons (`FUN_100c1460`/`FUN_100c1570`):

| pass | texture (table @ `0x101619e4`) | colour | notes |
|---|---|---|---|
| walls 1 | `texture:/images/sfx/capsule_tunnel` | (1.0, 0.52, 0.01) `0x3f051eb8`/`0x3c23d70a` | radial ×1.0, V −scroll |
| walls 2 | `texture:/images/sfx/capsule_tunnel2` | (0.83, 0.10, 0.01) `0x3f547ae1`/`0x3dcccccd` | radial ×**1.07** (`0x3f88f5c3`), V +scroll |
| beams ×2 | `texture:/images/sfx/capsule_beam` | white and (1.0, 1.0, 0.5) | 3 ribbons down the centres, extents ±w along (1,0,0)/(1,1,0)/(−1,1,0), U toggles 0/1 per ring |

Vertex alpha is `engine[0x1790] × 0.5` (`FUN_100c0ec0`); the master value
is not recovered — we bake 0.5 and draw the beam pass once (doubling it
white-outs the frame under Godot's glow).

Dressing (`FUN_100c2040` @ `0x100c2040`):
- two end flares at z = ±**90000** (`_DAT_1011cd5c`), size **10000**
  (`0x461c4000`), colour (1.0, 0.47, 0.03) (`0x3ef0a3d7`/`0x3cf5c28f`),
  brightness 0.2
- 99 per-ring flares, brightness 0.05, same colour
- one directional light (0.9, 0.43, 0.0) (`DAT_101715e8/ec/f0`) whose
  orientation is re-randomised **every frame** (Prepare @ `0x100c1d30`
  calls `FnRandom::Orientation`) — the flickering orange wash

## 4. The blank — icCapsuleEntryBlankAvatar / icCapsuleEffectNode

`AttachEffect` @ `0x10043390` re-parents the jumping ship's avatar under
an **icCapsuleEffectNode** (0xc4, factory `0x100bfc40`) built by
`FUN_100bef90` @ `0x100bef90`: effect node → `FcClipPlaneNode` → the
original ship avatar, plus an **icCapsuleEntryBlankAvatar** (0x108,
factory `0x100be0c0`, ctor `0x100be480`; the per-ship variant
`FUN_100be550` adds a white `FcLensFlareNode`, flicker envelope keys every
0.1 s in [0.8, 1.2] for 1 s). Child sims get their own clip-planed copies
(`FUN_100bf3f0`). The clip plane is what lets the ship "slide through the
membrane".

Properties (map @ `0x101714a0`, flux.ini `[icCapsuleEntryBlankAvatar]`):
`sound_url = ini:/audio/sfx/capsule_entry` (an `FcSoundNode` playing
`capsule_jump.wav`), `sound_tunnel_url = ini:/audio/sfx/capsule_tunnel`
(an `FcLoopSoundNode` looping `inside_capsule_space.wav`),
`feedback_url = ini:/forcefeedback/capsule_entry` (`capsuleentry.ffe`),
`flash_time = 0.5` (default `DAT_10161920` = 0.5).

State changes (`FUN_100c0170` @ `0x100c0170`): state 1 = play entry sound
+ force feedback + spawn the L-point flash (`FUN_100c02d0`: an
`icTimedWaypoint` living `flash_time` s carrying a (0.65, 0.75, 1.0)
lens flare sized by the ship); state 2 = start the tunnel loop. The
blank's own progress (`FUN_100bf870` @ `0x100bf870`) is proximity-based:
`FUN_100beea0` places the white flare at `z = (0.5 − d²/R²)·R` from the
LATCHED anchor position (cached doubles at `+0xc8..0xdc`, re-latched when
the anchor's system id `+0x12c` changes), with **R = 2 × ship radius**
floored by the INI value (`FUN_100be550`, `puVar6[0x84]`); the blank
stays ACTIVE while `d² < R²` (the predicate at `0x100bf9xx`), and for the
**player it additionally holds at least 1.5 s** (`_DAT_1011a268`). The effect node's
brightness channel envelope (`FUN_100bef90`) has keys every 0.1 from 0.2
to 0.9 (`_DAT_101184b0`, `_DAT_1011951c`) with values rand[**0.7**, 1.0]
(`_DAT_101191e8`), zero at the ends — the flicker we drive `jump_fade`
with.

## 5. Camera

`PerformJumps` case 5 cues `icDirector` event **0x10** every frame
(`FUN_100426f0` @ `0x100426f0`), and event **0x11** through the final
second. The response table @ `0x1011d498` (24-byte records: three camera
ids, priority, duration, flags):

| event | cameras | priority | duration |
|---|---|---|---|
| 0x0d NPC leaves | (4, 11, 11) chase/drop | 6 | 4 |
| 0x0e NPC enters | (11, 11, 11) drop | 6 | 4 |
| 0x0f jump queued | (25, 25, 25) | 7 | −2 |
| 0x10 in capsule space | (**24**, 24, 24) | 8 | −1e−05 (re-cuttable) |
| 0x11 exit imminent | (**3**, 3, 3) | 9 | 1 |

Camera name table @ `0x101621e0`: 3 = `cam_internal_no_hud`; 24 and 25
are unnamed dedicated cameras. Camera 24 (ctor `FUN_100dc080` @
`0x100dc080`, Update @ `0x100dc160`, both disassembled): FOV from
half-angle **0.35 rad** (`_DAT_1011d378`, ≈ 40.1°); each cut picks a
random direction in the SHIP's frame with components ([0.8, 1.0],
[−1, 1], [−1, 1]) normalized — biased to the ship's +X — and sits at
**4 × the focus radius** (`0x101190b4`), building its basis to face the
ship. Cuts are throttled by flux.ini `[icDirector] min_cut_time = 1`.
So: external shots cutting around your ship about once a second, then
the last second snaps inside the cockpit (no HUD) for the exit flash.

## 6. Audio

- `data/ini/audio/sfx/capsule_entry.ini` → `capsule_jump.wav` (entry AND
  exit flash, min_range 3000)
- `data/ini/audio/sfx/capsule_tunnel.ini` → loop
  `inside_capsule_space.wav` (min_range 5000)
- `data/ini/audio/sfx/capsule_space.ini` is an `FcThreePartSoundNode`
  (attack `capsule_jump`, sustain `inside_capsule_space`, decay
  `capsule_jump`, channel "jumping") — not referenced by flux.ini's
  blank-avatar keys; it is the same two WAVs either way.

## 7. What was implemented

`game/scripts/capsule_fx.gd` — `CapsuleFx`, the tunnel
(`@element icCapsuleSpaceAvatar`, `@element icCapsuleSpaceSystem`):
99-ring ring-buffer with the exact bands/spacing/speeds/jitter above,
camera-anchored with the basis frozen to the ship's frame at entry, two
wall passes + three beam ribbons with the extracted colours and the real
`capsule_tunnel`/`capsule_tunnel2`/`capsule_beam` textures, end/ring
flares, and the per-frame random orange directional light.

`game/scripts/main.gd` — `jump_state` extended to
`0 idle, 1 spool, 2 accel run, 3 entry flash, 4 capsule space,
5 exit flash`:
- state 3: 1.5 s flickering white-out (`_flash_roll`/`_flash_flicker` =
  the effect-node envelope), entry sound, HUD off, controls locked
- `_capsule_enter`: world swap (objects/sky/sun hidden, black
  background), ship at 500 m/s, tunnel on, loop sound, duration
  rand[8, 12] s
- `_capsule_camera`: camera 24 (random +X-biased viewpoint at 4 radii,
  FOV 40.1°, ≥1 s between cuts), final second `cam_internal_no_hud`
- `_capsule_exit`: teleport via `_load_system(dest, "", from)`, ship
  takes the arrival L-point's basis (`_record_basis(last_entry)` — the
  same quaternion `DoCapsuleJump` applies), exit speed
  `clamp(sqrt(2·150·0.64·3000), 500, 2000)` ≈ 759 m/s, exit flash + exit
  sound
- `_jump_abort` keeps scripted `start_in_system` calls safe mid-jump.

Kept from before (gameplay contract): 3 s spool + 3 s acceleration run,
J/K at L-points, `JUMP_RANGE`, and the arrival offset (+2500, +300,
+3000) from the entry L-point.

## 8. UNKNOWN / PLACEHOLDER

- **FcLensFlareNode internals**: the flare sprite atlas (type ids 1, 9,
  0x2b) and world sizing are not recovered; CapsuleFx uses additive
  billboard quads with a procedural radial texture, ring-flare size 150 m
  (placeholder), end flares at the recovered 10 km.
- **engine[0x1790]** (the master vertex alpha halved into every tunnel
  vertex): not recovered; 0.5 baked, beam pass drawn once instead of the
  literal twice.
- ~~The blank avatar's true white-out is proximity-driven~~ RECOVERED and
  wired: the exit blank ends when the ship has flown `R = 2 × radius`
  from the latched arrival point AND the 1.5 s player hold has passed
  (`FUN_100beea0` placement `(0.5 − d²/R²)·R`, active while `d² < R²`).
- ~~Original queue delay is 2.0 s~~ WIRED (state 1 holds exactly 2.0 s,
  `MakeEffect`'s countdown). `recharge_time` resolved: no shipped capsule
  drive INI authors the key — only the LDAs carry it.
- ~~`DoCapsuleJump` pulls the arrival position back by ship radius~~
  WIRED (the arrival subtracts `exit_dir × radius`).
- Camera 24's distance term uses the focus record's `+0x10` radius; we
  use the ship model bounds radius.
- ~~Camera 25 not implemented~~ RECOVERED and wired: the jump-queue drop
  camera (instance at `icDirector+0x244`, `+0xa8 = 8.0`; cut placement
  `FUN_100d9710`) parks ahead of the flight path by rand[**1.5, 2.0**] s
  of travel (`0x101626c4/c8`) along the velocity direction (focus +Z at
  rest), displaced by a random unit vector at
  `max(radius / tan(0.5), radius × 1.5) × 8.0`, and holds FIXED through
  the queue and entry flash (event 0xf duration −2), tracking the ship.
