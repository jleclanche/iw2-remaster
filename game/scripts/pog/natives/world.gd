class_name PogWorld
extends RefCounted

## The game-coupled native packages: sim, isim, iship, iai, ifaction,
## idirector, ihud and friends -- the half of the POG API that reaches into
## the simulation.
##
## Unlike std.gd, these need a live world to talk to. `bind_game(main)` hands
## us the game root; without it the bindings are inert, which is what lets the
## headless pogcheck harness run a real mission and simply *report* what it
## reached for. That report is the work queue -- see tools/iw2/apicov.py.

var vm: PogVM
var game: Node = null      ## the game root (main.gd), when running in-game


func register(v: PogVM) -> void:
	vm = v


func bind_game(main: Node) -> void:
	game = main
