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

## Method note

Optimized 2001-era C++ decompiles to dense pointer arithmetic; do not
expect readable code. The productive pattern is targeted: grep the
symbol index and the string literals for a known name (an INI key, a
localisation key, a class name), read only the functions around it, and
extract the *constants and ordering* — not the whole implementation.
