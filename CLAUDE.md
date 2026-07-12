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
