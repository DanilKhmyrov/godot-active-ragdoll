extends SceneTree
## How a knocked-down body moves in its first half second: does it fly off as one block or topple from the blow?
##   godot --headless --path . --script res://demo/tools/probe_knock.gd   (CASE=name for one)
## Every 0.1 s: how far the head, hips and feet went (cm) and bend — mean joint angle change since the blow (°).
## A block: feet go as far as the head, bend stays ~0. A topple: the head goes far, the feet little, joints bend.

const CASES := {
	"chest_back": [&"Standing", &"UpperChest", Vector3(0, 0.15, -1), 250.0],
	"chest_side": [&"Standing", &"UpperChest", Vector3(1, 0.15, 0), 250.0],
	"hips_side": [&"Standing", &"Hips", Vector3(1, 0.15, 0), 250.0],
	"head_back": [&"Standing", &"Head", Vector3(0, 0.15, -1), 150.0],
	"anim_chest": [&"Animated", &"UpperChest", Vector3(0, 0.15, -1), 250.0],
}

var demo: Node3D


func _initialize() -> void:
	_run.call_deferred()


func _rel(ar: ActiveRagdoll, n: String) -> Quaternion:
	var p := ar.physical_parent(n)
	return (ar._bone_basis(p).inverse() * ar._bone_basis(n)).get_rotation_quaternion()


func _run() -> void:
	for name: String in CASES:
		if OS.get_environment("CASE") != "" and OS.get_environment("CASE") != name:
			continue
		var spec: Array = CASES[name]
		demo = (load("res://demo/demo.tscn") as PackedScene).instantiate()
		root.add_child(demo)
		for i in 60:
			await physics_frame
		var c := demo.get_node(String(spec[0])) as CharacterBody3D
		var ar: ActiveRagdoll = c.ragdoll
		var start := {}
		var rel0 := {}
		for n: String in ar.bones:
			start[n] = (ar.bones[n] as PhysicalBone3D).global_position
			if ar.physical_parent(n) != "":
				rel0[n] = _rel(ar, n)
		var start_head: Vector3 = (c.skeleton.global_transform * c.skeleton.get_bone_global_pose(c.skeleton.find_bone("Head"))).origin
		c.knock_down(spec[1], (spec[2] as Vector3).normalized() * float(spec[3]))
		var line := "KNOCK %-11s" % name
		for i in 31:
			await physics_frame
			if i % 6 != 0 or i == 0:
				continue
			var d := func(n: String) -> float:
				return (ar.bones[n] as PhysicalBone3D).global_position.distance_to(start[n]) * 100.0
			var bend := 0.0
			for n: String in rel0:
				bend += rad_to_deg(_rel(ar, n).angle_to(rel0[n]))
			bend /= rel0.size()
			line += "  | %.1fs head %3.0f hips %3.0f feet %3.0f bend %2.0f°" % [i / 60.0, d.call("Head"), d.call("Hips"), (d.call("LeftFoot") + d.call("RightFoot")) * 0.5, bend]
		print(line)
		demo.queue_free()
		await process_frame
	quit()
