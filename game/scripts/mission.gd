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
var prompt := ""       # ihud.SetPrompt: bottom-of-HUD lesson prompt
var prompt_keys := ""  # the key-combination hint next to it
var _wp_counter := 0
var _kill_mark := 0

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
		main.comms.say_key(str(s["say"]), str(s.get("who", "")))
	if s.has("ask"):
		main.comms.ask(str(s["ask"]), str(s.get("who", "")), s["options"])
	if s.has("movie"):
		main._play_movie(str(s["movie"]), func() -> void: pass)
	if s.has("hostiles"):
		for h in s["hostiles"]:
			var ai: AiShip = main.spawn_hostile(h["at"] as Vector3)
			ai.display_name = str(h.get("name", ai.display_name))
			ai.faction = str(h.get("faction", "OUTLW"))
	if s.has("despawn_hostiles"):
		for a in main.ai_ships.duplicate():
			if a.behavior == "attack":
				main.ai_ships.erase(a)
				if main.target_ai == a:
					main.target_ai = null
				a.queue_free()
		main.audio.music("ambient")
	if s.has("npcs"):
		for n in s["npcs"]:
			main._spawn_npc(str(n["name"]), str(n.get("faction", "INDPT")),
				str(n.get("type", "TRANS")),
				str(n.get("avatar", "data/avatars/avatars/utilityvessel/setup.gltf")),
				n["at"], n.get("route", []))
	if s.has("mark_kills"):
		_kill_mark = main.kill_count
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
	if s.has("prompt"):
		# ihud.SetPrompt(text, key_hints); "" clears
		prompt = str(main.comms.strings.get(s["prompt"], s["prompt"]))
		prompt_keys = str(s.get("keys", ""))
	if s.has("target"):
		# aim the player's target at a named object (dock lessons etc.)
		for i in main.objects.size():
			if str(main.objects[i]["name"]) == str(s["target"]):
				main.target_idx = i
				main.target_ai = null
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
	if s.get("auto_target", true):
		# auto-target it so the HUD guides the player
		main.target_idx = main.objects.size() - 1
		main.target_ai = null
	# decoy blips for the contact-list lesson (bytecode: 5 waypoints
	# named a0_m10_name_other, 4-5 km from the player)
	var rng := RandomNumberGenerator.new()
	rng.seed = 42
	for i in int(s.get("blips", 0)):
		var dir2 := Vector3(rng.randf_range(-1, 1), rng.randf_range(-0.5, 0.5),
			rng.randf_range(-1, 1)).normalized()
		var dd := rng.randf_range(4000.0, 5000.0)
		main.objects.append({"name": str(main.comms.strings.get(
				"a0_m10_name_other", "Marker")) + " %d" % (i + 1),
			"category": "lpoint",
			"x": main.px + dir2.x * dd, "y": main.py + dir2.y * dd,
			"z": main.pz + dir2.z * dd,
			"radius": 0.0, "avatar": "", "jumps": [], "colors": [],
			"node": null, "waypoint": true})

func _remove_waypoints() -> void:
	for i in range(main.objects.size() - 1, -1, -1):
		if main.objects[i].get("waypoint", false):
			if main.objects[i]["node"] != null:
				main.objects[i]["node"].queue_free()
			if main.target_idx == i:
				# target gone: drop it and release any autopilot chasing it,
				# else the AP keeps flying at a stale (re-indexed) object
				main.target_idx = -1
				if main.ap_mode != 0:
					main._set_autopilot(0)
			elif main.target_idx > i:
				main.target_idx -= 1  # keep the same object targeted
			main.objects.remove_at(i)

func _has_wait(s: Dictionary) -> bool:
	for k in ["until_comms", "until_near", "until_ap", "until_docked",
			"until_undocked", "until_target", "until_kills", "wait"]:
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
	elif s.has("until_target"):
		# lesson: player must select the named contact themselves
		done = main.target_idx >= 0 and \
			str(main.objects[main.target_idx]["name"]) == str(s["until_target"])
	elif s.has("until_kills"):
		done = main.kill_count - _kill_mark >= int(s["until_kills"])
	if done:
		if s.get("clear_wp", false):
			_remove_waypoints()
		prompt = ""
		prompt_keys = ""
		_advance()

func _wp_pos() -> Vector3:
	for i in range(main.objects.size() - 1, -1, -1):
		if main.objects[i].get("waypoint", false):
			var o: Dictionary = main.objects[i]
			return Vector3(o["x"], o["y"], o["z"])
	return Vector3(INF, INF, INF)


# --- Act 0 Mission 10: Clay's tutorial run to Lucrecia's Base ---------------
# Authored from the disassembled iact0mission10 bytecode
# (data/pogdis/iact0mission10.pogasm): waypoint-select lesson with decoy
# blips and ihud.SetPrompt key hints, formate -> approach -> disengage
# autopilot lessons, dock/undock at the Abandoned Hulk, starmap leg to
# Griffon, the Effrit, then the marked chain to Lucrecia's Base.

static func act0_m10() -> Array:
	return [
		{"music": "ambient"},
		{"say": "a0_m10_dialogue_clay_i_know", "until_comms": true},
		{"say": "a0_m10_dialogue_clay_before_we", "until_comms": true},
		# contact-list lesson: Clay drops a waypoint among decoy blips and
		# the player must select it themselves (bytecode: CurrentTarget)
		{"say": "a0_m10_dialogue_clay_contact_list", "until_comms": true},
		{"waypoint": Vector3(2800, 600, -3500), "wp_name": "Clay's Waypoint",
			"auto_target": false, "blips": 5},
		{"say": "a0_m10_dialogue_clay_now_select",
			"prompt": "a0_m10_prompt_select_waypoint", "keys": ", / .",
			"until_target": "Clay's Waypoint"},
		{"obj_add": "a0_m10_objectives_approach_clay", "id": "wp1",
			"prompt": "a0_m10_prompt_fly_towards", "until_near": 800.0,
			"clear_wp": true},
		{"obj_done": "wp1", "say": "a0_m10_dialogue_clay_good",
			"until_comms": true},
		{"say": "a0_m10_dialogue_clay_the_first", "until_comms": true},
		{"say": "a0_m10_dialogue_clay_that_leads", "until_comms": true},
		# formate autopilot lesson (F7) — bytecode order: formate first
		{"say": "a0_m10_dialogue_clay_instructions_formate"},
		{"obj_add": "a0_m10_objectives_formate_lesson", "id": "ap2",
			"prompt": "a0_m10_prompt_activate_formate", "keys": "F7",
			"target": "Abandoned Hulk", "until_ap": 2},
		{"obj_done": "ap2", "say": "a0_m10_dialogue_clay_formate_engage",
			"until_comms": true},
		# approach autopilot lesson (F6)
		{"say": "a0_m10_dialogue_clay_instructions_approach"},
		{"obj_add": "a0_m10_objectives_approach_lesson", "id": "ap1",
			"prompt": "a0_m10_prompt_activate_approach", "keys": "F6",
			"until_ap": 1},
		{"obj_done": "ap1", "say": "a0_m10_dialogue_clay_approach_engage",
			"until_comms": true},
		# disengage (F5)
		{"say": "a0_m10_dialogue_clay_disengage"},
		{"obj_add": "a0_m10_objective_disengage", "id": "ap0",
			"prompt": "a0_m10_prompt_disengage", "keys": "F5", "until_ap": 0},
		{"obj_done": "ap0"},
		# dock/undock lesson at the Abandoned Hulk (F8 / U)
		{"obj_add": "a0_m10_objectives_dock_to", "id": "dock",
			"prompt": "a0_m10_prompt_use_dock", "keys": "F8",
			"target": "Abandoned Hulk", "until_docked": "abandoned"},
		{"obj_done": "dock", "say": "a0_m10_dialogue_clay_undock",
			"until_comms": true},
		{"obj_add": "a0_m10_objectives_undock", "id": "undock",
			"prompt": "a0_m10_prompt_use_undock", "keys": "U",
			"until_undocked": true},
		{"obj_done": "undock"},
		# starmap lesson (screen not built yet: dialogue + straight to leg)
		{"say": "a0_m10_dialogue_clay_starmap", "until_comms": true},
		{"say": "a0_m10_dialogue_clay_this_is", "until_comms": true},
		{"obj_add": "a0_m10_objectives_fly_to", "id": "griffon",
			"prompt": "a0_m10_prompt_use_approach", "keys": "F6"},
		{"waypoint": "Griffon", "offset": Vector3(0, 0, 8.0e6),
			"wp_name": "Griffon Approach", "until_near": 2.0e6,
			"clear_wp": true},
		{"obj_done": "griffon", "say": "a0_m10_dialogue_clay_there_weve",
			"until_comms": true},
		# on to the Effrit
		{"say": "a0_m10_dialogue_clay_ok_this_is", "until_comms": true},
		{"obj_add": "a0_m10_objectives_fly_to_effrit", "id": "effrit",
			"prompt": "a0_m10_prompt_fly_to_effrit", "keys": "F6"},
		{"waypoint": "The Effrit", "wp_name": "The Effrit",
			"until_near": 3.0e5, "clear_wp": true},
		{"obj_done": "effrit", "say": "a0_m10_dialogue_clay_were_here",
			"until_comms": true},
		# waypoint chain through the Effrit to Lucrecia's Base
		{"obj_add": "a0_m10_objectives_follow_waypoints", "id": "base",
			"prompt": "a0_m10_prompt_follow_waypoints"},
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
		# the HUD tour, docked at Lucrecia's
		{"say": "a0_m10_dialogue_clay_first_hud", "until_comms": true},
		{"say": "a0_m10_dialogue_clay_top_right", "until_comms": true},
		{"say": "a0_m10_dialogue_clay_bottom_right", "until_comms": true},
		{"say": "a0_m10_dialogue_clay_top_left", "until_comms": true},
		{"say": "a0_m10_dialogue_clay_under_top_left", "until_comms": true},
	]


# --- Act 0 story beats (iprelude.pogasm StoryElement conversations) ----------

static func _beat(lines: Array) -> Array:
	var out: Array = []
	for l in lines:
		out.append({"say": l[1], "who": l[0], "until_comms": true})
	return out

static func act0_beat_fuel_rods() -> Array:  # story 0.20
	return _beat([
		["young_cal", "a0_master_dialogue_young_cal_its_very_dark_in_here_clay"],
		["clay", "a0_master_dialogue_clay_yeah_i_think_theres_a_power_fault_somewhere"],
		["young_cal", "a0_master_dialogue_young_cal_it_says_fuel_rod_malfunction"],
		["clay", "a0_master_dialogue_clay_sure_is_it_means_we_need_to_find_some_new_rods_from_somewhere_before"],
	])

static func act0_beat_grandma() -> Array:  # Lucrecia mail conversation
	return _beat([
		["young_cal", "a0_master_dialogue_young_cal_so_grandma_was_a_space_pirate"],
		["clay", "a0_master_dialogue_clay_you_gotta_understand_cal_that_your_dad_and_your_grandma"],
		["young_cal", "a0_master_dialogue_young_cal_and_look_where_that_get_him"],
		["clay", "a0_master_dialogue_clay_listen_kid_your_father"],
	])

static func act0_beat_landmarks() -> Array:  # story 0.40, leads to the tour
	return _beat([
		["clay", "a0_master_dialogue_clay_well_your_piloting_skills_arnt_bad_for_a_kid"],
		["young_cal", "a0_master_dialogue_young_cal_does_that_mean_we_can_do_something_other_than_fly_through_rings"],
		["clay", "a0_master_dialogue_clay_dont_get_cocky_kid"],
		["young_cal", "a0_master_dialogue_young_cal_well_ive_never_really_left_the_asteroid_belot_before_i_came_here"],
		["clay", "a0_master_dialogue_clay_well_reacon_its_time_to_introduce_you_to_a_few_of_the_ladmarks"],
	])

static func act0_beat_flitter() -> Array:  # story 0.50
	return _beat([
		["clay", "a0_master_dialogue_clay_ive_looked_into_the_meteor_shielding_problem"],
		["young_cal", "a0_master_dialogue_young_cal_sure_what_do_you_want_me_to_do"],
		["clay", "a0_master_dialogue_clay_we_need_a_flitter_to_reapir_the_shielding"],
		["young_cal", "a0_master_dialogue_young_cal_of_course_i_can_fly_a_ship_you_know"],
		["clay", "a0_master_dialogue_clay_just_you_be_careful"],
	])


# --- Act 0 Mission 20: The Proving Grounds ----------------------------------
# iact0mission20.pogasm: waypoint course at Lucrecia's Base +(24000,0,0),
# 15 rings at authored offsets, response menu before the run

const M20_COURSE := [
	Vector3(0, 0, 2000), Vector3(200, 0, 4400), Vector3(-445, 765, 8520),
	Vector3(-185, -665, 10470), Vector3(1045, -320, 14660),
	Vector3(755, -700, 17340), Vector3(-715, 100, 21530),
	Vector3(-615, 300, 24280), Vector3(375, -300, 26660),
	Vector3(2590, 400, 31890), Vector3(1575, 900, 34990),
	Vector3(545, -25, 37980), Vector3(1055, 0, 39760),
	Vector3(555, 1150, 43590), Vector3(0, 900, 47320),
]

static func act0_m20() -> Array:
	var out: Array = [
		{"say": "a0_m20_dialogue_clay_theres", "until_comms": true},
		{"say": "a0_m20_dialogue_clay_your_gonna", "until_comms": true},
		{"say": "a0_m20_dialogue_clay_im_not", "until_comms": true},
		{"say": "a0_m20_dialogue_clay_im_sure", "until_comms": true},
		{"obj_add": "a0_m20_objectives_complete_course", "id": "course"},
		{"waypoint": "Lucrecia's Base", "offset": Vector3(24000, 0, 0),
			"wp_name": "Training Ground", "until_near": 2000.0,
			"clear_wp": true},
		{"ask": "a0_m20_dialogue_clay_c1_right", "who": "clay", "options": [
			["a0_m20_text_c1_option1_start",
				"a0_m20_dialogue_young_cal_c1_option1_start", ""],
			["a0_m20_text_c1_option2_rules",
				"a0_m20_dialogue_young_cal_c1_option2_rules", ""],
			["a0_m20_text_c1_option3_hi",
				"a0_m20_dialogue_young_cal_c1_option3_hi", ""],
			["a0_m20_text_c1_option4_nothing",
				"a0_m20_dialogue_young_cal_c1_option4_nothing", ""],
		], "until_comms": true},
		{"say": "a0_m20_dialogue_clay_ok_this", "until_comms": true},
		{"say": "a0_m20_dialogue_clay_at_any_time", "until_comms": true},
	]
	for i in M20_COURSE.size():
		var o: Vector3 = M20_COURSE[i]
		out.append({"waypoint": "Lucrecia's Base",
			"offset": Vector3(24000 + o.x, o.y, -o.z),
			"wp_name": "Ring %d" % (i + 1), "until_near": 320.0,
			"clear_wp": true})
	out += [
		{"say": "a0_m20_dialogue_clay_course", "until_comms": true},
		{"obj_done": "course", "say": "a0_m20_dialogue_clay_well_done",
			"until_comms": true},
		{"say": "a0_m20_dialogue_clay_enabled", "until_comms": true},
		{"say": "a0_m20_dialogue_clay_congrats", "until_comms": true},
	]
	return out


# --- Act 0 Tour of Hoffer's Wake (m35) ---------------------------------------
# iact0missiontour.pogasm: fly to Touchdown Orbital, Stepson convoy,
# bully ambush, Wolfgang's rescue

static func act0_tour() -> Array:
	return [
		{"say": "a0_m35_dialogue_clay_right_well", "until_comms": true},
		{"obj_add": "a0_m35_objectives_fly_to", "id": "tour"},
		{"npcs": [
			{"name": "Stepson Tug 1", "faction": "STPSN", "type": "TUG",
				"at": Vector3(2000, 300, -6000), "route": []},
			{"name": "Stepson Puffin", "faction": "STPSN", "type": "UTIL",
				"at": Vector3(2300, 250, -6400), "route": []},
			{"name": "Stepson Tug 2", "faction": "STPSN", "type": "TUG",
				"at": Vector3(1700, 350, -6400), "route": []},
		]},
		{"waypoint": "Touchdown Orbital Transfer Station",
			"offset": Vector3(0, 2000, -4000), "wp_name": "Tour Marker",
			"until_near": 1200.0, "clear_wp": true},
		{"say": "a0_m35_dialogue_clay_here_we", "until_comms": true},
		{"say": "a0_m35_dialogue_stepson_ah_judging", "who": "stepson",
			"until_comms": true},
		{"say": "a0_m35_dialogue_young_cal_uh_yeah", "until_comms": true},
		{"say": "a0_m35_dialogue_stepson_well_in", "who": "stepson",
			"until_comms": true},
		{"say": "a0_m35_dialogue_clay_hmm_they", "until_comms": true},
		# the bullies jump the player
		{"say": "a0_m35_dialogue_bullies_what_do", "who": "bullies"},
		{"hostiles": [
			{"name": "Bully Cutter", "at": Vector3(2600, 200, -2000)},
			{"name": "Bully Corvette", "at": Vector3(-2400, -300, -2400)},
		], "mark_kills": true},
		{"say": "a0_m35_dialogue_clay_guess_i", "until_comms": true},
		{"say": "a0_m35_dialogue_clay_help_1", "until_kills": 1},
		# Wolfgang turns up to even the odds
		{"npcs": [{"name": "Wolfgang's Cutter", "faction": "INDPT",
			"type": "CORVT", "at": Vector3(0, 500, 3000),
			"avatar": "data/avatars/avatars/cutter/setup.gltf", "route": []}]},
		{"say": "a0_m35_dialogue_clay_hey_there", "until_comms": true},
		{"say": "a0_m35_dialogue_wolfgang_looks_like", "who": "wolfgang",
			"until_kills": 2},
		{"despawn_hostiles": true, "obj_done": "tour",
			"say": "a0_m35_dialogue_wolfgang_guess_youve", "who": "wolfgang",
			"until_comms": true},
	]


# --- Act 0 Mission 40: Errand Boy --------------------------------------------
# iact0mission40.pogasm: Wolfgang at Charlesworth Freight, choice menus,
# meet the Princeton, deliver, puffin ambush, return

static func act0_m40() -> Array:
	return [
		{"say": "a0_m35_dialogue_clay_hm_i", "until_comms": true},
		{"obj_add": "a0_m40_objectives_visit", "id": "visit"},
		{"waypoint": "Charlesworth Freight Service Depot",
			"wp_name": "Charlesworth Depot", "until_near": 6000.0,
			"clear_wp": true},
		{"until_docked": "charlesworth"},
		{"obj_done": "visit", "say": "a0_m40_dialogue_wolfgang_ah_cal",
			"who": "wolfgang", "until_comms": true},
		{"ask": "a0_m40_dialogue_wolfgang_c1_so_what", "who": "wolfgang",
			"options": [
			["a0_m40_text_c1_option1_charlesworth",
				"a0_m40_dialogue_cal_c1_option1_charleswoth",
				"a0_m40_dialogue_wolfgang_c1_response1_in_this"],
			["a0_m40_text_c1_option2_business",
				"a0_m40_dialogue_cal_c1_option2_business",
				"a0_m40_dialogue_wolfgang_c1_response2_well_you"],
			["a0_m40_text_c1_option3_job",
				"a0_m40_dialogue_cal_c1_option3_job",
				"a0_m40_dialogue_wolfgang_c1_response3_ah_yes"],
			["a0_m40_text_c1_option4_nothing",
				"a0_m40_dialogue_cal_c1_option4_nothing", ""],
		], "until_comms": true},
		{"ask": "a0_m40_dialogue_wolfgang_c2_interested", "who": "wolfgang",
			"options": [
			["a0_m40_text_c2_option1_yes",
				"a0_m40_dialogue_cal_c2_option1_yes",
				"a0_m40_dialogue_wolfgang_c2_response1_this_is"],
			["a0_m40_text_c2_option2_no",
				"a0_m40_dialogue_cal_c2_option2_no",
				"a0_m40_dialogue_wolfgang_ok_come"],
		], "until_comms": true},
		{"obj_add": "a0_m40_objectives_meet_freight", "id": "meet"},
		{"say": "a0_m40_dialogue_wolfgang_ok_come", "who": "wolfgang",
			"until_undocked": true},
		{"npcs": [{"name": "Princeton", "faction": "INDPT", "type": "TRANS",
			"at": Vector3(1000, 0, -8300),
			"avatar": "data/avatars/avatars/freighter/setup.gltf",
			"route": []}]},
		{"waypoint": Vector3(1000, 0, -8300), "wp_name": "Rendezvous",
			"until_near": 900.0, "clear_wp": true},
		{"obj_done": "meet", "say": "a0_m40_dialogue_princeton_this_is",
			"who": "princeton", "until_comms": true},
		{"obj_add": "a0_m40_objectives_deliver_package", "id": "deliver",
			"say": "a0_m40_dialogue_princeton_right_guess", "who": "princeton",
			"wait": 4.0},
		{"obj_done": "deliver"},
		# the ambush
		{"say": "a0_m40_dialogue_clay_wooa",
			"hostiles": [
			{"name": "Armed Puffin 1", "at": Vector3(3000, 400, -1500)},
			{"name": "Armed Puffin 2", "at": Vector3(-2800, -200, -1800)},
		], "mark_kills": true, "until_kills": 2},
		{"despawn_hostiles": true, "say": "a0_m40_dialogue_clay_damn",
			"until_comms": true},
		{"obj_add": "a0_m40_objectives_return", "id": "return"},
		{"waypoint": "Charlesworth Freight Service Depot",
			"wp_name": "Charlesworth Depot", "until_near": 6000.0,
			"clear_wp": true},
		{"until_docked": "charlesworth"},
		{"obj_done": "return", "say": "a0_m40_dialogue_wolfgang_congrats1",
			"who": "wolfgang", "until_comms": true},
		{"say": "a0_m40_dialogue_wolfgang_congrats2", "who": "wolfgang",
			"until_comms": true},
		{"until_undocked": true},
	]


# --- Act 0 Mission 50: stealing the reactor ----------------------------------
# iact0mission50.pogasm: scout the Junkyard, sneak past the sentries,
# grab the reactor, the Junkers object, run for Lucrecia's

static func act0_m50() -> Array:
	return [
		{"say": "a0_master_dialogue_clay_hey_maybe", "until_comms": true},
		{"say": "a0_m50_dialogue_clay_ok_i_think", "until_comms": true},
		{"obj_add": "a0_m50_objectives_scout", "id": "scout"},
		{"waypoint": "Junkyard", "wp_name": "The Junkyard",
			"until_near": 14000.0, "clear_wp": true},
		{"obj_done": "scout", "say": "a0_m50_dialogue_clay_yep_thisll",
			"until_comms": true},
		{"obj_add": "a0_m50_objectives_sneak", "id": "sneak"},
		# the reactor sits at Junkyard +(500,0,1000) per the JunkyardHandler
		{"waypoint": "Junkyard", "offset": Vector3(500, 0, -1000),
			"wp_name": "Reactor", "until_near": 700.0, "clear_wp": true},
		{"obj_done": "sneak", "say": "a0_m50_dialogue_clay_good_work",
			"until_comms": true},
		{"say": "a0_m50_dialogue_clay_ok_lets", "until_comms": true},
		# the Junkers notice
		{"say": "a0_m50_dialogue_junkers_intruder", "who": "junkers"},
		{"hostiles": [
			{"name": "Junker Tug", "faction": "JUNKS",
				"at": Vector3(4000, 500, -3000)},
			{"name": "Junker Puffin", "faction": "JUNKS",
				"at": Vector3(-3600, -400, -3400)},
		]},
		{"say": "a0_m50_dialogue_clay_watch_out", "until_comms": true},
		{"obj_add": "a0_m50_objectives_return", "id": "return",
			"say": "a0_m50_dialogue_clay_run_for"},
		{"until_docked": "lucrecia"},
		{"despawn_hostiles": true, "obj_done": "return",
			"say": "a0_m50_dialogue_clay_well_done", "until_comms": true},
		{"until_undocked": true},
	]


# --- Act 0 Mission 60: Nemesis ------------------------------------------------
# iact0mission60.pogasm: recover pods at the Gap, Caleb Deacon arrives
# (choice menu), the police break it up, midtro

static func act0_m60() -> Array:
	return [
		{"say": "a0_m60_dialogue_clay_ok_kid", "until_comms": true},
		{"obj_add": "a0_m60_objectives_recover", "id": "recover"},
		{"waypoint": "Hoffer's Gap", "offset": Vector3(9000, 0, 0),
			"wp_name": "Cargo Pods", "until_near": 1000.0, "clear_wp": true},
		{"say": "a0_m60_dialogue_young_cal_right_ill", "wait": 6.0},
		{"obj_done": "recover"},
		# Caleb Deacon's ambush
		{"hostiles": [
			{"name": "MAAS Cutter", "faction": "MAAS",
				"at": Vector3(0, 800, -7000)},
			{"name": "The Eye", "faction": "MAAS",
				"at": Vector3(900, 700, -7200)},
			{"name": "Bruiser", "faction": "MAAS",
				"at": Vector3(-900, 700, -7200)},
		], "mark_kills": true},
		{"say": "a0_m60_dialogue_caleb_i_think", "who": "caleb",
			"until_comms": true},
		{"say": "a0_m60_dialogue_young_cal_you_killed", "until_comms": true},
		{"say": "a0_m60_dialogue_caleb_ah_the", "who": "caleb",
			"until_comms": true},
		{"ask": "a0_m60_dialogue_caleb_c1_any", "who": "caleb", "options": [
			["a0_m60_text_c1_option1_who",
				"a0_m60_dialogue_player_c1_option1_who",
				"a0_m60_dialogue_caleb_c1_response1_im_caleb"],
			["a0_m60_text_c1_option2_why",
				"a0_m60_dialogue_player_c1_option2_why",
				"a0_m60_dialogue_caleb_c1_respose2_ah_yes"],
			["a0_m60_text_c1_option3_kill",
				"a0_m60_dialogue_player_c1_option3_kill", ""],
		], "until_comms": true},
		{"say": "a0_m60_dialogue_caleb_this_conversation", "who": "caleb",
			"wait": 12.0},
		# the police arrive and Caleb withdraws
		{"npcs": [
			{"name": "Police Interceptor 1", "faction": "LAW", "type": "INTER",
				"at": Vector3(0, -1500, 5000),
				"avatar": "data/avatars/avatars/cutter/setup.gltf", "route": []},
			{"name": "Police Interceptor 2", "faction": "LAW", "type": "INTER",
				"at": Vector3(1200, -1400, 5200),
				"avatar": "data/avatars/avatars/cutter/setup.gltf", "route": []},
		]},
		{"say": "a0_m60_dialogue_police_ah_what", "who": "police",
			"until_comms": true},
		{"say": "a0_m60_dialogue_caleb_yes_i", "who": "caleb",
			"until_comms": true},
		{"say": "a0_m60_dialogue_police_i_see", "who": "police",
			"until_comms": true},
		{"despawn_hostiles": true, "wait": 3.0},
		{"movie": "midtro"},
	]


# --- the whole prelude, stitched per iprelude.pogasm's master script ---------

static func act0() -> Array:
	return act0_m10() + act0_beat_fuel_rods() + act0_m20() \
		+ act0_beat_grandma() + act0_beat_landmarks() + act0_tour() \
		+ act0_m40() + act0_beat_flitter() + act0_m50() + act0_m60()
