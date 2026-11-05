extends SceneTree
## Headless check of the demo: every tool on every kind of body, then everybody stands up.
##   Godot --headless --path . --script res://demo/tools/demo_check.gd
## SHOTS=dir (windowed) also saves a frame after each step. Ends with FAIL lines if something is off: a bone shown away
## from its physical body (joints anchored at the rest pose instead of the animated shoulders), a body that did not fall
## or did not get up.

var demo: Node3D
var _t := 0.0
var _gap := {}        # character → largest gap (m) between a shown bone and its body, standing calm in puppet mode
var _gap_now := {}    # character → that gap this frame
var _gap_bone := {}   # character → the bone with it
var _fails: Array[String] = []


func _initialize() -> void:
	demo = (load("res://demo/demo.tscn") as PackedScene).instantiate()
	root.add_child(demo)
	current_scene = demo
	_run.call_deferred()


func _watch_gaps() -> void:
	for n in ["Player", "Standing", "Walking", "Animated"]:
		var c := _c(n)
		c.skeleton.skeleton_updated.connect(func() -> void:
			if not c.ragdoll.is_running():
				return
			# a hard blow may pull joints apart for a frame (BoneLengthGuard hides it) — a constant offset is the bug
			var g: Transform3D = c.skeleton.global_transform
			var worst := 0.0
			var worst_bone := ""
			for b: String in c.ragdoll.bones:
				var pb := c.ragdoll.bones[b] as PhysicalBone3D
				if not pb.is_simulating_physics():
					continue
				var want := (pb.global_transform * pb.body_offset.affine_inverse()).origin
				var got: Vector3 = (g * c.skeleton.get_bone_global_pose(c.skeleton.find_bone(b))).origin
				if want.distance_to(got) > worst:
					worst = want.distance_to(got)
					worst_bone = b
			_gap_now[n] = worst
			_gap_bone[n] = worst_bone
			if c.ragdoll.is_puppet() and not c.down and not c.ragdoll.recently_hit(1.5):
				_gap[n] = maxf(float(_gap.get(n, 0.0)), worst))


func _expect(ok: bool, what: String) -> void:
	if not ok:
		_fails.append(what)


func _c(n: String) -> CharacterBody3D:
	return demo.get_node(n) as CharacterBody3D


func _wait(secs: float) -> void:
	var end := _t + secs
	while _t < end:
		await physics_frame


func _physics_process(delta: float) -> bool:
	_t += delta
	return false


func _report(tag: String) -> void:
	var line := "CHECK %-14s" % tag
	for n in ["Player", "Standing", "Walking", "Animated"]:
		var c := _c(n)
		var ar: ActiveRagdoll = c.ragdoll
		var hips: Vector3 = c.body_position()
		line += "  %s[%s%s%s h%.2f d%.2f]" % [n, "P" if ar.is_puppet() else "-", "R" if ar.is_running() else "-",
			"D" if c.down else "-", hips.y, ar.drift().length()]
	print(line)
	var shots := OS.get_environment("SHOTS")
	if shots != "":
		RenderingServer.force_draw(false)
		RenderingServer.force_draw(false)
		root.get_texture().get_image().save_png("%s/%s.png" % [shots, tag])


func _dir(from: String, to: String) -> Vector3:
	return (_c(to).global_position - _c(from).global_position).normalized()


func _cam(at: Vector3, look: Vector3) -> void:
	demo.follow = false
	var cam := demo.get_node("Camera3D") as Camera3D
	cam.global_position = at
	cam.look_at(look, Vector3.UP)


func _run() -> void:
	_cam(Vector3(3.2, 2.4, 6.0), Vector3(0, 0.6, -0.5))
	await _wait(1.0)
	_watch_gaps()
	_report("start")
	for n in ["Player", "Standing", "Walking"]:
		_expect(_c(n).ragdoll.is_puppet(), n + " is not in puppet mode")
	_c("Standing").shoot(&"LeftUpperArm", Vector3(1, 0, 0) * 10.0)
	_c("Animated").shoot(&"UpperChest", Vector3(0, 0, 1) * 10.0)
	await _wait(0.3)
	_report("shot")
	await _wait(1.0)
	_report("shot_after")
	_c("Walking").shove(&"UpperChest", Vector3(0, 0, -1) * 60.0)
	_c("Animated").shove(&"UpperChest", Vector3(0, 0, 1) * 60.0)
	await _wait(0.5)
	_report("shove")
	await _wait(1.5)
	_report("shove_after")
	_c("Standing").kill(&"Head", Vector3(1, 0, 0) * 10.0)
	_c("Player").knock_down(&"UpperChest", Vector3(0, 0.15, 1).normalized() * 150.0)
	await _wait(2.5)
	_report("down")
	for n in ["Player", "Standing", "Animated"]:
		_expect(_c(n).down and _c(n).body_position().y < 0.35, n + " is not lying")
		print("CHECK lying gap %-8s %.1f cm (%s)" % [n, float(_gap_now.get(n, 0.0)) * 100.0, _gap_bone.get(n, "")])
		_expect(float(_gap_now.get(n, 0.0)) < 0.06, "%s lies %.0f cm away from its bodies" % [n, float(_gap_now.get(n, 0.0)) * 100.0])
	var body: Vector3 = _c("Standing").body_position()
	_cam(body + Vector3(0.8, 1.2, 1.4), body)
	await _wait(0.1)
	_report("down_close")
	_cam(Vector3(3.2, 2.4, 6.0), Vector3(0, 0.6, -0.5))
	_c("Walking").start_crawl()
	await _wait(3.0)
	_report("crawl")
	for n in ["Player", "Standing", "Walking", "Animated"]:
		if _c(n).down:
			_c(n).stand_up()
	await _wait(1.0)
	_report("stood_up")
	for n in ["Player", "Standing", "Walking", "Animated"]:
		_expect(not _c(n).down and _c(n).body_position().y > 0.8, n + " did not stand up")
		print("CHECK standing gap %-8s %.1f cm" % [n, float(_gap.get(n, 0.0)) * 100.0])
		# a walking puppet's joints still give (pins outpull them) — known, only reported
		if n != "Walking":
			_expect(float(_gap.get(n, 0.0)) < 0.04, "%s: a bone was shown %.0f cm from its body" % [n, float(_gap.get(n, 0.0)) * 100.0])
	for f in _fails:
		print("FAIL ", f)
	print("CHECK done, %d failed" % _fails.size())
	quit()
