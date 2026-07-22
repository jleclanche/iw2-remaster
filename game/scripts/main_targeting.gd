# Main layer: targeting, contacts, sensors, autopilot switches.
# Part of main.gd's extends chain -- see
# main_state.gd for the scheme. Same node, same class.
extends "main_state.gd"

func contact_list() -> Array:
	# original columns: faction / type / range / name (manual, HUD section).
	# The rows are _contacts_full()'s admissions; a contact beyond
	# identification_range that is not explicitly sensor-visible is the gold
	# "UNKNOWN" row with blank faction and type columns (FUN_1003a8e0 sets
	# contact flag 8, FUN_100e8530 @ 0x100e8530 renders it: colour
	# DAT_10174f60 gold, name = hud_unknown_contact, both 5-char columns empty).
	var list: Array = []
	for e in _contacts_full():
		if e["kind"] == "obj":
			var o: Dictionary = objects[e["idx"]]
			if e["unknown"]:
				list.append({"name": "UNKNOWN", "dist": e["dist"],
						"hostile": false, "unknown": true,
						"targeted": e["idx"] == target_idx,
						"category": o["category"], "faction": "", "type": ""})
			else:
				list.append({"name": o["name"], "dist": e["dist"],
						"hostile": false, "unknown": false,
						"targeted": e["idx"] == target_idx,
						"category": o["category"],
						"faction": str(o.get("faction",
							"NAV" if o["category"] in
								["lpoint", "waypoint", "star", "body", "nebula"]
							else _station_faction(str(o["name"])))),
						# type column strings: data/text/hud.csv hud_type_star
						# (STAR), hud_type_planet (BODY), hud_type_nebula (NBULA),
						# hud_type_waypoint / hud_type_lpoint / hud_type_station
						"type": str(o.get("type",
							{"lpoint": "LAGPT", "waypoint": "WAYPT",
								"star": "STAR", "body": "BODY",
								"nebula": "NBULA"}.get(
								str(o["category"]), "STATN")))})
		else:
			var a: AiShip = e["ai"]
			var hostile: bool = _is_hostile(a)
			if e["unknown"]:
				list.append({"name": "UNKNOWN", "dist": e["dist"],
						"hostile": false, "unknown": true,
						"targeted": a == target_ai,
						"category": "traffic", "faction": "", "type": ""})
			else:
				list.append({"name": _contact_name(a), "dist": e["dist"],
						"hostile": hostile, "unknown": false,
						"targeted": a == target_ai, "category": "traffic",
						"faction": "OUTLW" if hostile else a.faction,
						"type": "FIGHT" if hostile else a.ctype})
	return list

## iiSim::VisibleToSensor (iwar2 @ 0x100013b0) gates a sim's place in the contact
## list. The scripts clear it with isim.SetSensorVisibility to stage an ambush --
## it applied to SHIPS as much as to stations, and we were only honouring it for
## static records, so hidden ambushers were showing up on the list.
func _sensor_visible(a: AiShip) -> bool:
	if pog_world == null:
		return true
	var key := String(a.sim_key)
	if key.is_empty():
		return true
	var s = pog_world.sims.get(key)
	return true if s == null else s.sensor_visible

## Never show a raw sim name. A sim's NAME is a localisation key and the engine
## resolves it (icAIPilot::ResolveName) before anything displays it; a ship with
## no name at all is "Undefined", never its Godot node name.
func _contact_name(a: AiShip) -> String:
	if not String(a.display_name).is_empty():
		return String(a.display_name)
	return "Undefined"

# --- subtargeting (icPlayerPilot.SubTarget -> icShip::CycleSubTarget) --------
# 0x10063a80 steps a cursor through the target ship's subsim list; one step
# past the last subsim clears it. The HUD redirects the target readout to the
# subtargeted component and marks it in-world (FUN_100f8360, sprite 3).
var subtarget_i := -1
var _subtarget_of: Object = null

func _cycle_subtarget() -> void:
	if target_ai == null or not is_instance_valid(target_ai) \
			or target_ai.sys == null:
		return
	if _subtarget_of != target_ai:
		_subtarget_of = target_ai
		subtarget_i = -1
	var n: int = target_ai.sys.systems.size()
	if n == 0:
		return
	subtarget_i += 1
	if subtarget_i >= n:
		subtarget_i = -1
	audio.play("audio/hud/target_changed.wav", -12.0)

func subtarget_sys() -> Dictionary:
	# the subtargeted subsim record, or {} when none is active
	if subtarget_i < 0 or target_ai == null or not is_instance_valid(target_ai) \
			or _subtarget_of != target_ai or target_ai.sys == null:
		return {}
	var arr: Array = target_ai.sys.systems
	return arr[subtarget_i] if subtarget_i < arr.size() else {}

func subtarget_world_pos() -> Vector3:
	var s := subtarget_sys()
	if s.is_empty():
		return Vector3.INF
	# a mount without an attach null sits at the hull origin -- the original's
	# behaviour (FcSubsim ctor zeroes the position), not a failed lookup
	var local: Vector3 = target_ai.sys.null_pos.get(str(s.get("null", "")),
			Vector3.ZERO)
	return target_ai.global_transform * local

func _target_pos() -> Vector3:
	if target_ai != null and is_instance_valid(target_ai):
		return target_ai.global_position
	# self-heal a stale record target: scripted destroys (act transitions
	# above all) shrink objects[] without clearing the selection, and every
	# HUD read of objects[target_idx] after this trusts the index
	if target_idx >= objects.size():
		target_idx = -1
	if target_idx >= 0:
		var t: Dictionary = objects[target_idx]
		return Vector3(t["x"] - px, t["y"] - py, t["z"] - pz)
	return Vector3.INF

func _target_distance() -> float:
	var p := _target_pos()
	return INF if p == Vector3.INF else p.length()

func target_avatar() -> String:
	# avatar path for the MFD's EO feed
	if target_ai != null and is_instance_valid(target_ai):
		return target_ai.avatar_path
	if target_idx >= 0:
		var av := str(objects[target_idx].get("avatar", ""))
		if av != "":
			return "data/avatars/" + av
	return ""

func _nearest(category: String, range_limit := INF) -> Dictionary:
	var best := {}
	var bestd := INF
	for o in objects:
		if o["category"] != category:
			continue
		var d := Vector3(o["x"] - px, o["y"] - py, o["z"] - pz).length()
		if d < bestd and d < range_limit:
			bestd = d
			best = o
	best["dist"] = bestd
	return best

func _nearest_inhibitor() -> Dictionary:
	# LDS INHIBITION is REGION-based, not a property of stations or bodies. A
	# ship is inhibited only while inside an icLDSIRegion sphere the scripts
	# author with iRegion.CreateLDSI. In the binary every ship carries an
	# inhibit counter at iiThrusterSim+0x251: icLDSIRegion::OnSimEnter
	# (iwar2 @ 0x10048680) -> EnterLDSInhibitRegion (0x1007e450) bumps it,
	# LeaveLDSInhibitRegion (0x1007e4a0) drops it, IsLDSInhibited (0x100023c0)
	# reads it, and icLDSDrive::Simulate (0x10037040) breaks the ship out of LDS
	# while it is non-zero. Stations and bodies carry NO intrinsic LDSI shell --
	# standing clear of a mass is AVOIDANCE, a separate break-off distance
	# (see _lds_avoidance). pog_ents already tracks these regions; ask it.
	if pog_ents == null:
		return {}
	# nearest_ldsi answers player-relative, differenced in doubles (issue #27)
	var b := pog_ents.nearest_ldsi()
	if b.is_empty():
		return {}
	return {"center": Vector3(b["center"]),
		"r": float(b["r"]), "clear": float(b["clear"])}

func _lds_clearance() -> float:
	# Clearance from LDS INHIBITION (the region boundary), +inf when no region.
	var b := _nearest_inhibitor()
	return INF if b.is_empty() else float(b["clear"])

func _lds_avoidance() -> float:
	# A DIAGNOSTIC metric only (the demo autoplay logs/gates on it) -- NOT a drive
	# gate and NOT used in the flight path. The original has no LDS mass handling
	# at all: the drive breaks out on the inhibit counter alone (icLDSDrive::
	# Simulate @ 0x10037040) and there is no route-around (LDSObstacles is never
	# populated -- docs/lds.md). Returns the signed clearance to the nearest mass
	# shell the ship is CLOSING on, shell = 1.5x radius + 200 m (InnerMarkerRadius
	# @ 0x100560d0, m_heat_radius_multiplier 0.5 @ 0x1011af58, 0x10119470).
	var best := INF
	var vel: Vector3 = ship.velocity
	for o in objects:
		var mult := 1.0
		match o["category"]:
			"body", "star":
				mult = 1.5
			"station", "gunstar":
				mult = 1.0
			_:
				continue
		var rel := Vector3(o["x"] - px, o["y"] - py, o["z"] - pz)
		if vel.dot(rel) <= 0.0:
			continue
		var margin := float(o["radius"]) * mult + 200.0
		best = minf(best, rel.length() - margin)
	return best


func inhibit_charge() -> float:
	# 1 deep inside an inhibition zone, discharging to 0 at its boundary
	# (the HUD roundel's pip ring). LDSi weapon hits pin it at full.
	if disrupt_time > 0.0:
		return 1.0
	var b := _nearest_inhibitor()
	if b.is_empty():
		return 0.0
	var clear: float = b["clear"]
	if clear >= 0.0:
		return 0.0
	return clampf(-clear / maxf(float(b["r"]), 1.0), 0.0, 1.0)

# --- targeting (original contact-list semantics) ----------------------------

## The sensor model: icSensor's default update (iwar2 @ 0x1003b330; per-sim gate
## FUN_1003ae90 @ 0x1003ae90) feeding icPlayerContactList. ShowAllContacts
## (icPlayerPilot+0x318, an input-toggled debug mode that lists every sim in the
## cluster) is OFF, as shipped. The gate, in order:
##  - a sim whose sensor-visibility byte (iiSim+0x198, SetSensorVisibility) is
##    CLEAR is rejected outright -- the scripted ambush -- with two exceptions:
##      stations (eSensorType 3) pass unless geography-hidden (SetHidden flag 2,
##      the undiscovered Lucrecia's Base), and L-point waypoints (type 5) pass
##    within 100 km (DAT_10119d18 box / DAT_10119d14 = (1e5)^2 sphere);
##  - ships default sensor-VISIBLE (iiThrusterSim ctor sets +0x198=1); stations
##    and all other geography default INVISIBLE (icGeography ctor) -- so
##    planets, suns, nebulae and belts never list unless a script turns them on;
##  - beyond efficiency*range (passive0_sensors.ini: 80 km) anything not
##    explicitly sensor-visible is dropped; explicitly visible sims (the found
##    base, mission markers) list at ANY range as nav contacts (flags 0x82);
##  - within 10 km (DAT_1015bb2c) detection is unconditional; beyond it the
##    score efficiency * Brightness() * (1 - dist/range) must reach
##    sensed_brightness (0.1) -- ship_systems.brightness() is that Brightness();
##    a Brightness under epsilon scores +inf (geography, cold ships);
##  - the player's current target is force-added regardless
##    (icPlayerContactList::PostProcess), and the list sorts by range
##    (CompareByRange). "unknown" = beyond identification_range (20 km) and not
##    explicitly visible (contact flag 8, FUN_1003a8e0).
const SENSOR_RANGE := 80000.0        # passive0_sensors.ini range
const SENSOR_ID_RANGE := 20000.0     # passive0_sensors.ini identification_range
const SENSOR_MIN_BRIGHT := 0.1       # passive0_sensors.ini sensed_brightness
const SENSOR_CLOSE := 10000.0        # DAT_1015bb2c: always-detected bubble
const LPOINT_LIST_RANGE := 100000.0  # DAT_10119d18: L-point listing radius

func _contacts_full() -> Array:
	var list: Array = []
	for i in objects.size():
		var o: Dictionary = objects[i]
		# SetSensorVisibility(sim, false) / hidden geography: never listed
		if o.get("sensor_hidden", false):
			continue
		var d := Vector3(o["x"] - px, o["y"] - py, o["z"] - pz).length()
		var forced: bool = o.get("sensor_forced", false)
		var show := forced or i == target_idx
		if not show:
			match o["category"]:
				"station", "gunstar":
					show = d < SENSOR_RANGE
				"lpoint", "waypoint":
					# nav points pass the sensor gate within 100 km
					# (FUN_1003ae90's type-5 window, DAT_10119d14)
					show = d < LPOINT_LIST_RANGE
				"star", "body", "nebula":
					# the system's own geography: always on the nav sensor.
					# icSun/icPlanet/icNebula carry a sensor type (0x194) whose
					# class-icon lookup FUN_100e86d0 is non-zero (star type 1 ->
					# icon 0x36), so they are always a KNOWN nav contact, never
					# the gold UNKNOWN row and never range-gated off the list.
					show = true
		if show:
			list.append({"kind": "obj", "idx": i, "dist": d,
					"unknown": not forced and d > SENSOR_ID_RANGE
						and o["category"] not in
							["lpoint", "waypoint", "star", "body", "nebula"]})
	for a in ai_ships:
		if not _sensor_visible(a):
			continue
		var d: float = a.global_position.length()
		if d > SENSOR_CLOSE and a != target_ai:
			var sig := 1.0
			if a.sys != null:
				sig = a.sys.brightness()
			if sig >= 1e-6 and sig * (1.0 - d / SENSOR_RANGE) < SENSOR_MIN_BRIGHT:
				continue
		# ships stay identified: flag 8 is only set for sims whose visibility
		# byte is clear (FUN_1003a8e0 tests param_5 first), and ships default
		# visible. The separate icShip identify counter (+0x2e0 < +0x2e4,
		# stripped in icPlayerContactList::Add) is 0 < 0 = complete unless a
		# mission sets it -- not modelled.
		list.append({"kind": "ai", "ai": a, "dist": d, "unknown": false})
	list.sort_custom(func(x, y): return x["dist"] < y["dist"])
	return list

func _current_contact_pos(list: Array) -> int:
	for i in list.size():
		var e: Dictionary = list[i]
		if e["kind"] == "ai" and e["ai"] == target_ai and target_ai != null:
			return i
		if e["kind"] == "obj" and e["idx"] == target_idx and target_idx >= 0:
			return i
	return -1

func _set_contact(e: Dictionary) -> void:
	if e["kind"] == "ai":
		target_ai = e["ai"]
		target_idx = -1
	else:
		target_idx = e["idx"]
		target_ai = null
	audio.play("audio/hud/target_changed.wav", -10.0)

func _cycle_contact(dir: int) -> void:
	var list := _contacts_full()
	if list.is_empty():
		return
	var pos := _current_contact_pos(list)
	_set_contact(list[clampi(pos + dir, 0, list.size() - 1)]
		if pos >= 0 else list[0])

func _target_contact_index(i: int) -> void:
	var list := _contacts_full()
	if list.is_empty():
		return
	_set_contact(list[clampi(i, 0, list.size() - 1)])

func _target_nearest_enemy() -> void:
	var best: AiShip = null
	var bestd := INF
	for a in ai_ships:
		if _is_hostile(a) and a.global_position.length() < bestd:
			bestd = a.global_position.length()
			best = a
	if best != null:
		target_ai = best
		target_idx = -1
		audio.play("audio/hud/target_changed.wav", -10.0)
	else:
		audio.play("audio/hud/invalid_input.wav", -10.0)

func _cycle_enemy() -> void:
	var enemies: Array = []
	for a in ai_ships:
		if _is_hostile(a):
			enemies.append(a)
	if enemies.is_empty():
		audio.play("audio/hud/invalid_input.wav", -10.0)
		return
	var idx := enemies.find(target_ai)
	target_ai = enemies[(idx + 1) % enemies.size()]
	target_idx = -1
	audio.play("audio/hud/target_changed.wav", -10.0)

func _target_nearest_to_direction() -> void:
	var fwd := -ship.global_transform.basis.z
	var best := {}
	var besta := 0.6  # ~35 degree cone
	for e in _contacts_full():
		var p: Vector3
		if e["kind"] == "ai":
			p = e["ai"].global_position
		else:
			var o: Dictionary = objects[e["idx"]]
			p = Vector3(o["x"] - px, o["y"] - py, o["z"] - pz)
		var a := fwd.angle_to(p.normalized())
		if a < besta:
			besta = a
			best = e
	if not best.is_empty():
		_set_contact(best)
	else:
		audio.play("audio/hud/invalid_input.wav", -10.0)

# --- autopilots (F5-F9, iAI order packages) ---------------------------------

func _set_autopilot(mode: int) -> void:
	if mode != 0 and _target_pos() == Vector3.INF and mode != 3:
		hud.warn("AUTOPILOT: NO TARGET")
		audio.play("audio/hud/invalid_input.wav", -8.0)
		return
	# icPlayerPilot::SetAutopilot (0x100af930): you cannot formate on something
	# that has no thrusters. The engine silently downgrades Formate to Approach
	# when the target is not an iiThrusterSim -- so F7 on a station approaches it.
	if mode == 2 and target_ai == null:
		mode = 1
	if mode == 0:
		_disengage_autopilot()
	else:
		ap_mode = mode
		# the order package latches the target it was engaged WITH (0x100afbc0)
		ap_target_idx = target_idx
		ap_target_ai = target_ai
	audio.play("audio/gui/confirm.wav", -10.0)
	var names := ["OFF", "APPROACH", "FORMATE", "DOCK", "MATCH VELOCITY"]
	hud.log_msg("AUTOPILOT: %s" % names[mode])

## icPlayerPilot::DisengageAutopilot (0x100b0010) ends by calling
## ResetThrottle (0x100b1450): the demanded throttle (+0x54) goes to ZERO --
## dropping the autopilot leaves the ship braking to a stop until you touch
## the throttle, exactly like the original. (An earlier pass handed the
## wheel back at the current speed instead; that was invented.) Every path
## that drops the autopilot goes through here.
func _disengage_autopilot() -> void:
	ap_mode = 0
	ap_target_idx = -1
	ap_target_ai = null
	ship.set_speed = 0.0
	ship.input_thrust = Vector3.ZERO
	ship.input_rotate = Vector3.ZERO

## The PogSim handle for whatever the player has targeted, so the marker maths
## can see its class (planet / star / nebula / belt) and its radius.
func _target_sim() -> PogWorld.PogSim:
	if pog_world == null:
		return null
	if target_ai != null and is_instance_valid(target_ai):
		return pog_world._wrap_ship(target_ai)
	if target_idx >= 0 and target_idx < objects.size():
		return pog_world._wrap_record(objects[target_idx])
	return null


## icAIServices::InnerMarkerRadius(player_ship, target) -- the autopilot's real
## break-off distance. See docs/original.md section 4a.
func _target_marker() -> float:
	if pog_world == null:
		return 0.0
	return PogWorld.inner_marker_radius(pog_world.player_sim(), _target_sim())
