"""Extract the composite visual effects (``sfx/*.lws``) into one JSON table.

``data/ini/sfx/<name>/`` is only the bottom layer of the effects system: the
particle systems. The layer above is ``sfx/*.lws`` -- 23 LightWave scenes that
compose particle systems, a sprite flipbook, a sound, a special avatar and a
light with an intensity envelope into one playable effect.

The engine reaches them through ``icVisualEffects`` (``iwar2.dll``, prefix table
at ``0x10161f14``). Its constructor (``0x100d3050``) loads, for each of twelve
effect kinds, ``<prefix>high_0..2`` (stopping at the first that fails) and
``<prefix>low``; the twelve 20-byte slots are ``{count, high[3], low}``, which
is exactly the ``operator_new(0x104)`` it allocates.

Selection (``0x100d33e0``, called from ``0x100d3210``) is a *distance* LOD, not
a quality setting::

    apparent = size * SIZE_WEIGHT[effect] / distance_to_camera
    apparent <  cull_detail * gfx  ->  nothing is drawn
    apparent <  low_detail  * gfx  ->  the `low` scene
    otherwise                      ->  a uniformly random `high_%d`

Writes ``data/json/sfx_effects.json``.

Usage:  python -m tools.iw2.sfx [output_path]
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

from .ini_parser import parse_ini
from .lws import parse_scene
from .resources import ResourceFS

# icVisualEffects prefix table, iwar2.dll @0x10161f14, in slot order. The index
# is what the fire sites push, so it is the effect's identity in the engine.
EFFECTS = [
    "explosion",             # 0
    "small_explosion",       # 1
    "hull_impact",           # 2
    "asteroid_impact",       # 3
    "beam_impact",           # 4
    "lda_impact",            # 5
    "plasma_fire",           # 6
    "reactor_explosion",     # 7
    "antimatter_explosion",  # 8
    "alien_explosion",       # 9
    "ldsi_explosion",        # 10
    "collision",             # 11
]

# Per-effect apparent-size weight, iwar2.dll @0x1011d254 (float[12]), read in
# FUN_100d3210 as `size * SIZE_WEIGHT[i] / distance`.
SIZE_WEIGHT = [20.0, 20.0, 15.0, 15.0, 15.0, 35.0, 20.0, 30.0, 30.0, 30.0,
               30.0, 30.0]

# icVisualEffects LOD thresholds (its two registered properties), defaults at
# iwar2.dll @0x10161f0c / @0x10161f10.
CULL_DETAIL = 0.005
LOW_DETAIL = 0.04

# Which game event fires which effect. Recovered from the seven call sites of
# the play function (iwar2.dll @0x100d3210); see docs/effects.md.
EVENTS = {
    "explosion": "icExplosion sim with radius >= 150 m (@0x1011a81c)",
    "small_explosion": "icExplosion sim with radius < 150 m",
    "hull_impact": "icBullet hitting anything that is not rock (default)",
    "asteroid_impact": "icBullet hitting a sim of category 0xb/0xe that also "
                       "passes a name test (rock)",
    "beam_impact": "icBeam hit",
    "lda_impact": "a shot crossing a ship's LDA shield ellipsoid; fired by the "
                  "LDA ship-system (@0x10036210), only if the ship has an LDA",
    "plasma_fire": "icShip::ApplyWeaponDamage, probabilistically: "
                   "p = (1 - armour/max_armour) * damage_fraction",
    "reactor_explosion": "icShockwave sim with no type flag (the default)",
    "antimatter_explosion": "icShockwave sim with antimatter=1 (+0x1e8)",
    "alien_explosion": "icShockwave sim with alien=1 (+0x1ea)",
    "ldsi_explosion": "icShockwave sim with ldsi=1 (+0x1e9)",
    "collision": "iiSim::ProcessContact -- two sims touching",
}

# iiSim::DoFinalExplosion (@0x1007c990), the ship-death recipe. Constants read
# out of the .rdata addresses named below.
DEATH = {
    "puffs": 4,                      # loop count
    "puff_radius_min": 0.3,          # @0x1011c034  radius = R * lerp(.3, .6, rand)
    "puff_radius_max": 0.6,          # @0x101192c4
    "puff_scatter": 0.4,             # @0x10117558  offset = unit_vector * R * 0.4
    "shockwave_sim": "sims/explosions/reactor_explosion",
    "shockwave_final_radius_mult": 4.0,   # @0x101190b4
    "shockwave_scale_min": 0.25,          # @0x101191ec  clamp(R/mean, .25, 4)
    "shockwave_scale_max": 4.0,
    "mean_radius_of_reactor_explosion_sim": 200.0,  # defaults.ini:446
    "note": "A dying sim spawns 4 icExplosion puffs, each of radius "
            "R*lerp(0.3,0.6,rand) scattered by a random unit vector * R*0.4, "
            "plus one reactor_explosion shockwave unless the sim sets "
            "no_shockwave=1. Each puff picks explosion/small_explosion by its "
            "OWN radius against 150 m, so only sims with R > ~250 m ever "
            "produce the big `explosion`.",
}

SMALL_EXPLOSION_THRESHOLD = 150.0


def _url(v: str) -> str:
    """LWS tag URLs escape ':/' as '||' and '/' as '|'."""
    return str(v).replace("||", ":/").replace("|", "/")


def _sound(fs: ResourceFS, url: str) -> dict:
    """Resolve ``ini:/audio/sfx/x`` (an FcSoundNode) to the wave it plays.

    The INI is an indirection, not an alias: ``audio/sfx/antimatter_explosion``
    plays ``sound:/audio/sfx/large_explosion_3``.
    """
    name = url.rsplit("/", 1)[-1]
    out = {"ini": name, "wav": name, "volume": 1.0, "min_range": 0.0}
    path = url.replace("ini:/", "") + ".ini"
    if not fs.exists(path):
        return out
    props = parse_ini(fs.read_text(path)).get("Properties", {})
    wav = str(props.get("url", "")).strip('"')
    if wav:
        out["wav"] = wav.rsplit("/", 1)[-1]
    for key in ("volume", "min_range"):
        if key in props:
            try:
                out[key] = float(props[key])
            except (TypeError, ValueError):
                pass
    return out


def _content(fs: ResourceFS, nodes: list[dict]) -> dict:
    """Classify a scene's nodes and resolve parenting (two passes).

    ``ParentObject n`` is a 1-based index into the *object* load order and may
    FORWARD-reference an object defined later in the file, so transforms can
    only be accumulated once every object has been read.
    """
    by_index = {n["index"]: n for n in nodes if n.get("index")}

    def chain(n: dict) -> list[dict]:
        out, seen = [n], {id(n)}
        while True:
            p = by_index.get(n.get("parent", 0))
            if p is None or id(p) in seen:
                break
            out.append(p)
            seen.add(id(p))
            n = p
        return out

    def scale_animates(link: dict) -> bool:
        """A link's SCALE animates (not merely: it has keys). The antimatter
        spinner nulls (``FatBeamsH`` etc.) are keyed for rotation only and must
        keep their static scale in the chain product."""
        keys = link.get("keys")
        if not keys:
            return False
        first = keys[0].get("scale")
        return any(k.get("scale") != first for k in keys)

    def resolve(n: dict) -> tuple[list[float], list]:
        """Static per-axis scale up the parent chain, plus the scale envelope.

        Effective scale at frame f is ``scale * key(f)``, so a link whose
        scale animates contributes its keys and *not* its frame-0 scale --
        otherwise a scaler that starts at 0 (``plasma_fire``'s ``scaler``, the
        antimatter ``beam_scaler_*``) would zero the whole chain.
        """
        animated = None
        scale = [1.0, 1.0, 1.0]
        for link in chain(n):
            if scale_animates(link):
                if animated is None:
                    animated = link
                continue
            s = link.get("scale") or [1.0, 1.0, 1.0]
            for i in range(3):
                scale[i] *= float(s[i])
        keys = ([[k["frame"], k["scale"][0]] for k in animated["keys"]]
                if animated else [])
        return scale, keys

    def parent_anim(n: dict) -> list[dict]:
        """The parent nulls, innermost first, with their authored motion.

        Rotation and scale channels only -- no sfx null animates position.
        A parent carries ``keys`` ([{frame, hpb, scale}], scene frames,
        degrees) only when it is actually keyframed; a static parent is just
        its frame-0 pose. NOTE a scale-animating parent's envelope is the
        node's ``scale_keys`` (see ``resolve``); consumers that use
        ``scale_keys`` must read only rotation out of ``parents`` or they
        would apply the envelope twice.
        """
        out = []
        for link in chain(n)[1:]:
            entry = {
                "name": str(link.get("name", "")),
                "hpb": link.get("hpb", [0.0, 0.0, 0.0]),
                "scale": link.get("scale") or [1.0, 1.0, 1.0],
            }
            if link.get("keys"):
                entry["keys"] = [{"frame": k["frame"], "hpb": k["hpb"],
                                  "scale": k["scale"]} for k in link["keys"]]
            out.append(entry)
        return out

    out: dict = {"systems": [], "sounds": [], "lights": [], "avatars": [],
                 "movie": None}
    for n in nodes:
        kind = n.get("kind")
        if kind == "light":
            light = {
                "color": n.get("color", [255, 255, 255]),
                "range": n.get("range", 0.0),
                "lens_flare": bool(n.get("lens_flare", False)),
                "light_type": n.get("light_type", 1),
                "name": n.get("name", ""),
            }
            if "intensity_envelope" in n:
                light["envelope"] = n["intensity_envelope"]
            else:
                light["intensity"] = n.get("intensity", 0.0)
            out["lights"].append(light)
            continue
        if kind != "node":
            continue
        scale, keys = resolve(n)
        if "template" in n:
            url = _url(n["template"])
            if url.startswith("ini:/audio/"):
                out["sounds"].append(_sound(fs, url))
            elif url.startswith("ini:/sfx/"):
                # ini:/sfx/<name>/node -> the particle system <name>
                # (every authored system/movie scale is uniform, so the
                # scalar is lossless here; avatars get the full vector)
                out["systems"].append({
                    "name": url.split("/")[2], "scale": scale[0],
                    "scale_keys": keys,
                })
            continue
        cls = n.get("class")
        if cls == "icMovieAvatar":
            out["movie"] = {
                "texture": _url(n.get("url", "")).replace("texture:/", ""),
                "frames": int(n.get("frame_count", 0)),
                "scale": scale[0],
            }
        elif cls:
            av = {"class": cls, "scale": scale[0], "scale_xyz": scale,
                  "scale_keys": keys, "hpb": n.get("hpb", [0.0, 0.0, 0.0])}
            for k in ("tint", "lifetime", "texture"):
                if k in n:
                    av[k] = n[k]
            parents = parent_anim(n)
            if parents:
                av["parents"] = parents
            out["avatars"].append(av)
    return out


def _tint(av: dict) -> None:
    """'(0.4,1.0,0.2)' -> [0.4, 1.0, 0.2]."""
    t = av.get("tint")
    if isinstance(t, str):
        try:
            av["tint"] = [float(x) for x in t.strip("()").split(",")]
        except ValueError:
            del av["tint"]


def build(fs: ResourceFS) -> dict:
    effects: dict = {}
    for i, name in enumerate(EFFECTS):
        variants: dict = {"low": None, "high": []}
        for suffix in ["low"] + [f"high_{k}" for k in range(3)]:
            path = f"sfx/{name}_{suffix}.lws"
            if not fs.exists(path):
                continue
            scene = parse_scene(fs.read_text(path))
            v = _content(fs, scene["nodes"])
            v["fps"] = scene["fps"]
            v["last_frame"] = scene["last_frame"]
            for av in v["avatars"]:
                _tint(av)
            if suffix == "low":
                variants["low"] = v
            else:
                variants["high"].append(v)
        effects[name] = {
            "index": i,
            "size_weight": SIZE_WEIGHT[i],
            "event": EVENTS[name],
            "variants": variants,
        }
    return {
        "_source": "sfx/*.lws in resource.zip, plus icVisualEffects in iwar2.dll",
        "engine": {
            "cull_detail": CULL_DETAIL,
            "low_detail": LOW_DETAIL,
            "small_explosion_threshold": SMALL_EXPLOSION_THRESHOLD,
            "lod": "apparent = size * size_weight / distance; < cull_detail: "
                   "cull; < low_detail: the `low` scene; else a random `high_%d`",
            "death": DEATH,
        },
        "effects": effects,
    }


def main(out_path: str = "data/json/sfx_effects.json") -> None:
    fs = ResourceFS()
    table = build(fs)
    dest = Path(out_path)
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_text(json.dumps(table, indent=1), encoding="utf-8")
    n_hi = sum(len(e["variants"]["high"]) for e in table["effects"].values())
    n_lo = sum(1 for e in table["effects"].values() if e["variants"]["low"])
    print(f"sfx: {len(table['effects'])} effects, {n_hi} high + {n_lo} low "
          f"scenes -> {dest}")


if __name__ == "__main__":
    main(*sys.argv[1:])
