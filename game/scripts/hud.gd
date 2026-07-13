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

# Palette lifted from the engine's static colour initialisers (iwar2.dll).
# Each is three consecutive float globals; addresses are the Ghidra DAT_ names.
# See docs/hud_elements.md.
const GREEN := Color(0.5, 1.0, 0.0, 0.95)          # DAT_10176038 - HUD chrome
const GREEN_DIM := Color(0.5, 1.0, 0.0, 0.4)
const GREEN_PANEL := Color(0.1, 0.5, 0.0, 0.8)     # not in binary: panel wash
const YELLOW := Color(1.0, 0.749, 0.0, 0.95)       # DAT_10164e58 - neutral
const AMBER := Color(1.0, 0.592, 0.0, 0.95)        # DAT_10174fb0 - reticle icons
const GOLD := Color(1.0, 0.8, 0.0, 0.95)           # DAT_10174f60 - healthy end of ramp
const ORANGE := Color(0.9, 0.43, 0.0, 0.95)        # DAT_101715e8
const RED := Color(1.0, 0.07, 0.0, 0.95)           # DAT_10176018 - hostile / alert
const BLUE := Color(0.3, 0.6, 1.0, 0.95)           # DAT_10174190 - friendly / traffic
const PALE := Color(0.9, 0.95, 1.0, 0.95)          # DAT_10174010 - cargo / inert
const LDS_COL := Color(0.5, 1.0, 0.0, 0.95)

# icHUDReticle geometry, in absolute pixels exactly as the binary uses them.
# The original HUD does not scale with resolution.
const RET_R := 63.0        # _DAT_1011e038  reticle ring radius
const RET_SLOP := 10.0     # _DAT_101190c0  target counts as "in reticle" within 63+10
const ICON_BASE := 80.0    # _DAT_1011e034  base radius for the status-icon ring
const ICON_R := 110.0      # ICON_BASE + _DAT_1011e040 (30)
const ICON_R_MODE := 150.0 # ICON_BASE + _DAT_1011e044 (70): the 4 mode icons
const ICON_PIPS := 24      # _DAT_1011e0bc  charge pips ringing an icon
const ICON_PIP_R := 18.0   # _DAT_101190bc  pip ring radius
const TEXT_X := 82.0       # ICON_BASE + _DAT_10119ec8 (2): target block / hull bar
const TEXT_GAP := 9.0      # _DAT_101190b8  bar -> text gap
# _DAT_1011b344: inside this range of a targeted L-point the reticle names its
# destination beside the capsule-drive icon.
const LPOINT_LABEL_RANGE := 50000.0
# FUN_100e88c0: the damage colour ramp's thresholds.
const HEALTH_HI := 0.75    # _DAT_10117d8c
const HEALTH_LO := 0.25    # _DAT_101191ec

var FONT_SIZE := 13
var _font: Font       # Handel Gothic 8pt -- panel text, like the original
var _font_num: Font   # OCR-B 8pt -- reticle numerics
var _font_big: Font   # Handel Gothic 12pt -- warnings
var num_size := 14
var big_size := 17
var target_view: TargetView  # live EO-feed render of the target
var _sprites: Texture2D      # images/hud/sprites.png
var _reticle_tex: Texture2D  # images/hud/reticle.png

# The engine's sprite atlas, recovered from the table builder at 0x100e6c60,
# which fills DAT_101741b0 (stride 0x24) one entry at a time by calling the
# record ctor FUN_100ee6b0(atlas_x, atlas_y, w, h, origin_x, origin_y, texture).
# The table itself lives in .bss, so it reads as zeroes from the PE -- it had to
# come out of the code. Only the ids the HUD actually references are listed.
# [x, y, w, h, origin_x, origin_y]; all from texture 0 (images/hud/sprites.png).
const SPR := {
	20: [68, 0, 11, 11, 5.5, 5.5],       # charge pip
	21: [0, 26, 32, 32, 16, 16],         # mode icon 1
	22: [33, 26, 32, 32, 16, 16],        # mode icon 2
	23: [99, 26, 32, 32, 16, 16],        # mode icon 3
	24: [66, 26, 32, 32, 16, 16],        # mode icon 4
	25: [132, 26, 32, 32, 16, 16],       # LDS drive (the striped capsule)
	26: [132, 92, 32, 32, 16, 16],       # "!"  -- LDS inhibited / disrupted
	27: [66, 125, 32, 32, 16, 16],       # power symbol -- a system is down
	28: [99, 125, 32, 32, 16, 16],       # drive-controller state (see docs)
	29: [132, 125, 32, 32, 16, 16],      # drive-controller state (see docs)
	30: [165, 125, 32, 32, 16, 16],      # capsule drive / jump
	50: [132, 59, 32, 32, 16, 16],       # rotating sweep wedge (flag bit 1)
	51: [165, 92, 32, 32, 16, 16],       # roundel: soft disc
	52: [165, 59, 32, 32, 16, 16],       # roundel: ring
	53: [198, 59, 32, 32, 16, 16],       # roundel: ring + disc  (bits 0|3)
	62: [0, 191, 32, 32, 16, 16],        # thermometer
	63: [33, 191, 32, 32, 16, 16],       # lightning bolt
	64: [198, 191, 32, 32, 16, 16],      # light bulb
	78: [99, 224, 32, 32, 16, 16],       # missile
	86: [132, 224, 32, 32, 16, 16],      # alpha  (multiplayer)
	87: [166, 224, 32, 32, 16, 16],      # beta   (multiplayer)
	88: [198, 224, 32, 32, 16, 16],      # flag   (multiplayer)
	89: [132, 158, 32, 32, 16, 16],      # bomb   (multiplayer)
}

# FUN_100ea2b0's fourth argument is NOT a size (as an earlier pass assumed) --
# it is a flag bitfield that selects the icon's backing roundel and animation:
#   bit0|bit3 -> roundel sprite 53 (ring + disc); bit0 alone -> 51; bit3 -> 52
#   bit1      -> sprite 50, a wedge spinning at 1 rev/s (rot = -2*PI * frac(t))
#   bit2      -> the icon pulses: alpha = |frac(t/2) - 0.5| * 1.8 + 0.1
# The only values the reticle passes are 9, 11 and 13, so every status icon has
# a roundel; 11 spins a sweep over it and 13 pulses it. Glyphs are never scaled.
const ICON_ROUNDEL := 1
const ICON_SWEEP := 2
const ICON_PULSE := 4
const ICON_RING := 8

# images/hud/reticle.png (texture 2 in the same table).
const SPR_RET := {
	90: [0, 0, 170, 170, 84, 84],     # the reticle ring
	91: [85, 0, 85, 85, 0, 85],       # menu reticle: the static backing quadrant
	93: [0, 186, 70, 70, 0, 70],      # menu reticle: the spinning quadrant
}

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
	_sprites = _load_mask(base, "sprites.png")
	_reticle_tex = _load_mask(base, "reticle.png")
	screens = HudScreens.new()
	screens.hud = self
	screens.main = main
	add_child(screens)

static func _load_mask(base: String, file: String) -> Texture2D:
	# the HUD atlases are white glyphs on black; convert to an alpha mask so
	# tinting a glyph does not paint its black cell background with it
	var path := base.path_join("data/textures/images/hud").path_join(file)
	if not FileAccess.file_exists(path):
		return null
	var img := Image.load_from_file(path)
	if img == null:
		return null
	img.convert(Image.FORMAT_RGBA8)
	for y in img.get_height():
		for x in img.get_width():
			var p := img.get_pixel(x, y)
			img.set_pixel(x, y, Color(1, 1, 1, maxf(p.r, maxf(p.g, p.b))))
	return ImageTexture.create_from_image(img)

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

func _process(d: float) -> void:
	_menu_spin += d * TAU * 0.05  # the four quadrants turn slowly together
	_menu_process(d)
	if screens != null:
		screens.visible = screen != ""
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
		_draw_menu_reticle(c)
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

func _mfd_rect() -> Rect2:
	return Rect2(Vector2(_left_x(), MARGIN), MFD_SIZE)

func _draw_comm_panel() -> void:
	# the comm channel takes over the target MFD's block (hud_target_comm_channel_open)
	var r := _mfd_rect()
	_panel(r.position, r.size, "COMM CHANNEL OPEN")
	# comms.gd builds the portrait at a fixed 204x148; scale it into the MFD's
	# 128px block rather than letting it overhang
	var feed_w := r.size.x - 2.0 * BORDER
	var p: Control = main.comms.portrait
	p.scale = Vector2.ONE * (feed_w / p.size.x)
	p.position = r.position + Vector2(BORDER, HDR_H + 4)
	var who := str(main.comms.speaker).to_upper()
	draw_string(_font, r.position + Vector2(32, r.size.y - 6), who.left(14),
			HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE - 1, AMBER)

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
# iiHUDBlockElement's layout, in absolute pixels. Blocks stack in the screen
# corners: 6px screen margin (DAT_1011d80c), a 4px border (DAT_1011d96c) that
# shifts left-anchored blocks 8px in, a 3px gap between blocks (DAT_1011d810),
# and a 16px header row (DAT_1011d970). Block heights are rounded up to the
# 16px grid. Vertical advance between stacked blocks is therefore h + 11.

const MARGIN := 6.0
const BORDER := 4.0
const BLOCK_GAP := 3.0
const HDR_H := 16.0
const MFD_SIZE := Vector2(128, 176)   # DAT_1011e238 / DAT_1011e23c
const PANEL_W := 112.0                # DAT_1011e10c (shields), DAT_1011e2f8 (weapons)
const ROW_PITCH := 32.0               # DAT_1011e110 / DAT_1011e2fc
const BAR_LEN := 74.0                 # PANEL_W - DAT_1011e140 (38)
const BAR_SEGS := 14                  # floor(74 / 5); bar style 1 has a 5px pitch
const BAR_PITCH := 5.0

func _left_x() -> float:
	return MARGIN + 2.0 * BORDER

func _right_x(w: float) -> float:
	return _screen().x - MARGIN - 2.0 * BORDER - w

func _advance(y: float, h: float) -> float:
	return y + h + 2.0 * BORDER + BLOCK_GAP

func _panel(pos: Vector2, size: Vector2, title: String) -> void:
	# glossy chrome: dark glass body with a subtle top sheen, bright header
	draw_rect(Rect2(pos + Vector2(0, HDR_H), size - Vector2(0, HDR_H)),
			Color(0.0, 0.05, 0.0, 0.62))
	draw_rect(Rect2(pos + Vector2(1, HDR_H + 1), Vector2(size.x - 2, 10)),
			Color(0.5, 1.0, 0.6, 0.05))
	draw_rect(Rect2(pos, Vector2(size.x, HDR_H)), GREEN_PANEL)
	draw_rect(Rect2(pos, Vector2(size.x, 5)), Color(0.7, 1.0, 0.75, 0.25))
	draw_string(_font, pos + Vector2(3, 12), title,
			HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE - 2, Color(0, 0, 0, 0.9))
	draw_rect(Rect2(pos, size), GREEN_DIM, false, 1.0)
	draw_rect(Rect2(pos - Vector2(1, 1), size + Vector2(2, 2)),
			Color(GREEN.r, GREEN.g, GREEN.b, 0.12), false, 1.0)

func _bar(pos: Vector2, frac: float, col: Color) -> void:
	# FUN_100ebde0 with bar style 1: BAR_SEGS blocks on a BAR_PITCH grid, and the
	# segment straddling the fill boundary fades by the remainder rather than
	# snapping on.
	var f := clampf(frac, 0.0, 1.0)
	var lit := f * BAR_SEGS
	for i in BAR_SEGS:
		var r := Rect2(pos + Vector2(i * BAR_PITCH, 0), Vector2(BAR_PITCH - 1.0, 8))
		var a := clampf(lit - float(i), 0.0, 1.0)
		if a > 0.0:
			draw_rect(r, Color(col.r, col.g, col.b, col.a * maxf(a, 0.35)))
		else:
			draw_rect(r, Color(col.r, col.g, col.b, 0.15))

func _contact_color(hostile: bool, category: String) -> Color:
	# FUN_100e8530, the one place the engine picks a contact's colour -- the
	# brackets, the contact list and the orb all just copy what it wrote.
	# Waypoints and L-points are chartreuse; everything else goes through an IFF
	# table where hostile is red, the default (neutral) is gold and friendly is
	# blue. We have no friendly flag yet, so non-hostiles read gold.
	if hostile:
		return RED
	if category == "lpoint" or category == "waypoint":
		return GREEN
	return GOLD

func _health_color(frac: float) -> Color:
	# FUN_100e88c0: a three-stop ramp with breaks at 0.75 and 0.25. The engine
	# LERPs between the stops but the decompiler lost the blend operands, so the
	# endpoints below are the palette entries the ramp names; the interpolation
	# is ours.
	var f := clampf(frac, 0.0, 1.0)
	if f > HEALTH_HI:
		return GOLD.lerp(GREEN, (f - HEALTH_HI) / (1.0 - HEALTH_HI))
	if f > HEALTH_LO:
		return RED.lerp(GOLD, (f - HEALTH_LO) / (HEALTH_HI - HEALTH_LO))
	return RED

func _fmt_range(d: float) -> String:
	# FUN_100f81a0, the reticle's range formatter: metres below 1 km, "%.1fkm"
	# below 1000 km, comma-grouped kilometres above that.
	if d < 1000.0:
		return "%dm" % int(d)
	if d * 0.001 < 1000.0:
		return "%.1fkm" % (d * 0.001)
	var km := "%d" % int(d * 0.001)
	var out := ""
	for i in km.length():
		if i > 0 and (km.length() - i) % 3 == 0:
			out += ","
		out += km[i]
	return out + "km"

# --- center reticle ---------------------------------------------------------

func _draw_reticle(c: Vector2) -> void:
	var in_lds: bool = main.lds_state == 2
	var ring := LDS_COL if in_lds else GREEN
	# The original's ring is a texture (images/hud/reticle.png, sprite 90) drawn
	# at RET_R: a thin circle with long ticks on the diagonals and short ticks
	# every 15 degrees. Redrawn here as vectors at the same radius.
	draw_arc(c, RET_R, 0, TAU, 96, ring, 1.4, true)
	for i in 24:
		var a := TAU * i / 24.0
		var dir := Vector2(sin(a), -cos(a))
		var inner := RET_R - (7.0 if i % 6 == 0 else 4.0)
		draw_line(c + dir * inner, c + dir * RET_R, ring, 1.4, true)
	draw_line(c + Vector2(-5, 0), c + Vector2(5, 0), ring, 1.0, true)
	draw_line(c + Vector2(0, -5), c + Vector2(0, 5), ring, 1.0, true)
	# own hull, as the filled arc the original sweeps behind the ring
	# (FUN_100f73d0, alpha 0.65 from _DAT_10119b40)
	var frac: float = clampf(main.hull / main.hull_max, 0.0, 1.0)
	var hull_col := _health_color(frac)
	draw_arc(c, RET_R + 5.0, -PI / 2.0, -PI / 2.0 + TAU * frac, 64,
			Color(hull_col.r, hull_col.g, hull_col.b, 0.65), 2.5, true)
	# own speed, left of the reticle ("+325m/s")
	var vel: float = main.ship.forward_speed()
	var vel_text: String = ("%s/s" % _fmt_range(absf(vel))) if in_lds \
		else "%s%dm/s" % ["-" if vel < 0 else "+", absi(int(absf(vel)))]
	var vw := _font_num.get_string_size(vel_text, HORIZONTAL_ALIGNMENT_LEFT,
			-1, num_size).x
	draw_string(_font_num, c + Vector2(-TEXT_X - vw, 4), vel_text,
			HORIZONTAL_ALIGNMENT_LEFT, -1, num_size, ring)
	if main.ship.set_speed > 0.5:
		var st := "set %d" % int(main.ship.set_speed)
		var sw2 := _font_num.get_string_size(st, HORIZONTAL_ALIGNMENT_LEFT,
				-1, num_size).x
		draw_string(_font_num, c + Vector2(-TEXT_X - sw2, 4 + num_size + 2), st,
				HORIZONTAL_ALIGNMENT_LEFT, -1, num_size,
				Color(ring.r, ring.g, ring.b, 0.55))
	_draw_target_block(c)
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

func _icon_pos(deg: float, radius: float) -> Vector2:
	# FUN_100f93c0: x = floor(sin(a) * r), y = floor(-cos(a) * r) -- angles run
	# clockwise from twelve o'clock.
	var a := deg_to_rad(deg)
	return Vector2(floor(sin(a) * radius), floor(-cos(a) * radius))

# --- the sprite primitives (FUN_100e9de0 / FUN_100ea2b0) --------------------

func _spr(pos: Vector2, id: int, col: Color, rot := 0.0) -> void:
	# FUN_100e9de0(x, y, sprite, flags, rotation). The quad spans
	# [-origin, size - origin] about the anchor and is drawn at NATIVE atlas
	# size -- the engine never scales these.
	if _sprites == null or not SPR.has(id):
		return
	var s: Array = SPR[id]
	var w := float(s[2])
	var h := float(s[3])
	var off := Vector2(-float(s[4]), -float(s[5]))
	var src := Rect2(float(s[0]), float(s[1]), w, h)
	if is_zero_approx(rot):
		draw_texture_rect_region(_sprites, Rect2(pos + off, Vector2(w, h)), src, col)
		return
	draw_set_transform(pos, rot, Vector2.ONE)
	draw_texture_rect_region(_sprites, Rect2(off, Vector2(w, h)), src, col)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

func _icon(pos: Vector2, id: int, flags: int, col: Color, charge := 0.0) -> void:
	# FUN_100ea2b0 (the roundel + its animation) followed by the charge ring
	# from FUN_100f8da0.
	var t: float = Time.get_ticks_msec() / 1000.0
	var a := col.a
	if flags & ICON_PULSE:
		a *= absf(fposmod(t * 0.5, 1.0) - 0.5) * 1.8 + 0.1
	var c := Color(col.r, col.g, col.b, a)
	var base := 0
	if (flags & ICON_ROUNDEL) and (flags & ICON_RING):
		base = 53
	elif flags & ICON_ROUNDEL:
		base = 51
	elif flags & ICON_RING:
		base = 52
	if base != 0:
		_spr(pos, base, c)
	if flags & ICON_SWEEP:
		_spr(pos, 50, c, -TAU * fposmod(t, 1.0))
	_spr(pos, id, c)
	if charge <= 0.0:
		return
	# ICON_PIPS pips on a circle of ICON_PIP_R; floor(charge * 24) are lit and
	# the next one is faded by the remainder (skipped below 0.05).
	var f: float = clampf(charge, 0.0, 1.0) * ICON_PIPS
	var lit := int(floor(f))
	for i in mini(lit, ICON_PIPS):
		var ang := TAU * i / float(ICON_PIPS)
		_spr(pos + Vector2(sin(ang), -cos(ang)) * ICON_PIP_R, 20, col)
	var rem := f - float(lit)
	if rem > 0.05 and lit < ICON_PIPS:
		var ang2 := TAU * lit / float(ICON_PIPS)
		_spr(pos + Vector2(sin(ang2), -cos(ang2)) * ICON_PIP_R, 20,
				Color(col.r, col.g, col.b, col.a * rem))

func _draw_target_block(c: Vector2) -> void:
	# FUN_100f7e10: to the right of the reticle at TEXT_X, a vertical segmented
	# hull bar spanning two text lines, then the lines themselves:
	#   "<hull%> <NAME>" / "<range>" / "<speed>m/s"
	var tdist: float = main._target_distance()
	if tdist == INF:
		return
	var col := _target_color()
	var lh := float(num_size) + 3.0
	var top := c.y - lh
	var tname := ""
	var thull := -1.0
	if main.target_ai != null and is_instance_valid(main.target_ai):
		tname = str(main.target_ai.display_name).to_upper()
		thull = clampf(main.target_ai.hull / main.target_ai.hull_max, 0.0, 1.0)
	elif main.target_idx >= 0:
		tname = str(main.objects[main.target_idx]["name"]).to_upper()
	if thull >= 0.0:
		_vbar(Vector2(c.x + TEXT_X, top), lh * 2.0, thull, _health_color(thull))
	var tx := c.x + TEXT_X + TEXT_GAP
	var head := tname
	if thull >= 0.0:
		head = "%d %s" % [int(round(thull * 100.0)), tname]
	draw_string(_font_num, Vector2(tx, top + lh - 3.0), head,
			HORIZONTAL_ALIGNMENT_LEFT, -1, num_size, col)
	draw_string(_font_num, Vector2(tx, top + lh * 2.0 - 3.0), _fmt_range(tdist),
			HORIZONTAL_ALIGNMENT_LEFT, -1, num_size, col)
	var tvel := Vector3.ZERO
	if main.target_ai != null and is_instance_valid(main.target_ai):
		tvel = main.target_ai.velocity
	var spd := tvel.length()
	if spd > 0.0:
		draw_string(_font_num, Vector2(tx, top + lh * 3.0 - 3.0),
				"%dm/s" % int(spd), HORIZONTAL_ALIGNMENT_LEFT, -1, num_size,
				Color(col.r, col.g, col.b, 0.7))
	_reticle_turn_arrow(c)

func _vbar(pos: Vector2, height: float, frac: float, col: Color,
		segments := 8) -> void:
	# the original's bars are stacks of lit/unlit blocks, filling upward
	var seg_h := height / segments
	for i in segments:
		var r := Rect2(pos + Vector2(0, height - (i + 1) * seg_h),
				Vector2(5.0, seg_h - 1.0))
		if float(i) / segments < frac:
			draw_rect(r, col)
		else:
			draw_rect(r, Color(col.r, col.g, col.b, 0.15))

func _reticle_turn_arrow(c: Vector2) -> void:
	# when the target is outside the reticle, an arrow inside the ring shows
	# which way to turn (manual, HUD section)
	var world: Vector3 = main._target_pos()
	var cam: Camera3D = main.cam
	var col := _target_color()
	var behind := cam.is_position_behind(world)
	var p := Vector2.INF if behind else cam.unproject_position(world)
	# FUN_100f6340 switches to the off-reticle indicator once the target sits
	# further than RET_R + RET_SLOP from the centre.
	if not behind and p.distance_to(c) < RET_R + RET_SLOP:
		return
	var local: Vector3 = cam.global_transform.affine_inverse() * world
	var dir2 := Vector2(local.x, -local.y)
	if dir2.length() < 0.001:
		return
	dir2 = dir2.normalized()
	_tri(c + dir2 * (RET_R - 18.0), dir2.angle(), col, 7.0)

func _target_color() -> Color:
	if main.target_ai != null and is_instance_valid(main.target_ai):
		return RED if main.target_ai.behavior == "attack" else BLUE
	if main.target_idx >= 0:
		var t: Dictionary = main.objects[main.target_idx]
		return GREEN if t["category"] == "lpoint" else YELLOW
	return YELLOW

# @element icHUDReticle
#
# The status-icon ring. The icHUDReticle constructor (FUN_100f5a90) lays down
# fifteen icon records via FUN_100f93c0(angle_in_half_turns, radius_delta,
# sprite, colour, flags); the draw (FUN_100f8410) decides which are visible and
# may swap the sprite, the colour and the flags. Every value below -- angle,
# radius, sprite id, colour, flag bits -- is that constructor's, verbatim:
#
#  slot  angle   r    sprite  colour  flags  meaning
#   0-3  -22.5 ..     0x15..  amber    11    the four mutually-exclusive
#        -56.25 150   0x18                   autopilot mode icons
#    4  -22.5   110   0x19    green    11/13 LDS drive; becomes 0x1A ("!") when
#                                            the drive is inhibited or disrupted
#    5  -67.5   110   0x1B    amber    13    a ship system is down
#    6  +22.5   110   0x1E    green    11/13 capsule drive / L-point jump
#    7  180     110   0x3E    amber     9    thermometer gauge
#    8  157.5   110   0x3F    amber     9    lightning gauge
#    9  135     110   0x40    amber     9    bulb gauge
#   10  +67.5   110   0x4E    red       9    incoming missile
#  11-14 202.5/225    0x56..  green   9/13   multiplayer team / flag / bomb
#
# Slots 0-3 are indexed by the table at DAT_1011e04c = [-1, 1, 0, 3, 2]: the
# pilot's mode 0 lights none, mode 1 lights slot 1, mode 2 lights slot 0, and so
# on. Our `ap_mode` (0 off, 1 approach, 2 formate, 3 dock, 4 match) has the same
# arity and the same "0 = off" convention, so it drives them.
const AP_ICON := [-1, 1, 0, 3, 2]   # DAT_1011e04c
const GAUGE_HOLD := 2.0             # DAT_1011e03c: a gauge lingers 2 s after it
                                    # stops changing
var _gauge_last := [-1.0, -1.0, -1.0]
var _gauge_hold := [0.0, 0.0, 0.0]

func _draw_status_icons(c: Vector2) -> void:
	# --- slots 0-3: autopilot mode, r = 150, one at most ---------------------
	var lit: int = AP_ICON[clampi(main.ap_mode, 0, 4)]
	if lit >= 0:
		_icon(c + _icon_pos(-22.5 - 11.25 * lit, ICON_R_MODE), 0x15 + lit,
				ICON_ROUNDEL | ICON_SWEEP | ICON_RING, AMBER)

	# --- slot 4: the LDS drive, r = 110 --------------------------------------
	# FUN_100f8410: while the drive is neither inhibited (ship+0x251) nor in
	# state 3, state 1 (warming up) shows the drive glyph with the warm-up as a
	# charge ring and state 2 (running) shows it bare. Otherwise the glyph
	# becomes "!" and the ring shows how hard the inhibition is -- 1 - d/r inside
	# an inhibitor's field, or the disrupt countdown after an LDSi hit. The draw
	# never touches the colour, so the "!" is GREEN, not red.
	var inhibited: bool = main.disrupt_time > 0.0 \
		or (main._lds_clearance() < 0.0 and main.docked_at == "")
	var lds_p := c + _icon_pos(-22.5, ICON_R)
	if inhibited:
		_icon(lds_p, 0x1A, ICON_ROUNDEL | ICON_PULSE | ICON_RING, GREEN,
				main.inhibit_charge())
	elif main.lds_state == 1:
		_icon(lds_p, 0x19, ICON_ROUNDEL | ICON_PULSE | ICON_RING, GREEN,
				clampf(main.lds_timer / main.LDS_SPOOL, 0.0, 1.0))
	elif main.lds_state == 2:
		_icon(lds_p, 0x19, ICON_ROUNDEL | ICON_SWEEP | ICON_RING, GREEN)

	# --- slot 5: a ship system is down, r = 110 ------------------------------
	# The draw walks the ship's components and lights sprite 0x1B if any is
	# non-functional. (The 0x1C / 0x1D branch keys off the drive controller's
	# state; see docs/original.md -- not resolved, so not drawn.)
	for state: float in main.system_states().values():
		if state >= 0.0 and state <= 0.0:
			_icon(c + _icon_pos(-67.5, ICON_R), 0x1B,
					ICON_ROUNDEL | ICON_PULSE | ICON_RING, AMBER)
			break

	# --- slot 6: capsule drive / L-point jump, r = 110 -----------------------
	var cap_p := c + _icon_pos(22.5, ICON_R)
	if main.jump_state == 1:
		_icon(cap_p, 0x1E, ICON_ROUNDEL | ICON_PULSE | ICON_RING, GREEN,
				clampf(main.jump_timer / 3.0, 0.0, 1.0))
	elif main.jump_state >= 2:
		_icon(cap_p, 0x1E, ICON_ROUNDEL | ICON_PULSE | ICON_RING, GREEN, 1.0)
	elif main.target_idx >= 0 \
			and main.objects[main.target_idx]["category"] == "lpoint" \
			and main._target_distance() < LPOINT_LABEL_RANGE:
		# ... and, within 50 km of a targeted L-point that has a destination, the
		# draw writes the destination's name beside the icon at (+24, -line).
		_icon(cap_p, 0x1E, ICON_ROUNDEL | ICON_PULSE | ICON_RING, GREEN)
		var jumps: Array = main.objects[main.target_idx].get("jumps", [])
		if not jumps.is_empty():
			draw_string(_font_num, cap_p + Vector2(ICON_PIPS, -float(num_size)),
					str(jumps[0]).replace("_", " ").to_upper(),
					HORIZONTAL_ALIGNMENT_LEFT, -1, num_size, GREEN)

	# --- slots 7-9: the three gauges, at 180 / 157.5 / 135 -------------------
	# Each is a {value, flag} pair on icPlayerPilot (+0xe8, stride 8). The icon
	# appears whenever the value CHANGES, holds GAUGE_HOLD seconds after it
	# settles, and shows the value as a charge ring: amber + flags 9 normally,
	# red + flags 13 when the flag is set. Only the thermometer has a source we
	# can honestly drive; what the lightning and bulb gauges measure is UNKNOWN.
	_gauge(c, 0, 0x3E, 180.0, main.ship_heat(), main.ship_heat() >= 1.0)

	# Slot 10 (incoming missile, sprite 0x4E) has no source in our sim -- no
	# missile ever locks the player -- so it never lights. Slots 11-14 are the
	# multiplayer team / flag / bomb markers and are dead in the campaign.

func _gauge(c: Vector2, idx: int, sprite: int, deg: float, value: float,
		flagged: bool) -> void:
	var dt: float = get_process_delta_time()
	if not is_equal_approx(value, float(_gauge_last[idx])) or flagged:
		_gauge_last[idx] = value
		_gauge_hold[idx] = GAUGE_HOLD
	elif _gauge_hold[idx] > 0.0:
		_gauge_hold[idx] = float(_gauge_hold[idx]) - dt
	if _gauge_hold[idx] <= 0.0:
		return
	var flags := ICON_ROUNDEL | ICON_PULSE | ICON_RING if flagged \
			else ICON_ROUNDEL | ICON_RING
	_icon(c + _icon_pos(deg, ICON_R), sprite, flags, RED if flagged else AMBER,
			clampf(value, 0.0, 1.0))

func _tri(p: Vector2, a: float, col: Color, size := 7.0) -> void:
	var d := Vector2(cos(a), sin(a))
	var perp := Vector2(-d.y, d.x)
	draw_colored_polygon(PackedVector2Array([
		p + d * size, p - d * size * 0.6 + perp * size * 0.7,
		p - d * size * 0.6 - perp * size * 0.7]), col)

# --- icHUDMenuReticle --------------------------------------------------------
# @element icHUDMenuReticle
#
# The arrow-key HUD menu. Every menu node is a 0x2c-byte record whose four
# direction links sit at +0x14 / +0x18 / +0x1c / +0x20; the draw
# (FUN_100f1d60, which Ghidra left undisassembled) proves the order by pulling
# a per-direction offset out of a table it builds at 0x100f1bf0:
#
#     +0x14 UP    (  0, -100)      +0x1c LEFT  (-100, 0)
#     +0x18 DOWN  (  0, +100)      +0x20 RIGHT (+100, 0)
#
# 100 = _DAT_1011dec0 (80) + _DAT_101190b0 (20). Node +0x10 is the enabled byte
# that ihud.SetMenuNodeEnabled writes; icHUD+0x1b6 is ihud.LockMenu's flag.
#
# The tree below is the one FUN_100df640 builds, link for link. The names are
# the hud.csv keys the engine passes to FcString, which is exactly what
# ihud.CurrentMenuNode hands back to the POG scripts.
const MENU_R := 100.0
const MENU_TIMEOUT := 30.0    # flux.ini [icHUD] menu_timeout
const MENU_ROOT := "hud_menu_menu"

# name -> {label, up, down, left, right, kind}
# kind: "" submenu, "screen", "cmd", "toggle", "carousel"
const MENU := {
	"hud_menu_menu": {"label": "MENU",
		"up": "hud_menu_eng", "down": "hud_menu_cmd",
		"left": "hud_menu_nav", "right": "hud_menu_wep"},
	"hud_menu_nav": {"label": "NAV", "right": "hud_menu_menu",
		"up": "hud_menu_map", "left": "hud_menu_autopilot",
		"down": "hud_menu_undock"},
	"hud_menu_wep": {"label": "WEP", "left": "hud_menu_menu",
		"up": "hud_menu_zoom", "down": "hud_menu_aim_assist",
		"right": "hud_menu_fire_mode"},
	"hud_menu_cmd": {"label": "CMD", "up": "hud_menu_menu",
		"left": "hud_menu_doc", "right": "hud_menu_remote_link",
		"down": "hud_menu_comms"},
	# "hud_menu_doc" has no hud.csv entry -- the label is ours.
	"hud_menu_doc": {"label": "DOC", "right": "hud_menu_cmd",
		"up": "hud_menu_log", "left": "hud_menu_objectives",
		"down": "hud_menu_score_table"},
	"hud_menu_comms": {"label": "COMMS", "up": "hud_menu_cmd",
		"right": "hud_menu_wingmen", "left": "hud_menu_tfighters",
		"down": "hud_menu_call_jafs"},
	# the five icHUD elements that register themselves as menu nodes
	"hud_menu_eng": {"label": "ENG", "kind": "screen", "down": "hud_menu_menu"},
	"hud_menu_map": {"label": "STARMAP", "kind": "screen", "down": "hud_menu_nav"},
	"hud_menu_log": {"label": "LOG", "kind": "screen", "down": "hud_menu_doc"},
	"hud_menu_objectives": {"label": "OBJECTIVES", "kind": "screen",
		"right": "hud_menu_doc"},
	"hud_menu_score_table": {"label": "STATISTICS", "kind": "screen",
		"up": "hud_menu_doc"},
	# commands and toggles
	"hud_menu_undock": {"label": "UNDOCK", "kind": "cmd", "up": "hud_menu_nav"},
	"hud_menu_zoom": {"label": "ZOOM IN", "kind": "toggle",
		"down": "hud_menu_wep"},
	"hud_menu_aim_assist": {"label": "TOGGLE AIM ASSIST", "kind": "toggle",
		"up": "hud_menu_wep"},
	"hud_menu_fire_mode": {"label": "TOGGLE FIRE MODE", "kind": "toggle",
		"left": "hud_menu_wep"},
	"hud_menu_remote_link": {"label": "REM LINK", "kind": "toggle",
		"left": "hud_menu_cmd"},
	"hud_menu_call_jafs": {"label": "CALL JAFS", "kind": "cmd",
		"up": "hud_menu_comms"},
	# The three dynamic nodes. Each really holds a PREV / NEXT pair plus a list
	# of commands (FUN_100efe50 / FUN_100f0560 / FUN_100f0c40 build them into
	# private slots, not into the four direction links), so left/right step the
	# list. WHICH direction is prev and which is next was not recovered.
	"hud_menu_autopilot": {"label": "AUTOPILOT", "kind": "carousel",
		"right": "hud_menu_nav",
		"items": ["APPROACH", "FORMATE", "PURSUIT", "DOCK", "DISENGAGE"]},
	"hud_menu_wingmen": {"label": "WINGMEN", "kind": "carousel",
		"left": "hud_menu_comms",
		"items": ["REPORT IN", "PROTECT ME", "ATTACK MY TARGET",
			"PROTECT MY TARGET", "DOCK WITH MY TARGET"]},
	"hud_menu_tfighters": {"label": "T-FIGHTERS", "kind": "carousel",
		"right": "hud_menu_comms",
		"items": ["ATTACH/DETACH", "ATTACK MY TARGET", "WEAPONS FREE",
			"WEAPONS HOLD"]},
}
const MENU_DIRS := ["up", "down", "left", "right"]
const MENU_OFF := {"up": Vector2(0, -MENU_R), "down": Vector2(0, MENU_R),
	"left": Vector2(-MENU_R, 0), "right": Vector2(MENU_R, 0)}

var menu_active := false
var menu_focus := MENU_ROOT
var menu_time := 0.0            # icHUD+0x1b8, counts down; the timeout is shown
                                # only below 10 s (_DAT_101190c0)
var menu_locked := false        # icHUD+0x1b6, ihud.LockMenu
var menu_disabled := {}         # node name -> true; ihud.SetMenuNodeEnabled
var menu_carousel := {}         # carousel node -> selected index
var screen := ""                # the open full-screen HUD element, "" for none
var screens: HudScreens
var _menu_spin := 0.0

func menu_node_name() -> String:
	# ihud.CurrentMenuNode (IHUDMenuFocusName, 0x100f5040): the open screen's
	# name if one is up, otherwise the focused node's.
	if screen != "":
		return screen
	return menu_focus if menu_active else ""

func menu_enabled(name: String) -> bool:
	return not menu_disabled.get(name, false)

func _menu_link(name: String, dir: String) -> String:
	var node: Dictionary = MENU.get(name, {})
	var to: String = str(node.get(dir, ""))
	return to if to != "" and menu_enabled(to) else ""

func _menu_open(name: String) -> void:
	var node: Dictionary = MENU.get(name, {})
	if str(node.get("kind", "")) == "screen":
		screen = name
		menu_active = false
		return
	menu_focus = name
	menu_time = MENU_TIMEOUT

func _menu_process(dt: float) -> void:
	if not menu_active:
		return
	menu_time -= dt
	if menu_time <= 0.0:
		menu_active = false
		menu_focus = MENU_ROOT

func _unhandled_input(e: InputEvent) -> void:
	if main == null or main.ship == null:
		return
	if main.menu != null and main.menu.visible:
		return
	if not (e is InputEventKey and e.pressed and not e.echo):
		return
	var key: int = (e as InputEventKey).physical_keycode
	# configs/default.ini [HUD.Objectives|Starmap|Log|Engineering|Statistics]
	if (e as InputEventKey).shift_pressed:
		var direct := {KEY_O: "hud_menu_objectives", KEY_M: "hud_menu_map",
			KEY_L: "hud_menu_log", KEY_E: "hud_menu_eng",
			KEY_S: "hud_menu_score_table"}
		if direct.has(key):
			screen = "" if screen == direct[key] else str(direct[key])
			menu_active = false
			get_viewport().set_input_as_handled()
		return
	if screen != "":
		# a screen is up: Backspace / Escape closes it, the rest is the screen's
		if key in [KEY_BACKSPACE, KEY_ESCAPE]:
			screen = ""
			get_viewport().set_input_as_handled()
		elif screens != null and screens.handle_key(key):
			get_viewport().set_input_as_handled()
		return
	if menu_locked:
		return
	var dir := ""
	match key:
		KEY_UP: dir = "up"
		KEY_DOWN: dir = "down"
		KEY_LEFT: dir = "left"
		KEY_RIGHT: dir = "right"
		KEY_BACKSPACE:  # [HUD.MenuCancel]
			if menu_active:
				menu_active = false
				menu_focus = MENU_ROOT
				get_viewport().set_input_as_handled()
			return
		KEY_ENTER, KEY_KP_ENTER:  # [HUD.MenuSelect]
			if menu_active:
				_menu_select()
				get_viewport().set_input_as_handled()
			return
		_:
			return
	get_viewport().set_input_as_handled()
	if not menu_active:
		# any arrow wakes the menu at the root
		menu_active = true
		menu_focus = MENU_ROOT
		menu_time = MENU_TIMEOUT
		return
	menu_time = MENU_TIMEOUT
	var node: Dictionary = MENU.get(menu_focus, {})
	if str(node.get("kind", "")) == "carousel" and dir in ["left", "right"]:
		var items: Array = node.get("items", [])
		var i: int = int(menu_carousel.get(menu_focus, 0))
		if not items.is_empty():
			menu_carousel[menu_focus] = wrapi(i + (1 if dir == "right" else -1),
					0, items.size())
		return
	var to := _menu_link(menu_focus, dir)
	if to != "":
		_menu_open(to)
	else:
		main.audio.play("audio/hud/invalid_input.wav", -8.0)

func _menu_select() -> void:
	var node: Dictionary = MENU.get(menu_focus, {})
	var kind := str(node.get("kind", ""))
	main.audio.play("audio/hud/valid_input.wav", -8.0)
	match menu_focus:
		"hud_menu_undock":
			main._undock()
		"hud_menu_zoom":
			main.zoomed = not main.zoomed
		"hud_menu_aim_assist":
			main.free_toggle = not main.free_toggle
		"hud_menu_autopilot":
			var i: int = int(menu_carousel.get(menu_focus, 0))
			# APPROACH / FORMATE / PURSUIT / DOCK / DISENGAGE -> main.ap_mode
			main.ap_mode = [1, 2, 0, 3, 0][i]
	if kind in ["cmd", "toggle", "carousel"]:
		menu_active = false
		menu_focus = MENU_ROOT

func _spr_ret(pos: Vector2, id: int, col: Color, rot := 0.0) -> void:
	if _reticle_tex == null or not SPR_RET.has(id):
		return
	var s: Array = SPR_RET[id]
	var sz := Vector2(float(s[2]), float(s[3]))
	var off := Vector2(-float(s[4]), -float(s[5]))
	var src := Rect2(float(s[0]), float(s[1]), sz.x, sz.y)
	draw_set_transform(pos, rot, Vector2.ONE)
	draw_texture_rect_region(_reticle_tex, Rect2(off, sz), src, col)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

func _draw_menu_reticle(c: Vector2) -> void:
	if not menu_active:
		return
	# the centre: one static quadrant (sprite 91) plus four copies of sprite 93
	# stepped by PI/2 (_DAT_1011a454), spinning together
	_spr_ret(c, 91, GREEN)
	for i in 4:
		_spr_ret(c, 93, GREEN, _menu_spin + PI / 2.0 * i)
	var node: Dictionary = MENU.get(menu_focus, {})
	var head := str(node.get("label", menu_focus))
	if str(node.get("kind", "")) == "carousel":
		var items: Array = node.get("items", [])
		var i: int = int(menu_carousel.get(menu_focus, 0))
		if not items.is_empty():
			head = "%s: %s" % [head, items[i]]
	_menu_label(c, head, GREEN)
	if menu_time < 10.0:  # _DAT_101190c0
		_menu_label(c + Vector2(0, 30), "TIME: %d" % int(ceil(menu_time)), AMBER)
	for dir in MENU_DIRS:
		var to := _menu_link(menu_focus, dir)
		if to == "":
			continue
		var col := AMBER if str(MENU[to].get("kind", "")) == "screen" else GREEN
		_menu_label(c + MENU_OFF[dir], str(MENU[to]["label"]), col)

func _menu_label(p: Vector2, text: String, col: Color) -> void:
	var w := _font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1,
			FONT_SIZE).x
	draw_string(_font, p - Vector2(w / 2.0, -float(FONT_SIZE) / 2.0), text,
			HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE, col)

# --- world-space target marks -----------------------------------------------
# @element icHUDBrackets
#   Draw = FUN_100e37f0. Corner brackets on the projected bounding box, the
#   target's slam-in, and the waypoint / L-point / unidentified marks.
# @element-stub icHUDContrails
#   flux.ini lists it between Brackets and the TargetMFD; it streaks the
#   velocity trails of nearby contacts. Not built -- its Draw was not reversed
#   and inventing the trail geometry would be a guess.

const BRK_ACQUIRE := 0.35   # DAT_1011d9dc: target-acquire animation length
const BRK_SLAM := 70.0      # DAT_1011d9e0: how far outside the bracket starts
const BRK_MIN := 2.0        # _DAT_10119ec8: bbox smaller than this collapses

var _brk_target := ""       # who the acquire animation is currently playing for
var _brk_t := 0.0

func _corner_bracket(bb: Rect2, col: Color, arm := 6.0, width := 1.4) -> void:
	# icHUDBrackets draws four corner sprites at the target's projected bounding
	# box, the same sprite mirrored into each corner.
	for sx in [0, 1]:
		for sy in [0, 1]:
			var p := bb.position + Vector2(bb.size.x * sx, bb.size.y * sy)
			var dx := arm if sx == 0 else -arm
			var dy := arm if sy == 0 else -arm
			draw_line(p, p + Vector2(dx, 0), col, width, true)
			draw_line(p, p + Vector2(0, dy), col, width, true)

func _bbox_of(world: Vector3, radius: float) -> Rect2:
	# project a contact to a screen-space box, with the engine's minimum-size
	# collapse when it is too small to bracket
	var cam: Camera3D = main.cam
	var p := cam.unproject_position(world)
	var edge := cam.unproject_position(
			world + cam.global_transform.basis.x * radius)
	var half := maxf(absf(edge.x - p.x), 3.0)
	if half * 2.0 < BRK_MIN:
		return Rect2(p.floor(), Vector2.ZERO)
	return Rect2((p - Vector2(half, half)).floor(), Vector2(half, half) * 2.0)

func _draw_target_marks() -> void:
	var cam: Camera3D = main.cam
	var screen := Rect2(Vector2.ZERO, _screen())
	# every on-screen contact gets a mark: a glyph for navigation points, corner
	# brackets for anything solid
	for i in main.objects.size():
		var o: Dictionary = main.objects[i]
		if o.get("sensor_hidden", false) or i == main.target_idx:
			continue
		var w := Vector3(o["x"] - main.px, o["y"] - main.py, o["z"] - main.pz)
		if cam.is_position_behind(w):
			continue
		var p := cam.unproject_position(w)
		if not screen.has_point(p):
			continue
		var col := _contact_color(false, str(o["category"]))
		if o["category"] == "lpoint":
			_diamond(p, 7.0, col)
		else:
			_corner_bracket(_bbox_of(w, 60.0), Color(col.r, col.g, col.b, 0.7))
	for a in main.ai_ships:
		if a == main.target_ai or cam.is_position_behind(a.global_position):
			continue
		var p := cam.unproject_position(a.global_position)
		if not screen.has_point(p):
			continue
		var col := _contact_color(a.behavior == "attack", "traffic")
		_corner_bracket(_bbox_of(a.global_position, 30.0),
				Color(col.r, col.g, col.b, 0.7))
	_draw_target_bracket()

func _draw_target_bracket() -> void:
	var world: Vector3
	var radius := 30.0
	var is_nav := false
	var key := ""
	if main.target_ai != null and is_instance_valid(main.target_ai):
		world = main.target_ai.global_position
		key = str(main.target_ai.get_instance_id())
	elif main.target_idx >= 0:
		var t: Dictionary = main.objects[main.target_idx]
		world = Vector3(t["x"] - main.px, t["y"] - main.py, t["z"] - main.pz)
		radius = 60.0
		is_nav = t["category"] == "lpoint"
		key = "o%d" % main.target_idx
	else:
		_brk_target = ""
		return
	# the acquire animation: brackets slam in from BRK_SLAM px outside over
	# BRK_ACQUIRE seconds, fading up as they close
	if key != _brk_target:
		_brk_target = key
		_brk_t = 0.0
	_brk_t = minf(_brk_t + get_process_delta_time(), BRK_ACQUIRE)
	var cam: Camera3D = main.cam
	if cam.is_position_behind(world):
		return
	var p := cam.unproject_position(world)
	if not Rect2(Vector2.ZERO, _screen()).has_point(p):
		return
	var col := _target_color()
	if is_nav:
		_diamond(p, 10.0, col)
		return
	var bb := _bbox_of(world, radius)
	_corner_bracket(bb, col, 8.0, 1.6)
	var t: float = _brk_t / BRK_ACQUIRE
	if t < 1.0:
		var d := (1.0 - t) * BRK_SLAM
		_corner_bracket(bb.grow(d), Color(col.r, col.g, col.b, t), 8.0, 1.6)
	# lead indicator for moving targets
	if main.target_ai != null and is_instance_valid(main.target_ai):
		var tvel: Vector3 = main.target_ai.velocity - main.ship.velocity
		var lead: Vector3 = world + tvel * (world.length() / 6000.0)
		if not cam.is_position_behind(lead):
			_diamond(cam.unproject_position(lead), 8.0, col)

func _diamond(p: Vector2, r: float, col: Color) -> void:
	draw_polyline(PackedVector2Array([p + Vector2(0, -r), p + Vector2(r, 0),
			p + Vector2(0, r), p + Vector2(-r, 0), p + Vector2(0, -r)]),
			col, 1.4, true)

# --- MFD (upper-left) -------------------------------------------------------
# @element icHUDTargetMFD
#   128x176 (DAT_1011e238 / DAT_1011e23c), left-anchored, chartreuse
#   wireframe, two amber text lines, typewriter reveal at 30 chars/sec.
# @element icHUDWeapons
#   112 wide (DAT_1011e2f8), 32*rows + 16 tall; the header is the weapon's
#   own localised name, uppercased.

func _draw_mfd() -> void:
	# icHUDTargetMFD: a 128x176 block in the top-left stack. The wireframe target
	# render fills the body in chartreuse; the two text lines sit at the bottom,
	# indented 32px, in amber -- line 1 the ship name, line 2 the owner/route.
	var r := _mfd_rect()
	var col := AMBER
	var tname := ""
	var ttype := ""
	if main.target_ai != null and is_instance_valid(main.target_ai):
		_panel(r.position, r.size, "TARGET LOCK")
		tname = str(main.target_ai.display_name)
		ttype = str(main.target_ai.ctype)
	elif main.target_idx >= 0:
		var t: Dictionary = main.objects[main.target_idx]
		_panel(r.position, r.size,
			"NAVIGATION LOCK" if t["category"] == "lpoint" else "TARGET LOCK")
		tname = str(t["name"])
		ttype = str(t.get("type", ""))
	else:
		_panel(r.position, r.size, "NO TARGET")
		target_view.enabled = false
		return
	# the wireframe feed occupies the block between the header and the text
	var feed := Rect2(r.position + Vector2(BORDER, HDR_H + 2),
			Vector2(r.size.x - 2.0 * BORDER, 110))
	var has_model := target_view.show_avatar(main.target_avatar())
	target_view.enabled = has_model
	if has_model:
		draw_texture_rect(target_view.get_texture(), feed, false)
	else:
		var center := feed.position + feed.size / 2.0
		var t := Time.get_ticks_msec() / 1000.0
		var basis := Basis(Vector3.UP, t * 0.6) * Basis(Vector3.RIGHT, 0.35)
		var ext := Vector3(26, 22, 26)
		var corners: Array = []
		for sx in [-1, 1]:
			for sy in [-1, 1]:
				for sz in [-1, 1]:
					var p3: Vector3 = basis * Vector3(sx * ext.x, sy * ext.y, sz * ext.z)
					corners.append(center + Vector2(p3.x, -p3.y * 0.8 + p3.z * 0.25))
		for e in [[0, 1], [0, 2], [1, 3], [2, 3], [4, 5], [4, 6], [5, 7], [6, 7],
				[0, 4], [1, 5], [2, 6], [3, 7]]:
			draw_line(corners[e[0]], corners[e[1]],
					Color(GREEN.r, GREEN.g, GREEN.b, 0.7), 1.0, true)
	var lh := float(FONT_SIZE) + 3.0
	var tx := r.position.x + 32.0
	draw_string(_font, Vector2(tx, r.position.y + r.size.y - BORDER - lh),
			tname.to_upper().left(14), HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE - 1,
			col)
	draw_string(_font, Vector2(tx, r.position.y + r.size.y - BORDER),
			ttype.to_upper().left(14), HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE - 2,
			Color(col.r, col.g, col.b, 0.7))

func _draw_weapon_panel() -> void:
	# icHUDWeapons: 112 wide, 16px header + 32px per weapon in the selected group.
	# Each row is a lightning sprite at x=16, a 14-segment charge bar at x=36
	# (length 74), and a "%d%%" readout. Header is the weapon's own name.
	var rows: int = 2 if "/" in str(main.weapon_name) else 1
	var pos := Vector2(_left_x(), _advance(MARGIN, MFD_SIZE.y))
	var size := Vector2(PANEL_W, ROW_PITCH * rows + HDR_H)
	_panel(pos, size, str(main.weapon_name).to_upper())
	var charge: float = 1.0
	if main.weapons != null:
		charge = 1.0 - main.weapons.cooldown / main.weapons.refire
	for i in rows:
		var ry := pos.y + HDR_H + i * ROW_PITCH
		var lp := Vector2(pos.x + 16, ry + 16)
		draw_colored_polygon(PackedVector2Array([
			lp + Vector2(3, -8), lp + Vector2(-4, 1), lp + Vector2(-1, 1),
			lp + Vector2(-3, 8), lp + Vector2(4, -1), lp + Vector2(1, -1)]), AMBER)
		_bar(Vector2(pos.x + 36, ry + 10), charge, AMBER)
		draw_string(_font, Vector2(pos.x + 36, ry + 28), "%d%%" % int(charge * 100),
				HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE - 2, AMBER)

# --- system status lights (top-center) --------------------------------------
# @element icHUDShipStatus
#   Draw = FUN_100fabd0 -> FUN_100fac60(screen_w * 0.5, 14.0): a horizontal
#   strip of per-component bars centred on the screen at y = 14, in
#   chartreuse (DAT_10176038). It enumerates the ship's component list
#   (icShip+0x138), i.e. one bar per subsim -- which is what this draws.

const SYSTEMS := ["DRV", "THR", "LDS", "CAP", "WEP", "SEN", "EPS", "CPU"]

func _draw_system_status() -> void:
	# Each cell is one mounted subsim group: the top bar is its condition, the
	# bottom its available power. These are the real subsims now (main.sys), not
	# a curve fitted to the hull -- a drive hit reads on DRV, not on everything.
	var s := _screen()
	var w := SYSTEMS.size() * 32.0
	var pos := Vector2(s.x / 2.0 - w / 2.0, 12)
	var states: Dictionary = main.system_states()
	var blink := int(Time.get_ticks_msec() / 300.0) % 2 == 0
	for i in SYSTEMS.size():
		var x := pos.x + i * 32.0
		var health: float = states.get(SYSTEMS[i], -1.0)
		if health < 0.0:
			# the hull mounts nothing of this kind: an empty socket, not a
			# healthy one
			draw_rect(Rect2(x, pos.y, 20, 7), GREEN_DIM, false, 1.0)
			draw_string(_font, Vector2(x, pos.y + 28), SYSTEMS[i],
					HORIZONTAL_ALIGNMENT_LEFT, -1, 8, Color(GREEN_DIM, 0.35))
			continue
		var dcol := _health_color(health)
		if health < 1.0 and blink:
			dcol = Color(dcol.r, dcol.g, dcol.b, 0.35)
		draw_rect(Rect2(x, pos.y, 20, 7), dcol)
		draw_rect(Rect2(x, pos.y + 9, 20.0 * health, 7),
				Color(0.3, 0.5, 1.0, 0.9))
		draw_string(_font, Vector2(x, pos.y + 28), SYSTEMS[i],
				HORIZONTAL_ALIGNMENT_LEFT, -1, 8, GREEN_DIM)
	draw_rect(Rect2(pos - Vector2(6, 4), Vector2(w + 8, 24)), GREEN_DIM, false, 1.0)

# --- ORB (top-right) --------------------------------------------------------
# @element icHUDOrbRadar
#   flux.ini [icHUDOrbRadar] use_thick_stalks = 1.
# @element icHUDClock
#   Right-anchored under the shields; "%02d:%02d:%02d.%02d" (0x10162b24),
#   game time in centiseconds, chartreuse.

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
	# right-hand block stack: ORB, then the clock beneath it
	var size := Vector2(PANEL_W, 128.0)
	var pos := Vector2(_right_x(size.x), MARGIN)
	var contacts := _orb_contacts()
	var n := contacts.size()
	_panel(pos, size, "%d %s" % [n, "CONTACT" if n == 1 else "CONTACTS"])
	# graph-paper backdrop, like the original's ORB panel
	for gx in range(int(pos.x) + 8, int(pos.x + size.x) - 4, 12):
		draw_line(Vector2(gx, pos.y + 20), Vector2(gx, pos.y + size.y - 4),
				Color(GREEN.r, GREEN.g, GREEN.b, 0.07), 1.0)
	for gy in range(int(pos.y) + 24, int(pos.y + size.y) - 4, 12):
		draw_line(Vector2(pos.x + 4, gy), Vector2(pos.x + size.x - 4, gy),
				Color(GREEN.r, GREEN.g, GREEN.b, 0.07), 1.0)
	var c := pos + Vector2(size.x / 2.0, HDR_H + (size.y - HDR_H) / 2.0)
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
	_draw_clock(_advance(pos.y, size.y))

func _draw_clock(y: float) -> void:
	# icHUDClock (FUN_100e40f0): centiseconds since leaving port, formatted
	# "%02d:%02d:%02d.%02d" with hours wrapping at 100, right-aligned 2px inside
	# its block, in chartreuse -- not amber.
	var cs: int = (Time.get_ticks_msec() - main.clock_start) / 10
	var text := "%02d:%02d:%02d.%02d" % [(cs / 360000) % 100, (cs % 360000) / 6000,
			(cs % 6000) / 100, cs % 100]
	var w := _font_num.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1,
			num_size).x
	var x := _right_x(PANEL_W) + PANEL_W - 2.0 - w
	draw_string(_font_num, Vector2(x, y + 12), text, HORIZONTAL_ALIGNMENT_LEFT,
			-1, num_size, GREEN)

func _ellipse(c: Vector2, radii: Vector2, col: Color) -> void:
	var pts := PackedVector2Array()
	for i in 33:
		var a := TAU * i / 32.0
		pts.append(c + Vector2(cos(a) * radii.x, sin(a) * radii.y))
	draw_polyline(pts, col, 1.0, true)

# --- contact list (lower-right) ---------------------------------------------
# @element icHUDContactList
#   Draw = FUN_100e4440. Six rows, 16px pitch, sorted by range ascending.
# @element-stub icHUDShields
#   112 x (32 * bars + 16), right-anchored, header hud_shield_status. NOT
#   drawn: the component class its draw filters on (DAT_10167e5c) was never
#   resolved, and our sim mounts no shield components, so there is nothing
#   truthful to put in the panel.

const CL_ROWS := 6        # the list shows six rows and scrolls (FUN_100e4440)
const CL_ROW_H := 16.0    # DAT_1011d970

func _cl_range(d: float) -> String:
	# FUN_100e8730, the contact list's own range formatter -- deliberately not
	# the reticle's. The reference shot shows "7103m" here and "7.1km" in the
	# reticle for the same contact.
	if d >= 1e7:
		var e := int(floor(log(d * 0.001) / log(10.0)))
		return "%dE%dk" % [int(d * 0.001 / pow(10.0, e)), mini(e, 99)]
	if d >= 1e5:
		return "%dk" % int(d * 0.001)
	if d >= 1e4:
		var k := d * 0.001
		return "%d.%dk" % [int(k), int((k - floor(k)) * 10.0)]
	return "%dm" % int(d)

func _draw_contact_list() -> void:
	# icHUDContactList. The row is a monospace character grid, not pixel columns:
	#   "%-5s %-5s %-5s %-12.12s%c"   (faction, type, range, name, then '>' when
	# the name was cut, else a space). Type abbreviations are the space-padded
	# five-character forms from data/text/hud.csv ("UTIL ", "TRANS", "LAGPT");
	# faction abbreviations are the five-character column of faction_names.csv
	# and are blank for anything with no owner. Six rows, scrolling to keep the
	# selected contact in view, with a scrollbar once there are more than six.
	# There is no highlight box on the selected row -- it is drawn brighter and
	# its name scrolls rather than being truncated.
	var s := _screen()
	var all: Array = main.contact_list()
	if all.is_empty():
		return
	var sel := -1
	for i in all.size():
		if all[i]["targeted"]:
			sel = i
			break
	var off := 0
	if sel > CL_ROWS - 1:
		off = sel - (CL_ROWS - 1)
	off = mini(off, maxi(0, all.size() - CL_ROWS))
	var rows: Array = all.slice(off, off + CL_ROWS)
	var h := 8.0 + rows.size() * CL_ROW_H
	var w := 320.0
	var pos := Vector2(_right_x(w), s.y - h - MARGIN - 2.0 * BORDER)
	draw_rect(Rect2(pos, Vector2(w, h)), Color(0.0, 0.05, 0.0, 0.55))
	draw_rect(Rect2(pos, Vector2(w, h)),
			Color(GREEN.r, GREEN.g, GREEN.b, 0.25), false, 1.0)
	# scrollbar, only once the list overflows (alpha 0.3, _DAT_1011c034)
	if all.size() > CL_ROWS:
		var frac := float(CL_ROWS) / float(all.size())
		var track := h - 4.0
		var top := pos.y + 2.0 + track * (float(off) / float(all.size()))
		draw_rect(Rect2(pos.x + 2.0, top, 4.0, track * frac),
				Color(GREEN.r, GREEN.g, GREEN.b, 0.3))
	var y := pos.y + CL_ROW_H
	for entry in rows:
		var col := _contact_color(entry["hostile"], str(entry.get("category", "")))
		if not entry["targeted"]:
			col = Color(col.r, col.g, col.b, 0.75)
		var nm := str(entry["name"]).to_upper()
		var cut := " "
		if nm.length() > 12:
			nm = nm.left(12)
			cut = ">"
		# navigation contacts have no owner, so the faction column stays blank
		var cat := str(entry.get("category", ""))
		var fac := "" if cat == "lpoint" or cat == "waypoint" \
			else str(entry.get("faction", "")).to_upper()
		var line := "%-5.5s %-5.5s %-5.5s %-12s%s" % [
			fac, str(entry.get("type", "")).to_upper(),
			_cl_range(float(entry["dist"])), nm, cut]
		draw_string(_font_num, Vector2(pos.x + 10, y), line,
				HORIZONTAL_ALIGNMENT_LEFT, -1, num_size, col)
		y += CL_ROW_H

# --- messages ----------------------------------------------------------------
# @element icHUDMessage
#   flux.ini [icHUDMessage] message_delay 5, prompt_delay 10,
#   new_message_flash_frequency 0.333333, caution_flash_frequency 1.
# @element-stub icHUDDebug
#   The developer overlay (hud_debug_indestructible, "Running missions: ").
#   Deliberately not built.
# @element-stub icHUDEditBoxElement
#   The in-HUD text entry ihud.GiveEditBoxControl hands control to. No
#   campaign script ever calls it, so there is nothing to drive it.

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
