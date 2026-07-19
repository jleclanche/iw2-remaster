class_name CheckRunner
extends Node
# The automated test harness: --demo / --mechcheck / --jumpcheck /
# --uicheck / --campcheck / --motioncheck cmdline modes. Owns all the
# phase machines that used to live in main.gd; `m` is the game root.

var m: Node3D  # main

var demo_t := 0.0
var demo_phase := 0
var _demo_logged := 0.0
var _mc_shot := 0
var _mech_fail := 0
var _mech_t0 := 0.0
var _mech_v0 := Vector3.ZERO
var _mech_home := Vector3.ZERO
var _mech_gs: AiShip = null      # turret platform (gunstar.ini)
var _mech_drone: AiShip = null   # turret / beam target
var _mech_beam: Dictionary = {}  # the beam mount under test
var _mech_field: Dictionary = {} # synthetic icFieldSphere for the fields phase

func step(delta: float) -> void:
	demo_t += delta
	if m.fireprobe:
		_fireprobe(delta)
	elif m.contactcheck:
		_contactcheck(delta)
	elif m.sunshot:
		_sunshot(delta)
	elif m.srgbprobe:
		_srgbprobe(delta)
	elif m.muzzleshot:
		_muzzleshot(delta)
	elif m.commshot:
		_commshot(delta)
	elif m.newgametest:
		_newgametest(delta)
	elif m.basecheck:
		_basecheck(delta)
	elif m.newgamecheck:
		_newgamecheck(delta)
	elif m.campcheck:
		_campcheck(delta)
	elif m.uicheck:
		_uicheck(delta)
	elif m.jumpcheck:
		_jumpcheck(delta)
	elif m.mechcheck or m.mechslow:
		_mechcheck(delta)
		if m.ap_mode > 0 and m.docked_at == "":
			m._autopilot_process(delta)
	elif m.motioncheck:
		_motioncheck(delta)
	elif m.geogcheck:
		_geogcheck(delta)
	else:
		_demo(delta)

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

func _shot(name: String) -> void:
	var img := get_viewport().get_texture().get_image()
	img.save_png(m._base().path_join("data/screenshots/%s.png" % name))

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

# --- campaign smoke test ----------------------------------------------------

## NEW GAME restarts the campaign by reloading the scene, so this check has to
## survive the reload: a static outlives the node, exactly like main._restarting.
## The bug it guards against: POG tasks parked on `process_frame` outlive the old
## scene, resume against a node that has left the tree, and reach for a null
## SceneTree -- which froze the game on the first NEW GAME.
static var _ng_stage := 0

## The REAL front-end path: let the PDA menu come up, then drive its own
## START NEW GAME button (close() + start_campaign, from input handling) --
## exactly what the player does. Distinct from _newgamecheck, which calls
## start_campaign directly and so cannot see an input-timing bug.
var _ngt_stage := 0

func _newgametest(_delta: float) -> void:
	match _ngt_stage:
		0:
			if demo_t > 1.5:
				# NOT fast: we are testing whether the real opening dialogue
				# actually plays and the mission advances past its first
				# `until_comms` step -- fast mode auto-completes it and hides
				# any hang.
				m.menu.sel = 0
				m.menu._activate()   # START NEW GAME, the button's own code
				print("NEWGAMETEST: pressed START NEW GAME, movie=%s"
					% [m.movie != null])
				_ngt_stage = 1
		1:
			if demo_t > 3.5 and m.movie != null:
				m.skip_movie()
			if demo_t > 12.0:
				if not m._headless():
					_shot("newgametest")
				var steps: int = m.mission.steps.size() if m.mission != null else 0
				# the real signal the OPENING played: the mission loaded AND is
				# speaking / has a subtitle up (Clay's opening line), not merely
				# that a world exists.
				var spoke: bool = m.comms != null and (m.comms.speaking() \
					or m.comms.subtitle != "")
				# the campaign runs one of three ways: hand-authored steps,
				# the ported GDScript runtime (--port), or the bytecode VM
				# (--pog). Crediting only --port made a working --pog boot
				# read as FAIL.
				var driven: bool = (m.use_port or m.use_pog) \
					and m.pog_rt != null and not m.pog_rt.halted
				var ok: bool = (steps > 0 or driven) and spoke
				print("NEWGAMETEST: %s — steps=%d, opening dialogue up=%s"
					% ["PASS" if ok else "FAIL", steps, spoke])
				_ngt_stage = 0
				get_tree().quit(0 if ok else 1)
	if demo_t > 40.0:
		print("NEWGAMETEST: TIMEOUT stage ", _ngt_stage)
		get_tree().quit(1)

func _newgamecheck(_delta: float) -> void:
	match _ng_stage:
		0:
			if demo_t > 1.0:
				m.comms.fast = true
				m.start_campaign()
				print("NEWGAMECHECK: campaign up, steps=", m.mission.steps.size())
				_ng_stage = 1
		1:
			# let the boot chain get properly under way (iprelude's master script
			# is the one that was parked on a frame when the scene went away)
			if demo_t > 4.0:
				print("NEWGAMECHECK: restarting")
				_ng_stage = 2
				m.restart_campaign()
		2:
			# a fresh scene: main._ready saw _restarting and started the campaign.
			# Under --port the campaign IS the POG runtime, so mission.steps is
			# legitimately empty; what must be true either way is that we have a
			# live world -- a player ship with systems, in a loaded system, and a
			# POG runtime that is running rather than halted.
			# The prelude cinematic plays first (it MUST play -- that it plays is
			# the whole point of the fix), so skip it the way a real player would
			# with Escape, then let its finished callback start the mission.
			if demo_t > 3.0 and m.movie != null:
				m.skip_movie()
			if demo_t > 5.0:
				var live_pog: bool = m.pog_rt != null and not m.pog_rt.halted
				# The campaign must actually OPEN, not just leave a live world:
				# the hand-authored path populates mission.steps, the --port path
				# queues the prologue dialogue. One of the two must be true, or
				# NEW GAME dropped you into empty flight (the user's bug).
				var steps: int = m.mission.steps.size() if m.mission != null else 0
				# hand-authored path -> mission.steps; --port -> the POG runtime
				# drives the campaign (proven separately to re-run iprelude)
				var opened: bool = steps > 0 \
					or ((m.use_port or m.use_pog) and live_pog)
				var ok: bool = m.ship != null and m.sys != null \
					and m.objects.size() > 0 and live_pog and opened
				print("NEWGAMECHECK: %s — objects=%d, pog=%s, mission steps=%d"
					% ["PASS" if ok else "FAIL", m.objects.size(), live_pog, steps])
				_ng_stage = 0
				get_tree().quit(0 if ok else 1)
	if demo_t > 40.0:
		print("NEWGAMECHECK: TIMEOUT stage ", _ng_stage)
		_ng_stage = 0
		get_tree().quit(1)

func _campcheck(_delta: float) -> void:
	# mission starts, dialogue flows, waypoint objective spawns + completes
	match demo_phase:
		0:
			if demo_t > 1.0:
				m.comms.fast = true
				m.start_campaign()
				print("CAMPCHECK: mission started, steps=", m.mission.steps.size())
				demo_phase = 1
		1:
			if m.movie != null and demo_t > 5.0:
				_shot("movie_frame")
				m.movie.finished.emit()
			# pass the contact-list lesson: select Clay's Waypoint
			for i in m.objects.size():
				if str(m.objects[i]["name"]) == "Clay's Waypoint" \
						and m.target_idx != i:
					m.target_idx = i
					m.target_ai = null
			if m.mission.objectives.has("wp1"):
				if not m._headless():
					_shot("campaign_spawn")
				for o in m.objects:
					if o.get("waypoint", false) and not o.get("blip", false):
						m.px = o["x"]
						m.py = o["y"]
						m.pz = o["z"]
				demo_phase = 2
		2:
			if m.mission.objectives.get("wp1", {}).get("done", false):
				var ck := _checkpoint_check()
				print("CAMPCHECK: PASS — waypoint objective completed, ",
					"dialogue queued=", m.comms.queue.size())
				get_tree().quit(0 if ck else 1)
	if demo_t > 90.0:
		print("CAMPCHECK: TIMEOUT phase ", demo_phase, " idx=", m.mission.idx)
		get_tree().quit(1)

# Mission checkpoints roll the scoreboard back (iwar2.dll @ 0x100a0ab0
# SetRestartPoint: snapshot; @ 0x100a0d80 GotoRestartPoint: restore -- see
# natives/misc.gd). Drive the natives exactly as the mission scripts do
# (argc=0, through the runtime dispatch) and assert the roll-back.
func _checkpoint_check() -> bool:
	var sc: PogMisc = m.pog_rt.misc
	var k0: int = sc.kill_score
	var p0: int = sc.piracy_score
	m.pog_rt.native("iscore.setrestartpoint", [])
	sc.kill_score += 250     # kills earned after the checkpoint...
	sc.piracy_score += 40    # ...are discarded by the restart
	m.pog_rt.native("iscore.gotorestartpoint", [])
	var ok: bool = sc.kill_score == k0 and sc.piracy_score == p0
	print("CAMPCHECK checkpoint: ", "PASS" if ok else "FAIL",
		" — score rolled back to %d kill / %d piracy" %
		[sc.kill_score, sc.piracy_score])
	return ok

# --- UI screenshots -----------------------------------------------------------

func _uicheck(_delta: float) -> void:
	match demo_phase:
		0:
			if demo_t > 0.5 and not m.menu.visible:
				m.menu.launched = false
				m.menu.open()
			if demo_t > 2.5:
				_shot("ui_menu")
				m.menu.launched = true
				m.menu.close()
				m.cam_mode = 0
				m._apply_view()
				var hostile: AiShip = m.spawn_hostile(Vector3(1200, 150, -2200))
				m.target_ai = hostile
				m.comms.say_key("a0_m10_dialogue_clay_i_know")
				demo_phase = 1
				demo_t = 0.0
		1:
			m._face_target()
			if demo_t > 2.5:
				_shot("ui_cockpit")
				m.cam_mode = 1
				m._apply_view()
				demo_phase = 2
				demo_t = 0.0
		2:
			m.ship.set_speed = m.ship.max_speed.z
			m.ship.input_thrust.z = 1.0
			if demo_t > 3.0:
				_shot("ui_chase")
				# teleport to Lucrecia's Base and dock for the interior shot
				m.ship.input_thrust.z = 0.0
				m.ship.set_speed = 0.0
				m.ship.velocity = Vector3.ZERO
				for a in m.ai_ships:
					a.queue_free()
				m.ai_ships.clear()
				m.target_ai = null
				for o in m.objects:
					if str(o["name"]) == "Lucrecia's Base":
						m.px = o["x"] + 2000.0
						m.py = o["y"]
						m.pz = o["z"]
				m._try_dock()
				demo_phase = 3
				demo_t = 0.0
		3:
			var bays := [Vector3(0, -110, -527), Vector3(-60, -160, -527),
				Vector3(0, -160, -700)]
			if demo_t > 1.5 and _mc_shot < 3:
				_shot("ui_base_%d" % _mc_shot)
				_mc_shot += 1
				if _mc_shot < 3:
					m.base_root.position = -(bays[_mc_shot] as Vector3)
				demo_t = 1.0
			elif _mc_shot >= 3:
				print("UICHECK done, docked=", m.docked_at)
				get_tree().quit()

# --- Lucrecia's Base ----------------------------------------------------------
#
# Drives the whole go-home system and asserts on it: the contact-list gate (not
# found -> not on the list), the found-base flag, the AUTOSKIP from >200 km with
# a dock order, the docking cutscene, the interior, the diorama the manager picks
# per screen, and the 30-second cut to the next room. Everything it checks comes
# out of ibacktobase.pog and [icSPPlayerBaseScreen] in the shipped defaults.ini;
# see base_interior.gd.

var _base_fail := 0
var _base_shot := 0
var _door_shot := false
var _room := 0
var _pending := false
var _hull0 := 0.0

func _bc(name: String, ok: bool, note := "") -> void:
	if not ok:
		_base_fail += 1
	print("BASECHECK %-34s %s%s" % [name, "PASS" if ok else "FAIL",
		"" if note.is_empty() else "  (%s)" % note])

func _base_rec() -> Dictionary:
	return m.base_iface.base_rec()

func _basecheck(_delta: float) -> void:
	var bi: BaseInterior = m.base_iface
	match demo_phase:
		0:
			if demo_t < 0.5:
				return
			m.menu.launched = true
			m.menu.close()
			# Fly home in the tug -- the ship you get AT Lucrecia's Base and the
			# one back-to-base is used in from act 1 on. (The bare act-0 command
			# section has an EMPTY heatsink mount-point socket -- comsec.ini
			# template[3] is filled from inventory in the real game -- so parked
			# under power it overheats; that is a fitting limitation in
			# ship_systems, not the docking path, and it is out of this task's
			# scope. The tug is prefitted and has its heatsink.)
			m._fit_player("sims/ships/player/tug.ini",
				"data/avatars/avatars/tug_hull/setup_prefitted.gltf")
			_hull0 = m.hull
			# 1. the contact-list gate. Fresh act 0: g_act0_found_base is 0, so
			#    iBackToBase is disabled and the base is off sensors.
			_bc("act 0: base not yet found", not bi.found())
			_bc("act 0: base off the contact list",
				not _contact_has_base(), "sensor_hidden")
			_bc("base system is Hoffer's Wake",
				bi.base_system() == "hoffers_wake", bi.base_system())
			# 2. find it (what iact0mission10 does on completion), and park 400 km
			#    out -- past the 200 km split -- so the base is inside sensor
			#    range of the contact list and the AUTOSKIP is the path in.
			m.pog_rt.std.globals["g_act0_found_base"] = 1
			bi.apply_visibility()
			var rec := _base_rec()
			m.px = float(rec["x"]) + 4.0e5
			m.py = float(rec["y"])
			m.pz = float(rec["z"])
			m.ship.global_position = Vector3.ZERO
			m.ship.velocity = Vector3.ZERO
			_bc("found: base now on the contact list", _contact_has_base())
			# 3. order a dock on the base. The detector should confirm for 10 s
			#    and then skip us home.
			for i in m.objects.size():
				if str(m.objects[i]["name"]) == BaseInterior.BASE_NAME:
					m.target_idx = i
					m.target_ai = null
			m._set_autopilot(3)
			_bc("dock order on the base at 400 km",
				bi._dock_ordered() and bi.base_pos().length() > BaseInterior.NEAR_RANGE)
			demo_phase = 1
			demo_t = 0.0
		1:
			# the autopilot would fly us in; freeze it so the range stays > 200 km
			# and only the detector can act
			m.ship.velocity = Vector3.ZERO
			m.ship.set_speed = 0.0
			# the detector polls every 2.1 s, then counts down 10 s of sanity
			# checks before it fires
			if bi.cut == 0 and demo_t < BaseInterior.POLL \
					+ float(BaseInterior.CONFIRM_SECONDS) + 3.0:
				return
			if bi.cut == 0:
				_bc("autoskip armed", false,
					"detector never confirmed (blocked=%s)" % bi._blocked())
				demo_phase = 4
				return
			if bi.cut == 1:
				_bc("AUTOSKIP fired", true,
					"%.0f m from base" % bi.base_pos().length())
				_bc("autoskip standoff = PlaceRelativeTo(3000,2000,15000)",
					absf(bi.base_pos().length()
						- BaseInterior.SKIP_STANDOFF.length()) < 1500.0,
					"%.0f m" % bi.base_pos().length())
				demo_phase = 2
				demo_t = 0.0
		2:
			# let the cutscene run: fly-by -> approach -> framing -> interior
			if not m._headless() and _base_shot == 0 and bi.cut == 1 \
					and demo_t > 2.0:
				_shot("base_autoskip")
				_base_shot = 1
			if not m._headless() and _base_shot == 1 and bi.cut == 2 \
					and demo_t > 1.0:
				_shot("base_approach")
				_base_shot = 2
			# the doors: catch the frame they are part-open (channel 0.3..0.9)
			if not m._headless() and not _door_shot and bi.cut == 2 \
					and bi._door > 0.3 and bi._door < 0.95:
				_shot("base_doors_opening")
				_door_shot = true
			# `inside` is set the moment the cutscene ends, but the SHUTDOWN
			# movie (YoungCalShutdown in act 0) plays before the interior comes
			# up -- `open` is the interior itself
			if bi.open:
				_bc("docking cutscene -> inside the base", true)
				_bc("docked_at set", m.docked_at == BaseInterior.BASE_NAME)
				# The cutscene flies the ship THROUGH the hull and parks it in
				# the bay: DockingCutscene calls sim.SetCollision(player, 0).
				# Without that we rammed the station at 300 m/s and blew up.
				_bc("survived the dock (no hull collision)",
					m.hull >= _hull0 - 0.5,
					"hull %.0f -> %.0f" % [_hull0, m.hull])
				# the bay doors are an avatar channel, not an animation we play:
				# sim.AvatarSetChannel(base, "door", 1) opens them, and the
				# cutscene shuts them again once the ship is inside
				_bc("bay doors driven by the `door` channel",
					not bi._door_nodes.is_empty() and bi._door_want == 0.0,
					"%d door nulls, channel now %.2f"
						% [bi._door_nodes.size(), bi._door])
				_bc("diorama 0 (MAIN BAY) up", bi.diorama == 0, bi.room_name())
				# gui.SetScreen("icSPPlayerBaseScreen") -> the overlay manager
				# raises its hosted menu, icSPBaseScreen, on top of itself
				# (iwar2 @ 0x10024cca), and ibasegui.SPBaseScreen builds it.
				var cur := str(m.pog_rt.native(
					"gui.currentscreenclassname", []))
				_bc("base menu raised (icSPBaseScreen)",
					cur == "icSPBaseScreen", cur)
				demo_phase = 3
				demo_t = 0.0
		3:
			if demo_t < 1.5:
				return
			if not m._headless() and _base_shot < 3:
				_shot("base_interior")
				_base_shot = 3
			var bui: PogUi = m.pog_rt.ui
			var sui: BaseScreens = bui.screen_ui
			_bc("base menu has controls",
				bui.visible_screen() != null
					and not bui.visible_screen().windows.is_empty(),
				"windows=%d drawn=%s size=%s" % [
					bui.visible_screen().windows.size()
						if bui.visible_screen() != null else -1,
					"no renderer" if sui == null else str(sui.visible),
					"-" if sui == null else str(sui.size)])
			# 4. the screens the manager hosts, and the diorama each one picks.
			#    With g_show_dioramas clear -- the whole campaign -- the loader
			#    only ever loads diorama 0 (iwar2 @ 0x10024b95), so the interior
			#    is the MAIN BAY and nothing else. iactthree sets the global at
			#    the very end of act 3, and only then do the other four rooms
			#    exist.
			bi.next_diorama()
			_bc("campaign: no other rooms (g_show_dioramas clear)",
				bi.diorama == 0, bi.room_name())
			m.pog_rt.std.globals["g_show_dioramas"] = 1
			var want := {"icSPHangarScreen": 3, "icSPInboxScreen": 1,
				"icSPComputerTradingScreen": 2, "icSPStatisticsScreen": 4}
			var ok := true
			for scr in want:
				m.pog_rt.native("gui.setscreen", ["icSPPlayerBaseScreen"])
				m.pog_rt.native("gui.overlayscreen", [scr])
				bi.set_diorama(bi._screen_diorama())
				if bi.diorama != int(want[scr]):
					ok = false
					print("   ", scr, " -> diorama ", bi.diorama,
						", expected ", want[scr])
			_bc("screen -> diorama map (ctor 0x100243b7)", ok)
			if not m._headless() and _base_shot < 4:
				_shot("base_diorama_%d" % bi.diorama)
				_base_shot = 4
			# 5. the 30-second cut to the next room
			m.pog_rt.native("gui.setscreen", ["icSPPlayerBaseScreen"])
			var was := bi.diorama
			bi._dio_t = 0.001
			bi._interior_process(0.01)
			_bc("diorama_delay cuts to the next room", bi.diorama != was,
				"%d -> %d" % [was, bi.diorama])
			_bc("fritz flash after the cut",
				bi.fritz_alpha() > 0.0 and bi.fritz_alpha() <= 1.0,
				"alpha %.2f" % bi.fritz_alpha())
			# 6. the light channels. g_base_lights_on is 0 from
			#    iStartSystem.StartupNewGame and is only set when Clay brings the
			#    base's power up (iPrelude.BaseOnlineHandler, "ok the systems are
			#    online") -- so a fresh act 0 base runs on EMERGENCY lighting,
			#    and the manager switches baselights_emergency on and
			#    baselights_normal off (iwar2 @ 0x10024d35).
			_bc("emergency lighting before the base is online",
				not bi._gflag(BaseInterior.LIGHTS_GLOBAL))
			m.pog_rt.std.globals["g_base_lights_on"] = 1
			bi.diorama = -1
			bi.set_diorama(0)
			_room = 0
			demo_phase = 5
			demo_t = 0.0
		5:  # a tour of the five rooms, one screenshot each (one per frame, or
			# the viewport hands back the same texture five times)
			if demo_t < 0.7:
				return
			if not m._headless():
				_shot("base_room_%d_%s" % [_room,
					bi.room_name().to_lower().replace(" ", "_")])
			_room += 1
			if _room >= BaseInterior.DIORAMAS.size():
				_bc("all five dioramas load and render", true)
				_room = 0
				demo_phase = 6
				demo_t = 0.0
				return
			bi.next_diorama()
			_bc("room %d = %s" % [bi.diorama, bi.room_name()],
				bi.diorama == _room
					and bi.room_name() == str(
						BaseInterior.DIORAMAS[_room]["name"]))
			demo_t = 0.0
		6:  # the screens the base menu leads to: the hangar (choose your ship),
			# the inbox (email) and the manifest (cargo) -- each on its own
			# diorama, each built by the original ibasegui code
			if demo_t < 0.7:
				return
			var tour: Array = ["icSPHangarScreen", "icSPInboxScreen",
				"icSPManifestScreen"]
			if _pending:
				# raised last pass, so it is on screen now
				if not m._headless():
					_shot("base_screen_%s" % str(tour[_room]).to_snake_case())
				_pending = false
				_room += 1
				demo_t = 0.0
				return
			if _room >= tour.size():
				demo_phase = 7
				demo_t = 0.0
				return
			var want_scr: String = str(tour[_room])
			m.pog_rt.native("gui.setscreen", ["icSPPlayerBaseScreen"])
			m.pog_rt.native("gui.overlayscreen", [want_scr])
			bi._interior_process(0.01)
			var raised: bool = str(m.pog_rt.native(
				"gui.currentscreenclassname", [])) == want_scr
			_bc("%s on the %s diorama" % [want_scr, bi.room_name()],
				raised and bi.diorama
					== int(BaseInterior.SCREEN_DIORAMA[want_scr]))
			_pending = true
			demo_t = 0.0
		7:  # the SAVE GAME slot screen, raised the way SPBasePDAScreen_OnSave
			# does: gui.OverlayScreen("icSPPDASaveScreen") (ipdagui.pog:352-356;
			# builder SPPDASaveScreen, ipdagui.pog:435)
			if demo_t < 0.7:
				return
			if not _pending:
				m.pog_rt.native("gui.setscreen", ["icSPPlayerBaseScreen"])
				m.pog_rt.native("gui.overlayscreen", ["icSPPDASaveScreen"])
				_pending = true
				demo_t = 0.0
				return
			var bui7: PogUi = m.pog_rt.ui
			if not m._headless():
				_shot("pda_save_screen")
			var sscr: PogUi.PogScreen = bui7.visible_screen()
			var boxes := 0
			if sscr != null:
				for w in sscr.windows:
					if w.kind == "editbox":
						boxes += 1
			_bc("save screen: an edit box per slot (14, iwar2 @ 0xb6c80)",
				sscr != null and sscr.name == "icSPPDASaveScreen"
					and boxes == PogGameApi.SAVE_SLOTS,
				"editboxes=%d" % boxes)
			# Select on the focused slot starts an edit and runs the begin
			# override, SPPDASaveScreen_SetDefaultName, which proposes
			# "ACT n  <realtime>" (ipdagui.pog:459-479, FcEditBox @ 0x7c4b0)
			var sui7: BaseScreens = bui7.screen_ui
			var box: PogUi.PogWindow = sui7._current() if sui7 != null else null
			var before := ""
			if box != null and box.kind == "editbox":
				before = PogStd._s(box.value)
				bui7.activate(box)
			_bc("save screen: edit proposes the default name",
				box != null and box.editing
					and PogStd._s(box.value).begins_with("ACT "),
				"-" if box == null else PogStd._s(box.value))
			# Escape while editing restores the pre-edit text and leaves the
			# screen up (FcEditBox::OnControlFocusCancel @ 0x7c530)
			if box != null and box.editing:
				bui7.cancel()
			_bc("save screen: edit cancel restores the slot text",
				box != null and not box.editing
					and PogStd._s(box.value) == before
					and bui7.visible_screen() == sscr,
				"-" if box == null else PogStd._s(box.value))
			bui7.dispatch("iPDAGUI.SPPDASaveScreen_OnBackButton")
			_pending = false
			demo_phase = 8
			demo_t = 0.0
		8:  # the LOAD GAME screen: a row per occupied slot (local_11058,
			# ipdagui.pog:618-630), each loading BY NAME (SPPDALoadScreen_OnLoad
			# -> igame.LoadGame(title), ipdagui.pog:605-610)
			if demo_t < 0.7:
				return
			if not _pending:
				m.pog_rt.native("gui.overlayscreen", ["icSPPDALoadScreen"])
				_pending = true
				demo_t = 0.0
				return
			var bui8: PogUi = m.pog_rt.ui
			if not m._headless():
				_shot("pda_load_screen")
			var lscr: PogUi.PogScreen = bui8.visible_screen()
			var rows := 0
			if lscr != null:
				for w in lscr.windows:
					if w.kind == "button" \
							and w.on_press == "iPDAGUI.SPPDALoadScreen_OnLoad":
						rows += 1
			_bc("load screen: a row per occupied save",
				lscr != null and lscr.name == "icSPPDALoadScreen"
					and rows == m.save_slots().size(),
				"rows=%d saves=%d" % [rows, m.save_slots().size()])
			bui8.dispatch("iPDAGUI.SPPDALoadScreen_OnBackButton")
			_pending = false
			demo_phase = 4
			demo_t = 0.0
		4:
			# the inbox's mail bodies: iemail.SendEmail's html:/text/... URLs must
			# resolve to the extracted pages (tools/iw2/html_text.py) -- this was
			# silently empty until the text/act_*/**.html tree was extracted
			var will: String = m.pog_rt.ui._resource_text(
				"html:/text/act_0/act0_master_lucreciamail_1")
			_bc("Lucrecia's mail body resolves (html:/text/...)",
				will.contains("Last Will and Testament"),
				"%d chars" % will.length())
			# gui.SetWindowStateIcons(win, 6, 6, 5) -- igui.MakeInverseButtonIconic
			# (igui.pog:630). Selected and neutral share their three-slice art, so
			# this glyph is the ONLY thing that reads as "selected"; the eIcon ->
			# rect table is icCustomisableWindowAvatar's, written @ 0x1010b480 with
			# m_icon_size (16,16) @ 0x1010b4f0.
			var iui: PogUi = m.pog_rt.ui
			var iwin := PogUi.PogWindow.new()
			iui._set_state_icons(null, [iwin, 6, 6, 5])
			_bc("iconic button: eIcon 6/6/5 -> the alpha-map rects",
				iwin.icons.get("neutral") == Rect2(34, 0, 16, 16)
					and iwin.icons.get("focused") == Rect2(34, 0, 16, 16)
					and iwin.icons.get("selected") == Rect2(34, 17, 16, 16),
				"neutral=%s selected=%s"
					% [iwin.icons.get("neutral"), iwin.icons.get("selected")])
			print("BASECHECK: ", "PASS" if _base_fail == 0 else "FAIL",
				" -- ", _base_fail, " failure(s)")
			get_tree().quit(0 if _base_fail == 0 else 1)

func _contact_has_base() -> bool:
	for e in m.contact_list():
		if str(e.get("name", "")) == BaseInterior.BASE_NAME:
			return true
	return false

func _screen_stack() -> Array:
	var out: Array = []
	for s in m.pog_ui.screens:
		out.append(s.name)
		for o in s.over:
			out.append(o.name)
	return out

# --- capsule jump -------------------------------------------------------------

func _jumpcheck(_delta: float) -> void:
	# validate a capsule jump: start at Alexander L-Point -> route to Coyote
	match demo_phase:
		0:
			if demo_t > 1.0:
				print("JUMPCHECK: from ", m.system_stem, ", routes: ",
					m.routes_text())
				m._try_jump()
				if m.jump_state == 0:
					print("JUMPCHECK: FAILED to initiate")
					get_tree().quit(1)
				demo_phase = 1
		1:
			if m.jump_state == 0:
				print("JUMPCHECK: now in ", m.system_stem,
					" (", m.system_name, ")")
				demo_phase = 2
				demo_t = 0.0
		2:
			if demo_t > 1.5:
				if not m._headless():
					_shot("jump_arrival")
				var ok: bool = m.system_stem != m.START_SYSTEM
				print("JUMPCHECK: ", "PASS" if ok else "FAIL",
					" — arrived in ", m.system_name,
					", contacts=", m.contact_list().size())
				get_tree().quit(0 if ok else 1)
	if demo_t > 60.0:
		print("JUMPCHECK: TIMEOUT in state ", m.jump_state)
		get_tree().quit(1)

# --- flight-model assertions ---------------------------------------------------

func _mech(check: String, ok: bool, detail: String) -> void:
	if not ok:
		_mech_fail += 1
	print("MECHCHECK %s: %s (%s)" % ["PASS" if ok else "FAIL", check, detail])

func _mech_next() -> void:
	demo_phase += 1
	demo_t = 0.0

# The mechcheck steps, in run order. demo_phase indexes this table, so a new
# step is one method plus one line here -- nothing renumbers.
var _mech_steps: Array[StringName] = [
	&"_ms_setup",
	&"_ms_accel",
	&"_ms_brake",
	&"_ms_lateral",
	&"_ms_assist_trim",
	&"_ms_coast_start",
	&"_ms_free_drift",
	&"_ms_lds_engage",
	&"_ms_lds_speed",
	&"_ms_lds_drop",
	&"_ms_ap_approach",
	&"_ms_ap_dock",
	&"_ms_missile_spawn",
	&"_ms_missile_track",
	&"_ms_turret_spawn",
	&"_ms_turret_refire",
	&"_ms_beam_spawn",
	&"_ms_beam_burst",
	&"_ms_field_spawn",
	&"_ms_field_assert",
	&"_ms_field_cull",
	&"_ms_tri_weights",
	&"_ms_tri_drive",
	&"_ms_tow_dock",
	&"_ms_tow_ride",
	&"_ms_pod_spill",
	&"_ms_pod_spill_assert",
	&"_ms_gatling",
	&"_ms_lazy_name",
	&"_ms_save_reload",
	&"_ms_debug_base",
	&"_ms_finish",
]

# Steps that take minutes of REAL flight (the autopilot convergence tests).
# --mechcheck skips them and runs the rest at 4x engine time (assertions all
# measure demo_t, which is game time, so they hold); --mechslow is the full
# suite at real time -- run it rarely, when the autopilot itself changed.
const MECH_SLOW_STEPS: Array[StringName] = [&"_ms_ap_approach", &"_ms_ap_dock"]
const MECH_FAST_TIME_SCALE := 4.0

func _mechcheck(delta: float) -> void:
	if not m.mechslow and _mech_steps[demo_phase] in MECH_SLOW_STEPS:
		print("MECHCHECK skip: %s (--mechslow runs it)"
				% _mech_steps[demo_phase])
		_mech_next()
		return
	call(_mech_steps[demo_phase], delta)
	if demo_t > 300.0:
		print("MECHCHECK: phase %d timeout" % demo_phase)
		get_tree().quit(1)

func _ms_setup(_delta: float) -> void:
	# move 1 Gm off-plane, clear of all masses, then full throttle
	if not m.mechslow:
		Engine.time_scale = MECH_FAST_TIME_SCALE
	_mech_home = Vector3(m.px, m.py, m.pz)
	m.py += 1.0e9
	m.target_idx = -1
	m.target_ai = null
	m.ship.set_speed = m.ship.max_speed.z
	_mech_t0 = demo_t
	_mech_next()

func _ms_accel(_delta: float) -> void:
	# tug reaches 850 m/s in 850/150 = 5.67 s (INI constants)
	if m.ship.forward_speed() >= m.ship.max_speed.z - 10.0:
		var t := demo_t
		_mech("accel-to-850", t > 4.5 and t < 7.5, "%.2f s" % t)
		m.ship.set_speed = 0.0
		_mech_next()
	elif demo_t > 15.0:
		_mech("accel-to-850", false,
			"timeout, v=%.0f" % m.ship.forward_speed())
		_mech_next()

func _ms_brake(_delta: float) -> void:
	# flight computer brakes back to zero
	if m.ship.velocity.length() < 5.0:
		_mech("brake-to-zero", true, "%.2f s" % demo_t)
		m.ship.input_thrust.x = 1.0
		_mech_next()
	elif demo_t > 15.0:
		_mech("brake-to-zero", false, "v=%.0f" % m.ship.velocity.length())
		_mech_next()

func _ms_lateral(_delta: float) -> void:
	# lateral thruster pushes sideways
	if demo_t > 2.0:
		var lat := absf((m.ship.velocity * m.ship.global_transform.basis).x)
		_mech("lateral-thrust", lat > 30.0, "%.0f m/s" % lat)
		m.ship.input_thrust.x = 0.0
		_mech_next()

func _ms_assist_trim(_delta: float) -> void:
	# assist trims lateral drift back out
	if demo_t > 4.0:
		var lat := absf((m.ship.velocity * m.ship.global_transform.basis).x)
		_mech("assist-trim", lat < 5.0, "%.1f m/s" % lat)
		m.ship.assist = false
		m.ship.input_thrust.z = 1.0
		_mech_next()

func _ms_coast_start(_delta: float) -> void:
	# free flight: thrust then coast, velocity must persist
	if demo_t > 1.5:
		m.ship.input_thrust.z = 0.0
		_mech_v0 = m.ship.velocity
		_mech_next()

func _ms_free_drift(_delta: float) -> void:
	if demo_t > 3.0:
		var dv: float = (m.ship.velocity - _mech_v0).length()
		_mech("free-flight-drift", dv < 1.0 and _mech_v0.length() > 50.0,
			"v=%.0f dv=%.2f" % [_mech_v0.length(), dv])
		m.ship.assist = true
		_mech_next()

func _ms_lds_engage(_delta: float) -> void:
	# LDS: must exceed drive speeds by orders of magnitude
	if m.ship.velocity.length() < 5.0:
		_mech_v0 = Vector3(m.px, m.py, m.pz)
		m._toggle_lds()
		_mech("lds-engage", m.lds_state == 1, "state=%d" % m.lds_state)
		_mech_next()
	elif demo_t > 15.0:
		_mech("lds-engage", false, "never stopped")
		_mech_next()

func _ms_lds_speed(_delta: float) -> void:
	if demo_t > 15.0:
		var spd: float = m.ship.velocity.length()
		var traveled := (Vector3(m.px, m.py, m.pz) - _mech_v0).length()
		_mech("lds-speed", m.lds_state == 2 and spd > 1.0e6,
			"v=" + m._fmt_dist(spd) + "/s")
		_mech("lds-travel", traveled > 1.0e8, m._fmt_dist(traveled))
		m._toggle_lds()
		_mech_next()

func _ms_lds_drop(_delta: float) -> void:
	# LDS drop: back to conventional speeds under assist
	if demo_t > 3.0:
		var spd: float = m.ship.velocity.length()
		_mech("lds-disengage",
			m.lds_state == 0 and spd <= m.ship.max_speed.z * 1.2,
			"v=%.0f" % spd)
		# return to the start cluster for autopilot + dock tests
		m.px = _mech_home.x
		m.py = _mech_home.y
		m.pz = _mech_home.z
		m.ship.velocity = Vector3.ZERO
		var near: Dictionary = m._nearest("station")
		for i in m.objects.size():
			if m.objects[i] == near:
				m.target_idx = i
				m.target_ai = null
		m._set_autopilot(1)
		_mech_next()

func _ms_ap_approach(_delta: float) -> void:
	# autopilot approach: arrive ON the marker sphere and stop
	# The break-off is not a constant. icPlayerPilot::EngageAutopilotApproach
	# hands the player's own icAIPilot a DefaultApproach order whose radius
	# is icAIServices::InnerMarkerRadius(ship, target) -- so it is derived
	# from what you are approaching, and a station, a fighter and a planet
	# all break off at different ranges. Assert that: the ship must stop on
	# the target's marker sphere, not inside some fixed radius.
	if m.ap_mode == 0 and demo_t > 1.0:
		var d: float = m._target_distance()
		var mk: float = m._target_marker()
		var slop: float = maxf(PogWorld.completion_tolerance(mk), 20.0) + 100.0
		_mech("ap-approach", mk > 0.0 and absf(d - mk) <= slop,
			"dist=%.0f m, marker=%.0f m, after %.0f s" % [d, mk, demo_t])
		m._set_autopilot(3)
		_mech_next()
	elif demo_t > 200.0:
		_mech("ap-approach", false,
			"timeout dist=%s" % m._fmt_dist(m._target_distance()))
		m._set_autopilot(3)
		_mech_next()

func _ms_ap_dock(_delta: float) -> void:
	# autopilot dock
	if m.docked_at != "":
		_mech("ap-dock", true, m.docked_at)
		m._undock()
		_mech_next()
	elif demo_t > 90.0:
		_mech("ap-dock", false, "timeout")
		_mech_next()

func _ms_missile_spawn(_delta: float) -> void:
	# a seeker missile tracks and kills: 500 hp / 280 flat blast = 2 hits
	var ai: AiShip = m.spawn_hostile(m.ship.global_position
			- m.ship.global_transform.basis.z * 3000.0)
	ai.hull = 500.0
	ai.behavior = "idle"
	m.target_ai = ai
	m._cycle_secondary()
	_mech_v0 = Vector3(ai.hull, 0.0, 0.0)
	_mech_next()

func _ms_missile_track(_delta: float) -> void:
	if m.target_ai == null or not is_instance_valid(m.target_ai):
		_mech("missile-kill", true, "%.0f s" % demo_t)
		_mech_next()
	elif demo_t > 60.0:
		_mech("missile-kill", false, "hull=%.0f after %.0f s"
			% [m.target_ai.hull, demo_t])
		_mech_reap(m.target_ai)
		_mech_next()
	else:
		# the recovered blast is flat 280 (seeker, disable_attenuation):
		# hull must step by exact multiples of it
		if is_instance_valid(m.target_ai) and not m.target_ai.dying \
				and m.target_ai.hull < float(_mech_v0.x):
			var drop: float = float(_mech_v0.x) - m.target_ai.hull
			if absf(fmod(drop, 280.0)) > 0.5 \
					and absf(fmod(drop, 280.0) - 280.0) > 0.5:
				_mech("missile-damage", false, "step=%.1f" % drop)
			_mech_v0.x = m.target_ai.hull
		m._fire_secondary()

func _ms_turret_spawn(_delta: float) -> void:
	# icTurret: a gunstar's nps_turret_pbc fires pbc_bolt on the
	# recovered fire cycle (refire_delay 0.6 through clock += eff*dt,
	# iiGun::Simulate 0x10035030 / IsReadyToFire 0x10035120)
	_mech_gs = _mech_spawn("Gunstar", 6000.0,
			m.ship.global_position - m.ship.global_transform.basis.z * 6000.0)
	_mech_gs.setup_ini("sims/ships/navy/gunstar.ini", null)
	# a small drone: radius < 40 m skips the iiGun jitter roll
	# (0x1011849c), so every solution passes the 1-degree fire arc
	# and the cadence is the bare refire clock. Offset off the mount
	# plane: the gunstar's turret nulls put min_elevation=0 exactly
	# on the equator, so a coplanar target sits on the limit.
	_mech_drone = _mech_spawn("Drone", 100000.0, _mech_gs.global_position
			+ Vector3(-600.0, 0.0, -2000.0))
	_mech_drone.radius = 20.0
	Turrets.instance.arm_ship(_mech_gs, _mech_drone)
	_mech_next()

func _ms_turret_refire(_delta: float) -> void:
	var shots := _mech_turret_shots()
	if shots.size() >= 4:
		var battery: Dictionary = _mech_battery(_mech_gs)
		var gun: Dictionary = battery["guns"][0]
		var bolt: Dictionary = gun["bolt"]
		_mech("turret-bolt", absf(float(bolt["damage"]) - 160.0) < 0.01
			and absf(float(bolt["penetration"]) - 50.0) < 0.01
			and absf(float(bolt["speed"]) - 6000.0) < 0.01,
			"pbc_bolt %d/%d @ %d m/s" % [int(bolt["damage"]),
				int(bolt["penetration"]), int(bolt["speed"])])
		var lo := 1.0e9
		var hi := 0.0
		for i in range(1, shots.size()):
			var dt_i := float(shots[i]) - float(shots[i - 1])
			lo = minf(lo, dt_i)
			hi = maxf(hi, dt_i)
		# refire_delay 0.6 (nps_turret_pbc.ini), quantised to the
		# physics tick
		_mech("turret-refire", lo > 0.55 and hi < 0.75,
			"interval %.3f..%.3f s" % [lo, hi])
		_mech_reap(_mech_gs)
		_mech_next()
	elif demo_t > 30.0:
		_mech("turret-refire", false, "%d shots in %.0f s"
			% [_mech_turret_shots().size(), demo_t])
		_mech_reap(_mech_gs)
		_mech_next()

func _ms_beam_spawn(_delta: float) -> void:
	# icBeamProjector/icBeam: nps_beam_weapon charges to capacity
	# (1800 at ai_charge_per_second 300), then burns at
	# beam_power_drain 500/s while applying damage_rate 1000/s --
	# the burst is exactly capacity/drain * damage_rate = 3600
	m.weapons.clear()  # no stale turret bolts against the drone
	var ship := _mech_spawn("Beamship", 5000.0,
			m.ship.global_position + m.ship.global_transform.basis.x * 6000.0)
	_mech_drone.global_position = ship.global_position \
			- ship.global_transform.basis.z * 1500.0
	_mech_drone.velocity = Vector3.ZERO
	_mech_drone.radius = 20.0
	_mech_beam = Turrets._make_beam(
			"ini:/subsims/systems/nonplayer/nps_beam_weapon", {},
			Vector3.ZERO, Basis.IDENTITY)
	Turrets.instance.batteries.append({"owner": ship, "rec": {},
		"guns": [], "beams": [_mech_beam], "armed": true,
		"locked": _mech_drone})
	_mech_v0 = Vector3(_mech_drone.hull, 0.0, 0.0)
	_mech_next()

func _ms_beam_burst(_delta: float) -> void:
	var burst := float(_mech_beam["burst_damage"])
	if burst > 0.0 and not bool(_mech_beam["firing"]):
		# the +-50 was one 60 Hz tick of damage-rate quantisation; the frame
		# step (and so the overshoot) scales with the fast suite's time scale
		_mech("beam-burst", absf(burst - 3600.0) < 50.0 * Engine.time_scale,
			"%.0f damage (capacity 1800 / drain 500 * rate 1000)" % burst)
		var took := float(_mech_v0.x) - _mech_drone.hull
		_mech("beam-damage", absf(took - burst) < 1.0,
			"hull -%.0f (src=1: no LDA, bare hull here)" % took)
		_mech_reap(_mech_drone)
		_mech_next()
	elif demo_t > 30.0:
		_mech("beam-burst", false, "energy=%.0f firing=%s after %.0f s"
			% [float(_mech_beam["energy"]),
				str(_mech_beam["firing"]), demo_t])
		_mech_next()

func _ms_field_spawn(_delta: float) -> void:
	# iiSimField: drop a synthetic icFieldSphere on the player and let
	# both singletons populate. Stationary, so the spawn path is the
	# uniform [0.1, 1.0] x (100 x rock radius) shell (FUN_1004a030
	# @ 0x1004a030 with _DAT_101184b0 = 0.1, _DAT_10119fa0 = 100).
	m.ship.velocity = Vector3.ZERO
	m.ship.set_speed = 0.0
	_mech_field = {"name": "__fieldtest", "category": "field_sphere",
		"x": m.px, "y": m.py, "z": m.pz, "radius": 10000.0,
		"field_asteroids": true, "field_debris": true,
		"avatar": "", "jumps": [], "colors": [], "node": null}
	m.objects.append(_mech_field)
	_mech_next()

func _ms_field_assert(_delta: float) -> void:
	if demo_t < 0.4:  # a few ticks: build the pools, spawn the lot
		return
	var ast: Array = m.fields.asteroid.live
	var deb: Array = m.fields.debris.live
	# count = the whole authored pool: live + pooled == count, always
	# (fields/asteroid.ini count=100, fields/debris.ini count=50; the
	# per-frame spawn budget is `count` too, Think @ 0x10049570)
	_mech("field-count", ast.size() == 100 and deb.size() == 50,
		"asteroids=%d debris=%d" % [ast.size(), deb.size()])
	var shell_ok := true
	var kin_ok := true
	var worst := ""
	for rk in ast:
		var r: float = rk["radius"]
		var d: float = (rk["node"] as Node3D).position.length()
		if d < 0.1 * 100.0 * r - 100.0 or d > 100.0 * r + 100.0:
			shell_ok = false
			worst = "d=%.0f r=%.0f" % [d, r]
		# spin in [min_rot, max_rot] deg/s, speed in [min_speed,
		# max_speed] m/s (FUN_10049d70 @ 0x10049d70 + fields inis)
		var w: float = rad_to_deg(float(rk["rate"]))
		var v: float = (rk["vel"] as Vector3).length()
		if w < 5.0 - 0.01 or w > 60.0 + 0.01 \
				or v < 2.0 - 0.01 or v > 75.0 + 0.01:
			kin_ok = false
			worst = "spin=%.1f v=%.1f" % [w, v]
	for rk in deb:
		if (rk["vel"] as Vector3).length() > 0.001:  # max_speed = 0
			kin_ok = false
			worst = "debris moving"
	_mech("field-shell", shell_ok and not ast.is_empty(),
		worst if not shell_ok else "all in [0.1, 1.0] x 100r")
	_mech("field-kinematics", kin_ok, worst if not kin_ok
		else "spin 5..60 deg/s, speed 2..75, debris still")
	# deactivate + teleport: every rock must strand outside the
	# 1.1 x 100r cull shell (Think @ 0x10049570, _DAT_10119e94)
	m.objects.erase(_mech_field)
	m.py += 1.0e8
	_mech_next()

func _ms_field_cull(_delta: float) -> void:
	if m.fields.asteroid.live.is_empty() \
			and m.fields.debris.live.is_empty():
		_mech("field-cull", true, "%.2f s" % demo_t)
		_mech_next()
	elif demo_t > 5.0:
		_mech("field-cull", false, "%d still live after %.0f s"
			% [m.fields.asteroid.live.size()
				+ m.fields.debris.live.size(), demo_t])
		_mech_next()

func _ms_tri_weights(_delta: float) -> void:
	# --- the TRI (task #60) -------------------------------------------
	# The recovered numbers, all from iiShipSystem's .data statics:
	# min_tri_weight 0.5 (0x1015bb8c), max_tri_weight 1.5 (0x1015bb90),
	# and SetTRIPosition's piecewise map (0x1003c070) -- weight is min at
	# position 0, exactly 1.0 at 1/3, max at 1.
	#
	# The ap-dock phase left us docked, and the drive weight only reaches
	# the flight model while we are flying -- icShip::Simulate gates its
	# two TRIWeight multiplies on `ship+0x148 == 0` exactly as our
	# _player_control gates on `docked_at == ""`. So: cast off first.
	m.docked_at = ""
	_tri_check()
	_mech_next()

func _ms_tri_drive(_delta: float) -> void:
	# the drive axis had a frame to reach ShipFlight through _player_control
	var wd: float = 1.5
	var got: float = m.ship.max_accel.z
	var want: float = m.base_max_accel.z * wd
	_mech("tri-drive-accel", absf(got - want) < 0.5,
		"full drive: %.1f m/s^2 (base %.1f x %.2f)"
			% [got, m.base_max_accel.z, wd])
	var gotr: float = m.ship.turn_accel.x
	var wantr: float = m.base_turn_accel.x * wd
	_mech("tri-drive-torque", absf(gotr - wantr) < 0.5,
		"full drive: %.1f deg/s^2 (base %.1f x %.2f)"
			% [gotr, m.base_turn_accel.x, wd])
	# put the ship back where the rest of the game expects it
	m.sys.set_tri_position(1.0 / 3.0, 1.0 / 3.0, 1.0 / 3.0)
	_mech_next()

func _ms_tow_dock(_delta: float) -> void:
	# --- towing (icDockPort::OnDock -> AttachChild mass coupling) ----
	# the tug is 80x70x120 -> mass 672 (iiThrusterSim::Load, w*h*l*
	# m_density 0.001); a cargo pod is 50^3 -> 125; a docked pair
	# accelerates at mass/(mass+partner) of the rated figure
	var pod := _mech_spawn("Tow Pod", 1000.0,
			m.ship.global_position - m.ship.global_transform.basis.z * 300.0)
	pod.setup_ini("sims/ships/utility/cargo_pod.ini", null)
	pod.docking_priority = 11
	pod.mass = 125.0   # setup_ini reloads dims; pin the authored value
	pod.velocity = m.ship.velocity
	var mass_ok: bool = absf(m.ship.mass - 672.0) < 1.0
	var did: bool = m._try_tow_dock()
	var scale_ok: bool = absf(m.ship.mass_scale() - 672.0 / 797.0) < 0.01
	_mech("tow-dock", did and mass_ok and scale_ok,
		"tug %.0f + pod %.0f -> accel x %.3f"
			% [m.ship.mass, pod.mass, m.ship.mass_scale()])
	_mech_v0 = pod.global_position
	_mech_next()

func _ms_tow_ride(_delta: float) -> void:
	var pod2: AiShip = m.towed
	if pod2 == null:
		_mech("tow-ride", false, "tow released early")
	else:
		# the child must ride the parent's frame rigidly
		var rel: float = ((pod2.global_position - m.ship.global_position)
				.length())
		_mech("tow-ride", absf(rel - 300.0) < 5.0 and pod2.behavior == "towed",
			"pod holds %.0f m off the parent" % rel)
	m._release_tow(false)
	_mech("tow-release", m.towed == null
			and absf(m.ship.mass_scale() - 1.0) < 0.001,
		"accel scale back to %.3f" % m.ship.mass_scale())
	if pod2 != null:
		_mech_reap(pod2)
	_mech_next()

## kill_ai now runs OnExplode's timed dramatic sequence for anything over
## size 25 -- minutes of pyrotechnics the harness must not sit through.
## Reap = kill and skip straight to the removal.
func _mech_reap(ai: AiShip) -> void:
	m.kill_ai(ai)
	if is_instance_valid(ai) and ai.dying:
		for c in ai.get_children():
			if c is DeathSequence:
				c.queue_free()
		m._finish_kill(ai)

var _spill_before := 0

func _ms_pod_spill(_delta: float) -> void:
	# a dying hauler spills its racked pods (DetachAndFlingChild -> free
	# cargo-pod sims with a "cargo" property, main._spill_pods)
	var frt := _mech_spawn("Doomed Freighter", 100.0,
			m.ship.global_position - m.ship.global_transform.basis.z * 5000.0)
	frt.setup_ini("sims/ships/utility/freighter.ini", null)
	frt.ctype = "Freighter"
	frt.carried_pods = 2
	# the commodity table normally comes up with the act; register one type
	# so the spill has something to stamp (icargo.Create's argument order)
	if m.pog_econ.cargo_types.is_empty():
		m.pog_econ._c_create(null,
				[900, "Cargo_Test", 1, 5, 0, 0, 0, 0, "", "", 0])
	_spill_before = m.ai_ships.size()
	_mech_reap(frt)   # the spill happens in _finish_kill either way
	_mech_next()

func _ms_pod_spill_assert(_delta: float) -> void:
	var pods: Array = []
	for a in m.ai_ships:
		if is_instance_valid(a) and String(a.ctype) == "CargoPod":
			pods.append(a)
	if pods.size() >= 2:
		var s = m.pog_world._wrap_ship(pods[0])
		var cargo := int(m.pog_std._bag(s).get("cargo", -1))
		_mech("pod-spill", cargo > 0, "%d pods, first cargo id %d"
				% [pods.size(), cargo])
		for p in pods:
			_mech_reap(p)
		_mech_next()
	elif demo_t > 20.0:
		_mech("pod-spill", false, "no pods %d s after the kill" % int(demo_t))
		_mech_next()

func _ms_gatling(_delta: float) -> void:
	# icSlugThrower is an ammo-counted iiGun. 20 shipped NPC hulls mount
	# nps_assault_cannon; it must build as a battery gun carrying its own store
	# and its own fire sound, not fall through to the generic PBC.
	const TPL := "ini:/subsims/systems/nonplayer/nps_assault_cannon"
	var g: Dictionary = Turrets._make_gun(TPL, {}, Vector3.ZERO, Basis.IDENTITY)
	var bolt: Dictionary = g["bolt"]
	var ok: bool = g["cls"] == "icSlugThrower" \
			and int(g["ammo"]) == 500 and int(g["ammo_max"]) == 1000 \
			and not bool(g["turret"]) \
			and absf(float(g["refire"]) - 0.5) < 0.001 \
			and absf(float(g["h_arc"]) - 30.0) < 0.001 \
			and absf(float(bolt["damage"]) - 160.0) < 0.001 \
			and str(bolt["wav"]).ends_with("gatling.wav")
	_mech("gatling-gun", ok,
		"ammo %d/%d refire %.2f arc %.0f dmg %.0f %s"
			% [int(g["ammo"]), int(g["ammo_max"]), float(g["refire"]),
			float(g["h_arc"]), float(bolt["damage"]),
			str(bolt["wav"]).get_file()])
	_mech_next()

func _ms_lazy_name(_delta: float) -> void:
	# FcLocalisedText::Field runs at DISPLAY time, so a sim created BEFORE the
	# table that names it must still come up named once the table lands. This is
	# the real ordering out of iact0mission10.gd: :622 creates the sim,
	# :627 loads the CSV holding its key.
	const TABLE := "csv:/text/act_0/act0_mission10_addendum3"
	const KEY := "a0_m10_name_abandoned"
	var std := PogStd.new()
	var ai := AiShip.new()
	ai.name_std = std
	ai.name_key = KEY
	# unresolved: the engine renders the key itself, and must NOT memoise it
	var before := String(ai.display_name)
	std._text_add(null, [TABLE])
	var after := String(ai.display_name)
	ai.free()
	_mech("lazy-name", before == KEY and after == "Abandoned Hulk",
		"before table %s, after %s (want the key, then \"Abandoned Hulk\")"
			% [before, after])
	_mech_next()

func _ms_save_reload(_delta: float) -> void:
	# the igame.SaveGame/LoadGame roundtrip with the world extras: hull,
	# throttle, kills, magazines and the live-ship snapshot all survive.
	# Runs LAST: load_game re-enters the system and resets the mech world.
	var mark := _mech_spawn("Roundtrip Contact", 777.0,
			m.ship.global_position + Vector3(4000, 0, 0))
	mark.sim_key = "mech_roundtrip"
	mark.explicit_hostile = true
	m.ship.set_speed = 123.0
	m.kill_count = 42
	m.hull = m.hull_max * 0.5
	var saved: bool = m.save_game(7, "mechtest")
	m.hull = m.hull_max
	m.kill_count = 0
	m.ship.set_speed = 0.0
	_mech_reap(mark)
	var loaded: bool = m.load_game(7)
	var back: AiShip = null
	for a in m.ai_ships:
		if is_instance_valid(a) and String(a.sim_key) == "mech_roundtrip":
			back = a
	var ok: bool = saved and loaded \
			and absf(m.hull - m.hull_max * 0.5) < 0.5 \
			and m.kill_count == 42 \
			and absf(m.ship.set_speed - 123.0) < 0.01 \
			and back != null and back.explicit_hostile \
			and absf(back.hull - 777.0) < 0.5
	_mech("save-reload", ok,
		"hull %.0f/%.0f kills %d set_speed %.0f contact %s"
			% [m.hull, m.hull_max, m.kill_count, m.ship.set_speed,
			"restored" if back != null else "LOST"])
	if back != null:
		_mech_reap(back)
	DirAccess.remove_absolute("user://save_7.json")
	_mech_next()

func _ms_debug_base(_delta: float) -> void:
	# the DEBUG START gate: with g_current_act = -1 in BOTH globals stores
	# (the VM's and the ported runtime's -- base_interior reads pog_rt's
	# first, and main's debug boot must seed both), Lucrecia's Base comes up
	# on sensors, forced-identified and dockable in hoffers_wake.
	m.pog_std.globals["g_current_act"] = -1
	if m.pog_rt != null and m.pog_rt.std != null:
		m.pog_rt.std.globals["g_current_act"] = -1
	m.base_iface.apply_visibility()
	var rec: Dictionary = m.base_iface.base_rec()
	_mech("debug-base",
		m.base_iface.found() and m.base_iface.dockable()
			and not rec.is_empty() and bool(rec.get("sensor_forced", false)),
		"found=%s dockable=%s" % [m.base_iface.found(), m.base_iface.dockable()])
	_mech_next()

func _ms_finish(_delta: float) -> void:
	Engine.time_scale = 1.0
	print("MECHCHECK done: %s" % ("ALL PASS" if _mech_fail == 0
		else "%d FAILURES" % _mech_fail))
	get_tree().quit(0 if _mech_fail == 0 else 1)

func _tri_check() -> void:
	var s: ShipSystems = m.sys
	if s == null:
		_mech("tri-weights", false, "no fitted systems on the player")
		return
	# 1. the weight curve. BalancePower -> (1/3,1/3,1/3) is the 1.0 point;
	#    PowerToOffensive -> (0,1,0); PowerToDrive -> (1,0,0)
	#    (icPlayerPilot::DistributePower 0x100b00d0, eButtonCommand 0x17..0x1a).
	s.set_tri_position(1.0 / 3.0, 1.0 / 3.0, 1.0 / 3.0)
	var bal := [s.tri_weight(0), s.tri_weight(1), s.tri_weight(2)]
	s.set_tri_position(0.0, 1.0, 0.0)
	var off := [s.tri_weight(0), s.tri_weight(1), s.tri_weight(2)]
	var curve_ok: bool = _near(bal[0], 1.0) and _near(bal[1], 1.0) \
		and _near(bal[2], 1.0) and _near(off[0], 0.5) and _near(off[1], 1.5) \
		and _near(off[2], 0.5)
	_mech("tri-weights", curve_ok,
		"balanced %.2f/%.2f/%.2f, full offensive %.2f/%.2f/%.2f (want 1/1/1 and .5/1.5/.5)"
			% [bal[0], bal[1], bal[2], off[0], off[1], off[2]])
	# 2. the eType map: iiWeapon ctor writes 1, icDrive/icThrusters write 0, and
	#    everything else keeps the base default of 3 (weight pinned at 1.0).
	var seen := {}
	for sub: Dictionary in s.systems:
		seen[str(sub["class"])] = int(sub["etype"])
	var etype_ok: bool = seen.get("icCannon", -1) == ShipSystems.TRI_OFFENSIVE \
		and seen.get("icDrive", -1) == ShipSystems.TRI_DRIVE \
		and seen.get("icThrusters", -1) == ShipSystems.TRI_DRIVE \
		and seen.get("icCPU", -1) == ShipSystems.TRI_NONE
	_mech("tri-etype", etype_ok, "cannon=%d drive=%d thrusters=%d cpu=%d"
		% [seen.get("icCannon", -1), seen.get("icDrive", -1),
			seen.get("icThrusters", -1), seen.get("icCPU", -1)])
	# 3. the IsPlayer gate (0x1003bb80): an AI ship's subsims never feel the TRI,
	#    whatever the triangle says.
	var ai_sys := ShipSystems.for_ship("sims/ships/player/tug_prefitted.ini")
	ai_sys.set_tri_position(0.0, 1.0, 0.0)
	_mech("tri-ai-flat", _near(ai_sys.tri_weight(ShipSystems.TRI_OFFENSIVE), 1.0),
		"non-player offensive weight = %.2f (want 1.00)"
			% ai_sys.tri_weight(ShipSystems.TRI_OFFENSIVE))
	# 4. the OFFENSIVE consumers, end to end -- fire a real bolt and read what
	#    came out. iiGun::RefireDelay 0x1000f0a0 = refire / w; iiWeapon::Fire
	#    0x100357e0 = w * damage and w * lifetime (which is w * range).
	var base_refire: float = m.weapons.refire
	var base_dmg: float = float(m.weapons.bolt_spec["damage"])
	var base_life: float = float(m.weapons.bolt_spec["lifetime"])
	m.weapons.clear()
	m.weapons.cooldown = 0.0
	_charge_guns()
	s.set_tri_position(0.0, 1.0, 0.0)          # full offensive: w = 1.5
	m.weapons.fire()
	var cd: float = m.weapons.cooldown
	var spec: Dictionary = {}
	if not m.weapons.bolts.is_empty():
		spec = (m.weapons.bolts[0] as Dictionary)["spec"]
	var dmg: float = float(spec.get("damage", 0.0))
	var life: float = float(spec.get("lifetime", 0.0))
	_mech("tri-weapon-refire", _near(cd, base_refire / 1.5, 0.005),
		"full offensive: %.3f s (base %.3f / 1.5 = %.3f)"
			% [cd, base_refire, base_refire / 1.5])
	_mech("tri-weapon-damage", _near(dmg, base_dmg * 1.5, 0.5),
		"full offensive: %.0f (base %.0f x 1.5)" % [dmg, base_dmg])
	_mech("tri-weapon-range", _near(life, base_life * 1.5, 0.01),
		"bolt lifetime %.2f s = range %.0f m (base %.2f s x 1.5)"
			% [life, life * float(spec.get("speed", 0.0)), base_life])
	# and the other corner: zero offensive halves the gun
	m.weapons.clear()
	m.weapons.cooldown = 0.0
	_charge_guns()
	s.set_tri_position(1.0, 0.0, 0.0)          # full drive: offensive w = 0.5
	m.weapons.fire()
	var cd2: float = m.weapons.cooldown
	var dmg2: float = 0.0
	if not m.weapons.bolts.is_empty():
		dmg2 = float(((m.weapons.bolts[0] as Dictionary)["spec"] as Dictionary)["damage"])
	_mech("tri-weapon-starved", _near(cd2, base_refire / 0.5, 0.005)
			and _near(dmg2, base_dmg * 0.5, 0.5),
		"zero offensive: refire %.3f s (want %.3f), damage %.0f (want %.0f)"
			% [cd2, base_refire / 0.5, dmg2, base_dmg * 0.5])
	m.weapons.clear()
	# leave the TRI at full DRIVE -- phase 22 reads the flight model back

func _near(a: float, b: float, eps := 0.01) -> bool:
	return absf(a - b) < eps

## icCannon fits charge from EMPTY (ctor 0x1002cad0 / clone 0x1002cb90 zero
## the store +0xd8, then icCannon::Simulate 0x1002cbd0 refills it at
## TRIWeight * efficiency * power per second). Checks that fire immediately
## top the stores up first -- test setup, like zeroing the cooldown, not a
## change to the extracted law.
func _charge_guns() -> void:
	if m.sys == null:
		return
	for sub: Dictionary in m.sys.systems:
		if sub["class"] == "icCannon":
			sub["energy"] = float(sub.get("capacity", 0.0))

# a bare AiShip for the turret/beam phases: no INI (sys == null), so damage
# lands on the raw hull pool and the numbers stay exact
func _mech_spawn(dname: String, hp: float, at: Vector3) -> AiShip:
	var ai := AiShip.new()
	ai.main = m
	ai.display_name = dname
	ai.behavior = "idle"
	ai.setup({"hit_points": hp, "speed": [1, 1, 1],
		"acceleration": [1, 1, 1], "yaw_rate": 0.001, "pitch_rate": 0.001,
		"roll_rate": 0.001})
	m.add_child(ai)
	ai.global_position = at
	m.ai_ships.append(ai)
	return ai

func _mech_battery(ai: AiShip) -> Dictionary:
	if Turrets.instance == null:
		return {}
	for b in Turrets.instance.batteries:
		if b["owner"] == ai:
			return b
	return {}

func _mech_turret_shots() -> Array:
	var b := _mech_battery(_mech_gs)
	if b.is_empty():
		return []
	# the drone is in some mounts' blind zone (elevation limits); read the
	# busiest gun's timestamps
	var best: Array = []
	for g in b["guns"]:
		var f: Array = g["fired"]
		if f.size() > best.size():
			best = f
	return best

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

## Where the demo pilot points the nose: straight at the target, unless the
## direct route grazes a mass's LDS break-off shell (the same margins as
## main._lds_avoidance: body/star 1.5x radius, station its bounds, +200 m).
## Then aim abeam of the first blocker -- past the point on its shell nearest
## the route, with sea room -- the way a player steers around a gas giant on a
## long LDS leg. Without this the demo re-engages pointed into the mass and
## the drive cycles: spool up, break off, spool up.
func _demo_aim() -> Vector3:
	var t: Vector3 = m._target_pos()
	if t == Vector3.INF:
		return t
	var tn := t.normalized()
	var tlen := t.length()
	var block_rel := Vector3.INF
	var block_margin := 0.0
	var best_along := INF
	for o in m.objects:
		var mult := 1.0
		match o["category"]:
			"body", "star":
				mult = 1.5
			"station", "gunstar":
				mult = 1.0
			_:
				continue
		var rel := Vector3(o["x"] - m.px, o["y"] - m.py, o["z"] - m.pz)
		var along := rel.dot(tn)
		if along <= 0.0 or along >= tlen - 1.0:
			continue    # behind us, or beyond the destination
		var margin := float(o["radius"]) * mult + 200.0
		var off_route := (rel - tn * along).length()
		if (off_route < margin * 1.2 or rel.length() < margin * 1.05) \
				and along < best_along:
			best_along = along
			block_rel = rel
			block_margin = margin
	if block_rel == Vector3.INF:
		return t
	# tangent point: abeam the blocker, perpendicular to the route
	var perp := tn * block_rel.dot(tn) - block_rel  # blocker -> nearest route point
	if perp.length() < 1.0:                          # dead centre: pick a side
		perp = tn.cross(Vector3.UP)
		if perp.length() < 0.5:
			perp = tn.cross(Vector3.RIGHT)
	return block_rel + perp.normalized() * block_margin * 1.5

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
