class_name ShipSystems
extends RefCounted
# The original damage model, as recovered from iwar2.dll. See docs/combat.md
# for the addresses and the disassembly this is transcribed from.
#
# A ship is a hull (hit_points + armour) plus a list of subsims mounted at named
# nulls in its model. A weapon impact:
#
#   1. bolt ages out its damage        icBullet::OnCollision   0x100630c0
#   2. an LDA may deflect it entirely  icPlayerLDA / icAILDA   0x100acda0 / 0x1002b940
#   3. armour divides what is left     iiSim::ApplyWeaponDamage 0x100796a0
#   4. the hull takes it               iiSim::ApplyDamage      0x10079920
#   5. N subsims take a cut of it      icShip::ApplyWeaponDamage 0x10073cf0
#
# Every constant here is either an INI value from the shipped data or a float
# read out of the PE. Nothing in this file is a guess; the two places where the
# original could not be recovered are marked UNKNOWN.

# flux.ini [icShip] (and defaults.ini, identical)
const CRITICAL_CHANCE_SCALE := 12.0
const CRITICAL_DAMAGE_SCALE := 0.2
const CRITICALS_PER_IMPACT := 0.2
const HEAT_GAIN_FACTOR := 1.0
const HEAT_LOSS_FACTOR := 0.5
const HEAT_DAMAGE_THRESHOLD := 500.0
const HEAT_DAMAGE_RATE := 0.08
# (the PE defaults the runtime flux.ini overrides: gain 1.0 @ 0x1015d5b4,
#  loss 1.0 @ 0x1015d5b8, threshold 500 @ 0x1015d5bc, rate 0.1 @ 0x1015d5c0)

# iwar2.dll immediates
const SPLASH_SCALE := 0.4         # 0x3ecccccd at 0x1007427b
const MIN_CRITICALS := 2          # cmp eax, 2 at 0x10074108
const OVERHEAT_EFFICIENCY := 0.75 # 0x10117d8c, iiShipSystem::Simulate 0x1003bcxx
const DRAIN_BASE := 0.25          # 0x101191ec, drain = (usage*0.75 + 0.25) * power
const DRAIN_USAGE := 0.75         # 0x10117d8c
const UNDERPOWER_RATIO := 0.25    # 0x101191ec
const LDA_MIN_ENERGY := 0.2       # 0x101607e0, icPlayerLDA::m_min_energy
const LDA_MAX_CHANCE := 0.98      # 0x1011c664
const INVULN_HULL_FLOOR := 0.2    # 0x101184ac, iiSim::ApplyDamage
const HEATSINK_MIN_RAMP := 0.2    # 0x101184ac again, icHeatSink::Simulate
const NO_POWERPLANT_POOL := 100000.0  # 0x47c35000, icShip 0x10075f80
const HEAT_DAMAGE_EXTERNAL_MIN := 0.5 # 0x10117738, icShip::SimulateSystems 0x10075f60
const HUD_HEAT_GAUGE_SCALE := 0.8 # 0x10163efc, HUD player feed 0x10108890

# icPlanet exported constants (not INI-tunable in the shipped build) and the
# icSun immediate: proximity heating of the player's ship, icPlanet::Think
# 0x10068380 / icSun::Think 0x1006ab90.
const HEAT_RADIUS_MULTIPLIER := 0.5    # icPlanet::m_heat_radius_multiplier 0x1011af58
const PLANET_HEAT_MULTIPLIER := 10000.0 # icPlanet::m_heat_multiplier 0x1011af54
const SUN_HEAT_FACTOR := 10.0          # 0x101190c0, the sun's extra term

# eDamageSource, from icBullet::OnCollision (setne on bypass_shields) and
# icShip::SimulateSystems (heat passes 3). Source 5 is the alien infection:
# iiThrusterSim::Simulate 0x1007e200 calls ApplyDamage(dt * damage, 5, self).
const SRC_WEAPON := 0
const SRC_BYPASS := 1
const SRC_HEAT := 3
const SRC_INFECTION := 5

# The eight HUD status groups map onto the mountpoint `type` bit flags
# (data/ini/subsims/mountpoints/*.ini) and, for prefitted hulls that name the
# device directly, onto the device's [Class].
const GROUPS := ["DRV", "THR", "LDS", "CAP", "WEP", "SEN", "EPS", "CPU"]

const CLASS_GROUP := {
	"icDrive": "DRV",
	"icThrusters": "THR",
	"icLDSDrive": "LDS",
	"icCapsuleDrive": "CAP",
	"icCannon": "WEP", "icTurret": "WEP", "icSlugThrower": "WEP",
	"icBeamProjector": "WEP", "icMissileLauncher": "WEP",
	"icMissileMagazine": "WEP", "icMagazine": "WEP",
	"icCounterMeasureMagazine": "WEP",
	"icSensor": "SEN", "icActiveSensor": "SEN",
	"icReactor": "EPS", "icEPS": "EPS",
	"icCPU": "CPU",
}

# mountpoint type= -> group, for hulls whose mounts are still empty sockets
const MOUNT_GROUP := {
	4: "EPS", 2: "EPS", 8: "THR", 16: "SEN", 32: "SEN", 64: "LDS",
	256: "DRV", 512: "CAP", 4096: "WEP", 32768: "CPU", 65536: "WEP",
}

static var _ini_cache: Dictionary = {}
static var _ships_cache: Array = []

var hull := 1000.0
var hull_max := 1000.0
var armour := 50.0
var systems: Array = []       # every mounted subsim, in INI order
var ldas: Array = []          # the subset that can deflect (icPlayerLDA/icAILDA)
var heat := 0.0               # icShip +0x288
var heat_external := 0.0      # icShip +0x28c
var invulnerable := false
var killed := false
var disrupt_time := 0.0       # icShip::Disrupt -- subsim disrupted flag 0x10,
var disrupt_full := false     # shields-only (LDA) vs full_disruption warheads
# @element icAlienSwarm (the infection half)
# The act 3 alien infection lives on the SHIP, not a subsim: iiThrusterSim
# +0x258, set by isim.SetAlienInfectionDamage (0x1007ed70), read back by
# AlienInfectionDamage (0x1007ee60). The visual (the sfx/infection crawl) is a
# separate flag: IsAlienEffectOn (0x1007ee70) only tests whether the effect
# node is attached, so damage can tick with the visual off and vice versa.
var infection_damage := 0.0   # hull points per second, continuous
var rng := RandomNumberGenerator.new()
var _repair_pool := 0.0
var _power_pool := 0.0
var _has_reactor := false

# --- loading ---------------------------------------------------------------

static func _base() -> String:
	return ProjectSettings.globalize_path("res://").path_join("..")

static func read_ini(rel: String) -> Dictionary:
	# "ini:/subsims/systems/player/cpu2" -> data/ini/subsims/systems/player/cpu2.ini
	if _ini_cache.has(rel):
		return _ini_cache[rel]
	var path: String = rel
	if path.begins_with("ini:/"):
		path = path.substr(5)
	if not path.ends_with(".ini"):
		path += ".ini"
	var out := {"class": "", "props": {}}
	var f := FileAccess.open(_base().path_join("data/ini").path_join(path), FileAccess.READ)
	if f != null:
		var section := ""
		while not f.eof_reached():
			var line := f.get_line().strip_edges()
			if line.is_empty() or line.begins_with(";"):
				continue
			if line.begins_with("[") and line.ends_with("]"):
				section = line.substr(1, line.length() - 2).to_lower()
				continue
			var eq := line.find("=")
			if eq < 0:
				continue
			var key := line.substr(0, eq).strip_edges().to_lower()
			var val := line.substr(eq + 1).strip_edges()
			var cut := val.find(";")
			if cut >= 0:
				val = val.substr(0, cut).strip_edges()
			if section == "class" and key == "name":
				out["class"] = val.strip_edges().trim_prefix("\"").trim_suffix("\"")
			elif section == "properties":
				out["props"][key] = val
	_ini_cache[rel] = out
	return out

static func ship_record(ini_path: String) -> Dictionary:
	if _ships_cache.is_empty():
		var f := FileAccess.open(_base().path_join("data/json/ships.json"), FileAccess.READ)
		if f != null:
			var parsed: Variant = JSON.parse_string(f.get_as_text())
			if parsed is Array:
				_ships_cache = parsed
	for rec in _ships_cache:
		if rec.get("path", "") == ini_path:
			return rec
	return {}

static func for_ship(ini_path: String) -> ShipSystems:
	var s := ShipSystems.new()
	s.rng.randomize()
	# sims/ships/player/comsec.ini mounts empty *sockets* (subsims/mountpoints/*)
	# that the original's fitting screen fills from the player's inventory. Fit
	# from the game's own already-fitted record instead -- same hull (350 hp / 50
	# armour) -- exactly as main.gd does for tug.ini -> tug_prefitted.ini. An
	# unfitted comsec has no heatsink, only the powerplant's heat_rate=100, so its
	# heat would just integrate up to the clamp at heat_damage_threshold.
	if ini_path == "sims/ships/player/comsec.ini":
		ini_path = "sims/ships/player/comsec_prefitted.ini"
	var rec := ship_record(ini_path)
	var props: Dictionary = rec.get("properties", {})
	s.hull_max = float(props.get("hit_points", 1000))
	s.hull = s.hull_max
	s.armour = float(props.get("armour", 0))
	for mount in (rec.get("subsims", []) as Array):
		s._mount(str(mount.get("template", "")), str(mount.get("attach_null", "")))
	return s

func _mount(template: String, attach_null: String) -> void:
	var ini := read_ini(template)
	var props: Dictionary = ini["props"]
	var cls: String = ini["class"]
	var sys := {
		"name": str(props.get("name", template.get_file())),
		"class": cls,
		"template": template,
		"null": attach_null,
		"group": _group_of(cls, props),
		# iiShipSystem::Load 0x1003bb30: max hit points is a copy of the INI's
		# hit_points, so a 0 there means the subsim cannot be damaged at all.
		"hp": float(props.get("hit_points", 0)),
		"hp_max": float(props.get("hit_points", 0)),
		"power": float(props.get("power", 0)),
		"heat_rate": float(props.get("heat_rate", 0)),
		"repair_rate": float(props.get("repair_rate", 0)),
		"min_eff": float(props.get("minimum_efficiency", 0)),
		"pos": Vector3.ZERO,
		"efficiency": 1.0,
		"usage": 0.0,
		"destroyed": false,
		"underpowered": false,
	}
	if cls == "icReactor":
		# icReactor::Simulate 0x1003a2xx: AddPower(efficiency * output_power)
		sys["output"] = float(props.get("output_power", 0))
		_has_reactor = true
	if cls == "icHeatSink":
		# icHeatSink::Simulate 0x1002ee90: AddHeatRate(-heat_loss_rate * ramp)
		sys["heat_loss_rate"] = float(props.get("heat_loss_rate", 0))
	if cls == "icAutorepair":
		sys["autorepair_rate"] = float(props.get("autorepair_rate", 0))
	if cls == "icPlayerLDA" or cls == "icAILDA":
		sys["lda"] = cls
		sys["coverage"] = float(props.get("coverage", 0))
		sys["field_coverage"] = float(props.get("field_coverage", 0))
		sys["reliability"] = float(props.get("reliability", 0))
		# icPlayerLDA: an energy bank charged by the power supply
		sys["capacity"] = float(props.get("capacity", 0))
		sys["cost"] = float(props.get("shield_energy_cost", 0))
		sys["energy"] = sys["capacity"]
		# icAILDA: a count of deflections that regenerates over recharge_time
		sys["defend_count"] = float(props.get("defend_count", 0))
		sys["recharge_time"] = float(props.get("recharge_time", 1))
		sys["defends"] = sys["defend_count"]
		ldas.append(sys)
	systems.append(sys)

func _group_of(cls: String, props: Dictionary) -> String:
	if CLASS_GROUP.has(cls):
		return CLASS_GROUP[cls]
	if cls == "icMountPoint":
		var t := int(props.get("type", 0))
		if MOUNT_GROUP.has(t):
			return MOUNT_GROUP[t]
	return ""

func bind_model(model: Node3D) -> void:
	# The engine mounts each subsim at the null named in the ship INI; that
	# position is what picks the subsim nearest an impact. Nulls we cannot find
	# stay at the hull origin, which is what an unnamed mount gets anyway.
	if model == null:
		return
	var nulls: Dictionary = {}
	for n in model.find_children("*", "Node3D", true, false):
		nulls[str(n.name).to_lower()] = n
	for sys in systems:
		var key: String = str(sys["null"]).to_lower()
		if key.is_empty() or not nulls.has(key):
			continue
		var node: Node3D = nulls[key]
		sys["pos"] = model.global_transform.affine_inverse() * node.global_position

# --- the damage chain ------------------------------------------------------

static func age_factor(age: float, half_time: float) -> float:
	# icBullet::OnCollision 0x100630e8: past its half_time the bolt's damage
	# halves every further half_time.  f = 2^(age/half_time - 1), age > half.
	if half_time <= 0.0 or age <= half_time:
		return 1.0
	return pow(2.0, age / half_time - 1.0)

static func armour_factor(penetration: float, armour_value: float) -> float:
	# iiSim::ApplyWeaponDamage 0x100796e1:
	#   if (penetration < armour) damage /= pow(2.0, armour/penetration - 1.0)
	# Penetration at or above the armour rating does full damage; there is no
	# bonus for exceeding it.
	if penetration >= armour_value:
		return 1.0
	if penetration <= 0.0:
		return INF
	return pow(2.0, armour_value / penetration - 1.0)

func apply_weapon_damage(damage: float, penetration: float, hit_local: Vector3,
		dir_local: Vector3, source: int = SRC_WEAPON) -> Dictionary:
	# icShip::ApplyWeaponDamage 0x10073cf0.
	var out := {"applied": 0.0, "deflected": false, "hit": "", "killed": false}
	if killed:
		return out
	if source == SRC_WEAPON and disrupt_time <= 0.0:
		# a disrupted LDA does not deflect (icShip::Disrupt raises the subsim
		# disrupted flag 0x10; shields-only disruption exists to strip the LDA)
		for lda in ldas:
			if _lda_deflect(lda, dir_local):
				out["deflected"] = true
				return out
	var af := armour_factor(penetration, armour)
	var applied := 0.0 if is_inf(af) else damage / af
	out["applied"] = applied
	_apply_hull(applied)
	out["killed"] = killed
	if invulnerable or applied <= 0.0 or systems.is_empty():
		return out
	# criticals = int(subsim_count * criticals_per_impact), floor 2.  The first
	# lands on the subsim nearest the impact at full weight; the rest land on
	# uniformly random subsims at 0.4.  The original gates the extra ones on a
	# rand() roll but does not consume an iteration when the roll fails, so it
	# retries until they all land -- the roll changes nothing but the loop count.
	var n: int = maxi(MIN_CRITICALS, int(float(systems.size()) * CRITICALS_PER_IMPACT))
	var first := _nearest_system(hit_local)
	if first >= 0:
		out["hit"] = str(systems[first]["name"])
		_inflict(systems[first], CRITICAL_DAMAGE_SCALE * applied)
	for i in range(1, n):
		var idx := rng.randi_range(0, systems.size() - 1)
		_inflict(systems[idx], CRITICAL_DAMAGE_SCALE * SPLASH_SCALE * applied)
	return out

func apply_damage(amount: float, _source: int = SRC_WEAPON) -> bool:
	# iiSim::ApplyDamage 0x10079920 -- the raw hull path (collision, heat, script
	# damage). No armour, no subsims.
	_apply_hull(amount)
	return killed

func _apply_hull(amount: float) -> void:
	if killed or absf(amount) < 1e-6:
		return
	hull -= amount
	if invulnerable:
		hull = maxf(hull, hull_max * INVULN_HULL_FLOOR)
	elif hull < 0.0:
		hull = 0.0
	if hull <= 0.0:
		killed = true

func _inflict(sys: Dictionary, amount: float) -> void:
	# iiShipSystem::InflictDamage 0x1003bed0: a subsim with hit_points 0 cannot
	# be hurt, and an already-destroyed one is skipped by the caller.
	if float(sys["hp_max"]) == 0.0 or float(sys["hp"]) <= 0.0:
		return
	sys["hp"] = float(sys["hp"]) - amount

func _nearest_system(hit_local: Vector3) -> int:
	var best := -1
	var best_d := INF
	for i in systems.size():
		var d: float = (systems[i]["pos"] as Vector3).distance_squared_to(hit_local)
		if d < best_d:
			best_d = d
			best = i
	return best

func _lda_deflect(lda: Dictionary, dir_local: Vector3) -> bool:
	if bool(lda["destroyed"]) or float(lda["efficiency"]) <= 0.0:
		return false
	var chance := 0.0
	if lda["lda"] == "icPlayerLDA":
		# icPlayerLDA 0x100acda0
		if float(lda["capacity"]) * LDA_MIN_ENERGY > float(lda["energy"]):
			return false
		if float(lda["cost"]) > float(lda["energy"]):
			return false
		# TRIWeight() is 1.0 for every non-player ship (iiShipSystem::TRIWeight
		# 0x1003c170); the player's TRI weights are UNKNOWN, so we use 1.0.
		chance = minf(float(lda["reliability"]) * float(lda["efficiency"]), LDA_MAX_CHANCE)
	else:
		# icAILDA 0x1002b940
		if float(lda["defends"]) < 1.0:
			return false
		chance = float(lda["reliability"]) * float(lda["efficiency"])
	if rng.randf() > chance:
		return false
	# hood coverage: the bolt must be arriving inside the half-angle the LDA
	# covers. FUN_100361b0 pre-computes cos(coverage * pi/360), i.e. the cosine
	# of half the authored arc.
	var half := deg_to_rad(float(lda["coverage"])) * 0.5
	if half > 0.0 and half < PI:
		var incoming := -dir_local
		if incoming.length_squared() > 1e-9 and incoming.normalized().z < cos(half):
			return false
	if lda["lda"] == "icPlayerLDA":
		lda["energy"] = float(lda["energy"]) - float(lda["cost"])
	else:
		lda["defends"] = float(lda["defends"]) - 1.0
	return true

# --- per-frame -------------------------------------------------------------

func simulate(dt: float) -> void:
	# icShip 0x10075f80 (the subsim tick) + iiShipSystem::Simulate 0x1003bbd0.
	if killed or dt <= 0.0:
		return
	# iiThrusterSim::Simulate 0x1007e200: the infection ticks FIRST, before the
	# rest of the sim -- ApplyDamage(dt * infection_damage, source 5, self).
	# Raw hull path: no armour, no subsim criticals, exactly like collisions.
	if infection_damage > 0.0:
		apply_damage(infection_damage * dt, SRC_INFECTION)
		if killed:
			return
	disrupt_time = maxf(0.0, disrupt_time - dt)
	if disrupt_time <= 0.0:
		disrupt_full = false
	_power_pool = 0.0
	_repair_pool = 0.0
	var heat_rate := 0.0
	if not _has_reactor:
		_power_pool = NO_POWERPLANT_POOL
	for sys in systems:
		if sys["class"] == "icReactor" and not bool(sys["destroyed"]):
			_power_pool += float(sys["output"]) * float(sys["efficiency"])
		if sys["class"] == "icAutorepair" and not bool(sys["destroyed"]):
			_repair_pool += float(sys["autorepair_rate"]) * float(sys["efficiency"])
	var overheated := (heat + heat_external) >= HEAT_DAMAGE_THRESHOLD
	for sys in systems:
		heat_rate += _simulate_system(sys, dt, overheated)
	if disrupt_time <= 0.0:
		# a disrupted LDA neither recharges nor deflects while the timer runs
		for lda in ldas:
			_simulate_lda(lda, dt)
	# icShip::SimulateSystems 0x10075f60 (integration at 0x10076060): a positive
	# net rate heats the internal store; a negative one cools the EXTERNAL store
	# first (at heat_loss_factor) and only what the external store cannot absorb
	# spills over into the internal store. Both stores are floored at zero and
	# clamped to the damage threshold.
	if heat_rate <= 0.0:
		var cool := HEAT_LOSS_FACTOR * dt * heat_rate  # <= 0
		if heat_external >= -cool:
			heat_external += cool
		else:
			heat += cool + heat_external
			heat_external = 0.0
	else:
		heat += HEAT_GAIN_FACTOR * dt * heat_rate
	heat = clampf(heat, 0.0, HEAT_DAMAGE_THRESHOLD)
	heat_external = clampf(heat_external, 0.0, HEAT_DAMAGE_THRESHOLD)
	var total := heat + heat_external
	if total > HEAT_DAMAGE_THRESHOLD and heat_external >= total * HEAT_DAMAGE_EXTERNAL_MIN:
		# The original hands (total - threshold) * heat_damage_rate straight to
		# ApplyDamage with NO dt term -- once per frame, frame-rate dependent.
		# We keep the per-call form it actually has.
		apply_damage((total - HEAT_DAMAGE_THRESHOLD) * HEAT_DAMAGE_RATE, SRC_HEAT)

func _simulate_system(sys: Dictionary, dt: float, overheated: bool) -> float:
	# a full-disruption warhead (icShip::Disrupt) raises the disrupted flag
	# 0x10 on every subsim: efficiency reads zero until the timer expires.
	# Heatsinks keep radiating -- their AddHeatRate has no gate (see below).
	if disrupt_full and disrupt_time > 0.0 and sys["class"] != "icHeatSink":
		sys["efficiency"] = 0.0
		sys["usage"] = 0.0
		return 0.0
	if bool(sys["destroyed"]):
		sys["efficiency"] = 0.0
		sys["usage"] = 0.0
		# icHeatSink::Simulate 0x1002ee90 has no destroyed/off gate: the base
		# Simulate bails out, the AddHeatRate(-loss * ramp) that follows it does
		# not. A shot-out heatsink keeps radiating.
		if sys["class"] == "icHeatSink":
			return -_heatsink_rate(float(sys["heat_loss_rate"]))
		return 0.0
	var hp_max := float(sys["hp_max"])
	var health := 1.0
	if hp_max > 0.0:
		var hp := float(sys["hp"])
		if hp < hp_max:
			# hit points below zero mean the subsim is dead but repairable; the
			# engine clamps at -hp_max and repairs out of the ship's pool.
			hp = maxf(hp, -hp_max)
			var want := float(sys["repair_rate"])
			var got := minf(want, _repair_pool)
			_repair_pool -= got
			hp = minf(hp + got * dt, hp_max)
			sys["hp"] = hp
		health = clampf(hp / hp_max, 0.0, 1.0)
	# power: the draw scales with how hard the subsim is being used
	var ratio := 1.0
	var power := float(sys["power"])
	sys["underpowered"] = false
	if power > 0.0:
		var drain: float = (float(sys["usage"]) * DRAIN_USAGE + DRAIN_BASE) * power
		var got := minf(drain, _power_pool)
		_power_pool -= got
		ratio = 0.0 if drain <= 0.0 else got / drain
		if ratio <= UNDERPOWER_RATIO:
			sys["underpowered"] = true
		ratio = clampf(ratio, 0.0, 1.0)
	var eff := ratio * health
	if overheated and sys["class"] != "icHeatSink":
		eff = minf(eff, OVERHEAT_EFFICIENCY)
	if bool(sys["underpowered"]) or health <= 0.0:
		eff = 0.0
	if eff < float(sys["min_eff"]):
		eff = 0.0
	sys["efficiency"] = eff
	# heat: only subsims with a positive heat_rate contribute, scaled by how much
	# power they actually got (iiShipSystem::Simulate 0x1003bda6)
	var rate := 0.0
	if float(sys["heat_rate"]) > 0.0:
		rate = float(sys["heat_rate"]) * ratio
	if sys["class"] == "icHeatSink":
		rate -= _heatsink_rate(float(sys["heat_loss_rate"]))
	return rate

func _heatsink_rate(loss: float) -> float:
	# icHeatSink::Simulate 0x1002ee90: cooling ramps in with the ship's heat,
	# from 20% of the rate when cold to the full rate at 0.9 * the threshold.
	var knee := HEAT_DAMAGE_THRESHOLD * 0.9
	var total := heat + heat_external
	if total >= knee or knee <= 0.0:
		return loss
	var d := total - knee
	return loss * maxf(1.0 - (d * d) / (knee * knee), HEATSINK_MIN_RAMP)

func add_body_heat(dist_to_surface: float, body_radius: float, is_sun: bool,
		dt: float) -> void:
	# icPlanet::Think 0x10068380 / icSun::Think 0x1006ab90: each frame every
	# planet/sun in the active system heats the PLAYER ship's external store
	# (only the player -- both Thinks go through icPlayerPilot::m_p_instance):
	#
	#   d = max(distance_to_centre - radius, 0)
	#   if d < radius * heat_radius_multiplier:                    ; 0.5
	#       t = 1 - d / (radius * heat_radius_multiplier)
	#       external += t^2 * heat_multiplier * dt                 ; planet, 10000
	#       external += t^2 * heat_multiplier * 10 * dt            ; sun
	#
	# The store is clamped to heat_damage_threshold by the next simulate(), and
	# heat damage only ever fires while external >= half the total -- so this is
	# what makes sun-diving lethal.
	var reach := body_radius * HEAT_RADIUS_MULTIPLIER
	var d := maxf(dist_to_surface, 0.0)
	if reach <= 0.0 or d >= reach:
		return
	var t := 1.0 - d / reach
	var mult := PLANET_HEAT_MULTIPLIER * (SUN_HEAT_FACTOR if is_sun else 1.0)
	heat_external += t * t * mult * dt

func _simulate_lda(lda: Dictionary, dt: float) -> void:
	if bool(lda["destroyed"]):
		return
	if lda["lda"] == "icPlayerLDA":
		# icPlayerLDA::Simulate 0x100acb4b: energy += TRIWeight * efficiency * power
		var cap := float(lda["capacity"])
		if float(lda["energy"]) < cap:
			var gain: float = float(lda["efficiency"]) * float(lda["power"]) * dt
			lda["energy"] = minf(float(lda["energy"]) + gain, cap)
			lda["usage"] = 0.75
		else:
			lda["usage"] = 0.0
	else:
		# icAILDA::Simulate 0x1002b7eb: defends += dt * defend_count / recharge_time
		var maxd := float(lda["defend_count"])
		var rt := float(lda["recharge_time"])
		if float(lda["defends"]) < maxd and rt > 0.0:
			lda["defends"] = minf(float(lda["defends"]) + dt * maxd / rt, maxd)
		lda["usage"] = 1.0

# --- read-only views for the HUD -------------------------------------------

func disrupt(seconds: float, full: bool) -> void:
	# icShip::Disrupt via icMissile::CheckForDisruption 0x1006d0b0: raise the
	# disrupted flag for `seconds`. Shields-only (full_disruption=0) takes the
	# LDAs; full disruption takes every subsim but the heatsinks.
	disrupt_time = maxf(disrupt_time, seconds)
	disrupt_full = disrupt_full or full

func heat_fraction() -> float:
	# The HUD's player feed (0x10108890) computes the thermometer as
	#   TotalHeat / heat_damage_threshold * 0.8   (0.8 lives at 0x10163efc)
	# clamped to 1. So an internal-only overheat pegs the needle at 0.8; only
	# external (sun/planet) heat pushes it into the top fifth, and the needle
	# hits 1.0 at total = 625. (The base-screen status panels use 0.75 instead,
	# 0x100e07f0, warning at frac >= 0.75, i.e. exactly at the threshold.)
	var total := heat + heat_external
	return clampf(total / HEAT_DAMAGE_THRESHOLD * HUD_HEAT_GAUGE_SCALE, 0.0, 1.0)

func group_health(group: String) -> float:
	# -1: nothing of that kind is fitted. Otherwise the worst efficiency of the
	# subsims in the group -- which is what degrades as they take hits.
	var worst := -1.0
	for sys in systems:
		if sys["group"] != group:
			continue
		var h := 1.0
		if float(sys["hp_max"]) > 0.0:
			h = clampf(float(sys["hp"]) / float(sys["hp_max"]), 0.0, 1.0)
		if worst < 0.0 or h < worst:
			worst = h
	return worst

func group_states() -> Dictionary:
	var out: Dictionary = {}
	for g in GROUPS:
		out[g] = group_health(g)
	return out

func shield_bars() -> Array:
	# The tug mounts two LDAs, at the shield_upper and shield_lower nulls: those
	# are the HUD's two SHIELD STATUS bars.
	var out: Array = []
	for lda in ldas:
		var frac := 0.0
		if lda["lda"] == "icPlayerLDA":
			var cap := float(lda["capacity"])
			frac = 0.0 if cap <= 0.0 else clampf(float(lda["energy"]) / cap, 0.0, 1.0)
		else:
			var maxd := float(lda["defend_count"])
			frac = 0.0 if maxd <= 0.0 else clampf(float(lda["defends"]) / maxd, 0.0, 1.0)
		if float(lda["hp_max"]) > 0.0 and float(lda["hp"]) <= 0.0:
			frac = 0.0  # a shot-out LDA holds no field
		out.append(frac)
	return out

func damaged_systems() -> Array:
	var out: Array = []
	for sys in systems:
		if float(sys["hp_max"]) > 0.0 and float(sys["hp"]) < float(sys["hp_max"]):
			out.append(sys)
	return out
