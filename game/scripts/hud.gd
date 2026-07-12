class_name Hud
extends Control
# The original IW2 in-flight HUD, vector-drawn: green-on-dark palette with
# orange target data (see the reference layout). Panels: target identity
# with rotating wireframe hologram (top-left), weapon charge (below it),
# throttle/speed bar (top-center), contact count + spherical radar
# (top-right), hull status + mission timer (right), reticle with own-speed
# (green, left) and target range/closing speed (orange, right), target
# lead indicator, message log (bottom-right), console readouts (bottom-left).

var main: Node3D
var warning_text := ""
var warning_until := 0.0
var log_lines: Array = []  # {text, color, until}

const GREEN := Color(0.35, 1.0, 0.4, 0.95)
const GREEN_DIM := Color(0.35, 1.0, 0.4, 0.4)
const GREEN_PANEL := Color(0.1, 0.5, 0.15, 0.8)
const ORANGE := Color(1.0, 0.6, 0.15, 0.95)
const RED := Color(1.0, 0.3, 0.25, 0.95)
const CYAN := Color(0.5, 0.9, 1.0, 0.9)
const FONT_SIZE := 13

var _font: Font

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_font = ThemeDB.fallback_font

func _screen() -> Vector2:
	return get_viewport_rect().size

func warn(text: String, seconds := 2.5) -> void:
	warning_text = text
	warning_until = Time.get_ticks_msec() / 1000.0 + seconds
	log_msg(text, RED)

func log_msg(text: String, color := GREEN) -> void:
	log_lines.append({"text": text, "color": color,
			"until": Time.get_ticks_msec() / 1000.0 + 14.0})
	if log_lines.size() > 6:
		log_lines.pop_front()

func _process(_d: float) -> void:
	queue_redraw()

func _draw() -> void:
	if main == null or main.ship == null:
		return
	if main.menu != null and main.menu.visible and not main.menu.launched:
		return
	var c := _screen() / 2.0
	_draw_reticle(c)
	_draw_target_marks()
	_draw_target_panel()
	_draw_weapons_panel()
	_draw_throttle_bar()
	_draw_radar()
	_draw_status_panel()
	_draw_log()
	_draw_readouts()
	_draw_warnings(c)

# --- panel chrome ----------------------------------------------------------

func _panel(pos: Vector2, size: Vector2, title: String) -> void:
	draw_rect(Rect2(pos, Vector2(size.x, 16)), GREEN_PANEL)
	draw_string(_font, pos + Vector2(5, 12), title,
			HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE - 1, Color(0, 0, 0, 0.9))
	draw_rect(Rect2(pos + Vector2(0, 16), size - Vector2(0, 16)),
			Color(0.0, 0.08, 0.0, 0.45))
	draw_rect(Rect2(pos, size), GREEN_DIM, false, 1.0)

func _bar(pos: Vector2, width: float, frac: float, col: Color,
		segments := 16) -> void:
	var seg_w := width / segments
	for i in segments:
		var r := Rect2(pos + Vector2(i * seg_w, 0), Vector2(seg_w - 2, 8))
		if float(i) / segments < frac:
			draw_rect(r, col)
		else:
			draw_rect(r, Color(col.r, col.g, col.b, 0.15))

# --- center ----------------------------------------------------------------

func _draw_reticle(c: Vector2) -> void:
	draw_arc(c, 56.0, 0, TAU, 64, GREEN_DIM, 1.2, true)
	for i in 12:
		var a := TAU * i / 12.0
		var dir := Vector2(cos(a), sin(a))
		var inner := 50.0 if i % 3 == 0 else 53.0
		draw_line(c + dir * inner, c + dir * 56.0, GREEN, 1.2, true)
	draw_line(c + Vector2(-5, 0), c + Vector2(5, 0), GREEN, 1.0, true)
	draw_line(c + Vector2(0, -5), c + Vector2(0, 5), GREEN, 1.0, true)
	# own speed left of the reticle, like the original
	var vel: float = main.ship.forward_speed()
	draw_string(_font, c + Vector2(-150, 4), "%+.0f m/s" % vel,
			HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE, GREEN)
	# target data right of the reticle, orange
	var tdist: float = main._target_distance()
	if tdist < INF:
		var closing: float = 0.0
		var tvel := Vector3.ZERO
		if main.target_ai != null and is_instance_valid(main.target_ai):
			tvel = main.target_ai.velocity
		closing = (main.ship.velocity - tvel).dot(main._target_pos().normalized())
		draw_string(_font, c + Vector2(78, -4), main._fmt_dist(tdist),
				HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE, ORANGE)
		draw_string(_font, c + Vector2(78, 12), "%+.0f m/s" % closing,
				HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE, ORANGE)
	# velocity vector marker
	var v: Vector3 = main.ship.velocity
	if v.length() > 5.0:
		var cam: Camera3D = main.cam
		var ahead: Vector3 = main.ship.global_position + v.normalized() * 5000.0
		if not cam.is_position_behind(ahead):
			var p := cam.unproject_position(ahead)
			draw_arc(p, 6.0, 0, TAU, 16, GREEN, 1.4, true)
			draw_line(p + Vector2(-12, 0), p + Vector2(-6, 0), GREEN, 1.4)
			draw_line(p + Vector2(6, 0), p + Vector2(12, 0), GREEN, 1.4)

func _tri(p: Vector2, a: float, col: Color, size := 7.0) -> void:
	var d := Vector2(cos(a), sin(a))
	var perp := Vector2(-d.y, d.x)
	draw_colored_polygon(PackedVector2Array([
		p + d * size, p - d * size * 0.6 + perp * size * 0.7,
		p - d * size * 0.6 - perp * size * 0.7]), col)

func _draw_target_marks() -> void:
	var world: Vector3
	var hostile := false
	if main.target_ai != null and is_instance_valid(main.target_ai):
		world = main.target_ai.global_position
		hostile = main.target_ai.behavior == "attack"
	elif main.target_idx >= 0:
		var t: Dictionary = main.objects[main.target_idx]
		world = Vector3(t["x"] - main.px, t["y"] - main.py, t["z"] - main.pz)
	else:
		return
	var cam: Camera3D = main.cam
	var col: Color = RED if hostile else ORANGE
	if cam.is_position_behind(world):
		_offscreen_arrow(world, col)
		return
	var p := cam.unproject_position(world)
	if not Rect2(Vector2.ZERO, _screen()).has_point(p):
		_offscreen_arrow(world, col)
		return
	# original style: four triangles around the target
	for i in 4:
		var a := TAU * i / 4.0 + TAU / 8.0
		_tri(p + Vector2(cos(a), sin(a)) * 26.0, a + PI, col)
	# lead indicator diamond for moving targets
	if main.target_ai != null and is_instance_valid(main.target_ai):
		var tvel: Vector3 = main.target_ai.velocity - main.ship.velocity
		var tof: float = world.length() / 6000.0
		var lead: Vector3 = world + tvel * tof
		if not cam.is_position_behind(lead):
			var lp := cam.unproject_position(lead)
			var pts := PackedVector2Array([lp + Vector2(0, -8), lp + Vector2(8, 0),
					lp + Vector2(0, 8), lp + Vector2(-8, 0), lp + Vector2(0, -8)])
			draw_polyline(pts, col, 1.4, true)

func _offscreen_arrow(world: Vector3, col: Color) -> void:
	var cam: Camera3D = main.cam
	var local: Vector3 = cam.global_transform.affine_inverse() * world
	var dir2 := Vector2(local.x, -local.y).normalized()
	var c := _screen() / 2.0
	var edge := c + dir2 * (minf(_screen().x, _screen().y) / 2.0 - 40.0)
	_tri(edge, dir2.angle(), col, 9.0)

# --- top-left: target identity + hologram ----------------------------------

func _target_name() -> Array:
	if main.target_ai != null and is_instance_valid(main.target_ai):
		var host: bool = main.target_ai.behavior == "attack"
		return [str(main.target_ai.name), "HOSTILE" if host else "TRAFFIC", host]
	if main.target_idx >= 0:
		var t: Dictionary = main.objects[main.target_idx]
		return [str(t["name"]), str(t["category"]).to_upper(), false]
	return []

func _draw_target_panel() -> void:
	var pos := Vector2(16, 16)
	var size := Vector2(220, 150)
	_panel(pos, size, "TARGET")
	var info := _target_name()
	if info.is_empty():
		draw_string(_font, pos + Vector2(10, 40), "NO TARGET",
				HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE, GREEN_DIM)
		return
	var col: Color = RED if info[2] else ORANGE
	draw_string(_font, pos + Vector2(8, 32), str(info[0]).left(28),
			HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE, col)
	draw_string(_font, pos + Vector2(8, 47), str(info[1]),
			HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE - 2, GREEN_DIM)
	# rotating wireframe hologram, like the original's target schematic
	var center := pos + Vector2(size.x / 2.0, 100)
	var t := Time.get_ticks_msec() / 1000.0
	var basis := Basis(Vector3.UP, t * 0.6) * Basis(Vector3.RIGHT, 0.35)
	var ext := Vector3(34, 12, 44)
	if main.target_ai == null and main.target_idx >= 0:
		ext = Vector3(30, 26, 30)
	var corners: Array = []
	for sx in [-1, 1]:
		for sy in [-1, 1]:
			for sz in [-1, 1]:
				var p3: Vector3 = basis * Vector3(sx * ext.x, sy * ext.y, sz * ext.z)
				corners.append(center + Vector2(p3.x, -p3.y * 0.9 + p3.z * 0.25))
	for e in [[0, 1], [0, 2], [1, 3], [2, 3], [4, 5], [4, 6], [5, 7], [6, 7],
			[0, 4], [1, 5], [2, 6], [3, 7]]:
		draw_line(corners[e[0]], corners[e[1]], col * Color(1, 1, 1, 0.8), 1.0, true)

# --- weapons ---------------------------------------------------------------

func _draw_weapons_panel() -> void:
	var pos := Vector2(16, 176)
	_panel(pos, Vector2(220, 62), "PBC BATTERY")
	var charge: float = 1.0
	if main.weapons != null:
		charge = 1.0 - main.weapons.cooldown / main.weapons.REFIRE
	for i in 2:
		var y := 28.0 + i * 16.0
		draw_string(_font, pos + Vector2(8, y + 8), "L" if i == 0 else "R",
				HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE - 2, GREEN)
		_bar(pos + Vector2(24, y), 150, charge, GREEN, 12)
		draw_string(_font, pos + Vector2(182, y + 8), "%d%%" % int(charge * 100),
				HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE - 2, GREEN)

# --- top-center: throttle / speed bar --------------------------------------

func _draw_throttle_bar() -> void:
	var s := _screen()
	var w := 260.0
	var pos := Vector2(s.x / 2.0 - w / 2.0, 14)
	var frac: float = absf(main.ship.forward_speed()) / maxf(main.ship.max_speed.z, 1.0)
	_bar(pos, w, clampf(frac, 0.0, 1.0), CYAN, 26)
	# throttle setting notch
	var tx: float = pos.x + w * main.ship.throttle
	draw_line(Vector2(tx, pos.y - 3), Vector2(tx, pos.y + 11), GREEN, 2.0)
	draw_rect(Rect2(pos - Vector2(3, 3), Vector2(w + 6, 14)), GREEN_DIM, false, 1.0)

# --- top-right: contacts radar ---------------------------------------------

func _radar_contacts() -> Array:
	var out: Array = []
	for o in main.objects:
		var rel := Vector3(o["x"] - main.px, o["y"] - main.py, o["z"] - main.pz)
		var d := rel.length()
		match o["category"]:
			"station":
				if d < 5.0e5:
					out.append([rel, GREEN])
			"lpoint":
				if d < 1.0e7:
					out.append([rel, CYAN])
	for a in main.ai_ships:
		out.append([a.global_position,
				RED if a.behavior == "attack" else GREEN])
	return out

func _draw_radar() -> void:
	var s := _screen()
	var pos := Vector2(s.x - 156, 16)
	var size := Vector2(140, 150)
	_panel(pos, size, "")
	var contacts := _radar_contacts()
	draw_rect(Rect2(pos, Vector2(size.x, 16)), GREEN_PANEL)
	draw_string(_font, pos + Vector2(5, 12), "%d CONTACTS" % contacts.size(),
			HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE - 1, Color(0, 0, 0, 0.9))
	var c := pos + Vector2(size.x / 2.0, 88)
	var r := 52.0
	draw_arc(c, r, 0, TAU, 48, GREEN_DIM, 1.0, true)
	draw_arc(c, r * 0.5, 0, TAU, 32, GREEN_DIM * Color(1, 1, 1, 0.6), 1.0, true)
	draw_line(c - Vector2(r, 0), c + Vector2(r, 0), GREEN_DIM * Color(1, 1, 1, 0.5), 1.0)
	draw_line(c - Vector2(0, r), c + Vector2(0, r), GREEN_DIM * Color(1, 1, 1, 0.5), 1.0)
	# azimuthal projection: center = ahead, edge = astern
	var inv: Transform3D = main.cam.global_transform.affine_inverse()
	for entry in contacts:
		var local: Vector3 = (inv * (Vector3(entry[0]) +
				main.ship.global_position)).normalized()
		var theta := acos(clampf(-local.z, -1.0, 1.0))
		var rad := r * theta / PI
		var dir := Vector2(local.x, -local.y)
		if dir.length() > 0.001:
			dir = dir.normalized()
		draw_circle(c + dir * rad, 2.5, entry[1])

# --- right: status ---------------------------------------------------------

func _draw_status_panel() -> void:
	var s := _screen()
	var pos := Vector2(s.x - 156, 176)
	_panel(pos, Vector2(140, 96), "STATUS")
	draw_string(_font, pos + Vector2(8, 32), "HULL",
			HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE - 2, GREEN)
	var frac: float = main.hull / main.hull_max
	_bar(pos + Vector2(45, 24), 85, frac, GREEN if frac > 0.35 else RED, 10)
	var mode := "CRUISE"
	match main.lds_state:
		1: mode = "LDS SPOOL"
		2: mode = "LDS"
	match main.jump_state:
		1: mode = "CAPSULE CHG"
		2: mode = "ACCEL RUN"
		3: mode = "CAPSULE"
	if main.docked_at != "":
		mode = "DOCKED"
	draw_string(_font, pos + Vector2(8, 52), mode,
			HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE, ORANGE)
	draw_string(_font, pos + Vector2(8, 70),
			"ASSIST" if main.ship.assist else "FREE",
			HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE - 2, GREEN)
	var ms := Time.get_ticks_msec()
	draw_string(_font, pos + Vector2(8, 88), "%02d:%02d:%02d.%02d" % [
			ms / 3600000, (ms / 60000) % 60, (ms / 1000) % 60, (ms / 10) % 100],
			HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE - 2, GREEN_DIM)

# --- bottom-right: message log ---------------------------------------------

func _draw_log() -> void:
	var s := _screen()
	var now := Time.get_ticks_msec() / 1000.0
	while not log_lines.is_empty() and log_lines[0]["until"] < now:
		log_lines.pop_front()
	var y := s.y - 24.0
	for i in range(log_lines.size() - 1, -1, -1):
		var entry: Dictionary = log_lines[i]
		draw_string(_font, Vector2(s.x - 420, y), str(entry["text"]).left(48),
				HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE, entry["color"])
		y -= 18.0

# --- bottom-left: console ---------------------------------------------------

func _draw_readouts() -> void:
	var ship: ShipFlight = main.ship
	var x := 20.0
	var y := _screen().y - 132.0
	var lines := [
		"SYS %s" % str(main.system_name).to_upper(),
		"VEL %10s/s" % main._fmt_dist(ship.velocity.length()),
		"SET %8.0f m/s   THR %d%%" % [ship.throttle * ship.max_speed.z,
			int(ship.throttle * 100)],
	]
	if main.lds_state == 2:
		lines.append("LDS %s/s" % main._fmt_dist(main.lds_speed))
	var routes: String = main.routes_text()
	if routes != "" and main.jump_state == 0:
		lines.append(routes)
	if main.docked_at != "":
		lines = ["DOCKED: %s" % main.docked_at, "press U to undock"]
	for ln in lines:
		draw_string(_font, Vector2(x, y), ln, HORIZONTAL_ALIGNMENT_LEFT, -1,
				FONT_SIZE + 1, GREEN)
		y += 20

func _draw_warnings(c: Vector2) -> void:
	if Time.get_ticks_msec() / 1000.0 < warning_until:
		var w := _font.get_string_size(warning_text, HORIZONTAL_ALIGNMENT_CENTER,
				-1, FONT_SIZE + 6).x
		draw_string(_font, Vector2(c.x - w / 2.0, c.y - 110), warning_text,
				HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE + 6, RED)
