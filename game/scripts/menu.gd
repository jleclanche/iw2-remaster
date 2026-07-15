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

# The front-end GUI amber palette, recovered from igui.SetGUIGlobals
# (data/pogsrc/igui.pog:35-46). These are the exact colours the original
# front end tints its controls -- and its prison bust hologram -- with.
const GUI_NEUTRAL := Color(0.600, 0.451, 0.0)   # igui.pog:35-37
const GUI_FOCUSED := Color(1.0, 0.749, 0.0)     # igui.pog:38-40 -- the holo amber
const GUI_SELECTED := Color(1.0, 0.859, 0.278)  # igui.pog:41-43 -- bright sweep
const GUI_FADED := Color(0.5, 0.3745, 0.0)      # igui.pog:44-46 -- dim grid

# Prison-bust HOLOGRAM parameters. The bust is the amber twin of Clay's red
# comm hologram: it is drawn by the engine's comms head system (icComms +
# icHUDTargetMFD in iwar2.dll) as an unshaded, self-lit, translucent amber head
# with a scrolling scanline overlay, a full-panel grid, and a bright sweep band.
# Recovered constants (iwar2.dll):
#   HOLO_AMBER = icComms tint FcColour[0], ctor 0x1007f720 (iwar2.dll.c:105107-109)
#                = 0x3f800000,0x3f3fbe77,0 = (1.0, 0.749, 0.0)  (== GUI_FOCUSED)
#   HOLO_SWEEP = sweep-flash colour DAT_10174fb0, FUN_100e6750 0x100e6750
#                (iwar2.dll.c:195396-398) = 0x3f800000,0x3f178d50,0 = (1.0,0.592,0.0)
#   panel/scanline texture = texture:/images/hud/ucp (icHUDTargetMFD ctor 0x10101530,
#                iwar2.dll.c:195533), scrolled in V over time (iwar2.dll.c:195797-804)
#   panel shader alpha = 0.990 (iwar2.dll.c:195545)
# The sweep motion is time-driven, wrapped 0..1 (iwar2.dll.c:195961-967); the
# original description has it sweeping UP. Grid cell size, scanline spacing and
# the sweep/scanline scroll RATES are .rdata floats the decomp left un-inlined
# (UNKNOWN); the values below are reconstructed to match the original's look.
const HOLO_AMBER := Color(1.0, 0.749, 0.0)      # icComms tint (verified)
const HOLO_SWEEP := Color(1.0, 0.592, 0.0)      # sweep flash (verified)
const HOLO_GRID_CELL := 26.0                    # px, reconstructed (baked in panel tex)
const HOLO_SCAN_STEP := 3.0                     # px between scanlines, reconstructed
const HOLO_SWEEP_SPEED := 0.28                  # panel-heights/sec up, reconstructed
const HOLO_SWEEP_FRAC := 0.14                   # sweep band height / panel, reconstructed
const HOLO_SCAN_SPEED := 34.0                   # px/sec scanline drift, reconstructed

# prison characters with an exported head anchor + dossier
const CHARACTERS := [
	["smith", "data/gltf/avatars/smith/smith_anchor.gltf"],
	["az", "data/gltf/avatars/az/az_anchor.gltf"],
	["jaffs", "data/gltf/avatars/jaffs/jafs_flappymouth.gltf"],
	["lori", "data/gltf/avatars/lori/lori_anchor.gltf"],
]

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
var bust_view: SubViewport
var bust_node: Node3D
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
var _shot_chars := ["az", "lori", "smith", "jaffs"]
var _shot_idx := 0

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
	# No lights: the bust is a self-lit amber HOLOGRAM (see _holo_bust). The
	# previous hand-placed key/rim lights were the wrong model -- they flat-lit
	# the head grey-green and their warm rim threw the "gold triangle" specular.
	_setup_cursor()
	if "--bustshot" in OS.get_cmdline_user_args():
		_shot = true
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

func _pick_character() -> void:
	var pick: Array = CHARACTERS[randi() % CHARACTERS.size()]
	if _force_char != "":
		for c in CHARACTERS:
			if c[0] == _force_char:
				pick = c
				break
	if _char == pick[0]:
		return
	_char = pick[0]
	if bust_node != null:
		bust_node.queue_free()
		bust_node = null
	bust_node = main._load_gltf(str(pick[1]))
	if bust_node != null:
		bust_node.scale = Vector3.ONE * 1.686
		_holo_bust(bust_node)
		bust_view.add_child(bust_node)
	_load_dossier(_char)
	_scroll = 0.0

# Re-skin the bust as an amber HOLOGRAM. The original prison dossier bust is not
# a naturalistically-lit solid head -- it is a translucent, self-lit amber
# hologram (the amber twin of Clay's real-time RED comm hologram in comms.gd,
# which is built the same way from icBeamAvatar scanline planes over an unshaded
# head). Rendering it UNSHADED is also what makes the RT head read correctly:
#  * these RT avatar heads (az/clay/smith) are hollow FRONT SHELLS -- the Body
#    surface has zero rear-facing polygons -- so lit opaquely and turned to a
#    hard profile the open back of the skull shows. Amber + translucent hides it.
#  * lit opaquely with a warm rim light the cheek threw a saturated gold specular
#    triangle by the mouth (the "gold triangle": it is in NO texture -- a
#    lighting artifact, not geometry). UNSHADED has no specular, so it is gone.
# Tint is GUI_FOCUSED amber (igui.pog:38-40).
func _holo_bust(node: Node3D) -> void:
	for mi in node.find_children("*", "MeshInstance3D", true, false):
		var m := mi as MeshInstance3D
		if m.mesh == null:
			continue
		for si in m.mesh.get_surface_count():
			var src := m.mesh.surface_get_material(si) as BaseMaterial3D
			var mat := StandardMaterial3D.new()
			# UNSHADED so the head self-glows and throws no specular (that is
			# what banishes the "gold triangle"). OPAQUE with depth writing on so
			# surfaces occlude correctly -- the RT heads carry internal "Black"
			# backing cards (e.g. Lori prim0, a flat card at z=-0.02); without
			# depth those floated to the front as a solid gold blob over the
			# face. The holographic translucency is applied later, in 2D, when
			# the whole viewport is composited (see _draw).
			mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			mat.cull_mode = BaseMaterial3D.CULL_BACK
			# Tint the SOURCE colour to amber, preserving its own value: white
			# (textured skin/hair/eyes) -> amber; black (mouth/eyebrow/backing
			# cards) -> black, so they read as dark features, not gold. The
			# texture, where present, still modulates it so features/hair read.
			var base := src.albedo_color if src != null else Color.WHITE
			mat.albedo_color = Color(base.r * HOLO_AMBER.r,
				base.g * HOLO_AMBER.g, base.b * HOLO_AMBER.b, 1.0)
			if src != null and src.albedo_texture != null:
				mat.albedo_texture = src.albedo_texture
			m.set_surface_override_material(si, mat)

func _load_dossier(who: String) -> void:
	# html/prison/<who>.html, stripped to amber text; <b> heads stay bright
	dossier_lines.clear()
	# data/html is transcoded to UTF-8 at extraction (tools/iw2/html_text.py)
	var path: String = main._base().path_join("data/html/prison/%s.html" % who)
	if not FileAccess.file_exists(path):
		return
	var raw := FileAccess.get_file_as_string(path)
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
	if bust_node != null:
		# slow turn around a 3/4-profile pose, like the front end. -62 turned it
		# to near-full profile, which exposed the RT head's open back-of-skull;
		# the original sits at a gentle 3/4 (~40 deg) and sways a little.
		bust_node.rotation.y = deg_to_rad(-40.0) + sin(_bust_t * 0.23) * 0.22
	_scroll += delta * 14.0
	queue_redraw()
	if _shot:
		_bustshot_step(delta)

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
			if _shot_t > 0.6:
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
	var g := Color(GUI_FADED.r, GUI_FADED.g, GUI_FADED.b, 0.16)
	var x := rect.position.x
	while x <= rect.end.x:
		draw_line(Vector2(x, rect.position.y), Vector2(x, rect.end.y), g, 1.0)
		x += HOLO_GRID_CELL
	var y := rect.position.y
	while y <= rect.end.y:
		draw_line(Vector2(rect.position.x, y), Vector2(rect.end.x, y), g, 1.0)
		y += HOLO_GRID_CELL

func _holo_overlay(panel: Rect2) -> void:
	# horizontal SCANLINES scrolling slowly over the model (icHUDTargetMFD scrolls
	# the panel/scanline texture in V, iwar2.dll.c:195797-804; texture images/hud/
	# ucp). Reconstructed spacing/rate.
	var drift := fmod(_bust_t * HOLO_SCAN_SPEED, HOLO_SCAN_STEP)
	var sc := Color(HOLO_AMBER.r, HOLO_AMBER.g, HOLO_AMBER.b, 0.10)
	var y := panel.position.y + drift
	while y < panel.end.y:
		draw_line(Vector2(panel.position.x, y), Vector2(panel.end.x, y), sc, 1.0)
		y += HOLO_SCAN_STEP
	# the bright SWEEP band, moving UP the panel and wrapping (time-driven wrap,
	# iwar2.dll.c:195961-967; colour = sweep flash HOLO_SWEEP, iwar2.dll.c:
	# 195396-398). Drawn as a soft triangular-alpha band.
	var band_h := panel.size.y * HOLO_SWEEP_FRAC
	var frac := fmod(_bust_t * HOLO_SWEEP_SPEED, 1.0)
	var cy := panel.end.y - frac * (panel.size.y + band_h) + band_h * 0.5
	var steps := 16
	for i in steps:
		var t := float(i) / float(steps - 1)          # 0..1 across the band
		var yy := cy - band_h * 0.5 + t * band_h
		if yy < panel.position.y or yy > panel.end.y:
			continue
		var a := 1.0 - absf(t - 0.5) * 2.0            # bright centre, soft edges
		draw_line(Vector2(panel.position.x, yy), Vector2(panel.end.x, yy),
				Color(HOLO_SWEEP.r, HOLO_SWEEP.g, HOLO_SWEEP.b, a * 0.5),
				band_h / float(steps) + 1.0)

func _draw() -> void:
	var s := get_viewport_rect().size
	draw_rect(Rect2(Vector2.ZERO, s), Color(0.0, 0.0, 0.0, 1.0))
	# the amber holo GRID covers the whole screen, behind everything
	_holo_grid(Rect2(Vector2.ZERO, s))
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
	# 3D bust, right of center -- rendered as an amber hologram
	if mode != "systems":
		var bust_size := minf(s.y * 0.62, 560.0)
		var bust_pos := Vector2(s.x * 0.40, -bust_size * 0.04)
		var panel := Rect2(bust_pos, Vector2(bust_size, bust_size))
		# a faint amber volume seats the head over the grid
		draw_rect(panel, Color(HOLO_AMBER.r, HOLO_AMBER.g, HOLO_AMBER.b, 0.04),
				true)
		# the head, composited translucently so it reads as a hologram volume
		draw_texture_rect(bust_view.get_texture(), panel, false,
				Color(1.0, 1.0, 1.0, 0.86))
		_holo_overlay(panel)  # scanlines + upward sweep, over the head
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
