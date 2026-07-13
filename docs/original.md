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
get at the binaries), `formats.md` (the file formats).

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

### Stars are NOT flat-shaded spheres
Assets (all present, and we already extract them):

| asset | what it is |
|---|---|
| `images/planets/sun_yellow.ftc`, `sun_red.ftc`, `sun_blue.ftc` | the star's **surface** texture: a tiling plasma |
| `images/planets/sun_halo.ftc` | one **quadrant** of a spiky corona, white on black -- mirrored 4x and drawn additively |
| `images/sfx/sun.ftc`, `images/sfx/lens_flares.ftc` | sun sprite and lens flares |

A star is a textured, emissive body plus an additive corona -- not a coloured
sphere.

### Planets: `data/ini/planets.ini` is the renderer's config

```
planet_models[]            = avatars/planets/Planet_LOD2 / LOD1 / LOD0
detail_switch[]            = 0.03, 0.2, 0.9          (LOD thresholds)
rocky_planet_textures[]    = Terrain1..4, LandWater1/2/4, Cracks
gassy_planet_textures[]    = Stripes1..6, gas1..4
atmosphere_planet_textures[] = clouds1..4  (+ matching *_bump)
atmosphere_height          = 1.1
atmosphere_threshold       = 0.1     ; below this pressure, no atmosphere
max_rings                  = 8
rings_prob                 = 1.0
colours[]                  = ...     ; "Colours for when colours can't be worked out"
```

Note the comment on `colours[]`: it is the **fallback** table, used when the real
colour cannot be derived. Anything reading it as *the* planet colour is using the
game's last resort as its first.

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

---

## 10. Open questions

Known gaps. **Do not fill these in with plausible values** -- find the answer.

- **`IeSimType`**: only `T_CommandSection = 131072` is confirmed. The rest of the
  bit flags are unknown; our table has placeholders and says so.
- **Body radii.** The map record's `+311` float is a *map zone* radius, not a
  physical size -- for `Hoffer's Wake Alpha` it comes out as 1.75e11 m (1.17 AU),
  which is an orbital distance. Our extractor clamps it to an arbitrary `8e7`.
  The real body radius must be somewhere else in the geography; we have not found
  it. Until we do, every planet and star is the wrong size.
- **Which sun texture a given star uses** (`sun_yellow` / `sun_red` /
  `sun_blue`), and where the star's colour/class comes from.
- **`icHUDLagrangeIcon` / `icHUDReferenceGrid` draw code** -- the funnel's
  geometry, colours and the grid's cell size. Being extracted now.
- **HUD colour palette** -- the actual RGB constants, and the per-state colours
  (hostile/friendly/neutral).
- **Subsim damage model** -- how hit points, armour, power and heat interact.
- **The `gui` widget toolkit** (99 natives) -- the base screens (trade,
  manufacturing, recycling) are POG scripts driving it; we replaced the front end,
  so most of it is stubbed.
