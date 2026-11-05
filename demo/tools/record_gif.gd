extends SceneTree
## Frames for the README GIFs, recorded from the demo with Movie Maker:
##   open -g -n --env SHOTS=OUT -a Godot.app --args --path . --windowed --resolution 960x540 --position 10000,10000 \
##     --fixed-fps 30 --script res://demo/tools/record_gif.gd      (env SCENE=reactions|getup)
## Frames are saved here after forcing a draw — Movie Maker on a window macOS does not redraw repeats old frames.
## then ffmpeg → GIF. reactions: a shot into an arm, a shove into the chest (stumbles, caught), a knock-down, a kick to
## a shin; getup: two bodies lying hurt — one on its back, one face down — getting up.

var demo: Node3D
var _time := 0.0
var _men: Array[CharacterBody3D] = []


func _initialize() -> void:
	demo = (load("res://demo/demo.tscn") as PackedScene).instantiate()
	root.add_child(demo)
	current_scene = demo
	_run.call_deferred()


func _physics_process(delta: float) -> bool:
	_time += delta
	return false


var _frame := 0


func _process(_delta: float) -> bool:
	var dir := OS.get_environment("SHOTS")
	if dir != "" and _time > 0.0:
		RenderingServer.force_draw(false)
		root.get_texture().get_image().save_png("%s/f%05d.png" % [dir, _frame])
		_frame += 1
	return false


func _at(t: float) -> void:
	while _time < t:
		await physics_frame


func _hit(k: int, bone: StringName, impulse: Vector3, how: String) -> void:
	var c := _men[k]
	var pb := c.ragdoll.bones[String(bone)] as PhysicalBone3D
	demo._mark(pb.global_position, impulse)
	match how:
		"shot":
			c.shoot(bone, impulse)
		"shove":
			c.shove(bone, impulse)
		"knock":
			c.knock_down(bone, impulse)


func _run() -> void:
	demo.follow = false
	for c in demo.get_children():
		if c is CanvasLayer:
			c.visible = false
	for n in ["Player", "Standing", "Walking", "Animated"]:
		var c := demo.get_node(n) as CharacterBody3D
		c.auto_get_up = false
		c.patrol = 0.0
		_men.append(c)
	var cam := demo.get_node("Camera3D") as Camera3D
	cam.fov = 40.0
	if OS.get_environment("SCENE") == "getup":
		await _getup(cam)
	else:
		await _reactions(cam)
	quit()


func _reactions(cam: Camera3D) -> void:
	for k in 4:
		_men[k].global_position = Vector3(-3.3 + k * 2.2, 0.0, 2.0)
		_men[k].rotation.y = 0.0
	(demo.get_node("Animated") as CharacterBody3D).set_puppet(true)
	# three quarters: steps backwards (away from a front camera) show
	cam.fov = 38.0
	cam.global_position = Vector3(4.6, 2.1, 7.6)
	cam.look_at(Vector3(-0.4, 0.7, 1.2), Vector3.UP)
	await _at(0.8)
	_hit(0, &"LeftUpperArm", Vector3(-1, 0, -0.3).normalized() * 14.0, "shot")
	await _at(1.4)
	_hit(1, &"UpperChest", Vector3(0, 0, -1) * 110.0, "shove")
	await _at(2.4)
	_hit(2, &"UpperChest", Vector3(0, 0.15, -1).normalized() * 120.0, "knock")
	await _at(3.2)
	_hit(3, &"LeftLowerLeg", Vector3(-1, 0, 0) * 90.0, "shove")
	await _at(3.6)
	_hit(0, &"Head", Vector3(0.3, 0, -1).normalized() * 10.0, "shot")
	await _at(6.0)


func _getup(cam: Camera3D) -> void:
	for k in 4:
		_men[k].global_position = Vector3(30.0 + k * 3.0, 0.0, 0.0)
	var back := _men[0]
	var front := _men[1]
	back.global_position = Vector3(-1.1, 0.0, 2.6)
	front.global_position = Vector3(1.3, 0.0, 2.0)
	back.rotation.y = 0.0
	front.rotation.y = PI
	var mid0 := Vector3(0.1, 0.0, 1.9)
	cam.global_position = mid0 + Vector3(0.6, 1.9, 4.6)
	cam.look_at(mid0 + Vector3(0, 0.45, 0), Vector3.UP)
	await _at(0.5)
	back.knock_down(&"UpperChest", Vector3(0, 0.1, -1).normalized() * 70.0)
	front.knock_down(&"UpperChest", Vector3(0, 0.1, -1).normalized() * 70.0)
	await _at(5.0)
	back.get_up()
	front.get_up()
	await _at(9.4)
