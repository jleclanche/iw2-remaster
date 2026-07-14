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
# FUN_100eb270's first argument is an index into the font table at 0x10162c60
# (stride 0x14). The four entries are, verbatim:
#   0 font:/fonts/ocrb_8pt   1 font:/fonts/ocrb_10pt
#   2 font:/fonts/ocrb_18pt  3 texture:/images/hud/sprites
# The menu reticle uses 1 for its node labels and 2 for the focused node's name.
var _font_menu: Font  # OCR-B 10pt -- font 1
var _font_head: Font  # OCR-B 18pt -- font 2
var menu_size := 10
var head_size := 18
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
	3: [51, 0, 16, 16, 7, 7],            # targeted-subsystem marker (MFD)
	16: [144, 0, 9, 11, 0, 9],           # icHUDShipStatus: ONE status lamp
	20: [68, 0, 11, 11, 5, 5],           # charge pip
	21: [0, 26, 32, 32, 16, 16],         # mode icon 1
	22: [33, 26, 32, 32, 16, 16],        # mode icon 2
	23: [99, 26, 32, 32, 16, 16],        # mode icon 3
	24: [66, 26, 32, 32, 16, 16],        # mode icon 4
	25: [132, 26, 32, 32, 16, 16],       # LDS drive (the striped capsule)
	26: [132, 92, 32, 32, 16, 16],       # "!"  -- LDS inhibited / disrupted
	27: [66, 125, 32, 32, 16, 16],       # power symbol -- a system is down
	28: [99, 125, 32, 32, 16, 16],       # 0x1C free-flight (capsule + circular arrow)
	29: [132, 125, 32, 32, 16, 16],      # 0x1D lateral thrust (capsule + side arrows)
	30: [165, 125, 32, 32, 16, 16],      # capsule drive / jump
	32: [198, 26, 32, 32, 16, 16],       # 0x20 menu carousel PREV
	33: [198, 92, 32, 32, 16, 16],       # 0x21 menu carousel NEXT
	40: [231, 26, 16, 32, 16, 16],       # 0x28 menu node box: the chevron end cap
	41: [248, 26, 4, 32, 0, 16],         # 0x29 menu node box: its top/bottom rails
	46: [99, 59, 32, 32, 16, 16],        # MFD class-icon overlay for 47/60
	47: [99, 92, 32, 32, 16, 16],        # waypoint class icon
	48: [0, 59, 32, 32, 16, 16],         # MFD class-icon overlay for 49
	49: [0, 92, 32, 32, 16, 16],         # unidentified-contact class icon
	50: [132, 59, 32, 32, 16, 16],       # rotating sweep wedge (flag bit 1)
	51: [165, 92, 32, 32, 16, 16],       # roundel: soft disc (also under the MFD class icon)
	52: [165, 59, 32, 32, 16, 16],       # roundel: ring
	53: [198, 59, 32, 32, 16, 16],       # roundel: ring + disc  (bits 0|3)
	54: [33, 125, 32, 32, 16, 16],       # ship class icon, type 1 (FUN_100e86d0)
	55: [0, 125, 32, 32, 16, 16],        # ship class icon, type 2
	56: [0, 158, 32, 32, 16, 16],        # ship class icon, type 4/6
	57: [33, 158, 32, 32, 16, 16],       # ship class icon, type 3
	58: [99, 158, 32, 32, 16, 16],       # ship class icon, type 5 / category 0xb
	60: [231, 226, 24, 24, 12, 12],      # L-point class icon
	62: [0, 191, 32, 32, 16, 16],        # thermometer
	63: [33, 191, 32, 32, 16, 16],       # lightning bolt
	64: [198, 191, 32, 32, 16, 16],      # light bulb
	78: [99, 224, 32, 32, 16, 16],       # missile
	86: [132, 224, 32, 32, 16, 16],      # alpha  (multiplayer)
	87: [166, 224, 32, 32, 16, 16],      # beta   (multiplayer)
	88: [198, 224, 32, 32, 16, 16],      # flag   (multiplayer)
	89: [132, 158, 32, 32, 16, 16],      # bomb   (multiplayer)
	# The two rail primitives. Both are fed to FUN_100eaf90(x, y, w, thin, cap,
	# rail): the cap is blitted at each end (the right one X-mirrored) and the
	# rail's narrow column is stretched between them.
	76: [111, 0, 9, 18, 9, 9],           # 0x4C ship-status strip: end chevron
	77: [121, 0, 2, 18, 0, 9],           # 0x4D ship-status strip: its two rails
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
	_font_menu = load_game_font(base, "ocrb_10pt.fnt")
	_font_head = load_game_font(base, "ocrb_18pt.fnt")
	if _font is FontFile and (_font as FontFile).fixed_size > 0:
		FONT_SIZE = (_font as FontFile).fixed_size
	if _font_num is FontFile and (_font_num as FontFile).fixed_size > 0:
		num_size = (_font_num as FontFile).fixed_size
	if _font_big is FontFile and (_font_big as FontFile).fixed_size > 0:
		big_size = (_font_big as FontFile).fixed_size
	if _font_menu is FontFile and (_font_menu as FontFile).fixed_size > 0:
		menu_size = (_font_menu as FontFile).fixed_size
	if _font_head is FontFile and (_font_head as FontFile).fixed_size > 0:
		head_size = (_font_head as FontFile).fixed_size
	target_view = TargetView.new()
	target_view.main = main
	add_child(target_view)
	_sprites = _load_mask(base, "sprites.png")
	_reticle_tex = _load_mask(base, "reticle.png")
	_ucp_tex = _load_mask(base, "ucp.png")
	# the 1024-entry scanline-brightness table (FUN_100e8250 fill loop):
	# (1 - r) * 0.75 + r with r uniform in [0,1)  (_DAT_10117d8c = 0.75)
	noise.resize(1024)
	for i in 1024:
		noise[i] = 0.75 + 0.25 * randf()
	screens = HudScreens.new()
	screens.hud = self
	screens.main = main
	# flux.ini [icHUD] puts the menu elements at 17..21 and the reticle at 11:
	# an open screen sits ON TOP of the flight HUD, including the MFD effect
	# layer (z 1) and the comm portrait, which are later children of this node.
	screens.z_index = 2
	add_child(screens)
	_mfd_fx = MfdFx.new()
	_mfd_fx.hud = self
	_mfd_fx.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_mfd_fx.z_index = 1  # composites over the comm portrait, a later child
	add_child(_mfd_fx)
	# icHUDShipStatus draws its lamps ADDITIVELY (every sprite path in the HUD
	# sets FcGraphicsEngine+0x175c = 2 before Begin). For this one element the
	# blend mode is load-bearing rather than cosmetic: a destroyed subsim's lamp
	# is drawn in BLACK (FUN_100fac60 @ 0x100faf34) -- which only reads as "off"
	# under an additive blend -- and a damaged one is drawn TWICE to make it
	# flash. A CanvasItem's blend mode is a material, not a per-call flag, so the
	# strip gets its own additive child.
	_status_fx = StatusLights.new()
	_status_fx.hud = self
	_status_fx.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_status_fx.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var add_mat := CanvasItemMaterial.new()
	add_mat.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	_status_fx.material = add_mat
	add_child(_status_fx)

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
	_menushot_step(d)
	_menu_spin_step(d)
	_menu_process(d)
	if flash_time > 0.0:
		flash_time -= d
		if flash_time <= 0.0:
			flash_name = ""
	if screens != null:
		screens.visible = screen != ""
	queue_redraw()

func hud_up() -> bool:
	if main == null or main.ship == null:
		return false
	if main.menu != null and main.menu.visible and not main.menu.launched:
		return false
	return true

func _draw() -> void:
	if not hud_up():
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
		if _mfd_fx != null:
			_mfd_fx.active = false
		_draw_mfd()
	_draw_weapon_panel()
	# icHUDShipStatus lives on the additive _status_fx layer (see _ready)
	_draw_shield_panel()
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
	# modes 0/1/3 shrink the block to 128x48 (FUN_10103d80 passes DAT_1011e240);
	# modes 2/4/5 restore the full 128x176 (FUN_10103e00)
	var h := MFD_SIZE.y if _mfd_mode in [2, 4, 5] else MFD_SHORT_H
	return Rect2(Vector2(_left_x(), MARGIN), Vector2(MFD_SIZE.x, h))

func _mfd_apply_mode(mode: int) -> void:
	# the master Draw (0x10101792): on any mode change this+0xb0 (the block
	# fade) and this+0xd0 (the barcode phase) reset; FUN_10102930 also resets
	# this+0xb4 (the convergence-line parameter) to 1. Mode 5 skips the fade
	# (FUN_10102fd0 writes +0xb0 = 1.0 directly).
	if mode == _mfd_mode:
		return
	_mfd_mode = mode
	_mfd_fade = 1.0 if mode == 5 else 0.0
	_mfd_sub = 1.0
	_ucp_phase = 0.0

func _mfd_begin(mode: int) -> Rect2:
	_mfd_apply_mode(mode)
	if _mfd_fade < 1.0:
		# 0x100de817f6..: fade += dt / 1.0; engine master alpha = fade while < 1
		_mfd_fade = minf(_mfd_fade + get_process_delta_time() / MFD_FADE_T, 1.0)
	_ea = _mfd_fade * _flash_a("icHUDTargetMFD")
	return _mfd_rect()

# the two amber text lines at the bottom of the block. The master Draw puts
# line 1 at y = h - 4 - 2*line_height - 3 and line 2 at y = h - 4 - lh + 2,
# x-indented 32px (2 * DAT_1011d970) in modes 2/3 and 0 in modes 4/5. The
# line height itself is a runtime font metric, so ours is our font's.
func _mfd_text(r: Rect2, line1: String, line2: String, indent: float) -> void:
	var lh := float(FONT_SIZE) + 3.0
	var tx := r.position.x + MFD_INSET + indent
	draw_string(_font, Vector2(tx, r.position.y + r.size.y - MFD_INSET - lh),
			line1.left(18), HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE - 1, _dim(AMBER))
	draw_string(_font, Vector2(tx, r.position.y + r.size.y - MFD_INSET),
			line2.left(18), HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE - 2,
			_dim(Color(AMBER.r, AMBER.g, AMBER.b, 0.7)))

func scanlines(ci: CanvasItem, rect: Rect2, strength: float, col: Color,
		ea := 1.0) -> void:
	# FUN_100ec850: one horizontal line every 2px (_DAT_10119ec8), each with a
	# brightness from the 1024-float noise table, starting at a random index
	# each frame -- animated interference static.
	if noise.is_empty():
		return
	var idx := randi() & 0x3ff
	var y := rect.position.y
	while y < rect.end.y:
		idx = (idx + 1) & 0x3ff
		var a := strength * noise[idx] * ea
		ci.draw_line(Vector2(rect.position.x, y), Vector2(rect.end.x, y),
				Color(col.r, col.g, col.b, col.a * a), 1.0)
		y += 2.0

# The comms static and scan band must composite OVER the portrait (which is a
# child Control that draws after the HUD's own canvas items), so they live on
# a small overlay child that stays on top.
class MfdFx extends Control:
	var hud: Hud
	var body := Rect2()
	var video := false
	var ea := 1.0
	var active := false

	func _process(_d: float) -> void:
		queue_redraw()

	func _draw() -> void:
		if not active or hud == null:
			return
		# interference static (FUN_10102490 @ 0x10102809): overall strength
		# flickers each frame -- (1-r)*0.1 + r*0.3 over a video feed,
		# (1-r)*0.3 + r*0.7 over a 3D feed; colour chartreuse * 0.4
		# (_DAT_10117558), over x 2..127, y 19..143 of the block.
		var rr := randf()
		var strength := lerpf(0.1, 0.3, rr) if video else lerpf(0.3, 0.7, rr)
		hud.scanlines(self, Rect2(body.position + Vector2(2, 3),
				Vector2(body.size.x - 3.0, body.size.y - 5.0)), strength,
				Color(Hud.GREEN.r * 0.4, Hud.GREEN.g * 0.4, Hud.GREEN.b * 0.4, 1.0),
				ea)
		# the scan band (FUN_10102490): 4px tall, chartreuse * 0.3
		# (_DAT_1011c034), alpha 0 at its top edge -> full at its bottom,
		# sweeping the portrait every 3 s (frac(game_ms / 3000) * (h - 4)).
		var sweep := fposmod(Time.get_ticks_msec() / 1000.0, Hud.MFD_SWEEP_T) \
				/ Hud.MFD_SWEEP_T
		var sy := body.position.y + sweep * (body.size.y - Hud.MFD_SWEEP_H)
		for i in int(Hud.MFD_SWEEP_H):
			draw_line(Vector2(body.position.x + 2, sy + i),
					Vector2(body.end.x - 1, sy + i),
					Color(Hud.GREEN.r * 0.3, Hud.GREEN.g * 0.3, Hud.GREEN.b * 0.3,
						(i + 1) / Hud.MFD_SWEEP_H * ea), 1.0)

var _mfd_fx: MfdFx

func _draw_comm_panel() -> void:
	# @element icHUDTargetMFD (mode 5, FUN_10102fd0 / FUN_10102490)
	# The comm channel takes over the target MFD block: caption becomes
	# hud_target_comm_channel_open, line 1 the speaker's name (icComms+0x50,
	# uppercased), line 2 hud_target_receiving_video / hud_target_no_video_feed
	# (icComms+0x138). The portrait area is backed by a solid black quad
	# (x 0..128, y 16..144, FUN_10103060's mode-5 branch), the FMV portrait or
	# the speaker's 3D model renders into it, and TWO effects composite on top:
	#  - interference static: a chartreuse*0.4 scanline field (FUN_100ec850)
	#    over x 2..127, y 19..143, whose overall strength flickers randomly
	#    every frame -- (1-r)*0.1 + r*0.3 over a video feed, (1-r)*0.3 + r*0.7
	#    over a 3D feed (FUN_10102490 @ 0x10102809).
	#  - the scan band: a 4px-tall chartreuse*0.3 quad whose alpha ramps 0 at
	#    its top edge to full at its bottom, sweeping down the portrait every
	#    3 s (frac(game_ms / 3000) * (128 - 4) + 16).
	var r := _mfd_begin(5)
	_panel(r.position, r.size, "COMM CHANNEL OPEN")
	var body := Rect2(r.position + Vector2(0, HDR_H),
			Vector2(r.size.x, 128.0))  # y 16..144 (16 * _DAT_10117b28 = 8)
	draw_rect(body, _dim(Color(0, 0, 0, 1)))
	# comms.gd builds the portrait at a fixed 204x148; scale it into the block
	var p: Control = main.comms.portrait
	p.scale = Vector2.ONE * ((body.size.x - 2.0) / p.size.x)
	p.position = body.position + Vector2(1, 1)
	var has_video: bool = main.comms.video != null and main.comms.video.is_playing()
	if _mfd_fx != null:
		_mfd_fx.active = true
		_mfd_fx.body = body
		_mfd_fx.video = has_video
		_mfd_fx.ea = _ea
	var who := str(main.comms.speaker).to_upper()
	_mfd_text(r, who, "RECEIVING VIDEO" if has_video else "NO VIDEO FEED", 0.0)
	_ea = 1.0

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
	var keys: String = str(main.mission.prompt_keys)
	if keys != "":
		# input.KeyCombinations already returns the brackets (FcInputMapper::
		# FormKeyString wraps every binding in "[ " ... " ]"); a hand-authored
		# mission `keys` field does not.
		text += "  %s" % keys if keys.begins_with("[") else "  [ %s ]" % keys
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

# icHUDTargetMFD internals, all read out of the master Draw (0x10101730, a
# jumptable casualty recovered from raw bytes) and its mode handlers. The
# element has SIX modes (this+0x34), dispatched through the table at
# 0x10101b20:
#   0 no target (hud_target_no_target)         draw = FUN_100bb300, a no-op
#   1 unknown target (hud_target_unknown_...)  short block, "?" class icon
#   2 ship target (hud_target_target_mode)     model + hull bars (FUN_10101c80)
#   3 nav target (hud_target_waypoint_mode)    short block, class icon
#   4 cargo pod (hud_target_ucp_scan_mode)     model + UCP barcode (FUN_10101f00)
#   5 comms (hud_target_comm_channel_open)     portrait + static (FUN_10102490)
const MFD_SHORT_H := 48.0    # DAT_1011e240: modes 0/1/3 shrink the block to 128x48
const MFD_INSET := 4.0       # _DAT_1011e244: horizontal text inset
const MFD_FADE_T := 1.0      # 0x1011e24c / 0x101171f0: the whole block fades in
                             # over one second after a mode change (this+0xb0)
const MFD_SWEEP_T := 3.0     # _DAT_10118498 = 1/3000 per game-time ms: the comms
                             # scan band sweeps the portrait every 3 s
const MFD_SWEEP_H := 4.0     # _DAT_101190b4: the band is 4px tall
const MFD_SUB_RATE := 1.5    # _DAT_1011a268: the convergence lines' sweep rate
const UCP_SCROLL := 0.2      # _DAT_1011e248: barcode scroll phase rate /s
var _mfd_mode := -1
var _mfd_fade := 1.0         # this+0xb0
var _mfd_sub := -1.0         # this+0xb4, the convergence-line parameter
var _ucp_phase := 0.0        # this+0xd0
var _ucp_tex: Texture2D      # texture:/images/hud/ucp (ctor 0x10101530)
# FUN_100e8250 fills 1024 floats with (1-r)*0.75 + r, r = rand()/32768 -- the
# per-scanline brightness table (DAT_1017500c) behind every "static" effect.
var noise := PackedFloat32Array()
# ihud.FlashElement (FUN_100df3e0): stores a CLASS name at icHUD+0xcc and
# flash_delay at +0xd0; each element whose ClassName() matches is drawn at
# master alpha 0.3 (0x3e99999a in FUN_100e1e30) while ftol(t * flash_frequency)
# is odd. flux.ini [icHUD]: flash_delay = 6, flash_frequency = 3.
const FLASH_DELAY := 6.0     # DAT_101628c0
const FLASH_FREQ := 3.0      # DAT_101628c4
const FLASH_DIM := 0.3       # 0x3e99999a
var flash_name := ""         # icHUD+0xcc
var flash_time := 0.0        # icHUD+0xd0
var _ea := 1.0               # element alpha: fade-in and FlashElement dimming

func flash_element(cls: String) -> void:
	# ihud.FlashElement -- FUN_100df3e0. The scripts pass icHUD class names
	# ("icHUDOrbRadar", "icHUDContactList", "icHUDTargetMFD", "icHUDWeapons").
	flash_name = cls
	flash_time = FLASH_DELAY

func _flash_a(cls: String) -> float:
	if flash_name != cls or flash_time <= 0.0:
		return 1.0
	return FLASH_DIM if int(flash_time * FLASH_FREQ) & 1 else 1.0

func _dim(c: Color) -> Color:
	return Color(c.r, c.g, c.b, c.a * _ea)

func _left_x() -> float:
	return MARGIN + 2.0 * BORDER

func _right_x(w: float) -> float:
	return _screen().x - MARGIN - 2.0 * BORDER - w

func _advance(y: float, h: float) -> float:
	return y + h + 2.0 * BORDER + BLOCK_GAP

func _panel(pos: Vector2, size: Vector2, title: String) -> void:
	# glossy chrome: dark glass body with a subtle top sheen, bright header.
	# _ea carries the MFD's one-second fade-in and FlashElement's 0.3 dim.
	draw_rect(Rect2(pos + Vector2(0, HDR_H), size - Vector2(0, HDR_H)),
			_dim(Color(0.0, 0.05, 0.0, 0.62)))
	draw_rect(Rect2(pos + Vector2(1, HDR_H + 1), Vector2(size.x - 2, 10)),
			_dim(Color(0.5, 1.0, 0.6, 0.05)))
	draw_rect(Rect2(pos, Vector2(size.x, HDR_H)), _dim(GREEN_PANEL))
	draw_rect(Rect2(pos, Vector2(size.x, 5)), _dim(Color(0.7, 1.0, 0.75, 0.25)))
	draw_string(_font, pos + Vector2(3, 12), title,
			HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE - 2, _dim(Color(0, 0, 0, 0.9)))
	draw_rect(Rect2(pos, size), _dim(GREEN_DIM), false, 1.0)
	draw_rect(Rect2(pos - Vector2(1, 1), size + Vector2(2, 2)),
			_dim(Color(GREEN.r, GREEN.g, GREEN.b, 0.12)), false, 1.0)

func _bar(pos: Vector2, frac: float, col: Color, segs := BAR_SEGS) -> void:
	# FUN_100ebde0 with bar style 1: segs blocks on a BAR_PITCH grid, and the
	# segment straddling the fill boundary fades by the remainder rather than
	# snapping on. The weapon/shield bars pass length 74 (14 segments); the
	# target MFD's hull bars pass length 2*16-3 = 29 (5 segments).
	var f := clampf(frac, 0.0, 1.0)
	var lit := f * segs
	for i in segs:
		var r := Rect2(pos + Vector2(i * BAR_PITCH, 0), Vector2(BAR_PITCH - 1.0, 8))
		var a := clampf(lit - float(i), 0.0, 1.0)
		if a > 0.0:
			draw_rect(r, _dim(Color(col.r, col.g, col.b, col.a * maxf(a, 0.35))))
		else:
			draw_rect(r, _dim(Color(col.r, col.g, col.b, 0.15)))

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
	# The ring is sprite 90 (reticle.png cell 0,0..170,170, origin 84,84),
	# drawn at NATIVE size: the master draw (FUN_100f6340 @ 0x100f615f) pushes
	# the pixel camera, icHUDReticle::Draw (0x100f60c0, raw bytes) builds a
	# translate-only matrix to the screen centre -- no scale anywhere -- and
	# FUN_100e9de0 always blits atlas cells 1:1. The circle stroke in the art
	# sits at r ~72.5 with ticks to ~79; _DAT_1011e038 = 63 is the LAYOUT
	# radius (in-reticle test, gauge ring), not the drawn ring. The engine
	# tints it chartreuse (DAT_10176038) unconditionally.
	if _reticle_tex != null:
		_spr_ret(c, 90, ring)
	else:
		# vector fallback when the extracted texture is missing
		draw_arc(c, 72.5, 0, TAU, 96, ring, 1.4, true)
		for i in 24:
			var a := TAU * i / 24.0
			var dir := Vector2(sin(a), -cos(a))
			var inner := 72.5 - (7.0 if i % 6 == 0 else 4.0)
			draw_line(c + dir * inner, c + dir * 72.5, ring, 1.4, true)
		draw_line(c + Vector2(-5, 0), c + Vector2(5, 0), ring, 1.0, true)
		draw_line(c + Vector2(0, -5), c + Vector2(0, 5), ring, 1.0, true)
	# own hull, as the filled arc the original sweeps behind the ring
	# (FUN_100f73d0, alpha 0.65 from _DAT_10119b40)
	var frac: float = clampf(main.hull / main.hull_max, 0.0, 1.0)
	var hull_col := _health_color(frac)
	draw_arc(c, RET_R + 5.0, -PI / 2.0, -PI / 2.0 + TAU * frac, 64,
			Color(hull_col.r, hull_col.g, hull_col.b, 0.65), 2.5, true)
	# own speed, left of the reticle ("+325m/s")
	# 0x100f7076: font 0, style 2 (alpha 0.75), halign 1 (right-anchored on
	# -TEXT_X), valign 2 (centred on the reticle's own centre line, y = 0).
	var vel: float = main.ship.forward_speed()
	var vel_text: String = ("%s/s" % _fmt_range(absf(vel))) if in_lds \
		else "%s%dm/s" % ["-" if vel < 0 else "+", absi(int(absf(vel)))]
	_hud_text(0, 2, c + Vector2(-TEXT_X, 0), vel_text, 1, 2, ring)
	if main.ship.set_speed > 0.5:
		var st := "set %d" % int(main.ship.set_speed)
		_hud_text(0, 0, c + Vector2(-TEXT_X, float(num_size) + 4.0), st, 1, 2,
				ring)
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

func _spr(pos: Vector2, id: int, col: Color, rot := 0.0, flags := 0,
		ci: CanvasItem = null) -> void:
	# FUN_100e9de0(x, y, sprite, flags, rotation). The quad spans
	# [-origin, size - origin] about the anchor and is drawn at NATIVE atlas
	# size -- the engine never scales these.
	# The FLAGS argument mirrors the cell about the anchor: bit0 in X
	# (0x100e9e0d: x0 = +origin_x, x1 = origin_x - w), bit1 in Y (0x100e9e3a).
	# That is not a detail -- it is how one 9x11 lamp cell makes the ship-status
	# strip's damage/power PAIR, how one 9x18 chevron caps both ends of a rail,
	# and how one 85x85 cell makes the whole 170x170 menu reticle.
	var t: CanvasItem = self if ci == null else ci
	if _sprites == null or not SPR.has(id):
		return
	var s: Array = SPR[id]
	var sz := Vector2(float(s[2]), float(s[3]))
	var off := Vector2(-float(s[4]), -float(s[5]))
	var src := Rect2(float(s[0]), float(s[1]), sz.x, sz.y)
	var c := _dim(col)
	var sc := Vector2(-1.0 if (flags & 1) != 0 else 1.0,
			-1.0 if (flags & 2) != 0 else 1.0)
	if is_zero_approx(rot) and sc.is_equal_approx(Vector2.ONE):
		t.draw_texture_rect_region(_sprites, Rect2(pos + off, sz), src, c)
		return
	t.draw_set_transform(pos, rot, sc)
	t.draw_texture_rect_region(_sprites, Rect2(off, sz), src, c)
	t.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

func _hbar(ci: CanvasItem, x: float, y: float, w: float, cap: int, rail: int,
		col: Color) -> void:
	# FUN_100eaf90(x, y, width, thin, cap_sprite, rail_sprite) @ 0x100eaf90 --
	# the engine's horizontal rail. It blits the cap sprite at (x, y) and again
	# at (x + w, y) with the X-mirror flag, then stretches the rail sprite's
	# narrow column (a bright row at its top and another at its bottom) into a
	# quad from x to x + w. Both the ship-status strip (caps 76 / rails 77, 18px
	# tall) and every menu node box (caps 40 / rails 41, 32px tall) ARE this
	# call; nothing here is a hand-drawn rectangle.
	# `thin` picks the alpha: 0 -> 0.5 * master, nonzero -> 1.0 * master. The
	# caller passes that in the colour's alpha here.
	x = floor(x)
	y = floor(y)
	_spr(Vector2(x, y), cap, col, 0.0, 0, ci)
	_spr(Vector2(x + w, y), cap, col, 0.0, 1, ci)
	if _sprites == null or not SPR.has(rail):
		return
	var s: Array = SPR[rail]
	var src := Rect2(float(s[0]), float(s[1]), float(s[2]), float(s[3]))
	var dst := Rect2(x, y - float(s[5]), w, float(s[3]))
	ci.draw_texture_rect_region(_sprites, dst, src, _dim(col))

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
	# hull bar spanning the block, then three lines --
	#   "<hull%> <NAME>"   0x100f7f2b  font 0, style 2, halign 0, valign 0
	#   "<range>"          0x100f7ffe  font 1 (ocrb_10pt!), style 2, x - 1
	#   "<speed>m/s"       0x100f812c  font 0, style 2
	# The RANGE is the one line in the whole reticle that is NOT in the little
	# Andale face -- it is set in OCR-B 10pt, twice the size of the name above
	# it. We had it in font 0 like the rest, which is why the block read flat.
	# The lines step by their OWN font's line height (0x10162c6c for font 0,
	# 0x10162c80 for font 1), and the block is centred on the reticle's centre
	# line: top = c.y - (lh0 + lh0 + lh1) / 2  (0x100f7e37).
	var tdist: float = main._target_distance()
	if tdist == INF:
		return
	var col := _target_color()
	var lh0: float = _font_num.get_height(num_size)
	var lh1: float = _font_menu.get_height(menu_size)
	var top: float = floor(c.y - (lh0 + lh0 + lh1) * 0.5)
	var tname := ""
	var thull := -1.0
	if main.target_ai != null and is_instance_valid(main.target_ai):
		tname = str(main.target_ai.display_name).to_upper()
		thull = clampf(main.target_ai.hull / main.target_ai.hull_max, 0.0, 1.0)
	elif main.target_idx >= 0:
		tname = str(main.objects[main.target_idx]["name"]).to_upper()
	if thull >= 0.0:
		_vbar(Vector2(c.x + TEXT_X, top), lh0 + lh0 + lh1, thull,
				_health_color(thull))
	var tx := c.x + TEXT_X + TEXT_GAP
	var head := tname
	if thull >= 0.0:
		head = "%d %s" % [int(round(thull * 100.0)), tname]
	_hud_text(0, 2, Vector2(tx, top), head, 0, 0, col)
	_hud_text(1, 2, Vector2(tx - 1.0, top + lh0), _fmt_range(tdist), 0, 0, col)
	var tvel := Vector3.ZERO
	if main.target_ai != null and is_instance_valid(main.target_ai):
		tvel = main.target_ai.velocity
	var spd := tvel.length()
	if spd > 0.0:
		_hud_text(0, 2, Vector2(tx, top + lh0 + lh1), "%dm/s" % int(spd), 0, 0,
				col)
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
#    5  -67.5   110   0x1B    amber    13    a ship system is down; else 0x1D
#                                            while strafing (yoke lateral x/y
#                                            nonzero) or 0x1C in free flight
#                                            (yoke+0x1c), autopilot off only
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
const AP_ICON := [-1, 1, 0, 3, 2]   # DAT_1011e04c, indexed by the ENGINE's enum
# The engine's autopilot enum is 0 Off, 1 Formate, 2 Approach, 3 Dock, 4 Match.
# Ours is 0 Off, 1 Approach, 2 Formate, ... -- approach and formate are swapped.
# AP_ICON is the engine's table, so it has to be indexed by the engine's value,
# or an approach lights the formate icon.
const AP_MODE_TO_ENGINE := [0, 2, 1, 3, 4]
const GAUGE_HOLD := 2.0             # DAT_1011e03c: a gauge lingers 2 s after it
                                    # stops changing
var _gauge_last := [-1.0, -1.0, -1.0]
var _gauge_hold := [0.0, 0.0, 0.0]

func _draw_status_icons(c: Vector2) -> void:
	# --- slots 0-3: autopilot mode, r = 150, one at most ---------------------
	var lit: int = AP_ICON[AP_MODE_TO_ENGINE[clampi(main.ap_mode, 0, 4)]]
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

	# --- slot 5: system down / manoeuvring state, r = 110 --------------------
	# FUN_100f8410 @ 0x100f89fa: sprite 0x1B (flags 13) if any non-turret
	# component is non-functional. Otherwise, with the autopilot OFF
	# (pilot+0x308 == 0), it reads iiPilot::Yoke() (ship+0x270 vfunc +0x40 =
	# icPlayerPilot::Yoke @ 0x100af8c0, the sYoke at pilot+0x30):
	#   yoke+0x0c/+0x10 (LateralX/LateralY, HandleLinearMessage msgs 5/6)
	#   nonzero            -> sprite 0x1D (capsule + side arrows), flags 13
	#   both zero AND yoke+0x1c == 1 (free flight -- FreeHold/FreeToggle,
	#   HandleButtonMessage cases 0/1) -> sprite 0x1C (capsule + circular
	#   arrow), flags 13
	var sys_down := false
	for state: float in main.system_states().values():
		if state >= 0.0 and state <= 0.0:
			sys_down = true
			break
	if sys_down:
		_icon(c + _icon_pos(-67.5, ICON_R), 0x1B,
				ICON_ROUNDEL | ICON_PULSE | ICON_RING, AMBER)
	elif main.ap_mode == 0 and main.ship != null:
		var thrust: Vector3 = main.ship.input_thrust
		if absf(thrust.x) > 0.0 or absf(thrust.y) > 0.0:
			_icon(c + _icon_pos(-67.5, ICON_R), 0x1D,
					ICON_ROUNDEL | ICON_PULSE | ICON_RING, AMBER)
		elif not main.ship.assist:
			_icon(c + _icon_pos(-67.5, ICON_R), 0x1C,
					ICON_ROUNDEL | ICON_PULSE | ICON_RING, AMBER)

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
	# Each is a {value, flag} pair at icHUD+0xe8 (stride 8) -- NOT on
	# icPlayerPilot as an earlier pass believed. The writer is the icHUD player
	# feed, FUN_100e07f0:
	#  0x3E thermometer: (ship+0x288 + ship+0x28c) * 0.75 /
	#       icShip::m_heat_damage_threshold, clamped 0..1; RED when >= 0.75,
	#       i.e. exactly when total heat reaches the damage threshold.
	#  0x3F lightning:   the "reactor charge" -- ship+0x2a0 is the first icReactor
	#       subsim (icShip::OnAttachSubsim, class DAT_10165d40); value =
	#       reactor+0x7c / reactor+0x98, RED when < 0.25 (0x101191ec), and it
	#       DEFAULTS TO 1.0 when no reactor is fitted. The name is a misnomer:
	#       icReactor::Simulate (0x1003a2a0) writes +0x98 = the rated output and
	#       +0x7c = efficiency * output * ramp, so the ratio is `efficiency *
	#       ramp` -- nothing is stored and nothing drains. See ship_systems.gd.
	#  0x40 bulb:        icShip::Brightness() (0x10075420) -- the ship's
	#       visible/EM signature, RED when > 0.75 (0x10117d8c). NOT the old
	#       "idle x reactor, lerped by ThrusterRatio, plus LDS and weapon
	#       capacitor" reading: ThrusterRatio() is a STUB returning 0.0
	#       (0x10075600), and the real terms are heat, the sensor disruptor, the
	#       active sensor and the CPU's stealth program. See ship_systems.gd.
	# The icon appears whenever the value CHANGES, holds GAUGE_HOLD seconds
	# after it settles, and shows the value as a charge ring: amber + flags 9
	# normally, red + flags 13 when flagged.
	# main.ship_heat() returns heat/threshold * 0.8, so the gauge value is
	# ship_heat() * (0.75/0.8) and the flag trips at ship_heat() >= 0.8.
	_gauge(c, 0, 0x3E, 180.0, main.ship_heat() * 0.9375, main.ship_heat() >= 0.8)
	if main.sys != null:
		var rc: float = main.sys.reactor_charge()
		_gauge(c, 1, 0x3F, 157.5, rc, rc < ShipSystems.REACTOR_RED)
		var br: float = main.sys.brightness()
		_gauge(c, 2, 0x40, 135.0, br, br > ShipSystems.BRIGHT_RED)

	# --- slot 10: incoming missile, r = 110, +67.5 ----------------------------
	# The pilot's incoming feed (0x100b0fc0): pilot+0x6c is the alarm flag,
	# pilot+0xa8 the id list -- ONE PIP PER MISSILE on the charge ring. Fed by
	# missiles.gd through main.incoming_missiles.
	var incoming: int = main.incoming_missiles.size()
	if incoming > 0:
		_icon(c + _icon_pos(67.5, ICON_R), 0x4E, ICON_ROUNDEL | ICON_RING, RED,
				float(incoming) / float(ICON_PIPS))

	# Slots 11-14 are the multiplayer team / flag / bomb markers and are dead
	# in the campaign.

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
	# The three dynamic nodes. Each holds a PREV / NEXT pair (hud_menu_prev /
	# hud_menu_next, sprites 0x20/0x21) plus its command list in private slots
	# +0x40..+0x58 (FUN_100efe50 / FUN_100f0560 / FUN_100f0c40). RESOLVED: the
	# carousel node's direction virtual (vtable 0x1011de18 slot 4 =
	# FUN_100f0380) overrides directions 0 and 1 -- and the input mapper
	# (FUN_100e1bf0) registers HUD.MenuUp as 0 and HUD.MenuDown as 1 -- so
	# UP = PREV and DOWN = NEXT, clamped (no wrap; the invalid-input beep,
	# FUN_100ea750(1), plays at either end). Left/right still follow the node
	# links (the way back out). The autopilot list is APPROACH / FORMATE /
	# PURSUIT / DOCK (engine modes 2 / 1 / 4 / 3, stored at item+0x24);
	# DISENGAGE (mode 0) is a separate node shown INSTEAD of the list while
	# the autopilot is engaged (FUN_100f0420 keys off icPlayerPilot+0x308).
	"hud_menu_autopilot": {"label": "AUTOPILOT", "kind": "carousel",
		"right": "hud_menu_nav",
		"items": ["APPROACH", "FORMATE", "PURSUIT", "DOCK"]},
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
# The draw pulls a per-direction alignment code out of the table at 0x1011dec8
# and hands it to FUN_100ea830 as the box's horizontal alignment:
#     UP 2   DOWN 2   LEFT 1   RIGHT 0
# 2 = centred on the anchor, 1 = right-aligned (the box grows left from it),
# 0 = left-aligned. So the side boxes hang off the reticle outwards.
const MENU_ALIGN := [2, 2, 1, 0]
const MENU_BOX_CAP := 40      # sprite 0x28: the node box's chevron end cap
const MENU_BOX_RAIL := 41     # sprite 0x29: its top and bottom rails
const MENU_ICON_PREV := 32    # sprite 0x20, on the carousel's UP node
const MENU_ICON_NEXT := 33    # sprite 0x21, on its DOWN node
const MENU_ICON_PAD := 32.0   # _DAT_1011848c: an icon widens the box by 32
const MENU_TEXT_TRIM := 16.0  # _DAT_101184a0: the rail is 16 shorter than the text
const MENU_TEXT_BACK := 8.0   # _DAT_10117b28: the label starts 8px left of the
                              # rail, so it overhangs into both chevrons
const MENU_ICON_STEP := 12.0  # _DAT_10119ec4: rail start -> icon anchor
const MENU_TIME_Y := 30.0     # 0x41f00000: the timeout sits 30px below centre
# Every string in the menu goes through _hud_text (FUN_100eb270) -- see the
# TEXT_ALPHA block for what the font and style arguments mean.

var menu_active := false
var menu_focus := MENU_ROOT
var menu_time := 0.0            # icHUD+0x1b8, counts down; the timeout is shown
                                # only below 10 s (_DAT_101190c0)
var menu_locked := false        # icHUD+0x1b6, ihud.LockMenu
var menu_disabled := {}         # node name -> true; ihud.SetMenuNodeEnabled
var menu_carousel := {}         # carousel node -> selected index
var screen := ""                # the open full-screen HUD element, "" for none
var screens: HudScreens
# The four spinning quadrants are NOT on a constant rotation. FUN_100f1d60
# @ 0x100f1e73: on the frame a menu key GOES DOWN (latched through this+0x2c)
# the element rolls a random spin -- rate = sign(rand/32768 - 0.5) * PI
# (_DAT_10119ae0 = -1, _DAT_10119464 = PI) and a random duration under one
# second (this+0x28 = rand/32768) -- and then spins down:
#     t -= game_dt;  angle += rate * t
# so each keypress kicks the reticle and it settles again. Between kicks it is
# perfectly still.
var _menu_spin := 0.0           # this+0x20, the angle
var _menu_spin_rate := 0.0      # this+0x24
var _menu_spin_t := 0.0         # this+0x28
var _menu_spin_latch := false   # this+0x2c

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
	if str(node.get("kind", "")) == "carousel" and dir in ["up", "down"]:
		# FUN_100f0380: direction 0 (HUD.MenuUp) steps to the PREVIOUS item,
		# 1 (HUD.MenuDown) to the NEXT, clamped -- stepping past either end
		# plays the invalid-input beep instead of wrapping.
		var items: Array = node.get("items", [])
		var i: int = int(menu_carousel.get(menu_focus, 0))
		var j: int = clampi(i + (1 if dir == "down" else -1), 0,
				maxi(0, items.size() - 1))
		if j == i:
			main.audio.play("audio/hud/invalid_input.wav", -8.0)
		else:
			menu_carousel[menu_focus] = j
			main.audio.play("audio/hud/valid_input.wav", -8.0)
		return
	if str(node.get("kind", "")) == "carousel" and dir == "left":
		# the carousel's LEFT link IS the selected command (FUN_100f0420 writes
		# it to +0x1c), so walking left runs it -- FUN_100efaf0, the default
		# direction handler, just follows the link
		_menu_select()
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
			if main.ap_mode != 0:
				# while engaged the node shows DISENGAGE (FUN_100f0420)
				main.ap_mode = 0
			else:
				var i: int = int(menu_carousel.get(menu_focus, 0))
				# APPROACH/FORMATE/PURSUIT/DOCK: engine modes 2/1/4/3, which
				# in main.ap_mode's numbering are 1/2/4/3
				main.ap_mode = [1, 2, 4, 3][i]
	if kind in ["cmd", "toggle", "carousel"]:
		menu_active = false
		menu_focus = MENU_ROOT

func _spr_ret(pos: Vector2, id: int, col: Color, rot := 0.0, flags := 0) -> void:
	# the same blit as _spr, against reticle.png (texture 2)
	if _reticle_tex == null or not SPR_RET.has(id):
		return
	var s: Array = SPR_RET[id]
	var sz := Vector2(float(s[2]), float(s[3]))
	var off := Vector2(-float(s[4]), -float(s[5]))
	var src := Rect2(float(s[0]), float(s[1]), sz.x, sz.y)
	var sc := Vector2(-1.0 if (flags & 1) != 0 else 1.0,
			-1.0 if (flags & 2) != 0 else 1.0)
	draw_set_transform(pos, rot, sc)
	draw_texture_rect_region(_reticle_tex, Rect2(off, sz), src, col)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

func _menu_key_down() -> int:
	# icHUD+0x1bc / +0x1c0: which menu input is being HELD, in the input mapper's
	# slot order (FUN_100e1bf0) -- 0 up, 1 down, 2 left, 3 right, and 4 select,
	# the same order as the link offsets at +0x14..+0x20. -1 for none.
	if not menu_active:
		return -1
	if Input.is_physical_key_pressed(KEY_UP):
		return 0
	if Input.is_physical_key_pressed(KEY_DOWN):
		return 1
	if Input.is_physical_key_pressed(KEY_LEFT):
		return 2
	if Input.is_physical_key_pressed(KEY_RIGHT):
		return 3
	if Input.is_physical_key_pressed(KEY_ENTER) \
			or Input.is_physical_key_pressed(KEY_KP_ENTER):
		return 4
	return -1

func _menu_spin_step(dt: float) -> void:
	var down: bool = not menu_locked and _menu_key_down() >= 0
	if down:
		if not _menu_spin_latch:
			_menu_spin_latch = true
			_menu_spin_rate = (1.0 if randf() > 0.5 else -1.0) * PI
			_menu_spin_t = randf()
	else:
		_menu_spin_latch = false
	if _menu_spin_t > 0.0:
		_menu_spin_t = maxf(_menu_spin_t - dt, 0.0)
		_menu_spin += _menu_spin_rate * _menu_spin_t

func _menu_link_nodes(name: String) -> Array:
	# The four direction links of the focused node, in the engine's order
	# (+0x14 UP, +0x18 DOWN, +0x1c LEFT, +0x20 RIGHT). A link that is null or
	# whose node is DISABLED (node+0x10 == 0) is skipped entirely -- 0x100f217d /
	# 0x100f2187 -- it is not greyed out, it is not there.
	# Each entry is {} or {label, icon, col}: `icon` is the node's +0x14 sprite
	# and `col` its +0x18..+0x20 colour (FUN_100efbb0, the node ctor). Every node
	# in the tree is built green with sprite 0; only the carousel's PREV / NEXT
	# carry sprites (0x20 / 0x21, still green -- 0x100f2 ctor block at 0x100efe50).
	var node: Dictionary = MENU.get(name, {})
	var out: Array = [{}, {}, {}, {}]
	if str(node.get("kind", "")) == "carousel":
		# FUN_100f0420, the carousel's refresh: it rewrites its OWN links every
		# time the selection moves --
		#     +0x1c (LEFT)  = items[sel]        the selected command itself
		#     +0x14 (UP)    = PREV, or NULL at the first item
		#     +0x18 (DOWN)  = NEXT, or NULL at the last one   (3 < sel + 1)
		#     +0x20 (RIGHT) = untouched: the way back out
		# and while the autopilot is engaged (icPlayerPilot+0x308) it swaps LEFT
		# for the DISENGAGE node (+0x58) and NULLs both PREV and NEXT.
		# So a carousel's current item is a NODE BOX on the left. It is not part
		# of the name in the middle of the reticle -- that is only ever
		# Field(node+8), the node's own hud.csv label (0x100f2134).
		# The item nodes' own sprite and colour (the ctors at 0x100efe50 for the
		# autopilot, 0x100f0560 / 0x100f0c40 for the other two):
		#   PREV / NEXT                  sprite 0x20 / 0x21, chartreuse
		#   autopilot_disengage          sprite 0 (DAT_1011dd5c), AMBER
		#   approach/formate/pursuit/dock  sprites 21/22/23/24, AMBER -- the same
		#     four mode glyphs the reticle's icon ring uses, and the slot order
		#     +0x40..+0x4c is exactly that
		#   every wingmen / T-fighter item goes through FUN_100efc30, which is
		#     FUN_100efbb0(name, sprite 0, chartreuse) -- plain green, no icon
		var items: Array = node.get("items", [])
		var sel: int = int(menu_carousel.get(name, 0))
		var ap: bool = name == "hud_menu_autopilot"
		if ap and main.ap_mode != 0:
			out[2] = {"label": "DISENGAGE", "icon": 0, "col": AMBER}
		else:
			if sel > 0:
				out[0] = {"label": "PREV", "icon": MENU_ICON_PREV, "col": GREEN}
			if sel + 1 < items.size():
				out[1] = {"label": "NEXT", "icon": MENU_ICON_NEXT, "col": GREEN}
			if sel >= 0 and sel < items.size():
				out[2] = {"label": str(items[sel]),
					"icon": (21 + sel) if ap else 0,
					"col": AMBER if ap else GREEN}
	for i in 4:
		if not (out[i] as Dictionary).is_empty():
			continue
		var to := _menu_link(name, str(MENU_DIRS[i]))
		if to == "":
			continue
		out[i] = {"label": str(MENU[to].get("label", to)), "icon": 0,
			"col": GREEN}
	return out

func _draw_menu_reticle(c: Vector2) -> void:
	# @element icHUDMenuReticle -- Draw = FUN_100f1d60 @ 0x100f1d60, recovered
	# from raw bytes (Ghidra skipped it). It gates on icHUD+0x1b4, pushes a
	# translate to the screen centre, and draws, in order: the centre reticle,
	# the four spinning quadrants, the focused node's name, the timeout, and the
	# four link boxes.
	if not menu_active:
		return
	var held: int = -1 if menu_locked else _menu_key_down()
	var links := _menu_link_nodes(menu_focus)
	# 0x100f1e40 / 0x100f1f9f: the centre reticle drops to HALF alpha while a
	# direction that HAS a live link is held -- it dims as it hands you off.
	var moving: bool = held >= 0 and held < 4 \
			and not (links[held] as Dictionary).is_empty()
	var a_centre: float = 0.5 if moving else 1.0
	# 0x100f1ff4: the quadrants sit at HALF alpha and go to FULL only while
	# SELECT (input 4) is held -- that is the menu's "click".
	var a_spin: float = 1.0 if held == 4 else 0.5
	# FUN_100ea7e0(0, 0, 0x5b, 0) @ 0x100ea7e0: sprite 91 blitted FOUR times,
	# once per mirror-flag pair (0, 1, 3, 2). The 85x85 cell is ONE QUADRANT --
	# mirrored out it is the whole 170x170 reticle. (The old code drew the cell
	# once, so three quarters of the reticle were missing.)
	for f in 4:
		_spr_ret(c, 91, Color(GREEN.r, GREEN.g, GREEN.b, a_centre), 0.0, f)
	# four copies of sprite 93 stepped by PI/2 (_DAT_1011a454), turning together
	for i in 4:
		_spr_ret(c, 93, Color(GREEN.r, GREEN.g, GREEN.b, a_spin),
				_menu_spin + PI / 2.0 * i)
	# The focused node's NAME, and nothing else: Field(node+8) at 0x100f2142, one
	# string, drawn by the call at 0x100f2161 --
	#     font 2 (ocrb_18pt), style = (select held) ? 1 : 0, x = 0, y = 0,
	#     halign 2, valign 2
	# so it is centred on the reticle in both axes and sits at alpha 0.6 until
	# you hold select, when it goes to 1.0. (It used to read "AUTOPILOT: DOCK"
	# on a carousel; the engine never concatenates the item -- see
	# _menu_link_nodes -- and at 18pt that string ran clear off both sides of
	# the reticle.)
	var node: Dictionary = MENU.get(menu_focus, {})
	var head := str(node.get("label", menu_focus))
	_hud_text(2, 1 if held == 4 else 0, c, head, 2, 2, GREEN)
	# 0x100f209f: the timeout is drawn ONLY on the ROOT node, and only once it
	# drops below 10 s (_DAT_101190c0). hud_menu_timeout ("TIME: ") with
	# AppendFormat("%0.1fs", icHUD+0x1b8) -- the call at 0x100f2124 is
	# font 0 (Andale Mono 7pt), style 0, x = 0, y = 30, halign 2, valign 0.
	if menu_focus == MENU_ROOT and menu_time < 10.0:
		_hud_text(0, 0, c + Vector2(0, MENU_TIME_Y),
				"TIME: %0.1fs" % maxf(menu_time, 0.0), 2, 0, GREEN)
	for i in 4:
		var link: Dictionary = links[i]
		if link.is_empty():
			continue
		_menu_node_box(c + MENU_OFF[MENU_DIRS[i]], str(link["label"]),
				int(link["icon"]), link["col"], int(MENU_ALIGN[i]), held == i)

func _menu_node_box(anchor: Vector2, text: String, icon: int, col: Color,
		align: int, hi: bool) -> void:
	# FUN_100ea830 @ 0x100ea830 -> FUN_100ea900 @ 0x100ea900. A menu node is not
	# a rectangle with a label in it: it is the rail primitive (FUN_100eaf90 with
	# cap sprite 40 and rail sprite 41 -- 32px tall, 16px chevrons) sized to the
	# label, with the label drawn straddling it:
	#     w  = text_width + (32 if icon) - 16
	#     x  = floor(anchor.x) - 1;  centred / right-aligned / left-aligned by the
	#          direction's code, then floor -1 again inside FUN_100ea900
	#     rail(x, y, w);  tx = x - 8
	#     if icon:  roundel 51 under it WHEN HELD, then the icon at tx + 12,
	#               both at FULL alpha and in the NODE'S colour; tx += 16 after
	#     text at tx, vertically centred on y
	# The rail is at HALF alpha unless this is the direction currently being held
	# (0x100ea949): held = 1.0, otherwise 0.5. The LABEL is the call at
	# 0x100eab54 -- font 1 (ocrb_10pt), style = held ? 1 : 0, halign 0 (LEFT),
	# valign 2 -- so it is dim at 0.6 and lights to 1.0 with the box. The text
	# keeps the node's colour on a plain node and reverts to chartreuse after an
	# icon (0x100eaa5c).
	# The width the box is sized to is the ENGINE's text width (0x100ea844 calls
	# the same measure, FUN_100ebd70(1, ...)), which trims both side bearings --
	# five pixels narrower than a raw advance sum on a three-letter label, and
	# the rail is cut to it.
	var a: float = 1.0 if hi else 0.5
	var tw: float = _text_w(1, text)
	var w: float = tw + (MENU_ICON_PAD if icon != 0 else 0.0) - MENU_TEXT_TRIM
	var x: float = floor(anchor.x) - 1.0
	if align == 2:
		x -= floor(w * 0.5)
	elif align == 1:
		x -= w
	x = floor(x) - 1.0
	var y: float = floor(anchor.y)
	_hbar(self, x, y, w, MENU_BOX_CAP, MENU_BOX_RAIL,
			Color(col.r, col.g, col.b, a))
	var tx: float = x - MENU_TEXT_BACK
	var tcol := col
	if icon != 0:
		var ip := Vector2(tx + MENU_ICON_STEP, y)
		if hi:
			_spr(ip, 51, Color(col.r, col.g, col.b, 1.0))  # the roundel backing
		_spr(ip, icon, Color(col.r, col.g, col.b, 1.0))
		tx = ip.x + MENU_TEXT_TRIM
		tcol = GREEN
	if text != "":
		_hud_text(1, 1 if hi else 0, Vector2(tx, y), text, 0, 2, tcol)

# --- FUN_100eb270: the one call every string on the HUD goes through ---------
# FUN_100eb270(font, style, x, y, str, halign, valign) @ 0x100eb270 -- 47 call
# sites, found by scanning .text for calls (Ghidra drops most of them).
#
#   font   indexes the table at 0x10162c60, stride 0x14 (0x100eb29d):
#            0 font:/fonts/ocrb_8pt    1 font:/fonts/ocrb_10pt
#            2 font:/fonts/ocrb_18pt   3 texture:/images/hud/sprites
#          Font 0 is a misnomer *in the game's own data*: ocrb_8pt.frf's FHDR
#          names its atlas "andale mono_7pt.lbm" and its family "andale mono",
#          at 7pt -- and the frf's glyph rects capture 100% of the ink on
#          andale mono_7pt.ftu against 62.9% on ocrb_8pt.ftu. Font 0 IS Andale
#          Mono 7pt; ocrb_8pt.ftu is a stale atlas nothing reads.
#   style  indexes the alpha table at 0x10162cb0, stride 8 (0x100eb2f2):
#            0 -> 0.6   1 -> 1.0   2 -> 0.75
#          multiplied by the element's master alpha (FcGraphicsEngine+0x1790).
#   halign 0x100eb390 / 0x100eb775:  0 left, 1 right (x - w), 2 centre (x - w/2)
#   valign 0x100eb7a2:  0 top, 1 bottom (y - h), 2 middle (y - h/2 - 1)
#          y is the TOP of the line; the baseline is y + the font's ascent
#          (DrawText adds FcFont+0x24, 0x100606f6).
const TEXT_ALPHA := [0.6, 1.0, 0.75]

func _hud_font(idx: int) -> Font:
	if idx == 1:
		return _font_menu
	if idx == 2:
		return _font_head
	return _font_num

func _hud_font_size(idx: int) -> int:
	if idx == 1:
		return menu_size
	if idx == 2:
		return head_size
	return num_size

var _glyph_cache := {}

func _glyph(fi: int, ch: int) -> Array:
	# [advance, ink_x0, ink_w, ink_y0, ink_h] for one character, straight out of
	# the loaded bitmap font -- the same five numbers FcGlyph keeps (flux.dll
	# 0x1007fe60 reads the .frf's ten int32s in file order).
	var key: int = fi * 65536 + ch
	if _glyph_cache.has(key):
		return _glyph_cache[key]
	var f: Font = _hud_font(fi)
	var size: int = _hud_font_size(fi)
	var rec: Array = [0.0, 0.0, 0.0, 0.0, 0.0]
	if f != null:
		rec[0] = f.get_char_size(ch, size).x
		var rids: Array = f.get_rids()
		if not rids.is_empty():
			var ts: TextServer = TextServerManager.get_primary_interface()
			var gi: int = ts.font_get_glyph_index(rids[0], size, ch, 0)
			var o: Vector2 = ts.font_get_glyph_offset(rids[0], Vector2i(size, 0), gi)
			var s: Vector2 = ts.font_get_glyph_size(rids[0], Vector2i(size, 0), gi)
			rec[1] = o.x
			rec[2] = s.x
			rec[3] = o.y
			rec[4] = s.y
	_glyph_cache[key] = rec
	return rec

func _text_metrics(fi: int, text: String) -> Vector3:
	# FcFont::GetTextSize @ flux.dll 0x100827a0. The pen steps by the glyph's
	# LOGICAL width (lx1 - lx0) plus Kern(c, next) -- and Kern is 0 for every
	# pair in every font the HUD uses: flux registers its 236 kerning pairs into
	# the ITALIC table only (FcFont ctor @ 0x100800b0, every call pushes 1), the
	# HUD's fonts are not italic, and nothing in iwar2 calls
	# SetAdditionalFontKern. So the advance IS the metric and our BMFonts match.
	# The reported WIDTH then trims the first glyph's left bearing (0x10082803)
	# and the last glyph's right bearing (0x1008286f), and the HEIGHT is the INK
	# height of THIS string (max -ink_y0 + max ink_y1, 0x10082883) -- not the
	# font's line box. Returns (width, ink height, first left bearing).
	if text.is_empty():
		return Vector3.ZERO
	var w := 0.0
	var asc := 0.0
	var desc := 0.0
	for i in text.length():
		var g: Array = _glyph(fi, text.unicode_at(i))
		w += float(g[0])
		asc = maxf(asc, -float(g[3]))
		desc = maxf(desc, float(g[3]) + float(g[4]) - 1.0)
	var first: Array = _glyph(fi, text.unicode_at(0))
	var last: Array = _glyph(fi, text.unicode_at(text.length() - 1))
	w -= float(first[1])
	w -= float(last[0]) - (float(last[1]) + float(last[2]) - 1.0)
	return Vector3(w, asc + desc, float(first[1]))

func _text_w(fi: int, text: String) -> float:
	return _text_metrics(fi, text).x

func _hud_text(fi: int, style: int, p: Vector2, text: String, halign: int,
		valign: int, rgb: Color) -> void:
	var f: Font = _hud_font(fi)
	if f == null or text == "":
		return
	var m: Vector3 = _text_metrics(fi, text)
	var x: float = p.x
	if halign == 1:
		x -= m.x
	elif halign == 2:
		x -= m.x * 0.5
	var y: float = p.y
	if valign == 1:
		y -= m.y
	elif valign == 2:
		y -= m.y * 0.5 + 1.0
	# DrawText backs the pen up by the first glyph's left bearing so the ink
	# starts flush on x (0x1006074d); Godot applies that bearing itself, so it
	# has to come back out here.
	x -= m.z
	var a: float = TEXT_ALPHA[clampi(style, 0, 2)] * _ea
	var size: int = _hud_font_size(fi)
	draw_string(f, Vector2(floor(x), floor(y) + f.get_ascent(size)), text,
			HORIZONTAL_ALIGNMENT_LEFT, -1, size, Color(rgb.r, rgb.g, rgb.b, a))

# --- dev: `-- --menushot` -----------------------------------------------------
# --hudshot walks the five full-screen elements; nothing screenshotted the arrow
# menu itself, which is the one HUD element whose fonts we had to guess at. This
# walks the root, a submenu and a carousel and writes one PNG each, then quits.
var _mshot_i := -2
var _mshot_t := 0.0
const MENU_SHOTS := ["hud_menu_menu", "hud_menu_nav", "hud_menu_comms",
		"hud_menu_autopilot"]

func _menushot_step(d: float) -> void:
	if _mshot_i == -2:
		_mshot_i = -1 if "--menushot" in OS.get_cmdline_user_args() else -3
		return
	if _mshot_i == -3:
		return
	_mshot_t += d
	if _mshot_i == -1:
		if _mshot_t > 1.5:
			_mshot_i = 0
			_mshot_t = 0.0
			menu_active = true
			menu_focus = MENU_SHOTS[0]
			menu_time = 8.4  # under 10 s, so the root shows its TIME readout
		return
	if _mshot_t < 0.8:
		return
	var img := get_viewport().get_texture().get_image()
	var dir: String = main._base().path_join("build/shots")
	DirAccess.make_dir_recursive_absolute(dir)
	img.save_png(dir.path_join("menu_%s.png" % MENU_SHOTS[_mshot_i]))
	print("MENUSHOT ", MENU_SHOTS[_mshot_i])
	_mshot_i += 1
	_mshot_t = 0.0
	if _mshot_i >= MENU_SHOTS.size():
		get_tree().quit()
		return
	menu_active = true
	menu_focus = MENU_SHOTS[_mshot_i]
	menu_time = 8.4

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
	# @element icHUDTargetMFD
	# Draw = 0x10101730 (recovered from raw bytes -- Ghidra dropped it over the
	# mode jumptable at 0x10101b20). Mode select is FUN_10102930: no target ->
	# mode 0, unidentified -> 1, category 4 (waypoint) or a sim with a class
	# icon -> 3, category 0xc (cargo pod) -> 4, anything else -> 2. Our
	# contacts are always identified and we simulate no cargo pods, so modes
	# 1 and 4 stay dormant (mode 4's UCP barcode bands are implemented below
	# and light up if a "cargo" category ever appears).
	var mode := 0
	var tname := ""
	var ttype := ""
	var tcat := ""
	if main.target_ai != null and is_instance_valid(main.target_ai):
		mode = 2
		tname = str(main.target_ai.display_name)
		ttype = str(main.target_ai.ctype)
	elif main.target_idx >= 0:
		var t: Dictionary = main.objects[main.target_idx]
		tcat = str(t["category"])
		tname = str(t["name"])
		ttype = str(t.get("type", ""))
		match tcat:
			"lpoint", "waypoint":
				mode = 3
			"cargo":
				mode = 4
			_:
				mode = 2
	var r := _mfd_begin(mode)
	match mode:
		0:
			# hud_target_no_target; the mode's extra draw (FUN_100bb300) is a
			# literal no-op -- just the short block and its caption
			_panel(r.position, r.size, "NO TARGET")
			target_view.enabled = false
		3:
			# hud_target_waypoint_mode; short block with the contact's class
			# icon at (16,32): the glyph (FUN_100e86d0: 47 waypoint, 60
			# L-point), then its overlay (0x2f/0x3c -> 0x2e), then roundel 0x33
			_panel(r.position, r.size, "NAVIGATION LOCK")
			target_view.enabled = false
			var icon := 60 if tcat == "lpoint" else 47
			var icol := _contact_color(false, tcat)
			var ip := r.position + Vector2(16, 32)
			_spr(ip, icon, icol)
			_spr(ip, 46, icol)
			_spr(ip, 51, icol)
			# line 2 is hud_target_waypoint_details = "WAYPOINT" for both
			_mfd_text(r, tname.to_upper(), "WAYPOINT", 32.0)
		_:
			var caption := "UCP SCAN" if mode == 4 else "TARGET LOCK"
			_panel(r.position, r.size, caption)
			# the model viewport spans the body between header and text rows
			# (mode 5's backing quad pins it at y 16..144; the exact viewport
			# insets for modes 2/4 were not recovered -- ftol()s the decompiler
			# elided -- so ours is the same band, inset by the panel border)
			var feed := Rect2(r.position + Vector2(BORDER, HDR_H),
					Vector2(r.size.x - 2.0 * BORDER, 128.0))
			var has_model := target_view.show_avatar(main.target_avatar())
			target_view.enabled = has_model
			if has_model:
				draw_texture_rect(target_view.get_texture(), feed, false,
						_dim(Color(1, 1, 1, 1)))
			else:
				_mfd_fallback_cube(feed)
			if mode == 4:
				_draw_ucp_bands(r)
			_mfd_sub_lines(r)
			# the hull bar: FUN_10101c80 draws the shared segmented bar
			# (FUN_100ebde0, style 1) at x=1, length 2*16-3 = 29 -> 5 segments,
			# at y = 16*9.5 = 152 (_DAT_1011e284), coloured by the damage ramp.
			# (With a targeted subsystem the first bar shows the subsystem and
			# the hull moves to y = 16*10.5 = 168 (_DAT_1011e280) -- we have no
			# subsystem targeting, so only the hull bar is drawn.)
			if main.target_ai != null and is_instance_valid(main.target_ai):
				var thull: float = clampf(
						main.target_ai.hull / main.target_ai.hull_max, 0.0, 1.0)
				_bar(r.position + Vector2(1, 152), thull, _health_color(thull), 5)
			_mfd_text(r, tname.to_upper(), ttype.to_upper(),
					32.0 if mode == 2 else 0.0)
	_ea = 1.0

func _mfd_fallback_cube(feed: Rect2) -> void:
	# no avatar for this contact: our placeholder wireframe box (not from the
	# binary -- the original always has the sim's avatar to render)
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
				_dim(Color(GREEN.r, GREEN.g, GREEN.b, 0.7)), 1.0, true)

func _mfd_sub_lines(r: Rect2) -> void:
	# FUN_10103060's tail: the target-designator lines over the model view.
	# this+0xb4 starts at 1 on a target change and decays at 1.5/s
	# (_DAT_1011a268); two vertical and two horizontal lines sweep in from the
	# body edges (x 0/128, y 16/144) toward the anchor -- the targeted
	# subsystem's projected position, or the fixed point (64, 96)
	# (16*_DAT_101190b4, 16*_DAT_101183f0 + 16) when none -- then, with no
	# subsystem, the parameter keeps going to -1 so they sweep back OUT and
	# vanish. The far end of each line fades to alpha 0.25 (_DAT_101191ec).
	if _mfd_sub <= -1.0:
		return
	_mfd_sub = maxf(_mfd_sub - get_process_delta_time() * MFD_SUB_RATE, -1.0)
	var t := absf(_mfd_sub)
	var o := r.position
	var ax := 64.0
	var ay := 96.0
	var x1 := lerpf(ax, 0.0, t)
	var x2 := lerpf(ax, 128.0, t)
	var y1 := lerpf(ay, 16.0, t)
	var y2 := lerpf(ay, 144.0, t)
	var full := _dim(Color(GREEN.r, GREEN.g, GREEN.b, 1.0))
	var faint := _dim(Color(GREEN.r, GREEN.g, GREEN.b, 0.25))
	for seg in [[Vector2(x1, 16), Vector2(x1, 144)],
			[Vector2(x2, 16), Vector2(x2, 144)],
			[Vector2(0, y1), Vector2(128, y1)],
			[Vector2(0, y2), Vector2(128, y2)]]:
		draw_polyline_colors(PackedVector2Array([o + seg[0], o + seg[1]]),
				PackedColorArray([full, faint]), 1.0, true)

func _draw_ucp_bands(r: Rect2) -> void:
	# FUN_10101f00's tail, the UCP-scan effect: two 16px bands of
	# images/hud/ucp.png (a barcode: digits in the top half, bars in the
	# bottom) counter-scrolling across the top of the body. The phase
	# (this+0xd0) advances at 0.2/s (_DAT_1011e248); the bar half (v 0.5..1)
	# occupies y 16..32 with u from -phase/2 to 0.5 - phase/2, and the digit
	# half (v 0..0.5) occupies y 32..48 with u from +phase to 0.5 + phase.
	# Chartreuse, alpha = 0.25 * master (_DAT_101191ec).
	if _ucp_tex == null:
		return
	_ucp_phase += get_process_delta_time() * UCP_SCROLL
	var col := _dim(Color(GREEN.r, GREEN.g, GREEN.b, 0.25))
	var w := r.size.x
	var tw := float(_ucp_tex.get_width())
	var th := float(_ucp_tex.get_height())
	# draw via source-rect scroll; wrap the phase into the texture
	var u_bars := fposmod(-0.5 * _ucp_phase, 1.0)
	var u_digits := fposmod(_ucp_phase, 1.0)
	for band in [[u_bars, 0.5, 16.0], [u_digits, 0.0, 32.0]]:
		var u: float = band[0]
		var v: float = band[1]
		var y: float = band[2]
		# split into two blits when the 128px window crosses the wrap seam
		var x := 0.0
		while x < w:
			var span := minf(w - x, tw * (1.0 - u))
			draw_texture_rect_region(_ucp_tex,
					Rect2(r.position + Vector2(x, y), Vector2(span, 16.0)),
					Rect2(u * tw, v * th, span, th * 0.5), col)
			x += span
			u = 0.0

func _draw_weapon_panel() -> void:
	# icHUDWeapons: 112 wide, 16px header + 32px per weapon in the selected group.
	# Each row is a lightning sprite at x=16, a 14-segment charge bar at x=36
	# (length 74), and a "%d%%" readout. Header is the weapon's own name.
	_ea = _flash_a("icHUDWeapons")
	var rows: int = 2 if "/" in str(main.weapon_name) else 1
	# One extra row for the selected secondary (missile magazine). The engine's
	# element shows the SELECTED GROUP's weapons one per row; the ammo-count
	# readout text is ours (the magazine row's exact layout was not recovered).
	var sec := str(main.secondary_name)
	var sec_row: int = 1 if sec != "NONE" else 0
	# the MFD above may be in a short mode; the stack advance uses its height
	var pos := Vector2(_left_x(), _advance(MARGIN, _mfd_rect().size.y))
	var size := Vector2(PANEL_W, ROW_PITCH * (rows + sec_row) + HDR_H)
	_panel(pos, size, str(main.weapon_name).to_upper())
	var charge: float = 1.0
	if main.weapons != null:
		charge = 1.0 - main.weapons.cooldown / main.weapons.refire
	for i in rows:
		var ry := pos.y + HDR_H + i * ROW_PITCH
		var lp := Vector2(pos.x + 16, ry + 16)
		draw_colored_polygon(PackedVector2Array([
			lp + Vector2(3, -8), lp + Vector2(-4, 1), lp + Vector2(-1, 1),
			lp + Vector2(-3, 8), lp + Vector2(4, -1), lp + Vector2(1, -1)]),
			_dim(AMBER))
		_bar(Vector2(pos.x + 36, ry + 10), charge, AMBER)
		draw_string(_font, Vector2(pos.x + 36, ry + 28), "%d%%" % int(charge * 100),
				HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE - 2, _dim(AMBER))
	if sec_row > 0:
		var ry := pos.y + HDR_H + rows * ROW_PITCH
		draw_string(_font, Vector2(pos.x + 16, ry + 20), sec,
				HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE - 2, _dim(AMBER))
	_ea = 1.0

# --- system status lights (top-centre) --------------------------------------
# @element icHUDShipStatus
#
# Draw = FUN_100fabd0 @ 0x100fabd0. It reads the screen size off the icHUD
# (this+0x18, +0x14 / +0x18) and calls
#
#     FUN_100fac60(x = screen_w * 0.5, y = 14.0, avail = screen_w - 320)
#                                    ^0x41600000        ^_DAT_1011e174
#
# FUN_100fac60 @ 0x100fac60 IS the element. Verbatim:
#
#     n_max = ftol((avail - 2 * SPR[76].w) / 6)   # _DAT_1011cbd0 = 1/6
#     n     = min(*(int*)(icShip + 0x138), n_max) # the component count
#     w     = n * 6                               # _DAT_1011a1a0 = 6, the pitch
#     x     = cx - w * 0.5
#     colour = chartreuse (DAT_10176038), alpha = master
#     FUN_100eaf90(x, y, w, 0, 76, 77)            # the rails, at HALF alpha
#     x -= 1                                      # _DAT_101171f0
#     for each component:
#         <colour = the damage ramp>   sprite 16, flags 0   # lamp ABOVE  y
#         <colour = blue * power>      sprite 16, flags 2   # lamp BELOW  y
#         x += 6
#
# So it is not eight labelled bars for eight groups: it is ONE LAMP PAIR PER
# MOUNTED SUBSIM, on a 6px pitch, damage over power, exactly as the manual says.
# The lamp is sprite 16 (a 9x11 round glow, origin 0,9) blitted twice from the
# same cell, the second one Y-mirrored about the anchor -- so the pair straddles
# y = 14 and the rails (18px apart) frame it.
const STATUS_Y := 14.0        # 0x41600000, pushed by the Draw
const STATUS_PITCH := 6.0     # _DAT_1011a1a0
const STATUS_MARGIN := 320.0  # _DAT_1011e174: the strip may use screen_w - 320
const STATUS_CAP := 76        # sprite: the strip's end chevron (9x18)
const STATUS_RAIL := 77       # sprite: its top and bottom rails
const STATUS_LAMP := 16       # sprite: one lamp
const STATUS_BLINK := 0.002   # _DAT_1011dfd0: frac(game_ms * 0.002) > 0.5
# DAT_10174190/94/98 = (0.3, 0.6, 1.0). The power lamp's colour is that blue
# SCALED BY the power fraction, so an unpowered lamp is literally black.
const POWER_COL := Color(0.3, 0.6, 1.0, 1.0)

class StatusLights extends Control:
	var hud: Hud
	func _process(_d: float) -> void:
		queue_redraw()
	func _draw() -> void:
		if hud != null and hud.hud_up():
			hud.draw_ship_status(self)

var _status_fx: StatusLights

func _power_ratios() -> Array:
	# The lamps need each subsim's power SATISFACTION, which the engine keeps on
	# the sim: iiShipSystem::Simulate (0x1003bd53) computes
	#     drain = (usage * 0.75 + 0.25) * power   # +0x74, +0x44
	#     got   = icShip::UsePower(drain)
	#     +0x70 = (got / drain) * power
	# and the HUD reads +0x70 / +0x44, i.e. got/drain. ship_systems.gd runs the
	# same distribution but does not keep the ratio, so it is recomputed here,
	# read-only, in the same mount order off the same stored usage/power -- not
	# approximated.
	var out: Array = []
	var sys: ShipSystems = main.sys
	var pool := 0.0
	var has_reactor := false
	for s: Dictionary in sys.systems:
		if s["class"] == "icReactor":
			has_reactor = true
			if not bool(s["destroyed"]):
				pool += float(s.get("charge", 0.0))
	if not has_reactor:
		pool = ShipSystems.NO_POWERPLANT_POOL
	for s: Dictionary in sys.systems:
		var r := 1.0
		var p := float(s["power"])
		if p > 0.0 and not bool(s["destroyed"]) and not _disrupted(s):
			var drain: float = (float(s["usage"]) * ShipSystems.DRAIN_USAGE
					+ ShipSystems.DRAIN_BASE) * p
			var got: float = minf(drain, pool)
			pool -= got
			r = 0.0 if drain <= 0.0 else clampf(got / drain, 0.0, 1.0)
		out.append(r)
	return out

func _disrupted(s: Dictionary) -> bool:
	# icShip::Disrupt raises subsim flag 0x10; FUN_100fac60 reads that bit FIRST
	# and randomises BOTH lamps while it is set (amber * rand for the damage
	# lamp, rand for the power lamp) -- the strip hashes.
	var sys: ShipSystems = main.sys
	if sys == null or sys.disrupt_time <= 0.0:
		return false
	return sys.disrupt_full or s.has("lda")

func draw_ship_status(ci: CanvasItem) -> void:
	if main.sys == null or main.sys.systems.is_empty():
		return
	var s := _screen()
	var avail: float = s.x - STATUS_MARGIN
	var n_max: int = int((avail - 2.0 * float(SPR[STATUS_CAP][2])) / STATUS_PITCH)
	var comps: Array = main.sys.systems
	var n: int = mini(comps.size(), maxi(n_max, 0))
	if n <= 0:
		return
	var w: float = float(n) * STATUS_PITCH
	var y := STATUS_Y
	var x: float = s.x * 0.5 - w * 0.5
	_hbar(ci, x, y, w, STATUS_CAP, STATUS_RAIL,
			Color(GREEN.r, GREEN.g, GREEN.b, 0.5))
	x -= 1.0
	# the flash: 2 Hz, 50% duty. A damaged subsim's damage lamp and an
	# under-supplied subsim's power lamp are drawn a SECOND time on the on-phase,
	# which under the additive blend doubles their brightness.
	var flash: bool = fposmod(float(Time.get_ticks_msec()) * STATUS_BLINK, 1.0) > 0.5
	var ratios := _power_ratios()
	for i in n:
		var c: Dictionary = comps[i]
		var dis := _disrupted(c)
		var hp_max := float(c["hp_max"])
		var hp := float(c["hp"])
		var p := Vector2(x, y)
		# --- the damage lamp (sprite 16 upright: it sits ABOVE the anchor) ----
		var dcol := Color(0, 0, 0, 1)
		if dis:
			var r := randf()
			dcol = Color(AMBER.r * r, AMBER.g * r, AMBER.b * r, 1.0)
		elif hp < 0.0:
			dcol = Color(0, 0, 0, 1)          # flag 0x08: hit points below zero
		elif hp_max == 0.0:
			dcol = Color(GREEN.r, GREEN.g, GREEN.b, 1.0)  # cannot be damaged
		else:
			var f: float = hp / hp_max
			dcol = Color(0, 0, 0, 1) if f <= 0.0 else _health_color(f)
			dcol.a = 1.0
		_spr(p, STATUS_LAMP, dcol, 0.0, 0, ci)
		if hp < hp_max and flash:
			_spr(p, STATUS_LAMP, dcol, 0.0, 0, ci)
		# --- the power lamp (the same cell, Y-mirrored: BELOW the anchor) -----
		var v := 1.0
		if dis:
			v = randf()
		elif bool(c["underpowered"]) or bool(c["destroyed"]):
			v = 0.0                           # flag 0x04: supply <= 0.25
		elif float(c["power"]) > 0.0:
			v = float(ratios[i])
		var pcol := Color(POWER_COL.r * v, POWER_COL.g * v, POWER_COL.b * v, 1.0)
		_spr(p, STATUS_LAMP, pcol, 0.0, 2, ci)
		if v < 1.0 and flash:
			_spr(p, STATUS_LAMP, pcol, 0.0, 2, ci)
		x += STATUS_PITCH

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
			"station", "gunstar":
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
	_ea = _flash_a("icHUDOrbRadar")
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
	var ring := _dim(Color(0.55, 0.85, 0.3, 0.9))
	draw_arc(c, r, 0, TAU, 48, ring, 1.6, true)
	_ellipse(c, Vector2(r, r * 0.35), Color(ring.r, ring.g, ring.b, ring.a * 0.55))
	_ellipse(c, Vector2(r * 0.35, r), Color(ring.r, ring.g, ring.b, ring.a * 0.30))
	draw_line(c + Vector2(0, -r - 8), c + Vector2(0, r + 8),
			_dim(Color(1.0, 0.75, 0.15, 0.85)), 2.0, true)
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
		draw_line(sp, tip, _dim(col * Color(1, 1, 1, 0.75)), 2.4, true)
		# blob contact: soft halo under a bright core, like the reference
		draw_circle(tip, 4.5, _dim(Color(col.r, col.g, col.b, 0.30)))
		if entry[2] and blink:
			draw_circle(tip, 3.2, _dim(Color(1, 1, 1, 0.95)))
		else:
			draw_circle(tip, 2.6, _dim(col))
	_ea = 1.0  # the clock is its own element (icHUDClock); it never flashes
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

# --- shields (right, above the contact list) ---------------------------------
# @element icHUDShields
#   Draw = FUN_100fa540, vtable 0x1011e114 slot 9. Right-anchored (the ctor at
#   0x100fa470 passes 1 to the block base), 112 wide, 16px header + 32px per row,
#   header hud_shield_status = "SHIELD STATUS". With NO shields fitted the block
#   is set to height 0 and the panel disappears entirely (FUN_100e2540(this,112,0)).
#
#   The class it filters the component list on -- DAT_10167e5c, the open question
#   in the old notes -- is **icPlayerLDA** (registered @ 0x100ac7a0). So this is
#   the LDA panel, and it CAPS AT TWO ROWS (cmp esi,2 @ 0x100fa596). icAILDA is a
#   sibling under iiLDA rather than a subclass, so an AI shield never shows here.
#
#   Per row: a lightning sprite (69) at x = 112-16 = 96, a 14-segment charge bar
#   at x=2 of length 74, and a status word at x = 112-36 = 76.
#     * working, charge >= min_energy * capacity : bar, no word (see below)
#     * working, charge <  min_energy * capacity : "OFFLINE"
#     * broken                                   : the row FLASHES at 2 Hz
#       (frac(t) vs 0.5, 0x10119458 / 0x10117738) and reads "DESTROYED" (sprite
#       31) or "OFFLINE" (sprites 63/65), by the subsim's flag bits at +0x68.
#   UNKNOWN: the original also prints "TRACKING" when charged AND icPlayerLDA
#   +0xa0 is non-zero. What writes +0xa0 was not traced, so we draw the
#   charged-and-+0xa0-zero case -- bar, no word -- rather than invent the gate.
const SHIELD_FLASH_HZ := 2.0   # 0.001 ms->s @ 0x10119458, vs 0.5 @ 0x10117738

func _draw_shield_panel() -> void:
	if main.sys == null:
		return
	var rows: Array = main.sys.shield_rows()
	if rows.is_empty():
		return   # height 0: the panel vanishes
	_ea = _flash_a("icHUDShields")
	var size := Vector2(PANEL_W, ROW_PITCH * rows.size() + HDR_H)
	var pos := Vector2(_right_x(PANEL_W), MARGIN)
	_panel(pos, size, "SHIELD STATUS")
	var flash: bool = fposmod(float(Time.get_ticks_msec()) * 0.001, 1.0) < 0.5
	for i in rows.size():
		var row: Dictionary = rows[i]
		var ry := pos.y + HDR_H + i * ROW_PITCH
		var broken: bool = not bool(row["working"])
		if broken and not flash:
			continue
		var col := RED if broken else AMBER
		# the lightning sprite, at x = PANEL_W - 16
		var lp := Vector2(pos.x + PANEL_W - 16, ry + 16)
		draw_colored_polygon(PackedVector2Array([
			lp + Vector2(3, -8), lp + Vector2(-4, 1), lp + Vector2(-1, 1),
			lp + Vector2(-3, 8), lp + Vector2(4, -1), lp + Vector2(1, -1)]),
			_dim(col))
		if not broken:
			_bar(Vector2(pos.x + 2, ry + 10), float(row["frac"]), AMBER)
		var word := ""
		if bool(row["destroyed"]):
			word = "DESTROYED"
		elif broken or bool(row["offline"]):
			word = "OFFLINE"
		if not word.is_empty():
			draw_string(_font, Vector2(pos.x + PANEL_W - 36, ry + 17), word,
					HORIZONTAL_ALIGNMENT_RIGHT, -1, FONT_SIZE - 4, _dim(col))
	_ea = 1.0


# --- contact list (lower-right) ---------------------------------------------
# @element icHUDContactList
#   Draw = FUN_100e4440. Six rows, 16px pitch, sorted by range ascending.

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
	_ea = _flash_a("icHUDContactList")
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
	draw_rect(Rect2(pos, Vector2(w, h)), _dim(Color(0.0, 0.05, 0.0, 0.55)))
	draw_rect(Rect2(pos, Vector2(w, h)),
			_dim(Color(GREEN.r, GREEN.g, GREEN.b, 0.25)), false, 1.0)
	# scrollbar, only once the list overflows (alpha 0.3, _DAT_1011c034)
	if all.size() > CL_ROWS:
		var frac := float(CL_ROWS) / float(all.size())
		var track := h - 4.0
		var top := pos.y + 2.0 + track * (float(off) / float(all.size()))
		draw_rect(Rect2(pos.x + 2.0, top, 4.0, track * frac),
				_dim(Color(GREEN.r, GREEN.g, GREEN.b, 0.3)))
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
				HORIZONTAL_ALIGNMENT_LEFT, -1, num_size, _dim(col))
		y += CL_ROW_H
	_ea = 1.0

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
