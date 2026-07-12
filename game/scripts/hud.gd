class_name Hud
extends Control
# The original IW2 HUD, per the manual's spec and reference shots:
# - MFD (upper-left): current target name/type, hull, wireframe feed
# - weapon panel below the MFD (current weapon charge)
# - SYSTEM STATUS light pairs (top-center): damage over power, per system
# - ORB (top-right): 3D contact sphere, points on stalks (in <1km, out >1km)
# - clock under the ORB: time since leaving port
# - CONTACT LIST (lower-right): faction/type/range/name, color-coded
# - reticle: own speed left, target hull/range/speed right, in-reticle
#   turn arrow, own hull arc lower-right, status icons around it,
#   warnings below
# Colors per manual: yellow neutral, red hostile, blue friendly,
# green waypoints. HUD chrome is green.

var main: Node3D
var warning_text := ""
var warning_until := 0.0
var log_lines: Array = []  # {text, color, until}

const GREEN := Color(0.35, 1.0, 0.4, 0.95)
const GREEN_DIM := Color(0.35, 1.0, 0.4, 0.4)
const GREEN_PANEL := Color(0.1, 0.5, 0.15, 0.8)
const YELLOW := Color(1.0, 0.9, 0.25, 0.95)
const ORANGE := Color(1.0, 0.6, 0.15, 0.95)
const RED := Color(1.0, 0.3, 0.25, 0.95)
const BLUE := Color(0.35, 0.6, 1.0, 0.95)
const LDS_COL := Color(0.4, 1.0, 0.75, 0.95)

var FONT_SIZE := 13
var _font: Font       # Handel Gothic 8pt â€” panel text, like the original
var _font_num: Font   # OCR-B 10pt â€” reticle numerics
var _font_big: Font   # Handel Gothic 12pt â€” warnings
var num_size := 14
var big_size := 17

static func load_game_font(base: String, fnt: String) -> Font:
	var path := base.path_join("data/fonts").path_join(fnt)
	if FileAccess.file_exists(path):
		var f := FontFile.new()
		if f.load_bitmap_font(path) == OK:
			return f
	return ThemeDB.fallback_font

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var base: String = main._base()
	_font = load_game_font(base, "handelgothic bt_8pt.fnt")
	_font_num = load_game_font(base, "ocrb_10pt.fnt")
	_font_big = load_game_font(base, "handelgothic bt_12pt.fnt")
	if _font is FontFile and (_font as FontFile).fixed_size > 0:
		FONT_SIZE = (_font as FontFile).fixed_size
	if _font_num is FontFile and (_font_num as FontFile).fixed_size > 0:
		num_size = (_font_num as FontFile).fixed_size
	if _font_big is FontFile and (_font_big as FontFile).fixed_size > 0:
		big_size = (_font_big as FontFile).fixed_size

func _screen() -> Vector2:
	return get_viewport_rect().size

func warn(text: String, seconds := 2.5) -> void:
	warning_text = text
	warning_until = Time.get_ticks_msec() / 1000.0 + seconds

func log_msg(text: String, color := GREEN) -> void:
	log_lines.append({"text": text, "color": color,
			"until": Time.get_ticks_msec() / 1000.0 + 12.0})
	if log_lines.size() > 4:
		log_lines.pop_front()

func _process(_d: float) -> void:
	queue_redraw()

func _draw() -> void:
	if main == null or main.ship == null:
		return
	if main.menu != null and main.menu.visible and not main.menu.launched:
		return
	var c := _screen() / 2.0
	var based: bool = main.get("base_root") != null
	if not based:
		_draw_reticle(c)
		_draw_target_marks()
	_draw_mfd()
	_draw_weapon_panel()
	_draw_system_status()
	_draw_orb()
	_draw_contact_list()
	_draw_log(c)
	_draw_console()
	_draw_warnings(c)
	_draw_subtitles()
	_draw_objectives()

func _draw_subtitles() -> void:
	# in-flight dialogue subtitles at the top of the HUD (manual, comms)
	if main.comms == null or str(main.comms.subtitle) == "":
		if main.comms != null:
			main.comms.portrait.visible = false
		return
	main.comms.portrait.visible = true
	var s := _screen()
	var who := str(main.comms.speaker).to_upper()
	var text: String = "%s: %s" % [who, main.comms.subtitle]
	var max_w := s.x * 0.62
	var words := text.split(" ")
	var lines: Array = [""]
	for w in words:
		var trial: String = (lines[-1] + " " + w).strip_edges()
		if _font.get_string_size(trial, HORIZONTAL_ALIGNMENT_LEFT, -1,
				FONT_SIZE + 1).x > max_w:
			lines.append(w)
		else:
			lines[-1] = trial
	var y := 58.0
	for ln in lines:
		var w2 := _font.get_string_size(ln, HORIZONTAL_ALIGNMENT_LEFT, -1,
				FONT_SIZE + 1).x
		draw_rect(Rect2(s.x / 2.0 - w2 / 2.0 - 6, y - FONT_SIZE - 2,
				w2 + 12, FONT_SIZE + 8), Color(0, 0.05, 0, 0.55))
		draw_string(_font, Vector2(s.x / 2.0 - w2 / 2.0, y), ln,
				HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE + 1, GREEN)
		y += FONT_SIZE + 8

func _draw_objectives() -> void:
	if main.mission == null or main.mission.objectives.is_empty():
		return
	var x := 20.0
	var y := _screen().y - 150.0
	draw_string(_font, Vector2(x, y), "OBJECTIVES",
			HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE - 1, GREEN_DIM)
	for id in main.mission.objectives:
		var o: Dictionary = main.mission.objectives[id]
		if o["done"]:
			continue
		y += 17
		draw_string(_font, Vector2(x, y), "- " + str(o["text"]).left(52),
				HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE - 1, YELLOW)

# --- shared chrome ----------------------------------------------------------

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

func _contact_color(hostile: bool, category: String) -> Color:
	if hostile:
		return RED
	if category == "lpoint":
		return GREEN
	if category == "traffic":
		return BLUE
	return YELLOW

# --- center reticle ---------------------------------------------------------

func _draw_reticle(c: Vector2) -> void:
	var in_lds: bool = main.lds_state == 2
	var ring := LDS_COL if in_lds else GREEN
	draw_arc(c, 56.0, 0, TAU, 64, Color(ring.r, ring.g, ring.b, 0.5), 1.2, true)
	for i in 12:
		var a := TAU * i / 12.0
		var dir := Vector2(cos(a), sin(a))
		var inner := 50.0 if i % 3 == 0 else 53.0
		draw_line(c + dir * inner, c + dir * 56.0, ring, 1.2, true)
	draw_line(c + Vector2(-5, 0), c + Vector2(5, 0), ring, 1.0, true)
	draw_line(c + Vector2(0, -5), c + Vector2(0, 5), ring, 1.0, true)
	# own hull: arc at the lower right of the reticle, green -> yellow -> red
	var frac: float = clampf(main.hull / main.hull_max, 0.0, 1.0)
	var hull_col := GREEN if frac > 0.66 else (YELLOW if frac > 0.33 else RED)
	draw_arc(c, 64.0, TAU * 0.02, TAU * 0.02 + TAU * 0.21 * frac, 24,
			hull_col, 2.5, true)
	# own speed, left: actual on top, set speed beneath
	var vel: float = main.ship.forward_speed()
	var vel_text: String = ("%s/s" % main._fmt_dist(vel)) if in_lds \
		else "%+.0f m/s" % vel
	draw_string(_font_num, c + Vector2(-166, -2), vel_text,
			HORIZONTAL_ALIGNMENT_LEFT, -1, num_size, ring)
	_tri(c + Vector2(-70, -6), 0.0, ring, 5.0)
	draw_string(_font_num, c + Vector2(-166, 14), "set %.0f" % main.ship.set_speed,
			HORIZONTAL_ALIGNMENT_LEFT, -1, num_size - 2,
			Color(ring.r, ring.g, ring.b, 0.55))
	# target data, right: hull / range / closing speed (name is in the MFD)
	var tdist: float = main._target_distance()
	if tdist < INF:
		var col := _target_color()
		_tri(c + Vector2(70, -6), PI, col, 5.0)
		var tvel := Vector3.ZERO
		if main.target_ai != null and is_instance_valid(main.target_ai):
			tvel = main.target_ai.velocity
			draw_string(_font, c + Vector2(80, -18), "%d" %
				int(100.0 * main.target_ai.hull / main.target_ai.hull_max),
				HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE - 1, col)
		var closing: float = (main.ship.velocity - tvel).dot(
			main._target_pos().normalized())
		draw_string(_font_num, c + Vector2(80, -2), main._fmt_dist(tdist),
				HORIZONTAL_ALIGNMENT_LEFT, -1, num_size, col)
		draw_string(_font_num, c + Vector2(80, 14), "%+.0f m/s" % closing,
				HORIZONTAL_ALIGNMENT_LEFT, -1, num_size - 2, col)
		_reticle_turn_arrow(c)
	# velocity vector marker
	var v: Vector3 = main.ship.velocity
	if v.length() > 5.0 and not in_lds:
		var cam: Camera3D = main.cam
		var ahead: Vector3 = main.ship.global_position + v.normalized() * 5000.0
		if not cam.is_position_behind(ahead):
			var p := cam.unproject_position(ahead)
			draw_arc(p, 6.0, 0, TAU, 16, ring, 1.4, true)
			draw_line(p + Vector2(-12, 0), p + Vector2(-6, 0), ring, 1.4)
			draw_line(p + Vector2(6, 0), p + Vector2(12, 0), ring, 1.4)
	_draw_status_icons(c)

func _reticle_turn_arrow(c: Vector2) -> void:
	# when the target is outside the reticle, an arrow inside the ring shows
	# which way to turn (manual, HUD section)
	var world: Vector3 = main._target_pos()
	var cam: Camera3D = main.cam
	var col := _target_color()
	var behind := cam.is_position_behind(world)
	var p := Vector2.INF if behind else cam.unproject_position(world)
	if not behind and p.distance_to(c) < 56.0:
		return
	var local: Vector3 = cam.global_transform.affine_inverse() * world
	var dir2 := Vector2(local.x, -local.y)
	if dir2.length() < 0.001:
		return
	dir2 = dir2.normalized()
	_tri(c + dir2 * 40.0, dir2.angle(), col, 7.0)

func _target_color() -> Color:
	if main.target_ai != null and is_instance_valid(main.target_ai):
		return RED if main.target_ai.behavior == "attack" else BLUE
	if main.target_idx >= 0:
		var t: Dictionary = main.objects[main.target_idx]
		return GREEN if t["category"] == "lpoint" else YELLOW
	return YELLOW

func _draw_status_icons(c: Vector2) -> void:
	# pop-up icons around the reticle (manual: clockwise from 9 o'clock)
	var icons: Array = []
	if not main.ship.assist:
		icons.append(["FA OFF", RED])
	if main.ship.thrusting():
		icons.append(["LAT", GREEN])
	if main.docked_at != "":
		icons.append(["DOCKED", GREEN])
	match main.lds_state:
		1: icons.append(["LDS RAMP", LDS_COL])
		2: icons.append(["LDS", LDS_COL])
	if main.lds_state == 0 and main.jump_state == 0 and main._lds_clearance() < 0.0:
		icons.append(["INHIBITED", YELLOW])
	match main.jump_state:
		1: icons.append(["CAPSULE CHG", ORANGE])
		2: icons.append(["ACCEL RUN", ORANGE])
		3: icons.append(["JUMP", ORANGE])
	if main.ap_mode > 0:
		icons.append([["", "AP:APPR", "AP:FORM", "AP:DOCK", "AP:MATCH"][main.ap_mode],
			GREEN])
	var start_a := PI  # 9 o'clock, going clockwise
	for i in icons.size():
		var a: float = start_a + (i + 1) * 0.5
		var pos := c + Vector2(cos(a), sin(a)) * 92.0
		var text: String = icons[i][0]
		var col: Color = icons[i][1]
		var w := _font.get_string_size(text, HORIZONTAL_ALIGNMENT_CENTER, -1,
				FONT_SIZE - 2).x
		draw_rect(Rect2(pos - Vector2(w / 2 + 4, 10), Vector2(w + 8, 15)),
				Color(0, 0.06, 0, 0.6))
		draw_rect(Rect2(pos - Vector2(w / 2 + 4, 10), Vector2(w + 8, 15)),
				col * Color(1, 1, 1, 0.5), false, 1.0)
		draw_string(_font, pos + Vector2(-w / 2, 2), text,
				HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE - 2, col)

func _tri(p: Vector2, a: float, col: Color, size := 7.0) -> void:
	var d := Vector2(cos(a), sin(a))
	var perp := Vector2(-d.y, d.x)
	draw_colored_polygon(PackedVector2Array([
		p + d * size, p - d * size * 0.6 + perp * size * 0.7,
		p - d * size * 0.6 - perp * size * 0.7]), col)

# --- world-space target marks -----------------------------------------------

func _draw_target_marks() -> void:
	var world: Vector3
	if main.target_ai != null and is_instance_valid(main.target_ai):
		world = main.target_ai.global_position
	elif main.target_idx >= 0:
		var t: Dictionary = main.objects[main.target_idx]
		world = Vector3(t["x"] - main.px, t["y"] - main.py, t["z"] - main.pz)
	else:
		return
	var cam: Camera3D = main.cam
	var col := _target_color()
	if cam.is_position_behind(world):
		return
	var p := cam.unproject_position(world)
	if not Rect2(Vector2.ZERO, _screen()).has_point(p):
		return
	# waypoints get the original's small diamond, ships corner triangles
	if main.target_ai == null and main.objects[main.target_idx]["category"] == "lpoint":
		var pts := PackedVector2Array([p + Vector2(0, -10), p + Vector2(10, 0),
				p + Vector2(0, 10), p + Vector2(-10, 0), p + Vector2(0, -10)])
		draw_polyline(pts, col, 1.4, true)
	else:
		for i in 4:
			var a := TAU * i / 4.0 + TAU / 8.0
			_tri(p + Vector2(cos(a), sin(a)) * 26.0, a + PI, col)
	# lead indicator for moving targets
	if main.target_ai != null and is_instance_valid(main.target_ai):
		var tvel: Vector3 = main.target_ai.velocity - main.ship.velocity
		var lead: Vector3 = world + tvel * (world.length() / 6000.0)
		if not cam.is_position_behind(lead):
			var lp := cam.unproject_position(lead)
			var pts := PackedVector2Array([lp + Vector2(0, -8), lp + Vector2(8, 0),
					lp + Vector2(0, 8), lp + Vector2(-8, 0), lp + Vector2(0, -8)])
			draw_polyline(pts, col, 1.4, true)

# --- MFD (upper-left) -------------------------------------------------------

func _draw_mfd() -> void:
	var pos := Vector2(16, 16)
	var size := Vector2(220, 150)
	_panel(pos, size, "TARGETING")
	var tname := ""
	var ttype := ""
	var col := YELLOW
	var hull_frac := -1.0
	if main.target_ai != null and is_instance_valid(main.target_ai):
		tname = str(main.target_ai.name)
		var host: bool = main.target_ai.behavior == "attack"
		ttype = "HOSTILE VESSEL" if host else "TRANSPORT VESSEL"
		col = RED if host else BLUE
		hull_frac = main.target_ai.hull / main.target_ai.hull_max
	elif main.target_idx >= 0:
		var t: Dictionary = main.objects[main.target_idx]
		tname = str(t["name"])
		ttype = str(t["category"]).to_upper()
		col = GREEN if t["category"] == "lpoint" else YELLOW
	else:
		draw_string(_font, pos + Vector2(10, 40), "NO TARGET",
				HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE, GREEN_DIM)
		return
	draw_string(_font, pos + Vector2(8, 32), tname.left(28),
			HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE, col)
	draw_string(_font, pos + Vector2(8, 47), ttype,
			HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE - 2, GREEN_DIM)
	if hull_frac >= 0.0:
		_bar(pos + Vector2(8, 54), 130, hull_frac, col, 13)
	# EO feed: rotating wireframe
	var center := pos + Vector2(size.x / 2.0, 104)
	var t := Time.get_ticks_msec() / 1000.0
	var basis := Basis(Vector3.UP, t * 0.6) * Basis(Vector3.RIGHT, 0.35)
	var ext := Vector3(34, 12, 44)
	if main.target_ai == null:
		ext = Vector3(30, 26, 30)
	var corners: Array = []
	for sx in [-1, 1]:
		for sy in [-1, 1]:
			for sz in [-1, 1]:
				var p3: Vector3 = basis * Vector3(sx * ext.x, sy * ext.y, sz * ext.z)
				corners.append(center + Vector2(p3.x, -p3.y * 0.8 + p3.z * 0.25))
	for e in [[0, 1], [0, 2], [1, 3], [2, 3], [4, 5], [4, 6], [5, 7], [6, 7],
			[0, 4], [1, 5], [2, 6], [3, 7]]:
		draw_line(corners[e[0]], corners[e[1]], col * Color(1, 1, 1, 0.7), 1.0, true)
	draw_string(_font, pos + Vector2(size.x - 60, size.y - 6), "EO FEED",
			HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE - 3, GREEN_DIM)

func _draw_weapon_panel() -> void:
	var pos := Vector2(16, 176)
	_panel(pos, Vector2(220, 62), "L-PBC / R-PBC")
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

# --- system status lights (top-center) --------------------------------------

const SYSTEMS := ["DRV", "THR", "LDS", "CAP", "WEP", "SEN", "EPS", "CPU"]

func _draw_system_status() -> void:
	var s := _screen()
	var w := SYSTEMS.size() * 32.0
	var pos := Vector2(s.x / 2.0 - w / 2.0, 12)
	var hull_frac: float = main.hull / main.hull_max
	var blink := int(Time.get_ticks_msec() / 300.0) % 2 == 0
	for i in SYSTEMS.size():
		var x := pos.x + i * 32.0
		# damage light: our prototype has a single hull pool, so systems
		# yellow/red out progressively as the hull goes down
		var sys_health := clampf(hull_frac * 1.4 - i * 0.05, 0.0, 1.0)
		var dcol := GREEN if sys_health > 0.66 else (YELLOW if sys_health > 0.33 else RED)
		if sys_health < 1.0 and blink:
			dcol = Color(dcol.r, dcol.g, dcol.b, 0.35)
		draw_rect(Rect2(x, pos.y, 20, 7), dcol)
		draw_rect(Rect2(x, pos.y + 9, 20, 7), Color(0.3, 0.5, 1.0, 0.9))
		draw_string(_font, Vector2(x, pos.y + 28), SYSTEMS[i],
				HORIZONTAL_ALIGNMENT_LEFT, -1, 8, GREEN_DIM)
	draw_rect(Rect2(pos - Vector2(6, 4), Vector2(w + 8, 24)), GREEN_DIM, false, 1.0)

# --- ORB (top-right) --------------------------------------------------------

func _orb_contacts() -> Array:
	var out: Array = []
	for i in main.objects.size():
		var o: Dictionary = main.objects[i]
		var rel := Vector3(o["x"] - main.px, o["y"] - main.py, o["z"] - main.pz)
		var d := rel.length()
		var ok := false
		match o["category"]:
			"station":
				ok = d < 5.0e5
			"lpoint":
				ok = d < 1.0e7
		if ok:
			out.append([rel, _contact_color(false, o["category"]),
				i == main.target_idx])
	for a in main.ai_ships:
		out.append([a.global_position,
			_contact_color(a.behavior == "attack", "traffic"), a == main.target_ai])
	return out

func _draw_orb() -> void:
	var s := _screen()
	var pos := Vector2(s.x - 156, 16)
	var size := Vector2(140, 158)
	var contacts := _orb_contacts()
	_panel(pos, size, "%d CONTACTS" % contacts.size())
	var c := pos + Vector2(size.x / 2.0, 92)
	var r := 40.0
	# wireframe sphere: equator + two meridians as ellipses
	draw_arc(c, r, 0, TAU, 40, GREEN_DIM, 1.0, true)
	_ellipse(c, Vector2(r, r * 0.35), GREEN_DIM * Color(1, 1, 1, 0.7))
	_ellipse(c, Vector2(r * 0.35, r), GREEN_DIM * Color(1, 1, 1, 0.7))
	var inv: Transform3D = main.ship.global_transform.affine_inverse()
	var blink := int(Time.get_ticks_msec() / 250.0) % 2 == 0
	for entry in contacts:
		var rel: Vector3 = entry[0]
		var local: Vector3 = (inv.basis * rel)
		var d := local.length()
		if d < 1.0:
			continue
		var nd := local / d
		# project the sphere point (x right, y up-ish with z depth squash)
		var sp := c + Vector2(nd.x, -nd.y * 0.6 - nd.z * 0.55) * r
		# stalk: inward when closer than 1 km, outward when farther
		var stalk := clampf(log(d / 1000.0) / log(10.0) * 0.35, -0.8, 0.9)
		var dir := (sp - c).normalized() if (sp - c).length() > 0.5 else Vector2.RIGHT
		var tip := sp + dir * stalk * 14.0
		var col: Color = entry[1]
		draw_line(sp, tip, col * Color(1, 1, 1, 0.6), 1.0, true)
		if entry[2] and blink:
			draw_circle(tip, 3.5, Color(1, 1, 1, 0.9))
		else:
			draw_circle(tip, 2.2, col)
	# clock: time since leaving port (orange, like the original)
	var ms: int = Time.get_ticks_msec() - main.clock_start
	draw_string(_font_num, pos + Vector2(size.x - 128, size.y + 16),
			"%02d:%02d:%02d.%02d" % [ms / 3600000, (ms / 60000) % 60,
			(ms / 1000) % 60, (ms / 10) % 100],
			HORIZONTAL_ALIGNMENT_LEFT, -1, num_size - 2, ORANGE)

func _ellipse(c: Vector2, radii: Vector2, col: Color) -> void:
	var pts := PackedVector2Array()
	for i in 33:
		var a := TAU * i / 32.0
		pts.append(c + Vector2(cos(a) * radii.x, sin(a) * radii.y))
	draw_polyline(pts, col, 1.0, true)

# --- contact list (lower-right) ---------------------------------------------

func _draw_contact_list() -> void:
	var s := _screen()
	var rows: Array = main.contact_list()
	var h := 22.0 + rows.size() * 17.0
	var pos := Vector2(s.x - 396, s.y - h - 16)
	_panel(pos, Vector2(380, h), "CONTACT REGISTRY")
	var y := pos.y + 30
	for entry in rows:
		var col := _contact_color(entry["hostile"], str(entry.get("category", "")))
		if entry["targeted"]:
			draw_rect(Rect2(pos.x + 2, y - 12, 376, 16),
					Color(col.r, col.g, col.b, 0.18))
		draw_string(_font, Vector2(pos.x + 6, y), str(entry.get("faction", "")),
				HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE - 1, col)
		draw_string(_font, Vector2(pos.x + 56, y), str(entry.get("type", "")),
				HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE - 1, col)
		draw_string(_font, Vector2(pos.x + 108, y),
				main._fmt_dist(entry["dist"]),
				HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE - 1, col)
		draw_string(_font, Vector2(pos.x + 176, y), str(entry["name"]).left(24),
				HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE - 1, col)
		y += 17.0

# --- messages ----------------------------------------------------------------

func _draw_log(c: Vector2) -> void:
	var now := Time.get_ticks_msec() / 1000.0
	while not log_lines.is_empty() and log_lines[0]["until"] < now:
		log_lines.pop_front()
	var y := c.y + 150.0
	for entry in log_lines:
		var text: String = str(entry["text"])
		var w := _font.get_string_size(text, HORIZONTAL_ALIGNMENT_CENTER, -1,
				FONT_SIZE).x
		draw_string(_font, Vector2(c.x - w / 2.0, y), text,
				HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE, entry["color"])
		y += 18.0

func _draw_console() -> void:
	var x := 20.0
	var y := _screen().y - 76.0
	var lines := ["SYS %s" % str(main.system_name).to_upper()]
	var routes: String = main.routes_text()
	if routes != "" and main.jump_state == 0:
		lines.append(routes)
	if main.docked_at != "":
		lines = ["DOCKED: %s" % main.docked_at, "press U to undock"]
	for ln in lines:
		draw_string(_font, Vector2(x, y), ln, HORIZONTAL_ALIGNMENT_LEFT, -1,
				FONT_SIZE, GREEN)
		y += 20

func _draw_warnings(c: Vector2) -> void:
	# urgent warnings flash below the reticle (manual)
	if Time.get_ticks_msec() / 1000.0 < warning_until:
		if int(Time.get_ticks_msec() / 250.0) % 3 == 0:
			return
		var w := _font_big.get_string_size(warning_text, HORIZONTAL_ALIGNMENT_CENTER,
				-1, big_size).x
		draw_string(_font_big, Vector2(c.x - w / 2.0, c.y + 110), warning_text,
				HORIZONTAL_ALIGNMENT_LEFT, -1, big_size, RED)
