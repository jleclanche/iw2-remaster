class_name DeathSequence
extends Node3D
# iiSim's ship-destruction system, extracted from iwar2.dll:
#
#   OnExplode (0x10079db0): the SIZE BRANCH. A dying sim whose size (+0x20,
#   half the bounding diagonal -- CalculateRadius 0x1007ccf0 returns
#   sqrt((w^2+h^2+l^2) * 0.25)) is under m_min_radius_for_dramatic_explosion
#   (25.0 @ 0x1011befc) spawns ONE inert explosion sim scaled to its size and
#   is gone. At or above it, the sim enters the DRAMATIC sequence: explosion
#   timer = size * m_explosion_length_scale (1/30 @ 0x1011bf00) capped at
#   30 s (0x10119c18), plus a random tumble -- SetAngularVelocity of
#   per-axis rand[-1,1] mixed with the sim's velocity * 0.001 (0x1011803c;
#   the exact per-axis component mixing is smeared over reused stack slots
#   in the disasm -- each axis here gets rand[-1,1] * |v| * 0.001).
#
#   Simulate (0x100792b0): while the timer runs down, sub-explosions crawl
#   over the hull -- every rand-lerp(0.2, 0.8) s (0x1011bf04/0x1011bf08) an
#   explosion of size * rand-lerp(0.01, 0.12) (0x1011bf0c/0x1011bf10) at a
#   random surface point (FindSurfacePoint; approximated here as a random
#   point on the half-dimension ellipsoid -- the original raycasts the
#   model). The original also occasionally DetachAndFlingChild()s a subsim;
#   our AI hulls have no detachable children, so that branch has no work.
#
#   DoFinalExplosion (0x1007c990), when the timer crosses 0 (0x10117178):
#   FOUR debris puffs, each of radius R * rand-lerp(0.3, 0.6)
#   (0x1011c034/0x101192c4) where R is the sim RADIUS (+0x1c, the ini
#   radius= key), positioned at a random unit vector * R * 0.4 (0x10117558)
#   rotated into the sim's frame, each inheriting the sim's VELOCITY; plus,
#   unless ini no_shockwave, one ini:/sims/explosions/reactor_explosion --
#   its final_radius (+0x1e0) forced to R * 4.0 (0x101190b4) and its
#   initial_damage_rate (+0x1d8 -- the icShockwave property map @
#   FUN_10077290 binds initial_damage_rate=0x1d8, front_depth=0x1dc,
#   final_radius=0x1e0, lifetime=0x1e4) multiplied by
#   clamp(R / mean_radius_of_reactor_explosion_sim (200.0 @ 0x1015d964),
#   0.25 (0x101191ec), 4.0). Big ships blast harder, not just bigger.
#
# The small-ship path is why a fighter pops in one flash while a freighter
# burns and crackles for seconds before the reactor goes -- the system the
# fixed-size boom() we shipped before never reproduced.
#
# reactor_explosion.ini (extracted, data/ini/sims/explosions/): "Template
# for a 1m radius normal detonation used by exploding ships. It is scaled
# according to the ship's size." -- final_radius=1.0, lifetime=2.0,
# front_depth=0.1 (front thickness as a fraction of radius),
# initial_damage_rate=2000 (damage/sec at t=0). The damage DECAY shape over
# the lifetime is not in the ini or the decompiled avatar -- main's sweep
# fades it linearly (eyeballed, marked there).

const DRAMATIC_MIN_SIZE := 25.0       # m_min_radius_for_dramatic_explosion
const EXPLOSION_LENGTH_SCALE := 1.0 / 30.0  # m_explosion_length_scale
const EXPLOSION_TIME_CAP := 30.0      # 0x10119c18 / the 30.0 store
const SUB_TIME_MIN := 0.2             # m_min_time_before_subexplosion
const SUB_TIME_MAX := 0.8             # m_max_time_before_subexplosion
const SUB_SCALE_MIN := 0.01           # m_min_subexplosion_scale
const SUB_SCALE_MAX := 0.12           # m_max_subexplosion_scale
const TUMBLE_VEL_SCALE := 0.001       # 0x1011803c
const PUFFS := 4                      # DoFinalExplosion loop count
const PUFF_RADIUS_MIN := 0.3          # 0x1011c034
const PUFF_RADIUS_MAX := 0.6          # 0x101192c4
const PUFF_SCATTER := 0.4             # 0x10117558
const SHOCKWAVE_RADIUS_MULT := 4.0    # 0x101190b4
const SHOCKWAVE_MEAN_RADIUS := 200.0  # m_mean_radius_of_reactor_explosion_sim
const SHOCKWAVE_SCALE_MIN := 0.25     # 0x101191ec
const SHOCKWAVE_SCALE_MAX := 4.0      # clamp reuses 0x101190b4
const SMALL_EXPLOSION_THRESHOLD := 150.0  # 0x1011a81c (explosion_fx.gd)
# reactor_explosion.ini [Properties]
const SHOCKWAVE_LIFETIME := 2.0
const SHOCKWAVE_FRONT_DEPTH := 0.1
const SHOCKWAVE_DAMAGE_RATE := 2000.0

var main: Node3D
var host: Node3D                  # the dying sim's node; we ride as its child
var vel := Vector3.ZERO           # world velocity the effects inherit
var size := 10.0                  # iiSim +0x20 (FUN_10064500 default 10.0)
var radius := 10.0                # iiSim +0x1c
var half_dims := Vector3.ONE * 10.0  # surface-point ellipsoid
var on_finish := Callable()       # removes the wreck (main/fields owns that)
## The final blast's +0x19f suppression: a sim carrying the "no_shockwave"
## script property is curtained (isim.StopExplosion) without the wave.
var shockwave := true

var _timer := 0.0
var _sub_at := 0.0

# The OnExplode entry point. Returns true when the sim is finished at once
# (the small-ship path) -- mirroring the original's bool return.
static func explode(p_main: Node3D, p_host: Node3D, p_size: float,
		p_radius: float, p_half_dims: Vector3, p_vel: Vector3,
		p_on_finish: Callable) -> bool:
	if p_size < DRAMATIC_MIN_SIZE:
		# one inert explosion sim, scaled to the sim size, riding its velocity
		_puff(p_main, p_host.global_position, p_size, p_vel)
		if p_on_finish.is_valid():
			p_on_finish.call()
		return true
	var seq := DeathSequence.new()
	seq.main = p_main
	seq.host = p_host
	seq.vel = p_vel
	seq.size = p_size
	seq.radius = p_radius
	seq.half_dims = p_half_dims
	seq.on_finish = p_on_finish
	seq._timer = minf(p_size * EXPLOSION_LENGTH_SCALE, EXPLOSION_TIME_CAP)
	seq._sub_at = randf_range(SUB_TIME_MIN, SUB_TIME_MAX)
	p_host.add_child(seq)
	return false

# The dramatic path's tumble (OnExplode tail, 0x10079e67..0x10079f33).
static func tumble(v: Vector3) -> Vector3:
	var s := v.length() * TUMBLE_VEL_SCALE
	return Vector3(randf_range(-1.0, 1.0), randf_range(-1.0, 1.0),
			randf_range(-1.0, 1.0)) * s

func _physics_process(delta: float) -> void:
	if host == null or not is_instance_valid(host):
		queue_free()
		return
	_timer -= delta
	_sub_at -= delta
	if _timer <= 0.0:
		DeathSequence.final_explosion(main, host.global_transform.basis,
				host.global_position, radius, vel, shockwave)
		var done := on_finish
		on_finish = Callable()
		set_physics_process(false)
		if done.is_valid():
			done.call()   # frees or pools the host
		# a pooled host (field rocks) survives -- never leave the sequence
		# hanging off it; if the host was freed this is a same-frame no-op
		queue_free()
		return
	if _sub_at <= 0.0:
		_sub_at = randf_range(SUB_TIME_MIN, SUB_TIME_MAX)
		var scale := size * randf_range(SUB_SCALE_MIN, SUB_SCALE_MAX)
		# FindSurfacePoint stand-in: random point on the half-dims ellipsoid
		var p := ExplosionFx._unit_vector() * half_dims
		DeathSequence._puff(main,
				host.global_position + host.global_transform.basis * p,
				scale, vel)

# One inert explosion sim (FUN_10064500): the effect keyed off its own
# radius against the 150 m threshold, drifting with the given velocity.
static func _puff(p_main: Node3D, pos: Vector3, p_size: float,
		p_vel: Vector3) -> void:
	var key := "explosion" if p_size >= SMALL_EXPLOSION_THRESHOLD \
			else "small_explosion"
	var fx := ExplosionFx.play(p_main, key,
			Transform3D(Basis.IDENTITY, pos), p_size)
	if fx != null:
		fx.drift = p_vel

# DoFinalExplosion (0x1007c990). `shockwave` is the +0x19f flag: a sim
# carrying the "no_shockwave" script property (a1m07 stages this before
# isim.StopExplosion) gets the four scatter puffs but no reactor_explosion.
static func final_explosion(p_main: Node3D, basis: Basis, pos: Vector3,
		p_radius: float, p_vel: Vector3, shockwave := true) -> void:
	for i in PUFFS:
		var pr := p_radius * randf_range(PUFF_RADIUS_MIN, PUFF_RADIUS_MAX)
		var scatter: Vector3 = basis \
				* (ExplosionFx._unit_vector() * p_radius * PUFF_SCATTER)
		DeathSequence._puff(p_main, pos + scatter, pr, p_vel)
	if not shockwave:
		return
	# the effect's authored envelope is unit-radius (scale_keys 0 -> 1 over
	# the lifetime): _size IS the expansion front's final radius
	var final_r := p_radius * SHOCKWAVE_RADIUS_MULT
	var fx := ExplosionFx.play(p_main, "reactor_explosion",
			Transform3D(Basis.IDENTITY, pos), final_r)
	if fx != null:
		fx.drift = p_vel
	var rate := SHOCKWAVE_DAMAGE_RATE * clampf(p_radius / SHOCKWAVE_MEAN_RADIUS,
			SHOCKWAVE_SCALE_MIN, SHOCKWAVE_SCALE_MAX)
	if p_main.has_method("register_shockwave"):
		p_main.register_shockwave(pos, p_vel, final_r, rate)
