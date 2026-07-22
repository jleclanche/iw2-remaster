extends "checks_state.gd"
# One-shot probes and the scripted demo.
# Part of the checks extends chain (issue #31):
# checks_state <- checks_probes <- checks_camp <- checks_base <-
# checks_jump <- checks_mech <- checks.gd (CheckRunner, the dispatcher).
# Same node, same class -- the split mirrors main.gd's layered-file scheme.

# --- fireprobe: does the primary actually fire on this boot? ------------------
var _fp_done := false

var _fp_next := 1.0

func _fireprobe(_delta: float) -> void:
	if demo_t >= _fp_next and _fp_next < 9.5 and m.sys != null:
		_fp_next += 1.0
		print("FIREPROBE t=%.0f heat=%.0f ext=%.0f" % [demo_t, m.sys.heat,
				m.sys.heat_external])
	if demo_t < 10.0 or _fp_done:
		return
	_fp_done = true
	if m.sys != null:
		# the heat ledger: who is producing and who is sinking, right now
		for s2: Dictionary in m.sys.systems:
			if float(s2["heat_rate"]) != 0.0:
				print("FIREPROBE ledger %-28s hr=%+.0f eff=%.2f off=%s dead=%s"
						% [str(s2["name"]), float(s2["heat_rate"]),
						float(s2["efficiency"]),
						str(s2.get("off", false)), str(s2["destroyed"])])
	m.weapons.cooldown = 0.0
	_charge_guns()
	var before: int = m.weapons.bolts.size()
	m.weapons.fire()
	var w: PbcWeapons = m.weapons
	print("FIREPROBE ship=%s groups=%d group_idx=%d muzzles=%d fixed=%s " %
			[m.player_ship_ini, w.groups.size(), w.group_idx,
			w.muzzle_nodes.size(), str(not w.fixed_gun.is_empty())]
			+ "secondary=%d heat=%.0f/%.0f bolts %d -> %d" %
			[m.secondary_idx,
			(m.sys.heat + m.sys.heat_external) if m.sys != null else -1.0,
			ShipSystems.HEAT_DAMAGE_THRESHOLD, before, w.bolts.size()])
	get_tree().quit()

# --- contact list after a debug-menu system spawn -----------------------------

var _cc_i := 0

func _contactcheck(_delta: float) -> void:
	# reproduce the SELECT SYSTEM path exactly: main.start_in_system per entry
	if demo_t < 0.5:
		return
	demo_t = 0.0
	var systems: Array = m.menu.SYSTEMS
	if _cc_i >= systems.size():
		print("CONTACTCHECK done")
		m.get_tree().quit()
		return
	var pick: Array = systems[_cc_i]
	m.start_in_system(str(pick[0]), str(pick[2]) if pick.size() > 2 else "")
	var list: Array = m.contact_list()
	print("CONTACTS %-28s n=%d  entry=%s" % [str(pick[1]), list.size(),
			str(m.last_entry.get("name", "?"))])
	for e in list:
		print("   %-5s %-5s %10.0f  %-14s%s" % [str(e["faction"]), str(e["type"]),
				float(e["dist"]), str(e["name"]),
				"  [unidentified]" if e.get("unknown", false) else ""])
	_cc_i += 1

# --- colour-pipeline probe ----------------------------------------------------
# Four unshaded quads parented to the camera: a 128-grey runtime ImageTexture,
# two albedo_color controls, and the freighter glTF's first texture. If the
# texture quads match the srgb_to_linear(0.502)=0.2158 control, runtime
# textures are decoded correctly; matching the 0.502 control means the sRGB
# decode is missing (washed out).

var _sp_built := false

func _sp_quad(cam: Camera3D, x: float, mat: StandardMaterial3D) -> void:
	var q := MeshInstance3D.new()
	q.mesh = QuadMesh.new()
	(q.mesh as QuadMesh).size = Vector2(0.3, 1.2)
	q.position = Vector3(x, 0, -2.0)
	q.material_override = mat
	cam.add_child(q)

func _sp_unshaded() -> StandardMaterial3D:
	var mt := StandardMaterial3D.new()
	mt.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	return mt

func _srgbprobe(_delta: float) -> void:
	if not _sp_built and demo_t > 0.6:
		_sp_built = true
		m.hud.visible = false
		var cam: Camera3D = get_viewport().get_camera_3d()
		var img := Image.create(8, 8, false, Image.FORMAT_RGB8)
		img.fill(Color8(128, 128, 128))
		var m_tex := _sp_unshaded()
		m_tex.albedo_texture = ImageTexture.create_from_image(img)
		_sp_quad(cam, -1.0, m_tex)
		var m_lo := _sp_unshaded()
		m_lo.albedo_color = Color(0.2158, 0.2158, 0.2158)
		_sp_quad(cam, -0.6, m_lo)
		var m_hi := _sp_unshaded()
		m_hi.albedo_color = Color(0.502, 0.502, 0.502)
		_sp_quad(cam, -0.2, m_hi)
		var gl: Node3D = m._load_gltf("data/avatars/avatars/freighter/setup.gltf")
		var m_g := _sp_unshaded()
		if gl != null:
			for mi in gl.find_children("*", "MeshInstance3D", true, false):
				var mat := (mi as MeshInstance3D).mesh.surface_get_material(0)
				if mat is StandardMaterial3D \
						and (mat as StandardMaterial3D).albedo_texture != null:
					m_g.albedo_texture = (mat as StandardMaterial3D).albedo_texture
					break
			gl.queue_free()
		_sp_quad(cam, 0.2, m_g)
		# the discriminator: identical shaders except the sampler hint. If the
		# hinted quad differs from the raw one, the sRGB decode IS applied to
		# runtime ImageTextures and the pipeline is already correct.
		var img2 := Image.create(8, 8, false, Image.FORMAT_RGB8)
		img2.fill(Color8(128, 128, 128))
		var t2 := ImageTexture.create_from_image(img2)
		for probe in [["src", "uniform sampler2D t : source_color;", 0.6],
				["raw", "uniform sampler2D t;", 1.0]]:
			var sh := Shader.new()
			sh.code = "shader_type spatial;\nrender_mode unshaded;\n" \
				+ str(probe[1]) \
				+ "\nvoid fragment() { ALBEDO = texture(t, UV).rgb; }"
			var sm := ShaderMaterial.new()
			sm.shader = sh
			sm.set_shader_parameter("t", t2)
			var q := MeshInstance3D.new()
			q.mesh = QuadMesh.new()
			(q.mesh as QuadMesh).size = Vector2(0.3, 1.2)
			q.position = Vector3(float(probe[2]), 0, -2.0)
			q.material_override = sm
			cam.add_child(q)
		return
	if _sp_built and demo_t > 1.6:
		var shot := get_viewport().get_texture().get_image()
		var w := shot.get_width()
		var h := shot.get_height()
		# camera half-width at z=2 with hfov 63 deg = 2*tan(31.5) = 1.2255
		for probe in [["tex128", -1.0], ["lin.2158", -0.6],
				["lin.502", -0.2], ["gltf", 0.2],
				["sh-src", 0.6], ["sh-raw", 1.0]]:
			var px := int(w * (0.5 + float(probe[1]) / (2.0 * 1.2255)))
			var c := shot.get_pixel(px, h / 2)
			print("SRGBPROBE %-9s = %d %d %d" % [probe[0],
					int(c.r * 255.0), int(c.g * 255.0), int(c.b * 255.0)])
		m.get_tree().quit()

# --- suns from the player's actual position (flare model eyeball) ------------

var _ss_i := 0
var _ss_aimed := false

func _sunshot(_delta: float) -> void:
	if demo_t < 1.2:
		return
	demo_t = 0.6
	var stars: Array = []
	for o in m.objects:
		if o["category"] == "star":
			stars.append(o)
	if _ss_i >= 36:
		print("SUNSHOT done")
		m.get_tree().quit()
		return
	var rec: Dictionary = stars[0]
	var yaw := float(_ss_i * 10)
	if not _ss_aimed:
		# stay AT the junkyard spawn; just point the ship at the sun
		var to := Vector3(float(rec["x"]) - m.px, float(rec["y"]) - m.py,
			float(rec["z"]) - m.pz).normalized()
		m.ship.global_transform = Transform3D(Basis.IDENTITY,
				Vector3.ZERO).looking_at(to * 1000.0, Vector3.UP)
		m.ship.rotate_y(deg_to_rad(yaw))
		m.cam_mode = 0
		m._apply_view()
		m.hud.visible = false
		_ss_aimed = true
		return
	_shot("sweep_yaw%03d" % int(yaw))
	_ss_i += 1
	_ss_aimed = false

# --- command-section muzzle: fire and photograph from the side ---------------

func _muzzleshot(_delta: float) -> void:
	match demo_phase:
		0:
			if demo_t > 0.6:
				m._fit_player("sims/ships/player/comsec.ini",
					"data/avatars/avatars/command_section/setup.gltf")
				print("MUZZLESHOT: fitted comsec, weapon=", m.weapon_name)
				demo_phase = 1
				demo_t = 0.0
		1:
			# drop camera abeam the ship: barrel and bolt side-on in frame
			m.cam_mode = 3
			m.cam_view = 0
			m.drop_cam_pos = m.ship.global_position + Vector3(-25, 2, -8)
			m._apply_view()
			if demo_t > 0.4:
				_charge_guns()
				m.weapons.fire()
				for b in m.weapons.bolts:
					print("MUZZLESHOT: bolt spawned at ship-local ",
							m.ship.to_local(b["node"].global_position))
				demo_phase = 2
				demo_t = 0.0
		2:
			if demo_t > 0.001:
				_shot("muzzleshot_side")
				demo_phase = 3
				demo_t = 0.0
		3:
			# and from above
			m.drop_cam_pos = m.ship.global_position + Vector3(0, 25, -8)
			if demo_t > 0.3:
				_charge_guns()
				m.weapons.fire()
				demo_phase = 4
				demo_t = 0.0
		4:
			if demo_t > 0.001:
				_shot("muzzleshot_top")
				get_tree().quit()

# --- comm portraits: one screenshot per speaker rig --------------------------

var _comm_idx := 0
const COMM_SPEAKERS := ["clay", "az", "cal", "jafs", "lori", "maas", "smith",
	"young_cal"]

func _commshot(_delta: float) -> void:
	# free flight; queue a fake line from each speaker in turn so the comm MFD
	# opens with their live head, and photograph it mid-sway
	if _comm_idx >= COMM_SPEAKERS.size():
		get_tree().quit()
		return
	var who: String = COMM_SPEAKERS[_comm_idx]
	if m.comms.current.is_empty() and m.comms.queue.is_empty():
		m.comms.queue.append({"key": "commshot_%s" % who, "speaker": who,
			"text": "COMM PORTRAIT RIG CHECK: %s" % who.to_upper()})
		demo_t = 0.0
	elif demo_t > 1.6:
		_shot("commshot_%s" % who)
		m.comms.current = {}
		m.comms.subtitle = ""
		_comm_idx += 1
		demo_t = 0.0

# --- geography: are the bodies the right size, and do they look right? -------

var _geog_shot := 0

func _geog_look_at(rec: Dictionary, dist_in_radii: float) -> void:
	# park the ship `dist_in_radii` body-radii out and point it at the body
	var r: float = maxf(float(rec["radius"]), 1.0e3)
	var d := r * dist_in_radii
	m.px = float(rec["x"]) + d * 0.6
	m.py = float(rec["y"]) + d * 0.25
	m.pz = float(rec["z"]) + d * 0.75
	m.ship.global_position = Vector3.ZERO
	m.ship.velocity = Vector3.ZERO
	var to := Vector3(float(rec["x"]) - m.px, float(rec["y"]) - m.py,
		float(rec["z"]) - m.pz).normalized()
	m.ship.global_transform = Transform3D(Basis.IDENTITY, Vector3.ZERO) \
		.looking_at(to * 1000.0, Vector3.UP)
	m.cam_mode = 0
	m._apply_view()
	m._stream_objects()

func _geogcheck(_delta: float) -> void:
	if demo_phase == 0:
		if demo_t < 1.0:
			return
		m.menu.visible = false
		m.hud.visible = false
		for o in m.objects:
			if o["category"] == "star" or (o["category"] == "body"
					and o["renders"]):
				var what: String = str(o["sun_texture"]) \
					if o["category"] == "star" \
					else "%s %s rings=%d atm=%s" % [o["surface_class"],
						o["surface_textures"], o["ring_count"],
						o["atmosphere_texture"]]
				print("GEOG: ", str(o["name"]).rpad(30), " r=",
					"%.0f" % float(o["radius"]), " m  ", what)
		demo_phase = 1
		demo_t = 0.0
		return
	var wanted := []
	for o in m.objects:
		if o["category"] == "star":
			wanted.append(o)
	for o in m.objects:
		if o["category"] == "body" and o["renders"] and o["ring_count"] > 0:
			wanted.append(o)
			break
	for o in m.objects:
		if o["category"] == "body" and o["renders"] \
				and not str(o["atmosphere_texture"]).is_empty():
			wanted.append(o)
			break
	if _geog_shot >= wanted.size():
		print("GEOGCHECK done")
		m.get_tree().quit()
		return
	var rec: Dictionary = wanted[_geog_shot]
	if demo_t < 0.4:
		_geog_look_at(rec, 6.0)
		return
	_shot("geog_%d_%s" % [_geog_shot, str(rec["name"]).to_snake_case()])
	print("GEOGCHECK shot: ", rec["name"])
	_geog_shot += 1
	demo_t = 0.0

# --- motion grid burst capture --------------------------------------------------

func _motioncheck(_delta: float) -> void:
	m.ship.set_speed = 0.0
	m.ship.velocity = Vector3.ZERO
	if m.target_idx < 0:
		for i in m.objects.size():
			if m.objects[i]["name"] == m.START_NAME:
				m.target_idx = i
	m._face_target()
	if demo_t > 2.0 + _mc_shot * 0.4 and _mc_shot < 8:
		_shot("motion_%d" % _mc_shot)
		_mc_shot += 1
	if _mc_shot >= 8:
		print("MOTIONCHECK done")
		get_tree().quit()

# --- scripted demo: LDS across the system, then a combat encounter ---------------

## Whether the straight run to `rel` stays clear of every body/star break-off
## shell (icAIServices::InnerMarkerRadius: 1.5x radius + 200 m). A shell we are
## already inside only blocks if the run takes us DEEPER than we are now.
func _lds_corridor_clear(rel: Vector3) -> bool:
	for o in m.objects:
		if not (o["category"] in ["body", "star"]):
			continue
		var margin := float(o["radius"]) * 1.5 + 200.0
		if margin <= 300.0:
			continue
		var c := Vector3(o["x"] - m.px, o["y"] - m.py, o["z"] - m.pz)
		var t := clampf(c.dot(rel) / maxf(rel.length_squared(), 1.0), 0.0, 1.0)
		var closest := (rel * t - c).length()
		if closest < margin and closest < c.length() * 0.98:
			return false
	return true

## Where the demo pilot points the nose: straight at the target. The original
## has no LDS mass avoidance (LDSObstacles is never populated), so the demo flies
## direct; its destination pick already screens for a clear corridor.
func _demo_aim() -> Vector3:
	return m._target_pos()

func _demo(_delta: float) -> void:
	if demo_t > 500.0:
		print("DEMO: TIMEOUT")
		get_tree().quit(1)
		return
	match demo_phase:
		0:
			m.ship.set_speed = m.ship.max_speed.z
			if m._lds_clearance() > m.LDSI_RADIUS * 0.1:
				var bestd := INF
				for i in m.objects.size():
					var o: Dictionary = m.objects[i]
					if o["category"] != "station":
						continue
					var rel := Vector3(o["x"] - m.px, o["y"] - m.py,
						o["z"] - m.pz)
					var d := rel.length()
					# a pilot would not point the drive through a gas giant:
					# skip destinations whose bearing closes on a mass shell
					if d > 0.5 * 1.496e11 and d < bestd \
							and _lds_corridor_clear(rel):
						bestd = d
						m.target_idx = i
				if bestd == INF:
					print("DEMO: no destination with a clear corridor")
					get_tree().quit(1)
					return
				print("DEMO: destination ", m.objects[m.target_idx]["name"])
				demo_phase = 1
		1:
			var aim1: Vector3 = _demo_aim()
			m._face_dir(aim1)
			if (-m.ship.global_transform.basis.z).angle_to(aim1.normalized()) < 0.05:
				m._toggle_lds()
				_mech_v0 = Vector3(m.px, m.py, m.pz)
				demo_phase = 2
		2:
			var aim2: Vector3 = _demo_aim()
			m._face_dir(aim2)
			if m.lds_state == 0:
				# dropout auto-deceleration zeroed the set speed; drive on so the
				# assist swings the velocity onto the detour heading
				m.ship.set_speed = m.ship.max_speed.z
			if demo_t - _demo_logged >= 30.0:
				_demo_logged = demo_t
				var worst := ""
				var worst_cl := INF
				for o in m.objects:
					if not (o["category"] in ["body", "star", "station", "gunstar"]):
						continue
					var mult: float = 1.5 if o["category"] in ["body", "star"] else 1.0
					var cl: float = Vector3(o["x"] - m.px, o["y"] - m.py,
						o["z"] - m.pz).length() - float(o["radius"]) * mult - 200.0
					if cl < worst_cl:
						worst_cl = cl
						worst = "%s %s r=%.0f" % [o["name"], o["category"], o["radius"]]
				print("DEMO: t=%.0fs lds=%d dist=%s speed=%.0f avoid=%.0f (%s)"
					% [demo_t, m.lds_state, m._fmt_dist(m._target_distance()),
						m.ship.velocity.length(), m._lds_avoidance(), worst])
			if m.lds_state == 0 and m._target_distance() > 1.0e6 \
					and m._lds_clearance() > 0.0 and m._lds_avoidance() > 0.0 \
					and (-m.ship.global_transform.basis.z).angle_to(aim2.normalized()) < 0.05 \
					and demo_t < 400.0:
				m._toggle_lds()  # dropout en route: re-engage once clear + aligned
			if m.lds_state == 0 and m._target_distance() <= 1.0e6:
				print("DEMO: arrived, remaining=",
					m._fmt_dist(m._target_distance()),
					" traveled=", m._fmt_dist(
						(Vector3(m.px, m.py, m.pz) - _mech_v0).length()))
				var hostile: AiShip = m.spawn_hostile(Vector3(2500, 300, -1500))
				m.target_ai = hostile
				m.target_idx = -1
				demo_phase = 3
				demo_t = 0.0
		3:
			m.ship.set_speed = m.ship.max_speed.z * 0.4
			m._face_target()
			if m.target_ai != null and is_instance_valid(m.target_ai):
				var dir: Vector3 = m._target_pos().normalized()
				if (-m.ship.global_transform.basis.z).angle_to(dir) < 0.08:
					m.weapons.fire()
			if demo_t > 6.0 or m.target_ai == null:
				if not m._headless():
					_shot("combat_demo")
				print("DEMO: combat shot saved; player hull=", m.hull,
					" hostiles=", m._hostiles_alive(),
					" contacts=", m.contact_list().size())
				demo_phase = 4
				demo_t = 0.0
		4:
			if m.target_ai == null or demo_t > 20.0:
				print("DEMO: done, hostile destroyed=", m.target_ai == null,
					" player hull=", m.hull)
				get_tree().quit()
			elif is_instance_valid(m.target_ai):
				m._face_target()
				var dir: Vector3 = m._target_pos().normalized()
				if (-m.ship.global_transform.basis.z).angle_to(dir) < 0.08:
					m.weapons.fire()
