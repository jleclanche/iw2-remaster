extends Node3D
# Loads a glTF given by --gltf (or the tug by default), frames it, saves a
# screenshot to --out and quits. Used for automated visual validation.

func _ready() -> void:
	# paths are relative to the repo root (parent of the game/ project dir)
	var gltf_path := "data/avatars/avatars/tug_hull/setup_prefitted.gltf"
	var out_path := "data/screenshots/shot.png"
	var view_dir := Vector3(0.7, 0.5, 1.0)
	var args := OS.get_cmdline_user_args()
	for i in args.size():
		if args[i] == "--gltf" and i + 1 < args.size():
			gltf_path = args[i + 1]
		elif args[i] == "--out" and i + 1 < args.size():
			out_path = args[i + 1]
		elif args[i] == "--dir" and i + 1 < args.size():
			var p := args[i + 1].split(",")
			view_dir = Vector3(float(p[0]), float(p[1]), float(p[2]))

	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	var base := ProjectSettings.globalize_path("res://").path_join("..")
	var err := doc.append_from_file(base.path_join(gltf_path), state)
	if err != OK:
		push_error("load failed: %s (%d)" % [gltf_path, err])
		get_tree().quit(1)
		return
	var model := doc.generate_scene(state)
	add_child(model)

	var aabb := _combined_aabb(model)
	print("AABB position=", aabb.position, " size=", aabb.size)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-35, 140, 0)
	sun.light_energy = 1.3
	add_child(sun)
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(20, -40, 0)
	fill.light_energy = 0.4
	add_child(fill)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.02, 0.02, 0.04)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.25, 0.27, 0.32)
	e.ambient_light_energy = 0.6
	env.environment = e
	add_child(env)

	var cam := Camera3D.new()
	var center := aabb.get_center()
	var radius: float = aabb.size.length() * 0.5
	if radius < 0.01:
		radius = 10.0
	cam.position = center + view_dir.normalized() * radius * 2.2
	var up := Vector3.UP if absf(view_dir.normalized().y) < 0.95 else Vector3.FORWARD
	cam.look_at_from_position(cam.position, center, up)
	cam.far = max(4000.0, radius * 10.0)
	add_child(cam)
	cam.make_current()

	await get_tree().process_frame
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var abs_out := base.path_join(out_path)
	DirAccess.make_dir_recursive_absolute(abs_out.get_base_dir())
	img.save_png(abs_out)
	print("saved ", abs_out)
	get_tree().quit(0)

func _combined_aabb(node: Node) -> AABB:
	var total := AABB()
	var first := true
	for child in node.find_children("*", "MeshInstance3D", true, false):
		var mi := child as MeshInstance3D
		var ab: AABB = mi.global_transform * mi.get_aabb()
		total = ab if first else total.merge(ab)
		first = false
	return total
