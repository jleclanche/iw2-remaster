# Main layer: bolts, kills, shockwaves, secondary weapons, the zoom gate.
# Part of main.gd's extends chain -- see
# main_state.gd for the scheme. Same node, same class.
extends "main_world.gd"

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
	# the authored cutter: 1500 hp, 55 armour, an icAILDA shield and ten other
	# subsims (sims/ships/marauder/marauder_cutter.ini)
	ai.setup_ini("sims/ships/marauder/marauder_cutter.ini", model)
	ai.position = at
	add_child(ai)
	ai_ships.append(ai)
	audio.music("action")
	hud.warn("HOSTILE CONTACT", 3.0)
	audio.play("audio/hud/klaxon.wav", -6.0)
	return ai

func spawn_bolt(shooter: Node3D, dir: Vector3) -> void:
	# NPC cannons: nps_pbc.ini fires the same sims/weapons/pbc_bolt, and its
	# effects rig carries the same audio/sfx/pbc FcSoundNode as the player gun
	if shooter is AiShip:
		# SetLastFireTarget: an attacking AI's engaged target is the player
		(shooter as AiShip).record_fire(
				ship if (shooter as AiShip).behavior == "attack" else null)
	weapons.spawn(shooter, dir, PbcWeapons.PBC_BOLT)
	audio.play("audio/sfx/pbc.wav", -8.0)

func on_bolt_hit(target: Node3D, pos: Vector3, shooter: Node3D = null,
		bolt: Dictionary = {}) -> void:
	# lws:/sfx/hull_impact_high_0: the impact sound, the pbc_spark system and
	# a flash, with the sparks thrown back out along the surface normal
	var out := pos - target.global_position
	out = out.normalized() if out.length_squared() > 1.0 else Vector3.FORWARD
	var spec: Dictionary = bolt.get("spec", PbcWeapons.PBC_BOLT)
	var age: float = float(bolt.get("age", 0.0))
	if target == ship:
		if shooter is AiShip:
			last_aggressor = shooter
		var hit := hit_player(spec, age, pos)
		# A deflected bolt never reaches the hull -- it flares on the LDA field,
		# and the engine has a separate effect for exactly that. Playing a
		# scaled-down hull impact was our invention.
		ExplosionFx.play(self,
				"lda_impact" if hit["deflected"] else "hull_impact",
				Transform3D(Basis.looking_at(-out), pos), 1.0)
		return
	ExplosionFx.play(self, "hull_impact",
			Transform3D(Basis.looking_at(-out), pos), 1.0)
	var ai := target as AiShip
	if ai == null:
		return
	# iiSim::ApplyWeaponDamage records the attacker (SetLastAggressor
	# 0x10079640); icShip::CheckForReactives (0x10073ac0) additionally counts
	# PLAYER shots on a non-hostile ship and only reacts past the ini's
	# max_player_shots_before_aggression (default 4) -- the original's
	# "forgive the first few shots" rule
	if shooter is AiShip:
		ai.set_last_aggressor(shooter)
	elif shooter == ship:
		if not _is_hostile(ai):
			ai.player_shots += 1
			if ai.pissed_with_player():
				ai.set_last_aggressor(ship)
				_check_reaction(ai)
		else:
			ai.set_last_aggressor(ship)
	var killed: bool = ai.hit_by_bolt(spec, age, pos)["killed"]
	if killed:
		# a player kill of a friendly marks the aggression even in death
		# (icShip::ApplyWeaponDamage 0x10073cf0 tail) -- the group/escort
		# check below still sees the wreck's aggressor this frame
		if shooter == ship:
			ai.set_last_aggressor(ship)
			_propagate_group_attack(ai)
		kill_ai(ai)

func kill_ai(ai: AiShip) -> void:
	# iiSim::OnKilled 0x10079b80 -> OnExplode (0x10079db0) -> removal;
	# shared by bolt hits (on_bolt_hit) and warheads (missiles.gd)
	if ai == null or not is_instance_valid(ai) or ai.dying:
		return
	kill_count += 1
	hud.warn("%s DESTROYED" % str(ai.display_name).to_upper())
	# icAlienSwarm::OnExplode 0x1002c4b0 replaces the stock death with its own
	# alien_explosion shockwave (alien.gd plays it) -- no generic death on top
	if ai is AlienShip:
		_finish_kill(ai)
	else:
		ai.dying = true
		ai.behavior = "dying"
		var done := DeathSequence.explode(self, ai, ai.explosion_size,
				ai.radius, ai.half_dims, ai.velocity, _finish_kill.bind(ai))
		if not done:
			# the dramatic path: dead hands on the stick -- the hulk keeps its
			# velocity and tumbles until the reactor goes
			ai.assist = false
			ai.angular_velocity = DeathSequence.tumble(ai.velocity)
	if not _hostiles_alive():
		audio.music("ambient")

func _finish_kill(ai: AiShip) -> void:
	if ai == null or not is_instance_valid(ai):
		return
	if towed == ai:
		_release_tow(false)
	if ai.carried_pods > 0:
		_spill_pods(ai)
	ai_ships.erase(ai)
	if target_ai == ai:
		target_ai = null
	ai.queue_free()

# iiSim::DetachAndFlingChild (0x1007be50): DoFinalExplosion detaches every
# surviving child subsim and flings it -- for a freighter (nine cargo clamps,
# sims/ships/utility/freighter.ini [Subsims]) the children are its racked
# cargo pods, so a dying hauler spills them as free sims. Pod CONTENT in the
# original comes from iCargoScript's location-weighted generators
# (FindCargoForLocation / CheapCargoGenerator...); the uniform pick over the
# registered commodity table here is a stand-in for that weighting.
var _pod_seq := 0

func _spill_pods(ai: AiShip) -> void:
	if pog_world == null:
		return
	for i in ai.carried_pods:
		_pod_seq += 1
		var s = pog_world._create_ship("ini:/sims/ships/utility/cargo_pod",
				"spilled_pod_%d" % _pod_seq)
		if s == null or s.node == null:
			return
		var dir := ExplosionFx._unit_vector()
		(s.node as Node3D).global_position = ai.global_position \
				+ dir * maxf(ai.radius * 0.5, 30.0)
		# flung like the debris: radius * 0.4 (0x10117558), riding the wreck's
		# velocity
		(s.node as Node3D).velocity = ai.velocity + dir * ai.radius * 0.4
		if pog_econ != null and not pog_econ.cargo_types.is_empty():
			var ids: Array = pog_econ.cargo_types.keys()
			pog_std._bag(s)["cargo"] = ids[randi() % ids.size()]

func _update_shockwaves(delta: float) -> void:
	for i in range(_shockwaves.size() - 1, -1, -1):
		var sw: Dictionary = _shockwaves[i]
		sw["t"] = float(sw["t"]) + delta
		var t: float = sw["t"]
		if t >= DeathSequence.SHOCKWAVE_LIFETIME:
			_shockwaves.remove_at(i)
			continue
		sw["pos"] = (sw["pos"] as Vector3) + (sw["vel"] as Vector3) * delta
		var frac := t / DeathSequence.SHOCKWAVE_LIFETIME
		var front: float = float(sw["r"]) * frac
		if front <= 0.0:
			continue
		var inner := front * (1.0 - DeathSequence.SHOCKWAVE_FRONT_DEPTH)
		# the ini documents only the t=0 rate; the fade to 0 over the
		# lifetime is eyeballed (linear, like the avatar's alpha)
		var dmg: float = float(sw["rate"]) * (1.0 - frac) * delta
		if dmg <= 0.0:
			continue
		var c: Vector3 = sw["pos"]
		var pd := ship.global_position.distance_to(c)
		if pd >= inner and pd <= front:
			if sys != null:
				sys.apply_damage(dmg)
			else:
				hull = maxf(hull - dmg, 0.0)
			if not bool(sw["warned"]):
				sw["warned"] = true
				hud.warn("SHOCKWAVE  HULL %d%%" % int(100.0 * hull / hull_max))
			if hull <= 0.0:
				_kill_player()
		for a in ai_ships.duplicate():
			var as_ship := a as AiShip
			if as_ship == null or as_ship.dying:
				continue
			var d: float = as_ship.global_position.distance_to(c)
			if d >= inner and d <= front and as_ship.damage(dmg):
				kill_ai(as_ship)

func _hostiles_alive() -> bool:
	for a in ai_ships:
		if a.behavior == "attack":
			return true
	return false

func _fire_aggressor() -> void:
	if sys == null:
		return
	if sys.aggressors.is_empty():
		hud.warn("NO AGGRESSOR SHIELD FITTED")
		return
	if sys.aggressor_fire():
		# the aggressor_shield sound INI is an FcThreePartSoundNode keyed on the
		# same "fire" channel Simulate drives (attack aggressor_start, sustain
		# aggressor_loop, decay aggressor_end)
		audio.play("audio/sfx/aggressor_start.wav", -6.0)
		hud.warn("AGGRESSOR SHIELD UP")
	else:
		audio.play("audio/gui/mechanical_deny.wav", -10.0)


# @element icAggressorShield
## The ram. iiSim::OnCollision (0x10078ab0, the shared collision handler at
## 0x1009971c) asks BOTH colliding ships for an icAggressorShield subsim before
## it computes ordinary collision damage; if one of them has a live shield whose
## cone covers the other, that shield handles the collision and the normal damage
## never happens. This is the player's half of it: the AI's aggressors are not
## fitted by any shipped non-player hull.
##
## The program-driven auto-fire comes first (bit 0x1000, aggressor_shield_control):
## with it fitted, the shield fires itself at anything hostile you are about to
## hit. Without it you hold the trigger yourself.
func _aggressor_ram(a: AiShip) -> bool:
	if sys == null or sys.aggressors.is_empty() or not is_instance_valid(a):
		return false
	var d := a.global_position - ship.global_position
	var dist := d.length()
	if dist >= 95.0 or dist < 0.1:
		return false
	# the direction to the victim, in the player's local frame
	var dir_local: Vector3 = ship.global_transform.basis.inverse() * (d / dist)
	sys.aggressor_auto(dir_local, _is_hostile(a))
	var hit: Dictionary = sys.aggressor_hit(dir_local, ship.velocity.length())
	if not bool(hit["handled"]):
		return false
	if a.damage(float(hit["damage"])):
		kill_ai(a)
	# the shield's own ship takes damage * self_damage_factor, source 4
	damage_player(float(hit["self_damage"]), "AGGRESSOR RAM")
	hud.warn("AGGRESSOR SHIELD - %s" % str(a.display_name).to_upper())
	audio.play("audio/sfx/collision.wav", -3.0)
	# push the wreck clear so the same frame does not re-trigger
	var n := d / dist
	ship.global_position = a.global_position - n * 95.0
	return true

func _check_reaction(ai: AiShip) -> void:
	# icShip::CheckReaction (0x10075860) -> icAIPilot::OnAttack (0x10055130).
	# OnAttack only reacts to the PLAYER, gated on feeling toward the player
	# being neutral-or-worse OR the ship already pissed. The fight/flee threat
	# ratios then default to 1000.0 (icAIPilot ctor 0x10054130) and NO shipped
	# script or ini changes them, so the stock outcome is the IGNORE branch --
	# the ship is marked as an explicit hostile contact (CheckForReactives'
	# reactives insert: the red contact + TargetNearestHostile candidate)
	# without itself opening fire. The shooting comes from its ESCORTS
	# (icAIEscortAgent, below) and from the POG station-protection/incident
	# scripts (istation.pog, igangsterincidentgen.pog), which we run.
	if iff_level(str(ai.faction)) <= 2 or ai.pissed_with_player():
		ai.explicit_hostile = true
		hud.log_msg("%s: HOSTILE" % str(ai.display_name).to_upper(), Hud.RED)
	_propagate_group_attack(ai)

func _propagate_group_attack(victim: AiShip) -> void:
	# icAIEscortAgent::GroupAttacker (0x100530b0) -> ExplicitAttack
	# (0x10052ed0): an escort polls its group for a member holding a hostile
	# last-aggressor and turns to attack that aggressor -- no radius check,
	# the logical group only. Our aggressor on this path is always the player.
	var dispatched := false
	for a: AiShip in ai_ships:
		if a == victim or not is_instance_valid(a):
			continue
		if a.escort_of == victim and a.behavior != "attack":
			a.behavior = "attack"
			a.set_last_aggressor(ship)
			dispatched = true
	if dispatched:
		# GroupAttacker consumes the member's aggressor once dispatched
		victim.last_aggressor = null

## Player against another SHIP. The extracted law (the collide handler above
## iiSim::OnCollision @ 0x10078ab0): BOTH parties take the SAME damage --
## ((|dv_a|/sweet)^2 m_a + (|dv_b|/sweet)^2 m_b) x factor, source 4 -- and
## both feel the response. The old path damaged only the player and left the
## other hull untouched at full speed. The 1.6 bounce stands in for the
## engine's contact solve; the partner's share of it comes from momentum
## against its own mass.
func _collide_ai(a: AiShip) -> void:
	if a == null or not is_instance_valid(a) or a.dying:
		return
	var d := ship.global_position - a.global_position
	var dist := d.length()
	if dist >= 95.0 or dist < 0.1:
		return
	var n := d / dist
	var rel: float = (ship.velocity - a.velocity).dot(n)
	if rel < 0.0:
		var m_p := maxf(ship.mass, 1.0)
		var m_a := maxf(a.mass, 1.0)
		var dv_p := -rel * 1.6
		var dv_a := dv_p * m_p / m_a
		ship.velocity -= n * rel * 1.6
		a.velocity += n * rel * 1.6 * (m_p / m_a)
		var dmg := _collision_damage(dv_p, m_p, dv_a, m_a)
		damage_player(dmg, "COLLISION - " + str(a.display_name).to_upper())
		if a.damage(dmg):
			kill_ai(a)
		audio.play("audio/sfx/collision.wav", -3.0)
		audio.play("audio/sfx/ship_clatter.wav", -8.0)
	ship.global_position = a.global_position + n * 95.0

func _collisions() -> void:
	# player_collision: leave() clears docked_at BEFORE the startup movie, but
	# the ship is still parked inside the base hull until _launch() places it
	# -- the original keeps sim collision off across that stretch
	# (istartsystem.pog:72..86)
	if docked_at != "" or jump_state >= 2 or not player_collision:
		return
	# The base's docking cutscene flies the ship THROUGH the station's hull and
	# parks it inside the bay, so the ship must not collide with anything while
	# it runs. That is not a fudge: iBackToBase.DockingCutscene calls
	# `sim.SetCollision(player, 0)` the moment it takes the ship (pogsrc/
	# ibacktobase.pog, at the dolly setup) and the detector calls it again before
	# it places the ship inside the base. Without it you fly into the hull at
	# 300 m/s -- which is exactly what happened.
	if base_iface != null and base_iface.cut > 0:
		return
	for a in ai_ships:
		if _aggressor_ram(a):
			continue
		_collide_ai(a)
	for o in objects:
		if o["node"] == null:
			continue
		if o["category"] == "station" or o["category"] == "gunstar" \
				or o.get("prop_collide", false):
			if o.get("hull", false):
				# the ini's real CollisionHull trimesh
				_collide_hull(o)
				continue
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

# --- the missile system: player-side plumbing (missiles.gd) -----------------

func _select_secondary(idx: int) -> void:
	secondary_idx = idx if idx >= 0 and idx < player_mags.size() else -1
	if secondary_idx < 0:
		secondary_name = "NONE"
		return
	var mag: Dictionary = player_mags[secondary_idx]
	secondary_name = "%s %d/%d" % [str(mag["projectile"]).replace("_", " ")
			.to_upper(), int(mag["ammo"]), int(mag["max_ammo"])]

## icPlayerPilot::CyclePrimaryWeapon 0x100b0850 -- what Enter is really bound to
## (configs/default.ini [icPlayerPilot.NextPrimaryWeapon] = Keyboard, Return).
## The engine's is four lines and it has one behaviour we did not have:
##
##     if (m_primary(+0x84) != -1) {
##         old = m_current(+0x8c);  m_current = m_primary;
##         if (old != m_secondary(+0x88)) {          // NOT already on a missile
##             GetNextWeapon(channel 1, any=false);  // advance among primaries
##             m_primary = m_current;
##         }
##     }
##
## -- so when a SECONDARY is selected, Enter does not cycle anything: it just
## comes back to the primary you were last on. It only advances when you are
## already holding a primary.
##
## SOUND. The recovered fact is that the engine plays NOTHING here: icPlayerPilot
## contains no sound call of any kind (nothing in 0x100ad000..0x100b2000 touches
## FiSound/FcSoundStreamManager), and IHUDPlayAudioCue (0x100f5400), the only
## exported hook by which non-HUD code could raise a cue, has no callers. What we
## were playing -- audio/gui/mechanical_confirm -- is from the PAUSE MENU's family
## (icShadyBar::SetTargetWidth, 0x1010e6d0, plays audio/gui/expand + contract when
## a menu bar moves), which is why it sounded like clicking Resume. It is gone.
## The cues below are the engine's own HUD table (loaded at 0x100e8220 into
## 0x101740d8, played by FUN_100ea750): 0 valid_input, 1 invalid_input,
## 2 target_changed, 3 missile_warning, 4 klaxon, 5 ping. The HUD's own idiom is
## cue 0 on an accepted input and cue 1 on a refused one (FUN_100efaf0 sets
## exactly that pair from one flag) -- so we use those. That mapping is OURS; the
## original pilot is simply silent.
func _next_primary_weapon(warn := true) -> bool:
	if weapons.groups.is_empty():
		if warn:
			hud.warn("NO PRIMARY WEAPONS")
			audio.play("audio/hud/invalid_input.wav", -8.0)
		return false
	# holding a secondary? Enter drops straight back to the primary.
	if secondary_idx >= 0:
		_select_secondary(-1)
		weapon_name = weapons.group_label()
		hud.log_msg("WEAPON: %s" % weapon_name)
		audio.play("audio/hud/valid_input.wav", -10.0)
		return true
	if not weapons.cycle_group():
		# ONE primary: the engine's loop steps off the end, wraps to the entry it
		# started on, accepts it, and changes nothing. There is nothing to switch
		# to, so we say so instead of pretending we switched.
		if warn:
			audio.play("audio/hud/invalid_input.wav", -8.0)
		return false
	weapon_name = weapons.group_label()
	hud.log_msg("WEAPON: %s" % weapon_name)
	audio.play("audio/hud/valid_input.wav", -10.0)
	return true

func _cycle_secondary() -> void:
	# icPlayerPilot.NextSecondaryWeapon (Backspace / Joy3) steps the ring of
	# fitted magazines. Same cue rule as the primary above.
	if player_mags.is_empty():
		hud.warn("NO SECONDARY WEAPONS")
		audio.play("audio/hud/invalid_input.wav", -8.0)
		return
	if player_mags.size() == 1 and secondary_idx == 0:
		audio.play("audio/hud/invalid_input.wav", -8.0)
		return
	_select_secondary((secondary_idx + 1) % player_mags.size())
	audio.play("audio/hud/valid_input.wav", -10.0)
	hud.log_msg("WEAPON: %s" % secondary_name)

func _fire_secondary() -> void:
	if secondary_idx < 0 or secondary_idx >= player_mags.size():
		return
	# iiWeapon::IsReadyToFire 0x1003cb80: the disrupted flag blocks fire.
	# Shields-only disruption (full_disruption=0, e.g. achillies) only takes
	# the LDA subsims, not the weapons.
	if weapon_disrupt_time > 0.0 and weapon_disrupt_full:
		return
	var mag: Dictionary = player_mags[secondary_idx]
	# the ship-wide overheat flag 0x200 (iiWeapon::Simulate 0x1003cc00)
	if sys != null and sys.heat + sys.heat_external \
			>= ShipSystems.HEAT_DAMAGE_THRESHOLD:
		return
	if missiles.fire_magazine(ship, mag, target_ai):
		_select_secondary(secondary_idx)  # refresh the ammo readout

func fire_ldsi() -> void:
	# LDSIQuickFire: the first LDSi magazine with ammo fires at the target,
	# regardless of the current weapon selection
	if weapon_disrupt_time > 0.0 and weapon_disrupt_full:
		return
	if fire_lock > 0.0:
		# iship.LockDownWeapons locks the quick-fire too, not just the trigger
		return
	for mag in player_mags:
		if bool(mag["ldsi"]):
			if missiles.fire_magazine(ship, mag, target_ai):
				hud.log_msg("LDSI MISSILE AWAY")
			else:
				audio.play("audio/hud/invalid_input.wav", -8.0)
			return
	hud.warn("NO LDSI MISSILES")
	audio.play("audio/hud/invalid_input.wav", -8.0)

# --- the view zoom is GATED ON HARDWARE (task #62) -----------------------------
# @element zoom
# `icPlayerPilot::EnableZoom` (0x100b0e80) is the whole gate, and it grants the
# zoom two ways:
#
#     cpu = ship->m_cpu (+0x29c)
#     if      (cpu == NULL)                 reason = E_NoCPU        (0x42)
#     else if (!(cpu->programs & 0x2000))   reason = E_NoZoomProgram(0x28)
#     else if (!cpu->IsWorking())           reason = E_CPUOffline   (0x41)
#     else                                  GRANTED
#     if (!granted) granted = GotSniperWeapon(&reason)
#     if (granted) { reason = E_ZoomEnabled (0x26); m_zoom_target = max_zoom_factor }
#     if (reason < 0x69) icLog::LogEvent(reason)
#
# 0x2000 = 8192 = the imaging_module program bit. So: a WORKING CPU carrying the
# imaging module, OR a sniper weapon -- and the user's hunch was right, it is ship
# hardware, both ways.
#
# `GotSniperWeapon` (0x100b14d0) is the second door: the CURRENTLY SELECTED weapon
# must be a working gun with `sniper_zoom` set (iiGun::SniperZoom, 0x1000f0b0,
# gun+0xc5), and if the selection is an icWeaponLink it walks the link's members
# and takes ANY working sniper gun in it. A sniper gun that is present but dead
# reports E_WeaponDamaged (0x1e). Only one weapon in the game sets the flag:
# subsims/systems/player/long_range_pbc.ini, the long-range 'Sniper' PBC.
#
# The event ids are icLog's (table at 0x10167558, stride 0x10, built at
# 0x100a89a0); the refusal TEXT is the game's own, from data/text/log_addendum.csv.
# THE CONSEQUENCE, stated plainly: the stock tug carries NEITHER. Its CPU has
# `programs = 0` (tug_prefitted.ini fits no icProgram at all) and none of its
# seven weapons sets `sniper_zoom`, so the recovered gate REFUSES the zoom
# outright -- and that is exactly what the original does to a fresh campaign
# pilot. icLoadout::LoadComputerPrograms (0x10095ea0) only fits a program the
# player already OWNS as cargo, and the campaign gives away just two of them
# (stealth, and the hyperspace tracker), never the imaging module. You BUY the
# zoom in IW2, either as `Cargo_ImagingModule` or as the long-range 'Sniper' PBC.
#
# The difference is that the original has a cargo/fitting screen and we have not
# ported one, so there is currently no way to earn either. Flip this to true to
# hand the player's CPU an imaging module at fit time. It is a LOADOUT decision,
# not a mechanic -- the gate above stays exactly as recovered either way -- and
# it is the only invented byte in this file.
const GRANT_IMAGING_MODULE := false

const ZOOM_NO_CPU := "ERROR: NO COMPUTER FITTED"          # E_NoCPU 0x42
const ZOOM_NO_PROGRAM := "ERROR: IMAGING MODULE NOT INSTALLED"  # E_NoZoomProgram 0x28
const ZOOM_CPU_OFFLINE := "ERROR: COMPUTER OFFLINE"       # E_CPUOffline 0x41
const ZOOM_WEAPON_DAMAGED := "WEAPON DAMAGED"             # E_WeaponDamaged 0x1e
const ZOOM_ENABLED := "IMAGING MODULE ACTIVATED"          # E_ZoomEnabled 0x26
const ZOOM_DISABLED := "IMAGING MODULE DEACTIVATED"       # E_ZoomDisabled 0x27

## icPlayerPilot::GotSniperWeapon 0x100b14d0, as a tri-state:
##   0 = the selection carries no sniper gun at all
##   1 = a WORKING sniper gun is selected (the zoom is granted)
##   2 = a sniper gun is selected but it is dead (reason -> E_WeaponDamaged)
func _sniper_state() -> int:
	if sys == null or weapons == null:
		return 0
	var g: Dictionary = weapons.current_group()
	if g.is_empty():
		return 0
	var damaged := 0
	for m: Dictionary in (g["members"] as Array):
		if not bool(m.get("sniper_zoom", false)):
			continue
		# iiShipSystem::IsWorking (vtable slot 13) -- the vf 0x34 that both
		# EnableZoom and GotSniperWeapon call on the gun.
		if not bool(m["destroyed"]) and float(m["efficiency"]) > 0.0:
			return 1           # ANY working sniper gun in the link is enough
		damaged = 2
	return damaged

## The refusal reason, or "" when the zoom may engage. Same order as EnableZoom:
## the CPU path is tested first, GotSniperWeapon second, and a broken sniper gun
## overwrites whatever the CPU path had to say (its out-param, 0x100b1653).
func _zoom_allowed() -> String:
	if sys == null:
		return ""              # no fitted hull (the bare demo ship): don't gate
	var sniper := _sniper_state()
	if sniper == 1:
		return ""
	var reason := ""
	if not sys.has_cpu():
		reason = ZOOM_NO_CPU
	elif not sys.has_program(ShipSystems.PROG_IMAGING):
		reason = ZOOM_NO_PROGRAM
	elif not sys.cpu_working():
		reason = ZOOM_CPU_OFFLINE
	else:
		return ""              # a working CPU carrying the imaging module
	if sniper == 2:
		reason = ZOOM_WEAPON_DAMAGED
	return reason

## icPlayerPilot::EnableZoom 0x100b0e80.
func _enable_zoom(on: bool) -> void:
	if on == zoomed:
		return                 # `if (param_1 == (1.0 < zoom_factor)) return;`
	if not on:
		# 0x100b0f20: the disable path snaps target AND factor to 1.0 -- there is
		# no ramp out.
		zoomed = false
		zoom_factor = 1.0
		hud.log_msg(ZOOM_DISABLED)
		return
	var reason := _zoom_allowed()
	if not reason.is_empty():
		hud.warn(reason, 3.0)
		audio.play("audio/hud/invalid_input.wav", -8.0)
		return
	zoomed = true
	hud.log_msg(ZOOM_ENABLED)
