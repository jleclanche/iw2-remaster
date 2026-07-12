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
  destination lists; validated across all 16 systems) — `data/json/systems/`
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
