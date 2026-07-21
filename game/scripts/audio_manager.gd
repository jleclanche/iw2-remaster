class_name AudioManager
extends Node
# Original IW2 audio: SFX from the extracted resource WAVs, dynamic music
# from the GOG install's streams/audio/music MP3s (moods: ambient, action,
# tension, discovery — we start with ambient/action and crossfade).

const GAME_DIR := "C:/Program Files (x86)/GOG Galaxy/Games/Independence War 2"

var sfx_cache: Dictionary = {}
var players: Array[AudioStreamPlayer] = []
var engine_player: AudioStreamPlayer
var thruster_player: AudioStreamPlayer
var lds_player: AudioStreamPlayer
var music_a: AudioStreamPlayer
var music_b: AudioStreamPlayer
var music_current: AudioStreamPlayer
var sting_player: AudioStreamPlayer   # imusic PlayEvent's channel 1 (cymbal/timpani)
var current_mood := ""
var current_track := ""       # a one-off stream (the credits' badlands), not a mood
var base_path := ""
var _mood_before_track := ""
var _engine_hot := false

# The SOUND options screen's four registered floats (ipdagui.gd:936-939)
# write these engine properties -- fcSoundDeviceDA speech_volume /
# music_volume / effects_volume and fcMovieDeviceBink volume -- with
# immediate_update, so they are LIVE mixer levels, not restart settings.
# Modelled as audio buses; the values persist in the same config store the
# options rows write (user://pog_system.cfg).
const VOLUME_BUSES := {
	"speech": "Voice", "music": "Music", "effects": "Sfx", "movie": "Movie"}

func _make_buses() -> void:
	for kind: String in VOLUME_BUSES:
		var bus: String = VOLUME_BUSES[kind]
		if AudioServer.get_bus_index(bus) < 0:
			AudioServer.add_bus()
			AudioServer.set_bus_name(AudioServer.bus_count - 1, bus)
	var cfg := ConfigFile.new()
	cfg.load("user://pog_system.cfg")
	set_volume("speech", float(cfg.get_value("fcSoundDeviceDA", "speech_volume", 1.0)))
	set_volume("music", float(cfg.get_value("fcSoundDeviceDA", "music_volume", 1.0)))
	set_volume("effects", float(cfg.get_value("fcSoundDeviceDA", "effects_volume", 1.0)))
	set_volume("movie", float(cfg.get_value("fcMovieDeviceBink", "volume", 1.0)))

func set_volume(kind: String, v: float) -> void:
	var i := AudioServer.get_bus_index(str(VOLUME_BUSES.get(kind, "")))
	if i >= 0:
		AudioServer.set_bus_volume_db(i, linear_to_db(clampf(v, 0.0001, 1.0)))

func _ready() -> void:
	base_path = ProjectSettings.globalize_path("res://").path_join("../data/audio")
	_make_buses()
	for i in 8:
		var p := AudioStreamPlayer.new()
		p.bus = "Sfx"
		add_child(p)
		players.append(p)
	for i in 8:
		var p3 := AudioStreamPlayer3D.new()
		p3.bus = "Sfx"
		add_child(p3)
		players_3d.append(p3)
	# the tug's actual drive: main burn loop plus spool-up/down transients
	engine_player = AudioStreamPlayer.new()
	engine_player.volume_db = -80.0
	engine_player.bus = "Sfx"
	add_child(engine_player)
	var eng := _load_wav("audio/sfx/tug_main_burn_loop.wav")
	if eng:
		eng.loop_mode = AudioStreamWAV.LOOP_FORWARD
		engine_player.stream = eng
		engine_player.play()
	thruster_player = AudioStreamPlayer.new()
	thruster_player.volume_db = -80.0
	thruster_player.bus = "Sfx"
	add_child(thruster_player)
	var thr := _load_wav("audio/sfx/maneuvering_thruster.wav")
	if thr:
		thr.loop_mode = AudioStreamWAV.LOOP_FORWARD
		thruster_player.stream = thr
		thruster_player.play()
	lds_player = AudioStreamPlayer.new()
	lds_player.bus = "Sfx"
	add_child(lds_player)
	music_a = AudioStreamPlayer.new()
	music_b = AudioStreamPlayer.new()
	music_a.bus = "Music"
	music_b.bus = "Music"
	add_child(music_a)
	add_child(music_b)
	music_current = music_a
	sting_player = AudioStreamPlayer.new()
	sting_player.bus = "Music"
	add_child(sting_player)

func _load_wav(rel: String) -> AudioStreamWAV:
	if rel in sfx_cache:
		return sfx_cache[rel]
	# WAVs are normalized at extraction (tools/iw2/audio.py strips the
	# smpl/LIST chunks Godot's parser trips on)
	var path := base_path.path_join(rel)
	var stream: AudioStreamWAV = null
	if FileAccess.file_exists(path):
		stream = AudioStreamWAV.load_from_file(path)
	else:
		push_warning("missing sfx " + rel)
	sfx_cache[rel] = stream
	return stream

# --- positional one-shots (#19) ---------------------------------------------
# FcSoundNode's authored fields: min_range ("full volume within" -> Godot's
# unit_size, the convention the missile flight loops already use) and the
# pitch jitter -- OnPropertiesChanged (flux @ 0x100e2f50) rolls ONE uniform
# multiplier in [0.9, 1.1] (0x100ee2bc/0x100ee2c0) times the INI pitch_bend
# at NODE LOAD, not per trigger; a one-shot play is one node's life, so the
# roll happens here once per call. The falloff CURVE past min_range is not
# extracted (the fcSoundDeviceDA dll is not in the decomp set); Godot's
# inverse-distance law over unit_size stands in, consistent with DS3D's
# default rolloff, and is flagged in issue #19 until the device is read.
const JITTER_HI := 1.1   # flux @ 0x100ee2bc
const JITTER_LO := 0.9   # flux @ 0x100ee2c0

var players_3d: Array[AudioStreamPlayer3D] = []

func play_3d(rel: String, at: Vector3, min_range: float,
		volume_db := 0.0, pitch_bend := 1.0) -> void:
	var stream := _load_wav(rel)
	if stream == null:
		return
	for p in players_3d:
		if not p.playing:
			p.global_position = at
			p.unit_size = maxf(min_range, 1.0)
			p.stream = stream
			p.volume_db = volume_db
			p.pitch_scale = pitch_bend * randf_range(JITTER_LO, JITTER_HI)
			p.play()
			return

func play(rel: String, volume_db := 0.0) -> void:
	var stream := _load_wav(rel)
	if stream == null:
		return
	for p in players:
		if not p.playing:
			p.stream = stream
			p.volume_db = volume_db
			p.play()
			return

func play_loop(player: AudioStreamPlayer, rel: String, volume_db := 0.0) -> void:
	var stream := _load_wav(rel)
	if stream == null:
		return
	stream.loop_mode = AudioStreamWAV.LOOP_FORWARD
	player.stream = stream
	player.volume_db = volume_db
	player.play()

func set_engine_level(level: float) -> void:
	# level 0..1 -> volume; near-silent when coasting. Spool transients fire
	# when the main drive lights up or dies down, like the original tug.
	var hot := level > 0.12
	if hot and not _engine_hot:
		play("audio/sfx/tug_main_burn_spoolup.wav", -12.0)
	elif not hot and _engine_hot:
		play("audio/sfx/tug_main_burn_spooldown.wav", -14.0)
	_engine_hot = hot
	engine_player.volume_db = linear_to_db(clampf(level, 0.0, 1.0) * 0.5 + 0.001)

func set_thruster_level(level: float) -> void:
	thruster_player.volume_db = linear_to_db(clampf(level, 0.0, 1.0) * 0.4 + 0.001)

# Fallback mood player for sessions without the ported imusic monitor (debug
# starts, front end). In the campaign the monitor (pog/gen/imusic.gd, started
# per scripts.ini [Space] enter[]=iMusic.Initialise) owns the score and drives
# play_track() through the stream natives instead.
func music(mood: String) -> void:
	if mood == current_mood and current_track.is_empty():
		return
	current_mood = mood
	current_track = ""
	_crossfade("a1_%s.mp3" % mood, true)

# --- one-off tracks ---------------------------------------------------------
# The mood pairs above are the dynamic score. A handful of screens instead name
# ONE stream outright: icCreditScreen (iwar2.dll @ 0x10016180) streams
# "sound:/audio/music/badlands" -- a track with no a1_/a2_/a4_ act prefix and no
# mood sibling, so music() cannot reach it. play_track() names the file
# directly and remembers the mood it interrupted; restore_music() fades that
# mood back in when the screen pops.

func play_track(stem: String, loop := true) -> void:
	# a finished one-shot may be replayed (imusic's monitor re-issues the same
	# mood track when it ends and nothing changed) -- only a still-audible
	# duplicate is a no-op
	if current_track == stem and music_current != null and music_current.playing:
		return
	if current_track.is_empty():
		_mood_before_track = current_mood
	current_track = stem
	current_mood = ""
	_crossfade("%s.mp3" % stem, loop)

func restore_music() -> void:
	if current_track.is_empty():
		return
	current_track = ""
	var mood := _mood_before_track
	_mood_before_track = ""
	current_mood = ""     # force the crossfade even back to the same mood
	if not mood.is_empty():
		music(mood)
	else:
		music_current.stop()

## stream.Stop on the score channel stops the music outright -- imusic's
## local_0 stops channels 0/1/2 on Initialise/Terminate and nothing plays
## until a new track is started. The engine's Stop takes a fade FLAG with an
## engine-side fade duration (constant not recovered); the stand-in fade must
## outlast the imusic monitor's first 1 s poll, because the fading front-end
## score answering IsPlaying(0) is what lets the system-entry coin flip
## survive (imusic.pog:376-425, #45) -- a fade that ends at exactly 1 s races
## the poll.
func stop_track() -> void:
	current_track = ""
	current_mood = ""
	_mood_before_track = ""
	if music_current != null and music_current.playing:
		var fading := music_current
		var tw := create_tween()
		tw.tween_property(fading, "volume_db", -60.0, 2.0)
		tw.tween_callback(fading.stop)

## End-of-track probe for stream.IsPlaying(0)/IsPlayingURL(0, ...): imusic's
## monitor polls it to know when a one-shot mood finished (only the ambient
## mood loops -- imusic.pog:494 plays with loop = (mood == 1)).
func track_playing(stem: String) -> bool:
	return current_track == stem \
		and music_current != null and music_current.playing

## The score channel's REAL state, bookkeeping or not -- the front end's menu
## music and a mid-fade Stop both count (stream.IsPlaying(0), #45).
func score_playing() -> bool:
	return music_current != null and music_current.playing

## imusic.PlayEvent's stings (short/long_cymbal, soft/loud_timpani -- MP3s in
## the music dir) play on stream channel 1 ALONGSIDE the score; they must not
## displace the channel-0 track.
func play_sting(stem: String) -> void:
	var path := GAME_DIR.path_join("streams/audio/music").path_join(
		"%s.mp3" % stem)
	if not FileAccess.file_exists(path):
		return
	var f := FileAccess.open(path, FileAccess.READ)
	var stream := AudioStreamMP3.new()
	stream.data = f.get_buffer(f.get_length())
	sting_player.stream = stream
	sting_player.volume_db = -8.0
	sting_player.play()

func sting_playing() -> bool:
	return sting_player != null and sting_player.playing

func _crossfade(file: String, loop: bool) -> void:
	var path := GAME_DIR.path_join("streams/audio/music").path_join(file)
	if not FileAccess.file_exists(path):
		return
	var f := FileAccess.open(path, FileAccess.READ)
	var stream := AudioStreamMP3.new()
	stream.data = f.get_buffer(f.get_length())
	stream.loop = loop
	var next := music_b if music_current == music_a else music_a
	next.stream = stream
	next.volume_db = -18.0
	next.play()
	var fading := music_current
	music_current = next
	var tw := create_tween()
	tw.tween_property(next, "volume_db", -8.0, 2.0)
	tw.parallel().tween_property(fading, "volume_db", -60.0, 2.0)
	tw.tween_callback(fading.stop)
