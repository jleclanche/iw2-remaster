# Game architecture — systems map

The Godot prototype grew organically out of `main.gd`; this is the
systems breakdown and the refactor roadmap. Rule of thumb: **extract,
don't guess** — every constant should trace to an INI, an LWS null, a
localisation string, or disassembled POG bytecode (`docs/formats.md`).

## Current systems (game/scripts/)

| file | system | notes |
|------|--------|-------|
| `main.gd` | orchestrator + world | still owns system loading/streaming, LDS/jump, targeting, collision, cameras; shrink over time (see roadmap) |
| `ship_flight.gd` | Newtonian flight model | INI constants; `assist` trims, `drive_override` for LDS/capsule |
| `ai_ship.gd` | AI pilot | same flight model; steers through `input_rotate`, never global_rotate |
| `weapons.gd` | PBC bolts | per-hull muzzles (setup-scene nulls), swept-sphere hits |
| `ship_effects.gd` | channel-driven effects | the original's channel expression language; pose-pair anim nulls, flame cones, RCS jets |
| `explosion_fx.gd` | kill explosions | deba flipbook + sparks + shockwave (sfx/explosion_high) |
| `hud.gd` | HUD chrome | manual.pdf layout; original fonts; owns `target_view` |
| `target_view.gd` | MFD EO feed | SubViewport rendering the targeted avatar |
| `comms.gd` | dialogue/VO/portraits | Clay = live 3D head (Clay_Anim01.lws); others = movie loops |
| `mission.gd` | mission step runner | being re-authored from disassembled POG (`data/pogdis`) |
| `menu.gd` | front end / pause | owns input while paused; prison dossiers + bust |
| `audio_manager.gd` | SFX/music | RIFF fixups, mood crossfade |
| `checks.gd` | test harness | `--demo/--mechcheck/--jumpcheck/--uicheck/--campcheck/--motioncheck` |

## Pause model

Esc opens the PDA menu; when in flight it sets `get_tree().paused`.
The HUD CanvasLayer and `audio_manager` run `PROCESS_MODE_ALWAYS`, so
the menu, its sounds and music stay live while the simulation
(everything under `main`, default `INHERIT`) freezes. `menu.gd` handles
its own `_unhandled_input` for the same reason. After any menu close or
movie skip, `main.fire_lock` briefly inhibits the trigger so the
confirming click can't fire the PBC.

## Extraction ground truths in play

- flight/ship constants: `sims/**/*.ini` → `data/json/ships.json`
- eye points: `crew` null in each ship's setup scene (`comsec.lws`,
  `common_setups/tug.lws`)
- camera FOV: `flux.ini` `icInternalCamera` 1.1 rad, others 1.2 rad
- mission logic: `tools/iw2/pogdis.py` → `data/pogdis/*.pogasm`
- HUD strings/abbreviations: `text/*.csv` → `data/json/strings.json`

## Refactor roadmap (next passes)

1. `world.gd`: pull system loading, object streaming, impostors, sky and
   the motion grid out of `main.gd`.
2. `flight_computer.gd`: autopilots, LDS, capsule jumps.
3. Generic particle player for `sfx/*/{node,emitter,dynamics,draw}.ini`
   (cornflakes, spark_shower, trails, capsule tunnel) — replaces the
   bespoke effect code.
4. Subsim graph loading (`subsims/`): real damage model, power/heat,
   weapon capacities.
5. Mission compiler: `data/pogdis/*.pogasm` → mission.gd step scripts
   (mechanical translation per mission).
