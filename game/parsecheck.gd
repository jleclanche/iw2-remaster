# Fast parse/analyzer gate: force-compiles every .gd in the project without
# booting the game, so identifier/type errors surface in seconds instead of
# a full --mechcheck run. Usage (from repo root):
#   godot --headless --path game --script res://parsecheck.gd
# Godot prints each SCRIPT ERROR with file/line as it compiles; exit code is
# 0 when every script compiled, 1 otherwise.
extends SceneTree


func _init() -> void:
	var files: Array[String] = []
	_walk("res://", files)
	files.sort()
	var failed: Array[String] = []
	for path in files:
		var script: GDScript = ResourceLoader.load(path, "GDScript",
				ResourceLoader.CACHE_MODE_REPLACE)
		if script == null or not script.can_instantiate():
			failed.append(path)
	print("parsecheck: %d scripts, %d failed" % [files.size(), failed.size()])
	for path in failed:
		printerr("parsecheck FAIL: " + path)
	quit(0 if failed.is_empty() else 1)


func _walk(dir_path: String, out: Array[String]) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		var path := dir_path.path_join(name)
		if dir.current_is_dir():
			if not name.begins_with("."):
				_walk(path, out)
		elif name.ends_with(".gd"):
			out.append(path)
		name = dir.get_next()
	dir.list_dir_end()
