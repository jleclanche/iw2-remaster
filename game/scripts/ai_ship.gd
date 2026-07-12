class_name AiShip
extends ShipFlight
# AI pilot on top of the same flight model the player uses.
# Behaviors: "patrol" (cruise between waypoints), "attack" (pursue the
# player, fire PBCs in range/arc). Stats and hull from the extracted INIs.

var behavior := "patrol"
var display_name := ""  # node names mangle punctuation; HUD uses this
var hull := 1000.0
var hull_max := 1000.0
var main: Node3D
var waypoints: Array[Vector3] = []
var wp := 0
var fire_cooldown := 0.0
var bolt_speed := 6000.0
var weapon_range := 2500.0

func setup(props: Dictionary) -> void:
	load_stats(props)
	hull_max = float(props.get("hit_points", 1000))
	hull = hull_max

func damage(amount: float) -> bool:
	hull -= amount
	return hull <= 0.0

func _physics_process(delta: float) -> void:
	fire_cooldown = maxf(0.0, fire_cooldown - delta)
	match behavior:
		"attack":
			_attack(delta)
		_:
			_patrol(delta)
	super._physics_process(delta)

func _steer_toward(point: Vector3, _delta: float) -> float:
	# steer through the flight model's angular dynamics (input_rotate) so AI
	# ships turn like ships, not turrets
	var local := (point - global_position) * global_transform.basis
	var pitch := atan2(local.y, -local.z)
	var yaw := atan2(-local.x, -local.z)
	input_rotate.x = clampf(pitch * 2.0, -1.0, 1.0)
	input_rotate.y = clampf(yaw * 2.0, -1.0, 1.0)
	input_rotate.z = 0.0
	return Vector2(pitch, yaw).length()

func _patrol(delta: float) -> void:
	if waypoints.is_empty():
		set_speed = 0.0
		return
	var target := waypoints[wp]
	if global_position.distance_to(target) < 800.0:
		wp = (wp + 1) % waypoints.size()
	_steer_toward(target, delta)
	set_speed = max_speed.z * 0.5

func _attack(delta: float) -> void:
	if main == null or main.ship == null:
		return
	var player: ShipFlight = main.ship
	# lead the target: aim where the player will be when the bolt arrives
	var dist := global_position.distance_to(player.global_position)
	var tof := dist / bolt_speed
	var aim: Vector3 = player.global_position + (player.velocity - velocity) * tof
	var angle := _steer_toward(aim, delta)
	set_speed = max_speed.z if dist > 1200.0 else max_speed.z * 0.35
	if dist < weapon_range and angle < 0.06 and fire_cooldown <= 0.0:
		fire_cooldown = 0.5
		main.spawn_bolt(self, -global_transform.basis.z)
