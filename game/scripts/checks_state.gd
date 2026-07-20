extends Node
# Check-suite shared state and cross-suite helpers.
# Part of the checks extends chain (issue #31):
# checks_state <- checks_probes <- checks_camp <- checks_base <-
# checks_jump <- checks_mech <- checks.gd (CheckRunner, the dispatcher).
# Same node, same class -- the split mirrors main.gd's layered-file scheme.

var m: Node3D  # main

var demo_t := 0.0
var demo_phase := 0
var _demo_logged := 0.0
var _mc_shot := 0
var _mech_fail := 0
var _mech_t0 := 0.0
var _mech_v0 := Vector3.ZERO
var _mech_home := Vector3.ZERO
var _mech_gs: AiShip = null      # turret platform (gunstar.ini)
var _mech_drone: AiShip = null   # turret / beam target
var _mech_beam: Dictionary = {}  # the beam mount under test
var _mech_field: Dictionary = {} # synthetic icFieldSphere for the fields phase

func _shot(name: String) -> void:
	var img := get_viewport().get_texture().get_image()
	img.save_png(m._base().path_join("data/screenshots/%s.png" % name))


## icShadyBar is a TRANSLUCENT column: black fill at m_bar_alpha 0.8 with additive
## passes that only ever add m_detail_alpha 0.1 and m_edge_alpha 0.2 on top. So a
## base screen's bar must stay dark, and the interior behind it must read through.
##
## This exists because the additive passes are accumulated into a per-frame rect
## list, and every way that list can go wrong -- not cleared, appended twice, kept
## across a screen change -- looks identical: the column saturates to solid amber
## and eats the screen. Every check in the suite still passed while it did, because
## nothing here had ever looked at a PIXEL. Renderer-only regressions need a
## renderer-level assertion, so this samples the real thing.
## Judged on the MEDIAN of a patch, not on any single sample: the bar carries
## amber text, which is legitimately bright, so "no pixel is bright" is not the
## property. "Most of the column is dark" is, and it does not depend on picking
func _charge_guns() -> void:
	if m.sys == null:
		return
	for sub: Dictionary in m.sys.systems:
		if sub["class"] == "icCannon":
			sub["energy"] = float(sub.get("capacity", 0.0))

# a bare AiShip for the turret/beam phases: no INI (sys == null), so damage
