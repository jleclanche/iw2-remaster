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
		# drop any latched menu direction across an open/close (icHUD clears
		# +0x1bc on the release it never gets to see while the screen is down)
		_menu_held = false
		_menu_down.clear()
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
	31: [165, 26, 32, 32, 16, 16],    # legend: CANCEL   (id 0x1f)
	34: [33, 92, 32, 32, 16, 16],     # legend: PREV     (id 0x22)
	35: [66, 92, 32, 32, 16, 16],     # legend: NEXT     (id 0x23)
	36: [198, 125, 32, 32, 16, 16],   # legend/indicator: ZOOM IN  (id 0x24)
	37: [198, 158, 32, 32, 16, 16],   # legend/indicator: ZOOM OUT (id 0x25)
	45: [66, 59, 32, 32, 16, 16],     # the TRI marker (a ragged ring)
	53: [198, 59, 32, 32, 16, 16],    # roundel: ring + disc (header glyph backing)
	# the four discs at atlas (0,125)/(33,125)/(0,158)/(33,158). Read out of the
	# table builder at 0x100e7783..0x100e7859 (`mov edi, 0x101741b0 + id*0x24`)
	# and eyeballed on the sheet:
	54: [33, 125, 32, 32, 16, 16],    # spoked disc  -- a STAR (type table [1] = 54)
	55: [0, 125, 32, 32, 16, 16],     # large plain disc
	56: [0, 158, 32, 32, 16, 16],     # ringed planet
	57: [33, 158, 32, 32, 16, 16],    # small plain disc
	60: [231, 226, 24, 24, 12, 12],   # L-point icon (type table [5] = 60)
	66: [99, 191, 32, 32, 16, 16],    # ship glyph: TRI axis 0, and the map's YOU-ARE-HERE
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

# --- the six rows, and how the keyboard actually drives them ------------------
#
# Six rows (this+0x54, wrapped 0..5 by the menu-input virtual FUN_10105c80),
# opening on row 5 (ctor 0x10105a23). ALL SIX ARE NOW RECOVERED:
#
#   0  SYSTEM SELECTOR   left/right cycle the ship's subsim list, Enter toggles
#   1  TRI axis DRIVE        \
#   2  TRI axis OFFENSIVE     >  left/right move the point WHILE HELD
#   3  TRI axis DEFENSIVE    /
#   4  RESET TRI         Enter -> SetTRIPosition(1/3, 1/3, 1/3)
#   5  REACTOR THROTTLE  left/right drag icReactor's ramp target WHILE HELD
#
# THE INPUT MODEL. There are TWO separate paths out of the arrow keys, and the
# TRI is on the second one -- which is why holding an arrow key did nothing here.
#
# (a) THE COMMAND PATH. configs/default.ini binds [HUD.MenuLeft|Right|Up|Down|
#     Select|Cancel] and icHUD registers them (FUN_100e1bf0) as commands
#     0 = up, 1 = down, 2 = left, 3 = right, 4 = select, 5 = cancel. The four
#     DIRECTIONS register with flags **0x103**, select/cancel with 3. Those flags
#     are read by flux's button dispatcher FUN_10075010, whose event mask is
#         1 = pressed   2 = released   4 = held (every frame)   0x100 = repeat
#     so 0x103 = press | release | AUTO-REPEAT: after m_initial_delay the key
#     re-fires every m_repeat_period (flux.ini: initial_delay 0.5, repeat_period
#     0.08). Each such event reaches the focused element's slot 13 (0x10105c80).
#     FUN_10105c80 handles cmd 0/1 itself (step the row), cmd 4 (Enter: row 0 ->
#     FUN_10106390, row 4 -> FUN_101092f0 = RESET TRI) and cmd 5 (close), and
#     hands LEFT/RIGHT to a PER-ROW dispatch table at 0x10163ec0 -- whose ONLY
#     non-null entry is row 0's (FUN_10106390). So on the TRI rows the command
#     path does NOTHING AT ALL. Nothing steps the point.
#
# (b) THE HELD-KEY PATH -- this is the one that moves the TRI. icHUD latches the
#     current menu direction into two fields (FUN_100de004): **+0x1bc = "a menu
#     direction is down"** (set on press @ 0x100de040, cleared on release @
#     0x100de07f) and **+0x1c0 = which command**. The Engineering screen then
#     polls them EVERY FRAME from its own body draw:
#
#       FUN_10107710 @ 0x10107729:  if (hud[+0x1bc] && !hud[+0x1b6]
#                                       && (hud[+0x1c0] == 2 || == 3)
#                                       && this[+0x54] in {1,2,3})
#                                       FUN_101081a0(cmd, &axis[row-1], other, other)
#                                   SetTRIPosition(+0xc0, +0xc4, +0xc8)  @0x101077d3
#       FUN_10108240 @ 0x10108264:  the same test for row 5, dragging the
#                                   reactor's ramp target (icReactor+0xa0).
#
#     So it is a RATE, not a step, and it is applied per-frame for as long as the
#     key is down -- exactly what the report expected.
#
# THE RATE: _DAT_10163f14 = **0.35** barycentric units per second (0x101081ab
# `fmul [0x10163f14]` against FnTimeWin32::m_game_delta_time_seconds). The very
# same constant drives row 5's reactor throttle (ship_systems.REACTOR_THROTTLE_RATE).
const MENU_RATE := 0.35                 # _DAT_10163f14, units/s while held
const MENU_DELAY := 0.5                 # flux.ini FcInputMapper::initial_delay
const MENU_PERIOD := 0.08               # flux.ini FcInputMapper::repeat_period

var eng_row := 5                                # ctor: this+0x54 = 5
const ENG_ROW0_Y := 177.0                       # OURS (212 - 35)
const ENG_ROW5_Y := 352.0                       # OURS (317 + 35)
var eng_sel := 0                                # row 0's cursor into systems[]

# Our stand-in for icHUD +0x1bc / +0x1c0. hud.gd only forwards key PRESSES, so
# the held state is polled here; a release of any menu direction clears the latch,
# which is what 0x100de07f does (it clears the flag whatever the command was).
const MENU_CMD := {KEY_UP: 0, KEY_DOWN: 1, KEY_LEFT: 2, KEY_RIGHT: 3}
var _menu_held := false                         # icHUD+0x1bc
var _menu_cmd := -1                             # icHUD+0x1c0
var _menu_down: Dictionary = {}                 # previous frame's key states
var _menu_rpt := 0.0                            # the auto-repeat countdown

func _menu_poll(d: float) -> void:
	# Latch the held direction (icHUD FUN_100de004) and run the 0.5s/0.08s
	# auto-repeat that flux's FUN_10075010 gives every 0x103-flagged binding.
	for key: int in MENU_CMD:
		var now: bool = Input.is_physical_key_pressed(key)
		var was: bool = bool(_menu_down.get(key, false))
		_menu_down[key] = now
		if now and not was:                     # press -> latch
			_menu_held = true
			_menu_cmd = int(MENU_CMD[key])
			_menu_rpt = MENU_DELAY
		elif was and not now:                   # release -> drop the latch
			_menu_held = false
	if not _menu_held:
		return
	# The repeat only matters for the commands slot 13 actually acts on: the row
	# stepper (0/1) and, on row 0 alone, the selector (2/3). On rows 1/2/3 and 5
	# the table entry is null and the held-key path below does the work instead.
	if _menu_cmd > 1 and eng_row != 0:
		return
	_menu_rpt -= d
	if _menu_rpt <= 0.0:
		_menu_rpt = MENU_PERIOD
		_eng_cmd(_menu_cmd)

func _eng_hold(d: float) -> void:
	# FUN_10107710 @ 0x10107729 and FUN_10108240 @ 0x10108264.
	if not _menu_held or (_menu_cmd != 2 and _menu_cmd != 3):
		return
	if eng_row >= 1 and eng_row <= 3:
		_tri_move(eng_row - 1, _menu_cmd, d)
	elif eng_row == 5:
		var s: ShipSystems = _sys()
		if s != null:
			s.nudge_reactor_throttle(-1.0 if _menu_cmd == 2 else 1.0, d)

func _eng_key(key: int) -> bool:
	# The press half of the command path. hud.gd hands us pressed keys only; the
	# repeat comes from _menu_poll.
	match key:
		KEY_UP, KEY_DOWN, KEY_LEFT, KEY_RIGHT:
			_eng_cmd(int(MENU_CMD[key]))
		KEY_ENTER, KEY_KP_ENTER:
			_eng_cmd(4)
		_:
			return false
	return true

func _eng_cmd(cmd: int) -> void:
	# FUN_10105c80, verbatim.
	match cmd:
		0:
			eng_row = wrapi(eng_row - 1, 0, 6)  # 0x10105c8b: dec, wrap to 5
		1:
			eng_row = wrapi(eng_row + 1, 0, 6)  # 0x10105ca8: inc, wrap to 0
		2, 3:
			# the per-row table at 0x10163ec0: row 0 -> FUN_10106390, rest null.
			# Rows 1/2/3 and 5 deliberately do nothing here -- see _eng_hold.
			if eng_row == 0:
				_eng_select(cmd)
		4:
			if eng_row == 0:
				_eng_toggle()                   # FUN_10106390(this, 4)
			elif eng_row == 4:
				# FUN_101092f0 -> SetTRIPosition(1/3, 1/3, 1/3) @ 0x101092ff
				_set_tri(1.0 / 3.0, 1.0 / 3.0, 1.0 / 3.0)

func _eng_systems() -> Array:
	# icShip+0x140, the subsim list FUN_10106390 walks and FUN_10108890 indexes
	# with the row-0 cursor (this+0x94 -> the selected subsim at this+0x98).
	var s: ShipSystems = _sys()
	return s.systems if s != null else []

func _eng_select(cmd: int) -> void:
	# FUN_10106390 @ 0x101063b0 (cmd 2: dec, wrap to n-1) / 0x101063d6 (cmd 3:
	# inc, wrap to 0).
	var n: int = _eng_systems().size()
	if n == 0:
		return
	eng_sel = wrapi(eng_sel + (1 if cmd == 3 else -1), 0, n)

func _eng_toggle() -> void:
	# FUN_10106390 @ 0x10106463: Enter flips bit 1 of the selected subsim's flags
	# (iiShipSystem+0x68) -- but only when bit 5 ("can be switched off", set by
	# the base ctor 0x1003b9f0) is up. A subsim that is off draws no power and
	# makes no heat: ShipSystems.set_system_off is the gate.
	var list: Array = _eng_systems()
	if eng_sel < 0 or eng_sel >= list.size():
		return
	var sys: Dictionary = list[eng_sel]
	if main.sys != null:
		main.sys.set_system_off(sys, not bool(sys.get("off", false)))

func _tri_move(idx: int, cmd: int, dt: float) -> void:
	# FUN_101081a0, verbatim. `d` is the frame's travel; the two axes that are
	# not `idx` absorb it so the triple always sums to 1.
	#
	#   LEFT  (cmd 2, 0x101081b6):  d = min(d, p);      p -= d;  a += d/2; b += d/2
	#                               -- an EQUAL split back to the other two
	#   RIGHT (cmd 3, 0x101081ed):  d = min(d, 1 - p);  p += d;
	#                               a -= d*a/(a+b);  b -= d - d*a/(a+b)
	#                               -- taken PROPORTIONALLY to what they hold
	#
	# The asymmetry is the engine's, not ours. Both clamps keep the point inside
	# the triangle without ever renormalising.
	var cur: Array = (tri as Array).duplicate()
	var o1: int = (idx + 1) % 3
	var o2: int = (idx + 2) % 3
	var p: float = float(cur[idx])
	var a: float = float(cur[o1])
	var b: float = float(cur[o2])
	var d: float = dt * MENU_RATE
	if cmd == 2:
		d = minf(d, p)                          # 0x101081ba: fcom / d = min(d, p)
		cur[idx] = p - d
		cur[o1] = a + d * 0.5                   # 0x101081d1: fmul _DAT_10117738
		cur[o2] = b + d * 0.5
	else:
		d = minf(d, 1.0 - p)                    # 0x101081f1: fld 1.0 / fsub p
		var rest: float = a + b
		if rest <= 0.0:
			return                              # already hard against the corner
		var share: float = d * a / rest         # 0x1010821e: fdivr / fmul
		cur[idx] = p + d
		cur[o1] = a - share
		cur[o2] = b - (d - share)
	_set_tri(float(cur[0]), float(cur[1]), float(cur[2]))

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
	# the held-key path runs BEFORE the ghosts, exactly as the body draw does it
	# (FUN_10105d40 calls the feed 0x10108890, then the TRI 0x10107710)
	_menu_poll(d)
	_eng_hold(d)
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
	# row 0: the subsim selector. Left/right cycle icShip+0x140 and Enter toggles
	# the selected sim (FUN_10106390); the original draws its label at (150, 109)
	# with left/right chevrons that light while the key is held (FUN_101069a0,
	# sprites 8/9). Our y keeps the 35px row pitch instead.
	var list: Array = _eng_systems()
	var lbl := "SYSTEM    NONE"
	if eng_sel >= 0 and eng_sel < list.size():
		var sel: Dictionary = list[eng_sel]
		lbl = "%-14s %s" % [str(sel["name"]).to_upper().substr(0, 14),
			"DISABLED" if bool(sel.get("off", false)) else "ENABLED"]
	draw_string(hud._font_num, o + Vector2(BAR_X, ENG_ROW0_Y),
			("< %s >" % lbl) if eng_row == 0 else ("  %s" % lbl),
			HORIZONTAL_ALIGNMENT_LEFT, -1, hud.num_size,
			hot if eng_row == 0 else col)
	# row 5: the reactor throttle -- icReactor's ramp target (+0xa0), dragged by
	# left/right at the same 0.35/s (FUN_10108240). The screen OPENS on this row.
	var s5: ShipSystems = _sys()
	var thr: float = s5.reactor_throttle() if s5 != null else 1.0
	draw_string(hud._font_num, o + Vector2(BAR_X, ENG_ROW5_Y),
			"REACTOR   %3d%%" % int(round(thr * 100.0)),
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
# dtor 0x100fb8b0. Renderers: FUN_100ff0a0 (cluster), FUN_100fda70 (system).
#
# ============================================================================
# THERE ARE **TWO** ZOOMS, AND THEY ARE DIFFERENT QUANTITIES.
# ============================================================================
# This is the thing the previous pass got wrong. The element carries two
# completely independent zoom/camera pairs:
#
#   CLUSTER    zoom  this+0xa0  float    target this+0xa4   camera this+0xa8 (vec3 f32)
#   SYSTEM     zoom  this+0xe8  DOUBLE   target this+0xf0   camera this+0xf8 (vec3 f64)
#
# Both feed the SAME projection --
#     scale = min(screen_w, screen_h) * 0.45 / zoom
# (FUN_100ff9f0 float / FUN_100ff9b0 double, _DAT_1011e1a8 = 0.45) -- but
#
#   * the CLUSTER zoom is a dimensionless divisor over clusters.ini chart units.
#     It is pinned at **5.0** (DAT_1011e194) and never moves except during a
#     transition. The cluster chart therefore has ONE fixed scale, forever.
#
#   * the SYSTEM zoom is a **distance in METRES** -- the radius of the region
#     being framed. Its floor is 1000 m (_DAT_1011e228) and its value is
#     DERIVED, never typed in:
#
#         zoom = max(extent, 1000) * 1.2        (_DAT_1011e220 = 1.2)
#
#     (FUN_100fd670 @ 0x100fd670, the line `*(double*)(this+0xf0) =
#     fVar10 * _DAT_1011e220`). `extent` comes from what you have SELECTED:
#       - focus is the system root   -> the whole system's radius (this+0xe4,
#                                       cached by FUN_100fffa0)
#       - focus IS the selection and it has map-visible children
#                                    -> its NEAREST child's orbit radius
#                                       (FUN_100fff10)
#       - otherwise                  -> max( radius of the selection's own
#                                       subtree (FUN_100ffe70), distance from
#                                       the selection to the focus )
#     Because scale = min(w,h)*0.45/(1.2*extent), the outermost member of what
#     you framed always lands at exactly **0.375 * min(w,h)** px from centre.
#     That is the whole framing rule, and it is why the system view "zooms"
#     when you move the selection: it re-frames on it.
#
# NOTE for the record: FUN_100fd440 is NOT the zoom initialiser the old comment
# here claimed, and Ghidra did not drop it. It is the CONTROL LEGEND refresh --
# it swaps which of the eight legend items at this+0x54..0x70 are shown in the
# panel at this+0x20. See the legend section below.
#
# ============================================================================
# THE STATE MACHINE (this+0x74), from the body draw 0x100fbf50 and the input
# dispatcher 0x100fbc60:
#   0  CLUSTER VIEW               input FUN_100fcd60
#   1  cluster -> system (diving)
#   2  SYSTEM VIEW                input FUN_100fce60
#   3  system -> cluster (pulling out)
#   4  JUMP-DESTINATION LIST      input FUN_100fd130     <- RECOVERED, see below
#
# THE TRANSITIONS are a continuous dive, and each one moves the OUTGOING view's
# zoom by a factor of 1000 (_DAT_1011e198 = 1000.0, _DAT_1011e1a0 = 0.001):
#
#   DIVE  (FUN_100fcd60 case 0):  FUN_100fc9e0 sets the system up, then
#         state = 1;  cluster_target *= 0.001
#         and FUN_100fc9e0 itself parks the system zoom 1000x OUT of its target
#         (`*(double*)(this+0xe8) = 1000.0 * *(double*)(this+0xf0)`) and snaps
#         the system camera. So BOTH views zoom in together.
#         Ends when the CLUSTER zoom arrives -> state 2.
#
#   PULL OUT (FUN_100fce60 case 1): FUN_100fc970 rebuilds the cluster, then
#         state = 3;  system_target *= 1000.0
#         and FUN_100fc970 parks the cluster zoom at 0.001x its target
#         (`*(float*)(this+0xa0) = 0.001 * *(float*)(this+0xa4)`) and snaps the
#         cluster camera.
#         Ends when the SYSTEM zoom arrives -> state 0.
#
# THE CROSS-FADE (0x100fbf50) is driven by the CLUSTER zoom in BOTH directions:
#     f = (cluster_zoom - 0.001) / (5.0 - 0.001)
#     cluster_alpha *= f ;  system_alpha *= (1 - f)
# FUN_100ff0a0 runs whenever state != 2, FUN_100fda70 whenever state != 0.
#
# THE EASE (head of each renderer), same law, different floor:
#     zoom = move_toward(zoom, target, ((zoom - FLOOR) * 5.0 + FLOOR) * dt)
# FLOOR = 0.001 for the cluster (_DAT_1011e1a0), 1000.0 for the system
# (_DAT_1011e228); rate 5.0 (_DAT_1011e190 / _DAT_1011e188). The cluster
# clamps its zoom up to the floor first; the system does not.
# The camera chases at 5 * dist / s and SNAPS when the remainder is under
# 1.5 px worth of world (_DAT_1011e1b0 = 1.5, divided by the scale).
#
# ============================================================================
# THE ZOOM INPUT: THERE IS NO MANUAL ZOOM. "ZOOM" IS A HIERARCHY WALK.
# ============================================================================
# Nothing anywhere in the element writes the zoom targets except the two
# transitions and FUN_100fd670/FUN_100fda10. hud.csv's ZOOM IN / ZOOM OUT are
# not a continuous rate and not a step -- they are the LABELS of menu commands
# 0 and 1, registered in the ctor (0x100fb260) into the legend list:
#
#   this+0x54  hud_menu_cancel            icon 0x1f (31), red
#   this+0x58  hud_menu_next              icon 0x23 (35)
#   this+0x5c  hud_menu_prev              icon 0x22 (34)
#   this+0x60  hud_map_zoom_in            icon 0x24 (36)     <- cmd 0
#   this+0x64  hud_map_zoom_out           icon 0x25 (37)     <- cmd 1
#   this+0x68  hud_map_select             no icon            <- cmd 4
#   this+0x6c  hud_map_jump_destination   no icon
#   this+0x70  hud_map_select_destination no icon
#
# and FUN_100fd440 / FUN_100fd2b0 / FUN_100fd380 / FUN_100fd5a0 are the four
# legend refreshes -- they load those items into the five command slots of the
# panel at this+0x20 (+0x14 = cmd0, +0x18 = cmd1, +0x1c = cmd2, +0x20 = cmd3,
# +0x24 = cmd4):
#   FUN_100fd2b0  cluster view : cmd0 = ZOOM IN, cmd1 = none, prev/next
#   FUN_100fd440  system view  : cmd0 = ZOOM IN (or JUMP DESTINATION when the
#                                selection is a usable L-point), cmd1 = ZOOM OUT
#   FUN_100fd5a0  state 4      : cmd0 = none, cmd1 = CANCEL, prev/next
#   FUN_100fd380  transitions  : all cleared (no legend while zooming)
#
# So the commands mean:
#   cmd 0  ZOOM IN   cluster: dive into the selected system.
#                    system : DESCEND the geography tree into the selection
#                             (FUN_100fce60 case 0 sets this+0x130 = selection
#                             and rebuilds the child list) -- which re-frames,
#                             i.e. zooms in. If the selection is a known L-point
#                             with jump waypoints (FUN_10100d20) it opens the
#                             jump-destination list instead (state 4).
#   cmd 1  ZOOM OUT  system : ASCEND to the parent (this+0x130 = parent, via
#                             this+0x1da) -- which re-frames out. At the ROOT,
#                             and only once the zoom has settled, it leaves for
#                             the cluster view instead.
#                    state4 : back to the system view.
#   cmd 2 / cmd 3    prev / next in the current list.
#   cmd 4  SELECT    icPlayerContactList::SetUserNavTarget on the selection.
#   cmd 5  CANCEL    close the screen.
#
# The two glyphs at (36,126) and (72,126) are INDICATORS, not buttons: sprite 53
# backs both; while a zoom is running the first blinks sprite 36 (zoom > target,
# i.e. scale rising) or 37 (zoom <= target); while the SYSTEM camera is still
# moving the second blinks sprite 29.
# blink alpha = (|frac(t * 0.0005) - 0.5| * 1.8 + 0.1) * master.
#
# ============================================================================
# STATE 4 -- THE JUMP-DESTINATION LIST (FUN_100fca90 in, FUN_100fd130 while in)
# ============================================================================
# Entered from the system view with cmd 0 when FUN_10100d20 passes: the
# selection is an icLagrangePointWaypoint, has waypoints (+0x1f8), IsKnown(),
# and is in the player's system. FUN_100fca90 then sets state 4, parks the
# L-point in this+0x150, and builds a list at this+0x148 (count 0x140, stride 8)
# of every one of its waypoints for which icLagrangePointWaypoint::IsKnown() is
# true, each paired with its ORIGINAL index. this+0x14c is the cursor.
# FUN_100fd130: cmd 2/3 walk the list, cmd 1 returns to state 2, and cmd 4
# COMMITS -- it writes the chosen waypoint's original index into the L-point's
# +0x204 (i.e. arms that L-point for that destination) and then calls
# SetUserNavTarget on it. That is how you plot an interstellar jump.
#
# ============================================================================
# THE CLUSTER VIEW
# ============================================================================
# The chart ships with the game: icCluster::Load (0x10044360) reads
# geog/clusters.ini `map_coords[n]` into icSolarSystem+0x624/+0x628, plus
# label[n] / label_coords[n]. FUN_100ff0a0 plots
#     s = (sys.map_xy - cam) * scale        scale = min(w,h) * 0.45 / 5.0
#
# NODE SPRITE -- RECOVERED. FUN_10100650 (the cluster rebuild) counts how many
# jump links touch each system and writes the sprite id into the runtime list at
# this+0x90:
#     id = (links > 2) ? 55 : 57            (0x10100989: `(-(uint)(2 < n) &
#                                            0xfffffffe) + 0x39`)
# and FUN_100ff0a0 reads it back per system (`mov ecx,[esi+0x90] / mov ebx,
# [ecx+edx*4]` @ 0x100ff427 -- Ghidra dropped the index and made it [0]).
# 55 is a large disc, 57 a small one: hub systems are drawn bigger. It was
# never the roundel (53) we used.
#
# Node/label alpha carries the save game: 1.0 selected or moused-over, 0.7
# visited (_DAT_101191e8), 0.3 never visited (_DAT_1011c034); the label style
# index is 2 / 1 / 0 respectively, and in the original the style-2 label is
# amber while 0 and 1 are green. Jump links are lines at width 0.5 / fade 1.5
# with a PER-END alpha (1.0 if that end is visited, else 0.3 -- FUN_10100650).
# Mouse pick: nearest system within sqrt(144) = 12 px (FUN_100ffb50).
#
# ============================================================================
# THE SYSTEM VIEW (FUN_100fda70) -- what it actually plots
# ============================================================================
# It walks icGeography, flattened by id into this+0xd4, and for every entity
# with IsVisibleOnMap() it projects the REAL SYSTEM COORDINATES, in metres, on
# the X/Z plane (entity+0x48 = X double, entity+0x58 = Z double):
#     p      = (entity.xz - cam) * scale
#     orbit  = (entity.xz - parent.xz) * scale     <- the orbit vector, in px
# It draws, in this order:
#   * for each body, an ORBIT CIRCLE about its PARENT of radius |orbit| --
#     FcGraphicsEngine::DrawCircle, width 0.5, only when |orbit| > 15 px
#     (_DAT_1011e1c8), alpha ramping 0 -> 1 across 15..25 px (_DAT_1011e1cc),
#     and only while the circle is not absurdly bigger than the screen
#     (|orbit| <= 12 * half-diagonal, _DAT_1011e1d0); past that the orbit is
#     drawn as a plain line instead.
#   * for each L-POINT (icGeography type 5), a STUB LINE toward its partner
#     geography (entity+0x20c), clipped to 2.1 * half-diagonal
#     (_DAT_1011e230), alpha 0.3.
#   * the BODIES themselves, one FUN_100ff6b0 each. That is where the fade
#     lives, and it is the reason the original's system view looks so clean:
#         glyph alpha : 0 below 27 px of orbit, ramp 27..50, 1 above
#                       (_DAT_1011e1b8 / _DAT_1011e1bc)
#         label alpha : 0 below 35 px of orbit, ramp 35..60, 1 above
#                       (_DAT_1011e1c0 / _DAT_1011e1c4)
#     -- both forced to 1.0 when the entity is the selection, the focus, or
#     moused-over, in which case sprite 51 is stamped over the glyph as well.
#     A body whose orbit is under 27 px simply is not drawn: only what you have
#     framed is visible, and descending is how you reveal the rest.
#   * the PLAYER, sprite 66 (the little ship), but only when the player is
#     actually in the system being viewed (0x100fec52 `push 0x42`).
#
# The body glyph id itself is FUN_100e86d0(entity):
#     type 1  -> 54 (star)        type 5  -> 60 (L-point)   [table 0x1011db64]
#     type 2  -> station subtype table 0x1011dbe4
#     type 14 -> 58 / 59 / 61 by the byte at entity+0x1e4
# NOT RECOVERED: how icGeography's +0x194 / +0x1e4 / +0x218 map onto the fields
# our system JSON actually carries. We use 54 for a star and 60 for an L-point
# (both pinned above) and fall back to the plain discs 55 / 57 for bodies and
# stations. Also NOT RECOVERED: icGeography::IsVisibleOnMap -- our JSON has no
# such flag, so we show everything.
const MAP_SCALE_K := 0.45      # _DAT_1011e1a8 (double)
const CLU_ZOOM := 5.0          # DAT_1011e194  -- the cluster's one fixed zoom
const CLU_FLOOR := 0.001       # _DAT_1011e1a0
const SYS_FLOOR := 1000.0      # _DAT_1011e228 -- metres
const ZOOM_RATE := 5.0         # _DAT_1011e190 / _DAT_1011e188
const DIVE := 1000.0           # _DAT_1011e198
const SYS_FIT := 1.2           # _DAT_1011e220
const CAM_SNAP_PX := 1.5       # _DAT_1011e1b0
const PICK_R := 12.0           # sqrt(_DAT_1011e234 = 144)
const ORBIT_ON := 15.0         # _DAT_1011e1c8
const ORBIT_FULL := 25.0       # _DAT_1011e1cc
const ORBIT_MAX_K := 12.0      # _DAT_1011e1d0
const GLYPH_ON := 27.0         # _DAT_1011e1b8
const GLYPH_FULL := 50.0       # _DAT_1011e1bc
const LABEL_ON := 35.0         # _DAT_1011e1c0
const LABEL_FULL := 60.0       # _DAT_1011e1c4
const LP_STUB_K := 2.1         # _DAT_1011e230
const MAP_A_VISITED := 0.7     # _DAT_101191e8
const MAP_A_UNSEEN := 0.3      # _DAT_1011c034
const MAP_LABEL_DX := 16.0     # _DAT_101184a0

var map_state := 0                      # this+0x74
var map_sel := 0                        # this+0x78  (cluster selection)
var _clu_zoom := CLU_ZOOM               # this+0xa0
var _clu_zoom_to := CLU_ZOOM            # this+0xa4
var _clu_cam := Vector2.ZERO            # this+0xa8
var _clu_cam_to := Vector2.ZERO         # this+0xb8
var _map_visited: Dictionary = {}       # stands in for icSaveGame's hash set
var _cluster_cache: Array = []
var _cluster_labels: Array = []

# the system view. _geo is icGeography flattened by index, exactly as our
# system JSON already stores it (index / parent / pos in metres).
var _sys_zoom := SYS_FLOOR              # this+0xe8   METRES
var _sys_zoom_to := SYS_FLOOR           # this+0xf0
var _sys_cam := Vector2.ZERO            # this+0xf8   METRES (x, z)
var _sys_cam_to := Vector2.ZERO         # this+0x118
var _geo: Array = []                    # this+0xd4
var _geo_stem := ""                     # this+0xc4
var _focus := 0                         # this+0x130  (index into _geo)
var _kids: Array = []                   # this+0x13c  (indices, children of _focus)
var _sel := 0                           # this+0xc8   (cursor into _kids)
var _lps: Array = []                    # this+0x148  (state 4: jump destinations)
var _lp_sel := 0                        # this+0x14c
var _lp_of := -1                        # this+0x150

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
	# the node sprite: FUN_10100650 counts the jump links touching each system
	# and picks 55 (>2 links) or 57.
	for s: Dictionary in _cluster_cache:
		var n := 0
		for o: Dictionary in _cluster_cache:
			if o["stem"] == s["stem"]:
				continue
			if str(s["stem"]) in o["links"] or str(o["stem"]) in s["links"]:
				n += 1
		s["spr"] = 55 if n > 2 else 57
	return _cluster_cache

# --- the geography tree (icGeography, flattened by id at this+0xd4) -----------

func _load_geo(stem: String) -> void:
	if _geo_stem == stem and not _geo.is_empty():
		return
	_geo_stem = stem
	_geo = []
	var sys: Variant = main._load_json("data/json/systems/%s.json" % stem)
	if sys == null:
		return
	for o: Dictionary in sys["objects"]:
		var p: Array = o["pos"]
		# the engine plots entity+0x48 (X) against entity+0x58 (Z), raw, in
		# metres. main.gd negates Z for Godot's handedness; the map does not.
		_geo.append({
			"i": int(o["index"]), "parent": int(o.get("parent", 0)),
			"name": str(o["name"]), "cat": str(o.get("category", "body")),
			"pos": Vector2(float(p[0]), float(p[2])),
			# an L-point's partner geography (icGeography+0x20c)
			"partner": int(o.get("info", -1)),
			"jumps": o.get("jumps_to_stems", []),
		})

func _kids_of(i: int) -> Array:
	var out: Array = []
	for g: Dictionary in _geo:
		if int(g["parent"]) == i and int(g["i"]) != i:
			out.append(int(g["i"]))
	return out

func _is_descendant(i: int, of: int) -> bool:
	# FUN_100ffe20
	var g := i
	var guard := 0
	while g != of and guard < 64:
		var p: int = int(_geo[g]["parent"])
		if p == g or g == 0:
			return false
		g = p
		guard += 1
	return g == of

func _subtree_radius(i: int) -> float:
	# FUN_100ffe70: the furthest descendant of i, from i.
	var c: Vector2 = _geo[i]["pos"]
	var r := 0.0
	for g: Dictionary in _geo:
		var j: int = int(g["i"])
		if j == i or not _is_descendant(j, i):
			continue
		r = maxf(r, (Vector2(g["pos"]) - c).length())
	return r

func _min_child_radius(i: int) -> float:
	# FUN_100fff10: the nearest direct child of i, from i.
	var c: Vector2 = _geo[i]["pos"]
	var r := 0.0
	for j: int in _kids_of(i):
		var d: float = (Vector2(_geo[j]["pos"]) - c).length()
		if r == 0.0 or d < r:
			r = d
	return r

# --- FUN_100fd670: re-frame the system view on the current selection ----------
func _refresh_system() -> void:
	if _geo.is_empty() or _kids.is_empty():
		return
	_sel = clampi(_sel, 0, _kids.size() - 1)
	var s: int = _kids[_sel]
	_sys_cam_to = _geo[s]["pos"]
	var ext := 0.0
	if _focus == 0:
		ext = _subtree_radius(0)                       # this+0xe4
	elif _focus == s and not _kids_of(s).is_empty():
		ext = _min_child_radius(_focus)
	else:
		ext = maxf(_subtree_radius(s),
				(Vector2(_geo[s]["pos"]) - Vector2(_geo[_focus]["pos"])).length())
	_sys_zoom_to = maxf(ext, SYS_FLOOR) * SYS_FIT

# --- FUN_100fda10: re-frame the cluster view on the selected system -----------
func _refresh_cluster() -> void:
	var c := _cluster()
	if c.is_empty():
		return
	map_sel = clampi(map_sel, 0, c.size() - 1)
	_clu_cam_to = c[map_sel]["pos"]
	_clu_zoom_to = CLU_ZOOM

# --- FUN_100fc9e0: set up the system view (called on the dive) ----------------
func _enter_system(stem: String) -> void:
	map_state = 2
	_load_geo(stem)
	_focus = 0
	_kids = _kids_of(0)
	_sel = 0
	_refresh_system()
	# the system starts 1000x zoomed OUT of its target and eases in
	_sys_zoom = DIVE * _sys_zoom_to
	_sys_cam = _sys_cam_to

# --- FUN_100fc970: rebuild the cluster view (called on the pull-out) ----------
func _leave_system() -> void:
	map_state = 0
	_refresh_cluster()
	# the cluster starts 1000x zoomed IN of its target and eases out
	_clu_zoom = CLU_FLOOR * _clu_zoom_to
	_clu_cam = _clu_cam_to

func _map_open() -> void:
	var c := _cluster()
	if not c.is_empty():
		for i in c.size():
			if str(c[i]["stem"]) == main.system_stem:
				map_sel = i
		_map_visited[main.system_stem] = true
	map_state = 0
	_clu_zoom = CLU_ZOOM
	_refresh_cluster()
	_clu_cam = _clu_cam_to

func _clu_scale() -> float:
	var s := get_viewport_rect().size
	return minf(s.x, s.y) * MAP_SCALE_K / maxf(_clu_zoom, CLU_FLOOR)

func _sys_scale() -> float:
	var s := get_viewport_rect().size
	return minf(s.x, s.y) * MAP_SCALE_K / maxf(_sys_zoom, 1e-6)

func _chase(cam: Vector2, to: Vector2, scale: float, d: float) -> Vector2:
	# the camera half of both renderer heads: snap inside 1.5 px of world, else
	# step 5 * dist * dt toward the target (and snap if that overshoots).
	var dv := to - cam
	var dist := dv.length()
	if dist < CAM_SNAP_PX / maxf(scale, 1e-12):
		return to
	var step := ZOOM_RATE * dist * d
	if dist < step:
		return to
	return cam + dv / dist * step

func _edge_pan(scale: float, d: float) -> Vector2:
	# FUN_100ffd30 (cluster, f32) / FUN_100ffc30 (system, f64): the camera TARGET
	# edge-scrolls while the cursor is within 3 px (_DAT_10118490) of a screen
	# edge, at 0.75 (_DAT_1011e1d4) screen-widths per second in world units.
	# This is not a nicety: the cluster chart is authored LARGER than the view
	# (20 x 12 units at 0.45*min(w,h)/5 px per unit), so panning is how you
	# reach the rest of it.
	if Input.mouse_mode != Input.MOUSE_MODE_VISIBLE:
		return Vector2.ZERO
	var vp := get_viewport_rect().size
	var m := get_viewport().get_mouse_position()
	if m.x < 0.0 or m.y < 0.0 or m.x > vp.x or m.y > vp.y:
		return Vector2.ZERO
	var step: float = 0.75 * d * vp.x / maxf(scale, 1e-12)
	var v := Vector2.ZERO
	if m.x < 3.0:
		v.x -= step
	if m.x > vp.x - 3.0:
		v.x += step
	if m.y < 3.0:
		v.y -= step
	if m.y > vp.y - 3.0:
		v.y += step
	return v

func _map_step(d: float) -> void:
	# FUN_100ff0a0 head: the cluster clamps up to its floor, then eases.
	_clu_zoom = maxf(_clu_zoom, CLU_FLOOR)
	_clu_zoom = move_toward(_clu_zoom, _clu_zoom_to,
			((_clu_zoom - CLU_FLOOR) * ZOOM_RATE + CLU_FLOOR) * d)
	var cs := _clu_scale()
	_clu_cam = _chase(_clu_cam, _clu_cam_to, cs, d)
	# FUN_100fda70 head: same law, floor 1000 m, and NO clamp.
	_sys_zoom = move_toward(_sys_zoom, _sys_zoom_to,
			((_sys_zoom - SYS_FLOOR) * ZOOM_RATE + SYS_FLOOR) * d)
	var ss := _sys_scale()
	_sys_cam = _chase(_sys_cam, _sys_cam_to, ss, d)
	# the edge-scroll pan, on the live view only (both renderers gate it on
	# state != 1 and state != 3 -- no panning mid-dive)
	if map_state == 0:
		_clu_cam_to += _edge_pan(cs, d)
	elif map_state == 2 or map_state == 4:
		_sys_cam_to += _edge_pan(ss, d)
	# 0x100fbf50: the dive ends when the CLUSTER zoom arrives, the pull-out when
	# the SYSTEM zoom arrives -- in both cases, when the OUTGOING view is done.
	if map_state == 1 and is_equal_approx(_clu_zoom, _clu_zoom_to):
		map_state = 2
	elif map_state == 3 and is_equal_approx(_sys_zoom, _sys_zoom_to):
		map_state = 0

# --- the six menu commands (vtable slot 13 -> FUN_100fbc60) -------------------
func _map_cmd(cmd: int) -> void:
	var c := _cluster()
	if c.is_empty():
		return
	match map_state:
		0:      # FUN_100fcd60
			match cmd:
				0:      # ZOOM IN: dive into the selected system
					var stem := str(c[map_sel]["stem"])
					_map_visited[stem] = true
					_enter_system(stem)
					map_state = 1
					_clu_zoom_to = _clu_zoom_to * CLU_FLOOR
				2:
					map_sel = wrapi(map_sel - 1, 0, c.size())
					_refresh_cluster()
				3:
					map_sel = wrapi(map_sel + 1, 0, c.size())
					_refresh_cluster()
		2:      # FUN_100fce60
			if _kids.is_empty():
				return
			var s: int = _kids[_sel]
			match cmd:
				0:      # ZOOM IN
					if _can_jump(s):
						_open_jump_list(s)          # FUN_100fca90 -> state 4
					elif not _kids_of(s).is_empty():
						_focus = s                  # descend
						_kids = _kids_of(_focus)
						_sel = 0
						_refresh_system()
				1:      # ZOOM OUT
					if _focus == 0:
						# only leaves once the zoom has settled (FUN_100fce60)
						if is_equal_approx(_sys_zoom, _sys_zoom_to):
							_leave_system()
							map_state = 3
							_sys_zoom_to = _sys_zoom_to * DIVE
					else:
						var was := _focus
						_focus = int(_geo[_focus]["parent"])
						_kids = _kids_of(_focus)
						_sel = maxi(0, _kids.find(was))
						_refresh_system()
				2:
					_sel = wrapi(_sel - 1, 0, _kids.size())
					_refresh_system()
				3:
					_sel = wrapi(_sel + 1, 0, _kids.size())
					_refresh_system()
		4:      # FUN_100fd130
			match cmd:
				1:
					map_state = 2
				2:
					if not _lps.is_empty():
						_lp_sel = wrapi(_lp_sel - 1, 0, _lps.size())
				3:
					if not _lps.is_empty():
						_lp_sel = wrapi(_lp_sel + 1, 0, _lps.size())

func _can_jump(i: int) -> bool:
	# FUN_10100d20: an L-point that has known jump waypoints.
	var g: Dictionary = _geo[i]
	return str(g["cat"]) == "lpoint" and not Array(g["jumps"]).is_empty()

func _open_jump_list(i: int) -> void:
	# FUN_100fca90
	map_state = 4
	_lp_of = i
	_lps = []
	for dest: String in _geo[i]["jumps"]:
		_lps.append(str(dest))
	_lp_sel = 0

func _map_key(key: int) -> bool:
	# the HUD menu's command keys. ZOOM IN / ZOOM OUT are commands 0 and 1 --
	# there is no held-rate and no step; see the header. We also accept +/- for
	# them because that is what they are called (our binding, not the original's;
	# configs/default.ini carries no starmap zoom binding).
	match key:
		KEY_UP, KEY_EQUAL, KEY_KP_ADD:
			_map_cmd(0)
		KEY_DOWN, KEY_MINUS, KEY_KP_SUBTRACT:
			_map_cmd(1)
		KEY_LEFT:
			_map_cmd(2)
		KEY_RIGHT:
			_map_cmd(3)
		KEY_ENTER, KEY_KP_ENTER:
			_map_cmd(4)
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

	# the cross-fade (0x100fbf50) -- driven by the CLUSTER zoom in both
	# directions, because that is the one the engine reads.
	var a_cluster := 0.0 if map_state == 2 else 1.0
	var a_system := 0.0 if map_state == 0 else 1.0
	if map_state == 1 or map_state == 3:
		var f: float = clampf((_clu_zoom - CLU_FLOOR) / (CLU_ZOOM - CLU_FLOOR), 0.0, 1.0)
		a_cluster *= f
		a_system *= 1.0 - f
	a_cluster *= fade
	a_system *= fade

	if a_system > 0.0:
		_draw_map_system(centre, a_system)
	if a_cluster > 0.0:
		_draw_map_cluster(centre, c, a_cluster)

	# the two header indicators, absolute (36,126) and (72,126), drawn after the
	# projection is popped: sprite 53 backs both, then the live one blinks over.
	var t: float = Time.get_ticks_msec()
	var blink: float = (absf(fposmod(t * 0.0005, 1.0) - 0.5) * 1.8 + 0.1) * fade
	var dim := Color(Hud.GREEN.r, Hud.GREEN.g, Hud.GREEN.b, fade * 0.5)
	_spr(Vector2(36, 126), 53, dim)
	_spr(Vector2(72, 126), 53, dim)
	var bc := Color(Hud.GREEN.r, Hud.GREEN.g, Hud.GREEN.b, blink)
	if not is_equal_approx(_sys_zoom, _sys_zoom_to) \
			or not is_equal_approx(_clu_zoom, _clu_zoom_to):
		# 36 while the scale is rising (zoom > target), 37 while it is falling
		_spr(Vector2(36, 126), 36 if _sys_zoom > _sys_zoom_to else 37, bc)
	if _sys_cam.distance_to(_sys_cam_to) > 0.0:
		_spr(Vector2(72, 126), 29, bc)

	# the three text lines (FUN_100eb270 puts two at x = 20, y = 60 / 80).
	var tc := Color(Hud.GREEN.r, Hud.GREEN.g, Hud.GREEN.b, fade)
	var ac := Color(Hud.AMBER.r, Hud.AMBER.g, Hud.AMBER.b, fade)
	var sel := str(c[map_sel]["stem"]).replace("_", " ").to_upper()
	var l0 := "CLUSTER VIEW"
	var l1 := "SELECTED: %s" % sel
	var l2 := ""
	if map_state != 0:
		l0 = "SYSTEM VIEW: %s" % _geo_name(0)
		l1 = "SELECTED: %s" % _geo_name(_focus)
		if not _kids.is_empty():
			l2 = "SELECTED: %s" % _geo_name(_kids[clampi(_sel, 0, _kids.size() - 1)])
	if map_state == 4:
		l2 = "JUMP DESTINATION: %s" % (str(_lps[_lp_sel]).replace("_", " ").to_upper()
				if not _lps.is_empty() else "NONE")
	draw_string(hud._font_num, Vector2(20, 60), l0,
			HORIZONTAL_ALIGNMENT_LEFT, -1, hud.num_size, tc)
	draw_string(hud._font_num, Vector2(20, 80), l1,
			HORIZONTAL_ALIGNMENT_LEFT, -1, hud.num_size, tc)
	draw_string(hud._font_num, Vector2(20, 100), l2,
			HORIZONTAL_ALIGNMENT_LEFT, -1, hud.num_size, ac)
	_draw_map_legend(fade)

func _geo_name(i: int) -> String:
	if i < 0 or i >= _geo.size():
		return ""
	return str(_geo[i]["name"]).to_upper()

# --- the control legend (FUN_100fd2b0 / FUN_100fd440 / FUN_100fd5a0) ----------
func _draw_map_legend(fade: float) -> void:
	if map_state == 1 or map_state == 3:
		return                                  # FUN_100fd380 clears it
	var items: Array = []                       # [sprite, text, red]
	match map_state:
		0:
			items = [[36, "ZOOM IN", false], [34, "PREV", false], [35, "NEXT", false]]
		2:
			var zin := [36, "ZOOM IN", false]
			if not _kids.is_empty() and _can_jump(_kids[_sel]):
				zin = [36, "JUMP DESTINATION", false]
			items = [zin, [37, "ZOOM OUT", false],
					[34, "PREV", false], [35, "NEXT", false]]
		4:
			items = [[31, "CANCEL", true], [34, "PREV", false], [35, "NEXT", false]]
	var size := get_viewport_rect().size
	var x := 24.0
	var y: float = size.y - 28.0
	for it: Array in items:
		var col: Color = Color(1, 0.25, 0.25, fade) if bool(it[2]) \
				else Color(Hud.GREEN.r, Hud.GREEN.g, Hud.GREEN.b, fade)
		_spr(Vector2(x + 10.0, y), int(it[0]), col)
		draw_string(hud._font_num, Vector2(x + 26.0, y + 5.0), str(it[1]),
				HORIZONTAL_ALIGNMENT_LEFT, -1, hud.num_size, col)
		x += 34.0 + hud._font_num.get_string_size(str(it[1]),
				HORIZONTAL_ALIGNMENT_LEFT, -1, hud.num_size).x

func _draw_map_cluster(centre: Vector2, c: Array, alpha: float) -> void:
	var scale := _clu_scale()
	var pos: Dictionary = {}
	for s: Dictionary in c:
		pos[str(s["stem"])] = centre + (Vector2(s["pos"]) - _clu_cam) * scale
	# the jump links: width 0.5, with a per-END alpha -- 1.0 if that end has been
	# visited, else 0.3 (FUN_10100650). Godot has no per-vertex alpha on
	# draw_line, so we draw each half at its own end's alpha.
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
			var pa: Vector2 = pos[a]
			var pb: Vector2 = pos[b]
			var mid := (pa + pb) * 0.5
			var aa: float = 1.0 if _map_visited.has(a) else MAP_A_UNSEEN
			var ab: float = 1.0 if _map_visited.has(b) else MAP_A_UNSEEN
			draw_line(pa, mid, Color(Hud.AMBER.r, Hud.AMBER.g, Hud.AMBER.b,
					aa * alpha * 0.6), 1.0, true)
			draw_line(mid, pb, Color(Hud.AMBER.r, Hud.AMBER.g, Hud.AMBER.b,
					ab * alpha * 0.6), 1.0, true)
	# the nodes: sprite 55 for a hub (>2 links), 57 otherwise
	for i in c.size():
		var stem := str(c[i]["stem"])
		var p: Vector2 = pos[stem]
		var here: bool = stem == main.system_stem
		var a := MAP_A_UNSEEN
		var style := 0
		if i == map_sel:
			a = 1.0
			style = 2
		elif _map_visited.has(stem) or here:
			a = MAP_A_VISITED
			style = 1
		var node := Color(Hud.AMBER.r, Hud.AMBER.g, Hud.AMBER.b, a * alpha)
		_spr(p, int(c[i]["spr"]), node)
		# style 2 (the selection) is amber, 0 and 1 are green
		var lc: Color = node if style == 2 else \
				Color(Hud.GREEN.r, Hud.GREEN.g, Hud.GREEN.b, a * alpha)
		draw_string(hud._font_num, p + Vector2(MAP_LABEL_DX, 5),
				stem.replace("_", " ").to_upper(), HORIZONTAL_ALIGNMENT_LEFT,
				-1, hud.num_size, lc)
	# the cluster labels (clusters.ini label[n] / label_coords[n])
	for l: Dictionary in _cluster_labels:
		var p := centre + (Vector2(l["pos"]) - _clu_cam) * scale
		draw_string(hud._font, p, str(l["text"]), HORIZONTAL_ALIGNMENT_LEFT,
				-1, hud.FONT_SIZE,
				Color(Hud.AMBER.r, Hud.AMBER.g, Hud.AMBER.b, 0.35 * alpha))

func _draw_map_system(centre: Vector2, alpha: float) -> void:
	if _geo.is_empty():
		return
	var scale := _sys_scale()
	var size := get_viewport_rect().size
	var half_diag: float = (size * 0.5).length()
	var amber := Color(Hud.AMBER.r, Hud.AMBER.g, Hud.AMBER.b, alpha)
	var sel_i: int = _kids[_sel] if not _kids.is_empty() and _sel < _kids.size() else -1

	# pass 1: the orbit circles, about each body's PARENT
	for g: Dictionary in _geo:
		var i: int = int(g["i"])
		var par: int = int(g["parent"])
		if i == par or str(g["cat"]) == "lpoint":
			continue
		var pc: Vector2 = centre + (Vector2(_geo[par]["pos"]) - _sys_cam) * scale
		var r: float = (Vector2(g["pos"]) - Vector2(_geo[par]["pos"])).length() * scale
		if r <= ORBIT_ON:
			continue
		var oa: float = clampf((r - ORBIT_ON) / (ORBIT_FULL - ORBIT_ON), 0.0, 1.0)
		if r > ORBIT_MAX_K * half_diag:
			continue
		draw_arc(pc, r, 0, TAU, maxi(24, mini(192, int(r * 0.5))),
				Color(amber.r, amber.g, amber.b, alpha * oa * 0.5), 1.0, true)

	# pass 2: the L-point stubs, toward the partner geography (entity+0x20c),
	# clipped to 2.1 * half-diagonal, alpha 0.3
	for g: Dictionary in _geo:
		if str(g["cat"]) != "lpoint":
			continue
		var pt: int = int(g["partner"])
		if pt < 0 or pt >= _geo.size():
			continue
		var p: Vector2 = centre + (Vector2(g["pos"]) - _sys_cam) * scale
		var q: Vector2 = centre + (Vector2(_geo[pt]["pos"]) - _sys_cam) * scale
		var dv := q - p
		var lim := LP_STUB_K * half_diag
		if dv.length() > lim:
			dv = dv.normalized() * lim
		draw_line(p, p + dv,
				Color(amber.r, amber.g, amber.b, alpha * MAP_A_UNSEEN), 1.0, true)

	# pass 3: the bodies (FUN_100ff6b0). Everything hangs off the ORBIT length in
	# pixels: under 27 px the glyph is not drawn at all, under 35 px no label.
	for g: Dictionary in _geo:
		var i: int = int(g["i"])
		var par: int = int(g["parent"])
		var p: Vector2 = centre + (Vector2(g["pos"]) - _sys_cam) * scale
		var r: float = 0.0 if i == par else \
				(Vector2(g["pos"]) - Vector2(_geo[par]["pos"])).length() * scale
		var hot: bool = i == sel_i or i == _focus
		var ga: float = 1.0 if hot else \
				clampf((r - GLYPH_ON) / (GLYPH_FULL - GLYPH_ON), 0.0, 1.0)
		var la: float = 1.0 if hot else \
				clampf((r - LABEL_ON) / (LABEL_FULL - LABEL_ON), 0.0, 1.0)
		if ga <= 0.0 and la <= 0.0:
			continue
		var cat := str(g["cat"])
		var id := 55                     # plain disc -- see the header, NOT RECOVERED
		var col := amber
		match cat:
			"star":
				id = 54                  # 0x1011db64[1] = 54
				col = Color(Hud.GOLD.r, Hud.GOLD.g, Hud.GOLD.b, alpha)
			"lpoint":
				id = 60                  # 0x1011db64[5] = 60
				col = Color(Hud.GREEN.r, Hud.GREEN.g, Hud.GREEN.b, alpha)
			"station":
				id = 57
				col = Color(Hud.BLUE.r, Hud.BLUE.g, Hud.BLUE.b, alpha)
		if hot:
			col = Color(Hud.GREEN.r, Hud.GREEN.g, Hud.GREEN.b, alpha)
		if ga > 0.0:
			_spr(p, id, Color(col.r, col.g, col.b, col.a * ga))
			if hot:
				draw_arc(p, 14.0, 0, TAU, 24,
						Color(col.r, col.g, col.b, alpha), 1.0, true)
		if la > 0.0:
			draw_string(hud._font_num, p + Vector2(MAP_LABEL_DX, 5),
					str(g["name"]).to_upper(), HORIZONTAL_ALIGNMENT_LEFT, -1,
					hud.num_size, Color(col.r, col.g, col.b, col.a * la))

	# the player, sprite 66 -- only when the player is in the system being viewed
	if _geo_stem == main.system_stem:
		var pp := centre + (Vector2(main.px, -main.pz) - _sys_cam) * scale
		_spr(pp, 66, Color(Hud.GREEN.r, Hud.GREEN.g, Hud.GREEN.b, alpha))

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
	if _shot_i == -4:
		_hudshot_zoom(d)
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
		if "--mapzoom" in OS.get_cmdline_user_args():
			_shot_i = -4
			_zoom_i = 0
			hud.screen = "hud_menu_map"
			_map_open()
			return
		get_tree().quit()
		return
	hud.screen = SHOT_SCREENS[_shot_i]

# `-- --hudshot --mapzoom` additionally walks the starmap through the dive, the
# system view and two levels of descent, snapping each -- so the zoom can be
# LOOKED AT rather than asserted. Each step is (label, command, settle seconds).
var _zoom_i := 0
const ZOOM_STEPS := [
	["00_cluster", -1, 0.6],     # the cluster view, at rest
	["01_diving", 0, 0.25],      # cmd 0: mid-dive
	["02_diving_late", -1, 0.35],
	["03_system", -1, 2.0],      # settled in the system view
	["04_descend1", 0, 2.0],     # cmd 0: descend one level (ZOOM IN)
	["05_next", 3, 2.0],         # cmd 3: move the selection -- re-frames
	["06_descend2", 0, 2.0],     # cmd 0: descend again
	["07_ascend", 1, 2.0],       # cmd 1: back up (ZOOM OUT)
	["08_pullout", 1, 0.4],      # cmd 1 at the root: mid pull-out
	["09_cluster_back", -1, 2.0],
]

func _hudshot_zoom(d: float) -> void:
	_shot_t += d
	var step: Array = ZOOM_STEPS[_zoom_i]
	if _zoom_i == 0 and _shot_t < 0.05:
		return
	if _shot_t < float(step[2]):
		return
	var img := get_viewport().get_texture().get_image()
	var dir: String = main._base().path_join("build/shots")
	DirAccess.make_dir_recursive_absolute(dir)
	img.save_png(dir.path_join("map_%s.png" % str(step[0])))
	print("MAPZOOM ", step[0], "  state=", map_state,
			"  clu_zoom=%.4f/%.4f" % [_clu_zoom, _clu_zoom_to],
			"  sys_zoom=%.0f/%.0f m" % [_sys_zoom, _sys_zoom_to],
			"  focus=", _geo_name(_focus))
	_zoom_i += 1
	_shot_t = 0.0
	if _zoom_i >= ZOOM_STEPS.size():
		get_tree().quit()
		return
	var cmd: int = int(ZOOM_STEPS[_zoom_i][1])
	if cmd >= 0:
		_map_cmd(cmd)
