class_name Fields
extends Node3D
# @element iiSimField
# @element icAsteroidField
# @element icDebrisField
# @element icAsteroidBelt
# @element icFieldSphere
# @element icFieldSim
# @element icAsteroidAvatar
#
# The ambient asteroid / debris fields, recovered from iwar2.dll. See
# docs/fields.md for the full evidence log; addresses inline below.
#
# The original's shape: TWO field singletons exist for the whole game -- one
# icAsteroidField, one icDebrisField, both iiSimField -- created at world load
# ("Loading asteroids" / "Loading debris", icSolarSystem setup @ 0x100846xx,
# decomp line ~148601). Nothing in the map places rocks. Instead, geography
# carries *zones* that turn the singletons on around the player:
#
#   icAsteroidBelt (map kind 4)  -- an annulus around its parent body; while
#       the player is inside it, the ASTEROID singleton is active
#       (Think @ 0x10064cf0 -> activate @ 0x10049890).
#   icFieldSphere (ini:/sims/regions/asteroid|asteroid25k|debris, created by
#       the mission scripts) -- a sphere with contains_asteroids /
#       contains_debris flags (+0x1e0/+0x1e1, map @ 0x100664e0), each flag
#       activating its singleton (Think @ 0x100667b0).
#
# An active field keeps a fixed pool of `count` icFieldSim rocks teleporting
# around the player (iiSimField::Think @ 0x10049570): rocks farther than
# 1.1 x (100 x rock_radius) from the camera go back to the pool, and pooled
# rocks respawn on a shell 100 x their own radius out. Live + pooled = count,
# ALWAYS -- that is the engine's whole streaming/LOD story for belts, and it
# is why a "belt" of 3.7e11 m radius never draws more than 100 rocks.

var main: Node3D

# --- recovered constants -----------------------------------------------------

# Spawn distance per metre of rock radius: FUN_100649b0 @ 0x100649b0 returns
# FiSim::Radius() * _DAT_10119fa0, and _DAT_10119fa0 = 100.0.
const SPAWN_PER_RADIUS := 100.0
# Cull hysteresis: iiSimField::Think @ 0x10049570 culls at spawn distance
# * _DAT_10119e94 = 1.1 (cube test per axis, then the sphere test).
const CULL_FACTOR := 1.1
# Stationary spawn: distance uniform in [0.1, 1.0] x spawn distance
# (FUN_1004a030 @ 0x1004a030, _DAT_101184b0 = 0.1).
const NEAR_FRACTION := 0.1
# Moving spawn: rocks spawn on a cone about the direction of travel whose
# half-angle ramps from PI (v <= 1 m/s) down to 0.4 rad at v >= 500 m/s
# (FUN_1004a430 @ 0x1004a430: t = clamp((v-1) * 0.00200401, 0, 1);
# angle = t*0.4 + (1-t)*PI. 0.4 = _DAT_10117558, PI = _DAT_10119464,
# 0.00200401 = _DAT_10119fc8 = 1/499, 500 = _DAT_10119fcc).
const CONE_MIN := 0.4
const CONE_RAMP := 1.0 / 499.0
# Field flush: the iiSimField init (dropped by Ghidra, raw disasm @ 0x10049400)
# ends with `this+0x64 = _DAT_10119fa0 * max_radius`; Think (0x10049570)
# squares that against the PER-FRAME focus displacement |FcWorld+0x50..0x58|
# (the same delta it divides by dt just below to get the cone speed) -- a
# DISPLACEMENT, not a velocity. The field only dumps when the player crosses
# the whole spawn shell in one tick: asteroids 40 km/frame, debris 20 km/frame.
# (What Think does next is spawn them all again through the speed-0 path --
# the field re-teleports around you, it does not switch off. But it teleports
# around the LAST tick's focus: icClient::Tick @ 0x100b39c0 runs the field
# Thinks BEFORE FcClient::Tick integrates the world, so at shell-per-frame
# speeds the respawned rocks are already a full frame's travel astern at
# render time and strand off the 1.1x cull unseen. That emergent stranding --
# not an LDS gate, none exists: there is no icLDSDrive/field coupling
# anywhere, and the zone Thinks @ 0x100667b0 / 0x10064cf0 test position only
# -- is why the original shows no field rocks during LDS cruise.)
#
# Rock collision cutoff: icFieldSim::CanCollide override @ 0x100648d0 refuses
# any collision when the other sim's speed (alpha-max-beta-min approximation,
# max + 0.34375*mid + 0.25*min: _DAT_101191f0/_DAT_101191ec) exceeds
# _DAT_1011a18c = 10000 m/s -- an LDS-speed ship passes straight through.
const COLLIDE_SPEED_MAX := 10000.0
# Rock spin (FUN_10049d70 @ 0x10049d70): size_frac = clamp((r - min_radius) /
# (max_radius - min_radius), 0, 1); k = (1 - size_frac) * (rand*0.9 + 0.1)
# (_DAT_1011951c = 0.9, _DAT_101184b0 = 0.1); rate = (k*max_rot +
# (1-k)*min_rot) degrees/s (_DAT_10119930 = 0.0174533 deg->rad). Big rocks
# tumble slowly. Axis random; orientation random; speed uniform
# [min_speed, max_speed] on a random direction (skipped when max_speed <= 0).

# --- the two singleton field specs -------------------------------------------

# icAsteroidField ctor (FUN_1003f8c0 @ 0x1003f8c0) reads ini:/fields/asteroid
# [Properties]; icDebrisField (FUN_10046c00 @ 0x10046c00) reads
# ini:/fields/debris. Property map FUN_10049020 @ 0x10049020:
# sim_templates[] +0x14, count +0x20 (int), particle_field +0x24,
# min/max_radius +0x28/+0x2c, min/max_rotation_rate +0x30/+0x34,
# min/max_speed +0x38/+0x3c, max_clump_size +0x40 (read by no recovered code).
# Values below are data/ini/fields/asteroid.ini and debris.ini verbatim.
# hit_points comes from the rock templates (data/ini/sims/inert/*.ini).
const ASTEROID_SPEC := {
	"name": "asteroid",
	"templates": [
		"avatars/asteroids/setup1.gltf", "avatars/asteroids/setup2.gltf",
		"avatars/asteroids/setup3.gltf", "avatars/asteroids/setup4.gltf"],
	"count": 100,
	"min_radius": 50.0, "max_radius": 400.0,
	"min_rot": 5.0, "max_rot": 60.0,
	"min_speed": 2.0, "max_speed": 75.0,
	"hit_points": 5000.0,
	"particle_field": "kibble",           # ini:/sfx/kibble/node
}
const DEBRIS_SPEC := {
	"name": "debris",
	"templates": [
		"avatars/debris/d1_setup.gltf", "avatars/debris/d2_setup.gltf",
		"avatars/debris/d3_setup.gltf", "avatars/debris/d4_setup.gltf",
		"avatars/debris/d5_setup.gltf"],
	"count": 50,
	"min_radius": 50.0, "max_radius": 200.0,
	"min_rot": 0.0, "max_rot": 20.0,
	"min_speed": 0.0, "max_speed": 0.0,
	"hit_points": 5000.0,
	"particle_field": "cornflake_field",  # ini:/sfx/cornflake_field/node
}

# One iiSimField singleton. Rocks are dictionaries:
#   {node, radius, ax/ay/az (absolute, doubles), vel, axis, rate, hp}
# Rock positions are ABSOLUTE and re-folded against px/py/pz every tick,
# exactly because the original's rocks are world-fixed sims culled against a
# moving camera -- a script teleporting the player must strand and cull them.
class Field extends RefCounted:
	var spec: Dictionary
	var live: Array = []
	var pool: Array = []
	var built := false          # pool is created on first activation
	var active := false         # activation refcount as a per-frame bool
	var tpl_radius: Dictionary = {}   # template path -> bounds radius
	var dust: ParticleFx = null       # the attached particle_field node
	func _init(s: Dictionary) -> void:
		spec = s

var asteroid := Field.new(ASTEROID_SPEC)
var debris := Field.new(DEBRIS_SPEC)

# icAsteroidBelt zones, rebuilt per system by main._load_system:
#   {cx, cy, cz (parent body position, doubles), r (ring radius, record
#    +0x134), w (width, record +0x138), basis}
# ParseAsteroidBeltInfo @ 0x1004e6b0: FiSim::SetRadius(record +0x134),
# width <- record +0x138, centre <- the PARENT geography's position.
# In all 21 shipped belt records width == radius, so the "annulus" test
# degenerates to a disc of radius 2R and half-thickness R about the parent.
var belts: Array = []


func _ready() -> void:
	name = "Fields"


# main._load_system, per kind-4 record.
func add_belt(ring_r: float, width: float, cx: float, cy: float, cz: float,
		basis: Basis) -> void:
	belts.append({"r": ring_r, "w": width, "cx": cx, "cy": cy, "cz": cz,
		"basis": basis})


# main._clear_system. The singletons persist across systems (they are created
# once at game load in the original); only the live set and the zones go.
func clear_system() -> void:
	belts.clear()
	_flush(asteroid)
	_flush(debris)
	asteroid.active = false
	debris.active = false
	_show_dust(asteroid, false)
	_show_dust(debris, false)


## The world fold is post-integration (main.late_physics, #51), and this tick
## placed the rock nodes against the PRE-fold focus -- so they must ride the
## rebase or they render one tick's travel off. At LDS shell-per-frame speeds
## that painted the whole per-tick respawned field around the ship for one
## frame each tick (the asteroid strobing regression; mechcheck
## belt-lds-astern). The absolute ax/ay/az are untouched: next tick's cull
## loop re-folds from them regardless.
func shift_world(offset: Vector3) -> void:
	for f: Field in [asteroid, debris]:
		for rk in f.live:
			(rk["node"] as Node3D).position -= offset


# --- zone tests --------------------------------------------------------------

# icAsteroidBelt::Think's inside test, FUN_10064d50 @ 0x10064d50:
# out-of-plane |d . Y| < width, then (R-w)^2 <= in-plane^2 <= (R+w)^2.
func _in_belt(b: Dictionary, p_x: float, p_y: float, p_z: float) -> bool:
	var dx := p_x - float(b["cx"])
	var dy := p_y - float(b["cy"])
	var dz := p_z - float(b["cz"])
	var bas: Basis = b["basis"]
	var d := Vector3(dx, dy, dz)  # f32 is fine: the test tolerances are >> 1e5
	var w: float = b["w"]
	var r: float = b["r"]
	if absf(d.dot(bas.y)) >= w:
		return false
	var in_plane := d.dot(bas.x) * d.dot(bas.x) + d.dot(bas.z) * d.dot(bas.z)
	var inner := maxf(r - w, 0.0)
	var outer := r + w
	return in_plane >= inner * inner and in_plane <= outer * outer


# --- per-frame ---------------------------------------------------------------

func tick(delta: float) -> void:
	if main == null or main.ship == null:
		return
	# icAsteroidBelt::Think (0x10064cf0) drives ONLY the asteroid singleton;
	# icFieldSphere::Think (0x100667b0) drives either per its contains flags.
	var ast_on := false
	var deb_on := false
	for b in belts:
		if _in_belt(b, main.px, main.py, main.pz):
			ast_on = true
			break
	for o in main.objects:
		if str(o.get("category", "")) != "field_sphere":
			continue
		# FUN_10066840 @ 0x10066840: cube-per-axis then sphere on FiSim radius
		var dx: float = float(o["x"]) - main.px
		var dy: float = float(o["y"]) - main.py
		var dz: float = float(o["z"]) - main.pz
		var r: float = float(o.get("radius", 0.0))
		if dx * dx + dy * dy + dz * dz < r * r:
			ast_on = ast_on or bool(o.get("field_asteroids", false))
			deb_on = deb_on or bool(o.get("field_debris", false))
	var vel: Vector3 = main.ship.velocity
	_field_tick(asteroid, ast_on, vel, delta)
	_field_tick(debris, deb_on, vel, delta)


# iiSimField::Think @ 0x10049570, one field.
func _field_tick(f: Field, on: bool, vel: Vector3, delta: float) -> void:
	if on != f.active:
		# activation refcount edge (FUN_10049890 / FUN_100498c0): the original
		# adds/removes the particle-field node from the solar system here
		# (icSolarSystem::AddParticleField @ 0x1004e7c0).
		f.active = on
		if on and not f.built:
			_build_pool(f)
		_show_dust(f, on)
	# 1. advance + cull. The cull loop runs whether or not the field is active
	# (Think's first loop is unconditional): leaving a belt does not pop the
	# rocks, they strand and fall off the 1.1x shell as you fly away.
	var i := f.live.size() - 1
	while i >= 0:
		var rk: Dictionary = f.live[i]
		rk["ax"] = float(rk["ax"]) + (rk["vel"] as Vector3).x * delta
		rk["ay"] = float(rk["ay"]) + (rk["vel"] as Vector3).y * delta
		rk["az"] = float(rk["az"]) + (rk["vel"] as Vector3).z * delta
		var off := Vector3(float(rk["ax"]) - main.px, float(rk["ay"]) - main.py,
			float(rk["az"]) - main.pz)
		var cull: float = CULL_FACTOR * SPAWN_PER_RADIUS * float(rk["radius"])
		if absf(off.x) > cull or absf(off.y) > cull or absf(off.z) > cull \
				or off.length_squared() > cull * cull:
			_recycle(f, i)
		else:
			var node: Node3D = rk["node"]
			node.position = off
			node.rotate(rk["axis"], float(rk["rate"]) * delta)
		i -= 1
	if not f.active:
		return
	# 2. flush when the focus crossed the whole spawn shell in ONE tick
	# (0x10049570 squares this+0x64 = 100 x max_radius against the per-frame
	# focus displacement FcWorld+0x50, NOT against a velocity -- comparing the
	# speed here was the LDS asteroid-swarm bug); the spawn-at-speed-0 path
	# then re-teleports the field
	var speed := vel.length()
	if speed * delta > SPAWN_PER_RADIUS * float(f.spec["max_radius"]):
		while not f.live.is_empty():
			_recycle(f, f.live.size() - 1)
		speed = 0.0
	# 3. spawn from the pool (Think passes `count` as the per-frame budget, so
	# an empty field fills completely in one tick). This tick runs where the
	# original's Think does -- BEFORE the world integrates and folds
	# (icClient::Tick @ 0x100b39c0 runs the Thinks before FcClient::Tick), so
	# px/py/pz here IS the pre-integration focus (world+0x38). At
	# shell-per-frame speeds the post-integration fold then strands the
	# respawned shell a full frame's travel astern of the camera, which is
	# exactly how the original shows nothing during LDS cruise.
	var budget: int = int(f.spec["count"])
	while budget > 0 and not f.pool.is_empty():
		_spawn(f, vel, speed)
		budget -= 1
	# the dust ticks itself: it is a scene node hanging off the solar system
	# (AddParticleField), not something the field drives
	_collide(f, speed)
	_bolts(f, delta)


# --- pool / spawn ------------------------------------------------------------

# The iiSimField init (raw disasm @ 0x10049400, called through vtable slot
# +0x18 after ReadProperties): resolve the particle_field node, then create
# `count` sims via FUN_10049c30 @ 0x10049c30 -- each a UNIFORM random pick of
# sim_templates[], class-checked against icFieldSim -- and push them all into
# the pool. We defer it to first activation so booting into a clear system
# never touches the rock glTFs.
func _build_pool(f: Field) -> void:
	f.built = true
	for i in int(f.spec["count"]):
		var tpls: Array = f.spec["templates"]
		var path := str(tpls[randi() % tpls.size()])
		var node: Node3D = main._load_gltf("data/avatars/" + path)
		if node == null:
			continue
		add_child(node)
		node.visible = false
		# FiSim radius comes from the avatar, same as every other sim we
		# stream (see main._stream_objects on stations). The [Properties]
		# width/height/length in the template inis match the LOD0 bounds.
		if not f.tpl_radius.has(path):
			f.tpl_radius[path] = main._model_bounds_radius(node)
		f.pool.append({"node": node, "radius": float(f.tpl_radius[path]),
			"ax": 0.0, "ay": 0.0, "az": 0.0, "vel": Vector3.ZERO,
			"axis": Vector3.UP, "rate": 0.0, "hp": float(f.spec["hit_points"]),
			"tpl": path})


# FUN_1004a030 @ 0x1004a030 (place) + FUN_10049d70 @ 0x10049d70 (kinematics).
# px/py/pz is the pre-integration focus here -- see _field_tick step 3.
func _spawn(f: Field, vel: Vector3, speed: float) -> void:
	var rk: Dictionary = f.pool.pop_back()
	var spawn_r: float = SPAWN_PER_RADIUS * float(rk["radius"])
	var dir: Vector3
	var dist := spawn_r
	if speed < 1.0e-6:
		dir = _unit_vector()
		dist = spawn_r * randf_range(NEAR_FRACTION, 1.0)
	else:
		# half-angle PI..0.4 rad over 1..500 m/s, opening ASTERN -- resolved
		# (the old AHEAD reading was wrong): FnRandom::ConeVector (flux @
		# 0x10048200) rotates +Z by its sampled quaternion, and FUN_1004a030
		# builds its basis from d = -direction (`local_74 = -*param_2`) with
		# the cone's z mapped onto d (`... + local_60 * local_50`), so the
		# cone's mean IS the negated travel direction. Moving respawns land
		# BEHIND the traveller at the full shell radius: the field thins out
		# ahead at speed and only refills around you once the cone widens
		# back to the sphere below ~1 m/s. Rocks never pop in in front.
		var t := clampf((speed - 1.0) * CONE_RAMP, 0.0, 1.0)
		dir = _cone_vector(-(vel / speed), t * CONE_MIN + (1.0 - t) * PI)
	rk["ax"] = main.px + dir.x * dist
	rk["ay"] = main.py + dir.y * dist
	rk["az"] = main.pz + dir.z * dist
	# rock kinematics: random orientation; spin scaled down for big rocks
	var size_span: float = float(f.spec["max_radius"]) - float(f.spec["min_radius"])
	var size_frac := 0.0
	if size_span > 0.0:
		size_frac = clampf((float(rk["radius"]) - float(f.spec["min_radius"]))
			/ size_span, 0.0, 1.0)
	var k := (1.0 - size_frac) * (randf() * 0.9 + 0.1)
	rk["rate"] = deg_to_rad(k * float(f.spec["max_rot"])
		+ (1.0 - k) * float(f.spec["min_rot"]))
	rk["axis"] = _unit_vector()
	rk["vel"] = Vector3.ZERO
	if float(f.spec["max_speed"]) > 0.0:
		rk["vel"] = _unit_vector() * randf_range(float(f.spec["min_speed"]),
			float(f.spec["max_speed"]))
	rk["hp"] = float(f.spec["hit_points"])
	var node: Node3D = rk["node"]
	node.basis = Basis(Quaternion(_unit_vector(), randf() * TAU))
	node.position = dir * dist
	node.visible = true
	f.live.append(rk)


func _recycle(f: Field, idx: int) -> void:
	var rk: Dictionary = f.live[idx]
	var node := rk["node"] as Node3D
	node.visible = false
	rk["dying"] = false
	# a world flush can pool a rock mid-death -- the pooled node must not
	# keep a live DeathSequence crackling on it
	for c in node.get_children():
		if c is DeathSequence:
			c.queue_free()
	f.live.remove_at(idx)
	f.pool.append(rk)


# iiSim::OnExplode (death_sequence.gd): field rocks run the STANDARD
# size-branch death -- icFieldSim overrides only Destroy (0x100648b0), which
# returns the sim to the field's pool (FUN_100498f0) instead of destroying
# it. A big rock therefore burns and crackles like a hulk before the final
# blast. Our rocks are random uniform scales of 4 templates, so the spawn
# radius doubles as the iiSim size (+0x20) stand-in; the surface-point
# ellipsoid uses the same 0.66 lumpy-rock factor as the collision sphere.
func _kill_rock(f: Field, rk: Dictionary) -> void:
	rk["dying"] = true
	var node := rk["node"] as Node3D
	var r := float(rk["radius"])
	var finish := func() -> void:
		var i := f.live.find(rk)
		if i >= 0:
			_recycle(f, i)
	DeathSequence.explode(main, node, r, r, Vector3.ONE * r * 0.66,
			rk["vel"] as Vector3, finish)


func _flush(f: Field) -> void:
	# FUN_10049a60 @ 0x10049a60: world change returns every live sim to the pool
	while not f.live.is_empty():
		_recycle(f, f.live.size() - 1)


# --- collision / damage ------------------------------------------------------

# Rocks are icFieldSim = icInertSim with a collision hull and a damage model
# (hit_points 5000, armour 0, threat 0 -- data/ini/sims/inert/*.ini). They
# push the ship around and they soak PBC fire; a killed rock goes back to the
# field pool (icFieldSim override @ 0x100648b0 calls the field's RemoveSim,
# FUN_100498f0, which pools it) and respawns elsewhere.
func _collide(f: Field, speed: float) -> void:
	if main.docked_at != "" or main.jump_state >= 2 \
			or not main.player_collision:
		return  # same guard as main._collisions, sim.SetCollision included:
		# the undock movie plays with the ship still parked inside the base
		# and docked_at already cleared (istartsystem.pog:72..86)
	if speed > COLLIDE_SPEED_MAX:
		return  # icFieldSim::CanCollide @ 0x100648d0
	for rk in f.live:
		var node: Node3D = rk["node"]
		var r: float = float(rk["radius"])
		if node.position.length_squared() > (r + 400.0) * (r + 400.0):
			continue
		# sphere at 0.66 x bounds like main._model_radius: the AABB radius
		# overshoots a lumpy rock on two axes
		main._collide_sphere(node.position, r * 0.66 + 45.0,
			rk["vel"], "asteroid" if f == asteroid else "debris")


func _bolts(f: Field, delta: float) -> void:
	if main.weapons == null or f.live.is_empty():
		return
	for bolt in main.weapons.bolts:
		if float(bolt["life"]) <= 0.0:
			continue
		var node = bolt["node"]
		if not (node is Node3D) or not is_instance_valid(node):
			continue
		var to: Vector3 = (node as Node3D).global_position
		var from: Vector3 = to - (bolt["vel"] as Vector3) * delta
		for i in f.live.size():
			var rk: Dictionary = f.live[i]
			var c: Vector3 = (rk["node"] as Node3D).position
			var r: float = float(rk["radius"]) * 0.66
			if not _segment_hits(from, to, c, r):
				continue
			# icBullet vs a rock plays the dedicated asteroid_impact effect
			# (sfx_effects.json: "icBullet hitting ... (rock)")
			var at := from + (to - from) * 0.5
			var out := (at - c).normalized()
			ExplosionFx.play(main, "asteroid_impact",
				Transform3D(Basis.looking_at(-out), at), 1.0)
			# bare-hull damage, armour 0, with the bolt's age falloff
			var spec: Dictionary = bolt.get("spec", {})
			var dmg: float = float(spec.get("damage", 160.0)) \
				/ ShipSystems.age_factor(float(bolt.get("age", 0.0)),
					float(spec.get("half_time", 0.35)))
			if rk.get("dying", false):
				bolt["life"] = 0.0
				break
			rk["hp"] = float(rk["hp"]) - dmg
			bolt["life"] = 0.0
			if float(rk["hp"]) <= 0.0:
				_kill_rock(f, rk)
			break


func _segment_hits(a: Vector3, b: Vector3, c: Vector3, r: float) -> bool:
	var ab := b - a
	var t := 0.0
	var len2 := ab.length_squared()
	if len2 > 0.0:
		t = clampf((c - a).dot(ab) / len2, 0.0, 1.0)
	return (a + ab * t).distance_squared_to(c) < r * r


# --- the particle field (kibble / cornflake dust) -----------------------------

# While a field is active the original hangs its particle_field scene node off
# the solar system (icSolarSystem::AddParticleField @ 0x1004e7c0 /
# RemoveParticleField @ 0x1004e8b0): ini:/sfx/kibble/node for asteroids,
# ini:/sfx/cornflake_field/node for debris. Attaching and detaching that node is
# ALL this file does -- the dust itself is icTeleportDynamics, and it lives in
# particle_fx.gd (Spawn @ 0x100c8c80, Update @ 0x100c91f0).
#
# The two things worth repeating here, because they were the two bugs:
#   * the motes are WORLD-FIXED. Update adds FcWorld::GraphicsDeltaFocus to
#     every mote every frame, which holds it still in the world while the shell
#     re-centres on the viewpoint. They are not attached to the camera and they
#     stream past you as you fly. (Our old 40 m camera-locked wrap box was a
#     reconstruction, and it was wrong on both counts.)
#   * they are culled inside 5 m of the viewpoint (0x1011cf68), which is what
#     keeps them out of the cockpit. There is no separate near pass: the
#     original just kills any mote you get that close to.
#
# The 40.0 that icDebrisField's ctor pokes into the node (0x10046c00) is a
# SetScale, not an emitter box -- FiSceneNode::SetScale writes exactly
# +0x5c/+0x60/+0x64 (flux @ 0x1004dd80). icCornflakeDraw reads that scale back
# off the emitter and multiplies it by 0.075 (0x100bc6cd..0x100bc6df), so the
# debris field's cornflakes are 3 m hull plates. icAsteroidField's ctor
# (0x1003f8c0) pokes nothing, so the kibble node keeps scale 1 and its chunk
# models draw at their authored 0.4.
const DEBRIS_NODE_SCALE := 40.0

func _show_dust(f: Field, on: bool) -> void:
	var have: bool = f.dust != null and is_instance_valid(f.dust)
	if on == have:
		return
	if not on:
		if have:
			f.dust.queue_free()
		f.dust = null
		return
	f.dust = ParticleFx.spawn(self, main._base(), str(f.spec["particle_field"]),
		Transform3D.IDENTITY, DEBRIS_NODE_SCALE if f == debris else 1.0)


# --- randoms -----------------------------------------------------------------

static func _unit_vector() -> Vector3:
	# FnRandom::UnitVector
	var v := Vector3(randfn(0.0, 1.0), randfn(0.0, 1.0), randfn(0.0, 1.0))
	return v.normalized() if v.length() > 1.0e-4 else Vector3.UP


static func _cone_vector(axis: Vector3, half_angle: float) -> Vector3:
	# FnRandom::ConeVector (flux @ 0x10048200): two uniform rolls in
	# [-a, a] halved into a quaternion, returning a vector within the cone.
	# Uniform-solid-angle within the cap is close enough to that here.
	var cos_a := cos(clampf(half_angle, 0.0, PI))
	var z := randf_range(cos_a, 1.0)
	var phi := randf() * TAU
	var s := sqrt(maxf(1.0 - z * z, 0.0))
	var local := Vector3(s * cos(phi), s * sin(phi), z)
	# build a basis with +Z on the axis
	var up := Vector3.UP if absf(axis.y) < 0.99 else Vector3.RIGHT
	var x := up.cross(axis).normalized()
	var y := axis.cross(x)
	return x * local.x + y * local.y + axis * local.z
