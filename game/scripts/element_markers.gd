extends RefCounted
# ============================================================================
# THE CLASSIFICATION LEDGER (task #44).
#
# tools/iw2/featurecov.py extracts every class the engine registers with
# FcRegistry (257 in iwar2.dll, 127 in flux.dll) and diffs it against our
# `# @element` / `# @element-stub` markers. This file classifies everything
# that is NOT implemented in a specific file, so that `featurecov --todo`
# shows only the genuine gaps instead of a 360-line wall.
#
# RULES:
#   * Markers for really-built classes (the "element" marker without "-stub")
#     do NOT belong here -- they belong in the file that implements the
#     thing. This file is stubs only.
#   * Every reason starts with a category tag featurecov understands:
#       covered-elsewhere  the behaviour exists, in the named file, without a
#                          per-class marker (usually because one file plays a
#                          whole data-driven family)
#       engine-internal    plumbing Godot (or an offline tool) supplies; the
#                          replacement is named
#       mp-only            deathmatch/CTF multiplayer, out of scope
#       editor-only        development-workflow surface
#       debug-only         debug screens and dev builds
#       GENUINE GAP        not built and player-visible in single player.
#                          These are the work queue.
#
# Everything here was checked against the sources named in the reason on
# 2026-07-13; if you implement one of these, move it to an `# @element`
# marker in the implementing file and delete the line here.
# ============================================================================

# ---------------------------------------------------------------------------
# iwar2.dll -- single-player GUI screens (base iiSPGUIScreen)
#
# The POG-driven screens: gen/ibasegui.gd and gen/ipdagui.gd hold the ported
# builder for each (verified per class: the snake_case builder function
# exists and ui.gd SCREEN_BUILDERS maps the class to it); PogUi (natives/
# ui.gd) holds the widget tree and base_screens.gd draws it and feeds input.
# ---------------------------------------------------------------------------
# the stub table below is one greppable annotation per line by design;
# keep each on a single line
# gdlint: disable=max-line-length
# @element-stub icSPBaseScreen -- covered-elsewhere: gen/ibasegui.gd s_p_base_screen + ui.gd SCREEN_BUILDERS + base_screens.gd
# @element-stub icSPHangarScreen -- covered-elsewhere: gen/ibasegui.gd s_p_hangar_screen + ui.gd + base_screens.gd
# @element-stub icSPLoadoutScreen -- covered-elsewhere: gen/ibasegui.gd s_p_loadout_screen + ui.gd + base_screens.gd
# @element-stub icSPManifestScreen -- covered-elsewhere: gen/ibasegui.gd s_p_manifest_screen + ui.gd + base_screens.gd
# @element-stub icSPInventoryScreen -- covered-elsewhere: gen/ibasegui.gd s_p_inventory_screen + ui.gd + base_screens.gd
# @element-stub icSPRecyclingScreen -- covered-elsewhere: gen/ibasegui.gd s_p_recycling_screen + ui.gd + base_screens.gd
# @element-stub icSPManufacturingScreen -- covered-elsewhere: gen/ibasegui.gd s_p_manufacturing_screen + ui.gd + base_screens.gd
# @element-stub icSPCommsMainMenuScreen -- covered-elsewhere: gen/ibasegui.gd s_p_comms_main_menu_screen + ui.gd + base_screens.gd
# @element-stub icSPInboxScreen -- covered-elsewhere: gen/ibasegui.gd s_p_inbox_screen + ui.gd + base_screens.gd
# @element-stub icSPArchiveScreen -- covered-elsewhere: gen/ibasegui.gd s_p_archive_screen + ui.gd + base_screens.gd
# @element-stub icSPMessagesScreen -- covered-elsewhere: gen/ibasegui.gd s_p_messages_screen + ui.gd + base_screens.gd
# @element-stub icSPEncyclopaediaScreen -- covered-elsewhere: gen/ibasegui.gd s_p_encyclopaedia_screen + ui.gd + base_screens.gd
# @element-stub icSPStatisticsScreen -- covered-elsewhere: gen/ibasegui.gd s_p_statistics_screen + ui.gd + base_screens.gd
# @element-stub icSPShipTypeScreen -- covered-elsewhere: gen/ibasegui.gd s_p_ship_type_screen + ui.gd + base_screens.gd
# (icSPCustomiseScreen is really built: its @element marker is in economy.gd (the original is a list-box mode machine, not drag-and-drop))
# @element-stub icSPMainPDAScreen -- covered-elsewhere: gen/ipdagui.gd s_p_main_p_d_a_screen + ui.gd + base_screens.gd
# @element-stub icSPBasePDAScreen -- covered-elsewhere: gen/ipdagui.gd s_p_base_p_d_a_screen + ui.gd + base_screens.gd
# @element-stub icSPPDAOptionsScreen -- covered-elsewhere: gen/ipdagui.gd s_p_p_d_a_options_screen + ui.gd + base_screens.gd
# @element-stub icSPPDAControlsScreen -- covered-elsewhere: gen/ipdagui.gd s_p_p_d_a_controls_screen + ui.gd + base_screens.gd
# @element-stub icSPPDAGraphicsScreen -- covered-elsewhere: gen/ipdagui.gd s_p_p_d_a_graphics_screen + ui.gd + base_screens.gd
# @element-stub icSPPDASoundScreen -- covered-elsewhere: gen/ipdagui.gd s_p_p_d_a_sound_screen + ui.gd + base_screens.gd
# @element-stub icSPPDADeviceScreen -- covered-elsewhere: gen/ipdagui.gd s_p_p_d_a_device_screen + ui.gd + base_screens.gd
# @element-stub icSPPDASaveScreen -- covered-elsewhere: gen/ipdagui.gd s_p_p_d_a_save_screen + ui.gd + base_screens.gd
# @element-stub icSPPDALoadScreen -- covered-elsewhere: gen/ipdagui.gd s_p_p_d_a_load_screen + ui.gd + base_screens.gd
# @element-stub icPDAConfirmScreen -- covered-elsewhere: gen/ipdagui.gd p_d_a_confirm_screen + ui.gd + base_screens.gd
# @element-stub icFlightConfirmScreen -- covered-elsewhere: gen/ipdagui.gd flight_confirm_screen + ui.gd + base_screens.gd
# @element-stub icRestartScreen -- covered-elsewhere: gen/ipdagui.gd restart_screen + ui.gd + base_screens.gd
# @element-stub icControlScreen -- covered-elsewhere: gen/ipdagui.gd control_screen + ui.gd + base_screens.gd
# @element-stub icMoviesScreen -- covered-elsewhere: gen/ipdagui.gd movies_screen + ui.gd + base_screens.gd
# @element-stub icModScreen -- covered-elsewhere: gen/ipdagui.gd mod_screen + ui.gd + base_screens.gd
# (icSPFlightPDAScreen is really built: its @element marker is in ui.gd (mapped to ipdagui's builder))
# @element-stub icMainMenuScreen -- covered-elsewhere: menu.gd front end; no shipped script ever raises this class (the menu flow runs through icSPMainPDAScreen)
# @element-stub icSPDemoMainScreen -- debug-only: the demo build's main menu; retail scripts never raise it (builder exists in gen/ipdagui.gd if ever wanted)
# @element-stub icSPPDAResolutionScreen -- engine-internal: the resolution picker sub-screen; display modes are Godot/OS business now, and no shipped script ever raises it
# @element-stub icWrongDiskScreen -- engine-internal: the disc-check failure screen; the remaster has no disc check
# @element-stub icCDKeyScreen -- mp-only: CD-key entry for the network lobby
# @element-stub icNetworkScreen -- mp-only: network game lobby
# @element-stub icMultiplayScreen -- mp-only: multiplayer menu
# @element-stub icMultiplayScreenInGame -- mp-only: in-game MP menu
# @element-stub icMultiplayLANScreen -- mp-only: LAN session browser
# @element-stub icMultiplayOptionsScreen -- mp-only: MP options
# @element-stub icMultiplayServerScreen -- mp-only: server setup
# @element-stub icMultiplayServerScreenEx -- mp-only: server setup (extended)
# @element-stub icMultiplayTeamScreen -- mp-only: team selection
# (icNotYetImplementedScreen is really built: its @element marker is in base_screens.gd (retail's own builder was never shipped; ours adds a Back row, noted))
# (icSPAddCargoScreen is really built: its @element marker is in base_screens.gd (iBaseGUI.SPCargoScreen))
# (icSPComputerTradingScreen is really built: its @element marker is in base_screens.gd (iBaseGUI.SPTradingScreen))
# (icSPComputerPuzzleScreen is really built: its @element marker is in base_screens.gd (SPComputerPuzzle.Main))
# @element-stub icSPComputerMenuScreen -- dead-in-original: its builder is absent from the shipped POG and the image has zero push sites (the remote-link flow is ship takeover, not this)
# @element-stub icSPComputerCommsScreen -- dead-in-original: builder absent from shipped POG, zero push sites
# (icCustomGUIScreen is really built: its @element marker is in base_screens.gd (runs the builder named in g_custom_gui_screen))

# ---------------------------------------------------------------------------
# iwar2.dll -- game-object singletons and managers (base FcObject)
# ---------------------------------------------------------------------------
# @element-stub icAITarget -- covered-elsewhere: AI targeting state lives in ai_ship.gd and the iai natives (natives/gameapi.gd)
# @element-stub icCargo -- covered-elsewhere: natives/economy.gd (icargo model; the 611 icargo.Create commodities)
# @element-stub icCluster -- covered-elsewhere: main.gd loads every system (data/json/systems) and flies the L-point links between them
# @element-stub icComms -- covered-elsewhere: comms.gd (VO, subtitles, Clay's head) driven by the icomms natives in natives/gameapi.gd
# @element-stub icConversation -- covered-elsewhere: comms.gd dialogue queue + iconversation natives (natives/gameapi.gd)
# (icCornflakeDraw is really built: its @element marker is in particle_fx.gd)
# @element-stub icDirector -- covered-elsewhere: idirector natives (natives/gameapi.gd): dolly, focus, fades, captions
# @element-stub icEmail -- covered-elsewhere: natives/misc.gd iemail (real inbox: sender/subject/body/read/archive)
# @element-stub icFaction -- covered-elsewhere: natives/factions.gd
# @element-stub icFactions -- covered-elsewhere: natives/factions.gd feelings matrix
# @element-stub icHUD -- covered-elsewhere: hud.gd is the HUD manager; its elements carry their own @element markers
# @element-stub icLog -- covered-elsewhere: hud.gd log_msg + the icHUDLog element (hud_screens.gd)
# @element-stub icMovie -- covered-elsewhere: main.gd _play_movie / igame.PlayMovie native
# @element-stub icObjectives -- covered-elsewhere: mission.gd objectives + iobjectives natives (natives/gameapi.gd)
# @element-stub icOptions -- covered-elsewhere: ioptions natives (natives/ui.gd) + menu.gd
# @element-stub icPauseScreen -- covered-elsewhere: menu.gd pauses the tree and owns its input
# @element-stub icPlanetProperties -- covered-elsewhere: main.gd planet/sun materials read the same record fields (star_fx.gd documents the icSun paths)
# @element-stub icPopUpCommsScreen -- covered-elsewhere: comms.gd draws conversations wherever they happen; ibasegui overlays this class on OnConversationStart and the empty overlay is benign (worth a runtime check)
# @element-stub icSPMasterScreen -- covered-elsewhere: the screen-stack container; natives/ui.gd screens/overlays arrays are that stack
# @element-stub icScoreTable -- covered-elsewhere: natives/misc.gd iscore (kill values, skill rating)
# @element-stub icSpaceFlightScreen -- covered-elsewhere: main.gd flight view + hud.gd
# @element-stub icSpaceFlightScreenOverlay -- covered-elsewhere: hud.gd draws the flight GUI overlay
# @element-stub icTrade -- covered-elsewhere: natives/economy.gd itrade offers
# @element-stub icVisualEffects -- covered-elsewhere: explosion_fx.gd (data/json/sfx_effects.json carries its constants)
# @element-stub icWindowAvatarFactory -- engine-internal: widget-skin factory; base_screens.gd draws controls directly
# @element-stub iiCamera -- engine-internal: abstract camera base; Godot Camera3D + main.gd camera rig
# @element-stub iiHUDElement -- engine-internal: abstract base; the concrete elements are marked in hud.gd
# @element-stub iiPilot -- engine-internal: abstract base of icAIPilot / icPlayerPilot
# @element-stub iiRegion -- engine-internal: abstract base; iregion natives (natives/world.gd) serve the concrete regions
# @element-stub iiSimField -- engine-internal: abstract base of the two ambient fields (which are themselves a gap, below)
# @element-stub icClient -- mp-only: the network client object
# @element-stub icMPMasterScreen -- mp-only: the MP GUI master screen
# @element-stub icDebugScreenShip -- debug-only: ship inspector debug screen
# @element-stub icDebugScreenBounds -- debug-only: bounds inspector debug screen
# @element-stub icFFEffects -- engine-internal: force-feedback effect table; joystick FF is not reproduced (Godot Input.start_joy_vibration would be the hook)
# @element-stub icAlienSwarmDraw -- dead-in-original: no shipped INI instantiates it (the swarm uses icCornflakeDraw); its per-particle gradient colour is computed then discarded -- an original bug
# @element-stub FcParticleDrawLensFlare -- dead-in-original: no shipped INI names it; every particle [Draw] in data/ini is FcParticleDrawBillBoard (x6) or FcParticleDrawModel (x2), and no pogsrc reference exists either. The class is live code in flux.dll (CreateInstance @ 0x50ab0) but nothing in the shipped game data ever asks for one
# (icAlienSwarmDynamics is really built: its @element marker is in particle_fx.gd -- Lorenz attractors)
# (icCapsuleSpace is really built: its @element marker is in capsule_fx.gd / main.gd)
# (icCreditScreen is really built: its @element marker is in base_screens.gd (html credits roll, 50 px/s @ 0x10117be8))
# (icDisruptorDynamics is really built: its @element marker is in particle_fx.gd -- the infection edge-crawl)
# (icScroller is really built: its @element marker is in base_screens.gd (the credits scroller))
# (icTeleportDynamics is really built: its @element marker is in particle_fx.gd)

# ---------------------------------------------------------------------------
# iwar2.dll -- world avatars (base FiSceneNode / FcSceneNode /
# FcParticleEmitterNode)
# ---------------------------------------------------------------------------
# (icFlameConeAvatar is really built: its @element marker is in ship_effects.gd -- a 6-facet plasma-textured cone, TIME-scrolled axial UV at 0.5/s (Prepare 0x100bd5f0), SRCALPHA/ONE additive, channel-driven intensity (Draw 0x100bd630). See docs/thrusters.md)
# (icMovieAvatar is really built: its @element marker is in explosion_fx.gd)
# @element-stub icPlanetAvatar -- covered-elsewhere: main.gd planet spheres, ring + atmosphere materials
# @element-stub icPlanetsAvatar -- covered-elsewhere: main.gd _spawn_impostor (distant-planet impostors)
# (icShockwaveAvatar is really built: its @element marker is in explosion_fx.gd)
# @element-stub icStarfieldAvatar -- covered-elsewhere: main.gd _starfield_material shader dome
# (icSunAvatar is really built: its @element marker is in star_fx.gd)
# @element-stub icNebulaAvatar -- covered-elsewhere: this class is ONLY the distant backdrop model (0x100cb590 forces every material additive at alpha 0.99), which main.gd _setup_sky draws. The INSIDE of a nebula is icCloudAvatar -- see space_fx.gd
# (icBeamAvatar is really built: its @element marker is in explosion_fx.gd)
# @element-stub icCockpitAvatar -- covered-elsewhere: main.gd cockpit dressing shown in the F1 view
# @element-stub icWaypointAvatar -- covered-elsewhere: space_fx.gd draws the waypoint marker (icHUDWaypointIcon is @element there)
# (icAggressorAvatar is really built: its @element marker is in space_fx.gd)
# (icAlienSwarmAvatar is really built: its @element marker is in alien.gd / particle_fx.gd)
# (icAsteroidAvatar is really built: its @element marker is in fields.gd)
# (icCapsuleEffectNode is really built: its @element marker is in capsule_fx.gd / main.gd)
# (icCapsuleEntryBlankAvatar is really built: its @element marker is in capsule_fx.gd / main.gd)
# (icCapsuleSpaceAvatar is really built: its @element marker is in capsule_fx.gd / main.gd)
# (icCloudAvatar is really built: its @element marker is in space_fx.gd -- the 4-cell scrolling cloud ring you see from inside a nebula)
# @element-stub icElectricEffectAvatar -- GENUINE GAP: electric-arc emitter (disruptor / damage arcing)
# @element-stub icGasBallAvatar -- GENUINE GAP: gas-ball avatar (cosmetic; exact use not yet traced in the campaign)
# (icLDAAvatar is really built: its @element marker is in explosion_fx.gd)
# (icMissileTrailAvatar is really built: its @element marker is in missiles.gd)
# (icRocketTrailAvatar is really built: its @element marker is in missiles.gd)
# @element-stub icSignAvatar -- GENUINE GAP: station signage boards (cosmetic)

# ---------------------------------------------------------------------------
# iwar2.dll -- ship systems (base iiShipSystem / FcSubsim / icCapacitor /
# iiLDA / iiPilot)
# ---------------------------------------------------------------------------
# @element-stub iiShipSystem -- engine-internal: abstract base; ship_systems.gd is the recovered damage/power model
# @element-stub icActiveSensor -- covered-elsewhere: ship_systems.gd SEN group + main.gd contact list ranges
# @element-stub icAutorepair -- covered-elsewhere: ship_systems.gd reads autorepair_rate and runs the repair pool
# @element-stub icCPU -- covered-elsewhere: ship_systems.gd CPU group
# @element-stub icCapacitor -- covered-elsewhere: ship_systems.gd capacitor pool
# @element-stub icCrew -- covered-elsewhere: a subsim in ship_systems.gd's generic INI-driven damage model (nps_crew.ini); no crew-specific behaviour was recovered
# @element-stub icDockPort -- covered-elsewhere: idockport natives (natives/entities.gd) + main.gd docking/towing (_try_tow_dock mass coupling)
# @element-stub icDrive -- covered-elsewhere: ship_systems.gd DRV group + ship_flight.gd
# @element-stub icEPS -- covered-elsewhere: ship_systems.gd EPS group
# @element-stub icHeatSink -- covered-elsewhere: ship_systems.gd heat model (HEATSINK_MIN_RAMP)
# @element-stub icLDSDrive -- covered-elsewhere: ship_systems.gd LDS group + main.gd LDS cruise
# @element-stub icMountPoint -- covered-elsewhere: ship_systems.gd mounts subsims at named nulls from the mountpoint INIs
# @element-stub icReactor -- covered-elsewhere: ship_systems.gd power model
# @element-stub icSensor -- covered-elsewhere: ship_systems.gd SEN group + main.gd sensor visibility
# @element-stub icSensorDisruptor -- covered-elsewhere: main.gd disrupt() applies the disruption; the subsim takes damage like any other
# @element-stub icThrusters -- covered-elsewhere: ship_systems.gd THR group + ship_flight.gd
# @element-stub icCapsuleDrive -- covered-elsewhere: main.gd capsule jump + ship_systems.gd CAP group
# @element-stub iiLDA -- engine-internal: abstract base; the LDA deflection maths is ship_systems.gd
# @element-stub icAILDA -- covered-elsewhere: ship_systems.gd LDA deflection (icAILDA @ 0x1002b940 constants)
# @element-stub icPlayerLDA -- covered-elsewhere: ship_systems.gd LDA deflection (m_min_energy, max chance)
# @element-stub icAIPilot -- covered-elsewhere: ai_ship.gd flies the same flight model with patrol/attack behaviours
# @element-stub icPlayerPilot -- covered-elsewhere: main.gd _player_control is the recovered yoke (docs/controls.md)
# (icWeaponLink is really built: its @element marker is in ship_systems.gd)
# (icProgram is really built: its @element marker is in ship_systems.gd)

# ---------------------------------------------------------------------------
# iwar2.dll -- weapons and ordnance (base iiWeapon / iiGun / iiProjectile /
# icMagazine / icMissile / iiThrusterSim / icShip / icPowerUp)
# ---------------------------------------------------------------------------
# @element-stub iiWeapon -- engine-internal: abstract weapon base
# @element-stub iiGun -- engine-internal: abstract gun base
# @element-stub iiProjectile -- engine-internal: abstract projectile base
# @element-stub icCannon -- covered-elsewhere: weapons.gd PBC manager (bolts, refire, INI stats)
# @element-stub icBullet -- covered-elsewhere: weapons.gd swept-sphere bolts + main.on_bolt_hit damage chain
# @element-stub icShip -- covered-elsewhere: ship_flight.gd flight model + ship_systems.gd damage model + ai_ship.gd
# @element-stub icCargoPod -- covered-elsewhere: spawned as ordinary sims from their INI (natives/world.gd sim.Create; ipilotsetup.generic_cargo_pod)
# (icBeamProjector is really built: its @element marker is in turrets.gd -- AI beams are mechcheck-verified; the PLAYER fire path is issue #3)
# (icBeam is really built: its @element marker is in turrets.gd)
# (icSlugThrower is really built: its @element marker is in turrets.gd -- ammo-counted gun, mechcheck `gatling-gun`)
# (icTurret is really built: its @element marker is in turrets.gd, with iiGun/icBeamProjector/icBeam)
# (icTurretShip stays a stub: its @element-stub marker is in turrets.gd)
# (icAggressorShield is really built: its @element marker is in ship_systems.gd (it is a RAM, not a shield -- base iiWeapon))
# (icMagazine is really built: its @element marker is in missiles.gd)
# (icMissileMagazine is really built: its @element marker is in missiles.gd)
# (icCounterMeasureMagazine is really built: its @element marker is in missiles.gd)
# (icMissileLauncher is really built: its @element marker is in missiles.gd)
# (icMissile is really built: its @element marker is in missiles.gd)
# (icSimTrackingMissile is really built: its @element marker is in missiles.gd)
# (icRemoteMissile stays a stub: its @element-stub marker is in missiles.gd)
# (icLDSIMissile is really built: its @element marker is in missiles.gd)
# (icMine is really built: its @element marker is in missiles.gd)
# (icCounterMeasure is really built: its @element marker is in missiles.gd)
# (icRocket is really built: its @element marker is in missiles.gd)
# @element-stub icPowerUp -- mp-only: deathmatch pickup (imultiplay.AddPowerupWeapon and friends)
# @element-stub icPowerUpBomb -- mp-only: deathmatch bomb pickup
# (icAlienSwarm is really built: its @element markers are in alien.gd and ship_systems.gd)

# ---------------------------------------------------------------------------
# iwar2.dll -- cameras (base iiCamera)
# ---------------------------------------------------------------------------
# @element-stub icInternalCamera -- covered-elsewhere: main.gd F1 cockpit/no-cockpit views (FOV from flux.ini)
# @element-stub icTacticalCamera -- covered-elsewhere: main.gd F2 tactical / inverse-tactical
# @element-stub icExternalCamera -- covered-elsewhere: main.gd F3 external orbit / target-external
# @element-stub icDropCamera -- covered-elsewhere: main.gd F4 fixed-in-space tracking view
# @element-stub icArcadeCamera -- covered-elsewhere: main.gd hull-following arcade view
# @element-stub icOrbitCamera -- covered-elsewhere: main.gd external slow-orbit framing
# @element-stub icContactCamera -- covered-elsewhere: main.gd target_external frames ship and target
# @element-stub icChaseCamera -- covered-elsewhere: gameapi.gd dolly attached to a sim serves the cutscene chase shots
# @element-stub icDollyCamera -- covered-elsewhere: gameapi.gd PogDolly (idirector.CreateDolly/SetDollyCamera)
# @element-stub icSwapCamera -- covered-elsewhere: gameapi.gd dolly shot composition (idirector.SetDirection)
# @element-stub icConversationCamera -- covered-elsewhere: comms.gd talking-head view replaces conversation framing
# @element-stub icTwoShotCamera -- covered-elsewhere: comms.gd talking-head view replaces the two-shot
# @element-stub icBridgeShotCamera -- covered-elsewhere: comms.gd talking-head view replaces the bridge shot

# ---------------------------------------------------------------------------
# iwar2.dll -- sims, geography, fields, regions
# ---------------------------------------------------------------------------
# @element-stub iiSim -- engine-internal: abstract sim base; natives/world.gd PogSim is the handle
# @element-stub iiThrusterSim -- engine-internal: abstract base; ship_flight.gd is the flight model
# @element-stub icInertSim -- covered-elsewhere: plain sims via natives/world.gd sim.Create
# @element-stub icDolly -- covered-elsewhere: gameapi.gd PogDolly
# @element-stub icExplosion -- covered-elsewhere: death_sequence.gd (OnExplode size branch, sub-explosion crawl, DoFinalExplosion) + explosion_fx.gd composite effects
# @element-stub icShockwave -- covered-elsewhere: death_sequence.gd final blast + main.gd _update_shockwaves damage front + explosion_fx.gd avatar
# @element-stub icTimedWaypoint -- covered-elsewhere: mission.gd waypoint steps + natives/world.gd waypoints
# @element-stub icGeography -- covered-elsewhere: the authored map records (data/json/systems) main.gd loads
# @element-stub icPlanet -- covered-elsewhere: main.gd planets (spheres, rings, atmosphere, impostors)
# @element-stub icStation -- covered-elsewhere: main.gd stations (models, factions, docking)
# @element-stub icSun -- covered-elsewhere: star_fx.gd builds the original's three-part sun
# @element-stub icLagrangePointWaypoint -- covered-elsewhere: main.gd L-points, jump gating + space_fx.gd funnel
# (icNebula is really built: its @element marker is in space_fx.gd -- a sim with a radius you fly INSIDE, not a backdrop)
# (icAsteroidBelt is really built: its @element marker is in fields.gd)
# (icFieldSphere is really built: its @element marker is in fields.gd)
# (icFieldSim is really built: its @element marker is in fields.gd)
# (icAsteroidField is really built: its @element marker is in fields.gd)
# (icDebrisField is really built: its @element marker is in fields.gd)
# @element-stub icSolarSystem -- covered-elsewhere: main.gd _load_system builds the system from its record
# (icCapsuleSpaceSystem is really built: its @element marker is in capsule_fx.gd / main.gd)
# @element-stub icLDSIRegion -- covered-elsewhere: main.gd LDSI fence + iregion natives (natives/world.gd)
# @element-stub icTrafficControlRegion -- covered-elsewhere: main.gd _spawn_traffic + iregion natives
# @element-stub icGame -- covered-elsewhere: main.gd is the game loop; igame natives (natives/gameapi.gd)
# @element-stub icServer -- mp-only: the network server object
# @element-stub icServerApp -- mp-only: the dedicated-server app shell
# @element icGUIMovie -- menu.gd: the prison-dossier bust screen; pairs movies/<who>.bik with html/prison/<who>.html, random start + cycle (FUN_10017850); character set from [icGUIMovie] config bools

# ---------------------------------------------------------------------------
# iwar2.dll -- HUD elements not implemented in hud.gd (their bare @element-stub
# markers live there; the classification is here)
# ---------------------------------------------------------------------------
# (icHUDShields is really built: its @element marker is in hud.gd)
# (icHUDContrails is really built: its @element marker is in space_fx.gd)
# @element-stub icHUDDebug -- debug-only: HUD debug readout
# @element-stub icHUDScore -- mp-only: deathmatch score HUD element
# @element-stub icHUDEditBoxElement -- mp-only: the HUD chat/taunt entry box (imultiplay.ClientOpenHUDTauntBox)
# @element-stub iiHUDMenuElement -- engine-internal: abstract base of the full-screen HUD overlays (hud_screens.gd)
# @element-stub iiHUDList -- engine-internal: abstract base of the HUD list screens (hud_screens.gd)
# @element-stub iiHUDBlockElement -- engine-internal: abstract HUD block base (hud.gd concrete elements are marked)
# @element-stub iiHUDOverlayElement -- engine-internal: abstract HUD overlay base
# @element-stub iiHUDUnderlayElement -- engine-internal: abstract 3D-underlay base (space_fx.gd concrete elements are marked)

# ---------------------------------------------------------------------------
# iwar2.dll -- GUI widget skins (base icWindowAvatar / icCustomisableWindowAvatar
# / FcWindowAvatar) and screen-stack plumbing
# ---------------------------------------------------------------------------
# @element-stub icWindowAvatar -- engine-internal: widget-skin base; base_screens.gd draws controls with Godot's canvas
# @element-stub icBorderAvatar -- engine-internal: border skin; base_screens.gd draws frames directly
# @element-stub icFancyBorderAvatar -- engine-internal: nine-patch border skin (the remaster deliberately has its own look)
# @element-stub icCheckBoxAvatar -- engine-internal: checkbox skin; base_screens.gd draws the control kind
# @element-stub icComboBoxAvatar -- engine-internal: combobox skin
# @element-stub icDropDownListBoxAvatar -- engine-internal: dropdown skin
# @element-stub icListBoxAvatar -- engine-internal: listbox skin; base_screens.gd _draw_listbox
# @element-stub icTextWindowAvatar -- engine-internal: text-window skin; base_screens.gd _draw_text
# @element-stub icSliderControlAvatar -- engine-internal: slider skin
# @element-stub icHorizontalScrollbarAvatar -- engine-internal: scrollbar skin
# @element-stub icVerticalScrollbarAvatar -- engine-internal: scrollbar skin
# @element-stub icFancyVerticalScrollbarAvatar -- engine-internal: scrollbar skin
# @element-stub icDualScrollbarsAvatar -- engine-internal: scrollbar-pair skin
# @element-stub icSplitterWindowAvatar -- engine-internal: splitter skin
# @element-stub icFancySplitterWindowAvatar -- engine-internal: splitter skin
# @element-stub icCustomisableWindowAvatar -- engine-internal: skinnable-widget base
# @element-stub icBackButtonAvatar -- engine-internal: back-button skin; base_screens.gd renders back actions
# @element-stub icEditBoxAvatar -- engine-internal: edit-box skin; base_screens.gd draws edit rows
# @element-stub iiSPGUIScreen -- engine-internal: abstract base of the SP screens; natives/ui.gd owns the stack
# @element-stub iiGUIOverlayManager -- engine-internal: abstract overlay-manager base; natives/ui.gd overlays array
# @element-stub icPDAOverlayManager -- covered-elsewhere: natives/ui.gd screen/overlay stack handles the PDA overlay flow the scripts drive (25 bytecode references)
# @element-stub icSPPlayerBaseScreen -- covered-elsewhere: natives/ui.gd AUTO_OVERLAY raises the base menu when docked (main.gd _enter_base)
# @element-stub icDebugScreen -- debug-only: the debug screen-overlay manager

# ---------------------------------------------------------------------------
# flux.dll -- object model, app shells, script engine
# ---------------------------------------------------------------------------
# @element-stub FcObject -- engine-internal: the object-model root; Godot Object/RefCounted
# @element-stub FcApp -- engine-internal: app shell; Godot SceneTree main loop
# @element-stub FcGame -- engine-internal: game-app shell; main.gd
# @element-stub FcMainApp -- engine-internal: windowed-app shell; Godot
# @element-stub FcDemoApp -- debug-only: the demo build's app shell
# @element-stub FcGroup -- engine-internal: object container; GDScript arrays/dictionaries
# @element-stub FcTree -- engine-internal: tree container
# @element-stub FcPointer -- engine-internal: smart pointer; GC'd references
# @element-stub FcSpacePartition -- engine-internal: spatial index; the remaster's swept-sphere checks scan the small live-sim set
# @element-stub FcSceneGraph -- engine-internal: Godot's scene tree
# @element-stub FcResourceManager -- engine-internal: Godot ResourceLoader + per-file caches
# @element-stub FcPackage -- engine-internal: resource packages; tools/iw2/pkg.py extracts them offline
# @element-stub FcScriptEngine -- covered-elsewhere: pog/vm.gd runs the original mission bytecode
# @element-stub FcScriptState -- covered-elsewhere: pog/vm.gd holds VM state
# @element-stub FcScriptTask -- covered-elsewhere: pog/runtime.gd cooperative tasks
# @element-stub FcScriptableBindings -- covered-elsewhere: pog/natives/*.gd native registry
# @element-stub FiCompiler -- editor-only: compiles POG source; we run shipped bytecode (ported offline by tools/iw2/pogport.py)
# @element-stub FcWorld -- covered-elsewhere: main.gd world root; natives/world.gd floating origin
# @element-stub FcSubsim -- engine-internal: abstract subsim base; ship_systems.gd
# @element-stub FiSim -- engine-internal: abstract sim base; natives/world.gd PogSim
# @element-stub FcConsole -- debug-only: the in-engine console
# @element-stub FcMovie -- engine-internal: movie resource; Godot VideoStreamPlayer via main.gd
# @element-stub FiMovieDevice -- engine-internal: movie codec device; Godot VideoStream
# @element-stub FcForceFeedback -- engine-internal: FF hardware layer; not reproduced
# @element-stub FiCDAudioDevice -- engine-internal: CD audio; audio_manager.gd streams the GOG MP3s
# @element-stub FiInputDevice -- engine-internal: Godot Input
# @element-stub FcInputMapper -- engine-internal: Godot InputMap; bindings read from the game's configs in main.gd
# @element-stub FiGraphicsDevice -- engine-internal: Godot RenderingDevice
# @element-stub FcGraphicsEngine -- engine-internal: Godot RenderingServer
# @element-stub FiSound -- engine-internal: audio_manager.gd players
# @element-stub FiSoundDevice -- engine-internal: Godot audio output
# @element-stub FiNetworkDevice -- mp-only: network transport
# @element-stub FcClient -- mp-only: client session
# @element-stub FcServer -- mp-only: server session
# @element-stub FcServerBrowser -- mp-only: session browser
# @element-stub FcServerResolver -- mp-only: address resolver
# @element-stub FcWindowManager -- engine-internal: window/widget manager; natives/ui.gd + Godot Control
# @element-stub FcWindowFrameSim -- engine-internal: window-frame sim; not needed under Godot
# @element-stub FiPrimitive -- engine-internal: renderer primitive
# @element-stub FiShader -- engine-internal: Godot ShaderMaterial
# @element-stub FiSurface -- engine-internal: Godot ImageTexture surface
# @element-stub FiResource -- engine-internal: abstract resource base
# @element-stub FiTextureImage -- engine-internal: FTEX textures are converted offline (tools/iw2/textures.py) and loaded as Godot images
# @element-stub FcBitmap -- engine-internal: bitmap resource; offline conversion + Godot Image
# @element-stub FcFont -- engine-internal: bitmap fonts; tools/iw2/fonts.py + Godot FontFile
# @element-stub FcModel -- engine-internal: model resource; tools/iw2/pso.py -> glTF -> Godot meshes
# @element-stub FcHullMesh -- engine-internal: collision hull resource; main.gd derives collision spheres from models
# @element-stub FcWaveform -- engine-internal: WAV resource; audio_manager.gd
# @element-stub FiWindowAvatarFactory -- engine-internal: widget-skin factory base
# @element-stub FcWindowAvatarFactory -- engine-internal: widget-skin factory

# ---------------------------------------------------------------------------
# flux.dll -- scene nodes (base FiSceneNode / FcSceneNode)
# ---------------------------------------------------------------------------
# @element-stub FiSceneNode -- engine-internal: abstract scene-node base; Godot Node3D
# @element-stub FcSceneNode -- engine-internal: scene node; Godot Node3D
# @element-stub FcModelNode -- engine-internal: Godot MeshInstance3D from the converted glTF
# @element-stub FcCameraNode -- engine-internal: Godot Camera3D
# @element-stub FcLightNode -- engine-internal: Godot Light3D (explosion_fx.gd drives effect lights)
# @element-stub FcAnimationNode -- engine-internal: LWS motions are baked by tools/iw2/lws.py; Godot AnimationPlayer
# @element-stub FcMotionNode -- engine-internal: baked motion; Godot AnimationPlayer
# @element-stub FcEnvelopeNode -- engine-internal: LWS envelopes baked offline
# @element-stub FcChannelGeneratorNode -- covered-elsewhere: ship_effects.gd evaluates the channel expressions
# @element-stub FcChannelSwitchNode -- covered-elsewhere: ship_effects.gd interpolates the tagged poses by channel value
# @element-stub FcClipPlaneNode -- engine-internal: renderer clip plane; unused under Godot
# @element-stub FcDetailLevelNode -- engine-internal: LOD switching; Godot visibility ranges
# @element-stub FcDetailSwitchNode -- engine-internal: LOD switching; Godot visibility ranges
# @element-stub FcFeedbackNode -- engine-internal: force-feedback trigger node; not reproduced
# @element-stub FcLensFlareNode -- covered-elsewhere: star_fx.gd flares + main.gd _add_sky_flare
# @element-stub FcLoopSoundNode -- engine-internal: looped 3D sound; audio_manager.gd players
# @element-stub FcSoundNode -- engine-internal: one-shot 3D sound; audio_manager.gd
# @element-stub FcThreePartSoundNode -- engine-internal: start/loop/end sound; audio_manager.gd approximates with plain loops
# @element-stub FcParticleEmitterNode -- covered-elsewhere: particle_fx.gd systems

# ---------------------------------------------------------------------------
# flux.dll -- particles and colliders
# ---------------------------------------------------------------------------
# @element-stub FiParticleDynamics -- engine-internal: abstract dynamics base
# @element-stub FcParticleDynamics -- covered-elsewhere: particle_fx.gd (semantics read from FcParticleDynamics::Spawn @ 0x10053f80)
# @element-stub FiParticleEmitter -- engine-internal: abstract emitter base
# @element-stub FcParticleEmitter -- covered-elsewhere: particle_fx.gd emitters
# @element-stub FiParticleDraw -- engine-internal: abstract particle-draw base
# @element-stub FcParticleDrawBillBoard -- covered-elsewhere: particle_fx.gd DRAW_BILLBOARD
# @element-stub FcParticleDrawModel -- covered-elsewhere: particle_fx.gd DRAW_MODEL
# @element-stub FcParticleDrawLensFlare -- GENUINE GAP: lens-flare particle draw (minor cosmetic; billboard/model/cornflake are in particle_fx.gd)
# @element-stub FiCollider -- engine-internal: abstract collider base; main.gd swept-sphere collision
# @element-stub FcSphereCollider -- engine-internal: main.gd _collide_sphere / _model_coll_spheres
# @element-stub FcHullCollider -- engine-internal: hull collision approximated by main.gd's model spheres
# @element-stub FcLineCollider -- engine-internal: weapons.gd swept-sphere bolt tests do this job

# ---------------------------------------------------------------------------
# flux.dll -- screens, windows, widget skins
# ---------------------------------------------------------------------------
# @element-stub FiScreen -- engine-internal: abstract screen base; natives/ui.gd stack
# @element-stub FcGUIScreen -- engine-internal: GUI screen base; natives/ui.gd + base_screens.gd
# @element-stub FcScreenOverlayManager -- covered-elsewhere: natives/ui.gd screens/overlays arrays are the stack
# @element-stub FcDebugScreen -- debug-only: debug screen-overlay manager
# @element-stub FcLogoScreen -- engine-internal: boot logo screen; Godot splash + menu.gd
# @element-stub FcSceneDemoScreen -- debug-only: scene-viewer demo screen
# @element-stub cMovieScreen -- covered-elsewhere: main.gd _play_movie plays fullscreen movies
# @element-stub cDebugScreenFPS -- debug-only: FPS readout (Godot's monitor overlays replace it)
# @element-stub cDebugScreenProfile -- debug-only: profiler readout (Godot profiler replaces it)
# @element-stub cDebugScreenStatistics -- debug-only: statistics readout
# @element-stub cDebugScreenTasks -- debug-only: task-list readout
# @element-stub FcWindow -- engine-internal: widget base; PogWindow in natives/ui.gd + base_screens.gd drawing
# @element-stub FcBorder -- engine-internal: Godot-drawn frame (base_screens.gd)
# @element-stub FcButton -- engine-internal: PogWindow kind "button"
# @element-stub FcCheckBox -- engine-internal: PogWindow kind "checkbox"
# @element-stub FcComboBox -- engine-internal: PogWindow kind "combobox"
# @element-stub FcDropDownListBox -- engine-internal: PogWindow list kinds
# @element-stub FcDualScrollbars -- engine-internal: scrolling handled by base_screens.gd
# @element-stub FcEditBox -- engine-internal: PogWindow kind "editbox"
# @element-stub FcHorizontalScrollbar -- engine-internal: scrolling handled by base_screens.gd
# @element-stub FcVerticalScrollbar -- engine-internal: scrolling handled by base_screens.gd
# @element-stub FcListBox -- engine-internal: PogWindow kind "listbox" (base_screens.gd _draw_listbox)
# @element-stub FcRadioButton -- engine-internal: PogWindow selected-state buttons
# @element-stub FcShaderWindow -- engine-internal: shader-filled window; Godot canvas
# @element-stub FcSliderControl -- engine-internal: PogWindow kind "slider"
# @element-stub FcSplitterWindow -- engine-internal: layout; base_screens.gd row layout
# @element-stub FcStaticWindow -- engine-internal: PogWindow kind "window"
# @element-stub FcTextWindow -- engine-internal: PogWindow text windows (base_screens.gd _draw_text)
# @element-stub FcWindowAvatar -- engine-internal: widget-skin base; the remaster draws widgets directly
# @element-stub FcBorderAvatar -- engine-internal: widget skin
# @element-stub FcButtonAvatar -- engine-internal: widget skin
# @element-stub FcCheckBoxAvatar -- engine-internal: widget skin
# @element-stub FcComboBoxAvatar -- engine-internal: widget skin
# @element-stub FcDropDownListBoxAvatar -- engine-internal: widget skin
# @element-stub FcDualScrollbarsAvatar -- engine-internal: widget skin
# @element-stub FcEditBoxAvatar -- engine-internal: widget skin
# @element-stub FcHorizontalScrollbarAvatar -- engine-internal: widget skin
# @element-stub FcListBoxAvatar -- engine-internal: widget skin
# @element-stub FcRadioButtonAvatar -- engine-internal: widget skin
# @element-stub FcShaderWindowAvatar -- engine-internal: widget skin
# @element-stub FcSliderControlAvatar -- engine-internal: widget skin
# @element-stub FcSplitterWindowAvatar -- engine-internal: widget skin
# @element-stub FcStaticWindowAvatar -- engine-internal: widget skin
# @element-stub FcTextWindowAvatar -- engine-internal: widget skin
# @element-stub FcVerticalScrollbarAvatar -- engine-internal: widget skin
# @element-stub FcWindowFrameAvatar -- engine-internal: window-frame skin
