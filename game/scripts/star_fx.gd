class_name StarFx
extends Node3D

# A star, as the original builds it.
#
# icSun::CreateAvatar (iwar2.dll @ 0x1006a960) attaches THREE things to an
# icSun sim:
#   1. an icSunAvatar scene node (ctor FUN_100d2910 @ 0x100d2910) -- the
#      plasma surface, radius-sized. At map distances (1e11..1e13 m) it sits
#      far beyond the 600 km far plane and is never seen; we do not build it.
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

var d_radii := INF   # main._stream_objects feeds true distance / sun radius
var _glow: FlareQuad
var _star: FlareQuad
var _streak: FlareQuad
var _glow_col: Color
var _star_col: Color
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
	# the render squares the colour components (FcColour at 0xe6100)
	_glow_col = Color(col_a.r * col_a.r, col_a.g * col_a.g, col_a.b * col_a.b)
	_star_col = Color(col_b.r * col_b.r, col_b.g * col_b.g, col_b.b * col_b.b)
	# class < 3 renders the sun_blue surface (FUN_100d2910), and class <= 2 is
	# also the flag-2 condition -- sun_texture IS the class band
	_has_streak = str(rec.get("sun_texture", "")) == "sun_blue"

	_glow = FlareQuad.create(_atlas[0])
	_star = FlareQuad.create(_atlas[2])
	_streak = FlareQuad.create(_atlas[0])
	_streak.width_ratio = STREAK_WIDTH_RATIO
	add_child(_glow)
	add_child(_star)
	add_child(_streak)


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
