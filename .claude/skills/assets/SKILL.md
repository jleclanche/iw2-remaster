---
name: assets
description: Navigate the IW2 data pipeline — resources, textures, models, geog scenes, systems, localisation — and know which converted artifact the game actually loads. Use when tracing where an asset comes from or why it looks wrong.
---

# Asset pipeline map

All under `data/` (generated from the GOG install, gitignored — never
commit). Python tools run from repo root:
`<python> -m tools.iw2.<tool>` with
`<python>` = `C:\Users\jerom\AppData\Local\Programs\Python\Python312\python.exe`.

## Original resources

- `tools/iw2/resources.py` `ResourceFS` — unified view of `resource.zip` +
  loose `resource/` overrides. `fs.list("", ".ftc")`, `fs.read_bytes(path)`.
- Textures: `.ftc` (DXT — the ONLY variant the engine loads; dx7graph
  registers `ftc;iff;lbm` @ 0x1001b700) and `.ftu` (uncompressed authoring
  leftover, often cleaner but sometimes differs — hud/sprites.ftu has a
  baked pedestal the .ftc lacks). `tools/iw2/textures.py` prefers .ftc,
  keeps .ftu only where no .ftc exists → `data/textures/**/*.png`.
- Models: `.pso` (compiled avatar mesh) + `setup.lws` (avatar rig) under
  `avatars/`; standalone `.pso` under `models/`.

## Conversion chain (who reads what)

```
resource.zip ── textures.py ──► data/textures/**/*.png
             ── export_gltf.py ► data/gltf/models/*.gltf (+ .bin)
                                 (textures resolved BY STEM from
                                  data/textures — re-running textures.py
                                  with different .ftc/.ftu preference
                                  silently changes what GLTFs show)
geog/*.lws ──► data/json/scenes/geog/<cluster>/<stem>.json
               (nodes: icNebulaAvatar url=model||models|<stem>,
                icStarfieldAvatar counts/tint, <star>/<fill> DISTANT
                lights, lens-flare lights)
*.map ──────► data/json/systems/<stem>.json (bodies, L-points, belts;
               format doc in tools/iw2/map_decoder.py)
```

- Runtime loading: `main_state.gd _load_gltf` (GLTFDocument at runtime,
  cached; no import-time VRAM recompression — textures stay RGB8).
- System stems for Act 0: `hoffers_wake` (note the underscore; clusters
  are `badlands`, `gagarin`, `multiplayer`).

## Names and text

- Localised names: `text/*.csv` via `Properties.name` ids.
- Encyclopedia/fiction: `html/` + `text/act_*/`.

## Gotchas

- A `.map`/geog stem is not the display name — grep
  `data/json/systems/*.json` `"name"` fields.
- `resource/` loose files override `resource.zip` — check both before
  concluding a file "doesn't exist".
- PNGs in `data/textures` may predate the current textures.py preference
  order; byte-compare against both .ftc and .ftu before blaming a source.
