class_name RagdollBuilder
extends RefCounted
## Builds a PhysicalBoneSimulator3D with PhysicalBone3D bodies on a Skeleton3D from a RagdollProfile.
## Capsules run from a bone to the next one (or along its +Y), joints sit at the bone's start: hinges for knees and
## elbows (bend one way), cones with limits elsewhere. Bodies start with no collision layer/mask and the simulator
## inactive — enable them when the ragdoll starts (ActiveRagdoll does this).
##
##   var r := RagdollBuilder.build(skeleton, RagdollProfile.humanoid())
##   r.simulator   # PhysicalBoneSimulator3D, child of the skeleton
##   r.bones       # {bone name: PhysicalBone3D}

## Result of build().
class Result:
	var simulator: PhysicalBoneSimulator3D
	var bones := {}


static func build(skeleton: Skeleton3D, profile: RagdollProfile, sim_name := "Ragdoll") -> Result:
	var r := Result.new()
	var sim := PhysicalBoneSimulator3D.new()
	sim.name = sim_name
	sim.active = false
	skeleton.add_child(sim)
	r.simulator = sim
	for bone_name: String in profile.bones:
		var spec: Dictionary = profile.bones[bone_name]
		var i := skeleton.find_bone(bone_name)
		if i < 0:
			continue
		var rest := skeleton.get_bone_global_rest(i)
		var dir: Vector3
		var length: float
		var to: Variant = spec.get("to", 0.15)
		if to is String and skeleton.find_bone(to) >= 0:
			var d := skeleton.get_bone_global_rest(skeleton.find_bone(to)).origin - rest.origin
			length = d.length()
			dir = d / maxf(length, 0.001)
		else:
			length = float(to) if not (to is String) else 0.15
			dir = rest.basis.y.normalized()
		var radius: float = spec.get("radius", 0.05)
		# capsule along the bone: −Z towards the next bone
		var up := Vector3.BACK if absf(dir.dot(Vector3.BACK)) < 0.8 else Vector3.UP
		var frame := Basis.looking_at(dir, up)
		var half := length * 0.5
		var body_w := Transform3D(frame, rest.origin + dir * half)
		var pb := PhysicalBone3D.new()
		pb.name = "PB_" + bone_name
		pb.set("bone_name", bone_name)
		pb.mass = spec.get("mass", 1.0)
		pb.friction = profile.friction
		pb.linear_damp = profile.linear_damp
		pb.angular_damp = profile.angular_damp
		pb.collision_layer = 0
		pb.collision_mask = 0
		pb.body_offset = rest.affine_inverse() * body_w
		pb.joint_offset = Transform3D(Basis.IDENTITY, Vector3(0, 0, half))   # the joint at the bone's start
		# joint axes: X along the bone (cone twist), Z across (hinge axis)
		pb.joint_rotation = Vector3(0, PI * 0.5, 0)
		var lim: Array = spec.get("limits", [])
		match String(spec.get("joint", "")):
			"cone":
				pb.joint_type = PhysicalBone3D.JOINT_TYPE_CONE
				pb.set("joint_constraints/swing_span", float(lim[0]))
				pb.set("joint_constraints/twist_span", float(lim[1]))
			"hinge":
				pb.joint_type = PhysicalBone3D.JOINT_TYPE_HINGE
				var sgn := profile.knee_sign if "Leg" in bone_name else profile.elbow_sign
				var a := float(lim[0]) * sgn
				var b := float(lim[1]) * sgn
				pb.set("joint_constraints/angular_limit_enabled", true)
				pb.set("joint_constraints/angular_limit_lower", minf(a, b))
				pb.set("joint_constraints/angular_limit_upper", maxf(a, b))
			_:
				pb.joint_type = PhysicalBone3D.JOINT_TYPE_NONE
		var cs := CollisionShape3D.new()
		var cap := CapsuleShape3D.new()
		cap.radius = radius
		cap.height = maxf(length + radius * 0.5, radius * 2.0 + 0.01)
		cs.shape = cap
		cs.rotation = Vector3(PI * 0.5, 0, 0)      # capsule axis (Y) along the body's −Z
		pb.add_child(cs)
		pb.set_meta(&"ragdoll_group", spec.get("group", ""))
		pb.set_meta(&"ragdoll_length", length)
		pb.set_meta(&"ragdoll_radius", radius)
		sim.add_child(pb)
		r.bones[bone_name] = pb
	return r
