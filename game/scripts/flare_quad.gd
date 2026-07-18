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
# FcLensFlareNode flags bit0 is set on EVERY flare node: when the base alpha
# local_58 (this+0xe0, throttled by the 2x-scale rule) exceeds 0.25, Render
# draws a SECOND quad -- pure white, m_white_centre_size_ratio (0.3
# @ 0x100ee4a4) of the main size, brightness (local_58 - 0.25) * 1.3333
# (0x100ee564) -- the incandescent core (flux.dll.c:215439..). Callers feed
# local_58 here each frame; -1 disables (for sub-quads like the streak,
# which are not flare nodes and carry no core).
var core_level := 1.0
const CORE_SIZE_RATIO := 0.3   # m_white_centre_size_ratio @ 0x100ee4a4
const CORE_BIAS := 0.25        # _DAT_100ec418
const CORE_GAIN := 1.3333      # _DAT_100ee564
var _core: MeshInstance3D
# LensFlareFade bit1 -> Render's flag-8 branch (flux.dll.c:215202-215206):
# the quad is a fixed WORLD size --
#     half-extent = m_intensity_scale x gfx+0x108 x intensity
# with NO view-depth term. gfx+0x108 is the camera's half-angle factor
# (tan of the horizontal half-fov -- the same factor FcBillBoard::Add uses
# for screen-filling quads), so the glow's world size tracks camera zoom
# and its apparent size at FlareNominalDistance stays put. The caller folds
# FlareNominalDistance (node +0xe4) into `intensity`.
var world_size := false


static func _flare_material(tex: Texture2D) -> StandardMaterial3D:
	# m_polygon_state (FUN_100e5cb0): eBlend 1 = pure ONE/ONE additive with
	# the "alpha" folded into RGB, depth test ON, depth write OFF. Godot's
	# BLEND_MODE_ADD is SRCALPHA/ONE, which equals ONE/ONE exactly while the
	# material colour's alpha stays 1 -- an invariant the callers keep (tint
	# alpha is never set below 1; brightness rides in the RGB).
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
	return mat

static func create(tex: Texture2D) -> FlareQuad:
	var mi := FlareQuad.new()
	var quad := QuadMesh.new()
	quad.size = Vector2(2.0, 2.0)  # unit half-extent; _process sizes it
	quad.material = _flare_material(tex)
	mi.mesh = quad
	# billboarding happens in the shader; culling uses the node-space bound,
	# so a flat quad slab pops out at a view angle -- bound a unit cube
	mi.custom_aabb = AABB(Vector3(-1, -1, -1), Vector3(2, 2, 2))
	# the white-centre overlay (flags bit0): same texture, 0.3x size
	var core_quad := QuadMesh.new()
	core_quad.size = Vector2(2.0, 2.0)
	core_quad.material = _flare_material(tex)
	mi._core = MeshInstance3D.new()
	mi._core.mesh = core_quad
	mi._core.scale = Vector3.ONE * CORE_SIZE_RATIO
	mi._core.custom_aabb = AABB(Vector3(-1, -1, -1), Vector3(2, 2, 2))
	mi.add_child(mi._core)
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
		# gfx+0x108 = tan(horizontal half-fov), PROVEN by the frustum test
		# (OutsideViewFrustrum, flux.dll.c:93217: |X| <= d * gfx+0x108) and
		# cot(fov/2) as the projection x-scale. Our cameras are KEEP_WIDTH
		# with fov binding the horizontal axis, so cam.fov IS that angle.
		span = tan(deg_to_rad(cam.fov) * 0.5)
	var half := StarFx.INTENSITY_SCALE * intensity * span
	if world_size and half > 0.0 and depth > 3000.0 * half:
		# m_cull_detail (3000 @ 0x100ee4b0): apparent half-size below
		# 1/3000 -> gone. (The 1/2000..1/3000 untextured point band of
		# m_point_detail is approximated by the shrinking quad.)
		visible = false
		return
	scale = Vector3(half, half * width_ratio, half)
	(mesh as QuadMesh).material.albedo_color = tint
	# the white centre: brightness (local_58 - 0.25) * 1.3333, clamped
	var cb := clampf((core_level - CORE_BIAS) * CORE_GAIN, 0.0, 1.0)
	if _core != null:
		_core.visible = cb > 0.0 and core_level >= 0.0
		if _core.visible:
			(_core.mesh as QuadMesh).material.albedo_color = Color(cb, cb, cb)
