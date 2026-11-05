extends SceneTree
## How a standing puppet's torso answers a blow: CASE=shot_arm|shove_arm|shove_chest|shot_chest|shove_hips.
##   godot --headless --path . --script res://demo/tools/probe_hits.gd    (all cases, one line each)
## chest — how far the upper chest went from the animation (cm) and how far it turned from where it was (°), hips — same,
## fold — most the torso bent over the hips beyond the animation (°), fell — balance lost.

const CASES := {
	"none": [&"Hips", Vector3(1, 0, 0), 0.0, false],
	"shot_arm": [&"LeftUpperArm", Vector3(1, 0, 0), 10.0, false],
	"shove_arm": [&"LeftUpperArm", Vector3(1, 0, 0), 60.0, true],
	"shot_chest": [&"UpperChest", Vector3(0, 0, -1), 10.0, false],
	"shove_chest": [&"UpperChest", Vector3(0, 0, -1), 60.0, true],
	"shove_hips": [&"Hips", Vector3(1, 0, 0), 60.0, true],
	"arm60_def": [&"LeftUpperArm", Vector3(1, 0, 0), 60.0, [0.95, -1.0, 0.0]],
	"arm60_b05": [&"LeftUpperArm", Vector3(1, 0, 0), 60.0, [1.0, 0.5, 0.3]],
	"arm40_b05": [&"LeftUpperArm", Vector3(1, 0, 0), 40.0, [1.0, 0.5, 0.3]],
	"chest60_b05": [&"UpperChest", Vector3(0, 0, -1), 60.0, [1.0, 0.5, 0.3]],
}

var demo: Node3D


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	for name: String in CASES:
		if OS.get_environment("CASE") != "" and OS.get_environment("CASE") != name:
			continue
		demo = (load("res://demo/demo.tscn") as PackedScene).instantiate()
		root.add_child(demo)
		for i in 60:
			await physics_frame
		var c := demo.get_node("Standing") as CharacterBody3D
		var ar: ActiveRagdoll = c.ragdoll
		var spec: Array = CASES[name]
		var fell := [false]
		var chest0 := (ar.bones["UpperChest"] as PhysicalBone3D).global_basis.get_rotation_quaternion()
		var hips0 := (ar.bones["Hips"] as PhysicalBone3D).global_basis.get_rotation_quaternion()
		var turn := 0.0
		var hturn := 0.0
		ar.balance_lost.connect(func() -> void: fell[0] = true)
		if spec[2] <= 0.0:
			pass
		elif spec[3] is Array:
			ar.puppet_hit(spec[0], spec[1] * spec[2], spec[3][0], spec[3][1], spec[3][2])
		elif spec[3]:
			c.shove(spec[0], spec[1] * spec[2])
		else:
			c.shoot(spec[0], spec[1] * spec[2])
		var chest_d := 0.0
		var chest_r := 0.0
		var hips_d := 0.0
		var fold := 0.0
		var line := ""
		for i in 72:
			await physics_frame
			if not ar.is_puppet():
				break
			var g: Transform3D = c.skeleton.global_transform
			var tg: Dictionary = ar._target_mod.targets
			for b in ["UpperChest", "Hips"]:
				var pb := ar.bones[b] as PhysicalBone3D
				var want: Transform3D = g * (tg[b] as Transform3D) * pb.body_offset
				var d := pb.global_position.distance_to(want.origin) * 100.0
				if b == "Hips":
					hips_d = maxf(hips_d, d)
				else:
					chest_d = maxf(chest_d, d)
					chest_r = maxf(chest_r, rad_to_deg(pb.global_basis.get_rotation_quaternion().angle_to(want.basis.get_rotation_quaternion())))
			turn = maxf(turn, rad_to_deg((ar.bones["UpperChest"] as PhysicalBone3D).global_basis.get_rotation_quaternion().angle_to(chest0)))
			hturn = maxf(hturn, rad_to_deg((ar.bones["Hips"] as PhysicalBone3D).global_basis.get_rotation_quaternion().angle_to(hips0)))
			var hb := ar._bone_basis("Hips")
			var ub := ar._bone_basis("UpperChest")
			var th: Basis = (g.basis * (tg["Hips"] as Transform3D).basis).orthonormalized()
			var tu: Basis = (g.basis * (tg["UpperChest"] as Transform3D).basis).orthonormalized()
			var bend := rad_to_deg(hb.y.normalized().angle_to(ub.y.normalized())) - rad_to_deg(th.y.normalized().angle_to(tu.y.normalized()))
			fold = maxf(fold, bend)
			if i in [6, 18, 36]:
				line += "  t%.1f chest %.0f" % [i / 60.0, (ar.bones["UpperChest"] as PhysicalBone3D).global_position.distance_to((g * (tg["UpperChest"] as Transform3D) * (ar.bones["UpperChest"] as PhysicalBone3D).body_offset).origin) * 100.0]
		print("HIT %-12s chest %4.1f cm, turned %4.1f°  hips %4.1f cm, turned %4.1f°  fold %4.1f°  fell %s %s" % [name, chest_d, turn, hips_d, hturn, fold, fell[0], line])
		demo.queue_free()
		await process_frame
	quit()
