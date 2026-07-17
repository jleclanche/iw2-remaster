class_name BaseInterior
extends Node

## Lucrecia's Base -- the campaign's home base: contact-list presence, the
## go-home dock, the docking cutscene, the long-range AUTOSKIP, and the
## interior (the diorama montage the base screens sit on).
##
## Everything here is recovered. The two sources are:
##
##  * `ibacktobase.pog` -- the whole go-home system, and the only script that
##    ever runs it. Read `data/pogsrc/ibacktobase.pog` (or the port,
##    `pog/gen/ibacktobase.gd`); the function names below are its own.
##  * `icSPPlayerBaseScreen` -- the base interior. It is NOT a screen: it is an
##    `iiGUIOverlayManager` (iwar2 `FcRegistry::RegisterClass` @ 0x10023710,
##    ctor @ 0x10024000) that loads five 3D "diorama" scenes, renders one behind
##    the GUI, and raises `icSPBaseScreen` -- the base menu -- on top of it
##    (`FcGame::AddOverlayScreen("icSPBaseScreen")` @ 0x10024cca, which settles
##    what docs/original.md could only infer). Its config lives in the shipped
##    `defaults.ini` under `[icSPPlayerBaseScreen]`.
##
## docs/screens.md carries the evidence log.


# --- iBackToBase.Detector (pogsrc/ibacktobase.pog:4) -------------------------
#
#   loop every 2.1 s:
#     if dist(player, base) < 200 km:
#         make sure the player has a "system_refuel_port" dockport (the script's
#         own comment calls it the "bodge dockport" -- without it you cannot
#         dock with the base at all)
#         if dist < 20 km and the player's current AI order is DOCK(4) on the
#         base  ->  confirm, then play the DOCKING CUTSCENE
#     else (>= 200 km):
#         destroy the bodge dockport again
#         if DOCK(4) ordered on the base, and the LDS drive is not inhibited,
#         and the director is not busy, and g_ibacktobase_level <= 0
#             ->  confirm, then AUTOSKIP home and play the docking cutscene
#
#   "confirm" is a 10-second sanity countdown, one check a second: the dock
#   order must still be on the base, the LDS must still not be inhibited, the
#   director must still be idle, and (autoskip only) the inhibit level must
#   still be 0. Any failure aborts and the detector goes back to watching.
const POLL := 2.1                 ## Detector's task.Sleep
const NEAR_RANGE := 200000.0      ## the 200 km near/far split
const DOCK_TRIGGER := 20000.0     ## inside this, docking is taken over
const CONFIRM_SECONDS := 10       ## the sanity countdown
const ORDER_DOCK := 4             ## iai.CurrentOrderType == 4

# --- the AUTOSKIP (ibacktobase local_3520) ----------------------------------
const SKIP_LDS_DISRUPT := 120.0   ## iship.DisruptLDSDrive(player, 120)
const SKIP_NEAR := 10000.0        ## sim.PlaceNear(player, base, 10000)
const SKIP_STANDOFF := Vector3(3000.0, 2000.0, 15000.0)  ## PlaceRelativeTo
const SKIP_SPEED := 400.0         ## SetVelocityLocalToSim(0,0,400)
const SKIP_HOLD := 5.0            ## task.Sleep(5) on the fly-by camera
const SKIP_FADE := 1.0            ## idirector.FadeOut(1,0,0,0)

# --- the docking cutscene (ibacktobase.DockingCutscene) ---------------------
const DOCK_LDS_DISRUPT := 1.0     ## iship.DisruptLDSDrive(player, 1)
const DOCK_START := 2900.0        ## PlaceRelativeTo(player, base, 0, 0, 2900)
const DOCK_BAY := 1800.0          ## PlaceRelativeToInside(wp, base, 0, 0, 1800)
const DOCK_SPEED := 300.0         ## object.SetVectorProperty(player,"speed",0,0,300)
const DOCK_ACCEL := 50.0          ## ...,"acceleration",0,0,50
const DOCK_ARRIVE := 50.0         ## poll until DistanceBetween(player, wp) <= 50
const DOCK_SETTLE := 1.0          ## task.Sleep(1) after the doors stop
const DOCK_HOLD := 11.0           ## task.Sleep(11) on the final framing shot
const DOCK_DOORS := 2.0           ## task.Sleep(2) before the approach order

## The framing offsets the cutscene's last shot uses, per hull. The switch is on
## isim.Type(player) and it is the same switch iStartSystem.FinalSetup uses to
## name the ship, which is what identifies each constant:
##   [x, y, z] = the (v9, v10, v11) the script feeds PlaceRelativeToInside.
const DOCK_FRAMING := {
	"command_section": Vector3(-1.1, 0.0, 14.0),    # isim.Type 131072
	"storm_petrel": Vector3(0.0, 0.0, 8.0),         # 8388608
	"tug": Vector3(-1.1, -14.0, 35.0),              # 2097152
	"fast_attack": Vector3(-1.1, 0.0, 44.0),        # 4194304
	"heavy_corvette": Vector3(-1.1, 0.0, 60.0),     # 16777216
}

# --- the interior: [icSPPlayerBaseScreen] in the shipped defaults.ini --------
const FRITZ_DELAY := 0.5          ## fritz_delay = 0.5
const DIORAMA_DELAY := 30.0       ## diorama_delay = 30

## The five dioramas, in the order the ctor copies their config URLs into its
## array (iwar2 @ 0x100242d9: main_bay, office_interior, jafs, smith, gunbabes),
## which is the index the screen map below hands to SetDiorama (0x10025540).
##
##  * `scene` is the config URL (`main_bay_url = lws:/avatars/base/setup` ...),
##    converted.
##  * `key` is the localised name the manager reads out of `csv:/text/dioramas`
##    (the key table @ 0x1015a6bc); data/text/dioramas.csv gives the words. The
##    manager draws that name as a clickable label and clicking it cuts to the
##    NEXT diorama (0x10025500, wired at 0x100253fb).
##  * `cam` / `rot` / `hfov` are the scene's own camera, out of the original
##    LightWave scene (resource.zip avatars/base/Setup*.lws): the world
##    transform of the camera at frame 0, and its ZoomFactor as a horizontal
##    FOV (LightWave: hfov = 2*atan(1/zoom)).
const DIORAMAS: Array = [
	{"scene": "setup", "key": "diorama_main_bay", "name": "MAIN BAY",
		"cam": Vector3(0.0, -75.0, -1487.5), "rot": Vector3(0.0, 180.0, 0.0),
		"hfov": 58.11},                                     # zoom 1.8
	{"scene": "setup_cal", "key": "diorama_office_interior", "name": "CONTROL ROOM",
		"cam": Vector3(-2.91, 1.33, 124.31), "rot": Vector3(-5.2, -24.0, 0.0),
		"hfov": 37.86},                                     # zoom 2.916
	{"scene": "setup_jafs", "key": "diorama_jafs", "name": "LOADING DOCK",
		"cam": Vector3(-32.87, -233.37, -850.2), "rot": Vector3(1.8, -22.6, 0.0),
		"hfov": 39.31},                                     # zoom 2.8
	{"scene": "setup_smith", "key": "diorama_smith", "name": "WORKSHOP",
		"cam": Vector3(-1.32, 0.73, -0.72), "rot": Vector3(-10.4, -147.2, 0.2),
		"hfov": 36.87},                                     # zoom 3.0
	{"scene": "setup_gb", "key": "diorama_gunbabes", "name": "CREW LOUNGE",
		"cam": Vector3(4.29, -1.25, 13.08), "rot": Vector3(0.7, 17.2, 0.0),
		"hfov": 24.02},                                     # zoom 4.7
]

## Which diorama each hosted screen shows. Straight out of the hash map the
## overlay manager's ctor builds (iwar2 0x100243b7 .. 0x100249f6): each entry is
## a class-name string and the int written into the node's value slot.
const SCREEN_DIORAMA := {
	"icSPBaseScreen": 0,
	"icSPCommsMainMenuScreen": 1, "icSPComputerCommsScreen": 1,
	"icSPInboxScreen": 1, "icSPArchiveScreen": 1, "icSPMessagesScreen": 1,
	"icSPEncyclopaediaScreen": 1, "icSPComputerPuzzleScreen": 1,
	"icSPComputerTradingScreen": 2, "icSPInventoryScreen": 2,
	"icSPAddCargoScreen": 2, "icSPRecyclingScreen": 2,
	"icSPManufacturingScreen": 2,
	"icSPHangarScreen": 3, "icSPLoadoutScreen": 3, "icSPManifestScreen": 3,
	"icSPShipTypeScreen": 3,
	"icSPCustomiseScreen": 4, "icSPStatisticsScreen": 4,
}

## `lights_global = g_base_lights_on` / `dioramas_global = g_show_dioramas`, and
## the two light channels the manager switches between (0x10024d35..0x10024dc0:
## the global set  -> baselights_normal = 1, emergency = 0; clear -> the reverse).
const LIGHTS_GLOBAL := "g_base_lights_on"
const DIORAMAS_GLOBAL := "g_show_dioramas"
const LIGHT_NORMAL := "baselights_normal"
const LIGHT_EMERGENCY := "baselights_emergency"

const BASE_NAME := "Lucrecia's Base"

## The three systems the base record exists in. iBackToBase.Initialise names all
## three by hand and hides the base in every one of them before showing the one
## in g_player_base_system (pogsrc/ibacktobase.pog:284).
const BASE_SYSTEMS := ["hoffers_wake", "santa_romera", "formhault"]

## istartsystem.pog:494 -- global.CreateString("g_player_base_system", 2,
## "map:/geog/badlands/hoffers_wake").
const DEFAULT_BASE_SYSTEM := "hoffers_wake"

var main: Node3D

# --- detector state ---------------------------------------------------------
var _poll := 0.0
var _confirm := -1.0        ## >= 0 while the 10-second sanity countdown runs
var _confirm_skip := false  ## the confirmation is for the AUTOSKIP, not the dock
var enabled := true         ## Initialise's act/found-base gate
## isim.SetStandardSensorVisibility(base, 1): the mission that leads you to the
## base puts it on sensors before the found-base flag is set. mission.gd's
## `reveal_base` step is that call. The base is then in the contact list and can
## be docked at -- but iBackToBase is still disabled, so there is no autoskip.
var revealed := false

# --- cutscene state ---------------------------------------------------------
## 0 idle, 1 autoskip fly-by, 2 approach run, 3 final framing shot
var cut := 0
var _cut_t := 0.0
## The dock waypoint, in ABSOLUTE map coordinates. The world is folded around the
## player, so a folded vector goes stale the moment the ship moves.
var _cut_target := Vector3.ZERO


## An absolute map position, as seen from the ship (folded space).
func _folded(abs_pos: Vector3) -> Vector3:
	return abs_pos - Vector3(main.px, main.py, main.pz) \
		- main.ship.global_position

# --- interior state ---------------------------------------------------------
var inside := false     ## docked at the base (the shutdown movie may still run)
var open := false       ## the movie is over and the interior is up
var diorama := -1
var _fritz := 0.0            ## the 0.5 s flash after a diorama change
var _dio_t := 0.0            ## counts down diorama_delay, then cuts to the next
var _dio_root: Node3D = null
## The class name of the screen the manager last saw (this+0x540).
var _last_screen := ""
var _hidden: Array = []      ## world nodes we hid while inside
var _saved_env: Dictionary = {}  ## the environment we overrode while inside


func _pog_globals() -> Dictionary:
	if main == null:
		return {}
	if main.pog_rt != null and main.pog_rt.std != null:
		return main.pog_rt.std.globals
	if main.pog_std != null:
		return main.pog_std.globals
	return {}


func _gflag(name: String) -> bool:
	var g := _pog_globals()
	return bool(int(g.get(name, 0))) if g.has(name) else false


## `map:/geog/badlands/hoffers_wake` -> `hoffers_wake`. The base's system is a
## POG global, and the campaign MOVES it: istartsystem.MovePlayerBase(from, to)
## (pogsrc/istartsystem.pog:1332) writes this global, hides the base record in
## the system it left and shows the one in the system it arrived at. The shipped
## itinerary, from the ported acts:
##    Act 0-1  Hoffer's Wake      (istartsystem.pog:494, the initial value)
##    Act 2    -> Santa Romera    (iacttwo.gd:6557 / 6845, after the L-point run)
##    Act 3    -> Formhault       (iactthree.gd:239)
##    Act 3    -> Santa Romera    (iactthree.gd:3508, the finale)
func base_system() -> String:
	var g := _pog_globals()
	var s := str(g.get("g_player_base_system", ""))
	if s.is_empty():
		return DEFAULT_BASE_SYSTEM
	return s.get_slice("/", s.get_slice_count("/") - 1)


## iBackToBase.Initialise's gate. Act 0 needs g_act0_found_base, act 1 needs
## g_act1_found_base; from act 2 on the base is simply known. Until the flag is
## set the whole system is disabled -- no contact-list entry, no go-home dock,
## no autoskip. That is what "you have to find it first" is, mechanically:
##   * act 0: iact0mission10 (Clay's run out to the base) sets g_act0_found_base
##     and plays /movies/PBDiscovery;
##   * act 1: iact1mission01 (Smith walks you in) sets g_act1_found_base, names
##     the station "Lucrecia's Base" and plays /movies/PB_Beauty.
func found() -> bool:
	var g := _pog_globals()
	var act := int(g.get("g_current_act", 0))
	if act == 0:
		return _gflag("g_act0_found_base")
	if act == 1:
		return _gflag("g_act1_found_base")
	return true


## The record for the base in the system we are actually in, or {}.
func base_rec() -> Dictionary:
	if main == null:
		return {}
	for o in main.objects:
		if str(o["name"]) == BASE_NAME:
			return o
	return {}


func base_pos() -> Vector3:
	var r := base_rec()
	if r.is_empty():
		return Vector3.INF
	return Vector3(r["x"] - main.px, r["y"] - main.py, r["z"] - main.pz)


## Contact-list presence. iBackToBase.Initialise:
##   isim.SetSensorVisibility(base in hoffers_wake, 0)
##   isim.SetSensorVisibility(base in santa_romera, 0)
##   isim.SetSensorVisibility(base in gagarin/formhault, 0)
##   isim.SetSensorVisibility(base in g_player_base_system, 1)
## -- so the base is on sensors (and therefore in the contact list) in exactly
## one system at a time, and only once the act's found-base flag is set. Called
## after every _load_system, and whenever the base moves.
func apply_visibility() -> void:
	enabled = found()
	var rec := base_rec()
	if rec.is_empty():
		return
	var here: bool = (enabled or revealed) and main.system_stem == base_system()
	rec["sensor_hidden"] = not here
	if rec.get("node", null) != null and is_instance_valid(rec["node"]):
		# imapentity.SetHidden: the base is not drawn in the systems it is not in
		(rec["node"] as Node3D).visible = here


# --- the detector -----------------------------------------------------------

## Can the player dock here at all? The base has to be in this system and on
## sensors. (iStartSystem.local_207, the dock watcher that raises the interior,
## polls `isim.IsDockedTo(base, player)` and nothing else -- so docking at the
## base always takes you inside it, even in act 0 before it is "found".)
func dockable() -> bool:
	var rec := base_rec()
	return not rec.is_empty() and not bool(rec.get("sensor_hidden", false))


## Is the player's autopilot flying a DOCK order at the base? The player's
## autopilot IS the AI order system (icPlayerPilot::EngageAutopilotDock pushes an
## order onto the player's own icAIPilot), so the script's
## `iai.CurrentOrderType(player) == 4 && iai.CurrentOrderTarget(player) == base`
## is, here, "ap_mode == 3 and the target is the base".
func _dock_ordered() -> bool:
	if main.ap_mode != 3 or main.target_ai != null:
		return false
	if main.target_idx < 0 or main.target_idx >= main.objects.size():
		return false
	return str(main.objects[main.target_idx]["name"]) == BASE_NAME


func _blocked() -> bool:
	# iship.IsLDSInhibited(player) || idirector.IsBusy() || g_ibacktobase_level > 0
	var g := _pog_globals()
	if int(g.get("g_ibacktobase_level", 0)) > 0:
		return true
	if main.in_cutscene():
		return true
	return main._lds_clearance() <= 0.0


func process(delta: float) -> void:
	_door_process(delta)
	if inside:
		if open:
			_interior_process(delta)
		return
	if cut > 0:
		_cutscene_process(delta)
		return
	if not enabled or main.docked_at != "":
		return
	var bp := base_pos()
	if bp == Vector3.INF:
		return
	if main.system_stem != base_system():
		return
	if _confirm >= 0.0:
		_confirm_process(delta, bp)
		return
	_poll += delta
	if _poll < POLL:
		return
	_poll = 0.0
	var d := bp.length()
	if d < NEAR_RANGE:
		if d < DOCK_TRIGGER and _dock_ordered():
			_confirm = float(CONFIRM_SECONDS)
			_confirm_skip = false
	elif _dock_ordered() and not _blocked():
		_confirm = float(CONFIRM_SECONDS)
		_confirm_skip = true
		main.hud.log_msg("BASE RETURN: PLOTTING COURSE")


## The Detector's 10-second sanity countdown, one check a second.
func _confirm_process(delta: float, bp: Vector3) -> void:
	var was := ceili(_confirm)
	_confirm -= delta
	if not _dock_ordered():
		_confirm = -1.0
		return
	if _confirm_skip and _blocked():
		_confirm = -1.0
		main.hud.log_msg("BASE RETURN ABORTED")
		return
	if ceili(_confirm) != was and _confirm_skip:
		main.hud.warn("BASE RETURN IN %d" % maxi(ceili(_confirm), 0))
	if _confirm > 0.0:
		return
	_confirm = -1.0
	_begin_cutscene(bp)


func _begin_cutscene(_bp: Vector3) -> void:
	main._set_autopilot(0)
	main.ship.velocity = Vector3.ZERO
	main.ship.set_speed = 0.0
	# iship.DisruptLDSDrive(player, 120) on the autoskip, (player, 1) on the
	# short dock -- either way the drive is locked out for the cutscene.
	main.disrupt_time = SKIP_LDS_DISRUPT if _confirm_skip else DOCK_LDS_DISRUPT
	if _confirm_skip:
		_autoskip_jump()
		cut = 1
	else:
		_place_for_approach()
		cut = 2
	_cut_t = 0.0


## local_3520, the AUTOSKIP. Over 200 km out the script does not fly you home: it
## FADES OUT, teleports the ship to the base (sim.PlaceNear(player, base, 10000),
## then PlaceRelativeTo(player, base, 3000, 2000, 15000)), points it at the base,
## opens the landing-gear channel ("lz"), gives it 400 m/s, fades back IN on the
## dolly camera for 5 seconds -- a fly-by beauty shot of home -- fades out again
## and hands over to the docking cutscene. That is the whole trick: a cut, a
## teleport and one 5-second shot. There is no time compression and no auto-LDS.
func _autoskip_jump() -> void:
	var rec := base_rec()
	var b := _base_basis(rec)
	# the world is folded around the player, so moving the player IS moving the
	# fold origin
	var world := Vector3(rec["x"], rec["y"], rec["z"]) + b * Vector3(
		SKIP_STANDOFF.x, SKIP_STANDOFF.y, -SKIP_STANDOFF.z)
	main.px = world.x
	main.py = world.y
	main.pz = world.z
	main.ship.global_position = Vector3.ZERO
	main._point_ship_at(base_pos())
	main.ship.velocity = -main.ship.global_transform.basis.z * SKIP_SPEED
	main.ship.set_speed = SKIP_SPEED
	main.cam_mode = 2   # the director's dolly: an external beauty shot
	main.cam_view = 0
	main._apply_view()
	main.hud.log_msg("BASE RETURN: %s" % BASE_NAME.to_upper())


## DockingCutscene's opening: the player is placed at base-local (0, 0, 2900) --
## 2900 m out along the base's axis -- pointed at it, and given a 300 m/s run in
## to a waypoint at base-local (0, 0, 1800), which is inside the bay. (The bay is
## about 1500 m deep: the main-bay diorama's own camera sits at z = -1487.5.)
func _place_for_approach() -> void:
	var rec := base_rec()
	var b := _base_basis(rec)
	var centre := Vector3(rec["x"], rec["y"], rec["z"])
	var start := centre + b * Vector3(0.0, 0.0, -DOCK_START)
	main.px = start.x
	main.py = start.y
	main.pz = start.z
	main.ship.global_position = Vector3.ZERO
	main._point_ship_at(base_pos())
	_cut_target = centre + b * Vector3(0.0, 0.0, -DOCK_BAY)
	main.ship.velocity = Vector3.ZERO
	main.ship.set_speed = 0.0
	_set_door(true)
	main.cam_mode = 2
	main.cam_view = 0
	main._apply_view()


func _base_basis(rec: Dictionary) -> Basis:
	if main.has_method("_record_basis"):
		return main._record_basis(rec)
	return Basis.IDENTITY


## Escape. The original's cutscenes all run inside
## `icutsceneutilities.HandleAbort`, which polls the `g_cutscene_skip` global and
## halts the cutscene task -- and iBackToBase's detector then goes straight on to
## the lines *after* HandleAbort: blackout, place the ship inside the base, raise
## the base screen. So a skip does not cancel the dock; it cuts to the end of it.
func skip_cutscene() -> void:
	if cut == 0:
		return
	cut = 0
	_cut_t = 0.0
	_set_door(false)
	_door = 0.0
	main.ship.velocity = Vector3.ZERO
	main.hud.log_msg("CUTSCENE SKIPPED")
	enter()


func _cutscene_process(delta: float) -> void:
	_cut_t += delta
	match cut:
		1:  # the autoskip fly-by: 5 seconds, then hand to the docking cutscene
			main.ship.velocity = -main.ship.global_transform.basis.z * SKIP_SPEED
			if _cut_t >= SKIP_HOLD + SKIP_FADE:
				_place_for_approach()
				cut = 2
				_cut_t = 0.0
		2:  # the run in to the bay waypoint
			var to: Vector3 = _folded(_cut_target)
			var d: float = to.length()
			if _cut_t < DOCK_DOORS:
				# task.Sleep(2) with the doors opening before the approach order
				main.ship.velocity = Vector3.ZERO
				return
			main._point_ship_at(to)
			var sp: float = minf(DOCK_SPEED,
				DOCK_ACCEL * (_cut_t - DOCK_DOORS) + 40.0)
			main.ship.velocity = to.normalized() * minf(sp, maxf(d, 1.0))
			main.ship.set_speed = 0.0
			# poll until DistanceBetween(player, waypoint) <= 50
			if d <= DOCK_ARRIVE:
				main.ship.velocity = Vector3.ZERO
				_set_door(false)
				cut = 3
				_cut_t = 0.0
		3:  # the final framing shot, then the blackout and the interior
			main.ship.velocity = Vector3.ZERO
			if _cut_t >= DOCK_SETTLE + DOCK_HOLD:
				cut = 0
				enter()


## THE BASE OPENS ITS DOORS.
##
## `avatars/player_base/setup.lws` carries an `OuterDoorMasterNull` and four
## `<anim channel=door?+s(0.1)>` nulls -- the engine's channel-driven pose
## interpolators: each node has two authored poses and sits between them at the
## value of the named channel, smoothed with a time constant (`s(0.1)`). The
## mobile base (`player_base_mobile`) is the same rig at `s(0.5)`.
##
## The docking cutscene drives it by name, and nothing else does:
##     sim.AvatarAddChannel(base, "door", 0)
##     sim.AvatarSetChannel(base, "door", 1)          <- the doors open
##     sim.AvatarAddChannel(base, "base_doors_sound", 1)
##     ... the ship flies in ...
##     sim.AvatarSetChannel(base, "base_doors_sound", 0)
##     sim.AvatarSetChannel(base, "door", 0)          <- and close behind it
##     sim.AvatarSetChannel(base, "base_doors_sound", 1)
##
## So this sets the CHANNEL and lets the authored poses do the animating.
## (ShipEffects has this evaluator already, but it is bound to a ShipFlight and
## the base is a map record, so the two-pose lerp is repeated here rather than
## reaching into a file this task does not own. Generalising ShipEffects to any
## avatar would let both share it.)
var _door := 0.0        ## the live channel value, 0 shut .. 1 open
var _door_want := 0.0
var _door_nodes: Array = []   ## [{node, p0, q0, s0, p1, q1, s1}, ...]
var _door_tau := 0.1          ## the `s(0.1)` in the channel expression


func _scan_doors() -> void:
	_door_nodes.clear()
	var rec := base_rec()
	var node: Variant = rec.get("node", null)
	if node == null or not is_instance_valid(node):
		return
	for n in (node as Node3D).find_children("*", "Node3D", true, false):
		if not n.has_meta("extras"):
			continue
		var ex: Dictionary = n.get_meta("extras")
		var ch := str(ex.get("iw2_channel", ""))
		if str(ex.get("iw2_kind", "")) != "anim" or not ch.begins_with("door"):
			continue
		if not (ex.has("iw2_pose0") and ex.has("iw2_pose1")):
			continue
		var tau := ch.get_slice("s(", 1).get_slice(")", 0)
		if tau.is_valid_float():
			_door_tau = maxf(float(tau), 0.01)
		var p0: Dictionary = ex["iw2_pose0"]
		var p1: Dictionary = ex["iw2_pose1"]
		_door_nodes.append({"node": n,
			"p0": _v3(p0["pos"]), "q0": _quat(p0["quat"]), "s0": _v3(p0["scale"]),
			"p1": _v3(p1["pos"]), "q1": _quat(p1["quat"]), "s1": _v3(p1["scale"])})


static func _v3(a) -> Vector3:
	return Vector3(float(a[0]), float(a[1]), float(a[2]))


static func _quat(a) -> Quaternion:
	return Quaternion(float(a[0]), float(a[1]), float(a[2]), float(a[3]))


func _door_process(delta: float) -> void:
	if _door_nodes.is_empty():
		return
	# `s(tau)`: an exponential approach to the demanded value, tau seconds
	_door = _door + (_door_want - _door) \
		* clampf(delta / maxf(_door_tau, 0.01), 0.0, 1.0)
	for d in _door_nodes:
		var n: Node3D = d["node"]
		if not is_instance_valid(n):
			continue
		n.transform = Transform3D(
			Basis((d["q0"] as Quaternion).slerp(d["q1"], _door)).scaled(
				(d["s0"] as Vector3).lerp(d["s1"], _door)),
			(d["p0"] as Vector3).lerp(d["p1"], _door))


## sim.AvatarSetChannel(base, "door", open) + the `base_doors_sound` emitter the
## LWS carries alongside the door nulls
## (`<node template=ini||audio|sfx|base_doors_sound>`).
func _set_door(open: bool) -> void:
	if _door_nodes.is_empty():
		_scan_doors()
	_door_want = 1.0 if open else 0.0
	if main.audio != null:
		main.audio.play("audio/sfx/base_doors_sound.wav", -4.0)


# --- the interior -----------------------------------------------------------

## Docked. The end of the detector's run:
##   igame.EnableBlackout(1); sim.SetCollision(player, 0); zero its velocity;
##   sim.PlaceRelativeToInside(player, base, 0, 0, 1800); sim.PointAt(player, base)
##   gui.SetScreen("icSPPlayerBaseScreen")
##   igame.PlayMovie(act == 0 ? "/movies/YoungCalShutdown" : "/movies/OldCalShutdown")
##
## The shutdown movie is Cal powering the ship down -- YOUNG Cal in act 0, and
## the older Cal from act 1 on (ibacktobase.pog:150; istartsystem's own dock
## watcher, local_207, plays exactly the same pair when you dock at the base by
## any other route).
func enter() -> void:
	if inside:
		return
	inside = true
	main.docked_at = BASE_NAME
	# the detector's own last act, after the cutscene (or after a skip):
	#   igame.EnableBlackout(1); sim.SetCollision(player, 0);
	#   sim.SetVelocity(player, 0,0,0);
	#   sim.PlaceRelativeToInside(player, base, 0, 0, 1800); sim.PointAt(player, base)
	var rec := base_rec()
	if not rec.is_empty():
		var b := _base_basis(rec)
		var park := Vector3(rec["x"], rec["y"], rec["z"]) \
			+ b * Vector3(0.0, 0.0, -DOCK_BAY)
		main.px = park.x
		main.py = park.y
		main.pz = park.z
		main.ship.global_position = Vector3.ZERO
		main._point_ship_at(base_pos())
	main.ship.velocity = Vector3.ZERO
	main.ship.set_speed = 0.0
	main._set_autopilot(0)
	var g := _pog_globals()
	var act := int(g.get("g_current_act", 0))
	var stem := "youngcalshutdown" if act == 0 else "oldcalshutdown"
	main.audio.music("ambient")
	main._play_movie(stem, func() -> void: _open_interior())


func _open_interior() -> void:
	if not inside:
		return
	open = true
	_hide_world()
	# gui.SetScreen("icSPPlayerBaseScreen"). PogUi's AUTO_OVERLAY raises the
	# overlay manager's hosted menu, icSPBaseScreen, on top of it -- which is
	# what the manager itself does at 0x10024cca -- and the menu is built by the
	# original script, ibasegui.SPBaseScreen. From there the player's own buttons
	# reach the hangar (choose your ship), the loadout and cargo screens, the
	# comms/inbox (email) and the trading screen: they are all already wired
	# (natives/ui.gd, natives/economy.gd), and they are all hosted screens of
	# this manager, so each one swings the camera to its own diorama.
	if main.pog_rt != null:
		main.pog_rt.native("gui.setscreen", ["icSPPlayerBaseScreen"])
	set_diorama(_screen_diorama())
	main.hud.log_msg("DOCKED: %s" % BASE_NAME.to_upper())


## Leaving. iStartSystem's launch cutscene (local_486) plays the STARTUP movie
## -- YoungCalStartup in act 0, OldCalStartup after -- and then flies the ship
## out of the tube. We play the movie and hand the ship back outside the bay.
func leave() -> void:
	if not inside:
		return
	inside = false
	open = false
	diorama = -1
	_last_screen = ""
	_show_world()
	_free_diorama()
	if main.pog_rt != null:
		main.pog_rt.native("gui.clearallscreens", [])
	var g := _pog_globals()
	var act := int(g.get("g_current_act", 0))
	var stem := "youngcalstartup" if act == 0 else "oldcalstartup"
	main._play_movie(stem, func() -> void: _launch())


## local_486's exit: sim.PlaceRelativeTo(player, base, 12000, 0, -1000),
## sim.PointAway(player, base), SetVelocityLocalToSim(0, 0, 500).
func _launch() -> void:
	var rec := base_rec()
	if rec.is_empty():
		return
	var b := _base_basis(rec)
	var world := Vector3(rec["x"], rec["y"], rec["z"]) \
		+ b * Vector3(12000.0, 0.0, 1000.0)
	main.px = world.x
	main.py = world.y
	main.pz = world.z
	main.ship.global_position = Vector3.ZERO
	main._point_ship_at(-base_pos())
	main.ship.velocity = -main.ship.global_transform.basis.z * 500.0
	main.ship.set_speed = 500.0
	main.cam_mode = 0
	main.cam_view = 0
	main._apply_view()
	main.clock_start = Time.get_ticks_msec()
	main.hud.log_msg("LAUNCHED")


## The class name of the screen on top of the game's screen stack.
func _screen_name() -> String:
	if main.pog_rt == null:
		return ""
	return str(main.pog_rt.native("gui.currentscreenclassname", []))


## The screen the manager is showing -> the diorama it wants. Unmapped screens
## fall back to 0, exactly as the ctor's default does (0x10024de9: SetDiorama(0)).
func _screen_diorama() -> int:
	return int(SCREEN_DIORAMA.get(_screen_name(), 0))


## SetDiorama (0x10025540): if that diorama was never loaded, fall back to 0; if
## it changed, restart the fritz and diorama timers and play the camera-change
## sound (`sound:/audio/gui/camera_change`, the string @ 0x1015aa78).
func set_diorama(i: int) -> void:
	if not _dioramas_on() and i != 0:
		i = 0
	if i == diorama:
		return
	diorama = i
	_fritz = FRITZ_DELAY
	_dio_t = DIORAMA_DELAY
	_load_diorama(i)
	if main.audio != null:
		main.audio.play("audio/gui/camera_change.wav", -8.0)


## 0x10025500: step to the next loaded diorama, wrapping mod 5. The manager calls
## this when the diorama timer runs out and when the player clicks the room name.
func next_diorama() -> void:
	if not _dioramas_on():
		return
	set_diorama((diorama + 1) % DIORAMAS.size())


## `dioramas_global = g_show_dioramas`. With it clear, the loader only ever loads
## diorama 0 (0x10024b95: load if show_dioramas OR i == 0) -- so during the
## campaign the base interior is the MAIN BAY and nothing else. The global is set
## by iStartSystem.SetPlayerBaseMoviesVisible, and the only script that ever turns
## it ON is iactthree.gd:3524, at the very end of act 3, as the game hands over to
## FreeRoam. The other four rooms are a post-campaign reward.
func _dioramas_on() -> bool:
	return _gflag(DIORAMAS_GLOBAL)


func _interior_process(delta: float) -> void:
	if _fritz > 0.0:
		_fritz = maxf(_fritz - delta, 0.0)
	# The manager keeps the class name of the screen it last saw (this+0x540).
	# When the CURRENT screen's name differs from it, it looks the new screen up
	# in the map and cuts to that diorama (0x10024e2c..0x10024ea3). When it does
	# NOT differ -- the player is sitting on one screen -- it runs the diorama
	# timer down instead and cuts to the NEXT room (0x10024eaa). That is the
	# montage: park on the base menu and the rooms rotate every 30 seconds.
	var scr := _screen_name()
	if scr != _last_screen:
		_last_screen = scr
		set_diorama(int(SCREEN_DIORAMA.get(scr, 0)))
		return
	_dio_t -= delta
	if _dio_t <= 0.0:
		next_diorama()


## The flash the manager draws over the diorama for fritz_delay seconds after a
## cut, fading out (0x10025472: alpha = timer / fritz_delay).
func fritz_alpha() -> float:
	return 0.0 if _fritz <= 0.0 else _fritz / FRITZ_DELAY


func room_name() -> String:
	if diorama < 0 or diorama >= DIORAMAS.size():
		return ""
	return str(DIORAMAS[diorama]["name"])


func _load_diorama(i: int) -> void:
	_free_diorama()
	if i < 0 or i >= DIORAMAS.size():
		return
	var rec: Dictionary = DIORAMAS[i]
	_dio_root = main._load_gltf("data/avatars/avatars/base/%s.gltf"
		% str(rec["scene"]))
	if _dio_root == null:
		return
	main.add_child(_dio_root)
	_dio_root.position = Vector3.ZERO
	# the light channels: g_base_lights_on picks the normal bank, and its
	# absence the emergency one (0x10024d35). The other switch channels are the
	# five player hulls parked in the main bay: the manager shows the one the
	# player owns and hides the rest (the same per-hull switch DOCK_FRAMING uses).
	var normal := _gflag(LIGHTS_GLOBAL)
	var hull := _player_hull()
	var bank: Node3D = null   # the ACTIVE baselights switch, if the scene has one
	for n in _dio_root.find_children("*", "Node3D", true, false):
		if not n.has_meta("extras"):
			continue
		var ex: Dictionary = n.get_meta("extras")
		var ch := str(ex.get("iw2_channel", ""))
		if str(ex.get("iw2_kind", "")) == "switch":
			if ch == LIGHT_NORMAL:
				(n as Node3D).visible = normal
				if normal:
					bank = n
			elif ch == LIGHT_EMERGENCY:
				(n as Node3D).visible = not normal
				if not normal:
					bank = n
			elif ch in DOCK_FRAMING:
				(n as Node3D).visible = ch == hull
	# The five scenes are authored at wildly different scales -- the main bay is
	# 3 km across, Smith's bench is 5 m -- and the converted lights carry their
	# LightWave intensity but no falloff (LightWave's default light has none, so
	# it lit the whole set). Range is therefore taken from the scene's own
	# bounds, and energy from the light's authored intensity. Lens flares
	# (intensity 0, iw2_lens_flare) are not lights and are skipped.
	var span: float = maxf(_scene_span(_dio_root), 1.0)
	var lights := 0
	for n in _dio_root.find_children("*", "Node3D", true, false):
		if not n.has_meta("extras"):
			continue
		var ex: Dictionary = n.get_meta("extras")
		if str(ex.get("iw2_kind", "")) != "light":
			continue
		var power := float(ex.get("iw2_intensity", 0.0))
		if power <= 0.0 or lights >= 32 or not (n as Node3D).is_visible_in_tree():
			continue
		var col := Color(1, 1, 1)
		if ex.has("iw2_color"):
			var c: Array = ex["iw2_color"]
			col = Color(c[0] / 255.0, c[1] / 255.0, c[2] / 255.0)
		if int(ex.get("iw2_light_type", 1)) == 0:
			# a LightWave DISTANT light: a directional flood, not a lamp. The
			# main bay's whole emergency look is two of these (red key + fill).
			var dl := DirectionalLight3D.new()
			dl.light_color = col
			dl.light_energy = power
			n.add_child(dl)
		else:
			var l := OmniLight3D.new()
			l.light_color = col
			# LightWave sums its lights; a room with a dozen 1.0 lamps in it
			# would blow out at full strength here, so the authored intensity is
			# shared out across the lights the scene actually has.
			l.light_energy = power * 0.5
			l.omni_range = span * 0.6
			l.omni_attenuation = 1.2
			n.add_child(l)
		lights += 1
	var bank_dark: bool = bank != null \
		and bank.find_children("*", "Light3D", true, false).is_empty()
	if lights == 0 or bank_dark:
		# every lamp in the active bank is a lens flare (the powered main bay:
		# searchlights and trough lights, all intensity 0) -- the original's
		# renderer had LW's scene ambient to fall back on; give the room a soft
		# neutral key so it reads at all
		var key := DirectionalLight3D.new()
		key.light_color = Color(0.9, 0.92, 1.0)
		key.light_energy = 0.55
		key.rotation_degrees = Vector3(-40.0, 30.0, 0.0)
		_dio_root.add_child(key)


## Which of the main bay's five hull switches is the player's current ship.
## The original switches on isim.Type(player); our equivalent identity is the
## fitted hull's sim INI (main.player_ship_ini).
func _player_hull() -> String:
	var ini: String = main.player_ship_ini.get_file()
	for ch in DOCK_FRAMING:
		if ini.begins_with(str(ch)):
			return str(ch)
	if ini.begins_with("comsec") or ini.begins_with("escape_tug"):
		return "command_section"
	return "command_section" if ini.is_empty() else "tug"


## The diagonal of everything the scene draws, in its own units.
func _scene_span(root: Node3D) -> float:
	var box := AABB()
	var first := true
	for n in root.find_children("*", "VisualInstance3D", true, false):
		var vi := n as VisualInstance3D
		var b := vi.global_transform * vi.get_aabb()
		if first:
			box = b
			first = false
		else:
			box = box.merge(b)
	return box.size.length()


func _free_diorama() -> void:
	if _dio_root != null and is_instance_valid(_dio_root):
		_dio_root.queue_free()
	_dio_root = null


## The diorama's own camera, out of its LightWave scene. Called from
## main._chase_camera while the interior is up.
func place_camera() -> void:
	if diorama < 0 or diorama >= DIORAMAS.size() or main.cam == null:
		return
	var rec: Dictionary = DIORAMAS[diorama]
	var r: Vector3 = rec["rot"]
	var t := Transform3D(Basis.from_euler(Vector3(deg_to_rad(r.x),
		deg_to_rad(r.y), deg_to_rad(r.z)), EULER_ORDER_YXZ), rec["cam"])
	main.cam.keep_aspect = Camera3D.KEEP_WIDTH
	main.cam.fov = float(rec["hfov"])
	main.cam.near = 0.05
	main.cam.global_transform = t


## The interior is its own place: the manager renders the diorama's scene graph
## and nothing else. Take the world away while we are in it, and put it back on
## the way out.
func _hide_world() -> void:
	_hidden.clear()
	# The interior is lit by the diorama's own lamps alone: the system's sky
	# ambient (Hoffer's Wake's green nebula fill) has no business inside the
	# asteroid, and the starfield behind the walls reads as holes.
	if main.env_ref != null and _saved_env.is_empty():
		_saved_env = {
			"bg": main.env_ref.background_mode,
			"col": main.env_ref.ambient_light_color,
			"energy": main.env_ref.ambient_light_energy,
		}
		main.env_ref.background_mode = Environment.BG_COLOR
		main.env_ref.background_color = Color.BLACK
		main.env_ref.ambient_light_color = Color(0.06, 0.06, 0.07)
		main.env_ref.ambient_light_energy = 1.0
	for n in [main.ship_model, main.cockpit, main.sky_anchor, main.space_fx,
			main.sun]:
		if n != null and is_instance_valid(n) and n is Node3D \
				and (n as Node3D).visible:
			(n as Node3D).visible = false
			_hidden.append(n)
	for o in main.objects:
		var node: Variant = o.get("node", null)
		if node != null and is_instance_valid(node) and (node as Node3D).visible:
			(node as Node3D).visible = false
			_hidden.append(node)
	for a in main.ai_ships:
		if is_instance_valid(a) and a.visible:
			a.visible = false
			_hidden.append(a)


func _show_world() -> void:
	if main.env_ref != null and not _saved_env.is_empty():
		main.env_ref.background_mode = _saved_env["bg"]
		main.env_ref.ambient_light_color = _saved_env["col"]
		main.env_ref.ambient_light_energy = _saved_env["energy"]
		_saved_env.clear()
	for n in _hidden:
		if n != null and is_instance_valid(n):
			(n as Node3D).visible = true
	_hidden.clear()
	if main.cam != null:
		main.cam.keep_aspect = Camera3D.KEEP_HEIGHT
		main.cam.near = 0.05
	main._apply_view()
