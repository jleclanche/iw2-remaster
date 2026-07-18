class_name FlareQuad
extends MeshInstance3D

# One FcLensFlareNode quad (flux.dll Render @ 0xe6100, constant-apparent-size
# branch). The world half-extent is
#     m_intensity_scale (15) x intensity x VIEW DEPTH
# where the depth is row 2 of the derived view transform applied to the
# node's world position (FUN_1004ca50) -- the FORWARD component, not the
# euclidean distance. That distinction is the whole off-axis behaviour: as
# the flare direction swings off-axis the quad narrows with cos(theta), its
# bright zone slides off the screen smoothly around ~70 degrees, and it is
# gone well before the 90-degree view plane. Sizing by euclidean distance
# instead kept the quad full-size until the near plane cut it in one frame --
# the hard "red pop".
#
# `tint` is the vertex colour the engine computes: (r^2, g^2, b^2) x alpha.
# `width_ratio` shrinks the Y axis for the anamorphic streak (1/6,
# m_anamorphic_streak_width_ratio @ 0x100ee4a0).

var intensity := 0.0
var tint := Color.WHITE
var width_ratio := 1.0
# LensFlareFade bit1 -> Render's flag-8 branch (flux.dll.c:215202-215206):
# the quad is a fixed WORLD size --
#     half-extent = m_intensity_scale x gfx+0x108 x intensity
# with NO view-depth term. gfx+0x108 is the camera's half-angle factor
# (tan of the horizontal half-fov -- the same factor FcBillBoard::Add uses
# for screen-filling quads), so the glow's world size tracks camera zoom
# and its apparent size at FlareNominalDistance stays put. The caller folds
# FlareNominalDistance (node +0xe4) into `intensity`.
var world_size := false


static func create(tex: Texture2D) -> FlareQuad:
	var mi := FlareQuad.new()
	var quad := QuadMesh.new()
	quad.size = Vector2(2.0, 2.0)  # unit half-extent; _process sizes it
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	mat.disable_receive_shadows = true
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mat.billboard_keep_scale = true
	mat.albedo_texture = tex
	quad.material = mat
	mi.mesh = quad
	# billboarding happens in the shader; culling uses the node-space bound,
	# so a flat quad slab pops out at a view angle -- bound a unit cube
	mi.custom_aabb = AABB(Vector3(-1, -1, -1), Vector3(2, 2, 2))
	return mi


func _process(_delta: float) -> void:
	if not is_inside_tree():
		return
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		visible = false
		return
	var rel := global_position - cam.global_position
	# camera forward is -Z; the basis is orthonormal, transposed = inverse
	var depth: float = -(cam.global_transform.basis.transposed() * rel).z
	if depth <= 1.0 or intensity <= 1e-7:
		visible = false
		return
	visible = true
	var span := depth
	if world_size:
		# gfx+0x108: tan of the horizontal half-fov (Godot's fov is vertical)
		var vp := get_viewport().get_visible_rect().size
		var aspect: float = vp.x / maxf(vp.y, 1.0)
		span = tan(deg_to_rad(cam.fov) * 0.5) * aspect
	var half := StarFx.INTENSITY_SCALE * intensity * span
	scale = Vector3(half, half * width_ratio, half)
	(mesh as QuadMesh).material.albedo_color = tint
