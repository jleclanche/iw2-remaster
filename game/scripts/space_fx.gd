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
	_update_aggressor(delta)


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
# UNKNOWN: the world scale. The cone is built at unit size and the LWS node's
# own transform scales it; we have not parsed avatars/aggressor_shield/setup, so
# the shell is sized to the player's collision radius instead. Everything else
# above is recovered.
const AGG_RIM := 0.1        # icAggressorAvatar +0xbc
const AGG_SCROLL := 1.0     # 0x1011c824, v units per second
const AGG_APEX := 4.0       # the fan's apex, as icLDAAvatar (0x1011cfbc)
const AGG_SHELL_R := 95.0   # our stand-in scale: the player collision radius

var _agg_mi: MeshInstance3D
var _agg_mat: StandardMaterial3D
var _agg_clock := 0.0

func _ensure_aggressor(base: String) -> void:
	if _agg_mi != null:
		return
	var tex := ParticleFx.texture(base, "images/sfx/aggressor")
	_agg_mat = ExplosionFx._blend2_material(tex)
	_agg_mat.vertex_color_use_as_albedo = true
	_agg_mi = MeshInstance3D.new()
	_agg_mi.mesh = ExplosionFx.lda_cone_mesh()
	_agg_mi.mesh.surface_set_material(0, _agg_mat)
	_agg_mi.visible = false
	add_child(_agg_mi)

## Called each frame by main: `up` is ShipSystems.aggressor_active().
func set_aggressor(base: String, up: bool, xform: Transform3D) -> void:
	_ensure_aggressor(base)
	_agg_mi.visible = up
	if not up:
		_agg_clock = 0.0
		return
	# the cone points dead ahead, down the ship's local +Z -- the axis the
	# shield's coverage cone is measured about (0x1002f810)
	_agg_mi.global_transform = xform
	var rim: float = maxf(AGG_RIM, 1e-3) * AGG_SHELL_R / AGG_RIM
	_agg_mi.scale = Vector3(rim, rim, AGG_APEX * AGG_SHELL_R * 0.25)

func _update_aggressor(delta: float) -> void:
	if _agg_mi == null or not _agg_mi.visible:
		return
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
#   most; the player's own ship always gets the first slot.
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
#   THE PLAYER'S IS A LADDER (FUN_100e5520): two rails offset +/- halfspan along
#   the sim's local X axis AT THE MOMENT EACH POINT WAS EMITTED, plus a rung
#   across every point. halfspan = icShip::width (+0x208, the ship INI's `width`)
#   * 0.5, scaled in over a 0.35 s splay ramp (_DAT_1011da90) each time the
#   element is shown -- so the trail opens out from the centreline. The rails are
#   SKIPPED on points whose LDS flag is set (the flag is head & 1 while the drive
#   is engaged), which makes them come out dashed under LDS; the rungs always
#   draw. Everyone ELSE gets a single centre line (FUN_100e59d0).
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
var _ct_emit := 0.0
var _ct_ramp := 0.0

func _ensure_contrails() -> void:
	if _ct_mi != null:
		return
	_ct_mesh = ArrayMesh.new()
	_ct_mi = MeshInstance3D.new()
	_ct_mi.mesh = _ct_mesh
	_ct_mi.material_override = _line_material()
	_ct_mi.custom_aabb = AABB(Vector3.ONE * -1.0e9, Vector3.ONE * 2.0e9)
	add_child(_ct_mi)

## `ships` is [{node, width, lds}], nearest first; `hidden` blanks the element.
func update_contrails(delta: float, ships: Array, hidden: bool) -> void:
	_ensure_contrails()
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
				"player": bool(s.get("player", false)),
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
			if not bool(p["player"]):
				# everyone else: one centre line (FUN_100e59d0)
				v.append(p["pos"]); col.append(cp)
				v.append(q["pos"]); col.append(cq)
				continue
			# the player: a ladder (FUN_100e5520)
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
