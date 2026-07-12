extends Node3D
# The Badlands, playable: flight, LDS, capsule jumps between all systems,
# targeting, weapons, damage, AI traffic + hostiles, docking, dynamic music,
# original SFX, animated stations, planets/stars rendered as impostors.
# See docs/mechanics.md for the IW2 semantics being recreated.

const START_SYSTEM := "hoffers_wake"
const START_NAME := "Alexander L-Point"
const STREAM_IN := 4.0e5
const STREAM_OUT := 5.0e5
const IMPOSTOR_DIST := 2.5e5  # bodies/stars drawn at capped range, scaled down
const LDSI_RADIUS := 2.5e4

const LDS_MAX := 3.0e10
const LDS_RAMP := 5.0
const LDS_SPOOL := 3.0
const LDS_BASE := 2000.0

const DOCK_RANGE := 4000.0
const JUMP_RANGE := 3.0e4  # must be this close to an L-point to capsule jump
const PBC_DAMAGE := 160.0  # sims/weapons/pbc_bolt.ini
const SHIP_HIT_RADIUS := 60.0

const PLANET_TEXTURES := [
	"landwater1", "landwater2", "landwater4", "gas1", "gas2", "gas3", "gas4",
	"stripes1", "stripes2", "stripes3", "stripes4", "stripes5", "stripes6",
]

var ship: ShipFlight
var ship_model: Node3D
var cockpit: Node3D
var cam: Camera3D
var hud: Hud
var menu: Menu
var weapons: PbcWeapons
var audio: AudioManager
var sun: DirectionalLight3D
var view_mode := 0  # 0 cockpit, 1 internal no frame, 2 external chase
var demo := false
var demo_t := 0.0
var demo_phase := 0

var px := 0.0
var py := 0.0
var pz := 0.0
var system_stem := ""
var system_name := ""
var objects: Array = []
var ai_ships: Array = []
var target_idx := -1
var target_ai: AiShip = null
var lds_state := 0
var lds_timer := 0.0
var lds_speed := 0.0
var jump_state := 0  # 0 idle, 1 spool, 2 accel run, 3 capsule space
var jump_timer := 0.0
var jump_dest := ""
var jump_sel := 0
var jump_fade: ColorRect
var hull := 1000.0
var hull_max := 1000.0
var docked_at := ""
var ship_stats: Dictionary = {}

var motioncheck := false
var jumpcheck := false
var uicheck := false

func _ready() -> void:
	demo = "--demo" in OS.get_cmdline_user_args()
	motioncheck = "--motioncheck" in OS.get_cmdline_user_args()
	jumpcheck = "--jumpcheck" in OS.get_cmdline_user_args()
	uicheck = "--uicheck" in OS.get_cmdline_user_args()
	if motioncheck or jumpcheck or uicheck:
		demo = true
	audio = AudioManager.new()
	add_child(audio)
	_build_environment()
	_spawn_player()
	_load_system(START_SYSTEM, START_NAME)
	hud = Hud.new()
	hud.main = self
	var cl := CanvasLayer.new()
	cl.add_child(hud)
	jump_fade = ColorRect.new()
	jump_fade.color = Color(1, 1, 1, 0)
	jump_fade.set_anchors_preset(Control.PRESET_FULL_RECT)
	jump_fade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cl.add_child(jump_fade)
	menu = Menu.new()
	menu.main = self
	cl.add_child(menu)
	add_child(cl)
	audio.music("ambient")
	if uicheck:
		menu.open()
	elif demo:
		menu.visible = false
		menu.launched = true
		view_mode = 2
		_apply_view()
	else:
		menu.open()

func start_in_system(stem: String) -> void:
	lds_state = 0
	jump_state = 0
	_load_system(stem, START_NAME if stem == START_SYSTEM else "")
	ship.velocity = Vector3.ZERO
	ship.throttle = 0.0

func _base() -> String:
	return ProjectSettings.globalize_path("res://").path_join("..")

func _load_json(rel: String) -> Variant:
	var f := FileAccess.open(_base().path_join(rel), FileAccess.READ)
	return null if f == null else JSON.parse_string(f.get_as_text())

func _load_gltf(rel: String) -> Node3D:
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	if doc.append_from_file(_base().path_join(rel), state) != OK:
		return null
	var node := doc.generate_scene(state)
	for ap in node.find_children("*", "AnimationPlayer", true, false):
		var player := ap as AnimationPlayer
		for anim_name in player.get_animation_list():
			player.get_animation(anim_name).loop_mode = Animation.LOOP_LINEAR
			player.play(anim_name)
	return node

func _build_environment() -> void:
	sun = DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-20, 60, 0)
	sun.light_energy = 1.4
	add_child(sun)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	sky.sky_material = _starfield_material()
	e.sky = sky
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.12, 0.13, 0.17)
	e.ambient_light_energy = 0.7
	e.glow_enabled = true
	env.environment = e
	add_child(env)

func _starfield_material() -> ShaderMaterial:
	var m := ShaderMaterial.new()
	var sh := Shader.new()
	sh.code = """
shader_type sky;
float hash(vec3 p) { return fract(sin(dot(p, vec3(127.1, 311.7, 74.7))) * 43758.5453); }
void sky() {
	vec3 d = EYEDIR;
	vec3 cell = floor(d * 220.0);
	float h = hash(cell);
	float star = step(0.997, h);
	vec3 center = (cell + 0.5) / 220.0;
	float falloff = smoothstep(0.0035, 0.0005, distance(normalize(center), d));
	float tw = 0.6 + 0.4 * hash(cell + 1.0);
	COLOR = vec3(0.004, 0.005, 0.01) + star * falloff * tw * vec3(0.9, 0.93, 1.0);
}
"""
	m.shader = sh
	return m

# --- system loading -------------------------------------------------------

func _clear_system() -> void:
	for o in objects:
		if o["node"] != null:
			o["node"].queue_free()
	objects.clear()
	for a in ai_ships:
		a.queue_free()
	ai_ships.clear()
	if weapons != null:
		weapons.clear()
	target_idx = -1
	target_ai = null
	docked_at = ""

func _load_system(stem: String, entry_name := "", from_stem := "") -> void:
	_clear_system()
	system_stem = stem
	var sys: Dictionary = _load_json("data/json/systems/%s.json" % stem)
	system_name = str(sys["objects"][0]["name"])
	var entry := {}
	for o in sys["objects"]:
		var cat := str(o.get("category", "body"))
		if cat == "system":
			continue
		var rec := {
			"name": str(o["name"]), "category": cat,
			"x": float(o["pos"][0]), "y": float(o["pos"][1]),
			"z": -float(o["pos"][2]),
			"radius": float(o.get("radius", 0.0)),
			"avatar": str(o.get("avatar", "")),
			"jumps": o.get("jumps_to_stems", []),
			"colors": o.get("colors", []),
			"node": null,
		}
		objects.append(rec)
		if cat == "body" or cat == "star":
			_spawn_impostor(rec)
		if entry_name != "" and rec["name"] == entry_name:
			entry = rec
	if entry.is_empty():
		# arrive at the L-point that links back to where we came from,
		# else at the system's first L-point
		for o in objects:
			if o["category"] != "lpoint":
				continue
			if entry.is_empty() or from_stem in o["jumps"]:
				entry = o
			if from_stem != "" and from_stem in o["jumps"]:
				break
	if entry.is_empty() and not objects.is_empty():
		entry = objects[0]
	px = entry["x"] + 2500.0
	py = entry["y"] + 300.0
	pz = entry["z"] + 3000.0
	jump_sel = 0
	_spawn_traffic()
	print("SYSTEM: ", system_name, " (", objects.size(), " objects)")

func _planet_material(rec: Dictionary) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	if rec["category"] == "star":
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.albedo_color = Color(1.0, 0.95, 0.8)
		mat.emission_enabled = true
		mat.emission = Color(1.0, 0.9, 0.7)
		mat.emission_energy_multiplier = 8.0
		return mat
	var pick: String = PLANET_TEXTURES[abs(str(rec["name"]).hash()) % PLANET_TEXTURES.size()]
	var path := _base().path_join("data/textures/images/planets/%s.png" % pick)
	if FileAccess.file_exists(path):
		var img := Image.load_from_file(path)
		if img != null:
			mat.albedo_texture = ImageTexture.create_from_image(img)
	# tint the luminance texture with the body's map palette
	var colors: Array = rec.get("colors", [])
	if not colors.is_empty():
		var c: Array = colors[0]
		mat.albedo_color = Color(
			clampf(c[0] / 255.0 * 1.5, 0.0, 1.0),
			clampf(c[1] / 255.0 * 1.5, 0.0, 1.0),
			clampf(c[2] / 255.0 * 1.5, 0.0, 1.0))
	mat.roughness = 0.9
	return mat

func _spawn_impostor(rec: Dictionary) -> void:
	var mesh := SphereMesh.new()
	mesh.radius = 1.0
	mesh.height = 2.0
	mesh.radial_segments = 48
	mesh.rings = 24
	mesh.material = _planet_material(rec)
	var node := MeshInstance3D.new()
	node.mesh = mesh
	add_child(node)
	rec["node"] = node

func _spawn_beacon(rec: Dictionary) -> Node3D:
	var mesh := SphereMesh.new()
	mesh.radius = 30.0
	mesh.height = 60.0
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(0.5, 0.9, 1.0)
	mat.emission_enabled = true
	mat.emission = Color(0.4, 0.8, 1.0)
	mat.emission_energy_multiplier = 3.0
	mesh.material = mat
	var node := MeshInstance3D.new()
	node.mesh = mesh
	add_child(node)
	return node

func _spawn_player() -> void:
	ship = ShipFlight.new()
	ship.name = "Player"
	var stats: Array = _load_json("data/json/ships.json")
	for rec in stats:
		if rec.get("path", "") == "sims/ships/player/tug.ini":
			ship_stats = rec["properties"]
			ship.load_stats(ship_stats)
			hull_max = float(ship_stats.get("hit_points", 1000))
			hull = hull_max
			break
	ship_model = _load_gltf("data/avatars/avatars/tug_hull/setup_prefitted.gltf")
	ship.add_child(ship_model)
	add_child(ship)
	weapons = PbcWeapons.new()
	weapons.ship = ship
	weapons.main = self
	add_child(weapons)
	cam = Camera3D.new()
	cam.far = 6.0e5
	cam.fov = 70
	add_child(cam)
	cam.make_current()
	# the original's cockpit frame, removable like the old UI option (V key)
	cockpit = _load_gltf("data/avatars/avatars/cockpit/setup.gltf")
	if cockpit != null:
		cam.add_child(cockpit)
	_apply_view()

func _apply_view() -> void:
	if cockpit != null:
		cockpit.visible = view_mode == 0
	if ship_model != null:
		ship_model.visible = view_mode == 2

func _cycle_view() -> void:
	view_mode = (view_mode + 1) % 3
	audio.play("audio/gui/camera_change.wav", -10.0)
	_apply_view()

func _spawn_traffic() -> void:
	# a couple of utility ships patrolling the start cluster
	var local: Array = []
	for o in objects:
		if o["category"] != "station":
			continue
		var d := Vector3(o["x"] - px, o["y"] - py, o["z"] - pz)
		if d.length() < 1.0e5:
			local.append(d)
	if local.size() < 2:
		return
	for i in 2:
		var ai := AiShip.new()
		ai.main = self
		ai.name = "Freighter %d" % (i + 1)
		ai.setup({"hit_points": 800, "speed": [100, 100, 300],
				"acceleration": [40, 40, 60], "yaw_rate": 20, "pitch_rate": 20,
				"roll_rate": 20})
		ai.add_child(_load_gltf("data/avatars/avatars/freighter/setup.gltf"))
		ai.position = Vector3(local[0]) + Vector3(1500 + i * 900, i * 400, -2000)
		for w in local:
			ai.waypoints.append(Vector3(w))
		ai.wp = i % local.size()
		add_child(ai)
		ai_ships.append(ai)

func spawn_hostile(at: Vector3) -> AiShip:
	var ai := AiShip.new()
	ai.main = self
	ai.name = "Marauder Cutter"
	ai.setup({"hit_points": 600, "speed": [150, 150, 600],
			"acceleration": [80, 80, 120], "yaw_rate": 45, "pitch_rate": 45,
			"roll_rate": 45})
	ai.behavior = "attack"
	var model := _load_gltf("data/avatars/avatars/cutter/setup.gltf")
	if model == null:
		model = _load_gltf("data/avatars/avatars/gangstership/setup.gltf")
	ai.add_child(model)
	ai.position = at
	add_child(ai)
	ai_ships.append(ai)
	audio.music("action")
	hud.warn("HOSTILE CONTACT", 3.0)
	audio.play("audio/hud/klaxon.wav", -6.0)
	return ai

func spawn_bolt(shooter: Node3D, dir: Vector3) -> void:
	weapons.spawn(shooter, dir)
	audio.play("audio/sfx/light_pbc.wav", -8.0)

func on_bolt_hit(target: Node3D, pos: Vector3) -> void:
	audio.play("audio/sfx/impact.wav", -6.0)
	_flash(pos, 8.0)
	if target == ship:
		hull -= PBC_DAMAGE
		hud.warn("HULL HIT  %d%%" % int(100.0 * hull / hull_max))
		if hull <= 0.0:
			hud.warn("SHIP DESTROYED — resetting", 5.0)
			hull = hull_max
			ship.velocity = Vector3.ZERO
		return
	var ai := target as AiShip
	if ai != null and ai.damage(PBC_DAMAGE):
		_flash(ai.global_position, 40.0)
		audio.play("audio/sfx/large_explosion_1.wav", -2.0)
		hud.warn("%s DESTROYED" % str(ai.name).to_upper())
		ai_ships.erase(ai)
		if target_ai == ai:
			target_ai = null
		ai.queue_free()
		if not _hostiles_alive():
			audio.music("ambient")

func _hostiles_alive() -> bool:
	for a in ai_ships:
		if a.behavior == "attack":
			return true
	return false

func _flash(pos: Vector3, size: float) -> void:
	var mesh := SphereMesh.new()
	mesh.radius = size
	mesh.height = size * 2
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(1.0, 0.85, 0.5)
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.7, 0.3)
	mat.emission_energy_multiplier = 4.0
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mesh.material = mat
	var node := MeshInstance3D.new()
	node.mesh = mesh
	add_child(node)
	node.global_position = pos
	var tw := create_tween()
	tw.tween_property(node, "scale", Vector3.ONE * 3.0, 0.5)
	tw.parallel().tween_property(mat, "albedo_color:a", 0.0, 0.5)
	tw.tween_callback(node.queue_free)

func contact_list() -> Array:
	var list: Array = []
	for i in objects.size():
		var o: Dictionary = objects[i]
		var d := Vector3(o["x"] - px, o["y"] - py, o["z"] - pz).length()
		var show := false
		match o["category"]:
			"station":
				show = d < 5.0e5
			"lpoint":
				show = d < 1.0e7
		if show:
			list.append({"name": o["name"], "dist": d, "hostile": false,
					"targeted": i == target_idx})
	for a in ai_ships:
		list.append({"name": a.name, "dist": a.global_position.length(),
				"hostile": a.behavior == "attack", "targeted": a == target_ai})
	list.sort_custom(func(x, y): return x["dist"] < y["dist"])
	return list.slice(0, 12)

func _unhandled_input(event: InputEvent) -> void:
	if menu != null and menu.visible:
		menu.handle(event)
		return
	if event is InputEventMouseMotion and not demo and docked_at == "":
		ship.input_rotate.y = clampf(ship.input_rotate.y - event.relative.x * 0.003, -1, 1)
		ship.input_rotate.x = clampf(ship.input_rotate.x - event.relative.y * 0.003, -1, 1)
	if event is InputEventKey and event.pressed and not event.echo:
		match event.physical_keycode:
			KEY_T:
				_cycle_target()
			KEY_L:
				_toggle_lds()
			KEY_D:
				_try_dock()
			KEY_U:
				_undock()
			KEY_J:
				_try_jump()
			KEY_K:
				_cycle_route()
			KEY_V:
				_cycle_view()
			KEY_H:
				spawn_hostile(ship.global_position +
					-ship.global_transform.basis.z * 3000.0 + Vector3(400, 200, 0))
	if event.is_action_pressed("ui_cancel") and not demo:
		menu.open()

func _cycle_target() -> void:
	audio.play("audio/hud/target_changed.wav", -10.0)
	# cycle: AI ships first (nearest), then map objects
	if not ai_ships.is_empty():
		var idx := ai_ships.find(target_ai)
		if idx < ai_ships.size() - 1:
			target_ai = ai_ships[idx + 1]
			target_idx = -1
			return
		target_ai = null
	target_idx = (target_idx + 1) % objects.size()
	if objects[target_idx]["category"] == "star":
		target_idx = (target_idx + 1) % objects.size()
	if target_idx == 0 and not ai_ships.is_empty():
		target_ai = ai_ships[0]
		target_idx = -1

func _target_pos() -> Vector3:
	if target_ai != null and is_instance_valid(target_ai):
		return target_ai.global_position
	if target_idx >= 0:
		var t: Dictionary = objects[target_idx]
		return Vector3(t["x"] - px, t["y"] - py, t["z"] - pz)
	return Vector3.INF

func _target_distance() -> float:
	var p := _target_pos()
	return INF if p == Vector3.INF else p.length()

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

func _lds_clearance() -> float:
	# distance to the nearest LDS-inhibition boundary (stations 25 km,
	# bodies scale with their radius — masses inhibit LDS, iRegion.CreateLDSI)
	var clear := INF
	for o in objects:
		var inhibit := 0.0
		match o["category"]:
			"station":
				inhibit = LDSI_RADIUS
			"body":
				inhibit = maxf(LDSI_RADIUS, o["radius"] * 1.5)
			_:
				continue
		var d := Vector3(o["x"] - px, o["y"] - py, o["z"] - pz).length()
		clear = minf(clear, d - inhibit)
	return clear

func _toggle_lds() -> void:
	if docked_at != "" or jump_state != 0:
		return
	if lds_state != 0:
		lds_state = 0
		audio.play("audio/sfx/lds_rampdown.wav", -4.0)
		audio.lds_player.stop()
		ship.velocity = -ship.global_transform.basis.z * ship.max_speed.z
	elif _lds_clearance() > 0.0:
		lds_state = 1
		lds_timer = 0.0
		lds_speed = LDS_BASE
		audio.play("audio/sfx/lds_rampup.wav", -4.0)
	else:
		hud.warn("LDS INHIBITED")
		audio.play("audio/hud/invalid_input.wav", -8.0)

func _try_dock() -> void:
	var near := _nearest("station")
	if near.get("dist", INF) > DOCK_RANGE:
		hud.warn("NO DOCKPORT IN RANGE")
		audio.play("audio/hud/invalid_input.wav", -8.0)
		return
	docked_at = near["name"]
	ship.velocity = Vector3.ZERO
	ship.throttle = 0.0
	audio.play("audio/sfx/dock.wav", -4.0)
	audio.music("ambient")

func _undock() -> void:
	if docked_at == "":
		return
	docked_at = ""
	audio.play("audio/sfx/base_doors_sound.wav", -6.0)
	ship.velocity = -ship.global_transform.basis.z * 50.0

# --- capsule jump ----------------------------------------------------------

func _jump_lpoint() -> Dictionary:
	var lp := _nearest("lpoint", JUMP_RANGE)
	return {} if lp.get("dist", INF) == INF else lp

func routes_text() -> String:
	var lp := _jump_lpoint()
	if lp.is_empty():
		return ""
	var jumps: Array = lp["jumps"]
	if jumps.is_empty():
		return "L-POINT: NO CHARTED ROUTES"
	var parts: PackedStringArray = []
	for i in jumps.size():
		var stem: String = jumps[i]
		parts.append(("[%s]" if i == jump_sel % jumps.size() else "%s")
			% stem.replace("_", " ").to_upper())
	return "CAPSULE ROUTES: " + "  ".join(parts) + "  (J jump, K cycle)"

func _cycle_route() -> void:
	var lp := _jump_lpoint()
	if lp.is_empty() or lp["jumps"].is_empty():
		return
	jump_sel = (jump_sel + 1) % lp["jumps"].size()
	audio.play("audio/hud/target_changed.wav", -10.0)

func _try_jump() -> void:
	if docked_at != "" or jump_state != 0 or lds_state != 0:
		return
	var lp := _jump_lpoint()
	if lp.is_empty():
		hud.warn("NO L-POINT IN RANGE")
		audio.play("audio/hud/invalid_input.wav", -8.0)
		return
	var jumps: Array = lp["jumps"]
	if jumps.is_empty():
		hud.warn("NO CHARTED CAPSULE ROUTES")
		audio.play("audio/hud/invalid_input.wav", -8.0)
		return
	jump_dest = jumps[jump_sel % jumps.size()]
	jump_state = 1
	jump_timer = 0.0
	hud.warn("CAPSULE DRIVE CHARGING", 3.0)
	audio.play("audio/sfx/capsule_jump.wav", -4.0)

func _jump_process(delta: float) -> void:
	jump_timer += delta
	match jump_state:
		1:  # spool
			if jump_timer >= 3.0:
				jump_state = 2
				jump_timer = 0.0
				hud.warn("ACCELERATION RUN", 2.0)
		2:  # acceleration run — iAI.IsCapsuleJumpAccelerating
			ship.velocity += -ship.global_transform.basis.z * 2500.0 * delta
			jump_fade.color.a = clampf(jump_timer / 3.0 - 0.6, 0.0, 1.0) * 2.5
			if jump_timer >= 3.0:
				jump_state = 3
				jump_timer = 0.0
				jump_fade.color.a = 1.0
				audio.play_loop(audio.lds_player,
					"audio/sfx/inside_capsule_space.wav", -6.0)
		3:  # capsule space, then exit at destination
			jump_fade.color.a = clampf(2.0 - jump_timer, 0.0, 1.0)
			if jump_timer >= 2.0:
				var from := system_stem
				audio.lds_player.stop()
				_load_system(jump_dest, "", from)
				ship.velocity = -ship.global_transform.basis.z * 1000.0
				jump_state = 0
				jump_fade.color.a = 0.0
				audio.play("audio/sfx/lds_rampdown.wav", -4.0)
				hud.warn("ARRIVED: %s" % system_name.to_upper(), 4.0)

func _physics_process(delta: float) -> void:
	if demo:
		_demo_control(delta)
	elif docked_at == "" and not menu.visible:
		_player_control(delta)
	if lds_state > 0:
		_lds_process(delta)
	if jump_state > 0:
		_jump_process(delta)
	if docked_at != "":
		ship.velocity = Vector3.ZERO
		ship.throttle = 0.0
	_fold_motion()
	_stream_objects()
	_chase_camera(delta)
	var demand: float = (ship.throttle * ship.max_speed.z -
		ship.forward_speed()) / maxf(ship.max_speed.z, 1.0)
	audio.set_engine_level(absf(demand) + ship.input_thrust.length() * 0.3
		+ ship.throttle * 0.15)

func _player_control(delta: float) -> void:
	ship.throttle = clampf(ship.throttle
		+ (0.4 if Input.is_action_pressed("throttle_up") else 0.0) * delta
		- (0.4 if Input.is_action_pressed("throttle_down") else 0.0) * delta, 0.0, 1.0)
	if Input.is_action_just_pressed("throttle_zero"):
		ship.throttle = 0.0
	if Input.is_action_just_pressed("toggle_assist"):
		ship.assist = not ship.assist
		audio.play("audio/gui/mechanical_confirm.wav", -10.0)
	ship.input_thrust.x = Input.get_axis("thrust_left", "thrust_right")
	ship.input_thrust.y = Input.get_axis("thrust_down", "thrust_up")
	ship.input_rotate.z = Input.get_axis("roll_right", "roll_left")
	ship.input_rotate.x = move_toward(ship.input_rotate.x, 0.0, delta * 1.5)
	ship.input_rotate.y = move_toward(ship.input_rotate.y, 0.0, delta * 1.5)
	if (Input.is_key_pressed(KEY_SPACE)
			or Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)) and lds_state == 0:
		weapons.fire()

func _lds_process(delta: float) -> void:
	if lds_state == 1:
		lds_timer += delta
		if lds_timer >= LDS_SPOOL:
			lds_state = 2
			audio.play_loop(audio.lds_player, "audio/sfx/lds_cruise.wav", -10.0)
		return
	lds_speed = minf(lds_speed * pow(LDS_RAMP, delta), LDS_MAX)
	var clear := _lds_clearance()
	var tdist := _target_distance()
	if (tdist < lds_speed * 1.5 and tdist < INF) or clear < 0.0:
		lds_speed = maxf(tdist * 1.5, LDS_BASE)
	lds_speed = minf(lds_speed, LDS_MAX)
	ship.velocity = -ship.global_transform.basis.z * lds_speed
	if clear < 0.0 or (tdist < 4.0e4 and lds_speed <= LDS_BASE * 2.0):
		lds_state = 0
		audio.lds_player.stop()
		audio.play("audio/sfx/lds_rampdown.wav", -4.0)
		ship.velocity = ship.velocity.normalized() * ship.max_speed.z

func _fold_motion() -> void:
	var p := ship.global_position
	px += p.x
	py += p.y
	pz += p.z
	ship.global_position = Vector3.ZERO
	cam.global_position -= p
	weapons.shift_world(p)
	for a in ai_ships:
		a.global_position -= p

func _stream_objects() -> void:
	for o in objects:
		var dx: float = o["x"] - px
		var dy: float = o["y"] - py
		var dz: float = o["z"] - pz
		var d2 := dx * dx + dy * dy + dz * dz
		match o["category"]:
			"body", "star":
				# always visible: drawn at capped distance, scaled to keep
				# the correct angular size (the camera far plane is 600 km)
				var dist := sqrt(maxf(d2, 1.0))
				var r: float = clampf(o["radius"], 2.0e4, 1.0e9)
				if o["category"] == "star":
					r = maxf(r, 7.0e8)
					sun.look_at_from_position(Vector3.ZERO,
						Vector3(-dx, -dy, -dz).normalized())
				var k := minf(IMPOSTOR_DIST / dist, 1.0)
				# never fill the screen: cap apparent radius vs draw distance
				var draw_r := minf(r * k, IMPOSTOR_DIST * 0.4)
				o["node"].position = Vector3(dx, dy, dz) * k
				o["node"].scale = Vector3.ONE * maxf(draw_r, 1.0)
			"station":
				if o["node"] == null and d2 < STREAM_IN * STREAM_IN:
					var model := _load_gltf("data/avatars/" + o["avatar"])
					if model == null:
						continue
					o["node"] = model
					add_child(model)
				elif o["node"] != null and d2 > STREAM_OUT * STREAM_OUT:
					o["node"].queue_free()
					o["node"] = null
				if o["node"] != null:
					o["node"].position = Vector3(dx, dy, dz)
			"lpoint":
				if o["node"] == null and d2 < STREAM_IN * STREAM_IN:
					o["node"] = _spawn_beacon(o)
				elif o["node"] != null and d2 > STREAM_OUT * STREAM_OUT:
					o["node"].queue_free()
					o["node"] = null
				if o["node"] != null:
					o["node"].position = Vector3(dx, dy, dz)

func _chase_camera(delta: float) -> void:
	var target := ship.global_transform
	if view_mode < 2:
		# internal: rigid at the pilot's eye point
		cam.global_transform = target.translated_local(Vector3(0, 5.0, -14.0))
		return
	var want := target.translated_local(Vector3(0, 32, 130))
	if lds_state == 2 or jump_state >= 2:
		cam.global_transform = want.looking_at(
			target.origin + target.basis * Vector3(0, 6, -30), target.basis.y)
	else:
		cam.global_transform = cam.global_transform.interpolate_with(
			want, 1.0 - exp(-8.0 * delta))
		cam.global_transform = cam.global_transform.looking_at(
			target.origin + target.basis * Vector3(0, 6, -30), target.basis.y)

func _fmt_dist(d: float) -> String:
	if d < 1e4:
		return "%.0f m" % d
	if d < 1e7:
		return "%.1f km" % (d / 1e3)
	if d < 1e10:
		return "%.1f Mm" % (d / 1e6)
	return "%.2f AU" % (d / 1.496e11)

# --- scripted demo: LDS across the system, then a combat encounter ---
var _mc_shot := 0

func _demo_control(delta: float) -> void:
	demo_t += delta
	if uicheck:
		_uicheck_control(delta)
		return
	if jumpcheck:
		_jumpcheck_control(delta)
		return
	if motioncheck:
		# hold position facing the start station; burst-capture frames
		ship.throttle = 0.0
		ship.velocity = Vector3.ZERO
		if target_idx < 0:
			for i in objects.size():
				if objects[i]["name"] == START_NAME:
					target_idx = i
		_face_target()
		if demo_t > 2.0 + _mc_shot * 0.4 and _mc_shot < 8:
			var img := get_viewport().get_texture().get_image()
			img.save_png(_base().path_join("data/screenshots/motion_%d.png" % _mc_shot))
			_mc_shot += 1
		if _mc_shot >= 8:
			print("MOTIONCHECK done")
			get_tree().quit()
		return
	if demo_t > 500.0:
		print("DEMO: TIMEOUT")
		get_tree().quit(1)
		return
	match demo_phase:
		0:
			ship.throttle = 1.0
			if _lds_clearance() > LDSI_RADIUS * 0.1:
				var bestd := INF
				for i in objects.size():
					var o: Dictionary = objects[i]
					if o["category"] != "station":
						continue
					var d := Vector3(o["x"] - px, o["y"] - py, o["z"] - pz).length()
					if d > 0.5 * 1.496e11 and d < bestd:
						bestd = d
						target_idx = i
				print("DEMO: destination ", objects[target_idx]["name"])
				demo_phase = 1
		1:
			_face_target()
			var dir := _target_pos().normalized()
			if (-ship.global_transform.basis.z).angle_to(dir) < 0.05:
				_toggle_lds()
				demo_phase = 2
		2:
			_face_target()
			if lds_state == 0:
				print("DEMO: arrived, dist=", _fmt_dist(_target_distance()))
				var hostile := spawn_hostile(Vector3(2500, 300, -1500))
				target_ai = hostile
				target_idx = -1
				demo_phase = 3
				demo_t = 0.0
		3:
			ship.throttle = 0.4
			_face_target()
			if target_ai != null and is_instance_valid(target_ai):
				var dir := _target_pos().normalized()
				if (-ship.global_transform.basis.z).angle_to(dir) < 0.08:
					weapons.fire()
			if demo_t > 6.0 or target_ai == null:
				var img := get_viewport().get_texture().get_image()
				img.save_png(_base().path_join("data/screenshots/combat_demo.png"))
				print("DEMO: combat shot saved; player hull=", hull,
					" hostiles=", _hostiles_alive(), " contacts=", contact_list().size())
				demo_phase = 4
				demo_t = 0.0
		4:
			if target_ai == null or demo_t > 20.0:
				print("DEMO: done, hostile destroyed=", target_ai == null,
					" player hull=", hull)
				get_tree().quit()
			elif is_instance_valid(target_ai):
				_face_target()
				var dir := _target_pos().normalized()
				if (-ship.global_transform.basis.z).angle_to(dir) < 0.08:
					weapons.fire()

func _uicheck_control(_delta: float) -> void:
	# screenshot the menu, then the cockpit HUD with a target
	match demo_phase:
		0:
			if demo_t > 1.5:
				var img := get_viewport().get_texture().get_image()
				img.save_png(_base().path_join("data/screenshots/ui_menu.png"))
				menu.launched = true
				menu.close()
				view_mode = 0
				_apply_view()
				var hostile := spawn_hostile(Vector3(1200, 150, -2200))
				target_ai = hostile
				demo_phase = 1
				demo_t = 0.0
		1:
			_face_target()
			if demo_t > 2.5:
				var img := get_viewport().get_texture().get_image()
				img.save_png(_base().path_join("data/screenshots/ui_cockpit.png"))
				view_mode = 2
				_apply_view()
				demo_phase = 2
				demo_t = 0.0
		2:
			_face_target()
			if demo_t > 1.0:
				var img := get_viewport().get_texture().get_image()
				img.save_png(_base().path_join("data/screenshots/ui_chase.png"))
				print("UICHECK done")
				get_tree().quit()

func _jumpcheck_control(_delta: float) -> void:
	# validate a capsule jump: start at Alexander L-Point -> route to Coyote
	match demo_phase:
		0:
			if demo_t > 1.0:
				print("JUMPCHECK: from ", system_stem, ", routes: ", routes_text())
				_try_jump()
				if jump_state == 0:
					print("JUMPCHECK: FAILED to initiate")
					get_tree().quit(1)
				demo_phase = 1
		1:
			if jump_state == 0:
				print("JUMPCHECK: now in ", system_stem, " (", system_name, ")")
				demo_phase = 2
				demo_t = 0.0
		2:
			if demo_t > 1.5:
				var img := get_viewport().get_texture().get_image()
				img.save_png(_base().path_join("data/screenshots/jump_arrival.png"))
				var ok := system_stem != START_SYSTEM
				print("JUMPCHECK: ", "PASS" if ok else "FAIL",
					" — arrived in ", system_name,
					", contacts=", contact_list().size())
				get_tree().quit(0 if ok else 1)
	if demo_t > 60.0:
		print("JUMPCHECK: TIMEOUT in state ", jump_state)
		get_tree().quit(1)

func _face_target() -> void:
	# demo autopilot: steer via the flight model, like a real pilot would
	var p := _target_pos()
	if p == Vector3.INF:
		return
	var local := p * ship.global_transform.basis
	var pitch := atan2(local.y, -local.z)
	var yaw := atan2(-local.x, -local.z)
	ship.input_rotate.x = clampf(pitch * 2.0, -1.0, 1.0)
	ship.input_rotate.y = clampf(yaw * 2.0, -1.0, 1.0)
