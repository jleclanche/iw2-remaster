extends Node3D
# The Badlands, playable: flight, LDS, capsule jumps between all systems,
# targeting, weapons, damage, AI traffic + hostiles, docking, dynamic music,
# original SFX, animated stations, planets/stars rendered as impostors.
# See docs/mechanics.md for the IW2 semantics being recreated.

const START_SYSTEM := "hoffers_wake"
const START_NAME := "Alexander L-Point"
const STREAM_IN := 4.0e5
const STREAM_OUT := 5.0e5
const IMPOSTOR_DIST := 2.5e5  # bodies/stars drawn at capped range, scaled down
const LDSI_RADIUS := 2.5e4

const LDS_MAX := 3.0e10
const LDS_RAMP := 5.0
const LDS_SPOOL := 3.0
const LDS_BASE := 2000.0
const LDS_DROPOUT_SPEED := 1000.0  # icLDSDrive::BreakShipOutOfLDS (decompiled)

const FOV_INTERNAL := 63.0  # flux.ini icInternalCamera field_of_view 1.1 rad
const FOV_EXTERNAL := 68.75  # flux.ini cameras field_of_view 1.2 rad
const DOCK_RANGE := 4000.0
const JUMP_RANGE := 3.0e4  # must be this close to an L-point to capsule jump

# icCapsuleSpace jump choreography (evidence log: docs/capsule.md)
const CAPSULE_FLASH := 1.5        # player entry-blank hold, _DAT_1011a268
                                  # (icCapsuleEntryBlankAvatar, FUN_100bf870)
const CAPSULE_TIME_MIN := 8.0     # tunnel time roll, _DAT_10117b28
const CAPSULE_TIME_MAX := 12.0    # _DAT_10119ec4 (PerformJumps @ 0x10040cc0)
const CAPSULE_SHIP_SPEED := 500.0  # SendShipDownTunnel @ 0x10043740
const CAPSULE_EXIT_MIN := 500.0   # flux.ini [icCapsuleSpace] min_exit_speed
const CAPSULE_EXIT_MAX := 2000.0  # flux.ini [icCapsuleSpace] max_exit_speed
const CAPSULE_EXIT_RUN := 3000.0  # DoCapsuleJump @ 0x10042730: v=sqrt(2*a*3000)
const CAPSULE_ACCEL_SCALE := 0.64  # player accel scaled 0.8^2 (_DAT_1011959c)
const CAPSULE_CUT_TIME := 1.0     # flux.ini [icDirector] min_cut_time
const CAPSULE_CAM_RANGE := 4.0    # camera 24 Update @ 0x100dc160: radius * 4
                                  # (0x101190b4)
const CAPSULE_CAM_FOV := 40.1     # FUN_100dc080: half-angle 0.35 rad
                                  # (_DAT_1011d378), 2*0.35 rad = 40.1 deg
const SHIP_HIT_RADIUS := 60.0

# planets.ini [Planets]: the renderer's own config, read by icPlanetProperties
const ATMOSPHERE_HEIGHT := 1.1  # atmosphere_height
# icPlanetAvatar (0x100cdc50) sizes each of a gas giant's rings with
# FcRandom::Float(1.75, 2.44) x the body radius (2.44 = _DAT_1011d07c)
const RING_MIN := 1.75
const RING_MAX := 2.44
const MAX_RINGS := 8  # max_rings
# PLACEHOLDER: icPlanetAvatar's draw is not disassembled, so a ring's WIDTH is
# not recovered. We give each band an even share of the 1.75..2.44 span so that
# a full set of 8 tiles it. The radii and the count are from the data; this is
# not.
const RING_WIDTH := (RING_MAX - RING_MIN) / MAX_RINGS

var ship: ShipFlight
var ship_model: Node3D
var cockpit: Node3D
var comms: Comms
var mission: Mission
var movie: VideoStreamPlayer
var cam: Camera3D
var hud: Hud
var menu: Menu
var weapons: PbcWeapons
var missiles: Missiles
var fields: Fields  # the ambient asteroid/debris field singletons (fields.gd)
var audio: AudioManager
var sun: DirectionalLight3D
var space_fx: SpaceFx
var ldsi_mesh: ImmediateMesh
var ldsi_mat: StandardMaterial3D
var sky_anchor: Node3D
var sky_mat: ShaderMaterial
var env_ref: Environment
# icDirector's camera GROUPS, built in its constructor (iwar2 @ 0x100d5e20) and
# cycled by icDirector::OnMessage (0x100d6920): pressing a camera key when you
# are outside its group jumps to the group's first camera; pressing it again
# steps to the next camera IN that group, wrapping. The groups, by their
# icDirector::eCamera indices (the name table is at 0x101621e0):
#
#   F1 internal : cam_internal_cockpit(1), cam_internal_no_cockpit(2), cam_arcade(5)
#   F2 tactical : cam_tactical(8), cam_inverse_tactical(9)
#   F3 external : cam_external(6), cam_target_external(7)
#   F4 drop     : cam_drop(11)
#
# So F1 is what takes the cockpit away, exactly as remembered, and it lands on
# the arcade camera on the third press. (cam_internal_no_hud(3) exists but is
# only in the developers' DevCycleAllCameras group, which ships unbound.)
const CAM_GROUPS := [["cockpit", "no_cockpit", "arcade"],
	["tactical", "inverse_tactical"], ["external", "target_external"], ["drop"]]
var cam_mode := 0  # group: 0 internal (F1), 1 tactical, 2 external, 3 drop
var cam_view := 0  # index within the group
var cockpit_frame := true  # derived: the internal group's cockpit dressing
var drop_cam_pos := Vector3.ZERO
var zoomed := false
# icPlayerPilot: max_zoom_factor = 10, zoom_time = 0.5 (flux.ini). The zoom ramps
# at max/time per second and DIVIDES the yaw and pitch yoke, which is what makes
# a zoomed-in shot aimable (icPlayerPilot::HandleLinearMessage, 0x100ae2b0 --
# cases 0/1/2 scale by 1/zoom, and ROLL is deliberately left unscaled).
const ZOOM_MAX := 10.0
const ZOOM_TIME := 0.5
var zoom_factor := 1.0
# The TRI's DRIVE axis scales the ship's engine force and thruster torque
# (icShip::Simulate 0x10070f00, at 0x1007105d / 0x10071088 -- player only, gated
# on `AIPilot(this) == NULL`). Force x w with a constant mass IS acceleration
# x w, so we hold the INI's accelerations here and re-derive them each frame.
var base_max_accel := Vector3(100, 100, 150)
var base_turn_accel := Vector3(30, 30, 30)
var free_toggle := false
var roll_yaw_swap := false  # icPlayerPilot.RollYawToggleHold
var ap_mode := 0  # 0 off, 1 approach, 2 formate, 3 dock, 4 match velocity
var _bounds_cache: Dictionary = {}
var last_aggressor: AiShip = null
var kill_count := 0  # hostiles destroyed (missions watch this)
var demo := false
var checks: CheckRunner

# The POG virtual machine and its native packages. With --pog the campaign is
# driven by the original mission bytecode instead of the hand-authored steps in
# mission.gd; without it, mission.gd still runs, so both paths stay testable.
var pog: PogVM
var pog_std: PogStd
var pog_facs: PogFactions
var pog_world: PogWorld
var pog_api: PogGameApi
var pog_econ: PogEconomy
var pog_ents: PogEntities
var pog_ui: PogUi
var pog_misc: PogMisc
var pog_boot: Array = []
var pog_boot_task: PogVM.PogTask = null
var use_pog := false

# The ported campaign: the same missions, decompiled to GDScript and running
# natively (game/scripts/pog/gen/). --port runs those; --pog runs the same
# missions on the bytecode VM, which is what we diff them against.
var pog_rt: PogRuntime
var use_port := false

var px := 0.0
var py := 0.0
var pz := 0.0
var system_stem := ""
var system_name := ""
var objects: Array = []
var ai_ships: Array = []
var target_idx := -1
var target_ai: AiShip = null
var lds_state := 0
var lds_timer := 0.0
var lds_speed := 0.0
# The capsule jump. States 1-2 approximate the queue/charge + acceleration
# run the original's autopilot flies (icAITarget::GetNewCapsuleJumpStage @
# 0x1005c5af, stages approach/queue/charge/accelerate at AverageJumpSpeed =
# (100 + 2500) / 2, 0x1015d224/28); states 3-5 are icCapsuleSpace's own sJump
# machine (PerformJumps @ 0x10040cc0 cases 4/5/6: entry blank flash ->
# capsule space -> DoCapsuleJump teleport under the exit flash).
var jump_state := 0  # 0 idle, 1 spool, 2 accel run, 3 entry flash,
                     # 4 capsule space, 5 exit flash
var jump_timer := 0.0
var jump_duration := 0.0  # tunnel time, rolled rand[8,12] s on entry
var jump_dest := ""
var jump_sel := 0
var jump_fade: ColorRect
var capsule: CapsuleFx
var last_entry: Dictionary = {}  # the L-point _load_system arrived at
var _flick := PackedFloat32Array()  # entry/exit blank flicker keys
var _cap_cut_t := 0.0  # capsule camera: time to next cut
var _cap_cam_dir := Vector3.RIGHT  # current random viewpoint (ship-local)
var _cap_prev_bg := 0  # Environment background mode to restore
# The hull is owned by the subsim model when one is fitted; these stay as plain
# properties so the HUD and the ported scripts (which set game.hull on load and
# on respawn) keep working against a single number.
var _hull := 1000.0
var _hull_max := 1000.0
var hull: float:
	get:
		return sys.hull if sys != null else _hull
	set(value):
		if sys == null:
			_hull = value
			return
		sys.hull = value
		sys.killed = value <= 0.0
var hull_max: float:
	get:
		return sys.hull_max if sys != null else _hull_max
	set(value):
		if sys == null:
			_hull_max = value
		else:
			sys.hull_max = value
var sys: ShipSystems  # the player's subsims, armour and hull (docs/combat.md)
var docked_at := ""
var ship_stats: Dictionary = {}
var weapon_name := "L-PBC / R-PBC"  # HUD weapon-panel title
var eye := Vector3(-1.19, -13.85, -40.05)  # pilot eye: tug.lws crew null
var fire_lock := 0.0  # brief inhibit after menus/movies eat a click
var disrupt_time := 0.0  # LDSi weapon hit: drive locked out (iship.Disrupt)
# --- the missile system's player-side state (missiles.gd) -------------------
var player_mags: Array = []      # the fitted icMissileMagazine/icCM magazines
var secondary_idx := -1          # NextSecondaryWeapon ring; -1 = primary
var secondary_name := "NONE"     # HUD weapon-panel line (hud.gd owner wires it)
# icPlayerPilot's incoming-missile feed (OnIncomingMissile 0x100b0fc0): the
# HUD draws one pip per entry of the +0xa8 id list and reads the octagonal-
# norm nearest range at +0xb4. hud.gd owns the drawing; these mirror the two.
var incoming_missiles: Array = []
var nearest_missile_range := -1.0
# icShip::Disrupt on the player (disruptor/achillies warheads): weapons out
var weapon_disrupt_time := 0.0
var weapon_disrupt_full := false

var clock_start := 0  # ms tick when we last left port (the HUD clock)
var base_root: Node3D  # hangar interior while docked at an ordinary base
const BASE_BAY := Vector3(0, -110, -527)  # tug parking bay (glTF coords)
# Lucrecia's Base: the home base. Contact-list rules, the go-home dock, the
# docking cutscene, the AUTOSKIP and the interior all live in base_interior.gd.
var base_iface: BaseInterior

var motioncheck := false
var jumpcheck := false
var uicheck := false
var mechcheck := false
var campcheck := false
var newgamecheck := false
var geogcheck := false
var basecheck := false   # Lucrecia's Base: dock -> interior -> screens

func _ready() -> void:
	demo = "--demo" in OS.get_cmdline_user_args()
	motioncheck = "--motioncheck" in OS.get_cmdline_user_args()
	jumpcheck = "--jumpcheck" in OS.get_cmdline_user_args()
	uicheck = "--uicheck" in OS.get_cmdline_user_args()
	mechcheck = "--mechcheck" in OS.get_cmdline_user_args()
	campcheck = "--campcheck" in OS.get_cmdline_user_args()
	newgamecheck = "--newgamecheck" in OS.get_cmdline_user_args()
	geogcheck = "--geogcheck" in OS.get_cmdline_user_args()
	basecheck = "--basecheck" in OS.get_cmdline_user_args()
	use_pog = "--pog" in OS.get_cmdline_user_args()
	use_port = "--port" in OS.get_cmdline_user_args()
	if motioncheck or jumpcheck or uicheck or mechcheck or campcheck or geogcheck \
			or newgamecheck or basecheck:
		demo = true
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
	_build_environment()
	_spawn_player()
	# the two iiSimField singletons, made once per game like the original's
	# "Loading asteroids" / "Loading debris" load stages; the belt records and
	# the scripts' icFieldSphere regions switch them on (docs/fields.md)
	fields = Fields.new()
	fields.main = self
	add_child(fields)
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
	if (use_pog or use_port) and "--pogplay" in OS.get_cmdline_user_args():
		# Straight into the campaign, no front end.
		menu.visible = false
		start_campaign()
	elif _restarting:
		# NEW GAME from the pause menu: the scene was reloaded to get a clean
		# slate, so pick the campaign straight back up.
		_restarting = false
		menu.visible = false
		start_campaign()

## Walk istartsystem's boot stages, each one starting only after the previous
## has run to completion. The engine drove these from C++; we drive them from
## here, which keeps the ordering the scripts were written against.
func _pog_boot_next() -> void:
	if pog_boot.is_empty():
		return
	var stage: String = pog_boot.pop_front()
	var parts := stage.split(".", true, 1)
	pog_boot_task = pog.start(parts[0], parts[1])

func _pog_boot_process() -> void:
	if pog_boot.is_empty() and pog_boot_task == null:
		return
	if pog_boot_task != null and not pog_boot_task.halted:
		return
	pog_boot_task = null
	if not pog_boot.is_empty():
		_pog_boot_next()

## Is an in-engine cutscene staged right now? idirector.Begin()/End() bracket
## one, and the launch sequence at the start of the campaign is one.
func in_cutscene() -> bool:
	if use_port and pog_rt != null and pog_rt.gameapi != null:
		return pog_rt.gameapi.director_busy
	if use_pog and pog_api != null:
		return pog_api.director_busy
	return false

## Ask the running cutscene to abort, the way the scripts themselves do.
func skip_cutscene() -> void:
	var std: PogStd = pog_rt.std if use_port else pog_std
	if std != null:
		std.globals["g_cutscene_skip"] = 1

## The campaign, running as ported GDScript. Same sequence the engine drove.
##
## iprelude.Main runs *before* FinalSetup, not after: it is what creates the
## player's ship (iutilities.CreatePlayer), and FinalSetup immediately reaches
## for it (iship.FindPlayerShip, sets its death script, checks its hull type).
## FinalSetup then suspends every task that already exists and runs the launch
## cutscene alone -- which is how the prelude movie is kept from racing it.
func _port_boot() -> void:
	var ss: PogScript = pog_rt.script("istartsystem")
	if ss == null:
		return
	await ss.startup_new_game()
	await ss.startup_session()
	await ss.startup_space()
	await ss.startup_system()
	var prelude: PogScript = pog_rt.script("iprelude")
	if prelude != null:
		await prelude.main()
	await ss.final_setup()

func _build_pog() -> void:
	# The POG virtual machine, running the game's original mission bytecode.
	# The natives are the only part we supply; everything above them -- the
	# missions themselves, the conversations, the AI orders -- is the original
	# compiled code out of resource.zip. See game/scripts/pog/vm.gd.
	# --pogtrace echoes the missions' own debug.Print* lines: the original
	# scripts narrate themselves, which is the fastest way to see what a
	# mission thinks it is doing.
	PogVM.trace_debug = "--pogtrace" in OS.get_cmdline_user_args()
	pog = PogVM.new()
	add_child(pog)
	pog_std = PogStd.new()
	pog_std.register(pog)
	pog_facs = PogFactions.new()
	pog_facs.register(pog)
	pog_world = PogWorld.new()
	pog_world.factions = pog_facs
	pog_world.std = pog_std   # a sim's name is a localisation key; it needs the tables
	pog_world.register(pog)
	pog_world.bind_game(self)
	pog_api = PogGameApi.new()
	pog_api.register(pog, pog_world)
	pog_api.bind_game(self)
	pog_econ = PogEconomy.new()
	pog_econ.register(pog, pog_world)
	pog_econ.bind_game(self)
	pog_ents = PogEntities.new()
	pog_ents.register(pog, pog_world)
	pog_ents.bind_game(self)
	pog_ui = PogUi.new()
	pog_ui.register(pog, pog_world)
	pog_ui.bind_game(self)
	pog_misc = PogMisc.new()
	pog_misc.register(pog, pog_world)
	pog_misc.bind_game(self)
	# The ported campaign gets its own instances of the same native modules, so
	# the two paths never share state and can be diffed against each other.
	pog_rt = PogRuntime.new()
	add_child(pog_rt)
	pog_rt.bind_game(self)

func _exit_tree() -> void:
	ExplosionFx.release_cache()
	Input.set_custom_mouse_cursor(null)
	# The glTF prototypes are parsed scenes we keep to duplicate from; they are
	# deliberately not in the tree, so nothing else will ever free them.
	for proto in _gltf_cache.values():
		if proto != null and is_instance_valid(proto):
			proto.free()
	_gltf_cache.clear()

func _fit_player(ini_path: String, avatar: String) -> void:
	# swap the player's hull: the campaign opens in the bare command
	# section; the tug comes later at Lucrecia's Base
	if ship_model != null:
		ship_model.queue_free()
	if ship.fx != null:
		ship.fx.queue_free()
		ship.fx = null
	ship_model = _load_gltf(avatar)
	ship.add_child(ship_model)
	ShipEffects.attach(ship, ship_model)
	var stats: Array = _load_json("data/json/ships.json")
	for rec in stats:
		if rec.get("path", "") == ini_path:
			ship_stats = rec["properties"]
			ship.load_stats(ship_stats)
	base_max_accel = ship.max_accel
	base_turn_accel = ship.turn_accel
	_fit_systems(ini_path)
	weapons.set_muzzles(ship_model)
	# icWeaponLink: the loadout builds the fire groups when the hull is fitted
	# (icLoadout::CreateWeaponLinks 0x10096940), so this is the same moment
	weapons.build_groups(sys)
	if "comsec" in ini_path:
		# single light PBC on the nose hardpoint (comsec.ini + comsec.lws:
		# nose_hardpoint at LW (1.625,-1.5,10.625); light_pbc.ini refire 0.8)
		weapons.refire = 0.8
		weapons.bolt_spec = PbcWeapons.LIGHT_PBC_BOLT
		weapons.muzzle_fallback = [Vector3(1.625, -1.5, -14.0)]
		weapon_name = "LIGHT PBC"
		eye = Vector3(-1.125, 0.425, -12.975)  # comsec.lws crew null
	else:
		# the tug's fitted PBCs (subsims/systems/player/pbc.ini: refire 0.7,
		# projectile sims/weapons/pbc_bolt)
		weapons.refire = 0.7
		weapons.bolt_spec = PbcWeapons.PBC_BOLT
		weapons.muzzle_fallback = PbcWeapons.MUZZLES
		weapon_name = "L-PBC / R-PBC"
		eye = Vector3(-1.19, -13.85, -40.05)  # tug.lws crew null
	_apply_view()

func _fit_systems(ini_path: String) -> void:
	# The player's hull, armour and subsim list, from the ship's own INI.
	#
	# sims/ships/player/tug.ini mounts empty *sockets* (subsims/mountpoints/*):
	# in the original the fitting screen fills them from the player's inventory,
	# which we have not ported. tug_prefitted.ini is the game's own already-
	# fitted tug -- same hull (1000 hp / 65 armour), and it is already the avatar
	# we render (setup_prefitted) -- so that is the record we fit from.
	var path := ini_path
	if path == "sims/ships/player/tug.ini":
		path = "sims/ships/player/tug_prefitted.ini"
	var fitted := ShipSystems.for_ship(path)
	if fitted.hull_max <= 0.0:
		sys = null
		hull_max = float(ship_stats.get("hit_points", 500))
		hull = hull_max
		player_mags = []
		_select_secondary(-1)
		return
	fitted.bind_model(ship_model)
	# iiShipSystem::TRIWeight (0x1003c170) is gated on IsPlayer: this ship, and
	# only this ship, feels the TRI. icPlayerPilot::CreateWorld calls
	# SetTRIPosition at 0x100b33d0, so a fresh world starts balanced.
	fitted.is_player = true
	fitted.set_tri_position(1.0 / 3.0, 1.0 / 3.0, 1.0 / 3.0)
	if GRANT_IMAGING_MODULE:
		fitted.programs |= ShipSystems.PROG_IMAGING
	sys = fitted
	# the fitted missile/countermeasure magazines (tug_prefitted.ini: seeker
	# x5, LDSi x4, decoy x8)
	player_mags = Missiles.mags_for(sys)
	_select_secondary(-1)

## NEW GAME while a game is already running. The POG runtime, its tasks, the
## mission runner and every native module's state are built once at boot, so
## simply calling start_campaign() again would stack a second campaign on top of
## the first. Reloading the scene is the only honest clean slate; `_restarting`
## survives it because a static outlives the node.
static var _restarting := false

func restart_campaign() -> void:
	# Halt the POG tasks BEFORE the scene goes: a task parked on process_frame
	# outlives the reload, resumes against a node that is no longer in the tree,
	# and reaches for a null SceneTree. (That is the freeze: iprelude's master
	# script awaiting a frame that now belongs to a dead scene.)
	if pog_rt != null:
		pog_rt.halt()
	_restarting = true
	get_tree().paused = false
	get_tree().reload_current_scene()

func start_campaign() -> void:
	# The pause menu needs to know a game is running, or Escape has nothing to
	# return to. --pogplay boots straight past the front end, so set it here
	# rather than in the menu item that usually would.
	if menu != null:
		menu.launched = true
	start_in_system(START_SYSTEM)
	_fit_player("sims/ships/player/comsec.ini",
		"data/avatars/avatars/command_section/setup.gltf")
	_setup_act0_scene()
	if use_port:
		_port_boot()
		return
	if use_pog:
		# Hand the campaign to the original bytecode, through the game's own
		# boot sequence rather than jumping straight into a mission.
		# istartsystem is the engine's bootstrap package: StartupNewGame sets up
		# what the missions assume already exists (the ship-name INI handle, the
		# mission tracker, the mission generator), then the session/space/system
		# stages bring the player into the world and start the act.
		# istartsystem's stages, then iprelude: nothing in the bytecode starts
		# the prologue, because the engine did it from C++, so we do. iprelude
		# plays the opening cinematic and then calls iact0mission10.Main itself.
		pog_boot = ["istartsystem.StartupNewGame", "istartsystem.StartupSession",
			"istartsystem.StartupSpace", "istartsystem.StartupSystem",
			"istartsystem.FinalSetup", "iprelude.Main"]
		_pog_boot_next()
		return
	# iact0mission10 bytecode: igame.PlayMovie("/movies/prelude")
	_play_movie("prelude", func() -> void:
		mission.start(Mission.act0()))

func _spawn_npc(dname: String, fac: String, typ: String, avatar: String,
		pos: Vector3, wps: Array) -> AiShip:
	var ai := AiShip.new()
	ai.main = self
	ai.display_name = dname
	ai.faction = fac
	ai.ctype = typ
	ai.avatar_path = avatar
	ai.setup({"hit_points": 600, "speed": [80, 80, 200],
		"acceleration": [30, 30, 50], "yaw_rate": 18, "pitch_rate": 18,
		"roll_rate": 18})
	var mdl := _load_gltf(avatar)
	if mdl != null:
		ai.add_child(mdl)
		ShipEffects.attach(ai, mdl)
	ai.position = pos
	for w in wps:
		ai.waypoints.append(w)
	add_child(ai)
	ai_ships.append(ai)
	return ai

func _setup_act0_scene() -> void:
	# extracted from the iprelude + iact0mission10 bytecode:
	# iutilities.CreatePlayer(comsec_prefitted, "Hoffer's Gap") — the player
	# wakes up AT Hoffer's Gap (the scrapyard rocks, avatars/hoffersgap);
	# the "Abandoned Hulk" is the base reactor station sim placed at
	# player + (3000, 4000, 5000) = 7071 m; junker traffic works the field
	for o in objects:
		match str(o["name"]):
			"Hoffer's Gap":
				# spawn 8 km out with the Gap dead ahead, like the original
				px = o["x"]
				py = o["y"]
				pz = o["z"] + 8000.0
				o["prop_collide"] = true
			"Hoffer's Gap Entertainment Complex", \
			"Hoffer's Gap Independent Trading Post":
				# dockable sub-locations of the same physical structure —
				# don't render more copies of the rocks
				o["avatar"] = ""
	objects.append({"name": "Abandoned Hulk", "category": "station",
		"x": px + 3000.0, "y": py + 4000.0, "z": pz - 5000.0, "radius": 120.0,
		"avatar": "avatars/reactor/setup.gltf",
		"faction": "", "type": "UTIL",
		"jumps": [], "colors": [], "node": null, "prop_collide": true})
	var scopo := _spawn_npc("Scopo", "INDPT", "UTIL",
		"data/avatars/avatars/utilityvessel/setup.gltf",
		Vector3(-600, 100, -3950),
		[Vector3(-600, 100, -3950), Vector3(2000, 300, -8000)])
	_spawn_npc("Marengo", "GOVMT", "TRANS",
		"data/avatars/avatars/freighter/setup.gltf",
		Vector3(9000, 1500, -16400),
		[Vector3(9000, 1500, -16400), Vector3(-14000, 800, -9000)])
	for cfg in [["Brick", 9000.0], ["De - Ex", 12000.0],
			["Swyddfa'r Post", 15000.0]]:
		var d2: float = cfg[1]
		_spawn_npc(str(cfg[0]), "INDPT", "TUG",
			"data/avatars/avatars/utilityvessel/setup.gltf",
			Vector3(d2, 200 + d2 * 0.02, -d2 * 0.6),
			[Vector3(d2, 0, -3000), Vector3(-2000, 400, -d2)])
	# the tutorial opens with the nearby tug already on target
	target_ai = scopo
	target_idx = -1

# Movies play one at a time. Several scripts can ask for one at once -- the
# launch cutscene and the mission's own opening both do -- and playing them on
# top of each other orphaned the first player, so its caller was never told its
# movie had ended and its script waited forever. They queue instead, and each
# caller's continuation fires when *its* movie finishes.
var _movie_queue: Array = []   # [[stem, then], ...]

func _play_movie(stem: String, then: Callable) -> void:
	var path := _base().path_join("data/movies/%s.ogv" % stem)
	if not FileAccess.file_exists(path) or _headless():
		then.call()
		return
	_movie_queue.append([stem, then])
	if movie == null:
		_next_movie()

func _next_movie() -> void:
	if _movie_queue.is_empty():
		_after_movies()
		return
	var job: Array = _movie_queue.pop_front()
	var then: Callable = job[1]
	movie = VideoStreamPlayer.new()
	var vs := VideoStreamTheora.new()
	vs.file = _base().path_join("data/movies/%s.ogv" % str(job[0]))
	movie.stream = vs
	movie.expand = true
	movie.set_anchors_preset(Control.PRESET_FULL_RECT)
	movie.finished.connect(func() -> void: _end_movie(then), CONNECT_ONE_SHOT)
	hud.get_parent().add_child(movie)
	movie.play()

func _end_movie(then: Callable) -> void:
	if movie != null:
		movie.queue_free()
		movie = null
	fire_lock = 0.4  # the skip keypress/click must not fire the PBC
	then.call()      # tell *this* movie's caller it is done
	_next_movie()

## Only once the last movie has played: handing the view back mid-sequence would
## flash the world between two cinematics.
func _after_movies() -> void:
	audio.music("ambient")
	if uicheck:
		menu.open()
	elif demo:
		menu.visible = false
		menu.launched = true
		cam_mode = 1
		_apply_view()
	elif menu.launched:
		menu.close()  # straight into flight after a campaign cinematic
	else:
		menu.open()   # MOVIES replay returns to the front end

## Skip the movie on screen. Only that one: the rest of the queue still plays,
## and a script waiting on a later movie must not be told its one has ended.
func skip_movie() -> void:
	if movie != null:
		movie.finished.emit()

func start_in_system(stem: String, at := "") -> void:
	# `at` names an entity to arrive beside (the system JSON's own name, e.g.
	# "Lucrecia's Base"); empty means the system's default entry point.
	lds_state = 0
	if hud != null:
		_jump_abort()
	jump_state = 0
	var entry: String = at
	if entry.is_empty() and stem == START_SYSTEM:
		entry = START_NAME
	_load_system(stem, entry)
	ship.velocity = Vector3.ZERO
	ship.set_speed = 0.0
	ap_mode = 0
	clock_start = Time.get_ticks_msec()

func _base() -> String:
	return ProjectSettings.globalize_path("res://").path_join("..")

func _load_json(rel: String) -> Variant:
	var f := FileAccess.open(_base().path_join(rel), FileAccess.READ)
	return null if f == null else JSON.parse_string(f.get_as_text())

# Parsed glTF scenes, kept as prototypes and duplicated per instance. The POG
# scripts build things like the Junkyard debris field out of hundreds of sims
# that share two or three models, and re-parsing the file for each one stalls
# the boot for minutes.
var _gltf_cache: Dictionary = {}

func _load_gltf(rel: String) -> Node3D:
	if _gltf_cache.has(rel):
		var proto: Node3D = _gltf_cache[rel]
		if proto == null:
			return null
		return _instance_gltf(proto.duplicate())
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	if doc.append_from_file(_base().path_join(rel), state) != OK:
		_gltf_cache[rel] = null
		return null
	var node := doc.generate_scene(state)
	_gltf_cache[rel] = node
	return _instance_gltf(node.duplicate())

func _instance_gltf(node: Node3D) -> Node3D:
	for ap in node.find_children("*", "AnimationPlayer", true, false):
		var player := ap as AnimationPlayer
		for anim_name in player.get_animation_list():
			player.get_animation(anim_name).loop_mode = Animation.LOOP_LINEAR
			player.play(anim_name)
	return node

func _build_environment() -> void:
	sun = DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-20, 60, 0)
	sun.light_energy = 1.4
	add_child(sun)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	sky.sky_material = _starfield_material()
	e.sky = sky
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.12, 0.13, 0.17)
	e.ambient_light_energy = 0.7
	e.glow_enabled = true
	env.environment = e
	env_ref = e
	add_child(env)
	_build_grid()

func _setup_sky(stem: String) -> void:
	# per-system sky from the original geog/*.lws: nebula backdrop model,
	# starfield tint/density, star + fill light colors, neighbor-star flares
	if sky_anchor != null:
		sky_anchor.queue_free()
	sky_anchor = Node3D.new()
	add_child(sky_anchor)
	var geo: Variant = null
	for cluster in ["badlands", "gagarin", "multiplayer"]:
		geo = _load_json("data/json/scenes/geog/%s/%s.json" % [cluster, stem])
		if geo != null:
			break
	if geo == null:
		return
	var sys_parent := Vector3.ZERO
	for n in geo["nodes"]:
		if str(n.get("name", "")) == "SystemParent" and n.has("pos"):
			sys_parent = Vector3(n["pos"][0], n["pos"][1], n["pos"][2])
	for n in geo["nodes"]:
		match str(n.get("kind", "")):
			"node":
				var cls := str(n.get("class", ""))
				if cls == "icNebulaAvatar":
					var mstem := str(n.get("url", "")).split("|")[-1].to_lower()
					var neb := _load_gltf("data/gltf/models/%s.gltf" % mstem)
					if neb != null:
						_make_additive(neb)
						sky_anchor.add_child(neb)
						# push the camera-anchored dome out near the far
						# plane so nearby geometry occludes it — at small
						# scales the additive backdrop painted OVER stations
						var r := _model_bounds_radius(neb)
						neb.scale = Vector3.ONE * (4.8e5 / maxf(r, 1.0))
				elif cls == "icStarfieldAvatar" and sky_mat != null:
					var tint := _parse_tuple(str(n.get("tint", "")), Vector3.ONE)
					sky_mat.set_shader_parameter("star_tint", tint)
					sky_mat.set_shader_parameter("density",
						clampf(float(n.get("bright_star_count", 2000)) / 2000.0,
							0.3, 3.0))
			"light":
				var col := Color.WHITE
				if n.has("color"):
					col = Color(n["color"][0] / 255.0, n["color"][1] / 255.0,
						n["color"][2] / 255.0)
				match str(n.get("name", "")):
					"<star>":
						sun.light_color = col
						sun.light_energy = float(n.get("intensity", 1.0)) * 0.9
					"<fill>":
						env_ref.ambient_light_color = col * 0.35
					_:
						if int(n.get("light_type", 0)) == 1 \
								and n.get("lens_flare", false) and n.has("pos"):
							# LW bank-180 SystemParent: (x,y) -> (-x,-y)
							var p := Vector3(-n["pos"][0], -n["pos"][1],
								n["pos"][2]) + sys_parent
							if p.length() > 100.0:
								_add_sky_flare(p, col)

func _parse_tuple(t: String, fallback: Vector3) -> Vector3:
	var parts := t.trim_prefix("(").trim_suffix(")").split(",")
	if parts.size() >= 3:
		return Vector3(float(parts[0]), float(parts[1]), float(parts[2]))
	return fallback

func _add_sky_flare(dir_lw: Vector3, col: Color) -> void:
	var dir := Vector3(dir_lw.x, dir_lw.y, -dir_lw.z).normalized()
	var mesh := SphereMesh.new()
	mesh.radius = 1600.0
	mesh.height = 3200.0
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = col
	mat.emission_enabled = true
	mat.emission = col
	mat.emission_energy_multiplier = 3.0
	mesh.material = mat
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.position = dir * 4.5e5
	sky_anchor.add_child(mi)

func _make_additive(node: Node3D) -> void:
	for mi in node.find_children("*", "MeshInstance3D", true, false):
		var m: MeshInstance3D = mi
		for i in m.get_surface_override_material_count():
			var mat := m.mesh.surface_get_material(i)
			if mat is StandardMaterial3D:
				var sm: StandardMaterial3D = mat.duplicate()
				sm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
				sm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
				sm.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
				sm.cull_mode = BaseMaterial3D.CULL_DISABLED
				m.set_surface_override_material(i, sm)

func _build_grid() -> void:
	# icHUDReferenceGrid: a 9x9x9 lattice of streaks pointing back along the
	# velocity vector, decoded from iwar2.dll FUN_100f5550 (see docs/hud.md)
	space_fx = SpaceFx.new()
	add_child(space_fx)
	# capsule space (the between-systems tunnel), inert until a jump enters it
	capsule = CapsuleFx.new()
	add_child(capsule)
	# LDSI boundary fence: vertical pillars marking the inhibition limit
	ldsi_mat = StandardMaterial3D.new()
	ldsi_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	ldsi_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	ldsi_mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	ldsi_mat.vertex_color_use_as_albedo = true
	ldsi_mesh = ImmediateMesh.new()
	var lm := MeshInstance3D.new()
	lm.mesh = ldsi_mesh
	add_child(lm)

func _update_ldsi_fence() -> void:
	# the original visualized the LDS-inhibition boundary near the player:
	# a curtain of vertical green pillars at the zone's edge
	ldsi_mesh.clear_surfaces()
	if docked_at != "" or jump_state != 0:
		return
	var b := _nearest_inhibitor()
	if b.is_empty() or absf(float(b["clear"])) > 2.0e4:
		return
	var center: Vector3 = b["center"]
	var r: float = b["r"]
	var flat := Vector3(-center.x, 0, -center.z)  # ship dir in zone plane
	if flat.length() < 1.0:
		flat = Vector3.FORWARD
	var base_a := atan2(flat.z, flat.x)
	ldsi_mesh.surface_begin(Mesh.PRIMITIVE_LINES, ldsi_mat)
	for i in range(-14, 15):
		var a := base_a + i * (2400.0 / r)  # ~2.4 km pillar spacing
		var p := center + Vector3(cos(a), 0, sin(a)) * r
		var dist := p.length()
		var alpha := clampf(1.0 - dist / 3.0e4, 0.0, 0.6)
		if alpha <= 0.01:
			continue
		ldsi_mesh.surface_set_color(Color(0.3, 1.0, 0.45, alpha))
		ldsi_mesh.surface_add_vertex(p + Vector3(0, -900, 0))
		ldsi_mesh.surface_set_color(Color(0.3, 1.0, 0.45, alpha * 0.15))
		ldsi_mesh.surface_add_vertex(p + Vector3(0, 900, 0))
	ldsi_mesh.surface_end()

func _update_grid() -> void:
	# no HUD underlay inside capsule space: the capsule system renders only
	# its own scene graph (icCapsuleSpaceSystem::Render @ 0x100481e0), and
	# the director is in cinematic mode for the whole effect
	space_fx.update_grid(cam, Vector3(px, py, pz), ship.velocity,
		lds_state == 2, docked_at != "" or jump_state >= 3)
	# @element icAggressorAvatar -- up exactly while the shield's "fire" channel
	# is 1 (icAggressorShield::Simulate 0x1002f44f)
	if sys != null and ship != null:
		space_fx.set_aggressor(_base(), sys.aggressor_active(),
			ship.global_transform)
	_update_contrails()

# @element icHUDContrails
## The trail feed: the player's own ship always takes the first of the eight
## slots (icHUD+0x104), then the contacts. `width` is icShip::width (+0x208), the
## ship INI's `width` -- it is the wingspan the player's ladder is drawn to.
func _update_contrails() -> void:
	var ships: Array = []
	if ship != null:
		ships.append({"node": ship, "vel": ship.velocity, "player": true,
			"width": float(ship_stats.get("width", 80)),
			"lds": lds_state == 2, "col": Hud.AMBER})
	for a in ai_ships:
		if not is_instance_valid(a):
			continue
		ships.append({"node": a, "vel": a.velocity, "player": false,
			"width": 0.0, "lds": false,
			"col": Hud.RED if a.behavior == "attack" else Hud.GREEN})
	space_fx.update_contrails(get_physics_process_delta_time(), ships,
		docked_at != "" or jump_state >= 3)

func _starfield_material() -> ShaderMaterial:
	var m := ShaderMaterial.new()
	var sh := Shader.new()
	sh.code = """
shader_type sky;
uniform vec3 star_tint = vec3(0.9, 0.93, 1.0);
uniform float density = 1.0;
float hash(vec3 p) { return fract(sin(dot(p, vec3(127.1, 311.7, 74.7))) * 43758.5453); }
void sky() {
	vec3 d = EYEDIR;
	vec3 cell = floor(d * 220.0);
	float h = hash(cell);
	float star = step(1.0 - 0.003 * density, h);
	vec3 center = (cell + 0.5) / 220.0;
	float falloff = smoothstep(0.0035, 0.0005, distance(normalize(center), d));
	float tw = 0.6 + 0.4 * hash(cell + 1.0);
	COLOR = vec3(0.004, 0.005, 0.01) + star * falloff * tw * star_tint;
}
"""
	m.shader = sh
	sky_mat = m
	return m

# --- system loading -------------------------------------------------------

func _clear_system() -> void:
	for o in objects:
		if o["node"] != null:
			o["node"].queue_free()
	objects.clear()
	for a in ai_ships:
		a.queue_free()
	ai_ships.clear()
	if weapons != null:
		weapons.clear()
	if missiles != null:
		missiles.clear()
	target_idx = -1
	target_ai = null
	docked_at = ""
	if fields != null:
		fields.clear_system()

func _load_system(stem: String, entry_name := "", from_stem := "") -> void:
	_clear_system()
	system_stem = stem
	var sys: Dictionary = _load_json("data/json/systems/%s.json" % stem)
	system_name = str(sys["objects"][0]["name"])
	var entry := {}
	for o in sys["objects"]:
		var cat := str(o.get("category", "body"))
		if cat == "system":
			continue
		var rec := {
			"name": str(o["name"]), "category": cat,
			"x": float(o["pos"][0]), "y": float(o["pos"][1]),
			"z": -float(o["pos"][2]),
			# the f32 at record +0x138, i.e. what the engine hands to
			# FiSim::SetRadius. Not a map zone, not clamped.
			"radius": float(o.get("radius", 0.0)),
			"orientation": o.get("orientation", [1.0, 0.0, 0.0, 0.0]),
			"avatar": str(o.get("avatar", "")),
			"jumps": o.get("jumps_to_stems", []),
			"colors": o.get("colors", []),
			"renders": bool(o.get("renders", false)),
			"surface_class": str(o.get("surface_class", "")),
			"surface_textures": o.get("surface_textures", []),
			"atmosphere_texture": str(o.get("atmosphere_texture", "")),
			"ring_count": int(o.get("ring_count", 0)),
			"sun_texture": str(o.get("sun_texture", "")),
			"sun_colours": o.get("sun_colours", []),
			"node": null,
		}
		objects.append(rec)
		# a kind-4 belt record is a field ZONE, not a body: ParseAsteroidBeltInfo
		# (iwar2 @ 0x1004e6b0) reads the ring radius from the record's +0x134
		# (our JSON `info_f`), the width from +0x138 (our `radius`), and centres
		# the annulus on the PARENT geography's position. Inside it, the ambient
		# asteroid field runs (fields.gd).
		if cat == "belt" and fields != null:
			var par_i := int(o.get("parent", 0))
			var objs: Array = sys["objects"]
			var ppos: Array = [0.0, 0.0, 0.0]
			if par_i >= 0 and par_i < objs.size():
				ppos = objs[par_i].get("pos", ppos)
			fields.add_belt(float(o.get("info_f", 0.0)), rec["radius"],
				float(ppos[0]), float(ppos[1]), -float(ppos[2]),
				_record_basis(rec))
		# icPlanet::CreateAvatar only builds an avatar for 1 < IeBodyType < 5,
		# so most map bodies (and the system centre) are invisible markers.
		if rec["renders"] and (cat == "body" or cat == "star"):
			_spawn_impostor(rec)
		if entry_name != "" and rec["name"] == entry_name:
			entry = rec
	if entry.is_empty():
		# arrive at the L-point that links back to where we came from,
		# else at the system's first L-point
		for o in objects:
			if o["category"] != "lpoint":
				continue
			if entry.is_empty() or from_stem in o["jumps"]:
				entry = o
			if from_stem != "" and from_stem in o["jumps"]:
				break
	if entry.is_empty() and not objects.is_empty():
		entry = objects[0]
	last_entry = entry  # the capsule exit takes this L-point's orientation
	px = entry["x"] + 2500.0
	py = entry["y"] + 300.0
	pz = entry["z"] + 3000.0
	jump_sel = 0
	_setup_sky(stem)
	_spawn_traffic()
	# iBackToBase.Initialise: the base is on sensors -- and so in the contact
	# list -- in exactly one system, and only once the act's found-base flag is
	# set. See base_interior.gd.
	if base_iface != null:
		base_iface.apply_visibility()
	print("SYSTEM: ", system_name, " (", objects.size(), " objects)")

func _planet_texture(stem: String) -> ImageTexture:
	if stem.is_empty():
		return null
	var path := _base().path_join("data/textures/images/planets/%s.png" % stem)
	if not FileAccess.file_exists(path):
		return null
	var img := Image.load_from_file(path)
	if img == null:
		return null
	return ImageTexture.create_from_image(img)

func _surface_tint(rec: Dictionary, layer: int) -> Color:
	# icPlanet::SurfaceTint(n) = the record's colour n, scaled by 1/255
	# (icPlanet::ReadColour, _DAT_1011b068 = 0.00392157)
	var colors: Array = rec.get("colors", [])
	if layer >= colors.size():
		return Color.WHITE
	var c: Array = colors[layer]
	return Color(c[0] / 255.0, c[1] / 255.0, c[2] / 255.0)

func _planet_material(rec: Dictionary) -> StandardMaterial3D:
	# icPlanetAvatar's shader (FUN_100cdc50 @ 0x100cdc50): layer 0 is
	# SurfaceType(0) out of planets.ini's rocky_ or gassy_planet_textures,
	# tinted by SurfaceTint(0).
	var mat := StandardMaterial3D.new()
	var textures: Array = rec.get("surface_textures", [])
	if not textures.is_empty():
		mat.albedo_texture = _planet_texture(str(textures[0]))
	mat.albedo_color = _surface_tint(rec, 0)
	mat.roughness = 0.9
	return mat

func _atmosphere_material(rec: Dictionary) -> StandardMaterial3D:
	# the cloud layer: atmosphere_planet_textures[record +0x164], tinted with a
	# random blend of the two surface tints pulled toward white
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = _planet_texture(str(rec["atmosphere_texture"]))
	var tint := _surface_tint(rec, 0).lerp(_surface_tint(rec, 1), 0.5) \
		.lerp(Color.WHITE, 0.6)
	mat.albedo_color = Color(tint.r, tint.g, tint.b, 0.55)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.roughness = 1.0
	return mat

func _spawn_impostor(rec: Dictionary) -> void:
	if rec["category"] == "star":
		var star := StarFx.new()
		star.setup(rec, _base())
		add_child(star)
		rec["node"] = star
		return
	var node := Node3D.new()
	var mesh := SphereMesh.new()
	mesh.radius = 1.0
	mesh.height = 2.0
	mesh.radial_segments = 48
	mesh.rings = 24
	mesh.material = _planet_material(rec)
	var body := MeshInstance3D.new()
	body.mesh = mesh
	node.add_child(body)
	if not str(rec["atmosphere_texture"]).is_empty():
		var shell := SphereMesh.new()
		shell.radius = ATMOSPHERE_HEIGHT
		shell.height = ATMOSPHERE_HEIGHT * 2.0
		shell.radial_segments = 48
		shell.rings = 24
		shell.material = _atmosphere_material(rec)
		var atmo := MeshInstance3D.new()
		atmo.mesh = shell
		node.add_child(atmo)
	for i in int(rec["ring_count"]):
		node.add_child(_spawn_ring(rec, i))
	add_child(node)
	rec["node"] = node

func _spawn_ring(rec: Dictionary, i: int) -> MeshInstance3D:
	# icPlanetAvatar (0x100cdc50) seeds an FcRandom from the body radius and,
	# for each of NumberOfRings(), draws a ring at FcRandom::Float(1.75, 2.44)
	# x the body radius, coloured by taking SurfaceTint(0)'s hue and scaling
	# its value by FcRandom::Float(0.2, 0.8). The width is NOT recovered.
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(str(rec["name"]) + str(i))
	var r := rng.randf_range(RING_MIN, RING_MAX)
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = _planet_texture("ring")
	var hsv := _surface_tint(rec, 0)
	mat.albedo_color = Color.from_hsv(hsv.h, hsv.s, rng.randf_range(0.2, 0.8), 0.7)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	var node := MeshInstance3D.new()
	node.mesh = _annulus_mesh(r - RING_WIDTH, r)
	node.mesh.surface_set_material(0, mat)
	return node

func _annulus_mesh(inner: float, outer: float) -> ArrayMesh:
	# a flat band in the body's equatorial plane
	const SEGMENTS := 96
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	for s in SEGMENTS:
		var a0 := TAU * s / SEGMENTS
		var a1 := TAU * (s + 1) / SEGMENTS
		var i0 := Vector3(cos(a0) * inner, 0.0, sin(a0) * inner)
		var o0 := Vector3(cos(a0) * outer, 0.0, sin(a0) * outer)
		var i1 := Vector3(cos(a1) * inner, 0.0, sin(a1) * inner)
		var o1 := Vector3(cos(a1) * outer, 0.0, sin(a1) * outer)
		var u0 := float(s) / SEGMENTS
		var u1 := float(s + 1) / SEGMENTS
		verts.append_array([i0, o0, o1, i0, o1, i1])
		uvs.append_array([Vector2(u0, 0), Vector2(u0, 1), Vector2(u1, 1),
			Vector2(u0, 0), Vector2(u1, 1), Vector2(u1, 0)])
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_TEX_UV] = uvs
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return mesh

func _spawn_beacon(rec: Dictionary) -> Node3D:
	# icHUDLagrangeIcon: the blue/red wireframe double funnel (docs/hud.md)
	var node := SpaceFx.make_lagrange_icon(_lpoint_axis(rec))
	add_child(node)
	return node

func _lpoint_axis(rec: Dictionary) -> Vector3:
	# The funnel is drawn in the L-point sim's frame with the jump axis on
	# local +Z (icLagrangePointWaypoint::TryToJump @ 0x1006ad40 refuses a jump
	# unless the ship's offset has local z < 0). That frame is the record's own
	# orientation quaternion at +0x120, which icSolarSystem::Load hands to
	# FiSim::SetOrientation; every L-point carries a real yaw there.
	return _record_basis(rec) * Vector3.FORWARD

func _record_basis(rec: Dictionary) -> Basis:
	# The map is left-handed (+Z forward) and we mirror Z into Godot's frame,
	# so a rotation R becomes M R M with M = diag(1,1,-1): for a quaternion
	# stored (w, x, y, z) that is (w, -x, -y, z). Game +Z is Godot -Z, so the
	# record's local +Z axis is the basis applied to Vector3.FORWARD.
	var q: Array = rec.get("orientation", [])
	if q.size() != 4:
		return Basis.IDENTITY
	var quat := Quaternion(-float(q[1]), -float(q[2]), float(q[3]), float(q[0]))
	if not quat.is_normalized():
		return Basis.IDENTITY
	return Basis(quat)

func _spawn_player() -> void:
	ship = ShipFlight.new()
	ship.name = "Player"
	var stats: Array = _load_json("data/json/ships.json")
	for rec in stats:
		if rec.get("path", "") == "sims/ships/player/tug.ini":
			ship_stats = rec["properties"]
			ship.load_stats(ship_stats)
			break
	base_max_accel = ship.max_accel
	base_turn_accel = ship.turn_accel
	ship_model = _load_gltf("data/avatars/avatars/tug_hull/setup_prefitted.gltf")
	ship.add_child(ship_model)
	# the tug's RCS jets live on its command section
	var cs := _load_gltf("data/avatars/avatars/command_section/setup.gltf")
	if cs != null:
		ShipEffects.graft_jets(ship_model, cs)
	ShipEffects.attach(ship, ship_model)
	add_child(ship)
	_fit_systems("sims/ships/player/tug.ini")
	weapons = PbcWeapons.new()
	weapons.ship = ship
	weapons.main = self
	weapons.refire = 0.7  # subsims/systems/player/pbc.ini refire_delay
	add_child(weapons)
	# icLoadout::CreateWeaponLinks (0x10096940) builds the fire groups when the
	# hull is fitted, and icPlayerPilot cycles THAT list. This boot path fitted the
	# systems above but never built the list, so the player's weapon cycle was
	# empty in the actual game -- which is why Enter appeared to do nothing but
	# make a noise. The tug's list is: the linked PBC pair, the assault cannon and
	# the quad light PBC (three channel-1 entries).
	weapons.set_muzzles(ship_model)
	weapons.build_groups(sys)
	if not weapons.groups.is_empty():
		weapon_name = weapons.group_label()
	missiles = Missiles.new()
	missiles.main = self
	add_child(missiles)
	cam = Camera3D.new()
	cam.far = 6.0e5
	cam.fov = FOV_INTERNAL  # starts in the F1 internal view
	add_child(cam)
	cam.make_current()
	# the original's cockpit frame, removable like the old UI option (V key),
	# exactly as authored: avatars/cockpit/setup.lws puts cockpit4 at
	# LW (0,-0.8225,1.8823) relative to the pilot's eye
	# (the authored LW offset is already baked into the assembled gltf)
	cockpit = _load_gltf("data/avatars/avatars/cockpit/setup.gltf")
	if cockpit != null:
		cam.add_child(cockpit)
	_apply_view()

func cam_name() -> String:
	return CAM_GROUPS[cam_mode][cam_view]

func _apply_view() -> void:
	# only the cockpit view carries the cockpit dressing; every camera that is
	# not inside the ship shows the hull
	cockpit_frame = cam_mode == 0 and cam_view == 0
	if cockpit != null:
		cockpit.visible = cockpit_frame
	if ship_model != null:
		ship_model.visible = not (cam_mode == 0 and cam_view <= 1)

## icDirector::OnMessage's camera-key rule: outside the group, jump to its first
## camera; inside it, step to the next one.
func _set_camera(group: int) -> void:
	if group == cam_mode:
		cam_view = (cam_view + 1) % CAM_GROUPS[group].size()
	else:
		cam_mode = group
		cam_view = 0
	if cam_name() == "drop":
		drop_cam_pos = cam.global_position
	zoomed = false
	zoom_factor = 1.0
	cam.fov = FOV_INTERNAL if cam_mode == 0 and cam_view <= 1 else FOV_EXTERNAL
	audio.play("audio/gui/camera_change.wav", -10.0)
	_apply_view()

func _spawn_traffic() -> void:
	# a couple of utility ships patrolling the start cluster
	var local: Array = []
	for o in objects:
		if o["category"] != "station":
			continue
		var d := Vector3(o["x"] - px, o["y"] - py, o["z"] - pz)
		if d.length() < 1.0e5:
			local.append(d)
	if local.size() < 2:
		return
	for i in 2:
		var ai := AiShip.new()
		ai.main = self
		ai.display_name = "Freighter %d" % (i + 1)
		ai.setup({"hit_points": 800, "speed": [100, 100, 300],
				"acceleration": [40, 40, 60], "yaw_rate": 20, "pitch_rate": 20,
				"roll_rate": 20})
		ai.avatar_path = "data/avatars/avatars/freighter/setup.gltf"
		var fmodel := _load_gltf(ai.avatar_path)
		ai.add_child(fmodel)
		ShipEffects.attach(ai, fmodel)
		ai.position = Vector3(local[0]) + Vector3(1500 + i * 900, i * 400, -2000)
		for w in local:
			ai.waypoints.append(Vector3(w))
		ai.wp = i % local.size()
		add_child(ai)
		ai_ships.append(ai)

func spawn_hostile(at: Vector3) -> AiShip:
	var ai := AiShip.new()
	ai.main = self
	ai.display_name = "Marauder Cutter"
	ai.setup({"hit_points": 600, "speed": [150, 150, 600],
			"acceleration": [80, 80, 120], "yaw_rate": 45, "pitch_rate": 45,
			"roll_rate": 45})
	ai.behavior = "attack"
	ai.avatar_path = "data/avatars/avatars/cutter/setup.gltf"
	var model := _load_gltf(ai.avatar_path)
	if model == null:
		ai.avatar_path = "data/avatars/avatars/gangstership/setup.gltf"
		model = _load_gltf(ai.avatar_path)
	ai.add_child(model)
	ShipEffects.attach(ai, model)
	# the authored cutter: 1500 hp, 55 armour, an icAILDA shield and ten other
	# subsims (sims/ships/marauder/marauder_cutter.ini)
	ai.setup_ini("sims/ships/marauder/marauder_cutter.ini", model)
	ai.position = at
	add_child(ai)
	ai_ships.append(ai)
	audio.music("action")
	hud.warn("HOSTILE CONTACT", 3.0)
	audio.play("audio/hud/klaxon.wav", -6.0)
	return ai

func spawn_bolt(shooter: Node3D, dir: Vector3) -> void:
	# NPC cannons: nps_pbc.ini fires the same sims/weapons/pbc_bolt
	weapons.spawn(shooter, dir, PbcWeapons.PBC_BOLT)
	audio.play("audio/sfx/light_pbc.wav", -8.0)

func on_bolt_hit(target: Node3D, pos: Vector3, shooter: Node3D = null,
		bolt: Dictionary = {}) -> void:
	# lws:/sfx/hull_impact_high_0: the impact sound, the pbc_spark system and
	# a flash, with the sparks thrown back out along the surface normal
	var out := pos - target.global_position
	out = out.normalized() if out.length_squared() > 1.0 else Vector3.FORWARD
	var spec: Dictionary = bolt.get("spec", PbcWeapons.PBC_BOLT)
	var age: float = float(bolt.get("age", 0.0))
	if target == ship:
		if shooter is AiShip:
			last_aggressor = shooter
		var hit := hit_player(spec, age, pos)
		# A deflected bolt never reaches the hull -- it flares on the LDA field,
		# and the engine has a separate effect for exactly that. Playing a
		# scaled-down hull impact was our invention.
		ExplosionFx.play(self,
				"lda_impact" if hit["deflected"] else "hull_impact",
				Transform3D(Basis.looking_at(-out), pos), 1.0)
		return
	ExplosionFx.play(self, "hull_impact",
			Transform3D(Basis.looking_at(-out), pos), 1.0)
	var ai := target as AiShip
	if ai != null and ai.hit_by_bolt(spec, age, pos)["killed"]:
		kill_ai(ai)

func kill_ai(ai: AiShip) -> void:
	# iiSim::OnKilled 0x10079b80 -> the death explosion + score/removal;
	# shared by bolt hits (on_bolt_hit) and warheads (missiles.gd)
	if ai == null or not is_instance_valid(ai):
		return
	# icAlienSwarm::OnExplode 0x1002c4b0 replaces the stock death with its own
	# alien_explosion shockwave (alien.gd plays it) -- no generic boom on top
	if not (ai is AlienShip):
		ExplosionFx.boom(self, ai.global_position, 70.0)
	kill_count += 1
	hud.warn("%s DESTROYED" % str(ai.display_name).to_upper())
	ai_ships.erase(ai)
	if target_ai == ai:
		target_ai = null
	ai.queue_free()
	if not _hostiles_alive():
		audio.music("ambient")

func _hostiles_alive() -> bool:
	for a in ai_ships:
		if a.behavior == "attack":
			return true
	return false

func _flash(pos: Vector3, size: float) -> void:
	var mesh := SphereMesh.new()
	mesh.radius = size
	mesh.height = size * 2
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(1.0, 0.85, 0.5)
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.7, 0.3)
	mat.emission_energy_multiplier = 4.0
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mesh.material = mat
	var node := MeshInstance3D.new()
	node.mesh = mesh
	add_child(node)
	node.global_position = pos
	var tw := create_tween()
	tw.tween_property(node, "scale", Vector3.ONE * 3.0, 0.5)
	tw.parallel().tween_property(mat, "albedo_color:a", 0.0, 0.5)
	tw.tween_callback(node.queue_free)

func _station_faction(sname: String) -> String:
	# text/faction_names.csv abbreviations
	const FACS := {"maas": "MAAS", "nomex": "SOLAN", "police": "LAW",
		"government": "GOVMT", "marauder": "XXXXX", "navy": "NAVY",
		"military": "NAVY", "trimann": "TRIMN", "lomax": "LXENG",
		"helios": "HELIO", "laplace": "NSO-L", "junker": "JUNKS"}
	for f in FACS:
		if f in sname.to_lower():
			return FACS[f]
	return "INDPT"

func contact_list() -> Array:
	# original columns: faction / type / range / name (manual, HUD section)
	var list: Array = []
	for i in objects.size():
		var o: Dictionary = objects[i]
		# isim.SetSensorVisibility(sim, false): the scripts hide a sim from
		# sensors to stage an ambush, so it must not reach the contact list.
		if o.get("sensor_hidden", false):
			continue
		var d := Vector3(o["x"] - px, o["y"] - py, o["z"] - pz).length()
		var show := false
		match o["category"]:
			"station", "gunstar":
				show = d < 5.0e5
			"lpoint":
				show = d < 1.0e7
		if show:
			list.append({"name": o["name"], "dist": d, "hostile": false,
					"targeted": i == target_idx, "category": o["category"],
					"faction": str(o.get("faction", "NAV" if o["category"] == "lpoint"
						else _station_faction(str(o["name"])))),
					"type": str(o.get("type", "LAGPT" if o["category"] == "lpoint"
						else "STATN"))})
	for a in ai_ships:
		if not _sensor_visible(a):
			continue
		var hostile: bool = a.behavior == "attack"
		list.append({"name": _contact_name(a), "dist": a.global_position.length(),
				"hostile": hostile, "targeted": a == target_ai,
				"category": "traffic",
				"faction": "OUTLW" if hostile else a.faction,
				"type": "FIGHT" if hostile else a.ctype})
	list.sort_custom(func(x, y): return x["dist"] < y["dist"])
	return list.slice(0, 12)

## iiSim::VisibleToSensor (iwar2 @ 0x100013b0) gates a sim's place in the contact
## list. The scripts clear it with isim.SetSensorVisibility to stage an ambush --
## it applied to SHIPS as much as to stations, and we were only honouring it for
## static records, so hidden ambushers were showing up on the list.
func _sensor_visible(a: AiShip) -> bool:
	if pog_world == null:
		return true
	var key := String(a.sim_key)
	if key.is_empty():
		return true
	var s = pog_world.sims.get(key)
	return true if s == null else s.sensor_visible

## Never show a raw sim name. A sim's NAME is a localisation key and the engine
## resolves it (icAIPilot::ResolveName) before anything displays it; a ship with
## no name at all is "Undefined", never its Godot node name.
func _contact_name(a: AiShip) -> String:
	if not String(a.display_name).is_empty():
		return String(a.display_name)
	return "Undefined"

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
	if event is InputEventMouseMotion and not demo and docked_at == "":
		var mx: float = event.relative.x * 0.003 / zoom_factor
		var my: float = event.relative.y * 0.003 / zoom_factor
		if roll_yaw_swap:
			ship.input_rotate.z = clampf(ship.input_rotate.z - mx, -1, 1)
		else:
			ship.input_rotate.y = clampf(ship.input_rotate.y - mx, -1, 1)
		ship.input_rotate.x = clampf(ship.input_rotate.x - my, -1, 1)
	# RollYawToggleHold: held, not toggled (flux.ini toggle_roll_yaw = 0). The
	# original's only binding is joystick button 2; on a mouse yoke the right
	# button is its natural home.
	if event is InputEventMouseButton \
			and event.button_index == MOUSE_BUTTON_RIGHT:
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
			KEY_N:  # icPlayerPilot.FreeToggle
				free_toggle = not free_toggle
				audio.play("audio/gui/mechanical_confirm.wav", -10.0)
				hud.log_msg("FLIGHT ASSIST %s" % ("OFF" if free_toggle else "ON"))
			KEY_L:  # ToggleLDS
				_toggle_lds()
			KEY_U:  # Undock
				_undock()
			KEY_Z:  # ToggleZoom -- gated on hardware, see _enable_zoom
				_enable_zoom(not zoomed)
			KEY_COMMA:  # CycleContactUp
				_cycle_contact(-1)
			KEY_PERIOD:  # CycleContactDown
				_cycle_contact(1)
			KEY_HOME:
				_target_contact_index(0)
			KEY_END:
				_target_contact_index(9999)
			KEY_R:  # TargetNearestEnemy
				_target_nearest_enemy()
			KEY_T:  # TargetNearestShipToDirection
				_target_nearest_to_direction()
			KEY_E:  # CycleEnemy
				_cycle_enemy()
			KEY_Q:  # TargetLastAggressor
				if last_aggressor != null and is_instance_valid(last_aggressor):
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
			KEY_G:  # the aggressor shield. Its Fire (0x1002f6a0) just raises the
				# active flag; it refuses unless the bank is FULL, then holds
				# for `duration` seconds while it drains.
				_fire_aggressor()
			KEY_I:  # icPlayerPilot.LDSIQuickFire: the LDSi magazine fires on
				# its own trigger, bypassing weapon selection (the dedicated
				# LDSI path in AttemptToActivateWeapon 0x1003ccb0 via
				# pilot+0x82)
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
			KEY_J:  # capsule jump at an L-point (remaster binding)
				_try_jump()
			KEY_K:
				_cycle_route()
			KEY_H:  # dev: spawn hostile
				spawn_hostile(ship.global_position +
					-ship.global_transform.basis.z * 3000.0 + Vector3(400, 200, 0))

func _target_pos() -> Vector3:
	if target_ai != null and is_instance_valid(target_ai):
		return target_ai.global_position
	if target_idx >= 0:
		var t: Dictionary = objects[target_idx]
		return Vector3(t["x"] - px, t["y"] - py, t["z"] - pz)
	return Vector3.INF

func _target_distance() -> float:
	var p := _target_pos()
	return INF if p == Vector3.INF else p.length()

func target_avatar() -> String:
	# avatar path for the MFD's EO feed
	if target_ai != null and is_instance_valid(target_ai):
		return target_ai.avatar_path
	if target_idx >= 0:
		var av := str(objects[target_idx].get("avatar", ""))
		if av != "":
			return "data/avatars/" + av
	return ""

func _nearest(category: String, range_limit := INF) -> Dictionary:
	var best := {}
	var bestd := INF
	for o in objects:
		if o["category"] != category:
			continue
		var d := Vector3(o["x"] - px, o["y"] - py, o["z"] - pz).length()
		if d < bestd and d < range_limit:
			bestd = d
			best = o
	best["dist"] = bestd
	return best

func _nearest_inhibitor() -> Dictionary:
	# nearest LDS-inhibition source (stations 25 km, bodies scale with
	# their radius — masses inhibit LDS, iRegion.CreateLDSI)
	var best := {}
	var bestc := INF
	for o in objects:
		var inhibit := 0.0
		match o["category"]:
			"station":
				inhibit = LDSI_RADIUS
			"body":
				# drop out just above the rendered surface — LDSI proper is
				# station/script territory in IW2, not blanket planet zones
				inhibit = maxf(LDSI_RADIUS, o["radius"] * 1.2)
			_:
				continue
		var cen := Vector3(o["x"] - px, o["y"] - py, o["z"] - pz)
		var cl := cen.length() - inhibit
		if cl < bestc:
			bestc = cl
			best = {"center": cen, "r": inhibit, "clear": cl}
	return best

func _lds_clearance() -> float:
	var b := _nearest_inhibitor()
	return INF if b.is_empty() else float(b["clear"])

func inhibit_charge() -> float:
	# 1 deep inside an inhibition zone, discharging to 0 at its boundary
	# (the HUD roundel's pip ring). LDSi weapon hits pin it at full.
	if disrupt_time > 0.0:
		return 1.0
	var b := _nearest_inhibitor()
	if b.is_empty():
		return 0.0
	var clear: float = b["clear"]
	if clear >= 0.0:
		return 0.0
	return clampf(-clear / maxf(float(b["r"]), 1.0), 0.0, 1.0)

func disrupt(seconds: float) -> void:
	# iship.DisruptLDSDrive: an LDSi hit locks the drive out for a while
	disrupt_time = maxf(disrupt_time, seconds)
	if lds_state != 0:
		lds_state = 0
		audio.lds_player.stop()
		audio.play("audio/sfx/lds_rampdown.wav", -4.0)
	audio.play("audio/sfx/ldsi_engage.wav", -4.0)
	hud.warn("LDS DRIVE DISRUPTED", 3.0)

func _toggle_lds() -> void:
	if docked_at != "" or jump_state != 0:
		return
	if disrupt_time > 0.0:
		hud.warn("LDS DRIVE DISRUPTED")
		audio.play("audio/hud/invalid_input.wav", -8.0)
		return
	if lds_state != 0:
		_drop_out_of_lds()
	elif _lds_clearance() > 0.0:
		lds_state = 1
		lds_timer = 0.0
		lds_speed = LDS_BASE
		audio.play("audio/sfx/lds_rampup.wav", -4.0)
	else:
		hud.warn("LDS INHIBITED")
		audio.play("audio/hud/invalid_input.wav", -8.0)

func _try_dock() -> void:
	var near := _nearest("station")
	if near.get("dist", INF) > DOCK_RANGE:
		hud.warn("NO DOCKPORT IN RANGE")
		audio.play("audio/hud/invalid_input.wav", -8.0)
		return
	# Lucrecia's Base is not an ordinary dock. It has no dockport of its own that
	# the player can use -- iBackToBase.Detector bolts a "bodge dockport" onto
	# the PLAYER's ship inside 200 km so that a dock order is even possible --
	# and the dock itself is a cutscene that ends inside the base. The whole
	# procedure is base_interior.gd; here we only hand it over.
	# (iStartSystem's own dock watcher, local_207, is NOT gated on the found-base
	# flag: it raises the interior whenever the player is docked to the base, by
	# any route. Only the cutscene and the autoskip are iBackToBase's.)
	if base_iface != null and str(near["name"]) == BaseInterior.BASE_NAME \
			and base_iface.dockable():
		_set_autopilot(0)
		base_iface.enter()
		return
	docked_at = near["name"]
	ship.velocity = Vector3.ZERO
	ship.set_speed = 0.0
	audio.play("audio/sfx/dock.wav", -4.0)
	audio.music("ambient")
	hud.log_msg("DOCKED: %s" % str(near["name"]).to_upper())
	if "base" in docked_at.to_lower():
		_enter_base()

func _enter_base() -> void:
	# the original's drydock hangar interior (avatars/base), placed so the
	# tug parking bay wraps around the docked ship; channel switches pick
	# the normal light bank and the tug bay dressing
	if base_root != null:
		return
	base_root = _load_gltf("data/avatars/avatars/base/setup.gltf")
	if base_root == null:
		return
	add_child(base_root)
	base_root.position = -BASE_BAY
	var lights := 0
	for n in base_root.find_children("*", "Node3D", true, false):
		if not n.has_meta("extras"):
			continue
		var ex: Dictionary = n.get_meta("extras")
		match str(ex.get("iw2_kind", "")):
			"switch":
				n.visible = str(ex.get("iw2_channel", "")) in [
					"baselights_normal", "tug"]
			"light":
				if lights >= 48 or not (n as Node3D).is_visible_in_tree():
					continue
				var col := Color(1, 1, 1)
				if ex.has("iw2_color"):
					var c: Array = ex["iw2_color"]
					col = Color(c[0] / 255.0, c[1] / 255.0, c[2] / 255.0)
				var l := OmniLight3D.new()
				l.light_color = col
				l.light_energy = 1.1
				l.omni_range = 170.0
				n.add_child(l)
				lights += 1
	if ship_model != null:
		ship_model.visible = true

func _leave_base() -> void:
	if base_root != null:
		base_root.queue_free()
		base_root = null
	_apply_view()

func _undock() -> void:
	if docked_at == "":
		return
	if base_iface != null and base_iface.inside:
		# iStartSystem's launch cutscene: the startup movie, then out of the tube
		docked_at = ""
		audio.play("audio/sfx/undock.wav", -4.0)
		base_iface.leave()
		return
	docked_at = ""
	_leave_base()
	audio.play("audio/sfx/undock.wav", -4.0)
	ship.velocity = -ship.global_transform.basis.z * 50.0
	clock_start = Time.get_ticks_msec()
	hud.log_msg("UNDOCKED")

## Point the ship's nose at a direction in folded world space, instantly. The
## cutscenes do this with sim.PointAt / sim.PointAway, which snap the sim's
## orientation rather than flying it round.
func _point_ship_at(dir: Vector3) -> void:
	if dir.length_squared() < 1.0e-6:
		return
	var up := Vector3.UP
	if absf(dir.normalized().dot(up)) > 0.999:
		up = Vector3.RIGHT
	ship.global_transform = Transform3D(Basis.IDENTITY,
		ship.global_position).looking_at(ship.global_position + dir, up)

# --- capsule jump ----------------------------------------------------------

func _jump_lpoint() -> Dictionary:
	var lp := _nearest("lpoint", JUMP_RANGE)
	return {} if lp.get("dist", INF) == INF else lp

func routes_text() -> String:
	var lp := _jump_lpoint()
	if lp.is_empty():
		return ""
	var jumps: Array = lp["jumps"]
	if jumps.is_empty():
		return "L-POINT: NO CHARTED ROUTES"
	var parts: PackedStringArray = []
	for i in jumps.size():
		var stem: String = jumps[i]
		parts.append(("[%s]" if i == jump_sel % jumps.size() else "%s")
			% stem.replace("_", " ").to_upper())
	return "CAPSULE ROUTES: " + "  ".join(parts) + "  (J jump, K cycle)"

func _cycle_route() -> void:
	var lp := _jump_lpoint()
	if lp.is_empty() or lp["jumps"].is_empty():
		return
	jump_sel = (jump_sel + 1) % lp["jumps"].size()
	audio.play("audio/hud/target_changed.wav", -10.0)

func _try_jump() -> void:
	if docked_at != "" or jump_state != 0 or lds_state != 0:
		return
	var lp := _jump_lpoint()
	if lp.is_empty():
		hud.warn("NO L-POINT IN RANGE")
		audio.play("audio/hud/invalid_input.wav", -8.0)
		return
	var jumps: Array = lp["jumps"]
	if jumps.is_empty():
		hud.warn("NO CHARTED CAPSULE ROUTES")
		audio.play("audio/hud/invalid_input.wav", -8.0)
		return
	jump_dest = jumps[jump_sel % jumps.size()]
	jump_state = 1
	jump_timer = 0.0
	hud.warn("CAPSULE DRIVE CHARGING", 3.0)
	audio.play("audio/sfx/capsule_jump.wav", -4.0)

func _jump_process(delta: float) -> void:
	jump_timer += delta
	match jump_state:
		1:  # spool -- the drive charging in the queue (icAITarget stage 3,
			# GetNewCapsuleJumpStage @ 0x1005c5af waits on icCapsuleDrive)
			if jump_timer >= 3.0:
				jump_state = 2
				jump_timer = 0.0
				hud.warn("ACCELERATION RUN", 2.0)
		2:  # acceleration run -- iAI.IsCapsuleJumpAccelerating (stage 4
			# flies at AverageJumpSpeed = (100+2500)/2 @ 0x1000b000;
			# TryToJump @ 0x1006ad40 gates entry on axis speed 100..2500,
			# statics 0x1015d224/0x1015d228)
			ship.velocity += -ship.global_transform.basis.z * 2500.0 * delta
			if jump_timer >= 3.0:
				# icCapsuleSpace::FullEffect @ 0x10042ea0: attach the effect
				# node and start the entry blank (icCapsuleEntryBlankAvatar
				# state 1 @ 0x100c0170: sound_url + force feedback + flash)
				jump_state = 3
				jump_timer = 0.0
				_flash_roll()
				audio.play("audio/sfx/capsule_jump.wav", -4.0)  # capsule_entry.ini
				hud.visible = false  # the director goes cinematic (Cue 0xf)
		3:  # entry blank: white-out held 1.5 s for the player
			# (_DAT_1011a268, FUN_100bf870), flickering at the effect-node
			# channel envelope (FUN_100bef90: keys 0.1 apart, rand[0.7,1])
			jump_fade.color.a = clampf(jump_timer * 4.0, 0.0, 1.0) \
				* _flash_flicker(jump_timer / CAPSULE_FLASH)
			if jump_timer >= CAPSULE_FLASH:
				_capsule_enter()
		4:  # capsule space (PerformJumps case 5): fly the tunnel out
			jump_fade.color.a = maxf(0.0, jump_fade.color.a - delta * 2.0)
			if jump_timer >= jump_duration:
				_capsule_exit()
		5:  # exit blank (case 6): the teleport already happened under full
			# white; the flash recedes as the ship flies off the L-point
			# (FUN_100beea0's proximity falloff), then camera + HUD restore
			# (case 7: icDirector::ChangeMode(0))
			jump_fade.color.a = clampf(1.0 - jump_timer / CAPSULE_FLASH,
				0.0, 1.0) * _flash_flicker(jump_timer / CAPSULE_FLASH)
			if jump_timer >= CAPSULE_FLASH:
				jump_state = 0
				jump_fade.color.a = 0.0
				hud.visible = true
				cam.fov = FOV_INTERNAL if cam_mode == 0 and cam_view <= 1 \
					else FOV_EXTERNAL
				hud.warn("ARRIVED: %s" % system_name.to_upper(), 4.0)

## Roll the blank-avatar flicker envelope: keys every tenth of the flash,
## values rand[0.7, 1.0] (FUN_100bef90 @ 0x100bef90; the 0.7 floor is
## _DAT_101191e8, the key spacing 0.1 is _DAT_101184b0).
func _flash_roll() -> void:
	_flick.resize(11)
	for i in 11:
		_flick[i] = randf_range(0.7, 1.0)

func _flash_flicker(t: float) -> float:
	var x := clampf(t, 0.0, 1.0) * 10.0
	var i := int(floor(x))
	return lerpf(_flick[i], _flick[mini(i + 1, 10)], x - i)

## Swap the world for capsule space. PerformJumps @ 0x10040cc0 case 4 -> 5:
## the ship is moved into icCluster's icCapsuleSpaceSystem (+0x2c) by
## SendShipDownTunnel @ 0x10043740 (velocity (0,0,500), identity orientation,
## so the tunnel axis is the ship's forward), the tunnel loop sound starts
## (blank avatar state 2: sound_tunnel_url), and the countdown is rolled at
## rand[8, 12] s (constants 0x10117b28 / 0x10119ec4).
func _capsule_enter() -> void:
	jump_state = 4
	jump_timer = 0.0
	jump_duration = randf_range(CAPSULE_TIME_MIN, CAPSULE_TIME_MAX)
	var fwd := -ship.global_transform.basis.z
	ship.velocity = fwd * CAPSULE_SHIP_SPEED
	ship.set_speed = CAPSULE_SHIP_SPEED
	capsule.enter(cam, ship.global_transform.basis)
	# capsule space is its own world: its scene graph holds only the tunnel
	# avatar and the cockpit (icCapsuleSpaceSystem::Render @ 0x100481e0) --
	# no sky, no sun, no system objects
	sun.visible = false
	if sky_anchor != null:
		sky_anchor.visible = false
	for o in objects:
		if o["node"] != null:
			o["node"].visible = false
	for a in ai_ships:
		a.visible = false
	_cap_prev_bg = env_ref.background_mode
	env_ref.background_mode = Environment.BG_COLOR
	env_ref.background_color = Color.BLACK
	audio.play_loop(audio.lds_player,
		"audio/sfx/inside_capsule_space.wav", -6.0)  # capsule_tunnel.ini
	_cap_cut_t = 0.0  # cut to a capsule-camera viewpoint immediately

func _capsule_world_restore() -> void:
	env_ref.background_mode = _cap_prev_bg
	sun.visible = true
	if sky_anchor != null:
		sky_anchor.visible = true
	for o in objects:
		if o["node"] != null:
			o["node"].visible = true
	for a in ai_ships:
		a.visible = true

## Leave capsule space: DoCapsuleJump @ 0x10042730. Teleport to the arrival
## L-point, take ITS orientation (FiSim::SetOrientation with the LP record's
## quaternion) and leave along its +Z jump axis at sqrt(2 * accel * 3000)
## (the player's accel scaled by 0.8^2, _DAT_1011959c), clamped to flux.ini
## [icCapsuleSpace] min/max_exit_speed 500..2000. The exit blank flash
## (case 6) covers the arrival.
func _capsule_exit() -> void:
	jump_state = 5
	jump_timer = 0.0
	_flash_roll()
	jump_fade.color.a = 1.0
	_apply_view()  # hand the cockpit/hull dressing back to the F-key camera
	audio.lds_player.stop()
	audio.play("audio/sfx/capsule_jump.wav", -4.0)  # exit blank sound_url
	capsule.exit()
	_capsule_world_restore()
	var from := system_stem
	_load_system(jump_dest, "", from)
	var b := ship.global_transform.basis
	if not last_entry.is_empty():
		b = _record_basis(last_entry)
		ship.global_transform.basis = b
	var v := sqrt(2.0 * ship.max_accel.z * CAPSULE_ACCEL_SCALE
		* CAPSULE_EXIT_RUN)
	if SHIP_HIT_RADIUS / maxf(v, 1.0) >= 2.5:  # big-hull cap @ 0x10042730
		v = SHIP_HIT_RADIUS / 2.5
	v = clampf(v, CAPSULE_EXIT_MIN, CAPSULE_EXIT_MAX)
	ship.velocity = (b * Vector3.FORWARD) * v
	ship.set_speed = minf(v, ship.max_speed.z)

## Abort the capsule sequence (a scripted system change mid-jump): put the
## world, HUD and fade back the way icCapsuleSpace::DetachEffect would.
func _jump_abort() -> void:
	if jump_state >= 3:
		capsule.exit()
		_capsule_world_restore()
		_apply_view()
		audio.lds_player.stop()
	jump_fade.color.a = 0.0
	hud.visible = true
	jump_state = 0

func _physics_process(delta: float) -> void:
	# reload_current_scene() does not stop the outgoing scene immediately: this
	# node keeps ticking for a frame after it has left the tree, and everything
	# that reaches for get_tree() or a global transform then fails. NEW GAME is
	# the only thing that does this.
	if not is_inside_tree():
		return
	fire_lock = maxf(0.0, fire_lock - delta)
	disrupt_time = maxf(0.0, disrupt_time - delta)
	weapon_disrupt_time = maxf(0.0, weapon_disrupt_time - delta)
	if weapon_disrupt_time <= 0.0:
		weapon_disrupt_full = false
	# icMagazine::Simulate 0x10038210: the refire clock is efficiency * dt
	if missiles != null:
		missiles._tick_mags(player_mags, delta)
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
		# the active system radiates onto the PLAYER's external heat store
		for o in objects:
			var cat: String = o["category"]
			if cat == "star" or cat == "body":
				var r: float = o["radius"]
				if r > 0.0:
					var d := Vector3(px - o["x"], py - o["y"],
							pz - o["z"]).length() - r
					sys.add_body_heat(d, r, cat == "star", delta)
		# icAggressorShield::Simulate 0x1002f52a drops the shield the moment the
		# LDS drive reaches state 2 (engaged) -- icShip+0x25c, the icLDSDrive.
		sys.in_lds = lds_state == 2
		sys.simulate(delta)
	_fold_motion()
	_stream_objects()
	_collisions()
	fields.tick(delta)
	_update_grid()
	_update_ldsi_fence()
	_chase_camera(delta)
	if sky_anchor != null:
		sky_anchor.global_position = cam.global_position

# --- read-only views of the damage model, for the HUD -----------------------

func system_states() -> Dictionary:
	# {"DRV": 0..1, ...}; -1 where the hull mounts nothing of that kind
	if sys == null:
		var out: Dictionary = {}
		for g in ShipSystems.GROUPS:
			out[g] = -1.0
		return out
	return sys.group_states()

func shield_bars() -> Array:
	# the tug's two LDAs (shield_upper / shield_lower) as 0..1 charge fractions
	return [] if sys == null else sys.shield_bars()

func armour_rating() -> float:
	return 0.0 if sys == null else sys.armour

func ship_heat() -> float:
	# the HUD player feed (0x10108890): TotalHeat / threshold * 0.8, clamped.
	# Internal-only overheat pegs at 0.8; only sun/planet heat reaches the top.
	if sys == null:
		return 0.0
	return sys.heat_fraction()

func _fire_aggressor() -> void:
	if sys == null:
		return
	if sys.aggressors.is_empty():
		hud.warn("NO AGGRESSOR SHIELD FITTED")
		return
	if sys.aggressor_fire():
		# the aggressor_shield sound INI is an FcThreePartSoundNode keyed on the
		# same "fire" channel Simulate drives (attack aggressor_start, sustain
		# aggressor_loop, decay aggressor_end)
		audio.play("audio/sfx/aggressor_start.wav", -6.0)
		hud.warn("AGGRESSOR SHIELD UP")
	else:
		audio.play("audio/gui/mechanical_deny.wav", -10.0)


# @element icAggressorShield
## The ram. iiSim::OnCollision (0x10078ab0, the shared collision handler at
## 0x1009971c) asks BOTH colliding ships for an icAggressorShield subsim before
## it computes ordinary collision damage; if one of them has a live shield whose
## cone covers the other, that shield handles the collision and the normal damage
## never happens. This is the player's half of it: the AI's aggressors are not
## fitted by any shipped non-player hull.
##
## The program-driven auto-fire comes first (bit 0x1000, aggressor_shield_control):
## with it fitted, the shield fires itself at anything hostile you are about to
## hit. Without it you hold the trigger yourself.
func _aggressor_ram(a: AiShip) -> bool:
	if sys == null or sys.aggressors.is_empty() or not is_instance_valid(a):
		return false
	var d := a.global_position - ship.global_position
	var dist := d.length()
	if dist >= 95.0 or dist < 0.1:
		return false
	# the direction to the victim, in the player's local frame
	var dir_local: Vector3 = ship.global_transform.basis.inverse() * (d / dist)
	sys.aggressor_auto(dir_local, _is_hostile(a))
	var hit: Dictionary = sys.aggressor_hit(dir_local, ship.velocity.length())
	if not bool(hit["handled"]):
		return false
	if a.damage(float(hit["damage"])):
		kill_ai(a)
	# the shield's own ship takes damage * self_damage_factor, source 4
	damage_player(float(hit["self_damage"]), "AGGRESSOR RAM")
	hud.warn("AGGRESSOR SHIELD - %s" % str(a.display_name).to_upper())
	audio.play("audio/sfx/collision.wav", -3.0)
	# push the wreck clear so the same frame does not re-trigger
	var n := d / dist
	ship.global_position = a.global_position - n * 95.0
	return true

func _is_hostile(a: AiShip) -> bool:
	# icShip::IsFriendly is what 0x1002f74a tests; the contact list (_contacts)
	# already uses `behavior == "attack"` as the remaster's hostility test, so
	# the auto-fire uses the same one.
	return a.behavior == "attack"

func _collide_sphere(center: Vector3, radius: float, vel: Vector3,
		what: String) -> void:
	var d := ship.global_position - center
	var dist := d.length()
	if dist >= radius or dist < 0.1:
		return
	var n := d / dist
	var rel: float = (ship.velocity - vel).dot(n)
	if rel < 0.0:
		ship.velocity -= n * rel * 1.6  # bounce off
		damage_player(clampf(-rel * 0.4, 4.0, 250.0),
			"COLLISION - " + what.to_upper())
		audio.play("audio/sfx/collision.wav", -3.0)
		audio.play("audio/sfx/ship_clatter.wav", -8.0)
	ship.global_position = center + n * radius

func damage_player(dmg: float, why: String) -> void:
	# iiSim::ApplyDamage: the raw hull path -- collisions and script damage do
	# not go through armour and do not spall into the subsims
	if sys != null:
		sys.apply_damage(dmg)
	else:
		hull = maxf(hull - dmg, 0.0)
	hud.warn("%s  HULL %d%%" % [why, int(100.0 * hull / hull_max)])
	if hull <= 0.0:
		_kill_player()

func hit_player(spec: Dictionary, age: float, at: Vector3) -> Dictionary:
	# icBullet::OnCollision -> icShip::ApplyWeaponDamage, on the player's hull
	var dmg: float = float(spec.get("damage", 160.0)) \
			/ ShipSystems.age_factor(age, float(spec.get("half_time", 0.35)))
	var pen: float = float(spec.get("penetration", 50.0))
	var out := {"applied": dmg, "deflected": false, "hit": "", "killed": false}
	if sys == null:
		damage_player(dmg, "HULL HIT")
		return out
	var inv := ship.global_transform.affine_inverse()
	var dir := (inv.basis * (at - ship.global_position)).normalized()
	var src: int = ShipSystems.SRC_BYPASS if bool(spec.get("bypass_shields", false)) \
			else ShipSystems.SRC_WEAPON
	out = sys.apply_weapon_damage(dmg, pen, inv * at, dir, src)
	if out["deflected"]:
		hud.warn("SHIELD DEFLECT")
		return out
	var what: String = str(out["hit"])
	if what.is_empty():
		hud.warn("HULL HIT  HULL %d%%" % int(100.0 * hull / hull_max))
	else:
		hud.warn("HULL HIT  %s  HULL %d%%"
				% [_system_label(what), int(100.0 * hull / hull_max)])
	if out["killed"]:
		_kill_player()
	return out

# --- the missile system: player-side plumbing (missiles.gd) -----------------

func _select_secondary(idx: int) -> void:
	secondary_idx = idx if idx >= 0 and idx < player_mags.size() else -1
	if secondary_idx < 0:
		secondary_name = "NONE"
		return
	var mag: Dictionary = player_mags[secondary_idx]
	secondary_name = "%s %d/%d" % [str(mag["projectile"]).replace("_", " ")
			.to_upper(), int(mag["ammo"]), int(mag["max_ammo"])]

## icPlayerPilot::CyclePrimaryWeapon 0x100b0850 -- what Enter is really bound to
## (configs/default.ini [icPlayerPilot.NextPrimaryWeapon] = Keyboard, Return).
## The engine's is four lines and it has one behaviour we did not have:
##
##     if (m_primary(+0x84) != -1) {
##         old = m_current(+0x8c);  m_current = m_primary;
##         if (old != m_secondary(+0x88)) {          // NOT already on a missile
##             GetNextWeapon(channel 1, any=false);  // advance among primaries
##             m_primary = m_current;
##         }
##     }
##
## -- so when a SECONDARY is selected, Enter does not cycle anything: it just
## comes back to the primary you were last on. It only advances when you are
## already holding a primary.
##
## SOUND. The recovered fact is that the engine plays NOTHING here: icPlayerPilot
## contains no sound call of any kind (nothing in 0x100ad000..0x100b2000 touches
## FiSound/FcSoundStreamManager), and IHUDPlayAudioCue (0x100f5400), the only
## exported hook by which non-HUD code could raise a cue, has no callers. What we
## were playing -- audio/gui/mechanical_confirm -- is from the PAUSE MENU's family
## (icShadyBar::SetTargetWidth, 0x1010e6d0, plays audio/gui/expand + contract when
## a menu bar moves), which is why it sounded like clicking Resume. It is gone.
## The cues below are the engine's own HUD table (loaded at 0x100e8220 into
## 0x101740d8, played by FUN_100ea750): 0 valid_input, 1 invalid_input,
## 2 target_changed, 3 missile_warning, 4 klaxon, 5 ping. The HUD's own idiom is
## cue 0 on an accepted input and cue 1 on a refused one (FUN_100efaf0 sets
## exactly that pair from one flag) -- so we use those. That mapping is OURS; the
## original pilot is simply silent.
func _next_primary_weapon(warn := true) -> bool:
	if weapons.groups.is_empty():
		if warn:
			hud.warn("NO PRIMARY WEAPONS")
			audio.play("audio/hud/invalid_input.wav", -8.0)
		return false
	# holding a secondary? Enter drops straight back to the primary.
	if secondary_idx >= 0:
		_select_secondary(-1)
		weapon_name = weapons.group_label()
		hud.log_msg("WEAPON: %s" % weapon_name)
		audio.play("audio/hud/valid_input.wav", -10.0)
		return true
	if not weapons.cycle_group():
		# ONE primary: the engine's loop steps off the end, wraps to the entry it
		# started on, accepts it, and changes nothing. There is nothing to switch
		# to, so we say so instead of pretending we switched.
		if warn:
			audio.play("audio/hud/invalid_input.wav", -8.0)
		return false
	weapon_name = weapons.group_label()
	hud.log_msg("WEAPON: %s" % weapon_name)
	audio.play("audio/hud/valid_input.wav", -10.0)
	return true

func _cycle_secondary() -> void:
	# icPlayerPilot.NextSecondaryWeapon (Backspace / Joy3) steps the ring of
	# fitted magazines. Same cue rule as the primary above.
	if player_mags.is_empty():
		hud.warn("NO SECONDARY WEAPONS")
		audio.play("audio/hud/invalid_input.wav", -8.0)
		return
	if player_mags.size() == 1 and secondary_idx == 0:
		audio.play("audio/hud/invalid_input.wav", -8.0)
		return
	_select_secondary((secondary_idx + 1) % player_mags.size())
	audio.play("audio/hud/valid_input.wav", -10.0)
	hud.log_msg("WEAPON: %s" % secondary_name)

func _fire_secondary() -> void:
	if secondary_idx < 0 or secondary_idx >= player_mags.size():
		return
	# iiWeapon::IsReadyToFire 0x1003cb80: the disrupted flag blocks fire.
	# Shields-only disruption (full_disruption=0, e.g. achillies) only takes
	# the LDA subsims, not the weapons.
	if weapon_disrupt_time > 0.0 and weapon_disrupt_full:
		return
	var mag: Dictionary = player_mags[secondary_idx]
	# the ship-wide overheat flag 0x200 (iiWeapon::Simulate 0x1003cc00)
	if sys != null and sys.heat + sys.heat_external \
			>= ShipSystems.HEAT_DAMAGE_THRESHOLD:
		return
	if missiles.fire_magazine(ship, mag, target_ai):
		_select_secondary(secondary_idx)  # refresh the ammo readout

func fire_ldsi() -> void:
	# LDSIQuickFire: the first LDSi magazine with ammo fires at the target,
	# regardless of the current weapon selection
	if weapon_disrupt_time > 0.0 and weapon_disrupt_full:
		return
	if fire_lock > 0.0:
		# iship.LockDownWeapons locks the quick-fire too, not just the trigger
		return
	for mag in player_mags:
		if bool(mag["ldsi"]):
			if missiles.fire_magazine(ship, mag, target_ai):
				hud.log_msg("LDSI MISSILE AWAY")
			else:
				audio.play("audio/hud/invalid_input.wav", -8.0)
			return
	hud.warn("NO LDSI MISSILES")
	audio.play("audio/hud/invalid_input.wav", -8.0)

func hit_player_warhead(dmg: float, pen: float, at: Vector3) -> Dictionary:
	# the contact-warhead path (icRocket::OnCollision 0x1006ff50):
	# ApplyWeaponDamage with source 2 -- armour and criticals, but the LDA
	# scan only runs for source 0 (icShip::ApplyWeaponDamage 0x10073e2e),
	# so no deflection
	var out := {"applied": dmg, "deflected": false, "hit": "", "killed": false}
	if sys == null:
		damage_player(dmg, "MISSILE HIT")
		return out
	var inv := ship.global_transform.affine_inverse()
	var dir := (inv.basis * (at - ship.global_position)).normalized()
	out = sys.apply_weapon_damage(dmg, pen, inv * at, dir, 2)
	hud.warn("MISSILE HIT  HULL %d%%" % int(100.0 * hull / hull_max))
	if out["killed"]:
		_kill_player()
	return out

func disrupt_player_systems(seconds: float, full: bool) -> void:
	# icShip::Disrupt via icMissile::CheckForDisruption 0x1006d0b0: the
	# weapons lock out here, and ship_systems raises the subsim disrupted
	# flag (efficiency reads zero, the LDA stops deflecting and recharging).
	weapon_disrupt_time = maxf(weapon_disrupt_time, seconds)
	weapon_disrupt_full = weapon_disrupt_full or full
	if sys != null:
		sys.disrupt(seconds, full)
	hud.warn("SYSTEMS DISRUPTED" if full else "SHIELDS DISRUPTED", 3.0)
	audio.play("audio/sfx/disruptor_startup.wav", -6.0)

func _system_label(name: String) -> String:
	# subsim names are localisation keys ("Cargo_ShipsDrive", "system_lda_shield")
	var s := name.get_slice("_", 0)
	if s == "Cargo" or s == "system":
		s = name.substr(name.find("_") + 1)
	else:
		s = name
	return s.to_upper()

func _kill_player() -> void:
	ExplosionFx.boom(self, ship.global_position, 60.0)
	hud.warn("SHIP DESTROYED - resetting", 5.0)
	if sys != null:
		for s in sys.systems:
			s["hp"] = s["hp_max"]
	hull = hull_max
	ship.velocity = Vector3.ZERO
	ship.set_speed = 0.0

func _model_bounds_radius(model: Node3D) -> float:
	# bounding-sphere radius of an instanced model (must be in the tree)
	var merged := AABB()
	var first := true
	for mi in model.find_children("*", "MeshInstance3D", true, false):
		var bb: AABB = (mi as MeshInstance3D).get_aabb()
		var xf: Transform3D = (mi as Node3D).global_transform
		xf = model.global_transform.affine_inverse() * xf
		var tb := xf * bb
		merged = tb if first else merged.merge(tb)
		first = false
	return 0.0 if first else merged.size.length() * 0.5

func _model_coll_spheres(model: Node3D) -> Array:
	# one collision sphere per major mesh chunk (model-local), so sprawling
	# structures like Hoffer's Gap are solid where their geometry actually
	# is — a single capped sphere either blocked docking or did nothing
	var spheres: Array = []
	var inv := model.global_transform.affine_inverse()
	for mi in model.find_children("*", "MeshInstance3D", true, false):
		var bb: AABB = (mi as MeshInstance3D).get_aabb()
		var tb := (inv * (mi as Node3D).global_transform) * bb
		var r := tb.size.length() * 0.4
		if r < 25.0:
			continue  # greebles/lights don't need physics
		spheres.append({"c": tb.get_center(), "r": minf(r, 1500.0)})
	spheres.sort_custom(func(a, b): return a["r"] > b["r"])
	return spheres.slice(0, 24)

func _model_radius(model: Node3D, fallback: float) -> float:
	# collision sphere for a streamed avatar — the map/record radii are
	# zone numbers, not hull sizes
	var r := _model_bounds_radius(model)
	if r <= 0.0:
		return fallback
	# spheres are crude: cap so docking approaches (and the F6 autopilot's
	# 600 m arrival) still get inside; big-station avatars also carry
	# far-flung light nulls that would blow the AABB up to km scale
	return clampf(r * 0.66, minf(fallback, 400.0) * 0.5, 450.0)

func _collisions() -> void:
	if docked_at != "" or jump_state >= 2:
		return
	# The base's docking cutscene flies the ship THROUGH the station's hull and
	# parks it inside the bay, so the ship must not collide with anything while
	# it runs. That is not a fudge: iBackToBase.DockingCutscene calls
	# `sim.SetCollision(player, 0)` the moment it takes the ship (pogsrc/
	# ibacktobase.pog, at the dolly setup) and the detector calls it again before
	# it places the ship inside the base. Without it you fly into the hull at
	# 300 m/s -- which is exactly what happened.
	if base_iface != null and base_iface.cut > 0:
		return
	for a in ai_ships:
		if _aggressor_ram(a):
			continue
		_collide_sphere(a.global_position, 95.0, a.velocity, str(a.display_name))
	for o in objects:
		if o["node"] == null:
			continue
		if o["category"] == "station" or o["category"] == "gunstar" \
				or o.get("prop_collide", false):
			var base := Vector3(o["x"] - px, o["y"] - py, o["z"] - pz)
			var spheres: Array = o.get("coll_spheres", [])
			if spheres.is_empty():
				_collide_sphere(base, o["radius"] + 45.0, Vector3.ZERO,
					str(o["name"]))
			else:
				for s in spheres:
					_collide_sphere(base + (s["c"] as Vector3),
						float(s["r"]) + 25.0, Vector3.ZERO, str(o["name"]))
	var demand: float = absf(ship.set_speed - ship.forward_speed()) \
		/ maxf(ship.max_speed.z, 1.0) + absf(ship.input_thrust.z)
	audio.set_engine_level(demand + ship.set_speed / ship.max_speed.z * 0.1)
	audio.set_thruster_level(Vector2(ship.input_thrust.x, ship.input_thrust.y).length()
		+ ship.input_rotate.length() * 0.5)

func _key(code: int) -> float:
	return 1.0 if Input.is_physical_key_pressed(code) else 0.0

# --- the view zoom is GATED ON HARDWARE (task #62) -----------------------------
# @element zoom
# `icPlayerPilot::EnableZoom` (0x100b0e80) is the whole gate, and it grants the
# zoom two ways:
#
#     cpu = ship->m_cpu (+0x29c)
#     if      (cpu == NULL)                 reason = E_NoCPU        (0x42)
#     else if (!(cpu->programs & 0x2000))   reason = E_NoZoomProgram(0x28)
#     else if (!cpu->IsWorking())           reason = E_CPUOffline   (0x41)
#     else                                  GRANTED
#     if (!granted) granted = GotSniperWeapon(&reason)
#     if (granted) { reason = E_ZoomEnabled (0x26); m_zoom_target = max_zoom_factor }
#     if (reason < 0x69) icLog::LogEvent(reason)
#
# 0x2000 = 8192 = the imaging_module program bit. So: a WORKING CPU carrying the
# imaging module, OR a sniper weapon -- and the user's hunch was right, it is ship
# hardware, both ways.
#
# `GotSniperWeapon` (0x100b14d0) is the second door: the CURRENTLY SELECTED weapon
# must be a working gun with `sniper_zoom` set (iiGun::SniperZoom, 0x1000f0b0,
# gun+0xc5), and if the selection is an icWeaponLink it walks the link's members
# and takes ANY working sniper gun in it. A sniper gun that is present but dead
# reports E_WeaponDamaged (0x1e). Only one weapon in the game sets the flag:
# subsims/systems/player/long_range_pbc.ini, the long-range 'Sniper' PBC.
#
# The event ids are icLog's (table at 0x10167558, stride 0x10, built at
# 0x100a89a0); the refusal TEXT is the game's own, from data/text/log_addendum.csv.
# THE CONSEQUENCE, stated plainly: the stock tug carries NEITHER. Its CPU has
# `programs = 0` (tug_prefitted.ini fits no icProgram at all) and none of its
# seven weapons sets `sniper_zoom`, so the recovered gate REFUSES the zoom
# outright -- and that is exactly what the original does to a fresh campaign
# pilot. icLoadout::LoadComputerPrograms (0x10095ea0) only fits a program the
# player already OWNS as cargo, and the campaign gives away just two of them
# (stealth, and the hyperspace tracker), never the imaging module. You BUY the
# zoom in IW2, either as `Cargo_ImagingModule` or as the long-range 'Sniper' PBC.
#
# The difference is that the original has a cargo/fitting screen and we have not
# ported one, so there is currently no way to earn either. Flip this to true to
# hand the player's CPU an imaging module at fit time. It is a LOADOUT decision,
# not a mechanic -- the gate above stays exactly as recovered either way -- and
# it is the only invented byte in this file.
const GRANT_IMAGING_MODULE := false

const ZOOM_NO_CPU := "ERROR: NO COMPUTER FITTED"          # E_NoCPU 0x42
const ZOOM_NO_PROGRAM := "ERROR: IMAGING MODULE NOT INSTALLED"  # E_NoZoomProgram 0x28
const ZOOM_CPU_OFFLINE := "ERROR: COMPUTER OFFLINE"       # E_CPUOffline 0x41
const ZOOM_WEAPON_DAMAGED := "WEAPON DAMAGED"             # E_WeaponDamaged 0x1e
const ZOOM_ENABLED := "IMAGING MODULE ACTIVATED"          # E_ZoomEnabled 0x26
const ZOOM_DISABLED := "IMAGING MODULE DEACTIVATED"       # E_ZoomDisabled 0x27

## icPlayerPilot::GotSniperWeapon 0x100b14d0, as a tri-state:
##   0 = the selection carries no sniper gun at all
##   1 = a WORKING sniper gun is selected (the zoom is granted)
##   2 = a sniper gun is selected but it is dead (reason -> E_WeaponDamaged)
func _sniper_state() -> int:
	if sys == null or weapons == null:
		return 0
	var g: Dictionary = weapons.current_group()
	if g.is_empty():
		return 0
	var damaged := 0
	for m: Dictionary in (g["members"] as Array):
		if not bool(m.get("sniper_zoom", false)):
			continue
		# iiShipSystem::IsWorking (vtable slot 13) -- the vf 0x34 that both
		# EnableZoom and GotSniperWeapon call on the gun.
		if not bool(m["destroyed"]) and float(m["efficiency"]) > 0.0:
			return 1           # ANY working sniper gun in the link is enough
		damaged = 2
	return damaged

## The refusal reason, or "" when the zoom may engage. Same order as EnableZoom:
## the CPU path is tested first, GotSniperWeapon second, and a broken sniper gun
## overwrites whatever the CPU path had to say (its out-param, 0x100b1653).
func _zoom_allowed() -> String:
	if sys == null:
		return ""              # no fitted hull (the bare demo ship): don't gate
	var sniper := _sniper_state()
	if sniper == 1:
		return ""
	var reason := ""
	if not sys.has_cpu():
		reason = ZOOM_NO_CPU
	elif not sys.has_program(ShipSystems.PROG_IMAGING):
		reason = ZOOM_NO_PROGRAM
	elif not sys.cpu_working():
		reason = ZOOM_CPU_OFFLINE
	else:
		return ""              # a working CPU carrying the imaging module
	if sniper == 2:
		reason = ZOOM_WEAPON_DAMAGED
	return reason

## icPlayerPilot::EnableZoom 0x100b0e80.
func _enable_zoom(on: bool) -> void:
	if on == zoomed:
		return                 # `if (param_1 == (1.0 < zoom_factor)) return;`
	if not on:
		# 0x100b0f20: the disable path snaps target AND factor to 1.0 -- there is
		# no ramp out.
		zoomed = false
		zoom_factor = 1.0
		hud.log_msg(ZOOM_DISABLED)
		return
	var reason := _zoom_allowed()
	if not reason.is_empty():
		hud.warn(reason, 3.0)
		audio.play("audio/hud/invalid_input.wav", -8.0)
		return
	zoomed = true
	hud.log_msg(ZOOM_ENABLED)

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
	# ThrottleDelta is a rate on the throttle FRACTION: `throttle += v * dt *
	# 0.3333` clamped to [0,1] (the 1/3 is the float at 0x10119454). A full sweep
	# is three seconds, and the throttle is a fraction of max speed, not m/s.
	var dv := ship.max_speed.z * delta / 3.0
	ship.set_speed = clampf(ship.set_speed
		+ (_key(KEY_EQUAL) + _key(KEY_KP_ADD)) * dv
		- (_key(KEY_MINUS) + _key(KEY_KP_SUBTRACT)) * dv,
		0.0, ship.max_speed.z)
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
		# THRUSTERS, not steering. LateralX = D / A, LateralZ = W / S. LateralY
		# has no keyboard binding in either shipped config -- it is joystick-only
		# (JoyYAxis with the ALT modifier), so vertical strafe is left unbound.
		ship.input_thrust.z = _key(KEY_W) - _key(KEY_S)
		ship.input_thrust.x = _key(KEY_D) - _key(KEY_A)
		ship.input_thrust.y = 0.0
		# keyboard_only.ini: NumPad6 = +Yaw, NumPad8 = +Pitch, NumPad3 = +Roll,
		# and the `inverse` twins are the negative half of each axis. +Pitch is
		# NOSE DOWN: the joystick binding is `JoyYAxis, inverse`, and an inverted
		# DirectInput Y is positive when the stick is pushed forward.
		var yaw := _key(KEY_KP_6) - _key(KEY_KP_4)
		var pitch := _key(KEY_KP_8) - _key(KEY_KP_2)
		var roll := _key(KEY_KP_3) - _key(KEY_KP_1)
		# RollYawToggleHold swaps the yaw and roll channels
		if roll_yaw_swap:
			var t := yaw
			yaw = roll
			roll = t
		# Godot's local axes: +x pitches the nose UP, +y yaws LEFT, +z rolls LEFT
		if absf(yaw) > 0.0:
			ship.input_rotate.y = -yaw / zoom_factor
		if absf(pitch) > 0.0:
			ship.input_rotate.x = -pitch / zoom_factor
		ship.input_rotate.z = -roll
		ship.input_rotate.x = move_toward(ship.input_rotate.x, 0.0, delta * 1.5)
		ship.input_rotate.y = move_toward(ship.input_rotate.y, 0.0, delta * 1.5)
	# free flight: N toggles, LeftCtrl / NumPad5 holds (FreeToggle/FreeHold)
	ship.assist = not (free_toggle or Input.is_physical_key_pressed(KEY_CTRL)
		or Input.is_physical_key_pressed(KEY_KP_5))
	if (Input.is_key_pressed(KEY_SPACE)
			or Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)) \
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

# --- targeting (original contact-list semantics) ----------------------------

func _contacts_full() -> Array:
	var list: Array = []
	for i in objects.size():
		var o: Dictionary = objects[i]
		# isim.SetSensorVisibility(sim, false): the scripts hide a sim from
		# sensors to stage an ambush, so it must not reach the contact list.
		if o.get("sensor_hidden", false):
			continue
		var d := Vector3(o["x"] - px, o["y"] - py, o["z"] - pz).length()
		var show := false
		match o["category"]:
			"station", "gunstar":
				show = d < 5.0e5
			"lpoint":
				show = d < 1.0e7
		if show:
			list.append({"kind": "obj", "idx": i, "dist": d})
	for a in ai_ships:
		list.append({"kind": "ai", "ai": a, "dist": a.global_position.length()})
	list.sort_custom(func(x, y): return x["dist"] < y["dist"])
	return list

func _current_contact_pos(list: Array) -> int:
	for i in list.size():
		var e: Dictionary = list[i]
		if e["kind"] == "ai" and e["ai"] == target_ai and target_ai != null:
			return i
		if e["kind"] == "obj" and e["idx"] == target_idx and target_idx >= 0:
			return i
	return -1

func _set_contact(e: Dictionary) -> void:
	if e["kind"] == "ai":
		target_ai = e["ai"]
		target_idx = -1
	else:
		target_idx = e["idx"]
		target_ai = null
	audio.play("audio/hud/target_changed.wav", -10.0)

func _cycle_contact(dir: int) -> void:
	var list := _contacts_full()
	if list.is_empty():
		return
	var pos := _current_contact_pos(list)
	_set_contact(list[clampi(pos + dir, 0, list.size() - 1)]
		if pos >= 0 else list[0])

func _target_contact_index(i: int) -> void:
	var list := _contacts_full()
	if list.is_empty():
		return
	_set_contact(list[clampi(i, 0, list.size() - 1)])

func _target_nearest_enemy() -> void:
	var best: AiShip = null
	var bestd := INF
	for a in ai_ships:
		if a.behavior == "attack" and a.global_position.length() < bestd:
			bestd = a.global_position.length()
			best = a
	if best != null:
		target_ai = best
		target_idx = -1
		audio.play("audio/hud/target_changed.wav", -10.0)
	else:
		audio.play("audio/hud/invalid_input.wav", -10.0)

func _cycle_enemy() -> void:
	var enemies: Array = []
	for a in ai_ships:
		if a.behavior == "attack":
			enemies.append(a)
	if enemies.is_empty():
		audio.play("audio/hud/invalid_input.wav", -10.0)
		return
	var idx := enemies.find(target_ai)
	target_ai = enemies[(idx + 1) % enemies.size()]
	target_idx = -1
	audio.play("audio/hud/target_changed.wav", -10.0)

func _target_nearest_to_direction() -> void:
	var fwd := -ship.global_transform.basis.z
	var best := {}
	var besta := 0.6  # ~35 degree cone
	for e in _contacts_full():
		var p: Vector3
		if e["kind"] == "ai":
			p = e["ai"].global_position
		else:
			var o: Dictionary = objects[e["idx"]]
			p = Vector3(o["x"] - px, o["y"] - py, o["z"] - pz)
		var a := fwd.angle_to(p.normalized())
		if a < besta:
			besta = a
			best = e
	if not best.is_empty():
		_set_contact(best)
	else:
		audio.play("audio/hud/invalid_input.wav", -10.0)

# --- autopilots (F5-F9, iAI order packages) ---------------------------------

func _set_autopilot(mode: int) -> void:
	if mode != 0 and _target_pos() == Vector3.INF and mode != 3:
		hud.warn("AUTOPILOT: NO TARGET")
		audio.play("audio/hud/invalid_input.wav", -8.0)
		return
	# icPlayerPilot::SetAutopilot (0x100af930): you cannot formate on something
	# that has no thrusters. The engine silently downgrades Formate to Approach
	# when the target is not an iiThrusterSim -- so F7 on a station approaches it.
	if mode == 2 and target_ai == null:
		mode = 1
	if mode == 0:
		_disengage_autopilot()
	else:
		ap_mode = mode
	audio.play("audio/gui/confirm.wav", -10.0)
	var names := ["OFF", "APPROACH", "FORMATE", "DOCK", "MATCH VELOCITY"]
	hud.log_msg("AUTOPILOT: %s" % names[mode])

## Hand the throttle back. The autopilot writes set_speed every tick, so on
## release it is whatever the autopilot last wanted -- not what the ship is
## actually doing. Leaving it there means the throttle wheel appears dead: the
## ship jumps to the stale demand the moment you nudge it, or sits at a demand it
## has already reached. Handing it back at the current speed makes the wheel pick
## up exactly where the autopilot left off. Every path that drops the autopilot
## goes through here.
func _disengage_autopilot() -> void:
	ap_mode = 0
	ship.set_speed = clampf(maxf(ship.forward_speed(), 0.0),
		0.0, ship.max_speed.z)
	ship.input_thrust = Vector3.ZERO
	ship.input_rotate = Vector3.ZERO

## FiSim::BoundsRadius for anything in the world. A ship's is its model's
## bounding sphere (the engine builds it from the avatar the same way); a map
## record carries its own authored radius.
func sim_bounds_radius(node: Node3D) -> float:
	if node == null or not is_instance_valid(node):
		return 0.0
	if not _bounds_cache.has(node.get_instance_id()):
		var r := 0.0
		for c in node.get_children():
			if c is Node3D:
				r = maxf(r, _model_bounds_radius(c as Node3D))
		_bounds_cache[node.get_instance_id()] = SHIP_HIT_RADIUS if r <= 0.0 else r
	return _bounds_cache[node.get_instance_id()]


## The PogSim handle for whatever the player has targeted, so the marker maths
## can see its class (planet / star / nebula / belt) and its radius.
func _target_sim() -> PogWorld.PogSim:
	if pog_world == null:
		return null
	if target_ai != null and is_instance_valid(target_ai):
		return pog_world._wrap_ship(target_ai)
	if target_idx >= 0 and target_idx < objects.size():
		return pog_world._wrap_record(objects[target_idx])
	return null


## icAIServices::InnerMarkerRadius(player_ship, target) -- the autopilot's real
## break-off distance. See docs/original.md section 4a.
func _target_marker() -> float:
	if pog_world == null:
		return 0.0
	return PogWorld.inner_marker_radius(pog_world.player_sim(), _target_sim())

func _autopilot_process(delta: float) -> void:
	var p := _target_pos()
	if ap_mode == 3 and p == Vector3.INF:
		var near := _nearest("station")
		if near.get("dist", INF) < INF:
			for i in objects.size():
				if objects[i] == near:
					target_idx = i
					target_ai = null
			p = _target_pos()
	if p == Vector3.INF:
		_disengage_autopilot()   # the target went away under us
		return
	var dist := p.length()
	_face_target()
	# The player's autopilot IS the AI order system: icPlayerPilot::
	# EngageAutopilotApproach (0x100afbc0) calls icAIServices::DefaultApproach
	# and pushes an "AutopilotApproach" order onto the player's own icAIPilot.
	# So the break-off is the same marker sphere the AI flies to, and it is
	# derived from the TARGET -- a fighter breaks off at ~300 m, a station at a
	# kilometre or two, a planet thousands of kilometres out.
	var marker := _target_marker()
	# like the original: approach/dock autopilots engage LDS for long
	# transits once the nose is on target (LDS cruise already brakes and
	# drops out near the destination)
	if ap_mode in [1, 3] and lds_state == 0 and jump_state == 0 \
			and dist > 8.0e4 and _lds_clearance() > 1000.0 \
			and (-ship.global_transform.basis.z).angle_to(p.normalized()) < 0.05:
		_toggle_lds()
	match ap_mode:
		1:  # approach: fly to the marker sphere and stop on it
			var togo := dist - marker
			if lds_state == 0:
				ship.set_speed = clampf(togo / 8.0, 0.0, ship.max_speed.z)
			# the engine settles onto the sphere and completes within
			# min(marker*0.05, 0.5) m of it; we arrive rather than settle, so the
			# slop is floored at icAITarget::m_waypoint_approach_distance (20 m)
			if togo <= maxf(PogWorld.completion_tolerance(marker), 20.0):
				ship.set_speed = 0.0
				_set_autopilot(0)
				hud.log_msg("APPROACH COMPLETE")
		2:  # formate: hold station on the marker sphere, matching velocity
			var tvel := Vector3.ZERO
			if target_ai != null and is_instance_valid(target_ai):
				tvel = target_ai.velocity
			# DefaultFormate (0x10056520) uses the same InnerMarkerRadius
			var hold := clampf((dist - marker) * 0.5, 0.0, ship.max_speed.z)
			ship.set_speed = clampf(tvel.length() + hold, 0.0, ship.max_speed.z)
		3:  # dock: approach then hard-dock
			if lds_state == 0:
				ship.set_speed = clampf((dist - marker) / 6.0, 0.0, ship.max_speed.z)
			if dist < DOCK_RANGE * 0.8:
				_set_autopilot(0)
				_try_dock()
		4:  # match velocity
			var tv := Vector3.ZERO
			if target_ai != null and is_instance_valid(target_ai):
				tv = target_ai.velocity
			ship.set_speed = clampf(tv.length(), 0.0, ship.max_speed.z)
			if tv.length() < 1.0:
				ship.set_speed = 0.0

func _lds_process(delta: float) -> void:
	# The TRI's DRIVE axis reaches the LDS drive too (icLDSDrive is eType 0), and
	# icLDSDrive::Simulate (0x10037040) spends it in BOTH halves:
	#   spin-up  0x10037224:  still spooling while `elapsed <= spinup_time / w`
	#                         -- the spool time is DIVIDED by the weight
	#   ramp     0x1003746e:  `speed = (w * rate * dt + 1) * speed` -- an
	#                         exponential whose rate is MULTIPLIED by the weight
	# so full drive gets you into LDS in 2/3 the time and accelerates 1.5x harder.
	var wd := 1.0
	if sys != null:
		wd = sys.tri_weight(ShipSystems.TRI_DRIVE)
	if lds_state == 1:
		lds_timer += delta
		if lds_timer >= LDS_SPOOL / maxf(wd, 1e-3):
			lds_state = 2
			audio.play_loop(audio.lds_player, "audio/sfx/lds_cruise.wav", -10.0)
		return
	# our ramp is pow(base, dt); the original's is exp(w * rate * dt), so the
	# weight belongs in the exponent
	lds_speed = minf(lds_speed * pow(LDS_RAMP, delta * wd), LDS_MAX)
	var clear := _lds_clearance()
	var tdist := _target_distance()
	if (tdist < lds_speed * 1.5 and tdist < INF) or clear < 0.0:
		lds_speed = maxf(tdist * 1.5, LDS_BASE)
	lds_speed = minf(lds_speed, LDS_MAX)
	ship.velocity = -ship.global_transform.basis.z * lds_speed
	if clear < 0.0 or (tdist < 4.0e4 and lds_speed <= LDS_BASE * 2.0):
		_drop_out_of_lds()

func _drop_out_of_lds() -> void:
	# icLDSDrive::BreakShipOutOfLDS (decompiled): zero the angular
	# velocity and set linear velocity to facing x 1000 m/s flat
	lds_state = 0
	audio.lds_player.stop()
	audio.play("audio/sfx/lds_rampdown.wav", -4.0)
	ship.velocity = -ship.global_transform.basis.z * LDS_DROPOUT_SPEED
	ship.angular_velocity = Vector3.ZERO
	ship.input_rotate = Vector3.ZERO
	# auto-deceleration (original option, default on): the flight computer
	# zeroes the throttle wheel so the ship brakes instead of barreling on
	ship.set_speed = 0.0

func _fold_motion() -> void:
	var p := ship.global_position
	px += p.x
	py += p.y
	pz += p.z
	ship.global_position = Vector3.ZERO
	cam.global_position -= p
	drop_cam_pos -= p
	weapons.shift_world(p)
	missiles.shift_world(p)
	for fx in get_tree().get_nodes_in_group("worldfx"):
		fx.shift_world(p)
	for a in ai_ships:
		a.global_position -= p

func _stream_objects() -> void:
	# the original funnels only the nearest L-point
	# (icPlayerContactList::NearestLagrangePoint feeds icHUDLagrangeIcon)
	var near_lp: Dictionary = _nearest("lpoint", SpaceFx.LP_DRAW_DIST)
	for o in objects:
		var dx: float = o["x"] - px
		var dy: float = o["y"] - py
		var dz: float = o["z"] - pz
		var d2 := dx * dx + dy * dy + dz * dz
		match o["category"]:
			"body", "star":
				if o["node"] == null:
					continue
				# always visible: drawn at capped distance, scaled to keep
				# the correct angular size (the camera far plane is 600 km)
				var dist := sqrt(maxf(d2, 1.0))
				# the record's own FiSim radius. No floor, no clamp: the map
				# says what size the body is.
				var r: float = o["radius"]
				if o["category"] == "star":
					sun.look_at_from_position(Vector3.ZERO,
						Vector3(-dx, -dy, -dz).normalized())
				var k := minf(IMPOSTOR_DIST / dist, 1.0)
				# never fill the screen: cap apparent radius vs draw distance
				var draw_r := minf(r * k, IMPOSTOR_DIST * 0.4)
				o["node"].position = Vector3(dx, dy, dz) * k
				o["node"].scale = Vector3.ONE * maxf(draw_r, 1.0)
			"station", "prop", "gunstar":
				if o["node"] == null and d2 < STREAM_IN * STREAM_IN:
					# POG can create a sim that carries no avatar (a pure logic
					# marker); there is nothing to stream in for those.
					if str(o.get("avatar", "")).is_empty():
						continue
					var model := _load_gltf("data/avatars/" + o["avatar"])
					if model == null:
						continue
					o["node"] = model
					add_child(model)
					o["coll_spheres"] = _model_coll_spheres(model)
					# A station's map record carries no radius -- the byte at
					# +0x138 belongs to its parent body (docs/geography.md), so
					# the decoder zeroes it. The engine gets a station's
					# FiSim::Radius the same way it gets any sim's: from the
					# avatar. Everything that reasons about the station's size --
					# above all the approach marker the autopilot breaks off at --
					# needs it, so stamp it the moment the model exists.
					if float(o.get("radius", 0.0)) <= 0.0:
						o["radius"] = _model_bounds_radius(model)
				elif o["node"] != null and d2 > STREAM_OUT * STREAM_OUT:
					o["node"].queue_free()
					o["node"] = null
				if o["node"] != null:
					o["node"].position = Vector3(dx, dy, dz)
			"lpoint":
				if o["node"] == null and d2 < STREAM_IN * STREAM_IN:
					o["node"] = _spawn_beacon(o)
				elif o["node"] != null and d2 > STREAM_OUT * STREAM_OUT:
					o["node"].queue_free()
					o["node"] = null
				if o["node"] != null:
					o["node"].position = Vector3(dx, dy, dz)
					# _nearest always stamps "dist", so has("name") is the
					# only reliable "did it find one" test
					var lit: bool = near_lp.has("name") \
						and near_lp["name"] == o["name"]
					SpaceFx.update_lagrange_icon(o["node"], cam, lit)

func _chase_camera(delta: float) -> void:
	var target := ship.global_transform
	if jump_state == 4:
		_capsule_camera(delta, target)
		return
	# inside Lucrecia's Base the camera is the diorama's own, out of the scene
	if base_iface != null and base_iface.inside:
		base_iface.place_camera()
		return
	if base_root != null:
		# in the hangar: gantry viewpoint with a gentle sway
		var a := Time.get_ticks_msec() / 1000.0 * 0.11
		var pos := target.origin + Vector3(-150.0 + sin(a) * 35.0, 70.0,
			-180.0 + cos(a * 0.7) * 25.0)
		cam.global_transform = Transform3D(Basis.IDENTITY, pos).looking_at(
			target.origin + Vector3(0, 0, 0), Vector3.UP)
		return
	# the target the "look at the target" cameras (inverse tactical, target
	# external) frame; without one they fall back to their forward-looking twin
	var tp := _target_pos()
	match cam_name():
		"cockpit", "no_cockpit":  # rigid at the pilot's eye (the crew null)
			cam.global_transform = target.translated_local(eye)
		"arcade":  # icArcadeCamera: hull-following, range 4 (defaults.ini)
			var pos := target.origin + target.basis * Vector3(0, 12, 55)
			cam.global_transform = Transform3D(target.basis, pos)
		"tactical":
			var want := target.translated_local(Vector3(0, 32, 130))
			if lds_state == 2 or jump_state >= 2:
				cam.global_transform = want.looking_at(
					target.origin + target.basis * Vector3(0, 6, -30), target.basis.y)
			else:
				cam.global_transform = cam.global_transform.interpolate_with(
					want, 1.0 - exp(-8.0 * delta))
				cam.global_transform = cam.global_transform.looking_at(
					target.origin + target.basis * Vector3(0, 6, -30), target.basis.y)
		"inverse_tactical":  # over the nose, looking back at the ship
			var want := target.translated_local(Vector3(0, 20, -130))
			cam.global_transform = cam.global_transform.interpolate_with(
				want, 1.0 - exp(-8.0 * delta))
			cam.global_transform = cam.global_transform.looking_at(
				target.origin, target.basis.y)
		"external":  # slow orbit around the ship
			var a := Time.get_ticks_msec() / 1000.0 * 0.15
			var pos := target.origin + Vector3(cos(a), 0.25, sin(a)) * 180.0
			cam.global_transform = Transform3D(Basis.IDENTITY, pos).looking_at(
				target.origin, Vector3.UP)
		"target_external":  # orbit the ship, but framed on the current target
			var a := Time.get_ticks_msec() / 1000.0 * 0.15
			var pos := target.origin + Vector3(cos(a), 0.25, sin(a)) * 180.0
			var look: Vector3 = target.origin + (-target.basis.z * 1000.0 \
				if tp == Vector3.INF else (tp - target.origin).normalized() * 1000.0)
			cam.global_transform = Transform3D(Basis.IDENTITY, pos).looking_at(
				look, Vector3.UP)
		"drop":  # fixed in space, tracking the ship
			cam.global_transform = Transform3D(Basis.IDENTITY,
				drop_cam_pos).looking_at(target.origin, Vector3.UP)

## The capsule-space camera. icDirector event 0x10 ("in capsule space",
## cued every frame by PerformJumps case 5 via FUN_100426f0) selects camera
## 24 (response table @ 0x1011d498: ev 0x10 -> cams (24,24,24), priority 8,
## re-cuttable). Camera 24 (ctor FUN_100dc080 @ 0x100dc080, Update @
## 0x100dc160) frames the ship from a random direction in the SHIP's frame,
## components ([0.8,1], [-1,1], [-1,1]) normalized -- biased to the ship's
## +X side -- at 4 x the focus radius (0x101190b4), with FOV 2 * 0.35 rad
## (_DAT_1011d378). Cuts are limited by flux.ini [icDirector]
## min_cut_time = 1. The final second cues event 0x11 -> camera 3,
## cam_internal_no_hud (name table @ 0x101621e0): back inside the cockpit
## for the exit flash.
func _capsule_camera(delta: float, target: Transform3D) -> void:
	if jump_timer >= jump_duration - 1.0:
		# cam_internal_no_hud: back inside the cockpit, HUD stays dark
		if cockpit != null:
			cockpit.visible = true
		if ship_model != null:
			ship_model.visible = false
		cam.fov = FOV_INTERNAL
		cam.global_transform = target.translated_local(eye)
		return
	# external shot: show the hull, drop the cockpit dressing
	if cockpit != null:
		cockpit.visible = false
	if ship_model != null:
		ship_model.visible = true
	_cap_cut_t -= delta
	if _cap_cut_t <= 0.0:
		_cap_cut_t = CAPSULE_CUT_TIME
		_cap_cam_dir = Vector3(randf_range(0.8, 1.0),
			randf_range(-1.0, 1.0), randf_range(-1.0, 1.0)).normalized()
	cam.fov = CAPSULE_CAM_FOV
	var r := _model_bounds_radius(ship_model)
	if r <= 0.0:
		r = SHIP_HIT_RADIUS
	var pos := target.origin + target.basis * (_cap_cam_dir
		* r * CAPSULE_CAM_RANGE)
	cam.global_transform = Transform3D(Basis.IDENTITY, pos).looking_at(
		target.origin, target.basis.y)

func _fmt_dist(d: float) -> String:
	if d < 1e4:
		return "%.0f m" % d
	if d < 1e7:
		return "%.1f km" % (d / 1e3)
	if d < 1e10:
		return "%.1f Mm" % (d / 1e6)
	return "%.2f AU" % (d / 1.496e11)

func _headless() -> bool:
	return DisplayServer.get_name() == "headless"

func _face_target() -> void:
	# demo autopilot: steer via the flight model, like a real pilot would
	var p := _target_pos()
	if p == Vector3.INF:
		return
	var local := p * ship.global_transform.basis
	var pitch := atan2(local.y, -local.z)
	var yaw := atan2(-local.x, -local.z)
	ship.input_rotate.x = clampf(pitch * 2.0, -1.0, 1.0)
	ship.input_rotate.y = clampf(yaw * 2.0, -1.0, 1.0)
