extends Node3D
## AI Village (3D): a KayKit hex island where each n8n agent is a villager.
## Asks the local "19 Village Status" webhook for news every 10 s.
##
## Controls: Tab = walk / monitor. Monitor: right-drag or Q/E to orbit, wheel to zoom,
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
	var help := Label.new()
	help.text = "Tab: walk / monitor\nWASD or arrows: walk\nRight-drag or Q/E: turn camera\nWheel: zoom   R: turntable\nF9 / top button: demo failure\nF5: refresh now"
	help.add_theme_color_override("font_color", Color(0.72, 0.72, 0.72))
	list.add_child(help)
	for v in _villagers + [_cleric]:
		v.apply({"state": "unknown", "text": "connecting..."})
	_refresh_ui()


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
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
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
	if Input.is_physical_key_pressed(KEY_Q):
		_yaw += delta * 1.5
	if Input.is_physical_key_pressed(KEY_E):
		_yaw -= delta * 1.5
	if _turntable and _mode == "monitor":
		_yaw += delta * 0.08
	if _mode == "walk":
		var input := Vector2(
			float(Input.is_physical_key_pressed(KEY_D) or Input.is_physical_key_pressed(KEY_RIGHT))
				- float(Input.is_physical_key_pressed(KEY_A) or Input.is_physical_key_pressed(KEY_LEFT)),
			float(Input.is_physical_key_pressed(KEY_S) or Input.is_physical_key_pressed(KEY_DOWN))
				- float(Input.is_physical_key_pressed(KEY_W) or Input.is_physical_key_pressed(KEY_UP)))
		var dir := Basis(Vector3.UP, _yaw) * Vector3(input.x, 0.0, input.y)
		_player.drive(dir, delta, 2.0 * LAND_RADIUS - 1.0)
	else:
		_player.drive(Vector3.ZERO, delta, 0.0)
	for c in _clouds:
		var a: float = c.get_meta("angle") + delta * 0.02
		c.set_meta("angle", a)
		var rad: float = c.get_meta("radius")
		c.position = Vector3(cos(a) * rad, c.position.y, sin(a) * rad)
	_update_camera(delta)


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


func _take_shot() -> void:
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(_shot_path)
	get_tree().quit()
