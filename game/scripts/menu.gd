class_name Menu
extends Control
# The original front end: amber capsule buttons down a circuit-board strip
# on the left (images/gui/gui atlas, igui.CreateFancyButton), a PRE-RENDERED
# prison-character bust movie on the right (movies/<who>.bik -- NOT real-time
# 3D; see the icGUIMovie recovery below), and their scrolling prison dossier
# (html/prison/*.html) beneath. Labels from text/gui.csv (pda_* keys). Esc in
# flight brings it back as a pause menu.

const AMBER := Color(1.0, 0.72, 0.1, 0.95)
const AMBER_DIM := Color(1.0, 0.72, 0.1, 0.45)
const AMBER_GLOW := Color(1.0, 0.88, 0.35, 1.0)
const AMBER_TEXT := Color(1.0, 0.81, 0.0, 0.95)  # dossier #ffcf00

# The front-end GUI amber palette, recovered from igui.SetGUIGlobals
# (data/pogsrc/igui.pog:35-46). These are the exact colours the original
# front end tints its controls -- and its prison bust hologram -- with.
const GUI_NEUTRAL := Color(0.600, 0.451, 0.0)   # igui.pog:35-37
const GUI_FOCUSED := Color(1.0, 0.749, 0.0)     # igui.pog:38-40 -- the holo amber
const GUI_SELECTED := Color(1.0, 0.859, 0.278)  # igui.pog:41-43 -- bright sweep
const GUI_FADED := Color(0.5, 0.3745, 0.0)      # igui.pog:44-46 -- dim grid

# The prison bust is NOT real-time 3D. icGUIMovie (iwar2.dll FUN_100169c0,
# registered as a GUI screen movie) pairs "\movies\" + <who> with
# "html:\html\prison\" + <who> (iwar2.dll.c:25002/25022/25333-25337): the bust
# is a PRE-RENDERED 400x400 Bink movie per character -- head, shoulders,
# lighting and the slow rotation are all baked into the video. Six characters
# are registered as icGUIMovie config properties in this order (FUN_10016a60,
# iwar2.dll.c:25089-25123): az, ocal, ycal, jaffs, lori, smith; all default
# OFF, and iActOne.MasterScript enables az/ocal/jaffs/lori/smith at campaign
# start (our port: pog/gen/iactone.gd:2089-2108 -> user://pog_system.cfg
# [icGUIMovie]). The picker starts at a RANDOM index and then CYCLES in order
# on every screen open (FUN_10017850, iwar2.dll.c:25503-25527).
#
# The movie frames are black-backed; the GUI composites them over its amber
# grid page so the grid reads through the dark regions (additive blend), with
# the sweep overlay drawn ON TOP of the movie. The page geometry is EXTRACTED
# from the DLL images (raw .rdata floats dumped and reinterpreted, same trick
# as the HUD palette):
#   HOLO_AMBER = icComms tint FcColour[0], ctor 0x1007f720 (iwar2.dll.c:105107-109)
#                = 0x3f800000,0x3f3fbe77,0 = (1.0, 0.749, 0.0)  (== GUI_FOCUSED)
#   HOLO_SWEEP = comm "speaking" flash DAT_10174fb0 (static init FUN_100e6750)
#                = (1.0, 0.592, 0.0) -- the blink colour, NOT the sweep bar
#   GRID_CELL_PX = DAT_1011d970 = 16.0 -- the same 16-px graph-paper grid every
#                HUD block frame draws (FUN_100e2620); fixed native pixels
#   SWEEP_BAND_PX = DAT_101190b4 = 4.0 -- the sweep is a HARD 4-px additive
#                quad, colour chrome x DAT_1011c034 (0.30), NO halo, NO texture
#                (comm-MFD sweep renderer FUN_10102490 @ 0x10102490 -- the only
#                sweep renderer recovered; the page one is assumed identical)
#   SWEEP_PERIOD = 3.0 s -- y = frac(time_ms * DAT_10118498 (1/3000)) * travel,
#                a top-to-bottom sawtooth (moves DOWN and wraps; the "reflect"
#                branch compares against 0.0 so it never bounces)
#   SCROLL_PX_S = DAT_10117d40 = 18.0 -- dossier scroll px/s (icMovie::Tick
#                0x17e90); when the text has scrolled fully off, the screen
#                ADVANCES to the next character (vtable+0x3c)
#   movie window = 400x400 native px at y=0, x centred between the menu bar's
#                right edge and the screen's right edge (icMovie::MovieView
#                0x18140, raw-disassembled); dossier = movie rect inset 24 px,
#                from movie-bottom+2 to the screen bottom (TextView 0x18220),
#                font:/fonts/handelgothic bt_8pt (FUN_100184b0)
# The GUI is fixed-pixel; we scale by screen height against the 1024x768
# reference (REF_H). Still RECONSTRUCTED (no binary source found): the fine
# scanlines (possibly a video artifact in our references -- the "ucp" texture
# once cited as the scanline pattern is actually the MFD barcode ribbon) and
# the text fade-out under the movie (FcGraphicsEngine::DrawText hard-scissors
# glyphs at the clip rect; the fade matches the reference video, source
# unlocated).
const HOLO_AMBER := Color(1.0, 0.749, 0.0)      # icComms tint (verified)
const HOLO_SWEEP := Color(1.0, 0.592, 0.0)      # comm speaking flash (verified)
const REF_H := 768.0                            # fixed-pixel GUI reference screen
const GRID_CELL_PX := 16.0                      # native px (extracted)
const SWEEP_BAND_PX := 4.0                      # native px (extracted)
const SWEEP_PERIOD := 3.0                       # s per top-to-bottom pass (extracted)
const SWEEP_ALPHA := 0.30                       # chrome x 0.30, additive (extracted)
const SCROLL_PX_S := 18.0                       # dossier px/s at native res (extracted)
const HOLO_SCAN_STEP := 3.0                     # px between scanlines, reconstructed
const HOLO_SCAN_SPEED := 34.0                   # px/sec scanline drift, reconstructed

# The six prison characters, in icGUIMovie property-registration order
# (FUN_10016a60, iwar2.dll.c:25089-25123) -- this is the CYCLE order. Each has
# a movie (data/movies/<who>.ogv, transcoded from movies/<who>.bik) and a
# dossier (data/html/prison/<who>.html).
const MOVIE_CHARS := ["az", "ocal", "ycal", "jaffs", "lori", "smith"]
# What iActOne.MasterScript switches on (ycal stays off in Act One); used as
# the fallback when no pog_system.cfg exists yet (fresh profile, front end).
const ACT_ONE_CHARS := ["az", "ocal", "jaffs", "lori", "smith"]

# the sixteen real systems of the two clusters (the *_dm maps are
# multiplayer arenas)
# [stem, label] or [stem, label, entity to arrive beside]. Lucrecia's Base sits
# in Hoffer's Wake, inside the nebula -- the campaign's home base.
const SYSTEMS := [
	["hoffers_wake", "Hoffer's Wake"],
	["hoffers_wake", "Lucrecia's Base (Nebula)", "Lucrecia's Base"],
	["coyote", "Coyote"],
	["dante", "Dante"], ["kompira", "Kompira"], ["ishime", "Ishime"],
	["batatas", "Batatas"], ["dagda", "Dagda"], ["drake", "Drake"],
	["eureka", "Eureka"], ["firefrost", "Firefrost"],
	["formhault", "Formhault"], ["mwari", "Mwari"],
	["new_bavaria", "New Bavaria"], ["osprey", "Osprey"],
	["owens_star", "Owen's Star"], ["santa_romera", "Santa Romera"],
]

var main: Node3D
var mode := "main"  # main | systems
var sel := 0
var launched := false
# The front end's fancy buttons use GUI_title_font = square721 bdex bt_8pt
# (igui.pog CreateFancyButton -> SetWindowFont, igui.pog:31/245); handelgothic
# bt_12pt DOES ship (fonts/handelgothic bt_12pt.frf in resource.zip) but it is
# the base GUI's "largenumber" font (ibasegui.pog:6), not the menu face.
var _font_small: Font  # Handel Gothic 8pt — dossier body
var _font_title: Font  # Square721 BdEx 8pt — fancy buttons, titles, version
var item_size := 13
var _item_rects: Array = []
var bust_movie: VideoStreamPlayer
var _overlay: Control       # scanline/sweep/dossier layer, drawn OVER the movie
var _top: Control           # buttons + version, normal blend, above everything
var _bar: Control           # icShadyBar black fill (clipped)
var _bar_fx: Control        # icShadyBar detail/flybys/edges, additive (clipped)
var _tex_detail: Texture2D  # images/gui/bar_detail  (icShadyBar::Create)
var _tex_flybys: Texture2D  # images/gui/text_flybys (icShadyBar::Create)
var _tex_glow: Texture2D    # images/gui/cursor_glow (icShadyBar::Create)
var _flybys: Array = []     # 8 slots (the engine's fixed array), h <= 0 = free
var _flyby_timer := 0.0
var _glow_pts: Array = []   # ring of the last 10 mouse positions
var _panel := Rect2()       # the square movie panel, laid out each frame
var _movie_idx := -1        # -1 = "pick a random start", then cycle (FUN_10017850)
var _bust_t := 0.0
var dossier_lines: Array = []  # {text, bold}
var _scroll := 0.0
var _char := ""
var _force_char := ""  # --bustshot pins a specific character
# --bustshot: windowed capture harness. Opens the menu on a fixed character and
# writes two PNGs a fraction of a second apart (to prove the sweep is moving),
# then quits. Not part of the shipped game.
var _shot := false
var _shot_phase := 0
var _shot_t := 0.0
var _shot_chars := ["az", "ocal", "ycal", "jaffs", "lori", "smith"]
var _shot_wait := 0.6
var _shot_idx := 0

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false
	_font_small = Hud.load_game_font(main._base(), "handelgothic bt_8pt.fnt")
	_font_title = Hud.load_game_font(main._base(), "square721 bdex bt_8pt.fnt")
	if _font_title is FontFile and (_font_title as FontFile).fixed_size > 0:
		item_size = (_font_title as FontFile).fixed_size
	var add_mat := CanvasItemMaterial.new()
	add_mat.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	# The left menu bar is the engine's icShadyBar (Render 0x10e7d0; statics
	# dumped from the DLL export table): a BLACK bar at m_bar_alpha 0.8 with,
	# drawn ADDITIVELY on top: two drifting layers of the images/gui/bar_detail
	# weave (m_detail_alpha 0.1), amber edge gradients (m_edge_width 8 px,
	# m_edge_alpha 0.2), and up to 8 "text flyby" glyph strips falling down the
	# bar (images/gui/text_flybys). Split into a normal-blend fill child and an
	# additive fx child, both clipped to the bar.
	_tex_detail = _gui_tex("bar_detail.png")
	_tex_flybys = _gui_tex("text_flybys.png")
	_tex_glow = _gui_tex("cursor_glow.png")
	for i in 8:
		_flybys.append({"h": 0.0})
	_bar = Control.new()
	_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bar.clip_contents = true
	_bar.draw.connect(_draw_bar)
	add_child(_bar)
	_bar_fx = Control.new()
	_bar_fx.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bar_fx.clip_contents = true
	_bar_fx.material = add_mat
	_bar_fx.draw.connect(_draw_bar_fx)
	add_child(_bar_fx)
	# The bust movie. Drawn ADDITIVELY so its black background is transparent and
	# the page's amber grid (parent _draw, i.e. below children) reads through the
	# dark regions of the head, exactly as the original composites it. The
	# scanline/sweep/dossier overlay is a second child ABOVE the movie.
	bust_movie = VideoStreamPlayer.new()
	bust_movie.expand = true
	bust_movie.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bust_movie.material = add_mat
	# icGUIMovie keeps the movie running while the screen is up: restart on end
	bust_movie.finished.connect(func() -> void:
		if visible:
			bust_movie.play())
	add_child(bust_movie)
	_overlay = Control.new()
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# the original draws its page decorations additively (blend state 2 in
	# FUN_10102490), so the sweep BRIGHTENS the face as it passes over it
	_overlay.material = add_mat
	_overlay.draw.connect(_draw_overlay)
	add_child(_overlay)
	# buttons + version render normal-blend above the effect layers
	_top = Control.new()
	_top.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_top.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_top.draw.connect(_draw_top)
	add_child(_top)
	_setup_cursor()
	if "--bustshot" in OS.get_cmdline_user_args():
		_shot = true
		for a in OS.get_cmdline_user_args():
			# --bustwait=N: settle N seconds before the first grab (lets the
			# dossier scroll into the fade band); implies az only
			if a.begins_with("--bustwait="):
				_shot_wait = maxf(float(a.get_slice("=", 1)), 0.1)
				_shot_chars = ["az"]
		_force_char = _shot_chars[0]
		open.call_deferred()

func _setup_cursor() -> void:
	# the original's cursor: the arrow tinted HUD-amber over a glossy glow
	# shadow (images/gui/cursor_glow); the raw PNG is white on black, so
	# derive alpha from luminance like the engine did
	var base: String = main._base()
	var cur := Image.load_from_file(base.path_join(
		"data/textures/images/cursors/pre_alpha_cursor.png"))
	if cur == null:
		return
	var glow := Image.load_from_file(base.path_join(
		"data/textures/images/gui/cursor_glow.png"))
	var w := cur.get_width()
	var h := cur.get_height()
	var canvas := Image.create(w + 6, h + 6, false, Image.FORMAT_RGBA8)
	if glow != null:
		glow.resize(w + 6, h + 6)
		for y in canvas.get_height():
			for x in canvas.get_width():
				var g := glow.get_pixel(x, y)
				var ga := maxf(g.r, maxf(g.g, g.b))
				canvas.set_pixel(x, y, Color(0.35, 0.22, 0.0, ga * 0.85))
	for y in h:
		for x in w:
			var p := cur.get_pixel(x, y)
			var lum := maxf(p.r, maxf(p.g, p.b))
			if lum > 0.05:
				var c := Color(1.0, 0.78, 0.1) * lum
				canvas.set_pixel(x, y, Color(c.r, c.g, c.b, 1.0))
	Input.set_custom_mouse_cursor(ImageTexture.create_from_image(canvas))

# The characters currently switched on in the icGUIMovie config section --
# written by our port of iActOne.MasterScript (pog/gen/iactone.gd:2089-2108)
# through the POG config store (pog/natives/ui.gd _cfg_*), which lives at
# user://pog_system.cfg.
func _enabled_chars() -> Array:
	var cfg := ConfigFile.new()
	cfg.load("user://pog_system.cfg")  # a missing file is just an empty store
	var out: Array = []
	for who in MOVIE_CHARS:
		if int(cfg.get_value("icGUIMovie", str(who), 0)) == 1:
			out.append(who)
	return out if not out.is_empty() else ACT_ONE_CHARS.duplicate()

func _pick_character() -> void:
	# random start, then cycle in registration order on each open (FUN_10017850)
	var chars := _enabled_chars()
	var who: String
	if _force_char != "":
		who = _force_char
	else:
		if _movie_idx < 0:
			_movie_idx = randi() % chars.size()
		else:
			_movie_idx = (_movie_idx + 1) % chars.size()
		who = str(chars[_movie_idx])
	_char = who
	var vs := VideoStreamTheora.new()
	vs.file = main._base().path_join("data/movies/%s.ogv" % who)
	bust_movie.stream = vs
	bust_movie.play()
	_load_dossier(_char)
	_scroll = 0.0

func _load_dossier(who: String) -> void:
	# html/prison/<who>.html, stripped to amber text; <b> heads stay bright
	dossier_lines.clear()
	# data/html is transcoded to UTF-8 at extraction (tools/iw2/html_text.py)
	var path: String = main._base().path_join("data/html/prison/%s.html" % who)
	if not FileAccess.file_exists(path):
		return
	var raw := FileAccess.get_file_as_string(path)
	var body := raw.get_slice("<BODY>", 1) if "<BODY>" in raw else raw
	# HTML: raw newlines are just whitespace; only <p>/<br> break lines. The
	# source files hard-wrap their paragraphs, so folding \n to spaces first is
	# what lets each paragraph reflow to the column width like the original.
	body = body.replace("\r\n", "\n").replace("\r", "\n")
	body = body.replace("\n", " ").replace("\t", " ")
	body = body.replace("<p>", "\n\n").replace("<P>", "\n\n")
	body = body.replace("<br>", "\n").replace("<BR>", "\n")
	body = body.replace("&nbsp;", " ")
	var re := RegEx.new()
	re.compile("<b>(.*?)</b>")
	body = re.sub(body, "$1", true)
	var re2 := RegEx.new()
	re2.compile("<[^>]*>")
	body = re2.sub(body, "", true)
	for para in body.split("\n"):
		var line := para.strip_edges()
		if line.is_empty():
			if not dossier_lines.is_empty() and dossier_lines[-1]["text"] != "":
				dossier_lines.append({"text": "", "bold": false})
			continue
		var bold := "" in line
		line = line.replace("", "")
		# wrap to the dossier column width -- in the reference the column is
		# ~93% of the movie panel's width (which is 0.521 x screen height)
		var wrap_w := get_viewport_rect().size.y * 0.521 * 0.93
		var words := line.split(" ")
		var cur := ""
		for w in words:
			var trial := (cur + " " + w).strip_edges()
			if _font_small.get_string_size(trial, HORIZONTAL_ALIGNMENT_LEFT,
					-1, 12).x > wrap_w:
				dossier_lines.append({"text": cur, "bold": bold})
				cur = w
			else:
				cur = trial
		if cur != "":
			dossier_lines.append({"text": cur, "bold": bold})

func _unhandled_input(event: InputEvent) -> void:
	# the menu owns its input: it must keep working while the tree is paused
	if main.movie != null or main.demo:
		return
	# ...except during a cutscene, where Escape means "skip", not "pause". The
	# menu sits deeper in the tree than main, so without this it would swallow
	# the key before main ever saw it.
	if not visible and main.in_cutscene():
		return
	if visible:
		handle(event)
		# During a NEW GAME the scene reloads out from under us; a queued input
		# event can still reach this node the frame it leaves the tree, when
		# get_viewport() is null.
		if is_inside_tree():
			get_viewport().set_input_as_handled()
	elif event is InputEventKey and event.pressed and not event.echo \
			and event.physical_keycode == KEY_ESCAPE:
		open()  # Escape = PDA / pause

func open() -> void:
	visible = true
	mode = "main"
	sel = 0
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_pick_character()
	if launched:
		# pause the simulation like the original; UI/audio stay live
		# (the CanvasLayer and AudioManager are PROCESS_MODE_ALWAYS)
		get_tree().paused = true
		for p in [main.audio.engine_player, main.audio.thruster_player,
				main.audio.lds_player]:
			p.stream_paused = true

func close() -> void:
	visible = false
	bust_movie.stop()
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	get_tree().paused = false
	for p in [main.audio.engine_player, main.audio.thruster_player,
			main.audio.lds_player]:
		p.stream_paused = false
	main.fire_lock = 0.3  # the confirming click must not fire the PBC

func _items() -> Array:
	# [label, enabled]; labels are the original pda_* strings
	if mode == "systems":
		var out: Array = []
		for s in SYSTEMS:
			out.append([s[1].to_upper(), true])
		out.append(["< BACK", true])
		return out
	if launched:
		return [["RESUME", true], ["NEW GAME", true], ["SAVE GAME", false],
			["SELECT SYSTEM", true], ["QUIT", true]]
	return [["START NEW GAME", true], ["LOAD GAME", false],
		["INSTANT ACTION", true], ["EXTRAS", true],
		["MULTIPLAYER", false], ["OPTIONS", false],
		["MOVIES", true], ["CREDITS", false], ["QUIT", true]]

func _activate() -> void:
	var items := _items()
	if not items[sel][1]:
		main.audio.play("audio/hud/invalid_input.wav", -10.0)
		return
	if mode == "systems":
		if sel == items.size() - 1:
			main.audio.play("audio/gui/contract.wav", -8.0)
			mode = "main"
			sel = 0
			return
		main.audio.play("audio/gui/confirm.wav", -6.0)
		var pick: Array = SYSTEMS[sel]
		main.start_in_system(str(pick[0]),
			str(pick[2]) if pick.size() > 2 else "")
		launched = true
		close()
		return
	if launched:
		match sel:
			0:  # RESUME
				main.audio.play("audio/gui/mechanical_confirm.wav", -6.0)
				close()
			1:  # NEW GAME -- restart the campaign from the top
				main.audio.play("audio/gui/confirm.wav", -6.0)
				close()
				main.restart_campaign()
			3:  # SELECT SYSTEM
				main.audio.play("audio/gui/expand.wav", -8.0)
				mode = "systems"
				sel = 0
			4:  # QUIT
				get_tree().quit()
		return
	match sel:
		0:  # START NEW GAME
			main.audio.play("audio/gui/confirm.wav", -6.0)
			launched = true
			close()
			main.start_campaign()
		2:  # INSTANT ACTION: free flight in the commissioned tug
			main.audio.play("audio/gui/mechanical_confirm.wav", -6.0)
			launched = true
			close()
		3:  # EXTRAS: system select
			main.audio.play("audio/gui/expand.wav", -8.0)
			mode = "systems"
			sel = 0
		6:  # MOVIES: replay the intro
			main.audio.play("audio/gui/confirm.wav", -6.0)
			visible = false
			main._play_movie("intro", func() -> void: pass)
		8:
			get_tree().quit()

func handle(event: InputEvent) -> void:
	# input is routed here by main while the menu is open
	if event is InputEventKey and event.pressed and not event.echo:
		var items := _items()
		match event.physical_keycode:
			KEY_UP:
				sel = (sel - 1 + items.size()) % items.size()
				main.audio.play("audio/gui/minor.wav", -12.0)
			KEY_DOWN:
				sel = (sel + 1) % items.size()
				main.audio.play("audio/gui/minor.wav", -12.0)
			KEY_ENTER, KEY_KP_ENTER, KEY_SPACE:
				_activate()
			KEY_ESCAPE:
				# Escape backs out of a screen. It never quits the game: that
				# is what the QUIT item is for, and losing a campaign to a
				# stray keypress is not a feature.
				if mode == "systems":
					mode = "main"
					sel = 0
				elif launched:
					close()
	if event is InputEventMouseMotion:
		for i in _item_rects.size():
			if _item_rects[i].has_point(event.position) and sel != i:
				sel = i
				main.audio.play("audio/gui/minor.wav", -12.0)
	if event is InputEventMouseButton and event.pressed \
			and event.button_index == MOUSE_BUTTON_LEFT:
		for i in _item_rects.size():
			if _item_rects[i].has_point(event.position):
				sel = i
				_activate()

func _process(delta: float) -> void:
	if not visible:
		return
	_bust_t += delta
	# dossier scroll: 18 px/s at native res (DAT_10117d40, icMovie::Tick),
	# scaled with the fixed-pixel page
	_scroll += delta * SCROLL_PX_S * get_viewport_rect().size.y / REF_H
	_layout_movie()
	# when the dossier has scrolled fully off, the original advances to the
	# NEXT character (icMovie::Tick 0x17e90 -> vtable+0x3c)
	if not dossier_lines.is_empty() \
			and _scroll > dossier_lines.size() * 17.0 + _panel.size.y * 0.19:
		_pick_character()
	_tick_flybys(delta)
	# icShadyBar keeps a ring of the last 10 mouse positions for the cursor
	# glow trail (Render 0x10e7d0, sampled once per frame)
	_glow_pts.push_front({"pos": get_viewport().get_mouse_position(),
			"hot": Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)})
	if _glow_pts.size() > 10:
		_glow_pts.resize(10)
	queue_redraw()
	_bar.queue_redraw()
	_bar_fx.queue_redraw()
	_overlay.queue_redraw()
	_top.queue_redraw()
	if _shot:
		_bustshot_step(delta)

func _layout_movie() -> void:
	# The movie is square (400x400 source) and the original GUI draws it at its
	# NATIVE pixel size in a fixed-pixel window layout: on the reference video's
	# 1024x768 screen that is 400/768 = 0.521 of the screen height, with the
	# window's top edge ~9% down and the head sitting in the UPPER half of the
	# screen (dossier column below). Fixed-pixel windows don't scale to modern
	# resolutions, so we keep the 1024x768 proportions.
	var s := get_viewport_rect().size
	var strip_w := _strip_w()
	var side := s.y * 0.521
	_panel = Rect2(Vector2(strip_w + (s.x - strip_w - side) / 2.0, s.y * 0.09),
			Vector2(side, side))
	bust_movie.position = _panel.position
	bust_movie.size = _panel.size
	bust_movie.visible = mode != "systems"
	_bar.position = Vector2.ZERO
	_bar.size = Vector2(strip_w, s.y)
	_bar_fx.position = Vector2.ZERO
	_bar_fx.size = Vector2(strip_w, s.y)

func _bustshot_step(delta: float) -> void:
	# for each character: settle, grab frame A, wait ~1/8 s, grab frame B (so the
	# sweep's motion is provable), then move to the next character; quit at the end
	_shot_t += delta
	var dir: String = main._base().path_join("data/screenshots")
	DirAccess.make_dir_recursive_absolute(dir)
	var who: String = _shot_chars[_shot_idx]
	if _force_char != who:
		_force_char = who
		_pick_character()
	match _shot_phase:
		0:
			if _shot_t > _shot_wait:
				_grab(dir.path_join("bustshot_%s_a.png" % who))
				_shot_phase = 1
				_shot_t = 0.0
		1:
			if _shot_t > 0.14:
				_grab(dir.path_join("bustshot_%s_b.png" % who))
				_shot_phase = 2
				_shot_t = 0.0
		2:
			if _shot_t > 0.1:
				_shot_idx += 1
				if _shot_idx >= _shot_chars.size():
					get_tree().quit()
				else:
					_shot_phase = 0
					_shot_t = 0.0

func _grab(path: String) -> void:
	var img := get_viewport().get_texture().get_image()
	img.save_png(path)
	print("BUSTSHOT wrote ", path, " ", img.get_size())

func _stadium(r: Rect2, col: Color, width: float, glow: bool) -> void:
	# the original's capsule button outline (drawn on the _top layer, above
	# the bar and the page effects)
	var rad := r.size.y / 2.0
	var lc := Vector2(r.position.x + rad, r.position.y + rad)
	var rc := Vector2(r.end.x - rad, r.position.y + rad)
	_top.draw_rect(Rect2(r.position + Vector2(rad, 0),
			Vector2(r.size.x - rad * 2, r.size.y)), Color(0.07, 0.05, 0.0, 0.85))
	_top.draw_circle(lc, rad, Color(0.07, 0.05, 0.0, 0.85))
	_top.draw_circle(rc, rad, Color(0.07, 0.05, 0.0, 0.85))
	if glow:
		_top.draw_arc(lc, rad + 2, PI / 2, PI * 1.5, 16,
				Color(col.r, col.g, col.b, 0.35), width + 3.0, true)
		_top.draw_arc(rc, rad + 2, -PI / 2, PI / 2, 16,
				Color(col.r, col.g, col.b, 0.35), width + 3.0, true)
		_top.draw_line(Vector2(lc.x, r.position.y - 2), Vector2(rc.x, r.position.y - 2),
				Color(col.r, col.g, col.b, 0.35), width + 3.0, true)
		_top.draw_line(Vector2(lc.x, r.end.y + 2), Vector2(rc.x, r.end.y + 2),
				Color(col.r, col.g, col.b, 0.35), width + 3.0, true)
	_top.draw_arc(lc, rad, PI / 2, PI * 1.5, 16, col, width, true)
	_top.draw_arc(rc, rad, -PI / 2, PI / 2, 16, col, width, true)
	_top.draw_line(Vector2(lc.x, r.position.y), Vector2(rc.x, r.position.y),
			col, width, true)
	_top.draw_line(Vector2(lc.x, r.end.y), Vector2(rc.x, r.end.y), col, width, true)

func _gui_tex(name: String) -> Texture2D:
	var img := Image.load_from_file(main._base().path_join(
			"data/textures/images/gui/" + name))
	if img == null:
		return null
	return ImageTexture.create_from_image(img)

func _strip_w() -> float:
	# GUI_shader_width = 240 native px (igui.pog:7), fixed-pixel scaled
	return get_viewport_rect().size.y * 240.0 / REF_H

func _draw_bar() -> void:
	# icShadyBar bar fill: BLACK (m_bar_colour statics zero, FUN_1010df20) at
	# m_bar_alpha 0.8 -- the same value igui.pog calls GUI_shader_opacity
	if not visible:
		return
	_bar.draw_rect(Rect2(Vector2.ZERO, _bar.size), Color(0, 0, 0, 0.8))

func _tick_flybys(delta: float) -> void:
	# icShadyBar::Render flyby spawner: 8 slots; a strip enters from the TOP
	# (y starts at 1 - height) and slides DOWN at 25..90 px/s
	# (m_min/max_flyby_speed); height = 13 (m_flyby_ch) x rand(3..30)
	# (0x1010e200/0x1010e230); x random inside the edges, snapped to the 16-px
	# glyph column (m_flyby_cw); the next spawn comes 0..6 s later
	# (m_min/max_flyby_time)
	var h := get_viewport_rect().size.y
	for f in _flybys:
		if f["h"] > 0.0:
			f["y"] += f["speed"] * delta
			if f["y"] > h:
				f["h"] = 0.0
	_flyby_timer -= delta
	if _flyby_timer > 0.0:
		return
	_flyby_timer = randf_range(0.0, 6.0)
	for i in _flybys.size():
		var f: Dictionary = _flybys[i]
		if f["h"] <= 0.0:
			f["h"] = 13.0 * randf_range(3.0, 30.0)
			f["speed"] = randf_range(25.0, 90.0)
			f["x"] = floorf(randf_range(8.0, maxf(8.0, _strip_w() - 24.0))
					/ 16.0) * 16.0
			f["y"] = 1.0 - f["h"]
			f["slot"] = i
			break

func _draw_bar_fx() -> void:
	# the additive passes of icShadyBar::Render, clipped to the bar
	if not visible:
		return
	var w := _bar_fx.size.x
	var h := _bar_fx.size.y
	var amber := GUI_FOCUSED                     # m_detail/glow colour (1,0.749,0)
	# two drifting layers of the 128px bar_detail weave, m_detail_alpha 0.1;
	# u drifts +, v drifts - at (t_ms x 0.001)/20 texture/s (DAT_1011803c /
	# DAT_1011e848 / m_u/v_scroll_rate) = 6.4 px/s. The second layer is the
	# same texture at DOUBLE scale (the original also mirrors it in u; the
	# weave is symmetric, so the mirror is skipped).
	var dcol := Color(amber.r, amber.g, amber.b, 0.1)
	var drift := fmod(_bust_t * 6.4, 128.0)
	if _tex_detail != null:
		_bar_fx.draw_texture_rect(_tex_detail,
				Rect2(Vector2(drift - 128.0, -drift), Vector2(w + 256, h + 256)),
				true, dcol)
		_bar_fx.draw_set_transform(Vector2.ZERO, 0.0, Vector2(2, 2))
		_bar_fx.draw_texture_rect(_tex_detail,
				Rect2(Vector2(drift * 0.5 - 128.0, -drift * 0.5),
					Vector2(w * 0.5 + 256, h * 0.5 + 256)), true, dcol)
		_bar_fx.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	# text flybys: a 16-px glyph column of text_flybys, v anchored to SCREEN
	# space (v = y/128, DAT_1011ccb8 = 1/128 -- the glyphs stay put and the
	# strip is a sliding reveal window), alpha ramping 0 (top) -> 0.2
	# (DAT_101184ac) at the strip's bottom edge; the glyph column flickers
	# with the strip's position ((int(y + h) + slot) & 7)
	if _tex_flybys != null:
		for f in _flybys:
			if f["h"] <= 0.0:
				continue
			var fy: float = f["y"]
			var fh: float = f["h"]
			var col_i: int = (int(fy + fh) + int(f["slot"])) & 7
			var y_end := minf(fy + fh, h)
			var row_y := maxf(fy, 0.0)
			while row_y < y_end:
				var rh := minf(13.0, y_end - row_y)
				var a := clampf((row_y + rh - fy) / fh, 0.0, 1.0) * 0.2
				var fcol := Color(amber.r, amber.g, amber.b, a)
				var v := fposmod(row_y, 128.0)
				var piece := minf(rh, 128.0 - v)
				_bar_fx.draw_texture_rect_region(_tex_flybys,
						Rect2(f["x"], row_y, 16.0, piece),
						Rect2(col_i * 16.0, v, 16.0, piece), fcol)
				if piece < rh:
					_bar_fx.draw_texture_rect_region(_tex_flybys,
							Rect2(f["x"], row_y + piece, 16.0, rh - piece),
							Rect2(col_i * 16.0, 0.0, 16.0, rh - piece), fcol)
				row_y += rh
	# edge gradients: m_edge_width 8 px at m_edge_alpha 0.2, brightest AT the
	# edge, fading inward; drawn on both vertical edges
	var e0 := Color(amber.r, amber.g, amber.b, 0.0)
	var e1 := Color(amber.r, amber.g, amber.b, 0.2)
	_bar_fx.draw_polygon(
			PackedVector2Array([Vector2(0, 0), Vector2(8, 0),
				Vector2(8, h), Vector2(0, h)]),
			PackedColorArray([e1, e0, e0, e1]))
	_bar_fx.draw_polygon(
			PackedVector2Array([Vector2(w - 8, 0), Vector2(w, 0),
				Vector2(w, h), Vector2(w - 8, h)]),
			PackedColorArray([e0, e1, e1, e0]))

func _holo_grid(rect: Rect2) -> void:
	# the page's amber GRID: the engine's 16-native-px graph-paper grid, the
	# same one every HUD block frame draws (DAT_1011d970 = 16.0, FUN_100e2620),
	# scaled by screen height against the 1024x768 reference. Grid colour dim =
	# GUI_FADED (igui.pog:44-46); the alpha is reconstructed.
	var cell := rect.end.y * GRID_CELL_PX / REF_H
	var g := Color(GUI_FADED.r, GUI_FADED.g, GUI_FADED.b, 0.24)
	var x := rect.position.x
	while x <= rect.end.x:
		draw_line(Vector2(x, rect.position.y), Vector2(x, rect.end.y), g, 1.0)
		x += cell
	var y := rect.position.y
	while y <= rect.end.y:
		draw_line(Vector2(rect.position.x, y), Vector2(rect.end.x, y), g, 1.0)
		y += cell

func _holo_overlay(panel: Rect2) -> void:
	# Drawn on _overlay, ABOVE the movie. Horizontal SCANLINES scrolling slowly
	# (icHUDTargetMFD scrolls the panel/scanline texture in V, iwar2.dll.c:
	# 195797-804; texture images/hud/ucp). Reconstructed spacing/rate.
	var drift := fmod(_bust_t * HOLO_SCAN_SPEED, HOLO_SCAN_STEP)
	var sc := Color(HOLO_AMBER.r, HOLO_AMBER.g, HOLO_AMBER.b, 0.10)
	var y := panel.position.y + drift
	while y < panel.end.y:
		_overlay.draw_line(Vector2(panel.position.x, y),
				Vector2(panel.end.x, y), sc, 1.0)
		y += HOLO_SCAN_STEP
	# the SWEEP: extracted from the comm-MFD sweep renderer (FUN_10102490) --
	# a HARD 4-native-px additive quad in the page chrome at 0.30 alpha, no
	# halo, no hot line, no texture, sweeping DOWN the page as a 3.0 s sawtooth
	# (the soft glow around it in video references is encoder bloom, not
	# geometry). The overlay canvas item is additive, like the original blend.
	var band_h := get_viewport_rect().size.y * SWEEP_BAND_PX / REF_H
	var frac := fmod(_bust_t / SWEEP_PERIOD, 1.0)
	var y0 := panel.position.y + frac * (panel.size.y - band_h)
	_overlay.draw_rect(Rect2(panel.position.x, y0, panel.size.x, band_h),
			Color(HOLO_AMBER.r, HOLO_AMBER.g, HOLO_AMBER.b, SWEEP_ALPHA))

func _draw_overlay() -> void:
	# the layer ABOVE the movie: scanlines + sweep across the open area, and the
	# scrolling dossier in the panel's lower-left (the original draws the HTML
	# into the movie window's TextView; position measured from reference).
	if not visible or mode == "systems":
		return
	var s := get_viewport_rect().size
	# the page effects span the WHOLE screen, bar included (in the reference
	# the sweep crosses the menu bar too)
	_holo_overlay(Rect2(0.0, 0.0, s.x, s.y))
	# cursor glow trail (icShadyBar::Render, glow pass): images/gui/cursor_glow
	# at DOUBLE its texture size on the last 10 mouse positions, m_glow_alpha
	# 0.1 falling off 0.1 per sample (DAT_1011d0cc), doubled while the button
	# is held. Only the in-game bars render with glow=true; the front end
	# passes false.
	if launched and _tex_glow != null:
		var gs: Vector2 = _tex_glow.get_size() * 2.0
		for i in _glow_pts.size():
			var g: Dictionary = _glow_pts[i]
			var ga: float = 0.1 * (1.0 - i * 0.1) * (2.0 if g["hot"] else 1.0)
			_overlay.draw_texture_rect(_tex_glow, Rect2(g["pos"] - gs / 2.0, gs),
					false, Color(GUI_FOCUSED.r, GUI_FOCUSED.g, GUI_FOCUSED.b, ga))
	# The dossier is a tall column BELOW the movie window (left edge just inside
	# the panel's), running to the bottom of the screen. Lines scroll upward and
	# FADE OUT as they slide under the movie's bottom edge -- in the reference
	# the fade band is the ~19%-of-panel gap between the movie and the first
	# fully-bright line. Positions measured from the reference video (1024x768).
	if dossier_lines.is_empty():
		return
	var dx := _panel.position.x + _panel.size.x * 0.05
	var line_h := 17.0
	var fade_top := _panel.end.y               # movie bottom: alpha 0 here
	var fade_h := _panel.size.y * 0.19         # fully bright below this band
	var start_y := fade_top + fade_h           # first line starts fully bright
	var y_bottom := s.y - 12.0
	var total := dossier_lines.size()
	for idx in total:
		var ypos := start_y + idx * line_h - _scroll
		if ypos < fade_top or ypos > y_bottom:
			continue
		var entry: Dictionary = dossier_lines[idx]
		var a := clampf((ypos - fade_top) / fade_h, 0.0, 1.0)
		var col2: Color = AMBER_GLOW if entry["bold"] else AMBER_TEXT
		_overlay.draw_string(_font_small, Vector2(dx, ypos), str(entry["text"]),
				HORIZONTAL_ALIGNMENT_LEFT, -1, 12,
				Color(col2.r, col2.g, col2.b, col2.a * a))

func _draw() -> void:
	# the page floor: black + the fullscreen amber grid. Everything else lives
	# on the child layers: _bar/_bar_fx (icShadyBar), the bust movie (additive),
	# _overlay (sweep/scanlines/dossier/glow, additive), _top (buttons/version).
	var s := get_viewport_rect().size
	draw_rect(Rect2(Vector2.ZERO, s), Color(0.0, 0.0, 0.0, 1.0))
	_holo_grid(Rect2(Vector2.ZERO, s))

func _draw_top() -> void:
	if not visible:
		return
	var s := get_viewport_rect().size
	var strip_w := _strip_w()
	# The GUI is fixed-pixel at the 1024x768 reference; the bar width already
	# scales with height (_strip_w), so the button metrics and the FONT must
	# scale by the same factor or small windows overflow the capsules.
	var sc := s.y / REF_H
	var fs := maxi(roundi(item_size * sc), 8)
	# capsule buttons
	_item_rects.clear()
	var items := _items()
	var bh := 24.0 * sc
	var gap := clampf((s.y - 90.0 * sc) / items.size() - bh, 8.0 * sc, 34.0 * sc)
	var y := 42.0 * sc
	var bw := strip_w - 52.0 * sc
	# one shared size fitted to the WIDEST label, so the column stays uniform
	var max_w := bw - 32.0 * sc
	var widest := 0.0
	for it in items:
		widest = maxf(widest, _font_title.get_string_size(str(it[0]),
				HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x)
	while fs > 8 and widest > max_w:
		fs -= 1
		widest = 0.0
		for it in items:
			widest = maxf(widest, _font_title.get_string_size(str(it[0]),
					HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x)
	for i in items.size():
		var enabled: bool = items[i][1]
		var col := AMBER_GLOW if i == sel else (AMBER if enabled else
			Color(AMBER.r, AMBER.g, AMBER.b, 0.22))
		var r := Rect2(Vector2(28.0 * sc, y), Vector2(bw, bh))
		_stadium(r, col, 1.6 if i == sel else 1.2, i == sel)
		var label: String = items[i][0]
		_top.draw_string(_font_title, r.position + Vector2(16.0 * sc, bh - 7.0 * sc),
				label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs,
				col if enabled else Color(col.r, col.g, col.b, 0.35))
		_item_rects.append(r.grow(4))
		y += bh + gap
	# version line, bottom right, like "Edge of Chaos F14.6"
	var ver := "Edge of Chaos R1.0"
	var vw := _font_title.get_string_size(ver, HORIZONTAL_ALIGNMENT_LEFT, -1,
			fs).x
	_top.draw_string(_font_title, Vector2(s.x - vw - 14.0 * sc, s.y - 10.0 * sc),
			ver, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, AMBER_TEXT)
