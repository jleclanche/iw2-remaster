class_name AlienShip
extends AiShip
# @element icAlienSwarm
# @element icAlienSwarmAvatar
# Act 3's aliens. icAlienSwarm (iwar2.dll, registered @ 0x1002c080 with
# icShip's property map -- it adds NO properties of its own) is an icShip
# whose ctor (0x1002c0f0) clears a was-hit flag at +0x300 and raises sim flag
# 0x80000. Everything alien-specific is four overrides, transcribed here:
#
#   ApplyWeaponDamage @ 0x1002c2c0 -- flinch away from every hit; only
#       antimatter-based weapons do damage (attacker vtable +0xdc =
#       iiSim::IsAntimatterBasedWeapon @ 0x10001520, the projectile INI's
#       antimatter_based key).
#   UpdateAvatar      @ 0x1002c1f0 -- avatar scale = ship radius; a random
#       pain1/pain2/pain3 channel fires 1.0 the frame after a hit
#       (rand() % 6 >> 1, names built @ 0x1002bf60: "pain1"/"pain2"/"pain3"
#       @ 0x1015b018/20/28); channel "damage" (@ 0x1015b030) = 1 - hp/max_hp.
#   OnExplode         @ 0x1002c4b0 -- the death is a single
#       ini:/sims/explosions/alien_explosion shockwave at radius x 4.0
#       (0x101190b4), copying the swarm's position and velocity, REPLACING
#       the standard four-puff death (OnExplode returns true).
#   OnPropertiesChanged @ 0x1002c1c0 -- width/height/length = 2 x radius.
#
# The swarm has NO weapons (sims/ships/aliens/alien.ini fits no subsims): the
# aliens kill through the mission scripts' isim.SetAlienInfectionDamage when
# they close inside 700 m (iactthree.gd), so _attack pursues but never fires.
#
# The avatar (avatars/aliens/setup_red.lws) is an icAlienSwarmAvatar particle
# node (factory @ 0x100b9640: a stock FcParticleEmitterNode, +0x24=30,
# +0xb0=1.0, no extra properties) running sfx/alienswarm through the
# cornflake draw, five animated icBeamAvatar tentacles, pain/damage flare
# lights, and alien_loop / alien_pain* sound nodes keyed on the same
# channels (audio/sfx/alien_pain*.ini: play_channel=pain1/2/3).

const FLINCH_SCALE := 0.7    # 0x101191e8, x MaxSpeed().z
const DEATH_RADIUS_MULT := 4.0  # 0x101190b4, alien_explosion final radius
const PAIN_CHANNELS := ["pain1", "pain2", "pain3"]
const PAIN_WAVS := ["audio/sfx/alien_pain.wav", "audio/sfx/alien_pain2.wav",
	"audio/sfx/alien_pain3.wav"]

var hit_flag := false        # icAlienSwarm +0x300
var swarm_fx: ParticleFx = null
var _pain := [0.0, 0.0, 0.0]  # o(1.0) one-shot states, one per channel
var _damage_smooth := 0.0     # "damage?+s(2.0)" first-order smooth
var _anim_pain: Array = []    # avatar <anim> nodes on the pain channels
var _anim_damage: Array = []  # avatar <anim> nodes on the damage channel
var _loop_player: AudioStreamPlayer3D = null
var _dead_fx_played := false

func init_alien(model: Node3D) -> void:
	# UpdateAvatar (0x1002c1f0) writes the ship radius into the avatar node's
	# scale (avatar +0x5c/+0x60/+0x64): the LWS scene is authored at unit
	# scale and the engine blows it up to the hull's 200 m.
	if model != null:
		model.scale = Vector3.ONE * radius
		_scan_avatar(model)
	# the swarm cloud itself, emitter-local, scaled by the same radius; parent
	# it to the SHIP (unscaled) so billboard sizes stay in metres
	if main != null:
		swarm_fx = ParticleFx.spawn(self, main._base(), "alienswarm",
				global_transform, radius)
	_start_loop()

func _scan_avatar(model: Node3D) -> void:
	# the two <anim> envelopes in setup_red.lws: "pain1?o(1.0) pain2?o(1.0)
	# pain3?o(1.0)" (parents the pain_flare light) and "damage?+s(2.0)"
	# (parents damage_flare). Driven here because their inputs are alien
	# state, not the flight-model channels ShipEffects feeds.
	for n in model.find_children("*", "Node3D", true, false):
		if not n.has_meta("extras"):
			continue
		var ex: Dictionary = n.get_meta("extras")
		if str(ex.get("iw2_kind", "")) != "anim" or not ex.has("iw2_pose0"):
			continue
		var ch := str(ex.get("iw2_channel", ""))
		var entry := {
			"node": n,
			"p0": _v3(ex["iw2_pose0"]["pos"]), "q0": _quat(ex["iw2_pose0"]["quat"]),
			"s0": _v3(ex["iw2_pose0"]["scale"]),
			"p1": _v3(ex["iw2_pose1"]["pos"]), "q1": _quat(ex["iw2_pose1"]["quat"]),
			"s1": _v3(ex["iw2_pose1"]["scale"]),
		}
		if "pain" in ch:
			_anim_pain.append(entry)
		elif "damage" in ch:
			_anim_damage.append(entry)

func _start_loop() -> void:
	# audio/sfx/alien_loop.ini: FcLoopSoundNode, volume 1.0, pitch_bend 1.1,
	# min_range 2000
	if main == null or main.audio == null:
		return
	var stream: AudioStreamWAV = main.audio._load_wav("audio/sfx/alien_loop.wav")
	if stream == null:
		return
	stream.loop_mode = AudioStreamWAV.LOOP_FORWARD
	_loop_player = AudioStreamPlayer3D.new()
	_loop_player.stream = stream
	_loop_player.max_distance = 2000.0
	_loop_player.pitch_scale = 1.1
	add_child(_loop_player)
	_loop_player.play()

static func _v3(a: Array) -> Vector3:
	return Vector3(a[0], a[1], a[2])

static func _quat(a: Array) -> Quaternion:
	return Quaternion(a[0], a[1], a[2], a[3]).normalized()

# --- the damage gate ---------------------------------------------------------

func _flinch(at: Vector3) -> void:
	# ApplyWeaponDamage 0x1002c2c0: velocity += normalize(pos - impact) x
	# 0.7 x MaxSpeed().z, and the was-hit flag arms the pain channel.
	hit_flag = true
	var dir := global_position - at
	if dir.length_squared() > 1e-9:
		velocity += dir.normalized() * FLINCH_SCALE * max_speed.z

func hit_by_bolt(spec: Dictionary, age: float, at: Vector3) -> Dictionary:
	_flinch(at)
	if not bool(spec.get("antimatter_based", false)):
		# non-antimatter fire never reaches icShip::ApplyWeaponDamage --
		# the override returns 0.0 damage applied
		return {"applied": 0.0, "deflected": false, "hit": "", "killed": false}
	var out := super.hit_by_bolt(spec, age, at)
	if out.get("killed", false):
		_death_explosion()
	return out

func hit_by_warhead(_dmg: float, _pen: float, at: Vector3) -> Dictionary:
	# same gate: icMissile::IsAntimatterBasedWeapon @ 0x1000f7d0 reads the
	# missile INI's antimatter_based, and no shipped warhead sets it -- only
	# antimatter_bolt and antimatter_beam do.
	_flinch(at)
	return {"applied": 0.0, "deflected": false, "hit": "", "killed": false}

func _death_explosion() -> void:
	# OnExplode 0x1002c4b0: one alien_explosion shockwave, final radius =
	# swarm radius x 4, seeded with our position and velocity. It replaces
	# the stock death; main.kill_ai's boom() still fires on top of this
	# (main.gd is owned elsewhere -- reported).
	if _dead_fx_played or main == null:
		return
	_dead_fx_played = true
	ExplosionFx.play(main, "alien_explosion",
			Transform3D(Basis.IDENTITY, global_position),
			radius * DEATH_RADIUS_MULT)

# --- per-frame ---------------------------------------------------------------

func _attack(delta: float) -> void:
	# an icShip with no weapons: pursue (the AI pilot's attack order), never
	# fire. The kill mechanism is the script-side infection at < 700 m.
	if main == null or main.ship == null:
		return
	var player: ShipFlight = main.ship
	_steer_toward(player.global_position, delta)
	var dist := global_position.distance_to(player.global_position)
	set_speed = max_speed.z if dist > 400.0 else max_speed.z * 0.35

func _physics_process(delta: float) -> void:
	super._physics_process(delta)
	_update_channels(delta)

func _update_channels(delta: float) -> void:
	# UpdateAvatar 0x1002c1f0, run every frame the avatar exists:
	if hit_flag:
		# one random pain channel fires at 1.0 (rand() % 6 >> 1 -- uniform
		# over the three), then the flag clears
		var idx := (randi() % 6) >> 1
		_pain[idx] = 1.0
		if main != null and main.audio != null:
			main.audio.play(PAIN_WAVS[idx], -4.0)
		hit_flag = false
	# the avatar's o(1.0) envelope decays each one-shot (ship_effects.gd's
	# recovered rate: state -= tau * dt * 0.5)
	for i in 3:
		_pain[i] = maxf(0.0, _pain[i] - delta * 0.5)
	var pain_v: float = maxf(_pain[0], maxf(_pain[1], _pain[2]))
	# channel "damage" = 1 - hp/max_hp when max_hp > 0 (+0x1ac / +0x1b0),
	# through the avatar's s(2.0) smooth
	var dmg_raw := 0.0
	if hull_max > 0.0:
		dmg_raw = clampf(1.0 - hull / hull_max, 0.0, 1.0)
	_damage_smooth += (dmg_raw - _damage_smooth) * minf(delta / 2.0, 1.0)
	for e in _anim_pain:
		_apply_anim(e, pain_v)
	for e in _anim_damage:
		_apply_anim(e, _damage_smooth)

func _apply_anim(e: Dictionary, t: float) -> void:
	var n: Node3D = e["node"]
	if not is_instance_valid(n):
		return
	var q: Quaternion = (e["q0"] as Quaternion).slerp(e["q1"], t)
	var b := Basis(q).scaled_local((e["s0"] as Vector3).lerp(e["s1"], t))
	n.transform = Transform3D(b, (e["p0"] as Vector3).lerp(e["p1"], t))
