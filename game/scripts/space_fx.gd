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
var _pos := Vector3.ZERO
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
	_pos += _vel * delta
	_render_grid()

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
func update_grid(cam: Camera3D, pos: Vector3, vel: Vector3, lds: bool,
		hidden: bool) -> void:
	_cam = cam
	_pos = pos
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
	var start := Vector3(
		-GRID_SPAN * cell - fmod(_pos.x, cell),
		-GRID_SPAN * cell - fmod(_pos.y, cell),
		-GRID_SPAN * cell - fmod(_pos.z, cell))
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
