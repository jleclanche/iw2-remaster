class_name ExplosionFx
extends Node3D
# The original's ship kill: sfx/explosion_high_*.lws = a 50-frame "deba"
# fireball flipbook (icMovieAvatar, images/sfx/deba00..49), a cornflakes
# debris shower, a spark shower and a shockwave ring, with the
# large_explosion WAVs. Rebuilt here from the extracted frames.

const FRAME_COUNT := 50
const FPS := 25.0

static var _frames: Array = []       # ImageTexture flipbook, loaded once
static var _spark_tex: Texture2D = null
static var _shock_tex: Texture2D = null

var _t := 0.0
var _size := 60.0
var _fire: MeshInstance3D
var _fire_mat: StandardMaterial3D
var _shock: MeshInstance3D
var _shock_mat: StandardMaterial3D
var _sparks: Array = []  # {node, vel, mat}

static func _load_tex(base: String, rel: String) -> Texture2D:
	var path := base.path_join("data/textures/images/sfx").path_join(rel)
	if not FileAccess.file_exists(path):
		return null
	var img := Image.load_from_file(path)
	return null if img == null else ImageTexture.create_from_image(img)

static func _ensure_frames(base: String) -> void:
	if not _frames.is_empty():
		return
	for i in FRAME_COUNT:
		var tex := _load_tex(base, "deba%02d.png" % i)
		if tex != null:
			_frames.append(tex)
	_spark_tex = _load_tex(base, "spark.png")
	_shock_tex = _load_tex(base, "shockwave.png")

static func boom(main: Node3D, pos: Vector3, size: float) -> void:
	_ensure_frames(main._base())
	var fx: ExplosionFx = ExplosionFx.new()
	fx._size = size
	main.add_child(fx)
	fx.global_position = pos
	main.audio.play("audio/sfx/large_explosion_%d.wav"
		% (randi() % 3 + 1), -2.0)

func _billboard_mat(tex: Texture2D) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mat.albedo_texture = tex
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	return mat

func _quad(size: float, mat: StandardMaterial3D) -> MeshInstance3D:
	var mesh := QuadMesh.new()
	mesh.size = Vector2(size, size)
	mesh.material = mat
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	add_child(mi)
	return mi

func _ready() -> void:
	if _frames.is_empty():
		queue_free()
		return
	_fire_mat = _billboard_mat(_frames[0])
	_fire = _quad(_size * 2.6, _fire_mat)
	_fire.rotate_z(randf() * TAU)
	if _shock_tex != null:
		_shock_mat = _billboard_mat(_shock_tex)
		_shock = _quad(_size * 1.2, _shock_mat)
	if _spark_tex != null:
		var rng := RandomNumberGenerator.new()
		for i in 14:
			var mat := _billboard_mat(_spark_tex)
			var s := _quad(_size * rng.randf_range(0.10, 0.25), mat)
			var dir := Vector3(rng.randf_range(-1, 1), rng.randf_range(-1, 1),
				rng.randf_range(-1, 1)).normalized()
			_sparks.append({"node": s, "mat": mat,
				"vel": dir * _size * rng.randf_range(0.8, 2.6)})
	# a flash of light on the surroundings
	var l := OmniLight3D.new()
	l.light_color = Color(1.0, 0.75, 0.4)
	l.light_energy = 6.0
	l.omni_range = _size * 12.0
	add_child(l)
	var tw := create_tween()
	tw.tween_property(l, "light_energy", 0.0, 0.9)

func _process(delta: float) -> void:
	_t += delta
	var fi := int(_t * FPS)
	if fi >= _frames.size():
		queue_free()
		return
	_fire_mat.albedo_texture = _frames[fi]
	var life := _t / (FRAME_COUNT / FPS)  # 0..1
	_fire.scale = Vector3.ONE * (1.0 + life * 0.9)
	if _shock != null:
		_shock.scale = Vector3.ONE * (1.0 + life * 7.0)
		_shock_mat.albedo_color.a = clampf(1.0 - life * 1.6, 0.0, 1.0)
	for s in _sparks:
		(s["node"] as Node3D).position += (s["vel"] as Vector3) * delta
		(s["mat"] as StandardMaterial3D).albedo_color.a = \
			clampf(1.0 - life * 1.3, 0.0, 1.0)
