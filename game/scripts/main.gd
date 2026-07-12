extends Node3D
# Hoffer's Wake, navigable end to end.
#
# World model: every map object keeps its position in the SYSTEM frame as
# 64-bit floats (GDScript floats are doubles; Vector3 is single precision).
# The player ship is glued to the scene origin: each frame its local motion
# is folded into the 64-bit system position and the node snapped back to
# zero, so nearby geometry always renders in high precision. Objects within
# streaming range are instantiated at (object - player).
#
# LDS uses the real drive constants (player Class 1: 3e10 m/s max, ramp
# factor 5/s, 3 s spool). LDSI: proximity to any map object forces dropout.

const DATA_SYSTEM := "data/json/systems/hoffers_wake.json"
const START_NAME := "Alexander L-Point"
const STREAM_IN := 4.0e5
const STREAM_OUT := 5.0e5
const LDSI_RADIUS := 2.5e4  # stations inhibit LDS within 25 km

const LDS_MAX := 3.0e10
const LDS_RAMP := 5.0
const LDS_SPOOL := 3.0
const LDS_BASE := 2000.0

const STATION_AVATARS := [
	"avatars/haven_station/setup.gltf",
	"avatars/policestation/setup.gltf",
	"avatars/lor_platform/setup.gltf",
]

var ship: ShipFlight
var cam: Camera3D
var hud: Label
var bracket: Control
var demo := false
var demo_t := 0.0
var demo_phase := 0

var px := 0.0
var py := 0.0
var pz := 0.0
var objects: Array = []  # {name, kind, x, y, z, node}
var target_idx := -1
var lds_state := 0  # 0 off, 1 spooling, 2 running
var lds_timer := 0.0
var lds_speed := 0.0

func _ready() -> void:
	demo = "--demo" in OS.get_cmdline_user_args()
	_build_environment()
	_load_system()
	_spawn_player()
	_build_hud()
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
	return doc.generate_scene(state)

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
	var start := Vector3.ZERO
	var i := 0
	for o in sys["objects"]:
		if o["index"] <= 1:
			continue  # system root + primary star
		var rec := {
			"name": str(o["name"]), "kind": int(o["kind"]),
			"x": float(o["pos"][0]), "y": float(o["pos"][1]),
			"z": -float(o["pos"][2]),  # LW->glTF handedness
			"node": null, "avatar": STATION_AVATARS[i % STATION_AVATARS.size()],
		}
		objects.append(rec)
		i += 1
		if rec["name"] == START_NAME:
			px = rec["x"] + 2500.0
			py = rec["y"] + 300.0
			pz = rec["z"] + 3000.0
	print("system objects: ", objects.size())

func _spawn_player() -> void:
	ship = ShipFlight.new()
	ship.name = "Player"
	var stats: Array = _load_json("data/json/ships.json")
	for rec in stats:
		if rec.get("path", "") == "sims/ships/player/tug.ini":
			ship.load_stats(rec["properties"])
			break
	ship.add_child(_load_gltf("data/avatars/avatars/tug_hull/setup_prefitted.gltf"))
	add_child(ship)
	cam = Camera3D.new()
	cam.far = 6.0e5
	cam.fov = 70
	add_child(cam)
	cam.make_current()

func _build_hud() -> void:
	var cl := CanvasLayer.new()
	hud = Label.new()
	hud.position = Vector2(24, 24)
	hud.add_theme_color_override("font_color", Color(0.55, 0.85, 1.0))
	hud.add_theme_font_size_override("font_size", 18)
	cl.add_child(hud)
	bracket = TargetBracket.new()
	bracket.main = self
	bracket.set_anchors_preset(Control.PRESET_FULL_RECT)
	cl.add_child(bracket)
	add_child(cl)

class TargetBracket extends Control:
	var main: Node3D
	func _process(_d: float) -> void:
		queue_redraw()
	func _draw() -> void:
		if main.target_idx < 0:
			return
		var t: Dictionary = main.objects[main.target_idx]
		var world := Vector3(t["x"] - main.px, t["y"] - main.py, t["z"] - main.pz)
		var c: Camera3D = main.cam
		if c.is_position_behind(world):
			return
		var p := c.unproject_position(world)
		var col := Color(0.5, 0.9, 1.0, 0.9)
		var s := 18.0
		for off in [Vector2(-s, -s), Vector2(s - 8, -s), Vector2(-s, s - 2), Vector2(s - 8, s - 2)]:
			draw_rect(Rect2(p + off, Vector2(8, 2)), col)
			draw_rect(Rect2(p + off, Vector2(2, 8)), col)

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and not demo:
		ship.input_rotate.y = clampf(ship.input_rotate.y - event.relative.x * 0.003, -1, 1)
		ship.input_rotate.x = clampf(ship.input_rotate.x - event.relative.y * 0.003, -1, 1)
	if event is InputEventKey and event.pressed and not event.echo:
		match event.physical_keycode:
			KEY_T:
				_cycle_target()
			KEY_L:
				_toggle_lds()
	if event.is_action_pressed("ui_cancel"):
		get_tree().quit()

func _cycle_target() -> void:
	target_idx = (target_idx + 1) % objects.size()

func _target_distance() -> float:
	if target_idx < 0:
		return INF
	var t: Dictionary = objects[target_idx]
	var dx: float = t["x"] - px
	var dy: float = t["y"] - py
	var dz: float = t["z"] - pz
	return sqrt(dx * dx + dy * dy + dz * dz)

func _nearest_distance() -> float:
	var best := INF
	for o in objects:
		var dx: float = o["x"] - px
		var dy: float = o["y"] - py
		var dz: float = o["z"] - pz
		best = minf(best, dx * dx + dy * dy + dz * dz)
	return sqrt(best)

func _toggle_lds() -> void:
	if lds_state != 0:
		lds_state = 0
		ship.velocity = -ship.global_transform.basis.z * ship.max_speed.z
	elif _nearest_distance() > LDSI_RADIUS * 0.5:
		lds_state = 1
		lds_timer = 0.0
		lds_speed = LDS_BASE

func _physics_process(delta: float) -> void:
	if demo:
		_demo_control(delta)
	else:
		_player_control(delta)
	if lds_state > 0:
		_lds_process(delta)
	_fold_motion()
	_stream_objects()
	_chase_camera(delta)
	_update_hud()

func _player_control(delta: float) -> void:
	ship.throttle = clampf(ship.throttle
		+ (0.4 if Input.is_action_pressed("throttle_up") else 0.0) * delta
		- (0.4 if Input.is_action_pressed("throttle_down") else 0.0) * delta, 0.0, 1.0)
	if Input.is_action_just_pressed("throttle_zero"):
		ship.throttle = 0.0
	if Input.is_action_just_pressed("toggle_assist"):
		ship.assist = not ship.assist
	ship.input_thrust.x = Input.get_axis("thrust_left", "thrust_right")
	ship.input_thrust.y = Input.get_axis("thrust_down", "thrust_up")
	ship.input_rotate.z = Input.get_axis("roll_right", "roll_left")
	ship.input_rotate.x = move_toward(ship.input_rotate.x, 0.0, delta * 1.5)
	ship.input_rotate.y = move_toward(ship.input_rotate.y, 0.0, delta * 1.5)

func _lds_process(delta: float) -> void:
	if lds_state == 1:
		lds_timer += delta
		if lds_timer >= LDS_SPOOL:
			lds_state = 2
		return
	# exponential ramp, capped; brake to converge on the target's LDSI edge
	lds_speed = minf(lds_speed * pow(LDS_RAMP, delta), LDS_MAX)
	var near := _nearest_distance()
	var tdist := _target_distance()
	if (tdist < lds_speed * 1.5 and tdist < INF) or near < LDSI_RADIUS:
		lds_speed = maxf(tdist * 1.5, LDS_BASE)
	lds_speed = minf(lds_speed, LDS_MAX)
	ship.velocity = -ship.global_transform.basis.z * lds_speed
	if near < LDSI_RADIUS or (tdist < 4.0e4 and lds_speed <= LDS_BASE * 2.0):
		lds_state = 0
		ship.velocity = ship.velocity.normalized() * ship.max_speed.z

func _fold_motion() -> void:
	var p := ship.global_position
	px += p.x
	py += p.y
	pz += p.z
	ship.global_position = Vector3.ZERO
	cam.global_position -= p

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
			print("stream in: ", o["name"])
		elif o["node"] != null and d2 > STREAM_OUT * STREAM_OUT:
			o["node"].queue_free()
			o["node"] = null
		if o["node"] != null:
			o["node"].position = Vector3(dx, dy, dz)

func _chase_camera(delta: float) -> void:
	var target := ship.global_transform
	var want := target.translated_local(Vector3(0, 14, 55))
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

func _update_hud() -> void:
	var lds_txt := ""
	match lds_state:
		1: lds_txt = "\nLDS SPOOLING"
		2: lds_txt = "\nLDS %s/s" % _fmt_dist(lds_speed)
	var tgt_txt := ""
	if target_idx >= 0:
		tgt_txt = "\nTGT %s  %s" % [objects[target_idx]["name"], _fmt_dist(_target_distance())]
	hud.text = "SPD %s/s\nSET %6.1f m/s\nTHR %3d%%\n%s%s%s" % [
		_fmt_dist(ship.velocity.length()), ship.throttle * ship.max_speed.z,
		int(ship.throttle * 100), "ASSIST" if ship.assist else "FREE", lds_txt, tgt_txt]

# --- scripted demo: clear the LDSI zone, LDS to another location, arrive ---
func _demo_control(delta: float) -> void:
	demo_t += delta
	if demo_t > 400.0:
		print("DEMO: TIMEOUT")
		get_tree().quit(1)
		return
	match demo_phase:
		0:
			ship.throttle = 1.0
			if _nearest_distance() > LDSI_RADIUS * 1.1:
				# nearest station-kind object beyond 0.5 AU
				var bestd := INF
				for i in objects.size():
					var o: Dictionary = objects[i]
					var d := Vector3(o["x"] - px, o["y"] - py, o["z"] - pz).length()
					if o["kind"] == 1 and d > 0.5 * 1.496e11 and d < bestd:
						bestd = d
						target_idx = i
				print("DEMO: destination ", objects[target_idx]["name"], " at ",
					_fmt_dist(bestd))
				demo_phase = 1
		1:
			_face_target()
			var t: Dictionary = objects[target_idx]
			var dir := Vector3(t["x"] - px, t["y"] - py, t["z"] - pz).normalized()
			if (-ship.global_transform.basis.z).angle_to(dir) < 0.05:
				_toggle_lds()
				print("DEMO: LDS engaged")
				demo_phase = 2
		2:
			_face_target()
			if lds_state == 0:
				print("DEMO: arrived at ", objects[target_idx]["name"],
					", dist=", _fmt_dist(_target_distance()), " t=%.1f" % demo_t)
				demo_phase = 3
				demo_t = 0.0
		3:
			ship.throttle = 0.3
			if demo_t > 2.0:
				var img := get_viewport().get_texture().get_image()
				img.save_png(_base().path_join("data/screenshots/lds_demo.png"))
				print("DEMO: screenshot saved")
				get_tree().quit()
	if int(demo_t) != int(demo_t - delta):
		print("t=%.0f phase=%d spd=%s/s tgt=%s" % [demo_t, demo_phase,
			_fmt_dist(ship.velocity.length()),
			_fmt_dist(_target_distance()) if target_idx >= 0 else "-"])

func _face_target() -> void:
	if target_idx < 0:
		return
	var t: Dictionary = objects[target_idx]
	var dir := Vector3(t["x"] - px, t["y"] - py, t["z"] - pz).normalized()
	var fwd := -ship.global_transform.basis.z
	var axis := fwd.cross(dir)
	if axis.length() > 1e-6:
		ship.global_rotate(axis.normalized(), minf(fwd.angle_to(dir), 0.03))
