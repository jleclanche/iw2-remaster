# Main layer: environment, sky, system loading, planets, streaming.
# Part of main.gd's extends chain -- see
# main_state.gd for the scheme. Same node, same class.
extends "main_collision.gd"

func _build_environment() -> void:
	# The original lights a system with exactly the geog LWS's two DISTANT
	# lights, <star> and <fill> (FcScene's LWS parser registers LightColor /
	# LgtIntensity / LightType and friends but NOT AmbientColor/AmbIntensity,
	# so the scene's ambient row is ignored). There is no ambient term and no
	# sky contribution: faces away from both lights are black. Our old rig
	# added a 0.7 grey ambient and flattened <fill> into it -- that was the
	# "washed out" look on unlit hulls.
	sun = DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-20, 60, 0)
	sun.light_energy = 1.4
	add_child(sun)
	fill_sun = DirectionalLight3D.new()
	fill_sun.light_energy = 0.0
	add_child(fill_sun)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	# D3D7 clears to black and the sky is drawn objects only: icStarfieldAvatar
	# points + the icNebulaAvatar cyclorama. An original-game screenshot's
	# empty-sky pixels equal the backdrop texture's dark texels byte-for-byte
	# ((8,44,7) in Hoffer's Wake), so there is NO ambient pedestal of any kind.
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color.BLACK
	e.ambient_light_source = Environment.AMBIENT_SOURCE_DISABLED
	e.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
	# the original has no post-processing at all -- D3D7 scanned the frame out
	# raw. Godot's glow bloom smeared the (already screen-dominating) sun
	# flare quads into full-screen saturation.
	e.glow_enabled = false
	env.environment = e
	env_ref = e
	add_child(env)
	_build_grid()

func _setup_sky(stem: String) -> void:
	# per-system sky from the original geog/*.lws: nebula backdrop model,
	# starfield tint/density, star + fill light colors, neighbor-star flares
	if sky_anchor != null:
		sky_anchor.queue_free()
	sky_anchor = Node3D.new()
	add_child(sky_anchor)
	var geo: Variant = null
	for cluster in ["badlands", "gagarin", "multiplayer"]:
		geo = _load_json("data/json/scenes/geog/%s/%s.json" % [cluster, stem])
		if geo != null:
			break
	if geo == null:
		return
	var sys_parent := Vector3.ZERO
	for n in geo["nodes"]:
		if str(n.get("name", "")) == "SystemParent" and n.has("pos"):
			sys_parent = Vector3(n["pos"][0], n["pos"][1], n["pos"][2])
	for n in geo["nodes"]:
		match str(n.get("kind", "")):
			"node":
				var cls := str(n.get("class", ""))
				if cls == "icNebulaAvatar":
					var mstem := str(n.get("url", "")).split("|")[-1].to_lower()
					var neb := _load_gltf("data/gltf/models/%s.gltf" % mstem)
					if neb != null:
						_make_additive(neb)
						sky_anchor.add_child(neb)
						# push the camera-anchored dome out near the far
						# plane so nearby geometry occludes it — at small
						# scales the additive backdrop painted OVER stations
						var r := _model_bounds_radius(neb)
						neb.scale = Vector3.ONE * (4.8e5 / maxf(r, 1.0))
				elif cls == "icStarfieldAvatar":
					_add_starfield(n)
			"light":
				var col := Color.WHITE
				if n.has("color"):
					col = Color(n["color"][0] / 255.0, n["color"][1] / 255.0,
						n["color"][2] / 255.0)
				match str(n.get("name", "")):
					"<star>":
						# a LightWave DISTANT light: colour x LgtIntensity,
						# aimed by the scene's heading/pitch
						sun.light_color = col
						sun.light_energy = float(n.get("intensity", 1.0))
						_aim_distant_light(sun, n)
					"<fill>":
						# the second DISTANT light -- directional, NOT ambient;
						# in every badlands scene it faces away from <star>, so
						# double-shadowed faces stay black like the original
						fill_sun.light_color = col
						fill_sun.light_energy = float(n.get("intensity", 1.0))
						_aim_distant_light(fill_sun, n)
					_:
						if int(n.get("light_type", 0)) == 1 \
								and n.get("lens_flare", false) and n.has("pos"):
							# LW bank-180 SystemParent: (x,y) -> (-x,-y)
							var p := Vector3(-n["pos"][0], -n["pos"][1],
								n["pos"][2]) + sys_parent
							if p.length() > 100.0:
								_add_sky_flare(p, n, col)

func _aim_distant_light(light: DirectionalLight3D, n: Dictionary) -> void:
	# LightWave: a light with H=P=0 shines along +Z; heading rotates about +Y,
	# pitch about +X (positive pitch tips the beam down). LW +Z maps to our -Z.
	var hpb: Array = n.get("hpb", [0.0, 0.0, 0.0])
	var h := deg_to_rad(float(hpb[0]))
	var p := deg_to_rad(float(hpb[1]))
	var dir_lw := Vector3(sin(h) * cos(p), -sin(p), cos(h) * cos(p))
	var dir := Vector3(dir_lw.x, dir_lw.y, -dir_lw.z)
	# DirectionalLight3D shines along its local -Z
	light.global_transform.basis = Basis.looking_at(dir,
		Vector3.RIGHT if absf(dir.y) > 0.99 else Vector3.UP)

func _parse_tuple(t: String, fallback: Vector3) -> Vector3:
	var parts := t.trim_prefix("(").trim_suffix(")").split(",")
	if parts.size() >= 3:
		return Vector3(float(parts[0]), float(parts[1]), float(parts[2]))
	return fallback

## NB the avatar LWS scenes carry their own light records (player_base:
## one white DISTANT lamp). Do NOT recover them onto streamed models: we
## tried, and the flood-lit result contradicts the original's render --
## the base's tunnel is dark and sun-shaded there, so the engine treats
## those as the modeller's preview lights, not runtime ones.
func _add_sky_flare(dir_lw: Vector3, n: Dictionary, col: Color) -> void:
	# A geog scene light with LensFlare becomes an FcLensFlareNode
	# (FcAvatarLoader::MakeLight, flux @ 0xdc3f0):
	#  - the flare's intensity envelope is FlareIntensity (LgtIntensity only
	#    drives the light itself);
	#  - style: LensFlareOptions bit 2 -> FlareStarFilter <= 4 ? 4-point star
	#    : 6-point star; else bit 3 -> sharp glow; else soft glow. The
	#    badlands lights are all options 7 / filter 2 -> the 4-point star;
	#  - the blue anamorphic streak needs options bit 6 (none set it);
	#  - Render (0xe6100): apparent half-angle = atan(m_intensity_scale(15) x
	#    intensity), vertex colour = LightColor squared.
	var dir := Vector3(dir_lw.x, dir_lw.y, -dir_lw.z).normalized()
	var intensity := float(n.get("flare_intensity", 0.01))
	var opts := int(n.get("flare_options", 7))
	var style := 0
	if opts & 4:
		style = 2 + (1 if int(n.get("flare_star_filter", 2)) > 4 else 0)
	elif opts & 8:
		style = 1
	var tex := StarFx.style_texture(style, _base())
	if tex == null or intensity <= 0.0:
		return
	var mi := FlareQuad.create(tex)
	mi.intensity = intensity
	mi.tint = Color(col.r * col.r, col.g * col.g, col.b * col.b)
	mi.position = dir * 4.5e5
	sky_anchor.add_child(mi)

func _make_additive(node: Node3D) -> void:
	# icNebulaAvatar (0x100cb520) forces every backdrop material additive at
	# alpha 0.99, and D3D7 both FILTERS and BLENDS in the stored gamma bytes.
	# Godot sRGB-decodes BEFORE the bilinear filter (--srgbprobe: texel
	# centres round-trip byte-exact, but interpolated samples land in linear
	# space), which perceptually collapses the dark end of every texel ramp
	# into hard ~1-texel stair-steps on the 256^2 cyclorama faces. So sample
	# the texture RAW (no source_color: hardware filters the gamma bytes like
	# D3D7 did) and apply the sRGB decode AFTER filtering; the framebuffer's
	# final linear->sRGB scanout then restores the gamma-space lerp exactly.
	for mi in node.find_children("*", "MeshInstance3D", true, false):
		var m: MeshInstance3D = mi
		for i in m.get_surface_override_material_count():
			var mat := m.mesh.surface_get_material(i)
			if mat is StandardMaterial3D:
				var std: StandardMaterial3D = mat
				if std.albedo_texture != null:
					var sm := ShaderMaterial.new()
					sm.shader = _additive_backdrop_shader()
					sm.set_shader_parameter("albedo_tex", std.albedo_texture)
					# the deepest painter slot (PRIORITY_PLANET note): this
					# camera-anchored dome sits 480 km out and would otherwise
					# distance-sort in FRONT of every planet
					sm.render_priority = PRIORITY_SKY
					m.set_surface_override_material(i, sm)
				else:
					var dup: StandardMaterial3D = std.duplicate()
					dup.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
					dup.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
					dup.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
					dup.cull_mode = BaseMaterial3D.CULL_DISABLED
					dup.render_priority = PRIORITY_SKY
					m.set_surface_override_material(i, dup)

func _additive_backdrop_shader() -> Shader:
	if backdrop_shader != null:
		return backdrop_shader
	backdrop_shader = Shader.new()
	backdrop_shader.code = """
shader_type spatial;
render_mode unshaded, blend_add, cull_disabled;
uniform sampler2D albedo_tex : filter_linear, repeat_enable;
void fragment() {
	// gamma-space bilinear result, then icNebulaAvatar's forced alpha 0.99
	vec3 g = texture(albedo_tex, UV).rgb * 0.99;
	// exact sRGB->linear so the swapchain's linear->sRGB restores g
	ALBEDO = mix(g / 12.92, pow((g + vec3(0.055)) / 1.055, vec3(2.4)),
		step(vec3(0.04045), g));
}
"""
	return backdrop_shader

func _build_grid() -> void:
	# icHUDReferenceGrid: a 9x9x9 lattice of streaks pointing back along the
	# velocity vector, decoded from iwar2.dll FUN_100f5550 (see docs/hud.md)
	space_fx = SpaceFx.new()
	add_child(space_fx)
	# capsule space (the between-systems tunnel), inert until a jump enters it
	capsule = CapsuleFx.new()
	add_child(capsule)
	# LDSI boundary fence: vertical pillars marking the inhibition limit
	ldsi_mat = StandardMaterial3D.new()
	ldsi_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	ldsi_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	ldsi_mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	ldsi_mat.vertex_color_use_as_albedo = true
	ldsi_mesh = ImmediateMesh.new()
	var lm := MeshInstance3D.new()
	lm.mesh = ldsi_mesh
	add_child(lm)

func _update_ldsi_fence() -> void:
	# the original visualized the LDS-inhibition boundary near the player:
	# a curtain of vertical green pillars at the zone's edge
	ldsi_mesh.clear_surfaces()
	if docked_at != "" or jump_state != 0:
		return
	var b := _nearest_inhibitor()
	if b.is_empty() or absf(float(b["clear"])) > 2.0e4:
		return
	var center: Vector3 = b["center"]
	var r: float = b["r"]
	var flat := Vector3(-center.x, 0, -center.z)  # ship dir in zone plane
	if flat.length() < 1.0:
		flat = Vector3.FORWARD
	var base_a := atan2(flat.z, flat.x)
	ldsi_mesh.surface_begin(Mesh.PRIMITIVE_LINES, ldsi_mat)
	for i in range(-14, 15):
		var a := base_a + i * (2400.0 / r)  # ~2.4 km pillar spacing
		var p := center + Vector3(cos(a), 0, sin(a)) * r
		var dist := p.length()
		var alpha := clampf(1.0 - dist / 3.0e4, 0.0, 0.6)
		if alpha <= 0.01:
			continue
		ldsi_mesh.surface_set_color(Color(0.3, 1.0, 0.45, alpha))
		ldsi_mesh.surface_add_vertex(p + Vector3(0, -900, 0))
		ldsi_mesh.surface_set_color(Color(0.3, 1.0, 0.45, alpha * 0.15))
		ldsi_mesh.surface_add_vertex(p + Vector3(0, 900, 0))
	ldsi_mesh.surface_end()

func _update_grid() -> void:
	# no HUD underlay inside capsule space: the capsule system renders only
	# its own scene graph (icCapsuleSpaceSystem::Render @ 0x100481e0), and
	# the director is in cinematic mode for the whole effect
	space_fx.update_grid(cam, px, py, pz, ship.velocity,
		lds_state == 2, docked_at != "" or jump_state >= 3)
	# @element icAggressorAvatar -- up exactly while the shield's "fire" channel
	# is 1 (icAggressorShield::Simulate 0x1002f44f)
	if sys != null and ship != null:
		# the shell is sized off the hull's own width/height/length
		# (icAggressorShield::Simulate 0x1002f464)
		space_fx.set_aggressor(_base(), sys.aggressor_active(),
			ship.global_transform,
			Vector3(float(ship_stats.get("width", 80)),
				float(ship_stats.get("height", 70)),
				float(ship_stats.get("length", 120))))
	_update_contrails()

# @element icHUDContrails
## The trail feed: the player's own ship always takes the first of the eight
## slots (icHUD+0x104), then the contacts. `width` is icShip::width (+0x208), the
## ship INI's `width` -- it is the wingspan the player's ladder is drawn to.
func _update_contrails() -> void:
	var ships: Array = []
	if ship != null:
		ships.append({"node": ship, "vel": ship.velocity, "player": true,
			"width": float(ship_stats.get("width", 80)),
			"lds": lds_state == 2, "col": Hud.AMBER})
	for a in ai_ships:
		if not is_instance_valid(a):
			continue
		# per-contact IFF colour (the point's [7..9] floats read the colour
		# FUN_100e8530 wrote at ship +0x1c) -- the same table as the brackets
		ships.append({"node": a, "vel": a.velocity, "player": false,
			"width": 0.0, "lds": false,
			"col": hud._contact_color(_is_hostile(a), "traffic",
					str(a.faction))})
	space_fx.update_contrails(get_physics_process_delta_time(), ships,
		docked_at != "" or jump_state >= 3)

# icStarfieldAvatar (iwar2 @ 0xd1000 Render, 0xd0d80 OnPropertiesChanged):
# bright stars are SINGLE-PIXEL additive points through SetPixelCamera, one
# per m_bright_star_count, colour m_tint x intensity, intensity =
# (1 - m_min_bright_star_intensity) * rand16[i & 15]
#   + m_min_bright_star_intensity        (min 0.4 @ 0x1011d1e0)
# with the 16 rand() intensities and the star directions generated ONCE per
# property change from srand(m_seed) -- no per-frame twinkle. Dim stars only
# exist when the scene sets high_quality (static default false; 0xd0d80
# zeroes m_dim_star_count otherwise); at rest their layer runs at
# (1 - 0.15 @ 0x1011b354) * m_max_dim_star_intensity (0.65 @ 0x1011d1e4).
# Rotation streaks (points stretch into lines) are NOT ported yet.
func _add_starfield(n: Dictionary) -> void:
	var bright := int(n.get("bright_star_count", 0))
	var dim := int(n.get("dim_star_count", 0)) \
			if bool(n.get("high_quality", false)) else 0
	if bright + dim <= 0:
		return
	var tint := _parse_tuple(str(n.get("tint", "")), Vector3.ONE)
	var rng := RandomNumberGenerator.new()
	# ctor default seed 314159276 (@ 0x10161ea4); the LCG stream itself is
	# msvcrt rand(), which we do not reproduce -- positions are cosmetic.
	rng.seed = int(n.get("seed", 314159276))
	var levels: Array[float] = []
	for i in 16:
		levels.append(0.4 + (1.0 - 0.4) * rng.randf())
	var pts := PackedVector3Array()
	var cols := PackedColorArray()
	for i in bright + dim:
		# uniform direction on the sphere, pushed out by the same camera-
		# anchored sky radius the cyclorama dome uses
		var z := rng.randf_range(-1.0, 1.0)
		var phi := rng.randf_range(0.0, TAU)
		var r := sqrt(maxf(0.0, 1.0 - z * z))
		pts.append(Vector3(r * cos(phi), r * sin(phi), z) * 4.7e5)
		var lum := levels[i & 15] if i < bright else (1.0 - 0.15) * 0.65
		cols.append(Color(tint.x * lum, tint.y * lum, tint.z * lum))
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = pts
	arrays[Mesh.ARRAY_COLOR] = cols
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_POINTS, arrays)
	var mat := ShaderMaterial.new()
	mat.shader = _starfield_shader()
	mat.render_priority = PRIORITY_SKY  # backdrop slot, behind the planets
	mesh.surface_set_material(0, mat)
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	# the points span the whole sky sphere; never frustum-cull the instance
	mi.custom_aabb = AABB(Vector3.ONE * -4.8e5, Vector3.ONE * 9.6e5)
	sky_anchor.add_child(mi)

func _starfield_shader() -> Shader:
	if starfield_shader != null:
		return starfield_shader
	starfield_shader = Shader.new()
	starfield_shader.code = """
shader_type spatial;
render_mode unshaded, blend_add;
void vertex() {
	POINT_SIZE = 1.0;
}
void fragment() {
	// vertex colour is the original's gamma-space star value; decode it so
	// the swapchain's linear->sRGB scanout restores it, like the cyclorama
	vec3 g = COLOR.rgb;
	ALBEDO = mix(g / 12.92, pow((g + vec3(0.055)) / 1.055, vec3(2.4)),
		step(vec3(0.04045), g));
}
"""
	return starfield_shader

# --- system loading -------------------------------------------------------

func _clear_system() -> void:
	for o in objects:
		if o["node"] != null:
			o["node"].queue_free()
	objects.clear()
	for a in ai_ships:
		a.queue_free()
	ai_ships.clear()
	if weapons != null:
		weapons.clear()
	if missiles != null:
		missiles.clear()
	target_idx = -1
	target_ai = null
	docked_at = ""
	if fields != null:
		fields.clear_system()

func _load_system(stem: String, entry_name := "", from_stem := "") -> void:
	_clear_system()
	system_stem = stem
	var sys: Dictionary = _load_json("data/json/systems/%s.json" % stem)
	system_name = str(sys["objects"][0]["name"])
	var entry := {}
	for o in sys["objects"]:
		var cat := str(o.get("category", "body"))
		if cat == "system":
			continue
		var rec := {
			"name": str(o["name"]), "category": cat,
			"x": float(o["pos"][0]), "y": float(o["pos"][1]),
			"z": -float(o["pos"][2]),
			# the f32 at record +0x138, i.e. what the engine hands to
			# FiSim::SetRadius. Not a map zone, not clamped.
			"radius": float(o.get("radius", 0.0)),
			"orientation": o.get("orientation", [1.0, 0.0, 0.0, 0.0]),
			"avatar": str(o.get("avatar", "")),
			"jumps": o.get("jumps_to_stems", []),
			"colors": o.get("colors", []),
			"renders": bool(o.get("renders", false)),
			"surface_class": str(o.get("surface_class", "")),
			"surface_textures": o.get("surface_textures", []),
			"atmosphere_texture": str(o.get("atmosphere_texture", "")),
			"ring_count": int(o.get("ring_count", 0)),
			"sun_texture": str(o.get("sun_texture", "")),
			"sun_colours": o.get("sun_colours", []),
			"node": null,
		}
		objects.append(rec)
		# a kind-4 belt record is a field ZONE, not a body: ParseAsteroidBeltInfo
		# (iwar2 @ 0x1004e6b0) reads the ring radius from the record's +0x134
		# (our JSON `info_f`), the width from +0x138 (our `radius`), and centres
		# the annulus on the PARENT geography's position. Inside it, the ambient
		# asteroid field runs (fields.gd).
		if cat == "belt" and fields != null:
			var par_i := int(o.get("parent", 0))
			var objs: Array = sys["objects"]
			var ppos: Array = [0.0, 0.0, 0.0]
			if par_i >= 0 and par_i < objs.size():
				ppos = objs[par_i].get("pos", ppos)
			fields.add_belt(float(o.get("info_f", 0.0)), rec["radius"],
				float(ppos[0]), float(ppos[1]), -float(ppos[2]),
				_record_basis(rec))
		# icPlanet::CreateAvatar only builds an avatar for 1 < IeBodyType < 5,
		# so most map bodies (and the system centre) are invisible markers.
		if rec["renders"] and (cat == "body" or cat == "star"):
			_spawn_impostor(rec)
		if entry_name != "" and rec["name"] == entry_name:
			entry = rec
	if entry.is_empty():
		# arrive at the L-point that links back to where we came from,
		# else at the system's first L-point
		for o in objects:
			if o["category"] != "lpoint":
				continue
			if entry.is_empty() or from_stem in o["jumps"]:
				entry = o
			if from_stem != "" and from_stem in o["jumps"]:
				break
	if entry.is_empty() and not objects.is_empty():
		entry = objects[0]
	last_entry = entry  # the capsule exit takes this L-point's orientation
	# the stock offset (~3.9 km) is fine beside an L-point, but Lucrecia's
	# Base's hull alone spans 4.7 km -- a debug spawn there starts you on (or
	# in) the structure. There is no authored debug spawn, so reuse the game's
	# OWN base standoff: ibacktobase's autoskip arrival, PlaceRelativeTo
	# (3000, 2000, 15000) in the base's frame pointing at it
	# (base_interior.gd SKIP_STANDOFF).
	var off := Vector3(2500.0, 300.0, 3000.0)
	var at_base: bool = str(entry.get("name", "")) == BaseInterior.BASE_NAME
	if at_base:
		off = _record_basis(entry) * Vector3(BaseInterior.SKIP_STANDOFF.x,
				BaseInterior.SKIP_STANDOFF.y, -BaseInterior.SKIP_STANDOFF.z)
	px = entry["x"] + off.x
	py = entry["y"] + off.y
	pz = entry["z"] + off.z
	if at_base and ship != null:
		var to := Vector3(entry["x"] - px, entry["y"] - py, entry["z"] - pz)
		ship.global_transform.basis = Basis.looking_at(to.normalized(),
				Vector3.UP)
	jump_sel = 0
	_setup_sky(stem)
	_spawn_traffic()
	# iBackToBase.Initialise: the base is on sensors -- and so in the contact
	# list -- in exactly one system, and only once the act's found-base flag is
	# set. See base_interior.gd.
	if base_iface != null:
		base_iface.apply_visibility()
	print("SYSTEM: ", system_name, " (", objects.size(), " objects)")

func _planet_texture(stem: String) -> ImageTexture:
	if stem.is_empty():
		return null
	var path := _base().path_join("data/textures/images/planets/%s.png" % stem)
	if not FileAccess.file_exists(path):
		return null
	var img := Image.load_from_file(path)
	if img == null:
		return null
	return ImageTexture.create_from_image(img)

func _surface_tint(rec: Dictionary, layer: int) -> Color:
	# icPlanet::SurfaceTint(n) = the record's colour n, scaled by 1/255
	# (icPlanet::ReadColour, _DAT_1011b068 = 0.00392157)
	var colors: Array = rec.get("colors", [])
	if layer >= colors.size():
		return Color.WHITE
	var c: Array = colors[layer]
	return Color(c[0] / 255.0, c[1] / 255.0, c[2] / 255.0)

## Planets are BACKDROP geometry, not scene geometry, and must not be lit by
## the geog scene's DISTANT lights.
##
## The original draws every body through the "Creating planets avatar" node
## (`DAT_10171e04`, built by `FUN_100ceb90` @ 0x100ceb90), which
## `icSolarSystem::Render` (0x1004d150) adds to the scene graph next to the
## cyclorama (`this+0x5c8`), gated on the same nebula-opacity test. That node
## carries `icPlanetAvatar`'s own shader (`FUN_100cdc50`); it never sees the
## `<star>` / `<fill>` FcLightNodes the geog scene ships.
##
## Those two lights are a STAGE RIG for ships and stations -- hoffers_wake
## authors `<star>` at hpb (180, 0, 0), a flat axis-aligned key that has no
## relation to where `Hoffer's Wake Alpha` actually sits. Shading a body with
## it put the terminator in an arbitrary place: Alexander (true radius 8.8e7 m
## at 1.5e8 m, a legitimate 62-degree disc at the spawn) turned its unlit face
## to the camera and rendered black, while still occluding -- which is what
## made the sky flares behind it wink out on rotation for no visible reason.
##
## So light a body from the real geometry: the direction from the body to its
## primary. `icPlanet` carries that star itself (the `icSun *` at `+0xbc` that
## FUN_100cdc50 reads for Class), so this is the engine's own association, not
## an invention.
##
## `depth_draw_never` is the second half, and it is the one that matters for
## the sky. The planets-avatar Render (vtable slot 16 @ 0x100cf220) wraps its
## whole draw in
##
##     FcGraphicsEngine::Push(0x10)
##     gfx+0x118 = 0.01 * 5 = 0.05     // this pass's own near clip
##     gfx+0x11c = 96000.0             //      "         "  far clip
##     FiShader::m_global_z_test = 0   // Z TEST OFF for the entire pass
##     ... Begin / Add(light) / Add(each planet) / Render / End ...
##     FiShader::m_global_z_test = 1
##     FcGraphicsEngine::Pop()
##
## -- a backdrop pass that puts NOTHING in the depth buffer, run right after
## the cyclorama and before the world. The FcLensFlareNodes that draw the
## neighbour-star flares DO depth-test (m_polygon_state eBlend 1 @ FUN_100e5cb0
## is "depth test on, depth write off"), so in the original they test against a
## buffer the planets never wrote to and shine straight over a planet's disc.
## Ours wrote depth from an opaque sphere, so an unlit body silently ate every
## flare behind it -- a 62-degree black hole in the sky that moved as you
## turned. Bodies still occlude correctly against ships and stations, which are
## drawn later and do write depth.
func _planet_shader() -> Shader:
	if planet_shader != null:
		return planet_shader
	planet_shader = Shader.new()
	planet_shader.code = """
shader_type spatial;
render_mode cull_back, depth_draw_never;
uniform sampler2D albedo_tex : source_color;
uniform vec4 tint : source_color;
uniform vec3 star_dir;   // world space, body -> its primary
uniform float ambient;   // the night side is dim, never pure black
uniform float alpha;
void fragment() {
	vec3 n = normalize((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
	float lam = max(dot(n, normalize(star_dir)), 0.0);
	vec4 t = texture(albedo_tex, UV);
	ALBEDO = t.rgb * tint.rgb * (ambient + (1.0 - ambient) * lam);
	ALPHA = t.a * alpha;
}
"""
	return planet_shader

# The sky is a painter-ordered stack in the original: the cyclorama dome +
# starfield, then the nebula layers, then the planets pass (0x100cf220,
# z-test off), then the world. Godot's transparent queue sorts by distance
# instead, which put the camera-anchored sky dome (480 km out) and the
# in-nebula wall in FRONT of Belial at Eureka's L-point. render_priority
# -40 (sky) < -30 (nebula, space_fx.gd) < -20 (bodies) < 0 (world)
# reproduces the original's order.
const PRIORITY_SKY := -40
const PRIORITY_PLANET := -20

func _planet_material(rec: Dictionary) -> ShaderMaterial:
	# icPlanetAvatar's shader (FUN_100cdc50 @ 0x100cdc50): layer 0 is
	# SurfaceType(0) out of planets.ini's rocky_ or gassy_planet_textures,
	# tinted by SurfaceTint(0).
	var mat := ShaderMaterial.new()
	mat.shader = _planet_shader()
	mat.render_priority = PRIORITY_PLANET
	var textures: Array = rec.get("surface_textures", [])
	if not textures.is_empty():
		mat.set_shader_parameter("albedo_tex", _planet_texture(str(textures[0])))
	mat.set_shader_parameter("tint", _surface_tint(rec, 0))
	mat.set_shader_parameter("ambient", PLANET_AMBIENT)
	mat.set_shader_parameter("alpha", 1.0)
	# a sane default until _stream_objects stamps the real one
	mat.set_shader_parameter("star_dir", Vector3.FORWARD)
	return mat

func _atmosphere_material(rec: Dictionary) -> ShaderMaterial:
	# the cloud layer: atmosphere_planet_textures[record +0x164], tinted with a
	# random blend of the two surface tints pulled toward white
	# same lighting rule as the surface: the cloud deck has a terminator too
	var mat := ShaderMaterial.new()
	mat.shader = _planet_shader()
	mat.render_priority = PRIORITY_PLANET
	mat.set_shader_parameter("albedo_tex",
		_planet_texture(str(rec["atmosphere_texture"])))
	var tint := _surface_tint(rec, 0).lerp(_surface_tint(rec, 1), 0.5) \
		.lerp(Color.WHITE, 0.6)
	mat.set_shader_parameter("tint", tint)
	mat.set_shader_parameter("ambient", PLANET_AMBIENT)
	mat.set_shader_parameter("alpha", 0.55)
	mat.set_shader_parameter("star_dir", Vector3.FORWARD)
	return mat

func _spawn_impostor(rec: Dictionary) -> void:
	if rec["category"] == "star":
		var star := StarFx.new()
		star.setup(rec, _base())
		add_child(star)
		rec["node"] = star
		return
	var node := Node3D.new()
	var mesh := SphereMesh.new()
	mesh.radius = 1.0
	mesh.height = 2.0
	mesh.radial_segments = 48
	mesh.rings = 24
	var surf_mat := _planet_material(rec)
	mesh.material = surf_mat
	# _light_body_from_primary stamps star_dir on these every frame
	var lit_mats: Array = [surf_mat]
	var body := MeshInstance3D.new()
	body.mesh = mesh
	node.add_child(body)
	if not str(rec["atmosphere_texture"]).is_empty():
		var shell := SphereMesh.new()
		shell.radius = ATMOSPHERE_HEIGHT
		shell.height = ATMOSPHERE_HEIGHT * 2.0
		shell.radial_segments = 48
		shell.rings = 24
		var atmo_mat := _atmosphere_material(rec)
		shell.material = atmo_mat
		lit_mats.append(atmo_mat)
		var atmo := MeshInstance3D.new()
		atmo.mesh = shell
		node.add_child(atmo)
	rec["lit_mats"] = lit_mats
	for i in int(rec["ring_count"]):
		node.add_child(_spawn_ring(rec, i))
	# The far glow: at range, the original shows a body as a bright star-like
	# flare (its FcLensFlareNode -- the reference's "Griffon" glow at 371
	# million km), which is both how you navigate and why a planet feels like
	# a real object growing as you approach. A tinted additive sun_halo
	# billboard, shown only while the true angular size is below the glow's.
	var glow := MeshInstance3D.new()
	glow.name = "FarGlow"
	var gq := QuadMesh.new()
	gq.size = Vector2(2, 2)
	var gm := StandardMaterial3D.new()
	gm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	gm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	gm.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	gm.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	gm.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	gm.disable_receive_shadows = true
	gm.albedo_texture = _planet_texture("sun_halo")
	var gtint := _surface_tint(rec, 0).lerp(Color.WHITE, 0.65)
	gm.albedo_color = Color(gtint.r, gtint.g, gtint.b, 0.9)
	gq.material = gm
	glow.mesh = gq
	glow.visible = false
	node.add_child(glow)
	add_child(node)
	rec["node"] = node

func _spawn_ring(rec: Dictionary, i: int) -> MeshInstance3D:
	# icPlanetAvatar (0x100cdc50) seeds an FcRandom from the body radius and,
	# for each of NumberOfRings(), draws a ring at FcRandom::Float(1.75, 2.44)
	# x the body radius, coloured by taking SurfaceTint(0)'s hue and scaling
	# its value by FcRandom::Float(0.2, 0.8). The width is NOT recovered.
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(str(rec["name"]) + str(i))
	var r := rng.randf_range(RING_MIN, RING_MAX)
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = _planet_texture("ring")
	var hsv := _surface_tint(rec, 0)
	mat.albedo_color = Color.from_hsv(hsv.h, hsv.s, rng.randf_range(0.2, 0.8), 0.7)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.render_priority = PRIORITY_PLANET
	var node := MeshInstance3D.new()
	node.mesh = _annulus_mesh(r - RING_WIDTH, r)
	node.mesh.surface_set_material(0, mat)
	return node

func _annulus_mesh(inner: float, outer: float) -> ArrayMesh:
	# a flat band in the body's equatorial plane
	const SEGMENTS := 96
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	for s in SEGMENTS:
		var a0 := TAU * s / SEGMENTS
		var a1 := TAU * (s + 1) / SEGMENTS
		var i0 := Vector3(cos(a0) * inner, 0.0, sin(a0) * inner)
		var o0 := Vector3(cos(a0) * outer, 0.0, sin(a0) * outer)
		var i1 := Vector3(cos(a1) * inner, 0.0, sin(a1) * inner)
		var o1 := Vector3(cos(a1) * outer, 0.0, sin(a1) * outer)
		var u0 := float(s) / SEGMENTS
		var u1 := float(s + 1) / SEGMENTS
		verts.append_array([i0, o0, o1, i0, o1, i1])
		uvs.append_array([Vector2(u0, 0), Vector2(u0, 1), Vector2(u1, 1),
			Vector2(u0, 0), Vector2(u1, 1), Vector2(u1, 0)])
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_TEX_UV] = uvs
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return mesh

func _spawn_beacon(rec: Dictionary) -> Node3D:
	# icHUDLagrangeIcon: the blue/red wireframe double funnel (docs/hud.md).
	# A mission waypoint record (imapentity.WaypointForEntity / mission.gd)
	# is an icHUDWaypointIcon instead: the wireframe cube (@ 0x10104380).
	var node: Node3D
	if rec.get("waypoint", false):
		node = SpaceFx.make_waypoint_icon()
	else:
		node = SpaceFx.make_lagrange_icon(_lpoint_axis(rec))
	add_child(node)
	return node

func _lpoint_axis(rec: Dictionary) -> Vector3:
	# The funnel is drawn in the L-point sim's frame with the jump axis on
	# local +Z (icLagrangePointWaypoint::TryToJump @ 0x1006ad40 refuses a jump
	# unless the ship's offset has local z < 0). That frame is the record's own
	# orientation quaternion at +0x120, which icSolarSystem::Load hands to
	# FiSim::SetOrientation; every L-point carries a real yaw there.
	return _record_basis(rec) * Vector3.FORWARD

func _spawn_traffic() -> void:
	# a couple of utility ships patrolling the start cluster
	var local: Array = []
	for o in objects:
		if o["category"] != "station":
			continue
		var d := Vector3(o["x"] - px, o["y"] - py, o["z"] - pz)
		if d.length() < 1.0e5:
			local.append(d)
	if local.size() < 2:
		return
	for i in 2:
		var ai := AiShip.new()
		ai.main = self
		ai.display_name = "Freighter %d" % (i + 1)
		ai.setup({"hit_points": 800, "speed": [100, 100, 300],
				"acceleration": [40, 40, 60], "yaw_rate": 20, "pitch_rate": 20,
				"roll_rate": 20})
		ai.avatar_path = "data/avatars/avatars/freighter/setup.gltf"
		var fmodel := _load_gltf(ai.avatar_path)
		ai.add_child(fmodel)
		ShipEffects.attach(ai, fmodel)
		# the authored hauler: real hull/armour/dims (and the dramatic death
		# its 133 m size buys); its clamps carry pods that spill on death
		ai.setup_ini("sims/ships/utility/freighter.ini", fmodel)
		ai.ctype = "Freighter"
		ai.carried_pods = 2 + (randi() % 3)
		ai.position = Vector3(local[0]) + Vector3(1500 + i * 900, i * 400, -2000)
		for w in local:
			ai.waypoints.append(Vector3(w))
		ai.wp = i % local.size()
		add_child(ai)
		ai_ships.append(ai)

func _fold_motion() -> void:
	var p := ship.global_position
	px += p.x
	py += p.y
	pz += p.z
	ship.global_position = Vector3.ZERO
	cam.global_position -= p
	drop_cam_pos -= p
	weapons.shift_world(p)
	missiles.shift_world(p)
	for fx in get_tree().get_nodes_in_group("worldfx"):
		fx.shift_world(p)
	for a in ai_ships:
		# a docked child (a pod racked on the Jafs) rides its parent's
		# transform; shifting it too would double-fold it
		if is_instance_valid(a) and not ((a as Node).get_parent() is AiShip):
			a.global_position -= p
	for sw in _shockwaves:
		sw["pos"] = (sw["pos"] as Vector3) - p
	space_fx.shift_world(p)  # the stored contrail points (FUN_100e5280)

## The body's terminator, from TRUE map positions -- the impostor's own
## position is a fiction (pulled to IMPOSTOR_DIST), so it cannot be used.
## `icPlanet` carries its `icSun *` at +0xbc; we recover that association as
## the nearest star record, which is what a system's primary is.
func _light_body_from_primary(o: Dictionary) -> void:
	var mats: Array = o.get("lit_mats", [])
	if mats.is_empty():
		return
	if not o.has("primary"):
		var best := INF
		var found: Dictionary = {}
		for s in objects:
			if str(s["category"]) != "star":
				continue
			var sdx: float = s["x"] - o["x"]
			var sdy: float = s["y"] - o["y"]
			var sdz: float = s["z"] - o["z"]
			var sd := sdx * sdx + sdy * sdy + sdz * sdz
			if sd < best:
				best = sd
				found = s
		o["primary"] = found
	var prim: Dictionary = o["primary"]
	if prim.is_empty():
		return
	var dir := Vector3(prim["x"] - o["x"], prim["y"] - o["y"],
			prim["z"] - o["z"]).normalized()
	for mat in mats:
		(mat as ShaderMaterial).set_shader_parameter("star_dir", dir)

func _stream_objects() -> void:
	# a scripted object is often created before the table that names it loads
	# (PogWorld.refresh_object_names); no-op unless a table landed since
	if pog_world != null:
		pog_world.refresh_object_names()
	# the original funnels only the nearest L-point
	# (icPlayerContactList::NearestLagrangePoint feeds icHUDLagrangeIcon)
	var near_lp: Dictionary = _nearest("lpoint", SpaceFx.LP_DRAW_DIST)
	for o in objects:
		var dx: float = o["x"] - px
		var dy: float = o["y"] - py
		var dz: float = o["z"] - pz
		var d2 := dx * dx + dy * dy + dz * dz
		# sim.SetCullable(sim, 0) = FiSim flag 0x40, DON'T CULL (sim.dll @
		# 0x10004a7e): the record streams in regardless of range and never
		# streams out -- cutscene actors and script waypoints must not vanish
		# at the 400 km world cull our STREAM_IN mirrors
		var sd2: float = 0.0 if o.get("no_cull", false) else d2
		match o["category"]:
			"body", "star":
				if o["node"] == null:
					continue
				# always visible: drawn at capped distance, scaled to keep
				# the correct angular size (the camera far plane is 600 km)
				var dist := sqrt(maxf(d2, 1.0))
				# the record's own FiSim radius. No floor, no clamp: the map
				# says what size the body is.
				var r: float = o["radius"]
				var k := minf(IMPOSTOR_DIST / dist, 1.0)
				# never fill the screen: cap apparent radius vs draw distance
				var draw_r := minf(r * k, IMPOSTOR_DIST * 0.4)
				if o["category"] == "star":
					# The star LIGHT is not re-aimed HERE, and that is a
					# behaviour choice, not a claim about the engine.
					#
					# CORRECTION. This comment used to assert that "no code
					# re-points it at the player". That is FALSE and it was
					# stated with unearned confidence. icSolarSystem::Render
					# (0x1004d150) does re-point a light every frame: it calls
					# FUN_1003e160 on `world+0x5d0`'s +0x38 (its POSITION) and
					# assigns its +0xf8 (its COLOUR) before the scene graph is
					# built. icPlanetAvatar's pass (0x100cf220) then adds that
					# same +0x5d0 node with its colour scaled by 0.8
					# (_DAT_1011959c) and restores it afterwards -- so bodies
					# are lit by a light the engine moves, not by a fixed one.
					# What is NOT re-pointed is the geog scene's <star>
					# FcLightNode, which icSolarSystem::OnBecomeActive
					# (0x1004c380) pulls with its AUTHORED rotation and only
					# recolours; that is the ship/station key light.
					#
					# We keep OUR directional `sun` on the authored heading
					# because re-aiming it along sun->player lit the wrong faces
					# of everything: Lucrecia's Base's docking mouth sat in
					# shadow that the original's fixed heading lights head-on.
					# Whether world+0x5d0 should drive a SECOND light for bodies
					# is open -- see _light_body_from_primary, which currently
					# approximates it from the nearest star record.
					# A sun is NEVER seen as a disc: the far plane (600 km)
					# cannot contain one at map distances (1e11..1e13 m). What
					# the player sees is icSun's pair of FcLensFlareNodes, and
					# StarFx sizes those itself (15 x intensity x depth, the
					# constant-apparent-size branch of flux 0xe6100) from the
					# distance in SUN RADII -- fed here with the engine's own
					# approximate magnitude (max + 0.34375*mid + 0.25*min,
					# iwar2 @ 0x1006b8xx via DAT_101191f0/DAT_101191ec).
					var ax := absf(dx)
					var ay := absf(dy)
					var az := absf(dz)
					var mx := maxf(ax, maxf(ay, az))
					var mn := minf(ax, minf(ay, az))
					var md := ax + ay + az - mx - mn
					(o["node"] as StarFx).d_radii = \
						(mx + 0.34375 * md + 0.25 * mn) / maxf(r, 1.0)
					o["node"].position = Vector3(dx, dy, dz) * k
					o["node"].scale = Vector3.ONE
					continue
				o["node"].position = Vector3(dx, dy, dz) * k
				o["node"].scale = Vector3.ONE * maxf(draw_r, 1.0)
				_light_body_from_primary(o)
				var fg: Node3D = o["node"].get_node_or_null("FarGlow")
				if fg != null:
					# the far flare: a fixed apparent size (~0.55 deg half-angle),
					# shown while the body's true disc is smaller than it
					var min_r := IMPOSTOR_DIST * 0.0096
					fg.visible = draw_r < min_r
					if fg.visible:
						fg.scale = Vector3.ONE * (min_r / maxf(draw_r, 1.0))
			"station", "prop", "gunstar":
				if o["node"] == null and sd2 < STREAM_IN * STREAM_IN:
					# POG can create a sim that carries no avatar (a pure logic
					# marker); there is nothing to stream in for those.
					if str(o.get("avatar", "")).is_empty():
						continue
					var model := _load_gltf("data/avatars/" + o["avatar"])
					if model == null:
						continue
					o["node"] = model
					add_child(model)
					# prefer the ini's real CollisionHull trimesh; sphere
					# blobs only when no hull ships for this avatar
					if not _attach_collision_hull(o, model):
						o["coll_spheres"] = _model_coll_spheres(model)
					# A station's map record carries no radius -- the byte at
					# +0x138 belongs to its parent body (docs/geography.md), so
					# the decoder zeroes it. The engine gets a station's
					# FiSim::Radius the same way it gets any sim's: from the
					# avatar. Everything that reasons about the station's size --
					# above all the approach marker the autopilot breaks off at --
					# needs it, so stamp it the moment the model exists.
					if float(o.get("radius", 0.0)) <= 0.0:
						o["radius"] = _model_bounds_radius(model)
				elif o["node"] != null and sd2 > STREAM_OUT * STREAM_OUT:
					o["node"].queue_free()
					o["node"] = null
				if o["node"] != null:
					o["node"].position = Vector3(dx, dy, dz)
			"lpoint":
				if o["node"] == null and sd2 < STREAM_IN * STREAM_IN:
					o["node"] = _spawn_beacon(o)
				elif o["node"] != null and sd2 > STREAM_OUT * STREAM_OUT:
					o["node"].queue_free()
					o["node"] = null
				if o["node"] != null:
					o["node"].position = Vector3(dx, dy, dz)
					# _nearest always stamps "dist", so has("name") is the
					# only reliable "did it find one" test
					if o.get("waypoint", false):
						SpaceFx.update_waypoint_icon(o["node"], cam)
					else:
						var lit: bool = near_lp.has("name") \
							and near_lp["name"] == o["name"]
						SpaceFx.update_lagrange_icon(o["node"], cam, lit)
