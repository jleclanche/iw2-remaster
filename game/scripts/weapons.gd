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

# sims/weapons/pbc_bolt.ini -- the standard PBC bolt (subsims .../player/pbc)
const PBC_BOLT := {"damage": 160.0, "penetration": 50.0, "half_time": 0.35,
	"speed": 6000.0, "lifetime": 1.6, "bypass_shields": false}
# sims/weapons/light_pbc_bolt.ini -- what a *light* PBC actually fires
const LIGHT_PBC_BOLT := {"damage": 130.0, "penetration": 35.0, "half_time": 0.3,
	"speed": 4500.0, "lifetime": 1.5, "bypass_shields": false}

var ship: ShipFlight  # player, for fire()
var main: Node3D
var refire := 0.3     # per-weapon (light PBC: 0.8 s, subsims INI)
var bolt_spec: Dictionary = PBC_BOLT
var cooldown := 0.0
var bolts: Array = []  # {node, vel, life, age, shooter, spec}
var muzzle_nodes: Array = []  # weapon-mount nulls found on the avatar
var muzzle_fallback: Array = MUZZLES  # per-hull mounts (setup-scene nulls)
var _mesh: Mesh

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

# the bolt's own avatar (avatars/standard_pbc_bolt/setup.lws) is an
# icBeamAvatar streak textured with images/sfx/pbc_standard, not a box
func _bolt_mesh() -> Mesh:
	if _mesh == null and main:
		_mesh = ExplosionFx.bolt_mesh(main._base())
	return _mesh

func fire() -> void:
	if cooldown > 0.0:
		return
	# iiWeapon::Simulate 0x1003cc00 sets flag 0x200 and refuses to fire while
	# the ship's TotalHeat is at or past heat_damage_threshold
	if main and main.sys != null and main.sys.heat + main.sys.heat_external \
			>= ShipSystems.HEAT_DAMAGE_THRESHOLD:
		return
	# iiWeapon::IsReadyToFire 0x1003cb80: the disrupted flag (0x10, set by a
	# full-disruption warhead through icShip::Disrupt) blocks fire
	if main and main.weapon_disrupt_time > 0.0 and main.weapon_disrupt_full:
		return
	# iiGun::RefireDelay 0x1000f0a0 -- the INI delay DIVIDED by the TRI weight
	var w := _tri_offensive()
	cooldown = refire / maxf(w, 1e-3)
	# iiWeapon::Fire 0x100357e0 -- the bolt leaves with w * damage and w * lifetime
	var spec := bolt_spec
	if not is_equal_approx(w, 1.0):
		spec = bolt_spec.duplicate()
		spec["damage"] = float(bolt_spec["damage"]) * w
		spec["lifetime"] = float(bolt_spec["lifetime"]) * w
	# The selected fire group fires as one -- every member on the same frame.
	# A group whose members' attach nulls are all on the avatar fires from them;
	# otherwise we fall back to the hull's authored PBC mounts, which is what the
	# tug's linked pair resolves to anyway.
	# Each gun fires from its own barrel end, down its own axis (muzzle_of).
	var mz: Array = _group_muzzles()
	if mz.is_empty():
		mz = muzzle_nodes.filter(func(n: Node3D) -> bool:
				return is_instance_valid(n))
	if not mz.is_empty():
		for n in mz:
			var m: Array = PbcWeapons.muzzle_of(n as Node3D)
			_spawn_at(ship, m[0], m[1], ship.velocity, spec)
	else:
		# no gun on the avatar at all: the hull's authored mounts, still fired
		# along the hull's forward because that is all a bare point can give us
		for m in muzzle_fallback:
			_spawn_at(ship, ship.global_transform * m,
					-ship.global_transform.basis.z, ship.velocity, spec)
	if main:
		main.audio.play("audio/sfx/light_pbc.wav", -8.0)

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
	var node := MeshInstance3D.new()
	node.mesh = _bolt_mesh()
	get_parent().add_child(node)
	node.global_position = pos
	node.global_transform.basis = Basis.looking_at(dir, Vector3.UP)
	if main:
		ExplosionFx.muzzle_flash(main, pos)
	bolts.append({"node": node, "vel": base_vel + dir * float(spec["speed"]),
			"life": float(spec["lifetime"]), "age": 0.0,
			"shooter": shooter, "spec": spec})

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
		var node: MeshInstance3D = bolt["node"]
		var dead: bool = bolt["life"] <= 0.0 or not is_instance_valid(node)
		if not dead:
			var move: Vector3 = bolt["vel"] * delta
			var from: Vector3 = node.global_position
			node.global_position = from + move
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
		var node: MeshInstance3D = bolt["node"]
		if is_instance_valid(node):
			node.queue_free()
	bolts.clear()

func shift_world(offset: Vector3) -> void:
	for bolt in bolts:
		var node: MeshInstance3D = bolt["node"]
		if is_instance_valid(node):
			node.global_position -= offset
