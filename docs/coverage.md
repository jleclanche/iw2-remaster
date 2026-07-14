# Coverage audit: the 184 API stubs and the element inventory

Audited 2026-07-13 (task #44); iscore checkpoints implemented (task #47).
Raw data is regenerable, not prose:

    python -m tools.iw2.apicov --stubs        # every stub, per package, by call count
    python -m tools.iw2.apicov --coverage     # 645/829 implemented, 184 stubbed
    python -m tools.iw2.featurecov            # 384 registered classes, per binary
    python -m tools.iw2.featurecov --todo     # the GENUINE single-player gaps only

The class-side classification lives in `game/scripts/element_markers.gd`
(the ledger featurecov reads). This file is the *native-API* side: what each
`# @stub` marker in `game/scripts/pog/natives/*.gd` claims, whether the claim
holds, and which stubs actually matter for single player.

Classification tags used below match featurecov's: **mp-only**,
**engine-internal**, **covered-elsewhere**, **debug-only**, **GENUINE GAP**
(player-visible in SP), plus **pragmatic** for stubs whose honest behaviour
is a deliberate approximation rather than a missing feature.

## Summary

| classification | stubs | call sites | verdict |
|---|---:|---:|---|
| mp-only (imultiplay, igame network/CD-key, isim.IsRespawning, ihud.ShowScore) | 131 | 991 | correctly out of scope |
| presentation, deliberately not reproduced (gui skin, sim culling/channels) | 17 | 700 | accurate, two reasons stale (below) |
| pragmatic approximations (ihabitat.Population, ibody.Type, iai.*, iship cosmetic) | 9 | 14 | accurate |
| engine-internal (ioptions device rows, igame disc checks) | 4 | 7 | accurate |
| **GENUINE GAP, SP-visible** | **22** | **159** | the work queue below |
| dead marker (`iship.IsAIDisabled`, zero call sites) | 1 | 0 | flag: remove or explain |

(184 markers total; `iship.IsAIDisabled` has no call site in any .pogasm --
`apicov --stubs` prints it as a DEAD MARKER. The iscore checkpoint pair,
formerly the top SP gap at 16 call sites, is implemented -- see below.)

## Per-package tables

### imultiplay -- 118 stubs, 943 call sites -- mp-only

The block comment in `natives/misc.gd` ("NOT PORTED, ON PURPOSE ... called
from icapturetheflag, iindiesvscorporates, inetworkgui and the other MP-only
packages") is accurate: every caller package is MP-only. No SP impact.
Heaviest: ServerSendUserMessage (75), ServerBroadcastMessage (69),
SetTransmitFlag (41), SetShipLimits (40), AIBotsCount (29). One marker reason
covers all 118; that is fine -- they are one decision.

### sim -- 8 stubs, 623 call sites -- mixed; reason partially STALE

Marker reason (world.gd): "Culling, collision toggles, mass and the avatar
channel-expression system ... have no effect on the outcome of a mission;
they are presentation."

| function | calls | audit |
|---|---:|---|
| SetCullable | 342 | accurate: culling is Godot's problem |
| AvatarSetChannel | 78 | **IMPLEMENTED** (task #51/53): routed to ship_effects.gd, which is the channel rig. The script's named channels are injected into the same raw-input table the avatar's `<anim>` expressions read, so a script value simply wins over the ship-state value while it is set |
| AvatarAddChannel | 58 | **IMPLEMENTED**, with AvatarSetChannel |
| SetCollision | 52 | mostly cutscene staging; ships colliding during a staged cutscene would be visible. Worth a runtime check, not clearly a gap |
| AddSubsim | 50 | **QUESTIONABLE**: "presentation" is too sweeping -- scripts add *working* subsims (act 3 fits the hyperspace tracker this way). Interacts with the iship.HasHyperSpaceTracker stub below |
| FindSubsimByName | 24 | same concern as AddSubsim |
| SetMass | 14 | accurate: handling tweaks, cosmetic |
| AvatarRemoveChannel | 5 | **IMPLEMENTED**, with AvatarSetChannel |

`sim.Create` on an `ini:/sims/weapons/*` path is also no longer a plain object:
it routes through missiles.gd (`_create_weapon` in natives/world.gd), so
iact2mission05's scripted LDSi burst -- create, PlaceAt on the Marauder group's
leader, Kill -- actually detonates and scrambles their LDS drives, and
iact2mission08 / iactthree's planted mines are real mines.

### imapentity -- 2 stubs, 57 call sites -- reason STALE

Marker reason (entities.gd): "we have no system map view for it to change".
**IMPLEMENTED** (task #53). icHUDStarmap is `@element` in hud_screens.gd, and
its system view now honours the flag: `_draw_system` skips records whose
`map_visible` is false. The 56 SetMapVisibility calls are how the missions hide
stations, wrecks and beacons from the map until the plot reveals them. Map-scoped
only -- a hidden entity still shows on sensors and in the contact list, which is
exactly what makes hiding it on the map useful.

### isim -- 6 stubs, 45 call sites -- mixed

| function | calls | audit |
|---|---:|---|
| AlienInfectionEffect | 17 | **GENUINE GAP** (SP): act 3 infection crust visual + damage-over-time. Matches the icAlienSwarm* class gaps in element_markers.gd. Reason accurate ("needs an avatar shader we have not built") |
| StopExplosion | 11 | accurate: our explosions are instantaneous, nothing staged to cancel |
| SetAlienInfectionDamage | 7 | **GENUINE GAP** (SP): the DoT half is gameplay, not just a shader -- act 3 damage numbers silently vanish |
| IsAlienInfectionEffectOn | 6 | with the above |
| WeaponTargetsFromContactList | 3 | turret-mode; part of the turret gap |
| IsRespawning | 1 | mp-only, accurate |

### gui -- 11 stubs, 42 call sites -- presentation, accurate

"Presentation we deliberately do not reproduce" (nine-patch skins, shady
bars, background movies). Accurate: base_screens.gd is deliberately not the
original look. One nuance: PlayBackgroundMovie/StopBackgroundMovie (4 calls)
are the base's animated backdrops -- cosmetic SP atmosphere lost by design,
worth a line in any future "faithful look" pass.

### igame -- 12 stubs, 35 calls -- mp-only (10) + disc checks (2), accurate

CreateFog/DestroyFog are called only from ibombtag/icapturetheflag/
ideathmatch (verified by callers), the CD-key/session/join calls belong to
the lobby, GotEarnedMovie/GotPlayDisk have no disc to check. All accurate.

### iship -- 10 stubs + 1 dead marker, 32 calls -- mixed

| function | calls | audit |
|---|---:|---|
| WeaponTargetsFromContactList | 15 | turret targeting -- part of the icTurret GENUINE GAP (SP combat vs gunstars) |
| WeaponsUseExplicitTarget | 4 | with the above |
| LastFireTarget | 3 | with the above |
| BrightnessOf | 2 | `icShip::Brightness` (0x10075420) is now recovered and implemented (ship_systems.gd); this stub can be bound to it |
| PercentageThrusterEmission | 2 | cosmetic, accurate |
| HyperSpaceTrackerTarget | 2 | **GENUINE GAP** (SP): the act 3 plot device -- following a ship through a capsule jump. With sim.AddSubsim stubbed too, the whole tracker chain is inert; the act 3 scripts should be traced to see how hard they lean on it |
| HasHyperSpaceTracker | 1 | with the above |
| RecalculateMOIFromMass | 1 | cosmetic, accurate |
| IsLDSScrambled | 1 | minor: LDS-scramble state query; the disrupt mechanic exists (main.gd), the query always answers no |
| CreateTurretFighters | 1 | turret gap |
| IsAIDisabled | 0 | **DEAD MARKER**: no call site in any .pogasm. Remove the marker or note why it is bound |

### iscore -- 0 stubs -- IMPLEMENTED (task #47)

SetRestartPoint / GotoRestartPoint (8 calls each, 8 packages -- every act)
are no longer stubs. The old marker reason ("we have no save/restore of
world state to hang that on") turned out to be a false premise: the natives
never snapshotted world state. Recovered from the binaries: the iscore.dll
handlers (@ 0x10001900 / 0x10001960) call icScoreTable::SetRestartPoint /
GotoRestartPoint (iwar2.dll @ 0x100a0ab0 / 0x100a0d80) with the player
ship's id, which copy the per-sim score stats (cStats) between the Current
table (+0x44) and the Restart table (+0x54) -- a *scoreboard* checkpoint.
The positional half of a mission checkpoint was always pure POG
(`restart_waypoint` / `current_mission_state` ship properties +
ideathscript.PlayerDeathScript + the restart screen) and is already ported.
Full write-up in docs/pog.md; verified by the `--campcheck` checkpoint
assertion in checks.gd.

### input -- 1 stub, 12 calls -- RECOVERED (task #53)

KeyCombinations is fully recovered: `input.dll @ 0x10001210` takes one action
name and returns one string from `FcInputMapper::KeyString` (flux @ 0x1006ade0)
via `FormKeyString` (flux @ 0x1006ab00) and `FcLocalisedText::Field`
(flux @ 0x10028d80) -- see docs/combat.md. The resolver is implemented as
`PogMisc.key_combinations()` in natives/misc.gd and reads the shipped keymap
(the install's `configs/default.ini`) plus `data/json/strings.json`; it returns
e.g. `[ Keyboard F8 ]` / `[ SHIFT - Keyboard M ]`.

The marker itself lives in natives/ui.gd (a different owner) and still needs its
one-line rebind onto `PogMisc.key_combinations`.

**Second half of the same bug, now fixed:** `ihud.SetPrompt` takes a SECOND
argument -- the key string -- and gameapi.gd's `_h_set_prompt` was discarding it.
All 12 KeyCombinations call sites (all in iact0mission10) pass their result
straight into it. It now carries through to `mission.prompt_keys`, which hud.gd
already draws.

### ihabitat -- 4 stubs, 9 calls -- 1 pragmatic + 3 GENUINE GAP

Population (4): pragmatic nominal value, accurate. SetArmed /
SetArmedWithTarget / SetReactiveFunction (5): "stations have no weapons in
the remaster yet" -- accurate, and it is the same gap as icTurret /
icTurretShip in element_markers.gd (SP missions do arm stations).

### ihud -- 2 stubs, 5 calls -- 1 SP gap + 1 mis-filed

FlashElement (4): tutorial highlight of a HUD element; reason honest (the
name->element mapping was not recovered). SP-visible during act 0 training.
ShowScore (1): **the comment block only explains FlashElement; ShowScore's
actual reason is that it is the MP scoreboard toggle -- mp-only. Flag: give
it its own line so the marker is accurate.**

### iloadout -- 5 stubs, 5 calls -- GENUINE GAP (SP); reason partially STALE

The five customise-screen event handlers. The reason says "the one base
screen with no POG builder we could run -- icSPCustomiseScreen exists,
but..." -- **stale**: `gen/ibasegui.gd` HAS `s_p_customise_screen` and ui.gd
SCREEN_BUILDERS maps it, so the screen shell comes up; what is missing is
only the drag-and-drop pylon fitting these five natives drive. The gap is
real (ship customisation is a core SP feature), the stated *why* is out of
date.

### ibody -- 2 stubs, 3 calls -- pragmatic, accurate

Type/FilterOnType: the record's two candidate fields genuinely do not fit;
honest and documented.

### ioptions -- 2 stubs, 2 calls -- engine-internal, accurate

One graphics device, one resolution row: Godot owns the display now.

### iai -- 1 stub, 1 call -- pragmatic, accurate

IsCapsuleJumpAccelerating: our AI ships have no jump spool-up phase.

## Stubs that matter for single player, ranked

1. ~~**iscore.SetRestartPoint / GotoRestartPoint**~~ -- IMPLEMENTED
   (task #47): the checkpoint scoreboard roll-back, see the iscore section.
2. **isim.AlienInfection\*** (4 stubs) -- act 3 infection visual *and* its
   damage-over-time.
3. **iship turret-targeting trio + ihabitat.SetArmed trio +
   iship.CreateTurretFighters** -- armed stations/gunstars; same root gap as
   icTurret/icTurretShip.
4. **iloadout customise five** -- ship customisation screen interaction.
5. **iship.HasHyperSpaceTracker / HyperSpaceTrackerTarget (+ sim.AddSubsim)**
   -- act 3 plot device.
6. ~~**input.KeyCombinations**~~ -- RECOVERED and implemented (task #53); the
   marker rebind is pending in natives/ui.gd.
7. **ihud.FlashElement** -- tutorial HUD highlight.
8. ~~**imapentity.SetMapVisibility**~~ -- IMPLEMENTED (task #53).

## Marker-hygiene flags (for the owners of the natives files -- not edited here)

* `iship.IsAIDisabled`: dead marker, zero call sites (`apicov --stubs`).
* `ihud.ShowScore`: reason comment describes FlashElement only; ShowScore is
  mp-only and should say so.
* `iloadout.*Customise*`: "no POG builder" is stale -- the builder exists and
  is mapped; the missing part is the pylon drag-and-drop UI.
* `imapentity.SetMapVisibility` / `IsVisibleOnMap`: "no system map view" is
  stale -- icHUDStarmap is implemented in hud_screens.gd.
* `sim.AvatarAddChannel` / `AvatarSetChannel` / `AvatarRemoveChannel`:
  "no equivalent" is stale -- ship_effects.gd is the channel rig; a routing
  would light up cutscene ships.
* `sim.AddSubsim` / `FindSubsimByName`: "presentation" undersells it; the
  act 3 tracker is fitted through it.

## The element side (featurecov)

`featurecov` now extracts the registry per binary -- **257 classes in
iwar2.dll, 127 in flux.dll, none in gui.dll / EdgeOfChaos.exe** (the old
"193 classes, 91 with base `?`" numbers were extraction misses: bases passed
as register-loaded imports, NULL-factory abstract classes, and the one
`cRegistrar`-registered class, icAITarget). Every class now has its real
base or `(root)`.

Classification (the ledger is game/scripts/element_markers.gd):

| | count |
|---|---:|
| built (`@element` in the implementing files) | 18 |
| covered-elsewhere (verified per class against the named file) | 136 |
| engine-internal (Godot or offline tools supply it) | 138 |
| mp-only | 22 |
| debug-only | 13 |
| editor-only | 1 |
| **GENUINE GAP** | **56** |

`featurecov --todo` prints the 56; `--todo --all` prints everything with its
category. The headline gaps, grouped:

* **The missile system** (12 classes): launchers, magazines, seekers, the
  remote missile, mines, LDSI missiles, countermeasures, rockets, both trail
  avatars.
* **Turrets / armed stations** (3): icTurret, icTurretShip, icSlugThrower.
* **Beam weapons** (2): icBeamProjector, icBeam.
* ~~**Player devices** (4)~~: **BUILT** (task #51). icAggressorShield (+avatar),
  icWeaponLink and icProgram are all recovered and implemented -- see
  docs/combat.md. The aggressor shield turned out to be an `iiWeapon`-derived
  RAM, not a shield; a weapon link is an automatic fire group built by the
  loadout from same-named weapons; and all ten program bits and what they gate
  are enumerated.
* **Act 3 aliens** (6): icAlienSwarm + avatar/draw/dynamics,
  icTeleportDynamics (+ the isim.AlienInfection stubs).
* **Capsule space** (5): the jump interior (currently a white fade).
* **Ambient fields** (6): asteroid/debris fields, belts, field sims, rock
  avatar.
* **Screens** (8): base trading, add-cargo, computer puzzle/menu/comms,
  custom GUI screen (instant action), credits (+icScroller),
  the NotYetImplemented apology screen.
* ~~**HUD** (2)~~: **BUILT** (task #51). icHUDShields (Draw 0x100fa540 -- the
  class it filters on is icPlayerLDA, the long-open DAT_10167e5c) and
  icHUDContrails (Update 0x100e4c80 / Draw 0x100e4e60, both raw-disassembled).
  See docs/hud_elements.md.
* **Cosmetic effects** (5): icLDAAvatar, icDisruptorDynamics,
  icElectricEffectAvatar, icGasBallAvatar, icSignAvatar, plus flux's
  FcParticleDrawLensFlare.
