class_name PogFactions
extends RefCounted

## ifaction + group: diplomacy and squadrons.
##
## ifaction.SetFeeling is the single hottest game-facing native in the campaign
## (5,529 call sites): the scripts spend most of their diplomacy budget writing
## a feelings matrix. Feeling is a float in [-1, +1] -- the literals the scripts
## push are 0.0, +-0.3, +-0.4, +-0.5, +-1.0 -- where negative is hostile,
## positive allied. Everything that decides "will this ship shoot at that one"
## reduces to a lookup in that matrix, so it is worth having exactly right.
##
## group is the squadron model: an ordered set of sims with a Leader, which is
## what wingmen, patrols and convoys are built from. Groups nest (AddGroup), so
## Flatten/TotalSimCount walk the tree.

## Below this, two factions shoot on sight. The scripts' own vocabulary -- they
## set -0.3 for "annoyed" and -1.0 for war -- puts the line at zero.
const HOSTILE_BELOW := 0.0

var vm: PogVM
var factions: Dictionary = {}     ## name -> PogFaction


class PogFaction extends RefCounted:
	var name: String
	var allegiance: int = 0
	var feelings: Dictionary = {}   ## other faction name -> float [-1, +1]

	func feeling_toward(other: String) -> float:
		return feelings.get(other, 0.0)


class PogGroup extends RefCounted:
	var sims: Array = []
	var groups: Array = []          ## nested subgroups

	## The leader is simply the first member: PromoteSim moves a sim to the
	## front, which is how the scripts hand over command when one dies.
	func leader() -> Variant:
		return sims[0] if not sims.is_empty() else null

	func flatten() -> Array:
		var out := sims.duplicate()
		for g in groups:
			out.append_array(g.flatten())
		return out


func register(v: PogVM) -> void:
	vm = v
	for fq in _BINDINGS:
		v.bind(fq, Callable(self, _BINDINGS[fq]))


## Is `a` hostile to `b`? The one question the rest of the game asks of all this.
func hostile(a: Variant, b: Variant) -> bool:
	var fa := _as_faction(a)
	var fb := _as_faction(b)
	if fa == null or fb == null or fa == fb:
		return false
	return fa.feeling_toward(fb.name) < HOSTILE_BELOW


func _as_faction(v: Variant) -> PogFaction:
	if v is PogFaction:
		return v
	if v is String:
		return factions.get(v, null)
	return null


# ---------------------------------------------------------------- ifaction
# @native ifaction.Create
func _f_create(_t, a: Array) -> Variant:
	var name := PogStd._s(a[0])
	if factions.has(name):
		return factions[name]
	var f := PogFaction.new()
	f.name = name
	f.allegiance = int(a[1]) if a.size() > 1 else 0
	factions[name] = f
	return f

# @native ifaction.Find
func _f_find(_t, a: Array) -> Variant:
	# The scripts call Find far more often than Create and assume the standing
	# factions already exist, so an unknown name is created on demand rather
	# than returning null into a hundred unchecked call sites.
	return _f_create(_t, [PogStd._s(a[0]), 0])

# @native ifaction.SetFeeling
func _f_set_feeling(_t, a: Array) -> Variant:
	var f := _as_faction(a[0])
	var other := _as_faction(a[1])
	if f != null and other != null:
		f.feelings[other.name] = clampf(float(a[2]), -1.0, 1.0)
	return 0

# @native ifaction.IncrementFeeling
func _f_inc_feeling(_t, a: Array) -> Variant:
	var f := _as_faction(a[0])
	var other := _as_faction(a[1])
	if f != null and other != null:
		f.feelings[other.name] = clampf(
				f.feeling_toward(other.name) + float(a[2]), -1.0, 1.0)
	return 0

# @native ifaction.Feeling
func _f_feeling(_t, a: Array) -> Variant:
	var f := _as_faction(a[0])
	var other := _as_faction(a[1])
	if f == null or other == null:
		return 0.0
	return f.feeling_toward(other.name)

# @native ifaction.FeelingLevel
func _f_feeling_level(_t, a: Array) -> Variant:
	var f := _as_faction(a[0])
	return f.allegiance if f != null else 0

# @native ifaction.Allegiance
func _f_allegiance(_t, a: Array) -> Variant:
	var f := _as_faction(a[0])
	return f.allegiance if f != null else 0

# @native ifaction.Name
func _f_name(_t, a: Array) -> Variant:
	var f := _as_faction(a[0])
	return f.name if f != null else ""

# @native ifaction.All
func _f_all(_t, _a: Array) -> Variant:
	return factions.values()

# @native ifaction.Cast
func _f_cast(_t, a: Array) -> Variant:
	return _as_faction(a[0])


# ---------------------------------------------------------------- group
# @native group.Create
func _g_create(_t, _a: Array) -> Variant:
	return PogGroup.new()

# @native group.AddSim
func _g_add_sim(_t, a: Array) -> Variant:
	var g = a[0]
	if g is PogGroup and a[1] != null and not g.sims.has(a[1]):
		g.sims.append(a[1])
	return 0

# @native group.RemoveSim
func _g_remove_sim(_t, a: Array) -> Variant:
	var g = a[0]
	if g is PogGroup:
		g.sims.erase(a[1])
	return 0

# @native group.RemoveNthSim
func _g_remove_nth_sim(_t, a: Array) -> Variant:
	var g = a[0]
	var i := int(a[1])
	if g is PogGroup and i >= 0 and i < g.sims.size():
		g.sims.remove_at(i)
	return 0

# @native group.NthSim
func _g_nth_sim(_t, a: Array) -> Variant:
	var g = a[0]
	var i := int(a[1])
	if g is PogGroup and i >= 0 and i < g.sims.size():
		return g.sims[i]
	return null

# @native group.SimCount
func _g_sim_count(_t, a: Array) -> Variant:
	var g = a[0]
	return g.sims.size() if g is PogGroup else 0

# @native group.TotalSimCount
func _g_total_sim_count(_t, a: Array) -> Variant:
	var g = a[0]
	return g.flatten().size() if g is PogGroup else 0

# @native group.Leader
func _g_leader(_t, a: Array) -> Variant:
	var g = a[0]
	return g.leader() if g is PogGroup else null

# @native group.PromoteSim
func _g_promote_sim(_t, a: Array) -> Variant:
	var g = a[0]
	if g is PogGroup and g.sims.has(a[1]):
		g.sims.erase(a[1])
		g.sims.push_front(a[1])
	return 0

# @native group.AddGroup
func _g_add_group(_t, a: Array) -> Variant:
	var g = a[0]
	if g is PogGroup and a[1] is PogGroup and not g.groups.has(a[1]):
		g.groups.append(a[1])
	return 0

# @native group.RemoveGroup
func _g_remove_group(_t, a: Array) -> Variant:
	var g = a[0]
	if g is PogGroup:
		g.groups.erase(a[1])
	return 0

# @native group.RemoveNthGroup
func _g_remove_nth_group(_t, a: Array) -> Variant:
	var g = a[0]
	var i := int(a[1])
	if g is PogGroup and i >= 0 and i < g.groups.size():
		g.groups.remove_at(i)
	return 0

# @native group.NthGroup
func _g_nth_group(_t, a: Array) -> Variant:
	var g = a[0]
	var i := int(a[1])
	if g is PogGroup and i >= 0 and i < g.groups.size():
		return g.groups[i]
	return null

# @native group.GroupCount
func _g_group_count(_t, a: Array) -> Variant:
	var g = a[0]
	return g.groups.size() if g is PogGroup else 0

# @native group.Flatten
func _g_flatten(_t, a: Array) -> Variant:
	var g = a[0]
	return g.flatten() if g is PogGroup else []

# @native group.FromSet
func _g_from_set(_t, a: Array) -> Variant:
	var g := PogGroup.new()
	if a[0] is Array:
		g.sims = (a[0] as Array).duplicate()
	return g

# @native group.Destroy
func _g_destroy(_t, a: Array) -> Variant:
	var g = a[0]
	if g is PogGroup:
		g.sims.clear()
		g.groups.clear()
	return 0

# @native group.Cast
func _g_cast(_t, a: Array) -> Variant:
	var v = a[0]
	return v if v is PogGroup else null


const _BINDINGS := {
	"ifaction.create": "_f_create", "ifaction.find": "_f_find",
	"ifaction.setfeeling": "_f_set_feeling",
	"ifaction.incrementfeeling": "_f_inc_feeling",
	"ifaction.feeling": "_f_feeling",
	"ifaction.feelinglevel": "_f_feeling_level",
	"ifaction.allegiance": "_f_allegiance", "ifaction.name": "_f_name",
	"ifaction.all": "_f_all", "ifaction.cast": "_f_cast",

	"group.create": "_g_create", "group.addsim": "_g_add_sim",
	"group.removesim": "_g_remove_sim",
	"group.removenthsim": "_g_remove_nth_sim",
	"group.nthsim": "_g_nth_sim", "group.simcount": "_g_sim_count",
	"group.totalsimcount": "_g_total_sim_count", "group.leader": "_g_leader",
	"group.promotesim": "_g_promote_sim", "group.addgroup": "_g_add_group",
	"group.removegroup": "_g_remove_group",
	"group.removenthgroup": "_g_remove_nth_group",
	"group.nthgroup": "_g_nth_group", "group.groupcount": "_g_group_count",
	"group.flatten": "_g_flatten", "group.fromset": "_g_from_set",
	"group.destroy": "_g_destroy", "group.cast": "_g_cast",
}
