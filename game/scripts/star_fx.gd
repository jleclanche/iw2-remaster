class_name StarFx
extends Node3D

# A star, as the original builds it.
#
# icSun::CreateAvatar (iwar2.dll @ 0x1006a960) attaches THREE things to an
# icSun sim:
#   1. an icSunAvatar scene node (ctor FUN_100d2910 @ 0x100d2910) -- the
#      plasma-surface DISC. It IS seen: a sun's runtime radius is forced to
#      1e8 m (SetRadius(1e8), OnBecomeActive @ 0x1004c380:66705) and the disc
#      is sized to radius x 1.4 (_DAT_1011a440, FUN_100d2910:167911), so a sun
#      at a few hundred thousand km fills much of the view (~47 deg at 320k km).
#      It draws in the planets-avatar group (DAT_10171e04, depth off), textured
#      with the class plasma texture (icPlanetProperties: class>=7 -> sun_red,
#      3..6 -> sun_yellow, <3 -> sun_blue). We build it as an impostor sphere,
#      like a planet, so the square plasma texture reads as a round disc.
#   2. an FcLensFlareNode, style 0 (the soft glow quadrant of
#      images/sfx/lens_flares), colour icSun::PickColour(class);
#   3. a second FcLensFlareNode, style 2 (the 4-point star quadrant), flags
#      1 | (class <= 2 ? 2 : 0) -- flag 2 turns on the blue anamorphic
#      streak, so only class <= 2 (sun_blue) stars get it.
#
# FcLensFlareNode::Render (flux.dll @ 0xe6100), constant-apparent-size branch:
#   world half-extent = m_intensity_scale (15, @ 0x100ee4a8) x envelope x
#   view depth -- i.e. apparent half-size = 15 x intensity, independent of
#   range. Vertex colour = (r^2, g^2, b^2) x alpha (+0xe0). The anamorphic
#   streak is a second quad, full length along camera-right, 1/6 as tall
#   (m_anamorphic_streak_width_ratio @ 0x100ee4a0), pure blue (0, 0, alpha),
#   textured with the style-0 glow.
#
# icSun's per-frame envelope writer (iwar2 @ 0x1006b8xx, the function before
# CreateAvatar): d = approximate player distance in SUN RADII
# (max + 0.34375*mid + 0.25*min of the |axis| deltas, DAT_101191f0/DAT_101191ec):
#   glow intensity:  d<5 -> 1; 5..25 -> 1 -> 0.5 (x0.025/radius);
#                    25..75 -> 0.5 -> 0.15 (x0.007); 75..125 -> 0.15 -> 0
#                    (x0.003); 0 beyond 125 radii.
#   star alpha    :  clamp(d * 0.008, 0..1)   (fades IN, full at 125 radii)
#   star intensity:  0.05 * (1 - clamp(d * 2e-5, 0..1))  (gone at 50k radii)

const INTENSITY_SCALE := 15.0       # FcLensFlareNode::m_intensity_scale
const STREAK_WIDTH_RATIO := 0.166667  # m_anamorphic_streak_width_ratio
const DISC_SIZE_MUL := 1.4          # _DAT_1011a440, FUN_100d2910:167911
# draw the disc just over the nebula band (space_fx -30) and sky (-40) so a
# near sun occludes them (the Effrit sits behind Hoffer's Wake Alpha), but under
# the closer-planet band (main_world PRIORITY_PLANET_NEAR -12). The corona sits
# one below the disc so the opaque disc covers its centre (icSunAvatar::Render
# draws the corona first, then the disc over it).
const DISC_RENDER_PRIORITY := -28
const CORONA_RENDER_PRIORITY := -29

var d_radii := INF   # main._stream_objects feeds true distance / sun radius
var disc_radius := 0.0  # world half-extent of the plasma disc, set by the caller
var _glow: FlareQuad
var _star: FlareQuad
var _streak: FlareQuad
var _disc: MeshInstance3D
var _corona: Array[MeshInstance3D] = []   # the two Draw4x4 fan billboards
var _glow_col: Color
var _star_col: Color
var _col_a: Color   # icSun::PickColour draw #1 (corona colour node+0xc0)
var _col_b: Color   # icSun::PickColour draw #2 (corona colour node+0xcc)
var _has_streak := false

# FcLensFlareNode::m_tex_coords (@ 0x100ee420) styles, one atlas quadrant
# each: 0 = soft glow (TL), 1 = sharp glow (TR), 2 = 4-point star (BL),
# 3 = 6-point star (BR)
static var _atlas: Array = []


static func _load_atlas(base: String) -> void:
	if not _atlas.is_empty():
		return
	var img := Image.load_from_file(
		base.path_join("data/textures/images/sfx/lens_flares.png"))
	if img == null:
		return
	var w := img.get_width() / 2
	var h := img.get_height() / 2
	for r in [Rect2i(0, 0, w, h), Rect2i(w, 0, w, h),
			Rect2i(0, h, w, h), Rect2i(w, h, w, h)]:
		_atlas.append(ImageTexture.create_from_image(img.get_region(r)))


static func style_texture(style: int, base: String) -> Texture2D:
	_load_atlas(base)
	if _atlas.is_empty():
		return null
	return _atlas[clampi(style, 0, 3)]


static func _sun_surface(stem: String, base: String) -> Texture2D:
	if stem.is_empty():
		return null
	var path := base.path_join(
		"data/textures/images/planets/%s.png" % stem)
	if not FileAccess.file_exists(path):
		return null
	var img := Image.load_from_file(path)
	return ImageTexture.create_from_image(img) if img != null else null


static func _pick_colour(pair: Array, seed_value: int) -> Color:
	# icSun::PickColour: FcColour::LERP(a, b, rand()). One draw per star, so a
	# stable per-star hash stands in for rand() -- the star must not shimmer.
	var a: Array = pair[0]
	var b: Array = pair[1]
	var t := float(seed_value % 1000) / 1000.0
	return Color(
		lerpf(float(a[0]), float(b[0]), t),
		lerpf(float(a[1]), float(b[1]), t),
		lerpf(float(a[2]), float(b[2]), t))


# @element icSunAvatar
func setup(rec: Dictionary, base: String) -> void:
	StarFx._load_atlas(base)
	var pair: Array = rec.get("sun_colours", [[1.0, 1.0, 1.0], [1.0, 1.0, 1.0]])
	var h := absi(str(rec.get("name", "")).hash())
	# CreateAvatar calls PickColour once per flare: independent draws
	var col_a := _pick_colour(pair, h)
	var col_b := _pick_colour(pair, h / 1000)
	_col_a = col_a
	_col_b = col_b
	# the render squares the colour components (FcColour at 0xe6100)
	_glow_col = Color(col_a.r * col_a.r, col_a.g * col_a.g, col_a.b * col_a.b)
	_star_col = Color(col_b.r * col_b.r, col_b.g * col_b.g, col_b.b * col_b.b)
	# class < 3 renders the sun_blue surface (FUN_100d2910), and class <= 2 is
	# also the flag-2 condition -- sun_texture IS the class band
	_has_streak = str(rec.get("sun_texture", "")) == "sun_blue"

	# The plasma disc (icSunAvatar): an unshaded sphere textured with the class
	# surface (sun_red/yellow/blue), so the square texture reads as a round disc.
	# Drawn in the backdrop band (depth off), opaque, so it occludes the sky.
	var tex := _sun_surface(str(rec.get("sun_texture", "sun_red")), base)
	if tex != null:
		var sph := SphereMesh.new()
		sph.radius = 1.0
		sph.height = 2.0
		sph.radial_segments = 48
		sph.rings = 24
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.albedo_texture = tex
		# TRANSPARENCY_ALPHA puts it in the priority-ordered queue (alpha stays 1)
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
		mat.cull_mode = BaseMaterial3D.CULL_BACK
		mat.disable_receive_shadows = true
		mat.render_priority = DISC_RENDER_PRIORITY
		sph.material = mat
		_disc = MeshInstance3D.new()
		_disc.mesh = sph
		add_child(_disc)

		# The corona: two Draw4x4 quadrant-fan billboards (icSunAvatar::Render
		# @ 0x100d2bc0), one per PickColour, additive, sharing a rotation angle
		# that tracks the camera. The fan's corners reach ~sqrt2 past the disc,
		# so its arms read as flames beyond the rim. Drawn behind the disc so the
		# opaque disc covers the centre.
		var fan := StarFx.quadrant_fan_mesh()
		for col in [_col_a, _col_b]:
			var cmat := StandardMaterial3D.new()
			cmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			cmat.albedo_texture = tex
			cmat.albedo_color = col
			cmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			cmat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
			cmat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
			cmat.cull_mode = BaseMaterial3D.CULL_DISABLED
			cmat.disable_receive_shadows = true
			cmat.render_priority = CORONA_RENDER_PRIORITY
			var cm := MeshInstance3D.new()
			cm.mesh = fan
			cm.material_override = cmat
			cm.custom_aabb = AABB(Vector3(-1, -1, -1), Vector3(2, 2, 2))
			add_child(cm)
			_corona.append(cm)

	_glow = FlareQuad.create(_atlas[0])
	_star = FlareQuad.create(_atlas[2])
	_streak = FlareQuad.create(_atlas[0])
	_streak.width_ratio = STREAK_WIDTH_RATIO
	# the streak is Render's SUB-quad, not a flare node: no white centre
	_streak.core_level = -1.0
	add_child(_glow)
	add_child(_star)
	add_child(_streak)


func _update_corona() -> void:
	# icSunAvatar::Render's rotation: the sun's fixed pole axis projected into the
	# camera basis, angle = -atan2(view.y, view.x) (fpatan + fchs @ 0x100d2cef).
	# A fixed axis under a moving camera => the corona rolls as the camera turns.
	# Both fans (the two PickColours) share the angle (node+0xe0 = 0).
	var vis := disc_radius > 0.0
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		for cm in _corona:
			cm.visible = false
		return
	var cb := cam.global_transform.basis
	var pole := Vector3.UP
	var ang := -atan2(cb.y.dot(pole), cb.x.dot(pole))
	var basis := cb * Basis(Vector3(0.0, 0.0, 1.0), ang)
	var s := maxf(disc_radius, 1.0)
	for cm in _corona:
		cm.visible = vis
		cm.transform = Transform3D(basis.scaled(Vector3(s, s, s)), Vector3.ZERO)


static func _glow_intensity(d: float) -> float:
	# iwar2 @ 0x1006b8xx piecewise, d in sun radii (DAT_101183f0=5,
	# DAT_101190b0=20, DAT_1011a1c0=50, slopes 0.025/0.007/0.003,
	# knots 0.5 @ DAT_10117738 and 0.15 @ DAT_1011b354)
	if d < 5.0:
		return 1.0
	var t := d - 5.0
	if t < 20.0:
		return 0.5 + (20.0 - t) * 0.025
	t -= 20.0
	if t < 50.0:
		return 0.15 + (50.0 - t) * 0.007
	t -= 50.0
	if t < 50.0:
		return (50.0 - t) * 0.003
	return 0.0


func _process(_delta: float) -> void:
	# icSun::UpdateAvatar's per-frame envelopes; FlareQuad does the sizing
	# (15 x intensity x view depth, flux Render @ 0xe6100)
	if _disc != null:
		_disc.scale = Vector3.ONE * maxf(disc_radius, 1.0)
		_disc.visible = disc_radius > 0.0
	if not _corona.is_empty():
		_update_corona()
	if _glow == null:
		return
	var gi := StarFx._glow_intensity(d_radii)
	var star_a := clampf(d_radii * 0.008, 0.0, 1.0)
	var si := 0.05 * (1.0 - clampf(d_radii * 2e-5, 0.0, 1.0))

	_glow.intensity = gi
	_glow.tint = _glow_col
	_star.intensity = si if star_a > 1e-3 else 0.0
	_star.tint = Color(
		_star_col.r * star_a, _star_col.g * star_a, _star_col.b * star_a)
	# the anamorphic streak is pure blue x the flare alpha (0, 0, a)
	_streak.intensity = _star.intensity if _has_streak else 0.0
	_streak.tint = Color(0.0, 0.0, star_a)


# The Draw4x4 primitive: an 8-triangle fan, centre UV (1, 1), corners at
# (0.008, 0.008) and edge midpoints at the texture's other two corners --
# one texture quadrant mirrored into all four.
# icShockwaveAvatar draws through the very same routine, so ExplosionFx
# shares this mesh. (icSunAvatar's corona also draws with it, but that node
# sits beyond the far plane at any map range and is never built here.)
static func quadrant_fan_mesh() -> ArrayMesh:
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	# 1/128 = the original's half-texel inset (0.0078125 / 0.9921875)
	var lo := 0.0078125
	var hi := 0.9921875
	# ring of 8 points around the centre: corners and edge midpoints
	var ring := [
		Vector2(-1, -1), Vector2(0, -1), Vector2(1, -1), Vector2(1, 0),
		Vector2(1, 1), Vector2(0, 1), Vector2(-1, 1), Vector2(-1, 0),
	]
	# corner -> UV (lo, lo); edge midpoint -> the quadrant's outer edge
	var ring_uv := [
		Vector2(lo, lo), Vector2(hi, lo), Vector2(lo, lo), Vector2(lo, hi),
		Vector2(lo, lo), Vector2(hi, lo), Vector2(lo, lo), Vector2(lo, hi),
	]
	for i in 8:
		var j := (i + 1) % 8
		verts.append(Vector3.ZERO)
		uvs.append(Vector2(1.0, 1.0))  # the centre samples the texture corner exactly
		verts.append(Vector3(ring[i].x, ring[i].y, 0.0))
		uvs.append(ring_uv[i])
		verts.append(Vector3(ring[j].x, ring[j].y, 0.0))
		uvs.append(ring_uv[j])
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_TEX_UV] = uvs
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return mesh
