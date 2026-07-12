class_name Menu
extends Control
# Front-end menu in the original's amber PDA style: vector-drawn panels,
# original GUI sounds. Main menu -> launch / system select / quit; Esc
# in flight brings it back as a pause menu.

const AMBER := Color(1.0, 0.72, 0.1, 0.95)
const AMBER_DIM := Color(1.0, 0.72, 0.1, 0.4)
const AMBER_GLOW := Color(1.0, 0.85, 0.3, 1.0)

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
var _font_title: Font  # Square721 BdEx 19pt — the original title face
var title_size := 27
var item_size := 17

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false
	_font = Hud.load_game_font(main._base(), "handelgothic bt_12pt.fnt")
	_font_title = Hud.load_game_font(main._base(), "square721 bdex bt_19pt.fnt")
	if _font is FontFile and (_font as FontFile).fixed_size > 0:
		item_size = (_font as FontFile).fixed_size
	if _font_title is FontFile and (_font_title as FontFile).fixed_size > 0:
		title_size = (_font_title as FontFile).fixed_size

var _item_rects: Array = []

func open() -> void:
	visible = true
	mode = "main"
	sel = 0
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

func close() -> void:
	visible = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _items() -> Array:
	if mode == "systems":
		var out: Array = []
		for s in SYSTEMS:
			out.append(s[1].to_upper())
		out.append("< BACK")
		return out
	if launched:
		return ["RESUME FLIGHT", "SELECT SYSTEM", "QUIT TO DESKTOP"]
	return ["NEW CAMPAIGN", "FREE FLIGHT — COMMISSION TUG", "SELECT SYSTEM",
		"QUIT TO DESKTOP"]

func _activate() -> void:
	var items := _items()
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
			1:
				main.audio.play("audio/gui/expand.wav", -8.0)
				mode = "systems"
				sel = 0
			2:
				get_tree().quit()
		return
	match sel:
		0:  # NEW CAMPAIGN
			main.audio.play("audio/gui/confirm.wav", -6.0)
			launched = true
			close()
			main.start_campaign()
		1:  # free flight
			main.audio.play("audio/gui/mechanical_confirm.wav", -6.0)
			launched = true
			close()
		2:
			main.audio.play("audio/gui/expand.wav", -8.0)
			mode = "systems"
			sel = 0
		3:
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

func _process(_d: float) -> void:
	if visible:
		queue_redraw()

func _draw() -> void:
	var s := get_viewport_rect().size
	draw_rect(Rect2(Vector2.ZERO, s), Color(0.0, 0.0, 0.02, 0.72))
	var cx := s.x / 2.0
	# title block
	var title := "INDEPENDENCE WAR 2"
	var sub := "EDGE OF CHAOS — REMASTER PROTOTYPE"
	var tw := _font_title.get_string_size(title, HORIZONTAL_ALIGNMENT_CENTER,
			-1, title_size * 2).x
	draw_string(_font_title, Vector2(cx - tw / 2.0, s.y * 0.2), title,
			HORIZONTAL_ALIGNMENT_LEFT, -1, title_size * 2, AMBER_GLOW)
	var sw := _font.get_string_size(sub, HORIZONTAL_ALIGNMENT_CENTER, -1, item_size).x
	draw_string(_font, Vector2(cx - sw / 2.0, s.y * 0.2 + 26), sub,
			HORIZONTAL_ALIGNMENT_LEFT, -1, item_size, AMBER_DIM)
	draw_line(Vector2(cx - tw / 2.0 - 30, s.y * 0.2 + 40),
			Vector2(cx + tw / 2.0 + 30, s.y * 0.2 + 40), AMBER_DIM, 1.5, true)
	# panel header
	var header := "SYSTEM SELECT" if mode == "systems" else "COMMAND"
	draw_string(_font, Vector2(cx - 180, s.y * 0.34), header,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 15, AMBER_DIM)
	# items
	_item_rects.clear()
	var items := _items()
	var y := s.y * 0.34 + 30
	var line_h := 30.0 if items.size() < 10 else 24.0
	var fs := item_size if items.size() < 10 else item_size - 3
	for i in items.size():
		var col := AMBER_GLOW if i == sel else AMBER
		var x := cx - 160
		if i == sel:
			var blink := 0.5 + 0.5 * sin(Time.get_ticks_msec() / 150.0)
			draw_rect(Rect2(x - 26, y - fs, 12, fs + 2),
					Color(AMBER.r, AMBER.g, AMBER.b, 0.25 + 0.35 * blink))
			draw_string(_font, Vector2(x - 30, y), ">",
					HORIZONTAL_ALIGNMENT_LEFT, -1, fs, AMBER_GLOW)
		draw_string(_font, Vector2(x, y), items[i],
				HORIZONTAL_ALIGNMENT_LEFT, -1, fs, col)
		_item_rects.append(Rect2(x - 34, y - fs - 2, 420, line_h))
		y += line_h
	# footer
	var foot := "ARROWS / MOUSE — SELECT      ENTER / CLICK — CONFIRM      ESC — BACK"
	var fw := _font.get_string_size(foot, HORIZONTAL_ALIGNMENT_CENTER, -1, 13).x
	draw_string(_font, Vector2(cx - fw / 2.0, s.y - 40), foot,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 13, AMBER_DIM)
	# corner frame accents, PDA style
	for corner in [Vector2(40, 40), Vector2(s.x - 40, 40),
			Vector2(40, s.y - 40), Vector2(s.x - 40, s.y - 40)]:
		var dx: float = 24.0 if corner.x < cx else -24.0
		var dy: float = 24.0 if corner.y < s.y / 2.0 else -24.0
		draw_line(corner, corner + Vector2(dx, 0), AMBER, 2.0, true)
		draw_line(corner, corner + Vector2(0, dy), AMBER, 2.0, true)
