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

var vm   ## the host: PogRuntime for the ported scripts, PogVM for the oracle
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


func register(v, w: PogWorld) -> void:
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
	# icCargo's engine property map exposes "type": the add-cargo screen reads
	# it back with object.IntProperty (ibasegui SPCargoScreen_OnCargoListBoxSelect),
	# so seed the script-visible property bag the way the engine map would.
	_seed_property(c, "type", c.type)
	return c


## Engine classes carried sPropertyMaps the scripts read through object.*Property.
## The ported natives keep those properties in PogStd's bag, so an engine-backed
## object has to arrive with its map already in it.
func _seed_property(o: Variant, key: String, value: Variant) -> void:
	if vm != null and vm.get("std") != null:
		vm.std._bag(o)[key] = value

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
	# icInventory::RecyclableCargo (@ 0xa5960), same predicate as
	# IsInRecycleScreen: recyclable AND worth something AND not fittable.
	var inv := player_inv()
	var n := 0
	for type in inv.counts:
		var c := _cargo(int(type))
		if c == null or not c.can_recycle or c.recycle_value == 0 \
				or not c.ship_system.is_empty():
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

# --- the hangar list boxes.
#
# These are natives rather than script code because they fill *two* things at
# once: the list box the player sees, and a plain POG list of the icCargo handles
# behind it, which the script keeps in a global and indexes with the row number
# the list box hands back:
#
#   global.CreateList("InventoryScreen_CargoList", 2, v1);
#   iinventory.FillInventoryListBox(v4, !v0, v1);       <- the same v1
#   ...
#   v0 = gui.ListBoxFocusedEntry(v1);                    <- a row number
#   v8 = icargo.Cast(list.GetNth(v7, v0));               <- back to the cargo
#
# So the row order and the list order have to agree, and the native is what makes
# them agree. The columns come from the titles igui.CreateTitledListBox was given:
# item / quantity for the inventory, item / quantity / recycling value for the
# recycling and add-cargo screens.

## The rows of one hangar list, as (cargo, quantity) in declaration order --
## which is the order the original listed things in.
func _held(filter: Callable) -> Array:
	var inv := player_inv()
	var out: Array = []
	for type in type_order:
		var qty := inv.quantity(int(type))
		if qty <= 0:
			continue
		var c := _cargo(int(type))
		if c == null or not c.significant or not filter.call(c):
			continue
		out.append([c, qty])
	return out


## Add the rows to the list box and the handles to the script's parallel list.
##
## The parallel list arrives from the script and we fill it *in place*, which is
## exactly what the original native did: the script's list-typed local is a live
## FcScriptList from the NewObject at the top of the frame (flux @ 0x1003b190,
## case 0x3a), it is passed in empty, and the handles we append to it are the
## handles the script then indexes by row number. Nothing to plant and nothing
## to guess: the caller owns the list, we only fill it.
##
## The listing is HIERARCHICAL (icInventory::FillInventoryListBox @ 0xa3820):
## a superset header row, then per category a category header row, then that
## category's item rows -- and the parallel list gets a 0 at every header
## index, which is what the scripts' `icargo.Cast == null -> beep` branches
## and the header-removal arithmetic in the recycling screen (rows v1-1/v1-2)
## are written against.
##
## Row geometry is the engine's, from icInventory::UpdateInventoryWindow
## (@ 0xa5250) and UpdateCategoryInventoryWindow (@ 0xa5540): item rows are
## 0x226 = 550 wide, 10 tall, with static components at x 32 (w 20, the "new"
## marker), x 52 (w 218, name), x 296 (w 111, quantity) and x 436 (w 109,
## recycle value); category headers are one component at x 12 (w 533) with a
## 20 px text offset, supersets the same but 18 tall and upper-cased.
const ROW_W := 550
const ROW_H := 10

func _row_window(h: int) -> PogUi.PogWindow:
	var w := PogUi.PogWindow.new()
	w.kind = "window"
	w.w = ROW_W
	w.h = h
	return w


func _row_cell(row: PogUi.PogWindow, x: int, wd: int, text: String) -> void:
	var c := PogUi.PogWindow.new()
	c.kind = "static"
	c.x = x
	c.w = wd
	c.h = row.h
	c.title = text
	# CreateInventoryWindowComponent passes SetTextFormatting(false, offset)
	# -- left-aligned (the offsets are baked into our x already)
	c.text_align = 0
	row.children.append(c)


func _fill(a: Array, list_at: int, rows: Array, with_value: bool) -> void:
	var lb = a[0] if a.size() > 0 else null
	var parallel = a[list_at] if a.size() > list_at else null
	if lb is PogUi.PogWindow:
		lb.entries.clear()
		lb.focused_entry = -1
		lb.selected_index = -1
	if parallel is Array:
		(parallel as Array).clear()
	var inv := player_inv()
	# Types are declared grouped by category and categories by superset, so
	# walking the rows in declaration order visits each set contiguously --
	# a header is emitted whenever the set changes.
	var last_ss := -2
	var last_cat := -2
	for r in rows:
		var c: PogCargo = r[0]
		var qty: int = r[1]
		var ss := _superset_of(c.type)
		var cat := _category_of(c.type)
		if lb is PogUi.PogWindow:
			if ss != last_ss and supersets.has(ss):
				var sh := _row_window(18)
				_row_cell(sh, 12, 533, _text(supersets[ss].name).to_upper())
				lb.entries.append(sh)
				if parallel is Array:
					(parallel as Array).append(0)
			if cat != last_cat and categories.has(cat):
				var ch := _row_window(ROW_H)
				_row_cell(ch, 32, 513, _text(categories[cat].name))
				lb.entries.append(ch)
				if parallel is Array:
					(parallel as Array).append(0)
			var row := _row_window(ROW_H)
			if inv.fresh.has(c.type):
				_row_cell(row, 32, 20, "*")
			_row_cell(row, 52, 218, _text(c.name))
			_row_cell(row, 296, 111, str(qty))
			if with_value:
				_row_cell(row, 436, 109, str(c.recycle_value * qty))
			lb.entries.append(row)
		last_ss = ss
		last_cat = cat
		if parallel is Array:
			(parallel as Array).append(c)
	if lb is PogUi.PogWindow and not lb.entries.is_empty():
		lb.focused_entry = 0
	_ui_dirty()


func _ui_dirty() -> void:
	var ui = vm.ui if (vm != null and "ui" in vm) else null
	if ui is PogUi:
		ui.dirty = true

# @native iinventory.FillInventoryListBox
func _i_fill_inventory(_t, a: Array) -> Variant:
	# (listbox, equipment, cargo_list). The screen has two tabs -- Equipment and
	# Cargo -- and the flag picks which. A cargo is "equipment" when it carries a
	# ship-system template, which is exactly what makes it fittable.
	var equipment := PogVM._truthy(a[1]) if a.size() > 1 else false
	var rows := _held(func(c: PogCargo) -> bool:
		return (not c.ship_system.is_empty()) == equipment)
	_fill(a, 2, rows, false)
	return 0

# @element icSPAddCargoScreen
# @native iinventory.FillAddCargoListBox
func _i_fill_add_cargo(_t, a: Array) -> Variant:
	# The loadout screen's "add cargo" list: everything in the hold that is not
	# already fitted, so the player can put it in the pods.
	_fill(a, 1, _held(func(c: PogCargo) -> bool: return true), true)
	return 0

# @native iinventory.FillRecyclingListBox
func _i_fill_recycling(_t, a: Array) -> Variant:
	# icInventory::IsInRecycleScreen (@ 0xa4190): held, significant,
	# recyclable, WORTH something (recycle_value != 0) and NOT a fittable
	# system -- so zero-value blueprints and equipment never list here.
	_fill(a, 1, _held(func(c: PogCargo) -> bool:
		return c.can_recycle and c.recycle_value != 0 \
			and c.ship_system.is_empty()), true)
	return 0

# @native iinventory.ResetWindows
func _i_reset_windows(_t, _a: Array) -> Variant:
	# Called on the way out of every hangar screen and before every re-fill: it
	# drops the cached window handles so the next screen builds fresh ones.
	_ui_dirty()
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
	# The trading screen tests object.StringProperty(trade, "generated_mission")
	# against "": in the engine an unset string property reads as empty, and only
	# iMissionGenerator (imissiongenerator.pog:1534) ever sets it. Seed the empty
	# default so an ordinary trade takes the faction-name branch.
	_seed_property(tr, "generated_mission", "")
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
# icLoadout's ship-template table (ctor @ 0x84210): m_template_ini[5] =
# ini:/sims/ships/player/{comsec, tug, fast_attack, heavy_corvette,
# storm_petrel}, indexed by the same 0..4 the scripts pass SetShip. The
# engine's CalculatePresetLoadout (@ 0x93d90) loads that template and fits its
# mount points out of the player's inventory; we have no per-mount fit model,
# so the launch fits the game's own *_prefitted variant of the template
# instead -- the identical stand-in _fit_systems already applies to the tug.
const SHIP_TEMPLATE_INI := [
	"sims/ships/player/comsec.ini",
	"sims/ships/player/tug.ini",
	"sims/ships/player/fast_attack_prefitted.ini",
	"sims/ships/player/heavy_corvette_prefitted.ini",
	"sims/ships/player/storm_petrel_prefitted.ini",
]

## The hull ini the current loadout selection launches with.
func ship_ini() -> String:
	if loadout.ship >= 0 and loadout.ship < SHIP_TEMPLATE_INI.size():
		return SHIP_TEMPLATE_INI[loadout.ship]
	return ""

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
	# icLoadout::GoodToGo (iwar2 @ 0x85030): spaceworthy means the fitted
	# loadout carries at least one of each of FIVE system classes -- icHeatSink,
	# icDrive, icThrusters, icSensor, icLDSDrive (bits 1|2|4|8|0x10 == 0x1f).
	# We fit the game's own preset templates, and every shipped player template
	# carries all five classes, so with presets the test reduces to "the
	# selected hull is owned". The cargo-space warning is NOT part of GoodToGo
	# -- folding it in refused launch the moment the debug GiveEverything
	# overstuffed the hold.
	return 1 if player_inv().ships.has(loadout.ship) else 0

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


## iloadout::eLoadout, read straight out of the loadout screen. ibasegui builds
## the buttons in the order standard, assault, stealth, ecm (local_13541) and
## pushes them into the "LoadoutButtons" list; SPLoadoutScreen_OnLoadout finds the
## checked one's index and maps 0->1, 1->2, 2->3, 3->4 before calling
## CalculateLoadout. So the enum is one-based, in button order.
##
## The names are limited to eight characters "because of the hangar", says the
## comment above them in text/gui.csv.
const LOADOUT_NAMES := {
	1: "loadoutmenu_standard",
	2: "loadoutmenu_assault",
	3: "loadoutmenu_stealth",
	4: "loadoutmenu_ecm",
}

## The manifest text window, when the loadout screen has given us one.
var manifest_window = null

# @native iloadout.LoadoutName
func _l_loadout_name(_t, a: Array) -> Variant:
	# Returns a *key*: ibasegui wraps it in text.Field(). The screens only ever
	# build four buttons, so 5 and 6 -- which OnLoadout can also produce -- and 0
	# have no shipped name; "custom" is the only other name in the table, and it
	# is what StartCustomisedLoadout leaves behind.
	return LOADOUT_NAMES.get(int(a[0]), "loadoutmenu_custom")

# @native iloadout.LoadoutDescription
func _l_loadout_description(_t, _a: Array) -> Variant:
	# icLoadout::LoadoutDescription (iwar2 @ 0x85390): an HTML page describing
	# the LOADOUT's own subsim array -- the SELECTED template's fit (filled by
	# CalculatePresetLoadout), not the flying ship's -- one localised section
	# head per kind: customise_propulsion / _offensive / _defensive / _general
	# (+ ship upgrades / armaments / turret fighter / cargo when non-empty),
	# with GenerateSystemDescription (@ 0x987f0) sorting each subsim by engine
	# class. Rendered as plain text here; the class->section sort below is
	# checked against the original's own comsec manifest (fuel cell, heat-sink,
	# thrusters, drive, LDS, accumulators = PROPULSION; quad light PBC =
	# OFFENSIVE; defense LDA = DEFENSIVE; sensors, CPU, autorepair = GENERAL).
	var ini := ship_ini()
	var fitted: ShipSystems = null
	if game != null and "player_ship_ini" in game and ini == game.player_ship_ini \
			and game.get("sys") != null:
		fitted = game.sys                 # describing the hull we are flying
	elif not ini.is_empty():
		if ini == "sims/ships/player/tug.ini":
			ini = "sims/ships/player/tug_prefitted.ini"  # _fit_systems's remap
		fitted = ShipSystems.for_ship(ini)
	var name: String = SHIP_NAMES[loadout.ship] \
			if loadout.ship >= 0 and loadout.ship < SHIP_NAMES.size() else "?"
	var lines: Array[String] = [name.to_upper(), ""]
	if fitted == null or fitted.hull_max <= 0.0:
		lines.append("No ship fitted.")
		return "\n".join(lines)
	var sections := {}
	for s in fitted.systems:
		if float(s.get("hp_max", 0)) <= 0.0:
			continue                      # an empty mount socket, not a device
		var sec := _manifest_section(s)
		if not sections.has(sec):
			sections[sec] = []
		sections[sec].append(
				ShipSystems.display_name(String(s.get("name", ""))))
	for pair in [["PROPULSION", "customise_propulsion"],
			["OFFENSIVE", "customise_offensive"],
			["DEFENSIVE", "customise_defensive"],
			["GENERAL", "customise_general"],
			["ARMAMENTS", "customise_armaments"]]:
		var items: Array = sections.get(pair[0], [])
		if items.is_empty():
			continue
		lines.append(_text_or(pair[1], pair[0]))
		for dn in items:
			lines.append("  " + str(dn))
		lines.append("")
	var slots: int = int(_l_unused_slots(null, []))
	lines.append(_text_or("manifest_ship_cargo", "SHIP CARGO"))
	lines.append("  %d of %d slots free" % [slots, _cargo_slots()])
	if loadout.turret_fighters > 0:
		lines.append(_text_or("customise_turretfighter", "TURRET FIGHTER"))
		lines.append("  %d fitted" % loadout.turret_fighters)
	return "\n".join(lines)


## GenerateSystemDescription's class sort, in our terms. The engine walks a
## chain of IsDerivedFrom tests against the FcClass registry; we test the
## recovered class/group tags instead.
func _manifest_section(s: Dictionary) -> String:
	var cls := String(s.get("class", ""))
	if cls in ["icPlayerLDA", "icAILDA", "icAggressorShield"]:
		return "DEFENSIVE"
	if cls in ["icMissileMagazine", "icCounterMeasureMagazine", "icMagazine"]:
		return "ARMAMENTS"
	match String(s.get("group", "")):
		"DRV", "THR", "LDS", "CAP", "EPS":
			return "PROPULSION"
		"WEP":
			return "OFFENSIVE"
		"SEN", "CPU":
			return "GENERAL"
	if cls == "icHeatSink":
		return "PROPULSION"
	return "GENERAL"                      # autorepair and the unclassified rest


## A text field when the tables carry it, our fallback label when not.
func _text_or(key: String, fallback: String) -> String:
	var t := _text(key)
	return fallback if t == key else t.to_upper()

# @native iloadout.SetManifestWindow
func _l_set_manifest_window(_t, a: Array) -> Variant:
	# The loadout and manifest screens hand us the text window they want the fit
	# written into, and then never write it themselves.
	manifest_window = a[0] if a.size() > 0 else null
	if manifest_window is PogUi.PogWindow:
		manifest_window.text = PogStd._s(_l_loadout_description(null, []))
		_ui_dirty()
	return 0


## The subsims of a sim: the player's are main.sys, an AI ship's are its own.
func _systems_of(s) -> ShipSystems:
	if s == null:
		return null
	if s.is_player:
		return game.sys if (game != null and "sys" in game) else null
	if s.node != null and is_instance_valid(s.node) and "sys" in s.node:
		return s.node.sys
	return null


## Rearm: put a ship's subsims back to `frac` of their hit points, and its hull
## with them. iiShipSystem hit points go negative and are still repairable, so a
## rearm is a clamp back up, not a heal from zero.
func _rearm(s, frac: float) -> void:
	var sys := _systems_of(s)
	if sys == null:
		return
	sys.hull = maxf(sys.hull, sys.hull_max * frac)
	for d in sys.systems:
		var hp: float = float(d.get("hp_max", 0))
		if hp <= 0.0:
			continue
		d["hp"] = maxf(float(d.get("hp", 0)), hp * frac)
		d["destroyed"] = false
		if d.has("energy"):
			d["energy"] = d.get("capacity", 0)
		if d.has("defends"):
			d["defends"] = d.get("defend_count", 0)

# @native iloadout.RearmFromJaffs
func _l_rearm_jaffs(_t, _a: Array) -> Variant:
	# Jaffs rearms you at the base, on the way out of the hangar: a full refit.
	_rearm(world.player_sim() if world != null else null, 1.0)
	return 0

# @native iloadout.RearmFromThirdParty
func _l_rearm_third_party(_t, a: Array) -> Variant:
	# RearmFromThirdParty(ship, fraction): somebody else's hangar, and they are
	# not as generous. Every shipped call passes 1.0.
	_rearm(world._as_sim(a[0]), float(a[1]) if a.size() > 1 else 1.0)
	return 0

# @native iloadout.StripShip
# @native iloadout.StripTurretFighters
func _l_strip(_t, a: Array) -> Variant:
	# istartsystem strips the hulls it hands the player between acts, so they
	# arrive empty and have to be refitted. Stripping empties the mount points:
	# an empty mount has hit_points 0 and cannot be damaged, which is exactly what
	# ship_systems.gd already models, so the devices simply go.
	var s = world._as_sim(a[0])
	loadout.turret_fighters = 0
	loadout.desired_turret_fighters = 0
	var sys := _systems_of(s)
	if sys == null:
		return 0
	var keep: Array = []
	for d in sys.systems:
		if float(d.get("hp_max", 0)) <= 0.0:
			keep.append(d)          # the mount point itself stays; the device goes
	sys.systems = keep
	sys.ldas.clear()
	return 0

# ------------------------------------------------------- iloadout: customise
# @element icSPCustomiseScreen
#
# The customise screen. The POG side (s_p_customise_screen) builds the shell --
# shady bar, splitter, text window -- and hands the splitter and text window to
# iloadout.StartCustomisedLoadout; everything inside is icLoadout's C++ mode
# machine, NOT drag-and-drop: the engine builds a list box wired to
# "iBaseGUI.SPCustomiseScreen_OnSelect" (UpdateCustomisationSplitterWindow @
# 0x10092170), fills it per mode (CreateListBoxEntries @ 0x100867d0 dispatches
# through m_create_options_functions on eCustomisationMode), and drills down:
#
#   ShipOverview (mode 0)  four category rows -- the localisation keys
#                          customise_propulsion / _offensive / _defensive /
#                          _general (FUN_100840f0), plus SHIP UPGRADES when the
#                          hull INI has [Modifiers] templates
#   CategoryView (mode 1)  the ship's subsims in that category
#                          (SubsimCategory @ 0x100927e0 on the subsim type)
#   deeper modes           per-subsim-type fitting: SystemView, UpgradeView,
#                          CPU options/programs, missile launcher/magazines,
#                          pylons, turret fighters, dock-on arms
#
# Back pops one mode off a history stack and returns whether it consumed the
# press (OnCustomiseScreenBack @ 0x10090c50: depth > 1 -> pop, true; else
# false and the POG closes the screen). The text window shows per-focused-row
# copy (the customise_*instructions_* keys), refreshed by the POG's 0.1s task.
#
# What is reproduced here: the mode stack, the four extracted category rows and
# their instruction keys, the drill-down, and Back's consume-or-close contract.
# DELIBERATE DIVERGENCE: the remaster has no subsim/mount-point model (systems
# are ShipSystems' flat INI list), so the deep per-type modes collapse into one
# generic SystemView -- pick a fitted system, then fit / swap / remove against
# the equipment cargo in the inventory. Category membership approximates
# SubsimCategory from ShipSystems groups; ship upgrades, CPU programs, missile
# magazines, pylon hardpoints and the chain/salvo fire-mode row need the mount
# model and are omitted.

const CUST_SHIP := 0
const CUST_CATEGORY := 1
const CUST_SYSTEM := 2

const CUST_ROW_BACK := -100          ## the engine's AddCustomisedBackButton id

## FUN_100840f0's four names, in eCustomisationCategory order.
const CUST_CATEGORY_KEYS := [
	"customise_propulsion", "customise_offensive",
	"customise_defensive", "customise_general",
]

## text/gui.csv rows 693-713: three keys per category, shown while the row has
## the focus (UpdateCustomisedLoadoutTextBoxForShipOverviewMode @ 0x10086c50).
const CUST_INSTRUCTION_KEYS := [
	["customise_propulsioninstructions_1", "customise_propulsioninstructions_2",
			"customise_propulsioninstructions_3"],
	["customise_offensiveinstructions_1", "customise_offensiveinstructions_2",
			"customise_offensiveinstructions_3"],
	["customise_defensiveinstructions_1", "customise_defensiveinstructions_2",
			"customise_defensiveinstructions_3"],
	["customise_generalinstructions_1", "customise_generalinstructions_2",
			"customise_generalinstructions_3"],
]

## The customise session. Empty dictionary = not customising.
var cust: Dictionary = {}


## The customisation list box is ours to make, so we need the PogUi the host is
## using. PogRuntime names it; PogVM does not (it only knows the natives that
## registered against it), so reach it through one of them -- otherwise the
## screen builds under the port and comes up empty under the bytecode.
func _cust_ui() -> PogUi:
	if vm == null:
		return null
	if vm.get("ui") != null:
		return vm.ui
	var c: Callable = vm.natives.get("gui.pushscreen", Callable())
	return (c.get_object() if c.is_valid() else null) as PogUi


func _cust_sys() -> ShipSystems:
	return _systems_of(world.player_sim() if world != null else null)


## "propulsion and power systems" / "weapon" / "defensive" / "other" -- an
## approximation of SubsimCategory (0x100927e0), which keyed off subsim type
## flags we do not model. The propulsion instructions say "propulsion and power
## systems", so EPS/CAP ride with DRV/THR/LDS.
func _cust_category_of(sysd: Dictionary) -> int:
	var cls := String(sysd.get("class", ""))
	if sysd.has("lda") or "LDA" in cls or "CounterMeasure" in cls:
		return 2
	match String(sysd.get("group", "")):
		"DRV", "THR", "LDS", "CAP", "EPS":
			return 0
		"WEP":
			return 1
	return 3


# @native iloadout.StartCustomisedLoadout
func _l_start_customise(_t, a: Array) -> Variant:
	var ui := _cust_ui()
	if ui == null:
		return 0
	# The splitter (a[0]) held the breadcrumb trail of mode titles; we fold the
	# trail into the list box title instead. The text window (a[1]) is real.
	var lb := ui._new_window("listbox", [], 0)
	# The engine wires the list box's Select and mouse-up to the POG's
	# SPCustomiseScreen_OnSelect and its cancel slot to the back handler
	# (UpdateCustomisationSplitterWindow, strings @ 1015f2b4 / 1015f28c).
	lb.overrides[PogUi.IN_SELECT] = "iBaseGUI.SPCustomiseScreen_OnSelect"
	lb.overrides[PogUi.IN_MOUSE_UP] = "iBaseGUI.SPCustomiseScreen_OnSelect"
	cust = {
		"listbox": lb,
		"textbox": a[1] if a.size() > 1 else null,
		"stack": [{"mode": CUST_SHIP, "param": -1,
				"title": _text(SHIP_NAMES[loadout.ship] if loadout.ship >= 0
						and loadout.ship < SHIP_NAMES.size() else "")}],
		"rows": [],
		"last_focus": -2,
	}
	_cust_rebuild()
	ui.focused = lb
	if lb.screen != null:
		lb.screen.focus = lb
	return 0


# @native iloadout.EndCustomisedLoadout
func _l_end_customise(_t, _a: Array) -> Variant:
	var ui := _cust_ui()
	if ui != null and cust.has("listbox"):
		ui._delete_window(null, [cust["listbox"]])
	cust = {}
	return 0


# @native iloadout.OnCustomiseScreenBack
func _l_customise_back(_t, _a: Array) -> Variant:
	# OnCustomiseScreenBack @ 0x10090c50: deeper than the ship overview -> pop
	# one mode and report it consumed; at the root report false so the POG's
	# SPCustomiseScreen_OnBackButton closes the screen.
	if cust.is_empty():
		return 0
	var stack: Array = cust["stack"]
	if stack.size() <= 1:
		return 0
	stack.pop_back()
	cust["last_focus"] = -2
	_cust_rebuild()
	return 1


# @native iloadout.OnCustomiseScreenSelect
func _l_customise_select(_t, _a: Array) -> Variant:
	if cust.is_empty():
		return 0
	var lb: PogUi.PogWindow = cust["listbox"]
	var rows: Array = cust["rows"]
	var at: int = lb.focused_entry
	if at < 0 or at >= rows.size():
		return 0
	var id: int = rows[at]
	if id == CUST_ROW_BACK:
		return _l_customise_back(_t, [])
	var stack: Array = cust["stack"]
	match int(stack[-1]["mode"]):
		CUST_SHIP:
			stack.append({"mode": CUST_CATEGORY, "param": id,
					"title": _text(CUST_CATEGORY_KEYS[id])})
		CUST_CATEGORY:
			var sys := _cust_sys()
			if sys == null or id < 0 or id >= sys.systems.size():
				return 0
			stack.append({"mode": CUST_SYSTEM, "param": id,
					"title": _cust_slot_name(sys.systems[id])})
		CUST_SYSTEM:
			_cust_fit(int(stack[-1]["param"]), id)
	cust["last_focus"] = -2
	_cust_rebuild()
	return 0


# @native iloadout.UpdateCustomisedLoadoutTextBox
func _l_customise_update(_t, _a: Array) -> Variant:
	# The POG polls this every 0.1s; only a focus change redraws the copy
	# (UpdateCustomisedLoadoutTextBox @ 0x10086820 keeps m_last_focus the same way).
	if cust.is_empty():
		return 0
	var lb: PogUi.PogWindow = cust["listbox"]
	if lb.focused_entry == int(cust["last_focus"]):
		return 0
	cust["last_focus"] = lb.focused_entry
	var tw = cust["textbox"]
	if tw is PogUi.PogWindow:
		tw.text = _cust_copy_for(lb.focused_entry)
		_ui_dirty()
	return 0


## Rebuild the list box for the mode on top of the stack.
func _cust_rebuild() -> void:
	var lb: PogUi.PogWindow = cust["listbox"]
	var rows: Array = cust["rows"]
	var stack: Array = cust["stack"]
	lb.entries.clear()
	rows.clear()
	var trail: Array[String] = []
	for e in stack:
		trail.append(String(e["title"]).to_upper())
	lb.title = " > ".join(trail)
	match int(stack[-1]["mode"]):
		CUST_SHIP:
			for i in CUST_CATEGORY_KEYS.size():
				lb.entries.append(_text(CUST_CATEGORY_KEYS[i]))
				rows.append(i)
		CUST_CATEGORY:
			var cat: int = int(stack[-1]["param"])
			var sys := _cust_sys()
			if sys != null:
				for i in sys.systems.size():
					var d: Dictionary = sys.systems[i]
					if _cust_category_of(d) != cat:
						continue
					lb.entries.append(_cust_slot_label(d))
					rows.append(i)
		CUST_SYSTEM:
			var idx: int = int(stack[-1]["param"])
			for type in _cust_candidates(idx):
				var c := _cargo(type)
				lb.entries.append("%-30s x%d" % [_text(c.name),
						player_inv().quantity(type)])
				rows.append(type)
			if _cust_removable(idx):
				# "[Empty]" -- fitting nothing is how the slot is cleared.
				lb.entries.append(_text("customise_empty"))
				rows.append(-3)
	if int(stack[-1]["mode"]) != CUST_SHIP:
		# AddCustomisedBackButton: every non-root mode ends with a BACK row.
		lb.entries.append(_text("mp_back_button"))
		rows.append(CUST_ROW_BACK)
	lb.focused_entry = 0 if not lb.entries.is_empty() else -1
	lb.selected_index = -1
	cust["last_focus"] = -2
	_l_customise_update(null, [])
	_ui_dirty()


func _cust_slot_name(d: Dictionary) -> String:
	if float(d.get("hp_max", 0)) <= 0.0:
		return _text("customise_emptyslot").rstrip(",")
	return String(d.get("name", "?"))


func _cust_slot_label(d: Dictionary) -> String:
	var name := _cust_slot_name(d)
	if float(d.get("hp_max", 0)) <= 0.0:
		return "%-30s %s" % [name, _text("customise_nosystemmounted")]
	var hp := float(d.get("hp", 0)) / maxf(float(d.get("hp_max", 1)), 1.0)
	return "%-30s %3d%%" % [name, roundi(100.0 * hp)]


## Which inventory cargo could go into slot `idx`: equipment (a ship_system
## template) whose class maps to the same customisation category as the slot.
func _cust_candidates(idx: int) -> Array[int]:
	var out: Array[int] = []
	var sys := _cust_sys()
	if sys == null or idx < 0 or idx >= sys.systems.size():
		return out
	var slot: Dictionary = sys.systems[idx]
	var slot_cat := _cust_category_of(slot)
	var inv := player_inv()
	for type in type_order:
		if inv.quantity(int(type)) <= 0:
			continue
		var c := _cargo(int(type))
		if c == null or c.ship_system.is_empty():
			continue
		var ini := ShipSystems.read_ini(c.ship_system)
		var probe := {
			"class": String(ini.get("class", "")),
			"group": sys._group_of(String(ini.get("class", "")),
					ini.get("props", {})),
		}
		if _cust_category_of(probe) == slot_cat:
			out.append(int(type))
	return out


func _cust_removable(idx: int) -> bool:
	var sys := _cust_sys()
	if sys == null or idx < 0 or idx >= sys.systems.size():
		return false
	var d: Dictionary = sys.systems[idx]
	return float(d.get("hp_max", 0)) > 0.0 \
			and _type_for_template(String(d.get("template", ""))) >= 0


## The cargo type whose ship-system template built this device, if any -- what
## lets a swapped-out system go back into the hold.
func _type_for_template(tpl: String) -> int:
	if tpl.is_empty():
		return -1
	var want := _tpl_norm(tpl)
	for type in type_order:
		var c := _cargo(int(type))
		if c != null and not c.ship_system.is_empty() \
				and _tpl_norm(c.ship_system) == want:
			return int(type)
	return -1


static func _tpl_norm(tpl: String) -> String:
	return tpl.to_lower().trim_prefix("ini:").trim_prefix("/") \
			.trim_suffix(".ini").replace("\\", "/")


## Fit inventory cargo `type` into systems[idx] (or clear the slot: type -3).
## The old device goes back to the hold when a cargo type maps to its template.
func _cust_fit(idx: int, type: int) -> void:
	var sys := _cust_sys()
	if sys == null or idx < 0 or idx >= sys.systems.size():
		return
	var old: Dictionary = sys.systems[idx]
	var null_name := String(old.get("null", ""))
	var group := String(old.get("group", ""))
	if type >= 0:
		var c := _cargo(type)
		if c == null or c.ship_system.is_empty() \
				or not player_inv().take(type, 1):
			return
		_cust_unmount(sys, idx)
		sys._mount(c.ship_system, null_name)
		var fitted: Dictionary = sys.systems.pop_back()
		sys.systems.insert(idx, fitted)
	elif type == -3:
		if not _cust_removable(idx):
			return
		_cust_unmount(sys, idx)
		sys.systems.insert(idx, {
			# an empty socket: hp_max 0 means it cannot be damaged and
			# ship_systems.gd's simulate leaves it alone, same as a stripped hull
			"name": _text("customise_emptyslot").rstrip(","), "class": "icMountPoint",
			"template": "", "null": null_name, "group": group,
			"hp": 0.0, "hp_max": 0.0, "power": 0.0, "heat_rate": 0.0,
			"repair_rate": 0.0, "min_eff": 0.0, "pos": Vector3.ZERO,
			"efficiency": 1.0, "usage": 0.0, "destroyed": false,
			"underpowered": false,
		})
	_recheck_cargo_space()
	if manifest_window is PogUi.PogWindow:
		manifest_window.text = PogStd._s(_l_loadout_description(null, []))
	_ui_dirty()


## Take systems[idx] out, returning the device to the hold when it maps back
## to a cargo type.
func _cust_unmount(sys: ShipSystems, idx: int) -> void:
	var old: Dictionary = sys.systems[idx]
	if float(old.get("hp_max", 0)) > 0.0:
		var t := _type_for_template(String(old.get("template", "")))
		if t >= 0:
			player_inv().add(t, 1)
	sys.systems.remove_at(idx)
	sys.ldas.erase(old)


## The text-window copy for the focused row.
func _cust_copy_for(at: int) -> String:
	var rows: Array = cust["rows"]
	var stack: Array = cust["stack"]
	if at < 0 or at >= rows.size():
		return ""
	var id: int = rows[at]
	if id == CUST_ROW_BACK:
		return ""
	match int(stack[-1]["mode"]):
		CUST_SHIP:
			var lines: Array[String] = []
			for key in CUST_INSTRUCTION_KEYS[id]:
				var s := _text(String(key))
				if not s.is_empty() and s != String(key):
					lines.append(s)
			return " ".join(lines)
		CUST_CATEGORY:
			var sys := _cust_sys()
			if sys == null:
				return ""
			var d: Dictionary = sys.systems[id]
			if float(d.get("hp_max", 0)) <= 0.0:
				return _text("customise_nosystemmounted")
			return "%s\n%s%.0f" % [String(d.get("name", "")),
					_text("customise_maxpowerusage"), float(d.get("power", 0))]
		CUST_SYSTEM:
			if id == -3:
				return _text("customise_nosystemmounted")
			var c := _cargo(id)
			if c == null:
				return ""
			return "%s\nValue: %d" % [_text(c.name), c.value]
	return ""


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
	"iinventory.fillinventorylistbox": "_i_fill_inventory",
	"iinventory.filladdcargolistbox": "_i_fill_add_cargo",
	"iinventory.fillrecyclinglistbox": "_i_fill_recycling",
	"iinventory.resetwindows": "_i_reset_windows",

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
	"iloadout.rearmfromjaffs": "_l_rearm_jaffs",
	"iloadout.rearmfromthirdparty": "_l_rearm_third_party",
	"iloadout.stripship": "_l_strip",
	"iloadout.stripturretfighters": "_l_strip",
	"iloadout.loadoutname": "_l_loadout_name",
	"iloadout.loadoutdescription": "_l_loadout_description",
	"iloadout.setmanifestwindow": "_l_set_manifest_window",
	"iloadout.startcustomisedloadout": "_l_start_customise",
	"iloadout.endcustomisedloadout": "_l_end_customise",
	"iloadout.oncustomisescreenback": "_l_customise_back",
	"iloadout.oncustomisescreenselect": "_l_customise_select",
	"iloadout.updatecustomisedloadouttextbox": "_l_customise_update",
}
