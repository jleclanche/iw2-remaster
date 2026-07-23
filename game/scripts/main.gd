extends "main_flow.gd"
# The Badlands, playable: flight, LDS, capsule jumps between all systems,
# targeting, weapons, damage, AI traffic + hostiles, docking, dynamic music,
# original SFX, animated stations, planets/stars rendered as impostors.
# See docs/mechanics.md for the IW2 semantics being recreated.
#
# main.gd is the top of a linear extends chain (scheme in main_state.gd).
# This file: boot (_ready), input, and the per-frame drive (_physics_process).

func _ready() -> void:
	# every harness flag is a member var named after its --flag; a new probe
	# is one string here plus its `var` declaration
	var args := OS.get_cmdline_user_args()
	demo = "--demo" in args
	for f: String in ["motioncheck", "jumpcheck", "uicheck", "mechcheck",
			"mechslow", "campcheck", "newgamecheck", "newgametest",
			"geogcheck", "basecheck", "commshot", "muzzleshot",
			"contactcheck", "srgbprobe", "sunshot", "sungallery",
			"fireprobe"]:
		var on: bool = ("--" + f) in args
		set(f, on)
		if on:
			demo = true
	use_pog = "--pog" in args
	# The ported GDScript runtime is the DEFAULT campaign path; --pog runs the
	# same campaign on the bytecode VM (the verification oracle). The legacy
	# hand-authored driver is retired, so anything that is not --pog is --port.
	# (--port is still accepted, now redundant.)
	use_port = not use_pog
	for arg in args:
		# the menu's DEBUG START, reachable from the command line:
		# --debugship=heavy_corvette_prefitted
		if str(arg).begins_with("--debugship="):
			_debug_request = "sims/ships/player/%s.ini" \
					% str(arg).get_slice("=", 1)
	if demo:
		checks = CheckRunner.new()
		checks.m = self
		add_child(checks)
	audio = AudioManager.new()
	add_child(audio)
	comms = Comms.new()
	comms.main = self
	add_child(comms)
	mission = Mission.new()
	mission.main = self
	add_child(mission)
	_build_pog()
	base_iface = BaseInterior.new()
	base_iface.main = self
	add_child(base_iface)
	if _debug_request != "":
		player_ship_ini = _debug_request
		debug_all_weapons = true
		# no act is running in a debug start: -1 is what
		# iJafsScript.JafsFunctionalityAvailable reads as "free flight, Jafs
		# enabled" (it then creates g_jafs_menu_option_enabled itself).
		# BaseInterior.found() also passes on -1 (only acts 0/1 need the
		# found-base flags), which puts Lucrecia's Base on sensors and makes
		# it dockable. The VM path and the ported runtime keep separate
		# globals by design -- and base_interior reads pog_rt's first -- so
		# seed BOTH.
		pog_std.globals["g_current_act"] = -1
		if pog_rt != null and pog_rt.std != null:
			pog_rt.std.globals["g_current_act"] = -1
		# the commodity table normally comes up with the act; a debug start
		# runs the original initialiser itself so pods have cargo to carry
		pog.start("icargoscript", "Initialise")
		_debug_seed_economy()
	_build_environment()
	_spawn_player()
	# the two iiSimField singletons, made once per game like the original's
	# "Loading asteroids" / "Loading debris" load stages; the belt records and
	# the scripts' icFieldSphere regions switch them on (docs/fields.md)
	fields = Fields.new()
	fields.main = self
	add_child(fields)
	if _debug_request != "":
		_load_system(_debug_system,
				_debug_at if _debug_at != "" \
				else (START_NAME if _debug_system == START_SYSTEM else ""))
	else:
		_load_system(START_SYSTEM, START_NAME)
	hud = Hud.new()
	hud.main = self
	var cl := CanvasLayer.new()
	cl.add_child(hud)
	jump_fade = ColorRect.new()
	jump_fade.color = Color(1, 1, 1, 0)
	jump_fade.set_anchors_preset(Control.PRESET_FULL_RECT)
	jump_fade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cl.add_child(jump_fade)
	menu = Menu.new()
	menu.main = self
	# above everything: the HUD's menu elements carry z 2 so they cover the
	# flight HUD (flux.ini puts them at 17..21, the reticle at 11), and the
	# pause screen has to cover them in turn.
	menu.z_index = 10
	cl.add_child(menu)
	# MFD comm-portrait video sits inside the HUD's targeting panel
	comms.portrait.position = Vector2(18, 52)
	hud.add_child(comms.portrait)
	# UI keeps running while Esc pauses the simulation underneath
	cl.process_mode = Node.PROCESS_MODE_ALWAYS
	audio.process_mode = Node.PROCESS_MODE_ALWAYS  # GUI sounds while paused
	add_child(cl)
	# There used to be a --pogplay branch here that skipped the front end and
	# started the campaign directly. It checked BEFORE the statics -- and the
	# command line outlives every reload_current_scene -- so under --pogplay
	# any in-session reload (DEBUG START, pause-menu NEW GAME) restarted the
	# campaign instead. The front end works; the flag is gone.
	if _debug_request != "":
		_debug_request = ""
		menu.visible = false
		menu.launched = true
		# every entry into flight that bypasses menu.close() must eat the
		# cursor itself, or mouse steering hits the screen edge
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		hud.log_msg("DEBUG START: %s" % player_ship_ini.get_file().get_basename()
				.to_upper())
	elif _restarting:
		# NEW GAME from the pause menu: the scene was reloaded to get a clean
		# slate, so pick the campaign straight back up -- but DEFERRED, one idle
		# past _ready. The front-end START NEW GAME works because it calls
		# start_campaign from a menu callback, on a live frame; calling it inline
		# here, mid-_ready of a freshly reloaded scene, starts the prelude movie
		# before the scene has rendered a frame and the VideoStreamPlayer never
		# plays, so its finished callback -- which is what starts the mission --
		# never fires. That is "NEW GAME drops me into empty flight".
		_restarting = false
		menu.visible = false
		start_campaign.call_deferred()
	elif not demo:
		# A plain launch boots into the FRONT END (the original's
		# icSPMainPDAScreen), not into flight -- the old straight-to-Tug boot
		# was a development leftover. The world behind stays whatever
		# START_SYSTEM built; INSTANT ACTION / START NEW GAME take it from
		# here. Check harnesses (demo) keep the direct boot they drive.
		menu.open()

func _exit_tree() -> void:
	ExplosionFx.release_cache()
	Input.set_custom_mouse_cursor(null)
	# The glTF prototypes are parsed scenes we keep to duplicate from; they are
	# deliberately not in the tree, so nothing else will ever free them.
	for proto in _gltf_cache.values():
		if proto != null and is_instance_valid(proto):
			proto.free()
	_gltf_cache.clear()

func _unhandled_input(event: InputEvent) -> void:
	# Escape means "get me out of whatever is in front of me", in that order:
	# a movie, then an in-engine cutscene, then (in menu.gd) the pause screen.
	# Space and Return skip a movie only.
	var key := -1
	if event is InputEventKey and event.pressed and not event.echo:
		key = event.physical_keycode

	if movie != null:  # Game.MovieSkip: Space / Escape / Return
		if key in [KEY_SPACE, KEY_ESCAPE, KEY_ENTER]:
			skip_movie()
			get_viewport().set_input_as_handled()
		return

	# A cutscene is staged: Escape skips it rather than pausing. The scripts have
	# their own abort for this -- icutsceneutilities.HandleAbort polls
	# g_cutscene_skip and halts the cutscene task -- so this is a real skip, not
	# us tearing the scene down behind their back.
	if key == KEY_ESCAPE and in_cutscene():
		skip_cutscene()
		get_viewport().set_input_as_handled()
		return

	# The base's docking cutscene is skippable the same way. In the original it
	# is a cutscene like any other -- ibacktobase runs it inside
	# icutsceneutilities.HandleAbort, which polls g_cutscene_skip and halts the
	# task -- and the abort still leaves you docked, because the detector places
	# the ship inside the base *after* HandleAbort returns.
	if key == KEY_ESCAPE and base_iface != null and base_iface.cut > 0:
		base_iface.skip_cutscene()
		get_viewport().set_input_as_handled()
		return

	if menu != null and menu.visible:
		return  # the menu handles its own input (it runs while paused)
	# The mouse stands in for the joystick yoke -- the original binds no mouse
	# axis to the pilot at all (mouse is the director's, in configs/default.ini),
	# so this is ours. It carries the yoke's two real behaviours: the zoom factor
	# divides it, and RollYawToggleHold swaps its X channel from yaw to roll.
	# ...but NOT while a menu page owns the pointer: on the starmap the mouse
	# is the map cursor, and its right button is ZOOM OUT
	var page_up: bool = hud != null and hud.screen != ""
	if event is InputEventMouseMotion and not demo and docked_at == "" \
			and not page_up:
		var sh: ShipFlight = piloted()  # the remote vessel while linked (#1)
		var mx: float = event.relative.x * 0.003 / zoom_factor
		var my: float = event.relative.y * 0.003 / zoom_factor
		if roll_yaw_swap:
			sh.input_rotate.z = clampf(sh.input_rotate.z - mx, -1, 1)
		else:
			sh.input_rotate.y = clampf(sh.input_rotate.y - mx, -1, 1)
		sh.input_rotate.x = clampf(sh.input_rotate.x - my, -1, 1)
	# RollYawToggleHold: held, not toggled (flux.ini toggle_roll_yaw = 0). The
	# original's only binding is joystick button 2; on a mouse yoke the right
	# button is its natural home.
	if event is InputEventMouseButton \
			and event.button_index == MOUSE_BUTTON_RIGHT and not page_up:
		roll_yaw_swap = event.pressed
	# conversation choices: number keys answer comms questions
	if comms != null and comms.choosing() and event is InputEventKey \
			and event.pressed and not event.echo \
			and event.physical_keycode >= KEY_1 \
			and event.physical_keycode <= KEY_9:
		comms.choose(event.physical_keycode - KEY_1)
		return
	# icPlayerPilot::DistributePower 0x100b00d0 -- the four power keys, which
	# configs/default.ini binds to SHIFT + the arrow keys. The corners the engine
	# picks agree with the triangle's geometry exactly: LEFT is the top-left node
	# (offensive), RIGHT the top-right (defensive), DOWN the bottom apex (drive),
	# UP the centre. Each one is a straight SetTRIPosition + an icLog event, and
	# the four event strings are in data/text/log_addendum.csv.
	if event is InputEventKey and event.pressed and not event.echo \
			and event.shift_pressed and sys != null:
		var corner: Array = []
		var msg := ""
		match event.physical_keycode:
			KEY_LEFT:    # 0x17 PowerToOffensive  -> event 0x43 hud_tri_offensive
				corner = [0.0, 1.0, 0.0]
				msg = "TRI: FULL POWER TO WEAPONS"
			KEY_RIGHT:   # 0x18 PowerToDefensive  -> event 0x44 hud_tri_defensive
				corner = [0.0, 0.0, 1.0]
				msg = "TRI: FULL POWER TO SHIELDS"
			KEY_DOWN:    # 0x19 PowerToDrive      -> event 0x45 hud_tri_propulsion
				corner = [1.0, 0.0, 0.0]
				msg = "TRI: FULL POWER TO ENGINES"
			KEY_UP:      # 0x1a BalancePower      -> event 0x46 hud_tri_centre
				corner = [1.0 / 3.0, 1.0 / 3.0, 1.0 / 3.0]
				msg = "TRI: POWER BALANCED"
		if not corner.is_empty():
			sys.set_tri_position(corner[0], corner[1], corner[2])
			hud.log_msg(msg)
			get_viewport().set_input_as_handled()
			return
	# original IW2 bindings (configs/default.ini + keyboard_only.ini)
	if event is InputEventKey and event.pressed and not event.echo:
		match event.physical_keycode:
			BIND_FREE_TOGGLE:  # icPlayerPilot.FreeToggle
				free_toggle = not free_toggle
				audio.play("audio/gui/mechanical_confirm.wav", -10.0)
				hud.log_msg("FLIGHT ASSIST %s" % ("OFF" if free_toggle else "ON"))
			BIND_TOGGLE_LDS:  # ToggleLDS
				_toggle_lds()
			BIND_UNDOCK:  # Undock -- SHIFT+U (plain U is vertical strafe)
				if event.shift_pressed:
					_undock()
			KEY_Z:  # ToggleZoom -- moved to Shift+Z now that plain Z/X roll.
				# Still gated on hardware, see _enable_zoom.
				if event.shift_pressed:
					_enable_zoom(not zoomed)
			KEY_TAB:  # CycleContactDown / CycleContactUp (remaster default:
				# Tab / Shift+Tab; the original shipped comma / period in
				# configs/default.ini)
				_cycle_contact(-1 if event.shift_pressed else 1)
				note_key_press(KEY_TAB, func() -> void:
					_cycle_contact(-1 if Input.is_key_pressed(KEY_SHIFT)
							else 1))
			KEY_HOME:
				_target_contact_index(0)
			KEY_END:
				_target_contact_index(9999)
			BIND_TARGET_NEAREST:  # TargetNearestEnemy
				_target_nearest_enemy()
			BIND_TARGET_DIRECTION:  # TargetNearestShipToDirection
				_target_nearest_to_direction()
			BIND_SUBTARGET:  # icPlayerPilot.SubTarget (configs/default.ini: Keyboard, Y)
				_cycle_subtarget()
			BIND_CYCLE_ENEMY:  # CycleEnemy -- SHIFT+E (plain E is yaw-right)
				if event.shift_pressed:
					_cycle_enemy()
			BIND_TARGET_AGGRESSOR:  # TargetLastAggressor -- SHIFT+Q (plain Q is yaw-left)
				if event.shift_pressed \
						and last_aggressor != null and is_instance_valid(last_aggressor):
					target_ai = last_aggressor
					target_idx = -1
					audio.play("audio/hud/target_changed.wav", -10.0)
			KEY_BACKSPACE:  # icPlayerPilot.NextSecondaryWeapon (+ Joy3)
				_cycle_secondary()
			KEY_ENTER, KEY_KP_ENTER:  # icPlayerPilot.NextPrimaryWeapon (+ Joy4)
				_next_primary_weapon()
			KEY_BRACKETRIGHT:  # icPlayerPilot.NextWeapon -> CycleWeapon
				# 0x100b0b70 = GetNextWeapon(channel 1, any=true): the SAME list,
				# but it ignores the channel and takes the next non-empty entry
				# of either kind. We keep the two lists apart, so: try the
				# primaries, and if there is nowhere else to go, fall to the
				# secondaries.
				if not _next_primary_weapon(false):
					_cycle_secondary()
			BIND_AGGRESSOR_SHIELD:  # the aggressor shield. Its Fire (0x1002f6a0)
				# just raises the active flag; it refuses unless the bank is
				# FULL, then holds for `duration` seconds while it drains.
				_fire_aggressor()
			BIND_LDSI_FIRE:  # icPlayerPilot.LDSIQuickFire -- SHIFT+I (plain I is
				# vertical strafe). The LDSi magazine fires on its own trigger,
				# bypassing weapon selection (the dedicated LDSI path in
				# AttemptToActivateWeapon 0x1003ccb0 via pilot+0x82).
				if event.shift_pressed:
					fire_ldsi()
			KEY_F5:  # AutopilotOff
				_set_autopilot(0)
			KEY_F6:  # AutopilotApproach
				_set_autopilot(1)
			KEY_F7:  # AutopilotFormate
				_set_autopilot(2)
			KEY_F8:  # AutopilotDock
				_set_autopilot(3)
			KEY_F9:  # AutopilotMatchVelocity
				_set_autopilot(4)
			# icDirector camera keys. Each cycles WITHIN its group -- F1 steps
			# cockpit -> no cockpit -> arcade, which is the "way to turn off the
			# cockpit view" the original had.
			KEY_F1:  # InternalCamera
				_set_camera(0)
				hud.log_msg("CAMERA: %s" % cam_name().replace("_", " ").to_upper())
			KEY_F2:  # TacticalCamera
				_set_camera(1)
			KEY_F3:  # ExternalCamera
				_set_camera(2)
			KEY_F4:  # DropCamera
				_set_camera(3)
			KEY_F12:  # fcGraphicsDeviceD3D.TakeScreenShot
				var img := get_viewport().get_texture().get_image()
				img.save_png(_base().path_join("data/screenshots/screenshot_%d.png"
					% (Time.get_ticks_msec() / 1000)))
			BIND_JUMP:  # capsule jump at an L-point -- SHIFT+J (plain J is pitch-up)
				if event.shift_pressed:
					_try_jump()
			BIND_CYCLE_ROUTE:  # SHIFT+K (plain K is pitch-down)
				if event.shift_pressed:
					_cycle_route()
			KEY_H:  # dev: spawn hostile (demo/check builds only -- a stray H
				# in the campaign summoned a marauder out of nowhere)
				if demo:
					spawn_hostile(ship.global_position +
						-ship.global_transform.basis.z * 3000.0
						+ Vector3(400, 200, 0))

# FcInputMapper auto-repeats every held mapped button: after m_initial_delay
# (0.5 s, flux.dll @ 0x101445e8) the binding re-fires every m_repeat_period
# (0.1 s, @ 0x101445e4) -- FUN_100e6a80's state machine, state 3 arms the
# initial delay, state 1 counts down and re-arms with the period. ONE engine,
# driven off Input polling rather than Godot's OS-rate echo events; whichever
# dispatch surface consumed the press hands it the ACTION to refire (flight
# bindings here, the HUD screens' keys in hud.gd). Which actions consume
# repeats is per-handler in the engine; one-shots (dock, jump, autopilot,
# screenshot) stay press-only.
const KEY_REPEAT_DELAY := 0.5   # FcInputMapper::m_initial_delay
const KEY_REPEAT_PERIOD := 0.1  # FcInputMapper::m_repeat_period
var _repeat_key := -1
var _repeat_t := 0.0
var _repeat_fire := Callable()

func note_key_press(key: int, fire: Callable) -> void:
	_repeat_key = key
	_repeat_t = KEY_REPEAT_DELAY
	_repeat_fire = fire

func _tick_key_repeat(delta: float) -> void:
	if _repeat_key < 0:
		return
	if not Input.is_physical_key_pressed(_repeat_key) \
			or (menu != null and menu.visible) or docked_at != "" \
			or not _repeat_fire.is_valid():
		_repeat_key = -1
		return
	_repeat_t -= delta
	while _repeat_t <= 0.0:
		_repeat_t += KEY_REPEAT_PERIOD
		_repeat_fire.call()

func _physics_process(delta: float) -> void:
	# reload_current_scene() does not stop the outgoing scene immediately: this
	# node keeps ticking for a frame after it has left the tree, and everything
	# that reaches for get_tree() or a global transform then fails. NEW GAME is
	# the only thing that does this.
	if not is_inside_tree():
		return
	_tick_key_repeat(delta)
	fire_lock = maxf(0.0, fire_lock - delta)
	disrupt_time = maxf(0.0, disrupt_time - delta)
	weapon_disrupt_time = maxf(0.0, weapon_disrupt_time - delta)
	if weapon_disrupt_time <= 0.0:
		weapon_disrupt_full = false
	# icMagazine::Simulate 0x10038210: the refire clock is efficiency * dt
	if missiles != null:
		missiles._tick_mags(player_mags, delta)
	if not _shockwaves.is_empty():
		_update_shockwaves(delta)
	_update_tow()
	# The TRI's DRIVE axis, which is a property of the SHIP and not of the yoke:
	# icShip::Simulate (0x10070f00) multiplies the engine force by
	# TRIWeight(ship+0x294) and the thruster force by TRIWeight(ship+0x290) --
	# both eType-0 subsims, so both carry the same drive weight -- just before
	# handing them to iiThrusterSim::ComputeForceAndTorque. It is gated on
	# `AIPilot(this) == NULL`, so only the player feels it. (The two other flags
	# in that condition, ship+0x270 != 0 and ship+0x148 == 0, are UNKNOWN.)
	# Force x w at constant mass IS acceleration x w.
	if sys != null:
		var wd: float = sys.tri_weight(ShipSystems.TRI_DRIVE)
		ship.max_accel = base_max_accel * wd
		ship.turn_accel = base_turn_accel * wd
	if use_pog:
		_pog_boot_process()
		pog_api.director_process(delta)   # cutscene camera, while one is staged
	elif use_port and pog_rt != null and pog_rt.gameapi != null:
		pog_rt.gameapi.director_process(delta)
	if demo:
		checks.step(delta)
		# a check may have torn the scene down mid-frame (NEW GAME); the rest of
		# this tick would then run against a node that has left the tree
		if not is_inside_tree():
			return
	elif in_cutscene():
		# The scripts fly the ship during a cutscene (the launch sequence takes
		# the yoke off you and flies you out of the tube), so the player does
		# not. Without this you sit in the cockpit flying around while a
		# cutscene you cannot see runs to completion behind you.
		ship.input_rotate = Vector3.ZERO
		ship.input_thrust = Vector3.ZERO
	elif jump_state >= 3:
		# icCapsuleSpace::MakeEffect @ 0x10042f80 zeroes the player yoke and
		# takes the control lock (+0x31c) for the whole effect; PerformJumps
		# case 7 releases it
		ship.input_rotate = Vector3.ZERO
		ship.input_thrust = Vector3.ZERO
	elif base_iface != null and base_iface.cut > 0:
		# the base's own docking cutscene flies the ship; the player does not
		ship.input_rotate = Vector3.ZERO
		ship.input_thrust = Vector3.ZERO
	elif docked_at == "" and not menu.visible and movie == null:
		_player_control(delta)
		if ap_mode > 0:
			_autopilot_process(delta)
	# iBackToBase's Detector, and the interior's diorama montage
	if base_iface != null:
		base_iface.process(delta)
	if lds_state > 0:
		_lds_process(delta)
	if jump_state > 0:
		_jump_process(delta)
	# LDS cruise / capsule runs own the velocity vector: the flight
	# computer's per-axis speed caps must not clip them back to drive speeds
	# the base's docking cutscene flies the ship on rails, like the scripts'
	# sim.SetVelocityLocalToSim: the flight model must not brake it back
	ship.drive_override = lds_state == 2 or jump_state >= 2 \
		or (base_iface != null and base_iface.cut > 0)
	if docked_at != "":
		ship.velocity = Vector3.ZERO
		ship.set_speed = 0.0
		ship.input_thrust = Vector3.ZERO
		ship.input_rotate = Vector3.ZERO
	# Docked, the ship's systems are off: the engine parks the sim and stops
	# simulating it (icShip::Simulate early-outs while the ship is on a dock
	# port). Leaving them running cooked the hull -- the bare command section has
	# a powerplant but no heatsink, so its heat integrates straight up to the
	# damage threshold and kills you while you sit in the hangar. The docking
	# cutscene is the same: the ship is not under power.
	if sys != null and docked_at == "" \
			and (base_iface == null or base_iface.cut == 0):
		# icSun::Think 0x1006ab90 / icPlanet::Think 0x10068380: every body in
		# the active system radiates onto the PLAYER's external heat store.
		# BUT a sim only Thinks while FcWorld::CullSims (flux 0x100c61d0) deems
		# it interesting: centre within the world's interesting range, which
		# icSolarSystem's ctor (0x1004b180) sets to 2 * far_clip
		# ([icSolarSystem] far_clip = 200000 -> 400 km). No map body's centre
		# is ever that close (you would be inside it), so in the shipped game
		# this heat NEVER fires -- the formula is real but dormant. Keep the
		# gate literal instead of deleting the code.
		for o in objects:
			var cat: String = o["category"]
			if cat == "star" or cat == "body":
				var r: float = o["radius"]
				if r > 0.0:
					var d_centre := Vector3(px - o["x"], py - o["y"],
							pz - o["z"]).length()
					if d_centre < SIM_INTERESTING_RANGE:
						sys.add_body_heat(d_centre - r, r, cat == "star",
								delta)
		# icAggressorShield::Simulate 0x1002f52a drops the shield the moment the
		# LDS drive reaches state 2 (engaged) -- icShip+0x25c, the icLDSDrive.
		sys.in_lds = lds_state == 2
		sys.simulate(delta)
	# sim.SetCollision(player, x), DERIVED from state each frame rather than
	# set/reset in the dock handlers: a set-only flag stuck OFF whenever a
	# path cleared docked_at without running _launch() (undocking out of a
	# LOADED docked save did exactly that), and the player flew straight
	# through the base hull. Off during any movie, the dock cutscene and the
	# interior -- the same window the original brackets with SetCollision 0/1
	# (istartsystem.pog:72..86).
	player_collision = movie == null and docked_at == "" \
			and (base_iface == null \
			or (not base_iface.inside and base_iface.cut == 0))
	_contact_sound_cd = maxf(0.0, _contact_sound_cd - delta)
	_collisions()
	# the field Thinks run PRE-integration on the last tick's focus, like the
	# original (icClient::Tick @ 0x100b39c0 runs them before FcClient::Tick
	# moves the world) -- the post-integration fold below is what strands
	# LDS-speed respawns astern (docs/fields.md)
	fields.tick(delta)


## Placed by CameraTail, not from _physics_process above: everything here needs
## the ship AFTER it integrates. See camera_tail.gd.
func late_physics(delta: float) -> void:
	# The world fold is POST-integration: FcClient::Tick integrates the world
	# and THEN rebases the render focus (FcWorld+0x38; the per-frame rebase is
	# GraphicsDeltaFocus, FcWorld+0x50..0x58), so the original renders the
	# focus at the origin every frame. Folding before integration left the
	# rendered ship a full tick's travel from the origin -- 5e8 m at the LDS
	# ceiling (lds_class1.ini max_speed=3e10 / 60 Hz), where a float32 ULP is
	# ~32 m: the ship/camera/world relation quantized per frame (the issue #51
	# on-screen teleporting), and every px/py/pz-anchored draw sat one tick
	# astern of the hull.
	_fold_motion()
	_stream_objects()
	_update_grid()
	_update_ldsi_fence()
	_update_nebula_fog()
	_chase_camera(delta)
	if sky_anchor != null:
		sky_anchor.global_position = cam.global_position
	_update_star_streaks()

## The pilot's yoke, as the original wires it.
##
## Bindings come from the game's OWN configs (`configs/default.ini` for a
## joystick, `configs/keyboard_only.ini` for the rest of us); the yoke itself is
## `icPlayerPilot::HandleLinearMessage` (iwar2 @ 0x100ae2b0). See docs/controls.md.
##
##   Yaw    NumPad4 / NumPad6      Pitch  NumPad2 / NumPad8   Roll  NumPad1 / NumPad3
##   Strafe A / D (LateralX), W / S (LateralZ)   -- NOT steering; IW2 flies on the numpad
##   Throttle  = / -  (ThrottleDelta): a FRACTION of top speed, +-1/3 per second
##   FreeHold LeftCtrl / NumPad5   FreeToggle N   Fire Space
##
## Two things fall out of the binary that a keyboard player never sees:
##   - `RollYawToggleHold` (joystick button 2) SWAPS yaw and roll on the yoke,
##     and `flux.ini [icPlayerPilot] toggle_roll_yaw = 0` says it is a hold, not a
##     permanent swap. We give the mouse yoke the same modifier.
##   - the zoom factor DIVIDES yaw and pitch (not roll), which is what makes a
##     zoomed shot aimable.
func _player_control(delta: float) -> void:
	# a cutscene ghost holds the pilot (iCutSceneUtilities.
	# EnablePlayerAutopilot): the yoke drives NOTHING -- the script flies
	# the hull through AI orders until the pilot is installed back
	if pilot_parked:
		return
	# The yoke drives the PILOTED ship: the own hull normally, the linked
	# vessel during a remote link (#1) -- the original installs the player
	# PILOT on the remote sim and this is that pilot's control path.
	var sh: ShipFlight = piloted()
	# ThrottleDelta is a rate on the throttle FRACTION: `throttle += v * dt *
	# 0.3333` clamped to [0,1] (the 1/3 is the float at 0x10119454). A full sweep
	# is three seconds, and the throttle is a fraction of max speed, not m/s.
	var dv := sh.max_speed.z * delta / 3.0
	sh.set_speed = clampf(sh.set_speed
		+ (_key(BIND_THROTTLE_UP) + _key(KEY_KP_ADD)) * dv
		- (_key(BIND_THROTTLE_DOWN) + _key(KEY_KP_SUBTRACT)) * dv,
		0.0, sh.max_speed.z)
	# icPlayerPilot::Think (0x100ad8f0, at 0x100ae191) re-tests the zoom gate every
	# frame and drops the zoom the moment the hardware that granted it goes away.
	if zoomed and not _zoom_allowed().is_empty():
		_enable_zoom(false)
	# Think ramps the zoom at max_zoom_factor / zoom_time toward the target
	# (0x100ae1cd). Note the asymmetry, straight out of EnableZoom: zooming IN
	# ramps, but zooming OUT is instantaneous -- 0x100b0f20 snaps BOTH the target
	# (+0xa4) and the live factor (+0xa0) to 1.0. _enable_zoom does the snap.
	zoom_factor = move_toward(zoom_factor, ZOOM_MAX if zoomed else 1.0,
		ZOOM_MAX / ZOOM_TIME * delta)
	var base_fov: float = FOV_INTERNAL if cam_mode == 0 and cam_view <= 1 \
		else FOV_EXTERNAL
	cam.fov = base_fov / zoom_factor
	if ap_mode == 0:
		# THRUSTERS, not steering. Fore-aft (W/S) and lateral (A/D) are the
		# shipped keyboard bindings; vertical strafe (U/I) is a remaster add --
		# the original left LateralY joystick-only (JoyYAxis + ALT). See the
		# keybind table in main_state for every key referenced here.
		sh.input_thrust.z = _key(BIND_THRUST_FWD) - _key(BIND_THRUST_BACK)
		sh.input_thrust.x = _key(BIND_THRUST_RIGHT) - _key(BIND_THRUST_LEFT)
		sh.input_thrust.y = _key(BIND_STRAFE_UP) - _key(BIND_STRAFE_DOWN)
		# keyboard_only.ini: NumPad6 = +Yaw, NumPad8 = +Pitch, NumPad3 = +Roll,
		# and the `inverse` twins are the negative half of each axis. +Pitch is
		# NOSE DOWN: the joystick binding is `JoyYAxis, inverse`, and an inverted
		# DirectInput Y is positive when the stick is pushed forward. Q/E (yaw)
		# and J/K (pitch, J = nose up) are remaster primaries alongside the NumPad
		# aliases; each letter groups with the NumPad key of matching sign.
		var yaw := _key(KEY_KP_6) + _key(BIND_YAW_RIGHT) \
			- _key(KEY_KP_4) - _key(BIND_YAW_LEFT)
		var pitch := _key(KEY_KP_8) + _key(BIND_PITCH_DOWN) \
			- _key(KEY_KP_2) - _key(BIND_PITCH_UP)
		# Roll: keyboard_only.ini binds NumPad1 / NumPad3; the remaster adds
		# Z / X as the primary roll keys for a mouse+keyboard pilot -- Z rolls
		# left, X rolls right. Gated on SHIFT being up because ToggleZoom moved
		# to Shift+Z (see the key handler), so a zoom press does not also roll.
		var roll := _key(KEY_KP_3) - _key(KEY_KP_1)
		if not Input.is_physical_key_pressed(KEY_SHIFT):
			roll += _key(BIND_ROLL_RIGHT) - _key(BIND_ROLL_LEFT)
		# RollYawToggleHold swaps the yaw and roll channels
		if roll_yaw_swap:
			var t := yaw
			yaw = roll
			roll = t
		# Godot's local axes: +x pitches the nose UP, +y yaws LEFT, +z rolls LEFT
		if absf(yaw) > 0.0:
			sh.input_rotate.y = -yaw / zoom_factor
		if absf(pitch) > 0.0:
			sh.input_rotate.x = -pitch / zoom_factor
		# Roll decays on release like yaw/pitch instead of hard-zeroing, so the
		# right-button roll/yaw swap (mouse X -> input_rotate.z) is no longer
		# clobbered to 0 every frame when no roll key is held.
		if absf(roll) > 0.0:
			sh.input_rotate.z = -roll
		sh.input_rotate.x = move_toward(sh.input_rotate.x, 0.0, delta * 1.5)
		sh.input_rotate.y = move_toward(sh.input_rotate.y, 0.0, delta * 1.5)
		sh.input_rotate.z = move_toward(sh.input_rotate.z, 0.0, delta * 1.5)
	# free flight: N toggles, LeftCtrl / NumPad5 holds (FreeToggle/FreeHold)
	sh.assist = not (free_toggle or Input.is_physical_key_pressed(KEY_CTRL)
		or Input.is_physical_key_pressed(KEY_KP_5))
	# a raised menu page (starmap etc.) owns the mouse: its clicks pick map
	# nodes, they must not reach the trigger
	var mouse_fire: bool = Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT) \
			and (hud == null or hud.screen == "")
	if (Input.is_key_pressed(KEY_SPACE) or mouse_fire) \
			and lds_state == 0 and fire_lock <= 0.0:
		# CurrentWeaponFire fires the SELECTED weapon (iiWeapon::
		# AttemptToActivateWeapon 0x1003ccb0 only lets the magazine whose id
		# matches the pilot's current selection through). Holding the trigger
		# keeps firing each refire_delay: icMagazine ctor 0x10037fe0 defaults
		# salvo_fire (+0xbc) on.
		if secondary_idx >= 0:
			_fire_secondary()
		else:
			weapons.fire()
