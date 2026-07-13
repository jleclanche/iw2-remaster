class_name ParticleFx
extends Node3D
# Data-driven player for the original's particle systems. An effect is a
# directory under data/ini/sfx/<name>/ holding node.ini (which names the
# emitter/dynamics/draw INIs), emitter.ini, dynamics.ini and draw.ini.
# See docs/effects.md; the semantics below are read out of flux.dll
# (FcParticleDynamics::Spawn @ 0x10053f80, FcParticleDrawBillBoard::Setup
# @ 0x10050770), not inferred from the data.
#
# The composite effects the game actually fires (explosion, hull_impact,
# ...) are LightWave scenes that instance one or more of these systems;
# ExplosionFx plays those.

# Draw classes we implement. icCornflakeDraw carries no properties at all
# (its property map is the base map, iwar2.dll @ 0x100bc5c0) because it
# hardcodes its own textures: images/sfx/cornflakes + cornflake_masks.
const DRAW_BILLBOARD := "FcParticleDrawBillBoard"
const DRAW_CORNFLAKE := "icCornflakeDraw"
const DRAW_MODEL := "FcParticleDrawModel"

# cornflakes.png / cornflake_masks.png are a 4x4 atlas of torn hull plates.
const CORNFLAKE_CELLS := 4

# NOT recovered. icCornflakeDraw has no size property and we did not find
# its size constant in iwar2.dll, so the flake's intrinsic size is a
# placeholder scaled by the emitter transform like everything else.
const CORNFLAKE_SIZE := 0.09

static var _systems: Dictionary = {}
static var _textures: Dictionary = {}
static var _meshes: Dictionary = {}

var sys: Dictionary = {}
var emitter_scale := 1.0
var emitter_vel := Vector3.ZERO
var _age := 0.0
var _accum := 0.0        # fractional particles owed, FcParticleDynamics+0x48
var _spawned := 0        # total ever spawned, +0x4c (the `once` budget)
var _live: Array = []    # {life, pos, vel, roll, spin, cell}
var _mm: MultiMeshInstance3D
var _models: Array = []  # FcParticleDrawModel: one child per live particle

# --- INI loading ------------------------------------------------------------

static func _read_ini(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var out: Dictionary = {}
	while not f.eof_reached():
		var line := f.get_line().strip_edges()
		var c := line.find(";")
		if c >= 0:
			line = line.substr(0, c).strip_edges()
		if line.is_empty() or line.begins_with("["):
			continue
		var eq := line.find("=")
		if eq < 0:
			continue
		var key := line.substr(0, eq).strip_edges()
		var val := line.substr(eq + 1).strip_edges().trim_prefix("\"").trim_suffix("\"")
		if key.ends_with("[]"):
			key = key.substr(0, key.length() - 2)
			if not out.has(key):
				out[key] = []
			(out[key] as Array).append(val)
		else:
			out[key] = val
	return out

static func _num(props: Dictionary, key: String, dflt: float) -> float:
	if not props.has(key):
		return dflt
	var s := str(props[key])
	return float(s) if s.is_valid_float() else dflt

static func _vec(s: String) -> Vector3:
	var parts := s.trim_prefix("(").trim_suffix(")").split(",")
	if parts.size() < 3:
		return Vector3.ZERO
	return Vector3(float(parts[0].strip_edges()), float(parts[1].strip_edges()),
			float(parts[2].strip_edges()))

# "ini:/sfx/cornflakes/draw" -> data/ini/sfx/cornflakes/draw.ini
static func _ini_path(base: String, url: String) -> String:
	return base.path_join("data/ini").path_join(url.trim_prefix("ini:/") + ".ini")

# "images/sfx/spark" or "texture:/images/sfx/spark" -> the extracted PNG
static func _tex_path(base: String, url: String) -> String:
	var rel := url.trim_prefix("texture:/").trim_prefix("/")
	return base.path_join("data/textures").path_join(rel + ".png")

static func texture(base: String, url: String) -> Texture2D:
	if _textures.has(url):
		return _textures[url]
	var path := _tex_path(base, url)
	var tex: Texture2D = null
	if FileAccess.file_exists(path):
		var img := Image.load_from_file(path)
		if img != null:
			tex = ImageTexture.create_from_image(img)
	_textures[url] = tex
	return tex

# The engine's particle textures carry no alpha and are drawn with blend mode
# 1 and ZWrite off (flux.dll @ 0x1004ffd0), while the colour ramp fades a
# dying particle to (0,0,0) and fade_on_emitter_age fades by scaling the
# colour toward black. Black can only mean "gone" under additive blending, so
# blend mode 1 is additive and the ramp is an emitted intensity, not a tint.
static func additive_material(tex: Texture2D) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	mat.vertex_color_use_as_albedo = true
	mat.albedo_texture = tex
	return mat

# icCornflakeDraw draws hull-plate art, not light: the shipped mask sheet only
# makes sense as a cutout, so these are alpha-blended and pick one of the 16
# atlas cells per particle (carried in the multimesh's custom data).
const CORNFLAKE_SHADER := """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_opaque;
uniform sampler2D sheet : source_color, filter_linear;
varying vec3 cell;
void vertex() {
	cell = INSTANCE_CUSTOM.xyz;
}
void fragment() {
	vec2 uv = UV * cell.z + cell.xy;
	vec4 c = texture(sheet, uv);
	ALBEDO = c.rgb * COLOR.rgb;
	ALPHA = c.a;
}
"""

static func cornflake_material(tex: Texture2D) -> ShaderMaterial:
	var sh := Shader.new()
	sh.code = CORNFLAKE_SHADER
	var mat := ShaderMaterial.new()
	mat.shader = sh
	mat.set_shader_parameter("sheet", tex)
	return mat

static func system(base: String, name: String) -> Dictionary:
	if _systems.has(name):
		return _systems[name]
	var node := _read_ini(base.path_join("data/ini/sfx/%s/node.ini" % name))
	var out: Dictionary = {"name": name, "ok": false}
	if not node.is_empty():
		var emitter := _read_ini(_ini_path(base, str(node.get("emitter", ""))))
		var dyn := _read_ini(_ini_path(base, str(node.get("dynamics", ""))))
		var draw := _read_ini(_ini_path(base, str(node.get("draw", ""))))
		# ldsi/node.ini points at ini:/sfx/lidsi/draw -- a typo in the
		# shipped data. Fall back to the sibling draw.ini rather than
		# rendering nothing.
		if draw.is_empty():
			draw = _read_ini(base.path_join("data/ini/sfx/%s/draw.ini" % name))
		out = _compile(base, node, emitter, dyn, draw)
		out["name"] = name
	_systems[name] = out
	return out

static func _compile(base: String, node: Dictionary, emitter: Dictionary,
		dyn: Dictionary, draw: Dictionary) -> Dictionary:
	var ramp: Array = []
	var cols: Array = draw.get("colours", [])
	var pos: Array = draw.get("colour_positions", [])
	for i in mini(cols.size(), pos.size()):
		ramp.append([float(pos[i]), _vec(str(cols[i]))])
	ramp.sort_custom(func(a, b): return a[0] < b[0])
	var draw_class := str(draw.get("name", ""))
	return {
		"ok": true,
		"node_class": str(node.get("name", "")),
		"dyn_class": str(dyn.get("name", "")),
		"draw_class": draw_class,
		# emitter (FiParticleEmitter, flux.dll @ 0x1005a7a0): time is the
		# emitter's lifetime in seconds, 0 = eternal. fixed_particles is
		# declared int but read as a bool (FixedParticles @ 0x1004f6f0
		# returns `!= 0`), so the 2s in the data mean the same as 1: keep
		# the particles in emitter-local space instead of leaving them in
		# the world.
		"time": _num(emitter, "time", 0.0),
		"fixed": _num(emitter, "fixed_particles", 0.0) != 0.0,
		"respect_orientation": _num(emitter, "respect_orientation", 0.0) != 0.0,
		# dynamics (FcParticleDynamics, flux.dll @ 0x100536b0). The ic*
		# subclasses in iwar2.dll name the lifetime min_death_age /
		# max_death_age instead; accept both.
		"min_rate": _num(dyn, "min_birth_rate", 0.0),
		"max_rate": _num(dyn, "max_birth_rate", 0.0),
		"min_life": _num(dyn, "min_lifetime", _num(dyn, "min_death_age", 1.0)),
		"max_life": _num(dyn, "max_lifetime", _num(dyn, "max_death_age", 1.0)),
		"cone": _num(dyn, "cone_angle", 0.0),
		"min_speed": _num(dyn, "min_speed", _num(dyn, "speed", 0.0)),
		"max_speed": _num(dyn, "max_speed", _num(dyn, "speed", 0.0)),
		"spin": _num(dyn, "angular_velocity", 0.0),
		"max_particles": int(_num(dyn, "max_particles", 0.0)),
		"once": _num(dyn, "once", 0.0) != 0.0,
		# draw (FcParticleDrawBillBoard, flux.dll @ 0x1004f8d0). max_age is
		# the ramp's time base and defaults to 1 second when absent or zero
		# (OnPropertiesChanged @ 0x1004ff20) -- no shipped draw.ini sets it,
		# so every ramp in the game plays over the final second of a
		# particle's life. See docs/effects.md.
		"max_age": _num(draw, "max_age", 1.0),
		"scale_birth": _num(draw, "scale_on_birth", 1.0),
		"scale_death": _num(draw, "scale_on_death", 1.0),
		"scale_by_emitter": _num(draw, "scale_by_emitter", 0.0) != 0.0,
		"fade_on_emitter_age": _num(draw, "fade_on_emitter_age", 0.0) != 0.0,
		"ramp": ramp,
		"texture": str(draw.get("texture", "")),
		"models": draw.get("model_urls", []),
		"model_scale": _num(draw, "scale", 1.0),
		"base": base,
	}

static func release_cache() -> void:
	_systems.clear()
	_textures.clear()
	_meshes.clear()

# --- the original's RNG -----------------------------------------------------

# FnRandom::CentreWeighted (flux.dll @ 0x100480b0): one uniform sample run
# through an S-curve, so the result is biased toward the middle of the range.
static func centre_weighted(a: float, b: float) -> float:
	var u := randf()
	var w := 2.0 * u * u if u < 0.5 else 1.0 - 2.0 * (1.0 - u) * (1.0 - u)
	return a + (b - a) * w

# --- playback ---------------------------------------------------------------

static func spawn(parent: Node3D, base: String, name: String, xform: Transform3D,
		scale: float = 1.0, vel: Vector3 = Vector3.ZERO) -> ParticleFx:
	var s := system(base, name)
	if not s.get("ok", false):
		return null
	var fx := ParticleFx.new()
	fx.sys = s
	fx.emitter_scale = scale
	fx.emitter_vel = vel
	parent.add_child(fx)
	fx.global_transform = xform
	return fx

func _ready() -> void:
	var draw_class: String = sys["draw_class"]
	if draw_class == DRAW_MODEL:
		return  # per-particle glTF instances, built lazily in _spawn_one
	var tex: Texture2D = null
	if draw_class == DRAW_CORNFLAKE:
		tex = _cornflake_texture()
	else:
		tex = ParticleFx.texture(sys["base"], str(sys["texture"]))
	if tex == null:
		queue_free()
		return
	var flake := draw_class == DRAW_CORNFLAKE
	var mesh := QuadMesh.new()
	mesh.size = Vector2.ONE
	mesh.material = ParticleFx.cornflake_material(tex) if flake \
			else ParticleFx.additive_material(tex)
	_mm = MultiMeshInstance3D.new()
	_mm.multimesh = MultiMesh.new()
	_mm.multimesh.transform_format = MultiMesh.TRANSFORM_3D
	_mm.multimesh.use_colors = true
	_mm.multimesh.use_custom_data = flake
	_mm.multimesh.mesh = mesh
	_mm.multimesh.instance_count = maxi(int(sys["max_particles"]), 1)
	_mm.multimesh.visible_instance_count = 0
	# a system's particles can end up far from the emitter node's origin;
	# without this Godot culls the whole batch as soon as the origin leaves
	# the frustum
	_mm.custom_aabb = AABB(Vector3.ONE * -5000.0, Vector3.ONE * 10000.0)
	add_child(_mm)

# cornflakes.png is the colour sheet, cornflake_masks.png the matching
# white-on-black silhouettes; neither carries alpha, so combine them.
func _cornflake_texture() -> Texture2D:
	if _textures.has("_cornflake_rgba"):
		return _textures["_cornflake_rgba"]
	var base: String = sys["base"]
	var dir := base.path_join("data/textures/images/sfx")
	var col := Image.load_from_file(dir.path_join("cornflakes.png"))
	var msk := Image.load_from_file(dir.path_join("cornflake_masks.png"))
	var tex: Texture2D = null
	if col != null and msk != null and col.get_size() == msk.get_size():
		col.convert(Image.FORMAT_RGBA8)
		for y in col.get_height():
			for x in col.get_width():
				var c := col.get_pixel(x, y)
				c.a = msk.get_pixel(x, y).r
				col.set_pixel(x, y, c)
		tex = ImageTexture.create_from_image(col)
	_textures["_cornflake_rgba"] = tex
	return tex

func _emit(delta: float) -> void:
	if sys["time"] > 0.0 and _age >= sys["time"]:
		return
	var cap: int = sys["max_particles"]
	if sys["once"] and _spawned >= cap:
		return
	_accum += ParticleFx.centre_weighted(sys["min_rate"], sys["max_rate"]) * delta
	while _accum >= 1.0:
		_accum -= 1.0
		if _live.size() >= cap or (sys["once"] and _spawned >= cap):
			_accum = 0.0
			return
		_spawn_one()

func _spawn_one() -> void:
	# direction: the emitter's +Z turned by two centre-weighted angles inside
	# cone_angle (flux.dll @ 0x10053f80, matching WeightedEmitInCone). Speed is
	# multiplied by the emitter's scale -- that is what "will get scaled up" in
	# hull_impact/dynamics.ini means.
	var cone: float = sys["cone"]
	var yaw := deg_to_rad(ParticleFx.centre_weighted(-cone, cone))
	var pitch := deg_to_rad(ParticleFx.centre_weighted(-cone, cone))
	var dir := Basis.from_euler(Vector3(pitch, yaw, 0.0)) * Vector3(0, 0, 1)
	var speed := ParticleFx.centre_weighted(sys["min_speed"], sys["max_speed"]) \
			* emitter_scale
	var vel := global_transform.basis * (dir * speed)
	var pos := Vector3.ZERO
	if not sys["fixed"]:
		# world-space particles: born at the emitter, carrying its velocity,
		# and left behind when it moves
		pos = global_position
		vel += emitter_vel
	var spin: float = sys["spin"]
	_live.append({
		"life": ParticleFx.centre_weighted(sys["min_life"], sys["max_life"]),
		"pos": pos,
		"vel": vel,
		"roll": randf() * TAU,
		"spin": deg_to_rad(ParticleFx.centre_weighted(-spin, spin)),
		"cell": randi() % (CORNFLAKE_CELLS * CORNFLAKE_CELLS),
		"model": null,
	})
	_spawned += 1

# The ramps are keyed on 1 - remaining_life/max_age, clamped (Setup @
# 0x10050770 with 1/max_age precomputed): a particle whose life exceeds
# max_age sits at ramp position 0 until its final max_age seconds.
func _ramp_t(life: float) -> float:
	return clampf(1.0 - life / maxf(sys["max_age"], 0.0001), 0.0, 1.0)

func _ramp_colour(t: float) -> Color:
	var ramp: Array = sys["ramp"]
	if ramp.is_empty():
		return Color(1, 1, 1)
	var prev: Array = ramp[0]
	if t <= prev[0]:
		return _col(prev[1])
	for i in range(1, ramp.size()):
		var cur: Array = ramp[i]
		if t <= cur[0]:
			var span: float = maxf(cur[0] - prev[0], 0.0001)
			return _col(prev[1]).lerp(_col(cur[1]), (t - prev[0]) / span)
		prev = cur
	return _col(prev[1])

func _col(v: Vector3) -> Color:
	return Color(v.x, v.y, v.z)

func _process(delta: float) -> void:
	_age += delta
	_emit(delta)
	var i := _live.size() - 1
	while i >= 0:
		var p: Dictionary = _live[i]
		p["life"] -= delta
		if p["life"] <= 0.0:
			var m = p["model"]
			if m != null and is_instance_valid(m):
				(m as Node3D).queue_free()
			_live.remove_at(i)
		else:
			p["pos"] += p["vel"] * delta
			p["roll"] += p["spin"] * delta
		i -= 1
	if _live.is_empty() and (sys["once"] or (sys["time"] > 0.0 and _age >= sys["time"])):
		queue_free()
		return
	if sys["draw_class"] == DRAW_MODEL:
		_draw_models()
	else:
		_draw_billboards()

func _draw_billboards() -> void:
	if _mm == null:
		return
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	# FcBillBoard::Add takes (position, size, roll), so the quad faces the
	# camera and spins about the view axis. Godot's BILLBOARD_ENABLED would
	# overwrite the basis and lose the roll, so orient on the CPU.
	var cb := cam.global_transform.basis
	var origin := global_position if sys["fixed"] else Vector3.ZERO
	var emit_scale: float = emitter_scale if sys["scale_by_emitter"] else 1.0
	var fade := 1.0
	if sys["fade_on_emitter_age"] and sys["time"] > 0.0:
		fade = clampf(_age / sys["time"], 0.0, 1.0)
	var n := mini(_live.size(), _mm.multimesh.instance_count)
	for i in n:
		var p: Dictionary = _live[i]
		var t := _ramp_t(p["life"])
		var size: float = lerpf(sys["scale_birth"], sys["scale_death"], t) * emit_scale
		if sys["draw_class"] == DRAW_CORNFLAKE:
			size = CORNFLAKE_SIZE * emitter_scale
		var b := cb.rotated(cb.z, p["roll"]).scaled(Vector3(size, size, size))
		_mm.multimesh.set_instance_transform(i,
				Transform3D(b, origin + p["pos"] - global_position))
		var c := _ramp_colour(t)
		if sys["draw_class"] == DRAW_CORNFLAKE:
			c = Color(1, 1, 1)  # icCornflakeDraw has no ramp; the sheet is lit art
		_mm.multimesh.set_instance_color(i, Color(c.r * fade, c.g * fade, c.b * fade))
		if _mm.multimesh.use_custom_data:
			var cell: int = p["cell"]
			_mm.multimesh.set_instance_custom_data(i, Color(
					float(cell % CORNFLAKE_CELLS) / CORNFLAKE_CELLS,
					float(cell / CORNFLAKE_CELLS) / CORNFLAKE_CELLS,
					1.0 / CORNFLAKE_CELLS, 0.0))
	_mm.multimesh.visible_instance_count = n

func _draw_models() -> void:
	var urls: Array = sys["models"]
	if urls.is_empty():
		return
	for p in _live:
		if p["model"] == null:
			var url := str(urls[randi() % urls.size()])
			var m := _load_model(url)
			if m != null:
				add_child(m)
				m.scale = Vector3.ONE * (sys["model_scale"] * emitter_scale)
				p["model"] = m
		var m2 = p["model"]
		if m2 != null and is_instance_valid(m2):
			var n: Node3D = m2
			var world: Vector3 = p["pos"]
			if sys["fixed"]:
				world += global_position
			n.global_position = world
			n.basis = Basis.from_euler(Vector3(p["roll"], p["roll"] * 0.7, 0.0)) \
					.scaled(Vector3.ONE * (sys["model_scale"] * emitter_scale))

# "model:/models/kibble01" -> data/gltf/models/kibble01.gltf
func _load_model(url: String) -> Node3D:
	var rel := "data/gltf/" + url.trim_prefix("model:/") + ".gltf"
	if _meshes.has(rel):
		var proto = _meshes[rel]
		return null if proto == null else (proto as Node3D).duplicate()
	var path: String = str(sys["base"]).path_join(rel)
	if not FileAccess.file_exists(path):
		_meshes[rel] = null
		return null
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	if doc.append_from_file(path, state) != OK:
		_meshes[rel] = null
		return null
	var node := doc.generate_scene(state)
	_meshes[rel] = node
	return null if node == null else (node as Node3D).duplicate()

# floating origin: our parent node is moved for us, but particles that were
# left behind in world space (fixed_particles = 0) hold absolute positions
func shift_world(offset: Vector3) -> void:
	if sys.get("fixed", true):
		return
	for p in _live:
		p["pos"] -= offset
