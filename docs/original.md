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

## 4a. The approach markers -- and so the autopilots' break-off

**The player's autopilot IS the AI order system.**
`icPlayerPilot::EngageAutopilotApproach` (`iwar2 @ 0x100afbc0`) calls
`icAIServices::DefaultApproach(player_ship, target)` and pushes the resulting
order onto the player's *own* `icAIPilot` (`icPlayerPilot+0xc0`), named
`"AutopilotApproach"`. `Formate`, `Dock` and `MatchVelocity` do the same. So
there is exactly **one** approach rule in the game, and the player and the AI
both obey it.

`icPlayerPilot::Simulate` then disengages the autopilot the moment the order slot
empties -- i.e. **the autopilot breaks off precisely when the order completes**.

### The break-off distance is `InnerMarkerRadius`, and it is derived from the target

`icAIServices::DefaultApproach` (`0x10056330`) builds the order's `icAITarget::
cData` with `radius = icAIServices::InnerMarkerRadius(ship, target)` (`cData+0x44`),
and `icAITarget::ComputeTargetVector` (`0x10058708`) drives
`range = |distance_to_centre| - cData.radius` to zero. The ship flies to a
**sphere around the target**, not to its centre. That is why a station and a
planet break off at wildly different ranges: **the marker is a function of the
target's size.**

`icAIServices::InnerMarkerRadius` (`0x100560d0`), fully read:

```
InnerMarkerRadius(ship, target):
    if target is icNebula:        return target.Radius() * 0.9      ; 0x1011951c
    if target.category == 0x1f:   return 0
    ship_r = ship.BoundsRadius()                                    ; FiSim+0x20
    tgt_r  = (target is icAsteroidBelt) ? 0 : target.BoundsRadius()
    if target is icPlanet or icSun:
        tgt_r *= (icPlanet::m_heat_radius_multiplier + 1.0)         ; 0.5 + 1.0
    if |tgt_r| < 1e-6:
        return icAITarget::m_waypoint_approach_distance             ; 20 m
    return max( tgt_r + ship_r + 200,                               ; 0x10119470
                1.75 * Avoid(tgt_r, ship_r),                        ; 0x1011a264
                1.75 * Avoid(ship_r, tgt_r) )

Avoid(a, b)  =  max(a*1.1 + b*1.25, m_minimum_avoidance_radius)     ; 20, unless a == 0
                     ^0x10119e94  ^0x1011a19c
```

`OuterMarkerRadius` (`0x10056280`) = `Inner * 1.5` (`0x1011a268`) -- but a nebula
reports its plain `Radius()`. `FarOuterMarkerRadius` (`0x100562e0`) =
`max(target.BoundsRadius() + 25000, Outer + 25000*0.2)`.

`FiSim::BoundsRadius` (`FiSim+0x20`, `FiSim::UpdateBoundsRadius @ flux
0x100c05a0`) is the sim's own radius grown to enclose its attached child sims;
for anything without children it **is** `Radius()`.

### The completion test

`icAIApproachAgent::Think` (`0x1004f9c0`) completes on
`icAITarget::IsPositionComplete` (`0x1005a047`), which is the flag
`ComputeTargetVector` sets:

```
complete  <=>  |distance_to_centre - marker| < cData.completion_radius
cData.completion_radius = min(marker * 0.05, m_maximum_standard_completion_radius)
                                     ^0x1011a198          ^ = 0.5 m
```

(`icAITarget::RecomputeRadii`, `0x10057ede`.) The engine's position controller
settles onto the sphere and holds, so half a metre is achievable for it.

### The constants (all read out of the shipped `iwar2.dll` export table)

| symbol | value |
|---|---|
| `icAITarget::m_waypoint_approach_distance` | **20** m |
| `icAITarget::m_minimum_avoidance_radius` | **20** m |
| `icAITarget::m_maximum_standard_completion_radius` | **0.5** m |
| `icAITarget::m_min_completion_radius` | 0.01 |
| `icAITarget::m_lds_approach_distance` | **25 000** m |
| `icAITarget::m_lds_approach_completion_distance` | 1 000 m |
| `icAITarget::m_avoidance_range_squared` | 6.4e7 (8 km) |
| `icAITarget::m_minimum_avoidance_radius` | 20 m |
| `icAITarget::m_min_avoidance_factor` | 0.4 |
| `icAITarget::m_max_avoidance_time` | 8 s |
| `icAITarget::m_emergency_avoidance_time` | 2 s |
| `icPlanet::m_heat_radius_multiplier` | **0.5** |
| `icAIServices::m_inner_radius_indicator` | **-1** (a sentinel: "solve it later") |
| `icAIServices::m_outer_radius_indicator` | -2 |
| `iiThrusterSim::m_avoidance_distance` | 5 000 m |

Worked examples, with the player's tug at a ~60 m bounds radius:

| target | radius | marker |
|---|---|---|
| a fighter | 60 m | **310 m** (`60 + 60 + 200`) |
| a station | 1 100 m | **2 400 m** (avoidance dominates) |
| a median body | 5.6e6 m | **1.8e7 m** (1.5x radius, then 1.75 x 1.25) |

### The eAutopilot enum

`icPlayerPilot::SetAutopilot` (`0x100af930`): **0 Off, 1 Formate, 2 Approach,
3 Dock, 4 MatchVelocity, 6 RemotePilot**. It is not the F5..F9 order.
`SetAutopilot` also **downgrades Formate to Approach when the target is not an
`iiThrusterSim`** -- you cannot fly formation on a station.

### `iai.InnerMarkerRadius`'s POG argument order is the reverse of the C++ one

The C++ static is `InnerMarkerRadius(ship, target)`; the POG native is
`(target, ship)`. `iact0mission10.pog:164` is decisive:

```
if (sim.DistanceBetween(v0, v8) < iai.InnerMarkerRadius(isim.Cast(v8), v0) + 500.0)
```

with `v0` the player's ship and `v8` the thing being approached.

---

## 4b. The controls -- the game ships its own keymap

Full write-up in **`controls.md`**. The keymap was an open question in this
document and should not have been: the install carries **both** binding sets,
complete, in `configs/default.ini` (joystick, "recommended") and
`configs/keyboard_only.ini` (no joystick). Every `input.KeyCombinations(...)`
prompt in the scripts can now be filled in.

The three things that make IW2 feel like IW2, all confirmed against
`icPlayerPilot::HandleLinearMessage` (`iwar2 @ 0x100ae2b0`) and
`icPlayerPilot::RegisterInputs` (`0x100aea00`):

- **You steer on the numpad and strafe on WASD.** `LateralX` is A/D, `LateralZ`
  is W/S -- *thrusters*, not the stick. Yaw is NumPad4/6, pitch NumPad2/8, roll
  NumPad1/3. `LateralY` (vertical strafe) has **no keyboard binding at all** in
  either shipped config; it is joystick-only.
- **`RollYawToggleHold` swaps yaw and roll.** Hold it (joystick button 2) and the
  X axis rolls instead of yawing. `flux.ini [icPlayerPilot] toggle_roll_yaw = 0`
  makes it a hold rather than a permanent swap. The yoke slots are identified
  from `icAITarget::AngularVelocityToEuler` (`0x1005df5c`), which is
  `icEuler(w.y, w.x, -w.z)` -- so **`icEuler` is (yaw, pitch, roll)**.
- **The throttle is a fraction of top speed, rate-limited to +-1/3 per second**
  (the float at `0x10119454`): a full sweep takes three seconds. The zoom factor
  (`max_zoom_factor = 10`, `zoom_time = 0.5`) **divides yaw and pitch but not
  roll**, which is what makes a zoomed shot aimable.

### F1 is the "turn the cockpit off" key

`icDirector`'s constructor (`0x100d5e20`) builds five camera **groups**, and
`icDirector::OnMessage` (`0x100d6920`) cycles them: a camera key pressed from
*outside* its group jumps to the group's first camera; pressed from *inside*, it
steps to the next one, wrapping.

```
F1  cam_internal_cockpit -> cam_internal_no_cockpit -> cam_arcade
F2  cam_tactical -> cam_inverse_tactical
F3  cam_external -> cam_target_external
F4  cam_drop
```

So the removable cockpit dressing was never a separate option -- it is the second
press of F1. (`cam_internal_no_hud` exists, at index 3 of the `eCamera` name table
at `0x101621e0`, but sits only in the developers' `DevCycleAllCameras` group,
which ships bound to nothing.)

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

## 5b. Heat is a raw two-store accumulator, not a temperature

Two stores on `icShip`: internal (`+0x288`, fed by every live subsim's
`heat_rate * power_ratio` and by beam fire at `sqrt(damage_rate) * heat_scale`
per second) and external (`+0x28c`, fed only by sun/planet proximity, and only
on the player's ship: `t = 1 - d/(0.5 * radius)` inside half a radius of the
surface, `t^2 * 10000` per second for planets, ten times that for suns).
Heatsinks cool at `heat_loss_rate` ramped from 20% on a cold ship to 100% at
nine-tenths of the `heat_damage_threshold` (500, flux.ini) -- so a ship's
resting heat is the equilibrium between its fitted subsims and its heatsink,
about 96 for the prefitted comsec and 128 for the prefitted tug, not zero and
not the threshold. Net cooling drains the external store before the internal
one, at half rate (`heat_loss_factor=0.5`). Both stores clamp at the
threshold. Over the threshold every non-heatsink subsim is capped at 0.75
efficiency and weapons refuse to fire; hull damage `(total - 500) * 0.08` (per
frame, no dt term in the original) only applies while the *external* store is
at least half the total -- a ship can never burn itself, only a sun or planet
can kill it. The HUD thermometer is `total / 500 * 0.8` clamped to 1, so
internal-only overheat pegs at 0.8 and the top fifth of the gauge is sun
territory. Sources: `0x1003bbd0`, `0x100300c0`, `0x10068380`, `0x1006ab90`,
`0x1002ee90`, `0x10075f60`, `0x1003cc00`, `0x10108890`; constants in
`docs/combat.md` section 8.

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

### `text.Field` is not a dictionary lookup

`FcLocalisedText::Field` (`flux @ 0x10028d80`) has three behaviours that a plain
`table[key]` does not, and every one of them is load-bearing:

- **The key is split on `'+'`** and each token looked up and concatenated. That
  is how the scripts interpolate numbers into names, and they do it constantly:

  ```
  iact1mission10.pog:394  iship.Create(".../navy/fighter",
                              string.Join("a1_m10_ship_name_fighter+ +", string.FromInt(v10)))
  iact0mission10.pog:570  iutilities.MakeWaypointVisible(v8, 1,
                              string.Join("a0_m10_name_other_waypoint+ +", string.FromInt(v4)))
  ```

  so the ship's name is the key `a1_m10_ship_name_fighter+ +2`, and it renders as
  `Fighter 2`.
- **A lone `" "` token is a literal space**, not a lookup (the engine tests for a
  one-character token equal to `' '`). That is what the `+ +` idiom above is for.
- **A token that is in no loaded table resolves to ITSELF.** Outside developer
  mode the engine returns the token text; in developer mode it appends a marker.
  So a missing table does not blank a string, it **leaks the raw key** -- which is
  exactly how `A1_M10_SHIP_NAME_FIGHTER+ +2` ends up in a contact list.
- Keys are hashed **lower-case**, so the lookup is case-insensitive.

### A sim's NAME is a localisation key, and displaying one means resolving it

`sim.Create(url, name)` takes a *key*: `iShipCreation.ShipName` composes
`sn_general_<n>` from `ship_names.ini` (per category, a `NumberOfEntries` and a
`Prefix`) and hands it straight to `iship.Create`. `iact2mission24.pog:3478` even
has a literal `iship.Create(".../heavy_corvette_mca", "sn_general_212")`.

Nothing displays that key. **`icAIPilot::ResolveName`** (`iwar2 @ 0x10055540`) is
the funnel: it takes a sim, runs `FcLocalisedText::Field(sim->name)` and returns
the text. A null sim resolves to `"Undefined"` (the literal at `0x1015c244`).
`csv:/text/ship_names` is loaded by `istartsystem.pog:486`, at StartupSystem.
- Both are Latin-1 in the original. We convert them to UTF-8 **at extraction**;
  the runtime never sees two encodings.
- Avatar geometry is PSO2 (not LWO). `DELT` chunks in a PSO are **facial morph
  targets**. `LWS ParentObject` can *forward*-reference an object defined later
  in the scene, so parenting needs two passes.
- The HUD sprite atlas is **white-on-black, not transparent**. It has to be
  converted to an alpha mask (alpha = luminance) or tinting a cell paints the
  whole cell.

---

## 8-0. `IeHabitatType` is the station record's `+0x135`

The station sub-type byte the geography notes had as unidentified (`+0x135` ->
`icStation+0x1e0`, values 0..122) **is `IeHabitatType`**: `icStation::HabitatType()`
(`iwar2 @ 0x1004ada0`) is exactly `return *(this + 0x1e0)`. `map_decoder.py` calls
it `station_subtype`.

The enum is never named in either binary, but the shipped data names it:

- Every station whose avatar is `policestation` carries **68 or 69** -- and
  `ifight.pog:111` builds its police set as precisely
  `FilterOnType(68) UNION FilterOnType(69)`. Nothing else in the game has those
  values.
- **54** is `securitystation` (26 of 27 instances) and **55** the fortresses.
  Every subtype found on a `navalbasestation` -- 70, 71, 73, 74, 79, 81, 85 --
  lies inside the set `ifight.pog:187` unions for "military"
  (72, 73, 70, 71, 79, 82, 85, 54, 55, 78).
- The names read straight back: **70** "Defense Station", **71** "Defence Dock",
  **73** "Naval Training Base", **79** "Naval Defences", **122** "Orbital Transfer
  Station".

Checked end to end: in Hoffer's Wake, `FilterOnType(68) | FilterOnType(69)`
returns exactly `Police Patrol Station` and `Hoffers Wake Police Headquarters`,
and all 109 habitats in the system resolve to a type.

This is what `ihabitat.FilterOnType` (81 call sites) and `ihabitat.Type` (40) run
on -- the traffic generator, the mission generator and every `ifight`/`iflee`
"who will respond to this" query.

**`IeBodyType` is still not found**, and it is *not* the analogous byte:
`body_type` (`+0x134`) only ever holds 2, 3, 4 or 6, and `planet_type` (`+0x13C`)
only 1 or 2, while `iscriptedorders.pog` compares `ibody.Type` against **5** and
**7**. See Open questions.

### `icAIServices::InnerMarkerRadius` -- the approach marker

`iwar2 @ 0x100560d0`. For an ordinary sim the whole function is

    inner = target.Radius() * 0.9          ; the 0.9 is the float at 0x1011951c

and `OuterMarkerRadius` (`0x10056280`) is `InnerMarkerRadius * 1.5`
(`0x1011a268`). A planet or sun instead scales by
`(HeatDistanceAsRadiusMultiplier + 1.0)`, and a target whose category is `0x1f`
returns 0 -- those branches are not fully read.

POG's argument order is `(target, ship)`: `iact0mission10.pog:117` passes the
object being approached first and the player's ship second, and it is the
object's size the marker comes from.

### `iloadout::eLoadout` is one-based, in button order

`ibasegui` builds the loadout buttons standard, assault, stealth, ecm
(`local_13541`) and pushes them into the `LoadoutButtons` list;
`SPLoadoutScreen_OnLoadout` finds the checked one's index and maps 0->1, 1->2,
2->3, 3->4 before calling `CalculateLoadout`. So **1 = STANDARD, 2 = ASSAULT,
3 = STEALTH, 4 = ECM**. The screens build only four buttons, though the mapping
runs to 6. The names are capped at eight characters "because of the hangar", says
the comment above them in `text/gui.csv`.

---

## 8a. The base screens are POG, and the engine called back into them

A screen is named by its C++ class (`gui.SetScreen("icSPPlayerBaseScreen")`), and
the engine's screen object **built itself by calling a POG function**. The
constructor of `icSPBaseScreen` (`iwar2 @ 0x10029230`) ends in
`FcScriptEngine::CallFunction`, and its destructor (`0x10029350`) calls another
before `HaltAllTasks`.

The function is the class name **without its `ic`**, in whichever package defines
it -- `icSPHangarScreen` -> `iBaseGUI.SPHangarScreen`. Checked across every screen
the campaign names: 33 of the 48 resolve to a function in **exactly one** package
(`ibasegui` owns the `SP*` base screens, `ipdagui` the PDA, `inetworkgui` and
`ifrontendgui` the rest). The other 15 -- `icSpaceFlightScreen`,
`icSPComputerTradingScreen`, `icSPAddCargoScreen`, `icSPComputerPuzzleScreen`,
`icPopUpCommsScreen`, `icNotYetImplementedScreen` and the multiplayer lobby --
have **no POG builder at all**: they were built in C++. Their factories
(e.g. `0x100299f0`) just `operator_new` the base class and set a vtable.

**So the trade screen is not POG.** It is worth being clear about, because it is
the one base screen you would most expect to be script-driven and it is not.
Manufacturing, recycling, inventory, the hangar, the loadout, the manifest, the
comms/inbox/archive, the encyclopaedia and the statistics screens all *are*.

### `icSPPlayerBaseScreen` is an overlay manager, not a screen

It derives from `iiGUIOverlayManager` (`FcRegistry::RegisterClass` at
`0x10023710`), and its constructor (`0x10024000`) builds a hash map of the screens
it hosts -- `icSPBaseScreen` -> 0, `icSPHangarScreen` -> 3, `icSPLoadoutScreen`
-> ... -- against a diorama index, alongside the base's backdrop URLs
(`main_bay_url`, `office_interior_url`, `jafs_url`, `smith_url`, `gunbabes_url`,
`fritz_delay`, `diorama_delay`). It hosts the base menu; it is not the menu.

**No POG script ever pushes `icSPBaseScreen`** -- yet every Back button in
`ibasegui` unwinds with `gui.RemoveOverlaysAfter("icSPBaseScreen")` (17 sites) and
`iact0generaltraining.pog:20` tests `"icSPBaseScreen" == gui.CurrentScreenClassname()`.
It can only be on the overlay stack because the manager put it there. That last
step is an inference, not a read instruction, but nothing else can put it there.

### The nine input-override slots

`gui.SetInputOverrideFunctions(window, s1..s9)` writes
`FcWindow+0xa0 .. +0xc0` (`FcWindow::SetInputOverrideFunctions`, `flux @
0x10094090`). The slots are `FcWindowManager::eInputMessages`, and the indices are
read straight off the handlers, each of which asks
`FcWindowManager::InputMessageOverrideFunction(window, <n>)` (`0x10097550`, a jump
into a table of accessors):

| slot | message | handler |
|---|---|---|
| 0 | Left | `FcWindow::OnControlFocusLeft` `0x100941f0` |
| 1 | Up | `0x10094270` |
| 2 | Right | `0x100943a0` |
| 3 | Down | `0x10094420` |
| 4 | **Select** | `0x10094530` |
| 5 | Cancel | -- |
| 6 | LeftMouseDown | `0x10094b40` |
| 7 | **LeftMouseUp** | `0x10094bb0` |
| 8 | LeftMouseDownHeld | `0x10094c20` |

**Slot 5 is dead in the original.** `FcWindow::OnControlFocusCancel`
(`0x10094720`) never consults the table: it walks up to the parent and, failing
that, calls the window manager's single global cancel function -- which is what
`gui.SetControlFocusCancelFunction` sets. Every base screen sets both, to the same
POG function, so honouring only the global one loses nothing. Slots 4 and 7 are
the pair that matter (keyboard select and mouse click), and `ibasegui` always
wires them to the same function.

### `gui.ListBoxFocusedEntry` returns an int, not the entry

`FcListBox::FocusedEntry` (`flux @ 0x100870d0`) is `return *(int *)(this + 0xdc)`,
and `SetFocusedEntry` (`0x100870e0`) takes an int. `ibasegui` reads it as a row
number and indexes a *parallel list* with it:

```
global.CreateList("InventoryScreen_CargoList", 2, v1);
iinventory.FillInventoryListBox(v4, !v0, v1);   <- the same v1
...
v0 = gui.ListBoxFocusedEntry(v1);               <- a row number
v8 = icargo.Cast(list.GetNth(v7, v0));          <- back to the cargo
```

That is why `iinventory.Fill*ListBox` and `iemail.FillArchivedEmailListBox` are
*natives*: they fill the list box **and** the script's list, and the two orders
have to agree.

---

## 8b. Two bugs that cancel, and must be fixed together

Found while implementing the base screens. **Neither is fixed**, because fixing
either one alone breaks the campaign. They are recorded here in full so that
whoever fixes them fixes both.

**Bug 1 -- `global.Create*` reads the wrong argument.** The signature is
`Create<T>(name, flag, value)`: all seven are `argc=3`, and the value is the
**third** argument. The middle one is the save-game persistence scope (`1`, `2`,
`14`).

```
global.CreateInt("GUI_inversebutton_height", 14, 16)   ; igui then passes
global.Int("GUI_inversebutton_height") as a button's height -- so 16 is the value
global.CreateBool("Hangar_Flashing", 2, 1)             ; 2 is not a bool
global.CreateInt("g_current_act", 2, -1)               ; and ijafsscript.pog:1379
tests `-1 == global.Int("g_current_act")` -- so -1 is the value
```

`natives/std.gd::_create` stores `a[1]`, the flag. Every global in the game
therefore holds a `1`, `2` or `14` instead of its value: harmless for the bools by
luck, fatal for the handles and lists, whose `Cast` then fails and whose screens
silently do nothing.

**Bug 2 -- the comparison operators have their operands the wrong way round.**
`pogdis`/`pogdec` render `LessI` on the stack `[a, b]` as `a < b`, `pogport` emits
that, and `vm.gd` computes it the same way (`OP_LESS_I: s[-1] < b`). The evidence
says it is `b < a`:

- `iprelude.JunkyardHandler` is an **Act 0** task. Its `every 1 seconds` loop
  begins `if (0 > global.Int("g_current_act")) { sim.Destroy(v4); ... return; }` --
  its tear-down test. As rendered that means "act == -1", which is the *initial*
  state, so the task would destroy itself on its first tick. It only makes sense
  as `act > 0`: "the campaign has left Act 0".
- The act gates line up only under the same reading: `iactone.pog:985`
  `if (1 < act) { SetInt("g_current_act", 1); ...}` is "if act **<** 1, start Act
  One", and `iactthree.pog:1655` likewise for 3.

**How they cancel.** `istartsystem.pog:329` does
`global.CreateInt("g_current_act", 2, -1)`. Bug 1 stores `2` instead of `-1`;
`iprelude.Main`'s gate `if (0 < global.Int("g_current_act"))` then passes because
`0 < 2`, and the Act 0 prologue starts. Fix bug 1 alone and the global correctly
becomes `-1`, `0 < -1` is false, **and the campaign never starts**. Fix bug 2
alone and the same gate inverts against a value that is still wrong.

Bug 2 lives in `tools/iw2/pogdec.py`, `tools/iw2/pogport.py` and
`game/scripts/pog/vm.gd`, and fixing it means regenerating `pog/gen/*.gd`. It
affects ~2,180 comparison sites (1013 `LessI`, 344 `LessF`, 298 `GreaterI`, 218
`GreaterF`, plus the `*Equal*` forms), so it is much the larger of the two.

---

## 8c. The HUD sprite atlas, and what the status icons really are

Two things an earlier pass got wrong, both because they were inferred rather
than read.

### The sprite table is not in the file, but its *builder* is

`FUN_100e9de0(x, y, sprite, flags, rot)` indexes a table at `DAT_101741b0`,
stride `0x24`. That address is in `.data` **past the raw-data end** (`.data` is
raw-backed only to `0x10165000`), so it is BSS: it reads as garbage from the PE,
which is why the last pass concluded "populated at runtime, not recoverable".

It *is* recoverable. The table is filled entry by entry by a static initialiser
at **`0x100e6c60` .. `0x100e7f90`**, which Ghidra left undisassembled (the same
failure as the Lagrange draw). Every entry is one call to the record ctor

```
FUN_100ee6b0(this, atlas_x, atlas_y, w, h, origin_x, origin_y, texture)
    +0x00 w   +0x04 h   +0x08 origin_x   +0x0c origin_y
    +0x10 u0 = atlas_x / 256          (_DAT_1011dc78 = 1/256)
    +0x14 v0 = atlas_y / 256
    +0x18 u1 = (atlas_x + w) / 256
    +0x1c v1 = (atlas_y + h) / 256
    +0x20 texture index
```

followed by `mov edi, <table entry>; rep movsd` (9 dwords). Walking those pairs
recovers all **95 sprites (0..94)** exactly. The four textures are the pointer
list at `0x10162c9c`:

    0 = images/hud/sprites    1 = images/hud/lcd
    2 = images/hud/reticle    3 = images/hud/tri

The ones the HUD uses are now in `hud.gd`'s `SPR` / `SPR_RET` tables, with the
atlas cell for each. Highlights: **20** = the charge pip (11x11 at 68,0);
**0x15-0x18** = the four mode icons; **0x19** = the LDS drive capsule; **0x1A**
= the "!"; **0x1B** = a power symbol; **0x1E** = the capsule-drive star;
**0x3E / 0x3F / 0x40** = thermometer / lightning / bulb; **0x4E** = a missile;
**0x56-0x59** = alpha / beta / flag / bomb (multiplayer); **50** = a sweep
wedge; **51 / 52 / 53** = the three roundel backings; **90** = the reticle ring;
**91** and **93** = the menu reticle's quadrants.

### `FUN_100ea2b0`'s fourth argument is a flag word, not a size

The previous pass read the reticle's per-icon `9` / `0xb` / `0xd` as a **size**.
It is not. `FUN_100ea2b0(x, y, sprite, flags, a, b)` is:

```
bit0 | bit3  -> draw roundel sprite 53 (ring + disc) under the glyph
bit0 alone   -> roundel 51 (soft disc)
bit3 alone   -> roundel 52 (ring)
bit1         -> draw sprite 50, a wedge, rotated -2*PI * frac(t)    (1 rev/s)
bit2         -> pulse: alpha = (|frac(t/2) - 0.5| * 1.8 + 0.1) * alpha
                (_DAT_1011dc58 = 1.8, _DAT_101184b0 = 0.1; 2 s period)
then         -> draw the glyph itself, at its NATIVE atlas size (never scaled)
```

So `9 = 0b1001` is a plain roundel, `11 = 0b1011` is a roundel with a spinning
sweep, and `13 = 0b1101` is a roundel that pulses. **Every status icon sits on a
32x32 roundel.** That is where the "disc" in the reference screenshot comes
from: it was never invented, it is sprite 53.

### The icon ring: `FUN_100f5a90` (ctor) and `FUN_100f8410` (draw)

The ctor builds 15 icons via
`FUN_100f93c0(angle_half_turns, radius_delta, sprite, colour, flags)`:

| slot | angle | r | sprite | colour | flags |
|---|---|---|---|---|---|
| 0-3 | -22.5, -33.75, -45, -56.25 | 150 | 0x15..0x18 | amber `DAT_10174fb0` | 11 |
| 4 | -22.5 | 110 | 0x19 | **green** `DAT_10176038` | 11 |
| 5 | -67.5 | 110 | 0x1B | amber | 13 |
| 6 | +22.5 | 110 | 0x1E | green | 11 |
| 7 | 180 | 110 | 0x3E | amber | 9 |
| 8 | 157.5 | 110 | 0x3F | amber | 9 |
| 9 | 135 | 110 | 0x40 | amber | 9 |
| 10 | +67.5 | 110 | 0x4E | **red** `DAT_10176018` | 9 |
| 11-12 | 202.5 | 110 | 0x56, 0x57 | green | 9 |
| 13-14 | 225 | 110 | 0x58, 0x59 | green | 13 |

(`-0.125` half-turns = -22.5 deg; the mode-icon step is `_DAT_101184a4` = 0.0625
and the gauge step is `_DAT_1011bdd0` = 0.125. radius = `_DAT_1011e034` (80) +
delta.)

Slots 0-3 are mutually exclusive, indexed through `DAT_1011e04c = [-1, 1, 0, 3,
2]` by `icPlayerPilot+0x308`: mode 0 lights none.

### The LDS-inhibit "!" -- what it actually is

It is **not** a separate element, and there is no hand-made disc, no arc and no
16-pip ring. It is **icon slot 4** with its sprite swapped. `FUN_100f8410`:

```
drive = ship+0x25c
if ship+0x251 == 0 and drive.state != 3:            # not inhibited
    state 1 (warming up): sprite 0x19, flags 13,
                          charge = 1 - WarmUpTimeRemaining / total
    state 2 (running):    sprite 0x19, flags 11, charge = 0
    otherwise:            hidden
else:                                                # inhibited or disrupted
    sprite 0x1A ("!"), flags 13
    charge = max( drive+0x98 / drive+0x9c,                       # disrupt countdown
                  1 - dist(ship, pilot+0xb8) / (pilot+0xb8)+0x30 )  # depth in the field
```

The draw **never touches the colour**, so the "!" keeps the ctor's
`DAT_10176038` = **(0.5, 1.0, 0.0) green**. It pulses (flags 13, bit 2). The ring
around it is the ordinary charge ring: `FUN_100f8da0` lights
`floor(charge * 24)` of **24** pips (`_DAT_1011e0bc`) on a circle of radius
**18** (`_DAT_101190bc`), clockwise from twelve, fading the next by the
remainder (skipped below 0.05, `_DAT_1011a198`). Same slot, same ring, same
green: LDS inhibition and an LDSi hit are the same indicator.

### The other slots

- **5** (0x1B, power symbol): lit when any ship component is non-functional. The
  `else` branch swaps in **0x1C or 0x1D** off the drive controller
  (`icShip+0x270`, vfunc `+0x40` returning a struct whose `+0xc` / `+0x10`
  floats and `+0x1c` int decide which). See Open questions.
- **6** (0x1E): the capsule drive charging (`ship+0x298`), *or* a targeted
  L-point within **50 km** (`_DAT_1011b344`) that has a destination -- in which
  case the destination's name is drawn beside the icon at `(+24, -line_height)`.
- **7-9**: three `{float value, bool flag}` records on `icPlayerPilot+0xe8`,
  stride 8. Each icon appears when its value **changes**, holds
  `DAT_1011e03c` = **2.0 s** after it settles, shows the value as a charge ring,
  and goes red + flags 13 when the flag is set (amber + flags 9 otherwise). What
  the three measure is an Open question; only the thermometer is driven.
- **10** (0x4E, red): lit when `icPlayerPilot+0x6c` is set; charge =
  `pilot+0xa8 * 1/24` (`_DAT_1011e0b8` = 0.0416667) -- **one pip per incoming
  missile**.
- **11-14**: multiplayer only (`mp_on_team_alpha`, `mp_on_team_beta`,
  `mp_has_opponent_flag`, `mp_has_bomb` object properties). Dead in the campaign.

---

## 8d. `icHUDMenuReticle` -- the arrow-key menu

Registered at `0x100f1b40` against `iiHUDOverlayElement`; factory `0x100f1b80`,
ctor `0x100f1ce0`, vtable `0x1011ded8`, **Draw = `0x100f1d60`** (another one
Ghidra skipped; disassembled by hand).

A menu node is 0x2c bytes: `+0x08` name (FcString), `+0x10` the **enabled** byte,
then four direction links. The direction order is proved by the offset table the
element builds at `0x100f1bf0` and which the draw indexes per link:

```
+0x14 UP    -> (   0, -100)        +0x1c LEFT  -> (-100,  0)
+0x18 DOWN  -> (   0, +100)        +0x20 RIGHT -> (+100,  0)
100 = _DAT_1011dec0 (80) + _DAT_101190b0 (20)
```

The centre is sprite **0x5B** (from `reticle.png`) plus **four** copies of sprite
**0x5D** stepped by `_DAT_1011a454` = PI/2, spinning together. The focus node's
name is drawn at the centre; the timeout is drawn below it only once it drops
under **10 s** (`_DAT_101190c0`), counting down from `flux.ini [icHUD]
menu_timeout = 30`.

### The tree (`FUN_100df640`), link for link

```
                          ENG (screen)
                               ^
        NAV  <------------  MENU  ------------>  WEP
         |                    |                   |
   UP    -> STARMAP (screen)  v             UP    -> ZOOM IN / ZOOM OUT
   LEFT  -> AUTOPILOT        CMD            DOWN  -> TOGGLE AIM ASSIST
   DOWN  -> UNDOCK            |             RIGHT -> TOGGLE FIRE MODE
                              |
              DOC <-- LEFT ---+--- RIGHT --> REM LINK / REM UNLINK
               |              v
   UP    -> LOG (screen)    COMMS
   LEFT  -> OBJECTIVES        |
   DOWN  -> STATISTICS   LEFT  -> T-FIGHTERS
                         RIGHT -> WINGMEN
                         DOWN  -> CALL JAFS   (ijafsscript.CallJafs)
```

The five **screens** attach themselves: the builder runs
`FcClass::InstanceIterator(<class>)` and wraps the live element in a node whose
name is the element's own `+0xc` string. Those classes are `DAT_10176300` =
`icHUDStarmap`, `DAT_101763ac` = `icHUDEngineering`, `DAT_10176078` =
`icHUDLog`, `DAT_10176140` = `icHUDObjectives`, `DAT_101762c8` = `icHUDScore`.

`ihud.CurrentMenuNode` is `IHUDMenuFocusName` (`0x100f5040`): it returns the
**open screen's** key if one is up (`hud_menu_map` / `hud_menu_eng` /
`hud_menu_log` / `hud_menu_objectives` / `hud_menu_score_table`), otherwise the
focused node's name. `ihud.SetMenuNodeEnabled` (`0x100f53e0`) finds the node by
name from the root and writes its `+0x10`. `ihud.LockMenu` (`0x100f51e0`) sets
`icHUD+0x1b6`, after which `FUN_100df610` forwards no menu input at all.

The keys are real, out of `configs/default.ini`:

```
[HUD.MenuLeft/Right/Up/Down]  arrows       [HUD.MenuSelect]  Return
[HUD.MenuCancel]  Backspace                [HUD.Objectives]  Shift+O
[HUD.Starmap]  Shift+M    [HUD.Log]  Shift+L
[HUD.Engineering]  Shift+E    [HUD.Statistics]  Shift+S
```

---

## 8e. `icHUDEngineering` and `icHUDStarmap`

Both derive from `iiHUDMenuElement` and share its Draw (`0x100f1400`, vtable
slot 9) -- **which Ghidra also left undisassembled and which we did not
reverse**. Their content hangs off later vtable slots (Engineering 13/14 =
`0x10105c80` / `0x10105d40`; Starmap 12..16).

What *is* read, from `icHUDEngineering`'s ctor `0x101059f0`:

- node name `hud_menu_eng`, caption `hud_menu_engineering` ("ENGINEERING")
- `+0x54` = the selected row, stepped 0..5 and wrapping at both ends
  (`FUN_10105c80`): **six rows**
- eleven localised strings from the key table at `0x10163e94`
  (`hud_engineering_ship`, `_iff`, `_back`, `_resettri`, `_powerhelp_part1/2`,
  `_general_enabled/disabled`, `_powerpod_enabled/disabled`)
- **`+0xc0`..`+0xd4` and `+0xdc`..`+0xe4`: nine floats, every one
  `0x3eaaaaab` = 1/3.** Three triples that each sum to 1 -- the TRI is a
  three-way split, starting even
- five floats parked after the vtable at `0x1011e348`: 70, 160, 35, 281, 275

The triangle art is the shipped `images/hud/tri.png` (texture 3), whose track
occupies (2,2)-(146,139): an inverted triangle with graduations and three corner
nodes, each carrying a glyph.

`icHUDStarmap`'s caption is `hud_map_caption` = "STELLAR NAVIGATION OVERLAY", and
`hud.csv` gives it both a **CLUSTER VIEW** and a **SYSTEM VIEW**, plus SELECTED /
ZOOM IN / ZOOM OUT / JUMP DESTINATION / SELECT DESTINATION / INTERSTELLAR
L-POINT / LOCAL L-POINT / MISSION WAYPOINTS / ROUTE. So both views exist. The
geography it draws is real (`data/json/systems/*.json`, `geography.md`); its
layout is not recovered.

---

## 8f. `icHUDShipStatus` is the top-centre strip

Registered against `iiHUDOverlayElement`; factory `0x100fab00`, ctor
`0x100fab60`, vtable `0x1011e148`, **Draw = `0x100fabd0`**, which computes
`x = screen_width * 0.5` and calls `FUN_100fac60(x, 14.0)`. `FUN_100fac60`
enumerates the ship's component list (`icShip+0x138`) and lays one bar per
component along a horizontal strip in chartreuse (`DAT_10176038`).

So the panel we already draw at top-centre *is* `icHUDShipStatus`: centred, at
**y = 14**, one bar per subsim.

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
| The base screens run the original POG builders, but are drawn in the remaster's own amber-on-black (`base_screens.gd`) | A skinned widget toolkit: `igui.CreateFancyButton` splices a 38-argument nine-patch atlas onto every control | The content and the control flow are the original's -- the rows, their order, and the POG function behind every one of them. Only the skin is ours, and the front end already is (`menu.gd`). |
| `natives/std.gd::_create` knowingly reads `global.Create*`'s persistence flag as its value | -- | It is a bug, and it is left in **on purpose**: it cancels a second bug in the ported comparison operators, and fixing either alone stops the campaign starting. See **8b**. |
| An approach **arrives** at the marker sphere: complete when `distance <= marker + max(min(marker*0.05, 0.5), 20)` | **Settles** on it: complete when `\|distance - marker\| < min(marker*0.05, 0.5)` | The break-off distance itself is exact (section 4a). Only the tolerance differs: the engine has a position controller that holds station to half a metre, ours flies a waypoint list and cannot. The floor is the engine's own `m_waypoint_approach_distance` (20 m), not a number we picked. |
| A station's `FiSim::Radius` is its avatar's bounding sphere, stamped when it streams in | The same -- the engine sizes every sim from its avatar | Not a divergence in kind, but worth stating: the station's *map record* carries no radius (its `+0x138` belongs to the parent body, see `geography.md`), so it has to come from the model, and **the approach marker depends on it**. Before this, every station reported radius 0 and the marker collapsed to the 20 m waypoint distance. |
| The mouse is a yoke: X yaws, Y pitches, the right button is `RollYawToggleHold`, and the zoom factor divides it | Bound **no** mouse axis to the pilot; flight is joystick or numpad, and the mouse drives the director's camera | A 2001 game could assume a joystick. The mouse carries the real yoke's two behaviours, so it is the same control on a different device. See `controls.md`. |

---

## 10. Open questions

Known gaps. **Do not fill these in with plausible values** -- find the answer.

### HUD (this pass)

- **What the three reticle gauges measure.** `icPlayerPilot+0xe8` holds three
  `{float value, bool flag}` records, drawn with a thermometer (0x3E), a
  lightning bolt (0x3F) and a light bulb (0x40). The thermometer is obviously
  heat and we drive it from `ship_heat()`. **The other two are UNKNOWN** and are
  therefore **not drawn**. Where `+0xe8` is written was not found. The
  change-then-hold-2s behaviour would fit the TRI allocations, but that is a
  guess and it is not implemented as one.
- **Slot 5's `0x1C` / `0x1D` branch.** When no ship component is broken, the
  draw reads `icShip+0x270` (a drive controller) through vfunc `+0x40` and picks
  sprite **0x1C** (a capsule with a circular arrow) when the returned struct's
  `+0xc` and `+0x10` floats are both zero *and* its `+0x1c` int is 1, else
  **0x1D** (a capsule with left/right arrows). What that struct is was not
  resolved, so **neither sprite is drawn** -- only the 0x1B "a system is down"
  case is.
- ~~**`icPlayerPilot+0x308`.**~~ **RESOLVED, and it needs a fix.** `+0x308` *is*
  the autopilot mode, by direct reading: `icPlayerPilot::SetAutopilot`
  (`0x100af930`) ends `*(eAutopilot *)(this + 0x308) = param_1`, `Autopilot()`
  (`0x10005370`) returns it and `AutopilotEngaged()` (`0x10005360`) is
  `+0x308 != 0`. No inference left.

  **But the enum is not ours.** The engine's is **0 Off, 1 Formate, 2 Approach,
  3 Dock, 4 MatchVelocity** (6 = RemotePilot); `main.gd`'s `ap_mode` is 0 off,
  **1 approach, 2 formate**, 3 dock, 4 match -- 1 and 2 are swapped. So
  `hud.gd`'s `AP_ICON = DAT_1011e04c = [-1, 1, 0, 3, 2]`, which is indexed by the
  *engine's* mode, currently lights the **formate** icon for an approach and vice
  versa. Either remap on read (`AP_ICON[[0,2,1,3,4][ap_mode]]`) or renumber
  `ap_mode` to the engine's enum -- but `hud.gd:917` also *writes* `ap_mode` from
  the HUD menu, so both ends have to move together. Left for the HUD owner;
  `main.gd` keeps its own numbering so nothing changes under `hud.gd`'s feet.
- **The incoming-missile icon (0x4E) has no source in our sim.** Nothing ever
  locks a missile on the player, so slot 10 never lights. The engine's rule is
  known (`pilot+0x6c` set; one pip per missile from `pilot+0xa8`).
- **`iiHUDMenuElement::Draw` (`0x100f1400`)** -- the shared frame every
  full-screen HUD element is drawn inside. Ghidra left it undisassembled and we
  did not reverse it, so the caption row and body inset in `hud_screens.gd` are
  **ours**.
- **The TRI's three axes.** Nine floats, all 1/3, are provably a three-way split,
  and `tri.png` provably has three corners -- but **which corner is which system
  is UNKNOWN**. `hud_screens.gd` labels them POWER / REPAIR / HEAT and says so.
  The five floats after the Engineering vtable (70, 160, 35, 281, 275) are
  almost certainly its pixel geometry, but nothing proves the assignment.
- **The starmap's projection, scale and layout.** Vtable slots 12..16 were not
  reversed. The geography is real; the map drawing is ours.
- **The three carousel submenus** (AUTOPILOT, WINGMEN, T-FIGHTERS). Each really
  holds a PREV and a NEXT node plus a list of commands, but the builders
  (`FUN_100efe50` / `FUN_100f0560` / `FUN_100f0c40`) put them in *private* slots
  (`+0x40`..`+0x58`), not in the four direction links, and the virtual that maps
  them onto the links was not read. **Which direction is prev and which is next
  is UNKNOWN**; we use left/right.
- **`hud_menu_doc`** has no entry in `hud.csv` or `hud_addendum.csv`. The node
  exists in the tree and the scripts can address it; its **display label is
  ours** ("DOC").
- **`ihud.FlashElement`** maps a script-supplied name onto a HUD element to
  flash (`FUN_100df3e0`, timing from `flux.ini [icHUD] flash_delay = 6`,
  `flash_frequency = 3`). Which names the scripts pass, and how they resolve to
  elements, was not recovered -- it stays a no-op.
- **The reticle ring's own sprite.** Sprite 90 is 170x170 with origin (84,84),
  i.e. radius ~85, but `_DAT_1011e038` says the ring radius is **63** and the
  reference screenshot measures 63.4. The engine must scale it; how was not
  found, so `hud.gd` still draws the ring as vectors at r = 63.

- **The two cancelling bugs in section 8b** are the most valuable thing on this
  list. `global.Create*` reads the wrong argument, and the ported `<`/`>` have
  their operands reversed. Both are diagnosed; neither is fixed, because fixing
  one alone breaks the boot. The comparison half needs `pogdec.py`, `pogport.py`
  and `vm.gd` changed together and `pog/gen/*.gd` regenerated.
- **`IeBodyType`.** `ibody.Type` is compared against **5** and **7**
  (`iscriptedorders.pog:517`, `:1853`) and no field in the map record produces
  either: `body_type` (`+0x134`) holds only 2/3/4/6, `planet_type` (`+0x13C`) only
  1/2. `icPlanet::Type` is a bare field read, so the binary does not say where the
  loader filled it from. 6 call sites; left stubbed.
- **What the contact list's membership rule actually is.** `icPlayerContactList`
  (`0x100aabe0`) is recovered as far as *sorting* (`CompareByRange`, `0x100ac190`)
  and the `iiSim::VisibleToSensor` (`0x100013b0`) gate, but the **range** at which
  a sim enters the list is not: `Add` (`0x100ac1c0`) carries no distance test, so
  the cutoff is upstream in the sensor sweep (`Update`, `0x100aad20`) and we did
  not follow it. Our list keeps its own ranges (stations 500 km, L-points
  10 000 km, ships unlimited) and they are **ours, not the game's**.
- **`icAIServices::InnerMarkerRadius`'s category `0x1f` branch.** A target whose
  `sim+0x194` is `0x1f` gets a marker of **0**. The category enum is the same one
  `icBullet` uses to pick `asteroid_impact` (`0xb` / `0xe`), and it is still not
  named -- so which sims those are is known by number, not by kind.
- **`icAIDockAgent`.** The dock autopilot is *not* the approach autopilot with a
  smaller radius: `EngageAutopilotDock` (`0x100afe80`) builds a `cData` with a
  target sim and **no radius at all**, and `icAIDockAgent` (`0x10050aa0`) flies it
  to a docking port. We did not read the agent, so our dock keeps its 4 km
  `DOCK_RANGE` hard-dock. The break-off is right; the approach path is not read.
- **The HUD menu tree.** `ihud.CurrentMenuNode` returns a *node name*
  ("hud_menu_eng", "hud_menu_wep", "hud_menu_nav" ...) and `SetMenuNodeEnabled`
  (70 call sites) locks the player out of a system until it has been taught. That
  is `icHUDMenuReticle` from `flux.ini [icHUD]`, and we never built it, so the
  whole of `iact0generaltraining`'s menu tour has nothing to walk. The node names
  are in the scripts; the tree's shape is not.
- **The sense of the yoke axes.** The *bindings* are recovered (see below and
  `controls.md`), and `icPlayerPilot::HandleLinearMessage` (`0x100ae2b0`) says
  which yoke slot each axis drives. What is **not** read out of the binary is the
  sign convention: whether `+Pitch` is nose-up or nose-down at the point the yoke
  reaches `iiThrusterSim`. We take it as **nose-down**, on the chain
  `[icPlayerPilot.Pitch] Joystick1, JoyYAxis, inverse` -> an inverted DirectInput
  Y is positive when the stick is pushed forward -> forward stick is nose-down;
  `keyboard_only.ini` then binds NumPad8 to the same positive half. Every step is
  sourced, but the last one is an inference from convention, not a read
  instruction. Yaw and roll are self-consistent either way and were already right.
- **The C++ base screens.** `icSPComputerTradingScreen`, `icSPAddCargoScreen` and
  `icSPComputerPuzzleScreen` have no POG builder -- they were laid out in C++, and
  their window trees are in `iwar2.dll` rather than in any script. Trading itself
  (`itrade`, 15 natives) is fully implemented and driven by the scripts; it is
  only the *screen* that is missing.
- **The alien infection.** `isim.AlienInfectionEffect` / `SetAlienInfectionDamage`
  / `IsAlienInfectionEffectOn` (30 call sites, all Act 3) put a spreading crust on
  an infected hull with a damage-over-time behind it. Neither the shader nor the
  damage rate is read.

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
