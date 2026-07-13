# IW2 Remaster

A remaster of **Independence War 2: Edge of Chaos** (Particle Systems, 2001)
in a modern engine, preserving the original's look & feel — Newtonian 6-DOF
flight, the component/subsim ship model, and the Badlands cluster — while
aiming at an open-world "EVE-but-flyable" experience.

Original game assets are copyrighted (Particle Systems / Atari SA lineage).
This repo contains **only tools and original code**: all game data is
extracted locally from the user's own GOG install at build time and is never
committed (see `.gitignore`). Distribution model: bring-your-own-copy
importer, pending any rights discussion with Atari.

## Layout

- `tools/iw2/` — Python extraction toolchain (run from repo root):
  - `resources.py` — layered VFS over `resource.zip` + loose `resource/`
    overrides, resolves Flux `ini:/`, `lws:/`, `map:/` references
  - `ini_parser.py` — Flux-flavored INI (arrays via `key[n]=`, vectors,
    trailing `;` comments)
  - `extract_sims.py` — ships/stations/subsims/weapons → `data/json/*.json`
  - `map_decoder.py` — binary `geog/*.map` star systems → `data/json/systems/`
    (format documented in the module docstring; reverse-engineered here)
  - `textures.py` — `.ftc`/`.ftu` → PNG via Pillow's FTEX plugin
- `data/` — generated output (gitignored)
- `docs/` — format notes and design docs

## Setup

```powershell
python -m venv .venv
.venv\Scripts\python -m pip install pillow
$env:IW2_GAME_DIR = "C:\...\Independence War 2"   # if not the GOG default
.venv\Scripts\python -m tools.iw2.extract_sims
.venv\Scripts\python -m tools.iw2.map_decoder
.venv\Scripts\python -m tools.iw2.textures
```

## Key sources

- Game data formats: mostly INI + LightWave (LWO/LWS) + FTEX; only `.map`
  (star systems) and `.pkg`/`.pso` (compiled POG scripts) needed reverse
  engineering.
- [i-war2.com](https://i-war2.com) — community hub: POG Scripting SDK 0.91,
  Graphic SDK, disassembled `.pkg` sources (ZeroPipeline), Torn Stars mod.
- Pillow's `FtexImagePlugin` decodes the texture format (originally
  contributed to Pillow by this project's owner).
- Prior art: IronDuke's Unity remake attempt (2016, stalled) —
  [forum thread](https://www.i-war2.com/forum/general-i-war-talk/3233-ironduke-s-i-war2-remake-i-war3).

## Status

1. ✅ Extraction toolchain (`python -m tools.iw2.extract_all`): ships,
   stations, subsims, star maps, textures, **PSO meshes → glTF** (format
   reverse-engineered here, 890/890), LWS scenes, avatar assembly (212
   setups with LODs, hardpoints, nested scenes)
2. ✅ **Engine: Godot 4** (agent-drivable text formats, MIT license,
   Forward+). Prototype in `game/`: assisted-Newtonian flight with original
   INI constants (validated), streaming 64-bit world, full Hoffer's Wake
   navigable, **LDS travel with real drive constants + LDSI dropout**,
   targeting HUD. Run: `godot --path game`; automated flight test:
   `godot --path game -- --demo`
3. ✅ The game runs its own content: all 114 POG packages ported to
   GDScript and verified against their bytecode (`pogverify`), campaign
   Act 0 end-to-end, docking, PBC + the full missile system, subsim
   damage/heat model, mission checkpoints, the original HUD (target MFD,
   TRI, starmap, hat-menu) — every constant extracted from the binaries
   (`docs/original.md` is the evidence log; `featurecov`/`apicov` measure
   what is honestly built vs stubbed)
4. Next (`featurecov --todo` is the authoritative list): turrets and beam
   weapons, capsule-space jump tunnel, asteroid/debris fields, act 3
   aliens, remaining base screens (trading, puzzle, customise), Acts 1-3
   mission authoring
