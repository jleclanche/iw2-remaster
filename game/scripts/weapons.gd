class_name PbcWeapons
extends Node3D
# PBC bolt manager for every combatant. Bolt stats come from the weapon INIs
# (data/ini/sims/weapons/*.ini) -- speed, lifetime, damage, penetration and
# half_time. Swept-sphere hit tests against the player and AI ships each tick;
# damage is applied by main.on_bolt_hit, which runs the recovered damage chain
# (docs/combat.md).

const BOLT_SPEED := 6000.0
const BOLT_LIFE := 1.6
const BOLT_LENGTH := 90.0
const MUZZLES := [Vector3(0, 17.5, -8), Vector3(0, -6, -30)]

# --- where a bolt actually leaves the ship -----------------------------------
# iiGun::Fire (0x100357e0) does NOT spawn the projectile at the ship's nose. It
# calls iiWeapon::FindWorldMuzzle (0x1003da30) @ 0x10035807, which takes
#   * FcSubsim::WorldPosition -- the gun subsim's own place on the hull, i.e.
#     the attach null the ship INI mounts it at, and
#   * FcSubsim::WorldOrientation composed with the gun's local aim,
# and then adds the INI's `fire_position_translation` (iiWeapon +0x88..+0x90)
# rotated into world -- "the end of the barrel of the gun with respect to the
# attachment point of the weapon", as pbc.ini itself puts it. EVERY player gun
# in the shipped data carries the same offset: (0, 10, 4.5) in the mount's LW
# frame (pbc / light_pbc / heavy_pbc / antimatter_pbc / long_range_pbc /
# assault_cannon / the beams -- all identical).
#
# We do NOT compute that composition. We fire from the fitted gun MODEL instead:
# the tug's two standard PBCs are drawn at ship-local (0, 19.75, 0) and
# (0, -23.5, 0), their bodies spanning y 16.8..21.8 / -25.6..-20.6 about that,
# and we add the barrel run -- 4.5 m along the gun's own forward axis -- to land
# the muzzle on the barrel line. See set_muzzles().
#
# WHY, given ship_systems.gd now has the real attach nulls (bug #68): because
# the null is NOT the muzzle, and the rest of the composition does not yet add
# up. The tug's upper `pbc` mounts at setup-scene null `upper_pbc_prefitted`,
# ship-local (0, 19.400, -9.100) -- but the gun MODEL is drawn 9.1 m aft of it,
# at (0, 19.75, 0). Feeding that null through the formula above with pbc.ini's
# (0,10,4.5)/(0,-90,0) and our LWS hpb->basis convention puts the muzzle at
# (0, 14.90, -19.10): 4.85 m BELOW the drawn gun body and 14.6 m ahead of it.
# Bolts would visibly leave empty space. So either the hpb convention for
# `fire_position_rotation` (a rotation triple in the weapon's own frame) is not
# the scene-node one, or the guns baked into the tug's avatar are not where the
# engine's subsim-mounted gun avatars (pbc.ini has its own [Avatar],
# avatars/standard_pbc/setup_effects) actually sit. UNRESOLVED -- and until it
# is, the model-based muzzle is the one that demonstrably lands on the barrels.
const MUZZLE_FORWARD := 4.5

# The bolt's DIRECTION is the gun's own axis, not the hull's. iiGun::
# ComputeFiringSolution (0x10035310) short-circuits for the player:
#     if (IsPlayer() && icPlayerPilot::m_p_instance[0x9c] == 0)
#         { solution = FUN_10009670(0, 0, 1.0); return true; }
# -- gun-LOCAL +Z, no lead, no jitter (the lead solution built out of
# FindLocalTarget + FindAimPoint 0x10035170 and the FcRandom::UnitVector jitter
# below it is the AI's path). iiGun::Fire then rotates that local vector by the
# muzzle quaternion FindWorldMuzzle handed back (0x1003581a..0x10035877) and
# fires along the result. So: a fixed gun fires straight down its own barrel.
# For the tug's PBCs the barrels are hull-aligned and this is the same vector
# the nose gives; for a canted mount (and for every turret) it is not.

# sims/weapons/pbc_bolt.ini -- the standard PBC bolt (subsims .../player/pbc).
# Every PBC bolt avatar is the same icBeamAvatar (4, 1, 800): half-width 4 m,
# only the streak TEXTURE differs per class, and the ini `length` key caps the
# trailing streak (standard 800 m, light 400 m). The fire SOUND is the weapon's
# own FcSoundNode ini (audio/sfx/pbc.ini vs light_pbc.ini), play_channel=fire.
const PBC_BOLT := {"damage": 160.0, "penetration": 50.0, "half_time": 0.35,
	"speed": 6000.0, "lifetime": 1.6, "bypass_shields": false,
	"length": 800.0, "texture": "images/sfx/pbc_standard",
	"wav": "audio/sfx/pbc.wav"}
# sims/weapons/light_pbc_bolt.ini -- what a *light* PBC actually fires
const LIGHT_PBC_BOLT := {"damage": 130.0, "penetration": 35.0, "half_time": 0.3,
	"speed": 4500.0, "lifetime": 1.5, "bypass_shields": false,
	"length": 400.0, "texture": "images/sfx/pbc_light",
	"wav": "audio/sfx/light_pbc.wav"}
# sims/weapons/assault_cannon_bolt.ini -- the gatling's icBullet ("Assault
# cannon burst"). Its avatar is FIVE icBeamAvatar streaks (texture pbc_gatling,
# half-width 2.5) scattered off-axis with staggered lengths 650-800: one shot
# draws a tracer cluster, not a single fat bolt.
const ASSAULT_BOLT := {"damage": 160.0, "penetration": 52.0, "half_time": 0.35,
	"speed": 6000.0, "lifetime": 2.0, "bypass_shields": false,
	"length": 800.0, "texture": "images/sfx/pbc_gatling",
	"wav": "audio/sfx/gatling.wav",
	"burst": [Vector3(-1.6, 2.175, 0), Vector3(2.725, 1.625, 0),
		Vector3(-2.75, -0.875, 0), Vector3(1.25, -1.925, 0), Vector3.ZERO],
	"burst_lengths": [650.0, 700.0, 675.0, 750.0, 800.0]}
# the selected group's own ballistics, keyed by the gun INI's
# projectile_template stem (iiGun::Load)
const BOLT_BY_PROJECTILE := {
	"pbc_bolt": PBC_BOLT,
	"light_pbc_bolt": LIGHT_PBC_BOLT,
	"assault_cannon_bolt": ASSAULT_BOLT,
	"nps_assault_cannon_bolt": ASSAULT_BOLT,
}

var ship: ShipFlight  # player, for fire()
var main: Node3D
var refire := 0.3     # per-weapon (light PBC: 0.8 s, subsims INI)
var bolt_spec: Dictionary = PBC_BOLT
var cooldown := 0.0
var bolts: Array = []  # {node, vel, life, age, shooter, spec}
var muzzle_nodes: Array = []  # weapon-mount nulls found on the avatar
var muzzle_fallback: Array = MUZZLES  # per-hull mounts (setup-scene nulls)
# A single fixed gun mounted on a named hull null (the command section's light
# PBC on nose_hardpoint), recovered per iiWeapon::FindWorldMuzzle. Empty for the
# tug, which fires from its fitted gun models. See light_pbc_muzzle().
var fixed_gun: Dictionary = {}  # {null_pos} ship-local Godot
var _meshes: Dictionary = {}  # streak texture path -> Mesh

# --- icWeaponLink: the primary fire groups -----------------------------------
# @element icWeaponLink
# ShipSystems.weapon_groups() is the recovered grouping (icLoadout::
# CreateWeaponLinks 0x10096940 -> RemoveSingleInstancesOfWeapon -> DoLinkWeapons;
# see ship_systems.gd for the addresses). This is the firing half: the selected
# group is ONE entry in the player's cycle, and pulling the trigger fires every
# member of it on the same frame -- which is exactly what iiWeapon::
# AttemptToActivateWeapon 0x1003ccb0 does when it compares the selected id
# against the weapon's LINK id instead of the weapon's own.
#
# On the tug this comes out as the game always presented it: the two `pbc`
# subsims of tug_prefitted.ini carry the same INI name, so they are the one
# link the hull has, and they fire as a pair. The assault cannon, the quad light
# PBC and the mining laser are singles and cycle on their own.
var groups: Array = []      # [{name, class, link_type, channel, members, linked}]
var group_idx := 0          # icPlayerPilot +0x8c, over the channel-1 entries
var _null_nodes: Dictionary = {}   # attach-null name (lower) -> Node3D

func set_muzzles(model: Node3D) -> void:
	# Fire from the avatar's actual guns.
	#
	# This used to skip every MeshInstance3D, on the theory that the mounts were
	# bare nulls on the avatar -- and on the tug it therefore found NOTHING,
	# silently fell back to the hardcoded MUZZLES constants, and put both bolts
	# near the hull origin instead of in the cannons.
	#
	# The avatar was never going to have them. A ship ini's `null[i]` names a
	# node of its [SetupScene] (sims/ships/common_setups/tug.lws), which is a
	# DIFFERENT scene from its [Avatar]; FiSim::Load (flux.dll 0x100bbc00) loads
	# both and only ever searches the setup scene for mount names. That is bug
	# #68, and ship_systems.gd now resolves those nulls properly.
	#
	# It does not make the muzzle fall out, though -- see MUZZLE_FORWARD. So we
	# still take the fitted gun models: setup_prefitted.gltf carries the guns
	# themselves (`...\Pbc_cannons\RTO\LOD0_RTO_StandardPBC_T_lwo`), and firing
	# from them is what demonstrably puts the bolts down the barrels.
	#
	# The weapon latch (same `Pbc_cannons` path, so it matches "pbc" too) and the
	# bolt avatar are not guns.
	muzzle_nodes.clear()
	_null_nodes.clear()
	for n in model.find_children("*", "Node3D", true, false):
		var nm := str(n.name).to_lower()
		_null_nodes[nm] = n
		if ("pbc" in nm or "hardpoint" in nm) and "bolt" not in nm \
				and "latch" not in nm:
			muzzle_nodes.append(n)
	muzzle_nodes = muzzle_nodes.slice(0, 2)

## The world point a bolt leaves `gun` from, and the direction it leaves along:
## iiWeapon::FindWorldMuzzle (0x1003da30) + the player's gun-local (0,0,1)
## firing solution (iiGun::ComputeFiringSolution 0x10035310). See the notes on
## MUZZLE_FORWARD above.
static func muzzle_of(gun: Node3D) -> Array:
	var b := gun.global_transform.basis.orthonormalized()
	var dir: Vector3 = -b.z              # the barrel's own axis
	return [gun.global_position + dir * MUZZLE_FORWARD, dir]

## The world muzzle of a single fixed gun mounted on a hull null, recovered per
## iiWeapon::FindWorldMuzzle (iwar2.dll 0x1003da30). The engine returns
##   pos = FcSubsim::WorldPosition + M(q) * fire_position_translation
## with q = InternalOrientation (identity for a fixed gun) composed with
## FcSubsim::WorldOrientation (flux.dll 0x100c2fb0 / 0x100c3070 -- the subsim's
## mount on the hull composed with the ship's world transform). fire_position_
## rotation (+0x94) is a SEPARATE post-multiply that only turns the firing
## direction; it does NOT rotate the muzzle position (corrects the prior note).
##
## For the command section's light PBC the barrel is baked into the hull avatar
## with its tip AT the nose_hardpoint null, so FcSubsim::WorldPosition already IS
## the barrel end -- verified visually (data/screenshots/muzzleshot.png): the
## null lands on the barrel muzzle, and every metre of the +0x88 translation runs
## off into empty space ahead of the gun. So we take WorldPosition and fire down
## the hull axis, which is where the bolt leaves the barrel.
func light_pbc_muzzle() -> Array:
	var base := ship.global_transform
	var null_pos: Vector3 = fixed_gun.get("null_pos", Vector3.ZERO)
	return [base * null_pos, -base.basis.z]

## Build the cycle from the fitted weapons. Channel 1 only: the secondaries
## (beams, magazines) are missiles.gd's list.
func build_groups(sys: ShipSystems) -> void:
	groups.clear()
	group_idx = 0
	if sys == null:
		return
	for g: Dictionary in sys.weapon_groups():
		if int(g["channel"]) == 1:
			groups.append(g)

func current_group() -> Dictionary:
	if groups.is_empty():
		return {}
	return groups[clampi(group_idx, 0, groups.size() - 1)]

# --- the TRI's OFFENSIVE axis (task #60) --------------------------------------
# Every weapon is an iiWeapon, and the iiWeapon ctor (0x1003c860) writes
# eType = 1, so the whole armament hangs off TRI axis 1. Four consumers, and NOT
# one of them is the plain multiply you would guess:
#
#   iiGun::Range        0x1000f090   w * range          (range +0xc0)
#   iiGun::RefireDelay  0x1000f0a0   refire / w         (`fdivr [esi+0xb8]`)
#   iiGun::IsReadyToFire 0x10035120  refuses (result 0xd) while
#                                    `w * time_since_shot < refire` -- which is
#                                    exactly the RefireDelay() test above
#   iiWeapon::Fire      0x100357e0   projectile damage (+0x1e8)   = w * damage
#                                    projectile lifetime (+0x1f0) = w * lifetime
#
# The lifetime scaling is how Range() stays honest: range = speed * lifetime
# (docs/combat.md), so multiplying the bolt's lifetime by w moves the bolt's
# reach by exactly the same w the gun advertises. At full offensive that is
# 1.5x damage, 1.5x reach and a 1/1.5 = 0.667x refire delay -- a 2.25x DPS
# swing between the two corners.
func _tri_offensive() -> float:
	if main != null and main.sys != null:
		return (main.sys as ShipSystems).tri_weight(ShipSystems.TRI_OFFENSIVE)
	return 1.0

## icPlayerPilot::GetNextWeapon 0x100b0590 / CycleWeapon 0x100b0b70 -- wrap round
## the channel-1 entries. Returns TRUE when the selection actually moved.
##
## The original walks the id list from the current index, wrapping, and stops at
## the first entry that matches the fire channel and is not an empty magazine;
## if it gets all the way back to where it started, the selection is simply left
## where it was. Two edge cases fall straight out of that loop, and they are the
## two the remaster had wrong:
##   - ZERO entries: `if (this+0x90 == 0) { this+0x8c = -1; return; }` -- the
##     index is cleared and nothing else happens.
##   - ONE entry: the loop steps off the end, wraps to itself, accepts itself.
##     The "next" weapon is the weapon you already have. Nothing changes.
## In neither case does the engine make a sound, log an event, or flash the HUD.
func cycle_group() -> bool:
	if groups.size() <= 1:
		return false
	group_idx = (group_idx + 1) % groups.size()
	return true

func group_label() -> String:
	var g := current_group()
	if g.is_empty():
		return ""
	var n: int = (g["members"] as Array).size()
	# the INI `name=` is a localisation key: Cargo_ParticleBeamCannon is "PBC",
	# Cargo_AssaultCannon is "Gatling Cannon" (data/json/strings.json)
	var label: String = ShipSystems.display_name(str(g["name"])).to_upper()
	return "%s x%d" % [label, n] if bool(g["linked"]) else label

## The muzzles the selected group fires from: each member's own attach null.
##
## In practice this always returns []: `_null_nodes` is keyed by AVATAR node
## name, and no avatar carries a node named after a ship ini's `null[i]` -- the
## mount names live in the [SetupScene], not the avatar (bug #68; see
## set_muzzles). So fire() always falls through to `muzzle_nodes`, the fitted
## gun models, which is what we want it to do until the muzzle composition in
## MUZZLE_FORWARD is settled. Kept, not deleted: this is the shape the proper
## per-member lookup takes once the muzzle offset is understood, and it already
## does the right thing for any hull whose avatar DOES name its mounts.
func _group_muzzles() -> Array:
	var g := current_group()
	if g.is_empty():
		return []
	var out: Array = []
	for m: Dictionary in (g["members"] as Array):
		if bool(m["destroyed"]) or float(m["efficiency"]) <= 0.0:
			continue
		var key: String = str(m["null"]).to_lower()
		if _null_nodes.has(key) and is_instance_valid(_null_nodes[key]):
			out.append(_null_nodes[key])
	return out

# the bolt's own avatar (avatars/<class>_pbc_bolt/setup.lws) is an
# icBeamAvatar streak; the class picks the texture (pbc_standard / pbc_light /
# pbc_heavy), the geometry is shared
func _bolt_mesh(spec: Dictionary) -> Mesh:
	var tex := str(spec.get("texture", ExplosionFx.BOLT_TEXTURE))
	if not _meshes.has(tex) and main:
		_meshes[tex] = ExplosionFx.bolt_mesh(main._base(), tex)
	return _meshes.get(tex)

# iiGun::ComputeFiringSolution (0x10035310) + the reticle's FUN_100f8ef0:
# FindLocalTarget gives the target in gun space, FindAimPoint leads it at the
# bolt's own speed (the bolt inherits shooter velocity, so the lead solves on
# RELATIVE velocity), IsInFireArc tests the gun's ini fire arcs. The player's
# bolts fire straight down the barrel ONLY when icPlayerPilot+0x9c (aim
# assist) is off; with it on and a locked solution, the fired bolt takes the
# assisted direction.
func firing_solution(target: Node3D) -> Dictionary:
	var out := {"lead": Vector3.INF, "in_range": false, "locked": false}
	if target == null or not is_instance_valid(target) or ship == null:
		return out
	var rel: Vector3 = target.global_position - ship.global_position
	var d := rel.length()
	var bolt_speed := float(bolt_spec.get("speed", 6000.0))
	var tvel: Vector3 = (target.velocity if "velocity" in target
			else Vector3.ZERO) - ship.velocity
	var lead: Vector3 = target.global_position + tvel * (d / bolt_speed)
	out["lead"] = lead
	# iiWeapon::Range (vtbl+0x60) for a bullet = speed x lifetime
	var rng := bolt_speed * float(bolt_spec.get("lifetime", 1.6))
	out["in_range"] = d <= rng
	if out["in_range"] and main != null and main.aim_assist:
		var fwd: Vector3 = -ship.global_transform.basis.z
		var dir := (lead - ship.global_position).normalized()
		# 30-degree half-angle from the ini's horizontal/vertical_fire_arc=60
		out["locked"] = fwd.dot(dir) >= 0.8660254
	return out

func fire() -> void:
	if cooldown > 0.0:
		return
	# iiWeapon::Simulate 0x1003cc00 sets flag 0x200 and refuses to fire while
	# the ship's TotalHeat is at or past heat_damage_threshold. (In practice
	# only internal heat can get there: sun/planet proximity heat is dormant
	# in the shipped game -- see main.gd's body-heat gate.)
	if main and main.sys != null and main.sys.heat + main.sys.heat_external \
			>= ShipSystems.HEAT_DAMAGE_THRESHOLD:
		# the warning line is ours; the original surfaces this only through
		# the heat gauge and the weapon's refusal
		main.hud.warn("WEAPONS HEAT-LOCKED")
		return
	# iiWeapon::IsReadyToFire 0x1003cb80: the disrupted flag (0x10, set by a
	# full-disruption warhead through icShip::Disrupt) blocks fire
	if main and main.weapon_disrupt_time > 0.0 and main.weapon_disrupt_full:
		return
	# The SELECTED group's own gun subsims carry the ballistics (iiGun::Load):
	# PBC refire 0.7 s, light PBC 0.8 s, the gatling 0.12 s with a 200-round
	# icSlugThrower ammo counter. The class-level refire/bolt_spec stay as the
	# fallback for hulls without recovered groups.
	var g := current_group()
	var members: Array = g.get("members", []) if not g.is_empty() else []
	var live: Array = members.filter(func(m: Dictionary) -> bool:
			return not bool(m.get("destroyed", false)) \
			and float(m.get("efficiency", 1.0)) > 0.0 \
			and int(m.get("ammo", -1)) != 0)
	if not members.is_empty() and live.is_empty():
		return  # dead, dark or dry: icSlugThrower::IsReadyToFire result 8
	var base_refire := refire
	var base_spec := bolt_spec
	if not live.is_empty():
		var m0: Dictionary = live[0]
		base_refire = float(m0.get("refire", refire))
		base_spec = BOLT_BY_PROJECTILE.get(
				str(m0.get("projectile", "")).get_file(), bolt_spec)
	# iiGun::RefireDelay 0x1000f0a0 -- the INI delay DIVIDED by the TRI weight
	var w := _tri_offensive()
	cooldown = base_refire / maxf(w, 1e-3)
	# iiWeapon::Fire 0x100357e0 -- the bolt leaves with w * damage and w * lifetime
	var spec := base_spec
	if not is_equal_approx(w, 1.0):
		spec = base_spec.duplicate()
		spec["damage"] = float(base_spec["damage"]) * w
		spec["lifetime"] = float(base_spec["lifetime"]) * w
	# The selected fire group fires as one -- every member on the same frame.
	# A group whose members' attach nulls are all on the avatar fires from them;
	# otherwise we fall back to the hull's authored PBC mounts, which is what the
	# tug's linked pair resolves to anyway.
	# Each gun fires from its own barrel end, down its own axis (muzzle_of).
	# A single fixed gun mounted on a hull null (the command section's light PBC)
	# fires from FcSubsim::WorldPosition down the hull axis -- the recovered muzzle
	# (light_pbc_muzzle), not the model-node fallback which sat 3-4 m ahead of the
	# barrel.
	# icShip::SetLastFireTarget (0x10075000): the weapon fire path stamps the
	# has-fired flag and the gun's engaged target -- what the POG reactive
	# systems (istation.pog's protection loop) poll via iship.HasFired /
	# LastFireTarget
	if main != null:
		main.player_has_fired = true
		if main.target_ai != null and is_instance_valid(main.target_ai):
			main.player_last_fire_target = main.target_ai
	# With aim assist on and a LOCKED solution the bolts take the assisted
	# direction (ComputeFiringSolution's player branch, gated on +0x9c).
	var assist_lead := Vector3.INF
	if main != null and main.aim_assist and main.target_ai != null \
			and is_instance_valid(main.target_ai):
		var sol := firing_solution(main.target_ai)
		if sol["locked"]:
			assist_lead = sol["lead"]
	if not fixed_gun.is_empty():
		var fm: Array = light_pbc_muzzle()
		_spawn_at(ship, fm[0], _aim_dir(fm[0], fm[1], assist_lead),
				ship.velocity, spec)
		if main:
			main.audio.play(str(spec.get("wav", "audio/sfx/pbc.wav")), -8.0)
		return
	var fired := 0
	if not live.is_empty() and not bool(g.get("linked", false)):
		# a SINGLE (the gatling, sharing the lower PBC's mount) fires one bolt
		# from its own mount point -- FcSubsim::WorldPosition, which
		# iiWeapon::FindWorldMuzzle (0x1003da30) starts from -- not from both
		# fitted PBC gun models, which is what the fallback list would do
		var mp: Vector3 = live[0].get("pos", Vector3.ZERO)
		var wp: Vector3 = ship.global_transform * mp
		_spawn_at(ship, wp, _aim_dir(wp, -ship.global_transform.basis.z,
				assist_lead), ship.velocity, spec)
		fired = 1
	else:
		var mz: Array = _group_muzzles()
		if mz.is_empty():
			mz = muzzle_nodes.filter(func(n: Node3D) -> bool:
					return is_instance_valid(n))
		if not mz.is_empty():
			for n in mz:
				var m: Array = PbcWeapons.muzzle_of(n as Node3D)
				_spawn_at(ship, m[0], _aim_dir(m[0], m[1], assist_lead),
						ship.velocity, spec)
				fired += 1
		else:
			# no gun on the avatar at all: the hull's authored mounts, still
			# fired along the hull's forward because that is all a bare point
			# can give us
			for m in muzzle_fallback:
				var p: Vector3 = ship.global_transform * m
				_spawn_at(ship, p,
						_aim_dir(p, -ship.global_transform.basis.z, assist_lead),
						ship.velocity, spec)
				fired += 1
	# icSlugThrower: spend the rounds (+0xd4 decrements per shot)
	for i in mini(fired, live.size()):
		var mem: Dictionary = live[i]
		if int(mem.get("ammo", -1)) > 0:
			mem["ammo"] = int(mem["ammo"]) - 1
	if main:
		main.audio.play(str(spec.get("wav", "audio/sfx/pbc.wav")), -8.0)

static func _aim_dir(muzzle: Vector3, barrel: Vector3, lead: Vector3) -> Vector3:
	# barrel line normally; the assisted lead direction when locked
	if lead == Vector3.INF:
		return barrel
	var d := lead - muzzle
	return d.normalized() if d.length_squared() > 1.0 else barrel

func spawn(shooter: Node3D, dir: Vector3, spec: Dictionary = {}) -> void:
	var vel: Vector3 = shooter.velocity if "velocity" in shooter else Vector3.ZERO
	_spawn_at(shooter, shooter.global_position + dir * 40.0, dir, vel,
			spec if not spec.is_empty() else bolt_spec)

func _spawn_at(shooter: Node3D, pos: Vector3, dir: Vector3, base_vel: Vector3,
		spec: Dictionary = {}) -> void:
	if spec.is_empty():
		spec = bolt_spec
	if shooter is ShipFlight and (shooter as ShipFlight).fx != null:
		(shooter as ShipFlight).fx.fire_pulse = 1.0
	var node: Node3D
	var burst: Array = spec.get("burst", [])
	if burst.is_empty():
		var mi := MeshInstance3D.new()
		mi.mesh = _bolt_mesh(spec)
		node = mi
	else:
		# the gatling burst: five streaks around the muzzle line, each with
		# its own authored length cap (avatars/assault_cannon_bolt/setup.lws)
		node = Node3D.new()
		var lens: Array = spec.get("burst_lengths", [])
		for bi in burst.size():
			var mi := MeshInstance3D.new()
			mi.mesh = _bolt_mesh(spec)
			mi.position = burst[bi]
			if bi < lens.size():
				mi.scale = Vector3(1, 1, float(lens[bi]) / float(spec["length"]))
			node.add_child(mi)
	get_parent().add_child(node)
	var up := Vector3.UP if absf(dir.dot(Vector3.UP)) < 0.99 else Vector3.RIGHT
	var aim := Basis.looking_at(dir, up)
	node.global_position = pos
	# the streak mesh is unit-length and trails BEHIND the head; it stretches
	# to min(distance flown, BOLT_LENGTH) each tick so the tail stays pinned to
	# the muzzle as the bolt leaves the barrel (see ExplosionFx.bolt_mesh)
	node.global_transform.basis = aim * Basis.from_scale(Vector3(1, 1, 0.5))
	# the bolt carries its own glow light: avatars/light_pbc_bolt/setup.lws
	# parents a point light (252,128,16), intensity 1.0, falloff range 300 m,
	# to the bolt root -- passing fire lights up nearby hulls
	var gl := OmniLight3D.new()
	gl.light_color = Color(0.988, 0.502, 0.063)
	gl.light_energy = 1.0
	gl.omni_range = 300.0
	gl.shadow_enabled = false
	node.add_child(gl)
	if main:
		ExplosionFx.muzzle_flash(main, pos)
	bolts.append({"node": node, "vel": base_vel + dir * float(spec["speed"]),
			"life": float(spec["lifetime"]), "age": 0.0, "spawn": pos,
			"aim": aim, "shooter": shooter, "spec": spec})

func _physics_process(delta: float) -> void:
	cooldown = maxf(0.0, cooldown - delta)
	var targets: Array = []
	if main:
		targets = main.ai_ships.duplicate()
		targets.append(main.ship)
	var i := bolts.size() - 1
	while i >= 0:
		var bolt: Dictionary = bolts[i]
		bolt["life"] -= delta
		bolt["age"] = float(bolt["age"]) + delta
		var node: Node3D = bolt["node"]
		var dead: bool = bolt["life"] <= 0.0 or not is_instance_valid(node)
		if not dead:
			var move: Vector3 = bolt["vel"] * delta
			var from: Vector3 = node.global_position
			node.global_position = from + move
			# stretch the trailing streak: tail pinned at the muzzle until the
			# bolt is BOLT_LENGTH out, then a constant-length tracer
			var flown: float = (node.global_position
					- bolt.get("spawn", from)).length()
			# the streak cap is the bolt ini's `length` (light PBC 400 m)
			node.global_transform.basis = (bolt["aim"] as Basis) \
					* Basis.from_scale(Vector3(1, 1, clampf(flown, 0.5,
					float((bolt["spec"] as Dictionary).get("length",
						ExplosionFx.BOLT_LENGTH)))))
			for t in targets:
				if t == bolt["shooter"] or not is_instance_valid(t):
					continue
				if not _segment_sphere(from, node.global_position,
						t.global_position, 60.0):
					continue
				# where the bolt struck matters now: it picks the subsim that
				# takes the direct critical
				var at := _closest_point(from, node.global_position,
						t.global_position)
				main.on_bolt_hit(t, at, bolt["shooter"], bolt)
				dead = true
				break
		if dead:
			if is_instance_valid(node):
				node.queue_free()
			bolts.remove_at(i)
		i -= 1

func _closest_point(a: Vector3, b: Vector3, c: Vector3) -> Vector3:
	var ab := b - a
	var t := clampf((c - a).dot(ab) / maxf(ab.length_squared(), 1e-6), 0.0, 1.0)
	return a + ab * t

func _segment_sphere(a: Vector3, b: Vector3, c: Vector3, r: float) -> bool:
	return _closest_point(a, b, c).distance_squared_to(c) < r * r

func clear() -> void:
	for bolt in bolts:
		var node: Node3D = bolt["node"]
		if is_instance_valid(node):
			node.queue_free()
	bolts.clear()

func shift_world(offset: Vector3) -> void:
	for bolt in bolts:
		var node: Node3D = bolt["node"]
		if is_instance_valid(node):
			node.global_position -= offset
