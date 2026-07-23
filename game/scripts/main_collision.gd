# Main layer: collision spheres and the stations' CollisionHull trimeshes.
# Part of main.gd's extends chain -- see
# main_state.gd for the scheme. Same node, same class.
extends "main_flight.gd"

# The collision damage law (iwar2, the collide handler directly above
# iiSim::OnCollision @ 0x10078ab0): each party's velocity CHANGE from the
# response is normalised by collision_damage_sweet_speed, and ONE damage
# number -- (|dv_a|/sweet)^2 * mass_a + (|dv_b|/sweet)^2 * mass_b, times
# collision_damage_factor -- is applied to BOTH ships as source-4 damage.
# The constants are the game's own: flux.ini/defaults.ini
# collision_damage_sweet_speed = 600, collision_damage_factor = 3.5.
const COLLISION_SWEET := 600.0
const COLLISION_FACTOR := 3.5

func _collision_damage(dv_a: float, m_a: float, dv_b: float, m_b: float) -> float:
	var na := dv_a / COLLISION_SWEET
	var nb := dv_b / COLLISION_SWEET
	return (na * na * m_a + nb * nb * m_b) * COLLISION_FACTOR

# FiSim::ProcessContact (flux.dll @ 0x100bd920) -- the collision RESPONSE law:
#   gate:    (vp_a - vp_b).n > 0.1 -> no response (@ 0x100ece2c); vp is the
#            CONTACT-POINT velocity, v + w x r
#   unwind:  each party not more than twice as heavy as the other backs out
#            along the normal by 1.1 frames of its own speed, and unwinds its
#            rotation by the same 1.1 frames (-1.1 @ 0x100edb50)
#   impulse: j = 1.5 * approach / (1/m_a + 1/m_b
#                + n.((I^-1_a (r_a x n)) x r_a) + n.((I^-1_b (r_b x n)) x r_b))
#            (-1.5 @ 0x100edb4c = -(1+e): restitution 0.5). FiSim stores
#            MOMENTUM (+0x110 linear, +0x11c angular): p_a -= j*n,
#            L_a -= r_a x j*n, the partner gets the opposite, then
#            v = p/m and w = I^-1 L.
# A massless partner is FiSim::SetMass(0): 1/m stored as 0 -- immovable
# (flux @ 0x100bcbb0). Contacts of docked children forward to the stack
# parent (+0x164), which carries the summed mass and tensor.
const CONTACT_RESTITUTION := 1.5   # -(1+e) @ 0x100edb4c
const CONTACT_UNWIND := 1.1        # -1.1 @ 0x100edb50, frames of own travel
const CONTACT_APPROACH_GATE := 0.1 # @ 0x100ece2c, m/s

# Contact FEEDBACK: the original's collide handler fires per contact event,
# so scraping along a hull is audible even when the damage rounds to zero.
# One clatter per cooldown window; the damage/log line keeps its own gate.
var _contact_sound_cd := 0.0

func _contact_feedback(dv: float, speed_rel: float, what: String) -> void:
	if dv > 0.05:
		damage_player(_collision_damage(dv, maxf(ship.mass, 1.0), 0.0, 0.0),
				"COLLISION - " + what)
	if _contact_sound_cd <= 0.0 and (dv > 0.05 or speed_rel > 1.0):
		_contact_sound_cd = 0.35
		audio.play("audio/sfx/collision.wav", -3.0 if dv > 0.05 else -14.0)
		audio.play("audio/sfx/ship_clatter.wav", -8.0 if dv > 0.05 else -16.0)

func _contact_angular_term(s: ShipFlight, r: Vector3, n: Vector3) -> float:
	# n . ((I^-1 (r x n)) x r): the contact's angular admittance, with the
	# diagonal body-frame box tensor (ShipFlight.moi)
	if s == null or s.moi.x <= 0.0 or s.moi.y <= 0.0 or s.moi.z <= 0.0:
		return 0.0
	var b := s.global_transform.basis
	var rxn_l: Vector3 = r.cross(n) * b
	var t := Vector3(rxn_l.x / s.moi.x, rxn_l.y / s.moi.y, rxn_l.z / s.moi.z)
	return n.dot((b * t).cross(r))

func _contact_spin(s: ShipFlight, r: Vector3, dp: Vector3) -> void:
	# dL = r x dp; dw = I^-1 dL (angular_velocity is body-frame)
	if s.moi.x <= 0.0 or s.moi.y <= 0.0 or s.moi.z <= 0.0:
		return
	var dl: Vector3 = r.cross(dp) * s.global_transform.basis
	s.angular_velocity += Vector3(dl.x / s.moi.x, dl.y / s.moi.y, dl.z / s.moi.z)

func _contact_unspin(s: ShipFlight, delta: float) -> void:
	# the unwind's rotation half: the quaternion integrated by -1.1 frames
	var back := s.angular_velocity * (-delta * CONTACT_UNWIND)
	s.rotate_object_local(Vector3.RIGHT, back.x)
	s.rotate_object_local(Vector3.UP, back.y)
	s.rotate_object_local(Vector3.BACK, back.z)

## The response, player = party A. `partner` null = a massless obstacle
## moving at `partner_vel` (its dv term is 0 and it cannot be pushed).
## `n` points from the partner toward the player. Returns the two speed
## changes |j|/m -- the inputs of the collision damage law above.
func _process_contact(point: Vector3, n: Vector3, partner: ShipFlight,
		partner_vel: Vector3, delta: float) -> Vector2:
	var inv_m_a := 1.0 / maxf(ship.mass, 1e-6)
	var r_a := point - ship.global_position
	var w_a: Vector3 = ship.global_transform.basis * ship.angular_velocity
	var vp_a: Vector3 = ship.velocity + w_a.cross(r_a)
	var inv_m_b := 0.0
	var r_b := Vector3.ZERO
	var vp_b := partner_vel
	if partner != null:
		inv_m_b = 1.0 / partner.mass if partner.mass > 1e-6 else 0.0
		r_b = point - partner.global_position
		var w_b: Vector3 = partner.global_transform.basis \
				* partner.angular_velocity
		vp_b = partner.velocity + w_b.cross(r_b)
	var approach := (vp_a - vp_b).dot(n)
	if approach > CONTACT_APPROACH_GATE:
		return Vector2.ZERO
	# positional unwind first (the original's order), on pre-impulse speeds
	if inv_m_b <= 2.0 * inv_m_a:
		ship.global_position += n \
				* (ship.velocity.length() * delta * CONTACT_UNWIND)
		_contact_unspin(ship, delta)
	if partner != null and inv_m_a <= 2.0 * inv_m_b:
		partner.global_position -= n \
				* (partner.velocity.length() * delta * CONTACT_UNWIND)
		_contact_unspin(partner, delta)
	var denom := inv_m_a + inv_m_b + _contact_angular_term(ship, r_a, n)
	if partner != null:
		denom += _contact_angular_term(partner, r_b, n)
	if denom <= 1e-9:
		return Vector2.ZERO
	var j := CONTACT_RESTITUTION * approach / denom  # < 0 on approach
	ship.velocity -= n * (j * inv_m_a)
	_contact_spin(ship, r_a, n * -j)
	if partner != null and inv_m_b > 0.0:
		partner.velocity += n * (j * inv_m_b)
		_contact_spin(partner, r_b, n * j)
	return Vector2(absf(j) * inv_m_a, absf(j) * inv_m_b)

func _collide_sphere(center: Vector3, radius: float, vel: Vector3,
		what: String) -> void:
	# the player against a MASSLESS-partner obstacle (stations, props, field
	# rocks): the partner contributes no dv term and takes no damage
	var d := ship.global_position - center
	var dist := d.length()
	if dist >= radius or dist < 0.1:
		return
	var n := d / dist
	var dv := _process_contact(center + n * radius, n, null, vel,
			get_physics_process_delta_time())
	# damage/log above 0.05 m/s dv (below it the hp rounds to ~1e-3);
	# the clatter also fires for a moving scrape, on a cooldown -- silent
	# sliding along a hull reads as "collision is gone"
	_contact_feedback(dv.x, (ship.velocity - vel).length(), what.to_upper())
	# port-side safety net: our detector reports penetration (a point test),
	# not surface contact, so never leave the ship inside the sphere
	d = ship.global_position - center
	dist = d.length()
	if dist < radius and dist > 0.1:
		ship.global_position = center + d / dist * radius

# --- station collision hulls -------------------------------------------------
# The original's REAL collision geometry: every station ini names a
# CollisionHull (collision_hull:/collisionhulls/*, a low-poly triangle mesh;
# tools/iw2/lwo.py converts them to data/json/collisionhulls/*.json, and
# stations.json carries each ini's reference). 40 of 41 station records have
# one. The per-mesh sphere blobs below remain only as the fallback -- on
# sprawling open frames like Hoffer's Gap they were solid in the wrong places.
const HULL_LAYER := 1 << 5   # a private physics layer; nothing else uses physics
const SHIP_HULL_LAYER := 1 << 6  # AI ships' own hull trimeshes (see _collide_ai)

var _hull_avatar_index := {}   # "avatars/x/setup.gltf" -> hull json path
var _probe_shape: SphereShape3D

func _hull_index() -> Dictionary:
	if not _hull_avatar_index.is_empty():
		return _hull_avatar_index
	var f := FileAccess.open(_base().path_join("data/json/stations.json"),
			FileAccess.READ)
	if f == null:
		_hull_avatar_index["<none>"] = ""
		return _hull_avatar_index
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if parsed is Array:
		for rec: Dictionary in parsed:
			var av := str(rec.get("avatar", "")).trim_prefix("lws:/").to_lower()
			var ch := str(rec.get("collision_hull", "")) \
					.trim_prefix("collision_hull:/").to_lower()
			if av.is_empty() or ch.is_empty():
				continue
			_hull_avatar_index[av + ".gltf"] = "data/json/" + ch + ".json"
	return _hull_avatar_index

func _build_hull_body(hull_path: String, layer: int) -> StaticBody3D:
	# Shared CollisionHull trimesh loader, used for stations (HULL_LAYER) and AI
	# ships (SHIP_HULL_LAYER): a converted hull json -> two-sided
	# ConcavePolygonShape3D StaticBody on a private layer, mask 0.
	var f := FileAccess.open(_base().path_join(hull_path), FileAccess.READ)
	if f == null:
		return null
	var h: Variant = JSON.parse_string(f.get_as_text())
	if not (h is Dictionary):
		return null
	var pts: Array = h.get("points", [])
	var tris: Array = h.get("triangles", [])
	if pts.is_empty() or tris.is_empty():
		return null
	var faces := PackedVector3Array()
	faces.resize(tris.size() * 3)
	var n := 0
	for t: Array in tris:
		for idx in t:
			var p: Array = pts[int(idx)]
			# the JSON is ALREADY in the glTF/engine frame: tools/iw2/lwo.py
			# negates Z at export. Negating again here mirrored every hull
			# (Lucrecia's Base collision sat 5 km behind the visible base;
			# Hoffer's Gap was hollow where its walls are and solid where
			# they are not -- fly in, never fly out).
			faces[n] = Vector3(float(p[0]), float(p[1]), float(p[2]))
			n += 1
	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(faces)
	# solid from BOTH sides. One-sided walls depend on triangle winding --
	# which the export's handedness flip inverts -- and quietly wave through
	# any ship that ends up inside; the probe orients the response normal
	# toward the ship anyway, so two-sided costs nothing.
	shape.backface_collision = true
	var body := StaticBody3D.new()
	body.collision_layer = layer
	body.collision_mask = 0
	var cs := CollisionShape3D.new()
	cs.shape = shape
	body.add_child(cs)
	return body

func _attach_collision_hull(o: Dictionary, model: Node3D) -> bool:
	var hull_path: String = _hull_index().get(str(o.get("avatar", "")).to_lower(), "")
	if hull_path.is_empty():
		return false
	var body := _build_hull_body(hull_path, HULL_LAYER)
	if body == null:
		return false
	model.add_child(body)
	o["hull"] = true
	return true

# --- AI ship collision hulls -------------------------------------------------
# Ships carry the SAME authored CollisionHull as stations (ships.json
# collision_hull:/, 134 records). Attached lazily -- only when a ship comes
# within contact range -- so distant traffic costs nothing. Feeding _collide_ai
# a REAL off-centre surface point + normal is what lets the response reorient a
# hull: the old centre-to-centre contact had r x n = 0 (a purely central bounce
# that could reorient neither party -- the "dumb bounce"). See docs/original.md
# 5h and FiSim::ProcessContact (flux @ 0x100bd920).
var _ship_hull_avatar_index := {}   # "cutter/setup" -> hull json path

func _ship_hull_index() -> Dictionary:
	if not _ship_hull_avatar_index.is_empty():
		return _ship_hull_avatar_index
	var f := FileAccess.open(_base().path_join("data/json/ships.json"),
			FileAccess.READ)
	if f == null:
		_ship_hull_avatar_index["<none>"] = ""
		return _ship_hull_avatar_index
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if parsed is Array:
		for rec: Dictionary in parsed:
			var av := str(rec.get("avatar", "")) \
					.trim_prefix("lws:/avatars/").to_lower()
			var ch := str(rec.get("collision_hull", "")) \
					.trim_prefix("collision_hull:/").to_lower()
			if av.is_empty() or ch.is_empty():
				continue
			_ship_hull_avatar_index[av] = "data/json/" + ch + ".json"
	if _ship_hull_avatar_index.is_empty():
		_ship_hull_avatar_index["<none>"] = ""
	return _ship_hull_avatar_index

func _ensure_ship_hull(a: AiShip) -> StaticBody3D:
	# lazily attach a's hull trimesh to its node; cache the body (or a null
	# sentinel for a hull-less / avatar-less ship) so the lookup runs once. The
	# gltf model rides the AI node at identity, so the hull's model-frame json
	# aligns with the node's own frame -- parent to the node so it tracks pose.
	if a.has_meta("hull_body"):
		var cached: Variant = a.get_meta("hull_body")
		return cached if is_instance_valid(cached) else null
	var key := a.avatar_path.trim_prefix("data/avatars/avatars/") \
			.trim_suffix(".gltf").to_lower()
	var hull_path: String = _ship_hull_index().get(key, "")
	if hull_path.is_empty():
		a.set_meta("hull_body", null)
		return null
	var body := _build_hull_body(hull_path, SHIP_HULL_LAYER)
	if body == null:
		a.set_meta("hull_body", null)
		return null
	body.set_meta("ai", a)
	a.add_child(body)
	a.set_meta("hull_body", body)
	return body

var _player_box: BoxShape3D
var _player_box_dims := Vector3.ZERO

func _player_box_probe() -> BoxShape3D:
	# the player's contact proxy for ship-ship: the ship's AUTHORED bounding box
	# (ini w/h/l) -- the very box the engine already models the hull as for mass
	# and the diagonal inertia tensor (ship_flight.recalc_moi / iiThrusterSim::
	# Load @ 0x1007ddf0). A sphere proxy can NEVER torque the player (a sphere's
	# contact normal is radial, so r_a x n = 0); the box's corners produce the
	# off-CoM contact the original's real hull does, so the player tumbles too.
	var dims := ship.dims if ship.dims.length() > 1.0 else Vector3(40, 40, 40)
	if _player_box == null or _player_box_dims != dims:
		_player_box = BoxShape3D.new()
		_player_box.size = dims
		_player_box_dims = dims
	return _player_box

func _player_box_support(n: Vector3) -> float:
	# half-extent of the player box along world normal n -- the penetration
	# reference for the depenetration safety net
	var nl: Vector3 = n * ship.global_transform.basis   # world -> local
	var h := (ship.dims if ship.dims.length() > 1.0 else Vector3(40, 40, 40)) * 0.5
	return absf(nl.x) * h.x + absf(nl.y) * h.y + absf(nl.z) * h.z

func _collide_hull(o: Dictionary) -> void:
	# swept-sphere test of the player against the station's hull trimesh,
	# answered with the same bounce/damage response as _collide_sphere
	if _probe_shape == null:
		_probe_shape = SphereShape3D.new()
		_probe_shape.radius = 20.0   # the player hull's rough half-width
	var node: Node3D = o["node"]
	# cheap reject: outside the record's own bounding radius + margin
	var r := maxf(float(o.get("radius", 0.0)), 500.0)
	if ship.global_position.distance_squared_to(node.global_position) \
			> (r + 4000.0) * (r + 4000.0):
		return
	# null for the one frame the outgoing scene still ticks after a reload
	var world := get_world_3d()
	if world == null:
		return
	var params := PhysicsShapeQueryParameters3D.new()
	params.shape = _probe_shape
	params.transform = Transform3D(Basis(), ship.global_position)
	params.collision_mask = HULL_LAYER
	var hit: Dictionary = world.direct_space_state.get_rest_info(params)
	if hit.is_empty():
		return
	var point: Vector3 = hit["point"]
	var n: Vector3 = hit["normal"]
	# orient the normal off the surface toward the ship
	if n.dot(ship.global_position - point) < 0.0:
		n = -n
	var dv := _process_contact(point, n, null, Vector3.ZERO,
			get_physics_process_delta_time())
	_contact_feedback(dv.x, ship.velocity.length(), str(o["name"]).to_upper())
	# port-side safety net: stay outside the surface our probe found
	if (ship.global_position - point).dot(n) < _probe_shape.radius:
		ship.global_position = point + n * (_probe_shape.radius + 0.5)

func _model_coll_spheres(model: Node3D) -> Array:
	# one collision sphere per major mesh chunk (model-local), so sprawling
	# structures like Hoffer's Gap are solid where their geometry actually
	# is — a single capped sphere either blocked docking or did nothing
	var spheres: Array = []
	var inv := model.global_transform.affine_inverse()
	for mi in model.find_children("*", "MeshInstance3D", true, false):
		var bb: AABB = (mi as MeshInstance3D).get_aabb()
		var tb := (inv * (mi as Node3D).global_transform) * bb
		var r := tb.size.length() * 0.4
		if r < 25.0:
			continue  # greebles/lights don't need physics
		spheres.append({"c": tb.get_center(), "r": minf(r, 1500.0)})
	spheres.sort_custom(func(a, b): return a["r"] > b["r"])
	return spheres.slice(0, 24)

func _model_radius(model: Node3D, fallback: float) -> float:
	# collision sphere for a streamed avatar — the map/record radii are
	# zone numbers, not hull sizes
	var r := _model_bounds_radius(model)
	if r <= 0.0:
		return fallback
	# spheres are crude: cap so docking approaches (and the F6 autopilot's
	# 600 m arrival) still get inside; big-station avatars also carry
	# far-flung light nulls that would blow the AABB up to km scale
	return clampf(r * 0.66, minf(fallback, 400.0) * 0.5, 450.0)
