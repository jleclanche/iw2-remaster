class_name Comms
extends Node
# The original's comms flow: when a character speaks, their portrait plays
# in the MFD, the line's voice-over plays, and subtitles appear at the top
# of the HUD. EVERY speaker's portrait is a REAL-TIME 3D head: icComms loads
# lws:/avatars/<who>/<who>_anim01 (iwar2.dll string table) -- the pre-rendered
# movies are the PRISON DOSSIER busts, not comm portraits. Each anim01 scene
# (extracted verbatim from resource.zip) is: the head anchor at the origin,
# ambient white 0.25, a camera on the z axis (LightWave ZoomFactor -> hfov =
# 2*atan(1/zf)), a white point KEY light, and a coloured "HeadupGlow" wash.
# For cal / smith / maas / young_cal the glow FLICKERS through a shared
# 60-frame (25 fps -> 2.4 s) envelope -- a cockpit-readout light playing on
# the face: cool blue for the Cals, red for Smith, green for Maas. Clay alone
# has a steady RED lamp, a 19-key head-motion loop and a wider lens (zf 3.2).
# On top, icComms::RenderPortrait (0x100810e0) sways every head:
# yaw = -0.2 rad (DAT_101184ac) x cos(t x 0.6pi (DAT_1011c3e8)), with a
# coupled second-axis component at 0.25x (DAT_101191ec).

const GAME_DIR := "C:/Program Files (x86)/GOG Galaxy/Games/Independence War 2"
# dialogue speaker token -> rig key (ibuki is Az's pirate name; old_cal has no
# scene of his own -- cal_anim01 IS the older Cal, young_cal reuses the same
# anchor with its own camera/glow)
const SPEAKER_RIG := {
	"clay": "clay", "az": "az", "ibuki": "az", "jafs": "jafs",
	"smith": "smith", "lori": "lori", "maas": "maas",
	"cal": "cal", "old_cal": "cal", "young_cal": "young_cal",
}
# Per-speaker rigs from avatars/<who>/<who>_anim01.lws. Positions are Godot
# coords (z = -LWS z). white/glow: [pos, LWS intensity, LWS range]; glow adds
# [colour, flicker?]. cam: [pos, LWS pitch (deg down), ZoomFactor].
const RIGS := {
	"clay": {"gltf": "data/gltf/avatars/clay/clay_anchor.gltf",
		"cam": [Vector3(0, -0.016, 0.992), 0.0, 3.2],
		"white": [Vector3(0, 0, 0.576), 1.0, 2.0],
		"glow": [Vector3(0, 0, 0.455), 1.0, 0.8, Color(1, 0, 0), false]},
	"az": {"gltf": "data/gltf/avatars/az/az_anchor.gltf",
		"cam": [Vector3(0, 0.0788, 1.115), 6.6, 6.666667],
		"white": [Vector3(0, 0, 0.425), 1.0, 1.0],
		"glow": [Vector3(0, 0.001, 0.205), 0.3, 1.0, Color(1, 1, 0.8), false]},
	"cal": {"gltf": "data/gltf/avatars/cal/cal_anchor.gltf",
		"cam": [Vector3(0, 0.0398, 0.992), 5.0, 6.666667],
		"white": [Vector3(0, 0.001, 0.438), 1.0, 1.0],
		"glow": [Vector3(0, 0.001, 0.205), 0.2227, 1.0,
			Color(0.69, 0.973, 1.0), true]},
	"jafs": {"gltf": "data/gltf/avatars/jafs/jafs_anchor.gltf",
		"cam": [Vector3(0, 0.0648, 0.928), 5.0, 6.666667],
		"white": [Vector3(0, 0, 0.378), 1.0, 1.0],
		"glow": [Vector3(0, 0.001, 0.205), 0.5, 1.0, Color(1, 1, 0.757), false]},
	"lori": {"gltf": "data/gltf/avatars/lori/lori_anchor.gltf",
		"cam": [Vector3(0, 0.0039, 1.308), 3.8, 6.666667],
		"white": [Vector3(0, 0, 0.403), 1.0, 1.0],
		"glow": [Vector3(0, 0.001, 0.205), 0.3, 1.0, Color(1, 1, 0.769), false]},
	"maas": {"gltf": "data/gltf/avatars/maas/maas_anchor.gltf",
		"cam": [Vector3(0, 0.0128, 0.501), 5.0, 3.2],
		"white": [],                        # Maas' scene has NO white key light
		"glow": [Vector3(0, 0.001, 0.205), 3.712, 1.0, Color(0, 1, 0), true]},
	"smith": {"gltf": "data/gltf/avatars/smith/smith_anchor.gltf",
		"cam": [Vector3(0, 0.0568, 0.992), 5.0, 6.666667],
		"white": [Vector3(0, 0.001, 0.438), 1.0, 1.0],
		"glow": [Vector3(0, 0.001, 0.205), 1.1136, 1.0, Color(1, 0, 0), true]},
	"young_cal": {"gltf": "data/gltf/avatars/cal/cal_anchor.gltf",
		"cam": [Vector3(0, 0.0618, 1.398), 5.0, 6.666667],
		"white": [Vector3(0, 0, 0.410), 1.0, 1.0],
		"glow": [Vector3(0, 0.001, 0.205), 0.2376, 1.0,
			Color(0.69, 0.973, 1.0), true]},
}
# The shared HeadupGlow flicker envelope: [frame, level], 60 frames @ 25 fps,
# normalised to its peak (frame 52); per-speaker amplitude in RIGS
const GLOW_ENV := [
	[0, 0.0], [2, 0.569], [5, 0.4655], [7, 0.2672], [9, 0.3319], [11, 0.4224],
	[14, 0.0], [17, 0.8448], [18, 0.3879], [20, 0.5517], [21, 0.1121],
	[24, 0.3448], [26, 0.6379], [29, 0.4569], [30, 0.0], [31, 0.7759],
	[33, 0.0086], [36, 0.5948], [38, 0.3534], [39, 0.4741], [42, 0.5603],
	[45, 0.5431], [46, 0.362], [48, 0.1724], [52, 1.0], [54, 0.4483],
	[57, 0.3664], [59, 0.6422], [60, 0.0]]
# Clay_Anim01.lws ObjectMotion keys: frame, x, y, z (Godot, = -LWS z),
# heading, pitch, bank (degrees). 300-frame loop at the scene's 25 fps (the
# last key equals the first); the head also DRIFTS BACK from frame 151 on.
const CLAY_KEYS := [
	[0, 0.01, 0.0, 0.037, 13.9, -2.4, 0.2],
	[24, 0.01, 0.0, 0.037, -4.9, 1.6, 0.2],
	[43, 0.01, 0.0, 0.037, -5.3, -1.3, 0.2],
	[51, 0.01, 0.0, 0.037, -16.8, 6.7, -6.6],
	[69, 0.01, 0.0, 0.037, -3.0, 1.5, 0.8],
	[80, 0.01, 0.0, 0.037, -4.55, 0.23, 0.04],
	[87, 0.01, 0.0, 0.037, 7.7, 1.8, 5.7],
	[94, 0.01, 0.0, 0.037, 8.2, 1.8, 5.7],
	[109, 0.01, 0.0, 0.037, 8.2, 1.8, -1.1],
	[123, 0.01, 0.0, 0.037, -1.6, 1.1, -1.1],
	[151, 0.0175, -0.0015, 0.091, -1.6, 1.1, -1.1],
	[167, 0.018, -0.013, 0.102, -1.9, -8.9, -1.1],
	[210, 0.018, -0.013, 0.102, -16.1, -5.9, -6.0],
	[226, 0.018, -0.013, 0.102, -23.0, 4.7, -2.2],
	[248, 0.018, -0.013, 0.102, 22.0, -4.0, 12.4],
	[263, 0.018, -0.013, 0.102, 23.8, -4.9, 12.4],
	[272, 0.029, -0.013, 0.2005, 11.9, -11.3, -8.4],
	[285, 0.0345, -0.0135, 0.185, 17.6, -2.4, 0.8],
	[300, 0.01, 0.0, 0.037, 13.9, -2.4, 0.2],
]

var main: Node3D
var queue: Array = []          # {key, speaker, text}
var current: Dictionary = {}
var subtitle := ""
var speaker := ""
var voice: AudioStreamPlayer
var portrait: Control          # container the HUD positions in its panel
var head_rect: TextureRect
var head_view: SubViewport
var head_node: Node3D
var beam_mats: Array = []
var _rig_key := ""             # which speaker rig the viewport currently holds
var _glow_light: OmniLight3D
var _glow_amp := 0.0           # LWS intensity (peak, for flickering glows)
var _glow_flicker := false
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
	head_view = SubViewport.new()
	head_view.size = Vector2i(256, 186)
	head_view.own_world_3d = true
	head_view.transparent_bg = false
	head_view.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(head_view)
	_build_head_view("clay")
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

func _build_head_view(rig_key: String) -> void:
	# rebuild the portrait viewport for one speaker's anim01 scene (see RIGS)
	if _rig_key == rig_key:
		return
	_rig_key = rig_key
	for c in head_view.get_children():
		c.queue_free()
	head_node = null
	_head_mesh = null
	_glow_light = null
	beam_mats.clear()
	var rig: Dictionary = RIGS[rig_key]
	var cam := Camera3D.new()
	cam.position = rig["cam"][0]
	cam.rotation_degrees.x = -float(rig["cam"][1])   # LWS pitch: + looks down
	cam.fov = rad_to_deg(2.0 * atan(1.0 / float(rig["cam"][2])))
	head_view.add_child(cam)
	# ambient white 0.25 (every scene)
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0, 0, 0)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(1, 1, 1)
	env.ambient_light_energy = 0.25
	cam.environment = env
	# lights: energies map the LWS point intensities with the same factors the
	# proven Clay rig used (white x0.9, glow x2.2 -- Godot omni attenuation vs
	# LW linear falloff)
	var wl: Array = rig["white"]
	if not wl.is_empty():
		var white := OmniLight3D.new()
		white.position = wl[0]
		white.light_energy = 0.9 * float(wl[1])
		white.omni_range = float(wl[2])
		head_view.add_child(white)
	var gl: Array = rig["glow"]
	_glow_light = OmniLight3D.new()
	_glow_light.position = gl[0]
	_glow_amp = float(gl[1])
	_glow_flicker = bool(gl[4])
	_glow_light.light_color = gl[3]
	_glow_light.light_energy = 0.0 if _glow_flicker else 2.2 * _glow_amp
	_glow_light.omni_range = float(gl[2]) + 0.1
	head_view.add_child(_glow_light)
	head_node = main._load_gltf(str(rig["gltf"]))
	if head_node != null:
		if rig_key == "clay":
			head_node.position = Vector3(0.01, 0, 0.037)
		head_node.scale = Vector3.ONE * 1.686
		head_view.add_child(head_node)
		for mi in head_node.find_children("*", "MeshInstance3D", true, false):
			if (mi as MeshInstance3D).get_blend_shape_count() > 0:
				_head_mesh = mi
				break
	if rig_key != "clay":
		return
	# Clay only: the icBeamAvatar scanline planes behind him (clay_back,
	# additive, scrolling)
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

func say_key(key: String, who := "") -> void:
	# "a1_m01_dialogue_smith_calm_down" -> speaker smith, text from strings;
	# `who` overrides for multi-word speakers (young_cal, wolfgang...)
	var text := str(strings.get(key, ""))
	if text.is_empty():
		return
	if who == "":
		var parts := key.split("_")
		who = parts[3] if parts.size() > 3 and parts[2] == "dialogue" else "?"
		# multi-word speakers in key form
		for s in ["young_cal", "old_cal", "mercenary_leader"]:
			if ("dialogue_" + s + "_") in key:
				who = s
	queue.append({"key": key, "speaker": who, "text": text})

# --- conversation choices (iconversation.AddResponse / Ask) -----------------

var ask_options: Array = []   # {text, reply_key, response_key}
var ask_speaker := ""
var ask_question := ""
# Index of the last option the player picked. The POG scripts branch on it:
# icomms.Response() maps it back to the code the script attached to that option.
var chosen := -1

func ask(question_key: String, q_speaker: String, options: Array) -> void:
	# options: [[text_key, player_reply_key, npc_response_key-or-""], ...]
	say_key(question_key, q_speaker)
	ask_speaker = q_speaker
	ask_question = question_key
	for o in options:
		ask_options.append({
			"text": str(strings.get(o[0], o[0])),
			"reply": str(o[1]),
			"response": str(o[2]) if o.size() > 2 else ""})

func choosing() -> bool:
	return not ask_options.is_empty() and current.is_empty() and queue.is_empty()

func choose(i: int) -> void:
	if i < 0 or i >= ask_options.size():
		return
	var opt: Dictionary = ask_options[i]
	chosen = i
	ask_options.clear()
	main.audio.play("audio/gui/confirm.wav", -8.0)
	say_key(opt["reply"], "young_cal")
	if opt["response"] != "":
		say_key(opt["response"], ask_speaker)

func speaking() -> bool:
	return not current.is_empty() or not queue.is_empty() \
		or not ask_options.is_empty()

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
	# every speaker with an anim01 scene renders as a live 3D head; speakers
	# without one (minor NPCs) get a blank channel, like the original's
	# "no video feed"
	var rig_key: String = SPEAKER_RIG.get(speaker, "")
	if rig_key != "":
		_build_head_view(rig_key)
		head_rect.visible = true
	else:
		head_rect.visible = false

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

func _pose_head(t: float) -> void:
	# base pose: Clay's 300-frame motion loop at the scene's 25 fps (all other
	# speakers hold their single key); on top, icComms::RenderPortrait's sway:
	# yaw = -0.2 x cos(t x 0.6pi) with a coupled 0.25x second-axis component
	# (DAT_101184ac / DAT_1011c3e8 / DAT_101191ec)
	var q := Quaternion.IDENTITY
	if _rig_key == "clay":
		var frame := fposmod(t * 25.0, 300.0)
		var a: Array = CLAY_KEYS[0]
		var b: Array = CLAY_KEYS[-1]
		for i in CLAY_KEYS.size() - 1:
			if frame >= float(CLAY_KEYS[i][0]) and frame <= float(CLAY_KEYS[i + 1][0]):
				a = CLAY_KEYS[i]
				b = CLAY_KEYS[i + 1]
				break
		var span := maxf(float(b[0]) - float(a[0]), 1.0)
		var k := (frame - float(a[0])) / span
		head_node.position = Vector3(
			lerpf(float(a[1]), float(b[1]), k),
			lerpf(float(a[2]), float(b[2]), k),
			lerpf(float(a[3]), float(b[3]), k))
		var h := lerpf(float(a[4]), float(b[4]), k)
		var p := lerpf(float(a[5]), float(b[5]), k)
		var bank := lerpf(float(a[6]), float(b[6]), k)
		# LW -> glTF: quat = Ry(-H) * Rx(-P) * Rz(B)
		q = Quaternion(Vector3.UP, deg_to_rad(-h)) \
			* Quaternion(Vector3.RIGHT, deg_to_rad(-p)) \
			* Quaternion(Vector3.BACK, deg_to_rad(bank))
	var yaw := -0.2 * cos(t * 1.8849557)
	var sway := Quaternion(Vector3.UP, yaw) \
		* Quaternion(Vector3.RIGHT, yaw * 0.25)
	head_node.quaternion = sway * q

func _tick_glow(t: float) -> void:
	# the HeadupGlow flicker: shared 60-frame envelope at 25 fps, per-speaker
	# amplitude (steady glows keep their constant energy)
	if _glow_light == null or not _glow_flicker:
		return
	var frame := fposmod(t * 25.0, 60.0)
	var a: Array = GLOW_ENV[0]
	var b: Array = GLOW_ENV[-1]
	for i in GLOW_ENV.size() - 1:
		if frame >= float(GLOW_ENV[i][0]) and frame <= float(GLOW_ENV[i + 1][0]):
			a = GLOW_ENV[i]
			b = GLOW_ENV[i + 1]
			break
	var span := maxf(float(b[0]) - float(a[0]), 1.0)
	var lv := lerpf(float(a[1]), float(b[1]), (frame - float(a[0])) / span)
	_glow_light.light_energy = 2.2 * _glow_amp * lv

func _physics_process(delta: float) -> void:
	var live := portrait.visible and head_rect.visible
	head_view.render_target_update_mode = SubViewport.UPDATE_ALWAYS if live \
		else SubViewport.UPDATE_DISABLED
	if live and head_node != null:
		_head_t += delta
		_pose_head(_head_t)
		_tick_glow(_head_t)
		_lip_sync(delta)
		for i in beam_mats.size():
			var m: StandardMaterial3D = beam_mats[i]
			m.uv1_offset.x = fposmod(m.uv1_offset.x
				+ (2.0 if i == 0 else -2.0) * delta / 20.0, 1.0)
	if current.is_empty():
		if not queue.is_empty():
			_start(queue.pop_front())
		elif fast and not ask_options.is_empty():
			choose(0)  # checks auto-answer conversations
		return
	if voice.playing:
		return
	_gap -= delta
	if _gap <= 0.0:
		current = {}
		subtitle = ""
		speaker = ""
		# (the HUD closes the portrait panel itself once nothing is speaking)
