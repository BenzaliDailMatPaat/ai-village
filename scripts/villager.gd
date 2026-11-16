extends Node3D
## One villager = one n8n agent (3D version).
## Plays an animation for its state, strolls near its building when healthy,
## walks around the town square to the healer church when its last run failed,
## lies down there until a run passes, then walks home.

const SPEED := 1.4             # walking speed, world units per second
const MODEL_SCALE := 0.46      # KayKit characters are big next to the hex buildings
const ARC_RADIUS := 3.6        # the ring road around the castle everyone walks on
const STATE_COLORS := {
	"ok": Color("7bd389"),
	"working": Color("f2b84b"),
	"failed": Color("ff6b6b"),
	"idle": Color("d0d0d0"),
	"unknown": Color("9a9a9a"),
}

# Filled in by village.gd before setup()
var key := ""
var cls := ""
var title := ""
var home := Vector3.ZERO        # where it stands when healthy (in front of its building)
var face_home := 0.0            # which way it looks at home (radians)
var hut_spot := Vector3.ZERO    # where it lies at the healer church
var hut_face := 0.0
var work_anim := "Idle_A"       # animation while its agent is running
var stays_home := false         # the Cleric never walks to the church, it lives there
var player_controlled := false  # you (the Guild Master)
var anim_index := {}            # short animation name -> "Library/name"

var state := "unknown"
var status_text := ""
var talking := false            # Zali is chatting with this villager (v3)
var npc_chat := false           # chatting with another villager
var job_busy := false           # v2: Zali just gave it a job, show the work animation
var last_info := {}             # last status from 19 (for greetings and small talk)

var _body: Node3D
var _anim: AnimationPlayer
var _name_label: Label3D
var _status_label: Label3D
var _bubble: Label3D
var _bubble_text := ""
var _talk_point := Vector3.ZERO
var _wants_hut := false
var _path: Array[Vector3] = []
var _next_stroll := 3.0
var _yaw_target := 0.0
var _current_anim := ""


func setup(model: PackedScene, libraries: Dictionary, gear: Dictionary) -> void:
	_body = model.instantiate()
	_body.scale = Vector3.ONE * MODEL_SCALE
	add_child(_body)
	# One AnimationPlayer per villager. All KayKit characters share the same
	# skeleton, so the shared animation libraries fit every one of them.
	_anim = AnimationPlayer.new()
	_body.add_child(_anim)
	_anim.root_node = NodePath("..")
	for lib_name in libraries:
		_anim.add_animation_library(lib_name, libraries[lib_name])
	# Gear (sword, staff, book...) sits on the hand bones.
	var skeleton: Skeleton3D = _body.find_children("*", "Skeleton3D", true, false)[0]
	for bone in gear:
		var slot := BoneAttachment3D.new()
		slot.bone_name = bone
		skeleton.add_child(slot)
		slot.add_child((gear[bone] as PackedScene).instantiate())
	# Both labels hang above the head; the pixel offset keeps them apart at any zoom.
	_name_label = _make_label(44, Color.WHITE, 1.3)
	_name_label.offset = Vector2(0, 46)
	_name_label.text = cls
	_status_label = _make_label(34, STATE_COLORS["unknown"], 1.3)
	# Speech bubble above the name: "..." while the villager is thinking (v3 talk).
	_bubble = _make_label(32, Color("ffffff"), 1.3)
	_bubble.offset = Vector2(0, 90)
	_bubble.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_bubble.width = 700
	_bubble.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	position = home
	rotation.y = face_home
	_yaw_target = face_home
	_next_stroll = randf_range(1.0, 5.0)
	_play("Idle_A")


func _make_label(font_size: int, color: Color, height: float) -> Label3D:
	var l := Label3D.new()
	l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	l.no_depth_test = true      # always readable, even behind a building
	l.fixed_size = true         # same size on screen at any zoom
	l.pixel_size = 0.0006
	l.font_size = font_size
	l.outline_size = 14
	l.outline_modulate = Color(0, 0, 0, 0.85)
	l.modulate = color
	l.position.y = height
	add_child(l)
	return l


## Called by village.gd with this agent's part of the 19 Village Status JSON.
func apply(info: Dictionary) -> void:
	state = str(info.get("state", "unknown"))
	if state != "unknown":
		last_info = info
	# "unknown" = feed down: stay where you are.
	if state != "unknown" and not stays_home and not player_controlled:
		var wants := state == "failed"
		if wants != _wants_hut:
			_wants_hut = wants
			_route(wants)
	status_text = describe(info)
	_status_label.text = status_text
	_status_label.modulate = STATE_COLORS.get(state, Color.WHITE)


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


func wants_hut() -> bool:
	return _wants_hut


## Small talk: walk to a meeting spot / walk back home.
func meet_at(p: Vector3) -> void:
	_route_to(p)


func go_home() -> void:
	_route_to(home)


func _route(to_hut: bool) -> void:
	_route_to(hut_spot if to_hut else home)


## Walk around the ring road (so nobody walks through the castle), then to the target.
func _route_to(target: Vector3) -> void:
	_path.clear()
	var a0 := atan2(position.x, position.z)
	var a1 := atan2(target.x, target.z)
	var diff := wrapf(a1 - a0, -PI, PI)
	var steps := maxi(1, int(ceil(absf(diff) / 0.35)))
	for i in range(steps + 1):
		var a := a0 + diff * float(i) / float(steps)
		_path.append(Vector3(sin(a), 0.0, cos(a)) * ARC_RADIUS)
	_path.append(target)


## v3 talk: show a bubble ("..." animates while thinking, "" hides it).
func set_bubble(text: String) -> void:
	_bubble_text = text
	_bubble.text = text


## Turn towards a point (the player while chatting).
func face_point(p: Vector3) -> void:
	_talk_point = p
	_yaw_target = atan2(p.x - position.x, p.z - position.z)


func is_walking() -> bool:
	return not _path.is_empty()


## Player movement (walk mode). dir is already relative to the camera.
func drive(dir: Vector3, delta: float, limit: float) -> void:
	if dir.length() > 0.01:
		position += dir.normalized() * SPEED * 1.6 * delta
		var flat := Vector2(position.x, position.z)
		if flat.length() > limit:
			flat = flat.normalized() * limit
			position = Vector3(flat.x, 0.0, flat.y)
		_yaw_target = atan2(dir.x, dir.z)
		_play("Running_A")
	else:
		_play("Idle_A")
	rotation.y = lerp_angle(rotation.y, _yaw_target, delta * 10.0)


func _process(delta: float) -> void:
	if player_controlled:
		return
	# Healthy villagers stroll around their own building now and then.
	if _bubble_text == "...":
		_bubble.text = ".".repeat(1 + int(Time.get_ticks_msec() / 350.0) % 3)
	if not talking and not npc_chat and not is_walking() and not _wants_hut and not stays_home and state in ["ok", "idle"]:
		_next_stroll -= delta
		if _next_stroll <= 0.0:
			_next_stroll = randf_range(4.0, 9.0)
			_path.append(home + Vector3(randf_range(-0.8, 0.8), 0.0, randf_range(-0.8, 0.8)))
	if is_walking():
		var target: Vector3 = _path[0]
		var to := target - position
		to.y = 0.0
		var step := SPEED * delta
		if to.length() <= step:
			position = target
			_path.remove_at(0)
		else:
			position += to.normalized() * step
			_yaw_target = atan2(to.x, to.z)
		_play("Walking_A")
	elif _wants_hut:
		_yaw_target = hut_face
		_play("Lie_Idle")
	elif job_busy:
		_play(work_anim)
	elif talking or npc_chat:
		face_point(_talk_point)
		_play("Idle_A")
	elif state == "working":
		_yaw_target = face_home
		_play(work_anim)
	elif state == "failed":
		_play("Sit_Floor_Idle")  # the Cleric itself is down
	elif state == "unknown":
		_play("Idle_B")
	else:
		_play("Idle_A")
	rotation.y = lerp_angle(rotation.y, _yaw_target, delta * 8.0)


func _play(short_name: String) -> void:
	var full: String = anim_index.get(short_name, "")
	if full == "" or full == _current_anim:
		return
	_current_anim = full
	_anim.play(full, 0.25)
