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
    2783/2878 functions ported cleanly (96.7%)
    95 functions still contain an unstructured jump, marked in the source

Run it:

```powershell
godot --path game -- --port --pogplay --pogtrace
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

The trade screen is the one you would expect to be script-driven and is not:
`icSPComputerTradingScreen` has no POG builder, and was laid out in C++.

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
