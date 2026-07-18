---
name: evidence
description: Dig original-engine behaviour out of the IW2 decomp/PE and cite it (law 1). Use when a gameplay constant, render behaviour, or engine law needs extraction — before writing any new constant into game code.
---

# Extracting engine evidence

Every constant in game code needs a citation (CLAUDE.md law 1). This is the
fastest path from "how did the original do X?" to a cited address.

## Where the original code lives

- `data/decomp/{iwar2,flux,dx7graph,gui,EdgeOfChaos.exe}.dll.c` — Ghidra
  decompilation, one giant file each. iwar2.dll = game logic, flux.dll =
  engine/scene, dx7graph.dll = renderer.
- `data/decomp/*.symbols.txt` — `VA  name  size` per FUNCTION (data symbols
  are NOT in it — see exported statics below).
- Binaries staged in `build/bin/` (Ghidra chokes on `Program Files (x86)`).
- iwar2.dll image base is `0x10000000`; decomp comments cite RVAs like
  `/* 0xd1000  2058  ?Render@icStarfieldAvatar@@... */` — the VA is
  `0x100d1000`.

## Search order

1. `Grep` the `.c` for the class/method: `icFoo::(Render|Think|Parse)` or
   `// ==== Name @ 100xxxxx ====` section markers.
2. Property maps: search `FcString::FcString` init runs near the class
   registration — they name every LWS/INI property and the static it lands
   in (e.g. `s_bright_star_count_...` → `m_bright_star_count`).
3. `_DAT_xxxxxxxx` constants referenced but never assigned → read them
   straight from the PE:
   `<python> tools/ghidra/readconst.py build/bin/iwar2.dll 0x1011d1e0 ...`
   (multiple addresses per call; prints float/double/int/bytes).
4. Function named in symbols.txt but MISSING from the .c (Ghidra hole):
   `<python> tools/ghidra/disasm.py build/bin/iwar2.dll 0x100d4cb0 +0x200`
   — capstone disasm with call targets annotated.
5. **Exported statics** (`m_*` tuning constants): names via
   `<python> tools/ghidra/pe_exports.py build/bin/iwar2.dll`, but it does
   NOT print addresses. To get VA + value, walk the export table yourself:
   ordinal table at export-dir +36, address table at +28, then read the
   float at the resolved file offset (reuse `_sections`/`_off` from
   pe_exports.py; a worked example lived in a scratchpad `export_addr.py` —
   ~40 lines, rewrite it if needed).

`<python>` = `C:\Users\jerom\AppData\Local\Programs\Python\Python312\python.exe`

## Other evidence sources (often faster than the decomp)

- `docs/original.md` — check FIRST; the law may already be extracted.
- `data/pogsrc/*.pog` — decompiled mission/system scripts (cite file:line).
- INIs under `data/` (`flux.ini [icShip]`, `sims/**/*.ini`).
- geog scenes: `data/json/scenes/geog/<cluster>/<stem>.json` (converted
  from `geog/*.lws`); LWS nulls carry engine properties.
- Empirical: original-game screenshots vs decoded textures — pixel-match
  with Pillow (see the `visualprobe` skill).

## Writing it down

- Constant in code → comment with address/source:
  `# 0.4 @ 0x1011d1e0 (m_min_bright_star_intensity, exported static)`.
- Behaviour law → paragraph in `docs/original.md` under the right section,
  with every address.
- Open question → `docs/original.md` Open questions, NOT a plausible guess
  in code.
- Gap that won't be fixed now → GitHub issue on `jleclanche/iw2-remaster`.
