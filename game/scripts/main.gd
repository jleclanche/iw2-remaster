extends Node3D
# Prototype: fly the tug around the Hoffer's Gap station cluster in
# Hoffer's Wake, built from the decoded .map data and assembled avatars.
#
# JSON doubles are 64-bit in GDScript; we subtract the anchor position
# before building Vector3s so single-precision rendering stays accurate.
# A floating origin keeps coordinates small while flying.

const DATA := "res://../data"
const ANCHOR_NAME := "Alexander L-Point"
const LOCAL_RADIUS := 2.0e5  # include map objects within 200 km of anchor

var ship: ShipFlight
var cam: Camera3D
var hud: Label
var demo := false
var demo_t := 0.0
var mouse_captured := true
var origin_shift_x := 0.0  # accumulated 64-bit floating-origin offset
var origin_shift_y := 0.0
var origin_shift_z := 0.0

# station avatars to cycle through for map objects (type mapping TBD)
const STATION_AVATARS := [
	"avatars/haven_station/setup.gltf",
	"avatars/modularstations/setup_habitat.gltf",
	"avatars/modularstations/setup_trade.gltf",
	"avatars/lor_platform/setup.gltf",
]

func _ready() -> void:
	demo = "--demo" in OS.get_cmdline_user_args()
	_build_environment()
	_build_system()
	_spawn_player()
	_build_hud()
	if not demo:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _base() -> String:
	return ProjectSettings.globalize_path("res://").path_join("..")

func _load_json(rel: String) -> Variant:
	var f := FileAccess.open(_base().path_join(rel), FileAccess.READ)
	if f == null:
		push_error("missing " + rel)
		return null
	return JSON.parse_string(f.get_as_text())

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
	e.glow_bloom = 0.1
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

func _build_system() -> void:
	var sys: Dictionary = _load_json("data/json/systems/hoffers_wake.json")
	if sys == null:
		return
	var objects: Array = sys["objects"]
	var anchor: Dictionary = {}
	for o in objects:
		if o["name"] == ANCHOR_NAME:
			anchor = o
			break
	if anchor.is_empty():
		anchor = objects[0]
	var ax: float = anchor["pos"][0]
	var ay: float = anchor["pos"][1]
	var az: float = anchor["pos"][2]
	var i := 0
	for o in objects:
		var dx: float = o["pos"][0] - ax
		var dy: float = o["pos"][1] - ay
		var dz: float = o["pos"][2] - az
		var d2 := dx * dx + dy * dy + dz * dz
		if d2 > LOCAL_RADIUS * LOCAL_RADIUS or o["kind"] != 1:
			continue
		var model := _load_gltf("data/avatars/" + STATION_AVATARS[i % STATION_AVATARS.size()])
		i += 1
		if model == null:
			continue
		# LW +Z forward was flipped to glTF -Z; map coords flip z the same way
		model.position = Vector3(dx, dy, -dz)
		model.name = str(o["name"])
		add_child(model)
	print("placed ", i, " stations near ", anchor["name"])

func _spawn_player() -> void:
	ship = ShipFlight.new()
	ship.name = "Player"
	var stats: Array = _load_json("data/json/ships.json")
	for rec in stats:
		if rec.get("path", "") == "sims/ships/player/tug.ini":
			ship.load_stats(rec["properties"])
			break
	var model := _load_gltf("data/avatars/avatars/tug_hull/setup_prefitted.gltf")
	ship.add_child(model)
	ship.position = Vector3(400, 120, 2500)
	ship.look_at_from_position(ship.position, Vector3.ZERO, Vector3.UP)
	add_child(ship)

	cam = Camera3D.new()
	cam.far = 4.0e5
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
	add_child(cl)

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and mouse_captured and not demo:
		ship.input_rotate.y = clampf(ship.input_rotate.y - event.relative.x * 0.003, -1, 1)
		ship.input_rotate.x = clampf(ship.input_rotate.x - event.relative.y * 0.003, -1, 1)
	if event.is_action_pressed("ui_cancel"):
		get_tree().quit()

func _physics_process(delta: float) -> void:
	if demo:
		_demo_control(delta)
	else:
		_player_control(delta)
	_chase_camera(delta)
	_floating_origin()
	_update_hud()

func _player_control(_delta: float) -> void:
	ship.throttle = clampf(ship.throttle
		+ (0.4 if Input.is_action_pressed("throttle_up") else 0.0) * _delta
		- (0.4 if Input.is_action_pressed("throttle_down") else 0.0) * _delta, 0.0, 1.0)
	if Input.is_action_just_pressed("throttle_zero"):
		ship.throttle = 0.0
	if Input.is_action_just_pressed("toggle_assist"):
		ship.assist = not ship.assist
	ship.input_thrust.x = Input.get_axis("thrust_left", "thrust_right")
	ship.input_thrust.y = Input.get_axis("thrust_down", "thrust_up")
	ship.input_rotate.z = Input.get_axis("roll_right", "roll_left")
	# mouse steering decays toward center for IW2-like handling
	ship.input_rotate.x = move_toward(ship.input_rotate.x, 0.0, _delta * 1.5)
	ship.input_rotate.y = move_toward(ship.input_rotate.y, 0.0, _delta * 1.5)

func _demo_control(delta: float) -> void:
	demo_t += delta
	if demo_t < 6.0:
		ship.throttle = 1.0
	elif demo_t < 9.0:
		ship.input_rotate.y = 0.6
	elif demo_t < 12.0:
		ship.input_rotate.y = 0.0
	else:
		print("DEMO speed=", ship.speed(), " fwd=", ship.forward_speed(),
			" pos=", ship.global_position)
		var img := get_viewport().get_texture().get_image()
		img.save_png(_base().path_join("data/screenshots/demo.png"))
		get_tree().quit()
	if int(demo_t * 2.0) != int((demo_t - delta) * 2.0):
		print("t=%.1f throttle=%.2f speed=%.1f" % [demo_t, ship.throttle, ship.speed()])

func _chase_camera(delta: float) -> void:
	var target := ship.global_transform
	var want := target.translated_local(Vector3(0, 14, 55))
	cam.global_transform = cam.global_transform.interpolate_with(want, 1.0 - exp(-8.0 * delta))
	cam.global_transform = cam.global_transform.looking_at(
		target.origin + target.basis * Vector3(0, 6, -30), target.basis.y)

func _floating_origin() -> void:
	var p := ship.global_position
	if p.length() < 20000.0:
		return
	origin_shift_x += p.x
	origin_shift_y += p.y
	origin_shift_z += p.z
	for child in get_children():
		if child is Node3D:
			(child as Node3D).global_position -= p
	cam.global_position -= p

func _update_hud() -> void:
	hud.text = "SPD %6.1f m/s\nSET %6.1f m/s\nTHR %3d%%\n%s" % [
		ship.speed(), ship.throttle * ship.max_speed.z, int(ship.throttle * 100),
		"ASSIST" if ship.assist else "FREE"]
