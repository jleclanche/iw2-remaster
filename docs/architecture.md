# Port architecture — where everything lives

Navigational map of `game/` for anyone (human or agent) landing in this repo.
Rule of thumb everywhere: **extract, don't guess** — every constant traces to a
binary address, an INI, an LWS null, a localisation string or POG bytecode.
The evidence logs are `docs/original.md` and its companions; this file is only
the map of *our* code.

## The one game node: main.gd's linear extends chain

The Badlands is ONE Godot node whose script is split by topic into a linear
`extends` chain (scheme comment: `game/scripts/main_state.gd:1-8`). Same
object, same class: every var/func is a member of the same node, so
`main.<member>` works from every other script. A layer may reference members
of its own level or below, **never above**.

| layer (bottom → top) | topic |
|---|---|
| `main_state.gd` | constants, shared state, small pure helpers |
| `main_targeting.gd` | targeting, contacts, sensors, autopilot switches |
| `main_camera.gd` | the icDirector camera rig (F1–F4, chase, capsule) |
| `main_flight.gd` | player damage, the LDS drive, towing, docking |
| `main_collision.gd` | collision spheres + station CollisionHull trimeshes |
| `main_world.gd` | environment, sky, system loading, planets, streaming |
| `main_combat.gd` | bolts, kills, shockwaves, secondary weapons, zoom gate |
| `main_travel.gd` | capsule jump machine, the autopilot |
| `main_flow.gd` | boot (istartsystem stage walk), campaign, fitting, save/load, movies, debug start |
| `main.gd` | scene-root script: `_ready`, input, per-frame drive |

## The POG dual runtime (game/scripts/pog/)

IW2's content logic (missions, conversations, AI orders, trading, GUI) is POG
bytecode in resource.zip. We RUN the originals — never re-author missions.

- `vm.gd` — the POG VM: `FcScriptTask::Execute` (flux @ 0x1003b190)
  transcribed; runs the original bytecode. `script.gd` is its package loader.
- `runtime.gd` (pog_rt) — hosts the PORTED scripts (`gen/`), mechanically
  translated to GDScript. This is the shipping runtime; the VM stays in the
  tree as a **differential oracle** (`--pog` runs the VM, `--port` the port).
- `natives/` — the ~42 native packages BOTH runtimes call into. Modules:
  `std.gd` (globals/lists/sets/tasks), `world.gd` (isim/iship/sim spawning),
  `entities.gd`, `factions.gd`, `economy.gd`, `gameapi.gd` (igame/ihud/
  imission bindings), `misc.gd`, `ui.gd` (gui/ioptions/input/config).
- **Two SEPARATE globals stores, by design**: the VM's `pog_std.globals` and
  the port's `pog_rt.std.globals` are distinct (see `main.gd` `_ready`, which
  seeds both on a debug start). Do not "unify" them.
- `pogcheck.gd` / `portcheck.gd` — headless SceneTree harnesses: run the real
  bytecode / compile every ported script and report what fails to load.
- Coverage of the native surface: `docs/coverage.md` (apicov/featurecov).

## The GUI stack

- `pog/natives/ui.gd` (PogUi) — holds the widget tree the scripts build;
  `SetScreen("icSPHangarScreen")` → POG builder `iBaseGUI.SPHangarScreen`
  (class name minus `ic`, resolved via SCREEN_BUILDERS). Runs the callbacks.
- `base_screens.gd` — the eyes and hands: draws the widget tree, moves the
  focus ring, feeds input back to PogUi. Semantics are original; the skin is
  deliberately ours.
- `pog/gen/ibasegui.gd`, `ipdagui.gd`, `igui.gd` — the ported builders
  (decompiled from `data/pogsrc/`); they create controls, title them from the
  localisation CSVs and attach POG handlers.
- `menu.gd` — front end / pause (currently a stand-in that borrows the ported
  slot screens; see docs/parity.md item A2). `base_interior.gd` — Lucrecia's
  Base docking/interior. `hud.gd` — flight HUD; `hud_screens.gd` — the five
  full-screen icHUD menu elements (starmap etc.); `comms.gd` — portraits/VO.
  Evidence: `docs/screens.md`, `docs/hud.md`, `docs/hud_elements.md`.

## Ships, combat, effects

- `ship_flight.gd` Newtonian flight; `ai_ship.gd` AI pilot on the same model;
  `ship_systems.gd` subsim damage/power/heat (docs/combat.md);
  `weapons.gd` PBC bolts; `missiles.gd` launchers/magazines/mines/CMs;
  `alien.gd` act 3 swarms (docs/act3.md); `death_sequence.gd` explosions.
- Effects: `ship_effects.gd` (channel rig `lz?+s(1.0)` etc.),
  `particle_fx.gd` (data-driven sfx/*/node+emitter+dynamics+draw INIs),
  `explosion_fx.gd` (composite effects from data/json/sfx_effects.json),
  `capsule_fx.gd` (jump tunnel), `space_fx.gd` (world-space HUD underlay:
  reference grid, L-point icons), `star_fx.gd` (suns), `flare_quad.gd`
  (lens flares), `fields.gd` (ambient asteroid/debris fields),
  `element_markers.gd` (the class-coverage ledger featurecov reads).
- `mission.gd` mission runner, `audio_manager.gd` SFX/music, `checks.gd` the
  test harness (below).

## checks.gd — the suites (`-- --<flag>` user args)

Run: `<godot console exe> --headless --path game -- --<flag>`. Fast suites are
kept ≤30 s; run before commits, not after every edit.

Since issue #31 the harness is split per suite along the same layered-file
scheme as main.gd — one node, one class, an extends chain:
`checks_state.gd` (shared state + cross-suite helpers) ← `checks_probes.gd`
(one-shot probes + the demo) ← `checks_camp.gd` (newgame/campcheck + stub
gate) ← `checks_base.gd` (uicheck/basecheck) ← `checks_jump.gd` ←
`checks_mech.gd` ← `checks.gd` (`CheckRunner`, the step dispatcher). New
campcheck acts go in `checks_camp.gd`; new mech steps in `checks_mech.gd`.

| flag | proves |
|---|---|
| `--mechcheck` | flight-model/LDS/missile/turret/beam/fields assertions, 4× time, ~17 s |
| `--mechslow` | + the real-time autopilot convergence steps (minutes; only when autopilot/timing changed) |
| `--jumpcheck` | capsule jump between systems completes |
| `--uicheck` | UI screenshots, docking + screens walk |
| `--basecheck` | Lucrecia's Base: dock, base screens (run when touching screens) |
| `--campcheck` | act 0 mission 10 boots, speaks, first objective + iscore checkpoint |
| `--newgamecheck` / `--newgametest` | new-game boot / campaign smoke |
| `--geogcheck` | body sizes and looks per system |
| `--motioncheck` | motion-grid burst capture |
| `--contactcheck` | contact list after a debug system spawn |
| `--demo` | scripted LDS flight + combat encounter |
| screenshot/probe one-offs | `--commshot --muzzleshot --sunshot --srgbprobe --fireprobe --nebshot --flameshot --hudshot [--mapzoom] --menushot --hudnavshot --bustshot` |

Also: `--pog` / `--port` select the runtime, `--pogtrace` enables the original
`debug{}` narration, `--debugship=<ini stem>` debug-starts in any hull.
Headless script gates: `game/parsecheck.gd` (compile every .gd, ~8 s),
`pog/pogcheck.gd`, `pog/portcheck.gd`.

## tools/ — the extraction pipeline (Python)

`python -m tools.iw2.<tool>` from repo root. `extract_all.py` drives the lot;
outputs land in gitignored `data/`.

- Resources: `resources.py` (ResourceFS: loose files over resource.zip),
  `pkg.py`, `ini_parser.py`, `map_decoder.py` (.map systems),
  `textures.py` (FTEX→PNG), `fonts.py`, `audio.py`, `sfx.py`,
  `hud_sprites.py`, `html_text.py`.
- Geometry: `pso.py` (PSO2 meshes) + `lwo.py` (LWOB collision hulls) +
  `lws.py` (LWS scenes) → `export_gltf.py` / `gltf_builder.py` →
  `assemble_avatar.py` (walk a setup LWS, instance PSOs, keep max-LOD
  detail_switch, preserve nulls → one glTF per avatar).
- Sims: `extract_sims.py` / `extract_all.py` → `data/json/*`;
  `campaign.py`, `classify_map.py`.
- POG: `pogdis.py` (disassembler, round-trip verified), `pogdec.py`
  (bytecode → `data/pogsrc/*.pog`), `pogport.py` (→ `game/scripts/pog/gen/`),
  `pogdata.py`, `pogexport.py`, `pogsummary.py`, `pogverify.py`,
  `pogsig.py` (native signatures from the SDK headers; `--check` cross-checks
  them against our bindings),
  `pogret.py` (validates each SDK-declared return type against the binary
  handler's actual return-slot writes -- the #24 audit; results in
  docs/original.md).
- Coverage: `apicov.py`, `featurecov.py` (see docs/coverage.md).
- Visual regression (#8): `refdiff.py` -- locks a blessed baseline of the
  capture suites' `data/screenshots/*.png` into `data/refshots/`
  (gitignored: rendered frames carry the game's art) and fails on drift
  (`--record` to bless, `--check` after every windowed capture run;
  per-shot tolerance overrides in `data/refshots/tolerances.json` for
  animated scenes). Proven able to fail: a 20% brightness drift on one
  shot fails the band-share metric.
- Binaries: `tools/ghidra/` (see docs/original-code.md).

## Pause model

Esc opens the menu; in flight it sets `get_tree().paused`. HUD CanvasLayer and
`audio_manager` are `PROCESS_MODE_ALWAYS` so menu/music stay live while the
sim freezes; `menu.gd` handles its own `_unhandled_input`. After any menu
close or movie skip, `main.fire_lock` briefly inhibits the trigger.
