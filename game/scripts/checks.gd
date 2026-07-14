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
var _mech_gs: AiShip = null      # turret platform (gunstar.ini)
var _mech_drone: AiShip = null   # turret / beam target
var _mech_beam: Dictionary = {}  # the beam mount under test
var _mech_field: Dictionary = {} # synthetic icFieldSphere for the fields phase

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
		12:  # a seeker missile tracks and kills: 500 hp / 280 flat blast = 2 hits
			var ai: AiShip = m.spawn_hostile(m.ship.global_position
					- m.ship.global_transform.basis.z * 3000.0)
			ai.hull = 500.0
			ai.behavior = "idle"
			m.target_ai = ai
			m._cycle_secondary()
			_mech_v0 = Vector3(ai.hull, 0.0, 0.0)
			_mech_next()
		13:
			if m.target_ai == null or not is_instance_valid(m.target_ai):
				_mech("missile-kill", true, "%.0f s" % demo_t)
				_mech_next()
			elif demo_t > 60.0:
				_mech("missile-kill", false, "hull=%.0f after %.0f s"
					% [m.target_ai.hull, demo_t])
				m.kill_ai(m.target_ai)
				_mech_next()
			else:
				# the recovered blast is flat 280 (seeker, disable_attenuation):
				# hull must step by exact multiples of it
				if is_instance_valid(m.target_ai) \
						and m.target_ai.hull < float(_mech_v0.x):
					var drop: float = float(_mech_v0.x) - m.target_ai.hull
					if absf(fmod(drop, 280.0)) > 0.5 \
							and absf(fmod(drop, 280.0) - 280.0) > 0.5:
						_mech("missile-damage", false, "step=%.1f" % drop)
					_mech_v0.x = m.target_ai.hull
				m._fire_secondary()
		14:  # icTurret: a gunstar's nps_turret_pbc fires pbc_bolt on the
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
		15:
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
				m.kill_ai(_mech_gs)
				_mech_next()
			elif demo_t > 30.0:
				_mech("turret-refire", false, "%d shots in %.0f s"
					% [_mech_turret_shots().size(), demo_t])
				m.kill_ai(_mech_gs)
				_mech_next()
		16:  # icBeamProjector/icBeam: nps_beam_weapon charges to capacity
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
		17:
			var burst := float(_mech_beam["burst_damage"])
			if burst > 0.0 and not bool(_mech_beam["firing"]):
				_mech("beam-burst", absf(burst - 3600.0) < 50.0,
					"%.0f damage (capacity 1800 / drain 500 * rate 1000)" % burst)
				var took := float(_mech_v0.x) - _mech_drone.hull
				_mech("beam-damage", absf(took - burst) < 1.0,
					"hull -%.0f (src=1: no LDA, bare hull here)" % took)
				m.kill_ai(_mech_drone)
				_mech_next()
			elif demo_t > 30.0:
				_mech("beam-burst", false, "energy=%.0f firing=%s after %.0f s"
					% [float(_mech_beam["energy"]),
						str(_mech_beam["firing"]), demo_t])
				_mech_next()
		18:  # iiSimField: drop a synthetic icFieldSphere on the player and let
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
		19:
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
		20:
			if m.fields.asteroid.live.is_empty() \
					and m.fields.debris.live.is_empty():
				_mech("field-cull", true, "%.2f s" % demo_t)
				_mech_next()
			elif demo_t > 5.0:
				_mech("field-cull", false, "%d still live after %.0f s"
					% [m.fields.asteroid.live.size()
						+ m.fields.debris.live.size(), demo_t])
				_mech_next()
		21:  # --- the TRI (task #60) -------------------------------------------
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
		22:  # the drive axis had a frame to reach ShipFlight through _player_control
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
		23:
			print("MECHCHECK done: %s" % ("ALL PASS" if _mech_fail == 0
				else "%d FAILURES" % _mech_fail))
			get_tree().quit(0 if _mech_fail == 0 else 1)
	if demo_t > 300.0:
		print("MECHCHECK: phase %d timeout" % demo_phase)
		get_tree().quit(1)

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
