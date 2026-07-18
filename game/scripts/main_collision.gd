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

func _collide_sphere(center: Vector3, radius: float, vel: Vector3,
		what: String) -> void:
	# the player against a MASSLESS-partner obstacle (stations, props, field
	# rocks): the partner contributes no dv term and takes no damage
	var d := ship.global_position - center
	var dist := d.length()
	if dist >= radius or dist < 0.1:
		return
	var n := d / dist
	var rel: float = (ship.velocity - vel).dot(n)
	if rel < 0.0:
		ship.velocity -= n * rel * 1.6  # bounce off (response stand-in)
		damage_player(_collision_damage(-rel * 1.6, maxf(ship.mass, 1.0),
				0.0, 0.0), "COLLISION - " + what.to_upper())
		audio.play("audio/sfx/collision.wav", -3.0)
		audio.play("audio/sfx/ship_clatter.wav", -8.0)
	ship.global_position = center + n * radius

# --- station collision hulls -------------------------------------------------
# The original's REAL collision geometry: every station ini names a
# CollisionHull (collision_hull:/collisionhulls/*, a low-poly triangle mesh;
# tools/iw2/lwo.py converts them to data/json/collisionhulls/*.json, and
# stations.json carries each ini's reference). 40 of 41 station records have
# one. The per-mesh sphere blobs below remain only as the fallback -- on
# sprawling open frames like Hoffer's Gap they were solid in the wrong places.
const HULL_LAYER := 1 << 5   # a private physics layer; nothing else uses physics

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

func _attach_collision_hull(o: Dictionary, model: Node3D) -> bool:
	var hull_path: String = _hull_index().get(str(o.get("avatar", "")).to_lower(), "")
	if hull_path.is_empty():
		return false
	var f := FileAccess.open(_base().path_join(hull_path), FileAccess.READ)
	if f == null:
		return false
	var h: Variant = JSON.parse_string(f.get_as_text())
	if not (h is Dictionary):
		return false
	var pts: Array = h.get("points", [])
	var tris: Array = h.get("triangles", [])
	if pts.is_empty() or tris.is_empty():
		return false
	var faces := PackedVector3Array()
	faces.resize(tris.size() * 3)
	var n := 0
	for t: Array in tris:
		for idx in t:
			var p: Array = pts[int(idx)]
			# LW -> Godot: negate Z, the model exporter's convention
			faces[n] = Vector3(float(p[0]), float(p[1]), -float(p[2]))
			n += 1
	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(faces)
	var body := StaticBody3D.new()
	body.collision_layer = HULL_LAYER
	body.collision_mask = 0
	var cs := CollisionShape3D.new()
	cs.shape = shape
	body.add_child(cs)
	model.add_child(body)
	o["hull"] = true
	return true

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
	var params := PhysicsShapeQueryParameters3D.new()
	params.shape = _probe_shape
	params.transform = Transform3D(Basis(), ship.global_position)
	params.collision_mask = HULL_LAYER
	var hit: Dictionary = get_world_3d().direct_space_state.get_rest_info(params)
	if hit.is_empty():
		return
	var point: Vector3 = hit["point"]
	var n: Vector3 = hit["normal"]
	# orient the normal off the surface toward the ship
	if n.dot(ship.global_position - point) < 0.0:
		n = -n
	var rel: float = ship.velocity.dot(n)
	if rel < 0.0:
		ship.velocity -= n * rel * 1.6  # bounce off
		damage_player(clampf(-rel * 0.4, 4.0, 250.0),
			"COLLISION - " + str(o["name"]).to_upper())
		audio.play("audio/sfx/collision.wav", -3.0)
		audio.play("audio/sfx/ship_clatter.wav", -8.0)
	# push out of the surface
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
