class_name Mission
extends Node
# Campaign STATE container: the objectives list and the HUD lesson prompt.
#
# Populated by the ported campaign runtime through its natives (gameapi.gd:
# igame.NewObjective / SetObjectiveState / RemoveObjective and ihud.SetPrompt),
# read by the HUD (hud.gd's prompt + objectives panels, hud_screens.gd's
# objectives screen) and the campaign checks, and carried across save/reload by
# gameapi's session snapshot. The bytecode VM (--pog) drives the same natives.
#
# The legacy hand-authored step-runner and its Act-0 dialogue/waypoint tables
# were retired when --port (the ported GDScript runtime) became the default
# campaign path. `steps`/`idx` remain as inert defaults the campaign checks
# still probe (the port never populates them).

var main: Node3D
var objectives: Dictionary = {}  # id -> {text, done, failed}
var prompt := ""       # ihud.SetPrompt: bottom-of-HUD lesson prompt
var prompt_keys := ""  # the key-combination hint next to it
var steps: Array = []  # inert: the hand-authored driver's step list, now unused
var idx := -1          # inert: hand-authored step cursor
