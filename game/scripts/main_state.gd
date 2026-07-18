# The Badlands' one game node, split by topic into a linear `extends` chain:
#   main_state -> main_targeting -> main_camera -> main_flight -> main_collision
#   -> main_world -> main_combat -> main_travel -> main_flow -> main.gd (the
#   script the scene root carries). One object, one class: every var and func is
#   still a member of the same node, so main.<member> (including string get())
#   keeps working from every other script. The split is file organisation only;
#   a layer may reference members of its own level or below, never above.
# This file: constants, the shared state, and small pure helpers.
extends Node3D

const START_SYSTEM := "hoffers_wake"
const START_NAME := "Alexander L-Point"
const STREAM_IN := 4.0e5
const STREAM_OUT := 5.0e5
# FcWorld's think/simulate cull distance: icSolarSystem's ctor (0x1004b180)
# sets the interesting range to 2 * far_clip (flux.ini [icSolarSystem]
# far_clip = 200000). Sims beyond it are frozen -- no Think, no Simulate.
const SIM_INTERESTING_RANGE := 2.0 * 2.0e5
const IMPOSTOR_DIST := 2.5e5  # bodies/stars drawn at capped range, scaled down
const LDSI_RADIUS := 2.5e4

const LDS_MAX := 3.0e10
const LDS_RAMP := 5.0
const LDS_SPOOL := 3.0
const LDS_BASE := 2000.0
const LDS_DROPOUT_SPEED := 1000.0  # icLDSDrive::BreakShipOutOfLDS (decompiled)

# flux.ini fields of view: icInternalCamera 1.1 rad (63.0), external cameras
# 1.2 rad (68.75). These are the era's D3D HORIZONTAL fovs -- treating them as
# Godot's default vertical fov made the cockpit read far wider than the
# original (the reported "camera angle wildly different"); the camera is
# KEEP_WIDTH so these constants bind the horizontal axis, and widescreen crops
# vertically like the period widescreen patches did.
const FOV_INTERNAL := 63.0
const FOV_EXTERNAL := 68.75
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
var player_ship_ini := ""  # sims/ships/player/*.ini path of the fitted hull
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
var fill_sun: DirectionalLight3D  # the geog scene's <fill> DISTANT light
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
var aim_assist := true  # icPlayerPilot+0x9c, hud_menu_toggle_aim_assist
# icShip +0x2ec/+0x2e8 on the PLAYER ship: has-fired flag + last fire target
# (SetLastFireTarget 0x10075000); read-and-clear by iship.HasFired
var player_has_fired := false
var player_last_fire_target: Node3D = null
var roll_yaw_swap := false  # icPlayerPilot.RollYawToggleHold
var ap_mode := 0  # 0 off, 1 approach, 2 formate, 3 dock, 4 match velocity
var _ap_dock_retry := 0.0  # dock autopilot: re-try the gate once a second
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
var newgametest := false
var geogcheck := false
var basecheck := false   # Lucrecia's Base: dock -> interior -> screens
var commshot := false    # screenshot every comm-portrait rig
var muzzleshot := false  # fire the comsec light PBC and photograph it
var contactcheck := false  # spawn into each menu system, print contact_list()
var srgbprobe := false     # render known-value quads, verify colour pipeline
var sunshot := false       # photograph each sun from the spawn point
var fireprobe := false     # fire the primary once and report the weapon state
var mechslow := false      # the full mech suite at real time (the slow
                           # autopilot steps included); --mechcheck is the
                           # time-scaled everyday variant

# The 5-level IFF the HUD colours contacts by: the TARGET faction's feeling
# toward the player, quantized at the icFactions boundaries -- extracted from
# iwar2.dll (statics m_hate_dislike -0.6 / m_dislike_neutral -0.2 /
# m_neutral_like +0.2 / m_like_love +0.6 @ 0x1015becc-d8, ctor 0x47820).
# Levels: 0 hate, 1 dislike (both draw red), 2 neutral (gold), 3 like,
# 4 love (both blue). Unknown factions (plain traffic spawned outside POG)
# read neutral, like the engine's default feeling of 0.
func iff_level(fac: String) -> int:
	if fac.is_empty():
		return 2
	var w: PogWorld = null
	if pog_rt != null and pog_rt.world != null \
			and not pog_rt.world.factions.factions.is_empty():
		w = pog_rt.world
	elif pog_world != null:
		w = pog_world
	if w == null or w.factions == null:
		return 2
	var pf: String = w.player_sim().faction
	if pf.is_empty():
		return 2
	if fac == pf:
		return 4
	var fa = w.factions._as_faction(fac)
	if fa == null:
		return 2
	var f: float = fa.feeling_toward(pf)
	if f < -0.6:
		return 0
	elif f < -0.2:
		return 1
	elif f < 0.2:
		return 2
	elif f < 0.6:
		return 3
	return 4

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
	# NOTE: no colour-space fixup is needed here. --srgbprobe settles it: a
	# 128-grey runtime ImageTexture under an unshaded material captures back
	# as 128 (and a source_color-hinted sampler matches, while a raw sampler
	# differs) -- Godot's Forward+ DOES apply the sRGB decode to runtime
	# textures, so unlit texels already round-trip byte-exact like D3D7's.
	_gltf_cache[rel] = node
	return _instance_gltf(node.duplicate())

func _instance_gltf(node: Node3D) -> Node3D:
	for ap in node.find_children("*", "AnimationPlayer", true, false):
		var player := ap as AnimationPlayer
		for anim_name in player.get_animation_list():
			player.get_animation(anim_name).loop_mode = Animation.LOOP_LINEAR
			player.play(anim_name)
	return node

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

# --- reactor shockwaves ------------------------------------------------------
# icShockwave (property map FUN_10077290: initial_damage_rate +0x1d8,
# front_depth +0x1dc, final_radius +0x1e0, lifetime +0x1e4), template
# ini:/sims/explosions/reactor_explosion -- lifetime 2.0, front_depth 0.1
# ("front thickness as % of radius"), initial_damage_rate 2000 "damage per
# second inflicted ... at time=0". DoFinalExplosion (death_sequence.gd)
# registers one per big death; ships caught in the expanding front burn.
var _shockwaves: Array = []

func register_shockwave(pos: Vector3, vel: Vector3, final_r: float,
		rate: float) -> void:
	_shockwaves.append({"pos": pos, "vel": vel, "r": final_r, "rate": rate,
			"t": 0.0, "warned": false})

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

func _is_hostile(a: AiShip) -> bool:
	# icShip::IsFriendly is what 0x1002f74a tests; the contact list (_contacts)
	# already uses `behavior == "attack"` as the remaster's hostility test, so
	# the auto-fire uses the same one. A ship the player has provoked past its
	# shot tolerance is an EXPLICIT hostile contact
	# (icPlayerContactList::SetSimAsHostile via CheckForReactives 0x10073ac0).
	return a.behavior == "attack" or a.explicit_hostile

func _system_label(name: String) -> String:
	# subsim names are localisation keys ("Cargo_ShipsDrive", "system_lda_shield")
	var s := name.get_slice("_", 0)
	if s == "Cargo" or s == "system":
		s = name.substr(name.find("_") + 1)
	else:
		s = name
	return s.to_upper()

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

func _key(code: int) -> float:
	return 1.0 if Input.is_physical_key_pressed(code) else 0.0

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
