class_name Turrets
extends Node3D
# Turrets, armed stations and beam weapons, recovered from iwar2.dll (GOG
# build, image base 0x10000000) and the shipped INI tree. Same idiom as
# missiles.gd: plain dictionaries, swept-sphere hits, damage through the
# recovered chain. The full disassembly notes live in docs/combat.md
# ("Turrets and guns" / "Beam weapons").
#
# @element icTurret
# @element iiGun
# @element icSlugThrower
# @element icBeamProjector
# @element icBeam
# @element icBeamAvatar
# @element-stub icTurretShip -- GENUINE GAP: the player turret-fighter hull
#   (an icShip that yaws itself at the contact target like a turret,
#   icTurretShip::Think 0x10034700, lead solved at a hardcoded 6000 m/s,
#   FUN_10034200). Only sims/ships/player/turret_fighter*.ini use it; the
#   remote-piloting/carrier loadout system that launches them is not built.
#   Should move to game/scripts/element_markers.gd.

# --- iiGun class statics (flux.ini [iiGun]; registered at 0x10034c20) --------
const MIN_TRAVEL_TIME := 0.4      # m_min_travel_time (flux.ini; FindAimPoint 0x10035170)
const MIN_SPEED_FRACTION := 0.75  # floor on the solved bolt speed, 0x10117d8c
const MAX_JITTER_ANGLE := 0.75    # m_max_jitter_angle (flux.ini)
const MAX_JITTER_RADIUS := 1.5    # m_max_jitter_radius (flux.ini), x target radius cap
const JITTER_ANGLE_UNIT := 0.0349066  # 2 deg in rad, 0x10119adc (iiGun::CFS 0x10035310)
const JITTER_MIN_TARGET_RADIUS := 40.0  # 0x1011849c: smaller targets get no jitter roll
const JITTER_DIE := 4             # FcRandom::Int(0, 4 - skill); no pilot rolls 0..4
# the octagonal-norm coefficients the jitter distance uses (0x101191f0/0x101191ec)
const OCT_MID := 0.34375
const OCT_MIN := 0.25

# --- icTurret (property map 0x10032960; Simulate 0x10033570) ------------------
const TURRET_SCAN_RANGE := 25000.0  # FindNewTarget 0x10033890: 6.25e8 m^2
const MODE_FULL := 0     # turret_mode 0: self-controlled, FindNewTarget
const MODE_CONTACT := 1  # 1: fire-request/designated target (SetMode 0x10033800)
const MODE_PD := 2       # 2: point defence -- targets hostile missiles only

# --- icBeamProjector / icBeam -------------------------------------------------
const BEAM_RAMP_TIME := 0.75    # icBeam::Think 0x100652c0: ramp += dt / 0.75 (0x1011ab30)
const BEAM_PEN_SCALE := 7.5     # 0x1011ac34: applied pen = INI penetration * 7.5
const BEAM_HEAT_SCALE := 5.0    # flux.ini [icBeamProjector] heat_scale (default 1.0, 0x1015b2c4)
const BEAM_DEFAULT_RANGE := 1500.0  # icBeamProjector::Range fallback, 0x1011961c
const BEAM_RAMP_START := 0.01   # 0x3c23d70a, icBeam ctor 0x100650a0 / reset 0x10065830
# eDamageSource 1 (icBeam::Think pushes 1 at 0x10065394): skips the LDA loop,
# armour still applies. ship_systems' SRC_BYPASS is the same path.
const BEAM_SRC := ShipSystems.SRC_BYPASS

# authored beam glow colours (data/avatars/avatars/*/setup.gltf light extras)
const BEAM_COLORS := {
	"antimatter_beam": Color8(149, 1, 211), "capital_ship_beam": Color8(149, 0, 211),
	"mining_beam": Color8(62, 220, 255), "comms_laser_beam": Color8(62, 220, 255),
	"cutting_beam": Color8(253, 165, 0), "nps_cutting_beam": Color8(253, 165, 0),
}
# texture stems under images/sfx, matched by name (the LWS texture binding did
# not survive the avatar extract; am_beam/cutting_beam/beam_blue are the only
# shipped beam streak textures)
const BEAM_TEXTURES := {
	"antimatter_beam": "am_beam", "capital_ship_beam": "am_beam",
	"mining_beam": "beam_blue", "comms_laser_beam": "beam_blue",
	"cutting_beam": "cutting_beam", "nps_cutting_beam": "cutting_beam",
}

static var instance: Turrets = null

var main: Node3D
var batteries: Array = []   # {owner|rec, guns, beams, armed, locked}
var _seen: Dictionary = {}  # AiShip instance id -> true
var _beam_mats: Dictionary = {}
var _time := 0.0            # game-time clock for the fire logs

func _enter_tree() -> void:
	instance = self
	# main fits the player during its _ready, BEFORE this deferred node
	# exists (missiles.gd bootstraps it a frame later) -- pick the fitted
	# beams up now
	if main != null and main.sys != null:
		main.player_beams = set_player_battery(main)

func _exit_tree() -> void:
	if instance == self:
		instance = null

# =============================================================================
# battery construction
# =============================================================================

static func _f(props: Dictionary, key: String, dft: float) -> float:
	return float(props.get(key, dft))

# icBullet spec out of the projectile INI (same keys weapons.gd carries;
# half_time ctor default is 2.0, docs/combat.md section 2)
static func bolt_spec(tpl: String) -> Dictionary:
	var ini: Dictionary = ShipSystems.read_ini(tpl)
	var p: Dictionary = ini["props"]
	# The fire sound is the weapon's own FcSoundNode (play_channel=fire), which
	# weapons.gd already carries per bolt class; a gatling must not report as a
	# light PBC. Unknown bolts keep the light PBC as before.
	var known: Dictionary = PbcWeapons.BOLT_BY_PROJECTILE.get(tpl.get_file(), {})
	var out := {"damage": _f(p, "damage", 0.0),
		"penetration": _f(p, "penetration", 0.0),
		"half_time": _f(p, "half_time", 2.0), "speed": _f(p, "speed", 6000.0),
		"lifetime": _f(p, "lifetime", 1.6),
		"wav": str(known.get("wav", "audio/sfx/light_pbc.wav")),
		"bypass_shields": int(_f(p, "bypass_shields", 0.0)) != 0}
	# streak texture / length cap / burst layout come from the bolt AVATAR, not
	# the INI -- weapons.gd's table carries the extraction; without a row the
	# renderer's defaults stand
	for vis in ["texture", "length", "burst", "burst_lengths"]:
		if known.has(vis):
			out[vis] = known[vis]
	return out

# a gun mount: icTurret (slews) or icCannon (fixed, wide fire arc -- the
# stations' nps_pseudo_turret). Property map offsets in docs/combat.md.
static func _make_gun(tpl: String, sysref: Dictionary, pos: Vector3,
		basis: Basis) -> Dictionary:
	var ini: Dictionary = ShipSystems.read_ini(tpl)
	var p: Dictionary = ini["props"]
	var cls: String = ini["class"]
	var mode := int(_f(p, "turret_mode", 0.0))
	return {"kind": "gun", "cls": cls, "tpl": tpl, "sys": sysref,
		"bolt": bolt_spec(str(p.get("projectile_template", ""))),
		"h_arc": _f(p, "horizontal_fire_arc", 0.0),
		"v_arc": _f(p, "vertical_fire_arc", 0.0),
		"refire": _f(p, "refire_delay", 1.0),
		"capacity": _f(p, "capacity", 0.0),
		"cost": _f(p, "shot_energy_cost", 0.0),
		"power": _f(p, "power", 0.0),
		# icSlugThrower's ammo pair (+0xd0 max, +0xd4 current, both ints;
		# ctor 0x10032660). -1 = not ammo-limited, the convention
		# ship_systems.gd:409 already uses. nps_assault_cannon starts 500/1000.
		"ammo": int(_f(p, "ammo_count", _f(p, "max_ammo_count", -1.0))),
		"ammo_max": int(_f(p, "max_ammo_count", -1.0)),
		# icTurret ctor defaults (0x10032d80): reacquire FLT_MAX, headings
		# -45/45, elevations 0/45, velocities 0
		"reacq_time": _f(p, "reacquire_time", 3.4e38),
		"mode": mode,
		"min_h": _f(p, "min_heading", -45.0), "max_h": _f(p, "max_heading", 45.0),
		"min_el": _f(p, "min_elevation", 0.0), "max_el": _f(p, "max_elevation", 45.0),
		"stow_h": _f(p, "stow_heading", 0.0), "stow_el": _f(p, "stow_elevation", 0.0),
		"vel_h": _f(p, "max_heading_velocity", 0.0),
		"vel_el": _f(p, "max_elevation_velocity", 0.0),
		"turret": cls == "icTurret",
		"pos": pos, "basis": basis,
		# runtime (icTurret ctor: energy +0x110 = 0, clock 0, angles at stow)
		"heading": _f(p, "stow_heading", 0.0), "elevation": _f(p, "stow_elevation", 0.0),
		"energy": 0.0, "clock": 0.0, "reacq": 3.4e38, "target": null,
		"fired": []}

# an icBeamProjector mount + its icBeam (property maps 0x1002fa20 / 0x10064f20)
static func _make_beam(tpl: String, sysref: Dictionary, pos: Vector3,
		basis: Basis) -> Dictionary:
	var ini: Dictionary = ShipSystems.read_ini(tpl)
	var p: Dictionary = ini["props"]
	var beam_tpl := str(p.get("beam_template", ""))
	var beam_ini: Dictionary = ShipSystems.read_ini(beam_tpl)
	var bp: Dictionary = beam_ini["props"]
	var stem := beam_tpl.get_file().get_basename()
	return {"kind": "beam", "tpl": tpl, "sys": sysref,
		"capacity": _f(p, "capacity", 0.0),
		"drain": _f(p, "beam_power_drain", 0.0),
		"min_fire": _f(p, "min_fire_energy", 0.0),
		"ai_charge": _f(p, "ai_charge_per_second", 0.0),
		"power": _f(p, "power", 0.0),
		"length": _f(bp, "length", BEAM_DEFAULT_RANGE),
		"damage_rate": _f(bp, "damage_rate", 0.0),
		"penetration": _f(bp, "penetration", 0.0),
		"stem": stem,
		"pos": pos, "basis": basis,
		# runtime: icBeamProjector ctor 0x1002fc50 zeroes energy (+0xc4);
		# firing flag +0xcc, live flag +0xcd, ramp icBeam+0x224
		"energy": 0.0, "firing": false, "live": false,
		"ramp": BEAM_RAMP_START, "node": null, "glow": null, "uv": 0.0,
		"burst_damage": 0.0}

# every icTurret / icBeamProjector fitted on an AiShip's subsim list
func _battery_for_ship(ai: AiShip) -> Dictionary:
	var guns: Array = []
	var beams: Array = []
	for s in ai.sys.systems:
		var cls := str(s.get("class", ""))
		var tpl := str(s.get("template", ""))
		var pos: Vector3 = s.get("pos", Vector3.ZERO)
		# icSlugThrower is an iiGun with an ammo store, so it belongs in the
		# battery exactly like a turret; `turret` below is false for it, which
		# routes it down the fixed-mount branch (no slew), as icCannon does.
		# 20 shipped NPC hulls mount nps_assault_cannon -- without this they
		# fell through to ai_ship.gd's generic 0.5 s PBC bolt.
		if cls == "icTurret" or cls == "icSlugThrower":
			guns.append(_make_gun(tpl, s, pos, _null_basis(ai, s)))
		elif cls == "icBeamProjector":
			beams.append(_make_beam(tpl, s, pos, _null_basis(ai, s)))
	if guns.is_empty() and beams.is_empty():
		return {}
	return {"owner": ai, "rec": {}, "ship": true, "guns": guns, "beams": beams,
		"armed": false, "locked": null}

# The mount null's orientation. ship_systems.bind_model keeps only the
# position, so read the setup-scene JSON (where the engine's attach nulls
# live) for the hpb; identity when nothing is found.
func _null_basis(ai: AiShip, s: Dictionary) -> Basis:
	return _ini_null_basis(ai.ini_path, s)

func _ini_null_basis(ini_path: String, s: Dictionary) -> Basis:
	var null_name := str(s.get("null", ""))
	if null_name.is_empty() or ini_path.is_empty():
		return Basis.IDENTITY
	var rec: Dictionary = ShipSystems.ship_record(ini_path)
	return _scene_null_basis(str(rec.get("setup_scene", "")), null_name)

# --- the player's beams (#3) -------------------------------------------------
# icBeamProjector::Fire (0x100300c0), the PLAYER trigger path: light-up needs
# energy above min_fire_energy (+0xb8) -- the full-capacity rule in _step_beam
# is the AI AUTO trigger, a separate recovered gate -- then the beam holds
# until the bank runs dry (energy -= beam_power_drain * dt, off at zero,
# result 4). No target is required: iiWeapon::AttemptToActivateWeapon
# (0x1003ccb0) only checks the pilot's selected id, and the beam goes where
# the mount points. The tug ships one: subsims/systems/player/mining_laser
# (capacity 1200, min_fire_energy 200, beam_power_drain 200).
var _player_battery: Dictionary = {}

## (Re)build the player's beam battery from the fitted loadout. Returns the
## beam dicts for main's secondary cycle; empty when nothing is fitted.
func set_player_battery(mn: Node3D) -> Array:
	if not _player_battery.is_empty():
		_free_battery(_player_battery)
		batteries.erase(_player_battery)
		_player_battery = {}
	var sys: ShipSystems = mn.sys
	if sys == null or mn.ship == null:
		return []
	var beams: Array = []
	for s in sys.systems:
		if str(s.get("class", "")) == "icBeamProjector":
			beams.append(_make_beam(str(s.get("template", "")), s,
					s.get("pos", Vector3.ZERO),
					_ini_null_basis(str(mn.player_ship_ini), s)))
	if beams.is_empty():
		return []
	_player_battery = {"owner": mn.ship, "rec": {}, "ship": true, "guns": [],
		"beams": beams, "armed": false, "locked": null, "player": true}
	batteries.append(_player_battery)
	return beams

var _scene_cache: Dictionary = {}

func _scene_null_basis(scene: String, null_name: String) -> Basis:
	if scene.is_empty():
		return Basis.IDENTITY
	var rel := scene.trim_prefix("lws:/") + ".json"
	if not _scene_cache.has(rel):
		var out: Dictionary = {}
		var f := FileAccess.open(ShipSystems._base().path_join(
				"data/json/scenes").path_join(rel), FileAccess.READ)
		if f != null:
			var parsed: Variant = JSON.parse_string(f.get_as_text())
			if parsed is Dictionary:
				for n in (parsed as Dictionary).get("nodes", []):
					if str(n.get("kind", "")) == "null":
						out[str(n.get("name", "")).to_lower()] = n
		_scene_cache[rel] = out
	var node: Variant = (_scene_cache[rel] as Dictionary).get(null_name.to_lower())
	if node == null:
		return Basis.IDENTITY
	var hpb: Array = node.get("hpb", [0.0, 0.0, 0.0])
	return ExplosionFx._hpb_basis(float(hpb[0]), float(hpb[1]), float(hpb[2]))

# =============================================================================
# arming -- iiSim::ConfigureWeapons 0x1007b8a0
# =============================================================================
# ihabitat.SetArmed(hab, true)        -> ConfigureWeapons(1, 0, 0)
# ihabitat.SetArmed(hab, false)       -> ConfigureWeapons(0, 0, 1)  (lockdown)
# ihabitat.SetArmedWithTarget(hab, t) -> ConfigureWeapons(1, t, 0)
# (handlers in ihabitat.dll @ 0x10002840 / 0x10002910)
# ConfigureWeapons walks the subsims: every icTurret / rear-facing weapon /
# icCounterMeasureMagazine goes to fire mode 2 (AUTO); with a target its id
# lands in the fire-request slot +0x84 and an icTurret is SetMode(1)
# (0x10033800: lock the designated target); with none an icTurret keeps its
# authored mode (2 stays point defence, else 0 = full control).

func arm_station(rec: Dictionary, target: Node3D) -> Dictionary:
	var b := _station_battery(rec)
	if b.is_empty():
		return b
	b["armed"] = true
	b["locked"] = target
	for g in b["guns"]:
		# SetMode 0x10033800: +0x100 = reacquire_time + 1 -> re-target now
		g["reacq"] = float(g["reacq_time"]) + 1.0
	return b

func disarm_station(rec: Dictionary) -> void:
	# LockDownWeapons: mode 0 -- AttemptToActivateWeapon returns 0xc, and
	# icTurret::Simulate slews back to stow
	for b in batteries:
		if b["rec"] == rec:
			b["armed"] = false
			b["locked"] = null

# ConfigureWeaponsForAI semantics for a spawned ship battery (checks/mission use)
func arm_ship(ai: AiShip, target: Node3D) -> Dictionary:
	_scan_ai_ships()
	for b in batteries:
		if b["owner"] == ai:
			b["armed"] = true
			b["locked"] = target
			for g in b["guns"]:
				g["reacq"] = float(g["reacq_time"]) + 1.0
			return b
	return {}

func _station_battery(rec: Dictionary) -> Dictionary:
	for b in batteries:
		if b["rec"] == rec:
			return b
	# stations.json carries the authored subsim list; a map "gunstar" habitat
	# has no avatar of its own and uses the shipped gunstar station record
	# (sims/stations/custom/gunstar.ini: 4 x nps_pseudo_turret on hardpoints)
	var srec := _station_record(rec)
	if srec.is_empty():
		return {}
	var scene := str(srec.get("setup_scene", ""))
	var guns: Array = []
	var beams: Array = []
	for mount in (srec.get("subsims", []) as Array):
		var tpl := str(mount.get("template", ""))
		var ini: Dictionary = ShipSystems.read_ini(tpl)
		var cls: String = ini["class"]
		if cls != "icTurret" and cls != "icCannon" and cls != "icBeamProjector":
			continue
		var nn := str(mount.get("attach_null", ""))
		var pos := Vector3.ZERO
		var basis := _scene_null_basis(scene, nn)  # also warms the cache
		var node: Variant = null
		if not scene.is_empty() and not nn.is_empty():
			node = (_scene_cache.get(scene.trim_prefix("lws:/") + ".json", {})
					as Dictionary).get(nn.to_lower())
		if node != null:
			var p: Array = node.get("pos", [0.0, 0.0, 0.0])
			# LWS -> our world: the map loader negates z (main.gd)
			pos = Vector3(float(p[0]), float(p[1]), -float(p[2]))
		if cls == "icBeamProjector":
			beams.append(_make_beam(tpl, {}, pos, basis))
		else:
			guns.append(_make_gun(tpl, {}, pos, basis))
	if guns.is_empty() and beams.is_empty():
		return {}
	var b := {"owner": null, "rec": rec, "ship": false, "guns": guns,
		"beams": beams, "armed": false, "locked": null}
	batteries.append(b)
	return b

var _station_db: Dictionary = {}

func _station_record(rec: Dictionary) -> Dictionary:
	if _station_db.is_empty():
		var f := FileAccess.open(ShipSystems._base().path_join(
				"data/json/stations.json"), FileAccess.READ)
		if f != null:
			var parsed: Variant = JSON.parse_string(f.get_as_text())
			if parsed is Array:
				for r in parsed:
					_station_db[str(r.get("path", ""))] = r
					var av := str(r.get("avatar", "")).get_file().get_basename()
					if not av.is_empty():
						_station_db["av:" + av.to_lower()] = r
	if str(rec.get("category", "")) == "gunstar":
		return _station_db.get("sims/stations/custom/gunstar.ini", {})
	var stem := str(rec.get("avatar", "")).get_file().get_basename()
	return _station_db.get("av:" + stem.to_lower(), {})

# =============================================================================
# per-frame
# =============================================================================

func _physics_process(delta: float) -> void:
	if main == null:
		return
	_time += delta
	_scan_ai_ships()
	var i := batteries.size() - 1
	while i >= 0:
		var b: Dictionary = batteries[i]
		# a freed AiShip compares == null in Godot 4; test validity directly.
		# `is` on a freed instance ERRORS, so every owner probe below has to
		# go through is_instance_valid first (a save reload frees ships
		# without the kill path, leaving freed owners in un-flagged batteries)
		if typeof(b["owner"]) == TYPE_OBJECT \
				and not is_instance_valid(b["owner"]):
			# a freed owner still holds TYPE_OBJECT (freed == null compares
			# true, but typed assignment from it errors); an authored station
			# battery's owner is a real null and steps on
			_free_battery(b)
			batteries.remove_at(i)
		elif is_instance_valid(b["owner"]) and b["owner"] is AiShip \
				and (b["owner"] as AiShip).dying:
			# a killed sim persists through OnExplode's dramatic sequence,
			# but its weapons died with the crew
			pass
		else:
			_step_battery(b, delta)
		i -= 1

func _scan_ai_ships() -> void:
	for a in main.ai_ships:
		if not (a is AiShip) or not is_instance_valid(a):
			continue
		var ai := a as AiShip
		var key := ai.get_instance_id()
		if _seen.has(key):
			continue
		_seen[key] = true
		if ai.sys == null:
			continue
		var b := _battery_for_ship(ai)
		if not b.is_empty():
			batteries.append(b)

func _battery_xform(b: Dictionary) -> Transform3D:
	var owner: Node3D = b["owner"]
	if owner != null:
		return owner.global_transform
	var rec: Dictionary = b["rec"]
	return Transform3D(Basis.IDENTITY, Vector3(
			float(rec.get("x", 0.0)) - main.px,
			float(rec.get("y", 0.0)) - main.py,
			float(rec.get("z", 0.0)) - main.pz))

func _owner_vel(b: Dictionary) -> Vector3:
	var owner: Node3D = b["owner"]
	if owner != null and "velocity" in owner:
		return owner.velocity
	return Vector3.ZERO

func _step_battery(b: Dictionary, delta: float) -> void:
	var owner: Node3D = b["owner"]
	# an AI ship arms its weapons when it engages (iiSim::ConfigureWeaponsForAI
	# 0x10001590, called by the AI pilot): fire mode 2, target = its victim
	var armed: bool = b["armed"]
	var target: Node3D = null
	if is_instance_valid(b["locked"]):
		target = b["locked"]
	else:
		b["locked"] = null
	if owner is AiShip:
		var ai := owner as AiShip
		if not armed and ai.behavior == "attack":
			armed = true
		if target == null and armed:
			target = main.ship
		# icShip::Disrupt raises subsim flag 0x10: a fully disrupted ship
		# cannot fire (iiWeapon::IsReadyToFire 0x1003cb80)
		if ai.disrupt_time > 0.0 and ai.disrupt_full:
			armed = false
	var base := _battery_xform(b)
	for g in b["guns"]:
		_step_gun(b, g, base, armed, target, delta)
	for beam in b["beams"]:
		_step_beam(b, beam, base, armed, target, delta)

# =============================================================================
# guns -- icTurret::Simulate 0x10033570 + iiGun::ComputeFiringSolution
# 0x10035310 + iiGun::Fire 0x100357e0
# =============================================================================

func _sys_efficiency(g: Dictionary) -> float:
	var s: Dictionary = g["sys"]
	if s.is_empty():
		return 1.0
	if bool(s.get("destroyed", false)):
		return 0.0
	return float(s.get("efficiency", 1.0))

func _step_gun(b: Dictionary, g: Dictionary, base: Transform3D, armed: bool,
		target: Node3D, delta: float) -> void:
	var eff := _sys_efficiency(g)
	# iiGun::Simulate 0x10035030: the refire clock accumulates efficiency * dt
	g["clock"] = float(g["clock"]) + eff * delta
	# icTurret::Simulate tail: energy += TRIWeight * efficiency * power * dt,
	# clamped at capacity (TRIWeight is 1.0 for every non-player ship)
	if float(g["power"]) > 0.0 and float(g["energy"]) < float(g["capacity"]):
		g["energy"] = minf(float(g["energy"]) + eff * float(g["power"]) * delta,
				float(g["capacity"]))

	var mount := base * Transform3D(g["basis"] as Basis, g["pos"] as Vector3)
	var chase: Variant = null
	if armed and eff > 0.0:
		chase = _gun_target(b, g, mount, target, delta)

	# --- aim (icTurret::Simulate: angles to lead point, else stow) ---------
	var want_h := float(g["stow_h"])
	var want_el := float(g["stow_el"])
	var lead := Vector3.ZERO
	var eff_speed := float((g["bolt"] as Dictionary)["speed"])
	if chase != null:
		var out := _lead_point(g, mount, chase)
		lead = out[0]
		eff_speed = out[1]
		var local: Vector3 = mount.affine_inverse() * lead
		var ang := _dir_angles(local)
		if _in_limits(g, ang.x, ang.y):
			want_h = ang.x
			want_el = ang.y
		# else: mode-1 designated target out of the arc -> the original scans
		# for another (FindNewTarget); we just stow this frame
	if bool(g["turret"]):
		# slew, rate-limited (0x10033470)
		g["heading"] = move_toward(float(g["heading"]), want_h,
				float(g["vel_h"]) * delta)
		g["elevation"] = move_toward(float(g["elevation"]), want_el,
				float(g["vel_el"]) * delta)

	if chase == null or not armed:
		return

	# --- fire gate ----------------------------------------------------------
	# iiGun::IsReadyToFire 0x10035120: TRIWeight * clock >= refire_delay;
	# icTurret::IsReadyToFire 0x10033790: power > 0 and energy <
	# shot_energy_cost -> "no energy"; ship overheat blocks (flag 0x200)
	if float(g["clock"]) < float(g["refire"]):
		return
	if float(g["power"]) > 0.0 and float(g["energy"]) < float(g["cost"]):
		return
	# icSlugThrower::IsReadyToFire 0x10032750 returns 8 on an empty store: the
	# gun is skipped, with no auto-switch and no reload (refill is cargo-side,
	# the pod_template key)
	if int(g.get("ammo", -1)) == 0:
		return
	var owner: Node3D = b["owner"]
	if owner is AiShip and (owner as AiShip).sys != null:
		var sys: ShipSystems = (owner as AiShip).sys
		if sys.heat + sys.heat_external >= ShipSystems.HEAT_DAMAGE_THRESHOLD:
			return

	# the muzzle frame: the mount slewed to the current heading/elevation
	# (icTurret::InternalOrientation 0x10033af0); a fixed icCannon is the
	# mount frame itself
	var muzzle := mount
	if bool(g["turret"]):
		muzzle = mount * Transform3D(
				Basis(Vector3.UP, deg_to_rad(float(g["heading"]))) *
				Basis(Vector3.RIGHT, deg_to_rad(float(g["elevation"]))),
				Vector3.ZERO)

	# iiGun::ComputeFiringSolution: range gate (speed * lifetime, iiGun+0xc0)
	var bolt: Dictionary = g["bolt"]
	var range_m := float(bolt["speed"]) * float(bolt["lifetime"])
	var chase_pos := _chase_pos(chase)
	if muzzle.origin.distance_to(chase_pos) > range_m:
		return
	# the solution is the lead point in the muzzle frame, jittered, and must
	# sit inside the (tiny) fire arc: |atan(|x|/z)| deg <= arc/2, z ahead
	# (IsInFireArc 0x10035270)
	var sol: Vector3 = muzzle.affine_inverse() * _jitter(b, g, lead, chase)
	if sol.z >= 0.0:
		return  # forward is -Z here; the original tests its own +Z convention
	var zf := -sol.z
	if rad_to_deg(atan(absf(sol.x) / zf)) > float(g["h_arc"]) * 0.5:
		return
	if rad_to_deg(atan(absf(sol.y) / zf)) > float(g["v_arc"]) * 0.5:
		return

	# --- Fire (icTurret::Fire 0x100337d0 -> iiGun::Fire 0x100357e0) --------
	g["energy"] = maxf(0.0, float(g["energy"]) - float(g["cost"]))
	g["clock"] = 0.0
	if int(g.get("ammo", -1)) > 0:
		g["ammo"] = int(g["ammo"]) - 1  # icSlugThrower::Fire 0x100327f0
	# the bolt flies at the SOLVED speed; lifetime and half_time scale by
	# speed/solved so range in metres is preserved (0x10035ad0 block)
	var spec: Dictionary = bolt.duplicate()
	var ratio := float(bolt["speed"]) / maxf(eff_speed, 1.0)
	spec["speed"] = eff_speed
	spec["lifetime"] = float(bolt["lifetime"]) * ratio
	spec["half_time"] = float(bolt["half_time"]) * ratio
	var dir := (muzzle * sol - muzzle.origin).normalized()
	var shooter: Node3D = owner if owner != null else self
	main.weapons._spawn_at(shooter, muzzle.origin, dir, _owner_vel(b), spec)
	if str(bolt.get("wav", "audio/sfx/light_pbc.wav")) != "":
		main.audio.play(str(bolt.get("wav", "audio/sfx/light_pbc.wav")), -10.0)
	var shots: Array = g["fired"]
	shots.append(_time)
	if shots.size() > 32:
		shots.pop_front()

# icTurret::FindNewTarget 0x10033890 (every reacquire_time in modes 0/2), or
# the designated target (mode 1 semantics via SetMode 0x10033800)
func _gun_target(b: Dictionary, g: Dictionary, mount: Transform3D,
		designated: Node3D, delta: float) -> Variant:
	# ConfigureWeapons with a target puts every icTurret in SetMode(1) -- the
	# designated target overrides even point-defence mode (0x1007bd20 block)
	if designated != null:
		g["target"] = designated
		return designated
	var t: Variant = g["target"]
	if t is Dictionary:
		if not main.missiles.missiles.has(t):
			t = null
	elif not is_instance_valid(t):
		t = null
	g["reacq"] = float(g["reacq"]) + delta
	if float(g["reacq"]) > float(g["reacq_time"]):
		g["reacq"] = 0.0
		t = _find_new_target(b, g, mount)
	g["target"] = t
	return t

func _find_new_target(b: Dictionary, g: Dictionary, mount: Transform3D) -> Variant:
	# 25 km scan. Hostility in the remaster is two-sided: an armed NPC/station
	# battery is hostile to the player, so its guns take the player (and, in
	# point-defence mode, the player's tracking missiles -- the original takes
	# any missile whose AGGRESSOR is hostile, 0x100339xx).
	var best: Variant = null
	var best_d := TURRET_SCAN_RANGE * TURRET_SCAN_RANGE
	if int(g["mode"]) == MODE_PD:
		for rec in main.missiles.missiles:
			if rec["shooter"] == b["owner"] or int(rec["state"]) >= Missiles.ST_EXPLODED:
				continue
			var d: float = mount.origin.distance_squared_to(
					(rec["node"] as Node3D).global_position)
			if d < best_d:
				best_d = d
				best = rec
		return best
	# Ship targets. The original scans every sim within 25 km and keeps the
	# nearest whose faction Feeling is hostile (FUN_10033de0). The remaster
	# has one hostility axis: an engaged AI ship's battery takes the player.
	# A station battery armed bare (SetArmed(x,1), no target) stays idle --
	# the shipped scripts (istation.pog) always arm WITH a target, and the
	# map records carry no usable faction feeling to scan by.
	if not (b["owner"] is AiShip):
		return null
	var t: Node3D = main.ship
	if t == null or b["owner"] == t:
		return null
	var d2: float = mount.origin.distance_squared_to(t.global_position)
	if d2 > best_d:
		return null
	# the original prefers an in-arc candidate but falls back to the last
	# hostile seen even out of arc (0x10033890 tail); with one candidate the
	# distinction vanishes
	return t

func _chase_pos(chase: Variant) -> Vector3:
	if chase is Dictionary:
		return ((chase as Dictionary)["node"] as Node3D).global_position
	return (chase as Node3D).global_position

func _chase_vel(chase: Variant) -> Vector3:
	if chase is Dictionary:
		return (chase as Dictionary)["vel"]
	var n := chase as Node3D
	return n.velocity if "velocity" in n else Vector3.ZERO

func _chase_radius(chase: Variant) -> float:
	if chase is Dictionary:
		return float(((chase as Dictionary)["spec"] as Dictionary).get("radius", 3.0))
	var n := chase as Node3D
	if n is AiShip:
		return maxf(float((n as AiShip).radius), 20.0)
	if main != null and n == main.ship:
		return maxf(float(main.ship_stats.get("radius", 60.0)), 20.0)
	return 60.0

# iiGun::FindAimPoint 0x10035170: travel = max(dist/speed, min_travel_time),
# solved speed = max(dist/travel, 0.75 * muzzle speed); aim = pos + vel * travel.
# Returns [world aim point, solved speed].
func _lead_point(g: Dictionary, mount: Transform3D, chase: Variant) -> Array:
	var speed := float((g["bolt"] as Dictionary)["speed"])
	var rel_p := _chase_pos(chase) - mount.origin
	var rel_v := _chase_vel(chase)  # target vel; muzzle vel added at launch
	var dist := rel_p.length()
	var travel := maxf(dist / maxf(speed, 1.0), MIN_TRAVEL_TIME)
	var solved := dist / travel
	if solved < speed * MIN_SPEED_FRACTION:
		solved = speed * MIN_SPEED_FRACTION
		travel = dist / solved
	return [_chase_pos(chase) + rel_v * travel, solved]

# the AI miss model (iiGun::ComputeFiringSolution 0x10035310): unless
# no_jitter, roll FcRandom::Int(0, 4 - skill); on > 0 push the aim point
# sin(rand^2 * max_jitter_angle * 2deg) * octnorm(dist) off target, capped at
# target_radius * max_jitter_radius, in a random direction. Targets smaller
# than 40 m radius (0x1011849c) skip the roll entirely.
func _jitter(b: Dictionary, _g: Dictionary, lead: Vector3, chase: Variant) -> Vector3:
	var r := _chase_radius(chase)
	if r < JITTER_MIN_TARGET_RADIUS:
		return lead
	if randi() % (JITTER_DIE + 1) == 0:  # a station gun has no pilot: skill 0
		return lead
	# octagonal norm of the ship-to-target offset (0x100354e6 block)
	var a := (_chase_pos(chase) - _battery_xform(b).origin).abs()
	var hi := maxf(a.x, maxf(a.y, a.z))
	var lo := minf(a.x, minf(a.y, a.z))
	var mid := a.x + a.y + a.z - hi - lo
	var oct := hi + OCT_MID * mid + OCT_MIN * lo
	var t := randf()
	var off: float = sin(t * t * MAX_JITTER_ANGLE * JITTER_ANGLE_UNIT) * maxf(oct, 1.0)
	off = minf(off, r * MAX_JITTER_RADIUS)
	var dir := Vector3(randf() - 0.5, randf() - 0.5, randf() - 0.5)
	dir = dir.normalized() if dir.length_squared() > 1e-6 else Vector3.UP
	return lead + dir * off

# local direction -> (heading, elevation) degrees (FUN_10033000; forward -Z).
# The original folds heading to [0,360); we keep it signed so the authored
# min/max_heading limits (-160..160 etc.) test directly.
func _dir_angles(local: Vector3) -> Vector2:
	var h := rad_to_deg(atan2(-local.x, -local.z))
	var el := rad_to_deg(atan2(local.y, Vector2(local.x, local.z).length()))
	return Vector2(h, el)

# icTurret angle-limit test 0x10033420
func _in_limits(g: Dictionary, h: float, el: float) -> bool:
	if not bool(g["turret"]):
		return true  # a fixed gun's limit IS its fire arc
	return h >= float(g["min_h"]) and h <= float(g["max_h"]) \
			and el >= float(g["min_el"]) and el <= float(g["max_el"])

# =============================================================================
# beams -- icBeamProjector::Simulate 0x1002fee0 / fire path 0x100300c0 /
# icBeam::Think 0x100652c0
# =============================================================================

func _step_beam(b: Dictionary, m: Dictionary, base: Transform3D, armed: bool,
		target: Node3D, delta: float) -> void:
	var eff := _sys_efficiency(m)
	# icBeamProjector::Simulate 0x1002ff19: prev = firing flag (+0xcc);
	# +0xcc = 0; live (+0xcd) = prev
	var was_live: bool = m["firing"]
	m["live"] = was_live
	m["firing"] = false

	var mount := base * Transform3D(m["basis"] as Basis, m["pos"] as Vector3)

	if not was_live:
		# recharge (icBeamProjector::Simulate): from ship power when the
		# projector draws any, plus the AI free charge in AUTO mode
		if float(m["power"]) > 0.0 and float(m["energy"]) < float(m["capacity"]):
			m["energy"] = minf(float(m["energy"])
					+ eff * float(m["power"]) * delta, float(m["capacity"]))
		if armed and float(m["energy"]) < float(m["capacity"]):
			m["energy"] = minf(float(m["energy"])
					+ float(m["ai_charge"]) * delta, float(m["capacity"]))

	# the AUTO trigger (recovered): while idle, charge; at FULL capacity with
	# a live fire-request target, light up and hold the beam until the bank
	# hits zero or the solution is lost
	var want_fire := false
	if bool(b.get("player", false)):
		# the player trigger (icBeamProjector::Fire 0x100300c0): light-up
		# above min_fire_energy, hold until dry, no target gate -- see
		# set_player_battery. The flag is set by main._fire_secondary each
		# held frame and consumed here.
		if bool(m.get("trigger", false)) and eff > 0.0:
			if was_live:
				want_fire = float(m["energy"]) > 0.0
			else:
				want_fire = float(m["energy"]) > float(m["min_fire"])
		m["trigger"] = false
	elif armed and target != null and eff > 0.0:
		if was_live:
			want_fire = float(m["energy"]) > 0.0
		else:
			want_fire = float(m["energy"]) >= float(m["capacity"]) \
					and float(m["energy"]) > float(m["min_fire"])
	# beam CFS (0x100304e0), the AI trigger only: the target must sit in the
	# muzzle cylinder -- ahead, within length, |x| and |y| inside its radius
	if want_fire and target != null and not bool(b.get("player", false)):
		var local: Vector3 = mount.affine_inverse() * target.global_position
		var r := _chase_radius(target)
		if local.z > 0.0 or -local.z > float(m["length"]) \
				or absf(local.x) > r or absf(local.y) > r:
			want_fire = false

	if not want_fire:
		if was_live:
			m["ramp"] = BEAM_RAMP_START  # FUN_10065830: reset on re-activate
		_hide_beam(m)
		return

	if not was_live:
		m["burst_damage"] = 0.0
	m["firing"] = true
	m["live"] = true
	# icBeam::Think: the beam VISUAL extends to full length over 0.75 s; the
	# collision/damage path has no ramp gate (Think applies the recorded
	# nearest contact regardless)
	m["ramp"] = minf(float(m["ramp"]) + delta / BEAM_RAMP_TIME, 1.0)
	var from := mount.origin
	var dir := -mount.basis.z
	# nearest contact along the ray (icBeam::OnCollision 0x10065840 keeps the
	# closest dot(fwd, contact - pos)); the beam SHORTENS to the hit
	var victims: Array = main.ai_ships.duplicate()
	victims.append(main.ship)
	var owner: Node3D = b["owner"]
	var hit: Node3D = null
	var hit_dist := float(m["length"])
	for v in victims:
		if v == owner or not is_instance_valid(v):
			continue
		var vp := (v as Node3D).global_position
		var along := (vp - from).dot(dir)
		if along < 0.0 or along > hit_dist:
			continue
		var r2 := _chase_radius(v)
		if (from + dir * along).distance_squared_to(vp) > r2 * r2:
			continue
		hit_dist = along
		hit = v
	# a station wall is a nearer contact like any other: the beam shortens to
	# it and whatever was behind it takes nothing (same OnCollision
	# closest-contact rule; the wall itself takes no damage here)
	# get_world_3d() is null for the one frame the outgoing scene still ticks
	# after a reload
	if main != null and main.get_world_3d() != null:
		var wq := PhysicsRayQueryParameters3D.create(from,
				from + dir * hit_dist, main.HULL_LAYER)
		var wall: Dictionary = main.get_world_3d() \
				.direct_space_state.intersect_ray(wq)
		if not wall.is_empty():
			var wall_d: float = from.distance_to(wall["position"])
			if wall_d < hit_dist:
				hit_dist = wall_d
				hit = null
	if hit != null:
		m["ramp"] = hit_dist / maxf(float(m["length"]), 1.0)
		var at := from + dir * hit_dist
		# ApplyWeaponDamage(damage_rate * dt, penetration * 7.5, ..., src=1):
		# continuous, LDA cannot deflect it, armour still divides it
		var dmg := float(m["damage_rate"]) * delta
		var pen := float(m["penetration"]) * BEAM_PEN_SCALE
		m["burst_damage"] = float(m["burst_damage"]) + dmg
		if hit == main.ship:
			main.hit_player_warhead(dmg, pen, at)
		elif hit is AiShip:
			var out: Dictionary = (hit as AiShip).hit_by_warhead(dmg, pen, at)
			if bool(out.get("killed", false)):
				main.kill_ai(hit as AiShip)
	# the drain (fire path 0x100300c0): energy -= beam_power_drain * dt; a
	# PLAYER-style beam (ai_charge_per_second == 0, the recovered gate at
	# 0x100301d1 tests |ai_charge| < 1e-6) also heats the ship:
	# internal += sqrt(damage_rate) * heat_scale * dt
	m["energy"] = maxf(0.0, float(m["energy"]) - float(m["drain"]) * delta)
	if absf(float(m["ai_charge"])) < 1e-6:
		var heat_sys: ShipSystems = null
		if owner is AiShip:
			heat_sys = (owner as AiShip).sys
		elif bool(b.get("player", false)):
			heat_sys = main.sys
		if heat_sys != null:
			heat_sys.heat += sqrt(maxf(float(m["damage_rate"]), 0.0)) \
					* BEAM_HEAT_SCALE * delta
	if float(m["energy"]) <= 0.0:
		m["firing"] = false
	var vis := minf(float(m["length"]) * float(m["ramp"]), hit_dist)
	_draw_beam(m, mount, vis, delta)

# --- the visual: icBeamAvatar (draw 0x100bb830, docs/effects.md) -------------
# an axial billboard quad along +Z of the node, half-width = scale.x, length
# driven by the engine to ramp * length (icBeam::Integrate 0x100656f0); u
# scrolls along the length, additive blend. Crossed quads stand in for the
# turn-to-camera, exactly like ExplosionFx.bolt_mesh.
func _draw_beam(m: Dictionary, mount: Transform3D, len_m: float, delta: float) -> void:
	var node: MeshInstance3D = m["node"]
	if node == null or not is_instance_valid(node):
		node = MeshInstance3D.new()
		node.mesh = _beam_mesh(str(m["stem"]))
		get_parent().add_child(node)
		m["node"] = node
		var glow := OmniLight3D.new()
		glow.light_color = BEAM_COLORS.get(str(m["stem"]), Color(1, 1, 1))
		glow.light_energy = 4.0
		glow.omni_range = 120.0
		node.add_child(glow)
		m["glow"] = glow
	node.visible = true
	node.global_transform = mount
	node.scale = Vector3(1, 1, maxf(len_m, 1.0))
	m["uv"] = fmod(float(m["uv"]) + delta * 2.0, 1.0)
	var mat: StandardMaterial3D = _beam_mats.get(str(m["stem"]))
	if mat != null:
		mat.uv1_offset.x = -float(m["uv"])

func _hide_beam(m: Dictionary) -> void:
	var node: MeshInstance3D = m["node"]
	if node != null and is_instance_valid(node):
		node.visible = false

func _beam_mesh(stem: String) -> Mesh:
	# unit-length crossed quad (scaled per frame); half-width = the avatar's
	# authored scale.x (beam_antimatter 1.8, beam_capital 10; mining/cutting 1)
	var width := 1.8 if stem == "antimatter_beam" else \
			(10.0 if stem == "capital_ship_beam" else 1.0)
	if not _beam_mats.has(stem):
		var tex := ParticleFx.texture(main._base(),
				"images/sfx/%s" % str(BEAM_TEXTURES.get(stem, "am_beam")))
		_beam_mats[stem] = ParticleFx.additive_material(tex)
	var mat: StandardMaterial3D = _beam_mats[stem]
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for axis in 2:
		var w := Vector3(width, 0, 0) if axis == 0 else Vector3(0, width, 0)
		var corners := [
			[-w, Vector2(0, 0)], [w, Vector2(0, 1)],
			[w + Vector3(0, 0, -1), Vector2(1, 1)],
			[-w + Vector3(0, 0, -1), Vector2(1, 0)],
		]
		for idx in [0, 1, 2, 0, 2, 3]:
			st.set_uv(corners[idx][1])
			st.add_vertex(corners[idx][0])
	var mesh := st.commit()
	mesh.surface_set_material(0, mat)
	return mesh

# --- housekeeping (weapons.gd idiom) -----------------------------------------
func _free_battery(b: Dictionary) -> void:
	for m in b["beams"]:
		var node: MeshInstance3D = m["node"]
		if node != null and is_instance_valid(node):
			node.queue_free()

func clear() -> void:
	for b in batteries:
		_free_battery(b)
	batteries.clear()
	_seen.clear()

func shift_world(_offset: Vector3) -> void:
	pass  # beam nodes are re-posed from their mounts every physics frame
