class_name CameraTail
extends Node
# Runs Main's camera placement AFTER every ship and effect node has integrated.
#
# Main is the PARENT of `ship` (main_flow.gd:663), and Godot walks the physics
# callback depth-first, parent before child. So `_chase_camera` running inside
# Main._physics_process read `ship.global_transform` a full tick before
# ShipFlight integrated it (ship_flight.gd:164) -- the view sat
# `velocity * delta` behind everything rigidly attached to the hull.
#
# That is a fixed 14 m at the tug's 850 m/s / 60 Hz and far more under LDS,
# which is why it read as "the thruster lights drift when I fly faster": in the
# cockpit view the hull is hidden (main_camera.gd:16) and the cockpit is a child
# of the camera (main_flow.gd:697), so the engine flares were the only
# hull-attached geometry left to show the lag.
#
# `process_priority` orders the whole physics group, so this runs last no matter
# where the node lands in the tree.

const TAIL_PRIORITY := 100

var main: Node = null


func _ready() -> void:
	process_priority = TAIL_PRIORITY


func _physics_process(delta: float) -> void:
	if main != null:
		main.late_physics(delta)
