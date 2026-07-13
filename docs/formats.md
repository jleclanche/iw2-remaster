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
Read straight out of `icSolarSystem::Load` (`iwar2.dll @ 0x1004bb60`) --
full write-up and per-kind field meanings in **`docs/geography.md`**.
Header: **u32 big-endian** record count at offset 0, and **nothing else**
(the byte at 4 is record 0's `kind`, which is 0 -- it is not a version
byte). Records are `sizeof(sEntity)` = 360 bytes, from offset 4:
| off | type | meaning |
|-----|------|---------|
| 0x000 | u8 | **kind**: 0 body, 1 station, 2 L-point, 4 belt, 5 sun, 6 gunstar (inert -- never added to the world), 7 nebula |
| 0x001 | NUL-str | name (rest of the 263-byte region is dirty buffer garbage) |
| 0x108 | 3xf64le | position, meters, system-centric |
| 0x120 | 4xf32le | **orientation quaternion, stored (w, x, y, z)** -- identity on everything except L-points, which carry a real yaw (the jump axis is local +Z) |
| 0x130 | u16le | parent record index (orbital hierarchy) |
| 0x134 | u32le | kind-dependent: body -> `IeBodyType`; sun -> `icSun::eClass`; station -> `station_creation.ini [Stations] Scene[n]` index; belt -> f32 belt radius |
| 0x138 | f32le | **body radius, meters** (`FiSim::SetRadius`) -- bodies and suns only |
| 0x13c | u8 | body: 1 = rocky, 2 = gassy |
| 0x13d, 0x13e | u8 | body: surface texture indices into `planets.ini` |
| 0x140 | 9xf32le | three RGB colors 0-255 -> `SurfaceTint(0/1)` (/255) |
| 0x164 | i8 | body: cloud texture index, **-1 = no atmosphere** |
| 0x165 | u8 | body: ring count |

**Fields a kind does not write are left over from the previous record**
(one shared write buffer), so a station's 0x138 is its parent body's
radius. Only read a field for the kind that owns it.

Tail = **capsule-jump table**: u8 pad, u16 zero, u32le 17, u32le 17,
u32le n, then n x { u32le record|0x8000, u8 len, `;`-separated
destination system names } with **3 zero bytes** between entries.
Destination names use underscores and may need `System Centre` suffix
stripping to match map stems. `microsystem.map` is an IFF FORM, not this
format.

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
  `LightRange`/`LensFlare`.
- **`(envelope)` key blocks are value-first, frame-second** -- the reverse
  of a motion block, where the values come first and the *meta* row leads
  with the frame. An animated light intensity is:

      LgtIntensity (envelope)
        1              <- channel count
        4              <- key count
        0              <- key 0 VALUE
        0 0 0 0 0      <- key 0 FRAME, then spline params
        1              <- key 1 value
        3 0 0 0 0      <- key 1 frame

  Reading it like a motion block yields intensity 0 everywhere. Frames are
  in the scene's own `FramesPerSecond`, so keep that too -- it differs per
  scene (the `sfx` explosions are 60 fps, the impacts 30).
- Parenting needs **two passes**: `ParentObject n` may FORWARD-reference an
  object defined later in the file. `sfx/antimatter_explosion_high_0.lws`
  does exactly this (its beams parent to scaler nulls declared below them).
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
Policy: anything that isn't UTF-8/clean for the engine is normalized AT
EXTRACTION, not patched at runtime — WAVs are rebuilt as minimal
fmt+data RIFF (`audio.py`; the originals' trailing smpl/LIST chunks
trip Godot's parser), and the `html/` screen-UI tree is transcoded
Latin-1 → UTF-8 (`html_text.py`).
- Resource `audio/**/*.wav`: PCM, load directly (post-normalization).
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
