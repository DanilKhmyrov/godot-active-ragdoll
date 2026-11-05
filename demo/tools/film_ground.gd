extends SceneTree
## Frames of one body knocked down, lying hurt, then getting up — for looking at, close up.
##   open -g -n -a Godot.app --args --path . --windowed --resolution 640x400 --position 10000,10000 \
##     --script res://demo/tools/film_ground.gd     (env: SHOTS=dir, FACE=down|back, PHASE=lie|up, STEP=frames, WAIT=frames before, CLOSE=1 upper body)
var demo: Node3D
func _initialize() -> void:
	demo = (load("res://demo/demo.tscn") as PackedScene).instantiate()
	root.add_child(demo)
	_run.call_deferred()
func _shot(n: int) -> void:
	await process_frame
	RenderingServer.force_draw(false)
	RenderingServer.force_draw(false)
	root.get_texture().get_image().save_png("%s/f%02d.png" % [OS.get_environment("SHOTS"), n])
func _run() -> void:
	demo.follow = false
	for c in demo.get_children():
		if c is CanvasLayer:
			c.visible = false
	for n in ["Player", "Walking", "Animated"]:
		(demo.get_node(n) as Node3D).position.x += 30
	var c := demo.get_node("Standing") as CharacterBody3D
	c.auto_get_up = false
	c.position = Vector3(0, 0, 2.5)
	var cam := demo.get_node("Camera3D") as Camera3D
	cam.fov = 45
	for i in 60:
		await physics_frame
	var face_down := OS.get_environment("FACE") == "down"
	c.knock_down(&"UpperChest", Vector3(0, 0.1, 1 if face_down else -1).normalized() * 70.0)
	var wait := int(OS.get_environment("WAIT")) if OS.get_environment("WAIT") != "" else 150
	for i in wait:
		await physics_frame
	if OS.get_environment("FOLLOW") != "":
		cam.global_position = c.global_position + Vector3(2.4, 1.8, 2.4)
		cam.look_at(c.global_position + Vector3(0, 0.5, -0.6), Vector3.UP)
	var body: Vector3 = c.body_position()
	var close := OS.get_environment("CLOSE") != ""
	var chest := (c.ragdoll.bones["UpperChest"] as PhysicalBone3D).global_position
	if OS.get_environment("FOLLOW") == "":
		cam.global_position = (chest + Vector3(0.9, 1.1, 0.9)) if close else (body + Vector3(1.6, 1.5, 1.6))
		cam.look_at(chest if close else body + Vector3.UP * 0.25, Vector3.UP)
	var step := int(OS.get_environment("STEP")) if OS.get_environment("STEP") != "" else 20
	if OS.get_environment("PHASE") == "up":
		c.get_up()
	var n := 0
	for i in step * 18:
		if i % step == 0:
			await _shot(n)
			n += 1
		await physics_frame
	quit()
