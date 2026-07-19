class_name PogMisc
extends RefCounted

## iemail, iscore, imod, stream, imultiplay: the game's odds and ends.
##
## iemail is the in-fiction inbox, and it is the one the campaign leans on: 159
## of its 270 call sites are SendEmail, which is how a mission tells the player
## what happened next. It is a real inbox here -- sender, subject, body, read
## flag, archive -- and the three keys the scripts pass are the same
## localisation keys the text tables already hold.
##
## iscore is the kill/piracy scoreboard. The kill values and the skill rating
## bands are declared by the scripts themselves (SetKillValue("T_Cruiser", 1000),
## AddSkillRating(1600, "statistics_kill_rating_level_5")), so the tables are the
## scripts' and the counters are ours.
##
## imultiplay is deliberately not ported: see the note above that section.

var vm   ## the host: PogRuntime for the ported scripts, PogVM for the oracle
var world: PogWorld = null
var game: Node3D = null

## iemail
var inbox: Array[PogEmail] = []
var archive: Array[PogEmail] = []

## iscore
var kill_values: Dictionary = {}       ## sim type name -> points per kill
var ratings: Array = []                ## [{score, key}], sorted high to low
var kill_score := 0
var piracy_score := 0
var logging := true
var restart_kill_score := 0            ## the checkpoint snapshot (SetRestartPoint)
var restart_piracy_score := 0

## imod: the mods found by ScanDirectory, in scan order.
var mods: Array[PogMod] = []

## stream: channel index -> {url, loop}. The scripts use channels 0..6.
var channels: Dictionary = {}


class PogEmail extends RefCounted:
	var sender := ""                   ## "a1_m02_email_sender", a text-table key
	var subject := ""                  ## likewise
	var body := ""                     ## "html:/text/act_1/act1_mission02_email"
	var received := 0.0
	var read := false


class PogMod extends RefCounted:
	var name := ""
	var display_name := ""
	var scenario := false
	var enabled := false


func register(v, w: PogWorld = null) -> void:
	vm = v
	world = w
	for fq in _BINDINGS:
		v.bind(fq, Callable(self, _BINDINGS[fq]))


func bind_game(main: Node3D) -> void:
	game = main


# ---------------------------------------------------------------- iemail
# SendEmail(sender_key, subject_key, body_url, notify). The body url is also the
# mail's identity: Find() takes it, and the missions send the same mail again on
# every entry to the scene, so sending is idempotent on it.

# @native iemail.SendEmail
func _send(_t, a: Array) -> Variant:
	var body := PogStd._s(a[2])
	var existing := _find(body)
	if existing != null:
		return existing
	var m := PogEmail.new()
	m.sender = PogStd._s(a[0])
	m.subject = PogStd._s(a[1])
	m.body = body
	m.received = vm.time if vm != null else 0.0
	inbox.append(m)
	if game != null and game.hud != null:
		game.hud.warn("NEW MAIL", 2.5)
	return m


func _find(body: String) -> PogEmail:
	for m in inbox:
		if m.body == body:
			return m
	for m in archive:
		if m.body == body:
			return m
	return null

# @native iemail.Find
func _email_find(_t, a: Array) -> Variant:
	return _find(PogStd._s(a[0]))

# @native iemail.Cast
func _email_cast(_t, a: Array) -> Variant:
	var v = a[0] if a.size() > 0 else null
	return v if v is PogEmail else null

# @native iemail.Read
func _email_read(_t, a: Array) -> Variant:
	var m = a[0] if a.size() > 0 else null
	return 1 if (m is PogEmail and m.read) else 0

# @native iemail.MarkAsRead
func _email_mark_read(_t, a: Array) -> Variant:
	var m = a[0] if a.size() > 0 else null
	if m is PogEmail:
		m.read = true
	return 0

# @native iemail.Unread
func _email_unread(_t, _a: Array) -> Variant:
	var n := 0
	for m in inbox:
		if not m.read:
			n += 1
	return n

# @native iemail.InboxSize
func _email_inbox_size(_t, _a: Array) -> Variant:
	return inbox.size()

# @native iemail.NthInInbox
func _email_nth_inbox(_t, a: Array) -> Variant:
	var i := int(a[0])
	return inbox[i] if i >= 0 and i < inbox.size() else null

# @native iemail.NthInArchive
func _email_nth_archive(_t, a: Array) -> Variant:
	var i := int(a[0])
	return archive[i] if i >= 0 and i < archive.size() else null

# @native iemail.ShuntReadEmailToArchive
func _email_shunt(_t, _a: Array) -> Variant:
	var keep: Array[PogEmail] = []
	for m in inbox:
		if m.read:
			archive.append(m)
		else:
			keep.append(m)
	inbox = keep
	return 0

# @native iemail.Sender
func _email_sender(_t, a: Array) -> Variant:
	var m = a[0] if a.size() > 0 else null
	return m.sender if m is PogEmail else ""

# @native iemail.Subject
func _email_subject(_t, a: Array) -> Variant:
	var m = a[0] if a.size() > 0 else null
	return m.subject if m is PogEmail else ""

# @native iemail.Body
func _email_body(_t, a: Array) -> Variant:
	var m = a[0] if a.size() > 0 else null
	return m.body if m is PogEmail else ""

# @native iemail.Received
func _email_received(_t, a: Array) -> Variant:
	var m = a[0] if a.size() > 0 else null
	return m.received if m is PogEmail else 0.0

# The archive list box on the comms screen. igui.CreateTitledListBox gives it two
# columns, "commsmenu_sender" and "commsmenu_subject", and ibasegui reads the row
# number straight back out to pick the mail:
#   v0 = gui.ListBoxFocusedEntry(v2); v1 = iemail.NthInArchive(v0);
# so the rows must be in archive order, which they are.

# @native iemail.FillArchivedEmailListBox
func _email_fill_archive(_t, a: Array) -> Variant:
	var lb = a[0] if a.size() > 0 else null
	if not (lb is PogUi.PogWindow):
		return 0
	lb.entries.clear()
	lb.selected_index = -1
	lb.focused_entry = 0 if not archive.is_empty() else -1
	for m in archive:
		lb.entries.append("%-22s %s" % [_text(m.sender), _text(m.subject)])
	_ui_dirty()
	return 0

# @native iemail.ResetWindows
func _email_reset_windows(_t, _a: Array) -> Variant:
	_ui_dirty()
	return 0


## The sender and subject are localisation keys, like every other line of text.
func _text(key: String) -> String:
	if game != null and game.comms != null:
		return String(game.comms.strings.get(key, key))
	return key


func _ui_dirty() -> void:
	var ui = vm.ui if (vm != null and "ui" in vm) else null
	if ui is PogUi:
		ui.dirty = true


# ---------------------------------------------------------------- iscore
# The scripts declare the tables and the engine kept the counters. Kills are
# credited through add_kill(), which is ours to call when a sim dies.

# @native iscore.SetKillValue
func _set_kill_value(_t, a: Array) -> Variant:
	kill_values[PogStd._s(a[0])] = int(a[1])
	return 0

# @native iscore.AddSkillRating
func _add_skill_rating(_t, a: Array) -> Variant:
	# (score_needed, rating_name_key): the bands the statistics screen reads.
	ratings.append({"score": int(a[0]), "key": PogStd._s(a[1])})
	ratings.sort_custom(func(x, y) -> bool: return x["score"] > y["score"])
	return 0

# @native iscore.AddPiracy
func _add_piracy(_t, a: Array) -> Variant:
	# (value, count): one call per pod taken, or a batch from a hold.
	if logging:
		piracy_score += int(a[0]) * int(a[1])
	return 0

# @native iscore.PodPiracyValue
func _pod_piracy_value(_t, _a: Array) -> Variant:
	return piracy_score

# @native iscore.Total
func _score_total(_t, _a: Array) -> Variant:
	return kill_score + piracy_score

# @native iscore.EnableLogging
func _enable_logging(_t, _a: Array) -> Variant:
	logging = true
	return 0

# @native iscore.DisableLogging
func _disable_logging(_t, _a: Array) -> Variant:
	logging = false
	return 0

# @native iscore.HTMLisedStats
func _htmlised_stats(_t, _a: Array) -> Variant:
	# The statistics screen renders this straight into a text window.
	var total: int = kill_score + piracy_score
	return "<html><body><p>Kills: %d</p><p>Piracy: %d</p><p>Total: %d</p>" \
			% [kill_score, piracy_score, total] \
			+ "<p>Rating: %s</p></body></html>" % skill_rating()


## The highest band the player has earned, as a text-table key.
func skill_rating() -> String:
	var total: int = kill_score + piracy_score
	for r in ratings:
		if total >= int(r["score"]):
			return r["key"]
	return ""


## Credit a kill. The value comes from the table the scripts loaded.
func add_kill(sim_type: String) -> void:
	if logging:
		kill_score += int(kill_values.get(sim_type, 0))

# The "restart point" is NOT a world snapshot. Both natives take no arguments
# (every call site is `Call iscore.SetRestartPoint argc=0`) and the handlers in
# iscore.dll (@ 0x10001900 / 0x10001960, registered @ 0x100018e0 / 0x10001940)
# do exactly one thing: call icScoreTable::SetRestartPoint / GotoRestartPoint
# with the player ship's object id (icPlayerPilot::m_p_instance +0x14 -> +4).
# icScoreTable (iwar2.dll) keeps three per-sim-id cStats hash maps: Aggregate
# (+0x34, whole game), Current (+0x44, this mission) and Restart (+0x54):
#   SetRestartPoint  (iwar2.dll @ 0x100a0ab0): Restart[id] := Current[id]
#   GotoRestartPoint (iwar2.dll @ 0x100a0d80): Current[id] := Restart[id]
# So the checkpoint rolls the *scoreboard* back: the mission scripts set the
# restart point right after storing "restart_waypoint"/"current_mission_state"
# on the player ship, and on a restart they discard the kills/piracy earned
# since the checkpoint (the player is about to re-earn them). The positional
# half of the checkpoint is pure POG (ideathscript.PlayerDeathScript reads
# those properties; the restart screen respawns there) and is already ported.
#
# Our model keeps one pair of counters where the original had Current +
# Aggregate. That is observably identical here: Credit (iwar2.dll @ 0x100a1380
# / 0x100a1620) only ever writes Current, and FlushScore (@ 0x100a07b0, called
# from icClient::DestroyWorld @ 0x100b3620) folds Current into Aggregate only
# at world teardown -- so between a Set and a Goto the Aggregate part cannot
# move, and restoring the combined counters restores exactly what the original
# restores. (Divergence only if a script called Goto without ever calling Set
# in the same world -- the original would zero just the mission's stats, we
# would zero the total. No shipped script does: all 8 campaign packages call
# SetRestartPoint from their mission-start handler.)

# @native iscore.SetRestartPoint
func _set_restart_point(_t, _a: Array) -> Variant:
	# No logging-enabled check: the original snapshots unconditionally.
	restart_kill_score = kill_score
	restart_piracy_score = piracy_score
	return 0

# @native iscore.GotoRestartPoint
func _goto_restart_point(_t, _a: Array) -> Variant:
	kill_score = restart_kill_score
	piracy_score = restart_piracy_score
	return 0


# ---------------------------------------------------------------- imod
# The mod/scenario list behind the PDA's mod page. Mods are directories under
# data/mods; the remaster ships none, so Count() is honestly 0 until one turns up.

# @native imod.ScanDirectory
func _mod_scan(_t, _a: Array) -> Variant:
	mods.clear()
	var root := ProjectSettings.globalize_path("res://").path_join("../data/mods")
	# Shipping no mods means the directory legitimately does not exist, and the
	# mod page is reachable from the front end's EXTRAS item -- so an absent
	# directory is an empty list, not an error to spew at whoever opens it.
	if not DirAccess.dir_exists_absolute(root):
		return 0
	for dir in DirAccess.get_directories_at(root):
		var m := PogMod.new()
		m.name = dir
		m.display_name = dir
		var cfg := ConfigFile.new()
		if cfg.load(root.path_join(dir).path_join("mod.ini")) == OK:
			m.display_name = PogStd._s(cfg.get_value("mod", "name", dir))
			m.scenario = PogVM._truthy(cfg.get_value("mod", "scenario", 0))
		mods.append(m)
	return 0

func _mod(i: int) -> PogMod:
	return mods[i] if i >= 0 and i < mods.size() else null

# @native imod.Count
func _mod_count(_t, _a: Array) -> Variant:
	return mods.size()

# @native imod.Name
func _mod_name(_t, a: Array) -> Variant:
	var m := _mod(int(a[0]))
	return m.name if m != null else ""

# @native imod.DisplayName
func _mod_display_name(_t, a: Array) -> Variant:
	var m := _mod(int(a[0]))
	return m.display_name if m != null else ""

# @native imod.IsScenario
func _mod_is_scenario(_t, a: Array) -> Variant:
	var m := _mod(int(a[0]))
	return 1 if (m != null and m.scenario) else 0

# @native imod.Enable
func _mod_enable(_t, a: Array) -> Variant:
	var m := _mod(int(a[0]))
	if m != null:
		m.enabled = PogVM._truthy(a[1])
	return 0


# ---------------------------------------------------------------- stream
# Play(channel, url, a, b) / Stop(channel, b) / IsPlayingURL(channel, url): a
# handful of audio channels the scripts drive directly for ambience (the base
# hum, the alien loop). The channel bookkeeping is exact, and a channel plays for
# real when its url resolves to one of the extracted wavs. A MUSIC url is one of
# the GOG MP3 streams and goes to the AudioManager's one-off track player --
# the base menu's own builder starts base_ambient_1/2 this way (ibasegui
# SPBaseScreen, 50/50 random), which is the base's real interior music.

# @native stream.Play
func _stream_play(_t, a: Array) -> Variant:
	var ch := int(a[0])
	var url := PogStd._s(a[1])
	channels[ch] = url
	if game == null or game.audio == null:
		return 0
	if "/music/" in url.replace("\\", "/"):
		game.audio.play_track(url.get_file())
		return 0
	var rel := PogUi.sound_path(url)
	if FileAccess.file_exists(game.audio.base_path.path_join(rel)):
		game.audio.play(rel)
	return 0

# @native stream.Stop
func _stream_stop(_t, a: Array) -> Variant:
	var url: String = channels.get(int(a[0]), "")
	channels.erase(int(a[0]))
	if game != null and game.audio != null \
			and "/music/" in url.replace("\\", "/"):
		game.audio.restore_music()
	return 0

# @native stream.IsPlaying
func _stream_is_playing(_t, a: Array) -> Variant:
	return 1 if channels.has(int(a[0])) else 0

# @native stream.IsPlayingURL
func _stream_is_playing_url(_t, a: Array) -> Variant:
	return 1 if channels.get(int(a[0]), "") == PogStd._s(a[1]) else 0


# ---------------------------------------------------------------- imultiplay
# NOT PORTED, ON PURPOSE. IW2's deathmatch/CTF multiplayer is out of scope for a
# single-player remaster: 118 functions and 943 call sites of server browser,
# lobby, bots and score sync, none of which the campaign touches (they are called
# from icapturetheflag, iindiesvscorporates, inetworkgui and the other MP-only
# packages). Every one of them is bound to the same inert handler so that those
# packages still link and any script that strays into one degrades quietly
# instead of crashing the VM on an unbound native.
#
# @stub imultiplay.ServerSendUserMessage
# @stub imultiplay.ServerBroadcastMessage
# @stub imultiplay.SetTransmitFlag
# @stub imultiplay.SetShipLimits
# @stub imultiplay.AIBotsCount
# @stub imultiplay.ClientOptionsDefaultTaunt
# @stub imultiplay.ClientBroadcastTeamMessage
# @stub imultiplay.IsGameEnded
# @stub imultiplay.ServerSetWinningTeam
# @stub imultiplay.LinkShipWeapons
# @stub imultiplay.ClientSendUserMessage
# @stub imultiplay.ClientAddRespawnEffect
# @stub imultiplay.SetUpdateFlag
# @stub imultiplay.PackageINI
# @stub imultiplay.ServerPlayerList
# @stub imultiplay.ClientSetRequestedToCycle
# @stub imultiplay.FragLimit
# @stub imultiplay.ClientBroadcastMessage
# @stub imultiplay.ServerPlayerDiedCount
# @stub imultiplay.MapINI
# @stub imultiplay.ClientOpenHUDTauntBox
# @stub imultiplay.EndGame
# @stub imultiplay.ServerPlayerFragCount
# @stub imultiplay.ServerSetPlayerTeam
# @stub imultiplay.ServerSetPlayerFragsCount
# @stub imultiplay.UseAIBots
# @stub imultiplay.AIBotsSkillLevel
# @stub imultiplay.ClientSay
# @stub imultiplay.NetworkReset
# @stub imultiplay.ClientPlayerList
# @stub imultiplay.ClientOptionsLoad
# @stub imultiplay.AddBotEndGameInfo
# @stub imultiplay.ClientOptionsShip
# @stub imultiplay.ClientOptionsName
# @stub imultiplay.ClientEndGameInfoFrags
# @stub imultiplay.ServerSetPlayerDiedCount
# @stub imultiplay.SendScores
# @stub imultiplay.ServerSendPlayerMessage
# @stub imultiplay.SetGameType
# @stub imultiplay.ServerSetSortMode
# @stub imultiplay.SetPlayerShip
# @stub imultiplay.ClientSetTeamGame
# @stub imultiplay.IsClient
# @stub imultiplay.ClientEndGameInfoCount
# @stub imultiplay.ClientEndGameInfoName
# @stub imultiplay.ClientEndGameInfoFlags
# @stub imultiplay.ClientEndGameInfoDied
# @stub imultiplay.ServerPlayerFlagsCount
# @stub imultiplay.ServerSetPlayerFlagsCount
# @stub imultiplay.TimeLimit
# @stub imultiplay.SeverRemoteLinkTo
# @stub imultiplay.ClientEndGameInfoTeam
# @stub imultiplay.ServerPlayerTeam
# @stub imultiplay.SetForRespawn
# @stub imultiplay.InstallAIPilot
# @stub imultiplay.AddPowerupWeapon
# @stub imultiplay.ServerMapListItem
# @stub imultiplay.ServerResetTeams
# @stub imultiplay.RemoteLinkTo
# @stub imultiplay.ClientSetLastSession
# @stub imultiplay.ClientOptionsSave
# @stub imultiplay.ClientOptionsServerAIBotsCount
# @stub imultiplay.ClientOptionsServerName
# @stub imultiplay.ServerSessionIndexFromName
# @stub imultiplay.ClientRejectedCount
# @stub imultiplay.ChangeMaxSpeed
# @stub imultiplay.ServerShipListItem
# @stub imultiplay.ServerBrowserUpdateComplete
# @stub imultiplay.ServerBrowserBeginInternet
# @stub imultiplay.ServerBrowserBeginLAN
# @stub imultiplay.ClientSetLastAddress
# @stub imultiplay.GetServerMapList
# @stub imultiplay.ClientOptionsServerMap
# @stub imultiplay.ServerMapListItemShort
# @stub imultiplay.GetServerPackageList
# @stub imultiplay.ClientOptionsServerAIBots
# @stub imultiplay.ClientOptionsServerAIBotsSkill
# @stub imultiplay.ClientOptionsServerPackage
# @stub imultiplay.IsServerAppSpawned
# @stub imultiplay.AddHealth
# @stub imultiplay.RemovePowerupWeapons
# @stub imultiplay.DebugSimPositionX
# @stub imultiplay.DebugSimPositionY
# @stub imultiplay.DebugSimPositionZ
# @stub imultiplay.ServerIP
# @stub imultiplay.ServerPlayerIP
# @stub imultiplay.GetServerShipList
# @stub imultiplay.NetworkSetProtocol
# @stub imultiplay.ProtocolVersion
# @stub imultiplay.ServerBrowserSetPogFunctions
# @stub imultiplay.ServerBrowserDisplayItem
# @stub imultiplay.ServerBrowserMaxPlayers
# @stub imultiplay.ServerBrowserPlayers
# @stub imultiplay.ServerBrowserAddress
# @stub imultiplay.ServerBrowserSessionIndex
# @stub imultiplay.ServerBrowserSessionName
# @stub imultiplay.ClientOptionsSetName
# @stub imultiplay.ClientOptionsSetShip
# @stub imultiplay.ClientOptionsSetServerName
# @stub imultiplay.ClientOptionsSetServerPackage
# @stub imultiplay.ClientOptionsSetServerMap
# @stub imultiplay.ClientOptionsSetServerFragLimit
# @stub imultiplay.ClientOptionsSetServerTimeLimit
# @stub imultiplay.ServerAppSpawn
# @stub imultiplay.ClientOptionsServerTimeLimit
# @stub imultiplay.ClientOptionsServerFragLimit
# @stub imultiplay.ClientOptionsSetServerAIBots
# @stub imultiplay.ClientOptionsSetServerAIBotsSkill
# @stub imultiplay.ClientOptionsSetServerAIBotsCount
# @stub imultiplay.ServerPackageListItem
# @stub imultiplay.ServerPackageListItemShort
# @stub imultiplay.ClientRequestedToCycle
# @stub imultiplay.ClientLastAddress
# @stub imultiplay.ClientLastSession
# @stub imultiplay.ServerBrowserValidateKey
# @stub imultiplay.ServerAppTerminate
# @stub imultiplay.ClientIsTeamGame
## FALSE, and correct: there is no network session, so we are never sitting
## in a multiplayer lobby. SPMainPDAScreen's first branch tests it
## (ipdagui.pog:29) and a wrong answer sends the whole builder down the
## multiplayer path -- which is exactly what igame.SessionName did.
# @native imultiplay.NetworkIsLobbySession
func _mp(_t, _a: Array) -> Variant:
	return 0


const _BINDINGS := {
	"iemail.sendemail": "_send", "iemail.find": "_email_find",
	"iemail.cast": "_email_cast", "iemail.read": "_email_read",
	"iemail.markasread": "_email_mark_read", "iemail.unread": "_email_unread",
	"iemail.inboxsize": "_email_inbox_size",
	"iemail.nthininbox": "_email_nth_inbox",
	"iemail.nthinarchive": "_email_nth_archive",
	"iemail.shuntreademailtoarchive": "_email_shunt",
	"iemail.sender": "_email_sender", "iemail.subject": "_email_subject",
	"iemail.body": "_email_body", "iemail.received": "_email_received",
	"iemail.resetwindows": "_email_reset_windows",
	"iemail.fillarchivedemaillistbox": "_email_fill_archive",

	"iscore.setkillvalue": "_set_kill_value",
	"iscore.addskillrating": "_add_skill_rating",
	"iscore.addpiracy": "_add_piracy",
	"iscore.podpiracyvalue": "_pod_piracy_value",
	"iscore.total": "_score_total",
	"iscore.enablelogging": "_enable_logging",
	"iscore.disablelogging": "_disable_logging",
	"iscore.htmlisedstats": "_htmlised_stats",
	"iscore.setrestartpoint": "_set_restart_point",
	"iscore.gotorestartpoint": "_goto_restart_point",

	"imod.scandirectory": "_mod_scan", "imod.count": "_mod_count",
	"imod.name": "_mod_name", "imod.displayname": "_mod_display_name",
	"imod.isscenario": "_mod_is_scenario", "imod.enable": "_mod_enable",

	"stream.play": "_stream_play", "stream.stop": "_stream_stop",
	"stream.isplaying": "_stream_is_playing",
	"stream.isplayingurl": "_stream_is_playing_url",

	"imultiplay.serversendusermessage": "_mp",
	"imultiplay.serverbroadcastmessage": "_mp",
	"imultiplay.settransmitflag": "_mp", "imultiplay.setshiplimits": "_mp",
	"imultiplay.aibotscount": "_mp",
	"imultiplay.clientoptionsdefaulttaunt": "_mp",
	"imultiplay.clientbroadcastteammessage": "_mp",
	"imultiplay.isgameended": "_mp", "imultiplay.serversetwinningteam": "_mp",
	"imultiplay.linkshipweapons": "_mp",
	"imultiplay.clientsendusermessage": "_mp",
	"imultiplay.clientaddrespawneffect": "_mp",
	"imultiplay.setupdateflag": "_mp", "imultiplay.packageini": "_mp",
	"imultiplay.serverplayerlist": "_mp",
	"imultiplay.clientsetrequestedtocycle": "_mp",
	"imultiplay.fraglimit": "_mp", "imultiplay.clientbroadcastmessage": "_mp",
	"imultiplay.serverplayerdiedcount": "_mp", "imultiplay.mapini": "_mp",
	"imultiplay.clientopenhudtauntbox": "_mp", "imultiplay.endgame": "_mp",
	"imultiplay.serverplayerfragcount": "_mp",
	"imultiplay.serversetplayerteam": "_mp",
	"imultiplay.serversetplayerfragscount": "_mp",
	"imultiplay.useaibots": "_mp", "imultiplay.aibotsskilllevel": "_mp",
	"imultiplay.clientsay": "_mp", "imultiplay.networkreset": "_mp",
	"imultiplay.clientplayerlist": "_mp",
	"imultiplay.clientoptionsload": "_mp",
	"imultiplay.addbotendgameinfo": "_mp",
	"imultiplay.clientoptionsship": "_mp",
	"imultiplay.clientoptionsname": "_mp",
	"imultiplay.clientendgameinfofrags": "_mp",
	"imultiplay.serversetplayerdiedcount": "_mp",
	"imultiplay.sendscores": "_mp",
	"imultiplay.serversendplayermessage": "_mp",
	"imultiplay.setgametype": "_mp", "imultiplay.serversetsortmode": "_mp",
	"imultiplay.setplayership": "_mp", "imultiplay.clientsetteamgame": "_mp",
	"imultiplay.isclient": "_mp", "imultiplay.clientendgameinfocount": "_mp",
	"imultiplay.clientendgameinfoname": "_mp",
	"imultiplay.clientendgameinfoflags": "_mp",
	"imultiplay.clientendgameinfodied": "_mp",
	"imultiplay.serverplayerflagscount": "_mp",
	"imultiplay.serversetplayerflagscount": "_mp",
	"imultiplay.timelimit": "_mp", "imultiplay.severremotelinkto": "_mp",
	"imultiplay.clientendgameinfoteam": "_mp",
	"imultiplay.serverplayerteam": "_mp", "imultiplay.setforrespawn": "_mp",
	"imultiplay.installaipilot": "_mp", "imultiplay.addpowerupweapon": "_mp",
	"imultiplay.servermaplistitem": "_mp",
	"imultiplay.serverresetteams": "_mp",
	"imultiplay.networkislobbysession": "_mp",
	"imultiplay.remotelinkto": "_mp", "imultiplay.clientsetlastsession": "_mp",
	"imultiplay.clientoptionssave": "_mp",
	"imultiplay.clientoptionsserveraibotscount": "_mp",
	"imultiplay.clientoptionsservername": "_mp",
	"imultiplay.serversessionindexfromname": "_mp",
	"imultiplay.clientrejectedcount": "_mp",
	"imultiplay.changemaxspeed": "_mp", "imultiplay.servershiplistitem": "_mp",
	"imultiplay.serverbrowserupdatecomplete": "_mp",
	"imultiplay.serverbrowserbegininternet": "_mp",
	"imultiplay.serverbrowserbeginlan": "_mp",
	"imultiplay.clientsetlastaddress": "_mp",
	"imultiplay.getservermaplist": "_mp",
	"imultiplay.clientoptionsservermap": "_mp",
	"imultiplay.servermaplistitemshort": "_mp",
	"imultiplay.getserverpackagelist": "_mp",
	"imultiplay.clientoptionsserveraibots": "_mp",
	"imultiplay.clientoptionsserveraibotsskill": "_mp",
	"imultiplay.clientoptionsserverpackage": "_mp",
	"imultiplay.isserverappspawned": "_mp", "imultiplay.addhealth": "_mp",
	"imultiplay.removepowerupweapons": "_mp",
	"imultiplay.debugsimpositionx": "_mp",
	"imultiplay.debugsimpositiony": "_mp",
	"imultiplay.debugsimpositionz": "_mp", "imultiplay.serverip": "_mp",
	"imultiplay.serverplayerip": "_mp", "imultiplay.getservershiplist": "_mp",
	"imultiplay.networksetprotocol": "_mp",
	"imultiplay.protocolversion": "_mp",
	"imultiplay.serverbrowsersetpogfunctions": "_mp",
	"imultiplay.serverbrowserdisplayitem": "_mp",
	"imultiplay.serverbrowsermaxplayers": "_mp",
	"imultiplay.serverbrowserplayers": "_mp",
	"imultiplay.serverbrowseraddress": "_mp",
	"imultiplay.serverbrowsersessionindex": "_mp",
	"imultiplay.serverbrowsersessionname": "_mp",
	"imultiplay.clientoptionssetname": "_mp",
	"imultiplay.clientoptionssetship": "_mp",
	"imultiplay.clientoptionssetservername": "_mp",
	"imultiplay.clientoptionssetserverpackage": "_mp",
	"imultiplay.clientoptionssetservermap": "_mp",
	"imultiplay.clientoptionssetserverfraglimit": "_mp",
	"imultiplay.clientoptionssetservertimelimit": "_mp",
	"imultiplay.serverappspawn": "_mp",
	"imultiplay.clientoptionsservertimelimit": "_mp",
	"imultiplay.clientoptionsserverfraglimit": "_mp",
	"imultiplay.clientoptionssetserveraibots": "_mp",
	"imultiplay.clientoptionssetserveraibotsskill": "_mp",
	"imultiplay.clientoptionssetserveraibotscount": "_mp",
	"imultiplay.serverpackagelistitem": "_mp",
	"imultiplay.serverpackagelistitemshort": "_mp",
	"imultiplay.clientrequestedtocycle": "_mp",
	"imultiplay.clientlastaddress": "_mp",
	"imultiplay.clientlastsession": "_mp",
	"imultiplay.serverbrowservalidatekey": "_mp",
	"imultiplay.serverappterminate": "_mp",
	"imultiplay.clientisteamgame": "_mp",
}


# ---------------------------------------------------------------- input
# @native input.KeyCombinations
## "Which key is <action> bound to?" -- the act-0 tutorial's prompts want the
## answer, and there are 12 calls, all in iact0mission10.
##
## RECOVERED, end to end:
##
##   input.dll @ 0x100011f0 registers the native; @ 0x10001210 it takes exactly
##   ONE string (the engine action name, e.g. "icPlayerPilot.AutopilotDock") and
##   returns ONE string, straight out of FcInputMapper::KeyString.
##
##   FcInputMapper::KeyString (flux.dll @ 0x1006ade0) looks the action up in the
##   binding table, returns the id "key_text_undefined" when it is unbound, and
##   otherwise walks up to FOUR bindings, joining them with the literal "+, +".
##
##   FcInputMapper::FormKeyString (flux.dll @ 0x1006ab00) builds each binding as
##   a '+'-delimited token string:
##       "[ " + [modifier ids...] + device id + " " + key id + "+ ]"
##   with the modifier bits (flux.dll .rdata): 0x08 ctrl, 0x04 alt, 0x02 shift,
##   0x80/0x40/0x20/0x10 shift1..4; and the device bits 0x10000 keyboard,
##   0x20000 mouse, 0x40000 joystick.
##
##   FcLocalisedText::Field (flux.dll @ 0x10028d80) is what turns that into
##   English: it SPLITS THE STRING ON '+', lowercases each token, looks it up in
##   the localised text table, substitutes the value if it is there and emits the
##   token literally if it is not. That is why "+, +" comes out as ", " and why
##   the whole thing is a chain of ids rather than words.
##
## So: "[ +device_text_keyboard+ +key_text_f8+ ]" -> "[ Keyboard F8 ]", and
## "[ +device_text_joystick+ +object_text_joybutton6+ ]" -> "[ Joystick
## Button 6 ]" -- non-keyboard controls use the object_text_* id table, not
## key_text_* (LoadLocalisedTextKeyTable @ 0x10070260).
##
## The bindings themselves are the shipped keymaps, which live in the INSTALL
## (configs/default.ini and configs/keyboard_only.ini -- they are not mirrored
## into data/ini). Format per docs/original.md 4b: a section per action, one
## line per binding, "Device, Control[, inverse][, SHIFT|ALT]".
##
## UNKNOWN: "key_text_undefined" (flux.dll @ 0x101447b4), the id returned for an
## unbound action, is ABSENT from the shipped text CSVs -- so the original would
## print the literal string. We print nothing instead; a bare id in a tutorial
## prompt is a shipped bug, not a behaviour worth reproducing.
const KEYMAP_INI := "configs/default.ini"

static var _keymap: Dictionary = {}      # action (lower) -> Array of binding rows
static var _strings: Dictionary = {}     # lowercased id -> localised text

static func _load_keymap(game_dir: String) -> void:
	if not _keymap.is_empty():
		return
	var f := FileAccess.open(game_dir.path_join(KEYMAP_INI), FileAccess.READ)
	if f == null:
		return
	var section := ""
	while not f.eof_reached():
		var line := f.get_line().strip_edges()
		if line.is_empty() or line.begins_with(";"):
			continue
		if line.begins_with("[") and line.ends_with("]"):
			section = line.substr(1, line.length() - 2).strip_edges().to_lower()
			if not _keymap.has(section):
				_keymap[section] = []
			continue
		if section.is_empty():
			continue
		var parts: Array = []
		for p in line.split(","):
			parts.append(str(p).strip_edges())
		(_keymap[section] as Array).append(parts)

static func _load_strings(base: String) -> void:
	if not _strings.is_empty():
		return
	var f := FileAccess.open(base.path_join("data/json/strings.json"), FileAccess.READ)
	if f == null:
		return
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if parsed is Dictionary:
		# the engine lowercases every token before it looks it up
		# (FcInputMapper::LoadLocalisedTextKeyTable, flux @ 0x10070260, calls
		# FcString::MakeLowerCase on each id), so we key on the lowercase form
		for k: String in (parsed as Dictionary):
			_strings[k.to_lower()] = str((parsed as Dictionary)[k])

static func _key_text(id: String) -> String:
	# FcLocalisedText::Field: a token that is not an id is emitted literally
	return str(_strings.get(id.to_lower(), id))

## One binding row -> "[ SHIFT - Keyboard M ]"
static func _form_key_string(row: Array) -> String:
	if row.size() < 2:
		return ""
	var device := str(row[0])
	var control := str(row[1])
	var mods: Array = []
	for i in range(2, row.size()):
		var m := str(row[i]).to_upper()
		match m:
			"SHIFT": mods.append(_key_text("modifier_text_shift"))
			"ALT":   mods.append(_key_text("modifier_text_alt"))
			"CTRL":  mods.append(_key_text("modifier_text_ctrl"))
			"INVERSE": pass   # an axis flag, not a modifier
	# FcInputMapper::FormKeyString (flux.dll @ 0x1006ab00) resolves a KEYBOARD
	# scancode through the key_text_* table (this+0x3c) but a mouse / joystick
	# control through the OBJECT name table (this+0x30), which
	# LoadLocalisedTextKeyTable (flux.dll @ 0x10070260) fills with object_text_*
	# ids (object_text_MouseButton1.., object_text_JoyButton1.., the axes and
	# POV hats). That is why "JoyButton6" is "object_text_joybutton6" =
	# "Button 6" in the shipped tables and key_text_joybutton6 does not exist.
	var dev_id := ""
	var key_prefix := "key_text_"
	var dl := device.to_lower()
	if dl.begins_with("keyboard"):
		dev_id = _key_text("device_text_keyboard")
	elif dl.begins_with("mouse"):
		dev_id = _key_text("device_text_mouse")
		key_prefix = "object_text_"
	elif dl.begins_with("joystick"):
		dev_id = _key_text("device_text_joystick")
		key_prefix = "object_text_"
	else:
		dev_id = device
	var key := _key_text(key_prefix + control)
	var out := "[ "
	for m in mods:
		out += "%s - " % m
	out += "%s %s ]" % [dev_id, key]
	return out

## The native. `action` is the engine action name; the result is one string.
static func key_combinations(base: String, game_dir: String, action: String) -> String:
	_load_keymap(game_dir)
	_load_strings(base)
	var rows: Array = _keymap.get(action.strip_edges().to_lower(), [])
	var parts: Array = []
	for row: Array in rows:
		var s := _form_key_string(row)
		if not s.is_empty():
			parts.append(s)
		if parts.size() >= 4:   # FcInputMapper::KeyString walks at most four
			break
	# the "+, +" separator localises to ", " (the ',' token is not a text id, so
	# FcLocalisedText::Field emits it literally between the two spaces)
	return ", ".join(PackedStringArray(parts))
