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
# the scanline/sweep overlay drawn ON TOP of the movie:
#   HOLO_AMBER = icComms tint FcColour[0], ctor 0x1007f720 (iwar2.dll.c:105107-109)
#                = 0x3f800000,0x3f3fbe77,0 = (1.0, 0.749, 0.0)  (== GUI_FOCUSED)
#   HOLO_SWEEP = sweep-flash colour DAT_10174fb0, FUN_100e6750 0x100e6750
#                (iwar2.dll.c:195396-398) = 0x3f800000,0x3f178d50,0 = (1.0,0.592,0.0)
# The sweep motion is time-driven, wrapped 0..1 (iwar2.dll.c:195961-967),
# sweeping UP. Grid cell size, scanline spacing and the sweep band height /
# scroll rates are .rdata floats the decomp left un-inlined (UNKNOWN); cell,
# spacing and band height below are measured from an original screenshot
# (band ~40px of a ~725px panel ≈ 0.055, a narrow bright bar with a soft warm
# halo -- not a wide smear), the rates reconstructed to match its motion.
const HOLO_AMBER := Color(1.0, 0.749, 0.0)      # icComms tint (verified)
const HOLO_SWEEP := Color(1.0, 0.592, 0.0)      # sweep flash (verified)
const HOLO_GRID_CELL := 30.0                    # px, reconstructed (baked in panel tex)
const HOLO_SCAN_STEP := 3.0                     # px between scanlines, reconstructed
const HOLO_SWEEP_SPEED := 0.28                  # panel-heights/sec up, reconstructed
const HOLO_SWEEP_FRAC := 0.02                   # core bar height / panel, from ref
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
var _font: Font        # Handel Gothic 12pt — the original GUI face
var _font_small: Font  # Handel Gothic 8pt — dossier body
var _font_title: Font  # Square721 BdEx — version line
var item_size := 13
var _item_rects: Array = []
var bust_movie: VideoStreamPlayer
var _overlay: Control       # scanline/sweep/dossier layer, drawn OVER the movie
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
	_font = Hud.load_game_font(main._base(), "handelgothic bt_12pt.fnt")
	_font_small = Hud.load_game_font(main._base(), "handelgothic bt_8pt.fnt")
	_font_title = Hud.load_game_font(main._base(), "square721 bdex bt_8pt.fnt")
	# The bust movie. Drawn ADDITIVELY so its black background is transparent and
	# the page's amber grid (parent _draw, i.e. below children) reads through the
	# dark regions of the head, exactly as the original composites it. The
	# scanline/sweep/dossier overlay is a second child ABOVE the movie.
	bust_movie = VideoStreamPlayer.new()
	bust_movie.expand = true
	bust_movie.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var add_mat := CanvasItemMaterial.new()
	add_mat.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	bust_movie.material = add_mat
	# icGUIMovie keeps the movie running while the screen is up: restart on end
	bust_movie.finished.connect(func() -> void:
		if visible:
			bust_movie.play())
	add_child(bust_movie)
	_overlay = Control.new()
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_overlay.draw.connect(_draw_overlay)
	add_child(_overlay)
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
	_scroll += delta * 14.0
	_layout_movie()
	queue_redraw()
	_overlay.queue_redraw()
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
	var strip_w := clampf(s.x * 0.21, 260, 340)
	var side := s.y * 0.521
	_panel = Rect2(Vector2(strip_w + (s.x - strip_w - side) / 2.0, s.y * 0.09),
			Vector2(side, side))
	bust_movie.position = _panel.position
	bust_movie.size = _panel.size
	bust_movie.visible = mode != "systems"

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
	# the original's capsule button outline
	var rad := r.size.y / 2.0
	var lc := Vector2(r.position.x + rad, r.position.y + rad)
	var rc := Vector2(r.end.x - rad, r.position.y + rad)
	draw_rect(Rect2(r.position + Vector2(rad, 0),
			Vector2(r.size.x - rad * 2, r.size.y)), Color(0.07, 0.05, 0.0, 0.85))
	draw_circle(lc, rad, Color(0.07, 0.05, 0.0, 0.85))
	draw_circle(rc, rad, Color(0.07, 0.05, 0.0, 0.85))
	if glow:
		draw_arc(lc, rad + 2, PI / 2, PI * 1.5, 16,
				Color(col.r, col.g, col.b, 0.35), width + 3.0, true)
		draw_arc(rc, rad + 2, -PI / 2, PI / 2, 16,
				Color(col.r, col.g, col.b, 0.35), width + 3.0, true)
		draw_line(Vector2(lc.x, r.position.y - 2), Vector2(rc.x, r.position.y - 2),
				Color(col.r, col.g, col.b, 0.35), width + 3.0, true)
		draw_line(Vector2(lc.x, r.end.y + 2), Vector2(rc.x, r.end.y + 2),
				Color(col.r, col.g, col.b, 0.35), width + 3.0, true)
	draw_arc(lc, rad, PI / 2, PI * 1.5, 16, col, width, true)
	draw_arc(rc, rad, -PI / 2, PI / 2, 16, col, width, true)
	draw_line(Vector2(lc.x, r.position.y), Vector2(rc.x, r.position.y),
			col, width, true)
	draw_line(Vector2(lc.x, r.end.y), Vector2(rc.x, r.end.y), col, width, true)

func _circuit_strip(w: float, h: float) -> void:
	# faint amber circuit-board traces down the left strip
	draw_rect(Rect2(0, 0, w, h), Color(0.03, 0.025, 0.0, 0.92))
	var rng := RandomNumberGenerator.new()
	rng.seed = 42
	var trace := Color(1.0, 0.72, 0.1, 0.06)
	var trace2 := Color(1.0, 0.72, 0.1, 0.12)
	for i in 26:
		var x := rng.randf_range(4, w - 4)
		var y0 := rng.randf_range(0, h)
		var len := rng.randf_range(40, 300)
		draw_line(Vector2(x, y0), Vector2(x, minf(y0 + len, h)),
				trace2 if i % 3 == 0 else trace, 1.0)
		if i % 2 == 0:
			var x2 := clampf(x + rng.randf_range(-40, 40), 4, w - 4)
			draw_line(Vector2(x, y0), Vector2(x2, y0), trace, 1.0)
			draw_rect(Rect2(x2 - 1.5, y0 - 1.5, 3, 3), trace2)
	for gy in range(0, int(h), 48):
		draw_line(Vector2(0, gy), Vector2(w, gy), Color(1, 0.72, 0.1, 0.025), 1.0)
	draw_line(Vector2(w, 0), Vector2(w, h), AMBER_DIM, 1.5, true)

func _holo_grid(rect: Rect2) -> void:
	# the front end's fine amber GRID (grid dim = GUI_FADED, igui.pog:44-46). The
	# engine bakes the grid into its panel texture, so the cell size here is
	# reconstructed (HOLO_GRID_CELL). It covers the whole screen.
	var g := Color(GUI_FADED.r, GUI_FADED.g, GUI_FADED.b, 0.24)
	var x := rect.position.x
	while x <= rect.end.x:
		draw_line(Vector2(x, rect.position.y), Vector2(x, rect.end.y), g, 1.0)
		x += HOLO_GRID_CELL
	var y := rect.position.y
	while y <= rect.end.y:
		draw_line(Vector2(rect.position.x, y), Vector2(rect.end.x, y), g, 1.0)
		y += HOLO_GRID_CELL

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
	# the bright SWEEP band, moving UP the panel and wrapping (time-driven wrap,
	# iwar2.dll.c:195961-967; colour = sweep flash HOLO_SWEEP, iwar2.dll.c:
	# 195396-398). In the reference it is a THIN hard bar -- ~2% of the panel,
	# with a hot centre line -- inside a dim warm halo ~4.5x as tall. Nothing
	# like a wide smear: the bar reads as a single scan line passing over the
	# page.
	var band_h := panel.size.y * HOLO_SWEEP_FRAC
	var halo_h := band_h * 4.5
	var frac := fmod(_bust_t * HOLO_SWEEP_SPEED, 1.0)
	var cy := panel.end.y - frac * (panel.size.y + halo_h) + halo_h * 0.5
	var steps := 10
	for i in steps:
		var t := float(i) / float(steps - 1)              # 0..1 across the halo
		var yy := cy - halo_h * 0.5 + t * halo_h
		if yy < panel.position.y or yy > panel.end.y:
			continue
		var a := 1.0 - absf(t - 0.5) * 2.0                # soft triangular falloff
		_overlay.draw_line(Vector2(panel.position.x, yy),
				Vector2(panel.end.x, yy),
				Color(HOLO_SWEEP.r, HOLO_SWEEP.g, HOLO_SWEEP.b, a * 0.16),
				halo_h / float(steps) + 1.0)
	var top := clampf(cy - band_h * 0.5, panel.position.y, panel.end.y)
	var bot := clampf(cy + band_h * 0.5, panel.position.y, panel.end.y)
	if bot > top:
		_overlay.draw_rect(Rect2(panel.position.x, top, panel.size.x, bot - top),
				Color(HOLO_SWEEP.r, HOLO_SWEEP.g, HOLO_SWEEP.b, 0.70))
		if cy > panel.position.y and cy < panel.end.y:
			_overlay.draw_line(Vector2(panel.position.x, cy),
					Vector2(panel.end.x, cy), Color(1.0, 0.85, 0.30, 0.80), 2.0)

func _draw_overlay() -> void:
	# the layer ABOVE the movie: scanlines + sweep across the open area, and the
	# scrolling dossier in the panel's lower-left (the original draws the HTML
	# into the movie window's TextView; position measured from reference).
	if not visible or mode == "systems":
		return
	var s := get_viewport_rect().size
	var strip_w := clampf(s.x * 0.21, 260, 340)
	_holo_overlay(Rect2(strip_w, 0.0, s.x - strip_w, s.y))
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
	# once the last line has faded out under the movie, re-enter from the
	# bottom of the screen
	if start_y + total * line_h - _scroll < fade_top:
		_scroll = -(y_bottom - start_y)

func _draw() -> void:
	var s := get_viewport_rect().size
	draw_rect(Rect2(Vector2.ZERO, s), Color(0.0, 0.0, 0.0, 1.0))
	var strip_w := clampf(s.x * 0.21, 260, 340)
	_circuit_strip(strip_w, s.y)
	# ONE uniform amber GRID over the whole screen, edge to edge, behind the menu
	# column AND the head. Drawn after the circuit strip so it reads at the same
	# brightness on the left as it does in open space -- no second, denser grid.
	_holo_grid(Rect2(Vector2.ZERO, s))
	# capsule buttons
	_item_rects.clear()
	var items := _items()
	var bh := 24.0
	var gap := clampf((s.y - 90.0) / items.size() - bh, 8.0, 34.0)
	var y := 42.0
	var bw := strip_w - 52.0
	for i in items.size():
		var enabled: bool = items[i][1]
		var col := AMBER_GLOW if i == sel else (AMBER if enabled else
			Color(AMBER.r, AMBER.g, AMBER.b, 0.22))
		var r := Rect2(Vector2(28, y), Vector2(bw, bh))
		_stadium(r, col, 1.6 if i == sel else 1.2, i == sel)
		var label: String = items[i][0]
		draw_string(_font, r.position + Vector2(16, bh - 7), label,
				HORIZONTAL_ALIGNMENT_LEFT, -1, item_size,
				col if enabled else Color(col.r, col.g, col.b, 0.35))
		_item_rects.append(r.grow(4))
		y += bh + gap
	# The bust movie itself is the VideoStreamPlayer child (drawn additively
	# above this canvas item, so the grid shows through its dark regions); the
	# scanline/sweep/dossier layer is the _overlay child above the movie.
	# version line, bottom right, like "Edge of Chaos F14.6"
	var ver := "Edge of Chaos R1.0"
	var vw := _font.get_string_size(ver, HORIZONTAL_ALIGNMENT_LEFT, -1, 13).x
	draw_string(_font, Vector2(s.x - vw - 14, s.y - 10), ver,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 13, AMBER_TEXT)
