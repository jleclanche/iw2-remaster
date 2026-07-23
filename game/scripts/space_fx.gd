class_name SpaceFx
extends Node3D

# The original's world-space HUD ("iiHUDUnderlayElement") drawn in 3D under the
# 2D HUD: icHUDReferenceGrid and icHUDLagrangeIcon. Both are pure procedural
# line geometry with hard-coded constants; every number below was read out of
# iwar2.dll. Addresses and derivations are in docs/hud.md.
#
# This node IS the reference grid. The Lagrange funnel is built through the
# static helpers, because the original attaches one funnel to an L-point sim
# and draws it in that sim's own frame.

# icHUDLagrangeIcon geometry, FUN_100eebf0 @ 0x100eebf0
const LP_SEGMENTS := 12  # angle step _DAT_1011dcbc = 0.523599 = TAU/12
const LP_RINGS := 7
const LP_LENGTH := 3000.0  # _DAT_1011dc7c
const LP_WAIST := 375.0  # DAT_1011dc80
# the element's cull sphere, computed at 0x100ee890 into DAT_10176050
const LP_BOUND := 2121.3203  # sqrt(3000 * 3000 * 0.5)
const LP_DRAW_DIST := 50000.0  # _DAT_1011dc84, hard cutoff
const LP_ALPHA_FAR := 0.4  # FUN_100e8960 arg a0
const LP_ALPHA_NEAR := 1.0  # arg a1
const LP_WAIST_COLOR := Color(0.5, 1.0, 0.0)  # DAT_10176038
# the -Z cone is the half you must be inside to jump (icLagrangePointWaypoint::
# TryToJump @ 0x1006ad40 refuses a jump unless the ship's offset has local z < 0)
const LP_ENTRY_COLOR := Color(0.0, 0.0, 1.0)
const LP_EXIT_COLOR := Color(1.0, 0.0, 0.0)

# icHUDReferenceGrid, FUN_100f5550 @ 0x100f5550
const GRID_STEPS := 9  # 9x9x9 lattice of streaks
const GRID_SPAN := 4.5  # _DAT_1011e030: lattice starts at -4.5 cells
const GRID_FADE_SPAN := 5.5  # far clip of the batch is (4.5 + 1) cells
const GRID_TRAIL := 1.0 / 3.0  # _DAT_10119454: streaks are 1/3 s of travel
const GRID_ALPHA_RATE := 0.007  # _DAT_1011b358: full alpha at ~142.9 m/s
const GRID_DECADE_BIAS := 0.3  # _DAT_1011c034
const GRID_DECADE_MIN := 3  # cell size clamped to 1e3 .. 1e10 m (asm 0x100f576a)
const GRID_DECADE_MAX := 10
const GRID_COLOR_LDS := Color(0.5, 1.0, 0.0)  # DAT_10176038
const GRID_COLOR := Color(1.0, 0.592, 0.0)  # DAT_10174fb0, 0x3f178d50 = 0.592

static var _lp_lines: Array = []  # [[Vector3 p0, Vector3 p1, Color rgb], ...]

var _mat: StandardMaterial3D

# The grid is 729 streaks = 1458 vertices. Rebuilding an ImmediateMesh with that
# many individual surface_add_vertex calls, once per frame, from GDScript, is far
# too slow. An ArrayMesh filled from pre-sized packed arrays and committed in one
# go costs a fraction of it.
var _grid_mesh: ArrayMesh
var _grid_mi: MeshInstance3D
var _gv: PackedVector3Array
var _gc: PackedColorArray

# The simulation ticks at 60 Hz but the game renders faster, and the grid is the
# player's only sense of motion: rebuilt on the physics tick it visibly steps
# while everything around it flows. So it is rebuilt every *rendered* frame, from
# the last known state, with the position carried forward by the velocity.
var _cam: Camera3D
# the TRUE position is held as three 64-bit floats, NOT a Vector3: at map
# coordinates (1e12 m from the system centre) a Vector3's 32-bit components
# quantise to ~1e5 m, and fmod-ing that against a 1000 m cell is pure noise --
# the lattice anchor wandered (the reported "streaks slide upward").
var _px := 0.0
var _py := 0.0
var _pz := 0.0
var _vel := Vector3.ZERO
var _lds := false
var _hidden := true

func _init() -> void:
	_mat = _line_material()
	_grid_mesh = ArrayMesh.new()
	_grid_mi = MeshInstance3D.new()
	_grid_mi.mesh = _grid_mesh
	_grid_mi.material_override = _mat
	# the lattice is in scene space around the ship; it must never be culled by
	# its own (empty) starting AABB
	_grid_mi.custom_aabb = AABB(Vector3.ONE * -1.0e9, Vector3.ONE * 2.0e9)
	add_child(_grid_mi)
	var n := GRID_STEPS * GRID_STEPS * GRID_STEPS * 2
	_gv.resize(n)
	_gc.resize(n)
	set_process(true)


func _process(delta: float) -> void:
	_px += _vel.x * delta
	_py += _vel.y * delta
	_pz += _vel.z * delta
	_render_grid()
	_update_aggressor(delta)
	_render_nebula()
	_nebshot(delta)


# --- icAggressorAvatar -------------------------------------------------------
# @element icAggressorAvatar
# The aggressor shield's avatar (lws:/avatars/aggressor_shield/setup, named by
# both shipped aggressor INIs). Registered at 0x100b9050, ctor 0x100b9280,
# Prepare 0x100b9460, Draw 0x100b94e0.
#
# It is the SAME cone fan icLDAAvatar draws: Draw's only geometry call is
# FUN_100c9f40 @ 0x100b95e1 -- the 16-triangle apex-at-+Z fan already
# transcribed in explosion_fx.gd. What differs is the dressing:
#   * texture:/images/sfx/aggressor  (ctor, 0x101615b8)
#   * additive, the same blend-2 polygon state
#   * rim radius = node +0xbc, ctor default 0.1 (0x3dcccccd @ 0x100b9280)
#   * the texture's v scrolls at 1 unit/s off the node's own clock (+0xc0,
#     accumulated from m_game_delta_time_seconds in Prepare; the 1.0 is
#     0x1011c824), with v1 = v0 + 1 -- so it crawls forward over the cone
#   * it is up exactly while the shield's "fire" channel is 1 -- which
#     icAggressorShield::Simulate sets from the active flag (0x1002f44f)
#
# The world scale is NOT a radius: icAggressorShield::Simulate writes the avatar
# node's transform every frame (0x1002f464..0x1002f4f5) from the hull's own
# dimensions -- iiThrusterSim Width/Height/Length (+0x208/0x20c/0x210, the ship
# INI's width/height/length keys):
#
#     node.scale    = (W*0.8, H, min(W*0.8, H) * 0.5)
#     node.position = (0, 0, L*0.75)
#
# and icAggressorAvatar::Draw (0x100b94e0) hands the shared LDA fan a rim radius
# of exactly 1.0 (immediate at 0x100b95dc) with the apex at +0xbc = the `depth`
# property. So the cone is unit-sized and the hull dimensions do all the work:
# on the tug (80/70/120) that is a 128 x 140 m ellipse standing ~84-103 m off
# the nose, not a 95 m sphere.
#
# avatars/aggressor_shield/setup carries TWO cones under the `fire?+s(1.5)`
# grow-in: shallow (depth 0.2) at z +0.2 and deep (depth 0.4) at z -0.2.
const AGG_RIM := 1.0          # hardcoded rim radius, 0x100b95dc
const AGG_SCROLL := 1.0       # 0x1011c824, v units per second
const AGG_DEPTH_SHALLOW := 0.2  # setup.json cone `depth`, at z +0.2
const AGG_DEPTH_DEEP := 0.4     # setup.json cone `depth`, at z -0.2
const AGG_SCALE_XY := 0.8     # 0x1011959c
const AGG_SCALE_Z := 0.5      # 0x10117738
const AGG_NOSE := 0.75        # 0x10117d8c
const AGG_RAMP := 1.5         # the `fire?+s(1.5)` channel's linear rate limit

var _agg_root: Node3D
var _agg_cones: Array[MeshInstance3D] = []
var _agg_mat: StandardMaterial3D
var _agg_clock := 0.0
var _agg_ramp := 0.0

func _ensure_aggressor(base: String) -> void:
	if _agg_root != null:
		return
	var tex := ParticleFx.texture(base, "images/sfx/aggressor")
	_agg_mat = ExplosionFx._blend2_material(tex)
	_agg_mat.vertex_color_use_as_albedo = true
	# `root` -> `ship_nose_pos`: the node Simulate drives. Both are authored
	# identity in the LWS, so one node stands in for the pair.
	_agg_root = Node3D.new()
	_agg_root.visible = false
	add_child(_agg_root)
	for cone in [[AGG_DEPTH_SHALLOW, 0.2], [AGG_DEPTH_DEEP, -0.2]]:
		var depth: float = cone[0]
		var mi := MeshInstance3D.new()
		# the shared LDA fan: rim radius 1 at z 0 (apex alpha 1, rim alpha 0 --
		# the aggressor's apex never fades, 0x100b95d6/0x100b95d4), apex at z 1,
		# so scaling z by `depth` puts the apex at +0xbc
		mi.mesh = ExplosionFx.lda_cone_mesh()
		mi.mesh.surface_set_material(0, _agg_mat)
		mi.position = Vector3(0, 0, cone[1])
		mi.scale = Vector3(AGG_RIM, AGG_RIM, depth)
		_agg_root.add_child(mi)
		_agg_cones.append(mi)

## Called each frame by main: `up` is ShipSystems.aggressor_active().
## `dims` is the hull's (width, height, length) -- the ship INI keys.
func set_aggressor(base: String, up: bool, xform: Transform3D,
		dims: Vector3) -> void:
	_ensure_aggressor(base)
	if not up:
		_agg_root.visible = false
		_agg_clock = 0.0
		_agg_ramp = 0.0
		return
	_agg_root.visible = true
	# the cone points dead ahead, down the ship's local +Z -- the axis the
	# shield's coverage cone is measured about (0x1002f810) -- and stands
	# L*0.75 off the nose along it
	var nose := xform.translated_local(Vector3(0, 0, dims.z * AGG_NOSE))
	var sx: float = dims.x * AGG_SCALE_XY
	var sy: float = dims.y
	# the grow-in: the `fire?+s(1.5)` channel ramps the whole rig 0 -> 1
	var s := Vector3(sx, sy, minf(sx, sy) * AGG_SCALE_Z) * _agg_ramp
	_agg_root.global_transform = Transform3D(nose.basis.scaled(s), nose.origin)

func _update_aggressor(delta: float) -> void:
	if _agg_root == null or not _agg_root.visible:
		return
	_agg_ramp = minf(1.0, _agg_ramp + AGG_RAMP * delta)
	_agg_clock += delta
	# v scrolls forward at 1 unit/s (Draw: v0 = +0xc4 - clock, v1 = v0 + 1)
	_agg_mat.uv1_offset.y = -_agg_clock * AGG_SCROLL

static func _line_material() -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.vertex_color_use_as_albedo = true
	mat.albedo_color = Color(1, 1, 1, 1)
	return mat

# --- icHUDLagrangeIcon -------------------------------------------------------
# @element icHUDLagrangeIcon
# @element icHUDWaypointIcon

static func _lp_build() -> void:
	if not _lp_lines.is_empty():
		return
	var verts: Array[Vector3] = []
	for r in LP_RINGS:
		var z: float = LP_LENGTH * -0.5 + r * LP_LENGTH / 6.0
		# (3 - 2*cos(z*pi/len)) * 375: waist 375 m at z=0, mouth 1125 m at +-1500
		var rad: float = (3.0 - 2.0 * cos(z * PI / LP_LENGTH)) * LP_WAIST
		for i in LP_SEGMENTS:
			var a: float = i * TAU / LP_SEGMENTS
			verts.append(Vector3(cos(a) * rad, sin(a) * rad, z))
	# the index list starts with the waist ring on its own, which is why the
	# waist is the only part in the third colour
	for i in LP_SEGMENTS:
		var v0: int = 3 * LP_SEGMENTS + i
		var v1: int = 3 * LP_SEGMENTS + (i + 1) % LP_SEGMENTS
		_lp_lines.append([verts[v0], verts[v1], LP_WAIST_COLOR])
	_lp_cone(verts, 0, LP_ENTRY_COLOR)
	_lp_cone(verts, 4, LP_EXIT_COLOR)

static func _lp_cone(verts: Array[Vector3], base: int, col: Color) -> void:
	# three rings of circumference, but spokes only between the first two pairs:
	# the original never spokes across the waist, so the cones stay separate
	for n in 3:
		var r: int = base + n
		for i in LP_SEGMENTS:
			var v0: int = r * LP_SEGMENTS + i
			var v1: int = r * LP_SEGMENTS + (i + 1) % LP_SEGMENTS
			_lp_lines.append([verts[v0], verts[v1], col])
			if n < 2:
				_lp_lines.append([verts[v0], verts[v0 + LP_SEGMENTS], col])

static func make_lagrange_icon(axis: Vector3) -> MeshInstance3D:
	_lp_build()
	var mi := MeshInstance3D.new()
	mi.mesh = ImmediateMesh.new()
	mi.material_override = _line_material()
	# the funnel lives in the L-point's frame with the jump axis on local +Z
	var z := axis.normalized()
	if z.length_squared() < 0.5:
		z = Vector3.BACK
	var up := Vector3.UP if absf(z.dot(Vector3.UP)) < 0.99 else Vector3.RIGHT
	var x := up.cross(z).normalized()
	mi.basis = Basis(x, z.cross(x).normalized(), z)
	return mi


# A mission waypoint is NOT an L-point funnel: icHUDWaypointIcon's ctor
# (iwar2 @ 0x10104040 -> mesh builder @ 0x10104380) builds a WIREFRAME CUBE --
# eight vertices at ((i,j,k) - 0.5) x scale for i,j,k in {0,1}, and these
# twelve edge index pairs, verbatim from the builder's index buffer. The edge
# length (_DAT_1011e2b4) and the element's colour are data-section values not
# in the decompiled text: the funnel's visual scale and the HUD colour stand
# in for them.
const WP_EDGES: Array = [[0, 1], [1, 5], [5, 4], [4, 0], [2, 3], [3, 7],
	[7, 6], [6, 2], [0, 2], [1, 3], [5, 7], [4, 6]]
const WP_HALF := 375.0          # stand-in: the funnel's waist radius

static func make_waypoint_icon() -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = ImmediateMesh.new()
	mi.material_override = _line_material()
	return mi

static func update_waypoint_icon(mi: MeshInstance3D, cam: Camera3D) -> void:
	# same cutoff and per-endpoint depth fade as the funnel: both are
	# iiHUDUnderlayElements and share the fade helper (FUN_100e8b30)
	var mesh := mi.mesh as ImmediateMesh
	mesh.clear_surfaces()
	if cam == null:
		return
	var xf := mi.global_transform
	var eye := cam.global_transform.origin
	var fwd := -cam.global_transform.basis.z
	var dist := fwd.dot(xf.origin - eye)
	if dist > LP_DRAW_DIST:
		return
	var far: float = dist + WP_HALF * 2.0
	if far <= 0.0:
		return
	var corners: Array[Vector3] = []
	for i in 2:
		for j in 2:
			for k in 2:
				corners.append(
					Vector3(i - 0.5, j - 0.5, k - 0.5) * 2.0 * WP_HALF)
	mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	for edge: Array in WP_EDGES:
		for e in 2:
			var p: Vector3 = corners[edge[e]]
			var t: float = clampf(1.0 - fwd.dot(xf * p - eye) / far, 0.0, 1.0)
			var col := GRID_COLOR
			col.a = LP_ALPHA_FAR + (LP_ALPHA_NEAR - LP_ALPHA_FAR) * t
			mesh.surface_set_color(col)
			mesh.surface_add_vertex(p)
	mesh.surface_end()

static func update_lagrange_icon(mi: MeshInstance3D, cam: Camera3D,
		active: bool) -> void:
	var mesh := mi.mesh as ImmediateMesh
	mesh.clear_surfaces()
	# the original draws a funnel for the NEAREST L-point only
	# (icPlayerContactList::NearestLagrangePoint), and only inside 50 km
	if not active or cam == null:
		return
	var xf := mi.global_transform
	var eye := cam.global_transform.origin
	var fwd := -cam.global_transform.basis.z
	var dist := fwd.dot(xf.origin - eye)
	if dist > LP_DRAW_DIST:
		return
	var far: float = dist + LP_BOUND
	if far <= 0.0:
		return
	mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	for line in _lp_lines:
		var col: Color = line[2]
		for e in 2:
			var p: Vector3 = line[e]
			# alpha = lerp(0.4, 1.0, t), t = 1 - depth/far: bright up close,
			# tending to 0.4 at range (FUN_100e8b30's per-endpoint fade)
			var t: float = clampf(1.0 - fwd.dot(xf * p - eye) / far, 0.0, 1.0)
			col.a = LP_ALPHA_FAR + (LP_ALPHA_NEAR - LP_ALPHA_FAR) * t
			mesh.surface_set_color(col)
			mesh.surface_add_vertex(p)
	mesh.surface_end()

# --- icHUDReferenceGrid ------------------------------------------------------
# @element icHUDReferenceGrid

static func grid_cell(speed: float) -> float:
	# spacing snaps to a decade chosen by speed, clamped to 1e3 .. 1e10 m
	var e: int = clampi(int(floor(log(speed) / log(10.0) + GRID_DECADE_BIAS)),
		GRID_DECADE_MIN, GRID_DECADE_MAX)
	return pow(10.0, e)

## Called from the simulation tick. Only records the state; the mesh itself is
## rebuilt on every rendered frame in _process, or the streaks step at 60 Hz
## while the world around them flows.
func update_grid(cam: Camera3D, px: float, py: float, pz: float, vel: Vector3,
		lds: bool, hidden: bool) -> void:
	_cam = cam
	_px = px
	_py = py
	_pz = pz
	_vel = vel
	_lds = lds
	_hidden = hidden


func _render_grid() -> void:
	_grid_mesh.clear_surfaces()
	var speed := _vel.length()
	if _hidden or _cam == null or speed < 1e-6:
		return
	var cell := grid_cell(speed)
	var fade := clampf(speed * GRID_ALPHA_RATE, 0.0, 1.0)
	var streak := _vel * GRID_TRAIL
	var far := GRID_FADE_SPAN * cell
	# the lattice is anchored to absolute world coordinates and slides through
	# the ship: the fmod pins it to a world grid, not to the ship
	# 64-bit anchor math, and fposmod so the wrap has no sign flip at the
	# coordinate origin
	var start := Vector3(
		-GRID_SPAN * cell - fposmod(_px, cell),
		-GRID_SPAN * cell - fposmod(_py, cell),
		-GRID_SPAN * cell - fposmod(_pz, cell))
	var rgb := GRID_COLOR_LDS if _lds else GRID_COLOR
	var eye := _cam.global_transform.origin
	var fwd := -_cam.global_transform.basis.z
	var n := 0
	for i in GRID_STEPS:
		for j in GRID_STEPS:
			for k in GRID_STEPS:
				var p := start + Vector3(i, j, k) * cell
				var q := p - streak
				var col := rgb
				col.a = fade * clampf(1.0 - fwd.dot(p - eye) / far, 0.0, 1.0)
				_gv[n] = p
				_gc[n] = col
				n += 1
				col.a = fade * clampf(1.0 - fwd.dot(q - eye) / far, 0.0, 1.0)
				_gv[n] = q
				_gc[n] = col
				n += 1
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = _gv
	arrays[Mesh.ARRAY_COLOR] = _gc
	_grid_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrays)


# --- icHUDContrails ----------------------------------------------------------
# @element icHUDContrails
# Update = FUN_100e4c80, Draw = FUN_100e4e60 (vtable 0x1011daa8 slots 10 and 9;
# Ghidra dropped both, recovered from raw bytes). An iiHUDUnderlayElement: it is
# drawn in the world, under the 2D HUD, like the reference grid.
#
# The 0x1708 object decodes exactly: 8 trails of 16 points, 44 bytes a point.
#
#   WHO GETS ONE (FUN_100e5390): a contact that is a ship, is moving faster than
#   50 m/s (_DAT_1011da98), and is within 50 km (_DAT_1011daa0) -- raised to
#   150 km (_DAT_1011da9c) while that ship's own LDS drive is engaged. Eight at
#   most; the currently selected TARGET always takes the first slot (icHUD+0x104,
#   set from icPlayerContactList::Target() in the HUD refresh FUN_100e09e0). The
#   player's OWN ship is never in its own contact list, so it never gets a trail.
#
#   EMISSION (FUN_100e5440): one global countdown, reloaded to 0.4 s
#   (_DAT_1011da8c). It is NOT distance-based -- every trail drops a point at the
#   same instant, 2.5 times a second. The ring holds 16, so a trail spans exactly
#   16 * 0.4 = 6.4 s.
#
#   FADE: a point's life starts at 0.7 (_DAT_1011daa4) and decays by 0.109375/s
#   -- a constant the engine DERIVES at 0x100e4b80 as 0.7 / (0.4 * 16), i.e. it
#   reaches zero exactly as the ring wraps. life is used as BOTH the alpha and
#   the line width. When a trail stops qualifying it gets a 2 s grace fade
#   (_DAT_1011da94) before its slot is freed.
#
#   THE TARGET'S IS A LADDER (FUN_100e5520): the Draw (FUN_100e4e60 @ 0x100e4f34)
#   gives the ladder to the ONE trail whose contact sim == icHUD+0x108 (the
#   selected target) and a plain centre line to every OTHER trail -- decided per
#   FRAME, not baked at emit, so re-targeting reshapes the trails at once. The
#   ladder is two rails offset +/- halfspan along the sim's local X axis AT THE
#   MOMENT EACH POINT WAS EMITTED, plus a rung across every point. halfspan =
#   icShip::width (+0x208, the TARGET's INI `width`) * 0.5 (FUN_100e5b70), scaled
#   in over a 0.35 s splay ramp (_DAT_1011da90) each time the element is shown --
#   so the trail opens out from the centreline. The rails are SKIPPED on points
#   whose LDS flag is set (the flag is head & 1 while the drive is engaged), which
#   makes them come out dashed under LDS; the rungs always draw.
#
#   DEPTH: the shared line batch is set up with z0=0, z1=50000, alpha and width
#   both = 1 - depth/50000 -- a linear fade to nothing at the eligibility range.
const CT_TRAILS := 8            # the 8 slots in the 0x1708 object
const CT_POINTS := 16           # ring length
const CT_EMIT := 0.4            # _DAT_1011da8c, seconds between points
const CT_LIFE := 0.7            # _DAT_1011daa4, a point's life/alpha at emit
const CT_DECAY := 0.109375      # DAT_10173f5c = 0.7 / (0.4 * 16), @ 0x100e4b80
const CT_SPLAY := 0.35          # _DAT_1011da90, the ladder's open-out ramp
const CT_GRACE := 2.0           # _DAT_1011da94, fade-out once it stops qualifying
const CT_MIN_SPEED := 50.0      # _DAT_1011da98, m/s
const CT_RANGE := 50000.0       # _DAT_1011daa0
const CT_RANGE_LDS := 150000.0  # _DAT_1011da9c

var _ct_mi: MeshInstance3D
var _ct_mesh: ArrayMesh
var _ct_trails: Dictionary = {}   # ship -> {points: Array, grace: float}
var _ct_target: Node3D = null     # the trail drawn as a ladder (icHUD+0x108)
var _ct_emit := 0.0
var _ct_ramp := 0.0

# The age/decay pass (FUN_100e5280) also SUBTRACTS THE WORLD DELTA from every
# stored point each frame -- the original's camera-relative world moves the
# same way main._fold_motion recentres ours. Without this the stored points
# ride the fold: the target's ladder glues itself to that ship and swims with
# every burn, and other ships' lines end up hundreds of metres from the ship
# that emitted them. (This was the "buggy rails".)
func shift_world(offset: Vector3) -> void:
	for node in _ct_trails:
		for p: Dictionary in (_ct_trails[node]["points"] as Array):
			p["pos"] = (p["pos"] as Vector3) - offset

func _ensure_contrails() -> void:
	if _ct_mi != null:
		return
	_ct_mesh = ArrayMesh.new()
	_ct_mi = MeshInstance3D.new()
	_ct_mi.mesh = _ct_mesh
	_ct_mi.material_override = _line_material()
	_ct_mi.custom_aabb = AABB(Vector3.ONE * -1.0e9, Vector3.ONE * 2.0e9)
	add_child(_ct_mi)

## `ships` is [{node, vel, width, lds, col}], target first; `target` is the
## contact drawn as a ladder (null -> all centre lines); `hidden` blanks it.
func update_contrails(delta: float, ships: Array, target: Node3D,
		hidden: bool) -> void:
	_ensure_contrails()
	_ct_target = target
	if hidden:
		_ct_mi.visible = false
		_ct_ramp = 0.0
		_ct_trails.clear()
		return
	_ct_mi.visible = true
	# the splay ramp restarts whenever the element is (re)shown
	_ct_ramp = minf(_ct_ramp + delta, CT_SPLAY)

	# --- who qualifies -------------------------------------------------------
	var live: Dictionary = {}
	for s: Dictionary in ships:
		if live.size() >= CT_TRAILS:
			break
		var node = s["node"]
		if node == null or not is_instance_valid(node):
			continue
		var vel: Vector3 = s.get("vel", Vector3.ZERO)
		if vel.length() <= CT_MIN_SPEED:
			continue
		var reach: float = CT_RANGE_LDS if bool(s.get("lds", false)) else CT_RANGE
		if (node as Node3D).global_position.length() > reach:
			continue
		live[node] = s

	# --- emit ----------------------------------------------------------------
	_ct_emit -= delta
	var emit := _ct_emit <= 0.0
	if emit:
		_ct_emit = CT_EMIT
	for node: Node3D in live:
		var s: Dictionary = live[node]
		if not _ct_trails.has(node):
			_ct_trails[node] = {"points": [], "grace": 0.0}
		var tr: Dictionary = _ct_trails[node]
		tr["grace"] = 0.0
		if emit:
			(tr["points"] as Array).append({
				"pos": node.global_position,
				# the sim's local X at the instant of emission: the wingtip axis
				"right": node.global_transform.basis.x,
				"lds": bool(s.get("lds", false)) \
					and (tr["points"] as Array).size() % 2 == 1,
				"life": CT_LIFE,
				"width": float(s.get("width", 0.0)),
				"col": Color(s.get("col", Color(0.6, 0.9, 0.6))),
			})
			while (tr["points"] as Array).size() > CT_POINTS:
				(tr["points"] as Array).pop_front()

	# --- age, grace, reap ----------------------------------------------------
	for node in _ct_trails.keys():
		var tr: Dictionary = _ct_trails[node]
		if not live.has(node):
			tr["grace"] = float(tr["grace"]) + delta
			if float(tr["grace"]) >= CT_GRACE or not is_instance_valid(node):
				_ct_trails.erase(node)
				continue
		for p: Dictionary in (tr["points"] as Array):
			p["life"] = maxf(0.0, float(p["life"]) - delta * CT_DECAY)
	_render_contrails()

func _render_contrails() -> void:
	_ct_mesh.clear_surfaces()
	var v := PackedVector3Array()
	var col := PackedColorArray()
	for node in _ct_trails:
		var tr: Dictionary = _ct_trails[node]
		var pts: Array = tr["points"]
		if pts.size() < 2:
			continue
		# the ladder goes to the ONE trail that is the current target; every
		# other trail is a centre line (FUN_100e4e60 @ 0x100e4f34, per frame)
		var ladder: bool = _ct_target != null and node == _ct_target
		# the grace fade multiplies every alpha in the trail
		var tail: float = 1.0 - float(tr["grace"]) / CT_GRACE
		for i in range(pts.size() - 1):
			var p: Dictionary = pts[i]
			var q: Dictionary = pts[i + 1]
			var ap := _ct_alpha(p, tail)
			var aq := _ct_alpha(q, tail)
			if ap <= 0.0 and aq <= 0.0:
				continue
			var cp := Color(p["col"], ap)
			var cq := Color(q["col"], aq)
			if not ladder:
				# every other contact: one centre line (FUN_100e59d0)
				v.append(p["pos"]); col.append(cp)
				v.append(q["pos"]); col.append(cq)
				continue
			# the target: a ladder (FUN_100e5520)
			var hs: float = float(p["width"]) * 0.5 * (_ct_ramp / CT_SPLAY)
			var op: Vector3 = (p["right"] as Vector3) * hs
			var oq: Vector3 = (q["right"] as Vector3) * hs
			if not bool(p["lds"]):
				# the rails, skipped on an LDS-flagged point -> dashed under LDS
				v.append(p["pos"] - op); col.append(cp)
				v.append(q["pos"] - oq); col.append(cq)
				v.append(p["pos"] + op); col.append(cp)
				v.append(q["pos"] + oq); col.append(cq)
			# the rung is always drawn, both ends at the newer point's alpha
			v.append(q["pos"] - oq); col.append(cq)
			v.append(q["pos"] + oq); col.append(cq)
	if v.is_empty():
		return
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = v
	arr[Mesh.ARRAY_COLOR] = col
	_ct_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arr)

func _ct_alpha(p: Dictionary, tail: float) -> float:
	# alpha = grace_fade * point.life, then the depth fade: 1 - depth/50000,
	# which the engine applies through the shared line batch
	var depth: float = (p["pos"] as Vector3).length()
	var dz: float = clampf(1.0 - depth / CT_RANGE, 0.0, 1.0)
	return clampf(tail * float(p["life"]) * dz, 0.0, 1.0)


# --- inside the nebula ------------------------------------------------------
# @element icNebula
# @element icCloudAvatar
#
# icNebula (registered 0x10067450, ctor 0x10067660, 0x200 bytes) is a real
# geography SIM with a position and a radius -- the player flies INSIDE it. Map
# kind 7; icSolarSystem::ParseNebulaInfo (0x1004e4f0) takes its radius from the
# record's +0x134 (like a belt, NOT the +0x138 the bodies use). The whole game
# ships exactly one: The Effrit, Hoffer's Wake, r = 2.5e8 m, with Lucrecia's
# Base 750 m from its centre. Its property map (0x100674f0) is three fields --
# depth (+0x1e0), colour (+0x1e4), texture_url (+0x1f0) -- and the map record
# carries none of them, so The Effrit runs on the ctor's defaults.
#
# icNebula::Think (0x10067870) asks 0x10067990 for the opacity ramp each tick,
# and on the 0 -> non-0 edge calls icSolarSystem::EnterNebula (0x1004eaa0), then
# icSolarSystem::SetNebulaOpacity (0x1004eaf0) every tick after. That opacity
# drives icSolarSystem::Render (0x1004d150), which
#   * turns hardware fog ON, coloured `colour`, from 100 m out to
#     lerp(far_clip -> depth, opacity), and pulls the far clip in to end * 1.1;
#   * STOPS adding the starfield and the geog cyclorama once opacity hits 1;
#   * adds the icCloudAvatar singleton (DAT_10171638, made at 0x100c27e0) with
#     its +0x16c set to the opacity.
#
# icCloudAvatar is what you actually see. Draw @ 0x100c2bf0 (vtable slot 17,
# dropped by Ghidra -- raw-disassembled) walks a 4-CELL RING of screen-filling
# billboards at z = phase + (3-j) * cell, cell = depth * 0.25. Each cell carries
# a random UV offset and a random UV scale; as you fly, `phase` slides by the
# camera's forward displacement and the cell that falls off the front or the back
# is recycled with fresh randoms. All four layers share one UV scroll and one
# roll angle, both driven by the camera's own rotation and translation
# (0x100c3150 / 0x100c3700). Blend 2 = SRCALPHA-ONE (additive), ZWrite off, fog
# off, texture texture:/images/sfx/cloud, tinted by the nebula colour.
# Draw @ 0x100c2a40 (slot 16) is the other half: one untextured, alpha-blended,
# Z-WRITING quad of the flat nebula colour at z = depth -- the wall that hides
# everything past the visibility distance. We fold that into Godot's depth fog
# (same colour, same 100 m .. depth range, sky included), which also stands in
# for the hardware fog the original switches on alongside it.
#
# (The per-cell random rotation the ctor also rolls, +0xc of each cell, is never
# read by either Draw. It is dead in the original; we do not generate it.)

const NEB_INNER := 0.75  # _DAT_10117d8c: opacity is 1 inside 0.75 * radius
const NEB_CELLS := 4  # the ring in icCloudAvatar's ctor, +0xdc, stride 0x10
const NEB_CELL_FRAC := 0.25  # _DAT_101191ec: cell size = depth * 0.25
const NEB_FAR_CELLS := 4.0  # _DAT_101190b4: the layers reach out to 4 cells
const NEB_FADE_FRAC := 0.5  # _DAT_10117738: distance fade starts at far * 0.5
const NEB_ALPHA := 0.4  # _DAT_10117558: peak layer alpha = opacity * 0.4
const NEB_FOG_START := 100.0  # icSolarSystem::Render's fog start, meters
const NEB_FAR_CLIP := 1.1  # _DAT_10119e94: Render pulls the far plane to end * 1.1
# main.gd::_setup_sky parks the geog backdrop dome at 4.8e5 m. Ours, not the
# original's -- so it is ours to get out of the way of the far plane.
const NEB_SKY_DOME := 5.0e5
# where the stand-in cyclorama wall sits, as a fraction of the far plane: just
# inside it. Port geometry, not an extracted constant -- the wall is fully
# fogged anywhere past fog_end, so its exact depth changes nothing on screen.
const NEB_SKY_Z := 0.98
const NEB_SCALE_MIN := 0.1  # 0x3dcccccd \ the per-cell random UV scale
const NEB_SCALE_MAX := 0.3  # 0x3e99999a /
# icNebula's ctor defaults, which is what The Effrit runs on. (The only sim that
# overrides them is the multiplayer fog_cloud_10000k.ini: r = 1e7, depth = 1e4,
# colour = (0.1, 0.55, 0.44), texture images/sfx/alien_cloud.)
const NEB_DEPTH := 30000.0  # 0x46ea6000
const NEB_COLOUR := Color(0.6745098, 0.2784314, 0.0823529)  # +0x1e4
const NEB_TEXTURE := "images/sfx/cloud"  # +0x1f0

var _neb: Dictionary = {}  # the resolved map record; {} = no nebula here
var _neb_stem := ""  # the system the record was resolved for
var _neb_quads: Array[MeshInstance3D] = []
var _neb_sky: MeshInstance3D = null  # the stand-in cyclorama wall (see below)
var _neb_cells: Array = []  # [{uv: Vector2, scale: float}, ...], NEB_CELLS long
var _neb_idx := 0  # icCloudAvatar+0x11c: which cell is the far one
var _neb_phase := 0.0  # +0x120: how far into the front cell we are, meters
var _neb_uv := Vector2.ZERO  # +0x130/+0x134: the shared UV scroll
var _neb_angle := 0.0  # +0x138: the shared roll
var _neb_prev := Vector3.ZERO  # last camera sim position
var _neb_prev_basis := Basis.IDENTITY
var _neb_seeded := false
var _neb_fogged := false  # did WE turn the environment's fog on?
var _neb_far0 := 0.0  # m_far_clip: the far plane outside the nebula, latched

## icNebula::Think's ramp, 0x10067990: full opacity inside 0.75 * radius, then
## linear to nothing at the rim. A plain sphere test -- there is no falloff
## outside and no density model, the volume is uniform.
static func nebula_opacity(dist: float, radius: float) -> float:
	if radius <= 0.0 or dist >= radius:
		return 0.0
	var inner := radius * NEB_INNER
	if dist <= inner:
		return 1.0
	return 1.0 - (dist - inner) / (radius - inner)

func _neb_resolve() -> void:
	var m := get_parent()
	if m == null or not ("objects" in m) or not ("system_stem" in m):
		return
	var stem: String = m.system_stem
	if stem == _neb_stem:
		return
	_neb_stem = stem
	_neb = {}
	for o in m.objects:
		if str(o.get("category", "")) == "nebula" \
				and float(o.get("radius", 0.0)) > 0.0:
			_neb = o
			break
	_neb_seeded = false

func _neb_build() -> void:
	var base := ProjectSettings.globalize_path("res://").path_join("..")
	var url := str(_neb.get("texture_url", NEB_TEXTURE))
	var tex: Texture2D = ParticleFx.texture(base, url)
	var quad := QuadMesh.new()
	quad.size = Vector2(2.0, 2.0)  # verts at +/-1; the transform does the sizing
	for i in NEB_CELLS:
		var sh := Shader.new()
		sh.code = NEB_SHADER
		var mat := ShaderMaterial.new()
		mat.shader = sh
		mat.set_shader_parameter("tex", tex)
		# the original draws the nebula as part of the sky backdrop, BEFORE
		# the planets pass (icPlanetsAvatar::Render 0x100cf220 runs "right
		# after the cyclorama"); Godot's transparent queue sorts by distance,
		# which painted this camera-range wall OVER a planet behind it
		# (Eureka's Belial). render_priority pins the painter order.
		mat.render_priority = -30
		var mi := MeshInstance3D.new()
		mi.mesh = quad
		mi.material_override = mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.visible = false
		add_child(mi)
		_neb_quads.append(mi)
	var sky_sh := Shader.new()
	sky_sh.code = NEB_SKY_SHADER
	var sky_mat := ShaderMaterial.new()
	sky_mat.shader = sky_sh
	sky_mat.render_priority = -30  # backdrop wall: same painter slot
	_neb_sky = MeshInstance3D.new()
	_neb_sky.mesh = quad
	_neb_sky.material_override = sky_mat
	_neb_sky.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_neb_sky.visible = false
	add_child(_neb_sky)

# the four corners the original hands FcBillBoard::Add are uv_c +/- uv_a +/- uv_b
# (0x100c2f26 .. 0x100c2fc9): a rotated, scaled square in texture space centred
# on the scroll position. images/sfx/cloud is greyscale with no alpha channel, so
# under SRCALPHA-ONE the dark half of the tile simply adds nothing.
#
# `source_color` and the linearised tint matter here. The original adds the layers
# in 8-bit gamma space, where a mid-grey tile is 0.31 of full; sampled raw into
# Godot's linear pipeline the same tile lands at 0.31 LINEAR -- twice as bright --
# and four layers of it clip the red channel flat, which is exactly the "featureless
# orange" the effect must not be. Decoded, the cloud structure survives.
#
# The layers ARE depth-tested (only ZWrite is off): the original's renders
# show near geometry as dark silhouette against the blazing fogged sky --
# structure occludes the murk. We tried depth_test_disabled to "bathe" the
# base in orange and it washed the whole frame flat; wrong reading.
const NEB_SHADER := """
shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never,
	shadows_disabled, fog_disabled;
uniform sampler2D tex : source_color, filter_linear_mipmap, repeat_enable;
uniform vec2 uv_c = vec2(0.0);
uniform vec2 uv_a = vec2(1.0, 0.0);
uniform vec2 uv_b = vec2(0.0, 1.0);
uniform vec3 tint = vec3(1.0);
uniform float amount = 0.0;
void fragment() {
	vec2 n = (UV - 0.5) * 2.0;
	vec3 c = texture(tex, uv_c + uv_a * n.x + uv_b * n.y).rgb;
	ALBEDO = c * tint;
	ALPHA = amount;
}
"""

# The stand-in cyclorama: a flat additive wall of the fog colour, depth-tested
# so near geometry keeps its dark silhouette, fog_disabled because it IS the
# fogged cyclorama -- the original's backdrop past fog_end resolves to exactly
# the fog colour (dx7graph 0x1000eeb0 fogs mesh fragments to D3DRS_FOGCOLOR).
const NEB_SKY_SHADER := """
shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never,
	shadows_disabled, fog_disabled;
uniform vec3 tint = vec3(1.0);
uniform float amount = 0.0;
void fragment() {
	ALBEDO = tint;
	ALPHA = amount;
}
"""

func _neb_recycle(i: int) -> void:
	_neb_cells[i] = {
		"uv": Vector2(randf(), randf()),
		"scale": randf_range(NEB_SCALE_MIN, NEB_SCALE_MAX),
	}

func _neb_hide() -> void:
	for mi in _neb_quads:
		mi.visible = false
	if _neb_sky != null:
		_neb_sky.visible = false
	if _neb_fogged:
		var m := get_parent()
		if m != null and "env_ref" in m and m.env_ref != null:
			m.env_ref.fog_enabled = false
			m.env_ref.glow_enabled = true   # normal space keeps its bloom
		if m != null and "sky_anchor" in m and m.sky_anchor != null:
			m.sky_anchor.visible = true
		if m != null and _cam != null and _neb_far0 > 0.0:
			_cam.far = _neb_far0
		_neb_fogged = false

func _render_nebula() -> void:
	_neb_resolve()
	if _neb_quads.is_empty() and not _neb.is_empty():
		_neb_build()
	if _neb.is_empty() or _cam == null or _hidden:
		_gas_hide()
		_neb_hide()
		return

	var centre := Vector3(_neb["x"], _neb["y"], _neb["z"])
	var radius := float(_neb["radius"])
	# the camera's own sim position. The ship sits at the world origin (main's
	# _fold_motion keeps it there), so the camera's offset from the origin is its
	# offset from `_pos`. Taking the delta in SIM space is what survives a fold.
	var eye: Vector3 = Vector3(_px, _py, _pz) + _cam.global_position
	var opacity := nebula_opacity(eye.distance_to(centre), radius)
	# the gas ball cloud is the nebula's OUTSIDE view -- it must draw exactly
	# when the inside layers don't
	_gas_update(centre, radius, opacity)
	if opacity <= 0.0:
		_neb_hide()
		_neb_seeded = false
		return

	var depth := float(_neb.get("depth", NEB_DEPTH))
	var col_a: Array = _neb.get("nebula_colour", [])
	var tint := NEB_COLOUR
	if col_a.size() >= 3:
		tint = Color(col_a[0], col_a[1], col_a[2])
	var cell := depth * NEB_CELL_FRAC
	var basis := _cam.global_transform.basis

	if not _neb_seeded:
		_neb_cells.resize(NEB_CELLS)
		for i in NEB_CELLS:
			_neb_recycle(i)
		_neb_idx = 0
		_neb_phase = 0.0
		_neb_uv = Vector2(randf(), randf())
		_neb_angle = randf_range(0.0, TAU)
		_neb_prev = eye
		_neb_prev_basis = basis
		_neb_seeded = true

	# --- the scroll: icCloudAvatar 0x100c3150 + 0x100c3700 -------------------
	var d := eye - _neb_prev
	_neb_prev = eye
	var fwd := -basis.z
	# the camera's rotation since the last frame, expressed in the old frame: the
	# roll goes into the shared UV angle, the yaw and pitch straight into the UV
	# scroll -- in RADIANS, so a radian of turn slides the tiles by a full period
	var rel := _neb_prev_basis.transposed() * basis
	_neb_prev_basis = basis
	var nf := rel * Vector3(0.0, 0.0, -1.0)  # the new forward, in the old frame
	var nu := rel * Vector3(0.0, 1.0, 0.0)  # the new up, in the old frame
	_neb_angle += atan2(nu.x, nu.y)
	var ca := cos(_neb_angle)
	var sa := sin(_neb_angle)
	var ax := Vector2(ca, sa)
	var ay := Vector2(-sa, ca)
	_neb_uv += ax * atan2(nf.x, -nf.z) - ay * atan2(nf.y, -nf.z)
	# ... and the translation: sideways slides the tiles, forward slides `phase`
	_neb_uv += ax * (d.dot(basis.x) / cell) - ay * (d.dot(basis.y) / cell)
	_neb_uv = Vector2(fposmod(_neb_uv.x, 1.0), fposmod(_neb_uv.y, 1.0))

	_neb_phase -= d.dot(fwd)
	if _neb_phase < 0.0:
		# flown forward out of the front cell: step the ring back, and the cell
		# that just wrapped round to the far end gets a fresh random tile
		_neb_idx = _neb_idx - 1 if _neb_idx > 0 else NEB_CELLS - 1
		_neb_recycle(_neb_idx)
		_neb_phase = fposmod(_neb_phase, cell)
	elif _neb_phase > cell:
		_neb_recycle(_neb_idx)
		_neb_phase = fposmod(_neb_phase, cell)
		_neb_idx = (_neb_idx + 1) % NEB_CELLS

	# --- the four layers ----------------------------------------------------
	var far := cell * NEB_FAR_CELLS
	var fade := far * NEB_FADE_FRAC
	var vp := _cam.get_viewport().get_visible_rect().size
	var aspect: float = maxf(1.0, vp.x / maxf(vp.y, 1.0))
	# the original's billboards are exactly screen-filling at their depth:
	# FcBillBoard::Add is handed w = z * gfx+0x108, the projection half-angle
	var half_at_1 := tan(deg_to_rad(_cam.fov) * 0.5) * aspect * 1.05
	var eye_w := _cam.global_position
	for j in NEB_CELLS:
		var mi: MeshInstance3D = _neb_quads[j]
		var z: float = _neb_phase + float(NEB_CELLS - 1 - j) * cell
		var a := opacity * NEB_ALPHA
		if z > far:
			a = 0.0
		if z > fade:
			a *= 1.0 - (z - fade) / fade
		if z < cell:
			a *= clampf(z / cell, 0.0, 1.0)
		a = clampf(a, 0.0, 1.0)
		if a <= 0.002:
			mi.visible = false
			continue
		var c: Dictionary = _neb_cells[(_neb_idx + j) % NEB_CELLS]
		var half: float = z * half_at_1
		# the UV half-extent is world_half * cell_scale / cell_size, so a tile has
		# a fixed size in METERS: it magnifies as its layer sweeps past you
		var s: float = half * float(c["scale"]) / cell
		var mat: ShaderMaterial = mi.material_override
		mat.set_shader_parameter("uv_c", _neb_uv + (c["uv"] as Vector2))
		mat.set_shader_parameter("uv_a", ax * s)
		mat.set_shader_parameter("uv_b", ay * s)
		var lin := tint.srgb_to_linear()
		mat.set_shader_parameter("tint", Vector3(lin.r, lin.g, lin.b))
		mat.set_shader_parameter("amount", a)
		mi.global_transform = Transform3D(
			basis.scaled(Vector3(half, half, 1.0)), eye_w + fwd * z)
		mi.visible = true

	# --- the fog and the wall at `depth`: icSolarSystem::Render 0x1004d150 ----
	var m := get_parent()
	if m == null:
		return
	# m_far_clip -- the far plane OUTSIDE the nebula. It has to be latched, because
	# it is an input to the fog lerp below AND we are about to overwrite it: feeding
	# the pulled-in value back into the lerp would wind the fog shut over a few
	# frames.
	if _neb_far0 <= 0.0 and _cam.far > 0.0:
		_neb_far0 = _cam.far
	var fog_end := opacity * depth + (1.0 - opacity) * _neb_far0

	# Render hauls the far plane in to fog_end * 1.1 (_DAT_10119e94) -- 33 km at
	# full opacity. That is not cosmetic: it is what CULLS the suns and planets.
	# We were leaving it at 600 km and trusting the fog to hide them, and it does
	# not -- main.gd draws bodies as impostors capped to 250 km and star_fx's
	# corona is emissive, so the sun burned a hole straight through the murk.
	_cam.far = fog_end * NEB_FAR_CLIP

	# ... and the cyclorama. Render 0x1004d150 only stops adding the geog
	# cyclorama (this+0x5c8) and the planet backdrop (DAT_10171e04) when the
	# opacity reaches 1.0 -- at EVERY opacity below that the backdrop is still in
	# the scene graph, hardware-fogged. The mesh fog path (dx7graph 0x1000eeb0)
	# fogs fragments to D3DRS_FOGCOLOR -- it even divides the fog colour by the
	# pass count for multipass materials precisely because each ADDITIVE pass
	# lands a full fog colour's worth -- so the additive cyclorama, wholly past
	# fog_end, adds exactly 1x fog colour over the faded stars, and the slot-16
	# wall (alpha = opacity) then veils the pair of them:
	#     sky = op * fog + (1 - op) * (stars' + fog) = fog + (1 - op) * stars'
	# The in-murk sky floor is a FULL 1x fog colour at every opacity; the blazing
	# highlights are the cloud layers stacking on top of that. Without the
	# cyclorama term ours floored at op * fog -- the dim olive transition band.
	#
	# Ours is a real mesh parked at a fixed 4.8e5 m, so once the far plane comes
	# inside that it would get sliced and leave a hard wedge across the sky; past
	# that point we swap it for a stand-in: a screen-filling additive wall of the
	# fog colour (the fogged backdrop resolves to exactly that -- 0x1000eeb0) at
	# alpha = 1 - opacity, the slot-16 veil folded in. It fades to nothing at
	# opacity 1, which is Render dropping the cyclorama outright, and the swap at
	# the dome boundary is seamless because the dome is already fully fogged
	# there (dome > fog_end whenever far <= NEB_SKY_DOME).
	if "sky_anchor" in m and m.sky_anchor != null:
		m.sky_anchor.visible = _cam.far > NEB_SKY_DOME
	if _neb_sky != null:
		var wall_a := 1.0 - opacity if _cam.far <= NEB_SKY_DOME else 0.0
		if wall_a <= 0.002:
			_neb_sky.visible = false
		else:
			var wz := _cam.far * NEB_SKY_Z
			var wh := wz * half_at_1
			var wlin := tint.srgb_to_linear()
			var wmat: ShaderMaterial = _neb_sky.material_override
			wmat.set_shader_parameter("tint", Vector3(wlin.r, wlin.g, wlin.b))
			wmat.set_shader_parameter("amount", wall_a)
			_neb_sky.global_transform = Transform3D(
				basis.scaled(Vector3(wh, wh, 1.0)), eye_w + fwd * wz)
			_neb_sky.visible = true

	if "env_ref" in m and m.env_ref != null:
		var env: Environment = m.env_ref
		env.fog_enabled = true
		env.fog_mode = Environment.FOG_MODE_DEPTH
		# Environment colours are sRGB and the renderer linearises them itself:
		# hand the engine's (172, 71, 21) over as it is. (Linearising it here as
		# well double-decodes it and the wall comes out a blood red, (146,28,4).)
		env.fog_light_color = tint
		env.fog_light_energy = 1.0
		env.fog_density = 1.0
		env.fog_depth_begin = NEB_FOG_START
		env.fog_depth_end = fog_end
		env.fog_depth_curve = 1.0
		env.fog_aerial_perspective = 0.0
		# The original has no bloom at all, and on a full-screen wall that already
		# sits near the top of the range ours only ever pushes it over. Inside the
		# nebula, drop it: the cloud layers ARE the light.
		env.glow_enabled = opacity <= 0.0
		# the slot-16 wall is ALPHA-blended with alpha = opacity, so the sky is
		# veiled by exactly the opacity -- out on the rim the stars still show
		# through, and at 1 it is gone, which is also when Render drops it outright
		env.fog_sky_affect = opacity
		# NO ambient term in here: we tried tint x opacity and it washed the
		# base's tunnel flat, where the original renders it dark. The murk's
		# orange lands on surfaces only through the additive cloud layers,
		# and those are depth-tested -- enclosed spaces stay unlit.
		_neb_fogged = true


# --- icGasBallAvatar: the nebula seen from OUTSIDE ---------------------------
# @element icGasBallAvatar
# icNebula's own avatar (created by 0x10067940 into nebula+0x1f8; factory
# 0x100bda60, data ctor FUN_100bdb50 @ 0x100bdb50, vtable 0x1011cc20). The
# ctor rolls a 32-entry ball table, 7 floats each (+0xcc stride 0x1c):
#   ball 0 (fixed):   pos (0,0,0), s1 1.1, s2 0.6, rolls 0 / 2pi
#   balls 1-31:       pos = lerp(0.4, 1.0, u) * random unit vector
#                     (consts @ 0x10117558/0x101171f0, u = rand()/32767
#                     @ 0x10118494), s1 = lerp(0.1, 0.4, u') (@ 0x101184b0),
#                     s2 = lerp(0.3, 0.7, u'') (@ 0x1011c034/0x101191e8),
#                     two rolls = u * 2pi (@ 0x10119f94)
# node scale = nebula radius (+0x1c), cull radius x1.7 (@ 0x1011c3ec);
# colour copied from the nebula's +0x1e4..0x1ec, texture the nebula's
# texture_url (images/sfx/cloud). Draw (vtable slot 16 @ 0x100bddb0 -- a
# Ghidra hole, raw-disassembled): view-depth-sorts the table (qsort, cmp @
# 0x100be050), then TWO FcBillBoard passes over all 32 balls: pass 1 in
# table order, engine blend +0x175c = 2 (SRCALPHA/ONE additive), size
# scale*s1, roll 1; pass 2 in sorted back-to-front order, blend 3
# (SRCALPHA/INVSRCALPHA), size scale*s2, roll 2. OPEN QUESTION
# (docs/original.md): cloud.png ships with no alpha channel, so what blend
# 3 uses for source alpha is unproven -- we read the texture luminance as
# the alpha (black = clear), which is the only reading that doesn't leave
# opaque black card corners over the starfield.
# The whole shipped game has ONE nebula (The Effrit, r 2.5e8 m), far beyond
# the 600 km far plane -- like the bodies, it draws at IMPOSTOR_DIST with
# the angular size preserved (main_world.gd's impostor law).
const GAS_BALLS := 32  # 1 fixed + 0x1f randoms (ctor loop @ 0x100bdb50)
var _gas: Array = []             # {off: Vector3, s1, s2, r1, r2}
var _gas_mis: Array[MeshInstance3D] = []
var _gas_anchor: Node3D = null

const GAS_SHADER_COMMON := """
uniform sampler2D tex : source_color, filter_linear_mipmap, repeat_enable;
uniform vec3 tint = vec3(1.0);
uniform float size = 1.0;
uniform float roll = 0.0;
void vertex() {
	float c = cos(roll);
	float s = sin(roll);
	vec2 v = vec2(VERTEX.x * c - VERTEX.y * s, VERTEX.x * s + VERTEX.y * c);
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(
		INV_VIEW_MATRIX[0], INV_VIEW_MATRIX[1], INV_VIEW_MATRIX[2],
		MODEL_MATRIX[3]);
	VERTEX = vec3(v * size, 0.0);
}
"""

const GAS_ADD_SHADER := """
shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never,
	shadows_disabled, fog_disabled;
""" + GAS_SHADER_COMMON + """
void fragment() {
	ALBEDO = texture(tex, UV).rgb * tint;
}
"""

const GAS_MIX_SHADER := """
shader_type spatial;
render_mode unshaded, blend_mix, cull_disabled, depth_draw_never,
	shadows_disabled, fog_disabled;
""" + GAS_SHADER_COMMON + """
void fragment() {
	vec3 c = texture(tex, UV).rgb;
	ALBEDO = c * tint;
	ALPHA = max(c.r, max(c.g, c.b));
}
"""

func _gas_build() -> void:
	var base := ProjectSettings.globalize_path("res://").path_join("..")
	var tex: Texture2D = ParticleFx.texture(
			base, str(_neb.get("texture_url", NEB_TEXTURE)))
	_gas_anchor = Node3D.new()
	add_child(_gas_anchor)
	var quad := QuadMesh.new()
	quad.size = Vector2(2.0, 2.0)  # verts at +/-1; `size` does the scaling
	_gas.append({"off": Vector3.ZERO, "s1": 1.1, "s2": 0.6,
			"r1": 0.0, "r2": TAU})
	for i in GAS_BALLS - 1:
		_gas.append({
			"off": Vector3(randf_range(-1, 1), randf_range(-1, 1),
					randf_range(-1, 1)).normalized() * randf_range(0.4, 1.0),
			"s1": randf_range(0.1, 0.4), "s2": randf_range(0.3, 0.7),
			"r1": randf_range(0.0, TAU), "r2": randf_range(0.0, TAU)})
	for b: Dictionary in _gas:
		for code in [GAS_ADD_SHADER, GAS_MIX_SHADER]:
			var sh := Shader.new()
			sh.code = code
			var mat := ShaderMaterial.new()
			mat.shader = sh
			mat.set_shader_parameter("tex", tex)
			mat.set_shader_parameter(
					"roll", b["r1"] if code == GAS_ADD_SHADER else b["r2"])
			# the additive pass lays down first, the sorted alpha pass on top
			mat.render_priority = -1 if code == GAS_ADD_SHADER else 0
			var mi := MeshInstance3D.new()
			mi.mesh = quad
			mi.material_override = mat
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			mi.extra_cull_margin = 5.0e5
			mi.visible = false
			_gas_anchor.add_child(mi)
			_gas_mis.append(mi)

func _gas_hide() -> void:
	for mi in _gas_mis:
		mi.visible = false

func _gas_update(centre: Vector3, radius: float, opacity: float) -> void:
	if _gas_mis.is_empty():
		_gas_build()
	# at opacity 1 the original's far plane sits at depth * 1.1 (~33 km) --
	# the balls are far beyond it; the fog wall owns the view
	if opacity >= 1.0:
		_gas_hide()
		return
	var m := get_parent()
	var rel := centre - Vector3(_px, _py, _pz)
	var dist := maxf(rel.length(), 1.0)
	var k := minf(float(m.IMPOSTOR_DIST) / dist, 1.0)
	_gas_anchor.position = rel.normalized() * (dist * k)
	var col_a: Array = _neb.get("nebula_colour", [])
	var tint := NEB_COLOUR
	if col_a.size() >= 3:
		tint = Color(col_a[0], col_a[1], col_a[2])
	var lin := tint.srgb_to_linear()
	var tv := Vector3(lin.r, lin.g, lin.b)
	for i in _gas.size():
		var b: Dictionary = _gas[i]
		var pos: Vector3 = (b["off"] as Vector3) * radius * k
		for pi in 2:
			var mi: MeshInstance3D = _gas_mis[i * 2 + pi]
			mi.position = pos
			var mat: ShaderMaterial = mi.material_override
			mat.set_shader_parameter("tint", tv)
			mat.set_shader_parameter("size",
					radius * float(b["s1"] if pi == 0 else b["s2"]) * k)
			mi.visible = true

# --- --nebshot: park inside The Effrit and photograph it ---------------------
# The nebula is the one effect you cannot see from any default spawn, so it gets
# its own capture mode. Writes data/screenshots/nebula_*.png and quits.
var _ns_t := 0.0
var _ns_shot := 0

func _nebshot(delta: float) -> void:
	if not ("--nebshot" in OS.get_cmdline_user_args()):
		return
	var m := get_parent()
	if m == null or _cam == null or _neb.is_empty():
		return
	_ns_t += delta
	if _ns_shot == 0 and _ns_t > 0.5:
		# beside Lucrecia's Base, which sits 750 m from the middle of The Effrit
		for o in m.objects:
			if str(o["name"]) == "Lucrecia's Base":
				m.px = float(o["x"]) + 5000.0
				m.py = float(o["y"]) + 700.0
				m.pz = float(o["z"]) + 2600.0
		m.ship.velocity = Vector3.ZERO
		m.ship.set_speed = 0.0
		m.menu.visible = false
		m.cam_mode = 2
		m._apply_view()
		m._stream_objects()
		_ns_shot = 1
		_ns_t = 0.0
	elif _ns_shot == 1 and _ns_t > 1.5:
		_ns_save("nebula_inside")
		_ns_shot = 2
		_ns_t = 0.0
	elif _ns_shot == 2 and _ns_t > 0.2:
		# ... and again out on the rim, where the ramp is only half wound up
		var r: float = float(_neb["radius"])
		m.px = float(_neb["x"])
		m.py = float(_neb["y"])
		m.pz = float(_neb["z"]) + r * (NEB_INNER + 0.25 * 0.5)
		m._stream_objects()
		_ns_shot = 3
		_ns_t = 0.0
	elif _ns_shot == 3 and _ns_t > 1.0:
		_ns_save("nebula_rim")
		print("NEBSHOT done")
		get_tree().quit()

func _ns_save(pname: String) -> void:
	var img := get_viewport().get_texture().get_image()
	var base := ProjectSettings.globalize_path("res://").path_join("..")
	img.save_png(base.path_join("data/screenshots/%s.png" % pname))
	print("NEBSHOT shot: ", pname)
