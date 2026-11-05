extends SceneTree
## A body knocked down alive, once it lies: does it move like a hurt person (writhe) and hold the wound?
##   godot --headless --path . --script res://demo/tools/probe_ground.gd   (CASE=name for one)
## moves — mean joint motion, °/s, per second of lying (0 — a log); hand — closest / mean distance of the nearest hand
## to the wound, m; up — highest the hips rose, m (it stays down); fast — fastest body speed, m/s (no explosions).

const CASES := {
	"chest_front": [&"UpperChest", Vector3(0, 0.1, -1), 110.0],
	"chest_back": [&"UpperChest", Vector3(0, 0.1, 1), 110.0],
	"thigh": [&"LeftUpperLeg", Vector3(1, 0, 0), 150.0],
	"arm": [&"RightUpperArm", Vector3(-1, 0.1, 0), 110.0],
}

var demo: Node3D


func _initialize() -> void:
	_run.call_deferred()


func _rel(ar: ActiveRagdoll, n: String) -> Quaternion:
	return (ar._bone_basis(ar.physical_parent(n)).inverse() * ar._bone_basis(n)).get_rotation_quaternion()


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
		c.knock_down(spec[0], (spec[1] as Vector3).normalized() * float(spec[2]))
		var wound := ar.bones[String(spec[0])] as PhysicalBone3D
		for i in 150:
			await physics_frame
		var face0 := ar._bone_basis("Hips").z.normalized().y
		var moves: Array[float] = []
		var prev := {}
		for n: String in ar.bones:
			if ar.physical_parent(n) != "":
				prev[n] = _rel(ar, n)
		var near := INF
		var mean := 0.0
		var up := 0.0
		var fast := 0.0
		var acc := 0.0
		for i in 300:
			await physics_frame
			var step := 0.0
			for n: String in prev:
				var q := _rel(ar, n)
				step += rad_to_deg(q.angle_to(prev[n]))
				prev[n] = q
			acc += step / prev.size()
			if i % 60 == 59:
				moves.append(acc)
				acc = 0.0
			var best := INF
			for h in ["LeftLowerArm", "RightLowerArm"]:
				if h.begins_with(String(spec[0]).left(4)) and String(spec[0]).contains("Arm"):
					continue
				var pb := ar.bones[h] as PhysicalBone3D
				var end := pb.global_transform * Vector3(0, 0, -float(pb.get_meta(&"ragdoll_length", 0.25)) * 0.5)
				best = minf(best, end.distance_to(wound.global_position))
			near = minf(near, best)
			mean += best / 300.0
			up = maxf(up, (ar.bones["Hips"] as PhysicalBone3D).global_position.y)
			for pb: PhysicalBone3D in ar.bones.values():
				fast = maxf(fast, pb.linear_velocity.length())
		var ms := ""
		for m in moves:
			ms += "%.0f " % m
		print("GROUND %-11s pelvis faces up %.2f → %.2f  writhing %s  moves %s°/s  hand %.2f / %.2f m  up %.2f m  fast %.1f m/s" % [name, face0, ar._bone_basis("Hips").z.normalized().y, ar.writhing(), ms, near, mean, up, fast])
		demo.queue_free()
		await process_frame
	quit()
