# Running the game's own code

IW2's *content* is not in the engine. The missions, the conversations, the AI
orders, trading, the mission generator, the base screens -- all of it is POG
script, compiled to a stack-machine bytecode and shipped in `resource.zip` as
114 packages. The engine binaries only provide the ~42 **native packages**
those scripts call into (`iship`, `isim`, `iai`, `idirector`, `icomms`...).

That split is the whole strategy of this remaster:

> We already have the bytecode. If we implement the native API, the original
> missions run -- exactly, including their bugs and their debug messages.

So we do not re-author missions. We run them.

```
resource.zip/packages/*.pkg      the original compiled missions (we have these)
        |
        |  tools/iw2/pogexport.py     resolve imports, emit VM-ready JSON
        v
data/pog/*.json
        |
        |  game/scripts/pog/vm.gd     the interpreter, transcribed from
        v                             FcScriptTask::Execute in flux.dll
   POG virtual machine
        |
        |  game/scripts/pog/natives/  the ~42 native packages: OUR job
        v
   the Godot game
```

## The measure of done

`tools/iw2/apicov.py` censuses the native API from the disassembly -- every
`Call <pkg>.<Func>` site across all 114 packages -- and diffs it against the
`# @native` / `# @stub` markers in `game/scripts/pog/natives/*.gd`.

```powershell
python -m tools.iw2.apicov --coverage       # implemented vs stubbed vs unbound
python -m tools.iw2.apicov --todo           # the work queue, most-called first
python -m tools.iw2.apicov --list iship     # one package, with call counts + argc
```

The distinction is deliberate and load-bearing:

- **`@native`** -- really implemented: it does the thing.
- **`@stub`** -- bound so the bytecode links and runs, but inert. Multiplayer
  (`imultiplay`, 118 functions) is deliberately not ported; some of `gui` needs
  a widget toolkit we replaced with our own front end.

A coverage number that conflated the two would be lying to us, so it does not.

## Running a mission

Headless, and it tells you what it reached for that we have not built:

```powershell
godot --headless --path game --script res://scripts/pog/pogcheck.gd -- iact0mission10
```

In the game, with the campaign driven by bytecode instead of the hand-authored
steps in `mission.gd`:

```powershell
godot --path game -- --pog --pogplay          # --pogtrace for the scripts' own
                                              # debug lines (developer mode)
```

`--pogtrace` is worth knowing about: `DebugSkip` (opcode 0x45) makes `debug`
statements free in release by jumping over them, and that flag is our
`FcDeveloperMode`. Turn it on and the original developers' narration comes out:

```
[pog] iUtilities.pog: locking the skipper.
[pog] iShipCreation.ShipName: ERROR! Unable to read the number of entries of
      category 'General' from ini file.  Using general category
```

That second line is the *game's own* error handler telling us a native was
lying to it. It is the best diagnostic in the project.

## What the natives have to bridge

Two impedance mismatches do most of the work in `natives/world.gd`:

- **The floating origin.** The player sits at the scene origin, its true
  position lives in `main.px/py/pz`, AI ships are positioned *relative to the
  player*, and static `main.objects[]` records are *absolute*. POG knows none
  of this and just says "put this here", so `PogSim.abs_pos()/set_abs_pos()`
  converts per object kind and every native works in absolute metres.
- **Hostility.** POG decides who shoots whom with `ifaction`'s feelings matrix
  (a float in [-1,+1]; `SetFeeling` is the hottest game-facing native in the
  campaign at 5,529 call sites). Our `AiShip` decided it with a
  `behavior == "attack"` string. `isim.SetFaction` now re-derives the one from
  the other.

Ships are spawned by INI path -- `sim.Create("ini:/sims/ships/utility/flitter",
name)` -- and `data/json/ships.json` has all 148 of those definitions, so a
POG-spawned ship gets its *authored* stats rather than placeholder numbers.

## Extraction steps this depends on

```powershell
python -m tools.iw2.pogexport      # packages -> data/pog/*.json
python -m tools.iw2.pogdata        # the INI tree and the CSV string tables
python -m tools.iw2.pogdis --all   # human-readable disassembly, for us
```

`pogdata` matters more than it looks: `text.Field` (636 call sites) is where
every line of dialogue comes from, and `inifile.*` is how the scripts read ship
and weapon definitions. Both are Latin-1 in the original and are converted to
UTF-8 at extraction, never at runtime.
