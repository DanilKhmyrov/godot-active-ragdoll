extends SceneTree
## Getting up from where the body lies: knocked down onto its back / face down, then get_up().
##   godot --headless --path . --script res://demo/tools/probe_getup.gd   (CASE=name for one)
## roll — how long turning onto the back took, s; start gap — physical hips vs the clip's first frame, m (a jump if
## large); stood — hips height at the end, m (≈0.9 standing); worst — worst bone shown away from its body during the
## get-up, cm; fast — fastest body speed, m/s; lost — balance_lost during it.

const CASES := {
	"on_back": [&"UpperChest", Vector3(0, 0.1, -1), 110.0],
	"face_down": [&"UpperChest", Vector3(0, 0.1, 1), 110.0],
	"on_side": [&"UpperChest", Vector3(1, 0.1, 0), 110.0],
}

var demo: Node3D


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	for name: String in CASES:
		if OS.get_environment("CASE") != "" and OS.get_environment("CASE") != name:
			continue
		var spec: Array = CASES[name]
		demo = (load("res://demo/demo.tscn") as PackedScene).instantiate()
		root.add_child(demo)
		for i in 60:
			await physics_frame
		var c := demo.get_node("Standing") as CharacterBody3D
		var ar: ActiveRagdoll = c.ragdoll
		var lost := [false]
		c.knock_down(spec[0], (spec[1] as Vector3).normalized() * float(spec[2]))
		for i in 150:
			await physics_frame
		ar.balance_lost.connect(func() -> void: lost[0] = true)
		c.get_up()
		var roll := 0.0
		var faces := ""
		while ar.rolling():
			roll += 1.0 / 60.0
			if int(roll * 60.0) % 15 == 0:
				faces += " %+.1f" % ar._bone_basis("Hips").z.normalized().y
			await physics_frame
		await physics_frame
		var gap0: float = ar.drift().length()
		var worst := [0.0]          # an array: a lambda captures locals by value
		var fast := 0.0
		var sk: Skeleton3D = c.skeleton
		var watch := func() -> void:
			if not ar.is_running():
				return
			for b: String in ar.bones:
				var pb := ar.bones[b] as PhysicalBone3D
				var want := (pb.global_transform * pb.body_offset.affine_inverse()).origin
				var got := (sk.global_transform * sk.get_bone_global_pose(sk.find_bone(b))).origin
				worst[0] = maxf(worst[0], want.distance_to(got) * 100.0)
		sk.skeleton_updated.connect(watch)
		for i in 240:
			await physics_frame
			for pb: PhysicalBone3D in ar.bones.values():
				fast = maxf(fast, pb.linear_velocity.length())
		sk.skeleton_updated.disconnect(watch)
		var hips := (ar.bones["Hips"] as PhysicalBone3D).global_position.y
		print("GETUP %-9s clip %s roll %.2fs (pelvis faces up%s)  start drift %.2f m  stood %.2f m (%s)  worst %.0f cm  fast %.1f m/s  lost %s" % [name, c._clip, roll, faces, gap0, hips, "up" if not c.down else "still down", worst[0], fast, lost[0]])
		demo.queue_free()
		await process_frame
	quit()
