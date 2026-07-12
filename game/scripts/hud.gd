class_name Hud
extends Control
# IW2-style HUD: center reticle ring, target bracket + off-screen arrow,
# velocity/set-speed readouts (left), contact registry (right), status line,
# center warnings. Cyan for neutral/friendly, red for hostile â€” matching the
# original's palette. Drawn as vectors in the original's style.

var main: Node3D
var warning_text := ""
var warning_until := 0.0

const CYAN := Color(0.45, 0.85, 1.0, 0.9)
const CYAN_DIM := Color(0.45, 0.85, 1.0, 0.45)
const RED := Color(1.0, 0.35, 0.3, 0.95)
const FONT_SIZE := 15

var _font: Font

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_font = ThemeDB.fallback_font

func _screen() -> Vector2:
	return get_viewport_rect().size

func warn(text: String, seconds := 2.5) -> void:
	warning_text = text
	warning_until = Time.get_ticks_msec() / 1000.0 + seconds

func _process(_d: float) -> void:
	queue_redraw()

func _draw() -> void:
	if main == null or main.ship == null:
		return
	var c := _screen() / 2.0
	_draw_reticle(c)
	_draw_target()
	_draw_contacts()
	_draw_readouts()
	_draw_warnings(c)

func _draw_reticle(c: Vector2) -> void:
	draw_arc(c, 52.0, 0, TAU, 64, CYAN_DIM, 1.5, true)
	for i in 8:
		var a := TAU * i / 8.0
		var dir := Vector2(cos(a), sin(a))
		draw_line(c + dir * 46.0, c + dir * 52.0, CYAN, 1.5, true)
	# velocity vector marker: where the ship is actually going
	var vel: Vector3 = main.ship.velocity
	if vel.length() > 5.0:
		var cam: Camera3D = main.cam
		var ahead: Vector3 = main.ship.global_position + vel.normalized() * 5000.0
		if not cam.is_position_behind(ahead):
			var p := cam.unproject_position(ahead)
			draw_arc(p, 6.0, 0, TAU, 16, CYAN, 1.5, true)
			draw_line(p + Vector2(-12, 0), p + Vector2(-6, 0), CYAN, 1.5)
			draw_line(p + Vector2(6, 0), p + Vector2(12, 0), CYAN, 1.5)

func _bracket(p: Vector2, s: float, col: Color) -> void:
	for sx in [-1.0, 1.0]:
		for sy in [-1.0, 1.0]:
			var corner := p + Vector2(sx * s, sy * s)
			draw_line(corner, corner - Vector2(sx * s * 0.4, 0), col, 1.8, true)
			draw_line(corner, corner - Vector2(0, sy * s * 0.4), col, 1.8, true)

func _draw_target() -> void:
	var world: Vector3
	var tname := ""
	var hostile := false
	if main.target_ai != null and is_instance_valid(main.target_ai):
		world = main.target_ai.global_position
		tname = str(main.target_ai.name)
		hostile = main.target_ai.behavior == "attack"
	elif main.target_idx >= 0:
		var t: Dictionary = main.objects[main.target_idx]
		world = Vector3(t["x"] - main.px, t["y"] - main.py, t["z"] - main.pz)
		tname = str(t["name"])
	else:
		return
	var cam: Camera3D = main.cam
	var col: Color = RED if hostile else CYAN
	if cam.is_position_behind(world):
		_offscreen_arrow(world, col)
		return
	var p := cam.unproject_position(world)
	if not Rect2(Vector2.ZERO, _screen()).has_point(p):
		_offscreen_arrow(world, col)
		return
	_bracket(p, 22.0, col)
	var label := "%s  %s" % [tname, main._fmt_dist(main._target_distance())]
	draw_string(_font, p + Vector2(28, 4), label, HORIZONTAL_ALIGNMENT_LEFT,
			-1, FONT_SIZE, col)

func _offscreen_arrow(world: Vector3, col: Color) -> void:
	var cam: Camera3D = main.cam
	var local: Vector3 = cam.global_transform.affine_inverse() * world
	var dir2 := Vector2(local.x, -local.y).normalized()
	var c := _screen() / 2.0
	var edge := c + dir2 * (minf(_screen().x, _screen().y) / 2.0 - 40.0)
	var perp := Vector2(-dir2.y, dir2.x)
	draw_colored_polygon(PackedVector2Array([
		edge + dir2 * 14.0, edge + perp * 7.0, edge - perp * 7.0]), col)

func _draw_contacts() -> void:
	var x := _screen().x - 330.0
	var y := 40.0
	draw_string(_font, Vector2(x, y), "CONTACT REGISTRY", HORIZONTAL_ALIGNMENT_LEFT,
			-1, FONT_SIZE, CYAN_DIM)
	y += 8
	var list: Array = main.contact_list()
	for entry in list:
		y += 20
		if y > _screen().y - 120:
			break
		var col: Color = RED if entry["hostile"] else CYAN
		var mark := "> " if entry["targeted"] else "  "
		draw_string(_font, Vector2(x, y), "%s%-26s %10s" % [
			mark, str(entry["name"]).left(26), main._fmt_dist(entry["dist"])],
			HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE, col)

func _draw_readouts() -> void:
	var ship: ShipFlight = main.ship
	var x := 28.0
	var y := _screen().y - 150.0
	var lines := [
		"VEL %10s/s" % main._fmt_dist(ship.velocity.length()),
		"SET %8.0f m/s" % (ship.throttle * ship.max_speed.z),
		"THR %6d%%" % int(ship.throttle * 100),
		"FLIGHT ASSIST" if ship.assist else "FREE FLIGHT",
	]
	match main.lds_state:
		1: lines.append("LDS SPOOLING")
		2: lines.append("LDS %s/s" % main._fmt_dist(main.lds_speed))
	if main.hull < main.hull_max:
		lines.append("HULL %d%%" % int(100.0 * main.hull / main.hull_max))
	if main.docked_at != "":
		lines = ["DOCKED: %s" % main.docked_at, "press U to undock"]
	for ln in lines:
		draw_string(_font, Vector2(x, y), ln, HORIZONTAL_ALIGNMENT_LEFT, -1,
				FONT_SIZE + 2, CYAN)
		y += 22

func _draw_warnings(c: Vector2) -> void:
	if Time.get_ticks_msec() / 1000.0 < warning_until:
		var w := _font.get_string_size(warning_text, HORIZONTAL_ALIGNMENT_CENTER,
				-1, FONT_SIZE + 6).x
		draw_string(_font, Vector2(c.x - w / 2.0, c.y - 110), warning_text,
				HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE + 6, RED)

