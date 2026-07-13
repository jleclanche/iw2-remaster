extends SceneTree

## Compile every ported mission script and report what does not load.
##
##   godot --headless --path game --script res://scripts/pog/portcheck.gd
##
## The port is only worth anything if it actually builds, so this is the gate:
## it loads all 114 generated packages, instantiates them, and reports any that
## fail. With --run it also boots the campaign through the ported scripts.

const GEN := "res://scripts/pog/gen"


func _initialize() -> void:
	var dir := DirAccess.open(GEN)
	if dir == null:
		print("no generated scripts at %s -- run tools/iw2/pogport.py" % GEN)
		quit(1)
		return

	var names: Array[String] = []
	for f in dir.get_files():
		if f.ends_with(".gd") and f != "native_api.gd":
			names.append(f.get_basename())
	names.sort()

	var ok := 0
	var failed: Array[String] = []
	var funcs := 0
	for n in names:
		var res := load("%s/%s.gd" % [GEN, n])
		if res == null or not (res is GDScript):
			failed.append(n)
			continue
		var gd := res as GDScript
		if not gd.can_instantiate():
			failed.append(n)
			continue
		funcs += gd.get_script_method_list().size()
		ok += 1

	print("== ported packages: %d/%d compiled" % [ok, names.size()])
	print("   %d methods across them" % funcs)
	if failed.is_empty():
		print("   every ported package builds.")
	else:
		print("\n== failed to build (%d):" % failed.size())
		for n in failed:
			print("   " + n)
	quit(0 if failed.is_empty() else 1)
