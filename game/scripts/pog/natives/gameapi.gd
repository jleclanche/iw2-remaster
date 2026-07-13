class_name PogGameApi
extends RefCounted

## icomms, iai, iobjectives, idirector, ihud, igame, inifile: the packages that
## drive what the player actually sees a mission do.
##
## The happiest discovery here is that icomms lines up with the dialogue system
## we already had. The scripts say
##     iconversation.Say(0, "name_clay", "a0_m20_dialogue_clay_ok_this")
## and that third argument is the very key comms.say_key() looks up in
## strings.json. So the original bytecode can drive the existing conversation
## queue, VO playback, Clay's 3D head and the subtitles, unchanged.
##
## iai is the order system: the scripts do not steer ships, they issue orders
## (approach, attack, escort, formate, dock, flee) and poll IsOrderComplete.
## AiShip only had "patrol" and "attack", so orders are modelled here and the
## ship's waypoint/behaviour fields are driven from them.

var vm   ## the host: PogRuntime for the ported scripts, PogVM for the oracle
var world: PogWorld
var game: Node3D = null

## icomms conversation state
var responses: Array = []          ## [{text, code}]
var chosen_code: int = 0
var in_conversation := false
var _asked := false

## iai orders, keyed by the AiShip node's instance id
var orders: Dictionary = {}

## inifile handles
var _inis: Dictionary = {}


class PogOrder extends RefCounted:
	var kind: String = ""          ## approach / attack / escort / formate / dock / flee
	var target = null              ## PogWorld.PogSim
	var complete := false


func register(v, w: PogWorld) -> void:
	vm = v
	world = w
	for fq in _BINDINGS:
		v.bind(fq, Callable(self, _BINDINGS[fq]))


func bind_game(main: Node3D) -> void:
	game = main


## "name_clay" -> "clay": the speaker keys are the localisation keys for the
## character names, and comms.gd keys its portraits off the bare stem.
static func speaker_stem(s: String) -> String:
	return s.trim_prefix("name_").to_lower()


# ---------------------------------------------------------------- icomms
# @native icomms.BeginConversation
# @native iconversation.Begin
func _c_begin(_t, _a: Array) -> Variant:
	in_conversation = true
	responses.clear()
	chosen_code = 0
	_asked = false
	return 0

# @native icomms.Say
# @native icomms.Shout
func _c_say(_t, a: Array) -> Variant:
	# Say(flags, speaker_name_key, text_key). Shout is the same but broadcast
	# to everyone in range rather than a private channel -- same presentation.
	if game == null or game.comms == null:
		return 0
	var who := speaker_stem(PogStd._s(a[1]))
	var key := PogStd._s(a[2])
	game.comms.say_key(key, who)
	return 0

# @native icomms.AddResponse
# @native icomms.AddResponseWithCode
func _c_add_response(_t, a: Array) -> Variant:
	# AddResponseWithCode(text_key, code, ...). The code is what Response()
	# hands back, and is how the script branches on the player's choice.
	responses.append({
		"text": PogStd._s(a[0]),
		"code": int(a[1]) if a.size() > 1 else responses.size(),
	})
	return 0

# @native icomms.ClearResponses
func _c_clear_responses(_t, _a: Array) -> Variant:
	responses.clear()
	return 0

# @native icomms.Ask
func _c_ask(_t, a: Array) -> Variant:
	# Ask(flags, speaker, question_key), with the options already queued up by
	# AddResponseWithCode. comms.ask() wants [text, reply, response] triples;
	# the scripts handle the reply themselves, so only the text is ours to give.
	if game == null or game.comms == null:
		return 0
	var opts: Array = []
	for r in responses:
		opts.append([r["text"], "", ""])
	game.comms.ask(PogStd._s(a[2]), speaker_stem(PogStd._s(a[1])), opts)
	_asked = true
	return 0

# @native icomms.Response
func _c_response(_t, _a: Array) -> Variant:
	# The script polls this after Ask. comms.gd records the picked index; map it
	# back to the code the script attached to that option.
	if game == null or game.comms == null:
		return chosen_code
	var i: int = game.comms.chosen if "chosen" in game.comms else -1
	if i >= 0 and i < responses.size():
		chosen_code = int(responses[i]["code"])
	return chosen_code

# @native icomms.IsInConversation
# @native icomms.IsBusy
# @native icomms.IsSaying
func _c_is_busy(_t, _a: Array) -> Variant:
	if game == null or game.comms == null:
		return 0
	if game.comms.speaking():
		return 1
	# An unanswered question keeps the conversation "busy" -- that is what the
	# scripts wait on before reading Response().
	if _asked and game.comms.choosing():
		return 1
	return 0

# @native icomms.CanEnd
func _c_can_end(_t, _a: Array) -> Variant:
	return 0 if PogVM._truthy(_c_is_busy(_t, [])) else 1

# @native icomms.EndConversation
# @native icomms.Abort
# @native icomms.AbortEnd
func _c_end(_t, _a: Array) -> Variant:
	in_conversation = false
	responses.clear()
	_asked = false
	return 0


# ---------------------------------------------------------------- iai
# The scripts never fly a ship directly; they hand it an order and wait.

## Orders only mean something for an AI-piloted ship. The scripts hand orders to
## the player's hull too (the launch cutscene purges the player's orders before
## it flies them out), and ShipFlight has no AI fields at all -- so an order for
## anything that is not an AiShip is simply not an order.
func _order_for(s) -> PogOrder:
	if s == null or s.node == null or not is_instance_valid(s.node):
		return null
	if not (s.node is AiShip):
		return null
	var key: int = s.node.get_instance_id()
	if not orders.has(key):
		orders[key] = PogOrder.new()
	return orders[key]

# @native iai.GiveApproachOrder
# @native iai.GiveApproachOrderAdvanced
# @native iai.GiveApproachOrderNoDropOff
# @native iai.GiveDockOrder
# @native iai.GiveReservedDockOrder
# @native iai.GiveDockOrderWithDockport
func _ai_approach(_t, a: Array) -> Variant:
	var s = world._as_sim(a[0])
	var o := _order_for(s)
	if o == null:
		return 0
	o.kind = "approach"
	o.target = world._as_sim(a[1]) if a.size() > 1 else null
	o.complete = false
	# Steer by waypoint: AiShip already flies its waypoint list on patrol.
	if o.target != null:
		s.node.waypoints = [o.target.abs_pos() - world.player_pos()]
		s.node.wp = 0
		s.node.behavior = "patrol"
	return 0

# @native iai.GiveAttackOrder
# @native iai.GiveGenericAttackOrder
# @native iai.GiveSpecificAttackOrder
func _ai_attack(_t, a: Array) -> Variant:
	var s = world._as_sim(a[0])
	var o := _order_for(s)
	if o == null:
		return 0
	o.kind = "attack"
	o.target = world._as_sim(a[1]) if a.size() > 1 else null
	o.complete = false
	s.node.behavior = "attack"
	return 0

# @native iai.GiveEscortOrder
# @native iai.GiveFormateOrder
func _ai_escort(_t, a: Array) -> Variant:
	var s = world._as_sim(a[0])
	var o := _order_for(s)
	if o == null:
		return 0
	o.kind = "escort"
	o.target = world._as_sim(a[1]) if a.size() > 1 else null
	o.complete = false
	s.node.behavior = "patrol"
	return 0

# @native iai.GiveFleeOrder
func _ai_flee(_t, a: Array) -> Variant:
	var s = world._as_sim(a[0])
	var o := _order_for(s)
	if o == null:
		return 0
	o.kind = "flee"
	o.complete = false
	if s.node != null and is_instance_valid(s.node):
		# Run: a waypoint far away, directly opposite the threat.
		var away := (s.abs_pos() - world.player_pos()).normalized() * 1.0e5
		s.node.waypoints = [away]
		s.node.wp = 0
		s.node.behavior = "patrol"
	return 0

# @native iai.PurgeOrders
# @native iai.RemoveOrder
func _ai_purge(_t, a: Array) -> Variant:
	var s = world._as_sim(a[0])
	if s == null or s.node == null or not is_instance_valid(s.node):
		return 0
	if not (s.node is AiShip):
		return 0            # the player's hull has no orders to purge
	orders.erase(s.node.get_instance_id())
	s.node.behavior = "patrol"
	return 0

# @native iai.HasOrder
func _ai_has_order(_t, a: Array) -> Variant:
	var s = world._as_sim(a[0])
	var o := _order_for(s)
	return 1 if (o != null and not o.kind.is_empty() and not o.complete) else 0

# @native iai.IsOrderComplete
func _ai_is_complete(_t, a: Array) -> Variant:
	var s = world._as_sim(a[0])
	var o := _order_for(s)
	if o == null:
		return 1              # a dead ship has finished whatever it was doing
	if o.complete:
		return 1
	match o.kind:
		"approach":
			if o.target != null and s.abs_pos().distance_to(o.target.abs_pos()) < 2000.0:
				o.complete = true
		"attack":
			if o.target == null or not o.target.alive():
				o.complete = true
	return 1 if o.complete else 0

# @native iai.CurrentOrderType
# @native iai.CurrentOrderName
func _ai_order_type(_t, a: Array) -> Variant:
	var s = world._as_sim(a[0])
	var o := _order_for(s)
	return o.kind if o != null else ""

# @native iai.CurrentOrderTarget
func _ai_order_target(_t, a: Array) -> Variant:
	var s = world._as_sim(a[0])
	var o := _order_for(s)
	return o.target if o != null else null

# @native iai.ClearAutopilot
func _ai_clear_autopilot(_t, _a: Array) -> Variant:
	if game != null:
		game.ap_mode = 0
	return 0

# @stub iai.InnerMarkerRadius
# @stub iai.ForceLPRoute
# @stub iai.IsCapsuleJumpAccelerating
func _ai_noop(_t, _a: Array) -> Variant:
	return 0


# ---------------------------------------------------------------- iobjectives
# @native iobjectives.Add
func _o_add(_t, a: Array) -> Variant:
	if game == null or game.mission == null:
		return 0
	var key := PogStd._s(a[0])
	var text: String = game.comms.strings.get(key, key) if game.comms != null else key
	game.mission.objectives[key] = {"text": text, "done": false}
	if game.hud != null:
		game.hud.warn("NEW MISSION OBJECTIVE", 2.5)
		game.hud.log_msg("+ " + text)
	return 0

# @native iobjectives.SetState
func _o_set_state(_t, a: Array) -> Variant:
	if game == null or game.mission == null:
		return 0
	var key := PogStd._s(a[0])
	if not game.mission.objectives.has(key):
		return 0
	# State 2 is "achieved" in the scripts' vocabulary; anything else leaves it
	# outstanding (1 = active, 3 = failed).
	var done := int(a[1]) == 2
	game.mission.objectives[key]["done"] = done
	if done and game.hud != null:
		game.hud.warn("MISSION OBJECTIVE COMPLETED", 2.5)
	return 0

# @native iobjectives.Remove
func _o_remove(_t, a: Array) -> Variant:
	if game != null and game.mission != null:
		game.mission.objectives.erase(PogStd._s(a[0]))
	return 0


# ---------------------------------------------------------------- idirector
# The in-engine cutscene camera. The scripts stage a scene by naming a focus
# (and optionally a second subject to frame against it), optionally parking the
# camera on a "dolly" -- a free-floating camera object they can attach to a ship
# -- then fade in, talk, and fade out. Begin/End bracket the scene and IsBusy is
# what they wait on.
#
# We drive main.cam directly for the duration: director_process() runs each
# frame while a scene is up, and _apply_view() takes the camera back at End.

var director_busy := false
var focus = null                  ## PogWorld.PogSim
var focus2 = null
var dolly: PogDolly = null
var use_dolly := false
var dolly_look_forward := false
var fade := 0.0                   ## 0 = clear, 1 = black
var fade_rate := 0.0
var director_fov := 0.0

class PogDolly extends RefCounted:
	var pos := Vector3.ZERO        ## absolute metres
	var attached = null            ## PogWorld.PogSim it rides
	var offset := Vector3.ZERO

# @native idirector.Begin
func _d_begin(_t, _a: Array) -> Variant:
	if PogRuntime.TRACE:
		print("[pog] idirector.Begin")
	director_busy = true
	focus = null
	focus2 = null
	dolly = null
	use_dolly = false
	director_fov = 0.0
	return 0

# @native idirector.End
func _d_end(_t, _a: Array) -> Variant:
	if PogRuntime.TRACE:
		print("[pog] idirector.End")
	director_busy = false
	fade = 0.0
	fade_rate = 0.0
	if game != null:
		if game.jump_fade != null:
			game.jump_fade.color = Color(0, 0, 0, 0)
		game._apply_view()          # hand the camera back to the player
	return 0

# @native idirector.IsBusy
func _d_is_busy(_t, _a: Array) -> Variant:
	return 1 if director_busy else 0

# @native idirector.SetCaption
func _d_set_caption(_t, a: Array) -> Variant:
	if game != null and game.hud != null:
		var key := PogStd._s(a[0])
		var text: String = game.comms.strings.get(key, key) if game.comms != null else key
		game.hud.log_msg(text)
	return 0

# @native idirector.SetFocus
func _d_set_focus(_t, a: Array) -> Variant:
	focus = world._as_sim(a[0])
	return 0

# @native idirector.SetSecondaryFocus
func _d_set_focus2(_t, a: Array) -> Variant:
	focus2 = world._as_sim(a[0])
	return 0

# @native idirector.CreateDolly
func _d_create_dolly(_t, _a: Array) -> Variant:
	return PogDolly.new()

# @native idirector.SetDollyCamera
func _d_set_dolly_camera(_t, a: Array) -> Variant:
	dolly = a[0] if a[0] is PogDolly else null
	use_dolly = dolly != null
	return 0

# @native idirector.AttachDollyToSim
func _d_attach_dolly(_t, a: Array) -> Variant:
	var d = a[0]
	if d is PogDolly:
		d.attached = world._as_sim(a[1])
	return 0

# @native idirector.DollyLookForward
func _d_dolly_look_forward(_t, a: Array) -> Variant:
	dolly_look_forward = PogVM._truthy(a[0]) if a.size() > 0 else true
	return 0

# @native idirector.UseDollyOrientation
func _d_use_dolly_orientation(_t, a: Array) -> Variant:
	use_dolly = PogVM._truthy(a[1]) if a.size() > 1 else true
	return 0

# @native idirector.SetDirection
func _d_set_direction(_t, a: Array) -> Variant:
	# SetDirection(dolly, x, y, z, dist): place the camera off its subject along
	# a direction, at a distance. This is the shot composition.
	var d = a[0]
	if not (d is PogDolly):
		return 0
	var dir := PogWorld.vec(a[1], a[2], a[3])
	if dir.length_squared() < 0.0001:
		dir = Vector3.BACK
	d.offset = dir.normalized() * (float(a[4]) if a.size() > 4 else 100.0)
	return 0

# @native idirector.SetCamera
func _d_set_camera(_t, a: Array) -> Variant:
	# SetCamera(sim): shoot from this sim's own viewpoint.
	var s = world._as_sim(a[0])
	if s != null:
		dolly = PogDolly.new()
		dolly.attached = s
		use_dolly = true
	return 0

# @native idirector.FadeIn
func _d_fade_in(_t, a: Array) -> Variant:
	# FadeIn(r, g, b, seconds): from opaque to clear.
	fade = 1.0
	var secs := float(a[3]) if a.size() > 3 else 1.0
	fade_rate = -1.0 / maxf(secs, 0.05)
	return 0

# @native idirector.FadeOut
func _d_fade_out(_t, a: Array) -> Variant:
	fade = 0.0
	var secs := float(a[3]) if a.size() > 3 else 1.0
	fade_rate = 1.0 / maxf(secs, 0.05)
	return 0

# @native idirector.SetInterpolateFieldOfView
func _d_set_fov(_t, a: Array) -> Variant:
	# (from, to, seconds); we settle on the target, which is what the shot reads
	# as. A real interpolation needs a shot clock we do not model yet.
	director_fov = float(a[1]) if a.size() > 1 else 0.0
	return 0

# @native idirector.Obituary
func _d_obituary(_t, a: Array) -> Variant:
	# The death cam: frame the wreck.
	focus = world._as_sim(a[0])
	director_busy = true
	return 0

# @native idirector.IsObituaryView
func _d_is_obituary(_t, _a: Array) -> Variant:
	return 1 if (director_busy and focus != null and not focus.alive()) else 0

# @stub idirector.UseSimOrientation
func _d_noop(_t, _a: Array) -> Variant:
	return 0


## Drive the camera while a directed scene is up. Called from main's frame loop.
func director_process(delta: float) -> void:
	if game == null:
		return
	if fade_rate != 0.0:
		fade = clampf(fade + fade_rate * delta, 0.0, 1.0)
		if game.jump_fade != null:
			game.jump_fade.color = Color(0, 0, 0, fade)
		if fade <= 0.0 or fade >= 1.0:
			fade_rate = 0.0
	if not director_busy or game.cam == null:
		return

	# Where the camera sits: on the dolly if the script parked one, otherwise
	# offset from the subject so both subjects are in frame.
	var subject = focus
	if subject == null:
		return
	var target: Vector3 = subject.abs_pos()
	var eye_pos: Vector3 = target + Vector3(0, 20, 120)

	if use_dolly and dolly != null:
		var base: Vector3 = dolly.attached.abs_pos() \
				if dolly.attached != null else dolly.pos
		eye_pos = base + dolly.offset
		if dolly_look_forward and dolly.attached != null:
			target = base - dolly.attached.basis().z * 1000.0
	elif focus2 != null:
		# Two subjects: back off along their perpendicular so both are visible.
		var other: Vector3 = focus2.abs_pos()
		var mid: Vector3 = (target + other) * 0.5
		var sep: float = maxf(target.distance_to(other), 50.0)
		var axis: Vector3 = (other - target).normalized().cross(Vector3.UP)
		if axis.length_squared() < 0.001:
			axis = Vector3.RIGHT
		eye_pos = mid + axis * sep
		target = mid

	# The camera lives in the folded scene space, like everything else.
	var origin: Vector3 = world.player_pos()
	game.cam.global_position = eye_pos - origin
	var look: Vector3 = target - origin
	if game.cam.global_position.distance_squared_to(look) > 0.01:
		game.cam.look_at(look, Vector3.UP)
	if director_fov > 0.0:
		game.cam.fov = director_fov


# ---------------------------------------------------------------- ihud
# @native ihud.SetPrompt
func _h_set_prompt(_t, a: Array) -> Variant:
	if game == null or game.mission == null:
		return 0
	var key := PogStd._s(a[0])
	game.mission.prompt = game.comms.strings.get(key, key) \
			if game.comms != null else key
	return 0

# @native ihud.Print
func _h_print(_t, a: Array) -> Variant:
	if game != null and game.hud != null:
		var key := PogStd._s(a[0])
		game.hud.log_msg(game.comms.strings.get(key, key) \
				if game.comms != null else key)
	return 0

# @native ihud.PlayAudioCue
func _h_audio_cue(_t, _a: Array) -> Variant:
	if game != null and game.audio != null:
		game.audio.play("audio/hud/valid_input.wav", -8.0)
	return 0

# @native ihud.SetTarget
func _h_set_target(_t, a: Array) -> Variant:
	var s = world._as_sim(a[0])
	if game == null or s == null:
		return 0
	if s.node != null and is_instance_valid(s.node):
		game.target_ai = s.node
		game.target_idx = -1
	return 0

# @stub ihud.SetMenuNodeEnabled
# @stub ihud.CurrentMenuNode
# @stub ihud.FlashElement
# @stub ihud.LockMenu
# @stub ihud.ShowScore
func _h_noop(_t, _a: Array) -> Variant:
	return 0


# ---------------------------------------------------------------- igame
# @native igame.PlayMovie
# @native igame.PlayMovieLooped
func _g_play_movie(t, a: Array) -> Variant:
	# PlayMovie("/movies/prelude"). The script blocks on it, so put the task to
	# sleep and wake it when the movie ends -- exactly what the engine did.
	if game == null:
		return 0
	var stem := PogStd._s(a[0]).get_file()
	vm.sleep_task(t, INF)
	game._play_movie(stem, func() -> void:
		t.wake_at = 0.0)
	return 0

# @native igame.GameTime
# @native igame.SystemTime
# @native igame.RealTime
func _g_time(_t, _a: Array) -> Variant:
	return vm.time

# @native igame.EnableBlackout
func _g_blackout(_t, a: Array) -> Variant:
	# Used to hide the world while the director re-stages a scene. It is the
	# scripts' job to turn it back off, and if they do not the player is left
	# staring at a black screen -- so say so when tracing.
	blackout = PogVM._truthy(a[0])
	if PogRuntime.TRACE:
		print("[pog] igame.EnableBlackout(%s)" % ("1" if blackout else "0"))
	if game == null or game.jump_fade == null:
		return 0
	game.jump_fade.color = Color(0, 0, 0, 1.0 if blackout else 0.0)
	return 0

var blackout := false

# @native igame.NextAct
func _g_next_act(_t, a: Array) -> Variant:
	# The campaign's act counter: the scripts read it back through global.Int,
	# and the act CSV tables are loaded off it.
	if vm != null:
		var std := _std()
		if std != null:
			std.globals["g_current_act"] = int(a[0]) if a.size() > 0 else 0
	return 0

func _std() -> PogStd:
	return game.pog_std if (game != null and "pog_std" in game) else null

# --- saves. In a POG-driven game the save file very nearly IS the script
# state: the campaign's whole memory lives in global.* and state.*, which is
# why the engine's Create* natives take a persistence flag. So we serialise
# those, plus where the player is and what they are flying.

const SAVE_SLOTS := 8

func _slot_path(n: int) -> String:
	return "user://save_%d.json" % n

# @native igame.SaveGame
# @native igame.SaveAutosave
func _g_save(_t, a: Array) -> Variant:
	var slot := int(a[0]) if a.size() > 0 else 0
	var std := _std()
	if game == null or std == null:
		return 0
	var states := {}
	for k in std.states:
		states[k] = std.states[k].progress
	var f := FileAccess.open(_slot_path(slot), FileAccess.WRITE)
	if f == null:
		return 0
	f.store_string(JSON.stringify({
		"name": PogStd._s(a[1]) if a.size() > 1 else "Save %d" % slot,
		"system": game.system_stem,
		"pos": [game.px, game.py, game.pz],
		"hull": game.hull,
		"globals": std.globals,
		"states": states,
		"objectives": game.mission.objectives if game.mission != null else {},
	}))
	f.close()
	_saved = true
	return 1

# @native igame.LoadGame
func _g_load(_t, a: Array) -> Variant:
	var slot := int(a[0]) if a.size() > 0 else 0
	var std := _std()
	if game == null or std == null:
		return 0
	var f := FileAccess.open(_slot_path(slot), FileAccess.READ)
	if f == null:
		return 0
	var d: Dictionary = JSON.parse_string(f.get_as_text())
	f.close()
	if d == null:
		return 0
	std.globals = d.get("globals", {})
	for k in d.get("states", {}):
		var s: PogStd.PogState = std._state_create(null, [k])
		s.progress = int(d["states"][k])
	var p: Array = d.get("pos", [0, 0, 0])
	game.start_in_system(String(d.get("system", game.system_stem)))
	game.px = float(p[0])
	game.py = float(p[1])
	game.pz = float(p[2])
	game.hull = float(d.get("hull", game.hull_max))
	if game.mission != null:
		game.mission.objectives = d.get("objectives", {})
	return 1

# @native igame.NumberOfSavedGameSlots
func _g_slots(_t, _a: Array) -> Variant:
	return SAVE_SLOTS

# @native igame.NameOfSaveInSlot
func _g_slot_name(_t, a: Array) -> Variant:
	var f := FileAccess.open(_slot_path(int(a[0])), FileAccess.READ)
	if f == null:
		return ""
	var d: Dictionary = JSON.parse_string(f.get_as_text())
	f.close()
	return PogStd._s(d.get("name", "")) if d != null else ""

# @native igame.AutosaveSaved
func _g_autosaved(_t, _a: Array) -> Variant:
	return 1 if _saved else 0

var _saved := false

# 0 IS the single-player campaign: istartsystem.FinalSetup gates its whole
# single-player path on `if (0 == igame.GameType())`, and StartupSpace blacks the
# screen out for anything that is not 2 or 3 (the multiplayer types). Getting
# this wrong skips the code that turns the blackout back off, and the player
# stares at a black screen with a perfectly healthy game running behind it.
var game_type := 0

# @native igame.GameType
func _g_game_type(_t, _a: Array) -> Variant:
	return game_type

# @native igame.SetGameType
func _g_set_game_type(_t, a: Array) -> Variant:
	game_type = int(a[0]) if a.size() > 0 else 1
	return 0

# @stub igame.CreateFog
# @stub igame.DestroyFog
# @stub igame.GameType
# @stub igame.SetGameType
# @stub igame.StartNewGame
# @stub igame.SessionName
# @stub igame.SetSessionName
# @stub igame.GotEarnedMovie
# @stub igame.GotPlayDisk
# @stub igame.MovePlayerBase
# @stub igame.SaveGame
# @stub igame.SaveAutosave
# @stub igame.AutosaveSaved
# @stub igame.LoadGame
# @stub igame.NumberOfSavedGameSlots
# @stub igame.NameOfSaveInSlot
# @stub igame.IsMultiplayerOnly
# @stub igame.CDKey
# @stub igame.SetCDKey
# @stub igame.ServerAddress
# @stub igame.JoinNetworkGame
# @stub igame.JoinNetworkGameFromLobby
func _g_noop(_t, _a: Array) -> Variant:
	return 0


# ---------------------------------------------------------------- inifile
# The scripts read the game's own INI tree (ship stats, weapon definitions).
# We already extract those; data/ini mirrors the original paths.

## Godot's ConfigFile cannot read these: it wants Variant literals, and the
## game's INIs are full of bare words (`type = T_Freighter`). So parse them
## ourselves -- sections of key -> raw string, coerced on read.
class PogIni extends RefCounted:
	var sections: Dictionary = {}    ## section -> {key: String}

	func value(section: String, key: String) -> Variant:
		var s: Dictionary = sections.get(section, {})
		return s.get(key, null)

	static func load_from(path: String) -> PogIni:
		var f := FileAccess.open(path, FileAccess.READ)
		if f == null:
			return null
		var ini := PogIni.new()
		var cur := ""
		while not f.eof_reached():
			var line := f.get_line().strip_edges()
			if line.is_empty() or line.begins_with(";") or line.begins_with("//"):
				continue
			if line.begins_with("[") and line.ends_with("]"):
				cur = line.substr(1, line.length() - 2)
				if not ini.sections.has(cur):
					ini.sections[cur] = {}
				continue
			var eq := line.find("=")
			if eq < 0:
				continue
			var k := line.substr(0, eq).strip_edges()
			var v := line.substr(eq + 1).strip_edges()
			# Values may or may not be quoted; the scripts never want the quotes.
			if v.length() >= 2 and v.begins_with("\"") and v.ends_with("\""):
				v = v.substr(1, v.length() - 2)
			if not ini.sections.has(cur):
				ini.sections[cur] = {}
			ini.sections[cur][k] = v
		f.close()
		return ini


# @native inifile.Create
func _n_create(_t, a: Array) -> Variant:
	var path := PogWorld.ini_key(PogStd._s(a[0]))
	if _inis.has(path):
		return _inis[path]
	var full := ProjectSettings.globalize_path("res://").path_join(
			"../data/ini/%s" % path)
	var ini := PogIni.load_from(full)
	_inis[path] = ini
	return ini

# @native inifile.String
func _n_string(_t, a: Array) -> Variant:
	var v: Variant = a[0].value(PogStd._s(a[1]), PogStd._s(a[2])) \
			if a[0] is PogIni else null
	return PogStd._s(v) if v != null \
			else (PogStd._s(a[3]) if a.size() > 3 else "")

# @native inifile.Int
func _n_int(_t, a: Array) -> Variant:
	var v: Variant = a[0].value(PogStd._s(a[1]), PogStd._s(a[2])) \
			if a[0] is PogIni else null
	return int(PogStd._s(v).to_int()) if v != null \
			else (int(a[3]) if a.size() > 3 else 0)

# @native inifile.Float
func _n_float(_t, a: Array) -> Variant:
	var v: Variant = a[0].value(PogStd._s(a[1]), PogStd._s(a[2])) \
			if a[0] is PogIni else null
	return PogStd._s(v).to_float() if v != null \
			else (float(a[3]) if a.size() > 3 else 0.0)

# @native inifile.Cast
func _n_cast(_t, a: Array) -> Variant:
	var v = a[0]
	return v if v is PogIni else null

# The Numbered* family reads an indexed key: the tables are written as
# `Entry0 = ...`, `Entry1 = ...`, which is how ship_names.ini holds its 343
# general ship names.
func _numbered(a: Array) -> Variant:
	if not (a[0] is PogIni):
		return null
	return a[0].value(PogStd._s(a[1]), "%s%d" % [PogStd._s(a[2]), int(a[3])])

# @native inifile.NumberedString
func _n_num_string(_t, a: Array) -> Variant:
	var v: Variant = _numbered(a)
	return PogStd._s(v) if v != null \
			else (PogStd._s(a[4]) if a.size() > 4 else "")

# @native inifile.NumberedInt
func _n_num_int(_t, a: Array) -> Variant:
	var v: Variant = _numbered(a)
	return int(PogStd._s(v).to_int()) if v != null \
			else (int(a[4]) if a.size() > 4 else 0)

# @native inifile.NumberedFloat
func _n_num_float(_t, a: Array) -> Variant:
	var v: Variant = _numbered(a)
	return PogStd._s(v).to_float() if v != null \
			else (float(a[4]) if a.size() > 4 else 0.0)

# @native inifile.NumberedExists
func _n_num_exists(_t, a: Array) -> Variant:
	return 1 if _numbered(a) != null else 0

# @stub inifile.Destroy
func _n_noop(_t, _a: Array) -> Variant:
	return 0


const _BINDINGS := {
	"icomms.beginconversation": "_c_begin",
	"icomms.say": "_c_say", "icomms.shout": "_c_say",
	"icomms.addresponse": "_c_add_response",
	"icomms.addresponsewithcode": "_c_add_response",
	"icomms.clearresponses": "_c_clear_responses",
	"icomms.ask": "_c_ask", "icomms.response": "_c_response",
	"icomms.isinconversation": "_c_is_busy", "icomms.isbusy": "_c_is_busy",
	"icomms.issaying": "_c_is_busy", "icomms.canend": "_c_can_end",
	"icomms.endconversation": "_c_end", "icomms.abort": "_c_end",
	"icomms.abortend": "_c_end",

	"iai.giveapproachorder": "_ai_approach",
	"iai.giveapproachorderadvanced": "_ai_approach",
	"iai.giveapproachordernodropoff": "_ai_approach",
	"iai.givedockorder": "_ai_approach",
	"iai.givereserveddockorder": "_ai_approach",
	"iai.givedockorderwithdockport": "_ai_approach",
	"iai.giveattackorder": "_ai_attack",
	"iai.givegenericattackorder": "_ai_attack",
	"iai.givespecificattackorder": "_ai_attack",
	"iai.giveescortorder": "_ai_escort",
	"iai.giveformateorder": "_ai_escort",
	"iai.givefleeorder": "_ai_flee",
	"iai.purgeorders": "_ai_purge", "iai.removeorder": "_ai_purge",
	"iai.hasorder": "_ai_has_order",
	"iai.isordercomplete": "_ai_is_complete",
	"iai.currentordertype": "_ai_order_type",
	"iai.currentordername": "_ai_order_type",
	"iai.currentordertarget": "_ai_order_target",
	"iai.clearautopilot": "_ai_clear_autopilot",
	"iai.innermarkerradius": "_ai_noop", "iai.forcelproute": "_ai_noop",
	"iai.iscapsulejumpaccelerating": "_ai_noop",

	"iobjectives.add": "_o_add", "iobjectives.setstate": "_o_set_state",
	"iobjectives.remove": "_o_remove",

	"idirector.begin": "_d_begin", "idirector.end": "_d_end",
	"idirector.isbusy": "_d_is_busy", "idirector.setcaption": "_d_set_caption",
	"idirector.setfocus": "_d_set_focus",
	"idirector.setsecondaryfocus": "_d_set_focus2",
	"idirector.setcamera": "_d_set_camera",
	"idirector.setdollycamera": "_d_set_dolly_camera",
	"idirector.createdolly": "_d_create_dolly",
	"idirector.setdirection": "_d_set_direction",
	"idirector.fadein": "_d_fade_in", "idirector.fadeout": "_d_fade_out",
	"idirector.setinterpolatefieldofview": "_d_set_fov",
	"idirector.attachdollytosim": "_d_attach_dolly",
	"idirector.dollylookforward": "_d_dolly_look_forward",
	"idirector.usedollyorientation": "_d_use_dolly_orientation",
	"idirector.usesimorientation": "_d_noop",
	"idirector.isobituaryview": "_d_is_obituary",
	"idirector.obituary": "_d_obituary",

	"ihud.setprompt": "_h_set_prompt", "ihud.print": "_h_print",
	"ihud.playaudiocue": "_h_audio_cue", "ihud.settarget": "_h_set_target",
	"ihud.setmenunodeenabled": "_h_noop", "ihud.currentmenunode": "_h_noop",
	"ihud.flashelement": "_h_noop", "ihud.lockmenu": "_h_noop",
	"ihud.showscore": "_h_noop",

	"igame.playmovie": "_g_play_movie",
	"igame.playmovielooped": "_g_play_movie",
	"igame.gametime": "_g_time", "igame.systemtime": "_g_time",
	"igame.realtime": "_g_time",
	"igame.nextact": "_g_next_act", "igame.enableblackout": "_g_blackout",
	"igame.createfog": "_g_noop", "igame.destroyfog": "_g_noop",
	"igame.gametype": "_g_game_type",
	"igame.setgametype": "_g_set_game_type",
	"igame.startnewgame": "_g_noop", "igame.sessionname": "_g_noop",
	"igame.setsessionname": "_g_noop", "igame.gotearnedmovie": "_g_noop",
	"igame.gotplaydisk": "_g_noop", "igame.moveplayerbase": "_g_noop",
	"igame.savegame": "_g_save", "igame.saveautosave": "_g_save",
	"igame.autosavesaved": "_g_autosaved", "igame.loadgame": "_g_load",
	"igame.numberofsavedgameslots": "_g_slots",
	"igame.nameofsaveinslot": "_g_slot_name",
	"igame.ismultiplayeronly": "_g_noop", "igame.cdkey": "_g_noop",
	"igame.setcdkey": "_g_noop", "igame.serveraddress": "_g_noop",
	"igame.joinnetworkgame": "_g_noop",
	"igame.joinnetworkgamefromlobby": "_g_noop",

	"inifile.create": "_n_create", "inifile.string": "_n_string",
	"inifile.int": "_n_int", "inifile.float": "_n_float",
	"inifile.cast": "_n_cast", "inifile.destroy": "_n_noop",
	"inifile.numberedstring": "_n_num_string",
	"inifile.numberedint": "_n_num_int",
	"inifile.numberedfloat": "_n_num_float",
	"inifile.numberedexists": "_n_num_exists",
}
