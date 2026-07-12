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

# --- state ---
var velocity := Vector3.ZERO                 # world m/s
var angular_velocity := Vector3.ZERO         # local rad/s (pitch, yaw, roll)
var set_speed := 0.0                         # m/s "throttle wheel" setting;
                                             # the flight computer flies the
                                             # ship at this speed along the nose
var assist := true
var drive_override := false                  # LDS/capsule drive owns velocity:
                                             # skip assist trim and speed caps

# --- per-frame inputs, set by the pilot controller ---
var input_rotate := Vector3.ZERO             # desired pitch/yaw/roll -1..1
var input_thrust := Vector3.ZERO             # lateral/vertical/fore-aft -1..1

func load_stats(props: Dictionary) -> void:
	var s: Array = props.get("speed", [200, 200, 850])
	var a: Array = props.get("acceleration", [100, 100, 150])
	max_speed = Vector3(s[0], s[1], s[2])
	max_accel = Vector3(a[0], a[1], a[2])
	turn_rate = Vector3(props.get("pitch_rate", 60), props.get("yaw_rate", 60),
			props.get("roll_rate", 60))
	turn_accel = Vector3(props.get("pitch_accel", 30), props.get("yaw_accel", 30),
			props.get("roll_accel", 30))
	angular_speed_boost = props.get("angular_speed_boost", 1.0)

func _physics_process(delta: float) -> void:
	_integrate_rotation(delta)
	_integrate_translation(delta)

func _integrate_rotation(delta: float) -> void:
	var boost := 1.0 if assist else angular_speed_boost
	var target_w := Vector3(
		input_rotate.x * deg_to_rad(turn_rate.x),
		input_rotate.y * deg_to_rad(turn_rate.y),
		input_rotate.z * deg_to_rad(turn_rate.z)) * boost
	var accel := Vector3(deg_to_rad(turn_accel.x), deg_to_rad(turn_accel.y),
			deg_to_rad(turn_accel.z)) * boost
	# IW2 rotation is snappy: angular accel limits are generous relative to
	# rates; move toward target with per-axis accel cap
	angular_velocity.x = move_toward(angular_velocity.x, target_w.x, accel.x * delta * 8.0)
	angular_velocity.y = move_toward(angular_velocity.y, target_w.y, accel.y * delta * 8.0)
	angular_velocity.z = move_toward(angular_velocity.z, target_w.z, accel.z * delta * 8.0)
	rotate_object_local(Vector3.RIGHT, angular_velocity.x * delta)
	rotate_object_local(Vector3.UP, angular_velocity.y * delta)
	rotate_object_local(Vector3.BACK, angular_velocity.z * delta)

func _integrate_translation(delta: float) -> void:
	# IW2 semantics: thrusters (W/S/A/D) always push directly, Newtonian.
	# With assist on, the flight computer trims axes that have no active
	# thruster input toward the set-speed vector (set_speed along the nose,
	# zero laterally); assist never fights a held thruster.
	if drive_override:
		global_position += velocity * delta
		return
	var b := global_transform.basis
	var v_local := velocity * b  # world->local
	if absf(input_thrust.x) > 0.05:
		v_local.x += input_thrust.x * max_accel.x * delta
	elif assist:
		v_local.x = move_toward(v_local.x, 0.0, max_accel.x * delta)
	if absf(input_thrust.y) > 0.05:
		v_local.y += input_thrust.y * max_accel.y * delta
	elif assist:
		v_local.y = move_toward(v_local.y, 0.0, max_accel.y * delta)
	if absf(input_thrust.z) > 0.05:
		v_local.z += -input_thrust.z * max_accel.z * delta
	elif assist:
		v_local.z = move_toward(v_local.z, -set_speed, max_accel.z * delta)
	if assist:
		v_local.x = clampf(v_local.x, -max_speed.x, max_speed.x)
		v_local.y = clampf(v_local.y, -max_speed.y, max_speed.y)
		v_local.z = clampf(v_local.z, -max_speed.z, max_speed.z)
	velocity = b * v_local
	global_position += velocity * delta

func thrusting() -> bool:
	return input_thrust.length() > 0.05

func speed() -> float:
	return velocity.length()

func forward_speed() -> float:
	return -(velocity * global_transform.basis).z
