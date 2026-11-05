extends SceneTree
## Shoves of growing strength into a standing puppet: does it stumble (steps to catch itself) or fall, and when?
##   godot --headless --path . --script res://demo/tools/probe_stumble.gd   (CASE=name for one)
## travel — how far the character (its feet) stepped, m; steps — foot lifts; drift — worst centre-of-mass drift, m;
## fell — time of balance_lost (s) or "no"; arms — highest a hand rose above the hips in the first second, m.

const CASES := {
	"back_60": [&"UpperChest", Vector3(0, 0, -1), 60.0],
	"back_90": [&"UpperChest", Vector3(0, 0, -1), 90.0],
	"back_120": [&"UpperChest", Vector3(0, 0, -1), 120.0],
	"back_160": [&"UpperChest", Vector3(0, 0, -1), 160.0],
	"fwd_90": [&"UpperChest", Vector3(0, 0, 1), 90.0],
	"side_90": [&"UpperChest", Vector3(1, 0, 0), 90.0],
	"hips_90": [&"Hips", Vector3(1, 0, 0), 90.0],
	"shin_60": [&"LeftLowerLeg", Vector3(1, 0, 0), 60.0],
	"shin_90": [&"LeftLowerLeg", Vector3(-1, 0, 0), 90.0],
	"thigh_90": [&"RightUpperLeg", Vector3(0, 0, -1), 90.0],
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
		var fell := [-1.0]
		var why := [""]
		var t := [0.0]
		ar.balance_lost.connect(func() -> void:
			if fell[0] < 0.0:
				fell[0] = t[0]
				why[0] = " (drift %.2f drop %.2f)" % [ar.drift().length(), ar.drop()])
		var start := c.global_position
		c.shove(spec[0], (spec[1] as Vector3) * float(spec[2]))
		var drift := 0.0
		var steps := 0
		var lifted := {"LeftFoot": false, "RightFoot": false}
		var arms := -9.0
		for i in 180:
			await physics_frame
			t[0] += 1.0 / 60.0
			drift = maxf(drift, ar.drift().length())
			if not ar.is_puppet():
				continue
			for f: String in lifted:
				var y := (ar.bones[f] as PhysicalBone3D).global_position.y
				if y > 0.16 and not lifted[f]:
					steps += 1
				lifted[f] = y > 0.16 if not lifted[f] else y > 0.12
			if t[0] < 1.0:
				var hy := (ar.bones["Hips"] as PhysicalBone3D).global_position.y
				for h in ["LeftLowerArm", "RightLowerArm"]:
					arms = maxf(arms, (ar.bones[h] as PhysicalBone3D).global_position.y - hy)
		print("STUMBLE %-9s travel %.2f m  steps %d  drift %.2f m  fell %s  arms %.2f m" % [name, start.distance_to(c.global_position), steps, drift, ("%.2fs%s" % [fell[0], why[0]]) if fell[0] >= 0.0 else "no", arms])
		demo.queue_free()
		await process_frame
	quit()
