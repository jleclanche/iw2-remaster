# IW2 Remaster — session harness

Godot 4.7 remaster of Independence War 2: Edge of Chaos. We run the game's
ORIGINAL content (POG bytecode, INIs, models) extracted from the user's GOG
install — see the doc index at the bottom before exploring by hand.

## The three laws

1. **EXTRACT, DON'T GUESS.** Every gameplay constant/behaviour traces to a
   cited source: `iwar2.dll @ 0x100796a0`, `flux.ini [icShip]`,
   `data/pogsrc/istartsystem.pog:775`, an LWS null, a localisation CSV.
   A number without a citation is a guess; put open questions in
   docs/original.md's Open questions, not plausible "facts" in code.
2. **Game data is copyrighted** (Particle Systems/Atari). `data/` and
   `build/` are generated from the local install and gitignored. NEVER
   commit them, NEVER publish their contents, NEVER `git add -A` / `git add .`
   — stage files by name. Never write into the game install
   (`C:\Program Files (x86)\GOG Galaxy\Games\Independence War 2`,
   override with `IW2_GAME_DIR`).
3. **Per-topic commits.**

## Toolchain

- **Godot** (console build, use full path):
  `C:\Users\jerom\AppData\Local\Microsoft\WinGet\Packages\GodotEngine.GodotEngine_Microsoft.Winget.Source_8wekyb3d8bbwe\Godot_v4.7-stable_win64_console.exe`
- **Python 3.12** (bare `python` is a broken Store stub — use full path):
  `C:\Users\jerom\AppData\Local\Programs\Python\Python312\python.exe`
  Run tools as modules from repo root: `<python> -m tools.iw2.<tool>`.
- **gdlint**: `.venv\Scripts\gdlint.exe game` (config `gdlintrc`; `pog/gen/`
  excluded). `.gd` files must be saved WITHOUT a UTF-8 BOM.
- Log redirection gotcha: PowerShell `*> log` captures everything but may
  write UTF-16 — check encoding before grepping the log.

## Gates (run before COMMIT, not after every edit)

In order:
1. **parsecheck** — after ANY `.gd` edit (~8 s):
   `<godot> --headless --path game --script res://parsecheck.gd`
2. **gdlint** — `.venv\Scripts\gdlint.exe game`
3. **mechcheck** — `<godot> --headless --path game -- --mechcheck`
   (fast suite, 4× time, ~17 s). `--mechslow` is the full real-time suite —
   only when autopilot/timing code itself changed.
4. **basecheck** (`-- --basecheck`) additionally when touching screens/GUI.

Suites are kept ≤30 s each; long assertions go behind `--mechslow` or their
own flag, never into the fast path. All suites: docs/architecture.md.

## Concurrency — multiple Claude sessions work this repo in parallel

- `git status` BEFORE staging; expect foreign uncommitted edits.
- Stage only YOUR OWN hunks/files, by name. Never `git add -A`.
- NEVER revert, checkout or "clean up" working-tree changes you didn't make.
- If a file you must edit has foreign changes, edit around them and stage
  selectively (`git add -p` is unavailable non-interactively; prefer
  file-level separation or coordinate via commit early/often).

## Probe discipline

Temporary diagnostics are `--<name>probe` flags: one string in main.gd's
flag list + a `var` + a branch in checks.gd. Before commit they MUST be
fully stripped — assert with:
`git grep -n "yourprobe" -- game/ ; # must return nothing`

## Doc index (read the map before spelunking)

- `docs/architecture.md` — where everything lives: main.gd extends chain,
  POG dual runtime, GUI stack, effects, check suites, tools pipeline.
- `docs/original-code.md` — the ORIGINAL game map: data/decomp layout,
  finding functions, Ghidra-hole recovery (readconst/disasm), pogsrc/json/
  ini trees, extraction conventions.
- `docs/coverage.md` — apicov/featurecov: how to run, current headline.
- `docs/parity.md` — done / missing / stand-in, act-by-act readiness.
- `docs/original.md` — THE evidence log (engine behaviour, with addresses).
- `docs/mechanics.md` — IW2 mechanics semantics being recreated.
- `docs/pog.md` — the POG VM/port: bytecode, dual runtime, checkpoints.
- `docs/hud.md` / `docs/screens.md` — HUD elements / base-GUI screens.
- `docs/fields.md` — asteroid/debris fields. `docs/capsule.md` — jumps.
- Also: combat.md, effects.md, controls.md, formats.md, geography.md,
  decompile.md, act3.md, lds.md, thrusters.md, campaign.md, hud_elements.md.
- **Work queue: the GitHub `jleclanche/iw2-remaster` issue tracker. Issues
  are BOUNDED, with an explicit done-state each — no open-ended buckets;
  act-by-act standing status lives in docs/parity.md instead.** New
  findings/gaps → file a bounded issue, don't hoard them in chat.

## Code quality — for NEW code (aspirational, do not retrofit)

- Typed GDScript (`var x: float`, typed args/returns, typed arrays).
- A comment states a CONSTRAINT or a source, not a narration of the code.
- Extraction citations on every constant (law 1); no magic numbers without
  an address or INI source.
- Keep functions small; prefer data-driven tables over branchy special cases.
- These are the bar for code written from now on. A dedicated quality pass
  over old code is planned but NOT yet applied — do NOT "fix" style
  drive-by, and don't "fix" code to satisfy a gdlint rule that is disabled
  in `gdlintrc` (the layered-file style is deliberate).

Misc: `.map` binary format is documented in `tools/iw2/map_decoder.py`;
`resource/` loose files override `resource.zip` (`tools/iw2/resources.py`);
localised names come from `text/*.csv` via `Properties.name` ids.
