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
var _add: Control = null       ## the SetBlend(2) additive layer (issue #47)
var _t: CanvasItem = null      ## current draw target: self, or _add
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
	_t = self
	# The ADDITIVE layer (issue #47): the engine runs SetBlend(2) before every
	# map sprite/line/text batch, so the starmap content and the shared page
	# chrome (grid, caption text, scan band, cursor) draw on this child with
	# real additive blending -- the extracted colours (GREEN DAT_10176038,
	# AMBER DAT_10174fb0) then land on the reference captures' pixels without
	# the old composite stand-ins. Additive draws commute, so order inside
	# the layer is free.
	_add = Control.new()
	_add.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_add.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var mat := CanvasItemMaterial.new()
	mat.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	_add.material = mat
	add_child(_add)
	_add.draw.connect(_draw_additive)

func _page() -> Vector2:
	# top-left of the 640x480 authoring page, centred in the viewport
	return ((get_viewport_rect().size - PAGE) * 0.5).floor()

# The host's cursor (icHUDFlightScreen +0x1c4/+0x1d0/+0x1d4, tick @
# 0x100e0700): armed by the first mouse MOVEMENT while a page is up, then the
# page draws the full-screen crosshair through it (FUN_100f1400).
var _cursor := Vector2.ZERO
var _cursor_on := false

func _process(d: float) -> void:
	if hud != null and hud.screen != _last_screen:
		if hud.screen != "" and _last_screen == "":
			# menu pages own the OS cursor; flight recaptures it on close
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		elif hud.screen == "" and _last_screen != "" \
				and (main.menu == null or not main.menu.visible):
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		_last_screen = hud.screen
		_open_t = 0.0
		_cursor_on = false
		_cursor = get_viewport().get_mouse_position()
		# drop any latched menu direction across an open/close (icHUD clears
		# +0x1bc on the release it never gets to see while the screen is down)
		_menu_held = false
		_menu_down.clear()
		if hud.screen == "hud_menu_map":
			_map_open()
	if hud != null and hud.screen != "":
		var m := get_viewport().get_mouse_position()
		if not _cursor_on and m.distance_to(_cursor) > 0.5:
			_cursor_on = true   # armed by movement, like the host's +0x1c4
		if _cursor_on:
			_cursor = m
	_open_t += d
	if hud != null and hud.screen == "hud_menu_map":
		_map_step(d)
	if hud != null and hud.screen == "hud_menu_eng":
		_eng_step(d)
	_hudshot_step(d)
	queue_redraw()
	if _add != null:
		_add.queue_redraw()

# Returns true when the key was consumed by the open screen.
func handle_key(key: int) -> bool:
	match hud.screen:
		"hud_menu_eng":
			return _eng_key(key)
		"hud_menu_map":
			return _map_key(key)
	return false

## The menu-page backdrop. The wash + 16 px grid are drawn by the flight
## region under the menu elements; their draw was not recovered to an address,
## so both are pixel-matched to the 2026-07-21 reference captures: background
## composite over black space reads (112, 61, 13) -> wash (0.517, 0.282, 0.06)
## at 0.85; grid lines read +(7, 10, 0) over the wash on a 16 px pitch --
## additive HUD green at 0.04. (Address still an open question, docs/original.md.)
const WASH := Color(0.517, 0.282, 0.06, 0.85)
const GRID_STEP := 16.0
const GRID_A := 0.04

func _draw() -> void:
	if hud == null or main == null or hud.screen == "":
		return
	_t = self
	var size := get_viewport_rect().size
	draw_rect(Rect2(Vector2.ZERO, size), WASH)
	# the element's one-second fade-in (icHUDEngineering this+0x58)
	var fade := clampf(_open_t / FADE_T, 0.0, 1.0)
	# The caption band (FUN_100f1920): quad (16,16)-(w-16,48) in the HUD's
	# general colour (DAT_10176038, the same register the body text uses) at
	# alpha 0.25 (_DAT_101191ec).
	var band_green := Color(Hud.GREEN.r, Hud.GREEN.g, Hud.GREEN.b, 0.25 * fade)
	draw_rect(Rect2(Vector2(16, 16), Vector2(size.x - 32.0, 32.0)), band_green)
	# NO open flash: the scanline burst _DAT_1011d814 times belongs to the
	# LDSi-disruption effect, not to a page opening -- the original opens
	# its pages clean (user capture review, issue #35)
	match hud.screen:
		"hud_menu_eng":
			hud._ea = fade
			_draw_engineering(fade)
		"hud_menu_map":
			pass  # drawn wholly on the additive layer (_draw_additive)
		_:
			var body := Rect2(Vector2(60, 90), size - Vector2(120, 150))
			draw_rect(Rect2(body.position - Vector2(8, 34), body.size + Vector2(16, 42)),
					Hud.AMBER * Color(1, 1, 1, 0.5 * fade), false, 1.0)
			match hud.screen:
				"hud_menu_log":
					_draw_list(body, _log_entries())
				"hud_menu_objectives":
					_draw_objectives(body)
				"hud_menu_score_table":
					_draw_list(body, _score_entries())

## The SetBlend(2) content, on the additive child. The engine's own colours
## draw here unmodified and land on the reference captures: e.g. the cursor's
## GREEN (0.5, 1.0, 0) at 0.5 alpha adds onto the wash composite
## (112, 61, 13) to give exactly the captured (176, 189, 12).
func _draw_additive() -> void:
	if hud == null or main == null or hud.screen == "":
		return
	_t = _add
	var size := get_viewport_rect().size
	var fade := clampf(_open_t / FADE_T, 0.0, 1.0)
	# the 16 px grid: additive HUD green at 0.04 (measured +(7, 10, 0) over
	# the wash; the draw's address is still an open question, docs/original.md)
	var grid := Color(Hud.GREEN.r, Hud.GREEN.g, Hud.GREEN.b, GRID_A)
	var gx := GRID_STEP
	while gx < size.x:
		_add.draw_line(Vector2(gx, 0), Vector2(gx, size.y), grid, 1.0)
		gx += GRID_STEP
	var gy := GRID_STEP
	while gy < size.y:
		_add.draw_line(Vector2(0, gy), Vector2(size.x, gy), grid, 1.0)
		gy += GRID_STEP
	# The band text is the MENU NODE's own label drawn through the node
	# member at (20,19) (FUN_100f1920 tail, member+0x24 vfunc(1, 20.0, 19.0))
	# -- the reference capture shows "STARMAP", the hud_menu_map label, in
	# the large OCR-B face, not the hud_map_caption string.
	var caption := str(Hud.MENU.get(hud.screen, {}).get("label", ""))
	hud._ea = fade
	_glow_text(2, Vector2(20, 19), caption, Hud.GREEN)
	# The page's green scan band, sweeping top to bottom. Row-profiled from
	# the 2026-07-21 capture (rows 446..483): alpha ramps LINEARLY from 0 at
	# the band's top edge to full at its bottom, then cuts hard -- the MFD
	# scan-band law (FUN_10102490) at page scale, 38 px tall, peaking at
	# additive green x 0.145 (+19,+37 over the wash). The renderer's address
	# is untraced, like the wash.
	var sweep := fposmod(Time.get_ticks_msec() / 3000.0, 1.0) \
			* (size.y + 38.0) - 38.0
	for i in 10:
		var la := (float(i) + 1.0) / 10.0 * 0.145 * fade
		_add.draw_rect(Rect2(0.0, sweep + i * 3.8, size.x, 3.8),
				Color(Hud.GREEN.r, Hud.GREEN.g, Hud.GREEN.b, la))
	if hud.screen == "hud_menu_map":
		_draw_starmap(fade)
	# FUN_100f1400 (element vtable +0x24, shared by all five pages): with the
	# host cursor armed, full-screen hairlines cross at the cursor in HUD
	# green at 0.5 alpha, ADDITIVE (SetBlend path), and sprite 3 is stamped
	# on the crossing (FUN_100e9de0(x, y, 3, 0, 0)).
	if _cursor_on:
		var cc := Color(Hud.GREEN.r, Hud.GREEN.g, Hud.GREEN.b, 0.5 * fade)
		_add.draw_line(Vector2(_cursor.x, 0), Vector2(_cursor.x, size.y), cc, 1.0)
		_add.draw_line(Vector2(0, _cursor.y), Vector2(size.x, _cursor.y), cc, 1.0)
		_spr(_cursor, 3, Color(Hud.GREEN.r, Hud.GREEN.g, Hud.GREEN.b, fade))
	_t = self

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
	47: [99, 92, 32, 32, 16, 16],     # iiSim default glyph (ctor type 4)
	53: [198, 59, 32, 32, 16, 16],    # roundel: ring + disc (header glyph backing)
	# The map glyph cells, DECODED from the table builder (FUN_100e6c60's
	# FUN_100ee6b0 fill run, `mov edi, 0x101741b0 + id*0x24` + arg pushes --
	# no longer eyeballed; slot 60's known-good cell validates the decode):
	54: [33, 125, 32, 32, 16, 16],    # sun with rays -- a STAR (type table [1] = 54)
	55: [0, 125, 32, 32, 16, 16],     # large plain disc
	56: [0, 158, 32, 32, 16, 16],     # ringed planet
	57: [33, 158, 32, 32, 16, 16],    # small plain disc
	58: [99, 158, 32, 32, 16, 16],    # asteroid-built station (the rock blob)
	59: [66, 158, 32, 32, 16, 16],    # standard station (crossed panels)
	60: [231, 226, 24, 24, 12, 12],   # L-point icon (type table [5] = 60)
	61: [165, 158, 32, 32, 16, 16],   # named settlement habitat (rock cluster)
	66: [99, 191, 32, 32, 16, 16],    # ship glyph: TRI axis 0, and the map's YOU-ARE-HERE
	67: [132, 191, 32, 32, 16, 16],   # TRI axis 1 -- ship + two beams firing
	68: [165, 191, 32, 32, 16, 16],   # TRI axis 2 -- ship + deflecting arc
}

func _spr(pos: Vector2, id: int, col: Color, rot := 0.0, scale := 1.0) -> void:
	# FUN_100e9de0(x, y, sprite, flags, rotation): the quad spans
	# [-origin, size - origin] about the anchor, at NATIVE atlas size.
	var tex: Texture2D = hud._sprites
	if tex == null:
		return
	# hud.cell(): the generated engine table first (issue #49), then the
	# hand dicts (SPR2 here, hud.gd's SPR)
	var s: Array = hud.cell(id)
	if s.is_empty():
		return
	var sz := Vector2(float(s[2]), float(s[3])) * scale
	var off := Vector2(-float(s[4]), -float(s[5])) * scale
	var src := Rect2(float(s[0]), float(s[1]), float(s[2]), float(s[3]))
	if is_zero_approx(rot):
		_t.draw_texture_rect_region(tex, Rect2(pos + off, sz), src, col)
		return
	_t.draw_set_transform(pos, rot, Vector2.ONE)
	_t.draw_texture_rect_region(tex, Rect2(off, sz), src, col)
	_t.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

## The engine draws the map sprites ADDITIVELY (SetBlend(2) before every
## FUN_100e9de0 run). The map path draws on the additive child (_t == _add),
## so this is one real additive pass -- the capture's glow is the atlas
## cell's soft edge under additive blending, no halo stand-in needed.
func _spr_glow(pos: Vector2, id: int, col: Color) -> void:
	_spr(pos, id, col)

## Page text through the HUD's own renderer (FUN_100eb270 port: kerned face,
## engine metrics/styles). On the additive layer a single pass IS the
## engine's draw; on the alpha layers (the eng page) the faint offset passes
## still stand in for the additive glyph bloom.
func _glow_text(fi: int, p: Vector2, text: String, col: Color,
		halign := 0) -> void:
	if _t != self:
		hud._hud_text(fi, 1, p, text, halign, 0, col, _t)
		return
	var ea: float = hud._ea
	hud._ea = ea * 0.3
	for off: Vector2 in [Vector2(1, 0), Vector2(-1, 0),
			Vector2(0, 1), Vector2(0, -1)]:
		hud._hud_text(fi, 1, p + off, text, halign, 0, col, self)
	hud._ea = ea
	hud._hud_text(fi, 1, p, text, halign, 0, col, self)

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
# recovered geometry (FUN_101069a0 / FUN_10106720 / FUN_10108240 /
# FUN_10105ef0): the selector row at y 150 (chevrons 39/74, name pill at
# 109 w 298), the three status lamps at y 108, the reactor at y 362, the
# four status pills at y 421
const ENG_ROW0_Y := 150.0
const ENG_LAMP_Y := 108.0
const ENG_LAMP_XS := [39.0, 74.0, 109.0]
const ENG_ROW5_Y := 362.0
const ENG_ROW5_LEN := 379.0                     # 0x10108240: {35, 362, 379}
const ENG_BOTTOM_Y := 421.0
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

## One engineering pill row (FUN_100ed780 = FUN_100eda60 frame + fill):
## the rail pill (caps 40 / rails 41, len - 8 with a pill), the icon at
## x + 4 (x - 8 [0x10117b28] + 12 [0x10119ec4]) over highlight sprite 51
## when hot, and the SOLID fill quad inset +15.5 / -27.5 (0x1011dc68/64).
## Alpha is the engine's 0.5 idle / 1.0 hot split (FUN_100eda60 head).
func _eng_row(o: Vector2, y: float, icon: int, frac: float, hot: bool,
		amber: Color) -> float:
	var c := Color(amber.r, amber.g, amber.b,
			amber.a if hot else amber.a * 0.5)
	var len := BAR_LEN - 8.0
	hud._hbar(self, o.x + BAR_X, o.y + y, len, 40, 41, c)
	var ix := BAR_X + 4.0
	if hot:
		hud._spr(Vector2(o.x + ix, o.y + y), 51, c, 0.0, 0, self)
	if icon != 0:
		hud._spr(Vector2(o.x + ix, o.y + y), icon, c, 0.0, 0, self)
	var fx := ix + 15.5
	var fl := len - 27.5
	if frac >= 0.0:
		draw_rect(Rect2(Vector2(o.x + fx, o.y + y - 5.0),
				Vector2(fl * clampf(frac, 0.0, 1.0), 10.0)),
				Color(c.r, c.g, c.b, c.a * 0.8))
	return fx  # where the fill/caption content starts

func _draw_engineering(fade: float) -> void:
	if not _tri_loaded:
		_tri_loaded = true
		_tri_tex = Hud._load_mask(main._base(), "tri.png")
	# 1:1, anchored top-left. The issue #35 reference captures (1897x1086)
	# put every element at its RAW page coordinate -- sliders at x 10..250,
	# the tri track at 270..410, the MW pill at 420..600 -- so the page is
	# NOT scaled to the window; layouts authored against 640x480 keep their
	# absolute pixel positions on larger screens, and only the bottom gauge
	# row stretches with the width. (The 0x280 x 0x1e0 compare @ 0x10105d75
	# is a dev-mode check, not a scaling rule -- the earlier scale-to-window
	# reading over-interpreted it.)
	var o := Vector2.ZERO
	# the whole screen is the menu family's AMBER (DAT_10174fb0), not the
	# flight HUD's green -- see the reference shots on issue #35
	var amber := Color(Hud.AMBER.r, Hud.AMBER.g, Hud.AMBER.b, fade)
	var col := Color(amber.r, amber.g, amber.b, fade * 0.5)
	var t: float = Time.get_ticks_msec() / 1000.0

	# header: hull name + IFF, uppercased, at (20, 63) (FUN_10106580's
	# FUN_100eb270(font 1, x 20, y 63, halign 0))
	var strings: Dictionary = main.comms.strings if main.comms != null else {}
	var iff := str(strings.get("player_iff_code", "CAL JOHNSTON"))
	draw_string(hud._font_num, o + Vector2(20.0, 63.0),
			"%s \"%s\" [IFF CODE: %s]" % [
				str(strings.get("hud_engineering_ship", "COMMAND SECTION")),
				str(main.ship.name).to_upper(), iff],
			HORIZONTAL_ALIGNMENT_LEFT, -1, hud.num_size - 2, col)

	# the three status lamps at (39/74/109, 108) (FUN_10106720): each is the
	# warning glyph in AMBER while its condition is bad, else the ring
	# roundel (sprite 52) in the page colour -- wrench 65 for hull < 0.3
	# (0x10163ee8), thermometer 62 for heat >= 0.7 (0x10163ef4) of the
	# x0.8-scaled fraction (0x10163efc), lightning 63 for free power <= 0
	# (feed FUN_10108890: +0xa4 hull/max, +0xa8 heat, +0xb4 ship+0x27c)
	var ls: ShipSystems = _sys()
	var lamp_hull: float = ls.hull / maxf(ls.hull_max, 1.0) \
			if ls != null else 1.0
	var lamp_heat: float = clampf((ls.heat + ls.heat_external) \
			/ ShipSystems.HEAT_DAMAGE_THRESHOLD * 0.8, 0.0, 1.0) \
			if ls != null else 0.0
	var lamp_pwr: float = ls._power_pool if ls != null else 1.0
	var lamps: Array = [
		[65, lamp_hull < 0.3], [62, lamp_heat >= 0.7], [63, lamp_pwr <= 0.0]]
	for li in 3:
		var lp := o + Vector2(ENG_LAMP_XS[li], ENG_LAMP_Y)
		if bool(lamps[li][1]):
			_spr(lp, int(lamps[li][0]), amber)
		else:
			_spr(lp, 52, col)

	# the track: tri.png drawn 1:1, (275,192)-(430,347), u/v 0..0.60546875
	if _tri_tex != null:
		draw_texture_rect_region(_tri_tex,
				Rect2(o + TRI_QUAD, Vector2(TRI_SIZE, TRI_SIZE)),
				Rect2(0, 0, TRI_SIZE, TRI_SIZE), col)

	# the three TRI rows: x = 35, y = 212 / 247 / 282, length 217, icons
	# 66/67/68 (the tri.png corner glyphs), each a pill + SOLID fill of the
	# slow ghost, with the fast ghost as a needle
	for i in 3:
		var y := BAR_Y + BAR_PITCH * i
		var sel: bool = eng_row == i + 1
		var v: float = float(_tri_slow[i])
		# the shimmer: while the ghost has caught up and the axis is off its
		# rails, the drawn value wobbles +/-0.02 (FUN_10107710)
		if v > 1e-6 and v < 0.999999:
			v = clampf(v + sin(t * TRI_JIT_HZ[i]) * TRI_JITTER, 0.0, 1.0)
		var fx := _eng_row(o, y, TRI_SPR[i], v, sel, amber)
		var c: Color = amber if sel else col
		var fl := BAR_LEN - 8.0 - 27.5
		var nx := o.x + fx + fl * float(_tri_fast[i])
		draw_line(Vector2(nx, o.y + y - 6.0), Vector2(nx, o.y + y + 6.0), c, 1.5)

	# the marker: sprite 45, chased toward the barycentre at 50 px/s, spinning
	# one revolution per 2 s (rot = frac(t_ms * 0.0005) * 2*PI)
	var want := _tri_bary(_tri_fast)          # page coords
	if _tri_mark.x < 0.0:
		_tri_mark = want
	_tri_mark = _tri_mark.move_toward(want, TRI_TRACK * get_process_delta_time())
	var rot: float = fposmod(Time.get_ticks_msec() * 0.0005, 1.0) * TAU
	_spr(o + _tri_mark, 45, amber, rot)

	# row 4: hud_engineering_resettri at (35, 317) -- a captioned pill
	# (FUN_100ea900: rails 40/41 + the caption)
	var r4 := _eng_row(o, RESET_Y, 0, -1.0, eng_row == 4, amber)
	draw_string(hud._font_num, Vector2(o.x + r4, o.y + RESET_Y + 5.0),
			str(strings.get("hud_engineering_resettri", "RESET TRI")),
			HORIZONTAL_ALIGNMENT_LEFT, -1, hud.num_size - 2,
			amber if eng_row == 4 else col)

	# row 0: the subsim selector (FUN_101069a0). Chevrons -- sprites 34/35 --
	# at (39, 150) / (74, 150), lit while the matching direction is held on
	# row 0; the selected sim's name in a 298-wide captioned pill at
	# (109, 150) (FUN_100ea900); connector strokes on y = 151.
	var list: Array = _eng_systems()
	var hot0: bool = eng_row == 0
	var lbl := "SYSTEM    NONE"
	if eng_sel >= 0 and eng_sel < list.size():
		var sel0: Dictionary = list[eng_sel]
		lbl = "%-14s %s" % [str(sel0["name"]).to_upper().substr(0, 14),
			str(strings.get("hud_engineering_general_disabled", "DISABLED"))
				if bool(sel0.get("off", false))
				else str(strings.get("hud_engineering_general_enabled",
					"ENABLED"))]
	var held_l: bool = hot0 and _menu_held and _menu_cmd == 2
	var held_r: bool = hot0 and _menu_held and _menu_cmd == 3
	_spr(o + Vector2(ENG_LAMP_XS[0], ENG_ROW0_Y), 34,
			amber if held_l else (amber if hot0 else col), PI * 0.5)
	_spr(o + Vector2(ENG_LAMP_XS[1], ENG_ROW0_Y), 34,
			amber if held_r else (amber if hot0 else col), -PI * 0.5)
	var c0 := Color(amber.r, amber.g, amber.b,
			amber.a if hot0 else amber.a * 0.5)
	hud._hbar(self, o.x + 109.0, o.y + ENG_ROW0_Y, 298.0 - 8.0, 40, 41, c0)
	draw_string(hud._font_num,
			Vector2(o.x + 109.0 + 15.5, o.y + ENG_ROW0_Y + 5.0), lbl,
			HORIZONTAL_ALIGNMENT_LEFT, -1, hud.num_size - 2,
			amber if hot0 else col)
	for seg in [[55.0, 60.0], [90.0, 95.0], [421.0, 426.75]]:
		draw_line(o + Vector2(seg[0], ENG_ROW0_Y + 1.0),
				o + Vector2(seg[1], ENG_ROW0_Y + 1.0), c0, 1.0)
	# ... and the selected sim's side panel at x 440 w 155 (FUN_10107070):
	# the wrench repair pill (icon 65, bar w 138, blink under 0.3) tracking
	# the sim's hull fraction
	if eng_sel >= 0 and eng_sel < list.size():
		var ps: Dictionary = list[eng_sel]
		var pf: float = float(ps.get("hp", 0.0)) \
				/ maxf(float(ps.get("hp_max", 1.0)), 1.0)
		var pc := Color(amber.r, amber.g, amber.b,
				amber.a if hot0 else amber.a * 0.5)
		hud._hbar(self, o.x + 440.0, o.y + ENG_ROW0_Y + 35.0, 138.0 - 8.0,
				40, 41, pc)
		_spr(o + Vector2(444.0, ENG_ROW0_Y + 35.0), 65, pc)
		draw_rect(Rect2(
				Vector2(o.x + 440.0 + 15.5, o.y + ENG_ROW0_Y + 30.0),
				Vector2((138.0 - 8.0 - 27.5) * clampf(pf, 0.0, 1.0), 10.0)),
				Color(pc.r, pc.g, pc.b, pc.a * 0.8))

	# row 5: the reactor (FUN_10108240): the bar record {35, 362, 379,
	# style 3} -- lightning icon, sprites 14/13 segments -- then the
	# connector stroke 420..427 and the output readout in its own pill at
	# (440, 362) w 152, text centred on (516, 362)
	var s5: ShipSystems = _sys()
	var thr: float = s5.reactor_throttle() if s5 != null else 1.0
	var hot5: bool = eng_row == 5
	var c5 := Color(amber.r, amber.g, amber.b,
			amber.a if hot5 else amber.a * 0.5)
	hud._hbar(self, o.x + BAR_X, o.y + ENG_ROW5_Y, ENG_ROW5_LEN - 8.0,
			40, 41, c5)
	if hot5:
		_spr(o + Vector2(BAR_X + 4.0, ENG_ROW5_Y), 51, c5)
	_spr(o + Vector2(BAR_X + 4.0, ENG_ROW5_Y), 63, c5)
	hud._segbar3(self, Vector2(o.x + BAR_X + 19.5, o.y + ENG_ROW5_Y),
			ENG_ROW5_LEN - 8.0 - 27.5, thr, amber if hot5 else col)
	draw_line(o + Vector2(420.0, ENG_ROW5_Y), o + Vector2(427.0, ENG_ROW5_Y),
			c5, 1.0)
	hud._hbar(self, o.x + 440.0, o.y + ENG_ROW5_Y, 152.0 - 8.0, 40, 41, c5)
	var mw: float = 0.0
	if s5 != null:
		for rsys in s5.systems:
			if str(rsys["class"]) == "icReactor":
				mw = float(rsys.get("output", 0.0))
	draw_string(hud._font_num, Vector2(o.x + 516.0 - 30.0,
			o.y + ENG_ROW5_Y + 5.0),
			("%d MW" % int(round(mw * thr))) if mw > 0.0
				else ("%3d%%" % int(round(thr * 100.0))),
			HORIZONTAL_ALIGNMENT_CENTER, 60, hud.num_size - 2,
			amber if hot5 else col)

	_eng_bottom_row(o, amber, col, t)

## The four wide status pills across the page bottom (FUN_10105ef0, called
## with x 35, y 421, w = page_w - 70): each pill (w - 96)/4 wide on a 32 px
## gap. Recovered fills: hull fraction behind the wrench (65, blinks under
## 0.2), the per-subsim tick strip (FUN_10106d20), the heat fraction behind
## the thermometer (62, blinks past 0.75) and Brightness() behind the bulb
## (64, red past 0.8 -- docs/original.md icShip::Brightness).
## The authored pill x/width layout, page coords: 4 pills of (w - 96)/4 on
## a 32 px gap starting at x 35 (FUN_10105ef0's head: fsub 96 @ 0x1011c70c,
## fmul 0.25 @ 0x101191ec, advance 32 @ 0x1011848c).
static func eng_bottom_rects() -> Array:
	var pw := (PAGE.x - 70.0 - 96.0) * 0.25
	var out: Array = []
	for i in 4:
		out.append(Rect2(35.0 + (pw + 32.0) * i, ENG_BOTTOM_Y, pw, 20.0))
	return out

func _eng_bottom_row(o: Vector2, amber: Color, col: Color, t: float) -> void:
	var s: ShipSystems = _sys()
	# the one width-relative row on the page: the reference captures show the
	# four gauges spanning the full window width, not the 640 page width
	var total := get_viewport_rect().size.x - 70.0
	var pw := (total - 96.0) * 0.25
	var hull_f: float = s.hull / maxf(s.hull_max, 1.0) if s != null else 1.0
	var heat_f: float = clampf((s.heat + s.heat_external) * 0.75 \
			/ ShipSystems.HEAT_DAMAGE_THRESHOLD, 0.0, 1.0) \
			if s != null else 0.0
	var brt: float = clampf(s.brightness(), 0.0, 1.0) if s != null else 0.0
	var blink := fposmod(t, 1.0) < 0.5
	var rows: Array = [
		[65, hull_f, hull_f < 0.2 and blink],
		[0, -1.0, false],
		[62, heat_f, heat_f > 0.75 and blink],
		[64, brt, brt > 0.8 and blink],
	]
	for i in 4:
		var x: float = 35.0 + (pw + 32.0) * i
		var c := Color(1.0, 0.07, 0.0, amber.a) if bool(rows[i][2]) else col
		hud._hbar(self, o.x + x, o.y + ENG_BOTTOM_Y, pw - 8.0, 40, 41, c)
		if int(rows[i][0]) != 0:
			_spr(o + Vector2(x + 4.0, ENG_BOTTOM_Y), int(rows[i][0]), c)
		var frac := float(rows[i][1])
		if frac >= 0.0:
			draw_rect(Rect2(Vector2(o.x + x + 15.5, o.y + ENG_BOTTOM_Y - 5.0),
					Vector2((pw - 8.0 - 27.5) * clampf(frac, 0.0, 1.0), 10.0)),
					Color(c.r, c.g, c.b, c.a * 0.8))
		elif s != null and i == 1:
			# the tick strip: one mark per subsim, bright when damaged
			var n: int = s.systems.size()
			for j in n:
				var sub: Dictionary = s.systems[j]
				var dmg: bool = bool(sub.get("destroyed", false)) \
						or float(sub.get("hp", 1.0)) \
						< float(sub.get("hp_max", 1.0))
				var mx: float = x + 15.5 \
						+ (pw - 8.0 - 27.5) * (float(j) + 0.5) / float(maxi(n, 1))
				draw_line(Vector2(o.x + mx, o.y + ENG_BOTTOM_Y - 5.0),
						Vector2(o.x + mx, o.y + ENG_BOTTOM_Y + 5.0),
						amber if dmg else col, 2.0)

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
# The body glyph id itself is FUN_100e86d0(sim) -- and the param is an iiSim,
# keyed on iiSim::eType (+0x194, SetType @ 0x10001350), NOT an icGeography
# type. The class ctors pin the enum: icSun ctor @ 0x1006a360 writes 1,
# icPlanet @ 0x10067bc0 writes 2, icLagrangePointWaypoint @ 0x1000a940 writes
# 5, icStation @ 0x100685a0 writes 14, and the iiSim base ctor @ 0x10077e70
# leaves 4. So (tables read from iwar2.dll .rdata):
#     type 1  icSun    -> 54            [DAT_1011db64[1]]
#     type 5  L-point  -> 60            [DAT_1011db64[5]]
#     type 4  generic  -> 47            [DAT_1011db64[4]]
#     type 2  icPlanet -> DAT_1011dbe4[icPlanet::BodyType], table
#             [0, 54, 55, 57, 56, 58, 56] -- BodyType is +0x218, loaded from
#             PSG record byte 0x134 (icPlanet::Load @ 0x1067eb0) = our JSON
#             body_type (observed values 2/3/4/6 -> 55/57/56/56).
#     type 14 icStation -> by icStation::Scene (+0x1e4, SetScene @ 0x100106c0,
#             = our JSON scene): 20..25 and 30 (the named settlement
#             habitats) -> 61, 26 (asteroid-built stations) -> 58, else 59.
# The COLOURS (static inits FUN_100e6750 / FUN_100e68d0 / .data):
#     bodies + labels   DAT_10174fb0 = (1.0, 0.592, 0.0)  amber-orange
#     plotted route     DAT_10176018 = (1.0, 0.07, 0.0)   red-orange
#     orbits/stub lines DAT_10176038 = (0.5, 1.0, 0.0)    green
# THE ROUTE (FUN_10100a-ish builder at 0x100fda70's head, list this+0x154):
# take the player pilot's nav target; if iiSim::IsGeographyBased, walk
# icCluster::GetLPointRoute hop by hop from the player to it and collect every
# L-point waypoint on the way plus the target itself. FUN_100ff6b0 draws any
# plotted entity (position-matched via FUN_10100bc0) in the route red, and the
# player marker 66 is drawn in the same red. Our port: cross-system targets
# cannot exist (only the loaded system's objects are targetable), so the
# route reduces to the nav target itself -- the same walk, one hop.
# Still NOT RECOVERED: icGeography::IsVisibleOnMap -- our JSON has no such
# flag, so we show everything.
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
const MAP_BODY := Color(1.0, 0.592, 0.0)    # DAT_10174fb0 (init FUN_100e6750)
const MAP_ROUTE := Color(1.0, 0.07, 0.0)    # DAT_10176018 (init FUN_100e68d0)
const MAP_LINE := Color(0.5, 1.0, 0.0)      # DAT_10176038 -- orbit/stub green
const PLANET_GLYPHS := [0, 54, 55, 57, 56, 58, 56]  # DAT_1011dbe4[IeBodyType]

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
	# localised system names for the chart nodes and the caption lines --
	# data/text/clusters.csv maps "map:/geog/badlands/<stem>" to the display
	# name ("Hoffer's Wake"), which is what the original's Field() lookups
	# print on the SYSTEM VIEW / SELECTED lines
	var names: Dictionary = {}
	var nf := FileAccess.open(
			main._base().path_join("data/text/clusters.csv"), FileAccess.READ)
	if nf != null:
		while not nf.eof_reached():
			var nl := nf.get_line()
			var comma := nl.find(",")
			if comma > 0 and nl.begins_with("map:"):
				names[nl.substr(0, comma).get_file().to_lower()] = \
						nl.substr(comma + 1).strip_edges()
	for s: Dictionary in _cluster_cache:
		s["name"] = str(names.get(str(s["stem"]).to_lower(),
				str(s["stem"]).replace("_", " ")))
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
			# the glyph keys: icPlanet::BodyType and icStation::Scene
			"body_type": int(o.get("body_type", 0)),
			"scene": int(o.get("scene", 0)),
		})

## FUN_100e86d0 -- the body glyph, keyed on iiSim::eType. See the header for
## the ctor-pinned type ids and the two .rdata tables.
func _glyph_id(g: Dictionary) -> int:
	match str(g["cat"]):
		"star":
			return 54                            # DAT_1011db64[1]
		"lpoint":
			return 60                            # DAT_1011db64[5]
		"station", "gunstar":
			var sc: int = int(g.get("scene", 0))
			if (sc >= 20 and sc <= 25) or sc == 30:
				return 61                        # named settlement habitats
			return 58 if sc == 26 else 59        # asteroid-built / standard
		"body":
			var bt: int = int(g.get("body_type", 0))
			if bt > 0 and bt < PLANET_GLYPHS.size() and int(PLANET_GLYPHS[bt]) != 0:
				return int(PLANET_GLYPHS[bt])
	return 47                                    # iiSim ctor default, type 4

func _kids_of(i: int) -> Array:
	var out: Array = []
	for g: Dictionary in _geo:
		if int(g["parent"]) == i and int(g["i"]) != i \
				and _geo_visible(g):
			out.append(int(g["i"]))
	return out

## imapentity.SetMapVisibility lands on the live sim record (entities.gd);
## istartsystem.HideMapLocations keeps the Dante route and the unrevealed
## story stations off the map until the plot shows them (istartsystem.pog:
## 673-697; revealed e.g. iact2mission24.pog:17-21). Only the player's own
## system has live records; a foreign system draws everything.
func _geo_visible(g: Dictionary) -> bool:
	var want := str(g["name"])
	if _geo_stem == main.system_stem:
		for o: Dictionary in main.objects:
			if str(o["name"]) == want:
				return bool(o.get("map_visible", true))
	# a foreign system has no live records; the persistent store still knows
	# (a ForeignRef write -- Dante's Marauder stations hidden from anywhere)
	return bool(main.entity_flag(_geo_stem, want, "map_visible", true))

## The per-frame lookup the renderers use (name -> visible).
func _vis_map() -> Dictionary:
	var vis: Dictionary = {}
	if _geo_stem == main.system_stem:
		for o: Dictionary in main.objects:
			vis[str(o["name"])] = bool(o.get("map_visible", true))
	else:
		for g: Dictionary in _geo:
			var n := str(g["name"])
			vis[n] = bool(main.entity_flag(_geo_stem, n, "map_visible", true))
	return vis

## A chart link hides while the local interstellar L-point that charters it
## is plot-hidden (the Dante route, istartsystem.pog:678-679, revealed by
## iact2mission24.pog:20). Only the player's own system has live records to
## consult; a foreign-to-foreign link draws as authored.
func _link_visible(a: String, b: String) -> bool:
	var here := str(main.system_stem)
	var far := b if a == here else (a if b == here else "")
	if far.is_empty() or _geo_stem != here:
		return true
	for g: Dictionary in _geo:
		if str(g["cat"]) != "lpoint":
			continue
		for d: String in g["jumps"]:
			if str(d).to_lower() == far and not _geo_visible(g):
				return false
	return true

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

## On-open (vtable slot 11 @ 0x100fba50): the map raises ALREADY IN SYSTEM
## VIEW (state = 2 outright) of the player's current system, the selection is
## the map node nearest the player ship (min-scan over the entity list by
## FiSim::DistanceBetweenCentres, focus root from its +0x1da parent node,
## selection from its +0x1d8 slot), and both zoom and camera SNAP to their
## targets -- the map opens framed, no ease-in.
func _map_open() -> void:
	var c := _cluster()
	if not c.is_empty():
		for i in c.size():
			if str(c[i]["stem"]) == main.system_stem:
				map_sel = i
		_map_visited[main.system_stem] = true
	_refresh_cluster()
	_clu_zoom = CLU_ZOOM
	_clu_cam = _clu_cam_to
	_load_geo(main.system_stem)
	map_state = 2
	if _geo.is_empty():
		map_state = 0
		return
	var pp := Vector2(main.px, -main.pz)
	var best := 0
	var bd := INF
	for g: Dictionary in _geo:
		if int(g["i"]) == 0:
			continue
		var d: float = (Vector2(g["pos"]) - pp).length()
		if d < bd:
			bd = d
			best = int(g["i"])
	_focus = int(_geo[best]["parent"]) if best != 0 else 0
	_kids = _kids_of(_focus)
	_sel = maxi(0, _kids.find(best))
	_refresh_system()
	_sys_zoom = _sys_zoom_to
	_sys_cam = _sys_cam_to

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

# The HUD sound bank (ctor loop @ 0x100e0480 region, table head
# PTR_s_sound__audio_hud_valid_input_10162dc8): 0 = valid_input,
# 1 = invalid_input, 2 = target_changed, 3 = missile_warning, 4 = klaxon,
# 5 = ping. Every accepted map command plays 0 via FUN_100ea750(0, 1.0), a
# rejected one plays 1 (FUN_100fce60 / 0x100fbce0 tails).
func _map_snd(ok: bool) -> void:
	main.audio.play("audio/hud/valid_input.wav" if ok
			else "audio/hud/invalid_input.wav", -8.0)

# --- the six menu commands (vtable slot 13 -> FUN_100fbc60) -------------------
func _map_cmd(cmd: int) -> void:
	var c := _cluster()
	if c.is_empty():
		return
	match map_state:
		0:      # FUN_100fcd60
			match cmd:
				0:      # ZOOM IN: dive into the selected system (no beep --
					# case 0 returns before the sound tail)
					var stem := str(c[map_sel]["stem"])
					_map_visited[stem] = true
					_enter_system(stem)
					map_state = 1
					_clu_zoom_to = _clu_zoom_to * CLU_FLOOR
				2:
					map_sel = wrapi(map_sel - 1, 0, c.size())
					_refresh_cluster()
					_map_snd(true)
				3:
					map_sel = wrapi(map_sel + 1, 0, c.size())
					_refresh_cluster()
					_map_snd(true)
		2:      # FUN_100fce60
			if _kids.is_empty():
				return
			var s: int = _kids[_sel]
			match cmd:
				0:      # ZOOM IN
					if _can_jump(s):
						_map_snd(true)
						_open_jump_list(s)          # FUN_100fca90 -> state 4
					elif not _kids_of(s).is_empty():
						_focus = s                  # descend
						_kids = _kids_of(_focus)
						_sel = 0
						_refresh_system()
						_map_snd(true)
					else:
						_map_snd(false)             # nothing to descend into
				1:      # ZOOM OUT (always beeps valid, FUN_100fce60 case 1)
					_map_snd(true)
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
					_map_snd(true)
				3:
					_sel = wrapi(_sel + 1, 0, _kids.size())
					_refresh_system()
					_map_snd(true)
				4:      # SELECT -> SetUserNavTarget on the selection
					_map_select(s)
		4:      # FUN_100fd130
			match cmd:
				1:
					map_state = 2
					_map_snd(true)
				2:
					if not _lps.is_empty():
						_lp_sel = wrapi(_lp_sel - 1, 0, _lps.size())
						_map_snd(true)
				3:
					if not _lps.is_empty():
						_lp_sel = wrapi(_lp_sel + 1, 0, _lps.size())
						_map_snd(true)
				4:      # COMMIT (case 4 @ 0x100fd130): arm the L-point with the
					# chosen waypoint (its +0x204 <- the original index; ours is
					# the live route cursor the J key reads), SetUserNavTarget
					# on the L-point (0x100fd20a), and CLOSE the map -- the
					# handler ends in FUN_100df520(host, 0) @ 0x100fd214, same
					# as the state-2 commit. (An earlier pass claimed the view
					# stays; the disassembly says otherwise.)
					if not _lps.is_empty() and _lp_of >= 0:
						main.jump_sel = _lp_sel
						_map_select(_lp_of)

# --- the mouse (host tick @ 0x100e0700 -> element vtable +0x3c/+0x40) ---------
# Left click dispatches to the element's own handler (0x100fbce0), right click
# injects menu command 1, ZOOM OUT (0x100fbf40: this->input(1)).
func _unhandled_input(e: InputEvent) -> void:
	if hud == null or main == null or hud.screen != "hud_menu_map":
		return
	if main.menu != null and main.menu.visible:
		return
	if not (e is InputEventMouseButton and (e as InputEventMouseButton).pressed):
		return
	match (e as InputEventMouseButton).button_index:
		MOUSE_BUTTON_RIGHT:
			_map_cmd(1)
			get_viewport().set_input_as_handled()
		MOUSE_BUTTON_LEFT:
			_map_click((e as InputEventMouseButton).position)
			get_viewport().set_input_as_handled()

## The 12 px pick: FUN_100ffb50 takes the nearest node within sqrt(144) px of
## the host cursor (cluster); the system view's pick (0x100ffa30) walks the
## same list. Returns an index into `c`/_geo, or -1.
func _map_pick_cluster(at: Vector2) -> int:
	var c := _cluster()
	var centre := (get_viewport_rect().size * 0.5).floor()
	var scale := _clu_scale()
	var best := -1
	var bd := PICK_R
	for i in c.size():
		var p: Vector2 = centre + (Vector2(c[i]["pos"]) - _clu_cam) * scale
		var d := p.distance_to(at)
		if d < bd:
			bd = d
			best = i
	return best

func _map_pick_geo(at: Vector2) -> int:
	var centre := (get_viewport_rect().size * 0.5).floor()
	var scale := _sys_scale()
	var best := -1
	var bd := PICK_R
	for g: Dictionary in _geo:
		if int(g["i"]) == 0 or not _geo_visible(g):
			continue
		var p: Vector2 = centre + (Vector2(g["pos"]) - _sys_cam) * scale
		var d := p.distance_to(at)
		if d < bd:
			bd = d
			best = int(g["i"])
	return best

## 0x100fbce0, the left-click law. System view: click nothing -> invalid beep;
## click a node with children -> descend into it; click the already-selected
## node -> command 4 (commit); click anything else -> select it. Cluster view:
## click nothing -> invalid beep; click the selected system -> dive; click
## another -> select it.
func _map_click(at: Vector2) -> void:
	if _menu_click(at):
		return
	match map_state:
		2:
			var pick := _map_pick_geo(at)
			if pick < 0:
				_map_snd(false)
				return
			if not _kids_of(pick).is_empty() and not _can_jump(pick):
				_focus = pick
				_kids = _kids_of(_focus)
				_sel = 0
				_refresh_system()
				_map_snd(true)
			elif not _kids.is_empty() and pick == _kids[_sel]:
				_map_cmd(4)
			else:
				_focus = int(_geo[pick]["parent"])
				_kids = _kids_of(_focus)
				_sel = maxi(0, _kids.find(pick))
				_refresh_system()
				_map_snd(true)
		0:
			var pick := _map_pick_cluster(at)
			if pick < 0:
				_map_snd(false)
				return
			if pick == map_sel:
				_map_cmd(0)      # the click-dive DOES beep (0x100fbec2)
				_map_snd(true)
			else:
				map_sel = pick
				_refresh_cluster()
				_map_snd(true)

func _can_jump(i: int) -> bool:
	# FUN_10100d20: an L-point that has known jump waypoints. The routes are
	# read through the LIVE record: ilagrangepoint.SetUsable parks them there
	# (natives/entities.gd), and the static JSON list would resurrect
	# story-locked routes (the Dante gate).
	return str(_geo[i]["cat"]) == "lpoint" and not _lp_jumps(i).is_empty()

func _lp_jumps(i: int) -> Array:
	var g: Dictionary = _geo[i]
	if _geo_stem == main.system_stem:
		var want := str(g["name"])
		for o: Dictionary in main.objects:
			if str(o["name"]) == want:
				return o.get("jumps", [])
	if not bool(main.entity_flag(_geo_stem, str(g["name"]), "usable", true)):
		return []
	return g["jumps"]

## cmd 4 SELECT -- icPlayerContactList::SetUserNavTarget @ 0x100abf00: the
## selection becomes the player's nav target (added to the contact list if it
## was not on it). Only sims exist to target, so it can only land in the
## system the player is actually in -- the original's FindInstance +
## IsDerivedFrom(iiSim) gate does the same thing for a foreign-system pick.
func _map_select(i: int, close := true) -> void:
	var want := str(_geo[i]["name"])
	if _geo_stem == main.system_stem:
		for oi in main.objects.size():
			if str(main.objects[oi]["name"]) == want:
				main.target_idx = oi
				main.target_ai = null
				break
	# HUD sound 2 (FUN_100fce60 case 4 -> FUN_100ea750(2, 1.0)), then
	# FUN_100df520(host, 0): the commit CLOSES the starmap and hands the
	# flight view back -- unconditionally, found or not.
	main.audio.play("audio/hud/target_changed.wav", -10.0)
	if close:
		hud.screen = ""

## The nav-target geo index for the route highlight (the this+0x154 list;
## see the header -- one hop, because only the loaded system is targetable).
func _route_geo() -> int:
	if _geo_stem != main.system_stem or main.target_idx < 0 \
			or main.target_idx >= main.objects.size():
		return -1
	var want := str(main.objects[main.target_idx]["name"])
	for g: Dictionary in _geo:
		if str(g["name"]) == want:
			return int(g["i"])
	return -1

func _open_jump_list(i: int) -> void:
	# FUN_100fca90 -- only the LIVE routes (IsKnown-filtered in the original;
	# SetUsable-parked in our records)
	map_state = 4
	_lp_of = i
	_lps = []
	for dest: String in _lp_jumps(i):
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
	# The capture shows them BRIGHT with bloom -- the additive sprite path.
	var t: float = Time.get_ticks_msec()
	var blink: float = (absf(fposmod(t * 0.0005, 1.0) - 0.5) * 1.8 + 0.1) * fade
	var backing := Color(Hud.GREEN.r, Hud.GREEN.g, Hud.GREEN.b, fade * 0.9)
	_spr_glow(Vector2(36, 126), 53, backing)
	_spr_glow(Vector2(72, 126), 53, backing)
	var bc := Color(Hud.GREEN.r, Hud.GREEN.g, Hud.GREEN.b, blink)
	if not is_equal_approx(_sys_zoom, _sys_zoom_to) \
			or not is_equal_approx(_clu_zoom, _clu_zoom_to):
		# 36 while the scale is rising (zoom > target), 37 while it is falling
		_spr(Vector2(36, 126), 36 if _sys_zoom > _sys_zoom_to else 37, bc)
	if _sys_cam.distance_to(_sys_cam_to) > 0.0:
		_spr(Vector2(72, 126), 29, bc)

	# EXACTLY TWO text lines (0x100fbf50 tail: FUN_100eb270(font 1, style 1,
	# x=20, ...) at y = 60 (0x42700000) and y = 80 (0x42a00000), both in the
	# HUD's general colour). State 0: "CLUSTER VIEW" / "SELECTED: <system>";
	# state 2: "SYSTEM VIEW: <system>" / "SELECTED: <selection>"; state 4: the
	# L-point type line / "SELECTED: <destination>". Names print in their
	# localised mixed case (hud.csv hud_map_* keys + Field lookups).
	var l0 := "CLUSTER VIEW"
	var l1 := "SELECTED: %s" % str(c[map_sel]["name"])
	if map_state == 2 or map_state == 1 or map_state == 3:
		l0 = "SYSTEM VIEW: %s" % _sys_display_name()
		l1 = "SELECTED: %s" % (_geo_name(_kids[clampi(_sel, 0, _kids.size() - 1)])
				if not _kids.is_empty() else _geo_name(_focus))
	elif map_state == 4:
		# hud_map_interstellar_point / hud_map_local_point (hud.csv:270-271);
		# an L-point with a foreign-system jump is interstellar
		var inter := false
		if _lp_of >= 0:
			for d: String in _geo[_lp_of]["jumps"]:
				if str(d).to_lower() != _geo_stem:
					inter = true
		l0 = "INTERSTELLAR L-POINT" if inter else "LOCAL L-POINT"
		l1 = "SELECTED: %s" % (_lp_display(_lps[_lp_sel])
				if not _lps.is_empty() else "NONE")
	hud._ea = fade
	_glow_text(1, Vector2(20, 60), l0, Hud.GREEN)
	_glow_text(1, Vector2(20, 80), l1, Hud.GREEN)
	_draw_map_menu(fade)

func _geo_name(i: int) -> String:
	if i < 0 or i >= _geo.size():
		return ""
	return str(_geo[i]["name"])

## The viewed system's localised display name (clusters.csv), the string the
## original's Field(system+0xc) resolves for the SYSTEM VIEW line.
func _sys_display_name() -> String:
	for s: Dictionary in _cluster():
		if str(s["stem"]) == _geo_stem:
			return str(s["name"])
	return _geo_name(0)

func _lp_display(stem: String) -> String:
	for s: Dictionary in _cluster():
		if str(s["stem"]).to_lower() == str(stem).to_lower():
			return str(s["name"])
	return str(stem).replace("_", " ")

# --- the centre menu (FUN_100fd2b0 / FUN_100fd440 / FUN_100fd5a0) -------------
# The map's commands ARE menu nodes: the reticle menu stays on screen with the
# element's command list hung around the centre ring -- PREV left, NEXT right,
# ZOOM OUT below, ZOOM IN above (menu offsets MENU_OFF, alignment table
# 0x1011dec8). Drawn with the SAME machinery as the flight arrow menu
# (hud._menu_node_box / _spr_ret against reticle.png), not a look-alike.
# Commands that would be rejected are simply not offered (FUN_100fd2b0
# rebuilds the list per state).
var _menu_pills: Array = []    # [[Rect2, cmd], ...] rebuilt each draw

func _draw_map_menu(fade: float) -> void:
	_menu_pills = []
	if map_state == 1 or map_state == 3:
		return                                  # FUN_100fd380 clears it
	var centre := (get_viewport_rect().size * 0.5).floor()
	hud._ea = fade
	var green := Color(Hud.GREEN.r, Hud.GREEN.g, Hud.GREEN.b, fade)
	# the menu reticle: sprite 91 mirrored into the full ring, the four
	# spinning quadrants at half alpha (FUN_100f1d60)
	for f in 4:
		hud._spr_ret(centre, 91, green, 0.0, f, _t)
	for i in 4:
		hud._spr_ret(centre, 93,
				Color(Hud.GREEN.r, Hud.GREEN.g, Hud.GREEN.b, 0.5 * fade),
				hud._menu_spin + PI / 2.0 * i, 0, _t)
	var items: Array = []                       # [sprite, text, cmd, dir, col]
	var red := Color(1, 0.25, 0.25)
	match map_state:
		0:
			items = [[36, "ZOOM IN", 0, "up", Hud.GREEN],
					[34, "PREV", 2, "left", Hud.GREEN],
					[35, "NEXT", 3, "right", Hud.GREEN]]
		2:
			if not _kids.is_empty():
				var s: int = _kids[_sel]
				if _can_jump(s):
					items.append([36, "JUMP DESTINATION", 0, "up", Hud.GREEN])
				elif not _kids_of(s).is_empty():
					items.append([36, "ZOOM IN", 0, "up", Hud.GREEN])
			items.append([37, "ZOOM OUT", 1, "down", Hud.GREEN])
			items.append([34, "PREV", 2, "left", Hud.GREEN])
			items.append([35, "NEXT", 3, "right", Hud.GREEN])
		4:
			items = [[31, "CANCEL", 1, "down", red],
					[34, "PREV", 2, "left", Hud.GREEN],
					[35, "NEXT", 3, "right", Hud.GREEN]]
	var dir_keys := {"up": KEY_UP, "down": KEY_DOWN,
			"left": KEY_LEFT, "right": KEY_RIGHT}
	for it: Array in items:
		var dir := str(it[3])
		var di: int = Hud.MENU_DIRS.find(dir)
		var anchor: Vector2 = centre + Hud.MENU_OFF[dir]
		var held: bool = Input.is_physical_key_pressed(int(dir_keys[dir]))
		var label := str(it[1])
		var icon := int(it[0])
		hud._menu_node_box(anchor, label, icon, it[4],
				int(Hud.MENU_ALIGN[di]), held, _t)
		# the click hit box mirrors _menu_node_box's rail geometry (32px tall,
		# 16px chevron caps beyond the rail width)
		var w: float = hud._text_w(1, label) \
				+ (Hud.MENU_ICON_PAD if icon != 0 else 0.0) - Hud.MENU_TEXT_TRIM
		var x: float = anchor.x
		match int(Hud.MENU_ALIGN[di]):
			2:
				x -= w * 0.5
			1:
				x -= w
		_menu_pills.append([Rect2(x - 16.0, anchor.y - 16.0, w + 32.0, 32.0),
				int(it[2])])

func _menu_click(at: Vector2) -> bool:
	for p: Array in _menu_pills:
		if (p[0] as Rect2).has_point(at):
			_map_cmd(int(p[1]))
			return true
	return false

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
			# a route whose chartering interstellar L-point the plot has
			# hidden (SetMapVisibility 0) is not on the chart: the Dante
			# link stays dark until iact2mission24 reveals it
			if not _link_visible(a, b):
				continue
			var pa: Vector2 = pos[a]
			var pb: Vector2 = pos[b]
			var mid := (pa + pb) * 0.5
			var aa: float = 1.0 if _map_visited.has(a) else MAP_A_UNSEEN
			var ab: float = 1.0 if _map_visited.has(b) else MAP_A_UNSEEN
			_t.draw_line(pa, mid, Color(Hud.AMBER.r, Hud.AMBER.g, Hud.AMBER.b,
					aa * alpha * 0.6), 1.0, true)
			_t.draw_line(mid, pb, Color(Hud.AMBER.r, Hud.AMBER.g, Hud.AMBER.b,
					ab * alpha * 0.6), 1.0, true)
	# the nodes: sprite 55 for a hub (>2 links), 57 otherwise. The cursor pick
	# hovers a node to full alpha exactly like the selection (0x100ff0a0 tests
	# `pick == node` alongside `i == sel`).
	var hov := _map_pick_cluster(_cursor) if _cursor_on else -1
	for i in c.size():
		var stem := str(c[i]["stem"])
		var p: Vector2 = pos[stem]
		var here: bool = stem == main.system_stem
		var a := MAP_A_UNSEEN
		var style := 0
		if i == map_sel or i == hov:
			a = 1.0
			style = 2
		elif _map_visited.has(stem) or here:
			a = MAP_A_VISITED
			style = 1
		var node := Color(Hud.AMBER.r, Hud.AMBER.g, Hud.AMBER.b, a * alpha)
		_spr_glow(p, int(c[i]["spr"]), node)
		# style 2 (the selection) is amber, 0 and 1 are green; the localised
		# display name (clusters.csv) in its own mixed case, CENTRED UNDER
		# the node (reference capture), small face
		var lc: Color = Hud.AMBER if style == 2 else Hud.GREEN
		hud._ea = a * alpha
		hud._hud_text(0, 1, p + Vector2(0.0, 10.0), str(c[i]["name"]),
				2, 0, lc, _t)
	hud._ea = alpha
	# the cluster labels (clusters.ini label[n] / label_coords[n])
	for l: Dictionary in _cluster_labels:
		var p := centre + (Vector2(l["pos"]) - _clu_cam) * scale
		_t.draw_string(hud._font, p, str(l["text"]), HORIZONTAL_ALIGNMENT_LEFT,
				-1, hud.FONT_SIZE,
				Color(Hud.AMBER.r, Hud.AMBER.g, Hud.AMBER.b, 0.35 * alpha))

func _draw_map_system(centre: Vector2, alpha: float) -> void:
	if _geo.is_empty():
		return
	var scale := _sys_scale()
	var size := get_viewport_rect().size
	var half_diag: float = (size * 0.5).length()
	var sel_i: int = _kids[_sel] if not _kids.is_empty() and _sel < _kids.size() else -1
	var route_i := _route_geo()
	# plot-hidden entities (SetMapVisibility 0) simply do not exist here
	var vis := _vis_map()
	# the cursor pick hovers a node to full alpha, like the cluster view
	var hov := _map_pick_geo(_cursor) if _cursor_on else -1

	# pass 1: the orbit circles, about each body's PARENT -- in the body AMBER
	# (the renderer parks DAT_10174fb0 in the colour register at its head; the
	# reference capture's rings read as additive amber, not green)
	for g: Dictionary in _geo:
		var i: int = int(g["i"])
		var par: int = int(g["parent"])
		if i == par or str(g["cat"]) == "lpoint" \
				or not bool(vis.get(str(g["name"]), true)):
			continue
		var pc: Vector2 = centre + (Vector2(_geo[par]["pos"]) - _sys_cam) * scale
		var r: float = (Vector2(g["pos"]) - Vector2(_geo[par]["pos"])).length() * scale
		if r <= ORBIT_ON:
			continue
		var oa: float = clampf((r - ORBIT_ON) / (ORBIT_FULL - ORBIT_ON), 0.0, 1.0)
		if r > ORBIT_MAX_K * half_diag:
			continue
		_t.draw_arc(pc, r, 0, TAU, maxi(24, mini(192, int(r * 0.5))),
				Color(MAP_BODY.r, MAP_BODY.g, MAP_BODY.b, alpha * oa * 0.5),
				1.0, true)

	# pass 2: the L-point stubs, toward the partner geography (entity+0x20c),
	# clipped to 2.1 * half-diagonal, alpha 0.3, in the same amber
	for g: Dictionary in _geo:
		if str(g["cat"]) != "lpoint" \
				or not bool(vis.get(str(g["name"]), true)):
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
		_t.draw_line(p, p + dv,
				Color(MAP_BODY.r, MAP_BODY.g, MAP_BODY.b, alpha * MAP_A_UNSEEN),
				1.0, true)

	# pass 3: the bodies (FUN_100ff6b0). Everything hangs off the ORBIT length in
	# pixels: under 27 px the glyph is not drawn at all, under 35 px no label.
	# Glyph and label share one colour: the body amber (DAT_10174fb0), or the
	# route red (DAT_10176018) when the entity is on the plotted route.
	for g: Dictionary in _geo:
		var i: int = int(g["i"])
		var par: int = int(g["parent"])
		if not bool(vis.get(str(g["name"]), true)):
			continue
		var p: Vector2 = centre + (Vector2(g["pos"]) - _sys_cam) * scale
		var r: float = 0.0 if i == par else \
				(Vector2(g["pos"]) - Vector2(_geo[par]["pos"])).length() * scale
		var hot: bool = i == sel_i or i == _focus or i == hov
		var ga: float = 1.0 if hot else \
				clampf((r - GLYPH_ON) / (GLYPH_FULL - GLYPH_ON), 0.0, 1.0)
		var la: float = 1.0 if hot else \
				clampf((r - LABEL_ON) / (LABEL_FULL - LABEL_ON), 0.0, 1.0)
		if ga <= 0.0 and la <= 0.0:
			continue
		var base: Color = MAP_ROUTE if i == route_i else MAP_BODY
		var col := Color(base.r, base.g, base.b, alpha)
		if ga > 0.0:
			_spr_glow(p, _glyph_id(g), Color(col.r, col.g, col.b, col.a * ga))
			if hot:
				# the selection stamp: sprite 51 over the glyph (FUN_100ff6b0's
				# second FUN_100e9de0 call, id 51)
				_spr_glow(p, 51, col)
		if la > 0.0:
			# the localised name in its own mixed case, CENTRED UNDER the
			# glyph (reference capture), in the small face (font 0)
			hud._ea = alpha * la
			hud._hud_text(0, 1, p + Vector2(0.0, 10.0), str(g["name"]),
					2, 0, base, _t)
	hud._ea = alpha

	# the player, sprite 66 -- only when the player is in the system being
	# viewed, and in the route red (0x100fda70 sets DAT_10176018 before it).
	# With a nav target plotted, the ROUTE LINE runs from the player to it in
	# the same red (the this+0x154 route list; ours is the one hop that can
	# exist -- only the loaded system's objects are targetable).
	if _geo_stem == main.system_stem:
		var pp := centre + (Vector2(main.px, -main.pz) - _sys_cam) * scale
		var rc := Color(MAP_ROUTE.r, MAP_ROUTE.g, MAP_ROUTE.b, alpha)
		if route_i >= 0 and route_i < _geo.size():
			var tp: Vector2 = centre \
					+ (Vector2(_geo[route_i]["pos"]) - _sys_cam) * scale
			_t.draw_line(pp, tp, rc, 1.0, true)
		_spr_glow(pp, 66, rc)

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
