extends Node2D
## AI Village v1: watch mode.
## Builds the village, gives each n8n agent a villager, asks the local
## "19 Village Status" webhook for news every 10 s, and switches between
## walk mode and monitor mode with Tab.
##
## Optional command line (after --): --feed=<url> --mode=walk|monitor --demo=<key>
##   --shot=<file.png> --shot-after=<seconds>   (saves a screenshot and quits, for testing)
##   --demo-off-after=<seconds>                  (ends the demo failure, to test the walk home)

const AgentScript := preload("res://legacy_2d/agent_2d.gd")

const TILE := 16
const MAP_SIZE := Vector2i(30, 18)
const ROAD_Y := 9                 # tile row of the main road
const LANE_X := 11                # tile column of the lane down to the healer hut
const PLAZA_Y := 15               # tile row in front of the healer hut
const HUT := Vector2i(14, 11)     # top-left tile of the 3x3 healer hut
const CLERIC_SPOT := Vector2i(18, 12)
const PLAYER_START := Vector2i(15, 9)
const POLL_SECONDS := 10.0
const WALK_ZOOM := 4.0
const PANEL_WIDTH := 330.0
const DEFAULT_FEED := "http://127.0.0.1:5678/webhook/village-status"
const TOWN_SHEET := preload("res://assets/tiny-town/Tilemap/tilemap_packed.png")
const DUNGEON_SHEET := preload("res://assets/tiny-dungeon/Tilemap/tilemap_packed.png")
const DEMO_CYCLE := ["", "sorter", "planner", "deep", "ask"]

# The cast. house = top-left tile of its 3x3 house, sprite = tile number in
# Tiny Dungeon, style = roof and wall tiles, spot = where it waits at the hut.
const CAST := [
	{"key": "sorter", "cls": "Paladin", "title": "01 Inbox Sorter", "house": Vector2i(3, 2), "sprite": 96, "style": "grey_wood", "spot": Vector2i(13, 15)},
	{"key": "planner", "cls": "Bard", "title": "02 Daily Planner", "house": Vector2i(10, 2), "sprite": 99, "style": "red_wood", "spot": Vector2i(15, 15)},
	{"key": "deep", "cls": "Mage", "title": "06 Deep Research", "house": Vector2i(17, 2), "sprite": 84, "style": "grey_stone", "spot": Vector2i(17, 15)},
	{"key": "ask", "cls": "Sage", "title": "07 Ask Notes", "house": Vector2i(24, 2), "sprite": 111, "style": "red_stone", "spot": Vector2i(19, 15)},
]

# House tiles from Tiny Town, top row to bottom row (roof, roof, wall with door).
const STYLES := {
	"grey_wood": [[48, 49, 50], [60, 61, 62], [72, 85, 75]],
	"red_wood": [[52, 53, 54], [64, 65, 66], [72, 85, 75]],
	"grey_stone": [[48, 49, 50], [60, 61, 62], [76, 89, 79]],
	"red_stone": [[52, 53, 54], [64, 65, 66], [76, 89, 79]],
}
const GRASS := [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 2]
const TREES := [16, 28, 16, 28, 5, 27, 15]
const DIRT := 25

var _feed_url := DEFAULT_FEED
var _demo := ""
var _mode := "monitor"
var _shot_path := ""
var _shot_after := 3.0

var _ground: TileMapLayer
var _things: TileMapLayer
var _overlay: CanvasLayer
var _ui: CanvasLayer
var _camera: Camera2D
var _player: Node2D
var _villagers: Array = []
var _cleric: Node2D
var _http: HTTPRequest
var _bar: Label
var _panel: PanelContainer
var _panel_rows := {}
var _mode_button: Button
var _demo_button: Button
var _feed_text := "connecting..."


func _ready() -> void:
	RenderingServer.set_default_clear_color(Color("24361f"))
	_read_args()
	_build_map()
	_overlay = CanvasLayer.new()
	add_child(_overlay)
	_build_people()
	for v in _villagers + [_cleric]:
		v.apply({"state": "unknown", "text": "connecting..."})
	_build_ui()
	_camera = Camera2D.new()
	add_child(_camera)
	_camera.make_current()
	_set_mode(_mode)
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
			"demo-off-after": get_tree().create_timer(float(value)).timeout.connect(_end_demo)


# ---------- map ----------

func _make_layer(sheet: Texture2D) -> TileMapLayer:
	var src := TileSetAtlasSource.new()
	src.texture = sheet
	src.texture_region_size = Vector2i(TILE, TILE)
	for y in sheet.get_height() / TILE:
		for x in sheet.get_width() / TILE:
			src.create_tile(Vector2i(x, y))
	var tiles := TileSet.new()
	tiles.tile_size = Vector2i(TILE, TILE)
	tiles.add_source(src, 0)
	var layer := TileMapLayer.new()
	layer.tile_set = tiles
	add_child(layer)
	return layer


## Place tile number `index` (counted left to right, 12 per row) at a cell.
func _put(layer: TileMapLayer, cell: Vector2i, index: int) -> void:
	layer.set_cell(cell, 0, Vector2i(index % 12, index / 12))


func _build_map() -> void:
	_ground = _make_layer(TOWN_SHEET)
	_things = _make_layer(TOWN_SHEET)
	var rng := RandomNumberGenerator.new()
	rng.seed = 14  # same village every time (Brainstorm #14)
	for y in MAP_SIZE.y:
		for x in MAP_SIZE.x:
			_put(_ground, Vector2i(x, y), GRASS[rng.randi() % GRASS.size()])
	# Roads: main road, a path from every door, the lane and the plaza at the hut.
	for x in range(1, MAP_SIZE.x - 1):
		_put(_ground, Vector2i(x, ROAD_Y), DIRT)
	for c in CAST:
		for y in range(c["house"].y + 3, ROAD_Y):
			_put(_ground, Vector2i(c["house"].x + 1, y), DIRT)
	for y in range(ROAD_Y, PLAZA_Y + 1):
		_put(_ground, Vector2i(LANE_X, y), DIRT)
	for x in range(LANE_X, 21):
		_put(_ground, Vector2i(x, PLAZA_Y), DIRT)
	_put(_ground, HUT + Vector2i(1, 3), DIRT)
	# Houses and the healer hut.
	for c in CAST:
		_house(c["house"], STYLES[c["style"]])
	_house(HUT, STYLES["red_stone"])
	# Trees around the edge.
	for y in MAP_SIZE.y:
		for x in MAP_SIZE.x:
			var edge := y == 0 or y >= MAP_SIZE.y - 2 or x == 0 or x == MAP_SIZE.x - 1
			if edge and y != ROAD_Y and rng.randf() < 0.7:
				_put(_things, Vector2i(x, y), TREES[rng.randi() % TREES.size()])
	# A red potion sign next to the hut door, so you know who heals here.
	var sign := Sprite2D.new()
	sign.texture = _dungeon_tile(115)
	sign.position = _cell_center(HUT + Vector2i(-1, 2))
	add_child(sign)


func _house(top_left: Vector2i, rows: Array) -> void:
	for dy in rows.size():
		for dx in rows[dy].size():
			_put(_things, top_left + Vector2i(dx, dy), rows[dy][dx])


func _cell_center(cell: Vector2i) -> Vector2:
	return Vector2(cell * TILE) + Vector2(TILE, TILE) / 2.0


func _dungeon_tile(index: int) -> AtlasTexture:
	var t := AtlasTexture.new()
	t.atlas = DUNGEON_SHEET
	t.region = Rect2((index % 12) * TILE, (index / 12) * TILE, TILE, TILE)
	return t


# ---------- people ----------

func _build_people() -> void:
	for c in CAST:
		var v = AgentScript.new()
		v.key = c["key"]
		v.cls = c["cls"]
		v.title = c["title"]
		v.home = _cell_center(c["house"] + Vector2i(1, 4))  # in front of the door
		v.hut_spot = _cell_center(c["spot"])
		v.road_y = _cell_center(Vector2i(0, ROAD_Y)).y
		v.lane_x = _cell_center(Vector2i(LANE_X, 0)).x
		add_child(v)
		v.setup(_dungeon_tile(c["sprite"]), _overlay)
		_villagers.append(v)
	_cleric = AgentScript.new()
	_cleric.key = "cleric"
	_cleric.cls = "Cleric"
	_cleric.title = "08 Error Alert + 17 Catch-up"
	_cleric.home = _cell_center(CLERIC_SPOT)
	_cleric.stays_home = true
	add_child(_cleric)
	_cleric.setup(_dungeon_tile(100), _overlay)
	# You, the Guild Master.
	_player = Node2D.new()
	var s := Sprite2D.new()
	s.texture = _dungeon_tile(98)
	_player.add_child(s)
	_player.position = _cell_center(PLAYER_START)
	add_child(_player)


# ---------- UI ----------

func _build_ui() -> void:
	_ui = CanvasLayer.new()
	_ui.layer = 2
	add_child(_ui)
	var top := PanelContainer.new()
	top.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	_ui.add_child(top)
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
	_mode_button.focus_mode = Control.FOCUS_NONE  # so Tab stays free for the toggle
	_mode_button.pressed.connect(_toggle_mode)
	row.add_child(_mode_button)

	_panel = PanelContainer.new()
	_panel.set_anchors_and_offsets_preset(Control.PRESET_RIGHT_WIDE)
	_panel.offset_left = -PANEL_WIDTH
	_panel.offset_top = 44
	_ui.add_child(_panel)
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
	help.text = "Tab: walk / monitor\nWASD or arrows: walk\nF9 / top button: demo failure\nF5: refresh now"
	help.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	list.add_child(help)
	_refresh_ui()


func _refresh_ui() -> void:
	var demo := "   DEMO: %s fails" % _demo if _demo != "" else ""
	_bar.text = "  AI Village   %s%s" % [_feed_text, demo]
	_demo_button.text = "Demo failure: %s" % (_demo if _demo != "" else "off")
	for v in _villagers + [_cleric]:
		var l: Label = _panel_rows[v.key]
		l.text = "%s  ·  %s\n    %s" % [v.cls, v.title, v.status_label.text]
		l.add_theme_color_override("font_color", AgentScript.STATE_COLORS.get(v.state, Color.WHITE))


# ---------- modes and camera ----------

func _toggle_mode() -> void:
	_set_mode("walk" if _mode == "monitor" else "monitor")


func _set_mode(m: String) -> void:
	_mode = m if m in ["walk", "monitor"] else "monitor"
	var walk := _mode == "walk"
	_panel.visible = not walk
	_mode_button.text = "Monitor mode  [Tab]" if walk else "Walk mode  [Tab]"
	var map_px := Vector2(MAP_SIZE * TILE)
	if walk:
		_camera.zoom = Vector2.ONE * WALK_ZOOM
		_camera.limit_left = 0
		_camera.limit_top = -12  # a little room under the top bar
		_camera.limit_right = int(map_px.x)
		_camera.limit_bottom = int(map_px.y)
	else:
		# Fit the whole map in the space left of the status panel.
		var view := get_viewport_rect().size
		var z := minf((view.x - PANEL_WIDTH) / map_px.x, (view.y - 50.0) / map_px.y)
		_camera.zoom = Vector2.ONE * z
		_camera.limit_left = -100000
		_camera.limit_top = -100000
		_camera.limit_right = 100000
		_camera.limit_bottom = 100000
		_camera.position = map_px / 2.0 + Vector2(PANEL_WIDTH / 2.0, -22.0) / z


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


func _process(delta: float) -> void:
	if _mode != "walk":
		return
	var dir := Vector2(
		float(Input.is_physical_key_pressed(KEY_D) or Input.is_physical_key_pressed(KEY_RIGHT))
			- float(Input.is_physical_key_pressed(KEY_A) or Input.is_physical_key_pressed(KEY_LEFT)),
		float(Input.is_physical_key_pressed(KEY_S) or Input.is_physical_key_pressed(KEY_DOWN))
			- float(Input.is_physical_key_pressed(KEY_W) or Input.is_physical_key_pressed(KEY_UP)))
	if dir != Vector2.ZERO:
		_player.position += dir.normalized() * 70.0 * delta
		_player.position = _player.position.clamp(Vector2(8, 8), Vector2(MAP_SIZE * TILE) - Vector2(8, 8))
		(_player.get_child(0) as Sprite2D).flip_h = dir.x < 0.0 if dir.x != 0.0 else (_player.get_child(0) as Sprite2D).flip_h
	_camera.position = _player.position


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
		return  # previous request still running
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


## The Cleric shows 08 Error Alert + 17 Catch-up, and how many villagers are at the hut.
func _apply_cleric(by_key: Dictionary) -> void:
	var patients := 0
	for v in _villagers:
		if v.state == "failed":
			patients += 1
	var helpers := [by_key.get("alert", {}), by_key.get("catchup", {})]
	var info := {"state": "ok", "text": "on duty"}
	for h in helpers:
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
