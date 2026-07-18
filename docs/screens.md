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

## For original.md

### Lucrecia's Base — the home base (task #70)

Everything below is recovered from `data/pogsrc/ibacktobase.pog`, the base
overlay-manager `icSPPlayerBaseScreen` in `bin/release/iwar2.dll`, and the
shipped `defaults.ini`. Implemented in `game/scripts/base_interior.gd`
(`BaseInterior`), wired through `main.gd`, drawn by `base_screens.gd`, driven
headlessly by `checks.gd --basecheck` (20 assertions, ALL PASS).

**1. Contact-list presence and "finding it first."** The base is one entity,
`"Lucrecia's Base"`, present in three systems' JSON (hoffers_wake, santa_romera,
formhault). `iBackToBase.Initialise` (ibacktobase.pog:160) hides it on sensors
in all three and shows it only in `g_player_base_system`
(`isim.SetSensorVisibility`), and only once the act's found-base flag is set:
act 0 gates on `g_act0_found_base`, act 1 on `g_act1_found_base`, act 2+ is
always known. The flags are set at the end of the mission that walks you to the
base — `iact0mission10` (port line 653: `SetBool("g_act0_found_base",1)` +
`/movies/PBDiscovery`) and `iact1mission01` (port 749: `g_act1_found_base` +
`/movies/PB_Beauty`). Before the flag, the leading mission still puts the base
on sensors with `isim.SetStandardSensorVisibility(base,1)` so you can fly to it —
that is `mission.gd`'s `reveal_base` step.

**It moves.** `iStartSystem.MovePlayerBase(from,to)` (istartsystem.pog:1332)
rewrites `g_player_base_system`, hides the record in the old system and shows the
one in the new (`igame.MovePlayerBase` + `imapentity.SetHidden`). Itinerary,
from the ported acts: Hoffer's Wake (istartsystem.pog:494 initial) → Santa
Romera (iacttwo.gd:6557) → Formhault (iactthree.gd:239) → Santa Romera
(iactthree.gd:3508 finale).

**2/3. The go-home dock and its cutscene** are `iBackToBase.Detector`
(ibacktobase.pog:4), a 2.1 s poll. There is no ordinary dockport: inside 200 km
the detector bolts a `system_refuel_port` "bodge dockport" onto the *player's*
ship so a dock order is even possible. Inside 20 km with a dock order on the
base it runs `DockingCutscene`; the ship is placed at base-local (0,0,2900),
`sim.SetCollision(player,0)`, given a 300 m/s run to a waypoint at base-local
(0,0,1800) inside the bay, with the bay `door` avatar channel driven 0→1 and
`base_doors_sound` alongside. The doors (four `OuterDoor` leaves +
`<anim channel=door>` nulls) sit at avatar-local z +2010.5 -- the base's LWS
+Z face -- and (0,0,2900) is out along that same axis, so the run-in goes
THROUGH the doors; the record's map orientation is identity, so the world
axis matches. The camera is a dolly parked at player-relative
(r, -r/2, -2.5r) with `SetDollyCamera` + `SetFocus(player)` (our drop
camera). The final framing shot's offsets are per hull
(command_section (-1.1,0,14) … heavy_corvette (-1.1,0,60), switched on
`isim.Type`). Ends: `EnableBlackout(1)`, place the ship inside the base,
`gui.SetScreen("icSPPlayerBaseScreen")`, play the shutdown movie
(`YoungCalShutdown` act 0, else `OldCalShutdown`). Skippable via
`icutsceneutilities.HandleAbort`/`g_cutscene_skip` — the abort still leaves you
docked because the ship is placed *after* HandleAbort returns.

**There is no instant entry.** `local_6393` wraps the same `DockingCutscene`
for the short-range dock, so EVERY route into the base is fly-in cutscene →
blackout → shutdown movie → interior: two cinematics, the first skippable.
Our dock key calls `base_interior.begin_dock()` (the cutscene), never
`enter()` directly. The base/PDA screens are mouse-driven: base_screens.gd
releases the captured flight cursor while any POG screen is up and takes it
back when the last one drops.

**4. The interior is `icSPPlayerBaseScreen`, an `iiGUIOverlayManager`** (iwar2
`FcRegistry::RegisterClass` @ 0x10023710, ctor @ 0x10024000), NOT a screen. Its
ctor loads five 3D "diorama" scenes and builds a hash map of hosted screen →
diorama index (0x100243b7..0x100249f6), then per frame renders one diorama
behind the GUI and raises `icSPBaseScreen` — the base menu, built by
`ibasegui.SPBaseScreen` — over it with `FcGame::AddOverlayScreen` @ 0x10024cca
(this *settles* the inference in original.md §8a that "nothing else can put
icSPBaseScreen on the stack"). Config is `[icSPPlayerBaseScreen]` in the shipped
`defaults.ini`:

| diorama | url | localised name (`csv:/text/dioramas`) | scene |
|---|---|---|---|
| 0 | `main_bay_url = lws:/avatars/base/setup` | MAIN BAY | setup |
| 1 | `office_interior_url = …/setup_cal` | CONTROL ROOM | setup_cal |
| 2 | `jafs_url = …/setup_jafs` | LOADING DOCK | setup_jafs |
| 3 | `smith_url = …/setup_smith` | WORKSHOP | setup_smith |
| 4 | `gunbabes_url = …/setup_gb` | CREW LOUNGE | setup_gb |

Also: `fritz_delay = 0.5` (a camera-change flash, 0x10025459), `diorama_delay =
30` (idle cut to the next room, 0x10024eaa), `lights_global = g_base_lights_on`
(picks `baselights_normal` vs `baselights_emergency`, 0x10024d35), `dioramas_global
= g_show_dioramas`. With `g_show_dioramas` clear — the whole campaign — the loader
only ever loads diorama 0 (0x10024b95), so the interior is the MAIN BAY; the other
four rooms are a post-campaign reward (`g_show_dioramas` is set only at the end of
act 3, iactthree.gd:3524). `g_base_lights_on` is 0 until `iPrelude.BaseOnlineHandler`
("ok the systems are online") powers the base up, so a fresh act-0 base runs on
emergency lighting. The diorama's own camera is taken from the LightWave scene
(`avatars/base/Setup*.lws`): its frame-0 world transform and `ZoomFactor` as an
h-FOV. The clickable room name that cuts to the next diorama (0x10025500) is a
control of the manager, not of any screen.

**5. Email, cargo, choosing your ship** are all hosted screens of this manager —
`icSPInboxScreen` (email, diorama 1), `icSPManifestScreen`/`icSPInventoryScreen`
(cargo, dioramas 3/2), `icSPHangarScreen` (choose your ship, diorama 3),
`icSPComputerTradingScreen` (diorama 2). Already built by the ported `ibasegui`,
now reached from the base menu and each swinging the camera to its own diorama.

**6. The AUTOSKIP** (ibacktobase `local_3520`) is the >200 km branch: with a dock
order, LDS not inhibited, director idle and `g_ibacktobase_level <= 0`, after a
10 s sanity countdown it `FadeOut`s, teleports the ship to the base
(`PlaceNear(10000)` then `PlaceRelativeTo(3000,2000,15000)`), opens the landing
channel, gives it 400 m/s and `FadeIn`s on a 5 s dolly fly-by, then hands to
`DockingCutscene`. **It is a cut + teleport + one beauty shot — not time
compression and not an auto-LDS.** `g_ibacktobase_level` is an inhibit counter
(`Inhibit`/`Allow` ± 1); missions raise it to lock the player at the base.

### The base-screen widget skin — recovered, not styled (task redirect)

The base screens' *look* is also the original's, and it is **data**, not code:
`igui.SetGUIGlobals` (igui.pog:4) holds the entire skin as POG globals and
`igui.CreateFancyButton`/`CreateInverseButton`/… hand it to
`gui.SetWindowStateTextures` / `SetWindowStateColours` / `SetWindowFont` /
`SetWindowTextFormatting`. Every control is a **three-slice horizontal strip**
(left cap at natural width / body column stretched / right cap) cut from one
256×256 atlas (`GUI_texture_request = texture:/images/gui/gui` →
`data/textures/images/gui/gui.png`), with a *different* strip per state
(neutral/focused/selected), e.g. the base menu's fancy button is 226×32 with
neutral art at (0,36)-(39,68), focused (40,36)-(80,68), selected (81,36)-(120,68).
`SetWindowStateColours` is the per-state text colour (GUI_neutral (0.6,0.451,0),
GUI_focused (1,0.749,0), GUI_selected (1,0.859,0.278)); the inverse buttons set
it black over a filled bar. `natives/ui.gd` now records
`SetWindowStateTextures`/`SetShadyBarWidth`/the fonts and formatting;
`base_screens.gd` blits the named rects. The previous hand-picked amber
rectangles are gone.

**Layout space.** The engine renders windows in NATIVE pixels --
`FcWindowManager::Render` (flux 0x10097000) sets `SetPixelCamera` /
`SetViewportToWindow`, no scaling, top-left anchored -- and the scripts
anchor to the LIVE frame: `igui.CreateShadyBar`'s column is
`gui.FrameHeight()` tall, ibasegui positions from `FrameHeight() - 290`;
only nominal WIDTHS use the literal 640 (igui.pog:392). An earlier port
treated the whole thing as a fixed 640×480 canvas scaled-and-centred, which
squashed every screen and blurred the art. `gui.FrameWidth/FrameHeight` now
return the real window in original-pixel units (viewport / (height/768) --
the same fixed-pixel 1024×768 reference as menu.gd) and `base_screens.gd`
draws top-left anchored at that scale, so the base screens match the pause
menu's size and sharpness.

**Hover.** `FcWindowManager::Tick` (flux 0x10096d80) re-focuses the window
under the cursor whenever the mouse moves (`GetWindowContaining` →
`SetFocus`, clearing focus over nothing): focus-follows-mouse IS the hover
effect -- the focused-state strip and text colour light up. Arrow keys move
the same focus; the next mouse move takes it back. The engine is silent on
focus gain (`BeepOnGainFocus` ships unset). `base_screens.gd` `_hover`.
