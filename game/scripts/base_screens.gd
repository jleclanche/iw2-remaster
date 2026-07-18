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
## The LOOK is the original's too, and it is not ours to choose: every control
## arrives carrying its own art, colours, font and text inset, because
## `igui.SetGUIGlobals` holds all of it as POG globals and `igui.CreateFancyButton`
## and friends hand it to `gui.SetWindowStateTextures` / `SetWindowStateColours` /
## `SetWindowFont` / `SetWindowTextFormatting`. We blit the game's own widget
## atlas (data/textures/images/gui/gui.png) with the rects the scripts name. See
## "the skin" below.

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
## The diorama-name label inside Lucrecia's Base: click it to change room.
var _room_hit := Rect2()
## Whether the credit screen (and its badlands stream) is currently up.
var _credits_playing := false


func _ready() -> void:
	# anchors AND offsets: anchors alone leave the rect at zero size, so nothing
	# is ever drawn (the screens had only ever been asserted on, never seen)
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	process_mode = Node.PROCESS_MODE_ALWAYS
	z_index = 10
	visible = false
	if main != null:
		_font = Hud.load_game_font(main._base(), "handelgothic bt_12pt.fnt")
		_font_small = Hud.load_game_font(main._base(), "handelgothic bt_8pt.fnt")


const SCROLL_SPEED := 50.0   ## px/s -- icCreditScreen's constant @ 0x10117be8

func _process(delta: float) -> void:
	if ui == null:
		return
	# The topmost screen with content. A windowless C++ overlay (the popup
	# comms panel) falls through to whatever it covers.
	var scr: PogUi.PogScreen = ui.visible_screen()
	var bi := _base()
	var want := (scr != null and not _rows(scr).is_empty()) or bi != null
	if want != visible:
		visible = want
		ui.dirty = true
		# these screens are mouse-driven; flight keeps the cursor captured.
		# Release it while any POG screen is up, take it back when the last
		# one drops (unless the pause menu owns it).
		if want:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		elif main == null or main.menu == null or not main.menu.visible:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	if ui.dirty:
		ui.dirty = false
		_rebuild(scr)
		queue_redraw()
	elif bi != null and bi.fritz_alpha() > 0.0:
		queue_redraw()   # the fritz flash fades, so it has to be re-drawn
	_credits_music(scr)
	if visible and scr != null:
		_advance_scrollers(scr, delta)


## icCreditScreen's own soundtrack. The screen's ctor (iwar2.dll @ 0x10016180)
## streams `sound:/audio/music/badlands` -- the one music cue in the game with no
## act prefix and no mood sibling, so it cannot come out of audio_manager's a1_
## mood pair. Start it when the credit screen comes up, put the mood score back
## when it pops (which it does itself, on the scroll running out or MovieSkip).
func _credits_music(scr: PogUi.PogScreen) -> void:
	var on_credits: bool = scr != null and scr.name == "icCreditScreen"
	if on_credits == _credits_playing:
		return
	_credits_playing = on_credits
	if main == null or main.audio == null:
		return
	if on_credits:
		main.audio.play_track("badlands")
	else:
		main.audio.restore_music()


## icScroller: the credits crawl. Advance at the engine's 50 px/s and pop the
## screen when the last line has scrolled off the top (Tick @ 0x100164e0).
func _advance_scrollers(scr: PogUi.PogScreen, delta: float) -> void:
	for w in scr.windows:
		if w.kind != "scroller":
			continue
		w.scroll += SCROLL_SPEED * delta
		if w.scroll > _scroller_end(w):
			ui.scroller_done(w)
		queue_redraw()


func _scroller_end(w: PogUi.PogWindow) -> float:
	var view_h := size.y - MARGIN * 2.0 - 46.0
	if _font_small == null:
		return view_h
	var lines := w.text.split("\n").size()
	return view_h + lines * _scroll_line_h() + 40.0


func _scroll_line_h() -> float:
	return maxf(_font_small.get_height(10), 14.0)


## The windows worth drawing: the ones that carry something to show.
## Windows living *inside* a list-box entry (the multi-column rows the inbox,
## trading and manufacturing screens build out of component static windows) are
## drawn by the list box, not as rows of their own.
func _rows(scr: PogUi.PogScreen) -> Array:
	var out: Array = []
	if scr == null:
		return out
	var absorbed := _absorbed(scr)
	for w in scr.windows:
		if absorbed.has(w):
			continue
		if w.kind == "listbox" or w.focusable() \
				or not w.title.is_empty() or not w.text.is_empty():
			out.append(w)
	return out


## Every window that is a list-box entry, or sits inside one.
func _absorbed(scr: PogUi.PogScreen) -> Dictionary:
	var got := {}
	for w in scr.windows:
		if w.kind != "listbox":
			continue
		for e in w.entries:
			if e is PogUi.PogWindow:
				_absorb(e, got)
	return got


func _absorb(w: PogUi.PogWindow, got: Dictionary) -> void:
	if got.has(w):
		return
	got[w] = true
	for c in w.children:
		if c is PogUi.PogWindow:
			_absorb(c, got)


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
		# Nothing focusable: on an engine screen (the credits) Enter skips,
		# the way the original's Game.MovieSkip binding did.
		var scr: PogUi.PogScreen = ui.visible_screen()
		if scr != null and scr.pop_on_cancel:
			_beep(false)
			ui.cancel()
			return
		_beep(true)
		return
	_beep(false)
	ui.activate(win)


func _click(screen_p: Vector2) -> void:
	# The room name under the base menu is a control of the overlay manager, not
	# of the screen: clicking it cuts to the next diorama (iwar2 0x100253fb ->
	# 0x10025500). It is drawn in screen coordinates, so it is hit-tested there.
	if _room_hit.has_area() and _room_hit.has_point(screen_p):
		var bi: BaseInterior = _base()
		if bi != null:
			bi.next_diorama()
			_beep(false)
			return
	# every other hit rect is in GUI canvas pixels
	var p := (screen_p - _origin()) / _scale()
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

## The base interior, while we are in it -- or null. Inside Lucrecia's Base every
## screen here is a hosted screen of icSPPlayerBaseScreen, and the 3D diorama it
## chose is rendering behind us, so the menu must not paint over it.
func _base() -> BaseInterior:
	if main == null or main.base_iface == null:
		return null
	var bi: BaseInterior = main.base_iface
	return bi if bi.inside else null


# ---------------------------------------------------------------- the skin
#
# NOTHING below is styled by us. Every control the scripts create arrives
# carrying its own art, its own colours, its own font and its own text inset,
# because `igui.SetGUIGlobals` (data/pogsrc/igui.pog:4) holds all of it as POG
# globals and `igui.CreateFancyButton` and friends hand it to
# `gui.SetWindowStateTextures`, `gui.SetWindowStateColours`, `gui.SetWindowFont`
# and `gui.SetWindowTextFormatting`. natives/ui.gd records what they say; this
# file blits it.
#
# A control is a THREE-SLICE horizontal strip out of one shared atlas
# (`GUI_texture_request` = "texture:/images/gui/gui" ->
# data/textures/images/gui/gui.png, 256x256): a left cap at its natural width, a
# 1-2 px body column stretched across the middle, and a right cap. There is one
# strip per state -- neutral, focused, selected -- and they are DIFFERENT ART,
# not one bitmap tinted three ways: the base menu's fancy button is 226x32 with
# its neutral pill at atlas (0,36)-(39,68), its focused pill at (40,36)-(80,68)
# and its selected pill at (81,36)-(120,68) (igui.pog:129+).
#
# `SetWindowStateColours` is the TEXT colour per state, not the art's:
# igui.CreateInverseButton sets all three to black and puts the text on a filled
# amber bar (igui.pog:270). The base menu's are GUI_neutral (0.6, 0.451, 0),
# GUI_focused (1, 0.749, 0) and GUI_selected (1, 0.859, 0.278).
#
# The front end is authored in a fixed 640x480 canvas -- igui.CreateWideShadyBar
# computes its width from the literal `640 - 2 * GUI_alignment_offset`
# (igui.pog:392) -- so we lay it out in those pixels and scale to the window.

const CANVAS := Vector2(640.0, 480.0)
## GUI_shader_opacity = 0.8: the translucent column (GUI_shader_width = 240 px)
## that every menu sits on. igui.CreateShadyBar.
const SHADER_OPACITY := 0.8
## GUI_listbox_entryheight = 10.
const LIST_ENTRY_H := 10.0

var _atlas: Texture2D
var _skin_fonts: Dictionary = {}


## The widget atlas. The art is drawn on black and the engine blitted it over the
## 3D with an additive/colour-keyed blend, so the shipped texture has no alpha
## channel of its own (it converts as RGB). We give it one from its own
## luminance, which is what additive amounts to over the dark diorama behind it.
func _gui_atlas() -> Texture2D:
	if _atlas != null:
		return _atlas
	var img := Image.load_from_file(main._base().path_join(
			"data/textures/images/gui/gui.png"))
	if img == null:
		return null
	img.convert(Image.FORMAT_RGBA8)
	for y in img.get_height():
		for x in img.get_width():
			var c := img.get_pixel(x, y)
			c.a = maxf(c.r, maxf(c.g, c.b))
			img.set_pixel(x, y, c)
	_atlas = ImageTexture.create_from_image(img)
	return _atlas


## "font:/fonts/square721 bdex bt_8pt" -> the game's own bitmap font.
func _font_for(url: String, fallback: Font) -> Font:
	if url.is_empty():
		return fallback
	if _skin_fonts.has(url):
		return _skin_fonts[url]
	var stem := url.get_slice("/", url.get_slice_count("/") - 1)
	var f: Font = Hud.load_game_font(main._base(), stem + ".fnt")
	if f == null:
		f = fallback
	_skin_fonts[url] = f
	return f


func _font_px(f: Font) -> int:
	if f is FontFile and (f as FontFile).fixed_size > 0:
		return (f as FontFile).fixed_size
	return 10


## GUI canvas -> screen.
func _scale() -> float:
	return maxf(minf(size.x / CANVAS.x, size.y / CANVAS.y), 0.01)


func _origin() -> Vector2:
	return (size - CANVAS * _scale()) * 0.5


## A window's rect in GUI canvas pixels. Positions are relative to the parent the
## scripts gave it (gui.RepositionWindow reparents as well as moves).
func _rect_of(w: PogUi.PogWindow) -> Rect2:
	var p := Vector2(w.x, w.y)
	var up: PogUi.PogWindow = w.parent
	var depth := 0
	while up != null and depth < 16:   # depth guard: never trust a parent chain
		p += Vector2(up.x, up.y)
		up = up.parent
		depth += 1
	return Rect2(p, Vector2(maxf(float(w.w), 1.0), maxf(float(w.h), 1.0)))


func _state_of(w: PogUi.PogWindow) -> String:
	if w == _current():
		return "focused"
	if w.selected:
		return "selected"
	return "neutral"


func _text_colour(w: PogUi.PogWindow) -> Color:
	match _state_of(w):
		"focused":
			return w.focused_col
		"selected":
			return w.selected_col
	return w.neutral


## The three-slice blit: left cap at its own width, body stretched, right cap.
func _blit(r: Rect2, strip: Array) -> void:
	var tex := _gui_atlas()
	if tex == null or strip.size() < 3:
		return
	var left: Rect2 = strip[0]
	var body: Rect2 = strip[1]
	var right: Rect2 = strip[2]
	var lw: float = left.size.x
	var rw: float = right.size.x
	var mid: float = maxf(r.size.x - lw - rw, 0.0)
	if lw > 0.0:
		draw_texture_rect_region(tex,
			Rect2(r.position, Vector2(lw, r.size.y)), left)
	if mid > 0.0 and body.size.x > 0.0:
		draw_texture_rect_region(tex,
			Rect2(r.position + Vector2(lw, 0.0), Vector2(mid, r.size.y)), body)
	if rw > 0.0:
		draw_texture_rect_region(tex,
			Rect2(r.position + Vector2(r.size.x - rw, 0.0),
				Vector2(rw, r.size.y)), right)


func _draw() -> void:
	if ui == null or _font == null:
		return
	var scr: PogUi.PogScreen = ui.visible_screen()
	var bi := _base()
	_hit.clear()
	_room_hit = Rect2()
	if scr != null:
		var sc := _scale()
		draw_set_transform(_origin(), 0.0, Vector2(sc, sc))
		# 1. the shady bar -- a plain window as wide as gui.SetShadyBarWidth said,
		#    filled at GUI_shader_opacity. That is the whole panel: no border, no
		#    outline, no corner art. The menu is a dark column over the diorama.
		for w in scr.windows:
			if w.kind == "window" and w.art.is_empty() and w.title.is_empty() \
					and w.text.is_empty() and ui.shady_width > 0 \
					and absi(w.w - ui.shady_width) <= 1:
				draw_rect(_rect_of(w), Color(0.0, 0.0, 0.0, SHADER_OPACITY))
		# 2. the controls, each in its own art
		for w in _rows(scr):
			_draw_window(w)
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	if bi != null:
		_draw_interior_furniture(bi)


func _draw_window(w: PogUi.PogWindow) -> void:
	var r := _rect_of(w)
	if w.kind == "listbox":
		_draw_listbox(w, r)
		return
	if w.kind == "scroller":
		_draw_scroller(w, r)
		return
	var st := _state_of(w)
	if w.art.has(st):
		_blit(r, w.art[st])
		_hit.append([r, w, -1])
	var f := _font_for(w.font_url, _font)
	var fs := _font_px(f)
	var col := _text_colour(w)
	var skinned: bool = w.art.has(st)
	if not skinned and col == Color(0, 0, 0):
		col = AMBER   # a static window the scripts never coloured
	if not w.title.is_empty():
		# gui.SetWindowTextFormatting's x inset (GUI_fancybutton_textoffset = 22)
		var tx := float(w.text_offset)
		var ty := r.position.y + (r.size.y + float(fs)) * 0.5 - 1.0
		draw_string(f, Vector2(r.position.x + tx, ty), _label(w.title),
			HORIZONTAL_ALIGNMENT_LEFT, r.size.x - tx, fs, col)
	if not w.text.is_empty():
		# a window too narrow to wrap in is one the scripts sized for something
		# else (a marker, a rule); wrapping in it puts one letter per line
		var wrap: float = r.size.x - 8.0
		if wrap < 32.0:
			wrap = -1.0
		draw_multiline_string(f, r.position + Vector2(4.0, float(fs) + 2.0),
			_plain(w.text), HORIZONTAL_ALIGNMENT_LEFT, wrap, fs, -1, col)


func _draw_listbox(w: PogUi.PogWindow, r: Rect2) -> void:
	var f := _font_for(w.font_url, _font_small)
	var fs := _font_px(f)
	var y := r.position.y
	if not w.title.is_empty():
		draw_string(f, Vector2(r.position.x, y + float(fs)), _label(w.title),
			HORIZONTAL_ALIGNMENT_LEFT, r.size.x, fs, AMBER_DIM)
		y += LIST_ENTRY_H + 2.0
	for i in w.entries.size():
		if y > r.end.y:
			break
		var er := Rect2(r.position.x, y, r.size.x, LIST_ENTRY_H)
		var e: Variant = w.entries[i]
		var here: bool = w == _current() and i == w.focused_entry
		var col := AMBER_GLOW if here else AMBER
		if e is PogUi.PogWindow:
			var ew: PogUi.PogWindow = e
			var st := "focused" if here else "neutral"
			if ew.art.has(st):
				_blit(er, ew.art[st])
				col = ew.focused_col if here else ew.neutral
		elif here:
			draw_rect(er, Color(1.0, 0.749, 0.0, 0.25))
		draw_string(f, Vector2(er.position.x + 2.0, y + float(fs)),
			_entry_text(e), HORIZONTAL_ALIGNMENT_LEFT, er.size.x - 4.0, fs, col)
		_hit.append([er, w, i])
		y += LIST_ENTRY_H


func _draw_scroller(w: PogUi.PogWindow, r: Rect2) -> void:
	# the credits scroller (natives/ui.gd _build_credit_screen) is created with
	# no rect -- it is the whole screen -- so an empty one takes the canvas
	if r.size.x < 8.0 or r.size.y < 8.0:
		r = Rect2(20.0, 20.0, CANVAS.x - 40.0, CANVAS.y - 40.0)
	var lh := _scroll_line_h()
	var lines := w.text.split("\n")
	var y := r.end.y + lh - w.scroll
	for i in lines.size():
		var ly := y + i * lh
		if ly < r.position.y + lh * 0.5:
			continue
		if ly > r.end.y:
			break
		var line := String(lines[i])
		if line.is_empty():
			continue
		draw_string(_font_small, Vector2(r.position.x, ly), line,
			HORIZONTAL_ALIGNMENT_CENTER, r.size.x, 10, AMBER)


## Two things the overlay manager draws that no screen owns:
##
##  * the current diorama's LOCALISED NAME (`csv:/text/dioramas` -- MAIN BAY,
##    CONTROL ROOM, LOADING DOCK, WORKSHOP, CREW LOUNGE), drawn low on the left
##    by the back button and CLICKABLE: a click cuts to the next room
##    (0x10025500, wired at 0x100253fb). Only when g_show_dioramas is set is
##    there anywhere to cut to.
##  * the "fritz" -- a flash over the whole view for fritz_delay = 0.5 s after
##    every cut, fading out as timer/fritz_delay (0x10025459..0x100254de), with
##    `sound:/audio/gui/camera_change` under it. The rooms are security cameras,
##    and this is the camera changing.
func _draw_interior_furniture(bi: BaseInterior) -> void:
	var sc := _scale()
	var o := _origin()
	var room := bi.room_name()
	if not room.is_empty():
		var f := _font_for("font:/fonts/square721 bdex bt_8pt", _font)
		var fs := _font_px(f)
		# GUI_backbutton_left = 27, GUI_backbutton_rise = 70: the manager draws
		# the room name in the back button's corner of the canvas.
		var gp := Vector2(27.0, CANVAS.y - 70.0 + float(fs) + 22.0)
		var p := o + gp * sc
		var wide := f.get_string_size(room, HORIZONTAL_ALIGNMENT_LEFT,
			-1, fs).x * sc
		_room_hit = Rect2(p.x - 4.0 * sc, p.y - float(fs) * sc,
			wide + 8.0 * sc, (float(fs) + 5.0) * sc)
		draw_rect(_room_hit, Color(0.0, 0.0, 0.0, SHADER_OPACITY))
		draw_string(f, p, room, HORIZONTAL_ALIGNMENT_LEFT, -1,
			int(maxf(float(fs) * sc, 6.0)), Color(1.0, 0.749, 0.0))
	var a := bi.fritz_alpha()
	if a > 0.0:
		draw_rect(Rect2(Vector2.ZERO, size), Color(0.75, 0.8, 0.85, a * 0.85))


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
		var w: PogUi.PogWindow = e
		if not w.title.is_empty():
			return _label(w.title)
		# A component row: the columns are child static windows, in x order.
		var cols: Array = w.children.duplicate()
		cols.sort_custom(func(a, b) -> bool: return a.x < b.x)
		var parts: Array[String] = []
		for c in cols:
			var t := _label((c as PogUi.PogWindow).title)
			if not t.is_empty():
				parts.append(t)
		return "  ".join(parts)
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
