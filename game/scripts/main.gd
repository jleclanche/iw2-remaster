extends Node3D
# Hoffer's Wake, playable: flight, LDS, targeting, weapons, damage, AI
# traffic + hostiles, docking, dynamic music, original SFX, animated
# stations. See docs/mechanics.md for the IW2 semantics being recreated.

const DATA_SYSTEM := "data/json/systems/hoffers_wake.json"
const START_NAME := "Alexander L-Point"
const STREAM_IN := 4.0e5
const STREAM_OUT := 5.0e5
const LDSI_RADIUS := 2.5e4

const LDS_MAX := 3.0e10
const LDS_RAMP := 5.0
const LDS_SPOOL := 3.0
const LDS_BASE := 2000.0

const DOCK_RANGE := 4000.0
const PBC_DAMAGE := 160.0  # sims/weapons/pbc_bolt.ini
const SHIP_HIT_RADIUS := 60.0

const STATION_AVATARS := [
	"avatars/haven_station/setup.gltf",
	"avatars/policestation/setup.gltf",
	"avatars/lor_platform/setup.gltf",
]

var ship: ShipFlight
var cam: Camera3D
var hud: Hud
var weapons: PbcWeapons
var audio: AudioManager
var demo := false
var demo_t := 0.0
var demo_phase := 0

var px := 0.0
var py := 0.0
var pz := 0.0
var objects: Array = []
var ai_ships: Array = []
var target_idx := -1
var target_ai: AiShip = null
var lds_state := 0
var lds_timer := 0.0
var lds_speed := 0.0
var hull := 1000.0
var hull_max := 1000.0
var docked_at := ""
var ship_stats: Dictionary = {}

var motioncheck := false

func _ready() -> void:
	demo = "--demo" in OS.get_cmdline_user_args()
	motioncheck = "--motioncheck" in OS.get_cmdline_user_args()
	if motioncheck:
		demo = true
	audio = AudioManager.new()
	add_child(audio)
	_build_environment()
	_load_system()
	_spawn_player()
	_spawn_traffic()
	hud = Hud.new()
	hud.main = self
	var cl := CanvasLayer.new()
	cl.add_child(hud)
	add_child(cl)
	audio.music("ambient")
	if not demo:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

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
	var sun := DirectionalLight3D.new()
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

func _load_system() -> void:
	var sys: Dictionary = _load_json(DATA_SYSTEM)
	var i := 0
	for o in sys["objects"]:
		if o["index"] <= 1:
			continue
		var rec := {
			"name": str(o["name"]), "kind": int(o["kind"]),
			"x": float(o["pos"][0]), "y": float(o["pos"][1]),
			"z": -float(o["pos"][2]),
			"node": null, "avatar": STATION_AVATARS[i % STATION_AVATARS.size()],
		}
		objects.append(rec)
		i += 1
		if rec["name"] == START_NAME:
			px = rec["x"] + 2500.0
			py = rec["y"] + 300.0
			pz = rec["z"] + 3000.0

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
	ship.add_child(_load_gltf("data/avatars/avatars/tug_hull/setup_prefitted.gltf"))
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

func _spawn_traffic() -> void:
	# a couple of utility ships patrolling the start cluster
	var local: Array = []
	for o in objects:
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
		if d < 5.0e5 and o["kind"] == 1:
			list.append({"name": o["name"], "dist": d, "hostile": false,
					"targeted": i == target_idx})
	for a in ai_ships:
		list.append({"name": a.name, "dist": a.global_position.length(),
				"hostile": a.behavior == "attack", "targeted": a == target_ai})
	list.sort_custom(func(x, y): return x["dist"] < y["dist"])
	return list.slice(0, 12)

func _unhandled_input(event: InputEvent) -> void:
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
			KEY_H:
				spawn_hostile(ship.global_position +
					-ship.global_transform.basis.z * 3000.0 + Vector3(400, 200, 0))
	if event.is_action_pressed("ui_cancel"):
		get_tree().quit()

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

func _nearest_object() -> Dictionary:
	var best := {}
	var bestd := INF
	for o in objects:
		var d := Vector3(o["x"] - px, o["y"] - py, o["z"] - pz).length()
		if d < bestd and o["kind"] == 1:
			bestd = d
			best = o
	best["dist"] = bestd
	return best

func _nearest_distance() -> float:
	return _nearest_object().get("dist", INF)

func _toggle_lds() -> void:
	if docked_at != "":
		return
	if lds_state != 0:
		lds_state = 0
		audio.play("audio/sfx/lds_rampdown.wav", -4.0)
		audio.lds_player.stop()
		ship.velocity = -ship.global_transform.basis.z * ship.max_speed.z
	elif _nearest_distance() > LDSI_RADIUS * 0.5:
		lds_state = 1
		lds_timer = 0.0
		lds_speed = LDS_BASE
		audio.play("audio/sfx/lds_rampup.wav", -4.0)
	else:
		hud.warn("LDS INHIBITED")
		audio.play("audio/hud/invalid_input.wav", -8.0)

func _try_dock() -> void:
	var near := _nearest_object()
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

func _physics_process(delta: float) -> void:
	if demo:
		_demo_control(delta)
	elif docked_at == "":
		_player_control(delta)
	if lds_state > 0:
		_lds_process(delta)
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
	var near := _nearest_distance()
	var tdist := _target_distance()
	if (tdist < lds_speed * 1.5 and tdist < INF) or near < LDSI_RADIUS:
		lds_speed = maxf(tdist * 1.5, LDS_BASE)
	lds_speed = minf(lds_speed, LDS_MAX)
	ship.velocity = -ship.global_transform.basis.z * lds_speed
	if near < LDSI_RADIUS or (tdist < 4.0e4 and lds_speed <= LDS_BASE * 2.0):
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
		if o["node"] == null and d2 < STREAM_IN * STREAM_IN and o["kind"] == 1:
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

func _chase_camera(delta: float) -> void:
	var target := ship.global_transform
	var want := target.translated_local(Vector3(0, 32, 130))
	if lds_state == 2:
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
			if _nearest_distance() > LDSI_RADIUS * 1.1:
				var bestd := INF
				for i in objects.size():
					var o: Dictionary = objects[i]
					var d := Vector3(o["x"] - px, o["y"] - py, o["z"] - pz).length()
					if o["kind"] == 1 and d > 0.5 * 1.496e11 and d < bestd:
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
