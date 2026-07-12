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
var _font_num: Font   # OCR-B 8pt â€” reticle numerics
var _font_big: Font   # Handel Gothic 12pt â€” warnings
var num_size := 14
var big_size := 17
var target_view: TargetView  # live EO-feed render of the target
var _sprites: Texture2D      # images/hud/sprites.png, 8x8 grid of 32px icons
const SPR_BANG := Rect2(128, 96, 32, 32)  # the "!" warning glyph

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
	_font_num = load_game_font(base, "ocrb_8pt.fnt")  # tight reticle numerics
	_font_big = load_game_font(base, "handelgothic bt_12pt.fnt")
	if _font is FontFile and (_font as FontFile).fixed_size > 0:
		FONT_SIZE = (_font as FontFile).fixed_size
	if _font_num is FontFile and (_font_num as FontFile).fixed_size > 0:
		num_size = (_font_num as FontFile).fixed_size
	if _font_big is FontFile and (_font_big as FontFile).fixed_size > 0:
		big_size = (_font_big as FontFile).fixed_size
	target_view = TargetView.new()
	target_view.main = main
	add_child(target_view)
	var sprites_path := base.path_join("data/textures/images/hud/sprites.png")
	if FileAccess.file_exists(sprites_path):
		var img := Image.load_from_file(sprites_path)
		if img != null:
			# the atlas is white glyphs on black; convert to an alpha mask
			# so tinting a glyph doesn't paint its black cell background
			img.convert(Image.FORMAT_RGBA8)
			for y in img.get_height():
				for x in img.get_width():
					var p := img.get_pixel(x, y)
					var l := maxf(p.r, maxf(p.g, p.b))
					img.set_pixel(x, y, Color(1, 1, 1, l))
			_sprites = ImageTexture.create_from_image(img)

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
	if main.comms != null and main.comms.speaking():
		target_view.enabled = false
		main.comms.portrait.visible = true  # channel stays open between lines
		_draw_comm_panel()
	else:
		if main.comms != null:
			main.comms.portrait.visible = false
		_draw_mfd()
	_draw_weapon_panel()
	_draw_system_status()
	_draw_orb()
	_draw_contact_list()
	_draw_log(c)
	_draw_console()
	_draw_warnings(c)
	_draw_subtitles()
	_draw_prompt(c)
	_draw_choices(c)
	_draw_objectives()

const SUBTITLE_COL := Color(1.0, 0.93, 0.55, 1.0)  # pale yellow, original

func _draw_comm_panel() -> void:
	# comm portrait replaces the targeting MFD while a channel is open:
	# "COMM CHANNEL OPEN" header, portrait feed, speaker caption (manual)
	var pos := Vector2(16, 16)
	var size := Vector2(240, 210)
	_panel(pos, size, "COMM CHANNEL OPEN")
	main.comms.portrait.position = pos + Vector2(18, 24)
	var who := str(main.comms.speaker).to_upper()
	draw_string(_font, pos + Vector2(8, size.y - 8), who,
			HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE, GREEN)
	draw_string(_font_num, pos + Vector2(8 + 70, size.y - 8), "E0",
			HORIZONTAL_ALIGNMENT_LEFT, -1, num_size - 2, GREEN_DIM)

func _draw_subtitles() -> void:
	# in-flight dialogue subtitles at the top of the HUD (manual, comms):
	# pale yellow with a dark drop, like the original
	if main.comms == null or str(main.comms.subtitle) == "":
		return
	var s := _screen()
	var who := str(main.comms.speaker).capitalize()
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
	var y := 64.0  # below the system-status lights
	for ln in lines:
		var w2 := _font.get_string_size(ln, HORIZONTAL_ALIGNMENT_LEFT, -1,
				FONT_SIZE + 1).x
		var at := Vector2(s.x / 2.0 - w2 / 2.0, y)
		draw_string(_font, at + Vector2(1, 1), ln,
				HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE + 1, Color(0, 0, 0, 0.8))
		draw_string(_font, at, ln,
				HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE + 1, SUBTITLE_COL)
		y += FONT_SIZE + 7

func _draw_choices(c: Vector2) -> void:
	# comms response menu (iconversation.Ask): numbered options
	if main.comms == null or not main.comms.choosing():
		return
	var opts: Array = main.comms.ask_options
	var y := c.y + 180.0
	draw_string(_font, Vector2(c.x - 200, y - 18), "RESPOND:",
			HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE - 1, GREEN_DIM)
	for i in opts.size():
		var text := "%d. %s" % [i + 1, str(opts[i]["text"])]
		draw_string(_font, Vector2(c.x - 199, y + 1), text,
				HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE, Color(0, 0, 0, 0.8))
		draw_string(_font, Vector2(c.x - 200, y), text,
				HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE, YELLOW)
		y += 17.0

func _draw_prompt(c: Vector2) -> void:
	# the original's lesson prompt (ihud.SetPrompt): instruction + key hint
	if main.mission == null or str(main.mission.prompt) == "":
		return
	var text: String = "+ " + str(main.mission.prompt)
	if str(main.mission.prompt_keys) != "":
		text += "  [ %s ]" % main.mission.prompt_keys
	var w := _font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1,
			FONT_SIZE).x
	var at := Vector2(c.x - w / 2.0, c.y + 148)
	draw_string(_font, at + Vector2(1, 1), text,
			HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE, Color(0, 0, 0, 0.8))
	draw_string(_font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE,
			GREEN)

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

func _fmt_tight(d: float) -> String:
	# the original's compact ranges: "4000m", "7071m", "18.7k", "2.1Mm"
	if d < 1e4:
		return "%dm" % int(d)
	if d < 1e6:
		return "%.1fk" % (d / 1e3)
	if d < 1e9:
		return "%.1fMm" % (d / 1e6)
	return "%.2fAU" % (d / 1.496e11)

func _panel(pos: Vector2, size: Vector2, title: String) -> void:
	# glossy chrome: dark glass body with a subtle top sheen, bright header
	draw_rect(Rect2(pos + Vector2(0, 16), size - Vector2(0, 16)),
			Color(0.0, 0.05, 0.0, 0.62))
	draw_rect(Rect2(pos + Vector2(1, 17), Vector2(size.x - 2, 10)),
			Color(0.5, 1.0, 0.6, 0.05))
	draw_rect(Rect2(pos, Vector2(size.x, 16)), GREEN_PANEL)
	draw_rect(Rect2(pos, Vector2(size.x, 5)), Color(0.7, 1.0, 0.75, 0.25))
	draw_string(_font, pos + Vector2(5, 12), title,
			HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE - 1, Color(0, 0, 0, 0.9))
	draw_rect(Rect2(pos, size), GREEN_DIM, false, 1.0)
	draw_rect(Rect2(pos - Vector2(1, 1), size + Vector2(2, 2)),
			Color(GREEN.r, GREEN.g, GREEN.b, 0.12), false, 1.0)

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
	# LDS inhibition: the original's "!" roundel above the reticle, with
	# charge pips over it (images/hud/sprites.png glyph)
	var inhibited: bool = main.lds_state == 0 and main.jump_state == 0 \
		and main._lds_clearance() < 0.0 and main.docked_at == ""
	if inhibited or main.disrupt_time > 0.0:
		_draw_inhibit_roundel(c + Vector2(-46, -96), main.inhibit_charge())
	# own hull: arc at the lower right of the reticle, green -> yellow -> red
	var frac: float = clampf(main.hull / main.hull_max, 0.0, 1.0)
	var hull_col := GREEN if frac > 0.66 else (YELLOW if frac > 0.33 else RED)
	draw_arc(c, 64.0, TAU * 0.02, TAU * 0.02 + TAU * 0.21 * frac, 24,
			hull_col, 2.5, true)
	# own speed, left of the reticle, tight like the original ("+000m/s")
	var vel: float = main.ship.forward_speed()
	var vel_text: String = ("%s/s" % _fmt_tight(absf(vel))) if in_lds \
		else "%s%03dm/s" % ["-" if vel < 0 else "+", absi(int(absf(vel)))]
	var vw := _font_num.get_string_size(vel_text, HORIZONTAL_ALIGNMENT_LEFT,
			-1, num_size).x
	draw_string(_font_num, c + Vector2(-84 - vw, 2), vel_text,
			HORIZONTAL_ALIGNMENT_LEFT, -1, num_size, ring)
	_tri(c + Vector2(-72, -2), 0.0, ring, 5.0)
	if main.ship.set_speed > 0.5:
		var st := "set %d" % int(main.ship.set_speed)
		var sw2 := _font_num.get_string_size(st, HORIZONTAL_ALIGNMENT_LEFT,
				-1, num_size).x
		draw_string(_font_num, c + Vector2(-84 - sw2, 16), st,
				HORIZONTAL_ALIGNMENT_LEFT, -1, num_size,
				Color(ring.r, ring.g, ring.b, 0.55))
	# target data, right: hull above range, tight ("100" / "4.0km")
	var tdist: float = main._target_distance()
	if tdist < INF:
		var col := _target_color()
		_tri(c + Vector2(72, -2), PI, col, 5.0)
		var tvel := Vector3.ZERO
		if main.target_ai != null and is_instance_valid(main.target_ai):
			tvel = main.target_ai.velocity
			draw_string(_font_num, c + Vector2(84, -12), "%d" %
				int(100.0 * main.target_ai.hull / main.target_ai.hull_max),
				HORIZONTAL_ALIGNMENT_LEFT, -1, num_size, col)
		var closing: float = (main.ship.velocity - tvel).dot(
			main._target_pos().normalized())
		draw_string(_font_num, c + Vector2(84, 2), _fmt_tight(tdist),
				HORIZONTAL_ALIGNMENT_LEFT, -1, num_size, col)
		draw_string(_font_num, c + Vector2(84, 16), "%+dm/s" % int(closing),
				HORIZONTAL_ALIGNMENT_LEFT, -1, num_size,
				Color(col.r, col.g, col.b, 0.7))
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

func _draw_inhibit_roundel(ip: Vector2, charge: float) -> void:
	# LDS inhibition (and LDSi missile hits): the "!" roundel. The pip ring
	# encircles it and DISCHARGES as you approach the edge of the field —
	# `charge` is 1 deep inside the zone, 0 at its boundary.
	var g := Color(0.45, 1.0, 0.35)
	draw_circle(ip, 17.0, Color(g.r, g.g, g.b, 0.12))
	draw_circle(ip, 13.0, Color(g.r, g.g, g.b, 0.85))
	draw_arc(ip, 14.0, 0, TAU, 40, Color(g.r, g.g, g.b, 0.95), 1.6, true)
	if _sprites != null:
		draw_texture_rect_region(_sprites, Rect2(ip - Vector2(9, 9),
				Vector2(18, 18)), SPR_BANG, Color(0.0, 0.13, 0.02, 0.95))
	else:
		draw_string(_font_big, ip + Vector2(-3, 6), "!",
				HORIZONTAL_ALIGNMENT_LEFT, -1, big_size, Color(0.0, 0.13, 0.02))
	var pips := 16
	var lit := int(round(clampf(charge, 0.0, 1.0) * pips))
	for i in pips:
		var a := -PI / 2.0 + TAU * i / float(pips)
		var pp := ip + Vector2(cos(a), sin(a)) * 17.5
		if i < lit:
			draw_circle(pp, 1.5, Color(g.r, g.g, g.b, 0.95))
		else:
			draw_circle(pp, 1.2, Color(g.r, g.g, g.b, 0.22))

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
		tname = str(main.target_ai.display_name)
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
		target_view.enabled = false
		draw_string(_font, pos + Vector2(10, 40), "NO TARGET",
				HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE, GREEN_DIM)
		return
	draw_string(_font, pos + Vector2(8, 32), tname.left(28),
			HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE, col)
	draw_string(_font, pos + Vector2(8, 47), ttype,
			HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE - 2, GREEN_DIM)
	if hull_frac >= 0.0:
		_bar(pos + Vector2(8, 54), 130, hull_frac, col, 13)
	# EO feed: live render of the actual target model
	var has_model := target_view.show_avatar(main.target_avatar())
	target_view.enabled = has_model
	if has_model:
		draw_texture_rect(target_view.get_texture(),
				Rect2(pos + Vector2(10, 52), Vector2(200, 92)), false)
	else:
		# waypoints and modelless contacts keep the wireframe diamond
		var center := pos + Vector2(size.x / 2.0, 104)
		var t := Time.get_ticks_msec() / 1000.0
		var basis := Basis(Vector3.UP, t * 0.6) * Basis(Vector3.RIGHT, 0.35)
		var ext := Vector3(30, 26, 30)
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
	var comm_open: bool = main.comms != null and main.comms.speaking()
	var pos := Vector2(16, 242 if comm_open else 176)
	var dual: bool = "/" in str(main.weapon_name)
	_panel(pos, Vector2(220, 62 if dual else 48), str(main.weapon_name))
	var charge: float = 1.0
	if main.weapons != null:
		charge = 1.0 - main.weapons.cooldown / main.weapons.refire
	# lightning glyph, like the original's weapon-charge icon
	var lp := pos + Vector2(14, 34)
	draw_colored_polygon(PackedVector2Array([
		lp + Vector2(3, -8), lp + Vector2(-4, 1), lp + Vector2(-1, 1),
		lp + Vector2(-3, 8), lp + Vector2(4, -1), lp + Vector2(1, -1)]),
		YELLOW)
	if dual:
		for i in 2:
			var y := 26.0 + i * 16.0
			draw_string(_font, pos + Vector2(26, y + 8), "L" if i == 0 else "R",
					HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE - 2, GREEN)
			_bar(pos + Vector2(42, y), 132, charge, GREEN, 12)
			draw_string(_font, pos + Vector2(182, y + 8), "%d%%" % int(charge * 100),
					HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE - 2, GREEN)
	else:
		_bar(pos + Vector2(28, 28), 130, charge, GREEN, 14)
		draw_string(_font, pos + Vector2(166, 36), "%d%%" % int(charge * 100),
				HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE - 1, GREEN)

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
	# graph-paper backdrop, like the original's ORB panel
	for gx in range(int(pos.x) + 8, int(pos.x + size.x) - 4, 12):
		draw_line(Vector2(gx, pos.y + 20), Vector2(gx, pos.y + size.y - 4),
				Color(GREEN.r, GREEN.g, GREEN.b, 0.07), 1.0)
	for gy in range(int(pos.y) + 24, int(pos.y + size.y) - 4, 12):
		draw_line(Vector2(pos.x + 4, gy), Vector2(pos.x + size.x - 4, gy),
				Color(GREEN.r, GREEN.g, GREEN.b, 0.07), 1.0)
	var c := pos + Vector2(size.x / 2.0, 92)
	var r := 40.0
	# wireframe sphere: bright ring + equator/meridian, and the axis pole
	var ring := Color(0.55, 0.85, 0.3, 0.9)
	draw_arc(c, r, 0, TAU, 48, ring, 1.6, true)
	_ellipse(c, Vector2(r, r * 0.35), Color(ring.r, ring.g, ring.b, 0.55))
	_ellipse(c, Vector2(r * 0.35, r), Color(ring.r, ring.g, ring.b, 0.30))
	draw_line(c + Vector2(0, -r - 8), c + Vector2(0, r + 8),
			Color(1.0, 0.75, 0.15, 0.85), 2.0, true)
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
		# thick stalk (flux.ini icHUDOrbRadar use_thick_stalks): inward
		# when closer than 1 km, outward when farther
		var stalk := clampf(log(d / 1000.0) / log(10.0) * 0.35, -0.8, 0.9)
		var dir := (sp - c).normalized() if (sp - c).length() > 0.5 else Vector2.RIGHT
		var tip := sp + dir * stalk * 14.0
		var col: Color = entry[1]
		draw_line(sp, tip, col * Color(1, 1, 1, 0.75), 2.4, true)
		# blob contact: soft halo under a bright core, like the reference
		draw_circle(tip, 4.5, Color(col.r, col.g, col.b, 0.30))
		if entry[2] and blink:
			draw_circle(tip, 3.2, Color(1, 1, 1, 0.95))
		else:
			draw_circle(tip, 2.6, col)
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
	# original columns: FACTION TYPE RANGE NAME, names cut with ">"
	# ("INDPT UTIL 4000m SCOPO", "UTIL 7071m ABANDONED HU>")
	var s := _screen()
	var rows: Array = main.contact_list()
	var h := 24.0 + rows.size() * 16.0
	var pos := Vector2(s.x - 336, s.y - h - 16)
	draw_rect(Rect2(pos, Vector2(320, h)), Color(0.0, 0.05, 0.0, 0.55))
	draw_rect(Rect2(pos, Vector2(320, h)),
			Color(GREEN.r, GREEN.g, GREEN.b, 0.25), false, 1.0)
	var y := pos.y + 16
	for entry in rows:
		var col := _contact_color(entry["hostile"], str(entry.get("category", "")))
		if entry["targeted"]:
			draw_rect(Rect2(pos.x + 1, y - 11, 318, 15),
					Color(col.r, col.g, col.b, 0.20))
			draw_rect(Rect2(pos.x + 1, y - 11, 3, 15), col)
		var range_txt := _fmt_tight(float(entry["dist"]))
		var rw := _font.get_string_size(range_txt, HORIZONTAL_ALIGNMENT_LEFT,
				-1, FONT_SIZE - 1).x
		var nm := str(entry["name"]).to_upper()
		if nm.length() > 13:
			nm = nm.left(12) + ">"
		draw_string(_font, Vector2(pos.x + 8, y), str(entry.get("faction", "")),
				HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE - 1, col)
		draw_string(_font, Vector2(pos.x + 62, y), str(entry.get("type", "")),
				HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE - 1, col)
		draw_string(_font, Vector2(pos.x + 168 - rw, y), range_txt,
				HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE - 1, col)
		draw_string(_font, Vector2(pos.x + 178, y), nm,
				HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE - 1, col)
		y += 16.0

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
