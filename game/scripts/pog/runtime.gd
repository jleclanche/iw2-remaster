class_name PogRuntime
extends Node

## Hosts the ported mission scripts.
##
## This is what replaces the VM. It owns the native packages (the same modules
## the interpreter used -- they were always the real systems; only the thing
## *calling* them changes), instantiates the ported scripts, and hands each one
## its dependencies.
##
## The VM stays in the tree as a differential oracle: pogcheck can run a mission
## as bytecode and we can run the same mission as GDScript and compare. It is a
## test tool, not the runtime.

const GEN_DIR := "res://scripts/pog/gen"

## The original scripts' `debug { ... }` blocks, which the compiler skipped
## unless developer mode was on. Same switch, same narration -- and the same
## value: their own error handlers are the best diagnostic we have.
static var TRACE := false

var std: PogStd
var facs: PogFactions
var world: PogWorld
var gameapi: PogGameApi
var econ: PogEconomy
var ents: PogEntities
var ui: PogUi
var misc: PogMisc

var api: PogNativeApi
var natives: Dictionary = {}          ## "pkg.func" (lower) -> Callable
var scripts: Dictionary = {}          ## package name -> PogScript instance

var game: Node3D

## task.SuspendAll / ResumeAll.
##
## The cutscene machinery depends on this: FinalSetup suspends everything that
## already exists, spawns the launch cutscene, and resumes at the end. Tasks
## created *after* the suspend keep running -- that is what lets the cutscene run
## at all -- and so does the task that called it, or it would freeze itself.
##
## A coroutine has no identity in Godot, so each carries a sequence number and
## the await helpers in PogScript re-assert `current_seq` when they resume:
## between a resume and the next await, only that coroutine is running.
var task_seq := 1
var current_seq := 0        ## 0 is the boot chain
var suspend_below := -1     ## tasks with seq <= this are frozen
var suspend_exempt := -1


func next_seq() -> int:
	task_seq += 1
	return task_seq


func suspend_all(caller_seq: int) -> void:
	suspend_below = task_seq
	suspend_exempt = caller_seq


func resume_all() -> void:
	suspend_below = -1
	suspend_exempt = -1


## Suspension freezes a task; HALT ends the world. There was no way to stop a
## task at all -- POG never needed one, because the process exited. We do: NEW
## GAME tears the scene down, and a task parked on `process_frame` would
## otherwise resume against a node that is no longer in the tree and reach for
## a null SceneTree. Halted tasks park on a signal that is never emitted and
## die with the scene.
var halted := false

func halt() -> void:
	halted = true

func is_suspended(seq: int) -> bool:
	return suspend_below >= 0 and seq <= suspend_below and seq != suspend_exempt


func bind_game(main: Node3D) -> void:
	game = main
	TRACE = "--pogtrace" in OS.get_cmdline_user_args()
	_build_natives()
	api = PogNativeApi.new(self)


## The native modules register themselves against a `bind()` the same way they
## did for the VM, so there is exactly one implementation of each native.
func _build_natives() -> void:
	std = PogStd.new()
	std.register(self)
	facs = PogFactions.new()
	facs.register(self)
	world = PogWorld.new()
	world.factions = facs
	world.register(self)
	world.bind_game(game)
	gameapi = PogGameApi.new()
	gameapi.register(self, world)
	gameapi.bind_game(game)
	econ = PogEconomy.new()
	econ.register(self, world)
	econ.bind_game(game)
	ents = PogEntities.new()
	ents.register(self, world)
	ents.bind_game(game)
	ui = PogUi.new()
	ui.register(self, world)
	ui.bind_game(game)
	misc = PogMisc.new()
	misc.register(self, world)
	misc.bind_game(game)


## The native modules call this to register themselves (same signature the VM
## exposed, so they did not have to change).
func bind(fqn: String, fn: Callable) -> void:
	natives[fqn.to_lower()] = fn


## Invoke a native. The generated facades in PogNativeApi call through here, so
## an unimplemented native fails loudly instead of silently returning zero.
## The natives marked `# @stub` in scripts/pog/natives/, read out of the source
## so the set can never drift from the markers. Lower-cased to match `natives`.
static var _stubs: Dictionary = {}
static var _stubs_loaded := false
## Which stubs have already been reported, so a stub on a per-frame path warns
## once rather than every tick. `--stubtrace` reports every call instead.
static var _stub_seen: Dictionary = {}
static var _stub_trace := false


## A stub is bound and returns 0, which is indistinguishable from a real answer:
## igame.GotPlayDisk answered "no disc" for months and silently deleted four
## items from the main menu; igame.SessionName returned the int 0 where the
## script compares against "" and sent the whole front-end builder down the
## multiplayer branch. Neither crashed, neither logged. So say so, once, the
## first time each one is actually reached -- an unimplemented native that
## nothing calls is not worth a word, and one that IS called is worth a warning.
static func _load_stubs() -> void:
	if _stubs_loaded:
		return
	_stubs_loaded = true
	_stub_trace = "--stubtrace" in OS.get_cmdline_user_args()
	var dir := DirAccess.open("res://scripts/pog/natives")
	if dir == null:
		return
	for f in dir.get_files():
		if not f.ends_with(".gd"):
			continue
		var text := FileAccess.get_file_as_string(
				"res://scripts/pog/natives/".path_join(f))
		for line in text.split("\n"):
			var t := (line as String).strip_edges()
			if not t.begins_with("# @stub"):
				continue
			# `# @stub gui.SetEditBoxCursorToEnd -- prose...`: the name is the
			# first token, anything after it is a note to the reader.
			var rest := t.substr(7).strip_edges()
			if rest.is_empty():
				continue
			_stubs[rest.split(" ")[0].to_lower()] = f
	# A name marked BOTH @stub and @native is a stale marker, not a stub: the
	# implementation landed and the old line was never deleted. @native wins, so
	# documentation rot cannot manufacture a false warning.
	for f2 in dir.get_files():
		if not f2.ends_with(".gd"):
			continue
		var text2 := FileAccess.get_file_as_string(
				"res://scripts/pog/natives/".path_join(f2))
		for line2 in text2.split("\n"):
			var t2 := (line2 as String).strip_edges()
			if not t2.begins_with("# @native"):
				continue
			var rest2 := t2.substr(9).strip_edges()
			if not rest2.is_empty():
				_stubs.erase(rest2.split(" ")[0].to_lower())


func native(fqn: String, args: Array) -> Variant:
	var fn: Callable = natives.get(fqn, Callable())
	if not fn.is_valid():
		push_error("POG: native %s is not implemented" % fqn)
		return 0
	_load_stubs()
	if _stubs.has(fqn) and (_stub_trace or not _stub_seen.has(fqn)):
		_stub_seen[fqn] = true
		push_warning(("POG STUB CALLED: %s (natives/%s) returns a placeholder; "
			+ "callers may be silently wrong") % [fqn, _stubs[fqn]])
	# The native modules take (task, args); ported scripts have no task object,
	# and the only natives that used it were task.* -- which the port rewrites
	# into await, so nothing reaches here needing one.
	return fn.call(null, args)


## Get (creating on first use) the ported script for a package.
func script(name: String) -> PogScript:
	var key := name.to_lower()
	if scripts.has(key):
		return scripts[key]
	var path := "%s/%s.gd" % [GEN_DIR, key]
	if not ResourceLoader.exists(path):
		push_error("POG: no ported script for package '%s'" % name)
		return null
	var s: PogScript = (load(path) as GDScript).new()
	s.name = key
	scripts[key] = s
	add_child(s)
	s.setup(self)
	return s
