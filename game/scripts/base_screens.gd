class_name BaseScreens
extends Control

## Draws the screens the POG scripts build, and feeds them input.
##
## Everything on these screens comes from the original code. `ibasegui.pog` and
## `ipdagui.pog` create the controls, title them out of the localised CSV tables,
## fill the list boxes from the inventory and the mail, and attach a POG function
## to every one of them; PogUi (natives/ui.gd) holds that widget tree and runs the
## callbacks. This file is only the eyes and hands: it walks the top screen's
## windows, draws them, moves the focus ring, and tells PogUi when the player
## pressed something.
##
## It is deliberately NOT the original's look. igui.CreateFancyButton skins every
## control from a 38-argument nine-patch atlas; the remaster has its own front end
## (menu.gd) and this follows it -- the same amber-on-black, the same Handel Gothic.
## What is faithful is the content and the control flow: the rows are the rows the
## scripts asked for, in the order they asked for them, and selecting one runs the
## function they attached.

const AMBER := Color(1.0, 0.72, 0.1, 0.95)
const AMBER_DIM := Color(1.0, 0.72, 0.1, 0.40)
const AMBER_GLOW := Color(1.0, 0.88, 0.35, 1.0)
const PANEL_BG := Color(0.02, 0.02, 0.03, 0.92)

const MARGIN := 64.0
const ROW_H := 30.0
const PAD := 18.0

var ui: PogUi
var main: Node3D

var _font: Font
var _font_small: Font

## The focusable windows of the current screen, in creation order.
var _focus: Array[PogUi.PogWindow] = []
var _fi := 0
## Row rects, for the mouse. [[Rect2, PogWindow, entry_index], ...]
var _hit: Array = []


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	process_mode = Node.PROCESS_MODE_ALWAYS
	z_index = 10
	visible = false
	if main != null:
		_font = Hud.load_game_font(main._base(), "handelgothic bt_12pt.fnt")
		_font_small = Hud.load_game_font(main._base(), "handelgothic bt_8pt.fnt")


func _process(_delta: float) -> void:
	if ui == null:
		return
	var scr := ui.top_screen()
	var want := scr != null and not _rows(scr).is_empty()
	if want != visible:
		visible = want
		ui.dirty = true
	if ui.dirty:
		ui.dirty = false
		_rebuild(scr)
		queue_redraw()


## The windows worth drawing: the ones that carry something to show.
func _rows(scr: PogUi.PogScreen) -> Array:
	var out: Array = []
	if scr == null:
		return out
	for w in scr.windows:
		if w.kind == "listbox" or w.focusable() \
				or not w.title.is_empty() or not w.text.is_empty():
			out.append(w)
	return out


func _rebuild(scr: PogUi.PogScreen) -> void:
	_focus.clear()
	if scr == null:
		return
	for w in scr.windows:
		if w.focusable():
			_focus.append(w)
	# gui.SetFirstControlFocus told us where the scripts want the ring to start.
	var want: PogUi.PogWindow = ui.focused if ui.focused != null else scr.focus
	_fi = maxi(0, _focus.find(want)) if want != null else 0
	_fi = clampi(_fi, 0, maxi(0, _focus.size() - 1))
	_sync()


func _sync() -> void:
	ui.focused = _focus[_fi] if _fi >= 0 and _fi < _focus.size() else null


func _current() -> PogUi.PogWindow:
	return _focus[_fi] if _fi >= 0 and _fi < _focus.size() else null


# ---------------------------------------------------------------- input
# Up/Down walk the focus ring; inside a list box they walk its rows first and
# only leave it at the ends, which is what FcListBox::OnControlFocusUp does.

func _unhandled_input(e: InputEvent) -> void:
	if not visible or ui == null:
		return
	if e is InputEventMouseButton and e.pressed \
			and e.button_index == MOUSE_BUTTON_LEFT:
		_click(e.position)
		get_viewport().set_input_as_handled()
		return
	if not (e is InputEventKey and e.pressed):
		return
	var key: int = e.keycode
	match key:
		KEY_UP, KEY_W:
			_step(-1)
		KEY_DOWN, KEY_S:
			_step(1)
		KEY_LEFT, KEY_A:
			ui._fire(_current(), PogUi.IN_LEFT)
		KEY_RIGHT, KEY_D:
			ui._fire(_current(), PogUi.IN_RIGHT)
		KEY_ENTER, KEY_KP_ENTER, KEY_SPACE:
			_activate(_current())
		KEY_ESCAPE, KEY_BACKSPACE:
			_beep(true)
			ui.cancel()
		_:
			return
	get_viewport().set_input_as_handled()


func _step(dir: int) -> void:
	var win := _current()
	if win != null and win.kind == "listbox" and not win.entries.is_empty():
		var n := win.focused_entry + dir
		if n >= 0 and n < win.entries.size():
			win.focused_entry = n
			_beep(false)
			queue_redraw()
			return
		# Off the end of the list: fall out of it and on to the next control.
	if _focus.is_empty():
		return
	_fi = wrapi(_fi + dir, 0, _focus.size())
	var into := _current()
	if into != null and into.kind == "listbox" and not into.entries.is_empty() \
			and into.focused_entry < 0:
		into.focused_entry = 0 if dir > 0 else into.entries.size() - 1
	_sync()
	_beep(false)
	queue_redraw()


func _activate(win: PogUi.PogWindow) -> void:
	if win == null:
		_beep(true)
		return
	_beep(false)
	ui.activate(win)


func _click(p: Vector2) -> void:
	for h in _hit:
		var r: Rect2 = h[0]
		if not r.has_point(p):
			continue
		var win: PogUi.PogWindow = h[1]
		var at: int = h[2]
		var i := _focus.find(win)
		if i < 0:
			return
		_fi = i
		if at >= 0:
			win.focused_entry = at
		_sync()
		# A click is a mouse-up on the control (eInputMessages slot 7), and the
		# scripts wire that to the same function as Select.
		var fn := win.override(PogUi.IN_MOUSE_UP)
		if fn.is_empty():
			_activate(win)
		else:
			_beep(false)
			if win.kind == "listbox":
				win.selected_index = win.focused_entry
			ui.dispatch(fn)
		return
	_beep(true)


func _beep(bad: bool) -> void:
	if main != null and main.audio != null:
		main.audio.play("audio/hud/%s_input.wav"
				% ("invalid" if bad else "valid"), -12.0)


# ---------------------------------------------------------------- draw

func _draw() -> void:
	if ui == null or _font == null:
		return
	var scr := ui.top_screen()
	var rows := _rows(scr)
	if rows.is_empty():
		return
	_hit.clear()

	var s := size
	var panel := Rect2(MARGIN, MARGIN, s.x - MARGIN * 2.0, s.y - MARGIN * 2.0)
	draw_rect(panel, PANEL_BG)
	draw_rect(panel, AMBER_DIM, false, 1.0)

	# The screen's own name, so it is always obvious where the scripts have put
	# you -- the original said it with a skin, and we have no skin.
	draw_string(_font_small, panel.position + Vector2(PAD, 20.0),
			_screen_label(scr.name), HORIZONTAL_ALIGNMENT_LEFT, -1, 9, AMBER_DIM)

	var y := panel.position.y + 46.0
	var x := panel.position.x + PAD
	var wide := panel.size.x - PAD * 2.0

	for w in rows:
		if y > panel.end.y - PAD:
			break
		var focused: bool = w == _current()
		match w.kind:
			"listbox":
				y = _draw_listbox(w, x, y, wide, focused, panel.end.y - PAD)
			"text":
				y = _draw_text(w, x, y, wide)
			"window":
				if not w.title.is_empty():
					draw_string(_font, Vector2(x, y + 14.0), _label(w.title),
							HORIZONTAL_ALIGNMENT_LEFT, -1, 13, AMBER_DIM)
					y += ROW_H
				y = _draw_text(w, x, y, wide)
			_:
				y = _draw_control(w, x, y, wide, focused)
		y += 4.0


func _draw_control(w: PogUi.PogWindow, x: float, y: float, wide: float,
		focused: bool) -> float:
	var r := Rect2(x, y, wide, ROW_H - 4.0)
	_hit.append([r, w, -1])
	if focused:
		draw_rect(r, Color(AMBER.r, AMBER.g, AMBER.b, 0.16))
		draw_rect(r, AMBER_GLOW, false, 1.0)
	var col: Color = AMBER_GLOW if focused else (AMBER if w.enabled else AMBER_DIM)
	var text := _label(w.title)
	match w.kind:
		"editbox":
			text = "%s  %s" % [text, PogStd._s(w.value)]
		"slider":
			text = "%s  %d%%" % [text, roundi(100.0 * float(w.value))]
		"radio":
			text = "%s  %s" % ["[X]" if w.checked else "[ ]", text]
	draw_string(_font, Vector2(x + 10.0, y + 17.0), text,
			HORIZONTAL_ALIGNMENT_LEFT, wide - 20.0, 13, col)
	return y + ROW_H


func _draw_listbox(w: PogUi.PogWindow, x: float, y: float, wide: float,
		focused: bool, bottom: float) -> float:
	if not w.title.is_empty():
		draw_string(_font_small, Vector2(x, y + 12.0), _label(w.title),
				HORIZONTAL_ALIGNMENT_LEFT, -1, 9, AMBER_DIM)
		y += 20.0
	if w.entries.is_empty():
		draw_string(_font_small, Vector2(x + 10.0, y + 14.0), "(empty)",
				HORIZONTAL_ALIGNMENT_LEFT, -1, 9, AMBER_DIM)
		return y + 22.0
	for i in w.entries.size():
		if y > bottom - 8.0:
			break
		var r := Rect2(x, y, wide, ROW_H - 6.0)
		_hit.append([r, w, i])
		var on: bool = focused and i == w.focused_entry
		if on:
			draw_rect(r, Color(AMBER.r, AMBER.g, AMBER.b, 0.16))
			draw_rect(r, AMBER_GLOW, false, 1.0)
		var col: Color = AMBER_GLOW if on else AMBER
		if i == w.selected_index:
			col = AMBER_GLOW
		draw_string(_font, Vector2(x + 14.0, y + 16.0), _entry_text(w.entries[i]),
				HORIZONTAL_ALIGNMENT_LEFT, wide - 28.0, 13, col)
		y += ROW_H - 6.0
	return y


func _draw_text(w: PogUi.PogWindow, x: float, y: float, wide: float) -> float:
	if w.text.is_empty():
		return y
	# The scripts push HTML into the text windows (the encyclopaedia and the mail
	# bodies are html/*.html); strip it rather than render it.
	var body := _plain(w.text)
	var h := _font_small.get_multiline_string_size(
			body, HORIZONTAL_ALIGNMENT_LEFT, wide - 20.0, 10).y
	draw_multiline_string(_font_small, Vector2(x + 10.0, y + 12.0), body,
			HORIZONTAL_ALIGNMENT_LEFT, wide - 20.0, 10, -1, AMBER)
	return y + h + 10.0


## The scripts hand us localisation keys as often as text.
func _label(s: String) -> String:
	if s.is_empty():
		return ""
	if main != null and main.comms != null:
		return String(main.comms.strings.get(s, s))
	return s


func _entry_text(e: Variant) -> String:
	if e is String:
		return _label(e)
	if e is PogUi.PogWindow:
		return _label(e.title)
	return PogStd._s(e)


static func _plain(s: String) -> String:
	var out := ""
	var depth := 0
	for i in s.length():
		var c := s[i]
		if c == "<":
			depth += 1
		elif c == ">":
			depth = maxi(0, depth - 1)
		elif depth == 0:
			out += c
	return out.strip_edges()


## "icSPManufacturingScreen" -> "MANUFACTURING"
static func _screen_label(name: String) -> String:
	var s := name.trim_prefix("ic").trim_prefix("SP").trim_suffix("Screen")
	var out := ""
	for i in s.length():
		var c := s[i]
		if i > 0 and c == c.to_upper() and c != c.to_lower():
			out += " "
		out += c
	return out.to_upper()
