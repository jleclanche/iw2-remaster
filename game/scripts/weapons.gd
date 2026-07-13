class_name PbcWeapons
extends Node3D
# PBC bolt manager for every combatant. Bolt stats come from the weapon INIs
# (data/ini/sims/weapons/*.ini) -- speed, lifetime, damage, penetration and
# half_time. Swept-sphere hit tests against the player and AI ships each tick;
# damage is applied by main.on_bolt_hit, which runs the recovered damage chain
# (docs/combat.md).

const BOLT_SPEED := 6000.0
const BOLT_LIFE := 1.6
const BOLT_LENGTH := 90.0
const MUZZLES := [Vector3(0, 17.5, -8), Vector3(0, -6, -30)]

# sims/weapons/pbc_bolt.ini -- the standard PBC bolt (subsims .../player/pbc)
const PBC_BOLT := {"damage": 160.0, "penetration": 50.0, "half_time": 0.35,
	"speed": 6000.0, "lifetime": 1.6, "bypass_shields": false}
# sims/weapons/light_pbc_bolt.ini -- what a *light* PBC actually fires
const LIGHT_PBC_BOLT := {"damage": 130.0, "penetration": 35.0, "half_time": 0.3,
	"speed": 4500.0, "lifetime": 1.5, "bypass_shields": false}

var ship: ShipFlight  # player, for fire()
var main: Node3D
var refire := 0.3     # per-weapon (light PBC: 0.8 s, subsims INI)
var bolt_spec: Dictionary = PBC_BOLT
var cooldown := 0.0
var bolts: Array = []  # {node, vel, life, age, shooter, spec}
var muzzle_nodes: Array = []  # weapon-mount nulls found on the avatar
var muzzle_fallback: Array = MUZZLES  # per-hull mounts (setup-scene nulls)
var _mesh: Mesh

func set_muzzles(model: Node3D) -> void:
	# fire from the avatar's actual weapon nulls (pbc mounts / hardpoints)
	muzzle_nodes.clear()
	for n in model.find_children("*", "Node3D", true, false):
		var nm := str(n.name).to_lower()
		if ("pbc" in nm or "hardpoint" in nm) and "bolt" not in nm \
				and not (n is MeshInstance3D):
			muzzle_nodes.append(n)
	muzzle_nodes = muzzle_nodes.slice(0, 2)

# the bolt's own avatar (avatars/standard_pbc_bolt/setup.lws) is an
# icBeamAvatar streak textured with images/sfx/pbc_standard, not a box
func _bolt_mesh() -> Mesh:
	if _mesh == null and main:
		_mesh = ExplosionFx.bolt_mesh(main._base())
	return _mesh

func fire() -> void:
	if cooldown > 0.0:
		return
	# iiWeapon::Simulate 0x1003cc00 sets flag 0x200 and refuses to fire while
	# the ship's TotalHeat is at or past heat_damage_threshold
	if main and main.sys != null and main.sys.heat + main.sys.heat_external \
			>= ShipSystems.HEAT_DAMAGE_THRESHOLD:
		return
	cooldown = refire
	if not muzzle_nodes.is_empty():
		for n in muzzle_nodes:
			if is_instance_valid(n):
				_spawn_at(ship, (n as Node3D).global_position,
						-ship.global_transform.basis.z, ship.velocity)
	else:
		for m in muzzle_fallback:
			_spawn_at(ship, ship.global_transform * m,
					-ship.global_transform.basis.z, ship.velocity)
	if main:
		main.audio.play("audio/sfx/light_pbc.wav", -8.0)

func spawn(shooter: Node3D, dir: Vector3, spec: Dictionary = {}) -> void:
	var vel: Vector3 = shooter.velocity if "velocity" in shooter else Vector3.ZERO
	_spawn_at(shooter, shooter.global_position + dir * 40.0, dir, vel,
			spec if not spec.is_empty() else bolt_spec)

func _spawn_at(shooter: Node3D, pos: Vector3, dir: Vector3, base_vel: Vector3,
		spec: Dictionary = {}) -> void:
	if spec.is_empty():
		spec = bolt_spec
	if shooter is ShipFlight and (shooter as ShipFlight).fx != null:
		(shooter as ShipFlight).fx.fire_pulse = 1.0
	var node := MeshInstance3D.new()
	node.mesh = _bolt_mesh()
	get_parent().add_child(node)
	node.global_position = pos
	node.global_transform.basis = Basis.looking_at(dir, Vector3.UP)
	if main:
		ExplosionFx.muzzle_flash(main, pos)
	bolts.append({"node": node, "vel": base_vel + dir * float(spec["speed"]),
			"life": float(spec["lifetime"]), "age": 0.0,
			"shooter": shooter, "spec": spec})

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
		bolt["age"] = float(bolt["age"]) + delta
		var node: MeshInstance3D = bolt["node"]
		var dead: bool = bolt["life"] <= 0.0 or not is_instance_valid(node)
		if not dead:
			var move: Vector3 = bolt["vel"] * delta
			var from: Vector3 = node.global_position
			node.global_position = from + move
			for t in targets:
				if t == bolt["shooter"] or not is_instance_valid(t):
					continue
				if not _segment_sphere(from, node.global_position,
						t.global_position, 60.0):
					continue
				# where the bolt struck matters now: it picks the subsim that
				# takes the direct critical
				var at := _closest_point(from, node.global_position,
						t.global_position)
				main.on_bolt_hit(t, at, bolt["shooter"], bolt)
				dead = true
				break
		if dead:
			if is_instance_valid(node):
				node.queue_free()
			bolts.remove_at(i)
		i -= 1

func _closest_point(a: Vector3, b: Vector3, c: Vector3) -> Vector3:
	var ab := b - a
	var t := clampf((c - a).dot(ab) / maxf(ab.length_squared(), 1e-6), 0.0, 1.0)
	return a + ab * t

func _segment_sphere(a: Vector3, b: Vector3, c: Vector3, r: float) -> bool:
	return _closest_point(a, b, c).distance_squared_to(c) < r * r

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
