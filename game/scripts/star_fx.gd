class_name StarFx
extends Node3D

# A star, as the original builds it.
#
# icSun::CreateAvatar (iwar2.dll @ 0x1006a960) attaches THREE things to an
# icSun sim:
#   1. an icSunAvatar scene node (ctor FUN_100d2910 @ 0x100d2910) -- a shader
#      whose single texture layer is chosen by the sun's class:
#          class < 3 -> icPlanetProperties+0x20 = images/planets/sun_blue
#          class < 7 -> icPlanetProperties+0x18 = images/planets/sun_yellow
#          else      -> icPlanetProperties+0x1c = images/planets/sun_red
#      scaled to FiSim::Radius() on all three axes, with a bounding radius of
#      radius * 1.4 (_DAT_1011a440).
#   2. a lens flare at the sun's position (FcLensFlareNode, mode 0),
#   3. a second lens flare (mode 2) whose variant is 3 for class <= 2 and 1
#      otherwise.
#
# The draw (vtable 0x1011d1fc slots 14/16 -> 0x100d2b30 / 0x100d2b80; Ghidra
# bails on both, recovered by raw disassembly -- docs/effects.md section 6):
#   - the DISC is one of the three planets.ini planet_models[] LOD spheres
#     (icPlanetProperties+0x28), rendered with the class texture as the
#     global shader;
#   - the CORONA is TWO FcBillBoard::Draw4x4 quads (flux.dll @ 0x1004c420) at
#     the sun's position, both sized radius * 1.3 (_DAT_1011d250) with the
#     second layer 5% bigger (1.05 @ 0x100d2d40), additive (Draw4x4 forces
#     eBlend=1 = ONE/ONE), each coloured by its OWN icSun::PickColour draw
#     (this+0xc0 / this+0xcc from the ctor).
#   - the roll TRACKS THE CAMERA: roll = -atan2(sunY . cam_up, sunY . cam_right)
#     (0x100d2c22..0x100d2cf1), so rolling your ship rotates the halo -- that
#     is the "the halo moves" the original shows.  On top of that a phase
#     accumulator (this+0xe0, Prepare @ 0x100d2b30) advances at 0.010472 rad/s
#     (= 0.6 deg/s, double @ 0x1011d248); layer 1 draws at roll + phase and
#     layer 2 at roll - phase, so the layers counter-rotate at 1.2 deg/s.
#   - Draw4x4 draws the quad as an 8-triangle fan whose CENTRE has UV (1, 1)
#     and whose corners have UV (0.008, 0.008): sun_halo.png is one quadrant,
#     mirrored 4x, spikes meeting at the centre.

const HALO_BOUND := 1.4    # _DAT_1011a440: icSunAvatar bounding radius multiplier
const HALO_SCALE := 1.3    # _DAT_1011d250: drawn corona quad half-extent, x radius
const HALO_LAYER2 := 1.05  # 0x100d2d40: second layer is 5% bigger
const PHASE_RATE := 0.010472  # double @ 0x1011d248: rad/s, layers at +/- phase
const FLARE_BOOST := 2.2   # reconstructed: the flare glow vs the corona's 1.3x

var _body: MeshInstance3D
var _halo_a: MeshInstance3D
var _halo_b: MeshInstance3D
var _phase := 0.0


static func _tex(stem: String, base: String) -> ImageTexture:
	var path := base.path_join("data/textures/images/planets/%s.png" % stem)
	if not FileAccess.file_exists(path):
		return null
	var img := Image.load_from_file(path)
	if img == null:
		return null
	return ImageTexture.create_from_image(img)


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
	var stem := str(rec.get("sun_texture", "sun_yellow"))
	var pair: Array = rec.get("sun_colours", [[1.0, 1.0, 1.0], [1.0, 1.0, 1.0]])
	var h := absi(str(rec.get("name", "")).hash())
	# the ctor calls PickColour TWICE (0x100d2903/0x100d2907): each corona
	# layer gets an independent draw from the class colour pair
	var col_a := _pick_colour(pair, h)
	var col_b := _pick_colour(pair, h / 1000)

	# The disc: the original renders a planet_models[] LOD sphere with the
	# class's plasma texture -- but at map distances a sun's TRUE angular size
	# is sub-pixel (Beta: 0.01 deg), and the star is drawn at the flare cap
	# (main.STAR_FLARE_DEG), standing in for the FcLensFlareNode glow the
	# player actually sees. At that size the noise texture read as a flat
	# "snowball"/"donut", so the disc renders as a small HOT CORE in the
	# picked class colour (lerped toward white, like a flare core) at 0.35x;
	# the plasma texture would only ever matter inside 250 km of a
	# photosphere, which no map allows.
	var sphere := SphereMesh.new()
	sphere.radius = 0.35
	sphere.height = 0.7
	sphere.radial_segments = 24
	sphere.rings = 12
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	var core := col_a.lerp(Color.WHITE, 0.7)
	mat.albedo_color = core
	mat.emission_enabled = true
	mat.emission = core
	mat.emission_energy_multiplier = 6.0
	sphere.material = mat
	_body = MeshInstance3D.new()
	_body.mesh = sphere
	add_child(_body)

	# the corona: two counter-rotating Draw4x4 layers, oriented on the CPU
	# each frame (the roll must track the camera; BILLBOARD_ENABLED would
	# overwrite the basis and lose it)
	var tex := _tex("sun_halo", base)
	_halo_a = _make_halo(tex, col_a)
	_halo_b = _make_halo(tex, col_b)
	add_child(_halo_a)
	add_child(_halo_b)


func _make_halo(tex: Texture2D, colour: Color) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = StarFx.quadrant_fan_mesh()
	var hm := StandardMaterial3D.new()
	hm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	hm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	hm.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	hm.cull_mode = BaseMaterial3D.CULL_DISABLED
	hm.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	hm.disable_receive_shadows = true
	hm.albedo_texture = tex
	hm.albedo_color = colour
	mi.mesh.surface_set_material(0, hm)
	return mi


func _process(delta: float) -> void:
	# icSunAvatar Prepare (0x100d2b30): phase += dt * 0.010472
	_phase += delta * PHASE_RATE
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	if cam == null or _halo_a == null:
		return
	var cb := cam.global_transform.basis
	# roll = -atan2(sunY . cam_up, sunY . cam_right)  (0x100d2c22..0x100d2cf1)
	var sun_y := global_transform.basis.y.normalized()
	var roll := -atan2(sun_y.dot(cb.y), sun_y.dot(cb.x))
	# main scales this node to the star's (draw) radius; setting the halos'
	# GLOBAL basis bypasses that, so fold it back in
	var radius := global_transform.basis.get_scale().x
	# FLARE_BOOST widens the corona from the icSunAvatar's own 1.3x to the
	# lens-flare glow the player actually sees at range (the FcLensFlareNode
	# atlas is not extracted yet; the spiky sun_halo quadrant is its stand-in)
	_orient(_halo_a, cb, roll + _phase, HALO_SCALE * FLARE_BOOST * radius)
	_orient(_halo_b, cb, roll - _phase,
			HALO_SCALE * HALO_LAYER2 * FLARE_BOOST * radius)


func _orient(halo: MeshInstance3D, cb: Basis, roll: float, size: float) -> void:
	# FcBillBoard::Draw4x4 (flux.dll @ 0x1004c420): the quad's axes are the
	# camera right/up rotated by the roll --
	#   right' = right*cos - up*sin ;  up' = up*cos + right*sin
	var c := cos(roll)
	var s := sin(roll)
	var right := cb.x * c - cb.y * s
	var up := cb.y * c + cb.x * s
	halo.global_transform.basis = Basis(right * size, up * size, cb.z * size)


# The Draw4x4 primitive: an 8-triangle fan, centre UV (1, 1), corners at
# (0.008, 0.008) and edge midpoints at the texture's other two corners --
# one texture quadrant mirrored into all four.
# icShockwaveAvatar draws through the very same routine, so ExplosionFx
# shares this mesh.
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
