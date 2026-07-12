class_name Menu
extends Control
# The original front end: amber capsule buttons down a circuit-board strip
# on the left (images/gui/gui atlas, igui.CreateFancyButton), a real-time
# 3D bust of one of the prison characters on the right, and their scrolling
# prison dossier (html/prison/*.html) beneath. Labels from text/gui.csv
# (pda_* keys). Esc in flight brings it back as a pause menu.

const AMBER := Color(1.0, 0.72, 0.1, 0.95)
const AMBER_DIM := Color(1.0, 0.72, 0.1, 0.45)
const AMBER_GLOW := Color(1.0, 0.88, 0.35, 1.0)
const AMBER_TEXT := Color(1.0, 0.81, 0.0, 0.95)  # dossier #ffcf00

# prison characters with an exported head anchor + dossier
const CHARACTERS := [
	["smith", "data/gltf/avatars/smith/smith_anchor.gltf"],
	["az", "data/gltf/avatars/az/az_anchor.gltf"],
	["jaffs", "data/gltf/avatars/jaffs/jafs_flappymouth.gltf"],
	["lori", "data/gltf/avatars/lori/lori_anchor.gltf"],
]

# the sixteen real systems of the two clusters (the *_dm maps are
# multiplayer arenas)
const SYSTEMS := [
	["hoffers_wake", "Hoffer's Wake"], ["coyote", "Coyote"],
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
var bust_view: SubViewport
var bust_node: Node3D
var _bust_t := 0.0
var dossier_lines: Array = []  # {text, bold}
var _scroll := 0.0
var _char := ""

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false
	_font = Hud.load_game_font(main._base(), "handelgothic bt_12pt.fnt")
	_font_small = Hud.load_game_font(main._base(), "handelgothic bt_8pt.fnt")
	_font_title = Hud.load_game_font(main._base(), "square721 bdex bt_8pt.fnt")
	bust_view = SubViewport.new()
	bust_view.size = Vector2i(512, 512)
	bust_view.own_world_3d = true
	bust_view.transparent_bg = true
	bust_view.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(bust_view)
	var cam := Camera3D.new()
	cam.position = Vector3(0, -0.02, 1.05)
	cam.fov = 26.0
	bust_view.add_child(cam)
	var key := OmniLight3D.new()
	key.position = Vector3(-0.5, 0.25, 0.8)
	key.omni_range = 3.0
	key.light_energy = 1.1
	bust_view.add_child(key)
	var rim := OmniLight3D.new()
	rim.position = Vector3(0.7, 0.1, -0.4)
	rim.omni_range = 2.5
	rim.light_energy = 0.5
	rim.light_color = Color(0.9, 0.75, 0.5)
	bust_view.add_child(rim)
	_setup_cursor()

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

func _pick_character() -> void:
	var pick: Array = CHARACTERS[randi() % CHARACTERS.size()]
	if _char == pick[0]:
		return
	_char = pick[0]
	if bust_node != null:
		bust_node.queue_free()
		bust_node = null
	bust_node = main._load_gltf(str(pick[1]))
	if bust_node != null:
		bust_node.scale = Vector3.ONE * 1.686
		bust_view.add_child(bust_node)
	_load_dossier(_char)
	_scroll = 0.0

func _load_dossier(who: String) -> void:
	# html/prison/<who>.html, stripped to amber text; <b> heads stay bright
	dossier_lines.clear()
	var path: String = main._base().path_join("data/html/prison/%s.html" % who)
	if not FileAccess.file_exists(path):
		return
	# the game's html is Latin-1; get_as_text() assumes UTF-8 and spews
	# "Unicode parsing error: ... not a correct continuation byte"
	var raw := FileAccess.get_file_as_bytes(path).get_string_from_ascii()
	var body := raw.get_slice("<BODY>", 1) if "<BODY>" in raw else raw
	body = body.replace("\r\n", "\n").replace("<p>", "\n\n").replace("<P>", "\n\n")
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
		# wrap to the dossier column width
		var words := line.split(" ")
		var cur := ""
		for w in words:
			var trial := (cur + " " + w).strip_edges()
			if _font_small.get_string_size(trial, HORIZONTAL_ALIGNMENT_LEFT,
					-1, 12).x > 380:
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
	if visible:
		handle(event)
		get_viewport().set_input_as_handled()
	elif event is InputEventKey and event.pressed and not event.echo \
			and event.physical_keycode == KEY_ESCAPE:
		open()  # Escape = PDA / pause

func open() -> void:
	visible = true
	mode = "main"
	sel = 0
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	bust_view.render_target_update_mode = SubViewport.UPDATE_ALWAYS
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
	bust_view.render_target_update_mode = SubViewport.UPDATE_DISABLED
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
		return [["RESUME", true], ["SAVE GAME", false],
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
		main.start_in_system(SYSTEMS[sel][0])
		launched = true
		close()
		return
	if launched:
		match sel:
			0:
				main.audio.play("audio/gui/mechanical_confirm.wav", -6.0)
				close()
			2:
				main.audio.play("audio/gui/expand.wav", -8.0)
				mode = "systems"
				sel = 0
			3:
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
				if mode == "systems":
					mode = "main"
					sel = 0
				elif launched:
					close()
				else:
					get_tree().quit()
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
	if bust_node != null:
		# slow turn around the profile pose, like the front end
		bust_node.rotation.y = deg_to_rad(-62.0) + sin(_bust_t * 0.23) * 0.35
	_scroll += delta * 14.0
	queue_redraw()

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

func _draw() -> void:
	var s := get_viewport_rect().size
	draw_rect(Rect2(Vector2.ZERO, s), Color(0.0, 0.0, 0.0, 1.0))
	var strip_w := clampf(s.x * 0.21, 260, 340)
	_circuit_strip(strip_w, s.y)
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
	# 3D bust, right of center
	if mode != "systems":
		var bust_size := minf(s.y * 0.62, 560.0)
		var bust_pos := Vector2(s.x * 0.40, -bust_size * 0.04)
		draw_texture_rect(bust_view.get_texture(),
				Rect2(bust_pos, Vector2(bust_size, bust_size)), false)
		# scrolling dossier under the bust
		var dx := s.x * 0.47
		var dy0 := s.y * 0.55
		var line_h := 17.0
		var visible_rows := int((s.y - 30.0 - dy0) / line_h)
		if not dossier_lines.is_empty():
			var total := dossier_lines.size()
			var first := int(_scroll / line_h)
			for row in visible_rows:
				var idx := first + row
				if idx >= total:
					break
				var entry: Dictionary = dossier_lines[idx]
				var ypos := dy0 + row * line_h - fmod(_scroll, line_h)
				var col2 := AMBER_GLOW if entry["bold"] else AMBER_TEXT
				draw_string(_font_small, Vector2(dx, ypos), str(entry["text"]),
						HORIZONTAL_ALIGNMENT_LEFT, -1, 12, col2)
			if first >= total:
				_scroll = -float(visible_rows) * line_h  # wrap from below
	# version line, bottom right, like "Edge of Chaos F14.6"
	var ver := "Edge of Chaos R1.0"
	var vw := _font.get_string_size(ver, HORIZONTAL_ALIGNMENT_LEFT, -1, 13).x
	draw_string(_font, Vector2(s.x - vw - 14, s.y - 10), ver,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 13, AMBER_TEXT)
