# Headless smoke test for the effect avatars (task #42): instantiates the
# recovered sun corona / shockwave / beam / LDA / movie players and steps a
# few frames.  Run from the repo root:
#   <godot> --path game --headless --script ../tools/godot_smoke_fx.gd
extends SceneTree

const MAIN_STUB := """
extends Node3D
var audio = null
var base_dir := ""
func _base() -> String: return base_dir
"""

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var base := ProjectSettings.globalize_path("res://").path_join("..")
	var cam := Camera3D.new()
	root.add_child(cam)
	cam.global_position = Vector3(0, 0, 50)

	# a stand-in for main.gd: _base() and audio are all ExplosionFx touches
	var stub := GDScript.new()
	stub.source_code = MAIN_STUB
	stub.reload()
	var main: Node3D = stub.new()
	root.add_child(main)
	main.set("base_dir", base)

	# sun
	var star: Node3D = load("res://scripts/star_fx.gd").new()
	root.add_child(star)
	star.setup({"name": "Test Star", "sun_texture": "sun_yellow",
			"sun_colours": [[1.0, 0.9, 0.5], [1.0, 1.0, 0.9]]}, base)
	star.scale = Vector3.ONE * 10.0

	var explosion := load("res://scripts/explosion_fx.gd")
	var keys := ["antimatter_explosion", "reactor_explosion", "lda_impact",
			"explosion", "hull_impact"]
	var spawned := 0
	for k in keys:
		var fx = explosion.call("play", main, k,
				Transform3D(Basis.IDENTITY, Vector3(0, 0, -20)), 10.0)
		print("play %-22s -> %s" % [k, fx])
		if fx != null:
			spawned += 1

	# step some frames so _process runs
	for i in 20:
		await process_frame
	print("smoke ok; spawned fx: %d" % spawned)
	explosion.call("release_cache")
	quit(0)
