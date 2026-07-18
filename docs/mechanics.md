# IW2 game mechanics — reimplementation notes

Sources: extracted INI data (`data/json/`), the POG Scripting SDK 0.91
(`C:\Users\jerom\Projects\pog-scripting-sdk`, 153 API headers + CHM manual),
and observed game behavior. Header references are to `include/*.h`.

## Flight model (implemented in `game/scripts/ship_flight.gd`)

Assisted-Newtonian: throttle sets a target velocity along the nose; the
flight computer accelerates toward the target vector with **per-axis**
limits from the ship INI (`speed=(x,y,z)`, `acceleration=(x,y,z)` m/s,
m/s²; z = fore/aft is always the big axis). Rotation: `pitch/yaw/roll_rate`
(deg/s) with `*_accel` limits. "Free flight" (assist off) integrates thrust
directly — velocity drifts, rotation gets `angular_speed_boost`.
Validated: tug reaches its 850 m/s in 850/150 s exactly.

## LDS — Linear Displacement System (in-system FTL-lite)

- Engaged like a drive mode; ship covers interplanetary distances.
- **LDSI**: inhibitor regions around masses/stations block LDS
  (`iRegion.CreateLDSI(centre, radius)`), forcing normal-space approach.
- Can be temporarily **disrupted** by weapons
  (`iShip.DisruptLDSDrive(ship, seconds)`) — the piracy interdiction
  mechanic — and **scrambled** (`IsLDSScrambled`).
- State queries: `iShip.IsInLDS`, `IsLDSInhibited` (iShip.h:175-218).
- Drive performance comes from the mounted LDS subsim
  (`subsims/systems/*lds*`).

## Capsule drive (inter-system jump)

- Jumps happen between **Lagrange points** (iLagrangePoint.h); the map
  `.map` link table wires L-point records to destination systems.
- Sequence: acceleration run (`iAI.IsCapsuleJumpAccelerating`), tunnel,
  exit with custom offset/speed (`iSim.CapsuleJumpCustom(sim, dest,
  exit_x, exit_y, exit_speed)`, iSim.h:372-390).

## Docking

- Ships/stations expose typed **dockports** (subsim templates
  `subsims/dockports/*`); `eDockportType`/`eDockportStatus`, compatibility
  sets (`iDockport.DockportsCompatibleWith`), enable/disable, and
  `iDockport.Dock(us, them)` (iDockport.h). Ship INIs carry
  `docking_priority`. High-level: `iShip.Dock`, `iSim.IsDockedTo`,
  `iSim.SetDockingLock`.

## Component (subsim) model

Every ship is a hull + tree of subsims on typed mountpoints (weapon mounts,
LDA shields, drive, LDS, capsule drive, CPU, EPS, sensors...). Systems have
`hit_points`, `minimum_efficiency` (performance floor when damaged),
`repair_rate`, `power`, `heat_rate` — damage degrades capability
per-component rather than a single HP pool. Weapons: `projectile_template`,
`refire_delay`, fire arcs, ammo. All extracted in `data/json/subsims.json`.

## AI & orders

`iAI.h`: order-based pilots — `GiveDockOrder`, formation/escort/fight/flee
packages (`iFormation.h`, `iEscort.h`, `iFight.h`, `iFlee.h`),
`iScriptedOrders.h`. Wingman command set in `iWingmen.h`.

## World simulation

- Factions & reputation: `iFaction.h`, `iFactionScript.h`.
- Ambient traffic: `iTrafficCreation.h`, `iTrafficScenario.h`,
  `iExodusTraffic.h`.
- Dynamic incidents/missions: `iGangsterIncidentGen.h`,
  `iMissionGenerator.h` + `iGMTemplates.h` (the freeform game's content
  engine — key for the EVE-like ambition).
- Trading/cargo: `iTrade.h`, `iCargo.h`, `CargoTypes.h`; stations are
  `iStation.h` + `iHabitat.h`.

## Extraction status: complete

Every game data format is now decoded and extracted:

- INI sims/subsims/weapons; localized strings — `data/json/`
- `.map` systems **including the capsule-jump table** (per-L-point
  destination lists; validated across all 16 systems) — `data/json/systems/`.
  The u32 at record offset +311 (previously logged as a "type hash") is a
  float32: the body radius in meters. Records carry no model reference —
  the original spawns station sims from POG scripts — so
  `tools/iw2/classify_map.py` classifies records (star/body/lpoint/station)
  by name keywords + hierarchy and assigns modular-station avatars.
- FTC/FTU textures — `data/textures/`
- PSO/PSO2 meshes incl. `DELT` morph deltas (character facial animation,
  paired with the text `MORPHGIZMO` `.giz` weight tracks); `FRAM` weight
  tracks preserved raw — `data/gltf/`, `data/avatars/`
- LWS scenes incl. full keyframe animation — `data/json/scenes/`
- LWOB collision hulls (149) — `data/json/collisionhulls/`
- Audio WAVs — `data/audio/`; music/ambience MP3s play directly from
  `streams/audio/`
- HTML encyclopedia + `.avi` movies are already standard formats in place
- `.ffe`/`.frf` force-feedback effect files: joystick hardware effects,
  intentionally not converted (no gameplay content)

## Still to reimplement (engine side)

- FRAM weight-track playback for character morphs (base interiors)
- Original mission `.pkg` logic via ZeroPipeline's disassembly (story
  campaign — deprioritized per project goals)

## Docking, towing and mass (extracted)

The join: icDockPort::OnDock (0x1002e540) calls FiSim::AttachChild on the two
port OWNERS -- a rigid parent/child attachment, not a merged body. Which one
is the parent is docking_priority (iiSim +0x1c0, ini `docking_priority`):
the HIGHER priority sim is the parent (station 200-1000 > tug 85 > pod 11).
FiSim::OnAttachChild then does the physics: AddMass(child mass @ +0x18) and
AddMomentOfInertia(child inertia at its attach offset), recursing up the
parent chain; FiSim::SetMass stores 1/mass at +0xa0 and FiSim::Integrate
(0x100bfc20) multiplies accumulated force by it -- accel = force / total
mass. FiSim::UpdateChild rewrites every child's transform from the parent
each tick (the rigid ride).

Mass is NOT authored for ships: iiThrusterSim::Load (0x1007ddf0) computes
  mass = width * height * length * m_density      (m_density = 0.001 @ 0x1011c168)
and thrust FORCE = mass * the ini acceleration vector (+0x224/228/22c), so
the ini `acceleration` is exactly the undocked acceleration and a docked
pair accelerates at accel * m_own / (m_own + m_partner). icInertSim::Load
does the same, except ini `immobile=1` forces SetMass(0) = INFINITE mass
(inverse 0): you can dock to it but never move it. Any ini `mass=` on these
classes is overwritten by Load (why the stock ships never author one).
Numbers: tug 80x70x120 -> 672, cargo pod 50^3 -> 125 (tow at 84% thrust),
command section 20x7x30 -> 4.2 (tow at 3% -- barely moves a pod).
Box inertia uses 1/12 (0x1011ae44) and deg->rad 0.0174533 (0x10119930).

Port: ship_flight.gd mass/tow_mass/mass_scale() and tow_torque_scale;
main.gd _try_tow_dock/_update_tow/_release_tow (the DOCK autopilot on a
targeted lower-priority sim tows it; U releases). Approximations, marked in
code: port-null mating is not modelled (the partner keeps its capture-moment
offset), the inertia sum is a scalar box+parallel-axis stand-in for the
tensor, and TryToDock's capture kinematics constants were not resolved (a
20 m/s relative-velocity gate is eyeballed). mechcheck: tow-dock, tow-ride,
tow-release.

## The heat "sanctuary" at Lucrecia's Base (verified, not a bug)

The map gives Hoffer's Wake Alpha -- the red giant -- radius 1.7508e11 m, and
ParseSunInfo (0x1004e5a0) hands that straight to FiSim::SetRadius.
icSun::Think (0x1006ab90) heats the player at t^2 * m_heat_multiplier
(10000 @ 0x1011af54) * 10 (0x101190c0) inside radius * 0.5 (0x1011af58) of
the surface -- which covers the entire inner nebula including Lucrecia's
Base. External heat pegs at heat_damage_threshold (500) there, the HUD gauge
(scale 0.8 @ 0x10163efc) reads past full, and iiWeapon's heat gate
(0x1003cc00) refuses to fire: nothing can shoot near the base. Idle internal
heat elsewhere is the authored source/heatsink equilibrium (tug 128,
comsec 96, storm petrel 133, turret fighter 0 -- all of 500) and every hull
fires normally at Alexander L-Point. weapons.gd now prints WEAPONS
HEAT-LOCKED (our line, not the original's) when the gate refuses.

## Saving and reloading

igame.SaveGame/LoadGame (natives/gameapi.gd, user://save_N.json, 8 slots)
now snapshot the WORLD as well as the story. Persisted: POG globals +
states + mission objectives (the campaign's whole script memory -- the
reactive layers re-arm from these), system + player position, the fitted
hull (ship_ini; load refits via _fit_player), hull and per-subsim hp,
velocity/set-speed/docked-at, magazines, the player inventory, kill count,
aim assist, and a snapshot of every live AI ship (ini, position, velocity,
behavior, hull, hostility, racked pods, pod cargo). NOT persisted, by
design: live POG task continuations (a bytecode coroutine parked
mid-mission cannot be serialised), in-flight ordnance and effects, field
rocks (procedural), escort links, and a mid-death dramatic sequence
(a dying ship saves as already gone). The pause menu's SAVE GAME writes
the next free slot; LOAD GAME (both menus) lists occupied slots.
mechcheck: save-reload.
