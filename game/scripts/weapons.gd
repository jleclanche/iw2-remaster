class_name PbcWeapons
extends Node3D
# Twin PBC cannons with IW2 constants (sims/weapons/pbc_bolt.ini):
# muzzle velocity is ADDED to ship velocity (fully Newtonian), bolts are
# long emissive tracers. No damage application yet — impact flash only.

const BOLT_SPEED := 6000.0
const BOLT_LIFE := 1.6
const BOLT_LENGTH := 90.0  # visual streak (data says 800 m total light trail)
const REFIRE := 0.3
const MUZZLES := [Vector3(0, 17.5, -8), Vector3(0, -6, -30)]  # tug pbc mounts

var ship: ShipFlight
var cooldown := 0.0
var bolts: Array = []  # {node, vel, life}
var _mesh: BoxMesh
var _mat: StandardMaterial3D

func _ready() -> void:
	_mesh = BoxMesh.new()
	_mesh.size = Vector3(0.8, 0.8, BOLT_LENGTH)
	_mat = StandardMaterial3D.new()
	_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_mat.albedo_color = Color(0.7, 0.85, 1.0)
	_mat.emission_enabled = true
	_mat.emission = Color(0.55, 0.75, 1.0)
	_mat.emission_energy_multiplier = 6.0
	_mesh.material = _mat

func fire() -> void:
	if cooldown > 0.0:
		return
	cooldown = REFIRE
	var b := ship.global_transform.basis
	for m in MUZZLES:
		var node := MeshInstance3D.new()
		node.mesh = _mesh
		get_parent().add_child(node)
		node.global_position = ship.global_transform * m
		node.global_transform.basis = b
		bolts.append({
			"node": node,
			"vel": ship.velocity + b * Vector3(0, 0, -BOLT_SPEED),
			"life": BOLT_LIFE,
		})

func _physics_process(delta: float) -> void:
	cooldown = maxf(0.0, cooldown - delta)
	var i := bolts.size() - 1
	while i >= 0:
		var bolt: Dictionary = bolts[i]
		bolt["life"] -= delta
		var node: MeshInstance3D = bolt["node"]
		if bolt["life"] <= 0.0 or not is_instance_valid(node):
			if is_instance_valid(node):
				node.queue_free()
			bolts.remove_at(i)
		else:
			node.global_position += bolt["vel"] * delta
		i -= 1

func shift_world(offset: Vector3) -> void:
	# called by the floating-origin fold so bolts stay in the player frame
	for bolt in bolts:
		var node: MeshInstance3D = bolt["node"]
		if is_instance_valid(node):
			node.global_position -= offset
