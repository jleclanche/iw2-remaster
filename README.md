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
3. ✅ The game runs its own content, and the systems under it are the
   original's. All 114 POG packages ported to GDScript and **provably
   agreeing with their bytecode** (`pogverify`: 2878/2878, nothing
   invented). Combat: subsim damage, heat, missiles/mines/countermeasures,
   turrets and beams. Flight: LDS, autopilots, **capsule space** (a real
   mini-world, not a fade). World: asteroid/debris fields, act-3 aliens
   and infection. UI: the original HUD (target MFD, reticle, TRI, starmap,
   hat-menu) and the POG-driven base screens (trading, loadout, customise,
   the triangulation puzzle). Every constant is extracted from the
   binaries — `docs/original.md` is the evidence log, and
   `featurecov`/`apicov` measure what is honestly built vs stubbed rather
   than asserting it in prose.

   Coverage: **666/829 natives (98% of call sites, 0 unbound)**,
   **70/384 engine classes built with 8 genuine gaps left**, gameplay
   assertions `--mechcheck` 20/20 · `--campcheck` · `--jumpcheck`.
4. Next: Acts 1–3 mission authoring (the bytecode is the source — use
   `pogsummary`), then the remaster proper. `featurecov --todo` is the
   authoritative list of what the engine has that we do not: the
   turret-fighter hull, remote missile, slug thrower, and five cosmetic
   avatars.
