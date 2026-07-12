# Decompiling the IW2 engine binaries

Everything that is *data* lives in `resource.zip` and is recovered by the
extraction pipeline (`docs/formats.md`). Everything that is *behaviour*
lives in the engine binaries: HUD presentation (the `icHUD*` classes),
the flight model's hidden constants, subsim damage rules, the sensor and
LDS-inhibition model. `flux.ini` only exposes the handful of knobs the
developers chose to expose; the rest is compiled C++.

This is the last big extraction frontier — without it, every HUD/feel
detail is reference-driven guesswork against screenshots.

## Setup (one-off)

- **JDK 21**: `winget install Microsoft.OpenJDK.21`
- **Ghidra** (not in winget): download the latest `*_PUBLIC_*.zip` from
  the GitHub releases API and unzip to `build/ghidra/`. See
  `tools/ghidra/decompile.ps1` for the exact paths it expects.

Both live under `build/` and are gitignored.

## Running

```powershell
powershell -File tools/ghidra/decompile.ps1 -Binaries @('iwar2.dll','flux.dll','gui.dll','EdgeOfChaos.exe')
```

Output (gitignored, like every other derived asset):

- `data/decomp/<binary>.c` — decompiled C for every function
- `data/decomp/<binary>.symbols.txt` — address / name / size index

**Gotcha:** Ghidra's `analyzeHeadless.bat` breaks on paths containing
parentheses, and the GOG install is under `Program Files (x86)`. The
script stages each binary into `build/bin/` first.

## The binaries

| binary | size | what's in it |
|--------|------|--------------|
| `EdgeOfChaos.exe` | 3.4 MB | entry point, top-level game loop |
| `iwar2.dll` | 1.5 MB | the game classes — `icShip`, `icHUD*`, `icCannon`, subsims |
| `flux.dll` | 1.4 MB | the Flux engine framework (sim/avatar/resource layer) |
| `gui.dll` | 73 KB | window/control widgets used by the front end |
| `ihud.dll` | 20 KB | just the POG→HUD API bindings, not the implementation |

The `ic*` class names from `flux.ini` (`icHUDOrbRadar`,
`icInternalCamera`, `icPlayerPilot`...) are the search handles: RTTI and
the INI-parsing code give the class → code mapping, and the INI key
strings ("use_thick_stalks", "field_of_view") appear as string literals
right next to the code that consumes them.

## What to mine, in order

1. **HUD presentation** (`icHUD*`): the inhibit roundel's real
   composition and pip semantics, ORB stalk/blob drawing, reticle
   layout, the `images/hud/sprites.png` atlas cell → icon mapping.
2. **Flight model**: constants not in the INIs (assist trim rates,
   thruster response, the LDS acceleration curve).
3. **LDS inhibition**: the actual zone-radius rule (we currently
   approximate it: 25 km stations, body radius × 1.2).
4. **Subsim damage**: how hit points, armour and power/heat interact.

## Findings so far

**The binaries kept their C++ symbols.** Ghidra recovers full mangled
names — class, method, parameter types (`?BreakShipOutOfLDS@icLDSDrive@@AAEXXZ`).
This is enormously better than a stripped binary: the classes named in
`flux.ini` map straight to code.

Totals: `iwar2.dll` 5,355 functions, `flux.dll` 5,606, `gui.dll` 150,
`EdgeOfChaos.exe` 656 (a thin launcher — the game lives in the DLLs).

### LDS dropout (`icLDSDrive::BreakShipOutOfLDS`)
On dropout the engine **zeroes angular velocity** and sets linear
velocity to **facing × 1000 m/s flat** — not the drive's max speed
(which is what we assumed). It then cues the director (event 0xe).

### LDS inhibition is REGION-based, not radius-derived
`iiThrusterSim` keeps an **inhibition counter** at `+0x251`
(`EnterLDSInhibitRegion` increments, `Leave` decrements; `IsLDSInhibited`
is just `counter != 0`). Regions are explicit `icLDSIRegion` objects
constructed from a **centre (double vector) + radius (float)** — created
by geography and by scripts (`iRegion.CreateLDSI` in POG). So our
"compute an inhibition radius from the body radius" model is wrong in
kind; inhibition zones are authored objects.

`icPlayerPilot` caches the region the player is inside at `+0xb8` —
which is exactly what the HUD needs to draw the boundary/pip state.

### LDS obstacle avoidance (`icAITarget::CheckLDSAvoidance`)
Avoidance radius for a body =
`(icPlanet::HeatDistanceAsRadiusMultiplier() + 1.1) × FiSim::Radius()`.

### The HUD element classes (all in `iwar2.dll`)
`icHUDBrackets`, `icHUDClock`, `icHUDContactList`, `icHUDContrails`,
`icHUDDebug`, `icHUDEditBoxElement`, `icHUDEngineering`,
`icHUDLagrangeIcon`, `icHUDLog`, `icHUDMenuReticle`, `icHUDMessage`,
`icHUDObjectives`, `icHUDOrbRadar`, `icHUDReferenceGrid`,
`icHUDReticle`, `icHUDScore`, `icHUDShields`, `icHUDShipStatus`,
`icHUDStarmap`, `icHUDTargetMFD`, `icHUDWaypointIcon`, `icHUDWeapons`.

That list is itself a spec: it names every element the original HUD had
(note `icHUDContrails` — the velocity trails; `icHUDReferenceGrid` — the
motion grid; `icHUDShields`, `icHUDEngineering`, `icHUDStarmap` — screens
we have not built yet).

### The POG interpreter (`FcScriptTask::Execute`)

The single most valuable function in either binary: it is the VM the whole
game's content logic runs on, and reading it let us build `game/scripts/pog/`
(see `docs/pog.md`). Three things it settled that guesswork had wrong:

- **`0x16`/`0x19` are `CallNative`/`StartNative`.** The compiler emits `Call`
  (0x15) for *every* import with operands `0 0 argc`; the loader patches the
  operands from the FIMP call-site tables and rewrites the opcode when the
  import resolves to a DLL package. That is why shipped bytecode only ever
  contains 0x15/0x18.
- **`TimedJump` is a rate limiter, not a sleep.** `if now - local[slot] <=
  interval: goto target; else: local[slot] = now`. So `EndTimeslice;
  TimedJump L,slot,1.0` is POG's "poll this every second while yielding every
  frame".
- **A suspended task stops at the next *instruction*, not the next yield.**
  The interpreter re-tests runnability after every opcode. Without that,
  `iconversation`'s `while (!done) task.Sleep(Current(), 0.5)` -- which never
  yields explicitly -- spins forever.

`0x33`-`0x36` are the bitwise ops, and `0x43`/`0x44` are atomic-region
begin/end (they suspend the 64-instruction preemption check), not debug
markers. `0x45` (`DebugSkip`) is how `debug` statements cost nothing in
release: the engine takes the jump unless `FcDeveloperMode` is on.

## Method note

Optimized 2001-era C++ decompiles to dense pointer arithmetic; do not
expect readable code. The productive pattern is targeted: grep the
symbol index and the string literals for a known name (an INI key, a
localisation key, a class name), read only the functions around it, and
extract the *constants and ordering* — not the whole implementation.
