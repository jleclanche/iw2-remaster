class_name CapsuleFx
extends Node3D

# @element icCapsuleSpaceAvatar
# @element icCapsuleSpaceSystem
# @element icCapsuleSpace
# @element icCapsuleEntryBlankAvatar
# @element icCapsuleEffectNode
# (the manager is main.gd's jump_state machine; the entry blank and its
#  flicker envelope -- FUN_100bef90's keys, _flash_flicker -- live in main.gd
#  states 3/5; this node is the tunnel itself)
#
# Capsule space: the mini-world the ship flies through between systems.
# icCapsuleSpaceSystem (ctor iwar2 @ 0x100480b0) is a real icSolarSystem
# subclass owned by icCluster (+0x2c); its whole content is one
# icCapsuleSpaceAvatar (factory 0x100c05a0, ctor 0x100c1be0, 0xdfa8 bytes),
# re-anchored to the CAMERA position with identity orientation every frame
# (icCapsuleSpaceSystem::Render @ 0x100481e0). This node is that avatar: it
# follows main.cam while active, with the basis frozen to the ship's frame at
# tunnel entry (SendShipDownTunnel @ 0x10043740 resets the ship to the
# identity orientation inside capsule space, so tunnel axis == ship forward).
#
# The tunnel is 99 rings (ctor loop @ 0x100c1be0), each a 32-point radius
# random-walk polygon (built by FUN_100c0700 @ 0x100c0700), spaced 1000 m
# apart (_DAT_1011945c) over a 99 km span (_DAT_1011cd68), streaming past the
# viewer at 7000 m/s (_DAT_1011cd7c, per-frame step clamped to 1000 m,
# _DAT_1011cd78; FUN_100c0d80). A ring that falls 36 km behind
# (_DAT_1011cd80) respawns at the front (FUN_100c11e0 @ 0x100c11e0).
# Rings alternate radius bands (FUN_100c1170 passes 2-(i&1)):
#   even: outer, radius walked in [960, 1000]   (DAT_1011cd58=1000, -40)
#   odd:  inner, radius walked in [600, 640]    (DAT_1011cd54=600, +40)
# (_DAT_1011849c = 40 is the band width). Ring centres scatter around the
# axis (initial walk, clamp derived from 600 * 0.2 = 120, _DAT_101188e8) and
# jitter +-15 m every frame (_DAT_101183ec, FUN_100c0d80).
#
# Draw (@ 0x100c1dd0, vtable 0x1011cd88 slot 16) is three passes:
#   1. walls, texture:/images/sfx/capsule_tunnel  (table @ 0x101619e4),
#      colour (1.0, 0.52, 0.01), radial scale 1.0, V scrolled by -scroll
#   2. walls, capsule_tunnel2, colour (0.83, 0.10, 0.01), radial scale 1.07
#      (0x3f88f5c3), V scrolled by +scroll  (scroll += dt * 0.001,
#      _DAT_1011803c, FUN_100c11e0)
#   3. beams, capsule_beam: three ribbon strips threaded down the ring
#      centres (FUN_100c1570), half-width per ring in [180, 460]
#      (_DAT_10119920, _DAT_1011cd70), directions (1,0,0) / (1,1,0) /
#      (-1,1,0), colours white and (1.0, 1.0, 0.5); the pass is drawn twice
#      (Draw calls FUN_100c1460 twice back to back).
# Vertex alpha is engine[0x1790] * 0.5 (FUN_100c0ec0); we bake 0.5.
# Wall UVs (FUN_100c0ec0 vertex slots 7/8): U = wobble-envelope value per
# ring point (envelope built @ 0x100c2040: keys every 1/27 alternating
# rand[0.5,1] / rand[0,0.5], sampled at i * 0.030303 = _DAT_1011cd74),
# V = per-ring phase (outer rings rand[0.5,0.8], inner rand[0,0.3],
# FUN_100c0700) plus the scroll.
#
# Dressing (built once in FUN_100c2040 @ 0x100c2040):
#   - two big end flares at z = +-90000 (_DAT_1011cd5c), size 10000
#     (0x461c4000), colour (1.0, 0.47, 0.03), brightness envelope 0.2
#   - 99 small flares (one per ring), brightness 0.05, same colour
#   - one directional light, colour (0.9, 0.43, 0.0) (DAT_101715e8/ec/f0),
#     re-randomised in orientation EVERY frame (Prepare @ 0x100c1d30 calls
#     FnRandom::Orientation) - a flickering orange wash
# PLACEHOLDER: FcLensFlareNode's sprite sizing/atlas (type ids 1/9/0x2b) is
# not recovered; the flares here are additive billboard quads with a
# procedural radial texture, sized to read at the recovered ranges.

const SEGS := 99                 # ctor 0x100c1be0
const RING_PTS := 32             # FUN_100c0700 builds 0x20 points
const SPACING := 1000.0          # _DAT_1011945c
const HALF_LEN := 49500.0        # FUN_100c1170 starts at z = -49500
const TUNNEL_SPEED := 7000.0     # _DAT_1011cd7c (sign folded into our frame)
const MAX_STEP := 1000.0         # _DAT_1011cd78 per-frame clamp
const CULL_BEHIND := 36000.0     # _DAT_1011cd80
const R_OUTER := 1000.0          # DAT_1011cd58
const R_INNER := 600.0           # DAT_1011cd54
const BAND := 40.0               # _DAT_1011849c
const CENTER_CLAMP := 120.0      # 600 * 0.2, _DAT_101188e8
const CENTER_WALK := 10.0        # _DAT_101190c0, spawn-to-spawn centre walk
const JITTER := 15.0             # _DAT_101183ec, per-frame centre jitter
const SCROLL_RATE := 0.001       # _DAT_1011803c
const WOBBLE_STEP := 1.0 / 27.0  # _DAT_1011cdd8 = 0.037037
const BEAM_W_MIN := 180.0        # _DAT_10119920
const BEAM_W_MAX := 460.0        # _DAT_1011cd70
const BEAM_JX := 50.0            # _DAT_1011a1c0, strip offset scatter
const BEAM_JY := 10.0            # _DAT_101190c0
const END_FLARE_Z := 90000.0     # _DAT_1011cd5c
# FlareNominalDistance (+0xe4) per flare family, FUN_100c2040: the end
# flares author 10000 (0x461c4000), the 99 ring flares 3500 (0x455ac000);
# both flag-8 fixed-world size = m_intensity_scale x envelope x nominal
# x tan(half-fov) (Render, flux.dll.c:215202-215206)
const END_FLARE_NOMINAL := 10000.0
const RING_FLARE_NOMINAL := 3500.0
const WALL1_COLOR := Color(1.0, 0.52, 0.01, 0.5)   # 0x3f051eb8, 0x3c23d70a
const WALL2_COLOR := Color(0.83, 0.10, 0.01, 0.5)  # 0x3f547ae1, 0x3dcccccd
const WALL2_SCALE := 1.07        # 0x3f88f5c3
const BEAM_COLOR_A := Color(1.0, 1.0, 1.0, 0.5)
const BEAM_COLOR_B := Color(1.0, 1.0, 0.5, 0.5)    # FUN_100c1570
const FLARE_COLOR := Color(1.0, 0.47, 0.03)        # 0x3ef0a3d7, 0x3cf5c28f
const FLARE_END_GAIN := 0.2      # envelope @ 0x100c2040
const FLARE_RING_GAIN := 0.05    # envelope, the 99 per-ring flares
const LIGHT_COLOR := Color(0.9, 0.43, 0.0)  # DAT_101715e8/ec/f0

var active := false

# per-segment state, tunnel-local (forward = -Z here; the engine's +Z)
var _pts: Array = []      # PackedVector3Array[33]: ring shape around centre
var _pu: Array = []       # PackedFloat32Array[33]: wobble-envelope U coords
var _cx := PackedFloat32Array()
var _cy := PackedFloat32Array()
var _cz := PackedFloat32Array()
var _phase := PackedFloat32Array()
var _jx := PackedFloat32Array()
var _jy := PackedFloat32Array()
var _w := PackedFloat32Array()
var _head := 0            # oldest segment (next to recycle); pair walk start
var _front_z := 0.0       # most-negative local z (newest ring)
var _last_inner := false  # respawns alternate bands off the previous ring
                          # (FUN_100c11e0 passes the newest ring's flag + 1)
var _walk_x := 0.0        # spawn-to-spawn centre random walk
var _walk_y := 0.0
var _wobble := PackedFloat32Array()  # the shared 33-key U envelope
var _scroll := 0.0

var _wall_mesh: ArrayMesh
var _beam_mesh: ArrayMesh
var _wall1: MeshInstance3D
var _wall2: MeshInstance3D
var _beams: MeshInstance3D
var _flares: MeshInstance3D
var _flare_mesh: ArrayMesh
var _mat_wall1: StandardMaterial3D
var _mat_wall2: StandardMaterial3D
var _light: DirectionalLight3D
var _cam: Camera3D
var _rng := RandomNumberGenerator.new()

# scratch arrays reused every rebuild
var _vv := PackedVector3Array()
var _vc := PackedColorArray()
var _vu := PackedVector2Array()


func _init() -> void:
	visible = false
	_wall_mesh = ArrayMesh.new()
	_beam_mesh = ArrayMesh.new()
	_flare_mesh = ArrayMesh.new()
	_mat_wall1 = _make_mat(_tex("capsule_tunnel"), WALL1_COLOR)
	_mat_wall2 = _make_mat(_tex("capsule_tunnel2"), WALL2_COLOR)
	_wall1 = _mk_mi(_wall_mesh, _mat_wall1)
	_wall2 = _mk_mi(_wall_mesh, _mat_wall2)
	_wall2.scale = Vector3(WALL2_SCALE, WALL2_SCALE, 1.0)  # radial x1.07 pass
	_beams = _mk_mi(_beam_mesh, _make_mat(_tex("capsule_beam"), Color.WHITE))
	_flares = _mk_mi(_flare_mesh, _make_mat(_flare_tex(), Color.WHITE))
	_light = DirectionalLight3D.new()
	_light.light_color = LIGHT_COLOR
	_light.light_energy = 1.0
	add_child(_light)
	set_process(true)


func _mk_mi(mesh: ArrayMesh, mat: StandardMaterial3D) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	# geometry spans +-100 km around the camera; never let Godot cull it
	mi.custom_aabb = AABB(Vector3.ONE * -1.1e5, Vector3.ONE * 2.2e5)
	add_child(mi)
	return mi


static func _make_mat(tex: Texture2D, col: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.vertex_color_use_as_albedo = true
	mat.albedo_color = col
	mat.disable_receive_shadows = true
	mat.no_depth_test = false
	if tex != null:
		mat.albedo_texture = tex
	return mat


static func _tex(stem: String) -> ImageTexture:
	var base := ProjectSettings.globalize_path("res://").path_join("..")
	var path := base.path_join("data/textures/images/sfx/%s.png" % stem)
	if not FileAccess.file_exists(path):
		return null
	var img := Image.load_from_file(path)
	if img == null:
		return null
	return ImageTexture.create_from_image(img)


static func _flare_tex() -> Texture2D:
	# The REAL FcLensFlareNode atlas (#34): m_texture_url =
	# texture:/images/sfx/lens_flares, m_tex_coords @ flux 0x100ee420 is a
	# FOUR-entry table (eStyle 0..3 = the 2x2 quadrants; the "type ids
	# 1/9/0x2b" the residual list carried were a misread of other fields).
	# Style 0, the top-left soft glow, is the default the ctor sets
	# (+0xbc = 1... style 1 top-right) -- the capsule's white blank uses
	# the plain glow quadrant.
	var base := ProjectSettings.globalize_path("res://").path_join("..")
	var tex := StarFx.style_texture(0, base)
	if tex != null:
		return tex
	# no extracted data on disk (bare CI checkout): keep the radial
	var img := Image.create(64, 64, false, Image.FORMAT_RGBA8)
	for y in 64:
		for x in 64:
			var d := Vector2(x - 31.5, y - 31.5).length() / 31.5
			var a := clampf(1.0 - d, 0.0, 1.0)
			img.set_pixel(x, y, Color(1, 1, 1, a * a))
	return ImageTexture.create_from_image(img)


## Enter capsule space: freeze the tunnel axis to the ship's forward frame
## (SendShipDownTunnel @ 0x10043740 resets the ship to identity inside the
## capsule system, so axis == ship forward) and build the 99 rings.
func enter(camera: Camera3D, axis_basis: Basis) -> void:
	_cam = camera
	basis = axis_basis.orthonormalized()
	_rng.randomize()
	_build_wobble()
	_pts.clear()
	_pu.clear()
	_cx.resize(SEGS)
	_cy.resize(SEGS)
	_cz.resize(SEGS)
	_phase.resize(SEGS)
	_jx.resize(SEGS)
	_jy.resize(SEGS)
	_w.resize(SEGS)
	_walk_x = 0.0
	_walk_y = 0.0
	_scroll = 0.0
	for i in SEGS:
		_pts.append(PackedVector3Array())
		_pu.append(PackedFloat32Array())
		# FUN_100c1170: ring i at engine z = -49500 + i*1000 -> local -z ahead
		_spawn(i, HALF_LEN - i * SPACING, (i & 1) == 1)
	_head = 0
	_front_z = HALF_LEN - (SEGS - 1) * SPACING
	active = true
	visible = true


func exit() -> void:
	active = false
	visible = false
	_cam = null
	_wall_mesh.clear_surfaces()
	_beam_mesh.clear_surfaces()
	_flare_mesh.clear_surfaces()


func _build_wobble() -> void:
	# the ring-point U envelope, FUN_100c2040 @ 0x100c2040: keys every 1/27,
	# alternating rand[0.5, 1.0] and rand[0.0, 0.5], zero at both ends;
	# sampled per point at i * 0.030303 (_DAT_1011cd74)
	_wobble.resize(RING_PTS + 1)
	_wobble[0] = 0.0
	for i in range(1, RING_PTS + 1):
		if i * WOBBLE_STEP >= 0.963:  # _DAT_1011cdd4, tail key is zero
			_wobble[i] = 0.0
		elif (i & 1) == 1:
			_wobble[i] = _rng.randf_range(0.5, 1.0)
		else:
			_wobble[i] = _rng.randf_range(0.0, 0.5)


func _spawn(i: int, z: float, inner: bool) -> void:
	# FUN_100c0700: one ring. Radius random-walks inside its band; the centre
	# walks from the previously spawned ring's centre (+-10, DAT_101715d8/dc)
	# and is clamped back toward the axis.
	_last_inner = inner
	var r_lo := R_INNER if inner else R_OUTER - BAND
	var r_hi := R_INNER + BAND if inner else R_OUTER
	_walk_x = clampf(_walk_x + _rng.randf_range(-CENTER_WALK, CENTER_WALK),
		-CENTER_CLAMP, CENTER_CLAMP)
	_walk_y = clampf(_walk_y + _rng.randf_range(-CENTER_WALK, CENTER_WALK),
		-CENTER_CLAMP, CENTER_CLAMP)
	_cx[i] = _walk_x
	_cy[i] = _walk_y
	_cz[i] = z
	# outer rings phase rand[0.5,0.8] (0.8=_DAT_1011959c, 0.5=_DAT_10117738),
	# inner rand[0,0.3] (_DAT_1011c034)
	_phase[i] = _rng.randf_range(0.0, 0.3) if inner \
		else _rng.randf_range(0.5, 0.8)
	_jx[i] = _rng.randf_range(-BEAM_JX, BEAM_JX)   # 0x230
	_jy[i] = _rng.randf_range(-BEAM_JY, BEAM_JY)   # 0x234
	_w[i] = _rng.randf_range(BEAM_W_MIN, BEAM_W_MAX)  # 0x23c
	var pts: PackedVector3Array = _pts[i]
	var pu: PackedFloat32Array = _pu[i]
	pts.resize(RING_PTS + 1)
	pu.resize(RING_PTS + 1)
	var r := _rng.randf_range(r_lo, r_hi)
	var half := (r_hi - r_lo) * 0.5
	for k in RING_PTS:
		var step := _rng.randf_range(0.0, half)
		r += step
		if r > r_hi:
			r -= step * 2.0
		var a := k * TAU / RING_PTS
		pts[k] = Vector3(cos(a) * r, sin(a) * r, 0.0)
		pu[k] = _wobble[k]
	pts[RING_PTS] = pts[0]
	pu[RING_PTS] = _wobble[RING_PTS]
	_pts[i] = pts
	_pu[i] = pu


func _process(delta: float) -> void:
	if not active or _cam == null:
		return
	# icCapsuleSpaceSystem::Render @ 0x100481e0: avatar sits AT the camera
	position = _cam.global_transform.origin
	_scroll += delta * SCROLL_RATE  # FUN_100c11e0
	# FUN_100c0d80: uniform stream step, clamped to 1000 m per frame; the
	# ring centres also jitter +-15 m every frame
	var step := minf(delta * TUNNEL_SPEED, MAX_STEP)
	for i in SEGS:
		_cz[i] += step
		_cx[i] += _rng.randf_range(-JITTER, JITTER)
		_cy[i] += _rng.randf_range(-JITTER, JITTER)
	# FUN_100c11e0: recycle rings that passed 36 km behind to the front
	while _cz[_head] > CULL_BEHIND:
		_front_z -= SPACING
		_spawn(_head, _front_z, not _last_inner)
		_head = (_head + 1) % SEGS
	_light.rotation = Vector3(_rng.randf_range(0, TAU),
		_rng.randf_range(0, TAU), 0.0)  # Prepare @ 0x100c1d30: random each frame
	var off := Vector2(_scroll, _scroll)
	_mat_wall1.uv1_offset = Vector3(-off.x, -off.y, 0.0)  # pass 1: -scroll
	_mat_wall2.uv1_offset = Vector3(off.x, off.y, 0.0)    # pass 2: +scroll
	_rebuild_walls()
	_rebuild_beams()
	_rebuild_flares()


func _rebuild_walls() -> void:
	# FUN_100c1300: 98 triangle strips joining consecutive rings, 33 point
	# pairs each; stitched here into one strip with degenerate joins
	var n := (SEGS - 1) * ((RING_PTS + 1) * 2 + 2) - 2
	if _vv.size() != n:
		_vv.resize(n)
		_vc.resize(n)
		_vu.resize(n)
	var white := Color(1, 1, 1, 1)  # tint lives in the material albedo
	var o := 0
	for p in SEGS - 1:
		var i := (_head + p) % SEGS
		var j := (_head + p + 1) % SEGS
		var ci := Vector3(_cx[i], _cy[i], _cz[i])
		var cj := Vector3(_cx[j], _cy[j], _cz[j])
		var pi: PackedVector3Array = _pts[i]
		var pj: PackedVector3Array = _pts[j]
		var ui: PackedFloat32Array = _pu[i]
		var uj: PackedFloat32Array = _pu[j]
		var vi := _phase[i]
		var vj := _phase[j]
		if p > 0:  # degenerate stitch from the previous strip
			_vv[o] = _vv[o - 1]
			_vc[o] = white
			_vu[o] = _vu[o - 1]
			o += 1
			_vv[o] = pi[0] + ci
			_vc[o] = white
			_vu[o] = Vector2(ui[0], vi)
			o += 1
		for k in RING_PTS + 1:
			_vv[o] = pi[k] + ci
			_vc[o] = white
			_vu[o] = Vector2(ui[k], vi)
			o += 1
			_vv[o] = pj[k] + cj
			_vc[o] = white
			_vu[o] = Vector2(uj[k], vj)
			o += 1
	_wall_mesh.clear_surfaces()
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = _vv
	arrays[Mesh.ARRAY_COLOR] = _vc
	arrays[Mesh.ARRAY_TEX_UV] = _vu
	_wall_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLE_STRIP, arrays)


func _rebuild_beams() -> void:
	# FUN_100c1570: three ribbons threaded down the ring centres. Strip A is
	# white, offset by the ring's jx scatter, extents +-w along (1,0,0);
	# strip B is (1,1,0.5), offset jy, extents along (1,1,0); strip C is
	# (1,1,0.5), offset jy, extents along (-1,1,0). U alternates 0/1 per
	# ring. Draw @ 0x100c1dd0 runs the pass twice, but the engine's master
	# vertex alpha (engine+0x1790, halved into every vertex) is not
	# recovered; a single pass at 0.5 reads right, doubling washes out.
	_beam_mesh.clear_surfaces()
	var dir_a := Vector3(1, 0, 0)
	var dir_b := Vector3(1, 1, 0)
	var dir_c := Vector3(-1, 1, 0)
	_beam_strip(dir_a, BEAM_COLOR_A, true)
	_beam_strip(dir_b, BEAM_COLOR_B, false)
	_beam_strip(dir_c, BEAM_COLOR_B, false)


func _beam_strip(dir: Vector3, col: Color, use_jx: bool) -> void:
	var vv := PackedVector3Array()
	var vc := PackedColorArray()
	var vu := PackedVector2Array()
	var n := SEGS * 2
	vv.resize(n)
	vc.resize(n)
	vu.resize(n)
	var c2 := col
	var u := 0.0
	var o := 0
	for p in SEGS:
		var i := (_head + p) % SEGS
		var c := Vector3(_cx[i] + (_jx[i] if use_jx else 0.0),
			_cy[i] + (0.0 if use_jx else _jy[i]), _cz[i])
		var e := dir * _w[i]
		vv[o] = c - e
		vc[o] = c2
		vu[o] = Vector2(u, 0.0)
		o += 1
		vv[o] = c + e
		vc[o] = c2
		vu[o] = Vector2(u, 1.0)
		o += 1
		u = 1.0 - u
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vv
	arrays[Mesh.ARRAY_COLOR] = vc
	arrays[Mesh.ARRAY_TEX_UV] = vu
	_beam_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLE_STRIP, arrays)


func _rebuild_flares() -> void:
	# FUN_100c2040: two 10 km end flares at z = +-90 km (gain 0.2) and one
	# small flare per ring (gain 0.05), colour (1.0, 0.47, 0.03). Billboarded
	# by hand into one additive quad soup.
	_flare_mesh.clear_surfaces()
	if _cam == null:
		return
	var cb := (global_transform.basis.inverse()
		* _cam.global_transform.basis).orthonormalized()
	var rt := cb.x
	var up := cb.y
	var vv := PackedVector3Array()
	var vc := PackedColorArray()
	var vu := PackedVector2Array()
	var quads := SEGS + 2
	vv.resize(quads * 6)
	vc.resize(quads * 6)
	vu.resize(quads * 6)
	# flag-8 fixed-world sizing (FcLensFlareNode::Render, flux.dll.c:
	# 215202-215206): half = m_intensity_scale x envelope x
	# FlareNominalDistance x tan(half-fov). The ring flares author
	# nominal 3500 (+0xe4 = 0x455ac000, FUN_100c2040's 99-loop), the end
	# flares 10000; both carry flag 8 (+0xe8 = 9 / 1). The old 150 m ring
	# size was the last placeholder on issue #34.
	var half_fov := tan(deg_to_rad(_cam.fov) * 0.5)
	var ring_half := StarFx.INTENSITY_SCALE * FLARE_RING_GAIN \
			* RING_FLARE_NOMINAL * half_fov
	var end_half := StarFx.INTENSITY_SCALE * FLARE_END_GAIN \
			* END_FLARE_NOMINAL * half_fov
	var o := 0
	for p in SEGS:
		var i := (_head + p) % SEGS
		var c := FLARE_COLOR
		c.a = FLARE_RING_GAIN
		o = _quad(vv, vc, vu, o, Vector3(_cx[i], _cy[i], _cz[i]),
			rt, up, ring_half, c)
	var ce := FLARE_COLOR
	ce.a = FLARE_END_GAIN
	o = _quad(vv, vc, vu, o, Vector3(0, 0, -END_FLARE_Z), rt, up,
		end_half, ce)
	o = _quad(vv, vc, vu, o, Vector3(0, 0, END_FLARE_Z), rt, up,
		end_half, ce)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vv
	arrays[Mesh.ARRAY_COLOR] = vc
	arrays[Mesh.ARRAY_TEX_UV] = vu
	_flare_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)


static func _quad(vv: PackedVector3Array, vc: PackedColorArray,
		vu: PackedVector2Array, o: int, c: Vector3, rt: Vector3, up: Vector3,
		size: float, col: Color) -> int:
	var r := rt * size
	var u := up * size
	var p0 := c - r - u
	var p1 := c + r - u
	var p2 := c + r + u
	var p3 := c - r + u
	var verts := [p0, p1, p2, p0, p2, p3]
	var uvs := [Vector2(0, 1), Vector2(1, 1), Vector2(1, 0),
		Vector2(0, 1), Vector2(1, 0), Vector2(0, 0)]
	for k in 6:
		vv[o + k] = verts[k]
		vc[o + k] = col
		vu[o + k] = uvs[k]
	return o + 6
