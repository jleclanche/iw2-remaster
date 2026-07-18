# IW2 Remaster — working notes

- Game install (read-only source of truth):
  `C:\Program Files (x86)\GOG Galaxy\Games\Independence War 2`
  Override with `IW2_GAME_DIR`. Never write into the game directory.
- Python: use `.venv\Scripts\python.exe` (3.12); run tools as modules from
  repo root: `python -m tools.iw2.<tool>`.
- `data/` is generated and gitignored — extracted game assets are
  copyrighted and must never be committed or published.
- The `.map` binary format is documented in `tools/iw2/map_decoder.py`.
  Record count is big-endian; link-table decoding is approximate (raw tail
  bytes are preserved in the JSON as `tail_raw` for future refinement).
- `resource/` loose files override `resource.zip` entries; both layers are
  handled by `tools/iw2/resources.py` (`ResourceFS`).
- Localized display names come from `text/*.csv` (`strings.json`); sim INIs
  reference them via `Properties.name` ids like `ship_type_tug`.
- Lint gates (run from repo root; the Godot binary is
  `Godot_v4.7-stable_win64_console.exe`, on PATH via winget):
  - **Parse check** — run after any `.gd` edit, before booting a full
    `--mechcheck`-style suite (~8s vs minutes):
    `Godot_v4.7-stable_win64_console.exe --headless --path game --script res://parsecheck.gd`
    Force-compiles every script through Godot's real analyzer: catches
    unknown identifiers, type-inference failures, bad awaits. Exit 0 =
    clean; failures print as `SCRIPT ERROR` with file:line.
  - **Style lint** — `.venv\Scripts\gdlint.exe game` (config in `gdlintrc`).
    Generated `pog/gen/` is excluded, and rules that clash with the
    deliberate codebase style (topic-layered definition order, large
    extends-chain files) are disabled there — don't "fix" code to satisfy a
    disabled rule. Keep new code clean on the enabled ones: unused args
    (underscore-prefix them), tabs-only indentation, ≤100-char lines.
  - `.gd` files must be saved without a UTF-8 BOM (gdlint can't parse it).
