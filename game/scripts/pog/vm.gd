class_name PogVM
extends Node

## The POG virtual machine: runs the game's original mission bytecode.
##
## IW2's missions, conversations, AI orders, trading, the mission generator --
## essentially all of the game's *content logic* -- are POG scripts compiled to
## a stack-machine bytecode and shipped in resource.zip. The engine binaries
## provide the ~42 "native" packages those scripts call into (iship, isim, iai,
## idirector...); everything else is bytecode we already have.
##
## So rather than re-authoring missions by hand, we run the originals. This is
## the interpreter, transcribed from FcScriptTask::Execute in flux.dll: same
## opcodes, same call frames, same cooperative scheduler. What we must supply
## is the native side -- see natives/.
##
## Divergence from the original, deliberately: MarkObject/DeleteMarkedObjects
## are the engine's manual object-scope GC. Godot refcounts, so they are no-ops
## here. That changes memory management, not behaviour.

const NATIVE_DIR := "res://scripts/pog/natives"

# --- opcodes (validated against the shipped bytecode: no byte unaccounted for)
const OP_POP := 0x01
const OP_POPN := 0x02
const OP_COPY := 0x03
const OP_LOAD_ZERO := 0x04
const OP_LOAD_ONE := 0x05
const OP_IMM8I := 0x06
const OP_IMM16I := 0x07
const OP_IMM32I := 0x08
const OP_IMM8U := 0x09
const OP_IMM16U := 0x0A
const OP_IMM32F := 0x0B
const OP_LOAD := 0x0C
const OP_STORE := 0x0D
const OP_RESERVE := 0x0E
const OP_GOTO := 0x0F
const OP_GOFALSE := 0x10
const OP_GOTRUE := 0x11
const OP_HALT := 0x12
const OP_RETURN := 0x13
const OP_CALL_LOCAL := 0x14
const OP_CALL := 0x15
const OP_START_LOCAL := 0x17
const OP_START := 0x18
const OP_ADD_I := 0x1A
const OP_SUB_I := 0x1B
const OP_MUL_I := 0x1C
const OP_DIV_I := 0x1D
const OP_MOD_I := 0x1E
const OP_NEG_I := 0x1F
const OP_EQUAL := 0x20
const OP_NOT_EQUAL := 0x21
const OP_GREATER_I := 0x22
const OP_LESS_I := 0x23
const OP_GREATER_EQ_I := 0x24
const OP_LESS_EQ_I := 0x25
const OP_ADD_F := 0x26
const OP_SUB_F := 0x27
const OP_MUL_F := 0x28
const OP_DIV_F := 0x29
const OP_NEG_F := 0x2B
const OP_GREATER_F := 0x2C
const OP_LESS_F := 0x2D
const OP_GREATER_EQ_F := 0x2E
const OP_LESS_EQ_F := 0x2F
const OP_LOGICAL_AND := 0x30
const OP_LOGICAL_OR := 0x31
const OP_LOGICAL_NOT := 0x32
const OP_BIT_AND := 0x33
const OP_BIT_OR := 0x34
const OP_BIT_XOR := 0x35
const OP_BIT_NOT := 0x36
const OP_INT_TO_FLOAT := 0x37
const OP_FLOAT_TO_INT := 0x38
const OP_TO_BOOL := 0x39
const OP_NEW_OBJECT := 0x3A
const OP_MARK_OBJECT := 0x3B
const OP_DELETE_MARKED := 0x3C
const OP_STORE_OBJECT := 0x3D
const OP_LOAD_STRING := 0x3E
const OP_EQUAL_OBJECTS := 0x3F
const OP_CLONE_OBJECT := 0x40
const OP_END_TIMESLICE := 0x41
const OP_TIMED_JUMP := 0x42
const OP_BEGIN_ATOMIC := 0x43
const OP_END_ATOMIC := 0x44
const OP_DEBUG_SKIP := 0x45

## How long the whole VM may run per frame. The original budgeted the
## interpreter in milliseconds too (FcScriptTask::Execute's second argument).
const BUDGET_MS := 4.0

## Tripwire for a script that loops without ever yielding. The original had no
## such guard -- it would simply hang -- but a runaway here would freeze Godot's
## main loop, so we break out and report which package did it.
const MAX_STEPS_PER_TASK := 2_000_000


class PogPackage:
	var name: String
	var strings: PackedStringArray
	var exports: Dictionary   ## func name -> entry offset
	var code: PackedByteArray
	## call-site offset -> resolved target, filled in by _link():
	##   {"native": Callable} or {"pkg": PogPackage, "entry": int}
	var links: Dictionary = {}
	var raw_imports: Dictionary = {}   ## offset(int) -> "pkg.Func"


class PogTask:
	var id: int
	var pkg: PogPackage
	var pc: int
	var stack: Array = []
	var bp: int = 0            ## locals base: stack[bp + n] is local n
	var frames: Array = []     ## [pc, pkg, bp, sp]
	var halted := false
	var wake_at := 0.0         ## suspended until VM time reaches this
	var atomic := 0
	var name: String = ""      ## for diagnostics


## Echo the scripts' own debug.Print* output. The original gated this on
## developer mode; it is how the missions narrate themselves, so it is the
## single most useful thing to turn on when a mission misbehaves.
static var trace_debug := false

var packages: Dictionary = {}       ## lowercase name -> PogPackage
var natives: Dictionary = {}        ## "pkg.func" (lower) -> Callable
var tasks: Array[PogTask] = []
var time: float = 0.0
var missing: Dictionary = {}        ## unimplemented natives actually hit
var called: Dictionary = {}         ## every native actually called, for tracing

var _next_id := 1
var _root := ""
var _native_pkgs: Dictionary = {}   ## packages with no bytecode: the engine's job
var _manifest_read := false


func _ready() -> void:
	set_process(false)


func _data_root() -> String:
	if _root.is_empty():
		_root = ProjectSettings.globalize_path("res://").path_join("../data/pog")
	return _root


## Which packages are native (engine-provided, no bytecode). Without this the
## linker would chase every `iship.Cast` into a package file that cannot exist.
func _native_set() -> Dictionary:
	if not _manifest_read:
		_manifest_read = true
		var f := FileAccess.open(_data_root().path_join("manifest.json"),
				FileAccess.READ)
		if f != null:
			var d: Dictionary = JSON.parse_string(f.get_as_text())
			f.close()
			for p in d.get("native", []):
				_native_pkgs[String(p).to_lower()] = true
	return _native_pkgs


## Register a native: `pkg.Func` -> Callable(task, args) -> Variant.
func bind(fqn: String, fn: Callable) -> void:
	natives[fqn.to_lower()] = fn


func load_package(name: String) -> PogPackage:
	var key := name.to_lower()
	if packages.has(key):
		return packages[key]
	var path := _data_root().path_join(key + ".json")
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("POG: no package '%s' at %s" % [name, path])
		return null
	var d: Dictionary = JSON.parse_string(f.get_as_text())
	f.close()

	var p := PogPackage.new()
	p.name = d.get("name", name)
	p.strings = PackedStringArray(d.get("strings", []))
	p.exports = d.get("exports", {})
	p.raw_imports = d.get("imports", {})
	p.code = Marshalls.base64_to_raw(d.get("code", ""))
	packages[key] = p
	_link(p)
	return p


## Resolve every call site to either a native Callable or a target package +
## entry. The original engine did this at load time by patching the operands;
## we keep a side table instead, so the bytecode stays pristine.
func _link(p: PogPackage) -> void:
	for off_s in p.raw_imports:
		var target: String = p.raw_imports[off_s]
		var parts := target.split(".", true, 1)
		if parts.size() != 2:
			continue
		var pkg_name := parts[0].to_lower()
		var fn_name := parts[1]
		var off := int(off_s)
		var fqn := pkg_name + "." + fn_name.to_lower()
		if natives.has(fqn):
			p.links[off] = {"native": natives[fqn], "fqn": target}
			continue
		if _native_set().has(pkg_name):
			# An engine package we have not implemented yet. Stub it to 0 and
			# count the hit; pogcheck prints these as the work queue.
			p.links[off] = {"missing": target}
			continue
		# A script package: load it and jump straight into its bytecode.
		var dep := load_package(pkg_name)
		if dep != null and dep.exports.has(fn_name):
			p.links[off] = {"pkg": dep, "entry": int(dep.exports[fn_name])}
		else:
			p.links[off] = {"missing": target}


func start(pkg_name: String, func_name: String, args: Array = []) -> PogTask:
	var p := load_package(pkg_name)
	if p == null:
		return null
	if not p.exports.has(func_name):
		push_error("POG: %s has no export '%s'" % [pkg_name, func_name])
		return null
	return _spawn(p, int(p.exports[func_name]), args, "%s.%s" % [pkg_name, func_name])


func _spawn(p: PogPackage, entry: int, args: Array, label: String) -> PogTask:
	var t := PogTask.new()
	t.id = _next_id
	_next_id += 1
	t.pkg = p
	t.pc = entry
	t.name = label
	t.stack = args.duplicate()
	t.bp = 0
	tasks.append(t)
	set_process(true)
	return t


func find_task(id: int) -> PogTask:
	for t in tasks:
		if t.id == id:
			return t
	return null


func _process(delta: float) -> void:
	step(delta)


## Advance every runnable task by one frame. Public so the headless harness can
## drive the VM without depending on node processing.
func step(delta: float) -> void:
	time += delta
	if tasks.is_empty():
		return
	var deadline := Time.get_ticks_usec() + int(BUDGET_MS * 1000.0)
	for t in tasks:
		if t.halted or time < t.wake_at:
			continue
		_execute(t, deadline)
	var live: Array[PogTask] = []
	for t in tasks:
		if not t.halted:
			live.append(t)
	tasks = live


## The interpreter. Runs `t` until it yields (EndTimeslice), halts, or the
## frame's time budget runs out -- exactly the three exits the original had.
func _execute(t: PogTask, deadline: int) -> void:
	var code := t.pkg.code
	var n := code.size()
	var steps := 0

	while true:
		if t.pc < 0 or t.pc >= n:
			push_error("POG: %s ran off the end of %s" % [t.name, t.pkg.name])
			t.halted = true
			return
		steps += 1
		if steps > MAX_STEPS_PER_TASK:
			push_error("POG: %s (%s) never yielded -- halting it"
					% [t.name, t.pkg.name])
			t.halted = true
			return
		# Preemption check, like the original's every-64-instructions test.
		# Never inside an atomic block.
		if t.atomic == 0 and (steps & 63) == 0:
			if Time.get_ticks_usec() > deadline:
				return

		var op := code.decode_u8(t.pc)
		t.pc += 1
		var s := t.stack

		match op:
			OP_POP:
				s.pop_back()
			OP_POPN:
				var k := code.decode_u8(t.pc)
				t.pc += 1
				s.resize(s.size() - k)
			OP_COPY:
				s.push_back(s[-1])
			OP_LOAD_ZERO:
				s.push_back(0)
			OP_LOAD_ONE:
				s.push_back(1)
			OP_IMM8I:
				s.push_back(code.decode_s8(t.pc))
				t.pc += 1
			OP_IMM8U:
				s.push_back(code.decode_u8(t.pc))
				t.pc += 1
			OP_IMM16I:
				s.push_back(code.decode_s16(t.pc))
				t.pc += 2
			OP_IMM16U:
				s.push_back(code.decode_u16(t.pc))
				t.pc += 2
			OP_IMM32I:
				s.push_back(code.decode_s32(t.pc))
				t.pc += 4
			OP_IMM32F:
				s.push_back(code.decode_float(t.pc))
				t.pc += 4
			OP_LOAD:
				s.push_back(t.stack[t.bp + code.decode_u32(t.pc)])
				t.pc += 4
			OP_STORE:
				# NB: Store does *not* pop -- assignment is an expression in
				# POG, so the compiler emits a trailing Pop when it's a
				# statement. Popping here silently corrupts every expression.
				t.stack[t.bp + code.decode_u32(t.pc)] = s[-1]
				t.pc += 4
			OP_RESERVE:
				var k := code.decode_u32(t.pc)
				t.pc += 4
				for _i in k:
					s.push_back(0)
			OP_GOTO:
				t.pc = code.decode_u32(t.pc)
			OP_GOFALSE:
				var target := code.decode_u32(t.pc)
				t.pc += 4
				if not _truthy(s.pop_back()):
					t.pc = target
			OP_GOTRUE:
				var target := code.decode_u32(t.pc)
				t.pc += 4
				if _truthy(s.pop_back()):
					t.pc = target
			OP_HALT:
				t.halted = true
				return
			OP_RETURN:
				var rv: Variant = s[-1] if not s.is_empty() else 0
				if t.frames.is_empty():
					t.halted = true
					return
				var fr: Array = t.frames.pop_back()
				t.pc = fr[0]
				t.pkg = fr[1]
				t.bp = fr[2]
				t.stack.resize(fr[3])
				t.stack.push_back(rv)
				code = t.pkg.code
				n = code.size()
			OP_CALL_LOCAL, OP_START_LOCAL:
				var entry := code.decode_u32(t.pc + 4)
				var argc := code.decode_u32(t.pc + 8)
				t.pc += 12
				if op == OP_CALL_LOCAL:
					_enter(t, t.pkg, entry, argc)
				else:
					_start_from(t, t.pkg, entry, argc)
			OP_CALL, OP_START:
				var site := t.pc - 1
				var argc := code.decode_u32(t.pc + 8)
				t.pc += 12
				var link: Dictionary = t.pkg.links.get(site, {})
				if link.has("native"):
					_call_native(t, link, argc)
				elif link.has("pkg"):
					if op == OP_CALL:
						_enter(t, link["pkg"], link["entry"], argc)
						code = t.pkg.code
						n = code.size()
					else:
						_start_from(t, link["pkg"], link["entry"], argc)
				else:
					# Unimplemented native: drop the args, yield 0.
					var name: String = link.get("missing", "?")
					if not missing.has(name):
						missing[name] = 0
					missing[name] += 1
					s.resize(s.size() - argc)
					s.push_back(0)
			OP_ADD_I, OP_ADD_F:
				var b: Variant = s.pop_back()
				s[-1] = s[-1] + b
			OP_SUB_I, OP_SUB_F:
				var b: Variant = s.pop_back()
				s[-1] = s[-1] - b
			OP_MUL_I, OP_MUL_F:
				var b: Variant = s.pop_back()
				s[-1] = s[-1] * b
			OP_DIV_I:
				var b: Variant = s.pop_back()
				s[-1] = 0 if int(b) == 0 else int(s[-1]) / int(b)
			OP_DIV_F:
				var b: Variant = s.pop_back()
				s[-1] = 0.0 if float(b) == 0.0 else float(s[-1]) / float(b)
			OP_MOD_I:
				var b: Variant = s.pop_back()
				s[-1] = 0 if int(b) == 0 else int(s[-1]) % int(b)
			OP_NEG_I, OP_NEG_F:
				s[-1] = -s[-1]
			OP_EQUAL:
				var b: Variant = s.pop_back()
				s[-1] = 1 if s[-1] == b else 0
			OP_NOT_EQUAL:
				var b: Variant = s.pop_back()
				s[-1] = 1 if s[-1] != b else 0
			OP_GREATER_I, OP_GREATER_F:
				var b: Variant = s.pop_back()
				s[-1] = 1 if s[-1] > b else 0
			OP_LESS_I, OP_LESS_F:
				var b: Variant = s.pop_back()
				s[-1] = 1 if s[-1] < b else 0
			OP_GREATER_EQ_I, OP_GREATER_EQ_F:
				var b: Variant = s.pop_back()
				s[-1] = 1 if s[-1] >= b else 0
			OP_LESS_EQ_I, OP_LESS_EQ_F:
				var b: Variant = s.pop_back()
				s[-1] = 1 if s[-1] <= b else 0
			OP_LOGICAL_AND:
				var b: Variant = s.pop_back()
				s[-1] = 1 if (_truthy(s[-1]) and _truthy(b)) else 0
			OP_LOGICAL_OR:
				var b: Variant = s.pop_back()
				s[-1] = 1 if (_truthy(s[-1]) or _truthy(b)) else 0
			OP_LOGICAL_NOT:
				s[-1] = 0 if _truthy(s[-1]) else 1
			OP_BIT_AND:
				var b: Variant = s.pop_back()
				s[-1] = int(s[-1]) & int(b)
			OP_BIT_OR:
				var b: Variant = s.pop_back()
				s[-1] = int(s[-1]) | int(b)
			OP_BIT_XOR:
				var b: Variant = s.pop_back()
				s[-1] = int(s[-1]) ^ int(b)
			OP_BIT_NOT:
				s[-1] = ~int(s[-1])
			OP_INT_TO_FLOAT:
				s[-1] = float(s[-1])
			OP_FLOAT_TO_INT:
				s[-1] = int(s[-1])
			OP_TO_BOOL:
				s[-1] = 1 if _truthy(s[-1]) else 0
			OP_NEW_OBJECT:
				t.pc += 4          # only type 0 (a bare object slot) is ever used
				s.push_back(null)
			OP_MARK_OBJECT, OP_DELETE_MARKED:
				pass               # engine-side object-scope GC; Godot refcounts
			OP_STORE_OBJECT:
				t.stack[t.bp + code.decode_u32(t.pc)] = s[-1]
				t.pc += 4
			OP_LOAD_STRING:
				var idx := code.decode_u32(t.pc)
				t.pc += 4
				s.push_back(t.pkg.strings[idx] if idx < t.pkg.strings.size() else "")
			OP_EQUAL_OBJECTS:
				var b: Variant = s.pop_back()
				s[-1] = 1 if s[-1] == b else 0
			OP_CLONE_OBJECT:
				var v: Variant = s[-1]
				s[-1] = v.duplicate() if v is Array or v is Dictionary else v
			OP_END_TIMESLICE:
				return
			OP_TIMED_JUMP:
				# "run the body at most once every `interval` seconds": if not
				# enough time has passed since the stamp in local `slot`, skip
				# to `target`; otherwise re-stamp and fall through.
				var target := code.decode_u32(t.pc)
				var slot := code.decode_u32(t.pc + 4)
				var interval := code.decode_float(t.pc + 8)
				t.pc += 12
				if time - float(t.stack[t.bp + slot]) <= interval:
					t.pc = target
				else:
					t.stack[t.bp + slot] = time
			OP_BEGIN_ATOMIC:
				t.atomic += 1
			OP_END_ATOMIC:
				if t.atomic > 0:
					t.atomic -= 1
			OP_DEBUG_SKIP:
				t.pc = code.decode_u32(t.pc)   # developer mode off: skip `debug`
			_:
				push_error("POG: unknown opcode 0x%02X in %s at %d"
						% [op, t.pkg.name, t.pc - 1])
				t.halted = true
				return

		# The engine re-tests "am I still runnable?" after *every* instruction,
		# not just at EndTimeslice. That is what makes task.Sleep work inside a
		# busy-wait like iconversation's `while (!done) Sleep(Current(), 0.5)`,
		# which never yields explicitly: the sleep takes effect immediately.
		if time < t.wake_at:
			return


## Push a call frame and jump. Args are already on the stack and become the
## callee's locals 0..argc-1 (POG passes arguments by leaving them in place).
func _enter(t: PogTask, p: PogPackage, entry: int, argc: int) -> void:
	var base := t.stack.size() - argc
	t.frames.push_back([t.pc, t.pkg, t.bp, base])
	t.pkg = p
	t.pc = entry
	t.bp = base


func _start_from(t: PogTask, p: PogPackage, entry: int, argc: int) -> void:
	var args := t.stack.slice(t.stack.size() - argc, t.stack.size())
	t.stack.resize(t.stack.size() - argc)
	var child := _spawn(p, entry, args, p.name)
	t.stack.push_back(child.id if child != null else 0)


func _call_native(t: PogTask, link: Dictionary, argc: int) -> void:
	var args := t.stack.slice(t.stack.size() - argc, t.stack.size())
	t.stack.resize(t.stack.size() - argc)
	var fqn: String = link.get("fqn", "?")
	called[fqn] = called.get(fqn, 0) + 1
	var fn: Callable = link["native"]
	var rv: Variant = fn.call(t, args)
	t.stack.push_back(0 if rv == null else rv)


## POG has no bool type: 0 is false, everything else true. An object handle is
## true when non-null, which is how scripts test `if (ship)`.
static func _truthy(v: Variant) -> bool:
	if v == null:
		return false
	if v is int:
		return v != 0
	if v is float:
		return v != 0.0
	if v is String:
		return not (v as String).is_empty()
	if v is Object:
		return is_instance_valid(v)
	return true


## Put a task to sleep for `secs` (task.Sleep and friends).
func sleep_task(t: PogTask, secs: float) -> void:
	t.wake_at = time + secs
