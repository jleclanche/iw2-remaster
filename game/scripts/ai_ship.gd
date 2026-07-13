class_name AiShip
extends ShipFlight
# AI pilot on top of the same flight model the player uses.
# Behaviors: "patrol" (cruise between waypoints), "attack" (pursue the
# player, fire PBCs in range/arc). Stats and hull from the extracted INIs.

var behavior := "patrol"
var display_name := ""  # node names mangle punctuation; HUD uses this
var faction := "INDPT"  # text/faction_names.csv abbreviations
var ctype := "TRANS"    # text/hud.csv hud_type_* abbreviations
var avatar_path := ""   # for the MFD's EO-feed render
# When a subsim model is fitted it owns the hull; these proxy onto it so the
# HUD and the ported scripts keep reading and writing one number.
var _hull := 1000.0
var _hull_max := 1000.0
var hull: float:
	get:
		return sys.hull if sys != null else _hull
	set(value):
		if sys == null:
			_hull = value
			return
		sys.hull = value
		sys.killed = value <= 0.0
var hull_max: float:
	get:
		return sys.hull_max if sys != null else _hull_max
	set(value):
		if sys == null:
			_hull_max = value
		else:
			sys.hull_max = value
var main: Node3D
var waypoints: Array[Vector3] = []
var wp := 0
var fire_cooldown := 0.0
var bolt_speed := 6000.0
var weapon_range := 2500.0
var sys: ShipSystems  # subsims, armour and hull, from the ship's INI

func setup(props: Dictionary) -> void:
	load_stats(props)
	hull_max = float(props.get("hit_points", 1000))
	hull = hull_max

func setup_ini(ini_path: String, model: Node3D = null) -> void:
	# the authored hull: hit_points, armour and the full subsim list
	var fitted := ShipSystems.for_ship(ini_path)
	if fitted.hull_max <= 0.0:
		return
	fitted.bind_model(model)
	sys = fitted

func armour() -> float:
	return sys.armour if sys != null else 0.0

func damage(amount: float) -> bool:
	# iiSim::ApplyDamage -- the raw hull path, no armour (collision, scripts)
	if sys != null:
		return sys.apply_damage(amount)
	hull -= amount
	return hull <= 0.0

func hit_by_bolt(spec: Dictionary, age: float, at: Vector3) -> Dictionary:
	# icBullet::OnCollision -> icShip::ApplyWeaponDamage
	var dmg: float = float(spec.get("damage", 160.0)) \
			/ ShipSystems.age_factor(age, float(spec.get("half_time", 0.35)))
	var pen: float = float(spec.get("penetration", 50.0))
	var bypass: bool = bool(spec.get("bypass_shields", false))
	if sys == null:
		# no INI record: fall back to the armourless hull pool
		hull -= dmg
		return {"applied": dmg, "deflected": false, "hit": "",
			"killed": hull <= 0.0}
	var inv := global_transform.affine_inverse()
	var local := inv * at
	var dir := (inv.basis * (at - global_position)).normalized()
	return sys.apply_weapon_damage(dmg, pen, local, dir,
			ShipSystems.SRC_BYPASS if bypass else ShipSystems.SRC_WEAPON)

func _physics_process(delta: float) -> void:
	fire_cooldown = maxf(0.0, fire_cooldown - delta)
	if sys != null:
		sys.simulate(delta)
	match behavior:
		"attack":
			_attack(delta)
		_:
			_patrol(delta)
	super._physics_process(delta)

func _steer_toward(point: Vector3, _delta: float) -> float:
	# steer through the flight model's angular dynamics (input_rotate) so AI
	# ships turn like ships, not turrets
	var local := (point - global_position) * global_transform.basis
	var pitch := atan2(local.y, -local.z)
	var yaw := atan2(-local.x, -local.z)
	input_rotate.x = clampf(pitch * 2.0, -1.0, 1.0)
	input_rotate.y = clampf(yaw * 2.0, -1.0, 1.0)
	input_rotate.z = 0.0
	return Vector2(pitch, yaw).length()

func _patrol(delta: float) -> void:
	if waypoints.is_empty():
		set_speed = 0.0
		return
	var target := waypoints[wp]
	if global_position.distance_to(target) < 800.0:
		wp = (wp + 1) % waypoints.size()
	_steer_toward(target, delta)
	set_speed = max_speed.z * 0.5

func _attack(delta: float) -> void:
	if main == null or main.ship == null:
		return
	var player: ShipFlight = main.ship
	# lead the target: aim where the player will be when the bolt arrives
	var dist := global_position.distance_to(player.global_position)
	var tof := dist / bolt_speed
	var aim: Vector3 = player.global_position + (player.velocity - velocity) * tof
	var angle := _steer_toward(aim, delta)
	set_speed = max_speed.z if dist > 1200.0 else max_speed.z * 0.35
	if dist < weapon_range and angle < 0.06 and fire_cooldown <= 0.0:
		fire_cooldown = 0.5
		main.spawn_bolt(self, -global_transform.basis.z)
