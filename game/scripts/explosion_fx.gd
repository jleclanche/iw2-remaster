class_name ExplosionFx
extends Node3D
# Player for the original's composite effects, driven entirely by
# data/json/sfx_effects.json (tools/iw2/sfx.py -> the 23 sfx/*.lws scenes plus
# the icVisualEffects constants out of iwar2.dll). Nothing about an individual
# effect is hardcoded here any more; see docs/effects.md.
#
# A scene is a bag of nulls tagged <node template=ini||sfx|x|node> (a ParticleFx
# system), <node class=icMovieAvatar url=... frame_count=N> (a flipbook),
# <node template=ini||audio|sfx|x> (a sound), <node class=icShockwaveAvatar ...>
# and a LightWave light with an intensity envelope.
#
# The engine picks low vs high_%d by *apparent size*, not by a quality setting
# (icVisualEffects @0x100d33e0):
#     apparent = size * size_weight / distance_to_camera
#     < cull_detail -> nothing;  < low_detail -> `low`;  else a random `high_%d`

const TABLE_PATH := "data/json/sfx_effects.json"

# Renderer-side constants. These are NOT from the game: the original's D3D
# light model and its icMovieAvatar quad size are not recovered (see
# docs/effects.md "Open questions"), so these are fitted to look right.
const LIGHT_ENERGY := 8.0    # scales a LightWave intensity to a Godot energy
const MOVIE_QUAD := 0.52     # quad half-extent per unit of movie scale
const MOVIE_FPS := 25.0      # icMovieAvatar's playback rate is unknown
const MAX_LIFE := 30.0       # backstop: an eternal emitter must not leak

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

static var _table: Dictionary = {}
static var _movies: Dictionary = {}

var _t := 0.0
var _life := 1.0
var _size := 1.0
var _fps := 30.0
var _variant: Dictionary = {}
var _fire: MeshInstance3D
var _fire_mat: StandardMaterial3D
var _frames: Array = []
var _lights: Array = []     # [{node, envelope, intensity}]
var _systems: Array = []    # [{fx, scale, keys}] -- animated emitter scalers

static func table(base: String) -> Dictionary:
	if not _table.is_empty():
		return _table
	var path := base.path_join(TABLE_PATH)
	if not FileAccess.file_exists(path):
		push_warning("ExplosionFx: %s missing; run python -m tools.iw2.sfx" % path)
		return {}
	var txt := FileAccess.get_file_as_string(path)
	var parsed = JSON.parse_string(txt)
	if parsed is Dictionary:
		_table = parsed
	return _table

static func release_cache() -> void:
	# static texture refs outlive the renderer and spam RID leaks at exit;
	# main releases them on shutdown
	_movies.clear()
	_table.clear()
	ParticleFx.release_cache()

static func _movie(base: String, stem: String, count: int) -> Array:
	if _movies.has(stem):
		return _movies[stem]
	var frames: Array = []
	for i in count:
		var path := base.path_join("data/textures/%s%02d.png" % [stem, i])
		if not FileAccess.file_exists(path):
			continue
		var img := Image.load_from_file(path)
		if img != null:
			frames.append(ImageTexture.create_from_image(img))
	_movies[stem] = frames
	return frames

# LightWave envelope: piecewise-linear keys of [frame, value].
static func _envelope(env: Array, frame: float) -> float:
	if env.is_empty():
		return 0.0
	var prev: Array = env[0]
	if frame <= float(prev[0]):
		return float(prev[1])
	for i in range(1, env.size()):
		var cur: Array = env[i]
		if frame <= float(cur[0]):
			var span: float = maxf(float(cur[0]) - float(prev[0]), 0.0001)
			return lerpf(float(prev[1]), float(cur[1]),
					(frame - float(prev[0])) / span)
		prev = cur
	return float((env[env.size() - 1] as Array)[1])

# icVisualEffects @0x100d33e0: cull / low / a uniformly random high_%d, chosen
# by the effect's apparent size. Returns {} when the effect is culled.
static func _pick(main: Node3D, effect: Dictionary, pos: Vector3,
		size: float) -> Dictionary:
	var variants: Dictionary = effect.get("variants", {})
	var high: Array = variants.get("high", [])
	var low = variants.get("low")
	var engine: Dictionary = _table.get("engine", {})
	var cam: Camera3D = null
	if main.is_inside_tree() and main.get_viewport() != null:
		cam = main.get_viewport().get_camera_3d()
	if cam != null:
		var dist := maxf(cam.global_position.distance_to(pos), 0.001)
		var apparent: float = size * float(effect.get("size_weight", 20.0)) / dist
		if apparent < float(engine.get("cull_detail", 0.005)):
			return {}
		if apparent < float(engine.get("low_detail", 0.04)):
			# the engine reads the `low` slot and draws nothing if it is empty;
			# five of the twelve effects ship no _low scene, so they simply
			# vanish past this distance
			return low if low != null else {}
	if not high.is_empty():
		return high[randi() % high.size()]
	if low != null:
		return low
	return {}

static func play(main: Node3D, key: String, xform: Transform3D,
		size: float = 1.0) -> ExplosionFx:
	var tbl := table(main._base())
	var effects: Dictionary = tbl.get("effects", {})
	if not effects.has(key):
		return null
	var effect: Dictionary = effects[key]
	var variant := _pick(main, effect, xform.origin, size)
	if variant.is_empty():
		return null
	var fx := ExplosionFx.new()
	fx._variant = variant
	fx._size = size
	main.add_child(fx)
	fx.global_transform = xform
	fx._build(main, xform)
	return fx

# main.gd's ship-kill hook. iiSim::DoFinalExplosion (@0x1007c990): a dying sim
# spawns FOUR icExplosion puffs, each of radius R*lerp(0.3, 0.6, rand) and
# scattered by a random unit vector * R*0.4, plus one reactor_explosion
# shockwave. Each puff picks explosion vs small_explosion from its OWN radius
# against 150 m (@0x1011a81c) -- which is why a fighter (R ~ 60-70 m, so puffs
# of 20-40 m) never shows the big `explosion`: you need R > ~250 m for that.
static func boom(main: Node3D, pos: Vector3, size: float) -> void:
	var tbl := table(main._base())
	var death: Dictionary = tbl.get("engine", {}).get("death", {})
	var threshold: float = float(tbl.get("engine", {}).get(
			"small_explosion_threshold", 150.0))
	var lo: float = float(death.get("puff_radius_min", 0.3))
	var hi: float = float(death.get("puff_radius_max", 0.6))
	var scatter: float = float(death.get("puff_scatter", 0.4))
	for i in int(death.get("puffs", 4)):
		var radius: float = size * lerpf(lo, hi, randf())
		var at: Vector3 = pos + _unit_vector() * size * scatter
		var key := "explosion" if radius >= threshold else "small_explosion"
		play(main, key, Transform3D(Basis.IDENTITY, at), radius)
	# The reactor shockwave that accompanies every death. We have no mesh for
	# icShockwaveAvatar (see docs/effects.md), so this contributes its light
	# and sound only.
	play(main, "reactor_explosion", Transform3D(Basis.IDENTITY, pos), size)

static func _unit_vector() -> Vector3:
	# FnRandom::UnitVector
	var v := Vector3(randfn(0.0, 1.0), randfn(0.0, 1.0), randfn(0.0, 1.0))
	return v.normalized() if v.length() > 0.0001 else Vector3.UP

func _build(main: Node3D, xform: Transform3D) -> void:
	var base: String = main._base()
	_fps = maxf(float(_variant.get("fps", 30.0)), 1.0)
	var last_frame: float = float(_variant.get("last_frame", 60))

	for s in _variant.get("systems", []):
		var sys: Dictionary = s
		var scale: float = _size * float(sys.get("scale", 1.0))
		var keys: Array = sys.get("scale_keys", [])
		var start: float = scale * (_envelope(keys, 0.0) if not keys.is_empty() else 1.0)
		var fx := ParticleFx.spawn(self, base, str(sys.get("name", "")), xform,
				maxf(start, 0.0001))
		if fx != null:
			_systems.append({"fx": fx, "scale": scale, "keys": keys})
			if not keys.is_empty():
				last_frame = maxf(last_frame, float((keys[keys.size() - 1] as Array)[0]))

	var movie = _variant.get("movie")
	if movie is Dictionary:
		var stem := str((movie as Dictionary).get("texture", ""))
		var count := int((movie as Dictionary).get("frames", 0))
		_frames = ExplosionFx._movie(base, stem, count)
		if not _frames.is_empty():
			_fire_mat = ParticleFx.additive_material(_frames[0])
			_fire_mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
			var mesh := QuadMesh.new()
			var mscale: float = float((movie as Dictionary).get("scale", 1.0))
			mesh.size = Vector2.ONE * (_size * mscale * MOVIE_QUAD)
			mesh.material = _fire_mat
			_fire = MeshInstance3D.new()
			_fire.mesh = mesh
			_fire.rotate_z(randf() * TAU)
			add_child(_fire)

	for l in _variant.get("lights", []):
		var light: Dictionary = l
		var rng: float = float(light.get("range", 0.0))
		if rng <= 0.0:
			continue  # LightType 0 (reactor_explosion) has no range: not a point light
		var node := OmniLight3D.new()
		var col: Array = light.get("color", [255, 255, 255])
		node.light_color = Color(float(col[0]) / 255.0, float(col[1]) / 255.0,
				float(col[2]) / 255.0)
		# the effect's scene node is scaled to `size` by the engine, and the
		# light hangs inside that scene
		node.omni_range = rng * maxf(_size, 1.0)
		node.light_energy = 0.0
		add_child(node)
		var env: Array = light.get("envelope", [])
		_lights.append({"node": node, "env": env,
				"intensity": float(light.get("intensity", 0.0))})
		if not env.is_empty():
			last_frame = maxf(last_frame, float((env[env.size() - 1] as Array)[0]))

	for s in _variant.get("sounds", []):
		var snd: Dictionary = s
		if main.audio == null:
			break
		var vol: float = float(snd.get("volume", 1.0))
		main.audio.play("audio/sfx/%s.wav" % str(snd.get("wav", "")),
				linear_to_db(maxf(vol, 0.001)) - 2.0)

	_life = last_frame / _fps
	if not _frames.is_empty():
		_life = maxf(_life, _frames.size() / MOVIE_FPS)

func _ready() -> void:
	add_to_group("worldfx")  # main._fold_motion re-anchors us on origin shift

func shift_world(offset: Vector3) -> void:
	global_position -= offset
	for c in get_children():
		if c is ParticleFx:
			(c as ParticleFx).shift_world(offset)

func _has_live_particles() -> bool:
	for c in get_children():
		if c is ParticleFx:
			return true
	return false

func _process(delta: float) -> void:
	_t += delta
	var frame := _t * _fps

	for l in _lights:
		var light: Dictionary = l
		var env: Array = light["env"]
		var value: float = _envelope(env, frame) if not env.is_empty() \
				else float(light["intensity"])
		(light["node"] as OmniLight3D).light_energy = value * LIGHT_ENERGY

	for s in _systems:
		var sys: Dictionary = s
		var keys: Array = sys["keys"]
		if keys.is_empty():
			continue
		var fx = sys["fx"]
		if fx != null and is_instance_valid(fx):
			(fx as ParticleFx).emitter_scale = float(sys["scale"]) \
					* _envelope(keys, frame)

	if _fire != null and not _frames.is_empty():
		var fi := int(_t * MOVIE_FPS)
		if fi < _frames.size():
			_fire_mat.albedo_texture = _frames[fi]
			_fire.scale = Vector3.ONE * (1.0 + (_t / maxf(_life, 0.001)) * 0.9)
		else:
			_fire.visible = false

	if _t >= MAX_LIFE or (_t >= _life and not _has_live_particles()):
		queue_free()

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
