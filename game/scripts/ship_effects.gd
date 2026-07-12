class_name ShipEffects
extends Node
# The original's channel-driven effect rig (FcChannelGeneratorNode +
# icFlameConeAvatar). Ship state feeds named channels; avatar nodes tagged
# <anim channel=X> interpolate between their two exported poses by the
# channel value, and flame-cone nodes get an additive cone mesh. This is
# how the tug's engine booms swivel, flaps open, and flames stretch with
# the burn — per avatars/*/channels.ini:
#   lz_smooth   = smoothed fore/aft thruster demand   (s = 0.75)
#   burn_smooth = smoothed main drive burn            (s = 1.0)
#   flame = f(lz, burn), core/boom/flap follow burn

var ship: ShipFlight
var anim_nodes: Array = []  # {node, channel, p0, q0, s0, p1, q1, s1}
var channels := {"flame": 0.0, "core": 0.0, "boom": 0.0, "flap": 0.0}
var _lz_smooth := 0.0
var _burn_smooth := 0.0

static func attach(to_ship: ShipFlight, model: Node3D) -> ShipEffects:
	var fx := ShipEffects.new()
	fx.ship = to_ship
	fx._scan(model)
	to_ship.add_child(fx)
	return fx

func _extras(n: Node) -> Dictionary:
	if n.has_meta("extras"):
		return n.get_meta("extras")
	# GLTFDocument may also flatten extras into individual meta keys
	var out := {}
	for k in n.get_meta_list():
		out[k] = n.get_meta(k)
	return out

func _scan(model: Node3D) -> void:
	for n in model.find_children("*", "Node3D", true, false):
		var ex := _extras(n)
		if str(ex.get("iw2_kind", "")) == "anim" and ex.has("iw2_pose0"):
			var p0: Dictionary = ex["iw2_pose0"]
			var p1: Dictionary = ex["iw2_pose1"]
			anim_nodes.append({
				"node": n, "channel": str(ex.get("iw2_channel", "")),
				"p0": _v3(p0["pos"]), "q0": _quat(p0["quat"]), "s0": _v3(p0["scale"]),
				"p1": _v3(p1["pos"]), "q1": _quat(p1["quat"]), "s1": _v3(p1["scale"]),
			})
		if str(ex.get("iw2_class", "")) == "icFlameConeAvatar":
			_add_flame_cone(n as Node3D, ex)

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

func set_input_channels(lz: float, burn: float, delta: float) -> void:
	# channels.ini smoothing: x?+s(tau)
	_lz_smooth += (clampf(lz, 0.0, 1.0) - _lz_smooth) * minf(delta / 0.75, 1.0)
	_burn_smooth += (clampf(burn, 0.0, 1.0) - _burn_smooth) * minf(delta / 1.0, 1.0)
	channels["flame"] = maxf(_lz_smooth, _burn_smooth)
	channels["core"] = _burn_smooth
	channels["boom"] = _burn_smooth
	channels["flap"] = maxf(_lz_smooth, _burn_smooth)

func _physics_process(delta: float) -> void:
	if ship == null:
		return
	# burn: is the main drive firing? (assist demand or direct fore thrust)
	var v_local: Vector3 = ship.velocity * ship.global_transform.basis
	var burn := 0.0
	if ship.drive_override:
		burn = 1.0
	elif absf(ship.input_thrust.z) > 0.05:
		burn = absf(ship.input_thrust.z)
	elif ship.assist:
		burn = clampf((-ship.set_speed - v_local.z) / -80.0, 0.0, 1.0)
	set_input_channels(absf(ship.input_thrust.z), burn, delta)
	for entry in anim_nodes:
		var n: Node3D = entry["node"]
		if not is_instance_valid(n):
			continue
		var t: float = channels.get(entry["channel"], 0.0)
		var q: Quaternion = (entry["q0"] as Quaternion).slerp(entry["q1"], t)
		var b := Basis(q).scaled_local(
			(entry["s0"] as Vector3).lerp(entry["s1"], t))
		n.transform = Transform3D(b, (entry["p0"] as Vector3).lerp(entry["p1"], t))
