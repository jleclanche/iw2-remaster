extends SceneTree

## Headless harness for the POG VM: run the game's real bytecode and report
## what it actually demands of us.
##
##   godot --headless --path game --script res://scripts/pog/pogcheck.gd \
##         -- <package> [entry] [seconds]
##
## The point is to stop guessing which natives matter. We run the original
## mission, and whatever it calls that we have not implemented gets counted and
## printed, most-wanted first. That list is the work queue.

const DEFAULT_PKG := "iact0mission10"
const DEFAULT_SECS := 30.0

var vm: PogVM
var std: PogStd
var facs: PogFactions
var world: PogWorld
var api: PogGameApi
var econ: PogEconomy
var ents: PogEntities
var ui: PogUi
var misc: PogMisc
var elapsed := 0.0
var limit := DEFAULT_SECS
var steps := 0


func _initialize() -> void:
	var argv := OS.get_cmdline_user_args()
	var pkg_name: String = argv[0] if argv.size() > 0 else DEFAULT_PKG
	var entry: String = argv[1] if argv.size() > 1 else ""
	if argv.size() > 2:
		limit = float(argv[2])

	PogVM.trace_debug = true
	vm = PogVM.new()
	root.add_child(vm)

	std = PogStd.new()
	std.register(vm)
	facs = PogFactions.new()
	facs.register(vm)
	world = PogWorld.new()
	world.factions = facs
	world.register(vm)
	api = PogGameApi.new()
	api.register(vm, world)
	econ = PogEconomy.new()
	econ.register(vm, world)
	ents = PogEntities.new()
	ents.register(vm, world)
	ui = PogUi.new()
	ui.register(vm, world)
	misc = PogMisc.new()
	misc.register(vm, world)

	var p := vm.load_package(pkg_name)
	if p == null:
		print("could not load package '%s'" % pkg_name)
		quit(1)
		return

	print("== package %s: %d bytes, %d strings, %d exports"
			% [p.name, p.code.size(), p.strings.size(), p.exports.size()])
	var names := p.exports.keys()
	names.sort()
	print("   exports: %s" % ", ".join(names))

	if entry.is_empty():
		# Missions expose a single entry; prefer the conventional names.
		for candidate in ["Main", "Start", "Init", "Run"]:
			if p.exports.has(candidate):
				entry = candidate
				break
		if entry.is_empty() and not names.is_empty():
			entry = names[0]

	print("== running %s.%s for %.0fs of game time\n" % [pkg_name, entry, limit])
	var t := vm.start(pkg_name, entry)
	if t == null:
		quit(1)
		return
	print("   [spawned task %d, pc=%d, processing=%s]"
			% [t.id, t.pc, vm.is_processing()])


func _process(delta: float) -> bool:
	elapsed += delta
	steps += 1
	vm.step(delta)
	if elapsed >= limit or vm.tasks.is_empty():
		_report()
		return true
	return false


func _report() -> void:
	print("\n== ran %.1fs of game time in %d frames" % [elapsed, steps])
	print("   tasks still live: %d" % vm.tasks.size())
	print("   packages loaded:  %d" % vm.packages.size())

	var top := []
	for k in vm.called:
		top.append([vm.called[k], k])
	top.sort_custom(func(a, b): return a[0] > b[0])
	print("\n== natives served (top 15):")
	for r in top.slice(0, 15):
		print("   %6d  %s" % [r[0], r[1]])

	if vm.missing.is_empty():
		print("\n   every native the script called is implemented.")
		return

	var rows := []
	for k in vm.missing:
		rows.append([vm.missing[k], k])
	rows.sort_custom(func(a, b): return a[0] > b[0])
	var total := 0
	for r in rows:
		total += r[0]
	print("\n== %d unimplemented natives hit (%d calls) -- the work queue:"
			% [rows.size(), total])
	for r in rows:
		print("   %6d  %s" % [r[0], r[1]])
