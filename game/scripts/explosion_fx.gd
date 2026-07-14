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

# Renderer-side constant. NOT from the game: the original's D3D light model is
# not comparable to Godot's, so this is fitted to look right.
const LIGHT_ENERGY := 8.0    # scales a LightWave intensity to a Godot energy
const MAX_LIFE := 30.0       # backstop: an eternal emitter must not leak

# icMovieAvatar (iwar2.dll, vtable 0x1011d018; recovered by raw disassembly,
# docs/effects.md section 6). Prepare (0x100ca990) advances the frame counter
# by 0.5 PER RENDERED FRAME -- playback is framerate-locked, not time-based
# (0.5 * 60 Hz = 30 flipbook fps on the original's target rate). The draw
# (0x100caa50) renders TWO quads, frame N and N+1, alpha-crossfaded by the
# fractional frame, blend 2 (SRCALPHA, ONE). Quad half-extent = the node's
# world radius = the LWS scale * the effect size. Orientation: a billboard
# basis built around the camera direction with a per-instance RANDOM roll
# axis from the ctor (0x100ca660).
const MOVIE_FRAME_STEP := 0.5

# icShockwaveAvatar (vtable 0x1011d140 slots 14/16 -> 0x100cfc90 / 0x100cfcb0):
# two counter-rotating FcBillBoard::Draw4x4 quads (the mirrored-quadrant fan,
# StarFx.quadrant_fan_mesh), texture:/images/sfx/shockwave, scaled to the
# node's world radius, colour = tint * (1 - age/lifetime), additive.
# The spin phase is frac(game_time_ms * 1e-5) * 2pi (0x1011d18c / 0x10119f94);
# the roll axis is a random unit vector from the ctor (0x100cfa50).
const SHOCKWAVE_SPIN := TAU * 1e-5 * 1000.0  # rad/s, assuming ms game time

# icLDAAvatar (vtable 0x1011cfcc slots 14/16 -> 0x100c9d80 / 0x100c9dd0): a
# 16-triangle cone fan, apex at local +Z * 4 (0x1011cfbc), drawn for a 1 s
# life (0x1011cfc0). The rim radius grows 0 -> 30 (0x1011cfb8) over the first
# half of the life (0x10117738 = 0.5), then holds 30 while the alpha fades
# 1 -> 0. The texture (texture:/images/sfx/lda) scrolls rim-to-apex at 1 v/s
# (0x1011cfc4); rim vertices have alpha 0. Blend 2 (SRCALPHA, ONE).
const LDA_LIFETIME := 1.0
const LDA_APEX := 4.0
const LDA_RIM := 30.0
const LDA_SEGS := 16

# icBeamAvatar rigs (the antimatter spikes) are now fully data-driven:
# sfx_effects.json carries each beam's per-axis LWS scale (`scale_xyz`,
# x = half-width, z = length), its scaler envelope (`scale_keys`, from the
# beam_scaler_thick/_thin nulls) and its spinner parent chain (`parents`:
# FatBeamsH/FatBeamsP spin +360 deg/2 s in heading and pitch; SkinnyBeamsH
# starts pitched 180 (unwinding to 0) while spinning -360 deg/2 s in heading,
# SkinnyBeamsP -360 deg/2 s in pitch). The beam texture name is the node's
# `texture` attribute under images/sfx/.
const BEAM_TEXTURE := "searchbeam"  # fallback when a node carries no texture

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
# plus a glow light (252 128 16, range 300). The icBeamAvatar draw
# (0x100bb830) makes an axial billboard: half-width = scale.x (so the bolt is
# 8 m wide), running scale.z along local +Z, blend 1 = pure additive
# (sPolygonState @ 0x10168230).
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
var _movie_frame := 0.0
var _movie_axis := Vector3.UP
var _movie_half := 1.0
var _movie_quads: Array = []  # two MeshInstance3D, cross-faded
var _frames: Array = []
var _lights: Array = []      # [{node, envelope, intensity}]
var _systems: Array = []     # [{fx, scale, keys}] -- animated emitter scalers
var _shockwaves: Array = []  # [{a, b, tint, lifetime, keys, axis}]
var _ldas: Array = []        # [{node, mat}]
var _beams: Array = []       # [{node, dir, width, length, keys, spinners}]

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
	# the reactor shockwave that accompanies every death
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
			_build_movie(float((movie as Dictionary).get("scale", 1.0)))

	for a in _variant.get("avatars", []):
		var av: Dictionary = a
		match str(av.get("class", "")):
			"icShockwaveAvatar":
				_add_shockwave(base, av)
				last_frame = maxf(last_frame, float(av.get("lifetime", 1)) * _fps)
			"icLDAAvatar":
				_add_lda(base, av)
				last_frame = maxf(last_frame, LDA_LIFETIME * _fps)
			"icBeamAvatar":
				_add_beam(base, av)
				var bkeys: Array = av.get("scale_keys", [])
				if not bkeys.is_empty():
					last_frame = maxf(last_frame,
							float((bkeys[bkeys.size() - 1] as Array)[0]))

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
		# frame-rate locked playback; assume the original's 60 Hz target for
		# the lifetime bound only
		_life = maxf(_life, _frames.size() / (MOVIE_FRAME_STEP * 60.0))

# additive-with-alpha: the engine's blend 2 (SRCALPHA, ONE) -- colour scaled
# by alpha, added to the framebuffer
static func _blend2_material(tex: Texture2D) -> StandardMaterial3D:
	var mat := ParticleFx.additive_material(tex)
	mat.vertex_color_use_as_albedo = false
	return mat

# --- icMovieAvatar -----------------------------------------------------------

# @element icMovieAvatar
func _build_movie(movie_scale: float) -> void:
	# quad half-extent = node world radius = LWS scale * effect size
	# (FindWorldRadius at 0x100cabb9; the ctor's base radius is 1.0)
	_movie_half = movie_scale * _size
	_movie_axis = ExplosionFx._unit_vector()  # fixed random roll, ctor 0x100ca660
	var mesh := QuadMesh.new()
	mesh.size = Vector2.ONE * 2.0  # unit half-extent; the basis carries the size
	for i in 2:
		var mi := MeshInstance3D.new()
		var mat := ExplosionFx._blend2_material(_frames[0])
		mesh = mesh.duplicate()
		mesh.material = mat
		mi.mesh = mesh
		add_child(mi)
		_movie_quads.append(mi)

func _update_movie() -> void:
	# Prepare (0x100ca990): += 0.5 per rendered frame; draw (0x100caa50)
	# cross-fades frame N and N+1 by the fractional position
	_movie_frame += MOVIE_FRAME_STEP
	var fi := int(_movie_frame)
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var camdir := -cam.global_transform.basis.z
	var right := camdir.cross(_movie_axis)
	if right.length() < 0.001:
		right = camdir.cross(Vector3.UP)
	right = right.normalized()
	var up := right.cross(camdir).normalized()
	var b := Basis(right * _movie_half, up * _movie_half, camdir * _movie_half)
	for i in 2:
		var mi: MeshInstance3D = _movie_quads[i]
		var f := fi + i
		if f >= _frames.size():
			mi.visible = false
			continue
		var mat: StandardMaterial3D = (mi.mesh as QuadMesh).material
		mat.albedo_texture = _frames[f]
		# alpha = 1 - |frame_index - frame| (0x100cadb0..0x100cae08)
		mat.albedo_color.a = clampf(1.0 - absf(float(f) - _movie_frame), 0.0, 1.0)
		mi.global_transform.basis = b

# --- icShockwaveAvatar -------------------------------------------------------

# @element icShockwaveAvatar
func _add_shockwave(base: String, av: Dictionary) -> void:
	var tint_arr: Array = av.get("tint", [1.0, 1.0, 1.0])
	var tint := Color(float(tint_arr[0]), float(tint_arr[1]), float(tint_arr[2]))
	var tex := ParticleFx.texture(base, "images/sfx/shockwave")
	var pair: Array = []
	for i in 2:
		var mi := MeshInstance3D.new()
		mi.mesh = StarFx.quadrant_fan_mesh()
		mi.mesh.surface_set_material(0, ExplosionFx._blend2_material(tex))
		add_child(mi)
		pair.append(mi)
	_shockwaves.append({
		"a": pair[0], "b": pair[1], "tint": tint,
		"lifetime": maxf(float(av.get("lifetime", 1)), 0.001),
		"keys": av.get("scale_keys", []),
		"axis": ExplosionFx._unit_vector(),  # ctor 0x100cfa50
	})

func _update_shockwaves(cb: Basis) -> void:
	# spin phase: frac(game_time_ms * 1e-5) * 2pi (0x100cfceb..0x100cfd29);
	# roll tracks the random axis against the camera like the sun corona
	var phase := fposmod(_t * SHOCKWAVE_SPIN, TAU)
	for s in _shockwaves:
		var sw: Dictionary = s
		var life: float = sw["lifetime"]
		var fade := clampf(1.0 - _t / life, 0.0, 1.0)  # 0x100cfd85..0x100cfdcb
		var keys: Array = sw["keys"]
		var r: float = _size * (_envelope(keys, _t * _fps) if not keys.is_empty() else 1.0)
		r = maxf(r, 0.0001)
		var axis: Vector3 = sw["axis"]
		var roll := -atan2(axis.dot(cb.y), axis.dot(cb.x))
		var col: Color = sw["tint"]
		col.a = fade
		for layer in 2:
			var mi: MeshInstance3D = sw["a"] if layer == 0 else sw["b"]
			if fade <= 0.0:
				mi.visible = false
				continue
			var rl := roll + (phase if layer == 0 else -phase)
			var c := cos(rl)
			var sn := sin(rl)
			var right := cb.x * c - cb.y * sn
			var up := cb.y * c + cb.x * sn
			mi.global_transform.basis = Basis(right * r, up * r, cb.z * r)
			((mi.mesh as ArrayMesh).surface_get_material(0)
					as StandardMaterial3D).albedo_color = col

# --- icLDAAvatar -------------------------------------------------------------

# @element icLDAAvatar
func _add_lda(base: String, _av: Dictionary) -> void:
	var tex := ParticleFx.texture(base, "images/sfx/lda")
	var mat := ExplosionFx._blend2_material(tex)
	mat.vertex_color_use_as_albedo = true  # the rim fades to alpha 0
	var mi := MeshInstance3D.new()
	mi.mesh = lda_cone_mesh()
	mi.mesh.surface_set_material(0, mat)
	add_child(mi)
	_ldas.append({"node": mi, "mat": mat})

# The cone fan (FUN_100c9f40 @ 0x100c9f40): 16 triangles, apex at local
# +Z (scaled to 4 by the node transform), rim on the z=0 circle. Apex UV
# u=0.5, rim u alternates 0/1 per triangle; the v offset scrolls with age.
# icAggressorAvatar's Draw (0x100b94e0) calls the SAME helper, which is why this
# is shared with space_fx.gd rather than private to the LDA.
static func lda_cone_mesh() -> ArrayMesh:
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var cols := PackedColorArray()
	var apex_col := Color(1, 1, 1, 1)
	var rim_col := Color(1, 1, 1, 0)
	for i in LDA_SEGS:
		var a0 := TAU * float(i) / LDA_SEGS
		var a1 := TAU * float(i + 1) / LDA_SEGS
		verts.append(Vector3(0, 0, 1))
		uvs.append(Vector2(0.5, 0.0))
		cols.append(apex_col)
		verts.append(Vector3(cos(a0), sin(a0), 0))
		uvs.append(Vector2(0.0, 1.0))
		cols.append(rim_col)
		verts.append(Vector3(cos(a1), sin(a1), 0))
		uvs.append(Vector2(1.0, 1.0))
		cols.append(rim_col)
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_TEX_UV] = uvs
	arr[Mesh.ARRAY_COLOR] = cols
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return mesh

func _update_ldas() -> void:
	# Prepare (0x100c9d80) / draw (0x100c9dd0): rim = (2*30/life)*age for the
	# first half of the life, then 30 with alpha = 2*(1 - age/life)
	for l in _ldas:
		var lda: Dictionary = l
		var mi: MeshInstance3D = lda["node"]
		if _t >= LDA_LIFETIME:
			mi.visible = false
			continue
		var rim: float
		var alpha: float
		if _t <= LDA_LIFETIME * 0.5:
			rim = (2.0 * LDA_RIM / LDA_LIFETIME) * _t
			alpha = 1.0
		else:
			rim = LDA_RIM
			alpha = 2.0 * (1.0 - _t / LDA_LIFETIME)
		# the avatar node inherits the effect scale like every scene node
		rim *= _size
		mi.scale = Vector3(maxf(rim, 0.001), maxf(rim, 0.001), LDA_APEX * _size)
		var mat: StandardMaterial3D = lda["mat"]
		mat.albedo_color.a = clampf(alpha, 0.0, 1.0)
		# v scrolls rim-to-apex: apex v = -age, rim v = 1 - age (0x100c9e96)
		mat.uv1_offset.y = -_t

# --- icBeamAvatar (the antimatter spikes) ------------------------------------

# LightWave HPB (degrees) -> basis: heading about Y, pitch about X, bank
# about the +Z-forward axis, heading outermost (LW's H*P*B order, mapped the
# same way the beam directions always were).  All authored sfx banks are 0.
static func _hpb_basis(h: float, p: float, b: float) -> Basis:
	var out := Basis(Vector3.UP, deg_to_rad(h)) * Basis(Vector3.RIGHT, deg_to_rad(p))
	if b != 0.0:
		out = out * Basis(Vector3.FORWARD, deg_to_rad(b))
	return out

# @element icBeamAvatar
func _add_beam(base: String, av: Dictionary) -> void:
	var sxyz: Array = av.get("scale_xyz", [1.0, 1.0, 1.0])
	var hpb: Array = av.get("hpb", [0.0, 0.0, 0.0])
	# the spinner nulls up the parent chain, innermost first: per parent,
	# three [frame, degrees] envelopes (h, p, b). A static parent becomes a
	# one-key envelope. The parents' animated SCALE is not read here -- it is
	# already this node's scale_keys (sfx.py resolve()); using both would
	# apply the envelope twice.
	var spinners: Array = []
	for p in av.get("parents", []):
		var par: Dictionary = p
		var hpb0: Array = par.get("hpb", [0.0, 0.0, 0.0])
		var chans: Array = [[], [], []]
		for k in par.get("keys", []):
			var key: Dictionary = k
			var khpb: Array = key.get("hpb", hpb0)
			for c in 3:
				(chans[c] as Array).append(
						[float(key.get("frame", 0.0)), float(khpb[c])])
		for c in 3:
			if (chans[c] as Array).is_empty():
				chans[c] = [[0.0, float(hpb0[c])]]
		spinners.append(chans)
	var tex := str(av.get("texture", BEAM_TEXTURE)).to_lower()
	var mi := MeshInstance3D.new()
	mi.mesh = _beam_quad_mesh()
	mi.mesh.surface_set_material(0, ParticleFx.additive_material(
			ParticleFx.texture(base, "images/sfx/" + tex)))
	add_child(mi)
	_beams.append({"node": mi,
			"dir": ExplosionFx._hpb_basis(float(hpb[0]), float(hpb[1]),
					float(hpb[2])) * Vector3.FORWARD,
			"width": float(sxyz[0]), "length": float(sxyz[2]),
			"keys": av.get("scale_keys", []), "spinners": spinners})

# unit beam quad: z 0..1 along the beam, x -1..1 across; u runs along the
# length and v across the width (0x100bbc6c..0x100bbd7e)
func _beam_quad_mesh() -> ArrayMesh:
	var verts := PackedVector3Array([
		Vector3(-1, 0, 0), Vector3(-1, 0, 1), Vector3(1, 0, 0),
		Vector3(1, 0, 0), Vector3(-1, 0, 1), Vector3(1, 0, 1),
	])
	var uvs := PackedVector2Array([
		Vector2(0, 0), Vector2(1, 0), Vector2(0, 1),
		Vector2(0, 1), Vector2(1, 0), Vector2(1, 1),
	])
	var cols := PackedColorArray()
	for i in 6:
		cols.append(Color(1, 1, 1, 1))
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_TEX_UV] = uvs
	arr[Mesh.ARRAY_COLOR] = cols
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return mesh

func _update_beams(cam: Camera3D) -> void:
	if _beams.is_empty():
		return
	var frame := _t * _fps
	for b in _beams:
		var beam: Dictionary = b
		var mi: MeshInstance3D = beam["node"]
		var keys: Array = beam["keys"]
		var scaler: float = _envelope(keys, frame) if not keys.is_empty() else 1.0
		if scaler <= 0.0:
			mi.visible = false
			continue
		mi.visible = true
		# the parent nulls spin the whole fan: beam -> *BeamsH -> *BeamsP ->
		# beam_scaler_*; each parent wraps the accumulated child rotation, so
		# compose innermost-first
		var group := Basis.IDENTITY
		for sp in beam["spinners"]:
			var chans: Array = sp
			group = ExplosionFx._hpb_basis(
					_envelope(chans[0], frame), _envelope(chans[1], frame),
					_envelope(chans[2], frame)) * group
		var dir: Vector3 = (global_transform.basis * (group * beam["dir"])).normalized()
		# axial billboard (0x100bba92..0x100bbb38): the quad turns about its
		# own axis to face the camera
		var to_cam := (cam.global_position - global_position).normalized()
		var side := dir.cross(to_cam)
		if side.length() < 0.001:
			continue
		side = side.normalized()
		var w: float = float(beam["width"]) * scaler * _size
		var length: float = float(beam["length"]) * scaler * _size
		mi.global_transform = Transform3D(
				Basis(side * w, side.cross(dir), dir * length), global_position)

# --- frame update ------------------------------------------------------------

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

	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	if cam != null:
		if not _movie_quads.is_empty():
			_update_movie()
		if not _shockwaves.is_empty():
			_update_shockwaves(cam.global_transform.basis)
		_update_beams(cam)
	_update_ldas()

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
	# icBeamAvatar (draw @ 0x100bb830) is an axial billboard: a single quad,
	# half-width scale.x, turned about the beam axis to face the camera.
	# Crossed quads are our static stand-in for that turn -- same footprint,
	# never edge-on. u runs along the length, v across the width.
	var tex := ParticleFx.texture(base, BOLT_TEXTURE)
	var mat := ParticleFx.additive_material(tex)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var half := BOLT_LENGTH * 0.5
	for axis in 2:
		# half-width = scale.x = 4 (the original quad spans pos +/- side*4)
		var w := Vector3(BOLT_WIDTH, 0, 0) if axis == 0 \
				else Vector3(0, BOLT_WIDTH, 0)
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
