extends SceneTree
## How a falling body protects itself: knocked down forwards, backwards, sideways, a leg knocked out.
##   godot --headless --path . --script res://demo/tools/probe_fall.gd   (CASE=name for one)
## hands — when the first hand touched the ground (s), head — when the head did and how fast it was going (m/s),
## knees — most a knee bent while falling (°), curl — most the spine curled over the hips (°), lands — on what
## (back / front / side, by where the pelvis faces at the end).

const CASES := {
	"forwards": [&"UpperChest", Vector3(0, 0.1, 1), 110.0],
	"backwards": [&"UpperChest", Vector3(0, 0.1, -1), 110.0],
	"sideways": [&"UpperChest", Vector3(1, 0.1, 0), 110.0],
	"leg_out": [&"LeftLowerLeg", Vector3(-1, 0, 0), 90.0],
}

var demo: Node3D


func _initialize() -> void:
	_run.call_deferred()


func _angle(ar: ActiveRagdoll, a: String, b: String) -> float:
	return rad_to_deg(ar._bone_basis(a).y.normalized().angle_to(ar._bone_basis(b).y.normalized()))


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
		var knee0 := maxf(_angle(ar, "LeftUpperLeg", "LeftLowerLeg"), _angle(ar, "RightUpperLeg", "RightLowerLeg"))
		var curl0 := _angle(ar, "Hips", "UpperChest")
		if name == "leg_out":
			c.shove(spec[0], (spec[1] as Vector3) * float(spec[2]))
		else:
			c.knock_down(spec[0], (spec[1] as Vector3).normalized() * float(spec[2]))
		var hand_t := -1.0
		var head_t := -1.0
		var head_v := 0.0
		var knees := 0.0
		var curl := 0.0
		for i in 150:
			await physics_frame
			var t := (i + 1) / 60.0
			var head := ar.bones["Head"] as PhysicalBone3D
			if head_t < 0.0 and head.global_position.y < 0.16:
				head_t = t
				head_v = head.linear_velocity.length()
			for h in ["LeftLowerArm", "RightLowerArm"]:
				var pb := ar.bones[h] as PhysicalBone3D
				var end := pb.global_transform * Vector3(0, 0, -float(pb.get_meta(&"ragdoll_length", 0.25)) * 0.5)
				if hand_t < 0.0 and end.y < float(pb.get_meta(&"ragdoll_radius", 0.05)) + 0.04 and ar.is_running() and not ar.is_puppet():
					hand_t = t
			if head_t < 0.0 and ar.is_running():
				knees = maxf(knees, maxf(_angle(ar, "LeftUpperLeg", "LeftLowerLeg"), _angle(ar, "RightUpperLeg", "RightLowerLeg")) - knee0)
				curl = maxf(curl, _angle(ar, "Hips", "UpperChest") - curl0)
		# by the pelvis — the chest also turns when the back curls
		var faces := ar._bone_basis("Hips").z.normalized().y
		var lands := "back" if faces > 0.5 else ("front" if faces < -0.5 else "side")
		print("FALL %-9s hands %s  head %s  knees %3.0f°  curl %3.0f°  lands on %s" % [name,
			("%.2fs" % hand_t) if hand_t >= 0.0 else "never", ("%.2fs at %.1f m/s" % [head_t, head_v]) if head_t >= 0.0 else "never", knees, curl, lands])
		demo.queue_free()
		await process_frame
	quit()
