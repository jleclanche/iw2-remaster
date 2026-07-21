# Main layer: player damage, the LDS drive, towing and docking.
# Part of main.gd's extends chain -- see
# main_state.gd for the scheme. Same node, same class.
extends "main_camera.gd"

func damage_player(dmg: float, why: String) -> void:
	# iiSim::ApplyDamage: the raw hull path -- collisions and script damage do
	# not go through armour and do not spall into the subsims
	if sys != null:
		sys.apply_damage(dmg)
	else:
		hull = maxf(hull - dmg, 0.0)
	hud.warn("%s  HULL %d%%" % [why, int(100.0 * hull / hull_max)])
	if hull <= 0.0:
		_kill_player()

func hit_player(spec: Dictionary, age: float, at: Vector3) -> Dictionary:
	# icBullet::OnCollision -> icShip::ApplyWeaponDamage, on the player's hull
	var dmg: float = float(spec.get("damage", 160.0)) \
			/ ShipSystems.age_factor(age, float(spec.get("half_time", 0.35)))
	var pen: float = float(spec.get("penetration", 50.0))
	var out := {"applied": dmg, "deflected": false, "hit": "", "killed": false}
	if sys == null:
		damage_player(dmg, "HULL HIT")
		return out
	var inv := ship.global_transform.affine_inverse()
	var dir := (inv.basis * (at - ship.global_position)).normalized()
	var src: int = ShipSystems.SRC_BYPASS if bool(spec.get("bypass_shields", false)) \
			else ShipSystems.SRC_WEAPON
	out = sys.apply_weapon_damage(dmg, pen, inv * at, dir, src)
	if out["deflected"]:
		hud.warn("SHIELD DEFLECT")
		return out
	var what: String = str(out["hit"])
	if what.is_empty():
		hud.warn("HULL HIT  HULL %d%%" % int(100.0 * hull / hull_max))
	else:
		hud.warn("HULL HIT  %s  HULL %d%%"
				% [_system_label(what), int(100.0 * hull / hull_max)])
	if out["killed"]:
		_kill_player()
	return out

func hit_player_warhead(dmg: float, pen: float, at: Vector3) -> Dictionary:
	# the contact-warhead path (icRocket::OnCollision 0x1006ff50):
	# ApplyWeaponDamage with source 2 -- armour and criticals, but the LDA
	# scan only runs for source 0 (icShip::ApplyWeaponDamage 0x10073e2e),
	# so no deflection
	var out := {"applied": dmg, "deflected": false, "hit": "", "killed": false}
	if sys == null:
		damage_player(dmg, "MISSILE HIT")
		return out
	var inv := ship.global_transform.affine_inverse()
	var dir := (inv.basis * (at - ship.global_position)).normalized()
	out = sys.apply_weapon_damage(dmg, pen, inv * at, dir, 2)
	hud.warn("MISSILE HIT  HULL %d%%" % int(100.0 * hull / hull_max))
	if out["killed"]:
		_kill_player()
	return out

func disrupt_player_systems(seconds: float, full: bool) -> void:
	# icShip::Disrupt via icMissile::CheckForDisruption 0x1006d0b0: the
	# weapons lock out here, and ship_systems raises the subsim disrupted
	# flag (efficiency reads zero, the LDA stops deflecting and recharging).
	weapon_disrupt_time = maxf(weapon_disrupt_time, seconds)
	weapon_disrupt_full = weapon_disrupt_full or full
	if sys != null:
		sys.disrupt(seconds, full)
	hud.warn("SYSTEMS DISRUPTED" if full else "SHIELDS DISRUPTED", 3.0)
	audio.play("audio/sfx/disruptor_startup.wav", -6.0)
	# the ARCS: icShip::Disrupt (0x100751b0) attaches ini:/sfx/disruptor/node
	# scaled max(1, radius/25), emitter life = the disruption seconds
	# (SetTime @ 0x100c4150); re-disruption re-times the attached node
	if is_instance_valid(player_disrupt_fx):
		player_disrupt_fx.sys["time"] = \
				player_disrupt_fx._age + weapon_disrupt_time
	elif ship_model != null:
		var r := float(ship_stats.get("radius", 60.0))
		player_disrupt_fx = ParticleFx.spawn_on_model(ship,
				ProjectSettings.globalize_path("res://").path_join(".."),
				"disruptor", ship_model, r, maxf(1.0, r / 25.0))
		if player_disrupt_fx != null:
			player_disrupt_fx.sys = player_disrupt_fx.sys.duplicate()
			player_disrupt_fx.sys["time"] = weapon_disrupt_time

func _kill_player() -> void:
	# The respawn-in-place flow can't ride out the 30 s dramatic sequence, so
	# the player death goes straight to DoFinalExplosion at the ship's real
	# radius (the timed crawl is an AI/asteroid-only spectacle for now).
	DeathSequence.final_explosion(self, ship.global_transform.basis,
			ship.global_position, float(ship_stats.get("radius", 60.0)),
			ship.velocity)
	hud.warn("SHIP DESTROYED - resetting", 5.0)
	if sys != null:
		for s in sys.systems:
			s["hp"] = s["hp_max"]
	hull = hull_max
	ship.velocity = Vector3.ZERO
	ship.set_speed = 0.0

func disrupt(seconds: float) -> void:
	# iship.DisruptLDSDrive: an LDSi hit locks the drive out for a while
	disrupt_time = maxf(disrupt_time, seconds)
	if lds_state != 0:
		lds_state = 0
		audio.lds_player.stop()
		audio.play("audio/sfx/lds_rampdown.wav", -4.0)
	audio.play("audio/sfx/ldsi_engage.wav", -4.0)
	hud.warn("LDS DRIVE DISRUPTED", 3.0)

func _toggle_lds() -> void:
	if docked_at != "" or jump_state != 0:
		return
	if disrupt_time > 0.0:
		hud.warn("LDS DRIVE DISRUPTED")
		audio.play("audio/hud/invalid_input.wav", -8.0)
		return
	if lds_state != 0:
		_drop_out_of_lds()
	elif _lds_clearance() > 0.0:
		lds_state = 1
		lds_timer = 0.0
		lds_speed = LDS_BASE
		audio.play("audio/sfx/lds_rampup.wav", -4.0)
	else:
		hud.warn("LDS INHIBITED")
		audio.play("audio/hud/invalid_input.wav", -8.0)

func _lds_process(delta: float) -> void:
	# The TRI's DRIVE axis reaches the LDS drive too (icLDSDrive is eType 0), and
	# icLDSDrive::Simulate (0x10037040) spends it in BOTH halves:
	#   spin-up  0x10037224:  still spooling while `elapsed <= spinup_time / w`
	#                         -- the spool time is DIVIDED by the weight
	#   ramp     0x1003746e:  `speed = (w * rate * dt + 1) * speed` -- an
	#                         exponential whose rate is MULTIPLIED by the weight
	# so full drive gets you into LDS in 2/3 the time and accelerates 1.5x harder.
	var wd := 1.0
	if sys != null:
		wd = sys.tri_weight(ShipSystems.TRI_DRIVE)
	if lds_state == 1:
		lds_timer += delta
		if lds_timer >= LDS_SPOOL / maxf(wd, 1e-3):
			lds_state = 2
			audio.play_loop(audio.lds_player, "audio/sfx/lds_cruise.wav", -10.0)
		return
	# our ramp is pow(base, dt); the original's is exp(w * rate * dt), so the
	# weight belongs in the exponent
	lds_speed = minf(lds_speed * pow(LDS_RAMP, delta * wd), LDS_MAX)
	var clear := _lds_clearance()     # LDS inhibition (icLDSIRegion), region-based
	var tdist := _target_distance()
	# brake as we close on the destination -- icLDSDrive::Simulate case 2
	# (0x10037040) caps the cruise speed at the pilot target's break-off
	# (this+0x90 = target_marker x max_speed @ 0x10037596), so the drive settles
	# onto its destination rather than overshooting it
	if tdist < lds_speed * 1.5 and tdist < INF:
		lds_speed = maxf(tdist * 1.5, LDS_BASE)
	lds_speed = minf(lds_speed, LDS_MAX)
	ship.velocity = -ship.global_transform.basis.z * lds_speed
	# drop out ONLY on inhibition or arrival. icLDSDrive::Simulate breaks the
	# ship out at 0x100376xx solely when the inhibit counter iiThrusterSim+0x251
	# is non-zero (docs/lds.md) -- there is NO mass gate in the drive. Flying
	# near/into a mass is handled by AI route-around (autopilot) or the player
	# (manual), never by a drive dropout; a mass dropout here wedged manual
	# re-engage near a star into a spool/break loop (#56).
	if clear < 0.0 or (tdist < 4.0e4 and lds_speed <= LDS_BASE * 2.0):
		_drop_out_of_lds()

func _drop_out_of_lds() -> void:
	# icLDSDrive::BreakShipOutOfLDS (decompiled): zero the angular
	# velocity and set linear velocity to facing x 1000 m/s flat
	lds_state = 0
	audio.lds_player.stop()
	audio.play("audio/sfx/lds_rampdown.wav", -4.0)
	ship.velocity = -ship.global_transform.basis.z * LDS_DROPOUT_SPEED
	ship.angular_velocity = Vector3.ZERO
	ship.input_rotate = Vector3.ZERO
	# auto-deceleration (original option, default on): the flight computer
	# zeroes the throttle wheel so the ship brakes instead of barreling on
	ship.set_speed = 0.0

# --- towing ------------------------------------------------------------------
# icDockPort::OnDock (0x1002e540): docking rigidly attaches the LOWER
# docking_priority sim as a CHILD of the higher (both +0x1c0, compared at
# 43203). FiSim::OnAttachChild adds the child's mass and inertia to the
# parent (AddMass walks the parent chain), FiSim::UpdateChild rewrites the
# child's transform from the parent every tick, and Integrate divides the
# thruster force by the combined mass -- so a docked pod is towed, and how
# well depends on your hull's mass (= w*h*l*0.001, iiThrusterSim::Load)
# against the pod's. The tug (672) barely feels a pod (125); the command
# section (4.2) can hardly budge one. Port-null mating is not modelled: the
# partner keeps its capture-moment offset. The torque side is the real
# tensor sum: FiSim::AddMomentOfInertia (flux @ 0x100c06b0) adds the child's
# tensor UNROTATED plus a parallel-axis term (|r|^2 - r_i r_j) built from
# the RAW attach offset with NO mass factor (OnAttachChild @ 0x100c0270
# passes +0x168, the same plain-metres vector UpdateChild rides) -- so the
# offset term is negligible against the box tensors, and a docked stack
# turns with I_parent + I_child to first order.
var towed: AiShip = null
var towed_rel := Transform3D()
var towed_prev_behavior := "patrol"

func _try_tow_dock() -> bool:
	var prio := int(ship_stats.get("docking_priority", 85))
	var best: AiShip = null
	var best_d := DOCK_RANGE
	for a in ai_ships:
		var ai := a as AiShip
		if ai == null or ai.dying or ai.behavior == "towed":
			continue
		# icDockPort::TryToDock also gates on approach kinematics; its capture
		# constants (_DAT_10119468 alignment/distance thresholds) were not
		# resolved to values -- 20 m/s relative is eyeballed
		if (ai.velocity - ship.velocity).length() > 20.0:
			continue
		var d: float = ship.global_position.distance_to(ai.global_position) \
				- ai.radius
		if d < best_d:
			best = ai
			best_d = d
	if best == null:
		return false
	if best.docking_priority >= prio:
		# the higher-priority sim is the parent: docking to it anchors US.
		# Our station dock (velocity zeroed) already models that; a
		# higher-priority ship berth is not supported here.
		return false
	towed = best
	towed_prev_behavior = best.behavior
	best.behavior = "towed"
	towed_rel = ship.global_transform.affine_inverse() * best.global_transform
	ship.tow_mass = best.mass
	# the tensor sum (see the header comment): child box tensor + the
	# unit-mass parallel-axis diagonal of the attach offset
	var r := towed_rel.origin
	var pa := Vector3(r.length_squared() - r.x * r.x,
			r.length_squared() - r.y * r.y,
			r.length_squared() - r.z * r.z)
	var comb := ship.moi + best.moi + pa
	ship.tow_torque_scale = Vector3(
			ship.moi.x / maxf(comb.x, 1e-6),
			ship.moi.y / maxf(comb.y, 1e-6),
			ship.moi.z / maxf(comb.z, 1e-6))
	audio.play("audio/sfx/dock.wav", -4.0)
	hud.log_msg("DOCKED: %s  (MASS %d + %d)"
			% [str(best.display_name).to_upper(), int(ship.mass), int(best.mass)])
	return true

func _update_tow() -> void:
	if towed == null:
		return
	if not is_instance_valid(towed) or towed.dying:
		_release_tow(false)
		return
	# FiSim::UpdateChild: the child rides the parent's frame rigidly
	towed.global_transform = ship.global_transform * towed_rel
	towed.velocity = ship.velocity

func _release_tow(nudge: bool) -> void:
	if towed != null and is_instance_valid(towed):
		towed.behavior = towed_prev_behavior
		towed.velocity = ship.velocity
		if nudge:
			hud.log_msg("UNDOCKED: %s" % str(towed.display_name).to_upper())
	towed = null
	ship.tow_mass = 0.0
	ship.tow_torque_scale = Vector3.ONE

func _try_dock() -> void:
	var near := _nearest("station")
	if near.get("dist", INF) > DOCK_RANGE:
		# no station berth: a lower-priority sim (a cargo pod) in reach
		# becomes our docked child instead -- the tow
		if _try_tow_dock():
			return
		hud.warn("NO DOCKPORT IN RANGE")
		audio.play("audio/hud/invalid_input.wav", -8.0)
		return
	# Lucrecia's Base is not an ordinary dock. It has no dockport of its own that
	# the player can use -- iBackToBase.Detector bolts a "bodge dockport" onto
	# the PLAYER's ship inside 200 km so that a dock order is even possible --
	# and the dock itself is a cutscene that ends inside the base. The whole
	# procedure is base_interior.gd; here we only hand it over.
	# (iStartSystem's own dock watcher, local_207, is NOT gated on the found-base
	# flag: it raises the interior whenever the player is docked to the base, by
	# any route. Only the cutscene and the autoskip are iBackToBase's.)
	if base_iface != null and str(near["name"]) == BaseInterior.BASE_NAME \
			and base_iface.dockable():
		_set_autopilot(0)
		_deliver_towed_pod()
		# NOT an instant entry: every route into the base runs the
		# DockingCutscene fly-in first (Escape skips to the end of it), then
		# the shutdown movie, then the interior
		base_iface.begin_dock()
		return
	docked_at = near["name"]
	ship.velocity = Vector3.ZERO
	ship.set_speed = 0.0
	audio.play("audio/sfx/dock.wav", -4.0)
	if not music_monitor_active():
		# station docks stay in space mode -- the monitor keeps the score;
		# only debug sessions without it fall back to a static mood
		audio.music("ambient")
	hud.log_msg("DOCKED: %s" % str(near["name"]).to_upper())
	# only THE base raises the hangar interior (the old substring test also
	# matched every "...Base" station in the map)
	if docked_at == BaseInterior.BASE_NAME:
		_deliver_towed_pod()
		_enter_base()

## Docking at LUCRECIA'S BASE with a pod in tow unloads it into the player's
## stockpile -- the same iinventory.Add + read of the pod's "cargo" property
## that iJafsScript.CollectPods performs when the Jafs unloads there. Only the
## base: hauling a pod to some corporate station credits you nothing (their
## clamps are not your loading dock), and the tow simply stays attached.
func _deliver_towed_pod() -> void:
	if towed == null or not is_instance_valid(towed) or pog_world == null:
		return
	var pod := towed
	_release_tow(false)
	var s = pog_world._wrap_ship(pod)
	var cargo := int(pog_std._bag(s).get("cargo", 0))
	if cargo != 0 and pog_econ != null:
		pog_econ.player_inv().add(cargo, 1)
		var label := "CARGO"
		var c = pog_econ.cargo_types.get(cargo)
		if c != null:
			label = str(pog_econ._text(c.name))
		hud.log_msg("CARGO UNLOADED: %s" % label.to_upper())
	# the pod itself stays with the station
	s.dead = true
	pog_world.sims.erase(s.name)
	ai_ships.erase(pod)
	pod.queue_free()

func _enter_base() -> void:
	# the original's drydock hangar interior (avatars/base), placed so the
	# tug parking bay wraps around the docked ship; channel switches pick
	# the normal light bank and the tug bay dressing
	if base_root != null:
		return
	base_root = _load_gltf("data/avatars/avatars/base/setup.gltf")
	if base_root == null:
		return
	add_child(base_root)
	base_root.position = -BASE_BAY
	var lights := 0
	for n in base_root.find_children("*", "Node3D", true, false):
		if not n.has_meta("extras"):
			continue
		var ex: Dictionary = n.get_meta("extras")
		match str(ex.get("iw2_kind", "")):
			"switch":
				n.visible = str(ex.get("iw2_channel", "")) in [
					"baselights_normal", "tug"]
			"light":
				if lights >= 48 or not (n as Node3D).is_visible_in_tree():
					continue
				var col := Color(1, 1, 1)
				if ex.has("iw2_color"):
					var c: Array = ex["iw2_color"]
					col = Color(c[0] / 255.0, c[1] / 255.0, c[2] / 255.0)
				var l := OmniLight3D.new()
				l.light_color = col
				l.light_energy = 1.1
				l.omni_range = 170.0
				n.add_child(l)
				lights += 1
	if ship_model != null:
		ship_model.visible = true

func _leave_base() -> void:
	if base_root != null:
		base_root.queue_free()
		base_root = null
	_apply_view()

func _undock() -> void:
	if towed != null:
		# iiSim::Undock: the lower-priority half frees the mate; our child
		# is released with the pair's current velocity
		audio.play("audio/sfx/undock.wav", -4.0)
		_release_tow(true)
		return
	if docked_at == "":
		return
	if base_iface != null and base_iface.inside:
		# iStartSystem's launch cutscene: the startup movie, then out of the tube
		docked_at = ""
		audio.play("audio/sfx/undock.wav", -4.0)
		base_iface.leave()
		return
	docked_at = ""
	_leave_base()
	audio.play("audio/sfx/undock.wav", -4.0)
	ship.velocity = -ship.global_transform.basis.z * 50.0
	clock_start = Time.get_ticks_msec()
	hud.log_msg("UNDOCKED")

## Point the ship's nose at a direction in folded world space, instantly. The
## cutscenes do this with sim.PointAt / sim.PointAway, which snap the sim's
## orientation rather than flying it round.
func _point_ship_at(dir: Vector3) -> void:
	if dir.length_squared() < 1.0e-6:
		return
	var up := Vector3.UP
	if absf(dir.normalized().dot(up)) > 0.999:
		up = Vector3.RIGHT
	ship.global_transform = Transform3D(Basis.IDENTITY,
		ship.global_position).looking_at(ship.global_position + dir, up)
