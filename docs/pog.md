# Porting the game's own code

IW2's *content* is not in the engine. The missions, the conversations, the AI
orders, trading, the mission generator, the base screens -- all of it is POG
script, compiled to a stack-machine bytecode and shipped in `resource.zip` as
114 packages. The engine binaries only provide the ~42 **native packages** those
scripts call into (`iship`, `isim`, `iai`, `idirector`, `icomms`...).

So the remaster does not re-author missions. It **ports** them.

```
resource.zip/packages/*.pkg          the original compiled missions
        |
        |  tools/iw2/pogdec.py       bytecode -> AST (expressions + control flow)
        v
   an actual program
        |
        |  tools/iw2/pogport.py      AST -> GDScript
        v
game/scripts/pog/gen/*.gd            the missions, as native Godot code
        |
        |  game/scripts/pog/natives/ the ~42 engine packages: our systems
        v
   the Godot game
```

There is no interpreter in the shipping path, no bytecode, and no
`resource.zip` at runtime. A mission is ordinary GDScript calling ordinary
Godot systems.

## Where it stands

```powershell
python -m tools.iw2.pogdec --all data/pogsrc     # readable POG source
python -m tools.iw2.pogport                      # the GDScript port
godot --headless --path game --script res://scripts/pog/portcheck.gd
```

    114/114 packages compile
    2878/2878 functions provably agree with their bytecode (pogverify: 100%,
               MISSING 0, INVENTED 0)
    2661/2878 ported as structured code (92.5%)
    217 fall back to the basic-block dispatch form (irreducible, but exact)

Run it (START NEW GAME on the front end boots the campaign; the old
`--pogplay` skip-the-menu flag is gone -- it hijacked every in-session scene
reload, turning DEBUG START into a fresh campaign):

```powershell
godot --path game -- --port --pogtrace
```

`--pogtrace` is worth knowing about: `DebugSkip` (opcode 0x45) made `debug`
statements free in release by jumping over them, and that flag is our
`FcDeveloperMode`. Turn it on and the original developers' narration comes out
-- **including their own error handlers**, which is the best diagnostic in the
project. It is how we found that `isim.Type` must return the engine's
`IeSimType` bit flag rather than a class name.

## The VM is the oracle, not the runtime

`game/scripts/pog/vm.gd` still exists, and `--pog` still runs the campaign on
it. That is deliberate: it lets us run the *same* mission both ways and diff
them. The VM is a test instrument; the port is the game.

## How POG maps onto Godot

A POG task is a coroutine, and a GDScript function with an `await` in it already
is one, so most of this is a change of spelling:

| POG | ported |
|---|---|
| `task.Sleep(task.Current(), 2.0)` | `await _pog_wait(2.0)` |
| `EndTimeslice` | `await _pog_frame()` |
| `start f(a, b)` | `_pog_spawn(f.bind(a, b))` |
| `igame.PlayMovie(x)` | `await _pog_movie(x)` (it blocks the script) |

Three things needed real answers rather than fudges:

- **POG has no null and no bool.** A script asks "is this handle null?" by
  comparing it against `0` -- legal on a 32-bit word machine, a type error in
  GDScript. `x == 0` ports to `_pog_is_null(x)`, which leaves `count == 0`
  meaning exactly what it says.
- **The floating origin.** The player sits at the scene origin, its true
  position lives in `main.px/py/pz`, AI ships are positioned *relative to the
  player*, and static `main.objects[]` records are *absolute*. POG knows none of
  this, so `PogSim.abs_pos()/set_abs_pos()` converts per object kind and every
  native works in absolute metres.
- **Hostility.** POG decides who shoots whom with `ifaction`'s feelings matrix
  (a float in [-1,+1]; `SetFeeling` is the hottest game-facing native in the
  campaign at 5,529 call sites). Our `AiShip` decided it with a
  `behavior == "attack"` string. `isim.SetFaction` now derives the one from the
  other.

Ships are spawned by INI path -- `sim.Create("ini:/sims/ships/utility/flitter",
name)` -- and `data/json/ships.json` has all 148 definitions, so a POG-spawned
ship gets its *authored* stats rather than placeholder numbers.

## How the decompiler recovers control flow

The compiler emits reducible, source-ordered code, so the shapes read back:

```
while:     L: <cond> GoFalse X ; <body> ; Goto L ; X:
pre-tested Goto COND ; H: <body> ; COND: <cond> ; GoTrue H
do/while:  H: <body> ; <cond> ; GoTrue H          (the test IS the back edge)
if/else:   <cond> GoFalse E ; <then> ; Goto X ; E: <else> ; X:
every:     L: EndTimeslice ; TimedJump SKIP,slot,secs ; <body> ; SKIP: Goto L
```

Loops come from **back edges**, which is exact rather than a heuristic. The one
subtlety that mattered: a loop's extent is *not* its last back edge -- a nested
loop's own back edge can sit after the outer loop's, so bounding the outer loop
by its latch truncates it and it is then never recognised at all. Extents are
grown to fixpoint over any loop that begins inside them.

The last big win was noticing that most of what remained were jumps to the
function's shared exit (scope cleanup and a `Return`). That is a `return`, not a
goto -- and it took the goto count from 1146 to 135.

Whatever still does not fit a known shape is emitted as a labelled `goto` rather
than guessed at, so the output never lies about the original.

### The coverage check, and keeping its books honest

Skipping the cursor forward over a switch's case bodies is only sound if every
body is inlined back at the branch that selects it; when inlining fails the code
is simply *gone*, and the output looks perfectly clean while missing statements.
So after structuring, every reachable instruction must have been consumed, or
the function falls back to the dispatch form (`_lost_code` in pogdec).

When that check landed it ballooned the dispatch count from 223 to 1849 -- not
because structuring was that broken, but because the books were not: an
instruction that is consumed *structurally* (a case arm's trailing `Goto` that
became the fall into the shared exit, the `Return` a `_epilogue` folded into a
`return` statement, a loop latch that became the `while` itself, the
jump-over-the-else that became the `if/else`) was emitted but never marked.
Marking exactly those -- and only on success: `_epilogue`/`_inline` simulate
speculatively, so their marks merge in only when the result is actually used --
brought the count to 217 with the check fully intact.

The check also caught one recogniser that really was wrong: a then-branch
ending in `Goto exit` with a value still on its stack is an early
`return <value>`, not a jump over an else; treating it as if/else silently
dropped the value (and any call inside it). The if/else shape now requires the
then-part to end value-clean, or the join to be the shared exit consuming that
value.

Two facts about the dispatch form, for when you read one: a block that jumps to
the shared exit with values on its stack folds the exit in as `return <value>`
(each arm carries a *different* value, so `_pc = exit` cannot express it), and a
compare ladder's selector carries across the fall-through edge like any other
mid-expression value. Both matter for the switch-over-string-table functions
(`iutilities.FromAllegianceEnum` and friends) that used to lose their string
literals in dispatch form.

## The base screens run the original scripts

A screen is named by its C++ class, and the engine's screen object **called back
into POG to build itself** -- `icSPHangarScreen`'s constructor runs
`iBaseGUI.SPHangarScreen`. That convention resolves 33 of the 48 screens the
campaign names (`docs/original.md` 8a), so `gui.SetScreen`/`PushScreen`/
`OverlayScreen` now do what the engine did: look the builder up and run it.

The hangar, loadout, manifest, inventory, recycling, manufacturing, comms, inbox,
archive, encyclopaedia and statistics screens, and the whole PDA, are therefore
the original code. `natives/ui.gd` holds the widget tree and runs the callbacks;
`base_screens.gd` draws it and feeds it input. We do **not** rebuild the original
skin (`igui.CreateFancyButton` splices a 38-argument nine-patch atlas onto every
control) -- the rows, their order and the POG function behind each are faithful;
the amber-on-black is ours, to match `menu.gd`.

The trading screen is script-driven too (`iBaseGUI.SPTradingScreen`), and it is
the one that proves the object model below: it builds itself out of a POG *list*
of widgets.

## `NewObject`: POG's three object types, and the fixup that hides them

POG has three heap types -- `FcScriptString`, `FcScriptList`, `FcScriptSet` --
and one opcode that makes them: `NewObject` (`0x3a`). It pushes a **live, empty**
object; `FcScriptTask::Execute` (`flux.dll @ 0x1003b190`) calls
`FiScriptObject::Create(type)` (`flux.dll @ 0x1003a960`), which switches on the
enum: 1 -> string, 2 -> list, 3 -> set. A declaration `list l;` is compiled to
`NewObject FcScriptList; Store slot`, at the top of the frame.

The operand reads **0 in every shipped package** because it is a link-time fixup,
not data: the `OIMP` chunks name the type and list the sites, and the loader
(`flux.dll @ 0x1003482c`) patches each one with
`FiScriptObject::TypeFromName(name)`. Both the decompiler and the VM used to take
that 0 at face value and push `null`. That is invisible in 90% of the code and
fatal in the rest, because **a native that is handed a POG list fills the caller's
list in place**:

```
v1 = NewObject FcScriptList          # the script's own list
iinventory.FillInventoryListBox(listbox, equipment, v1)
...
v8 = icargo.Cast(list.GetNth(v1, gui.ListBoxFocusedEntry(listbox)))
```

The native fills *both* the list box and `v1`, and the two orders must agree --
that is how a row number becomes a cargo handle (`docs/original.md` 8a). The
returned-widget pattern is the same idea outward: `igui.CreateGreyBoxStyleScreen`
returns a list and `SPTradingScreen` pulls its four widgets back out with
`list.Head`. With `null` in the local, nothing is filled and nothing comes back.

Now: `pogdis.parse_pkg` reads OIMP into `obj_sites` (keyed by the `NewObject`
offset), `pogdec` emits a `New(kind)` node, `pogport` renders it as a fresh
`[]` (list *and* set -- `natives/std.gd` implements both over `Array`) or `""`
(string), `pogexport` writes the sites into `data/pog/*.json`, and the VM reads
them. Both hosts now build a real object, so the two shims that stood in for it
(`natives/economy.gd` planting the parallel list under its known global name, and
`natives/ui.gd` rewiring the trading screen by hand) are **gone**.

pogverify is unchanged by the fix: 2878/2878 functions agree, MISSING 0,
INVENTED 0, 217 dispatch. A `New` is not a call and not a string, so it adds
nothing the differential test counts -- what it changes is what the code *does*.

Two things the fix exposed, both latent behind the null lists:

* `gui.RepositionWindow` is `(window, parent, x, y)` -- it reparents as well as
  moves. `igui.ArrangeWindowsVertically` (igui entry 17714) walks a list and
  passes a *running* offset as the last argument, and `igui.CreateMenu` passes
  the shady bar it just made as the second. Those loops walk a list, so they had
  never run.
* `iloadout.StartCustomisedLoadout` builds its list box through `vm.ui`, which
  only `PogRuntime` has -- under the VM the customise screen came up without its
  rows. It now finds the `PogUi` through the natives it registered.

## Extraction steps this depends on

```powershell
python -m tools.iw2.pogdata        # the INI tree and the CSV string tables
python -m tools.iw2.pogdis --all   # disassembly, for reading
python -m tools.iw2.apicov --coverage   # native API coverage
```

`pogdata` matters more than it looks: `text.Field` (636 call sites) is where
every line of dialogue comes from, and `inifile.*` is how the scripts read ship
and weapon definitions. Both are Latin-1 in the original and are converted to
UTF-8 at extraction, never at runtime.

## Mission checkpoints: what iscore.SetRestartPoint actually is

Every campaign act calls `iscore.SetRestartPoint()` at mission start and
`iscore.GotoRestartPoint()` on a mission restart (8 packages, argc=0 at every
call site). The natural guess -- an engine snapshot of the mission -- is wrong,
and the binaries say so:

* The POG package lives in its own wrapper DLL, `iscore.dll`. Its
  `RegisterNative("SetRestartPoint", ...)` / `("GotoRestartPoint", ...)` calls
  are at `iscore.dll @ 0x100018e0 / 0x10001940`, and the handlers
  (`@ 0x10001900 / 0x10001960`) are five instructions each: if
  `icScoreTable::m_p_instance` is non-null, push the player ship's object id
  (`icPlayerPilot::m_p_instance` -> `+0x14` (ship) -> `+0x4` (id)) and call the
  matching icScoreTable method. Nothing else.
* `icScoreTable` (`iwar2.dll`) keeps three per-sim-id hash maps of `cStats`
  (0x80-byte score records: per-type kill tallies, kill points, pod piracy
  count/value): **Aggregate** at `+0x34`, **Current** at `+0x44`, **Restart**
  at `+0x54`.
  * `SetRestartPoint(id)` (`iwar2.dll @ 0x100a0ab0`):
    `Restart[id] := Current[id]` (find-or-create, whole cStats copy).
  * `GotoRestartPoint(id)` (`iwar2.dll @ 0x100a0d80`):
    `Current[id] := Restart[id]`.
  * `Credit` (`@ 0x100a1380` kills, `@ 0x100a1620` piracy) writes **only**
    Current; `FlushScore` (`@ 0x100a07b0`, called from `icClient::DestroyWorld`
    `@ 0x100b3620` when the world is torn down with the player alive) folds
    Current into Aggregate and zeroes Current *and* Restart; if the player died,
    DestroyWorld instead just zeroes Current. `Total` (the statistics screen)
    reads Current + Aggregate.

So the pair is a **scoreboard checkpoint**: restarting a mission discards the
kills and piracy credited since the checkpoint, because the player is about to
earn them again. The *positional* half of a checkpoint was never native at all
-- the mission scripts store a `restart_waypoint` handle and a
`current_mission_state` on the player ship right before calling
SetRestartPoint, `ideathscript.PlayerDeathScript` reads them back on death, and
the restart screen respawns the ship at the waypoint
(`ideathscript.RestorePlayerShip`). All of that is POG and already ported in
`gen/ideathscript.gd` / `gen/ipdagui.gd`.

The port (`natives/misc.gd`) keeps one pair of counters where the original had
Current + Aggregate, so SetRestartPoint snapshots the counters and
GotoRestartPoint restores them. Between a Set and a Goto the Aggregate part
cannot change (Credit only writes Current), so the observable behaviour is
identical for every shipped script. The one divergence -- a Goto with no prior
Set in the same world would zero the whole total instead of just the mission's
share -- is unreachable: all 8 packages Set from their mission-start handler
before any Goto. `--campcheck` asserts the roll-back end to end.

UNKNOWN (not needed for the natives, left unrecovered): the exact meaning of
the cStats dwords at `+0x54..+0x74` (ResetStats zeroes them; neither Credit
overload writes them). Recovered fields: per-type kill tallies at `+0x00..+0x48`
(dword index `iiSim::eType - 0xc`, types 0xc..0x1e), kill points `+0x4c`, kill
count `+0x50` (Credit `@ 0x100a1380`), pod piracy count `+0x78` and value
`+0x7c` (Credit `@ 0x100a1620`). Also left alone: `ResolveID`'s wingmen path
(`iwar2.dll @ 0x100a1c60`: sims in the player's `wingmen_group` resolve to
score id 0), which never triggers for these natives because the wrapper always
passes the player ship's own id.

## The cargo loop (Jafs), now live end to end

ijafsscript's bytecode always contained the whole loop -- CallJafs ->
SummonJafs (spawns the SNRV, auto-tags the most valuable pods), the
irreducible loading loop (approach each pod, dock it to one of twelve
script-built cargo clamps), jafs_goes_home (dock cutscene at Lucrecia's
Base), CollectPods (reads each pod's "cargo" int property ->
iinventory.Add + iscore.AddPiracy + g_piracy_rating). It ran blind against
five native gaps, now fixed:

1. HUD wiring: hud_menu_call_jafs now starts ijafsscript.CallJafs
   (hud.gd _menu_select). The script gates itself on availability; with no
   act running (g_current_act == -1, the debug start seeds it) it
   self-enables, exactly as authored.
2. isim.Type / SimsInRadius: the full IeSimType enum is EXTRACTED --
   iiSim::Type (0x10078df0) indexes m_type_names (.data 0x1015d8e4..
   0x1015d960, 32 names T_None..T_PowerUp) and the script-facing flag is
   1 << (ordinal-1): T_CargoPod 2048, T_CommandSection 131072, both
   confirmed by bytecode comparisons. SimsInRadius now honours its type
   mask (with care: SimsInCone/OfFaction put other things at a[2]).
3. isim.IsDocked(sim[, to]) answers for the ARGUMENT (PogSim.docked_to),
   not the player; the Jafs loading loop polls it per pod.
4. iai.GiveDockOrderWithDockport carries the port; on approach completion
   the mover MATES it (icAIDockAgent's endgame): port.docked, docked_to,
   and the pod node reparents under the host to ride it rigidly
   (FiSim::AttachChild). main._fold_motion skips child-parented sims.
5. Ambient pods: a dying freighter spills its racked pods
   (DetachAndFlingChild -> main._spill_pods; traffic freighters now carry
   2-4 and fit the authored freighter.ini). Pod content: uniform pick over
   the registered commodity table -- a STAND-IN for iCargoScript's
   location-weighted generators (marked); the debug start runs
   icargoscript.Initialise so the table exists outside the campaign.

The player can also haul a pod personally: tow it (see Docking, towing and
mass) to LUCRECIA'S BASE and dock -- _deliver_towed_pod does the same
iinventory.Add read CollectPods would. Other stations credit nothing.
