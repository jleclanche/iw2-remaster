class_name Comms
extends Node
# The original's comms flow: when a character speaks, their portrait video
# plays in the MFD, the line's voice-over WAV plays, and subtitles appear
# at the top of the HUD (manual, MFD section). Dialogue keys map 1:1 to
# streams/audio/speech/<key>.wav and to the localized subtitle text.

const GAME_DIR := "C:/Program Files (x86)/GOG Galaxy/Games/Independence War 2"
const PORTRAITS := {
	"clay": "ocal", "cal": "ycal", "az": "az", "jafs": "jaffs",
	"smith": "smith", "lori": "lori", "ibuki": "az",
}

var main: Node3D
var queue: Array = []          # {key, speaker, text}
var current: Dictionary = {}
var subtitle := ""
var speaker := ""
var voice: AudioStreamPlayer
var portrait: VideoStreamPlayer  # rendered into the HUD MFD
var strings: Dictionary = {}
var fast := false  # checks: skip VO playback, minimal gaps
var _gap := 0.0

func _ready() -> void:
	voice = AudioStreamPlayer.new()
	voice.volume_db = -2.0
	add_child(voice)
	portrait = VideoStreamPlayer.new()
	portrait.visible = false
	portrait.loop = true
	portrait.size = Vector2(200, 112)
	# main reparents this into the HUD's MFD panel
	var f := FileAccess.open(main._base().path_join("data/json/strings.json"),
		FileAccess.READ)
	if f != null:
		strings = JSON.parse_string(f.get_as_text())

func say_key(key: String) -> void:
	# "a1_m01_dialogue_smith_calm_down" -> speaker smith, text from strings
	var text := str(strings.get(key, ""))
	if text.is_empty():
		return
	var parts := key.split("_")
	var who := parts[3] if parts.size() > 3 and parts[2] == "dialogue" else "?"
	queue.append({"key": key, "speaker": who, "text": text})

func speaking() -> bool:
	return not current.is_empty() or not queue.is_empty()

func _start(entry: Dictionary) -> void:
	current = entry
	speaker = str(entry["speaker"])
	subtitle = str(entry["text"])
	print("COMMS: [", speaker, "] ", subtitle.left(40))
	var ogg: String = main._base().path_join(
		"data/audio/speech/%s.ogg" % entry["key"])
	if fast:
		_gap = 0.05
	elif FileAccess.file_exists(ogg):
		voice.stream = AudioStreamOggVorbis.load_from_file(ogg)
		voice.play()
		_gap = 0.6
	else:
		_gap = maxf(2.0, subtitle.length() * 0.05)  # unvoiced: read time
	var stem: String = PORTRAITS.get(speaker, "")
	var ogv: String = main._base().path_join("data/movies/%s.ogv" % stem)
	if stem != "" and FileAccess.file_exists(ogv):
		var vs := VideoStreamTheora.new()
		vs.file = ogv
		portrait.stream = vs
		portrait.play()

func _physics_process(delta: float) -> void:
	if portrait.visible and portrait.is_playing():
		var tex := portrait.get_video_texture()
		if tex != null and tex.get_size().x > 0:
			var k := minf(216.0 / tex.get_size().x, 100.0 / tex.get_size().y)
			portrait.scale = Vector2(k, k)
	if current.is_empty():
		if not queue.is_empty():
			_start(queue.pop_front())
		return
	if voice.playing:
		return
	_gap -= delta
	if _gap <= 0.0:
		current = {}
		subtitle = ""
		speaker = ""
		if queue.is_empty():
			portrait.stop()
			portrait.visible = false
