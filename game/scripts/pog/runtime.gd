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
func native(fqn: String, args: Array) -> Variant:
	var fn: Callable = natives.get(fqn, Callable())
	if not fn.is_valid():
		push_error("POG: native %s is not implemented" % fqn)
		return 0
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
