class_name ShipEffects
extends Node
# @element icFlameConeAvatar
# The original's channel-driven effect rig (FcChannelGeneratorNode +
# icFlameConeAvatar). Ship state feeds named channels; avatar nodes tagged
# <anim channel=...> interpolate between their two exported poses by the
# channel value, and flame-cone nodes get a scrolling, textured additive cone.
#
# icFlameConeAvatar RECOVERED from iwar2.dll (Ghidra dropped its whole vtable
# cluster; raw-disassembled at the addresses below):
#   ctor        FUN_100bd350 @ 0x100bd350  (object size 0xdc)
#   Prepare     vtable[14]   @ 0x100bd5f0  -- scrolls a UV phase every frame
#   Draw        vtable[16]   @ 0x100bd630  -- builds/emits the cone
#   SetChannel  vtable[6]    @ 0x100bd5b0  -- parses the "channel" property
#   ring gens   0x100bd220 (cos) / 0x100bd260 (sin) / 0x100bd2a0 (axial)
#   registry    FUN_100bcf80 @ 0x100bcf80  -> RegisterClass(props @0x101713e0)
# Property map (FUN_100bd030 @ 0x100bd030): three authored properties --
#   "channel" (string, +0xd0)  -- an FcChannelExpression, parsed in SetChannel
#   "splay"   (float,  +0xbc, default 0.5)   -- ring radius scale
#   "tint"    (FcColour,+0xc0, default (1,1,0)) -- emitted colour
# What it DRAWS (0x100bd630): a 6-facet cone (cos/sin tables step pi/3, 7 verts
# with wrap) textured with texture:/images/sfx/plasma (bound once in the ctor
# @0x100bd3d3 into a shared sPolygonState @0x10171310, blend field = 2 =
# SRCALPHA/ONE alpha-weighted additive, z-write off). Colour = the "tint"
# property (FcColour copy @0x100bd67b). Ring radius = cos/sin * splay (+0xbc,
# fmul @0x100bd78c/0x100bd7a0). The channel value v = |Evaluate(channel)|
# (@0x100bd63e); if |v| < 1e-6 the Draw early-outs (invisible at idle).
# THE ANIMATION: Prepare (0x100bd5f0) advances a phase at +0xcc every frame:
#   phase -= game_delta * 0.5 (const @0x1011cbc4); wrap +1.0 when it passes 0.
# The Draw feeds that phase as the axial texture coordinate (+0x1788 <-[ebx+0xcc]
# @0x100bd711) so the turbulent plasma SCROLLS along the cone at 0.5/sec -- that
# scroll over the cloudy plasma noise is what makes the original read as "fire",
# and it moves at a HELD throttle. Per-vertex alpha grades v*globalalpha*0.6 at
# one ring (@0x100bd6ff/0x100bd705, const 0.6 @0x101192c4) to 1.0 at the other
# (@0x100bd7c6), so the flame brightens/fills as the channel rises. (The tail
# @0x100bd7ea, gated by 0x10173b74, sums the flame's screen coverage into a
# global bloom/glare accumulator at +0x37c -- not geometry; not reproduced.)
# The old stand-in was a flat untextured CylinderMesh at constant alpha with NO
# texture and NO scroll -- hence "flat and constant". Rebuilt below on the real
# behaviour: real plasma texture, TIME-scrolled V, channel-driven intensity.
#
# Channel strings are EXPRESSIONS in the original's little language
# (FcChannelEvaluator::Parse @ flux 0x100dd3e0, evaluate FUN_100ddae0):
#   "LZ?+s(1.0)"              positive fore thrust, rate-limited at 1.0/s
#   "RP?+j(0.1) LY?+j(0.1)"   RCS jet: pitch-up / thrust-up, 0.1 s puff
#   "fire?o(5.0)"             one-shot pulse on fire event, fast decay
# Space-separated terms combine by ARITHMETIC MEAN, then clamp [0,1]
# (flux.dll.c:207726-207737); s(t) is a LINEAR rate limit, and a bare
# name (no '?') is identity. Raw inputs: LZ/LX/LY (thrusters), RP/RY/RR
# (rotation demands), burn (BINARY forward yoke), fire, dock, v.
# avatars/tug_hull/channels.ini derives flame/core/boom/flap from these.

var ship: ShipFlight
var anim_nodes: Array = []   # {node, channel, p0..s1}
var flame_cones: Array = []  # {mat: ShaderMaterial, channel: String}
var glow_mats: Array = []    # {mat: StandardMaterial3D, channel: String} (#17)
var _jet_beams: Array = []   # {node: Node3D (icBeamAvatar), mi: MeshInstance3D}
var _signs: Array = []       # {mat, tex1, tex2, fps} (icSignAvatar flips)
var _sign_t := 0.0
var _engine_flares: Array = []  # {node, quad: FlareQuad, intensity, col}
var exprs: Dictionary = {}   # channel string -> {terms: Array, value: float}
var fire_pulse := 0.0        # set by weapons fire events
# sim.AvatarAddChannel / AvatarSetChannel / AvatarRemoveChannel (sim.dll) --
# FiSceneNode::SetChannelValue on the avatar root. The scripts drive cutscene
# ships through the SAME named inputs the expressions above read: 79 SetChannel
# calls set "lz" (a raw thruster input the generator also writes), and
# AddChannel/RemoveChannel bracket script-OWNED names the generator never
# writes ("league_off", "iasteroid_pre_damage", "fire"). Both cases land in one
# table because both are looked up the same way -- a script value simply wins
# over the ship-state value for as long as it is set.
var script_channels: Dictionary = {}
var _lz_smooth := 0.0
var _burn_smooth := 0.0
var _term_re: RegEx

# --flameshot: a self-contained capture mode (this script only) that forces the
# player tug to full burn and photographs the thrusters from an external camera
# across several frames, so the SCROLL animation is visible frame-to-frame.
var _flameshot := false
var _shot_cam: Camera3D
var _shot_t := 0.0
var _shot_n := 0
var _shot_settle := 0.0

static func attach(to_ship: ShipFlight, model: Node3D) -> ShipEffects:
	var fx := ShipEffects.new()
	fx.ship = to_ship
	fx._scan(model)
	to_ship.add_child(fx)
	to_ship.fx = fx
	return fx

static func graft_jets(target_model: Node3D, donor: Node3D) -> void:
	# move the donor's RCS jet rigs (anim channels with j() envelopes) onto
	# the target — the tug's jets live on its command section
	var anchor: Node3D = null
	for n in target_model.find_children("*", "Node3D", true, false):
		if "commandsection" in str(n.name).to_lower():
			anchor = n
			break
	if anchor == null:
		anchor = target_model
	var jets: Array = []
	for n in donor.find_children("*", "Node3D", true, false):
		if n.has_meta("extras"):
			var ex: Dictionary = n.get_meta("extras")
			if str(ex.get("iw2_kind", "")) == "anim" \
					and "j(" in str(ex.get("iw2_channel", "")):
				jets.append(n)
	for n in jets:
		var t: Transform3D = n.transform
		_clear_owner(n)
		n.get_parent().remove_child(n)
		anchor.add_child(n)
		n.transform = t
	donor.queue_free()

static func _clear_owner(n: Node) -> void:
	n.owner = null
	for c in n.get_children():
		_clear_owner(c)

func _extras(n: Node) -> Dictionary:
	return n.get_meta("extras") if n.has_meta("extras") else {}

func _scan(model: Node3D) -> void:
	_term_re = RegEx.new()
	_term_re.compile("^(\\w+)([?#])?([+-])?(.*)$")
	for n in model.find_children("*", "Node3D", true, false):
		var ex := _extras(n)
		if str(ex.get("iw2_kind", "")) == "anim" and ex.has("iw2_pose0"):
			var p0: Dictionary = ex["iw2_pose0"]
			var p1: Dictionary = ex["iw2_pose1"]
			var ch := str(ex.get("iw2_channel", ""))
			anim_nodes.append({
				"node": n, "channel": ch,
				"p0": _v3(p0["pos"]), "q0": _quat(p0["quat"]), "s0": _v3(p0["scale"]),
				"p1": _v3(p1["pos"]), "q1": _quat(p1["quat"]), "s1": _v3(p1["scale"]),
			})
			if not exprs.has(ch) and not ch in ["flame", "core", "boom", "flap"]:
				exprs[ch] = {"terms": _parse_expr(ch), "value": 0.0}
		if ex.has("iw2_glow_channels") and n is MeshInstance3D:
			# <glow channel=EXPR> surfaces (#17): the export tags the mesh
			# node with {primitive: expression}; each surface's emission
			# follows its channel instead of staying baked full-bright
			var chans: Dictionary = ex["iw2_glow_channels"]
			for idx in chans:
				var mi := n as MeshInstance3D
				var src := mi.get_active_material(int(str(idx)))
				if not (src is StandardMaterial3D):
					continue
				var mat: StandardMaterial3D = src.duplicate()
				mi.set_surface_override_material(int(str(idx)), mat)
				var gch := str(chans[idx])
				glow_mats.append({"mat": mat, "channel": gch})
				if not exprs.has(gch) \
						and not gch in ["flame", "core", "boom", "flap"]:
					exprs[gch] = {"terms": _parse_expr(gch), "value": 0.0}
		if str(ex.get("iw2_class", "")) == "icFlameConeAvatar":
			_add_flame_cone(n as Node3D, ex)
		if str(ex.get("iw2_class", "")) == "icBeamAvatar":
			_add_jet_beam(n as Node3D, ex)
		if str(ex.get("iw2_class", "")) == "icSignAvatar":
			_add_sign(n as Node3D, ex)
		if bool(ex.get("iw2_lens_flare", false)) \
				and ex.has("iw2_flare_intensity"):
			_add_engine_flare(n as Node3D, ex)

func _parse_expr(expr: String) -> Array:
	var terms: Array = []
	for tok in expr.split(" ", false):
		var m := _term_re.search(tok)
		if m == null:
			continue
		var mods: Array = []
		var mod_re := RegEx.new()
		mod_re.compile("([sjo])\\(([0-9.]+)\\)")
		for mm in mod_re.search_all(m.get_string(4)):
			mods.append([mm.get_string(1), float(mm.get_string(2))])
		terms.append({"input": m.get_string(1).to_lower(),
				"sign": m.get_string(3), "mods": mods, "state": 0.0,
				"last": 0.0})
	return terms

func _eval_term(term: Dictionary, raw: Dictionary, delta: float) -> float:
	var v: float = raw.get(term["input"], 0.0)
	# operators after '?': '+' positive part, '-' negative part, 'a' abs;
	# a BARE name is identity/passthrough (PTR_LAB_100ee050), not abs
	match term["sign"]:
		"+": v = maxf(v, 0.0)
		"-": v = maxf(-v, 0.0)
		"a": v = absf(v)
	for mod in term["mods"]:
		var tau: float = mod[1]
		match mod[0]:
			"s":  # LINEAR rate limit at tau units/s (FUN_100ddae0
				# @ flux.dll.c:207738-207751), NOT an exponential smooth:
				# move toward the target by at most delta * tau per frame
				term["state"] = move_toward(float(term["state"]), v, delta * tau)
				v = term["state"]
			"j":  # jet: instant attack, tau-second decay
				term["state"] = maxf(v, term["state"] - delta / maxf(tau, 0.01))
				v = term["state"]
			"o":  # one-shot: pulse on rising edge, decay at rate tau/s
				if v > 0.5 and term["last"] <= 0.5:
					term["state"] = 1.0
				term["state"] = maxf(0.0, term["state"] - tau * delta * 0.5)
				term["last"] = v
				v = term["state"]
	return v

func _v3(a: Array) -> Vector3:
	return Vector3(a[0], a[1], a[2])

func _quat(a: Array) -> Quaternion:
	return Quaternion(a[0], a[1], a[2], a[3]).normalized()

# texture:/images/sfx/plasma, bound in the ctor @0x100bd3d3. A cloudy grey
# noise sheet (no alpha) -- density rides in the luminance, per the engine's
# "particle textures carry no alpha" convention (particle_fx.gd @0x1004ffd0).
const FLAME_TEX := "images/sfx/plasma"

# blend field of the shared sPolygonState @0x10171314 = 2 -> SRCALPHA/ONE with
# z-write off: alpha-weighted additive (Godot blend_add + alpha == SRCALPHA/ONE).
# Prepare @0x100bd5f0 scrolls the axial texture coord at 0.5/sec over TIME so the
# turbulent noise flows down the cone; intensity gates the whole thing on the
# channel value (Draw early-outs when |v| < 1e-6). The grade term is the Draw's
# per-ring alpha ramp (0.6 @0x101192c4 at one ring, 1.0 at the other).
const FLAME_SHADER := """
shader_type spatial;
render_mode blend_add, depth_draw_never, cull_disabled, unshaded, shadows_disabled, fog_disabled;
uniform sampler2D plasma : source_color, filter_linear_mipmap, repeat_enable;
uniform vec3 tint = vec3(1.0, 1.0, 0.0);
uniform float intensity = 0.0;      // |channel value|, 0..1
uniform float scroll_rate = 0.5;    // iwar2 @ 0x1011cbc4 = 0.5/s (verified)
void fragment() {
	// V runs the cone axis: 0 at the nozzle, 1 at the tip. ONE plasma sheet
	// scrolled along the axis at 0.5/s (Prepare @0x100bd5f0 integrates the
	// phase; Draw feeds it into the axial coord). The original has no second
	// octave and no white-hot albedo boost -- the colour is a FLAT tint copy
	// (@0x100bd67b); all the motion is the single sliding sheet.
	float v = UV.y - TIME * scroll_rate;
	float density = texture(plasma, vec2(UV.x, v)).r;
	// Draw's per-ring alpha ramp: the nozzle ring at 1.0, the far ring at
	// 0.6 x channel value (0x101192c4 = 0.6, verified in .data). The channel
	// does NOT fade the whole cone -- visibility is the |v| < 1e-6 early-out
	// (the parent anim null's z-scale carries the length).
	float grade = mix(1.0, 0.6 * intensity, UV.y);
	ALBEDO = tint;
	ALPHA = intensity < 1e-6 ? 0.0 : clamp(density * grade, 0.0, 1.0);
}
"""

func _add_flame_cone(node: Node3D, ex: Dictionary) -> void:
	# tint default (1,1,0) = FcColour ctor defaults DAT_101713d0..d8
	var tint := Color(1.0, 1.0, 0.0)
	var t := str(ex.get("iw2_tint", ""))
	var floats: Array = []
	for part in t.trim_prefix("(").trim_suffix(")").split(","):
		if part.strip_edges().is_valid_float():
			floats.append(float(part.strip_edges()))
	if floats.size() >= 3:
		tint = Color(floats[0], floats[1], floats[2])
	# splay default 0.5 = DAT_1011cbc0 (ctor @0x100bd350, value read from
	# iwar2.dll .data); scales the ring radius
	var splay := float(ex.get("iw2_splay", 0.5))
	# 6-facet cone: cos/sin tables step pi/3 over 7 verts (gens @0x100bd220/60).
	# Wide at the nozzle (radius = splay), tapering to a near-point tip. The
	# parent <anim channel=flame> null's z-scale keys (-10..-40 in the tug LWS)
	# stretch this unit cone to full length, and its (4.5, 2.5) x/y scale gives
	# the elliptical mouth -- that machinery stays untouched.
	var mesh := CylinderMesh.new()
	mesh.top_radius = splay
	mesh.bottom_radius = maxf(0.02, splay * 0.05)
	mesh.height = 1.0
	mesh.radial_segments = 6
	mesh.rings = 8            # axial subdivisions so the V scroll interpolates smoothly
	mesh.cap_top = false
	mesh.cap_bottom = false
	var base := ProjectSettings.globalize_path("res://").path_join("..")
	var tex: Texture2D = ParticleFx.texture(base, FLAME_TEX)
	var sh := Shader.new()
	sh.code = FLAME_SHADER
	var mat := ShaderMaterial.new()
	mat.shader = sh
	mat.set_shader_parameter("plasma", tex)
	mat.set_shader_parameter("tint", Vector3(tint.r, tint.g, tint.b))
	mat.set_shader_parameter("intensity", 0.0)
	mesh.material = mat
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	# never culled: the plume is always drawn, and it can outrun the frustum cull
	mi.extra_cull_margin = 16384.0
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# cone along the parent's local -Z (LW-authored +Z, flipped by our
	# coordinate convention); wide nozzle end (+Y after the tilt) at the null
	# origin, tapering back out of the nozzle
	mi.rotation_degrees = Vector3(90, 0, 0)
	mi.position = Vector3(0, 0, -0.5)
	node.add_child(mi)
	flame_cones.append({"mat": mat, "node": node,
		"channel": str(ex.get("iw2_channel", "flame"))})

# The RCS jet visuals. In the setup LWS each <anim channel="RR?+j(0.1) ...">
# jet null (scale keys 1e-4 -> 1, driven by the channel rig above) carries a
# <node class=icBeamAvatar texture=jet_short> child, e.g. scale (0.5, 1, 2.5):
# a single axial-billboard quad (icBeamAvatar::Draw @ 0x100bb830, the same
# primitive explosion_fx.gd extracts) textured with images/sfx/jet_short,
# running z 0..1 along the node's LW +Z (our -Z), half-width = |x scale|.
# The jet puffs because the PARENT anim null scales 0 -> 1 with the channel
# value; the beam itself just follows its node's world basis every frame.
func _add_jet_beam(node: Node3D, ex: Dictionary) -> void:
	var base := ProjectSettings.globalize_path("res://").path_join("..")
	var tex := str(ex.get("iw2_texture", "jet_short")).to_lower()
	var mi := MeshInstance3D.new()
	mi.mesh = _beam_quad_mesh()
	mi.mesh.surface_set_material(0, ParticleFx.additive_material(
			ParticleFx.texture(base, "images/sfx/" + tex)))
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.extra_cull_margin = 64.0
	mi.visible = false
	add_child(mi)
	_jet_beams.append({"node": node, "mi": mi})

# The SHDR layer stack (lightmap #16, envmap #15, glow #59) is BAKED at
# export time (tools/iw2/bake.py): layered surfaces arrive as plain
# StandardMaterial3D with a pre-multiplied albedo atlas and, for glow
# surfaces, an emission atlas -- nothing to fix up here. Only the
# <glow channel=EXPR> emission ENERGY stays runtime-driven (glow_mats).
# Evidence for the stack itself: docs/original.md 7x.

# @element icSignAvatar
# Station signage (registry FUN_100cfeb0 @ 0x100cfeb0, vtable 0x1011d190;
# property map FUN_100cff60: "texture" +0xbc, "texture_2" +0xc0, "fps" +0xc4).
# Draw (vtable slot @ 0x100d0440 -- a Ghidra hole, raw-disassembled): one quad
# in the NODE'S LOCAL FRAME (no billboarding), x -0.5..+0.5, y 0..1 (the base
# sits ON the null, the null's scale sizes it), z 0, colour (1,1,1), v=0 at
# the top edge. Polygon state @ 0x10171e80 (init FUN_100d00f0): cull 0,
# blend 1 = pure additive, ztest on / z-write off -- additive_material's
# exact shape. Textures load through the "texture:" prefix (@ 0x1016172c,
# loader @ 0x100d0330). Two-texture signs flip on game time: phase =
# game_ms * 0.001 / fps (consts @ 0x10119458 / cmp 0.5 @ 0x10117738, code
# 0x100d047f..0x100d04d7); frac(phase) <= 0.5 draws texture, else texture_2.
# So "fps" is actually the FULL flip cycle in SECONDS (casinostation.lws
# authors fps 2..4 -- its neon flips every 1..2 s, not 2..4 times a second).
func _add_sign(node: Node3D, ex: Dictionary) -> void:
	var base := ProjectSettings.globalize_path("res://").path_join("..")
	var t1: Texture2D = ParticleFx.texture(
			base, str(ex.get("iw2_texture_path", "")))
	if t1 == null:
		return
	var quad := QuadMesh.new()
	quad.size = Vector2(1, 1)
	quad.center_offset = Vector3(0, 0.5, 0)
	var mi := MeshInstance3D.new()
	mi.mesh = quad
	mi.material_override = ParticleFx.additive_material(t1)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	node.add_child(mi)
	var t2: Texture2D = null
	if ex.has("iw2_texture_2_path"):
		t2 = ParticleFx.texture(base, str(ex["iw2_texture_2_path"]))
	var fps := float(ex.get("iw2_fps", 0))
	if t2 != null and fps > 0.0:
		_signs.append({"mat": mi.material_override,
				"tex1": t1, "tex2": t2, "fps": fps})

# unit beam quad: z 0..1 along the beam, x -1..1 across; u along the length,
# v across the width (icBeamAvatar mesh gen @ 0x100bbc6c..0x100bbd7e)
func _beam_quad_mesh() -> ArrayMesh:
	var verts := PackedVector3Array([
		Vector3(-1, 0, 0), Vector3(-1, 0, 1), Vector3(1, 0, 0),
		Vector3(1, 0, 0), Vector3(-1, 0, 1), Vector3(1, 0, 1),
	])
	var uvs := PackedVector2Array([
		Vector2(0, 0), Vector2(1, 0), Vector2(0, 1),
		Vector2(0, 1), Vector2(1, 0), Vector2(1, 1),
	])
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_TEX_UV] = uvs
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return mesh

# The engine GLOW: the cs_eng scene's two <light lens_flare> nodes
# (EngineFlare 242,196,53 FlareIntensity 0.15 options 15 filter 5 -> the
# 6-point star; EngineGlow FlareIntensity 0.3 options 3 -> the soft glow),
# both LensFlareFade 6 = flags 8|0x10 of FcLensFlareNode::Render
# (flux.dll.c:215184-215232): fixed WORLD size, and -- the key -- the
# envelope is MULTIPLIED by the node's world scale (FindWorldScale, +0xac),
# with the vertex alpha additionally x (2 x scale) below scale 0.5. The
# parent <anim channel="lz?+s(1.0)"> null scales 0 -> 1 with smoothed
# forward thrust, so the glow breathes with the drive. Style from
# LensFlareOptions bit2 + FlareStarFilter, as FcAvatarLoader::MakeLight maps.
func _add_engine_flare(node: Node3D, ex: Dictionary) -> void:
	var base := ProjectSettings.globalize_path("res://").path_join("..")
	var options := int(ex.get("iw2_flare_options", 0))
	var filt := int(ex.get("iw2_flare_star_filter", 0))
	var style := 0
	if options & 4:
		style = 2 if filt <= 4 else 3
	elif options & 8:
		style = 1
	var tex := StarFx.style_texture(style, base)
	if tex == null:
		return
	var q := FlareQuad.create(tex)
	q.world_size = true
	add_child(q)
	var col: Array = ex.get("iw2_color", [255, 255, 255])
	_engine_flares.append({
		"node": node, "quad": q,
		# Render's flag-8 size: envelope x FlareNominalDistance x the camera
		# half-angle factor (gfx+0x108) -- x15 and x world-scale downstream.
		# The tug's engine lights carry FlareNominalDistance 10; dropping it
		# was why the glow rendered a tenth of its real size.
		"intensity": float(ex.get("iw2_flare_intensity", 0.0)) \
			* float(ex.get("iw2_flare_nominal", 1.0)),
		# the render squares the colour (FcColour path at 215274-215282)
		"col": Color(pow(float(col[0]) / 255.0, 2.0),
				pow(float(col[1]) / 255.0, 2.0),
				pow(float(col[2]) / 255.0, 2.0)),
	})

func _update_engine_flares() -> void:
	for ef in _engine_flares:
		var n: Node3D = ef["node"]
		var q: FlareQuad = ef["quad"]
		if not is_instance_valid(n) or not n.is_inside_tree():
			q.intensity = 0.0
			continue
		# Render reads the node's world Z SCALE specifically (+0xac,
		# FindWorldScale @ flux.dll.c:213949) -- the axis the anim null's
		# length keys ride -- as the flag-0x10 modulator
		var ch := n.global_transform.basis.z.length()
		q.global_position = n.global_position
		q.intensity = float(ef["intensity"]) * ch
		var a := minf(2.0 * ch, 1.0)   # local_58: x 2*scale below 0.5
		var c: Color = ef["col"]
		q.tint = Color(c.r * a, c.g * a, c.b * a)
		q.core_level = a  # the white centre rides local_58

func _update_jet_beams() -> void:
	if _jet_beams.is_empty():
		return
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	for jb in _jet_beams:
		var n: Node3D = jb["node"]
		var mi: MeshInstance3D = jb["mi"]
		if not is_instance_valid(n) or not n.is_inside_tree():
			mi.visible = false
			continue
		var b := n.global_transform.basis
		# the node's basis carries the authored scale x the anim null's 0..1
		var w := b.x.length()
		var jlen := b.z.length()
		if w < 0.005:
			mi.visible = false
			continue
		# axial billboard (0x100bba92..0x100bbb38): the quad turns about its
		# own beam axis to face the camera
		var dir := (-b.z).normalized()
		var to_cam := (cam.global_position - n.global_position).normalized()
		var side := dir.cross(to_cam)
		if side.length() < 0.001:
			mi.visible = false
			continue
		side = side.normalized()
		mi.visible = true
		mi.global_transform = Transform3D(
				Basis(side * w, side.cross(dir), dir * jlen), n.global_position)

func _ready() -> void:
	# only the player tug (NPCs also carry a ShipEffects rig and would race us)
	_flameshot = "--flameshot" in OS.get_cmdline_user_args() \
		and ship != null and ship.name == "Player"
	if _flameshot:
		process_mode = Node.PROCESS_MODE_ALWAYS
		# force the drive on so the flame/burn channels sit at full, and pre-warm
		# the smoothers so the plume is at full length immediately
		if ship != null:
			ship.drive_override = true
		_lz_smooth = 1.0
		_burn_smooth = 1.0
		# force the RCS channels too, so the jet beams show in the captures
		for ch in ["rp", "ry", "rr", "lx", "ly"]:
			script_channels[ch] = 1.0
		# an external chase camera on the MAIN viewport (the front-end SubViewport
		# path renders a frozen world; the main window renders live like the check
		# harness). We make it current every frame to win over the game camera.
		_shot_cam = Camera3D.new()
		_shot_cam.far = 200000.0
		_shot_cam.fov = 55.0
		get_tree().root.add_child.call_deferred(_shot_cam)

func _flameshot_tick(delta: float) -> void:
	if ship == null or _shot_cam == null or not is_instance_valid(_shot_cam) \
			or not _shot_cam.is_inside_tree():
		return
	ship.drive_override = true          # hold full burn every frame
	# the cockpit view (cam_mode 0) hides ship_model -- force it visible so our
	# external camera can see the hull + plumes
	var mn := ship.get_parent()
	if mn != null:
		var sm = mn.get("ship_model")
		if sm != null and is_instance_valid(sm):
			(sm as Node3D).visible = true
	# aim at the actual engine-cone centroid (world), framed from the side
	var c := Vector3.ZERO
	var nn := 0
	for fc in flame_cones:
		var n: Node3D = fc["node"]
		if is_instance_valid(n) and n.is_inside_tree():
			c += n.global_position
			nn += 1
	if nn == 0:
		return
	c /= float(nn)
	var xf := ship.global_transform
	# rear-quarter hero view: engines are at the ship's tail; stand off to one
	# side, behind and above, so the full plumes read against clear space
	var eye := c + Vector3(58.0, 30.0, 92.0)
	_shot_cam.global_position = eye
	_shot_cam.look_at(c + Vector3(0.0, -4.0, -6.0), Vector3.UP)
	_shot_cam.current = true            # override the game camera every frame
	_shot_settle += delta
	if _shot_settle < 1.0:
		return
	_shot_t += delta
	if _shot_t < 0.15:
		return
	_shot_t = 0.0
	var img := get_viewport().get_texture().get_image()
	var base := ProjectSettings.globalize_path("res://").path_join("..")
	var dir := base.path_join("data/screenshots")
	DirAccess.make_dir_recursive_absolute(dir)
	img.save_png(dir.path_join("flameshot_%d.png" % _shot_n))
	var jets_on := 0
	for jb in _jet_beams:
		if (jb["mi"] as MeshInstance3D).visible:
			jets_on += 1
	print("FLAMESHOT: saved frame ", _shot_n, " ship=", xf.origin,
			" jets=", jets_on, "/", _jet_beams.size())
	_shot_n += 1
	if _shot_n >= 8:
		print("FLAMESHOT: done")
		get_tree().quit()

## The flare quads and jet beams are WORLD-anchored: ShipEffects is a plain
## Node, so its Node3D children sit outside the ship's 3D transform chain and
## do not ride the hull. They are placed at RENDER cadence, after the
## post-integration world fold (main.late_physics), reading the same folded
## nozzle transforms the hull is drawn with. Placing them from
## _physics_process left them a full tick's travel ahead of the folded hull
## -- kilometres per frame during the LDS ramp (the "thruster lights run
## ahead" regression; mechcheck lds-flare-anchored read 2e9 m).
func _process(_delta: float) -> void:
	if ship == null:
		return
	_update_jet_beams()
	_update_engine_flares()


func _physics_process(delta: float) -> void:
	if ship == null:
		return
	# raw ship-state inputs for the channel language
	# icShip::ApplyThrusterBurns @ iwar2.dll.c:97623-97631: "burn" is BINARY
	# -- 1.0 while the forward yoke demand (+0x2cc) is positive, else 0.0,
	# written for PLAYER ships only. Not analog, not a speed: burn_smooth's
	# 1.0/s rate limit is what shapes the attack; at constant velocity there
	# is no demand and no glow.
	var burn := 0.0
	if ship.drive_override or ship.input_thrust.z > 0.05:
		burn = 1.0
	fire_pulse = maxf(0.0, fire_pulse - delta * 4.0)
	# icShip::ApplyThrusterBurns @ 0x100758a0 writes the raw channels on the
	# avatar root each tick: "lx"/"ly"/"lz" (strings @ 0x1015d5fc/0x1015d600/
	# 0x1015d2b0) = APPLIED force / max force per axis -- ship.thrust_frac
	# mirrors that law, assist trim included, so the engine glow follows the
	# throttle, not just held stick input. "ry"/"rp"/"rr" (@ 0x1015d604/08/0c)
	# = applied torque / max torque; input_rotate stands in (same 0..1 shape).
	# It also writes "burn" (@ 0x1015d610) = forward yoke > 0 and "v"
	# (@ 0x1015d618) = speed fraction; our burn below approximates the former.
	var raw := {
		"lz": ship.thrust_frac.z, "lx": ship.thrust_frac.x,
		"ly": ship.thrust_frac.y,
		"rp": ship.input_rotate.x, "ry": ship.input_rotate.y,
		"rr": ship.input_rotate.z,
		"burn": burn, "fire": fire_pulse, "dock": 0.0,
	}
	# a script-set channel overrides the ship-state input of the same name and
	# supplies the ones the ship has no state for
	for k: String in script_channels:
		raw[k] = script_channels[k]
	# avatars/tug_hull/channels.ini, verbatim:
	#   lz_smooth = "lz?+s(0.75)"    burn_smooth = "burn?+s(1.0)"
	#   boom = core = "burn_smooth"  flame = flap = "lz_smooth burn_smooth"
	# s(t) is a LINEAR rate limit at t units/s (FUN_100ddae0 @ flux.dll.c:
	# 207738-207751), not an exponential smooth, and space-separated terms
	# combine by ARITHMETIC MEAN then clamp [0,1] (207726-207737) -- NOT max.
	_lz_smooth = move_toward(_lz_smooth,
		clampf(maxf(raw["lz"], 0.0), 0.0, 1.0), delta * 0.75)
	_burn_smooth = move_toward(_burn_smooth, burn, delta * 1.0)
	var mixed := clampf((_lz_smooth + _burn_smooth) * 0.5, 0.0, 1.0)
	var named := {
		"flame": mixed,
		"core": _burn_smooth,
		"boom": _burn_smooth,
		"flap": mixed,
	}
	if _flameshot:
		# main resets ship.drive_override each frame, so pin the derived channels
		# to full for the capture (full plume length + intensity)
		named = {"flame": 1.0, "core": 1.0, "boom": 1.0, "flap": 1.0}
	for ch in exprs:
		var e: Dictionary = exprs[ch]
		# terms combine by MEAN then clamp to [0,1] (FUN_100ddae0
		# @ flux.dll.c:207726-207737) -- the engine never takes a max
		var total := 0.0
		for term in e["terms"]:
			total += _eval_term(term, raw, delta)
		e["value"] = clampf(total / maxf(float(e["terms"].size()), 1.0),
			0.0, 1.0)
	# drive each flame cone's own channel (flame/core) into its shader. The
	# Draw uses v = |Evaluate(channel)| (0x100bd63e) to gate + grade the plume.
	for fc in flame_cones:
		var ch: String = fc["channel"]
		var v: float
		if named.has(ch):
			v = named[ch]
		elif exprs.has(ch):
			v = exprs[ch]["value"]
		else:
			v = 0.0
		(fc["mat"] as ShaderMaterial).set_shader_parameter("intensity", clampf(v, 0.0, 1.0))
	# the <glow channel=...> surfaces (#17): emission follows the channel
	for gm in glow_mats:
		var gch: String = gm["channel"]
		var gv: float
		if named.has(gch):
			gv = named[gch]
		elif exprs.has(gch):
			gv = exprs[gch]["value"]
		else:
			gv = 0.0
		(gm["mat"] as StandardMaterial3D).emission_energy_multiplier = \
				clampf(gv, 0.0, 1.0)
	if _flameshot:
		_flameshot_tick(delta)
	for entry in anim_nodes:
		var n: Node3D = entry["node"]
		if not is_instance_valid(n):
			continue
		var t: float
		if named.has(entry["channel"]):
			t = named[entry["channel"]]
		elif exprs.has(entry["channel"]):
			t = exprs[entry["channel"]]["value"]
		else:
			t = 0.0
		# every generator output is clamped [0,1] inside the evaluator
		# before it drives geometry (flux.dll.c:207730-207737)
		t = clampf(t, 0.0, 1.0)
		var q: Quaternion = (entry["q0"] as Quaternion).slerp(entry["q1"], t)
		var b := Basis(q).scaled_local(
			(entry["s0"] as Vector3).lerp(entry["s1"], t))
		n.transform = Transform3D(b, (entry["p0"] as Vector3).lerp(entry["p1"], t))
	# icSignAvatar flip: frac(t_seconds / fps) <= 0.5 -> texture, else
	# texture_2 (Draw @ 0x100d047f..0x100d04d7 -- see _add_sign)
	_sign_t += delta
	for sg in _signs:
		var frac := fposmod(_sign_t / float(sg["fps"]), 1.0)
		(sg["mat"] as StandardMaterial3D).albedo_texture = \
				sg["tex1"] if frac <= 0.5 else sg["tex2"]
