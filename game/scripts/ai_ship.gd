class_name AiShip
extends ShipFlight
# AI pilot on top of the same flight model the player uses.
# Behaviors: "patrol" (cruise between waypoints), "attack" (pursue the
# player, fire PBCs in range/arc). Stats and hull from the extracted INIs.

var behavior := "patrol"
# A sim's NAME is a localisation key ("sn_general_212"), and the engine resolves
# it through FcLocalisedText::Field for display (icAIPilot::ResolveName). The
# scripts look ships up by the key; the HUD shows the resolved text.
var sim_key := ""
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
var radius := 60.0    # iiSim radius (+0x1c), the ship INI's radius= key
var disrupt_time := 0.0       # icShip::Disrupt via icMissile::CheckForDisruption
var disrupt_full := false     # full_disruption: everything, else shields only
var sys: ShipSystems  # subsims, armour and hull, from the ship's INI
var ini_path := ""    # the authored ship INI (turrets.gd reads the record's
					  # setup scene for the turret mount nulls)

func setup(props: Dictionary) -> void:
	load_stats(props)
	hull_max = float(props.get("hit_points", 1000))
	hull = hull_max
	radius = float(props.get("radius", 60.0))

func setup_ini(path: String, model: Node3D = null) -> void:
	# the authored hull: hit_points, armour and the full subsim list
	ini_path = path
	var rec := ShipSystems.ship_record(path)
	if not rec.is_empty():
		radius = float((rec.get("properties", {}) as Dictionary)
				.get("radius", radius))
	var fitted := ShipSystems.for_ship(path)
	if fitted.hull_max <= 0.0:
		return
	fitted.bind_model(model)
	sys = fitted
	# any fitted icTurret / icBeamProjector fires through the turret manager
	# (turrets.gd scans main.ai_ships and arms them with the ship: an AI ship
	# engaging arms its weapons, iiSim::ConfigureWeaponsForAI 0x10001590)

func armour() -> float:
	return sys.armour if sys != null else 0.0

func damage(amount: float) -> bool:
	# iiSim::ApplyDamage -- the raw hull path, no armour (collision, scripts)
	if sys != null:
		return sys.apply_damage(amount)
	hull -= amount
	return hull <= 0.0

func hit_by_warhead(dmg: float, pen: float, at: Vector3) -> Dictionary:
	# icRocket::OnCollision 0x1006ff50 / icMissile::OnCollision 0x1006cc30
	# contact path: ApplyWeaponDamage with eDamageSource=2. A nonzero source
	# skips the LDA scan (icShip::ApplyWeaponDamage 0x10073e2e), so warheads
	# are never shield-deflected; armour and subsim criticals still apply.
	if sys == null:
		hull -= dmg
		return {"applied": dmg, "deflected": false, "hit": "",
			"killed": hull <= 0.0}
	var inv := global_transform.affine_inverse()
	var dir := (inv.basis * (at - global_position)).normalized()
	return sys.apply_weapon_damage(dmg, pen, inv * at, dir, 2)

func disrupt(seconds: float, full: bool) -> void:
	# icShip::Disrupt (via icMissile::CheckForDisruption 0x1006d0b0): the
	# original sets the disrupted flag (0x10) on the subsims, which zeroes
	# their efficiency. ship_systems.gd is owned elsewhere; here the timer
	# gates everything this ship does with its weapons (fire below, missile
	# magazines in missiles.gd). The LDA-efficiency wiring is reported to the
	# ship_systems owner.
	disrupt_time = maxf(disrupt_time, seconds)
	disrupt_full = disrupt_full or full

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
	disrupt_time = maxf(0.0, disrupt_time - delta)
	if disrupt_time <= 0.0:
		disrupt_full = false
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
	# a fully disrupted ship cannot fire (iiWeapon::IsReadyToFire 0x1003cb80:
	# the disrupted flag 0x10 returns eFireResult 6)
	if disrupt_time > 0.0 and disrupt_full:
		return
	if dist < weapon_range and angle < 0.06 and fire_cooldown <= 0.0:
		fire_cooldown = 0.5
		main.spawn_bolt(self, -global_transform.basis.z)
