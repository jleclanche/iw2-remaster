class_name HudScreens
extends Control
# The five icHUD elements that derive from iiHUDMenuElement and therefore open
# as a full-screen overlay rather than drawing into the flight HUD. They are
# reached either through the arrow-key menu (icHUDMenuReticle, see hud.gd) or
# through their direct keys in configs/default.ini:
#
#   [HUD.Engineering] Shift+E   [HUD.Starmap]    Shift+M
#   [HUD.Log]         Shift+L   [HUD.Objectives] Shift+O
#   [HUD.Statistics]  Shift+S
#
# Every one of them registers with FcRegistry under a base of
# iiHUDMenuElement and puts its hud.csv menu key in the object at +0xc; that
# key is what ihud.CurrentMenuNode reports while the screen is up
# (IHUDMenuFocusName, 0x100f5040).
#
# The shared frame -- RESOLVED from raw bytes (iiHUDMenuElement::Draw @
# 0x100f1400 was a jumptable casualty). The Draw itself is thin: it calls the
# element's body virtual (vtable slot 14, +0x38), then draws the mouse
# crosshair cursor when active, then the in-screen comms overlay. The parts
# every screen shares are:
#  - FUN_100f1920, called first by every body draw: the CAPTION BAND -- a
#    translucent chartreuse quad from (16,16) to (screen_w - 16, 48)
#    (_DAT_101184a0 = 16), alpha = 0.25 * master (_DAT_101191ec), with the
#    localised caption drawn at (20, 19) (0x41a00000 / 0x41980000).
#  - a one-second fade-in per element (icHUDEngineering ramps this+0x58 to
#    _DAT_1011e330 = 1.0 and sets the master alpha to the ratio; icHUDStarmap
#    does the same with this+0x160 / _DAT_1011e180 = 1.0).
#  - the OPEN FLASH, drawn by icHUD itself (FUN_100de1a0 tail): for the first
#    0.5 s (_DAT_1011d814) after a menu element opens, the whole screen is
#    washed with 2px-pitch noise scanlines (FUN_100ec850 / FUN_100eca30) in
#    chartreuse * 0.9 (_DAT_1011951c), alpha (1 - t/0.5); after that the wash
#    alpha collapses to 0 (it returns only under damage flicker, pilot+0x74).
#
# THE PAGE. icHUDEngineering's body draw (0x10105d40) contains
# `cmp eax, 0x280 / cmp ecx, 0x1e0` -- it only draws its developer-mode debug
# rect when the framebuffer is exactly **640x480**, which is the resolution its
# absolute pixel coordinates are authored against (the TRI lands at
# (275,192)-(430,347), dead centre of a 640x480 page). The original pins that
# page to the top-left at any resolution; we CENTRE it (`_page()`), which is
# the one deliberate divergence here and keeps every recovered pixel offset
# exact. icHUDStarmap needs no page: its own projection is screen-centred.

var hud: Hud
var main: Node3D
const OPEN_FLASH_T := 0.5   # _DAT_1011d814
const FADE_T := 1.0         # _DAT_1011e330 / _DAT_1011e180
const PAGE := Vector2(640, 480)   # 0x280 x 0x1e0, from the eng body draw
var _open_t := 10.0
var _last_screen := ""

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	# flux.ini's [icHUD] element list puts the five menu elements at indices
	# 17..21 and the reticle at 11, so icHUD::Draw draws a menu screen OVER the
	# flight HUD. Our Hud is a sibling that draws after us, so lift us above it.
	z_index = 1

func _page() -> Vector2:
	# top-left of the 640x480 authoring page, centred in the viewport
	return ((get_viewport_rect().size - PAGE) * 0.5).floor()

func _process(d: float) -> void:
	if hud != null and hud.screen != _last_screen:
		_last_screen = hud.screen
		_open_t = 0.0
		if hud.screen == "hud_menu_map":
			_map_open()
	_open_t += d
	if hud != null and hud.screen == "hud_menu_map":
		_map_step(d)
	if hud != null and hud.screen == "hud_menu_eng":
		_eng_step(d)
	_hudshot_step(d)
	queue_redraw()

# Returns true when the key was consumed by the open screen.
func handle_key(key: int) -> bool:
	match hud.screen:
		"hud_menu_eng":
			return _eng_key(key)
		"hud_menu_map":
			return _map_key(key)
	return false

func _draw() -> void:
	if hud == null or main == null or hud.screen == "":
		return
	var size := get_viewport_rect().size
	# ours: dim the scene so the green text stays readable over bright space
	# (the original relies on its opaque body panels instead)
	draw_rect(Rect2(Vector2.ZERO, size), Color(0, 0.03, 0, 0.72))
	# the element's one-second fade-in (icHUDEngineering this+0x58)
	var fade := clampf(_open_t / FADE_T, 0.0, 1.0)
	# the caption band (FUN_100f1920): chartreuse quad (16,16)-(w-16,48) at
	# 0.25 alpha, caption text at (20,19)
	var captions := {
		"hud_menu_eng": "ENGINEERING",             # hud_menu_engineering
		"hud_menu_map": "STELLAR NAVIGATION OVERLAY",  # hud_map_caption
		"hud_menu_log": "MISSION LOG",             # hud_log_caption
		"hud_menu_objectives": "MISSION OBJECTIVES",   # hud_objectives_caption
		"hud_menu_score_table": "STATISTICS",      # hud_score_sheet_caption
	}
	var caption := str(captions.get(hud.screen, ""))
	draw_rect(Rect2(Vector2(16, 16), Vector2(size.x - 32.0, 32.0)),
			Color(Hud.GREEN.r, Hud.GREEN.g, Hud.GREEN.b, 0.25 * fade))
	draw_string(hud._font, Vector2(20, 19 + hud.FONT_SIZE), caption,
			HORIZONTAL_ALIGNMENT_LEFT, -1, hud.FONT_SIZE,
			Color(Hud.GREEN.r, Hud.GREEN.g, Hud.GREEN.b, fade))
	# the open flash: full-screen noise scanlines for the first 0.5 s
	var flash := 1.0 - _open_t / OPEN_FLASH_T
	if flash > 0.0:
		hud.scanlines(self, Rect2(Vector2.ZERO, size), flash,
				Color(Hud.GREEN.r * 0.9, Hud.GREEN.g * 0.9, Hud.GREEN.b * 0.9, 1.0))
	match hud.screen:
		"hud_menu_eng":
			_draw_engineering(fade)
		"hud_menu_map":
			_draw_starmap(fade)
		_:
			var body := Rect2(Vector2(60, 90), size - Vector2(120, 150))
			draw_rect(Rect2(body.position - Vector2(8, 34), body.size + Vector2(16, 42)),
					Hud.GREEN * Color(1, 1, 1, 0.5 * fade), false, 1.0)
			match hud.screen:
				"hud_menu_log":
					_draw_list(body, _log_entries())
				"hud_menu_objectives":
					_draw_objectives(body)
				"hud_menu_score_table":
					_draw_list(body, _score_entries())

# --- the sprite atlas --------------------------------------------------------
# hud.gd's SPR only carries the cells the flight HUD needs. These are the extra
# cells the two menu screens use, read out of the same table builder
# (0x100e6c60, which fills DAT_101741b0 stride 0x24 through
# FUN_100ee6b0(x, y, w, h, origin_x, origin_y, texture)); all are texture 0 =
# images/hud/sprites.png.
const SPR2 := {
	29: [132, 125, 32, 32, 16, 16],   # starmap header glyph (second slot)
	36: [198, 125, 32, 32, 16, 16],   # zoom-in arrow    (starmap, 0x24)
	37: [198, 158, 32, 32, 16, 16],   # zoom-out arrow   (starmap, 0x25)
	45: [66, 59, 32, 32, 16, 16],     # the TRI marker (a ragged ring)
	53: [198, 59, 32, 32, 16, 16],    # roundel: ring + disc
	60: [231, 226, 24, 24, 12, 12],   # L-point icon
	66: [99, 191, 32, 32, 16, 16],    # TRI axis 0 -- ship + engine plume
	67: [132, 191, 32, 32, 16, 16],   # TRI axis 1 -- ship + two beams firing
	68: [165, 191, 32, 32, 16, 16],   # TRI axis 2 -- ship + deflecting arc
}

func _spr(pos: Vector2, id: int, col: Color, rot := 0.0) -> void:
	# FUN_100e9de0(x, y, sprite, flags, rotation): the quad spans
	# [-origin, size - origin] about the anchor, at NATIVE atlas size.
	var tex: Texture2D = hud._sprites
	if tex == null or not SPR2.has(id):
		return
	var s: Array = SPR2[id]
	var sz := Vector2(float(s[2]), float(s[3]))
	var off := Vector2(-float(s[4]), -float(s[5]))
	var src := Rect2(float(s[0]), float(s[1]), sz.x, sz.y)
	if is_zero_approx(rot):
		draw_texture_rect_region(tex, Rect2(pos + off, sz), src, col)
		return
	draw_set_transform(pos, rot, Vector2.ONE)
	draw_texture_rect_region(tex, Rect2(off, sz), src, col)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

# --- icHUDEngineering: the TRI ------------------------------------------------
# @element icHUDEngineering
#
# ctor FUN_101059f0 / re-open FUN_10105c10; menu input slot 13 = FUN_10105c80;
# body draw slot 14 = FUN_10105d40, whose TRI half is FUN_10107710 (a Ghidra
# hole, recovered from raw bytes) and whose per-frame feed is FUN_10108890.
#
# THE THREE AXES ARE RESOLVED, four independent ways:
#
# 1. `iiShipSystem::TRIWeight()` (0x1003c170) returns
#    `m_tri_weights[ this+0x64 ]`, and `this+0x64` is an `iiShipSystem::eType`
#    set by each subsim's ctor. Base default is **3** (= no TRI). The overrides:
#      0  icDrive (0x10030da0), icThrusters (0x1003c590),
#         icCapsuleDrive (0x10030750), icLDSDrive (0x10036c50)
#      1  iiWeapon (0x1003c860), icMissileLauncher (0x10031450)
#      2  icAggressorShield (0x1002f290)
# 2. `icPlayerPilot::DistributePower` (0x100b00d0) maps the four power keys
#    straight onto `iiShipSystem::SetTRIPosition(a, b, c)`:
#      cmd 0x17 `PowerToOffensive` -> (0, 1, 0)   => axis 1 is OFFENSIVE
#      cmd 0x18 `PowerToDefensive` -> (0, 0, 1)   => axis 2 is DEFENSIVE
#      cmd 0x19 `PowerToDrive`     -> (1, 0, 0)   => axis 0 is DRIVE
#      cmd 0x1a `BalancePower`     -> (1/3, 1/3, 1/3)
#    (the command ids come from the FcInputMapper::Register table at 0x1451xx)
# 3. The three bar icons the screen itself draws are sprites 66 / 67 / 68, in
#    that row order: a ship with an engine plume, a ship firing two beams, a
#    ship behind a deflecting arc.
# 4. tri.png's three corner nodes carry those same three glyphs: the BOTTOM
#    apex is the plume, the TOP-LEFT node the beams, the TOP-RIGHT node the arc.
#
# So the TRI is DRIVE / OFFENSIVE / DEFENSIVE -- it was never POWER/REPAIR/HEAT.
#
# What it does: `SetTRIPosition` (0x1003c070) turns each 0..1 axis position into
# a multiplier applied to every subsim of that type --
#   x = pos * 3 - 1   (_DAT_10118490 = 3, _DAT_101171f0 = 1)
#   w = 1 + x * (0.5 * (max_tri_weight - 1))   for x > 0     (_DAT_10117738 = .5)
#   w = 1 + x * (1 - min_tri_weight)           for x < 0
# i.e. **weight = min_tri_weight at 0, 1.0 at 1/3, max_tri_weight at 1**, with
# min clamped to [0,1] and max to [1,3]; they are per-subsim INI properties.
# The consumers are iiWeapon::Range / ::RefireDelay (0x1000f090 / 0x1000f0a0),
# ::IsReadyToFire / ::Fire (0x10035120 / 0x100357e0), icLDSDrive::Simulate
# (0x10037040), the capsule drive (0x100305e0) and the aggressor shield
# (0x1002f900). TRIWeight returns a flat 1.0 for anything that is not the
# player's ship.
const TRI_QUAD := Vector2(275, 192)    # _DAT_1011e388 / _DAT_1011e394
const TRI_SIZE := 155.0                # _DAT_1011e390 (and the u/v span,
                                       # 0.60546875 * 256 = 155)
# the three node centres, measured off tri.png (quad-local px)
const TRI_NODE := [Vector2(74.5, 119.0), Vector2(20.5, 19.0), Vector2(127.5, 19.0)]
const TRI_SPR := [66, 67, 68]
const TRI_NAME := ["DRIVE", "OFFENSIVE", "DEFENSIVE"]
const BAR_X := 35.0                    # _DAT_1011e380
const BAR_Y := 212.0
const BAR_PITCH := 35.0                # _DAT_1011e380 again -- rows 212/247/282
const BAR_LEN := 217.0                 # 0x43590000
const RESET_Y := 317.0                 # 282 + 35, and the literal in FUN_10107710
const TRI_TRACK := 50.0                # _DAT_10163f10: marker chase, px/s
const TRI_SLOW := 0.15                 # _DAT_10163f08: bar ghost, /s
const TRI_FAST := 0.8                  # _DAT_10163f0c: marker ghost, /s
const TRI_JITTER := 0.02               # _DAT_1011e3b8
const TRI_JIT_HZ := [PI, 5.02655, 4.08407]   # _DAT_10119464 / _1011e3b4 / _1011e3b0

# iiShipSystem::m_tri_position -- the LIVE setting, the thing the ship reads.
# It is a CLASS STATIC in the original (0x1015bb94; SetTRIPosition, 0x1003c070,
# has no `this`), and the screen writes straight into it: the bar input calls
# SetTRIPosition at 0x101077d3 and RESET TRI calls it at 0x101092ff. So this
# screen does not own a TRI of its own -- it is a view onto the player's, which
# lives on ShipSystems (the IsPlayer gate on TRIWeight makes those the same
# thing). `tri` below is only the fallback for a hull with no fitted systems.
var _tri_local := [1.0 / 3.0, 1.0 / 3.0, 1.0 / 3.0]   # ctor: 0x3eaaaaab x3

var tri: Array:
	get:
		var s: ShipSystems = _sys()
		return s.tri if s != null else _tri_local
	set(value):
		_set_tri(value[0], value[1], value[2])

func _sys() -> ShipSystems:
	if main != null and main.sys != null:
		return main.sys as ShipSystems
	return null

func _set_tri(a: float, b: float, c: float) -> void:
	var s: ShipSystems = _sys()
	if s != null:
		s.set_tri_position(a, b, c)     # -> the live m_tri_weights
	else:
		_tri_local = [a, b, c]
# icHUDEngineering +0xcc and +0xdc: two followers of the live TRI at different
# rates. The bars are drawn from the slow one, the marker from the fast one --
# that is where the screen's lag and shimmer come from.
var _tri_slow := [1.0 / 3.0, 1.0 / 3.0, 1.0 / 3.0]
var _tri_fast := [1.0 / 3.0, 1.0 / 3.0, 1.0 / 3.0]
var _tri_mark := Vector2(-1, -1)                 # +0xe8/+0xec, chased at 50 px/s

# Six rows (this+0x54, wrapped 0..5 by FUN_10105c80), opening on row 5.
# Rows 1/2/3 are the TRI axes and row 4 is RESET TRI -- both PROVEN (FUN_10107710
# selects this+0xc0/+0xc4/+0xc8 for rows 1/2/3 and puts hud_engineering_resettri,
# key index 4 of the table at 0x10163e94, at (35, 317)). Rows 0 and 5 are NOT
# recovered: row 0 has an Enter handler (FUN_10106390(this, 4), through the
# dispatch table at 0x10163ec0) and row 5 has none. The labels below for those
# two, and their y positions, are OURS -- they just continue the recovered 35px
# pitch.
var eng_row := 5                                # ctor: this+0x54 = 5
const ENG_ROW0_Y := 177.0                       # OURS (212 - 35)
const ENG_ROW5_Y := 352.0                       # OURS (317 + 35)
var eng_iff := true                             # OURS: what row 0 toggles

func _eng_key(key: int) -> bool:
	# FUN_10105c80: menu cmd 0 = up, 1 = down, 2/3 = left/right, 4 = select,
	# 5 = cancel. Rows 1..3 take left/right into the TRI; row 4 resets it.
	match key:
		KEY_UP:
			eng_row = wrapi(eng_row - 1, 0, 6)
		KEY_DOWN:
			eng_row = wrapi(eng_row + 1, 0, 6)
		KEY_LEFT, KEY_RIGHT:
			var d: float = (0.04 if key == KEY_RIGHT else -0.04)
			if eng_row >= 1 and eng_row <= 3:
				_tri_shift(eng_row - 1, d)
		KEY_ENTER, KEY_KP_ENTER:
			if eng_row == 4:
				# FUN_101092f0 -> SetTRIPosition(1/3, 1/3, 1/3) @ 0x101092ff
				_set_tri(1.0 / 3.0, 1.0 / 3.0, 1.0 / 3.0)
			elif eng_row == 0:
				eng_iff = not eng_iff                    # FUN_10106390(this, 4)
			elif eng_row == 5:
				hud.screen = ""
		_:
			return false
	return true

func _tri_shift(idx: int, amount: float) -> void:
	# a TRI is a simplex: what one axis gains, the other two give up in
	# proportion, so the triple always sums to 1 (FUN_101081a0). The result goes
	# through SetTRIPosition, exactly as the screen does at 0x101077d3 -- which is
	# what makes the bars move the SHIP and not just the picture.
	var cur: Array = (tri as Array).duplicate()
	var want: float = clampf(float(cur[idx]) + amount, 0.0, 1.0)
	var give: float = want - float(cur[idx])
	var rest: float = 1.0 - float(cur[idx])
	if rest <= 0.0001:
		return
	for i in 3:
		if i != idx:
			cur[i] = maxf(0.0, float(cur[i]) - give * float(cur[i]) / rest)
	cur[idx] = want
	var total: float = float(cur[0]) + float(cur[1]) + float(cur[2])
	if total > 0.0:
		for i in 3:
			cur[i] = float(cur[i]) / total
	_set_tri(cur[0], cur[1], cur[2])

func _tri_chase(ghost: Array, rate: float, d: float) -> void:
	# FUN_10108890: the ghost walks toward the live TRI with a total budget of
	# rate*dt shared between the three axes in proportion to their errors.
	var e := [absf(float(ghost[0]) - float(tri[0])),
			absf(float(ghost[1]) - float(tri[1])),
			absf(float(ghost[2]) - float(tri[2]))]
	var sum: float = float(e[0]) + float(e[1]) + float(e[2])
	var budget := rate * d
	if sum <= budget or sum <= 0.0:
		for i in 3:
			ghost[i] = tri[i]
		return
	for i in 3:
		ghost[i] = move_toward(float(ghost[i]), float(tri[i]),
				(float(e[i]) / sum) * budget)

func _eng_step(d: float) -> void:
	_tri_chase(_tri_slow, TRI_SLOW, d)
	_tri_chase(_tri_fast, TRI_FAST, d)

func _tri_bary(w: Array) -> Vector2:
	# the marker is the barycentric mix of the three node centres. The original
	# solves a 2x2 system in a mirrored local frame and then maps it back with
	# an affine (FUN_10107710: x' = (155 - (x - 275)) * 0.85 + 281,
	# y' = (155 - (y - 192)) * 0.9 + 198); an affine map of a barycentric mix IS
	# the barycentric mix of the mapped corners, so this is the same point.
	var p := Vector2.ZERO
	for i in 3:
		p += (TRI_QUAD + TRI_NODE[i]) * float(w[i])
	return p

var _tri_tex: Texture2D
var _tri_loaded := false

func _draw_engineering(fade: float) -> void:
	if not _tri_loaded:
		_tri_loaded = true
		_tri_tex = Hud._load_mask(main._base(), "tri.png")
	var o := _page()
	var col := Color(Hud.GREEN.r, Hud.GREEN.g, Hud.GREEN.b, fade)
	var hot := Color(Hud.AMBER.r, Hud.AMBER.g, Hud.AMBER.b, fade)
	var t: float = Time.get_ticks_msec() / 1000.0

	# the track: tri.png drawn 1:1, (275,192)-(430,347), u/v 0..0.60546875
	if _tri_tex != null:
		draw_texture_rect_region(_tri_tex,
				Rect2(o + TRI_QUAD, Vector2(TRI_SIZE, TRI_SIZE)),
				Rect2(0, 0, TRI_SIZE, TRI_SIZE), col)

	# the three bars: x = 35, y = 212 / 247 / 282, length 217, icon 66/67/68.
	# Each carries the slow ghost as its fill and the fast ghost as a needle.
	for i in 3:
		var y := BAR_Y + BAR_PITCH * i
		var sel: bool = eng_row == i + 1
		var c: Color = hot if sel else col
		var v: float = float(_tri_slow[i])
		# the shimmer: while the ghost has caught up and the axis is off its
		# rails, the drawn value wobbles +/-0.02 (FUN_10107710)
		if v > 1e-6 and v < 0.999999:
			v = clampf(v + sin(t * TRI_JIT_HZ[i]) * TRI_JITTER, 0.0, 1.0)
		_spr(o + Vector2(BAR_X, y), TRI_SPR[i], c)
		var bx := o.x + BAR_X + 20.0
		var bw := BAR_LEN - 20.0
		draw_rect(Rect2(Vector2(bx, o.y + y - 5.0), Vector2(bw, 10.0)),
				Color(c.r, c.g, c.b, 0.25 * fade), false, 1.0)
		draw_rect(Rect2(Vector2(bx + 1.0, o.y + y - 4.0),
				Vector2((bw - 2.0) * v, 8.0)), Color(c.r, c.g, c.b, 0.55 * fade))
		var nx := bx + 1.0 + (bw - 2.0) * float(_tri_fast[i])
		draw_line(Vector2(nx, o.y + y - 6.0), Vector2(nx, o.y + y + 6.0), c, 1.5)
		# the original writes no text here at all -- the glyph IS the label, and
		# it is the same glyph as the tri.png corner it feeds. The readout above
		# each bar is ours, and it now carries the thing that actually matters:
		# the TRIWeight this axis is handing its subsims (min 0.5 at an empty
		# corner, 1.0 balanced, max 1.5 at a full one).
		var s: ShipSystems = _sys()
		var w: float = float(s.tri_weights[i]) if s != null else 1.0
		draw_string(hud._font_num, Vector2(bx, o.y + y - 10.0),
				"%s %d%%  x%.2f" % [TRI_NAME[i],
					int(round(float(tri[i]) * 100.0)), w],
				HORIZONTAL_ALIGNMENT_LEFT, -1, hud.num_size - 2, c)

	# the marker: sprite 45, chased toward the barycentre at 50 px/s, spinning
	# one revolution per 2 s (rot = frac(t_ms * 0.0005) * 2*PI)
	var want := _tri_bary(_tri_fast)          # page coords
	if _tri_mark.x < 0.0:
		_tri_mark = want
	_tri_mark = _tri_mark.move_toward(want, TRI_TRACK * get_process_delta_time())
	var rot: float = fposmod(Time.get_ticks_msec() * 0.0005, 1.0) * TAU
	_spr(o + _tri_mark, 45, hot, rot)

	# row 4: hud_engineering_resettri at (35, 317)
	draw_string(hud._font_num, o + Vector2(BAR_X, RESET_Y),
			"RESET TRI", HORIZONTAL_ALIGNMENT_LEFT, -1, hud.num_size,
			hot if eng_row == 4 else col)
	# rows 0 and 5: positions and labels OURS (see the note above)
	draw_string(hud._font_num, o + Vector2(BAR_X, ENG_ROW0_Y),
			"IFF       %s" % ("ENABLED" if eng_iff else "DISABLED"),
			HORIZONTAL_ALIGNMENT_LEFT, -1, hud.num_size,
			hot if eng_row == 0 else col)
	draw_string(hud._font_num, o + Vector2(BAR_X, ENG_ROW5_Y), "BACK",
			HORIZONTAL_ALIGNMENT_LEFT, -1, hud.num_size,
			hot if eng_row == 5 else col)

	# hud_engineering_ship / _hull and the subsim states, right of the track.
	# Their layout is not recovered; this column is ours.
	var x := o.x + TRI_QUAD.x + TRI_SIZE + 16.0
	var y2 := o.y + TRI_QUAD.y + 4.0
	draw_string(hud._font_num, Vector2(x, y2), "SHIP  %s"
			% str(main.ship.name).to_upper(),
			HORIZONTAL_ALIGNMENT_LEFT, -1, hud.num_size, col)
	y2 += float(hud.num_size) + 4.0
	draw_string(hud._font_num, Vector2(x, y2), "HULL  %3d%%"
			% int(round(main.hull / main.hull_max * 100.0)),
			HORIZONTAL_ALIGNMENT_LEFT, -1, hud.num_size, col)
	var states: Dictionary = main.system_states()
	for g: String in states.keys():
		var s: float = float(states[g])
		if s < 0.0:
			continue
		y2 += float(hud.num_size) + 2.0
		var hc: Color = hud._health_color(s)
		draw_string(hud._font_num, Vector2(x, y2), "%-4s  %3d%%"
				% [g, int(round(s * 100.0))],
				HORIZONTAL_ALIGNMENT_LEFT, -1, hud.num_size,
				Color(hc.r, hc.g, hc.b, fade))

# --- icHUDStarmap -------------------------------------------------------------
# @element icHUDStarmap
#
# Registration FUN_100fb1c0, factory FUN_100fb200 (size 0x1b8), ctor
# FUN_100fb260, vtable **0x1011e1d8**. The content virtuals are
#   slot 11 0x100fba50  (re-open)          slot 13 0x100fbc60  (menu input)
#   slot 12 0x100fbc20                     slot 14 0x100fbf50  (body draw)
#   slot 15 0x100fbce0                     slot 16 0x100fbf40
#
# THE STATE MACHINE (this+0x74), from the body draw 0x100fbf50 and the input
# dispatcher 0x100fbc60:
#   0  CLUSTER VIEW   input FUN_100fcd60
#   1  cluster -> system transition (zooming in)
#   2  SYSTEM VIEW    input FUN_100fce60
#   3  system -> cluster transition (zooming out)
#   4  a drilled-in local view    input FUN_100fd130  (NOT recovered)
# The two views are drawn by two renderers and CROSS-FADE through the zoom:
# FUN_100ff0a0 (cluster) runs whenever state != 2, FUN_100fda70 (system)
# whenever state != 0, and in states 1/3 the zoom's position between its limits
# is the blend: f = (zoom - 0.001) / (5.0 - 0.001)  (_DAT_1011e1a0 / DAT_1011e194);
# cluster alpha *= f, system alpha *= (1 - f). "Zoom in" DIVIDES the zoom value.
# So entering a system is one continuous dive down the cluster map until the
# system fills the screen -- not a page flip. FUN_100fcd60 case 0 sets state 1
# and multiplies the zoom TARGET by 0.001; FUN_100fce60 case 1 sets state 3 and
# multiplies it by 1000.0 (_DAT_1011e198).
#
# THE CLUSTER VIEW IS A REAL 2D CHART, and the data ships with the game.
# FUN_100ff0a0 projects each system as
#     sx = (sys.map_x - cam.x) * scale
#     sy = (sys.map_y - cam.y) * scale
# in a frame the body draw has already translated to the SCREEN CENTRE
# (FcGraphicsEngine::Push + a matrix whose translation is (w/2, h/2)), with
#     scale = min(screen_w, screen_h) * 0.45 / zoom       (FUN_100ff9f0,
#                                                          _DAT_1011e1a8 = 0.45)
# `sys.map_x/map_y` are icSolarSystem+0x624/+0x628, and icCluster::Load
# (0x10044360) reads them straight out of **geog/clusters.ini `map_coords[n]`**
# -- 16 systems with hand-placed chart positions, plus `label[n]` /
# `label_coords[n]` for the two cluster names. That file is the cluster map.
# Selecting a system re-centres the camera on it and parks the zoom at its
# maximum, 5.0 (FUN_100fda10).
#
# Per system: a sprite (additive, SetBlend 2) and its localised name 16px to the
# right, in amber (DAT_10174fb0), with the alpha carrying the save game:
#   1.0  selected, or the system you are in
#   0.7  visited before (_DAT_101191e8) -- the name is looked up in
#        icSaveGame's hash set
#   0.3  never visited (_DAT_1011c034)
# Jump links are drawn as lines (width 0.5, fade width 1.5) from the link table
# at this+0x9c. Mouse picking takes the nearest system within sqrt(144) = 12px
# (FUN_100ffb50 / _DAT_1011e234).
#
# NOT RECOVERED: the sprite id for a cluster node (the draw reads it out of a
# runtime list at this+0x90); we use the roundel, sprite 53. State 4. The system
# view's initial zoom -- FUN_100fda70 keeps it as a double and its start value
# is set in FUN_100fd440, which Ghidra dropped; we fit the system to the page.
const MAP_SCALE_K := 0.45     # _DAT_1011e1a8
const MAP_ZOOM_MAX := 5.0     # DAT_1011e194  -- the cluster view sits here
const MAP_ZOOM_MIN := 0.001   # _DAT_1011e1a0
const MAP_ZOOM_RATE := 5.0    # _DAT_1011e190
const MAP_PAN_RATE := 5.0     # _DAT_1011e190 again (camera chase)
const MAP_A_VISITED := 0.7    # _DAT_101191e8
const MAP_A_UNSEEN := 0.3     # _DAT_1011c034
const MAP_LABEL_DX := 16.0    # _DAT_101184a0

var map_state := 0            # this+0x74
var map_sel := 0              # this+0x78
var _map_zoom := MAP_ZOOM_MAX          # this+0xa0
var _map_zoom_to := MAP_ZOOM_MAX       # this+0xa4
var _map_cam := Vector2.ZERO           # this+0xa8/+0xac
var _map_cam_to := Vector2.ZERO        # this+0xb8/+0xbc
var _map_visited: Dictionary = {}      # stands in for icSaveGame's hash set
var _cluster_cache: Array = []
var _cluster_labels: Array = []
var _sys_sel := 0

func _cluster() -> Array:
	# geog/clusters.ini: system[n] + map_coords[n], and label[n] +
	# label_coords[n]. Parsed here rather than in main because nothing else
	# needs it.
	if not _cluster_cache.is_empty():
		return _cluster_cache
	var path: String = main._base().path_join("data/ini/geog/clusters.ini")
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return _cluster_cache
	var sys: Dictionary = {}
	var pos: Dictionary = {}
	var lab: Dictionary = {}
	var lpos: Dictionary = {}
	while not f.eof_reached():
		var line := f.get_line().strip_edges()
		if line.is_empty() or line.begins_with(";") or not "=" in line:
			continue
		var key := line.split("=")[0].strip_edges()
		var val := line.split("=", true, 1)[1].strip_edges()
		if not "[" in key:
			continue
		var idx := int(key.get_slice("[", 1).get_slice("]", 0))
		var name := key.get_slice("[", 0)
		if name == "system":
			var parts := val.split("/")
			sys[idx] = parts[parts.size() - 1]
		elif name == "label":
			lab[idx] = val
		elif name == "map_coords" or name == "label_coords":
			var n := val.replace("(", "").replace(")", "").split(",")
			if n.size() >= 2:
				var v := Vector2(float(n[0]), float(n[1]))
				if name == "map_coords":
					pos[idx] = v
				else:
					lpos[idx] = v
	var idxj: Dictionary = main._load_json("data/json/systems/_index.json")
	for i: int in sys.keys():
		if not pos.has(i):
			continue
		var stem: String = str(sys[i])
		var links: Array = []
		if idxj != null and idxj.has(stem):
			links = idxj[stem].get("links", [])
		_cluster_cache.append({"stem": stem, "pos": pos[i], "links": links})
	for i: int in lab.keys():
		if lpos.has(i):
			_cluster_labels.append({"text": str(lab[i]).replace("_", " ").to_upper(),
					"pos": lpos[i]})
	return _cluster_cache

func _map_open() -> void:
	var c := _cluster()
	if not c.is_empty():
		for i in c.size():
			if str(c[i]["stem"]) == main.system_stem:
				map_sel = i
		_map_visited[main.system_stem] = true
		var cp: Vector2 = c[map_sel]["pos"]
		_map_cam = cp
		_map_cam_to = cp
	map_state = 0
	_map_zoom = MAP_ZOOM_MAX
	_map_zoom_to = MAP_ZOOM_MAX

func _map_step(d: float) -> void:
	# FUN_100ff0a0's head: the zoom eases toward its target at a rate
	# proportional to how far out it already is, and the camera chases at
	# 5 * dist per second. Both are clamped at the minimum zoom.
	_map_zoom = maxf(_map_zoom, MAP_ZOOM_MIN)
	var rate: float = ((_map_zoom - MAP_ZOOM_MIN) * MAP_ZOOM_RATE
			+ MAP_ZOOM_MIN) * d
	_map_zoom = move_toward(_map_zoom, _map_zoom_to, rate)
	_map_cam = _map_cam.move_toward(_map_cam_to,
			maxf(_map_cam.distance_to(_map_cam_to), 0.0) * MAP_PAN_RATE * d)
	# the transitions settle when the zoom has arrived (0x100fbf50)
	if map_state == 1 and absf(_map_zoom - _map_zoom_to) < 1e-6:
		map_state = 2
	elif map_state == 3 and absf(_map_zoom - _map_zoom_to) < 1e-6:
		map_state = 0

func _map_scale() -> float:
	var s := get_viewport_rect().size
	return minf(s.x, s.y) * MAP_SCALE_K / maxf(_map_zoom, MAP_ZOOM_MIN)

func _map_key(key: int) -> bool:
	var c := _cluster()
	if c.is_empty():
		return false
	match key:
		KEY_UP:            # menu cmd 0: dive into the selected system
			if map_state == 0:
				map_state = 1
				_map_zoom_to = _map_zoom * MAP_ZOOM_MIN
				_map_visited[str(c[map_sel]["stem"])] = true
		KEY_DOWN:          # menu cmd 1: back out to the cluster
			if map_state == 2:
				map_state = 3
				_map_zoom_to = MAP_ZOOM_MAX
		KEY_LEFT:          # menu cmd 2
			if map_state == 0:
				map_sel = wrapi(map_sel - 1, 0, c.size())
				_map_cam_to = c[map_sel]["pos"]
				_map_zoom_to = MAP_ZOOM_MAX       # FUN_100fda10
			else:
				_sys_sel = maxi(0, _sys_sel - 1)
		KEY_RIGHT:         # menu cmd 3
			if map_state == 0:
				map_sel = wrapi(map_sel + 1, 0, c.size())
				_map_cam_to = c[map_sel]["pos"]
				_map_zoom_to = MAP_ZOOM_MAX
			else:
				_sys_sel += 1
		KEY_EQUAL, KEY_KP_ADD:          # hud_map_zoom_in  (key 0x24)
			_map_zoom_to = maxf(MAP_ZOOM_MIN, _map_zoom_to * 0.5)
		KEY_MINUS, KEY_KP_SUBTRACT:     # hud_map_zoom_out (key 0x25)
			_map_zoom_to = minf(MAP_ZOOM_MAX, _map_zoom_to * 2.0)
		_:
			return false
	return true

func _draw_starmap(fade: float) -> void:
	var c := _cluster()
	if c.is_empty():
		return
	map_sel = clampi(map_sel, 0, c.size() - 1)
	var size := get_viewport_rect().size
	var centre := (size * 0.5).floor()

	# the cross-fade (0x100fbf50)
	var a_cluster := 0.0 if map_state == 2 else 1.0
	var a_system := 0.0 if map_state == 0 else 1.0
	if map_state == 1 or map_state == 3:
		var f: float = clampf((_map_zoom - MAP_ZOOM_MIN)
				/ (MAP_ZOOM_MAX - MAP_ZOOM_MIN), 0.0, 1.0)
		a_cluster *= f
		a_system *= 1.0 - f
	a_cluster *= fade
	a_system *= fade

	if a_system > 0.0:
		_draw_map_system(centre, a_system)
	if a_cluster > 0.0:
		_draw_map_cluster(centre, c, a_cluster)

	# the two header glyphs, absolute (36,126) and (72,126), drawn after the
	# projection is popped. They blink while a zoom or a pan is still running:
	# alpha = (|frac(t * 0.0005) - 0.5| * 1.8 + 0.1) * master.
	var t: float = Time.get_ticks_msec()
	var blink: float = (absf(fposmod(t * 0.0005, 1.0) - 0.5) * 1.8 + 0.1) * fade
	var dim := Color(Hud.GREEN.r, Hud.GREEN.g, Hud.GREEN.b, fade)
	_spr(Vector2(36, 126), 53, Color(dim.r, dim.g, dim.b, fade * 0.5))
	_spr(Vector2(72, 126), 53, Color(dim.r, dim.g, dim.b, fade * 0.5))
	if absf(_map_zoom - _map_zoom_to) > 1e-6:
		# sprite 36 while zooming in, 37 while zooming out
		var s: int = 36 if _map_zoom > _map_zoom_to else 37
		_spr(Vector2(36, 126), s, Color(dim.r, dim.g, dim.b, blink))
	if _map_cam.distance_to(_map_cam_to) > 1e-6:
		_spr(Vector2(72, 126), 29, Color(dim.r, dim.g, dim.b, blink))

	# the three text lines. FUN_100eb270 puts two of them at x = 20, y = 60 and
	# y = 80; the third is drawn from the same block (Ghidra lost its call) and
	# we continue the 20px pitch at y = 40.
	var sel := str(c[map_sel]["stem"]).replace("_", " ").to_upper()
	var l0 := "CLUSTER VIEW" if map_state == 0 else \
			"SYSTEM VIEW: %s" % str(main.system_name).to_upper()
	var l1 := "SELECTED: %s" % sel
	var l2 := ""
	if map_state == 0:
		l2 = "JUMP DESTINATION: %s" % sel
	else:
		var objs := _map_objects()
		if not objs.is_empty():
			_sys_sel = wrapi(_sys_sel, 0, objs.size())
			l2 = "SELECTED: %s" % str(objs[_sys_sel]["name"]).to_upper()
	var tc := Color(Hud.GREEN.r, Hud.GREEN.g, Hud.GREEN.b, fade)
	draw_string(hud._font_num, Vector2(20, 60), l0,
			HORIZONTAL_ALIGNMENT_LEFT, -1, hud.num_size, tc)
	draw_string(hud._font_num, Vector2(20, 80), l1,
			HORIZONTAL_ALIGNMENT_LEFT, -1, hud.num_size, tc)
	draw_string(hud._font_num, Vector2(20, 100), l2,
			HORIZONTAL_ALIGNMENT_LEFT, -1, hud.num_size, Hud.AMBER * Color(1, 1, 1, fade))

func _draw_map_cluster(centre: Vector2, c: Array, alpha: float) -> void:
	var scale := _map_scale()
	var pos: Dictionary = {}
	for s: Dictionary in c:
		var sp: Vector2 = s["pos"]
		pos[str(s["stem"])] = centre + (sp - _map_cam) * scale
	# the jump links, amber, 0.5px (FcGraphicsEngine::SetLineWidth(0.5))
	var link_col := Color(Hud.AMBER.r, Hud.AMBER.g, Hud.AMBER.b, alpha * 0.5)
	var drawn: Dictionary = {}
	for s: Dictionary in c:
		var a := str(s["stem"])
		for l: String in s["links"]:
			var b := str(l).to_lower()
			if not pos.has(b):
				continue
			var k: String = a + "|" + b if a < b else b + "|" + a
			if drawn.has(k):
				continue
			drawn[k] = true
			draw_line(pos[a], pos[b], link_col, 1.0, true)
	# the nodes
	for i in c.size():
		var stem := str(c[i]["stem"])
		var p: Vector2 = pos[stem]
		var here: bool = stem == main.system_stem
		var a := MAP_A_UNSEEN
		if i == map_sel or here:
			a = 1.0
		elif _map_visited.has(stem):
			a = MAP_A_VISITED
		var col := Color(Hud.AMBER.r, Hud.AMBER.g, Hud.AMBER.b, a * alpha)
		_spr(p, 53, col)
		if here:
			draw_arc(p, 14.0, 0, TAU, 24, col, 1.0, true)
		draw_string(hud._font_num, p + Vector2(MAP_LABEL_DX, 5),
				stem.replace("_", " ").to_upper(), HORIZONTAL_ALIGNMENT_LEFT,
				-1, hud.num_size, col)
	# the cluster labels (clusters.ini label[n] / label_coords[n])
	for l: Dictionary in _cluster_labels:
		var lp: Vector2 = l["pos"]
		var p := centre + (lp - _map_cam) * scale
		draw_string(hud._font, p, str(l["text"]), HORIZONTAL_ALIGNMENT_LEFT,
				-1, hud.FONT_SIZE,
				Color(Hud.AMBER.r, Hud.AMBER.g, Hud.AMBER.b, 0.35 * alpha))

func _map_objects() -> Array:
	# imapentity.SetMapVisibility: the scripts hide and reveal entities on THIS
	# view (56 call sites -- stations you have not found, wrecks the plot has
	# not pointed you at). It scopes the map only: a hidden station still shows
	# on sensors and in the contact list, which is the whole point of hiding it.
	var out: Array = []
	for o: Dictionary in main.objects:
		if not bool(o.get("map_visible", true)):
			continue
		var cat := str(o["category"])
		if cat in ["star", "lpoint", "station", "planet", "body", "moon"]:
			out.append(o)
	return out

func _draw_map_system(centre: Vector2, alpha: float) -> void:
	# FUN_100fda70: the star sits at the origin, every body's orbit is a circle
	# (FcGraphicsEngine::DrawCircle) in amber at 0.5px, the route is drawn over
	# it at 2px, and the bodies are sprites. The zoom is a double here because
	# the radii are in metres. Its start value is not recovered -- we fit the
	# system to the page.
	var objs := _map_objects()
	if objs.is_empty():
		return
	_sys_sel = wrapi(_sys_sel, 0, objs.size())
	var size := get_viewport_rect().size
	var far := 1.0
	for o: Dictionary in objs:
		far = maxf(far, Vector2(float(o["x"]), float(o["z"])).length())
	var scale: float = minf(size.x, size.y) * MAP_SCALE_K / (far * 1.15)
	var amber := Color(Hud.AMBER.r, Hud.AMBER.g, Hud.AMBER.b, alpha)

	# orbits
	for o: Dictionary in objs:
		var r: float = Vector2(float(o["x"]), float(o["z"])).length() * scale
		if r > 4.0 and str(o["category"]) != "lpoint":
			draw_arc(centre, r, 0, TAU, 96,
					Color(amber.r, amber.g, amber.b, alpha * 0.25), 1.0, true)
	# the plotted route: our jump links out of this system, drawn from the star
	# to each L-point at 2px (FUN_100fda70 raises the line width for these)
	for o: Dictionary in objs:
		if str(o["category"]) != "lpoint":
			continue
		var p := centre + Vector2(float(o["x"]), float(o["z"])) * scale
		draw_line(centre, p, Color(amber.r, amber.g, amber.b, alpha * 0.4),
				2.0, true)
	# the bodies
	for i in objs.size():
		var o: Dictionary = objs[i]
		var p := centre + Vector2(float(o["x"]), float(o["z"])) * scale
		var cat := str(o["category"])
		var col := amber
		var id := 53
		match cat:
			"star":
				col = Color(Hud.GOLD.r, Hud.GOLD.g, Hud.GOLD.b, alpha)
			"lpoint":
				id = 60
				col = Color(Hud.GREEN.r, Hud.GREEN.g, Hud.GREEN.b, alpha)
			"station":
				col = Color(Hud.BLUE.r, Hud.BLUE.g, Hud.BLUE.b, alpha)
		if i == _sys_sel:
			col = Color(Hud.RED.r, Hud.RED.g, Hud.RED.b, alpha)
			draw_arc(p, 16.0, 0, TAU, 24, col, 1.5, true)
		_spr(p, id, col)
		draw_string(hud._font_num, p + Vector2(MAP_LABEL_DX, 5),
				str(o["name"]).to_upper(), HORIZONTAL_ALIGNMENT_LEFT, -1,
				hud.num_size, col)
	# the player
	var pp := centre + Vector2(main.px, main.pz) * scale
	draw_arc(pp, 6.0, 0, TAU, 16,
			Color(Hud.GREEN.r, Hud.GREEN.g, Hud.GREEN.b, alpha), 1.4, true)

# --- icHUDLog / icHUDObjectives / icHUDScore ---------------------------------
# @element icHUDLog
# @element icHUDObjectives
# @element-stub icHUDScore
#   The score sheet's statistics (kills, shots fired, credits earned) are not
#   tracked anywhere in our sim, so there is nothing to put on it. The screen
#   opens and says so rather than inventing numbers.

func _log_entries() -> Array:
	var out: Array = []
	for l: Dictionary in hud.log_lines:
		out.append(str(l["text"]))
	return out

func _score_entries() -> Array:
	return []

func _draw_objectives(body: Rect2) -> void:
	# hud_objectives_incomplete / _succeeded / _failed
	var rows: Array = []
	var objs: Dictionary = {}
	if main.mission != null:
		objs = main.mission.objectives
	for id: String in objs.keys():
		var o: Dictionary = objs[id]
		var done: bool = bool(o.get("done", false))
		rows.append(["COMPLETED: " if done else "INCOMPLETE: ",
				str(o.get("text", id)), done])
	if rows.is_empty():
		draw_string(hud._font, body.position + Vector2(0, 30), "NO ENTRIES",
				HORIZONTAL_ALIGNMENT_LEFT, -1, hud.FONT_SIZE, Hud.GREEN)
		return
	var y := body.position.y + 30.0
	for r: Array in rows:
		var col: Color = Hud.GREEN if bool(r[2]) else Hud.AMBER
		draw_string(hud._font, Vector2(body.position.x, y),
				"%s%s" % [r[0], r[1]], HORIZONTAL_ALIGNMENT_LEFT, -1,
				hud.FONT_SIZE, col)
		y += float(hud.FONT_SIZE) + 6.0

func _draw_list(body: Rect2, entries: Array) -> void:
	# hud_list_no_entries / hud_list_entry / hud_list_entries
	if entries.is_empty():
		draw_string(hud._font, body.position + Vector2(0, 30), "NO ENTRIES",
				HORIZONTAL_ALIGNMENT_LEFT, -1, hud.FONT_SIZE, Hud.GREEN)
		return
	var y := body.position.y + 30.0
	for e: String in entries:
		draw_string(hud._font, Vector2(body.position.x, y), e,
				HORIZONTAL_ALIGNMENT_LEFT, -1, hud.FONT_SIZE, Hud.GREEN)
		y += float(hud.FONT_SIZE) + 6.0
	draw_string(hud._font_num, body.end - Vector2(body.size.x, 8),
			"%d %s" % [entries.size(),
				"ENTRY" if entries.size() == 1 else "ENTRIES"],
			HORIZONTAL_ALIGNMENT_LEFT, -1, hud.num_size, Hud.GREEN)

# --- dev: `-- --hudshot` ------------------------------------------------------
# --uicheck never opens a menu element, so the five screens had no screenshot
# coverage at all. This walks them and writes one PNG each, then quits.
var _shot_i := -2
var _shot_t := 0.0
const SHOT_SCREENS := ["hud_menu_map", "hud_menu_eng", "hud_menu_log",
		"hud_menu_objectives", "hud_menu_score_table"]

func _hudshot_step(d: float) -> void:
	if _shot_i == -2:
		_shot_i = -1 if "--hudshot" in OS.get_cmdline_user_args() else -3
		return
	if _shot_i == -3 or hud == null:
		return
	_shot_t += d
	if _shot_i == -1:
		if _shot_t > 1.0:
			_shot_i = 0
			_shot_t = 0.0
			hud.screen = SHOT_SCREENS[0]
		return
	if _shot_t < 1.2:
		return
	var img := get_viewport().get_texture().get_image()
	var dir: String = main._base().path_join("build/shots")
	DirAccess.make_dir_recursive_absolute(dir)
	img.save_png(dir.path_join("hud_%s.png" % SHOT_SCREENS[_shot_i]))
	print("HUDSHOT ", SHOT_SCREENS[_shot_i])
	_shot_i += 1
	_shot_t = 0.0
	if _shot_i >= SHOT_SCREENS.size():
		get_tree().quit()
		return
	hud.screen = SHOT_SCREENS[_shot_i]
