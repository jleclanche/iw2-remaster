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

# Dynamics subclasses with their own behaviour (iwar2.dll; the base spray is
# FcParticleDynamics in flux.dll). See docs/act3.md for the recovery.
const DYN_ALIENSWARM := "icAlienSwarmDynamics"
const DYN_DISRUPTOR := "icDisruptorDynamics"
const DYN_TELEPORT := "icTeleportDynamics"

# @element icAlienSwarmDynamics
# The alien swarm (iwar2.dll ctor @ 0x100ba270, Spawn @ 0x100ba5d0, Update @
# 0x100ba9e0): every particle is a point on its own LORENZ ATTRACTOR run --
# sigma=10 (0x101190c0), rho=28 (0x1011c950), beta=8/3 (0x1011c94c) -- drawn at
# 0.05 x the state vector (ctor, +0x1c), with a point-mirrored twin through the
# emitter origin. Particles never die (Reset @ 0x100c4a40 is a bare ret and
# Update never ages them); min/max_death_age is reinterpreted as the SIZE range
# and angular_velocity as the colour-phase step (both per the INI's own
# comments). The engine caps the count at pool-block-size/52, which we cannot
# read; ALIEN_CAP is our stand-in.
const LORENZ_SIGMA := 10.0    # 0x101190c0
const LORENZ_RHO := 28.0      # 0x1011c950
const LORENZ_BETA := 8.0 / 3.0  # 2.66667 @ 0x1011c94c
const LORENZ_K := 0.0253      # 0x1011c8f4, times dt (dt clamp at 5.0 @ 0x101183f0)
const LORENZ_ARC := 0.5       # 0x10117738: substep until moved this much
const LORENZ_STEP_BIAS := 0.015  # 0x1011c948: caps the substep loop
const LORENZ_ESCAPE := 60.0   # 0x1011c958/54: |component| beyond this resets
const LORENZ_RESET := 0.7     # 0x101191e8: reset components to rand()*0.7
const LORENZ_SCALE := 0.05    # ctor +0x1c (0x3d4ccccd)
const ALIEN_CAP := 128        # pairs; engine pool size UNKNOWN

# @element icDisruptorDynamics
# The disruptor / LDSI / act-3 INFECTION crawl (iwar2.dll ctor @ 0x100c4900,
# Spawn @ 0x100c4e20 + 0x100c5a10, Update @ 0x100c4fe0, geometry intake @
# 0x100c5430). The host ship's model is broken into long polyline edges
# (radius/3 <= len < 2*radius, capped 25 m), subdivided one point per 25 m
# (0.04 @ 0x1011cebc). Particles spawn in TRIPLES anchored on an edge point:
# with follow_edge=1 (infection) they crawl along the edge at seglen/lifetime
# and jitter ALONG it; prob_jump is the chance a new triple starts at a random
# point instead of the next one. When a particle expires it respawns in place
# for as long as the emitter lives. Noise: a 128-entry [-1,1] table
# (0x101716fc), amplitude = sim_radius/120 capped 2.0 (0x1011cec0/0x10119ec8).
const EDGE_SUBDIV := 0.04     # 0x1011cebc: points per metre of edge
const EDGE_MINLEN_DIV := 3.0  # minLen = radius/3 (0x10119454)...
const EDGE_MINLEN_CAP := 25.0 # ...capped at 25 (0x1011a920)
const NOISE_AMP_DIV := 120.0  # 0x1011cec0 (1/120)
const NOISE_AMP_CAP := 2.0    # 0x10119ec8

# @element icTeleportDynamics
# The kibble / cornflake_field ambient dust (iwar2.dll ctor @ 0x100c8870,
# Spawn @ 0x100c8c80, Update @ 0x100c91f0). "Teleport" is about the CAMERA
# teleporting, not the particles: the field is a shell of world-fixed motes
# around the viewpoint (radius = max(viewport dimension) x draw radius x 0.5)
# that spawn ahead of travel (cone 0.2 when speed >= 1 m/s), spin at a random
# rate in [0, angular_velocity] (deg/s in the INI, 0x10119930 converts), and
# are culled outside the shell or closer than 5 m (0x1011cf68). A frame that
# moves further than the shell radius flushes every particle; jumps <= 2000 m
# (0x1011cfb4: 4e6 = 2000^2) refill the whole field at once, bigger jumps
# (LDS, capsule) leave it to regrow at the birth rate.
const TP_MOVE_STEP2 := 10.0   # 0x101190c0: spawn every sqrt(10) m of travel
const TP_NEAR := 5.0          # 0x1011cf68: cull inside this
const TP_JUMP2 := 4.0e6       # 0x1011cfb4: flush-without-refill beyond 2 km
const TP_SWING := PI / 2.0    # 0x1011a454: camera swing rate for a burst...
const TP_SWING_FRAC := 0.4    # 0x10117558: ...that emits 40% of the cap
const TP_CONE := 0.2          # 0x3e4ccccd @ 0x100c9589: spawn cone ahead

# cornflakes.png / cornflake_masks.png are a 4x4 atlas of torn hull plates.
const CORNFLAKE_CELLS := 4

# icCornflakeDraw's draw (iwar2.dll @ 0x100bc620, recovered by raw
# disassembly -- docs/effects.md section 6): a flake is a 2:1 rectangle of
# half-extents size x size/2, where size = 0.075 (0x1011cb98) * the emitter
# scale. It is NOT a billboard: it TUMBLES in 3D, rotated by the particle's
# accumulated roll angle about one of FOUR random unit axes (chosen by
# particle index & 3; the class precomputes 256 rotation steps per axis at
# 2pi/256 = 0x1011cb90). The atlas cell is particle index & 15 -- sequential,
# not random (UV table @ 0x1011ca58). The flake is LIT: its colour is
# (normal . world_light_dir)^2 grey (0x100bc6f1..0x100bc89d), alpha-blended
# (sPolygonState @ 0x101682c8: blend 3 = SRCALPHA/INVSRCALPHA) WITH z-write.
const CORNFLAKE_SIZE := 0.075

static var _systems: Dictionary = {}
static var _textures: Dictionary = {}
static var _meshes: Dictionary = {}

var sys: Dictionary = {}
var emitter_scale := 1.0
var emitter_vel := Vector3.ZERO
# icDisruptorDynamics hosts: the infected/disrupted hull whose edges the
# particles crawl (geometry intake @ 0x100c5430 gets the sim's models and its
# radius)
var host_model: Node3D = null
var host_radius := 0.0
var _age := 0.0
var _accum := 0.0        # fractional particles owed, FcParticleDynamics+0x48
var _spawned := 0        # total ever spawned, +0x4c (the `once` budget)
var _live: Array = []    # {life, pos, vel, roll, spin, cell, axis}
var _edges: Array = []   # icDisruptorDynamics: {pos, dir, seglen} in our space
var _edge_cursor := 0    # +0x90
var _noise := PackedFloat32Array()  # the 128-float [-1,1] table @ 0x101716fc
var _tp_accum := Vector3.ZERO       # icTeleportDynamics +0x40: movement owed
var _tp_prev_fwd := Vector3.ZERO    # +0x4c: last camera forward
var _mm: MultiMeshInstance3D
var _models: Array = []  # FcParticleDrawModel: one child per live particle
# icCornflakeDraw's four random tumble axes (FUN_100bc480 @ 0x100bc480)
var _flake_axes: Array = []
var _sun_dir := Vector3(0, 0, -1)
var _sun_dir_found := false

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

# @element icCornflakeDraw
# icCornflakeDraw draws hull-plate art, not light: alpha-blended with z-write
# (sPolygonState @ 0x101682c8, blend 3) with the mask sheet as the cutout.
# The atlas cell rides in the multimesh's custom data.
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
		# icDisruptorDynamics only (property map @ 0x100c46f0; its
		# speed/cone_angle/angular_velocity INI keys are dead)
		"prob_jump": _num(dyn, "prob_jump", 0.0),
		"follow_edge": _num(dyn, "follow_edge", 0.0) != 0.0,
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

# An icDisruptorDynamics effect glued to a hull: iiThrusterSim::
# AlienInfectionEffect (0x1007ed80) creates ini:/sfx/infection/node, hands it
# the sim's models and radius (FUN_100c3ce0 -> intake 0x100c5430), scales the
# node by max(1, radius/15) and attaches it to the avatar. icDisruptor (the
# weapon effect) does the same with /25 and a finite emitter time.
static func spawn_on_model(parent: Node3D, base: String, name: String,
		model: Node3D, sim_radius: float, scale: float) -> ParticleFx:
	var fx := spawn(parent, base, name,
			Transform3D(Basis.IDENTITY, parent.global_position), scale)
	if fx == null:
		return null
	fx.host_model = model
	fx.host_radius = sim_radius
	fx._build_edges()
	return fx

# The geometry intake (0x100c5430): consecutive model points whose spacing is
# a LONG structural edge -- between radius/3 (capped 25 m, 0x10119454 /
# 0x1011a920) and 2 x radius -- subdivided one anchor per 25 m (0.04 @
# 0x1011cebc). We walk each mesh surface's vertex order, which is the closest
# Godot analogue of the engine's model point iterator (UNKNOWN: the original
# iterator's exact traversal; docs/act3.md).
func _build_edges() -> void:
	_edges.clear()
	if host_model == null or not is_instance_valid(host_model):
		return
	var min_len := minf(host_radius / EDGE_MINLEN_DIV, EDGE_MINLEN_CAP)
	var max_len := 2.0 * host_radius
	var inv := global_transform.affine_inverse()
	for child in host_model.find_children("*", "MeshInstance3D", true, false):
		var mi := child as MeshInstance3D
		if mi.mesh == null:
			continue
		var xf: Transform3D = inv * mi.global_transform
		for s in mi.mesh.get_surface_count():
			var arrays := mi.mesh.surface_get_arrays(s)
			var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			for i in range(1, verts.size()):
				var a: Vector3 = xf * verts[i - 1]
				var b: Vector3 = xf * verts[i]
				var d := a - b
				var l := d.length()
				if l <= min_len or l >= max_len:
					continue
				var dir := d / l
				var nsub := int(l * EDGE_SUBDIV) + 1
				var step := l / float(nsub)
				for k in nsub:
					_edges.append({"pos": b + dir * (step * k), "dir": dir,
							"seglen": step})
	if _noise.is_empty():
		# the shared 128-entry noise table (ctor 0x100c4900, values
		# rand()/32767 * 2 - 1 into 0x101716fc)
		_noise.resize(128)
		for i in 128:
			_noise[i] = randf() * 2.0 - 1.0

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
	if sys["dyn_class"] == DYN_ALIENSWARM:
		# every alien particle draws twice: itself and its point-mirrored twin
		# (vector B, filled at 0x100bad20 with pos = -pos)
		_mm.multimesh.instance_count = ALIEN_CAP * 2
	else:
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
	if sys["dyn_class"] == DYN_TELEPORT:
		return  # emission is movement-driven, inside _update_teleport
	if sys["time"] > 0.0 and _age >= sys["time"]:
		return
	var cap: int = sys["max_particles"]
	if sys["dyn_class"] == DYN_ALIENSWARM:
		# icAlienSwarmDynamics::Spawn (0x100ba5d0) ignores max_particles: the
		# cap is the allocator pool block / 52 (UNKNOWN; ALIEN_CAP stands in)
		cap = ALIEN_CAP
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
	if sys["dyn_class"] == DYN_ALIENSWARM:
		_spawn_alien()
		return
	if sys["dyn_class"] == DYN_DISRUPTOR:
		_spawn_disruptor_triple()
		return
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
		# icCornflakeDraw picks both by particle index, not at random
		# (0x100bc783 / 0x100bc7a3): cell = index & 15, tumble axis = index & 3
		"cell": _spawned % (CORNFLAKE_CELLS * CORNFLAKE_CELLS),
		"axis": _spawned % 4,
		"model": null,
	})
	_spawned += 1

# icAlienSwarmDynamics::Spawn @ 0x100ba5d0. The Lorenz state vector starts as
# a unit vector inside cone_angle (360 deg in the shipped data: fully random);
# `speed` is a registered property the code never reads (dead key). Death age
# is repurposed as the particle's SIZE ("For aliens, this is the range of
# sizes" -- the INI's own comment), picked plain-uniform, not centre-weighted.
# Each particle also gets a mirrored twin through the emitter origin.
func _spawn_alien() -> void:
	var cone := deg_to_rad(float(sys["cone"]))
	var pitch := ParticleFx.centre_weighted(-cone, cone)
	var yaw := ParticleFx.centre_weighted(-cone, cone)
	var v := (Basis.from_euler(Vector3(pitch, yaw, 0.0)) * Vector3(0, 0, 1)) \
			.normalized()
	# angular_velocity is the colour-phase step: uniform in [av/2, av]
	# (0x10117738); the axis permutation is uniform over 0/1/2 (1/3 @
	# 0x1011c944, 2/3 @ 0x1011c940)
	var av: float = sys["spin"]
	_live.append({
		"life": INF,  # alien particles are never aged and never die
		"v": v,
		"perm": randi() % 3,
		"axis": _spawned % 4,  # icCornflakeDraw tumble axis, by index
		"phase": randf(),               # rand()/32768 (3.05185e-05 @ 0x10118494)
		"phase_step": lerpf(av * 0.5, av, randf()),
		"size": lerpf(sys["min_life"], sys["max_life"], randf()),
		"pos": Vector3.ZERO,
		"vel": Vector3.ZERO,
		"roll": 0.0,
		"spin": 0.0,
		"cell": _spawned % (CORNFLAKE_CELLS * CORNFLAKE_CELLS),
		"model": null,
	})
	_spawned += 1

# icAlienSwarmDynamics::Update @ 0x100ba9e0: integrate each particle's Lorenz
# system in adaptive substeps until it has moved a roughly constant arc, then
# place it at LORENZ_SCALE x an axis permutation of the state. Positions are
# emitter-local (alienswarm/emitter.ini: fixed_particles=1); emitter_scale is
# the swarm avatar's scale, which icAlienSwarm::UpdateAvatar (0x1002c1f0)
# drives with the ship's radius.
func _update_alien(delta: float) -> void:
	var k := LORENZ_K * (delta if delta < 5.0 else 1.0)
	for p in _live:
		var v: Vector3 = p["v"]
		if absf(v.x) > LORENZ_ESCAPE or absf(v.y) > LORENZ_ESCAPE \
				or absf(v.z) > LORENZ_ESCAPE:
			v = Vector3(randf(), randf(), randf()) * LORENZ_RESET
		var total := 0.0
		while total < LORENZ_ARC:
			var dx := k * LORENZ_SIGMA * (v.y - v.x)
			var dy := k * (LORENZ_RHO * v.x - v.x * v.z - v.y)
			var dz := k * (v.x * v.y - LORENZ_BETA * v.z)
			v += Vector3(dx, dy, dz)
			total += dx * dx + dy * dy + dz * dz + LORENZ_STEP_BIAS
		p["v"] = v
		var phase: float = p["phase"] + p["phase_step"]
		if phase > 1.0 or phase < 0.0:
			phase -= p["phase_step"]
			p["phase_step"] = -p["phase_step"]
		p["phase"] = phase
		var s := LORENZ_SCALE * emitter_scale
		match int(p["perm"]):
			1:
				p["pos"] = Vector3(v.x, v.z, v.y) * s
			2:
				p["pos"] = Vector3(v.z, v.y, v.x) * s
			_:
				p["pos"] = Vector3(v.x, v.y, v.z) * s

# icDisruptorDynamics::SpawnTriple (FUN_100c5a10 @ 0x100c5a10). One emission
# unit is a TRIPLE of particles on one edge anchor: with follow_edge=1 the
# leader A and its copy B crawl along the edge at seglen/lifetime and C rides
# one sub-segment ahead of B; with follow_edge=0 they sit at 1/3 and 2/3 of
# the sub-segment and only jitter. prob_jump picks a random anchor instead of
# the next one (crawl: cursor+1 mod count).
func _spawn_disruptor_triple() -> void:
	if _edges.is_empty():
		return
	if randf() >= float(sys["prob_jump"]):
		_edge_cursor = (_edge_cursor + 1) % _edges.size()
	else:
		_edge_cursor = randi() % _edges.size()
	# lifetime is plain-uniform in [min, max] death age, NOT centre-weighted
	var life := lerpf(float(sys["min_life"]), float(sys["max_life"]), randf())
	var e: Dictionary = _edges[_edge_cursor]
	var follow: bool = sys["follow_edge"]
	var vel: Vector3 = (e["dir"] as Vector3) * (float(e["seglen"]) / maxf(life, 1e-3)) \
			if follow else Vector3.ZERO
	for role in 3:
		var pos: Vector3 = e["pos"]
		if not follow:
			# 1/3 and 2/3 along the sub-segment (0x1011cec8 / 0x1011cec4)
			pos += (e["dir"] as Vector3) * (float(e["seglen"]) * 0.333 * float(role + 1))
		_live.append({
			"life": life, "life_max": life, "edge": _edge_cursor, "role": role,
			"pos": pos, "vel": vel, "roll": 0.0, "spin": 0.0,
			"cell": _spawned % (CORNFLAKE_CELLS * CORNFLAKE_CELLS),
			"axis": _spawned % 4, "model": null,
		})
		_spawned += 1

# icDisruptorDynamics::Update (0x100c4fe0) + NoiseKick (FUN_100c5f30):
# tick lifetimes (respawn in place while the emitter lives -- infection's
# emitter time is 0, eternal), crawl, and jitter by the noise table at
# amplitude (radius/120 capped 2) x sub-segment length, ~50% sign-flipped.
# follow_edge constrains the jitter to the edge direction.
func _update_disruptor(delta: float) -> void:
	var emitter_alive: bool = sys["time"] <= 0.0 or _age < sys["time"]
	var amp := minf(host_radius / NOISE_AMP_DIV, NOISE_AMP_CAP)
	var dtc := maxf(delta, 0.01)  # 0x1011a70c
	var follow: bool = sys["follow_edge"]
	var noise_idx := (randi() % 0xa2) >> 1
	var i := 0
	while i + 2 < _live.size():
		var a: Dictionary = _live[i]
		var b: Dictionary = _live[i + 1]
		var c: Dictionary = _live[i + 2]
		a["life"] = float(a["life"]) - delta
		if float(a["life"]) < 0.0:
			if emitter_alive:
				_respawn_triple(a, b, c)
			else:
				_live.remove_at(i + 2)
				_live.remove_at(i + 1)
				_live.remove_at(i)
				continue
		var e: Dictionary = _edges[int(a["edge"])] if not _edges.is_empty() \
				else {"pos": Vector3.ZERO, "dir": Vector3.FORWARD, "seglen": 0.0}
		var kick_scale := amp * float(e["seglen"]) * dtc
		for p in [a, b]:
			p["pos"] = (p["pos"] as Vector3) + (p["vel"] as Vector3) * delta
			var kick := Vector3(_noise[noise_idx % 128], _noise[(noise_idx + 1) % 128],
					_noise[(noise_idx + 2) % 128]) * kick_scale
			if (randi() % 0xca & ~1) > 100:
				kick = -kick
			if follow:
				p["pos"] = (p["pos"] as Vector3) + kick * (e["dir"] as Vector3)
			else:
				p["pos"] = (p["pos"] as Vector3) + kick
				p["vel"] = Vector3.ZERO
			noise_idx = (noise_idx + 1) % 125
		c["pos"] = (b["pos"] as Vector3) + (e["dir"] as Vector3) * float(e["seglen"])
		c["life"] = a["life"]
		b["life"] = a["life"]
		i += 3

func _respawn_triple(a: Dictionary, b: Dictionary, c: Dictionary) -> void:
	# SpawnTriple with bucket == -1: re-anchor the same three slots
	if _edges.is_empty():
		return
	if randf() >= float(sys["prob_jump"]):
		_edge_cursor = (_edge_cursor + 1) % _edges.size()
	else:
		_edge_cursor = randi() % _edges.size()
	var life := lerpf(float(sys["min_life"]), float(sys["max_life"]), randf())
	var e: Dictionary = _edges[_edge_cursor]
	var follow: bool = sys["follow_edge"]
	var vel: Vector3 = (e["dir"] as Vector3) * (float(e["seglen"]) / maxf(life, 1e-3)) \
			if follow else Vector3.ZERO
	var role := 0
	for p in [a, b, c]:
		p["life"] = life
		p["life_max"] = life
		p["edge"] = _edge_cursor
		p["vel"] = vel
		p["pos"] = e["pos"] if follow else (e["pos"] as Vector3) \
				+ (e["dir"] as Vector3) * (float(e["seglen"]) * 0.333 * float(role + 1))
		role += 1

# icTeleportDynamics::Update (0x100c91f0) + Spawn (0x100c8c80). Runs in the
# folded scene space where the player IS the focus, so the world movement the
# engine reads from GraphicsDeltaFocus arrives here through shift_world().
func _update_teleport(delta: float) -> void:
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	if cam == null or delta <= 0.0:
		return
	# field radius: max viewport dimension x the draw's radius x 0.5. The
	# draw's Radius slot returns its scale (FcParticleDrawModel) or
	# scale_on_death; icCornflakeDraw's is UNKNOWN (docs/act3.md).
	var vp := get_viewport().get_visible_rect().size
	var draw_r: float = sys["model_scale"] if sys["draw_class"] == DRAW_MODEL \
			else sys["scale_death"]
	var r := maxf(vp.x, vp.y) * draw_r * 0.5
	var cam_pos := cam.global_position
	# cull + spin
	var i := _live.size() - 1
	var r2 := r * r
	while i >= 0:
		var p: Dictionary = _live[i]
		p["roll"] = float(p["roll"]) + float(p["spin"]) * delta
		var d2: float = ((p["pos"] as Vector3) - cam_pos).length_squared()
		if d2 > r2 or d2 < TP_NEAR * TP_NEAR:
			_live.remove_at(i)
		i -= 1
	# spawn: driven by accumulated world movement (shift_world feeds _tp_accum)
	var jump2 := _tp_accum.length_squared()
	var burst := 0
	if jump2 > r2:
		_live.clear()
		_tp_accum = Vector3.ZERO
		if jump2 > TP_JUMP2:
			return  # a capsule/LDS jump: the field regrows at the birth rate
		burst = int(sys["max_particles"])
	elif _tp_accum.length_squared() >= TP_MOVE_STEP2:
		var fwd := -cam.global_transform.basis.z
		var swing := acos(clampf(fwd.dot(_tp_prev_fwd), -1.0, 1.0)) / delta
		_tp_prev_fwd = fwd
		if swing > TP_SWING:
			burst = int(float(sys["max_particles"]) * TP_SWING_FRAC)
		else:
			_accum += ParticleFx.centre_weighted(sys["min_rate"], sys["max_rate"]) \
					* delta
			burst = int(_accum)
			_accum -= float(burst)
		var speed := _tp_accum.length() / maxf(delta, 1e-4)
		var dir := _tp_accum.normalized()
		_tp_accum = Vector3.ZERO
		var cap: int = sys["max_particles"]
		for k in mini(burst, cap - _live.size()):
			_spawn_teleport(cam_pos, dir, speed, r)
		return
	var cap2: int = sys["max_particles"]
	for k in mini(burst, cap2 - _live.size()):
		_spawn_teleport(cam_pos, -cam.global_transform.basis.z, 0.0, r)

# SpawnPos (FUN_100c94b0): ahead of travel inside cone 0.2 when moving at
# >= 1 m/s; a uniform shell when drifting; radius uniform in [0.1 r, r] when
# still (0x101184b0). Spin uniform in [0, angular_velocity] (deg/s).
func _spawn_teleport(cam_pos: Vector3, dir: Vector3, speed: float, r: float) -> void:
	var pos: Vector3
	if speed >= 1.0:
		var cone := TP_CONE
		var off := Vector3(ParticleFx.centre_weighted(-cone, cone),
				ParticleFx.centre_weighted(-cone, cone), 1.0).normalized()
		# travel direction is -delta-focus: the engine spawns AHEAD of travel
		pos = cam_pos + Basis.looking_at(-dir, Vector3.UP) * (off * -r)
	elif speed >= 1e-6:
		pos = cam_pos + _random_unit() * r
	else:
		pos = cam_pos + _random_unit() * (r * lerpf(0.1, 1.0, randf()))
	var av: float = sys["spin"]
	_live.append({
		"life": INF, "pos": pos, "vel": Vector3.ZERO,
		"roll": randf() * TAU,
		"spin": deg_to_rad(av * randf()),
		"cell": _spawned % (CORNFLAKE_CELLS * CORNFLAKE_CELLS),
		"axis": _spawned % 4, "model": null,
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
	if sys["dyn_class"] == DYN_ALIENSWARM:
		# alien particles never age or die (Update @ 0x100ba9e0 has no death
		# path and Reset @ 0x100c4a40 is a bare ret)
		_update_alien(delta)
		_draw_billboards()
		return
	if sys["dyn_class"] == DYN_DISRUPTOR:
		_update_disruptor(delta)
		_draw_billboards()
		return
	if sys["dyn_class"] == DYN_TELEPORT:
		_update_teleport(delta)
		if sys["draw_class"] == DRAW_MODEL:
			_draw_models()
		else:
			_draw_billboards()
		return
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
	# icTeleportDynamics positions are scene-absolute despite the emitter's
	# fixed_particles=2 -- the class manages the focus shift itself
	var world_space: bool = (not sys["fixed"]) \
			or sys["dyn_class"] == DYN_TELEPORT
	var origin := Vector3.ZERO if world_space else global_position
	var emit_scale: float = emitter_scale if sys["scale_by_emitter"] else 1.0
	var fade := 1.0
	if sys["fade_on_emitter_age"] and sys["time"] > 0.0:
		fade = clampf(_age / sys["time"], 0.0, 1.0)
	var flake: bool = sys["draw_class"] == DRAW_CORNFLAKE
	if flake and _flake_axes.is_empty():
		# FUN_100bc480 (@ 0x100bc480) rolls four random unit axes when the
		# first cornflake system is created
		for k in 4:
			_flake_axes.append(_random_unit())
	if sys["dyn_class"] == DYN_ALIENSWARM:
		_draw_alien(cb)
		return
	var n := mini(_live.size(), _mm.multimesh.instance_count)
	for i in n:
		var p: Dictionary = _live[i]
		var t := _ramp_t(p["life"])
		var size: float = lerpf(sys["scale_birth"], sys["scale_death"], t) * emit_scale
		var b: Basis
		var c: Color
		if flake:
			# a tumbling world-space plate, not a billboard: the particle's
			# roll angle turned about its tumble axis, half-extents size x
			# size/2 (0x100bc767 / 0x10117738)
			size = CORNFLAKE_SIZE * emitter_scale
			var axis: Vector3 = _flake_axes[p["axis"]]
			var rot := Basis(axis, p["roll"])
			# lit by the world light: colour = (normal . light)^2 grey
			var d := absf(rot.z.dot(_light_dir()))
			c = Color(d * d, d * d, d * d)
			b = Basis(rot.x * size, rot.y * (size * 0.5), rot.z * size)
		else:
			b = cb.rotated(cb.z, p["roll"]).scaled(Vector3(size, size, size))
			c = _ramp_colour(t)
		_mm.multimesh.set_instance_transform(i,
				Transform3D(b, origin + p["pos"] - global_position))
		_mm.multimesh.set_instance_color(i, Color(c.r * fade, c.g * fade, c.b * fade))
		if _mm.multimesh.use_custom_data:
			var cell: int = p["cell"]
			_mm.multimesh.set_instance_custom_data(i, Color(
					float(cell % CORNFLAKE_CELLS) / CORNFLAKE_CELLS,
					float(cell / CORNFLAKE_CELLS) / CORNFLAKE_CELLS,
					1.0 / CORNFLAKE_CELLS, 0.0))
	_mm.multimesh.visible_instance_count = n

# The alien swarm draws through icCornflakeDraw (alienswarm/node.ini points
# draw at ini:/sfx/cornflakes/draw): tumbling lit hull-flakes, 0.075 x the
# emitter scale (0x1011cb98), atlas cell by particle index. Each particle and
# its mirrored twin (icAlienSwarmDynamics vector B) both draw. Positions are
# emitter-LOCAL and the engine never rotates them by the emitter's basis
# (fixed_particles without respect_orientation), so the parent ship's spin is
# cancelled here. The size range in min/max_death_age and the colour phase
# only feed icAlienSwarmDraw's gradient -- a draw class no shipped INI uses --
# so with the cornflake draw they are dormant (docs/act3.md).
func _draw_alien(_cb: Basis) -> void:
	if _flake_axes.is_empty():
		for k in 4:
			_flake_axes.append(_random_unit())
	var inv := global_transform.basis.inverse()
	var size := CORNFLAKE_SIZE * emitter_scale
	var n := mini(_live.size(), _mm.multimesh.instance_count / 2)
	for i in n:
		var p: Dictionary = _live[i]
		var axis: Vector3 = _flake_axes[int(p["axis"]) % 4]
		var rot := Basis(axis, p["roll"])
		var d := absf(rot.z.dot(_light_dir()))
		var c := Color(d * d, d * d, d * d)
		var b := inv * Basis(rot.x * size, rot.y * (size * 0.5), rot.z * size)
		for twin in 2:
			var at: Vector3 = p["pos"] if twin == 0 else -(p["pos"] as Vector3)
			var idx := i * 2 + twin
			_mm.multimesh.set_instance_transform(idx, Transform3D(b, inv * at))
			_mm.multimesh.set_instance_color(idx, c)
			if _mm.multimesh.use_custom_data:
				var cell: int = p["cell"]
				_mm.multimesh.set_instance_custom_data(idx, Color(
						float(cell % CORNFLAKE_CELLS) / CORNFLAKE_CELLS,
						float(cell / CORNFLAKE_CELLS) / CORNFLAKE_CELLS,
						1.0 / CORNFLAKE_CELLS, 0.0))
	_mm.multimesh.visible_instance_count = n * 2

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
			if sys["fixed"] and sys["dyn_class"] != DYN_TELEPORT:
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

static func _random_unit() -> Vector3:
	# FnRandom::UnitVector
	var v := Vector3(randfn(0.0, 1.0), randfn(0.0, 1.0), randfn(0.0, 1.0))
	return v.normalized() if v.length() > 0.0001 else Vector3.UP

# the world light the original lights cornflakes with (FcWorld+0x60c) is the
# system's sun; ours is the scene's DirectionalLight3D
func _light_dir() -> Vector3:
	if not _sun_dir_found:
		_sun_dir_found = true
		var lights := get_tree().root.find_children("*", "DirectionalLight3D",
				true, false)
		if not lights.is_empty():
			_sun_dir = -(lights[0] as DirectionalLight3D) \
					.global_transform.basis.z
	return _sun_dir

# floating origin: our parent node is moved for us, but particles that were
# left behind in world space (fixed_particles = 0) hold absolute positions
func shift_world(offset: Vector3) -> void:
	if sys.get("dyn_class", "") == DYN_TELEPORT:
		# icTeleportDynamics keeps its motes world-fixed by adding the
		# graphics delta-focus every tick (Update @ 0x100c91f0) and feeds the
		# same movement into its spawn logic (+0x40 accumulator) -- the fold
		# offset IS our delta focus
		_tp_accum += offset
		for p in _live:
			p["pos"] -= offset
		return
	if sys.get("fixed", true):
		return
	for p in _live:
		p["pos"] -= offset
