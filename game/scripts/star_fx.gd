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
#      radius * 1.4 (_DAT_1011a440) -- the extra 40% is the corona reaching
#      past the disc, which is what images/planets/sun_halo is for.
#   2. a lens flare at the sun's position (FcLensFlareNode, mode 0),
#   3. a second lens flare (mode 2) whose variant is 3 for class <= 2 and 1
#      otherwise.
# Both flares and both of the avatar's own colours come from
# icSun::PickColour(class), which LERPs the class's colour pair with rand().
#
# NOT RECOVERED: Ghidra leaves the icSunAvatar draw (0x100d2b30 / 0x100d2b80)
# undisassembled, so the corona's exact geometry and blend are unread.  What we
# do know from the assets and the ctor: sun_halo is ONE QUADRANT of a spiky
# corona, white on black, and the avatar's bound is 1.4x the disc.  We mirror
# the quadrant into a 2.8x-diameter billboard and add it.  See docs/geography.md.

const HALO_BOUND := 1.4  # _DAT_1011a440: icSunAvatar bounding radius multiplier

var _body: MeshInstance3D
var _halo: MeshInstance3D


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


func setup(rec: Dictionary, base: String) -> void:
	var stem := str(rec.get("sun_texture", "sun_yellow"))
	var pair: Array = rec.get("sun_colours", [[1.0, 1.0, 1.0], [1.0, 1.0, 1.0]])
	var h := absi(str(rec.get("name", "")).hash())
	var tint := _pick_colour(pair, h)
	var corona := _pick_colour(pair, h / 1000)

	# the body: the class's plasma texture, unshaded and emissive
	var sphere := SphereMesh.new()
	sphere.radius = 1.0
	sphere.height = 2.0
	sphere.radial_segments = 48
	sphere.rings = 24
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_texture = _tex(stem, base)
	mat.albedo_color = tint
	mat.emission_enabled = true
	mat.emission = tint
	mat.emission_energy_multiplier = 4.0
	if mat.albedo_texture != null:
		mat.emission_texture = mat.albedo_texture
		mat.emission_operator = BaseMaterial3D.EMISSION_OP_MULTIPLY
	sphere.material = mat
	_body = MeshInstance3D.new()
	_body.mesh = sphere
	add_child(_body)

	# the corona: sun_halo is one quadrant, so mirror it into four and add it
	_halo = MeshInstance3D.new()
	_halo.mesh = _halo_mesh()
	var hm := StandardMaterial3D.new()
	hm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	hm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	hm.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	hm.cull_mode = BaseMaterial3D.CULL_DISABLED
	hm.disable_receive_shadows = true
	hm.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	hm.billboard_keep_scale = true
	hm.albedo_texture = _tex("sun_halo", base)
	hm.albedo_color = corona
	hm.vertex_color_use_as_albedo = false
	_halo.mesh.surface_set_material(0, hm)
	_halo.scale = Vector3.ONE * HALO_BOUND
	add_child(_halo)


func _halo_mesh() -> ArrayMesh:
	# sun_halo.png is the +u/+v quadrant of the corona: four quads, each with
	# the UVs mirrored so the spikes meet at the centre of the star.
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	for qi in 4:
		var sx := 1.0 if qi == 0 or qi == 3 else -1.0
		var sy := 1.0 if qi < 2 else -1.0
		# quad corners, centre of the star at (0,0)
		var c := [Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)]
		var order := [0, 1, 2, 0, 2, 3]
		if sx * sy < 0.0:
			order = [0, 2, 1, 0, 3, 2]  # keep winding consistent when mirrored
		for i in order:
			var p: Vector2 = c[i]
			verts.append(Vector3(p.x * sx, p.y * sy, 0.0))
			uvs.append(Vector2(1.0 - p.x, 1.0 - p.y))
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_TEX_UV] = uvs
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return mesh
