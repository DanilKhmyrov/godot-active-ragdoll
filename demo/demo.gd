extends Node3D
## Active Ragdoll demo: walk the mannequin around, click a body to hit it. The reaction depends on the tool
## (shot, shove, kill, knock down) and on whether the body is in puppet mode or on plain animation.
##
##   WASD — walk (Shift — run), right mouse — orbit, wheel — zoom
##   left mouse — use the tool on the body under the cursor; 1–4 — tools; Q — throw a crate
##   C — crawl (the body under the cursor, or you), R — everybody stands up, P — puppet mode on/off
##   T — slow motion, B — show physical bodies, Backspace — restart

const TOOLS := [
	{"name": "Shot", "key": KEY_1, "power": 10.0, "unit": "N·s"},
	{"name": "Shove", "key": KEY_2, "power": 60.0, "unit": "N·s"},
	{"name": "Kill", "key": KEY_3, "power": 10.0, "unit": "N·s"},
	{"name": "Knock down", "key": KEY_4, "power": 150.0, "unit": "N·s"},
]

@onready var player: CharacterBody3D = $Player
@onready var camera: Camera3D = $Camera3D

var characters: Array[CharacterBody3D] = []
var current_tool := 0
var power := 1.0
var slow := false
var show_bodies := false
var puppet := true
## The camera follows the player (off — whoever drives the demo places it).
var follow := true

var _yaw := 0.35
var _pitch := -0.22
var _dist := 4.5
var _focus := Vector3.ZERO
var _orbiting := false
var _status: Label
var _tool_buttons: Array[Button] = []
var _power_label: Label
var _debug_meshes: Array[MeshInstance3D] = []


func _ready() -> void:
	for c in get_children():
		if c is CharacterBody3D:
			characters.append(c)
	_focus = player.global_position + Vector3.UP
	_build_ui()


func _process(delta: float) -> void:
	# walk relative to the camera
	var input := Input.get_vector("ui_left", "ui_right", "ui_up", "ui_down")
	input += Vector2(float(Input.is_key_pressed(KEY_D)) - float(Input.is_key_pressed(KEY_A)),
		float(Input.is_key_pressed(KEY_S)) - float(Input.is_key_pressed(KEY_W)))
	input = input.limit_length(1.0)
	var basis_flat := Basis(Vector3.UP, _yaw)
	player.move_dir = basis_flat * Vector3(input.x, 0.0, input.y)
	player.running = Input.is_key_pressed(KEY_SHIFT)
	_update_status()
	if not follow:
		return
	# camera: orbit around the body (the physical hips when it is a ragdoll)
	var target: Vector3 = player.body_position() + Vector3.UP * 0.35
	_focus = _focus.lerp(target, 1.0 - exp(-6.0 * delta / maxf(Engine.time_scale, 0.05)))
	var offset := Basis(Vector3.UP, _yaw) * Basis(Vector3.RIGHT, _pitch) * Vector3(0.0, 0.0, _dist)
	camera.global_position = _focus + offset
	camera.look_at(_focus, Vector3.UP)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		match mb.button_index:
			MOUSE_BUTTON_RIGHT:
				_orbiting = mb.pressed
			MOUSE_BUTTON_WHEEL_UP:
				_dist = maxf(_dist * 0.9, 1.5)
			MOUSE_BUTTON_WHEEL_DOWN:
				_dist = minf(_dist * 1.1, 20.0)
			MOUSE_BUTTON_LEFT:
				if mb.pressed:
					_use_tool(mb.position)
	elif event is InputEventMouseMotion and _orbiting:
		var mm := event as InputEventMouseMotion
		_yaw -= mm.relative.x * 0.006
		_pitch = clampf(_pitch - mm.relative.y * 0.006, -1.4, 0.3)
	elif event is InputEventKey and event.pressed and not event.echo:
		var key := (event as InputEventKey).keycode
		for i in TOOLS.size():
			if key == TOOLS[i]["key"]:
				_set_tool(i)
		match key:
			KEY_Q:
				_throw_crate()
			KEY_C:
				var c := _character_under_mouse()
				(c if c else player).start_crawl()
			KEY_R:
				for c in characters:
					if c.down:
						c.stand_up()
			KEY_P:
				_set_puppet(not puppet)
			KEY_T:
				_set_slow(not slow)
			KEY_B:
				_set_show_bodies(not show_bodies)
			KEY_BACKSPACE:
				Engine.time_scale = 1.0
				get_tree().reload_current_scene()


# ------------------------------------------------------------------ tools

func _ray(at: Vector2) -> Array:
	return [camera.project_ray_origin(at), camera.project_ray_normal(at)]


## The character and bone under the screen point, if no wall is in between: [character, bone, world point].
func _pick(at: Vector2) -> Array:
	var r := _ray(at)
	var from: Vector3 = r[0]
	var dir: Vector3 = r[1]
	var q := PhysicsRayQueryParameters3D.create(from, from + dir * 100.0, 1)
	var wall := get_world_3d().direct_space_state.intersect_ray(q)
	var wall_t: float = from.distance_to(wall["position"]) if wall else INF
	var best: Array = []
	var best_t := wall_t
	for c in characters:
		var hit: Array = c.pick_bone(from, dir)
		if hit[0] != &"" and hit[1] < best_t:
			best_t = hit[1]
			best = [c, hit[0], from + dir * best_t]
	return best


func _character_under_mouse() -> CharacterBody3D:
	var p := _pick(get_viewport().get_mouse_position())
	return p[0] if not p.is_empty() else null


func _use_tool(at: Vector2) -> void:
	var p := _pick(at)
	if p.is_empty():
		return
	var c: CharacterBody3D = p[0]
	var bone: StringName = p[1]
	var dir: Vector3 = _ray(at)[1]
	var amount: float = TOOLS[current_tool]["power"] * power
	_mark(p[2], dir)
	match current_tool:
		0:
			c.shoot(bone, dir * amount)
		1:
			# a shove is horizontal
			var flat := Vector3(dir.x, 0.0, dir.z).normalized()
			c.shove(bone, flat * amount)
		2:
			c.kill(bone, dir * amount)
		3:
			c.knock_down(bone, Vector3(dir.x, 0.15, dir.z).normalized() * amount)


func _throw_crate() -> void:
	var r := _ray(get_viewport().get_mouse_position())
	var crate := RigidBody3D.new()
	crate.mass = 8.0
	crate.collision_layer = 1
	crate.collision_mask = 1 | (1 << 9)
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3.ONE * 0.4
	cs.shape = box
	crate.add_child(cs)
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = box.size
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.75, 0.55, 0.3)
	bm.material = mat
	mi.mesh = bm
	crate.add_child(mi)
	add_child(crate)
	crate.global_position = r[0] + r[1] * 1.0
	crate.linear_velocity = r[1] * 14.0
	crate.angular_velocity = Vector3(randf(), randf(), randf()) * 4.0
	get_tree().create_timer(12.0, true, false, true).timeout.connect(crate.queue_free)


## A red flash where the blow landed and an arrow along it.
func _mark(at: Vector3, dir: Vector3) -> void:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.no_depth_test = true
	mat.albedo_color = Color(1.0, 0.15, 0.1, 0.9)
	var node := Node3D.new()
	add_child(node)
	node.global_position = at
	var flash := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 0.04
	sm.height = 0.08
	sm.material = mat
	flash.mesh = sm
	node.add_child(flash)
	var arrow := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = 0.0
	cm.bottom_radius = 0.025
	cm.height = 0.3
	cm.material = mat
	arrow.mesh = cm
	node.add_child(arrow)
	var d := dir.normalized()
	arrow.global_basis = Basis(Quaternion(Vector3.UP, d))
	arrow.global_position = at - d * 0.2
	var tw := node.create_tween().set_parallel()
	tw.tween_property(flash, "scale", Vector3.ONE * 2.5, 0.3)
	tw.tween_property(mat, "albedo_color:a", 0.0, 0.5).set_delay(0.3)
	tw.chain().tween_callback(node.queue_free)


# ------------------------------------------------------------------ toggles

func _set_tool(i: int) -> void:
	current_tool = i
	for k in _tool_buttons.size():
		_tool_buttons[k].set_pressed_no_signal(k == i)
	_update_power_label()


func _set_puppet(on: bool) -> void:
	puppet = on
	for c in characters:
		c.set_puppet(on)


func _set_slow(on: bool) -> void:
	slow = on
	Engine.time_scale = 0.25 if on else 1.0


func _set_show_bodies(on: bool) -> void:
	show_bodies = on
	if on and _debug_meshes.is_empty():
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(1.0, 0.55, 0.1, 0.45)
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		for c in characters:
			for pb: PhysicalBone3D in c.ragdoll.bones.values():
				var cs := pb.get_child(0) as CollisionShape3D
				var cap := cs.shape as CapsuleShape3D
				var mi := MeshInstance3D.new()
				var cm := CapsuleMesh.new()
				cm.radius = cap.radius
				cm.height = cap.height
				cm.radial_segments = 12
				cm.rings = 4
				cm.material = mat
				mi.mesh = cm
				mi.transform = cs.transform
				mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
				pb.add_child(mi)
				_debug_meshes.append(mi)
	for mi in _debug_meshes:
		mi.visible = on


# ------------------------------------------------------------------ UI

func _build_ui() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	var panel := PanelContainer.new()
	panel.position = Vector2(16, 16)
	layer.add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	panel.add_child(box)
	var title := Label.new()
	title.text = "Active Ragdoll"
	title.add_theme_font_size_override("font_size", 20)
	box.add_child(title)
	var tools := HBoxContainer.new()
	box.add_child(tools)
	var group := ButtonGroup.new()
	for i in TOOLS.size():
		var b := Button.new()
		b.text = "%d %s" % [i + 1, TOOLS[i]["name"]]
		b.toggle_mode = true
		b.button_group = group
		b.focus_mode = Control.FOCUS_NONE
		b.pressed.connect(_set_tool.bind(i))
		tools.add_child(b)
		_tool_buttons.append(b)
	var row := HBoxContainer.new()
	box.add_child(row)
	_power_label = Label.new()
	_power_label.custom_minimum_size.x = 150
	row.add_child(_power_label)
	var slider := HSlider.new()
	slider.min_value = 0.25
	slider.max_value = 3.0
	slider.step = 0.05
	slider.value = power
	slider.custom_minimum_size.x = 200
	slider.focus_mode = Control.FOCUS_NONE
	slider.value_changed.connect(func(v: float) -> void:
		power = v
		_update_power_label())
	row.add_child(slider)
	var toggles := HBoxContainer.new()
	box.add_child(toggles)
	for t: Array in [["P Puppet", puppet, _set_puppet], ["T Slow-mo", slow, _set_slow], ["B Bodies", show_bodies, _set_show_bodies]]:
		var cb := CheckButton.new()
		cb.text = t[0]
		cb.button_pressed = t[1]
		cb.focus_mode = Control.FOCUS_NONE
		cb.toggled.connect(t[2])
		toggles.add_child(cb)
		cb.set_meta(&"toggle", t[0])
	var help := Label.new()
	help.text = "WASD walk, Shift run · RMB orbit, wheel zoom\nLMB use the tool on a body · Q throw a crate\nC crawl · R stand up · Backspace restart"
	help.modulate = Color(1, 1, 1, 0.7)
	box.add_child(help)
	_status = Label.new()
	_status.add_theme_font_size_override("font_size", 13)
	box.add_child(_status)
	_set_tool(0)


func _update_power_label() -> void:
	if _power_label:
		_power_label.text = "Power %.0f %s" % [TOOLS[current_tool]["power"] * power, TOOLS[current_tool]["unit"]]


func _update_status() -> void:
	# keep the check buttons in sync with the keys
	for cb in _status.get_parent().get_child(3).get_children():
		var on: bool = {"P Puppet": puppet, "T Slow-mo": slow, "B Bodies": show_bodies}[cb.get_meta(&"toggle")]
		(cb as CheckButton).set_pressed_no_signal(on)
	var c: CharacterBody3D = _character_under_mouse()
	if c == null:
		c = player
	var ar: ActiveRagdoll = c.ragdoll
	var state := "animated"
	if c.dead:
		state = "dead"
	elif c.crawling:
		state = "crawling"
	elif c.down:
		state = "down"
	elif ar.is_puppet():
		state = "puppet"
	if ar.staggering():
		state += ", staggering"
	if ar.stumbling():
		state += ", stumbling"
	if ar.hitting():
		state += ", hit"
	if ar.writhing():
		state += ", writhing"
	_status.text = "%s: %s\ndrift %.2f m  drop %.2f m  hips %.1f m/s\n%d FPS" % [
		c.name, state, ar.drift().length(), ar.drop(), ar.hips_speed(), Engine.get_frames_per_second()]
