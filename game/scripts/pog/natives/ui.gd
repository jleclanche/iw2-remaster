class_name PogUi
extends RefCounted

## gui, ioptions, input, config: the front end the original scripts drive.
##
## The base screens are POG. A screen is named by its C++ class
## (`gui.SetScreen("icSPPlayerBaseScreen")`), and the engine's screen object
## **called straight back into the scripts to build itself**: the ctor of
## `icSPBaseScreen` (iwar2 @ 0x10029230) runs `FcScriptEngine::CallFunction` on a
## POG function, and its dtor (0x10029350) runs another. The function is the class
## name without its `ic`, in whichever package defines it -- `icSPHangarScreen` ->
## `iBaseGUI.SPHangarScreen` -- and that convention resolves 33 of the 48 screens
## the campaign names, each in exactly one package (SCREEN_BUILDERS below). The
## other 15 were built in C++.
##
## So the hangar, loadout, manifest, inventory, recycling, manufacturing, comms,
## inbox, encyclopaedia and statistics screens, and the whole PDA, are the
## original scripts' own code, and all we have to do is run it. That is what
## SetScreen/PushScreen/OverlayScreen do here, and what base_screens.gd draws.
##
## We do **not** reproduce the original's widget skin. igui.CreateFancyButton and
## friends splice a 38-argument texture atlas onto every control; the remaster has
## its own look. What is honoured is the *semantics*: the controls, their titles,
## their contents, the focus ring, and the nine input-override slots -- so the
## scripts' own control flow decides what happens, and every button really runs
## the POG function it was given.
##
## ioptions, input and config are small and real: an options registry that reads
## and writes the config store, a key binding table that can dispatch back into
## POG, and a persistent key/value store backed by ConfigFile.

var vm   ## the host: PogRuntime for the ported scripts, PogVM for the oracle
var world: PogWorld = null
var game: Node3D = null

## The screen stack (SetScreen/PushScreen). Overlays belong to the screen they
## cover -- FcGame::AddOverlayScreen stacks them on the *current* screen, and a
## later PushScreen shows a fresh screen with no overlays, so pushing the
## credits over the PDA really covers the PDA menu -- so they live on each
## PogScreen (`over`), not in a global pile.
var screens: Array[PogScreen] = []

var focused: PogWindow = null
var top_window: PogWindow = null
var default_colour := Color(1, 1, 1)
var default_font := ""
var sounds: Dictionary = {}            ## sound id -> url
var background := ""

## Set whenever the widget tree changes, so the renderer knows to rebuild.
var dirty := true
var screen_ui = null                   ## BaseScreens, created on first use

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

## `FcWindowManager::eInputMessages`, the nine slots of SetInputOverrideFunctions.
## The indices are the engine's own: FcWindow::OnControlFocusLeft (flux @
## 0x100941f0) asks the manager for slot 0, OnControlFocusUp for 1, Right 2,
## Down 3, Select 4, and the mouse handlers for 6, 7 and 8
## (InputMessageOverrideFunction, 0x10097550, indexes a table of accessors).
##
## Slot 5 is Cancel, and it is *dead in the original*: FcWindow::OnControlFocusCancel
## (0x10094720) never consults the table -- it walks up to the parent and, failing
## that, calls the window manager's single global cancel function, which is what
## gui.SetControlFocusCancelFunction sets. Every base screen sets both, to the
## same POG function, so nothing is lost by honouring only the one that fires.
const IN_LEFT := 0
const IN_UP := 1
const IN_RIGHT := 2
const IN_DOWN := 3
const IN_SELECT := 4
const IN_CANCEL := 5
const IN_MOUSE_DOWN := 6
const IN_MOUSE_UP := 7
const IN_MOUSE_HELD := 8

## Screen class -> the POG function that builds it. Derived from the shipped
## scripts: for each screen the campaign names, the function called `<class minus
## "ic">` exists in exactly one package -- and, where it does not, from the
## engine itself. Each icSP* screen's Initialise (vtable slot 16, e.g. iwar2 @
## 0x10029540 for icSPCommsMainMenuScreen) is `FcGUIScreen::Initialise` plus one
## `FcScriptEngine::CallFunction` on a hard-coded name, so the name is not always
## the class name: icSPComputerTradingScreen (Initialise @ 0x10029a80) calls
## "iBaseGUI.SPTradingScreen", icSPAddCargoScreen (@ 0x10028f80) calls
## "iBaseGUI.SPCargoScreen", and icSPComputerPuzzleScreen (@ 0x10029930) calls
## "SPComputerPuzzle.Main". All three builders shipped in the POG and are ported,
## so those screens are as real as the hangar.
##
## The screens still absent from this table fall into three bins:
##  * built in C++ with no POG callback at all (icSpaceFlightScreen, the
##    multiplayer lobby, icPopUpCommsScreen -- a comms panel icComms drives,
##    which comms.gd covers);
##  * icCreditScreen / icNotYetImplementedScreen, C++-built, mirrored engine-side
##    in _enter below;
##  * dead in the original: icSPComputerMenuScreen (@ 0x100297e0) and
##    icSPComputerCommsScreen (@ 0x10029690) call "iBaseGUI.SPComputerMenuScreen"
##    / "iBaseGUI.SPComputerCommsScreen", but no such functions exist in the
##    shipped ibasegui.pog, and nothing -- POG or C++ -- ever raises either class
##    (their names' only other reference is icSPPlayerBaseScreen's diorama map @
##    0x100245xx). They came up empty in the retail game too, so they stay
##    unmapped rather than being invented.
# @element icSPComputerTradingScreen
# @element icSPAddCargoScreen
# @element icSPComputerPuzzleScreen
# @element icSPFlightPDAScreen
const SCREEN_BUILDERS := {
	"icSPBaseScreen": "ibasegui.SPBaseScreen",
	"icSPHangarScreen": "ibasegui.SPHangarScreen",
	"icSPLoadoutScreen": "ibasegui.SPLoadoutScreen",
	"icSPManifestScreen": "ibasegui.SPManifestScreen",
	"icSPInventoryScreen": "ibasegui.SPInventoryScreen",
	"icSPRecyclingScreen": "ibasegui.SPRecyclingScreen",
	"icSPManufacturingScreen": "ibasegui.SPManufacturingScreen",
	"icSPCommsMainMenuScreen": "ibasegui.SPCommsMainMenuScreen",
	"icSPInboxScreen": "ibasegui.SPInboxScreen",
	"icSPArchiveScreen": "ibasegui.SPArchiveScreen",
	"icSPMessagesScreen": "ibasegui.SPMessagesScreen",
	"icSPEncyclopaediaScreen": "ibasegui.SPEncyclopaediaScreen",
	"icSPStatisticsScreen": "ibasegui.SPStatisticsScreen",
	"icSPShipTypeScreen": "ibasegui.SPShipTypeScreen",
	"icSPCustomiseScreen": "ibasegui.SPCustomiseScreen",

	# The base Trade button (iBaseGUI.SPBaseScreen_OnTradeButton overlays it).
	"icSPComputerTradingScreen": "ibasegui.SPTradingScreen",
	# The loadout screen's Add Cargo button and the act-0 training tour.
	"icSPAddCargoScreen": "ibasegui.SPCargoScreen",
	# The triangulation minigame: the base Triangulation button and act 1.
	"icSPComputerPuzzleScreen": "spcomputerpuzzle.Main",

	"icSPMainPDAScreen": "ipdagui.SPMainPDAScreen",
	"icSPBasePDAScreen": "ipdagui.SPBasePDAScreen",
	"icSPPDAOptionsScreen": "ipdagui.SPPDAOptionsScreen",
	"icSPPDAControlsScreen": "ipdagui.SPPDAControlsScreen",
	"icSPPDAGraphicsScreen": "ipdagui.SPPDAGraphicsScreen",
	"icSPPDASoundScreen": "ipdagui.SPPDASoundScreen",
	"icSPPDADeviceScreen": "ipdagui.SPPDADeviceScreen",
	"icSPPDASaveScreen": "ipdagui.SPPDASaveScreen",
	"icSPPDALoadScreen": "ipdagui.SPPDALoadScreen",
	# The in-flight PDA. iwar2 keeps the class name and its builder name side by
	# side in .rdata (1015a478 / 1015a48c), the same Initialise pattern as above.
	"icSPFlightPDAScreen": "ipdagui.SPFlightPDAScreen",
	"icPDAConfirmScreen": "ipdagui.PDAConfirmScreen",
	"icFlightConfirmScreen": "ipdagui.FlightConfirmScreen",
	"icRestartScreen": "ipdagui.RestartScreen",
	"icControlScreen": "ipdagui.ControlScreen",
	"icMoviesScreen": "ipdagui.MoviesScreen",
	"icModScreen": "ipdagui.ModScreen",
}

## `icSPPlayerBaseScreen` is not an ordinary screen: it derives from
## `iiGUIOverlayManager` (iwar2 @ 0x10023710) and its ctor builds a map of the
## screens it hosts -- icSPBaseScreen, icSPHangarScreen, icSPLoadoutScreen ... --
## against a diorama index, alongside the base's backdrop URLs (main_bay_url,
## office_interior_url, jafs_url). It hosts the base menu; it is not the menu.
##
## No POG script ever pushes icSPBaseScreen, yet every Back button in ibasegui
## unwinds with `gui.RemoveOverlaysAfter("icSPBaseScreen")` and the training
## mission tests `"icSPBaseScreen" == gui.CurrentScreenClassname()`. It can only
## be on the stack because the overlay manager put it there. So docking at the
## base raises the manager, and the manager raises the menu.
const AUTO_OVERLAY := {
	"icSPPlayerBaseScreen": "icSPBaseScreen",
}


## One entry on the screen stack: the screen's class name, the widgets its POG
## builder made, and the cancel function that builder registered.
class PogScreen extends RefCounted:
	var name := ""
	var windows: Array[PogWindow] = []
	var over: Array[PogScreen] = []    ## this screen's own overlay stack
	var cancel_fn := ""
	var focus: PogWindow = null
	## Engine-built screens (credits, the apology screen) have no POG cancel
	## function; Escape just pops them, the way FcGame::PopScreen did.
	var pop_on_cancel := false
	## The shady-bar widths THIS screen's builder set (-1 = it never did). In
	## retail each icShadyBar is a control owned by its screen and dies with
	## it; our single global width has to be restored from the screens that
	## remain whenever one pops, or a grey-box overlay's 614 sticks and the
	## 240-wide menu column under it loses its backdrop.
	var shady_width := -1
	var shady_width_rhs := -1


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
	var children: Array = []           ## windows created with this as parent
	var title := ""
	var text := ""
	var enabled := true
	var selected := false
	var highlight := true
	var screen: PogScreen = null
	## The three state colours the scripts set and read back. These are the
	## control's TEXT colours, one per state: igui.CreateInverseButton sets all
	## three to black and gives the control a *filled* amber bar to sit on, which
	## only reads as black-on-amber (igui.pog:270).
	var neutral := Color(1, 1, 1)
	var focused_col := Color(1, 1, 1)
	var selected_col := Color(1, 1, 1)
	## The control's SKIN: `gui.SetWindowStateTextures(win, texture, 36 ints)`.
	## Every control in the game is a THREE-SLICE horizontal strip -- a left cap
	## drawn at its natural width, a body stretched across the middle, a right cap
	## -- and it has one such strip per state. The 36 ints are
	## (left|body|right) x (l,t,r,b) x (neutral|focused|selected), in atlas
	## pixels. igui.pog holds every number as a POG global (SetGUIGlobals), so
	## this is the original skin, not a reproduction of it.
	var tex_url := ""                  ## "texture:/images/gui/gui"
	## state -> [left, body, right] Rect2 in atlas pixels. Empty = no skin.
	var art: Dictionary = {}
	## The control's STATE GLYPH: `gui.SetWindowStateIcons(win, n, f, s)`, one
	## eIcon per state, resolved here to its rect in the alpha map exactly as
	## icCustomisableWindowAvatar::SetAlphaMappedIcon (@ 0x1010c4a0) resolves it
	## and stores it at +0x194. state -> Rect2 in alpha-map pixels; empty = none.
	## This is how an inverse button shows selection AT ALL: igui's
	## MakeInverseButtonIconic gives selected and neutral the SAME three-slice
	## art (igui.pog:629) and distinguishes the states only by this glyph.
	var icons: Dictionary = {}
	var font_url := ""                 ## gui.SetWindowFont
	## gui.SetWindowTextFormatting arg 1: TRUE = centre the title in the
	## window, FALSE = left-aligned at the arg-2 inset. That is exactly what
	## icCustomisableWindowAvatar's text draw does with the flag it stored
	## (SetTextFormatting @ 0x10c320; the draw branches on it @ 0x1010be74
	## region: centred uses (right-left)/2, else the +0x18c offset). The
	## avatar's CTOR defaults the flag to 1 (@ 0x1010c...:201110), which is
	## why igui helpers that want left text always set it explicitly.
	var text_align := 1
	var text_offset := 0               ## ...arg 2: the text's x inset, in px
	## Focus ring, as the scripts wire it (SetWindowNextFocus/PreviousFocus).
	var next_focus: PogWindow = null
	var prev_focus: PogWindow = null
	## List box.
	var entries: Array = []
	var focused_entry := -1            ## an int index; FcListBox::FocusedEntry is
	var selected_index := -1           ## `return *(int *)(this + 0xdc)`
	## First visible row. FcListBox lays entry windows at scroll-adjusted
	## offsets (negative y = scrolled off above, EntryHoveredOver @ 0x88740);
	## we keep the row index the view starts at instead.
	var scroll_top := 0
	## kind == "scrollbar": the list box (or text window) this bar scrolls.
	var scroll_target: PogWindow = null
	## A CreateFancyBorder window: drawn as the border outline.
	var is_border := false
	## Text window as an HTML page (icTextWindow renders HTML: the mails and
	## the encyclopedia are authored pages with <a href> cross-links).
	var page_url := ""                 ## the html: url currently shown
	var page: Array = []               ## parsed blocks (parse_html_page)
	var history: Array = []            ## visited urls; gui.TextWindowBack pops
	var links: Array = []              ## renderer-filled: hrefs by hit index
	var page_h := 0.0                  ## renderer-measured page height, px
	## Edit box / slider / radio / checkbox.
	var value: Variant = ""
	var max_chars := 0
	## NB: a radio's checked state IS `selected` above -- FcRadioButton::SetChecked
	## (flux @ 0x89240) Selects the window and Deselects its siblings, it does not
	## keep a second flag. Holding them apart left every radio the POG checked
	## drawn in the neutral state forever, because the renderer reads `selected`.
	## Edit box editing state: FcEditBox's "being typed into" flag (this[0x91])
	## and the pre-edit text it stashes at +0x10c so Escape can put it back
	## (OnControlFocusSelect @ flux 0x7c4b0 / OnControlFocusCancel @ 0x7c530).
	var editing := false
	var edit_saved := ""
	## gui.SetEditBoxOverrides' three POG functions -- begin-edit, cancel,
	## commit -- stored by FcEditBox::SetOverrides at +0x100/+0x104/+0x108
	## (flux @ 0x78bd0). The save screen wires SetDefaultName / "" / OnSave
	## (ipdagui.pog:508).
	var eb_overrides := PackedStringArray()
	## Splitter.
	var top: PogWindow = null
	var bottom: PogWindow = null
	## The POG functions this control runs.
	var on_press := ""                 ## SetButtonFunctionPog
	var on_select := ""                ## SetListBoxSelectFunction
	var overrides: PackedStringArray = PackedStringArray()  ## the nine slots
	## Engine-built controls have engine actions instead of POG functions.
	## "pop_screen" is the only one: the apology screen's Back row.
	var engine_action := ""
	## kind == "scroller": how far the text has scrolled (px). base_screens.gd
	## advances it at SCROLL_SPEED and calls scroller_done() at the end.
	var scroll := 0.0

	func override(slot: int) -> String:
		if slot < 0 or slot >= overrides.size():
			return ""
		return overrides[slot]

	## Can the player put the focus ring on this?
	func focusable() -> bool:
		if not enabled:
			return false
		return kind in ["button", "listbox", "editbox", "radio", "slider"]


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


## The screens are drawn by base_screens.gd, which has to hang off the same
## CanvasLayer the HUD and the front end do. main._build_pog() runs before that
## layer exists, so the renderer is made on the first screen that has anything on
## it rather than at bind time.
func _ensure_renderer() -> void:
	if screen_ui != null or game == null or game.hud == null:
		return
	var layer: Node = game.hud.get_parent()
	if layer == null:
		return
	screen_ui = BaseScreens.new()
	screen_ui.ui = self
	screen_ui.main = game
	layer.add_child(screen_ui)


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
	# Every Create* takes its parent right after the rect; capture it so a
	# multi-column list-box row (a window holding component static windows,
	# igui.CreateAndInitialiseListBoxEntryComponentWindow) can be read back as
	# one row: the renderer joins the children's titles.
	for arg in a:
		if arg is PogWindow:
			win.parent = arg
			(arg as PogWindow).children.append(win)
			break
	win.neutral = default_colour
	win.focused_col = default_colour
	win.selected_col = default_colour
	win.overrides.resize(9)
	var scr := top_screen()
	if scr != null:
		win.screen = scr
		scr.windows.append(win)
	top_window = win
	dirty = true
	_ensure_renderer()
	return win


# ------------------------------------------------------- POG dispatch
# Every widget callback is a POG function named as a string, "iBaseGUI.OnFoo".
# Running it is what makes a button a button.

## tools/iw2/pogdec.py's _snake: an underscore before every capital but the first.
static func snake(n: String) -> String:
	var out := ""
	for i in n.length():
		var c := n[i]
		if i > 0 and c == c.to_upper() and c != c.to_lower():
			out += "_"
		out += c
	return out.to_lower()


## Run "pkg.Func". Works on either host: the ported scripts are PogScript nodes
## with snake_cased methods, the VM takes the original name.
func dispatch(fq: String) -> Variant:
	if fq.is_empty() or vm == null:
		return 0
	var pkg := fq.get_slice(".", 0).to_lower()
	var fn := fq.get_slice(".", 1)
	if pkg.is_empty() or fn.is_empty():
		return 0
	if vm.has_method("script"):                 # PogRuntime: the ported scripts
		var s = vm.script(pkg)
		if s == null:
			return 0
		var m := snake(fn)
		if not s.has_method(m):
			m = "pog_" + m                      # pogport renames GDScript clashes
		if not s.has_method(m):
			push_warning("POG: %s has no method for %s" % [pkg, fn])
			return 0
		return s.call(m)
	if vm.has_method("start"):                  # PogVM: the bytecode oracle
		vm.start(pkg, fn)
	return 0


# ---------------------------------------------------------------- gui: screens
# The scripts name screens by their C++ class ("icSPHangarScreen"). Raising one
# runs its POG builder, which is what fills it with controls.

func _cur() -> PogScreen:
	return screens[-1] if not screens.is_empty() else null


func top_screen() -> PogScreen:
	var cur := _cur()
	if cur == null:
		return null
	return cur.over[-1] if not cur.over.is_empty() else cur


## Raise a screen: push the record, then run its builder, so that every window the
## builder creates lands on it. An overlay manager raises its hosted menu first.
func _enter(name: String, stack: Array[PogScreen]) -> PogScreen:
	var scr := PogScreen.new()
	scr.name = name
	stack.append(scr)
	dirty = true
	if AUTO_OVERLAY.has(name):
		_enter(String(AUTO_OVERLAY[name]), scr.over)
		return scr
	var builder: String = SCREEN_BUILDERS.get(name, "")
	match name:
		"icCustomGUIScreen":
			# The one screen whose builder is data: its ctor (iwar2 @ 0x100166b0)
			# reads the POG global "g_custom_gui_screen", which
			# igui.OverlayCustomScreen has just set -- Instant Action's ship
			# choice comes through here as iinstantaction.InstantActionShipChoiceScreen.
			builder = _pog_global_string("g_custom_gui_screen")
		"icCreditScreen":
			_build_credit_screen(scr)
		"icNotYetImplementedScreen":
			_build_not_yet_implemented(scr)
	if not builder.is_empty():
		dispatch(builder)
	return scr


## A POG global out of the std store (the ported scripts' side of `global.*`).
func _pog_global_string(name: String) -> String:
	if vm != null and vm.get("std") != null:
		return PogStd._s(vm.std.globals.get(name, ""))
	return ""


# @element icCustomGUIScreen
# @element icCreditScreen
## icCreditScreen (iwar2 ctor @ 0x10016180) is C++: an icScroller over the
## resource "html:\html\credits\credits" inset 0x40 px from the frame, scrolling
## at 50 px/s (constant @ 0x10117be8), popping itself when the text runs out
## (Tick @ 0x100164e0) or on the "Game.MovieSkip" input (OnActivate @
## 0x10016350). The scroll itself is base_screens.gd's job; the backing movie
## ("\movies\credits") and the music stream ("sound:/audio/music/badlands") are
## presentation we do not reproduce here.
func _build_credit_screen(scr: PogScreen) -> void:
	scr.pop_on_cancel = true
	var win := _new_window("scroller", [], 0)
	win.title = "CREDITS"
	win.text = _credits_text()


## The credits copy, out of the extracted resource the original scrolled.
func _credits_text() -> String:
	var text := ""
	if game != null and game.has_method("_base"):
		var f := FileAccess.open(String(game._base()).path_join(
				"data/html/credits/credits.html"), FileAccess.READ)
		if f != null:
			text = f.get_as_text()
	if text.is_empty():
		return "CREDITS\n\n(data/html/credits/credits.html not extracted)"
	# FrontPage-era HTML: <BR> is the only line structure it has.
	var t := text.replace("\r", "").replace("\n", " ")
	for br in ["<BR>", "<br>", "<Br>", "<bR>"]:
		t = t.replace(br, "\n")
	t = BaseScreens._plain(t)
	t = t.replace("&amp;", "&").replace("&nbsp;", " ")
	var out: Array[String] = []
	for line in t.split("\n"):
		out.append(String(line).strip_edges())
	return "\n".join(out)


# @element icNotYetImplementedScreen
## The original's own apology screen, pushed by the base Starmap button. Its
## Initialise (iwar2 @ 0x10028100) calls "iFrontendGUI.NotYetImplementedScreen"
## -- a function that does NOT exist in the shipped ifrontendgui.pog, and no
## text table carries an apology string, so in the retail game this screen came
## up empty. The class name is the whole message; we show it and give the
## player a way back (the retail escape path -- whatever FcGUIScreen did with
## an empty window manager -- is unrecovered).
func _build_not_yet_implemented(scr: PogScreen) -> void:
	scr.pop_on_cancel = true
	var label := _new_window("window", [], 0)
	label.title = "NOT YET IMPLEMENTED"   # the class's own words; no shipped copy
	var back := _new_window("button", [], 0)
	back.title = "BACK"
	back.engine_action = "pop_screen"


# @native gui.SetScreen
func _set_screen(_t, a: Array) -> Variant:
	screens.clear()
	focused = null
	var name := PogStd._s(a[0])
	_enter(name, screens)
	# icSpaceFlightScreen is the C++ flight screen (no POG builder). Inside the
	# base it IS the launch: the hangar's LAUNCH button ends with
	# SetScreen("icSpaceFlightScreen") and the engine's screen change is what
	# tears the base UI down and runs istartsystem's launch cutscene. Deferred:
	# leave() clears the screen stack we are standing in.
	if name == "icSpaceFlightScreen" and game != null \
			and game.get("base_iface") != null and game.base_iface.inside:
		game.base_iface.leave.call_deferred()
	return 0

# @native gui.PushScreen
func _push_screen(_t, a: Array) -> Variant:
	_enter(PogStd._s(a[0]), screens)
	return 0

# @native gui.OverlayScreen
func _overlay_screen(_t, a: Array) -> Variant:
	var cur := _cur()
	if cur == null:
		_enter(PogStd._s(a[0]), screens)
	else:
		_enter(PogStd._s(a[0]), cur.over)
	return 0

# @native gui.PopScreen
func _pop_screen(_t, _a: Array) -> Variant:
	var cur := _cur()
	if cur != null and not cur.over.is_empty():
		cur.over.pop_back()
	elif screens.size() > 1:
		# the screen below comes back with its own overlays intact
		screens.pop_back()
	_restore_shady()
	focused = null
	dirty = true
	return 0

# @native gui.RemoveLastOverlay
func _remove_last_overlay(_t, _a: Array) -> Variant:
	var cur := _cur()
	if cur != null and not cur.over.is_empty():
		cur.over.pop_back()
	_restore_shady()
	focused = null
	dirty = true
	return 0

# @native gui.PopScreensTo
func _pop_screens_to(_t, a: Array) -> Variant:
	var name := PogStd._s(a[0])
	# icSPMasterScreen is the C++ FRONT END, which sits under everything in
	# the original's stack but never on ours. Unwinding to it -- the QUIT
	# confirm's OnOK (ipdagui FlightConfirmScreen_OnOK: PopScreensTo +
	# PopScreen) -- means "leave the session for the main menu".
	if name == "icSPMasterScreen":
		screens.clear()
		focused = null
		dirty = true
		if game != null and game.has_method("quit_to_menu"):
			game.quit_to_menu()
		return 0
	for i in range(screens.size() - 1, -1, -1):
		if screens[i].name == name:
			screens.resize(i + 1)
			break
	_restore_shady()
	focused = null
	dirty = true
	return 0

# @native gui.RemoveOverlaysAfter
func _remove_overlays_after(_t, a: Array) -> Variant:
	# The argument names the screen to be left on top: everything above it goes.
	# This is how every Back button in ibasegui returns to the base menu.
	var name := PogStd._s(a[0])
	var cur := _cur()
	if cur != null:
		for i in range(cur.over.size() - 1, -1, -1):
			if cur.over[i].name == name:
				cur.over.resize(i + 1)
				_restore_shady()
				focused = null
				dirty = true
				return 0
		cur.over.clear()
	for i in range(screens.size() - 1, -1, -1):
		if screens[i].name == name:
			screens.resize(i + 1)
			break
	_restore_shady()
	focused = null
	dirty = true
	return 0

# @native gui.ClearAllScreens
func _clear_screens(_t, _a: Array) -> Variant:
	screens.clear()
	_restore_shady()
	focused = null
	dirty = true
	return 0

# @native gui.NumScreens
func _num_screens(_t, _a: Array) -> Variant:
	var cur := _cur()
	return screens.size() + (cur.over.size() if cur != null else 0)

# @native gui.CurrentScreenClassname
func _current_screen(_t, _a: Array) -> Variant:
	var scr := top_screen()
	return scr.name if scr != null else ""


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
	if win.screen != null:
		win.screen.windows.erase(win)
	win.entries.clear()
	if win.parent != null:
		win.parent.children.erase(win)
	win.parent = null
	dirty = true
	return 0

# @native gui.RepositionWindow
func _reposition(_t, a: Array) -> Variant:
	# (window, parent, x, y) -- it *reparents* as well as moves. The shipped
	# bytecode is unambiguous: igui.ArrangeWindowsVertically (igui.pog entry
	# 17714) walks a list and calls RepositionWindow(w, v1, v2, running) where
	# `running` accumulates each window's canvas height, so the last argument is
	# y and the second is the container -- igui.CreateMenu passes the shady bar
	# it just made, igui.CreateWindowListInFancyBorder the window it just made.
	# We never saw this before the porter's NewObject fix: the list those loops
	# walk was null, so they ran zero times.
	var win := _win(a[0])
	if win == null:
		return 0
	var parent := _win(a[1]) if a.size() > 1 else null
	if parent != null and parent != win.parent:
		if win.parent != null:
			win.parent.children.erase(win)
		win.parent = parent
		parent.children.append(win)
	if a.size() > 3:
		win.x = int(a[2])
		win.y = int(a[3])
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

## The GUI's frame. The engine renders windows in NATIVE pixels --
## FcWindowManager::Render (flux 0x10097000) sets SetPixelCamera /
## SetViewportToWindow, no scaling anywhere -- and the scripts anchor to the
## LIVE frame: igui.CreateShadyBar's column is gui.FrameHeight() tall,
## ibasegui positions windows from `gui.FrameHeight() - 290`, while WIDTHS
## are authored against the nominal 640 (igui.pog:392). An earlier port
## assumption made this a fixed 640x480 canvas, which squashed every screen
## to 480 "pixels" tall and scaled them to mush. FrameWidth/FrameHeight are
## the real window in ORIGINAL-pixel units: the viewport divided by the
## port's fixed-pixel scale (viewport height / 768 -- the same 1024x768
## reference convention menu.gd renders the front end with).
const REF_H := 768.0

func _frame() -> Vector2i:
	if game != null and game.is_inside_tree():
		var vp: Vector2 = game.get_viewport().get_visible_rect().size
		if vp.y > 0.0:
			return Vector2i((vp * (REF_H / vp.y)).round())
	return Vector2i(1024, 768)

# @native gui.SetWindowTitle
func _set_title(_t, a: Array) -> Variant:
	var win := _win(a[0])
	if win != null:
		win.title = PogStd._s(a[1])
		dirty = true
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
		dirty = true
	return 0

# @native gui.DeselectWindow
func _deselect_window(_t, a: Array) -> Variant:
	var win := _win(a[0])
	if win != null:
		win.selected = false
		dirty = true
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
	var scr := top_screen()
	if scr != null:
		scr.focus = focused
	dirty = true
	return 0

# @native gui.FocusedWindow
func _focused_window(_t, _a: Array) -> Variant:
	return focused

# @native gui.TopWindow
func _top_window(_t, _a: Array) -> Variant:
	# `FcWindowManager::TopWindow()` is the current screen's TOP-LEVEL window --
	# the root everything else hangs under -- not "the last window made". The
	# scripts use it as the parent of a screen's root container:
	# igui.CreateShadyBar makes the menu's column with
	# `gui.CreateWindow(13, 0, 240, FrameHeight(), gui.TopWindow())` and then
	# ArrangeWindowsVertically *reparents the buttons into that column*. Handing
	# back the last-created window (which by then is the last button) made the
	# column a child of a button that was about to become its child -- a cycle,
	# and any walk up the parent chain hung. Here a top-level window is simply one
	# with no parent, so the screen root is null.
	return null

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
# The widgets' *contents* are script data: the recycling screen fills a list box
# with cargo and then reads the selection back, so the entries, values and
# indices are kept exactly.

# @native gui.AddListBoxEntry
func _lb_add(_t, a: Array) -> Variant:
	var win := _win(a[0])
	if win != null:
		win.entries.append(a[1])
		dirty = true
	return 0

# @native gui.RemoveListBoxEntry
func _lb_remove(_t, a: Array) -> Variant:
	# The second argument is a ROW INDEX: ibasegui's recycling screen calls
	# RemoveListBoxEntry(box, v1) with the selected row number, then peels the
	# category/superset header rows above it as v1-1 / v1-2.
	var win := _win(a[0])
	if win != null:
		var i := int(a[1]) if not (a[1] is PogWindow) else win.entries.find(a[1])
		if i >= 0 and i < win.entries.size():
			win.entries.remove_at(i)
		win.selected_index = mini(win.selected_index, win.entries.size() - 1)
		win.focused_entry = mini(win.focused_entry, win.entries.size() - 1)
		dirty = true
	return 0

# @native gui.RemoveListBoxEntries
func _lb_clear(_t, a: Array) -> Variant:
	var win := _win(a[0])
	if win != null:
		win.entries.clear()
		win.selected_index = -1
		win.focused_entry = -1
		dirty = true
	return 0

# @native gui.SelectListBoxEntry
func _lb_select(_t, a: Array) -> Variant:
	var win := _win(a[0])
	if win != null:
		win.selected_index = int(a[1])
		dirty = true
	return 0

# @native gui.CancelListBoxSelection
func _lb_cancel(_t, a: Array) -> Variant:
	var win := _win(a[0])
	if win != null:
		win.selected_index = -1
		dirty = true
	return 0

# @native gui.ListBoxSelectedIndex
func _lb_selected(_t, a: Array) -> Variant:
	var win := _win(a[0])
	return win.selected_index if win != null else -1

# @native gui.ListBoxFocusedEntry
func _lb_focused(_t, a: Array) -> Variant:
	# An int index, not the entry. FcListBox::FocusedEntry (flux @ 0x100870d0) is
	# `return *(int *)(this + 0xdc)`, and ibasegui reads it as one: it tests the
	# result against -1 and then passes it to iemail.NthInArchive as a row number.
	var win := _win(a[0])
	return win.focused_entry if win != null else -1

# @native gui.SetListBoxFocusedEntry
func _lb_set_focused(_t, a: Array) -> Variant:
	var win := _win(a[0])
	if win != null:
		win.focused_entry = int(a[1])
		dirty = true
	return 0

# @native gui.SetListBoxSelectFunction
func _lb_set_select_fn(_t, a: Array) -> Variant:
	var win := _win(a[0])
	if win != null:
		win.on_select = PogStd._s(a[1])
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
	dirty = true
	return 0

# @native gui.SetEditBoxMaxCharLength
func _eb_set_max(_t, a: Array) -> Variant:
	var win := _win(a[0])
	if win != null:
		win.max_chars = int(a[1])
	return 0

# @native gui.SetRadioButtonChecked
func _rb_set(_t, a: Array) -> Variant:
	# FcRadioButton::SetChecked (flux @ 0x89240): ONLY the false->true edge does
	# anything -- it Selects this window and walks the parent's child list,
	# Deselecting every other FcRadioButton it finds. There is no direct
	# uncheck; a radio only clears when a sibling takes the group. A parentless
	# radio hangs off the screen's root window, so its group is the screen's
	# other parentless radios.
	var win := _win(a[0])
	if win == null or not PogVM._truthy(a[1]):
		return 0
	radio_latch(win)
	return 0


## FcRadioButton::SetChecked's false->true edge: Select this window, then walk
## the group Deselecting every other radio in it.
func radio_latch(win: PogWindow) -> void:
	if win.selected:
		return
	win.selected = true
	var siblings: Array = []
	if win.parent != null:
		siblings = win.parent.children
	elif win.screen != null:
		for w in win.screen.windows:
			if w.parent == null:
				siblings.append(w)
	for s in siblings:
		if s != win and (s as PogWindow).kind == "radio":
			(s as PogWindow).selected = false
	dirty = true

# @native gui.RadioButtonValue
func _rb_value(_t, a: Array) -> Variant:
	var win := _win(a[0])
	return (1 if win.selected else 0) if win != null else 0

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
		dirty = true
	return 0

# @native gui.SetTextWindowString
func _tw_set_string(_t, a: Array) -> Variant:
	var win := _win(a[0])
	if win != null:
		var s := PogStd._s(a[1])
		# the engine's text window renders HTML whether it came from a
		# resource or a string: the statistics screen BUILDS its page as an
		# html string ("<html><body><p>Kills: ...") and hands it here. Without
		# the conversion the tags drew literally and every <p> collapsed onto
		# one line.
		if s.findn("<html") != -1 or s.findn("<p") != -1 \
				or s.findn("<br") != -1:
			win.page = parse_html_page(s)
			s = html_to_text(s)
		else:
			win.page = []
		win.page_url = ""
		win.text = s
		dirty = true
	return 0

# @native gui.SetTextWindowResource
func _tw_set_resource(_t, a: Array) -> Variant:
	# SetTextWindowResource(window, "html:/text/act_0/act0_master_lucreciamail_1")
	# -- the engine points the text window at an HTML resource page: this is how
	# the comms screen shows a mail's body and the encyclopedia its topics. The
	# pages live extracted under data/ (tools/iw2/html_text.py). Setting a new
	# resource starts a fresh visited-page stack.
	var win := _win(a[0])
	if win != null:
		win.history.clear()
		_tw_load(win, PogStd._s(a[1]))
	return 0


## Load an html: page into a text window: parsed blocks for the renderer, the
## plain text as fallback, scroll to the top.
func _tw_load(win: PogWindow, url: String) -> void:
	win.page_url = url
	var raw := _resource_raw(url)
	win.page = parse_html_page(raw)
	win.text = html_to_text(raw)
	win.scroll = 0.0
	dirty = true


## Follow a page link. hrefs are relative to the current page's directory
## (index.html links "ships/corvettes/Dreadnaught_Corvette"), and the engine's
## icTextWindow keeps the visited stack that TextWindowBack pops.
func text_window_follow(win: PogWindow, href: String) -> void:
	if win == null or href.is_empty():
		return
	var target := href
	if not target.begins_with("html:"):
		var dir := win.page_url.replace("\\", "/").trim_prefix("html:") \
				.get_base_dir()
		target = "html:" + dir.path_join(href).simplify_path()
	if not win.page_url.is_empty():
		win.history.append(win.page_url)
	_tw_load(win, target)


# @native gui.TextWindowBack
func _tw_back(_t, a: Array) -> Variant:
	# Pops one visited page and reports whether it navigated: the
	# encyclopedia's Back button only leaves the screen when this returns 0
	# (ibasegui SPEncyclopaediaScreen_OnBackButton).
	var win := _win(a[0])
	if win == null or win.history.is_empty():
		return 0
	_tw_load(win, String(win.history.pop_back()))
	return 1


## "html:" + resource path, extension implied, either slash. Empty when the
## page is missing (a URL the scripts build for content that never shipped).
func _resource_raw(url: String) -> String:
	if url.is_empty():
		return ""
	var path := url.replace("\\", "/").trim_prefix("html:").trim_prefix("/")
	if not path.ends_with(".html"):
		path += ".html"
	if game == null or not game.has_method("_base"):
		return ""
	var full := String(game._base()).path_join("data").path_join(path)
	if not FileAccess.file_exists(full):
		return ""
	return FileAccess.get_file_as_string(full)


func _resource_text(url: String) -> String:
	return html_to_text(_resource_raw(url))


# --- the HTML page model ----------------------------------------------------
# icTextWindow renders its HTML itself. parse_html_page turns a page into
# renderable blocks -- {kind:"rule"} or {kind:"para", spans:[{t, link, b}]},
# with {br:true} spans for forced line breaks -- and base_screens.gd lays the
# spans out, underlines the links and hit-tests them.

static var _re_ws := RegEx.create_from_string("\\s+")
static var _re_href := RegEx.create_from_string("(?i)href\\s*=\\s*\"?([^\"\\s>]+)")

static func parse_html_page(raw: String) -> Array:
	var body := raw
	var mb := RegEx.create_from_string("(?is)<body[^>]*>(.*?)</body>").search(raw)
	if mb != null:
		body = mb.get_string(1)
	body = body.replace("\r", " ").replace("\n", " ").replace("\t", " ")
	var st := {"cur": "", "link": "", "bold": false,
			"spans": [], "blocks": []}
	var i := 0
	var n := body.length()
	while i < n:
		var lt := body.find("<", i)
		if lt == -1:
			st.cur += _entities(body.substr(i))
			break
		if lt > i:
			st.cur += _entities(body.substr(i, lt - i))
		var gt := body.find(">", lt)
		if gt == -1:
			break
		var tag := body.substr(lt + 1, gt - lt - 1).strip_edges()
		i = gt + 1
		var tl := tag.to_lower()
		if tl == "p" or tl.begins_with("p ") or tl == "/p":
			_hp_flush_para(st)
		elif tl == "br" or tl.begins_with("br ") or tl.begins_with("br/"):
			_hp_flush_span(st)
			st.spans.append({"br": true})
		elif tl == "hr" or tl.begins_with("hr "):
			_hp_flush_para(st)
			st.blocks.append({"kind": "rule"})
		elif tl == "a" or tl.begins_with("a "):
			_hp_flush_span(st)
			var m := _re_href.search(tag)
			st.link = m.get_string(1) if m != null else ""
		elif tl == "/a":
			_hp_flush_span(st)
			st.link = ""
		elif tl == "b" or tl == "strong":
			_hp_flush_span(st)
			st.bold = true
		elif tl == "/b" or tl == "/strong":
			_hp_flush_span(st)
			st.bold = false
		# every other tag is presentation we do not model; dropped
	_hp_flush_para(st)
	return st.blocks

static func _entities(s: String) -> String:
	return s.replace("&nbsp;", " ").replace("&amp;", "&") \
		.replace("&lt;", "<").replace("&gt;", ">") \
		.replace("&quot;", "\"").replace("&#39;", "'")

static func _hp_flush_span(st: Dictionary) -> void:
	var t := _re_ws.sub(String(st.cur), " ", true)
	if not t.is_empty():
		st.spans.append({"t": t, "link": st.link, "b": st.bold})
	st.cur = ""

static func _hp_flush_para(st: Dictionary) -> void:
	_hp_flush_span(st)
	var spans: Array = st.spans
	while not spans.is_empty() and not bool(spans[0].get("br", false)) \
			and String(spans[0].get("t", "")).strip_edges().is_empty():
		spans.pop_front()
	while not spans.is_empty() and not bool(spans[-1].get("br", false)) \
			and String(spans[-1].get("t", "")).strip_edges().is_empty():
		spans.pop_back()
	if not spans.is_empty():
		st.blocks.append({"kind": "para", "spans": spans.duplicate()})
	spans.clear()


## Word-era page HTML -> the plain paragraphs the text window draws. Raw
## newlines are only whitespace (the sources hard-wrap); <p> and <br> are the
## real structure, and folding the rest lets each paragraph reflow to the
## window's width, which is what the original's HTML renderer did too.
static func html_to_text(raw: String) -> String:
	var body := raw
	var re_body := RegEx.create_from_string("(?is)<body[^>]*>(.*?)</body>")
	var mb := re_body.search(raw)
	if mb != null:
		body = mb.get_string(1)
	body = body.replace("\r\n", "\n").replace("\r", "\n")
	body = body.replace("\n", " ").replace("\t", " ")
	body = RegEx.create_from_string("(?i)<p[^>]*>").sub(body, "\n\n", true)
	body = RegEx.create_from_string("(?i)<br[^>]*>").sub(body, "\n", true)
	body = RegEx.create_from_string("(?is)<style.*?</style>").sub(body, "", true)
	body = RegEx.create_from_string("(?s)<!--.*?-->").sub(body, "", true)
	body = RegEx.create_from_string("<[^>]*>").sub(body, "", true)
	body = body.replace("&nbsp;", " ").replace("&amp;", "&")
	body = body.replace("&lt;", "<").replace("&gt;", ">")
	body = body.replace("&quot;", "\"").replace("&#39;", "'")
	body = RegEx.create_from_string("  +").sub(body, " ", true)
	var out: Array[String] = []
	for para in body.split("\n"):
		out.append(String(para).strip_edges())
	var text := "\n".join(out)
	# collapse runs of blank lines left by empty paragraphs
	while "\n\n\n" in text:
		text = text.replace("\n\n\n", "\n\n")
	return text.strip_edges()

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


# ---------------------------------------------------------------- gui: creation
# The Create* calls hand back a window that belongs to the screen being built.
# What each one is, and what it holds, is real; how it is skinned is not.

# @native gui.CreateWindow
# @native gui.CreateStaticWindow
func _create_window(_t, a: Array) -> Variant:
	return _new_window("window", a, 0)

# @native gui.CreateVerticalScrollbar
func _create_scrollbar(_t, a: Array) -> Variant:
	# CreateVerticalScrollbar(x, y, w, h, parent, listbox, buttonratio, fn):
	# the bar is its own control wired to the list box it scrolls -- FcListBox
	# lays its entry windows at scroll-adjusted offsets (EntryHoveredOver
	# @ 0x88740 hit-tests entries whose stored y has gone negative), and the
	# bar drives that offset. Ours records the target and base_screens.gd draws
	# the track/thumb and pages the target's scroll_top.
	var win := _new_window("scrollbar", a, 0)
	win.scroll_target = _win(a[5]) if a.size() > 5 else null
	return win

# @native gui.CreateFancyBorder
func _create_fancy_border(_t, a: Array) -> Variant:
	# CreateFancyBorder(window): FcBorder::AttachToWindow (flux @ 0x77950)
	# makes the border ITS OWN WINDOW -- the wrapped window's rect grown by the
	# border width (FcBorder ctor passes 7) on every side, parented to the
	# wrapped window's parent. Scripts measure it: SPHangarScreen positions the
	# SHIP/LOADOUT readouts at WindowCanvasHeight(border) below the button box.
	var inner = a[0] if a.size() > 0 else null
	var win := PogWindow.new()
	win.kind = "window"
	win.is_border = true
	if inner is PogWindow:
		var iw: PogWindow = inner
		win.x = iw.x - 7
		win.y = iw.y - 7
		win.w = iw.w + 14
		win.h = iw.h + 14
		if iw.parent != null:
			win.parent = iw.parent
			iw.parent.children.append(win)
	win.neutral = default_colour
	win.focused_col = default_colour
	win.selected_col = default_colour
	win.overrides.resize(9)
	var scr := top_screen()
	if scr != null:
		win.screen = scr
		scr.windows.append(win)
	dirty = true
	_ensure_renderer()
	return win

# @native gui.CreateButton
# @native gui.CreateBackButton
func _create_button(_t, a: Array) -> Variant:
	# CreateButton(x, y, w, h, parent) -- and igui hands the POG function in
	# separately, through SetButtonFunctionPog.
	return _new_window("button", a, 0)

# @native gui.CreateRadioButton
# @native gui.CreateCheckbox
func _create_radio(_t, a: Array) -> Variant:
	return _new_window("radio", a, 0)

# @native gui.CreateListBox
func _create_listbox(_t, a: Array) -> Variant:
	return _new_window("listbox", a, 0)

# @native gui.CreateEditBox
func _create_editbox(_t, a: Array) -> Variant:
	# CreateEditBox(x, y, w, h, parent, multiline, text, flag): arg 6 is the
	# box's initial text -- the save screen seeds each slot row with its saved
	# name or the localised "[Empty]" through it (ipdagui.pog:507).
	var win := _new_window("editbox", a, 0)
	win.value = PogStd._s(a[6]) if a.size() > 6 else ""
	win.eb_overrides.resize(3)
	return win

# @native gui.CreateSliderControl
func _create_slider(_t, a: Array) -> Variant:
	var win := _new_window("slider", a, 0)
	win.value = 0.0
	return win

# @native gui.CreateTextWindow
func _create_textwindow(_t, a: Array) -> Variant:
	return _new_window("text", a, 0)

# @native gui.CreateSplitterWindow
func _create_splitter(_t, a: Array) -> Variant:
	# CreateSplitterWindow(x, y, w, h, parent, split, flags): the splitter
	# divides its rect into a TOP pane `split` px tall and a BOTTOM pane with
	# the rest, and the panes are real windows -- the loadout screen sizes
	# the MANIFEST title off WindowCanvasWidth/Height of the top pane and
	# hangs the manifest text in the bottom. Bare zero-sized panes collapsed
	# all of it to (0,0 0x0) and spilled the fit list over the menu.
	var win := _new_window("splitter", a, 0)
	var split: int = int(a[5]) if a.size() > 5 else 0
	win.top = PogWindow.new()
	win.bottom = PogWindow.new()
	for pane: PogWindow in [win.top, win.bottom]:
		pane.overrides.resize(9)
		pane.screen = win.screen
		pane.parent = win
		pane.w = win.w
	win.top.h = clampi(split, 0, win.h)
	win.bottom.y = win.top.h
	win.bottom.h = maxi(win.h - win.top.h, 0)
	return win


# ---------------------------------------------------------------- gui: callbacks
# What makes a button a button: the POG function it runs.

# @native gui.SetButtonFunctionPog
func _set_button_fn(_t, a: Array) -> Variant:
	var win := _win(a[0])
	if win != null:
		win.on_press = PogStd._s(a[1])
	return 0

# @native gui.SetInputOverrideFunctions
func _set_input_overrides(_t, a: Array) -> Variant:
	# (window, left, up, right, down, select, cancel, mdown, mup, mheld) -- the
	# nine eInputMessages slots, in the engine's own order (see IN_* above).
	var win := _win(a[0])
	if win == null:
		return 0
	for i in 9:
		win.overrides[i] = PogStd._s(a[i + 1]) if a.size() > i + 1 else ""
	return 0

# @native gui.SetControlFocusCancelFunction
func _set_cancel_fn(_t, a: Array) -> Variant:
	# The window manager's single global cancel function -- what Escape runs.
	var scr := top_screen()
	if scr != null:
		scr.cancel_fn = PogStd._s(a[0])
	return 0

# @native gui.SetEditBoxOverrides
func _eb_set_overrides(_t, a: Array) -> Variant:
	# FcEditBox::SetOverrides(begin, cancel, commit) (flux @ 0x78bd0): three POG
	# functions, run on the Select that starts editing, on Escape while editing,
	# and on the Select that commits (FcEditBox::OnControlFocusSelect @ 0x7c4b0,
	# OnControlFocusCancel @ 0x7c530).
	var win := _win(a[0])
	if win == null:
		return 0
	win.eb_overrides.resize(3)
	for i in 3:
		win.eb_overrides[i] = PogStd._s(a[i + 1]) if a.size() > i + 1 else ""
	return 0

# @native gui.CancelFocusLock
func _cancel_focus_lock(_t, _a: Array) -> Variant:
	# An edit box holds the focus while it is being typed into; this releases it.
	if focused != null and focused.kind == "editbox":
		focused.editing = false
		focused = null
		dirty = true
	return 0

# @native gui.OnControlFocusLeft
func _on_focus_left(_t, a: Array) -> Variant:
	return _fire(_win(a[0]), IN_LEFT)

# @native gui.OnControlFocusRight
func _on_focus_right(_t, a: Array) -> Variant:
	return _fire(_win(a[0]), IN_RIGHT)

# @native gui.OnControlFocusSelect
func _on_focus_select(_t, a: Array) -> Variant:
	return activate(_win(a[0]))


## Run whatever the window has in an input slot.
func _fire(win: PogWindow, slot: int) -> Variant:
	if win == null:
		return 0
	var fn := win.override(slot)
	return dispatch(fn) if not fn.is_empty() else 0


## Enter on a control. The engine's OnControlFocusSelect consults slot 4 first and
## falls back to the control's own action, so a list box that was given a select
## override runs that, and a plain button runs its button function.
func activate(win: PogWindow) -> Variant:
	if win == null or not win.enabled:
		return 0
	if win.kind == "editbox":
		return _eb_select(win)
	if win.kind == "listbox":
		win.selected_index = win.focused_entry
	if win.kind == "radio":
		# a radio LATCHES; there is no direct uncheck (FcRadioButton::SetChecked
		# @ 0x89240). Toggling let Enter clear a group and never select a
		# sibling, so ibasegui's RadioButtonValue scans matched nothing.
		radio_latch(win)
	dirty = true
	var fn := win.override(IN_SELECT)
	if fn.is_empty():
		fn = win.on_select if win.kind == "listbox" else win.on_press
	if fn.is_empty():
		fn = win.on_press
	if fn.is_empty() and win.engine_action == "pop_screen":
		return _pop_screen(null, [])
	return dispatch(fn) if not fn.is_empty() else 0


## Select on an edit box, FcEditBox::OnControlFocusSelect (flux @ 0x7c4b0).
## Not editing yet: stash the text, run the begin override (the save screen's
## SetDefaultName proposes "ACT n  <time>"), lock the focus for typing, cursor
## to the end. Already editing: run the commit override (OnSave) and end the
## edit (CancelEditing).
func _eb_select(win: PogWindow) -> Variant:
	dirty = true
	if win.editing:
		return eb_commit(win)
	win.edit_saved = PogStd._s(win.value)
	var out: Variant = 0
	if not win.eb_overrides[0].is_empty():
		out = dispatch(win.eb_overrides[0])
	win.editing = true
	return out


## The committing half of the edit, shared with the focus moves: FcEditBox's
## OnControlFocusUp/Down (flux @ 0x7c570/0x7c5b0) run the commit override and
## CancelEditing before letting the focus leave the box.
func eb_commit(win: PogWindow) -> Variant:
	win.editing = false
	dirty = true
	if not win.eb_overrides[2].is_empty():
		return dispatch(win.eb_overrides[2])
	return 0


## Escape. FcWindow::OnControlFocusCancel ends at the window manager's global
## cancel function, which is the one the screen's builder registered. In the
## engine that function is a single global slot, so a windowless C++ overlay
## (icPopUpCommsScreen) leaves the previous screen's cancel in force -- which is
## what the fall-through below reproduces.
func cancel() -> Variant:
	# An edit box being typed into eats the cancel first: run its cancel
	# override, put the pre-edit text back and stop editing, leaving the screen
	# up (FcEditBox::OnControlFocusCancel @ flux 0x7c530).
	if focused != null and focused.kind == "editbox" and focused.editing:
		var win := focused
		win.value = win.edit_saved
		win.editing = false
		dirty = true
		if not win.eb_overrides[1].is_empty():
			return dispatch(win.eb_overrides[1])
		return 0
	for scr in _view_order():
		if not scr.cancel_fn.is_empty():
			return dispatch(scr.cancel_fn)
		if scr.pop_on_cancel:
			return _pop_screen(null, [])
		if not scr.windows.is_empty():
			return 0                # a real screen chose to have no cancel
	return 0


## Top-down: the current screen's overlays, the screen, then on down the stack.
func _view_order() -> Array[PogScreen]:
	var out: Array[PogScreen] = []
	for i in range(screens.size() - 1, -1, -1):
		var s := screens[i]
		for j in range(s.over.size() - 1, -1, -1):
			out.append(s.over[j])
		out.append(s)
	return out


## The screen worth drawing: the topmost one that actually has windows.
## icPopUpCommsScreen (a windowless C++ overlay whose content comms.gd draws)
## must not blank the base menu underneath it.
func visible_screen() -> PogScreen:
	for scr in _view_order():
		if not scr.windows.is_empty():
			return scr
	return null


## base_screens.gd calls this when a scroller's text has fully run out: the
## credits pop themselves, exactly as icCreditScreen's Tick @ 0x100164e0 does.
func scroller_done(win: PogWindow) -> void:
	if win.screen != null and win.screen == top_screen():
		_pop_screen(null, [])


# ---------------------------------------------------------------- gui: skin
# Presentation we deliberately do not reproduce. SetWindowStateTextures takes 38
# arguments -- a nine-patch atlas per widget state -- and the remaster has its own
# look; the background movies are the base's animated backdrops.
# @stub gui.SetWindowStateTextures
# @stub gui.SetShadyBarWidth
# @stub gui.SetRHSShadyBarWidth
# @stub gui.PlayBackgroundMovie
# @stub gui.StopBackgroundMovie
# @stub gui.StopAllMovies
# @stub gui.TextWindowBack
# @stub gui.SetEditBoxCursorToEnd -- our caret always sits at the end of the
#   text (base_screens draws it there), which is exactly where SetCursorToEnd
#   (flux @ 0x78c10, SetCursorFromPoint(100000,100000)) put it.
func _gui_noop(_t, _a: Array) -> Variant:
	return 0


## `gui.SetWindowStateTextures(window, texture, 36 ints)` -- the control's skin.
## The engine's own widget art: a three-slice strip (left cap / stretched body /
## right cap) per state, cut out of a shared atlas. The numbers all come from
## igui.SetGUIGlobals, so nothing here is chosen by us: e.g. the base menu's
## fancy button is 226x32 with its neutral art at atlas (0,36)-(39,68), its
## focused art at (40,36)-(80,68) and its selected art at (81,36)-(120,68)
## (igui.pog:129+). base_screens.gd blits exactly these rects.
# @native gui.SetWindowStateTextures
func _set_state_textures(_t, a: Array) -> Variant:
	var win := _win(a[0])
	if win == null or a.size() < 38:
		return 0
	win.tex_url = PogStd._s(a[1])
	var states := ["neutral", "focused", "selected"]
	var slices := ["left", "body", "right"]
	var i := 2
	for s in states:
		var strip: Array = []
		for _sl in slices:
			var l := float(a[i])
			var t := float(a[i + 1])
			var r := float(a[i + 2])
			var b := float(a[i + 3])
			strip.append(Rect2(l, t, maxf(r - l, 0.0), maxf(b - t, 0.0)))
			i += 4
		win.art[s] = strip
	dirty = true
	return 0


## icCustomisableWindowAvatar's static icon table, written at 0x1010b480:
## eIcon -> top-left in the alpha map. eax/ecx/edx there are 0/17/34, so the
## glyphs sit on a 17 px grid (16 px cell + 1 px gutter) in the top-left 3x2
## corner of the 64x64 map. Indices 0 and 2 are both (0,0) in the original.
const ICON_XY: Array[Vector2i] = [
	Vector2i(0, 0), Vector2i(0, 17), Vector2i(0, 0), Vector2i(17, 17),
	Vector2i(17, 0), Vector2i(34, 17), Vector2i(34, 0),
]
## m_icon_size, set to (16, 16) at 0x1010b4f0.
const ICON_SIZE := Vector2i(16, 16)


## `gui.SetWindowStateIcons(window, neutral, focused, selected)` -- the glyph
## the control wears per state, out of texture:/images/gui/gui_alphamap
## (icCustomisableWindowAvatar::m_icon_texture, set @ 0x1010b510).
## SetStateIcons (@ 0x1010c530) is three SetAlphaMappedIcon calls, one per
## state index, and each resolves eIcon -> a rect through ICON_XY above.
# @native gui.SetWindowStateIcons
func _set_state_icons(_t, a: Array) -> Variant:
	var win := _win(a[0])
	if win == null or a.size() < 4:
		return 0
	var states := ["neutral", "focused", "selected"]
	for i in states.size():
		var idx := int(a[i + 1])
		if idx < 0 or idx >= ICON_XY.size():
			win.icons.erase(states[i])
			continue
		win.icons[states[i]] = Rect2(ICON_XY[idx], ICON_SIZE)
	dirty = true
	return 0


## The width of the "shady bar" -- the translucent column the menus sit on
## (igui.CreateShadyBar: GUI_shader_width = 240 px, GUI_shader_opacity = 0.8).
var shady_width := 0
var shady_width_rhs := 0

# @native gui.SetShadyBarWidth
func _set_shady_width(_t, a: Array) -> Variant:
	shady_width = int(a[0])
	var scr := top_screen()
	if scr != null:
		scr.shady_width = shady_width
	return 0

# @native gui.SetRHSShadyBarWidth
func _set_shady_width_rhs(_t, a: Array) -> Variant:
	shady_width_rhs = int(a[0])
	var scr := top_screen()
	if scr != null:
		scr.shady_width_rhs = shady_width_rhs
	return 0

## Re-derive the global widths from the screens still standing, most recently
## raised wins -- the per-screen half of the icShadyBar ownership note above.
func _restore_shady() -> void:
	shady_width = 0
	shady_width_rhs = 0
	var cur := _cur()
	if cur == null:
		return
	var chain: Array = [cur]
	chain.append_array(cur.over)
	for scr: PogScreen in chain:
		if scr.shady_width >= 0:
			shady_width = scr.shady_width
		if scr.shady_width_rhs >= 0:
			shady_width_rhs = scr.shady_width_rhs

# @native gui.SetWindowFont
# @native gui.SetDefaultFont
# @native gui.SetWindowTextFormatting
# @native gui.SetBackgroundImage
func _gui_style(_t, a: Array) -> Variant:
	# gui.SetDefaultFont(url) / gui.SetWindowFont(window, url) /
	# gui.SetWindowTextFormatting(window, align, x_offset). The fonts are the
	# game's own bitmap fonts and we load them: GUI_title_font is
	# "font:/fonts/square721 bdex bt_8pt", which is data/fonts/*.fnt.
	if a.size() == 1:
		default_font = PogStd._s(a[0])
		return 0
	var win := _win(a[0])
	if win == null:
		return 0
	if a.size() == 2:
		win.font_url = PogStd._s(a[1])
	elif a.size() >= 3:
		win.text_align = int(a[1])
		win.text_offset = int(a[2])
	dirty = true
	return 0


# ---------------------------------------------------------------- ioptions
# The options screen. Register*(label_key, config_section, config_key, ...)
# declares one row; the value lives in the config store, so Apply is a write-back
# and the getters read through.

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

# @native ioptions.CreateWindows
func _opt_create_windows(_t, a: Array) -> Variant:
	# One row per registered option, as a button whose title carries the current
	# value. Selecting it steps the option, which is what OnSelect does.
	var parent := _win(a[0] if a.size() > 0 else null)
	for i in options.size():
		var o: PogOption = options[i]
		var row := _new_window("button", [], 0)
		row.parent = parent
		row.title = _option_label(o)
		row.on_press = ""
		row.overrides[IN_SELECT] = ""
		row.value = i                 # which option this row steps
		row.kind = "option"
	dirty = true
	return 0

## "Detail  HIGH" -- the label the option row shows.
func _option_label(o: PogOption) -> String:
	var text: String = o.label
	if game != null and game.comms != null:
		text = game.comms.strings.get(o.label, o.label)
	var v: Variant = _opt_load(o)
	match o.kind:
		"bool":
			return "%s: %s" % [text, "ON" if PogVM._truthy(v) else "OFF"]
		"float":
			return "%s: %d%%" % [text, roundi(100.0 * (float(v) - o.lo)
					/ maxf(o.hi - o.lo, 0.0001))]
	return "%s: %d" % [text, int(v)]

# The graphics device/resolution rows are the two the options screen builds by
# hand rather than through Register*; both offer exactly one device, so there is
# nothing to choose between.
# @stub ioptions.CreateGraphicsDeviceOptionButtons
# @stub ioptions.CreateGraphicsResolutionOptionButtons
func _opt_noop(_t, _a: Array) -> Variant:
	return 0


# ---------------------------------------------------------------- input
# BindKey("csvchecker.SetStringRepeat", "ScriptKeys.repeatcsvchecker"): the first
# argument is the POG function to run, the second names an *engine* action.

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

# @native input.KeyCombinations
func _key_combinations(_t, a: Array) -> Variant:
	# "which key is icPlayerPilot.CycleContactUp bound to" -- the prompts splice
	# the answer into their text. The keymap is not engine-side after all: the
	# game ships it (configs/default.ini), and FcInputMapper::KeyString
	# (flux 0x1006ade0) -> FormKeyString (0x1006ab00) -> FcLocalisedText::Field
	# (0x10028d80) is what renders "[ Keyboard F8 ]" / "[ SHIFT - Keyboard M ]".
	if game == null:
		return ""
	return PogMisc.key_combinations(game._base(), AudioManager.GAME_DIR,
		PogStd._s(a[0]))


## Run whatever POG function is bound to a named action.
func fire(action: String) -> void:
	if bindings_suspended:
		return
	dispatch(String(bindings.get(action, "")))


# ---------------------------------------------------------------- config
# config.GetBool("system", "InstantAction", "tug"): a store name, a section and a
# key. "system" is the only store the scripts use.

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
	"gui.setlistboxselectfunction": "_lb_set_select_fn",
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
	"gui.createfancyborder": "_create_fancy_border",
	"gui.createverticalscrollbar": "_create_scrollbar",
	"gui.createbutton": "_create_button",
	"gui.createbackbutton": "_create_button",
	"gui.createradiobutton": "_create_radio",
	"gui.createcheckbox": "_create_radio",
	"gui.createlistbox": "_create_listbox",
	"gui.createeditbox": "_create_editbox",
	"gui.createslidercontrol": "_create_slider",
	"gui.createtextwindow": "_create_textwindow",
	"gui.createsplitterwindow": "_create_splitter",

	"gui.setbuttonfunctionpog": "_set_button_fn",
	"gui.setinputoverridefunctions": "_set_input_overrides",
	"gui.setcontrolfocuscancelfunction": "_set_cancel_fn",
	"gui.cancelfocuslock": "_cancel_focus_lock",
	"gui.oncontrolfocusleft": "_on_focus_left",
	"gui.oncontrolfocusright": "_on_focus_right",
	"gui.oncontrolfocusselect": "_on_focus_select",

	"gui.setdefaultfont": "_gui_style", "gui.setwindowfont": "_gui_style",
	"gui.setwindowtextformatting": "_gui_style",
	"gui.setbackgroundimage": "_gui_style",

	"gui.setwindowstatetextures": "_set_state_textures",
	"gui.setshadybarwidth": "_set_shady_width",
	"gui.setrhsshadybarwidth": "_set_shady_width_rhs",
	"gui.setwindowstateicons": "_set_state_icons",
	"gui.playbackgroundmovie": "_gui_noop",
	"gui.stopbackgroundmovie": "_gui_noop", "gui.stopallmovies": "_gui_noop",
	"gui.settextwindowresource": "_tw_set_resource",
	"gui.textwindowback": "_tw_back",
	"gui.seteditboxoverrides": "_eb_set_overrides",
	"gui.seteditboxcursortoend": "_gui_noop",

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
	"ioptions.createwindows": "_opt_create_windows",
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
