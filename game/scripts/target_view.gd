class_name TargetView
extends SubViewport
# The MFD's EO FEED: a live 3D render of the currently targeted object
# (the original shows the actual model, camera-feed style). Models are
# loaded once per avatar path and swapped in as the target changes.

var main: Node3D
var enabled := false          # hud sets this while the MFD feed is on screen
var _cache: Dictionary = {}   # avatar rel path -> Node3D (kept out of tree)
var _current := ""
var _model: Node3D
var _pivot: Node3D
var _t := 0.0

func _ready() -> void:
	size = Vector2i(200, 110)
	own_world_3d = true
	transparent_bg = true
	render_target_update_mode = SubViewport.UPDATE_DISABLED
	var cam := Camera3D.new()
	cam.position = Vector3(0, 0.25, 2.6)
	cam.fov = 30.0
	add_child(cam)
	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-35, 40, 0)
	key.light_energy = 1.2
	add_child(key)
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(20, -140, 0)
	fill.light_energy = 0.35
	add_child(fill)
	_pivot = Node3D.new()
	add_child(_pivot)

func show_avatar(rel: String) -> bool:
	# rel is a path under the project data dir ("data/avatars/..."); returns
	# whether a model is displayed
	if rel == _current:
		return _model != null
	if _model != null:
		_pivot.remove_child(_model)
		_model = null
	_current = rel
	if rel == "":
		return false
	if not _cache.has(rel):
		var node: Node3D = main._load_gltf(rel)
		if node != null:
			_fit(node)
		_cache[rel] = node
	_model = _cache[rel]
	if _model != null:
		_pivot.add_child(_model)
	return _model != null

func _fit(node: Node3D) -> void:
	# normalize to unit size so the fixed camera frames anything
	var merged := AABB()
	var first := true
	for mi in node.find_children("*", "MeshInstance3D", true, false):
		var bb: AABB = (mi as MeshInstance3D).get_aabb()
		var xf: Transform3D = (mi as Node3D).transform
		var n: Node = mi.get_parent()
		while n != node and n is Node3D:
			xf = (n as Node3D).transform * xf
			n = n.get_parent()
		var tb := xf * bb
		merged = tb if first else merged.merge(tb)
		first = false
	if first:
		return
	var r := maxf(merged.size.length() * 0.5, 0.001)
	node.scale = Vector3.ONE / r
	node.position = -(merged.get_center()) / r

func _exit_tree() -> void:
	# cached models not currently parented would leak at exit (Nodes are
	# not refcounted)
	for rel in _cache:
		var n: Node3D = _cache[rel]
		if n != null and n != _model and not n.is_inside_tree():
			n.free()
	_cache.clear()

func _process(delta: float) -> void:
	var active := _model != null and enabled
	render_target_update_mode = SubViewport.UPDATE_ALWAYS if active \
		else SubViewport.UPDATE_DISABLED
	if active:
		_t += delta
		_pivot.rotation.y = _t * 0.5
		_pivot.rotation.x = 0.25
