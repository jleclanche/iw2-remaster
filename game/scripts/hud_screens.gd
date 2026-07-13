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
#    _DAT_1011e330 = 1.0 and sets the master alpha to the ratio).
#  - the OPEN FLASH, drawn by icHUD itself (FUN_100de1a0 tail): for the first
#    0.5 s (_DAT_1011d814) after a menu element opens, the whole screen is
#    washed with 2px-pitch noise scanlines (FUN_100ec850 / FUN_100eca30) in
#    chartreuse * 0.9 (_DAT_1011951c), alpha (1 - t/0.5); after that the wash
#    alpha collapses to 0 (it returns only under damage flicker, pilot+0x74).
# The BODY layout inside each screen (row positions, the starmap projection)
# is still OURS; the per-screen constants that are real are called out below.

var hud: Hud
var main: Node3D
const OPEN_FLASH_T := 0.5   # _DAT_1011d814
const FADE_T := 1.0         # _DAT_1011e330 (icHUDEngineering this+0x58 ramp)
var _open_t := 10.0
var _last_screen := ""

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

func _process(d: float) -> void:
	if hud != null and hud.screen != _last_screen:
		_last_screen = hud.screen
		_open_t = 0.0
	_open_t += d
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
	var body := Rect2(Vector2(60, 90), size - Vector2(120, 150))
	draw_rect(Rect2(body.position - Vector2(8, 34), body.size + Vector2(16, 42)),
			Hud.GREEN * Color(1, 1, 1, 0.5 * fade), false, 1.0)
	match hud.screen:
		"hud_menu_eng":
			_draw_engineering(body)
		"hud_menu_map":
			_draw_starmap(body)
		"hud_menu_log":
			_draw_list(body, _log_entries())
		"hud_menu_objectives":
			_draw_objectives(body)
		"hud_menu_score_table":
			_draw_list(body, _score_entries())

# --- icHUDEngineering: the TRI ----------------------------------------------
# @element icHUDEngineering
#
# From the constructor (FUN_101059f0 @ 0x101059f0):
#   +0xc   node name = "hud_menu_eng"; caption key = "hud_menu_engineering"
#   +0x54  the selected row, cycled 0..5 by FUN_10105c80 -- SIX rows
#   +0x5c  eleven localised strings, loaded from the key table at 0x10163e94:
#          hud_menu_engineering, hud_engineering_ship, hud_engineering_iff,
#          hud_engineering_back, hud_engineering_resettri,
#          hud_engineering_powerhelp_part1/2, ..._general_enabled/disabled,
#          ..._powerpod_enabled/disabled
#   +0xc0..+0xd4 and +0xdc..+0xe4  NINE floats, every one initialised to
#          0x3eaaaaab = 1/3 -- three triples that each sum to 1. That is the
#          TRI: a three-way split, starting even.
#   +0xbc  1000.0
#
# The triangle itself is the shipped art, images/hud/tri.png (texture 3 in the
# sprite table's texture list), whose track occupies (2,2)-(146,139). It is
# drawn here at 2x. The three corners are the three allocations and the marker
# sits at their barycentre.
#
# NOT RECOVERED: which corner is which system, and the pixel geometry of the
# element (the five floats parked after its vtable at 0x1011e348 are 70, 160,
# 35, 281, 275 and are almost certainly it, but nothing proves the assignment).
# The corner labels below are OURS.
const TRI_SRC := Rect2(0, 0, 150, 145)
const TRI_SCALE := 2.0
var tri := [1.0 / 3.0, 1.0 / 3.0, 1.0 / 3.0]   # ctor: 0x3eaaaaab, three ways
var eng_row := 5                                # ctor: this+0x54 = 5
const ENG_ROWS := ["POWER", "REPAIR", "HEAT", "RESET TRI", "SHIP", "BACK"]
const TRI_CORNERS := ["POWER", "REPAIR", "HEAT"]

func _eng_key(key: int) -> bool:
	# FUN_10105c80: 0/1 step the row (wrapping at 0 and 5), 4 activates it.
	match key:
		KEY_UP:
			eng_row = wrapi(eng_row - 1, 0, ENG_ROWS.size())
		KEY_DOWN:
			eng_row = wrapi(eng_row + 1, 0, ENG_ROWS.size())
		KEY_LEFT, KEY_RIGHT:
			var d: float = (0.04 if key == KEY_RIGHT else -0.04)
			if eng_row < 3:
				_tri_shift(eng_row, d)
		KEY_ENTER, KEY_KP_ENTER:
			if eng_row == 3:
				tri = [1.0 / 3.0, 1.0 / 3.0, 1.0 / 3.0]  # hud_engineering_resettri
			elif eng_row == 5:
				hud.screen = ""                          # hud_engineering_back
		_:
			return false
	return true

func _tri_shift(idx: int, amount: float) -> void:
	# a TRI is a simplex: what one axis gains, the other two give up in
	# proportion, so the triple always sums to 1
	var want: float = clampf(float(tri[idx]) + amount, 0.0, 1.0)
	var give: float = want - float(tri[idx])
	var rest: float = 1.0 - float(tri[idx])
	if rest <= 0.0001:
		return
	for i in 3:
		if i != idx:
			tri[i] = maxf(0.0, float(tri[i]) - give * float(tri[i]) / rest)
	var total: float = float(tri[0]) + float(tri[1]) + float(tri[2])
	tri[idx] = want
	total = float(tri[0]) + float(tri[1]) + float(tri[2])
	if total > 0.0:
		for i in 3:
			tri[i] = float(tri[i]) / total

var _tri_tex: Texture2D
var _tri_loaded := false

func _draw_engineering(body: Rect2) -> void:
	if not _tri_loaded:
		_tri_loaded = true
		_tri_tex = Hud._load_mask(main._base(), "tri.png")
	var tex := _tri_tex
	var sz := TRI_SRC.size * TRI_SCALE
	var origin := body.position + Vector2(20, 20)
	if tex != null:
		draw_texture_rect_region(tex, Rect2(origin, sz), TRI_SRC, Hud.GREEN)
	# the corners of the track, measured off tri.png and scaled
	var pts := [origin + Vector2(22, 22) * TRI_SCALE,
			origin + Vector2(128, 22) * TRI_SCALE,
			origin + Vector2(75, 122) * TRI_SCALE]
	for i in 3:
		var lab: String = "%s %d%%" % [TRI_CORNERS[i], int(round(float(tri[i]) * 100.0))]
		var col: Color = Hud.AMBER if eng_row == i else Hud.GREEN
		draw_string(hud._font, pts[i] + Vector2(-24, -12), lab,
				HORIZONTAL_ALIGNMENT_LEFT, -1, hud.FONT_SIZE, col)
	var marker: Vector2 = pts[0] * float(tri[0]) + pts[1] * float(tri[1]) \
			+ pts[2] * float(tri[2])
	draw_circle(marker, 5.0, Hud.AMBER)
	draw_arc(marker, 9.0, 0, TAU, 24, Hud.AMBER, 1.4, true)

	# the row list, right of the triangle
	var x := origin.x + sz.x + 40.0
	var y := origin.y + 10.0
	for i in ENG_ROWS.size():
		var col: Color = Hud.AMBER if i == eng_row else Hud.GREEN
		var text: String = ENG_ROWS[i]
		if i < 3:
			text = "%-9s %3d%%" % [text, int(round(float(tri[i]) * 100.0))]
		draw_string(hud._font_num, Vector2(x, y), text,
				HORIZONTAL_ALIGNMENT_LEFT, -1, hud.num_size, col)
		y += float(hud.num_size) + 8.0
	# hud_engineering_hull / _ship / _iff: the real screen reads these out
	y += 12.0
	draw_string(hud._font_num, Vector2(x, y), "HULL      %3d%%"
			% int(round(main.hull / main.hull_max * 100.0)),
			HORIZONTAL_ALIGNMENT_LEFT, -1, hud.num_size, Hud.GREEN)
	y += float(hud.num_size) + 4.0
	draw_string(hud._font_num, Vector2(x, y), "SHIP:     %s"
			% str(main.ship.name).to_upper(),
			HORIZONTAL_ALIGNMENT_LEFT, -1, hud.num_size, Hud.GREEN)
	y += float(hud.num_size) + 4.0
	var states: Dictionary = main.system_states()
	for g: String in states.keys():
		var s: float = float(states[g])
		if s < 0.0:
			continue
		y += float(hud.num_size) + 2.0
		var col: Color = hud._health_color(s)
		draw_string(hud._font_num, Vector2(x, y), "%-4s %3d%%"
				% [g, int(round(s * 100.0))],
				HORIZONTAL_ALIGNMENT_LEFT, -1, hud.num_size, col)

# --- icHUDStarmap ------------------------------------------------------------
# @element icHUDStarmap
#
# Registered against iiHUDMenuElement; node name "hud_menu_map"; caption
# hud_map_caption = "STELLAR NAVIGATION OVERLAY". hud.csv also gives it
# CLUSTER VIEW / SYSTEM VIEW: / SELECTED: / ZOOM IN / ZOOM OUT / JUMP
# DESTINATION / SELECT DESTINATION / INTERSTELLAR L-POINT / LOCAL L-POINT /
# MISSION WAYPOINTS / ROUTE, so both views exist and both are drawn here.
#
# NOT RECOVERED: the projection, the scale and every pixel position. The draw
# is spread over vtable slots 12..16 (0x100fbc20, 0x100fbc60, 0x100fbf50,
# 0x100fbce0, 0x100fbf40) and was not reversed. The GEOGRAPHY is real -- it is
# data/json/systems/*.json (docs/geography.md), including the L-point links --
# but the LAYOUT below is ours.
var map_cluster := true     # hud_map_cluster_view vs hud_map_system_view
var map_sel := 0

func _map_key(key: int) -> bool:
	var systems := _cluster()
	match key:
		KEY_LEFT:
			map_sel = wrapi(map_sel - 1, 0, maxi(1, systems.size()))
		KEY_RIGHT:
			map_sel = wrapi(map_sel + 1, 0, maxi(1, systems.size()))
		KEY_UP, KEY_DOWN:
			map_cluster = not map_cluster
		_:
			return false
	return true

func _cluster() -> Array:
	var idx: Dictionary = main._load_json("data/json/systems/_index.json")
	var out: Array = []
	for stem: String in idx.keys():
		out.append({"stem": stem, "links": idx[stem].get("links", [])})
	out.sort_custom(func(a, b): return str(a["stem"]) < str(b["stem"]))
	return out

func _draw_starmap(body: Rect2) -> void:
	var systems := _cluster()
	if systems.is_empty():
		return
	map_sel = clampi(map_sel, 0, systems.size() - 1)
	draw_string(hud._font_num, body.position + Vector2(0, 16),
			"CLUSTER VIEW" if map_cluster else "SYSTEM VIEW: %s"
				% str(main.system_name).to_upper(),
			HORIZONTAL_ALIGNMENT_LEFT, -1, hud.num_size, Hud.GREEN)
	if map_cluster:
		_draw_cluster(body, systems)
	else:
		_draw_system(body)
	var sel := str(systems[map_sel]["stem"]).replace("_", " ").to_upper()
	draw_string(hud._font_num, body.end - Vector2(body.size.x, 8),
			"SELECTED: %s" % sel, HORIZONTAL_ALIGNMENT_LEFT, -1, hud.num_size,
			Hud.AMBER)

func _draw_cluster(body: Rect2, systems: Array) -> void:
	# ring layout: the index gives the links but no coordinates, and the real
	# cluster map's projection was not recovered
	var c := body.get_center()
	var r: float = minf(body.size.x, body.size.y) * 0.36
	var pos: Dictionary = {}
	for i in systems.size():
		var a := TAU * i / float(systems.size()) - PI / 2.0
		pos[str(systems[i]["stem"])] = c + Vector2(cos(a), sin(a) * 0.72) * r
	for s: Dictionary in systems:
		for link: String in s["links"]:
			var to := str(link).to_lower()
			if pos.has(to):
				draw_line(pos[str(s["stem"])], pos[to],
						Hud.GREEN * Color(1, 1, 1, 0.35), 1.0, true)
	for i in systems.size():
		var stem := str(systems[i]["stem"])
		var p: Vector2 = pos[stem]
		var here: bool = stem == main.system_stem
		var col: Color = Hud.AMBER if i == map_sel else \
			(Hud.GOLD if here else Hud.GREEN)
		draw_circle(p, 4.0 if here else 3.0, col)
		if here:
			draw_arc(p, 9.0, 0, TAU, 20, col, 1.2, true)
		draw_string(hud._font_num, p + Vector2(7, 4),
				stem.replace("_", " ").to_upper(),
				HORIZONTAL_ALIGNMENT_LEFT, -1, hud.num_size, col)

func _draw_system(body: Rect2) -> void:
	# top-down x/z of the current system, log-scaled so the inner bodies and the
	# far L-points both land on the page
	var c := body.get_center()
	var span: float = minf(body.size.x, body.size.y) * 0.45
	var far := 1.0
	for o: Dictionary in main.objects:
		far = maxf(far, Vector2(float(o["x"]), float(o["z"])).length())
	for o: Dictionary in main.objects:
		var v := Vector2(float(o["x"]), float(o["z"]))
		var d: float = v.length()
		var p := c
		if d > 1.0:
			p = c + v.normalized() * (log(1.0 + d) / log(1.0 + far)) * span
		var cat := str(o["category"])
		var col := Hud.GREEN
		var rad := 2.0
		match cat:
			"star":
				col = Hud.GOLD
				rad = 5.0
			"lpoint":
				col = Hud.GREEN
				rad = 3.0
			"station":
				col = Hud.BLUE
			_:
				col = Hud.PALE * Color(1, 1, 1, 0.6)
		draw_circle(p, rad, col)
		if cat in ["lpoint", "star", "station"]:
			draw_string(hud._font_num, p + Vector2(5, 3),
					str(o["name"]).to_upper(), HORIZONTAL_ALIGNMENT_LEFT, -1,
					hud.num_size, col)
	var pp := Vector2(main.px, main.pz)
	var pd: float = pp.length()
	var me := c if pd <= 1.0 else \
		c + pp.normalized() * (log(1.0 + pd) / log(1.0 + far)) * span
	draw_arc(me, 6.0, 0, TAU, 16, Hud.AMBER, 1.4, true)

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
	for id: String in main.objectives.keys():
		var o: Dictionary = main.objectives[id]
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
