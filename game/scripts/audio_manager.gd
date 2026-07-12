class_name AudioManager
extends Node
# Original IW2 audio: SFX from the extracted resource WAVs, dynamic music
# from the GOG install's streams/audio/music MP3s (moods: ambient, action,
# tension, discovery — we start with ambient/action and crossfade).

const GAME_DIR := "C:/Program Files (x86)/GOG Galaxy/Games/Independence War 2"

var sfx_cache: Dictionary = {}
var players: Array[AudioStreamPlayer] = []
var engine_player: AudioStreamPlayer
var lds_player: AudioStreamPlayer
var music_a: AudioStreamPlayer
var music_b: AudioStreamPlayer
var music_current: AudioStreamPlayer
var current_mood := ""
var base_path := ""

func _ready() -> void:
	base_path = ProjectSettings.globalize_path("res://").path_join("../data/audio")
	for i in 8:
		var p := AudioStreamPlayer.new()
		add_child(p)
		players.append(p)
	engine_player = AudioStreamPlayer.new()
	engine_player.volume_db = -80.0
	add_child(engine_player)
	lds_player = AudioStreamPlayer.new()
	add_child(lds_player)
	music_a = AudioStreamPlayer.new()
	music_b = AudioStreamPlayer.new()
	music_a.bus = "Master"
	add_child(music_a)
	add_child(music_b)
	music_current = music_a
	var eng := _load_wav("audio/sfx/engine_startup.wav")
	if eng:
		eng.loop_mode = AudioStreamWAV.LOOP_FORWARD
		eng.loop_end = eng.data.size() / 2  # 16-bit mono frames; refined per file
		engine_player.stream = eng
		engine_player.play()

func _load_wav(rel: String) -> AudioStreamWAV:
	if rel in sfx_cache:
		return sfx_cache[rel]
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
	# level 0..1 -> volume; silent when coasting (space is quiet, IW2 wasn't)
	engine_player.volume_db = linear_to_db(clampf(level, 0.0, 1.0) * 0.5 + 0.001)

func music(mood: String) -> void:
	if mood == current_mood:
		return
	current_mood = mood
	var path := GAME_DIR.path_join("streams/audio/music").path_join("a1_%s.mp3" % mood)
	if not FileAccess.file_exists(path):
		return
	var f := FileAccess.open(path, FileAccess.READ)
	var stream := AudioStreamMP3.new()
	stream.data = f.get_buffer(f.get_length())
	stream.loop = true
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
