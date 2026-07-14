class_name PogScript
extends Node

## Base class for the ported mission scripts.
##
## The missions are no longer bytecode: tools/iw2/pogport.py decompiles them and
## emits GDScript, one file per original package, and those files extend this.
## There is no interpreter left in the loop -- a mission is ordinary Godot code
## calling ordinary Godot systems.
##
## What this base has to provide is the handful of things POG's runtime gave a
## script for free: cooperative tasks, and the two ways a script gives up the
## frame.
##
##   POG                                 here
##   task.Sleep(task.Current(), 2.0)     await wait(2.0)
##   <EndTimeslice>                      await frame()
##   start SomeFunc(a, b)                spawn(some_func.bind(a, b))
##
## A POG task is a coroutine, which is exactly what a GDScript function with an
## `await` in it already is, so `spawn` just calls one without awaiting it and
## hands back a handle so the script can halt or poll it later.

var rt: PogRuntime
var api: PogNativeApi          ## the engine packages (iship, isim, sim, ...)

## Handles for the tasks this script spawned, so task.Halt/IsRunning work.
var _tasks: Array[PogTaskHandle] = []


class PogTaskHandle extends RefCounted:
	var done := false
	var halted := false
	var seq := 0

	func running() -> bool:
		return not done and not halted


func setup(runtime: PogRuntime) -> void:
	rt = runtime
	api = runtime.api
	_link()


## Generated: binds the package names this script imports. Overridden per file.
func _link() -> void:
	pass


## Never emitted. A halted task parks on it and is collected with the scene --
## see `_dead()`.
signal _halt


## True once this task's world has gone away: the runtime was halted (NEW GAME)
## or the script has been pulled out of the tree. A coroutine cannot be killed
## from outside in GDScript, so every await point checks this and parks forever
## rather than resuming into a freed SceneTree.
func _dead() -> bool:
	return rt == null or rt.halted or not is_inside_tree()


## Every await goes through here. `rt.current_seq` identifies the coroutine that
## is running right now; it must be re-asserted on resume, because in between,
## other coroutines will have run and overwritten it. And a suspended task stays
## parked here until it is resumed, which is what task.SuspendAll means.
func _resume(seq: int) -> void:
	if _dead():
		await _halt
		return
	rt.current_seq = seq
	while rt.is_suspended(seq):
		await get_tree().process_frame
		if _dead():
			await _halt
			return
		rt.current_seq = seq


## `task.Sleep(task.Current(), secs)`.
func _pog_wait(secs: float) -> void:
	if _dead():
		await _halt
		return
	var seq: int = rt.current_seq
	if secs <= 0.0:
		await get_tree().process_frame
	else:
		await get_tree().create_timer(secs).timeout
	await _resume(seq)


## `EndTimeslice` -- give up the rest of the frame.
func _pog_frame() -> void:
	if _dead():
		await _halt
		return
	var seq: int = rt.current_seq
	await get_tree().process_frame
	await _resume(seq)


## `start f(...)`. A coroutine called without await runs until its first await
## and then continues on its own, which is precisely a POG task.
func _pog_spawn(c: Callable) -> PogTaskHandle:
	var h := PogTaskHandle.new()
	h.seq = rt.next_seq()
	_tasks.append(h)
	_run(c, h)
	return h


func _run(c: Callable, h: PogTaskHandle) -> void:
	var caller: int = rt.current_seq
	rt.current_seq = h.seq
	if PogRuntime.TRACE:
		print("[task] start %s.%s (#%d)" % [name, c.get_method(), h.seq])
	await c.call()
	h.done = true
	if PogRuntime.TRACE:
		print("[task] done  %s.%s (#%d)" % [name, c.get_method(), h.seq])
	rt.current_seq = caller


func _pog_halt(h) -> int:
	if h is PogTaskHandle:
		h.halted = true
	return 0


## POG has no bool, so the ported code compares these against 0 and 1.
func _pog_is_running(h) -> int:
	return 1 if (h is PogTaskHandle and h.running()) else 0


## `task.Detach` meant "outlive your parent"; a spawned coroutine already does.
func _pog_detach(_h) -> int:
	return 0


func _pog_suspend(_h) -> int:
	return 0


func _pog_resume(_h) -> int:
	return 0


## Freeze every task that already exists. The caller keeps running (it is about
## to spawn the cutscene), and so does anything spawned from here on.
func _pog_suspend_all() -> int:
	rt.suspend_all(rt.current_seq)
	return 0


func _pog_resume_all() -> int:
	rt.resume_all()
	return 0


func _pog_task_cast(h) -> Variant:
	return h


## `task.Call`: run a task to completion here and now.
func _run_now(h) -> Variant:
	if h is Callable:
		return await h.call()
	return h


## POG has no null literal and no bool: a script asks "is this handle null?" by
## comparing it against 0, which is legal there (everything is a 32-bit word)
## and a type error here. Numbers keep their ordinary meaning, so `count == 0`
## still behaves exactly as written.
func _pog_is_null(v: Variant) -> bool:
	if v == null:
		return true
	if v is int:
		return v == 0
	if v is float:
		return v == 0.0
	return false


## Equality where neither side is a literal, so the types are not known: a
## handle and a number are never equal, which GDScript would rather raise about.
func _pog_eq(a: Variant, b: Variant) -> bool:
	if a == null or b == null:
		return _pog_is_null(a) and _pog_is_null(b)
	var an := a is int or a is float
	var bn := b is int or b is float
	if an != bn:
		return false
	return a == b


## `igame.PlayMovie` blocks the script until the cinematic ends. In the original
## that was the task suspending; here it is simply an await.
func _pog_movie(stem: String) -> Variant:
	if rt.game == null:
		return 0
	var done := [false]
	rt.game._play_movie(stem.get_file(), func() -> void: done[0] = true)
	while not done[0]:
		await _pog_frame()
	return 0


## `TimedJump`: not a sleep, a rate limiter. It lets a polling loop yield every
## frame while the body it guards runs at most once every `secs`. Keyed by the
## instruction it came from, which is unique per site.
var _every: Dictionary = {}

func _pog_every(site: int, secs: float) -> bool:
	var now := Time.get_ticks_msec() / 1000.0
	var last: float = _every.get(site, -INF)
	if now - last <= secs:
		return false
	_every[site] = now
	return true


## `CloneObject`: POG's containers are values, and Godot's are too.
func _pog_clone(v: Variant) -> Variant:
	if v is Array or v is Dictionary:
		return v.duplicate()
	return v
