class_name PogEconomy
extends RefCounted

## iinventory / icargo / itrade / iloadout: cargo, trading and ship fitting.
##
## The scripts do not just *use* an economy, they *declare* it: iact*_setup runs
## 611 icargo.Create calls to define every commodity in the game, groups them
## into categories and supersets, then hangs ~1000 itrade offers off the
## habitats. So the data is all in the bytecode we already have; what was
## missing was somewhere to put it. This file is that model.
##
## Shapes come from the decompiled engine, not from guesswork:
##   icCargo(int type, name, bool playerKnows, int value, bool canManufacture,
##           int manufactureValue, bool canRecycle, int recycleValue,
##           shipSystemTemplate, encyclopediaEntry, bool playerSystem)
##   icTrade::SetTrade(faction, offeredType, numOffered, cargoClass, wanted,
##                     numWanted, offers)   -- offers <= 0 means unlimited
##   icInventory is a *singleton*: every iinventory native works on the player's
##   inventory. We still key inventories by sim, so an AI hauler can carry cargo
##   later, but the natives address the player's.
##
## Two things the original had and we do not: the money-free manufacturing loop
## is closed here by making RecycleValue pay into ManufactureUnits and
## ManufactureValue spend from it, and cargo capacity is per hull rather than
## per mount point, because we have no subsim/mount-point model to fit against.

## icTrade::eCargoClass -- what the "wanted" side of a trade is quantified over.
const CLASS_TYPE := 0
const CLASS_CATEGORY := 1
const CLASS_SUPERSET := 2

## iloadout::eShip. The indices are fixed by the Add/Got pairs in iinventory:
## iinventory.AddTug() then iloadout.SetShip(1), AddHeavyCorvette() then
## SetShip(3), and so on.
const SHIP_COMMAND_SECTION := 0
const SHIP_TUG := 1
const SHIP_FAST_ATTACK := 2
const SHIP_HEAVY_CORVETTE := 3
const SHIP_STORM_PETREL := 4

const SHIP_NAMES := [
	"Command Section", "Tug", "Fast Attack Ship", "Heavy Corvette",
	"Storm Petrel",
]

## Hold capacity per hull. The originals came out of the mount-point tables in
## the ship INIs; without those we scale off hull size, which is what the
## cargo-space warning actually needs to be monotonic in.
const SHIP_CARGO_SLOTS := [4, 24, 8, 16, 12]

var vm: PogVM
var world: PogWorld
var game: Node3D = null

## icargo.Create's registry: type id -> PogCargo, plus declaration order, which
## is the order the inventory windows list things in.
var cargo_types: Dictionary = {}
var type_order: Array[int] = []
var categories: Dictionary = {}     ## index -> PogCargoSet, over cargo types
var supersets: Dictionary = {}      ## index -> PogCargoSet, over categories
var blueprints: Dictionary = {}     ## cargo type -> blueprint cargo type

var inventories: Dictionary = {}    ## sim instance id -> PogInventory
var loadout := PogLoadout.new()


class PogCargo extends RefCounted:
	var type: int = 0
	var name: String = ""              ## localisation key, e.g. "Cargo_Water"
	var player_knows := false
	var value: int = 0
	var can_manufacture := false
	var manufacture_value: int = 0
	var can_recycle := false
	var recycle_value: int = 0
	var ship_system: String = ""       ## INI template, when this is fittable
	var encyclopedia: String = ""
	var player_system := false
	## MarkInsignificant clears this: insignificant cargo is not worth listing
	## or trading, it just sits in the hold.
	var significant := true


## A cargo category (a contiguous run of cargo types) or a superset (a
## contiguous run of categories). Both are declared as [first, last] ranges.
class PogCargoSet extends RefCounted:
	var index: int = 0
	var name: String = ""
	var encyclopedia: String = ""
	var first: int = 0
	var last: int = 0

	func contains(n: int) -> bool:
		return n >= first and n <= last


class PogTrade extends RefCounted:
	var faction = null                 ## PogFactions.PogFaction
	var offered_type: int = 0
	var num_offered: int = 0
	var cargo_class: int = CLASS_TYPE
	var wanted: int = 0                ## a cargo type, category or superset
	var num_wanted: int = 0
	var offers: int = -1               ## -1 is unlimited


class PogInventory extends RefCounted:
	var counts: Dictionary = {}        ## cargo type -> quantity
	var fresh: Dictionary = {}         ## cargo type -> "new since last visit"
	var ships: Dictionary = {}         ## eShip -> owned
	var manufacture_units: int = 0
	var trades: Array = []             ## trades offered to the player here

	func quantity(type: int) -> int:
		return int(counts.get(type, 0))

	func add(type: int, qty: int) -> void:
		counts[type] = quantity(type) + qty

	## Returns false and changes nothing when the hold is short: the trade and
	## manufacturing paths both depend on this being all-or-nothing.
	func take(type: int, qty: int) -> bool:
		if quantity(type) < qty:
			return false
		counts[type] = quantity(type) - qty
		if counts[type] <= 0:
			counts.erase(type)
			fresh.erase(type)
		return true

	func total_items() -> int:
		var n := 0
		for t in counts:
			n += int(counts[t])
		return n


class PogLoadout extends RefCounted:
	var ship: int = 0                  ## eShip; 0 is the command section
	var cargo: int = 0                 ## the selected cargo-pod configuration
	var preset: int = 0                ## eLoadout, whatever CalculateLoadout ran
	var active := false
	var ammo_types: Array[String] = []
	var desired_turret_fighters: int = 0
	var turret_fighters: int = 0
	var remote_fighter := false
	var cargo_warning := false


func register(v: PogVM, w: PogWorld) -> void:
	vm = v
	world = w
	for fq in _BINDINGS:
		v.bind(fq, Callable(self, _BINDINGS[fq]))


func bind_game(main: Node3D) -> void:
	game = main


## The scripts hand us localisation keys ("Cargo_SeekerMine"); everything the
## player reads goes through the same string table the dialogue does.
func _text(key: String) -> String:
	if game != null and game.comms != null:
		return game.comms.strings.get(key, key)
	return key


func inventory_of(sim) -> PogInventory:
	var key: Variant = sim.get_instance_id() if sim is Object else 0
	if not inventories.has(key):
		inventories[key] = PogInventory.new()
	return inventories[key]


## iinventory's implicit subject. icInventory::Instance() is the player's hold.
func player_inv() -> PogInventory:
	return inventory_of(world.player_sim() if world != null else null)


func _cargo(type: int) -> PogCargo:
	return cargo_types.get(type, null)


func _category_of(type: int) -> int:
	for i in categories:
		if categories[i].contains(type):
			return i
	return -1


func _superset_of(type: int) -> int:
	var cat := _category_of(type)
	# SuperSetContaining is called with a cargo type, but supersets are declared
	# over category indices, so an unknown type is taken as a category already.
	if cat < 0:
		cat = type
	for i in supersets:
		if supersets[i].contains(cat):
			return i
	return -1


## Does cargo type `type` satisfy the wanted side of `tr`?
func _matches(type: int, tr: PogTrade) -> bool:
	match tr.cargo_class:
		CLASS_CATEGORY:
			return _category_of(type) == tr.wanted
		CLASS_SUPERSET:
			return _superset_of(type) == tr.wanted
	return type == tr.wanted


func _held_matching(tr: PogTrade) -> int:
	var inv := player_inv()
	var n := 0
	for type in inv.counts:
		if _matches(int(type), tr):
			n += int(inv.counts[type])
	return n


func _label(type: int, qty: int) -> String:
	var c := _cargo(type)
	var name := _text(c.name) if c != null else str(type)
	return "%d %s" % [qty, name] if qty != 1 else name


## What a trade is worth to the player: what it hands over versus what it costs.
## The wanted side may be a whole category, in which case it is priced off the
## cheapest thing the player is actually holding, since that is what a trade
## would spend.
func _trade_gain(tr: PogTrade) -> int:
	var offered := _cargo(tr.offered_type)
	var gain := (offered.value if offered != null else 0) * tr.num_offered
	var unit := 0
	var inv := player_inv()
	for type in inv.counts:
		if not _matches(int(type), tr):
			continue
		var c := _cargo(int(type))
		if c != null and (unit == 0 or c.value < unit):
			unit = c.value
	if unit == 0:
		var w := _cargo(tr.wanted)
		unit = w.value if w != null else 0
	return gain - unit * tr.num_wanted


# ---------------------------------------------------------------- icargo
# The commodity table. Every cargo is declared once, at act setup, and then
# referred to by its integer type for the rest of the game.

# @native icargo.Create
func _c_create(_t, a: Array) -> Variant:
	var c := PogCargo.new()
	c.type = int(a[0])
	c.name = PogStd._s(a[1])
	c.player_knows = PogVM._truthy(a[2])
	c.value = int(a[3])
	c.can_manufacture = PogVM._truthy(a[4])
	c.manufacture_value = int(a[5])
	c.can_recycle = PogVM._truthy(a[6])
	c.recycle_value = int(a[7])
	c.ship_system = PogStd._s(a[8])
	c.encyclopedia = PogStd._s(a[9])
	c.player_system = PogVM._truthy(a[10]) if a.size() > 10 else false
	if not cargo_types.has(c.type):
		type_order.append(c.type)
	cargo_types[c.type] = c
	return c

# @native icargo.Find
func _c_find(_t, a: Array) -> Variant:
	return _cargo(int(a[0]))

# @native icargo.Cast
func _c_cast(_t, a: Array) -> Variant:
	var v = a[0]
	return v if v is PogCargo else null

# @native icargo.Name
func _c_name(_t, a: Array) -> Variant:
	var c = a[0]
	return _text(c.name) if c is PogCargo else ""

# @native icargo.Value
func _c_value(_t, a: Array) -> Variant:
	var c = a[0]
	return c.value if c is PogCargo else 0

# @native icargo.ManufactureValue
func _c_manufacture_value(_t, a: Array) -> Variant:
	var c = a[0]
	return c.manufacture_value if c is PogCargo else 0

# @native icargo.CanManufacture
func _c_can_manufacture(_t, a: Array) -> Variant:
	var c = a[0]
	return 1 if (c is PogCargo and c.can_manufacture) else 0

# @native icargo.EncyclopediaEntry
func _c_encyclopedia(_t, a: Array) -> Variant:
	var c = a[0]
	return c.encyclopedia if c is PogCargo else ""

# @native icargo.MarkInsignificant
func _c_mark_insignificant(_t, a: Array) -> Variant:
	var c = a[0]
	if c is PogCargo:
		c.significant = false
	return 0


# ---------------------------------------------------------------- iinventory
# @native iinventory.CreateCargoCategory
func _i_create_category(_t, a: Array) -> Variant:
	var s := PogCargoSet.new()
	s.index = int(a[0])
	s.name = PogStd._s(a[1])
	s.encyclopedia = PogStd._s(a[2])
	s.first = int(a[3])
	s.last = int(a[4])
	categories[s.index] = s
	return 0

# @native iinventory.CreateCargoSuperSet
func _i_create_superset(_t, a: Array) -> Variant:
	var s := PogCargoSet.new()
	s.index = int(a[0])
	s.name = PogStd._s(a[1])
	s.encyclopedia = PogStd._s(a[2])
	s.first = int(a[3])
	s.last = int(a[4])
	supersets[s.index] = s
	return 0

# @native iinventory.SetBlueprintsForCargo
func _i_set_blueprints(_t, a: Array) -> Variant:
	# SetBlueprintsForCargo(cargo, blueprint): the blueprint is itself a cargo
	# type, so owning it is what unlocks manufacturing the other.
	blueprints[int(a[0])] = int(a[1])
	return 0

# @native iinventory.GotBlueprints
func _i_got_blueprints(_t, a: Array) -> Variant:
	var type := int(a[0])
	if not blueprints.has(type):
		return 0
	return 1 if player_inv().quantity(int(blueprints[type])) > 0 else 0

# @native iinventory.Add
func _i_add(_t, a: Array) -> Variant:
	var type := int(a[0])
	player_inv().add(type, int(a[1]))
	player_inv().fresh[type] = true
	return 1

# @native iinventory.AddWithoutMarkingNew
func _i_add_quiet(_t, a: Array) -> Variant:
	player_inv().add(int(a[0]), int(a[1]))
	return 1

# @native iinventory.Remove
func _i_remove(_t, a: Array) -> Variant:
	return 1 if player_inv().take(int(a[0]), int(a[1])) else 0

# @native iinventory.NumberOfCargoType
func _i_number_of_type(_t, a: Array) -> Variant:
	return player_inv().quantity(int(a[0]))

# @native iinventory.NumberOfCargoTypes
func _i_number_of_types(_t, _a: Array) -> Variant:
	return type_order.size()

# @native iinventory.CargoTypeFromName
func _i_type_from_name(_t, a: Array) -> Variant:
	var name := PogStd._s(a[0])
	for type in type_order:
		if cargo_types[type].name == name:
			return type
	return -1

# @native iinventory.CargoCategoryFromName
func _i_category_from_name(_t, a: Array) -> Variant:
	var name := PogStd._s(a[0])
	for i in categories:
		if categories[i].name == name:
			return i
	return -1

# @native iinventory.CargoTypeFromCategoryIndex
func _i_type_from_index(_t, a: Array) -> Variant:
	# The index is a row in the inventory listing, which runs in declaration
	# order; the scripts use it to turn a selection back into a cargo type.
	var i := int(a[0])
	return type_order[i] if i >= 0 and i < type_order.size() else -1

# @native iinventory.CategoryContaining
func _i_category_containing(_t, a: Array) -> Variant:
	return _category_of(int(a[0]))

# @native iinventory.SuperSetContaining
func _i_superset_containing(_t, a: Array) -> Variant:
	return _superset_of(int(a[0]))

# @native iinventory.NumberOfRecyclableCargoInCategory
func _i_recyclable_in_category(_t, a: Array) -> Variant:
	return _count_recyclable(int(a[0]), false)

# @native iinventory.NumberOfRecyclableCargoInSuperSet
func _i_recyclable_in_superset(_t, a: Array) -> Variant:
	return _count_recyclable(int(a[0]), true)


func _count_recyclable(index: int, superset: bool) -> int:
	var inv := player_inv()
	var n := 0
	for type in inv.counts:
		var c := _cargo(int(type))
		if c == null or not c.can_recycle:
			continue
		var holder: int = _superset_of(int(type)) if superset else _category_of(int(type))
		if holder == index:
			n += int(inv.counts[type])
	return n


# @native iinventory.Recycle
func _i_recycle(_t, a: Array) -> Variant:
	# Recycling is where manufacturing units come from: break the cargo down and
	# bank its RecycleValue.
	var type := int(a[0])
	var qty := int(a[1])
	var c := _cargo(type)
	var inv := player_inv()
	if c == null or not c.can_recycle or not inv.take(type, qty):
		return 0
	inv.manufacture_units += c.recycle_value * qty
	return 1

# @native iinventory.Manufacture
func _i_manufacture(_t, a: Array) -> Variant:
	var type := int(a[0])
	var qty := int(a[1])
	var c := _cargo(type)
	var inv := player_inv()
	if c == null or not c.can_manufacture:
		return 0
	if blueprints.has(type) and not PogVM._truthy(_i_got_blueprints(_t, [type])):
		return 0
	var cost := c.manufacture_value * qty
	if inv.manufacture_units < cost:
		return 0
	inv.manufacture_units -= cost
	inv.add(type, qty)
	inv.fresh[type] = true
	return 1

# @native iinventory.ManufactureUnits
func _i_manufacture_units(_t, _a: Array) -> Variant:
	return player_inv().manufacture_units

# @native iinventory.CancelNewCargoFlags
func _i_cancel_new(_t, _a: Array) -> Variant:
	player_inv().fresh.clear()
	return 0

# --- the ship roster. Add/Got/Remove triples over the same eShip indices
# iloadout.SetShip takes.

# @native iinventory.AddCommandSection
func _i_add_command(_t, _a: Array) -> Variant:
	player_inv().ships[SHIP_COMMAND_SECTION] = true
	return 0

# @native iinventory.AddTug
func _i_add_tug(_t, _a: Array) -> Variant:
	player_inv().ships[SHIP_TUG] = true
	return 0

# @native iinventory.AddFastAttackShip
func _i_add_fast_attack(_t, _a: Array) -> Variant:
	player_inv().ships[SHIP_FAST_ATTACK] = true
	return 0

# @native iinventory.AddHeavyCorvette
func _i_add_corvette(_t, _a: Array) -> Variant:
	player_inv().ships[SHIP_HEAVY_CORVETTE] = true
	return 0

# @native iinventory.AddStormPetrel
func _i_add_petrel(_t, _a: Array) -> Variant:
	player_inv().ships[SHIP_STORM_PETREL] = true
	return 0

# @native iinventory.GotCommandSection
func _i_got_command(_t, _a: Array) -> Variant:
	return 1 if player_inv().ships.has(SHIP_COMMAND_SECTION) else 0

# @native iinventory.GotTug
func _i_got_tug(_t, _a: Array) -> Variant:
	return 1 if player_inv().ships.has(SHIP_TUG) else 0

# @native iinventory.GotFastAttackShip
func _i_got_fast_attack(_t, _a: Array) -> Variant:
	return 1 if player_inv().ships.has(SHIP_FAST_ATTACK) else 0

# @native iinventory.GotHeavyCorvette
func _i_got_corvette(_t, _a: Array) -> Variant:
	return 1 if player_inv().ships.has(SHIP_HEAVY_CORVETTE) else 0

# @native iinventory.GotStormPetrel
func _i_got_petrel(_t, _a: Array) -> Variant:
	return 1 if player_inv().ships.has(SHIP_STORM_PETREL) else 0

# @native iinventory.RemoveCommandSection
func _i_remove_command(_t, _a: Array) -> Variant:
	return _drop_ship(SHIP_COMMAND_SECTION)

# @native iinventory.RemoveStormPetrel
func _i_remove_petrel(_t, _a: Array) -> Variant:
	return _drop_ship(SHIP_STORM_PETREL)


## Losing the hull you are flying puts you back in the command section, which is
## the one thing the player always has.
func _drop_ship(which: int) -> Variant:
	var inv := player_inv()
	inv.ships.erase(which)
	if loadout.ship == which:
		loadout.ship = SHIP_COMMAND_SECTION
	return 0

# @stub iinventory.FillInventoryListBox
# @stub iinventory.FillAddCargoListBox
# @stub iinventory.FillRecyclingListBox
# @stub iinventory.ResetWindows
func _i_noop(_t, _a: Array) -> Variant:
	# The hangar screens these fill (FcListBox handles, in and out) are the one
	# part of the economy that is pure UI; there is no window to put rows in yet.
	return 0


# ---------------------------------------------------------------- itrade
# A trade is a standing offer at a habitat: "bring me `num_wanted` of X and I
# will give you `num_offered` of Y", repeatable `offers` times.

func _make_trade(a: Array, cargo_class: int) -> PogTrade:
	var tr := PogTrade.new()
	tr.faction = a[0]
	tr.offered_type = int(a[1])
	tr.num_offered = int(a[2])
	tr.cargo_class = cargo_class
	tr.wanted = int(a[3])
	tr.num_wanted = int(a[4])
	tr.offers = int(a[5]) if int(a[5]) > 0 else -1
	return tr

# @native itrade.CreateTradeForCargoType
func _t_create_for_type(_t, a: Array) -> Variant:
	return _make_trade(a, CLASS_TYPE)

# @native itrade.CreateTradeForCargoCategory
func _t_create_for_category(_t, a: Array) -> Variant:
	return _make_trade(a, CLASS_CATEGORY)

# @native itrade.OfferTrade
func _t_offer(_t, a: Array) -> Variant:
	var tr = a[0]
	if tr is PogTrade and not player_inv().trades.has(tr):
		player_inv().trades.append(tr)
	return 0

# @native itrade.RemoveTrade
func _t_remove(_t, a: Array) -> Variant:
	player_inv().trades.erase(a[0])
	return 0

# @native itrade.NumTrades
func _t_num_trades(_t, _a: Array) -> Variant:
	return player_inv().trades.size()

# @native itrade.NthTrade
func _t_nth_trade(_t, a: Array) -> Variant:
	var trades: Array = player_inv().trades
	var i := int(a[0])
	return trades[i] if i >= 0 and i < trades.size() else null

# @native itrade.NumOffers
func _t_num_offers(_t, a: Array) -> Variant:
	var tr = a[0]
	return tr.offers if tr is PogTrade else 0

# @native itrade.Faction
func _t_faction(_t, a: Array) -> Variant:
	var tr = a[0]
	return tr.faction if tr is PogTrade else null

# @native itrade.MetatypeOfTrade
func _t_metatype(_t, a: Array) -> Variant:
	var tr = a[0]
	return tr.cargo_class if tr is PogTrade else CLASS_TYPE

# @native itrade.CanSatisfyTrade
func _t_can_satisfy(_t, a: Array) -> Variant:
	var tr = a[0]
	if not (tr is PogTrade) or tr.offers == 0:
		return 0
	return 1 if _held_matching(tr) >= tr.num_wanted else 0

# @native itrade.PerformTrade
func _t_perform(_t, a: Array) -> Variant:
	var tr = a[0]
	if not PogVM._truthy(_t_can_satisfy(_t, a)):
		return 0
	# Spend the cheapest matching cargo first: with a category trade the player
	# would never hand over the good stuff.
	var inv := player_inv()
	var held: Array = []
	for type in inv.counts:
		if _matches(int(type), tr):
			held.append(int(type))
	held.sort_custom(func(x: int, y: int) -> bool:
		var cx := _cargo(x)
		var cy := _cargo(y)
		return (cx.value if cx != null else 0) < (cy.value if cy != null else 0))

	var owing: int = tr.num_wanted
	for type in held:
		if owing <= 0:
			break
		var take: int = mini(owing, inv.quantity(type))
		inv.take(type, take)
		owing -= take
	inv.add(tr.offered_type, tr.num_offered)
	inv.fresh[tr.offered_type] = true
	if tr.offers > 0:
		tr.offers -= 1
		if tr.offers == 0:
			inv.trades.erase(tr)
	return 1

# @native itrade.Offered
# @native itrade.Wanted
func _t_side(_t, a: Array) -> Variant:
	# Both feed straight into a listbox row, so both are display strings. Which
	# side we describe is decided by the binding, not by the argument.
	var tr = a[0]
	return _label(tr.offered_type, tr.num_offered) if tr is PogTrade else ""

func _t_wanted(_t, a: Array) -> Variant:
	var tr = a[0]
	if not (tr is PogTrade):
		return ""
	match tr.cargo_class:
		CLASS_CATEGORY:
			var cat = categories.get(tr.wanted, null)
			return "%d %s" % [tr.num_wanted,
					_text(cat.name) if cat != null else str(tr.wanted)]
		CLASS_SUPERSET:
			var ss = supersets.get(tr.wanted, null)
			return "%d %s" % [tr.num_wanted,
					_text(ss.name) if ss != null else str(tr.wanted)]
	return _label(tr.wanted, tr.num_wanted)

# @native itrade.JaffsTradeDescription
func _t_jaffs_description(_t, a: Array) -> Variant:
	var tr = a[0]
	if not (tr is PogTrade):
		return ""
	return "Give %s, receive %s." % [_t_wanted(_t, a), _t_side(_t, a)]

# @native itrade.JaffsTradeAdvice
func _t_jaffs_advice(_t, a: Array) -> Variant:
	# Jaffs is the ship's trade computer. The wording is ours; the judgement is
	# the game's own arithmetic, cargo value in against cargo value out.
	var tr = a[0]
	if not (tr is PogTrade):
		return ""
	if not PogVM._truthy(_t_can_satisfy(_t, a)):
		return "You cannot cover this trade."
	var gain := _trade_gain(tr)
	if gain > 0:
		return "Worth taking."
	if gain < 0:
		return "You would be down on the deal."
	return "An even trade."


# ---------------------------------------------------------------- iloadout
# @native iloadout.SetShip
func _l_set_ship(_t, a: Array) -> Variant:
	var which := int(a[0])
	if not player_inv().ships.has(which):
		return 0
	loadout.ship = which
	loadout.turret_fighters = 0
	loadout.remote_fighter = false
	_recheck_cargo_space()
	return 1

# @native iloadout.Ship
func _l_ship(_t, _a: Array) -> Variant:
	return loadout.ship

# @native iloadout.ShipName
func _l_ship_name(_t, a: Array) -> Variant:
	var i := int(a[0])
	return SHIP_NAMES[i] if i >= 0 and i < SHIP_NAMES.size() else ""

# @native iloadout.SetCargo
func _l_set_cargo(_t, a: Array) -> Variant:
	loadout.cargo = int(a[0])
	_recheck_cargo_space()
	return 0

# @native iloadout.Cargo
func _l_cargo(_t, _a: Array) -> Variant:
	return loadout.cargo

# @native iloadout.RegisterAmmoType
func _l_register_ammo(_t, a: Array) -> Variant:
	var name := PogStd._s(a[0])
	if not loadout.ammo_types.has(name):
		loadout.ammo_types.append(name)
	return 0

# @native iloadout.CalculateLoadout
func _l_calculate(_t, a: Array) -> Variant:
	# eLoadout is a preset (the scripts pick one, they never fit systems by
	# hand). We have no mount points to fit against, so what a preset decides
	# here is what the scripts read back out: the loadout and its fighter count.
	loadout.preset = int(a[0])
	loadout.active = true
	loadout.turret_fighters = mini(loadout.desired_turret_fighters,
			player_inv().quantity(_turret_fighter_type()))
	_recheck_cargo_space()
	return 0

# @native iloadout.CurrentLoadout
func _l_current(_t, _a: Array) -> Variant:
	return loadout.preset

# @native iloadout.LoadoutActive
func _l_active(_t, _a: Array) -> Variant:
	return 1 if loadout.active else 0

# @native iloadout.GoodToGo
func _l_good_to_go(_t, _a: Array) -> Variant:
	# What the launch button asks: is there a hull, is it fitted, does the cargo
	# fit in it.
	if not player_inv().ships.has(loadout.ship):
		return 0
	return 0 if loadout.cargo_warning else 1

# @native iloadout.UnusedInternalCargoSlots
func _l_unused_slots(_t, _a: Array) -> Variant:
	return maxi(0, _cargo_slots() - player_inv().total_items())

# @native iloadout.CargoSpaceWarning
func _l_cargo_warning(_t, _a: Array) -> Variant:
	return 1 if loadout.cargo_warning else 0

# @native iloadout.TurretFightersInLoadout
func _l_turret_fighters(_t, _a: Array) -> Variant:
	return loadout.turret_fighters

# @native iloadout.SetDesiredNumberOfTurretFighters
func _l_set_desired_fighters(_t, a: Array) -> Variant:
	loadout.desired_turret_fighters = maxi(0, int(a[0]))
	return 0

# @native iloadout.RemoveTurretFighters
func _l_remove_fighters(_t, _a: Array) -> Variant:
	loadout.turret_fighters = 0
	loadout.desired_turret_fighters = 0
	return 0

# @native iloadout.RemoteFighterMounted
func _l_remote_mounted(_t, _a: Array) -> Variant:
	return 1 if loadout.remote_fighter else 0

# @native iloadout.RemoveRemoteFighter
func _l_remove_remote(_t, _a: Array) -> Variant:
	loadout.remote_fighter = false
	return 0


## Turret fighters are carried as cargo, so the number you can actually mount is
## capped by how many are in the hold.
func _turret_fighter_type() -> int:
	return int(_i_type_from_name(null, ["Cargo_TurretFighter"]))


func _cargo_slots() -> int:
	var i := loadout.ship
	return SHIP_CARGO_SLOTS[i] if i >= 0 and i < SHIP_CARGO_SLOTS.size() else 0


func _recheck_cargo_space() -> void:
	loadout.cargo_warning = player_inv().total_items() > _cargo_slots()


# @stub iloadout.RearmFromJaffs
# @stub iloadout.RearmFromThirdParty
# @stub iloadout.StripShip
# @stub iloadout.StripTurretFighters
# @stub iloadout.LoadoutName
# @stub iloadout.LoadoutDescription
# @stub iloadout.SetManifestWindow
# @stub iloadout.StartCustomisedLoadout
# @stub iloadout.EndCustomisedLoadout
# @stub iloadout.OnCustomiseScreenBack
# @stub iloadout.OnCustomiseScreenSelect
# @stub iloadout.UpdateCustomisedLoadoutTextBox
func _l_noop(_t, _a: Array) -> Variant:
	# Rearming refills magazines and stripping empties mount points; both need
	# the subsim/mount-point model the ships do not have yet, and the rest is the
	# customise screen itself. The scripts pop every one of these return values,
	# so nothing branches on what we hand back.
	return 0


const _BINDINGS := {
	"icargo.create": "_c_create", "icargo.find": "_c_find",
	"icargo.cast": "_c_cast", "icargo.name": "_c_name",
	"icargo.value": "_c_value",
	"icargo.manufacturevalue": "_c_manufacture_value",
	"icargo.canmanufacture": "_c_can_manufacture",
	"icargo.encyclopediaentry": "_c_encyclopedia",
	"icargo.markinsignificant": "_c_mark_insignificant",

	"iinventory.createcargocategory": "_i_create_category",
	"iinventory.createcargosuperset": "_i_create_superset",
	"iinventory.setblueprintsforcargo": "_i_set_blueprints",
	"iinventory.gotblueprints": "_i_got_blueprints",
	"iinventory.add": "_i_add",
	"iinventory.addwithoutmarkingnew": "_i_add_quiet",
	"iinventory.remove": "_i_remove",
	"iinventory.numberofcargotype": "_i_number_of_type",
	"iinventory.numberofcargotypes": "_i_number_of_types",
	"iinventory.cargotypefromname": "_i_type_from_name",
	"iinventory.cargocategoryfromname": "_i_category_from_name",
	"iinventory.cargotypefromcategoryindex": "_i_type_from_index",
	"iinventory.categorycontaining": "_i_category_containing",
	"iinventory.supersetcontaining": "_i_superset_containing",
	"iinventory.numberofrecyclablecargoincategory": "_i_recyclable_in_category",
	"iinventory.numberofrecyclablecargoinsuperset": "_i_recyclable_in_superset",
	"iinventory.recycle": "_i_recycle",
	"iinventory.manufacture": "_i_manufacture",
	"iinventory.manufactureunits": "_i_manufacture_units",
	"iinventory.cancelnewcargoflags": "_i_cancel_new",
	"iinventory.addcommandsection": "_i_add_command",
	"iinventory.addtug": "_i_add_tug",
	"iinventory.addfastattackship": "_i_add_fast_attack",
	"iinventory.addheavycorvette": "_i_add_corvette",
	"iinventory.addstormpetrel": "_i_add_petrel",
	"iinventory.gotcommandsection": "_i_got_command",
	"iinventory.gottug": "_i_got_tug",
	"iinventory.gotfastattackship": "_i_got_fast_attack",
	"iinventory.gotheavycorvette": "_i_got_corvette",
	"iinventory.gotstormpetrel": "_i_got_petrel",
	"iinventory.removecommandsection": "_i_remove_command",
	"iinventory.removestormpetrel": "_i_remove_petrel",
	"iinventory.fillinventorylistbox": "_i_noop",
	"iinventory.filladdcargolistbox": "_i_noop",
	"iinventory.fillrecyclinglistbox": "_i_noop",
	"iinventory.resetwindows": "_i_noop",

	"itrade.createtradeforcargotype": "_t_create_for_type",
	"itrade.createtradeforcargocategory": "_t_create_for_category",
	"itrade.offertrade": "_t_offer", "itrade.removetrade": "_t_remove",
	"itrade.numtrades": "_t_num_trades", "itrade.nthtrade": "_t_nth_trade",
	"itrade.numoffers": "_t_num_offers", "itrade.faction": "_t_faction",
	"itrade.metatypeoftrade": "_t_metatype",
	"itrade.cansatisfytrade": "_t_can_satisfy",
	"itrade.performtrade": "_t_perform",
	"itrade.offered": "_t_side", "itrade.wanted": "_t_wanted",
	"itrade.jaffstradedescription": "_t_jaffs_description",
	"itrade.jaffstradeadvice": "_t_jaffs_advice",

	"iloadout.setship": "_l_set_ship", "iloadout.ship": "_l_ship",
	"iloadout.shipname": "_l_ship_name",
	"iloadout.setcargo": "_l_set_cargo", "iloadout.cargo": "_l_cargo",
	"iloadout.registerammotype": "_l_register_ammo",
	"iloadout.calculateloadout": "_l_calculate",
	"iloadout.currentloadout": "_l_current",
	"iloadout.loadoutactive": "_l_active",
	"iloadout.goodtogo": "_l_good_to_go",
	"iloadout.unusedinternalcargoslots": "_l_unused_slots",
	"iloadout.cargospacewarning": "_l_cargo_warning",
	"iloadout.turretfightersinloadout": "_l_turret_fighters",
	"iloadout.setdesirednumberofturretfighters": "_l_set_desired_fighters",
	"iloadout.removeturretfighters": "_l_remove_fighters",
	"iloadout.remotefightermounted": "_l_remote_mounted",
	"iloadout.removeremotefighter": "_l_remove_remote",
	"iloadout.rearmfromjaffs": "_l_noop",
	"iloadout.rearmfromthirdparty": "_l_noop",
	"iloadout.stripship": "_l_noop",
	"iloadout.stripturretfighters": "_l_noop",
	"iloadout.loadoutname": "_l_noop",
	"iloadout.loadoutdescription": "_l_noop",
	"iloadout.setmanifestwindow": "_l_noop",
	"iloadout.startcustomisedloadout": "_l_noop",
	"iloadout.endcustomisedloadout": "_l_noop",
	"iloadout.oncustomisescreenback": "_l_noop",
	"iloadout.oncustomisescreenselect": "_l_noop",
	"iloadout.updatecustomisedloadouttextbox": "_l_noop",
}
