class_name Mission
extends Node
# Data-driven mission runner over the extracted campaign: sequential steps
# of dialogue (say -> comms/VO/subtitles), objectives (per the original's
# E_NewObjective / E_ObjectiveSucceeded events), waypoints, autopilot
# lessons, travel and docking triggers. Mission scripts are authored from
# docs/campaign.md + data/json/campaign.json key order.

var main: Node3D
var steps: Array = []
var idx := -1
var objectives: Dictionary = {}  # id -> {text, done}
var active := false
var _wp_counter := 0

func start(script: Array) -> void:
	steps = script
	idx = -1
	active = true
	_advance()

func _advance() -> void:
	idx += 1
	if idx >= steps.size():
		active = false
		main.hud.warn("MISSION COMPLETE", 5.0)
		main.audio.play("audio/gui/confirm.wav", -4.0)
		return
	var s: Dictionary = steps[idx]
	if s.has("say"):
		main.comms.say_key(str(s["say"]))
	if s.has("obj_add"):
		var text := str(main.comms.strings.get(s["obj_add"], s["obj_add"]))
		objectives[s.get("id", s["obj_add"])] = {"text": text, "done": false}
		main.hud.warn("NEW MISSION OBJECTIVE", 2.5)
		main.hud.log_msg("+ " + text)
		main.audio.play("audio/hud/valid_input.wav", -8.0)
	if s.has("obj_done"):
		if objectives.has(s["obj_done"]):
			objectives[s["obj_done"]]["done"] = true
			main.hud.warn("MISSION OBJECTIVE COMPLETED", 2.5)
			main.audio.play("audio/gui/confirm.wav", -8.0)
	if s.has("waypoint"):
		_make_waypoint(s)
	if s.has("music"):
		main.audio.music(str(s["music"]))
	# steps without a wait condition chain immediately
	if not _has_wait(s):
		_advance()

func _make_waypoint(s: Dictionary) -> void:
	var at: Vector3
	if s["waypoint"] is String:
		var found := false
		for o in main.objects:
			if str(o["name"]) == str(s["waypoint"]):
				at = Vector3(o["x"], o["y"], o["z"])
				found = true
		if not found:
			return
	else:
		at = Vector3(main.px, main.py, main.pz) + (s["waypoint"] as Vector3)
	if s.has("offset"):
		at += s["offset"]
	_wp_counter += 1
	var rec := {"name": str(s.get("wp_name", "Waypoint %d" % _wp_counter)),
		"category": "lpoint", "x": at.x, "y": at.y, "z": at.z,
		"radius": 0.0, "avatar": "", "jumps": [], "colors": [], "node": null,
		"waypoint": true}
	main.objects.append(rec)
	# auto-target it so the HUD guides the player
	main.target_idx = main.objects.size() - 1
	main.target_ai = null

func _remove_waypoints() -> void:
	for i in range(main.objects.size() - 1, -1, -1):
		if main.objects[i].get("waypoint", false):
			if main.objects[i]["node"] != null:
				main.objects[i]["node"].queue_free()
			if main.target_idx == i:
				main.target_idx = -1
			main.objects.remove_at(i)

func _has_wait(s: Dictionary) -> bool:
	for k in ["until_comms", "until_near", "until_ap", "until_docked",
			"until_undocked", "wait"]:
		if s.has(k):
			return true
	return false

func _physics_process(delta: float) -> void:
	if not active or idx >= steps.size() or idx < 0:
		return
	var s: Dictionary = steps[idx]
	var done := false
	if s.has("wait"):
		s["wait"] = float(s["wait"]) - delta
		done = float(s["wait"]) <= 0.0
	elif s.has("until_comms"):
		done = not main.comms.speaking()
	elif s.has("until_near"):
		done = Vector3(main.px, main.py, main.pz).distance_to(
			_wp_pos()) < float(s["until_near"])
	elif s.has("until_ap"):
		done = main.ap_mode == int(s["until_ap"])
	elif s.has("until_docked"):
		done = str(s["until_docked"]).to_lower() in main.docked_at.to_lower()
	elif s.has("until_undocked"):
		done = main.docked_at == ""
	if done:
		if s.get("clear_wp", false):
			_remove_waypoints()
		_advance()

func _wp_pos() -> Vector3:
	for i in range(main.objects.size() - 1, -1, -1):
		if main.objects[i].get("waypoint", false):
			var o: Dictionary = main.objects[i]
			return Vector3(o["x"], o["y"], o["z"])
	return Vector3(INF, INF, INF)


# --- Act 0 Mission 10: Clay's tutorial run to Lucrecia's Base --------------

static func act0_m10() -> Array:
	var wp := func(offset: Vector3, near: float) -> Dictionary:
		return {"waypoint": offset, "until_near": near, "clear_wp": true}
	return [
		{"music": "ambient"},
		{"say": "a0_m10_dialogue_clay_i_know", "until_comms": true},
		{"say": "a0_m10_dialogue_clay_before_we", "until_comms": true},
		# contact list lesson: fly to Clay's waypoint
		{"say": "a0_m10_dialogue_clay_contact_list"},
		{"obj_add": "a0_m10_objectives_approach_clay", "id": "wp1"},
		wp.call(Vector3(4000, 400, -6000), 800.0),
		{"obj_done": "wp1", "say": "a0_m10_dialogue_clay_good",
			"until_comms": true},
		# approach autopilot lesson (F6)
		{"say": "a0_m10_dialogue_clay_instructions_approach"},
		{"obj_add": "a0_m10_objectives_approach_lesson", "id": "ap1",
			"until_ap": 1},
		{"obj_done": "ap1", "say": "a0_m10_dialogue_clay_approach_engage",
			"until_comms": true},
		# formate autopilot lesson (F7)
		{"say": "a0_m10_dialogue_clay_instructions_formate"},
		{"obj_add": "a0_m10_objectives_formate_lesson", "id": "ap2",
			"until_ap": 2},
		{"obj_done": "ap2", "say": "a0_m10_dialogue_clay_formate_engage",
			"until_comms": true},
		# fly to Griffon (LDS travel)
		{"say": "a0_m10_dialogue_clay_this_is", "until_comms": true},
		{"obj_add": "a0_m10_objectives_fly_to", "id": "griffon"},
		{"waypoint": "Griffon", "offset": Vector3(0, 0, 8.0e6),
			"wp_name": "Griffon Approach", "until_near": 2.0e6,
			"clear_wp": true},
		{"obj_done": "griffon", "say": "a0_m10_dialogue_clay_there_weve",
			"until_comms": true},
		# on to the Effrit
		{"say": "a0_m10_dialogue_clay_ok_this_is", "until_comms": true},
		{"obj_add": "a0_m10_objectives_fly_to_effrit", "id": "effrit"},
		{"waypoint": "The Effrit", "wp_name": "The Effrit",
			"until_near": 3.0e5, "clear_wp": true},
		{"obj_done": "effrit", "say": "a0_m10_dialogue_clay_were_here",
			"until_comms": true},
		# waypoint chain through the Effrit to Lucrecia's Base
		{"obj_add": "a0_m10_objectives_approach_lucrecias", "id": "base"},
		{"say": "a0_m10_dialogue_clay_im_bringing"},
		{"waypoint": "Lucrecia's Base", "offset": Vector3(5.0e4, 6000, 4.0e4),
			"wp_name": "Marked Asteroid 1", "until_near": 4000.0, "clear_wp": true},
		{"say": "a0_m10_dialogue_clay_progress1"},
		{"waypoint": "Lucrecia's Base", "offset": Vector3(2.6e4, 2500, 2.2e4),
			"wp_name": "Marked Asteroid 2", "until_near": 3000.0, "clear_wp": true},
		{"say": "a0_m10_dialogue_clay_progress2"},
		{"waypoint": "Lucrecia's Base", "offset": Vector3(1.2e4, 800, 0.9e4),
			"wp_name": "Marked Asteroid 3", "until_near": 2500.0, "clear_wp": true},
		{"say": "a0_m10_dialogue_clay_there_it", "until_comms": true},
		{"until_docked": "lucrecia"},
		{"obj_done": "base"},
		{"say": "a0_m10_dialogue_clay_first_hud", "until_comms": true},
		{"say": "a0_m10_dialogue_clay_top_right", "until_comms": true},
		{"say": "a0_m10_dialogue_clay_bottom_right", "until_comms": true},
		{"say": "a0_m10_dialogue_clay_top_left", "until_comms": true},
		{"say": "a0_m10_dialogue_clay_under_top_left", "until_comms": true},
	]
