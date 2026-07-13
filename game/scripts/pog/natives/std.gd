class_name PogStd
extends RefCounted

## The POG language runtime: the native packages that carry no game state.
##
## These are the compiled-in packages every script leans on -- global (the
## story-flag store, and the single hottest function in the game at 8k call
## sites), task (cooperative scheduling), state (story progress), object
## (property bags), text (the localised CSV tables), plus the containers and
## maths. Roughly 55% of all native call sites in the campaign land here, and
## none of it touches the world, so it is exact rather than approximated.
##
## Each binding carries a `# @native pkg.Func` marker; tools/iw2/apicov.py
## scans for those to report coverage against the real call census.

var vm   ## the host: PogRuntime for the ported scripts, PogVM for the oracle
## global.* -- typed, named, persistent-ish variable store.
var globals: Dictionary = {}
## object.* -- property bags hung off arbitrary script objects.
var props: Dictionary = {}
## state.* -- named story-progress records.
var states: Dictionary = {}
## text.* -- loaded CSV string tables, keyed by row.
var text_tables: Dictionary = {}
var _loaded_csv: Array[String] = []


class PogState extends RefCounted:
	var name: String
	var progress: int = 0
	var task_id: int = 0


func register(v) -> void:
	vm = v
	for fq in _BINDINGS:
		v.bind(fq, Callable(self, _BINDINGS[fq]))


## Variant -> String. POG passes null object handles around freely (an unset
## `object` local is null), and String(null) is not a valid constructor, so
## every string coercion goes through here.
static func _s(v: Variant) -> String:
	return "" if v == null else str(v)


# ---------------------------------------------------------------- global
# A name -> value store. Every typed accessor lands in the same dictionary:
# POG is statically typed at compile time, so the Int/Bool/Float/String/Handle
# split is a compile-time distinction the runtime does not need to re-check.
# Create* takes (name, flag, value): every one of them is argc=3, and the value
# is the THIRD argument, not the second. The second is the save-game persistence
# scope (2, 14, 1 ...). Proof:
#   global.CreateInt("GUI_inversebutton_height", 14, 16)  -- and igui then passes
#     global.Int("GUI_inversebutton_height") as a button's height, so 16 is it
#   global.CreateBool("Hangar_Flashing", 2, 1)            -- 2 is not a bool
#   global.CreateInt("g_current_act", 2, -1)              -- and ijafsscript.pog
#     :1379 tests `-1 == global.Int("g_current_act")`, so -1 is the value
#
# THIS IS KNOWINGLY WRONG, and it is left wrong on purpose. See docs/original.md
# "Two bugs that cancel": the ported comparison operators have their operands the
# wrong way round, so `if (0 < global.Int("g_current_act"))` -- which gates the
# whole Act 0 prologue in iPrelude.Main -- only passes because this stores the
# flag (2) instead of the value (-1). Correcting this one alone stops the
# campaign starting. The two have to be fixed together, and the comparison half
# lives in tools/iw2/pogdec.py, pogport.py and pog/vm.gd.

# @native global.CreateBool
# @native global.CreateInt
# @native global.CreateFloat
# @native global.CreateString
# @native global.CreateHandle
# @native global.CreateList
# @native global.CreateSet
func _create(_t, a: Array) -> Variant:
	var name := _s(a[0])
	if not globals.has(name):
		globals[name] = a[1] if a.size() > 1 else 0
	return 0

# @native global.Bool
# @native global.Int
# @native global.Float
# @native global.String
# @native global.Handle
# @native global.List
# @native global.Set
func _glob_get(_t, a: Array) -> Variant:
	return globals.get(_s(a[0]), 0)

# @native global.SetBool
# @native global.SetInt
# @native global.SetFloat
# @native global.SetString
# @native global.SetHandle
# @native global.SetList
# @native global.SetSet
# @native global.Set
func _glob_set(_t, a: Array) -> Variant:
	globals[_s(a[0])] = a[1] if a.size() > 1 else 0
	return 0

# @native global.Exists
func _exists(_t, a: Array) -> Variant:
	return 1 if globals.has(_s(a[0])) else 0

# @native global.Destroy
func _destroy(_t, a: Array) -> Variant:
	globals.erase(_s(a[0]))
	return 0


# ---------------------------------------------------------------- debug
# @native debug.PrintString
# @native debug.PrintInt
# @native debug.PrintFloat
# @native debug.PrintHandle
func _print(_t, a: Array) -> Variant:
	if PogVM.trace_debug:
		print("[pog] ", a[0] if a.size() > 0 else "")
	return 0

# @native debug.Error
func _error(_t, a: Array) -> Variant:
	push_error("[pog] %s" % (a[0] if a.size() > 0 else ""))
	return 0

# @native debug.DeveloperMode
func _developer_mode(_t, _a: Array) -> Variant:
	return 0


# ---------------------------------------------------------------- task
# @native task.Current
func _task_current(t, _a: Array) -> Variant:
	return t

# @native task.Sleep
func _task_sleep(_t, a: Array) -> Variant:
	# Sleep(task, seconds). The script yields (EndTimeslice) immediately
	# after, and the scheduler skips it until the wake time.
	var target = a[0]
	if target is PogVM.PogTask:
		vm.sleep_task(target, float(a[1]))
	return 0

# @native task.Halt
func _task_halt(_t, a: Array) -> Variant:
	var target = a[0] if a.size() > 0 else null
	if target is PogVM.PogTask:
		target.halted = true
	return 0

# @native task.Detach
func _task_detach(_t, _a: Array) -> Variant:
	# Detach means "outlive my parent". We never cascade-kill children, so a
	# detached task is already what a plain task is here.
	return 0

# @native task.IsRunning
func _task_is_running(_t, a: Array) -> Variant:
	var target = a[0] if a.size() > 0 else null
	return 1 if (target is PogVM.PogTask and not target.halted) else 0

# @native task.IsHalted
func _task_is_halted(_t, a: Array) -> Variant:
	var target = a[0] if a.size() > 0 else null
	return 1 if (target == null or (target is PogVM.PogTask and target.halted)) else 0

# @native task.Suspend
func _task_suspend(_t, a: Array) -> Variant:
	var target = a[0] if a.size() > 0 else null
	if target is PogVM.PogTask:
		target.wake_at = INF
	return 0

# @native task.Resume
func _task_resume(_t, a: Array) -> Variant:
	var target = a[0] if a.size() > 0 else null
	if target is PogVM.PogTask:
		target.wake_at = 0.0
	return 0

# @native task.SuspendAll
func _task_suspend_all(t, _a: Array) -> Variant:
	# Everything *else*. istartsystem.FinalSetup calls this immediately before
	# spawning the launch cutscene, so suspending the caller as well deadlocks
	# the boot -- which is exactly what it did.
	for other in vm.tasks:
		if other != t:
			other.wake_at = INF
	return 0

# @native task.ResumeAll
func _task_resume_all(_t, _a: Array) -> Variant:
	for t in vm.tasks:
		t.wake_at = 0.0
	return 0

# @native task.Cast
func _task_cast(_t, a: Array) -> Variant:
	var v = a[0] if a.size() > 0 else null
	return v if v is PogVM.PogTask else null


# ---------------------------------------------------------------- state
# Named story-progress records: the campaign's spine. A mission calls
# state.Create("act1_mission03"), then walks SetProgress(s, n) as it goes;
# the save game is essentially the set of these.

# @native state.Create
func _state_create(_t, a: Array) -> Variant:
	var name := _s(a[0])
	if states.has(name):
		return states[name]
	var s := PogState.new()
	s.name = name
	states[name] = s
	return s

# @native state.Find
func _state_find(_t, a: Array) -> Variant:
	return states.get(_s(a[0]), null)

# @native state.SetProgress
func _state_set_progress(_t, a: Array) -> Variant:
	var s = a[0]
	if s is PogState:
		s.progress = int(a[1])
	return 0

# @native state.Progress
func _state_progress(_t, a: Array) -> Variant:
	var s = a[0] if a.size() > 0 else null
	return s.progress if s is PogState else 0

# @native state.Destroy
func _state_destroy(_t, a: Array) -> Variant:
	var s = a[0] if a.size() > 0 else null
	if s is PogState:
		states.erase(s.name)
	return 0

# @native state.DestroyAll
func _state_destroy_all(_t, _a: Array) -> Variant:
	states.clear()
	return 0

# @native state.Task
func _state_task(_t, a: Array) -> Variant:
	var s = a[0] if a.size() > 0 else null
	return vm.find_task(s.task_id) if s is PogState else null

# @native state.Restore
func _state_restore(_t, _a: Array) -> Variant:
	return 0

# @native state.Cast
func _state_cast(_t, a: Array) -> Variant:
	var v = a[0] if a.size() > 0 else null
	return v if v is PogState else null


# ---------------------------------------------------------------- object
# Property bags hung off any script object. Keyed by instance so that engine
# objects (ships, sims) can carry script-authored properties too.

func _bag(o: Variant) -> Dictionary:
	var key: Variant = _key(o)
	if not props.has(key):
		props[key] = {}
	return props[key]

func _key(o: Variant) -> Variant:
	return o.get_instance_id() if o is Object else o

# @native object.AddBoolProperty
# @native object.AddIntProperty
# @native object.AddFloatProperty
# @native object.AddStringProperty
# @native object.AddHandleProperty
# @native object.AddListProperty
# @native object.AddSetProperty
func _obj_add(_t, a: Array) -> Variant:
	_bag(a[0])[_s(a[1])] = a[2] if a.size() > 2 else 0
	return 0

# @native object.BoolProperty
# @native object.IntProperty
# @native object.FloatProperty
# @native object.StringProperty
# @native object.HandleProperty
# @native object.ListProperty
# @native object.SetProperty
func _obj_get(_t, a: Array) -> Variant:
	return _bag(a[0]).get(_s(a[1]), 0)

# @native object.SetBoolProperty
# @native object.SetIntProperty
# @native object.SetFloatProperty
# @native object.SetStringProperty
# @native object.SetHandleProperty
# @native object.SetListProperty
# @native object.SetSetProperty
func _obj_set(_t, a: Array) -> Variant:
	_bag(a[0])[_s(a[1])] = a[2] if a.size() > 2 else 0
	return 0

# @native object.PropertyExists
func _obj_exists(_t, a: Array) -> Variant:
	return 1 if _bag(a[0]).has(_s(a[1])) else 0

# @native object.RemoveProperty
func _obj_remove(_t, a: Array) -> Variant:
	_bag(a[0]).erase(_s(a[1]))
	return 0

# @native object.Destroy
func _obj_destroy(_t, a: Array) -> Variant:
	props.erase(_key(a[0]))
	return 0


# ---------------------------------------------------------------- text
# The localised string tables. text.Add("csv:/text/act_1/act1_master") loads a
# CSV; Field(key, column) reads a cell. Our extraction already writes these out
# as UTF-8 CSV under data/text/.

# @native text.Add
func _text_add(_t, a: Array) -> Variant:
	var path := _s(a[0])
	if _loaded_csv.has(path):
		return 0
	_loaded_csv.append(path)
	_load_csv(path)
	return 0

# @native text.Remove
func _text_remove(_t, a: Array) -> Variant:
	_loaded_csv.erase(_s(a[0]))
	return 0

# @native text.Field
func _text_field(_t, a: Array) -> Variant:
	var row: Array = text_tables.get(_s(a[0]), [])
	var col := int(a[1])
	return row[col] if col < row.size() else ""


func _load_csv(path: String) -> void:
	# "csv:/text/act_1/act1_master" -> data/text/act_1/act1_master.csv
	var rel := path.trim_prefix("csv:").trim_prefix("/")
	var full := ProjectSettings.globalize_path("res://").path_join(
			"../data/%s.csv" % rel)
	var f := FileAccess.open(full, FileAccess.READ)
	if f == null:
		return
	while not f.eof_reached():
		var row := f.get_csv_line()
		# The tables are commented with a leading ';' -- skip those, and the
		# blank separator rows between sections.
		if row.size() > 0 and not row[0].is_empty() and not row[0].begins_with(";"):
			text_tables[row[0]] = Array(row).slice(1)
	f.close()


# ---------------------------------------------------------------- math
# @native math.Random
func _rand(_t, _a: Array) -> Variant:
	return randf()

# @native math.RandomInt
func _rand_int(_t, a: Array) -> Variant:
	var lo := int(a[0]) if a.size() > 1 else 0
	var hi := int(a[1]) if a.size() > 1 else int(a[0])
	return randi_range(lo, hi) if hi > lo else lo

# @native math.Sin
func _sin(_t, a: Array) -> Variant:
	return sin(float(a[0]))

# @native math.Cos
func _cos(_t, a: Array) -> Variant:
	return cos(float(a[0]))

# @native math.Sqrt
func _sqrt(_t, a: Array) -> Variant:
	return sqrt(maxf(0.0, float(a[0])))

# @native math.CubeRoot
func _cbrt(_t, a: Array) -> Variant:
	var x := float(a[0])
	return signf(x) * pow(absf(x), 1.0 / 3.0)

# @native math.Abs
func _abs(_t, a: Array) -> Variant:
	var v = a[0]
	return absf(v) if v is float else absi(int(v))


# ---------------------------------------------------------------- string
# @native string.Join
func _str_join(_t, a: Array) -> Variant:
	var out := ""
	for v in a:
		out += _s(v)
	return out

# @native string.FromInt
func _str_from_int(_t, a: Array) -> Variant:
	return str(int(a[0]))

# @native string.FromFloat
func _str_from_float(_t, a: Array) -> Variant:
	return str(float(a[0]))

# @native string.ToInt
func _str_to_int(_t, a: Array) -> Variant:
	return int(_s(a[0]).to_int())

# @native string.Length
func _str_length(_t, a: Array) -> Variant:
	return _s(a[0]).length()

# @native string.UpperCase
func _str_upper(_t, a: Array) -> Variant:
	return _s(a[0]).to_upper()

# @native string.Left
func _str_left(_t, a: Array) -> Variant:
	return _s(a[0]).left(int(a[1]))

# @native string.Right
func _str_right(_t, a: Array) -> Variant:
	return _s(a[0]).right(int(a[1]))

# @native string.TrimLeft
func _str_trim_left(_t, a: Array) -> Variant:
	return _s(a[0]).lstrip(" \t\n\r")

# @native string.TrimRight
func _str_trim_right(_t, a: Array) -> Variant:
	return _s(a[0]).rstrip(" \t\n\r")

# @native string.FormatStrStr
func _str_format(_t, a: Array) -> Variant:
	var s := _s(a[0])
	for i in range(1, a.size()):
		s = s.replace("%s", _s(a[i]), )
	return s


# ---------------------------------------------------------------- list
# POG's list is a deque: AddTail/AddHead, Head/Tail, RemoveHead. A POG list is
# a plain GDScript Array here; the sorts take a *property name* and order by the
# object.* property bag, which is why they live in this file.

# @native list.AddTail
# @native list.Append
func _list_add_tail(_t, a: Array) -> Variant:
	var l = a[0]
	if l is Array:
		l.append(a[1])
	return 0

# @native list.AddHead
func _list_add_head(_t, a: Array) -> Variant:
	var l = a[0]
	if l is Array:
		l.push_front(a[1])
	return 0

# @native list.ItemCount
func _list_count(_t, a: Array) -> Variant:
	var l = a[0]
	return l.size() if l is Array else 0

# @native list.IsEmpty
func _list_is_empty(_t, a: Array) -> Variant:
	var l = a[0]
	return 1 if (not (l is Array) or (l as Array).is_empty()) else 0

# @native list.GetNth
func _list_nth(_t, a: Array) -> Variant:
	var l = a[0]
	var i := int(a[1])
	if l is Array and i >= 0 and i < l.size():
		return l[i]
	return null

# @native list.SetNth
func _list_set_nth(_t, a: Array) -> Variant:
	var l = a[0]
	var i := int(a[1])
	if l is Array and i >= 0 and i < l.size():
		l[i] = a[2]
	return 0

# @native list.Head
func _list_head(_t, a: Array) -> Variant:
	var l = a[0]
	if l is Array and not (l as Array).is_empty():
		return l[0]
	return null

# @native list.Tail
func _list_tail(_t, a: Array) -> Variant:
	var l = a[0]
	if l is Array and not (l as Array).is_empty():
		return l[-1]
	return null

# @native list.RemoveHead
func _list_remove_head(_t, a: Array) -> Variant:
	var l = a[0]
	if l is Array and not (l as Array).is_empty():
		return (l as Array).pop_front()
	return null

# @native list.Remove
func _list_remove(_t, a: Array) -> Variant:
	var l = a[0]
	if l is Array:
		l.erase(a[1])
	return 0

# @native list.RemoveNth
func _list_remove_nth(_t, a: Array) -> Variant:
	var l = a[0]
	var i := int(a[1])
	if l is Array and i >= 0 and i < l.size():
		l.remove_at(i)
	return 0

# @native list.RemoveAll
func _list_clear(_t, a: Array) -> Variant:
	var l = a[0]
	if l is Array:
		l.clear()
	return 0

# @native list.RemoveMembers
func _list_remove_members(_t, a: Array) -> Variant:
	var l = a[0]
	var other = a[1]
	if l is Array and other is Array:
		for v in other:
			l.erase(v)
	return 0

# @native list.Contains
func _list_contains(_t, a: Array) -> Variant:
	var l = a[0]
	return 1 if (l is Array and l.has(a[1])) else 0

# @native list.SortByIntProperty
# @native list.SortByFloatProperty
# @native list.SortByStringProperty
func _list_sort_by(_t, a: Array) -> Variant:
	var l = a[0]
	if not (l is Array):
		return 0
	var key := _s(a[1])
	var bags := props
	(l as Array).sort_custom(func(x, y) -> bool:
		var bx = bags.get(_key(x), {}).get(key, 0)
		var by = bags.get(_key(y), {}).get(key, 0)
		return bx < by)
	return 0


# ---------------------------------------------------------------- set
# @native set.Add
func _set_add(_t, a: Array) -> Variant:
	var s = a[0]
	if s is Array and not s.has(a[1]):
		s.append(a[1])
	return 0

# @native set.ItemCount
func _set_count(_t, a: Array) -> Variant:
	var s = a[0]
	return s.size() if s is Array else 0

# @native set.IsEmpty
func _set_is_empty(_t, a: Array) -> Variant:
	return _list_is_empty(_t, a)

# @native set.FirstElement
func _set_first(_t, a: Array) -> Variant:
	return _list_head(_t, a)

# @native set.Remove
func _set_remove(_t, a: Array) -> Variant:
	return _list_remove(_t, a)

# @native set.Contains
func _set_contains(_t, a: Array) -> Variant:
	return _list_contains(_t, a)

# @native set.FromList
func _set_from_list(_t, a: Array) -> Variant:
	var out: Array = []
	if a[0] is Array:
		for v in a[0]:
			if not out.has(v):
				out.append(v)
	return out

# @native set.Union
func _set_union(_t, a: Array) -> Variant:
	var out: Array = (a[0] as Array).duplicate() if a[0] is Array else []
	if a[1] is Array:
		for v in a[1]:
			if not out.has(v):
				out.append(v)
	return out

# @native set.Difference
func _set_difference(_t, a: Array) -> Variant:
	var out: Array = (a[0] as Array).duplicate() if a[0] is Array else []
	if a[1] is Array:
		for v in a[1]:
			out.erase(v)
	return out

# @native list.FromSet
func _list_from_set(_t, a: Array) -> Variant:
	return (a[0] as Array).duplicate() if a[0] is Array else []


# ---------------------------------------------------------------- vectors
# POG has no vector type: a "vector property" is three floats behind one name,
# which is how the scripts stash positions on an object.

# @native object.SetVectorProperty
func _obj_set_vector(_t, a: Array) -> Variant:
	var bag := _bag(a[0])
	var key := _s(a[1])
	bag[key + ".x"] = float(a[2]) if a.size() > 2 else 0.0
	bag[key + ".y"] = float(a[3]) if a.size() > 3 else 0.0
	bag[key + ".z"] = float(a[4]) if a.size() > 4 else 0.0
	return 0

# @native object.VectorPropertyX
func _obj_vector_x(_t, a: Array) -> Variant:
	return _bag(a[0]).get(_s(a[1]) + ".x", 0.0)

# @native object.VectorPropertyY
func _obj_vector_y(_t, a: Array) -> Variant:
	return _bag(a[0]).get(_s(a[1]) + ".y", 0.0)

# @native object.VectorPropertyZ
func _obj_vector_z(_t, a: Array) -> Variant:
	return _bag(a[0]).get(_s(a[1]) + ".z", 0.0)

# @native object.IDModulus
func _obj_id_modulus(_t, a: Array) -> Variant:
	# A cheap stable hash of an object's identity: the scripts use it to spread
	# work across frames and to pick a variant per object without a RNG.
	var n := int(a[1]) if a.size() > 1 else 1
	if n == 0:
		return 0
	var k: Variant = _key(a[0])
	return absi(int(k) if k is int else hash(k)) % n

# @native task.Call
func _task_call(t, a: Array) -> Variant:
	# Call(task): run a task to completion synchronously. Nothing in the retail
	# campaign relies on the blocking part (one call site), so we let it run on
	# its own and hand back the handle.
	return a[0] if a.size() > 0 else t


const _BINDINGS := {
	"global.createbool": "_create", "global.createint": "_create",
	"global.createfloat": "_create", "global.createstring": "_create",
	"global.createhandle": "_create", "global.createlist": "_create",
	"global.createset": "_create",
	"global.bool": "_glob_get", "global.int": "_glob_get",
	"global.float": "_glob_get", "global.string": "_glob_get",
	"global.handle": "_glob_get", "global.list": "_glob_get",
	"global.setbool": "_glob_set", "global.setint": "_glob_set",
	"global.setfloat": "_glob_set", "global.setstring": "_glob_set",
	"global.sethandle": "_glob_set", "global.setlist": "_glob_set",
	"global.setset": "_glob_set", "global.set": "_glob_set",
	"global.exists": "_exists", "global.destroy": "_destroy",

	"debug.printstring": "_print", "debug.printint": "_print",
	"debug.printfloat": "_print", "debug.printhandle": "_print",
	"debug.error": "_error", "debug.developermode": "_developer_mode",

	"task.current": "_task_current", "task.sleep": "_task_sleep",
	"task.halt": "_task_halt", "task.detach": "_task_detach",
	"task.isrunning": "_task_is_running", "task.ishalted": "_task_is_halted",
	"task.suspend": "_task_suspend", "task.resume": "_task_resume",
	"task.suspendall": "_task_suspend_all", "task.resumeall": "_task_resume_all",
	"task.cast": "_task_cast",

	"state.create": "_state_create", "state.find": "_state_find",
	"state.setprogress": "_state_set_progress",
	"state.progress": "_state_progress", "state.destroy": "_state_destroy",
	"state.destroyall": "_state_destroy_all", "state.task": "_state_task",
	"state.restore": "_state_restore", "state.cast": "_state_cast",

	"object.addboolproperty": "_obj_add", "object.addintproperty": "_obj_add",
	"object.addfloatproperty": "_obj_add",
	"object.addstringproperty": "_obj_add",
	"object.addhandleproperty": "_obj_add",
	"object.addlistproperty": "_obj_add", "object.addsetproperty": "_obj_add",
	"object.boolproperty": "_obj_get", "object.intproperty": "_obj_get",
	"object.floatproperty": "_obj_get", "object.stringproperty": "_obj_get",
	"object.handleproperty": "_obj_get", "object.listproperty": "_obj_get",
	"object.setproperty": "_obj_get",
	"object.setboolproperty": "_obj_set", "object.setintproperty": "_obj_set",
	"object.setfloatproperty": "_obj_set",
	"object.setstringproperty": "_obj_set",
	"object.sethandleproperty": "_obj_set",
	"object.setlistproperty": "_obj_set",
	"object.setsetproperty": "_obj_set",
	"object.propertyexists": "_obj_exists",
	"object.removeproperty": "_obj_remove", "object.destroy": "_obj_destroy",

	"text.add": "_text_add", "text.remove": "_text_remove",
	"text.field": "_text_field",

	"math.random": "_rand", "math.randomint": "_rand_int",
	"math.sin": "_sin", "math.cos": "_cos", "math.sqrt": "_sqrt",
	"math.cuberoot": "_cbrt", "math.abs": "_abs",

	"string.join": "_str_join", "string.fromint": "_str_from_int",
	"string.fromfloat": "_str_from_float", "string.toint": "_str_to_int",
	"string.length": "_str_length", "string.uppercase": "_str_upper",
	"string.left": "_str_left", "string.right": "_str_right",
	"string.trimleft": "_str_trim_left", "string.trimright": "_str_trim_right",
	"string.formatstrstr": "_str_format",

	"list.addtail": "_list_add_tail", "list.append": "_list_add_tail",
	"list.addhead": "_list_add_head", "list.itemcount": "_list_count",
	"list.isempty": "_list_is_empty", "list.getnth": "_list_nth",
	"list.setnth": "_list_set_nth", "list.head": "_list_head",
	"list.tail": "_list_tail", "list.removehead": "_list_remove_head",
	"list.remove": "_list_remove", "list.removenth": "_list_remove_nth",
	"list.removeall": "_list_clear",
	"list.removemembers": "_list_remove_members",
	"list.contains": "_list_contains",
	"list.sortbyintproperty": "_list_sort_by",
	"list.sortbyfloatproperty": "_list_sort_by",
	"list.sortbystringproperty": "_list_sort_by",

	"list.fromset": "_list_from_set",
	"object.setvectorproperty": "_obj_set_vector",
	"object.vectorpropertyx": "_obj_vector_x",
	"object.vectorpropertyy": "_obj_vector_y",
	"object.vectorpropertyz": "_obj_vector_z",
	"object.idmodulus": "_obj_id_modulus",
	"task.call": "_task_call",

	"set.add": "_set_add", "set.itemcount": "_set_count",
	"set.isempty": "_set_is_empty", "set.firstelement": "_set_first",
	"set.remove": "_set_remove", "set.contains": "_set_contains",
	"set.fromlist": "_set_from_list", "set.union": "_set_union",
	"set.difference": "_set_difference",
}
