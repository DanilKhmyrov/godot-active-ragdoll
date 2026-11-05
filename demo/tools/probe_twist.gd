extends SceneTree
## How far the arms twist about their own axis (relative to their physical parent, from the rest relation) while a
## body falls and lies — a twisted upper arm turns the elbow the wrong way. CASE=name for one; max and at the end, °.
const CASES := {
	"back": [&"UpperChest", Vector3(0, 0.1, -1), 90.0],
	"front": [&"UpperChest", Vector3(0, 0.1, 1), 90.0],
	"side": [&"UpperChest", Vector3(1, 0.1, 0), 90.0],
}
var demo: Node3D
func _initialize() -> void:
	_run.call_deferred()
static func _twist(q: Quaternion) -> float:
	var t := Quaternion(0, q.y, 0, q.w).normalized()
	var a := rad_to_deg(2.0 * atan2(t.y, t.w))
	return wrapf(a, -180.0, 180.0)
func _rel(ar: ActiveRagdoll, sk: Skeleton3D, n: String) -> Quaternion:
	var p := ar.physical_parent(n)
	var rest := ar._rest_rel(n).get_rotation_quaternion()      # the neutral its limits are centred on
	var now := (ar._bone_basis(p).inverse() * ar._bone_basis(n)).get_rotation_quaternion()
	return rest.inverse() * now
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
		c.auto_get_up = false
		var ar: ActiveRagdoll = c.ragdoll
		var sk: Skeleton3D = c.skeleton
		c.knock_down(spec[0], (spec[1] as Vector3).normalized() * float(spec[2]))
		var worst := {}
		for i in 420:
			await physics_frame
			for n in ["LeftUpperArm", "RightUpperArm", "LeftLowerArm", "RightLowerArm", "Head"]:
				worst[n] = maxf(float(worst.get(n, 0.0)), absf(_twist(_rel(ar, sk, n))))
		var line := "TWIST %-6s" % name
		for n in ["LeftUpperArm", "RightUpperArm", "LeftLowerArm", "RightLowerArm", "Head"]:
			line += "  %s max %3.0f end %+4.0f" % [n.replace("Upper", "U").replace("Lower", "L"), worst[n], _twist(_rel(ar, sk, n))]
		print(line)
		demo.queue_free()
		await process_frame
	quit()
