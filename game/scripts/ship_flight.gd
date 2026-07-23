class_name ShipFlight
extends Node3D
# IW2-style assisted-Newtonian flight model.
#
# The ship has a target velocity (throttle * forward, plus lateral/vertical
# thrust inputs). Flight assist accelerates toward the target velocity with
# per-axis acceleration limits, expressed in the SHIP's local frame — exactly
# how IW2's INI constants are specified (speed/acceleration as (x,y,z)
# vectors, angular rates in deg/s). With assist off the ship is a pure
# Newtonian body: thrust inputs apply acceleration directly, velocity drifts.
#
# All tuning constants come from the extracted ship INI (data/json/ships.json).

# --- constants loaded from ship data (tug defaults) ---
var max_speed := Vector3(200, 200, 850)      # m/s per local axis
var max_accel := Vector3(100, 100, 150)      # m/s^2 per local axis
var turn_rate := Vector3(60, 60, 60)         # pitch, yaw, roll deg/s
var turn_accel := Vector3(30, 30, 30)        # deg/s^2
var angular_speed_boost := 1.4               # free-flight rotation bonus
# iiThrusterSim::Load (0x1007ddf0): mass = width * height * length *
# m_density (0.001 @ 0x1011c168) -- the hull's bounding box at 1 kg/m^3 in
# the engine's unit -- and the thrust FORCE is mass * the authored
# acceleration (+0x224/228/22c = mass * accel vector). Every ini `mass=` on
# a thruster/inert sim is overwritten by this (which is why the stock inis
# never author it); `immobile=1` instead forces SetMass(0) = INFINITE
# (FiSim stores 1/mass at +0xa0; 0 means force can never move it).
var mass := 0.0
# iiThrusterSim::Load (0x1007ddf0) and the iship.RecalculateMOIFromMass
# handler (iship.dll @ 0x10003450): the inertia tensor is the DIAGONAL box
# tensor over the ini dims -- diag(m/12*(h^2+l^2), m/12*(w^2+l^2),
# m/12*(w^2+h^2)), 1/12 @ 0x1011ae44 / 0x10004140 -- rebuilt from the
# CURRENT mass whenever a script changes it (sim.SetMass does NOT rebuild).
var dims := Vector3.ZERO       # ini width/height/length (m)
var moi := Vector3.ZERO        # diagonal inertia, body frame
# Docking (icDockPort::OnDock -> FiSim::AttachChild -> OnAttachChild):
# the child's mass and moment of inertia are ADDED to the parent's, and
# FiSim::Integrate divides force by the total -- a heavy docked pod scales
# your acceleration by mass/(mass+partner), an immobile partner kills it.
var tow_mass := 0.0            # docked child's mass; INF = immobile partner
var tow_torque_scale := Vector3.ONE  # per-axis I_own / I_combined, set by main

func recalc_moi() -> void:
	var k := mass / 12.0
	moi = Vector3(
		k * (dims.y * dims.y + dims.z * dims.z),
		k * (dims.x * dims.x + dims.z * dims.z),
		k * (dims.x * dims.x + dims.y * dims.y))
# iiSim::CalculateRadius (0x1007ccf0): sqrt((w^2 + h^2 + l^2) * 0.25) -- the
# engine's sim radius. The external cameras are authored in RADII (defaults.ini
# [icArcadeCamera] range = 4, [icChaseCamera] initial_range = 4, ...).
var radius := 80.0             # tug default

# --- state ---
var velocity := Vector3.ZERO                 # world m/s
var angular_velocity := Vector3.ZERO         # local rad/s (pitch, yaw, roll)
var set_speed := 0.0                         # m/s "throttle wheel" setting;
                                             # the flight computer flies the
                                             # ship at this speed along the nose
var assist := true
var drive_override := false                  # LDS/capsule drive owns velocity:
                                             # skip assist trim and speed caps
var fx: Node = null                          # ShipEffects channel rig
# icShip::ApplyThrusterBurns (iwar2.dll @ 0x100758a0) writes the avatar
# channels "lx"/"ly"/"lz" (name strings @ 0x1015d5fc/0x1015d600/0x1015d2b0)
# every tick as APPLIED thruster force / max force per axis (+0x224..0x22c =
# mass * authored accel) -- the force the flight computer commanded, so the
# assist's own trim burns light the drives, not just held stick input.
# Recorded by _integrate_translation in the original's sign convention
# (+z = forward burn, LW axes); ShipEffects feeds it to the authored channel
# expressions ("lz?+s(1.0)" = the command section's engine glow).
var thrust_frac := Vector3.ZERO

# --- per-frame inputs, set by the pilot controller ---
var input_rotate := Vector3.ZERO             # desired pitch/yaw/roll -1..1
var input_thrust := Vector3.ZERO             # lateral/vertical/fore-aft -1..1

func load_stats(props: Dictionary) -> void:
	var s: Array = props.get("speed", [200, 200, 850])
	var a: Array = props.get("acceleration", [100, 100, 150])
	max_speed = Vector3(s[0], s[1], s[2])
	max_accel = Vector3(a[0], a[1], a[2])
	var w := float(props.get("width", 0.0))
	var h := float(props.get("height", 0.0))
	var l := float(props.get("length", 0.0))
	mass = w * h * l * 0.001  # m_density
	dims = Vector3(w, h, l)
	recalc_moi()
	if w > 0.0 or h > 0.0 or l > 0.0:
		radius = sqrt((w * w + h * h + l * l) * 0.25)  # CalculateRadius
	turn_rate = Vector3(props.get("pitch_rate", 60), props.get("yaw_rate", 60),
			props.get("roll_rate", 60))
	turn_accel = Vector3(props.get("pitch_accel", 30), props.get("yaw_accel", 30),
			props.get("roll_accel", 30))
	angular_speed_boost = props.get("angular_speed_boost", 1.0)

func _physics_process(delta: float) -> void:
	_integrate_rotation(delta)
	_integrate_translation(delta)

func mass_scale() -> float:
	# FiSim::Integrate: accel = force * (1 / total mass). Our force is
	# mass * max_accel, so the docked-pair accel is max_accel * this.
	if tow_mass <= 0.0:
		return 1.0
	if is_inf(tow_mass) or mass <= 0.0:
		return 0.0
	return mass / (mass + tow_mass)

func _integrate_rotation(delta: float) -> void:
	var boost := 1.0 if assist else angular_speed_boost
	var target_w := Vector3(
		input_rotate.x * deg_to_rad(turn_rate.x),
		input_rotate.y * deg_to_rad(turn_rate.y),
		input_rotate.z * deg_to_rad(turn_rate.z)) * boost
	var accel := Vector3(deg_to_rad(turn_accel.x), deg_to_rad(turn_accel.y),
			deg_to_rad(turn_accel.z)) * boost * tow_torque_scale
	# Rate-demand fly-by-wire: the yoke commands a target angular velocity
	# (capped at pitch/yaw/roll_rate) and the flight computer accelerates
	# toward it at the authored angular accel. iiThrusterSim::Load (0x1007ddf0)
	# stores max_torque = MOI * (*_accel * deg2rad) (+0x230..0x238, MOI = the
	# box tensor m/12) and max_angular_speed = (*_rate * deg2rad) (+0x23c..0x244);
	# FiSim::Integrate then applies torque/MOI, so an UNDOCKED ship's net
	# angular acceleration is exactly the authored *_accel (deg/s^2) -- MOI
	# cancels, and only re-enters through tow_torque_scale when a pod is docked.
	# The tug's 30 deg/s^2 climb to its 60 deg/s rate is a 2 s ramp; that
	# build-up (heavier on bigger hulls, per each ship's authored *_accel) is
	# the "force feedback" of the original yoke. (An earlier pass multiplied
	# accel by 8x for "snappiness" -- that collapsed the ramp to 0.25 s and
	# tracked the reticle ~1:1; it was invented, not extracted.)
	angular_velocity.x = move_toward(angular_velocity.x, target_w.x, accel.x * delta)
	angular_velocity.y = move_toward(angular_velocity.y, target_w.y, accel.y * delta)
	angular_velocity.z = move_toward(angular_velocity.z, target_w.z, accel.z * delta)
	rotate_object_local(Vector3.RIGHT, angular_velocity.x * delta)
	rotate_object_local(Vector3.UP, angular_velocity.y * delta)
	rotate_object_local(Vector3.BACK, angular_velocity.z * delta)

func _integrate_translation(delta: float) -> void:
	# IW2 semantics: thrusters (W/S/A/D) always push directly, Newtonian.
	# With assist on, the flight computer trims axes that have no active
	# thruster input toward the set-speed vector (set_speed along the nose,
	# zero laterally); assist never fights a held thruster.
	if drive_override:
		# LDS: the drive holds a full positive forward yoke (the "burn" flag
		# @ 0x100758a0 reads yoke z at +0x2cc > 0), so the drives blaze
		thrust_frac = Vector3(0.0, 0.0, 1.0)
		global_position += velocity * delta
		return
	var b := global_transform.basis
	var v_local := velocity * b  # world->local
	# a docked partner's mass divides the same thruster force
	var acc := max_accel * mass_scale()
	# the channel fractions (see thrust_frac): commanded accel / max accel.
	# A held thruster is the input itself; the assist trim step is
	# |dv| <= acc*delta, so its fraction is dv/(acc*delta), full while
	# chasing the set speed and fading out as the ship settles on it.
	var frac := Vector3.ZERO
	if absf(input_thrust.x) > 0.05:
		v_local.x += input_thrust.x * acc.x * delta
		frac.x = input_thrust.x
	elif assist:
		var dvx := move_toward(v_local.x, 0.0, acc.x * delta) - v_local.x
		v_local.x += dvx
		frac.x = dvx / maxf(acc.x * delta, 1e-9)
	if absf(input_thrust.y) > 0.05:
		v_local.y += input_thrust.y * acc.y * delta
		frac.y = input_thrust.y
	elif assist:
		var dvy := move_toward(v_local.y, 0.0, acc.y * delta) - v_local.y
		v_local.y += dvy
		frac.y = dvy / maxf(acc.y * delta, 1e-9)
	if absf(input_thrust.z) > 0.05:
		v_local.z += -input_thrust.z * acc.z * delta
		frac.z = input_thrust.z
	elif assist:
		var dvz := move_toward(v_local.z, -set_speed, acc.z * delta) - v_local.z
		v_local.z += dvz
		# our local -z is forward; the channel convention is +z = forward
		frac.z = -dvz / maxf(acc.z * delta, 1e-9)
	thrust_frac = frac
	# NO velocity clamp -- and that is extracted, not a choice.
	# iiThrusterSim::MaxSpeed (0x1007e2a0, the ini `speed` vector) has exactly
	# three consumers in iwar2.dll: the AI target-velocity scaling
	# (icAITarget::ComputeTargetVelocity 0x1005a098), the avatar speed-fraction
	# channel (clamped 0..1 for effects), and the throttle range. Nothing caps
	# the ship's actual velocity: the throttle SETTING is bounded by the rated
	# speed, but held thrust accelerates past it (Newtonian), and releasing it
	# lets the assist trim back down to the set speed. The dial's own
	# over-range blink (|speed/rated| > 1.001, FUN_100f6c80) exists precisely
	# because overspeed happens. (An earlier pass clamped here; invented.)
	velocity = b * v_local
	global_position += velocity * delta

# --- autopilot / AI angular controller (icAITarget) ---
# Exported tuning statics in iwar2.dll (icAITarget::m_*), read from the PE:
const AI_ANG_DAMP_DIST := 0.05    # m_angular_damping_distance @ 0x1015c3cc (rad)
const AI_ANG_DONE_DIST := 0.002   # m_angular_completion_distance @ 0x1015c3c8 (rad)
const AI_ANG_DONE_VEL := 0.017    # m_angular_completion_velocity @ 0x1015c3c4 (rad/s)

## One euler axis of the AI/autopilot orientation controller, ported from
## icAITarget::ComputeJourneyComponent (iwar2.dll @ 0x10058f6e) and its yoke
## conversion ComputeAngularYoke (0x1005e0ed). Both the player autopilot
## (main._face_dir) and the AI pilots (AiShip._steer_toward) run through
## icAITarget::ComputeAngularControl (0x1005e32c) in the original -- the player's
## autopilot IS an AutopilotApproach order on the player's OWN icAIPilot
## (icPlayerPilot::EngageAutopilotApproach 0x100afbc0) -- so they share this.
##
## `e` is the signed angle error (rad) to null on this axis, `w` the ship's
## current body rate (rad/s) about it (angular_velocity[axis]); `axis` picks
## pitch/yaw/roll for the authored accel and rate. Returns the yoke fraction
## (-1..1) to write to input_rotate[axis].
##
## The law: from the current rate, solve the peak rate of a symmetric
## accelerate-then-decelerate profile that reaches the target heading with zero
## residual rate -- vp = sqrt((w^2 + 2*a*|e|) / 2), the 2 is _DAT_10119ec8 -- and
## command it, so the flight computer eases off BEFORE the mark and settles
## instead of ping-ponging past it (the brake the replaced pitch*2 proportional
## steer lacked). Inside m_angular_damping_distance the accel scales down for a
## soft landing; within completion distance AND rate the axis is done and the
## yoke releases. Modelled for a static target (target rate 0) with skill and
## control authority 1 (the player-autopilot defaults); roll banking
## (ComputeAnglesForNormal) is not modelled -- callers leave input_rotate.z at 0.
func angular_yoke(e: float, w: float, axis: int) -> float:
	var boost := 1.0 if assist else angular_speed_boost
	var a := deg_to_rad(turn_accel[axis]) * boost * tow_torque_scale[axis]
	var vmax := deg_to_rad(turn_rate[axis]) * boost
	if a <= 0.0 or vmax <= 0.0:
		return 0.0
	# completion snap (target rate 0): both the rate and the angle within
	# tolerance -> the axis is settled, release the yoke (ComputeAngularControl
	# marks the axis complete and ComputeAngularYoke emits 0 for a zero command)
	var rate_done := absf(w) < AI_ANG_DONE_VEL
	if rate_done and absf(e) < AI_ANG_DONE_DIST:
		return 0.0
	var dt := get_physics_process_delta_time()
	# local_8 = accel in the closing sense, local_10 = the opposing decel,
	# picked by the sign of the error
	var a8 := a if e >= 0.0 else -a
	var a10 := -a if e >= 0.0 else a
	# soft landing inside the damping distance (floored at 0.01 of the accel)
	if absf(e) < AI_ANG_DAMP_DIST:
		var s := maxf(absf(e) / AI_ANG_DAMP_DIST, 0.01)
		a8 *= s
		a10 *= s
	# peak rate of the accel/decel profile, signed by the error
	var peak := sqrt(maxf((w * w * a10 + 2.0 * a8 * a10 * e) / (a10 - a8), 0.0))
	var v_peak := peak if e >= 0.0 else -peak
	var t_acc := (v_peak - w) / a8   # time to accelerate from w up to the peak
	var w_cmd: float
	if t_acc >= dt:
		w_cmd = v_peak               # still accelerating for the whole frame
	elif t_acc <= 0.0:
		# already at/past the peak: null the residual angle this frame if the
		# rate is within completion, else coast to the target rate (0) -- braking
		w_cmd = e / dt if rate_done else 0.0
	else:
		# the peak lands mid-frame: average the accel and decel sub-steps
		var rate_at_peak := a8 * t_acc + w
		var t_rem := dt - t_acc
		var avg := (rate_at_peak + w) * 0.5
		w_cmd = 2.0 * (avg * t_acc + a10 * 0.5 * t_rem * t_rem
			+ rate_at_peak * t_rem) / dt - w
	# ComputeAngularYoke: target rate / max rate, clamped to the stops
	return clampf(w_cmd / vmax, -1.0, 1.0)

func thrusting() -> bool:
	return input_thrust.length() > 0.05

func speed() -> float:
	return velocity.length()

func forward_speed() -> float:
	return -(velocity * global_transform.basis).z
