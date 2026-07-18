# The original game's code and data — map for extraction work

Where the ORIGINAL game lives in this repo and how to mine it. Companions:
`docs/original.md` (the evidence log — what we PROVED, with sources),
`docs/decompile.md` (how to regenerate the decomp), `docs/formats.md` (file
formats), `docs/pog.md` (running/porting the scripts). Everything under
`data/` and `build/` is derived from the user's own GOG install and
**gitignored — copyrighted, never commit it**.

## data/decomp/ — the decompiled binaries

Ghidra headless output (`tools/ghidra/decompile.ps1`), one pair per binary:
`<name>.c` (decompiled C, every recovered function) and `<name>.symbols.txt`.

| binary | image base | what lives there |
|---|---|---|
| `iwar2.dll` | 0x10000000 | the game classes: `ic*` / `ii*` (icShip, icHUD*, icCannon, subsims, AI, cameras) |
| `flux.dll` | 0x10000000 | the Flux engine: `Fc*` / `Fi*` (sim/avatar/resource layer, **the POG VM**: FcScriptTask::Execute @ 0x1003b190) |
| `gui.dll` | 0x10000000 | window/control widgets the front end uses |
| `dx7graph.dll` | 0x10000000 | the DirectX 7 renderer backend |
| `EdgeOfChaos.exe` | 0x00400000 | thin launcher / top-level game loop |

(`ihud.dll` and the other `bin/release/*.dll` wrapper packages are POG→C++
bindings only; iscore.dll's handlers are documented in original.md §3.)

- **Symbols files**: tab-separated `hex_va<TAB>name<TAB>size`, one line per
  function, demangled where the PE kept its C++ symbols (most classes did).
  Grep these first to turn a name into an address or vice versa.
- **Section markers in the .c**: every function is preceded by
  `// ==== Name @ addr ====` — grep `"==== icShip::" data/decomp/iwar2.dll.c`
  to jump straight to a class's functions.
- **icHUD\* have NO symbols.** Find them through the class registry: grep the
  class-name string → `FcRegistry::RegisterClass(name, base, factory, props)`
  → factory → ctor → vtable → the virtual you want. Worked example in
  original.md §1.
- Addresses in the decomp are virtual addresses at the preferred image base,
  so they are stable and citable.

## The Ghidra dropped-body problem, and the recovery tools

Ghidra's decompiler **silently drops** functions it cannot recover ("could not
recover jumptable", regions its disassembler never reached). The bytes are
still in the PE. When a function named in symbols.txt has no body in the .c:

- `python tools/ghidra/readconst.py build/bin/iwar2.dll 0x1011945c [...]` —
  read float/double/int constants at a Ghidra VA straight out of the PE
  (this is how the `_DAT_xxxxxxxx` engine constants come out).
- `python tools/ghidra/disasm.py build/bin/iwar2.dll 0x100d4cb0 [end|+len]` —
  capstone raw disassembly of the VA range, call/jmp targets annotated from
  the matching symbols.txt, import thunks dereferenced.

That is how `icChaseCamera::Update @ 0x100d4cb0` was recovered (a Ghidra
hole): disasm.py for the control flow, readconst.py for the constants, then
transcribe the law into GDScript with the address cited (main_camera.gd).
`pe_exports.py` dumps the export table (exported statics like the
`icAITarget::m_*` tuning constants). Binaries are staged into `build/bin/`
because Ghidra breaks on the `Program Files (x86)` path.

## data/pogsrc/ — the decompiled scripts (114 packages)

`tools/iw2/pogdec.py` output from the shipped bytecode; header says "review
before trusting". Naming:

- `iact<N>mission*.pog` — campaign missions (acts 0–3); `iactone/two/three`
  are the act drivers; `iact0generaltraining`, `iact1wingmentraining` etc.
- `ibasegui` / `ipdagui` / `igui` — the GUI screen builders and widget layer.
- `istartsystem` (boot walk), `iprelude` (player creation), `ibacktobase`.
- Support: `iutilities`, `iconversation`, `imissiongenerator`, `iwingmen`,
  `itrafficcreation`, `ifactionscript`, `imusic`, `ideathscript`, ...
- MP-only: `imultiplaygui`, `icapturetheflag`, `ideathmatch`, `ibombtag`, ...

**Irreducible control flow**: where the bytecode's flow graph cannot be shaped
into structured statements, pogdec rebuilds the function as its basic blocks
under an explicit program counter rather than emit a goto it cannot honour —
ugly but never lying. `data/pogdis/*.pogasm` is the raw disassembly
(`pogdis.py`, round-trips all 16k instructions against the SDK compiler).

## data/ — the rest of the extracted tree

| dir | derived from / holds |
|---|---|
| `data/ini/` | the game's own INI config tree as shipped (sims/, subsims/, sfx/, geog/, audio/, loadouts/, text/, planets.ini, ship_names.ini, ...) |
| `data/json/` | our extracted JSON: `ships/stations/subsims/sims_other.json` (sim INIs), `strings.json` (text CSVs), `systems/` (.map decode), `packages/` (POG package index), `sfx_effects.json` (sfx LWS + icVisualEffects consts), `hud_sprites.json`, `campaign.json`, `scenes/`, `collisionhulls/` |
| `data/text/` | localisation CSVs per act + global tables |
| `data/avatars/`, `data/gltf/` | LWS setups and converted PSO→glTF meshes |
| `data/textures/` | FTEX/FTC → PNG (decoder: Jerome's, verified good) |
| `data/audio/`, `data/movies/`, `data/fonts/` | WAVs, Bik movies, fonts |
| `data/pog/`, `data/packages_bin/` | raw POG bytecode packages |

## Key conventions (get these wrong and everything looks wrong)

- **Address citations**: every extracted fact in `game/scripts` carries its
  source as a comment — `iwar2.dll @ 0x100796a0`, `flux @ 0x1003b190`,
  `flux.ini [icShip]`, `data/pogsrc/istartsystem.pog:775`. Follow the
  convention; a number without a citation is a guess.
- **Handedness**: LightWave/DirectX are left-handed +Z-forward; Godot/glTF
  right-handed. **Negate Z** on positions/normals and flip winding
  (`tools/iw2/export_gltf.py`, formats.md).
- **LWS anim channels**: null names carry semantics in angle-bracket tags;
  `<anim channel="lz?+s(1.0)">` = drive by channel `lz` (fore thrust),
  `?` = positive-only gate, `+s(1.0)` = smoothed over 1 s. Grammar and the
  raw-input channel list ("lx"/"ly"/"lz"/"rp"/"ry"/"rr"...) in
  `ship_effects.gd`; scene semantics in `tools/iw2/lws.py`.
- **Localisation**: `text/*.csv` are id→string tables; sims reference
  `Properties.name` ids (`ship_type_tug`). `key_text_*` rows are key-cap
  labels (`key_text_circumflex` = "^"), `object_text_*` rows are input
  device/axis display names (input.csv). Never hardcode a display string.
- **Shipped-data faults are recorded, not "fixed"** — see original.md §5c-0
  (missing setup scenes, wrong dockport null names). The original's bugs are
  part of the spec.
