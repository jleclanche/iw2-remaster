class_name CheckRunner
extends Node
# The automated test harness: --demo / --mechcheck / --jumpcheck /
# --uicheck / --campcheck / --motioncheck cmdline modes. Owns all the
# phase machines that used to live in main.gd; `m` is the game root.

var m: Node3D  # main

var demo_t := 0.0
var demo_phase := 0
var _mc_shot := 0
var _mech_fail := 0
var _mech_t0 := 0.0
var _mech_v0 := Vector3.ZERO
var _mech_home := Vector3.ZERO

func step(delta: float) -> void:
	demo_t += delta
	if m.campcheck:
		_campcheck(delta)
	elif m.uicheck:
		_uicheck(delta)
	elif m.jumpcheck:
		_jumpcheck(delta)
	elif m.mechcheck:
		_mechcheck(delta)
		if m.ap_mode > 0 and m.docked_at == "":
			m._autopilot_process(delta)
	elif m.motioncheck:
		_motioncheck(delta)
	elif m.geogcheck:
		_geogcheck(delta)
	else:
		_demo(delta)

func _shot(name: String) -> void:
	var img := get_viewport().get_texture().get_image()
	img.save_png(m._base().path_join("data/screenshots/%s.png" % name))

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

func _mechcheck(_delta: float) -> void:
	match demo_phase:
		0:  # move 1 Gm off-plane, clear of all masses, then full throttle
			_mech_home = Vector3(m.px, m.py, m.pz)
			m.py += 1.0e9
			m.target_idx = -1
			m.target_ai = null
			m.ship.set_speed = m.ship.max_speed.z
			_mech_t0 = demo_t
			_mech_next()
		1:  # tug reaches 850 m/s in 850/150 = 5.67 s (INI constants)
			if m.ship.forward_speed() >= m.ship.max_speed.z - 10.0:
				var t := demo_t
				_mech("accel-to-850", t > 4.5 and t < 7.5, "%.2f s" % t)
				m.ship.set_speed = 0.0
				_mech_next()
			elif demo_t > 15.0:
				_mech("accel-to-850", false,
					"timeout, v=%.0f" % m.ship.forward_speed())
				_mech_next()
		2:  # flight computer brakes back to zero
			if m.ship.velocity.length() < 5.0:
				_mech("brake-to-zero", true, "%.2f s" % demo_t)
				m.ship.input_thrust.x = 1.0
				_mech_next()
			elif demo_t > 15.0:
				_mech("brake-to-zero", false, "v=%.0f" % m.ship.velocity.length())
				_mech_next()
		3:  # lateral thruster pushes sideways
			if demo_t > 2.0:
				var lat := absf((m.ship.velocity * m.ship.global_transform.basis).x)
				_mech("lateral-thrust", lat > 30.0, "%.0f m/s" % lat)
				m.ship.input_thrust.x = 0.0
				_mech_next()
		4:  # assist trims lateral drift back out
			if demo_t > 4.0:
				var lat := absf((m.ship.velocity * m.ship.global_transform.basis).x)
				_mech("assist-trim", lat < 5.0, "%.1f m/s" % lat)
				m.ship.assist = false
				m.ship.input_thrust.z = 1.0
				_mech_next()
		5:  # free flight: thrust then coast, velocity must persist
			if demo_t > 1.5:
				m.ship.input_thrust.z = 0.0
				_mech_v0 = m.ship.velocity
				_mech_next()
		6:
			if demo_t > 3.0:
				var dv: float = (m.ship.velocity - _mech_v0).length()
				_mech("free-flight-drift", dv < 1.0 and _mech_v0.length() > 50.0,
					"v=%.0f dv=%.2f" % [_mech_v0.length(), dv])
				m.ship.assist = true
				_mech_next()
		7:  # LDS: must exceed drive speeds by orders of magnitude
			if m.ship.velocity.length() < 5.0:
				_mech_v0 = Vector3(m.px, m.py, m.pz)
				m._toggle_lds()
				_mech("lds-engage", m.lds_state == 1, "state=%d" % m.lds_state)
				_mech_next()
			elif demo_t > 15.0:
				_mech("lds-engage", false, "never stopped")
				_mech_next()
		8:
			if demo_t > 15.0:
				var spd: float = m.ship.velocity.length()
				var traveled := (Vector3(m.px, m.py, m.pz) - _mech_v0).length()
				_mech("lds-speed", m.lds_state == 2 and spd > 1.0e6,
					"v=" + m._fmt_dist(spd) + "/s")
				_mech("lds-travel", traveled > 1.0e8, m._fmt_dist(traveled))
				m._toggle_lds()
				_mech_next()
		9:  # LDS drop: back to conventional speeds under assist
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
		10:  # autopilot approach: arrive ON the marker sphere and stop
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
		11:  # autopilot dock
			if m.docked_at != "":
				_mech("ap-dock", true, m.docked_at)
				m._undock()
				_mech_next()
			elif demo_t > 90.0:
				_mech("ap-dock", false, "timeout")
				_mech_next()
		12:
			print("MECHCHECK done: %s" % ("ALL PASS" if _mech_fail == 0
				else "%d FAILURES" % _mech_fail))
			get_tree().quit(0 if _mech_fail == 0 else 1)
	if demo_t > 300.0:
		print("MECHCHECK: phase %d timeout" % demo_phase)
		get_tree().quit(1)

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
					var d := Vector3(o["x"] - m.px, o["y"] - m.py,
						o["z"] - m.pz).length()
					if d > 0.5 * 1.496e11 and d < bestd:
						bestd = d
						m.target_idx = i
				print("DEMO: destination ", m.objects[m.target_idx]["name"])
				demo_phase = 1
		1:
			m._face_target()
			var dir: Vector3 = m._target_pos().normalized()
			if (-m.ship.global_transform.basis.z).angle_to(dir) < 0.05:
				m._toggle_lds()
				_mech_v0 = Vector3(m.px, m.py, m.pz)
				demo_phase = 2
		2:
			m._face_target()
			if m.lds_state == 0 and m._target_distance() > 1.0e6 \
					and m._lds_clearance() > 0.0 and demo_t < 400.0:
				m._toggle_lds()  # LDSI dropout en route: re-engage
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
