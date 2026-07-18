---
name: gates
description: Run the pre-commit gate sequence (parsecheck, gdlint, mechcheck, basecheck) with the exact toolchain paths, then stage-by-name and commit. Use before every commit touching game/.
---

# Commit gates

Run IN ORDER before commit (not after every edit). Abort on first failure.

```powershell
$godot = "C:\Users\jerom\AppData\Local\Microsoft\WinGet\Packages\GodotEngine.GodotEngine_Microsoft.Winget.Source_8wekyb3d8bbwe\Godot_v4.7-stable_win64_console.exe"

# 1. parsecheck — after ANY .gd edit (~8 s)
& $godot --headless --path game --script res://parsecheck.gd

# 2. gdlint
.venv\Scripts\gdlint.exe game

# 3. mechcheck — fast suite (~17 s)
& $godot --headless --path game -- --mechcheck

# 4. basecheck — ONLY when screens/GUI were touched
& $godot --headless --path game -- --basecheck
```

- `--mechslow` only when autopilot/timing code itself changed.
- Expect trailing `ObjectDB instances were leaked` warnings at exit —
  noise, not a failure. The suites print `ALL PASS` / `PASS` lines.
- PowerShell note: don't `2>&1` the godot exe (NativeCommandError wrapping);
  pipe through `Select-Object -Last 5` for the verdict if output is long.
- `.gd` files must be saved WITHOUT a UTF-8 BOM.

## Committing (multi-session tree — other Claudes work here in parallel)

1. If a probe flag was used: `git grep -n "<name>probe" -- game/` → empty.
2. `git status --short` — expect foreign uncommitted edits; NEVER revert or
   clean anything you didn't write.
3. Stage YOUR files by name only (`git add path1 path2`). NEVER
   `git add -A` / `git add .` — `data/` and `build/` are copyrighted game
   content and must never be committed.
4. Per-topic commit; message body explains the WHY with citations; last
   line exactly:
   `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`
