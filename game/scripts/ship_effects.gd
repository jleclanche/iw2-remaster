class_name ShipEffects
extends Node
# The original's channel-driven effect rig (FcChannelGeneratorNode +
# icFlameConeAvatar). Ship state feeds named channels; avatar nodes tagged
# <anim channel=...> interpolate between their two exported poses by the
# channel value, and flame-cone nodes get an additive cone mesh.
#
# Channel strings are EXPRESSIONS in the original's little language
# (seen across avatars/*.lws):
#   "LZ?+s(1.0)"              positive fore thrust, smoothed over 1 s
#   "RP?+j(0.1) LY?+j(0.1)"   RCS jet: pitch-up OR thrust-up, 0.1 s puff
#   "fire?o(5.0)"             one-shot pulse on fire event, fast decay
# Terms are separated by spaces and combined with max(). Raw inputs:
# LZ/LX/LY (thrusters), RP/RY/RR (rotation demands), burn, fire, dock.
# The tug's channels.ini also derives: flame/core/boom/flap from lz/burn.

var ship: ShipFlight
var anim_nodes: Array = []   # {node, channel, p0..s1}
var exprs: Dictionary = {}   # channel string -> {terms: Array, value: float}
var fire_pulse := 0.0        # set by weapons fire events
var _lz_smooth := 0.0
var _burn_smooth := 0.0
var _term_re: RegEx

static func attach(to_ship: ShipFlight, model: Node3D) -> ShipEffects:
	var fx := ShipEffects.new()
	fx.ship = to_ship
	fx._scan(model)
	to_ship.add_child(fx)
	to_ship.fx = fx
	return fx

static func graft_jets(target_model: Node3D, donor: Node3D) -> void:
	# move the donor's RCS jet rigs (anim channels with j() envelopes) onto
	# the target — the tug's jets live on its command section
	var anchor: Node3D = null
	for n in target_model.find_children("*", "Node3D", true, false):
		if "commandsection" in str(n.name).to_lower():
			anchor = n
			break
	if anchor == null:
		anchor = target_model
	var jets: Array = []
	for n in donor.find_children("*", "Node3D", true, false):
		if n.has_meta("extras"):
			var ex: Dictionary = n.get_meta("extras")
			if str(ex.get("iw2_kind", "")) == "anim" \
					and "j(" in str(ex.get("iw2_channel", "")):
				jets.append(n)
	for n in jets:
		var t: Transform3D = n.transform
		_clear_owner(n)
		n.get_parent().remove_child(n)
		anchor.add_child(n)
		n.transform = t
	donor.queue_free()

static func _clear_owner(n: Node) -> void:
	n.owner = null
	for c in n.get_children():
		_clear_owner(c)

func _extras(n: Node) -> Dictionary:
	return n.get_meta("extras") if n.has_meta("extras") else {}

func _scan(model: Node3D) -> void:
	_term_re = RegEx.new()
	_term_re.compile("^(\\w+)([?#])?([+-])?(.*)$")
	for n in model.find_children("*", "Node3D", true, false):
		var ex := _extras(n)
		if str(ex.get("iw2_kind", "")) == "anim" and ex.has("iw2_pose0"):
			var p0: Dictionary = ex["iw2_pose0"]
			var p1: Dictionary = ex["iw2_pose1"]
			var ch := str(ex.get("iw2_channel", ""))
			anim_nodes.append({
				"node": n, "channel": ch,
				"p0": _v3(p0["pos"]), "q0": _quat(p0["quat"]), "s0": _v3(p0["scale"]),
				"p1": _v3(p1["pos"]), "q1": _quat(p1["quat"]), "s1": _v3(p1["scale"]),
			})
			if not exprs.has(ch) and not ch in ["flame", "core", "boom", "flap"]:
				exprs[ch] = {"terms": _parse_expr(ch), "value": 0.0}
		if str(ex.get("iw2_class", "")) == "icFlameConeAvatar":
			_add_flame_cone(n as Node3D, ex)

func _parse_expr(expr: String) -> Array:
	var terms: Array = []
	for tok in expr.split(" ", false):
		var m := _term_re.search(tok)
		if m == null:
			continue
		var mods: Array = []
		var mod_re := RegEx.new()
		mod_re.compile("([sjo])\\(([0-9.]+)\\)")
		for mm in mod_re.search_all(m.get_string(4)):
			mods.append([mm.get_string(1), float(mm.get_string(2))])
		terms.append({"input": m.get_string(1).to_lower(),
				"sign": m.get_string(3), "mods": mods, "state": 0.0,
				"last": 0.0})
	return terms

func _eval_term(term: Dictionary, raw: Dictionary, delta: float) -> float:
	var v: float = raw.get(term["input"], 0.0)
	match term["sign"]:
		"+": v = maxf(v, 0.0)
		"-": v = maxf(-v, 0.0)
		_: v = absf(v)
	for mod in term["mods"]:
		var tau: float = mod[1]
		match mod[0]:
			"s":  # first-order smooth
				term["state"] += (v - term["state"]) * minf(delta / maxf(tau, 0.01), 1.0)
				v = term["state"]
			"j":  # jet: instant attack, tau-second decay
				term["state"] = maxf(v, term["state"] - delta / maxf(tau, 0.01))
				v = term["state"]
			"o":  # one-shot: pulse on rising edge, decay at rate tau/s
				if v > 0.5 and term["last"] <= 0.5:
					term["state"] = 1.0
				term["state"] = maxf(0.0, term["state"] - tau * delta * 0.5)
				term["last"] = v
				v = term["state"]
	return v

func _v3(a: Array) -> Vector3:
	return Vector3(a[0], a[1], a[2])

func _quat(a: Array) -> Quaternion:
	return Quaternion(a[0], a[1], a[2], a[3]).normalized()

func _add_flame_cone(node: Node3D, ex: Dictionary) -> void:
	var tint := Color(1.0, 0.7, 0.2)
	var t := str(ex.get("iw2_tint", ""))
	var floats: Array = []
	for part in t.trim_prefix("(").trim_suffix(")").split(","):
		if part.strip_edges().is_valid_float():
			floats.append(float(part.strip_edges()))
	if floats.size() >= 3:
		tint = Color(floats[0], floats[1], floats[2])
	var splay := float(ex.get("iw2_splay", 1.0))
	var mesh := CylinderMesh.new()
	mesh.top_radius = 0.5 * splay  # base of the cone at the nozzle
	mesh.bottom_radius = 0.02
	mesh.height = 1.0
	mesh.radial_segments = 12
	mesh.cap_top = false
	mesh.cap_bottom = false
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.albedo_color = Color(tint.r, tint.g, tint.b, 0.55)
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mesh.material = mat
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	# cone along the parent's local -Z (LW-authored +Z, flipped by our
	# coordinate convention); the <anim> null's negative z scale keys then
	# stretch it backward out of the nozzle
	mi.rotation_degrees = Vector3(90, 0, 0)
	mi.position = Vector3(0, 0, -0.5)
	node.add_child(mi)

func _physics_process(delta: float) -> void:
	if ship == null:
		return
	# raw ship-state inputs for the channel language
	var v_local: Vector3 = ship.velocity * ship.global_transform.basis
	var burn := 0.0
	if ship.drive_override:
		burn = 1.0
	elif absf(ship.input_thrust.z) > 0.05:
		burn = absf(ship.input_thrust.z)
	elif ship.assist:
		burn = clampf((ship.set_speed + v_local.z) / 80.0, 0.0, 1.0)
	fire_pulse = maxf(0.0, fire_pulse - delta * 4.0)
	var raw := {
		"lz": ship.input_thrust.z, "lx": ship.input_thrust.x,
		"ly": ship.input_thrust.y,
		"rp": ship.input_rotate.x, "ry": ship.input_rotate.y,
		"rr": ship.input_rotate.z,
		"burn": burn, "fire": fire_pulse, "dock": 0.0,
	}
	# tug channels.ini: smoothed lz/burn -> flame/core/boom/flap
	_lz_smooth += (clampf(absf(raw["lz"]), 0.0, 1.0) - _lz_smooth) \
		* minf(delta / 0.75, 1.0)
	_burn_smooth += (burn - _burn_smooth) * minf(delta / 1.0, 1.0)
	var named := {
		"flame": maxf(_lz_smooth, _burn_smooth),
		"core": _burn_smooth,
		"boom": _burn_smooth,
		"flap": maxf(_lz_smooth, _burn_smooth),
	}
	for ch in exprs:
		var e: Dictionary = exprs[ch]
		var best := 0.0
		for term in e["terms"]:
			best = maxf(best, _eval_term(term, raw, delta))
		e["value"] = best
	for entry in anim_nodes:
		var n: Node3D = entry["node"]
		if not is_instance_valid(n):
			continue
		var t: float
		if named.has(entry["channel"]):
			t = named[entry["channel"]]
		elif exprs.has(entry["channel"]):
			t = exprs[entry["channel"]]["value"]
		else:
			t = 0.0
		var q: Quaternion = (entry["q0"] as Quaternion).slerp(entry["q1"], t)
		var b := Basis(q).scaled_local(
			(entry["s0"] as Vector3).lerp(entry["s1"], t))
		n.transform = Transform3D(b, (entry["p0"] as Vector3).lerp(entry["p1"], t))
