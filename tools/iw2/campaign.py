"""Reconstruct the IW2 campaign storyline from extracted data.

Combines the mission script packages (data/json/packages, from pkg.py)
with the localized strings (data/json/strings.json) into:

  - docs/campaign.md        human-readable storyline: acts, missions,
                            titles, objectives, full dialogue scripts
  - data/json/campaign.json structured form for driving a playthrough

Dialogue keys follow  a<act>_m<mission>_dialogue_<speaker>_<slug>;
objective keys        a<act>_m<mission>_objective(s)_<slug>.
The order of keys in the localisation files is the authored order.

Usage:  python -m tools.iw2.campaign
"""

from __future__ import annotations

import json
import re
from pathlib import Path

MISSION_RE = re.compile(r"iact(\d)mission(\d+)$")
KEY_RE = re.compile(r"a(\d)_m(\d+)_(\w+)")

ACT_NAMES = {
    0: "Act 0 — Prologue (training, young Cal)",
    1: "Act 1 — The Badlands (escape and survival)",
    2: "Act 2 — Piracy (building a reputation)",
    3: "Act 3 — The Gathering Storm (endgame)",
}


def mission_title(strings_in_pkg: list[str]) -> str:
    for s in strings_in_pkg:
        if (2 < len(s) < 60 and " " in s.strip() and not s.startswith(("g_", "ini:", ";"))
                and "_" not in s and not s.startswith("iAct")
                and s[0].isupper()):
            return s
    return ""


def main() -> None:
    strings: dict = json.loads(Path("data/json/strings.json").read_text(encoding="utf-8"))
    pkg_dir = Path("data/json/packages")

    missions: dict = {}
    for f in sorted(pkg_dir.glob("iact*mission*.json")):
        m = MISSION_RE.match(f.stem)
        if not m:
            continue
        act, num = int(m.group(1)), int(m.group(2))
        pkg = json.loads(f.read_text(encoding="utf-8"))
        missions[(act, num)] = {
            "package": f.stem,
            "title": mission_title(pkg["strings"]),
            "objectives": [],
            "dialogue": [],
            "emails": [],
            "api_calls": len(pkg["calls"]),
        }

    # walk localisation in authored order and attach to missions
    for key, text in strings.items():
        if not isinstance(text, str) or not text.strip():
            continue
        m = KEY_RE.match(key)
        if not m:
            continue
        act, num, rest = int(m.group(1)), int(m.group(2)), m.group(3)
        if (act, num) not in missions:
            missions[(act, num)] = {"package": None, "title": "",
                                    "objectives": [], "dialogue": [],
                                    "emails": [], "api_calls": 0}
        entry = missions[(act, num)]
        if rest.startswith(("objective", "objectives")):
            entry["objectives"].append(text)
        elif rest.startswith("dialogue"):
            speaker = rest.split("_")[1] if "_" in rest else "?"
            entry["dialogue"].append([speaker.upper(), text])
        elif "email" in rest or "brief" in rest:
            entry["emails"].append(text)

    out_md = ["# Independence War 2: Edge of Chaos — campaign storyline",
              "", "Reconstructed from the game's mission script packages "
              "and localisation files.", ""]
    out_json: dict = {}
    for act in sorted({a for a, _ in missions}):
        out_md += ["", f"## {ACT_NAMES.get(act, 'Act %d' % act)}", ""]
        out_json[str(act)] = {}
        for (a, num) in sorted(k for k in missions if k[0] == act):
            e = missions[(a, num)]
            title = e["title"] or "(untitled)"
            out_md.append(f"### Mission {num:02d} — {title}")
            if e["package"]:
                out_md.append(f"*script: {e['package']}, "
                              f"{e['api_calls']} engine calls*")
            if e["objectives"]:
                out_md.append("")
                out_md.append("**Objectives**")
                for o in dict.fromkeys(e["objectives"]):
                    out_md.append(f"- {o}")
            if e["emails"]:
                out_md.append("")
                out_md.append("**Briefings / email**")
                for t in e["emails"][:6]:
                    out_md.append(f"> {t}")
            if e["dialogue"]:
                out_md.append("")
                out_md.append("**Dialogue**")
                for speaker, line in e["dialogue"]:
                    out_md.append(f"- **{speaker}**: {line}")
            out_md.append("")
            out_json[str(act)][f"{num:02d}"] = e

    Path("docs/campaign.md").write_text("\n".join(out_md), encoding="utf-8")
    Path("data/json/campaign.json").write_text(json.dumps(out_json, indent=1),
                                               encoding="utf-8")
    total_dialogue = sum(len(e["dialogue"]) for e in missions.values())
    print(f"campaign: {len(missions)} missions, {total_dialogue} dialogue "
          f"lines -> docs/campaign.md")


if __name__ == "__main__":
    main()
