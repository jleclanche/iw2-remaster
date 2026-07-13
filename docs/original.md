# What the original game actually does

An evidence log. Every claim here is something we *confirmed* from the shipped
game -- the decompiled engine, the INI tree, the mission bytecode, or the
assets -- and every claim carries its source so it can be re-checked.

This file exists because the code will be rewritten several times before this
remaster is done, and the facts are the expensive part. Losing them means
re-deriving them.

**Rules for this document.**

- Nothing goes in without a source. `iwar2.dll @ 0x1003b190`, `flux.ini
  [icHUD]`, `data/pogsrc/istartsystem.pog:766`, `images/planets/sun_halo.ftc`.
- If we do not know something, it goes in **Open questions** and stays there
  until we do. A plausible guess recorded as fact is worse than a known gap:
  it gets built on.
- Where our implementation deliberately differs, say so in **Deliberate
  divergences**, with the reason.

Companion docs: `pog.md` (how we run/port the scripts), `decompile.md` (how to
get at the binaries), `formats.md` (the file formats), `geography.md` (the solar
systems: bodies, stars, stations, L-points).

---

## 1. Architecture

**The game's content is not in the engine.** Missions, conversations, AI orders,
trading, the mission generator and the base screens are POG script, compiled to
a stack-machine bytecode and shipped in `resource.zip` as 114 packages. The
engine binaries provide ~42 *native* packages the scripts call into.

| binary | what is in it |
|---|---|
| `EdgeOfChaos.exe` | a thin launcher |
| `iwar2.dll` | the game: `icShip`, `icHUD*`, `icCannon`, the subsims |
| `flux.dll` | the Flux engine: sim/avatar/resource layer, and the POG VM |
| `gui.dll` | window/control widgets |
| `ihud.dll` | the POG->HUD *bindings* only, not the implementation |

**The binaries kept their C++ symbols** -- mangled names like
`?BreakShipOutOfLDS@icLDSDrive@@AAEXXZ` -- so most classes named in `flux.ini`
map straight to code.

**Except the HUD elements.** `icHUD*` classes have *no* exported symbols. Reach
them through the class registry instead (`iwar2.dll.c` ~line 183250):

```c
FcRegistry::RegisterClass(inst,
    "icHUDLagrangeIcon",        // class name
    "iiHUDUnderlayElement",     // base class
    FUN_100ee820,               // factory
    m_property_map_exref);
FcObject *FUN_100ee820(void) { p = operator_new(0x620); return FUN_100ee8b0(p); }
                                                        //  ^ ctor, sets the vtable
```
Grep the class-name string -> its `RegisterClass` -> factory -> constructor ->
vtable -> the virtual `Draw`. `iiHUDUnderlayElement` means *drawn under the HUD,
in world space* (3D); there is a matching overlay base for 2D elements.

---

## 2. The POG virtual machine

Source: `FcScriptTask::Execute`, `flux.dll @ 0x1003b190` (4,505 bytes). This is
the single most valuable function in either binary.

Opcode table is fully recovered; every byte in all 114 shipped packages decodes
(`tools/iw2/pogdis.py --selftest` round-trips 16k instructions exactly against
the SDK compiler's own listings).

Four semantics that guessing had wrong:

- **`0x16`/`0x19` are `CallNative`/`StartNative`.** The compiler emits `Call`
  (0x15) for *every* import with operands `0 0 argc`; the **loader** patches the
  operands from the FIMP call-site tables and rewrites the opcode when the
  import resolves to a DLL package. Shipped bytecode therefore only ever
  contains 0x15/0x18.
- **`TimedJump` is a rate limiter, not a sleep.** `if now - local[slot] <=
  interval: goto target; else: local[slot] = now`. So `EndTimeslice; TimedJump
  L,slot,1.0` is POG's *"poll this every second while yielding every frame"*.
- **A suspended task stops at the next *instruction*, not the next yield.** The
  interpreter re-tests runnability after every opcode. Without this,
  `iconversation`'s `while (!done) task.Sleep(Current(), 0.5)` -- which never
  yields explicitly -- spins forever.
- **`0x45` `DebugSkip` is `FcDeveloperMode`.** It is how `debug { }` blocks cost
  nothing in release: the engine takes the jump unless developer mode is on.
  Turn it on and the original developers' narration comes out, *including their
  own error handlers*. It is the best diagnostic in the project.

`0x33`-`0x36` are the bitwise ops. `0x43`/`0x44` are atomic-region begin/end
(they suspend the 64-instruction preemption check), not debug markers.

**Task frames** (`this+0x48`, 28 bytes each): return PC, saved stack base, saved
locals base, saved package pointer. Registers: `+0x24` package, `+0x28` code
base, `+0x2c` PC, `+0x30` stack base, `+0x38` SP, `+0x3c` locals base.
`Store` does **not** pop -- assignment is an expression, so the compiler emits a
trailing `Pop` when it was a statement.

---

## 3. Game startup

Source: `data/pogsrc/istartsystem.pog`, `data/pogsrc/iprelude.pog` (decompiled
from the shipped bytecode by `tools/iw2/pogdec.py`).

The engine drove this from C++; we drive it from `main._port_boot()`.

```
istartsystem.StartupNewGame     singleplayer setup; starts the mission generator
istartsystem.StartupSession
istartsystem.StartupSpace       <-- calls igame.EnableBlackout(1)
istartsystem.StartupSystem      preloads sims, loads the localised CSV text,
                                binds script keys, creates the traffic-control
                                and LDSI regions, starts the range/traffic
                                /station monitors
iprelude.Main                   creates the player ship, starts MasterScript
istartsystem.FinalSetup         <-- lifts the blackout, or runs the launch cutscene
```

**`iprelude.Main` must run BEFORE `FinalSetup`.** It is what creates the player's
ship (`iutilities.CreatePlayer`), and `FinalSetup` immediately reaches for it
(`iship.FindPlayerShip`, sets its death script, checks its hull type). Missions
assume the whole bootstrap has run; never call one directly.

### `igame.GameType()` -- 0 IS the single-player campaign

`istartsystem.pog:775`: `if (0 == igame.GameType()) { ...single player... }`
and `StartupSpace` blacks the screen out for anything that is *not* 2 or 3.
The scripts set 0, 1 and 2 via `SetGameType`. Getting this wrong skips the code
that lifts the blackout and the player stares at a black screen with a perfectly
healthy game running behind it.

### The screen blackout

`StartupSpace` calls `igame.EnableBlackout(1)`. It is lifted in `FinalSetup`,
either directly (`EnableBlackout(0)`) or -- on a new game -- at the end of the
launch cutscene. If nothing lifts it, the game is invisible. Worth tracing.

### The launch cutscene (`istartsystem` local_486 / local_1487)

```
FinalSetup:  task.SuspendAll(); task.Detach(start local_486());
local_486:   sleep 1; PlayMovie(YoungCalStartup or OldCalStartup);
             icutsceneutilities.HandleAbort(start local_1487(player, base));
             ... sim.PlaceRelativeTo(player, base, 12000, 0, -1000);
                 sim.PointAway(player, base);
                 sim.SetVelocityLocalToSim(player, 0, 0, 500);
             task.ResumeAll(); igame.EnableBlackout(0);
local_1487:  idirector.Begin(); creates a "launchtube" sim; puts the player
             inside it; dolly camera; waits until the player is within 2300 m
             of the tube; idirector.End();
```

So **the "teleport" at the end of the launch is correct**: the sequence leaves
you 12 km off Lucrecia's Base doing 500 m/s.

`task.SuspendAll()` freezes every task that *already exists*; the caller keeps
running (it is about to spawn the cutscene) and so does anything spawned after.
That is what stops the mission's opening movie from racing the cutscene.

**Cutscenes are skippable, and the scripts own the mechanism.**
`icutsceneutilities.HandleAbort` polls the global `g_cutscene_skip`; setting it
to 1 halts the cutscene task and calls `idirector.End()`. Escape should set that
flag, not tear the scene down behind the scripts' back.

---

## 4. Flight, LDS, and regions

### LDS dropout
`icLDSDrive::BreakShipOutOfLDS` (`iwar2.dll`): zeroes **angular** velocity and
sets linear velocity to **facing x 1000 m/s flat** -- *not* the drive's max
speed. Then cues the director (event 0xe).

### LDS inhibition is REGION-based, not radius-derived
`iiThrusterSim` holds an inhibition **counter** at `+0x251`
(`EnterLDSInhibitRegion` increments, `Leave` decrements; `IsLDSInhibited` is
just `counter != 0`). Regions are explicit `icLDSIRegion` objects with an
authored **centre (double vector) + radius (float)**.

They are *authored*, not computed: `istartsystem.create_station_regions` builds
them at system startup via `iRegion.CreateLDSI(sim, radius)` and
`iRegion.CreateTrafficControl(sim, radius, speed_limit)`. Observed call shapes:
`CreateLDSI(sim, 250000.0)`, `CreateTrafficControl(sim, 30000.0, 500.0)`.

`icPlayerPilot` caches the region the player is inside at `+0xb8` -- that is what
feeds the HUD roundel.

Any model that derives an inhibition radius from a body's size is wrong in kind.

### LDS obstacle avoidance
`icAITarget::CheckLDSAvoidance`: avoidance radius =
`(icPlanet::HeatDistanceAsRadiusMultiplier() + 1.1) x FiSim::Radius()`.

---

## 5. Ships and sims

**Ships are spawned by INI path**, not by a model name:
`sim.Create("ini:/sims/ships/utility/flitter", name)`. The INI carries the
model, mass, hit points, handling. All 148 are extracted to
`data/json/ships.json`; a script-spawned ship should get its *authored* stats.

**`isim.Type` returns the engine's `IeSimType` bit flag**, not a class name. The
scripts compare against the raw number:

| flag | meaning | how we know |
|---|---|---|
| `131072` (1<<17) | `T_CommandSection` | `istartsystem.pog:817` checks it to name the player's starting hull |

The rest of the enum is **not yet recovered** -- see Open questions.

**Ship names** come from `ship_names.ini`: per category, a `NumberOfEntries` and
a `Prefix` (e.g. `[General] NumberOfEntries = 343, Prefix = "sn_general_"`).
`iShipCreation.ShipName` picks a random index and looks `sn_general_<n>` up in
the localised CSV tables.

### Subsims are mounted at named model nulls, and a `mountpoint` is an empty socket

A ship INI's `[Subsims]` names a template and (optionally) a null:
`template[14]=ini:/subsims/mountpoints/lda`, `null[14]=shield_upper`. The
`mountpoints/*.ini` are **sockets**, not devices -- all they carry is a `name`
and a `type` bit flag, no `hit_points`, and `iiShipSystem::InflictDamage`
(`0x1003bed0`) refuses to damage anything whose max hit points are 0. The
fitting screen fills them from the player's inventory. `tug_prefitted.ini` is the
game's own already-fitted tug, and is the record to fit from when the fitting
screen is not in play.

The `type` flags are the HUD's `DRV THR LDS CAP WEP SEN EPS CPU` strip:
`1` heatsink, `2` reactor, `4` eps, `8` thrusters, `16`/`32` active/passive
sensors, `64` lds, `128` lda, `256` drive, `512` capsule drive, `1024`
auto-repair, `2048` aggressor shield, `4096` every weapon mount, `16384` sensor
disruptor, `32768` cpu, `65536` point-defence turret, `131072` dock-on turret.

---

## 5a. Combat and damage

Full write-up with the disassembly in **`combat.md`**. The short version:

**The damage formula.** `iiSim::ApplyWeaponDamage` (`iwar2.dll @ 0x100796a0`):

```
applied = damage,                                penetration >= armour
applied = damage / 2^(armour/penetration - 1),   penetration <  armour
```

Penetration at or above the armour rating does full damage; there is no bonus
for exceeding it. Below it the damage halves for every whole multiple of the
ratio. **Penetration, not hit points, is what makes capital ships immune to
light weapons**: a light PBC bolt (`light_pbc_bolt.ini`, damage 130,
penetration 35) does **0.32%** of a navy heavy cruiser (16500 hp, armour 80) per
hit, and 22% of a patcom (700 hp, armour 50).

**Bolts lose damage with flight time**, not distance -- the same curve, from the
same `2.0` constant at `0x1011a5e0`. `icBullet::OnCollision` (`0x100630c0`):
`damage / 2^(age/half_time - 1)` once `age > half_time`. A standard PBC bolt
(`half_time=0.35`) does 160 at 2.1 km, 80 at 4.2 km, 40 at 6.3 km.

**Subsim damage.** `icShip::ApplyWeaponDamage` (`0x10073cf0`) spalls
`N = max(2, int(subsim_count * 0.2))` criticals off every impact: the subsim
whose mount null is *nearest the impact point* takes `0.2 x` the hull damage
that got through, and `N-1` uniformly random subsims take `0.2 x 0.4 x` it.
(The `critical_chance_scale` RNG gate on the random ones is a **no-op**: a failed
roll does not consume a loop iteration, so it just re-rolls. Every impact lands
exactly N.)

**Damage degrades a subsim linearly**: `efficiency = (hp/max_hp) x power_ratio`
(`iiShipSystem::Simulate`, `0x1003bbd0`). There is no destruction threshold --
instead each device's INI declares a `minimum_efficiency` below which it snaps
to zero (`cpu2` 0.1, `light_pbc` 0.3, `nps_pbc` 0.5, `ships_drive` 0). Hit points
go *negative* (to `-max_hp`) and are still repairable.

**Auto-repair is a shared budget.** `icAutorepair`'s `autorepair_rate` fills a
ship-wide pool each frame; each damaged subsim draws its own `repair_rate` out of
it, first come first served. No autorepair fitted, nothing ever repairs.

**LDA (the shields) deflect the whole bolt or nothing.** `icShip::ApplyWeaponDamage`
walks the subsims for anything `IsKindOf(iiLDA)` and calls its virtual at slot
`+0x54` *before* any damage is computed; if it returns true the shot is gone.
There is no partial absorption and no shield hit-point pool. `icPlayerLDA`
(`0x100acda0`) pays `shield_energy_cost` out of an energy bank recharged at
`efficiency x power` per second, with `chance = reliability x efficiency`
(capped 0.98) and a hood-coverage arc test. `icAILDA` (`0x1002b940`) instead has
`defend_count` deflections regenerating over `recharge_time` --
`nps_lda.ini` is one deflection every 0.1 s at 50%, which is why NPC warships
feel spongy. A weapon INI's `bypass_shields` skips the whole loop (it is passed
as the `eDamageSource` argument).

**Death.** Hull to 0 -> `Kill()` -> `iiSim::OnKilled` (`0x10079b80`): score
credit, killed flag, **the ship's death script** (a POG task name at `+0x1c4`),
`Explode()`, director cue `0xc`, removed from its group.

`flux.ini [icShip]` carries the tuning: `critical_chance_scale=12`,
`critical_damage_scale=0.2`, `criticals_per_impact=0.2`, `heat_gain_factor=1`,
`heat_loss_factor=0.5`, `heat_damage_threshold=500`, `heat_damage_rate=0.08`.

---

## 6. Factions

Diplomacy is a **feelings matrix**: a float in `[-1, +1]`, negative hostile,
positive allied. `ifaction.SetFeeling(a, b, f)` is the hottest game-facing native
in the whole campaign at **5,529 call sites**. The literals the scripts actually
push are `0.0`, `+-0.3`, `+-0.4`, `+-0.5`, `+-1.0`.

Everything that decides "will this ship shoot at that one" reduces to a lookup in
that matrix. A `behaviour == "attack"` string is not a substitute.

---

## 7. Rendering

### The geography: every render property of a body is in its `.map` record

Full write-up, with the disassembly, in **`geography.md`**. The short version --
all of it out of `icSolarSystem::Load` (`iwar2.dll @ 0x1004bb60`), which reads
the file as `count * sizeof(sEntity)` with `sizeof(sEntity) == 0x168` (360) and
switches on each record's **first byte**:

**The header has no version byte.** The byte we were skipping at offset 4 is
record 0's `kind`, and it is 0 (the system centre is a body). Every field in our
old decoder was therefore **one byte off**, which is why the "kind" it read was
the *next* record's kind and why L-points appeared to have no orientation.

**The body radius is the f32 at `+0x138`** -- `FiSim::SetRadius(*(float *)(entity
+ 0x138))` in both `icPlanet::Load` (`0x10067eb0`) and `ParseSunInfo`
(`0x1004e5a0`). It is a physical radius in meters; there is no map-zone field and
no derivation. Median body 5.6e6 m, gas giants 3.2e7-2.6e8 m, stars 2e7-1.75e11 m.
(Yes, 1.75e11: `Hoffer's Wake Alpha` is authored as a 251-solar-radius red
hypergiant, and the engine takes it at face value -- it builds an
`FcSphereCollider` of exactly that radius.) We had been reading the right float
all along and then **clamping it to an arbitrary `8e7`**; the clamp was the bug.

**A record's fields are only valid for the kinds that write them.** The writer
reused one 360-byte buffer, so a station's `+0x138` is its parent body's radius.
That garbage is what made stations look planet-sized.

**Only `1 < IeBodyType < 5` is drawn** (`icPlanet::CreateAvatar`, `0x10067fe0`).
Type 4 is the ringed gas giant, and it is the only type that gets rings.

### Stars: class -> texture, class -> colour

`icSun::eClass` is the byte at record `+0x134` (0..15 in the shipped maps).

- **Texture** (`icSunAvatar` ctor, `0x100d2910`): `class < 3` -> `sun_blue`,
  `class < 7` -> `sun_yellow`, else -> `sun_red`. Default class is 6.
- **Colour** (`icSun::PickColour`, `0x1006ac70`): `icSun::m_colours` is **16
  pairs**; the star LERPs its class's pair with `rand()`. Blue-white -> white ->
  yellow -> orange -> red. The table is written by a runtime static-init
  (`FUN_10069f70`) so it is zeros in the file; the values are in `geography.md`.
- The avatar is scaled to `FiSim::Radius()` with a bounding radius of
  **radius x 1.4** (`_DAT_1011a440`) -- the extra 40% is the corona, which is what
  `sun_halo` (one quadrant, mirrored 4x, additive) is for.
- `icSun::CreateAvatar` (`0x1006a960`) also attaches **two `FcLensFlareNode`s**,
  both coloured by `PickColour`; the second's variant is 3 for class <= 2 and 1
  otherwise. `UpdateAvatar` pushes the first flare toward the camera each frame.

### Planets: `planets.ini` is the config, and the record is the content

`icPlanetAvatar`'s shader setup (`FUN_100cdc50 @ 0x100cdc50`) reads the record,
not the planet's name and not a hash:

| record | field | drives |
|---|---|---|
| `+0x13c` | `icPlanet::eType` | 1 = **rocky**, 2 = **gassy** (486 / 122 across the game) |
| `+0x13d`, `+0x13e` | `SurfaceType(0/1)` | index into `planets.ini` `rocky_`/`gassy_planet_textures[]` |
| `+0x140` | colours 0-255 | `SurfaceTint(0/1)` = colour / 255 (`_DAT_1011b068`) |
| `+0x164` | i8 | atmosphere texture index; **-1 = none** (339 have none, 269 have clouds1..4) |
| `+0x165` | u8 | ring count (0, or 4..8) |

A cloud layer and a second surface layer are **mutually exclusive**. Rings are
`FcRandom::Float(1.75, 2.44) x radius`, from an `FcRandom` seeded with the body's
radius, coloured by `SurfaceTint(0)`'s hue at value `FcRandom::Float(0.2, 0.8)`.

**`planets.ini`'s `colours[]` really is the last resort its comment says it is:
nothing in the render path reads it.** We were using it first.

### Stations: the model is in the record too

`ParseLocationInfo` (`0x1004e0a0`) reads `entity[0x134]` as a **scene index** and
`icStation::Scene(n)` (`0x100698c0`) looks it up in **`station_creation.ini`
`[Stations] Scene[n]`** -- 37 entries, each an `ini:/sims/stations/*` whose
`[Avatar]` names the LWS scene. All 756 station records resolve. `+0x136` is the
station's **faction allegiance** (`icFactions::FindFactionByAllegiance`).

This retires the name-keyword table we had been using to pick station avatars.

### L-points: the orientation is in the record

Every L-point carries a **unit quaternion at `+0x120`, stored (w, x, y, z)**,
which `icSolarSystem::Load` hands to `FiSim::SetOrientation`. All 76 are a pure
yaw. That is the frame `icLagrangePointWaypoint::TryToJump` (`0x1006ad40`) tests
`local z < 0` in, so it is the funnel's frame and its local +Z is the jump axis.
Into Godot (we mirror Z): the quaternion becomes `(w, -x, -y, z)` and the axis is
`basis * Vector3.FORWARD`.

### The HUD element list (authoritative, in draw order)
`flux.ini [icHUD]`:

```
use_thick_lines = 1 ; flash_delay = 6 ; flash_frequency = 3 ; menu_timeout = 30

0  icHUDReferenceGrid    8  icHUDShields        16 icHUDEditBoxElement
1  icHUDLagrangeIcon     9  icHUDClock          17 icHUDStarmap
2  icHUDWaypointIcon    10  icHUDContactList    18 icHUDEngineering
3  icHUDBrackets        11  icHUDReticle        19 icHUDLog
4  icHUDContrails       12  icHUDMenuReticle    20 icHUDObjectives
5  icHUDTargetMFD       13  icHUDDebug          21 icHUDScore
6  icHUDWeapons         14  icHUDMessage
7  icHUDOrbRadar        15  icHUDShipStatus
```

Also: `[icHUDMessage] message_delay=5, prompt_delay=10,
new_message_flash_frequency=0.333333, caution_flash_frequency=1`;
`[icHUDOrbRadar] use_thick_stalks=1`.

That list is itself a spec: it names every element the original HUD had --
including `icHUDContrails` (velocity trails) and `icHUDReferenceGrid` (the
motion grid), which we have not built.

**There are no L-point art assets in `resource.zip`** (no lagrange/lpoint model,
texture or INI). The blue/red funnel is entirely procedural code, in
`icHUDLagrangeIcon`, whose base class `iiHUDUnderlayElement` places it in world
space.

### The world-space HUD elements (recovered; see `hud.md` for the full write-up)

Vtable **slot 9 (`+0x24`) is `Draw`**.

| class | ctor | vtable | Draw |
|---|---|---|---|
| `icHUDLagrangeIcon` | `0x100ee8b0` | `0x1011dc90` | `0x100ee920` |
| `icHUDReferenceGrid` | `0x100f54d0` | `0x1011e004` | `0x100f5550` |
| `icHUDWaypointIcon` | `0x10104040` | `0x1011e2cc` | `0x101040b0` |

(Ghidra leaves the Lagrange `Draw` undisassembled -- it has to be read from the
raw bytes.)

**The L-point funnel.** 84 vertices, 132 lines: 12 segments, 7 rings at
`z = -1500..+1500` step 500, with

```
radius(z) = (3 - 2*cos(z*PI/3000)) * 375
```

so a **375 m waist**, **1125 m mouths**, **3000 m** long. No spokes across the
waist. The arithmetic self-checks: `0x410 + 132*2*2 = 0x620`, exactly the
`operator_new` size in the factory.

**What blue and red mean** -- not near/far, which is the obvious guess.
`icLagrangePointWaypoint::TryToJump` (`0x1006ad40`) refuses a jump unless the
ship's offset from the L-point has **local z < 0**. That makes the L-point's
local **Z axis the jump axis**, and so:

- **blue = the -Z *entry* funnel** (the side you must be on to jump)
- **red = the +Z exit side**
- the waist ring is green `(0.5, 1, 0)`

Exactly **one** funnel is drawn, for the **nearest** L-point
(`icPlayerContactList::NearestLagrangePoint`, `0x10002800`, is a bare field
read). Hard **50 km** cutoff; per-vertex alpha `0.4 + 0.6t`.

**The reference grid is neither blue/red nor a grid.** It is a **9x9x9 lattice of
729 velocity streaks**:

```
cell   = 10^clamp(floor(log10(speed) + 0.3), 3, 10)   ; snaps to a decade
length = speed / 3                                    ; a third of a second of travel
anchor = fmod(world_pos, cell)                        ; absolute, not ship-relative
alpha  = clamp(speed*0.007, 0, 1) * t                 ; fades out at 5.5 cells
colour = (1.0, 0.592, 0) amber, or (0.5, 1, 0) yellow-green under LDS
```

**The waypoint icon is a 300 m cube** at 15 km draw distance. Our beacon cube was
right in kind; its 26 m size was invented.

### The 2D HUD (recovered; full write-up in `hud_elements.md`)

Two things that make this code hard to read, worth knowing before you go back in:
the **vtables are not in Ghidra's output** and must be dumped from the PE, and the
**colours are written by tiny runtime static-init functions**, so they read as
garbage from the file -- you find them by grepping for `DAT_xxx = 0x3f800000;`
and reinterpreting the hex as IEEE-754 bits.

**HUD coordinates are absolute pixels. There is no resolution scaling.**
Cross-checked against a reference screenshot (a 1280x800 render upscaled
1.4984x): the reticle ring measures `95/1.4984 = 63.4` against the binary's
**63**, and the icon ring `166/1.4984 = 110.8` against **110**. Two independent
measurements agreeing to 1%.

**The palette** -- the actual constants, which we had been eyeballing:

| colour | RGB | used for |
|---|---|---|
| chartreuse | `(0.5, 1, 0)` | the HUD's base green; the clock; the L-point waist ring |
| amber | `(1, 0.592, 0)` | the reference grid |
| gold | `(1, 0.8, 0)` | **neutral** contacts (not yellow) |
| red | `(1, 0.07, 0)` | hostiles |
| blue | `(0.1, 0.1, 1)` | **friendlies only** |

The damage ramp breaks at **0.75 / 0.25** (we had guessed 0.66/0.33).

**Reticle** (`0x100f6340`): ring **r=63**; off-reticle threshold `63+10`; status
icons on rings of **110** (and **150** for the four mode icons) at fixed angular
slots, clockwise from twelve o'clock (the ctor stores
`x = floor(sin(a)*r), y = floor(-cos(a)*r)`). Charge rings are **24 pips at
r=18**.

**Contact list**: **6 rows** plus a scrollbar, sorted by range ascending, and the
format string is literally

```
"%-5s %-5s %-5s %-12.12s%c"
```

a monospace character grid. That is exactly the "tighter, more readable" quality
the original has. There is **no highlight box** on the selected row. Its range
formatter is deliberately *different* from the reticle's: `7103m` in the list,
`7.1km` in the reticle, for the same contact.

**Brackets** are not geometry: four corner **sprites** on the target's projected
bounding box, with a **0.35 s slam-in** from 70 px out.

**Panels**: `iiHUDBlockElement` stacks blocks into the screen corners. Margin 6,
border 4, gap 3, header 16, advance `h+11`. MFD **128x176**; weapons and shields
**112** wide; 32 px rows; **14-segment** bars.

**Not statically recoverable** (left alone rather than invented): font metrics are
*measured at runtime* and zero in the file, so the clock block's size, the MFD's
text-line Y and the contact-list block width cannot be read out; the sprite table
mapping a glyph to each status-icon slot is built at runtime (the slots and radii
are real, the icons are not); the reticle ring's tick pattern is a texture.

### Effects are a two-layer system, and both layers are now extracted
(Full write-up in `effects.md`.)

`data/ini/sfx/<name>/` -- twelve particle systems, each `node.ini` +
`emitter.ini` + `dynamics.ini` + `draw.ini`. Nothing in `sims/weapons/*.ini`
references any of them, which is why the link looked missing: **a weapon does
not name its effects.**

The layer above is **`sfx/*.lws`** -- 23 LightWave scenes in `resource.zip`,
now extracted to `data/json/sfx_effects.json` (`tools/iw2/sfx.py`). Each
composes particle systems, a sprite flipbook, a sound and a light into one
effect. `icVisualEffects` (`iwar2.dll`, prefix table `0x10161f14`) holds twelve
URL *prefixes* and builds the URL with `"%slow"` or `"%shigh_%d"`
(`0x101620a0`). So the engine picks the effect from the *kind of event*.

**`low` vs `high_%d` is a distance LOD, not a quality setting.**
`icVisualEffects` (`0x100d33e0`, called from the play function `0x100d3210`)
computes `apparent = size * size_weight[effect] / distance_to_camera`, with the
weights in a `float[12]` at `0x1011d254`, and then:

    apparent < cull_detail (0.005)  ->  nothing is drawn
    apparent < low_detail  (0.04)   ->  the `_low` scene, and if the effect
                                        ships none, nothing is drawn
    otherwise                       ->  a uniformly RANDOM `high_%d`

(`cull_detail`/`low_detail` are its two registered properties, defaults at
`0x10161f0c`/`0x10161f10`.) Only `explosion` and `small_explosion` ship three
`high_` variants, and they differ *only* in flipbook + sound -- which is what
makes "pick one at random" legible. Five of the twelve ship no `_low` scene at
all, so they simply vanish past that distance.

**Which effect fires for which event** -- recovered from the seven call sites of
`0x100d3210`. Note the decompiled `iwar2.dll.c` only shows four of them: Ghidra
dropped three, and they were found by scanning `.text` for `E8` calls to the
target. Do not trust the `.c` for call-site census work.

| effect | fired by | condition |
|---|---|---|
| `explosion` | `icExplosion` | its radius >= **150 m** (`0x1011a81c`) |
| `small_explosion` | `icExplosion` | its radius < 150 m |
| `hull_impact` | `icBullet` | default |
| `asteroid_impact` | `icBullet` | target category (`sim+0x194`) is `0xb`/`0xe` *and* a name test on `sim+0x184` passes |
| `beam_impact` | `icBeam` | on hit |
| `lda_impact` | the LDA ship-system (`0x10036210`) | a shot crossing the ship's LDA shield **ellipsoid**; only if the ship mounts an LDA. It is drawn at the ray/ellipsoid intersection, not at the hull |
| `plasma_fire` | `icShip::ApplyWeaponDamage` | probabilistic: `p = (1 - armour/max_armour) * damage_fraction`. The burning-hull effect; sound is `critical_hit` |
| `reactor_explosion` | `icShockwave` | no type flag (the default) |
| `antimatter_explosion` | `icShockwave` | `antimatter=1` (`+0x1e8`) |
| `alien_explosion` | `icShockwave` | `alien=1` (`+0x1ea`) |
| `ldsi_explosion` | `icShockwave` | `ldsi=1` (`+0x1e9`) |
| `collision` | `iiSim::ProcessContact` | two sims touching |

The four `icShockwave` flags are confirmed independently by the data:
`sims/explosions/*.ini` are all `name=icShockwave` and carry exactly
`antimatter=1`, `alien=1`, `ldsi=1`, or nothing (`reactor_explosion.ini`).

**A ship death is not one explosion.** `iiSim::DoFinalExplosion`
(`0x1007c990`) spawns **four** `icExplosion` puffs, each of radius
`R * lerp(0.3, 0.6, rand)` (`0x1011c034`/`0x101192c4`) and offset by a random
unit vector * `R * 0.4` (`0x10117558`), plus one `reactor_explosion` shockwave
sim (`final_radius = R*4`, scale `clamp(R/200, 0.25, 4)`; `mean_radius_of_
reactor_explosion_sim = 200` in `defaults.ini:446`) unless the sim sets
`no_shockwave=1` (only the power-ups do). Each puff then picks its own effect
against the 150 m rule -- so a fighter (`R` ~ 60-70 m, puffs of 20-40 m) shows
**`small_explosion`, never `explosion`**. You need `R` > ~250 m for the big one.
That is the answer to "when is `small_explosion` used instead of `explosion`".

Three facts that guessing had wrong:

- **A ramp is keyed on *seconds remaining*, not on normalised lifetime.**
  `FiParticle::AgeStep` (`0x1004da70`) is `remaining -= dt`, and
  `FcParticleDrawBillBoard::Setup` (`0x10050770`) uses
  `t = clamp(1 - remaining/max_age, 0, 1)`. `max_age` defaults to **1.0**
  (`OnPropertiesChanged`, `0x1004ff20`) and **no shipped `draw.ini` sets it** --
  so every colour/size ramp in the game plays over the final *one second* of a
  particle's life and is clamped flat before that.
- **Particles are additive.** `OnDisplay` (`0x1004ffd0`) sets `eBlend = 1`,
  z-write off. The colour arrays have no alpha, every ramp *ends* at `(0,0,0)`,
  and `fade_on_emitter_age` fades by scaling the colour toward black -- which
  only means "invisible" under `src=ONE, dst=ONE`. The ramp is an emitted
  intensity, not a tint.
- **Speed is multiplied by the emitter's scale**, so the authored speeds are
  small numbers (`0.8`-`1.2`) and the emitter transform sizes the effect to the
  thing that blew up (`FcParticleDynamics::Spawn`, `0x10053f80`).

`FnRandom::CentreWeighted(a,b)` (`0x100480b0`), which picks every random
quantity in the system, is one uniform run through an S-curve
(`w = 2u^2` / `1-2(1-u)^2`), biased to the centre of the range.

**The muzzle flash and the bolt are not particle systems.** The muzzle flash is
a lens-flare light on `avatars/standard_pbc/setup_effects.lws`, parented to an
`<anim channel="fire?o(5.0)">` null -- the same channel rig as the thrusters.
The bolt (`avatars/standard_pbc_bolt/setup.lws`) is one
`<node class=icBeamAvatar texture=pbc_standard>` scaled **`4 1 800`**: an 800 m
textured streak, matching `length=800` in `sims/weapons/pbc_bolt.ini`. Not a
bullet.

### Cameras
`flux.ini`: `[icInternalCamera] field_of_view = 1.1` rad (63 deg),
`neck_stiffness = 2`, `acceleration_stiffness = 1`, `acceleration_scale = 0.01`,
`yaw_ratio = 0.25`, `pitch_ratio = 0.4`, `roll_ratio = 0.25`,
`lateral_ratio = (-0.15,-0.2,-0.2)`, `focal_length = 100`.
External cameras: `field_of_view = 1.2` rad (68.75 deg).

---

## 8. Data and text

- **`text.Field` (636 call sites) is where every line of dialogue comes from.**
  The tables are CSVs (`csv:/text/act_0/act0_master` etc.), format `key,"text"`,
  `;` comments. 178 of them.
- The INI tree (779 files) is read at runtime by the `inifile.*` natives.
- Both are Latin-1 in the original. We convert them to UTF-8 **at extraction**;
  the runtime never sees two encodings.
- Avatar geometry is PSO2 (not LWO). `DELT` chunks in a PSO are **facial morph
  targets**. `LWS ParentObject` can *forward*-reference an object defined later
  in the scene, so parenting needs two passes.
- The HUD sprite atlas is **white-on-black, not transparent**. It has to be
  converted to an alpha mask (alpha = luminance) or tinting a cell paints the
  whole cell.

---

## 9. Deliberate divergences

Things we do differently, on purpose. Each one is a decision, not an accident.

| we do | the original did | why |
|---|---|---|
| Port the bytecode to GDScript; ship no interpreter | Ran POG bytecode in a VM | The remaster must not carry the 2001 resource format and object model forever. The VM survives as a differential oracle (`--pog`), not the runtime. |
| Floating origin: player at the scene origin, true position in `main.px/py/pz`, AI ships positioned *relative to the player* | World coordinates | float precision at solar-system scale. **Consequence:** moving the player moves the origin, so AI ships must be re-anchored or they are dragged along. |
| `MarkObject`/`DeleteMarkedObjects` are no-ops | Manual object-scope GC | Godot refcounts. Memory management, not behaviour. |
| Multiplayer (`imultiplay`, 118 natives) not ported | -- | Single-player remaster. |
| The player flies `tug_prefitted.ini`'s subsim list | `tug.ini`'s empty mountpoints, filled by the fitting screen | Same hull (1000 hp / 65 armour) and the avatar we already render. The fitting screen is not ported, and empty mountpoints have `hit_points=0`, so they cannot be damaged -- a tug fitted from `tug.ini` would have no shields and no subsystem damage at all. |
| Every impact lands exactly `N` subsim criticals | The same, via an RNG gate that re-rolls until they all land | The `critical_chance_scale` roll in `icShip::ApplyWeaponDamage` does not consume a loop iteration when it fails, so it is a no-op that only costs spins. We do the N hits directly. |
| Bodies and stars are drawn as impostors: pulled in to 250 km and scaled down by the same factor, so the *angular* size is right, with the apparent radius capped at `0.4 x` the draw distance | Drew them at their true distance and size | Floating origin + a 600 km far plane. The cap only bites when a body would subtend more than ~44 degrees, which happens because a few authored star radii are enormous (see `geography.md`). |

---

## 10. Open questions

Known gaps. **Do not fill these in with plausible values** -- find the answer.

- **`IeSimType`**: only `T_CommandSection = 131072` is confirmed. The rest of the
  bit flags are unknown; our table has placeholders and says so.
- **`IeBodyType`.** The values are known by behaviour (0 = system centre, 4 = the
  ringed gas giant, 2/3 = the drawn bodies, 1 and 6 exist and are *not* drawn but
  do count as LDS obstacles) but the enum's actual names are not recovered.
- **The sun / planet avatar draw code.** Ghidra leaves `icSunAvatar`'s draw
  (`0x100d2b30`, `0x100d2b80`) and `icPlanetAvatar`'s (`0x100ccbb0`, `0x100ccc60`,
  `0x100ccc80`) undisassembled, same as the Lagrange icon. So the corona's exact
  geometry and blend, a planet ring's **width**, and the atmosphere shell's blend
  are unread. We have the textures, the colours, the ring radii, the 1.4x sun
  bound and `atmosphere_height = 1.1`; the ring width in `main.gd` is a marked
  placeholder.
- **Station record bytes `+0x135` and `+0x137`.** `icStation::Load` reads both
  (`+0x135` -> `icStation+0x1e0`, values 0..122; `+0x137` -> `+0x1e5`, quantised
  3/5/10/15/.../250). Neither is identified. The faction byte `+0x136` and the
  scene byte `+0x134` are.
- **The L-point's `+0x134` link word.** `icSolarSystem::Load` stores it at
  `icLagrangePointWaypoint+0x20c` and `icCluster::ConnectLagrangePoints`
  (`0x10044e50`) consumes it. We take the jump destinations from the file's tail
  table instead, so we never decoded what it indexes.
- **The status-icon glyphs.** The reticle's icon *slots and radii* are recovered,
  but the sprite table that maps a glyph to each slot is built at runtime, so
  which icon sits in which slot is unknown. Ours currently use text labels.
- **Font metrics.** Measured at runtime, zero in the file. The clock block's
  size, the MFD's text-line Y and the contact-list block width cannot be read
  out of the binary; they have to come from the bitmap font itself.
- **The TRI weight table.** `iiShipSystem::m_tri_weights`, indexed by a system's
  TRI position, multiplies an `icPlayerLDA`'s deflect chance and recharge rate --
  for the player only (`TRIWeight`, `0x1003c170`, returns 1.0 for everything
  else). The table's values were not read out. `ship_systems.gd` uses 1.0.
- **The LDA's second arc test.** `icPlayerLDA` (`0x100acda0`) runs a second
  coverage test against the sim it is currently tracking (`+0xa0`, chosen by
  `0x100ad000` from the contact list), gated by `field_coverage` and
  `field_hold_time`. Only half read; we implement the hood test and skip it, so
  our LDAs deflect slightly more than the original's.
- **The `eBlend` enum.** Particles use `1`, the HUD and sprites use `2` and `3`.
  We are confident `1` is additive (see `effects.md`), but the enum is only
  *applied* in `dx7graph.dll`, which is not decompiled, so the mapping to actual
  blend factors -- and the meaning of `0` and `3` -- is unread.
- **The shockwave avatars' geometry.** `icShockwaveAvatar`, `icLDAAvatar`,
  `icBeamAvatar` and `icMovieAvatar` are named in the `sfx/*.lws` scenes with
  their `tint`/`lifetime`, and we now also know `icShockwaveAvatar` hardcodes
  the texture **`texture:/images/sfx/shockwave`** and picks a **random unit
  vector** in its constructor (`0x100cfa50`) -- so it has an orientation axis.
  But its *draw* code is exactly where Ghidra gives up: the class's display
  virtuals are vtable `0x1011d140` slots 14/16 (`0x100cfc90`, `0x100cfcb0`) and
  the decompiler bails with "could not recover jumptable", so the actual
  primitive (ring? sphere? camera-facing quad?) is unread, and the primitives
  themselves live in the undecompiled `dx7graph.dll`. We therefore play the
  antimatter / reactor / alien / LDSI explosions' **light and sound only** and
  draw no shockwave. Guessing a mesh here would be inventing art.
- **`antimatter_explosion` has a beam rig we do not draw.** Its scene has eight
  `icBeamAvatar` nodes (`texture=SearchBeam`) parented through `FatBeamsH` /
  `SkinnyBeamsP` / `beam_scaler_*` nulls -- the radiating spikes. Extracted into
  the JSON (with parenting resolved), but unplayed for the same reason.
- **Does an effect's light range scale with the effect's size?** The engine sets
  the effect scene-node's scale to `size` on all three axes (`0x100d3210`), and
  the LightWave light hangs inside that scene, so we scale `LightRange` by
  `size`. Whether the original's D3D light actually inherits the node scale is
  unverified (it is applied in `dx7graph.dll`).
- **The `asteroid_impact` name test.** `icBullet` selects it when the target's
  category (`sim+0x194`) is `0xb` or `0xe` **and** an `FcString::Find`-style
  import (`0x10116a0c`) on the target's string field (`sim+0x184`) against a
  runtime-initialised global (`0x10166318`) returns >= 0. The category enum and
  the global's string value are both set at runtime, so "which sims count as
  rock" is known by shape but not by name.
- **`icCornflakeDraw`'s flake size** and blend mode. The class has *no*
  properties (it hardcodes `images/sfx/cornflakes` + `cornflake_masks`, a 4x4
  atlas) and we did not find the constant that sizes a flake; ours is a marked
  placeholder.
- **`icMovieAvatar`'s playback rate and quad size.** The `explosion` scene is 60
  frames at 60 fps but the `deba` flipbook has 50 frames; nothing says whether
  the movie plays at the scene rate, is stretched over the scene, or has its
  own. Its quad's size in metres per unit of scene scale is likewise unread.
  `ExplosionFx.MOVIE_FPS` (25) and `MOVIE_QUAD` (0.52) are marked placeholders.
- **`eDamageSource`** beyond `0` (weapon), `1` (shield-bypassing weapon) and `3`
  (heat). There is a log-event table at `DAT_1011bf14` indexed by it.
- **Flag `0x100`** on a subsim (`iiShipSystem+0x68`) means "destroy me when my
  hit points go negative" rather than merely stop working. Which subsims set it
  is unread, so in our model nothing is ever permanently removed.
- **`icShip+0x2ac`** -- the subsystem that drives the flat hull regen at
  `0x10076028` (`hull += (+0x80) * dt`). Not identified; we do not implement it.
- **The `gui` widget toolkit** (99 natives) -- the base screens (trade,
  manufacturing, recycling) are POG scripts driving it; we replaced the front end,
  so most of it is stubbed.
