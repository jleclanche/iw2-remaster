# Parity audit — done / missing / stand-in / act-by-act readiness

Audited 2026-07-18 against: `apicov --coverage/--stubs` (run clean),
`featurecov --todo` (run clean), `element_markers.gd`, the natives'
`@stub` markers, the check suites in `checks.gd`, `data/pogsrc/*.pog`
call sites, and the last ~140 commits. Effort: S = under a day,
M = days, L = a week or more.

Headline numbers: **829 natives, 673 implemented (98% of 72,345 campaign
call sites); 156 stubs, of which 131 are mp-only.** All 114 POG packages
ported and loading (portcheck); all 48 act-mission scripts ported.
Element registry: 384 classes, 8 genuine SP gaps left (featurecov).
The engine surface is nearly done. What remains is concentrated,
and most of it is listed on this page.

## A. Executive summary — the ten things that matter most

1. **Remote piloting is a no-op, and nine missions across all four acts
   use it.** `iship.InstallPlayerPilot` (natives/world.gd:1534) says it
   plainly: "our player is welded to main.ship, so those are not
   modelled." `iremotepilot.Install` therefore never hands control to the
   drone, and the HUD REM LINK node (hud.gd:1572) dispatches nothing.
   Callers: a0m20 (training), a1m04/08/09, a2m02/18/24, a3m03/08.
   Missions gate on `ReturnCurrentRemoteVessel()` AND on the linked
   vessel being flown somewhere — the second half cannot happen.
   **The single biggest campaign blocker.** (L)
2. **The front end and pause menu bypass the ported PDA screens.** The
   builders are done and mapped (`gen/ipdagui.gd` SPMainPDAScreen /
   SPFlightPDAScreen, ui.gd SCREEN_BUILDERS:149/160) but menu.gd is a
   stand-in that only borrows the save/load slot screens via
   `_pog_overlay`. Direct consequences, visible on the first screen of
   the game: OPTIONS and CREDITS are disabled rows (menu.gd:457-458),
   INSTANT ACTION skips the ship-choice screen (icSPShipTypeScreen —
   builder mapped, unreachable). Wiring this retires a whole class of
   divergence at once. (M; plus S for the two `ioptions.CreateGraphics*`
   row stubs the options screen will call)
3. **The player cannot fire a fitted beam weapon.** Beam mechanics are
   built and mechcheck-verified (turrets.gd: icBeamProjector/icBeam,
   AI ships and stations fire them) — but the player fire paths cover
   only guns (weapons.gd, channel 1) and magazines (main_combat.gd
   `player_mags`). A fitted icBeamProjector lands on channel 2 with no
   route to the trigger. Cargo_AntimatterStreamer (578) and the cutting
   beam are loot/fitting options from act 2 piracy onward — currently
   dead weight in the loadout screen. (M)
4. **Campaign verification depth is one mission.** `--campcheck` proves
   act 0 mission 10 boots, speaks, and completes its first waypoint
   objective (+ the iscore checkpoint natives). Nothing runs missions
   2..48 end-to-end. Every per-mission claim below the verified line is
   static analysis, not observation. Extending campcheck act-by-act is
   how "unknown" becomes a list. (M, incremental)
5. **Turret fighters never spawn.** `iship.CreateTurretFighters` is a
   stub and `istartsystem.finish_loadout` calls it on every system
   start, feeding `iwingmen.AddTFighters`. The icTurretShip hull is a
   GENUINE GAP (turrets.gd:14). A whole loadout feature (carrier escort)
   silently absent mid/late campaign. (L, needs icTurretShip + remote
   fighter plumbing)
6. **Scripted turret target designation is inert.**
   `iship/isim.WeaponTargetsFromContactList` and
   `WeaponsUseExplicitTarget` are stubs; turrets pick their own targets
   instead of the mission's. Degrades a1m03, a1m07, a2m25, a3m01, a3m03,
   istation, iwingmen. Turrets exist now, so this is routing, not
   simulation. (S)
7. **The physics feel is a fudge in two load-bearing places.** Collision
   response is `velocity -= n * rel * 1.6  # bounce off (response
   stand-in)` (main_collision.gd:32); rotational inertia is a scalar
   box-tensor stand-in (main_flight.gd:171-209). a2m24 leans on
   `sim.SetMass` + `iship.RecalculateMOIFromMass` (both stubs) — the one
   mission most exposed to invented physics. (M-L, needs extraction)
8. **Cutscene staging stubs:** `sim.SetCollision` (52 calls, 18
   packages; only the player half ported — commit be3434d) risks visible
   collisions during staged scenes; `isim.StopExplosion` (a1m07, a1m10,
   a2m01, a2m13, a3m04, a3m10) means staged explosions cannot be
   cancelled. Ghost-ship body-swap cutscenes (a1m10, iscriptedorders)
   no-op with #1. (S each)
9. **The look is verified only by eyeball, and the history proves it
   churns.** Engine glow (4 commits), nebula (6), sun/flares (5), prison
   bust (6), lighting reverted-inventions (e3ddd39), HUD (~15). No
   reference-image comparison exists; every one of these can regress
   without a check failing. (M to build the discipline, then S per area)
10. **Cosmetic element gaps, batched:** icElectricEffectAvatar
    (disruptor + act 3 infection arcs — the damage and crust natives ARE
    implemented, the arc visual is not), icRemoteMissile visual,
    icSignAvatar, icGasBallAvatar, FcParticleDrawLensFlare,
    icSlugThrower (ammo gun — matters now that the customise screen is
    live), gui.PlayBackgroundMovie (PDA/base animated backdrops).
    (mostly S each)

Corrections to the running gap list (things believed missing that are
not): beam weapon *mechanics* are built and checked (turrets.gd);
alien-infection natives, hyperspace tracker, iloadout customise five,
imapentity map visibility, ihud.FlashElement, iscore checkpoints,
sim.AddSubsim/AvatarSetChannel are all implemented since the 07-13
coverage audit. docs/coverage.md and several element_markers.gd lines
(icBeamProjector/icBeam "GENUINE GAP") are stale and should be refreshed.

## B. VERIFIED — feature → the check that proves it

| Feature | Proof (all in game/scripts/checks.gd unless noted) |
|---|---|
| Flight model: accel, brake, lateral, assist trim, coast, drift | mechcheck `_ms_accel`..`_ms_free_drift` (fast suite, ~17 s) |
| LDS engage / cruise speed / drop | mechcheck `_ms_lds_*` |
| Autopilot approach + dock convergence | `--mechslow` `_ms_ap_approach`/`_ms_ap_dock` (real-time, run rarely) |
| Missile spawn + velocity-vector guidance | mechcheck `_ms_missile_*` |
| Turret spawn + refire law; AI beam spawn + burst damage | mechcheck `_ms_turret_*`, `_ms_beam_*` |
| Asteroid/debris field pools (100/50), spawn shell, culling | mechcheck `_ms_field_*` |
| TRI power weights and drive response | mechcheck `_ms_tri_*` |
| Towing: dock, docked-mass ride | mechcheck `_ms_tow_*` |
| Freighter pod spill on kill | mechcheck `_ms_pod_spill*` |
| Full save → reload roundtrip; debug base dock | mechcheck `_ms_save_reload`, `_ms_debug_base` |
| Base dock fly-in, interior, room tour, base screens raise, PDA save/load slot screens | `--basecheck` (asserted `_bc` steps + screenshots) |
| New game end-to-end: front-end button → prelude POG boots → objects spawn → dialogue speaks | `--newgametest` / `--newgamecheck` (PASS/FAIL) |
| Act 0 m10: mission starts, dialogue flows, waypoint objective completes; iscore checkpoint roll-back | `--campcheck` |
| Capsule jump initiate → arrival | `--jumpcheck` |
| All 114 ported packages compile and instantiate | pog/portcheck.gd |
| Native API surface: 98% of call sites implemented, 0 unbound | tools/iw2/apicov.py --coverage |
| Heat sanctuary dormant exactly as the original (FcWorld cull, 400 km) | verified per docs + commit d606910; extraction rule recorded |
| Primary fire + heat ledger; per-system contact lists | `--fireprobe`, `--contactcheck` (printed, human-read) |

**Screenshot-only (eyeball, no assertion):** uicheck, motioncheck,
geogcheck, sunshot, muzzleshot, commshot, srgbprobe. These cover exactly
the areas with the worst churn history (see D, fragile areas, and F#2).

## C. MISSING — feature → evidence → what breaks → effort

Ordered by campaign impact.

| Feature | Evidence | What breaks | Effort |
|---|---|---|---|
| Remote-pilot control handoff (`iship.InstallPlayerPilot` real swap) | natives/world.gd:1534 "not modelled"; REM LINK HUD node dispatches nothing | 9 missions (a0m20, a1m04/08/09, a2m02/18/24, a3m03/08): the linked vessel can never be flown; icRemoteMissile and the remote fighter are unreachable behind the same wall | L |
| Front-end/pause PDA wiring | menu.gd:457 OPTIONS/CREDITS `false`; `_pog_overlay` used only for save/load | Stand-in menus diverge from original; OPTIONS, CREDITS dead; Instant Action ship choice (icSPShipTypeScreen) unreachable | M |
| `ioptions.CreateGraphicsDeviceOptionButtons` / `...Resolution...` | apicov --stubs | The wired PDA options screen will render empty device/resolution rows | S |
| Player beam fire path (channel-2 beams to the trigger) | weapons.gd cycles channel 1 only; `player_mags` = magazines only | Antimatter Streamer (cargo 578), cutting beam: lootable, fittable, never fire | M |
| Turret-fighter system (`iship.CreateTurretFighters` + icTurretShip) | stub in world.gd; turrets.gd:14 GENUINE GAP; istartsystem.pog:484 calls it every system start | Carrier-escort loadout feature absent; `iwingmen.AddTFighters` always fed an empty list | L |
| Turret designation (`WeaponTargetsFromContactList`, `WeaponsUseExplicitTarget`) | apicov --stubs; `_sh_noop` world.gd | a1m03/07, a2m25, a3m01/03, istation, iwingmen: batteries ignore the mission's targeting orders | S |
| `sim.SetCollision` (non-player half) | stub; 52 calls / 18 pkgs; be3434d ported the player half | Staged cutscenes and dock sequences can collide visibly (a0m20, a1m01/07/10, a2m01/18/24/25, a3m04/10, ideathscript, ishipcreation...) | S-M |
| `isim.StopExplosion` | stub ("our explosions are instantaneous") | a1m07/10, a2m01/13, a3m04/10, ideathscript, iwingmen: staged explosions cannot be cancelled mid-sequence | S |
| icElectricEffectAvatar | featurecov --todo; used by data/ini/sfx/disruptor + sfx/infection nodes | Disruptor arcs (act 2 loot weapon) and act 3 infection arcing invisible — the DoT and crust natives already work | M |
| icRemoteMissile (visual + control) | missiles.gd:21 stub "data and rules recovered; the handoff is not built" | Remote/deathblow/antimatter missiles (cargo 505/513/515) unusable; depends on the remote handoff | M (after handoff) |
| ~~icSlugThrower (ammo-counted gun)~~ **DONE** | was turrets.gd:20; the stub was stale on both counts — the player path was already complete, and 20 NPC hulls mount `nps_assault_cannon` (the stub claimed none did). Admitted to the AI battery with its ammo store; mechcheck `gatling-gun` | — | — |
| icSignAvatar, icGasBallAvatar, FcParticleDrawLensFlare | featurecov --todo | Station signage, gas-ball prop, flare-particle draws — cosmetic set dressing | S each |
| gui.PlayBackgroundMovie / StopBackgroundMovie | apicov --stubs (callers: ipdagui, inetworkgui) | PDA animated backdrop missing once the PDA screens are wired | S |
| `iship.BrightnessOf` rebind | coverage.md: recovered in ship_systems.gd, stub never rebound | a0m50, a1m08 script branches read 0 | S |
| `iship.IsLDSScrambled` query | stub; mechanic exists in main.gd | iscriptedorders always told "no" — wingman orders may misjudge scrambled ships | S |
| ihud.FlashElement — **implemented**; icPopUpCommsScreen empty overlay | element_markers.gd:115 "benign (worth a runtime check)" | Unverified: an in-flight conversation raising the overlay could blank or misdraw | S (check only) |

Deliberately out of scope (verified correctly classified): all 118
imultiplay stubs + igame network/CD-key/fog (MP-only callers, checked
against pogasm), force feedback, disc checks, debug screens, widget-skin
avatars (the remaster draws its own widgets by design).

## D. STAND-IN / DIVERGENT — how it diverges → risk

| Feature | Divergence | Risk |
|---|---|---|
| Collision bounce response | `velocity -= n * rel * 1.6`, an invented restitution (main_collision.gd:32) | Wrong feel in every ram/scrape; worst where missions stage collisions (a2m24) |
| Rotational inertia | scalar box tensor `I = m(w²+h²+l²)/12` + point-mass children; port-null mating not modelled (main_flight.gd:171-209) | Towed/docked stacks turn wrongly; `RecalculateMOIFromMass` stub compounds it |
| Pirated-pod contents | uniform pick over the commodity table, vs the original's location-weighted generators (main_combat.gd:133) | Act 2 piracy economy: loot distribution is wrong, trade balance drifts from original |
| Nebula interior | cyclorama wall stand-in beyond a swap distance (space_fx.gd:609-912); extracted, not tuned | Fragile — 6 commits of churn already; only eyeball guards it |
| ~~Aggressor shield shell~~ **RECOVERED** | the scale was never a radius: `icAggressorShield::Simulate` 0x1002f464 writes the node transform from the hull's W/H/L — scale (W·0.8, H, min·0.5), position (0,0,L·0.75) — and `icAggressorAvatar::Draw` 0x100b94e0 passes a hardcoded rim 1.0 with the apex at `depth`. Both cones now drawn, grow-in honoured | remaining: the two pulse nulls' looping envelopes and the `<glow>` light |
| Alien swarm pool | engine pool size UNKNOWN; `ALIEN_CAP := 128` (particle_fx.gd:36-46) | Act 3 swarm density may diverge from original |
| Death sequence surface points | FindSurfacePoint = random point on half-dims ellipsoid (death_sequence.gd:133) | Sub-explosion crawl placement approximate |
| Explosion bolt quads | crossed static quads for the turn-to-camera (explosion_fx.gd:647) | Minor visual |
| Front-end/pause menu | menu.gd is a whole-screen stand-in (see C) | Every session starts and pauses in a non-original screen |
| Base screens look | deliberately not the original skins (base_screens.gd:488,906 "tuned stand-ins") | Accepted divergence — flag if "faithful look" becomes a goal |
| Teleprint rate | `TELEPRINT_CPS := 30.0` stand-in for unvoiced lines (comms.gd:125) | Pacing of unvoiced dialogue |
| icNotYetImplementedScreen | ours adds a Back row the original never shipped (element_markers.gd:87) | Documented, benign |
| Imaging module | `GRANT_IMAGING_MODULE := false` — "the only invented byte in this file" (main_combat.gd:512); zoom unearnable until a purchase route exists | With trading/customise live, wire the buy route instead of the flag |
| ihabitat.Population | pragmatic nominal value (traffic density) | Traffic volumes approximate |
| **Fragile, eyeball-verified areas (churn history)** | engine glow ×4, nebula ×6, sun/flare ×5, prison bust ×6, lighting inventions reverted (e3ddd39), starmap, reticle, comms portrait | Regressions invisible to the suites; needs reference-comparison checks (F#2) |

## E. Act-by-act campaign readiness

"Blocking" = objective cannot complete or scene cannot run as designed.
"Degraded" = runs, but visibly or mechanically wrong. Only act 0 m10 has
an end-to-end check; everything else is call-site analysis (see A#4).

| Act | Missions (scripts) | Blocking | Degraded | Unknown / to verify |
|---|---|---|---|---|
| **0 — Prologue** | iprelude, m10, m20, m40, m50, m60, generaltraining, missiontour | m20: remote-link training segment (creates `a0_m20_name_remote`, enables connection — handoff no-ops). Verify whether the timed course requires it or it is an optional lesson | m20: `WeaponsUseExplicitTarget`, `SetCollision` staging; m50: `BrightnessOf` branch reads 0 | m10 VERIFIED to first waypoint + checkpoint (campcheck); rest of m10's HUD-tour and m40/m50/m60 never driven end-to-end; icPopUpCommsScreen overlay unverified |
| **1 — The Badlands** | m00-m10, piracyspecial, wingmentraining | m04, m08, m09: remote-pilot missions — scripts gate on flying the linked drone (m08:442, m09:496-635) | m03/m07: turret designation inert; m07/m10: StopExplosion; m01/m07/m10: SetCollision staging; m10: ghost-ship cutscene body-swap no-ops; m09: thruster-emission cosmetic; wingmen target orders partial | None run past static analysis; piracyspecial + wingmentraining unexercised |
| **2 — Piracy** | m01-m05, m07-m11, m13, m18-m20, m22, m24, m25 | m02, m18, m24: remote-pilot missions; m24 doubly exposed: also `SetMass` + `RecalculateMOIFromMass` stubs on invented-inertia physics | m25: turret designation; m01/m13: StopExplosion; m01/m18/m24/m25: SetCollision; piracy loot distribution invented (pod contents); player-lootable beams/slug-throwers/remote missiles cannot fire; disruptor arcs invisible (icElectricEffectAvatar) | m05 LDSi burst and m22 tracker poll implemented but never observed in-mission; trading/customise screens live but unexercised by any check beyond basecheck's raise |
| **3 — Gathering Storm** | m01-m06, m08-m10, iactthree | m03, m08: remote-pilot missions | m01/m03: turret designation; m04/m10: StopExplosion + SetCollision; infection ARC visual missing (DoT + crust natives work); `IsCapsuleJumpAccelerating` always no; player antimatter streamer unusable (scripted counter-weapon is the antimatter PBC — works via sim.AddSubsim, implemented) | Alien fights, capsule-chase sequences, endgame never run; alienswarm INI missing in original too (no-op'd there as well — parity, amusingly) |
| **JAFS side jobs** ("act 4", ijafsscript + imissiongenerator*) | 29 generated jobs | none known | SetCollision staging; generated economy rides the invented pod-content weighting | Entirely unexercised; runs on implemented natives (trade/cargo/email all 100%) |

Cross-act: turret fighters never spawn (istartsystem, every system);
front-end/pause stand-in wraps every session; save/load + starmap +
checkpoints implemented and checked.

## F. Recommended attack order

Systematic gates first — each one retires a *class* of failures or makes
a class of unknowns measurable. Bug-whacking individual missions before
these lands on sand.

1. **Wire the ported PDA screens into the front end and pause flow**
   (icSPMainPDAScreen / icSPFlightPDAScreen; + the two ioptions row
   stubs; + route INSTANT ACTION through icSPShipTypeScreen). Rationale:
   the builders already exist and are mapped — this is wiring, not
   porting. Kills the largest permanent divergence (every session's
   first screen), un-disables OPTIONS/CREDITS, and moves menu behaviour
   onto original bytecode where it stops needing bespoke maintenance.
2. **Reference-comparison discipline for the eyeball areas.** A
   screenshot-diff harness (original captures vs uicheck/sunshot/
   geogcheck outputs, tolerance-banded) for: lighting rig, nebula
   interior, engine glow, flares, HUD layout, comms portrait. Rationale:
   these areas have already consumed ~35 commits of fix-revert-fix; every
   future regression there is currently invisible. Cheap insurance that
   compounds. Keep it in the ≤30 s fast tier where possible.
3. **Extend campcheck one act at a time** (drive each mission's critical
   path headless; even "boots + reaches objective 1 + no stub hit"
   per mission converts column "Unknown" into a worklist). Do act 1
   first — it is the next thing a player hits. Rationale: A#4; also the
   cheapest way to find out whether a0m20's remote segment really
   blocks.
4. **The remote-pilot handoff.** Unweld the player from main.ship far
   enough to swap hulls (control + camera + HUD follow the piloted sim;
   the original swaps pilots, not ships). Unblocks nine missions in all
   four acts, the remote fighter, and icRemoteMissile — the largest
   single blocker class. Do it before anyone play-tests act 1 m08/09.
5. **Player beam fire path** (channel-2 beams behind the existing
   trigger/cycle machinery; mechanics already proven by mechcheck's AI
   beams). Before act 2 play-testing: that is when the loot starts
   including beams. Add a mechcheck step for player-fired beams.
6. **Small-stub batch, one pass:** turret designation pair,
   `SetCollision` non-player half, `StopExplosion` (stage-and-cancel),
   `BrightnessOf` rebind, `IsLDSScrambled`, icPopUpCommsScreen runtime
   check. Rationale: clears most of the per-mission "Degraded" column
   for a few days' work; each is S with a named call-site list above.
7. **Physics honesty: collision response + inertia tensor extraction**
   (replace the 1.6 bounce and scalar tensor with recovered laws; then
   implement `SetMass`/`RecalculateMOIFromMass` for real). Before a2m24.
8. **Turret fighters** (icTurretShip + CreateTurretFighters +
   AddTFighters plumbing) — after the remote handoff, which it shares
   machinery with (both are "player-adjacent hulls that fly
   themselves").
9. **Cosmetic batch:** icElectricEffectAvatar (act 2/3 arcs), remote
   missile visual, slug thrower, sign/gas-ball avatars, lens-flare
   particle draw, PDA background movies, pod-content weighting from
   iCargoScript's real generators.
10. **Ledger hygiene** (cheap, do alongside anything): element_markers
    stale lines (icBeamProjector/icBeam "GENUINE GAP" — built;
    icFlameConeAvatar/icScroller unmarked), dead marker
    `iship.IsAIDisabled`, refresh docs/coverage.md against today's
    apicov output so the next audit starts true.
