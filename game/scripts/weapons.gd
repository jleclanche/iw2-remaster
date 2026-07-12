class_name PbcWeapons
extends Node3D
# PBC bolt manager for every combatant. IW2 constants
# (sims/weapons/pbc_bolt.ini): 6000 m/s muzzle velocity added to shooter
# velocity, 1.6 s lifetime. Swept-sphere hit tests against the player and
# AI ships each tick; damage is applied by main.on_bolt_hit.

const BOLT_SPEED := 6000.0
const BOLT_LIFE := 1.6
const BOLT_LENGTH := 90.0
const REFIRE := 0.3
const MUZZLES := [Vector3(0, 17.5, -8), Vector3(0, -6, -30)]

var ship: ShipFlight  # player, for fire()
var main: Node3D
var cooldown := 0.0
var bolts: Array = []  # {node, vel, life, shooter}
var _mesh: BoxMesh

func _ready() -> void:
	_mesh = BoxMesh.new()
	_mesh.size = Vector3(0.8, 0.8, BOLT_LENGTH)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(0.7, 0.85, 1.0)
	mat.emission_enabled = true
	mat.emission = Color(0.55, 0.75, 1.0)
	mat.emission_energy_multiplier = 6.0
	_mesh.material = mat

func fire() -> void:
	if cooldown > 0.0:
		return
	cooldown = REFIRE
	for m in MUZZLES:
		_spawn_at(ship, ship.global_transform * m,
				-ship.global_transform.basis.z, ship.velocity)
	if main:
		main.audio.play("audio/sfx/light_pbc.wav", -8.0)

func spawn(shooter: Node3D, dir: Vector3) -> void:
	var vel: Vector3 = shooter.velocity if "velocity" in shooter else Vector3.ZERO
	_spawn_at(shooter, shooter.global_position + dir * 40.0, dir, vel)

func _spawn_at(shooter: Node3D, pos: Vector3, dir: Vector3, base_vel: Vector3) -> void:
	var node := MeshInstance3D.new()
	node.mesh = _mesh
	get_parent().add_child(node)
	node.global_position = pos
	node.global_transform.basis = Basis.looking_at(dir, Vector3.UP)
	bolts.append({"node": node, "vel": base_vel + dir * BOLT_SPEED,
			"life": BOLT_LIFE, "shooter": shooter})

func _physics_process(delta: float) -> void:
	cooldown = maxf(0.0, cooldown - delta)
	var targets: Array = []
	if main:
		targets = main.ai_ships.duplicate()
		targets.append(main.ship)
	var i := bolts.size() - 1
	while i >= 0:
		var bolt: Dictionary = bolts[i]
		bolt["life"] -= delta
		var node: MeshInstance3D = bolt["node"]
		var dead: bool = bolt["life"] <= 0.0 or not is_instance_valid(node)
		if not dead:
			var move: Vector3 = bolt["vel"] * delta
			var from: Vector3 = node.global_position
			node.global_position = from + move
			for t in targets:
				if t == bolt["shooter"] or not is_instance_valid(t):
					continue
				var hit := _segment_sphere(from, node.global_position,
						t.global_position, 60.0)
				if hit:
					main.on_bolt_hit(t, t.global_position)
					dead = true
					break
		if dead:
			if is_instance_valid(node):
				node.queue_free()
			bolts.remove_at(i)
		i -= 1

func _segment_sphere(a: Vector3, b: Vector3, c: Vector3, r: float) -> bool:
	var ab := b - a
	var t := clampf((c - a).dot(ab) / maxf(ab.length_squared(), 1e-6), 0.0, 1.0)
	return (a + ab * t).distance_squared_to(c) < r * r

func clear() -> void:
	for bolt in bolts:
		var node: MeshInstance3D = bolt["node"]
		if is_instance_valid(node):
			node.queue_free()
	bolts.clear()

func shift_world(offset: Vector3) -> void:
	for bolt in bolts:
		var node: MeshInstance3D = bolt["node"]
		if is_instance_valid(node):
			node.global_position -= offset
