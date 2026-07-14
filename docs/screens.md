# The remaining base/GUI screens (task #52)

Evidence log for the screens the classification ledger still listed as missing:
icSPComputerTradingScreen, icSPAddCargoScreen, icSPComputerPuzzleScreen,
icSPComputerMenu(Screen), icSPComputerCommsScreen, icCustomGUIScreen,
icCreditScreen + icScroller, icNotYetImplementedScreen — plus the audit flags
(icSPFlightPDAScreen unmapped, icPopUpCommsScreen's empty overlay, the five
`iloadout.*Customise*` stubs).

All addresses are virtual addresses in `bin/release/iwar2.dll` (Ghidra image
base 0x10000000). Functions Ghidra dropped were read with
`python tools/ghidra/disasm.py build/bin/iwar2.dll <va> +<len>`.

## How each screen's builder was recovered

Every icSP* screen class is a 0x30-byte FcGUIScreen registered with
`FcRegistry::RegisterClass`; the only virtual that differs per class is slot 16
of the vtable — `Initialise` — and every one of them is the same shape:
`FcGUIScreen::Initialise` (flux) plus **one `FcScriptEngine::CallFunction` on a
hard-coded string**. Dumping the vtables from the PE and disassembling each
slot-16 function gives the builder name directly — no guessing:

| class | Initialise | POG function it calls | shipped? |
|---|---|---|---|
| icSPCommsMainMenuScreen (control) | 0x10029540 | `iBaseGUI.SPCommsMainMenuScreen` | yes (already mapped) |
| icSPComputerTradingScreen | 0x10029a80 | `iBaseGUI.SPTradingScreen` | **yes** — `s_p_trading_screen` |
| icSPAddCargoScreen | 0x10028f80 | `iBaseGUI.SPCargoScreen` | **yes** — `s_p_cargo_screen` |
| icSPComputerPuzzleScreen | 0x10029930 | `SPComputerPuzzle.Main` | **yes** — gen/spcomputerpuzzle.gd `main` |
| icNotYetImplementedScreen | 0x10028100 | `iFrontendGUI.NotYetImplementedScreen` | **no** — absent from ifrontendgui.pog |
| icSPComputerMenuScreen | 0x100297e0 | `iBaseGUI.SPComputerMenuScreen` | **no** — absent from ibasegui.pog |
| icSPComputerCommsScreen | 0x10029690 | `iBaseGUI.SPComputerCommsScreen` | **no** — absent from ibasegui.pog |
| icMainMenuScreen (control) | 0x10026550 | `iFrontendGUI.MainMenuScreen` | yes |

So the "computer trading" screen *is* the SPTradingScreen builder and the
"add cargo" screen *is* SPCargoScreen — the class name and the builder name
simply differ, which is why the class-name convention never resolved them.

`icSPFlightPDAScreen` keeps its class name and builder name side by side in
.rdata (0x1015a478 / 0x1015a48c `iPDAGUI.SPFlightPDAScreen`) — same pattern.
Nothing in the shipped POG raises it (the engine raised it for the in-flight
pause); the remaster's pause is menu.gd, so the mapping is inert but correct.

### Status

| screen | status |
|---|---|
| icSPComputerTradingScreen | **wired + working** (SCREEN_BUILDERS + repair shim, see below); trade performed end-to-end in the harness |
| icSPAddCargoScreen | **wired + working**; row select fits a cargo pod, Remove returns it |
| icSPComputerPuzzleScreen | **wired + working**; increments, Calculate shuffle, NO MATCH path all run (see divergences) |
| icSPFlightPDAScreen | **wired**; builds 5 windows when raised |
| icCustomGUIScreen | **wired + working** (dynamic builder from `g_custom_gui_screen`); Instant Action ship choice builds 7 windows |
| icCreditScreen / icScroller | **engine-side mirror, working**; scrolls the extracted credits at the engine's own speed, pops at the end or on skip |
| icNotYetImplementedScreen | **engine-side mirror, working**; see honesty note |
| icSPComputerMenuScreen / icSPComputerCommsScreen | **dead in the original — left unmapped** (see below) |
| icSPCustomiseScreen (the five iloadout natives) | **implemented, functional divergence documented** |
| icPopUpCommsScreen | windowless C++ overlay; render/cancel now fall through so it cannot blank the base menu |

## icSPComputerMenuScreen / icSPComputerCommsScreen are dead code

Their Initialise functions call `iBaseGUI.SPComputerMenuScreen` /
`iBaseGUI.SPComputerCommsScreen`, and **no such functions exist in the shipped
ibasegui.pog** (checked data/pogsrc/ibasegui.pog and the port). A whole-image
scan for references to their class-name strings finds exactly two users each:
the `FcRegistry::RegisterClass` record, and (for the comms one) the
icSPPlayerBaseScreen diorama map built at 0x10024640 — **nothing, POG or C++,
ever pushes or overlays either class**. In the retail game these screens were
unreachable, and had they been reached their builder call would have failed and
left them empty. They stay unmapped; inventing content for them would violate
the prime rule. (The ledger's guess that they were "part of the remote-link
flow" does not hold up: icPlayerPilot::RemoteLink @ 0x100b1110 is the fly-by-
wire ship takeover and never touches the GUI screen stack.)

## icNotYetImplementedScreen — the apology that isn't there

The base Starmap button (`ibasegui SPBaseScreen_OnStarmapButton`, pogsrc line
553) pushes it. Its builder `iFrontendGUI.NotYetImplementedScreen` is missing
from the shipped ifrontendgui.pog, and no text table carries an apology string
(`grep -i implemented data/text/*.csv` — nothing). So in the retail game the
screen came up **empty**; the class name is the entire message. The remaster
mirrors it engine-side (natives/ui.gd `_build_not_yet_implemented`): a label
made of the class's own words ("NOT YET IMPLEMENTED") and a BACK row that pops
the screen. The retail escape path from the empty screen is unrecovered; the
BACK row is a remaster affordance so the player cannot be stranded.

## icCreditScreen + icScroller

C++ throughout, recovered from the binary:

* ctor 0x10016180: an icScroller (ctor 0x10018390) over the client rect inset
  0x40 px from the frame.
* the scroller resource (string table 0x10159e**): `html:\html\credits\credits`
  (extracted at data/html/credits/credits.html, 8 KB of FrontPage HTML), with
  `\movies\credits` as the backing movie.
* OnActivate 0x10016350: caps the frame rate at 120, registers the
  `Game.MovieSkip` input, streams `sound:/audio/music/badlands`.
* Tick 0x100164e0: `offset += dt * 50.0` (the 50.0 is the float at 0x10117be8),
  renders the text window at `SetViewOffset(floor(offset))` (0x100187c0), and
  calls `FcGame::PopScreen` when the offset passes the text height.

Remaster mirror: natives/ui.gd `_build_credit_screen` makes a `scroller`
window carrying the stripped credits HTML (`<BR>` = line break, tags dropped,
`&amp;` decoded); base_screens.gd advances it at the same 50 px/s, pops the
screen when the last line leaves the panel, and Escape/Enter skip (the
MovieSkip equivalent). Deliberately not reproduced: the credits movie backdrop
and the badlands music stream (audio_manager only plays the `a1_<mood>` music
set; the file `streams/audio/music/badlands.mp3` exists if its owner wants it).

## icCustomGUIScreen

Its ctor (0x100166b0) reads the POG **global string** `g_custom_gui_screen`
via `FcScriptGlobal::Access` and stores it; Initialise dispatches it. The
global is created empty by igui (gen/igui.gd:255) and set by
`igui.OverlayCustomScreen` (gen/igui.gd:899) immediately before overlaying the
class — Instant Action's ship choice goes through it as
`iinstantaction.InstantActionShipChoiceScreen` (gen/iinstantaction.gd:1396).
natives/ui.gd `_enter` resolves the builder from the same global at raise time.

## The customise screen (the five iloadout natives)

**Correction to the ledger: the original is not drag-and-drop.** icLoadout's
customisation is a list-box **mode machine** (all names from the export table):

* `StartCustomisedLoadout(splitter, textwindow)` @ 0x100863c0 stores the two
  windows, pushes a history node, and enters mode 0.
* `UpdateCustomisationSplitterWindow` @ 0x10092170 rebuilds the splitter each
  mode change: one 13-px static window per history entry (the uppercased mode
  titles — a breadcrumb trail), then an FcListBox wired to
  `iBaseGUI.SPCustomiseScreen_OnSelect` (select + mouse-up, string @
  0x1015f2b4) and the back handler on the cancel slot (@ 0x1015f28c).
* `CreateListBoxEntries` @ 0x100867d0 dispatches through
  `m_create_options_functions[mode]`; mode 0 (ShipOverview,
  0x10086b10) adds the four category rows — the FcString table at
  `m_customisation_category_names` (filled by 0x100840f0) holds the keys
  `customise_propulsion`, `customise_offensive`, `customise_defensive`,
  `customise_general` — plus SHIP UPGRADES when the hull INI has [Modifiers]
  entries; `AddCustomisedBackButton` (0x10092bf0) ends every non-root list.
* mode 1 (CategoryView, 0x10087060) lists the ship's subsims whose
  `SubsimCategory` (0x100927e0, keyed on the subsim type flags) matches, with
  special rows for turret-fighter dock ports, docked-on arms, and — offensive
  only, when cargo 0x22b is held — the chain/salvo fire-mode toggle.
* deeper modes fit each subsim type: SystemView, UpgradeView, CPU options /
  programs, missile launcher / categories / magazine, pylons, turret fighters,
  dock-on arms (the full OnCustomiseScreenSelectFor* / UpdateFor* family,
  0x10086fe0..0x10090400).
* `OnCustomiseScreenBack` @ 0x10090c50: history deeper than the root → pop one
  node, rebuild, return **true** (consumed); at the root return **false**, and
  the POG's SPCustomiseScreen_OnBackButton closes the screen.
* `UpdateCustomisedLoadoutTextBox` @ 0x10086820 refreshes the text window only
  when the focused row changes; the ShipOverview copy is the
  `customise_*instructions_1/2/3` keys (text/gui.csv rows 693-719).

natives/economy.gd now implements all five natives with that structure: the
mode/history stack, the four extracted category rows, the instruction keys, the
BACK row, and Back's consume-or-close contract. The breadcrumb trail is folded
into the list-box title (`TUG > OFFENSIVE > ...`).

**Deliberate divergence** (documented in the code): the remaster has no
subsim/mount-point model — ShipSystems is a flat list built from the ship INI —
so the deep per-type modes collapse into one generic SystemView: pick a fitted
system, then fit / swap ("[Empty]" clears) against the equipment cargo in the
inventory; a swapped-out device returns to the hold when a cargo type's
ship-system template matches it. Category membership approximates
SubsimCategory from ShipSystems groups (propulsion+power = DRV/THR/LDS/CAP/EPS
per the shipped instruction text "propulsion and power systems"; offensive =
WEP; defensive = LDA/countermeasures; general = the rest). Ship upgrades, CPU
programs, missile magazines, pylon hardpoints and the fire-mode row need the
mount model and are omitted.

## The porter's NewObject hole (FIXED -- both shims retired)

The POG opcode **NewObject** creates a live object of one of POG's three heap
types, and the operand that says which is a *link-time fixup* that reads 0 on
disk (the OIMP chunk names the type; `flux.dll @ 0x1003482c` patches the code
stream). Both the decompiler and the VM read that 0 literally and pushed `null`,
so every list local in a ported script was nothing at all. Two shipped patterns
break on that:

1. `iinventory.Fill*ListBox(listbox, parallel_list)` fills a parallel list of
   icCargo handles the script then stores in a global and indexes by row. With a
   null local the handles went nowhere and every row select died.
2. `igui.CreateGreyBoxStyleScreen` returns its widgets in a list and
   SPTradingScreen pulls them back out with `list.Head` -- so the trading
   screen's four handles were all null.

Both were shimmed (`natives/economy.gd _fill` planted the list under the global
name the script was about to use; `natives/ui.gd _repair_trading` rewired the
trading screen by hand). **Both shims are now gone.** `pogdis` reads the OIMP
tables into `obj_sites`, `pogdec` emits a `New(kind)` node, `pogport` renders a
fresh `[]` (list and set alike) or `""` (string), and the VM does the same from
`data/pog/*.json` -- so on both hosts the script's own list is a real, live list
and the natives fill it in place. See `docs/pog.md` and `docs/decompile.md`.
pogverify is unchanged by the fix (2878/2878, MISSING 0, INVENTED 0).

The fix exposed two latent bugs, both behind the null lists (the loops that walk
them had never executed):

* `gui.RepositionWindow` is `(window, parent, x, y)` -- it *reparents* as well as
  moves; `natives/ui.gd` was reading `(window, x, y, flag)`. The shipped
  bytecode settles it: `igui.ArrangeWindowsVertically` (igui entry 17714) passes
  a running vertical offset as the last argument.
* `iloadout.StartCustomisedLoadout` reached its `PogUi` through `vm.ui`, which
  only `PogRuntime` has, so under the VM (the default host) the customise screen
  came up with no rows. It now finds the PogUi through the natives it registered.

Related engine-property seeds (same "engine object arrives with its property
map" idea): icCargo exposes `type` (read back by SPCargoScreen's row select)
and icTrade's `generated_mission` string property defaults to "" (only
imissiongenerator.pog:1534 ever sets it) — economy.gd seeds both at creation so
`object.IntProperty` / `object.StringProperty` read what the engine would have
returned.

## Screen-stack model fix (per-screen overlays)

`FcGame::AddOverlayScreen` stacks overlays on the *current screen*;
`PushScreen` shows a fresh screen with no overlays, and popping it brings the
previous screen back **with its overlays intact**. PogUi used to keep one
global overlay pile, so `gui.PushScreen("icCreditScreen")` from under the base
menu overlay left the credits invisible below it. PogScreen now carries its own
`over` stack; top/visible/cancel resolution walks the current screen's overlays,
then the screen, then on down. Multi-column list-box rows (the component static
windows the inbox, trading and manufacturing screens build) are also rendered
as one row now: windows created inside a list-box entry are absorbed into it
and their titles joined in x order.

## Runtime verification

Headless harness (temporary `tmp_screen_check.gd`, deleted after the run) drove
the ported builders through PogRuntime and asserted on the PogUi model — 34/34
PASS, zero script errors: base menu up; trading raised with rows, a trade
performed (3 water -> 1 gold) and refilled; add-cargo raised, parallel list
planted, row select set the cargo pod, Remove path clean; puzzle raised with
edit boxes, increment worked, Calculate settled on "NO MATCH FOUND"; customise
raised (4 category rows), drill-down to a slot, a fit performed with correct
swap-back, Back consumed twice then closed; credits raised with the extracted
5.3 KB roll and skipped clean; NYI raised with its BACK row; the windowless
popup-comms overlay fell through to the base menu for both render and cancel;
Instant Action's custom screen and the flight PDA both built.

Gates: `--headless --quit` boots clean; `-- --campcheck` PASS (incl.
checkpoint roll-back); `-- --uicheck` completes ("UICHECK done, docked=
Lucrecia's Base"; its 6 headless save_png errors are pre-existing — identical
count with the changes stashed); portcheck 114/114; apicov: iloadout 24→29
implemented (100%), overall 646→653 functions, stubs 183→176.

Re-verified after the NewObject fix and the removal of both shims, with a
throwaway harness (`tmp_screen_check.gd`, deleted after the run) that drives the
screens on **both hosts** -- the ported GDScript and the original bytecode --
and asserts on the PogUi model: 26/26 PASS, zero script errors. Trading: the
four widgets come back out of the returned list, the offer row is in the list
box, the script wires its own input overrides, and a trade performed off the
selected row moved the hold 10 -> 7. Inventory: the parallel list is the
script's own live list, its handles line up 1:1 with the rows, and row 0 indexes
back to a real icCargo. Loadout, add-cargo (parallel list live), customise (4
category rows) and hangar all build. Identical results on the VM and the port.

Known small divergences, all noted in code: the puzzle's edit boxes step with
Left/Right only (no direct typing; `gui.SetEditBoxOverrides` remains a
presentation stub, so the begin/finish-editing callbacks never fire — the
original's own Increment/Decrement handlers are the wired path); the credits play
no music and no movie backdrop. (The add-cargo screen's inability to pre-select
the currently-fitted pod on entry is fixed: the builder now scans a real list.)
