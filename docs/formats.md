# IW2: Edge of Chaos — file format reference (reverse-engineered)

Everything below was reverse-engineered for this project unless marked
**[existing tooling]**. Implementations live in `tools/iw2/*.py`; each
section names its decoder. Byte order is noted per field — Flux mixes
big-endian IFF metadata with little-endian payloads constantly.

## Resource layout & URL schemes (`resources.py`)
- `resource.zip` is a plain zip; loose files under `resource/` override
  same-path entries. All lookups are case-insensitive.
- INI values reference resources by scheme: `ini:/path` (another INI),
  `lws:/path` (scene), `map:/`, `sound:/`, `font:/`, `model:/`,
  `collision_hull:/`. In LWS null tags, `|` replaces `/` and `||` starts
  an absolute path (`template=ini||audio|sfx|player_drive_tug`).
- `streams/` (music/ambient MP3, speech WAV) and `movies/` (*.bik) live
  outside the resource FS. `html/` inside the resource holds the game's
  own screen UI (425 pages: emails, encyclopedia, prison dossiers).

## Flux INI (`ini_parser.py`)
`key[n]=` indexed arrays, `(a,b,c)` float vectors, `;` comments,
`[Section]` headers. `[Class] name=` gives the sim class; `[Properties]`
carries gameplay constants (per-axis `speed`/`acceleration`, rates).

## `.map` star systems (`map_decoder.py`, `classify_map.py`)
Header: **u32 big-endian** record count at offset 0, then 1 byte.
Records are 360 bytes:
| off | type | meaning |
|-----|------|---------|
| 0   | NUL-str | name (rest of 263-byte region is dirty buffer garbage) |
| 263 | 3×f64le | position, meters, system-centric |
| 287 | f32le | scale (usually 1.0) |
| 303 | u32le | parent record index (orbital hierarchy) |
| 311 | f32le | **map ZONE radius** — not a body size and not a type id; Alexander is 88 Mm, cluster rocks 6,000 Mm. Cap by nearest-neighbor distance for rendering; do not use for LDSI |
| 319 | 9×f32le | three RGB map colors 0-255 (tint planet impostors with color[0]) |
| 359 | u8 | kind (5=system root; otherwise unreliable — classify by name keywords + hierarchy) |

Tail = **capsule-jump table**: u16 zero, u32le 17, u32le 17, u32le n,
then n × { u32le record|0x8000, u8 len, `;`-separated destination system
names } with **3 zero bytes** between entries. Destination names use
underscores and may need `System Centre` suffix stripping to match map
stems. Records carry no model reference — the original spawns station
sims from POG scripts; we classify by descriptive names.
`microsystem.map` is an IFF FORM, not this format.

## PSO / PSO2 meshes (`pso.py`, `export_gltf.py`)
IFF `FORM PSO ` / `PSO2`. Metadata big-endian, vertex/index payload
little-endian.
- `OHDR`: 3×u32be + NUL-strings — texture names; `.LBM` stems match the
  extracted PNG stems.
- `SHDR` per surface: NUL-str name, 5×f32be (RGB + 2 coefficients), two
  texture slots { u32be 1-based texture index, u32be mode (0x21/0x24),
  u32be pad }, optional envmap string, tail u32be n_verts + u32be n_uv.
- `VERT`: f32le, stride 24 + 8×n_uv (position, normal, UVs).
- `INDX`: 2-byte prefix (unreliable); triangle count = (size−2)/6,
  3×u16le each.
- `DELT`: u32be a, u32be b, then N×12B f32le vertex morph deltas
  (character facial animation). `FRAM`: morph weight tracks (raw).
- `.giz` = plain-text `MORPHGIZMO` weight tracks driving DELT morphs.

## LWS scenes (`lws.py`, `assemble_avatar.py`, `gltf_builder.py`)
LightWave LWSC v1 text. Objects 1-indexed in load order; `ParentObject`
refers to that order (lights don't count). Null names carry semantics:
- `<detail_switch min max>` LOD group — keep the max=1.0 group and
  force identity transform (authoring offsets lay LODs side by side).
- `<scene name="x">` instances sibling `x.lws`.
- `<anim channel=EXPR>` — **pose interpolator, not a time animation**:
  exactly two keyframes = the pose at channel value 0 and 1. Export as
  pose pairs; looping them as timelines makes parts snap back.
- `<node class=... >`: `icFlameConeAvatar` (tint/splay/channel),
  `icStarfieldAvatar`, `icNebulaAvatar url=model||models|x`,
  `icBeamAvatar`; `<node template=ini||audio|sfx|x>` = sound emitter.
- `<switch channel=x>` visibility banks (base light banks, parked-ship
  bays in `avatars/base`).
- `LoadObject foo.lwo` → lowercase stem + `.pso` in the same directory.
- Motion blocks: rows of `x y z h p b sx sy sz` + meta rows; scale 0 is
  LightWave's "hidden" idiom (clamp, don't drop); `(envelope)` may
  replace values — skip those keys. Lights: `AddLight`/`LightName`/
  `LightColor`/`LgtIntensity` (may be `(envelope)`)/`LightType`/
  `LensFlare`.
- Time animations must only loop when cyclic (first==last pose, HPB
  modulo 360°); rotation keys must be subdivided to ≤90° steps before
  quaternion conversion or spinners collapse.
- Coordinates: LW left-handed +Z-forward → glTF: negate Z on positions,
  flip winding, quat = Ry(−H)·Rx(−P)·Rz(B).

## Channel expression language (`ship_effects.gd`)
Channel strings on `<anim>`/sound nodes are expressions:
`NAME[?|#][+|-]mods`, space-separated terms combined with max().
Inputs: `LZ/LX/LY` thruster demands, `RP/RY/RR` rotation demands,
`burn`, `fire`, `dock`, `damage`... Mods: `s(tau)` first-order smooth,
`j(tau)` jet puff (instant attack, tau-second decay — RCS thrusters),
`o(rate)` one-shot pulse on rising edge (muzzle flashes). Per-avatar
`channels.ini` (`FcChannelGeneratorNode`) derives named channels
(`flame`, `core`, `boom`, `flap`) from smoothed inputs. Sound emitter
INIs (`FcLoopSoundNode`) multiply volume by `volume_channel`.

## LWOB collision hulls (`lwo.py`)
`collisionhulls/*.lwo` are standard LWOB: `PNTS` f32be triplets, `POLS`
(u16be nverts, indices, s16be surface), `SRFS` names. Fan-triangulate.

## Fonts `.frf` (`fonts.py`)
IFF `FORM FONT`. `FHDR` (70B): u32be first_char, last_char, first
again, line_height, descent, tex_w, tex_h, glyph_count, point_size,
then two NUL-strings at offset 38: atlas name (`*.lbm` → the FTU/FTC
texture) and family name. Per-char `GLYP`: u8 present flag; if set,
10×s32be: logical box (x0,y0,x1,y1; y relative to baseline, up
negative; x1 = advance), ink box (x0,y0,x1,y1), atlas x, atlas y.
Emit as BMFont (`base = line_height − descent`); GOG's `ocrb_8pt.frf`
actually references the Andale Mono atlas. Note: font `.frf` ≠ `.ffe`
(joystick force-feedback effects, no gameplay content).

## POG VM bytecode (`pogdis.py`)
The CODE chunk (u32be size prefix, then bytecode) is a stack-machine
program: opcode byte + **little-endian** operands. The opcode table was
recovered by compiling the POG SDK's sample sources — which include
three original campaign missions — with the SDK's own `pc.exe -ma`
(assembler listings with byte offsets) and aligning listing offsets
against the compiled CODE bytes; `python -m tools.iw2.pogdis --selftest`
re-validates the round trip (16k instructions, exact match). Compiler
runs from `build/pogc` (needs the game's `flux.dll` beside it).
Highlights: `0x0F/0x10/0x11` Goto/GoFalse/GoTrue (absolute u32 target),
`0x14/0x15` CallLocal/Call and `0x17/0x18` StartLocal/Start (13 bytes;
imported targets resolved via FIMP call-site offsets, local targets
carry the callee entry offset), `0x0C/0x0D` Load/Store (local slot),
`0x0E` Reserve, `0x3E` LoadString (STAB index), `0x3B/0x3C`
MarkObject/DeleteMarkedObjects (temp handle scopes), `0x45` DebugSkip.
Full table in `tools/iw2/pogdis.py`. `--all` emits readable listings
for every retail package (`data/pogdis/*.pogasm`) — exact mission
logic: spawn positions, waypoints, conditions, timings.

## POG script packages `.pkg` (`pkg.py`, `campaign.py`)
IFF `FORM PKG `: `PKHD` name; `ITAB` import count; per import package a
`PIMP` (name + count) followed by its `FIMP`s — imported function name,
u32be call count, and **u32be CODE offsets of every call site**; `ETAB`
+ `FEXP` exports (name + entry offset; `Main`, `MissionHandler`);
`STAB` u32be count + NUL-separated strings (globals, sim/template
names, localisation keys); `CODE` VM bytecode. The offset-sorted import
list is an API call trace — mission logic skeletons without a VM.
Dialogue/objective text keys (`a<act>_m<mm>_dialogue_<speaker>_<slug>`)
map 1:1 to `streams/audio/speech/<key>.wav`.

## Audio & video
- Resource `audio/**/*.wav`: PCM, load directly.
- `streams/audio/speech/*.wav`: **compressed** WAV (not PCM) —
  transcoded with **[existing tooling]** ffmpeg to OGG.
- `streams/audio/music|ambient/*.mp3`: play directly (moods `a1_ambient`,
  `a1_action`, ...).
- `movies/*.bik`: Bink — **[existing tooling]** ffmpeg decodes.
  **ffmpeg 8.1.x's libtheora encoder emits corrupt bitstreams**
  (`error in unpack_block_qpis` from ffmpeg's own decoder; macroblock
  garbage in Godot) — encode with ffmpeg 7.1.1, forced `yuv420p` +
  even dimensions, and verify with `ffmpeg -v error -i out.ogv -f
  null -`. Character biks (az/jaffs/lori/ocal/ycal/smith) are the MFD
  comm-portrait loops.

## Textures FTC/FTU — [existing tooling]
Decoded with Jerome's own FTEX plugin for Pillow (`textures.py` wraps
it). Every FTC has an FTU twin; prefer FTU (lossless) on stem collision.
Font atlases need alpha-from-luminance when re-exported.

## Geog skies (`geog/*.lws`)
Per-system sky scene: `icStarfieldAvatar` (bright/dim star counts,
tint), `icNebulaAvatar` (backdrop model in `models/*.pso`), `<star>` /
`<fill>` light colors (sun + ambient), and lens-flared point lights =
neighboring systems' stars (positions double as starmap layout).

## Reference data used as-is
- `configs/default.ini` + `keyboard_only.ini`: the original input
  bindings (F5–F9 autopilots, `=`/`-` set-speed throttle, W/S/A/D
  thrusters, numpad steering).
- `manual.pdf` (game root): authoritative HUD spec (reticle, ORB,
  contact list colors, system-status lights, motion grid orange→green).
- `defaults.ini`, `flux.ini`: engine class defaults.
- POG SDK headers (`Projects/pog-scripting-sdk`): API semantics for the
  call traces; distilled gameplay notes in `docs/mechanics.md`.
