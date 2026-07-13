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

var vm   ## the host: PogRuntime for the ported scripts, PogVM for the oracle
var game: Node3D = null                ## main.gd, when running in-game
var factions: PogFactions = null       ## for the hostility lookup
var sims: Dictionary = {}              ## name -> PogSim
var ship_db: Dictionary = {}           ## "sims/ships/x.ini" -> ships.json record
var _preloaded: Dictionary = {}


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


func register(v) -> void:
	vm = v
	for fq in _BINDINGS:
		v.bind(fq, Callable(self, _BINDINGS[fq]))


func bind_game(main: Node3D) -> void:
	game = main
	_load_ship_db()


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


func _load_ship_db() -> void:
	if not ship_db.is_empty() or game == null:
		return
	for rec in game._load_json("data/json/ships.json"):
		ship_db[String(rec.get("path", ""))] = rec


## "ini:/sims/ships/utility/flitter" -> "sims/ships/utility/flitter.ini"
static func ini_key(p: String) -> String:
	var s := p.trim_prefix("ini:").trim_prefix("/")
	return s if s.ends_with(".ini") else s + ".ini"


## "lws:/avatars/gangstership/setup" -> "data/avatars/avatars/gangstership/setup.gltf"
static func avatar_path(a: String) -> String:
	var s := a.trim_prefix("lws:").trim_prefix("/")
	return "data/avatars/%s.gltf" % s


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
	var key := String(rec.get("name", ""))
	if sims.has(key):
		return sims[key]
	var s := PogSim.new()
	s.world = self
	s.name = key
	s.rec = rec
	s.faction = String(rec.get("faction", ""))
	sims[key] = s
	return s


func find_by_name(name: String) -> PogSim:
	if sims.has(name):
		return sims[name]
	if game == null:
		return null
	for rec in game.objects:
		if String(rec.get("name", "")) == name:
			return _wrap_record(rec)
	for ai in game.ai_ships:
		if is_instance_valid(ai) and ai.display_name == name:
			return _wrap_ship(ai)
	return null


func _wrap_ship(ai: Node3D) -> PogSim:
	var key := String(ai.display_name)
	if sims.has(key):
		return sims[key]
	var s := PogSim.new()
	s.world = self
	s.name = key
	s.node = ai
	s.faction = String(ai.faction)
	sims[key] = s
	return s


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
	var ai := AiShip.new()
	ai.main = game
	ai.display_name = name
	ai.ctype = String(props.get("type", "TRANS")).trim_prefix("T_")
	ai.avatar_path = avatar_path(String(rec.get("avatar", "")))
	ai.setup(props if not props.is_empty() else {"hit_points": 600})
	var mdl: Node3D = game._load_gltf(ai.avatar_path)
	if mdl != null:
		ai.add_child(mdl)
		ShipEffects.attach(ai, mdl)
	ai.position = Vector3.ZERO
	game.add_child(ai)
	game.ai_ships.append(ai)
	s.node = ai
	sims[name] = s
	return s


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
	var rec: Dictionary = {
		"name": name, "category": "prop",
		"x": 0.0, "y": 0.0, "z": 0.0,
		"radius": 100.0, "avatar": "", "jumps": [], "colors": [],
		"node": null, "prop_collide": true,
	}
	game.objects.append(rec)
	s.rec = rec
	sims[name] = s
	return s


# ---------------------------------------------------------------- sim
# @native sim.Create
func _s_create(_t, a: Array) -> Variant:
	var ini := PogStd._s(a[0])
	var name := PogStd._s(a[1]) if a.size() > 1 else ini.get_file()
	if "/ships/" in ini:
		return _create_ship(ini, name)
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
# @stub sim.AvatarAddChannel
# @stub sim.AvatarSetChannel
# @stub sim.AvatarRemoveChannel
# @stub sim.AddSubsim
# @stub sim.FindSubsimByName
func _s_noop(_t, _a: Array) -> Variant:
	# Culling, collision toggles, mass and the avatar channel-expression system
	# (LZ?+s(1.0) and friends) have no effect on the outcome of a mission; they
	# are presentation. Bound so the scripts run; see docs/decompile.md.
	return 0

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
	var origin := centre.abs_pos()
	var out: Array = []
	for ai in game.ai_ships:
		if is_instance_valid(ai) \
				and (player_pos() + ai.position).distance_to(origin) <= r:
			out.append(_wrap_ship(ai))
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
	for s in _i_sims_in_radius(_t, a):
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

## The engine's IeSimType is a bit flag, and the scripts compare against the raw
## number (isim.Type(s) == 131072). The ship INIs name the same thing in words
## ("T_CommandSection"), so map between them here.
const SIM_TYPE := {
	"T_CommandSection": 1 << 17,   # 131072, the hull the campaign opens in
	"T_Fighter": 1 << 0,
	"T_Corvette": 1 << 1,
	"T_Freighter": 1 << 2,
	"T_Transport": 1 << 3,
	"T_Station": 1 << 4,
	"T_Alien": 1 << 5,
	"T_Utility": 1 << 6,
	"T_Tug": 1 << 7,
}

# @native isim.Type
func _i_type(_t, a: Array) -> Variant:
	# NB only T_CommandSection is confirmed against the bytecode (131072); the
	# rest of the flags are placeholders until we read the enum out of the
	# engine. Returning an int either way keeps the scripts' comparisons legal.
	var s := _as_sim(a[0])
	if s == null or s.node == null or not is_instance_valid(s.node):
		return 0
	if not ("ctype" in s.node):
		return 0
	return int(SIM_TYPE.get("T_" + String(s.node.ctype), 0))

# @native isim.IsDocked
# @native isim.IsDockedTo
# @native isim.IsDockedToStructure
func _i_is_docked(_t, _a: Array) -> Variant:
	return 1 if (game != null and game.docked_at != "") else 0

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
	ExplosionFx.boom(game, pos, 70.0)
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
	# The scripts jump a ship to another system by name. For the player that is
	# the real capsule-jump sequence; an AI ship just leaves.
	var s := _as_sim(a[0])
	if s == null or game == null:
		return 0
	var dest := PogStd._s(a[1]) if a.size() > 1 else ""
	if s.is_player:
		if not dest.is_empty():
			game.start_in_system(dest.to_lower().replace(" ", "_"))
	else:
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
# @stub isim.AlienInfectionEffect
# @stub isim.IsAlienInfectionEffectOn
# @stub isim.SetAlienInfectionDamage
# @stub isim.WeaponTargetsFromContactList
# @stub isim.IsRespawning
func _i_noop(_t, _a: Array) -> Variant:
	# The alien infection is the Act 3 visual: a spreading crust on an infected
	# hull, with a damage-over-time behind it. Both halves need an avatar shader
	# we have not built, and StopExplosion cancels a staged explosion that
	# iiSim::StartExplosion never staged (ours is instantaneous, see
	# docs/original.md "The explosion sequence"). WeaponTargetsFromContactList and
	# IsRespawning are turret-targeting and multiplayer respawn.
	return 0


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
func _sh_has_fired(_t, _a: Array) -> Variant:
	return 0

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
# @stub iship.LastFireTarget
# @stub iship.BrightnessOf
# @stub iship.PercentageThrusterEmission
# @stub iship.RecalculateMOIFromMass
# @stub iship.IsLDSScrambled
# @stub iship.HasHyperSpaceTracker
# @stub iship.HyperSpaceTrackerTarget
# @stub iship.CreateTurretFighters
func _sh_noop(_t, _a: Array) -> Variant:
	# Turret targeting modes (a ship's turrets either track its own target or pick
	# their own off the contact list) need the turret subsims we do not simulate;
	# the hyperspace tracker is the Act 3 plot device that follows a capsule jump;
	# BrightnessOf and PercentageThrusterEmission are avatar channel expressions.
	return 0


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
	"sim.setmass": "_s_noop", "sim.avataraddchannel": "_s_noop",
	"sim.avatarsetchannel": "_s_noop", "sim.avatarremovechannel": "_s_noop",
	"sim.addsubsim": "_s_noop", "sim.findsubsimbyname": "_s_noop",
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
	"isim.alieninfectioneffect": "_i_noop",
	"isim.isalieninfectioneffecton": "_i_noop",
	"isim.setalieninfectiondamage": "_i_noop",
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
	"iship.lastfiretarget": "_sh_noop", "iship.dock": "_sh_dock",
	"iship.undock": "_sh_undock", "iship.undockself": "_sh_undock",
	"iship.brightnessof": "_sh_noop",
	"iship.percentagethrusteremission": "_sh_noop",
	"iship.recalculatemoifrommass": "_sh_noop",
	"iship.isldsscrambled": "_sh_noop",
	"iship.hashyperspacetracker": "_sh_noop",
	"iship.hyperspacetrackertarget": "_sh_noop",
	"iship.createturretfighters": "_sh_noop",
	"iship.createplayership": "_sh_create_player_ship",

	"imapentity.findbyname": "_s_find_by_name",
	"imapentity.findbynameinsystem": "_s_find_in_system",
	"imapentity.cast": "_s_cast",
	"ihabitat.cast": "_s_cast", "istation.cast": "_s_cast",
}
