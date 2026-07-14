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
# icShip::SimulateSystems (heat passes 3). Source 4 is the collision path
# (iiSim::OnCollision 0x10078ab0 hands 4 to both ships). Source 5 is the alien
# infection -- iiThrusterSim::Simulate 0x1007e200 calls ApplyDamage(dt*damage, 5)
# -- and ALSO what an aggressor-shield ram hands its victim (0x1002f8b0). The
# source only labels the damage; every one of them is the raw hull path.
const SRC_WEAPON := 0
const SRC_BYPASS := 1
const SRC_HEAT := 3
const SRC_COLLISION := 4
const SRC_INFECTION := 5

# --- icAggressorShield -------------------------------------------------------
# @element icAggressorShield
# Registered at 0x1002efa0 with base **iiWeapon** -- it is not a shield at all in
# the LDA sense. It is a rammer: you charge it, hold it, and whatever you hit
# head-on takes a multiple of YOUR hull in damage while you take a fraction of it
# back. Fitted at the type-2048 mountpoint (subsims/mountpoints/aggressor_shield),
# prefitted on the heavy corvette and fast attack, an empty socket on the tug.
#
#   Fire            0x1002f6a0   one instruction: active = 1
#   IsReadyToFire   0x1002f5c0   refuses unless the bank is FULL (|energy-cap| < 1e-6)
#   Simulate        0x1002f410   drains over `duration`, recharges when idle
#   OnCollision     0x1002f6b0   the cone test, the damage, the self-damage
#   DamageAtSpeed   0x1002f900   the curve
#
# Property map 0x1002f040: duration +0xac, capacity +0xb0, coverage +0xb4,
# sweet_speed +0xb8, damage_factor +0xbc, self_damage_factor +0xc0.
# Runtime: energy +0xc4, active +0xc8.
const AGG_SWEET_SPEED := 2000.0   # ctor default 0x44fa0000 @ 0x1002f290 (both
                                  # shipped INIs override it: 800 / 1200)
const AGG_MIN_DAMAGE := 0.25      # m_min_damage_factor 0x1015b214
const AGG_MAX_DAMAGE := 5.0       # m_max_damage_factor 0x1015b210
const AGG_CHANNEL := "fire"       # the avatar channel Simulate drives, 0x1015b22c
                                  # (0/1) -- the same channel the aggressor_shield
                                  # sound INI triggers on
# m_penetration_armour_factor = 0.7 @ 0x1015b20c is REGISTERED in the property map
# but never read anywhere in iwar2.dll: UNKNOWN what it was meant to scale.
const AGG_PENETRATION_ARMOUR_FACTOR := 0.7

# @element icProgram
# icCPU +0x80, the fitted-program bitmask (icCPU property map @ 0x100308a0:
# "programs" -> +0x80; icProgram program_id -> +0x40, map @ 0x10031e80). The ten
# shipped programs (subsims/systems/player/programs/*.ini) and what each bit
# gates in the engine -- see docs/combat.md. The campaign only ever GIVES the
# player two of them: PROG_STEALTH (act 1 m8, on one dialogue branch) and
# PROG_HYPERSPACE_TRACKER (act 2 m5); the rest are bought as cargo.
const PROG_MATCHVEL_AUTOPILOT := 4        # autopilot_matchvel
const PROG_ENGINE_MANAGEMENT := 32        # engine_manage_program
const PROG_MIL_TRACKING := 64             # mil_tracking_program
const PROG_OCCLUSION := 128               # occlusion_program
const PROG_REPAIR_CONTROL := 256          # repair_control_program
const PROG_SELF_DEFENCE := 512            # self_defense_program
const PROG_STEALTH := 1024                # stealth_program
const PROG_HYPERSPACE_TRACKER := 2048     # hyperspace_tracker
const PROG_AGGRESSOR_CONTROL := 4096      # aggressor_shield_control
const PROG_IMAGING := 8192                # imaging_module

# --- the TRI: iiShipSystem's power triangle (task #60) -------------------------
# @element TRI
# Every subsim carries an `iiShipSystem::eType` at +0x64 -- the TRI GROUP it
# draws from. The base ctor (0x1003b9f0) writes 3 = "no TRI", and EXACTLY four
# ctors override it (proven by disassembling every `mov [reg+0x64], imm` in
# iwar2.dll; `iiShipSystem::SetType` @ 0x10001b60 has ZERO call sites, so the
# type is fixed at construction and nothing can move a subsim between groups):
#
#   0 DRIVE      icDrive 0x10030da0 / icThrusters 0x1003c590 /
#                icCapsuleDrive 0x10030750 / icLDSDrive 0x10036c50 (all `mov 0`)
#   1 OFFENSIVE  iiWeapon 0x1003c860 (`mov ecx,1` @ 0x1003c868) -- so EVERY
#                weapon subclass -- and icMissileLauncher 0x10031450 (`mov 1`)
#   2 DEFENSIVE  icAggressorShield 0x1002f290 (`mov 2`)
#   3 NONE       everything else, including icPlayerLDA -- see below
#
# `iiShipSystem::TRIWeight()` (0x1003c170) is
#     if (!IsPlayer()) return 1.0            # 0x1003bb80, arg 1
#     return m_tri_weights[ this->eType ]
# so the TRI is a PLAYER-ONLY system: every AI ship runs at a flat 1.0.
const TRI_DRIVE := 0
const TRI_OFFENSIVE := 1
const TRI_DEFENSIVE := 2
const TRI_NONE := 3

# The position, the weights and the two bounds are CLASS STATICS -- one TRI for
# the whole game (SetTRIPosition, 0x1003c070, takes no `this`). Their values are
# in .data, and no shipped INI overrides them (`min_tri_weight`/`max_tri_weight`
# are real property keys -- the strings are at 0x1015bbd8/0x1015bbc8 -- but they
# appear in none of data/ini/**):
const TRI_MIN_WEIGHT := 0.5   # iiShipSystem::m_min_tri_weight, .data @ 0x1015bb8c
const TRI_MAX_WEIGHT := 1.5   # iiShipSystem::m_max_tri_weight, .data @ 0x1015bb90
# m_tri_position is FOUR floats (0x1015bb94..0x1015bba0), all 1/3. SetTRIPosition
# writes only the first three but the weight loop runs over all four, so
# m_tri_weights[3] -- the "no TRI" group -- is permanently w(1/3) = 1.0.
const TRI_START := [1.0 / 3.0, 1.0 / 3.0, 1.0 / 3.0]

# class -> eType. Anything absent is 3.
const TRI_ETYPE := {
	"icDrive": TRI_DRIVE, "icThrusters": TRI_DRIVE,
	"icCapsuleDrive": TRI_DRIVE, "icLDSDrive": TRI_DRIVE,
	# iiWeapon subclasses: the base ctor sets 1 for all of them
	"icCannon": TRI_OFFENSIVE, "icTurret": TRI_OFFENSIVE,
	"icSlugThrower": TRI_OFFENSIVE, "icBeamProjector": TRI_OFFENSIVE,
	"icMissileLauncher": TRI_OFFENSIVE, "icMagazine": TRI_OFFENSIVE,
	"icMissileMagazine": TRI_OFFENSIVE,
	"icCounterMeasureMagazine": TRI_OFFENSIVE,
	# registered with base iiWeapon, but its own ctor overrides eType to 2
	"icAggressorShield": TRI_DEFENSIVE,
}

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
	# an iiWeapon subclass like the rest of the WEP group (registered @ 0x1002efa0
	# with base iiWeapon::m_static_class_name)
	"icAggressorShield": "WEP",
}

# mountpoint type= -> group, for hulls whose mounts are still empty sockets
const MOUNT_GROUP := {
	4: "EPS", 2: "EPS", 8: "THR", 16: "SEN", 32: "SEN", 64: "LDS",
	256: "DRV", 512: "CAP", 2048: "WEP", 4096: "WEP", 32768: "CPU",
	65536: "WEP",
}

static var _ini_cache: Dictionary = {}
static var _ships_cache: Array = []
static var _strings: Dictionary = {}

var hull := 1000.0
var hull_max := 1000.0
var armour := 50.0
var systems: Array = []       # every mounted subsim, in INI order
var null_pos: Dictionary = {} # this hull's [SetupScene] attach nulls: name -> ship-local pos
var ldas: Array = []          # the subset that can deflect (icPlayerLDA/icAILDA)
var aggressors: Array = []    # the subset that are icAggressorShield
var programs := 0             # icCPU +0x80, the fitted-program bitmask
# The TRI (see the constants above). `is_player` is iiShipSystem::IsPlayer
# (0x1003bb80) -- the gate on TRIWeight, and the reason an AI ship never feels
# the triangle. The position is the live m_tri_position; the weights are what
# SetTRIPosition bakes out of it.
var is_player := false
var tri: Array = TRI_START.duplicate()
var tri_weights: Array = [1.0, 1.0, 1.0, 1.0]
var in_lds := false           # icShip+0x25c state 2: an engaged LDS drive drops
                              # the aggressor shield (0x1002f537)
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

## A sim INI's `[Properties] name=` is a LOCALISATION KEY, not a display name --
## the engine resolves it through text/*.csv (our data/json/strings.json). The
## weapon keys come out as the names the game actually shows: Cargo_AssaultCannon
## -> "Gatling Cannon", Cargo_LongRangeCannon -> "Sniper Cannon".
static func display_name(key: String) -> String:
	if _strings.is_empty():
		var f := FileAccess.open(_base().path_join("data/json/strings.json"),
				FileAccess.READ)
		if f != null:
			var j: Variant = JSON.parse_string(f.get_as_text())
			if j is Dictionary:
				for k: String in (j as Dictionary):
					_strings[k.to_lower()] = str((j as Dictionary)[k])
		_strings["__loaded"] = ""
	var hit: String = str(_strings.get(key.to_lower(), ""))
	return hit if not hit.is_empty() else key

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
	# icShip +0x2fc, MinimumBrightness (0x10002b60) -- the ship INI's
	# `min_brightness`. `brightness` (+0x1b8) is the network-replicated value and
	# is unreachable on the local path; see brightness() below.
	s.min_brightness = float(props.get("min_brightness", 0))
	var mounts: Array = rec.get("subsims", [])
	# Where each of this hull's attach nulls is, before anything is mounted: the
	# fitting screen (economy.gd `_cust_fit`) re-mounts a device onto the null
	# name it inherits from the device it replaces, so the map has to outlive the
	# mount that introduced it.
	for mount: Dictionary in mounts:
		var key := _null_name(mount)
		if not key.is_empty() and mount.get("attach_pos") != null:
			s.null_pos[key] = _attach_pos(mount)
	for mount: Dictionary in mounts:
		s._mount(str(mount.get("template", "")), _null_name(mount))
	return s

## The ini's `null[i]` for a mount. A mount without one carries a JSON null
## here, not a missing key, so `.get(k, "")` would hand back `<null>`.
static func _null_name(mount: Dictionary) -> String:
	var an: Variant = mount.get("attach_null")
	return str(an).to_lower() if an != null else ""

## Where a subsim mounted at this null sits on the hull, in ship-local Godot
## axes. LWS -> Godot negates Z, as the model exporter does (gltf_builder.py).
static func _attach_pos(mount: Dictionary) -> Vector3:
	var a: Array = mount["attach_pos"]
	return Vector3(float(a[0]), float(a[1]), -float(a[2]))

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
		# iiShipSystem::eType (+0x64) -- which TRI axis this subsim draws from
		"etype": int(TRI_ETYPE.get(cls, TRI_NONE)),
		# iiShipSystem::Load 0x1003bb30: max hit points is a copy of the INI's
		# hit_points, so a 0 there means the subsim cannot be damaged at all.
		"hp": float(props.get("hit_points", 0)),
		"hp_max": float(props.get("hit_points", 0)),
		"power": float(props.get("power", 0)),
		"heat_rate": float(props.get("heat_rate", 0)),
		"repair_rate": float(props.get("repair_rate", 0)),
		"min_eff": float(props.get("minimum_efficiency", 0)),
		# Where this subsim sits on the hull -- what picks the subsim nearest an
		# impact, and what iiWeapon::FindWorldMuzzle fires from.
		#
		# FiSim::PlaceSubsimAtNull (flux.dll 0x100bcb10) places each subsim at the
		# null named by the ini's `null[i]`, looked up in the scene named by
		# [SetupScene] -- NOT in the avatar. It takes that null's frame-0 local
		# transform and hands it to FcSubsim::SetPosition/SetOrientation.
		# tools/iw2/extract_sims.py does the same lookup at extract time and writes
		# the result to ships.json as `attach_pos`; null_pos is that, per hull.
		#
		# A mount with no `null[i]` (7 of the tug's 23) never reaches SetPosition
		# and so keeps FcSubsim's ctor defaults (flux.dll 0x100c2190 zeroes
		# +0x20..0x28): the hull origin. ZERO here is the original's behaviour, not
		# a failed lookup.
		"pos": null_pos.get(attach_null, Vector3.ZERO),
		"efficiency": 1.0,
		"usage": 0.0,
		"destroyed": false,
		"underpowered": false,
	}
	# iiGun::SniperZoom (0x1000f0b0) is `mov al, [ecx+0xc5]; ret` -- a plain bool
	# on the gun, fed by the INI key `sniper_zoom` (string @ 0x1015b884). Exactly
	# ONE subsim in the shipped data sets it: subsims/systems/player/long_range_pbc
	# (icSlugThrower, "Cargo_LongRangeCannon" -- the long-range 'Sniper' PBC, and
	# the powerup sims/power_ups/weapon_pbc_sniper drops that same resource).
	# icPlayerPilot::GotSniperWeapon (0x100b14d0) is what reads it: see main.gd.
	sys["sniper_zoom"] = float(props.get("sniper_zoom", 0)) != 0.0
	if cls == "icReactor":
		# icReactor::Load 0x1003a260 copies output_power (+0x7c) into the base
		# output (+0x94) and HeatRate() into the base heat (+0x90). Property map
		# @ 0x10039f40: output_power +0x7c, has_power_pod +0x80, pod_power_factor
		# +0x84, pod_heat_factor +0x88, ramp_up_time +0x8c.
		sys["output"] = float(props.get("output_power", 0))
		sys["has_pod"] = float(props.get("has_power_pod", 0)) != 0.0
		sys["pod_power"] = float(props.get("pod_power_factor", 1))
		sys["pod_heat"] = float(props.get("pod_heat_factor", 1))
		sys["ramp_up_time"] = float(props.get("ramp_up_time", REACTOR_RAMP_TIME))
		# +0x9c the ramp, +0xa0 its target. The ctor (0x1003a0f0) starts the ramp
		# at 0 and the target at 1, so a freshly-constructed reactor spools up
		# over ramp_up_time. Our ships are constructed at the moment they ENTER
		# PLAY, not at level load, so we start the ramp settled -- the cold-start
		# transient is the one part of this we deliberately do not reproduce.
		sys["ramp"] = 1.0
		sys["ramp_target"] = 1.0
		sys["charge"] = 0.0      # +0x7c at runtime: this frame's actual output
		sys["max_charge"] = 0.0  # +0x98: the rated output
		_has_reactor = true
	if cls == "icSensorDisruptor" or cls == "icActiveSensor" or cls == "icCPU":
		# the three brightness terms (see brightness() below)
		sys["brightness_mod"] = float(props.get("brightness_mod", 0))
		sys["stealth_mod"] = float(props.get("stealth_brightness_modifier", 0))
		sys["on"] = true
	if cls == "icCPU":
		sys["engine_mult"] = float(props.get(
			"engine_management_power_multiplier", 1.0))
	if cls == "icHeatSink":
		# icHeatSink::Simulate 0x1002ee90: AddHeatRate(-heat_loss_rate * ramp)
		sys["heat_loss_rate"] = float(props.get("heat_loss_rate", 0))
	if cls == "icAutorepair":
		sys["autorepair_rate"] = float(props.get("autorepair_rate", 0))
	if cls == "icProgram":
		# icLoadout::LoadComputerPrograms 0x10095ea0 ORs each fitted program's
		# program_id (icProgram +0x40) into the CPU's mask -- `or ebp, esi` @
		# 0x1009609c -- and writes the result through the icCPU property map's
		# "programs" key (+0x80). A prefitted hull that names a program INI
		# directly gets the same bit.
		programs |= int(props.get("program_id", 0))
	if cls == "icAggressorShield":
		sys["duration"] = float(props.get("duration", 0))
		sys["capacity"] = float(props.get("capacity", 0))
		sys["coverage"] = float(props.get("coverage", 0))
		sys["sweet_speed"] = float(props.get("sweet_speed", AGG_SWEET_SPEED))
		sys["damage_factor"] = float(props.get("damage_factor", 0))
		sys["self_damage_factor"] = float(props.get("self_damage_factor", 0))
		# the bank starts EMPTY: the ctor zeroes +0xc4 (0x1002f290) and Simulate
		# fills it, so the shield is not available on the first frame
		sys["energy"] = 0.0
		sys["active"] = false
		aggressors.append(sys)
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

## Hand the built hull model over. Deliberately does nothing to subsim
## positions: those are already set, from the ini's [SetupScene] nulls, by
## _mount() -- see _attach_pos.
##
## This used to scan the *avatar* for nodes named after the ini's `null[i]`
## keys. It found nothing -- on any hull -- and so left every subsim at the hull
## origin, which made apply_weapon_damage() distribute criticals as if the whole
## ship were stacked at its centre (bug #68). Those names were never in the
## avatar to begin with: FiSim::Load (flux.dll 0x100bbc00) loads [SetupScene]
## and [Avatar] as two separate scenes, and only ever searches the *setup scene*
## for mount names (PlaceSubsimAtNull 0x100bcb10). The avatar only draws the
## ship. Kept because main.gd / ai_ship.gd hand us the model here.
func bind_model(_model: Node3D) -> void:
	pass

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

# --- the TRI ------------------------------------------------------------------

## iiShipSystem::SetTRIPosition (0x1003c070). Static in the original; here it is
## the player's ShipSystems, which is the same thing (TRIWeight is IsPlayer-gated).
##
## The two bounds are clamped on every call -- min to [0,1] (0x1003c076..0x1003c0c9)
## and max to [1,3] (0x1003c0cf..0x1003c105) -- then each axis is mapped:
##
##     x = pos * 3 - 1                       ; 0x10118490 = 3, 0x101171f0 = 1
##     w = 1 + x * (1 - min_tri_weight)      ; x < 0
##     w = 1 + x * 0.5 * (max_tri_weight - 1); x > 0   (0x10117738 = 0.5)
##
## i.e. weight = min at position 0, exactly 1.0 at 1/3, max at 1 -- piecewise
## linear with the kink at the balanced point. With the shipped statics that is
## 0.5 / 1.0 / 1.5.
##
## (Quirk, faithfully NOT reproduced: the x == 0 case falls out of the compare
## chain at 0x1003c141 with st(0) still holding x, so the original would store a
## weight of ZERO for a perfectly balanced axis. It never bites, because the x87
## unit evaluates `1/3f * 3 - 1` in 80-bit and lands on +2.98e-8, not 0. We take
## the continuous limit, 1.0.)
func set_tri_position(a: float, b: float, c: float) -> void:
	tri = [a, b, c]
	var lo := clampf(TRI_MIN_WEIGHT, 0.0, 1.0)
	var hi := clampf(TRI_MAX_WEIGHT, 1.0, 3.0)
	for i in 3:
		var x: float = float(tri[i]) * 3.0 - 1.0
		if x < 0.0:
			tri_weights[i] = 1.0 + x * (1.0 - lo)
		elif x > 0.0:
			tri_weights[i] = 1.0 + x * 0.5 * (hi - 1.0)
		else:
			tri_weights[i] = 1.0
	# m_tri_weights[3] is baked from the fourth, never-written m_tri_position
	# slot (a static 1/3) -- so the "no TRI" group is pinned at 1.0.
	tri_weights[3] = 1.0

## iiShipSystem::TRIWeight (0x1003c170): `if (!IsPlayer()) return 1.0;` then
## `m_tri_weights[eType]`. Every AI ship runs at a flat 1.0.
func tri_weight(etype: int) -> float:
	if not is_player:
		return 1.0
	return float(tri_weights[clampi(etype, 0, 3)])

## The weight a given mounted subsim pulls -- TRIWeight() as its owner sees it.
func system_tri_weight(sys: Dictionary) -> float:
	return tri_weight(int(sys.get("etype", TRI_NONE)))

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
		# icPlayerLDA DOES call TRIWeight -- twice: on the deflect chance
		# (0x100acdf0: `w * reliability * efficiency`, then the 0.98 ceiling at
		# 0x1011c664) and on the recharge (0x100acb71). But its weight is
		# provably a CONSTANT 1.0: no icPlayerLDA ctor writes eType (+0x64), so
		# it keeps the base default of 3, and m_tri_weights[3] is baked from the
		# fourth m_tri_position slot, which SetTRIPosition never writes and .data
		# pins at 1/3 -> w(1/3) = 1.0. (SetType, 0x10001b60, has zero call sites,
		# so nothing can move it into a group either.) The shields are NOT on the
		# defensive axis -- the aggressor shield is the only eType-2 subsim.
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
			_power_pool += _simulate_reactor(sys, dt)
		if sys["class"] == "icAutorepair" and not bool(sys["destroyed"]):
			_repair_pool += float(sys["autorepair_rate"]) * float(sys["efficiency"])
	var overheated := (heat + heat_external) >= HEAT_DAMAGE_THRESHOLD
	for sys in systems:
		heat_rate += _simulate_system(sys, dt, overheated)
	if disrupt_time <= 0.0:
		# a disrupted LDA neither recharges nor deflects while the timer runs
		for lda in ldas:
			_simulate_lda(lda, dt)
	for agg in aggressors:
		_simulate_aggressor(agg, dt)
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
	# The Engineering screen's row 0 switches a subsim off (FUN_10106390 flips
	# bit 1 of iiShipSystem+0x68). A subsim that is off draws no power, makes no
	# heat and does nothing -- but a heatsink still radiates, like a destroyed
	# one, because AddHeatRate sits outside the base Simulate's early-out.
	if bool(sys.get("off", false)):
		sys["efficiency"] = 0.0
		sys["usage"] = 0.0
		if sys["class"] == "icHeatSink":
			return -_heatsink_rate(float(sys["heat_loss_rate"]))
		return 0.0
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

func _simulate_aggressor(agg: Dictionary, dt: float) -> void:
	# icAggressorShield::Simulate 0x1002f410, after iiWeapon::Simulate.
	if bool(agg["destroyed"]):
		agg["active"] = false
		return
	if bool(agg["active"]):
		# Drain: the bank empties over exactly `duration` seconds, because the
		# rate is capacity/duration (0x1002f503: dt * capacity / duration).
		var dur := maxf(float(agg["duration"]), 1e-6)
		agg["energy"] = float(agg["energy"]) - dt * float(agg["capacity"]) / dur
		# It drops on empty, and it drops the moment the LDS drive engages
		# (0x1002f52a: ship+0x25c, the icLDSDrive, state +0x84 == 2).
		if float(agg["energy"]) < 0.0 or in_lds:
			agg["active"] = false
			agg["energy"] = 0.0
		agg["usage"] = 1.0
	elif float(agg["energy"]) < float(agg["capacity"]):
		# Recharge. The original adds TRIWeight * efficiency * power ONCE PER
		# FRAME with NO dt: at 0x1002f579 the compiler reuses the (now dead) dt
		# argument slot as scratch for the efficiency, so the multiply chain at
		# 0x1002f582 picks up efficiency and power and nothing else. icPlayerLDA
		# 0x100acb7e does the same three multiplies and then an `fmul [esp+0x14]`
		# for dt -- the aggressor simply has no such instruction. We keep the
		# per-call form the binary has, exactly as we do for the heat-damage
		# tick; it is why the device is called an INSTANT shield (the control
		# program's cargo name is Cargo_InstantShieldControl).
		#
		# The TRIWeight is the DEFENSIVE axis (the aggressor is the only eType-2
		# subsim in the game): at full defensive the bank refills 1.5x as fast,
		# at zero defensive 0.5x.
		agg["energy"] = minf(
			float(agg["energy"]) + system_tri_weight(agg)
				* float(agg["efficiency"]) * float(agg["power"]),
			float(agg["capacity"]))
		agg["usage"] = 0.75
	else:
		agg["usage"] = 0.0

func aggressor_ready(agg: Dictionary) -> bool:
	# icAggressorShield::IsReadyToFire (vtable slot 22, 0x1002f5c0): the base
	# iiWeapon check, then -- already up? (result 0xd). Then the bank must be
	# FULL, not merely non-empty: |energy - capacity| < 1e-6 (0x101178fc), else
	# result 4. There is no partial discharge.
	# (The Mode()==2 branch at 0x1002f5e5 is the AI's: an AI aggressor only fires
	# while its icAITarget IsAvoiding. The player's weapons are Mode 1.)
	if bool(agg["destroyed"]) or float(agg["efficiency"]) <= 0.0:
		return false
	if bool(agg["active"]):
		return false
	if disrupt_full and disrupt_time > 0.0:
		return false
	return absf(float(agg["energy"]) - float(agg["capacity"])) < 1e-6

func aggressor_fire() -> bool:
	# icAggressorShield::Fire (vtable slot 28, 0x1002f6a0) is literally
	# `mov byte ptr [ecx+0xc8], 1; ret 8`. Everything else is Simulate's and
	# OnCollision's job.
	for agg in aggressors:
		if aggressor_ready(agg):
			agg["active"] = true
			return true
	return false

func aggressor_active() -> bool:
	for agg in aggressors:
		if bool(agg["active"]):
			return true
	return false

func aggressor_charge() -> float:
	# 0..1 for the HUD; -1 when none is fitted
	for agg in aggressors:
		var cap := float(agg["capacity"])
		if cap > 0.0:
			return clampf(float(agg["energy"]) / cap, 0.0, 1.0)
	return -1.0

func aggressor_damage_at(agg: Dictionary, speed: float) -> float:
	# icAggressorShield::DamageAtSpeed 0x1002f900:
	#   d = (speed / sweet_speed)^2 * damage_factor * TRIWeight()
	#   d = clamp(d, min_damage_factor 0.25, max_damage_factor 5.0)
	#   return ship.hit_points (icShip+0x1b0) * d
	# So the INI's damage_factor really is "multiples of the ship's hull at the
	# sweet speed", and the floor means a stationary ram still hurts.
	# TRIWeight() is the DEFENSIVE axis, and it goes INSIDE the clamp: the
	# multiply chain at 0x1003c91d..0x1002f92e is `w * (v/ss) * (v/ss) * factor`
	# and only then the two `fcom`s against 0.25 / 5.0. So the TRI cannot push the
	# ram past the 5x ceiling that the speed alone already reaches.
	var ss := maxf(float(agg["sweet_speed"]), 1e-6)
	var t := speed / ss
	var d := clampf(system_tri_weight(agg) * t * t * float(agg["damage_factor"]),
			AGG_MIN_DAMAGE, AGG_MAX_DAMAGE)
	return hull_max * d

func aggressor_hit(dir_local: Vector3, speed: float) -> Dictionary:
	# icAggressorShield::OnCollision 0x1002f6b0, the effect half (from 0x1002f792).
	# `dir_local` is the unit vector from THIS ship to the other one, in this
	# ship's local frame. The other ship must be inside the coverage cone dead
	# ahead: cos(coverage * pi/360) is the cosine of HALF the authored arc
	# (0x101195a0 = pi/360, 0x1002f841) and the test at 0x1002f851 accepts when
	# dot(dir, forward) >= that -- the same hood idiom as the LDA above, on the
	# ship's +Z.
	#
	# Inside the cone: the victim takes DamageAtSpeed(|ship.velocity|) on the raw
	# hull path (source 5, 0x1002f8b0), this ship takes that SAME number times
	# self_damage_factor (source 4, 0x1002f8d0), and the collision is reported
	# HANDLED -- which is what makes iiSim::OnCollision skip the ordinary
	# collision damage for both ships (0x1009971c).
	var out := {"handled": false, "damage": 0.0, "self_damage": 0.0}
	if dir_local.length_squared() < 1e-9:
		return out
	var d := dir_local.normalized()
	for agg in aggressors:
		if not bool(agg["active"]):
			continue
		var cos_half := cos(deg_to_rad(float(agg["coverage"])) * 0.5)
		if d.z < cos_half:
			continue
		var dmg := aggressor_damage_at(agg, speed)
		out["handled"] = true
		out["damage"] = dmg
		out["self_damage"] = dmg * float(agg["self_damage_factor"])
		return out
	return out

func aggressor_auto(dir_local: Vector3, hostile: bool) -> bool:
	# The auto-fire half of 0x1002f6b0 (0x1002f6b7 .. 0x1002f77e): gated on the
	# CPU being fitted AND working AND carrying program bit 0x1000
	# (aggressor_shield_control, "Cargo_InstantShieldControl"). It fires the
	# shield at anything that is about to hit you and is not friendly and is not
	# one of the excluded sim types 7/8/9/12/31 (0x1002f721..0x1002f739).
	# Without the program the player fires it by hand.
	if programs & PROG_AGGRESSOR_CONTROL == 0:
		return false
	if not cpu_working():
		return false
	if not hostile:
		return false
	if aggressor_active():
		return true
	if dir_local.length_squared() < 1e-9:
		return false
	return aggressor_fire()

func has_cpu() -> bool:
	# icShip+0x29c. EnableZoom (0x100b0e80) distinguishes a MISSING cpu (event
	# 0x42 E_NoCPU) from a fitted-but-dead one (0x41 E_CPUOffline) from one that
	# simply has no imaging module (0x28 E_NoZoomProgram), so we have to as well.
	for sys in systems:
		if sys["class"] == "icCPU":
			return true
	return false

func cpu_working() -> bool:
	# iiShipSystem::IsWorking (vtable slot 13): the gates on every program bit.
	for sys in systems:
		if sys["class"] == "icCPU":
			return not bool(sys["destroyed"]) and float(sys["efficiency"]) > 0.0
	return false

func has_program(bit: int) -> bool:
	# icShip::HasProgram 0x10002a70 -- cpu(+0x29c)->programs & bit. Every gate
	# but engine-management/occlusion/repair also demands the CPU be working.
	return (programs & bit) != 0

# --- icReactor ---------------------------------------------------------------
# icReactor::Simulate 0x1003a2a0. The HUD's "reactor charge" gauge is a MISNOMER
# and the recovery says so plainly: nothing is stored and nothing drains.
#
#   ramp(+0x9c)  chases  ramp_target(+0xa0)  at 1/ramp_up_time per second
#   out          = base_output(+0x94), x pod_power_factor when a pod is fitted
#                  and on (0x1003a386)
#   +0x98        = out                      <- the gauge's DENOMINATOR
#   +0x7c        = efficiency * out * ramp  <- the gauge's NUMERATOR (0x1003a3d2)
#   +0x7c       *= cpu.engine_management_power_multiplier  when the CPU carries
#                  program bit 0x20 (0x1003a3e4)
#   icShip::AddPower(+0x7c)                                (0x1003a413)
#
# so the gauge reads `efficiency * ramp` (times the engine-management multiplier)
# and its EQUILIBRIUM is efficiency -- 1.0 for a healthy, cool, powered reactor,
# and up to 1.14 with cpu5 + the engine-management program, which the HUD clamps.
# It only goes RED (< 0.25, 0x101191ec) when the reactor is damaged, overheated,
# or throttled down by the player.
const REACTOR_RAMP_TIME := 20.0   # icReactor ctor 0x1003a0f0 (0x41a00000); only
                                  # powerplant_multiplayer.ini overrides it (2.0)
const REACTOR_THROTTLE_RATE := 0.35  # _DAT_10163f14: how fast the HUD throttle
                                     # (FUN_10108240) drags the ramp TARGET
const REACTOR_RED := 0.25         # 0x101191ec, the gauge's red threshold

func _simulate_reactor(sys: Dictionary, dt: float) -> float:
	var ramp := float(sys["ramp"])
	var target := float(sys["ramp_target"])
	var rut := maxf(float(sys["ramp_up_time"]), 1e-6)
	if absf(ramp - target) < 1e-6:
		ramp = target
	elif ramp < target:
		ramp = minf(ramp + dt / rut, target)
	else:
		ramp = maxf(ramp - dt / rut, target)
	sys["ramp"] = ramp
	var out := float(sys["output"])
	if bool(sys.get("has_pod", false)) and bool(sys.get("on", true)):
		out *= float(sys["pod_power"])
	sys["max_charge"] = out
	var charge := float(sys["efficiency"]) * out * ramp
	if has_program(PROG_ENGINE_MANAGEMENT):
		# NOTE: this gate has NO cpu-working check in the original (0x1003a3e4)
		charge *= _cpu_engine_mult()
	sys["charge"] = charge
	return charge

func _cpu_engine_mult() -> float:
	for sys in systems:
		if sys["class"] == "icCPU":
			return float(sys.get("engine_mult", 1.0))
	return 1.0

func reactor_charge() -> float:
	# The HUD status-icon feed (FUN_100e07f0): icHUD+0xf0 = clamp(+0x7c / +0x98)
	# -- and it DEFAULTS TO 1.0, not 0, when there is no reactor at all.
	for sys in systems:
		if sys["class"] != "icReactor":
			continue
		var mx := float(sys["max_charge"])
		if absf(mx) < 1e-6:
			return 1.0
		return clampf(float(sys["charge"]) / mx, 0.0, 1.0)
	return 1.0

func set_reactor_throttle(target: float) -> void:
	# FUN_10108240: the HUD throttle is the ONLY thing that moves +0xa0.
	for sys in systems:
		if sys["class"] == "icReactor":
			sys["ramp_target"] = clampf(target, 0.0, 1.0)

func nudge_reactor_throttle(dir: float, dt: float) -> void:
	for sys in systems:
		if sys["class"] == "icReactor":
			sys["ramp_target"] = clampf(
				float(sys["ramp_target"]) + dir * REACTOR_THROTTLE_RATE * dt,
				0.0, 1.0)

func reactor_throttle() -> float:
	for sys in systems:
		if sys["class"] == "icReactor":
			return float(sys["ramp_target"])
	return 1.0


# --- icShip::Brightness ------------------------------------------------------
# icShip::Brightness 0x10075420, vtable slot +0xc8. The ship's EM/visual
# signature, 0..1 -- the number the whole stealth system runs on: icSensor's scan
# (FUN_1003ae90) scores a contact as
#   efficiency * Brightness * (1 - dist/range)
# so a low brightness is literally what makes you hard to see. The HUD's bulb
# gauge (sprite 0x40) is clamp(Brightness()), red above 0.75 (0x10117d8c).
#
# TWO CORRECTIONS to what we previously believed:
#
#  * **ThrusterRatio() IS A STUB.** icShip::ThrusterRatio 0x10075600 is seven
#    bytes -- `fld dword [0x10117178]; ret` -- and 0x10117178 is 0.0. So the
#    lerp at 0x10075499, `b = (m_brightness - b) * ThrusterRatio() + b`,
#    collapses to `b`. The ship INI's `brightness` (icShip +0x1b8) is NEVER
#    reached on this path; only `min_brightness` (+0x2fc) is. We reproduce the
#    stub, because reproducing the intent would not be the shipped game.
#  * The terms are NOT "heat / LDS / weapon capacitor". The four subsims icShip
#    caches are icCPU (+0x29c), icReactor (+0x2a0), icActiveSensor (+0x2a4) and
#    icSensorDisruptor (+0x2a8), and those are what Brightness reads.
#
# UNKNOWN / dead: cold_thrusters.ini carries brightness_mod = -0.1, but its class
# is icThrusters (icShip +0x290), which Brightness never reads -- with
# ThrusterRatio stubbed too, the cold thrusters' stealth bonus looks dead in the
# shipped build.
const BRIGHT_HEAT_FACTOR := 0.4     # 0x10117558
const BRIGHT_DOCKED := 0.1          # 0x101184b0
const BRIGHT_RED := 0.75            # 0x10117d8c, the bulb gauge's red threshold

var min_brightness := 0.0           # icShip +0x2fc, ship INI `min_brightness`
var docked_at_station := false      # iiSim::IsDocked() && dock is an icStation

func brightness() -> float:
	var b := min_brightness
	# the reactor scales the idle floor by how hard it is actually running
	for sys in systems:
		if sys["class"] != "icReactor":
			continue
		var mx := float(sys["max_charge"])
		var ratio: float = 1.0 if absf(mx) < 1e-6 \
			else float(sys["charge"]) / mx
		b *= ratio
		break
	# b = (m_brightness - b) * ThrusterRatio() + b, and ThrusterRatio() == 0.0
	# (0x10075600). The term is a no-op in the shipped build; left here as the
	# comment above explains, not as code that pretends to do something.
	var heat_total := heat + heat_external
	if heat_total > 0.0:
		b += heat_total * BRIGHT_HEAT_FACTOR / HEAT_DAMAGE_THRESHOLD
	for sys in systems:
		match str(sys["class"]):
			"icSensorDisruptor":
				# a NEGATIVE brightness_mod (adv_sensor_disruptor.ini: -0.15),
				# added while the device is ON. Note: not gated on IsWorking and
				# not scaled by efficiency (0x100754f0).
				if bool(sys.get("on", true)) and not bool(sys["destroyed"]):
					b += float(sys.get("brightness_mod", 0.0))
			"icActiveSensor":
				# a POSITIVE one (+0.02..+0.1), scaled by efficiency, with no
				# on/working gate at all (0x10075510) -- running an active sensor
				# lights you up
				b += float(sys["efficiency"]) * float(sys.get("brightness_mod", 0.0))
			"icCPU":
				# the stealth program (bit 0x400) subtracts a flat modifier, and
				# THIS one does demand a working CPU (0x1007554b)
				if has_program(PROG_STEALTH) and cpu_working():
					b -= float(sys.get("stealth_mod", 0.0))
	if docked_at_station:
		b *= BRIGHT_DOCKED
	return clampf(b, 0.0, 1.0)


# --- icWeaponLink ------------------------------------------------------------
# @element icWeaponLink
# A weapon link is a FIRE GROUP, and the player never builds one: the loadout
# does it automatically when the hull carries more than one of the same weapon.
#
#   icLoadout::CreateWeaponLinks 0x10096940 walks the ship's subsims, keeps the
#   iiWeapon-derived ones and buckets them BY NAME (the INI `name=`, FcObject
#   +0xc) into three maps, by class:
#     icCounterMeasureMagazine  -> excluded outright (tested FIRST, at
#                                  0x10096a4c, because it derives from icMagazine)
#     icCannon (base iiGun) /
#     icSlugThrower             -> map A, eLinkType 0
#     icBeamProjector           -> map B, eLinkType 1
#     icMagazine                -> map C, eLinkType 2
#   icLoadout::RemoveSingleInstancesOfWeapon 0x10096cd0 then throws away every
#   bucket with fewer than two members -- one gun is not a group.
#   icLoadout::DoLinkWeapons 0x10096e40 makes one icWeaponLink (operator_new
#   0xa0) per surviving bucket, sets its eFireChannel to `(linktype != 0) + 1`
#   -- so guns land on channel 1 and beams/magazines on channel 2 -- stores the
#   eLinkType at +0x90, adds every member, and FiSim::AddSubsim's the link onto
#   the ship as a subsim of its own.
#
# What the link then DOES is in iiWeapon::AttemptToActivateWeapon 0x1003ccb0: a
# player-mode weapon fires only when the pilot's SELECTED object id (the id at
# pilot+0x98[pilot+0x8c]) matches -- and the id it matches against is the
# weapon's own (0x1003cd3e) when it has no link, but the LINK's (0x1003cd4b /
# 0x1003cd5c) when it has one. So one entry in the cycle selects the whole
# group and every member fires on the same trigger. icPlayerPilot::GetNextWeapon
# 0x100b0590 cycles that id list, which holds bare weapons AND links side by
# side, filtered by fire channel.
#
# icShip::WeaponLinkingMode (+0x2f4) / WeaponLinkingHardware (+0x2f8) and
# icPlayerPilot::ToggleWeaponLinking (0x100b0f60, log events 0x29/0x2a/0x2b) are
# a SEPARATE player toggle that needs Cargo_WeaponLinkHardware fitted. Two things
# about it are UNKNOWN and stay that way: nothing in iwar2.dll reads +0x2f4 other
# than the accessor, so what the toggle actually switches was not recovered; and
# the hardware's template, ini:/subsims/systems/player/subsystems/weapon_link
# (cargo type 555, icargoscript.gd:5477), DOES NOT SHIP -- the file is absent
# from data/ini. The automatic grouping above is the part that works.
const LINK_TYPE_GUN := 0
const LINK_TYPE_BEAM := 1
const LINK_TYPE_MAGAZINE := 2

const LINK_CLASS_TYPE := {
	"icCannon": LINK_TYPE_GUN, "icSlugThrower": LINK_TYPE_GUN,
	"icBeamProjector": LINK_TYPE_BEAM,
	"icMagazine": LINK_TYPE_MAGAZINE,
	"icMissileMagazine": LINK_TYPE_MAGAZINE,
	# icCounterMeasureMagazine is deliberately absent: it is excluded first
}

func weapon_groups() -> Array:
	# The cycle list the player actually sees: one entry per link, plus every
	# weapon that did not end up in one. Fire channel 1 = the guns, 2 = beams
	# and magazines, exactly as DoLinkWeapons assigns it.
	var buckets: Dictionary = {}
	var singles: Array = []
	for sys in systems:
		var cls: String = sys["class"]
		if not LINK_CLASS_TYPE.has(cls):
			continue
		var key: String = "%s/%s" % [cls, sys["name"]]
		if not buckets.has(key):
			buckets[key] = []
		(buckets[key] as Array).append(sys)
	var out: Array = []
	for key: String in buckets:
		var members: Array = buckets[key]
		var cls: String = str(members[0]["class"])
		var lt: int = LINK_CLASS_TYPE[cls]
		var linked: bool = members.size() >= 2
		if not linked:
			singles.append(members[0])
			continue
		out.append({
			"name": str(members[0]["name"]), "class": cls,
			"link_type": lt, "channel": 2 if lt != LINK_TYPE_GUN else 1,
			"members": members, "linked": true,
		})
	for sys in singles:
		var lt: int = LINK_CLASS_TYPE[str(sys["class"])]
		out.append({
			"name": str(sys["name"]), "class": str(sys["class"]),
			"link_type": lt, "channel": 2 if lt != LINK_TYPE_GUN else 1,
			"members": [sys], "linked": false,
		})
	return out

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

func set_system_off(sys: Dictionary, off: bool) -> void:
	# icHUDEngineering row 0's Enter (0x10106463): flip bit 1 of the subsim's
	# flags, but ONLY when bit 5 -- "can be switched off" -- is up. The base
	# ctor (0x1003b9f0) raises bit 5, so every subsim is switchable unless its
	# own ctor clears it; nothing in the shipped classes does, so the gate
	# passes for all of them. Recorded here so the gate has one home if a class
	# turns up that clears it.
	sys["off"] = off

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

func shield_rows() -> Array:
	# icHUDShields' feed (Draw 0x100fa540). The element walks the ship's
	# component list, keeps everything IsKindOf(icPlayerLDA) -- the class handle
	# at DAT_10167e5c, registered at 0x100ac7a0 -- and CAPS THE LIST AT TWO
	# (cmp esi,2 @ 0x100fa596). icAILDA is a sibling under iiLDA, not a subclass,
	# so an AI shield never appears here: this panel is player LDAs only.
	#
	# Each row's fill is icPlayerLDA charge / capacity (+0xa4 / +0x94,
	# 0x100fa9ca) and its status text turns on min_energy (the class static 0.2
	# @ 0x101607e0, i.e. flux.ini [icPlayerLDA] min_energy): below
	# min_energy * capacity the row reads OFFLINE.
	#
	# Row order in the original is the two LDAs' forward axes sorted by Y
	# ascending (0x100fa75f) -- the down-facing one first. Our LDAs carry their
	# mount-null position instead of an orientation, so we sort on that Y, which
	# on every shipped hull (shield_upper / shield_lower, upper_lda / lower_lda)
	# is the same ordering.
	var rows: Array = []
	for lda in ldas:
		if lda["lda"] != "icPlayerLDA":
			continue
		var cap := float(lda["capacity"])
		var frac: float = 0.0 if cap <= 0.0 else clampf(float(lda["energy"]) / cap, 0.0, 1.0)
		var broken: bool = float(lda["hp_max"]) > 0.0 and float(lda["hp"]) <= 0.0
		var working: bool = not broken and not bool(lda["destroyed"]) \
				and float(lda["efficiency"]) > 0.0
		rows.append({
			"name": str(lda["name"]), "frac": 0.0 if broken else frac,
			"working": working,
			"destroyed": broken,
			# below min_energy * capacity the LDA cannot deflect at all
			# (icPlayerLDA 0x100acda0) and the panel says so
			"offline": float(lda["energy"]) < LDA_MIN_ENERGY * cap,
			"y": (lda["pos"] as Vector3).y,
		})
	rows.sort_custom(func(a, b): return float(a["y"]) < float(b["y"]))
	return rows.slice(0, 2)

func damaged_systems() -> Array:
	var out: Array = []
	for sys in systems:
		if float(sys["hp_max"]) > 0.0 and float(sys["hp"]) < float(sys["hp_max"]):
			out.append(sys)
	return out
