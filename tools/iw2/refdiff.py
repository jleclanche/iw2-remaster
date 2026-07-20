"""Reference-comparison discipline for the eyeball-verified visual areas (#8).

The screenshot suites (uicheck / basecheck / sunshot / geogcheck / muzzleshot
/ commshot / bustshot / motioncheck ...) write PNGs into data/screenshots/
when run WINDOWED (headless runs skip capture). This tool locks a BLESSED
baseline of those captures in data/refshots/ -- gitignored like everything
under data/, because rendered frames contain the game's copyrighted art --
and fails when a fresh capture drifts:

    <python> -m tools.iw2.refdiff --record [name ...]   bless current captures
    <python> -m tools.iw2.refdiff --check  [name ...]   diff against baseline
    <python> -m tools.iw2.refdiff --list                what is blessed

Metrics per shot: mean absolute error (8-bit) and the share of pixels whose
max-channel delta exceeds the pixel band. The defaults hold static scenes;
animated ones (pulsing suns, starfields, blinking cursors) get per-shot
overrides in data/refshots/tolerances.json:

    { "sunshot_sol": {"mae": 8.0, "band": 24, "share": 0.06} }

A missing fresh capture and a size change both FAIL. Exit 0 when every
blessed shot holds, 1 otherwise. The workflow: run the capture suites
windowed, eyeball the output ONCE, `--record`; from then on every capture
run ends with `--check`, and a visual regression in the ~35-commit churn
areas (glow, nebula, flares, HUD, portraits) fails loudly instead of
slipping by.
"""

from __future__ import annotations

import json
import shutil
import sys
from pathlib import Path

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
SHOTS = ROOT / "data" / "screenshots"
REFS = ROOT / "data" / "refshots"
DEFAULT = {"mae": 4.0, "band": 12, "share": 0.015}


def _load(p: Path) -> np.ndarray:
    return np.asarray(Image.open(p).convert("RGB"), dtype=np.int16)


def record(names: list[str]) -> int:
    REFS.mkdir(parents=True, exist_ok=True)
    picked = ([SHOTS / ("%s.png" % n) for n in names] if names
              else sorted(SHOTS.glob("*.png")))
    if not picked:
        print("refdiff: nothing to record (no captures in %s)" % SHOTS)
        return 1
    for p in picked:
        if not p.exists():
            print("refdiff: MISSING capture %s" % p.name)
            return 1
        shutil.copy2(p, REFS / p.name)
        print("refdiff: blessed %s" % p.name)
    return 0


def check(names: list[str]) -> int:
    tol_all = {}
    tp = REFS / "tolerances.json"
    if tp.exists():
        tol_all = json.loads(tp.read_text())
    refs = ([REFS / ("%s.png" % n) for n in names] if names
            else sorted(REFS.glob("*.png")))
    if not refs:
        print("refdiff: no baselines recorded -- run --record after an "
              "approved capture run")
        return 1
    bad = 0
    for rp in refs:
        fp = SHOTS / rp.name
        t = {**DEFAULT, **tol_all.get(rp.stem, {})}
        if not fp.exists():
            print("refdiff FAIL %s: no fresh capture" % rp.stem)
            bad += 1
            continue
        a, b = _load(rp), _load(fp)
        if a.shape != b.shape:
            print("refdiff FAIL %s: size %dx%d vs baseline %dx%d"
                  % (rp.stem, b.shape[1], b.shape[0], a.shape[1], a.shape[0]))
            bad += 1
            continue
        d = np.abs(a - b)
        mae = float(d.mean())
        share = float((d.max(axis=2) > t["band"]).mean())
        ok = mae <= t["mae"] and share <= t["share"]
        print("refdiff %s %s: mae %.2f (<= %s), %.2f%% past band %d "
              "(<= %.2f%%)" % ("PASS" if ok else "FAIL", rp.stem, mae,
                               t["mae"], share * 100.0, t["band"],
                               t["share"] * 100.0))
        bad += 0 if ok else 1
    print("refdiff: %d/%d shots hold the baseline" % (len(refs) - bad,
                                                      len(refs)))
    return 0 if bad == 0 else 1


def main(argv: list[str]) -> int:
    if not argv:
        print(__doc__)
        return 2
    mode, names = argv[0], argv[1:]
    if mode == "--record":
        return record(names)
    if mode == "--check":
        return check(names)
    if mode == "--list":
        for p in sorted(REFS.glob("*.png")):
            print(p.stem)
        return 0
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
