class_name PogEntities
extends RefCounted

## imapentity, ihabitat, ilagrangepoint, idockport, ibody, iregion, subsim:
## the packages that address the *authored* world rather than the ships in it.
##
## Everything these packages talk about already exists in our data. A "map
## entity" is a record in main.objects; a habitat is one with category
## "station"; a body is a planet or moon; an L-point is the thing you capsule
## jump from. So this file adds no second registry: it leans on PogWorld's sims
## and only supplies what the records alone cannot answer.
##
## Two things needed real machinery. Dockports are authored as subsims in the
## station and ship INIs (data/json/stations.json + subsims.json), each with a
## type_flags bitmask, so idockport enumerates the ports a sim actually has
## rather than inventing them. And regions -- iregion.CreateLDSI, the
## LDS-inhibition bubbles the missions drop around a target, and its speed-limit
## sibling CreateTrafficControl -- are enforced per frame against the player,
## because a region that nothing checks is not a region.
##
## The geography (which body a station orbits, an entity's index in the system
## map) lives in the system JSON but not in the records main.gd builds from it,
## so it is re-read here and cached.

var vm   ## the host: PogRuntime for the ported scripts, PogVM for the oracle
var world: PogWorld
var game: Node3D = null

## iregion.* -- the live regions, in creation order.
var regions: Array = []
## subsim.* -- every subsim the scripts made, dockports included.
var subsims: Array = []

var _ports: Dictionary = {}        ## PogSim instance id -> Array[PogSubsim]
var _station_db: Dictionary = {}   ## avatar stem -> stations.json record
var _subsim_db: Dictionary = {}    ## "subsims/x.ini" -> subsims.json record
var _waypoints: Dictionary = {}    ## entity name -> waypoint PogSim
var _geog: Dictionary = {}         ## entity name -> system JSON object
var _geog_by_index: Dictionary = {}
var _geog_stem := ""


## An LDS-inhibition or traffic-control bubble: a centre sim plus a radius.
## The engine's icLDSIRegion / icTrafficControlRegion.
class PogRegion extends RefCounted:
	var kind: String = "ldsi"      ## "ldsi" or "traffic"
	var centre = null              ## PogWorld.PogSim
	var radius: float = 0.0
	var speed_limit: float = 0.0
	var dead := false

	## Whether the PLAYER sits inside, differenced in doubles (issue #27): a
	## float32 world point at AU coordinates quantises by >100 km, more than
	## most region radii.
	func contains_player(w) -> bool:
		if dead or centre == null or not centre.alive():
			return false
		return centre.dist_to(w.player_sim()) < radius


## A subsim: a piece of equipment bolted to a sim. Dockports are the only kind
## the scripts reason about in detail, so the docking state lives here too.
class PogSubsim extends RefCounted:
	var ini: String = ""
	var name: String = ""
	var klass: String = ""         ## "icDockPort", "icWeapon", ...
	var type_flags: int = 0        ## the authored dockport compatibility mask
	var owner = null               ## PogWorld.PogSim it is attached to
	var offset: Vector3 = Vector3.ZERO
	var euler: Vector3 = Vector3.ZERO
	var disabled := false
	var docked = null              ## the PogSubsim we are mated to
	var dead := false

	func is_dockport() -> bool:
		return klass == "icDockPort"

	func free_port() -> bool:
		return is_dockport() and not dead and not disabled and docked == null


func register(v, w: PogWorld) -> void:
	vm = v
	world = w
	for fq in _BINDINGS:
		v.bind(fq, Callable(self, _BINDINGS[fq]))


func bind_game(main: Node3D) -> void:
	game = main
	_load_dbs()
	# The regions have to be tested against the player every frame; a script
	# calls CreateLDSI once and then never touches it again.
	main.get_tree().process_frame.connect(_region_tick)


# ---------------------------------------------------------------- data

func _load_dbs() -> void:
	if game == null or not _station_db.is_empty():
		return
	for rec in game._load_json("data/json/stations.json"):
		_station_db[_avatar_stem(String(rec.get("avatar", "")))] = rec
	for rec in game._load_json("data/json/subsims.json"):
		_subsim_db[PogWorld.ini_key(String(rec.get("path", "")))] = rec


## "lws:/avatars/ModularStations/AdminStation" and the record's
## "avatars/modularstations/adminstation.gltf" have to meet in the middle.
static func _avatar_stem(a: String) -> String:
	var s := a.to_lower().trim_prefix("lws:").trim_prefix("/")
	s = s.trim_suffix(".gltf").trim_suffix("/setup")
	return s.get_file()


## The system JSON keeps the map hierarchy (index, parent) that main.gd drops
## when it flattens the file into objects[].
func _geog_table() -> Dictionary:
	if game == null:
		return {}
	if _geog_stem == game.system_stem and not _geog.is_empty():
		return _geog
	_geog.clear()
	_geog_by_index.clear()
	_geog_stem = game.system_stem
	var sys = game._load_json("data/json/systems/%s.json" % _geog_stem)
	if sys == null:
		return _geog
	for o in sys.get("objects", []):
		_geog[String(o.get("name", ""))] = o
		_geog_by_index[int(o.get("index", -1))] = o
	return _geog


func _geog_of(s) -> Dictionary:
	if s == null:
		return {}
	var t := _geog_table()
	return t.get(s.name, {})


# ---------------------------------------------------------------- helpers

func _sim(v: Variant):
	return world._as_sim(v)


func _category(s) -> String:
	if s == null or s.rec.is_empty():
		return ""
	return String(s.rec.get("category", ""))


func _is_habitat(s) -> bool:
	return _category(s) == "station"


func _is_body(s) -> bool:
	var c := _category(s)
	return c == "body" or c == "star"


func _is_lpoint(s) -> bool:
	return _category(s) == "lpoint"


## Every objects[] record of a category, wrapped as sims. This is what the
## System* natives hand the scripts to filter and sort.
func _entities_of(category: String) -> Array:
	var out: Array = []
	if game == null:
		return out
	for rec in game.objects:
		if String(rec.get("category", "")) == category:
			out.append(world._wrap_record(rec))
	return out


## Nearest(set, sim): the set is the candidate pool, the sim is the yardstick.
## An empty pool means "anything of this kind", which is main._nearest.
func _nearest_of(pool: Variant, ref, category: String):
	# issue #27: ranked in doubles -- float32 absolutes at AU coordinates
	# quantise by >100 km and re-order near ties arbitrarily
	var yard = ref if ref != null else world.player_sim()
	var candidates: Array = pool if pool is Array else []
	if candidates.is_empty():
		candidates = _entities_of(category)
	var best = null
	var bestd := INF
	for c in candidates:
		var s = _sim(c)
		if s == null or not s.alive():
			continue
		var d: float = yard.dist_to(s)
		if d < bestd:
			bestd = d
			best = s
	return best


func _random_of(pool: Variant):
	var candidates: Array = pool if pool is Array else []
	if candidates.is_empty():
		return null
	return candidates[randi() % candidates.size()]


# ---------------------------------------------------------------- regions

## LDS inhibition and traffic control only exist if something enforces them.
## main.gd already inhibits LDS near stations and planets and locks the drive
## out through disrupt_time, so a scripted region reuses that same lockout;
## a traffic control region is a speed limit (icTrafficControlRegion, and the
## engine's EnterSpeedLimitRegion), so it caps the throttle.
func _region_tick() -> void:
	if game == null or not is_instance_valid(game) or regions.is_empty():
		return
	if game.docked_at != "" or game.jump_state != 0:
		return
	for r in regions:
		if not r.contains_player(world):
			continue
		if r.kind == "ldsi":
			if game.lds_state != 0:
				# Drops the drive with the warning and the LDSi sound, exactly
				# as an inhibitor hit does. Only fires on the way in: disrupt()
				# zeroes lds_state.
				game.disrupt(3.0)
			else:
				# Hold the lockout while the player stays inside the bubble.
				game.disrupt_time = maxf(game.disrupt_time, 0.25)
		elif r.kind == "traffic" and game.ship != null:
			if game.ship.set_speed > r.speed_limit:
				game.ship.set_speed = r.speed_limit

# @native iregion.CreateLDSI
func _r_create_ldsi(_t, a: Array) -> Variant:
	# CreateLDSI(centre_sim, radius_metres): the missions drop one of these on a
	# target so the player cannot outrun the fight.
	var r := PogRegion.new()
	r.kind = "ldsi"
	r.centre = _sim(a[0])
	r.radius = float(a[1]) if a.size() > 1 else 0.0
	regions.append(r)
	return r

# @native iregion.CreateTrafficControl
func _r_create_traffic(_t, a: Array) -> Variant:
	# CreateTrafficControl(centre_sim, radius, speed_limit): the approach lanes
	# around a station, where the law expects you to slow down.
	var r := PogRegion.new()
	r.kind = "traffic"
	r.centre = _sim(a[0])
	r.radius = float(a[1]) if a.size() > 1 else 0.0
	r.speed_limit = float(a[2]) if a.size() > 2 else 0.0
	regions.append(r)
	return r

# @native iregion.Destroy
func _r_destroy(_t, a: Array) -> Variant:
	var r = a[0] if a.size() > 0 else null
	if r is PogRegion:
		r.dead = true
		regions.erase(r)
	return 0


## Whether the player sits inside a scripted LDS-inhibition region. Kept
## public because it is the one piece of state outside this file's packages
## that a caller might reasonably want.
func lds_inhibited() -> bool:
	for r in regions:
		if r.kind == "ldsi" and r.contains_player(world):
			return true
	return false


## The nearest scripted LDS-inhibition region to the PLAYER, for the HUD
## roundel and the LDSi fence. Returns the region's PLAYER-RELATIVE centre
## (differenced in doubles, issue #27 -- a world-frame float32 centre at AU
## coordinates is off by up to the ULP's ~131 km), its radius, and the signed
## clearance (negative inside the sphere); {} when no live inhibitor exists.
## icLDSIRegion is a centre+radius sphere (iwar2 @ 0x10048870); only
## kind=="ldsi" regions -- the iRegion.CreateLDSI zones -- are LDS inhibitors.
## (icTrafficControlRegion::OnSimEnter @ 0x1004f3e0 also calls
## EnterLDSInhibitRegion, so approach lanes inhibit too in the original; the
## remaster still models "traffic" as a speed cap only -- see docs/lds.md.)
func nearest_ldsi() -> Dictionary:
	var best := {}
	var bestc := INF
	var me = world.player_sim()
	for r in regions:
		if r.kind != "ldsi" or r.dead or r.centre == null or not r.centre.alive():
			continue
		var clear: float = me.dist_to(r.centre) - r.radius
		if clear < bestc:
			bestc = clear
			best = {"center": me.dvec_to(r.centre), "r": r.radius,
				"clear": clear}
	return best


# ---------------------------------------------------------------- subsim
# subsim.Create("ini:/subsims/dockports/universal_port") then Place/Orientate:
# the scripts bolt equipment onto a sim they just built. The INI gives the
# class and, for dockports, the compatibility mask.

# @native subsim.Create
func _ss_create(_t, a: Array) -> Variant:
	var ini := PogStd._s(a[0])
	var ss := PogSubsim.new()
	ss.ini = ini
	var rec: Dictionary = _subsim_db.get(PogWorld.ini_key(ini), {})
	var props: Dictionary = rec.get("properties", {})
	ss.klass = String(rec.get("class", ""))
	ss.name = String(props.get("name", ini.get_file()))
	ss.type_flags = int(props.get("type_flags", 0))
	subsims.append(ss)
	return ss

# @native subsim.Place
func _ss_place(_t, a: Array) -> Variant:
	var ss = a[0] if a.size() > 0 else null
	if ss is PogSubsim:
		ss.offset = PogWorld.vec(a[1], a[2], a[3])
	return 0

# @native subsim.OrientateEuler
func _ss_orientate(_t, a: Array) -> Variant:
	var ss = a[0] if a.size() > 0 else null
	if ss is PogSubsim:
		# Degrees in the scripts (180, -90, 0), radians here.
		ss.euler = Vector3(deg_to_rad(float(a[1])), deg_to_rad(float(a[2])),
				deg_to_rad(-float(a[3])))
	return 0

# @native subsim.Destroy
func _ss_destroy(_t, a: Array) -> Variant:
	var ss = a[0] if a.size() > 0 else null
	if ss is PogSubsim:
		ss.dead = true
		if ss.docked is PogSubsim:
			ss.docked.docked = null
			ss.docked = null
		subsims.erase(ss)
	return 0

# @native subsim.Cast
func _ss_cast(_t, a: Array) -> Variant:
	var v = a[0] if a.size() > 0 else null
	return v if v is PogSubsim else null


# ---------------------------------------------------------------- idockport
# The ports are authored, not scripted: every station and ship INI lists its
# dockport subsims, and every dockport INI carries a type_flags bitmask (a
# universal port is 17, a cargo clamp 2, an unload port 4). So the ports a sim
# has are looked up, once, from the same data the original engine loaded.

func _dockports_of(s) -> Array:
	if s == null:
		return []
	var key: int = s.get_instance_id()
	if _ports.has(key):
		return _ports[key]
	var out: Array = []
	var rec: Dictionary = {}
	if not s.ini.is_empty():
		rec = world.ship_db.get(PogWorld.ini_key(s.ini), {})
	if rec.is_empty() and not s.rec.is_empty():
		rec = _station_db.get(_avatar_stem(String(s.rec.get("avatar", ""))), {})
	for sub in rec.get("subsims", []):
		var ss = _ss_create(null, [String(sub.get("template", ""))])
		if ss is PogSubsim and ss.is_dockport():
			ss.owner = s
			out.append(ss)
	_ports[key] = out
	return out


## The scripts pass two ints. The last is the port type: it is matched against
## the authored type_flags mask, and it is the argument that varies with the
## kind of port being asked for. The other is a filter whose meaning we could
## not pin down (see the report); a zero type falls back to it so that no query
## silently matches nothing.
func _ports_matching(s, mask_a: int, mask_b: int) -> Array:
	var mask := mask_b if mask_b != 0 else mask_a
	var out: Array = []
	for p in _dockports_of(s):
		if p.dead or p.disabled:
			continue
		if mask == 0 or (p.type_flags & mask) != 0:
			out.append(p)
	return out

# @native idockport.DockportsOfType
func _dp_of_type(_t, a: Array) -> Variant:
	return _ports_matching(_sim(a[0]), int(a[1]), int(a[2]))

# @native idockport.DockportsCompatibleWith
func _dp_compatible(_t, a: Array) -> Variant:
	return _ports_matching(_sim(a[0]), int(a[1]), int(a[2]))

# @native idockport.Count
func _dp_count(_t, a: Array) -> Variant:
	return _ports_matching(_sim(a[0]), int(a[1]), int(a[2])).size()

# @native idockport.Cast
func _dp_cast(_t, a: Array) -> Variant:
	var v = a[0] if a.size() > 0 else null
	return v if (v is PogSubsim and v.is_dockport()) else null

# @native idockport.Enable
func _dp_enable(_t, a: Array) -> Variant:
	var p = a[0] if a.size() > 0 else null
	if p is PogSubsim:
		p.disabled = false
	return 0

# @native idockport.Disable
func _dp_disable(_t, a: Array) -> Variant:
	# The missions close ports to force a ship (or the player) to dock elsewhere.
	var p = a[0] if a.size() > 0 else null
	if p is PogSubsim:
		p.disabled = true
	return 0

# @native idockport.IsDisabled
func _dp_is_disabled(_t, a: Array) -> Variant:
	var p = a[0] if a.size() > 0 else null
	return 1 if (p is PogSubsim and p.disabled) else 0


## Dock(a, b) is called with either dockports or the sims that own them, in
## either order, so both arguments are resolved the same way.
func _resolve_port(v: Variant):
	if v is PogSubsim:
		return v
	var s = _sim(v)
	if s == null:
		return null
	for p in _dockports_of(s):
		if p.free_port():
			return p
	return null

# @native idockport.Dock
func _dp_dock(_t, a: Array) -> Variant:
	var pa = _resolve_port(a[0])
	var pb = _resolve_port(a[1] if a.size() > 1 else null)
	if pa == null or pb == null or pa == pb:
		return 0
	var sa = pa.owner
	var sb = pb.owner
	# isim.SetDockingLock: a locked ship has exactly one berth it may take.
	if not world.docking_allowed(sa, sb) or not world.docking_allowed(sb, sa):
		return 0
	pa.docked = pb
	pb.docked = pa
	if sa == null or sb == null:
		return 0
	# The mobile half moves onto the static one; a station never moves.
	var mover = sa if not _is_habitat(sa) else sb
	var host = sb if mover == sa else sa
	if game != null and mover.is_player:
		game.docked_at = host.name
		if game.ship != null:
			game.ship.velocity = Vector3.ZERO
			game.ship.set_speed = 0.0
	else:
		mover.set_dabs(host.dabs(),
				Vector3.UP * (host.radius() + mover.radius()))
	return 0


# ---------------------------------------------------------------- imapentity
# A map entity is any authored object in the system: bodies, stars, habitats,
# L-points. FindByName / FindByNameInSystem / Cast are PogWorld's (world.gd);
# everything else about the map lives here.

# @native imapentity.Name
func _m_name(_t, a: Array) -> Variant:
	var s = _sim(a[0])
	return s.name if s != null else ""

# @native imapentity.SetHidden
func _m_set_hidden(_t, a: Array) -> Variant:
	# Whole planets get hidden in Act 2 (Dante). The impostor is a lazily
	# instanced node hanging off the record.
	if a.size() > 0 and a[0] is PogWorld.ForeignRef and game != null:
		var fr: PogWorld.ForeignRef = a[0]
		game.flag_entity(fr.stem, fr.ename, "hidden", PogVM._truthy(a[1]))
		return 0
	var s = _sim(a[0])
	if s == null:
		return 0
	var hide := PogVM._truthy(a[1])
	if game != null:
		game.flag_entity(game.system_stem, s.name, "hidden", hide)
	s.hidden = hide
	if not s.rec.is_empty():
		s.rec["hidden"] = hide
		var n = s.rec.get("node")
		if n != null and is_instance_valid(n):
			n.visible = not hide
	elif s.node != null and is_instance_valid(s.node):
		s.node.visible = not hide
	return 0

# @native imapentity.IsDestroyed
func _m_is_destroyed(_t, a: Array) -> Variant:
	var s = _sim(a[0])
	return 0 if (s != null and s.alive()) else 1

# @native imapentity.SetDestroyed
func _m_set_destroyed(_t, a: Array) -> Variant:
	var s = _sim(a[0])
	if s == null:
		return 0
	if PogVM._truthy(a[1]):
		world._s_destroy(_t, [s])
	else:
		s.dead = false
	return 0

# @native imapentity.EntityToSimDistance
func _m_entity_distance(_t, a: Array) -> Variant:
	var e = _sim(a[0])
	var s = _sim(a[1])
	if e == null or s == null:
		return 0.0
	return e.dist_to(s)  # doubles: issue #27

# @native imapentity.SimForEntity
func _m_sim_for_entity(_t, a: Array) -> Variant:
	# The engine kept the map entity and the physical sim apart; PogSim is both,
	# so the entity IS its sim.
	return _sim(a[0])

# @native imapentity.WaypointForEntity
func _m_waypoint_for(_t, a: Array) -> Variant:
	# A nav marker on the entity. Waypoints are records of category "lpoint"
	# flagged waypoint=true, which is what mission.gd builds and the HUD draws.
	var s = _sim(a[0])
	if s == null or game == null:
		return null
	if _waypoints.has(s.name):
		var w = _waypoints[s.name]
		if w != null and w.alive():
			w.set_dabs(s.dabs())
			return w
	var p := s.dabs()  # doubles: an AU-scale marker must not quantise (#27)
	var rec: Dictionary = {
		"name": "%s Waypoint" % s.name, "category": "lpoint",
		"x": p[0], "y": p[1], "z": p[2],
		"radius": 0.0, "avatar": "", "jumps": [], "colors": [],
		"node": null, "waypoint": true,
	}
	game.objects.append(rec)
	var wp = world._wrap_record(rec)
	_waypoints[s.name] = wp
	return wp

# @native imapentity.GeogIndex
func _m_geog_index(_t, a: Array) -> Variant:
	var g := _geog_of(_sim(a[0]))
	return int(g.get("index", 0)) if not g.is_empty() else 0

# @native imapentity.Parent
func _m_parent(_t, a: Array) -> Variant:
	# The map is a tree: a station's parent is the body it orbits, a body's is
	# the star. The link is the system JSON's parent index.
	var g := _geog_of(_sim(a[0]))
	if g.is_empty():
		return null
	var pg = _geog_by_index.get(int(g.get("parent", -1)))
	if pg == null:
		return null
	return world.find_by_name(String(pg.get("name", "")))

# @native imapentity.RadiusOfInfluence
func _m_radius_of_influence(_t, a: Array) -> Variant:
	# The map radius the geography authored for the object, which is exactly the
	# sphere the scripts mean by "influence" (it is not the physical radius:
	# a planet's runs to millions of metres).
	var s = _sim(a[0])
	return s.radius() if s != null else 0.0

# @native imapentity.SystemHabitats
# @native imapentity.SystemHabitatsInSystem
func _m_habitats(_t, _a: Array) -> Variant:
	# The InSystem variant names a system by map path. Only one system is ever
	# resident, and PogWorld's FindByNameInSystem already reads it the same way.
	return _entities_of("station")

# @native imapentity.SystemBodies
func _m_bodies(_t, _a: Array) -> Variant:
	return _entities_of("body")

# @native imapentity.SystemLagrangePoints
# @native imapentity.SystemLagrangePointsInSystem
func _m_lpoints(_t, _a: Array) -> Variant:
	return _entities_of("lpoint")

# @native imapentity.SystemName
func _m_system_name(_t, _a: Array) -> Variant:
	return game.system_name if game != null else ""

# @native imapentity.SystemCentre
func _m_system_centre(_t, _a: Array) -> Variant:
	# The system's root entity. Our loader drops the "system" record itself, but
	# the star sits at the same place and is the thing the scripts measure from.
	var stars := _entities_of("star")
	return stars[0] if not stars.is_empty() else null

# @native imapentity.SetMapVisibility
# @native imapentity.IsVisibleOnMap
func _m_map_visibility(_t, a: Array) -> Variant:
	# The flag lives on the record and icHUDStarmap honours it: the 56
	# SetMapVisibility calls are how the missions hide stations, wrecks and
	# beacons from the map until the plot reveals them. Map-scoped only -- a
	# hidden entity still appears on sensors and in the contact list. The
	# toggle also persists in main.entity_flags (records are rebuilt per
	# system load), and a ForeignRef writes the store for a system that is
	# not resident (HideMapLocations hides Dante's stations from elsewhere).
	if a.size() > 0 and a[0] is PogWorld.ForeignRef and game != null:
		var fr: PogWorld.ForeignRef = a[0]
		if a.size() > 1:
			game.flag_entity(fr.stem, fr.ename, "map_visible",
					PogVM._truthy(a[1]))
			return 0
		return 1 if bool(game.entity_flag(fr.stem, fr.ename,
				"map_visible", true)) else 0
	var s = _sim(a[0])
	if s == null or s.rec.is_empty():
		return 1
	if a.size() > 1:
		var vis := PogVM._truthy(a[1])
		s.rec["map_visible"] = vis
		if game != null:
			game.flag_entity(game.system_stem, s.name, "map_visible", vis)
		return 0
	return 1 if bool(s.rec.get("map_visible", true)) else 0


# ---------------------------------------------------------------- ihabitat
# Habitats are the stations: the places with people, dockports and guns.

# @native ihabitat.FindByName
func _hab_find(_t, a: Array) -> Variant:
	var s = world.find_by_name(PogStd._s(a[0]))
	return s if _is_habitat(s) else null

# @native ihabitat.Nearest
func _hab_nearest(_t, a: Array) -> Variant:
	return _nearest_of(a[0], _sim(a[1]) if a.size() > 1 else null, "station")

# @native ihabitat.Random
func _hab_random(_t, a: Array) -> Variant:
	return _random_of(a[0])

# @native ihabitat.FilterOrbiting
func _hab_filter_orbiting(_t, a: Array) -> Variant:
	# Orbiting means "parented to a body" in the map tree, as against the
	# habitats parked in deep space at an L-point.
	var out: Array = []
	for h in (a[0] if a[0] is Array else []):
		var s = _sim(h)
		var g := _geog_of(s)
		if g.is_empty():
			continue
		var pg = _geog_by_index.get(int(g.get("parent", -1)))
		if pg != null and String(pg.get("category", "")) == "body":
			out.append(s)
	return out

# @native ihabitat.Allegiance
func _hab_allegiance(_t, a: Array) -> Variant:
	var s = _sim(a[0])
	if s == null or world.factions == null:
		return null
	var fac: String = s.faction
	if fac.is_empty() and game != null and not s.rec.is_empty():
		# The station records carry no faction; main.gd derives one from the
		# name ("Coyote Police Station" -> LAW) for the contact list.
		fac = game._station_faction(s.name)
	return world.factions._f_find(null, [fac])

# @native ihabitat.HasSpewer
func _hab_has_spewer(_t, a: Array) -> Variant:
	return 1 if not _spewers(_sim(a[0])).is_empty() else 0

# @native ihabitat.HasSpewerSlotFree
func _hab_spewer_free(_t, a: Array) -> Variant:
	for p in _spewers(_sim(a[0])):
		if p.free_port():
			return 1
	return 0

## The spewer ports: the cargo clamps a station launches pods and traffic from.
## type_flags bit 64 is the spewer bit (spewer_cargo_port_only is 64, the pod
## port 67, the turret-fighter port 99).
func _spewers(s) -> Array:
	var out: Array = []
	for p in _dockports_of(s):
		if not p.dead and (p.type_flags & 64) != 0:
			out.append(p)
	return out

# @native ihabitat.Spew
func _hab_spew(_t, a: Array) -> Variant:
	# Spew(habitat, sim): the station ejects the sim from a spewer port. The
	# traffic scripts build a freighter, then spew it.
	var h = _sim(a[0])
	var s = _sim(a[1] if a.size() > 1 else null)
	if h == null or s == null:
		return 0
	for p in _spewers(h):
		if p.free_port():
			p.docked = null
			break
	var dir := Vector3(randf() - 0.5, randf() - 0.5, randf() - 0.5).normalized()
	s.set_dabs(h.dabs(), dir * (h.radius() + 200.0))
	if s.node != null and is_instance_valid(s.node):
		s.node.velocity = dir * 60.0
	return 0

# @native ihabitat.CastIntToHabitatType
func _hab_cast_int(_t, a: Array) -> Variant:
	# A compile-time cast: the int the script read out of a property bag is
	# already the enum value.
	return int(a[0])

## IeHabitatType is authored per station instance, in the system map record: the
## byte at `+0x135`, which map_decoder.py calls `station_subtype` and which
## `icStation::Load` copies to `icStation+0x1e0` -- exactly the field
## `icStation::HabitatType()` (iwar2 @ 0x1004ada0) returns. The getter is a bare
## field read, so there is no logic to recover beyond the value.
##
## The enum is never named in the binary, but the data names it for us:
##   - every station whose avatar is `policestation` has 68 or 69, and
##     ifight.pog:111 builds its "police" set as exactly
##     FilterOnType(68) UNION FilterOnType(69);
##   - 54 is `securitystation` (26 of 27) and 55 the fortresses; every subtype on
##     a `navalbasestation` -- 70, 71, 73, 74, 79, 81, 85 -- falls inside the set
##     ifight.pog:187 unions for "military" (72,73,70,71,79,82,85,54,55,78);
##   - the names read back straight: 70 "Defense Station", 71 "Defence Dock",
##     73 "Naval Training Base", 79 "Naval Defences", 122 "Orbital Transfer
##     Station".
func _habitat_type(s) -> int:
	var g := _geog_of(s)
	return int(g.get("station_subtype", 0)) if not g.is_empty() else 0

# @native ihabitat.Type
func _hab_type(_t, a: Array) -> Variant:
	return _habitat_type(_sim(a[0]))

# @native ihabitat.FilterOnType
func _hab_filter_type(_t, a: Array) -> Variant:
	var want := int(a[1]) if a.size() > 1 else 0
	var out: Array = []
	for h in (a[0] if a[0] is Array else []):
		var s = _sim(h)
		if s != null and _habitat_type(s) == want:
			out.append(s)
	return out

# @native ihabitat.FilterOnAllegiance
func _hab_filter_allegiance(_t, a: Array) -> Variant:
	# The allegiance is the station's faction, which _hab_allegiance already
	# resolves; the argument is the faction to keep.
	var want = a[1] if a.size() > 1 else null
	var name: String = want.name if want is PogFactions.PogFaction \
			else PogStd._s(want)
	var out: Array = []
	for h in (a[0] if a[0] is Array else []):
		var s = _sim(h)
		if s == null:
			continue
		var f = _hab_allegiance(_t, [s])
		if f is PogFactions.PogFaction and f.name == name:
			out.append(s)
	return out

# @stub ihabitat.Population
func _hab_population(_t, a: Array) -> Variant:
	# No census data survives in the extract -- the map record carries the type
	# but no headcount, and no INI has one. A nominal figure keeps the traffic
	# generators' "is anybody home" gates behaving.
	return 5000 if _is_habitat(_sim(a[0])) else 0

# @native ihabitat.SetArmed
func _hab_set_armed(_t, a: Array) -> Variant:
	# ihabitat.dll @ 0x10002840: armed -> iiSim::ConfigureWeapons(1, 0, 0)
	# (every turret to AUTO in its authored mode), disarmed ->
	# ConfigureWeapons(0, 0, 1) = iiSim::LockDownWeapons (fire mode 0, the
	# turrets slew back to stow). turrets.gd carries the recovered handler
	# (iwar2.dll @ 0x1007b8a0).
	var s = _sim(a[0])
	if s == null or Turrets.instance == null:
		return 0
	var armed: bool = a.size() > 1 and PogVM._truthy(a[1])
	if s.node is AiShip:
		if armed:
			Turrets.instance.arm_ship(s.node, null)
		else:
			for b in Turrets.instance.batteries:
				if b["owner"] == s.node:
					b["armed"] = false
					b["locked"] = null
	elif not s.rec.is_empty():
		if armed:
			Turrets.instance.arm_station(s.rec, null)
		else:
			Turrets.instance.disarm_station(s.rec)
	return 0

# @native ihabitat.SetArmedWithTarget
func _hab_set_armed_with_target(_t, a: Array) -> Variant:
	# ihabitat.dll @ 0x10002910: iiSim::ConfigureWeapons(1, target, 0) --
	# every turret goes to SetMode(1) (0x10033800) with the target id in its
	# fire-request slot (+0x84).
	var s = _sim(a[0])
	var t = _sim(a[1]) if a.size() > 1 else null
	if s == null or Turrets.instance == null:
		return 0
	var target: Node3D = null
	if t != null and t.node is Node3D and is_instance_valid(t.node):
		target = t.node
	if s.node is AiShip:
		Turrets.instance.arm_ship(s.node, target)
	elif not s.rec.is_empty():
		Turrets.instance.arm_station(s.rec, target)
	return 0

## icStation::m_damage_function -- ONE static FcString shared by every
## station, not a per-habitat slot (ihabitat.dll @ 0x100027d0 assigns the
## static; called with no argument it assigns the empty string).
var reactive_function := ""

# @native ihabitat.SetReactiveFunction
func _hab_set_reactive(_t, a: Array) -> Variant:
	reactive_function = PogStd._s(a[0]) if a.size() > 0 else ""
	return 0


## icStation::ApplyWeaponDamage (iwar2.dll @ 0x10068b70): after the base
## damage is applied, a non-empty m_damage_function starts a POG task
## FcScriptEngine::StartTask(fn, [station id, aggressor id, damage]) -- the
## campaign registers iStation.StationReactive(station, aggressor, damage),
## which is how shooting a station raises its protection response.
## main_combat.on_bolt_hit reports station hits here, once per hit, with the
## record it resolved and the same bolt damage the ship path applies.
func station_attacked(rec: Dictionary, aggressor_node: Node3D,
		dmg: float) -> void:
	if reactive_function.is_empty() or vm == null or world == null:
		return
	var station = world._wrap_record(rec)
	var aggressor = null
	if game != null and aggressor_node == game.ship:
		aggressor = world.player_sim()
	elif aggressor_node is AiShip:
		aggressor = world._wrap_ship(aggressor_node)
	if "ui" in vm and vm.ui != null:            # PogRuntime: args-through dispatch
		vm.ui.dispatch(reactive_function, [station, aggressor, dmg])
	elif vm.has_method("start"):                # PogVM: start the bytecode task
		vm.start(reactive_function.get_slice(".", 0).to_lower(),
			reactive_function.get_slice(".", 1), [station, aggressor, dmg])


# ---------------------------------------------------------------- ilagrangepoint
# The capsule-jump anchors. main.gd already flies the jump: an L-point record's
# "jumps" array is the list of system stems reachable from it, and being within
# JUMP_RANGE of one with a non-empty list is what lets the player leave.

# @native ilagrangepoint.Cast
func _lp_cast(_t, a: Array) -> Variant:
	# Must return null for anything that is not an L-point: the scripts branch
	# on this to tell an L-point apart from a station or a planet.
	if a.size() > 0 and a[0] is PogWorld.ForeignRef:
		return a[0]     # unverifiable without the foreign system loaded
	var s = _sim(a[0] if a.size() > 0 else null)
	return s if _is_lpoint(s) else null

# @native ilagrangepoint.FindByName
func _lp_find(_t, a: Array) -> Variant:
	var s = world.find_by_name(PogStd._s(a[0]))
	return s if _is_lpoint(s) else null

# @native ilagrangepoint.Nearest
func _lp_nearest(_t, a: Array) -> Variant:
	return _nearest_of(a[0], _sim(a[1]) if a.size() > 1 else null, "lpoint")

# @native ilagrangepoint.Random
func _lp_random(_t, a: Array) -> Variant:
	return _random_of(a[0])

# @native ilagrangepoint.Create
func _lp_create(_t, _a: Array) -> Variant:
	var rec: Dictionary = {
		"name": "L-Point %d" % (_entities_of("lpoint").size() + 1),
		"category": "lpoint", "x": 0.0, "y": 0.0, "z": 0.0,
		"radius": 0.0, "avatar": "", "jumps": [], "colors": [], "node": null,
	}
	if game == null:
		return null
	game.objects.append(rec)
	return world._wrap_record(rec)

# @native ilagrangepoint.SetUsable
func _lp_set_usable(_t, a: Array) -> Variant:
	# An unusable L-point is one you cannot jump from, and what main.gd reads to
	# decide that is the route list. Park the routes rather than lose them.
	if a.size() > 0 and a[0] is PogWorld.ForeignRef and game != null:
		var fr: PogWorld.ForeignRef = a[0]
		game.flag_entity(fr.stem, fr.ename, "usable", PogVM._truthy(a[1]))
		return 0
	var s = _sim(a[0])
	if s == null or s.rec.is_empty():
		return 0
	var usable := PogVM._truthy(a[1])
	if game != null:
		game.flag_entity(game.system_stem, s.name, "usable", usable)
	if usable:
		if s.rec.has("jumps_locked"):
			s.rec["jumps"] = s.rec["jumps_locked"]
			s.rec.erase("jumps_locked")
	elif not s.rec.has("jumps_locked"):
		s.rec["jumps_locked"] = s.rec.get("jumps", [])
		s.rec["jumps"] = []
	return 0

# @native ilagrangepoint.AddDestination
func _lp_add_destination(_t, a: Array) -> Variant:
	# AddDestination(from, to): the scripts wire the pairs both ways. If the
	# destination is in another system its stem becomes a capsule route; the
	# same-system pairs stay a local link (LocalDestinations reads them back).
	var from = _sim(a[0])
	var to = _sim(a[1] if a.size() > 1 else null)
	if from == null or to == null or from.rec.is_empty():
		return 0
	var dests: Array = from.rec.get("destinations", [])
	if not dests.has(to.name):
		dests.append(to.name)
	from.rec["destinations"] = dests
	return 0

# @native ilagrangepoint.LocalDestinations
func _lp_local_destinations(_t, a: Array) -> Variant:
	var s = _sim(a[0])
	if s == null or s.rec.is_empty():
		return []
	var out: Array = []
	for dest_name in s.rec.get("destinations", []):
		var d = world.find_by_name(String(dest_name))
		if d != null:
			out.append(d)
	return out

# @native ilagrangepoint.Interstellar
func _lp_interstellar(_t, a: Array) -> Variant:
	# Interstellar means it leaves the system: it has charted capsule routes.
	var s = _sim(a[0])
	if s == null or s.rec.is_empty():
		return 0
	var jumps: Array = s.rec.get("jumps", [])
	if jumps.is_empty():
		jumps = s.rec.get("jumps_locked", [])
	return 1 if not jumps.is_empty() else 0


# ---------------------------------------------------------------- ibody
# Planets, moons, asteroids, the star.

# @native ibody.Cast
func _b_cast(_t, a: Array) -> Variant:
	var s = _sim(a[0] if a.size() > 0 else null)
	return s if _is_body(s) else null

# @native ibody.Nearest
func _b_nearest(_t, a: Array) -> Variant:
	return _nearest_of(a[0], _sim(a[1]) if a.size() > 1 else null, "body")

# @native ibody.HabitatsAroundBody
func _b_habitats_around(_t, a: Array) -> Variant:
	# The stations parented to this body in the map tree.
	var s = _sim(a[0])
	var g := _geog_of(s)
	if g.is_empty():
		return []
	var idx := int(g.get("index", -1))
	var out: Array = []
	for h in _entities_of("station"):
		var hg := _geog_of(h)
		if not hg.is_empty() and int(hg.get("parent", -1)) == idx:
			out.append(h)
	return out

# @stub ibody.Type
# @stub ibody.FilterOnType
func _b_type_filter(_t, a: Array) -> Variant:
	# NOT the same story as IeHabitatType, which came out of the record cleanly.
	# The map record has two candidate fields and neither fits: `body_type`
	# (+0x134) only ever holds 2, 3, 4 or 6 across every shipped system, and
	# `planet_type` (+0x13C) only 1 or 2 -- while iscriptedorders.pog:517 tests
	# `5 != ibody.Type(v1)` and :1853 unions types 5 and 7. Nothing in the
	# geography produces a 5 or a 7. icPlanet::Type is a bare field read, so the
	# binary does not say where the loader got it either. Which field carries it
	# is an open question; pass the set through, report "unknown".
	var v = a[0] if a.size() > 0 else null
	if v is Array:
		return (v as Array).duplicate()
	return 0


const _BINDINGS := {
	"imapentity.name": "_m_name",
	"imapentity.sethidden": "_m_set_hidden",
	"imapentity.isdestroyed": "_m_is_destroyed",
	"imapentity.setdestroyed": "_m_set_destroyed",
	"imapentity.setmapvisibility": "_m_map_visibility",
	"imapentity.isvisibleonmap": "_m_map_visibility",
	"imapentity.entitytosimdistance": "_m_entity_distance",
	"imapentity.simforentity": "_m_sim_for_entity",
	"imapentity.waypointforentity": "_m_waypoint_for",
	"imapentity.geogindex": "_m_geog_index",
	"imapentity.parent": "_m_parent",
	"imapentity.radiusofinfluence": "_m_radius_of_influence",
	"imapentity.systemhabitats": "_m_habitats",
	"imapentity.systemhabitatsinsystem": "_m_habitats",
	"imapentity.systembodies": "_m_bodies",
	"imapentity.systemlagrangepoints": "_m_lpoints",
	"imapentity.systemlagrangepointsinsystem": "_m_lpoints",
	"imapentity.systemname": "_m_system_name",
	"imapentity.systemcentre": "_m_system_centre",

	"ihabitat.findbyname": "_hab_find", "ihabitat.nearest": "_hab_nearest",
	"ihabitat.random": "_hab_random",
	"ihabitat.filterorbiting": "_hab_filter_orbiting",
	"ihabitat.allegiance": "_hab_allegiance",
	"ihabitat.hasspewer": "_hab_has_spewer",
	"ihabitat.hasspewerslotfree": "_hab_spewer_free",
	"ihabitat.spew": "_hab_spew",
	"ihabitat.castinttohabitattype": "_hab_cast_int",
	"ihabitat.type": "_hab_type",
	"ihabitat.filterontype": "_hab_filter_type",
	"ihabitat.filteronallegiance": "_hab_filter_allegiance",
	"ihabitat.population": "_hab_population",
	"ihabitat.setarmed": "_hab_set_armed",
	"ihabitat.setarmedwithtarget": "_hab_set_armed_with_target",
	"ihabitat.setreactivefunction": "_hab_set_reactive",

	"ilagrangepoint.cast": "_lp_cast",
	"ilagrangepoint.findbyname": "_lp_find",
	"ilagrangepoint.nearest": "_lp_nearest",
	"ilagrangepoint.random": "_lp_random",
	"ilagrangepoint.create": "_lp_create",
	"ilagrangepoint.setusable": "_lp_set_usable",
	"ilagrangepoint.adddestination": "_lp_add_destination",
	"ilagrangepoint.localdestinations": "_lp_local_destinations",
	"ilagrangepoint.interstellar": "_lp_interstellar",

	"idockport.cast": "_dp_cast", "idockport.enable": "_dp_enable",
	"idockport.disable": "_dp_disable",
	"idockport.isdisabled": "_dp_is_disabled",
	"idockport.dock": "_dp_dock", "idockport.count": "_dp_count",
	"idockport.dockportsoftype": "_dp_of_type",
	"idockport.dockportscompatiblewith": "_dp_compatible",

	"iregion.createldsi": "_r_create_ldsi",
	"iregion.createtrafficcontrol": "_r_create_traffic",
	"iregion.destroy": "_r_destroy",

	"ibody.cast": "_b_cast", "ibody.nearest": "_b_nearest",
	"ibody.habitatsaroundbody": "_b_habitats_around",
	"ibody.type": "_b_type_filter",
	"ibody.filterontype": "_b_type_filter",

	"subsim.create": "_ss_create", "subsim.place": "_ss_place",
	"subsim.orientateeuler": "_ss_orientate",
	"subsim.destroy": "_ss_destroy", "subsim.cast": "_ss_cast",
}
