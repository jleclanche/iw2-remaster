class_name ExplosionFx
extends Node3D
# Player for the original's composite effects. icVisualEffects (iwar2.dll,
# name table @ 0x10161f14) holds twelve effect prefixes and builds the URL as
# "%slow" or "%shigh_%d" -- so a hull impact is the LightWave scene
# lws:/sfx/hull_impact_high_0. Each scene is a bag of nulls tagged
# <node template=ini||sfx|x|node> (a ParticleFx system),
# <node class=icMovieAvatar url=... frame_count=N> (a flipbook),
# <node template=ini||audio|sfx|x> (a sound), plus a LightWave light with an
# intensity envelope. RECIPES below is that table, read out of the scenes in
# resource.zip (sfx/*.lws). Those files are not in our extraction yet, which
# is why the recipes live here and not in data/. See docs/effects.md.

const RECIPES := {
	"explosion": {
		"movie": "deba", "frames": 50, "movie_scale": 5.0,
		"systems": ["cornflakes", "spark_shower"],
		"sounds": ["large_explosion_1", "large_explosion_2", "large_explosion_3"],
		"light": Color(1.0, 0.647, 0.098), "range": 50.0, "fps": 60.0,
		"env": [[0.0, 0.0], [0.05, 1.0], [0.3, 0.3], [1.0, 0.0]],
	},
	"small_explosion": {
		"movie": "fzgb", "frames": 40, "movie_scale": 5.0,
		"systems": ["cornflakes", "spark_shower"],
		"sounds": ["small_explosion_1", "small_explosion_2", "small_explosion_3"],
		"light": Color(1.0, 0.647, 0.098), "range": 50.0, "fps": 60.0,
		"env": [[0.0, 0.0], [0.05, 1.0], [0.3, 0.3], [1.0, 0.0]],
	},
	"hull_impact": {
		"systems": ["pbc_spark"], "sounds": ["impact"],
		"light": Color(1.0, 0.647, 0.098), "range": 60.0, "fps": 30.0,
		"env": [[0.0, 0.0], [0.0667, 1.0], [0.5, 0.0]],
	},
	"beam_impact": {
		"systems": ["pbc_spark"], "sounds": ["impact"],
		"light": Color(1.0, 0.647, 0.098), "range": 60.0, "fps": 30.0,
		"env": [[0.0, 0.0], [0.0667, 1.0], [0.5, 0.0]],
	},
	"asteroid_impact": {
		"systems": ["pbc_spark", "asteroid_impact"], "sounds": [],
		"light": Color(1.0, 0.647, 0.098), "range": 60.0, "fps": 30.0,
		"env": [[0.0, 0.0], [0.0667, 1.0], [0.5, 0.0]],
	},
	"collision": {
		"systems": [], "sounds": ["collision"], "range": 0.0,
	},
}

# icMovieAvatar's playback rate is not recovered; the scene is 60 frames long
# and the flipbook has 40-50, so the two cannot both be right. Kept at the
# rate the previous billboard explosion used.
const MOVIE_FPS := 25.0

# The muzzle flash is not a particle system: avatars/standard_pbc/
# setup_effects.lws is a lens-flare light parented to an
# <anim channel="fire?o(5.0)"> null, so it pops on the rising edge of `fire`
# and decays at 5/s. LightColor 252 180 16, LightRange 300.
const MUZZLE_COLOUR := Color(0.988, 0.706, 0.063)
const MUZZLE_RANGE := 300.0
const MUZZLE_DECAY := 5.0

# The bolt: avatars/standard_pbc_bolt/setup.lws is a single
# <node class=icBeamAvatar texture=pbc_standard> scaled (4, 1, 800) -- an
# 800 m streak, which is exactly the `length` in sims/weapons/pbc_bolt.ini --
# plus a glow light (252 128 16, range 300).
const BOLT_WIDTH := 4.0
const BOLT_LENGTH := 800.0
const BOLT_TEXTURE := "images/sfx/pbc_standard"

static var _movies: Dictionary = {}

var _t := 0.0
var _life := 1.0
var _size := 60.0
var _recipe: Dictionary = {}
var _fire: MeshInstance3D
var _fire_mat: StandardMaterial3D
var _frames: Array = []
var _light: OmniLight3D

static func _movie(base: String, stem: String, count: int) -> Array:
	if _movies.has(stem):
		return _movies[stem]
	var frames: Array = []
	for i in count:
		var path := base.path_join("data/textures/images/sfx/%s%02d.png" % [stem, i])
		if not FileAccess.file_exists(path):
			continue
		var img := Image.load_from_file(path)
		if img != null:
			frames.append(ImageTexture.create_from_image(img))
	_movies[stem] = frames
	return frames

static func release_cache() -> void:
	# static texture refs outlive the renderer and spam RID leaks at exit;
	# main releases them on shutdown
	_movies.clear()
	ParticleFx.release_cache()

# main.gd's ship-kill hook. A ship death is the `explosion` effect.
static func boom(main: Node3D, pos: Vector3, size: float) -> void:
	play(main, "explosion", Transform3D(Basis.IDENTITY, pos), size)

static func play(main: Node3D, key: String, xform: Transform3D,
		size: float = 1.0) -> ExplosionFx:
	if not RECIPES.has(key):
		return null
	var base: String = main._base()
	var recipe: Dictionary = RECIPES[key]
	var fx := ExplosionFx.new()
	fx._recipe = recipe
	fx._size = size
	main.add_child(fx)
	fx.global_transform = xform
	for sys_name in recipe.get("systems", []):
		ParticleFx.spawn(fx, base, str(sys_name), xform, size)
	var sounds: Array = recipe.get("sounds", [])
	if not sounds.is_empty() and main.audio != null:
		main.audio.play("audio/sfx/%s.wav" % str(sounds[randi() % sounds.size()]), -2.0)
	return fx

# The <anim channel="fire?o(5.0)"> flare on the cannon avatar.
static func muzzle_flash(parent: Node3D, at: Vector3) -> void:
	var l := OmniLight3D.new()
	l.light_color = MUZZLE_COLOUR
	l.light_energy = 8.0
	l.omni_range = MUZZLE_RANGE
	parent.add_child(l)
	l.global_position = at
	var tw := l.create_tween()
	tw.tween_property(l, "light_energy", 0.0, 1.0 / MUZZLE_DECAY)
	tw.tween_callback(l.queue_free)

static func bolt_mesh(base: String) -> Mesh:
	# icBeamAvatar is a textured streak along the bolt's local +Z. Crossed
	# quads so it does not vanish when the camera looks down the beam.
	var tex := ParticleFx.texture(base, BOLT_TEXTURE)
	var mat := ParticleFx.additive_material(tex)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var half := BOLT_LENGTH * 0.5
	for axis in 2:
		var w := Vector3(BOLT_WIDTH * 0.5, 0, 0) if axis == 0 \
				else Vector3(0, BOLT_WIDTH * 0.5, 0)
		var corners := [
			[-w - Vector3(0, 0, half), Vector2(0, 0)],
			[w - Vector3(0, 0, half), Vector2(0, 1)],
			[w + Vector3(0, 0, half), Vector2(1, 1)],
			[-w + Vector3(0, 0, half), Vector2(1, 0)],
		]
		for idx in [0, 1, 2, 0, 2, 3]:
			st.set_uv(corners[idx][1])
			st.add_vertex(corners[idx][0])
	st.generate_normals()
	var mesh := st.commit()
	mesh.surface_set_material(0, mat)
	return mesh

func shift_world(offset: Vector3) -> void:
	global_position -= offset
	for c in get_children():
		if c is ParticleFx:
			(c as ParticleFx).shift_world(offset)

func _ready() -> void:
	add_to_group("worldfx")  # main._fold_motion re-anchors us on origin shift
	var fps: float = _recipe.get("fps", 30.0)
	_life = 60.0 / maxf(fps, 1.0)  # every sfx scene runs to LastFrame 60
	var stem := str(_recipe.get("movie", ""))
	if not stem.is_empty():
		var main := get_parent() as Node3D
		_frames = ExplosionFx._movie(main._base(), stem, int(_recipe["frames"]))
		if not _frames.is_empty():
			_fire_mat = ParticleFx.additive_material(_frames[0])
			_fire_mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
			var mesh := QuadMesh.new()
			mesh.size = Vector2.ONE * (_size * float(_recipe["movie_scale"]) * 0.52)
			mesh.material = _fire_mat
			_fire = MeshInstance3D.new()
			_fire.mesh = mesh
			_fire.rotate_z(randf() * TAU)
			add_child(_fire)
			_life = maxf(_life, _frames.size() / MOVIE_FPS)
	var rng: float = _recipe.get("range", 0.0)
	if rng > 0.0:
		_light = OmniLight3D.new()
		_light.light_color = _recipe.get("light", Color(1, 1, 1))
		_light.omni_range = rng * maxf(_size, 1.0) * 0.2
		_light.light_energy = 0.0
		add_child(_light)

# LightWave intensity envelope: piecewise-linear keys of (time, intensity).
func _envelope(t: float) -> float:
	var env: Array = _recipe.get("env", [])
	if env.is_empty():
		return 0.0
	var prev: Array = env[0]
	if t <= prev[0]:
		return prev[1]
	for i in range(1, env.size()):
		var cur: Array = env[i]
		if t <= cur[0]:
			var span: float = maxf(cur[0] - prev[0], 0.0001)
			return lerpf(prev[1], cur[1], (t - prev[0]) / span)
		prev = cur
	return 0.0

func _process(delta: float) -> void:
	_t += delta
	var life := _t / _life
	if _light != null:
		_light.light_energy = _envelope(life) * 8.0
	if _fire != null and not _frames.is_empty():
		var fi := int(_t * MOVIE_FPS)
		if fi < _frames.size():
			_fire_mat.albedo_texture = _frames[fi]
			_fire.scale = Vector3.ONE * (1.0 + life * 0.9)
		else:
			_fire.visible = false
	if _t >= _life:
		queue_free()
