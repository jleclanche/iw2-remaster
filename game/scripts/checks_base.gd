extends "checks_camp.gd"
# The base-GUI suites: --uicheck screenshots and --basecheck.
# Part of the checks extends chain (issue #31):
# checks_state <- checks_probes <- checks_camp <- checks_base <-
# checks_jump <- checks_mech <- checks.gd (CheckRunner, the dispatcher).
# Same node, same class -- the split mirrors main.gd's layered-file scheme.

func _bc_shady_sane(screen: String) -> void:
	var img := get_viewport().get_texture().get_image()
	var w := img.get_width()
	var h := img.get_height()
	# a patch inside the left bar, which every base screen has: past the edge
	# gradient (m_edge_width 8 native px) and well short of the 240 px column
	var lum: Array[float] = []
	for xi in 12:
		var x := int(w * (0.02 + 0.01 * xi))
		for yi in 20:
			var y := int(h * (0.1 + 0.04 * yi))
			if x >= w or y >= h:
				continue
			var c := img.get_pixel(x, y)
			lum.append(minf(c.r, c.g))   # amber saturates BOTH channels
	if lum.is_empty():
		return
	lum.sort()
	var med: float = lum[lum.size() / 2]
	# 0.8 black over the interior plus at most ~0.3 of additive amber; a runaway
	# column sits at 1.0 across the whole patch.
	_bc("%s: shady bar stays translucent" % screen, med < 0.5,
		"median amber %.2f over %d samples" % [med, lum.size()])

# --- UI screenshots -----------------------------------------------------------

func _uicheck(_delta: float) -> void:
	match demo_phase:
		0:
			if demo_t > 0.5 and not m.menu.visible:
				m.menu.launched = false
				m.menu.open()
			if demo_t > 2.5:
				_shot("ui_menu")
				m.menu.launched = true
				m.menu.close()
				m.cam_mode = 0
				m._apply_view()
				var hostile: AiShip = m.spawn_hostile(Vector3(1200, 150, -2200))
				m.target_ai = hostile
				m.comms.say_key("a0_m10_dialogue_clay_i_know")
				demo_phase = 1
				demo_t = 0.0
		1:
			m._face_target()
			if demo_t > 2.5:
				_shot("ui_cockpit")
				m.cam_mode = 1
				m._apply_view()
				demo_phase = 2
				demo_t = 0.0
		2:
			m.ship.set_speed = m.ship.max_speed.z
			m.ship.input_thrust.z = 1.0
			if demo_t > 3.0:
				_shot("ui_chase")
				# the full-screen HUD mode screens (#35): engineering, then
				# the starmap, one settled shot each
				m.ship.input_thrust.z = 0.0
				m.ship.set_speed = 0.0
				m.hud._menu_open("hud_menu_eng")
				demo_phase = 21
				demo_t = 0.0
		21:
			if demo_t > 1.5:
				_shot("ui_hud_engineering")
				m.hud.screen = ""
				m.hud._menu_open("hud_menu_map")
				demo_phase = 22
				demo_t = 0.0
		22:
			if demo_t > 1.5:
				_shot("ui_hud_starmap")
				m.hud.screen = ""
				# teleport to Lucrecia's Base and dock for the interior shot
				m.ship.velocity = Vector3.ZERO
				for a in m.ai_ships:
					a.queue_free()
				m.ai_ships.clear()
				m.target_ai = null
				for o in m.objects:
					if str(o["name"]) == "Lucrecia's Base":
						m.px = o["x"] + 2000.0
						m.py = o["y"]
						m.pz = o["z"]
				m._try_dock()
				demo_phase = 3
				demo_t = 0.0
		3:
			var bays := [Vector3(0, -110, -527), Vector3(-60, -160, -527),
				Vector3(0, -160, -700)]
			if demo_t > 1.5 and _mc_shot < 3:
				_shot("ui_base_%d" % _mc_shot)
				_mc_shot += 1
				if _mc_shot < 3:
					m.base_root.position = -(bays[_mc_shot] as Vector3)
				demo_t = 1.0
			elif _mc_shot >= 3:
				print("UICHECK done, docked=", m.docked_at)
				get_tree().quit()

# --- Lucrecia's Base ----------------------------------------------------------
#
# Drives the whole go-home system and asserts on it: the contact-list gate (not
# found -> not on the list), the found-base flag, the AUTOSKIP from >200 km with
# a dock order, the docking cutscene, the interior, the diorama the manager picks
# per screen, and the 30-second cut to the next room. Everything it checks comes
# out of ibacktobase.pog and [icSPPlayerBaseScreen] in the shipped defaults.ini;
# see base_interior.gd.

var _base_fail := 0
var _base_shot := 0
var _door_shot := false
var _room := 0
var _pending := false
var _hull0 := 0.0

func _bc(name: String, ok: bool, note := "") -> void:
	if not ok:
		_base_fail += 1
	print("BASECHECK %-34s %s%s" % [name, "PASS" if ok else "FAIL",
		"" if note.is_empty() else "  (%s)" % note])

func _base_rec() -> Dictionary:
	return m.base_iface.base_rec()

func _basecheck(_delta: float) -> void:
	var bi: BaseInterior = m.base_iface
	match demo_phase:
		0:
			if demo_t < 0.5:
				return
			m.menu.launched = true
			m.menu.close()
			# Fly home in the tug -- the ship you get AT Lucrecia's Base and the
			# one back-to-base is used in from act 1 on. (The bare act-0 command
			# section has an EMPTY heatsink mount-point socket -- comsec.ini
			# template[3] is filled from inventory in the real game -- so parked
			# under power it overheats; that is a fitting limitation in
			# ship_systems, not the docking path, and it is out of this task's
			# scope. The tug is prefitted and has its heatsink.)
			m._fit_player("sims/ships/player/tug.ini",
				"data/avatars/avatars/tug_hull/setup_prefitted.gltf")
			_hull0 = m.hull
			# 1. the contact-list gate. Fresh act 0: g_act0_found_base is 0, so
			#    iBackToBase is disabled and the base is off sensors.
			_bc("act 0: base not yet found", not bi.found())
			_bc("act 0: base off the contact list",
				not _contact_has_base(), "sensor_hidden")
			_bc("base system is Hoffer's Wake",
				bi.base_system() == "hoffers_wake", bi.base_system())
			# 2. find it (what iact0mission10 does on completion), and park 400 km
			#    out -- past the 200 km split -- so the base is inside sensor
			#    range of the contact list and the AUTOSKIP is the path in.
			m.pog_rt.std.globals["g_act0_found_base"] = 1
			bi.apply_visibility()
			var rec := _base_rec()
			m.px = float(rec["x"]) + 4.0e5
			m.py = float(rec["y"])
			m.pz = float(rec["z"])
			m.ship.global_position = Vector3.ZERO
			m.ship.velocity = Vector3.ZERO
			_bc("found: base now on the contact list", _contact_has_base())
			# 3. order a dock on the base. The detector should confirm for 10 s
			#    and then skip us home.
			for i in m.objects.size():
				if str(m.objects[i]["name"]) == BaseInterior.BASE_NAME:
					m.target_idx = i
					m.target_ai = null
			m._set_autopilot(3)
			_bc("dock order on the base at 400 km",
				bi._dock_ordered() and bi.base_pos().length() > BaseInterior.NEAR_RANGE)
			demo_phase = 1
			demo_t = 0.0
		1:
			# the autopilot would fly us in; freeze it so the range stays > 200 km
			# and only the detector can act
			m.ship.velocity = Vector3.ZERO
			m.ship.set_speed = 0.0
			# the detector polls every 2.1 s, then counts down 10 s of sanity
			# checks before it fires
			if bi.cut == 0 and demo_t < BaseInterior.POLL \
					+ float(BaseInterior.CONFIRM_SECONDS) + 3.0:
				return
			if bi.cut == 0:
				_bc("autoskip armed", false,
					"detector never confirmed (blocked=%s)" % bi._blocked())
				demo_phase = 4
				return
			if bi.cut == 1:
				_bc("AUTOSKIP fired", true,
					"%.0f m from base" % bi.base_pos().length())
				_bc("autoskip standoff = PlaceRelativeTo(3000,2000,15000)",
					absf(bi.base_pos().length()
						- BaseInterior.SKIP_STANDOFF.length()) < 1500.0,
					"%.0f m" % bi.base_pos().length())
				demo_phase = 2
				demo_t = 0.0
		2:
			# let the cutscene run: fly-by -> approach -> framing -> interior
			if not m._headless() and _base_shot == 0 and bi.cut == 1 \
					and demo_t > 2.0:
				_shot("base_autoskip")
				_base_shot = 1
			if not m._headless() and _base_shot == 1 and bi.cut == 2 \
					and demo_t > 1.0:
				_shot("base_approach")
				_base_shot = 2
			# the doors: catch the frame they are part-open (channel 0.3..0.9)
			if not m._headless() and not _door_shot and bi.cut == 2 \
					and bi._door > 0.3 and bi._door < 0.95:
				_shot("base_doors_opening")
				_door_shot = true
			# `inside` is set the moment the cutscene ends, but the SHUTDOWN
			# movie (YoungCalShutdown in act 0) plays before the interior comes
			# up -- `open` is the interior itself
			if bi.open:
				_bc("docking cutscene -> inside the base", true)
				_bc("docked_at set", m.docked_at == BaseInterior.BASE_NAME)
				# The cutscene flies the ship THROUGH the hull and parks it in
				# the bay: DockingCutscene calls sim.SetCollision(player, 0).
				# Without that we rammed the station at 300 m/s and blew up.
				_bc("survived the dock (no hull collision)",
					m.hull >= _hull0 - 0.5,
					"hull %.0f -> %.0f" % [_hull0, m.hull])
				# the bay doors are an avatar channel, not an animation we play:
				# sim.AvatarSetChannel(base, "door", 1) opens them, and the
				# cutscene shuts them again once the ship is inside
				_bc("bay doors driven by the `door` channel",
					not bi._door_nodes.is_empty() and bi._door_want == 0.0,
					"%d door nulls, channel now %.2f"
						% [bi._door_nodes.size(), bi._door])
				_bc("diorama 0 (MAIN BAY) up", bi.diorama == 0, bi.room_name())
				# gui.SetScreen("icSPPlayerBaseScreen") -> the overlay manager
				# raises its hosted menu, icSPBaseScreen, on top of itself
				# (iwar2 @ 0x10024cca), and ibasegui.SPBaseScreen builds it.
				var cur := str(m.pog_rt.native(
					"gui.currentscreenclassname", []))
				_bc("base menu raised (icSPBaseScreen)",
					cur == "icSPBaseScreen", cur)
				demo_phase = 3
				demo_t = 0.0
		3:
			if demo_t < 1.5:
				return
			if not m._headless() and _base_shot < 3:
				_shot("base_interior")
				_base_shot = 3
			var bui: PogUi = m.pog_rt.ui
			var sui: BaseScreens = bui.screen_ui
			_bc("base menu has controls",
				bui.visible_screen() != null
					and not bui.visible_screen().windows.is_empty(),
				"windows=%d drawn=%s size=%s" % [
					bui.visible_screen().windows.size()
						if bui.visible_screen() != null else -1,
					"no renderer" if sui == null else str(sui.visible),
					"-" if sui == null else str(sui.size)])
			# 4. the screens the manager hosts, and the diorama each one picks.
			#    With g_show_dioramas clear -- the whole campaign -- the loader
			#    only ever loads diorama 0 (iwar2 @ 0x10024b95), so the interior
			#    is the MAIN BAY and nothing else. iactthree sets the global at
			#    the very end of act 3, and only then do the other four rooms
			#    exist.
			bi.next_diorama()
			_bc("campaign: no other rooms (g_show_dioramas clear)",
				bi.diorama == 0, bi.room_name())
			m.pog_rt.std.globals["g_show_dioramas"] = 1
			var want := {"icSPHangarScreen": 3, "icSPInboxScreen": 1,
				"icSPComputerTradingScreen": 2, "icSPStatisticsScreen": 4}
			var ok := true
			for scr in want:
				m.pog_rt.native("gui.setscreen", ["icSPPlayerBaseScreen"])
				m.pog_rt.native("gui.overlayscreen", [scr])
				bi.set_diorama(bi._screen_diorama())
				if bi.diorama != int(want[scr]):
					ok = false
					print("   ", scr, " -> diorama ", bi.diorama,
						", expected ", want[scr])
			_bc("screen -> diorama map (ctor 0x100243b7)", ok)
			if not m._headless() and _base_shot < 4:
				_shot("base_diorama_%d" % bi.diorama)
				_base_shot = 4
			# 5. the 30-second cut to the next room
			m.pog_rt.native("gui.setscreen", ["icSPPlayerBaseScreen"])
			var was := bi.diorama
			bi._dio_t = 0.001
			bi._interior_process(0.01)
			_bc("diorama_delay cuts to the next room", bi.diorama != was,
				"%d -> %d" % [was, bi.diorama])
			_bc("fritz flash after the cut",
				bi.fritz_alpha() > 0.0 and bi.fritz_alpha() <= 1.0,
				"alpha %.2f" % bi.fritz_alpha())
			# 6. the light channels. g_base_lights_on is 0 from
			#    iStartSystem.StartupNewGame and is only set when Clay brings the
			#    base's power up (iPrelude.BaseOnlineHandler, "ok the systems are
			#    online") -- so a fresh act 0 base runs on EMERGENCY lighting,
			#    and the manager switches baselights_emergency on and
			#    baselights_normal off (iwar2 @ 0x10024d35).
			_bc("emergency lighting before the base is online",
				not bi._gflag(BaseInterior.LIGHTS_GLOBAL))
			m.pog_rt.std.globals["g_base_lights_on"] = 1
			bi.diorama = -1
			bi.set_diorama(0)
			_room = 0
			demo_phase = 5
			demo_t = 0.0
		5:  # a tour of the five rooms, one screenshot each (one per frame, or
			# the viewport hands back the same texture five times)
			if demo_t < 0.7:
				return
			if not m._headless():
				_shot("base_room_%d_%s" % [_room,
					bi.room_name().to_lower().replace(" ", "_")])
			_room += 1
			if _room >= BaseInterior.DIORAMAS.size():
				_bc("all five dioramas load and render", true)
				_room = 0
				demo_phase = 6
				demo_t = 0.0
				return
			bi.next_diorama()
			_bc("room %d = %s" % [bi.diorama, bi.room_name()],
				bi.diorama == _room
					and bi.room_name() == str(
						BaseInterior.DIORAMAS[_room]["name"]))
			demo_t = 0.0
		6:  # the screens the base menu leads to: the hangar (choose your ship),
			# the inbox (email) and the manifest (cargo) -- each on its own
			# diorama, each built by the original ibasegui code
			if demo_t < 0.7:
				return
			var tour: Array = ["icSPHangarScreen", "icSPInboxScreen",
				"icSPManifestScreen"]
			if _pending:
				# raised last pass, so it is on screen now
				if not m._headless():
					_shot("base_screen_%s" % str(tour[_room]).to_snake_case())
					_bc_shady_sane(str(tour[_room]))
				_pending = false
				_room += 1
				demo_t = 0.0
				return
			if _room >= tour.size():
				demo_phase = 7
				demo_t = 0.0
				return
			var want_scr: String = str(tour[_room])
			m.pog_rt.native("gui.setscreen", ["icSPPlayerBaseScreen"])
			m.pog_rt.native("gui.overlayscreen", [want_scr])
			bi._interior_process(0.01)
			var raised: bool = str(m.pog_rt.native(
				"gui.currentscreenclassname", [])) == want_scr
			_bc("%s on the %s diorama" % [want_scr, bi.room_name()],
				raised and bi.diorama
					== int(BaseInterior.SCREEN_DIORAMA[want_scr]))
			_pending = true
			demo_t = 0.0
		7:  # the SAVE GAME slot screen, raised the way SPBasePDAScreen_OnSave
			# does: gui.OverlayScreen("icSPPDASaveScreen") (ipdagui.pog:352-356;
			# builder SPPDASaveScreen, ipdagui.pog:435)
			if demo_t < 0.7:
				return
			if not _pending:
				m.pog_rt.native("gui.setscreen", ["icSPPlayerBaseScreen"])
				m.pog_rt.native("gui.overlayscreen", ["icSPPDASaveScreen"])
				_pending = true
				demo_t = 0.0
				return
			var bui7: PogUi = m.pog_rt.ui
			if not m._headless():
				_shot("pda_save_screen")
			var sscr: PogUi.PogScreen = bui7.visible_screen()
			var boxes := 0
			if sscr != null:
				for w in sscr.windows:
					if w.kind == "editbox":
						boxes += 1
			_bc("save screen: an edit box per slot (14, iwar2 @ 0xb6c80)",
				sscr != null and sscr.name == "icSPPDASaveScreen"
					and boxes == PogGameApi.SAVE_SLOTS,
				"editboxes=%d" % boxes)
			# Select on the focused slot starts an edit and runs the begin
			# override, SPPDASaveScreen_SetDefaultName, which proposes
			# "ACT n  <realtime>" (ipdagui.pog:459-479, FcEditBox @ 0x7c4b0)
			var sui7: BaseScreens = bui7.screen_ui
			var box: PogUi.PogWindow = sui7._current() if sui7 != null else null
			var before := ""
			if box != null and box.kind == "editbox":
				before = PogStd._s(box.value)
				bui7.activate(box)
			_bc("save screen: edit proposes the default name",
				box != null and box.editing
					and PogStd._s(box.value).begins_with("ACT "),
				"-" if box == null else PogStd._s(box.value))
			# Escape while editing restores the pre-edit text and leaves the
			# screen up (FcEditBox::OnControlFocusCancel @ 0x7c530)
			if box != null and box.editing:
				bui7.cancel()
			_bc("save screen: edit cancel restores the slot text",
				box != null and not box.editing
					and PogStd._s(box.value) == before
					and bui7.visible_screen() == sscr,
				"-" if box == null else PogStd._s(box.value))
			bui7.dispatch("iPDAGUI.SPPDASaveScreen_OnBackButton")
			_pending = false
			demo_phase = 8
			demo_t = 0.0
		8:  # the LOAD GAME screen: a row per occupied slot (local_11058,
			# ipdagui.pog:618-630), each loading BY NAME (SPPDALoadScreen_OnLoad
			# -> igame.LoadGame(title), ipdagui.pog:605-610)
			if demo_t < 0.7:
				return
			if not _pending:
				m.pog_rt.native("gui.overlayscreen", ["icSPPDALoadScreen"])
				_pending = true
				demo_t = 0.0
				return
			var bui8: PogUi = m.pog_rt.ui
			if not m._headless():
				_shot("pda_load_screen")
			var lscr: PogUi.PogScreen = bui8.visible_screen()
			var rows := 0
			if lscr != null:
				for w in lscr.windows:
					if w.kind == "button" \
							and w.on_press == "iPDAGUI.SPPDALoadScreen_OnLoad":
						rows += 1
			_bc("load screen: a row per occupied save",
				lscr != null and lscr.name == "icSPPDALoadScreen"
					and rows == m.save_slots().size(),
				"rows=%d saves=%d" % [rows, m.save_slots().size()])
			bui8.dispatch("iPDAGUI.SPPDALoadScreen_OnBackButton")
			_pending = false
			demo_phase = 4
			demo_t = 0.0
		4:
			# the inbox's mail bodies: iemail.SendEmail's html:/text/... URLs must
			# resolve to the extracted pages (tools/iw2/html_text.py) -- this was
			# silently empty until the text/act_*/**.html tree was extracted
			var will: String = m.pog_rt.ui._resource_text(
				"html:/text/act_0/act0_master_lucreciamail_1")
			_bc("Lucrecia's mail body resolves (html:/text/...)",
				will.contains("Last Will and Testament"),
				"%d chars" % will.length())
			# gui.SetWindowStateIcons(win, 6, 6, 5) -- igui.MakeInverseButtonIconic
			# (igui.pog:630). Selected and neutral share their three-slice art, so
			# this glyph is the ONLY thing that reads as "selected"; the eIcon ->
			# rect table is icCustomisableWindowAvatar's, written @ 0x1010b480 with
			# m_icon_size (16,16) @ 0x1010b4f0.
			var iui: PogUi = m.pog_rt.ui
			var iwin := PogUi.PogWindow.new()
			iui._set_state_icons(null, [iwin, 6, 6, 5])
			_bc("iconic button: eIcon 6/6/5 -> the alpha-map rects",
				iwin.icons.get("neutral") == Rect2(34, 0, 16, 16)
					and iwin.icons.get("focused") == Rect2(34, 0, 16, 16)
					and iwin.icons.get("selected") == Rect2(34, 17, 16, 16),
				"neutral=%s selected=%s"
					% [iwin.icons.get("neutral"), iwin.icons.get("selected")])
			# The front-end items menu.gd routes at its OWN handlers' screens
			# (SPMainPDAScreen_On{Options,Movies,Mod}, ipdagui.pog:130-162).
			# Enabling a button that raises an empty screen would be worse than
			# leaving it greyed, so each builder must actually produce windows.
			# icSPPDADeviceScreen is in here because it is the one that consumes
			# ioptions.CreateGraphics{Device,Resolution}OptionButtons.
			for pda: String in ["icSPPDAOptionsScreen", "icMoviesScreen",
					"icModScreen", "icSPPDADeviceScreen"]:
				m.pog_rt.native("gui.overlayscreen", [pda])
				var pscr: PogUi.PogScreen = m.pog_rt.ui.visible_screen()
				_bc("front end: %s builds" % pda,
					pscr != null and pscr.name == pda
						and not pscr.windows.is_empty(),
					"windows=%d" % (pscr.windows.size() if pscr != null else -1))
				m.pog_rt.native("gui.popscreen", [])
			# The SOUND screen's four volume rows (#37) must be SLIDERS with
			# real, distinct, descending-laid-out geometry -- the first cut
			# shipped rows with x/y/w/h all zero, every label overprinting one
			# point, and no check noticed because nothing asserted a rect.
			m.pog_rt.native("gui.overlayscreen", ["icSPPDASoundScreen"])
			var snd: PogUi.PogScreen = m.pog_rt.ui.visible_screen()
			var sliders: Array = []
			if snd != null:
				for w2: PogUi.PogWindow in snd.windows:
					if w2.kind == "slider":
						sliders.append(w2)
			var geom_ok := sliders.size() == 4
			var last_y := -1
			for w3: PogUi.PogWindow in sliders:
				if w3.w <= 0 or w3.h <= 0 or w3.y <= last_y:
					geom_ok = false
				last_y = w3.y
			_bc("front end: icSPPDASoundScreen slider rows", geom_ok,
				"sliders=%d ys=%s" % [sliders.size(),
					str(sliders.map(func(w4: PogUi.PogWindow) -> int:
						return w4.y))])
			m.pog_rt.native("gui.popscreen", [])
			# The remaster-only debug picker: PogUi.debug_screen composes an
			# overlay out of the PDA screens' own igui recipe (no POG builder
			# exists for it) -- one inverse button per row inside the fancy
			# border -- and a row click must land in the GDScript callable.
			var picked: Array = []
			var dscr: PogUi.PogScreen = m.pog_rt.ui.debug_screen(
				"CHECK", ["ROW A", "ROW B", "ROW C"],
				func(i: int) -> void: picked.append(i))
			var dbtn: PogUi.PogWindow = null
			var drows := 0
			for dw: PogUi.PogWindow in dscr.windows:
				if dw.on_press_cb.is_valid():
					drows += 1
					if dw.title == "ROW B":
						dbtn = dw
			if dbtn != null:
				m.pog_rt.ui.activate(dbtn)
			_bc("debug picker: PDA-recipe overlay + row pick",
				dscr.pop_on_cancel and drows == 3 and picked == [1]
					and dscr.windows.size() > 6,
				"windows=%d rows=%d picked=%s"
					% [dscr.windows.size(), drows, str(picked)])
			m.pog_rt.native("gui.popscreen", [])
			print("BASECHECK: ", "PASS" if _base_fail == 0 else "FAIL",
				" -- ", _base_fail, " failure(s)")
			get_tree().quit(0 if _base_fail == 0 else 1)

func _contact_has_base() -> bool:
	for e in m.contact_list():
		if str(e.get("name", "")) == BaseInterior.BASE_NAME:
			return true
	return false

func _screen_stack() -> Array:
	var out: Array = []
	for s in m.pog_ui.screens:
		out.append(s.name)
		for o in s.over:
			out.append(o.name)
	return out

