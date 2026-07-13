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
const PBC_DAMAGE := 160.0  # sims/weapons/pbc_bolt.ini
const SHIP_HIT_RADIUS := 60.0

const PLANET_TEXTURES := [
	"landwater1", "landwater2", "landwater4", "gas1", "gas2", "gas3", "gas4",
	"stripes1", "stripes2", "stripes3", "stripes4", "stripes5", "stripes6",
]

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
var audio: AudioManager
var sun: DirectionalLight3D
var space_fx: SpaceFx
var ldsi_mesh: ImmediateMesh
var ldsi_mat: StandardMaterial3D
var sky_anchor: Node3D
var sky_mat: ShaderMaterial
var env_ref: Environment
var cam_mode := 0  # F1 internal, F2 tactical/chase, F3 external, F4 drop
var cockpit_frame := true  # the original's removable cockpit dressing
var drop_cam_pos := Vector3.ZERO
var zoomed := false
var free_toggle := false
var ap_mode := 0  # 0 off, 1 approach, 2 formate, 3 dock, 4 match velocity
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
var jump_state := 0  # 0 idle, 1 spool, 2 accel run, 3 capsule space
var jump_timer := 0.0
var jump_dest := ""
var jump_sel := 0
var jump_fade: ColorRect
var hull := 1000.0
var hull_max := 1000.0
var docked_at := ""
var ship_stats: Dictionary = {}
var weapon_name := "L-PBC / R-PBC"  # HUD weapon-panel title
var eye := Vector3(-1.19, -13.85, -40.05)  # pilot eye: tug.lws crew null
var fire_lock := 0.0  # brief inhibit after menus/movies eat a click
var disrupt_time := 0.0  # LDSi weapon hit: drive locked out (iship.Disrupt)

var clock_start := 0  # ms tick when we last left port (the HUD clock)
var base_root: Node3D  # hangar interior while docked at a base
const BASE_BAY := Vector3(0, -110, -527)  # tug parking bay (glTF coords)

var motioncheck := false
var jumpcheck := false
var uicheck := false
var mechcheck := false
var campcheck := false

func _ready() -> void:
	demo = "--demo" in OS.get_cmdline_user_args()
	motioncheck = "--motioncheck" in OS.get_cmdline_user_args()
	jumpcheck = "--jumpcheck" in OS.get_cmdline_user_args()
	uicheck = "--uicheck" in OS.get_cmdline_user_args()
	mechcheck = "--mechcheck" in OS.get_cmdline_user_args()
	campcheck = "--campcheck" in OS.get_cmdline_user_args()
	use_pog = "--pog" in OS.get_cmdline_user_args()
	use_port = "--port" in OS.get_cmdline_user_args()
	if motioncheck or jumpcheck or uicheck or mechcheck or campcheck:
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
	_build_environment()
	_spawn_player()
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
			hull_max = float(ship_stats.get("hit_points", 500))
			hull = hull_max
	weapons.set_muzzles(ship_model)
	if "comsec" in ini_path:
		# single light PBC on the nose hardpoint (comsec.ini + comsec.lws:
		# nose_hardpoint at LW (1.625,-1.5,10.625); light_pbc.ini refire 0.8)
		weapons.refire = 0.8
		weapons.muzzle_fallback = [Vector3(1.625, -1.5, -14.0)]
		weapon_name = "LIGHT PBC"
		eye = Vector3(-1.125, 0.425, -12.975)  # comsec.lws crew null
	else:
		weapons.refire = 0.3
		weapons.muzzle_fallback = PbcWeapons.MUZZLES
		weapon_name = "L-PBC / R-PBC"
		eye = Vector3(-1.19, -13.85, -40.05)  # tug.lws crew null
	_apply_view()

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

func start_in_system(stem: String) -> void:
	lds_state = 0
	jump_state = 0
	_load_system(stem, START_NAME if stem == START_SYSTEM else "")
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
	space_fx.update_grid(cam, Vector3(px, py, pz), ship.velocity,
		lds_state == 2, docked_at != "")

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
	target_idx = -1
	target_ai = null
	docked_at = ""

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
			"radius": float(o.get("visual_radius", o.get("radius", 0.0))),
			"avatar": str(o.get("avatar", "")),
			"jumps": o.get("jumps_to_stems", []),
			"colors": o.get("colors", []),
			"node": null,
		}
		objects.append(rec)
		if cat == "body" or cat == "star":
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
	px = entry["x"] + 2500.0
	py = entry["y"] + 300.0
	pz = entry["z"] + 3000.0
	jump_sel = 0
	_setup_sky(stem)
	_spawn_traffic()
	print("SYSTEM: ", system_name, " (", objects.size(), " objects)")

func _planet_material(rec: Dictionary) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	if rec["category"] == "star":
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.albedo_color = Color(1.0, 0.95, 0.8)
		mat.emission_enabled = true
		mat.emission = Color(1.0, 0.9, 0.7)
		mat.emission_energy_multiplier = 8.0
		return mat
	var pick: String = PLANET_TEXTURES[abs(str(rec["name"]).hash()) % PLANET_TEXTURES.size()]
	var path := _base().path_join("data/textures/images/planets/%s.png" % pick)
	if FileAccess.file_exists(path):
		var img := Image.load_from_file(path)
		if img != null:
			mat.albedo_texture = ImageTexture.create_from_image(img)
	# tint the luminance texture with the body's map palette
	var colors: Array = rec.get("colors", [])
	if not colors.is_empty():
		var c: Array = colors[0]
		mat.albedo_color = Color(
			clampf(c[0] / 255.0 * 1.5, 0.0, 1.0),
			clampf(c[1] / 255.0 * 1.5, 0.0, 1.0),
			clampf(c[2] / 255.0 * 1.5, 0.0, 1.0))
	mat.roughness = 0.9
	return mat

func _spawn_impostor(rec: Dictionary) -> void:
	var mesh := SphereMesh.new()
	mesh.radius = 1.0
	mesh.height = 2.0
	mesh.radial_segments = 48
	mesh.rings = 24
	mesh.material = _planet_material(rec)
	var node := MeshInstance3D.new()
	node.mesh = mesh
	add_child(node)
	rec["node"] = node

func _spawn_beacon(rec: Dictionary) -> Node3D:
	# icHUDLagrangeIcon: the blue/red wireframe double funnel (docs/hud.md)
	var node := SpaceFx.make_lagrange_icon(_lpoint_axis(rec))
	add_child(node)
	return node

func _lpoint_axis(rec: Dictionary) -> Vector3:
	# PLACEHOLDER. The funnel is drawn in the L-point sim's own frame with the
	# jump axis on local +Z, but our extracted system JSON carries no
	# orientation for lpoint records, so the true axis is not available. The
	# star -> L-point line is a stand-in and is NOT from the binary.
	var here := Vector3(rec["x"], rec["y"], rec["z"])
	for o in objects:
		if o["category"] == "star":
			var axis := here - Vector3(o["x"], o["y"], o["z"])
			if axis.length_squared() > 1.0:
				return axis.normalized()
	return Vector3.BACK

func _spawn_player() -> void:
	ship = ShipFlight.new()
	ship.name = "Player"
	var stats: Array = _load_json("data/json/ships.json")
	for rec in stats:
		if rec.get("path", "") == "sims/ships/player/tug.ini":
			ship_stats = rec["properties"]
			ship.load_stats(ship_stats)
			hull_max = float(ship_stats.get("hit_points", 1000))
			hull = hull_max
			break
	ship_model = _load_gltf("data/avatars/avatars/tug_hull/setup_prefitted.gltf")
	ship.add_child(ship_model)
	# the tug's RCS jets live on its command section
	var cs := _load_gltf("data/avatars/avatars/command_section/setup.gltf")
	if cs != null:
		ShipEffects.graft_jets(ship_model, cs)
	ShipEffects.attach(ship, ship_model)
	add_child(ship)
	weapons = PbcWeapons.new()
	weapons.ship = ship
	weapons.main = self
	add_child(weapons)
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

func _apply_view() -> void:
	if cockpit != null:
		cockpit.visible = cam_mode == 0 and cockpit_frame
	if ship_model != null:
		ship_model.visible = cam_mode != 0

func _set_camera(mode: int) -> void:
	cam_mode = mode
	if mode == 3:
		drop_cam_pos = cam.global_position
	if not zoomed:
		cam.fov = FOV_INTERNAL if mode == 0 else FOV_EXTERNAL
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
	ai.position = at
	add_child(ai)
	ai_ships.append(ai)
	audio.music("action")
	hud.warn("HOSTILE CONTACT", 3.0)
	audio.play("audio/hud/klaxon.wav", -6.0)
	return ai

func spawn_bolt(shooter: Node3D, dir: Vector3) -> void:
	weapons.spawn(shooter, dir)
	audio.play("audio/sfx/light_pbc.wav", -8.0)

func on_bolt_hit(target: Node3D, pos: Vector3, shooter: Node3D = null) -> void:
	audio.play("audio/sfx/impact.wav", -6.0)
	_flash(pos, 8.0)
	if target == ship:
		if shooter is AiShip:
			last_aggressor = shooter
		damage_player(PBC_DAMAGE, "HULL HIT")
		return
	var ai := target as AiShip
	if ai != null and ai.damage(PBC_DAMAGE):
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
			"station":
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
		var hostile: bool = a.behavior == "attack"
		list.append({"name": (a.display_name if a.display_name != "" else str(a.name)), "dist": a.global_position.length(),
				"hostile": hostile, "targeted": a == target_ai,
				"category": "traffic",
				"faction": "OUTLW" if hostile else a.faction,
				"type": "FIGHT" if hostile else a.ctype})
	list.sort_custom(func(x, y): return x["dist"] < y["dist"])
	return list.slice(0, 12)

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

	if menu != null and menu.visible:
		return  # the menu handles its own input (it runs while paused)
	# mouse steers as the joystick yoke (the original's primary control)
	if event is InputEventMouseMotion and not demo and docked_at == "":
		ship.input_rotate.y = clampf(ship.input_rotate.y - event.relative.x * 0.003, -1, 1)
		ship.input_rotate.x = clampf(ship.input_rotate.x - event.relative.y * 0.003, -1, 1)
	# conversation choices: number keys answer comms questions
	if comms != null and comms.choosing() and event is InputEventKey \
			and event.pressed and not event.echo \
			and event.physical_keycode >= KEY_1 \
			and event.physical_keycode <= KEY_9:
		comms.choose(event.physical_keycode - KEY_1)
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
			KEY_Z:  # ToggleZoom
				zoomed = not zoomed
				cam.fov = 30 if zoomed else \
					(FOV_INTERNAL if cam_mode == 0 else FOV_EXTERNAL)
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
			KEY_F1:  # InternalCamera
				_set_camera(0)
			KEY_F2:  # TacticalCamera
				_set_camera(1)
			KEY_F3:  # ExternalCamera
				_set_camera(2)
			KEY_F4:  # DropCamera
				_set_camera(3)
			KEY_F12:
				var img := get_viewport().get_texture().get_image()
				img.save_png(_base().path_join("data/screenshots/screenshot_%d.png"
					% (Time.get_ticks_msec() / 1000)))
			KEY_V:  # cockpit dressing on/off (original GUI option)
				cockpit_frame = not cockpit_frame
				_apply_view()
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
	docked_at = ""
	_leave_base()
	audio.play("audio/sfx/undock.wav", -4.0)
	ship.velocity = -ship.global_transform.basis.z * 50.0
	clock_start = Time.get_ticks_msec()
	hud.log_msg("UNDOCKED")

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
		1:  # spool
			if jump_timer >= 3.0:
				jump_state = 2
				jump_timer = 0.0
				hud.warn("ACCELERATION RUN", 2.0)
		2:  # acceleration run â€” iAI.IsCapsuleJumpAccelerating
			ship.velocity += -ship.global_transform.basis.z * 2500.0 * delta
			jump_fade.color.a = clampf(jump_timer / 3.0 - 0.6, 0.0, 1.0) * 2.5
			if jump_timer >= 3.0:
				jump_state = 3
				jump_timer = 0.0
				jump_fade.color.a = 1.0
				audio.play_loop(audio.lds_player,
					"audio/sfx/inside_capsule_space.wav", -6.0)
		3:  # capsule space, then exit at destination
			jump_fade.color.a = clampf(2.0 - jump_timer, 0.0, 1.0)
			if jump_timer >= 2.0:
				var from := system_stem
				audio.lds_player.stop()
				_load_system(jump_dest, "", from)
				ship.velocity = -ship.global_transform.basis.z * 1000.0
				jump_state = 0
				jump_fade.color.a = 0.0
				audio.play("audio/sfx/lds_rampdown.wav", -4.0)
				hud.warn("ARRIVED: %s" % system_name.to_upper(), 4.0)

func _physics_process(delta: float) -> void:
	fire_lock = maxf(0.0, fire_lock - delta)
	disrupt_time = maxf(0.0, disrupt_time - delta)
	if use_pog:
		_pog_boot_process()
		pog_api.director_process(delta)   # cutscene camera, while one is staged
	elif use_port and pog_rt != null and pog_rt.gameapi != null:
		pog_rt.gameapi.director_process(delta)
	if demo:
		checks.step(delta)
	elif in_cutscene():
		# The scripts fly the ship during a cutscene (the launch sequence takes
		# the yoke off you and flies you out of the tube), so the player does
		# not. Without this you sit in the cockpit flying around while a
		# cutscene you cannot see runs to completion behind you.
		ship.input_rotate = Vector3.ZERO
		ship.input_thrust = Vector3.ZERO
	elif docked_at == "" and not menu.visible and movie == null:
		_player_control(delta)
		if ap_mode > 0:
			_autopilot_process(delta)
	if lds_state > 0:
		_lds_process(delta)
	if jump_state > 0:
		_jump_process(delta)
	# LDS cruise / capsule runs own the velocity vector: the flight
	# computer's per-axis speed caps must not clip them back to drive speeds
	ship.drive_override = lds_state == 2 or jump_state >= 2
	if docked_at != "":
		ship.velocity = Vector3.ZERO
		ship.set_speed = 0.0
		ship.input_thrust = Vector3.ZERO
		ship.input_rotate = Vector3.ZERO
	_fold_motion()
	_stream_objects()
	_collisions()
	_update_grid()
	_update_ldsi_fence()
	_chase_camera(delta)
	if sky_anchor != null:
		sky_anchor.global_position = cam.global_position

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
	hull = maxf(hull - dmg, 0.0)
	hud.warn("%s  HULL %d%%" % [why, int(100.0 * hull / hull_max)])
	if hull <= 0.0:
		ExplosionFx.boom(self, ship.global_position, 60.0)
		hud.warn("SHIP DESTROYED - resetting", 5.0)
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
	for a in ai_ships:
		_collide_sphere(a.global_position, 95.0, a.velocity, str(a.display_name))
	for o in objects:
		if o["node"] == null:
			continue
		if o["category"] == "station" or o.get("prop_collide", false):
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

func _player_control(delta: float) -> void:
	# throttle wheel: = / - adjust the set speed (icPlayerPilot.ThrottleDelta)
	var dv := ship.max_speed.z * delta / 1.2
	ship.set_speed = clampf(ship.set_speed
		+ (_key(KEY_EQUAL) + _key(KEY_KP_ADD)) * dv
		- (_key(KEY_MINUS) + _key(KEY_KP_SUBTRACT)) * dv,
		0.0, ship.max_speed.z)
	if ap_mode == 0:
		# thrusters: W/S fore-aft, A/D lateral (LateralZ / LateralX)
		ship.input_thrust.z = _key(KEY_W) - _key(KEY_S)
		ship.input_thrust.x = _key(KEY_D) - _key(KEY_A)
		ship.input_thrust.y = 0.0
		# steering: numpad per keyboard_only.ini, on top of the mouse yoke
		var yaw := _key(KEY_KP_4) - _key(KEY_KP_6)
		var pitch := _key(KEY_KP_8) - _key(KEY_KP_2)
		var roll := _key(KEY_KP_1) - _key(KEY_KP_3)
		if absf(yaw) > 0.0:
			ship.input_rotate.y = yaw
		if absf(pitch) > 0.0:
			ship.input_rotate.x = pitch
		ship.input_rotate.z = roll
		ship.input_rotate.x = move_toward(ship.input_rotate.x, 0.0, delta * 1.5)
		ship.input_rotate.y = move_toward(ship.input_rotate.y, 0.0, delta * 1.5)
	# free flight: N toggles, LeftCtrl / NumPad5 holds (FreeToggle/FreeHold)
	ship.assist = not (free_toggle or Input.is_physical_key_pressed(KEY_CTRL)
		or Input.is_physical_key_pressed(KEY_KP_5))
	if (Input.is_key_pressed(KEY_SPACE)
			or Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)) \
			and lds_state == 0 and fire_lock <= 0.0:
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
			"station":
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
	ap_mode = mode
	audio.play("audio/gui/confirm.wav", -10.0)
	var names := ["OFF", "APPROACH", "FORMATE", "DOCK", "MATCH VELOCITY"]
	hud.log_msg("AUTOPILOT: %s" % names[mode])

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
		ap_mode = 0
		return
	var dist := p.length()
	_face_target()
	# like the original: approach/dock autopilots engage LDS for long
	# transits once the nose is on target (LDS cruise already brakes and
	# drops out near the destination)
	if ap_mode in [1, 3] and lds_state == 0 and jump_state == 0 \
			and dist > 8.0e4 and _lds_clearance() > 1000.0 \
			and (-ship.global_transform.basis.z).angle_to(p.normalized()) < 0.05:
		_toggle_lds()
	match ap_mode:
		1:  # approach: decelerate to arrive 500 m out
			if lds_state == 0:
				ship.set_speed = clampf(dist / 8.0, 0.0, ship.max_speed.z)
			if dist < 600.0:
				ship.set_speed = 0.0
				_set_autopilot(0)
				hud.log_msg("APPROACH COMPLETE")
		2:  # formate: hold 300 m abreast
			var tvel := Vector3.ZERO
			if target_ai != null and is_instance_valid(target_ai):
				tvel = target_ai.velocity
			var hold := clampf((dist - 300.0) * 0.5, 0.0, ship.max_speed.z)
			ship.set_speed = clampf(tvel.length() + hold, 0.0, ship.max_speed.z)
		3:  # dock: approach then hard-dock
			if lds_state == 0:
				ship.set_speed = clampf(dist / 6.0, 0.0, ship.max_speed.z)
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
	if lds_state == 1:
		lds_timer += delta
		if lds_timer >= LDS_SPOOL:
			lds_state = 2
			audio.play_loop(audio.lds_player, "audio/sfx/lds_cruise.wav", -10.0)
		return
	lds_speed = minf(lds_speed * pow(LDS_RAMP, delta), LDS_MAX)
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
				# always visible: drawn at capped distance, scaled to keep
				# the correct angular size (the camera far plane is 600 km)
				var dist := sqrt(maxf(d2, 1.0))
				var r: float = clampf(o["radius"], 2.0e4, 1.0e9)
				if o["category"] == "star":
					r = maxf(r, 7.0e8)
					sun.look_at_from_position(Vector3.ZERO,
						Vector3(-dx, -dy, -dz).normalized())
				var k := minf(IMPOSTOR_DIST / dist, 1.0)
				# never fill the screen: cap apparent radius vs draw distance
				var draw_r := minf(r * k, IMPOSTOR_DIST * 0.4)
				o["node"].position = Vector3(dx, dy, dz) * k
				o["node"].scale = Vector3.ONE * maxf(draw_r, 1.0)
			"station", "prop":
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
	if base_root != null:
		# in the hangar: gantry viewpoint with a gentle sway
		var a := Time.get_ticks_msec() / 1000.0 * 0.11
		var pos := target.origin + Vector3(-150.0 + sin(a) * 35.0, 70.0,
			-180.0 + cos(a * 0.7) * 25.0)
		cam.global_transform = Transform3D(Basis.IDENTITY, pos).looking_at(
			target.origin + Vector3(0, 0, 0), Vector3.UP)
		return
	match cam_mode:
		0:  # internal (F1): rigid at the pilot's eye (the crew null)
			cam.global_transform = target.translated_local(eye)
		1:  # tactical chase (F2)
			var want := target.translated_local(Vector3(0, 32, 130))
			if lds_state == 2 or jump_state >= 2:
				cam.global_transform = want.looking_at(
					target.origin + target.basis * Vector3(0, 6, -30), target.basis.y)
			else:
				cam.global_transform = cam.global_transform.interpolate_with(
					want, 1.0 - exp(-8.0 * delta))
				cam.global_transform = cam.global_transform.looking_at(
					target.origin + target.basis * Vector3(0, 6, -30), target.basis.y)
		2:  # external (F3): slow orbit around the ship
			var a := Time.get_ticks_msec() / 1000.0 * 0.15
			var pos := target.origin + Vector3(cos(a), 0.25, sin(a)) * 180.0
			cam.global_transform = Transform3D(Basis.IDENTITY, pos).looking_at(
				target.origin, Vector3.UP)
		3:  # drop camera (F4): fixed in space, tracking the ship
			cam.global_transform = Transform3D(Basis.IDENTITY,
				drop_cam_pos).looking_at(target.origin, Vector3.UP)

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
