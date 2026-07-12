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

## Roadmap

1. ✅ Extraction toolchain (ships, stations, subsims, star maps, textures)
2. Models: LWO → glTF pipeline (Blender headless import or python lwo parser)
3. POG script recovery (SDK sources + ZeroPipeline disassembly) for
   mechanics: traffic, docking, factions, mission generator
4. Engine prototype: 6-DOF Newtonian flight with original INI tuning values,
   one system (Hoffer's Wake), LDS travel, docking
5. Full Badlands/Gagarin cluster import
