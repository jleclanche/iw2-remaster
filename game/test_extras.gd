extends SceneTree
# Headless check: extras import + ShipEffects rig behavior.
# usage: godot --headless -s test_extras.gd

func _init() -> void:
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	var path := ProjectSettings.globalize_path("res://").path_join(
		"../data/avatars/avatars/tug_hull/setup_prefitted.gltf")
	if doc.append_from_file(path, state) != OK:
		print("EXTRAS: load failed")
		quit(1)
		return
	var node := doc.generate_scene(state)
	var ship := ShipFlight.new()
	ship.add_child(node)
	root.add_child(ship)
	var fx := ShipEffects.attach(ship, node)
	print("EXTRAS: anim=%d" % fx.anim_nodes.size())
	var cones := 0
	for n in node.find_children("*", "MeshInstance3D", true, false):
		if n.mesh is CylinderMesh:
			cones += 1
	print("EXTRAS: cones=%d" % cones)
	# drive the channels to full and inspect a flame node's transform
	ship.set_speed = 850.0
	fx.set_input_channels(1.0, 1.0, 100.0)
	for entry in fx.anim_nodes:
		var t: float = fx.channels.get(entry["channel"], 0.0)
		if entry["channel"] == "flame":
			var n: Node3D = entry["node"]
			n.transform = Transform3D(Basis(entry["q0"].slerp(entry["q1"], t))
				.scaled_local(entry["s0"].lerp(entry["s1"], t)),
				entry["p0"].lerp(entry["p1"], t))
			print("EXTRAS: flame t=%.2f scale=%s pos=%s" %
				[t, n.transform.basis.get_scale(), n.position])
			break
	quit(0)
