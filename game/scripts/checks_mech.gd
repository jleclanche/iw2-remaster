extends "checks_jump.gd"
# --mechcheck / --mechslow: the flight-model assertion suite.
# Part of the checks extends chain (issue #31):
# checks_state <- checks_probes <- checks_camp <- checks_base <-
# checks_jump <- checks_mech <- checks.gd (CheckRunner, the dispatcher).
# Same node, same class -- the split mirrors main.gd's layered-file scheme.

# --- flight-model assertions ---------------------------------------------------

func _mech(check: String, ok: bool, detail: String) -> void:
	if not ok:
		_mech_fail += 1
	print("MECHCHECK %s: %s (%s)" % ["PASS" if ok else "FAIL", check, detail])

func _mech_next() -> void:
	demo_phase += 1
	demo_t = 0.0

## The sky shell has to fit inside the frustum at its DEEPEST, which is dead
## ahead (depth = radius * cos(theta)). Asserted against the EFFECTIVE far
## plane -- min(far, near * 2^23) -- not against cam.far, because cam.far is
## what we asked for and the frustum is what we got. Reading the requested
## value instead of the derived one is exactly how the sky came to vanish
## within 21 deg of the view axis while cam.far still reported 600000.
func _ms_sky_depth(_delta: float) -> void:
	var cam: Camera3D = m.cam
	# THE far plane, straight out of the frustum the camera hands the renderer.
	# Deliberately not cam.far and not a formula: cam.far is what we asked for,
	# and any closed form for the float32 loss is a model that can be wrong.
	# Measure what we got.
	var measured := 0.0
	for pl: Plane in cam.get_frustum():
		measured = maxf(measured, -pl.distance_to(cam.global_position))
	for layer in [["flare", m.SKY_FLARE_RADIUS],
			["starfield", m.SKY_STARFIELD_RADIUS],
			["cyclorama", m.SKY_DOME_RADIUS]]:
		var radius: float = layer[1]
		# 10% headroom: a layer sitting just inside the plane is one tweak to
		# near/far away from popping again
		_mech("sky-depth %s" % layer[0], radius < measured * 0.9,
				"radius %.0f vs MEASURED far %.0f (cam.far asked %.0f, near %.3f)"
				% [radius, measured, cam.far, cam.near])
	_mech_next()

# The mechcheck steps, in run order. demo_phase indexes this table, so a new
# step is one method plus one line here -- nothing renumbers.
var _mech_steps: Array[StringName] = [
	&"_ms_setup",
	&"_ms_sky_depth",
	&"_ms_accel",
	&"_ms_brake",
	&"_ms_lateral",
	&"_ms_assist_trim",
	&"_ms_coast_start",
	&"_ms_free_drift",
	&"_ms_lds_engage",
	&"_ms_lds_speed",
	&"_ms_lds_drop",
	&"_ms_sun_radius",
	&"_ms_lds_routearound",
	&"_ms_ap_approach",
	&"_ms_ap_dock",
	&"_ms_dock_null",
	&"_ms_missile_spawn",
	&"_ms_missile_track",
	&"_ms_seeker_cross",
	&"_ms_seeker_cross_assert",
	&"_ms_seeker_dud",
	&"_ms_turret_spawn",
	&"_ms_turret_refire",
	&"_ms_beam_spawn",
	&"_ms_beam_burst",
	&"_ms_player_beam",
	&"_ms_player_beam_gate",
	&"_ms_player_beam_burn",
	&"_ms_field_spawn",
	&"_ms_field_assert",
	&"_ms_field_cull",
	&"_ms_belt_enter",
	&"_ms_belt_assert",
	&"_ms_belt_lds",
	&"_ms_tri_weights",
	&"_ms_tri_drive",
	&"_ms_tow_dock",
	&"_ms_tow_ride",
	&"_ms_contact_law",
	&"_ms_nav_contact",
	&"_ms_contact_pair",
	&"_ms_ship_reorient_arm",
	&"_ms_ship_reorient",
	&"_ms_station_reorient_arm",
	&"_ms_station_reorient",
	&"_ms_hull_solid",
	&"_ms_hull_solid_assert",
	&"_ms_hull_ghost",
	&"_ms_pod_spill",
	&"_ms_pod_spill_assert",
	&"_ms_gatling",
	&"_ms_sign_avatar",
	&"_ms_sign_avatar_assert",
	&"_ms_gas_ball",
	&"_ms_disrupt_arcs",
	&"_ms_remote_missile",
	&"_ms_remote_missile_assert",
	&"_ms_remote_fire",
	&"_ms_remote_fire_assert",
	&"_ms_ghost_autopilot",
	&"_ms_eng_layout",
	&"_ms_star_streaks",
	&"_ms_lightmap_layer",
	&"_ms_turret_fighters",
	&"_ms_attached_fire",
	&"_ms_attached_fire_assert",
	&"_ms_bolt_table",
	&"_ms_lazy_name",
	&"_ms_au_place",
	&"_ms_script_queries",
	&"_ms_station_reactive",
	&"_ms_cutscene_staging",
	&"_ms_set_collision_on",
	&"_ms_cutscene_staging_assert",
	&"_ms_comms_overlay",
	&"_ms_remote_link",
	&"_ms_map_hide",
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
	# per-phase watchdog. Fast suite runs at 4x time (MECH_FAST_TIME_SCALE), so
	# demo_t 180 = 45 s wall -- the ceiling a fast-suite failure may burn (#53).
	# The --mechslow legs are real-time and a few legitimately need longer, so
	# their watchdog stays generous.
	var watchdog := 300.0 if m.mechslow else 180.0
	if demo_t > watchdog:
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
		# the world fold is post-integration (main.late_physics): at this point
		# in the NEXT tick the rendered ship must sit at the fold origin. When
		# the fold ran pre-integration this read velocity * delta -- 5e8 m at
		# the 3e10 m/s LDS ceiling, where float32 jitter tore the view apart
		# (issue #51; measured 5.0e8 by probe before the fix, 0.0 after).
		_mech("lds-render-origin", m.ship.global_position.length() < 1.0,
			"off=%.1f m at v=%s/s" % [m.ship.global_position.length(),
			m._fmt_dist(spd)])
		# the engine flares are WORLD-anchored (ShipEffects is a plain Node,
		# so its quads sit outside the ship's 3D chain): they must be placed
		# at render cadence, post-fold, or they sit a full tick's travel
		# ahead of the folded hull -- the thruster-lights-ahead-in-LDS
		# regression. Here (pre-integration) quad == nozzle when placement
		# is render-time; physics-time placement reads ~v*dt.
		var fxo := -1.0
		if m.ship.fx != null and not m.ship.fx._engine_flares.is_empty():
			var ef: Dictionary = m.ship.fx._engine_flares[0]
			if is_instance_valid(ef["quad"]) and is_instance_valid(ef["node"]):
				fxo = (ef["quad"] as Node3D).global_position.distance_to(
						(ef["node"] as Node3D).global_position)
		_mech("lds-flare-anchored", fxo >= 0.0 and fxo < 1.0,
			"quad-nozzle=%s m at v=%s/s" % [str(fxo), m._fmt_dist(spd)])
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
		# the approach engage is SETUP for the two --mechslow ap checks; the
		# fast suite skips those, and an engaged autopilot must not leak into
		# the missile checks -- the order latches its target (0x100afbc0), so
		# it keeps flying to this station while they re-aim the live contact
		if m.mechslow:
			var near: Dictionary = m._nearest("station")
			for i in m.objects.size():
				if m.objects[i] == near:
					m.target_idx = i
					m.target_ai = null
			m._set_autopilot(1)
		_mech_next()

func _ms_sun_radius(_delta: float) -> void:
	# icSolarSystem::AddSim (iwar2 @ 0x1004cbe0) forces every icSun's radius to
	# 1e8 m, discarding the authored map value (Alpha's record says 1.75e11).
	# Everything downstream -- flare envelope distance, the 1.5x approach
	# marker, the 1.6x LDS avoidance shell -- keys off the 1e8, so a star
	# record that kept its file radius instant-completes approaches and blinds
	# the sky. Assert every loaded star record carries the override and sits in
	# the LDS obstacle list, and that Lucrecia's Base (scene 28) does too;
	# report the star count so an empty system cannot pass vacuously
	# (hoffers_wake has 2).
	var stars := 0
	var bad := ""
	var base_flagged := false
	for o in m.objects:
		if str(o["name"]) == BaseInterior.BASE_NAME:
			base_flagged = bool(o.get("lds_obstacle", false))
		if str(o["category"]) != "star":
			continue
		stars += 1
		if absf(float(o["radius"]) - 1.0e8) > 1.0 \
				or not bool(o.get("lds_obstacle", false)):
			bad = "%s=%.3g" % [str(o["name"]), float(o["radius"])]
	_mech("sun-radius", stars > 0 and bad == "" and base_flagged,
		"%d stars in %s, base-obstacle=%s%s" % [stars, m.system_stem,
			str(base_flagged), "" if bad == "" else ", bad " + bad])
	_mech_next()

func _ms_lds_routearound(_delta: float) -> void:
	# LDS route-around (icAITarget::CheckLDSAvoidance @ 0x1005bd87): a mass in
	# the LDS obstacle list must bend the transit heading so the path grazes
	# its 1.6x-radius shell, never bores through it -- and a record NOT in the
	# list (a type-0 marker, an ordinary station) must not deflect at all
	# (docs/lds.md). Pure-function assert on _lds_avoid_waypoint with synthetic
	# blockers -- deterministic, no real-time flight. State is swapped in and
	# fully restored in-frame.
	var saved_obj: Array = m.objects
	var saved_p := Vector3(m.px, m.py, m.pz)
	var sun_r := 1.0e8    # the AddSim runtime sun radius (0x1004cbe0)
	var shell := sun_r * float(m.LDS_AVOID_SHELL)
	var big := 4.0 * sun_r          # blocker at -4R, destination beyond it
	m.px = 0.0
	m.py = 0.0
	m.pz = 0.0
	m.objects = [{"name": "sun", "category": "star", "radius": sun_r,
			"lds_obstacle": true, "x": 0.0, "y": 0.0, "z": -big}]
	var dest := Vector3(0.0, 0.0, -2.0 * big)
	# direct route (routing OFF) bores dead through the centre -- prove-can-fail
	var direct_off := (Vector3(0.0, 0.0, -big)
			- dest.normalized() * big).length()
	var wp: Vector3 = m._lds_avoid_waypoint(dest)
	# closest approach of the ship->waypoint corridor to the blocker centre
	var c := Vector3(0.0, 0.0, -big)
	var wd := wp.normalized()
	var routed_off := (c - wd * c.dot(wd)).length()
	# the same mass OUTSIDE the obstacle list must not deflect
	m.objects = [{"name": "marker", "category": "body", "radius": sun_r,
			"lds_obstacle": false, "x": 0.0, "y": 0.0, "z": -big}]
	var non_wp: Vector3 = m._lds_avoid_waypoint(dest)
	# and with no blocker at all the waypoint is the raw destination
	m.objects = []
	var clear_wp: Vector3 = m._lds_avoid_waypoint(dest)
	m.objects = saved_obj
	m.px = saved_p.x
	m.py = saved_p.y
	m.pz = saved_p.z
	_mech("lds-routearound",
		direct_off < shell and routed_off >= shell * 0.7
			and non_wp == dest and clear_wp == dest,
		"direct=%.0f routed=%.0f shell=%.0f nonobstacle=%s clear=%s"
			% [direct_off, routed_off, shell,
				str(non_wp == dest), str(clear_wp == dest)])
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

func _ms_dock_null(_delta: float) -> void:
	# #52: docking settles the hull ON the port null (attach_pos 175 m up the
	# station +Y), not at the station centre. Pure call to _settle_on_dockport;
	# px/py/pz and the hull basis are restored in-frame.
	var saved_p := Vector3(m.px, m.py, m.pz)
	var saved_b: Basis = m.ship.global_transform.basis
	var rec := {"category": "station", "name": "Dock Test",
			"x": 1000.0, "y": 2000.0, "z": 3000.0,
			"dock_pos": [0.0, 175.0, 0.0], "dock_hpb": [0.0, 0.0, 0.0]}
	m._settle_on_dockport(rec)
	var landed := Vector3(m.px, m.py, m.pz)
	var want := Vector3(1000.0, 2175.0, 3000.0)   # centre + 175 m up the port
	var off := landed.distance_to(want)
	var centre_off := landed.distance_to(Vector3(1000.0, 2000.0, 3000.0))
	m.px = saved_p.x
	m.py = saved_p.y
	m.pz = saved_p.z
	m.ship.global_transform.basis = saved_b
	_mech("dock-null", off < 1.0 and centre_off > 170.0,
		"landed=%s off=%.2f centre_off=%.1f" % [str(landed), off, centre_off])
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

## Issue #30: a player-fired seeker with a lock must CONVERGE. A magazine
## round is eMissileType 2: armed straight into TRACK (icMissile::Simulate
## case 1) and steered by the embedded icAITarget (0x1006c550). The
## missile-kill step's target sits dead ahead, which an inert dud would ALSO
## hit -- this target sits 90 degrees off the launch axis at 3 km, a geometry
## only real guidance reaches.
func _ms_seeker_cross(_delta: float) -> void:
	var ai: AiShip = m.spawn_hostile(m.ship.global_position
			+ m.ship.global_transform.basis.x * 3000.0)
	ai.hull = 250.0  # one seeker (280 flat blast) kills
	ai.behavior = "idle"
	m.target_ai = ai
	for i in m._secondary_count():
		m._select_secondary(i)
		if "SEEKER" in m.secondary_name.to_upper():
			break
	# missile-kill spam-fires this same magazine, and how many of its 5
	# rounds it eats is a race on kill time -- reload, so this check proves
	# GUIDANCE, not the leftover ammo count (the reported flake)
	if m.secondary_idx >= 0 and m.secondary_idx < m.player_mags.size():
		m.player_mags[m.secondary_idx]["ammo"] = 5
		m._select_secondary(m.secondary_idx)
	_mech_v0 = Vector3.ZERO
	_mech_next()

func _ms_seeker_cross_assert(_delta: float) -> void:
	if m.target_ai != null and is_instance_valid(m.target_ai):
		m._fire_secondary()  # refire clock gates repeats
	# the round must actually be IN TRACK on the locked target, not merely
	# happen to drift into the blast
	for rec: Dictionary in m.missiles.missiles:
		if int(rec["state"]) == Missiles.ST_TRACK and rec["target"] == m.target_ai:
			_mech_v0.x = 1.0
	if m.target_ai == null or not is_instance_valid(m.target_ai):
		_mech("seeker-cross", _mech_v0.x == 1.0,
			"off-axis kill in %.0f s (tracked=%d)" % [demo_t, int(_mech_v0.x)])
		_mech_next()
	elif demo_t > 45.0:
		# name the launch gate that ate the shot, not just the outcome
		var states: Array = []
		for rec: Dictionary in m.missiles.missiles:
			states.append(int(rec["state"]))
		var ammo := -1
		if m.secondary_idx >= 0 and m.secondary_idx < m.player_mags.size():
			ammo = int(m.player_mags[m.secondary_idx].get("ammo", -1))
		_mech("seeker-cross", false,
			"target alive after %.0f s (tracked=%d live=%d states=%s sec=%s ammo=%d heat=%.0f+%.0f)"
			% [demo_t, int(_mech_v0.x), m.missiles.missiles.size(), str(states),
			m.secondary_name, ammo,
			m.sys.heat if m.sys != null else -1.0,
			m.sys.heat_external if m.sys != null else -1.0])
		_mech_reap(m.target_ai)
		m.target_ai = null
		_mech_next()

## The rule's other half: a type-2 round fired with NO lock is a dud --
## Think() finds no target instance and sets state 6 (coast inert to
## lifetime). Firing unlocked must not invent a target.
func _ms_seeker_dud(_delta: float) -> void:
	if _mech_v0.z == 0.0:
		m.target_ai = null
		# the cross step may have run the magazine dry; the dud rule needs a round
		var mag: Dictionary = m.player_mags[m.secondary_idx]
		mag["ammo"] = maxi(int(mag["ammo"]), 1)
		var count: int = m.missiles.missiles.size()
		m._fire_secondary()
		if m.missiles.missiles.size() > count:
			_mech_v0.z = 1.0
			_mech_v0.y = float(demo_t)  # launch time
		return
	# arm_time 0.5 s (sims/weapons/seeker_missile.ini); settled by +1.5 s
	if demo_t < float(_mech_v0.y) + 1.5:
		return
	var rec: Dictionary = m.missiles.missiles.back()
	var ok: bool = int(rec["state"]) == Missiles.ST_DEAD \
			and rec["target"] == null
	_mech("seeker-dud", ok, "state=%d target=%s"
		% [int(rec["state"]), str(rec["target"])])
	_mech_next()

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

func _ms_player_beam(_delta: float) -> void:
	# --- the player's channel-2 beam (#3): the tug's own mining laser -------
	# icBeamProjector::Fire (0x100300c0): the trigger must NOT light the beam
	# below min_fire_energy; from a part-charged bank it lights and holds
	# until dry, damaging the first contact and heating the ship.
	m.weapons.clear()
	var fitted: bool = m.player_beams.size() == 1 \
			and str(m.player_beams[0]["stem"]) == "mining_beam"
	_mech("player-beam-fitted", fitted, "beams=%d" % m.player_beams.size())
	if not fitted:
		_mech_beam = {}
		_mech_next()
		return
	_mech_beam = m.player_beams[0]
	# the drone sits on the BEAM's own axis (the mount null aims it, not the
	# hull nose), inside the 1500 m length
	var mount: Transform3D = m.ship.global_transform * Transform3D(
			_mech_beam["basis"] as Basis, _mech_beam["pos"] as Vector3)
	_mech_drone = _mech_spawn("Beam Drone", 5000.0,
			mount.origin - mount.basis.z * 800.0)
	_mech_drone.velocity = m.ship.velocity
	_mech_drone.radius = 30.0
	m._select_secondary(m.player_mags.size())  # first beam entry of the ring
	_mech("player-beam-select", m.secondary_name == "MINING BEAM",
		"selected '%s'" % m.secondary_name)
	_mech_beam["energy"] = float(_mech_beam["min_fire"]) * 0.5
	_mech_next()

func _ms_player_beam_gate(_delta: float) -> void:
	if _mech_beam.is_empty():
		_mech_next()   # fitted-check already failed and reported
		return
	if demo_t < 0.5:
		m._fire_secondary()   # hold the trigger below the threshold
		return
	_mech("player-beam-lowgate", not bool(_mech_beam["firing"])
			and float(_mech_beam["burst_damage"]) == 0.0,
		"energy %.0f < min_fire %.0f never lit"
			% [float(_mech_beam["energy"]), float(_mech_beam["min_fire"])])
	# a part charge: 2 x min_fire lights up and burns dry -- 400 energy /
	# drain 200 * damage_rate 1000 = 2000 damage, and sqrt(1000) * 5 heat/s
	# stays under the 500 overheat cutoff for the 2 s burn
	_mech_beam["energy"] = float(_mech_beam["min_fire"]) * 2.0
	_mech_v0 = Vector3(_mech_drone.hull, m.sys.heat, 0.0)
	_mech_next()

func _ms_player_beam_burn(_delta: float) -> void:
	if _mech_beam.is_empty():
		_mech_next()
		return
	m._fire_secondary()
	var burst := float(_mech_beam["burst_damage"])
	if burst > 0.0 and not bool(_mech_beam["firing"]):
		_mech("player-beam-burst", absf(burst - 2000.0) < 50.0 * Engine.time_scale,
			"%.0f damage (2 x min_fire 400 / drain 200 * rate 1000)" % burst)
		var took := float(_mech_v0.x) - _mech_drone.hull
		_mech("player-beam-damage", absf(took - burst) < 1.0,
			"drone hull -%.0f" % took)
		# the player-style heat coupling (ai_charge == 0, gate 0x100301d1).
		# Grew-at-all is the failable claim: without the coupling the
		# heatsinks make heat FALL across the 2 s burn.
		_mech("player-beam-heat", m.sys.heat > float(_mech_v0.y) + 5.0,
			"ship heat %.0f -> %.0f" % [float(_mech_v0.y), m.sys.heat])
		m._select_secondary(-1)
		_mech_reap(_mech_drone)
		_mech_next()
	elif demo_t > 30.0:
		_mech("player-beam-burst", false, "energy=%.0f firing=%s after %.0f s"
			% [float(_mech_beam["energy"]), str(_mech_beam["firing"]), demo_t])
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

func _ms_belt_enter(_delta: float) -> void:
	# issue #50: the REAL kind-4 belt record (Hoffer's Asteroid Belt), not the
	# synthetic sphere above. Prove-it-can-fail: assert the zone is OFF out
	# here first -- a spawn check that never saw an empty field is vacuous.
	var f: Fields = m.fields
	var outside := not f.belts.is_empty() \
			and not f._in_belt(f.belts[0], m.px, m.py, m.pz)
	_mech("belt-outside", outside and f.asteroid.live.is_empty(),
		"belts=%d live=%d" % [f.belts.size(), f.asteroid.live.size()])
	if f.belts.is_empty():
		_mech_next()
		return
	# mid-annulus, on-plane: ParseAsteroidBeltInfo's degenerate disc contains
	# in-plane radius R with |y| < w (fields.gd _in_belt)
	var b: Dictionary = f.belts[0]
	m.px = float(b["cx"]) + float(b["r"])
	m.py = float(b["cy"])
	m.pz = float(b["cz"])
	m.ship.velocity = Vector3.ZERO
	m.ship.set_speed = 0.0
	_mech_next()

func _ms_belt_assert(_delta: float) -> void:
	var live: Array = m.fields.asteroid.live
	if live.is_empty() and demo_t < 10.0:
		return
	var vis := 0
	for rk in live:
		if (rk["node"] as Node3D).is_visible_in_tree():
			vis += 1
	_mech("belt-spawn", not live.is_empty() and vis == live.size(),
		"live=%d visible=%d after %.1f s" % [live.size(), vis, demo_t])
	# stay in the belt and light the LDS drive for the astern guard
	m.target_idx = -1
	m.target_ai = null
	m._toggle_lds()
	_mech_next()

func _ms_belt_lds(_delta: float) -> void:
	# The #50/#51 fix-review regression: at shell-per-frame LDS speeds the
	# field flushes and respawns EVERY tick against the PRE-fold focus; the
	# post-integration fold must carry the rock nodes astern before the
	# frame renders, or each tick flashes the whole respawned field around
	# the ship (the reported asteroid strobing). Sampled pre-tick: every
	# live rock must sit far astern, never on screen.
	if m.lds_state == 2 and m.ship.velocity.length() > 1.0e8:
		var live: Array = m.fields.asteroid.live
		var nearest := INF
		for rk in live:
			nearest = minf(nearest, (rk["node"] as Node3D).position.length())
		_mech("belt-lds-astern", not live.is_empty() and nearest > 1.0e6,
			"live=%d nearest=%s m at v=%s/s" % [live.size(), str(nearest),
			m._fmt_dist(m.ship.velocity.length())])
		m._toggle_lds()
		m.ship.velocity = Vector3.ZERO
		m.py += 1.0e8  # strand the rocks; the cull loop reaps them as we go
		_mech_next()
	elif demo_t > 20.0:
		_mech("belt-lds-astern", false, "never reached cruise (state=%d v=%s)"
			% [m.lds_state, str(m.ship.velocity.length())])
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
	# the per-axis tensor scale (FiSim::AddMomentOfInertia @ 0x100c06b0): the
	# pod adds its box tensor plus a UNIT-MASS offset term, so roll (z, no
	# offset penalty for an aft pod) keeps more authority than pitch/yaw and
	# nothing drops below ~0.8 -- the old m*d^2 stand-in sat near 0.09 on x/y
	var ts: Vector3 = m.ship.tow_torque_scale
	var ts_ok: bool = ts.z > ts.x and ts.x > 0.8 and ts.z < 0.95
	_mech("tow-dock", did and mass_ok and scale_ok and ts_ok,
		"tug %.0f + pod %.0f -> accel x %.3f, torque (%.3f %.3f %.3f)"
			% [m.ship.mass, pod.mass, m.ship.mass_scale(), ts.x, ts.y, ts.z])
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

func _ms_contact_law(_delta: float) -> void:
	# --- FiSim::ProcessContact (flux @ 0x100bd920): restitution 0.5 ---------
	# central static hit: r x n = 0, no angular admittance, so the response
	# is exactly v'.n = -0.5 * (v.n). The OLD invented 1.6 bounce gave -0.6;
	# the tolerance separates them, so this fails against the stand-in.
	var n := Vector3(1, 0, 0)
	m.ship.velocity = -n * 12.0
	m.ship.angular_velocity = Vector3.ZERO
	var center: Vector3 = m.ship.global_position - n * 190.0
	m._collide_sphere(center, 200.0, Vector3.ZERO, "MECH WALL")
	var vn: float = m.ship.velocity.dot(n)
	var spin0_ok: bool = m.ship.angular_velocity.length() < 0.001
	_mech("contact-restitution", absf(vn - 6.0) < 0.5 and spin0_ok,
		"central bounce v.n %+.2f (want +6.0 = -0.5 * approach), spin %.5f"
			% [vn, m.ship.angular_velocity.length()])
	# off-centre: the contact sits 30 m above the centre of mass, so part of
	# the impulse must shed into spin and the linear kick shrinks
	m.ship.velocity = -n * 12.0
	var point: Vector3 = m.ship.global_position - n * 5.0 + Vector3(0, 30, 0)
	m._process_contact(point, n, null, Vector3.ZERO, 0.016)
	var vn2: float = m.ship.velocity.dot(n)
	var w2: float = m.ship.angular_velocity.length()
	_mech("contact-angular", w2 > 0.001 and vn2 < 5.99 and vn2 > -11.5,
		"off-centre v.n %+.2f (< the central +6), spin %.4f rad/s" % [vn2, w2])
	m.ship.velocity = Vector3.ZERO
	m.ship.angular_velocity = Vector3.ZERO
	_mech_next()

func _ms_nav_contact(_delta: float) -> void:
	# #55: the system's geography is a KNOWN nav contact. A star far past the
	# identification range still lists as STAR / NAV (never the gold UNKNOWN row)
	# and routes to the NAVIGATION-LOCK class icon 0x36, not the mode-2 EO cube.
	# Pure-function, state swapped in and fully restored in-frame.
	var saved_obj: Array = m.objects
	var saved_idx: int = m.target_idx
	var saved_ai: Variant = m.target_ai
	var saved_p := Vector3(m.px, m.py, m.pz)
	m.px = 0.0
	m.py = 0.0
	m.pz = 0.0
	m.objects = [{"category": "star", "name": "Test Star", "radius": 1.0e8,
			"x": 0.0, "y": 0.0, "z": -9.0e11}]   # far past SENSOR_ID_RANGE
	m.target_idx = 0
	m.target_ai = null
	var row: Dictionary = {}
	for e in m.contact_list():
		if str(e.get("category", "")) == "star":
			row = e
			break
	var icon: int = m.hud._nav_class_icon("star")
	m.objects = saved_obj
	m.target_idx = saved_idx
	m.target_ai = saved_ai
	m.px = saved_p.x
	m.py = saved_p.y
	m.pz = saved_p.z
	_mech("nav-contact",
		not row.is_empty() and str(row.get("type", "")) == "STAR"
			and str(row.get("faction", "")) == "NAV"
			and not bool(row.get("unknown", true)) and icon == 54,
		"row=%s icon=%d" % [str(row), icon])
	_mech_next()

func _ms_contact_pair(_delta: float) -> void:
	# two-body contact: the impulse splits by inverse mass -- momentum is
	# conserved exactly, and the light pod takes the bigger velocity change
	var pod := _mech_spawn("Contact Pod", 1000.0,
			m.ship.global_position + Vector3(90, 0, 0))
	pod.setup_ini("sims/ships/utility/cargo_pod.ini", null)
	pod.mass = 125.0
	pod.recalc_moi()
	pod.velocity = Vector3.ZERO
	pod.angular_velocity = Vector3.ZERO
	m.ship.velocity = Vector3(30, 0, 0)
	m.ship.angular_velocity = Vector3.ZERO
	var p0: Vector3 = m.ship.velocity * m.ship.mass + pod.velocity * pod.mass
	m._collide_ai(pod)
	var p1: Vector3 = m.ship.velocity * m.ship.mass + pod.velocity * pod.mass
	_mech("contact-pair", pod.velocity.x > 1.0 and (p1 - p0).length() < 0.5
			and pod.velocity.x > m.ship.velocity.x,
		"pod kicked %+.1f m/s, player %+.1f, |dp| %.3f"
			% [pod.velocity.x, m.ship.velocity.x, (p1 - p0).length()])
	# --- sim.SetMass + iship.RecalculateMOIFromMass (the a2m24 pairing) -----
	var s = m.pog_world._wrap_ship(pod)
	var moi0: Vector3 = pod.moi
	m.pog_world._s_set_mass(null, [s, 250.0])
	var mass_set: bool = absf(pod.mass - 250.0) < 0.01
	var moi_frozen: bool = pod.moi == moi0   # SetMass does NOT rebuild it
	m.pog_world._sh_recalc_moi(null, [s])
	var moi_ratio: float = pod.moi.x / maxf(moi0.x, 1e-6)
	_mech("setmass-moi", mass_set and moi_frozen
			and absf(moi_ratio - 2.0) < 0.01,
		"mass 125 -> 250, MOI frozen until recalc, then x %.2f" % moi_ratio)
	_mech_reap(pod)
	m.ship.velocity = Vector3.ZERO
	_mech_next()

# --- ship-ship reorientation: the contact is fed REAL hull geometry ----------
# The old centre-to-centre contact put the point on the line of centres
# (r x n = 0), so a ship-ship hit could reorient neither hull -- a purely
# central "dumb bounce". _collide_ai now narrowphases the player's box proxy
# against the other ship's CollisionHull trimesh, so the surface point/normal
# sit off both centres of mass and FiSim::ProcessContact sheds the impulse into
# spin. Two steps: arm attaches the freshly built StaticBody a frame BEFORE the
# query, so it is registered in the physics space when get_rest_info runs.
var _reorient_enemy: AiShip = null
var _reorient_saved := {}

func _ms_ship_reorient_arm(_delta: float) -> void:
	_reorient_saved = {"pos": m.ship.global_position, "rot": m.ship.rotation,
		"vel": m.ship.velocity, "w": m.ship.angular_velocity}
	m.ship.velocity = Vector3.ZERO
	# overlap the player: both hulls are tens of metres, so a ~30 m offset keeps
	# them interpenetrating for a guaranteed rest contact next frame
	var e := _mech_spawn("Reorient Test", 5000.0,
			m.ship.global_position + Vector3(28, 11, 6))
	e.avatar_path = "data/avatars/avatars/cutter/setup.gltf"  # -> gangstership_hull
	e.dims = Vector3(40, 40, 160)
	e.mass = 600.0
	e.recalc_moi()
	e.velocity = Vector3.ZERO
	e.angular_velocity = Vector3.ZERO
	var body: StaticBody3D = m._ensure_ship_hull(e)
	_reorient_enemy = e
	_mech("ship-hull-attach", body != null,
		"cutter avatar -> hull trimesh attached: %s" % (body != null))
	_mech_next()

func _ms_ship_reorient(_delta: float) -> void:
	var e := _reorient_enemy
	if e == null or not is_instance_valid(e):
		_mech("ship-reorient", false, "enemy lost before contact")
		_mech_next()
		return
	# yaw/pitch the player off the enemy's axes so its box contacts as a corner
	# (r_a not parallel to n) -- the player must tumble too, not only the enemy
	m.ship.rotation = Vector3(deg_to_rad(20.0), deg_to_rad(35.0), 0.0)
	m.ship.velocity = (e.global_position - m.ship.global_position).normalized() * 60.0
	m.ship.angular_velocity = Vector3.ZERO
	e.velocity = Vector3.ZERO
	e.angular_velocity = Vector3.ZERO
	m._collide_ai(e)
	var wp: float = m.ship.angular_velocity.length()
	var we: float = e.angular_velocity.length()
	_mech("ship-reorient", wp > 1e-4 and we > 1e-4,
		"player spin %.4f rad/s, enemy spin %.4f rad/s (both > 0 = off-centre)"
			% [wp, we])
	_mech_reap(e)
	_reorient_enemy = null
	m.ship.global_position = _reorient_saved["pos"]
	m.ship.rotation = _reorient_saved["rot"]
	m.ship.velocity = _reorient_saved["vel"]
	m.ship.angular_velocity = _reorient_saved["w"]
	_mech_next()

# --- station reorientation: _collide_hull tumbles the player too --------------
# The station path had the same defect as ship-ship: a 20 m sphere proxy whose
# contact normal is radial (r_a x n = 0) -- a head-on hit ping-ponged the player
# off with no attitude change. _collide_hull now probes with the player's box, so
# a corner/face contact against the station's surface normal is off-CoM and the
# player tumbles. Two steps so the asteroid's freshly attached hull StaticBody is
# registered in the physics space before the query.
var _st_reorient_o: Dictionary = {}
var _st_saved := {}

func _ms_station_reorient_arm(_delta: float) -> void:
	_st_saved = {"pos": m.ship.global_position, "rot": m.ship.rotation,
		"vel": m.ship.velocity, "w": m.ship.angular_velocity}
	var anchor: Vector3 = m.ship.global_position + Vector3(0, 0, -3000)
	var o := {"name": "Reorient Rock", "key": "st_reorient", "category": "station",
		"avatar": HULL_PROBE_AVATAR, "radius": 0.0,
		"x": m.px + anchor.x, "y": m.py + anchor.y, "z": m.pz + anchor.z}
	var model: Node3D = m._load_gltf("data/avatars/" + HULL_PROBE_AVATAR)
	if model != null:
		o["node"] = model
		m.add_child(model)
		model.global_position = anchor
		m._attach_collision_hull(o, model)
		o["radius"] = m._model_bounds_radius(model)
	_st_reorient_o = o
	_mech("station-hull-built",
		bool(o.get("hull", false)) and o.get("node") != null,
		"asteroid CollisionHull attached for the reorient probe")
	_mech_next()

func _ms_station_reorient(_delta: float) -> void:
	var node: Variant = _st_reorient_o.get("node")
	var wp := 0.0
	var diag := "no model"
	if node != null and is_instance_valid(node):
		var centre: Vector3 = (node as Node3D).global_position
		var rad: float = maxf(m._model_bounds_radius(node), 200.0)
		# the hull is a triangle SHELL, not a solid, so the box must STRADDLE the
		# surface to intersect it. Sweep in along an off-radial axis (rotated, so
		# the corner contact is off-CoM) until the box crosses the shell.
		m.ship.rotation = Vector3(deg_to_rad(15.0), deg_to_rad(25.0), 0.0)
		m.ship.angular_velocity = Vector3.ZERO
		var dir := Vector3(0.62, 0.21, 0.11).normalized()
		var params := PhysicsShapeQueryParameters3D.new()
		params.shape = m._player_box_probe()
		params.collision_mask = m.HULL_LAYER
		var ss := m.get_world_3d().direct_space_state
		var hit: Dictionary = {}
		for i in range(44):
			m.ship.global_position = centre + dir * (rad * 1.1 - i * rad * 0.05)
			params.transform = m.ship.global_transform
			hit = ss.get_rest_info(params)
			if not hit.is_empty():
				break
		if hit.is_empty():
			diag = "no rest contact across the sweep"
		else:
			var nn: Vector3 = hit["normal"]
			if nn.dot(m.ship.global_position - (hit["point"] as Vector3)) < 0.0:
				nn = -nn
			m.ship.velocity = -nn * 50.0
			m._collide_hull(_st_reorient_o)
			wp = m.ship.angular_velocity.length()
			diag = "player spin %.4f rad/s off a station hull" % wp
	_mech("station-reorient", wp > 1e-4, diag)
	if node != null and is_instance_valid(node):
		(node as Node3D).queue_free()
	_st_reorient_o = {}
	m.ship.global_position = _st_saved["pos"]
	m.ship.rotation = _st_saved["rot"]
	m.ship.velocity = _st_saved["vel"]
	m.ship.angular_velocity = _st_saved["w"]
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

# --- issue #33: the permanent hull-solidity gate ------------------------------
# Converted from the 2026-07-19 "Hoffer's Wake has no collision" throwaway
# probe. Rams a REAL authored CollisionHull through the exact pipeline every
# streamed station takes (stations.json -> data/json/collisionhulls/*.json ->
# ConcavePolygonShape3D -> _collide_hull's rest_info -> _process_contact), and
# then rams the same model built WITHOUT its collider to prove the fly-through
# detector actually detects -- the check re-earns its own trust every run.
# Verdicts are TARGET-RELATIVE (progress along the ram axis toward the node):
# the floating origin rebases scene coordinates mid-flight, so anything
# measured as displacement-from-start silently lies here.
# the hero asteroid: a CLOSED solid, so the centre-line ram cannot thread an
# authored gap (the modular stations' open frames can pass a ship right past
# their model origin without touching geometry)
const HULL_PROBE_AVATAR := "avatars/HeroAsteroid/setup.gltf"
const HULL_RAM_FROM := 2500.0
const HULL_RAM_SPEED := 250.0  # 16.7 m/frame at 4x, inside the 40 m probe window

var _mech_hull_o: Dictionary = {}
var _mech_hull_hp := Vector2.ZERO  # saved (m.hull, m.sys.hull)

func _hull_probe_station(with_hull: bool) -> Dictionary:
	var fwd: Vector3 = -m.ship.global_transform.basis.z
	# The record goes into m.objects with world coordinates built by the
	# streaming convention (scene = world - scene-origin px/py/pz, so
	# world = px + scene): the REAL streaming and collision frame loops then
	# handle placement and contact -- the exact pipeline every live station
	# takes, which is the thing this gate exists to exercise.
	var anchor: Vector3 = m.ship.global_position + fwd * HULL_RAM_FROM
	var o := {"name": "Hull Probe", "key": "hull_probe", "category": "station",
		"avatar": HULL_PROBE_AVATAR, "radius": 0.0, "axis": fwd,
		"x": m.px + anchor.x, "y": m.py + anchor.y, "z": m.pz + anchor.z}
	var model: Node3D = m._load_gltf("data/avatars/" + HULL_PROBE_AVATAR)
	if model == null:
		return o
	o["node"] = model
	m.add_child(model)
	model.global_position = anchor
	if with_hull:
		m._attach_collision_hull(o, model)
	else:
		o["hull"] = true  # the probe runs against NOTHING: the ghost case
	o["radius"] = m._model_bounds_radius(model)
	m.objects.append(o)
	m.ship.velocity = fwd * HULL_RAM_SPEED
	m.ship.set_speed = HULL_RAM_SPEED
	return o

## a GUIDED ram, re-aimed at the node every frame: the ship's own drift (and
## whatever throttle state earlier steps left behind) must not let the run
## slide past the target laterally -- the projection s cannot see a sideways
## miss. The fixed speed keeps one frame's travel (250 * 4/60 = 16.7 m)
## inside the 20 m probe sphere so the surface cannot be tunnelled between
## frames, and the assignment happens every frame so nothing else can steer.
func _hull_probe_ram() -> void:
	var node: Node3D = _mech_hull_o["node"]
	if node == null or not is_instance_valid(node):
		return
	var dir: Vector3 = \
			(node.global_position - m.ship.global_position).normalized()
	# nose on the target too: the assist trims velocity onto the nose line,
	# so an unaligned nose turns the aimed ram into a stalled fly-by
	var up := Vector3.UP if absf(dir.dot(Vector3.UP)) < 0.99 else Vector3.RIGHT
	m.ship.global_transform.basis = Basis.looking_at(dir, up)
	m.ship.set_speed = HULL_RAM_SPEED
	m.ship.velocity = dir * HULL_RAM_SPEED

func _hull_probe_cleanup(restore_pools: bool) -> void:
	m.objects.erase(_mech_hull_o)
	var node: Variant = _mech_hull_o.get("node")
	if node != null and is_instance_valid(node):
		(node as Node3D).queue_free()
	_mech_hull_o = {}
	m.ship.velocity = Vector3.ZERO
	m.ship.set_speed = 0.0
	if restore_pools:
		m.hull = _mech_hull_hp.x
		if m.sys != null:
			m.sys.hull = _mech_hull_hp.y

## ram progress along the axis: negative approaching, > 0 = past the centre.
## TARGET-RELATIVE on purpose: ship and node scene positions from the same
## frame, so the floating origin's folds cancel out of the difference --
## anything anchored on where the run STARTED is a lie after the first fold.
func _hull_probe_s() -> float:
	var node: Node3D = _mech_hull_o["node"]
	return (m.ship.global_position - node.global_position) \
			.dot(_mech_hull_o["axis"] as Vector3)

func _ms_hull_solid(_delta: float) -> void:
	_mech_hull_o = _hull_probe_station(true)
	var built: bool = bool(_mech_hull_o.get("hull", false)) \
			and _mech_hull_o.get("node") != null
	_mech("hull-built", built,
		"CollisionHull trimesh for %s" % HULL_PROBE_AVATAR.get_file())
	if not built:
		_hull_probe_cleanup(false)
		demo_phase += 2  # nothing to ram; skip both ram phases
	else:
		# the gate is about geometry, not the damage law (contact-law covers
		# that): top the pool up so the ram is survivable at any damage number
		_mech_hull_hp = Vector2(m.hull, m.sys.hull if m.sys != null else 0.0)
		m.hull = 1.0e9
		if m.sys != null:
			m.sys.hull = 1.0e9
		_mech_v0 = Vector3(-1.0e9, 0.0, 0.0)  # (max progress, response seen, -)
	_mech_next()

func _ms_hull_solid_assert(_delta: float) -> void:
	var node: Variant = _mech_hull_o.get("node")
	if node == null or not is_instance_valid(node):
		_mech("hull-solid", false, "probe station vanished mid-run")
		_hull_probe_cleanup(true)
		_mech_next()
		return
	_hull_probe_ram()
	# drive the detector directly: the game loop's own call sits behind the
	# docked/jump/movie gate, which is not this step's subject -- the gate
	# rams the GEOMETRY pipeline (trimesh -> rest_info -> ProcessContact)
	m._collide_hull(_mech_hull_o)
	var s := _hull_probe_s()
	_mech_v0.x = maxf(_mech_v0.x, s)
	# the verdict signal is the RESPONSE, not the trajectory: a real contact
	# runs _process_contact -> damage_player against the topped-up pool. The
	# trajectory after first contact is a scrum (bounce vs re-thrust vs the
	# port-side snap-out) and proves nothing either way.
	if _hull_probe_hit():
		_mech("hull-solid", true,
			"contact at %.0f m from the centre (pool -%.0f)"
				% [-s, 1.0e9 - _hull_probe_pool()])
	elif s > 0.0:
		_mech("hull-solid", false,
			"flew THROUGH: %.0f m past the centre, no damage, no response" % s)
	elif demo_t > 30.0:
		_mech("hull-solid", false,
			"no contact: nearest %.0f m from the centre after %.0f s"
				% [-_mech_v0.x, demo_t])
	else:
		return
	_hull_probe_cleanup(false)  # pools stay topped up through the ghost run
	_mech_next()

func _hull_probe_pool() -> float:
	return m.sys.hull if m.sys != null else m.hull

func _hull_probe_hit() -> bool:
	# ANY damage: one 250 m/s ram contact deals ~2e5 against the 1e9 pool
	return _hull_probe_pool() < 1.0e9 - 1.0 or m.hull < 1.0e9 - 1.0

func _ms_hull_ghost(_delta: float) -> void:
	# DETERMINISTIC (#53): a colliderless twin of the probe station must answer
	# NO contact even at MAXIMUM overlap. Put the hull dead on the station centre
	# and drive the detector (_collide_hull is a static get_rest_info shape query
	# at the ship's position, not a swept test) exactly once. The old check flew
	# the ship in under physics and asserted "no damage while past the centre",
	# which passed vacuously whenever the ram stalled short of the centre -- the
	# "the detector can fail" caveat it printed on itself.
	_mech_hull_o = _hull_probe_station(false)
	var node: Variant = _mech_hull_o.get("node")
	if node == null or not is_instance_valid(node):
		_mech("hull-ghost", false, "probe model failed to load")
		_hull_probe_cleanup(true)
		_mech_next()
		return
	m.hull = 1.0e9      # re-top so "no damage" is assertable for this run
	if m.sys != null:
		m.sys.hull = 1.0e9
	m.ship.global_position = (node as Node3D).global_position   # max overlap
	m._collide_hull(_mech_hull_o)
	_mech("hull-ghost", not _hull_probe_hit(),
		"no collider -> no contact at the station centre (a solid twin hits here)")
	m.ship.global_position = Vector3.ZERO
	_hull_probe_cleanup(true)
	_mech_next()

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
		# cargo 0 is a LEGAL roll (CheapCargoGenerator's fall-through tail,
		# icargoscript.pog:10469, stamped unconditionally by the original --
		# ishipcreation.pog:10606); only a MISSING property (-1) fails
		var s = m.pog_world._wrap_ship(pods[0])
		var cargo := int(m.pog_std._bag(s).get("cargo", -1))
		_mech("pod-spill", cargo >= 0, "%d pods, first cargo id %d"
				% [pods.size(), cargo])
		for p in pods:
			_mech_reap(p)
		_mech_next()
	elif demo_t > 20.0:
		_mech("pod-spill", false, "no pods %d s after the kill" % int(demo_t))
		_mech_next()

var _sign_st: AiShip
var _sign_fx: ShipEffects
var _sign_t0 := 0.0

func _ms_sign_avatar(_delta: float) -> void:
	# icSignAvatar (#10): the casino's 13 sign nulls each grow an additive
	# quad; the 8 two-texture ones flip on frac(t/fps) (draw @ 0x100d0440)
	var model: Node3D = m._load_gltf(
			"data/avatars/avatars/modularstations/casinostation.gltf")
	if model == null:
		_mech("sign-avatar", false, "casinostation avatar failed to load")
		_mech_next()
		return
	_sign_st = _mech_spawn("Sign Casino", 1000.0,
			m.ship.global_position + Vector3(0, -50000, 0))
	_sign_st.add_child(model)
	_sign_fx = ShipEffects.attach(_sign_st, model)
	if not _sign_fx._signs.is_empty():
		# park game time just past the half-cycle: the next fx tick must be
		# showing texture_2
		_sign_fx._sign_t = float(_sign_fx._signs[0]["fps"]) * 0.75
	_sign_t0 = demo_t
	_mech_next()

func _ms_sign_avatar_assert(_delta: float) -> void:
	var quads := 0
	for n in _sign_st.find_children("*", "Node3D", true, false):
		if not n.has_meta("extras") \
				or str(n.get_meta("extras").get("iw2_class", "")) \
					!= "icSignAvatar":
			continue
		for c in n.get_children():
			if c is MeshInstance3D and (c as MeshInstance3D).mesh is QuadMesh:
				quads += 1
	var flipped := false
	if not _sign_fx._signs.is_empty():
		var sg: Dictionary = _sign_fx._signs[0]
		flipped = (sg["mat"] as StandardMaterial3D).albedo_texture == sg["tex2"]
	# the fx node ticks after this check in tree order -- poll until the
	# parked half-cycle phase lands (tex2 shows for fps/2 s per cycle)
	if not flipped and demo_t < _sign_t0 + 5.0:
		return
	_mech("sign-avatar", quads == 13 and _sign_fx._signs.size() == 8
			and flipped, "%d/13 quads, %d/8 animated, flipped=%s"
			% [quads, _sign_fx._signs.size(), flipped])
	_mech_reap(_sign_st)
	_mech_next()

func _ms_gas_ball(_delta: float) -> void:
	# icGasBallAvatar (#10): a nebula seen from outside is 32 balls x 2
	# blend passes at the impostor distance; ball 0 is the fixed centre
	# blob (s1 1.1 / s2 0.6, ctor @ 0x100bdb50)
	var fx: SpaceFx = m.space_fx
	var radius := 2.5e8  # The Effrit's, the one shipped nebula
	var centre := Vector3(fx._px + 1.0e9, fx._py, fx._pz)
	fx._neb = {"x": centre.x, "y": centre.y, "z": centre.z, "radius": radius}
	fx._gas_update(centre, radius, 0.0)
	var vis := 0
	for mi in fx._gas_mis:
		if mi.visible:
			vis += 1
	var k: float = m.IMPOSTOR_DIST / 1.0e9
	var s0: float = (fx._gas_mis[0].material_override as ShaderMaterial) \
			.get_shader_parameter("size")
	var at := fx._gas_anchor.position.length()
	var ok := vis == 64 and absf(at - m.IMPOSTOR_DIST) < 1.0 \
			and absf(s0 - radius * 1.1 * k) < 1.0
	_mech("gas-ball", ok, "%d/64 visible, anchor %.0f m, ball0 %.0f m"
			% [vis, at, s0])
	fx._neb = {}
	fx._gas_hide()
	_mech_next()

func _ms_disrupt_arcs(_delta: float) -> void:
	# icShip::Disrupt attaches the icElectricEffectAvatar arcs (#10):
	# ini:/sfx/disruptor/node scaled max(1, radius/25), emitter life = the
	# disruption seconds; a re-disrupt re-times the SAME node
	var ai := _mech_spawn("Disruptee", 1000.0,
			m.ship.global_position + Vector3(0, -60000, 0))
	var mi := MeshInstance3D.new()
	mi.mesh = BoxMesh.new()
	(mi.mesh as BoxMesh).size = Vector3(60, 60, 60)
	ai.add_child(mi)
	ai.radius = 100.0
	ai.disrupt(3.0, true)
	var fx := ai.disrupt_fx
	var made := fx != null and is_instance_valid(fx)
	var edges := 0
	var life := 0.0
	if made:
		edges = fx._edges.size()
		life = float(fx.sys["time"])
	ai.disrupt(8.0, true)
	var relife := float(fx.sys["time"]) if made else 0.0
	var same: bool = made and ai.disrupt_fx == fx
	_mech("disrupt-arcs", made and edges > 0 and absf(life - 3.0) < 0.01
			and same and absf(relife - (fx._age + 8.0)) < 0.01,
			"fx=%s edges=%d life=%.1f->%.1f same-node=%s"
			% [made, edges, life, relife, same])
	_mech_reap(ai)
	_mech_next()

var _rm_t0 := 0.0
var _rm_fired := false
var _rf_drone: AiShip = null

func _ms_remote_missile(_delta: float) -> void:
	# icRemoteMissile (#10): firing the remote launcher spawns a SHIP, not a
	# missile record; after m_arm_time (1.5 s) the player is flying it
	var mag: Dictionary = Missiles._mag_record("remote_launcher", {})
	mag["clock"] = 1.0e9  # past any refire delay
	_rm_fired = m.missiles.fire_magazine(m.ship, mag, null)
	_rm_t0 = demo_t
	_mech_next()

func _ms_remote_missile_assert(_delta: float) -> void:
	var ms: Missiles = m.missiles
	if not _rm_fired or ms.remotes.is_empty():
		_mech("remote-missile", false, "fired=%s remotes=%d"
				% [_rm_fired, ms.remotes.size()])
		_mech_next()
		return
	var ai: AiShip = ms.remotes[0]["ai"]
	# phase 1: wait for the arm-time link
	if m.remote_ai != ai:
		if demo_t > _rm_t0 + 10.0:
			_mech("remote-missile", false,
					"no link %.1f s after launch" % (demo_t - _rm_t0))
			_mech_next()
		return
	# linked: abort the link -> Think self-destructs the missile
	m.unpossess()
	var before := ms.remotes.size()
	ms._step_remotes(0.0)
	_mech("remote-missile", before == 1 and ms.remotes.is_empty()
			and m.remote_ai == null,
			"linked, then abort left %d live remotes" % ms.remotes.size())
	_mech_next()

func _ms_remote_fire(_delta: float) -> void:
	# #1 residual: the trigger fires the PILOTED hull's own guns. The cutter
	# mounts nps_assault_cannon (icSlugThrower, a fixed battery gun); a
	# frame for Turrets._scan_ai_ships to build its battery, then possess.
	_rf_drone = _mech_spawn("Remote Gunship", 2000.0,
			m.ship.global_position + Vector3(0, -70000, 0))
	_rf_drone.sim_key = "remote_gunship"
	_rf_drone.setup_ini("sims/ships/corporate/cutter.ini", null)
	_mech_next()

func _ms_remote_fire_assert(_delta: float) -> void:
	if Turrets.instance == null \
			or Turrets.instance._battery_for_ship(_rf_drone).is_empty():
		if demo_t > 120.0:   # 30 s wall at 4x -- battery builds in a few frames
			_mech("remote-fire", false, "no battery on the cutter")
			_mech_next()
		return
	m.possess(_rf_drone)
	var before: int = m.weapons.bolts.size()
	m.weapons.cooldown = 0.0
	m.weapons.fire()
	var after: int = m.weapons.bolts.size()
	# ... and the own hull must NOT have fired: every new bolt's shooter is
	# the remote
	var all_remote := true
	for i in range(before, after):
		if m.weapons.bolts[i]["shooter"] != _rf_drone:
			all_remote = false
	m.unpossess()
	_mech("remote-fire", after > before and all_remote,
			"%d bolt(s), all from the linked hull=%s"
			% [after - before, all_remote])
	_mech_reap(_rf_drone)
	_mech_next()

func _ms_ghost_autopilot(_delta: float) -> void:
	# iCutSceneUtilities.EnablePlayerAutopilot (#1): the ghost takes the
	# PILOT, not the hull -- run the PORTED script function itself
	var cs = m.pog_rt.script("icutsceneutilities")
	var hull = cs.enable_player_autopilot()
	var w: PogWorld = m.pog_rt.world
	var ghost = m.pog_rt.native("iship.findplayership", [])
	var parked: bool = m.pilot_parked and ghost != null \
			and ghost != w.player_sim() and ghost.parent == w.player_sim()
	# the script flies the HULL by the handle Enable returned: an approach
	# order must engage the player autopilot, not vanish into _order_for
	var st: AiShip = _mech_spawn("Ghost Waypoint", 100.0,
			m.ship.global_position - m.ship.global_transform.basis.z * 60000.0)
	st.sim_key = "ghost_waypoint"
	m.pog_rt.native("iai.giveapproachorderadvanced",
			[hull, w._wrap_ship(st), 0.0, 1.0, 0])
	var engaged: bool = m.ap_mode == 1
	var incomplete: bool = not PogVM._truthy(
			m.pog_rt.native("iai.isordercomplete", [hull]))
	# ... and the reverse: Disable installs the pilot back and frees the ghost
	cs.disable_player_autopilot()
	var restored: bool = not m.pilot_parked \
			and m.pog_rt.native("iship.findplayership", []) == w.player_sim()
	m.ap_mode = 0
	_mech("ghost-autopilot",
			parked and engaged and incomplete and restored,
			"parked=%s engaged=%s incomplete=%s restored=%s"
			% [parked, engaged, incomplete, restored])
	_mech_reap(st)
	_mech_next()

func _ms_eng_layout(_delta: float) -> void:
	# the engineering page's recovered furniture (#35): the four bottom
	# status pills span 35..605 on the 640 page ((w-96)/4 pitch +32), and
	# the sprite table's 65..68 run is the re-paired builder assignment
	# (wrench at atlas x 66; the TRI glyphs at 99/132/165 -- the old
	# off-by-one drew a wrench on the DRIVE row)
	var rects: Array = HudScreens.eng_bottom_rects()
	var xs_ok: bool = rects.size() == 4 \
			and absf(rects[0].position.x - 35.0) < 0.01 \
			and absf(rects[3].end.x - 605.0) < 0.01 \
			and absf(rects[0].size.x - 118.5) < 0.01
	var spr_ok: bool = int(Hud.SPR[65][0]) == 66 and int(Hud.SPR[66][0]) == 99 \
			and int(Hud.SPR[67][0]) == 132 and int(Hud.SPR[68][0]) == 165
	_mech("eng-layout", xs_ok and spr_ok,
			"pills=%d x0=%.1f x3end=%.1f w=%.1f tri-glyphs@%d/%d/%d" % [
				rects.size(), rects[0].position.x, rects[3].end.x,
				rects[0].size.x, int(Hud.SPR[66][0]), int(Hud.SPR[67][0]),
				int(Hud.SPR[68][0])])
	_mech_next()

func _ms_star_streaks(_delta: float) -> void:
	# icStarfieldAvatar rotation streaks (#18): a camera slew turns a bright
	# star into a line between its two projected positions, intensity
	# 1/length (the 0x640-entry table @ 0x10171f98); below ~2 px it stays a
	# point. Pure math -- drive star_streak directly.
	var dir := Vector3.FORWARD
	var still: Array = m.star_streak(dir, Basis.IDENTITY, Basis.IDENTITY,
			500.0)
	# a 2-degree yaw at 500 px/rad = ~17.5 px of motion: a streak, dimmed
	# to 2/17.5 of the point intensity
	var turned := Basis(Vector3.UP, deg_to_rad(2.0))
	var seg: Array = m.star_streak(dir, Basis.IDENTITY, turned, 500.0)
	var ok := still.is_empty() and seg.size() == 3
	var len_px := 0.0
	var want := 0.0
	if ok:
		len_px = (seg[0] as Vector3).angle_to(seg[1] as Vector3) * 500.0
		want = 2.0 / (deg_to_rad(2.0) * 500.0)
		ok = absf(len_px - deg_to_rad(2.0) * 500.0) < 0.1 \
				and absf(float(seg[2]) - want) < 0.001
	_mech("star-streaks", ok,
			"rest=%s slew len=%.1f px mult=%.3f (want %.3f)"
			% [still.is_empty(), len_px, float(seg[2]) if seg.size() == 3
				else -1.0, want])
	_mech_next()

func _ms_lightmap_layer(_delta: float) -> void:
	# the SHDR layer scheme (original.md 7x, incl. the open question: only
	# base + glow observably render): every textured surface must import as
	# a StandardMaterial3D with its albedo texture resolved (authored
	# texture, or the baked glow atlas for slot-2 surfaces) and NO shader
	# overrides -- a missing texture or a stale bake fails here.
	var model: Node3D = m._load_gltf("data/avatars/avatars/am_remote/setup.gltf")
	if model == null:
		_mech("lightmap-layer", false, "am_remote avatar failed to load")
		_mech_next()
		return
	var host := _mech_spawn("Lightmap Probe", 100.0,
			m.ship.global_position + Vector3(0, -80000, 0))
	host.add_child(model)
	ShipEffects.attach(host, model)
	var surfs := 0
	var baked := 0
	var shader_overrides := 0
	for n in host.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		for si in mi.mesh.get_surface_count():
			surfs += 1
			var mat := mi.get_active_material(si)
			if mat is ShaderMaterial:
				shader_overrides += 1
			elif mat is StandardMaterial3D \
					and (mat as StandardMaterial3D).albedo_texture != null:
				baked += 1
	_mech("lightmap-layer",
			surfs >= 1 and baked == surfs and shader_overrides == 0,
			"%d/%d surfaces carry the baked atlas (%d shader overrides)"
			% [baked, surfs, shader_overrides])
	_mech_reap(host)
	_mech_next()

func _ms_turret_fighters(_delta: float) -> void:
	# iship.CreateTurretFighters (#5): one icTurretShip per fitted loadout
	# slot (cap 2), named for the wingmen; zero fitted -> an empty list
	var lo = m.pog_rt.econ.loadout
	var before: int = lo.turret_fighters
	lo.turret_fighters = 0
	var none: Array = m.pog_rt.native("iship.createturretfighters", [])
	lo.turret_fighters = 2
	var two: Array = m.pog_rt.native("iship.createturretfighters", [])
	lo.turret_fighters = before
	var ships := 0
	var fitted := 0
	for s in two:
		if s != null and s.node is AiShip \
				and is_instance_valid(s.node):
			ships += 1
			# the authored hull: 500 hp and a fitted subsim list (the
			# turret_fighter.ini record, not the bare-record default)
			var ai := s.node as AiShip
			if ai.sys != null and absf(ai.sys.hull_max - 500.0) < 0.5 \
					and not ai.sys.systems.is_empty():
				fitted += 1
	_mech("turret-fighters",
			none.is_empty() and two.size() == 2 and ships == 2
			and fitted == 2,
			"0-fitted=%d 2-fitted=%d live=%d authored-hulls=%d"
			% [none.size(), two.size(), ships, fitted])
	for s in two:
		if s != null and s.node != null and is_instance_valid(s.node):
			_mech_reap(s.node)
	_mech_next()

var _af_fighter: AiShip = null
var _af_victim: AiShip = null
var _af_bolts0 := 0

func _ms_attached_fire(_delta: float) -> void:
	# icTurretShip attached fire (#5): WeaponsUseExplicitTarget on a hull
	# without a turret battery must make its guns solve onto the target
	# turret-style (Think 0x10034700 mode 3) -- bolts leave toward the
	# lead point regardless of the hull's own attitude
	_af_fighter = _mech_spawn("TFighter", 500.0,
			m.ship.global_position + Vector3(0, -90000, 0))
	_af_fighter.sim_key = "tfighter_probe"
	_af_victim = _mech_spawn("TFighter Prey", 500.0,
			_af_fighter.global_position + Vector3(1000, 0, 0))
	_af_victim.sim_key = "tfighter_prey"
	# face the fighter AWAY from the prey: the turret solve must not care
	_af_fighter.global_transform.basis = Basis.looking_at(
			Vector3(-1, 0, 0), Vector3.UP)
	var w: PogWorld = m.pog_rt.world
	_af_bolts0 = m.weapons.bolts.size()
	m.pog_rt.native("iship.weaponsuseexplicittarget",
			[w._wrap_ship(_af_fighter), w._wrap_ship(_af_victim)])
	_mech_next()

func _ms_attached_fire_assert(_delta: float) -> void:
	var fired := 0
	var at_prey := 0
	for i in range(_af_bolts0, m.weapons.bolts.size()):
		var b: Dictionary = m.weapons.bolts[i]
		if b.get("shooter") != _af_fighter:
			continue
		fired += 1
		var dir: Vector3 = (b["vel"] as Vector3).normalized()
		var want: Vector3 = (_af_victim.global_position
				- _af_fighter.global_position).normalized()
		if dir.dot(want) > 0.9:
			at_prey += 1
	if fired == 0 and demo_t < 200.0:
		return
	# ... and LockDownWeapons must clear the solve
	m.pog_rt.native("iship.lockdownweapons",
			[m.pog_rt.world._wrap_ship(_af_fighter)])
	var cleared: bool = _af_fighter.weapons_target == null
	_mech("attached-fire", fired > 0 and at_prey == fired and cleared,
			"%d bolt(s), %d toward the prey, lock-cleared=%s"
			% [fired, at_prey, cleared])
	_mech_reap(_af_fighter)
	_mech_reap(_af_victim)
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

## Issue #28: every icBullet the shipped subsims can fire must resolve to an
## extracted BOLT_BY_PROJECTILE row whose ballistics EQUAL the projectile INI
## (sims/weapons/*.ini) -- no stem may fall through to another bolt's spec.
## Walks the real data/ini/subsims/systems population, so a new weapon INI or
## a deleted table row fails here, and a broken walk fails the floor check
## (the shipped data has 11 bullet stems).
func _ms_bolt_table(_delta: float) -> void:
	var base: String = ShipSystems._base()
	var stems := {}  # stem -> projectile ini rel
	var dirs: Array[String] = ["subsims/systems"]
	var scanned := 0
	while not dirs.is_empty():
		var rel: String = dirs.pop_back()
		var da := DirAccess.open(base.path_join("data/ini").path_join(rel))
		if da == null:
			continue
		for sub in da.get_directories():
			dirs.append(rel.path_join(sub))
		for fn in da.get_files():
			if not fn.ends_with(".ini"):
				continue
			scanned += 1
			var sys: Dictionary = ShipSystems.read_ini(
					rel.path_join(fn.trim_suffix(".ini")))
			var tpl := str((sys["props"] as Dictionary).get(
					"projectile_template", ""))
			if tpl.is_empty():
				continue
			if str(ShipSystems.read_ini(tpl)["class"]) == "icBullet":
				stems[tpl.get_file()] = tpl
	var bad := 0
	for stem: String in stems:
		var row: Dictionary = PbcWeapons.BOLT_BY_PROJECTILE.get(stem, {})
		if row.is_empty():
			_mech("bolt-table %s" % stem, false, "no BOLT_BY_PROJECTILE row")
			bad += 1
			continue
		var p: Dictionary = ShipSystems.read_ini(str(stems[stem]))["props"]
		var diffs := PackedStringArray()
		for key in ["damage", "penetration", "half_time", "speed", "lifetime"]:
			if not is_equal_approx(float(row[key]), float(p.get(key, 0.0))):
				diffs.append("%s %s!=%s" % [key, row[key], p.get(key, "?")])
		if bool(row.get("bypass_shields", false)) \
				!= (int(float(p.get("bypass_shields", "0"))) != 0):
			diffs.append("bypass_shields")
		# the wav is avatar-sourced, not INI-sourced; assert the FILE exists
		# ("" is the authored no-sound case, the megabolter)
		var wav := str(row.get("wav", ""))
		if not wav.is_empty() and not FileAccess.file_exists(
				base.path_join("data/audio").path_join(wav)):
			diffs.append("missing " + wav)
		if not FileAccess.file_exists(base.path_join("data/textures")
				.path_join(str(row.get("texture", ""))) + ".png"):
			diffs.append("missing texture %s" % row.get("texture", "(none)"))
		if not diffs.is_empty():
			_mech("bolt-table %s" % stem, false, " ".join(diffs))
			bad += 1
	_mech("bolt-table", bad == 0 and stems.size() >= 11,
		"%d/%d icBullet stems verified against %d weapon INIs"
			% [stems.size() - bad, stems.size(), scanned])
	_mech_next()

## Issue #27: placement natives must survive AU-scale coordinates. At
## x = 1e12 m a Vector3 ULP exceeds 100 km, so a scripted 2 km offset folded
## through float32 abs_pos() collapses. Two record sims at 1e12; PlaceRelativeTo
## / PlaceInFrontOf / PlaceBetween each place one against the other; the
## load-bearing mission-gate read (sim.DistanceBetween, doubles) must answer
## the authored offset within a metre.
func _ms_au_place(_delta: float) -> void:
	var w: PogWorld = m.pog_rt.world
	var ref = w._wrap_record({"key": "au_ref", "name": "au_ref",
		"category": "station", "x": 1.0e12, "y": 0.0, "z": 0.0, "radius": 10.0})
	var mov = w._wrap_record({"key": "au_mov", "name": "au_mov",
		"category": "station", "x": 1.0e12, "y": 0.0, "z": 0.0, "radius": 10.0})
	var diffs := PackedStringArray()
	m.pog_rt.native("sim.placerelativeto", [mov, ref, 2000.0, 0.0, 0.0])
	var d := float(m.pog_rt.native("sim.distancebetween", [mov, ref]))
	if absf(d - 2000.0) > 1.0:
		diffs.append("PlaceRelativeTo %.0f" % d)
	m.pog_rt.native("sim.placeinfrontof", [mov, ref, 3000.0])
	d = float(m.pog_rt.native("sim.distancebetween", [mov, ref]))
	if absf(d - 3000.0) > 1.0:
		diffs.append("PlaceInFrontOf %.0f" % d)
	# a second anchor 8 km out: the lerp must land ON the line, 2 km in
	var far = w._wrap_record({"key": "au_far", "name": "au_far",
		"category": "station", "x": 1.0e12 + 8000.0, "y": 0.0, "z": 0.0,
		"radius": 10.0})
	m.pog_rt.native("sim.placebetween", [mov, ref, far, 0.25])
	d = float(m.pog_rt.native("sim.distancebetween", [mov, ref]))
	if absf(d - 2000.0) > 1.0:
		diffs.append("PlaceBetween %.0f" % d)
	for k in ["au_ref", "au_mov", "au_far"]:
		w.sims.erase(k)
	_mech("au-place", diffs.is_empty(),
		"all offsets exact at 1e12 m" if diffs.is_empty() else " ".join(diffs))
	_mech_next()

func _ms_script_queries(_delta: float) -> void:
	# iship.BrightnessOf (iship.dll @ 0x100022f0) and iship.IsLDSScrambled
	# (@ 0x10003240), driven through the runtime dispatch exactly as the
	# mission scripts drive them (a0m50/a1m08 stealth loops, iscriptedorders).
	var w: PogWorld = m.pog_rt.world
	var me = w.player_sim()
	# scene coords: PogSim.abs_pos treats an AI node's position as the offset
	# from the player, so distance = |node.position| regardless of where the
	# ship node has drifted between scene folds
	var hostile: AiShip = m.spawn_hostile(Vector3(4000, 0, 0))
	var viewer = w._wrap_ship(hostile)
	# brightness() must be nonzero or every product below passes vacuously --
	# park some heat on the ledger for the duration
	var heat0: float = m.sys.heat
	m.sys.heat = 0.5 * ShipSystems.HEAT_DAMAGE_THRESHOLD
	var b0: float = m.sys.brightness()
	# double-precision distance: mechcheck parks the world at ~1e12 m where
	# float32 Vector3 math washes a 4 km separation out to 0 -- which is
	# exactly the bug dist_to exists to avoid
	var d: float = me.dist_to(viewer)
	# range = 0 -> unattenuated; range = 2d -> t = 0.5 exactly, so linear
	# reads b*(1-t) and squared reads b*(1-t*t); range = d/2 -> t clamps to 1
	var raw := float(m.pog_rt.native("iship.brightnessof", [me, viewer, 0.0, 0]))
	var lin := float(m.pog_rt.native(
			"iship.brightnessof", [me, viewer, d * 2.0, 0]))
	var sq := float(m.pog_rt.native(
			"iship.brightnessof", [me, viewer, d * 2.0, 1]))
	var far := float(m.pog_rt.native(
			"iship.brightnessof", [me, viewer, d * 0.5, 0]))
	m.sys.heat = heat0
	_mech("brightness-of", b0 > 0.0 and d > 0.0
			and absf(raw - b0) < 1e-4
			and absf(lin - b0 * 0.5) < 1e-4
			and absf(sq - b0 * 0.75) < 1e-4
			and far == 0.0,
		"b0=%.3f raw=%.3f lin=%.3f sq=%.3f far=%.3f d=%.0f"
			% [b0, raw, lin, sq, far, d])
	var s0 := int(m.pog_rt.native("iship.isldsscrambled", [me]))
	m.disrupt(5.0)
	var s1 := int(m.pog_rt.native("iship.isldsscrambled", [me]))
	m.disrupt_time = 0.0
	var s2 := int(m.pog_rt.native("iship.isldsscrambled", [me]))
	_mech("lds-scrambled-query", s0 == 0 and s1 == 1 and s2 == 0,
		"%d/%d/%d" % [s0, s1, s2])
	# turret designation (#6): WeaponsUseExplicitTarget locks every turret
	# onto the target (ConfigureWeapons(1,t,0) 0x1007b8a0 -> SetMode(1)
	# 0x10033800); WeaponTargetsFromContactList clears the lock so turrets
	# pick their own again -- and the battery stays armed through both
	var gs := _mech_spawn("Query Gunstar", 6000.0, Vector3(0, 0, -8000))
	gs.setup_ini("sims/ships/navy/gunstar.ini", null)
	var gsim = w._wrap_ship(gs)
	var r1 := int(m.pog_rt.native(
			"iship.weaponsuseexplicittarget", [gsim, viewer]))
	var bat: Dictionary = _mech_battery(gs)
	var locked_on: bool = not bat.is_empty() and bat.get("locked") == hostile
	var r2 := int(m.pog_rt.native(
			"iship.weapontargetsfromcontactlist", [gsim]))
	var released: bool = not bat.is_empty() and bat.get("locked") == null \
			and bool(bat.get("armed", false))
	_mech("turret-designation", r1 == 1 and locked_on and r2 == 1 and released,
		"designate=%d locked=%s release=%d armed=%s"
			% [r1, locked_on, r2, bat.get("armed", false)])
	# group membership (#4): AddSim must set the sim's own back-reference,
	# because sim.Group(member) answers which group it was added to -- the
	# Kompira initiation's v14 pairing (iacttwo.pog 1970) polls exactly
	# that, and without the back-reference it was structurally false for
	# every POG-created group
	var grp: Variant = m.pog_rt.native("group.create", [])
	m.pog_rt.native("group.addsim", [grp, viewer])
	var back_ok: bool = m.pog_rt.native("sim.group", [viewer]) == grp
	m.pog_rt.native("group.removesim", [grp, viewer])
	var clear_ok: bool = m.pog_rt.native("sim.group", [viewer]) == null
	_mech("group-backref", back_ok and clear_ok,
		"addsim back=%s removesim cleared=%s" % [back_ok, clear_ok])
	gs.queue_free()
	m.ai_ships.erase(gs)
	hostile.queue_free()
	m.ai_ships.erase(hostile)
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

# The dispatch target _ms_station_reactive registers: a stand-in POG package
# whose one export records what the engine passed it.
class _ReactiveProbe extends PogScript:
	var calls: Array = []

	func on_reactive(a, b, c) -> Variant:
		calls.append([a, b, c])
		return 0


func _ms_station_reactive(_delta: float) -> void:
	# ihabitat.SetReactiveFunction (ihabitat.dll @ 0x100027d0: assigns the ONE
	# static icStation::m_damage_function) + icStation::ApplyWeaponDamage
	# (iwar2.dll @ 0x10068b70): a weapon hit on a station starts the
	# registered task with (station, aggressor, damage). Register a probe
	# package, put a bolt on a station record, and read back what arrived.
	var probe := _ReactiveProbe.new()
	# wire the runtime so dispatch takes the REAL path -- the engine starts
	# the reactive function as its own task (_pog_spawn), not a bare call
	probe.rt = m.pog_rt
	probe.name = "checkprobe"
	m.pog_rt.scripts["checkprobe"] = probe
	m.pog_rt.native("ihabitat.setreactivefunction", ["checkprobe.OnReactive"])
	var node := Node3D.new()
	m.add_child(node)
	var rec := {"name": "Probe Station", "key": "probe_station",
		"category": "station", "node": node, "x": 0.0, "y": 0.0, "z": 0.0,
		"radius": 100.0}
	m.objects.append(rec)
	m.on_bolt_hit(node, Vector3.ZERO, m.ship, {"spec": PbcWeapons.PBC_BOLT})
	m.pog_rt.native("ihabitat.setreactivefunction", [])  # clears the static
	m.on_bolt_hit(node, Vector3.ZERO, m.ship, {"spec": PbcWeapons.PBC_BOLT})
	m.objects.erase(rec)
	node.queue_free()
	m.pog_rt.scripts.erase("checkprobe")
	var one_call: bool = probe.calls.size() == 1
	var ok := one_call
	var detail := "calls=%d" % probe.calls.size()
	if one_call:
		var station = probe.calls[0][0]
		var aggressor = probe.calls[0][1]
		var dmg := float(probe.calls[0][2])
		ok = station != null and String(station.name) == "probe_station" \
			and aggressor != null and bool(aggressor.is_player) \
			and absf(dmg - 160.0) < 0.01
		detail = "station=%s player-aggressor=%s dmg=%.0f (cleared: no 2nd call)" \
			% [station.name if station != null else "null",
				aggressor != null and bool(aggressor.is_player), dmg]
	probe.free()
	_mech("station-reactive", ok, detail)
	_mech_next()


## Issue #11: icPopUpCommsScreen runtime verification. The overlay is a
## windowless C++ screen (no POG builder) that iBaseGUI.OnConversationStart
## raises over whatever is up. Driven through the ported callback exactly as
## the engine would: in flight the stack is empty, so gui.OverlayScreen lands
## it on `screens` -- it must show up there, it must NOT become the visible
## screen (a windowless screen would blank the base GUI's draw path;
## visible_screen skips it), and popping must restore the stack.
func _ms_comms_overlay(_delta: float) -> void:
	var ui = m.pog_rt.ui
	var deep0: int = (ui.screens as Array).size()
	m.pog_rt.script("ibasegui").on_conversation_start()
	var raised := ""
	if (ui.screens as Array).size() > deep0:
		raised = str((ui.screens as Array).back().name)
	elif not (ui.screens as Array).is_empty() \
			and not ((ui.screens as Array).back().over as Array).is_empty():
		raised = str(((ui.screens as Array).back().over as Array).back().name)
	var vis = ui.visible_screen()
	var no_blank: bool = vis == null or not (vis.windows as Array).is_empty()
	ui._pop_screen(null, [])
	var restored: bool = (ui.screens as Array).size() == deep0
	_mech("comms-overlay",
		raised == "icPopUpCommsScreen" and no_blank and restored,
		"raised=%s visible=%s restored=%s"
			% [raised if raised != "" else "(nothing)",
			"(none)" if vis == null else str(vis.name), str(restored)])
	_mech_next()

## Issue #1: the REMOTE LINK end to end, driven exactly as the game drives
## it -- the HUD's REM LINK node dispatches iRemotePilot.Install, which
## links to the CURRENT TARGET when it carries remote_connection_available.
## Asserted: possession (piloted() and control follow the drone,
## FindPlayerShip answers the drone), the watchdog's live hit_points read,
## and the toggle back (pilot returns, drone released to its own AI).
func _ms_remote_link(_delta: float) -> void:
	var drone: AiShip = m.spawn_hostile(m.ship.global_position
			+ Vector3(2000, 0, 0))
	drone.behavior = "idle"
	# a unique identity: _wrap_ship caches by name, and earlier steps have
	# already parked a (freed) "Marauder Cutter" wrap in the registry
	drone.display_name = "Remote Probe Drone"
	drone.sim_key = "remote_probe_drone"
	var w = m.pog_rt.world._wrap_ship(drone)
	m.pog_rt.native("object.addintproperty",
			[w, "remote_connection_available", 1])
	m.target_ai = drone
	m.pog_rt.ui.dispatch("iRemotePilot.Install")
	var linked: bool = m.remote_ai == drone and m.piloted() == drone \
			and drone.behavior == "piloted"
	var fps_remote: bool = \
			m.pog_rt.native("iship.findplayership", []) == w
	# the watchdog (iremotepilot local_0) reads hit_points off both ends
	# every 4 s; a dead read severs the link, so it must be the LIVE hull
	var hp := float(m.pog_rt.native("object.floatproperty",
			[w, "hit_points"]))
	var hp_live: bool = absf(hp - drone.hull) < 0.5 and hp > 0.0
	m.pog_rt.ui.dispatch("iRemotePilot.Install")   # toggle the link off
	var released: bool = m.remote_ai == null and m.piloted() == m.ship \
			and drone.behavior != "piloted"
	_mech("remote-link",
		linked and fps_remote and hp_live and released,
		"linked=%s fps=%s hp=%.0f released=%s"
			% [linked, fps_remote, hp, released])
	m.target_ai = null
	_mech_reap(drone)
	_mech_next()

var _mech_burn: AiShip = null


var _ghost_hostile: AiShip = null
var _ghost_hsim: Variant = null
var _ghost_hull0 := 0.0
var _ghost_off_ok := false

func _ms_cutscene_staging(_delta: float) -> void:
	# sim.SetCollision (sim.dll @ 0x10005760): collision off -> a staged overlap
	# produces NO contact (the player glides through); back on, the same geometry
	# collides and damages. The OFF half is asserted here; the ON half runs next
	# frame (_ms_set_collision_on) because _collide_ai now narrowphases the ship's
	# real hull trimesh, and a freshly attached StaticBody only enters the physics
	# space on the following tick.
	var w: PogWorld = m.pog_rt.world
	# just BEYOND the box's front half-length, so the two hulls overlap at a
	# clean frontal contact -- engulfing the small hostile inside the long box
	# makes get_rest_info return an ambiguous side/rear exit normal
	var off: float = m.ship.dims.z * 0.5 + 8.0
	var hostile: AiShip = m.spawn_hostile(
			m.ship.global_position - m.ship.global_transform.basis.z * off)
	# a unique key, or _wrap_ship hands back the cached PogSim of the freed
	# "Marauder Cutter" the brightness step spawned
	hostile.sim_key = "mech_ghost"
	hostile.behavior = "idle"          # freeze it across the two frames
	hostile.velocity = Vector3.ZERO
	m._ensure_ship_hull(hostile)       # attach the trimesh now; registers by N+1
	var hsim = w._wrap_ship(hostile)
	m.pog_rt.native("sim.setcollision", [hsim, 0])
	var hull0: float = m.hull
	m.ship.velocity = -m.ship.global_transform.basis.z * 10.0
	m._collisions()
	_ghost_off_ok = absf(m.hull - hull0) < 0.01
	m.ship.velocity = Vector3.ZERO
	_ghost_hostile = hostile
	_ghost_hsim = hsim
	_ghost_hull0 = hull0
	# isim.StartExplosion (0x1007c950: timer = FLT_MAX, the burn) +
	# isim.StopExplosion (0x1007c970: cut to DoFinalExplosion, destroy=1)
	_mech_burn = _mech_spawn("Burn Target", 500.0,
			m.ship.global_position + Vector3(0, 2000, 0))
	var bsim = w._wrap_ship(_mech_burn)
	m.pog_rt.native("isim.startexplosion", [bsim, 0])
	var burning := false
	for c in _mech_burn.get_children():
		if c is DeathSequence:
			burning = true
	m.pog_rt.native("isim.stopexplosion", [bsim, 0, 1])
	_mech("start-explosion", burning, "staged burn present=%s" % burning)
	_mech_next()


func _ms_set_collision_on(_delta: float) -> void:
	# the ON half of set-collision, a frame after the hostile's hull trimesh was
	# attached, so the StaticBody is now registered in the physics space: the same
	# staged overlap that ghosted with collision off must collide and damage now
	var hostile := _ghost_hostile
	var solid := false
	var diag := "enemy lost"
	if hostile != null and is_instance_valid(hostile):
		m.pog_rt.native("sim.setcollision", [_ghost_hsim, 1])
		m.ship.angular_velocity = Vector3.ZERO
		# steer into the contact normal the narrowphase reports, so the staged
		# overlap is unambiguously an APPROACH (the gate needs (vp_a-vp_b).n <
		# 0.1); then let _collisions run the real response
		var params := PhysicsShapeQueryParameters3D.new()
		params.shape = m._player_box_probe()
		params.transform = m.ship.global_transform
		params.collision_mask = m.SHIP_HULL_LAYER
		var hit: Dictionary = m.get_world_3d().direct_space_state.get_rest_info(params)
		if hit.is_empty():
			diag = "no rest contact"
		else:
			var nn: Vector3 = hit["normal"]
			if nn.dot(m.ship.global_position - (hit["point"] as Vector3)) < 0.0:
				nn = -nn
			m.ship.velocity = -nn * 40.0
			var hull0: float = m.hull
			m._collisions()
			solid = m.hull < hull0 - 0.01
			diag = "dhull=%.3f" % (hull0 - m.hull)
		m.ship.velocity = Vector3.ZERO
		m.hull = m.hull_max
		hostile.queue_free()
		m.ai_ships.erase(hostile)
	_ghost_hostile = null
	_mech("set-collision", _ghost_off_ok and solid,
		"off: no contact=%s, on: damaged=%s (%s)" % [_ghost_off_ok, solid, diag])
	_mech_next()


func _ms_cutscene_staging_assert(_delta: float) -> void:
	# the curtain runs on the physics tick after the cut: the final blast
	# fires and the destroy flag removes the sim
	if _mech_burn == null or not is_instance_valid(_mech_burn):
		_mech("stop-explosion", true, "curtained and destroyed")
		_mech_burn = null
		_mech_next()
	elif demo_t > 10.0:
		_mech("stop-explosion", false, "burn target still alive")
		_mech_next()


func _ms_map_hide(_delta: float) -> void:
	# The plot's entity toggles end to end (istartsystem.HideMapLocations
	# drives these): imapentity.SetMapVisibility must stamp the live record
	# AND main.entity_flags; a foreign-system call must land under the
	# FOREIGN system's key (not alias the resident one); and a system reload
	# -- which rebuilds every record from JSON -- must re-apply the flag.
	var probe := "Military FTL Outpost"
	var before := false          # ...proving the flag can be true first
	for o: Dictionary in m.objects:
		if str(o["name"]) == probe:
			before = bool(o.get("map_visible", true))
	var h = m.pog_world._s_find_in_system(null,
			[probe, "map:/geog/badlands/hoffers_wake"])
	m.pog_ents._m_map_visibility(null, [h, 0])
	var fh = m.pog_world._s_find_in_system(null,
			["Marauder Central HQ", "map:/geog/badlands/dante"])
	m.pog_ents._m_map_visibility(null, [fh, 0])
	var stored: bool = not bool(m.entity_flag(
			"hoffers_wake", probe, "map_visible", true))
	var foreign: bool = not bool(m.entity_flag(
			"dante", "Marauder Central HQ", "map_visible", true))
	m.start_in_system("hoffers_wake")   # rebuild the records from JSON
	var after := true
	for o: Dictionary in m.objects:
		if str(o["name"]) == probe:
			after = bool(o.get("map_visible", true))
	_mech("map-hide", before and stored and foreign and not after,
			"before=%s stored=%s foreign-keyed=%s survives-reload=%s"
			% [before, stored, foreign, not after])
	# leave no probe state behind for the later steps
	m.entity_flags.clear()
	for o: Dictionary in m.objects:
		if str(o["name"]) == probe:
			o["map_visible"] = true
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

