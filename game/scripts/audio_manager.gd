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
var current_mood := ""
var current_track := ""       # a one-off stream (the credits' badlands), not a mood
var base_path := ""
var _mood_before_track := ""
var _engine_hot := false

func _ready() -> void:
	base_path = ProjectSettings.globalize_path("res://").path_join("../data/audio")
	for i in 8:
		var p := AudioStreamPlayer.new()
		add_child(p)
		players.append(p)
	# the tug's actual drive: main burn loop plus spool-up/down transients
	engine_player = AudioStreamPlayer.new()
	engine_player.volume_db = -80.0
	add_child(engine_player)
	var eng := _load_wav("audio/sfx/tug_main_burn_loop.wav")
	if eng:
		eng.loop_mode = AudioStreamWAV.LOOP_FORWARD
		engine_player.stream = eng
		engine_player.play()
	thruster_player = AudioStreamPlayer.new()
	thruster_player.volume_db = -80.0
	add_child(thruster_player)
	var thr := _load_wav("audio/sfx/maneuvering_thruster.wav")
	if thr:
		thr.loop_mode = AudioStreamWAV.LOOP_FORWARD
		thruster_player.stream = thr
		thruster_player.play()
	lds_player = AudioStreamPlayer.new()
	add_child(lds_player)
	music_a = AudioStreamPlayer.new()
	music_b = AudioStreamPlayer.new()
	music_a.bus = "Master"
	add_child(music_a)
	add_child(music_b)
	music_current = music_a

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
	if current_track == stem:
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
