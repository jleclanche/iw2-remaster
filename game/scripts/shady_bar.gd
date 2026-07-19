class_name ShadyBar
extends RefCounted
# icShadyBar::Render (iwar2 @ 0x1010e7d0), the translucent column every menu in
# the game sits on. One renderer, because the front end and the base/PDA screens
# are the SAME engine control -- igui.CreateShadyBar builds it for both
# (igui.CreateMenu calls it for the main menu, igui.pog; the PDA screens call it
# directly, ipdagui.pog:940). base_screens.gd used to carry a reduced copy whose
# alphas and rates were its own admitted stand-ins; these are the extracted ones.
#
# The recipe, in draw order:
#   1. a solid black fill (m_bar_colour statics are zero @ 0x1010df20) at
#      m_bar_alpha 0.8 -- the value igui.pog calls GUI_shader_opacity;
#   2. ADDITIVELY, two drifting layers of the images/gui/bar_detail weave;
#   3. ADDITIVELY, up to 8 "text flyby" glyph strips sliding down the bar;
#   4. ADDITIVELY, amber edge gradients on both vertical edges.
#
# Steps 2-4 must land on an additive canvas and 1 on a normal-blend one, so the
# caller owns two layers and calls draw_fill / draw_fx on the matching one.

## m_bar_alpha, and igui.pog's GUI_shader_opacity.
const BAR_ALPHA := 0.8
## m_detail_alpha.
const DETAIL_ALPHA := 0.1
## m_edge_width, native px, and m_edge_alpha.
const EDGE_WIDTH := 8.0
const EDGE_ALPHA := 0.2
## The weave tile is 128 px and drifts at (t_ms * 0.001) / 20 texture/s
## (DAT_1011803c / DAT_1011e848 / m_u_scroll_rate) = 6.4 px/s, u positive and
## v negative. The second layer is the same texture at DOUBLE scale (the
## original also mirrors it in u; the weave is symmetric, so the mirror is a
## no-op and is skipped).
const WEAVE_TILE := 128.0
const WEAVE_DRIFT := 6.4
## m_flyby_cw / m_flyby_ch: the glyph column is 16 px wide, 13 px tall.
const FLYBY_W := 16.0
const FLYBY_H := 13.0
## m_min/max_flyby_speed (px/s) and the 3..30 row count @ 0x1010e200 / 0x1010e230.
const FLYBY_SPEED := Vector2(25.0, 90.0)
const FLYBY_ROWS := Vector2(3.0, 30.0)
## m_min/max_flyby_time: the gap before the next strip spawns.
const FLYBY_GAP := Vector2(0.0, 6.0)
## The flyby strips ramp to m_flyby_alpha (DAT_101184ac) at their bottom edge.
const FLYBY_ALPHA := 0.2
## The engine's fixed slot array.
const FLYBY_SLOTS := 8
## icShadyBar m_detail_colour / m_glow_colour: (1, 0.749, 0) -- static init
## @ 0x1010df80 (0x3f800000, 0x3f3fbfc0, 0).
const AMBER := Color(1.0, 0.749, 0.0)

var detail: Texture2D    ## images/gui/bar_detail, loaded by icShadyBar::Create
var flybys_tex: Texture2D  ## images/gui/text_flybys, same
var _slots: Array = []
var _timer := 0.0
var _t := 0.0


func _init() -> void:
	for _i in FLYBY_SLOTS:
		_slots.append({"h": 0.0})


## Load the two textures the control needs out of the game's own texture tree.
func load_textures(base: String) -> void:
	detail = _tex(base, "bar_detail.png")
	flybys_tex = _tex(base, "text_flybys.png")


static func _tex(base: String, name: String) -> Texture2D:
	var img := Image.load_from_file(
			base.path_join("data/textures/images/gui/" + name))
	if img == null:
		return null
	return ImageTexture.create_from_image(img)


## The flyby spawner. A strip enters from the TOP (y starts at 1 - height) and
## slides DOWN; x is random inside the edges, snapped to the glyph column.
func tick(delta: float, bar_w: float, screen_h: float) -> void:
	_t += delta
	for f in _slots:
		if f["h"] > 0.0:
			f["y"] += f["speed"] * delta
			if f["y"] > screen_h:
				f["h"] = 0.0
	_timer -= delta
	if _timer > 0.0:
		return
	_timer = randf_range(FLYBY_GAP.x, FLYBY_GAP.y)
	for i in _slots.size():
		var f: Dictionary = _slots[i]
		if f["h"] <= 0.0:
			f["h"] = FLYBY_H * randf_range(FLYBY_ROWS.x, FLYBY_ROWS.y)
			f["speed"] = randf_range(FLYBY_SPEED.x, FLYBY_SPEED.y)
			f["x"] = floorf(randf_range(EDGE_WIDTH,
					maxf(EDGE_WIDTH, bar_w - 3.0 * EDGE_WIDTH)) / FLYBY_W) * FLYBY_W
			f["y"] = 1.0 - f["h"]
			f["slot"] = i
			break


## Step 1, on a NORMAL-blend canvas.
func draw_fill(ci: CanvasItem, r: Rect2) -> void:
	ci.draw_rect(r, Color(0.0, 0.0, 0.0, BAR_ALPHA))


## Steps 2-4, on an ADDITIVE canvas, clipped to the bar.
func draw_fx(ci: CanvasItem, r: Rect2) -> void:
	_draw_weave(ci, r)
	_draw_flybys(ci, r)
	_draw_edges(ci, r)


func _draw_weave(ci: CanvasItem, r: Rect2) -> void:
	if detail == null:
		return
	var col := Color(AMBER.r, AMBER.g, AMBER.b, DETAIL_ALPHA)
	var drift := fmod(_t * WEAVE_DRIFT, WEAVE_TILE)
	# The weave TILES (the canvas has texture_repeat on) and scrolls, so it is
	# drawn as the bar rect with a moving source REGION rather than an oversized
	# destination -- the destination is exactly the bar, which is what keeps the
	# additive pass off the rest of the screen. u drifts positive, v negative.
	# The second layer is the same weave at double scale: same destination, a
	# half-size region.
	ci.draw_texture_rect_region(detail, r,
			Rect2(drift, -drift, r.size.x, r.size.y), col)
	ci.draw_texture_rect_region(detail, r,
			Rect2(drift * 0.5, -drift * 0.5, r.size.x * 0.5, r.size.y * 0.5), col)


## The strips' v is anchored to SCREEN space (v = y/128, DAT_1011ccb8 = 1/128):
## the glyphs stay put and the strip is a sliding reveal window. Alpha ramps from
## 0 at the top to FLYBY_ALPHA at the strip's bottom edge, and the glyph column
## flickers with the strip's position.
func _draw_flybys(ci: CanvasItem, r: Rect2) -> void:
	if flybys_tex == null:
		return
	var o := r.position
	var h := r.size.y
	for f in _slots:
		if f["h"] <= 0.0:
			continue
		var fy: float = f["y"]
		var fh: float = f["h"]
		var col_i: int = (int(fy + fh) + int(f["slot"])) & 7
		var y_end := minf(fy + fh, h)
		var row_y := maxf(fy, 0.0)
		while row_y < y_end:
			var rh := minf(FLYBY_H, y_end - row_y)
			var a := clampf((row_y + rh - fy) / fh, 0.0, 1.0) * FLYBY_ALPHA
			var col := Color(AMBER.r, AMBER.g, AMBER.b, a)
			var v := fposmod(row_y, WEAVE_TILE)
			var piece := minf(rh, WEAVE_TILE - v)
			ci.draw_texture_rect_region(flybys_tex,
					Rect2(o.x + f["x"], o.y + row_y, FLYBY_W, piece),
					Rect2(col_i * FLYBY_W, v, FLYBY_W, piece), col)
			if piece < rh:
				ci.draw_texture_rect_region(flybys_tex,
						Rect2(o.x + f["x"], o.y + row_y + piece,
							FLYBY_W, rh - piece),
						Rect2(col_i * FLYBY_W, 0.0, FLYBY_W, rh - piece), col)
			row_y += rh


## Brightest AT the edge, fading inward, on both vertical edges.
func _draw_edges(ci: CanvasItem, r: Rect2) -> void:
	var e0 := Color(AMBER.r, AMBER.g, AMBER.b, 0.0)
	var e1 := Color(AMBER.r, AMBER.g, AMBER.b, EDGE_ALPHA)
	var t := r.position.y
	var b := r.end.y
	var l := r.position.x
	var rr := r.end.x
	ci.draw_polygon(
			PackedVector2Array([Vector2(l, t), Vector2(l + EDGE_WIDTH, t),
				Vector2(l + EDGE_WIDTH, b), Vector2(l, b)]),
			PackedColorArray([e1, e0, e0, e1]))
	ci.draw_polygon(
			PackedVector2Array([Vector2(rr - EDGE_WIDTH, t), Vector2(rr, t),
				Vector2(rr, b), Vector2(rr - EDGE_WIDTH, b)]),
			PackedColorArray([e0, e1, e1, e0]))
