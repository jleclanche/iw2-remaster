# Main layer: the icDirector camera rig (F1-F4, chase, capsule).
# Part of main.gd's extends chain -- see
# main_state.gd for the scheme. Same node, same class.
extends "main_targeting.gd"

func cam_name() -> String:
	return CAM_GROUPS[cam_mode][cam_view]

func _apply_view() -> void:
	# only the cockpit view carries the cockpit dressing; every camera that is
	# not inside the ship shows the hull
	cockpit_frame = cam_mode == 0 and cam_view == 0
	if cockpit != null:
		cockpit.visible = cockpit_frame
	if ship_model != null:
		ship_model.visible = not (cam_mode == 0 and cam_view <= 1)

## icDirector::OnMessage's camera-key rule (0x100d6920): outside the group, jump
## to its first camera; inside it, step to the next one, wrapping. The step is
## handed to icDirector::ChangeCamera (0x100d7350), which has a special same-id
## branch at 0x100d7358: re-selecting the camera you are already on is a no-op for
## every camera EXCEPT the drop camera (id 0xb) -- for that one it re-commits and
## raises CameraChanged=2 (0x100d739c), so the drop camera re-establishes its
## default framing. In our groups only the drop group has a single member, so it
## is the only key whose repeat press lands back on itself: that repeat RE-DROPS
## the camera at the ship's current default vantage instead of doing nothing. The
## multi-member groups (F1/F2/F3) always step to a different camera, so each of
## their presses is already a real change.
func _set_camera(group: int) -> void:
	var reselect := group == cam_mode
	if reselect:
		cam_view = (cam_view + 1) % CAM_GROUPS[group].size()
	else:
		cam_mode = group
		cam_view = 0
	if cam_name() == "drop":
		# first entry drops the camera where the previous view was; a repeat F4
		# (reselect, single-member group) is the ChangeCamera 0xb reset -- re-drop
		# behind the ship at the default drop-back vantage
		if reselect:
			drop_cam_pos = ship.global_position \
				+ ship.global_transform.basis * Vector3(0, 20, 130)
		else:
			drop_cam_pos = cam.global_position
	zoomed = false
	zoom_factor = 1.0
	# icDirector::ChangeCamera commits the new camera through its Reset
	# (icChaseCamera's @ 0x100d4bf0): the follow state re-seeds, no carry-over
	chase_snap = true
	_ffb_reset()
	cam.fov = FOV_INTERNAL if cam_mode == 0 and cam_view <= 1 else FOV_EXTERNAL
	audio.play("audio/gui/camera_change.wav", -10.0)
	_apply_view()

func _chase_camera(delta: float) -> void:
	# the camera rides the PILOTED ship: the remote vessel while a link is
	# up (#1) -- the pilot moved, so the eye did
	var target: Transform3D = piloted().global_transform
	if jump_state == 4:
		_capsule_camera(delta, target)
		return
	# camera 25 holds from the queue through the entry flash (event 0xf,
	# duration -2; nothing re-cues until 0x10 inside the capsule)
	if jump_state in [1, 2, 3]:
		_jump_queue_camera(target)
		return
	_jq_set = false
	# inside Lucrecia's Base the camera is the diorama's own, out of the scene
	if base_iface != null and base_iface.inside:
		base_iface.place_camera()
		return
	if base_root != null:
		# in the hangar: gantry viewpoint with a gentle sway
		var a := Time.get_ticks_msec() / 1000.0 * 0.11
		var pos := target.origin + Vector3(-150.0 + sin(a) * 35.0, 70.0,
			-180.0 + cos(a * 0.7) * 25.0)
		cam.global_transform = Transform3D(Basis.IDENTITY, pos).looking_at(
			target.origin + Vector3(0, 0, 0), Vector3.UP)
		return
	# the target the "look at the target" cameras (inverse tactical, target
	# external) frame; without one they fall back to their forward-looking twin
	var tp := _target_pos()
	# every external camera range in the original is authored in SHIP RADII
	# (defaults.ini: [icArcadeCamera] range = 4, [icChaseCamera]/[icDollyCamera]
	# initial_range = 4, [icExternalCamera] initial_zoom = 3), against
	# iiSim::CalculateRadius (0x1007ccf0). Fixed-metre offsets framed the
	# turret fighter fine and put the camera INSIDE the tug's silhouette.
	var r: float = piloted().radius
	# advance the icInternalCamera neck springs once for the frame; the cockpit
	# eye rides them so it lags the ship's motion (icInternalCamera::Update)
	_ffb_step(target.basis, delta)
	match cam_name():
		"cockpit", "no_cockpit":  # the pilot's eye (the crew null) on the neck
			cam.global_transform = _ffb_look(target.translated_local(eye))
		"arcade":  # icArcadeCamera::Update (0x100d3a00): the eye trails 4x hull
			# radius BEHIND (range @ 0x101620f4) and 1.2x ABOVE (@ 0x1011a1c4),
			# easing the offset and the up/roll quat toward the pose at a hard-coded
			# k = clamp(2.5*dt) (rate @ 0x101620f0) -- the same offset+quat ease as
			# the chase camera (its speed*max_range/range is 2.5 at range 4), so it
			# routes through _chase_follow. It does NOT look at the hull: it aims
			# far along the CURRENT heading (forward*10000 @ 0x1011a18c, the commit
			# 0x100d4620 takes look = arg2), which sits the ship low-frame and lets
			# it slide sideways as the lagging eye catches up -- the arcade FFB.
			# (basis.z is the hull's local +Z = astern in Godot; -basis.z ahead.)
			var want_off := target.basis.z * (4.0 * r) + target.basis.y * (1.2 * r)
			var focus := target.origin - target.basis.z * 10000.0
			_chase_follow(target, want_off, focus, delta)
		"tactical":  # icChaseCamera: initial_range 4
			var want_off := target.basis * (Vector3(0, 0.24, 0.97) * 4.0 * r)
			var focus := target.origin + target.basis * Vector3(0, 0.075 * r,
				-0.375 * r)
			_chase_follow(target, want_off, focus, delta)
		"inverse_tactical":  # over the nose, looking back at the ship
			var want_off := target.basis * (Vector3(0, 0.15, -0.99) * 4.0 * r)
			_chase_follow(target, want_off, target.origin, delta)
		"external":  # slow orbit around the ship; icExternalCamera initial_zoom 3
			var a := Time.get_ticks_msec() / 1000.0 * 0.15
			var pos := target.origin + Vector3(cos(a), 0.25, sin(a)) * 3.0 * r
			cam.global_transform = Transform3D(Basis.IDENTITY, pos).looking_at(
				target.origin, Vector3.UP)
		"target_external":  # orbit the ship, but framed on the current target
			var a := Time.get_ticks_msec() / 1000.0 * 0.15
			var pos := target.origin + Vector3(cos(a), 0.25, sin(a)) * 3.0 * r
			var look: Vector3 = target.origin + (-target.basis.z * 1000.0 \
				if tp == Vector3.INF else (tp - target.origin).normalized() * 1000.0)
			cam.global_transform = Transform3D(Basis.IDENTITY, pos).looking_at(
				look, Vector3.UP)
		"drop":  # fixed in space, tracking the ship
			cam.global_transform = Transform3D(Basis.IDENTITY,
				drop_cam_pos).looking_at(target.origin, Vector3.UP)

## Camera 25 -- the jump-queue drop camera (#34). icDirector event 0xf
## ("jump queued", cued by PerformJumps case 0) selects camera 25
## (response table @ 0x1011d498: cams (25,25,25), priority 7, duration -2
## = held for the queue). It is a DROP camera (ctor FUN_100d95e0, the
## instance at icDirector+0x244 with +0xa8 = 8.0; cut placement
## FUN_100d9710): parked AHEAD of the flight path by rand[1.5, 2.0] s of
## travel (0x101626c4/c8) along the velocity direction (the focus basis
## +Z at rest), displaced sideways by a random unit vector at
## max(radius / tan(0.5), radius * 1.5) x the 8.0 multiplier, then left
## FIXED, tracking the ship as it runs the acceleration past it.
var _jq_set := false
var _jq_pos := Vector3.ZERO

func _jump_queue_camera(target: Transform3D) -> void:
	if not _jq_set:
		_jq_set = true
		var r: float = maxf(piloted().radius, 1.0)
		var vel: Vector3 = piloted().velocity
		var vd := vel.normalized() if vel.length() > 1e-3 \
				else -target.basis.z
		var side := Vector3(randf_range(-1, 1), randf_range(-1, 1),
				randf_range(-1, 1)).normalized() \
				* maxf(r / tan(0.5), r * 1.5) * 8.0
		_jq_pos = target.origin + vd * vel.length() \
				* randf_range(1.5, 2.0) + side
		if cockpit != null:
			cockpit.visible = false
		if ship_model != null:
			ship_model.visible = true
		cam.fov = FOV_EXTERNAL
	cam.global_transform = Transform3D(Basis.IDENTITY, _jq_pos) \
			.looking_at(target.origin, Vector3.UP)

## The capsule-space camera. icDirector event 0x10 ("in capsule space",
## cued every frame by PerformJumps case 5 via FUN_100426f0) selects camera
## 24 (response table @ 0x1011d498: ev 0x10 -> cams (24,24,24), priority 8,
## re-cuttable). Camera 24 (ctor FUN_100dc080 @ 0x100dc080, Update @
## 0x100dc160) frames the ship from a random direction in the SHIP's frame,
## components ([0.8,1], [-1,1], [-1,1]) normalized -- biased to the ship's
## +X side -- at 4 x the focus radius (0x101190b4), with FOV 2 * 0.35 rad
## (_DAT_1011d378). Cuts are limited by flux.ini [icDirector]
## min_cut_time = 1. The final second cues event 0x11 -> camera 3,
## cam_internal_no_hud (name table @ 0x101621e0): back inside the cockpit
## for the exit flash.
func _capsule_camera(delta: float, target: Transform3D) -> void:
	if jump_timer >= jump_duration - 1.0:
		# cam_internal_no_hud: back inside the cockpit, HUD stays dark
		if cockpit != null:
			cockpit.visible = true
		if ship_model != null:
			ship_model.visible = false
		cam.fov = FOV_INTERNAL
		cam.global_transform = target.translated_local(eye)
		return
	# external shot: show the hull, drop the cockpit dressing
	if cockpit != null:
		cockpit.visible = false
	if ship_model != null:
		ship_model.visible = true
	_cap_cut_t -= delta
	if _cap_cut_t <= 0.0:
		_cap_cut_t = CAPSULE_CUT_TIME
		_cap_cam_dir = Vector3(randf_range(0.8, 1.0),
			randf_range(-1.0, 1.0), randf_range(-1.0, 1.0)).normalized()
	cam.fov = CAPSULE_CAM_FOV
	# the distance term is the focus record's +0x10 radius = the SIM's
	# radius (the drop camera reads the same field), not model bounds
	var r: float = piloted().radius
	if r <= 0.0:
		r = SHIP_HIT_RADIUS
	var pos := target.origin + target.basis * (_cap_cam_dir
		* r * CAPSULE_CAM_RANGE)
	cam.global_transform = Transform3D(Basis.IDENTITY, pos).looking_at(
		target.origin, target.basis.y)

## icChaseCamera::Update @ 0x100d4cb0 (raw disasm; constants and state in
## main_state.gd). The original smooths the camera's OFFSET from the focus and
## its up-quaternion -- never the absolute position -- so eye = focus + offset
## rides the ship at any speed. There is no LDS/jump special case in the
## original: the offset law is what keeps the camera glued during LDS, and the
## per-frame world fold cancels out of the relative state by construction
## (the original rebases its committed absolute eye via FUN_100d4790 instead).
## The aim is exact every frame; only position and up ease with
## k = clamp01(speed * max_range * dt / range) @ 0x100d4eac.
func _chase_follow(target: Transform3D, want_off: Vector3, focus: Vector3,
		delta: float) -> void:
	var k := clampf(CHASE_SPEED * CHASE_MAX_RANGE * delta / CHASE_RANGE,
		0.0, 1.0)
	var ship_q := target.basis.get_rotation_quaternion()
	if chase_snap:  # camera Reset @ 0x100d4bf0: state re-seeded on selection
		chase_offset = want_off
		chase_quat = ship_q
		chase_snap = false
	chase_offset = chase_offset.lerp(want_off, k)
	chase_quat = chase_quat.slerp(ship_q, k).normalized()
	var pos := target.origin + chase_offset
	cam.global_transform = Transform3D(Basis.IDENTITY, pos).looking_at(
		focus, chase_quat * Vector3.UP)


## The icInternalCamera neck spring (icInternalCamera::Update @ 0x100db3f0).
## Advances the two persistent springs from the piloted ship's state each frame;
## _ffb_look then applies them so the eye lags the ship's rotation and leans on
## its linear acceleration -- the visible "force feedback" as hull and camera
## diverge. Call once per camera frame BEFORE reading ffb_neck / ffb_lean.
func _ffb_step(basis: Basis, delta: float) -> void:
	if delta <= 0.0:
		return
	var pil := piloted()
	# Rotational neck: target = per-axis angular yoke x its ratio (roll negated,
	# fchs @ 0x100db658), spring toward it at neck_stiffness (loop @ 0x100db661).
	# The AngularYoke the original reads (icPlayerPilot vtable +0x40) is our
	# ship.input_rotate: x pitch, y yaw, z roll.
	var yoke: Vector3 = pil.input_rotate
	var neck_target := Vector3(
		FFB_NECK_RATIO.x * yoke.x,
		FFB_NECK_RATIO.y * yoke.y,
		-FFB_NECK_RATIO.z * yoke.z)
	ffb_neck += (neck_target - ffb_neck) * FFB_NECK_STIFFNESS * delta
	# Lateral lean: body-frame linear acceleration ((v - v_prev)/dt @ 0x100db6de,
	# rotated into the hull frame), scaled and clamped to +/-1 (0x100db8ba /
	# 0x100db934), weighted by lateral_ratio, sprung at acceleration_stiffness
	# (loop @ 0x100db9d1). accel_scale 0.01 keeps the normal thrust range inside
	# the clamp instead of pinning it.
	var vel: Vector3 = pil.velocity
	if not ffb_seeded:
		ffb_prev_vel = vel
		ffb_seeded = true
	var accel_body := ((vel - ffb_prev_vel) / delta) * basis  # world -> local
	ffb_prev_vel = vel
	var lean_in := Vector3(
		clampf(accel_body.x * FFB_ACCEL_SCALE, -1.0, 1.0),
		clampf(accel_body.y * FFB_ACCEL_SCALE, -1.0, 1.0),
		clampf(accel_body.z * FFB_ACCEL_SCALE, -1.0, 1.0))
	var lean_target := FFB_LATERAL_RATIO * lean_in
	ffb_lean += (lean_target - ffb_lean) * FFB_ACCEL_STIFFNESS * delta

## Build the neck-sprung eye transform from a rigid mount `mount` (eye or arcade
## seat, already in world space with the hull's basis). The neck rotates the LOOK
## about a focal point focal_length ahead (0x100dbb8e builds the offset quat,
## 0x100d4620 commits eye->look); the lean shifts the eye in the hull frame.
func _ffb_look(mount: Transform3D) -> Transform3D:
	# The neck LEANS INTO the input (the original rotates the look by +neck, only
	# roll negated -- already done in the target). It must not oppose the input:
	# at motion onset the neck grows linearly while the hull's own rotation is
	# still ramping from zero, so a -neck would swing the view the WRONG way for a
	# frame (mouse up -> a beat of down) before the hull caught up. +neck kicks
	# the view with the input, then relaxes back as the yoke centres -- the settle
	# that reads as force feedback.
	var neck := Basis.from_euler(ffb_neck)
	var fwd := mount.basis * (neck * Vector3(0, 0, -1))
	var up := mount.basis * (neck * Vector3(0, 1, 0))
	# focal point stays on the rigid mount; the eye leans under G -- so the lean
	# reads as parallax against a fixed convergence point (the original commits
	# eye = base + lean, look = base + focal*neck_forward @ 0x100dbd4b/0x100d4620)
	var look := mount.origin + fwd * FFB_FOCAL
	var pos := mount.origin + mount.basis * ffb_lean
	return Transform3D(Basis.IDENTITY, pos).looking_at(look, up)

## Zero the neck springs on a camera cut so the new view does not inherit the old
## lag (the camera Reset @ 0x100d4bf0 re-seeds; chase_snap already flags cuts).
func _ffb_reset() -> void:
	ffb_neck = Vector3.ZERO
	ffb_lean = Vector3.ZERO
	ffb_seeded = false


func _face_target() -> void:
	# demo autopilot: steer via the flight model, like a real pilot would
	var p := _target_pos()
	if p == Vector3.INF:
		return
	_face_dir(p)

func _face_dir(p: Vector3) -> void:
	# icAITarget::ComputeAngularControl (0x1005e32c): decompose the heading error
	# into (pitch, yaw) the way the engine does (ship.aim_angles /
	# ComputeAnglesForDirection), then steer each euler axis with the time-optimal
	# braking controller so the nose arrives ON the heading with zero residual rate
	# instead of overshooting and ping-ponging back. ship.angular_yoke carries the
	# extracted brake law.
	var ang := ship.aim_angles(p * ship.global_transform.basis)
	ship.input_rotate.x = ship.angular_yoke(ang.x, ship.angular_velocity.x, 0)
	ship.input_rotate.y = ship.angular_yoke(ang.y, ship.angular_velocity.y, 1)
