class_name PogWorld
extends RefCounted

## sim / isim / iship: the native packages that reach into the simulation.
##
## The scripts spawn everything by INI path -- sim.Create("ini:/sims/ships/
## utility/flitter", name) -- and the engine looks the model, mass, hit points
## and handling up in that INI. We extracted all 148 of those into
## data/json/ships.json, so a POG-created ship gets the *authored* stats rather
## than the placeholder numbers the hand-written spawners used.
##
## One wrinkle dominates this file. The game runs a floating origin: the player
## sits at the scene origin and its true position lives in main.px/py/pz, AI
## ships are positioned *relative to the player*, and the static objects[]
## records hold *absolute* coordinates. POG knows nothing about any of that and
## just says "put this here", so PogSim hides it: every native works in absolute
## metres and abs_pos()/set_abs_pos() do the conversion per object kind.

const _ALIEN_SHIP := preload("res://scripts/alien.gd")

var vm   ## the host: PogRuntime for the ported scripts, PogVM for the oracle
var game: Node3D = null                ## main.gd, when running in-game
var factions: PogFactions = null       ## for the hostility lookup
var std: PogStd = null                 ## for the localised name tables

## Which icSim subclasses fly (get a pilot and a flight model) and which are
## live ordnance. Everything else -- icStation, icInertSim, icPowerUp,
## icFieldSim, icShockwave -- is a world record, not a ship.
const _SHIP_CLASSES: Array[String] = [
	"icShip", "icTurretShip", "icAlienSwarm", "icCargoPod",
]
const _WEAPON_CLASSES: Array[String] = [
	"icBullet", "icSimTrackingMissile", "icBeam", "icRemoteMissile",
	"icCounterMeasure", "icRocket", "icLDSIMissile", "icMine",
]
var sims: Dictionary = {}              ## name -> PogSim
var ship_db: Dictionary = {}           ## "sims/ships/x.ini" -> ships.json record
var _preloaded: Dictionary = {}
var _player_infection_fx: Node3D = null
## iship.HyperSpaceTrackerContact / HyperSpaceTrackerTarget (iship.dll @
## 0x10002f70 / 0x10003080): the player CPU's +0x9c / +0xa0 -- the last ship
## the tracker followed through a capsule jump, and where it went. Set by
## icCapsuleSpace's jump intake when the player has program 0x800 and the
## jumper is the player's current contact-list target (iwar2 @ 0x10040530
## region; it also logs event 0x67 and raises sim flag 0x40 on the jumper).
var tracker_contact: PogSim = null
var tracker_target: PogSim = null


## A POG object handle. Wraps the three things the game calls a "sim":
## the player (main.ship), an AI ship (AiShip node), or a static record in
## main.objects (station / body / L-point / prop).
class PogSim extends RefCounted:
	var world: PogWorld
	var name: String = ""
	var ini: String = ""
	var node: Node3D = null            ## ShipFlight / AiShip
	var rec: Dictionary = {}           ## main.objects[] record
	var is_player := false
	var dead := false
	var hidden := false
	var indestructable := false
	var mission_critical := false
	var sensor_visible := true
	var skill := 1.0                   ## iship.SetPilotSkillLevel
	var free_without_pilot := false
	var faction: String = ""
	var children: Array = []
	var parent: PogSim = null
	var group = null                   ## PogFactions.PogGroup
	var docking_lock: PogSim = null    ## isim.SetDockingLock: the only legal berth
	## iiSim::IsDockedTo state for NON-player sims: who this sim is berthed on
	## (set by idockport.Dock and by a completed dock order). The player's dock
	## state stays game.docked_at.
	var docked_to: PogSim = null
	## sim.AddSubsim (sim.dll @ 0x10004e90): subsims fitted onto a LIVE sim.
	var fitted: Array = []             ## of PogEntities.PogSubsim
	## sim.Create on an ini:/sims/weapons/* path: the missiles.gd record behind
	## this sim, so isim.Kill can detonate it (see _create_weapon).
	var weapon: Dictionary = {}
	## icCPU +0x80, the fitted-program bitmask (icCPU property map @
	## 0x100308a0: "programs" -> +0x80). An icProgram subsim carries its bit
	## in program_id (property map @ 0x10031e80: +0x40); the hyperspace
	## tracker's is 2048 = 0x800 (subsims/systems/player/programs/
	## hyperspace_tracker.ini).
	var programs: int = 0
	## isim.AlienInfectionEffect: the visual's on/off state. In the engine it
	## IS the presence of the sfx/infection node on the avatar
	## (IsAlienEffectOn @ 0x1007ee70); mirrored here so scripts can flip it
	## on sims that have no node (headless, or a map record).
	var infection_on := false
	## isim.SetAlienInfectionDamage fallback store for node-less sims
	## (iiThrusterSim +0x258); node-backed sims keep it on the ship itself.
	var infection_damage := 0.0

	func alive() -> bool:
		if dead:
			return false
		if node != null:
			return is_instance_valid(node)
		return true

	func abs_pos() -> Vector3:
		if is_player:
			return world.player_pos()
		if node != null and is_instance_valid(node):
			# AI ships live in the folded scene space: their position IS the
			# offset from the player.
			return world.player_pos() + node.position
		if not rec.is_empty():
			return Vector3(rec.get("x", 0.0), rec.get("y", 0.0), rec.get("z", 0.0))
		return Vector3.ZERO

	func set_abs_pos(p: Vector3) -> void:
		if is_player:
			world.set_player_pos(p)
		elif node != null and is_instance_valid(node):
			node.position = p - world.player_pos()
		elif not rec.is_empty():
			rec["x"] = p.x
			rec["y"] = p.y
			rec["z"] = p.z

	func basis() -> Basis:
		if node != null and is_instance_valid(node):
			return node.global_transform.basis
		return Basis.IDENTITY

	func set_basis(b: Basis) -> void:
		if node != null and is_instance_valid(node):
			node.global_transform.basis = b

	func radius() -> float:
		if not rec.is_empty():
			return float(rec.get("radius", 100.0))
		return 60.0

	## The map record's category, which is how we tell an icPlanet from an icSun
	## from an icNebula from an icAsteroidBelt. The approach-marker maths branches
	## on exactly those four classes, so it has to be able to ask.
	func category() -> String:
		if is_player or node != null:
			return "ship"
		return String(rec.get("category", ""))

	## FiSim::BoundsRadius (flux `FiSim+0x20`, FiSim::UpdateBoundsRadius @
	## 0x100c05a0): the sim's own radius grown to enclose its attached children.
	## For everything we model it is the radius; a ship has no attached sims.
	func bounds_radius() -> float:
		if node != null and is_instance_valid(node) and world != null \
				and world.game != null:
			return world.game.sim_bounds_radius(node)
		return radius()


## icAITarget::AvoidanceFunction (iwar2 @ 0x1005ab6e):
##     max(a*1.1 + b*1.25, m_minimum_avoidance_radius)
## with the floor skipped when `a` is zero. Constants read out of the shipped
## DLL: 0x10119e94 = 1.1, 0x1011a19c = 1.25, m_minimum_avoidance_radius = 20.
static func avoidance_function(a: float, b: float) -> float:
	var r := a * 1.1 + b * 1.25
	if r < 20.0 and absf(a) >= 1.0e-6:
		r = 20.0
	return r


## icAIServices::InnerMarkerRadius (iwar2 @ 0x100560d0) -- the sphere an
## approaching ship flies to and stops on. THIS is the autopilot's break-off
## distance, and it is derived from the target, which is why a station and a
## planet break off at wildly different ranges. Argument order is the C++ one,
## (ship, target); the POG native takes them the other way round.
static func inner_marker_radius(ship: PogSim, target: PogSim) -> float:
	if target == null:
		return 0.0
	var cat := target.category()
	# an icNebula is its own marker: radius * 0.9 (the float at 0x1011951c)
	if cat == "nebula":
		return target.radius() * 0.9
	var ship_r := ship.bounds_radius() if ship != null else 0.0
	# an icAsteroidBelt contributes no radius at all -- you fly into a belt
	var tgt_r := 0.0 if cat == "belt" else target.bounds_radius()
	if cat == "body" or cat == "star":
		# icPlanet/icSun: (HeatDistanceAsRadiusMultiplier + 1.0) x the radius.
		# m_heat_radius_multiplier = 0.5 (0x1011af58), so 1.5x -- you stop well
		# outside a star's photosphere.
		tgt_r *= 1.5
	if absf(tgt_r) < 1.0e-6:
		# no radius to stand off from: icAITarget::m_waypoint_approach_distance
		return 20.0
	var a := avoidance_function(tgt_r, ship_r) * 1.75   # 0x1011a264
	var b := avoidance_function(ship_r, tgt_r) * 1.75
	# the two hulls plus 200 m of clear space (0x10119470), or the avoidance
	# radius if that is larger
	return maxf(maxf(tgt_r + ship_r + 200.0, a), b)


## icAIServices::OuterMarkerRadius (0x10056280): the inner marker x 1.5
## (0x1011a268) -- except for a nebula, which reports its own radius.
static func outer_marker_radius(ship: PogSim, target: PogSim) -> float:
	if target == null:
		return 0.0
	if target.category() == "nebula":
		return target.radius()
	return inner_marker_radius(ship, target) * 1.5


## icAITarget::RecomputeRadii (0x10057ede) sets the order's completion tolerance
## to `min(radius * 0.05, m_maximum_standard_completion_radius)`, and
## m_maximum_standard_completion_radius is 0.5 m. The engine's position
## controller settles onto the marker sphere and holds; ours flies a waypoint and
## cannot hold half a metre, so we treat "reached the sphere" as arrival -- see
## docs/original.md Deliberate divergences.
static func completion_tolerance(marker: float) -> float:
	return minf(marker * 0.05, 0.5)


func register(v) -> void:
	vm = v
	# Sims are named with localisation keys, so the world needs the text tables to
	# turn one into something a human reads. Both hosts (PogRuntime for the port,
	# PogVM's owner for the oracle) build their PogStd before their PogWorld.
	if std == null and "std" in v:
		std = v.std
	for fq in _BINDINGS:
		v.bind(fq, Callable(self, _BINDINGS[fq]))


func bind_game(main: Node3D) -> void:
	game = main
	_load_ship_db()
	# the player's infection DoT ticks inside main.sys.simulate(); the death
	# it can cause has no other observer (main only checks its hull at damage
	# sites, and ship_systems.gd cannot reach _kill_player)
	main.get_tree().process_frame.connect(_infection_frame)


func _infection_frame() -> void:
	if game == null or game.sys == null:
		return
	if game.sys.infection_damage > 0.0 and game.sys.killed \
			and game.has_method("_kill_player"):
		game._kill_player()


## POG works in game coordinates; our world negates Z (the system JSON importer
## does the same on load), so every script-supplied offset flips here.
static func vec(x: Variant, y: Variant, z: Variant) -> Vector3:
	return Vector3(float(x), float(y), -float(z))


func player_pos() -> Vector3:
	if game == null:
		return Vector3.ZERO
	return Vector3(game.px, game.py, game.pz)


## Moving the player moves the *origin*, because AI ships are positioned relative
## to it. Shift them back by the same delta or they are dragged along, and a
## script that teleports the player next to something it just spawned will find
## the thing has politely moved out of the way -- which is what left the launch
## cutscene waiting forever for the player to close on a launch tube that kept
## running away from them.
func set_player_pos(p: Vector3) -> void:
	if game == null:
		return
	var delta := p - player_pos()
	if delta == Vector3.ZERO:
		return
	game.px = p.x
	game.py = p.y
	game.pz = p.z
	for ai in game.ai_ships:
		if is_instance_valid(ai):
			ai.position -= delta


## The three extracted sim tables share one schema (path/class/avatar/properties)
## and together cover every ini the scripts can name. Indexing only ships.json
## left 88 of the 179 inis the POG tree creates unresolvable -- including every
## station, so `ini:/sims/stations/reactor` came up with no record and no avatar.
const _SIM_DBS: Array[String] = [
	"data/json/ships.json", "data/json/stations.json", "data/json/sims_other.json",
]

func _load_ship_db() -> void:
	if not ship_db.is_empty() or game == null:
		return
	for db in _SIM_DBS:
		for rec in game._load_json(db):
			ship_db[String(rec.get("path", ""))] = rec


## "ini:/sims/ships/utility/flitter" -> "sims/ships/utility/flitter.ini"
static func ini_key(p: String) -> String:
	var s := p.trim_prefix("ini:").trim_prefix("/")
	return s if s.ends_with(".ini") else s + ".ini"


## "lws:/avatars/gangstership/setup" -> "data/avatars/avatars/gangstership/setup.gltf"
static func avatar_path(a: String) -> String:
	var s := a.trim_prefix("lws:").trim_prefix("/")
	return "data/avatars/%s.gltf" % s


## The object-record form of the same thing: main.objects stores the avatar
## RELATIVE to data/avatars/ (main_world._stream_objects prepends it), lower-cased
## the way the extraction writes the tree.
static func object_avatar(a: String) -> String:
	if a.is_empty():
		return ""
	return "%s.gltf" % a.trim_prefix("lws:").trim_prefix("/").to_lower()


func _as_sim(v: Variant) -> PogSim:
	return v if v is PogSim else null


## The player's handle, created lazily so it always tracks main.ship.
func player_sim() -> PogSim:
	if sims.has("@player"):
		return sims["@player"]
	var s := PogSim.new()
	s.world = self
	s.name = "Player"
	s.is_player = true
	s.node = game.ship if game != null else null
	sims["@player"] = s
	return s


## Wrap an existing objects[] record (station, body, L-point, prop) so the
## scripts can find the world they were written against: "Hoffer's Gap" and
## friends already exist in the system JSON.
func _wrap_record(rec: Dictionary) -> PogSim:
	# A record's identity is its sim NAME (a localisation key for anything the
	# scripts created); rec["name"] is the resolved text the HUD shows.
	var key := String(rec.get("key", rec.get("name", "")))
	if sims.has(key):
		return sims[key]
	var s := PogSim.new()
	s.world = self
	s.name = key
	s.rec = rec
	s.faction = String(rec.get("faction", ""))
	sims[key] = s
	return s


## The scripts look a sim up by its NAME -- the localisation key they created it
## with, not the text it displays as. Both are accepted here because the
## hand-authored content in mission.gd names its ships in plain English.
func find_by_name(name: String) -> PogSim:
	if sims.has(name):
		return sims[name]
	if game == null:
		return null
	for rec in game.objects:
		if String(rec.get("key", rec.get("name", ""))) == name \
				or String(rec.get("name", "")) == name:
			return _wrap_record(rec)
	for ai in game.ai_ships:
		if is_instance_valid(ai) \
				and (ai.sim_key == name or ai.display_name == name):
			return _wrap_ship(ai)
	return null


func _wrap_ship(ai: Node3D) -> PogSim:
	var key := String(ai.sim_key)
	if key.is_empty():
		key = String(ai.display_name)
	if sims.has(key):
		return sims[key]
	var s := PogSim.new()
	s.world = self
	s.name = key
	s.node = ai
	s.faction = String(ai.faction)
	sims[key] = s
	return s


var _names_gen := -1

## An object record's "name" is a RESOLVED string, not a key -- half the game
## compares it against literals ("Lucrecia's Base", BaseInterior.BASE_NAME), so
## it cannot become lazy the way AiShip.display_name did. Instead re-resolve the
## records whenever a table lands, which is the same invalidation, batched.
func refresh_object_names() -> void:
	if std == null or game == null or std.text_gen == _names_gen:
		return
	_names_gen = std.text_gen
	for o: Dictionary in game.objects:
		var key := String(o.get("key", ""))
		if not key.is_empty():
			o["name"] = display_name_of(key)


## icAIPilot::ResolveName (iwar2 @ 0x10055540): a sim's NAME is a localisation
## key, and everything that displays one runs it through FcLocalisedText::Field
## first. `iShipCreation.ShipName` hands `sim.Create` a key like `sn_general_212`
## and the missions hand it composite keys like `a1_m10_ship_name_fighter+ +2`;
## the display string is the resolved text, never the key. A null sim resolves to
## "Undefined" (the literal at 0x1015c244).
func display_name_of(key: String) -> String:
	if key.is_empty():
		return "Undefined"
	return std.field(key, 0) if std != null else key


## Spawn from an INI path, using the authored stats out of ships.json.
func _create_ship(ini: String, name: String) -> PogSim:
	var s := PogSim.new()
	s.world = self
	s.name = name
	s.ini = ini
	if game == null:
		sims[name] = s
		return s

	var rec: Dictionary = ship_db.get(ini_key(ini), {})
	var props: Dictionary = rec.get("properties", {})
	# @element icAlienSwarm -- act 3's aliens are their own icShip subclass
	# (registered @ 0x1002c080); alien.gd carries the recovered overrides
	# (preloaded: the global class cache only learns new class_names in the
	# editor, and headless runs never see it)
	var is_alien := String(rec.get("class", "")) == "icAlienSwarm"
	var ai: AiShip = _ALIEN_SHIP.new() if is_alien else AiShip.new()
	ai.main = game
	ai.sim_key = name
	# Deferred, not display_name_of(name) here: the table naming this sim may not
	# be loaded yet (see AiShip.name_key).
	if name.is_empty():
		ai.display_name = "Undefined"  # the literal at 0x1015c244
	else:
		ai.name_std = std
		ai.name_key = name
	ai.ctype = String(props.get("type", "TRANS")).trim_prefix("T_")
	ai.avatar_path = avatar_path(String(rec.get("avatar", "")))
	ai.setup(props if not props.is_empty() else {"hit_points": 600})
	var mdl: Node3D = game._load_gltf(ai.avatar_path)
	if mdl != null:
		ai.add_child(mdl)
		if not is_alien:
			# the alien avatar's channels (pain1..3/damage) are alien state,
			# not flight state; AlienShip drives them itself
			ShipEffects.attach(ai, mdl)
	ai.position = Vector3.ZERO
	game.add_child(ai)
	game.ai_ships.append(ai)
	if is_alien:
		ai.init_alien(mdl)
	s.node = ai
	sims[name] = s
	return s


## The three icFieldSphere region templates (data/ini/sims/regions/*.ini):
## a sphere that switches the ambient asteroid/debris field singletons on
## while the player is inside it (icFieldSphere::Think, iwar2 @ 0x100667b0;
## contains flags at +0x1e0/+0x1e1, property map @ 0x100664e0). The scripts
## drop one on a habitat -- istartsystem.FinalSetup puts ini:/sims/regions/
## debris on Lucrecia's Base, which IS the Junkyard's ambient junk.
## [contains_asteroids, contains_debris, radius]
const _FIELD_SPHERES := {
	"sims/regions/asteroid": [true, false, 10000.0],
	"sims/regions/asteroid25k": [true, false, 25000.0],
	"sims/regions/debris": [false, true, 10000.0],
}

## Spawn a non-ship sim: it becomes a record in main.objects, which is how the
## game models stations, props and beacons.
func _create_object(ini: String, name: String) -> PogSim:
	var s := PogSim.new()
	s.world = self
	s.name = name
	s.ini = ini
	if game == null:
		sims[name] = s
		return s
	# The record's own avatar and radius: without these the object streamed in as
	# nothing at all (main_world._stream_objects skips an empty avatar), which is
	# why a scripted station was on sensors with no geometry.
	_load_ship_db()
	var db: Dictionary = ship_db.get(ini_key(ini), {})
	var dprops: Dictionary = db.get("properties", {})
	var rec: Dictionary = {
		"name": display_name_of(name), "key": name, "category": "prop",
		"x": 0.0, "y": 0.0, "z": 0.0,
		"radius": float(dprops.get("radius", 100.0)),
		"avatar": object_avatar(String(db.get("avatar", ""))),
		"jumps": [], "colors": [],
		"node": null, "prop_collide": true,
	}
	var stem := ini.trim_prefix("ini:/").trim_suffix(".ini")
	if _FIELD_SPHERES.has(stem):
		# an icFieldSphere is pure geography: no avatar, no hull, nothing on
		# sensors -- fields.gd reads these records every frame and PlaceAt
		# moves them, so the sphere follows wherever the script puts it
		var fs: Array = _FIELD_SPHERES[stem]
		rec["category"] = "field_sphere"
		rec["prop_collide"] = false
		rec["field_asteroids"] = fs[0]
		rec["field_debris"] = fs[1]
		rec["radius"] = fs[2]
	game.objects.append(rec)
	s.rec = rec
	sims[name] = s
	return s


## sim.Create on a weapon INI: live ordnance, dropped into the world by hand.
## Three scripts do it -- iact2mission05 makes an `ini:/sims/weapons/ldsi_missile`,
## PlaceAt's it on the Marauder group's leader and isim.Kill's it (the scripted
## LDSI burst that drops the group out of LDS); iact2mission08 and iactthree plant
## proximity / antimatter mines the same way. missiles.gd already owns all three
## (Missiles.SPECS), including the LDSI's ScrambleLDSDrives field, so this only
## has to wrap one of its records in a PogSim: node = the missile's node, so
## PlaceAt / abs_pos / IsAlive all work off the same field they use for a ship,
## and Kill detonates instead of quietly deleting.
func _create_weapon(ini: String, name: String) -> PogSim:
	var s := PogSim.new()
	s.world = self
	s.name = name
	s.ini = ini
	sims[name] = s
	var stem := ini.trim_prefix("ini:/").trim_suffix(".ini").get_file()
	if game == null or game.missiles == null or not Missiles.SPECS.has(stem):
		return s
	var spec: Dictionary = Missiles.SPECS[stem]
	# no shooter and no target: it is inert ordnance until the script kills it
	var rec: Dictionary = game.missiles.spawn_missile(null, spec,
			game.missiles.global_position, Vector3.FORWARD, Vector3.ZERO, null)
	s.node = rec["node"]
	s.weapon = rec
	return s

# ---------------------------------------------------------------- sim
# @native sim.Create
func _s_create(_t, a: Array) -> Variant:
	var ini := PogStd._s(a[0])
	var name := PogStd._s(a[1]) if a.size() > 1 else ini.get_file()
	# The sim's CLASS decides what it is, not where its ini happens to sit. The
	# path substring disagrees with the class on 51 inis: 47 real ships live
	# outside /sims/ships/ (sims/stations/custom/asteroid_mine is an icShip) and
	# came up as avatar-less prop records, and 4 icInertSim markers under
	# /sims/ships/ were being given a pilot they never had.
	_load_ship_db()
	var cls := String(ship_db.get(ini_key(ini), {}).get("class", ""))
	if not cls.is_empty():
		if cls in _SHIP_CLASSES:
			return _create_ship(ini, name)
		if cls in _WEAPON_CLASSES:
			return _create_weapon(ini, name)
		return _create_object(ini, name)
	# ini in no table: fall back to the path, which is all we ever had
	if "/ships/" in ini:
		return _create_ship(ini, name)
	if "/weapons/" in ini:
		return _create_weapon(ini, name)
	return _create_object(ini, name)

# @native sim.Preload
func _s_preload(_t, a: Array) -> Variant:
	_preloaded[PogStd._s(a[0])] = true
	return 0

# @native sim.FindByName
# @native imapentity.FindByName
func _s_find_by_name(_t, a: Array) -> Variant:
	return find_by_name(PogStd._s(a[0]))

# @native isim.FindByNameInSystem
# @native imapentity.FindByNameInSystem
func _s_find_in_system(_t, a: Array) -> Variant:
	return find_by_name(PogStd._s(a[0]))

# @native sim.Name
func _s_name(_t, a: Array) -> Variant:
	var s := _as_sim(a[0])
	return s.name if s != null else ""

# @native sim.Destroy
func _s_destroy(_t, a: Array) -> Variant:
	var s := _as_sim(a[0])
	if s == null:
		return 0
	s.dead = true
	sims.erase(s.name)
	if not s.weapon.is_empty() and game != null and game.missiles != null:
		# script-planted ordnance goes off rather than vanishing; missiles.gd
		# reaps the record itself once the node is gone
		game.missiles.detonate(s.weapon)
		s.weapon = {}
		return 0
	if s.node != null and is_instance_valid(s.node) and game != null:
		game.ai_ships.erase(s.node)
		s.node.queue_free()
	elif not s.rec.is_empty() and game != null:
		var n = s.rec.get("node")
		if n != null and is_instance_valid(n):
			n.queue_free()
		game.objects.erase(s.rec)
	return 0

# @native sim.IsAlive
func _s_is_alive(_t, a: Array) -> Variant:
	var s := _as_sim(a[0])
	return 1 if (s != null and s.alive()) else 0

# @native sim.IsDead
# @native isim.IsDying
func _s_is_dead(_t, a: Array) -> Variant:
	var s := _as_sim(a[0])
	return 0 if (s != null and s.alive()) else 1

# @native sim.Cast
# @native isim.Cast
# @native iship.Cast
# @native ihabitat.Cast
# @native imapentity.Cast
# @native istation.Cast
func _s_cast(_t, a: Array) -> Variant:
	# POG is statically typed; a cast that would fail at compile time cannot
	# occur, so at runtime this is identity on anything that is a sim.
	return _as_sim(a[0])

# --- placement. All of these are "put A somewhere near B".

# @native sim.PlaceAt
func _s_place_at(_t, a: Array) -> Variant:
	var s := _as_sim(a[0])
	var r := _as_sim(a[1])
	if s != null and r != null:
		s.set_abs_pos(r.abs_pos())
	return 0

# @native sim.PlaceRelativeTo
# @native sim.PlaceRelativeToInside
func _s_place_relative(_t, a: Array) -> Variant:
	var s := _as_sim(a[0])
	var r := _as_sim(a[1])
	if s != null and r != null:
		s.set_abs_pos(r.abs_pos() + r.basis() * vec(a[2], a[3], a[4]))
	return 0

# @native sim.PlaceNear
func _s_place_near(_t, a: Array) -> Variant:
	var s := _as_sim(a[0])
	var r := _as_sim(a[1])
	if s == null or r == null:
		return 0
	var d := float(a[2])
	var dir := Vector3(randf() - 0.5, randf() - 0.5, randf() - 0.5).normalized()
	s.set_abs_pos(r.abs_pos() + dir * d)
	return 0

# @native sim.PlaceBetween
func _s_place_between(_t, a: Array) -> Variant:
	var s := _as_sim(a[0])
	var p := _as_sim(a[1])
	var q := _as_sim(a[2])
	if s == null or p == null or q == null:
		return 0
	var f := clampf(float(a[3]), 0.0, 1.0)
	s.set_abs_pos(p.abs_pos().lerp(q.abs_pos(), f))
	return 0

# @native sim.PlaceInFrontOf
func _s_place_in_front(_t, a: Array) -> Variant:
	var s := _as_sim(a[0])
	var r := _as_sim(a[1])
	if s != null and r != null:
		s.set_abs_pos(r.abs_pos() - r.basis().z * float(a[2]))
	return 0

# @native sim.PointAt
func _s_point_at(_t, a: Array) -> Variant:
	var s := _as_sim(a[0])
	var r := _as_sim(a[1])
	if s == null or r == null or s.node == null:
		return 0
	var to := r.abs_pos() - s.abs_pos()
	if to.length_squared() > 0.001:
		s.node.look_at(s.node.global_position + to, Vector3.UP)
	return 0

# @native sim.PointAway
func _s_point_away(_t, a: Array) -> Variant:
	var s := _as_sim(a[0])
	var r := _as_sim(a[1])
	if s == null or r == null or s.node == null:
		return 0
	var to := s.abs_pos() - r.abs_pos()
	if to.length_squared() > 0.001:
		s.node.look_at(s.node.global_position + to, Vector3.UP)
	return 0

# @native sim.CopyOrientation
func _s_copy_orientation(_t, a: Array) -> Variant:
	var s := _as_sim(a[0])
	var r := _as_sim(a[1])
	if s != null and r != null:
		s.set_basis(r.basis())
	return 0

# @native sim.SetOrientationEuler
func _s_set_orientation(_t, a: Array) -> Variant:
	var s := _as_sim(a[0])
	if s != null:
		s.set_basis(Basis.from_euler(vec(a[1], a[2], a[3])))
	return 0

# @native sim.DistanceBetween
# @native sim.DistanceBetweenCentres
func _s_distance(_t, a: Array) -> Variant:
	var p := _as_sim(a[0])
	var q := _as_sim(a[1])
	if p == null or q == null:
		return 0.0
	return p.abs_pos().distance_to(q.abs_pos())

# --- motion

# @native sim.SetVelocity
func _s_set_velocity(_t, a: Array) -> Variant:
	var s := _as_sim(a[0])
	if s != null and s.node != null and is_instance_valid(s.node):
		s.node.velocity = vec(a[1], a[2], a[3])
	return 0

# @native sim.SetVelocityLocalToSim
func _s_set_velocity_local(_t, a: Array) -> Variant:
	var s := _as_sim(a[0])
	if s != null and s.node != null and is_instance_valid(s.node):
		s.node.velocity = s.basis() * vec(a[1], a[2], a[3])
	return 0

# @native sim.SetAngularVelocityEuler
# @native sim.SetAngularVelocity
func _s_set_angular(_t, a: Array) -> Variant:
	var s := _as_sim(a[0])
	if s != null and s.node != null and is_instance_valid(s.node):
		s.node.angular_velocity = vec(a[1], a[2], a[3])
	return 0

# @native sim.Speed
func _s_speed(_t, a: Array) -> Variant:
	var s := _as_sim(a[0])
	if s != null and s.node != null and is_instance_valid(s.node):
		return s.node.velocity.length()
	return 0.0

# --- flags and structure

# @native sim.SetHidden
func _s_set_hidden(_t, a: Array) -> Variant:
	var s := _as_sim(a[0])
	if s != null:
		s.hidden = PogVM._truthy(a[1])
		if s.node != null and is_instance_valid(s.node):
			s.node.visible = not s.hidden
	return 0

# @native sim.IsHidden
func _s_is_hidden(_t, a: Array) -> Variant:
	var s := _as_sim(a[0])
	return 1 if (s != null and s.hidden) else 0

# @stub sim.SetCullable
# @stub sim.SetCollision
# @stub sim.SetMass
func _s_noop(_t, _a: Array) -> Variant:
	# Culling, collision toggles and mass have no effect on the outcome of a
	# mission. See docs/coverage.md.
	return 0


# --- avatar channels --------------------------------------------------------
# FiSceneNode::SetChannelValue on a sim's avatar root. ship_effects.gd is the
# channel rig: its <anim> nodes interpolate between two poses by the value of
# the channel expression they were authored with, and those expressions read
# named inputs (lz, fire, burn, ...). These three natives write those inputs
# from the script, which is how the cutscene ships light their drives, how the
# League corvettes switch their livery on and off ("league_on"/"league_off")
# and how the asteroids swap to their damaged pose ("iasteroid_pre_damage").

func _fx_of(a) -> ShipEffects:
	var s := _as_sim(a)
	if s == null or s.node == null or not is_instance_valid(s.node):
		return null
	if s.node is ShipFlight:
		return (s.node as ShipFlight).fx
	return null

# @native sim.AvatarAddChannel
func _s_avatar_add_channel(_t, a: Array) -> Variant:
	var fx := _fx_of(a[0])
	if fx != null and a.size() > 1:
		fx.script_channels[PogStd._s(a[1]).to_lower()] = \
			float(a[2]) if a.size() > 2 else 0.0
	return 0

# @native sim.AvatarSetChannel
func _s_avatar_set_channel(_t, a: Array) -> Variant:
	var fx := _fx_of(a[0])
	if fx != null and a.size() > 2:
		fx.script_channels[PogStd._s(a[1]).to_lower()] = float(a[2])
	return 0

# @native sim.AvatarRemoveChannel
func _s_avatar_remove_channel(_t, a: Array) -> Variant:
	# the channel goes back to whatever the ship's own state drives it to
	var fx := _fx_of(a[0])
	if fx != null and a.size() > 1:
		fx.script_channels.erase(PogStd._s(a[1]).to_lower())
	return 0

# @native sim.AddSubsim
func _s_add_subsim(_t, a: Array) -> Variant:
	# sim.dll @ 0x10004e90: both handles must resolve (FiSim + FcSubsim
	# derived) or the native returns false; a subsim that already has an
	# owner is FiSim::RemoveSubsim'd from it first; then FiSim::AddSubsim
	# (flux @ 0x100bc420) appends it, points it at its new sim and fires
	# OnAttachSubsim. Returns true unconditionally after that.
	var s := _as_sim(a[0])
	var ss = a[1] if a.size() > 1 else null
	if s == null or ss == null or not (ss is PogEntities.PogSubsim):
		return 0
	if ss.owner is PogSim and ss.owner != s:
		(ss.owner as PogSim).fitted.erase(ss)
	ss.owner = s
	if not s.fitted.has(ss):
		s.fitted.append(ss)
	var ini: Dictionary = ShipSystems.read_ini(String(ss.ini))
	var props: Dictionary = ini["props"]
	match String(ini["class"]):
		"icProgram":
			# a fitted program ORs its program_id into the CPU's mask
			# (icCPU "programs" @ +0x80, map @ 0x100308a0; icProgram
			# program_id @ +0x40, map @ 0x10031e80). 2048 = the hyperspace
			# tracker (hyperspace_tracker.ini).
			s.programs |= int(props.get("program_id", 0))
		"icCannon":
			# act 3 fits antimatter PBCs onto live ships (iactthree.gd 1805 /
			# 3205, iact3mission10.gd 738). The cannon's projectile INI is
			# what makes the shot antimatter_based -- the only damage an
			# icAlienSwarm accepts (ApplyWeaponDamage @ 0x1002c2c0 calls the
			# projectile's IsAntimatterBasedWeapon, vtable +0xdc).
			var spec := _bolt_spec_for(String(props.get("projectile_template", "")),
					float(props.get("refire_delay", 0.5)))
			if not spec.is_empty():
				if s.is_player and game != null and game.weapons != null:
					game.weapons.bolt_spec = spec
					game.weapons.refire = float(spec["refire"])
				elif s.node is AiShip:
					(s.node as AiShip).bolt_spec = spec
	return 1

## Build a PbcWeapons spec dict from a projectile INI (sims/weapons/*.ini).
func _bolt_spec_for(projectile: String, refire: float) -> Dictionary:
	if projectile.is_empty():
		return {}
	var ini: Dictionary = ShipSystems.read_ini(projectile)
	var p: Dictionary = ini["props"]
	if p.is_empty():
		return {}
	return {
		"damage": float(p.get("damage", 160.0)),
		"penetration": float(p.get("penetration", 50.0)),
		"half_time": float(p.get("half_time", 0.35)),
		"speed": float(p.get("speed", 6000.0)),
		"lifetime": float(p.get("lifetime", 1.6)),
		"bypass_shields": int(p.get("bypass_shields", 0)) != 0,
		"antimatter_based": int(p.get("antimatter_based", 0)) != 0,
		"refire": refire,
	}

# @native sim.FindSubsimByName
func _s_find_subsim(_t, a: Array) -> Variant:
	# sim.dll @ 0x10004fe0: FiSim::Subsim(name) -- first fitted subsim whose
	# name matches, else null. We only track the runtime-fitted list; the
	# authored loadout lives in ShipSystems and has no POG handles.
	var s := _as_sim(a[0])
	var name := PogStd._s(a[1]) if a.size() > 1 else ""
	if s == null:
		return null
	for ss in s.fitted:
		if String(ss.name) == name:
			return ss
		# subsim.Create only knows the display name once the subsim db is
		# bound; the INI's own name property is the same string the engine
		# matches (FcSubsim name)
		if String(ShipSystems.read_ini(String(ss.ini))["props"] \
				.get("name", "")) == name:
			return ss
	return null

# @native sim.Group
func _s_group(_t, a: Array) -> Variant:
	var s := _as_sim(a[0])
	return s.group if s != null else null

# @native sim.Parent
func _s_parent(_t, a: Array) -> Variant:
	var s := _as_sim(a[0])
	return s.parent if s != null else null

# @native sim.Children
func _s_children(_t, a: Array) -> Variant:
	var s := _as_sim(a[0])
	return s.children.duplicate() if s != null else []

# @native sim.AttachChild
# @native sim.AddChildRelativeTo
func _s_attach_child(_t, a: Array) -> Variant:
	var s := _as_sim(a[0])
	var c := _as_sim(a[1])
	if s == null or c == null:
		return 0
	if not s.children.has(c):
		s.children.append(c)
	c.parent = s
	if a.size() >= 5:
		c.set_abs_pos(s.abs_pos() + s.basis() * vec(a[2], a[3], a[4]))
	return 0

# @native sim.DetachChild
func _s_detach_child(_t, a: Array) -> Variant:
	var s := _as_sim(a[0])
	var c := _as_sim(a[1])
	if s != null and c != null:
		s.children.erase(c)
		c.parent = null
	return 0

# @native sim.IsInFOV
func _s_is_in_fov(_t, a: Array) -> Variant:
	var s := _as_sim(a[0])
	var r := _as_sim(a[1])
	if s == null or r == null:
		return 0
	var to := (r.abs_pos() - s.abs_pos()).normalized()
	var fwd := -s.basis().z
	return 1 if fwd.dot(to) > cos(deg_to_rad(float(a[2]) * 0.5)) else 0


# ---------------------------------------------------------------- isim
# @native isim.SetFaction
func _i_set_faction(_t, a: Array) -> Variant:
	var s := _as_sim(a[0])
	if s == null:
		return 0
	var f = a[1]
	s.faction = f.name if f is PogFactions.PogFaction else PogStd._s(f)
	if s.node != null and is_instance_valid(s.node) and "faction" in s.node:
		s.node.faction = s.faction
	elif not s.rec.is_empty():
		s.rec["faction"] = s.faction
	_refresh_hostility(s)
	return 0

# @native isim.Faction
func _i_faction(_t, a: Array) -> Variant:
	var s := _as_sim(a[0])
	if s == null or factions == null:
		return null
	return factions._f_find(null, [s.faction])

# @native isim.SetHostile
func _i_set_hostile(_t, a: Array) -> Variant:
	var s := _as_sim(a[0])
	if s != null and s.node != null and is_instance_valid(s.node) \
			and "behavior" in s.node:
		s.node.behavior = "attack" if PogVM._truthy(a[1]) else "patrol"
	return 0

## The game decides "will this ship shoot at me" with AiShip.behavior, while POG
## decides it with the faction feelings matrix. Bridge the two: whenever a sim's
## faction changes, re-derive its behaviour from how it feels about the player.
func _refresh_hostility(s: PogSim) -> void:
	if s == null or factions == null or s.node == null:
		return
	if not is_instance_valid(s.node) or not ("behavior" in s.node):
		return
	var player_fac := player_sim().faction
	if player_fac.is_empty() or s.faction.is_empty():
		return
	if factions.hostile(s.faction, player_fac):
		s.node.behavior = "attack"

# @native isim.Kill
func _i_kill(_t, a: Array) -> Variant:
	var s := _as_sim(a[0])
	if s == null or s.indestructable:
		return 0
	return _s_destroy(_t, a)

# @native isim.SetIndestructable
func _i_set_indestructable(_t, a: Array) -> Variant:
	var s := _as_sim(a[0])
	if s != null:
		s.indestructable = PogVM._truthy(a[1])
	return 0

# @native isim.IsIndestructable
func _i_is_indestructable(_t, a: Array) -> Variant:
	var s := _as_sim(a[0])
	return 1 if (s != null and s.indestructable) else 0

# @native isim.SetMissionCritical
func _i_set_mission_critical(_t, a: Array) -> Variant:
	var s := _as_sim(a[0])
	if s != null:
		s.mission_critical = PogVM._truthy(a[1])
	return 0

# @native isim.IsMissionCritical
func _i_is_mission_critical(_t, a: Array) -> Variant:
	var s := _as_sim(a[0])
	return 1 if (s != null and s.mission_critical) else 0

# @native isim.SimsInRadius
# @native isim.ShipsInRadius
# @native isim.NonPlanetaryInRadius
# @native isim.PlayerHostilesInRadius
func _i_sims_in_radius(_t, a: Array) -> Variant:
	var centre := _as_sim(a[0])
	if centre == null or game == null:
		return []
	var r := float(a[1])
	# the third argument is an IeSimType bitmask (ijafsscript passes 2048 =
	# T_CargoPod to find loose pods); 0 = no filter. Some aliases put other
	# things at a[2] (SimsInRadiusOfFaction: the faction) -- ints only.
	var mask := 0
	if a.size() > 2 and (a[2] is int or a[2] is float):
		mask = int(a[2])
	var origin := centre.abs_pos()
	var out: Array = []
	for ai in game.ai_ships:
		if not is_instance_valid(ai):
			continue
		if (player_pos() + ai.position).distance_to(origin) > r:
			continue
		var w := _wrap_ship(ai)
		if mask != 0 and (sim_type_of(w) & mask) == 0:
			continue
		out.append(w)
	return out

# @native isim.SimsInRadiusFromSet
func _i_sims_in_radius_from_set(_t, a: Array) -> Variant:
	# Same query, but filtered to a candidate set the script already holds.
	var found: Array = _i_sims_in_radius(_t, a)
	var pool = a[3] if a.size() > 3 else null
	if not (pool is Array):
		return found
	var out: Array = []
	for s in found:
		if (pool as Array).has(s):
			out.append(s)
	return out

# @native isim.SimsInRadiusOfFaction
func _i_sims_in_radius_of_faction(_t, a: Array) -> Variant:
	var want = a[2] if a.size() > 2 else null
	var name: String = want.name if want is PogFactions.PogFaction \
			else PogStd._s(want)
	var out: Array = []
	for s in _i_sims_in_radius(_t, a):
		if s.faction == name:
			out.append(s)
	return out

# @native isim.SimsInCone
func _i_sims_in_cone(_t, a: Array) -> Variant:
	# (centre, radius, half-angle degrees, ...) about the centre's facing.
	var centre := _as_sim(a[0])
	if centre == null:
		return []
	var fwd := -centre.basis().z
	var lim := cos(deg_to_rad(float(a[2]) if a.size() > 2 else 45.0))
	var origin := centre.abs_pos()
	var out: Array = []
	# NB a[2] here is the cone half-angle, NOT the radius query's type mask
	for s in _i_sims_in_radius(_t, [a[0], a[1]]):
		var to: Vector3 = s.abs_pos() - origin
		if to.length_squared() > 0.001 and fwd.dot(to.normalized()) >= lim:
			out.append(s)
	return out

# @native isim.SimsInCylinder
func _i_sims_in_cylinder(_t, a: Array) -> Variant:
	# A radius query along the centre's facing axis, bounded in length: how the
	# scripts sweep a corridor ahead of a ship.
	var centre := _as_sim(a[0])
	if centre == null:
		return []
	var axis := -centre.basis().z
	var r := float(a[1]) if a.size() > 1 else 0.0
	var half_len := float(a[2]) if a.size() > 2 else r
	var origin := centre.abs_pos()
	var out: Array = []
	for s in _i_sims_in_radius(_t, [centre, maxf(r, half_len)]):
		var to: Vector3 = s.abs_pos() - origin
		var along: float = to.dot(axis)
		if absf(along) <= half_len and (to - axis * along).length() <= r:
			out.append(s)
	return out

# @native isim.LastAttacker
# @native iship.LastAttacker
func _i_last_attacker(_t, _a: Array) -> Variant:
	if game == null or game.last_aggressor == null:
		return null
	if not is_instance_valid(game.last_aggressor):
		return null
	return _wrap_ship(game.last_aggressor)

# @native isim.Attacked
# @native iship.Attacked
func _i_attacked(_t, _a: Array) -> Variant:
	return 1 if (game != null and game.last_aggressor != null) else 0

# @native isim.WorldName
# @native isim.ActiveWorld
func _i_world(_t, _a: Array) -> Variant:
	return game.system_name if game != null else ""

## The engine's IeSimType, EXTRACTED: iiSim::Type (0x10078df0) returns the
## ordinal of the name in the m_type_names table (.data 0x1015d8e4..0x1015d960,
## 32 entries T_None..T_PowerUp), and the script-facing flag is
## 1 << (ordinal - 1) with T_None = 0 -- confirmed twice over by the bytecode
## comparisons: T_CommandSection ordinal 18 -> 131072, T_CargoPod ordinal 12
## -> 2048 (what ijafsscript's pod scans test).
const SIM_TYPE := {
	"T_None": 0,
	"T_Star": 1 << 0,
	"T_Planet": 1 << 1,
	"T_Nebula": 1 << 2,
	"T_Waypoint": 1 << 3,
	"T_LagrangePoint": 1 << 4,
	"T_Probe": 1 << 5,
	"T_Weapon": 1 << 6,
	"T_Missile": 1 << 7,
	"T_Mine": 1 << 8,
	"T_Dolly": 1 << 9,
	"T_Asteroid": 1 << 10,
	"T_CargoPod": 1 << 11,        # 2048
	"T_Gunstar": 1 << 12,
	"T_Station": 1 << 13,
	"T_BioBomber": 1 << 14,
	"T_Drone": 1 << 15,
	"T_Waldo": 1 << 16,
	"T_CommandSection": 1 << 17,  # 131072
	"T_Utility": 1 << 18,
	"T_Passenger": 1 << 19,
	"T_Fighter": 1 << 20,
	"T_Tug": 1 << 21,
	"T_Patcom": 1 << 22,
	"T_Interceptor": 1 << 23,
	"T_Corvette": 1 << 24,
	"T_Freighter": 1 << 25,
	"T_Destroyer": 1 << 26,
	"T_Cruiser": 1 << 27,
	"T_Carrier": 1 << 28,
	"T_Alien": 1 << 29,
	"T_PowerUp": 1 << 30,
}

func sim_type_of(s: PogSim) -> int:
	if s == null:
		return 0
	if s.node != null and is_instance_valid(s.node) and "ctype" in s.node:
		var t := int(SIM_TYPE.get("T_" + String(s.node.ctype), 0))
		if t != 0:
			return t
	# no node or an untyped one: the ini record's authored type
	if not s.ini.is_empty():
		var rec: Dictionary = ship_db.get(PogWorld.ini_key(s.ini), {})
		return int(SIM_TYPE.get(str((rec.get("properties", {}) as Dictionary)
				.get("type", "")), 0))
	return 0

# @native isim.Type
func _i_type(_t, a: Array) -> Variant:
	return sim_type_of(_as_sim(a[0]))

# @native isim.IsDocked
# @native isim.IsDockedTo
# @native isim.IsDockedToStructure
func _i_is_docked(_t, a: Array) -> Variant:
	# per-SIM, not per-player: the Jafs loading loop polls is_docked(pod) to
	# see a pod berth on the Jafs (the old player-only answer never resolved)
	var s := _as_sim(a[0] if a.size() > 0 else null)
	if s == null or s.is_player:
		return 1 if (game != null and game.docked_at != "") else 0
	var to := _as_sim(a[1]) if a.size() > 1 else null
	if to != null:
		return 1 if s.docked_to == to else 0
	return 1 if s.docked_to != null else 0

# @native isim.StartExplosion
# @native isim.CreateExplosion
func _i_explode(_t, a: Array) -> Variant:
	var s := _as_sim(a[0])
	if s == null or game == null:
		return 0
	# ExplosionFx works in the folded scene space, which is where the ship
	# node already lives.
	var pos: Vector3 = s.node.global_position \
			if (s.node != null and is_instance_valid(s.node)) \
			else s.abs_pos() - player_pos()
	# The real StartExplosion (0x1007c950) sets the explosion timer to
	# FLT_MAX -- a continuous crackle until StopExplosion fires
	# DoFinalExplosion. We collapse both natives to the final blast at the
	# sim's radius; the open-ended crawl is not modelled for scripted sims.
	var r := 60.0
	if s.node != null and is_instance_valid(s.node) and "radius" in s.node:
		r = float(s.node.radius)
	DeathSequence.final_explosion(game, Basis.IDENTITY, pos, r, Vector3.ZERO)
	return 0

# @native isim.Dock
func _i_dock(_t, a: Array) -> Variant:
	var s := _as_sim(a[0])
	var to := _as_sim(a[1]) if a.size() > 1 else null
	if game != null and s != null and s.is_player and to != null:
		game.docked_at = to.name
	return 0

# @native isim.Undock
func _i_undock(_t, a: Array) -> Variant:
	var s := _as_sim(a[0])
	if game != null and s != null and s.is_player and game.docked_at != "":
		game._undock()
	return 0

# @native isim.CapsuleJump
# @native isim.CapsuleJumpStaggered
# @native isim.CapsuleJumpCustom
func _i_capsule_jump(_t, a: Array) -> Variant:
	# The scripts jump a ship to another system by name. For the player that
	# rides the real sequence from the entry blank onward (the script has
	# already staged the queue and the acceleration run itself); an AI ship
	# just leaves.
	var s := _as_sim(a[0])
	if s == null or game == null:
		return 0
	var dest := PogStd._s(a[1]) if a.size() > 1 else ""
	if s.is_player:
		if not dest.is_empty():
			game.jump_dest = dest.to_lower().replace(" ", "_")
			game.jump_state = 3
			game.jump_timer = 0.0
			game._flash_roll()
			game.audio.play("audio/sfx/capsule_jump.wav", -4.0)
			game.hud.visible = false
	else:
		# the hyperspace tracker (icCapsuleSpace's jump intake, iwar2 @
		# 0x10040530 region): if the player has program 0x800 and the jumper
		# is the player's CURRENT TARGET, record who jumped and where. The
		# scripts pass the destination as a sim (AI jumps) -- that sim id is
		# exactly what the engine stores at CPU +0xa0.
		if player_has_tracker() and s.node != null and is_instance_valid(s.node) \
				and game.target_ai == s.node:
			tracker_contact = s
			tracker_target = _as_sim(a[1]) if a.size() > 1 else null
		_s_destroy(_t, [s])
	return 0

# @native isim.IsCapsuleJumping
func _i_is_jumping(_t, _a: Array) -> Variant:
	return 1 if (game != null and game.jump_state > 0) else 0

# @native isim.SetSensorVisibility
# @native isim.SetStandardSensorVisibility
func _i_set_sensor_visibility(_t, a: Array) -> Variant:
	# Whether the ship shows up on sensors at all. The contact list and the ORB
	# both read the record, so a hidden sim simply is not there to be found --
	# which is how the scripts stage ambushes.
	var s := _as_sim(a[0])
	if s == null:
		return 0
	var vis := PogVM._truthy(a[1]) if a.size() > 1 else true
	s.sensor_visible = vis
	if not s.rec.is_empty():
		s.rec["sensor_hidden"] = not vis
		# An explicitly sensor-visible sim lists at ANY range as a nav contact
		# and is always identified (icSensor gate @ 0x1003ae90: a set
		# visibility byte survives the efficiency*range cut with flags 0x82,
		# and FUN_1003a8e0 skips the "unknown" flag) -- that is how the found
		# Lucrecia's Base and mission markers stay on the list.
		s.rec["sensor_forced"] = vis
	elif s.node != null and is_instance_valid(s.node) \
			and "sensor_hidden" in s.node:
		s.node.sensor_hidden = not vis
	return 0

# @native isim.LockDownWeapons
func _i_lock_weapons(_t, a: Array) -> Variant:
	return _sh_lock_weapons(_t, a)

# @native isim.SetDockingLock
func _i_set_docking_lock(_t, a: Array) -> Variant:
	# SetDockingLock(ship, target, on): while the lock is on, `ship` may only dock
	# at `target`. The missions use it to funnel you (and the traffic) to the one
	# station the script cares about -- iact0mission40 locks the player to the
	# station it wants them to visit and unlocks it again afterwards.
	var s := _as_sim(a[0])
	var to := _as_sim(a[1]) if a.size() > 1 else null
	if s == null:
		return 0
	if PogVM._truthy(a[2]) if a.size() > 2 else false:
		s.docking_lock = to
	else:
		s.docking_lock = null
	return 0


## Whether `s` is allowed to dock at `to` right now. idockport.Dock honours it.
func docking_allowed(s: PogSim, to: PogSim) -> bool:
	if s == null or s.docking_lock == null:
		return true
	return s.docking_lock == to


# @stub isim.StopExplosion
# @stub isim.WeaponTargetsFromContactList
# @stub isim.IsRespawning
func _i_noop(_t, _a: Array) -> Variant:
	# StopExplosion cancels a staged explosion that iiSim::StartExplosion
	# never staged (ours is instantaneous, see docs/original.md "The explosion
	# sequence"). WeaponTargetsFromContactList and IsRespawning are
	# turret-targeting and multiplayer respawn.
	return 0

# @element icAlienSwarm (the infection natives)
# @native isim.AlienInfectionEffect
func _i_infection_effect(_t, a: Array) -> Variant:
	# iiThrusterSim::AlienInfectionEffect @ 0x1007ed80: on = create the
	# ini:/sfx/infection node (icElectricEffectAvatar running
	# icDisruptorDynamics over the hull's edges), feed it the sim's models
	# and radius (FUN_100c3ce0 -> intake 0x100c5430), scale it by
	# max(1, radius/15), eternal emitter (SetTime 0); off = destroy the node.
	var s := _as_sim(a[0])
	if s == null:
		return 0
	var on: bool = PogVM._truthy(a[1]) if a.size() > 1 else false
	if on == s.infection_on and game != null:
		return 0  # both branches no-op when already in that state (0x1007ed80)
	s.infection_on = on
	var host := _infection_host(s)
	if host == null or game == null:
		return 0
	if on:
		if host is AiShip and (host as AiShip).infection_fx != null:
			return 0
		var scale := maxf(1.0, s.radius() / 15.0)
		var fx := ParticleFx.spawn_on_model(host, game._base(), "infection",
				host, s.radius(), scale)
		if host is AiShip:
			(host as AiShip).infection_fx = fx
		elif s.is_player:
			_player_infection_fx = fx
	else:
		var fx2: Node3D = (host as AiShip).infection_fx if host is AiShip \
				else _player_infection_fx
		if fx2 != null and is_instance_valid(fx2):
			fx2.queue_free()
		if host is AiShip:
			(host as AiShip).infection_fx = null
		elif s.is_player:
			_player_infection_fx = null
	return 0

# @native isim.IsAlienInfectionEffectOn
func _i_is_infection_on(_t, a: Array) -> Variant:
	# IsAlienEffectOn @ 0x1007ee70: purely "is the effect node attached" --
	# independent of the damage value.
	var s := _as_sim(a[0])
	return 1 if (s != null and s.infection_on) else 0

# @native isim.SetAlienInfectionDamage
func _i_set_infection_damage(_t, a: Array) -> Variant:
	# SetAlienInfectionDamage @ 0x1007ed70: iiThrusterSim +0x258, hull points
	# per second. iiThrusterSim::Simulate (0x1007e200) applies it every tick
	# as ApplyDamage(dt * damage, source 5, self) -- ship_systems.gd and
	# ai_ship.gd carry that tick.
	var s := _as_sim(a[0])
	if s == null:
		return 0
	var dmg := float(a[1]) if a.size() > 1 else 0.0
	s.infection_damage = dmg
	if s.is_player and game != null and game.sys != null:
		game.sys.infection_damage = dmg
	elif s.node is AiShip and is_instance_valid(s.node):
		(s.node as AiShip).infection_damage = dmg
	return 0

## The node the infection crawl attaches to (and whose meshes it crawls).
func _infection_host(s: PogSim) -> Node3D:
	if s.is_player:
		return game.ship if game != null else null
	if s.node != null and is_instance_valid(s.node):
		return s.node
	return null


# ---------------------------------------------------------------- iship
# @native iship.FindPlayerShip
func _sh_find_player(_t, _a: Array) -> Variant:
	return player_sim()

# @native iship.Create
func _sh_create(_t, a: Array) -> Variant:
	return _create_ship(PogStd._s(a[0]), PogStd._s(a[1]) if a.size() > 1 else "")

# @native iship.InstallAIPilot
func _sh_install_ai(_t, a: Array) -> Variant:
	# InstallAIPilot(ship, ...skill/behaviour...): the AI ships we create are
	# already piloted, so this only has to make sure they are flying.
	var s := _as_sim(a[0])
	if s != null and s.node != null and is_instance_valid(s.node) \
			and "behavior" in s.node:
		_refresh_hostility(s)
	return 0

# @native iship.CurrentTarget
func _sh_current_target(_t, _a: Array) -> Variant:
	if game == null or game.target_ai == null:
		return null
	if not is_instance_valid(game.target_ai):
		return null
	return _wrap_ship(game.target_ai)

# @native iship.DisruptLDSDrive
# @native iship.Disrupt
func _sh_disrupt(_t, a: Array) -> Variant:
	var s := _as_sim(a[0])
	if game == null:
		return 0
	var secs := float(a[1]) if a.size() > 1 else 10.0
	if s != null and s.is_player and game.has_method("disrupt"):
		game.disrupt(secs)
	return 0

# @native iship.CancelDisrupt
func _sh_cancel_disrupt(_t, _a: Array) -> Variant:
	if game != null:
		game.disrupt_time = 0.0
	return 0

# @native iship.IsDisrupted
func _sh_is_disrupted(_t, _a: Array) -> Variant:
	return 1 if (game != null and game.disrupt_time > 0.0) else 0

# @native iship.IsInLDS
func _sh_is_in_lds(_t, _a: Array) -> Variant:
	return 1 if (game != null and game.lds_state > 0) else 0

# @native iship.IsLDSInhibited
func _sh_is_inhibited(_t, _a: Array) -> Variant:
	if game == null or not game.has_method("_nearest_inhibitor"):
		return 0
	return 1 if not game._nearest_inhibitor().is_empty() else 0

# @native iship.Heal
func _sh_heal(_t, a: Array) -> Variant:
	var s := _as_sim(a[0])
	if s == null or game == null:
		return 0
	if s.is_player:
		game.hull = game.hull_max
	elif s.node != null and is_instance_valid(s.node) and "hull" in s.node:
		s.node.hull = s.node.hull_max
	return 0

# @native iship.HasFired
# icShip::HasFired (0x10074fe0): read-and-CLEAR the has-fired flag stamped by
# the weapon fire path (SetLastFireTarget 0x10075000). istation.pog's station
# protection loop keys entirely off this + LastFireTarget below -- with the
# old stub returning 0 the whole shipped reactive system was blind.
func _sh_has_fired(_t, a: Array) -> Variant:
	var s := _as_sim(a[0])
	if s == null:
		return 0
	if s.is_player:
		var v: bool = game != null and game.player_has_fired
		if game != null:
			game.player_has_fired = false
		return 1 if v else 0
	if s.node is AiShip:
		var n := s.node as AiShip
		var v2 := n.has_fired
		n.has_fired = false
		return 1 if v2 else 0
	return 0

# @native iship.LastFireTarget
# icShip::LastFireTarget (0x10074fc0), non-clearing read of the target the
# ship last engaged with its guns.
func _sh_last_fire_target(_t, a: Array) -> Variant:
	var s := _as_sim(a[0])
	if s == null:
		return null
	var node: Node3D = null
	if s.is_player:
		node = game.player_last_fire_target if game != null else null
	elif s.node is AiShip:
		node = (s.node as AiShip).last_fire_target
	if node == null or not is_instance_valid(node):
		return null
	return sim_for_node(node)

## The PogSim wrapping an already-live world node, if any.
func sim_for_node(node: Node3D) -> PogSim:
	if game != null and node == game.ship:
		return player_sim()
	for s: PogSim in sims.values():
		if s.node == node:
			return s
	return null

# @native iship.Dock
func _sh_dock(_t, a: Array) -> Variant:
	return _i_dock(_t, a)

# @native iship.Undock
# @native iship.UndockSelf
func _sh_undock(_t, a: Array) -> Variant:
	return _i_undock(_t, a)

# @native iship.LockDownWeapons
func _sh_lock_weapons(_t, a: Array) -> Variant:
	# The mission locks the player's guns during the training approach, which is
	# why firing does nothing until Clay says otherwise.
	var s := _as_sim(a[0])
	if game != null and s != null and s.is_player:
		game.fire_lock = 1.0e9
	return 0

# @native iship.SetAIDisabled
func _sh_set_ai_disabled(_t, a: Array) -> Variant:
	var s := _as_sim(a[0])
	if s != null and s.node != null and is_instance_valid(s.node) \
			and "behavior" in s.node:
		s.node.behavior = "idle" if PogVM._truthy(a[1]) else "patrol"
	return 0

# @native iship.SetPilotSkillLevel
func _sh_set_skill(_t, a: Array) -> Variant:
	# Skill scales how hard the AI flies and how well it shoots: the missions
	# fly rookies at the player early and aces later, and this is the dial.
	var s := _as_sim(a[0])
	if s == null:
		return 0
	s.skill = clampf(float(a[1]), 0.0, 1.0) if a.size() > 1 else 1.0
	if s.node != null and is_instance_valid(s.node):
		if "weapon_range" in s.node:
			s.node.weapon_range = 1500.0 + 2000.0 * s.skill
		if "angular_speed_boost" in s.node:
			s.node.angular_speed_boost = 1.0 + 0.5 * s.skill
	return 0

# @native iship.PilotSkillLevel
func _sh_skill(_t, a: Array) -> Variant:
	var s := _as_sim(a[0])
	return s.skill if s != null else 0.0

# @native iship.RemovePilot
func _sh_remove_pilot(_t, a: Array) -> Variant:
	# An unpiloted ship just drifts.
	var s := _as_sim(a[0])
	if s != null and s.node != null and is_instance_valid(s.node) \
			and "behavior" in s.node:
		s.node.behavior = "idle"
	return 0

# @native iship.SetFreeWithoutPilot
func _sh_set_free(_t, a: Array) -> Variant:
	# "Free without a pilot": the hull can be claimed if nobody is flying it,
	# which is how the campaign lets you take the tug at Lucrecia's Base.
	var s := _as_sim(a[0])
	if s != null:
		s.free_without_pilot = PogVM._truthy(a[1]) if a.size() > 1 else true
	return 0

# @native iship.IsFreeWithoutPilot
func _sh_is_free(_t, a: Array) -> Variant:
	var s := _as_sim(a[0])
	return 1 if (s != null and s.free_without_pilot) else 0

# @native iship.CreatePlayerShip
func _sh_create_player_ship(_t, a: Array) -> Variant:
	# iUtilities.CreatePlayer's first move: build the hull the player flies. Ours
	# already exists -- main.gd owns the ShipFlight node -- so this hands back the
	# handle for it rather than making a second one. Without this the whole of
	# CreatePlayer ran against a null sim, which is why nothing the scripts did to
	# the player (SetFaction, PlaceRelativeTo, the death script) took effect.
	var s := player_sim()
	var name := PogStd._s(a[0]) if a.size() > 0 else ""
	if not name.is_empty():
		s.name = name
	return s

# @native iship.InstallPlayerPilot
func _sh_install_player_pilot(_t, a: Array) -> Variant:
	# The sim named here becomes the one the player is flying. For CreatePlayer
	# that is the hull we just handed back, and there is nothing to do. The other
	# callers swap the player into a body double for a cutscene
	# (icutsceneutilities.CreateGhostShip) or into a different hull mid-mission;
	# our player is welded to main.ship, so those are not modelled -- but the sim
	# is still marked, because iship.FindPlayerShip has to keep agreeing with it.
	var s := _as_sim(a[0])
	if s == null or s.is_player:
		return 0
	s.free_without_pilot = false
	return 0

# @stub iship.IsAIDisabled
# @stub iship.WeaponsUseExplicitTarget
# @stub iship.WeaponTargetsFromContactList
# @stub iship.BrightnessOf
# @stub iship.PercentageThrusterEmission
# @stub iship.RecalculateMOIFromMass
# @stub iship.IsLDSScrambled
# @stub iship.CreateTurretFighters
func _sh_noop(_t, _a: Array) -> Variant:
	# Turret targeting modes (a ship's turrets either track its own target or pick
	# their own off the contact list) need the turret subsims we do not simulate;
	# BrightnessOf and PercentageThrusterEmission are avatar channel expressions.
	return 0

## Does the PLAYER have the tracker program? Two routes to "fitted": the
## runtime sim.AddSubsim path (programs mask), and owning Cargo_
## HyperspaceTracker (type 312, icargoscript.gd:5055) -- the original fits it
## on the loadout CPU-programs screen (icLoadout::LoadComputerPrograms @
## 0x10095ea0 ORs program_id into the CPU mask); we have no such screen, so
## possession counts as fitted (deliberate divergence, docs/act3.md).
func player_has_tracker() -> bool:
	if (player_sim().programs & 0x800) != 0:
		return true
	if vm != null and "econ" in vm and vm.econ != null:
		return vm.econ.player_inv().quantity(312) > 0
	return false

# @native iship.HasHyperSpaceTracker
func _sh_has_tracker(_t, a: Array) -> Variant:
	# iship.dll @ 0x10002f70: resolve the handle, must be an icShip, then
	# test bit 0x800 in its CPU's program mask (ship +0x29c -> icCPU +0x80).
	var s := _as_sim(a[0])
	if s == null:
		return 0
	if (s.programs & 0x800) != 0:
		return 1
	return 1 if (s.is_player and player_has_tracker()) else 0

# @native iship.HyperSpaceTrackerTarget
func _sh_tracker_target(_t, _a: Array) -> Variant:
	# iship.dll @ 0x10003080: no arguments -- always the PLAYER ship's CPU,
	# +0xa0: the DESTINATION of the last tracked jump.
	return tracker_target

# @native iship.HyperSpaceTrackerContact
func _sh_tracker_contact(_t, _a: Array) -> Variant:
	# iship.dll @ 0x10003020: CPU +0x9c, the ship that made the tracked jump.
	return tracker_contact


const _BINDINGS := {
	"sim.create": "_s_create", "sim.preload": "_s_preload",
	"sim.findbyname": "_s_find_by_name", "sim.name": "_s_name",
	"sim.destroy": "_s_destroy", "sim.isalive": "_s_is_alive",
	"sim.isdead": "_s_is_dead", "sim.cast": "_s_cast",
	"sim.placeat": "_s_place_at",
	"sim.placerelativeto": "_s_place_relative",
	"sim.placerelativetoinside": "_s_place_relative",
	"sim.placenear": "_s_place_near", "sim.placebetween": "_s_place_between",
	"sim.placeinfrontof": "_s_place_in_front",
	"sim.pointat": "_s_point_at", "sim.pointaway": "_s_point_away",
	"sim.copyorientation": "_s_copy_orientation",
	"sim.setorientationeuler": "_s_set_orientation",
	"sim.distancebetween": "_s_distance",
	"sim.distancebetweencentres": "_s_distance",
	"sim.setvelocity": "_s_set_velocity",
	"sim.setvelocitylocaltosim": "_s_set_velocity_local",
	"sim.setangularvelocityeuler": "_s_set_angular",
	"sim.setangularvelocity": "_s_set_angular",
	"sim.speed": "_s_speed",
	"sim.sethidden": "_s_set_hidden", "sim.ishidden": "_s_is_hidden",
	"sim.setcullable": "_s_noop", "sim.setcollision": "_s_noop",
	"sim.setmass": "_s_noop",
	"sim.avataraddchannel": "_s_avatar_add_channel",
	"sim.avatarsetchannel": "_s_avatar_set_channel",
	"sim.avatarremovechannel": "_s_avatar_remove_channel",
	"sim.addsubsim": "_s_add_subsim",
	"sim.findsubsimbyname": "_s_find_subsim",
	"sim.group": "_s_group", "sim.parent": "_s_parent",
	"sim.children": "_s_children", "sim.attachchild": "_s_attach_child",
	"sim.addchildrelativeto": "_s_attach_child",
	"sim.detachchild": "_s_detach_child", "sim.isinfov": "_s_is_in_fov",

	"isim.cast": "_s_cast", "isim.setfaction": "_i_set_faction",
	"isim.faction": "_i_faction", "isim.sethostile": "_i_set_hostile",
	"isim.kill": "_i_kill",
	"isim.setindestructable": "_i_set_indestructable",
	"isim.isindestructable": "_i_is_indestructable",
	"isim.setmissioncritical": "_i_set_mission_critical",
	"isim.ismissioncritical": "_i_is_mission_critical",
	"isim.simsinradius": "_i_sims_in_radius",
	"isim.shipsinradius": "_i_sims_in_radius",
	"isim.nonplanetaryinradius": "_i_sims_in_radius",
	"isim.playerhostilesinradius": "_i_sims_in_radius",
	"isim.lastattacker": "_i_last_attacker", "isim.attacked": "_i_attacked",
	"isim.worldname": "_i_world", "isim.activeworld": "_i_world",
	"isim.type": "_i_type", "isim.isdying": "_s_is_dead",
	"isim.isdocked": "_i_is_docked", "isim.isdockedto": "_i_is_docked",
	"isim.isdockedtostructure": "_i_is_docked",
	"isim.findbynameinsystem": "_s_find_in_system",
	"isim.setsensorvisibility": "_i_set_sensor_visibility",
	"isim.setstandardsensorvisibility": "_i_set_sensor_visibility",
	"isim.lockdownweapons": "_i_lock_weapons",
	"isim.setdockinglock": "_i_set_docking_lock",
	"isim.dock": "_i_dock", "isim.undock": "_i_undock",
	"isim.capsulejump": "_i_capsule_jump",
	"isim.capsulejumpstaggered": "_i_capsule_jump",
	"isim.capsulejumpcustom": "_i_capsule_jump",
	"isim.iscapsulejumping": "_i_is_jumping",
	"isim.startexplosion": "_i_explode", "isim.stopexplosion": "_i_noop",
	"isim.createexplosion": "_i_explode",
	"isim.alieninfectioneffect": "_i_infection_effect",
	"isim.isalieninfectioneffecton": "_i_is_infection_on",
	"isim.setalieninfectiondamage": "_i_set_infection_damage",
	"isim.weapontargetsfromcontactlist": "_i_noop",
	"isim.isrespawning": "_i_noop",
	"isim.simsinradiusfromset": "_i_sims_in_radius_from_set",
	"isim.simsinradiusoffaction": "_i_sims_in_radius_of_faction",
	"isim.simsincylinder": "_i_sims_in_cylinder",
	"isim.simsincone": "_i_sims_in_cone",

	"iship.cast": "_s_cast", "iship.create": "_sh_create",
	"iship.findplayership": "_sh_find_player",
	"iship.installaipilot": "_sh_install_ai",
	"iship.currenttarget": "_sh_current_target",
	"iship.disruptldsdrive": "_sh_disrupt", "iship.disrupt": "_sh_disrupt",
	"iship.canceldisrupt": "_sh_cancel_disrupt",
	"iship.isdisrupted": "_sh_is_disrupted",
	"iship.isinlds": "_sh_is_in_lds",
	"iship.isldsinhibited": "_sh_is_inhibited",
	"iship.heal": "_sh_heal", "iship.hasfired": "_sh_has_fired",
	"iship.lastattacker": "_i_last_attacker",
	"iship.attacked": "_i_attacked",
	"iship.lockdownweapons": "_sh_lock_weapons",
	"iship.removepilot": "_sh_remove_pilot",
	"iship.installplayerpilot": "_sh_install_player_pilot",
	"iship.setpilotskilllevel": "_sh_set_skill",
	"iship.pilotskilllevel": "_sh_skill",
	"iship.setfreewithoutpilot": "_sh_set_free",
	"iship.isfreewithoutpilot": "_sh_is_free",
	"iship.setaidisabled": "_sh_set_ai_disabled",
	"iship.isaidisabled": "_sh_noop",
	"iship.weaponsuseexplicittarget": "_sh_noop",
	"iship.weapontargetsfromcontactlist": "_sh_noop",
	"iship.lastfiretarget": "_sh_last_fire_target", "iship.dock": "_sh_dock",
	"iship.undock": "_sh_undock", "iship.undockself": "_sh_undock",
	"iship.brightnessof": "_sh_noop",
	"iship.percentagethrusteremission": "_sh_noop",
	"iship.recalculatemoifrommass": "_sh_noop",
	"iship.isldsscrambled": "_sh_noop",
	"iship.hashyperspacetracker": "_sh_has_tracker",
	"iship.hyperspacetrackertarget": "_sh_tracker_target",
	"iship.hyperspacetrackercontact": "_sh_tracker_contact",
	"iship.createturretfighters": "_sh_noop",
	"iship.createplayership": "_sh_create_player_ship",

	"imapentity.findbyname": "_s_find_by_name",
	"imapentity.findbynameinsystem": "_s_find_in_system",
	"imapentity.cast": "_s_cast",
	"ihabitat.cast": "_s_cast", "istation.cast": "_s_cast",
}
