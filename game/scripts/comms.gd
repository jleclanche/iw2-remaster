class_name Comms
extends Node
# The original's comms flow: when a character speaks, their portrait plays
# in the MFD, the line's voice-over plays, and subtitles appear at the top
# of the HUD. Portraits: Clay is a REAL-TIME 3D head (avatars/clay/
# Clay_Anim01.lws — anchor model, 10 s head-motion loop, red + white point
# lights, icBeamAvatar scanline planes over clay_back). The other
# characters use their pre-rendered movie loops (az/jaffs/lori/ycal/ocal/
# smith biks). Dialogue keys map 1:1 to streams/audio/speech/<key>.wav.

const GAME_DIR := "C:/Program Files (x86)/GOG Galaxy/Games/Independence War 2"
const PORTRAITS := {
	"cal": "ycal", "az": "az", "jafs": "jaffs",
	"smith": "smith", "lori": "lori", "ibuki": "az",
}
# Clay_Anim01.lws ObjectMotion keys: frame, heading, pitch, bank (degrees)
const CLAY_KEYS := [
	[0, 13.9, -2.4, 0.2], [24, -4.9, 1.6, 0.2], [43, -5.3, -1.3, 0.2],
	[51, -16.8, 6.7, -6.6], [69, -3.0, 1.5, 0.8], [80, -4.55, 0.23, 0.04],
	[87, 7.7, 1.8, 5.7], [94, 8.2, 1.8, 5.7], [109, 8.2, 1.8, -1.1],
	[123, -1.6, 1.1, -1.1], [151, -1.6, 1.1, -1.1], [167, -1.9, -8.9, -1.1],
	[210, -16.1, -5.9, -6.0], [226, -23.0, 4.7, -2.2], [248, 22.0, -4.0, 12.4],
	[263, 23.8, -4.9, 12.4], [272, 11.9, -11.3, -8.4], [285, 17.6, -2.4, 0.8],
	[300, 13.9, -2.4, 0.2],
]

var main: Node3D
var queue: Array = []          # {key, speaker, text}
var current: Dictionary = {}
var subtitle := ""
var speaker := ""
var voice: AudioStreamPlayer
var portrait: Control          # container the HUD positions in its panel
var video: VideoStreamPlayer
var head_rect: TextureRect
var head_view: SubViewport
var head_node: Node3D
var beam_mats: Array = []
var strings: Dictionary = {}
var fast := false  # checks: skip VO playback, minimal gaps
var _gap := 0.0
var _head_t := 0.0
var _head_mesh: MeshInstance3D          # blend-shaped face (DELT morphs)
var _spectrum: AudioEffectSpectrumAnalyzerInstance
var _mouth := 0.0

func _ready() -> void:
	# voice goes through its own bus with a spectrum analyzer so the 3D
	# head can flap its mouth to the VO amplitude (the original's
	# primitive lip sync over the DELT face morphs)
	var bus := AudioServer.bus_count
	AudioServer.add_bus(bus)
	AudioServer.set_bus_name(bus, "Voice")
	AudioServer.set_bus_send(bus, "Master")
	AudioServer.add_bus_effect(bus, AudioEffectSpectrumAnalyzer.new(), 0)
	_spectrum = AudioServer.get_bus_effect_instance(bus, 0)
	voice = AudioStreamPlayer.new()
	voice.volume_db = -2.0
	voice.bus = "Voice"
	add_child(voice)
	portrait = Control.new()
	portrait.visible = false
	portrait.custom_minimum_size = Vector2(204, 148)
	portrait.size = Vector2(204, 148)
	portrait.clip_contents = true
	video = VideoStreamPlayer.new()
	video.loop = true
	video.expand = true
	video.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	portrait.add_child(video)
	_build_head_view()
	head_rect = TextureRect.new()
	head_rect.texture = head_view.get_texture()
	head_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	head_rect.stretch_mode = TextureRect.STRETCH_SCALE
	head_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	portrait.add_child(head_rect)
	# main reparents `portrait` into the HUD's comm panel
	var f := FileAccess.open(main._base().path_join("data/json/strings.json"),
		FileAccess.READ)
	if f != null:
		strings = JSON.parse_string(f.get_as_text())

func _build_head_view() -> void:
	# the Clay_Anim01 scene: head anchor, camera close in, white + red point
	# lights, scanline beam planes behind (clay_back, additive, scrolling)
	head_view = SubViewport.new()
	head_view.size = Vector2i(256, 186)
	head_view.own_world_3d = true
	head_view.transparent_bg = false
	head_view.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(head_view)
	var cam := Camera3D.new()
	cam.position = Vector3(0, -0.016, 0.992)
	cam.fov = 24.0
	head_view.add_child(cam)
	var white := OmniLight3D.new()
	white.position = Vector3(0, 0, 0.576)
	white.omni_range = 2.0
	white.light_energy = 0.9
	head_view.add_child(white)
	var red := OmniLight3D.new()
	red.position = Vector3(0, 0, 0.455)
	red.omni_range = 0.9
	red.light_color = Color(1, 0, 0)
	red.light_energy = 2.2
	head_view.add_child(red)
	head_node = main._load_gltf("data/gltf/avatars/clay/clay_anchor.gltf")
	if head_node != null:
		head_node.position = Vector3(0.01, 0, 0.037)
		head_node.scale = Vector3.ONE * 1.686
		head_view.add_child(head_node)
		for mi in head_node.find_children("*", "MeshInstance3D", true, false):
			if (mi as MeshInstance3D).get_blend_shape_count() > 0:
				_head_mesh = mi
				break
	var beam_path: String = main._base().path_join(
		"data/textures/images/sfx/clay_back.png")
	if FileAccess.file_exists(beam_path):
		var img := Image.load_from_file(beam_path)
		var tex := ImageTexture.create_from_image(img)
		for side in [-1.0, 1.0]:
			var mat := StandardMaterial3D.new()
			mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
			mat.albedo_texture = tex
			mat.cull_mode = BaseMaterial3D.CULL_DISABLED
			mat.uv1_scale = Vector3(20, 1, 1)
			var mesh := QuadMesh.new()
			mesh.size = Vector2(1.2, 0.85)
			mesh.material = mat
			var mi := MeshInstance3D.new()
			mi.mesh = mesh
			mi.position = Vector3(0.34 * side, 0, -0.2)
			head_view.add_child(mi)
			beam_mats.append(mat)

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
	if speaker == "clay":
		# Clay is the ship's AI: rendered live, red hologram style
		head_rect.visible = true
		video.visible = false
		video.stop()
		return
	head_rect.visible = false
	var stem: String = PORTRAITS.get(speaker, "")
	var ogv: String = main._base().path_join("data/movies/%s.ogv" % stem)
	if stem != "" and FileAccess.file_exists(ogv):
		var vs := VideoStreamTheora.new()
		vs.file = ogv
		video.stream = vs
		video.visible = true
		video.play()
	else:
		video.visible = false

func _lip_sync(delta: float) -> void:
	# primitive lip sync, like the original: voice energy opens the mouth
	# (blend shapes exported from the PSO DELT face morphs)
	if _head_mesh == null:
		return
	var want := 0.0
	if voice.playing and _spectrum != null:
		var mag := _spectrum.get_magnitude_for_frequency_range(180.0, 3500.0)
		want = clampf(mag.length() * 22.0, 0.0, 1.0)
	_mouth += (want - _mouth) * minf(delta / 0.045, 1.0)
	var n := _head_mesh.get_blend_shape_count()
	if n > 0:
		_head_mesh.set_blend_shape_value(0, _mouth)
	if n > 1:
		# flicker a secondary viseme at speech peaks so it reads as talking
		_head_mesh.set_blend_shape_value(1,
			maxf(_mouth - 0.55, 0.0) * (0.5 + 0.5 * sin(_head_t * 23.0)))

func _clay_pose(t: float) -> void:
	# evaluate the original 10 s head-motion loop (30 fps, 300 frames)
	var frame := fposmod(t * 30.0, 300.0)
	var a: Array = CLAY_KEYS[0]
	var b: Array = CLAY_KEYS[-1]
	for i in CLAY_KEYS.size() - 1:
		if frame >= float(CLAY_KEYS[i][0]) and frame <= float(CLAY_KEYS[i + 1][0]):
			a = CLAY_KEYS[i]
			b = CLAY_KEYS[i + 1]
			break
	var span := maxf(float(b[0]) - float(a[0]), 1.0)
	var k := (frame - float(a[0])) / span
	var h := lerpf(float(a[1]), float(b[1]), k)
	var p := lerpf(float(a[2]), float(b[2]), k)
	var bank := lerpf(float(a[3]), float(b[3]), k)
	# LW -> glTF: quat = Ry(-H) * Rx(-P) * Rz(B)
	var q := Quaternion(Vector3.UP, deg_to_rad(-h)) \
		* Quaternion(Vector3.RIGHT, deg_to_rad(-p)) \
		* Quaternion(Vector3.BACK, deg_to_rad(bank))
	head_node.quaternion = q

func _physics_process(delta: float) -> void:
	var live := portrait.visible and head_rect.visible
	head_view.render_target_update_mode = SubViewport.UPDATE_ALWAYS if live \
		else SubViewport.UPDATE_DISABLED
	if live and head_node != null:
		_head_t += delta
		_clay_pose(_head_t)
		_lip_sync(delta)
		for i in beam_mats.size():
			var m: StandardMaterial3D = beam_mats[i]
			m.uv1_offset.x = fposmod(m.uv1_offset.x
				+ (2.0 if i == 0 else -2.0) * delta / 20.0, 1.0)
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
			video.stop()
			video.visible = false
