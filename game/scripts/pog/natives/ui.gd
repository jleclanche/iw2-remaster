class_name PogUi
extends RefCounted

## gui, ioptions, input, config: the front end the original scripts drive.
##
## The original built its base screens (trade, manufacturing, recycling) and its
## front end out of an in-engine widget toolkit, and the POG scripts do all the
## layout themselves: CreateWindow, CreateListBox, SetWindowStateColours, and so
## on for a thousand call sites. The remaster has its own front end (menu.gd), so
## reproducing that widget tree would be pointless work whose output we would
## then throw away.
##
## What the scripts also do, and what does matter, is *ask questions*: which
## screen am I on, how many screens are stacked, is this overlay still up, what
## is in that list box, what did the player type. So the model here is a real
## screen/overlay state machine plus headless widgets that hold their state
## (title, colours, entries, values, focus links). Queries get coherent answers
## and the control flow through ibasegui/ipdagui/ifrontendgui stays on the rails;
## nothing is drawn. Creation and pure presentation (textures, fonts, movies,
## widget callbacks that nothing can click) are marked @stub.
##
## ioptions, input and config are small and real: an options registry that reads
## and writes the config store, a key binding table that can dispatch back into
## POG, and a persistent key/value store backed by ConfigFile.

var vm   ## the host: PogRuntime for the ported scripts, PogVM for the oracle
var world: PogWorld = null
var game: Node3D = null

## gui: the screen stack. `screens` is the base stack (SetScreen/PushScreen);
## `overlays` sit on top of it (OverlayScreen) and pop independently.
var screens: Array[String] = []
var overlays: Array[String] = []

## gui: windows are headless. Created ones are kept alive by the script's own
## global.Handle store, so there is no registry here.
var focused: PogWindow = null
var top_window: PogWindow = null
var default_colour := Color(1, 1, 1)
var sounds: Dictionary = {}            ## sound id -> url

## ioptions: the options screen registry, in registration order.
var options: Array[PogOption] = []

## input: action name -> "pkg.Func" to run when that action fires.
var bindings: Dictionary = {}
var bindings_suspended := false
var input_scheme := 0

## config: store name -> ConfigFile.
var _configs: Dictionary = {}

## The resolutions the options screen offers. The original enumerated D3D8 modes;
## we are windowed on whatever Godot gives us, so this is a fixed ladder and
## SetGraphicsDevice resizes the window to the chosen rung.
const RESOLUTIONS: Array = [
	Vector2i(1280, 720), Vector2i(1600, 900),
	Vector2i(1920, 1080), Vector2i(2560, 1440),
]

const INPUT_SCHEMES: Array = ["keyboard_mouse", "joystick"]


## A window, button, list box, edit box, slider or checkbox. One class, because
## the scripts pass all of them through gui.Cast and the state each carries is
## small and disjoint.
class PogWindow extends RefCounted:
	var kind := "window"
	var x := 0
	var y := 0
	var w := 0
	var h := 0
	var parent: PogWindow = null
	var title := ""
	var text := ""
	var enabled := true
	var selected := false
	var highlight := true
	## The three state colours the scripts set and read back.
	var neutral := Color(1, 1, 1)
	var focused_col := Color(1, 1, 1)
	var selected_col := Color(1, 1, 1)
	## Focus ring, as the scripts wire it (SetWindowNextFocus/PreviousFocus).
	var next_focus: PogWindow = null
	var prev_focus: PogWindow = null
	## List box.
	var entries: Array = []
	var focused_entry := -1
	var selected_index := -1
	## Edit box / slider / radio / checkbox.
	var value: Variant = ""
	var max_chars := 0
	var checked := false
	## Splitter.
	var top: PogWindow = null
	var bottom: PogWindow = null
	## Recorded but never fired: nothing renders these, so nothing clicks them.
	var callback := ""


## One registered option: a label, the config slot behind it, and the range.
class PogOption extends RefCounted:
	var label := ""
	var section := ""
	var key := ""
	var kind := "bool"                  ## bool / int / float
	var lo: float = 0.0
	var hi: float = 1.0
	var dflt: Variant = 0


func register(v, w: PogWorld = null) -> void:
	vm = v
	world = w
	for fq in _BINDINGS:
		v.bind(fq, Callable(self, _BINDINGS[fq]))


func bind_game(main: Node3D) -> void:
	game = main


static func _win(v: Variant) -> PogWindow:
	return v if v is PogWindow else null


func _new_window(kind: String, a: Array, rect_at: int) -> PogWindow:
	var win := PogWindow.new()
	win.kind = kind
	if a.size() > rect_at + 3:
		win.x = int(a[rect_at])
		win.y = int(a[rect_at + 1])
		win.w = int(a[rect_at + 2])
		win.h = int(a[rect_at + 3])
	win.neutral = default_colour
	win.focused_col = default_colour
	win.selected_col = default_colour
	top_window = win
	return win


# ---------------------------------------------------------------- gui: screens
# The scripts name screens by their C++ class ("icSPBaseScreen"). SetScreen
# replaces the stack, PushScreen grows it, PopScreensTo unwinds to a named one.
# Overlays (the comms panel over the base screen, the puzzle screen over the
# cockpit) sit above the stack and pop separately.

# @native gui.SetScreen
func _set_screen(_t, a: Array) -> Variant:
	screens.clear()
	overlays.clear()
	screens.append(PogStd._s(a[0]))
	return 0

# @native gui.PushScreen
func _push_screen(_t, a: Array) -> Variant:
	screens.append(PogStd._s(a[0]))
	return 0

# @native gui.PopScreen
func _pop_screen(_t, _a: Array) -> Variant:
	if not overlays.is_empty():
		overlays.pop_back()
	elif screens.size() > 1:
		screens.pop_back()
	return 0

# @native gui.PopScreensTo
func _pop_screens_to(_t, a: Array) -> Variant:
	var name := PogStd._s(a[0])
	overlays.clear()
	var at := screens.rfind(name)
	if at >= 0:
		screens.resize(at + 1)
	return 0

# @native gui.ClearAllScreens
func _clear_screens(_t, _a: Array) -> Variant:
	screens.clear()
	overlays.clear()
	return 0

# @native gui.NumScreens
func _num_screens(_t, _a: Array) -> Variant:
	return screens.size() + overlays.size()

# @native gui.CurrentScreenClassname
func _current_screen(_t, _a: Array) -> Variant:
	if not overlays.is_empty():
		return overlays[-1]
	return screens[-1] if not screens.is_empty() else ""

# @native gui.OverlayScreen
func _overlay_screen(_t, a: Array) -> Variant:
	overlays.append(PogStd._s(a[0]))
	return 0

# @native gui.RemoveLastOverlay
func _remove_last_overlay(_t, _a: Array) -> Variant:
	if not overlays.is_empty():
		overlays.pop_back()
	return 0

# @native gui.RemoveOverlaysAfter
func _remove_overlays_after(_t, a: Array) -> Variant:
	# The argument names the screen to be left on top: everything stacked above
	# it goes. It is usually a base screen, so search both stacks.
	var name := PogStd._s(a[0])
	var at := overlays.rfind(name)
	if at >= 0:
		overlays.resize(at + 1)
	else:
		overlays.clear()
		var base := screens.rfind(name)
		if base >= 0:
			screens.resize(base + 1)
	return 0


# ---------------------------------------------------------------- gui: windows
# @native gui.Cast
func _cast(_t, a: Array) -> Variant:
	return _win(a[0] if a.size() > 0 else null)

# @native gui.DeleteWindow
func _delete_window(_t, a: Array) -> Variant:
	var win := _win(a[0])
	if win == null:
		return 0
	if focused == win:
		focused = null
	if top_window == win:
		top_window = null
	win.entries.clear()
	win.parent = null
	return 0

# @native gui.RepositionWindow
func _reposition(_t, a: Array) -> Variant:
	# (window, x, y, flag). The flag is a relayout hint we have no use for.
	var win := _win(a[0])
	if win != null:
		win.x = int(a[1])
		win.y = int(a[2])
	return 0

# @native gui.SetWindowClientArea
func _set_client_area(_t, a: Array) -> Variant:
	var win := _win(a[0])
	if win != null:
		win.x = int(a[1])
		win.y = int(a[2])
		win.w = int(a[3])
		win.h = int(a[4])
	return 0

# @native gui.WindowCanvasWidth
func _canvas_width(_t, a: Array) -> Variant:
	var win := _win(a[0])
	return win.w if win != null else 0

# @native gui.WindowCanvasHeight
func _canvas_height(_t, a: Array) -> Variant:
	var win := _win(a[0])
	return win.h if win != null else 0

# @native gui.FrameWidth
func _frame_width(_t, _a: Array) -> Variant:
	return _frame().x

# @native gui.FrameHeight
func _frame_height(_t, _a: Array) -> Variant:
	return _frame().y

func _frame() -> Vector2i:
	if game != null and game.is_inside_tree():
		return Vector2i(game.get_viewport().get_visible_rect().size)
	return Vector2i(
			int(ProjectSettings.get_setting("display/window/size/viewport_width", 1280)),
			int(ProjectSettings.get_setting("display/window/size/viewport_height", 720)))

# @native gui.SetWindowTitle
func _set_title(_t, a: Array) -> Variant:
	var win := _win(a[0])
	if win != null:
		win.title = PogStd._s(a[1])
	return 0

# @native gui.WindowTitle
func _title(_t, a: Array) -> Variant:
	var win := _win(a[0])
	return win.title if win != null else ""

# @native gui.SelectWindow
func _select_window(_t, a: Array) -> Variant:
	var win := _win(a[0])
	if win != null:
		win.selected = true
		win.enabled = true
	return 0

# @native gui.DeselectWindow
func _deselect_window(_t, a: Array) -> Variant:
	var win := _win(a[0])
	if win != null:
		win.selected = false
	return 0

# @native gui.DisableHighlight
func _disable_highlight(_t, a: Array) -> Variant:
	var win := _win(a[0])
	if win != null:
		win.highlight = false
	return 0

# @native gui.SetFocus
# @native gui.SetFirstControlFocus
func _set_focus(_t, a: Array) -> Variant:
	focused = _win(a[0])
	return 0

# @native gui.FocusedWindow
func _focused_window(_t, _a: Array) -> Variant:
	return focused

# @native gui.TopWindow
func _top_window(_t, _a: Array) -> Variant:
	return top_window

# @native gui.SetWindowNextFocus
func _set_next_focus(_t, a: Array) -> Variant:
	var win := _win(a[0])
	if win != null:
		win.next_focus = _win(a[1])
	return 0

# @native gui.SetWindowPreviousFocus
func _set_prev_focus(_t, a: Array) -> Variant:
	var win := _win(a[0])
	if win != null:
		win.prev_focus = _win(a[1])
	return 0

# @native gui.WindowNextFocus
func _next_focus(_t, a: Array) -> Variant:
	var win := _win(a[0])
	return win.next_focus if win != null else null


# ---------------------------------------------------------------- gui: colours
# SetWindowStateColours(window, nR,nG,nB, fR,fG,fB, sR,sG,sB): the neutral,
# focused and selected tints. ibasegui reads them straight back out again to
# derive the tints for the widgets it builds next, which is why the getters
# matter as much as the setter.

# @native gui.SetWindowStateColours
func _set_state_colours(_t, a: Array) -> Variant:
	var win := _win(a[0])
	if win == null or a.size() < 10:
		return 0
	win.neutral = Color(float(a[1]), float(a[2]), float(a[3]))
	win.focused_col = Color(float(a[4]), float(a[5]), float(a[6]))
	win.selected_col = Color(float(a[7]), float(a[8]), float(a[9]))
	return 0

# @native gui.SetDefaultColour
func _set_default_colour(_t, a: Array) -> Variant:
	default_colour = Color(float(a[0]), float(a[1]), float(a[2]))
	return 0

# @native gui.WindowNeutralRed
func _neutral_r(_t, a: Array) -> Variant:
	var win := _win(a[0])
	return win.neutral.r if win != null else 0.0

# @native gui.WindowNeutralGreen
func _neutral_g(_t, a: Array) -> Variant:
	var win := _win(a[0])
	return win.neutral.g if win != null else 0.0

# @native gui.WindowNeutralBlue
func _neutral_b(_t, a: Array) -> Variant:
	var win := _win(a[0])
	return win.neutral.b if win != null else 0.0

# @native gui.WindowFocusedRed
func _focused_r(_t, a: Array) -> Variant:
	var win := _win(a[0])
	return win.focused_col.r if win != null else 0.0

# @native gui.WindowFocusedGreen
func _focused_g(_t, a: Array) -> Variant:
	var win := _win(a[0])
	return win.focused_col.g if win != null else 0.0

# @native gui.WindowFocusedBlue
func _focused_b(_t, a: Array) -> Variant:
	var win := _win(a[0])
	return win.focused_col.b if win != null else 0.0

# @native gui.WindowSelectedRed
func _selected_r(_t, a: Array) -> Variant:
	var win := _win(a[0])
	return win.selected_col.r if win != null else 0.0

# @native gui.WindowSelectedGreen
func _selected_g(_t, a: Array) -> Variant:
	var win := _win(a[0])
	return win.selected_col.g if win != null else 0.0

# @native gui.WindowSelectedBlue
func _selected_b(_t, a: Array) -> Variant:
	var win := _win(a[0])
	return win.selected_col.b if win != null else 0.0


# ---------------------------------------------------------------- gui: controls
# The widgets are headless, but their *contents* are script data: the trade
# screen fills a list box with cargo and then reads the selection back. So the
# entries, values and selection indices are kept exactly.

# @native gui.AddListBoxEntry
func _lb_add(_t, a: Array) -> Variant:
	var win := _win(a[0])
	if win != null:
		win.entries.append(a[1])
	return 0

# @native gui.RemoveListBoxEntry
func _lb_remove(_t, a: Array) -> Variant:
	var win := _win(a[0])
	if win != null:
		win.entries.erase(a[1])
		win.selected_index = mini(win.selected_index, win.entries.size() - 1)
	return 0

# @native gui.RemoveListBoxEntries
func _lb_clear(_t, a: Array) -> Variant:
	var win := _win(a[0])
	if win != null:
		win.entries.clear()
		win.selected_index = -1
		win.focused_entry = -1
	return 0

# @native gui.SelectListBoxEntry
func _lb_select(_t, a: Array) -> Variant:
	var win := _win(a[0])
	if win != null:
		win.selected_index = int(a[1])
	return 0

# @native gui.CancelListBoxSelection
func _lb_cancel(_t, a: Array) -> Variant:
	var win := _win(a[0])
	if win != null:
		win.selected_index = -1
	return 0

# @native gui.ListBoxSelectedIndex
func _lb_selected(_t, a: Array) -> Variant:
	var win := _win(a[0])
	return win.selected_index if win != null else -1

# @native gui.ListBoxFocusedEntry
func _lb_focused(_t, a: Array) -> Variant:
	var win := _win(a[0])
	if win == null:
		return null
	var i := win.focused_entry
	return win.entries[i] if i >= 0 and i < win.entries.size() else null

# @native gui.SetListBoxFocusedEntry
func _lb_set_focused(_t, a: Array) -> Variant:
	# The argument is the entry itself, not its index.
	var win := _win(a[0])
	if win != null:
		win.focused_entry = win.entries.find(a[1])
	return 0

# @native gui.EditBoxValue
func _eb_value(_t, a: Array) -> Variant:
	var win := _win(a[0])
	return win.value if win != null else ""

# @native gui.SetEditBoxValue
func _eb_set_value(_t, a: Array) -> Variant:
	var win := _win(a[0])
	if win == null:
		return 0
	var s := PogStd._s(a[1])
	win.value = s.left(win.max_chars) if win.max_chars > 0 else s
	return 0

# @native gui.SetEditBoxMaxCharLength
func _eb_set_max(_t, a: Array) -> Variant:
	var win := _win(a[0])
	if win != null:
		win.max_chars = int(a[1])
	return 0

# @native gui.SetRadioButtonChecked
func _rb_set(_t, a: Array) -> Variant:
	var win := _win(a[0])
	if win != null:
		win.checked = PogVM._truthy(a[1])
	return 0

# @native gui.RadioButtonValue
func _rb_value(_t, a: Array) -> Variant:
	var win := _win(a[0])
	return (1 if win.checked else 0) if win != null else 0

# @native gui.CheckboxValue
func _cb_value(_t, a: Array) -> Variant:
	return _rb_value(_t, a)

# @native gui.SliderControlValue
func _slider_value(_t, a: Array) -> Variant:
	var win := _win(a[0])
	return float(win.value) if win != null and win.value is float else 0.0

# @native gui.SetSliderControlValue
func _slider_set_value(_t, a: Array) -> Variant:
	var win := _win(a[0])
	if win != null:
		win.value = float(a[1])
	return 0

# @native gui.SetTextWindowString
func _tw_set_string(_t, a: Array) -> Variant:
	var win := _win(a[0])
	if win != null:
		win.text = PogStd._s(a[1])
	return 0

# @native gui.SplitterWindowTopWindow
func _split_top(_t, a: Array) -> Variant:
	var win := _win(a[0])
	return win.top if win != null else null

# @native gui.SplitterWindowBottomWindow
func _split_bottom(_t, a: Array) -> Variant:
	var win := _win(a[0])
	return win.bottom if win != null else null


# ---------------------------------------------------------------- gui: sound
# RegisterSound("sound:/audio/gui/minor", id) then PlaySound(id). The urls point
# at the extracted GUI wavs, so this one really works.

# @native gui.RegisterSound
func _register_sound(_t, a: Array) -> Variant:
	var id := int(a[1])
	sounds[id] = PogStd._s(a[0])
	return id

# @native gui.PlaySound
# @native gui.QueueSound
func _play_sound(_t, a: Array) -> Variant:
	if game == null or game.audio == null:
		return 0
	var url: String = sounds.get(int(a[0]), "")
	if url.is_empty():
		return 0
	game.audio.play(sound_path(url), -6.0)
	return 0


## "sound:/audio/gui/minor" -> "audio/gui/minor.wav", the path AudioManager wants.
static func sound_path(url: String) -> String:
	var rel := url.trim_prefix("sound:").trim_prefix("/")
	if rel.get_extension().is_empty():
		rel += ".wav"
	return rel


# ---------------------------------------------------------------- gui: widgets
# Everything below here needs a renderer we do not have. The Create* calls still
# hand back a window object so the state above stays coherent (a list box the
# script fills and reads is a real list box to the script); nothing is drawn.

# @stub gui.CreateWindow
# @stub gui.CreateStaticWindow
# @stub gui.CreateFancyBorder
# @stub gui.CreateVerticalScrollbar
func _create_window(_t, a: Array) -> Variant:
	return _new_window("window", a, 0)

# @stub gui.CreateButton
# @stub gui.CreateBackButton
func _create_button(_t, a: Array) -> Variant:
	return _new_window("button", a, 0)

# @stub gui.CreateRadioButton
# @stub gui.CreateCheckbox
func _create_radio(_t, a: Array) -> Variant:
	return _new_window("radio", a, 0)

# @stub gui.CreateListBox
func _create_listbox(_t, a: Array) -> Variant:
	return _new_window("listbox", a, 0)

# @stub gui.CreateEditBox
func _create_editbox(_t, a: Array) -> Variant:
	var win := _new_window("editbox", a, 0)
	win.value = ""
	return win

# @stub gui.CreateSliderControl
func _create_slider(_t, a: Array) -> Variant:
	var win := _new_window("slider", a, 0)
	win.value = 0.0
	return win

# @stub gui.CreateTextWindow
func _create_textwindow(_t, a: Array) -> Variant:
	return _new_window("text", a, 0)

# @stub gui.CreateSplitterWindow
func _create_splitter(_t, a: Array) -> Variant:
	var win := _new_window("splitter", a, 0)
	win.top = PogWindow.new()
	win.bottom = PogWindow.new()
	return win

# Presentation and event plumbing: skins, fonts, background movies, and the
# widget callbacks (SetButtonFunctionPog and friends). The callbacks are inert
# rather than unimplemented: with nothing rendered, nothing can be clicked.
# @stub gui.SetWindowStateTextures
# @stub gui.SetWindowStateIcons
# @stub gui.SetBackgroundImage
# @stub gui.SetDefaultFont
# @stub gui.SetWindowFont
# @stub gui.SetWindowTextFormatting
# @stub gui.SetShadyBarWidth
# @stub gui.SetRHSShadyBarWidth
# @stub gui.PlayBackgroundMovie
# @stub gui.StopBackgroundMovie
# @stub gui.StopAllMovies
# @stub gui.SetTextWindowResource
# @stub gui.TextWindowBack
# @stub gui.SetEditBoxOverrides
# @stub gui.SetEditBoxCursorToEnd
# @stub gui.SetButtonFunctionPog
# @stub gui.SetListBoxSelectFunction
# @stub gui.SetInputOverrideFunctions
# @stub gui.SetControlFocusCancelFunction
# @stub gui.CancelFocusLock
# @stub gui.OnControlFocusLeft
# @stub gui.OnControlFocusRight
# @stub gui.OnControlFocusSelect
func _gui_noop(_t, _a: Array) -> Variant:
	return 0


# ---------------------------------------------------------------- ioptions
# The options screen. Register*(label_key, config_section, config_key, ...)
# declares one row; the value lives in the config store, so Apply is a write-back
# and the getters read through. Only the widget building is stubbed.

# @native ioptions.RegisterBool
func _opt_bool(_t, a: Array) -> Variant:
	var o := PogOption.new()
	o.label = PogStd._s(a[0])
	o.section = PogStd._s(a[1])
	o.key = PogStd._s(a[2])
	o.kind = "bool"
	o.dflt = 1 if (a.size() > 3 and PogVM._truthy(a[3])) else 0
	options.append(o)
	return 0

# @native ioptions.RegisterInt
func _opt_int(_t, a: Array) -> Variant:
	# (label, section, key, default, lo, hi)
	var o := PogOption.new()
	o.label = PogStd._s(a[0])
	o.section = PogStd._s(a[1])
	o.key = PogStd._s(a[2])
	o.kind = "int"
	o.dflt = int(a[3]) if a.size() > 3 else 0
	o.lo = float(a[4]) if a.size() > 4 else 0.0
	o.hi = float(a[5]) if a.size() > 5 else 0.0
	options.append(o)
	return 0

# @native ioptions.RegisterFloat
func _opt_float(_t, a: Array) -> Variant:
	# (label, section, key, lo, hi, flags): the float rows are sliders, so the
	# two numbers are the ends of the range.
	var o := PogOption.new()
	o.label = PogStd._s(a[0])
	o.section = PogStd._s(a[1])
	o.key = PogStd._s(a[2])
	o.kind = "float"
	o.lo = float(a[3]) if a.size() > 3 else 0.0
	o.hi = float(a[4]) if a.size() > 4 else 1.0
	o.dflt = o.lo
	options.append(o)
	return 0

# @native ioptions.UnregisterAll
func _opt_unregister_all(_t, _a: Array) -> Variant:
	options.clear()
	return 0

# @native ioptions.Apply
# @native ioptions.Update
func _opt_apply(_t, _a: Array) -> Variant:
	# The rows write straight through to the config store, so applying is just
	# flushing it to disk.
	_cfg_save(_cfg("system"), "system")
	return 0

# @native ioptions.RestoreDefaults
func _opt_restore(_t, _a: Array) -> Variant:
	var cfg := _cfg("system")
	for o in options:
		cfg.set_value(o.section, o.key, o.dflt)
	_cfg_save(cfg, "system")
	return 0

# @native ioptions.OnSelect
func _opt_on_select(_t, a: Array) -> Variant:
	# The player hit enter on row n: bools toggle, the rest advance one step.
	var o := _option(int(a[0]))
	if o == null:
		return 0
	if o.kind == "bool":
		_opt_store(o, 0 if PogVM._truthy(_opt_load(o)) else 1)
	else:
		return _opt_step(int(a[0]), 1)
	return 0

# @native ioptions.OnLeft
func _opt_on_left(_t, a: Array) -> Variant:
	return _opt_step(int(a[0]), -1)

# @native ioptions.OnRight
func _opt_on_right(_t, a: Array) -> Variant:
	return _opt_step(int(a[0]), 1)

func _option(i: int) -> PogOption:
	return options[i] if i >= 0 and i < options.size() else null

func _opt_load(o: PogOption) -> Variant:
	return _cfg("system").get_value(o.section, o.key, o.dflt)

func _opt_store(o: PogOption, v: Variant) -> void:
	var cfg := _cfg("system")
	cfg.set_value(o.section, o.key, v)
	_cfg_save(cfg, "system")

func _opt_step(i: int, dir: int) -> Variant:
	var o := _option(i)
	if o == null:
		return 0
	match o.kind:
		"bool":
			_opt_store(o, 0 if PogVM._truthy(_opt_load(o)) else 1)
		"int":
			var iv := int(_opt_load(o)) + dir
			_opt_store(o, clampi(iv, int(o.lo), int(o.hi)) if o.hi > o.lo else iv)
		"float":
			var step := (o.hi - o.lo) / 10.0
			var fv := float(_opt_load(o)) + step * dir
			_opt_store(o, clampf(fv, o.lo, o.hi))
	return 0

# @native ioptions.DirectX8Available
func _opt_d3d8(_t, _a: Array) -> Variant:
	return 0                          # Godot renders this; there is no D3D8 path

# @native ioptions.GraphicsDeviceIndex
func _opt_device(_t, _a: Array) -> Variant:
	return 0                          # one renderer, so one device

# @native ioptions.NumberOfResolutionOptions
func _opt_num_res(_t, _a: Array) -> Variant:
	return RESOLUTIONS.size()

# @native ioptions.GraphicsResolutionIndex
func _opt_res_index(_t, _a: Array) -> Variant:
	var size := _frame()
	var at := RESOLUTIONS.find(size)
	return at if at >= 0 else 0

# @native ioptions.SetGraphicsDevice
func _opt_set_device(_t, a: Array) -> Variant:
	# (device, resolution_index). The device is always 0; the resolution is real.
	var i := int(a[1]) if a.size() > 1 else 0
	if i >= 0 and i < RESOLUTIONS.size() and DisplayServer.get_name() != "headless":
		DisplayServer.window_set_size(RESOLUTIONS[i])
	return 0

# The options screen widgets, same story as the rest of gui.
# @stub ioptions.CreateWindows
# @stub ioptions.CreateGraphicsDeviceOptionButtons
# @stub ioptions.CreateGraphicsResolutionOptionButtons
func _opt_noop(_t, _a: Array) -> Variant:
	return 0


# ---------------------------------------------------------------- input
# BindKey("csvchecker.SetStringRepeat", "ScriptKeys.repeatcsvchecker"): the first
# argument is the POG function to run, the second names an *engine* action. The
# table and the dispatch (fire()) are real; what is missing is the original
# keymap that says which physical key each action is, so nothing calls fire()
# yet and KeyCombinations, which renders that keymap into prompt text, is a stub.

# @native input.BindKey
func _bind_key(_t, a: Array) -> Variant:
	bindings[PogStd._s(a[1])] = PogStd._s(a[0])
	return 0

# @native input.PurgeBindings
func _purge_bindings(_t, _a: Array) -> Variant:
	bindings.clear()
	return 0

# @native input.SuspendBindings
func _suspend_bindings(_t, _a: Array) -> Variant:
	bindings_suspended = true
	return 0

# @native input.ResumeBindings
func _resume_bindings(_t, _a: Array) -> Variant:
	bindings_suspended = false
	return 0

# @native input.NumInputSchemes
func _num_schemes(_t, _a: Array) -> Variant:
	return INPUT_SCHEMES.size()

# @native input.CurrentInputScheme
func _current_scheme(_t, _a: Array) -> Variant:
	return input_scheme

# @native input.NthInputSchemeName
func _nth_scheme(_t, a: Array) -> Variant:
	var i := int(a[0])
	return INPUT_SCHEMES[i] if i >= 0 and i < INPUT_SCHEMES.size() else ""

# @native input.SelectInputScheme
func _select_scheme(_t, a: Array) -> Variant:
	input_scheme = clampi(int(a[0]), 0, INPUT_SCHEMES.size() - 1)
	return 0

# @stub input.KeyCombinations
func _key_combinations(_t, _a: Array) -> Variant:
	# "which key is icPlayerPilot.CycleContactUp bound to" -- we ship no keymap,
	# so the prompts that splice this in come out without the key name.
	return ""


## Run whatever POG function is bound to a named action. Nothing calls this yet:
## it is the half of the binding table the engine owned.
func fire(action: String) -> void:
	if bindings_suspended or vm == null:
		return
	var fn: String = bindings.get(action, "")
	if fn.is_empty():
		return
	var pkg := fn.get_slice(".", 0)
	var entry := fn.get_slice(".", 1)
	if not pkg.is_empty() and not entry.is_empty():
		vm.start(pkg, entry)


# ---------------------------------------------------------------- config
# config.GetBool("system", "InstantAction", "tug"): a store name, a section and a
# key. "system" is the only store the scripts use. It is the player's settings
# file, so it persists in user://.

func _cfg(name: String) -> ConfigFile:
	if _configs.has(name):
		return _configs[name]
	var cfg := ConfigFile.new()
	cfg.load(_cfg_path(name))            # a missing file is just an empty store
	_configs[name] = cfg
	return cfg

func _cfg_path(name: String) -> String:
	return "user://pog_%s.cfg" % name.to_lower()

func _cfg_save(cfg: ConfigFile, name: String) -> void:
	cfg.save(_cfg_path(name))

# @native config.CreateBool
func _cfg_create_bool(_t, a: Array) -> Variant:
	# (store, section, key, value): create only if absent, so a saved preference
	# survives the script re-declaring its default on the next run.
	var cfg := _cfg(PogStd._s(a[0]))
	if not cfg.has_section_key(PogStd._s(a[1]), PogStd._s(a[2])):
		cfg.set_value(PogStd._s(a[1]), PogStd._s(a[2]),
				1 if PogVM._truthy(a[3]) else 0)
		_cfg_save(cfg, PogStd._s(a[0]))
	return 0

# @native config.SetBool
func _cfg_set_bool(_t, a: Array) -> Variant:
	var cfg := _cfg(PogStd._s(a[0]))
	cfg.set_value(PogStd._s(a[1]), PogStd._s(a[2]),
			1 if PogVM._truthy(a[3]) else 0)
	_cfg_save(cfg, PogStd._s(a[0]))
	return 0

# @native config.GetBool
func _cfg_get_bool(_t, a: Array) -> Variant:
	var cfg := _cfg(PogStd._s(a[0]))
	return 1 if PogVM._truthy(
			cfg.get_value(PogStd._s(a[1]), PogStd._s(a[2]), 0)) else 0

# @native config.GetString
func _cfg_get_string(_t, a: Array) -> Variant:
	var cfg := _cfg(PogStd._s(a[0]))
	return PogStd._s(cfg.get_value(PogStd._s(a[1]), PogStd._s(a[2]), ""))

# @native config.Exists
func _cfg_exists(_t, a: Array) -> Variant:
	var cfg := _cfg(PogStd._s(a[0]))
	return 1 if cfg.has_section_key(PogStd._s(a[1]), PogStd._s(a[2])) else 0

# @native config.CountNumber
func _cfg_count(_t, a: Array) -> Variant:
	# Numbered entries are key0, key1, ... in one section (the front end's movie
	# list is the only user). Count the run from 0.
	var cfg := _cfg(PogStd._s(a[0]))
	var section := PogStd._s(a[1])
	var key := PogStd._s(a[2])
	var n := 0
	while cfg.has_section_key(section, "%s%d" % [key, n]):
		n += 1
	return n

# @native config.GetNumberedString
func _cfg_numbered(_t, a: Array) -> Variant:
	var cfg := _cfg(PogStd._s(a[0]))
	return PogStd._s(cfg.get_value(PogStd._s(a[1]),
			"%s%d" % [PogStd._s(a[2]), int(a[3])], ""))


const _BINDINGS := {
	"gui.setscreen": "_set_screen", "gui.pushscreen": "_push_screen",
	"gui.popscreen": "_pop_screen", "gui.popscreensto": "_pop_screens_to",
	"gui.clearallscreens": "_clear_screens", "gui.numscreens": "_num_screens",
	"gui.currentscreenclassname": "_current_screen",
	"gui.overlayscreen": "_overlay_screen",
	"gui.removelastoverlay": "_remove_last_overlay",
	"gui.removeoverlaysafter": "_remove_overlays_after",

	"gui.cast": "_cast", "gui.deletewindow": "_delete_window",
	"gui.repositionwindow": "_reposition",
	"gui.setwindowclientarea": "_set_client_area",
	"gui.windowcanvaswidth": "_canvas_width",
	"gui.windowcanvasheight": "_canvas_height",
	"gui.framewidth": "_frame_width", "gui.frameheight": "_frame_height",
	"gui.setwindowtitle": "_set_title", "gui.windowtitle": "_title",
	"gui.selectwindow": "_select_window",
	"gui.deselectwindow": "_deselect_window",
	"gui.disablehighlight": "_disable_highlight",
	"gui.setfocus": "_set_focus", "gui.setfirstcontrolfocus": "_set_focus",
	"gui.focusedwindow": "_focused_window", "gui.topwindow": "_top_window",
	"gui.setwindownextfocus": "_set_next_focus",
	"gui.setwindowpreviousfocus": "_set_prev_focus",
	"gui.windownextfocus": "_next_focus",

	"gui.setwindowstatecolours": "_set_state_colours",
	"gui.setdefaultcolour": "_set_default_colour",
	"gui.windowneutralred": "_neutral_r",
	"gui.windowneutralgreen": "_neutral_g",
	"gui.windowneutralblue": "_neutral_b",
	"gui.windowfocusedred": "_focused_r",
	"gui.windowfocusedgreen": "_focused_g",
	"gui.windowfocusedblue": "_focused_b",
	"gui.windowselectedred": "_selected_r",
	"gui.windowselectedgreen": "_selected_g",
	"gui.windowselectedblue": "_selected_b",

	"gui.addlistboxentry": "_lb_add",
	"gui.removelistboxentry": "_lb_remove",
	"gui.removelistboxentries": "_lb_clear",
	"gui.selectlistboxentry": "_lb_select",
	"gui.cancellistboxselection": "_lb_cancel",
	"gui.listboxselectedindex": "_lb_selected",
	"gui.listboxfocusedentry": "_lb_focused",
	"gui.setlistboxfocusedentry": "_lb_set_focused",
	"gui.editboxvalue": "_eb_value", "gui.seteditboxvalue": "_eb_set_value",
	"gui.seteditboxmaxcharlength": "_eb_set_max",
	"gui.setradiobuttonchecked": "_rb_set",
	"gui.radiobuttonvalue": "_rb_value", "gui.checkboxvalue": "_cb_value",
	"gui.slidercontrolvalue": "_slider_value",
	"gui.setslidercontrolvalue": "_slider_set_value",
	"gui.settextwindowstring": "_tw_set_string",
	"gui.splitterwindowtopwindow": "_split_top",
	"gui.splitterwindowbottomwindow": "_split_bottom",

	"gui.registersound": "_register_sound", "gui.playsound": "_play_sound",
	"gui.queuesound": "_play_sound",

	"gui.createwindow": "_create_window",
	"gui.createstaticwindow": "_create_window",
	"gui.createfancyborder": "_create_window",
	"gui.createverticalscrollbar": "_create_window",
	"gui.createbutton": "_create_button",
	"gui.createbackbutton": "_create_button",
	"gui.createradiobutton": "_create_radio",
	"gui.createcheckbox": "_create_radio",
	"gui.createlistbox": "_create_listbox",
	"gui.createeditbox": "_create_editbox",
	"gui.createslidercontrol": "_create_slider",
	"gui.createtextwindow": "_create_textwindow",
	"gui.createsplitterwindow": "_create_splitter",

	"gui.setwindowstatetextures": "_gui_noop",
	"gui.setwindowstateicons": "_gui_noop",
	"gui.setbackgroundimage": "_gui_noop", "gui.setdefaultfont": "_gui_noop",
	"gui.setwindowfont": "_gui_noop",
	"gui.setwindowtextformatting": "_gui_noop",
	"gui.setshadybarwidth": "_gui_noop",
	"gui.setrhsshadybarwidth": "_gui_noop",
	"gui.playbackgroundmovie": "_gui_noop",
	"gui.stopbackgroundmovie": "_gui_noop", "gui.stopallmovies": "_gui_noop",
	"gui.settextwindowresource": "_gui_noop",
	"gui.textwindowback": "_gui_noop", "gui.seteditboxoverrides": "_gui_noop",
	"gui.seteditboxcursortoend": "_gui_noop",
	"gui.setbuttonfunctionpog": "_gui_noop",
	"gui.setlistboxselectfunction": "_gui_noop",
	"gui.setinputoverridefunctions": "_gui_noop",
	"gui.setcontrolfocuscancelfunction": "_gui_noop",
	"gui.cancelfocuslock": "_gui_noop",
	"gui.oncontrolfocusleft": "_gui_noop",
	"gui.oncontrolfocusright": "_gui_noop",
	"gui.oncontrolfocusselect": "_gui_noop",

	"ioptions.registerbool": "_opt_bool", "ioptions.registerint": "_opt_int",
	"ioptions.registerfloat": "_opt_float",
	"ioptions.unregisterall": "_opt_unregister_all",
	"ioptions.apply": "_opt_apply", "ioptions.update": "_opt_apply",
	"ioptions.restoredefaults": "_opt_restore",
	"ioptions.onselect": "_opt_on_select", "ioptions.onleft": "_opt_on_left",
	"ioptions.onright": "_opt_on_right",
	"ioptions.directx8available": "_opt_d3d8",
	"ioptions.graphicsdeviceindex": "_opt_device",
	"ioptions.numberofresolutionoptions": "_opt_num_res",
	"ioptions.graphicsresolutionindex": "_opt_res_index",
	"ioptions.setgraphicsdevice": "_opt_set_device",
	"ioptions.createwindows": "_opt_noop",
	"ioptions.creategraphicsdeviceoptionbuttons": "_opt_noop",
	"ioptions.creategraphicsresolutionoptionbuttons": "_opt_noop",

	"input.bindkey": "_bind_key", "input.purgebindings": "_purge_bindings",
	"input.suspendbindings": "_suspend_bindings",
	"input.resumebindings": "_resume_bindings",
	"input.numinputschemes": "_num_schemes",
	"input.currentinputscheme": "_current_scheme",
	"input.nthinputschemename": "_nth_scheme",
	"input.selectinputscheme": "_select_scheme",
	"input.keycombinations": "_key_combinations",

	"config.createbool": "_cfg_create_bool", "config.setbool": "_cfg_set_bool",
	"config.getbool": "_cfg_get_bool", "config.getstring": "_cfg_get_string",
	"config.exists": "_cfg_exists", "config.countnumber": "_cfg_count",
	"config.getnumberedstring": "_cfg_numbered",
}
