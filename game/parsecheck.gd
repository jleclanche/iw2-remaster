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
	var layered := _check_layering(files)
	quit(0 if failed.is_empty() and layered else 1)


## The ported bytecode must not know what engine it is running on.
##
## gen/*.gd is ~208k generated lines and references ZERO Godot types: it calls
## the ORIGINAL's native API (gui.*, isim.*, iship.*) and nothing else. That is
## what makes the port movable -- a different engine means a new pogport backend
## plus a rewrite of natives/ (~10k lines), not of the 208k.
##
## It is true today because the porter happens not to emit engine types, which
## is not a guarantee. This makes it one.
##
## Whole-word matches on the type NAMES only: a POG identifier that merely
## CONTAINS one as a substring (a sim named "color_beacon", a function
## "load_cargo") must not trip it.
const ENGINE_TYPES: Array[String] = [
	"Vector2", "Vector3", "Vector4", "Transform2D", "Transform3D", "Basis",
	"Quaternion", "Color", "Node", "Node2D", "Node3D", "Control", "Resource",
	"PackedScene", "SceneTree", "Viewport", "Camera3D", "Engine",
	"RenderingServer", "DisplayServer", "AudioServer", "PhysicsServer3D",
	"get_tree", "get_viewport", "queue_free", "add_child", "preload",
]


func _check_layering(files: Array[String]) -> bool:
	var bad: Array[String] = []
	var re := RegEx.new()
	# The ported debug strings quote the original's own prose, which says
	# things like "Node group property not found" -- so match CODE only and
	# blank every string literal out of the line first.
	var lit := RegEx.new()
	lit.compile(r'"(?:[^"\\]|\\.)*"')
	re.compile(r"\b(%s)\b" % "|".join(ENGINE_TYPES))
	for path in files:
		if not path.begins_with("res://scripts/pog/gen/"):
			continue
		var text := FileAccess.get_file_as_string(path)
		if text.is_empty():
			continue
		var n := 0
		for line in text.split("\n"):
			n += 1
			var t := (line as String).strip_edges()
			if t.begins_with("#"):
				continue          # the generated header names the porter
			var m := re.search(lit.sub(t, "", true))
			if m != null:
				bad.append("%s:%d  %s" % [path, n, m.get_string(1)])
	if bad.is_empty():
		print("parsecheck: layering OK -- gen/ references no engine types")
		return true
	printerr("parsecheck LAYERING FAIL: the ported bytecode must stay ",
		"engine-agnostic (natives/ is the only layer that may know Godot):")
	for b in bad:
		printerr("  " + b)
	return false


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
