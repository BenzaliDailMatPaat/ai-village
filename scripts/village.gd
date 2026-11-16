extends Node3D
## AI Village (3D): a KayKit hex island where each n8n agent is a villager.
## Asks the local "19 Village Status" webhook for news every 10 s.
##
## Controls: Tab = walk / monitor. T (walk mode, next to a villager) = talk (v3). Monitor: right-drag or Q/E to orbit, wheel to zoom,
## R = slow turntable. Walk: WASD / arrows. F9 or top button = demo failure. F5 = refresh.
## Command line (after --): --feed=<url> --mode=walk|monitor --demo=<key>
##   --demo-off-after=<s>  --shot=<file.png> --shot-after=<s>  --yaw=<degrees>

const Villager := preload("res://scripts/villager.gd")

const KAY := "res://assets/kaykit/"
const HEX := KAY + "hexagon/"
const ANIM_FILES := ["General", "MovementBasic", "Simulation", "Tools", "CombatRanged"]
const LOOPING := ["Idle_A", "Idle_B", "Walking_A", "Running_A", "Hammering", "Cheering",
	"Ranged_Magic_Spellcasting", "Interact", "Lie_Idle", "Sit_Floor_Idle", "Working_A"]

const LAND_RADIUS := 5       # hexes of grass from the centre
const SEA_RADIUS := 8        # water around the island
const SQRT3 := 1.7320508
const POLL_SECONDS := 10.0
const DEFAULT_FEED := "http://127.0.0.1:5678/webhook/village-status"
const PANEL_WIDTH := 330.0
const DEMO_CYCLE := ["", "sorter", "planner", "deep", "ask"]

# The cast. hex = where its building stands (axial hex coordinates).
const CAST := [
	{"key": "sorter", "cls": "Paladin", "title": "01 Inbox Sorter", "model": "Knight",
		"hex": Vector2i(-3, 0), "building": "building_barracks_blue", "work": "Hammering",
		"gear": {"handslot.r": "sword_1handed", "handslot.l": "shield_badge_color"}, "prop": "weaponrack"},
	{"key": "planner", "cls": "Bard", "title": "02 Daily Planner", "model": "Ranger",
		"hex": Vector2i(0, -3), "building": "building_tavern_blue", "work": "Cheering",
		"gear": {"handslot.r": "mug_full"}, "prop": "barrel"},
	{"key": "deep", "cls": "Mage", "title": "06 Deep Research", "model": "Mage",
		"hex": Vector2i(3, -3), "building": "building_tower_A_blue", "work": "Ranged_Magic_Spellcasting",
		"gear": {"handslot.r": "wand", "handslot.l": "spellbook_open"}, "prop": "crate_A_small"},
	{"key": "ask", "cls": "Sage", "title": "07 Ask Notes", "model": "Rogue",
		"hex": Vector2i(3, 0), "building": "building_windmill_blue", "work": "Interact",
		"gear": {"handslot.l": "spellbook_closed"}, "prop": "sack"},
]
const CHURCH_HEX := Vector2i(-2, 4)

var _feed_url := DEFAULT_FEED
var _demo := ""
var _mode := "monitor"
var _shot_path := ""
var _shot_after := 4.0
var _test_job := ""    # --job=<agent>:<input> gives a job for testing
var _test_talk := ""   # --talk=<agent>:<message> opens a chat for testing

var _scenes := {}
var _libraries := {}
var _anim_index := {}
var _villagers: Array = []
var _cleric: Node3D
var _player: Node3D
var _clouds: Array[Node3D] = []
var _cam: Camera3D
var _yaw := 0.0
var _monitor_dist := 21.0
var _walk_dist := 9.0
var _focus := Vector3.ZERO
var _orbiting := false
var _turntable := false
var _http: HTTPRequest
var _bar: Label
var _panel: PanelContainer
var _panel_rows := {}
var _mode_button: Button
var _demo_button: Button
var _feed_text := "connecting..."

# v3 talk
const TALK_RANGE := 2.0
var _talk_http: HTTPRequest
var _talk_url := ""
var _talk_with: Node3D = null    # villager in the open chat
var _near: Node3D = null         # villager close enough to talk to
var _waiting := false
var _history: Array[String] = []
var _hint: Label
var _chat: PanelContainer
var _chat_title: Label
var _chat_log: RichTextLabel
var _chat_input: LineEdit

# v2 jobs (22 Village Jobs)
const JOB_LABELS := {
	"sorter": "Job: sort inbox now",
	"planner": "Job: re-plan today",
	"deep": "Job: research (type topic)",
	"ask": "Job: ask notes (type question)",
}
var _job_http: HTTPRequest
var _job_url := ""
var _job_button: Button
var _job_for: Node3D = null
var _plan_armed := false

# Small talk between villagers (code-written lines from real status, free)
var _convo := {}                 # {a, b, lines, i, phase, t}
var _next_convo := 12.0
var _overheard: Array[String] = []
var _overheard_label: Label


func _ready() -> void:
	_read_args()
	_build_environment()
	_load_animations()
	_build_map()
	_build_people()
	_build_ui()
	_cam = Camera3D.new()
	_cam.fov = 38.0
	add_child(_cam)
	_set_mode(_mode)
	_focus = _focus_target()
	_setup_feed()
	if _shot_path != "":
		get_tree().create_timer(_shot_after).timeout.connect(_take_shot)
	if _test_talk != "":
		get_tree().create_timer(12.0 if _demo != "" else 2.0).timeout.connect(_run_test_talk)


func _read_args() -> void:
	for arg in OS.get_cmdline_user_args():
		var kv: PackedStringArray = arg.trim_prefix("--").split("=", true, 1)
		var value := kv[1] if kv.size() > 1 else ""
		match kv[0]:
			"feed": _feed_url = value
			"demo": _demo = value
			"mode": _mode = value
			"shot": _shot_path = value
			"shot-after": _shot_after = float(value)
			"yaw": _yaw = deg_to_rad(float(value))
			"talk": _test_talk = value
			"chatter-after": _next_convo = float(value)
			"job": _test_job = value
			"demo-off-after": get_tree().create_timer(float(value)).timeout.connect(_end_demo)


# ---------- world ----------

func _build_environment() -> void:
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color("5d9bd6")
	sky_mat.sky_horizon_color = Color("cde5f4")
	sky_mat.ground_horizon_color = Color("cde5f4")
	sky_mat.ground_bottom_color = Color("3b6f8f")
	var sky := Sky.new()
	sky.sky_material = sky_mat
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.45
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	env.ssao_enabled = true          # soft contact shadows in corners
	env.glow_enabled = true
	env.glow_intensity = 0.1
	var world_env := WorldEnvironment.new()
	world_env.environment = env
	add_child(world_env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-52, -38, 0)
	sun.light_energy = 0.95
	sun.light_color = Color("fff3e0")
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 70.0
	add_child(sun)


## Load the shared animation files once. Every villager reuses these libraries.
func _load_animations() -> void:
	for f in ANIM_FILES:
		var scene: Node = load(KAY + "animations/Rig_Medium_%s.glb" % f).instantiate()
		var player: AnimationPlayer = scene.find_children("*", "AnimationPlayer", true, false)[0]
		var lib: AnimationLibrary = player.get_animation_library("")
		_libraries[f] = lib
		for anim_name in lib.get_animation_list():
			if not _anim_index.has(anim_name):
				_anim_index[anim_name] = "%s/%s" % [f, anim_name]
			if anim_name in LOOPING:
				lib.get_animation(anim_name).loop_mode = Animation.LOOP_LINEAR
		scene.free()


func _scene(path: String) -> PackedScene:
	if not _scenes.has(path):
		_scenes[path] = load(path)
	return _scenes[path]


func _place(path: String, pos: Vector3, yaw := 0.0, size := 1.0) -> Node3D:
	var n: Node3D = _scene(path).instantiate()
	n.position = pos
	n.rotation.y = yaw
	n.scale = Vector3.ONE * size
	add_child(n)
	return n


## Pointy-top hex grid: axial (q, r) -> world position. Tiles are 2 units wide.
func _hex_pos(h: Vector2i) -> Vector3:
	return Vector3(2.0 * (h.x + h.y * 0.5), 0.0, SQRT3 * h.y)


func _hex_dist(h: Vector2i) -> int:
	return (absi(h.x) + absi(h.y) + absi(h.x + h.y)) / 2


func _face_center(pos: Vector3) -> float:
	return atan2(-pos.x, -pos.z)


func _build_map() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 14  # same village every time (Brainstorm #14)
	var used := {Vector2i.ZERO: true, CHURCH_HEX: true}
	for c in CAST:
		used[c["hex"]] = true
	var trees := ["trees_A_medium", "trees_B_large", "tree_single_A", "trees_A_small", "trees_B_medium", "tree_single_B"]
	var rocks := ["hills_A_trees", "rock_single_A", "hill_single_B", "rock_single_C"]
	for q in range(-SEA_RADIUS, SEA_RADIUS + 1):
		for r in range(-SEA_RADIUS, SEA_RADIUS + 1):
			var h := Vector2i(q, r)
			var d := _hex_dist(h)
			if d > SEA_RADIUS:
				continue
			var pos := _hex_pos(h)
			var yaw := deg_to_rad(60.0 * rng.randi_range(0, 5))
			if d > LAND_RADIUS:
				_place(HEX + "tiles/base/hex_water.gltf", pos)
				continue
			_place(HEX + "tiles/base/hex_grass.gltf", pos)
			if used.has(h) or d < LAND_RADIUS - 1:
				continue
			# Outer two rings: a forest edge with some hills and mountains.
			var roll := rng.randf()
			if d == LAND_RADIUS and roll < 0.12:
				_place(HEX + "decoration/nature/mountain_%s_grass_trees.gltf" % ["A", "B", "C"][rng.randi() % 3], pos, yaw)
			elif roll < 0.62:
				_place(HEX + "decoration/nature/%s.gltf" % trees[rng.randi() % trees.size()], pos, yaw)
			elif roll < 0.74:
				_place(HEX + "decoration/nature/%s.gltf" % rocks[rng.randi() % rocks.size()], pos, yaw)
	# Buildings: your castle in the middle, one building per agent, the healer church.
	_place(HEX + "buildings/blue/building_castle_blue.gltf", Vector3.ZERO)
	for c in CAST:
		var pos := _hex_pos(c["hex"])
		var face := _face_center(pos)
		_place(HEX + "buildings/blue/%s.gltf" % c["building"], pos, face)
		var side := Vector3(cos(face), 0.0, -sin(face))
		_place(HEX + "decoration/props/%s.gltf" % c["prop"], pos + side * 0.75 + (-pos.normalized()) * 0.55, face)
	var church := _hex_pos(CHURCH_HEX)
	_place(HEX + "buildings/blue/building_church_blue.gltf", church, _face_center(church))
	_place(HEX + "decoration/props/flag_blue.gltf", church + Vector3(-0.9, 0, -0.6))
	_place(HEX + "buildings/blue/building_well_blue.gltf", Vector3(1.7, 0, 1.9), 0.4, 0.8)
	# A few clouds drifting over the island.
	for i in 5:
		var cloud := _place(HEX + "decoration/nature/cloud_big.gltf",
			Vector3.ZERO, rng.randf() * TAU, rng.randf_range(0.8, 1.4))
		cloud.set_meta("angle", TAU * i / 5.0)
		cloud.set_meta("radius", rng.randf_range(15.0, 18.0))
		cloud.position.y = rng.randf_range(4.0, 6.0)
		for m in cloud.find_children("*", "MeshInstance3D", true, false):
			(m as MeshInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_clouds.append(cloud)


func _build_people() -> void:
	var church := _hex_pos(CHURCH_HEX)
	var toward := (-church).normalized()           # from the church towards the castle
	var side := Vector3(toward.z, 0.0, -toward.x)
	var i := 0
	for c in CAST:
		var v = Villager.new()
		v.key = c["key"]
		v.cls = c["cls"]
		v.title = c["title"]
		v.work_anim = c["work"]
		v.anim_index = _anim_index
		var bpos := _hex_pos(c["hex"])
		var to_center := (-bpos).normalized()
		v.home = bpos + to_center * 1.45
		v.face_home = atan2(to_center.x, to_center.z)
		v.hut_spot = church + toward * 2.2 + side * ((i - 1.5) * 1.15)
		v.hut_face = atan2(side.x, side.z)
		add_child(v)
		v.setup(_scene(KAY + "adventurers/characters/%s.glb" % c["model"]), _libraries, _gear(c["gear"]))
		_villagers.append(v)
		i += 1
	_cleric = Villager.new()
	_cleric.key = "cleric"
	_cleric.cls = "Cleric"
	_cleric.title = "08 Error Alert + 17 Catch-up"
	_cleric.work_anim = "Ranged_Magic_Spellcasting"
	_cleric.anim_index = _anim_index
	_cleric.stays_home = true
	_cleric.home = church + toward * 1.15 + side * 1.6
	_cleric.face_home = atan2(toward.x, toward.z)
	add_child(_cleric)
	_cleric.setup(_scene(KAY + "adventurers/characters/Barbarian.glb"), _libraries, _gear({"handslot.r": "staff"}))
	# You, the Guild Master: a hooded assassin with two daggers.
	_player = Villager.new()
	_player.key = "you"
	_player.cls = "You"
	_player.player_controlled = true
	_player.anim_index = _anim_index
	_player.home = Vector3(0, 0, 2.4)
	_player.face_home = 0.0
	add_child(_player)
	_player.setup(_scene(KAY + "adventurers/characters/Rogue_Hooded.glb"), _libraries, _gear({"handslot.r": "dagger", "handslot.l": "dagger"}))


func _gear(spec: Dictionary) -> Dictionary:
	var out := {}
	for bone in spec:
		out[bone] = _scene(KAY + "adventurers/accessories/%s.gltf" % spec[bone])
	return out


# ---------- UI ----------

func _build_ui() -> void:
	var ui := CanvasLayer.new()
	add_child(ui)
	var top := PanelContainer.new()
	top.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	ui.add_child(top)
	var row := HBoxContainer.new()
	top.add_child(row)
	_bar = Label.new()
	_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_bar.add_theme_font_size_override("font_size", 16)
	row.add_child(_bar)
	_demo_button = Button.new()
	_demo_button.focus_mode = Control.FOCUS_NONE
	_demo_button.pressed.connect(_cycle_demo)
	row.add_child(_demo_button)
	_mode_button = Button.new()
	_mode_button.focus_mode = Control.FOCUS_NONE  # keeps Tab free for the toggle
	_mode_button.pressed.connect(_toggle_mode)
	row.add_child(_mode_button)

	_panel = PanelContainer.new()
	_panel.set_anchors_and_offsets_preset(Control.PRESET_RIGHT_WIDE)
	_panel.offset_left = -PANEL_WIDTH
	_panel.offset_top = 44
	ui.add_child(_panel)
	var list := VBoxContainer.new()
	list.add_theme_constant_override("separation", 10)
	_panel.add_child(list)
	var head := Label.new()
	head.text = "Village status"
	head.add_theme_font_size_override("font_size", 20)
	list.add_child(head)
	for v in _villagers + [_cleric]:
		var l := Label.new()
		l.add_theme_font_size_override("font_size", 15)
		list.add_child(l)
		_panel_rows[v.key] = l
	_overheard_label = Label.new()
	_overheard_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_overheard_label.custom_minimum_size = Vector2(PANEL_WIDTH - 20, 0)
	_overheard_label.add_theme_font_size_override("font_size", 13)
	_overheard_label.add_theme_color_override("font_color", Color("cfd8e3"))
	_overheard_label.text = "Overheard:\n(nothing yet)"
	list.add_child(_overheard_label)
	var help := Label.new()
	help.text = "Tab: walk / monitor\nT: talk (walk mode, next to a villager)\nWASD or arrows: walk\nRight-drag or Q/E: turn camera\nWheel: zoom   R: turntable\nF9 / top button: demo failure\nF5: refresh now"
	help.add_theme_color_override("font_color", Color(0.72, 0.72, 0.72))
	list.add_child(help)
	for v in _villagers + [_cleric]:
		v.apply({"state": "unknown", "text": "connecting..."})
	_build_chat(ui)
	_refresh_ui()


## v3 talk UI: a hint ("T: talk to Mage") and a chat box at the bottom.
func _build_chat(ui: CanvasLayer) -> void:
	_hint = Label.new()
	_hint.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	_hint.offset_top = -70
	_hint.offset_left = -200
	_hint.offset_right = 200
	_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hint.add_theme_font_size_override("font_size", 20)
	_hint.add_theme_constant_override("outline_size", 6)
	_hint.add_theme_color_override("font_outline_color", Color.BLACK)
	_hint.visible = false
	ui.add_child(_hint)

	_chat = PanelContainer.new()
	_chat.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	_chat.offset_top = -290
	_chat.offset_left = 20
	_chat.offset_right = -20
	_chat.offset_bottom = -16
	_chat.visible = false
	ui.add_child(_chat)
	var col := VBoxContainer.new()
	_chat.add_child(col)
	_chat_title = Label.new()
	_chat_title.add_theme_font_size_override("font_size", 18)
	col.add_child(_chat_title)
	_chat_log = RichTextLabel.new()
	_chat_log.bbcode_enabled = true
	_chat_log.scroll_following = true
	_chat_log.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_chat_log.add_theme_font_size_override("normal_font_size", 16)
	col.add_child(_chat_log)
	var row := HBoxContainer.new()
	col.add_child(row)
	_chat_input = LineEdit.new()
	_chat_input.placeholder_text = "Say something... (Enter to send, Esc to leave)"
	_chat_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_chat_input.max_length = 400
	_chat_input.text_submitted.connect(_send_talk)
	row.add_child(_chat_input)
	_chat_button(row, "Send", func(): _send_talk(_chat_input.text))
	_chat_button(row, "What went wrong?", func(): _send_talk("What went wrong? How do I fix it?"))
	_job_button = Button.new()
	_job_button.focus_mode = Control.FOCUS_NONE
	_job_button.add_theme_color_override("font_color", Color("f2b84b"))
	_job_button.pressed.connect(_give_job)
	row.add_child(_job_button)
	# "Mark done": tell any villager what you finished; 16 Done ticks it off in your notes.
	var done_btn := Button.new()
	done_btn.text = "Mark done (type it)"
	done_btn.focus_mode = Control.FOCUS_NONE
	done_btn.add_theme_color_override("font_color", Color("7bd389"))
	done_btn.pressed.connect(func(): _give_job("done"))
	row.add_child(done_btn)
	_chat_button(row, "Leave (Esc)", func(): _close_chat())


func _chat_button(row: HBoxContainer, text: String, action: Callable) -> void:
	var btn := Button.new()
	btn.text = text
	btn.focus_mode = Control.FOCUS_NONE
	btn.pressed.connect(action)
	row.add_child(btn)


func _open_chat(v: Node3D) -> void:
	_talk_with = v
	v.talking = true
	v.face_point(_player.position)
	_history.clear()
	_chat_log.clear()
	_chat_title.text = "Talking to %s  ·  %s" % [v.cls, v.title]
	_end_convo()  # a villager in small talk stops to talk to you
	_chat_log.append_text("[i][color=#aaaaaa]%s turns to you. (%s)[/color][/i]\n" % [v.cls, v.status_text])
	# The villager speaks first: an instant line from its real status (no AI call, free).
	var hello := _greeting(v)
	_chat_log.append_text("[color=#f2b84b]%s:[/color] %s\n" % [v.cls, _bb(hello)])
	_history.append("%s: %s" % [v.cls, hello])
	v.set_bubble(hello)
	get_tree().create_timer(4.0).timeout.connect(func(): if _talk_with == v and not _waiting: v.set_bubble(""))
	_job_button.visible = JOB_LABELS.has(v.key)
	_job_button.text = JOB_LABELS.get(v.key, "")
	_plan_armed = false
	_chat.visible = true
	_hint.visible = false
	_chat_input.text = ""
	_chat_input.grab_focus()


func _close_chat() -> void:
	if _talk_with:
		_talk_with.talking = false
		_talk_with.set_bubble("")
	_talk_with = null
	_chat.visible = false
	_chat_input.release_focus()


const HELLO := {
	"Paladin": "Well met, Guild Master!",
	"Bard": "Hey hey, Guild Master!",
	"Mage": "Ah, the Guild Master approaches.",
	"Sage": "Greetings, Guild Master.",
	"Cleric": "Welcome, Guild Master.",
}


## First line when you press T, written by code from the villager's real status.
func _greeting(v: Node3D) -> String:
	var hi: String = HELLO.get(v.cls, "Hello!")
	if v == _cleric:
		var sick := _villagers.filter(func(x): return x.state == "failed").map(func(x): return x.cls)
		if v.state == "failed":
			return hi + " I'm not well myself, 08 or 17 failed. Ask me what went wrong."
		if sick.is_empty():
			return hi + " Everyone in the village is healthy today."
		return hi + " I'm healing the %s. Ask me how they are." % ", ".join(sick)
	var info: Dictionary = v.last_info
	match v.state:
		"failed":
			if info.get("demo", false):
				return "Ugh... I'm lying at the church (demo failure). Ask me what went wrong!"
			return "Ugh... my last run failed (%s). Ask me \"What went wrong?\" and I'll check the error." % str(info.get("last_run", "?"))
		"working":
			return hi + " I'm busy, my run is going right now. Ask away though."
		"idle":
			return hi + " Nobody has called on me yet. What do you need?"
		"ok":
			return hi + " I last ran %s, all good. What do you need?" % Villager.ago_text(int(info.get("ago_s", -1)))
	return hi + " I can't reach the village feed right now."


## v2: give the villager its job (22 Village Jobs). Sage and Mage use the text box as input.
func _give_job(job := "main", typed := "") -> void:
	var v := _talk_with
	if v == null or _job_for != null:
		return
	var input := typed if typed != "" else _chat_input.text.strip_edges()
	if job == "done":
		if input.length() < 3:
			_chat_log.append_text("[color=#aaaaaa](type what you finished in the box first, for example \"checked Equity Edge rules\")[/color]\n")
			return
		_chat_input.text = ""
		_chat_log.append_text("[color=#8ecbff]You:[/color] I did this: %s\n" % _bb(input))
		_job_for = v
		v.set_bubble("Let me check it off...")
		if _job_http.request(_job_url, ["Content-Type: application/json"], HTTPClient.METHOD_POST, JSON.stringify({"agent": v.key, "input": input, "job": "done"})) != OK:
			_on_job(HTTPRequest.RESULT_CANT_CONNECT, 0, PackedStringArray(), PackedByteArray())
		return
	if v.key in ["deep", "ask"] and input.length() < 3:
		_chat_log.append_text("[color=#aaaaaa](type %s in the box first, then press the job button)[/color]\n" % ("a topic" if v.key == "deep" else "a question"))
		return
	if v.key == "planner" and not _plan_armed:
		_plan_armed = true
		_job_button.text = "Sure? Overwrites today's plan"
		_chat_log.append_text("[color=#f2b84b]Bard:[/color] That rewrites today's plan in your Journal. Press again if you're sure.\n")
		return
	_chat_input.text = ""
	if v.key == "ask":
		_chat_log.append_text("[color=#8ecbff]You:[/color] %s\n" % _bb(input))
	else:
		_chat_log.append_text("[color=#8ecbff]You give a job:[/color] %s%s\n" % [_bb(JOB_LABELS[v.key].trim_prefix("Job: ").split(" (")[0]), (" \"" + _bb(input) + "\"") if input != "" else ""])
	_job_for = v
	v.job_busy = true
	v.set_bubble("On it!")
	var body := {"agent": v.key, "input": input, "confirm": _plan_armed}
	_plan_armed = false
	_job_button.text = JOB_LABELS[v.key]
	if _job_http.request(_job_url, ["Content-Type: application/json"], HTTPClient.METHOD_POST, JSON.stringify(body)) != OK:
		_on_job(HTTPRequest.RESULT_CANT_CONNECT, 0, PackedStringArray(), PackedByteArray())


func _on_job(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	var v := _job_for
	_job_for = null
	if v == null:
		return
	var data = null
	if result == HTTPRequest.RESULT_SUCCESS and code == 200:
		data = JSON.parse_string(body.get_string_from_utf8())
	if typeof(data) != TYPE_DICTIONARY:
		v.job_busy = false
		v.set_bubble("")
		if _talk_with == v:
			_chat_log.append_text("[color=#ff6b6b](job not started, HTTP %d. Is n8n running?)[/color]\n" % code)
		return
	var reply := str(data.get("reply", ""))
	if _talk_with == v:
		_chat_log.append_text("[color=#f2b84b]%s:[/color] %s\n" % [v.cls, _bb(reply)])
	var bubble := "Done!" if data.get("done", false) else ("Working on it!" if data.get("started", false) else "")
	if data.get("job", "") == "mark done":
		bubble = "Nice work!" if reply.contains("✅") or reply.to_lower().contains("marked") else "Hmm, which one?"
	v.set_bubble(bubble)
	get_tree().create_timer(4.0).timeout.connect(func(): if v != _talk_with or not _waiting: v.set_bubble(""))
	# Keep the work animation a little while; after that 19's "working" state takes over.
	var busy_for := 1.0 if data.get("done", false) or not data.get("started", false) else 25.0
	get_tree().create_timer(busy_for).timeout.connect(func(): v.job_busy = false)
	_poll()


## Recognise commands in a chat line. Returns {job, input} or {} for normal chat.
## "mark X as bought", "I bought X", "I did X", "done: X" -> Mark done (any villager).
## "ask: X" (Sage), "research: X" / "deep: X" (Mage), "sort the inbox" (Paladin) -> that villager's job.
func _chat_command(text: String) -> Dictionary:
	var low := text.to_lower().replace("'", "").replace("’", "").strip_edges()
	# A "done" command can be anywhere: "I have bought X", "I've finished X", "mark X as done", "done: X".
	var done_re := RegEx.new()
	done_re.compile("(?:^done:|\\bmark(?:ed)?\\b|\\bi(?:ve|\\s+have|\\s+just|\\s+already)*\\s+(?:did|done|finished|bought|got|checked|completed|paid|sent|fixed|cleaned)\\b)")
	if done_re.search(low):
		# Pick the sentence that names the task: words left after dropping command and filler words.
		var drop := RegEx.new()
		drop.compile("\\b(?:done|mark|marked|as|i|i've|ive|have|has|just|already|did|finished|bought|buy|got|checked|completed|complete|paid|sent|fixed|cleaned|it|that|this|them|the|a|an|my|our|some|all|of|on|for|please|both|remove|reminders?|tasks?|can|you|now|to)\\b")
		var sentences := low.replace("done:", "").split(".", false)
		var best := ""
		for s in sentences:
			for part in s.split("!", false):
				var what := " ".join(drop.sub(part, " ", true).split(" ", false)).strip_edges()
				if what.length() >= 3 and (best == "" or done_re.search(part)):
					best = what
					if done_re.search(part):
						break
			if best != "" and done_re.search(s):
				break
		if best != "":
			return {"job": "done", "input": best}
	var key: String = _talk_with.key
	if key == "ask":
		if low.begins_with("ask:"):
			return {"job": "main", "input": text.substr(4).strip_edges()}
		# The Sage's job IS answering from your notes, so questions go to 07 Ask Notes.
		# Only small talk about the Sage itself stays normal chat.
		var about_me := RegEx.new()
		about_me.compile("(went wrong|\\bfix\\b|how are you|your status|what do you do|who are you|are you ok|^hi\\b|^hey\\b|^hello\\b|thanks|thank you)")
		if about_me.search(low) == null and low.length() >= 6:
			return {"job": "main", "input": text}
	if key == "deep" and (low.begins_with("research:") or low.begins_with("deep:")):
		return {"job": "main", "input": text.substr(text.find(":") + 1).strip_edges()}
	if key == "sorter" and low.contains("sort") and low.contains("inbox"):
		return {"job": "main", "input": ""}
	return {}


static func _bb(text: String) -> String:
	return text.replace("[", "[lb]")  # so replies can't inject BBCode


func _send_talk(text: String) -> void:
	text = text.strip_edges()
	if _waiting or text == "" or _talk_with == null:
		return
	# Commands typed in the chat become real jobs (same words as Telegram). Everything else is chat.
	var cmd := _chat_command(text)
	if not cmd.is_empty():
		_chat_input.text = ""
		_give_job(cmd["job"], cmd["input"])
		return
	_chat_input.text = ""
	_chat_log.append_text("[color=#8ecbff]You:[/color] %s\n" % _bb(text))
	var body := {"agent": _talk_with.key, "message": text, "history": "\n".join(_history)}
	_history.append("Zali: " + text)
	_waiting = true
	_talk_with.set_bubble("...")
	var err := _talk_http.request(_talk_url, ["Content-Type: application/json"], HTTPClient.METHOD_POST, JSON.stringify(body))
	if err != OK:
		_on_talk(HTTPRequest.RESULT_CANT_CONNECT, 0, PackedStringArray(), PackedByteArray())


func _on_talk(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	_waiting = false
	if _talk_with == null:
		return
	_talk_with.set_bubble("")
	var data = null
	if result == HTTPRequest.RESULT_SUCCESS and code == 200:
		data = JSON.parse_string(body.get_string_from_utf8())
	if typeof(data) != TYPE_DICTIONARY:
		_chat_log.append_text("[color=#ff6b6b](no answer, HTTP %d. Is n8n running?)[/color]\n" % code)
		return
	var reply := str(data.get("reply", "..."))
	_chat_log.append_text("[color=#f2b84b]%s:[/color] %s\n" % [_talk_with.cls, _bb(reply)])
	var steps: Array = data.get("fix_steps", [])
	for i in steps.size():
		_chat_log.append_text("    [color=#7bd389]%d.[/color] %s\n" % [i + 1, _bb(str(steps[i]))])
	_chat_log.append_text("[font_size=12][color=#888888](%s)[/color][/font_size]\n" % _bb(str(data.get("brain", ""))))
	_history.append("%s: %s" % [_talk_with.cls, reply])
	while _history.size() > 6:
		_history.pop_front()


func _refresh_ui() -> void:
	var demo := "   DEMO: %s fails" % _demo if _demo != "" else ""
	_bar.text = "  AI Village   %s%s" % [_feed_text, demo]
	_demo_button.text = "Demo failure: %s" % (_demo if _demo != "" else "off")
	for v in _villagers + [_cleric]:
		var l: Label = _panel_rows[v.key]
		l.text = "%s  ·  %s\n    %s" % [v.cls, v.title, v.status_text]
		l.add_theme_color_override("font_color", Villager.STATE_COLORS.get(v.state, Color.WHITE))


# ---------- modes, camera, input ----------

func _toggle_mode() -> void:
	_set_mode("walk" if _mode == "monitor" else "monitor")


func _set_mode(m: String) -> void:
	_mode = m if m in ["walk", "monitor"] else "monitor"
	var walk := _mode == "walk"
	_panel.visible = not walk
	if not walk and _hint:
		_hint.visible = false
	_mode_button.text = "Monitor mode  [Tab]" if walk else "Walk mode  [Tab]"


func _focus_target() -> Vector3:
	if _mode == "walk":
		return _player.position + Vector3(0, 0.6, 0)
	# Shift the island left so the status panel does not cover it.
	var right := Basis(Vector3.UP, _yaw) * Vector3.RIGHT
	var view_w := 2.0 * _monitor_dist * tan(deg_to_rad(_cam.fov) / 2.0) * get_viewport().get_visible_rect().size.aspect()
	return Vector3(0, 0, 0.6) + right * (PANEL_WIDTH / 2.0) / get_viewport().get_visible_rect().size.x * view_w


func _update_camera(delta: float) -> void:
	var walk := _mode == "walk"
	_focus = _focus.lerp(_focus_target(), 1.0 - exp(-delta * 6.0))
	var pitch := deg_to_rad(-34.0 if walk else -48.0)
	var dist := _walk_dist if walk else _monitor_dist
	var offset := Basis(Vector3.UP, _yaw) * Basis(Vector3.RIGHT, pitch) * Vector3(0, 0, dist)
	_cam.position = _focus + offset
	_cam.look_at(_focus, Vector3.UP)


func _input(event: InputEvent) -> void:
	if _chat and _chat.visible:
		# While chatting, keys go to the text box. Only Esc (leave) is ours.
		if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
			_close_chat()
			get_viewport().set_input_as_handled()
		elif event is InputEventKey and event.keycode == KEY_TAB:
			get_viewport().set_input_as_handled()
		return
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_T:
				if _mode == "walk" and _near:
					_open_chat(_near)
					get_viewport().set_input_as_handled()
			KEY_TAB:
				_toggle_mode()
				get_viewport().set_input_as_handled()
			KEY_F9:
				_cycle_demo()
			KEY_F5:
				_poll()
			KEY_R:
				_turntable = not _turntable
	elif event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_RIGHT:
			_orbiting = event.pressed
		elif event.pressed and event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
			var f := 0.9 if event.button_index == MOUSE_BUTTON_WHEEL_UP else 1.1
			if _mode == "walk":
				_walk_dist = clampf(_walk_dist * f, 4.0, 16.0)
			else:
				_monitor_dist = clampf(_monitor_dist * f, 12.0, 45.0)
	elif event is InputEventMouseMotion and _orbiting:
		_yaw -= event.relative.x * 0.006


func _process(delta: float) -> void:
	var chatting := _chat.visible
	if chatting and _mode != "walk":
		_close_chat()
		chatting = false
	if not chatting and Input.is_physical_key_pressed(KEY_Q):
		_yaw += delta * 1.5
	if not chatting and Input.is_physical_key_pressed(KEY_E):
		_yaw -= delta * 1.5
	if _turntable and _mode == "monitor":
		_yaw += delta * 0.08
	if _mode == "walk" and chatting:
		_player.face_point(_talk_with.position)
		_player.drive(Vector3.ZERO, delta, 0.0)
	elif _mode == "walk":
		var input := Vector2(
			float(Input.is_physical_key_pressed(KEY_D) or Input.is_physical_key_pressed(KEY_RIGHT))
				- float(Input.is_physical_key_pressed(KEY_A) or Input.is_physical_key_pressed(KEY_LEFT)),
			float(Input.is_physical_key_pressed(KEY_S) or Input.is_physical_key_pressed(KEY_DOWN))
				- float(Input.is_physical_key_pressed(KEY_W) or Input.is_physical_key_pressed(KEY_UP)))
		var dir := Basis(Vector3.UP, _yaw) * Vector3(input.x, 0.0, input.y)
		_player.drive(dir, delta, 2.0 * LAND_RADIUS - 1.0)
		_update_near()
	else:
		_player.drive(Vector3.ZERO, delta, 0.0)
	for c in _clouds:
		var a: float = c.get_meta("angle") + delta * 0.02
		c.set_meta("angle", a)
		var rad: float = c.get_meta("radius")
		c.position = Vector3(cos(a) * rad, c.position.y, sin(a) * rad)
	_update_camera(delta)
	_convo_tick(delta)


# ---------- small talk between villagers ----------

func _free_for_chat(v: Node3D) -> bool:
	return v.state in ["ok", "idle"] and not v.talking and not v.wants_hut() and v != _talk_with


func _convo_tick(delta: float) -> void:
	if _convo.is_empty():
		_next_convo -= delta
		if _next_convo <= 0.0:
			_next_convo = randf_range(25.0, 45.0)
			_start_convo()
		return
	var a: Node3D = _convo["a"]
	var b: Node3D = _convo["b"]
	if not _free_for_chat(a) or not _free_for_chat(b):
		_end_convo()
		return
	_convo["t"] += delta
	if _convo["phase"] == "walk":
		if (not a.is_walking() and not b.is_walking()) or _convo["t"] > 25.0:
			a.face_point(b.position)
			b.face_point(a.position)
			_convo["phase"] = "talk"
			_convo["t"] = 99.0  # say the first line right away
		return
	if _convo["t"] < 3.8:
		return
	_convo["t"] = 0.0
	var lines: Array = _convo["lines"]
	var i: int = _convo["i"]
	if i >= lines.size():
		_end_convo()
		return
	var speaker: Node3D = lines[i][0]
	var other: Node3D = b if speaker == a else a
	speaker.set_bubble(lines[i][1])
	other.set_bubble("")
	_overheard.append("%s: %s" % [speaker.cls, lines[i][1]])
	while _overheard.size() > 4:
		_overheard.pop_front()
	_refresh_overheard()
	_convo["i"] = i + 1


func _start_convo() -> void:
	var free := _villagers.filter(func(v): return _free_for_chat(v))
	if free.size() < 2:
		return
	free.shuffle()
	var a: Node3D = free[0]
	var b: Node3D = free[1]
	# Meet halfway, but never inside the castle: push the spot out to the ring road.
	var mid: Vector3 = (a.home + b.home) / 2.0
	if mid.length() < 3.8:
		mid = (mid if mid.length() > 0.1 else a.home).normalized() * 3.8
	var side: Vector3 = (a.home - b.home).normalized()
	a.npc_chat = true
	b.npc_chat = true
	a.meet_at(mid + side * 0.6)
	b.meet_at(mid - side * 0.6)
	_convo = {"a": a, "b": b, "lines": _small_talk(a, b), "i": 0, "phase": "walk", "t": 0.0}


func _end_convo() -> void:
	if _convo.is_empty():
		return
	for v in [_convo["a"], _convo["b"]]:
		v.npc_chat = false
		if v != _talk_with:
			v.set_bubble("")
			if not v.wants_hut():
				v.go_home()
	_convo = {}


## How a villager talks about its own day, from real status.
func _about_me(v: Node3D) -> String:
	var ago := Villager.ago_text(int(v.last_info.get("ago_s", -1)))
	var days := int(v.last_info.get("ago_s", 0)) / 86400
	match v.cls:
		"Paladin":
			return "Inbox duty as always. Last sweep was %s." % ago
		"Bard":
			return "Wrote today's plan %s. Plans by noon, tasks done soon!" % ago
		"Mage":
			if days >= 3:
				return "No deep research for %d days... my spells grow restless." % days
			return "Cast a deep research %s. The scrolls are still warm." % ago
		"Sage":
			if days >= 3:
				return "Quiet days. Nobody has asked me anything for %d days." % days
			return "Answered a question %s. Notes never lie." % ago
	return "I last ran %s." % ago


func _small_talk(a: Node3D, b: Node3D) -> Array:
	var lines := []
	lines.append([a, "%s %s! How's work?" % [HELLO.get(a.cls, "Hi").split(",")[0], b.cls]])
	lines.append([b, _about_me(b) + " You?"])
	lines.append([a, _about_me(a)])
	var sick := _villagers.filter(func(v): return v.state == "failed").map(func(v): return v.cls)
	if not sick.is_empty():
		lines.append([b, "Did you hear? The %s is lying at the church." % sick[0]])
		lines.append([a, "The Cleric will patch them up. I hope the Guild Master checks the error."])
	elif randf() < 0.5:
		lines.append([b, "Everyone's healthy today. The Cleric is bored!"])
	else:
		lines.append([b, "Have you seen the Guild Master sneaking around? Hood up, two daggers..."])
	lines.append([a, ["See you around!", "Back to work then.", "Stay healthy!"].pick_random()])
	return lines


func _refresh_overheard() -> void:
	if _overheard_label:
		_overheard_label.text = "Overheard:\n" + "\n".join(_overheard)


## Who is close enough to talk to? Shows the "T: talk" hint.
func _update_near() -> void:
	_near = null
	var best := TALK_RANGE
	for v in _villagers + [_cleric]:
		var d: float = v.position.distance_to(_player.position)
		if d < best:
			best = d
			_near = v
	_hint.visible = _near != null
	if _near:
		_hint.text = "T: talk to %s" % _near.cls


# ---------- status feed ----------

func _setup_feed() -> void:
	_http = HTTPRequest.new()
	_http.timeout = 5.0
	add_child(_http)
	_http.request_completed.connect(_on_feed)
	var timer := Timer.new()
	timer.wait_time = POLL_SECONDS
	timer.autostart = true
	add_child(timer)
	timer.timeout.connect(_poll)
	_poll()
	# v3 talk goes to 21 Village Talk next to the status feed. Answers take 5-30 s.
	_talk_url = _feed_url.replace("village-status", "village-talk")
	_talk_http = HTTPRequest.new()
	_talk_http.timeout = 160.0
	add_child(_talk_http)
	_talk_http.request_completed.connect(_on_talk)
	# v2 jobs go to 22 Village Jobs. A Sage answer takes 10-60 s.
	_job_url = _feed_url.replace("village-status", "village-job")
	_job_http = HTTPRequest.new()
	_job_http.timeout = 200.0
	add_child(_job_http)
	_job_http.request_completed.connect(_on_job)


func _poll() -> void:
	if _http.get_http_client_status() != HTTPClient.STATUS_DISCONNECTED:
		return
	var url := _feed_url + ("?demo=" + _demo if _demo != "" else "")
	if _http.request(url) != OK:
		_feed_down("could not start request")


func _on_feed(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		_feed_down("no answer (HTTP %d). Are Docker and n8n running?" % code)
		return
	var data = JSON.parse_string(body.get_string_from_utf8())
	if typeof(data) != TYPE_DICTIONARY:
		_feed_down("bad reply")
		return
	var by_key := {}
	for a in data.get("agents", []):
		by_key[str(a.get("key", ""))] = a
	for v in _villagers:
		v.apply(by_key.get(v.key, {"state": "unknown"}))
	_apply_cleric(by_key)
	var feed := str(data.get("feed", "?"))
	_feed_text = "feed %s · updated %s" % [feed, str(data.get("updated", ""))]
	if feed != "ok":
		_feed_text += "  (n8n API problem: check the Village API key)"
	_refresh_ui()


## The Cleric shows 08 Error Alert + 17 Catch-up, and heals whoever lies at the church.
func _apply_cleric(by_key: Dictionary) -> void:
	var patients := 0
	for v in _villagers:
		if v.state == "failed":
			patients += 1
	var info := {"state": "ok", "text": "on duty"}
	for h in [by_key.get("alert", {}), by_key.get("catchup", {})]:
		if str(h.get("state", "")) == "failed":
			info = {"state": "failed", "text": "needs healing!"}
	if info["state"] == "ok" and patients > 0:
		info = {"state": "working", "text": "healing %d" % patients}
	_cleric.apply(info)


func _feed_down(why: String) -> void:
	for v in _villagers + [_cleric]:
		v.apply({"state": "unknown"})
	_feed_text = "feed down: " + why
	_refresh_ui()


## Demo failure: pretend one agent failed (only the reply is faked, no agent is touched).
func _cycle_demo() -> void:
	_demo = DEMO_CYCLE[(DEMO_CYCLE.find(_demo) + 1) % DEMO_CYCLE.size()]
	_refresh_ui()
	_poll()


func _end_demo() -> void:
	_demo = ""
	_refresh_ui()
	_poll()


func _run_test_talk() -> void:
	var parts := _test_talk.split(":", true, 1)
	for v in _villagers + [_cleric]:
		if v.key == parts[0]:
			_set_mode("walk")
			_player.position = v.position + (Vector3.ZERO - v.position).normalized() * 1.3
			_open_chat(v)
			if _test_job != "":
				_chat_input.text = _test_job
				_give_job()
			else:
				_send_talk(parts[1] if parts.size() > 1 else "Hi!")


func _take_shot() -> void:
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(_shot_path)
	get_tree().quit()
