# Main layer: boot, campaign, fitting, save/load, movies, debug start.
# Part of main.gd's extends chain -- see
# main_state.gd for the scheme. Same node, same class.
extends "main_travel.gd"

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
	# the base's docking/autoskip cutscene is a director sequence like any
	# other: menu Escape must not open the pause menu over it, the HUD goes
	# dark, and the yoke is the script's
	if base_iface != null and base_iface.cut > 0:
		return true
	if use_port and pog_rt != null and pog_rt.gameapi != null:
		return pog_rt.gameapi.director_busy
	if use_pog and pog_api != null:
		return pog_api.director_busy
	return false

## Ask the running cutscene to abort, the way the scripts themselves do.
func skip_cutscene() -> void:
	if base_iface != null and base_iface.cut > 0:
		base_iface.skip_cutscene()
		return
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
	# scripts.ini [Space] enter[]=iMusic.Initialise (data/ini/scripts.ini:47)
	# runs between StartupSpace and StartupSystem: it starts the dynamic-music
	# monitor, whose first tick sees the system change and plays the entry
	# pick (50% theme / 50% discovery, imusic.pog:376-383). FinalSetup's
	# suspend-all parks it during the launch cutscene like any other task.
	music_start()
	await ss.startup_system()
	var prelude: PogScript = pog_rt.script("iprelude")
	if prelude != null:
		await prelude.main()
	await ss.final_setup()

## The load-time session re-entry (igame.LoadGame, #46): the engine replaces
## the whole session, so a load runs the same enter lists a session start
## does -- scripts.ini [Session] (iCargoScript.Initialise,
## iStartSystem.StartupSession), [Space] (StartupSpace, iMusic.Initialise),
## [System] (StartupSystem), then the act master's Main (the
## icSPMasterScreen::m_act_package re-dispatch; its resume path re-arms from
## the restored globals/states) and [Space] final_setup. NOT StartupNewGame
## and NOT iPrelude -- those are [Game]/new-game only. The save stays the
## truth for where the player is and what they fly: the act masters' resume
## path recreates the player at the base, so position, hull and the fitted
## extras are re-applied from the snapshot afterwards.
func load_reenter(d: Dictionary) -> void:
	if not use_port or pog_rt == null:
		return
	pog_rt.current_seq = 0  # the boot chain: the seq the enter lists ran under
	var ss: PogScript = pog_rt.script("istartsystem")
	if ss == null:
		return
	var cargo: PogScript = pog_rt.script("icargoscript")
	if cargo != null:
		await cargo.initialise()
	await ss.startup_session()
	await ss.startup_space()
	music_start()  # [Space] enter[]=iMusic.Initialise (scripts.ini:47)
	await ss.startup_system()
	var act := String(d.get("act", ""))
	if not act.is_empty():
		var acts: PogScript = pog_rt.script(act.to_lower())
		if acts != null:
			await acts.main()
	await ss.final_setup()
	# the snapshot's truth, re-applied over the act master's base-anchored
	# player rebuild
	var p: Array = d.get("pos", [px, py, pz])
	px = float(p[0])
	py = float(p[1])
	pz = float(p[2])
	hull = float(d.get("hull", hull_max))
	restore_extras(d)

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

func _fit_player(ini_path: String, avatar: String) -> void:
	# swap the player's hull: the campaign opens in the bare command
	# section; the tug comes later at Lucrecia's Base
	player_ship_ini = ini_path
	if ship_model != null:
		ship_model.queue_free()
	if ship.fx != null:
		ship.fx.queue_free()
		ship.fx = null
	ship_model = _load_gltf(avatar) if not avatar.is_empty() else null
	# a missing avatar record already push_errors in _load_gltf; the fit must
	# still complete (stats/systems/groups) or the campaign wedges hull-less
	if ship_model != null:
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
	if ship_model != null:
		weapons.set_muzzles(ship_model)
	# icWeaponLink: the loadout builds the fire groups when the hull is fitted
	# (icLoadout::CreateWeaponLinks 0x10096940), so this is the same moment
	weapons.build_groups(sys)
	if "comsec" in ini_path:
		# single light PBC on the nose hardpoint (comsec.ini + comsec.lws:
		# nose_hardpoint at LW (1.625,-1.5,10.625); light_pbc.ini refire 0.8)
		weapons.refire = 0.8
		weapons.bolt_spec = PbcWeapons.LIGHT_PBC_BOLT
		# The light PBC is a single fixed gun on nose_hardpoint. Its muzzle is the
		# subsim's FcSubsim::WorldPosition (the barrel tip is baked there), fired
		# down the hull axis -- see weapons.light_pbc_muzzle / fixed_gun. The old
		# fallback spawned bolts 3-4 m ahead of the barrel; both point at the null.
		var np: Vector3 = sys.null_pos.get("nose_hardpoint", Vector3.ZERO) \
			if sys != null else Vector3(1.625, -1.5, -10.62505)
		weapons.muzzle_fallback = [np]
		weapons.fixed_gun = {"null_pos": np}
		weapon_name = "LIGHT PBC"
		eye = Vector3(-1.125, 0.425, -12.975)  # comsec.lws crew null
	else:
		# the tug's fitted PBCs (subsims/systems/player/pbc.ini: refire 0.7,
		# projectile sims/weapons/pbc_bolt)
		weapons.refire = 0.7
		weapons.bolt_spec = PbcWeapons.PBC_BOLT
		weapons.muzzle_fallback = PbcWeapons.MUZZLES
		weapons.fixed_gun = {}  # the tug fires from its fitted gun models
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
		player_beams = []
		if Turrets.instance != null:
			Turrets.instance.set_player_battery(self)
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
	# the fitted beams join the channel-2 cycle (icPlayerPilot::GetNextWeapon
	# 0x100b0590 holds magazines and beam links side by side; the tug's is
	# the mining laser)
	player_beams = Turrets.instance.set_player_battery(self) \
			if Turrets.instance != null else []
	_select_secondary(-1)

## NEW GAME while a game is already running. The POG runtime, its tasks, the
## mission runner and every native module's state are built once at boot, so
## simply calling start_campaign() again would stack a second campaign on top of
## the first. Reloading the scene is the only honest clean slate; `_restarting`
## survives it because a static outlives the node.
static var _restarting := false

# --- debug start -------------------------------------------------------------
# The menu's DEBUG START: pick any player hull and a start location, spawn
# with every weapon type loaded, front end skipped. The request rides statics
# across the scene reload exactly like _restarting.
#
# NB an earlier reading concluded Lucrecia's Base was a designed "heat
# sanctuary" (sun radius 1.75e11 m x icSun::Think would peg external heat).
# WRONG: FcWorld::CullSims (flux 0x100c61d0) only Thinks sims within the
# world's interesting range -- icSolarSystem's ctor (0x1004b180) sets it to
# 2 * far_clip = 400 km -- so the sun sim is frozen everywhere a player can
# be and its heat never runs. See _physics_process's body-heat gate.
static var _debug_request := ""   # a player ship ini path; "" = off
static var _debug_system := "hoffers_wake"
static var _debug_at := ""        # arrive-beside entity; "" = system default
var debug_all_weapons := false

func debug_start(ini: String, system_stem := "hoffers_wake", at := "") -> void:
	if pog_rt != null:
		pog_rt.halt()
	_debug_request = ini
	_debug_system = system_stem
	_debug_at = at
	_restarting = false
	get_tree().paused = false
	get_tree().reload_current_scene()

## Debug start: something to look at in the base's Inventory / Recycling /
## Manifest / Add Cargo / Trading screens. The developers left their own tool
## for exactly this -- iTradeTest.GiveEverything (itradetest.pog): 20 of every
## cargo type and the full authored trade board. Running it grants the
## original data, nothing invented. The base screens run on the PORTED
## runtime's natives while the world/jafs code runs on the VM's, and the two
## keep separate state BY DESIGN -- so it runs on both.
func _debug_seed_economy() -> void:
	if pog_rt != null and pog_rt.econ != null \
			and pog_rt.econ.cargo_types.is_empty():
		var cs = pog_rt.script("icargoscript")
		if cs != null:
			cs.call("initialise")
	if pog != null:
		pog.start("itradetest", "GiveEverything")
		pog.start("ipowerup", "GiveAllShips")
	if pog_econ != null:
		# the hull the campaign grants in the prelude (iprelude.pog:238)
		pog_econ._i_add_command(null, [])
	if pog_rt != null:
		var tt = pog_rt.script("itradetest")
		if tt != null:
			tt.call("give_everything")
		if pog_rt.econ != null:
			pog_rt.econ._i_add_command(null, [])
		var pu = pog_rt.script("ipowerup")
		if pu != null:
			pu.call("give_all_ships")

## QUIT confirmed (ipdagui FlightConfirmScreen_OnOK unwinds the screen stack
## to icSPMasterScreen -- the C++ front end): leave the session for the main
## menu. A clean scene reload with no pending debug/restart request boots to
## the front end.
func quit_to_menu() -> void:
	if pog_rt != null:
		pog_rt.halt()
	_debug_request = ""
	_debug_at = ""
	_restarting = false
	get_tree().paused = false
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	get_tree().reload_current_scene()

# --- save/reload -------------------------------------------------------------
# igame.SaveGame/LoadGame (natives/gameapi.gd) own the file format; these
# helpers gather and restore the WORLD state the story-level snapshot
# (globals + states + objectives) does not cover. Deliberately NOT saved:
# live POG task continuations (a bytecode coroutine parked mid-mission
# cannot be serialised; the states/globals it wrote are, and the reactive
# scripts re-arm from those), in-flight ordnance, effects, and field rocks
# (regenerated procedurally).

func save_extras() -> Dictionary:
	var systems: Array = []
	if sys != null:
		for s2: Dictionary in sys.systems:
			var row := {"n": s2["name"], "hp": s2["hp"]}
			if s2.has("ammo"):  # the gatling's icSlugThrower round counter
				row["ammo"] = s2["ammo"]
			systems.append(row)
	var mags: Array = []
	for m2: Dictionary in player_mags:
		mags.append({"stem": m2["stem"], "ammo": m2["ammo"]})
	var ai: Array = []
	for a in ai_ships:
		var s3 := a as AiShip
		if s3 == null or not is_instance_valid(s3) or s3.dying:
			continue
		ai.append({
			"key": s3.sim_key, "name": s3.display_name,
			"name_key": s3.name_key, "ini": s3.ini_path,
			"avatar": s3.avatar_path, "faction": s3.faction,
			"ctype": s3.ctype, "behavior": s3.behavior, "hull": s3.hull,
			"pos": [s3.position.x, s3.position.y, s3.position.z],
			"vel": [s3.velocity.x, s3.velocity.y, s3.velocity.z],
			"hostile": s3.explicit_hostile, "pods": s3.carried_pods,
			"cargo": int(pog_std._bag(pog_world._wrap_ship(s3))
					.get("cargo", 0)) if pog_world != null else 0,
		})
	var inv := {}
	if pog_econ != null:
		for k in pog_econ.player_inv().counts:
			inv[str(k)] = pog_econ.player_inv().counts[k]
	return {
		"ship_ini": player_ship_ini,
		"vel": [ship.velocity.x, ship.velocity.y, ship.velocity.z],
		"set_speed": ship.set_speed,
		"docked_at": docked_at,
		"kill_count": kill_count,
		"aim_assist": aim_assist,
		"systems": systems,
		"mags": mags,
		"inventory": inv,
		"ai": ai,
		# the plot's entity toggles (HideMapLocations and every later
		# reveal) -- the original keeps these in icSaveGame
		"entity_flags": entity_flags,
	}

## Fit a player hull by its ini path alone, resolving the avatar out of
## ships.json. Used by the save restore and by the base launch (the hangar's
## SHIP selection names a hull; icLoadout's launch builds the ship from it).
func fit_player_by_path(want: String) -> void:
	if want.is_empty() or want == player_ship_ini:
		return
	var stats: Array = _load_json("data/json/ships.json")
	for rec in stats:
		if rec.get("path", "") == want:
			# record avatar is an lws:/ ref; _fit_player wants the gltf
			_fit_player(want, "data/avatars/avatars/"
					+ str(rec.get("avatar", "lws:/avatars/tug_hull/setup_prefitted"))
					.trim_prefix("lws:/avatars/") + ".gltf")
			return

func restore_extras(d: Dictionary) -> void:
	entity_flags = d.get("entity_flags", {})
	_apply_entity_flags()   # the records were rebuilt before this ran
	fit_player_by_path(str(d.get("ship_ini", "")))
	var v: Array = d.get("vel", [0, 0, 0])
	ship.velocity = Vector3(v[0], v[1], v[2])
	ship.set_speed = float(d.get("set_speed", 0.0))
	docked_at = str(d.get("docked_at", ""))
	# the SetCollision flag is session state, not save state: a flying save
	# loaded from inside the base menus must not inherit collision-off
	player_collision = docked_at == ""
	kill_count = int(d.get("kill_count", kill_count))
	aim_assist = bool(d.get("aim_assist", aim_assist))
	if sys != null:
		for saved in d.get("systems", []):
			for s2: Dictionary in sys.systems:
				if s2["name"] == saved["n"]:
					s2["hp"] = float(saved["hp"])
					if saved.has("ammo") and s2.has("ammo"):
						s2["ammo"] = int(saved["ammo"])
					break
	for saved in d.get("mags", []):
		for m2: Dictionary in player_mags:
			if m2["stem"] == saved["stem"]:
				m2["ammo"] = int(saved["ammo"])
				break
	if pog_econ != null:
		var inv: Dictionary = d.get("inventory", {})
		pog_econ.player_inv().counts.clear()
		for k in inv:
			pog_econ.player_inv().counts[int(k)] = int(inv[k])
	# the world's live ships: replace whatever the system load spawned
	for a in ai_ships.duplicate():
		if is_instance_valid(a):
			(a as Node).queue_free()
	ai_ships.clear()
	target_ai = null
	for saved in d.get("ai", []):
		var rec2: Dictionary = saved
		var ai := AiShip.new()
		ai.main = self
		ai.sim_key = str(rec2.get("key", ""))
		# Literal first, then the key -- assigning display_name clears name_key.
		# Saves written before name_key existed restore the literal alone.
		ai.display_name = str(rec2.get("name", "Contact"))
		var nkey := str(rec2.get("name_key", ""))
		if not nkey.is_empty():
			ai.name_std = pog_std
			ai.name_key = nkey
		ai.faction = str(rec2.get("faction", "INDPT"))
		ai.ctype = str(rec2.get("ctype", "TRANS"))
		ai.avatar_path = str(rec2.get("avatar", ""))
		if ai.avatar_path != "":
			var mdl := _load_gltf(ai.avatar_path)
			if mdl != null:
				ai.add_child(mdl)
				ShipEffects.attach(ai, mdl)
				if str(rec2.get("ini", "")) != "":
					ai.setup_ini(str(rec2["ini"]), mdl)
		elif str(rec2.get("ini", "")) != "":
			ai.setup_ini(str(rec2["ini"]), null)
		ai.behavior = str(rec2.get("behavior", "patrol"))
		ai.hull = float(rec2.get("hull", ai.hull_max))
		ai.explicit_hostile = bool(rec2.get("hostile", false))
		ai.carried_pods = int(rec2.get("pods", 0))
		var p2: Array = rec2.get("pos", [0, 0, 0])
		var v2: Array = rec2.get("vel", [0, 0, 0])
		add_child(ai)
		ai.position = Vector3(p2[0], p2[1], p2[2])
		ai.velocity = Vector3(v2[0], v2[1], v2[2])
		ai_ships.append(ai)
		var cargo := int(rec2.get("cargo", 0))
		if cargo != 0 and pog_world != null:
			pog_std._bag(pog_world._wrap_ship(ai))["cargo"] = cargo

func save_game(slot: int, label := "") -> bool:
	if pog_api == null:
		return false
	return int(pog_api._g_save(null, [slot, label])) == 1

func load_game(slot: int) -> bool:
	if pog_api == null:
		return false
	return int(pog_api._g_load(null, [slot])) == 1

func save_slots() -> Array:
	# [[slot, name], ...] for every occupied slot
	var out: Array = []
	if pog_api == null:
		return out
	for i in pog_api.SAVE_SLOTS:
		var n := str(pog_api._g_slot_name(null, [i]))
		if n != "":
			out.append([i, n])
	return out

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
	# return to. The pause menu's NEW GAME path reaches here via a scene reload
	# with no menu item involved, so set it here rather than in the front end.
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
				# iutilities.CreatePlayer (iprelude.gd:923 -> iutilities.gd:2209):
				# sim.PlaceRelativeTo(player, gap, 7000, 10000, -19000) -- the
				# offset in the GAP'S frame (identity in the map), 22.6 km out --
				# then sim.PointAt(player, gap). The z sign is anchored to the
				# reference screenshot: the star (authored heading 180) must
				# light the near faces of the Gap from behind the player, which
				# puts the player on the map's -z side, our -z as well.
				var b := _record_basis(o)
				var off: Vector3 = b * Vector3(7000.0, 10000.0, -19000.0)
				px = o["x"] + off.x
				py = o["y"] + off.y
				pz = o["z"] + off.z
				if ship != null:
					var to := Vector3(o["x"] - px, o["y"] - py, o["z"] - pz)
					ship.global_transform.basis = Basis.looking_at(
						to.normalized(), Vector3.UP)
				o["prop_collide"] = true
			"Hoffer's Gap Entertainment Complex", \
			"Hoffer's Gap Independent Trading Post":
				# dockable sub-locations of the same physical structure —
				# don't render more copies of the rocks
				o["avatar"] = ""
	# sim.PlaceRelativeTo(hulk, player, 3000, 4000, 5000) -- in the PLAYER'S
	# frame (the player now faces the Gap), 7071 m out
	var hoff := Vector3(3000.0, 4000.0, -5000.0)
	if ship != null:
		hoff = ship.global_transform.basis * hoff
	objects.append({"name": "Abandoned Hulk", "category": "station",
		"x": px + hoff.x, "y": py + hoff.y, "z": pz + hoff.z, "radius": 120.0,
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
	movie.bus = "Movie"  # fcMovieDeviceBink volume (the MOVIE VOLUME slider)
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
	if not music_monitor_active():
		audio.music("ambient")  # front end / debug; in-campaign the monitor owns the score
	if uicheck:
		menu.open()
	elif demo:
		menu.visible = false
		menu.launched = true
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		cam_mode = 1
		_apply_view()
	elif menu.launched:
		menu.close()  # straight into flight after a campaign cinematic
	else:
		menu.open()   # MOVIES replay returns to the front end

## A session swap (igame.LoadGame) drops every queued cinematic unplayed:
## their `then` continuations belong to the replaced session and must not run.
func flush_movies() -> void:
	_movie_queue.clear()
	if movie != null:
		movie.queue_free()
		movie = null

## Skip the movie on screen. Only that one: the rest of the queue still plays,
## and a script waiting on a later movie must not be told its one has ended.
func skip_movie() -> void:
	if movie != null:
		movie.finished.emit()

func start_in_system(stem: String, at := "") -> void:
	# `at` names an entity to arrive beside (the system JSON's own name, e.g.
	# "Lucrecia's Base"); empty means the system's default entry point.
	#
	# Every route into flight comes through here, so this is where the front end
	# gets out of the way. It used to be the menu item's own job, which stopped
	# working the moment the items became the original's: SPMainPDAScreen_OnStart
	# calls igame.StartNewGame and knows nothing about our menu, so START NEW GAME
	# loaded the system behind a menu that was still up and still paused -- a
	# freeze, then apparently nothing.
	if menu != null and menu.visible:
		menu.launched = true
		menu.close()
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
	ap_target_idx = -1
	ap_target_ai = null
	clock_start = Time.get_ticks_msec()

func _spawn_player() -> void:
	ship = ShipFlight.new()
	ship.name = "Player"
	# the boot hull: the debug start preloads player_ship_ini; otherwise the
	# commissioned tug (the campaign swaps hulls later via _fit_player)
	var want_ini := player_ship_ini if player_ship_ini != "" \
			else "sims/ships/player/tug.ini"
	var avatar := "lws:/avatars/tug_hull/setup_prefitted"
	var stats: Array = _load_json("data/json/ships.json")
	for rec in stats:
		if rec.get("path", "") == want_ini:
			ship_stats = rec["properties"]
			ship.load_stats(ship_stats)
			avatar = str(rec.get("avatar", avatar))
			break
	base_max_accel = ship.max_accel
	base_turn_accel = ship.turn_accel
	ship_model = _load_gltf("data/avatars/avatars/"
			+ avatar.trim_prefix("lws:/avatars/") + ".gltf")
	if ship_model == null:
		# a hull without an assembled avatar still has to fly
		ship_model = _load_gltf("data/avatars/avatars/tug_hull/setup_prefitted.gltf")
	ship.add_child(ship_model)
	if "tug_hull/" in avatar:
		# the tug's RCS jets live on its command section
		var cs := _load_gltf("data/avatars/avatars/command_section/setup.gltf")
		if cs != null:
			ShipEffects.graft_jets(ship_model, cs)
	ShipEffects.attach(ship, ship_model)
	add_child(ship)
	_fit_systems(want_ini)
	if debug_all_weapons:
		player_mags = Missiles.mags_all()
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
	# The far plane you GET is not the one you ask for. The projection matrix
	# is float32, and at a large far/near ratio the far plane degrades: with
	# cam.far = 600000, Camera3D.get_frustum() reports 419430 at near 0.05,
	# 559241 at near 0.1, 599187 at near 1.0.
	#
	# Everything on sky_anchor lives past that: the neighbour-star flares at
	# 4.5e5, the icStarfieldAvatar points at 4.7e5, the cyclorama at 4.8e5.
	# Their distance is fixed but their DEPTH is radius * cos(theta), so each
	# one crossed the 419430 boundary as it swung toward the middle of the
	# screen and popped out of existence -- "stars disappear when you look at
	# them", the whole sky quietly hollowing out around the view axis. A flare
	# at 4.5e5 survived only while cos(theta) < 0.932, i.e. more than 21.2 deg
	# off-axis; measured at 21.2 deg.
	#
	# 0.1 measures 559241 m, clearing the 4.8e5 cyclorama with room to spare,
	# and stays close enough to the old value that cockpit dressing at the
	# pilot's eye is unaffected. --mechcheck asserts the margin against the
	# MEASURED frustum, not against this comment.
	cam.near = CAM_NEAR
	cam.keep_aspect = Camera3D.KEEP_WIDTH  # the fov constants are horizontal
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
	var tail := CameraTail.new()
	tail.main = self
	add_child(tail)
