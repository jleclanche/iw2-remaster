class_name Missiles
extends Node3D
# The missile system: launchers, magazines, missiles, rockets, mines and
# countermeasures, recovered from iwar2.dll (GOG build, image base 0x10000000)
# and the shipped INI tree. Same idiom as weapons.gd: plain dictionaries,
# swept-sphere hits, damage through the recovered chain. The full disassembly
# notes live in docs/combat.md ("Missiles").
#
# @element icMissile
# @element icSimTrackingMissile
# @element icLDSIMissile
# @element icMine
# @element icRocket
# @element icCounterMeasure
# @element icMagazine
# @element icMissileMagazine
# @element icCounterMeasureMagazine
# @element icMissileLauncher
# @element icMissileTrailAvatar
# @element icRocketTrailAvatar
# @element-stub icRemoteMissile -- GENUINE GAP: data and rules recovered
#   (docs/combat.md: an icShip subclass the player flies through
#   icPlayerPilot::RemoteLink 0x1006f490); the remote-piloting camera/control
#   handoff is not built.

# --- icMissile class statics (compiled-in, read out of the PE) --------------
const ACTIVE_SEEK_UPDATE := 1.0   # m_active_seek_update_time  0x1011b60c
const MIN_DISRUPTOR_TIME := 2.0   # m_min_disruptor_time       0x1011b610
const MAX_DISRUPTOR_TIME := 30.0  # m_max_disruptor_time       0x1011b614
const DESTROYER_RADIUS := 300.0   # m_destroyer_radius         0x1011b618
const LAUNCH_GRACE := 4.0         # icMissile::CanCollideWith  0x101190b4:
								# no collision with the launcher for 4 s
const MINE_DROP_FACTOR := 5.0     # icMine::Think 0x1006bbb0 hysteresis 0x1011b4dc
const LDSI_FUSE_RANGE := 500.0    # icLDSIMissile::Think 0x1006b830, 0x10119fcc
const ROCKET_IGNITION := 0.6      # icRocket::Simulate 0x1006fde0, 0x1011bb94
const FIREBALL_FLOOR := 100.0     # icMissile::OnExplode 0x1006d1a0, 0x101192c0
const MISSILE_SRC := 2            # eDamageSource for every warhead path
# flux.ini [icSimTrackingMissile] (= compiled defaults 0x1015dd5c/0x1015dd60):
const DECOY_RANGE_L0 := 500.0     # max_range_for_decoying_level_zero_missile
const REACQUIRE_RANGE_L1 := 5000.0  # min_range_for_stopping_level_one_..._reacquisition
# flux.ini [icMissileMagazine] (compiled defaults 0.02 / 0.08 at 0x1015ba80/7c):
const LAUNCH_LIKELIHOOD := 0.005  # missile_launch_likelihood_per_ammo_fraction
# flux.ini [icMagazine] (compiled default 0.1 at 0x1015ba00):
const ROCKET_LIKELIHOOD := 0.1    # rocket_launch_likelihood_per_ammo_fraction
const FIRING_TOLERANCE := 15.0    # squared_radius_firing_tolerance (used linearly,
								# icMagazine::ComputeFiringSolution 0x10038660)
const CFS_MAX_LEAD := 30.0        # max ballistic lead time, 0x10119c18

# --- in-flight sound, from the avatar scenes -------------------------------
# Each missile's Setup.lws carries an FcThreePartSoundNode null on the same
# `lz` channel that lights the exhaust (ini:/audio/sfx/*): the loop starts
# when the motor does. Extracted per avatar from resource.zip:
#   seeker / harrower / deadshot ................ missile_scream   (1.0, 100 m)
#   disruptor / rocket (gnat) / pulsar .......... missile_scream02 (1.0, 100 m)
#   hammer (rocket_scream) ...................... missile_scream03 (0.7, 180 m)
#     (its attack_url "sound:/audio/sfx/ignite" does not EXIST in the shipped
#      resource -- the original degrades to the sustain loop too)
#   blizzard / am_remote ........................ missile_scream03 (1.2, 180 m)
#   ldsi_large / ldsi_small (FcSoundNode) ....... ldsi_engage, ONE-SHOT (50 m)
#   mines (ldsi_mine / proximity_mine) .......... silent
#   counter (FcLoopSoundNode, no channel) ....... cm_loop, loops for life (250 m)
# min_range is "full volume within" -- Godot's unit_size. pitch_bend maps to
# pitch_scale.
const FLIGHT_SOUNDS := {
	"seeker": {"wav": "missile_scream", "pitch": 1.0, "range": 100.0},
	"harrower": {"wav": "missile_scream", "pitch": 1.0, "range": 100.0},
	"deadshot": {"wav": "missile_scream", "pitch": 1.0, "range": 100.0},
	"disruptor": {"wav": "missile_scream02", "pitch": 1.0, "range": 100.0},
	"rocket": {"wav": "missile_scream02", "pitch": 1.0, "range": 100.0},
	"pulsar": {"wav": "missile_scream02", "pitch": 1.0, "range": 100.0},
	"hammer": {"wav": "missile_scream03", "pitch": 0.7, "range": 180.0},
	"blizzard": {"wav": "missile_scream03", "pitch": 1.2, "range": 180.0},
	"am_remote": {"wav": "missile_scream03", "pitch": 1.2, "range": 180.0},
	"ldsi_large": {"wav": "ldsi_engage", "pitch": 1.0, "range": 50.0,
		"once": true},
}

# icMissile::eState (+0x29c). 1..6 as constructed/assigned in the DLL.
const ST_EJECT := 1     # coasting until arm_time
const ST_SEEK := 2      # thrust ahead, FindTarget every ACTIVE_SEEK_UPDATE
const ST_TRACK := 3     # the icAITarget brain chases the target
const ST_HOLD := 4      # icMine w/ proximity: brake to zero, wait
const ST_EXPLODED := 5
const ST_DEAD := 6      # lost lock (type >= 2): coast inert to lifetime

# --- sims/weapons/*.ini (verbatim; only keys the engine reads) ---------------
# speed/acceleration are the iiThrusterSim per-axis vectors; missiles fly the
# ship flight model (icMissile::Simulate 0x1006c550 -> ComputeForceAndTorque).
const SPECS := {
	"basic_missile": {"cls": "icSimTrackingMissile", "damage": 200.0,
		"penetration": 52.0, "level": 0.4, "arm_time": 0.5, "lifetime": 20.0,
		"speed": 2800.0, "accel": 280.0, "yaw_rate": 120.0, "radius": 3.0,
		"sensor_radius": 4.0, "explode_radius": 3.0, "blast_radius": 3.5,
		"disable_attenuation": true, "hit_points": 100.0,
		"model": "harrower", "trail": "redtrail", "trail_life": 5.0},
	"seeker_missile": {"cls": "icSimTrackingMissile", "damage": 280.0,
		"penetration": 60.0, "level": 0.5, "arm_time": 0.5, "lifetime": 20.0,
		"speed": 3000.0, "accel": 380.0, "yaw_rate": 120.0, "radius": 3.0,
		"sensor_radius": 5.0, "explode_radius": 3.5, "blast_radius": 3.5,
		"disable_attenuation": true, "hit_points": 100.0,
		"model": "seeker", "trail": "redtrail", "trail_life": 5.0},
	"harrower_missile": {"cls": "icSimTrackingMissile", "damage": 250.0,
		"penetration": 52.0, "level": 0.3, "arm_time": 0.5, "lifetime": 20.0,
		"speed": 2800.0, "accel": 280.0, "yaw_rate": 120.0, "radius": 3.0,
		"sensor_radius": 5.0, "explode_radius": 3.0, "blast_radius": 3.5,
		"disable_attenuation": true, "hit_points": 100.0,
		"model": "harrower", "trail": "redtrail", "trail_life": 5.0},
	"deadshot_missile": {"cls": "icSimTrackingMissile", "damage": 320.0,
		"penetration": 65.0, "level": 0.9, "arm_time": 0.5, "lifetime": 20.0,
		"speed": 3500.0, "accel": 480.0, "yaw_rate": 120.0, "radius": 3.0,
		"sensor_radius": 5.0, "explode_radius": 4.0, "blast_radius": 3.5,
		"disable_attenuation": true, "hit_points": 100.0,
		"model": "deadshot", "trail": "redtrail", "trail_life": 5.0},
	"disruptor_missile": {"cls": "icSimTrackingMissile", "damage": 1.0,
		"penetration": 60.0, "level": 0.6, "arm_time": 0.5, "lifetime": 20.0,
		"speed": 2800.0, "accel": 400.0, "yaw_rate": 120.0, "radius": 3.0,
		"sensor_radius": 4.0, "explode_radius": 3.0, "blast_radius": 3.5,
		"disable_attenuation": true, "disruptor_time": 20.0,
		"full_disruption": true, "hit_points": 100.0,
		"model": "disruptor", "trail": "bluetrail", "trail_life": 5.0},
	"ldsi_missile": {"cls": "icLDSIMissile", "damage": 0.0, "penetration": 1.0,
		"arm_time": 0.7, "lifetime": 120.0, "speed": 3000.0, "accel": 380.0,
		"yaw_rate": 120.0, "radius": 3.0, "explode_radius": 15000.0,
		"field_radius": 30000.0, "field_life_time": 100.0, "hit_points": 100.0,
		"model": "ldsi_large", "trail": "greentrail", "trail_life": 2.0},
	"gnat_rocket": {"cls": "icRocket", "damage": 140.0, "penetration": 50.0,
		"arm_time": 0.5, "lifetime": 20.0, "accel": 450.0, "radius": 3.0,
		"model": "rocket", "trail": "orangetrail", "trail_life": 2.0},
	"hammer_rocket": {"cls": "icRocket", "damage": 250.0, "penetration": 55.0,
		"arm_time": 0.5, "lifetime": 20.0, "accel": 350.0, "radius": 3.0,
		"model": "hammer", "trail": "orangetrail", "trail_life": 3.0},
	"blizzard_rocket": {"cls": "icRocket", "damage": 160.0, "penetration": 52.0,
		"arm_time": 0.3, "lifetime": 20.0, "accel": 600.0, "radius": 3.0,
		"model": "blizzard", "trail": "orangetrail", "trail_life": 2.0},
	"basic_counter_measure": {"cls": "icCounterMeasure", "lifetime": 20.0,
		"engage_time": 2.0, "radius": 1.0, "model": "counter"},
	"flare": {"cls": "icCounterMeasure", "lifetime": 20.0, "engage_time": 2.0,
		"radius": 1.0, "model": "counter"},
	"decoy": {"cls": "icCounterMeasure", "lifetime": 20.0, "engage_time": 2.0,
		"radius": 1.0, "model": "counter"},
	"proximity_mine": {"cls": "icMine", "damage": 2200.0, "penetration": 60.0,
		"arm_time": 2.0, "lifetime": -1.0, "speed": 2000.0, "accel": 500.0,
		"yaw_rate": 90.0, "radius": 3.0, "sensor_radius": 500.0,
		"explode_radius": 750.0, "blast_radius": 1000.0, "proximity": true,
		"hit_points": 100.0, "model": "proximity_mine"},
	"seeker_mine": {"cls": "icMine", "damage": 1600.0, "penetration": 60.0,
		"arm_time": 1.0, "lifetime": -1.0, "speed": 3000.0, "accel": 380.0,
		"yaw_rate": 120.0, "radius": 3.0, "sensor_radius": 10000.0,
		"explode_radius": 150.0, "blast_radius": 600.0, "proximity": false,
		"hit_points": 20.0, "model": "ldsi_mine"},
}

# --- subsims/systems/*.ini magazines (keys: icMagazine map 0x10037db0) -------
# refire_delay +0xb4, launch_speed +0xb8, max_ammo_count +0xac,
# projectile_template +0xc4. The icMissileLauncher itself is inert -- its
# Fire/CFS are empty and IsReadyToFire returns "never" (0x1004ad80/0x100bc470);
# it only donates a fire position to magazines slaved to it (SetLauncher
# 0x100387e0). The magazine IS the weapon.
const MAG_SPECS := {
	"seeker_missile_magazine": {"projectile": "seeker_missile",
		"launch_speed": 200.0, "max_ammo": 5, "refire_delay": 2.0},
	"deadshot_missile_magazine": {"projectile": "deadshot_missile",
		"launch_speed": 200.0, "max_ammo": 5, "refire_delay": 2.0},
	"harrower_missile_magazine": {"projectile": "harrower_missile",
		"launch_speed": 200.0, "max_ammo": 5, "refire_delay": 2.0},
	"ldsi_missile_magazine": {"projectile": "ldsi_missile",
		"launch_speed": 150.0, "max_ammo": 4, "refire_delay": 2.0,
		"ldsi": true},
	"decoy_magazine": {"projectile": "decoy", "launch_speed": 30.0,
		"max_ammo": 8, "refire_delay": 3.0, "cm": true},
	"flare_magazine": {"projectile": "flare", "launch_speed": 30.0,
		"max_ammo": 10, "refire_delay": 3.0, "cm": true},
	"nps_missile_magazine": {"projectile": "basic_missile",
		"launch_speed": 500.0, "max_ammo": 6, "refire_delay": 4.0},
	"nps_harrower_missile_magazine": {"projectile": "harrower_missile",
		"launch_speed": 500.0, "max_ammo": 5, "refire_delay": 4.0},
	"nps_ldsi_missile_magazine": {"projectile": "ldsi_missile",
		"launch_speed": 150.0, "max_ammo": 2, "refire_delay": 4.0,
		"ldsi": true},
	"nps_counter_measure_magazine": {"projectile": "basic_counter_measure",
		"launch_speed": 5.0, "max_ammo": 2, "refire_delay": 10.0, "cm": true},
	"nps_flare_magazine": {"projectile": "flare", "launch_speed": 5.0,
		"max_ammo": 8, "refire_delay": 3.0, "cm": true},
	"gnat_rocket_pod": {"projectile": "gnat_rocket", "launch_speed": 200.0,
		"max_ammo": 8, "refire_delay": 0.5, "rocket": true},
	"nps_gnat_rocket_pod": {"projectile": "gnat_rocket", "launch_speed": 200.0,
		"max_ammo": 8, "refire_delay": 0.5, "rocket": true},
}

var main: Node3D
var missiles: Array = []  # live icMissile/icRocket records
var cms: Array = []       # live icCounterMeasure records
var _trail_mats: Dictionary = {}
var _ai_mags: Dictionary = {}  # AiShip instance id -> Array of magazine dicts

func _ready() -> void:
	# The turret/beam manager (turrets.gd) rides along with the missile
	# system: main.gd builds weapons + missiles, and the turret battery layer
	# arrived later, so it bootstraps itself here rather than editing main.
	if main != null and Turrets.instance == null:
		var t := Turrets.new()
		t.main = main
		add_sibling.call_deferred(t)

# =============================================================================
# magazines -- the fire cycle (iiWeapon::Simulate 0x1003cc00 ->
# AttemptToActivateWeapon 0x1003ccb0 -> IsReadyToFire -> Fire)
# =============================================================================

# icMagazine::Simulate 0x10038210: the refire clock accumulates
# efficiency * dt, so a damaged magazine reloads slower.
# icMagazine::IsReadyToFire 0x10038350: ready when eff * clock > refire_delay
# and ammo > 0 (plus the ship-wide overheat flag 0x200 from iiWeapon).
static func mags_for(sys: ShipSystems) -> Array:
	var out: Array = []
	if sys == null:
		return out
	for s in sys.systems:
		var stem := str(s.get("template", "")).get_file().get_basename()
		if MAG_SPECS.has(stem):
			out.append(_mag_record(stem, s))
	return out

static func _mag_record(stem: String, sys_ref: Dictionary) -> Dictionary:
	var m: Dictionary = MAG_SPECS[stem]
	return {"stem": stem, "spec": SPECS[m["projectile"]],
		"projectile": String(m["projectile"]),
		"launch_speed": float(m["launch_speed"]),
		"ammo": int(m["max_ammo"]), "max_ammo": int(m["max_ammo"]),
		"refire_delay": float(m["refire_delay"]), "clock": 0.0,
		"cm": bool(m.get("cm", false)), "ldsi": bool(m.get("ldsi", false)),
		"rocket": bool(m.get("rocket", false)), "sys": sys_ref}

## The debug start's loadout: one full magazine of every player weapon type,
## no fitted subsim behind them (the empty "sys" reads efficiency 1.0).
static func mags_all() -> Array:
	var out: Array = []
	for stem in ["seeker_missile_magazine", "deadshot_missile_magazine",
			"harrower_missile_magazine", "ldsi_missile_magazine",
			"decoy_magazine", "flare_magazine", "gnat_rocket_pod"]:
		out.append(_mag_record(stem, {}))
	return out

static func mag_ready(mag: Dictionary) -> bool:
	var s: Dictionary = mag["sys"]
	if bool(s.get("destroyed", false)):
		return false
	return float(s.get("efficiency", 1.0)) * float(mag["clock"]) \
			> float(mag["refire_delay"]) and int(mag["ammo"]) > 0

func _tick_mags(mags: Array, delta: float) -> void:
	for mag in mags:
		mag["clock"] = float(mag["clock"]) + \
				float((mag["sys"] as Dictionary).get("efficiency", 1.0)) * delta

# icMissileMagazine::Fire 0x100399c0 / icMagazine::Fire 0x10038440:
# clock = 0, ammo -= 1, projectile spawned at the muzzle with
# velocity = ship velocity + muzzle forward * launch_speed.
func fire_magazine(shooter: Node3D, mag: Dictionary, target: Node3D) -> bool:
	if not mag_ready(mag):
		return false
	mag["clock"] = 0.0
	mag["ammo"] = int(mag["ammo"]) - 1
	var fwd: Vector3 = -shooter.global_transform.basis.z
	var vel: Vector3 = (shooter.velocity if "velocity" in shooter
			else Vector3.ZERO) + fwd * float(mag["launch_speed"])
	var spec: Dictionary = mag["spec"]
	if bool(mag["cm"]):
		_spawn_cm(shooter, spec, vel)
	else:
		spawn_missile(shooter, spec, shooter.global_position + fwd * 30.0,
				fwd, vel, target)
	if main != null:
		if bool(mag["cm"]):
			main.audio.play("audio/sfx/cm_launch.wav", -6.0)
		elif bool(mag["ldsi"]):
			main.audio.play("audio/sfx/ldsi_launch.wav", -6.0)
		else:
			main.audio.play("audio/sfx/missile_us.wav", -6.0)
	return true

# =============================================================================
# missiles
# =============================================================================

func spawn_missile(shooter: Node3D, spec: Dictionary, pos: Vector3,
		fwd: Vector3, vel: Vector3, target: Node3D) -> Dictionary:
	var node := Node3D.new()
	get_parent().add_child(node)
	node.global_position = pos
	node.global_transform.basis = Basis.looking_at(fwd, Vector3.UP)
	var model_rel := "data/avatars/avatars/%s/setup.gltf" % str(spec.get("model", "missile"))
	if main != null:
		var model: Node3D = main._load_gltf(model_rel)
		if model != null:
			node.add_child(model)
	var rec := {"node": node, "vel": vel, "age": 0.0, "state": ST_EJECT,
		"spec": spec, "shooter": shooter, "target": null, "seek_clock": 0.0,
		"saved_target": null, "decoy": null, "trail": [], "trail_node": null,
		"warned": false, "cls": str(spec["cls"])}
	# icMissileMagazine::Fire calls SetTarget with the launch target; type-2
	# missiles arm straight into tracking (icMissile::Simulate case 1). Mines
	# (icMine ctor 0x1006baf0 sets eMissileType 0) arm into SEEK instead.
	if rec["cls"] != "icMine" and rec["cls"] != "icRocket":
		rec["target"] = target
	missiles.append(rec)
	return rec

func _spawn_cm(owner: Node3D, spec: Dictionary, vel: Vector3) -> void:
	var node := Node3D.new()
	get_parent().add_child(node)
	# launched "backwards": the CM mounts eject at low launch_speed and coast
	# ballistically (icCounterMeasure::Integrate 0x100642d0: pos += vel * dt)
	node.global_position = owner.global_position
	# The counter avatar (avatars/counter/setup) is a single <glow_and_flare>
	# null with no geometry -- a flare IS a glow. A light is the closest
	# stand-in we can spawn without inventing a draw.
	var glow := OmniLight3D.new()
	glow.light_color = Color(1.0, 0.85, 0.5)
	glow.light_energy = 6.0
	glow.omni_range = 200.0
	node.add_child(glow)
	# the counter avatar's FcLoopSoundNode (ini:/audio/sfx/countermeasure):
	# cm_loop, no trigger channel -- it loops for the CM's whole life
	if main != null and main.audio != null:
		var stream: AudioStreamWAV = main.audio._load_wav("audio/sfx/cm_loop.wav")
		if stream != null:
			stream.loop_mode = AudioStreamWAV.LOOP_FORWARD
			var sp := AudioStreamPlayer3D.new()
			sp.stream = stream
			sp.unit_size = 250.0  # min_range=250
			node.add_child(sp)
			sp.play()
	cms.append({"node": node, "vel": vel, "age": 0.0, "spec": spec,
		"owner": owner, "engaged": false,
		"engage_time": float(spec.get("engage_time", 5.0)),
		"lifetime": float(spec.get("lifetime", 20.0))})

func _ship_radius(t: Node3D) -> float:
	if t is AiShip:
		return maxf(float((t as AiShip).radius), 20.0)
	if main != null and t == main.ship:
		return maxf(float(main.ship_stats.get("radius", 60.0)), 20.0)
	return 60.0

func _ship_vel(t: Node3D) -> Vector3:
	return t.velocity if (t != null and "velocity" in t) else Vector3.ZERO

# icMissile::FindTarget 0x1006c3f0: nearest ship-type sim inside sensor_radius.
# An AI missile takes only ships its faction is hostile to; a missile whose
# aggressor is the player takes anything on the player's contact list.
func _find_target(rec: Dictionary) -> Node3D:
	var reach := float((rec["spec"] as Dictionary).get("sensor_radius", 0.0))
	if reach <= 0.0 or main == null:
		return null
	var pos: Vector3 = (rec["node"] as Node3D).global_position
	var best: Node3D = null
	var best_d := reach * reach
	var cands: Array = main.ai_ships.duplicate()
	cands.append(main.ship)
	for t in cands:
		if t == rec["shooter"] or not is_instance_valid(t):
			continue
		if rec["shooter"] is AiShip and t != main.ship:
			continue  # AI factions are only hostile to the player here
		var d: float = pos.distance_squared_to((t as Node3D).global_position)
		if d <= best_d:
			best_d = d
			best = t
	return best

# icMissile::OnTracking 0x1000f8c0 -> icShip::OnIncomingMissile 0x10074f20:
# warn the player pilot (pilot+0x6c / the +0xa8 id list the HUD pips read) and
# ask the target's countermeasure magazine for an auto launch.
func _on_tracking(rec: Dictionary) -> void:
	var t: Node3D = rec["target"]
	if t == null or not is_instance_valid(t):
		return
	if main != null and t == main.ship:
		if not rec["warned"]:
			rec["warned"] = true
			# icPlayerPilot::OnIncomingMissile logs event 0x30; the tone is the
			# HUD cue table's entry 3 = missile_warning (0x100e8220 ->
			# 0x101740d8), NOT the klaxon (cue 4)
			main.audio.play("audio/hud/missile_warning.wav", -8.0)
			main.hud.warn("INCOMING MISSILE", 2.5)
	elif t is AiShip:
		# icShip::OnIncomingMissile: the first ready icCounterMeasureMagazine
		# gets the missile id in its fire-request slot (+0x84) and its
		# Simulate (0x1002d550) force-fires it next frame.
		for mag in _mags_of(t as AiShip):
			if bool(mag["cm"]) and mag_ready(mag):
				fire_magazine(t, mag, null)
				break

func _mags_of(ai: AiShip) -> Array:
	var key := ai.get_instance_id()
	if not _ai_mags.has(key):
		_ai_mags[key] = mags_for(ai.sys)
	return _ai_mags[key]

func _physics_process(delta: float) -> void:
	if main == null:
		return
	_ai_fire(delta)
	_step_cms(delta)
	_step_missiles(delta)
	_update_incoming()

# --- AI launch decisions ------------------------------------------------
# icMissileMagazine::ComputeFiringSolution 0x10039d50 (auto mode): each ready
# frame the launch rolls rand() <= ammo_fraction * launch_likelihood (0.005;
# 0.01 under a missile-boat order, which we do not have). LDSI magazines only
# fire at a target whose LDS drive is engaged. Rockets (icMagazine::
# IsReadyToFire 0x10038350 + CFS 0x10038660) roll 0.1 * ammo_fraction and
# need a ballistic solution within radius + 15 m.
func _ai_fire(delta: float) -> void:
	for a in main.ai_ships:
		if not is_instance_valid(a) or not (a is AiShip):
			continue
		var ai := a as AiShip
		var mags := _mags_of(ai)
		if mags.is_empty():
			continue
		_tick_mags(mags, delta)
		if ai.behavior != "attack" \
				or (ai.disrupt_time > 0.0 and ai.disrupt_full):
			continue
		var player: Node3D = main.ship
		for mag in mags:
			if bool(mag["cm"]) or not mag_ready(mag):
				continue
			var frac := float(mag["ammo"]) / float(mag["max_ammo"])
			if bool(mag["ldsi"]):
				if main.lds_state != 2:
					continue
				if randf() > frac * LAUNCH_LIKELIHOOD:
					continue
			elif bool(mag["rocket"]):
				if randf() > frac * ROCKET_LIKELIHOOD:
					continue
				if not _rocket_solution(ai, mag, player):
					continue
			else:
				if randf() > frac * LAUNCH_LIKELIHOOD:
					continue
			fire_magazine(ai, mag, player)
			break

# icMagazine::ComputeFiringSolution 0x10038660: an unguided round at
# launch_speed (plus ignition thrust; the original solves launch_speed only)
# must pass within target_radius + 15 m, lead time 0..30 s.
func _rocket_solution(shooter: Node3D, mag: Dictionary, target: Node3D) -> bool:
	if target == null or not is_instance_valid(target):
		return false
	var basis := shooter.global_transform.basis
	var rel_p: Vector3 = (target.global_position - shooter.global_position) * basis
	var rel_v: Vector3 = (_ship_vel(target) - _ship_vel(shooter)) * basis
	var speed := float(mag["launch_speed"]) + \
			float((mag["spec"] as Dictionary).get("accel", 0.0)) * 2.0
	if speed <= 0.0:
		return false
	var t := -rel_p.z / speed
	if t < 0.0 or t > CFS_MAX_LEAD:
		return false
	var at_t := rel_p + rel_v * t
	return Vector2(at_t.x, at_t.y).length() < _ship_radius(target) + FIRING_TOLERANCE

# --- countermeasures ------------------------------------------------------
# icCounterMeasure::Simulate 0x10064140. The seduction is a single event: the
# frame the engage timer (engage_time, INI; started at launch, 0x10064130)
# expires, every icSimTrackingMissile currently targeting the CM's OWNER rolls
# icSimTrackingMissile::Decoy (0x1007d240): seduced iff the CM sits within
# (1 - level) * 500 m of the victim. When the CM dies, OnDecoyExpired
# (0x1007d2d0): a missile further than level * 5000 m from the dead CM loses
# lock for good; otherwise it reacquires its old target (and re-warns it).
func _step_cms(delta: float) -> void:
	var i := cms.size() - 1
	while i >= 0:
		var cm: Dictionary = cms[i]
		var node: Node3D = cm["node"]
		cm["age"] = float(cm["age"]) + delta
		node.global_position += (cm["vel"] as Vector3) * delta
		if not bool(cm["engaged"]) and float(cm["age"]) >= float(cm["engage_time"]):
			cm["engaged"] = true
			_cm_engage(cm)
		if float(cm["age"]) > float(cm["lifetime"]):
			_cm_expire(cm)
			node.queue_free()
			cms.remove_at(i)
		i -= 1

func _cm_engage(cm: Dictionary) -> void:
	var owner: Node3D = cm["owner"]
	if owner == null or not is_instance_valid(owner):
		return
	var cm_pos: Vector3 = (cm["node"] as Node3D).global_position
	for rec in missiles:
		if rec["cls"] != "icSimTrackingMissile" or rec["decoy"] != null:
			continue
		if rec["target"] != owner:
			continue
		var level := float((rec["spec"] as Dictionary).get("level", 1.0))
		if cm_pos.distance_to(owner.global_position) \
				<= (1.0 - level) * DECOY_RANGE_L0:
			rec["saved_target"] = rec["target"]
			rec["decoy"] = cm
			rec["target"] = null  # now chasing the CM node
			rec["warned"] = false

func _cm_expire(cm: Dictionary) -> void:
	var cm_pos: Vector3 = (cm["node"] as Node3D).global_position
	for rec in missiles:
		if rec["decoy"] != cm:
			continue
		rec["decoy"] = null
		var level := float((rec["spec"] as Dictionary).get("level", 1.0))
		var pos: Vector3 = (rec["node"] as Node3D).global_position
		if pos.distance_to(cm_pos) > level * REACQUIRE_RANGE_L1:
			rec["target"] = null
			rec["saved_target"] = null
			rec["state"] = ST_DEAD  # SetTarget(0): type 2 -> state 6
		else:
			rec["target"] = rec["saved_target"]
			rec["saved_target"] = null
			_on_tracking(rec)

# --- the missile state machine -------------------------------------------
func _step_missiles(delta: float) -> void:
	var i := missiles.size() - 1
	while i >= 0:
		var rec: Dictionary = missiles[i]
		if _step_missile(rec, delta):
			var node: Node3D = rec["node"]
			var tn = rec["trail_node"]
			if tn != null and is_instance_valid(tn):
				(tn as Node3D).queue_free()
			if is_instance_valid(node):
				node.queue_free()
			missiles.remove_at(i)
		i -= 1

# returns true when the record is finished
func _step_missile(rec: Dictionary, delta: float) -> bool:
	var node: Node3D = rec["node"]
	if not is_instance_valid(node):
		return true
	var spec: Dictionary = rec["spec"]
	rec["age"] = float(rec["age"]) + delta
	var age := float(rec["age"])
	var from := node.global_position

	if rec["cls"] == "icRocket":
		# icRocket::Integrate 0x1006fe30: after a fixed 0.6 s ignition delay
		# (0x1011bb94) velocity += facing * acceleration * dt, no speed cap,
		# no guidance.
		if age >= ROCKET_IGNITION:
			rec["vel"] = (rec["vel"] as Vector3) \
					- node.global_transform.basis.z * float(spec["accel"]) * delta
	else:
		if not _step_guidance(rec, node, spec, delta):
			return true  # detonated by TargetInRange

	# the lz channel lights the motor: the avatar's flight-scream sound node
	# rides the same channel as the exhaust (see FLIGHT_SOUNDS)
	var burning: bool = (rec["cls"] == "icRocket" and age >= ROCKET_IGNITION) \
			or (rec["cls"] != "icRocket" and int(rec["state"]) >= ST_SEEK)
	if burning and not bool(rec.get("burning", false)):
		rec["burning"] = true
		_start_flight_sound(rec, node, spec)

	node.global_position = from + (rec["vel"] as Vector3) * delta
	_update_trail(rec, node, delta)

	# lifetime: icMissile::Simulate tail -- expiry EXPLODES a missile
	# (vtable +0xd8 then Destroy); iiProjectile::Simulate 0x1006ef90 just
	# Destroy()s a rocket. lifetime -1 (mines) never expires.
	var life := float(spec.get("lifetime", 20.0))
	if life >= 0.0 and age > life:
		if rec["cls"] != "icRocket":
			_explode(rec, node.global_position)
		return true

	# collision sweep (icMissile::OnCollision 0x1006cc30 / icRocket::
	# OnCollision 0x1006ff50). CanCollideWith 0x1006cf90: never the shooter
	# during the first 4 s, never another missile.
	var targets: Array = main.ai_ships.duplicate()
	targets.append(main.ship)
	for t in targets:
		if not is_instance_valid(t):
			continue
		if t == rec["shooter"] and age < LAUNCH_GRACE:
			continue
		var r := _ship_radius(t)
		if not _segment_sphere(from, node.global_position,
				(t as Node3D).global_position, r):
			continue
		_impact(rec, t, _closest_point(from, node.global_position,
				(t as Node3D).global_position))
		return true
	return false

# icMissile::Think 0x1006c350 + Simulate 0x1006c550. The missile is an
# iiThrusterSim flown by its embedded icAITarget brain (+0x2a0) -- Think
# runs icAITarget::Think (0x59a5e) in states 3/4, and Simulate feeds the
# brain's desired velocity/attitude to ComputeForceAndTorque. The steering
# law lives in _steer below.
func _step_guidance(rec: Dictionary, node: Node3D, spec: Dictionary,
		delta: float) -> bool:
	var state := int(rec["state"])
	var chase: Node3D = null
	if rec["decoy"] != null:
		chase = (rec["decoy"] as Dictionary)["node"]
	elif rec["target"] != null and is_instance_valid(rec["target"]):
		chase = rec["target"]
	elif rec["target"] != null:
		rec["target"] = null  # target died: Think() drops the lock
		state = ST_SEEK if rec["cls"] == "icMine" else ST_DEAD
		rec["state"] = state

	match state:
		ST_EJECT:
			# arm (icMissile::Simulate case 1): eMissileType 0/1 (mines) go
			# to SEEK; type 2 (everything a magazine fires) goes straight to
			# TRACK -- and a type-2 with no lock is a dud: Think() finds no
			# target instance and sets state 6.
			if float(rec["age"]) > float(spec.get("arm_time", 0.5)):
				if rec["cls"] == "icMine":
					rec["state"] = ST_SEEK
					rec["seek_clock"] = 0.0
				elif chase == null:
					rec["state"] = ST_DEAD
				else:
					rec["state"] = ST_TRACK
					_on_tracking(rec)
		ST_SEEK:
			_thrust_forward(rec, node, spec, delta)
			rec["seek_clock"] = float(rec["seek_clock"]) - delta
			if float(rec["seek_clock"]) < 0.0:
				rec["seek_clock"] = ACTIVE_SEEK_UPDATE
				var t := _find_target(rec)
				if t != null:
					rec["target"] = t
					rec["state"] = ST_TRACK
					_on_tracking(rec)
		ST_TRACK, ST_HOLD:
			if chase == null:
				return true  # lock already dropped above; coast this frame
			# icMine::Think 0x1006bbb0: drop the lock past sensor_radius
			# (x5 hysteresis while tracking), back to SEEK
			if rec["cls"] == "icMine":
				var rng := node.global_position.distance_to(chase.global_position)
				if rng > float(spec.get("sensor_radius", 0.0)) * MINE_DROP_FACTOR:
					rec["target"] = null
					rec["state"] = ST_SEEK
					return true
				# icMine::Simulate 0x1006bc20: a proximity mine holds station
				if bool(spec.get("proximity", false)) and int(rec["state"]) == ST_TRACK:
					rec["state"] = ST_HOLD
			if int(rec["state"]) == ST_HOLD:
				rec["vel"] = (rec["vel"] as Vector3).move_toward(Vector3.ZERO,
						float(spec.get("accel", 100.0)) * delta)
			else:
				_steer(rec, node, spec, chase, delta)
			# TargetInRange (vtable +0x124): inside explode_radius + target
			# radius -> OnExplodeRadiusEntry + OnExplode + Destroy.
			# icLDSIMissile::TargetInRange 0x1006b7c0 returns the Think fuse
			# flag instead: range < 500 (0x10119fcc). (Its LDS-chase fuse
			# branch needs an LDS drive on the missile; not built.)
			var reach := float(spec.get("explode_radius", 0.0))
			if rec["cls"] == "icLDSIMissile":
				reach = LDSI_FUSE_RANGE
			elif rec["decoy"] == null:
				reach += _ship_radius(chase)
			else:
				# a CM's authored radius is 1 m (sims/weapons/decoy.ini)
				reach += float(((rec["decoy"] as Dictionary)["spec"]
						as Dictionary).get("radius", 1.0))
			if node.global_position.distance_to(chase.global_position) <= reach:
				_explode(rec, node.global_position)
				return false
		ST_DEAD:
			pass  # coast inert until lifetime
	return true

func _start_flight_sound(_rec: Dictionary, node: Node3D,
		spec: Dictionary) -> void:
	if main == null or main.audio == null:
		return
	var fs: Dictionary = FLIGHT_SOUNDS.get(str(spec.get("model", "")), {})
	if fs.is_empty():
		return
	var stream: AudioStreamWAV = main.audio._load_wav(
			"audio/sfx/%s.wav" % str(fs["wav"]))
	if stream == null:
		return
	stream.loop_mode = AudioStreamWAV.LOOP_DISABLED \
			if bool(fs.get("once", false)) else AudioStreamWAV.LOOP_FORWARD
	var p := AudioStreamPlayer3D.new()
	p.stream = stream
	p.pitch_scale = float(fs["pitch"])
	p.unit_size = float(fs["range"])
	node.add_child(p)
	p.play()


func _thrust_forward(rec: Dictionary, node: Node3D, spec: Dictionary,
		delta: float) -> void:
	var want: Vector3 = -node.global_transform.basis.z * float(spec.get("speed", 2800.0))
	rec["vel"] = (rec["vel"] as Vector3).move_toward(want,
			float(spec.get("accel", 300.0)) * delta)

func _steer(rec: Dictionary, node: Node3D, spec: Dictionary, chase: Node3D,
		delta: float) -> void:
	# icMissile::Simulate (0x1006c550) state 3 hands iiThrusterSim::
	# ComputeForceAndTorque a DESIRED VELOCITY (missile+0x37c, the embedded
	# icAITarget's +0xdc) and a desired attitude (+0x3a0): the missile steers
	# its VELOCITY VECTOR with the full per-axis thruster acceleration
	# (380,380,380 on the seeker) -- it never has to point at the target
	# before it can pull toward it. The brain builds that velocity from the
	# bearing to the target (icAITarget::ComputeTargetVector 0x58708: unit
	# direction and range into +0xb0/+0xc8) at maximum speed, and
	# ComputeTargetVelocity (0x5a098) folds the TARGET'S OWN velocity in
	# (+0xbc) -- close along the bearing while matching the target's motion,
	# i.e. a constant-bearing intercept. ComputeAngularControl (0x5e32c)
	# separately aligns the nose to the same vector at the authored angular
	# rates. (The exact control mixing in ComputeLateralControl 0x5b3f4 --
	# damping bands, avoidance, formation offsets -- is ship-AI machinery a
	# missile's order flags 0xc000008 never enable.)
	var speed := float(spec.get("speed", 2800.0))
	var accel := float(spec.get("accel", 300.0))
	var to: Vector3 = chase.global_position - node.global_position
	var fwd: Vector3 = -node.global_transform.basis.z
	var dir := to.normalized() if to.length_squared() > 1e-6 else fwd
	var want_vel: Vector3 = dir * speed + _ship_vel(chase)
	rec["vel"] = (rec["vel"] as Vector3).move_toward(want_vel, accel * delta)
	# nose alignment at the INI yaw/pitch rate (the drawn attitude and the
	# exhaust direction; the thrusters above do the actual steering)
	var max_turn := deg_to_rad(float(spec.get("yaw_rate", 120.0))) * delta
	var angle := fwd.angle_to(dir)
	if angle > 1e-4:
		var axis := fwd.cross(dir)
		if axis.length_squared() < 1e-9:
			axis = node.global_transform.basis.y
		node.global_transform.basis = Basis(axis.normalized(),
				minf(angle, max_turn)) * node.global_transform.basis

# --- warheads ---------------------------------------------------------------
func _impact(rec: Dictionary, t: Node3D, at: Vector3) -> void:
	var spec: Dictionary = rec["spec"]
	# icMissile::OnCollision 0x1006cc30 / icRocket::OnCollision 0x1006ff50:
	# only a warhead with explode_radius == 0 (rockets) applies contact
	# ApplyWeaponDamage(damage, penetration, ..., src=2); a radius warhead
	# does all its damage in the blast. src=2 skips the LDA loop --
	# missiles are not deflectable (icShip::ApplyWeaponDamage 0x10073e2e
	# only runs the LDA scan for source 0).
	if absf(float(spec.get("explode_radius", 0.0))) < 1e-6:
		_contact_damage(rec, t, at)
	_explode(rec, at)

func _contact_damage(rec: Dictionary, t: Node3D, at: Vector3) -> void:
	var spec: Dictionary = rec["spec"]
	var dmg := float(spec.get("damage", 0.0))
	var pen := float(spec.get("penetration", 0.0))
	if dmg <= 0.0:
		return
	if t == main.ship:
		main.hit_player_warhead(dmg, pen, at)
	elif t is AiShip:
		var out: Dictionary = (t as AiShip).hit_by_warhead(dmg, pen, at)
		if bool(out.get("killed", false)):
			main.kill_ai(t as AiShip)
	_disrupt_check(rec, t)

# icMissile::OnExplode 0x1006d1a0.
## Set off a live record where it stands, and hand it back so the caller can see
## it has gone off. sim.Create on a weapon INI followed by isim.Kill is how the
## scripts fire ordnance by hand: iact2mission05 creates an ldsi_missile, PlaceAt
## it on the Marauder group's leader and kills it, which is what drops the whole
## group out of LDS. natives/world.gd routes that Kill here.
func detonate(rec: Dictionary) -> void:
	var node = rec.get("node")
	if node == null or not is_instance_valid(node):
		return
	_explode(rec, (node as Node3D).global_position)


func _explode(rec: Dictionary, at: Vector3) -> void:
	if int(rec["state"]) == ST_EXPLODED:
		return
	rec["state"] = ST_EXPLODED
	var spec: Dictionary = rec["spec"]

	if rec["cls"] == "icLDSIMissile":
		# OnExplodeRadiusEntry 0x1006c9e0: snap to the target, kill the
		# target's LDS run, then ScrambleLDSDrives(field_radius,
		# field_life_time) 0x1006d7c0 -- every ship in the field with an
		# engaged LDS drive is stopped dead and its drive scrambled.
		var field := float(spec.get("field_radius", 30000.0))
		var hold := float(spec.get("field_life_time", 100.0))
		if main.ship != null and at.distance_to(main.ship.global_position) <= field \
				and main.lds_state != 0:
			main.ship.velocity = Vector3.ZERO
		if main.ship != null and at.distance_to(main.ship.global_position) <= field:
			main.disrupt(hold)  # iship.DisruptLDSDrive path already in main
		ExplosionFx.play(main, "ldsi_explosion",
				Transform3D(Basis.IDENTITY, at), 1.0)
		return

	var blast := float(spec.get("blast_radius", 0.0))
	if absf(float(spec.get("explode_radius", 0.0))) >= 1e-6 and blast > 0.0:
		# the blast loop: every sim within blast_radius + its radius takes
		# (1 - dist/reach) * damage -- or flat damage with
		# disable_attenuation -- through iiSim::ApplyDamage (vtable +0xd0):
		# raw hull, NO armour, NO LDA, no subsim criticals.
		var dmg0 := float(spec.get("damage", 0.0))
		var flat := bool(spec.get("disable_attenuation", false))
		var victims: Array = main.ai_ships.duplicate()
		victims.append(main.ship)
		for t in victims:
			if not is_instance_valid(t):
				continue
			var reach := blast + _ship_radius(t)
			var d := at.distance_to((t as Node3D).global_position)
			if d > reach:
				continue
			var dmg := dmg0 if flat else (1.0 - d / reach) * dmg0
			if dmg > 0.0:
				if t == main.ship:
					main.damage_player(dmg, "MISSILE HIT")
				elif t is AiShip and (t as AiShip).damage(dmg):
					main.kill_ai(t as AiShip)
			_disrupt_check(rec, t)

	# the visual: a fireball of min(max(blast, explode, radius), 100) --
	# 100.0 pushed at 0x1006d33x -- (plus a harmless shockwave when large;
	# our sfx table's explosion/small_explosion carry both parts)
	var r := maxf(maxf(blast, float(spec.get("explode_radius", 0.0))),
			float(spec.get("radius", 3.0)))
	r = minf(r, FIREBALL_FLOOR)
	# no sound here: the explosion SCENE carries its own FcSoundNode and
	# ExplosionFx plays it (explosion_fx.gd `sounds`). Playing one on top
	# double-triggered every warhead.
	ExplosionFx.play(main, "explosion" if r >= 50.0 else "small_explosion",
			Transform3D(Basis.IDENTITY, at), maxf(r, 10.0))

# icMissile::CheckForDisruption 0x1006d0b0: disruptor_time scaled by
# 150 / target_radius (m_destroyer_radius 300 * 0.5), clamped 2..30 s.
func _disrupt_check(rec: Dictionary, t: Node3D) -> void:
	var spec: Dictionary = rec["spec"]
	var dt := float(spec.get("disruptor_time", 0.0))
	if dt <= 0.0 or t == null or not is_instance_valid(t):
		return
	var secs: float = clampf(DESTROYER_RADIUS * 0.5 / _ship_radius(t) * dt,
			MIN_DISRUPTOR_TIME, MAX_DISRUPTOR_TIME)
	var full := bool(spec.get("full_disruption", false))
	if t == main.ship:
		main.disrupt_player_systems(secs, full)
	elif t is AiShip:
		(t as AiShip).disrupt(secs, full)

# --- incoming-missile state for the player HUD -------------------------------
# icPlayerPilot::OnIncomingMissile 0x100b0fc0 keeps the id list (+0xa8) the
# HUD draws one pip per entry from, and the nearest range (+0xb4, an
# octagonal-norm approximation: max + 0.34375 * mid + 0.25 * min,
# 0x101191f0/0x101191ec). main.incoming_missiles / main.nearest_missile_range
# mirror those two fields; hud.gd owns the drawing.
func _update_incoming() -> void:
	var list: Array = []
	var nearest := INF
	for rec in missiles:
		if int(rec["state"]) != ST_TRACK or rec["target"] != main.ship:
			continue
		list.append(rec)
		var d: Vector3 = ((rec["node"] as Node3D).global_position
				- main.ship.global_position).abs()
		var hi: float = maxf(d.x, maxf(d.y, d.z))
		var lo: float = minf(d.x, minf(d.y, d.z))
		var mid: float = d.x + d.y + d.z - hi - lo
		nearest = minf(nearest, hi + 0.34375 * mid + 0.25 * lo)
	main.incoming_missiles = list
	main.nearest_missile_range = nearest if list.size() > 0 else -1.0

# --- trails -------------------------------------------------------------
# icMissileTrailAvatar / icRocketTrailAvatar: the avatar INIs
# (data/ini/avatars/*/trail.ini) author texture (redtrail / orangetrail /
# greentrail / bluetrail), min_radius 1.5, max_radius 10, lifetime 2..5 s,
# keyed to the "lz" engine channel (on from state SEEK, icMissile::Simulate
# 0x1006c8xx). The original ribbon draw was not recovered; this spawns the
# repo's additive-billboard machinery (ParticleFx.texture/additive_material)
# with exactly those parameters: a camera-facing strip along the flown path,
# fading out over `lifetime`, radius growing min_radius -> max_radius with age.
func _update_trail(rec: Dictionary, node: Node3D, delta: float) -> void:
	var spec: Dictionary = rec["spec"]
	var tex_name := str(spec.get("trail", ""))
	if tex_name.is_empty():
		return
	var life := float(spec.get("trail_life", 2.0))
	var pts: Array = rec["trail"]
	# lz channel: no exhaust until the motor lights. icMissile::Simulate sets
	# lz = (state >= 2) -- a DEAD (state 6) missile keeps its flame -- and
	# icRocket lights it at the 0.6 s ignition (0x1006fde0).
	var burning: bool = (rec["cls"] == "icRocket" and float(rec["age"]) >= ROCKET_IGNITION) \
			or (rec["cls"] != "icRocket" and int(rec["state"]) >= ST_SEEK)
	for p in pts:
		p["t"] = float(p["t"]) + delta
	while pts.size() > 0 and float((pts[0] as Dictionary)["t"]) > life:
		pts.pop_front()
	if burning:
		pts.append({"pos": node.global_position, "t": 0.0})
		if pts.size() > 120:
			pts.pop_front()
	if pts.size() < 2:
		return
	var tn: MeshInstance3D = rec["trail_node"]
	if tn == null or not is_instance_valid(tn):
		tn = MeshInstance3D.new()
		tn.mesh = ImmediateMesh.new()
		if not _trail_mats.has(tex_name):
			var tex := ParticleFx.texture(main._base(),
					"images/sfx/%s" % tex_name)
			_trail_mats[tex_name] = ParticleFx.additive_material(tex)
		tn.material_override = _trail_mats[tex_name]
		get_parent().add_child(tn)
		rec["trail_node"] = tn
	tn.global_transform = Transform3D.IDENTITY
	var mesh := tn.mesh as ImmediateMesh
	mesh.clear_surfaces()
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	if cam == null:
		return
	mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
	for i in pts.size():
		var p: Dictionary = pts[i]
		var t := float(p["t"]) / life
		var w: float = lerpf(1.5, 10.0, t)  # min_radius / max_radius
		var pos: Vector3 = p["pos"]
		var dir: Vector3 = (pts[mini(i + 1, pts.size() - 1)]["pos"] as Vector3) \
				- (pts[maxi(i - 1, 0)]["pos"] as Vector3)
		var side := dir.cross(cam.global_position - pos)
		side = side.normalized() if side.length_squared() > 1e-6 else Vector3.UP
		var c := Color(1, 1, 1, 1) * (1.0 - t)  # fade with age
		mesh.surface_set_color(c)
		mesh.surface_set_uv(Vector2(t, 0))
		mesh.surface_add_vertex(pos - side * w)
		mesh.surface_set_color(c)
		mesh.surface_set_uv(Vector2(t, 1))
		mesh.surface_add_vertex(pos + side * w)
	mesh.surface_end()

# --- geometry helpers (weapons.gd idiom) -------------------------------------
func _closest_point(a: Vector3, b: Vector3, c: Vector3) -> Vector3:
	var ab := b - a
	var t := clampf((c - a).dot(ab) / maxf(ab.length_squared(), 1e-6), 0.0, 1.0)
	return a + ab * t

func _segment_sphere(a: Vector3, b: Vector3, c: Vector3, r: float) -> bool:
	return _closest_point(a, b, c).distance_squared_to(c) < r * r

# --- housekeeping (weapons.gd idiom) ------------------------------------------
func clear() -> void:
	for rec in missiles:
		if is_instance_valid(rec["node"]):
			(rec["node"] as Node3D).queue_free()
		var tn = rec["trail_node"]
		if tn != null and is_instance_valid(tn):
			(tn as Node3D).queue_free()
	missiles.clear()
	for cm in cms:
		if is_instance_valid(cm["node"]):
			(cm["node"] as Node3D).queue_free()
	cms.clear()
	_ai_mags.clear()
	if main != null:
		main.incoming_missiles = []
		main.nearest_missile_range = -1.0

func shift_world(offset: Vector3) -> void:
	for rec in missiles:
		if is_instance_valid(rec["node"]):
			(rec["node"] as Node3D).global_position -= offset
		for p in rec["trail"]:
			p["pos"] = (p["pos"] as Vector3) - offset
	for cm in cms:
		if is_instance_valid(cm["node"]):
			(cm["node"] as Node3D).global_position -= offset
