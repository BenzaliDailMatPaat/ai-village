extends Node2D
## One villager = one n8n agent.
## Shows the agent's state under its head. When the last run failed it walks
## to the healer hut, and it walks home again once a run passes.

const SPEED := 45.0  # walking speed, pixels per second
const STATE_COLORS := {
	"ok": Color("7bd389"),
	"working": Color("f2b84b"),
	"failed": Color("ff6b6b"),
	"idle": Color("c8c8c8"),
	"unknown": Color("8a8a8a"),
}

# Filled in by main.gd before setup()
var key := ""
var cls := ""
var title := ""
var home := Vector2.ZERO      # where it stands when healthy (in front of its house)
var hut_spot := Vector2.ZERO  # where it waits at the healer hut
var road_y := 0.0             # y of the main road everyone walks along
var lane_x := 0.0             # x of the lane down to the healer hut
var stays_home := false       # the Cleric lives at the hut and never walks

var state := "unknown"
var sprite: Sprite2D
var name_label: Label
var status_label: Label

var _wants_hut := false
var _path: Array[Vector2] = []
var _t := 0.0
var _next_stroll := 2.0


func setup(texture: Texture2D, overlay: CanvasLayer) -> void:
	sprite = Sprite2D.new()
	sprite.texture = texture
	add_child(sprite)
	# Labels live on a screen overlay (not in the zoomed world) so text stays sharp.
	name_label = _make_label(overlay, 15)
	name_label.text = cls
	name_label.reset_size()
	status_label = _make_label(overlay, 13)
	position = home
	_t = randf() * 10.0  # so not everyone bounces in sync


func _make_label(overlay: CanvasLayer, font_size: int) -> Label:
	var l := Label.new()
	l.add_theme_font_size_override("font_size", font_size)
	l.add_theme_constant_override("outline_size", 5)
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	overlay.add_child(l)
	return l


## Called by main.gd with this agent's part of the 19 Village Status JSON.
func apply(info: Dictionary) -> void:
	state = str(info.get("state", "unknown"))
	# "unknown" means the feed is down: stay where you are, just grey out.
	if state != "unknown" and not stays_home:
		var wants := state == "failed"
		if wants != _wants_hut:
			_wants_hut = wants
			_route(wants)
	status_label.text = describe(info)
	status_label.reset_size()
	status_label.add_theme_color_override("font_color", STATE_COLORS.get(state, Color.WHITE))
	if state == "failed":
		sprite.modulate = Color(1.0, 0.55, 0.55)
	elif state == "unknown":
		sprite.modulate = Color(0.55, 0.55, 0.55)
	else:
		sprite.modulate = Color.WHITE


## Short text under the character, for example "ok · 3 h ago".
static func describe(info: Dictionary) -> String:
	if info.has("text"):
		return str(info["text"])
	match str(info.get("state", "unknown")):
		"ok":
			return "ok · " + ago_text(int(info.get("ago_s", -1)))
		"working":
			return "working..."
		"failed":
			if info.get("demo", false):
				return "FAILED (demo)"
			return "FAILED · " + str(info.get("last_run", ""))
		"idle":
			return "no runs yet"
	return "no signal"


static func ago_text(seconds: int) -> String:
	if seconds < 0:
		return "never"
	if seconds < 60:
		return "just now"
	if seconds < 3600:
		return "%d min ago" % int(seconds / 60.0)
	if seconds < 86400:
		return "%d h ago" % int(seconds / 3600.0)
	return "%d d ago" % int(seconds / 86400.0)


## Build the list of corners to walk through: along the road, down the lane, to the hut (or back).
func _route(to_hut: bool) -> void:
	_path.clear()
	var below_road := position.y > road_y + 4.0
	if to_hut:
		if not below_road:
			_path.append(Vector2(position.x, road_y))
			_path.append(Vector2(lane_x, road_y))
		_path.append(Vector2(lane_x, hut_spot.y))
		_path.append(hut_spot)
	else:
		if below_road:
			_path.append(Vector2(lane_x, position.y))
			_path.append(Vector2(lane_x, road_y))
		_path.append(Vector2(home.x, road_y))
		_path.append(home)


func is_walking() -> bool:
	return not _path.is_empty()


func _process(delta: float) -> void:
	_t += delta
	# Healthy villagers stroll around their own yard now and then, so the village feels alive.
	if not is_walking() and not _wants_hut and state in ["ok", "idle", "working"]:
		_next_stroll -= delta
		if _next_stroll <= 0.0:
			_next_stroll = randf_range(3.0, 7.0)
			_path.append(home + Vector2(randf_range(-20.0, 20.0), randf_range(-6.0, 10.0)))
	var walking := is_walking()
	if walking:
		var target: Vector2 = _path[0]
		var step := SPEED * delta
		if position.distance_to(target) <= step:
			position = target
			_path.remove_at(0)
		else:
			var dir := (target - position).normalized()
			if absf(dir.x) > 0.1:
				sprite.flip_h = dir.x < 0.0
			position += dir * step
	# Small animations: hop while walking, bounce while working, sway while sick at the hut.
	sprite.rotation = 0.0
	if walking:
		sprite.position.y = -absf(sin(_t * 10.0)) * 2.0
	elif state == "working":
		sprite.position.y = -absf(sin(_t * 6.0)) * 3.0
	elif state == "failed":
		sprite.position.y = 0.0
		sprite.rotation = sin(_t * 2.0) * 0.12
	else:
		sprite.position.y = 0.0
	_place_labels()


func _place_labels() -> void:
	var xf := get_viewport().get_canvas_transform()
	var p: Vector2 = xf * global_position
	var zoom := xf.get_scale().y
	name_label.position = Vector2(p.x - name_label.size.x / 2.0, p.y - 8.0 * zoom - name_label.size.y)
	status_label.position = Vector2(p.x - status_label.size.x / 2.0, p.y + 8.0 * zoom + 2.0)
