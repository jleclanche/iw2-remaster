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
# `radius` (iiSim +0x1c, the ship INI's radius= key) now lives on ShipFlight
# (the external cameras need it for the player too); _load_dims overwrites the
# inherited default with the authored value
# iiSim size (+0x20): half the bounding diagonal -- CalculateRadius
# (0x1007ccf0) = sqrt((w^2+h^2+l^2) * 0.25) from the INI dimensions. Drives
# the OnExplode dramatic-explosion branch (death_sequence.gd). 10.0 is the
# engine's generic-explosion default scale (FUN_10064500 +0x1d8).
var explosion_size := 10.0
var half_dims := Vector3(10, 10, 10)  # INI width/height/length * 0.5
var dying := false    # OnExplode dramatic sequence running; ignore new kills
var docking_priority := 50  # iiSim +0x1c0; the HIGHER sim is the dock parent
var carried_pods := 0       # cargo pods racked on this hull's cargo clamps;
                            # DoFinalExplosion's DetachAndFlingChild spills
                            # them as free sims (main._spill_pods)
var disrupt_time := 0.0       # icShip::Disrupt via icMissile::CheckForDisruption
var disrupt_full := false     # full_disruption: everything, else shields only
var sys: ShipSystems  # subsims, armour and hull, from the ship's INI
var ini_path := ""    # the authored ship INI (turrets.gd reads the record's
					# setup scene for the turret mount nulls)
# @element icAlienSwarm (the infection half, on the victims)
# iiThrusterSim +0x258: the act 3 alien infection, hull points per second,
# applied by Simulate (0x1007e200) as ApplyDamage(dt * damage, source 5).
# Proxied onto ShipSystems when a subsim model is fitted, exactly like hull.
var _infection_damage := 0.0
var infection_damage: float:
	get:
		return sys.infection_damage if sys != null else _infection_damage
	set(value):
		if sys != null:
			sys.infection_damage = value
		else:
			_infection_damage = value
var infection_fx: Node3D = null  # the sfx/infection crawl; presence IS the
								# "effect on" state (IsAlienEffectOn 0x1007ee70)
# A cannon fitted at runtime by sim.AddSubsim (act 3's nps_antimatter_pbc):
# when set, _attack fires this projectile instead of main.spawn_bolt's
# standard PBC bolt. Spec dict as PbcWeapons uses, plus "refire".
var bolt_spec: Dictionary = {}

# --- icShip aggression bookkeeping (extracted, docs/combat.md) ---------------
#   +0x1a0 last aggressor / +0x19d was-attacked (iiSim::SetLastAggressor
#          0x10079640: recorded by every ApplyDamage/ApplyWeaponDamage, never
#          decays -- consumed by readers)
#   +0x2e0 max_player_shots_before_aggression (ini property, default 4) and
#          +0x2e4 the counter; "pissed" = counter > tolerance
#          (icShip::IsPissedWithPlayer 0x10002be0)
#   +0x2e8/+0x2ec last fire target + has-fired flag (SetLastFireTarget
#          0x10075000, set by the weapon fire path with the gun's engaged
#          target; the getters are read-and-optionally-clear) -- these feed
#          the POG reactive systems (istation.pog's station protection,
#          igangsterincidentgen.pog), which we RUN
var last_aggressor: Node3D = null
var was_attacked := false
var player_shots := 0
var shot_tolerance := 4       # max_player_shots_before_aggression
var has_fired := false
var last_fire_target: Node3D = null
var escort_of: Node3D = null  # iai.GiveEscortOrder's escortee (FcGroup stand-in)
var explicit_hostile := false # icPlayerContactList::SetSimAsHostile (0x100059c0)

func set_last_aggressor(who: Node3D) -> void:
	# iiSim::SetLastAggressor refuses self-recording
	if who == null or who == self:
		return
	last_aggressor = who
	was_attacked = true

func pissed_with_player() -> bool:
	return player_shots > shot_tolerance

func record_fire(at: Node3D) -> void:
	# icShip::SetLastFireTarget: the flag AND the target, set together
	has_fired = true
	if at != null:
		last_fire_target = at

func setup(props: Dictionary) -> void:
	load_stats(props)
	hull_max = float(props.get("hit_points", 1000))
	hull = hull_max
	radius = float(props.get("radius", 60.0))
	shot_tolerance = int(props.get("max_player_shots_before_aggression", 4))
	docking_priority = int(props.get("docking_priority", docking_priority))
	_load_dims(props)

func _load_dims(props: Dictionary) -> void:
	var w := float(props.get("width", 0.0))
	var h := float(props.get("height", 0.0))
	var l := float(props.get("length", 0.0))
	if w > 0.0 or h > 0.0 or l > 0.0:
		half_dims = Vector3(w, h, l) * 0.5
		explosion_size = half_dims.length()  # CalculateRadius 0x1007ccf0
		mass = w * h * l * 0.001             # iiThrusterSim::Load, m_density
	else:
		# no dimensions in the record: the radius is the only size we have
		half_dims = Vector3.ONE * radius * 0.5
		explosion_size = radius
		mass = radius * radius * radius * 0.001

func setup_ini(path: String, model: Node3D = null) -> void:
	# the authored hull: hit_points, armour and the full subsim list
	ini_path = path
	var rec := ShipSystems.ship_record(path)
	if not rec.is_empty():
		radius = float((rec.get("properties", {}) as Dictionary)
				.get("radius", radius))
	if not rec.is_empty():
		shot_tolerance = int((rec.get("properties", {}) as Dictionary)
				.get("max_player_shots_before_aggression", shot_tolerance))
		docking_priority = int((rec.get("properties", {}) as Dictionary)
				.get("docking_priority", docking_priority))
		_load_dims(rec.get("properties", {}) as Dictionary)
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
		# ShipSystems ticks the infection inside simulate(); a ship the
		# infection killed still has to explode (main owns the death path).
		if sys.killed and sys.infection_damage > 0.0 \
				and main != null and main.has_method("kill_ai"):
			main.kill_ai(self)
			return
	elif _infection_damage > 0.0:
		# no subsim model fitted (every POG-created ship): the raw hull pool,
		# same rule -- iiThrusterSim::Simulate 0x1007e200, dt * damage.
		if damage(_infection_damage * delta) and main != null \
				and main.has_method("kill_ai"):
			main.kill_ai(self)
			return
	match behavior:
		"towed":
			# a docked child rides its parent rigidly (FiSim::UpdateChild
			# rewrites the child's transform from the parent every tick);
			# main._update_tow does the rewrite, we must not integrate
			thrust_frac = Vector3.ZERO  # no burn of its own -> engines dark
			return
		"dying":
			# OnExplode's dramatic sequence: dead hands on the controls, the
			# hulk keeps its velocity and the random tumble until the final
			# blast (death_sequence.gd frees it)
			input_rotate = Vector3.ZERO
			input_thrust = Vector3.ZERO
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

# --- icAIAttackAgent: the dogfight is a MANEUVER CYCLE ------------------------
# Extracted from iwar2.dll (Construct 0x4faa0, GetSensibleManeuver 0x50280,
# Strafe 0x4fe80, TailBite 0x4ff90, GunPlatform 0x50040, FacingAttack 0x500d0,
# GetNewStrafeVector 0x4fda0, Think 0x504a0; constants dumped from the image):
#   halfrange = min(gun range) / 2, clamped [3000, 20000] (MinHalfWeaponsRange
#     0x501d0; caps DAT_1011a194 / immediate 20000)
#   STRAFE   goal = target + fwd x lerp(2.0, 2.5)*halfrange (cap 10 km,
#     DAT_1011a190/1011a18c) plus a lateral ring offset of 3x the target's
#     radius (DAT_10118490) whose side FLIPS on every pass (GetNewStrafeVector
#     negates z); cruise at lerp(0.1, 0.2) x dist (DAT_101184b0/101184ac).
#     Reaching the goal re-rolls the ring and swings back THROUGH the target:
#     the weaving gun pass.
#   TAILBITE goal = target - fwd x lerp(0.9, 1.1)*halfrange (DAT_1011951c/
#     10119e94, cap 10 km), speed 0.2 x dist: sit on the tail.
#   GUNPLATFORM hold radius lerp(0.9, 1.1)*halfrange (cap 3 km), speed 50
#     (0x42480000): capital hulls (ship types 0x1b/0x1c/0x1d) always use this.
#   FACING   hold radius lerp(0.9, 1.1)*halfrange + 1000 (DAT_1011945c, cap
#     3 km) nose-on, speed radius x 0.05 (DAT_1011a198): the joust.
# The maneuver re-rolls every 60 s (m_maximum_target_kill_time) or when its
# goal completes, never repeating the previous pick (Think's do/while). The
# full pick heuristics weigh group counts and agility (CalculateStanding);
# we keep the engine's own four-way random fallback.
const ATK_STRAFE := 0
const ATK_TAILBITE := 1
const ATK_GUNPLATFORM := 2
const ATK_FACING := 3
const ATK_KILL_TIME := 60.0        # m_maximum_target_kill_time
var _atk_mode := -1
var _atk_timer := 0.0
var _atk_dist := 3000.0
var _atk_side := 1.0               # strafe z sign, flipped each pass
var _atk_lat := Vector2.ZERO       # strafe ring offset, target-frame x/y
var _atk_speed_frac := 0.15
var _half_range := 3375.0          # light PBC: 4500*1.5/2

func _new_strafe_ring(target: Node3D) -> void:
	# GetNewStrafeVector: a random direction in the ring plane, normalised,
	# scaled by 3x the target's radius; z (the pass side) flips every call
	var tr := 30.0
	if "radius" in target:
		tr = maxf(float(target.radius), 10.0)
	var a := randf() * TAU
	_atk_lat = Vector2(cos(a), sin(a)) * tr * 3.0

func _pick_attack(target: Node3D) -> void:
	var prev := _atk_mode
	_atk_mode = randi() % 4
	if _atk_mode == prev:
		_atk_mode = (_atk_mode + 1 + randi() % 3) % 4
	_atk_timer = ATK_KILL_TIME
	var lr := randf()
	match _atk_mode:
		ATK_STRAFE:
			_atk_dist = minf(lerpf(2.0, 2.5, lr) * _half_range, 10000.0)
			_atk_speed_frac = lerpf(0.1, 0.2, randf())
			_atk_side = 1.0
			_new_strafe_ring(target)
		ATK_TAILBITE:
			_atk_dist = minf(lerpf(0.9, 1.1, lr) * _half_range, 10000.0)
		ATK_GUNPLATFORM:
			_atk_dist = minf(lerpf(0.9, 1.1, lr) * _half_range, 3000.0)
		ATK_FACING:
			_atk_dist = minf(lerpf(0.9, 1.1, lr) * _half_range + 1000.0, 3000.0)

func _attack(delta: float) -> void:
	if main == null or main.ship == null:
		return
	var player: ShipFlight = main.ship
	_atk_timer -= delta
	if _atk_mode < 0 or _atk_timer <= 0.0:
		_pick_attack(player)
	var tb := player.global_transform.basis
	var tfwd: Vector3 = -tb.z
	var goal: Vector3 = player.global_position
	var speed := max_speed.z
	match _atk_mode:
		ATK_STRAFE:
			goal = player.global_position + tfwd * _atk_dist * _atk_side \
				+ tb.x * _atk_lat.x + tb.y * _atk_lat.y
			speed = maxf(_atk_speed_frac * _atk_dist, 80.0)
			if global_position.distance_to(goal) < 300.0:
				_atk_side = -_atk_side   # swing back through the target
				_new_strafe_ring(player)
		ATK_TAILBITE:
			goal = player.global_position - tfwd * _atk_dist
			speed = 0.2 * _atk_dist
		ATK_GUNPLATFORM:
			var away := (global_position - player.global_position).normalized()
			goal = player.global_position + away * _atk_dist
			speed = 50.0
		ATK_FACING:
			var away := (global_position - player.global_position).normalized()
			goal = player.global_position + away * _atk_dist
			speed = _atk_dist * 0.05
	_steer_toward(goal, delta)
	set_speed = clampf(speed, 30.0, max_speed.z)
	# fire whenever the LEAD POINT happens to bear, regardless of maneuver:
	# aim where the player will be when the bolt arrives
	var dist := global_position.distance_to(player.global_position)
	var tof := dist / bolt_speed
	var aim: Vector3 = player.global_position + (player.velocity - velocity) * tof
	var la := (aim - global_position) * global_transform.basis
	var angle := Vector2(atan2(la.y, -la.z), atan2(-la.x, -la.z)).length()
	# a fully disrupted ship cannot fire (iiWeapon::IsReadyToFire 0x1003cb80:
	# the disrupted flag 0x10 returns eFireResult 6)
	if disrupt_time > 0.0 and disrupt_full:
		return
	if dist < weapon_range and angle < 0.06 and fire_cooldown <= 0.0:
		if bolt_spec.is_empty():
			fire_cooldown = 0.5
			main.spawn_bolt(self, -global_transform.basis.z)
		else:
			# a runtime-fitted cannon (sim.AddSubsim): its own projectile INI
			# and refire_delay -- act 3's antimatter PBCs
			fire_cooldown = float(bolt_spec.get("refire", 0.5))
			main.weapons.spawn(self, -global_transform.basis.z, bolt_spec)
			main.audio.play("audio/sfx/light_pbc.wav", -8.0)
