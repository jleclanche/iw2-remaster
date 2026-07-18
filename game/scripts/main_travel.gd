# Main layer: the capsule jump machine and the autopilot. Part of main.gd's extends chain -- see
# main_state.gd for the scheme. Same node, same class.
extends "main_combat.gd"

# --- capsule jump ----------------------------------------------------------

func _jump_lpoint() -> Dictionary:
	var lp := _nearest("lpoint", JUMP_RANGE)
	return {} if lp.get("dist", INF) == INF else lp

func routes_text() -> String:
	var lp := _jump_lpoint()
	if lp.is_empty():
		return ""
	var jumps: Array = lp["jumps"]
	if jumps.is_empty():
		return "L-POINT: NO CHARTED ROUTES"
	var parts: PackedStringArray = []
	for i in jumps.size():
		var stem: String = jumps[i]
		parts.append(("[%s]" if i == jump_sel % jumps.size() else "%s")
			% stem.replace("_", " ").to_upper())
	return "CAPSULE ROUTES: " + "  ".join(parts) + "  (J jump, K cycle)"

func _cycle_route() -> void:
	var lp := _jump_lpoint()
	if lp.is_empty() or lp["jumps"].is_empty():
		return
	jump_sel = (jump_sel + 1) % lp["jumps"].size()
	audio.play("audio/hud/target_changed.wav", -10.0)

func _try_jump() -> void:
	if docked_at != "" or jump_state != 0 or lds_state != 0:
		return
	var lp := _jump_lpoint()
	if lp.is_empty():
		hud.warn("NO L-POINT IN RANGE")
		audio.play("audio/hud/invalid_input.wav", -8.0)
		return
	var jumps: Array = lp["jumps"]
	if jumps.is_empty():
		hud.warn("NO CHARTED CAPSULE ROUTES")
		audio.play("audio/hud/invalid_input.wav", -8.0)
		return
	jump_dest = jumps[jump_sel % jumps.size()]
	jump_state = 1
	jump_timer = 0.0
	hud.warn("CAPSULE DRIVE CHARGING", 3.0)
	audio.play("audio/sfx/capsule_jump.wav", -4.0)

func _jump_process(delta: float) -> void:
	jump_timer += delta
	match jump_state:
		1:  # spool -- the drive charging in the queue (icAITarget stage 3,
			# GetNewCapsuleJumpStage @ 0x1005c5af waits on icCapsuleDrive)
			if jump_timer >= 3.0:
				jump_state = 2
				jump_timer = 0.0
				hud.warn("ACCELERATION RUN", 2.0)
		2:  # acceleration run -- iAI.IsCapsuleJumpAccelerating (stage 4
			# flies at AverageJumpSpeed = (100+2500)/2 @ 0x1000b000;
			# TryToJump @ 0x1006ad40 gates entry on axis speed 100..2500,
			# statics 0x1015d224/0x1015d228)
			ship.velocity += -ship.global_transform.basis.z * 2500.0 * delta
			if jump_timer >= 3.0:
				# icCapsuleSpace::FullEffect @ 0x10042ea0: attach the effect
				# node and start the entry blank (icCapsuleEntryBlankAvatar
				# state 1 @ 0x100c0170: sound_url + force feedback + flash)
				jump_state = 3
				jump_timer = 0.0
				_flash_roll()
				audio.play("audio/sfx/capsule_jump.wav", -4.0)  # capsule_entry.ini
				hud.visible = false  # the director goes cinematic (Cue 0xf)
		3:  # entry blank: white-out held 1.5 s for the player
			# (_DAT_1011a268, FUN_100bf870), flickering at the effect-node
			# channel envelope (FUN_100bef90: keys 0.1 apart, rand[0.7,1])
			jump_fade.color.a = clampf(jump_timer * 4.0, 0.0, 1.0) \
				* _flash_flicker(jump_timer / CAPSULE_FLASH)
			if jump_timer >= CAPSULE_FLASH:
				_capsule_enter()
		4:  # capsule space (PerformJumps case 5): fly the tunnel out
			jump_fade.color.a = maxf(0.0, jump_fade.color.a - delta * 2.0)
			if jump_timer >= jump_duration:
				_capsule_exit()
		5:  # exit blank (case 6): the teleport already happened under full
			# white; the flash recedes as the ship flies off the L-point
			# (FUN_100beea0's proximity falloff), then camera + HUD restore
			# (case 7: icDirector::ChangeMode(0))
			jump_fade.color.a = clampf(1.0 - jump_timer / CAPSULE_FLASH,
				0.0, 1.0) * _flash_flicker(jump_timer / CAPSULE_FLASH)
			if jump_timer >= CAPSULE_FLASH:
				jump_state = 0
				jump_fade.color.a = 0.0
				hud.visible = true
				cam.fov = FOV_INTERNAL if cam_mode == 0 and cam_view <= 1 \
					else FOV_EXTERNAL
				hud.warn("ARRIVED: %s" % system_name.to_upper(), 4.0)

## Roll the blank-avatar flicker envelope: keys every tenth of the flash,
## values rand[0.7, 1.0] (FUN_100bef90 @ 0x100bef90; the 0.7 floor is
## _DAT_101191e8, the key spacing 0.1 is _DAT_101184b0).
func _flash_roll() -> void:
	_flick.resize(11)
	for i in 11:
		_flick[i] = randf_range(0.7, 1.0)

func _flash_flicker(t: float) -> float:
	var x := clampf(t, 0.0, 1.0) * 10.0
	var i := int(floor(x))
	return lerpf(_flick[i], _flick[mini(i + 1, 10)], x - i)

## Swap the world for capsule space. PerformJumps @ 0x10040cc0 case 4 -> 5:
## the ship is moved into icCluster's icCapsuleSpaceSystem (+0x2c) by
## SendShipDownTunnel @ 0x10043740 (velocity (0,0,500), identity orientation,
## so the tunnel axis is the ship's forward), the tunnel loop sound starts
## (blank avatar state 2: sound_tunnel_url), and the countdown is rolled at
## rand[8, 12] s (constants 0x10117b28 / 0x10119ec4).
func _capsule_enter() -> void:
	jump_state = 4
	jump_timer = 0.0
	jump_duration = randf_range(CAPSULE_TIME_MIN, CAPSULE_TIME_MAX)
	var fwd := -ship.global_transform.basis.z
	ship.velocity = fwd * CAPSULE_SHIP_SPEED
	ship.set_speed = CAPSULE_SHIP_SPEED
	capsule.enter(cam, ship.global_transform.basis)
	# capsule space is its own world: its scene graph holds only the tunnel
	# avatar and the cockpit (icCapsuleSpaceSystem::Render @ 0x100481e0) --
	# no sky, no sun, no system objects
	sun.visible = false
	if sky_anchor != null:
		sky_anchor.visible = false
	for o in objects:
		if o["node"] != null:
			o["node"].visible = false
	for a in ai_ships:
		a.visible = false
	_cap_prev_bg = env_ref.background_mode
	env_ref.background_mode = Environment.BG_COLOR
	env_ref.background_color = Color.BLACK
	audio.play_loop(audio.lds_player,
		"audio/sfx/inside_capsule_space.wav", -6.0)  # capsule_tunnel.ini
	_cap_cut_t = 0.0  # cut to a capsule-camera viewpoint immediately

func _capsule_world_restore() -> void:
	env_ref.background_mode = _cap_prev_bg
	sun.visible = true
	if sky_anchor != null:
		sky_anchor.visible = true
	for o in objects:
		if o["node"] != null:
			o["node"].visible = true
	for a in ai_ships:
		a.visible = true

## Leave capsule space: DoCapsuleJump @ 0x10042730. Teleport to the arrival
## L-point, take ITS orientation (FiSim::SetOrientation with the LP record's
## quaternion) and leave along its +Z jump axis at sqrt(2 * accel * 3000)
## (the player's accel scaled by 0.8^2, _DAT_1011959c), clamped to flux.ini
## [icCapsuleSpace] min/max_exit_speed 500..2000. The exit blank flash
## (case 6) covers the arrival.
func _capsule_exit() -> void:
	jump_state = 5
	jump_timer = 0.0
	_flash_roll()
	jump_fade.color.a = 1.0
	_apply_view()  # hand the cockpit/hull dressing back to the F-key camera
	audio.lds_player.stop()
	audio.play("audio/sfx/capsule_jump.wav", -4.0)  # exit blank sound_url
	capsule.exit()
	_capsule_world_restore()
	var from := system_stem
	_load_system(jump_dest, "", from)
	var b := ship.global_transform.basis
	if not last_entry.is_empty():
		b = _record_basis(last_entry)
		ship.global_transform.basis = b
	var v := sqrt(2.0 * ship.max_accel.z * CAPSULE_ACCEL_SCALE
		* CAPSULE_EXIT_RUN)
	if SHIP_HIT_RADIUS / maxf(v, 1.0) >= 2.5:  # big-hull cap @ 0x10042730
		v = SHIP_HIT_RADIUS / 2.5
	v = clampf(v, CAPSULE_EXIT_MIN, CAPSULE_EXIT_MAX)
	ship.velocity = (b * Vector3.FORWARD) * v
	ship.set_speed = minf(v, ship.max_speed.z)

## Abort the capsule sequence (a scripted system change mid-jump): put the
## world, HUD and fade back the way icCapsuleSpace::DetachEffect would.
func _jump_abort() -> void:
	if jump_state >= 3:
		capsule.exit()
		_capsule_world_restore()
		_apply_view()
		audio.lds_player.stop()
	jump_fade.color.a = 0.0
	hud.visible = true
	jump_state = 0

func _autopilot_process(delta: float) -> void:
	var p := _target_pos()
	if ap_mode == 3 and p == Vector3.INF:
		var near := _nearest("station")
		if near.get("dist", INF) < INF:
			for i in objects.size():
				if objects[i] == near:
					target_idx = i
					target_ai = null
			p = _target_pos()
	if p == Vector3.INF:
		_disengage_autopilot()   # the target went away under us
		return
	var dist := p.length()
	_face_target()
	# The player's autopilot IS the AI order system: icPlayerPilot::
	# EngageAutopilotApproach (0x100afbc0) calls icAIServices::DefaultApproach
	# and pushes an "AutopilotApproach" order onto the player's own icAIPilot.
	# So the break-off is the same marker sphere the AI flies to, and it is
	# derived from the TARGET -- a fighter breaks off at ~300 m, a station at a
	# kilometre or two, a planet thousands of kilometres out.
	var marker := _target_marker()
	# like the original: approach/dock autopilots engage LDS for long
	# transits once the nose is on target (LDS cruise already brakes and
	# drops out near the destination)
	if ap_mode in [1, 3] and lds_state == 0 and jump_state == 0 \
			and dist > 8.0e4 and _lds_clearance() > 1000.0 \
			and (-ship.global_transform.basis.z).angle_to(p.normalized()) < 0.05:
		_toggle_lds()
	match ap_mode:
		1:  # approach: fly to the marker sphere and stop on it
			var togo := dist - marker
			if lds_state == 0:
				ship.set_speed = clampf(togo / 8.0, 0.0, ship.max_speed.z)
			# the engine settles onto the sphere and completes within
			# min(marker*0.05, 0.5) m of it; we arrive rather than settle, so the
			# slop is floored at icAITarget::m_waypoint_approach_distance (20 m)
			if togo <= maxf(PogWorld.completion_tolerance(marker), 20.0):
				ship.set_speed = 0.0
				_set_autopilot(0)
				hud.log_msg("APPROACH COMPLETE")
		2:  # formate: hold station on the marker sphere, matching velocity
			var tvel := Vector3.ZERO
			if target_ai != null and is_instance_valid(target_ai):
				tvel = target_ai.velocity
			# DefaultFormate (0x10056520) uses the same InnerMarkerRadius
			var hold := clampf((dist - marker) * 0.5, 0.0, ship.max_speed.z)
			ship.set_speed = clampf(tvel.length() + hold, 0.0, ship.max_speed.z)
		3:  # dock: approach then hard-dock
			if lds_state == 0:
				# aim INSIDE the dock gate, not at the approach marker: for big
				# stations the marker sphere lies OUTSIDE DOCK_RANGE, so braking
				# onto it parked the ship just out of reach with the autopilot
				# still engaged -- the reported "autopilot stuck still" freeze.
				# icAIDockAgent flies the port corridor all the way in; we bore
				# in to half the gate range and let the dock take us.
				ship.set_speed = clampf((dist - DOCK_RANGE * 0.5) / 6.0,
						0.0, ship.max_speed.z)
			_ap_dock_retry -= delta
			# Lucrecia's Base: the dock detector hands over OUTSIDE the hull
			# (its cutscene teleports to the bay-axis staging point at
			# base-local 2900, ibacktobase.pog:502). Boring on to DOCK_RANGE
			# reached the trigger point only after grinding through the hull
			# trimesh -- the "F8 flies me through the base" report.
			var gate := DOCK_RANGE * 0.8
			if target_idx >= 0 and target_idx < objects.size() \
					and str(objects[target_idx]["name"]) == BaseInterior.BASE_NAME:
				gate = 6000.0
			if dist < gate and _ap_dock_retry <= 0.0:
				_ap_dock_retry = 1.0
				_try_dock()
				if docked_at != "" or towed != null \
						or (base_iface != null and base_iface.inside):
					_set_autopilot(0)
		4:  # match velocity
			var tv := Vector3.ZERO
			if target_ai != null and is_instance_valid(target_ai):
				tv = target_ai.velocity
			ship.set_speed = clampf(tv.length(), 0.0, ship.max_speed.z)
			if tv.length() < 1.0:
				ship.set_speed = 0.0
