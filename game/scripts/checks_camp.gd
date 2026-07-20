extends "checks_probes.gd"
# The campaign smoke suites: --newgamecheck / --campcheck (+ stub gate).
# Part of the checks extends chain (issue #31):
# checks_state <- checks_probes <- checks_camp <- checks_base <-
# checks_jump <- checks_mech <- checks.gd (CheckRunner, the dispatcher).
# Same node, same class -- the split mirrors main.gd's layered-file scheme.

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

## A control on the PDA screen by the POG function it dispatches.
func _ngt_button(fn: String) -> PogUi.PogWindow:
	var scr: PogUi.PogScreen = m.pog_rt.ui.visible_screen()
	if scr == null:
		return null
	for w in scr.windows:
		if w.on_press == fn:
			return w
	return null

func _newgametest(_delta: float) -> void:
	match _ngt_stage:
		0:
			if demo_t > 1.5:
				# NOT fast: we are testing whether the real opening dialogue
				# actually plays and the mission advances past its first
				# `until_comms` step -- fast mode auto-completes it and hides
				# any hang.
				#
				# The button is the ORIGINAL's now (SPMainPDAScreen builds it),
				# so press THAT rather than this file's old capsule list, which
				# the front end no longer draws. Pressing the stale list is how
				# a broken START NEW GAME slipped through: nothing here touched
				# the control the player actually clicks.
				m.menu.open()
				# The debug pickers ride the REAL stack now (PogUi.debug_screen
				# composes them from the PDA screens' own igui recipe):
				# entering one OVERLAYS icDebugPickerScreen on the
				# still-standing PDA, and Back/Escape pops straight back to it.
				m.menu._enter_mode("ships")
				var over: PogUi.PogScreen = m.pog_rt.ui.visible_screen()
				var picker_up: bool = over != null \
						and over.name == "icDebugPickerScreen"
				print("NEWGAMETEST: %s — debug picker overlays the PDA (%s)"
					% ["PASS" if picker_up else "FAIL",
						"none" if over == null else over.name])
				if not picker_up:
					get_tree().quit(1)
					return
				m.pog_rt.native("gui.popscreen", [])
				var back: PogUi.PogScreen = m.pog_rt.ui.visible_screen()
				var pda_back: bool = back != null \
						and back.name == "icSPMainPDAScreen"
				print("NEWGAMETEST: %s — the PDA was still under it (%s)"
					% ["PASS" if pda_back else "FAIL",
						"none" if back == null else back.name])
				# INSTANT ACTION goes through igui.OverlayCustomScreen, which is
				# a POG function, not a native: it sets g_custom_gui_screen and
				# overlays icCustomGUIScreen, whose builder IS that global
				# (igui.pog:748, ui.gd:468). parity.md had this down as a
				# missing native; it was ported all along.
				var ia: PogUi.PogWindow = _ngt_button(
					"iPDAGUI.SPMainPDAScreen_OnInstant")
				if ia != null:
					m.pog_rt.ui.activate(ia)
					var ias: PogUi.PogScreen = m.pog_rt.ui.visible_screen()
					var rows: int = ias.windows.size() if ias != null else 0
					print("NEWGAMETEST: %s — INSTANT ACTION builds (%s, %d windows)"
						% ["PASS" if rows > 0 else "FAIL",
							"none" if ias == null else ias.name, rows])
					m.pog_rt.native("gui.popscreen", [])
				var start: PogUi.PogWindow = _ngt_button(
					"iPDAGUI.SPMainPDAScreen_OnStart")
				if start == null:
					print("NEWGAMETEST: FAIL — no START NEW GAME button on ",
						m.pog_rt.ui.visible_screen().name \
						if m.pog_rt.ui.visible_screen() != null else "<no screen>")
					get_tree().quit(1)
					return
				m.pog_rt.ui.activate(start)
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
				if not ok:
					_ngt_stage = 0
					get_tree().quit(1)
					return
				# Now the PAUSE menu, which is a DIFFERENT builder
				# (icSPFlightPDAScreen: RESUME / LOAD / OPTIONS / QUIT,
				# ipdagui.pog:376) and was never covered by anything.
				m.menu.open()
				var res: PogUi.PogWindow = _ngt_button(
					"iPDAGUI.SPFlightPDAScreen_OnResume")
				var scrn: PogUi.PogScreen = m.pog_rt.ui.visible_screen()
				print("NEWGAMETEST: %s — pause menu is the flight PDA (%s, RESUME=%s)"
					% ["PASS" if res != null else "FAIL",
						"none" if scrn == null else scrn.name, res != null])
				if res == null:
					get_tree().quit(1)
					return
				m.pog_rt.ui.activate(res)
				_ngt_stage = 2
		2:
			# SPFlightPDAScreen_OnResume is nothing but gui.PopScreen, so the
			# menu has to notice its own screen went away and stand down --
			# otherwise RESUME leaves the front-end chrome up with no controls
			# on it, which is exactly what it did.
			var closed: bool = not m.menu.visible and not get_tree().paused
			print("NEWGAMETEST: %s — RESUME returns to flight (menu=%s paused=%s)"
				% ["PASS" if closed else "FAIL", m.menu.visible,
					get_tree().paused])
			_ngt_stage = 0
			get_tree().quit(0 if closed else 1)
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
				var sg := _stub_gate(_known_stubs())
				print("NEWGAMECHECK: %s — objects=%d, pog=%s, mission steps=%d"
					% ["PASS" if ok else "FAIL", m.objects.size(), live_pog, steps])
				_ng_stage = 0
				get_tree().quit(0 if ok and sg else 1)
	if demo_t > 40.0:
		print("NEWGAMECHECK: TIMEOUT stage ", _ng_stage)
		_ng_stage = 0
		get_tree().quit(1)

func _campcheck(_delta: float) -> void:
	if m.use_port:
		_campcheck_port()
		return
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
				var sg := _stub_gate(_known_stubs())
				print("CAMPCHECK: PASS — waypoint objective completed, ",
					"dialogue queued=", m.comms.queue.size())
				get_tree().quit(0 if ck and sg else 1)
	if demo_t > 90.0:
		print("CAMPCHECK: TIMEOUT phase ", demo_phase, " idx=", m.mission.idx)
		get_tree().quit(1)

# Observed stub baselines (issue #25), per campaign driver, recorded
# 2026-07-19. The PORT set is what the istartsystem boot chain reaches:
# SetReactiveFunction (#26), CreateTurretFighters (#5), SetCullable
# (presentation, deliberate). The legacy hand-authored driver reaches no
# stubs. A name DISAPPEARING from a run is progress: update the list. A name
# APPEARING is a regression or a newly reached code path -- the gate FAILS
# so a human looks.
const KNOWN_STUBS_LEGACY: Array[String] = []
# EMPTY: every native the acts 0-3 boot chain touches is real now
# (iship.CreateTurretFighters was the last holdout, #5). Any stub hit
# fails the gate.
const KNOWN_STUBS_PORT: Array[String] = []


func _known_stubs() -> Array[String]:
	return KNOWN_STUBS_PORT if m.use_port else KNOWN_STUBS_LEGACY


## Issue #25: the observed stub hits of a run ARE its remaining-work list.
## Print them, then hold the line against the mission's recorded baseline.
func _stub_gate(known: Array[String]) -> bool:
	var hits: Dictionary = PogRuntime.stub_hits
	var names := hits.keys()
	names.sort()
	for n in names:
		print("  stub hit: %s x%d" % [n, int(hits[n])])
	var fresh: Array[String] = []
	for n2 in names:
		if not known.has(n2):
			fresh.append(n2)
	for k in known:
		if not hits.has(k):
			print("STUBGATE: %s no longer hit — progress; update the baseline" % k)
	if fresh.is_empty():
		print("STUBGATE: PASS — %d stub hits, all in the recorded baseline"
			% names.size())
		return true
	print("STUBGATE: FAIL — stub hits missing from the baseline: ",
		", ".join(fresh))
	return false

## The same mission driven by the PORTED runtime (--campcheck --port): the
## signals are the POG side's own -- the waypoint record iutilities creates,
## the contact-list selection gate (iship.CurrentTarget == the waypoint), the
## proximity gate, and the objective keyed by the script's own id reaching
## OS_Succeeded. This is the ported campaign's end-to-end depth marker (#4).
func _campcheck_port() -> void:
	match demo_phase:
		0:
			if demo_t > 1.0:
				m.comms.fast = true
				m.start_campaign()
				print("CAMPCHECK(port): campaign booting")
				demo_phase = 1
		1:
			if m.movie != null and demo_t > 3.0:
				m.skip_movie()
			# iact0mission10 local_1276: CreateWaypointNear -> the record
			# "Clay's Waypoint" (a0_m10_name_waypoint) appears in m.objects
			var idx := _object_index("Clay's Waypoint")
			if idx >= 0:
				m.target_ai = null
				m.target_idx = idx        # gate 1: CurrentTarget == waypoint
				var o: Dictionary = m.objects[idx]
				m.px = o["x"]
				m.py = o["y"]
				m.pz = o["z"]             # gate 2: DistanceBetween ~ 0
				print("CAMPCHECK(port): waypoint selected + reached")
				demo_phase = 2
		2:
			m.ship.velocity = Vector3.ZERO
			# keep re-asserting the position: the boot chain can still move
			# the player (cutscene placement, HUD-tour staging) between the
			# selection gate and the distance gate
			var wp := _object_index("Clay's Waypoint")
			if wp >= 0:
				var o2: Dictionary = m.objects[wp]
				m.px = o2["x"]
				m.py = o2["y"]
				m.pz = o2["z"]
			var obj: Dictionary = m.mission.objectives.get(
					"a0_m10_objectives_approach_clay", {})
			if obj.get("done", false):
				print("CAMPCHECK(port): a0m10 approach_clay SUCCEEDED — ",
					"advancing to act 1 (igame.NextAct, the end-of-act call)")
				m.pog_rt.native("igame.nextact", ["iActOne"])
				demo_phase = 3
		3:
			# iActOne.Main -> MasterScript chapter 0 -> iact1mission01.Main.
			# The mission opens with a FIGHT: two Puffins get an attack order,
			# and change_iff is only added once their group is empty
			# (iact1mission01.pog local_604). The check plays the player's
			# part -- kill the attackers -- and the mission's own logic
			# raises the objective.
			for a in m.ai_ships:
				if is_instance_valid(a) and not a.dying \
						and a.behavior == "attack":
					m.kill_ai(a)
			if m.mission.objectives.has("a1_m01_objective_change_iff"):
				print("CAMPCHECK(port): act 1 m01 fight won — docking at ",
					"Maurice's (the change_iff gate, issue #4)")
				demo_phase = 30
		30:
			# the dock watcher (iact1mission01 local_8531): IsDocked(player)
			# AND DistanceBetween < 450 at Maurice's Freighter Service Depot
			# raises change_iff to DONE and adds find_base. The check plays
			# the player's docking: park at the depot record, docked_at set.
			var depot := _object_index("Maurice's Freighter Service Depot")
			if depot >= 0:
				var od: Dictionary = m.objects[depot]
				m.px = od["x"]
				m.py = od["y"]
				m.pz = od["z"]
				m.ship.velocity = Vector3.ZERO
				m.docked_at = str(od["name"])
			if m.mission.objectives.has("a1_m01_objective_find_base"):
				print("CAMPCHECK(port): docked — change_iff done, find_base ",
					"raised; casting off for Lucrecia's")
				m.docked_at = ""
				demo_phase = 31
		31:
			# the base watcher (local_7459): distance to Lucrecia's Base
			# < 20 km completes find_base and sets mission progress 10 --
			# a1m01 run birth to completion
			var luc := _object_index("Lucrecia's Base")
			if luc >= 0:
				var ol: Dictionary = m.objects[luc]
				m.px = ol["x"]
				m.py = ol["y"]
				m.pz = ol["z"]
				m.ship.velocity = Vector3.ZERO
			var fb: Dictionary = m.mission.objectives.get(
					"a1_m01_objective_find_base", {})
			if fb.get("done", false):
				print("CAMPCHECK(port): act 1 m01 COMPLETE (find_base done)",
					" — advancing to act 2")
				m.pog_rt.native("igame.nextact", ["iActTwo"])
				demo_phase = 4
		4:
			# iActTwo.Main -> MasterScript -> (no SkipAct) -> chapter switch
			# case 0 -> iact2mission01.Main: the cutscene stages the Haven
			# Station rescue, a three-line conversation runs (comms.fast
			# auto-answers), and the mission's own logic raises the protect
			# objective (iact2mission01.pog @ 4084..4353).
			if m.mission.objectives.has("a2_m01_objectives_protect"):
				print("CAMPCHECK(port): act 2 m01 protect raised — ",
					"defending the LOR platform (issue #4)")
				demo_phase = 40
		40:
			# the protect gate (iact2mission01 case 4733/4823): the objective
			# completes when the ATTACKER GROUP is empty. The check plays
			# the player's defence -- kill everything on the attack
			for a2a in m.ai_ships:
				if is_instance_valid(a2a) and not a2a.dying \
						and a2a.behavior == "attack":
					m.kill_ai(a2a)
			var prot: Dictionary = m.mission.objectives.get(
					"a2_m01_objectives_protect", {})
			if prot.get("done", false):
				print("CAMPCHECK(port): act 2 m01 protect COMPLETE — ",
					"advancing to act 3")
				m.pog_rt.native("igame.nextact", ["iActThree"])
				demo_phase = 5
		5:
			# iActThree -> MasterScript -> iact3mission01.Main: the mission
			# SENDS an email and holds until the player READS it
			# (iact3mission01.pog @ 2359..2490); the check reads it the way
			# the PDA inbox would (iemail.MarkAsRead), and the rendezvous
			# objective follows.
			var mail: Variant = m.pog_rt.native("iemail.find",
					["html:/text/act_3/act3_mission01_email"])
			if mail != null and not (mail is int and int(mail) == 0):
				m.pog_rt.native("iemail.markasread", [mail])
			if m.mission.objectives.has("a3_m01_objectives_redezvous"):
				print("CAMPCHECK(port): act 3 m01 rendezvous raised — ",
					"flying to the League Rendezvous (issue #4)")
				demo_phase = 50
		50:
			# the movement watch (iact3mission01 case 2597,
			# abb_common.WatchSimsMovement): reaching the
			# a3_m01_waypoint_initial_meeting waypoint ("League Rendezvous")
			# completes the objective at case 2745
			var wp3 := _object_index("League Rendezvous")
			if wp3 >= 0:
				var o3: Dictionary = m.objects[wp3]
				m.px = o3["x"]
				m.py = o3["y"]
				m.pz = o3["z"]
				m.ship.velocity = Vector3.ZERO
			var rdv: Dictionary = m.mission.objectives.get(
					"a3_m01_objectives_redezvous", {})
			if rdv.get("done", false):
				var ck := _checkpoint_check()
				var sg := _stub_gate(_known_stubs())
				print("CAMPCHECK(port): PASS — a1m01 and a2m01-protect ",
					"COMPLETE, a3m01 rendezvous reached; objectives=",
					m.mission.objectives.size())
				get_tree().quit(0 if ck and sg else 1)
	if demo_t > 240.0:
		var tail: Array = []
		for i in range(maxi(0, m.objects.size() - 10), m.objects.size()):
			tail.append(str(m.objects[i]["name"]))
		var wpi := _object_index("Clay's Waypoint")
		var probe := "no waypoint"
		if wpi >= 0:
			var wsim = m.pog_rt.world._wrap_record(m.objects[wpi])
			var me = m.pog_rt.world.player_sim()
			probe = "dist=%.1f imr=%.1f" % [
				float(m.pog_rt.native("sim.distancebetween", [me, wsim])),
				float(m.pog_rt.native(
					"iai.innermarkerradius", [wsim, me]))]
		var ships: Array = []
		for a2 in m.ai_ships:
			if is_instance_valid(a2):
				ships.append("%s/%s" % [a2.display_name, a2.behavior])
		print("CAMPCHECK(port): TIMEOUT phase ", demo_phase,
			" objectives=", m.mission.objectives.keys(),
			" last objects=", tail, " ", probe,
			" halted=", m.pog_rt.halted if m.pog_rt != null else "?",
			" in_conv=", m.pog_rt.gameapi.in_conversation,
			" speaking=", m.comms.speaking(),
			" queue=", m.comms.queue.size(),
			" ai=", ships)
		get_tree().quit(1)


func _object_index(name: String) -> int:
	for i in m.objects.size():
		if str(m.objects[i]["name"]) == name:
			return i
	return -1


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

