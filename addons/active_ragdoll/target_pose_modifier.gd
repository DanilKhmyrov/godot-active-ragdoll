class_name TargetPoseModifier
extends SkeletonModifier3D
## Records the pose the physical body should follow in puppet mode: animation plus every modifier before this one
## (IK, look-at, lean…) — read here, right before PhysicalBoneSimulator3D, which then overrides the bones with
## physics. Skeleton-space transforms of the physical bones, ActiveRagdoll.targets().

var ragdoll: ActiveRagdoll
var targets := {}            # bone name → Transform3D, skeleton space


func setup(ar: ActiveRagdoll) -> void:
	ragdoll = ar


func _process_modification_with_delta(_delta: float) -> void:
	if ragdoll == null:
		return
	var sk := get_skeleton()
	for n: String in ragdoll.bones:
		targets[n] = sk.get_bone_global_pose(ragdoll._idx[n])
